import Foundation
import SwiftSoup

/// 域名级「直连 / 代理」路由策略。
///
/// 实测：同一台机器上 `www.yck2026.fun` 走代理 code=000、直连 200，
/// 而 GitHub 反过来。**没有一条通道能通吃**，必须按域名记。
///
/// 策略持久化到 UserDefaults —— 用户下次开 App 就直接选对通道，
/// 不必再付一次「必然失败的首个请求」（慢站上就是 10s 超时）。
enum NetRoute {
    private static let key = "hmd_net_route_direct"
    private static let lock = NSLock()
    private static var map: [String: Bool] = [:]
    private static var loaded = false

    /// 返回 true = 该域名直连可用；false = 需要走系统代理；nil = 未知
    static func decision(_ host: String) -> Bool? {
        guard !host.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        if !loaded { loadLocked() }
        return map[host]
    }

    static func record(_ host: String, direct: Bool) {
        guard !host.isEmpty else { return }
        lock.lock()
        if !loaded { loadLocked() }
        if map[host] == direct { lock.unlock(); return }
        map[host] = direct
        let snap = map
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            UserDefaults.standard.set(snap, forKey: key)
        }
    }

    private static func loadLocked() {
        loaded = true
        if let m = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] { map = m }
    }

    static func clear() {
        lock.lock(); map = [:]; loaded = true; lock.unlock()
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// 已知需要代理的域名数（诊断页展示）
    static var proxyCount: Int {
        lock.lock(); defer { lock.unlock() }
        if !loaded { loadLocked() }
        return map.values.filter { !$0 }.count
    }
    static var directCount: Int {
        lock.lock(); defer { lock.unlock() }
        if !loaded { loadLocked() }
        return map.values.filter { $0 }.count
    }
}

/// 网络层 —— URLSession + Cookie 持久化（对应原版 OkHttp/Cronet + CookieBean）
final class HttpFetcher {
    static let shared = HttpFetcher()
    private let session: URLSession

    // MARK: - 最近一次抓取的 HTTP 状态（供失败归因 / 源级熔断）

    /// `fetchPage` 只返回 String，**状态码被吞掉了** —— 于是上层拿不到
    /// 「403 被拦」「404 地址失效」「503 站点故障」的区别，只能一律当成
    /// 「抓不到」。`SourceBreaker` 需要按原因决定要不要熔断，
    /// 所以这里留一份按 host 的最新状态。
    ///
    /// 约定：`0` = 网络层就失败了（没拿到任何 HTTP 响应），`nil` = 本会话没记录过。
    private var lastStatusByHost: [String: Int] = [:]
    private let statusLock = NSLock()

    func lastStatus(forHost host: String) -> Int? {
        guard !host.isEmpty else { return nil }
        statusLock.lock(); defer { statusLock.unlock() }
        return lastStatusByHost[host.lowercased()]
    }

    private func recordStatus(host: String, _ status: Int) {
        guard !host.isEmpty else { return }
        statusLock.lock()
        // 防止长期运行无限增长；超过 256 个 host 直接清空重来（只是诊断缓存）
        if lastStatusByHost.count > 256 { lastStatusByHost.removeAll(keepingCapacity: true) }
        lastStatusByHost[host.lowercased()] = status
        statusLock.unlock()
    }

    /// ── 直连会话：**显式禁用 HTTP 代理** ──────────────────────────────────
    ///
    /// 为什么需要（实测驱动）：`www.yck2026.fun` 走本机代理返回 **code=000**，
    /// 直连返回 **200**。国内图源被绕到境外代理出口后，反而会被链路或站点拦掉。
    /// 用户反馈的「代理有时候也会失效，有没有什么方法可以不开代理就能进」
    /// 就是这个现象。
    ///
    /// ⚠️ 只能绕过 **HTTP 代理**（`connectionProxyDictionary = [:]`）。
    ///    如果是系统级 VPN（全局隧道），URLSession 无法绕过 —— 那种情况靠
    ///    `DoHResolver` + `RawHttpClient` 的 IP 直连兜底（已有）。
    private let directSession: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 120
        cfg.httpShouldSetCookies = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        // HTTP/2 自动启用；HTTP/3 由系统按 Alt-Svc 协商
        session = URLSession(configuration: cfg)

        let dcfg = URLSessionConfiguration.default
        dcfg.timeoutIntervalForRequest = 60
        dcfg.timeoutIntervalForResource = 120
        dcfg.httpShouldSetCookies = false
        dcfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 空字典 = 不走任何代理（显式声明，覆盖系统代理设置）
        dcfg.connectionProxyDictionary = [:]
        directSession = URLSession(configuration: dcfg)
    }

    /// 按「域名路由策略」发一次请求：已知直连可用就走直连，否则先试系统配置。
    /// 失败时自动切换另一条通道，并把结果记下来供下次直接选对。
    private func performWithRoute(_ req: URLRequest, host: String) async -> (Data, URLResponse?) {
        let known = NetRoute.decision(host)
        // 未知时**先直连** —— 国内图源占多数，直连成功率高且少一次绕行
        let preferDirect = (known ?? true)
        let first = preferDirect ? directSession : session
        let second = preferDirect ? session : directSession
        do {
            let (d, r) = try await first.data(for: req)
            if !d.isEmpty {
                NetRoute.record(host, direct: preferDirect)
                return (d, r)
            }
        } catch { /* 落到第二条通道 */ }
        do {
            let (d, r) = try await second.data(for: req)
            if !d.isEmpty {
                NetRoute.record(host, direct: !preferDirect)
                return (d, r)
            }
        } catch { }
        return (Data(), nil)
    }

    func fetchText(_ url: String, method: String = "GET", body: String? = nil, headers: [String: String] = [:], timeout: TimeInterval? = nil) async -> String {
        let data = await fetchData(url, method: method, body: body, headers: headers, timeout: timeout)
        return decode(data)
    }

    // MARK: - 反反爬（分级升级链）

    /// 抓「页面」文本。**分级升级**，只在失败路径上升级，正常页面零额外开销：
    ///
    /// ```
    /// L0 URLSession 直连（带 Cookie + 与 WebView 一致的 UA + 浏览器指纹头）
    ///   ↓ 403 + cf-mitigated:challenge ‖ 挑战页 HTML 特征
    /// L1 WebView 过挑战（真正执行挑战 JS）→ 拿到 cf_clearance + UA → 回写 CookieStore
    ///   ↓
    /// L2 用新 Cookie/UA 重试 URLSession（多数站点到此结束）
    ///   ↓ 仍失败（如需人机交互的 hCaptcha）
    /// L3 直接返回 WebView 渲染后的 HTML（绕过 HTTP 层）
    /// ```
    ///
    /// ── 为什么必须做（2026-10 实测定位到的系统性根因）────────────────────
    /// 内置 501 个启用源里，「站点活着但列表解析 0 条」有 165 个。
    /// 抽查 14 个，**8 个是反爬/挑战页**（Cloudflare `Just a moment` /
    /// `__cf_chl` / `Enable JavaScript and cookies`）。
    /// URLSession 拿到的是**挑战页 HTML**（2~6KB），规则自然一条都匹配不到 ——
    /// 用户看到「这个源不能用」，实际是**页面根本没拿到**。
    ///
    /// ⚠️ 三个关键约束（都有实测依据）：
    ///   ① WebView 只能发 GET → POST 接口不走兜底，
    ///      否则会「用 GET 重取 POST 地址」拿到完全不同的页面；
    ///   ② 挑战页**绝不返回给调用方** —— 它一旦被 `ResponseCache` 当成
    ///      「有效详情页」缓存 2 小时，用户这段时间怎么刷都是 0 章且看不出原因；
    ///   ③ 过挑战后必须**同时**回写 UA 和 Cookie（`cf_clearance` 绑定 UA）。
    func fetchPage(_ url: String, method: String = "GET", body: String? = nil,
                   headers: [String: String] = [:],
                   timeout: TimeInterval = 30) async -> String {
        let host = URL(string: url)?.host ?? ""
        let isGet = method.uppercased() == "GET"
        let httpLike = url.lowercased().hasPrefix("http")

        // ── 已知该域名需要过挑战：直接走 WebView，省掉一次必然失败的请求 ──
        if isGet, httpLike, AntiBot.knownNeedsWebView(host) {
            if let r = await renderViaWebView(url: url) { return r }
            // 会话过期 → 清掉策略，落回 L0 重来
            AntiBot.update(host) { $0.lastSolvedAt = 0 }
        }

        // ── L0 ──
        var (data, resp) = await fetchDataWithResponse(url, method: method, body: body,
                                                       headers: headers, timeout: timeout)
        recordStatus(host: host, resp?.statusCode ?? 0)
        var html = decode(data, charsetHint: Self.charsetFromContentType(
            (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")))
        if !AntiBot.isChallenge(status: resp?.statusCode ?? 0,
                                headers: headerMap(resp), body: html) {
            // 🔴 「极短响应」也是一种拦截：真机日志里 manhua3 的发现页只回了 **39 字**
            //    （`⚠️ 解析为空：html 39 字`），它不是标准挑战页特征，于是被当成
            //    正常 HTML 返回 → 解析 0 条 → 用户看到「这个源没内容」。
            //    正常列表页不可能 < 500 字，这里统一按「疑似拦截」升级 WebView。
            let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
            let isJSONish = trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
            if isGet, httpLike, !isJSONish, trimmed.count < 500 {
                DiagLog.event("fetch", "short",
                              "疑似拦截页 \(trimmed.count) 字（\(DiagLog.safeURL(url))）：\(trimmed.prefix(100))")
                if let r = await renderViaWebView(url: url), r.count > trimmed.count {
                    return r
                }
            }
            return html
        }
        guard isGet, httpLike else { return html }   // POST 不升级

        // ── L1 过挑战 ──
        let solved = await AntiBot.solve(url: url, host: host)
        if solved {
            // ── L2 用新 Cookie/UA 重试 ──
            (data, resp) = await fetchDataWithResponse(url, method: method, body: body,
                                                       headers: headers, timeout: timeout)
            recordStatus(host: host, resp?.statusCode ?? 0)
            html = decode(data, charsetHint: Self.charsetFromContentType(
                (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")))
            if !AntiBot.isChallenge(status: resp?.statusCode ?? 0,
                                    headers: headerMap(resp), body: html) {
                return html
            }
        }

        // ── L3 直接返回 WebView 渲染结果 ──
        if let r = await renderViaWebView(url: url) { return r }

        // 全链失败 → 返回空串（绝不返回挑战页，见约束 ②）
        DiagLog.event("fetch", "fail",
                      "全链失败 \(DiagLog.safeURL(url)) status=\(resp?.statusCode ?? -1) bytes=\(data.count)")
        return ""
    }

    /// L3：用 WebView 渲染并返回 HTML/JSON（失败返回 nil）
    private func renderViaWebView(url: String) async -> String? {
        let rendered = await WebViewRuleEngine.shared.fetchRendered(url: url)
        guard !rendered.isEmpty, !AntiBot.looksLikeChallengeHTML(rendered) else { return nil }
        // ⚠️ JSON 接口经 WebView 后会被包成
        //    `<html><body><pre>{"…":…}</pre></body></html>`，
        //    直接返回会让 `isJson` 判定失败、整条 JSON 规则链报废。
        if let json = Self.unwrapPreJSON(rendered) { return json }
        return rendered
    }

    /// 响应头 → 大小写不敏感字典
    private func headerMap(_ resp: HTTPURLResponse?) -> [String: String] {
        guard let resp else { return [:] }
        var m: [String: String] = [:]
        for (k, v) in resp.allHeaderFields {
            m["\(k)"] = "\(v)"
        }
        return m
    }

    /// 把 WebView 渲染 JSON 接口得到的 `<pre>{…}</pre>` 还原成裸 JSON
    static func unwrapPreJSON(_ html: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "<pre[^>]*>([\\s\\S]*?)</pre>",
                                                options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        guard let m = re.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var inner = ns.substring(with: m.range(at: 1))
        // HTML 实体还原（JSON 里常见 &quot; &amp; &lt; &gt; &#39;）
        let ents = ["&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<",
                    "&gt;": ">", "&amp;": "&"]
        for (k, v) in ents { inner = inner.replacingOccurrences(of: k, with: v) }
        let t = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t.hasPrefix("{") || t.hasPrefix("[")) ? t : nil
    }

    func fetchJson(_ url: String, method: String = "GET", body: String? = nil, headers: [String: String] = [:], timeout: TimeInterval? = nil) async -> Any? {
        let data = await fetchData(url, method: method, body: body, headers: headers, timeout: timeout)
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// 合并请求显式 Cookie（图源 header）与 CookieStore Cookie。
    /// 同名 Cookie 去重，显式值优先；这样登录态/源自带验证 Cookie 不会互相覆盖。
    private func mergedCookieHeader(host: String, explicit: [String: String]) -> String {
        var values: [String: String] = [:]
        func add(_ raw: String) {
            for part in raw.split(separator: ";") {
                let item = part.trimmingCharacters(in: .whitespaces)
                guard let eq = item.firstIndex(of: "=") else { continue }
                let name = item[..<eq].trimmingCharacters(in: .whitespaces)
                let value = item[item.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { values[String(name)] = String(value) }
            }
        }
        // Store 先加，源 header 后加 → 源值优先
        add(CookieStore.header(host: host))
        if let sourceCookie = explicit.first(where: { $0.key.caseInsensitiveCompare("Cookie") == .orderedSame }) {
            add(sourceCookie.value)
        }
        return values.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    /// 单次响应体的**硬上限**（2026-10-19 安全加固）。
    ///
    /// 为什么需要：站点（或被劫持的 DNS / 中间人）返回一个几百 MB 的响应时，
    ///   ① `URLSession` 会把它整个读进内存 → 内存暴涨；
    ///   ② 更致命的是后续**正则在几百 MB 的字符串上跑**，CPU 直接打满、App 卡死。
    ///   正常漫画站 HTML 1~2MB，漫画 JSON 也远小于此，16MB 足够宽松。
    static let maxResponseBytes = 16 * 1024 * 1024

    func fetchData(_ url: String, method: String = "GET", body: String? = nil, headers: [String: String] = [:], timeout: TimeInterval? = nil) async -> Data {
        await fetchDataWithResponse(url, method: method, body: body, headers: headers, timeout: timeout).data
    }

    /// 与 `fetchData` 相同，但**同时返回响应**（状态码 + 响应头）。
    ///
    /// 为什么需要：反爬判定必须看响应头 —— Cloudflare 挑战的权威标记是
    /// `cf-mitigated: challenge`（HTTP 403）。旧实现只返回 `Data`，
    /// 把响应头丢了，只能靠嗅 HTML，误报率高。见 `AntiBot`。
    func fetchDataWithResponse(_ url: String, method: String = "GET", body: String? = nil,
                               headers: [String: String] = [:],
                               timeout: TimeInterval? = nil) async -> (data: Data, response: HTTPURLResponse?) {
        guard let u = URL(string: url) else { return (Data(), nil) }
        var req = URLRequest(url: u)
        req.httpMethod = method
        if let timeout { req.timeoutInterval = timeout }
        let host = u.host ?? ""
        // UA：显式 > 源配置 > 全局。
        // ⚠️ `CookieStore.ua(host:)` 存的是**过挑战时 WebView 的真实 UA** ——
        //    `cf_clearance` 与 UA 绑定，这里必须优先用它，否则挑战白过。
        var hh = headers
        if hh["User-Agent"] == nil, let cookieUA = CookieStore.ua(host: host) { hh["User-Agent"] = cookieUA }
        if hh["User-Agent"] == nil { hh["User-Agent"] = AppSettings.shared.httpUA }
        // 浏览器指纹补全：很多站点会校验 Sec-Fetch-* / Accept-Encoding 的一致性
        if hh["Accept"] == nil {
            hh["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"
        }
        if hh["Accept-Language"] == nil { hh["Accept-Language"] = "zh-CN,zh;q=0.9,en;q=0.8" }
        if hh["Sec-Fetch-Mode"] == nil, method.uppercased() == "GET" {
            hh["Sec-Fetch-Mode"] = "navigate"
            hh["Sec-Fetch-Dest"] = "document"
            hh["Sec-Fetch-Site"] = "none"
            hh["Upgrade-Insecure-Requests"] = "1"
        }
        for (k, v) in hh { req.setValue(v, forHTTPHeaderField: k) }
        // Cookie 注入：**合并**源 header 里的 Cookie 与 CookieStore。
        //
        // 🔴 不能让 CookieStore 整体覆盖源 header：卡拉漫画的验证令牌
        //    `omo_token` 是源里声明的，而 WKWebView 捕获的 Cookie 里可能只有
        //    cf_clearance / tracker；整体覆盖会把 omo_token 丢掉 → 验证页 →
        //    `fetchPage` 全链返回空 → 发现页「该栏目暂无内容」。
        //    规则/源的 Cookie 与网页登录 Cookie 应该按名字合并，源显式值优先。
        let cookie = mergedCookieHeader(host: host, explicit: hh)
        if !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let b = body { req.httpBody = Data(b.utf8) }

        do {
            let (rawData, resp) = await performWithRoute(req, host: host)
            // 🔴 响应体上限（见 `maxResponseBytes`）：超限截断并记诊断，
            //    避免「内存暴涨 + 正则在巨串上跑」把 App 卡死。
            var data = rawData
            if data.count > Self.maxResponseBytes {
                DiagLog.event("net", "oversize",
                              "响应体 \(data.count / 1_048_576)MB 超上限，已截断：\(url.prefix(60))")
                data = Data(data.prefix(Self.maxResponseBytes))
            }
            // 🔴 302/301 重定向**终址复检** —— `URLSession` 默认自动跟重定向，
            //    而 `JsoupConn.isAllowed` 只校验**初始 URL**：`https://allowed.com`
            //    302 到 `https://evil.com` 时，evil 的响应体会原样返回给 JS 脚本
            //    （白名单被完全绕过，甚至能把已登录站点的内容带到外域）。
            //    这里对终址再跑一遍「恒拒绝清单」，命中就**丢弃结果**。
            //    （由智能体「安全终审」发现）
            if let http = resp as? HTTPURLResponse, let finalURL = http.url {
                if JsoupConn.isDeniedAlways(finalURL.absoluteString) {
                    DiagLog.event("net", "redirect",
                                  "⚠️ 重定向终址命中恒拒绝清单，已丢弃响应：\(url.prefix(50)) → \(finalURL.absoluteString.prefix(50))")
                    return (Data(), nil)
                }
            }
            // 存响应 Cookie
            if let http = resp as? HTTPURLResponse, let set = http.value(forHTTPHeaderField: "Set-Cookie") ?? allCookies(resp) {
                CookieStore.parseAndStore(host: host, setCookie: set)
            }
            return (data, resp as? HTTPURLResponse)
        } catch let err as URLError {
            // DoH 兜底：仅 DNS 污染/连接失败类错误触发；只接受 200 且非空结果（避免拿重定向页当数据）
            let retriable: [URLError.Code] = [.cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .timedOut]
            if DoHResolver.isEnabled, retriable.contains(err.code),
               let ip = await DoHResolver.resolve(host), let u2 = URL(string: url) {
                if let (data, status) = await RawHttpClient.request(u2, ip: ip, method: method,
                                                                    body: body.flatMap { Data($0.utf8) }, headers: hh),
                   status == 200, !data.isEmpty {
                    return (data, nil)
                }
            }
            return (Data(), nil)
        } catch {
            return (Data(), nil)
        }
    }

    /// ⚠️ 参数必须接受可选 —— 走路由后响应是 `(Data, URLResponse?)`，
    ///    非可选签名会让 CI 报 "value of optional type must be unwrapped"。
    private func allCookies(_ resp: URLResponse?) -> String? {
        guard let http = resp as? HTTPURLResponse else { return nil }
        let pairs = (200..<300).compactMap { http.allHeaderFields[$0] as? String }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }

    /// 字节 → 文本。
    ///
    /// ⚠️ 原先的实现是「UTF-8 能解就用 UTF-8 → 再试 GBK → 再试 Big5」的**盲试**，
    ///    有两个真实缺陷：
    ///    ① **不看 `Content-Type` / `<meta charset>`** —— 而绝大多数漫画站都在
    ///       `<meta>` 里声明了编码，这是**最可靠**的线索却没用上；
    ///    ② 盲试顺序会错判：GBK/Big5 页面若字节序列恰好是**合法 UTF-8**
    ///       （短英文页、数字标点为主的页很常见），会在第一步被「成功」解出乱码，
    ///       永远走不到 GBK 分支；而 GBK 排在 Big5 前面，Big5 页若字节合法 GBK
    ///       就会被解成 GBK 乱码。
    ///    兜底的 `isoLatin1` 更是**永不失败**（任何字节都能解码），
    ///    所以调用方永远无法感知解码失败，乱码会当正常内容一路传下去。
    ///
    /// 现在的顺序：**显式提示 → BOM → 页面内声明的 charset → UTF-8 → GBK → Big5**。
    func decode(_ data: Data, charsetHint: String? = nil) -> String {
        if let name = charsetHint, let e = Self.encoding(named: name),
           let s = String(data: data, encoding: e) { return s }
        // BOM
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let s = String(data: data.dropFirst(3), encoding: .utf8) { return s }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16) { return s }
        // 页面内声明的 charset（HTML `<meta>` / XML `encoding=`，前 4KB 足够）
        if let declared = Self.sniffDeclaredCharset(data),
           let e = Self.encoding(named: declared),
           let s = String(data: data, encoding: e) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .gbk) { return s }
        if let s = String(data: data, encoding: Self.big5) { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// Big5（含 HKSCS 扩展）
    static let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(UInt32(CFStringEncodings.big5_HKSCS_1999.rawValue))))

    /// charset 名 → `String.Encoding`（不认识返回 nil，由调用方继续兜底）
    static func encoding(named name: String) -> String.Encoding? {
        let n = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch n {
        case "utf-8", "utf8":                     return .utf8
        case "gbk", "gb2312", "gb18030", "x-gbk": return .gbk
        case "big5", "big-5", "big5-hkscs":       return big5
        case "iso-8859-1", "latin1":              return .isoLatin1
        case "utf-16", "utf16":                   return .utf16
        default:                                  return nil
        }
    }

    /// 从响应头 `Content-Type: text/html; charset=gbk` 里取 charset
    static func charsetFromContentType(_ value: String?) -> String? {
        guard let v = value else { return nil }
        guard let r = v.range(of: "charset\\s*=\\s*[\"']?([A-Za-z0-9_\\-]+)",
                              options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(v[r]).components(separatedBy: "=").last?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }

    /// 从 HTML/XML 头部嗅探声明的 charset（`<meta charset=gbk>` /
    /// `<meta http-equiv=Content-Type content="text/html; charset=gbk">` /
    /// `<?xml version="1.0" encoding="gbk"?>`）。
    ///
    /// 用 `isoLatin1` 把字节当单字节读 —— 它**永不失败**，正好用来做纯 ASCII 嗅探。
    static func sniffDeclaredCharset(_ data: Data) -> String? {
        guard let head = String(data: data.prefix(4096), encoding: .isoLatin1) else { return nil }
        guard let r = head.range(of: "charset\\s*=\\s*[\"']?([A-Za-z0-9_\\-]+)",
                                 options: [.regularExpression, .caseInsensitive]) else { return nil }
        let seg = String(head[r])
        guard let eq = seg.firstIndex(of: "=") else { return nil }
        let v = seg[seg.index(after: eq)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        return v.isEmpty ? nil : v
    }

    /// 解析 HTML 为 SwiftSoup Document
    func parseHtml(_ html: String, baseUrl: String) -> Document? {
        try? SwiftSoup.parse(html, baseUrl)
    }

    // MARK: - 带失败原因的诊断抓取

    /// 抓取结果 —— 区分「拿到了什么」与「为什么没拿到」。
    ///
    /// ── 为什么需要它 ────────────────────────────────────────────────────
    /// `fetchText` / `fetchData` 为兼容旧调用点，把**所有**错误都吞成空值。
    /// 但对「章节解析为 0」这个用户可见故障来说，空值有两种截然不同的成因：
    ///   1. **网络层**：DNS 污染 / 连不上 / TLS 握手失败 / 超时 / 非 2xx
    ///      → 用户挂了梯子仍失败，多半是这一类（尤其 App 未走代理时）。
    ///   2. **规则层**：页面确实拿到了，但 `ruleChapterList` 选择器没匹配上
    ///      → 这是图源规则与站点改版不匹配。
    /// 以前两种情况都显示同一句含糊提示，用户无从下手。现在把它分开。
    enum FetchOutcome {
        case ok(String)
        case httpError(Int)
        case networkError(String)
        case emptyBody
    }

    /// 抓文本并保留失败原因（诊断专用；正常业务路径仍走 `fetchText`）
    func fetchTextDiagnosed(_ url: String, headers: [String: String] = [:],
                            timeout: TimeInterval? = nil) async -> FetchOutcome {
        guard let u = URL(string: url) else { return .networkError("URL 非法：\(url)") }
        var req = URLRequest(url: u)
        if let timeout { req.timeoutInterval = timeout }
        let host = u.host ?? ""
        var hh = headers
        if hh["User-Agent"] == nil, let cookieUA = CookieStore.ua(host: host) { hh["User-Agent"] = cookieUA }
        if hh["User-Agent"] == nil { hh["User-Agent"] = AppSettings.shared.httpUA }
        for (k, v) in hh { req.setValue(v, forHTTPHeaderField: k) }
        let cookie = mergedCookieHeader(host: host, explicit: hh)
        if !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .emptyBody }
            if http.statusCode < 200 || http.statusCode >= 300 {
                return .httpError(http.statusCode)
            }
            let text = decode(data)
            return text.isEmpty ? .emptyBody : .ok(text)
        } catch let err as URLError {
            return .networkError(Self.describe(err))
        } catch {
            return .networkError(error.localizedDescription)
        }
    }

    /// 把 URLError 翻成用户能看懂、能据此行动的一句话
    static func describe(_ err: URLError) -> String {
        switch err.code {
        case .notConnectedToInternet: return "设备无网络连接"
        case .cannotFindHost, .dnsLookupFailed:
            return "域名解析失败（该站可能被 DNS 污染，请开启代理）"
        case .cannotConnectToHost: return "无法连接到服务器（端口被阻断，或需要代理）"
        case .timedOut: return "连接超时（站点慢或被限速，可换节点重试）"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .clientCertificateRejected:
            return "TLS 证书校验失败（可能被中间人劫持，或系统时间不准）"
        case .networkConnectionLost: return "连接被中断（代理不稳定）"
        case .cancelled: return "请求被取消"
        case .appTransportSecurityRequiresSecureConnection:
            return "被 ATS 拦截（站点是 HTTP 且未加例外）"
        default: return "\(err.localizedDescription)（代码 \(err.errorCode)）"
        }
    }
}

/// Cookie/UA 按源存储（对应 CookieBean）
enum CookieStore {
    private static var map: [String: [String: String]] = [:]
    private static var uaMap: [String: String] = [:]
    private static let lock = NSLock()

    /// Cookie 在 Keychain 里的键（整个 map 序列化成一个 blob）
    private static let kcKey = "cookieStoreBlob"

    /// 🔴 加固第 4 重：Cookie（含登录态 `omo_token`）**原本明文存在
    ///    `COOKIE_BEAN` 表**里 —— 越狱设备 / iTunes 备份能直接读到，
    ///    等于把用户登录态交出去。现在改存 **Keychain**（系统级加密）。
    ///
    /// 兼容性：首次启动时若 Keychain 为空、而旧表有数据 → **迁移**过来，
    /// 然后立刻 `DELETE` 旧表，确保明文不残留（只搬不删等于没修）。
    static func load() {
        // ① 优先 Keychain（新路径）
        if let blob = KeychainStore.get(kcKey),
           let data = Data(base64Encoded: blob),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] {
            lock.lock(); defer { lock.unlock() }
            for (url, cookies) in obj {
                var c: [String: String] = [:]
                for (k, v) in cookies where k != "User-Agent" { c[k] = v }
                map[url] = c
                if let ua = cookies["User-Agent"] { uaMap[url] = ua }
            }
            return
        }

        // ② 旧明文表 → 迁移
        let d = Database.shared.query("SELECT url, variable_str FROM COOKIE_BEAN")
        guard !d.isEmpty else { return }
        lock.lock()
        for row in d {
            if let url = row["url"] as? String, let s = row["variable_str"] as? String,
               let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: String] {
                var cookies: [String: String] = [:]
                for (k, v) in obj where k != "User-Agent" { cookies[k] = v }
                map[url] = cookies
                if let ua = obj["User-Agent"] { uaMap[url] = ua }
            }
        }
        lock.unlock()
        save()                                            // 写入 Keychain
        Database.shared.exec("DELETE FROM COOKIE_BEAN")    // 抹掉明文残留
        DiagLog.event("cookie", "migrate", "Cookie 已从明文表迁入 Keychain（旧数据已清除）")
    }

    static func save() {
        lock.lock(); defer { lock.unlock() }
        var obj: [String: [String: String]] = [:]
        for (url, cookies) in map {
            var c = cookies
            if let ua = uaMap[url] { c["User-Agent"] = ua }
            obj[url] = c
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        // 只写 Keychain，**不再**落明文数据库表
        KeychainStore.set(data.base64EncodedString(), forKey: kcKey)
    }

    static func header(host: String) -> String {
        lock.lock(); defer { lock.unlock() }
        guard let cookies = map[host], !cookies.isEmpty else { return "" }
        return cookies.map { "\($0)=\($1)" }.joined(separator: "; ")
    }
    static func get(host: String, name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return map[host]?[name]
    }
    static func set(host: String, name: String, value: String) {
        lock.lock(); defer { lock.unlock() }
        map[host, default: [:]][name] = value
        scheduleSave()
    }
    static func ua(host: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return uaMap[host]
    }
    static func setUA(host: String, ua: String) {
        lock.lock(); defer { lock.unlock() }
        uaMap[host] = ua
        scheduleSave()
    }

    /// 落盘串行队列 + 合并标记 —— 一批 `Set-Cookie` 只落盘一次。
    ///
    /// ⚠️ 为什么不能直接 `DispatchQueue.global().async { save() }`：
    ///    `parseAndStore` 会对一个 `Set-Cookie` 里的**每个键**各调一次 `set`，
    ///    每次 `set` 派一个独立的全局异步任务 → N 个任务并发做
    ///    「`DELETE FROM COOKIE_BEAN` + 全量重插」，IO 被放大 N 倍、还互相抢锁。
    ///    正确性本身没问题（`save()` 在锁内取快照，不会写旧值覆盖新值），
    ///    但 IO 放大是实打实的浪费，且与「详情页 + 章节页并行抓取」叠加时更明显。
    private static let saveQueue = DispatchQueue(label: "hmd.cookiestore.save")
    private static var savePending = false

    /// 请求一次落盘（调用方**必须已持有 `lock`**）。
    private static func scheduleSave() {
        if savePending { return }      // 已有待执行的落盘 → 合并掉
        savePending = true
        saveQueue.async {
            lock.lock()
            savePending = false
            lock.unlock()
            save()
        }
    }

    static func parseAndStore(host: String, setCookie: String) {
        for part in setCookie.components(separatedBy: "\n") {
            let kv = part.split(separator: ";").first.map(String.init) ?? ""
            let bits = kv.split(separator: "=", maxSplits: 1).map(String.init)
            if bits.count == 2 {
                set(host: host, name: bits[0].trimmingCharacters(in: .whitespaces), value: bits[1].trimmingCharacters(in: .whitespaces))
            }
        }
    }
}
