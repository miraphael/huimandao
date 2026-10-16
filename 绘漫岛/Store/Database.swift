import Foundation
import Security
import SQLCipher

/// SQLITE_TRANSIENT 宏在 Swift 不可见，手动定义
private let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

/// SQLCipher 数据库直连封装（表结构与 GreenDAO 一一对应）
///
/// 🔐 加固第 4 重：数据库文件现在是 SQLCipher AES-256 加密的。
/// 密钥随机生成并存 Keychain，不写 UserDefaults、不写数据库、不写日志。
///
/// 迁移策略（用户已确认本地数据不重要）：
/// - 新安装：生成随机密钥，创建加密 hmd.db
/// - 旧明文库 / 密钥丢失导致无法打开：将 hmd.db、WAL、SHM 改名为
///   `.legacy-*`，创建全新的加密库，避免启动崩溃
/// - 这样不会把旧明文文件删除，便于故障排查，但主库从此只使用加密文件
final class Database {
    static let shared = Database()
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "hmd.db")
    private let dbPath: String
    private static let keychainKey = "databaseEncryptionKey.v1"

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dbPath = dir.appendingPathComponent("hmd.db").path
        let key = Self.databaseKey()
        openEncrypted(path: dbPath, key: key)

        // 🔴 必须开 WAL —— 默认的 rollback journal 模式下读会阻塞写、写会阻塞读，
        //    而本类是「单条串行队列 + 所有读写都 queue.sync」的结构。
        //    WAL 让读写在多数情况下互不阻塞。
        if db != nil {
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        }
    }

    /// 从 Keychain 取 32 字节随机密钥；首次运行生成并存储。
    private static func databaseKey() -> String {
        if let old = KeychainStore.get(keychainKey), !old.isEmpty { return old }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let key = status == errSecSuccess
            ? Data(bytes).base64EncodedString()
            : UUID().uuidString + UUID().uuidString
        _ = KeychainStore.set(key, forKey: keychainKey)
        return key
    }

    /// 打开并设置 SQLCipher 密钥；探测失败时隔离旧库再重建。
    private func openEncrypted(path: String, key: String) {
        guard sqlite3_open_v2(path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, let handle = db else { return }
        key.withCString { sqlite3_key(handle, $0, Int32(key.utf8.count)) }

        // SQLCipher 4 默认格式；明确设置便于以后升级/诊断。
        sqlite3_exec(handle, "PRAGMA cipher_compatibility = 4;", nil, nil, nil)
        var stmt: OpaquePointer?
        let probeOK = sqlite3_prepare_v2(handle, "SELECT count(*) FROM sqlite_master;", -1, &stmt, nil) == SQLITE_OK
        if probeOK { _ = sqlite3_step(stmt) }
        sqlite3_finalize(stmt)
        guard probeOK else {
            sqlite3_close(handle)
            db = nil
            isolateLegacyFiles(at: path)
            guard sqlite3_open_v2(path, &db,
                                  SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                                  nil) == SQLITE_OK, let fresh = db else { return }
            key.withCString { sqlite3_key(fresh, $0, Int32(key.utf8.count)) }
            sqlite3_exec(fresh, "PRAGMA cipher_compatibility = 4;", nil, nil, nil)
            DiagLog.event("db", "rebuild", "旧数据库无法用 SQLCipher 打开，已隔离并创建加密新库")
            return
        }
        DiagLog.event("db", "cipher", "SQLCipher 数据库已打开")
    }

    private func isolateLegacyFiles(at path: String) {
        let stamp = Int(Date().timeIntervalSince1970)
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let old = path + suffix
            guard fm.fileExists(atPath: old) else { continue }
            let dst = old + ".legacy-\(stamp)"
            try? fm.moveItem(atPath: old, toPath: dst)
        }
    }

    func migrate() {
        // 注意：必须在队列内用 *Locked 版本，绝不能再走 queue.sync（会自死锁闪退）
        queue.sync {
            execLocked("""
            CREATE TABLE IF NOT EXISTS COMIC_SOURCE_BEAN (
              BOOK_SOURCE_URL TEXT PRIMARY KEY, BOOK_SOURCE_TYPE TEXT, BOOK_SINGLE_THREAD TEXT,
              BOOK_DELAY_TIME TEXT, BOOK_SOURCE_NAME TEXT, BOOK_SOURCE_GROUP TEXT, CHECK_URL TEXT,
              LAST_UPDATE_TIME INTEGER, SERIAL_NUMBER INTEGER, WEIGHT INTEGER, ENABLE INTEGER,
              RULE_FIND_URL TEXT, RULE_SEARCH_URL TEXT, RULE_SEARCH_URL_NEXT TEXT,
              RULE_SEARCH_LIST TEXT, RULE_SEARCH_NAME TEXT, RULE_SEARCH_AUTHOR TEXT,
              RULE_SEARCH_KIND TEXT, RULE_SEARCH_LAST_CHAPTER TEXT, RULE_SEARCH_COVER_URL TEXT,
              RULE_SEARCH_COVER_DECODER TEXT, RULE_SEARCH_NOTE_URL TEXT, RULE_BOOK_NAME TEXT,
              RULE_BOOK_AUTHOR TEXT, RULE_CHAPTER_ID TEXT, RULE_CHAPTER_URL TEXT,
              RULE_CHAPTER_URL_NEXT TEXT, RULE_CHAPTER_PARENT_ID TEXT, RULE_CHAPTER_PARENT_NAME TEXT,
              RULE_COVER_URL TEXT, RULE_COVER_DECODER TEXT, RULE_INTRODUCE TEXT, RULE_CHAPTER_LIST TEXT,
              RULE_CHAPTER_NAME TEXT, RULE_CONTENT_URL TEXT, RULE_CONTENT_URL_NEXT TEXT,
              RULE_BOOK_CONTENT TEXT, RULE_BOOK_CONTENT_DECODER TEXT, HTTP_USER_AGENT TEXT,
              RULE_BOOK_KIND TEXT, RULE_BOOK_LAST_CHAPTER TEXT, RULE_BOOK_URL_PATTERN TEXT,
              LOGIN_URL TEXT, LOGIN_URL_RESULT TEXT, SOURCE_REMARK TEXT, RULE_CONTENT_FLOW TEXT)
            """)
            execLocked("""
            CREATE TABLE IF NOT EXISTS COMIC_SHELF_BEAN (
              NOTE_URL TEXT PRIMARY KEY, SERIAL_NUMBER INTEGER, FINAL_DATE INTEGER, HAS_UPDATE INTEGER,
              NEW_CHAPTERS TEXT, DUR_CHAPTER_URL TEXT, DUR_CHAPTER_NAME TEXT, DUR_CHAPTER_PAGE INTEGER,
              CHAPTER_LIST_SIZE INTEGER, LAST_CHAPTER_NAME TEXT, CUSTOM_COVER_PATH TEXT,
              ALLOW_UPDATE INTEGER, GROUP_ID INTEGER, READ_MODE INTEGER, VARIABLE TEXT,
              FINAL_REFRESH_DATA INTEGER, ORIGIN TEXT, NAME TEXT, COVER_URL TEXT, AUTHOR TEXT, KIND TEXT)
            """)
            execLocked("""
            CREATE TABLE IF NOT EXISTS COMIC_INFO_BEAN (
              NOTE_URL TEXT, NAME TEXT, ORIGIN TEXT, CHAPTER_URL TEXT, COVER_URL TEXT, AUTHOR TEXT,
              INTRODUCE TEXT, KIND TEXT, TAG TEXT, DOWNLOAD INTEGER, FINAL_REFRESH_DATA INTEGER,
              VARIABLE TEXT, PRIMARY KEY (NOTE_URL, ORIGIN))
            """)
            execLocked("""
            CREATE TABLE IF NOT EXISTS CHAPTER_LIST_BEAN (
              NOTE_URL TEXT, PARENT_ID_STRING TEXT, PARENT_NAME_STRING TEXT, CHAPTER_ID TEXT,
              DUR_CHAPTER_URL TEXT, DUR_CHAPTER_NAME TEXT, DUR_CHAPTER_INDEX INTEGER,
              NEXT_CHAPTER_URL TEXT, START INTEGER, END INTEGER, COMIC_INFO_URL TEXT,
              VARIABLE TEXT, TAG TEXT, TID TEXT, COMPLETE INTEGER, DOWNLOAD INTEGER,
              PRIMARY KEY (NOTE_URL, PARENT_ID_STRING))
            """)
            execLocked("""
            CREATE TABLE IF NOT EXISTS HISTORY_COMIC_BEAN (
              NAME TEXT, AUTHOR TEXT, COVER_URL TEXT, KIND TEXT, DESCRIBE TEXT, LAST_CHAPTER TEXT,
              CHAPTER_URL TEXT, NOTE_URL TEXT PRIMARY KEY, ORIGIN TEXT, VARIABLE TEXT,
              UP_TIME INTEGER, SEARCH_PAGE INTEGER, TAG TEXT)
            """)
            execLocked("""
            CREATE TABLE IF NOT EXISTS SEARCH_COMIC_BEAN (
              NAME TEXT, AUTHOR TEXT, COVER_URL TEXT, KIND TEXT, DESCRIBE TEXT, LAST_CHAPTER TEXT,
              CHAPTER_URL TEXT, NOTE_URL TEXT, ORIGIN TEXT, VARIABLE TEXT, UP_TIME INTEGER,
              ADD_TIME INTEGER, URL_NEXT TEXT, WEIGHT INTEGER, WORDS TEXT,
              PRIMARY KEY (NOTE_URL, ORIGIN))
            """)
            execLocked("""
            CREATE TABLE IF NOT EXISTS TASK_BEAN (
              _ID INTEGER PRIMARY KEY AUTOINCREMENT, KEY TEXT, NAME TEXT, SOURCE TEXT, PATH TEXT,
              PARENT_ID_STRING TEXT, PARENT_NAME_STRING TEXT, CHAPTER_ID TEXT,
              DUR_CHAPTER_URL TEXT, DUR_CHAPTER_NAME TEXT, DUR_CHAPTER_INDEX INTEGER,
              NEXT_CHAPTER_URL TEXT, START INTEGER, END INTEGER, COMIC_INFO_URL TEXT,
              VARIABLE TEXT, STATE INTEGER, PROGRESS INTEGER, MAX INTEGER, TITLE TEXT,
              ERROR_MESSAGE TEXT, IS_CHECKED INTEGER)
            """)
            execLocked("""
            CREATE TABLE IF NOT EXISTS COMIC_SHELF_GROUP_BEAN (
              _ID INTEGER PRIMARY KEY AUTOINCREMENT, GROUP_NAME TEXT, GROUP_NUMBER INTEGER,
              GROUP_SORT INTEGER, GROUP_VIEW INTEGER, ENABLE INTEGER)
            """)
            execLocked("""
            CREATE TABLE IF NOT EXISTS COOKIE_BEAN (url TEXT PRIMARY KEY, variable_str TEXT)
            """)
            execLocked("""
            CREATE TABLE IF NOT EXISTS VARIABLES (KEY TEXT PRIMARY KEY, VALUE TEXT)
            """)
            // ── 离线章节库：章节 URL → 本地目录 ──
            // 「下载完打开还要联网加载」的根治点。主键用 **chapterUrl**（不是
            // 章节名）—— 章节名会随站点改名而变，用名字当键会导致下载找不到自己。
            // 详见 `OfflineLibrary` 的注释。
            execLocked("""
            CREATE TABLE IF NOT EXISTS LOCAL_CHAPTER (
              CHAPTER_URL TEXT, ORIGIN TEXT, NOTE_URL TEXT, COMIC_NAME TEXT, CHAPTER_NAME TEXT,
              DIR TEXT, IMAGE_COUNT INTEGER, SIZE INTEGER, ADD_TIME INTEGER,
              PRIMARY KEY (CHAPTER_URL, ORIGIN))
            """)

            // ── 图集收藏：单张图收藏（与离线下载**分目录、分开清理**）──
            // 主键是 `sha256(origin|chapterUrl|index)` —— **不是图片 URL**：
            // 图站地址常带签名/时间戳，下次打开就变，拿它当键会「同一张图收藏两次变两条」。
            // 表是全新的，所以 `CREATE TABLE IF NOT EXISTS` 就够（无需 ALTER 补列）。
            execLocked("""
            CREATE TABLE IF NOT EXISTS IMAGE_FAVORITE (
              ID TEXT PRIMARY KEY, ORIGIN TEXT, NOTE_URL TEXT, COMIC_NAME TEXT,
              CHAPTER_URL TEXT, CHAPTER_NAME TEXT, IMAGE_INDEX INTEGER,
              IMAGE_URL TEXT, FILE_NAME TEXT, BYTE_COUNT INTEGER, ADD_TIME INTEGER)
            """)

            // ── JS 类源（ARCHITECTURE §9.1）──
            // 与 JSON 规则源（COMIC_SOURCE_BEAN）**分表**：两者的字段/校验/安全模型都不同，
            // 混在一张表里迟早要为了 JS 源加一堆对 JSON 源无意义的列。
            // ⚠️ `MANIFEST_JSON` 存**完整 manifest 原文**而不是逐字段拆列 ——
            //    manifest 后续会加字段（桥接版本演进），存原文就不必每次加列+迁移。
            //    常用检索字段（ID/NAME/DOMAIN/ENABLED）单独冗余一份，便于列表查询。
            // 表是全新的，`CREATE TABLE IF NOT EXISTS` 即可（无需 ALTER 补列）。
            execLocked("""
            CREATE TABLE IF NOT EXISTS JS_SOURCE (
              ID TEXT PRIMARY KEY, NAME TEXT, VERSION TEXT, API_VERSION INTEGER,
              DOMAIN TEXT, ENABLED INTEGER DEFAULT 1, MANIFEST_JSON TEXT, ADD_TIME INTEGER)
            """)

            // ── 阅读进度（**与书架解耦**）──
            // 🔴 为什么要独立一张表：以前进度只存在 `COMIC_SHELF_BEAN.DUR_CHAPTER_*`，
            //    而 `updateProgress` 用的是纯 `UPDATE` —— 对**没加入书架**的书
            //    （搜索页/详情页直达阅读）影响 0 行，进度**静默丢失**，
            //    用户再进来发现从第 0 页开始，看着就像「进度没保存」。
            //    书架行仍然同步更新（书架列表直接读它），但这张表才是**权威来源**。
            // 表是全新的，`CREATE TABLE IF NOT EXISTS` 即可（无需 ALTER 补列）。
            execLocked("""
            CREATE TABLE IF NOT EXISTS COMIC_PROGRESS (
              NOTE_URL TEXT PRIMARY KEY, ORIGIN TEXT, NAME TEXT, COVER_URL TEXT, AUTHOR TEXT, KIND TEXT,
              CHAPTER_URL TEXT, CHAPTER_NAME TEXT, PAGE INTEGER, UPDATED INTEGER)
            """)

            // ── 删除墓碑（ARCHITECTURE §8.2 阶段 B）──
            // 目的：记录「某条数据在某时刻被删除」，让双向合并时**不会把已删的条目
            // 从远端旧备份里复活**（没有墓碑，删除信息在合并中必然丢失）。
            // 主键 (ID, KIND)：同一条数据只留一条墓碑（重复删除覆盖时间戳即可）。
            // ⚠️ `KIND` 取值：`source`（bookSourceUrl）/ `shelf`（NOTE_URL）/ `group`（GROUP_NAME）。
            // 表是全新的，`CREATE TABLE IF NOT EXISTS` 即可。
            execLocked("""
            CREATE TABLE IF NOT EXISTS TOMBSTONE (
              ID TEXT, KIND TEXT, DELETED_AT INTEGER, DEVICE_ID TEXT,
              PRIMARY KEY (ID, KIND))
            """)

            // ── 迁移：书架表补一列章节列表 JSON ──
            // 安卓原版把章节列表存在独立的 CHAPTER_LIST_BEAN 表（通过 daoSession 关联查询），
            // 所以点书架时**不需要联网**就能直接进阅读器。我们此前表建了但从未读写，
            // 导致每次点书架都要重新抓一遍章节 —— 这就是「每次都出现抓取章节」的根因。
            //
            // ⚠️ 这里必须用 columnExistsLocked（直接用已打开的 db 句柄），
            // 绝不能走 Database.query —— 那条路会 queue.sync 自死锁。
            if !columnExistsLocked("COMIC_SHELF_BEAN", "CHAPTERS_JSON") {
                execLocked("ALTER TABLE COMIC_SHELF_BEAN ADD COLUMN CHAPTERS_JSON TEXT")
            }
            if !columnExistsLocked("COMIC_SHELF_BEAN", "CHAPTERS_CACHE_TIME") {
                execLocked("ALTER TABLE COMIC_SHELF_BEAN ADD COLUMN CHAPTERS_CACHE_TIME INTEGER DEFAULT 0")
            }
            // ── 迁移：追更用的两列 ──
            // 建表语句里本来就有 NEW_CHAPTERS / FINAL_REFRESH_DATA（对齐安卓原版），
            // 但 `CREATE TABLE IF NOT EXISTS` **不会给已存在的表补列** ——
            // 老用户升级上来的库里没有这两列，追更一跑就会 "no such column"。
            // 所以这里必须显式 ALTER。
            if !columnExistsLocked("COMIC_SHELF_BEAN", "NEW_CHAPTERS") {
                execLocked("ALTER TABLE COMIC_SHELF_BEAN ADD COLUMN NEW_CHAPTERS TEXT")
            }
            if !columnExistsLocked("COMIC_SHELF_BEAN", "FINAL_REFRESH_DATA") {
                execLocked("ALTER TABLE COMIC_SHELF_BEAN ADD COLUMN FINAL_REFRESH_DATA INTEGER DEFAULT 0")
            }

            // ── 迁移：源表补 `HEADER` 列 ──
            // ⚠️ `ComicSource.header` 承载 Legado 的 `header` 字段（源自带的请求头，
            //    很多漫画源靠它带 Referer/UA），`ComicEngine.sourceHeaders` 也会读它。
            //    但 `COMIC_SOURCE_BEAN` **没有这一列**、`saveSource` 也没写它 →
            //    **导入任何带 header 的源都会把它丢掉** → 搜索/详情/正文全部 403 或空页。
            //    同时这也让「导出 → 再导入」不可逆（导出有 header，导入后恒为 nil）。
            if !columnExistsLocked("COMIC_SOURCE_BEAN", "HEADER") {
                execLocked("ALTER TABLE COMIC_SOURCE_BEAN ADD COLUMN HEADER TEXT")
            }

            // ── 迁移：源表补 `RULE_CONTENT_FLOW` 列 ──
            // ⚠️ `ruleContentFlow`（声明式多步内容流，见 `ContentFlowEngine`）此前
            //    **只活在内存里**：`saveSource` 的固定列 INSERT 不写它、`rowToSource`
            //    也不读它 → 导入「成功」但 flow 恒为 nil → 卡拉这类挑战流站点正文
            //    落到空规则路径、**静默返回空**（用户只看到「加载失败」，日志里一条都没有）。
            //    这个坑和 `HEADER` 那次一模一样，所以用同样的显式 ALTER 兜老库。
            if !columnExistsLocked("COMIC_SOURCE_BEAN", "RULE_CONTENT_FLOW") {
                execLocked("ALTER TABLE COMIC_SOURCE_BEAN ADD COLUMN RULE_CONTENT_FLOW TEXT")
            }

            // ── 迁移：下载任务表加**唯一索引**，防僵尸行 ──
            // `TASK_BEAN` 的建表语句没有唯一约束，下载任务的插入路径用的是普通
            // `INSERT` —— 同一本书同一章被反复入队（断点续传、重试、并发调度重叠）
            // 就会留下多条 `(KEY, DUR_CHAPTER_URL)` 相同的行：
            //   · 下载列表里同一章显示多次；
            //   · 完成/删除时只处理到其中一条，另一条永久挂在那里（僵尸行）。
            //
            // ⚠️ 建唯一索引前必须**先去重**，否则在有重复行的老库上建索引会直接失败，
            //    整个 `migrate()` 抛错 → 启动崩溃。这里保留每组 `_ID` 最小的一条
            //    （最早入队的那条，其进度信息最完整）。
            execLocked("""
            DELETE FROM TASK_BEAN WHERE _ID NOT IN (
                SELECT MIN(_ID) FROM TASK_BEAN GROUP BY KEY, DUR_CHAPTER_URL
            )
            """)
            // `IF NOT EXISTS` 保证幂等；重复执行不会报错。
            execLocked("""
            CREATE UNIQUE INDEX IF NOT EXISTS IDX_TASK_KEY_CHAPTER
            ON TASK_BEAN (KEY, DUR_CHAPTER_URL)
            """)
        }
    }

    /// 列是否存在（**只能在已持有 db 队列时调用**，不自行加锁）
    private func columnExistsLocked(_ table: String, _ column: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1), String(cString: c) == column { return true }
        }
        return false
    }

    func exec(_ sql: String, _ params: Any...) {
        queue.sync {
            execLocked(sql, params)
        }
    }

    /// **数组版**执行 —— 参数个数在运行期才知道时用这个。
    ///
    /// ⚠️ 为什么必须有它（这是一个真实的静默数据损坏源）：
    ///    `exec` 是**变参** `Any...`。写 `exec(sql, [a, b])` 时 Swift **不会展开数组**，
    ///    整个 `[a, b]` 会成为**唯一一个** `Any` 元素 → `params == [[a, b]]`。
    ///    `bind` 只循环一次，遇到 `Array` 落进 `default: sqlite3_bind_null`
    ///    → 占位符**全部绑成 NULL**，且其余占位符**根本没被绑定**（默认也是 NULL）。
    ///
    ///    语句本身能执行、**不报任何错**，于是：
    ///      · `DELETE ... WHERE ID = NULL` → 恒不匹配 → **删除静默失效**；
    ///      · `DELETE ... WHERE DELETED_AT < NULL` → 恒假 → **清理静默失效**；
    ///      · `INSERT ... VALUES (NULL, …)` → 主键为 NULL → **插入垃圾行**。
    ///
    ///    调用方必须显式选择：**固定个数的参数用 `exec(sql, a, b)`**（变参形式），
    ///    **动态个数的参数用 `execArray(sql, [a, b])`**。
    func execArray(_ sql: String, _ params: [Any]) {
        queue.sync {
            execLocked(sql, params)
        }
    }

    /// 只在已持有 db 队列的上下文里调用（migrate 内部 / exec 包装层）
    private func execLocked(_ sql: String, _ params: [Any] = []) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("[DB] exec prepare 失败:", sql.prefix(80), "|", String(cString: sqlite3_errmsg(db)))
            return
        }
        defer { sqlite3_finalize(stmt) }
        bind(params, to: stmt)
        if sqlite3_step(stmt) != SQLITE_DONE && sqlite3_column_count(stmt) == 0 {
            print("[DB] exec step 失败:", String(cString: sqlite3_errmsg(db)))
        }
    }

    /// 执行一条 INSERT 并**在同一队列周期内**返回自增主键。
    ///
    /// ⚠️ 不要写成「先 `exec` 再读 `sqlite3_last_insert_rowid`」—— 两次调用之间
    ///    可能被别的线程插入一条，读回来的是**别人的** id。
    ///    放在同一个 `queue.sync` 里才严格正确。
    @discardableResult
    func insertReturningID(_ sql: String, _ params: Any...) -> Int64 {
        queue.sync {
            execLocked(sql, params)
            return sqlite3_last_insert_rowid(db)
        }
    }

    func query(_ sql: String, _ params: [Any] = []) -> [[String: Any]] {
        queue.sync {
            queryLocked(sql, params)
        }
    }

    private func queryLocked(_ sql: String, _ params: [Any]) -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("[DB] query prepare 失败:", sql.prefix(80), "|", String(cString: sqlite3_errmsg(db)))
            return rows
        }
        defer { sqlite3_finalize(stmt) }
        bind(params, to: stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            let count = sqlite3_column_count(stmt)
            for i in 0..<count {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(stmt, i))
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_BLOB: row[name] = Data(bytes: sqlite3_column_blob(stmt, i), count: Int(sqlite3_column_bytes(stmt, i)))
                default: break
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func bind(_ params: [Any], to stmt: OpaquePointer?) {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case let s as String: sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case let n as Int64: sqlite3_bind_int64(stmt, idx, n)
            case let n as Int: sqlite3_bind_int64(stmt, idx, Int64(n))
            case let n as Int32: sqlite3_bind_int64(stmt, idx, Int64(n))
            case let d as Double: sqlite3_bind_double(stmt, idx, d)
            case let b as Bool: sqlite3_bind_int64(stmt, idx, b ? 1 : 0)
            case let data as Data: data.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
            default:
                // ⚠️ 走到这里说明调用方传了不支持的类型（最常见的是把 `[a,b]` 传给了
                //    变参 `exec`，见 `execArray` 的说明）。**必须吵**：静默绑 NULL
                //    会造成「删除失效 / 插入垃圾行」这类极难定位的数据损坏。
                print("[DB] ⚠️ 不支持的绑定类型（将绑成 NULL）: \(type(of: p))"
                      + " —— 若你传的是数组，请改用 execArray(_:_:)")
                sqlite3_bind_null(stmt, idx)
            }
        }
    }
}

extension Data {
    /// GBK 兼容辅助（占位避免未使用告警）
    var gbkSafe: Data { self }
}
