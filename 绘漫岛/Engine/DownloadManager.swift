import Foundation

/// 下载管理 —— 对应 DownloadService：章节并发(默认2,上限10)，图片串行 20 次重试
///
/// ⚠️ **必须 `@MainActor`**：本类持有 `@Published tasks`，而 `pump()` / `runChapter()`
///    在 `Task { }` 里从**任意执行器**上直接写 `tasks[idx].state = …`。
///    `@Published` 的 `willSet` 会同步触发 SwiftUI 的订阅回调，而在后台线程改
///    `@Published` 会让 SwiftUI 在非主线程做布局 → 偶发崩溃（
///    `Publishing changes from background threads is not allowed`）+ UI 状态撕裂。
///    标记 `@MainActor` 后，所有属性访问都被编译器强制到主线程，
///    下载 IO 本身仍然是 `await`（不阻塞主线程）。
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    // `TaskItem` 已迁至 `Model/TaskItem.swift`（ARCHITECTURE §7.2 · 批次 4）。

    @Published var tasks: [TaskItem] = []
    @Published var isRunning = false
    /// 队列是否被用户暂停。
    ///
    /// ⚠️ 暂停**不会打断正在下载的那一章** —— 一章内部是「逐张图 + 最多 20 次重试」
    ///    的循环，中途强停会留下半章目录。暂停的语义是「不再取新任务」，
    ///    当前章会跑完。UI 上要如实说明，不能写成「立即停止」。
    @Published var paused = false
    private var queue: [TaskItem] = []
    private var processing = 0

    /// 失败任务数（供 UI 显示「重试全部失败」）
    var failedCount: Int { tasks.filter { $0.state == 5 }.count }
    /// 排队中 + 下载中的任务数
    var pendingCount: Int { tasks.filter { $0.state == 2 || $0.state == 3 }.count }

    /// 按**整本漫画**聚合的任务分组（下载管理页用）。
    ///
    /// ⚠️ 为什么在 manager 里算而不是在 View 里：分组需要保持**稳定的顺序**
    ///    （活跃的在前、同组内按入队序），而 `tasks` 会频繁变动。
    ///    放在这里算一次，View 只负责画。
    ///
    /// 排序规则：
    ///   ① **有活的在前**（下载中/排队中）—— 用户最关心「还在下的」；
    ///   ② 其次**有失败的**（需要用户处理）；
    ///   ③ 最后已全部结束的，按最近活跃排序（用组内最后一个任务的位置近似）。
    /// 组内顺序保持 `tasks` 的原始入队顺序，不重排（否则章节顺序会乱）。
    var comicGroups: [ComicDownloadGroup] {
        var order: [String] = []
        var bucket: [String: [TaskItem]] = [:]
        for t in tasks {
            if bucket[t.comicKey] == nil { order.append(t.comicKey) }
            bucket[t.comicKey, default: []].append(t)
        }
        let groups = order.compactMap { key -> ComicDownloadGroup? in
            guard let list = bucket[key], let first = list.first else { return nil }
            return ComicDownloadGroup(comicKey: key,
                                      comicName: first.comicName,
                                      origin: first.origin,
                                      noteUrl: first.noteUrl,
                                      tasks: list)
        }
        return groups.enumerated().sorted { a, b in
            let ga = a.element, gb = b.element
            // ① 有活的优先
            if ga.isActive != gb.isActive { return ga.isActive }
            // ② 有失败的次之
            let fa = ga.failedChapters > 0, fb = gb.failedChapters > 0
            if fa != fb { return fa }
            // ③ 其余保持原顺序（稳定）
            return a.offset < b.offset
        }.map(\.element)
    }

    /// 活跃组（还在下的）—— 供页面顶部单独展示
    var activeGroups: [ComicDownloadGroup] { comicGroups.filter { $0.isActive } }
    /// 已结束组（含失败待处理）
    var settledGroups: [ComicDownloadGroup] { comicGroups.filter { !$0.isActive } }

    /// 单章最多下载多少张图。DoS 护栏，见 `runChapter` 里的说明。
    /// （正常漫画一章远不到 2000 张；超出基本就是规则/源坏了。）
    static let maxImagesPerChapter = 2000

    func addTask(_ item: TaskItem) {
        guard !tasks.contains(where: { $0.id == item.id }) else { return }
        // 已下载过的章节不重复排队（用户可能手滑点了两次「下载全部」）
        if OfflineLibrary.shared.isDownloaded(chapterUrl: item.chapterUrl, origin: item.origin) { return }
        queue.append(item)
        tasks.append(item)
        persist(item)
        start()
    }

    private func persist(_ t: TaskItem) {
        Database.shared.exec("""
            INSERT OR REPLACE INTO TASK_BEAN (KEY, NAME, SOURCE, PATH, PARENT_ID_STRING, DUR_CHAPTER_URL, DUR_CHAPTER_NAME, STATE, PROGRESS, MAX, ERROR_MESSAGE)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            """, t.comicKey, t.comicName, t.origin, downloadDir(), t.noteUrl, t.chapterUrl, t.chapterName, t.state, t.progress, t.max, t.error)
    }

    func downloadDir() -> String {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func start() {
        guard !isRunning else { return }
        isRunning = true
        Task { await pump() }
    }

    private func pump() async {
        let maxThreads = AppSettings.shared.downloadThreads
        while !queue.isEmpty {
            // 暂停：不再取新任务（正在跑的那一章会跑完，见 `paused` 的注释）
            if paused {
                try? await Task.sleep(nanoseconds: 300_000_000)
                continue
            }
            guard processing < maxThreads else {
                try? await Task.sleep(nanoseconds: 300_000_000)
                continue
            }
            var item = queue.removeFirst()
            processing += 1
            if let i = tasks.firstIndex(where: { $0.id == item.id }) { tasks[i].state = 3 }
            await runChapter(&item)
            // ⚠️ **必须重新按 id 查下标**，不能复用 `await` 之前算出的 `idx`。
            //    `await runChapter` 期间用户可能在下载管理页删掉某条（`tasks` 缩短）
            //    或点「清空全部」→ 旧下标越界 → `Index out of range` **直接崩溃**；
            //    即使不越界也会把结果写到**另一章**上。
            if let i = tasks.firstIndex(where: { $0.id == item.id }) { tasks[i] = item }
            processing -= 1
        }
        isRunning = false
    }

    // MARK: - 批量操作（下载管理页用）

    /// 暂停队列：不再取新任务。已在下载的那一章会跑完。
    func pauseAll() {
        guard !paused else { return }
        paused = true
    }

    /// 继续队列。
    func resumeAll() {
        guard paused else { return }
        paused = false
        start()
    }

    /// 把**失败**的任务重新排队。
    ///
    /// 为什么需要它：一次网络抖动就能让几十章变成「失败」，而失败项散在列表里，
    /// 让用户逐个点重试不现实。已下载成功的章节不受影响（`addTask` 会挡）。
    @discardableResult
    func retryFailed() -> Int {
        var n = 0
        for i in tasks.indices where tasks[i].state == 5 {
            tasks[i].state = 2
            tasks[i].progress = 0
            tasks[i].error = ""
            // 已经在队列里的不重复加
            if !queue.contains(where: { $0.id == tasks[i].id }) {
                queue.append(tasks[i])
            }
            persist(tasks[i])
            n += 1
        }
        if n > 0 { start() }
        return n
    }

    /// 清掉「失败」的任务记录（**不删已下载的文件**）。
    @discardableResult
    func clearFailed() -> Int {
        let failed = tasks.filter { $0.state == 5 }
        for t in failed {
            Database.shared.exec("DELETE FROM TASK_BEAN WHERE DUR_CHAPTER_URL=? AND KEY=?",
                                 t.chapterUrl, t.comicKey)
        }
        tasks.removeAll { $0.state == 5 }
        queue.removeAll { q in failed.contains { $0.id == q.id } }
        return failed.count
    }

    private func runChapter(_ item: inout TaskItem) async {
        let diag = DiagLog.begin("dl")
        let res = await ComicEngine.shared.contentWithHeaders(chapterUrl: item.chapterUrl, origin: item.origin)
        let allImages = res.urls
        // 🔴 单章图片数上限（DoS 护栏）—— 规则是**不可信输入**，
        //    一个恶意图源让一章返回数万张 URL，就会无限下载、占满磁盘、
        //    并把下载线程永久占着。（由智能体「规则漏洞B」发现）
        let images = Array(allImages.prefix(Self.maxImagesPerChapter))
        if images.count < allImages.count {
            DiagLog.event("download", "cap",
                          "⚠️ \(item.comicName)/\(item.chapterName) 解析出 \(allImages.count) 张，"
                          + "超过上限 \(Self.maxImagesPerChapter)，只取前 \(Self.maxImagesPerChapter) 张")
        }
        DiagLog.event(diag, "download", "\(item.comicName)/\(item.chapterName) 解析出 \(images.count) 张")
        // 规则尾部 @Header:{...} 是给图片请求用的，下载同样要带上
        var imgHeaders: [String: String] = ["Referer": item.origin]
        for (k, v) in res.headers { imgHeaders[k] = v }
        item.max = images.count
        if let i = tasks.firstIndex(where: { $0.id == item.id }) { tasks[i].max = item.max }

        // ⚠️ **解析出 0 张图 = 失败，不是「完成」**。
        //    原实现里 `images` 为空时下面的 `for` 不执行、`state` 保持初值，
        //    随后被 `if item.state != 5 { item.state = 0 }` 置成「完成」——
        //    用户看到「已完成」但磁盘上什么都没有（静默假成功）。
        guard !images.isEmpty else {
            item.state = 5
            item.error = "未解析到图片（规则未命中或网络失败）"
            if let row = tasks.firstIndex(where: { $0.id == item.id }) {
                tasks[row].state = 5
                tasks[row].error = item.error
            }
            DiagLog.event(diag, "download", "\(item.comicName)/\(item.chapterName) 解析出 0 张 → 判失败")
            Database.shared.exec("UPDATE TASK_BEAN SET STATE=?, PROGRESS=?, MAX=?, ERROR_MESSAGE=? WHERE DUR_CHAPTER_URL=? AND KEY=?",
                                 item.state, item.progress, item.max, item.error, item.chapterUrl, item.comicKey)
            return
        }

        let dir = URL(fileURLWithPath: downloadDir())
            .appendingPathComponent(item.comicName.sanitizedFileName)
            .appendingPathComponent(item.chapterName.sanitizedFileName)
        // ⚠️ 重下前**先清空目录**：否则上次残留的 `006..020` 会混进本次结果
        //    （站点改版导致张数变少时，阅读器会读到「新 5 张 + 旧 15 张」的错乱内容）。
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 章内图片串行，最多 20 次重试（对应原版逻辑）
        for (i, img) in images.enumerated() {
            var ok = false
            for _ in 0..<20 {
                let raw = await HttpFetcher.shared.fetchData(img, headers: imgHeaders, timeout: 30)
                if !raw.isEmpty {
                    // ⚠️ 写盘**之前**必须跑 `RULE_BOOK_CONTENT_DECODER`：
                    //    很多图源的图片字节是加密的（漫蛙族 AES / 果果族条带还原），
                    //    直接存原始字节 → 离线打开时 `UIImage(data:)` 返回 nil → 白屏。
                    //    这里与在线阅读共用同一个解码实现，保证两边字节一致。
                    let data = await ChapterImageStore.decodeBytes(
                        raw, origin: item.origin, baseUrl: img, headers: imgHeaders)
                    if let type = imgType(data) {
                        let path = dir.appendingPathComponent(String(format: "%03d.%@", i + 1, type))
                        // ⚠️ **原子写**：`Data.write(to:)` 默认直接写目标文件名，
                        //    写到一半被杀进程会留下「扩展名正确、头部合法、内容截断」的
                        //    半张图，而 `OfflineLibrary.imageFiles` 按扩展名收 → 被当成
                        //    有效图片登记 → 离线打开白屏。`.atomic` 写同目录临时文件再
                        //    rename，最终名只会以**完整文件**出现。
                        if (try? data.write(to: path, options: .atomic)) != nil { ok = true; break }
                    } else {
                        // 拿到字节但**不是图片**（解密/还原失败）→ 重试 20 次毫无意义
                        // （数据问题不是网络问题），立即放弃这一张。
                        item.error = "第\(i + 1)张解码后不是图片: \(img)"
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            // 每次都按 id 现查 —— 下载期间用户可能删掉这条（见 `pump` 的说明）
            // ⚠️ 下标变量名不能叫 `i` —— 外层 `for (i, img)` 的 `i` 是**图片序号**，
            //    同名会遮蔽，`tasks[i].progress = i + 1` 会写进错误的进度值。
            if let row = tasks.firstIndex(where: { $0.id == item.id }) {
                tasks[row].progress = i + 1
            }
            item.progress = i + 1
            if !ok {
                item.state = 5
                item.error = "第\(i + 1)张下载失败: \(img)"
                if let row = tasks.firstIndex(where: { $0.id == item.id }) {
                    tasks[row].state = 5
                    tasks[row].error = item.error
                }
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if item.state != 5 { item.state = 0 }   // 0=完成
        // 诊断链：每章一个 session（用 begin 而不是固定串，否则几十章会混在一起）
        DiagLog.event(diag, "download",
                      "\(item.comicName)/\(item.chapterName) "
                      + (item.state == 0 ? "完成 \(item.progress)/\(item.max) 张"
                                         : "失败：\(item.error.prefix(60))"))

        // ── 登记进离线库 ──────────────────────────────────────────────────
        // 这一步是「下载完打开还要联网加载」的根治：没有它，磁盘上的图片
        // 没有任何读取入口（阅读器只会联网重抓）。见 `OfflineLibrary`。
        if item.state == 0 {
            let ok = OfflineLibrary.shared.register(
                chapterUrl: item.chapterUrl, origin: item.origin, noteUrl: item.noteUrl,
                comicName: item.comicName, chapterName: item.chapterName, dir: dir)
            if !ok { item.error = "已下载但未能登记到离线库（目录为空？）" }
            // 本类已是 `@MainActor`，这里就在主线程上，直接发通知即可
            // （`ChapterListView` 的 `.onReceive` 会改 `@State`，必须主线程）。
            NotificationCenter.default.post(name: .hmdDownloadsChanged, object: nil)
        }

        Database.shared.exec("UPDATE TASK_BEAN SET STATE=?, PROGRESS=?, MAX=?, ERROR_MESSAGE=? WHERE DUR_CHAPTER_URL=? AND KEY=?",
                             item.state, item.progress, item.max, item.error, item.chapterUrl, item.comicKey)
    }

    private func imgType(_ data: Data) -> String? {
        if data.starts(with: [0x89, 0x50]) { return "png" }
        if data.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if data.starts(with: [0x47, 0x49]) { return "gif" }
        if data.starts(with: [0x52, 0x49]) { return "webp" }
        return data.isEmpty ? nil : "jpg"
    }

    /// 清掉「已完成」的任务记录（**不删已下载的文件**）。
    ///
    /// ⚠️ 同时删数据库行：只从内存列表移除的话，TASK_BEAN 里会留一堆 STATE=0 的
    ///    僵尸记录，越攒越多（而且 `restorePersisted` 的查询条件一旦放宽就会复活它们）。
    @discardableResult
    func clearFinished() -> Int {
        let done = tasks.filter { $0.state == 0 }
        for t in done {
            Database.shared.exec("DELETE FROM TASK_BEAN WHERE DUR_CHAPTER_URL=? AND KEY=?",
                                 t.chapterUrl, t.comicKey)
        }
        tasks.removeAll { $0.state == 0 }
        return done.count
    }

    /// 删除某章的下载：清磁盘目录 + 清离线库登记 + 从任务列表**和队列**移除。
    func removeDownload(chapterUrl: String, origin: String, noteUrl: String) {
        OfflineLibrary.shared.remove(chapterUrl: chapterUrl, origin: origin)
        tasks.removeAll { $0.chapterUrl == chapterUrl && $0.origin == origin }
        // ⚠️ **必须同时清 `queue`**。`pump()` 是从 `queue` 取任务的，
        //    只清 `tasks` 的话，一个「排队中」的章节被删掉后仍会被 `pump` 取出来
        //    重新下载、重新登记 —— 用户会看到「删了又自己回来」。
        queue.removeAll { $0.chapterUrl == chapterUrl && $0.origin == origin }
        Database.shared.exec("DELETE FROM TASK_BEAN WHERE DUR_CHAPTER_URL=? AND KEY=?",
                             chapterUrl, "\(origin)|\(noteUrl)")
        NotificationCenter.default.post(name: .hmdDownloadsChanged, object: nil)
    }

    /// 取消**全部**未完成任务（清队列 + 清任务列表 + 清库记录），**不删已下载的文件**。
    ///
    /// 供「清空全部下载」使用。⚠️ 必须由本类提供，不能让 View 直接
    /// `tasks.removeAll()` —— 那样 `queue` 仍是满的，后台会继续下完并重新登记。
    func cancelAllPending() -> Int {
        let n = queue.count + tasks.filter { $0.state == 2 || $0.state == 3 }.count
        queue.removeAll()
        let pending = tasks.filter { $0.state == 2 || $0.state == 3 }
        for t in pending {
            Database.shared.exec("DELETE FROM TASK_BEAN WHERE DUR_CHAPTER_URL=? AND KEY=?",
                                 t.chapterUrl, t.comicKey)
        }
        tasks.removeAll { $0.state == 2 || $0.state == 3 }
        NotificationCenter.default.post(name: .hmdDownloadsChanged, object: nil)
        return n
    }

    /// 启动时把上次没下完的任务捞回来。
    /// 不做这件事的话，用户杀掉 App 后「等待中 / 下载中」的队列就永久丢了
    /// （`tasks` 只在内存里），而 TASK_BEAN 里还留着 STATE=2/3 的僵尸记录。
    func restorePersisted() {
        guard tasks.isEmpty, queue.isEmpty, !isRunning else { return }
        let rows = Database.shared.query(
            "SELECT KEY, NAME, SOURCE, DUR_CHAPTER_URL, DUR_CHAPTER_NAME FROM TASK_BEAN WHERE STATE=2 OR STATE=3")
        var restored: [TaskItem] = []
        for r in rows {
            guard let key = r["KEY"] as? String, let chUrl = r["DUR_CHAPTER_URL"] as? String, !chUrl.isEmpty
            else { continue }
            // KEY = "origin|noteUrl"
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            let origin = parts.first ?? ""
            let noteUrl = parts.count > 1 ? parts[1] : ""
            // 已经躺在离线库里的直接跳过（可能是上次跑到一半被杀，图其实已齐）
            if OfflineLibrary.shared.isDownloaded(chapterUrl: chUrl, origin: origin) {
                Database.shared.exec("UPDATE TASK_BEAN SET STATE=0 WHERE DUR_CHAPTER_URL=? AND KEY=?", chUrl, key)
                continue
            }
            restored.append(TaskItem(
                comicKey: key,
                comicName: r["NAME"] as? String ?? "",
                chapterName: r["DUR_CHAPTER_NAME"] as? String ?? "",
                chapterUrl: chUrl,
                origin: origin,
                noteUrl: noteUrl))
        }
        guard !restored.isEmpty else { return }
        tasks = restored
        queue = restored
        start()
    }
}

extension String {
    /// 把外部输入（漫画名/章节名，来自图源，**不可信**）清洗成安全的文件名。
    ///
    /// 🔴 以前只替换 `/\:?%*|"<>`，**漏了 `..`、前导 `.`、空名、超长**：
    ///    · 名字恰好是 `..` 时，拼出的目录会**上跳一级**（可越出 Downloads 目录写）
    ///    · 名字为空时，拼接会塌缩，`removeItem` 有**删掉整个 Downloads** 的风险
    ///    · 超长名会超出文件系统 255 字节上限导致写失败
    ///    （由智能体「守卫」发现）
    var sanitizedFileName: String {
        var s = components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
        // 控制字符（含换行/制表）一律去掉
        s = s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
             .reduce(into: "") { $0.unicodeScalars.append($1) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // 纯 `.` / `..` → 兜底名；顺带去掉前导点（避免生成隐藏文件）
        if s.isEmpty || s == "." || s == ".." { s = "_" }
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { s = "_" }
        // 截断到 100 字符（UTF-8 下最多 400 字节，留足余量）
        if s.count > 100 { s = String(s.prefix(100)) }
        return s
    }
}

extension Notification.Name {
    /// 下载完成 / 删除下载 —— 章节列表据此刷新「离线」角标与删除入口。
    /// 注意：发送方必须保证在**主线程**发（接收方会直接改 `@State`）。
    static let hmdDownloadsChanged = Notification.Name("hmdDownloadsChanged")
}
