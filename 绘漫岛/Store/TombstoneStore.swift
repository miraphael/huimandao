import Foundation

/// 删除墓碑（ARCHITECTURE §8.2 阶段 B · 批次 1）。
///
/// 记录「某条数据在某时刻被删除」，让双向合并时**不会把已删条目从远端旧备份里复活**。
/// 没有墓碑，删除信息在合并过程中必然丢失（远端有、本地没有 = 会被当成「新增」）。
///
/// ⚠️ 只记**稳定 ID**，不记内容 —— 墓碑本身不能成为隐私泄漏点。
enum TombstoneStore {

    /// 墓碑记录
    struct Tombstone: Equatable {
        var id: String
        var kind: String
        var deletedAt: Int
        var deviceID: String
    }

    /// 数据类别（与 DB `KIND` 列一致）
    enum Kind: String {
        case source = "source"   // id = bookSourceUrl
        case shelf  = "shelf"    // id = NOTE_URL
        case group  = "group"    // id = GROUP_NAME
        /// JS 源（id = `JSSourceManifest.id`）。
        /// ⚠️ 与 `source` 分开：JSON 规则源和 JS 源的 id 空间不同
        ///    （前者是 URL，后者是 `legado.xxx` 这类符号名），
        ///    混用会让「删了 JSON 源」把同名的 JS 源也判成已删。
        case jssource = "jssource"
    }

    /// 墓碑默认保留时长：90 天。
    /// ⚠️ 太短会导致「长期离线的设备」把已删数据复活；太长则墓碑无限增长。
    ///    90 天是「用户换设备/长期离线后回来同步」的常见上限。
    static let defaultRetentionDays = 90

    /// 记录一次删除（同一条重复删除会覆盖时间戳）。
    ///
    /// ⚠️ **时间单位必须是毫秒**（与 `COMIC_SHELF_BEAN.FINAL_DATE`、
    ///    `COMIC_SOURCE_BEAN.LAST_UPDATE_TIME` 一致）。
    ///    原先这里写的是**秒**，而 `applyRemoteTombstone` 拿本地毫秒时间戳去比：
    ///    `毫秒(1.7e12) <= 秒(1.7e9)` 恒为 false → **远端书架删除永远不生效**（漏删）；
    ///    而内置源的 `LAST_UPDATE_TIME` 常为 0 → `0 <= 秒` 恒真 → 源删除又能生效。
    ///    同一机制一半生效一半不生效，是极难定位的「同步行为不一致」。
    static func markDeleted(_ id: String, kind: Kind) {
        guard !id.isEmpty else { return }
        Database.shared.exec(
            "INSERT OR REPLACE INTO TOMBSTONE (ID, KIND, DELETED_AT, DEVICE_ID) VALUES (?,?,?,?)",
            id, kind.rawValue, nowMillis(), BackupManager.deviceID)
    }

    /// 当前毫秒时间戳（墓碑统一单位）
    static func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// 把可能来自旧版本（秒）或其它设备的时间戳**归一到毫秒**。
    ///
    /// 判据：合理毫秒时间戳 ≥ 1e12（2001 年之后）；小于这个量级的一律按「秒」放大。
    /// 这样新旧墓碑、新旧设备混用时比较仍然正确，不必强制清库。
    static func normalizeToMillis(_ raw: Int64) -> Int64 {
        raw > 0 && raw < 1_000_000_000_000 ? raw * 1000 : raw
    }

    /// 该条目是否已被删除（且墓碑仍有效）
    static func isDeleted(_ id: String, kind: Kind) -> Bool {
        !Database.shared.query(
            "SELECT 1 FROM TOMBSTONE WHERE ID = ? AND KIND = ? LIMIT 1",
            [id, kind.rawValue]).isEmpty
    }

    /// 全部墓碑（供上传/合并时一并携带）
    static func all() -> [Tombstone] {
        Database.shared.query("SELECT ID, KIND, DELETED_AT, DEVICE_ID FROM TOMBSTONE ORDER BY DELETED_AT")
            .compactMap { row in
                guard let id = row["ID"] as? String, let kind = row["KIND"] as? String else { return nil }
                return Tombstone(id: id, kind: kind,
                                 deletedAt: Int(row["DELETED_AT"] as? Int64 ?? 0),
                                 deviceID: row["DEVICE_ID"] as? String ?? "")
            }
    }

    /// 清理过期墓碑，返回删除条数。
    @discardableResult
    static func prune(retentionDays: Int = defaultRetentionDays) -> Int {
        // 单位与 `markDeleted` 对齐（毫秒）
        let cutoff = nowMillis() - Int64(retentionDays) * 86_400_000
        let before = count()
        // ⚠️ 必须用**变参**形式 `exec(sql, cutoff)`；写成 `exec(sql, [cutoff])`
        //    会把数组当单个参数 → 占位符绑 NULL → `DELETED_AT < NULL` 恒假 → 永不清理。
        Database.shared.exec("DELETE FROM TOMBSTONE WHERE DELETED_AT < ?", cutoff)
        return max(0, before - count())
    }

    /// 某条数据「复活」时调用（用户重新添加了同 ID 的源/书架）——
    /// 必须**撤掉墓碑**，否则下次合并又会被判成「已删除」。
    static func clear(_ id: String, kind: Kind) {
        // ⚠️ 同样必须用变参形式，见上。
        Database.shared.exec("DELETE FROM TOMBSTONE WHERE ID = ? AND KIND = ?", id, kind.rawValue)
    }

    static func count() -> Int {
        (Database.shared.query("SELECT COUNT(*) AS C FROM TOMBSTONE").first?["C"] as? Int64).map(Int.init) ?? 0
    }
}
