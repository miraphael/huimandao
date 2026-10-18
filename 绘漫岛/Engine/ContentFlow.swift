import Foundation

/// ──────────────────────────────────────────────────────────────────────────
/// 万能图源解析引擎 · 声明式「多步内容流」
///
/// ## 它解决什么问题
/// 像**卡拉漫画**这类站点，正文图片藏在一个「多级挑战流」后面：
///
///     章节页 HTML ──抽 hex──▶ L1 接口 ──抽动态 token──▶ L2 阅读器页 ──抽 data-src──▶ 图片
///
/// 这种「抽 A → 用 A 拼 URL → 抽 B → 用 B 拼 URL → 出图」的流水线，
/// 光靠一条 `ruleBookContent` 正则/JS 规则表达不了；更糟的是在 iOS 上
/// JavaScriptCore 的 `java.get(url,{headers})` 桥接常返回空，导致 JS 规则真机失灵。
///
/// 以前的做法是给 `ComicEngine` 写一段 `if bookSourceUrl.contains("kalamanhua.com")`
/// 的硬编码原生补丁——**每多一个这种站就要改一次 Swift 代码、重新发版**。
///
/// ## 本引擎的做法
/// 把整条流水线写成图源 JSON 里的一个数组 `ruleContentFlow`，引擎**解释执行**：
///
/// ```json
/// "ruleContentFlow": [
///   { "input": "chapterHtml",
///     "extract": { "hex": "\"url\"\\s*:\\s*\"([0-9a-f]{32,})\"" } },
///   { "request": { "url": "https://image.kalaimg.top/play/min/{hex}",
///                  "headers": { "User-Agent": "{ua}", "Referer": "{chapterUrl}" } } },
///   { "input": "response",
///     "extract": { "token": "token\\s*=\\s*['\"]([^'\"]+)['\"]" } },
///   { "request": { "url": "https://image.kalaimg.top/play/min/{hex}?cf_verify={token:urlenc}",
///                  "headers": { "User-Agent": "{ua}", "Referer": "{chapterUrl}",
///                               "Cookie": "omo_token={token}" } } },
///   { "input": "response",
///     "select": { "regex": "data-src\\s*=\\s*['\"]([^'\"]+)['\"]",
///                 "base": "https://image.kalaimg.top" } }
/// ]
/// ```
///
/// - 引擎用 `HttpFetcher` **原生**发请求（不走 JS 桥），真机稳定。
/// - 任何新站只要在自己的 JSON 里写一段 `ruleContentFlow` 即可，**零 Swift 改动、零发版**。
/// - 没有该字段的源完全不受影响（见 `ComicEngine.contentFlow`）。
///
/// ## 一步（Step）的结构
/// 一个 step 按顺序可做：
///   ① `set`     字面量赋值（支持 `{var}` 替换）—— 预置常量变量
///   ② `extract` 从当前输入文本里按正则抽变量（取第 1 捕获组）
///   ③ `request` 发一次 HTTP 请求；响应成为下一步的「输入文本」
///   ④ `select`  从当前输入文本里出图片列表 —— 命中即整条 flow 成功返回
/// 任一步的 `extract` 没匹配到、或 `request` 返回空，整条 flow 立即失败（返回空），
/// 调用方据此降级到「规则 → 万用兜底」。
///
/// 内置可用变量：`{chapterUrl}` `{origin}` `{referer}`(源根) `{ua}`；外加源 `header` 里的基础
/// Cookie（变量名 `{sourceCookie}`）。变量还可写 `{name:urlenc}` 做 URL 百分号编码。
/// ──────────────────────────────────────────────────────────────────────────
/// 图源 JSON `ruleContentFlow` 里的一步（顶层类型，便于 `ComicSource.ruleContentFlow` 直接引用）。
struct ContentFlowStep: Codable, Hashable {
    var input: String? = nil            // chapterHtml | response | chapterUrl | source（默认 response）
    var extract: [String: String]? = nil // 变量名 -> 正则（取第 1 捕获组）
    var set: [String: String]? = nil      // 字面量赋值（支持 {var} 替换）
    var request: Request? = nil
    var select: Select? = nil

    struct Request: Codable, Hashable {
        var url: String
        var method: String? = "GET"
        var headers: [String: String]? = nil
        var cookie: String? = nil         // 单独写，便于与源 header 的 Cookie 合并
    }
    struct Select: Codable, Hashable {
        var regex: String? = nil          // 在输入文本上跑正则，收集第 1 捕获组
        var rule: String? = nil           // legado 规则（AnalyzeRule），取图片列表
        var base: String? = nil           // 相对图地址的解析基址；默认上一请求 URL
        /// **生成式**出图：模板里的 `{i}` 会被 1...count 依次替换。
        /// 用于「正文图是 JS 拼出来的」站点（HTML 里根本没有 `<img src>`），
        /// 例如 W漫画：`var num=eval("54"); var pasd="…/"; pasd + i + ".webp"`。
        var template: String? = nil
        /// 张数（支持 `{num}` 这类变量引用）
        var count: String? = nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input   = try? c.decodeIfPresent(String.self, forKey: .input)
        extract = try? c.decodeIfPresent([String: String].self, forKey: .extract)
        set     = try? c.decodeIfPresent([String: String].self, forKey: .set)
        request = try? c.decodeIfPresent(Request.self, forKey: .request)
        select  = try? c.decodeIfPresent(Select.self, forKey: .select)
    }
    private enum CodingKeys: String, CodingKey {
        case input, extract, set, request, select
    }
}
enum ContentFlowEngine {


    // MARK: - 主入口

    /// 运行整条 flow。
    /// - Parameters:
    ///   - flow: 图源里的 `ruleContentFlow`
    ///   - chapterHtml: 已抓到的章节页 HTML（首步 `input: chapterHtml` 用，避免重复请求）
    ///   - chapterUrl: 章节页 URL
    ///   - source: 图源（提供 UA / 默认 Referer / 全局 header）
    /// - Returns: `(urls, headers)`。`urls` 为空表示 flow 没跑通，调用方应降级。
    static func run(_ flow: [ContentFlowStep], chapterHtml: String, chapterUrl: String,
                    source: ComicSource) async -> (urls: [String], headers: [String: String]) {
        var vars: [String: String] = [
            "chapterUrl": chapterUrl,
            "origin": source.bookSourceUrl,
            "referer": source.bookSourceUrl,
            "ua": source.httpUserAgent ?? AppSettings.shared.httpUA,
        ]
        // 源全局 header（如有的基础 Cookie / 固定 UA）作为默认请求头与默认变量
        var baseHeaders: [String: String] = [:]
        if let lines = Self.parseHeaderLines(source.header) {
            for (k, v) in lines {
                baseHeaders[k] = v
                if k.lowercased() == "cookie" { vars["sourceCookie"] = v }
            }
        }

        var context = chapterHtml          // 当前「输入文本」
        var lastResponseUrl: String? = nil
        var lastHeaders: [String: String] = [:]

        for (idx, step) in flow.enumerated() {
            // ① 选输入文本
            let input = step.input
                ?? (idx == 0 && step.extract != nil ? "chapterHtml" : "response")
            switch input {
            case "chapterHtml": context = chapterHtml
            case "chapterUrl":  context = chapterUrl
            case "source":      context = source.bookSourceUrl
            case "response", "": break                      // 沿用上一步响应
            default: break
            }

            // ② 字面量赋值（支持 {var} 替换）
            if let set = step.set {
                for (k, v) in set { vars[k] = Self.substitute(v, vars: vars) }
            }

            // ③ extract：从当前输入抽变量
            if let extract = step.extract {
                for (name, pattern) in extract {
                    guard let val = Self.firstMatch(pattern, in: context) else {
                        DiagLog.event("flow", "extract",
                                      "步骤\(idx) 提取 [\(name)] 失败 → 整条 flow 中断")
                        return ([], [:])
                    }
                    vars[name] = val
                }
            }

            // ④ request：发请求，响应成为新的输入文本
            if let req = step.request {
                let url = Self.substitute(req.url, vars: vars)
                guard !url.isEmpty else {
                    DiagLog.event("flow", "request", "步骤\(idx) URL 为空 → flow 中断")
                    return ([], [:])
                }
                var hdrs = baseHeaders
                if let h = req.headers {
                    for (k, v) in h where !v.isEmpty { hdrs[k] = Self.substitute(v, vars: vars) }
                }
                if let ck = req.cookie, !ck.isEmpty {
                    hdrs["Cookie"] = Self.mergeCookie(hdrs["Cookie"], Self.substitute(ck, vars: vars))
                }
                let resp = await HttpFetcher.shared.fetchText(url, headers: hdrs, timeout: 20)
                guard !resp.isEmpty else {
                    DiagLog.event("flow", "request", "步骤\(idx) 请求空响应 → flow 中断：\(DiagLog.safeURL(url))")
                    return ([], [:])
                }
                context = resp
                lastResponseUrl = url
                lastHeaders = hdrs
            }

            // ⑤ select：出图片 —— 命中即整条 flow 成功
            if let sel = step.select {
                let base = sel.base ?? lastResponseUrl ?? source.bookSourceUrl
                var urls: [String] = []
                if let regex = sel.regex, !regex.isEmpty {
                    for m in Self.allMatches(regex, in: context) where !m.isEmpty {
                        if m.hasPrefix("data:") { continue }
                        let abs = Self.resolve(m, base: base)
                        if !urls.contains(abs) { urls.append(abs) }
                    }
                } else if let tpl = sel.template, !tpl.isEmpty,
                          let cntRaw = sel.count,
                          let n = Int(Self.substitute(cntRaw, vars: vars)
                                      .trimmingCharacters(in: .whitespacesAndNewlines)),
                          n > 0 {
                    // 生成式：按模板逐张拼地址（1...n）。上限 500 张，防正则抽错时失控。
                    var v = vars
                    for i in 1...min(n, 500) {
                        v["i"] = String(i)
                        let u = Self.substitute(tpl, vars: v)
                        let abs = u.hasPrefix("http") ? u : Self.resolve(u, base: base)
                        if !urls.contains(abs) { urls.append(abs) }
                    }
                } else if let rule = sel.rule, !rule.isEmpty {
                    let a = AnalyzeRule(baseUrl: base)
                    let t = context.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.hasPrefix("{") || t.hasPrefix("[") { a.setJson(context, baseUrl: base) }
                    else { a.setDocument(html: context, baseUrl: base) }
                    for u in await a.getStringList(rule) where !u.isEmpty {
                        let abs = u.hasPrefix("http") ? u : Self.resolve(u, base: base)
                        if !urls.contains(abs) { urls.append(abs) }
                    }
                }
                if !urls.isEmpty {
                    var out = lastHeaders
                    // 图片的 Referer 用「嵌它的那一页」最稳（很多 CDN 据此防盗链）
                    if let ru = lastResponseUrl { out["Referer"] = ru }
                    DiagLog.event("flow", "select", "ruleContentFlow 命中 \(urls.count) 张图")
                    return (urls, out)
                }
                DiagLog.event("flow", "select", "步骤\(idx) 未选出图片 → flow 中断")
                return ([], [:])
            }
        }
        // 跑完仍没有任何 select 步骤
        return ([], [:])
    }

    // MARK: - 工具

    /// `{name}` 替换为变量值；`{name:urlenc}` 做 URL 百分号编码。
    /// 变量不存在时原样保留，避免把 URL 改坏。
    private static func substitute(_ template: String, vars: [String: String]) -> String {
        // 先把带 :urlenc 修饰符的替换掉（否则 manualSubstitute 会把 :urlenc 当普通名）
        guard template.contains("{") else { return template }
        var out = template
        if let re = try? NSRegularExpression(pattern: #"\{([^}:]+):urlenc\}"#) {
            let ns = out as NSString
            // 倒序替换，避免位置偏移
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                let name = ns.substring(with: m.range(at: 1))
                let raw = vars[name] ?? ""
                let enc = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
                let full = ns.substring(with: m.range)
                out = (out as NSString).replacingCharacters(
                    in: NSRange(location: m.range.location, length: full.utf16.count), with: enc)
            }
        }
        return manualSubstitute(out, vars: vars)
    }

    /// 手动把字符串里所有 `{name}`（name 为字母数字下划线）替换为变量；
    /// 变量缺失则保留原样。
    private static func manualSubstitute(_ s: String, vars: [String: String]) -> String {
        guard s.contains("{") else { return s }
        let re = try? NSRegularExpression(pattern: #"\{([A-Za-z_][A-Za-z0-9_]*)\}"#)
        guard let re else { return s }
        let ns = s as NSString
        var result = ""
        var pos = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let full = ns.substring(with: m.range)
            let name = ns.substring(with: m.range(at: 1))
            let replacement = vars[name] ?? full       // 缺失 → 原样
            let before = ns.substring(with: NSRange(location: pos, length: m.range.location - pos))
            result += before + replacement
            pos = m.range.location + m.range.length
        }
        result += ns.substring(from: pos)
        return result
    }

    /// 第一个正则匹配的第 1 捕获组（不区分大小写）。
    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              m.numberOfRanges > 1 else { return nil }
        let r = m.range(at: 1)
        guard r.location != NSNotFound else { return nil }
        return (text as NSString).substring(with: r)
    }

    /// 所有正则匹配的第 1 捕获组（全局、不区分大小写）。
    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { m -> String? in
                guard m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
                return ns.substring(with: m.range(at: 1))
            }
    }

    /// 相对/协议相对地址解析为绝对地址。
    private static func resolve(_ raw: String, base: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("//") { return "https:" + s }
        if s.hasPrefix("http") { return s }
        guard let u = URL(string: s, relativeTo: URL(string: base)) else { return s }
        return u.absoluteString
    }

    /// 合并两段 Cookie：按 `k=v` 拆分，同名后者覆盖前者，重新拼装。
    private static func mergeCookie(_ old: String?, _ new: String?) -> String {
        var dict: [String: String] = [:]
        func fill(_ src: String?) {
            guard let src else { return }
            for part in src.split(separator: ";") {
                let kv = part.trimmingCharacters(in: .whitespaces)
                guard let eq = kv.firstIndex(of: "=") else { continue }
                let k = kv[..<eq].trimmingCharacters(in: .whitespaces)
                let v = kv[kv.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if !k.isEmpty { dict[k] = v }
            }
        }
        fill(old); fill(new)
        return dict.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    /// 解析 legado 全局 header 文本（`Key: Value` 每行一条，允许空行）。
    private static func parseHeaderLines(_ header: String?) -> [String: String]? {
        guard let header, !header.isEmpty else { return nil }
        var out: [String: String] = [:]
        for line in header.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, let sep = l.firstIndex(of: ":") else { continue }
            let k = String(l[..<sep]).trimmingCharacters(in: .whitespaces)
            let v = String(l[l.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k] = v }
        }
        return out.isEmpty ? nil : out
    }
}
