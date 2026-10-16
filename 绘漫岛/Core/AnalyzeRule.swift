import Foundation
import SwiftSoup
import CommonCrypto

/// 规则引擎 v2 —— 全面对照安卓 AnalyzeRule/AnalyzeByJSoup/AnalyzeByJSonPath/AnalyzeByXPath 语义
/// 支持: jsoup 链式(tag./class./id./text./[n]索引/!排除/>子过滤/children) / @CSS: / @JSon:,$(大小写变体+JSON隐式模式) /
///       @XPath:// / @js:<js> / {{}} / @get:(内联) / @put:(多键) / @Header: / #正则#替换(单#) / & || %%(交错) 组合 / - 反转
final class AnalyzeRule {
    struct Context {
        var baseUrl: String = ""
        var element: Element? = nil
        var json: Any? = nil
        var variableMap: [String: String] = [:]
        var headers: [String: String] = [:]
        /// 当前内容是否为「**迭代出来的节点对象**」（对齐安卓 `setContent(_, it.next(), _)`），
        /// 而非「**HTTP 响应体本体**」（`setContent(_, response.body(), _)`）。
        ///
        /// ⚠️ 这决定 JS 段里 `result` 绑成对象还是字符串（对齐 `WrapForJS(this.object)`）：
        ///   - 节点对象 → 绑**对象**，规则写 `@js:result.title` / `result.url`（逐章/逐搜索结果）；
        ///   - 响应体   → 绑**字符串**，规则写 `@js:JSON.parse(result)…` / `result.match(…)`。
        /// ⚠️ 不能只看 `ctx.json != nil`：JSON API 的**响应体本身**也是 JSON 文本，
        /// `setJson()` 后 `ctx.json != nil`，但它对应的其实是 String 上下文。
        /// 曾经用它当判据 → 亲亲漫画/小姐姐漫画等 158 条 `JSON.parse(result)` 规则全挂。
        var jsonIsNode: Bool = false
        /// 响应体（HTML）的**原始字符串**。`setDocument` 时保存。
    ///
    /// 🔴 为什么必须有它：`@js:` 规则在**文档场景**下必须拿到完整响应体，
    ///    而 `ctx.element.html()` 只是某个元素的 HTML（真机实测只有 1913 字符，
    ///    而整页是 38249）→ 加密站点的 `result.match(...)` 全部匹配不上。
    var rawHtml: String? = nil
    /// 响应体（JSON 文本）的**原始字符串**。`setJson` 时保存，
        /// 供「响应体本体」场景把 `result` 原样传给 JS（而不是重新序列化 —— 重新序列化
        /// 会丢掉键顺序/转义细节，且 `JsonPath.stringify` 对顶层标量有损）。
        var rawJsonText: String? = nil
    }

    private let js = JSEvaluator.shared

    /// 变量表并发保护。
    ///
    /// ⚠️ **为什么必须有锁**：`putVariables` 会把多键求值并发丢进 task group，
    ///    而每个键的求值里若含 `@js:`，JS 里的 `java.put(k,v)` 会直接写
    ///    `ctx.variableMap`（见 `javaPut`）。也就是说同一个实例的变量表会被
    ///    **多个执行器并发写** —— Swift `Dictionary` 不是线程安全的，
    ///    并发写会触发未定义行为（重复哈希/扩容时的野指针，实测表现为偶发崩溃）。
    ///    读侧（`@get:{k}` / `{{k}}` 展开）同样在并发上下文中，一并发写就撕裂。
    ///    这里用一把递归锁把所有访问收口（`@put` 内部再触发 `@put` 需要可重入）。
    private let varLock = NSRecursiveLock()
    /// 读一个变量
    func varGet(_ key: String) -> String {
        varLock.lock(); defer { varLock.unlock() }
        return ctx.variableMap[key] ?? ""
    }
    /// 写一个变量
    func varSet(_ key: String, _ value: String) {
        varLock.lock(); defer { varLock.unlock() }
        ctx.variableMap[key] = value
    }
    /// 批量写（putVariables 收口用）
    private func varSetAll(_ pairs: [(String, String)]) {
        varLock.lock(); defer { varLock.unlock() }
        for (k, v) in pairs { ctx.variableMap[k] = v }
    }
    /// 整个变量表的快照（供需要遍历的场景）
    func varSnapshot() -> [String: String] {
        varLock.lock(); defer { varLock.unlock() }
        return ctx.variableMap
    }

    var ctx = Context()

    init(baseUrl: String = "") {
        ctx.baseUrl = baseUrl
    }

    func setDocument(html: String, baseUrl: String) {
        ctx.baseUrl = baseUrl
        ctx.rawHtml = html          // 🔴 保存原文，供 @js: 正文规则用
        ctx.element = try? SwiftSoup.parse(html, baseUrl)
        ctx.json = nil
        ctx.jsonIsNode = false          // 文档本体 = 响应体 → String（Jsoup 会 toString）
    }
    /// 设置内容为 JSON —— `isNode=false` 表示这是**响应体本体**（String 语义），
    /// `isNode=true` 表示这是**从列表里迭代出来的节点**（对象语义）。
    func setJson(_ text: String, baseUrl: String, isNode: Bool = false) {
        ctx.baseUrl = baseUrl
        ctx.json = JsonPath.parse(text)
        ctx.element = nil
        ctx.jsonIsNode = isNode
        ctx.rawJsonText = text
    }
    /// 把一段**节点片段**（某个元素的 `outerHtml`）设为当前上下文。
    ///
    /// 🔴 与 `setDocument` 的关键区别：`setDocument` 把内容当**整页文档**，根是 `<html>`；
    ///    这里根是**片段里的第一个元素本身**。
    ///
    /// 为什么必须区分：章节 / 搜索列表的每条规则都是在**节点**上求值的，
    /// 而裸属性名规则（`ruleChapterName = "title"`、`ruleContentUrl = "href"`）
    /// 要作用在**节点自己**身上。以前片段也走 `setDocument` → 根变成 `<html>` →
    /// `attr("title")` 取到空字符串 → 真机表现就是
    /// **「249 章全都没有名字」**（知音漫客，2026-10-14 实测）。
    /// （`href` 之所以没暴露，是因为后面有一条 `a@href` 兜底把 URL 救了回来。）
    func setFragment(html: String, baseUrl: String) {
        ctx.baseUrl = baseUrl
        let doc = try? SwiftSoup.parse(html, baseUrl)
        // 片段解析后，真正的节点是 body 的第一个子元素
        if let d = doc, let body = try? d.body(), let first = try? body.children().first() {
            ctx.element = first
        } else {
            ctx.element = doc
        }
        ctx.json = nil
        ctx.jsonIsNode = false
    }

    func setElement(_ el: Element) {
        ctx.element = el
        // 🔴 必须清掉 `ctx.json` —— 以前这里只设 element 不清 json，
        //    JSON 页 + `<js>` 返回元素节点后，再走 `$..x` 会读到**上一页的旧 JSON**。
        //    （由智能体「规则漏洞A」发现）
        ctx.json = nil
        ctx.jsonIsNode = false          // HTML 元素 → Jsoup Element，WrapForJS 转成 outerHtml 字符串
    }

    // MARK: - 对外取值

    /// 文本字段：多结果按 \n 连接（对齐安卓 getString(rule,false)）
    func getString(_ rule: String) async -> String {
        let r = await splitAndRun(rule, want: .list)
        if !r.list.isEmpty { return r.list.joined(separator: "\n") }
        return r.string
    }
    /// URL 字段：只取首个（对齐安卓 getString0）
    func getStringFirst(_ rule: String) async -> String {
        let r = await splitAndRun(rule, want: .string)
        return r.string
    }
    func getStringList(_ rule: String) async -> [String] {
        let r = await splitAndRun(rule, want: .list)
        return r.list.filter { !$0.isEmpty }
    }
    func getElements(_ rule: String) async -> [RuleNode] {
        var rl = rule
        if rl.hasPrefix("-") {   // - 前缀反转结果顺序
            rl = String(rl.dropFirst())
            var nodes = await splitAndRun(rl, want: .elements).elements
            nodes.reverse()
            return nodes
        }
        return await splitAndRun(rl, want: .elements).elements
    }

    // MARK: - 组合拆分（& || %% 交错）

    enum Want { case string, list, elements }
    struct RuleResult { var string: String = ""; var list: [String] = []; var elements: [RuleNode] = [] }

    /// 规则求值的最大递归层数。
    ///
    /// 🔴 为什么需要：`java.getString(rule, true)` 会把**规则当成参数再求值一次**，
    ///    自引用规则（形如 `a@js:java.getString('a',true)`）会无限递归下去。
    ///    `@put:` / `@get:{` / `{{}}` 各自有 guardCount，但**整条链路的递归深度没人管**。
    ///    而 `jscore` 通道**不可强杀**、执行槽只有 8 个 —— 8 槽耗尽后
    ///    **所有** JS 图源一起挂起，App 僵死到重启。
    ///    （由智能体「规则漏洞B」发现；这里加护栏是「补钉子」，不改正常规则的语义。）
    private static let maxRuleDepth = 8
    /// 🔴 必须加锁：`putVariables` 的并发子任务会对**同一个实例**并发 ++/--，
    ///    自增不是原子操作 → 丢失更新 → 护栏被稀释（递归深于 8 仍放行），
    ///    也构成 Swift 独占访问数据竞争。（由复审智能体发现）
    private let ruleDepthLock = NSLock()
    private var ruleDepth = 0

    private func splitAndRun(_ rule: String, want: Want) async -> RuleResult {
        // 取「深度令牌」（原子读改写）
        ruleDepthLock.lock()
        let curDepth = ruleDepth
        ruleDepth += 1
        ruleDepthLock.unlock()
        defer { ruleDepthLock.lock(); ruleDepth -= 1; ruleDepthLock.unlock() }
        // 超深度直接返回空，而不是无限嵌套把 JS 执行槽耗尽
        guard curDepth < Self.maxRuleDepth else {
            DiagLog.event("rule", "depth",
                          "⚠️ 规则递归超过 \(Self.maxRuleDepth) 层，已截断：\(rule.prefix(60))")
            return RuleResult()
        }

        // ── 占位符保护 ────────────────────────────────────────────────
        // 两种片段的内部可能含 `&`/`|`/`%`，绝不能参与组合切分：
        //   ① `<js>...</js>` 块
        //   ② 尾部 `@js:...` 段（安卓 jsPattern 同样把它整体切出来）
        // 先把它们换成不含分隔符的占位符，切分完成后再还原。
        // （旧实现只保护 `<js>`；`...@js:baseUrl+'&chap='+result` 这类规则会被 `&` 切碎 →
        //  实测 54 条规则受影响。）
        var placeholders: [String] = []
        var jsRanges: [(Range<String.Index>, Int)] = []
        var scan = rule.startIndex
        while let r = rule.range(of: "<js>", range: scan..<rule.endIndex) {
            if let close = rule.range(of: "</js>", range: r.upperBound..<rule.endIndex) {
                jsRanges.append((r.lowerBound..<close.upperBound, placeholders.count))
                placeholders.append(String(rule[r.lowerBound..<close.upperBound]))
                scan = close.upperBound
            } else { break }
        }
        // 🔴 必须取**最后一个**不在 `<js>` 内的 `@js:` ——
        //    旧实现只找第一个：`<js>result+="@js:x"</js>@js:java.get('a&b')` 里
        //    标签内含字面量 "@js:"，会命中它并判 insideTag=true，于是**尾部真正的
        //    `@js:` 段没被占位** → 组合切分的 `&` 把 JS 代码切碎 → 静默空。
        //    （由智能体「规则漏洞A」发现）
        var jsScan = rule.startIndex
        var lastJS: (Range<String.Index>, String)? = nil
        while let a = rule.range(of: "@js:", range: jsScan..<rule.endIndex) {
            let insideTag = jsRanges.contains { a.lowerBound >= $0.0.lowerBound && a.lowerBound < $0.0.upperBound }
            if !insideTag { lastJS = (a.lowerBound..<rule.endIndex, String(rule[a.lowerBound...])) }
            jsScan = a.upperBound
        }
        if let last = lastJS {
            jsRanges.append((last.0, jsRanges.count))
            placeholders.append(last.1)
        }
        jsRanges.sort { $0.0.lowerBound < $1.0.lowerBound }
        var protected = ""
        var i = rule.startIndex
        var ri = 0
        while i < rule.endIndex {
            if ri < jsRanges.count, i == jsRanges[ri].0.lowerBound {
                let (rng, idx) = jsRanges[ri]
                protected += "\u{E000}\(idx)\u{E001}"
                i = rng.upperBound; ri += 1
                continue
            }
            protected.append(rule[i]); i = rule.index(after: i)
        }

        var segments: [(String, String)] = []
        var buf = ""; var mode = "&"
        i = protected.startIndex
        // 🔴 必须做**引号 / 括号感知**的切分：`a[href*="?x=1&y=2"]@href` 里的 `&`
        //    是属性值的一部分，不是「组合分隔符」；`div[data-a|b]` 里的 `|` 同理。
        //    以前这里是**裸切**，会把选择器切成两半 → SwiftSoup 抛异常 →
        //    `try?` 吞成 0 个元素 → **静默解析失败**（用户只看到「没图」）。
        //    `CssSelect.splitOr` 早就有 depth/quote 状态机，这里对齐它。
        //    （由智能体「源核」发现）
        var depth = 0
        var quote: Character? = nil
        while i < protected.endIndex {
            let c = protected[i]
            // 引号内：原样收，只在遇到同种引号时出栈
            if let q = quote {
                buf.append(c)
                if c == q { quote = nil }
                i = protected.index(after: i); continue
            }
            if c == "\"" || c == "'" {
                quote = c; buf.append(c); i = protected.index(after: i); continue
            }
            if c == "[" || c == "(" || c == "{" {
                depth += 1; buf.append(c); i = protected.index(after: i); continue
            }
            if c == "]" || c == ")" || c == "}" {
                depth = max(0, depth - 1); buf.append(c); i = protected.index(after: i); continue
            }
            // 只有**顶层**（不在引号、不在括号里）才认分隔符
            if depth == 0 {
                if c == "|", protected.index(after: i) < protected.endIndex, protected[protected.index(after: i)] == "|" {
                    segments.append((buf, mode)); buf = ""; mode = "||"; i = protected.index(i, offsetBy: 2); continue
                }
                if c == "%", protected.index(after: i) < protected.endIndex, protected[protected.index(after: i)] == "%" {
                    segments.append((buf, mode)); buf = ""; mode = "%%"; i = protected.index(i, offsetBy: 2); continue
                }
                if c == "&" {
                    segments.append((buf, mode)); buf = ""; mode = "&"; i = protected.index(after: i); continue
                }
            }
            buf.append(c); i = protected.index(after: i)
        }
        segments.append((buf, mode))
        // 还原占位符
        if !placeholders.isEmpty {
            segments = segments.map { seg in
                var s = seg.0
                for (n, ph) in placeholders.enumerated() {
                    s = s.replacingOccurrences(of: "\u{E000}\(n)\u{E001}", with: ph)
                }
                return (s, seg.1)
            }
        }

        var merged = RuleResult()
        for (idx, seg) in segments.enumerated() {
            let r = await runOne(seg.0, want: want)
            if idx == 0 { merged = r; continue }
            switch seg.1 {
            case "%%":
                // 交错合并（round-robin，对齐安卓）
                var out: [String] = []
                let a = merged.list, b = r.list
                for k in 0..<max(a.count, b.count) {
                    if k < a.count { out.append(a[k]) }
                    if k < b.count { out.append(b[k]) }
                }
                merged.list = out
            case "||":
                if merged.list.isEmpty && merged.string.isEmpty && merged.elements.isEmpty {
                    merged = r
                }
            default:
                merged.list += r.list
                if !r.string.isEmpty { merged.string += r.string }
                if merged.elements.isEmpty { merged.elements = r.elements }
            }
        }
        return merged
    }

    /// 单条规则求值
    private func runOne(_ rawRule: String, want: Want) async -> RuleResult {
        var rule = rawRule.trimmingCharacters(in: .whitespaces)
        if rule.isEmpty { return RuleResult() }
        rule = await replaceInlineJS(rule)

        // @get:{k} 内联替换（可出现在规则中部）
        if rule.contains("@get:{") {
            var guardCount = 0
            while let r = rule.range(of: "@get:{"), let r2 = rule.range(of: "}", range: r.upperBound..<rule.endIndex), guardCount < 10 {
                guardCount += 1
                let key = String(rule[r.upperBound..<r2.lowerBound])
                rule.replaceSubrange(r.lowerBound..<r2.upperBound, with: varGet(key))
            }
        }

        rule = extractTrailingHeaders(rule).clean

        // ── 规则段拆分（对齐安卓 jsPattern = `(<js>…</js>|@js:…$)`）─────────────
        // 安卓把任意 `<js>...</js>` 或**行尾的 `@js:...`** 切出来作为独立 JS 段，
        // 前面的普通规则先求值、其结果作为 result 传给 JS 段，段间**顺序链式**执行。
        // 典型规则：`$.chapterid@js:baseUrl+result+'.html'`（100+ 个源的章节链接就是这种形态）。
        // 旧实现只识别 `<js>`，`$.x@js:...` 会被整串塞进 JsonPath（tokenizer 把
        // `chapterid@js:...` 当成一个 key）→ 取不到值 → 章节链接为空 → 章节列表 0 条。
        // 判断「JS 段的 result 该绑字符串还是对象」：对齐安卓 WrapForJS ——
        // 仅当当前内容是从列表里**迭代出来的节点对象**（ctx.jsonIsNode）才绑对象；
        // HTTP 响应体（正文/详情 HTML、JSON 文本）恒为 String，必须绑原字符串，
        // 否则 `@js:JSON.parse(result)…` 会炸成 `JSON.parse("[object Object]")`。
        // ⚠️ 判据必须是 ctx.jsonIsNode，不能用 `ctx.json != nil` ——
        //    JSON API 的**响应体本体**也是 JSON，setJson() 后 ctx.json != nil 但它是 String 语义。
        let ctxIsJsonNode = ctx.jsonIsNode

        // 🔴 守卫改成「**含** `<js>` 或 `@js:` 即切」—— 旧条件是
        //    `!rule.hasPrefix("<js>")`，太宽：
        //    以 `<js>` 开头**且后面还接着普通段**的规则（如 `<js>…</js>tag.a@href`）
        //    会被整串塞进 `evalJSRule`，`code` 里残留 `</js>@js:` → JS 语法错 →
        //    `try?` 吞成静默空。（由智能体「引擎复审」发现）
        let hasJSBlock = rule.contains("<js>")
        if !hasJSBlock, !rule.contains("@js:") {
            let segs = Self.splitJsSegments(rule)
            if segs.count > 1 {
                var carry = ""
                for seg in segs {
                    if seg.isJS {
                        // 链式段的 carry 来自 JsonPath 取出的**标量**（安卓 getString 语义 → String），
                        // 故恒传 presetIsObject: false。
                        return await evalJSRule(seg.text, presetResult: carry, want: want,
                                                presetIsObject: false)
                    }
                    carry = await innerString(seg.text, isList: false) ?? ""
                }
            }
        }
        if rule.hasPrefix("<js>") || rule.hasPrefix("@js:") {
            // ⚠️ 关键：正文规则（HTTP 响应体）必须拿到**原始字符串**。
            //    只有「迭代出来的 JSON 节点」才绑对象（如 @js:result.title）。
            // 🔴 修复：HTML 文档场景下，`@js:` 的 `result` 必须绑**完整响应体**。
            //    旧实现只取了 `ctx.element.html()`（某个元素的内部 HTML），
            //    于是正文规则里 `result` 只有 1913 字符而不是 38249 →
            //    `result.match(/params=……/)` 永远匹配不上 → 加密站点全挂。
            //    （真机实测 manhua3.com，2026-10-15；Node 里同样的规则完全正常，
            //     差异就在这个绑定上。）
            //    · 文档场景（ctx.jsonIsNode == false）：优先用 `ctx.rawHtml`（整页原文）
            //    · 节点场景（ctx.jsonIsNode == true）：保持 element.html()（逐章/逐结果迭代）
            let preset = jsPreset()
            // 🔎 插桩（build-62）：`@js:` 正文规则拿到的 result 到底有多长。
            //    真机排查 manhua3.com 时踩过坑：Node 里正常、真机匹配不上，
            //    差异就在 preset 上（旧实现只给 element.html()=1913 字，整页 38249）。
            //    这行日志用来确认新绑定已生效 / 以及跑的是不是新包。
            DiagLog.event("js", "preset",
                          "jsonIsNode=\(ctx.jsonIsNode) presetLen=\(preset.count) "
                          + "rawHtml=\(ctx.rawHtml?.count ?? -1) rule=\(rule.prefix(40))")
            return await evalJSRule(rule, presetResult: preset, want: want,
                                    presetIsObject: ctxIsJsonNode)
        }

        // ── 正则替换 `rule#regex#replacement` ──────────────────────────────
        // 分隔符有两种写法，都要支持：
        //   · 绘漫岛（本项目的移植源）：`AnalyzeByJSoup.SourceRule` 里是 `str.split("#")`
        //     —— **单井号**，p[0]=选择器 p[1]=regex p[2]=replacement
        //   · Legado：`##` 双井号
        // 实测（501 启用源）：单 `#` 形式 557 条规则 / 204 个源；
        // `##` 形式 8 条 / 4 个源（禁漫天堂、肉色漫画、CC漫画网15、亲亲漫画）。
        // ⚠️ 若一律按单 `#` 切，`a##b##c` 会变成 ["a","","b","","c"] →
        //    regex 为空 → 整个替换被静默跳过（禁漫天堂的书名就一直带着【…】）。
        var post: [(String, String)] = []
        var body = rule
        // 🔴 分隔符判定必须**忽略引号/括号**，且 `#` 前面不能是空或选择器边界：
        //    · `#cover_img@src` —— 这里的 `#` 是 **CSS id 选择器**，不是分隔符。
        //      旧代码一句 `rule.contains("#")` 就把它切开：body="" + pattern="cover_img@src"
        //      → 空 body 走到 `extract(root, "text")` → **把整页正文当结果**
        //      （封面取到整个 HTML 文本 = 封面加载不出来，章节名同理）。
        //    · `a[href*="#"]@href` —— `#` 在属性值里，同样不能当分隔符。
        //    （由智能体「规则漏洞A」构造反例发现）
        let hashSep: String?
        if rule.contains("##") {
            hashSep = "##"
        } else if let h = Self.firstUnquoted(rule, "#") {
            let boundary = " .>|&,@#[("
            let isIdSelector = (h == rule.startIndex) || boundary.contains(rule[rule.index(before: h)])
            hashSep = isIdSelector ? nil : "#"
        } else {
            hashSep = nil
        }
        if let sep = hashSep {
            let parts = rule.components(separatedBy: sep)
            if parts.count >= 2 {
                body = parts[0]
                let pattern = parts[1]
                let repl = parts.count > 2 ? parts[2] : ""
                if !pattern.isEmpty { post.append((pattern, repl)) }
            }
        }

        let res = await evalByMode(body, want: want)
        var out = res
        for (pattern, repl) in post {
            // 🔴 非法正则会 `continue` **静默跳过** —— 用户只看到「替换没生效」，
            //    完全不知道是规则写错了。记一条诊断，把静默失败变成可定位。
            //    （由智能体「规则漏洞A」发现）
            guard let re = try? NSRegularExpression(pattern: pattern) else {
                DiagLog.event("rule", "regex", "非法正则，已跳过替换：\(pattern.prefix(60))")
                continue
            }
            // 灾难回溯保护：病态 pattern（如 `(a+)+$`）配长文本会让 ICU 正则跑很久。
            // 规则来自不可信的导入，加长度护栏。（导入端应限 pattern 长度）
            if pattern.count > 200 || out.string.count > 100_000 {
                DiagLog.event("rule", "regex",
                              "正则/文本过长，已跳过替换（pattern \(pattern.count) 字、文本 \(out.string.count) 字）")
                continue
            }
            let ns = NSMutableString(string: out.string)
            re.replaceMatches(in: ns, range: NSRange(location: 0, length: ns.length), withTemplate: repl)
            out.string = ns as String
            out.list = out.list.map { item -> String in
                let s2 = NSMutableString(string: item)
                re.replaceMatches(in: s2, range: NSRange(location: 0, length: s2.length), withTemplate: repl)
                return s2 as String
            }
        }
        return out
    }

    // ── 规则解析的「忽略引号/括号」工具 ──────────────────────────────────
    //
    // 🔴 为什么需要：规则字符串里同时存在三类 `@` / `#` / `|` / `&`：
    //    ① 语法分隔符（`@href` 取值、`##` 正则替换、`||` 或）
    //    ② **属性值里的同名字符**（`a[href*="?x=1&y=2"]`、`a[href*="#"]`）
    //    ③ **CSS id 选择器**（`#cover_img@src`）
    //    裸 `contains` / `split` 会把 ②③ 当成 ① 处理 → 选择器被切坏 →
    //    SwiftSoup 抛异常 → `try?` 吞成 0 元素 → **静默解析失败**。
    //    （由智能体「规则漏洞A」构造反例发现，两者都真实存在。）
    //
    // 这两个函数是**纯字符扫描**，不依赖 SwiftSoup，成本 O(n)。

    /// 按分隔符切分；**跳过引号内与括号/方括号内**的命中。
    static func splitUnquoted(_ s: String, _ sep: Character) -> [String] {
        var out: [String] = []
        var cur = ""
        var depth = 0
        var quote: Character? = nil
        for c in s {
            if let q = quote {
                cur.append(c)
                if c == q { quote = nil }
                continue
            }
            if c == "\"" || c == "'" { quote = c; cur.append(c); continue }
            if c == "[" || c == "(" || c == "{" { depth += 1; cur.append(c); continue }
            if c == "]" || c == ")" || c == "}" { depth = max(0, depth - 1); cur.append(c); continue }
            if c == sep, depth == 0 { out.append(cur); cur = ""; continue }
            cur.append(c)
        }
        out.append(cur)
        return out
    }

    /// 第一个「不在引号/括号内」的 `target` 位置；找不到返回 nil。
    static func firstUnquoted(_ s: String, _ target: Character) -> String.Index? {
        var depth = 0
        var quote: Character? = nil
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "[" || c == "(" || c == "{" {
                depth += 1
            } else if c == "]" || c == ")" || c == "}" {
                depth = max(0, depth - 1)
            } else if c == target, depth == 0 {
                return i
            }
            i = s.index(after: i)
        }
        return nil
    }

    private func innerString(_ rule: String, isList: Bool) async -> String? {
        let r = await splitAndRun(rule, want: isList ? .list : .string)
        return isList ? r.list.joined(separator: "\n") : r.string
    }

    // MARK: - 模式分发（大小写不敏感 + JSON 隐式模式）

    private func evalByMode(_ rule: String, want: Want) async -> RuleResult {
        let lower = rule.lowercased()

        if lower.hasPrefix("@web:") || lower.hasPrefix("@webm:") {
            // ⚠️ `@web:` 是 5 字符、`@webm:` 是 6 字符 —— 必须分别 drop，
            //    否则 `@webm:http://…` 会残留 `m:` 前缀，URL 直接坏掉。
            let body = lower.hasPrefix("@webm:") ? String(rule.dropFirst(6)) : String(rule.dropFirst(5))
            let parts = body.components(separatedBy: "@html@@")
            let urlPart = parts[0].trimmingCharacters(in: .whitespaces)
            let rendered = await WebViewRuleEngine.shared.fetchRendered(url: urlPart)
            if parts.count > 1, !rendered.isEmpty {
                setDocument(html: rendered, baseUrl: urlPart)
                return jsoupRule(parts[1], want: want)
            }
            return RuleResult(string: rendered, list: [rendered])
        }
        if lower.hasPrefix("@get:{") {
            let key = String(rule.dropFirst(6).dropLast(1))
            let v = varGet(key)
            return RuleResult(string: v, list: [v])
        }
        if lower.hasPrefix("@put:{") {
            let inner = String(rule.dropFirst(6).dropLast(1))
            await putVariables(inner)
            return RuleResult()
        }
        // @JSon:/$. 显式，或内容为 JSON 且无元素 → 隐式 JSON 模式（对齐安卓，影响面最大）
        if lower.hasPrefix("@json:") || rule.hasPrefix("$.") || (ctx.element == nil && ctx.json != nil) {
            let r = lower.hasPrefix("@json:") ? String(rule.dropFirst(6)) : rule
            return jsonRule(r, want: want)
        }
        if lower.hasPrefix("@xpath:") || rule.hasPrefix("//") {
            let r = lower.hasPrefix("@xpath:") ? String(rule.dropFirst(7)) : rule
            return xpathRule(r, want: want)
        }
        if lower.hasPrefix("@css:") {
            return jsoupRule(String(rule.dropFirst(5)), want: want)
        }
        // ── 裸前缀（不带 `@`）─────────────────────────────────────────────
        // 实测来源（内置 501 个启用源普查）：
        //   · `css:`   14 条规则 / **整个 WNACG 源**都用这种写法
        //   · `json:`   5 条规则
        //   · `xpath:` 少量
        // 不处理的话它们会被当成 CSS 选择器（`css:.gallary_item`）→
        // SwiftSoup 抛 SelectorParseException → `try?` 吞成 0 个元素。
        if lower.hasPrefix("css:") {
            return jsoupRule(String(rule.dropFirst(4)), want: want)
        }
        if lower.hasPrefix("json:") {
            return jsonRule(String(rule.dropFirst(5)), want: want)
        }
        if lower.hasPrefix("xpath:") {
            return xpathRule(String(rule.dropFirst(6)), want: want)
        }
        // 🔴 未知的 `@前缀:` 规则 —— 最典型的是 Legado 的 `@rule:<其它规则名>`
        //    （「复用本图源的另一个规则」）。⚠️ 我们的 309 条内置源里**一条都没用**
        //    （已实测统计 = 0），所以**没有凭猜实现它的语义** —— 猜错反而会引入新 bug。
        //    但用户导入的第三方源可能会用，以前这种规则会被当成 CSS 选择器 →
        //    SwiftSoup 抛异常 → `try?` 吞成空 → **用户完全看不到原因**
        //    （「源坏了」和「这章真没图」无法区分）。
        //    这里把「静默失败」变成「可定位」：记一条明确诊断。
        if rule.hasPrefix("@"), let colon = rule.firstIndex(of: ":") {
            let name = String(rule[rule.index(after: rule.startIndex)..<colon])
            DiagLog.event("rule", "unknown",
                          "未支持的 @\(name): 前缀，规则=\(rule.prefix(60))（按 CSS 兜底处理，结果可能为空）")
        }
        return jsoupRule(rule, want: want)
    }

    /// @put:{k1:rule1,k2:rule2} 多键（宽松拆分，每值本身是规则）
    ///
    /// ⚠️ 曾经这里是**同步**函数，内部用 `DispatchSemaphore.wait(15s)` 等
    /// `innerString` 的 async 结果。`AnalyzeRule` 的整条求值链本身就跑在
    /// Swift 并发协作线程池上，在这个池子上 `wait()` 会**占住一个协作线程不还**；
    /// 多个 put 键 / 多个图源并发解析时会直接把线程池饿死 → 规则求值奇慢甚至卡死。
    /// 现在改成纯 async、并发求值：不阻塞任何线程，N 个键的耗时从「相加」变「取最大」。
    private func putVariables(_ inner: String) async {
        var depth = 0; var inQ = false; var cur = ""; var parts: [String] = []
        for ch in inner {
            if ch == "\"" { inQ.toggle(); cur.append(ch); continue }
            if ch == "{" || ch == "[" { depth += 1 }
            if ch == "}" || ch == "]" { depth -= 1 }
            if ch == "," && depth == 0 && !inQ { parts.append(cur); cur = ""; continue }
            cur.append(ch)
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(cur) }

        // 先解析出 (key, valueRule) 列表，再一次性并发求值
        var jobs: [(key: String, rule: String)] = []
        for p in parts {
            guard let colon = p.firstIndex(of: ":") else { continue }
            let key = String(p[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            let valueRule = String(p[p.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            guard !key.isEmpty, !valueRule.isEmpty else { continue }
            jobs.append((key, valueRule))
        }
        guard !jobs.isEmpty else { return }

        // 并发求值，但写回变量表必须收口（variableMap 是共享可变状态，见 varLock 说明）。
        // ⚠️ 子任务里若含 `@js:` 且 JS 调 `java.put(...)`，会在**并发中**直接写变量表 ——
        //    所以写回也必须走 `varSetAll`（持锁），不能裸写。
        let results = await withTaskGroup(of: (String, String).self) { group -> [(String, String)] in
            for j in jobs {
                group.addTask { [weak self] in
                    let v = await self?.innerString(j.rule, isList: false) ?? ""
                    return (j.key, v)
                }
            }
            var acc: [(String, String)] = []
            for await r in group { acc.append(r) }
            return acc
        }
        varSetAll(results)
    }

    /// 剥离规则尾部 @Header:{...}，返回干净规则与请求头
    /// 摘掉规则尾部的请求头/选项块，返回「干净的规则 + 头部」。
    ///
    /// 支持两种写法：
    ///   ① `@Header:{k:v,...}`    —— Legado / 绘漫岛 通用（58 处）
    ///   ② `,{"headers":{...}}`   —— Legado 的「URL 选项」后缀（1 处：亲亲漫画封面）
    ///
    /// ⚠️ ② 必须在 `#`/`##` 切分**之前**摘掉：
    ///    `$.coverUrl##$##,{"headers":{"Referer":"…"}}`
    ///    若先把 `,{…}` 当 replacement，会把它整段插进封面 URL 里，直接毁掉地址。
    func extractTrailingHeaders(_ rule: String) -> (clean: String, headers: [String: String]) {
        var r = rule
        var headers: [String: String] = [:]

        if let block = AnalyzeUrl.extractBlock(&r, prefix: "@Header:"), !block.isEmpty {
            headers.merge(AnalyzeUrl.parseLenientHeaders(block)) { _, new in new }
        }
        if let opt = Self.stripTrailingOption(&r),
           let d = opt.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let hs = obj["headers"] as? [String: Any] {
            for (k, v) in hs { headers[k] = (v as? String) ?? String(describing: v) }
        }

        guard !headers.isEmpty else { return (rule, [:]) }
        let base = ctx.baseUrl
        for (k, v) in headers {
            let lv = v.lowercased()
            if v == "host" { headers[k] = URL(string: base)?.host ?? v }
            else if lv == "thispage" || lv == "referer:host" || lv == "prepage" { headers[k] = base }
        }
        return (r.trimmingCharacters(in: .whitespacesAndNewlines), headers)
    }

    /// 摘掉尾部的 `,{...}` 选项块，返回块内文本（不含最外层花括号）。
    /// 形态必须是 `…,{…}`（花括号前紧跟逗号），否则返回 nil 且不改动入参。
    static func stripTrailingOption(_ rule: inout String) -> String? {
        let t = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasSuffix("}") else { return nil }
        var depth = 0
        var open: String.Index? = nil
        var i = t.endIndex
        while i > t.startIndex {
            i = t.index(before: i)
            if t[i] == "}" { depth += 1 }
            else if t[i] == "{" {
                depth -= 1
                if depth == 0 { open = i; break }
            }
        }
        guard let o = open, o > t.startIndex, t[t.index(before: o)] == "," else { return nil }
        let inner = String(t[t.index(after: o)..<t.index(before: t.endIndex)])
        rule = String(t[t.startIndex..<t.index(before: o)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return inner
    }
    // MARK: - JSON 规则（支持 &&/|| 组合）

    private func jsonRule(_ rule: String, want: Want) -> RuleResult {
        guard let json = ctx.json else { return RuleResult() }
        var segments: [(String, String)] = []
        // 🔴 JSON 规则也要切 `%%`（交错）—— 旧代码只切 `||`/`&`，
        //    `$.a@text%%$.b@text` 会整串进 tokenize 成怪 key → **静默空**。
        //    安卓 JSON 模式（AnalyzeByJSoup）同样切 `%%`。
        //    ⚠️ 单 `|` **不在这里切**：它在选择器级才是「或」（见 `CssSelect.splitOr`），
        //       JSON 侧语义不确定，贸然切可能改变现有行为。（由智能体「规则漏洞A」发现）
        //    同时加引号/括号感知 —— 和顶层 `splitAndRun` 保持同一套标准。
        var buf = ""; var mode = "&"
        var i = rule.startIndex
        var jdepth = 0
        var jquote: Character? = nil
        while i < rule.endIndex {
            let c = rule[i]
            if let q = jquote {
                buf.append(c)
                if c == q { jquote = nil }
                i = rule.index(after: i); continue
            }
            if c == "\"" || c == "'" { jquote = c; buf.append(c); i = rule.index(after: i); continue }
            if c == "[" || c == "(" || c == "{" { jdepth += 1; buf.append(c); i = rule.index(after: i); continue }
            if c == "]" || c == ")" || c == "}" { jdepth = max(0, jdepth - 1); buf.append(c); i = rule.index(after: i); continue }
            if jdepth == 0, rule.index(after: i) < rule.endIndex {
                let n = rule[rule.index(after: i)]
                if c == "|" && n == "|" {
                    segments.append((buf, mode)); buf = ""; mode = "||"; i = rule.index(i, offsetBy: 2); continue
                }
                if c == "%" && n == "%" {
                    segments.append((buf, mode)); buf = ""; mode = "%%"; i = rule.index(i, offsetBy: 2); continue
                }
            }
            if jdepth == 0, c == "&" {
                segments.append((buf, mode)); buf = ""; mode = "&"; i = rule.index(after: i); continue
            }
            buf.append(c); i = rule.index(after: i)
        }
        segments.append((buf, mode))

        var merged = RuleResult()
        for (idx, seg) in segments.enumerated() {
            let vals = JsonPath.query(json, seg.0)
            let strs = vals.map { JsonPath.asString($0) }
            let r = RuleResult(string: strs.first ?? "", list: strs)
            if idx == 0 { merged = r; continue }
            if seg.1 == "||" {
                if merged.list.isEmpty && merged.string.isEmpty && merged.elements.isEmpty { merged = r }
            } else if seg.1 == "%%" {
                // 🔴 `%%` 是**逐项交错**（Legado 语义），不是简单拼接。
                //    旧代码把它和 `&` 同等 append，顺序/配平全错。
                //    这里和顶层 `splitAndRun` 的 `%%` 处理保持一致（短侧用完即止）。
                //    （由复审智能体发现）
                var out: [String] = []
                let a = merged.list, b = r.list
                for k in 0..<max(a.count, b.count) {
                    if k < a.count { out.append(a[k]) }
                    if k < b.count { out.append(b[k]) }
                }
                merged.list = out
                if !merged.list.isEmpty { merged.string = merged.list.first ?? merged.string }
            } else {
                merged.list += r.list
                if !r.string.isEmpty { merged.string += r.string }
            }
        }
        return merged
    }

    private func xpathRule(_ rule: String, want: Want) -> RuleResult {
        guard let html = ctx.element.flatMap({ try? $0.html() }), !html.isEmpty else { return RuleResult() }
        if want == .elements {
            let frags = XPathEngine.queryHTML(html: html, xpath: rule, baseUrl: ctx.baseUrl)
            var els: [Element] = []
            for f in frags {
                guard let doc = try? SwiftSoup.parse(f), let body = doc.body(), let first = try? body.children().first() else { continue }
                els.append(first)
            }
            return RuleResult(list: frags, elements: els.map { RuleNode(element: $0) })
        }
        // 字符串输出 = 节点外层 HTML（对齐安卓 JXNode.toString）
        let vals = XPathEngine.queryHTML(html: html, xpath: rule, baseUrl: ctx.baseUrl)
        return RuleResult(string: vals.first ?? "", list: vals)
    }

    // MARK: - jsoup 链式（元素步: [n]索引 / !排除 / >子过滤 / text.包含 / children）

    private func jsoupRule(_ rule: String, want: Want) -> RuleResult {
        // ── 顶层 OR（单 `|`）必须先切 ──────────────────────────────────────
        // ⚠️ 顺序必须「先 `|` 后 `@`」，与安卓一致：`AnalyzeByJSoup` 在
        //    `getStringList`/`getElements` 里**先**按 `|`/`&`/`%%` 切整条规则，
        //    **再**把每段交给 `getResultList` 按 `@` 切。
        //    iOS 原先反了 —— 先按 `@` 切，于是
        //    `class.title@text|class.txtA@text` 被切成
        //    ["class.title", "text|class.txtA", "text"]，中间那段既不是取值关键字、
        //    也不是合法 CSS → 整条链静默返回空。
        //    实测 78 条规则受影响（快看漫画/虎虎漫画等的搜索列表与书名）。
        //
        //    这里用 `CssSelect.splitOr`：它已做**方括号/引号感知**，
        //    不会误切 `[href|=x]` 或 `a[href*='x|y']`。
        //    `||` 在上层 `splitAndRun` 已消费，不会走到这里。
        let branches = CssSelect.splitOr(rule)
        if branches.count > 1 {
            for b in branches {
                let r = jsoupRuleSingle(b, want: want)
                // 安卓 `|` 是**短路**语义：取第一个非空分支即止
                if !r.list.isEmpty || !r.elements.isEmpty { return r }
            }
            return RuleResult()
        }
        return jsoupRuleSingle(rule, want: want)
    }

    /// 单个 OR 分支的 jsoup 链式求值（不含顶层 `|` 切分）。
    private func jsoupRuleSingle(_ rule: String, want: Want) -> RuleResult {
        guard let root = ctx.element else { return RuleResult() }
        var nodes: [Element] = [root]
        var lastKey = ""

        // 🔴 必须**忽略引号/括号**地按 `@` 切分 ——
        //    `a[href*="x@y"]@href` 里的 `@` 属于属性值，裸 `split(separator:"@")`
        //    会切成 `a[href*="x` / `y"]` / `href` → SwiftSoup 抛异常 →
        //    `try?` 吞成 0 元素 → **静默解析失败**。
        //    （老代码就是这么写的，由智能体「规则漏洞A」发现）
        let steps = Self.splitUnquoted(rule, "@")
        for (stepIdx, step) in steps.enumerated() {
            if step.isEmpty { continue }
            // ⚠️ 「末段是取值键」这一判定必须知道**位置**（对齐安卓 getResultList：
            //    除最后一段外都是选择器，最后一段无条件交给 getResultLast）。
            let isLast = (stepIdx == steps.count - 1)
            let (kind, key) = parseStep(step, isLast: isLast, wantElements: want == .elements)
            if kind == .select {
                var sel = key
                var index: Int? = nil
                var exclude: (Int, Int)? = nil
                var childFilter = ""
                var textFilter = ""
                var work = sel
                // ── `>` 子过滤器 ────────────────────────────────────────────
                // ⚠️ **只在 `>` 后紧跟 `class.`/`id.`/`tag.`/`text.` 时才当过滤器**，
                //    否则 `>` 是 **CSS 子代组合器**，必须整段交给 SwiftSoup。
                //    安卓（AnalyzeByJSoup.smali:652/706-776）正是这么判的。
                //    原实现无条件切 `>`，把 `A>B` 解析成「选出 A 中**含有** B 后代的 A」
                //    （返回**容器**）而不是 B 本身 → 后续 name/url 全落在容器上。
                //    实测 20+ 条规则（`.manga-list>a`、`.mh-list>li`、`class.row3>li`、
                //    `class.ul-36>li` 等）因此搜索 0 结果 / 章节 0 条。
                if let r = work.range(of: ">") {
                    let after = String(work[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if after.hasPrefix("class.") || after.hasPrefix("id.")
                        || after.hasPrefix("tag.") || after.hasPrefix("text.") {
                        childFilter = after
                        work = String(work[..<r.lowerBound])
                    }
                }
                if let r = work.range(of: "!") {
                    let ex = String(work[r.upperBound...])
                    work = String(work[..<r.lowerBound])
                    let pp = ex.split(separator: ":").compactMap { Int($0) }
                    if pp.count >= 1 { exclude = (pp[0], pp.count > 1 ? pp[1] : pp[0]) }
                }
                // [n] 索引：末段纯数字（含负数）
                if let r = work.range(of: ".", options: .backwards) {
                    let tail = work[work.index(after: r.lowerBound)...]
                    if let n = Int(tail), !tail.isEmpty {
                        index = n
                        work = String(work[..<r.lowerBound])
                    }
                }
                if work.hasPrefix("text.") {
                    textFilter = String(work.dropFirst(5))
                    work = "text"
                }
                if work.hasPrefix("tag.") { work = String(work.dropFirst(4)) }
                else if work.hasPrefix("class.") { work = "." + String(work.dropFirst(6)) }
                else if work.hasPrefix("id.") { work = "#" + String(work.dropFirst(3)) }

                var next: [Element] = []
                if work == "text" {
                    for n in nodes {
                        let t = (try? n.ownText()) ?? ""
                        if !textFilter.isEmpty {
                            if t.contains(textFilter) { next.append(n) }
                        } else { next.append(n) }
                    }
                } else if work == "children" {
                    for n in nodes { next += (try? n.children()) ?? Elements() }
                } else if !work.isEmpty {
                    // ⚠️ 走 CssSelect 而不是直接 el.select：Legado 的 `|` 是「或」，
                    //    而 CSS 里 `|` 是命名空间分隔符 → SwiftSoup 抛
                    //    SelectorParseException → try? 吞掉 → 静默返回 0 个元素。
                    //    84 个启用源的 ruleSearchList、3 个的 ruleChapterList
                    //    （含「紳士漫畫」）都踩在这个坑上。详见 CssSelect.swift。
                    for n in nodes { next += CssSelect.all(n, work) }
                }
                if let ex = exclude {
                    var fixed: [Element] = []
                    let cnt = next.count
                    for (i2, e) in next.enumerated() {
                        var idx = ex.0 < 0 ? cnt + ex.0 : ex.0
                        var end = ex.1 < 0 ? cnt + ex.1 : ex.1
                        if idx > end { swap(&idx, &end) }
                        if i2 < idx || i2 > end { fixed.append(e) }
                    }
                    next = fixed
                }
                if !childFilter.isEmpty {
                    var cf = childFilter
                    if cf.hasPrefix("class.") { cf = "." + String(cf.dropFirst(6)) }
                    else if cf.hasPrefix("id.") { cf = "#" + String(cf.dropFirst(3)) }
                    else if cf.hasPrefix("tag.") { cf = String(cf.dropFirst(4)) }
                    next = next.filter { el in !CssSelect.all(el, cf).isEmpty }
                }
                if let n = index {
                    let cnt = next.count
                    let real = n < 0 ? cnt + n : n
                    next = next.indices.contains(real) ? [next[real]] : []
                }
                nodes = next
            } else {
                lastKey = key
            }
        }

        if lastKey.isEmpty, want == .elements {
            return RuleResult(elements: nodes.map { RuleNode(element: $0) })
        }
        var out: [String] = []
        for n in nodes {
            let v = extract(n, lastKey.isEmpty ? "text" : lastKey)
            if !v.isEmpty { out.append(v) }   // 跳过空值（对齐安卓）
        }
        var seen = Set<String>()
        out = out.filter { seen.insert($0).inserted }   // 去重保序（对齐安卓）
        return RuleResult(string: out.first ?? "", list: out)
    }

    enum StepKind { case select, value }

    /// 判断一个 `@` 段是「选择器」还是「取值键」。
    ///
    /// ## 对齐安卓（这是本次修正的核心）
    /// `AnalyzeByJSoup.getResultList` 把规则按 `@` 切分后：
    ///   · **除最后一段外**，每段都当**选择器**（`getElementsSingle`）；
    ///   · **最后一段**无条件交给 `getResultLast` → 不是
    ///     `text/textNodes/ownText/html` 就当 **`el.attr(段)`**。
    ///
    /// 原实现用「白名单命中才是取值，否则当选择器」——
    /// 于是所有**未列进白名单的属性名**（`style` / `data-bg` / `data-hreflink` /
    /// `data-background` / `syrc` / `jhc-data` …）都被当成 CSS 标签名送进
    /// `SwiftSoup.select()` → 匹配 0 个元素 → 静默返回空。
    /// 实测 25 条规则受影响（漫客栈 `tag.a@data-hreflink` → **章节打不开**；
    /// 酷漫屋 `.mh-cover@style` → 封面空；顶通漫画 `class.img-box>img@syrc` …）。
    ///
    /// - Parameters:
    ///   - isLast: 是否是 `@` 链的最后一段
    ///   - wantElements: 本次求值要的是「元素」还是「字符串」。
    ///     ⚠️ 要元素时（列表规则），**末段也是选择器** ——
    ///     `class.book-list@tag.li` / `class.list@li` 的 `li` 必须当标签选择器，
    ///     不能当属性名（否则 `.elements` 会返回空）。
    private func parseStep(_ step: String, isLast: Bool, wantElements: Bool) -> (StepKind, String) {
        // ① 明确的取值关键字（安卓 getResultLast 的 switch 分支）
        switch step {
        case "text", "textNodes", "ownText", "html", "all", "children", "content":
            return (.value, step)
        default:
            break
        }
        // ② 显式 `attr:` 前缀
        if step.hasPrefix("attr:") { return (.value, String(step.dropFirst(5))) }
        // ③ 末段 + 纯属性名样式 → 取值键（对齐安卓「末段无条件当 attr」）
        if isLast, !wantElements, Self.isBareAttributeName(step) {
            return (.value, step)
        }
        return (.select, step)
    }

    /// 是否是「纯属性名样式」的 token：字母/下划线开头，且只含
    /// 字母、数字、下划线、连字符。
    ///
    /// 含 `.` `[` `]` `>` `!` `#` 空格 `|` `:` `*` `,` 的一律**不是**属性名
    /// （那些是选择器语法），因此 `tag.a` / `.foo` / `a[href]` / `.a>li`
    /// 都不会被误判成属性。
    static func isBareAttributeName(_ s: String) -> Bool {
        guard let f = s.first, f.isLetter || f == "_" else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    private func extract(_ el: Element, _ key: String) -> String {
        switch key {
        case "text": return (try? el.text()) ?? ""
        case "textNodes":
            let nodes = el.getChildNodes()
            return nodes.compactMap { node -> String? in
                guard let t = node as? TextNode else { return nil }
                let v = (try? t.text()) ?? ""
                return v.isEmpty ? nil : v
            }.joined(separator: "\n")
        case "ownText": return (try? el.ownText()) ?? ""
        // 🔴 `@html` 的语义对齐 Legado：取 **outerHtml**（含元素自身标签），
        //    并且**先删掉 `<script>` / `<style>`**。
        //    我们以前是 `el.html()`（inner html，不含自身标签）且不过滤 ——
        //    依赖「匹配外层标签」的正则（16 条内置规则在用）会直接失灵。
        //    （由智能体「规则漏洞C」对照 Legado jsoup.kt:271-277 发现）
        //
        // ⚠️ **不能用 `el.clone()`** —— SwiftSoup 全版本（2.3.2 / 2.6.0 / master）的
        //    `Node`/`Element` 上都没有这个方法（只有 `Attributes.clone()`），
        //    用它会直接编译失败。改用「解析 outerHtml 拿一份副本」实现，
        //    这样 select/remove 动的是副本，不会污染原始文档。
        //    （这条是复审智能体验出来的硬编译错，已修。）
        case "html", "all":
            guard let raw = try? el.outerHtml() else { return "" }
            guard let doc = try? SwiftSoup.parse(raw),
                  let body = try? doc.body(),
                  let first = try? body.children().first() else { return raw }
            _ = try? first.select("script,style").remove()
            return (try? first.outerHtml()) ?? raw
        case "children":
            return el.getChildNodes().compactMap { $0 as? Element }.map { (try? $0.html()) ?? "" }.joined(separator: "\n")
        case "content":
            if let meta = try? el.select("meta").first(), let c = try? meta.attr("content") { return c }
            return (try? el.text()) ?? ""
        default:
            if key.hasPrefix("attr:") { return (try? el.attr(String(key.dropFirst(5)))) ?? "" }
            return (try? el.attr(key)) ?? (try? el.text()) ?? ""
        }
    }

    // MARK: - JS

    /// 规则段（普通段 / JS 段）
    struct RuleSegment { var text: String; var isJS: Bool }

    /// 按安卓 `jsPattern = (<js>[\w\W]*?</js>|@js:[\w\W]*$)` 切分规则串。
    /// - `<js>…</js>`：可出现在任意位置，切为 JS 段
    /// - `@js:…`：只在**行尾**（或串尾）才算 JS 段，避免误伤 JS 代码里字面量的 "@js:"
    static func splitJsSegments(_ rule: String) -> [RuleSegment] {
        var segs: [RuleSegment] = []
        var cursor = rule.startIndex
        while cursor < rule.endIndex {
            let rest = rule[cursor...]
            // 最近的 <js> 或 @js:
            let ltJs = rest.range(of: "<js>")
            // 对齐安卓 `@js:[\w\W]*$`：**第一个** `@js:` 起、直到串尾都算 JS 段。
            // （不做"前一个字符必须是分隔符"的启发式判断——真实规则形如
            //   `$.chapterid@js:baseUrl+result+'.html'`，`@js:` 前面是普通字符。）
            let atJSRange: Range<String.Index>? = rest.range(of: "@js:")
            // 取更靠前的那个
            var jsStart: Range<String.Index>? = nil
            var jsIsTag = false
            if let a = ltJs, let b = atJSRange { if a.lowerBound <= b.lowerBound { jsStart = a; jsIsTag = true } else { jsStart = b } }
            else if let a = ltJs { jsStart = a; jsIsTag = true }
            else if let b = atJSRange { jsStart = b }

            guard let js = jsStart else {
                let tail = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty { segs.append(RuleSegment(text: tail, isJS: false)) }
                break
            }
            let head = String(rest[..<js.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            // `-@js:...` / `-<js>...`：`-` 是"结果反转"前缀，属于 JS 段，不是独立规则段
            if head == "-" {
                let body = jsIsTag ? String(rest[js.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                                   : String(rest[js.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                segs.append(RuleSegment(text: "-" + body, isJS: true))
                cursor = jsIsTag ? (rule.range(of: "</js>", range: js.upperBound..<rule.endIndex).map { $0.upperBound } ?? rule.endIndex)
                                 : rule.endIndex
                continue
            }
            if !head.isEmpty { segs.append(RuleSegment(text: head, isJS: false)) }
            if jsIsTag {
                guard let close = rule.range(of: "</js>", range: js.upperBound..<rule.endIndex) else {
                    let tail = String(rest[js.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !tail.isEmpty { segs.append(RuleSegment(text: tail, isJS: true)) }
                    break
                }
                segs.append(RuleSegment(text: String(rule[js.lowerBound..<close.upperBound]), isJS: true))
                cursor = close.upperBound
            } else {
                // @js: 到串尾（对齐安卓 `@js:[\w\W]*$`）
                segs.append(RuleSegment(text: String(rule[js.lowerBound...]), isJS: true))
                cursor = rule.endIndex
            }
        }
        return segs
    }

    private func replaceInlineJS(_ rule: String) async -> String {
        guard rule.contains("{{") else { return rule }
        var out = rule
        var guardCount = 0
        while let r1 = out.range(of: "{{"), let r2 = out.range(of: "}}", range: r1.upperBound..<out.endIndex), guardCount < 8 {
            guardCount += 1
            let code = String(out[r1.upperBound..<r2.lowerBound])
            let val = await evalJS(code, result: "")
            out.replaceSubrange(r1.lowerBound..<r2.upperBound, with: val)
        }
        return out
    }

    func evalJS(_ code: String, result: String) async -> String {
        await js.evaluate(code, java: self, result: result, baseUrl: ctx.baseUrl,
                          variables: varSnapshot(), headers: ctx.headers).text
    }

    /// 应用 `RULE_BOOK_CONTENT_DECODER`（正文后期规则）—— 对**下载下来的加密图片字节**解密。
    ///
    /// 对照安卓 `ChapterBrowseAdapter.m25054while()`：
    /// ```java
    /// AnalyzeRule r = new AnalyzeRule(baseUrl);
    /// r.setContent(headersJson, bytes, imgUrl);        // 第二个参数是 byte[]
    /// byte[] out = r.getBytes(ruleBookContentDecoder, false);
    /// ```
    /// 规则里以 `result` 消费**字节数组**，返回的也是字节数组（`java.decryptESBytes`）
    /// 或通过 `BitmapFactory/Bitmap/Canvas` 重排后的图片字节。返回 nil 表示「无需/无法解密」。
    ///
    /// - Returns: 解密后的字节；若规则求值返回空/异常则返回 nil（调用方保留原始字节）。
    func applyContentDecoder(_ rule: String, bytes: Data, headers: [String: String] = [:]) async -> Data? {
        var code = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if code.isEmpty { return nil }
        if code.hasPrefix("<js>") {
            code = String(code.dropFirst(4))
            if code.hasSuffix("</js>") { code = String(code.dropLast(5)) }
        } else if code.hasPrefix("@js:") {
            code = String(code.dropFirst(4))
        } else {
            return nil        // 非 JS 规则不支持字节处理
        }
        let oldHeaders = ctx.headers
        if !headers.isEmpty { ctx.headers = headers }
        defer { ctx.headers = oldHeaders }
        let out = await js.evaluate(code, java: self, result: "", baseUrl: ctx.baseUrl,
                                    variables: varSnapshot(), headers: ctx.headers,
                                    resultBytes: [UInt8](bytes))
        // 完成值是 Number 数组 → 还原成 Data。
        // 两种形态都要认：`JSON.stringify` 产出 `[1,2,3]`；
        // 而 `result` 原样回退时 JS 数组 `.toString()` 产出 `1,2,3`。
        let t = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var nums: [Int] = []
        if let d = t.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: d) as? [Any], !arr.isEmpty {
            nums = arr.compactMap { ($0 as? NSNumber)?.intValue }
        } else if t.contains(",") && !t.contains("[") {
            nums = t.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        } else if let n = Int(t), t.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789")) != nil {
            nums = [n]
        }
        guard !nums.isEmpty else { return nil }
        var data = Data(capacity: nums.count)
        for n in nums { data.append(UInt8(truncatingIfNeeded: n)) }
        return data.isEmpty ? nil : data
    }

    // MARK: - `@js:` 的 `result` 绑定（唯一真相源）

    /// 计算 `@js:` / `<js>` 规则里 `result` 到底绑什么。
    ///
    /// 🔴 这是**唯一**的计算处 —— `@js:` 求值分支和规则调试器都调它。
    ///    以前这段逻辑内联在分支里，调试器要跑同一套绑定就只能复制一份，
    ///    一旦分叉，就会出现「调试器里好好的、真机却不出图」这种最难查的偏差。
    ///
    /// 规则（对齐安卓绘漫岛的 WrapForJS 语义）：
    /// · **文档场景**（`ctx.jsonIsNode == false`，如正文页 / 搜索页）：
    ///   绑**完整响应体** —— HTML 站点优先 `rawHtml`，JSON 站点用 `rawJsonText`。
    ///   ⚠️ 曾经这里只绑 `ctx.element.html()`（某个元素的内部 HTML），
    ///      真机实测正文页只有 1882~1913 字（整页 38249），
    ///      于是 `result.match(/params=…/)` 永远匹配不上 → 所有加密站点的
    ///      `@js:` 正文规则全挂，而且日志里看不出任何异常。
    /// · **节点场景**（`ctx.jsonIsNode == true`，逐章 / 逐搜索结果迭代）：
    ///   保持 `element.html()`，因为规则要的就是「当前这一条」。
    private func jsPreset() -> String {
        if ctx.jsonIsNode, let el = ctx.element {
            return (try? el.html()) ?? ""
        }
        // 响应体本体（非节点）时，JSON 要按**原始文本**传，而不是重新序列化的 JSON。
        if ctx.json != nil, let raw = ctx.rawJsonText { return raw }
        if let raw = ctx.rawHtml, !raw.isEmpty { return raw }
        if let el = ctx.element { return (try? el.html()) ?? "" }
        return ""
    }

    // MARK: - 规则调试器：JS 规则模式

    /// `debugJS` 的返回：不只是结果，还带**中间过程**。
    struct JSDebugInfo {
        /// 规则里 `result` 的长度（判断「绑定对不对」的第一手证据）
        var presetLength = 0
        /// `result` 是否被绑成对象/数组（而不是字符串）
        var presetIsObject = false
        /// `result` 开头 160 字（一眼看出拿到的是 HTML 还是别的）
        var presetPreview = ""
        /// JS 的返回值（对象/数组会被 JSON.stringify）
        var value = ""
        /// 返回值里若含 Jsoup 元素，这里是元素个数
        var elementCount = 0
        /// JS 抛出的异常原文（无异常为 nil）
        var error: String?
        /// 规则里 `hmd.toast(...)` / `java.log(...)` 打印的内容（相当于 console.log）
        var logs: [String] = []
    }

    /// 规则调试器专用 —— 跑一段 `@js:` / `<js>` 规则，并把**中间过程**一并返回。
    ///
    /// 为什么不能直接用 `getString(rule)`：那条路只回最终值，
    /// JS 抛的异常、`result` 的实际长度与类型全都丢掉了。
    /// 结果是用户写错一条 JS 规则时**只看到「规则没命中」**，
    /// 分不清是「页面没抓对」「绑定不对」「JS 报错」还是「返回格式不对」——
    /// 这四种原因的修法完全不同。
    func debugJS(_ rawRule: String) async -> JSDebugInfo {
        var info = JSDebugInfo()
        let preset = jsPreset()
        info.presetLength = preset.count
        info.presetIsObject = ctx.jsonIsNode
        info.presetPreview = String(preset.prefix(160))

        // 与 evalJSRule 完全相同的规则拆壳（`<js>…</js>` / `@js:` / `-` 反转）
        var code = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
        if code.hasPrefix("-") { code = String(code.dropFirst()) }
        if code.hasPrefix("<js>") {
            code = String(code.dropFirst(4))
            if code.hasSuffix("</js>") { code = String(code.dropLast(5)) }
        } else if code.hasPrefix("@js:") {
            code = String(code.dropFirst(4))
        }

        let out = await js.evaluate(code, java: self, result: preset, baseUrl: ctx.baseUrl,
                                    variables: varSnapshot(), headers: ctx.headers,
                                    resultAsObject: ctx.jsonIsNode)
        info.value = out.text
        info.elementCount = out.elements.count
        info.error = out.error
        info.logs = out.logs
        DiagLog.event("debug", "js",
                      "JS 模式：result=\(info.presetLength) 字 返回=\(info.value.count) 字 "
                      + "元素=\(info.elementCount) 错误=\(info.error?.prefix(80) ?? "无")")
        return info
    }

    /// 求值 <js>...</js> / @js: 规则，结果转成 RuleResult
    /// - Parameter presetIsObject: presetResult 是否为「对象/数组」（对齐安卓
    ///   只有 Map/List 才 WrapForJS 成 JS 对象；字符串保持字符串）。
    private func evalJSRule(_ rule: String, presetResult: String, want: Want,
                            presetIsObject: Bool = false) async -> RuleResult {
        var code = rule
        var reverse = false
        if code.hasPrefix("-") {           // `-@js:...` / `-<js>...`：结果反转
            reverse = true
            code = String(code.dropFirst())
        }
        if code.hasPrefix("<js>") {
            code = String(code.dropFirst(4))
            if code.hasSuffix("</js>") { code = String(code.dropLast(5)) }
        } else if code.hasPrefix("@js:") {
            code = String(code.dropFirst(4))
        }
        let out = await js.evaluate(code, java: self, result: presetResult, baseUrl: ctx.baseUrl,
                                    variables: varSnapshot(), headers: ctx.headers,
                                    resultAsObject: presetIsObject)
        // JS 直接返回了 Jsoup 元素（规则里常见 `return doc.select(...)`）→ 直接变成节点。
        // 这条路径必须走原生元素，靠 JSON 序列化会把元素变成 [{},{}]。
        if !out.elements.isEmpty {
            var els = out.elements
            if reverse { els.reverse() }
            var r = RuleResult()
            r.elements = els.map { RuleNode(element: $0) }
            r.list = els.map { (try? $0.text()) ?? "" }
            r.string = r.list.first ?? ""
            return r
        }
        // 🔎 插桩：**要元素却一个都没拿到** —— 这是「章节/搜索列表 0 条」最典型的失败模式。
        //    包子漫画的 `ruleChapterList`（`@js: … doc.select(...)`）就挂在这里：
        //    日志只显示「规则(空)」，看不出是 JS 抛错、选择器没命中、还是返回值没被识别成元素。
        //    这三者的修法完全不同，所以必须把「拿到了什么」打出来。
        if want == .elements {
            DiagLog.event("js", "elements",
                          "⚠️ @js: 规则未返回元素（返回文本 \(out.text.count) 字，前 80 字：\(out.text.prefix(80))）")
        }
        var res = Self.ruleResult(fromJS: out.text, want: want)
        if reverse { res.list.reverse(); res.string = res.list.first ?? res.string; res.elements.reverse() }
        return res
    }

    /// JS 完成值标准化：JSON 数组/对象或纯文本 → RuleResult
    private static func ruleResult(fromJS out: String, want: Want) -> RuleResult {
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return RuleResult() }
        if let data = t.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if let arr = obj as? [Any] {
                let strs = arr.map { JsonPath.asString($0) }
                var result = RuleResult(string: strs.first ?? "", list: strs)
                if want == .elements {
                    result.elements = arr.map { item -> RuleNode in
                        if let s = item as? String, s.contains("<") {
                            if let doc = try? SwiftSoup.parse(s), let body = doc.body(), let first = try? body.children().first() { return RuleNode(element: first) }
                            return RuleNode(json: s)
                        }
                        if let dict = item as? [String: Any] { return RuleNode(json: JsonPath.stringify(dict)) }
                        return RuleNode(json: JsonPath.asString(item))
                    }
                }
                return result
            }
            if want == .elements { return RuleResult(string: t, list: [t], elements: [RuleNode(json: t)]) }
            return RuleResult(string: t, list: [t])
        }
        return RuleResult(string: t, list: t.isEmpty ? [] : [t])
    }
    // MARK: - java.* 扩展后端

    public func javaGet(_ key: String) -> String { varGet(key) }
    public func javaPut(_ key: String, _ value: String) { varSet(key, value) }
    public func javaAjax(_ urls: [String]) async -> [String] {
        await withTaskGroup(of: (Int, String).self) { group in
            for (i, u) in urls.enumerated() {
                group.addTask { (i, await HttpFetcher.shared.fetchText(u, headers: self.ctx.headers)) }
            }
            var out = [String](repeating: "", count: urls.count)
            for await (i, t) in group { out[i] = t }
            return out
        }
    }
    public func javaPost(_ url: String, body: String, headers: [String: String]) async -> String {
        await HttpFetcher.shared.fetchText(url, method: "POST", body: body, headers: headers.isEmpty ? ctx.headers : headers)
    }
    public func javaGet(_ url: String, headers: [String: String]) async -> String {
        await HttpFetcher.shared.fetchText(url, headers: headers.isEmpty ? ctx.headers : headers)
    }
    public func decryptAES(_ data: String, key: String, iv: String, mode: String) -> String {
        if mode.uppercased().contains("ECB") {
            if let d = SourceDecrypt.base64Flexible(data), let dec = AESECB.run(d, key: Array(key.utf8)) {
                return String(data: dec, encoding: .utf8) ?? ""
            }
            return data
        }
        return SourceDecrypt.aesDecrypt(data, key: key) ?? data
    }
}

/// 供列表循环使用的元素包装
struct RuleNode {
    let element: Element?
    let jsonText: String?
    init(element: Element?) { self.element = element; self.jsonText = nil }
    init(json: String) { self.element = nil; self.jsonText = json }
    var html: String { (try? element?.html()) ?? jsonText ?? "" }
}

/// AES-ECB（JS 扩展 decryptAES 用）
enum AESECB {
    static func run(_ data: Data, key: [UInt8]) -> Data? {
        var out = [UInt8](repeating: 0, count: data.count + 32)
        var outLen = 0
        let status = key.withUnsafeBufferPointer { kp in
            data.withUnsafeBytes { dp in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        kp.baseAddress, kp.count, nil,
                        dp.baseAddress, dp.count, &out, out.count, &outLen)
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(out[0..<outLen])
    }
}

/// AES 任意模式（CBC/ECB）× 任意 key/IV 的**原始字节**加解密。
///
/// 用于 `java.decryptESBytes(mode, charset, data, key, iv)` —— 漫蛙/禁漫等 17 个源
/// 用它解密**下载下来的加密图片字节**（`RULE_BOOK_CONTENT_DECODER`）。
/// 注意 mode 形如 `AES/CBC/PKCS5Padding`（Java 风格，PKCS5 实为 PKCS7）、
/// `AES/ECB/NoPadding` 等，必须解析出「模式 + 填充」两段。
enum AESAny {
    /// - Parameters:
    ///   - mode: `AES/CBC/PKCS5Padding` / `AES/ECB/NoPadding` …
    ///   - noPadding: 是否 NoPadding；其余一律 PKCS7（= Java 的 PKCS5）
    static func run(_ data: Data, key: Data, iv: Data, mode: String, decrypt: Bool) -> Data? {
        let up = mode.uppercased()
        var options = CCOptions(0)
        if up.contains("ECB") { options |= CCOptions(kCCOptionECBMode) }
        // NoPadding 时不加填充；CBC 无填充也要自己做零填充对齐（CCCrypt 要求块对齐）
        let noPadding = up.contains("NOPADDING")
        if !noPadding { options |= CCOptions(kCCOptionPKCS7Padding) }

        var input = data
        if noPadding, input.count % kCCBlockSizeAES128 != 0 {
            // CCCrypt 不支持非对齐输入；NoPadding 场景补齐到块整数倍（多余字节丢弃在输出尾部）
            let pad = kCCBlockSizeAES128 - (input.count % kCCBlockSizeAES128)
            input.append(Data(repeating: 0, count: pad))
        }
        var out = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var outLen = 0
        let status: CCCryptorStatus = key.withUnsafeBytes { kp in
            iv.withUnsafeBytes { ivp in
                input.withUnsafeBytes { dp in
                    CCCrypt(CCOperation(decrypt ? kCCDecrypt : kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES), options,
                            kp.baseAddress, key.count,
                            iv.isEmpty ? nil : ivp.baseAddress,
                            dp.baseAddress, input.count, &out, out.count, &outLen)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        var result = Data(out[0..<outLen])
        if noPadding {
            // NoPadding 时按原始长度裁剪（我们前面补过零）
            if result.count > data.count { result = result.prefix(data.count) }
        }
        return result
    }
}
