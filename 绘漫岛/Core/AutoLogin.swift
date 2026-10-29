import Foundation

/// ── 自动登录 / 自动过验证 ───────────────────────────────────────────────
///
/// 用户诉求：「别让我手动点，自动跳转验证就行」。
///
/// 两条自动链：
/// ① **挑战页**（Cloudflare / 盾 / 滑块）—— 已在 `AntiBot` 里：HttpFetcher 收到
///    403 + `cf-mitigated:challenge` 就自动开隐藏 WebView 过挑战、回写 Cookie 再重试。
/// ② **登录态**（如卡拉漫画的 `omo_token` 由页面 JS 写入）—— 本文件负责：
///    源配了 `loginUrl` 且还没拿到过登录态时，**自动**用隐藏 WebView 访问一次，
///    抓到 Cookie 回写 `CookieStore` + 标记 `loginUrlResult`，之后所有请求自带登录态。
///
/// 与 `AntiBot` 的区别：AntiBot 是**失败后**的兜底；AutoLogin 是**首次访问前**的预热。
/// 两者共用 `WebViewRuleEngine`（同一个隐藏 WebView，串行执行）。
enum AutoLogin {

    /// 登录态有效期：12 小时（站点 token 一般更短，过期后失败会再自动跑一次）
    static let ttl: TimeInterval = 12 * 3600

    private static var running = Set<String>()
    /// 失败冷却：同一个源自动登录失败后，10 分钟内不再重试。
    /// 🔴 真机实证：漫画网的 `loginUrl` 是一条搜索页，隐藏 WebView 永远「没放行」，
    ///    每次抓取前都要等满 25 秒 → 用户看到「切换图源一直加载、切不过去」。
    ///    失败就该认输，别每次都拿 25 秒再撞一次。
    private static var failedAt: [String: Date] = [:]
    private static let failureCooldown: TimeInterval = 10 * 60
    private static let lock = NSLock()

    /// 确保该源可用于抓取：需要登录就先自动登录一次。
    /// - Returns: 是否可以继续（不需要登录 / 登录成功）
    @discardableResult
    static func ensure(_ s: ComicSource) async -> Bool {
        guard AppSettings.shared.autoLogin else { return true }
        guard let loginUrl = s.loginUrl, !loginUrl.isEmpty else { return true }
        // 已拿到登录态 → 放行（过期由「失败后重跑」兜底，不在这里计时）
        if let r = s.loginUrlResult, !r.isEmpty { return true }
        // 刚失败过 → 冷却期内直接放行（不阻塞抓取）
        lock.lock()
        let recentFail = failedAt[s.bookSourceUrl].map {
            Date().timeIntervalSince($0) < failureCooldown
        } ?? false
        lock.unlock()
        if recentFail { return false }

        guard begin(s.bookSourceUrl) else { return true }   // 并发去重：同一源只跑一次
        defer { end(s.bookSourceUrl) }

        DiagLog.event("login", "auto",
                      "自动登录开始：\(s.bookSourceName) → \(DiagLog.safeURL(loginUrl))")
        // 25s → 10s：真机实测正常放行只需几秒，等满 25 秒的只会是「压根过不去」的情况，那 15 秒纯属白等（失败后还有 10 分钟冷却）。
        let res = await WebViewRuleEngine.shared.passChallenge(url: loginUrl, maxWaitMs: 10_000)
        guard res.passed else {
            lock.lock(); failedAt[s.bookSourceUrl] = Date(); lock.unlock()
            DiagLog.event("login", "auto",
                          "❌ 自动登录失败：\(s.bookSourceName)（页面没放行）→ 10 分钟内不再尝试")
            return false
        }

        let host = s.host()
        var keys: [String] = []
        for (k, v) in res.cookies where !k.isEmpty {
            CookieStore.set(host: host, name: k, value: v)
            keys.append(k)
        }
        if !res.ua.isEmpty { CookieStore.setUA(host: host, ua: res.ua) }

        if var updated = ComicRepository.shared.source(url: s.bookSourceUrl) {
            updated.loginUrlResult = keys.isEmpty ? "" : "ok:" + keys.sorted().joined(separator: ",")
            ComicRepository.shared.saveSource(updated)
        }
        NotificationCenter.default.post(name: .hmdSourcesChanged, object: nil)
        DiagLog.event("login", "auto",
                      "✅ 自动登录完成：\(s.bookSourceName)，捕获 \(keys.count) 个 Cookie（域 \(host)）")
        return !keys.isEmpty
    }

    /// 清掉登录标记（Cookie 失效时手动重跑用）
    static func reset(_ s: ComicSource) {
        guard var updated = ComicRepository.shared.source(url: s.bookSourceUrl) else { return }
        updated.loginUrlResult = ""
        ComicRepository.shared.saveSource(updated)
        DiagLog.event("login", "reset", "已清除登录标记：\(s.bookSourceName)")
    }

    private static func begin(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if running.contains(key) { return false }
        running.insert(key); return true
    }

    private static func end(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        running.remove(key)
    }
}
