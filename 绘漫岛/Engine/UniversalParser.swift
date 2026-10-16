import Foundation
import SwiftSoup

/// ──────────────────────────────────────────────────────────────────────────
/// 万用解析引擎 —— 「规则没命中也能出内容」的兜底层
///
/// ## 为什么需要它
/// 图源规则是人工写的、站点是会改版的。规则一旦和当前页面结构对不上，
/// 用户看到的就是「章节解析为 0」或「未解析到图片」——白屏，且无从下手。
///
/// 实测案例（绅士漫画 ssmhw.com，2026-10）：
///   · `ruleChapterList = [id=list-chapter] ul.list-chapter a` 在首屏能命中 26 章
///   · 但该站章节是**分页**的（`?p=2` 另有 50 章），而页面里**没有任何 `?p=N` 链接**
///   · 规则里的 `ruleChapterUrlNext` 靠 `h.match(/\?p=(\d+)/g)` 取页码 → 永远匹配空
///   → 结果：只拿到 26/76 章，用户以为「解析失灵」
///
/// ## 设计原则
/// ① **只在规则失败时启用**：规则命中就绝不插手，避免把正确的解析改坏。
/// ② **纯函数式扫描**：输入 HTML，输出候选列表，不碰网络、不碰状态。
/// ③ **保守优先**：兜底结果必须「看起来像」目标（章节链接 / 图片链接），
///    宁可少收也不要塞进一堆垃圾链接。
/// ④ **每次命中都记录下来**（`Diagnosis.hits`），这样用户报「某源不行」时
///    我们能一眼看出是规则失效还是兜底生效，而不是靠猜。
/// ──────────────────────────────────────────────────────────────────────────
enum UniversalParser {

    // MARK: - 诊断

    /// 记录本次解析走了哪条策略，供「图源连通性诊断」展示
    struct Diagnosis {
        var hits: [String] = []
        mutating func hit(_ s: String) { if !hits.contains(s) { hits.append(s) } }
        var summary: String { hits.isEmpty ? "未记录" : hits.joined(separator: " → ") }
    }

    /// 可跨递归调用累积的诊断盒。
    ///
    /// 为什么需要它：`ComicEngine.chapters` 是**递归**的（逐页翻），
    /// 而 `scanChapters` 要的是 `inout Diagnosis`。把每次的结果 merge 进
    /// 这个引用类型，最后一次性交给 `ComicInfo.diagnosis` 展示。
    final class DiagnosisBox: @unchecked Sendable {
        private let lock = NSLock()
        private var d = Diagnosis()
        func merge(_ other: Diagnosis) {
            lock.lock()
            for h in other.hits where !d.hits.contains(h) { d.hits.append(h) }
            lock.unlock()
        }
        func hit(_ s: String) {
            lock.lock(); d.hit(s); lock.unlock()
        }
        var summary: String {
            lock.lock(); defer { lock.unlock() }
            return d.summary
        }
    }

    // MARK: - 章节兜底扫描

    /// 当 `ruleChapterList` 解析不出章节（或明显偏少）时，直接从 HTML 里
    /// 把所有「像章节链接」的 `<a>` 捞出来。
    ///
    /// 判据（全部满足才收）：
    ///   ① href 非空、不是 `#` / `javascript:` / 外链首页
    ///   ② **与详情页同一部漫画**（同路径前缀）—— 这条最关键：
    ///      详情页几乎都带「热门漫画 / 猜你喜欢」侧栏，不过滤就会把
    ///      别的作品的章节全捞进来（实测捞到 58 条，其中 30+ 条是别人的）
    ///   ③ 链接文本或 title 含「话/話/章/回/卷/集/第N」等章节特征词
    ///
    /// ── 名字的三级回退（2026-10 实测补上，很关键）────────────────────────
    /// 站点在**分页页**上常常不渲染章节名。绅士漫画 ssmhw.com 的 `?p=2`：
    /// ```html
    /// <a href="/novel103670/chapter50.html" title="">
    ///   <span class="chapter-text"></span></a>
    /// ```
    /// 文本和 title 都是空的。如果照旧 `guard !label.isEmpty` 直接跳过，
    /// 整页 50 章会被全部丢掉 —— 分页探测「拿到了页面却 0 新增」，
    /// 于是终止条件误判成「已经到底」，26 章永远变不成 376 章。
    ///
    /// 所以名字按 `文本 → title → 从 URL 编号合成` 三级回退。
    /// 合成的名字（如 `chapter50.html → 第51话`）随后由 `calibrateNames`
    /// 用首页学到的偏移校正，避免不同站点 0/1 起始不一致。
    ///
    /// - Parameters:
    ///   - html: 详情页 / 章节页 HTML
    ///   - pageUrl: 该 HTML 的地址（用于解析相对路径 + 同源判断）
    ///   - baseOrigin: 图源根（用于同源判断）
    /// - Returns: 去重后的章节候选（保持文档顺序）
    static func scanChapters(html: String, pageUrl: String, baseOrigin: String,
                             diagnosis: inout Diagnosis) -> [(name: String, url: String)] {
        guard let doc = try? SwiftSoup.parse(html, pageUrl) else { return [] }
        guard let anchors = try? doc.select("a[href]") else { return [] }

        let host = URL(string: pageUrl)?.host?.lowercased()
            ?? URL(string: baseOrigin)?.host?.lowercased() ?? ""

        // 章节特征词：命中任一即认为「像一章」
        let chapterHints = ["话", "話", "章", "回", "卷", "集", "節", "节", "篇",
                            "Chapter", "chapter", "EP", "ep"]
        // 明确不是章节的链接特征（导航 / 榜单 / 分类 / 首页）
        let noise = ["/hanman/", "/riman/", "/3d/", "/cg/", "/cosplay/", "/short/",
                     "/list", "/top", "/tag/", "/author", "/search", "/login",
                     "/user", "/bookcase", "/history", "javascript:", "mailto:"]

        // ⚠️ 同部漫画的路径前缀。/novel103670/xxx → 前缀 "/novel103670/"
        let comicPrefix = Self.comicPathPrefix(pageUrl)

        struct Cand { var name: String; var url: String; var alias: Bool }
        var items: [Cand] = []
        var indexOf: [String: Int] = [:]

        for a in anchors.array() {
            guard let href = try? a.attr("href"), !href.isEmpty, href != "#" else { continue }
            let lower = href.lowercased()
            if noise.contains(where: { lower.contains($0) }) { continue }
            if lower.hasPrefix("http"), !lower.contains(host) { continue }   // 外链

            let abs: String
            if lower.hasPrefix("http") { abs = href }
            else if let u = URL(string: href, relativeTo: URL(string: pageUrl)) { abs = u.absoluteString }
            else { continue }

            // ② 必须属于同一部漫画（详情页 URL 前缀）；跨作品一律丢弃
            if !comicPrefix.isEmpty, !abs.contains(comicPrefix) { continue }

            // ③ 文本含章节特征词；或 href 形如 /xxx/chapter12.html、/xxx/12.html
            let textHit = chapterHints.contains { lower.contains($0.lowercased()) }
                || chapterHints.contains { ((try? a.text()) ?? "").contains($0) }
                || chapterHints.contains { ((try? a.attr("title")) ?? "").contains($0) }
            let hrefHit = lower.range(of: #"(chapter|chap|ep|/)\d+(\.html?)?$"#,
                                      options: .regularExpression) != nil
            guard textHit || hrefHit else { continue }

            // ── 名字三级回退 ──
            let rawText = ((try? a.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let rawTitle = ((try? a.attr("title")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var label = rawText.isEmpty ? rawTitle : rawText
            let alias = Self.aliasNames.contains(label)
            if label.isEmpty || alias {
                // 站点没给名字（分页页常见）→ 从 URL 编号合成
                if let synth = Self.synthesizeName(from: abs) { label = synth }
                else if label.isEmpty { continue }   // 连编号都没有才放弃
            }

            if let i = indexOf[abs] {
                // 同一 URL 出现多次（例如「开始阅读」按钮 + 章节列表项）：
                // **优先保留非别名、更长的那个名字**，不要盲删。
                // 旧实现直接 `filter { $0.0 != "开始阅读" }`，会把 chapter0 一起删掉
                // → 实测首页 26 章只捞到 25 章，第 1 话凭空消失。
                if items[i].alias, !alias { items[i].name = label; items[i].alias = alias }
                else if items[i].alias == alias, label.count > items[i].name.count { items[i].name = label }
                continue
            }
            indexOf[abs] = items.count
            items.append(Cand(name: label, url: abs, alias: alias))
        }

        let out = items.map { (name: $0.name, url: $0.url) }
        if !out.isEmpty { diagnosis.hit("章节兜底扫描(\(out.count)条)") }
        return out
    }

    /// 「开始阅读 / 阅读」这类指向首话的**别名**按钮文本。
    /// 命中时优先用同一 URL 上的真实章节名（见 `scanChapters` 的去重分支）。
    static let aliasNames: Set<String> = ["开始阅读", "開始閱讀", "阅读", "閱讀",
                                          "开始观看", "立即阅读", "阅读本章",
                                          "Continue", "Read", "read"]

    // MARK: - 搜索兜底扫描

    /// 搜索列表里**绝不可能**是书名的导航/功能词（命中即丢弃）。
    static let searchJunkNames: Set<String> = [
        "首页", "首頁", "主页", "登录", "登入", "注册", "註冊", "搜索", "搜尋", "检索",
        "上一页", "下一页", "上页", "下页", "末页", "尾页", "更多", "全部", "查看全部",
        "分类", "分類", "排行", "榜单", "榜單", "标签", "標籤", "作者", "更新", "最新",
        "home", "login", "signin", "signup", "register", "search", "next", "prev",
        "previous", "more", "all", "category", "categories", "rank", "ranking",
        "tag", "tags", "author", "update", "updates", "latest", "menu", "close",
    ]

    /// 搜索页里明确**不是详情页**的路径特征（命中即丢弃）。
    ///
    /// ⚠️ 不要在这里放 `"#"` —— 这里用 `contains` 匹配，
    ///    放 `"#"` 会把 `/comic/123#chapter` 这类**带锚点的正常链接**一起丢掉。
    ///    `#` 与 `javascript:` 由下面的显式前缀判断处理。
    private static let searchNoisePaths = [
        "/search", "/login", "/signin", "/signup", "/register", "/user",
        "/tag/", "/tags/", "/category", "/rank", "/top", "/list", "/history",
        "/bookcase", "/bookshelf", "/author", "/about", "/help", "/faq",
    ]

    /// 当 `ruleSearchList` 一条都没解析出来时，直接从 HTML 里捞出「像搜索结果」的链接。
    ///
    /// ## 这是「融合引擎」的第三级
    /// 统一降级链：**规则 → JS → 万用**。
    /// 规则能命中就绝不插手（与 `UniversalParser` 的设计原则一致，
    /// 避免把本来正确的解析改坏）。
    ///
    /// ## 判据（比 `scanChapters` 宽松一点，因为搜索页结构差异极大）
    ///   ① href 非空、不是 `#`/`javascript:`/外链、不是导航路径
    ///   ② 同源（外链丢弃 —— 搜索页常带友链/广告）
    ///   ③ 文本 2~80 字，且不是导航词
    ///   ④ **优先收「<a> 里含 <img>」的链接** —— 搜索结果的封面是极强信号；
    ///      没有 img 的也收，但排序靠后（很多站点用 CSS 背景图）
    ///   ⑤ 按 URL 去重
    ///
    /// ⚠️ 这里**不做关键词相关性过滤** —— 那是调用方 `ComicEngine.rankByRelevance`
    ///    的职责（它有一套完整的评分/剪裁逻辑）。这里只负责「找出候选」。
    ///
    /// - Returns: 候选列表（保持文档顺序，带封面的在前）
    static func scanSearch(html: String, pageUrl: String, baseOrigin: String,
                           diagnosis: inout Diagnosis) -> [(name: String, url: String)] {
        guard let doc = try? SwiftSoup.parse(html, pageUrl) else { return [] }
        guard let anchors = try? doc.select("a[href]") else { return [] }

        let host = URL(string: pageUrl)?.host?.lowercased()
            ?? URL(string: baseOrigin)?.host?.lowercased() ?? ""
        // 搜索页自己的 URL 前缀（避免把「翻页到自身」当成结果）
        let selfURL = pageUrl

        struct Cand { var name: String; var url: String; var hasCover: Bool }
        var items: [Cand] = []
        var indexOf: [String: Int] = [:]

        for a in anchors.array() {
            guard let href = try? a.attr("href"), !href.isEmpty else { continue }
            let lower = href.lowercased()
            // 纯锚点 / JS 伪链接 / mailto 一律丢弃（显式前缀判断，避免误伤带 # 的正常链接）
            if lower.hasPrefix("#") || lower.hasPrefix("javascript:") || lower.hasPrefix("mailto:") {
                continue
            }
            if searchNoisePaths.contains(where: { lower.contains($0) }) { continue }
            // 外链一律丢弃（搜索页的友链/广告）
            if lower.hasPrefix("http"), !host.isEmpty, !lower.contains(host) { continue }

            let abs: String
            if lower.hasPrefix("http") { abs = href }
            else if let u = URL(string: href, relativeTo: URL(string: pageUrl)) { abs = u.absoluteString }
            else { continue }
            if abs == selfURL { continue }               // 指向自己 → 不是结果

            // 文本（→ title → img alt）
            var label = ((try? a.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty { label = ((try? a.attr("title")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            if label.isEmpty, let img = try? a.select("img").first(), let alt = try? img.attr("alt") {
                label = alt.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard label.count >= 2, label.count <= 80 else { continue }
            if searchJunkNames.contains(label.lowercased()) { continue }

            let hasCover = ((try? a.select("img").size()) ?? 0) > 0

            if let i = indexOf[abs] {
                // 同 URL 多次出现 → 保留「更长且带封面」的那个
                if (hasCover && !items[i].hasCover) || label.count > items[i].name.count {
                    items[i].name = label
                    items[i].hasCover = hasCover
                }
                continue
            }
            indexOf[abs] = items.count
            items.append(Cand(name: label, url: abs, hasCover: hasCover))
        }

        // 带封面的排前面（稳定排序，同组内保持文档顺序）
        let ordered = items.enumerated().sorted {
            ($0.element.hasCover ? 0 : 1, $0.offset) < ($1.element.hasCover ? 0 : 1, $1.offset)
        }.map(\.element)

        let out = ordered.map { (name: $0.name, url: $0.url) }
        if !out.isEmpty { diagnosis.hit("搜索兜底扫描(\(out.count)条)") }
        return out
    }

    /// 从 URL 编号合成章节名 —— 站点在分页页不给名字时的兜底。
    ///
    /// · `/novel103670/chapter50.html` → `第51话`（`chapterN` 约定 0 起始，
    ///   与绅士漫画首页 `chapter0.html = 第1话` 一致）
    /// · `/comic/abc/12.html`         → `第12话`
    /// · 取不到编号返回 nil
    ///
    /// ⚠️ 这只是**名字**，读不读得到取决于 URL；偏移随后由 `calibrateNames`
    ///    用首页真实名字校正，所以这里猜错也不会影响阅读。
    static func synthesizeName(from url: String) -> String? {
        guard let n = chapterNumber(in: url) else { return nil }
        // `chapterN` 约定 0 起始（ssmhw 的 chapter0.html = 第1话）；纯尾部数字按 1 起始
        if url.range(of: #"chapter[_\-]?\d+"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return "第\(n + 1)话"
        }
        return "第\(n)话"
    }

    /// 从 URL 里抽出章节号 —— 分页终止判断 + 名字校准都用它。
    ///
    /// · `/novel103670/chapter50.html` → 50
    /// · `/comic/abc/12.html`          → 12
    /// · 抽不到返回 nil（slug 型站点）
    /// 章节号提取：**优先从章节名取**，取不到再退回 URL。
    ///
    /// 🔴 为什么必须优先用名字：真机反馈「88 章排到 1 章前面、顺序乱了」。
    ///    旧实现只看 URL，而 URL 里那个数字经常**不是章节号**：
    ///      · 知音漫客的 `href="437819.html"` —— 437819 是**数据库自增 ID**；
    ///      · 有的站是 `/ch/88-1.html`，末尾数字是**分卷/分P 号**，
    ///        按它排会把 88话1 / 88话2 拆散到别的章节之间。
    ///    名字（「第88话」「88话1」）才是站点真正想表达的序号。
    ///    URL 只作兜底（slug 型站点名字里没号码时才用）。
    static func chapterNumber(name: String, url: String) -> Int? {
        // ① 名字里的第一个数字串：「第88话」→88、「88话1」→88（分P 号不参与排序）
        if let m = name.range(of: #"\d+"#, options: .regularExpression), let n = Int(name[m]), n > 0 {
            return n
        }
        // ② 退回 URL
        return chapterNumber(in: url)
    }

    /// 章节排序键：**(季/部/卷, 话号)**。
    ///
    /// 🔴 为什么要两段：
    ///   · 真机实测（2026-10-14，漫画1234/完美世界）：站点把「最新更新」那话顶在最前，
    ///     顺序是 `第88话, 第1话, 第2话, …` —— 不排序用户看到的就是乱序。
    ///   · 但**只按「第一个数字」排**会把分季漫画排坏：
    ///     「第二季第1话」解析成 1 → 跑到「3话」前面。
    ///   所以先取「季」再取「话」：`3话` → (1,3)；`第二季第1话` → (2,1) → 3话 在前 ✓
    ///
    /// 季/卷/部的数字可能是中文（二、三…），也要认。
    static func chapterSortKey(name: String, url: String) -> (season: Int, chapter: Int)? {
        // ① 季 / 部 / 卷（中文或阿拉伯数字）
        var season = 1
        for unit in ["季", "部", "卷"] {
            if let r = name.range(of: "[第]?([0-9]+|[一二三四五六七八九十]+)" + unit,
                                  options: .regularExpression) {
                let s = String(name[r])
                if let n = chineseOrArabicNumber(s) { season = n; break }
            }
        }
        // ② 话号：取「季/部/卷」之后的第一个数字，避免把季号当成话号
        var tail = name
        if season > 1, let r = name.range(of: "[0-9]+|[一二三四五六七八九十]+[季部卷]",
                                          options: .regularExpression) {
            tail = String(name[r.upperBound...])
        }
        if let m = tail.range(of: #"\d+"#, options: .regularExpression), let n = Int(tail[m]), n > 0 {
            return (season, n)
        }
        // ③ 名字里没数字 → 退回 URL 末尾数字（slug 站）
        if let n = chapterNumber(in: url) { return (season, n) }
        return nil
    }

    /// 「二」→2、「12」→12、「十二」→12（只处理到 99，够用）
    private static func chineseOrArabicNumber(_ s: String) -> Int? {
        let digits = s.filter { $0.isNumber }
        if !digits.isEmpty, let n = Int(digits) { return n }
        let map: [Character: Int] = ["一":1,"二":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9]
        let cn = s.filter { map[$0] != nil || $0 == "十" }
        guard !cn.isEmpty else { return nil }
        if let i = cn.firstIndex(of: "十") {
            let tens = cn[..<i].compactMap { map[$0] }.first ?? 1
            let ones = cn[cn.index(after: i)...].compactMap { map[$0] }.first ?? 0
            return tens * 10 + ones
        }
        return cn.compactMap { map[$0] }.first
    }

    static func chapterNumber(in url: String) -> Int? {
        if let r = url.range(of: #"chapter[_\-]?(\d+)"#, options: [.regularExpression, .caseInsensitive]) {
            let digits = String(url[r]).filter { $0.isNumber }
            if let n = Int(digits) { return n }
        }
        if let r = url.range(of: #"(\d+)(\.html?)?$"#, options: .regularExpression) {
            let digits = String(url[r]).filter { $0.isNumber }
            if let n = Int(digits), n > 0, n < 1_000_000 { return n }
        }
        return nil
    }

    /// 按章节号升序排列。
    ///
    /// 为什么需要：分页探测是**并行**的，各页返回顺序不定；而且站点自己的
    /// 分页可能跳号（实测绅士漫画首页 0..25、?p=2 直接跳到 50..99，26..49
    /// 要靠后面的「随机推荐」块补回来）。不排序的话章节列表会是
    /// `0..25, 50..399, 26..49` 这种乱序。
    ///
    /// 安全阀：只有**绝大多数**（≥80%）章节都能抽到编号时才排序 ——
    /// slug 型站点（`/chapter/xxx-vol-1`）抽不到号，排序会破坏站点原顺序。
    static func sortByChapterNumber(_ items: [ComicInfo.Chapter]) -> [ComicInfo.Chapter] {
        guard !items.isEmpty else { return items }
        // 用「(季, 话号)」双段键 —— 见 `chapterSortKey` 的说明。
        // 安全阀不变：≥80% 能解析出键才排，slug 型站点原样返回。
        let keyed = items.compactMap { chapterSortKey(name: $0.name, url: $0.url) }
        guard keyed.count * 5 >= items.count * 4 else { return items }
        return items.enumerated()
            .sorted { a, b in
                let ka = chapterSortKey(name: a.element.name, url: a.element.url)
                let kb = chapterSortKey(name: b.element.name, url: b.element.url)
                switch (ka, kb) {
                case let (x?, y?):
                    if x.season != y.season { return x.season < y.season }
                    if x.chapter != y.chapter { return x.chapter < y.chapter }
                case (nil, _?): return false      // 解析不出键的排后面
                case (_?, nil): return true
                default: break
                }
                return a.offset < b.offset        // 同键保持原顺序（稳定）
            }
            // ⚠️ 不能写 `map(\.element)` —— Swift 的 key path **不支持元组成员**，
            //    编译期会报 "key path cannot refer to tuple element"。
            .map { $0.element }
    }

    /// 用**已知章节**校准从 URL 合成的名字。
    ///
    /// 不同站点 `chapterN` 的起始不一致（ssmhw 是 0 起始，别的站可能是 1 起始）。
    /// 与其写死，不如从首页已解析出的数据里学偏移：
    ///   首页 `chapter0.html → "第1话"` ⇒ 偏移 +1
    ///   首页 `chapter1.html → "第1话"` ⇒ 偏移 0
    /// 学不到就保持原样（名字只是展示，不影响阅读）。
    static func calibrateNames(_ items: [(name: String, url: String)],
                               using known: [ComicInfo.Chapter]) -> [ComicInfo.Chapter] {
        var offset = 1   // 默认按 `chapterN` 0 起始
        for k in known {
            guard let r = k.url.range(of: #"chapter[_\-]?(\d+)"#, options: [.regularExpression, .caseInsensitive]),
                  let n = Int(String(k.url[r]).filter({ $0.isNumber })),
                  let m = k.name.range(of: #"\d+"#, options: .regularExpression),
                  let named = Int(String(k.name[m])) else { continue }
            offset = named - n
            break
        }
        return items.map { it in
            var name = it.name
            if let r = it.url.range(of: #"chapter[_\-]?(\d+)"#, options: [.regularExpression, .caseInsensitive]),
               let n = Int(String(it.url[r]).filter({ $0.isNumber })) {
                // 只改「像我们合成出来的」那种名字，站点给的真名一律不动
                if name == "第\(n + 1)话" { name = "第\(n + offset)话" }
            }
            return ComicInfo.Chapter(name: name, url: it.url, group: "")
        }
    }

    /// 取「同一部作品」的路径前缀。
    /// `/novel103670/` → `/novel103670/`；`/comic/abc/` → `/comic/abc/`；
    /// `/manga/12345` → `/manga/12345/`。取不到就返回 "/"（退化：只按同 host 过滤）。
    static func comicPathPrefix(_ pageUrl: String) -> String {
        guard let u = URL(string: pageUrl) else { return "/" }
        var path = u.path
        if path.isEmpty || path == "/" { return "/" }
        // 去掉末尾的 index.html / 空段
        path = path.replacingOccurrences(of: #"/index\.html?$"#, with: "/",
                                         options: .regularExpression)
        if !path.hasSuffix("/") { path += "/" }
        // 多级路径时，取「最后一个非数字段 + 其后的数字段」作为作品标识，
        // 例如 /comic/12345/ 保持原样；/a/b/c/12345/ 也保持一致（够用且简单）
        return path
    }

    // MARK: - 图片兜底扫描

    /// 当 `ruleBookContent` 解析不出图片时，从正文页 HTML 里扫所有可能的图片地址。
    ///
    /// 覆盖：
    ///   · `img[src]` / `img[data-src]` / `img[data-original]` / `img[data-lazy-src]`
    ///   · `<source srcset>` / `img[srcset]`（取候选中最大的一张）
    ///   · 内联脚本 / JSON 里的图片数组（`"images":[...]`、`url: "..."`）
    ///   · 跳过明显的图标/占位（gif 小图、logo、avatar、1x1、base64 占位）
    static func scanImages(html: String, pageUrl: String, baseOrigin: String,
                           diagnosis: inout Diagnosis) -> [String] {
        guard let doc = try? SwiftSoup.parse(html, pageUrl) else { return [] }
        var out: [String] = []
        var seen = Set<String>()

        func push(_ raw: String) {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, !s.hasPrefix("data:"), !s.hasPrefix("blob:") else { return }
            let abs = absolute(s, base: pageUrl)
            guard !abs.isEmpty, isLikelyComicImage(abs) else { return }
            if seen.insert(abs).inserted { out.append(abs) }
        }

        // ① img 的各种懒加载属性（按优先级取第一个非空的）
        if let imgs = try? doc.select("img") {
            for img in imgs.array() {
                for attr in ["data-original", "data-src", "data-lazy-src", "data-url", "src"] {
                    if let v = try? img.attr(attr), !v.isEmpty, !v.hasPrefix("data:") {
                        // srcset 取最大的一张
                        if v.contains(",") || v.contains(" ") {
                            if let best = bestFromSrcset(v) { push(best) } else { push(v) }
                        } else { push(v) }
                        break
                    }
                }
            }
        }

        // ② <source srcset>
        if let sources = try? doc.select("source[srcset]") {
            for s in sources.array() {
                if let v = try? s.attr("srcset"), let best = bestFromSrcset(v) { push(best) }
            }
        }

        // ③ 内联脚本里的图片数组（很多站把图片塞在 `var images = [...]`）
        if let scripts = try? doc.select("script") {
            for sc in scripts.array() {
                let js = (try? sc.data()) ?? ""
                if js.isEmpty { continue }
                for m in matches(in: js, pattern: #"https?://[^\s"'\\<>]+\.(?:jpg|jpeg|png|webp|gif|avif)"#) {
                    push(m)
                }
            }
        }

        if !out.isEmpty { diagnosis.hit("图片兜底扫描(\(out.count)张)") }
        return out
    }

    // MARK: - 分页探测

    /// 页面里是否**存在分页机制**的痕迹。
    ///
    /// 为什么需要这个开关：`paginationCandidates` 是「猜 URL」，如果对每个
    /// 图源都无脑猜一次 `?p=2`，488 个源里 455 个没有分页的会白白多打一次
    /// HTTP（详情页延迟直接翻倍）。所以先用一次**廉价的字符串查找**判断
    /// 「这页像不像有分页」，只有像才去猜。
    ///
    /// 实测依据（绅士漫画 ssmhw.com，2026-10）：页面里有
    /// `<div id="pagination"></div>`（空的），规则里的 `ruleChapterUrlNext`
    /// 靠 `h.match(/\?p=(\d+)/g)` 取页码 → 永远匹配空。有容器、无链接，
    /// 正是这个开关要覆盖的形态。
    static func hasPaginationHint(_ html: String) -> Bool {
        guard !html.isEmpty else { return false }
        let needles = ["pagination", "page-list", "pagelist", "pager", "page-nav",
                       "下一页", "下一頁", "下页", "下一章列表", "?p=", "&p=",
                       "page=", "/page/", "list_", "_2.html", "pageNum"]
        let lower = html.lowercased()
        for n in needles where lower.contains(n.lowercased()) { return true }
        return false
    }

    /// 规则里的「下一页」失效时，探测 `?p=N` / `index_N.html` / `page/N` 这类分页。
    ///
    /// ⚠️ 只**生成候选 URL**，不发请求 —— 由调用方决定要不要抓（避免兜底反而拖慢）。
    /// 调用方抓到某页后若章节数没增加，就该停止（防止对 404 页面无限探测）。
    static func paginationCandidates(pageUrl: String, upTo maxPage: Int = 30) -> [String] {
        guard let u = URL(string: pageUrl) else { return [] }
        var base = u.absoluteString
        var sep = "?"
        if base.contains("?") { sep = "&" }
        // 若已有 ?p=N，先把 N 剥掉再做基准
        if let r = base.range(of: #"[?&]p=\d+"#, options: .regularExpression) {
            base.removeSubrange(r)
            if base.hasSuffix("?") || base.hasSuffix("&") { base.removeLast() }
            sep = base.contains("?") ? "&" : "?"
        }
        var out: [String] = []
        for n in 2...max(2, maxPage) { out.append("\(base)\(sep)p=\(n)") }
        return out
    }

    // MARK: - 工具

    private static func absolute(_ s: String, base: String) -> String {
        if s.hasPrefix("//") { return "https:" + s }
        if s.hasPrefix("http") { return s }
        guard let u = URL(string: s, relativeTo: URL(string: base)) else { return "" }
        return u.absoluteString
    }

    /// 过滤掉明显不是漫画正文图的地址
    static func isLikelyComicImage(_ url: String) -> Bool {
        let l = url.lowercased()
        // 必须像图片
        let exts = [".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif", ".bmp"]
        let hasExt = exts.contains { l.contains($0) }
        // 但很多图床 URL 无扩展名（`/img/abc123`），所以无扩展名也放行，
        // 只要不是明显的静态资源
        let staticNoise = [".css", ".js", ".ico", ".svg", "/logo", "avatar",
                           "icon", "sprite", "placeholder", "loading", "blank",
                           "1x1", "pixel", "spacer", "banner", "/ads", "advert"]
        if staticNoise.contains(where: { l.contains($0) }) { return false }
        if hasExt { return true }
        // 无扩展名：要求路径带常见图片目录或较长 hash
        return l.contains("/img") || l.contains("/image") || l.contains("/pic")
            || l.contains("/photo") || l.contains("/media") || l.contains("/upload")
    }

    /// 从 srcset 里取分辨率最大的一张
    private static func bestFromSrcset(_ srcset: String) -> String? {
        var best: (url: String, w: Int)? = nil
        for part in srcset.split(separator: ",") {
            let bits = part.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard let u = bits.first.map(String.init), !u.isEmpty else { continue }
            var w = 0
            if bits.count > 1 {
                let d = bits[1].replacingOccurrences(of: "w", with: "")
                    .replacingOccurrences(of: "x", with: "")
                w = Int(d) ?? 0
            }
            if best == nil || w > best!.w { best = (u, w) }
        }
        return best?.url
    }

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }
}
