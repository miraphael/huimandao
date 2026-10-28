import Foundation

/// 源级熔断 —— 「这个源这轮已经彻底不行了，别再让它拖住界面」。
///
/// ## 为什么需要（2026-10-28，用户实测）
/// 用户原话：「切换包子漫画一直切换不到，一直加载」。
/// 拆开看是三件事叠在一起：
///   ① 包子图床整站 404（站点侧故障，代码无解）；
///   ② 每次切源都会**重新**去试一遍，于是每次都要等它超时；
///   ③ 换源页还要拿它去核验章节数 —— 一个坏源能拖住整页 30 秒。
///
/// 图床级熔断（`ChapterImageStore.consecutiveNotFound`）只解决「一张图失败后
/// 同 host 的后续图直接判失败」，管不到**源**这一层。这里补上：
/// 同一个源本会话内连续失败 3 次 → 后续请求直接跳过，并给用户一句
/// 「本会话已连续失败 N 次，暂时跳过」。
///
/// ## 三个刻意的设计取舍
///
/// **① 只记内存，不落盘。** 设计文档写的是「本次会话内跳过」。落盘会让
///    「昨天站点抽风」变成「今天打开就跳过」，用户完全无法自证。
///    重启 App = 全部清零，永远给人一次干净的重试机会。
///
/// **② 不是所有失败都计数。** 只有「这个源本身够不到」才算：
///    `network` / `timeout` / `blocked` / `server` / `unknown`。
///    明确**不计数**的三类：
///      · `notFound`（404）—— 是「这本书下架了」，不是「这个源坏了」。
///        按源计数会把一本下架的书误判成整源故障。
///      · `ruleMiss`（解析 0 条）—— 可能是关键词真没结果，属于正常业务结果。
///      · `needLogin` —— 用户去网页登录一次就能恢复，熔断会挡住这条修复路径。
///
/// **③ 半开恢复（half-open）。** 熔断不是永久拉黑：冷却 `cooldown` 秒后
///    放行一次试探。成功 → 清零；失败 → 重新计时。否则站点短暂抽风一次，
///    用户整轮都得手动重启 App。
final class SourceBreaker: @unchecked Sendable {

    static let shared = SourceBreaker()

    /// 连续失败达到这个次数 → 熔断
    let limit: Int
    /// 熔断后多久放行一次试探
    let cooldown: TimeInterval

    private let lock = NSLock()
    private var failures: [String: Int] = [:]
    private var openedAt: [String: Date] = [:]
    private var reasons: [String: FailureReason] = [:]

    init(limit: Int = 3, cooldown: TimeInterval = 120) {
        self.limit = limit
        self.cooldown = cooldown
    }

    /// 某个源的熔断状态快照（供 UI 展示）
    struct Snapshot: Equatable {
        var origin: String
        var failures: Int
        /// 熔断开始时刻（nil = 未熔断）
        var openedAt: Date?
        var lastReason: FailureReason?

        var isOpen: Bool { openedAt != nil }
    }

    // MARK: - 查询

    /// 是否应该跳过这个源。返回 nil = 可以正常请求。
    ///
    /// 冷却到期的源会**放行**（半开），但计数不清零 —— 若这次又失败，
    /// `recordFailure` 会把熔断窗口重新推后。
    func shouldSkip(_ origin: String) -> Snapshot? {
        guard !origin.isEmpty else { return nil }
        lock.lock()
        let f = failures[origin] ?? 0
        let opened = openedAt[origin]
        let reason = reasons[origin]
        lock.unlock()

        guard f >= limit, let opened else { return nil }
        guard Date().timeIntervalSince(opened) < cooldown else { return nil }   // 半开
        return Snapshot(origin: origin, failures: f, openedAt: opened, lastReason: reason)
    }

    /// 不判断冷却、纯读状态（UI 角标用）
    func snapshot(_ origin: String) -> Snapshot? {
        guard !origin.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        let f = failures[origin] ?? 0
        guard f > 0 else { return nil }
        return Snapshot(origin: origin, failures: f,
                        openedAt: openedAt[origin], lastReason: reasons[origin])
    }

    /// 当前处于熔断（未过冷却）的源数量
    func openCount() -> Int {
        lock.lock()
        let all = openedAt
        lock.unlock()
        let now = Date()
        return all.values.filter { now.timeIntervalSince($0) < cooldown }.count
    }

    // MARK: - 记账

    func recordSuccess(_ origin: String) {
        guard !origin.isEmpty else { return }
        lock.lock()
        failures.removeValue(forKey: origin)
        openedAt.removeValue(forKey: origin)
        reasons.removeValue(forKey: origin)
        lock.unlock()
    }

    /// 记一次失败。返回 true 表示「这一次刚好触发熔断」（调用方可以据此打日志）。
    @discardableResult
    func recordFailure(_ origin: String, reason: FailureReason) -> Bool {
        guard !origin.isEmpty, Self.countsTowardBreaker(reason) else { return false }
        lock.lock()
        let n = (failures[origin] ?? 0) + 1
        failures[origin] = n
        reasons[origin] = reason
        var justOpened = false
        if n >= limit {
            // 已经熔断后再次失败（半开试探失败）→ 把窗口推后，重新冷却
            justOpened = (openedAt[origin] == nil)
            openedAt[origin] = Date()
        }
        lock.unlock()
        return justOpened
    }

    func reset(_ origin: String) {
        recordSuccess(origin)
    }

    func resetAll() {
        lock.lock()
        failures.removeAll()
        openedAt.removeAll()
        reasons.removeAll()
        lock.unlock()
    }

    /// 这类失败算不算「源本身够不到」—— 见文件头 ② 的取舍说明。
    static func countsTowardBreaker(_ reason: FailureReason) -> Bool {
        switch reason {
        case .network, .timeout, .blocked, .server, .unknown: return true
        case .notFound, .ruleMiss, .needLogin, .decode:       return false
        }
    }
}
