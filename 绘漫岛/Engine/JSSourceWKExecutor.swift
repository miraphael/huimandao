import Foundation
import UIKit
import WebKit

/// JS 类源的「可终止」执行通道（`JS隔离方案评估.md` 方案 C）。
///
/// ## 为什么需要它
/// `JSProvider` 默认走 `JSEvaluator`（JavaScriptCore）。JSCore **没有终止执行中脚本的 API**，
/// 一个 `while(true){}` 会让该次 `evaluate` 永不返回、**永久占住 `JSExecQueue`** ——
/// 之后所有 JS 解析一起排队。这是 §9.1 明确要求评估、发布前必须解决的问题。
///
/// WKWebView 的 JS 跑在 **WebContent 独立进程**里：销毁 WebView 即可回收该进程，
/// 这是 iOS 上**现成可用**的唯一隔离手段。本类把它包装成「带超时的执行器」。
///
/// ## 能力边界（刻意保守）
/// · **不提供网络桥**。JSCore 通道里的 `org.jsoup.*` / `java.ajax` 在这里**没有对应实现** ——
///   因为跨进程无法同步阻塞调用 Swift（WKWebView 的 JS 与原生只能异步通信）。
///   依赖网络抓取的 JS 源**不应**走本通道；请在源里显式声明（见 `JSSourceManifest.runtime`）。
/// · **无 HTML 上下文**：在 `about:blank` 上执行，提供 `java.get/put/log`（纯内存）。
/// · 超时后**销毁并重建** WebView —— 这是唯一可靠的"终止"。
///
/// ## 并发
/// `@MainActor`（WKWebView 必须主线程操作）。同一时刻只跑一个脚本（内部串行）。
@MainActor
final class JSSourceWKExecutor {
    static let shared = JSSourceWKExecutor()

    /// 单次执行的默认超时（秒）。超过即销毁 WebView —— 进程被回收，不再占用。
    /// 取 8s：JS 源多为「解析型」纯计算，正常脚本毫秒级完成；8s 未返回基本可判定异常。
    static let defaultTimeout: TimeInterval = 8

    private var webview: WKWebView?
    /// 当前是否正在执行（串行化，避免多个脚本争抢同一个 WebView）
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// 已因超时被强制销毁的次数（仅用于诊断展示，不参与逻辑）
    private(set) var forcedKillCount = 0

    private init() {}

    /// 执行一段 JS，返回其字符串结果。
    ///
    /// - Parameters:
    ///   - script: 待执行的 JS（应是一个完整表达式或有返回值的 IIFE）
    ///   - timeout: 超时秒数；超时返回 `nil` 并**销毁 WebView**（可终止保证）
    ///   - variables: 预置到 `java.get(k)` 能读到的键值对
    /// - Returns: 成功时返回结果字符串；超时 / 出错返回 nil。
    func run(script: String,
             timeout: TimeInterval = JSSourceWKExecutor.defaultTimeout,
             variables: [String: String] = [:]) async -> String? {
        await acquire()
        defer { release() }
        guard let w = ensureWebview() else { return nil }

        // 预置上下文：与 WebViewRuleEngine 的 prelude 保持同一套 `java.*` 语义，
        // 让写过 HTML 规则的作者迁移过来时不必重新学。
        let prelude = """
        var __kv = \(Self.json(variables));
        var java = {
          get: function(k){ return __kv[k] !== undefined ? __kv[k] : ''; },
          put: function(k,v){ __kv[k] = String(v); },
          log: function(m){ },
          toast: function(m){ }
        };
        var result = null;
        """
        _ = try? await w.evaluateJavaScript(prelude)

        let value = await withTimeout(timeout: timeout) {
            try? await w.evaluateJavaScript(script)
        }
        guard let value else {
            // 超时（或执行抛错）→ 销毁 WebView。
            // ⚠️ 必须真的销毁，不能只 `stopLoading()`：WebContent 进程里跑飞的循环
            //    不会因为停止加载而结束，只有销毁 WebView 才能让它随进程一起被回收。
            teardown()
            forcedKillCount += 1
            return nil
        }
        if let s = Self.stringify(value), !s.isEmpty { return s }
        // 脚本通过 `result = ...` 传值的写法（对齐 WebViewRuleEngine 的兜底）
        if let r = try? await w.evaluateJavaScript(
            "String(typeof result === 'undefined' || result === null ? '' : result)") {
            return Self.stringify(r)
        }
        return ""
    }

    // MARK: - 超时包装

    /// 给一个 async 操作加超时。超时返回 nil（**不取消**内层 —— 内层是 WebView 调用，
    /// 取消不了；真正的终止靠调用方在超时后销毁 WebView）。
    ///
    /// ⚠️ **不能用 `withTaskGroup` 实现超时**（曾经就是这么写的，是个真 bug）：
    ///    `withTaskGroup` 在**离开作用域时隐式等待所有子任务结束**。
    ///    内层是 `evaluateJavaScript`（不可取消 —— 没有对应的 cancel API，
    ///    必须等 WebKit 回调）。于是「超时返回 nil」的那条路径根本走不到：
    ///    作用域退出时会一直等那个卡死的子任务 → **整个调用永久挂起**。
    ///    现象：某个 JS 源页面里 `alert`/死循环让 WebKit 回调永不返回时，
    ///    这次抓取不是「15 秒后失败」，而是**永远不返回**（UI 上表现为一直转圈）。
    ///
    ///    改用「竞速两条独立 Task + continuation」：谁先完成就 resume 谁，
    ///    且**不等待**另一条 —— continuation 只允许 resume 一次，用 `claimed` 原子位保护。
    ///    超时后的孤儿任务由调用方 `teardown()`（销毁 WebView）来收尾。
    private func withTimeout<T>(timeout: TimeInterval,
                                _ op: @escaping () async -> T?) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            // `continuation` 只允许 resume 一次；用「锁 + 类的引用语义」保证先到者胜。
            // ⚠️ 不能用 `var claimed` + `@Sendable` 闭包：捕获可变局部变量在
            //    Swift 6 下是编译错误（`Mutation of captured var in concurrently-executing code`）。
            // ⚠️ 也不能把 `OnceFlag` 定义在这个闭包**里面** —— 本函数是泛型（`<T>`），
            //    Swift 不允许在泛型上下文的闭包内嵌套类型：
            //    `type 'OnceBox' cannot be nested in closure in generic context`。
            //    所以类型提到文件级（见文件末尾的 `OnceFlag`）。
            let once = OnceFlag()
            // ① 真正的工作
            Task {
                let r = await op()
                if once.claim() { cont.resume(returning: r) }
            }
            // ② 超时哨兵
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if once.claim() { cont.resume(returning: nil) }
            }
        }
    }

    // MARK: - WebView 生命周期

    private func ensureWebview() -> WKWebView? {
        if let webview, webview.superview != nil || webview.window != nil { return webview }
        let cfg = WKWebViewConfiguration()
        // JS 源不需要持久 cookie（本通道无网络），用非持久存储避免污染挑战态
        cfg.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: cfg)
        wv.alpha = 0.01
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
           let window = scene.windows.first {
            window.addSubview(wv)
            window.sendSubviewToBack(wv)
        }
        webview = wv
        return wv
    }

    /// 销毁 WebView（连同其 WebContent 进程一起回收）
    private func teardown() {
        webview?.stopLoading()
        webview?.removeFromSuperview()
        webview = nil
    }

    // MARK: - 串行化

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if let f = waiters.first {
            waiters.removeFirst()
            f.resume()   // 锁继续被持有
        } else {
            busy = false
        }
    }

    // MARK: - 工具

    private static func json(_ dict: [String: String]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    private static func stringify(_ v: Any?) -> String? {
        guard let v else { return nil }
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case is NSNull: return ""
        default: return "\(v)"
        }
    }
}

/// 「先到者胜」的一次性开关 —— 供 `withTimeout` 的 continuation 去重使用。
///
/// ⚠️ 必须是**文件级**类型，不能定义在泛型函数的闭包内（Swift 不允许）。
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// 返回 true 表示「本次是第一个到达者」，调用方据此 resume continuation。
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
