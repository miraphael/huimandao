import Foundation

/// ──────────────────────────────────────────────────────────────────────────
/// 备份 —— 对应 BackupActivity：WebDAV(URL/账号/密码) + 本地导出/恢复
///
/// ## 安全设计（为什么不是简单的「整库覆盖」）
/// 备份恢复是**破坏性操作**：一次误操作就能把用户攒了几个月的书架冲掉。
/// 所以这里做了三层保护：
///   ① **版本化信封**（`schemaVersion`）：遇到比当前 App 更新的格式**拒绝写入**，
///      而不是把不认识的字段悄悄丢掉。
///   ② **恢复前自动本地快照**：`Documents/backup_snapshots/<时间戳>.json`。
///      恢复错了可以回滚 —— 不需要用户提前手动备份。
///   ③ **只合并、不清空**：恢复按 `bookSourceUrl` / `NOTE_URL` 对齐 upsert，
///      不删用户现有的任何源或书架条目。
///
/// ⚠️ 当前仍是「快照式」备份，**不是**冲突安全的双向同步。
///    多设备同时改同一份数据时以最后一次为准 —— 真正的双向合并
///    （墓碑、ETag/If-Match、字段级 merge）见 ARCHITECTURE.md §8.2 阶段 B。
/// ---------------------------------------------------------------------------
enum BackupManager {

    /// 当前信封版本。新增**不兼容**字段时才 +1。
    static let schemaVersion = 1

    // MARK: - 信封

    struct Payload {
        var sources: [ComicSource] = []
        var shelf: [[String: Any]] = []
        var groups: [[String: Any]] = []
        /// 删除墓碑（§8.2 阶段 B）—— 没有它，「删除」信息在合并中会丢失，
        /// 已删的源/书会被远端旧备份「复活」。
        var tombstones: [[String: Any]] = []

        func encode() -> Data? {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let s = try? enc.encode(sources) else { return nil }
            let sh = (try? JSONSerialization.data(withJSONObject: shelf)) ?? Data("[]".utf8)
            let gr = (try? JSONSerialization.data(withJSONObject: groups)) ?? Data("[]".utf8)
            let tb = (try? JSONSerialization.data(withJSONObject: tombstones)) ?? Data("[]".utf8)
            let head: [String: Any] = [
                "schemaVersion": BackupManager.schemaVersion,
                "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                "deviceID": BackupManager.deviceID,
                "createdAt": Int(Date().timeIntervalSince1970),
            ]
            let hd = (try? JSONSerialization.data(withJSONObject: head)) ?? Data("{}".utf8)
            let json = """
            {"meta":\(String(data: hd, encoding: .utf8) ?? "{}"),\
            "sources":\(String(data: s, encoding: .utf8) ?? "[]"),\
            "shelf":\(String(data: sh, encoding: .utf8) ?? "[]"),\
            "groups":\(String(data: gr, encoding: .utf8) ?? "[]"),\
            "tombstones":\(String(data: tb, encoding: .utf8) ?? "[]")}
            """
            return json.data(using: .utf8)
        }
    }

    /// 设备标识 —— 用于「这份备份是谁写的」。首次调用生成并持久化。
    static var deviceID: String {
        let key = "hmd_device_id"
        if let v = UserDefaults.standard.string(forKey: key), !v.isEmpty { return v }
        let v = String(UUID().uuidString.prefix(8)).lowercased()
        UserDefaults.standard.set(v, forKey: key)
        return v
    }

    static func makePayload() -> Payload {
        var p = Payload()
        p.sources = ComicRepository.shared.allSources()
        p.shelf = Database.shared.query("SELECT * FROM COMIC_SHELF_BEAN")
        p.groups = Database.shared.query("SELECT * FROM COMIC_SHELF_GROUP_BEAN")
        // 带上删除墓碑，让「删除」能随备份传播到其他设备（§8.2 阶段 B）
        p.tombstones = TombstoneStore.all().map {
            ["id": $0.id, "kind": $0.kind, "deletedAt": $0.deletedAt, "deviceID": $0.deviceID]
        }
        return p
    }

    // MARK: - 恢复

    struct RestoreReport {
        var sources = 0
        var shelf = 0
        var groups = 0
        var schemaVersion = 0
        var deviceID = ""
        var createdAt: Date?
        /// 非致命问题（例如个别条目格式不对被跳过）
        var warnings: [String] = []
        var ok: Bool { sources + shelf + groups > 0 }
        /// 格式比当前 App 新 → 拒绝恢复
        var tooNew: Bool { schemaVersion > BackupManager.schemaVersion }

        var summary: String {
            var parts = ["图源 \(sources)", "书架 \(shelf)"]
            if groups > 0 { parts.append("分组 \(groups)") }
            return parts.joined(separator: " · ")
        }

        var origin: String {
            let when = createdAt.map {
                DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short)
            } ?? "未知时间"
            let who = deviceID.isEmpty ? "未知设备" : deviceID
            return "备份来自 \(who) · \(when) · 格式 v\(schemaVersion)"
        }
    }

    /// 只解析不写入 —— 给 UI 做「恢复前预览/确认」用。
    ///
    /// ⚠️ 绝不在这里动数据库：用户点「恢复」之前，任何写入都是越权。
    static func inspect(_ text: String) -> RestoreReport {
        var r = RestoreReport()
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            r.warnings.append("不是合法的 JSON 备份文件")
            return r
        }
        if let meta = obj["meta"] as? [String: Any] {
            r.schemaVersion = (meta["schemaVersion"] as? NSNumber)?.intValue ?? 0
            r.deviceID = meta["deviceID"] as? String ?? ""
            if let t = (meta["createdAt"] as? NSNumber)?.doubleValue, t > 0 {
                r.createdAt = Date(timeIntervalSince1970: t)
            }
        }
        // 兼容没有 meta 的老备份：视为 v1
        if r.schemaVersion == 0 { r.schemaVersion = 1 }
        r.sources = (obj["sources"] as? [[String: Any]])?.count ?? 0
        r.shelf = (obj["shelf"] as? [[String: Any]])?.count ?? 0
        r.groups = (obj["groups"] as? [[String: Any]])?.count ?? 0
        if r.tooNew {
            r.warnings.append("备份格式 v\(r.schemaVersion) 比当前 App 支持的 v\(schemaVersion) 新，已拒绝恢复")
        }
        return r
    }

    /// 恢复（**合并 upsert，不清空**）。
    ///
    /// - Parameter ignoringVersionGate: 仅供 `rollback` 使用 —— 本地快照跳过版本门禁
    ///   （详见 `rollback` 处的说明）。外部恢复一律用默认值 `false`。
    /// 图源是否含「可执行」规则（JS / WebView）。
    ///
    /// 🔴 为什么要单独检：图源规则不只是「取数据」—— `@js:` / `<js>` / `@web:`
    ///    会在 App 里**执行代码 / 加载真实 WebView**。恢复一个来历不明的备份
    ///    等于直接把这些源导进来，之后搜索/阅读就会执行它们的 JS
    ///    （「导入即代码执行」）。
    ///    目前只**告警不阻止** —— 挡住正常备份的代价更高。
    ///    （由智能体「规则漏洞B」发现）
    private static func suspiciousSourceReason(_ s: ComicSource) -> String? {
        var why: [String] = []
        // 把所有 String 型字段拼起来粗查一次（恢复时才跑，成本可忽略）
        var blob = ""
        for child in Mirror(reflecting: s).children {
            if let v = child.value as? String { blob += v }
        }
        if blob.contains("<js>") { why.append("<js> 块") }
        if blob.contains("@js:") { why.append("@js: 段") }
        if blob.contains("@web:") || blob.contains("@webm:") { why.append("@web: WebView") }
        return why.isEmpty ? nil : why.joined(separator: "、")
    }

    /// 恢复（**合并 upsert，不清空**）。
    ///
    /// - Parameter ignoringVersionGate: 仅供 `rollback` 使用 —— 本地快照跳过版本门禁
    ///   （详见 `rollback` 处的说明）。外部恢复一律用默认值 `false`。
    @discardableResult
    static func restore(from text: String, ignoringVersionGate: Bool = false) -> RestoreReport {
        var r = inspect(text)
        guard ignoringVersionGate || !r.tooNew else { return r }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return r
        }
        // ── 先应用远端墓碑（§8.2 阶段 B）──
        // ⚠️ 必须**先删后导**：否则刚导入的条目又会被随后的删除抹掉（白做一遍）。
        if let tbs = obj["tombstones"] as? [[String: Any]] {
            for t in tbs {
                guard let id = t["id"] as? String, !id.isEmpty,
                      let kind = t["kind"] as? String else { continue }
                let remoteAt = (t["deletedAt"] as? NSNumber)?.intValue ?? 0
                applyRemoteTombstone(id: id, kind: kind, remoteDeletedAt: remoteAt)
            }
        }
        var srcCount = 0, shelfCount = 0, groupCount = 0
        if let arr = obj["sources"] as? [[String: Any]] {
            for item in arr {
                guard let data = try? JSONSerialization.data(withJSONObject: item),
                      let s = try? JSONDecoder().decode(ComicSource.self, from: data) else {
                    r.warnings.append("跳过 1 条无法解析的图源")
                    continue
                }
                var s2 = s
                s2.decryptRules(sourceUrl: s2.bookSourceUrl)
                // 🔴 警告必须在**解密之后**跑 —— `:_` 前缀的加密规则（`SourceCodec`）
                //    解密后才露出 `@js:` / `<js>`，在解密前扫描看到的是密文，等于没检。
                //    （由智能体「安全终审」发现）
                if let why = Self.suspiciousSourceReason(s2) {
                    r.warnings.append("⚠️ 图源「\(s2.bookSourceName)」含可执行规则（\(why)），已导入但请留意")
                }
                ComicRepository.shared.saveSource(s2)
                srcCount += 1
            }
        }
        if let shelf = obj["shelf"] as? [[String: Any]] {
            // 本地墓碑（用户在本机删过的书）——导入时**不要**把它们复活。
            // `applyRemoteTombstone` 已先跑过一轮，但它只处理「备份里带墓碑」的情况；
            // 若备份来自一台「删了这本书但墓碑没上传」的设备，这里仍需本地墓碑兜底。
            let localShelfTomb = Set(
                TombstoneStore.all()
                    .filter { $0.kind == TombstoneStore.Kind.shelf.rawValue }
                    .map(\.id))
            for row in shelf {
                guard let url = row["NOTE_URL"] as? String else { continue }
                guard !localShelfTomb.contains(url) else { continue }
                // ⚠️ 这里**不能**用 8 列的 `INSERT OR REPLACE`：
                //    `INSERT OR REPLACE` 的语义是「整行替换」——未列出的列会被写成
                //    NULL/默认值。原实现只写 8 列，于是每次恢复备份都会把
                //    `DUR_CHAPTER_URL` / `DUR_CHAPTER_PAGE`（阅读进度）、`READ_MODE`
                //    （阅读模式）、`VARIABLE`、`NEW_CHAPTERS`、`ALLOW_UPDATE` 等
                //    **全部清零** —— 用户恢复完备份，书架里每本书都「回到第一页」。
                //    （`addToShelf` 用 `ON CONFLICT DO UPDATE` 躲过了这个坑，恢复路径没有。）
                //
                //    改为 `ON CONFLICT(NOTE_URL) DO UPDATE SET`：**按字段合并**。
                //    仅当 payload 里**确实带了这个键**时才覆盖 —— 这样新旧备份都能用，
                //    老备份（缺列）不会把本地进度抹掉。
                let cols: [(String, Any?)] = [
                    ("NAME", row["NAME"]),
                    ("ORIGIN", row["ORIGIN"]),
                    ("COVER_URL", row["COVER_URL"]),
                    ("AUTHOR", row["AUTHOR"]),
                    ("KIND", row["KIND"]),
                    ("LAST_CHAPTER_NAME", row["LAST_CHAPTER_NAME"]),
                    ("GROUP_ID", row["GROUP_ID"]),
                    // 阅读进度相关：payload 里有才覆盖（保住用户「读到哪」）
                    ("DUR_CHAPTER_URL", row["DUR_CHAPTER_URL"]),
                    ("DUR_CHAPTER_NAME", row["DUR_CHAPTER_NAME"]),
                    ("DUR_CHAPTER_PAGE", row["DUR_CHAPTER_PAGE"]),
                    ("READ_MODE", row["READ_MODE"]),
                    ("FINAL_DATE", row["FINAL_DATE"]),
                    ("HAS_UPDATE", row["HAS_UPDATE"]),
                    ("NEW_CHAPTERS", row["NEW_CHAPTERS"]),
                    ("ALLOW_UPDATE", row["ALLOW_UPDATE"]),
                    ("SERIAL_NUMBER", row["SERIAL_NUMBER"]),
                    ("VARIABLE", row["VARIABLE"]),
                    ("FINAL_REFRESH_DATA", row["FINAL_REFRESH_DATA"]),
                    ("CHAPTER_LIST_SIZE", row["CHAPTER_LIST_SIZE"]),
                    ("CUSTOM_COVER_PATH", row["CUSTOM_COVER_PATH"]),
                ]
                Self.upsertShelfRow(noteUrl: url, cols: cols)
                shelfCount += 1
            }
        }
        if let groups = obj["groups"] as? [[String: Any]] {
            for row in groups {
                guard let name = row["GROUP_NAME"] as? String, !name.isEmpty else { continue }
                Database.shared.exec(
                    "INSERT OR IGNORE INTO COMIC_SHELF_GROUP_BEAN (GROUP_NAME, GROUP_NUMBER, GROUP_SORT, GROUP_VIEW, ENABLE) VALUES (?,?,?,?,?)",
                    name, row["GROUP_NUMBER"] ?? 0, row["GROUP_SORT"] ?? 0,
                    row["GROUP_VIEW"] ?? 0, row["ENABLE"] ?? 1)
                groupCount += 1
            }
        }
        r.sources = srcCount
        r.shelf = shelfCount
        r.groups = groupCount
        return r
    }

    /// 按需合并一行书架记录（`ON CONFLICT(NOTE_URL) DO UPDATE SET`）。
    ///
    /// 只有 `cols` 中**值非 nil** 的列才会参与 —— 键不在 payload 里就保持本地原值，
    /// 避免用「缺列的老备份」把本地阅读进度抹成 NULL。
    private static func upsertShelfRow(noteUrl: String, cols: [(String, Any?)]) {
        let present = cols.filter { $0.1 != nil }
        guard !present.isEmpty else { return }
        let names = present.map { $0.0 }
        let placeholders = Array(repeating: "?", count: names.count).joined(separator: ",")
        let sets = names.map { "\($0)=excluded.\($0)" }.joined(separator: ",")
        let sql = """
            INSERT INTO COMIC_SHELF_BEAN (NOTE_URL, \(names.joined(separator: ",")))
            VALUES (?, \(placeholders))
            ON CONFLICT(NOTE_URL) DO UPDATE SET \(sets)
            """
        // ⚠️ 参数个数在运行期才知道 → 必须用**数组版** `execArray`。
        //    写成 `exec(sql, [noteUrl] + …)` 会把整个数组当**单个**参数，
        //    占位符全绑 NULL → 插入一行全 NULL 的垃圾行、真行一条都没更新（静默假成功）。
        let args: [Any] = [noteUrl] + present.map { $0.1! }
        Database.shared.execArray(sql, args)
    }

    /// 应用一条远端墓碑：**只有远端删除时间不早于本地条目时间**时才删本地条目。
    ///
    /// ⚠️ 为什么要比时间：墓碑可能比本地数据**旧**（本地在墓碑之后又更新过 ——
    ///    例如在另一台设备删了、在这台又继续读了这本书）。直接按墓碑删会**误删用户数据**。
    /// 删除走 `ComicRepository` 的删除入口 → 会**记下本地墓碑**，让删除继续传播出去。
    @discardableResult
    private static func applyRemoteTombstone(id: String, kind: String, remoteDeletedAt: Int) -> Bool {
        // ⚠️ 单位归一：远端墓碑可能来自旧版本（秒）或其它设备，本地时间戳一律是毫秒。
        //    不归一的话「毫秒 <= 秒」恒假 → 远端删除永不生效（见 TombstoneStore 的说明）。
        let remoteAt = TombstoneStore.normalizeToMillis(Int64(remoteDeletedAt))
        switch kind {
        case "source":
            let rows = Database.shared.query(
                "SELECT LAST_UPDATE_TIME FROM COMIC_SOURCE_BEAN WHERE BOOK_SOURCE_URL = ?", [id])
            guard let localTime = (rows.first?["LAST_UPDATE_TIME"] as? NSNumber)?.int64Value else {
                return false   // 本地没有这条 → 无需删除
            }
            // 本地时间戳为 0（内置源常见）→ 视为「从未更新」，允许墓碑生效
            guard localTime == 0 || localTime <= remoteAt else { return false }
            ComicRepository.shared.deleteSources(urls: [id])
            return true
        case "shelf":
            let rows = Database.shared.query(
                "SELECT FINAL_DATE FROM COMIC_SHELF_BEAN WHERE NOTE_URL = ?", [id])
            guard let localTime = (rows.first?["FINAL_DATE"] as? NSNumber)?.int64Value else {
                return false
            }
            guard localTime == 0 || localTime <= remoteAt else { return false }
            ComicRepository.shared.removeFromShelf(noteUrl: id)
            return true
        case TombstoneStore.Kind.jssource.rawValue:
            // JS 源删除同样要能随备份传播（此前没有这个分支 → 删了会在另一台复活）
            JSSourceStore.remove(id: id)
            return true
        case TombstoneStore.Kind.group.rawValue:
            // 分组墓碑：按名字删（group 的 id 就是 GROUP_NAME）
            Database.shared.exec("DELETE FROM COMIC_SHELF_GROUP_BEAN WHERE GROUP_NAME = ?", id)
            return true
        default:
            return false
        }
    }

    // MARK: - 本地快照（恢复前的回滚点）

    static func snapshotsDir() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("backup_snapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 把**当前**数据写成一个本地快照，返回文件 URL。
    ///
    /// 调用时机：任何一次「从云端/文件恢复」之前。恢复错了可以回滚，
    /// 用户不需要提前手动备份。
    @discardableResult
    static func makeSnapshot(reason: String = "before-restore") -> URL? {
        guard let data = makePayload().encode() else { return nil }
        let ts = Int(Date().timeIntervalSince1970)
        let url = snapshotsDir().appendingPathComponent("\(ts).json")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        pruneSnapshots(keep: 5)
        return url
    }

    /// 只保留最近 `keep` 份快照，避免长期占用空间。
    @discardableResult
    static func pruneSnapshots(keep: Int = 5) -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: snapshotsDir(),
                                                      includingPropertiesForKeys: nil) else { return 0 }
        let sorted = files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }   // 文件名是时间戳 → 倒序
        var removed = 0
        for f in sorted.dropFirst(max(0, keep)) {
            try? fm.removeItem(at: f)
            removed += 1
        }
        return removed
    }

    static func snapshots() -> [URL] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: snapshotsDir(), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// 回滚到某个本地快照。
    @discardableResult
    static func rollback(to url: URL) -> RestoreReport {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            var r = RestoreReport()
            r.warnings.append("快照文件读不出来")
            return r
        }
        // ⚠️ 快照是本机自己写的，**格式不可能比当前 App 新**。
        //    若走正常 `restore`，它会因 `tooNew` 提前返回、什么都不做 ——
        //    回滚就成了**静默失败**：用户以为「回滚了」，实际数据一点没变
        //    （比报错更糟 —— 用户会基于错误前提继续操作）。
        //    所以回滚**跳过版本门禁**（`ignoringVersionGate: true`），
        //    但仍把这件事如实记进 warnings，不静默。
        var r = restore(from: text, ignoringVersionGate: true)
        if r.schemaVersion > schemaVersion {
            r.warnings.append("快照标记为 v\(r.schemaVersion)（高于当前 v\(schemaVersion)）——"
                              + "本地快照按定义可信，已忽略版本检查并执行回滚")
        }
        return r
    }

    // MARK: - WebDAV

    /// 云端备份文件名（latest 指针）
    static let remoteLatest = "hmd_ios_backup.json"

    /// 上次成功读写 latest 时服务端给的 ETag（**并发写保护**的依据）。
    ///
    /// 为什么内存里也要留一份：`If-Match` 需要「我上次看到的版本」。
    /// 只在同一进程内做「上传前先 HEAD 一把」是不够的 ——
    /// 两次上传之间如果别的设备改过，中间那段时间的差异必须能被发现。
    private static var latestETag: String?

    /// 记录最近一次冲突，供 UI 提示用户「云端被别的设备改过」。
    private(set) static var lastConflict: String?

    /// 解除冲突标记（用户选择「从云端恢复」= 接受远端版本后调用）。
    static func clearConflict() { lastConflict = nil }

    /// 上传：**先写版本文件，再更新 latest**。
    ///
    /// ## 为什么不能直接覆盖 latest
    /// 上传中途断网/失败会把**唯一一份**备份写坏。
    /// 先落一份带时间戳的版本文件（它失败了 latest 还是旧的），
    /// 成功后再更新 latest —— 任何时刻都至少有一份完整备份。
    ///
    /// ## 并发写保护（阶段 B）
    /// latest 的更新走 **`If-Match: <ETag>`** 条件请求：
    ///   • 我们手上有 ETag → 带上；服务端版本不一致就返回 **412**，
    ///     说明别的设备在我们读取之后改过 latest，此时**不覆盖**，报冲突。
    ///   • 我们手上没有 ETag（首次上传）→ 用 **`If-None-Match: *`**，
    ///     只有云端确实不存在时才允许创建；已存在则说明有别的设备先写过，
    ///     同样按冲突处理（先把服务端的 ETag 拉回来，不盲目覆盖）。
    ///
    /// ⚠️ 很多轻量 WebDAV 服务端**不实现** ETag 条件请求（忽略 If-Match 直接写）。
    ///    所以这里把「拿不到 ETag」当作正常情况处理，不阻断上传 ——
    ///    有保护更好，没有保护也不能因此让备份功能完全不能用。
    static func webdavBackup(cfg: (url: String, user: String, pass: String)) async -> (ok: Bool, detail: String) {
        guard let data = makePayload().encode() else { return (false, "本地数据编码失败") }
        let versioned = "hmd_ios_backup_\(Int(Date().timeIntervalSince1970)).json"
        let v = await webdavPut(path: versioned, data: data, cfg: cfg)
        // ⚠️ `webdavPut` 返回的是 `PutResult` 枚举（success/preconditionFailed/failed），
        //    **不是 Bool** —— 写成 `guard v else` 是编译错误
        //    （cannot convert value of type 'PutResult' to expected condition type 'Bool'）。
        //    版本文件是「仅创建」语义（无 If-Match），所以只要不是 failed 就算成功；
        //    `preconditionFailed` 在这里理论上不会出现（没传任何条件头）。
        guard case .success = v else { return (false, "上传版本备份失败（检查地址/账号/网络）") }

        // ── latest：条件写入 ─────────────────────────────────────────
        // 先探一次当前 ETag（没有就说明服务端不支持，或文件还不存在）
        if latestETag == nil {
            latestETag = await webdavETag(path: remoteLatest, cfg: cfg)
        }
        let res = await webdavPut(path: remoteLatest, data: data, cfg: cfg,
                                  ifMatch: latestETag, ifNoneMatch: latestETag == nil ? "*" : nil)
        switch res {
        case .success(let etag):
            latestETag = etag
            lastConflict = nil
            return (true, "已上传 \(versioned) 并更新 latest")
        case .preconditionFailed:
            // 云端在我们读取之后被改过 —— 不覆盖，明确报冲突
            let fresh = await webdavETag(path: remoteLatest, cfg: cfg)
            lastConflict = "云端 latest 已被其它设备修改（本地 ETag \(latestETag ?? "无") → "
                         + "服务端 \(fresh ?? "未知")）。为避免覆盖他人的备份，本次未写入 latest。"
            // 拉回新 ETag，让用户「重试」时能基于最新版本写
            latestETag = fresh
            return (false, "云端已被其它设备修改，未覆盖。版本文件 \(versioned) 已安全落盘。")
        case .failed:
            return (false, "版本文件已上传，但更新 latest 失败")
        }
    }

    /// `webdavPut` 的结果。比 `Bool` 多一档 `preconditionFailed` ——
    /// 「条件不满足」必须与「网络/权限失败」区分：前者要提示冲突，后者要提示检查配置。
    enum PutResult {
        case success(String?)        // 关联值：服务端返回的新 ETag
        case preconditionFailed      // 412 / 409：条件写被判不通过
        case failed
    }

    /// WebDAV 地址必须是 **https**。
    ///
    /// 🔴 `Info.plist` 里的 `NSAllowsArbitraryLoads=true` 是**故意的** ——
    ///    大量图源只有明文 http，关掉就整站打不开。
    ///    但备份走的是 **HTTP Basic 认证**，明文 http 等于把账号密码
    ///    原样送给链路上的任何人（同一 WiFi 就能抓）。所以这里单独收紧：
    ///    非 https 直接拒绝，并在 UI 层提示用户改地址。
    ///    （由智能体「守卫」发现）
    private static func secureBase(_ raw: String) -> URL? {
        guard let u = URL(string: raw), u.scheme?.lowercased() == "https" else { return nil }
        return u
    }

    static func webdavPut(path: String, data: Data,
                          cfg: (url: String, user: String, pass: String),
                          ifMatch: String? = nil,
                          ifNoneMatch: String? = nil) async -> PutResult {
        guard var base = Self.secureBase(cfg.url) else { return .failed }
        base.appendPathComponent(path)
        var req = URLRequest(url: base)
        req.httpMethod = "PUT"
        let auth = Data("\(cfg.user):\(cfg.pass)".utf8).base64EncodedString()
        req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        // 条件头：二者只用其一（`If-Match` 用于更新已知版本，`If-None-Match: *` 用于仅创建）
        if let ifMatch { req.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
        if let ifNoneMatch { req.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match") }
        req.httpBody = data
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .failed }
            switch http.statusCode {
            case 200, 201, 204:
                // 服务端可能在响应头里回新 ETag；没有就保留旧的（下次仍能用）
                let etag = http.value(forHTTPHeaderField: "ETag") ?? ifMatch
                return .success(etag)
            case 412, 409:
                return .preconditionFailed
            default:
                return .failed
            }
        } catch { return .failed }
    }

    /// 取远端文件的 ETag（`HEAD`）；服务端不支持 HEAD/ETag 时返回 nil。
    ///
    /// ⚠️ 用 `HEAD` 而不是 `GET` —— 备份文件可能几 MB，为了一个版本号把整个文件
    ///    拉下来毫无必要。不支持 HEAD 的服务端会返回 405，此时退回 `GET` 只读头部。
    static func webdavETag(path: String, cfg: (url: String, user: String, pass: String)) async -> String? {
        guard var base = Self.secureBase(cfg.url) else { return nil }
        base.appendPathComponent(path)
        let auth = Data("\(cfg.user):\(cfg.pass)".utf8).base64EncodedString()

        func probe(_ method: String) async -> String? {
            var req = URLRequest(url: base)
            req.httpMethod = method
            req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
            // GET 时不要正文，只为拿头
            req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) || http.statusCode == 206 else { return nil }
                return http.value(forHTTPHeaderField: "ETag")
            } catch { return nil }
        }
        if let e = await probe("HEAD") { return e }
        // 405/Method Not Allowed 等 → 用带 Range 的 GET 再试一次
        return await probe("GET")
    }

    static func webdavGet(path: String, cfg: (url: String, user: String, pass: String)) async -> String? {
        guard var base = Self.secureBase(cfg.url) else { return nil }
        base.appendPathComponent(path)
        var req = URLRequest(url: base)
        req.httpMethod = "GET"
        let auth = Data("\(cfg.user):\(cfg.pass)".utf8).base64EncodedString()
        req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            // 顺手记住 ETag —— 下载后紧接着上传时就能带上正确的 If-Match
            if let http = resp as? HTTPURLResponse,
               let e = http.value(forHTTPHeaderField: "ETag") {
                latestETag = e
            }
            return String(data: data, encoding: .utf8)
        } catch { return nil }
    }
}
