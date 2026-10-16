import Foundation

/// ──────────────────────────────────────────────────────────────────────────
/// 离线章节库 —— 「下载过的章节必须离线秒开」的唯一真相源
///
/// ## 为什么需要它（用户实测反馈）
/// > 下载漫画的一章下载完，我去打开看的时候还要进行加载，我不是已经把
/// > 这一章图片都下载了吗，是不是这个设计本身就有问题
///
/// 确实有问题。旧实现里 `DownloadManager` 把图片写到
/// `Documents/Downloads/<漫画名>/<章节名>/001.jpg`，但**阅读器完全不知道
/// 这些文件存在** —— `ReaderView.loadChapter` 一律走
/// `ComicEngine.contentFirstPage`（联网解析章节页），再让 `ChapterImageStore`
/// 逐张走 Nuke 从网上重新拉。磁盘上那份拷贝只是「躺着」，没有任何读取路径。
/// 用户看到的就是「我明明下载了，打开还要转圈」。
///
/// ## 这条路径怎么补
///   · 下载完成时 `register(...)` 把「章节 URL → 本地目录」登记进 SQLite
///   · 阅读器开章前 `images(forChapterUrl:origin:)` 查一次，命中就直接读本地
///
/// ## 为什么用数据库登记而不是「按名字拼目录」
/// 目录名是 `chapterName` 清洗后的结果。章节名会变（站点改名、规则改了
/// `ruleChapterName`），一旦变了就再也找不到自己的下载。所以主键用
/// **chapterUrl**，名字只用于展示与人眼辨认。
///
/// ## 兼容旧数据
/// 老版本只写了 `TASK_BEAN`，没有登记表。查不到时退回：
///   ① `TASK_BEAN`（KEY = origin|noteUrl，DUR_CHAPTER_URL = 章节链接）
///   ② 目录里的 `_manifest.json`（新版本会写，含 chapterUrl）
///
/// ⚠️ 本类所有对外方法都是**同步**的：内部 `NSLock` 不能出现在 async
///    函数体里（Swift 6 硬规则，`NSLock.lock` 标了 `@available(*, noasync)`）。
/// ──────────────────────────────────────────────────────────────────────────
final class OfflineLibrary {
    static let shared = OfflineLibrary()
    private init() {}

    /// 章节目录里的清单文件名（便于「人肉排查 + 目录搬家后仍可自愈」）
    static let manifestName = "_manifest.json"

    /// 漫画图片扩展名（与 `LocalComicScanner.imageExts` 保持一致）
    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "avif", "bmp"]

    // MARK: - 目录

    /// 所有下载的根目录：`Documents/Downloads`
    func rootDir() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 某一章的落盘目录：`Downloads/<漫画名>/<章节名>`
    func chapterDir(comicName: String, chapterName: String) -> URL {
        rootDir()
            .appendingPathComponent(comicName.sanitizedFileName)
            .appendingPathComponent(chapterName.sanitizedFileName)
    }

    // MARK: - 登记（下载完成时调用）

    /// 把一个已完成的章节登记进离线库。
    /// - Returns: 登记成功返回 true（目录存在且至少有一张图）
    @discardableResult
    func register(chapterUrl: String, origin: String, noteUrl: String,
                  comicName: String, chapterName: String, dir: URL) -> Bool {
        guard !chapterUrl.isEmpty else { return false }
        let files = imageFiles(in: dir)
        guard !files.isEmpty else { return false }
        let size = files.reduce(Int64(0)) { $0 + fileSize($1) }

        Database.shared.exec("""
            INSERT OR REPLACE INTO LOCAL_CHAPTER
            (CHAPTER_URL, ORIGIN, NOTE_URL, COMIC_NAME, CHAPTER_NAME, DIR, IMAGE_COUNT, SIZE, ADD_TIME)
            VALUES (?,?,?,?,?,?,?,?,?)
            """,
            chapterUrl, origin, noteUrl, comicName, chapterName,
            dir.path, files.count, size, Int64(Date().timeIntervalSince1970 * 1000))

        writeManifest(dir: dir, chapterUrl: chapterUrl, origin: origin, noteUrl: noteUrl,
                      comicName: comicName, chapterName: chapterName, count: files.count)
        lock.lock(); cache.removeAll(); lock.unlock()      // 让下次查询重新读库
        return true
    }

    /// 目录里的清单（新版本下载时写；老目录没有，靠 TASK_BEAN 兜底）
    private func writeManifest(dir: URL, chapterUrl: String, origin: String, noteUrl: String,
                               comicName: String, chapterName: String, count: Int) {
        let obj: [String: Any] = [
            "chapterUrl": chapterUrl, "origin": origin, "noteUrl": noteUrl,
            "comicName": comicName, "chapterName": chapterName,
            "count": count, "time": Int64(Date().timeIntervalSince1970)
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return }
        try? d.write(to: dir.appendingPathComponent(Self.manifestName))
    }

    // MARK: - 查询

    private let lock = NSLock()
    /// 小缓存：`chapters` 列表页会一次性问几十个章节，别每个都打一次 SQLite。
    private var cache: [String: String] = [:]      // chapterUrl → dir path（"" 表示确认没有）

    /// 该章节是否已下载（离线可读）
    func isDownloaded(chapterUrl: String, origin: String) -> Bool {
        dir(forChapterUrl: chapterUrl, origin: origin) != nil
    }

    /// 找章节的本地目录。查不到返回 nil。
    func dir(forChapterUrl chapterUrl: String, origin: String) -> URL? {
        guard !chapterUrl.isEmpty else { return nil }
        let key = "\(origin)|\(chapterUrl)"

        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit.isEmpty ? nil : URL(fileURLWithPath: hit) }
        lock.unlock()

        var found: String? = nil

        // ① 新表（首选）
        let rows = Database.shared.query(
            "SELECT DIR FROM LOCAL_CHAPTER WHERE CHAPTER_URL=? AND ORIGIN=?", [chapterUrl, origin])
        if let p = rows.first?["DIR"] as? String, !p.isEmpty,
           FileManager.default.fileExists(atPath: p) {
            found = p
        }

        // ② 老数据兜底：TASK_BEAN（KEY = origin|noteUrl）反查目录名
        if found == nil {
            // 🔴 必须校验 `STATE=0`（已完成）**且**实际图片数 ≥ 记录的 `MAX`：
            //    以前只看目录里「有图」就算命中，于是**下载一半 / 下载失败**的章节
            //    会被判成「已下载」——阅读器直接拿残缺图当整章读（用户看到缺页、
            //    以为图源坏了），而且一旦误判，这章**再也不会被重新下载**。
            //    同因还让 `restorePersisted` / `addTask` 把中断的章节标成完成。
            //    （由智能体「书架」发现，属静默数据损坏）
            let t = Database.shared.query("""
                SELECT NAME, DUR_CHAPTER_NAME, MAX FROM TASK_BEAN
                WHERE DUR_CHAPTER_URL=? AND KEY LIKE ? AND STATE=0 LIMIT 1
                """, [chapterUrl, "\(origin)|%"])
            if let row = t.first,
               let comicName = row["NAME"] as? String, !comicName.isEmpty,
               let chapName = row["DUR_CHAPTER_NAME"] as? String, !chapName.isEmpty {
                let d = chapterDir(comicName: comicName, chapterName: chapName)
                let files = imageFiles(in: d)
                let expected = Int(truncatingIfNeeded: row["MAX"] as? Int64 ?? 0)
                // `MAX` 为 0（老数据没记张数）时只要求非空；记了就要求张数齐
                if !files.isEmpty, expected <= 0 || files.count >= expected { found = d.path }
            }
        }

        // ③ 目录里带 _manifest.json 的自愈路径（用于目录被整体搬动后）
        if found == nil, let d = findDirByManifest(chapterUrl: chapterUrl) { found = d.path }

        lock.lock()
        cache[key] = found ?? ""
        lock.unlock()
        return found.map { URL(fileURLWithPath: $0) }
    }

    /// 按 `_manifest.json` 里的 chapterUrl 反查目录（只在 ①② 都失败时才扫，代价可控）
    private func findDirByManifest(chapterUrl: String) -> URL? {
        let fm = FileManager.default
        guard let comics = try? fm.contentsOfDirectory(at: rootDir(), includingPropertiesForKeys: [.isDirectoryKey])
        else { return nil }
        for c in comics where c.lastPathComponent != "Inbox" {
            guard let chapters = try? fm.contentsOfDirectory(at: c, includingPropertiesForKeys: [.isDirectoryKey])
            else { continue }
            for ch in chapters {
                let m = ch.appendingPathComponent(Self.manifestName)
                guard let d = try? Data(contentsOf: m),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let u = obj["chapterUrl"] as? String, u == chapterUrl else { continue }
                return ch
            }
        }
        return nil
    }

    /// 该章节的本地图片文件（按文件名自然序，即 001、002、…）。
    /// 空数组表示没下载或目录里没图。
    func images(forChapterUrl chapterUrl: String, origin: String) -> [URL] {
        guard let d = dir(forChapterUrl: chapterUrl, origin: origin) else { return [] }
        return imageFiles(in: d)
    }

    /// 一批章节里哪些已下载（章节列表打「离线」角标用）。
    /// 一次 SQL 拿全，避免逐条查库。
    func downloadedChapterUrls(origin: String, noteUrl: String) -> Set<String> {
        var out = Set<String>()
        let rows = Database.shared.query(
            "SELECT CHAPTER_URL FROM LOCAL_CHAPTER WHERE ORIGIN=? AND NOTE_URL=?", [origin, noteUrl])
        for r in rows { if let u = r["CHAPTER_URL"] as? String { out.insert(u) } }
        // 老数据兜底：TASK_BEAN 里**已完成**的
        // 🔴 必须 `STATE=0`（已完成）—— 和 `dir(forChapterUrl:)` 的兜底保持同一套判据。
        //    以前这里不判状态，**下载了一半 / 下载失败**的章节也会亮「已下载」角标，
        //    同源缺陷换个入口又漏了进来。（由智能体「安全终审」发现）
        let t = Database.shared.query("""
            SELECT DUR_CHAPTER_URL, NAME, DUR_CHAPTER_NAME, MAX FROM TASK_BEAN
            WHERE KEY=? AND STATE=0 AND DUR_CHAPTER_URL IS NOT NULL AND DUR_CHAPTER_URL != ''
            """, ["\(origin)|\(noteUrl)"])
        for r in t {
            guard let u = r["DUR_CHAPTER_URL"] as? String, !out.contains(u),
                  let cn = r["NAME"] as? String, let chn = r["DUR_CHAPTER_NAME"] as? String
            else { continue }
            let files = imageFiles(in: chapterDir(comicName: cn, chapterName: chn))
            let expected = Int(truncatingIfNeeded: r["MAX"] as? Int64 ?? 0)
            // MAX 为 0（老数据没记张数）时只要求非空；记了就要求张数齐
            guard !files.isEmpty, expected <= 0 || files.count >= expected else { continue }
            out.insert(u)
        }
        return out
    }

    /// 已下载章节占用的总字节数
    func totalSize() -> Int64 {
        (Database.shared.query("SELECT SUM(SIZE) AS s FROM LOCAL_CHAPTER").first?["s"] as? Int64) ?? 0
    }

    /// 已下载章节数
    func count() -> Int {
        Int(truncatingIfNeeded: (Database.shared.query("SELECT COUNT(*) AS c FROM LOCAL_CHAPTER").first?["c"] as? Int64) ?? 0)
    }

    // MARK: - 删除

    /// 删掉某一章的下载（同时清登记与目录）
    func remove(chapterUrl: String, origin: String) {
        if let d = dir(forChapterUrl: chapterUrl, origin: origin) {
            try? FileManager.default.removeItem(at: d)
        }
        Database.shared.exec("DELETE FROM LOCAL_CHAPTER WHERE CHAPTER_URL=? AND ORIGIN=?", chapterUrl, origin)
        lock.lock(); cache.removeAll(); lock.unlock()
    }

    // MARK: - 工具

    /// 目录里的图片文件（自然序）。顺带跳过 `_manifest.json` 之类的非图片。
    func imageFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names
            .filter { Self.imageExts.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { naturalLess($0, $1) }
            .map { dir.appendingPathComponent($0) }
    }

    private func fileSize(_ url: URL) -> Int64 {
        // ⚠️ 不要写 `.map(Int64.init)` —— `Int64` 有多个重载 init
        //    （`init(_: Int)` / `init(_: some BinaryInteger)` / `init(_: Double)` …），
        //    作为函数值传递时容易产生歧义。显式闭包最稳。
        //    另外 `try? x.y` 在 Swift 5 起会把 `Int??` 压平成 `Int?`，所以 map 能直接接。
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
    }

    /// 自然序比较：`002.jpg` < `010.jpg`（按数字大小而不是字典序）。
    ///
    /// ⚠️ 原实现只认「去掉扩展名后是**纯整数**」的文件名，其它一律落到 `Int.max`
    ///    → 退化成字典序。于是 `page2.jpg` 会排在 `page10.jpg` **之后**
    ///    （`'2' > '1'`），页序错乱。
    ///    改用 Foundation 的 `.numeric` 比较，与 `LocalComicScanner.naturalCompare`
    ///    口径统一（同一本漫画走不同入口时顺序才一致）。
    private func naturalLess(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.numeric, .caseInsensitive]) == .orderedAscending
    }
}
