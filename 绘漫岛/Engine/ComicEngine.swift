import Foundation
import SwiftSoup

/// 业务引擎：搜索/详情/章节/正文（对应 SearchComicModel + presenter 层）
final class ComicEngine {
    static let shared = ComicEngine()

    // MARK: - 并发搜索（默认 32 线程）

    /// 全图源搜索：结果流式回调（UI 边到边显示），最终返回全量去重结果
    func search(_ keyword: String, sources: [ComicSource]? = nil, page: Int = 1,
                onBatch: (([SearchResult]) -> Void)? = nil) async -> [SearchResult] {
        // 第 1 页 = 新搜索 → 只清理这个关键词自己的 cursor，不能打断其他并发搜索/栏目。
        if page <= 1 { resetSearchPager(keyword) }
        let enabled = sources ?? ComicRepository.shared.allSources(includeDisabled: false).filter { !($0.ruleSearchUrl ?? "").isEmpty }
        let threads = AppSettings.shared.searchThreads
        // ⚠️ 用引用类型承载「累加器」：`NSLock.lock()` 在 async 上下文里调用会告警
        //    （Swift 6 下直接报错），所以把「加锁去重追加」收进这个同步方法里。
        //    闭包捕获 `acc`（class）而不是 `var results`（会有并发写入告警）。
        final class Accumulator {
            private let lock = NSLock()
            private var results: [SearchResult] = []
            private var seen = Set<String>()
            /// 加锁去重追加，返回本次新增的部分（同步函数，锁安全）
            func absorb(_ part: [SearchResult]) -> [SearchResult] {
                lock.lock(); defer { lock.unlock() }
                var fresh: [SearchResult] = []
                for r in part where !seen.contains(r.id) {
                    seen.insert(r.id)
                    results.append(r)
                    fresh.append(r)
                }
                return fresh
            }
            func snapshot() -> [SearchResult] {
                lock.lock(); defer { lock.unlock() }
                return results
            }
        }
        let acc = Accumulator()

        await withTaskGroup(of: [SearchResult].self) { group in
            var active = 0
            var iterator = enabled.makeIterator()
            func fill() {
                while active < threads, let s = iterator.next() {
                    active += 1
                    group.addTask { [weak self] in
                        guard let self else { return [] }
                        let raw = await self.searchOne(s, keyword: keyword, page: page)
                        // 逐源先做相关性过滤：站点「搜不到就返回热门列表兜底」的结果在这里被剪掉，
                        // 而不是等到全部源汇总后才发现一半是无关的。
                        return Self.rankByRelevance(raw, keyword: keyword)
                    }
                }
            }
            fill()
            for await part in group {
                active -= 1
                let fresh = acc.absorb(part)
                if !fresh.isEmpty { onBatch?(fresh) }
                fill()
            }
        }

        // ── JS 类源（ARCHITECTURE §9.1）────────────────────────────────
        // ⚠️ 单独一段、不塞进上面的 `enabled` 循环：
        //    ① JS 源不是 `ComicSource`，进不去那个数组；
        //    ② 异常必须**隔离** —— 某个 JS 源脚本抛错不能影响 JSON 源的结果，
        //       所以每源各自 `try?`，失败当空结果（§9.1 验收：一源异常不拖累其他源）。
        // 没有注册任何 JS 源时这段**完全不执行**，对现有搜索零开销。
        //
        // TODO（已知缺口，待设计确认后实现 —— 不要照 JSON 源的 urlNext 直接照搬）：
        //   `SearchResult.urlNext` 目前被 `decodeSearch` 解出来但**没有任何消费者**。
        //   JS manifest 的 `entry.search(keyword, page)` 契约只收 `page`，
        //   内置转换产物（`engine/legado_to_js.py`）也只用 `page` 拼 URL、
        //   从不返回 `urlNext` —— 所以对内置 30 条 JS 源无影响。
        //   但**第三方 JS 源**若只给 `urlNext`（游标/token 型分页），第 2 页会断链。
        //   补齐需要：① `JSProvider` 暴露源 id（用于游标记账）；
        //   ② manifest 契约允许「按 urlNext 续页」的调用形态。
        //   两者都是契约变更，须先定规格再改。
        let jsProviders = SourceProviderRegistry.shared.allJSProviders()
        if !jsProviders.isEmpty {
            await withTaskGroup(of: [SearchResult].self) { group in
                for p in jsProviders {
                    group.addTask {
                        let raw = (try? await p.search(keyword: keyword, page: page)) ?? []
                        return Self.rankByRelevance(raw, keyword: keyword)
                    }
                }
                for await part in group {
                    let fresh = acc.absorb(part)
                    if !fresh.isEmpty { onBatch?(fresh) }
                }
            }
        }

        // 全局重排：跨源汇总后再按相关度排一次（各源都过滤过了，这里只定序）
        return Self.rankByRelevance(acc.snapshot(), keyword: keyword)
    }

    /// 搜索：构建搜索 URL → parseResults
    /// 规则里是否含分页占位符（`searchPage` / `{{page}}` / `{{...page...}}`）
    static func hasPagingPlaceholder(_ rule: String) -> Bool {
        PagingStrategyResolver.hasPlaceholder(rule)
    }

    /// 给不含分页占位符的搜索 URL 自动追加 `page=N`。
    ///
    /// ⚠️ 为什么需要它（实测数据）：309 个内置源里 **151 个（49%）** 的
    ///    `ruleSearchUrl` **不含任何分页占位符**，例如
    ///    `http://kuman5.com/search?keyword=searchKey`。
    ///    此时 `AnalyzeUrl.make(page:)` 传进去的页码**完全不起作用** ——
    ///    第 2 页请求到的是和第 1 页**一模一样**的页面，去重后必然为空，
    ///    UI 那边 `if more.isEmpty { return }` 静默返回 → 用户看到「点击没反应」。
    ///
    /// 追加位置要小心：规则可能带 `@Header:{...}` / `|char=gbk` 后缀，
    /// 必须插在 **URL 主体之后、后缀之前**，否则会把后缀拼进 URL 里。
    static func appendPageParam(_ rule: String, page: Int) -> String {
        PagingStrategyResolver.applyingQueryParameter(rule, name: "page", page: page)
    }

    /// ── 分页游标（搜索与栏目共用同一套实现）────────────────────────────────
    ///
    /// 对齐绘漫岛 `SearchComicModel` 的 `Map<源, urlNext>`（`Cgoto.java:70-89`）：
    /// 第 N 页的响应里才有「第 N+1 页」的地址，所以必须缓存，否则第 2 页无从下手。
    ///
    /// scopeKey 必须带上**具体资源**，不能只用源 URL：
    ///   · 搜索 `SEARCH|<源URL>|<关键词 base64>` —— 同一源搜「海贼王」和「火影」
    ///     不能共用下一页地址（旧实现只按源 URL 缓存，是真实存在的串页隐患）
    ///   · 栏目 `COLUMN|<源URL>|<栏目URL>`
    ///
    /// 所有锁操作都收在同步 helper 里（`NSLock` 不能在 async 上下文里直接用）。
    private var pagerCursors: [String: PageCursor] = [:]
    private let pagerLock = NSLock()

    private func searchScopeKey(source: String, keyword: String) -> String {
        let token = Data(keyword.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
            .base64EncodedString()
        return "SEARCH|\(source)|\(token)"
    }

    /// 尝试登记这一页的 URL；返回 false = 不该请求（重复 URL / 页码不对 / 已到底）。
    private func beginPage(_ key: String, page: Int, url: String) -> Bool {
        pagerLock.lock(); defer { pagerLock.unlock() }
        var cursor = pagerCursors[key] ?? PageCursor(scopeKey: key)
        let accepted = cursor.beginRequest(page: page, url: url)
        pagerCursors[key] = cursor
        return accepted
    }

    /// 网络失败/取消时撤销访问标记，允许同一页安全重试。
    private func abortPage(_ key: String, url: String) {
        pagerLock.lock(); defer { pagerLock.unlock() }
        guard var cursor = pagerCursors[key] else { return }
        cursor.cancelRequest(url: url)
        pagerCursors[key] = cursor
    }

    /// 完成页解析并推进游标；返回是否仍可继续（含占位符/页码 fallback）。
    @discardableResult
    private func finishPage(_ key: String, page: Int, nextURL: String?,
                            itemIDs: [String], allowsComputedFallback: Bool) -> Bool {
        pagerLock.lock(); defer { pagerLock.unlock() }
        var cursor = pagerCursors[key] ?? PageCursor(scopeKey: key)
        let canContinue = cursor.finishPage(page: page, nextURL: nextURL,
                                            itemIDs: itemIDs,
                                            allowsComputedFallback: allowsComputedFallback)
        pagerCursors[key] = cursor
        return canContinue
    }

    private func nextURL(_ key: String) -> String? {
        pagerLock.lock(); defer { pagerLock.unlock() }
        return pagerCursors[key]?.nextURL
    }

    /// 清空全部分页游标（显式全量重置）。
    func resetPager() {
        pagerLock.lock(); defer { pagerLock.unlock() }
        pagerCursors.removeAll()
    }

    /// 清空**所有搜索**分页游标，保留栏目游标。
    /// 供 `SearchSession` 在「开始新搜索 / 清空结果」时调用。
    func resetSearchPaging() {
        pagerLock.lock(); defer { pagerLock.unlock() }
        let keys = pagerCursors.keys.filter { $0.hasPrefix("SEARCH|") }
        for key in keys { pagerCursors.removeValue(forKey: key) }
    }

    /// 只清掉某个关键词的搜索游标；其他关键词与栏目不受影响。
    private func resetSearchPager(_ keyword: String) {
        let token = Data(keyword.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
            .base64EncodedString()
        let suffix = "|\(token)"
        pagerLock.lock(); defer { pagerLock.unlock() }
        // ⚠️ 先取出 key 数组再删 —— 边遍历 `.keys` 边 removeValue 是未定义行为
        let keys = pagerCursors.keys.filter { $0.hasPrefix("SEARCH|") && $0.hasSuffix(suffix) }
        for key in keys { pagerCursors.removeValue(forKey: key) }
    }

    /// 重置单个 scope 的分页游标。
    private func resetCursor(_ key: String) {
        pagerLock.lock(); defer { pagerLock.unlock() }
        pagerCursors.removeValue(forKey: key)
    }

    /// 以指定上限新建（覆盖）某个 scope 的游标。
    ///
    /// 章节/正文各自的「最大页数」与搜索/栏目不同（章节 40、正文 50），且为了
    /// 不改动既有终止行为，把「连续无进展」上限设得很高（等于不提前停），
    /// 仅用游标统一「去重 / 环路 / 最大页数 / scope 隔离」。
    private func seedCursor(_ key: String, maximumPages: Int, maximumNoProgressPages: Int) {
        pagerLock.lock(); defer { pagerLock.unlock() }
        pagerCursors[key] = PageCursor(scopeKey: key,
                                       maximumPages: maximumPages,
                                       maximumNoProgressPages: maximumNoProgressPages)
    }

    /// 章节分页游标 key：按「源 + 作品」隔离，避免 A 漫画的下一页串到 B 漫画。
    private func chapterScopeKey(source: String, noteUrl: String) -> String {
        "CHAPTER|\(source)|\(noteUrl)"
    }

    /// 正文分页游标 key：按「源 + 章节」隔离。
    private func contentScopeKey(origin: String, chapterUrl: String) -> String {
        "CONTENT|\(origin)|\(chapterUrl)"
    }

    /// 通用「下一页」链接发现 —— **不依赖 `ruleSearchUrlNext`**。
    ///
    /// 为什么必须有它：内置 309 个源里只有 **5 个**写了 `ruleSearchUrlNext`，
    /// 其余全靠「追加 page=N」兜底，而很多站的分页参数不叫 `page`
    /// （`p` / `pg` / `pageNo` / `pageNum`）→ 追加无效 → 第 2 页 == 第 1 页。
    /// 但**搜索页几乎都会渲染一个「下一页」链接**，这是跨站通用的特征。
    ///
    /// 三级判据（可靠 → 宽松）：
    ///   ① `rel="next"`
    ///   ② 锚文本命中「下一页 / 下页 / Next / 次へ / » / ›」（先排除「上一页 / prev」）
    ///   ③ href 里出现 `page=<当前页+1>` 或 `/page/<当前页+1>`
    static func findNextLink(_ html: String, baseUrl: String, currentPage: Int) -> String? {
        guard let doc = try? SwiftSoup.parse(html, baseUrl) else { return nil }
        let anchors = (try? doc.select("a[href]")) ?? Elements()

        func normalize(_ h: String) -> String? {
            let t = h.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !t.hasPrefix("#") else { return nil }
            let low = t.lowercased()
            guard !low.hasPrefix("javascript"), !low.hasPrefix("mailto") else { return nil }
            let u = URL(string: t, relativeTo: URL(string: baseUrl))?.absoluteString ?? t
            guard u != baseUrl else { return nil }        // 指向自己 → 不是下一页
            return u
        }

        // ① rel=next
        for sel in ["a[rel=next]", "link[rel=next]"] {
            if let e = (try? doc.select(sel))?.first(),
               let u = normalize((try? e.attr("href")) ?? "") { return u }
        }

        // ② 锚文本（先排除「上一页」）
        let nextWords = ["下一页", "下页", "下一頁", "次页", "next", "次へ", "»", "›"]
        let prevWords = ["上一页", "上页", "上一頁", "prev", "前页", "«", "‹"]
        for a in anchors {
            let hay = (((try? a.text()) ?? "") + " " + ((try? a.attr("aria-label")) ?? "")
                       + " " + ((try? a.attr("title")) ?? "")
                       + " " + ((try? a.attr("class")) ?? "")).lowercased()
            if prevWords.contains(where: { hay.contains($0) }) { continue }
            guard nextWords.contains(where: { hay.contains($0) }) else { continue }
            if let u = normalize((try? a.attr("href")) ?? "") { return u }
        }

        // ③ href 里就是下一页的页码
        let want = currentPage + 1
        for a in anchors {
            let h = (try? a.attr("href")) ?? ""
            if h.range(of: "[?&]page=\(want)([^0-9]|$)", options: .regularExpression) != nil,
               let u = normalize(h) { return u }
            if h.range(of: "/page/\(want)([^0-9]|$)", options: .regularExpression) != nil,
               let u = normalize(h) { return u }
        }
        return nil
    }

    /// 从响应里按 `ruleSearchUrlNext` 提取下一页地址（对齐 Cgoto.java:74）
    private func extractNext(_ html: String, source: ComicSource, baseUrl: String,
                             page: Int = 1) async -> String? {
        let isJSON = html.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
            || html.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
        let candidates = PagingStrategyResolver.candidates(
            sourceRule: source.ruleSearchUrlNext, urlRule: "",
            allowsLinkScan: PagingStrategyResolver.canScanLinks(isHTML: !isJSON))

        for strategy in candidates {
            switch strategy {
            case .sourceRule(let rule):
                let analyzer = AnalyzeRule(baseUrl: baseUrl)
                if isJSON { analyzer.setJson(html, baseUrl: baseUrl) }
                else { analyzer.setDocument(html: html, baseUrl: baseUrl) }
                let value = (await analyzer.getStringFirst(rule))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return source.absoluteUrl(value, base: baseUrl) }
            case .linkScan:
                if let url = Self.findNextLink(html, baseUrl: baseUrl, currentPage: page) {
                    return url
                }
            case .placeholder, .queryParameter, .none:
                continue
            }
        }
        return nil
    }

    func searchOne(_ source: ComicSource, keyword: String, page: Int = 1) async -> [SearchResult] {
        guard let rawSearchRule = source.ruleSearchUrl, !rawSearchRule.isEmpty else { return [] }
        await AutoLogin.ensure(source)   // 自动登录（同上）
        let key = searchScopeKey(source: source.bookSourceUrl, keyword: keyword)
        let hasPlaceholder = PagingStrategyResolver.hasPlaceholder(rawSearchRule)

        // ── 第 1 级：urlNext（最可靠 —— 从上一页响应里提取的地址）──
        // ⚠️ 这里**必须自己抓页面**（不能用 fetchListWithRetry，它只回结果不回 html）：
        //    第 N 页的响应里才有「第 N+1 页」的地址，不提取的话
        //    第 3 页就断链了（只能退回「追加 page=N」，而很多站不支持）。
        if page > 1, let cached = nextURL(key), beginPage(key, page: page, url: cached) {
            let html = await HttpFetcher.shared.fetchPage(cached, method: "GET", body: nil,
                                                          headers: Self.sourceHeaders(source), timeout: 15)
            if !html.isEmpty {
                let results = await parseResults(html, source: source, baseUrl: cached)
                if !results.isEmpty {
                    let next = await extractNext(html, source: source, baseUrl: cached, page: page)
                    finishPage(key, page: page, nextURL: next,
                               itemIDs: results.map(\.id), allowsComputedFallback: true)
                    return results
                }
            }
            // 空响应 / 空结果 → 释放这一页，落回下面的占位符 / 追加策略再试一次
            // （urlNext 也可能因站点改版或链接过期而失效）
            abortPage(key, url: cached)
        }

        // ── 第 2/3 级：占位符 或 自动追加 page=N ──
        var searchRule = rawSearchRule
        if page > 1, !hasPlaceholder {
            searchRule = PagingStrategyResolver.applyingQueryParameter(
                rawSearchRule, name: "page", page: page)
        }
        let au = AnalyzeUrl.make(searchRule, searchKey: keyword, page: page, baseUrl: source.bookSourceUrl, ua: source.httpUserAgent)
        guard let req = au.toRequest() else { return [] }
        let target = req.url?.absoluteString ?? ""
        // 规则没有分页变量、也不像可追加参数的 URL 时，第 N 页会算出与第 1 页相同的地址。
        // 游标会直接挡掉这种重复请求（旧实现是白抓一次再靠去重发现「没新内容」）。
        guard !target.isEmpty, beginPage(key, page: page, url: target) else { return [] }
        let headers = Self.sourceHeaders(source).merging(au.headers) { a, _ in a }

        // 抓页面（这里要拿到 html 才能提取 urlNext，所以不用 fetchListWithRetry）
        var html = await HttpFetcher.shared.fetchPage(target, method: req.httpMethod ?? "GET",
                                                       body: String(data: req.httpBody ?? Data(), encoding: .utf8),
                                                       headers: headers, timeout: 15)
        if html.isEmpty, (req.httpMethod ?? "GET").uppercased() == "GET" {
            html = await HttpFetcher.shared.fetchPage(target, method: "GET", body: nil,
                                                      headers: headers, timeout: 15)
        }
        guard !html.isEmpty else {
            abortPage(key, url: target)
            return []
        }
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksJSON = trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
        var results = await parseResults(html, source: source, baseUrl: target)
        if results.isEmpty, !looksJSON, (req.httpMethod ?? "GET").uppercased() == "GET" {
            // 兜底：WebView 渲染（SPA / JS 跳转 / 未识别的挑战页）
            let rendered = await WebViewRuleEngine.shared.fetchRendered(url: target)
            if !rendered.isEmpty, rendered != html {
                html = rendered
                results = await parseResults(rendered, source: source, baseUrl: target)
            }
        }

        // ── 解析管线：规则 → 万用 ──────────────────────────────────────────
        // ⚠️ 搜索此前**完全没有兜底**：规则一旦与站点改版对不上，`searchOne`
        //    就返回空数组 —— 用户看到「这个源搜不到东西」，而章节/正文都有兜底，
        //    唯独搜索没有，降级链是断的。
        //    搜索没有「部分成功」的概念（结果要么有要么没有），所以达标线就是 1 条。
        //    JSON 响应没有可扫描的链接结构 → 万用那级直接返回空（由 `looksJSON` 挡）。
        let ruleResults = results
        let piped = await ParseCore.run(
            stage: .search, sourceKey: source.bookSourceUrl,
            empty: [SearchResult](),
            identity: { Set($0.map(\.noteUrl)) },
            steps: [
                (.rule, { (ruleResults, ParseCore.Quality.of(ruleResults.count)) }),
                (.universal, {
                    guard !looksJSON else { return ([], ParseCore.Quality.none) }
                    var d = UniversalParser.Diagnosis()
                    let cands = UniversalParser.scanSearch(html: html, pageUrl: target,
                                                           baseOrigin: source.bookSourceUrl,
                                                           diagnosis: &d)
                    guard !cands.isEmpty else { return ([], ParseCore.Quality.none) }
                    let mapped = cands.map { c -> SearchResult in
                        var r = SearchResult()
                        r.name = c.name
                        r.noteUrl = c.url
                        r.origin = source.bookSourceUrl
                        // 显示名兜底（与 `JSProvider.decodeSearch` 同策略）：
                        // 搜索结果里「来源: X」是用户判断来源的唯一线索，不能留白。
                        r.originName = source.bookSourceName
                        return r
                    }
                    return (mapped, ParseCore.Quality.of(mapped.count))
                }),
            ])
        if piped.winner == .universal { results = piped.value }
        // 提取并推进游标（对齐 Cgoto.java:74 + SearchComicModel.java:124）
        let next = await extractNext(html, source: source, baseUrl: target, page: page)
        finishPage(key, page: page, nextURL: next,
                   itemIDs: results.map(\.id), allowsComputedFallback: true)
        return results
    }

    /// 发现/推荐栏目：规则占位符优先；没有占位符时跟随页面真实的「下一页」链接。
    /// 结果仍复用搜索列表规则解析，避免栏目页另造一套解析链。
    func browse(url: String, source: ComicSource, page: Int = 1,
                extraHeaders: [String: String] = [:]) async -> [SearchResult] {
        let pagerKey = "COLUMN|\(source.bookSourceUrl)|\(url)"
        if page <= 1 { resetCursor(pagerKey) }
        let discoveredNext = page > 1 ? nextURL(pagerKey) : nil
        let strategies = PagingStrategyResolver.candidates(
            sourceRule: nil, urlRule: url, allowsLinkScan: true)
        let hasPlaceholder = strategies.contains(.placeholder)
        let fallbackParameter = strategies.compactMap { strategy -> String? in
            if case .queryParameter(let name) = strategy { return name }
            return nil
        }.first

        // 先从原规则生成 URL/method/body/headers，保证即使 next link 是绝对地址，
        // 原请求配置也仍然在（例如 POST/body、字符集与自定义 header）。只替换请求目标 URL。
        var requestRule = url
        if discoveredNext == nil, page > 1, !hasPlaceholder,
           let fallbackParameter {
            requestRule = PagingStrategyResolver.applyingQueryParameter(
                url, name: fallbackParameter, page: page)
        }
        let au = AnalyzeUrl.make(requestRule, searchKey: "", page: page,
                                 baseUrl: source.bookSourceUrl, ua: source.httpUserAgent)
        guard let req = au.toRequest() else { return [] }
        let target = req.url?.absoluteString ?? ""
        let requestUrl = discoveredNext ?? (target.isEmpty ? url : target)
        guard beginPage(pagerKey, page: page, url: requestUrl) else { return [] }
        let body = String(data: req.httpBody ?? Data(), encoding: .utf8)
        // 源自带 header（Legado 全局头）优先，再被调用方的 extraHeaders 覆盖。
        var headers = au.headers
        for (k, v) in Self.sourceHeaders(source) where headers[k] == nil { headers[k] = v }
        for (k, v) in extraHeaders { headers[k] = v }

        // 保留旧版的超时与 SPA/WebView 兜底，但留住 HTML 才能发现下一页。
        let method = req.httpMethod ?? "GET"
        var html = await HttpFetcher.shared.fetchPage(requestUrl, method: method, body: body,
                                                       headers: headers, timeout: 30)
        if html.isEmpty, method.uppercased() == "GET" {
            html = await HttpFetcher.shared.fetchPage(requestUrl, method: method, body: body,
                                                       headers: headers, timeout: 30)
        }
        guard !html.isEmpty else {
            // 🔎 插桩：**抓取失败**（与「解析为空」完全不同的原因，修法也不同）
            DiagLog.event("find", "browse",
                          "❌ 抓取失败 \(DiagLog.safeURL(requestUrl))（ua=\(source.httpUserAgent?.prefix(24) ?? "无")）")
            abortPage(pagerKey, url: requestUrl)
            return []
        }

        let looksJSON = html.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
            || html.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
        var results = await parseResults(html, source: source, baseUrl: requestUrl)
        if results.isEmpty, !looksJSON, method.uppercased() == "GET" {
            let rendered = await WebViewRuleEngine.shared.fetchRendered(url: requestUrl)
            if !rendered.isEmpty, rendered != html {
                html = rendered
                results = await parseResults(rendered, source: source, baseUrl: requestUrl)
            }
        }

        // 🔴 兜底：栏目 URL 抓不到/解析不出 → **回落到源首页**用同一套规则再解析一次。
        //    实测很多站（卡拉、瓜子）的分类页对移动端/设备网络会限流，而首页正常；
        //    首页往往也是同一批卡片，能出内容比「空白」有用得多。
        if results.isEmpty, !looksJSON, !requestUrl.hasPrefix(source.bookSourceUrl) {
            let home = source.bookSourceUrl
            let homeHTML = await HttpFetcher.shared.fetchPage(home, method: "GET", body: nil,
                                                               headers: headers, timeout: 25)
            if !homeHTML.isEmpty {
                let homeResults = await parseResults(homeHTML, source: source, baseUrl: home)
                if !homeResults.isEmpty {
                    DiagLog.event("find", "fallback",
                                  "栏目抓取失败 → 回落首页解析成功：\(homeResults.count) 条")
                    results = homeResults
                    html = homeHTML
                }
            }
        }

        let canScanLinks = PagingStrategyResolver.canScanLinks(isHTML: !looksJSON)
        let candidate = canScanLinks
            ? Self.findNextLink(html, baseUrl: requestUrl, currentPage: page) : nil
        let allowsComputedFallback = hasPlaceholder || fallbackParameter != nil
        if results.isEmpty {
            // 🔎 插桩：页面抓到了但**一条都没解析出来** —— 打印 HTML 长度与列表规则
            DiagLog.event("find", "browse",
                          "⚠️ 解析为空：html \(html.count) 字，列表规则=\(source.ruleSearchList ?? "(空)")")
        }
        finishPage(pagerKey, page: page, nextURL: candidate,
                   itemIDs: results.map(\.id),
                   allowsComputedFallback: allowsComputedFallback)
        return results
    }

    /// 抓入口页 → 解析列表；**解析结果为空时用 WebView 重渲染再试一次**。
    ///
    /// ── 为什么必须有这一层 ──────────────────────────────────────────────
    /// 只靠 HTML 特征判断反爬是不够的：大量站点是 **SPA（React/Vue）** 或
    /// 用 **JS 做跳转**，HTTP 拿到的 HTML 体积正常（实测 `ikanmh.xyz` 的跳转页
    /// 有 **38KB**）、也没有明显挑战特征，但规则**一条都匹配不到**。
    /// 「解析结果为空」才是最终、最可靠的信号 —— 它不依赖我们猜站点用了什么反爬。
    ///
    /// ⚠️ 只在真的解析不出东西时才多付一次 WebView 渲染，正常站点零开销。
    /// ⚠️ JSON 接口不重试：WebView 会把它渲染成 HTML，反而毁掉 JSON 规则链。
    private func fetchListWithRetry(url: String, method: String, body: String?,
                                    headers: [String: String], source: ComicSource,
                                    timeout: TimeInterval) async -> [SearchResult] {
        guard !url.isEmpty else { return [] }
        var html = await HttpFetcher.shared.fetchPage(url, method: method, body: body,
                                                       headers: headers, timeout: timeout)
        if html.isEmpty, method.uppercased() == "GET" {
            // 慢站首包偶尔超时 → 重试一次（与 detail() 策略一致）
            html = await HttpFetcher.shared.fetchPage(url, method: method, body: body,
                                                      headers: headers, timeout: timeout)
        }
        guard !html.isEmpty else { return [] }
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksJSON = trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
        let first = await parseResults(html, source: source, baseUrl: url)
        if !first.isEmpty || looksJSON { return first }
        guard method.uppercased() == "GET" else { return first }

        // ── 兜底：WebView 渲染（SPA / JS 跳转 / 未被 HTML 特征识别的挑战页）──
        let rendered = await WebViewRuleEngine.shared.fetchRendered(url: url)
        guard !rendered.isEmpty, rendered != html else { return first }
        return await parseResults(rendered, source: source, baseUrl: url)
    }

    /// 共享解析：HTML/JSON → SearchResult 列表（搜索与发现栏目共用）
    func parseResults(_ html: String, source: ComicSource, baseUrl: String) async -> [SearchResult] {
        let analyzer = AnalyzeRule(baseUrl: source.bookSourceUrl)
        let listRule = source.ruleSearchList ?? ""
        let isJson = html.trimmingCharacters(in: .whitespaces).hasPrefix("{") || html.trimmingCharacters(in: .whitespaces).hasPrefix("[")
        if isJson {
            analyzer.setJson(html, baseUrl: source.bookSourceUrl)
        } else {
            analyzer.setDocument(html: html, baseUrl: baseUrl)
        }

        // 列表
        var nodes: [RuleNode] = []
        if !listRule.isEmpty {
            if isJson {
                let vals = JsonPath.query(analyzer.ctx.json ?? [String: Any](), listRule)
                nodes = vals.map { RuleNode(json: JsonPath.stringify($0)) }
            } else {
                nodes = await analyzer.getElements(listRule)
            }
        } else {
            // 无列表规则：整页视为单结果
            nodes = [RuleNode(json: "{}")]
        }
        // 防御：列表规则匹配到文档根（html/body）时，整页会被当成一条结果 → 判定解析失败
        if nodes.count == 1, let el = nodes[0].element,
           let tag = (try? el.tagName())?.lowercased(), ["html", "body", "#document", "#root"].contains(tag) {
            return []
        }

        var out: [SearchResult] = []
        for node in nodes {
            let a = AnalyzeRule(baseUrl: source.bookSourceUrl)
            if let el = node.element { a.setElement(el) }
            else { a.setJson(node.jsonText ?? "{}", baseUrl: source.bookSourceUrl, isNode: true) }
            // 先清洗空白/换行（HTML 排版会让书名变成「\n   某漫画\n  」），
            // 再走下面的垃圾防御 —— 否则「长度 > 120」会被空白撑大而误杀正常书名。
            let name = Self.cleanChapterName(await a.getString(source.ruleSearchName ?? ""))
            // noteUrl 规则可能自带 @Header（Authorization/签名等），需捕获并传给详情请求
            let rawNoteRule = source.ruleSearchNoteUrl ?? "tag.a@href"
            let (cleanNoteRule, noteHeaders) = a.extractTrailingHeaders(rawNoteRule)
            let noteUrl = await a.getStringFirst(cleanNoteRule)
            let cover = await a.getStringFirst(source.ruleSearchCoverUrl ?? "img@src")
            if name.isEmpty && noteUrl.isEmpty { continue }
            // 垃圾结果防御：书名抓到了 HTML 源码/整页文本/超长文本 → 丢弃
            let looksLikeHtml = name.contains("<!") || name.contains("<html") || name.contains("<div")
                || name.contains("<meta") || name.contains("</")
            if looksLikeHtml || name.count > 120 { continue }
            // 导航/按钮文本被当成书名 → 这类就是搜索里「一堆不相干」的主要来源
            if Self.junkNames.contains(name) { continue }
            if name.contains("http://") || name.contains("https://") { continue }
            out.append(SearchResult(
                name: name,
                author: await a.getString(source.ruleSearchAuthor ?? ""),
                kind: await a.getString(source.ruleSearchKind ?? ""),
                coverUrl: source.absoluteUrl(cover),
                lastChapter: await a.getString(source.ruleSearchLastChapter ?? ""),
                introduce: "",
                noteUrl: source.absoluteUrl(noteUrl),
                origin: source.bookSourceUrl,
                originName: source.bookSourceName,
                noteHeaders: noteHeaders))
        }
        // 若该源多数结果都有书名，就把没书名的丢掉（它们只会显示成一行空白）
        let named = out.filter { !$0.name.isEmpty }.count
        if named >= max(1, out.count / 2) { out = out.filter { !$0.name.isEmpty } }
        return out
    }

    /// 搜索相关性排序 + 弱相关过滤（对搜索生效，对发现栏目不生效）。
    ///
    /// 问题：很多站点在搜不到时**返回热门列表兜底**，用户看到的就是「一堆跟关键词无关的漫画」。
    /// 客户端无法改站点行为，但可以按标题与关键词的相关度**重排 + 剪掉明显不相关的**：
    /// - 标题含完整关键词 → 最高分
    /// - 标题含关键词的多数连续字符（如「火影忍者」→「火影」）→ 次高
    /// - 作者/别名命中 → 中
    /// - 完全不含 → 低分，若整批都没有高分则**全部丢弃**（宁可显示"未找到"也别给用户看无关结果）
    ///
    /// ── 精细化判据（2026-10 增强，针对「搜出来一堆无关的」）────────────────
    /// 旧版只要命中「任意 2 个连续字符」就有 24 分，108 分就算合格 → 噪声太多。
    /// 现在三层收口：
    ///   ① **覆盖率**：命中字符数 / 关键词长度。只命中一半字符的，分数按比例砍。
    ///   ② **顺序/连续性**：片段必须**连续**且在**同一顺序**上（乱序命中不给分）。
    ///   ③ **相对阈值**：一批结果里，得分低于「最高分 × 0.5」且低于硬门槛的全部丢弃。
    ///      这样即便站点兜底返回 50 条热门，只要其中 1 条真正匹配，其余 49 条会被剪掉。
    /// 另外把 `junkNames`（首页/登录/下一页 等导航文本）也纳入排除。
    static func rankByRelevance(_ list: [SearchResult], keyword: String) -> [SearchResult] {
        let kw = keyword.trimmingCharacters(in: .whitespaces).lowercased()
        // 1 个字符的关键词（如「龙」）几乎无法判别相关性，返回原序即可，不做剪裁
        guard kw.count >= 2 else { return list }

        func score(_ r: SearchResult) -> Int {
            let raw = r.name.lowercased()
            // 书名里的装饰/标记（如【】《》-）先剔掉再比，避免「【」之类的字切断连续片段
            let n = raw.replacingOccurrences(of: "[\\[\\]【】《》()（）\\-_.·,， ]",
                                             with: "", options: .regularExpression)
            var s = 0
            if n == kw { s += 1000 }                       // 完全相等
            if n.contains(kw) { s += 300 }                 // 完整包含

            // 最长「连续子串」命中（顺序敏感：只按 keyword 的连续片段去名字里找）
            var bestLen = 0
            if kw.count >= 2 {
                for len in stride(from: kw.count, through: 2, by: -1) {
                    var hit = false
                    for st in 0...(kw.count - len) {
                        let a = kw.index(kw.startIndex, offsetBy: st)
                        let b = kw.index(a, offsetBy: len)
                        if n.contains(String(kw[a..<b])) { hit = true; break }
                    }
                    if hit { bestLen = len; break }
                }
            }
            // 覆盖率加权：片段长度占比越低，得分越少（2/10 的片段不该和 8/10 同分）。
            // ⚠️ 基础分 40 而不是 12：2 字关键词命中 2 字片段（cov=1.0）必须稳稳越过
            //    120 硬门槛 —— 否则「搜『龙珠Z』时『龙珠』被误剪」。
            //    全覆盖（cov=1）时 2 字 → 40×2=80，仍不足 120，靠下面的整体放宽兜底。
            if bestLen >= 2 {
                let coverage = Double(bestLen) / Double(kw.count)
                // cov=1 时给满额 40/字；cov 越低衰减越狠（平方衰减）
                s += Int(Double(bestLen * 40) * (coverage * coverage))
            }
            // 关键词长度 ≥3 且全覆盖（整段都出现在书名里）→ 额外加成，明确是相关结果
            if bestLen == kw.count, kw.count >= 2 { s += 200 }

            // 作者命中（作者名通常短，等长匹配才给分，避免误伤）
            let au = r.author.lowercased().replacingOccurrences(of: " ", with: "")
            if au.count >= 2, au.contains(kw) { s += 150 }

            // 导航/按钮文本：直接归零，后面会被剪掉
            if Self.junkNames.contains(raw.trimmingCharacters(in: .whitespaces)) { return 0 }
            return s
        }

        let scored = list.map { (r: $0, s: score($0)) }

        // 判据分两档，避免「要么全留、要么全剪」：
        //   · strong  = 真正相关（完整包含 / 高覆盖片段）→ 必定保留
        //   · weak    = 部分相关（低覆盖片段命中）→ 保留但排在后面
        //   · 其余    = 完全不相关 → 剪掉
        // 关键词长度 n 决定「多短的片段算 weak」——长关键词命中 2 字噪声高，短的则较可靠。
        let n = kw.count
        let strongCut = max(150, n * 35)      // 完整包含(≥300) / 高覆盖片段都能过
        let weakCut = n >= 4 ? 60 : 30        // 长词的 2 字片段噪声大，门槛抬高

        let strong = scored.filter { $0.s >= strongCut }
        let weak = scored.filter { $0.s >= weakCut && $0.s < strongCut }

        // 一条 strong 都没有：说明站点在兜底（搜『斗罗大陆』却返回热门榜）→ 给空
        guard !strong.isEmpty else {
            // 但若存在「完整包含关键词」的，那些其实应在 strong 里；这里兜底再查一次
            let direct = scored.filter { $0.r.name.lowercased().contains(kw) }
            if !direct.isEmpty { return direct.sorted { $0.s > $1.s }.map(\.r) }
            // 没有直接命中，但有「部分匹配」（weak）→ 这些是真实的近似结果
            // （如搜『龙珠Z』命中『龙珠』、搜『斗罗大陆』命中『大陆』），保留并降序；
            // 完全不相关的（无任何 weak）才判定为站点兜底，返回空。
            if !weak.isEmpty { return weak.sorted { $0.s > $1.s }.map(\.r) }
            return []
        }

        // 有 strong → 保留 strong + weak，按分排序（strong 天然在前）
        let merged = (strong + weak).sorted { $0.s > $1.s }
        return merged.map(\.r)
    }

    /// 常见的导航/按钮文本 —— 被误当成书名时要丢掉
    private static let junkNames: Set<String> = [
        "首页", "登录", "注册", "上一页", "下一页", "末页", "更多", "全部", "搜索", "返回",
        "目录", "详情", "连载", "完结", "收藏", "推荐", "排行", "分类", "标签",
        "Home", "Login", "Next", "Prev", "Previous", "More", "Search", "Menu", "Read more",
    ]

    private static func fieldRule(_ rule: String?, _ fallback: String?) -> String {
        if let r = rule, !r.isEmpty { return r }
        return fallback ?? ""
    }

    // MARK: - 发现（ruleFindUrl 栏目）

    // `FindColumn` 已迁至 `Model/FindColumn.swift`（ARCHITECTURE §7.2 · 批次 2）。

    /// 发现栏目解析 —— 分隔符为 && 或换行（单 & 是 URL 参数必须保留，对应 Legado 语义）
    func findColumns(sources: [ComicSource]? = nil) -> [FindColumn] {
        let enabled = sources ?? ComicRepository.shared.allSources(includeDisabled: false)
        var cols: [FindColumn] = []
        for s in enabled {
            // 「发现」开关关掉的源不贡献栏目（对齐 Legado 的 enabledExplore）
            guard s.isExploreEnabled, let find = s.ruleFindUrl, !find.isEmpty else { continue }
            let probe = AnalyzeRule(baseUrl: s.bookSourceUrl)
            for (title, rawUrl) in Self.parseFindUrl(find) {
                // 栏目 URL 可能带尾部 @Header:{...}，要摘出来单独用
                let (cleanURL, hdrs) = probe.extractTrailingHeaders(rawUrl)
                guard !cleanURL.isEmpty else { continue }
                cols.append(FindColumn(title: title, url: s.absoluteUrl(cleanURL),
                                       origin: s.bookSourceUrl, originName: s.bookSourceName,
                                       headers: hdrs))
            }
        }
        return cols
    }

    /// 解析 `ruleFindUrl`：`标题::URL&&标题::URL`（或换行分隔）。
    ///
    /// ⚠️ 有些源**漏写了分隔符**，例如
    /// `热门::https://x.com/albums?o=mv最新A漫::https://x.com/albums?o=tf`
    /// —— `o=mv` 后面直接跟了下一个栏目标题。老实现按 `&&` 切不出这一段，
    /// 会把 `...o=mv最新A漫` 整串当成 URL，取回来是含中文的非法地址 → 该栏目必然「暂无内容」。
    ///
    /// 这里改成扫描式：URL 读到「非 ASCII 段后面还有 `::`」处截断（那才是下一个标题）；
    /// 若整段里没有 `::`，则保留中文（有些源确实用 `?tag=單行本` 这种合法写法）。
    static func parseFindUrl(_ raw: String) -> [(title: String, url: String)] {
        let s = Array(raw.replacingOccurrences(of: "\r\n", with: "\n"))
        var out: [(String, String)] = []
        var carry = ""
        var i = 0
        let n = s.count
        func isSep(_ k: Int) -> Bool { k + 1 < n && s[k] == "&" && s[k + 1] == "&" }

        while i < n {
            if s[i] == "\n" || s[i] == "\r" { carry = ""; i += 1; continue }
            if isSep(i) { carry = ""; i += 2; continue }
            if i + 1 < n, s[i] == ":", s[i + 1] == ":" {
                let title = carry.trimmingCharacters(in: .whitespaces)
                carry = ""
                i += 2
                // 候选 URL 段：到换行 / && 为止
                var j = i
                while j < n, s[j] != "\n", s[j] != "\r", !isSep(j) { j += 1 }
                let seg = String(s[i..<j])
                var cut = seg.count
                if let sepR = seg.range(of: "::") {
                    let sepOff = seg.distance(from: seg.startIndex, to: sepR.lowerBound)
                    if let naIdx = seg.firstIndex(where: { !$0.isASCII }) {
                        let naOff = seg.distance(from: seg.startIndex, to: naIdx)
                        if sepOff > naOff { cut = naOff }
                    }
                }
                var url = String(seg.prefix(cut))
                i += cut
                while let last = url.last, last == "&" || last == "," || last == ";" || last == ":" {
                    url.removeLast()
                }
                let titleIsURL = title.lowercased().hasPrefix("http")
                if !title.isEmpty, !url.isEmpty, !titleIsURL,
                   !title.contains("<js"), !url.contains("<js") {
                    out.append((title, url))
                }
                continue
            }
            carry.append(s[i]); i += 1
        }
        return out
    }

    /// 栏目页 → 漫画卡片列表（复用搜索列表规则）
    func explore(_ column: FindColumn, page: Int = 1) async -> [SearchResult] {
        guard let s = ComicRepository.shared.source(url: column.origin) else {
            // 🔎 插桩：发现栏目点进去空白时，先确认**源还在不在**
            DiagLog.event("find", "explore",
                          "❌ 找不到源 origin=\(column.origin)（栏目「\(column.title)」）")
            return []
        }
        // 🔴 自动登录：源配了 loginUrl 且没登录过 → 先自动跑一次隐藏 WebView 拿 token
        await AutoLogin.ensure(s)
        let r = await browse(url: column.url, source: s, page: page, extraHeaders: column.headers)
        // 🔎 插桩：栏目 URL、最终条目数 —— 「该栏目暂无内容」一看便知卡在哪
        DiagLog.event("find", "explore",
                      "栏目「\(column.title)」 url=\(DiagLog.safeURL(column.url)) → \(r.count) 条")
        return r
    }

    // MARK: - 详情页

    /// 从 origin 解析 JS 源 id：`js://<id>` → `<id>`；非 JS 源返回 nil。
    ///
    /// ⚠️ 用**显式前缀**判定，而不是「ComicRepository 找不到就当 JS 源」——
    ///    后者会把「源被删除/禁用」也误判成 JS 源，掩盖真实错误。
    static func jsSourceID(from origin: String) -> String? {
        let prefix = SearchResult.jsOriginPrefix
        guard origin.hasPrefix(prefix) else { return nil }
        let id = String(origin.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    // MARK: - 「融合引擎」：三通道共用的万用兜底（统一降级链的最后一级）

    /// 统一降级链：**规则 → JS → 万用**。
    ///
    /// ## 为什么要把兜底抽成共用函数（这就是「融合」的落点）
    /// 三个引擎此前是三条**互不相干**的路径：
    ///   · JSON 规则源：`chapters()` 内部有万用兜底；
    ///   · **JS 类源：完全没有兜底** —— 脚本返回空章节/空图片就直接给用户「0 条」；
    ///   · 搜索：**完全没有兜底**（现在已补，见 `searchOne`）。
    /// 把兜底收成一个函数后，不管入口是规则还是 JS，落空时都退到**同一个**扫描器 ——
    /// 这才是一个管线，而不是三套各自为政的逻辑。
    ///
    /// ⚠️ 只在**上层完全落空**时调用（规则/JS 有结果就绝不插手），
    ///    与 `UniversalParser` 的设计原则一致：避免把本来正确的解析改坏。
    private static func universalChaptersFallback(pageUrl: String, origin: String,
                                                  extraHeaders: [String: String]) async -> [ComicInfo.Chapter] {
        guard !pageUrl.isEmpty else { return [] }
        var headers = extraHeaders
        if let s = ComicRepository.shared.source(url: origin) {
            for (k, v) in Self.sourceHeaders(s, referer: origin) where headers[k] == nil { headers[k] = v }
        }
        let html = await HttpFetcher.shared.fetchPage(pageUrl, headers: headers, timeout: 20)
        guard !html.isEmpty else { return [] }
        var d = UniversalParser.Diagnosis()
        let cands = UniversalParser.scanChapters(html: html, pageUrl: pageUrl,
                                                baseOrigin: origin, diagnosis: &d)
        guard !cands.isEmpty else { return [] }
        DiagLog.event("engine", "fallback",
                      "万用章节兜底 \(cands.count) 条 ← \(DiagLog.safeURL(pageUrl))")
        return cands.map { ComicInfo.Chapter(name: $0.name, url: $0.url, group: "") }
    }

    /// 声明式多级内容流（ruleContentFlow）：卡拉等「挑战流」站点的统一入口。
    ///
    /// 不再为某个站写 `if contains("xxx.com")` 的硬编码补丁——图源 JSON 里写一段
    /// `ruleContentFlow` 数组即可，引擎用 `HttpFetcher` **原生**执行（不走 JS 桥），真机稳定。
    /// 没有该字段的源返回空，调用方继续走「规则 → 万用兜底」。
    private static func contentFlow(_ source: ComicSource, chapterHtml: String,
                                    chapterUrl: String) async -> (urls: [String], headers: [String: String]) {
        guard let flow = source.ruleContentFlow, !flow.isEmpty else { return ([], [:]) }
        return await ContentFlowEngine.run(flow, chapterHtml: chapterHtml,
                                           chapterUrl: chapterUrl, source: source)
    }

    /// 识别「正文图由 JS 拼出来」的站点，直接从脚本变量生成图片地址。
    ///
    /// 实测 W漫画的章节页：
    /// ```js
    /// var num = eval("27")
    /// var pasd = "https://image4.wmanhua.com/mh/<hash>/<uuid>/"
    /// img.setAttribute('data-src', pasd + i + '.webp')   // i = 1…num
    /// ```
    /// HTML 里没有任何 `<img src>`，所以规则/万用都扫不到 → 阅读器空白。
    /// 这里按同样的规律生成 `pasd1.webp … pasdN.webp`（也兼容 `.jpg`）。
    static func jsTemplateImages(html: String) -> [String]? {
        func firstMatch(_ pattern: String, _ text: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
            let ns = text as NSString
            guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges > 1 else { return nil }
            return ns.substring(with: m.range(at: 1))
        }
        guard let pasd = firstMatch(#"var\s+pasd\s*=\s*[\"']([^\"']+)[\"']"#, html) else { return nil }
        guard let numStr = firstMatch(#"var\s+num\s*=\s*eval\(\s*[\"']?(\d+)"#, html)
                ?? firstMatch(#"var\s+num\s*=\s*(\d+)"#, html),
              let num = Int(numStr), num > 0, num <= 500 else { return nil }
        // 扩展名：优先沿用页面里出现的后缀
        let ext = html.contains(".webp") ? "webp" : (html.contains(".jpg") ? "jpg" : "webp")
        let base = pasd.hasSuffix("/") ? pasd : pasd + "/"
        return (1...num).map { "\(base)\($0).\(ext)" }
    }

    /// 万用正文兜底：直接抓章节页 + `UniversalParser.scanImages`。
    /// 与 `universalChaptersFallback` 配对，见其说明。
    private static func universalImagesFallback(chapterUrl: String, origin: String,
                                                headers: [String: String]) async -> [String] {
        guard !chapterUrl.isEmpty else { return [] }
        var h = headers
        if let s = ComicRepository.shared.source(url: origin) {
            for (k, v) in Self.sourceHeaders(s, referer: origin) where h[k] == nil { h[k] = v }
        }
        let html = await HttpFetcher.shared.fetchPage(chapterUrl, headers: h, timeout: 25)
        guard !html.isEmpty else { return [] }
        var d = UniversalParser.Diagnosis()
        let urls = UniversalParser.scanImages(html: html, pageUrl: chapterUrl,
                                             baseOrigin: origin, diagnosis: &d)
        guard !urls.isEmpty else { return [] }
        DiagLog.event("engine", "fallback",
                      "万用正文兜底 \(urls.count) 张 ← \(DiagLog.safeURL(chapterUrl))")
        return urls
    }

    /// - Parameter skipPagination: 跳过章节列表的**分页探测**，只解析第一页。
    ///   用途：详情页首屏。`probePaginationParallel` 会并发抓最多 36 页
    ///   （6 批 × 6 页 × 15s 超时），绅士漫画那种 376 章的源要等十几秒才出首屏
    ///   （用户反馈「刚开始点进新的漫画加载要太久了」）。
    ///   首屏传 true 秒开，随后在后台用 false 再跑一次补全。
    /// - Parameter reuseMetadataFrom: 复用此前已解析好的**元信息**（书名/作者/封面/简介等），
    ///   本次只解析**章节列表**。用途：详情页第二阶段补全 —— 首屏已经把元信息解析出来了，
    ///   第二阶段再串行 `await` 一遍 7 个字段（含 JS 规则时相当慢）纯属重复劳动。
    ///   ⚠️ 传入的 info 必须与 `noteUrl`/`origin` 同源（调用方 DetailSession 保证）。
    func detail(noteUrl: String, origin: String, extraHeaders: [String: String] = [:],
                forceRefresh: Bool = false,
                skipPagination: Bool = false,
                reuseMetadataFrom: ComicInfo? = nil) async -> ComicInfo {
        // 🔴 自动登录：从书架/搜索直接进详情时也要保证登录态
        if let src = ComicRepository.shared.source(url: origin) { await AutoLogin.ensure(src) }
        // 诊断链：一次详情加载 = 一个 session，后面关键节点都带上它
        let diag = DiagLog.begin("detail")
        let t0 = Date()
        // ⚠️ 详情页有**两阶段**加载（DetailSession 编排）：
        //    ① 首屏 skipPagination=true  —— 只要元信息 + 第一页章节，求快
        //    ② 补全 skipPagination=false —— 重取一次（走缓存）+ 分页探测，求全
        //    两阶段各自 begin 一个 session，光看日志分不清谁是谁；这里显式打阶段标记，
        //    用户实测时能一眼看出「第 ①/② 阶段各花了多久、瓶颈在哪一段」。
        let phase = skipPagination ? "①首屏" : "②补全"
        DiagLog.event(diag, "detail", "阶段=\(phase)\(forceRefresh ? " 强制刷新" : "")")
        var info = ComicInfo()
        info.noteUrl = noteUrl
        info.origin = origin
        // ── JS 类源（ARCHITECTURE §9.1）──
        // origin 形如 `js://<manifest.id>` 时委托给注册表里的 JSProvider。
        // 未注册 / 脚本失败 → 返回带 noteUrl 的空详情（不崩，也不影响下面的 JSON 源路径）。
        // ⚠️ JS 源走独立分支、**不享受 `reuseMetadataFrom` 优化**：JS 脚本一次性返回完整
        //    manifest 结构（含章节），没有「元信息 / 章节」分段的概念，复用无从谈起。
        //    这是既有行为，不是遗漏；若日后 JS 源变慢，应优化脚本本身而非走此路径。
        if let jsID = Self.jsSourceID(from: origin),
           let provider = SourceProviderRegistry.shared.jsProvider(id: jsID) {
            // ⚠️ 脚本抛错时退回带 noteUrl 的空详情（不崩，也不影响下面的 JSON 源路径）。
            let jsInfo = (try? await provider.detail(noteUrl: noteUrl, origin: origin,
                                                     extraHeaders: extraHeaders)) ?? info
            // ── 解析管线：JS → 万用 ──────────────────────────────────────────
            // JS 源此前**完全没有兜底**：脚本返回空章节 → 用户看到「章节 0 条」，
            // 而 JSON 规则源有万用兜底 —— 降级链是断的。
            //
            // ⚠️ 这里 JS 那级的达标线是 1 条（非空即达标）：因为 JS 通道拿不到
            //    原始 HTML，万用兜底**需要额外抓一次页面**。若像规则路径那样做
            //    「可疑也跑万用择优」，每个 JS 源都会多一次网络请求 —— 不划算。
            //    所以 JS 通道只在**完全落空**时降级。
            let piped = await ParseCore.run(
                stage: .chapters, sourceKey: origin,
                empty: [ComicInfo.Chapter](),
            // 交叉验证用：章节的身份 = URL。两级都产出时据此算重合率
            // （重合率高 → 两个引擎互相印证；低 → 至少一个在解析别的东西）。
            identity: { Set($0.map(\.url)) },
                steps: [
                    (.js, { (jsInfo.chapters, ParseCore.Quality.of(jsInfo.chapters.count)) }),
                    (.universal, {
                        let extra = await Self.universalChaptersFallback(
                            pageUrl: noteUrl, origin: origin, extraHeaders: extraHeaders)
                        return (extra, ParseCore.Quality.of(extra.count))
                    }),
                ])
            var out = jsInfo
            if piped.winner == .universal { out.chapters = piped.value }
            return out
        }
        guard let s = ComicRepository.shared.source(url: origin) else {
            DiagLog.event(diag, "detail", "找不到图源，直接返回空（源可能被禁用/删除）")
            return info
        }
        DiagLog.event(diag, "detail", "源=\(s.bookSourceName) 入口=\(DiagLog.safeURL(noteUrl))")
        let baseUrl = noteUrl.isEmpty ? origin : noteUrl
        // ⚠️ 源自带的 `header`（Legado 全局请求头）必须注入：
        //    很多源把 Referer / Cookie / 自定义 UA 放在这里，不注入会被站点拒，
        //    表现为「有响应但解析 0 条」——极难从现象反推原因。
        var reqHeaders: [String: String] = Self.sourceHeaders(s, referer: origin)
        for (k, v) in extraHeaders { reqHeaders[k] = v }
        // ⚠️ 这里不要收窄超时：详情页取不到 HTML 会直接返回空 info，
        // 表现出来就是「简介打不开 + 章节解析为 0」，很容易被误判成解析规则的问题。
        // 沿用全局 60s，并在首次为空时重试一次（慢站首包偶尔会超时）。
        //
        // 走 ResponseCache：命中缓存时详情页零网络延迟。安卓原版每进一次详情都重新请求，
        // 慢站要转十几秒；daisy 用 web_cache.cache_first 把详情缓存 2 小时，我们照做。
        let tFetch = Date()
        let cacheKey = CacheDomain.detail.key(origin, noteUrl)
        // 先探一次缓存（只读），用于诊断里区分「网络抓取」和「缓存命中」。
        // ⚠️ 这只是**多一次内存/磁盘只读**，不改变 `cached()` 的行为：
        //    真正的取数仍由下面 `cached()` 决定（含防击穿、forceRefresh 语义）。
        // ⚠️ 不能写成 `!forceRefresh && (await …)` —— `&&` 右侧是 **autoclosure**，
        //    不支持 `await`（编译错误：'await' in an autoclosure that does not support
        //    concurrency / call to actor-isolated instance method 'peek' in a synchronous
        //    nonisolated context）。必须先把 await 求出来再参与逻辑运算。
        var cacheHit = false
        if !forceRefresh {
            cacheHit = (await ResponseCache.shared.peek(cacheKey)?.isEmpty == false)
        }
        var fetched: String? = await ResponseCache.shared.cached(
            key: cacheKey, ttl: CacheDomain.detail.ttl, forceRefresh: forceRefresh) {
                // ⚠️ 「空则重试」的两次请求**共用同一个 30s 超时**时，失败路径最坏要 60s。
                //    这里让**重试**用满超时、首次请求用一半：慢站首包超时后能更快进入重试，
                //    总等待时间从「30+30」降到「15+30」，且成功路径行为不变（首次就成功）。
                var t = await HttpFetcher.shared.fetchPage(noteUrl, headers: reqHeaders, timeout: 15)
                if t.isEmpty { t = await HttpFetcher.shared.fetchPage(noteUrl, headers: reqHeaders) }
                return t
            }
        // ── 分层计时（ARCHITECTURE §8.5）────────────────────────────────
        // 「详情页慢」到底慢在网络首包、反爬挑战升级，还是规则解析，光看总耗时判断不了。
        // 这里把「详情 HTML 就绪」单独打点：若它占了绝大部分耗时，说明瓶颈在 HTTP 层
        // （含 fetchPage 的 L0→L3 挑战升级），而不是解析规则；反之则去查元信息/章节解析。
        DiagLog.event(diag, "detail",
                      "①详情HTML就绪（\(fetched?.count ?? 0) 字节\(cacheHit ? "，缓存命中" : "，网络抓取")）",
                      ms: Int(Date().timeIntervalSince(tFetch) * 1000))
        if fetched == nil, forceRefresh {
            // 强刷失败时退回缓存，别把已有内容弄丢
            fetched = await ResponseCache.shared.peek(cacheKey)
        }
        guard let html = fetched, !html.isEmpty else {
            // ── 空页 ≠ 规则失效 ──────────────────────────────────────────
            // 以前无论哪种失败都返回空 info，调用方只能显示「章节解析为 0」，
            // 用户看到这句会以为是图源规则坏了，而真实原因往往是网络层没通
            // （挂了梯子但 App 没走代理 / 节点被墙 / TLS 失败）。
            // 这里做一次带原因的诊断请求 —— 只在失败路径跑，不影响正常加载速度。
            //
            // ⚠️ 失败路径的**时间预算**：上面主取数最坏已耗时 15s + 30s（首次+重试）。
            //    若再无条件等 20s 诊断，用户要盯着转圈 65s 以上，体感就是「卡死」。
            //    这里按已耗时自适应：已经等得久就用更短的诊断超时，把总时长压在 ~50s 内。
            let spent = Date().timeIntervalSince(t0)
            let diagTimeout: TimeInterval = spent > 35 ? 8 : 20
            DiagLog.event(diag, "detail", "主取数失败（阶段=\(phase)），开始诊断请求（已耗时 \(Int(spent))s，诊断超时 \(Int(diagTimeout))s）")
            let outcome = await HttpFetcher.shared.fetchTextDiagnosed(noteUrl, headers: reqHeaders,
                                                                     timeout: diagTimeout)
            info.diagnosis = Self.explain(outcome, origin: origin, url: noteUrl)
            DiagLog.event(diag, "detail", "详情页取不到 HTML：\(info.diagnosis.prefix(80))",
                          ms: Int(Date().timeIntervalSince(t0) * 1000))
            return info
        }
        let isJson = html.trimmingCharacters(in: .whitespaces).hasPrefix("{") || html.trimmingCharacters(in: .whitespaces).hasPrefix("[")
        let a = AnalyzeRule(baseUrl: baseUrl)
        if isJson { a.setJson(html, baseUrl: baseUrl) } else { a.setDocument(html: html, baseUrl: baseUrl) }

        let tMeta = Date()

        // ── 元信息清洗工具（**两个分支共用**）────────────────────────────
        // 🔴 为什么必须有：`JSEvaluator.evaluateSync` 末尾有兜底 `out.text = result`
        //    —— 任何 `@js:` 规则一旦抛异常/返回 undefined，就把**整个 HTML**
        //    当结果返回。于是书名 / 作者 / 分类 / 简介 / 最新章**都**可能变成
        //    一整页 HTML 源码。
        //
        // 🔴 顺序**不能反**：必须先在**原始结果**上体检（此时 `<html>` 等标签还在，
        //    marker 必然命中），确认不是整页 HTML 后，**再**去标签、解实体。
        //    上一版把体检放在去标签之后 —— `<!doctype html>` 早被替换成空白了，
        //    体检永远命中不了，「整页纯文本」照样被当成简介显示。
        //
        // 🔴 覆盖**所有**字段：上一版只清洗了 introduce/kind，结果真机截图显示
        //    「书名下方直接是 <!doctype html><html lang=…>」—— 那是 `info.author`
        //    字段漏清洗。（2026-10-15 用户录屏/截图实锤）
        func fullyUnescape(_ raw: String) -> String {
            var cur = raw
            for _ in 0..<4 {
                let next = (try? Entities.unescape(cur)) ?? cur
                if next == cur { break }
                cur = next
            }
            return cur
        }
        func cleanMeta(_ raw: String) -> String {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return "" }
            // ① 体检：整页 HTML 一定带这些骨架标记（必须在去标签**之前**查）
            let low = t.lowercased()
            for marker in ["<!doctype", "<html", "<head", "<body",
                           "<meta ", "<script", "<link ", "<title>"] {
                if low.contains(marker) { return "" }
            }
            // ② 去掉残余标签（<br> / <span> / <a …> 等）
            let stripped = t.replacingOccurrences(of: "<[^>]+>", with: " ",
                                                  options: .regularExpression)
            // ③ 循环解码 HTML 实体 + 收敛空白
            let unescaped = fullyUnescape(stripped)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // ④ 超长（整页纯文本会轻松破万）→ 判定失败
            if unescaped.count > 5000 { return "" }
            return unescaped
        }

        if let reuse = reuseMetadataFrom {
            // 复用首屏已解析的元信息，跳过 7 个字段的串行解析。
            // ⚠️ 复用路径**也要清洗**：首屏数据可能来自上一版（未清洗的包）
            //    或旧缓存，直接透传会把整页 HTML 带到详情页。
            info.name = cleanMeta(reuse.name)
            info.author = cleanMeta(reuse.author)
            info.kind = cleanMeta(reuse.kind)
            info.introduce = cleanMeta(reuse.introduce)
            info.lastChapter = cleanMeta(reuse.lastChapter)
            info.coverUrl = reuse.coverUrl
            info.chapterUrl = reuse.chapterUrl.isEmpty ? noteUrl : reuse.chapterUrl
            // 首屏若带了诊断（万用引擎兜底说明等），一并带过来，避免补全后信息反而变少
            info.diagnosis = reuse.diagnosis
            DiagLog.event(diag, "detail", "②元信息复用首屏结果（跳过解析）",
                          ms: Int(Date().timeIntervalSince(tMeta) * 1000))
        } else {
            // ⚠️ **每个**字段都要过 `cleanMeta` —— 漏一个就会出现
            //    「作者 / 最新章 / 书名显示 HTML」。
            //    2026-10-15 真机截图实锤：书名下方直接是 `<!doctype html><html lang=…>`
            //    （那是 `info.author`，上一版只清洗了 introduce/kind）。
            info.name = cleanMeta(Self.cleanChapterName(await a.getString(Self.fieldRule(s.ruleBookName, "h1@text"))))
            info.author = cleanMeta(await a.getString(Self.fieldRule(s.ruleBookAuthor, "")))
            info.kind = cleanMeta(await a.getString(Self.fieldRule(s.ruleBookKind, "")))
            info.introduce = cleanMeta(await a.getString(Self.fieldRule(s.ruleIntroduce, "")))
            info.lastChapter = cleanMeta(await a.getString(Self.fieldRule(s.ruleBookLastChapter, "")))

            // ── 🔴 最后一道保险：内置兜底 ──────────────────────────────────
            // 为什么需要它：`@js:` 规则一旦失败，`JSEvaluator` 会回退成整个 HTML，
            // 上面 `sanitizeMeta` 只能把它丢掉（简介变空）。但用户看到的仍是
            // 「没有简介」或（旧包）「整页 HTML」。
            //
            // 这里**绕开规则**，直接用内置的候选选择器从已解析好的文档里再捞一次。
            // 只要页面结构是这三个源里任意一种，简介就能出来 —— 不依赖规则是否正确、
            // 也不依赖用户是否导入了最新规则。
            //
            // ⚠️ 只在简介为空时兜底，**不覆盖**规则已成功解析出的结果。
            if info.introduce.isEmpty, let root = a.ctx.element {
                for sel in [".mobile-comic-desc",                    // 瓜子漫画
                            ".module-info-introduction-content",     // 漫画网
                            ".detail-sketch"] {                      // 卡拉漫画
                    guard let el = try? root.select(sel).first(),
                          let raw = try? el.text() else { continue }
                    let cleaned = cleanMeta(raw)
                    if !cleaned.isEmpty {
                        info.introduce = cleaned
                        DiagLog.event(diag, "detail", "简介兜底命中：\(sel)（规则未解析出简介）")
                        break
                    }
                }
            }
            if info.kind.isEmpty, let root = a.ctx.element {
                for sel in [".mobile-comic-tags"] {                  // 瓜子漫画
                    guard let el = try? root.select(sel).first(),
                          let raw = try? el.text() else { continue }
                    let cleaned = cleanMeta(raw)
                    if !cleaned.isEmpty {
                        info.kind = cleaned
                        DiagLog.event(diag, "detail", "分类兜底命中：\(sel)")
                        break
                    }
                }
            }
            // 作者兜底：有些源的 `ruleBookAuthor` 是 `@js:` 且会失败（→ 整页 HTML）。
            // 这里直接从文档里找常见作者容器。
            if info.author.isEmpty, let root = a.ctx.element {
                for sel in [".mobile-comic-author", ".author", ".module-info-item",
                            ".detail-author", "[class*=author]"] {
                    guard let el = try? root.select(sel).first(),
                          let raw = try? el.text() else { continue }
                    let cleaned = cleanMeta(raw)
                    if !cleaned.isEmpty, cleaned.count < 120 {
                        info.author = cleaned
                        DiagLog.event(diag, "detail", "作者兜底命中：\(sel)")
                        break
                    }
                }
            }
            let cover = await a.getStringFirst(Self.fieldRule(s.ruleCoverUrl, "img@src"))
            info.coverUrl = s.absoluteUrl(cover)
            info.chapterUrl = await a.getStringFirst(Self.fieldRule(s.ruleChapterUrl, ""))
            if info.chapterUrl.isEmpty { info.chapterUrl = noteUrl }
            else { info.chapterUrl = s.absoluteUrl(info.chapterUrl) }
            if info.name.isEmpty {
                info.name = cleanMeta((try? a.ctx.element?.select("title").text()) ?? "")
            }
            // 分层计时②：元信息 7 个字段是**串行** await 的（AnalyzeRule 有可变 ctx，不能共享实例并行）。
            // 若这里耗时显著，说明规则里含 JS（JavaScriptCore/WebView），下一步才值得做并行化改造。
            DiagLog.event(diag, "detail", "②元信息解析完成",
                          ms: Int(Date().timeIntervalSince(tMeta) * 1000))
        }

        // ── 章节列表 ────────────────────────────────────────────────────────
        //
        // ⚡️ 先看缓存：章节列表解析结果的 key 与写入端一致（`CHAPLIST|origin|noteUrl`）。
        //
        // 为什么必须放在**取独立章节页之前**：绅士漫画这类源现在会做并行分页
        // 探测（376 章要并发抓 8 页）。如果每次都重跑，用户每进一次详情页都要
        // 等好几秒。缓存命中就是 0 网络、0 解析，直接出 376 章。
        // ⚠️ 首屏（skipPagination）**不读也不写** CHAPLIST 缓存 ——
        //    否则「只解析了第一页的残缺章节列表」会被缓存 2 小时，
        //    后台补全时反而命中缓存读到残缺数据（章节数永远停在第一页）。
        let tChap = Date()
        let chapListKey = CacheDomain.chapterList.key(origin, noteUrl)
        if !skipPagination, !forceRefresh, let cached = await ResponseCache.shared.get(chapListKey),
           let cd = cached.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: cd) as? [[String: String]],
           !arr.isEmpty,
           // 🔴 **名字全空的缓存一律判为无效** —— 修复前的旧版本（名字规则失效时）
           //    会把「249 章、名字全空」的列表写进 2 小时 TTL 的缓存里，
           //    之后即使规则修好了，补全阶段仍会读到这份旧数据。
           //    真机实测（2026-10-14）：解析层日志已显示 `非空 249/249`（名字正常），
           //    用户界面却仍无名字 —— 就是这份陈旧缓存盖住了新结果。
           //    （名字为空的列表对用户没有任何价值，重取一次的代价远小于显示错误。）
           arr.contains(where: { !($0["n"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }) {
            // 🔴 同样要防御性去重：`Chapter.id == url`，重复 id 会让 SwiftUI 的 List
            //    **静默丢行**（症状就是「章节显示不全」）。（见 `loadChapters` 的说明）
            var seen = Set<String>()
            info.chapters = arr.map {
                ComicInfo.Chapter(name: $0["n"] ?? "", url: $0["u"] ?? "", group: $0["g"] ?? "")
            }.filter { !$0.url.isEmpty && seen.insert($0.url).inserted }
        } else {
            // 章节列表：ruleChapterUrl 指向**独立章节页**时必须去取那一页，否则永远「章节解析为 0」。
            // 实测 488 个启用源里有 33 个是这种结构（章节不在详情页上）。
            var chapHtml = html
            var chapBase = baseUrl
            var chapIsJson = isJson
            if info.chapterUrl != noteUrl, !info.chapterUrl.isEmpty {
                let h2 = await ResponseCache.shared.cached(
                    key: CacheDomain.chapters.key(origin, info.chapterUrl),
                    ttl: CacheDomain.chapters.ttl, forceRefresh: forceRefresh) {
                        await HttpFetcher.shared.fetchPage(info.chapterUrl, headers: reqHeaders)
                    } ?? ""
                if !h2.isEmpty {
                    chapHtml = h2
                    chapBase = info.chapterUrl
                    chapIsJson = h2.trimmingCharacters(in: .whitespaces).hasPrefix("{")
                        || h2.trimmingCharacters(in: .whitespaces).hasPrefix("[")
                }
            }
            let diagBox = UniversalParser.DiagnosisBox()
            info.chapters = await chapters(source: s, info: info, html: chapHtml, isJson: chapIsJson,
                                           baseUrl: chapBase, skipPagination: skipPagination, diag: diagBox)
            // 🔴 **章节 API 覆盖**（2026-10-18）：很多站详情页只渲染最近 20~30 章，
            //    「加载更多」是 POST 一个 JSON 接口（W漫画：POST /comic/{id}）。
            //    只有拿到**更多**章节时才覆盖，避免 API 抽风把正常结果改坏。
            let apiChapters = await chaptersFromApi(s, noteUrl: noteUrl, headers: reqHeaders)
            if apiChapters.count > info.chapters.count {
                DiagLog.event("detail", "chapterApi",
                              "用章节 API 覆盖：\(info.chapters.count) → \(apiChapters.count) 章")
                info.chapters = apiChapters
            }

            // ── 章节智能排序（2026-10-18）──────────────────────────────────
            // 很多站的章节是**倒序**（最新话在最前）。原样搬过来会有两个后果：
            //   ① 详情页/章节列表反着显示；
            //   ② 阅读器「下一章」按数组顺序取 → 往回走。
            // 这里统一按话数升序重排，与站点顺序无关（见 `ChapterSorter`）。
            if AppSettings.shared.chapterAutoSort, info.chapters.count > 1 {
                let before = info.chapters.first?.name ?? ""
                info.chapters = ChapterSorter.sort(info.chapters)
                let after = info.chapters.first?.name ?? ""
                if before != after {
                    DiagLog.event("detail", "sort", "章节智能排序：首章「\(before)」→「\(after)」")
                }
            }
            // 万用引擎实际介入时，把「走了哪条策略」记进诊断 —— 用户报「某源不行」时
            // 能一眼看出是规则失效还是兜底生效，而不是靠猜。
            if diagBox.summary != "未记录" {
                let note = "解析策略：\(diagBox.summary)"
                info.diagnosis = info.diagnosis.isEmpty ? note : info.diagnosis + "\n" + note
            }
        }
        // 分层计时③：章节列表（含「独立章节页」二次网络请求 + 分页探测）耗时。
        // 首屏 skipPagination=true 时不含分页探测，这个数字应当很小；若仍偏大，
        // 说明瓶颈在「取独立章节页」那次额外请求。
        DiagLog.event(diag, "detail", "③章节解析完成（\(info.chapters.count) 章）",
                      ms: Int(Date().timeIntervalSince(tChap) * 1000))
        // 章节列表落库（若该书已在书架）—— 让下次点书架可以零网络直开
        if !skipPagination, !info.chapters.isEmpty, ComicRepository.shared.inShelf(noteUrl: noteUrl) {
            ComicRepository.shared.saveChapters(noteUrl: noteUrl, chapters: info.chapters)
        }
        // 章节列表缓存（同一本书用统一 key，便于后续「续读」秒开）
        if !skipPagination, !info.chapters.isEmpty {
            let payload = (try? JSONSerialization.data(withJSONObject: info.chapters.map {
                ["n": $0.name, "u": $0.url, "g": $0.group]
            })).flatMap { String(data: $0, encoding: .utf8) }
            if let payload { await ResponseCache.shared.put(key: chapListKey, value: payload, ttl: CacheDomain.chapterList.ttl) }
        }
        DiagLog.event(diag, "detail",
                      "完成：书名=\(info.name.isEmpty ? "(空)" : info.name) 章节=\(info.chapters.count)"
                      + (info.diagnosis.isEmpty ? "" : " 诊断=\(info.diagnosis.prefix(60))"),
                      ms: Int(Date().timeIntervalSince(t0) * 1000))
        return info
    }

    /// 构建一次请求要用的头：源自带 `header`（Legado 全局头）> 源 UA > 全局 UA，再补 Referer。
    ///
    /// ⚠️ 优先级：**源自带的头最优先** —— 源作者把 Referer/Cookie 写进 `header`
    ///    就是站点要求的精确值，被我们的默认值覆盖掉反而会失败。
    /// 从图源的 `header` 字段里解析「Referer 该怎么发」。
    ///
    /// - Returns: `nil` = 没指定（调用方用默认值）；
    ///            `""`  = **明确要求不发 Referer**；
    ///            其它 = 指定值。
    ///
    /// 🔴 为什么需要「明确不发」这一档：有些图站**只要带 Referer 就返回占位图**。
    ///    实测 manhua3.com 的图片 CDN（`c-nd3-1.6wm.top`）：
    ///      · 带 `Referer`（任何值，包括站点自己的域名）→ 301 到 `/link/link.webp`
    ///        —— 一张 728×728 的「请到本网站阅读」占位图
    ///      · 不带 Referer → 200 真图（800×1150 / 158KB）
    ///    而 App 默认把图片 Referer 设成 `bookSourceUrl`，正好踩中。
    ///    这种站只能靠「不发 Referer」——写成 `Referer: -` 或 `Referer:`（空值）。
    enum SourceReferer {
        static func override(in header: String?) -> String? {
            guard let header, !header.isEmpty else { return nil }
            // JSON 形式的 header 也支持
            if header.hasPrefix("{"),
               let d = header.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                for (k, v) in obj where k.lowercased() == "referer" {
                    let val = (v as? String) ?? String(describing: v)
                    let t = val.trimmingCharacters(in: .whitespaces)
                    return (t.isEmpty || t == "-") ? "" : t
                }
                return nil
            }
            for rawLine in header.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                // 宽松：`k: v` 或 `k=v`
                let sepIdx = line.firstIndex(of: ":") ?? line.firstIndex(of: "=")
                guard let idx = sepIdx else { continue }
                let key = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
                guard key == "referer" else { continue }
                let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                return (value.isEmpty || value == "-") ? "" : value
            }
            return nil
        }
    }

    static func sourceHeaders(_ s: ComicSource, referer: String? = nil) -> [String: String] {
        var h: [String: String] = [:]
        for (k, v) in LegadoConverter.parseHeader(s.header) { h[k] = v }
        if h["User-Agent"] == nil, let ua = s.httpUserAgent, !ua.isEmpty { h["User-Agent"] = ua }
        if h["User-Agent"] == nil { h["User-Agent"] = AppSettings.shared.httpUA }
        // 🔴 图源明确声明「不发 Referer」时，连 `Referer: -` 这个占位值都要清掉，
        //    否则会把字面量 `-` 当 Referer 发出去（比不发更糟）。
        if let ov = SourceReferer.override(in: s.header) {
            if ov.isEmpty { h.removeValue(forKey: "Referer") } else { h["Referer"] = ov }
        } else if let r = referer, !r.isEmpty, h["Referer"] == nil {
            h["Referer"] = r
        }
        return h
    }

    /// 把抓取失败翻译成「用户能照着做点什么」的一句话
    static func explain(_ outcome: HttpFetcher.FetchOutcome, origin: String, url: String) -> String {
        switch outcome {
        case .ok:
            // 诊断拿到页面，但业务请求是空的 —— 典型的「首次超时后缓存了空结果」
            return "页面可访问，但详情页请求返回空。请下拉强制刷新重试（首次请求可能超时被缓存）。"
        case .httpError(let code):
            if code == 403 { return "站点返回 403：需要登录或防盗链校验。可在图源菜单里用「网页登录」捕获 Cookie。" }
            if code == 404 { return "站点返回 404：该漫画可能已下架，或图源地址已失效。" }
            if code >= 500 { return "站点返回 \(code)：对方服务器故障，稍后重试。" }
            return "站点返回 HTTP \(code)，非 2xx。"
        case .networkError(let msg):
            return "网络不通：\(msg)。\n图源：\(origin)\n入口：\(url)"
        case .emptyBody:
            return "站点返回空响应体（可能被反向代理拦截，或需要特定 UA/Cookie）。\n图源：\(origin)"
        }
    }

    /// 章节名清洗。
    ///
    /// 漫画站的章节名常有 HTML 排版造成的**大量空白/换行**
    /// （`<a>\n  第 12 话\n</a>`），直接显示会变成一坨。
    /// 另外 NBSP（`\u{00a0}`）在中文站点很常见，`\s` 不匹配它，要单独换掉。
    static func cleanChapterName(_ raw: String) -> String {
        var t = raw.replacingOccurrences(of: "\u{00a0}", with: " ")
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉常见的装饰性包裹符号（保留正文，只削首尾）
        let junk = CharacterSet(charactersIn: "·•-—>》】] ")
        t = t.trimmingCharacters(in: junk)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从 URL 合成章节名 —— 名字完全拿不到时的最后兜底。
    ///
    /// ⚠️ 不要只写「第N话」：分卷/分页时会出现大量重名，
    ///    而重名会让「续读定位」和「追更比对」双双失灵。
    ///    优先从 URL 里抽章节号（`/chapter/102765` → 第102765话 太丑，
    ///    所以只在数字较小时用，否则退回序号）。
    static func synthesizeChapterName(url: String, index: Int) -> String {
        if let n = UniversalParser.chapterNumber(in: url), n > 0, n < 100000 {
            return "第\(n)话"
        }
        return "第\(index + 1)话"
    }

    /// 从「章节 API」拿全量章节（见 `ComicSource.ruleChapterApi`）。
    ///
    /// 适用站点：详情页只渲染最近 N 章，「加载更多」按钮去 POST 一个 JSON 接口。
    /// 例（W漫画）：`POST /comic/{id}`，body `{}` →
    /// `{"code":0,"data":{"chapters":[{"id":856484,"contentId":9040,"chapterName":"第01話"}]}}`
    ///
    /// 三个字段：`ruleChapterApi`（POST 地址，`{id}` 由详情页 URL 的数字段替换）、
    /// `ruleChapterApiList`（JSON 路径）、`ruleChapterApiUrl`（每章 URL 模板，
    /// `{字段名}` 由该 JSON 元素的同名字段替换）。
    private func chaptersFromApi(_ s: ComicSource, noteUrl: String,
                                 headers: [String: String]) async -> [ComicInfo.Chapter] {
        guard let api = s.ruleChapterApi, !api.isEmpty,
              let listPath = s.ruleChapterApiList, !listPath.isEmpty,
              let urlTpl = s.ruleChapterApiUrl, !urlTpl.isEmpty else { return [] }
        // {id} = 详情页 URL 最后一段里的数字（/comic/9040.html → 9040）
        let tail = noteUrl.split(separator: "/").last.map(String.init) ?? ""
        let digits = tail.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .filter { !$0.isEmpty }.first ?? ""
        guard !digits.isEmpty else { return [] }
        let apiUrl = api.hasPrefix("http")
            ? api.replacingOccurrences(of: "{id}", with: digits)
            : s.bookSourceUrl + api.replacingOccurrences(of: "{id}", with: digits)
        var h = headers
        h["Content-Type"] = "application/json"
        let resp = await HttpFetcher.shared.fetchText(apiUrl, method: "POST", body: "{}",
                                                      headers: h, timeout: 20)
        guard let root = JsonPath.parse(resp) else {
            DiagLog.event("detail", "chapterApi", "响应不是 JSON：\(DiagLog.safeURL(apiUrl))")
            return []
        }
        let items = JsonPath.query(root, listPath)
        guard !items.isEmpty else {
            DiagLog.event("detail", "chapterApi", "JSON 路径没命中：\(listPath)")
            return []
        }
        // ⚠️ `ruleChapterName` 通常是给 **HTML** 用的（如 `text` / `tag.a@text`），
        //    在 JSON 元素上取不到 —— 所以这里做一条**字段名回退链**：
        //    ruleChapterName → chapterName → name → title。
        //    （W漫画 的 ruleChapterName 就是 `text`，不兜底会把所有章节都丢掉。）
        let nameField = s.ruleChapterName ?? ""
        var out: [ComicInfo.Chapter] = []
        var seen = Set<String>()
        for it in items {
            guard let dict = it as? [String: Any] else { continue }
            var name = nameField.isEmpty ? "" : JsonPath.asString(dict[nameField] ?? "")
            if name.isEmpty { name = JsonPath.asString(dict["chapterName"] ?? "") }
            if name.isEmpty { name = JsonPath.asString(dict["name"] ?? "") }
            if name.isEmpty { name = JsonPath.asString(dict["title"] ?? "") }
            var u = urlTpl
            for (k, v) in dict {
                u = u.replacingOccurrences(of: "{\(k)}", with: JsonPath.asString(v))
            }
            guard !name.isEmpty, !u.isEmpty, !u.contains("{") else { continue }
            let abs = u.hasPrefix("http") ? u : s.bookSourceUrl + u
            if seen.insert(abs).inserted {
                out.append(ComicInfo.Chapter(name: Self.cleanChapterName(name), url: abs, group: ""))
            }
        }
        return out
    }

    /// 章节列表（含分卷 ruleChapterParentName/Id、下一页 ruleChapterUrlNext）
    ///
    /// ── 万用引擎接入点 ① ────────────────────────────────────────────────
    /// 规则解析不出章节时，交给 `UniversalParser.scanChapters` 兜底；
    /// 规则给不出「下一页」时，交给 `UniversalParser.paginationCandidates`
    /// 按 `?p=N` 递增探测（绅士漫画只出 26/76 章就是这个原因）。
    func chapters(source s: ComicSource, info: ComicInfo, html: String, isJson: Bool, baseUrl: String,
                  page: Int = 1, skipPagination: Bool = false,
                  accumulated: [ComicInfo.Chapter] = [], deadline: Date = Date().addingTimeInterval(30),
                  diag: UniversalParser.DiagnosisBox? = nil) async -> [ComicInfo.Chapter] {
        guard Date() < deadline else { return accumulated }
        var list = accumulated
        // 顶层（page==1）重置本作品游标，保证每次详情抓取都从头开始（与原来
        // `visited` 默认空集一致）；最大页数 40、连续无进展上限很高=保持原终止行为。
        let ckey = chapterScopeKey(source: s.bookSourceUrl, noteUrl: info.noteUrl)
        if page == 1 { seedCursor(ckey, maximumPages: 40, maximumNoProgressPages: 40) }
        let a = AnalyzeRule(baseUrl: baseUrl)
        if isJson { a.setJson(html, baseUrl: baseUrl) } else { a.setDocument(html: html, baseUrl: baseUrl) }

        let listRule = s.ruleChapterList ?? ""
        var nodes: [RuleNode] = []
        if !listRule.isEmpty {
            if isJson {
                nodes = JsonPath.query(a.ctx.json ?? [String: Any](), listRule).map { RuleNode(json: JsonPath.stringify($0)) }
            } else {
                nodes = await a.getElements(listRule)
            }
        }
        // 先收集原始值 —— 名字要做**跨章节**质量校验，所以不能边取边定稿
        //
        // ⚠️ **性能：节点之间并发，节点内部串行。**
        //    原先是对每个节点顺序 `await` 6~8 次（name / alt 的 4 级回退 / url / parent），
        //    一个 376 章的源 ≈ 1500~1900 次**串行** await；每次 await 都要回到
        //    Analyzer 的 executor 上排队，累计延迟是秒级。
        //    各节点的解析**互不依赖**（每节点一个独立的 `AnalyzeRule`），
        //    所以丢进 task group 并行 —— 章节顺序由 `raw` 按 index 回填保证。
        //    单节点成本是纯内存的 CSS/正则求值（非 IO），并发不会打爆网络。
        //
        //    `Element` 不是 `Sendable`，不能跨任务传 —— 改为传 HTML 字符串，
        //    每个子任务内部各自 `setDocument` 重建（SwiftSoup 解析片段很廉价）。
        var raw = [(name: String, alt: String, url: String, parent: String)?](repeating: nil, count: nodes.count)

        enum NodePayload: Sendable {
            case element(String)   // HTML 片段（outerHtml）
            case json(String)
        }
        var payloads: [NodePayload] = []
        payloads.reserveCapacity(nodes.count)
        for node in nodes {
            if let el = node.element {
                payloads.append(.element((try? el.outerHtml()) ?? ""))
            } else {
                payloads.append(.json(node.jsonText ?? "{}"))
            }
        }

        await withTaskGroup(of: (Int, (name: String, alt: String, url: String, parent: String)?).self) { group in
            for (i, payload) in payloads.enumerated() {
                group.addTask {
                    let e = AnalyzeRule(baseUrl: baseUrl)
                    switch payload {
                    case .element(let html):
                        // 🔴 用 `setFragment` 而不是 `setDocument` —— 片段里根要落在
                        //    **节点自己**身上，否则裸属性名规则（`title` / `href`）
                        //    作用到 `<html>` 上取到空（「249 章全都没有名字」的根因）。
                        e.setFragment(html: html, baseUrl: baseUrl)
                    case .json(let t):
                        e.setJson(t, baseUrl: baseUrl, isNode: true)
                    }
                    let name = Self.cleanChapterName(await e.getString(Self.fieldRule(s.ruleChapterName, "a@text")))
                    // ⚠️ **备用名：节点内第一个 <a> 的文本**。
                    //    为什么需要（用户实测反馈「每一话都显示成同一个名字」）：
                    //    `ruleChapterName = "text"` 且节点是**容器**（内含多个子元素）时，
                    //    `text` 会把**整个容器的文本拼接**返回 → 所有章节名完全一样。
                    //    节点内 <a> 的文本才是「这一话自己的名字」。
                    //    回退链：a.text → a.title → 节点自身文本 → 节点 title → URL 合成
                    var alt = ""
                    if let el = e.ctx.element {
                        if let a = try? el.select("a").first() {
                            if let t = try? a.text() { alt = Self.cleanChapterName(t) }
                            // ② <a> 的 title 属性 —— 很多站在**分页页不渲染章节名文本**，
                            //    只把名字放进 title（`<a href="…" title="第12话"></a>`）。
                            //    实测 ssmhw 的 `?p=2` 就是这样，漏掉这级会让整页章节全无名。
                            if alt.isEmpty, let t = try? a.attr("title") { alt = Self.cleanChapterName(t) }
                        }
                        if alt.isEmpty, let t = try? el.ownText() { alt = Self.cleanChapterName(t) }
                        if alt.isEmpty, let t = try? el.attr("title") { alt = Self.cleanChapterName(t) }
                    }
                    // ⚠️ 章节链接取自 **ruleContentUrl**（不是 ruleChapterUrl！）
                    // 对照安卓 Cnew.m26009if()：
                    //   string4 = getString(getRuleContentUrl(), true)  -> chapterListBean.setDurChapterUrl
                    //   if (name 非空 && url 非空) 才加入列表
                    // ruleChapterUrl 是「章节列表所在的那个独立页面」的地址，不是每章链接。
                    // 实测 488 个启用源里 455 个 ruleChapterUrl 为空；若用 ruleChapterUrl 取每章链接，
                    // 会 fallback 到 "a@href"（对 JSON 节点恒为空）→ 全部章节被丢弃 → 永远「章节解析为 0」。
                    var url = await e.getStringFirst(Self.fieldRule(s.ruleContentUrl, ""))
                    // 🔴 兜底**只能**用节点内的 `a@href`，**绝不能**回退到 `ruleChapterUrl`：
                    //    它是**页面级**规则（「章节列表所在的独立页面」地址 —— 见 `detail` 里
                    //    `info.chapterUrl != noteUrl` 那段的用法），逐节点求值会产出
                    //    **同一个常量 URL**，紧接着被下面的 URL 去重塌缩成 **1 章**
                    //    （用户看到的就是「这个源只有一章」）。
                    //    实测 309 条内置源里只有 1 条会走到这个兜底，但一旦命中就是灾难性结果。
                    //    （由智能体「源核」发现）
                    if url.isEmpty { url = await e.getStringFirst("a@href") }
                    let parent = await e.getString(Self.fieldRule(s.ruleChapterParentName, ""))
                    // url 必须非空（无链接就不是一章）；name 允许为空 —— 后面有兜底
                    guard !url.isEmpty else { return (i, nil) }
                    return (i, (name, alt, url, parent))
                }
            }
            for await (i, value) in group where value != nil {
                raw[i] = value
            }
        }
        let collected = raw.compactMap { $0 }

        // ── 名字质量校验（跨章节）──────────────────────────────────────────
        // ⚠️ **只在「几乎全同」时触发**（≤2 个不同名），不能更激进：
        //    分卷漫画里每卷都有「第1话」，唯一名数量天然明显少于章节数，
        //    用「唯一率」当判据会误伤这些源。用户反馈的现象是「全都一个名字」，
        //    所以这里只抓这种极端情况。
        let nonEmptyNames = collected.map(\.name).filter { !$0.isEmpty }
        let uniqNames = Set(nonEmptyNames)
        let namesPoor = collected.count > 3 && uniqNames.count <= 2
        if namesPoor, diag != nil {
            diag?.hit("章节名规则疑似取到容器文本（\(collected.count) 章仅 \(uniqNames.count) 个不同名），已改用节点内链接文本")
        }

        // 🔴 `baseIndex` 必须在循环**外**取：原来写的是 `list.count + i`，
        //    而 `list` 在循环里逐条 append —— i=0 时 0+0=0、i=1 时 1+1=2、
        //    i=2 时 2+2=4 …… **翻倍计数**，无名章节会被合成为「第1/3/5话」。
        //    （由智能体「源核」发现）
        let baseIndex = list.count
        for (i, r) in collected.enumerated() {
            // 🔴 防御：章节列表规则失败时（JS 回退成整页 HTML / 万用兜底扫到
            //    JSON-LD 结构化数据），会产出 `{"@type":"ListItem",...}` 这种
            //    「章节」—— 用户看到的章节列表就是一堆 JSON 源码。
            //    这里按内容体检过滤：URL / 名字里出现 JSON 特征字符就丢弃。
            //    （2026-10-15 真机实锤：瓜子漫画章节列表显示 JSON-LD。）
            let u = r.url.trimmingCharacters(in: .whitespacesAndNewlines)
            if u.isEmpty || u.contains("{") || u.contains("\"") || u.contains("</") { continue }
            var title = r.name
            if namesPoor || title.isEmpty { title = r.alt }
            // 🔴 章节名是 HTML 源码 → 解析错位，丢弃。
            //    真机截图实锤（2026-10-15 瓜子漫画）：章节列表整列显示
            //    `<a href="/chapter.php?id=1628417">183 双枪对决</a>` —— 规则失败后
            //    JS 回退成整页 HTML，万用兜底又把 `<a>` 标签当成了章节名。
            if title.contains("<a ") || title.contains("</a>") || title.contains("href=")
                || title.contains("<!") || title.contains("</") { continue }
            if title.contains("{\"") || title.contains("\"@type\"") || title.contains(":[\"") { continue }
            if title.isEmpty { title = Self.synthesizeChapterName(url: u, index: baseIndex + i) }
            list.append(ComicInfo.Chapter(name: title,
                                          url: s.absoluteUrl(u, base: baseUrl),
                                          group: r.parent))
        }
        // 去重（保持顺序）
        let beforeDedup = list.count
        var seen = Set<String>(); list = list.filter { seen.insert($0.url).inserted }

        // ── 🔴 章节兜底：规则解析失败时，用通用选择器再捞一次 ──────────────
        // 为什么需要：`@js:` 规则一旦失败，`JSEvaluator` 回退成整页 HTML，
        // 万用兜底会把 `<a>` 标签 / JSON-LD 当成「章节」（上面已过滤掉），
        // 结果章节列表为空 —— 用户看到「该图源没解析出章节」。
        // 这里**绕开规则**，直接从已解析好的文档里扫「href 含 chapter 的链接」。
        // 只在本页一条都没解析出来时触发，不会覆盖规则已成功的结果。
        // （2026-10-15 真机实锤：瓜子漫画章节列表变成 HTML 源码。）
        // 🔴 **只在「本页一条都没解析出来」时才兜底**，且去重要带上已有章节。
        //
        //    真机实测（2026-10-18，v111）：翻到第 2 页时本页 0 条新章节 →
        //    `list.count == baseIndex` 成立 → 兜底把**第 2 页 HTML 里的全部**
        //    `<a href*=chapter>` 又扫了一遍，而 `seenFallback` 是个**空集合**
        //    （没有带上 list 里已有的 URL）→ 整份章节被**再追加一遍**：
        //      《海贼王》1034 章 → 2068 章；瓜子 1068 → 2136；卡拉 919 → 2650。
        //    用户看到的就是「章节列表里每话都有两份」。
        if list.count == baseIndex, collected.isEmpty, let root = a.ctx.element {
            // 已有章节的 URL 先灌进去，兜底不可能产出重复项
            var seenFallback = Set(list.map(\.url))
            let buttonNames: Set<String> = ["开始阅读", "阅读", "立即阅读", "上一章",
                                            "下一章", "返回", "目录", "首页"]
            if let els = try? root.select("a[href*=chapter]") {
                for el in els.array() {
                    guard let href = try? el.attr("href"),
                          let rawName = try? el.text() else { continue }
                    var n = Self.cleanChapterName(rawName)
                    // 去掉尾部按钮词：`el.text()` 会把
                    // `<span>334 鬼梦貘</span><em>阅读</em>` 里的 `<em>阅读</em>`
                    // 一起带出来 → "334 鬼梦貘 阅读"。这里削掉尾部装饰词。
                    for suffix in ["阅读", "最新", "查看", "连载", "详情", "立即"] {
                        if n.hasSuffix(suffix), n.count > suffix.count {
                            n = String(n.dropLast(suffix.count))
                                .trimmingCharacters(in: .whitespaces)
                        }
                    }
                    if n.isEmpty || n.count > 80 { continue }
                    if buttonNames.contains(n) { continue }
                    if n.contains("<") || n.contains("{") { continue }
                    let abs = s.absoluteUrl(href, base: baseUrl)
                    if seenFallback.insert(abs).inserted {
                        list.append(ComicInfo.Chapter(name: n, url: abs, group: ""))
                    }
                }
            }
            if list.count > baseIndex {
                DiagLog.event("chapters", "fallback",
                              "章节兜底命中 \(list.count - baseIndex) 条（规则未解析出章节，改用通用链接扫描）")
            }
        }
        // 🔎 插桩：章节到底在第几步丢的 —— 用户报「章节不全」时看这一条就能定案
        //    ⚠️ 本函数的 `diag` 形参是 `UniversalParser.DiagnosisBox?`，不是 `DiagLog`
        //       的 session 字符串 —— 直接传会编译不过（踩过一次）。
        DiagLog.event("chapters", "count", "本页：节点 \(nodes.count) → 有效 \(collected.count) → 去重后新增 \(list.count - baseIndex)"
                      + (beforeDedup - list.count > 0 ? "（URL 去重掉了 \(beforeDedup - list.count) 条）" : ""))
        // 🔎 插桩：**章节名**到底取到了什么。用户报「章节都没有名字」时，
        //    这一条能区分三种情况：
        //      ① 名字全空 → 名字规则（如裸属性名 `title`）没作用在节点上
        //      ② 名字全同 → 规则取到了容器文本（`namesPoor` 分支会打印）
        //      ③ 名字正常 → 问题在显示层，不在解析层
        if !collected.isEmpty {
            let head = collected.prefix(3).map { $0.name.isEmpty ? "(空)" : String($0.name.prefix(14)) }
            DiagLog.event("chapters", "name",
                          "章节名样本：\(head.joined(separator: " / "))｜非空 \(collected.filter { !$0.name.isEmpty }.count)/\(collected.count)"
                          + "｜规则=\(s.ruleChapterName?.prefix(20) ?? "(无)")")
        }

        // ── 解析管线：规则 → 万用（质量门 + 择优）────────────────────────────
        // ⚠️ 旧逻辑是「规则**非空**就收工」，于是「**部分成功**」永远发现不了 ——
        //    实测绅士漫画 ssmhw.com：规则首屏只给 26 章、实际 376 章，
        //    而「非空即止」根本不会去问「是不是漏了」。
        //    现在改为：规则结果**达标**才收工；**可疑**（明显偏少）则继续跑万用，
        //    最后取更优的那个。万用扫描**复用同一份 html**，不额外发网络请求。
        //
        // 首屏 `skipPagination=true` 时规则本来就只解析第一页（偏少是正常的），
        // 所以把达标线放低，避免无谓地跑万用。
        let minChapters = skipPagination ? 1 : 5
        let ruleChapters = list
        let piped = await ParseCore.run(
            stage: .chapters, sourceKey: s.bookSourceUrl,
            empty: [ComicInfo.Chapter](),
            // 交叉验证用：章节的身份 = URL。两级都产出时据此算重合率
            // （重合率高 → 两个引擎互相印证；低 → 至少一个在解析别的东西）。
            identity: { Set($0.map(\.url)) },
            steps: [
                (.rule, {
                    (ruleChapters,
                     ParseCore.Quality.of(ruleChapters.count, usableWhenAtLeast: minChapters))
                }),
                (.universal, {
                    // JSON 响应没有可扫描的链接结构
                    guard !isJson else { return ([], ParseCore.Quality.none) }
                    var d = UniversalParser.Diagnosis()
                    let cands = UniversalParser.scanChapters(html: html, pageUrl: baseUrl,
                                                             baseOrigin: s.bookSourceUrl, diagnosis: &d)
                    guard !cands.isEmpty else { return ([], ParseCore.Quality.none) }
                    diag?.merge(d)
                    // ── 取长补短 ①：语义骨架 + 召回补全 ──────────────────────
                    // 规则的长处是**顺序/命名**，万用的长处是**召回**（能发现规则漏的）。
                    // 所以以规则为骨架、把万用里规则没有的**追加**到末尾 ——
                    // 而不是简单拼接（会破坏顺序）或整体替换（会丢掉规则的命名）。
                    // 具体实现收在兼容模块里（`CompatKit.mergePreservingOrder`）。
                    let extra = cands.compactMap { c -> ComicInfo.Chapter? in
                        let abs = s.absoluteUrl(c.url, base: baseUrl)
                        guard !abs.isEmpty else { return nil }
                        return ComicInfo.Chapter(name: c.name, url: abs, group: "")
                    }
                    let merged = CompatKit.mergePreservingOrder(
                        primary: ruleChapters, secondary: extra, identity: { $0.url })
                    return (merged, ParseCore.Quality.of(merged.count))
                }),
            ])
        if piped.winner == .universal { list = piped.value }
        if let w = piped.winner, w != .rule {
            diag?.hit("解析管线：\(piped.summary)")
        }

        // ── 下一页（统一游标：与搜索/栏目共用 PageCursor 合同）─────────────
        // ① 源规则 ruleChapterUrlNext → ①.5 页面下一页链接发现；二者取最先命中的，
        //    优先级不变。循环防护 / 最大页数 / URL 去重统一收进 beginPage/finishPage，
        //    不再各自维护 `visited` 集合。
        var discoveredNext: String? = nil
        if page < 40, !skipPagination, let nextRule = s.ruleChapterUrlNext, !nextRule.isEmpty {
            let next = await a.getString(nextRule)
            if !next.isEmpty,
               let nu = URL(string: s.absoluteUrl(next, base: baseUrl)),
               nu.absoluteString != baseUrl {
                discoveredNext = nu.absoluteString
            }
        }
        if discoveredNext == nil, page < 40, !skipPagination,
           PagingStrategyResolver.canScanLinks(isHTML: !isJson),
           let nx = Self.findNextLink(html, baseUrl: baseUrl, currentPage: page),
           let nu = URL(string: nx), nu.absoluteString != baseUrl {
            // 🔴 「下一页」如果**本身就在章节列表里**，那它是章节链接（比如详情页底部的
            //    「开始阅读」按钮），不是分页链接 —— 跟过去只会把同一份章节再抓一遍。
            if list.contains(where: { $0.url == nu.absoluteString }) {
                DiagLog.event("chapters", "paging",
                              "跳过伪分页链接（就是一章）：\(DiagLog.safeURL(nu.absoluteString))")
            } else {
                discoveredNext = nu.absoluteString
            }
        }

        // 记录本页进度并推进游标（itemIDs 供未来「连续无进展」终止；当前阈值很高=不提前停）
        finishPage(ckey, page: page, nextURL: discoveredNext,
                   itemIDs: list.map(\.url), allowsComputedFallback: false)

        if !skipPagination, let nx = discoveredNext,
           beginPage(ckey, page: page + 1, url: nx), Date() < deadline {
            let nextHtml = await HttpFetcher.shared.fetchText(
                nx,
                headers: ["User-Agent": s.httpUserAgent ?? AppSettings.shared.httpUA,
                          "Referer": s.bookSourceUrl],
                timeout: 15)
            if !nextHtml.isEmpty {
                let nj = nextHtml.trimmingCharacters(in: .whitespaces).hasPrefix("{")
                    || nextHtml.trimmingCharacters(in: .whitespaces).hasPrefix("[")
                let how = (s.ruleChapterUrlNext ?? "").isEmpty ? "页面下一页链接" : "源规则"
                diag?.hit("章节分页走「\(how)」")
                return await chapters(source: s, info: info, html: nextHtml, isJson: nj,
                                      baseUrl: nx, page: page + 1,
                                      accumulated: list, deadline: deadline, diag: diag)
            }
            abortPage(ckey, url: nx)   // 抓取失败释放访问标记，允许同页安全重试
        }

        // ② 万用引擎兜底：规则给不出「下一页」时，按 `?p=N` **并行分批**探测。
        //
        // 为什么是「并行分批」而不是「顺序猜一页算一页」：
        // 绅士漫画有 376 章，站点每页 50 章 → 要 8 页。顺序抓 8 次、
        // 每次 1~3s（挂代理更慢），用户要盯着详情页等十几秒。
        // 改成每批并发 6 页，8 页两批就够 —— 延迟从「页数 × 单页耗时」
        // 降到「批数 × 单页耗时」。
        //
        // 触发条件刻意收紧（避免给 455 个没有分页的图源平白加请求）：
        //   · 只在顶层 page == 1 做一次
        //   · 且（规则本来就想翻页 ‖ 页面里存在分页痕迹）
        //   该分支不经由游标（独立并行探测），故不受上面 exhausted 影响。
        if !isJson, page == 1, !skipPagination {
            let ruleWantedPaging = !(s.ruleChapterUrlNext ?? "").isEmpty
            if ruleWantedPaging || UniversalParser.hasPaginationHint(html) {
                return await probePaginationParallel(source: s, info: info, baseUrl: baseUrl,
                                                     list: list, deadline: deadline, diag: diag)
            }
        }
        // 🔴 **最终按 (季, 话号) 排序** ——
        //    真机实测（2026-10-14，漫画1234/完美世界 678 章）：站点把「最新更新」那话
        //    顶在最前，顺序是 `第88话, 第1话, 第2话, …`，不排用户看到的就是乱序。
        //    用「(季, 话号)」双段键而不是「第一个数字」，所以**分季漫画不会被打乱**
        //   （`3话`→(1,3) 排在 `第二季第1话`→(2,1) 之前）。
        //    安全阀：抽不到编号的站点（slug 型）原样返回，不破坏站点顺序。
        return UniversalParser.sortByChapterNumber(list)
    }

    /// 万用分页探测（并行分批）。
    ///
    /// 生成 `?p=2...?p=N` 候选 → 每批并发抓 6 页 → 合并去重 → 停止。
    ///
    /// ── 终止条件（2026-10 实测后重写，这是本函数最脆弱的地方）──────────
    /// 最初用「整批零新增」就停。实测绅士漫画**停不下来**：
    /// 站点对 `?p=9` 以后的页面不再渲染真正的章节列表，而是渲染一个
    /// **随机推荐块**（同样指向 `/novel103670/chapterN.html`，前缀过滤拦不住，
    /// 且每次返回的编号都不同）→ 每页都能「新增」50 章 → 一路探到 1626 章。
    ///
    /// 改用「章节号是否推进」：
    ///   本批新增章节的**最大编号**没有超过已知最大编号 → 说明后面的页
    ///   只是在重复已有区间（或吐随机推荐），立刻停。
    ///
    /// 实测轨迹（ssmhw，共 400 章）：
    ///   第1批 p=2..7   → 50..349   max 349 ↑ 继续
    ///   第2批 p=8..13  → 350..399 + 补回 26..49  max 399 ↑ 继续
    ///   第3批 p=14..19 → 无更大编号 ↓ 停止
    ///
    /// 另有两条兜底：整批零新增、页数/时间上限。
    private func probePaginationParallel(source s: ComicSource, info: ComicInfo, baseUrl: String,
                                         list: [ComicInfo.Chapter], deadline: Date,
                                         diag: UniversalParser.DiagnosisBox?) async -> [ComicInfo.Chapter] {
        let cands = UniversalParser.paginationCandidates(pageUrl: baseUrl, upTo: 60)
        guard !cands.isEmpty else { return list }

        let headers: [String: String] = [
            "User-Agent": s.httpUserAgent ?? AppSettings.shared.httpUA,
            "Referer": s.bookSourceUrl
        ]
        var seen = Set(list.map(\.url))
        var scanned: [(name: String, url: String)] = []
        let waveSize = 6
        let maxWaves = 6          // 最多 36 页（≈1800 章）
        let maxChapters = 3000    // 病态站点兜底
        var cursor = 0
        var wave = 0
        var maxNum = list.compactMap { UniversalParser.chapterNumber(in: $0.url) }.max() ?? -1
        // 🔴 同时跟踪**最小**章节号 —— 判据要用「区间是否向外扩张」而不是只看最大值。
        //    很多站点**新章在前**（降序排列）：第 2 页的编号比第 1 页**小**，
        //    只判 `waveMax <= maxNum` 会在**第二页就误停** → 章节大面积缺失
        //    （用户报「章节没解析全」的一种典型成因）。
        var minNum = list.compactMap { UniversalParser.chapterNumber(in: $0.url) }.min() ?? Int.max

        while wave < maxWaves, cursor < cands.count, Date() < deadline,
              list.count + scanned.count < maxChapters {
            let batch = Array(cands[cursor..<min(cursor + waveSize, cands.count)])
            cursor += batch.count
            wave += 1

            let pages: [(String, String)] = await withTaskGroup(of: (String, String).self) { group in
                for u in batch {
                    group.addTask {
                        let h = await HttpFetcher.shared.fetchText(u, headers: headers, timeout: 15)
                        return (u, h)
                    }
                }
                var out: [(String, String)] = []
                for await r in group { out.append(r) }
                return out
            }

            var gained = 0
            var waveMax = maxNum
            var waveMin = minNum
            for (u, h) in pages where !h.isEmpty {
                var d = UniversalParser.Diagnosis()
                let items = UniversalParser.scanChapters(html: h, pageUrl: u,
                                                         baseOrigin: s.bookSourceUrl, diagnosis: &d)
                diag?.merge(d)
                for it in items {
                    let abs = s.absoluteUrl(it.url, base: u)
                    guard !abs.isEmpty, !seen.contains(abs) else { continue }
                    seen.insert(abs)
                    scanned.append((name: it.name, url: abs))
                    gained += 1
                    if let n = UniversalParser.chapterNumber(in: abs) {
                        if n > waveMax { waveMax = n }
                        if n < waveMin { waveMin = n }
                    }
                }
            }
            if gained == 0 { break }                       // 整批零新增 → 到底了
            // 本批既没出现更大的章节号、也没出现更小的 → 后面的页只是在重复已有区间，停。
            // ⚠️ 必须**双向**判断（见 `minNum` 的说明）；`maxNum >= 0` 才启用
            //    （slug 型站点抽不到编号，别误停）。
            if maxNum >= 0, waveMax <= maxNum, waveMin >= minNum { break }
            maxNum = max(waveMax, maxNum)
            minNum = min(waveMin, minNum)
        }

        guard !scanned.isEmpty else { return list }
        // 名字校准：把「从 URL 合成的名字」按首页真实名字学到的偏移修正
        let extra = UniversalParser.calibrateNames(scanned, using: list)
        let merged = UniversalParser.sortByChapterNumber(list + extra)
        diag?.hit("分页探测(\(list.count)→\(merged.count)章)")
        return merged
    }

    // MARK: - 正文（图片列表）

    /// 正文图片列表 + 规则尾部 `@Header:{...}`。
    /// ⚠️ 图片请求必须带上这个 Header（很多图片站校验 Referer，不带就 403），
    /// 否则阅读器会一直黑屏转圈。原实现把它丢掉了，只剩 URL 字符串。
    func contentWithHeaders(chapterUrl: String, origin: String, page: Int = 1,
                            accumulated: [String] = [], headers: [String: String] = [:],
                            deadline: Date = Date().addingTimeInterval(45)) async -> (urls: [String], headers: [String: String]) {
        guard Date() < deadline else { return (accumulated, headers) }   // 总预算：正文分页递归最多 45s，杜绝无限转圈
        // ── JS 类源（ARCHITECTURE §9.1）──
        // 同 detail：`js://<id>` 走注册表里的 JSProvider，失败返回空而不是崩。
        if let jsID = Self.jsSourceID(from: origin),
           let provider = SourceProviderRegistry.shared.jsProvider(id: jsID) {
            let r: (urls: [String], headers: [String: String]) =
                (try? await provider.images(chapterUrl: chapterUrl, origin: origin,
                                            page: page, extraHeaders: headers)) ?? ([], [:])
            // ── 解析管线：JS → 万用 ──────────────────────────────────────────
            // JS 源此前完全没有兜底（与 detail 的章节兜底配对，见
            // `universalImagesFallback` 的说明）。达标线同为 1 张：JS 通道拿不到
            // 原始 HTML，万用兜底要额外抓一次页面，只在**完全落空**时降级。
            let piped = await ParseCore.run(
                stage: .images, sourceKey: origin,
                empty: [String](),
            identity: { Set($0) },
                steps: [
                    (.js, { (r.urls, ParseCore.Quality.of(r.urls.count)) }),
                    (.universal, {
                        let urls = await Self.universalImagesFallback(
                            chapterUrl: chapterUrl, origin: origin, headers: headers)
                        return (urls, ParseCore.Quality.of(urls.count))
                    }),
                ])
            if piped.winner == .universal { return (piped.value, headers) }
            return (r.urls, r.headers)
        }
        guard let s = ComicRepository.shared.source(url: origin) else { return ([], [:]) }
        // 顶层（page==1）重置本章游标，保证每次打开章节都从头开始（与原来
        // `visited` 默认空集一致）；最大页数 50、连续无进展上限很高=保持原终止行为。
        let ckey = contentScopeKey(origin: origin, chapterUrl: chapterUrl)
        if page == 1 { seedCursor(ckey, maximumPages: 50, maximumNoProgressPages: 50) }
        // 第一页结果整体缓存（图片 URL 列表 + 请求头），30 分钟内再进同一章秒开
        if accumulated.isEmpty, page == 1 {
            let key = CacheDomain.content.key(origin, chapterUrl)
            if let cached = await ResponseCache.shared.get(key),
               let d = cached.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let us = obj["u"] as? [String], !us.isEmpty {
                let hs = (obj["h"] as? [String: String]) ?? [:]
                return (us, hs)
            }
        }
        // 章节页可能很大且国内站点慢，30s（原来 15s 会让慢站直接返回空 → 阅读器报「未解析到图片」）
        let html = await HttpFetcher.shared.fetchPage(chapterUrl, headers: ["User-Agent": s.httpUserAgent ?? AppSettings.shared.httpUA, "Referer": s.bookSourceUrl], timeout: 30)
        guard !html.isEmpty else {
            DiagLog.event("content", "page",
                          "❌ 章节页返回空（page=\(page)）：\(DiagLog.safeURL(chapterUrl))")
            return (accumulated, headers)
        }
        let isJson = html.trimmingCharacters(in: .whitespaces).hasPrefix("{") || html.trimmingCharacters(in: .whitespaces).hasPrefix("[")
        let a = AnalyzeRule(baseUrl: chapterUrl)
        if isJson { a.setJson(html, baseUrl: chapterUrl) } else { a.setDocument(html: html, baseUrl: chapterUrl) }

        var images: [String] = accumulated
        var outHeaders = headers

        // ── 声明式多级内容流（ruleContentFlow）：卡拉等「挑战流」站点优先 ──
        // 引擎用 HttpFetcher **原生**执行（不走 JavaScriptCore 的 java.get 桥），真机稳定。
        // 没有该字段的源走下面传统「规则 → 万用兜底」路径，行为完全不变。
        let flowResult = await Self.contentFlow(s, chapterHtml: html, chapterUrl: chapterUrl)
        let useFlow = !flowResult.urls.isEmpty

        if useFlow {
            images = flowResult.urls
            outHeaders.merge(flowResult.headers) { _, new in new }
            DiagLog.event("engine", "flow", "ruleContentFlow 命中 \(images.count) 张图")
        } else {
            let contentRule = s.ruleBookContent ?? ""
            if !contentRule.isEmpty {
                // 先把尾部 @Header:{...} 摘出来（splitAndRun 会把它剥掉且丢弃）
                let (cleanRule, ruleHeaders) = a.extractTrailingHeaders(contentRule)
                if !ruleHeaders.isEmpty { outHeaders.merge(ruleHeaders) { _, new in new } }
                let urls = await a.getStringList(cleanRule)
                for u in urls where !u.isEmpty {
                    let abs = s.absoluteUrl(u, base: chapterUrl)
                    if !images.contains(abs) { images.append(abs) }
                }
            } else {
                // 兜底：正则抓 img src
                let re = try? NSRegularExpression(pattern: "<img[^>]+src=[\"']([^\"']+)[\"']")
                for m in (re?.matches(in: html, range: NSRange(html.startIndex..., in: html)) ?? []) {
                    if let r = Range(m.range(at: 1), in: html) {
                        let abs = s.absoluteUrl(String(html[r]), base: chapterUrl)
                        if !images.contains(abs) { images.append(abs) }
                    }
                }
            }
        }

        // ── 解析管线：规则 → 万用（质量门 + 择优）── 仅当 ruleContentFlow 未命中 ──
        // 与 `chapters` 同理：旧逻辑是「规则**非空**就收工」，于是
        // 「规则只解出前几张、后面的全漏」这种情况**永远发现不了**。
        // 达标线定 2 张：正常章节页至少 2 张图；只解出 1 张几乎必然是规则没匹配全。
        // 万用扫描**复用同一份 html**，不额外发网络请求。
        if !useFlow {
        let ruleImages = images
        let pipedImages = await ParseCore.run(
            stage: .images, sourceKey: s.bookSourceUrl,
            empty: [String](),
            identity: { Set($0) },
            steps: [
                (.rule, { (ruleImages,
                          ParseCore.Quality.of(ruleImages.count, usableWhenAtLeast: 2)) }),
                (.universal, {
                    guard !isJson else { return ([], ParseCore.Quality.none) }
                    var d = UniversalParser.Diagnosis()
                    let scanned = UniversalParser.scanImages(html: html, pageUrl: chapterUrl,
                                                            baseOrigin: s.bookSourceUrl, diagnosis: &d)
                    let abs = scanned.compactMap { u -> String? in
                        let a = s.absoluteUrl(u, base: chapterUrl)
                        return a.isEmpty ? nil : a
                    }
                    // ── 取长补短 ④：污染剔除 ────────────────────────────────
                    // 万用召回高但会捞到**别的作品**的图（正文页常有「推荐/猜你喜欢」）。
                    // 用规则侧的「本作品路径前缀」把它们剔掉 ——
                    // 这是拿规则的**语义**去补万用**无语义**的短。
                    let kept = CompatKit.dropForeign(abs, pageUrl: chapterUrl)
                    // 取长补短 ①：以规则为骨架、把万用新发现的追加到末尾
                    let merged = CompatKit.mergePreservingOrder(
                        primary: ruleImages, secondary: kept, identity: { $0 })
                    return (merged, ParseCore.Quality.of(merged.count))
                }),
            ])
        if pipedImages.winner == .universal { images = pipedImages.value }
        }

        // 🔴 两条通用兜底（2026-10-27，用户反馈「很多漫画打开一直重试也没图片」）：
        //    根因是 6 个图源的 `ruleContentList` **全为空**，正文图全靠万用扫 `<img>`。
        //    但有一类站点的图**不在 HTML 里**：
        //      · 卡拉：图片由页面脚本注入 → HTML 里一个 <img> 都没有
        //      · W漫画：`var num=eval("27"); var pasd="…/"; pasd+i+".webp"` → JS 拼出来
        //    这两种站点「打开没图、一直重试」，靠规则永远修不好。
        if images.isEmpty, !isJson {
            // ① JS 拼图模式：直接从脚本变量生成地址（零网络开销）
            if let gen = Self.jsTemplateImages(html: html) {
                images = gen
                DiagLog.event("content", "jsgen", "JS 拼图模式命中：\(gen.count) 张")
            }
            // ② 仍为空 → 用内置浏览器渲染章节页，再扫一遍（JS 注入图只能这么拿）
            //    ⚠️ `fetchRendered` 返回的是**非可选** String（空串表示失败），不能用 if let
            let rendered = await WebViewRuleEngine.shared.fetchRendered(url: chapterUrl)
            if images.isEmpty, !rendered.isEmpty, rendered != html {
                var d2 = UniversalParser.Diagnosis()
                let scanned = UniversalParser.scanImages(html: rendered, pageUrl: chapterUrl,
                                                         baseOrigin: s.bookSourceUrl, diagnosis: &d2)
                let abs = scanned.compactMap { u -> String? in
                    let a = s.absoluteUrl(u, base: chapterUrl)
                    return a.isEmpty ? nil : a
                }
                let kept = CompatKit.dropForeign(abs, pageUrl: chapterUrl)
                if !kept.isEmpty {
                    images = kept
                    DiagLog.event("content", "render", "WebView 渲染后取到 \(kept.count) 张图")
                } else {
                    DiagLog.event("content", "render", "❌ WebView 渲染后仍 0 张：\(DiagLog.safeURL(chapterUrl))")
                }
            }
        }

        // 正文下一页（统一游标：与搜索/栏目/章节共用 PageCursor 合同）
        // ① 源规则 ruleContentUrlNext → ①.5 页面下一页链接发现；取最先命中者，优先级不变。
        //    循环防护 / 最大页数 / URL 去重统一收进 beginPage/finishPage。
        var discoveredNext: String? = nil
        if let nextRule = s.ruleContentUrlNext, !nextRule.isEmpty, page < 50 {
            let next = await a.getString(nextRule)
            if !next.isEmpty,
               let nu = URL(string: s.absoluteUrl(next, base: chapterUrl)),
               nu.absoluteString != chapterUrl {
                discoveredNext = nu.absoluteString
            }
        }
        if discoveredNext == nil,
           PagingStrategyResolver.canScanLinks(isHTML: !isJson), page < 50,
           let nx = Self.findNextLink(html, baseUrl: chapterUrl, currentPage: page),
           let nu = URL(string: nx), nu.absoluteString != chapterUrl {
            discoveredNext = nu.absoluteString
        }

        finishPage(ckey, page: page, nextURL: discoveredNext,
                   itemIDs: images, allowsComputedFallback: false)

        if let nx = discoveredNext,
           beginPage(ckey, page: page + 1, url: nx), Date() < deadline {
            let merged = await contentWithHeaders(chapterUrl: nx, origin: origin,
                                                  page: page + 1, accumulated: images,
                                                  headers: outHeaders, deadline: deadline)
            // 最外层（page==1）负责写缓存：此时 merged 已含全部页的图片
            if page == 1, !merged.urls.isEmpty {
                await cacheContent(origin: origin, chapterUrl: chapterUrl,
                                   urls: merged.urls, headers: merged.headers)
            }
            return merged
        }

        // 单页（无下一页）
        if page == 1, !images.isEmpty {
            await cacheContent(origin: origin, chapterUrl: chapterUrl, urls: images, headers: outHeaders)
        }
        return (images, outHeaders)
    }

    /// ⚡️ 只抓**第一页**正文（不递归下一页）。
    ///
    /// 为什么需要它：`contentWithHeaders` 在有 `ruleContentUrlNext` 的源上会把整章
    /// 所有分页**串行**抓完才返回（一章 5~10 页 = 5~10 次 HTTP）。
    /// 用户感知就是「打开漫画要等好久，什么都看不到」。
    ///
    /// 改成：首屏只等第一页 → 立刻渲染 → 剩下的页由 `contentRemainingPages` 在后台续。
    func contentFirstPage(chapterUrl: String, origin: String) async -> (urls: [String], headers: [String: String], hasNext: Bool) {
        // 🔴🔴 JS 图源必须**最先**判断并 return —— `origin` 形如 `js://<id>`，
        //      `ComicRepository.source(url:)` 根本查不到它，走到下面只会返回空
        //      → 阅读器报「未解析到图片」→ **JS 源的漫画一个都打不开**。
        //      （`detail`:879 / `contentWithHeaders`:1491 一直都有这个分支，
        //        只有本函数漏了。由 10 智能体交叉审查发现，两个智能体独立命中。）
        if let jsID = Self.jsSourceID(from: origin),
           let provider = SourceProviderRegistry.shared.jsProvider(id: jsID) {
            let r: (urls: [String], headers: [String: String]) =
                (try? await provider.images(chapterUrl: chapterUrl, origin: origin,
                                            page: 1, extraHeaders: [:])) ?? ([], [:])
            // JS 一条都没解出来 → 万用兜底扫页面（与 contentWithHeaders 的降级配对）
            if r.urls.isEmpty {
                let urls = await Self.universalImagesFallback(chapterUrl: chapterUrl, origin: origin, headers: [:])
                if !urls.isEmpty { return (urls, [:], true) }
            }
            // hasNext=true：JS 的 images 入口本身带 page 参数，第 2+ 页交给
            // `contentRemainingPages` 续抓（那里也已补 JS 分支）
            return (r.urls, r.headers, true)
        }
        guard let s = ComicRepository.shared.source(url: origin) else { return ([], [:], false) }
        // 缓存命中：整章都在缓存里，直接返回（hasNext=false，无需再续）
        let key = CacheDomain.content.key(origin, chapterUrl)
        if let cached = await ResponseCache.shared.get(key),
           let d = cached.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let us = obj["u"] as? [String], !us.isEmpty {
            return (us, (obj["h"] as? [String: String]) ?? [:], false)
        }
        let html = await HttpFetcher.shared.fetchPage(
            chapterUrl,
            headers: ["User-Agent": s.httpUserAgent ?? AppSettings.shared.httpUA,
                      "Referer": s.bookSourceUrl],
            timeout: 30)
        guard !html.isEmpty else {
            // ⚠️ 这条日志是「白屏无日志」的解药：章节页拿不到时旧代码直接静默 return，
            //    用户只看到「加载失败」，排查全靠猜。现在必须留下痕迹。
            DiagLog.event("content", "first",
                          "❌ 章节页返回空 → 直接判失败：\(DiagLog.safeURL(chapterUrl))")
            return ([], [:], false)
        }
        let isJson = html.trimmingCharacters(in: .whitespaces).hasPrefix("{") || html.trimmingCharacters(in: .whitespaces).hasPrefix("[")
        let a = AnalyzeRule(baseUrl: chapterUrl)
        if isJson { a.setJson(html, baseUrl: chapterUrl) } else { a.setDocument(html: html, baseUrl: chapterUrl) }

        var images: [String] = []
        var outHeaders: [String: String] = [:]

        // ── 声明式多级内容流（ruleContentFlow）：卡拉等挑战流站点优先 ──
        // 引擎原生执行（HttpFetcher），不走 JS 桥，真机稳定；无此字段的源不受影响。
        let flowResult = await Self.contentFlow(s, chapterHtml: html, chapterUrl: chapterUrl)
        if !flowResult.urls.isEmpty {
            images = flowResult.urls
            outHeaders.merge(flowResult.headers) { _, new in new }
            DiagLog.event("engine", "flow", "ruleContentFlow(首屏) 命中 \(images.count) 张图")
        } else {
            let contentRule = s.ruleBookContent ?? ""
            if !contentRule.isEmpty {
                let (cleanRule, ruleHeaders) = a.extractTrailingHeaders(contentRule)
                if !ruleHeaders.isEmpty { outHeaders.merge(ruleHeaders) { _, new in new } }
                for u in await a.getStringList(cleanRule) where !u.isEmpty {
                    let abs = s.absoluteUrl(u, base: chapterUrl)
                    if !images.contains(abs) { images.append(abs) }
                }
            } else {
                let re = try? NSRegularExpression(pattern: "<img[^>]+src=[\"']([^\"']+)[\"']")
                for m in (re?.matches(in: html, range: NSRange(html.startIndex..., in: html)) ?? []) {
                    if let r = Range(m.range(at: 1), in: html) {
                        let abs = s.absoluteUrl(String(html[r]), base: chapterUrl)
                        if !images.contains(abs) { images.append(abs) }
                    }
                }
            }
            // ── 万用引擎兜底：规则没解出来 → 扫 HTML（懒加载属性 / srcset / 内联脚本） ──
            if images.isEmpty, !isJson {
                var d = UniversalParser.Diagnosis()
                for u in UniversalParser.scanImages(html: html, pageUrl: chapterUrl,
                                                   baseOrigin: s.bookSourceUrl, diagnosis: &d) {
                    let abs = s.absoluteUrl(u, base: chapterUrl)
                    if !images.contains(abs) { images.append(abs) }
                }
            }
        }
        // 是否有下一页。
        // 🔴 以前只看「有没有配 `ruleContentUrlNext`」—— 靠**页面里的下一页链接**
        //    分页的源（没配该规则）永远 `hasNext=false` → 后台续抓根本不触发 →
        //    **正文缺页**（用户以为图源坏了）。这里对齐 `contentWithHeaders` 的判定：
        //    规则命中 **或** 页面里能扫到下一页链接。
        //    （由智能体「源核」「漫读」分别发现）
        let hasNextRule = !(s.ruleContentUrlNext ?? "").isEmpty
        let hasNextLink = !isJson
            && PagingStrategyResolver.canScanLinks(isHTML: true)
            && Self.findNextLink(html, baseUrl: chapterUrl, currentPage: 1) != nil
        // 无论成功失败都落一条：把「flow 步数 / 规则长度 / html 大小 / 最终图数」打出来，
        // 「白屏且无日志」这类静默失败以后一眼就能定位。
        DiagLog.event("content", "first",
                      "结果 images=\(images.count)｜flow=\(s.ruleContentFlow?.count ?? 0)步"
                      + "｜rule=\((s.ruleBookContent ?? "").count)字｜html=\(html.count)"
                      + "｜\(DiagLog.safeURL(chapterUrl))")
        return (images, outHeaders, hasNextRule || hasNextLink)
    }

    /// ⚡️ 续抓剩余分页（首屏渲染后在后台跑），返回**新增**的图片 URL。
    /// 与 `contentWithHeaders` 的区别：不阻塞首屏，且把结果并回缓存让下次秒开。
    func contentRemainingPages(chapterUrl: String, origin: String,
                               first: [String], headers: [String: String]) async -> [String] {
        // 🔴 JS 源同样要走注册表（`ComicRepository.source(url:)` 查不到 js:// 源）。
        //    JS 的 images 入口自带 `page` 参数，所以按 page=2,3,... 续抓，
        //    某一页拿不到新图就停（不依赖 ruleContentUrlNext）。
        if let jsID = Self.jsSourceID(from: origin),
           let provider = SourceProviderRegistry.shared.jsProvider(id: jsID) {
            var extra: [String] = []
            var seen = Set(first)
            var p = 2
            while p <= 50 {                      // 环路保护：最多 50 页
                let r: (urls: [String], headers: [String: String]) =
                    (try? await provider.images(chapterUrl: chapterUrl, origin: origin,
                                                page: p, extraHeaders: headers)) ?? ([], [:])
                // 🔴 **显式**终止条件（不能只靠 fresh 为空）：
                //    本轮返回的集合与上一轮**完全相同** ⇒ 该源忽略了 `page`
                //    （内置 26 个 JS 源都是这样：一次 `__fetch` 返回整章全量），
                //    再问下去只会拿到同一批图，直接停。
                //    没有这条，一旦某源的图片 URL 带随机 token/时间戳，
                //    `fresh` 每轮都非空 → 跑满 50 轮、白打 49 次网络请求。
                //    （第二轮复核智能体指出：原来的终止依赖「重复调用返回逐字
                //      相同的集合」这一未被 manifest 契约保证的假设。）
                let cur = Set(r.urls)
                if cur == seen { break }
                seen.formUnion(cur)
                let fresh = r.urls.filter { !first.contains($0) && !extra.contains($0) }
                if fresh.isEmpty { break }
                extra.append(contentsOf: fresh)
                p += 1
            }
            return extra
        }
        guard let s = ComicRepository.shared.source(url: origin),
              let nextRule = s.ruleContentUrlNext, !nextRule.isEmpty else { return [] }
        // 用 contentWithHeaders 递归拿全量（内部有环路保护 + 45s 预算），再算差集
        let full = await contentWithHeaders(chapterUrl: chapterUrl, origin: origin, accumulated: first,
                                            headers: headers,
                                            deadline: Date().addingTimeInterval(45))
        let extra = full.urls.filter { !first.contains($0) }
        if !extra.isEmpty || full.urls.count != first.count {
            await cacheContent(origin: origin, chapterUrl: chapterUrl, urls: full.urls, headers: full.headers)
        }
        return extra
    }

    /// 缓存正文解析结果（图片列表 + 规则请求头）
    private func cacheContent(origin: String, chapterUrl: String,
                              urls: [String], headers: [String: String]) async {
        guard !urls.isEmpty else { return }
        let key = CacheDomain.content.key(origin, chapterUrl)
        guard let d = try? JSONSerialization.data(withJSONObject: ["u": urls, "h": headers]),
              let payload = String(data: d, encoding: .utf8) else { return }
        await ResponseCache.shared.put(key: key, value: payload, ttl: CacheDomain.content.ttl)
    }

    /// 兼容旧调用方：只要 URL 列表
    func content(chapterUrl: String, origin: String, page: Int = 1, accumulated: [String] = [],
                 deadline: Date = Date().addingTimeInterval(45)) async -> [String] {
        await contentWithHeaders(chapterUrl: chapterUrl, origin: origin, page: page,
                                 accumulated: accumulated, deadline: deadline).urls
    }

    // MARK: - Web 服务辅助（对应 BookshelfController 的数据接口）

    /// 章节列表（Web 端用，只回名称+链接）
    func webChapters(noteUrl: String, origin: String) async -> [[String: String]] {
        let info = await detail(noteUrl: noteUrl, origin: origin)
        return info.chapters.map { ["name": $0.name, "url": $0.url] }
    }

    /// 正文图片列表（Web 端用）
    func webContent(chapterUrl: String, origin: String) async -> [String] {
        await content(chapterUrl: chapterUrl, origin: origin)
    }
}
