import CryptoKit
import Foundation

/// ──────────────────────────────────────────────────────────────────────────
/// 图集收藏（image_favorites）—— 阅读时收藏单张图，之后可独立浏览
///
/// ## 与「离线下载」的区别（为什么不能复用 `LOCAL_CHAPTER`）
/// | | 离线下载 | 图集收藏 |
/// |---|---|---|
/// | 单位 | 整章 | 单张图 |
/// | 触发 | 用户批量选章 | 阅读时随手收藏 |
/// | 生命周期 | 看完就删 | 长期保留 |
/// | 目录 | `Documents/Downloads/<漫画>/<章节>/` | `Documents/Favorites/<id>.<ext>` |
/// 两者**分目录、分开清理** —— 删下载不能误删收藏，反之亦然。
///
/// ## 为什么主键不是图片 URL
/// 很多图站的图片地址带签名/时间戳（`?sign=…&t=…`），**下次打开就变了**；
/// 拿它当主键会导致「同一张图收藏两次出现两条」。
/// 所以稳定 ID 由 **图源 + 章节 URL + 页序号** 派生 —— 这三者在同一章里不变。
///
/// ⚠️ 本文件是**纯模型**：不碰数据库、不碰文件系统（文件路径由 `FavoriteStore` 拼）。
/// ---------------------------------------------------------------------------
struct FavoriteImage: Identifiable, Equatable {
    /// 稳定 ID：`sha256(origin|chapterUrl|index)` 前 16 位
    var id: String
    var origin: String
    var noteUrl: String
    var comicName: String
    var chapterUrl: String
    var chapterName: String
    /// 页序号（0 基）—— 用于「跳回原阅读位置」
    var imageIndex: Int
    /// 收藏时的图片地址（仅作回溯/诊断，可能过期，**不作为主键**）
    var imageURL: String
    /// 文件名（相对 `Documents/Favorites/`）
    var fileName: String
    var byteCount: Int
    var addedAt: Int64

    /// 从图源 + 章节 + 页序号派生稳定 ID。
    ///
    /// ⚠️ 三个输入都必须在同一章内**不变**：图源 URL、章节 URL、页序号。
    ///    图片 URL 会变（签名过期），章节名会变（站点改名），都不能用。
    static func makeID(origin: String, chapterUrl: String, index: Int) -> String {
        StableID.hash("\(origin)|\(chapterUrl)|\(index)", length: 16)
    }
}

/// 稳定 ID 工具 —— 需要「同样的输入永远得到同样的输出」的地方都用它。
enum StableID {
    /// SHA-256 十六进制前 `length` 位。
    ///
    /// 用 SHA-256 而不是 `hashValue`：Swift 的 `Hashable` 每个进程都会换种子，
    /// **重启后就变了**，拿它当持久化主键会导致「重启后收藏对不上」。
    static func hash(_ text: String, length: Int = 16) -> String {
        let hex = SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return String(hex.prefix(max(1, length)))
    }
}
