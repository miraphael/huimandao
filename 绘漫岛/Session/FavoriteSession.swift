import Combine
import Foundation

/// ──────────────────────────────────────────────────────────────────────────
/// 图集收藏 · 会话层
///
/// 负责「一次用户动作」的编排：取字节 → 落盘 → 刷新列表 → 给出提示。
/// 存储细节在 `FavoriteStore`，UI 只绑定本类的 `@Published`。
///
/// ## 为什么不把这段逻辑写在 View 里
/// 「收藏当前页」要跨三个东西：图片字节（`ChapterImageStore`）、
/// 文件+数据库（`FavoriteStore`）、提示文案（UI）。
/// 散在 View 里的话，阅读器与图集页会各写一遍，且错误提示容易漏。
/// ---------------------------------------------------------------------------
@MainActor
final class FavoriteSession: ObservableObject {
    static let shared = FavoriteSession()

    @Published private(set) var items: [FavoriteImage] = []
    @Published private(set) var busy = false
    /// 给用户的明确提示（不静默失败）
    @Published var message = ""

    private init() {
        reload()
    }

    // MARK: - 读

    /// 重新读库（收藏/取消后调用；列表页出现时也调一次）
    func reload() {
        items = FavoriteStore.shared.all()
    }

    var count: Int { items.count }

    var totalBytes: Int64 {
        items.reduce(Int64(0)) { $0 + Int64($1.byteCount) }
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    /// 按漫画分组（图集页展示用）
    func grouped() -> [(key: String, name: String, items: [FavoriteImage])] {
        var order: [String] = []
        var dict: [String: [FavoriteImage]] = [:]
        for item in items {
            let key = "\(item.origin)|\(item.noteUrl)"
            if dict[key] == nil { order.append(key); dict[key] = [] }
            dict[key]?.append(item)
        }
        return order.map { key in
            let list = dict[key] ?? []
            let name = list.first.flatMap { $0.comicName.isEmpty ? nil : $0.comicName } ?? "未命名"
            return (key: key, name: name, items: list)
        }
    }

    /// 该页是否已收藏（用于按钮状态）
    func isFavorite(origin: String, chapterUrl: String, index: Int) -> Bool {
        FavoriteStore.shared.contains(origin: origin, chapterUrl: chapterUrl, index: index)
    }

    // MARK: - 写

    /// 收藏阅读器当前页。
    ///
    /// - Parameter store: 阅读器的图片仓库 —— 字节从它那里取，保证与屏幕上看到的一致。
    @discardableResult
    func addCurrentPage(store: ChapterImageStore, index: Int,
                        origin: String, noteUrl: String, comicName: String,
                        chapterUrl: String, chapterName: String) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }

        // 已收藏 → 再点一次即取消（按钮语义与大多数阅读器一致）
        if FavoriteStore.shared.contains(origin: origin, chapterUrl: chapterUrl, index: index) {
            return removeByKey(origin: origin, chapterUrl: chapterUrl, index: index)
        }
        guard let data = await store.originalBytes(at: index) else {
            message = "收藏失败：这一页的图片还没下载好，等图出来再试"
            return false
        }
        let imageURL = store.url(at: index) ?? ""
        let saved = FavoriteStore.shared.add(
            origin: origin, noteUrl: noteUrl, comicName: comicName,
            chapterUrl: chapterUrl, chapterName: chapterName,
            imageIndex: index, imageURL: imageURL, data: data)
        guard saved != nil else {
            message = "收藏失败：写入本地文件出错（可能存储空间不足）"
            return false
        }
        reload()
        message = "已收藏第 \(index + 1) 页"
        return true
    }

    /// 按业务键取消收藏（不需要先查出 id）
    @discardableResult
    func removeByKey(origin: String, chapterUrl: String, index: Int) -> Bool {
        let id = FavoriteImage.makeID(origin: origin, chapterUrl: chapterUrl, index: index)
        FavoriteStore.shared.remove(id: id)
        reload()
        message = "已取消收藏"
        return false
    }

    func remove(id: String) {
        FavoriteStore.shared.remove(id: id)
        reload()
    }

    func removeAll() {
        FavoriteStore.shared.removeAll()
        reload()
        message = "已清空图集收藏"
    }

    /// 清理孤儿文件（崩溃留下的「有文件没记录」）
    @discardableResult
    func pruneOrphans() -> Int {
        let n = FavoriteStore.shared.pruneOrphanFiles()
        reload()
        message = n > 0 ? "清理了 \(n) 个残留文件" : "没有需要清理的残留文件"
        return n
    }
}
