import Foundation

/// 业务数据仓库 —— 对应原版 dao/ 各 DAO 操作
final class ComicRepository {
    static let shared = ComicRepository()

    // MARK: - 图源

    /// ── 源列表内存缓存 ───────────────────────────────────────────────────────
    ///
    /// `allSources()` 原先每次调用都要 `SELECT *` 整表 + 逐行构造 `ComicSource`
    /// （约 45 个字段/行）。书架滚动时它被**每个封面**各调一次
    /// （`CoverImage.load` 反查 Referer；`ShelfCell.prefetchNeighbors` 在循环里再调），
    /// 于是「一屏十几个格子 × 每格 7 个邻居」退化成几千次全表扫描。
    ///
    /// 源表的数据特征决定了这里可以安全缓存：
    ///   · 条目数量级只有几百，且**极少变**（用户手动导入/删除时才动）；
    ///   · 读取是高频、写入是低频 —— 典型的「读多写少」。
    ///
    /// ⚠️ 因此**所有写路径**（`saveSource` / `saveSources` / `deleteSources` /
    ///    `deleteAllSources` / `updateSourceEnable` / 内置导入 …）都必须调用
    ///    `invalidateSourceCache()`。漏掉一处，用户就会看到「改了源但列表没变」。
    private let sourceCacheLock = NSLock()
    private var _sourcesAll: [ComicSource]?
    private var _sourcesEnabled: [ComicSource]?
    /// host → 源（同域多源时保留排序在前的那条，与旧的 `first(where:)` 语义一致）
    private var _sourceByHost: [String: ComicSource]?

    /// 源表被写入后必须调用（见上方说明）。清空缓存比精确失效更安全。
    func invalidateSourceCache() {
        sourceCacheLock.lock()
        _sourcesAll = nil
        _sourcesEnabled = nil
        _sourceByHost = nil
        sourceCacheLock.unlock()
        // 通知所有在屏的列表刷新（导入 / 删除 / 启停都会走到这里）
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .hmdSourcesChanged, object: nil)
        }
    }

    func allSources(includeDisabled: Bool = true) -> [ComicSource] {
        sourceCacheLock.lock()
        if let hit = includeDisabled ? _sourcesAll : _sourcesEnabled {
            sourceCacheLock.unlock()
            return hit
        }
        sourceCacheLock.unlock()

        let rows = Database.shared.query(includeDisabled
            ? "SELECT * FROM COMIC_SOURCE_BEAN ORDER BY WEIGHT DESC, SERIAL_NUMBER"
            : "SELECT * FROM COMIC_SOURCE_BEAN WHERE ENABLE=1 ORDER BY WEIGHT DESC, SERIAL_NUMBER")
        let list = rows.compactMap(rowToSource)

        sourceCacheLock.lock()
        // 两份列表共享同一批对象（`ComicSource` 是值类型，拷贝成本只是引用计数）
        if _sourcesAll == nil { _sourcesAll = list }
        if includeDisabled {
            // 全量列表同时派生「仅启用」视图，避免二次全表扫描
            _sourcesEnabled = list.filter { $0.isEnabled }
            var byHost: [String: ComicSource] = [:]
            for s in list where byHost[s.host()] == nil { byHost[s.host()] = s }
            _sourceByHost = byHost
            let all = _sourcesAll ?? list
            sourceCacheLock.unlock()
            return all
        } else {
            _sourcesEnabled = list
            sourceCacheLock.unlock()
            return list
        }
    }

    /// 按域名反查图源（封面防盗链 Referer / UA 补齐用）。
    ///
    /// **O(1)**（哈希索引），替代原先「`allSources()` 全表 + `first(where:)` 线性扫」。
    /// 这是书架滚动路径上最热的调用 —— 每个可见封面两次
    /// （`CoverImage.load` 一次、`prefetchNeighbors` 每个邻居一次）。
    func source(forHost host: String) -> ComicSource? {
        guard !host.isEmpty else { return nil }
        sourceCacheLock.lock()
        if let idx = _sourceByHost {
            let hit = idx[host]
            sourceCacheLock.unlock()
            return hit
        }
        sourceCacheLock.unlock()
        // 未建索引（例如只请求过 enabled 列表）→ 触发一次全量构建
        _ = allSources(includeDisabled: true)
        sourceCacheLock.lock()
        let hit = _sourceByHost?[host]
        sourceCacheLock.unlock()
        return hit
    }

    func source(url: String) -> ComicSource? {
        Database.shared.query("SELECT * FROM COMIC_SOURCE_BEAN WHERE BOOK_SOURCE_URL=?", [url]).first.flatMap(rowToSource)
    }

    /// `ruleContentFlow` 数组 ↔ 库里的 JSON 字符串。
    /// ⚠️ 必须成对落库/读回：只加字段不加这一层，导入照样「成功」而 flow 恒为 nil。
    private static func encodeContentFlow(_ flow: [ContentFlowStep]?) -> String {
        guard let flow, !flow.isEmpty else { return "" }
        guard let d = try? JSONEncoder().encode(flow) else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    private static func decodeContentFlow(_ json: String?) -> [ContentFlowStep]? {
        guard let json, !json.isEmpty,
              let d = json.data(using: .utf8),
              let flow = try? JSONDecoder().decode([ContentFlowStep].self, from: d),
              !flow.isEmpty else { return nil }
        return flow
    }

    func saveSource(_ s: ComicSource) {
        // 源被（重新）保存 = 「复活」：撤掉删除墓碑，否则下次合并又会把它判成「已删除」（§8.2 阶段 B）
        TombstoneStore.clear(s.bookSourceUrl, kind: .source)
        Database.shared.exec("""
            INSERT OR REPLACE INTO COMIC_SOURCE_BEAN (
            BOOK_SOURCE_URL, BOOK_SOURCE_TYPE, BOOK_SINGLE_THREAD, BOOK_DELAY_TIME, BOOK_SOURCE_NAME,
            BOOK_SOURCE_GROUP, CHECK_URL, LAST_UPDATE_TIME, SERIAL_NUMBER, WEIGHT, ENABLE, ENABLED_EXPLORE,
            RULE_FIND_URL, RULE_SEARCH_URL, RULE_SEARCH_URL_NEXT, RULE_SEARCH_LIST, RULE_SEARCH_NAME,
            RULE_SEARCH_AUTHOR, RULE_SEARCH_KIND, RULE_SEARCH_LAST_CHAPTER, RULE_SEARCH_COVER_URL,
            RULE_SEARCH_COVER_DECODER, RULE_SEARCH_NOTE_URL, RULE_BOOK_NAME, RULE_BOOK_AUTHOR,
            RULE_CHAPTER_ID, RULE_CHAPTER_URL, RULE_CHAPTER_URL_NEXT, RULE_CHAPTER_PARENT_ID,
            RULE_CHAPTER_PARENT_NAME, RULE_COVER_URL, RULE_COVER_DECODER, RULE_INTRODUCE,
            RULE_CHAPTER_LIST, RULE_CHAPTER_NAME, RULE_CONTENT_URL, RULE_CONTENT_URL_NEXT,
            RULE_BOOK_CONTENT, RULE_BOOK_CONTENT_DECODER, HTTP_USER_AGENT, RULE_BOOK_KIND,
            RULE_BOOK_LAST_CHAPTER, RULE_BOOK_URL_PATTERN, LOGIN_URL, LOGIN_URL_RESULT, SOURCE_REMARK,
            HEADER, RULE_CONTENT_FLOW,
            RULE_CHAPTER_API, RULE_CHAPTER_API_LIST, RULE_CHAPTER_API_URL)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            s.bookSourceUrl, s.bookSourceType ?? "漫画", s.bookSingleThread ?? "", s.bookDelayTime ?? "",
            s.bookSourceName, s.bookSourceGroup ?? "", s.checkUrl ?? "", s.lastUpdateTime ?? 0,
            s.serialNumber ?? 0, s.weight ?? 0, s.isEnabled ? 1 : 0, (s.enabledExplore ?? true) ? 1 : 0,
            s.ruleFindUrl ?? "", s.ruleSearchUrl ?? "", s.ruleSearchUrlNext ?? "", s.ruleSearchList ?? "",
            s.ruleSearchName ?? "", s.ruleSearchAuthor ?? "", s.ruleSearchKind ?? "", s.ruleSearchLastChapter ?? "",
            s.ruleSearchCoverUrl ?? "", s.ruleSearchCoverDecoder ?? "", s.ruleSearchNoteUrl ?? "",
            s.ruleBookName ?? "", s.ruleBookAuthor ?? "", s.ruleChapterId ?? "", s.ruleChapterUrl ?? "",
            s.ruleChapterUrlNext ?? "", s.ruleChapterParentId ?? "", s.ruleChapterParentName ?? "",
            s.ruleCoverUrl ?? "", s.ruleCoverDecoder ?? "", s.ruleIntroduce ?? "", s.ruleChapterList ?? "",
            s.ruleChapterName ?? "", s.ruleContentUrl ?? "", s.ruleContentUrlNext ?? "",
            s.ruleBookContent ?? "", s.ruleBookContentDecoder ?? "", s.httpUserAgent ?? "",
            s.ruleBookKind ?? "", s.ruleBookLastChapter ?? "", s.ruleBookUrlPattern ?? "",
            s.loginUrl ?? "", s.loginUrlResult ?? "", s.sourceRemark ?? "",
            // ⚠️ `header` 必须落库：很多源的 Referer/UA 靠它带，丢了就 403/空页。
            s.header ?? "",
            // ⚠️ `ruleContentFlow` 同样必须落库（JSON 数组）：不落库就等于导入失败，
            //    卡拉这类多级挑战流站点正文会静默返回空。
            Self.encodeContentFlow(s.ruleContentFlow),
            // ⚠️ 章节 API 三件套同样必须落库 —— 不落库等于没配（W漫画 章节会停在 24 章）。
            s.ruleChapterApi ?? "", s.ruleChapterApiList ?? "", s.ruleChapterApiUrl ?? "")
        invalidateSourceCache()
    }
    func saveSources(_ list: [ComicSource]) {
        list.forEach(saveSource)   // 每条的 saveSource 都会失效缓存；这里再兜一次
        invalidateSourceCache()
    }

    func deleteSources(urls: [String]) {
        for u in urls {
            Database.shared.exec("DELETE FROM COMIC_SOURCE_BEAN WHERE BOOK_SOURCE_URL=?", u)
            // 记删除墓碑（§8.2 阶段 B）：否则双向合并时这条源会被远端旧备份「复活」
            TombstoneStore.markDeleted(u, kind: .source)
        }
        invalidateSourceCache()
    }

    func setEnable(url: String, enable: Bool) {
        Database.shared.exec("UPDATE COMIC_SOURCE_BEAN SET ENABLE=? WHERE BOOK_SOURCE_URL=?", enable ? 1 : 0, url)
        invalidateSourceCache()
    }

    /// 批量启用/停用（多选操作条用）。
    /// 一次事务搞定 —— 逐个调 `setEnable` 会反复 `invalidateSourceCache()` 并重建缓存。
    func setEnable(urls: [String], enable: Bool) {
        guard !urls.isEmpty else { return }
        for u in urls {
            Database.shared.exec("UPDATE COMIC_SOURCE_BEAN SET ENABLE=? WHERE BOOK_SOURCE_URL=?",
                                 enable ? 1 : 0, u)
        }
        invalidateSourceCache()
    }

    /// 「发现」开关（对齐 Legado 的 `enableExplore`）
    func setExploreEnabled(urls: [String], enable: Bool) {
        guard !urls.isEmpty else { return }
        for u in urls {
            Database.shared.exec("UPDATE COMIC_SOURCE_BEAN SET ENABLED_EXPLORE=? WHERE BOOK_SOURCE_URL=?",
                                 enable ? 1 : 0, u)
        }
        invalidateSourceCache()
    }

    /// 手动排序：直接写 WEIGHT
    func setSourceWeight(url: String, weight: Int) {
        Database.shared.exec("UPDATE COMIC_SOURCE_BEAN SET WEIGHT=? WHERE BOOK_SOURCE_URL=?", weight, url)
        invalidateSourceCache()
    }

    /// 置顶 / 置底（对齐 Legado 的 `toTop` / `toBottom`）。
    ///
    /// 列表的排序是 `ORDER BY WEIGHT DESC, SERIAL_NUMBER`（见 `allSources`），
    /// 所以改 WEIGHT 就能把源顶到最前 / 沉到最后，不用重排整张表。
    func moveSources(urls: [String], toTop: Bool) {
        guard !urls.isEmpty else { return }
        let sql = toTop
            ? "UPDATE COMIC_SOURCE_BEAN SET WEIGHT = (SELECT IFNULL(MAX(WEIGHT),0)+1 FROM COMIC_SOURCE_BEAN) WHERE BOOK_SOURCE_URL=?"
            : "UPDATE COMIC_SOURCE_BEAN SET WEIGHT = (SELECT IFNULL(MIN(WEIGHT),0)-1 FROM COMIC_SOURCE_BEAN) WHERE BOOK_SOURCE_URL=?"
        for u in urls { Database.shared.exec(sql, u) }
        invalidateSourceCache()
    }

    /// 改图源分组（对齐 Legado 的「加入分组 / 移出分组」）。
    /// 分组是逗号分隔的多值字段，与 Legado 一致（`bookSourceGroup`）。
    func setSourceGroups(url: String, groups: [String]) {
        let clean = groups.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        let uniq = clean.filter { seen.insert($0).inserted }
        Database.shared.exec("UPDATE COMIC_SOURCE_BEAN SET BOOK_SOURCE_GROUP=? WHERE BOOK_SOURCE_URL=?",
                             uniq.joined(separator: ","), url)
        invalidateSourceCache()
    }

    private func rowToSource(_ row: [String: Any]) -> ComicSource? {
        guard let url = row["BOOK_SOURCE_URL"] as? String, !url.isEmpty else { return nil }
        var s = ComicSource()
        s.bookSourceUrl = url
        s.bookSourceType = row["BOOK_SOURCE_TYPE"] as? String
        s.bookSingleThread = row["BOOK_SINGLE_THREAD"] as? String
        s.bookDelayTime = row["BOOK_DELAY_TIME"] as? String
        s.bookSourceName = row["BOOK_SOURCE_NAME"] as? String ?? ""
        s.bookSourceGroup = row["BOOK_SOURCE_GROUP"] as? String
        s.enabledExplore = ((row["ENABLED_EXPLORE"] as? Int64) ?? 1) != 0
        s.checkUrl = row["CHECK_URL"] as? String
        s.lastUpdateTime = row["LAST_UPDATE_TIME"] as? Int64
        s.serialNumber = Int(truncatingIfNeeded: row["SERIAL_NUMBER"] as? Int64 ?? 0)
        s.weight = Int(truncatingIfNeeded: row["WEIGHT"] as? Int64 ?? 0)
        s.enable = (row["ENABLE"] as? Int64 ?? 1) == 1
        s.ruleFindUrl = row["RULE_FIND_URL"] as? String
        s.ruleSearchUrl = row["RULE_SEARCH_URL"] as? String
        s.ruleSearchUrlNext = row["RULE_SEARCH_URL_NEXT"] as? String
        s.ruleSearchList = row["RULE_SEARCH_LIST"] as? String
        s.ruleSearchName = row["RULE_SEARCH_NAME"] as? String
        s.ruleSearchAuthor = row["RULE_SEARCH_AUTHOR"] as? String
        s.ruleSearchKind = row["RULE_SEARCH_KIND"] as? String
        s.ruleSearchLastChapter = row["RULE_SEARCH_LAST_CHAPTER"] as? String
        s.ruleSearchCoverUrl = row["RULE_SEARCH_COVER_URL"] as? String
        s.ruleSearchCoverDecoder = row["RULE_SEARCH_COVER_DECODER"] as? String
        s.ruleSearchNoteUrl = row["RULE_SEARCH_NOTE_URL"] as? String
        s.ruleBookName = row["RULE_BOOK_NAME"] as? String
        s.ruleBookAuthor = row["RULE_BOOK_AUTHOR"] as? String
        s.ruleChapterId = row["RULE_CHAPTER_ID"] as? String
        s.ruleChapterUrl = row["RULE_CHAPTER_URL"] as? String
        s.ruleChapterUrlNext = row["RULE_CHAPTER_URL_NEXT"] as? String
        s.ruleChapterParentId = row["RULE_CHAPTER_PARENT_ID"] as? String
        s.ruleChapterParentName = row["RULE_CHAPTER_PARENT_NAME"] as? String
        s.ruleCoverUrl = row["RULE_COVER_URL"] as? String
        s.ruleCoverDecoder = row["RULE_COVER_DECODER"] as? String
        s.ruleIntroduce = row["RULE_INTRODUCE"] as? String
        s.ruleChapterList = row["RULE_CHAPTER_LIST"] as? String
        s.ruleChapterName = row["RULE_CHAPTER_NAME"] as? String
        s.ruleChapterApi = row["RULE_CHAPTER_API"] as? String
        s.ruleChapterApiList = row["RULE_CHAPTER_API_LIST"] as? String
        s.ruleChapterApiUrl = row["RULE_CHAPTER_API_URL"] as? String
        s.ruleContentUrl = row["RULE_CONTENT_URL"] as? String
        s.ruleContentUrlNext = row["RULE_CONTENT_URL_NEXT"] as? String
        s.ruleBookContent = row["RULE_BOOK_CONTENT"] as? String
        s.ruleBookContentDecoder = row["RULE_BOOK_CONTENT_DECODER"] as? String
        s.httpUserAgent = row["HTTP_USER_AGENT"] as? String
        s.ruleBookKind = row["RULE_BOOK_KIND"] as? String
        s.ruleBookLastChapter = row["RULE_BOOK_LAST_CHAPTER"] as? String
        s.ruleBookUrlPattern = row["RULE_BOOK_URL_PATTERN"] as? String
        s.loginUrl = row["LOGIN_URL"] as? String
        s.loginUrlResult = row["LOGIN_URL_RESULT"] as? String
        s.sourceRemark = row["SOURCE_REMARK"] as? String
        s.header = row["HEADER"] as? String
        s.ruleContentFlow = Self.decodeContentFlow(row["RULE_CONTENT_FLOW"] as? String)
        return s
    }

    // MARK: - 书架

    // `ShelfItem` 已迁至 `Model/ShelfItem.swift`（ARCHITECTURE §7.2 · 批次 3）。

    /// 数 `NEW_CHAPTERS` 里存了几章（该列存的是 JSON 数组）
    private static func countNewChapters(_ json: String?) -> Int {
        guard let json, !json.isEmpty, let d = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: String]] else { return 0 }
        return arr.count
    }

    func shelfList(groupId: Int64? = nil) -> [ShelfItem] {
        let sql = groupId == nil
            ? "SELECT * FROM COMIC_SHELF_BEAN ORDER BY FINAL_DATE DESC"
            : "SELECT * FROM COMIC_SHELF_BEAN WHERE GROUP_ID=\(groupId!) ORDER BY FINAL_DATE DESC"
        return Database.shared.query(sql).map { row in
            ShelfItem(
                noteUrl: row["NOTE_URL"] as? String ?? "",
                name: row["NAME"] as? String ?? "",
                origin: row["ORIGIN"] as? String ?? "",
                coverUrl: row["COVER_URL"] as? String ?? "",
                author: row["AUTHOR"] as? String ?? "",
                kind: row["KIND"] as? String ?? "",
                lastChapterName: row["LAST_CHAPTER_NAME"] as? String ?? "",
                durChapterName: row["DUR_CHAPTER_NAME"] as? String ?? "",
                durChapterUrl: row["DUR_CHAPTER_URL"] as? String ?? "",
                durChapterPage: Int(truncatingIfNeeded: row["DUR_CHAPTER_PAGE"] as? Int64 ?? 0),
                hasUpdate: (row["HAS_UPDATE"] as? Int64 ?? 0) == 1,
                newChapterCount: Self.countNewChapters(row["NEW_CHAPTERS"] as? String),
                groupId: row["GROUP_ID"] as? Int64 ?? 0,
                variable: row["VARIABLE"] as? String ?? "")
        }
    }

    func addToShelf(info: ComicInfo, groupId: Int64 = 0) {
        // 加入书架 = 「复活」：撤掉删除墓碑（§8.2 阶段 B）
        TombstoneStore.clear(info.noteUrl, kind: .shelf)
        // ⚠️ 不能直接 INSERT OR REPLACE —— 那会把已有的阅读进度（DUR_CHAPTER_*）重置成 0。
        // 已经读完一半的漫画再点一次「加入书架」，进度就没了。
        // 改用 INSERT ... ON CONFLICT DO UPDATE，只更新元信息，保留进度。
        Database.shared.exec("""
            INSERT INTO COMIC_SHELF_BEAN
            (NOTE_URL, SERIAL_NUMBER, FINAL_DATE, HAS_UPDATE, DUR_CHAPTER_URL, DUR_CHAPTER_NAME,
             DUR_CHAPTER_PAGE, LAST_CHAPTER_NAME, ALLOW_UPDATE, GROUP_ID, ORIGIN, NAME, COVER_URL, AUTHOR, KIND)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(NOTE_URL) DO UPDATE SET
              LAST_CHAPTER_NAME = excluded.LAST_CHAPTER_NAME,
              NAME = excluded.NAME,
              COVER_URL = excluded.COVER_URL,
              AUTHOR = excluded.AUTHOR,
              KIND = excluded.KIND,
              ORIGIN = excluded.ORIGIN
            """,
            info.noteUrl, 0, Int64(Date().timeIntervalSince1970 * 1000), 0,
            info.chapters.first?.url ?? "", "", 0, info.chapters.last?.name ?? "", 1, groupId,
            info.origin, info.name, info.coverUrl, info.author, info.kind)
        // 章节列表一并落库 —— 之后点书架可以零网络直接开阅读器
        saveChapters(noteUrl: info.noteUrl, chapters: info.chapters)
    }

    func inShelf(noteUrl: String) -> Bool {
        !Database.shared.query("SELECT NOTE_URL FROM COMIC_SHELF_BEAN WHERE NOTE_URL=?", [noteUrl]).isEmpty
    }

    func removeFromShelf(noteUrl: String) {
        Database.shared.exec("DELETE FROM COMIC_SHELF_BEAN WHERE NOTE_URL=?", noteUrl)
        // 记删除墓碑（§8.2 阶段 B）：防止已移出书架的书被远端旧备份「复活」
        TombstoneStore.markDeleted(noteUrl, kind: .shelf)
    }

    /// 保存阅读进度。
    ///
    /// 🔴 以前只有一条 `UPDATE COMIC_SHELF_BEAN …` —— 对**没加入书架**的书
    ///    （搜索页/详情页直达阅读）影响 **0 行**，进度**静默丢失**，
    ///    用户再打开发现从第 0 页开始，表现就是「进度没保存」。
    ///    现在：① 写**独立的** `COMIC_PROGRESS` 表（权威来源，与书架解耦）
    ///          ② 顺带更新书架行（书架列表直接读 `DUR_CHAPTER_*`，不更新就显示旧进度）
    func updateProgress(noteUrl: String, chapterUrl: String, chapterName: String, page: Int,
                        info: ComicInfo? = nil) {
        Database.shared.exec("""
            INSERT INTO COMIC_PROGRESS
            (NOTE_URL, ORIGIN, NAME, COVER_URL, AUTHOR, KIND, CHAPTER_URL, CHAPTER_NAME, PAGE, UPDATED)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(NOTE_URL) DO UPDATE SET
              CHAPTER_URL = excluded.CHAPTER_URL,
              CHAPTER_NAME = excluded.CHAPTER_NAME,
              PAGE = excluded.PAGE,
              UPDATED = excluded.UPDATED
            """,
            noteUrl, info?.origin ?? "", info?.name ?? "", info?.coverUrl ?? "",
            info?.author ?? "", info?.kind ?? "", chapterUrl, chapterName, page,
            Int64(Date().timeIntervalSince1970 * 1000))
        // 书架行：只更新进度三列，**不动**用户已有的分组/封面/自定义字段
        Database.shared.exec("""
            UPDATE COMIC_SHELF_BEAN SET DUR_CHAPTER_URL=?, DUR_CHAPTER_NAME=?, DUR_CHAPTER_PAGE=?
            WHERE NOTE_URL=?
            """, chapterUrl, chapterName, page, noteUrl)
    }

    func clearUpdateFlag(noteUrl: String) {
        Database.shared.exec("UPDATE COMIC_SHELF_BEAN SET HAS_UPDATE=0 WHERE NOTE_URL=?", noteUrl)
    }

    // MARK: - 追更（follow_updates）

    /// 记录追更结果：新增章节 + 最新章节名 + 刷新时间。
    /// 存 JSON 而不只存数量 —— 详情页可以直接列出「新增的那几章」。
    func setUpdate(noteUrl: String, newChapters: [ComicInfo.Chapter], latestName: String) {
        guard !newChapters.isEmpty else { return }
        let arr: [[String: String]] = newChapters.map { ["n": $0.name, "u": $0.url, "g": $0.group] }
        guard let d = try? JSONSerialization.data(withJSONObject: arr),
              let json = String(data: d, encoding: .utf8) else { return }
        Database.shared.exec("""
            UPDATE COMIC_SHELF_BEAN SET HAS_UPDATE=1, NEW_CHAPTERS=?, LAST_CHAPTER_NAME=?,
                   FINAL_REFRESH_DATA=? WHERE NOTE_URL=?
            """, json, latestName, Int64(Date().timeIntervalSince1970 * 1000), noteUrl)
    }

    /// 清掉更新标记（没新增章节时调用，覆盖「站点删章 / 改章节 URL」的边界情况）
    func clearUpdate(noteUrl: String) {
        Database.shared.exec("UPDATE COMIC_SHELF_BEAN SET HAS_UPDATE=0, NEW_CHAPTERS='' WHERE NOTE_URL=?",
                             noteUrl)
    }

    /// 读「新增的章节」（追更列表直接用它，不用再联网）
    func newChapters(noteUrl: String) -> [ComicInfo.Chapter] {
        let rows = Database.shared.query(
            "SELECT NEW_CHAPTERS FROM COMIC_SHELF_BEAN WHERE NOTE_URL=?", [noteUrl])
        guard let json = rows.first?["NEW_CHAPTERS"] as? String, !json.isEmpty,
              let d = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: String]] else { return [] }
        return arr.map { ComicInfo.Chapter(name: $0["n"] ?? "", url: $0["u"] ?? "", group: $0["g"] ?? "") }
    }

    /// 一键全部标为已读（书架几十本时逐个点开太累）
    func markAllRead() {
        Database.shared.exec("UPDATE COMIC_SHELF_BEAN SET HAS_UPDATE=0, NEW_CHAPTERS='' WHERE HAS_UPDATE=1")
    }

    /// 书架里有更新的本数
    func updateCount() -> Int {
        let rows = Database.shared.query("SELECT COUNT(*) AS C FROM COMIC_SHELF_BEAN WHERE HAS_UPDATE=1")
        return Int(rows.first?["C"] as? Int64 ?? 0)
    }

    // MARK: - 章节列表本地化（点书架零网络直开的关键）

    /// 把抓到的章节列表落库。之后点书架可以直接用它开阅读器，不必再联网。
    func saveChapters(noteUrl: String, chapters: [ComicInfo.Chapter]) {
        guard !chapters.isEmpty else { return }
        let arr: [[String: String]] = chapters.map { ["n": $0.name, "u": $0.url, "g": $0.group] }
        guard let d = try? JSONSerialization.data(withJSONObject: arr),
              let json = String(data: d, encoding: .utf8) else { return }
        Database.shared.exec("""
            UPDATE COMIC_SHELF_BEAN SET CHAPTERS_JSON=?, CHAPTERS_CACHE_TIME=?, CHAPTER_LIST_SIZE=?
            WHERE NOTE_URL=?
            """, json, Int64(Date().timeIntervalSince1970 * 1000), chapters.count, noteUrl)
    }

    /// 章节列表的**新鲜期**：超过这个时长，界面侧会触发一次后台静默刷新。
    ///
    /// ⚠️ 这只是「多久刷新一次」的节流，**不是「多久后就不可用」**。
    ///    旧实现把两者混为一谈（`loadChapters` 默认 maxAge=6h，超时直接返回 nil），
    ///    结果：用户隔一晚再点书架，本地明明有完整章节列表，却因为「超过 6 小时」
    ///    被判为不可用 → 走联网慢路径重新抓整本详情（含分页探测，慢站十几秒）。
    ///    用户看到的就是「每次打开都要重新抓一遍，特别慢」。
    static let chapterCacheFreshness: TimeInterval = 7 * 24 * 3600

    /// 读回本地章节列表。
    ///
    /// - Parameter maxAge: 超过该时长视为「陈旧」。**默认 0 = 永不过期**，即只要库里有就返回。
    ///   陈旧与否由调用方结合 `chaptersAge(noteUrl:)` 决定是否后台刷新，
    ///   而不是靠「读不到数据」来表达 —— 目录数据「有旧的总比没有强」。
    /// - Parameter allowStale: 兼容旧调用（显式传 maxAge 时生效）。
    func loadChapters(noteUrl: String, maxAge: TimeInterval = 0) -> [ComicInfo.Chapter]? {
        let rows = Database.shared.query(
            "SELECT CHAPTERS_JSON, CHAPTERS_CACHE_TIME FROM COMIC_SHELF_BEAN WHERE NOTE_URL=?", [noteUrl])
        guard let row = rows.first,
              let json = row["CHAPTERS_JSON"] as? String, !json.isEmpty,
              let d = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: String]],
              !arr.isEmpty else { return nil }
        // 过期检查：只有调用方**显式要求**maxAge > 0 时才做过期过滤。
        // 默认 0 → 不做任何过期判定（旧行为是默认 6 小时，正是「重新抓取」的元凶）。
        let t = row["CHAPTERS_CACHE_TIME"] as? Int64 ?? 0
        if maxAge > 0, t > 0, Date().timeIntervalSince1970 - Double(t) / 1000 > maxAge {
            return nil
        }
        // 🔴 读回来必须**再去重一次** —— `ComicInfo.Chapter.id == url`，
        //    而 SwiftUI 的 `List` 要求 id 唯一：一旦有重复，**重复行会被静默丢掉**
        //    （用户看到的就是「章节显示不全」，而且完全没有报错）。
        //    写入侧虽然已去过重，但缓存/数据库可能来自旧版本或并发写入，
        //    这里做一道防御，成本 O(n)。（由智能体「界面」「详情」发现同类隐患）
        var seen = Set<String>()
        return arr.map { ComicInfo.Chapter(name: $0["n"] ?? "", url: $0["u"] ?? "", group: $0["g"] ?? "") }
                  .filter { !$0.url.isEmpty && seen.insert($0.url).inserted }
    }

    /// 本地章节缓存已存在多久（秒）。0 表示没有缓存。
    /// 用于决定「要不要在后台静默刷新」——刚打开就联网会让用户以为又在抓章节。
    func chaptersAge(noteUrl: String) -> TimeInterval {
        let rows = Database.shared.query(
            "SELECT CHAPTERS_CACHE_TIME FROM COMIC_SHELF_BEAN WHERE NOTE_URL=?", [noteUrl])
        guard let t = rows.first?["CHAPTERS_CACHE_TIME"] as? Int64, t > 0 else { return .greatestFiniteMagnitude }
        return Date().timeIntervalSince1970 - Double(t) / 1000
    }

    /// 阅读进度（用于续读定位）。
    ///
    /// 🔴 先查**独立进度表**（`COMIC_PROGRESS`，对未入书架的书也有效），
    ///    查不到再回退书架行（兼容老数据 —— 升级前只写过书架表）。
    func progress(noteUrl: String) -> (chapterUrl: String, chapterName: String, page: Int)? {
        let rows = Database.shared.query(
            "SELECT CHAPTER_URL, CHAPTER_NAME, PAGE FROM COMIC_PROGRESS WHERE NOTE_URL=?",
            [noteUrl])
        if let row = rows.first {
            return (row["CHAPTER_URL"] as? String ?? "",
                    row["CHAPTER_NAME"] as? String ?? "",
                    Int(truncatingIfNeeded: row["PAGE"] as? Int64 ?? 0))
        }
        let legacy = Database.shared.query(
            "SELECT DUR_CHAPTER_URL, DUR_CHAPTER_NAME, DUR_CHAPTER_PAGE FROM COMIC_SHELF_BEAN WHERE NOTE_URL=?",
            [noteUrl])
        guard let row = legacy.first else { return nil }
        return (row["DUR_CHAPTER_URL"] as? String ?? "",
                row["DUR_CHAPTER_NAME"] as? String ?? "",
                Int(truncatingIfNeeded: row["DUR_CHAPTER_PAGE"] as? Int64 ?? 0))
    }

    // MARK: - 历史

    func addHistory(info: ComicInfo) {
        Database.shared.exec("""
            INSERT OR REPLACE INTO HISTORY_COMIC_BEAN
            (NOTE_URL, NAME, AUTHOR, COVER_URL, KIND, DESCRIBE, LAST_CHAPTER, CHAPTER_URL, ORIGIN, UP_TIME)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            """,
            info.noteUrl, info.name, info.author, info.coverUrl, info.kind, info.introduce,
            info.chapters.last?.name ?? "", info.chapters.first?.url ?? "", info.origin,
            Int64(Date().timeIntervalSince1970 * 1000))
    }

    func historyList() -> [(noteUrl: String, name: String, coverUrl: String, origin: String, upTime: Int64)] {
        Database.shared.query("SELECT * FROM HISTORY_COMIC_BEAN ORDER BY UP_TIME DESC LIMIT 200").map {
            ($0["NOTE_URL"] as? String ?? "", $0["NAME"] as? String ?? "",
             $0["COVER_URL"] as? String ?? "", $0["ORIGIN"] as? String ?? "",
             $0["UP_TIME"] as? Int64 ?? 0)
        }
    }

    // MARK: - 阅读统计（供账号页展示）

    /// 书架里的漫画数
    func shelfCount() -> Int {
        (Database.shared.query("SELECT COUNT(*) AS c FROM COMIC_SHELF_BEAN").first?["c"] as? Int64).map(Int.init) ?? 0
    }

    /// 已读章节数：用「有阅读进度的书架条目」的章节总数近似
    /// （章节表里 DUR_CHAPTER_URL 非空 = 这本书拉过目录；再叠加进度章节计数）
    func readChapterCount() -> Int {
        // 每本在书架且已读过（DUR_CHAPTER_URL 非空）的书，贡献其已缓存章节数
        let books = Database.shared.query(
            "SELECT NOTE_URL FROM COMIC_SHELF_BEAN WHERE DUR_CHAPTER_URL IS NOT NULL AND DUR_CHAPTER_URL != ''")
        var total = 0
        var seen = Set<String>()
        for b in books {
            guard let note = b["NOTE_URL"] as? String else { continue }
            let rows = Database.shared.query(
                "SELECT DUR_CHAPTER_URL FROM CHAPTER_LIST_BEAN WHERE NOTE_URL = ?", [note])
            for r in rows {
                if let u = r["DUR_CHAPTER_URL"] as? String, !u.isEmpty, seen.insert(u).inserted {
                    total += 1
                }
            }
        }
        return total
    }

    /// 累计阅读时长（分钟）估算：按「已读章节数 × 平均 3 分钟/话」。
    /// ⚠️ 没有逐次会话计时，所以这是估算值；想精确需要在 ReaderView 里累计前台时长。
    func totalReadMinutes() -> Int { readChapterCount() * 3 }

    // MARK: - 分组

    func groups() -> [(id: Int64, name: String)] {
        Database.shared.query("SELECT * FROM COMIC_SHELF_GROUP_BEAN ORDER BY GROUP_SORT").map {
            ($0["_ID"] as? Int64 ?? 0, $0["GROUP_NAME"] as? String ?? "未分组")
        }
    }

    /// 每个分组里的漫画数（分组管理页显示「N 本」用）。
    /// 一次 `GROUP BY` 查完，不要每行单独 count（分组多时会卡）。
    func groupCounts() -> [Int64: Int] {
        var out: [Int64: Int] = [:]
        for row in Database.shared.query(
            "SELECT GROUP_ID, COUNT(*) AS C FROM COMIC_SHELF_BEAN GROUP BY GROUP_ID") {
            let gid = row["GROUP_ID"] as? Int64 ?? 0
            let c: Int
            if let v = row["C"] as? Int64 { c = Int(v) }
            else if let v = row["C"] as? Int { c = v }
            else { c = 0 }
            out[gid] = c
        }
        return out
    }

    func createGroup(name: String) -> Int64 {
        // ⚠️ 必须回读**真实自增主键**。
        //    原实现返回的是按时间戳自己算出来的一个「像 id 的数」，
        //    而 `_ID` 是 `INTEGER PRIMARY KEY AUTOINCREMENT`（INSERT 里没写 `_ID`）——
        //    两者**永远对不上** → `moveToGroup(noteUrl:groupId:)` 写进 `GROUP_ID` 的值
        //    与 `groups()` 返回的真实 `_ID` 不一致 → **分组过滤永远查不到书**，
        //    表现为「新建分组、把书移进去，书还是显示未分组」。
        return Database.shared.insertReturningID(
            "INSERT INTO COMIC_SHELF_GROUP_BEAN (GROUP_NAME, GROUP_NUMBER, GROUP_SORT, GROUP_VIEW, ENABLE) VALUES (?,?,?,?,?)",
            name, 0, Int32(groups().count), 0, 1)
    }

    func moveToGroup(noteUrl: String, groupId: Int64) {
        Database.shared.exec("UPDATE COMIC_SHELF_BEAN SET GROUP_ID=? WHERE NOTE_URL=?", groupId, noteUrl)
    }

    /// 删除分组（2026-10-19）。
    ///
    /// ⚠️ **只删分组、不删漫画** —— 用户点「删除分组」的预期是「这个分类不要了」，
    ///    不是「把里面的书一起删掉」。所以先把组里的书**移回「未分组」**
    ///    （`GROUP_ID=0`），再删分组行。
    ///
    /// - Returns: 被移到「未分组」的漫画数（用于给用户看提示）
    @discardableResult
    func deleteGroup(id: Int64) -> Int {
        let rows = Database.shared.query(
            "SELECT COUNT(*) AS C FROM COMIC_SHELF_BEAN WHERE GROUP_ID=?", [id])
        let moved: Int
        if let v = rows.first?["C"] as? Int64 { moved = Int(v) }
        else if let v = rows.first?["C"] as? Int { moved = v }
        else { moved = 0 }
        Database.shared.exec("UPDATE COMIC_SHELF_BEAN SET GROUP_ID=0 WHERE GROUP_ID=?", id)
        Database.shared.exec("DELETE FROM COMIC_SHELF_GROUP_BEAN WHERE _ID=?", id)
        DiagLog.event("shelf", "group", "删除分组 id=\(id)，\(moved) 本移到未分组")
        return moved
    }

    func setAllSourcesEnabled(_ enabled: Bool) {
        Database.shared.exec("UPDATE COMIC_SOURCE_BEAN SET ENABLE=?", enabled ? 1 : 0)
        invalidateSourceCache()
    }
}
