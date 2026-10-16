import Foundation

/// 图源连通性诊断 —— 把「章节解析不出来」这种模糊现象拆成可定位的结论。
///
/// ── 实测样本（2026-10，用于校准结论文案）──────────────────────────────
/// 「绅士漫画」= 内置「直连韩漫网」https://ssmhw.com，规则本身**完全正确**
/// （`[id=list-chapter] ul.list-chapter a` → 41 章；`.comic_img@data-original` → 270 张）。
/// 真正断点是正文图 CDN `img1.du8.in`（→134.19.178.140）在国内直连超时
/// （HTTP 000 / 10.7s），走代理立刻 200。ssmhw.com 挂在 Cloudflare 上，
/// 国内直连反而通；站点本身**不校验 Referer**（带不带都 200）。
/// → 典型的「梯子规则模式没覆盖图片域名」，不是 App bug。
/// 这正是本诊断第 ⑤ 步要区分的情形。
///
/// ── 另一条线索：「让我喵喵」.em 源文件格式（逆向进展）────────────────
/// .em = NSKeyedArchiver bplist，结构为
///   { "MyDataFile": [N × bytes], "inviteCode": "<8 字节明文字符串>" }
/// 实测 51 个 blob 全部 16 字节对齐；**同「首 16 字节」的 blob 在尾部若干块完全一致**
/// → 已确证分组模式为 **AES-ECB**（非 CBC），首 16 字节是「同源共享的固定明文前缀」。
/// 但 inviteCode 的 763 种派生 + 固定 key 字典 × {AES,SM4,3DES,Blowfish} 全部失败，
/// 说明 key 是 App 内硬编码的随机串（非可猜弱 key），需要 App 二进制才能继续。
/// 结论：暂不支持导入 .em；图源仍走 yck2026 / 图源编辑器两条成熟路径。
///
/// 为什么需要它：
/// 用户报「绅士漫画章节解析不出来，我已经挂了梯子」时，实际情况可能完全不同：
///   · 详情页 HTML 不通           → 梯子没覆盖 ssmhw.com，或规则/反爬变更
///   · 章节列表选择器不匹配       → 规则过期（站点改了 id/class）
///   · 章节页通但图片 CDN 不通     → 最常见！如 ssmhw 的正文图在 img1.du8.in，
///                                国内直连超时，梯子的规则模式又没包含这个域名
///   · 全部通但解码失败           → 加密图源 key/算法问题
/// 以前这些在 App 里长得一模一样（都是「章节解析为 0 / 一直转圈」），
/// 用户无从下手。这里逐段探测并给出**明确的一句话结论 + 可执行建议**。
struct SourceDiagnostics {

    struct Report {
        var sourceName: String = ""
        var sourceUrl: String = ""
        var steps: [Step] = []
        var conclusion: String = ""

        var okCount: Int { steps.filter { $0.level == .ok }.count }
        var failed: [Step] { steps.filter { $0.level == .fail } }
    }

    struct Step {
        enum Level { case ok, warn, fail, info }
        var title: String
        var detail: String
        var level: Level
        var ms: Int = 0
    }

    /// 全流程诊断。`noteUrl` 是详情页地址（用户从搜索/书架进来时的那个）。
    static func run(source: ComicSource, noteUrl: String, chapterUrl: String? = nil) async -> Report {
        var r = Report()
        r.sourceName = source.bookSourceName ?? ""
        r.sourceUrl = source.bookSourceUrl

        // ── ① 详情页 HTML ──
        let t0 = Date()
        let html = await HttpFetcher.shared.fetchText(
            noteUrl,
            headers: ["User-Agent": source.httpUserAgent ?? AppSettings.shared.httpUA,
                      "Referer": source.bookSourceUrl],
            timeout: 15)
        let ms1 = Int(Date().timeIntervalSince(t0) * 1000)
        let isJson = html.trimmingCharacters(in: .whitespaces).hasPrefix("{")
            || html.trimmingCharacters(in: .whitespaces).hasPrefix("[")
        if html.isEmpty {
            r.steps.append(.init(title: "详情页 HTML", detail: "抓取失败（超时/被拒/域名不可达）", level: .fail, ms: ms1))
            r.conclusion = "❌ 详情页都打不开 —— 和规则无关。请确认梯子已覆盖 \(host(source.bookSourceUrl))（规则模式下要手动加该域名），或站点已更换域名。"
            return r
        }
        r.steps.append(.init(title: "详情页 HTML", detail: "\(html.count) 字符", level: .ok, ms: ms1))

        // ── ② 章节列表选择器 ──
        let a = AnalyzeRule(baseUrl: noteUrl)
        if isJson { a.setJson(html, baseUrl: noteUrl) } else { a.setDocument(html: html, baseUrl: noteUrl) }
        let listRule = source.ruleChapterList ?? ""
        var nodes: [RuleNode] = []
        if !listRule.isEmpty {
            if isJson { nodes = JsonPath.query(a.ctx.json ?? [String: Any](), listRule).map { RuleNode(json: JsonPath.stringify($0)) } }
            else { nodes = await a.getElements(listRule) }
        }
        if nodes.isEmpty {
            r.steps.append(.init(title: "章节列表", detail: "选择器 `\(listRule)` 命中 0 个节点", level: .fail))
            r.conclusion = "❌ 页面能打开，但章节选择器匹配不到内容 —— 这是**规则过期**（站点改了 HTML 结构）。建议：用「图源编辑器」更新 ruleChapterList。"
            return r
        }
        r.steps.append(.init(title: "章节列表", detail: "命中 \(nodes.count) 个章节节点", level: .ok))

        // ── ③ 逐节点取 name / url（前 3 个抽样）──
        var resolved: [ComicInfo.Chapter] = []
        for (i, node) in nodes.enumerated() {
            if i >= 3 { break }
            let e = AnalyzeRule(baseUrl: noteUrl)
            if let el = node.element { e.setElement(el) } else { e.setJson(node.jsonText ?? "{}", baseUrl: noteUrl, isNode: true) }
            let name = await e.getString(source.ruleChapterName ?? "")
            var url = await e.getStringFirst(source.ruleContentUrl ?? "")
            if url.isEmpty { url = await e.getStringFirst(source.ruleChapterUrl ?? "a@href") }
            guard !url.isEmpty else { continue }
            resolved.append(.init(name: name.isEmpty ? "第\(i + 1)话" : name,
                                  url: source.absoluteUrl(url, base: noteUrl), group: ""))
        }
        if resolved.isEmpty {
            r.steps.append(.init(title: "章节链接", detail: "ruleContentUrl=`\(source.ruleContentUrl ?? "")` 取不到链接", level: .fail))
            r.conclusion = "❌ 章节节点有，但取不到链接 —— 规则里 ruleContentUrl 字段失效（站点可能从 href 改成 data-href）。"
            return r
        }
        r.steps.append(.init(title: "章节链接", detail: "样例：\(resolved[0].name) → \(resolved[0].url)", level: .ok))

        // ── ④ 正文页 + 图片提取（用真实章节）──
        let probeChapter = chapterUrl.map { ComicInfo.Chapter(name: "指定章节", url: $0, group: "") } ?? resolved[0]
        let t2 = Date()
        let chHtml = await HttpFetcher.shared.fetchText(
            probeChapter.url,
            headers: ["User-Agent": source.httpUserAgent ?? AppSettings.shared.httpUA,
                      "Referer": source.bookSourceUrl],
            timeout: 15)
        let ms2 = Int(Date().timeIntervalSince(t2) * 1000)
        if chHtml.isEmpty {
            r.steps.append(.init(title: "正文页 HTML", detail: "抓取失败", level: .fail, ms: ms2))
            r.conclusion = "❌ 章节列表 OK，但正文页打不开 —— 章节页域名可能和主站不同，梯子需要一并覆盖。"
            return r
        }
        r.steps.append(.init(title: "正文页 HTML", detail: "\(chHtml.count) 字符", level: .ok, ms: ms2))

        let ca = AnalyzeRule(baseUrl: probeChapter.url)
        if chHtml.trimmingCharacters(in: .whitespaces).hasPrefix("{") { ca.setJson(chHtml, baseUrl: probeChapter.url) }
        else { ca.setDocument(html: chHtml, baseUrl: probeChapter.url) }
        var images: [String] = []
        let contentRule = source.ruleBookContent ?? ""
        if !contentRule.isEmpty {
            let (clean, _) = ca.extractTrailingHeaders(contentRule)
            images = (await ca.getStringList(clean)).filter { !$0.isEmpty }.map { source.absoluteUrl($0, base: probeChapter.url) }
        }
        if images.isEmpty {
            r.steps.append(.init(title: "正文图片", detail: "ruleBookContent=`\(contentRule)` 命中 0 张", level: .fail))
            r.conclusion = "❌ 正文页能打开，但图片规则取不到图片 —— 规则过期（站点改了图片容器/属性名）。"
            return r
        }
        r.steps.append(.init(title: "正文图片", detail: "解析出 \(images.count) 张，首张 \(images[0])", level: .ok))

        // ── ⑤ 图片域名连通性 + 速度 ──
        // ⚠️ 这里同时看「通不通」和「快不快」。实测（2026-10，包子漫画）：
        //    图片 CDN c-nd3-1.6wm.top 直连 1.7~3.7s，走代理 7.7~12.7s —— 慢 4~5 倍！
        //    所以「挂了梯子反而更慢」是真实存在的，诊断必须给出方向正确的建议。
        let host = URL(string: images[0])?.host ?? ""
        let t3 = Date()
        let (code, size) = await probeBinary(images[0], referer: source.bookSourceUrl,
                                             ua: source.httpUserAgent ?? AppSettings.shared.httpUA)
        let ms3 = Int(Date().timeIntervalSince(t3) * 1000)
        if code == 200, size > 0 {
            let speed = ms3 > 0 ? "，耗时 \(ms3)ms" : ""
            if ms3 > 5000 {
                // 通了但很慢 —— 典型是「代理绕远路」
                r.steps.append(.init(title: "图片 CDN", detail: "\(host) → HTTP 200，\(size) 字节，**耗时 \(ms3)ms（偏慢）**", level: .warn, ms: ms3))
                r.conclusion = "⚠️ 图片能下但很慢（\(ms3)ms）。\n\n最常见的原因不是站点，而是**代理绕路**：\n· 该图 CDN 在国内往往可以直连（实测同域名直连比走代理快 4~5 倍）\n· 如果你的梯子是「全局模式」，请试试**关掉梯子**再读这一话\n· 或者在梯子规则里把 \(host) 设为 **DIRECT（直连）**\n\n👉 先关梯子试一次；若关掉后反而打不开，再把它加回代理。"
            } else {
                r.steps.append(.init(title: "图片 CDN", detail: "\(host) → HTTP 200，\(size) 字节\(speed)", level: .ok, ms: ms3))
                r.conclusion = "✅ 全链路通畅（HTML / 章节 / 正文 / 图片）—— 这个源在当前网络下应该能正常阅读。"
            }
        } else if code > 0 {
            r.steps.append(.init(title: "图片 CDN", detail: "\(host) → HTTP \(code)", level: .fail, ms: ms3))
            r.conclusion = "❌ 图片域名 \(host) 返回 \(code) —— 可能需要特定 Referer，或该 CDN 挂了。"
        } else {
            r.steps.append(.init(title: "图片 CDN", detail: "\(host) → 连接超时（\(ms3)ms）", level: .fail, ms: ms3))
            r.conclusion = "❌ **关键问题**：正文图在 \(host)，这个域名当前网络下连不上。\n\n可能原因与对策（按顺序试）：\n· 该域名被污染/被墙 → 把梯子切成「全局模式」，或在规则里给 \(host) 加代理\n· 梯子只代理了主站、没包含 \(host)（规则模式常见）→ 手动补一条规则\n· 都不行 → 换一个正文图不走境外 CDN 的图源"
        }
        return r
    }

    private static func host(_ url: String) -> String {
        URL(string: url)?.host ?? url
    }

    /// 探测二进制资源，返回 (HTTP 状态码, 字节数)。0 表示连接失败。
    private static func probeBinary(_ url: String, referer: String, ua: String) async -> (Int, Int) {
        guard let u = URL(string: url) else { return (0, 0) }
        var req = URLRequest(url: u)
        req.timeoutInterval = 12
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        // 只取前 8KB 探活，别把整张图拉下来
        req.setValue("bytes=0-8191", forHTTPHeaderField: "Range")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (code, data.count)
        } catch {
            return (0, 0)
        }
    }
}
