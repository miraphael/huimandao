import Foundation
import SwiftUI

/// ──────────────────────────────────────────────────────────────────────────
/// 追更（follow_updates）—— 检查书架里的漫画有没有新章节。
///
/// 对齐参考实现：Venera `features/follow_updates`、Aidoku `LibraryUpdateManager`。
///
/// ## 为什么单独抽一个引擎
/// 旧实现在 `ShelfView.refreshUpdates()` 里，只有 20 行，而且只做了一件事：
/// 比对「最新章节名」→ 不同就置 `HAS_UPDATE=1`。三个缺陷：
///   ① **不知道新增了几章** —— 用户只看到一个红点，不知道是 1 章还是 50 章
///   ② **不能批量操作** —— 红点只能一本本点开清掉
///   ③ **没有自动追更** —— 必须手动点刷新，而没人会记得点
/// 抽成引擎后这三件事都有明确归属，也能被「设置」页复用。
///
/// ## 数据落在哪
/// 复用建表时就有的 `COMIC_SHELF_BEAN.NEW_CHAPTERS`（安卓原版也用它）——
/// 存的是**新增章节的 JSON 数组**而不只是数量，这样详情页可以直接把
/// 「新增的那几章」列出来，而不是让用户自己去找。
/// ⚠️ 老库没有这列 → `Database.migrate()` 里有 ALTER TABLE 补列。
/// ──────────────────────────────────────────────────────────────────────────
@MainActor
final class FollowUpdater: ObservableObject {
    static let shared = FollowUpdater()

    // MARK: - 状态（UI 直接观察）

    @Published private(set) var running = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    /// 上一次追更的结果文案（书架页直接显示）
    @Published private(set) var lastMessage = ""

    // MARK: - 配置

    private let lastRunKey = "hmd_last_follow_time"
    private let intervalKey = "hmd_follow_interval_hours"
    private let autoKey = "hmd_follow_auto"

    private init() {}

    /// 距上次追更过了多久（没有记录 → 返回极大值，即「该跑了」）
    var sinceLastRun: TimeInterval {
        let t = UserDefaults.standard.double(forKey: lastRunKey)
        guard t > 0 else { return .greatestFiniteMagnitude }
        return Date().timeIntervalSince1970 - t
    }

    /// 自动追更间隔（小时，默认 6）
    var autoIntervalHours: Double {
        get {
            let h = UserDefaults.standard.double(forKey: intervalKey)
            return h > 0 ? h : 6
        }
        set { UserDefaults.standard.set(max(1, newValue), forKey: intervalKey) }
    }

    /// 是否启用自动追更。
    /// ⚠️ 单独一个开关而不是「间隔设 0 = 关闭」——
    ///    `autoIntervalHours` 的 getter 会把 0 兜底成 6，没法表达「关闭」。
    var autoEnabled: Bool {
        UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true
    }

    /// 现在该不该自动跑一次
    var shouldAutoRun: Bool { autoEnabled && sinceLastRun > autoIntervalHours * 3600 }

    /// 上次追更的展示文案（「刚刚 / 3 小时前 / 从未」）
    var lastRunText: String {
        let t = sinceLastRun
        if t == .greatestFiniteMagnitude { return "从未" }
        if t < 60 { return "刚刚" }
        if t < 3600 { return "\(Int(t / 60)) 分钟前" }
        if t < 86400 { return "\(Int(t / 3600)) 小时前" }
        return "\(Int(t / 86400)) 天前"
    }

    // MARK: - 主流程

    /// 检查书架里所有漫画的新章节。
    ///
    /// - Returns: 有更新的漫画本数
    @discardableResult
    func checkAll() async -> Int {
        guard !running else { return 0 }
        let items = ComicRepository.shared.shelfList()
        guard !items.isEmpty else {
            lastMessage = "书架是空的"
            return 0
        }
        running = true
        done = 0
        total = items.count
        defer { running = false }

        let threads = max(1, min(AppSettings.shared.refreshThreads, 8))
        var updated = 0

        await withTaskGroup(of: Bool.self) { group in
            var active = 0
            var it = items.makeIterator()
            func fill() {
                while active < threads, let i = it.next() {
                    active += 1
                    group.addTask { await Self.checkOne(i) }
                }
            }
            fill()
            for await hasNew in group {
                active -= 1
                if hasNew { updated += 1 }
                done += 1
                fill()
            }
        }

        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastRunKey)
        lastMessage = updated > 0 ? "\(updated) 本有更新" : "全部已是最新"
        NotificationCenter.default.post(name: .hmdShelfChanged, object: nil)
        return updated
    }

    /// 检查单本。
    ///
    /// ⚠️ 两个关键点（写错任何一个都会得到「全都算更新」的错误结果）：
    ///   ① 必须用**完整**详情（不能 `skipPagination`）——
    ///      追更就是要拿到全量章节，新增的那几章很可能在第二页。
    ///   ② 读旧章节列表必须传 `maxAge: 0`（不过期）——
    ///      默认 6 小时过期会返回 nil，于是**整本漫画的章节都会被当成新增**。
    nonisolated private static func checkOne(_ item: ShelfItem) async -> Bool {
        let info = await ComicEngine.shared.detail(noteUrl: item.noteUrl, origin: item.origin)
        guard !info.chapters.isEmpty else { return false }

        let old = ComicRepository.shared.loadChapters(noteUrl: item.noteUrl, maxAge: 0) ?? []
        let oldURLs = Set(old.map(\.url))
        let fresh = info.chapters.filter { !oldURLs.contains($0.url) }

        // 无论有没有新增都落库：下次点书架可以零网络直开
        ComicRepository.shared.saveChapters(noteUrl: item.noteUrl, chapters: info.chapters)

        guard !fresh.isEmpty else {
            // 没有新增 → 顺手清掉可能残留的标记
            // （站点删章 / 改章节 URL 时会留下假的红点）
            if item.hasUpdate { ComicRepository.shared.clearUpdate(noteUrl: item.noteUrl) }
            return false
        }
        ComicRepository.shared.setUpdate(noteUrl: item.noteUrl,
                                         newChapters: fresh,
                                         latestName: info.chapters.last?.name ?? "")
        return true
    }

    // MARK: - 批量操作

    /// 一键全部标为已读（书架几十本时逐个点开太累）
    func markAllRead() {
        ComicRepository.shared.markAllRead()
        lastMessage = "已全部标为已读"
        NotificationCenter.default.post(name: .hmdShelfChanged, object: nil)
    }
}
