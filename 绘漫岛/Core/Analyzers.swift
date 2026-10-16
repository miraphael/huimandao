import Foundation

/// 轻量 JSONPath：覆盖 `$.a.b`, `$..a`, `$.a[*]`, `$.a[0]`, `$[*].b`, `$['k']` 常用子集
enum JsonPath {
    static func parse(_ text: String) -> Any? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = t.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func query(_ root: Any, _ path: String) -> [Any] {
        var p = path.hasPrefix("$") ? String(path.dropFirst()) : path
        if p.hasPrefix("@.") { p = String(p.dropFirst(2)) }   // 列表内相对路径
        var current: [Any] = [root]
        let tokens = tokenize(p)
        for tok in tokens {
            var next: [Any] = []
            for node in current {
                switch tok {
                case .deep(let key):
                    next += deepSearch(node, key)
                case .key(let k):
                    if let dict = node as? [String: Any] {
                        if let v = dict[k] { next.append(v) }
                        else if k == "length" && node is [Any] { next.append((node as! [Any]).count) }
                    }
                case .index(let i):
                    if let arr = node as? [Any], arr.indices.contains(i < 0 ? arr.count + i : i) {
                        next.append(arr[i < 0 ? arr.count + i : i])
                    }
                case .allIndices:
                    if let arr = node as? [Any] { next += arr }
                case .allKeys:
                    if let dict = node as? [String: Any] { next += dict.values }
                }
            }
            current = next
        }
        return current
    }

    private enum Token { case key(String); case index(Int); case allIndices; case allKeys; case deep(String) }

    private static func tokenize(_ p: String) -> [Token] {
        var tokens: [Token] = []
        var i = p.startIndex
        var deep = false
        while i < p.endIndex {
            let c = p[i]
            if c == "." {
                let n = p.index(after: i)
                if n < p.endIndex, p[n] == "." {
                    deep = true; i = p.index(after: n); continue
                }
                i = n; continue
            }
            if c == "[" {
                let close = p[i...].firstIndex(of: "]") ?? p.endIndex
                let inner = String(p[p.index(after: i)..<close])
                deep = false
                if inner == "*" { tokens.append(.allIndices) }
                else if let n = Int(inner) { tokens.append(.index(n)) }
                else if inner.hasPrefix("'") || inner.hasPrefix("\"") {
                    tokens.append(.key(String(inner.dropFirst().dropLast())))
                } else { tokens.append(.key(inner)) }
                i = close == p.endIndex ? close : p.index(after: close)
                continue
            }
            // 读一个 key
            var j = i
            while j < p.endIndex, p[j] != ".", p[j] != "[" { j = p.index(after: j) }
            let key = String(p[i..<j])
            if !key.isEmpty, key != "*" {
                if deep { tokens.append(.deep(key)); deep = false }
                else if key == "*" { tokens.append(.allKeys) }
                else { tokens.append(.key(key)) }
            } else if key == "*" { tokens.append(.allKeys) }
            i = j
        }
        return tokens
    }

    private static func deepSearch(_ node: Any, _ key: String) -> [Any] {
        var out: [Any] = []
        if let dict = node as? [String: Any] {
            if let v = dict[key] { out.append(v) }
            for v in dict.values { out += deepSearch(v, key) }
        } else if let arr = node as? [Any] {
            for v in arr { out += deepSearch(v, key) }
        }
        return out
    }

    static func asString(_ v: Any) -> String {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let b as Bool: return b ? "true" : "false"
        default: return stringify(v)
        }
    }

    static func stringify(_ v: Any) -> String {
        if let s = v as? String { return s }
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]) else { return "\(v)" }
        return String(data: d, encoding: .utf8) ?? "\(v)"
    }
}

/// XPath：libxml2 html 解析（系统库，覆盖完整 XPath 1.0）
import libxml2

enum XPathEngine {
    // libxml2 HTML 解析选项宏不进 Swift 模块，用数值: RECOVER=1 NOERROR=32 NOWARNING=64
    static func query(html: String, xpath: String, baseUrl: String) -> [String] {
        let cHtml = html.cString(using: .utf8) ?? []
        let doc = htmlReadMemory(cHtml, Int32(cHtml.count), baseUrl, nil, Int32(1 | 32 | 64))
        guard let doc else { return [] }
        defer { xmlFreeDoc(doc) }
        let ctx = xmlXPathNewContext(doc)
        defer { xmlXPathFreeContext(ctx) }
        let cXpath = xpath.cString(using: .utf8) ?? []
        let result = xmlXPathEvalExpression(cXpath, ctx)
        defer { xmlXPathFreeObject(result) }
        guard let result, result.pointee.type == XPATH_NODESET, let nodeset = result.pointee.nodesetval else { return [] }
        var out: [String] = []
        for i in 0..<Int(nodeset.pointee.nodeNr) {
            guard let node = nodeset.pointee.nodeTab[i] else { continue }
            guard let content = xmlNodeGetContent(node) else { continue }
            let s = String(cString: content).trimmingCharacters(in: .whitespacesAndNewlines)
            free(content)
            out.append(s)
        }
        return out.filter { !$0.isEmpty }
    }

    /// 返回匹配节点的外层 HTML 片段（供列表规则还原成元素，字段规则才能继续取 class./text）
    static func queryHTML(html: String, xpath: String, baseUrl: String) -> [String] {
        let cHtml = html.cString(using: .utf8) ?? []
        let doc = htmlReadMemory(cHtml, Int32(cHtml.count), baseUrl, nil, Int32(1 | 32 | 64))
        guard let doc else { return [] }
        defer { xmlFreeDoc(doc) }
        let ctx = xmlXPathNewContext(doc)
        defer { xmlXPathFreeContext(ctx) }
        let cXpath = xpath.cString(using: .utf8) ?? []
        let result = xmlXPathEvalExpression(cXpath, ctx)
        defer { xmlXPathFreeObject(result) }
        guard let result, result.pointee.type == XPATH_NODESET, let nodeset = result.pointee.nodesetval else { return [] }
        var out: [String] = []
        for i in 0..<Int(nodeset.pointee.nodeNr) {
            guard let node = nodeset.pointee.nodeTab[i] else { continue }
            guard let buf = xmlBufferCreate() else { continue }
            defer { xmlBufferFree(buf) }
            xmlNodeDump(buf, doc, node, 0, 0)
            guard let content = xmlBufferContent(buf) else { continue }
            let s = String(cString: content)
            if !s.isEmpty { out.append(s) }
        }
        return out
    }
}
