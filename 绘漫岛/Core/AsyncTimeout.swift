import Foundation

/// 「到点就返回」的通用超时封装。
///
/// ## 为什么需要（2026-10-28）
/// 用户实测最痛的一条是「切换包子漫画一直切换不到，一直加载」。
/// 根因不是解析错，而是**换源时逐个核验章节数的请求没有上限**：
/// 12 个候选 × 每个最坏 15s+30s（详情页首次+重试）→ 页面上转两分钟。
///
/// 给每个候选套一个 8 秒上限，用户最多等 8×3=24 秒就能看到结果，
/// 且**超时的那几个照样显示出来**（标成「超时未核验」），不会凭空消失。
enum AsyncTimeout {

    /// 竞速两条独立 Task：内层先完成就用它的结果，超时就用 `fallback`。
    ///
    /// ⚠️ **绝对不能用 `withTaskGroup` 实现超时** —— 这是 `JSSourceWKExecutor` 里
    ///    已经踩过的真 bug：`withTaskGroup` 离开作用域时会**隐式等待所有子任务**。
    ///    内层若不可取消（网络请求被系统挂住、WebView 回调不返回），
    ///    「超时返回 fallback」这条路径根本走不到，整个调用**永久挂起** ——
    ///    现象就是用户说的「一直转圈」。
    ///
    ///    这里用 continuation + 一次性开关：谁先到谁 resume，**不等待**另一条。
    ///    超时后的孤儿任务继续在后台跑完（结果被丢弃），由 URLSession 自己的
    ///    超时兜底回收 —— 这比挂住 UI 好得多。
    static func run<T>(seconds: TimeInterval,
                       fallback: T,
                       _ op: @escaping @Sendable () async -> T) async -> T {
        guard seconds > 0 else { return await op() }
        return await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            let once = TimeoutOnceFlag()
            Task {
                let value = await op()
                if once.claim() { cont.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.claim() { cont.resume(returning: fallback) }
            }
        }
    }
}

/// 「先到者胜」的一次性开关 —— 供 `AsyncTimeout.run` 的 continuation 去重使用。
///
/// ⚠️ 必须是**文件级**类型：Swift 不允许在泛型函数的闭包内嵌套类型
///    （`type 'X' cannot be nested in closure in generic context`）。
final class TimeoutOnceFlag: @unchecked Sendable {
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
