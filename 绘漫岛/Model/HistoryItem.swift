import Foundation

/// 历史记录项（ARCHITECTURE §7.2：Model 层迁移 · 批次 1）。
///
/// ⚠️ 从 `UI/SearchView.swift` **原样移出**：
///    字段名 / 类型 / 顺序一律不变，构造调用点
///    `HistoryItem(noteUrl:name:coverUrl:origin:upTime:)` 不受影响。
///    纯数据、不访问数据库 / 网络 / UI。
struct HistoryItem: Identifiable {
    var id: String { noteUrl }
    let noteUrl: String
    let name: String
    let coverUrl: String
    let origin: String
    let upTime: Int64
}
