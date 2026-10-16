import Foundation

/// JS 类源的持久化（ARCHITECTURE §9.1）。
///
/// ⚠️ 设计要点：
///   • 与 JSON 规则源**分表**（`JS_SOURCE`），不混进 `COMIC_SOURCE_BEAN`。
///   • `MANIFEST_JSON` 存**完整 manifest 原文**，加字段无需迁移；
///     常用检索字段（ID/NAME/DOMAIN/ENABLED）冗余成列，供列表查询。
///   • 读出来的 manifest 一律**再过一遍 `validate()`** —— 库里的旧数据可能来自
///     更早的版本/被手工改过，不能假设它仍然合法（不合法就跳过，不崩）。
enum JSSourceStore {

    /// 列表项（列表页只需要这几个字段，不必解出整个 manifest）
    struct Item: Identifiable, Equatable {
        var id: String
        var name: String
        var version: String
        var domain: String
        var enabled: Bool
    }

    /// 列表项 + 运行时（列表页要打「可终止」徽章时才需要解 manifest）。
    /// 单独查询而不是塞进 `Item`：`Item` 只查 5 个冗余列，解 manifest 是额外成本，
    /// 只有确实要展示徽章的地方才付这个代价。
    static func runtime(forID id: String) -> JSSourceManifest.Runtime? {
        load(id: id)?.effectiveRuntime
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// 保存/更新（按 `id` upsert）。返回是否成功编码（manifest 必须可序列化）。
    @discardableResult
    static func save(_ manifest: JSSourceManifest, enabled: Bool = true) -> Bool {
        guard let data = try? encoder.encode(manifest),
              let json = String(data: data, encoding: .utf8) else { return false }
        Database.shared.exec(
            """
            INSERT OR REPLACE INTO JS_SOURCE
              (ID, NAME, VERSION, API_VERSION, DOMAIN, ENABLED, MANIFEST_JSON, ADD_TIME)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            manifest.id, manifest.name, manifest.version, manifest.apiVersion,
            manifest.domain, enabled ? 1 : 0, json, Int(Date().timeIntervalSince1970))
        // ⚠️ 与 `ComicRepository.saveSource` 对齐：**保存 = 复活**，必须撤掉墓碑。
        //    否则「删掉某 JS 源 → 重新导入同名 id」后墓碑仍在，
        //    下次双向合并会把这台设备刚导入的源判成「已删除」而清掉。
        TombstoneStore.clear(manifest.id, kind: .jssource)
        return true
    }

    /// 全部源（按名称排序）
    static func list() -> [Item] {
        Database.shared.query("SELECT ID, NAME, VERSION, DOMAIN, ENABLED FROM JS_SOURCE ORDER BY NAME")
            .compactMap { row in
                guard let id = row["ID"] as? String, !id.isEmpty else { return nil }
                return Item(id: id,
                            name: row["NAME"] as? String ?? "",
                            version: row["VERSION"] as? String ?? "",
                            domain: row["DOMAIN"] as? String ?? "",
                            enabled: (row["ENABLED"] as? Int64 ?? 1) != 0)
            }
    }

    /// 读取单个 manifest；**解码后必须通过 `validate()`**，否则视为不可用（返回 nil）。
    static func load(id: String) -> JSSourceManifest? {
        let rows = Database.shared.query("SELECT MANIFEST_JSON FROM JS_SOURCE WHERE ID = ?", [id])
        guard let json = rows.first?["MANIFEST_JSON"] as? String,
              let data = json.data(using: .utf8),
              let m = try? decoder.decode(JSSourceManifest.self, from: data),
              (try? m.validate()) != nil else { return nil }
        return m
    }

    /// 全部**启用**且合法的 manifest（供注册表批量装载）
    static func loadEnabled() -> [JSSourceManifest] {
        Database.shared.query("SELECT ID FROM JS_SOURCE WHERE ENABLED = 1")
            .compactMap { $0["ID"] as? String }
            .compactMap { load(id: $0) }
    }

    static func setEnabled(_ enabled: Bool, id: String) {
        Database.shared.exec("UPDATE JS_SOURCE SET ENABLED = ? WHERE ID = ?",
                             enabled ? 1 : 0, id)
    }

    /// 删除一条 JS 源，并**记下墓碑**。
    ///
    /// ⚠️ 为什么必须记墓碑：内置 JS 源会在版本升级时被**重导**一遍
    ///    （`HMDApp.importBuiltinJSSources`）。若无墓碑，用户手动删掉的内置源
    ///    会在下次升级时「删了又回来」—— 用户会认为 App 存不住状态。
    ///    与 JSON 规则源（`ComicRepository.deleteSources` → `TombstoneStore.markDeleted(_, .source)`）
    ///    保持同一套语义。
    static func remove(id: String) {
        // ⚠️ 必须用**变参**形式。写成 `exec(sql, [id])` 会把数组当单个参数
        //    → 占位符绑 NULL → `WHERE ID = NULL` 恒不匹配 → **删除静默失效**。
        Database.shared.exec("DELETE FROM JS_SOURCE WHERE ID = ?", id)
        TombstoneStore.markDeleted(id, kind: .jssource)
    }

    /// 仅删记录、**不记墓碑** —— 供「内置合集收缩、清理过时内置源」使用
    /// （`HMDApp` 里 `packIds` 那段）。
    ///
    /// 为什么不记墓碑：那不是用户的删除意愿，而是 App 自己的版本演进。
    /// 若在这里记墓碑，将来这个 id 被**重新加回内置合集**时，会被自己的墓碑挡住。
    static func removeWithoutTombstone(id: String) {
        Database.shared.exec("DELETE FROM JS_SOURCE WHERE ID = ?", id)
    }

    static func count() -> Int {
        (Database.shared.query("SELECT COUNT(*) AS C FROM JS_SOURCE").first?["C"] as? Int64).map(Int.init) ?? 0
    }
}
