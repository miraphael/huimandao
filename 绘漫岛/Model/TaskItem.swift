import Foundation

/// 下载任务项（下载队列快照）（ARCHITECTURE §7.2：Model 层迁移 · 批次 4）。
///
/// ⚠️ 从 `DownloadManager` 的**嵌套类型**移出为**顶层类型**。
///    字段名 / 类型 / **默认值**一律不变 —— `state = 2`（等待）、`progress = 0` 等
///    是构造语义的一部分，改了会影响「新任务初始状态」。
///    外部（UI）通过 `DownloadManager.tasks` 间接使用，无显式 `DownloadManager.TaskItem`
///    引用，故本次迁移**不需要改任何调用点**。
///    纯数据、不访问数据库 / 网络 / UI。
struct TaskItem: Identifiable {
    var id: String { "\(comicKey)#\(chapterUrl)" }
    var comicKey: String       // origin|noteUrl
    var comicName: String
    var chapterName: String
    var chapterUrl: String
    var origin: String
    var noteUrl: String
    var state: Int = 2         // 2等待 3下载中 5失败
    var progress: Int = 0
    var max: Int = 0
    var error: String = ""
}

/// 按**整本漫画**聚合的一组下载任务。
///
/// ## 为什么需要它
/// `TASK_BEAN` 是**一章一行**的。一本 50 话的漫画在「下载任务」页就是 50 行 ——
/// 用户根本看不出「这本下到哪了」，只能一行一行数。
/// 聚合后一行一本：`12/50 章`，一眼就知道进度。
///
/// ## 关于「总页数」
/// ⚠️ **无法预知总页数**：只有真正开始下载某一章、拿到图片列表后才知道它的页数
///    （`TaskItem.max`），未开始的章节 `max == 0`。
///    所以这里给两个互补的指标：
///      · `doneChapters / totalChapters` —— **权威**，任何时刻都准；
///      · `donePages`（已下载页数）—— 只累加**已完成**章节的 `max`，不虚报。
///    不提供「预计总页数」这种需要猜测的数字（猜错比不显示更糟）。
struct ComicDownloadGroup: Identifiable {
    var id: String { comicKey }
    let comicKey: String
    let comicName: String
    let origin: String
    let noteUrl: String
    /// 本组的全部章节任务（顺序 = 入队顺序）
    let tasks: [TaskItem]

    // MARK: - 计数

    /// 总章节数（= 用户为这本选了下载的章节数）
    var totalChapters: Int { tasks.count }
    /// 已完成
    var doneChapters: Int { tasks.filter { $0.state == 0 }.count }
    /// 下载中
    var runningChapters: Int { tasks.filter { $0.state == 3 }.count }
    /// 排队等待
    var waitingChapters: Int { tasks.filter { $0.state == 2 }.count }
    /// 失败
    var failedChapters: Int { tasks.filter { $0.state == 5 }.count }

    /// 已下载页数 —— **只累加已完成章节**，不含下载中/未开始的（不虚报）
    var donePages: Int { tasks.filter { $0.state == 0 }.reduce(0) { $0 + $1.max } }

    // MARK: - 派生状态

    /// 整本进度：**完成 + 失败**都算「已结束」，否则失败会让进度条永远停在半路。
    /// 失败章节由 `failedChapters` 单独提示，不混进进度条。
    var progress: Double {
        guard totalChapters > 0 else { return 0 }
        return Double(doneChapters + failedChapters) / Double(totalChapters)
    }

    /// 是否还有活（下载中或排队中）
    var isActive: Bool { runningChapters > 0 || waitingChapters > 0 }
    /// 是否全部结束（没有等待/下载中）
    var isSettled: Bool { !isActive }
    /// 是否全部成功
    var isAllDone: Bool { doneChapters == totalChapters }

    /// 一行摘要，如 `12/50 章 · 下载中 2 · 失败 1`
    var summary: String {
        var parts = ["\(doneChapters)/\(totalChapters) 章"]
        if runningChapters > 0 { parts.append("下载中 \(runningChapters)") }
        if waitingChapters > 0 { parts.append("排队 \(waitingChapters)") }
        if failedChapters > 0 { parts.append("失败 \(failedChapters)") }
        if donePages > 0 { parts.append("已下 \(donePages) 张") }
        return parts.joined(separator: " · ")
    }
}
