import Foundation

/// URL 规则引擎 —— Legado/绘漫岛 标准语义
/// 支持: 裸词 searchKey / searchPage(含 searchPage±N 算术) / {{js 表达式}} /
///       @Header:{宽松头部,值内可嵌 JS} / ,{JSON 请求配置(POST/body/headers)} / |char=gbk / @Body:{}
struct AnalyzeUrl {
    var url = ""
    var method = "GET"
    var body: String? = nil
    var headers: [String: String] = [:]
    var charset: String? = nil

    static func make(_ rawRule: String, searchKey: String = "", page: Int = 1, baseUrl: String? = nil, ua: String? = nil) -> AnalyzeUrl {
        var a = AnalyzeUrl()
        var rule = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.isEmpty else { return a }

        // 1) @Header:{...} —— 宽松键值（支持 k=v / k:v，值可含 {{js}}）
        if let h = extractBlock(&rule, prefix: "@Header:") {
            for (k, v) in parseLenientHeaders(h) {
                var vv = evalVars(v, searchKey: searchKey, page: page, charset: nil, urlEncode: false)
                // AnalyzeHeaders 关键字：host/thisPage/prePage
                let lk = vv.lowercased()
                if let b = baseUrl {
                    if vv == "host" { vv = URL(string: b)?.host ?? vv }
                    else if lk == "thispage" || lk == "referer:host" { vv = b }
                    else if lk == "prepage" { vv = b }
                }
                a.headers[k] = vv
            }
        }
        // 2) |char=gbk/escape
        if let pipe = rule.range(of: "|char=") {
            let cs = String(rule[pipe.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: ",; \t\n"))
            a.charset = cs.lowercased().contains("gbk") ? "gbk" : (cs.lowercased().contains("escape") ? "escape" : nil)
            rule = String(rule[..<pipe.lowerBound])
        }
        // 3) ,{JSON 请求配置}（Legado POST 配置格式: url,{\"method\":\"POST\",...}）
        if let brace = findTopLevelBrace(rule, afterComma: true) {
            let inner = String(rule[rule.index(after: brace.lowerBound)..<rule.index(before: brace.upperBound)])
            if let cfg = try? JSONSerialization.jsonObject(with: Data(inner.utf8)) as? [String: Any] {
                rule = String(rule[..<brace.lowerBound]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ","))
                if let m = cfg["method"] as? String { a.method = m.uppercased() }
                if let bd = cfg["body"] as? String { a.body = evalVars(bd, searchKey: searchKey, page: page, charset: nil, urlEncode: false) }
                if let hh = cfg["headers"] as? [String: String] {
                    for (k, v) in hh { a.headers[k] = evalVars(v, searchKey: searchKey, page: page, charset: nil, urlEncode: false) }
                }
                if let cs = cfg["charset"] as? String { a.charset = cs.lowercased() }
            }
        }
        // 4) @Body:{...}
        if let b = extractBlock(&rule, prefix: "@Body:") {
            a.body = evalVars(b, searchKey: searchKey, page: page, charset: nil, urlEncode: false)
        }
        // 5) post: 前缀
        if rule.lowercased().hasPrefix("post:") {
            rule = String(rule.dropFirst(5))
            a.method = "POST"
        }
        // 5b) url@body POST 形式（对齐安卓 AUrl @ 拆分；@Header/@Body/@JSon 等已提前剥离）
        // 🔴 必须用**忽略引号/括号**的切分 —— URL 自身可能含 `@`
        //    （userinfo 形式 `https://u:p@host/`、或 query 里的 `@`）。
        //    裸 `firstIndex(of:"@")` 会把它当 url/body 分隔，把 URL 截断并**强改 POST**，
        //    静默坏掉整个搜索入口。（由智能体「引擎复审」发现）
        if let at = AnalyzeRule.firstUnquoted(rule, "@"), rule.index(after: at) < rule.endIndex {
            let right = String(rule[rule.index(after: at)...])
            if !right.hasPrefix("{"), !right.hasPrefix("["), !right.lowercased().hasPrefix("json"), !right.lowercased().hasPrefix("css"), !right.lowercased().hasPrefix("xpath"), !right.lowercased().hasPrefix("get:"), !right.lowercased().hasPrefix("put:"), !right.lowercased().hasPrefix("web") {
                rule = String(rule[..<at])
                let b = evalVars(right, searchKey: searchKey, page: page, charset: a.charset, urlEncode: false)
                if b.hasPrefix("{") {
                    a.headers["Content-Type"] = "application/json;charset=UTF-8"
                } else {
                    a.headers["Content-Type"] = "application/x-www-form-urlencoded"
                }
                a.body = b
                a.method = "POST"
            }
        }
        // 6) URL 求值（searchKey/searchPage/{{js}}）
        a.url = evalVars(rule, searchKey: searchKey, page: page, charset: a.charset, urlEncode: true)
        // 7) method 收敛
        if a.body != nil, a.method == "GET" { a.method = "POST" }
        if a.body != nil, a.headers["Content-Type"] == nil {
            a.headers["Content-Type"] = "application/x-www-form-urlencoded"
        }
        a.headers["User-Agent"] = ua ?? AppSettings.shared.httpUA
        if let b = baseUrl, !a.url.lowercased().hasPrefix("http") {
            a.url = NetUrl.absolute(a.url, base: b)
        }
        a.url = NetUrl.fixEncoding(a.url)   // 中文路径等非 ASCII 百分号编码（URL(string:) 会返回 nil）
        return a
    }

    // MARK: - 变量求值

    /// 求值顺序: {p1,p2}页码备选 → {{js}} → searchPage±N → searchKey
    static func evalVars(_ s: String, searchKey: String, page: Int, charset: String?, urlEncode: Bool) -> String {
        var out = s
        // 🔴 有些导入链路会把 `{{page}}` 的花括号**百分号编码**成 `%7B%7Bpage%7D%7D`。
        //    真机日志实证：`[explore] 栏目「全部」 url=https://www.tuku.cc/comics-p%7B%7Bpage%7D%7D/ → 0 条`
        //    —— 字面 `{{` 不存在，`evalInlineJS` 的守卫直接放过 → 页码永不替换 →
        //    图库/包子这类 `{{page}}` 源**整栏目空**、切源一直转圈。
        //    这里先把成对的花括号还原（只动成对形式，避免误伤单个 `%7B`）。
        if out.range(of: "%7B%7B", options: .caseInsensitive) != nil {
            out = out.replacingOccurrences(of: "%7B%7B", with: "{{", options: .caseInsensitive)
                     .replacingOccurrences(of: "%7D%7D", with: "}}", options: .caseInsensitive)
        }
        // {page1,page2,...} 页码备选（不含 {{}}/@/冒号引号的纯逗号列表；超出取最后一个）
        if let re = try? NSRegularExpression(pattern: "\\{([^{}'\":@]*,[^{}'\":@]*)\\}") {
            let ns = NSMutableString(string: out)
            var edits: [(NSRange, String)] = []
            re.enumerateMatches(in: out, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m, let r = Range(m.range, in: out) else { return }
                let inner = String(out[out.index(after: r.lowerBound)..<out.index(before: r.upperBound)])
                let pages = inner.components(separatedBy: ",")
                guard pages.count > 1 else { return }
                let pick = pages.indices.contains(page - 1) ? pages[page - 1] : pages.last ?? ""
                edits.append((m.range, pick))
            }
            for (range, value) in edits.sorted(by: { $0.0.location > $1.0.location }) {
                ns.replaceCharacters(in: range, with: value)
            }
            out = ns as String
        }
        out = evalInlineJS(out, searchKey: searchKey, page: page)
        // searchPage±N / 裸 searchPage
        // 实测语义（拷贝漫画等 offset 型 API）：searchPage-N 为"偏移步进"—— (page-1)*N（0 起）
        // searchPage+N 为 page+N；裸 searchPage 为页码本身
        if let re = try? NSRegularExpression(pattern: "searchPage(?:\\s*([+-])\\s*(\\d+))?", options: []) {
            // 先收集匹配再倒序替换——边遍历边修改可变字符串会崩溃
            let ns = NSMutableString(string: out)
            var edits: [(NSRange, String)] = []
            re.enumerateMatches(in: out, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m else { return }
                guard let r = Range(m.range, in: out) else { return }
                var value = page
                if let sign = Range(m.range(at: 1), in: out), let num = Range(m.range(at: 2), in: out), let n = Int(out[num]) {
                    if out[sign] == "-" { value = max(0, (page - 1) * n) }   // 偏移型：0,10,20...
                    else { value = page + n }
                }
                edits.append((m.range, "\(value)"))
            }
            for (range, value) in edits.sorted(by: { $0.0.location > $1.0.location }) {
                ns.replaceCharacters(in: range, with: value)
            }
            out = ns as String
        }
        // searchKey（URL 中按字符集编码；body/头中用原文）
        if out.contains("searchKey") {
            let v = urlEncode ? encodeKey(searchKey, charset: charset) : searchKey
            out = out.replacingOccurrences(of: "searchKey", with: v)
        }
        return out
    }

    /// {{js}} 内联求值（同步 JSContext，暴露 searchKey/searchPage）
    static func evalInlineJS(_ s: String, searchKey: String, page: Int) -> String {
        guard s.contains("{{"), !s.contains("://") || s.range(of: "\\{\\{", options: .regularExpression) != nil else { return s }
        guard s.range(of: "\\{\\{.*?\\}\\}", options: .regularExpression) != nil else { return s }
        var out = s
        var guardCount = 0
        while let r1 = out.range(of: "{{"), let r2 = out.range(of: "}}", range: r1.upperBound..<out.endIndex), guardCount < 8 {
            guardCount += 1
            let code = String(out[r1.upperBound..<r2.lowerBound])
            // ⚠️ `{{}}` 里的变量名**两套格式不一样**，必须都注入：
            //    · 绘漫岛：`searchKey` / `searchPage`
            //    · Legado：`key` / `page`（实测新采的源里大量出现
            //      `?q={{key}}&page={{page}}`）
            //    只注入前者的话，`{{key}}` 求值成 undefined → 空串 →
            //    整个搜索 URL 坏掉（表现为「该源搜不到东西」）。
            let val = JSEvaluator.shared.evaluateExpression(code, vars: [
                "searchKey": searchKey, "searchPage": String(page),
                "key": searchKey, "page": String(page)
            ])
            out.replaceSubrange(r1.lowerBound..<r2.upperBound, with: val)
        }
        return out
    }

    static func encodeKey(_ s: String, charset: String?) -> String {
        if charset == "gbk", let d = s.data(using: .gbk) {
            return d.map { $0 == 0x2D || ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
        }
        if charset == "escape" {
            return s.unicodeScalars.map { sc -> String in
                sc.isASCII && sc.value > 0x20 && sc.value < 0x7F ? String(sc) : "\(s.utf8.map { String(format: "%%%02X", $0) }.joined())"
            }.joined()
        }
        return s.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? s
    }

    // MARK: - 头部解析

    /// 宽松头部: JSON 优先，失败则按顶层逗号拆分、首个 = 或 : 分键值
    static func parseLenientHeaders(_ s: String) -> [String: String] {
        if let d = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: String] { return d }
        var out: [String: String] = [:]
        var parts: [String] = []
        var cur = ""
        var depth = 0
        var inQ = false
        var esc = false
        for ch in s {
            if esc { cur.append(ch); esc = false; continue }
            if inQ && ch == "\\" { cur.append(ch); esc = true; continue }
            if ch == "\"" { inQ.toggle(); cur.append(ch); continue }
            if ch == "{" || ch == "[" { depth += 1 }
            if ch == "}" || ch == "]" { depth -= 1 }
            if ch == "," && depth == 0 && !inQ { parts.append(cur); cur = ""; continue }
            cur.append(ch)
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(cur) }
        for p in parts {
            let pair: (String, String)?
            if let i = p.firstIndex(of: "=") { pair = (String(p[..<i]), String(p[p.index(after: i)...])) }
            else if let i = p.firstIndex(of: ":") { pair = (String(p[..<i]), String(p[p.index(after: i)...])) }
            else { pair = nil }
            if let (k, v) = pair {
                let strip = CharacterSet(charactersIn: "\" ")
                let key = k.trimmingCharacters(in: strip)
                let val = v.trimmingCharacters(in: strip)
                if !key.isEmpty { out[key] = val }
            }
        }
        return out
    }

    // MARK: - 花括号块提取

    /// 提取 prefix 后的 {...} 块（计数配平），返回块内容并从 rule 中移除
    static func extractBlock(_ rule: inout String, prefix: String) -> String? {
        guard let p = rule.range(of: prefix), p.upperBound < rule.endIndex, rule[p.upperBound] == "{" else { return nil }
        let start = rule.index(after: p.upperBound)
        var depth = 1
        var i = start
        while i < rule.endIndex, depth > 0 {
            if rule[i] == "{" { depth += 1 }
            if rule[i] == "}" { depth -= 1 }
            i = rule.index(after: i)
        }
        guard depth == 0 else { return nil }
        let inner = String(rule[start..<rule.index(before: i)])
        rule = String(rule[..<p.lowerBound]) + String(rule[i...])
        return inner
    }

    /// 找 rule 中逗号后的顶层 {（Legado JSON 配置格式），返回配平区间
    static func findTopLevelBrace(_ rule: String, afterComma: Bool) -> Range<String.Index>? {
        var inQ = false
        var esc = false
        var i = rule.startIndex
        var sawComma = false
        while i < rule.endIndex {
            let c = rule[i]
            if esc { esc = false }
            else if inQ && c == "\\" { esc = true }
            else if c == "\"" { inQ.toggle() }
            else if !inQ {
                if c == "," { sawComma = true }
                if c == "{" && sawComma && afterComma {
                    // 配平
                    var depth = 1
                    var j = rule.index(after: i)
                    while j < rule.endIndex, depth > 0 {
                        let cj = rule[j]
                        if cj == "\"" { inQ.toggle() }
                        else if !inQ {
                            if cj == "{" { depth += 1 }
                            if cj == "}" { depth -= 1 }
                        }
                        j = rule.index(after: j)
                    }
                    if depth == 0 { return i..<j }
                    return nil
                }
            }
            i = rule.index(after: i)
        }
        return nil
    }

    func toRequest() -> URLRequest? {
        // 🔴 先补编码再构造 URL —— URL 里带**空格**（很多图源的书名/章节名带空格）
        //    直接过 `URL(string::)` 会返回 **nil** → 请求根本发不出去 →
        //    整章无图 / 整章打不开，而且**没有任何日志**（静默失败）。
        guard let u = URL(string: NetUrl.fixEncoding(url)) else { return nil }
        var req = URLRequest(url: u)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let b = body { req.httpBody = Data(b.utf8) }
        return req
    }
}

enum NetUrl {
    /// 含非 ASCII / 空格等不安全字符的 URL 补百分号编码，否则 `URL(string:)` 返回 nil。
    ///
    /// 🔴 以前只处理「含非 ASCII」的情况 —— URL 里有**空格**但全 ASCII 时直接放过，
    ///    而 `URL(string:)` 不接受空格 → 返回 nil → 请求发不出去 → **整章无图**，
    ///    且没有任何日志（用户只看到黑屏转圈）。（由智能体「规则漏洞A」发现）
    ///    `%` 已在白名单里，所以已编码的 `%20` 不会被二次编码成 `%2520`。
    static func fixEncoding(_ u: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~:/?#[]@!$&'()*+,;=%")
        return u.addingPercentEncoding(withAllowedCharacters: allowed) ?? u
    }

    static func absolute(_ path: String, base: String) -> String {
        if path.lowercased().hasPrefix("http") { return path }
        if let b = URL(string: base) {
            if path.hasPrefix("//") { return "https:\(path)" }
            return URL(string: path, relativeTo: b)?.absoluteString ?? path
        }
        return path
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var c = CharacterSet.alphanumerics
        c.insert(charactersIn: "-._~")
        return c
    }()
}

extension String.Encoding {
    static let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(UInt32(CFStringEncodings.GB_18030_2000.rawValue))))
}
