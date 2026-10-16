import Foundation

/// ──────────────────────────────────────────────────────────────────────────
/// Legado（开源阅读）原生嵌套书源 → 本项目的扁平 `ComicSource`
///
/// ## 为什么必须有这个转换器
/// 图源 JSON 有两套字段结构，**互不兼容**：
///
/// **① 扁平式**（绘漫岛 / 本项目内置的 535 源）
/// ```json
/// { "bookSourceName": "…", "ruleSearchList": "…", "ruleChapterList": "…",
///   "ruleContentUrl": "…", "ruleBookContent": "…" }
/// ```
///
/// **② 嵌套式**（Legado 原生，`yck2026.fun/yuedu/shuyuan/` 与绝大多数
///    GitHub 书源仓库都是这种）
/// ```json
/// { "bookSourceName": "…", "bookSourceType": 2, "searchUrl": "…",
///   "exploreUrl": "…", "header": "{…}",
///   "ruleSearch":   { "bookList": "…", "name": "…", "bookUrl": "…" },
///   "ruleBookInfo": { "name": "…", "intro": "…", "tocUrl": "…" },
///   "ruleToc":      { "chapterList": "…", "chapterName": "…", "chapterUrl": "…" },
///   "ruleContent":  { "content": "…", "nextContentUrl": "…" } }
/// ```
///
/// 我们的 `ComicSource` 只有扁平字段，所以**嵌套式的源导入进来会全是空规则**，
/// 表现为「源加进去了但什么都搜不到」。
/// 实测 `yck2026.fun/yuedu/shuyuan/`（开源阅读书源仓库）里筛选「漫画」有
/// 上百个**活跃维护**的源（最近几天还在更新），是比绘漫岛那边新鲜得多的源池 ——
/// 一个转换器就能把整个生态吃进来。
///
/// ## 映射表
/// | Legado | 本项目 |
/// |---|---|
/// | `bookSourceType`(Int, 2=图片) | `bookSourceType = "漫画"` |
/// | `enabled` | `enable` |
/// | `bookSourceComment` | `sourceRemark` |
/// | `respondTime` | `bookDelayTime` |
/// | `header` | `header`（新增字段，请求时统一注入） |
/// | `searchUrl` | `ruleSearchUrl` |
/// | `exploreUrl` | `ruleFindUrl` |
/// | `ruleSearch.bookList/name/author/kind/lastChapter/coverUrl/bookUrl` | `ruleSearchList/Name/Author/Kind/LastChapter/CoverUrl/NoteUrl` |
/// | `ruleBookInfo.name/author/kind/lastChapter/intro/coverUrl/tocUrl` | `ruleBookName/Author/Kind/LastChapter/Introduce/CoverUrl/ChapterUrl` |
/// | `ruleToc.chapterList/chapterName/chapterUrl/nextTocUrl` | `ruleChapterList/Name/ContentUrl/UrlNext` |
/// | `ruleContent.content/nextContentUrl` | `ruleBookContent/ContentUrlNext` |
/// ──────────────────────────────────────────────────────────────────────────
enum LegadoConverter {

    /// 判断一个 JSON 对象是不是 Legado 嵌套格式
    static func isNested(_ obj: [String: Any]) -> Bool {
        // 有任一嵌套子对象即为嵌套格式
        for k in ["ruleSearch", "ruleBookInfo", "ruleToc", "ruleContent", "ruleExplore"] {
            if obj[k] is [String: Any] { return true }
        }
        return false
    }

    /// 嵌套 → 扁平。返回 nil 表示不像 Legado 源。
    static func convert(_ obj: [String: Any]) -> ComicSource? {
        guard isNested(obj) else { return nil }
        var s = ComicSource()

        func str(_ k: String) -> String? {
            if let v = obj[k] as? String, !v.isEmpty { return v }
            return nil
        }
        func sub(_ k: String, _ f: String) -> String? {
            guard let d = obj[k] as? [String: Any] else { return nil }
            if let v = d[f] as? String, !v.isEmpty { return v }
            return nil
        }

        s.bookSourceUrl = str("bookSourceUrl") ?? ""
        s.bookSourceName = str("bookSourceName") ?? ""
        s.bookSourceGroup = str("bookSourceGroup")
        s.sourceRemark = str("bookSourceComment")
        s.bookDelayTime = str("respondTime")
        s.header = str("header")
        s.httpUserAgent = str("httpUserAgent")
        s.loginUrl = str("loginUrl")
        s.checkUrl = str("checkUrl")

        // bookSourceType：Legado 用 Int（0 文本 / 1 音频 / 2 图片 / 3 文件）
        if let t = obj["bookSourceType"] as? Int {
            s.bookSourceType = (t == 2) ? "漫画" : (t == 0 ? "小说" : (t == 1 ? "音频" : "文件"))
        } else if let t = obj["bookSourceType"] as? String, !t.isEmpty {
            s.bookSourceType = t
        } else {
            s.bookSourceType = "漫画"
        }
        // enabled 优先于 enable
        if let e = obj["enabled"] as? Bool { s.enable = e }
        else if let e = obj["enable"] as? Bool { s.enable = e }
        if let w = obj["weight"] as? Int { s.weight = w }
        if let c = obj["customOrder"] as? Int { s.serialNumber = c }
        if let t = obj["lastUpdateTime"] as? Int64 { s.lastUpdateTime = t }
        else if let t = obj["lastUpdateTime"] as? Int { s.lastUpdateTime = Int64(t) }

        // ── 搜索 ──
        s.ruleSearchUrl = str("searchUrl")
        s.ruleFindUrl = str("exploreUrl")
        s.ruleSearchList = sub("ruleSearch", "bookList")
        s.ruleSearchName = sub("ruleSearch", "name")
        s.ruleSearchAuthor = sub("ruleSearch", "author")
        s.ruleSearchKind = sub("ruleSearch", "kind")
        s.ruleSearchLastChapter = sub("ruleSearch", "lastChapter")
        s.ruleSearchCoverUrl = sub("ruleSearch", "coverUrl")
        s.ruleSearchNoteUrl = sub("ruleSearch", "bookUrl")

        // ── 详情 ──
        s.ruleBookName = sub("ruleBookInfo", "name")
        s.ruleBookAuthor = sub("ruleBookInfo", "author")
        s.ruleBookKind = sub("ruleBookInfo", "kind")
        s.ruleBookLastChapter = sub("ruleBookInfo", "lastChapter")
        s.ruleIntroduce = sub("ruleBookInfo", "intro")
        s.ruleCoverUrl = sub("ruleBookInfo", "coverUrl")
        // ⚠️ `ruleBookInfo.tocUrl` 是「目录所在独立页」的地址，
        //    对应我们的 `ruleChapterUrl`（**不是** `ruleContentUrl`！）
        s.ruleChapterUrl = sub("ruleBookInfo", "tocUrl")

        // ── 目录 ──
        s.ruleChapterList = sub("ruleToc", "chapterList")
        s.ruleChapterName = sub("ruleToc", "chapterName")
        // ⚠️ `ruleToc.chapterUrl` 是**每章链接** → 对应我们的 `ruleContentUrl`
        //    （踩过：绘漫岛那边 `ruleChapterUrl` 是「目录页地址」，
        //     两个格式里同名字段语义不同，不能混）
        s.ruleContentUrl = sub("ruleToc", "chapterUrl")
        s.ruleChapterUrlNext = sub("ruleToc", "nextTocUrl")

        // ── 正文 ──
        s.ruleBookContent = sub("ruleContent", "content")
        s.ruleContentUrlNext = sub("ruleContent", "nextContentUrl")

        guard !s.bookSourceUrl.isEmpty else { return nil }
        if s.bookSourceName.isEmpty { s.bookSourceName = s.bookSourceUrl }
        return s
    }

    /// 把 `header`（JSON 字符串）解析成字典。
    /// 支持两种写法：`{"k":"v"}` 标准 JSON，以及 `k=v\nk2=v2` 宽松格式。
    static func parseHeader(_ raw: String?) -> [String: String] {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return [:] }
        if raw.hasPrefix("{"),
           let d = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            var m: [String: String] = [:]
            for (k, v) in obj { m[k] = (v as? String) ?? String(describing: v) }
            return m
        }
        // 宽松：按行 `k=v` 或 `k: v`
        var m: [String: String] = [:]
        for line in raw.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if let r = t.range(of: "=") {
                m[String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)] =
                    String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if let r = t.range(of: ":") {
                m[String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)] =
                    String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return m
    }
}
