import Foundation

/// ──────────────────────────────────────────────────────────────────────────
/// 统一诊断日志（Log 横切）
///
/// ## 为什么需要它
/// 用户报「这本漫画打不开」时，我们能拿到的只有一张截图。而真实原因可能是
/// 「搜索命中了 → 详情页超时 → 重试拿到缓存 → 章节页解析 0 条」这条链上的**任何一环**。
/// 没有关联 id，这些事件在日志里是散的，串不起来。
///
/// 这里的做法：**一次用户动作 = 一个 session id**，
/// 链路上每个关键节点都带上它。用户导出日志时，我们按 session 分组就能还原全过程。
///
/// ## 边界（刻意不做的事）
/// · **不记正文/图片内容** —— 只记数量、耗时、状态码，避免把用户看的内容留在磁盘上。
/// · **不记 Cookie / Authorization / 签名 query** —— 这些是凭据，导出会泄露。
/// · **有上限**（`maxEntries`）—— 内存环形缓冲，App 常驻不会无限涨。
/// · 默认**不落盘**：需要时由用户显式导出（`exportText()`），导出内容交给用户自己保管。
/// ---------------------------------------------------------------------------
enum DiagLog {

    struct Entry {
        let at: Date
        let session: String
        let category: String
        let message: String

        var line: String {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return "\(f.string(from: at))  [\(category)]  \(session.isEmpty ? "-" : session)  \(message)"
        }
    }

    /// 上限：够定位最近几次操作，又不会占内存
    private static let maxEntries = 400
    private static var buffer: [Entry] = []
    private static var counter = 0
    private static let lock = NSLock()

    /// 开一次新的用户动作，返回 session id（形如 `d3`、`s7`）。
    /// - Parameter category: 动作类型，如 `detail` / `search` / `download`
    static func begin(_ category: String) -> String {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        let sid = "\(category.prefix(1))\(counter)"
        appendLocked(Entry(at: Date(), session: sid, category: category, message: "开始"))
        return sid
    }

    /// 记一条事件。
    ///
    /// ⚠️ 只允许**同步**调用：内部用 `NSLock`，而 `NSLock.lock()` 标了
    ///    `@available(*, noasync)`，在 async 函数体里直接调用是 Swift 6 编译错误
    ///    （`probe/async_lock.py` 扫这个）。async 上下文里直接调本函数是安全的，
    ///    因为它本身不是 async。
    static func event(_ session: String, _ category: String, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(Entry(at: Date(), session: session, category: category, message: message))
    }

    /// 快捷写法：带耗时的事件
    static func event(_ session: String, _ category: String, _ message: String, ms: Int) {
        event(session, category, "\(message) (\(ms)ms)")
    }

    private static func appendLocked(_ e: Entry) {
        buffer.append(e)
        if buffer.count > maxEntries {
            buffer.removeFirst(buffer.count - maxEntries)
        }
        // ⚠️ 落盘放在**后台队列**：绝不在调用线程（往往是主线程）做磁盘 IO。
        persist(e.line)
        #if DEBUG
        print("[Diag] \(e.line)")
        #endif
    }

    // MARK: - 落盘（供「把设备日志取回来分析」）

    /// 日志文件：`Documents/diag.log`。
    ///
    /// ## 为什么需要它
    /// 真机上的视觉问题（黑屏、跳页、闪烁）只看录屏**猜不出原因** ——
    /// 录像能证明「发生了什么」，但证明不了「App 内部处于什么状态」。
    /// 而本机**拿不到 iOS 的 UI 控制通道**（`developer screenshot` 走不通），
    /// 唯一能把设备数据取回来的通道是 `pymobiledevice3 apps pull`
    /// —— 所以日志必须**落到 App 自己的 Documents 里**。
    ///
    /// 取法：
    /// `pymobiledevice3 apps pull app.jujube3424.yew7522 Documents/diag.log dev/diag.log`
    ///
    /// ## 边界
    /// · 仍然**只记数量/状态/耗时**，不记正文与图片内容（与 `exportText` 同规矩）。
    /// · 超过 `maxLogBytes` 就**整个重开**（不做滚动归档：这是诊断文件，不是数据库）。
    private static let persistQueue = DispatchQueue(label: "hmd.diag.persist", qos: .utility)
    private static let maxLogBytes = 2 * 1024 * 1024
    private static let logURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("diag.log")
    }()

    private static func persist(_ line: String) {
        persistQueue.async {
            let data = (line + "\n").data(using: .utf8) ?? Data()
            let fm = FileManager.default
            if let attrs = try? fm.attributesOfItem(atPath: logURL.path),
               let size = attrs[.size] as? Int, size > maxLogBytes {
                try? fm.removeItem(at: logURL)
            }
            if let fh = try? FileHandle(forWritingTo: logURL) {
                defer { try? fh.close() }
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: data)
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    /// 清空磁盘日志（供「只保留本次复现」的场景）
    static func clearPersisted() {
        persistQueue.async { try? FileManager.default.removeItem(at: logURL) }
    }

    static func recent(_ n: Int = 200) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return Array(buffer.suffix(max(1, n)))
    }

    static func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return buffer.count
    }

    static func clear() {
        lock.lock(); defer { lock.unlock() }
        buffer.removeAll()
    }

    /// 导出成纯文本（按时间顺序，**不做 session 分组** —— 分组交给看的人）。
    static func exportText() -> String {
        let entries = recent(maxEntries)
        guard !entries.isEmpty else { return "（暂无诊断日志）" }
        let head = "绘漫岛诊断日志 · \(entries.count) 条 · 导出时间 \(Date())\n" +
                   "说明：同一 session id 的若干行属于同一次操作，按它串链路。\n" +
                   String(repeating: "-", count: 60) + "\n"
        return head + entries.map(\.line).joined(separator: "\n")
    }

    /// 脱敏：把 URL 里的签名/令牌类 query 抹掉再入日志。
    ///
    /// 图源地址常带 `?sign=…&t=…` / `token=…`，直接记进日志再导出就泄露了。
    static func safeURL(_ url: String) -> String {
        guard var c = URLComponents(string: url) else { return url }
        let secretKeys = ["sign", "signature", "token", "key", "auth", "expire", "expires", "t"]
        if let items = c.queryItems, !items.isEmpty {
            c.queryItems = items.map { item in
                secretKeys.contains(item.name.lowercased())
                    ? URLQueryItem(name: item.name, value: "***")
                    : item
            }
        }
        return c.string ?? url
    }
}
