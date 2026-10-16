import Foundation

/// 图源检验 —— 并发探测图源可用性，支持批量启停/删除
///
/// ── 两档检验 ────────────────────────────────────────────────────────────
/// `check(_:)`     轻量：只探「发现页 → 列表」，8s 超时。用于快速筛掉死站。
/// `checkFull(_:)` 全链路：发现页 → 列表 → 详情 → 章节 → 正文首章。
///
/// 为什么要做全链路：用户报的是「**很多源显示不出章节**」。
/// 只查列表根本发现不了 —— 大量源是「列表能出、章节恒 0」（规则与站点不匹配），
/// 甚至「章节有、正文 0 图」。只有走完整条链才能定位是哪一环断的。
///
/// ⚠️ 全链路必须走 `ComicEngine.detail` / `contentFirstPage`，**不能自己解析** ——
///    这样才能把万用引擎的兜底（`UniversalParser` 的章节/图片扫描、分页探测）
///    一起算进去，体检结果 = 用户真实会看到的结果。
enum SourceValidator {

    /// 取「入口规则」：发现栏目第一条 > checkUrl > 搜索规则
    static func entryRule(_ source: ComicSource, keyword: String = "斗") -> String? {
        if let find = source.ruleFindUrl, !find.isEmpty {
            // 支持 `名称::url` 多行，也支持 `&&` 串联
            let line = find.components(separatedBy: ["\n"]).compactMap { $0.contains("::") ? $0 : nil }.first
                ?? find.components(separatedBy: "&&").compactMap { $0.contains("::") ? $0 : nil }.first
            if let line, let url = line.components(separatedBy: "::").dropFirst().first {
                let u = url.trimmingCharacters(in: .whitespaces)
                if !u.isEmpty, !u.contains("<js") { return u }
            }
        }
        if let checkUrl = source.checkUrl, !checkUrl.isEmpty, !checkUrl.contains("<js") { return checkUrl }
        if let search = source.ruleSearchUrl, !search.isEmpty, !search.contains("<js") { return search }
        return nil
    }

    // MARK: - 轻量检验（只到列表）

    static func check(_ source: ComicSource, keyword: String = "斗") async -> SourceCheckResult {
        let t0 = Date()
        func done(_ ok: Bool, _ stage: String, _ msg: String) -> SourceCheckResult {
            SourceCheckResult(name: source.bookSourceName, sourceUrl: source.bookSourceUrl,
                              ok: ok, ms: Int(Date().timeIntervalSince(t0) * 1000),
                              message: msg, checked: true, stage: stage)
        }

        guard let rule = entryRule(source, keyword: keyword) else {
            return done(false, "入口", "无可检验规则（发现/搜索为空或 JS）")
        }
        let au = AnalyzeUrl.make(rule, searchKey: keyword, page: 1,
                                 baseUrl: source.bookSourceUrl, ua: source.httpUserAgent)
        guard let req = au.toRequest() else { return done(false, "入口", "URL 无效") }
        let html = await HttpFetcher.shared.fetchText(
            req.url?.absoluteString ?? "", method: req.httpMethod ?? "GET",
            body: String(data: req.httpBody ?? Data(), encoding: .utf8),
            headers: au.headers, timeout: 8)
        if html.isEmpty { return done(false, "网络", "连接失败/超时（可能需要代理）") }

        let items = await ComicEngine.shared.parseResults(
            html, source: source, baseUrl: req.url?.absoluteString ?? rule)
        if !items.isEmpty { return done(true, "列表", "\(items.count) 条结果") }
        return done(false, "列表", "有响应但解析不到列表（规则/页面结构变化）")
    }

    // MARK: - 全链路检验

    /// 发现页 → 列表 → 详情 → 章节 → 正文首章。逐步记录断在哪一环。
    static func checkFull(_ source: ComicSource, keyword: String = "斗",
                          probeContent: Bool = true) async -> SourceCheckResult {
        let t0 = Date()
        func done(_ ok: Bool, _ stage: String, _ msg: String,
                  chapters: Int = 0, images: Int = 0) -> SourceCheckResult {
            SourceCheckResult(name: source.bookSourceName, sourceUrl: source.bookSourceUrl,
                              ok: ok, ms: Int(Date().timeIntervalSince(t0) * 1000),
                              message: msg, checked: true, stage: stage,
                              chapters: chapters, images: images,
                              probedContent: probeContent)
        }

        // ① 入口
        guard let rule = entryRule(source, keyword: keyword) else {
            return done(false, "入口", "无可检验规则（发现/搜索为空或 JS）")
        }
        let au = AnalyzeUrl.make(rule, searchKey: keyword, page: 1,
                                 baseUrl: source.bookSourceUrl, ua: source.httpUserAgent)
        guard let req = au.toRequest(), let entryUrl = req.url?.absoluteString else {
            return done(false, "入口", "URL 无效")
        }
        let reqBody = String(data: req.httpBody ?? Data(), encoding: .utf8)
        var html = await HttpFetcher.shared.fetchText(
            entryUrl, method: req.httpMethod ?? "GET", body: reqBody,
            headers: au.headers, timeout: 12)
        if html.isEmpty {
            // 慢站重试一次（与 detail() 的策略一致）
            html = await HttpFetcher.shared.fetchText(
                entryUrl, method: req.httpMethod ?? "GET", body: reqBody,
                headers: au.headers, timeout: 12)
        }
        if html.isEmpty { return done(false, "网络", "入口页连接失败/超时（可能需要代理）") }

        // ② 列表
        let items = await ComicEngine.shared.parseResults(html, source: source, baseUrl: entryUrl)
        guard let first = items.first, !first.noteUrl.isEmpty else {
            return done(false, "列表", "入口页有响应但解析不到列表（规则与站点不匹配）")
        }

        // ③ 详情（含章节）
        let info = await ComicEngine.shared.detail(
            noteUrl: first.noteUrl, origin: source.bookSourceUrl, extraHeaders: first.noteHeaders)
        if !info.diagnosis.isEmpty {
            return done(false, "详情", info.diagnosis.components(separatedBy: "\n").first ?? "详情页失败")
        }
        if info.chapters.isEmpty {
            let who = info.name.isEmpty ? "（书名也没解析出来）" : info.name
            return done(false, "章节", "详情页可达但章节为 0 \(who)")
        }

        // ④ 正文首章（可选）
        guard probeContent else {
            return done(true, "完成", "\(info.chapters.count) 章", chapters: info.chapters.count)
        }
        let res = await ComicEngine.shared.contentFirstPage(
            chapterUrl: info.chapters[0].url, origin: source.bookSourceUrl)
        if res.urls.isEmpty {
            return done(false, "正文", "有 \(info.chapters.count) 章，但首章图片为 0",
                        chapters: info.chapters.count)
        }
        return done(true, "完成", "\(info.chapters.count) 章 · 首章 \(res.urls.count) 图",
                    chapters: info.chapters.count, images: res.urls.count)
    }

    // MARK: - 批量

    /// 并发批量检验（轻量档）
    static func checkAll(_ sources: [ComicSource], onUpdate: @escaping (SourceCheckResult) -> Void) async {
        await run(sources, threads: 8, full: false, probeContent: false, onUpdate: onUpdate)
    }

    /// 并发批量检验（全链路档）
    ///
    /// ⚠️ 全链路每个源要打 3~4 次 HTTP，501 个源 ≈ 2000 次请求。
    ///    线程数刻意压到 6：并发再高会触发图站限流，反而把「可用源」误判成不可用。
    ///    进度通过 `onUpdate` 流式回调，UI 边到边显示。
    static func checkAllFull(_ sources: [ComicSource], threads: Int = 6,
                             probeContent: Bool = true,
                             onUpdate: @escaping (SourceCheckResult) -> Void) async {
        await run(sources, threads: threads, full: true, probeContent: probeContent, onUpdate: onUpdate)
    }

    /// 通用批量跑（UI 也可直接调）
    static func run(_ sources: [ComicSource], threads: Int, full: Bool,
                    probeContent: Bool,
                    onUpdate: @escaping (SourceCheckResult) -> Void) async {
        await withTaskGroup(of: SourceCheckResult.self) { group in
            var active = 0
            var it = sources.makeIterator()
            func fill() {
                while active < threads, let s = it.next() {
                    active += 1
                    group.addTask {
                        full ? await checkFull(s, probeContent: probeContent) : await check(s)
                    }
                }
            }
            fill()
            for await r in group {
                active -= 1
                onUpdate(r)
                fill()
            }
        }
    }

    /// 体检报告落盘（Documents/图源体检报告.json），便于导出/回传
    @discardableResult
    static func writeReport(_ results: [SourceCheckResult]) -> URL? {
        let arr: [[String: Any]] = results.filter { $0.checked }.map {
            ["name": $0.name, "url": $0.sourceUrl, "ok": $0.ok, "stage": $0.stage,
             "message": $0.message, "chapters": $0.chapters, "images": $0.images, "ms": $0.ms]
        }
        let payload: [String: Any] = [
            "time": Int(Date().timeIntervalSince1970),
            "total": results.count,
            "ok": results.filter { $0.ok }.count,
            "results": arr
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        else { return nil }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("图源体检报告.json")
        try? d.write(to: url)
        return url
    }
}
