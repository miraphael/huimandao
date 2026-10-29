import Foundation

/// 一次性数据补丁：给内置图源补上**正文图规则**。
///
/// ## 为什么需要它（2026-10-27 查出的真 bug）
/// 我们导出的图源 JSON 里一直写的是 `ruleContentList`，但 `ComicSource`
/// **没有这个字段** —— `init(from:)` 只挑自己认识的 key，多余的 key 被静默丢弃。
/// 于是 6 个源在库里 `ruleBookContent` 全是 nil，正文图只能靠
/// 「万用扫 `<img>`」兜底；对「图由 JS 生成/注入」的站（卡拉、W漫画、漫画网）
/// 就是**打开白屏、一直重试也没图**。
///
/// ## 做法
/// 按域名匹配，**只补空字段**（用户自己配过规则的源一律不动），补完广播刷新。
/// 规则以 JSON 文本形式内联，走 `JSONDecoder` 解成 `ContentFlowStep`
/// —— 和从文件导入的路径完全一致，不另造一套构造器。
enum SourceContentPatch {

    /// 只跑一次；以后要再补新规则时把版本号 +1。
    private static let flagKey = "patch.contentRules.v6"

    // MARK: - 发现栏目专用列表规则（只影响 explore，不影响搜索）

    /// 2026-10-28 实测：`tuku.cc` 改版后，**搜索页**仍是 `class.manga-content-item`
    /// （实测 21 处），而**栏目页**（`/comics-pN/`、`/comics-tagN-pN/`、`/comics-orderN/`）
    /// 换成了 `class.swiper-card-item`（每页 24 处，书名在 `class.card-item-title`，
    /// 链接 `tag.a@href`，封面 `tag.img@data-original`）。
    ///
    /// `explore()` 复用**搜索规则**去解析栏目页 → 必然 0 条。
    /// 真机日志实证：`html 29488 字，列表规则=class.manga-content-item` → `0 条`。
    ///
    /// 修法：给「发现」单独一套选择器，通过**复制一份 ComicSource** 传进 `browse`。
    /// · **不动数据库**（不加字段、不做迁移，出问题回退一行代码即可）
    /// · **不动搜索**（搜索页仍是旧 DOM，`ruleSearchList` 必须保留原值）
    private static let findListOverrides: [String: (list: String, name: String,
                                                     noteUrl: String, cover: String)] = [
        "tuku.cc": (list: "class.swiper-card-item",
                    name: "class.card-item-title@text",
                    noteUrl: "tag.a@href",
                    cover: "tag.img@data-original"),
    ]

    /// 给 `explore()` 用的源副本：只替换「列表 / 书名 / 链接 / 封面」四项。
    ///
    /// 🔴 2026-10-29 修正：**源 JSON 里已经有 `||` 双选择器时不要覆盖**。
    ///    图库的源规则实际是
    ///    `class.manga-content-item||class.swiper-card-item` —— 它同时兼容新旧两个 DOM，
    ///    比这里的单选择器**更健壮**（站点改回去也不会挂）。
    ///    昨天在真机上看到的「0 条」是因为**手机里存的是旧版源**（单选择器、无 `||`），
    ///    正确修法是重新导入源，不是改代码。
    ///    这里保留补丁，只为照顾「没重新导入过源」的用户；有 `||` 就原样返回。
    ///
    /// 没有登记的源**原样返回** —— 零开销、零行为变化。
    static func sourceForExplore(_ s: ComicSource) -> ComicSource {
        guard let host = URL(string: s.bookSourceUrl)?.host?.lowercased(),
              let o = findListOverrides.first(where: { host.contains($0.key) })?.value
        else { return s }
        // 库里已经是「兼容新旧 DOM」的规则 → 不要降级成单选择器
        if (s.ruleSearchList ?? "").contains(o.list) { return s }
        var copy = s
        copy.ruleSearchList = o.list
        copy.ruleSearchName = o.name
        copy.ruleSearchNoteUrl = o.noteUrl
        copy.ruleSearchCoverUrl = o.cover
        return copy
    }

    static func applyIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        var changed: [String] = []
        for var s in ComicRepository.shared.allSources() {
            guard let host = URL(string: s.bookSourceUrl)?.host?.lowercased(),
                  let patch = table.first(where: { host.contains($0.host) }) else { continue }
            let hasFlow = (s.ruleContentFlow?.count ?? 0) > 0
            var applied = false

            // ① 清掉历史上配错的规则（W漫画：`tag.img@data-src` 指向 loading.svg，
            //    结果「有图但全是占位符」，还会挡住后面的万用兜底）
            // ⚠️ 用「包含」而不是「完全相等」：用户库里那条规则可能是更早的写法
            //    （`s\d\.bzcdn\.net` 少个 `+`），精确匹配会静默不命中 —— 
            //    真机日志里包子图片全是 404 就是这个原因。
            if let bad = patch.dropBadBook,
               let cur = s.ruleBookContent, cur.contains(bad) {
                s.ruleBookContent = nil
                applied = true
            }
            // ② flow 优先于 ruleBookContent（引擎里也是先跑 flow），
            //    所以只要还没有 flow 就装 —— 不被已有的 rule 挡住
            if !hasFlow, let json = patch.flowJSON, let flow = decodeFlow(json) {
                s.ruleContentFlow = flow
                applied = true
            }
            // ③ 直配规则：只在空的时候填，不覆盖用户/原有配置
            if (s.ruleBookContent ?? "").isEmpty, let book = patch.book, !book.isEmpty {
                s.ruleBookContent = book
                applied = true
            }
            // ④ 发现栏目：老规则指向已改版页面时整体替换（带条件，避免误伤用户改过的配置）
            if let f = patch.find, (s.ruleFindUrl ?? "").contains(f.whenFindUrlContains) {
                s.ruleFindUrl = f.findUrl
                s.ruleSearchList = f.list
                s.ruleSearchName = f.name
                s.ruleSearchNoteUrl = f.noteUrl
                applied = true
            }
            // ⑤ 站点改版导致**规则失效**：只在库里还是那条已知死规则时才换。
            //    判据一律用「包含 / 相等」，不用「无条件覆盖」——
            //    用户自己改过的规则、或站点改回来后的新规则都不能被踩掉。
            if let r = patch.rules {
                if let when = r.chapterListWhenContains, let to = r.chapterList,
                   (s.ruleChapterList ?? "").contains(when) {
                    s.ruleChapterList = to
                    applied = true
                }
                if let when = r.searchCoverWhenEquals, let to = r.searchCover,
                   (s.ruleSearchCoverUrl ?? "") == when {
                    s.ruleSearchCoverUrl = to
                    applied = true
                }
                if let when = r.coverWhenContains, let to = r.cover,
                   (s.ruleCoverUrl ?? "").contains(when) {
                    s.ruleCoverUrl = to
                    applied = true
                }
            }
            guard applied else { continue }
            ComicRepository.shared.saveSource(s)
            changed.append(s.bookSourceName)
        }

        UserDefaults.standard.set(true, forKey: flagKey)
        if !changed.isEmpty {
            NotificationCenter.default.post(name: .hmdSourcesChanged, object: nil)
        }
        DiagLog.event("patch", "contentRules", "补齐正文规则：\(changed.isEmpty ? "无（都已有规则）" : changed.joined(separator: "、"))")
    }

    // MARK: - 规则表

    private struct Patch {
        let host: String
        /// 直配的正文图规则（只在**空**的时候填）
        var book: String? = nil
        /// 多级内容流（优先于 `book`；只要还没有 flow 就装）
        var flowJSON: String? = nil
        /// 清掉历史遗留的**错误**规则（目前只有 W漫画 的 `tag.img@data-src`）
        var dropBadBook: String? = nil
        /// 发现栏目补丁：老规则指向已改版的页面时整体换掉
        var find: FindPatch? = nil
        /// 站点改版导致的选择器失效补丁
        var rules: RulesPatch? = nil
    }

    /// 站点改版后**替换已失效的选择器**。
    ///
    /// 为什么需要（2026-10-29 真机实测）：
    /// · W漫画 把章节列表从 `div.chapter-list a.chaper-btn` 改成了 `div.chapters a`
    ///   —— 旧选择器实测命中 **0 个节点**，章节全靠「通用链接扫描」兜底出 12 条。
    /// · W漫画 把列表封面从 `<img data-src>` 改成了 `div.thumb` 的
    ///   **内联 `background-image:url('…')`** —— 页面里一个 `<img>` 都没有，
    ///   规则产出**空字符串**，于是封面根本不发请求（连失败日志都没有，
    ///   用户看到的就是「一片空白，也不报错」）。
    ///
    /// 每个字段都是**条件替换**：库里存的还是那条已知死规则才换，
    /// 用户改过的、或站点改回来后自己配的规则都不会被踩掉。
    private struct RulesPatch {
        /// 章节列表：库里含这个子串（= 已知失效的旧选择器）时替换
        var chapterListWhenContains: String? = nil
        var chapterList: String? = nil
        /// 列表封面：库里**恰好等于**这个值（= 已知失效）时替换
        var searchCoverWhenEquals: String? = nil
        var searchCover: String? = nil
        /// 详情页封面：库里含这个子串时替换
        var coverWhenContains: String? = nil
        var cover: String? = nil
    }

    /// 发现栏目的一整套规则（列表 / 名称 / 链接 / 栏目地址）
    private struct FindPatch {
        var findUrl: String
        var list: String
        var name: String
        var noteUrl: String
        /// 只有当库里 `ruleFindUrl` 含这个子串时才替换（= 确认是老规则）
        var whenFindUrlContains: String
    }

    private static let table: [Patch] = [
        // 卡拉漫画：MacPlayer 加密播放器 → 三级挑战流
        // 章节页 `player_aaaa.url`（144 hex）→ /play/min/{hex} 拿 token
        // → 带 omo_token + cf_verify 再取 → `img.comic-img[data-src]`
        // 实测：209 张，首图 200 / 295KB
        Patch(host: "kalamanhua.com", flowJSON: kalaFlowJSON),

        // W漫画：`var num = eval("17")` + `var pasd = "…/"`
        // → 图片就是 pasd + i + ".webp"。HTML 里一个 <img src> 都没有。
        // W漫画 发现页：老规则 `ruleFindUrl` 指向 `/new`（时间线页，条目是 `a.timeline-item`、
        // 封面用 CSS background-image，**没有 `<img>`**）→ 按搜索页规则解析必然 0 条。
        // 实测 `/sort?page=N` 是标准卡片列表（`a.book` + `<h3>` 名称 + href 详情），
        // 一页 24 本，翻页正常 → 发现栏目改指 /sort，并用 `||` 兼容搜索页的 `card-content`。
        Patch(host: "wmanhua.com", flowJSON: wmanhuaFlowJSON,
              dropBadBook: "tag.img@data-src",
              find: FindPatch(
                findUrl: "全部::https://www.wmanhua.com/sort?page={{page}}",
                list: "class.card-content||class.book",
                name: "class.cardtitle@text||tag.h3@text",
                noteUrl: "tag.a@href||href",
                whenFindUrlContains: "/new"),
              // 2026-10-29 站点改版：章节与封面两条选择器都失效了（实测）
              //   · `chaper-btn` 全站命中 0 次 → 章节只能靠兜底扫描
              //   · 封面搬进 `div.thumb` 的内联 background-image，页面无任何 <img>
              //     → 规则产出空串 → 封面不发请求、连失败日志都没有
              rules: RulesPatch(
                chapterListWhenContains: "chaper-btn",
                chapterList: "@css:div.chapters a||@css:div.chapter-list a.chaper-btn",
                searchCoverWhenEquals: "tag.img@data-src",
                searchCover: wmanhuaStyleCover,
                coverWhenContains: "img[data-src]",
                cover: wmanhuaStyleCover + "||@css:img[data-src]@data-src")),

        // 瓜子：正文图有独立 class，不配规则会被 8 张「推荐封面」污染
        Patch(host: "guazimanhua.com", book: "tag.img.reading-image@src"),

        // 图库：懒加载在 data-original，去掉 query 后需 Referer（源 header 已配）
        Patch(host: "tuku.cc", book: "tag.img@data-original##\\?.*"),

        // 包子：**不要**做 host 改写。
        // 2026-10-27 实测：章节页的图就在 `https://s1.bzcdn.net/scomic/…`，
        // 改成 `static-tw.baozimh.com` 反而全 404（那个域只放 `/static/` 静态资源）。
        // 旧规则里的 `##https://s\d+\.bzcdn\.net##https://static-tw.baozimh.com`
        // 是**错的**，这里用 dropBadBook 精确清掉，改回直取 src。
        Patch(host: "cnbzmg.com",
              book: "tag.img@src",
              dropBadBook: "static-tw.baozimh.com"),

        // 漫画网：`<div id="pics">` 是空的，由混淆过的 pic-v2.js 填充 →
        // 规则无能为力，交给「正文 0 图 → 内置浏览器渲染」兜底（v184）。
    ]

    /// 卡拉：三级挑战流（与 ContentFlow 文档里的示例一致，字段按实测校正）
    private static let kalaFlowJSON = #"""
    [
      {"input":"chapterHtml",
       "extract":{"hex":"\"url\"\\s*:\\s*\"([0-9a-f]{32,})\""}},
      {"request":{"url":"https://image.kalaimg.top/play/min/{hex}",
                  "headers":{"User-Agent":"{ua}","Referer":"{chapterUrl}"}},
       "extract":{"token":"token\\s*=\\s*['\"]([^'\"]+)['\"]"}},
      {"request":{"url":"https://image.kalaimg.top/play/min/{hex}?cf_verify={token:urlenc}",
                  "headers":{"User-Agent":"{ua}","Referer":"{chapterUrl}"},
                  "cookie":"omo_token={token}"},
       "select":{"regex":"data-src\\s*=\\s*[\"']([^\"']+)[\"']",
                 "base":"https://image.kalaimg.top"}}
    ]
    """#

    /// W漫画 封面（2026-10-29 改版后）：封面不在 `<img>` 里，而是
    /// `<div class="thumb" style="background-image:url('https://image4.wmanhua.com/…/cover.webp')">`
    ///
    /// 所以先用 `@style` 把整个 style 属性取出来，再用 `##` 正则把 URL 抠出来。
    /// `$1` 是 `NSRegularExpression.replaceMatches(withTemplate:)` 的捕获组引用。
    /// ⚠️ 正则里**不能出现字面 `&`**（`splitAndRun` 会把单 `&` 当规则分隔符，
    ///    且不保护 `##` 正则）—— 这条正则只有 `.` `*` `url` `\(` `'`，安全。
    private static let wmanhuaStyleCover = "@css:div.thumb@style##.*url\\('([^']+)'\\).*##$1"

    /// W漫画：脚本变量直接拼图
    private static let wmanhuaFlowJSON = #"""
    [
      {"input":"chapterHtml",
       "extract":{"pasd":"var\\s+pasd\\s*=\\s*[\"']([^\"']+)[\"']",
                  "num":"var\\s+num\\s*=\\s*eval\\(\\s*[\"'](\\d+)[\"']"}},
      {"select":{"template":"{pasd}{i}.webp","count":"{num}"}}
    ]
    """#

    private static func decodeFlow(_ json: String) -> [ContentFlowStep]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([ContentFlowStep].self, from: data)
    }
}
