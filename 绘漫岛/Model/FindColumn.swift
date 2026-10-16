import Foundation

/// 发现栏目项（ARCHITECTURE §7.2：Model 层迁移 · 批次 2）。
///
/// ⚠️ 从 `ComicEngine` 的**嵌套类型**移出为**顶层类型**：
///    原先外部引用写作 `ComicEngine.FindColumn`，迁移后统一为 `FindColumn`
///    （同 module 内直接可见，ComicEngine 内部引用也自动解析到这里）。
///    字段名 / 类型 / 顺序一律不变，构造调用点不受影响。
///    纯数据、不访问数据库 / 网络 / UI。
struct FindColumn: Identifiable {
    var id: String { "\(origin)#\(title)#\(url)" }
    var title: String
    var url: String
    var origin: String
    var originName: String
    /// 栏目 URL 自带的 `@Header:{...}`（个别源需要，如 mh857）
    var headers: [String: String] = [:]
}
