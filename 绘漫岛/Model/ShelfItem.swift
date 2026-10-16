import Foundation

/// 书架项（ARCHITECTURE §7.2：Model 层迁移 · 批次 3）。
///
/// ⚠️ 从 `ComicRepository` 的**嵌套类型**移出为**顶层类型**：
///    原先外部引用写作 `ComicRepository.ShelfItem`，迁移后统一为 `ShelfItem`
///    （同 module 内直接可见，`ComicRepository.shelfList()` 的返回类型也自动解析到这里）。
///
/// ⚠️ 字段名 / 类型 / **顺序**一律不变 —— `ComicRepository.shelfList` 里的
///    15 个参数构造调用必须继续成立（memberwise init 依赖顺序）。
///    纯数据、不访问数据库 / 网络 / UI。
struct ShelfItem: Identifiable, Hashable {
    var id: String { noteUrl }
    var noteUrl: String
    var name: String
    var origin: String
    var coverUrl: String
    var author: String
    var kind: String
    var lastChapterName: String
    var durChapterName: String
    var durChapterUrl: String
    var durChapterPage: Int
    var hasUpdate: Bool
    /// 新增章节数（从 `NEW_CHAPTERS` 的 JSON 数组长度算出）
    var newChapterCount: Int
    var groupId: Int64
    var variable: String
}
