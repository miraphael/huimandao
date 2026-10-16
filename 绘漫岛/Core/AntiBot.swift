import Foundation
import WebKit

/// ──────────────────────────────────────────────────────────────────────────
/// 反反爬（Anti-Bot）—— 让图源解析不受站点验证页影响
///
/// ## 设计参考
/// Venera-Next（Flutter 漫画阅读器）的 `network/cloudflare.dart` +
/// `routing/cloudflare.dart`。它的三招我们全部照搬：
///
/// ① **用响应头判定，不靠嗅 HTML**
///    Cloudflare 挑战的响应带 `cf-mitigated: challenge`（HTTP 403）。
///    这比字符串嗅探准得多 —— 嗅 HTML 会把「页面里恰好出现 captcha 这个词」
///    误判成挑战。HTML 嗅探只作为**第二判据**（有些站点不用 Cloudflare）。
///
/// ② **UA 必须与 WebView 完全一致**（最容易踩的坑）
///    `cf_clearance` 是**跟 UA 绑定**的。WebView 过完挑战后必须把它的 UA
///    持久化，后续所有 HTTP 请求换用这个 UA，否则会出现
///    「挑战过了、Cookie 也有了，但请求还是被拒」这种极难排查的现象。
///
/// ③ **Cookie 双向同步**
///    WebView → CookieStore（拿到 `cf_clearance`）
///    CookieStore → WebView（避免每次开页都重新过挑战）
///
/// ## 分级升级链（从便宜到贵，只在失败路径上升级）
/// ```
/// L0 URLSession 直连（带 Cookie + 与 WebView 一致的 UA）
///   ↓ 403 + cf-mitigated:challenge ‖ 挑战页特征
/// L1 WebView 过挑战（真正执行挑战 JS）
///   ↓ 拿到 cf_clearance + UA → 回写 CookieStore
/// L2 用新 Cookie/UA 重试 URLSession（多数站点到此结束）
///   ↓ 仍失败（如需人机交互的 hCaptcha / reCAPTCHA）
/// L3 直接返回 WebView 渲染后的 HTML（绕过 HTTP 层）
/// ```
///
/// ## 为什么必须有「域名策略缓存」
/// 若每次都靠「先发一个必然失败的 URLSession 请求」来探测挑战，
/// 每次开页都要多付一次 403 往返（慢站上就是 10s 超时）。
/// 记住策略后，第二次起直接走 WebView。
///
/// ## ⚠️ 已知边界
/// 需要**人机交互**的挑战（点选图片的 hCaptcha/reCAPTCHA）无法自动通过。
/// 这类站点只能靠用户手动过一次（`WebViewRuleEngine` 的可见 WebView），
/// 过完把 Cookie 持久化。所以本模块的目标是「自动通过机器可解的挑战」，
/// 而不是「绕过一切」。
/// ──────────────────────────────────────────────────────────────────────────
enum AntiBot {

    // MARK: - 域名策略

    struct Policy: Codable {
        var needsWebView = false          // 该域名需要先过 WebView
        var lastSolvedAt: TimeInterval = 0
        var solvedCount = 0
        var ua = ""                       // WebView 的 UA（cf_clearance 绑定它）
        var lastBlockedAt: TimeInterval = 0
        var blockedCount = 0

        /// 挑战会话的有效期（Cloudflare 的 cf_clearance 通常几小时；
        /// 保守取 2 小时 —— 过期后重过一次挑战，避免「Cookie 看起来还在但已失效」）
        var fresh: Bool { Date().timeIntervalSince1970 - lastSolvedAt < 2 * 3600 }
    }

    private static let key = "hmd_antibot_policies"
    private static let lock = NSLock()
    private static var cache: [String: Policy] = [:]

    static func policy(for host: String) -> Policy? {
        guard !host.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        if cache.isEmpty { loadLocked() }
        return cache[host]
    }

    static func update(_ host: String, _ mutate: (inout Policy) -> Void) {
        guard !host.isEmpty else { return }
        lock.lock()
        if cache.isEmpty { loadLocked() }
        var p = cache[host] ?? Policy()
        mutate(&p)
        cache[host] = p
        let snapshot = cache
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { persist(snapshot) }
    }

    private static func loadLocked() {
        guard let d = UserDefaults.standard.data(forKey: key),
              let m = try? JSONDecoder().decode([String: Policy].self, from: d) else { return }
        cache = m
    }

    private static func persist(_ m: [String: Policy]) {
        guard let d = try? JSONEncoder().encode(m) else { return }
        UserDefaults.standard.set(d, forKey: key)
    }

    static func clearAll() {
        lock.lock(); cache = [:]; lock.unlock()
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - 挑战判定

    /// 判定一次响应是否被反爬拦截。
    ///
    /// - Parameters:
    ///   - status: HTTP 状态码（0 表示没拿到响应）
    ///   - headers: 响应头（键大小写不敏感）
    ///   - body: 响应体文本
    static func isChallenge(status: Int, headers: [String: String], body: String) -> Bool {
        // ① 响应头（最准）：Cloudflare 用 `cf-mitigated: challenge` 标记
        for (k, v) in headers where k.lowercased() == "cf-mitigated" {
            if v.lowercased().contains("challenge") { return true }
        }
        // ② 强特征：`cf-chl` / `challenge-platform` 这类标记**只可能**出现在反爬页，
        //    不看状态码也判。
        if hasStrongMarker(body) { return true }
        // ③ 弱特征：**必须配合非 2xx 状态码**。
        //
        // ⚠️ 原实现第 ③ 条是 `return looksLikeChallengeHTML(body)` —— **完全不看状态码**。
        //    而 `weakMarkers` 里的 `window.location.href =` / `location.replace(`
        //    会命中**任何含前端跳转脚本的正常页面**（大量漫画站列表页、广告位、
        //    年龄确认页都有）。一旦误判 → `fetchPage` 走挑战升级链 → 最终 `return ""`
        //    → 用户看到**空白页 / 章节 0 条**，而且和「站点真的挂了」无法区分。
        //    2xx 且能拿到 body = 服务端正常响应，不该再按挑战处理。
        guard status == 403 || status == 503 || status == 0 else { return false }
        return looksLikeChallengeHTML(body)
    }

    /// 强特征：这些标记**不可能**出现在正常漫画站页面里，不看体积直接判。
    static let strongMarkers = [
        "cf-mitigated", "__cf_chl", "cf-browser-verification", "cf-chl",
        "challenge-platform", "window._cf_chl_opt", "cf_challenge",
        "just a moment", "ddos protection", "attention required"
    ]

    /// 弱特征：可能误伤（比如某本漫画就叫「captcha」），必须配合「页面内容贫瘠」才判。
    static let weakMarkers = [
        "enable javascript and cookies", "please enable javascript",
        "checking your browser", "javascript is disabled",
        "window.location.href =", "document.location.href =",
        "location.replace(", "captcha",
        "请开启javascript", "正在验证", "人机验证", "访问验证", "安全验证"
    ]

    /// 强特征判定：不看状态码、不看体积（这些标记只可能出现在反爬页）。
    static func hasStrongMarker(_ html: String) -> Bool {
        guard !html.isEmpty else { return false }
        let low = html.lowercased()
        return strongMarkers.contains { low.contains($0) }
    }

    /// 弱特征 + **内容贫瘠** 判定。
    ///
    /// ⚠️ 不要用「整体体积 < 20KB」这种一刀切前置条件 ——
    ///    实测 `ikanmh.xyz` 的 JS 跳转页有 **38KB**，照样是挑战页。
    ///    但反过来「小页面 + 弱特征就直接判挑战」会**误伤**正常的小页面
    ///    （移动端优化的漫画页常 < 20KB 且含 `location.replace(`）。
    ///    正确做法：**弱特征一律要求「内容贫瘠」**（无 `<a>`/`<img>`），
    ///    这样 38KB 的跳转页（无内容）仍然会被抓到，而正常小页面不会。
    static func looksLikeChallengeHTML(_ html: String) -> Bool {
        guard !html.isEmpty else { return false }
        let low = html.lowercased()
        for m in strongMarkers where low.contains(m) { return true }
        guard weakMarkers.contains(where: { low.contains($0) }) else { return false }
        return isContentPoor(html)
    }

    /// 页面是否「内容贫瘠」。
    /// 正常的漫画列表页/详情页会有大量 `<a>` 和 `<img>`；挑战页/跳转页几乎什么都没有。
    static func isContentPoor(_ html: String) -> Bool {
        var anchors = 0
        var imgs = 0
        var idx = html.startIndex
        while let r = html.range(of: "<a ", range: idx..<html.endIndex) {
            anchors += 1
            if anchors >= 12 { break }
            idx = r.upperBound
        }
        idx = html.startIndex
        while let r = html.range(of: "<img", range: idx..<html.endIndex) {
            imgs += 1
            if imgs >= 6 { break }
            idx = r.upperBound
        }
        return anchors < 12 && imgs < 6
    }

    // MARK: - 过挑战

    /// 正在过挑战的域名（UI 可据此显示「正在通过站点验证…」）
    private static var _solvingHost: String?
    static var solvingHost: String? {
        lock.lock(); defer { lock.unlock() }
        return _solvingHost
    }

    /// 占用「过挑战」标记。返回 true 表示**已有同域名的挑战在进行中**。
    ///
    /// ⚠️ 必须是**同步**函数：`NSLock.lock()` 标了 `@available(*, noasync)`，
    ///    在 async 函数体内直接调用在 Swift 6 下是**编译错误**（不是告警）。
    ///    本项目的 `probe/async_lock.py` 就是扫这个的，它抓出过这一处。
    private static func beginSolving(_ host: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _solvingHost == host { return true }
        _solvingHost = host
        return false
    }

    private static func endSolving() {
        lock.lock(); defer { lock.unlock() }
        _solvingHost = nil
    }

    /// 用 WebView 过挑战。
    ///
    /// - Returns: true 表示挑战已通过，且 **UA 与 Cookie 已回写 CookieStore**
    @discardableResult
    static func solve(url: String, host: String) async -> Bool {
        guard let u = URL(string: url), let h = u.host, !h.isEmpty else { return false }
        let target = host.isEmpty ? h : host

        let already = beginSolving(target)
        defer { endSolving() }
        // 同一域名并发请求时只跑一次挑战（后来的直接等结果）
        if already {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if let p = policy(for: target), p.fresh { return true }
        }

        // ① 把已有 Cookie 注入 WebView，避免重复过挑战
        await WebViewRuleEngine.shared.syncCookiesToWebView(host: target, url: u)

        // ② 加载并等待挑战结束
        let result = await WebViewRuleEngine.shared.passChallenge(url: url)

        guard result.passed else {
            update(target) { $0.blockedCount += 1; $0.lastBlockedAt = Date().timeIntervalSince1970 }
            return false
        }

        // ③ UA 回写（cf_clearance 绑定 UA，这一步不能省）
        if !result.ua.isEmpty {
            CookieStore.setUA(host: target, ua: result.ua)
        }
        // ④ Cookie 回写
        var got: [String] = []
        for (k, v) in result.cookies {
            CookieStore.set(host: target, name: k, value: v)
            got.append(k)
        }
        let hasClearance = got.contains("cf_clearance")
        update(target) {
            $0.needsWebView = true
            $0.lastSolvedAt = Date().timeIntervalSince1970
            $0.solvedCount += 1
            if !result.ua.isEmpty { $0.ua = result.ua }
        }
        // 没有 cf_clearance 也可能是非 Cloudflare 的站点验证 —— 只要页面不再是挑战页就算过
        _ = hasClearance
        return true
    }

    /// 该域名是否「已知需要 WebView」（且会话仍新鲜）
    static func knownNeedsWebView(_ host: String) -> Bool {
        guard let p = policy(for: host) else { return false }
        return p.needsWebView && p.fresh
    }

    /// 供「图源诊断」展示
    static func summary() -> [(host: String, text: String)] {
        lock.lock()
        if cache.isEmpty { loadLocked() }
        let snap = cache
        lock.unlock()
        return snap
            .sorted { $0.value.lastSolvedAt > $1.value.lastSolvedAt }
            .prefix(20)
            .map { (host, p) in
                let ago = Int(Date().timeIntervalSince1970 - p.lastSolvedAt)
                return (host, "过挑战 \(p.solvedCount) 次 · 最近 \(ago / 60) 分钟前 · 被拦 \(p.blockedCount) 次")
            }
    }
}
