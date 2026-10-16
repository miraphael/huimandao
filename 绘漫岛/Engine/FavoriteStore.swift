import Foundation

/// ──────────────────────────────────────────────────────────────────────────
/// 图集收藏 · 存储层
///
/// ## 落盘顺序（为什么不能反）
/// ```
/// ① 写临时文件 → ② rename 到正式名 → ③ 写数据库
/// ```
/// - **先写文件再写库**：库里有记录但文件不存在 = 列表里一张裂图；
///   反过来（文件在、库没有）最多是「占了一点空间」，用户无感。
/// - **必须 rename 而不是直接写目标名**：写到一半被杀进程会留下半张图，
///   而 rename 在同一卷上是原子的 —— 要么完整，要么没有。
/// - 第 ③ 步失败 → **回滚文件**，不留孤儿文件。
///
/// ## 目录与清理边界
/// 所有收藏都在 `Documents/Favorites/`，与离线下载的 `Documents/Downloads/`
/// **完全分开**。清理缓存/删下载都不会碰到这里。
///
/// ⚠️ 本类对外方法全部是**同步**的：内部用 `NSLock`，
///    而 `NSLock.lock()` 标了 `@available(*, noasync)`，
///    在 async 函数体里直接调用是 Swift 6 编译错误（`probe/async_lock.py` 扫这个）。
///    需要下载的异步部分放在 `FavoriteSession`。
/// ---------------------------------------------------------------------------
final class FavoriteStore {
    static let shared = FavoriteStore()
    private init() {}

    private let lock = NSLock()

    // MARK: - 目录

    /// `Documents/Favorites`（与下载目录分开）
    func rootDir() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Favorites")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func fileURL(for item: FavoriteImage) -> URL {
        rootDir().appendingPathComponent(item.fileName)
    }

    // MARK: - 写入

    /// 保存一张收藏图。
    ///
    /// - Parameter data: 已经过图源解码（`ChapterImageStore.decodeBytes`）的**原始字节**，
    ///   不是重新编码的截图 —— 保证「收藏的就是用户看到的那张」。
    /// - Returns: 成功返回记录；失败返回 nil（并已清理临时文件）。
    @discardableResult
    func add(origin: String, noteUrl: String, comicName: String,
             chapterUrl: String, chapterName: String, imageIndex: Int,
             imageURL: String, data: Data) -> FavoriteImage? {
        guard !chapterUrl.isEmpty, !data.isEmpty else { return nil }
        let id = FavoriteImage.makeID(origin: origin, chapterUrl: chapterUrl, index: imageIndex)
        let ext = Self.fileExtension(for: data)
        let fileName = "\(id).\(ext)"
        let dir = rootDir()
        let finalURL = dir.appendingPathComponent(fileName)
        let tmpURL = dir.appendingPathComponent(".tmp-\(id)-\(UUID().uuidString)")

        // ① 临时文件
        do {
            try data.write(to: tmpURL, options: .atomic)
        } catch {
            return nil
        }
        // ② rename（同卷原子）
        do {
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: tmpURL, to: finalURL)
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            return nil
        }

        let item = FavoriteImage(
            id: id, origin: origin, noteUrl: noteUrl, comicName: comicName,
            chapterUrl: chapterUrl, chapterName: chapterName, imageIndex: imageIndex,
            imageURL: imageURL, fileName: fileName,
            byteCount: data.count, addedAt: Int64(Date().timeIntervalSince1970 * 1000))

        // ③ 数据库（失败则回滚文件，不留孤儿）
        guard insert(item) else {
            try? FileManager.default.removeItem(at: finalURL)
            return nil
        }
        return item
    }

    /// 按文件头猜扩展名（不信任 URL 后缀：很多站的图片 URL 没有后缀）。
    private static func fileExtension(for data: Data) -> String {
        let b = [UInt8](data.prefix(12))
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50 { return "png" }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8 { return "jpg" }
        if b.count >= 12, b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "webp" }
        if b.count >= 3, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "gif" }
        return "jpg"
    }

    // MARK: - 查询

    /// ── 收藏 ID 内存索引 ─────────────────────────────────────────────────────
    ///
    /// `contains(...)` 由 `ReaderView.favoriteOn` 在 **body 里每帧调用**，
    /// 原先每次都走一次同步 SQLite `SELECT`（`Database.query` 虽是串行队列，
    /// 但主线程仍要阻塞等锁 + 走一遍 sqlite3 step）。
    /// 阅读器翻页/缩放时每帧一次同步 IO，是可见的掉帧来源。
    ///
    /// 收藏表的特征与源表一样是「读多写少」：条目只由本类增删，
    /// 因此维护一个 `Set<id>` 即可 —— 增删时同步更新，读时 O(1) 且零 IO。
    ///
    /// ⚠️ 索引**必须**在所有写路径上保持同步：`add` / `remove` / `removeAll` /
    ///    `pruneOrphanFiles`（不清 ID，只清文件）/ `insert`。
    ///    懒加载：首次查询时从库里建一次（`reloadIndexLocked`），之后常驻。
    private var idIndex: Set<String>?
    private var idIndexLoaded = false

    /// 从库里重建内存索引（已在锁内调用）
    private func reloadIndexLocked() {
        let rows = Database.shared.query("SELECT ID FROM IMAGE_FAVORITE")
        idIndex = Set(rows.compactMap { $0["ID"] as? String })
        idIndexLoaded = true
    }

    func contains(origin: String, chapterUrl: String, index: Int) -> Bool {
        let id = FavoriteImage.makeID(origin: origin, chapterUrl: chapterUrl, index: index)
        lock.lock()
        if !idIndexLoaded { reloadIndexLocked() }
        let hit = idIndex?.contains(id) ?? false
        lock.unlock()
        return hit
    }

    func all() -> [FavoriteImage] {
        let rows = Database.shared.query(
            "SELECT * FROM IMAGE_FAVORITE ORDER BY ADD_TIME DESC")
        return rows.compactMap(Self.decode)
    }

    /// 某本漫画的收藏（按页序号升序，便于「跳回原位置」）
    func images(origin: String, noteUrl: String) -> [FavoriteImage] {
        let rows = Database.shared.query(
            "SELECT * FROM IMAGE_FAVORITE WHERE ORIGIN=? AND NOTE_URL=? ORDER BY CHAPTER_URL, IMAGE_INDEX",
            [origin, noteUrl])
        return rows.compactMap(Self.decode)
    }

    func count() -> Int {
        let rows = Database.shared.query("SELECT COUNT(*) AS C FROM IMAGE_FAVORITE")
        return Self.int(rows.first?["C"])
    }

    func totalBytes() -> Int64 {
        let rows = Database.shared.query("SELECT BYTE_COUNT FROM IMAGE_FAVORITE")
        return rows.reduce(Int64(0)) { $0 + Self.int64($1["BYTE_COUNT"]) }
    }

    // MARK: - 删除

    /// 删除一条收藏（先删库再删文件）。
    ///
    /// 顺序与新增相反：**先删库** —— 即使文件删不掉，也只是留下一个不可见的
    /// 孤儿文件（可由 `pruneOrphanFiles` 清理），而不会出现「列表里有点开是裂图」。
    @discardableResult
    func remove(id: String) -> Bool {
        let rows = Database.shared.query(
            "SELECT FILE_NAME FROM IMAGE_FAVORITE WHERE ID=?", [id])
        let fileName = rows.first?["FILE_NAME"] as? String ?? ""
        Database.shared.exec("DELETE FROM IMAGE_FAVORITE WHERE ID=?", id)
        lock.lock()
        if !idIndexLoaded { reloadIndexLocked() }
        idIndex?.remove(id)
        lock.unlock()
        if !fileName.isEmpty {
            try? FileManager.default.removeItem(at: rootDir().appendingPathComponent(fileName))
        }
        return true
    }

    func removeAll() {
        for item in all() { remove(id: item.id) }
        pruneOrphanFiles()
    }

    /// 清理「文件在、库里没有」的孤儿文件（崩溃/异常退出留下的）。
    /// - Returns: 清理掉的文件数
    @discardableResult
    func pruneOrphanFiles() -> Int {
        let known = Set(all().map(\.fileName))
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: rootDir().path) else { return 0 }
        var removed = 0
        for name in files where !known.contains(name) {
            try? fm.removeItem(at: rootDir().appendingPathComponent(name))
            removed += 1
        }
        return removed
    }

    // MARK: - 行解码

    /// ⚠️ `Database.query` 把 SQLITE_INTEGER 读成 **`Int64`**（不是 `Int`）——
    ///    直接 `as? Int` 会永远拿到 nil，字段静默变成 0（踩过）。
    private static func int(_ v: Any?) -> Int {
        if let n = v as? Int64 { return Int(n) }
        if let n = v as? Int { return n }
        if let n = v as? Double { return Int(n) }
        return 0
    }

    private static func int64(_ v: Any?) -> Int64 {
        if let n = v as? Int64 { return n }
        if let n = v as? Int { return Int64(n) }
        if let n = v as? Double { return Int64(n) }
        return 0
    }

    private static func decode(_ row: [String: Any]) -> FavoriteImage? {
        guard let id = row["ID"] as? String, !id.isEmpty else { return nil }
        return FavoriteImage(
            id: id,
            origin: row["ORIGIN"] as? String ?? "",
            noteUrl: row["NOTE_URL"] as? String ?? "",
            comicName: row["COMIC_NAME"] as? String ?? "",
            chapterUrl: row["CHAPTER_URL"] as? String ?? "",
            chapterName: row["CHAPTER_NAME"] as? String ?? "",
            imageIndex: int(row["IMAGE_INDEX"]),
            imageURL: row["IMAGE_URL"] as? String ?? "",
            fileName: row["FILE_NAME"] as? String ?? "",
            byteCount: int(row["BYTE_COUNT"]),
            addedAt: int64(row["ADD_TIME"]))
    }

    private func insert(_ item: FavoriteImage) -> Bool {
        Database.shared.exec("""
            INSERT OR REPLACE INTO IMAGE_FAVORITE
            (ID, ORIGIN, NOTE_URL, COMIC_NAME, CHAPTER_URL, CHAPTER_NAME,
             IMAGE_INDEX, IMAGE_URL, FILE_NAME, BYTE_COUNT, ADD_TIME)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            """,
            item.id, item.origin, item.noteUrl, item.comicName, item.chapterUrl,
            item.chapterName, item.imageIndex, item.imageURL, item.fileName,
            item.byteCount, item.addedAt)
        // 回读校验：exec 不抛错不代表写进去了（例如表不存在）
        let rows = Database.shared.query("SELECT ID FROM IMAGE_FAVORITE WHERE ID=?", [item.id])
        let ok = !rows.isEmpty
        if ok {
            lock.lock()
            if !idIndexLoaded { reloadIndexLocked() }
            idIndex?.insert(item.id)
            lock.unlock()
        }
        return ok
    }
}
