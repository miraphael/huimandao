import SwiftUI

/// 规则调试器 —— 自建图源的核心工具。
///
/// 🔴 为什么必须有它：手写规则最难的不是「知道语法」，而是**写完不知道对不对**。
///    以前只能改完规则 → 回图源 → 搜索 → 打开详情 → 看结果，
///    一轮下来几十秒，还分不清是「搜索规则错」还是「章节规则错」。
///    这里把「抓页面 + 求值一条规则 + 显示结果」压成一个按钮，
///    并且**明确区分三种失败**（网络失败 / 规则报错 / 规则没命中），
///    让用户能自己把源调通，而不是等别人更新。
///
/// ## JS 模式（2026-10-15 新增）
/// 以前只有 文本/列表/元素/图片 四种，**全部走 `AnalyzeRule.getString()`**，
/// 也就是说：**`@js:` / `<js>` 规则一条都测不了**。
/// 真实场景里这恰恰是最需要调试的一类 —— 加密站点（如 manhua3.com 的
/// AES-CBC 图片数据）全靠 `@js:` 正文规则，出问题时旧调试器只会显示
/// 「规则没命中」，看不出是「页面没抓对」「`result` 绑定不对」「JS 报错」
/// 还是「返回格式不对」—— 这四种原因的修法完全不同。
///
/// JS 模式因此额外给出**中间过程**：
/// · `result` 的实际长度与开头（判断绑定对不对）
/// · JS 返回值（对象/数组会自动 JSON 展开成一条条）
/// · **JS 抛出的异常原文**
/// · 规则里 `hmd.toast(...)` / `java.log(...)` 打印的内容（相当于 console.log）
struct RuleDebugView: View {
    /// 预填的站点地址（从图源编辑器进来时带上 bookSourceUrl）
    var presetBaseURL: String = ""
    /// 预填的规则（点某一栏旁边的「调试」时带上那条规则）
    var presetRule: String = ""
    /// 规则用途（搜索列表 / 章节列表 / 正文图片 …）—— 决定结果怎么展示
    var presetKind: RuleKind = .text

    enum RuleKind: String, CaseIterable {
        case text = "文本"
        case list = "列表"
        case elements = "元素"
        case images = "图片"
        /// 跑 `@js:` / `<js>` 规则，并显示 `result` 绑定、返回值、异常、打印内容
        case js = "JS"
    }

    @State private var pageURL = ""
    @State private var ruleText = ""
    @State private var kind: RuleKind = .text
    @State private var running = false
    @State private var status = ""
    @State private var statusOK = true
    @State private var results: [String] = []
    @State private var pageSize = 0
    @State private var htmlPreview = ""

    // ── JS 模式专属 ──
    /// `result` 的实际长度 —— 判断「绑定对不对」的第一手证据
    @State private var jsPresetLength = 0
    /// `result` 是否被绑成对象/数组
    @State private var jsPresetIsObject = false
    /// `result` 开头（一眼看出拿到的是整页 HTML 还是别的）
    @State private var jsPresetPreview = ""
    /// JS 抛出的异常原文
    @State private var jsError = ""
    /// 规则里 `hmd.toast(...)` / `java.log(...)` 打印的内容
    @State private var jsLogs: [String] = []
    /// JS 返回的 Jsoup 元素个数
    @State private var jsElementCount = 0

    var body: some View {
        Form {
            Section("① 抓哪个页面") {
                TextField("https://站点/路径", text: $pageURL, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.callout)
            }

            Section("② 写规则") {
                Picker("用途", selection: $kind) {
                    ForEach(RuleKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField(kind == .js ? "// 例如：result.match(/params='([^']+)'/)[1]" : "例如 class.item@tag.a",
                          text: $ruleText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(3...10)
            }

            Section {
                Button {
                    Task { await run() }
                } label: {
                    HStack {
                        if running { ProgressView().controlSize(.small) }
                        Text(running ? "测试中…" : "▶︎ 测试规则")
                    }
                }
                // JS 模式下允许规则留空 —— 会跑一段「看看 result 是什么」的默认脚本
                .disabled(running || pageURL.isEmpty || (ruleText.isEmpty && kind != .js))
            } footer: {
                if kind == .js {
                    Text("跑 `@js:` / `<js>` 规则。规则留空时会跑一段「看看 result 是什么」的默认脚本。JS 里用 `hmd.toast(值)` 或 `java.log(值)` 打印中间结果，会显示在下面。")
                } else {
                    Text("支持 Legado 兼容语法：CSS 选择器、`@attr`、`@text`、`##正则替换`、`$.JSONPath`、`//XPath`、`<js>`、`@js:`、`{{page}}`。")
                }
            }

            if kind == .js {
                Section("JS 里能用的东西") {
                    ForEach(Self.jsGlobals, id: \.self) { line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !status.isEmpty {
                Section("结果") {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(statusOK ? Color.primary : Color.orange)
                    if !results.isEmpty {
                        ForEach(Array(results.enumerated()), id: \.offset) { i, s in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(i + 1)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, alignment: .trailing)
                                Text(s.isEmpty ? "(空)" : s)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(6)
                            }
                        }
                    }
                }
            }

            // ── JS 模式的诊断区：把「为什么没结果」说清楚 ──
            if kind == .js && !jsPresetPreview.isEmpty {
                Section("中间过程（判断卡在哪一环）") {
                    row("result 长度", "\(jsPresetLength) 字\(jsPresetIsObject ? "（对象/数组）" : "（字符串）")")
                    if jsElementCount > 0 { row("返回的 Jsoup 元素", "\(jsElementCount) 个") }
                    Text(jsPresetPreview)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
            }

            if !jsError.isEmpty {
                Section("❌ JS 抛出的异常") {
                    Text(jsError)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }

            if !jsLogs.isEmpty {
                Section("规则里打印的内容") {
                    ForEach(Array(jsLogs.enumerated()), id: \.offset) { i, s in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(i + 1)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .trailing)
                            Text(s)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if !htmlPreview.isEmpty {
                Section("页面开头（确认抓到的不是错误页）") {
                    Text(htmlPreview)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(8)
                }
            }
        }
        .transparentScrollBackground()
        .navigationTitle("规则调试器")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if pageURL.isEmpty { pageURL = presetBaseURL }
            if ruleText.isEmpty { ruleText = presetRule }
            kind = presetKind
        }
    }

    /// 诊断区的一行
    @ViewBuilder
    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(v).font(.system(.caption, design: .monospaced))
        }
    }

    /// JS 模式留空时跑的默认脚本 —— 先让人看清 `result` 到底是什么
    private static let defaultJSProbe = """
    hmd.toast('result 是 ' + (typeof result) + '，' + String(result).length + ' 字');
    hmd.toast('开头：' + String(result).slice(0, 120));
    String(result).length;
    """

    private static let jsGlobals: [String] = [
        "result  —— 当前页面（正文页 = 整页 HTML；逐条迭代时 = 该条元素）",
        "baseUrl —— 当前页面地址",
        "headers / cookie —— 请求头与 Cookie 读写",
        "java    —— java.get(url,headers) / java.ajax([url]) / java.post / java.log(值)",
        "hmd     —— hmd.toast(值) / md5 / sha / atob / btoa / decrypt / aesDecryptCBC(key,iv,密文)",
        "org.jsoup.Jsoup —— Jsoup.parse(html).select(\"css\") 等",
        "打印用 hmd.toast(值) 或 java.log(值) —— 结果会显示在下面",
    ]

    private func run() async {
        running = true
        status = ""; results = []; htmlPreview = ""; statusOK = true
        jsPresetLength = 0; jsPresetIsObject = false; jsPresetPreview = ""
        jsError = ""; jsLogs = []; jsElementCount = 0
        defer { running = false }

        var u = pageURL.trimmingCharacters(in: .whitespaces)
        if !u.lowercased().hasPrefix("http") { u = "https://" + u }
        guard URL(string: u)?.host != nil else {
            status = "❌ 地址不合法"; statusOK = false; return
        }

        // ── ① 抓页面 ──
        let html = await HttpFetcher.shared.fetchPage(u, timeout: 25)
        guard !html.isEmpty else {
            // 这一档必须与「规则没命中」分开报 —— 两者的修法完全不同
            status = "❌ 页面抓取失败（网络/被墙/需要代理）。规则还没被执行，先解决网络。"
            statusOK = false
            return
        }
        pageSize = html.count
        htmlPreview = html.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300).description

        // ── ② 求值 ──
        let a = AnalyzeRule(baseUrl: u)
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksJSON = trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
        if looksJSON { a.setJson(html, baseUrl: u) } else { a.setDocument(html: html, baseUrl: u) }

        let rule = ruleText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .text:
            let v = await a.getString(rule)
            results = v.isEmpty ? [] : [v]
            status = v.isEmpty
                ? "⚠️ 规则没命中（页面 \(pageSize) 字）。换个选择器，或确认页面结构。"
                : "✅ 取到 \(v.count) 字"
            statusOK = !v.isEmpty
        case .list:
            let v = await a.getStringList(rule)
            results = Array(v.prefix(30))
            status = v.isEmpty
                ? "⚠️ 规则没命中（页面 \(pageSize) 字）"
                : "✅ 取到 \(v.count) 条\(v.count > 30 ? "（只显示前 30）" : "")"
            statusOK = !v.isEmpty
        case .elements:
            let els = await a.getElements(rule)
            results = els.prefix(30).map { n in
                guard let e = n.element else { return n.jsonText ?? "" }
                let t = (try? e.text()) ?? ""
                let h = (try? e.attr("href")) ?? ""
                return "[\(t.prefix(20))] \(h.prefix(40))"
            }
            status = els.isEmpty
                ? "⚠️ 规则没命中（页面 \(pageSize) 字）"
                : "✅ 选中 \(els.count) 个元素\(els.count > 30 ? "（只显示前 30）" : "")"
            statusOK = !els.isEmpty
        case .images:
            let urls = await a.getStringList(rule)
            let imgs = urls.filter { UniversalParser.isLikelyComicImage($0) }
            results = Array(imgs.prefix(30))
            status = imgs.isEmpty
                ? "⚠️ 没取到图片 URL（原始 \(urls.count) 条，页面 \(pageSize) 字）"
                : "✅ 取到 \(imgs.count) 张图"
            statusOK = !imgs.isEmpty

        case .js:
            let effective = rule.isEmpty ? Self.defaultJSProbe : rule
            let info = await a.debugJS(effective)
            jsPresetLength = info.presetLength
            jsPresetIsObject = info.presetIsObject
            jsPresetPreview = info.presetPreview
            jsError = info.error ?? ""
            jsLogs = info.logs
            jsElementCount = info.elementCount

            if !jsError.isEmpty {
                // 报错时**不要把返回值当成结果** —— 那只会让人以为规则「跑通了但没内容」
                status = "❌ JS 报错（原因见下方）。result = \(info.presetLength) 字。"
                statusOK = false
            } else if info.elementCount > 0 {
                results = []
                status = "✅ 返回 \(info.elementCount) 个 Jsoup 元素（可直接用于章节列表/元素规则）"
                statusOK = true
            } else if info.value.isEmpty {
                status = "⚠️ JS 跑完但返回空。先看下方 result 的长度与开头 —— "
                       + "若 result 很短，说明绑定不对；若 result 正常，说明规则逻辑没命中。"
                statusOK = false
            } else {
                let items = Self.displayItems(from: info.value)
                results = Array(items.prefix(30))
                status = "✅ 返回 \(info.value.count) 字\(items.count > 1 ? "（\(items.count) 条）" : "")"
                    + (items.count > 30 ? "，只显示前 30" : "")
                statusOK = true
            }
        }
        DiagLog.event("debug", "rule", "规则调试：kind=\(kind.rawValue) 结果=\(results.count) 页面=\(pageSize) 字")
    }

    /// 把 JS 返回值拆成一条条显示。
    ///
    /// `@js:` 正文规则通常 `JSON.stringify(urls)` 返回 JSON 数组，
    /// 章节规则可能返回 HTML 或元素数组 —— 两种都照顾到。
    private static func displayItems(from text: String) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        if t.hasPrefix("["), let d = t.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: d) as? [Any] {
            return arr.map { ($0 as? String) ?? String(describing: $0) }
        }
        let lines = t.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return lines.count > 1 ? lines : [t]
    }
}
