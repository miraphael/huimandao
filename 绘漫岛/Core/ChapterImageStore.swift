import Foundation
import UIKit
import Nuke

/// 章节图片按需加载器 —— 防止整章图片撑爆内存（Jetsam 崩溃）
/// 加载成功后自动向前预载若干页，阅读更顺滑
///
/// ──────────────────────────────────────────────────────────────────────
/// ⚠️ 设计红线（踩过血坑，勿动）
///
/// 本类以前是 `ObservableObject`，`loaded` / `failed` 是 `@Published`，
/// 却在 `loadRaw()` 的异步回调里直接赋值。`@Published` 会在**写入线程**上
/// 同步触发 `objectWillChange`，而 `StoreImage` 正在**主线程**读这两个字典
/// → AttributeGraph 内部状态被并发改写 → **整屏冻结、手势全丢、
/// 只能强制关机**（用户实测反馈）。
///
/// 现在的结构：
///   · 所有可变状态（loaded/failed/urls/inflight）都由 `NSLock` 保护，
///     **只在锁内读写**，不含任何 UI 概念。
///   · 状态变化时**只标记 `needsPublish = true`**，然后统一在主线程
///     发一次 `objectWillChange`（`publish()`）。
///   · 视图读的是 `loaded` / `failed` 的**加锁快照**（`snapshot`）。
///
/// 另外删掉了旧的「`inflight` 命中就轮询等 30 秒」逻辑：
/// 那是「图片等几分钟都出不来」的直接原因 —— `runLimited` 会**提前**插入
/// `inflight` 占坑，而真正执行要排 `AsyncGate` 的队（4 路 × 20s 超时），
/// 排队时间天然超过 30 秒，于是每个 cell 都在做无意义的死等。
/// 现在改成「同一个 index 只跑一个 `Task`，其余调用者 `await` 同一个
/// `Task.value`」——不轮询、不抢坑、天然去重。
///
/// ── 第四轮改造（2026-10，借鉴 Aidoku）：下载/缓存换成 Nuke ─────────────
/// 原来 `loadRaw` 自己走 `HttpFetcher.fetchData` + `ImageDiskCache` +
/// `DecodedImageCache` + `AsyncGate`。四件套边界太多（并发去重、磁盘 LRU、
/// 解码、取消传播都要自己写），实测仍有「图片转圈」。
/// 现在把「网络下载 + 双层缓存 + 去重 + 取消 + 预取」全部交给 Nuke
/// （`HMDImagePipeline`），本类只保留：
///   · **解密**（图源规则的 `@js` 头/字节解码，Nuke 不管这个）
///   · **白边裁剪**（本项目特有）
///   · `@Published` 安全发布（Nuke 的加载结果回到这里再统一发通知）
///
/// ⚠️ 为什么不能直接换成 `NukeUI.LazyImage`：图片需要**先解密再解码**，
///    Nuke 的 `ImagePipeline` 拿到的是密文字节，得走自定义 `DataDecoder`
///    或在加载后处理。这里选择「Nuke 负责取字节与缓存，解密在本类做」，
///    改动面最小且行为可控。
/// ──────────────────────────────────────────────────────────────────────
final class ChapterImageStore: ObservableObject {

    // MARK: - 对外只读快照（视图用）

    /// 已加载成功、可直接显示的图片
    var loaded: [Int: UIImage] {
        lock.lock(); defer { lock.unlock() }
        return _loaded
    }

    /// 加载失败、需要用户手动重试的页
    var failed: Set<Int> {
        lock.lock(); defer { lock.unlock() }
        return _failed
    }

    /// 当前章节共几页（首屏解析出来的是第一页集合，后续会 append）
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _urls.count
    }

    /// 单页是否已就绪（视图侧快速判断，避免整字典拷贝）
    func current(_ index: Int) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        return _loaded[index]
    }

    /// 单页 URL（调试/分享用）
    func url(at index: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return _urls.indices.contains(index) ? _urls[index] : nil
    }

    /// 首屏 URL 列表的只读快照（供"还有没有下一页"之类的判断）
    var urlsSnapshot: [String] {
        lock.lock(); defer { lock.unlock() }
        return _urls
    }

    /// 第 index 页的**宽高比**（高 / 宽）。图片本身可能已被淘汰，但比例一直留着。
    ///
    /// 🔴 **为什么比例必须单独缓存、且永不淘汰** —— 这是「看漫画时图片会割裂、
    ///    过一会儿才恢复」的直接根因：
    ///    页面在 SwiftUI 里的高度 = 宽度 × 宽高比。图片一旦被 `evictOutsideWindow`
    ///    回收（`_loaded` 里没了），旧实现只能退回**写死的 1.45 占位比**，
    ///    于是那一页的高度**突然变化** → 它下面的所有内容整体位移 → 视觉上就是
    ///    「裂开、跳一下」，等图片重新加载完才收敛回真实高度。
    ///    比例只是几个浮点数，留着它的成本可以忽略，收益是**布局彻底稳定**。
    func ratio(at index: Int) -> CGFloat? {
        lock.lock(); defer { lock.unlock() }
        return _ratios[index]
    }

    /// 本章**已知比例的样本数**（用于判断估算是否可信）
    var ratioSampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _ratios.count
    }

    /// 本章已知比例的**中位数**；本章样本不足时退回**同书其它章**的中位比例。
    ///
    /// 用途：给「还没加载过」的页一个比写死 1.45 准得多的估算 ——
    /// 同一章、同一站点的漫画页比例通常高度一致，用中位数估算后
    /// 首次加载时的高度跳变会小一个数量级。
    ///
    /// 2026-10-17 起：**新章**（本章一个样本都没有）也会返回书级中位数，
    /// 不再直接给 nil —— 见 `bookRatioKey` 那段注释。
    /// 只有「第一次看这本书」才会返回 nil（调用方再退 1.45）。
    var medianRatio: CGFloat? {
        lock.lock()
        // ⚠️ 必须按 `_urls.count` 过滤：持久化读回来的比例里可能有**超出当前页数**
        //    的索引（章节页数变少 / 键碰撞串进来的别章数据）。它们对 `heights`
        //    无害（那里按 count 迭代），但**中位数是全量取样本**，掺进来会把
        //    「未加载页的估算高度」带偏 → 又变成高度突变。
        //    （第二轮复核智能体发现：我先前那句「越界项根本不会被读到」只对 heights 成立。）
        let vals = _ratios.filter { $0.key < _urls.count }.map(\.value)
        lock.unlock()
        // 本章样本不足 → 用**同书其它章**的中位比例兜底（2026-10-17）。
        // 只有第一次看这本书（书级也没学过）才会返回 nil，调用方再退 1.45。
        guard vals.count >= 3 else { return bookMedian }
        let sorted = vals.sorted()
        return sorted[sorted.count / 2]
    }

    /// **一次**取回「算每页高度」所需的全部信息（只加一次锁）。
    ///
    /// ⚠️ 为什么需要它：滚动模式的内容视图与协调器都要按页算高度
    /// （`宽 × 宽高比`），长章 300 页。若逐页调 `ratio(at:)`，每次都要加锁
    /// —— 一帧就是几百次锁操作，白白拖慢布局。这里一次拿完。
    func ratioSnapshot() -> (known: [Int: CGFloat], median: CGFloat?, count: Int) {
        lock.lock(); defer { lock.unlock() }
        var med: CGFloat? = nil
        // ⚠️ 中位数只统计**当前确实存在的页**（理由见 `medianRatio`）。
        //    `known` 仍然返回全量：`StripMetrics.heights` 按 `count` 迭代，
        //    取不到的索引不会读到，而取得到的（分页章后半段）正是我们要救的。
        let inRange = _ratios.filter { $0.key < _urls.count }.map(\.value)
        if inRange.count >= 3 {
            let sorted = inRange.sorted()
            med = sorted[sorted.count / 2]
        } else {
            // 新章（本章还没样本）：用同书中位比例估算，别退回 1.45
            med = bookMedian
        }
        return (_ratios, med, _urls.count)
    }

    // MARK: - 内部状态（全部由 lock 保护）

    private let lock = NSLock()
    private var _loaded: [Int: UIImage] = [:]
    /// 每页图片的**宽高比**（高 / 宽）。
    /// ⚠️ **永不淘汰**（`evictOutsideWindow` 不碰它）—— 理由见 `ratio(at:)` 的说明。
    private var _ratios: [Int: CGFloat] = [:]
    private var _failed: Set<Int> = []
    /// 每页的**失败原因**（2026-10-28）。UI 靠它把「点击重试」换成
    /// 「图片地址失效 · 建议换源」这类可执行的提示。
    private var _reasons: [Int: FailureReason] = [:]
    /// 图床级熔断：同一章节里连续 N 页 `notFound` → 判定「该源图床挂了」，
    /// 后面的页直接标失败，不再逐页发请求（包子实测：18 页 × 2 次重试 = 20 秒白等）。
    private var consecutiveNotFound = 0
    private static let notFoundBreakLimit = 3
    /// 已经上报过「图床失效」的源（每个源每次启动只报一次，避免刷爆体检文件）
    private static var reportedBrokenHosts = Set<String>()
    private static let reportLock = NSLock()
    private var _urls: [String]
    /// 每个 index 对应的在飞任务。用 Task 而不是 Bool 标记：
    /// 后来者直接 await 同一个 Task，不再轮询等待。
    private var inflight: [Int: Task<UIImage?, Never>] = [:]
    /// 是否有未发布的状态变化（攒批，避免高频发通知）
    private var needsPublish = false
    /// 最近若干次成功请求的耗时（秒）。用来判断链路是不是「慢链路」，
    /// 进而动态收敛预载窗口 —— 慢链路上继续猛预载只会让队列更长。
    private var recentRTT: [Double] = []

    /// 最近一次 `preload(around:)` 的锚点页 —— 闲置补载用它校验「用户有没有滑走」。
    private var lastPreloadCenter: Int = -1
    /// 闲置补载任务（每次 `preload` 都会取消重排，避免补到旧位置去）
    private var idleExtendTask: Task<Void, Never>?

    /// 当前有效的预载窗口：慢链路时自动收窄。
    /// 判据用「最近 slowWindow 次的**中位数**」而不是平均值 ——
    /// 单张图偶发抖动不该影响整体策略。
    private var effectiveAhead: Int {
        lock.lock()
        let rtts = recentRTT
        lock.unlock()
        guard rtts.count >= Self.slowWindow else { return Self.preloadAhead }
        let sorted = rtts.sorted()
        let median = sorted[sorted.count / 2]
        if median > Self.slowRTT { return 4 }        // 慢：收窄到 4 张
        if median > Self.slowRTT / 2 { return 7 }
        return Self.preloadAhead
    }

    /// 记录一次成功请求的耗时（由 `loadRaw` 调用）
    private func noteRTT(_ seconds: Double) {
        lock.lock()
        recentRTT.append(seconds)
        if recentRTT.count > Self.slowWindow * 2 { recentRTT.removeFirst() }
        lock.unlock()
    }

    private let referer: String
    private let ua: String
    /// 规则尾部 @Header:{...} 带来的额外请求头（很多图片站校验 Referer，不带就 403）
    private let extraHeaders: [String: String]
    private let whiteCut: Bool
    /// 图源 origin（BOOK_SOURCE_URL）—— 用来取 `RULE_BOOK_CONTENT_DECODER`
    private let origin: String
    /// ── 离线模式 ────────────────────────────────────────────────────────
    /// 非空表示这一章是**已下载**的：`_urls` 里存的是**本地文件路径**，
    /// 加载走 `Data(contentsOf:)`，完全不经网络、不进并发闸门。
    /// 见 `OfflineLibrary` 的注释（用户反馈「下载完打开还要加载」）。
    private let localFiles: [URL]

    /// 比例持久化的键（章节身份）。nil = 不持久化（读缓存/ Debug 打开）。
    ///
    /// 🔴 **为什么要持久化比例**（2026-10-13 真机日志实锤）：
    ///    用户反馈「重新打开漫画就往上滑」「打开时自动滑一下」。
    ///    插桩显示：打开瞬间 `内容总高 90354`（166 页 × 375 × **1.45 占位比**），
    ///    等真实图片到达后 `内容总高 47880` —— **腰斩 47%**。
    ///    高度表突变 → 触发高度补偿 → 若补偿被跳过（「超过 3 页」护栏），
    ///    内容就会在用户眼前整体上移 = 「自动往上滑」+「黑屏」。
    ///    把比例存到 UserDefaults 后，**重开时首帧就是正确高度**，突变不再发生。
    private let persistKey: String?

    /// 本章是否离线（供 UI 打角标 / 决定要不要后台续抓分页）
    var isOffline: Bool { !localFiles.isEmpty }

    // MARK: - 比例持久化

    /// UserDefaults 里的键前缀。整体清 App 数据时会跟着没了，无所谓（比例可再生）。
    private static let ratioPrefix = "hmd.imageratio.v1."

    /// 把磁盘上存的这一章比例读进 `_ratios`（init 时调用）。
    private func loadPersistedRatios() {
        guard let key = persistKey else { return }
        let d = UserDefaults.standard.dictionary(forKey: Self.ratioPrefix + key) as? [String: Double] ?? [:]
        guard !d.isEmpty else { return }
        lock.lock()
        for (k, v) in d {
            // 🔴 这里**不能**加 `idx < _urls.count` 过滤 —— init 时 `_urls` 只有
            //    **首屏第一批**（`contentFirstPage` 只返回第一分页），后续分页是
            //    `appendURLs` 事后才到达的。加了那个过滤，分页章**后半章的比例
            //    永远读不回来**，重开时那些页仍走占位比 → 真实图到达时章后段
            //    再次腰斩 = 用户说的「尾部自动往上滑」。
            //    （由 3 个智能体独立发现：链路 2 / 3 / 8。）
            //
            //    多余的索引对 `heights` 是**安全**的：`StripMetrics.heights` 只按
            //    `snap.count`（= `_urls.count`）迭代，越界项读不到。
            //    ⚠️ 但**中位数**是全量取样本，必须单独过滤 —— 见 `medianRatio` /
            //    `ratioSnapshot`。（第二轮复核智能体发现：别以为「没人读」就万事大吉。）
            if let idx = Int(k), v > 0, v < Self.ratioBound, _ratios[idx] == nil, idx >= 0 {
                _ratios[idx] = CGFloat(v)
            }
        }
        lock.unlock()
    }

    /// 立刻把当前已知比例写盘。
    ///
    /// ⚠️ **过滤口径必须和 `loadPersistedRatios` 完全一致** —— 之前读侧写死
    ///    `v < 20` 而写侧不过滤，长条漫（整章一张超长图，比例可达 30+）的比例
    ///    写得进去却读不回来，每开一次都要重学一遍。（智能体审查发现）
    private func persistRatiosNow() {
        guard let key = persistKey else { return }
        lock.lock()
        var out: [String: Double] = [:]
        out.reserveCapacity(_ratios.count)
        for (i, r) in _ratios where r > 0 && r < Self.ratioBound { out[String(i)] = Double(r) }
        lock.unlock()
        UserDefaults.standard.set(out, forKey: Self.ratioPrefix + key)
        // 顺便把「这本书的中位比例」更新一下，供**其它没读过的章**估算高度用
        updateBookMedian()
        trimRatioStoreIfNeeded()
    }

    /// 把本章的中位比例并进**书级**估算（指数平滑）。
    ///
    /// 只在样本够（≥3 页）时更新 —— 一两页的「中位数」毫无代表性，
    /// 拿它去当整本书的占位比只会引入新的误差。
    private func updateBookMedian() {
        guard let key = persistKey else { return }
        lock.lock()
        let vals = _ratios.filter { $0.key < _urls.count }.map(\.value)
        lock.unlock()
        guard vals.count >= 3 else { return }
        let sorted = vals.sorted()
        let med = sorted[sorted.count / 2]
        guard med > 0, med < Self.ratioBound else { return }

        let bk = Self.bookKey(from: key)
        let d = UserDefaults.standard
        var map = d.dictionary(forKey: Self.bookRatioKey) as? [String: Double] ?? [:]
        let blended: Double
        if let old = map[bk], old > 0, old < Double(Self.ratioBound) {
            blended = old * (1 - Self.bookRatioBlend) + Double(med) * Self.bookRatioBlend
        } else {
            blended = Double(med)
        }
        map[bk] = blended
        if map.count > Self.bookRatioLimit {
            // 超上限丢一半：先收成数组再删，避免「边遍历边改字典」
            let dropKeys = Array(map.keys.prefix(map.count - Self.bookRatioLimit / 2))
            for k in dropKeys { map.removeValue(forKey: k) }
        }
        d.set(map, forKey: Self.bookRatioKey)
    }

    /// 限制比例缓存的**章节数上限**（LRU 淘汰最旧的）。
    ///
    /// 🔴 原来只写不删：按章累积、永不清理（移出书架 / 删下载都不清）。
    ///    1000 章大约 1MB+，而且 `UserDefaults` 每次 `set` 都会**整份 plist 重写**，
    ///    数据量线性增长 → 启动与写入越来越慢。（由智能体「漫读」「设置」分别发现）
    ///    这里用一个轻量的「最近写入时间表」做 LRU，超过上限就删最旧那批。
    private func trimRatioStoreIfNeeded() {
        let d = UserDefaults.standard
        var order = d.dictionary(forKey: Self.ratioOrderKey) as? [String: Double] ?? [:]
        guard let key = persistKey else { return }
        order[key] = Date().timeIntervalSince1970
        if order.count > Self.ratioChapterLimit {
            // 按时间升序，删掉最旧的一批（留出 10% 余量，避免每次写都触发淘汰）
            let sorted = order.sorted { $0.value < $1.value }
            let drop = order.count - Self.ratioChapterLimit + Self.ratioChapterLimit / 10
            for (k, _) in sorted.prefix(drop) {
                d.removeObject(forKey: Self.ratioPrefix + k)
                order.removeValue(forKey: k)
            }
        }
        d.set(order, forKey: Self.ratioOrderKey)
    }

    /// 比例合法区间上界。两侧（读/写）共用，避免口径漂移。
    private static let ratioBound: CGFloat = 50
    /// 最多缓存多少章的图片比例（超出按 LRU 淘汰最旧的）。
    private static let ratioChapterLimit = 300
    /// 记录每章比例最近写入时间的键（用于 LRU）。
    private static let ratioOrderKey = "hmd.imageratio.order.v1"

    // ── 书级比例（跨章节，2026-10-17）────────────────────────────────────
    /// **书级中位比例**的存储键：一个字典 `bookKey → 中位比例`。
    ///
    /// 为什么需要（真机日志实锤「第一次打开新章会跳一下」）：
    /// 比例是**按章**持久化的（`persistKey`），所以一本**没读过的新章**里
    /// 一个样本都没有 → `medianRatio` 为 nil → 退回写死的 1.45。
    /// 而真实比例可能差很远（包子漫画的横版画格条只有 ~0.78，竖版页 1.4~2.9），
    /// 于是「打开瞬间的总高」与「图到齐后的总高」能差几千像素：
    /// `[fixup] strip 补偿 824→1073（页 1 移 249px，总高 19667→23956）`。
    ///
    /// 修法：把**同一本书已读章节**的中位比例记下来，新章打开时先拿它估算。
    /// 同一本书的画格比例通常很接近，误差能小一个数量级。
    private static let bookRatioKey = "hmd.imageratio.bookmed.v1"
    /// 最多记多少本书（超出丢一半；被丢的下次读到时重新学）。
    private static let bookRatioLimit = 120
    /// 指数平滑权重：老值占 0.65、本次章中位数占 0.35。
    /// 用平滑而不是「取最后一次」—— 单章异常（插页广告、超长条）不该带偏整本。
    private static let bookRatioBlend: Double = 0.35

    /// 本书的估算比例（nil = 还没学过，仍用 `StripMetrics.fallbackRatio`）。
    private let bookMedian: CGFloat?

    /// 从章节的 `persistKey` 里截出「书」的部分。
    ///
    /// ⚠️ 与 `ReaderView.ratioKey` 的拼接格式**强耦合**：
    ///    `"<origin>|<noteUrl>|<anchor>|<discriminator>"` —— 前两段就是书的身份。
    ///    那边改格式时这里必须同步，否则会退化成「每章一本书」，等于没做。
    private static func bookKey(from persistKey: String) -> String {
        let parts = persistKey.split(separator: "|", maxSplits: 3,
                                     omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return persistKey }
        return parts[0] + "|" + parts[1]
    }

    private static func storedBookMedian(bookKey: String) -> CGFloat? {
        let d = UserDefaults.standard.dictionary(forKey: bookRatioKey) as? [String: Double] ?? [:]
        guard let v = d[bookKey], v > 0, v < Double(ratioBound) else { return nil }
        return CGFloat(v)
    }

    /// 一次性迁移：把 v89 之前存的**按章比例**汇总成**书级中位数**。
    ///
    /// 🔴 为什么必须迁移（2026-10-17，装完 v89 立刻发现）：
    ///    书级比例是 v89 才引入的新存储。装完后第一次打开一本「以前读过几章」的书，
    ///    书级仍然是**空的** → 依然退 1.45 → 看起来像「根本没修」。
    ///    但存量里其实早就有按章比例（`hmd.imageratio.v1.<persistKey>`），
    ///    扫一遍就能立刻算出每本书的中位数，不用等用户重读一遍。
    ///
    /// 成本：最多 300 章 × 每章几十~几百个 double，几十毫秒；且只做一次。
    /// ⚠️ 用 `static let` + 闭包拿到「线程安全地只执行一次」的语义。
    ///    闭包里**显式写类型名**（`ChapterImageStore.xxx`）—— 静态存储属性初始化
    ///    闭包里对其它静态成员做**非限定**引用，Swift 的解析规则容易踩坑。
    private static let migrateBookMediansOnce: Void = {
        ChapterImageStore.migrateBookMediansNow()
    }()

    private static func migrateBookMediansNow() {
        let d = UserDefaults.standard
        let doneKey = "hmd.imageratio.bookmed.migrated.v1"
        guard !d.bool(forKey: doneKey) else { return }

        // ① 按「书」把存量比例分桶
        var buckets: [String: [CGFloat]] = [:]
        for (k, v) in d.dictionaryRepresentation() {
            guard k.hasPrefix(ratioPrefix), let raw = v as? [String: Any] else { continue }
            let bk = bookKey(from: String(k.dropFirst(ratioPrefix.count)))
            var vals: [CGFloat] = []
            vals.reserveCapacity(raw.count)
            for (_, num) in raw {
                if let dv = num as? Double, dv > 0, dv < Double(ratioBound) {
                    vals.append(CGFloat(dv))
                }
            }
            // 单章样本太少（1~2 页）时中位数没有代表性，直接丢掉
            if vals.count >= 3 { buckets[bk, default: []].append(contentsOf: vals) }
        }
        guard !buckets.isEmpty else {
            d.set(true, forKey: doneKey)
            return
        }

        // ② 每本书取中位数写进书级表
        var map = d.dictionary(forKey: bookRatioKey) as? [String: Double] ?? [:]
        for (bk, vals) in buckets {
            guard map[bk] == nil else { continue }   // 已有（运行时学到的）就别覆盖
            let sorted = vals.sorted()
            let med = sorted[sorted.count / 2]
            if med > 0, med < ratioBound { map[bk] = Double(med) }
        }
        if map.count > bookRatioLimit {
            let dropKeys = Array(map.keys.prefix(map.count - bookRatioLimit / 2))
            for k in dropKeys { map.removeValue(forKey: k) }
        }
        d.set(map, forKey: bookRatioKey)
        d.set(true, forKey: doneKey)
        DiagLog.event("img", "bookratio", "存量比例迁移完成：\(map.count) 本书")
    }

    /// 标记比例需要落盘（防抖：≥1.5 秒才真正写，避免滚动时每帧都写）。
    ///
    /// ⚠️ `setLoaded` 可能在**非主线程**的 Nuke 回调里执行，所以这里用**独立的锁**
    ///    保护 `ratioSaveWork` —— 否则两个线程同时 cancel/替换会让待写任务被丢掉
    ///    （表现为「比例没存上」）。`lock`（状态锁）不能在这里用：`persistRatiosNow`
    ///    自己要拿它，会重入死锁。
    private func schedulePersistRatios() {
        guard persistKey != nil else { return }
        let w = DispatchWorkItem { [weak self] in self?.persistRatiosNow() }
        saveLock.lock()
        ratioSaveWork?.cancel()
        ratioSaveWork = w
        saveLock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    /// 保护 `ratioSaveWork` 的小锁（**不能**用状态锁 `lock`，见 `schedulePersistRatios`）。
    private let saveLock = NSLock()
    private var ratioSaveWork: DispatchWorkItem?

    /// 预载窗口：进入章节先并发拉前 10 张。
    ///
    /// 变迁：6 → 10（2026-10-17，用户反馈「看太快就跟不上，经常看到没加载出来的」）。
    /// 并发闸门同期已提到 10（见 `maxConcurrent`），窗口 10 正好能把闸门喂满，
    /// 又不会超出它 —— 「预载窗口不能大于并发闸门」这条红线仍然成立。
    ///
    /// ⚠️ 曾改成 12 反而更慢（2026-10）：滚动模式里 LazyVStack 每出现一个新 cell
    /// 就会调 `image(at:)`，叠加 12 张预载 → 同时 20+ 个请求打图站 → 图站限流/超时。
    static let preloadAhead = 12
    /// 「可视区」宽度（锚点往后算几张）。
    /// 这几张按 `.visible` 优先级加载，其余预载按 `.ahead` 让路。
    /// 取 3：滚动模式下同屏通常 1~2 张（条漫画格条更少），3 张已覆盖
    /// 「刚滑过去还没稳定」的情况，再多就等于把预载也算成可视区了。
    static let visibleBand = 3
    /// 「已经滑过去多远」的在飞任务该被取消（见 `cancelStaleInflight`）。
    /// 取 8 页 ≈ 往回翻一屏的距离，正常来回微调不会误杀。
    private static let staleBehind = 8
    /// ⚠️ 22 秒（从 16 上调）：实测（2026-10，包子漫画 c-nd3-1.6wm.top）
    /// 走代理时单张 webp 要 **7.7~12.7 秒**（直连只要 1.7~3.7 秒）。
    /// 16 秒在高延迟链路上会**正常图也判超时 → 走重试 → 更慢**，
    /// 用户看到「明明能出图却一直在转圈」。22 秒能覆盖代理慢链路，
    /// 又不至于让用户以为卡死。
    private static let imageTimeout: TimeInterval = 22
    /// 单张图的总耗时预算（含重试）。超了就当失败，交给用户点重试，
    /// 绝不无限期挂着 —— 这是「等几分钟出不来」的兜底。
    private static let imageBudget: TimeInterval = 45
    /// 并发上限：**Nuke 接管下载后可以放宽到 6**。
    ///
    /// ── 为什么从 4 提到 6 ───────────────────────────────────────────────
    /// 以前是 4，因为「四件套」时代没有请求去重：
    /// 滚动模式里 LazyVStack 每出现一个新 cell 就调 `image(at:)`，
    /// 叠加预载会同时打出 20+ 个请求，图站直接限流。
    ///
    /// 现在 Nuke 的 `DataLoader` 内建：① 同 URL 并发**去重**；
    /// ② **取消传播**（cell 回收后立即放弃在飞请求）；
    /// ③ HTTP/2 多路复用。真正打出去的并发数已由 Nuke 统一调度，
    /// 这里再压到 4 只是白白拖长首屏（用户实测「等几分钟」）。
    /// 提到 6 是速度与礼貌的折中：爬虫礼仪上 6 路对图站仍算温和。
    ///
    /// ⚠️ 但**预载窗口不能跟着放大**：预载是「主动提前打」的请求，
    /// 和可视区内的即时请求叠加。保持 `preloadAhead = 12`（仍小于闸门 14）。
    ///
    /// ── 为什么 2026-10-17 又从 6 提到 10 ────────────────────────────────
    /// 实测（包子漫画图 CDN `s1.bzcdn.net`，HTTP/1.1、**单连接限速 40~85 KB/s**）：
    ///
    ///   并发  聚合速率   单张中位
    ///    1    36 KB/s    2.82s
    ///    4   259 KB/s    1.70s
    ///    6   407 KB/s    1.67s
    ///    8   522 KB/s    1.70s
    ///   12   690 KB/s    1.61s   ← 到 12 仍未被限流
    ///
    /// 结论：单张耗时由 CDN 单连接决定（约 1.6s 起步，改不了），
    /// **能改的只有同时跑几路**。首屏实际待办是「可视 2~3 张 + 预载 6 张 ≈ 9 个请求」，
    /// 卡在 6 就必然分两批（约 3.4s），放到 10 可以一批到齐（约 2s）。
    ///
    /// ── 为什么 2026-10-17 又提到 **14** ─────────────────────────────────
    /// 用户反馈「快滑还是经常碰到没加载出来的」。实测图站的并发上限（同一章 24 张）：
    ///
    ///   并发  成功      聚合速率
    ///   10   10/10    427 KB/s
    ///   14   14/14    404 KB/s
    ///   18   15/18    567 KB/s   ← 开始丢请求
    ///   24   15/24    795 KB/s   ← 丢了 9 个，靠重试反而更慢
    ///
    /// 所以 **14 是安全上限**：再往上就变成「失败 + 重试」，净效果更慢。
    /// ⚠️ 必须与 `HMDImagePipeline.maxConnectionsPerHost` 保持一致，
    ///    否则闸门放行的任务会在 URLSession 内部排队白等。
    /// 🔴 2026-10-27：14 → 6。必须与 `HMDImagePipeline.maxConnectionsPerHost`
    ///    保持一致；两者都降到 6 是因为真机上 14 路并发会把带宽切碎，
    ///    单张图超过超时阈值 → 整批失败（用户看到「全都要点重试」）。
    private static let maxConcurrent = 6
    /// 慢链路自适应：若最近几次请求明显偏慢，暂时把预载收敛，
    /// 避免「越慢越排队、越排队越慢」。阈值取实测代理态中位数（约 8s）。
    private static let slowRTT: TimeInterval = 6.5
    private static let slowWindow = 4

    /// ── 全局闸门：所有图片请求（即时加载 + 预载）共用同一个并发额度 ──
    /// 这是「图片经常转圈」的根治：此前 `image(at:)` 直调 `loadRaw`，
    /// 而 `runLimited` 只约束预载任务，两路各开各的 Task，合计并发不可控。
    private static let gate = AsyncGate(limit: maxConcurrent)

    init(urls: [String], referer: String, ua: String, whiteCut: Bool,
         headers: [String: String] = [:], origin: String = "",
         persistKey: String? = nil) {
        // ⚠️ 必须在读 `bookMedian` 之前跑：把存量按章比例汇总成书级（只做一次）
        _ = Self.migrateBookMediansOnce
        self._urls = urls
        self.referer = referer
        self.ua = ua
        self.whiteCut = whiteCut
        self.extraHeaders = headers
        self.origin = origin
        self.localFiles = []
        self.persistKey = persistKey
        self.bookMedian = persistKey.flatMap {
            Self.storedBookMedian(bookKey: Self.bookKey(from: $0))
        }
        loadPersistedRatios()
    }

    /// 离线初始化：直接读磁盘上的已下载图片，零网络、零解析。
    ///
    /// ⚠️ 这条路径的存在本身就是修复 —— 以前下载完的章节没有任何读取入口，
    ///    阅读器一律联网重抓，用户看到「我明明下载了还要加载」。
    init(localFiles: [URL], whiteCut: Bool, origin: String = "", persistKey: String? = nil) {
        _ = Self.migrateBookMediansOnce
        self._urls = localFiles.map { $0.path }
        self.referer = ""
        self.ua = ""
        self.whiteCut = whiteCut
        self.extraHeaders = [:]
        self.origin = origin
        self.localFiles = localFiles
        self.persistKey = persistKey
        self.bookMedian = persistKey.flatMap {
            Self.storedBookMedian(bookKey: Self.bookKey(from: $0))
        }
        loadPersistedRatios()
    }

    // MARK: - 状态发布（唯一允许碰 UI 的地方）

    /// 把一个变更标记为「待发布」。可以在任意线程调用。
    private func markDirty() {
        lock.lock()
        needsPublish = true
        lock.unlock()
        // 直接派到主线程发通知：objectWillChange 必须在主线程触发，
        // 否则 SwiftUI 的图状态会被后台线程改写（→ 整屏卡死）。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let should = self.needsPublish
            self.needsPublish = false
            self.lock.unlock()
            if should { self.objectWillChange.send() }
        }
    }

    // MARK: - 写入状态的统一收口（全部在锁内，且改完 markDirty）

    private func setLoaded(_ index: Int, _ image: UIImage) {
        lock.lock()
        _loaded[index] = image
        _failed.remove(index)
        _reasons.removeValue(forKey: index)
        consecutiveNotFound = 0          // 有图能出来 → 图床没挂，重置熔断
        // 记下真实宽高比（**永不淘汰**）—— 布局靠它才算得准，见 `ratio(at:)`
        let w = image.size.width
        var isNewRatio = false
        if w > 0 {
            let r = image.size.height / w
            if _ratios[index] != r {
                _ratios[index] = r
                isNewRatio = true
            }
        }
        lock.unlock()
        // 🔎 插桩：用户报「图片是黑的」时，这条能直接区分三种情况：
        //    ① 根本没打这条 → 图片没加载（网络/URL 问题）
        //    ② size=0×0 → 数据解码出来是空图（响应被丢 / 内容不是图）
        //    ③ size 正常但仍显示黑 → 渲染层问题（与解析/网络无关）
        //    （由真机日志只能看到「淘汰 N 页」推断不出加载结果，补这条）
        if index < 3 || isNewRatio {
            DiagLog.event("img", "load",
                          "页 \(index) 载入 \(Int(w))×\(Int(image.size.height)) 比例 \(String(format: "%.3f", Double(image.size.height / max(w, 1))))"
                          + (w > 0 ? "" : " ⚠️ 空图（解码失败或响应为空）"))
        }
        // 只对「新学到的比例」落盘 —— 防抖 1.5 秒，滚动时不会每帧都写
        if isNewRatio { schedulePersistRatios() }
        markDirty()
    }

    /// 立刻把比例写盘（阅读器退出 / App 进后台时调用，别指望防抖一定来得及）。
    func flushRatios() {
        // 顺手取消挂起的防抖任务：旧 store 被换掉后它还会在 1.5s 后补写一次
        //（写的是旧章自己的 key，无害但多余）。（智能体审查发现）
        saveLock.lock()
        ratioSaveWork?.cancel()
        ratioSaveWork = nil
        saveLock.unlock()
        persistRatiosNow()
    }

    /// 该页失败的原因（供阅读器失败页展示；没失败过返回 nil）
    func reason(at index: Int) -> FailureReason? {
        lock.lock(); defer { lock.unlock() }
        return _reasons[index]
    }

    private func setFailed(_ index: Int, _ reason: FailureReason = .unknown) {
        lock.lock()
        _failed.insert(index)
        _reasons[index] = reason
        lock.unlock()
        // 🔎 插桩：**「黑屏图片」的头号嫌疑就是这条** —— 加载失败时页面会显示
        //    失败态（黑底 + 重试按钮），用户看到的就是「一堆黑屏图片」。
        //    打出 URL（去掉 query 里的 token，避免泄露）便于判断是
        //    「URL 本身坏」还是「被恒拒绝清单拦了」。
        if index < 8 {
            let u = _urls.indices.contains(index) ? _urls[index] : ""
            let bare = String(u.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            let denied = JsoupConn.isDeniedAlways(u) ? " ⚠️命中恒拒绝清单" : ""
            DiagLog.event("img", "fail", "页 \(index) 加载失败 \(bare)\(denied)")
        }
        markDirty()
    }

    // MARK: - 增量追加 URL（首屏只拿第一页 → 后台续抓分页）

    /// 必须在主线程调用（`_urls` 被 SwiftUI 读，且会触发一次发布）
    @MainActor
    func appendURLs(_ more: [String]) {
        lock.lock()
        let existing = Set(_urls)
        let add = more.filter { !existing.contains($0) }
        guard !add.isEmpty else { lock.unlock(); return }
        _urls.append(contentsOf: add)
        let start = _urls.count - add.count
        let total = _urls.count
        lock.unlock()
        markDirty()
        // 立刻预载新追加的这一段，用户往下滚就不会转圈（慢链路会自动收窄）
        let end = min(total - 1, start + effectiveAhead)
        if start <= end { runLimited(Array(start...end)) }
    }

    // MARK: - 对外入口

    /// 取第 index 页。缓存命中直接返回；否则复用/新建加载任务并 await 它。
    ///
    /// 语义变化：以前「已有任务在飞」会进入 30 秒轮询（死等）；
    /// 现在直接 `await` 那个 Task 的 value —— 一次等待，绝不空转。
    ///
    /// ⚠️ 清理语义：任务由 `self` 持有（`inflight[index]`），**不是**调用者的
    /// 结构化子任务。因此这里用 `defer` 而不是「await 完再清理」——
    /// 调用者（SwiftUI 的 `.task`）在 cell 被回收时会取消，`await task.value`
    /// 会提前返回，但后台任务必须继续跑完并把 `inflight` 清掉，
    /// 否则该 index 会被永久标记为「在飞」，后续所有请求都拿到一个已取消的任务。
    @discardableResult
    func image(at index: Int, priority: LoadPriority = .visible) async -> UIImage? {
        // ⚠️ 所有锁操作必须放在**同步**函数里：`NSLock.lock()` 标了
        //    `@available(*, noasync)`，在 async 函数体内直接调用会告警
        //    （Swift 6 语言模式下直接报错）。这里把「查缓存 / 摘取在飞任务 /
        //    占坑建任务」整体收进一个同步方法，异步侧只拿结果。
        switch claim(index, priority: priority) {
        case .cached(let img):
            return img
        case .failed:
            return nil
        case .flying(let task):
            return await task.value            // ← 复用同一个任务，不再轮询
        case .owner(let task):
            let img = await task.value
            // 🔴 **不要在这里 prefetchAhead**（2026-10-16 真机实锤的回归根因）：
            //    `runLimited` 自己就是走 `image(at:)` 起任务的，于是
            //      加载第 N 张成功 → prefetchAhead(N+1 … N+6) → runLimited → image(at:)
            //      → 又成功 → 再 prefetchAhead … **无限前向级联**，
            //    进章节时 7 张种子会在十几秒内把整章（几十上百张）全部拉完。
            //    后果真机日志看得一清二楚：
            //      · `[load] img 页 3 / 页 1 / 页 6 …` 页序混乱、持续 12 秒不断
            //      · 每张到家就把该页高度从兜底值改成真实值 → contentSize 持续收缩
            //        → 用户看到「图片一直往上顶」「自己在一直往下滑」
            //      · 首屏第一张图要跟 38 张抢带宽 → 黑屏 1.5 秒
            //    预载**只应由视口锚点驱动**：`ReaderView` 在「进章节 / 翻页 / 滚动」
            //    时都会调 `preload(around:)`（且 `preloadCenter` 已去重），
            //    这里再补一次纯属重复，且把窗口预载变成了整章预载。
            return img
        }
    }

    /// `image(at:)` 的同步前半段：决定这一页该「直接返回」「复用任务」还是「新建任务」。
    private enum Claim {
        case cached(UIImage)
        case failed
        case flying(Task<UIImage?, Never>)
        case owner(Task<UIImage?, Never>)
    }

    private func claim(_ index: Int, priority: LoadPriority) -> Claim {
        lock.lock()
        defer { lock.unlock() }
        guard _urls.indices.contains(index) else { return .failed }
        if let img = _loaded[index] { return .cached(img) }
        if _failed.contains(index) { return .failed }   // 失败态等用户点重试
        if let flying = inflight[index] { return .flying(flying) }

        // 占坑：先建 Task（此时还没进闸门），保证并发调用只产生一个任务
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            defer { self.clearInflight(index) }   // ⚠️ 任务自己负责摘牌
            return await self.loadNow(index, priority: priority)
        }
        inflight[index] = task
        return .owner(task)
    }

    /// 摘掉在飞标记（由任务体自己调用，保证无论调用者是否取消都能清理）
    private func clearInflight(_ index: Int) {
        lock.lock()
        inflight[index] = nil
        lock.unlock()
    }

    /// 真正走一遍「缓存 → 闸门 → 下载」。任务本身由 `image(at:)` 创建，
    /// 这里只管干活，不碰 `inflight`。
    private func loadNow(_ index: Int, priority: LoadPriority) async -> UIImage? {
        guard urlAt(index) != nil else { return nil }

        // ⓪ **离线章节**：直接读磁盘。放在最前面且**不进闸门** ——
        //    闸门是给网络请求限流的，本地文件读取被它卡住毫无道理
        //    （用户反馈「下载完打开还要加载」，一部分原因就是本地读也被排队）。
        if let f = localFileAt(index) { return await loadLocalFile(index, path: f.path) }

        // ① 缓存预检（**必须在闸门之外**）：命中的图是纯本地 IO + 解码，
        //    几十毫秒的事，不该被并发额度卡住排队。
        // ── 缓存预检 ──────────────────────────────────────────────────────
        // ⚠️ 只查**内存图片缓存**（`ImageCaching`），不碰磁盘数据缓存。
        //
        //    为什么不去查磁盘：`DataCaching.containsData(for:)` 是对管线内部
        //    `DataCache` 的直接调用，签名随 Nuke 小版本变动，而且 Aidoku 全程
        //    没有这样用过 —— 它一律交给 `ImagePipeline` 自己判断命中。
        //
        //    但本类的流程特殊：我们要区分「原始**密文**字节在不在磁盘上」，
        //    再决定走不走解密。所幸路径②（`loadRaw` → `data(for:)`）本身
        //    就是「先查双层缓存，未命中才发网络」，Nuke 命中磁盘时同样是
        //    零网络返回。所以这里**不需要自己预检磁盘**：
        //      · 内存图命中 → 直接返回已解码的图（最快路径）
        //      · 其余情况 → 一律走闸门 → `loadRaw`，由 Nuke 内部决定是
        //        命中磁盘（快）还是真的发网络（慢）
        //
        //    这样既拿回了「内存命中零成本」的收益，又不依赖易变的磁盘 API，
        //    也彻底消除了「请求头不一致导致查不到缓存」这类隐患。
        if let img = memoryHit(index) { return img }

        // ② 走闸门（带超时兜底）。Nuke 在 `loadRaw` 内部完成缓存判定。
        return await Self.gate.run(priority: priority.rawValue) {
            await self.loadRaw(index, priority: priority)
        }
    }

    /// 离线模式下取第 index 页对应的本地文件（同步，锁内）
    private func localFileAt(_ index: Int) -> URL? {
        guard !localFiles.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        return _urls.indices.contains(index) && localFiles.indices.contains(index)
            ? localFiles[index] : nil
    }

    /// 离线读图：`Data(contentsOf:)` → `UIImage` → 白边裁剪。
    private func loadLocalFile(_ index: Int, path: String) async -> UIImage? {
        if Task.isCancelled { return nil }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else {
            setFailed(index, .notFound)   // 离线文件被系统清掉了
            return nil
        }
        var bytes = data
        if UIImage(data: bytes) == nil {
            // 旧版本下载时写的是**未解密**的原始字节 → 补跑一次内容解码器。
            // （新版本下载已在写盘前解码，所以正常情况下走不到这里。）
            bytes = await Self.decodeBytes(bytes, origin: origin, baseUrl: path, headers: [:])
        }
        guard var img = UIImage(data: bytes) else {
            setFailed(index, .decode)
            return nil
        }
        if whiteCut { img = WhiteEdgeCutter.cut(img) }
        setLoaded(index, img)
        return img
    }

    /// ── 内容解码器（`RULE_BOOK_CONTENT_DECODER`）的唯一实现 ──────────────
    ///
    /// 它作用于**下载下来的图片字节**，不是 URL 规则。语义见安卓
    /// `ChapterBrowseAdapter.m25054while`：`setContent(headers, byte[], url)`
    /// → `result` 是 byte[] → `getBytes(decoder, false)` 返回处理后的 byte[]。
    ///
    /// ⚠️ 下载（`DownloadManager`）与离线读取（本类）都必须用它，
    ///    否则磁盘上会是「一半解密一半没解密」，离线打开直接白屏。
    static func decodeBytes(_ data: Data, origin: String, baseUrl: String,
                            headers: [String: String]) async -> Data {
        guard !origin.isEmpty,
              let s = ComicRepository.shared.source(url: origin),
              let rule = s.ruleBookContentDecoder, !rule.isEmpty else { return data }
        let a = AnalyzeRule(baseUrl: baseUrl)
        if let decoded = await a.applyContentDecoder(rule, bytes: data, headers: headers), !decoded.isEmpty {
            return decoded
        }
        return data
    }

    /// 内存图片缓存预检：命中时直接返回已解码的 `UIImage`（零网络、零解码）。
    ///
    /// 用 Aidoku 同款 API（`ImageCaching`）：`containsCachedImage(for:)` + `cachedImage(for:)`。
    /// ⚠️ 不能用 `containsData(for:)` / `storeData(...)` —— 那是 `DataCaching`
    ///    （磁盘字节缓存）的接口，不是内存图片缓存的。
    ///
    /// ⚠️ `ImageContainer.image` 在 iOS 上是 **非可选** 的 `PlatformImage`
    ///    （= `UIImage`），不能写 `let image = container.image` 做条件绑定 ——
    ///    编译器会报 "initializer for conditional binding must have Optional type"。
    private func memoryHit(_ index: Int) -> UIImage? {
        guard let urlString = urlAt(index) else { return nil }
        var hh: [String: String] = ["Referer": referer, "User-Agent": ua]
        for (k, v) in extraHeaders { hh[k] = v }
        guard let req = HMDImagePipeline.request(url: urlString, referer: referer, ua: ua, headers: hh),
              HMDImagePipeline.shared.cache.containsCachedImage(for: req),
              let container = HMDImagePipeline.shared.cache.cachedImage(for: req)
        else { return nil }
        let image = container.image
        // 内存命中也算「已加载」，写进本类状态让视图立即显示
        setLoaded(index, image)
        return image
    }

    /// 在锁内安全取某一页的 URL
    private func urlAt(_ index: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard _urls.indices.contains(index) else { return nil }
        return _urls[index]
    }

    /// `loadRaw` 的同步前半段：校验 index、命中已加载的图、取 URL。
    /// 把锁操作留在同步函数里，避免 async 上下文调用 `NSLock`。
    private enum RawTarget {
        case ready(UIImage)     // 已加载，直接返回
        case url(String)        // 待下载
    }

    private func rawTarget(_ index: Int) -> RawTarget? {
        lock.lock(); defer { lock.unlock() }
        guard _urls.indices.contains(index) else { return nil }
        if let img = _loaded[index] { return .ready(img) }
        return .url(_urls[index])
    }

    /// 实际抓取+解码（带重试），预载与即时加载共用。
    /// 只在 `AsyncGate` 额度内执行，绝不自建并发。
    ///
    /// ── 第四轮改造：数据获取交给 Nuke ──────────────────────────────────
    /// 原来自己走 `HttpFetcher.fetchData` + `ImageDiskCache`。现在改为
    /// `HMDImagePipeline.shared.data(for:)`：
    ///   · Nuke 自动做**请求去重**（同 URL 并发只发一次）
    ///   · 自动**双层缓存**（内存 100MB + 磁盘 500MB，按 LRU）
    ///   · 返回的是**原始字节**（`.storeOriginalData`），解密仍在本类做
    /// ⚠️ 超时交给 Nuke 的 DataLoader（30s/60s），不再自己算 budget；
    ///    但保留一次重试（图站偶发 5xx/Cloudflare 挑战）。
    private func loadRaw(_ index: Int, priority: LoadPriority) async -> UIImage? {
        let url: String
        switch rawTarget(index) {
        case .none: return nil
        case .ready(let img): return img
        case .url(let u): url = u
        }
        // 规则自带的头优先，其次才是默认 Referer/UA
        var hh: [String: String] = ["Referer": referer, "User-Agent": ua]
        for (k, v) in extraHeaders { hh[k] = v }

        guard let req = HMDImagePipeline.request(url: url, referer: referer, ua: ua,
                                                headers: hh, priority: priority.nuke) else {
            DiagLog.event("img", "badurl", "页 \(index) 请求构造失败 \(url)")
            setFailed(index, .ruleMiss)
            return nil
        }
        // 🔴 图床级熔断：本会话里已经连续 3 页 404 → 判定该源图床失效，
        //    后面的页不再发请求（包子实测 18 页 × 2 次重试 = 白等 20 秒）。
        lock.lock(); let broken = consecutiveNotFound >= Self.notFoundBreakLimit; lock.unlock()
        if broken {
            setFailed(index, .notFound)
            reportBrokenImageHostOnce()
            return nil
        }
        // 日志里去掉 query（可能带 token），只留路径便于判断
        let bareURL = String(url.split(separator: "?", maxSplits: 1,
                                       omittingEmptySubsequences: false).first ?? "")

        /// 本轮所有尝试里最后一次失败的归因（给 UI 用）
        var lastReason: FailureReason = .unknown
        var attempt = 0
        while attempt < 2 {
            attempt += 1
            // ⚠️ 必须区分「失败」与「被取消」（血坑）：
            // 滚动模式下 cell 回收 → SwiftUI 取消 `.task` → 这里的 `data(for:)` 抛 CancellationError。
            // 旧代码用 `try?` 把两种情况都吞成 nil，于是：
            //   ① 取消后还傻等 500ms 再重试（浪费额度、拖慢真正可见的图）；
            //   ② 循环走完调 `setFailed(index)`，把这一页标成**永久失败** —— 
            //      用户滚回去看到的是「点击重试」而不是自动加载，只能手动点。
            // 现在取消就直接返回 nil（不标失败），下次进入可视区会重新发起。
            if Task.isCancelled { return nil }
            let tReq = Date()
            let data: Data?
            do {
                // ⚠️ `ImagePipeline.data(for:)` 返回的是**元组**
                //    `(Data, URLResponse?)`，不是 `Data`！写 `d.isEmpty` 会报
                //    "value of tuple type has no member 'isEmpty'"，写
                //    `data = d` 会报 "cannot assign '(Data, URLResponse?)' to 'Data?'"。
                let (d, resp) = try await HMDImagePipeline.shared.data(for: req)
                // 🔎 非 2xx 一定要记：以前响应被丢掉，403/404 和「网络失败」
                //    在日志里长得一模一样，根本分不出是防盗链还是解析错。
                if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    DiagLog.event("img", "http", "页 \(index) HTTP \(http.statusCode) \(bareURL)")
                    lastReason = FailureReason.from(status: http.statusCode)
                }
                data = d.isEmpty ? nil : d
            } catch let err as ImagePipeline.Error {
                // ⚠️ Nuke 抛的是 `ImagePipeline.Error`（枚举），**不是** `CancellationError`。
                //    以前的 `catch is CancellationError` 永远不匹配
                //    （编译器 warning: cast ... always fails），
                //    结果「用户滚动导致的取消」会被当成「真实失败」→ 页面被标 failed。
                //    枚举里的 `.cancelled` 才是取消信号（见 Aidoku 的 switch 写法）。
                if case .cancelled = err { return nil }
                // 🔎 把 Nuke 的底层错误打出来。`String(describing:)` 会把关联的
                //    URLError 一起打印，例如 `dataLoadingFailed(Code=-1003)`：
                //      -1003 = 域名解析失败、-1009 = 断网、-1001 = 超时、
                //      -1200 = TLS 握手失败、-1011 = 响应非 2xx。
                //    没有这一行，用户报「图片一直重试」时只能靠猜。
                DiagLog.event("img", "err", "页 \(index) \(Self.describe(err)) \(bareURL)")
                lastReason = FailureReason.from(error: err)
                data = nil                     // 真正的网络/解码失败
            } catch {
                if Task.isCancelled { return nil }
                DiagLog.event("img", "err", "页 \(index) \(error.localizedDescription) \(bareURL)")
                lastReason = FailureReason.from(error: error)
                data = nil
            }
            guard let data else {
                // 超时/网络抖动 → 短暂退避再来（但取消优先，别做无谓等待）
                if Task.isCancelled { return nil }
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            // 记录成功请求的耗时，供「慢链路自适应」判断是否收敛预载
            noteRTT(Date().timeIntervalSince(tReq))

            // ── 正文后期规则：图片本身是加密的 → 用 RULE_BOOK_CONTENT_DECODER 解出来 ──
            // 对照安卓 ChapterBrowseAdapter.m25054while()：拿到 bytes 后跑解码器规则。
            // ⚠️ 与离线路径共用同一个实现（`decodeBytes`），保证「下载到磁盘的」
            //    和「在线阅读的」是同一份字节，不会出现离线打不开。
            let bytes = await Self.decodeBytes(data, origin: origin, baseUrl: url, headers: hh)
            if var img = UIImage(data: bytes) {
                // 白边裁剪要在**回写缓存之前**做完：
                // 缓存里存的应该是**用户最终看到的那张图**。先存后裁的话，
                // 下次内存命中拿到的是未裁剪的图，裁剪设置变了还会不一致。
                if whiteCut { img = WhiteEdgeCutter.cut(img) }

                // 把**已解码（且已裁剪）的图像**写进内存缓存，下次命中零解码直接显示。
                // ⚠️ 用 `storeCachedImage(_:for:)`（`ImageCaching`，内存图片缓存），
                //    不是 `storeData(_:for:cacheType:)`（`DataCaching`，磁盘字节缓存）。
                //    这里存 `ImageContainer(image:)`，与 Aidoku 的用法一致
                //    （见 `ReaderPageView.setPageImage` 末尾那行）。
                //
                //    为什么不把「解密后的字节」写回磁盘数据缓存：
                //    磁盘缓存的写入在管线内部完成，直接调用 `DataCaching` 的
                //    方法签名随版本变动，且解密后写回会让「磁盘上是密文还是明文」
                //    变得不确定，排查困难。内存缓存这一层已经吃掉了阅读中
                //    「同一页滚出再滚回」的绝大多数重复解码，收益足够。
                HMDImagePipeline.shared.cache.storeCachedImage(ImageContainer(image: img), for: req)

                setLoaded(index, img)
                return img
            }
            // 解码失败：把字节数和文件头打出来 —— 是 HTML 错误页还是真图一眼可辨
            DiagLog.event("img", "decode",
                          "页 \(index) 解码失败 \(bytes.count)B head="
                          + bytes.prefix(8).map { String(format: "%02X", $0) }.joined()
                          + " \(bareURL)")
            if Task.isCancelled { return nil }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        // 走到这里是真的两次都失败了。若这期间任务被取消，不要标失败。
        if Task.isCancelled { return nil }

        // 🔴 兜底：Nuke 的 DataLoader 两次都失败 → 换 `HttpFetcher` 再试一次。
        //    HttpFetcher 与「抓章节页」是同一条链路（同 UA / Cookie / 超时策略），
        //    所以「页面能开、图片打不开」时这一跳常常能救回来；顺带把状态码写进日志。
        if !Task.isCancelled {
            // 变体 ①：原样（与 Nuke 完全一致的请求头）
            var variants: [(String, [String: String])] = [("原样", hh)]
            // 变体 ②：不带 Referer / Cookie。
            //   真机实证：瓜子图床对 `Referer: -` 这种占位值直接 403（4548B），
            //   而对「完全没有 Referer」返回 200 —— 空值和不发是两个不同的结果。
            var noRef = hh
            noRef.removeValue(forKey: "Referer")
            noRef.removeValue(forKey: "Cookie")
            variants.append(("无Referer", noRef))
            // 变体 ③：Referer 换成图源根域（部分站只认根）
            if !origin.isEmpty {
                var root = noRef
                root["Referer"] = origin
                variants.append(("源根Referer", root))
            }
            for (name, hv) in variants {
                let (d, r) = await HttpFetcher.shared.fetchDataWithResponse(url, headers: hv, timeout: 40)
                let st = r?.statusCode ?? -1
                DiagLog.event("img", "fallback",
                              "页 \(index) [\(name)] HTTP \(st) \(d.count)B \(bareURL)")
                if st == 200, !d.isEmpty, var img = UIImage(data: d) {
                    if whiteCut { img = WhiteEdgeCutter.cut(img) }
                    HMDImagePipeline.shared.cache.storeCachedImage(ImageContainer(image: img), for: req)
                    setLoaded(index, img)
                    return img
                }
                if st != 200 { lastReason = FailureReason.from(status: st) }
                // 非 200 且响应体很小 → 多半是拦截页/错误说明，把开头记下来便于定性
                if st != 200, d.count > 0, d.count < 4096,
                   let txt = String(data: d.prefix(180), encoding: .utf8) {
                    DiagLog.event("img", "body",
                                  "页 \(index) \(st) "
                                  + txt.replacingOccurrences(of: "\n", with: " ").prefix(160))
                }
            }
        }
        // 图床级故障计数：连续 404 说明是**站点**挂了，不是这一页的问题
        lock.lock()
        if lastReason == .notFound { consecutiveNotFound += 1 } else { consecutiveNotFound = 0 }
        lock.unlock()
        setFailed(index, lastReason)
        return nil
    }

    /// 图床连续 404 → 把结论写进 `SourceHealth`，图源页会显示「正文 0 图」徽章。
    ///
    /// 意义：包子这类**整站图床失效**的源，用户在图源页一眼就能看到"这个源坏了"，
    /// 而不是打开章节、看到 18 页「图片地址失效」才知道。
    /// 每个源每次启动只报一次（静态去重），避免每章都写一次体检文件。
    private func reportBrokenImageHostOnce() {
        guard !origin.isEmpty else { return }
        Self.reportLock.lock()
        let already = Self.reportedBrokenHosts.contains(origin)
        if !already { Self.reportedBrokenHosts.insert(origin) }
        Self.reportLock.unlock()
        guard !already, let s = ComicRepository.shared.source(url: origin) else { return }

        let res = SourceCheckResult(
            name: s.bookSourceName, sourceUrl: s.bookSourceUrl,
            ok: false, ms: 0,
            message: "正文图连续 \(Self.notFoundBreakLimit) 页 404（图床失效）",
            checked: true, stage: "正文", chapters: 0, images: 0, probedContent: true)
        _ = SourceHealth.mergeObserved([res])
        DiagLog.event("img", "host",
                      "图床失效已记入体检：\(s.bookSourceName)（图源页会显示「正文 0 图」）")
    }

    /// 把 Nuke 的 `ImagePipeline.Error` 翻成可读文本（带上底层错误码）。
    private static func describe(_ e: ImagePipeline.Error) -> String {
        let s = String(describing: e)
        if let u = (e as NSError).userInfo[NSUnderlyingErrorKey] as? NSError {
            return "\(s) ⟵ \(u.domain)#\(u.code)"
        }
        return s
    }

    /// 用户点击重试
    func retry(_ index: Int) {
        lock.lock()
        _failed.remove(index)
        _loaded[index] = nil
        let flying = inflight[index] != nil
        lock.unlock()
        markDirty()
        guard !flying else { return }
        Task { _ = await image(at: index) }
    }

    /// 退出章节时停掉本章残留的预取（2026-10-17）。
    ///
    /// 为什么需要：`HMDImagePipeline.prefetcher` 是**全局单例**，Nuke 只在
    /// prefetcher **自己**被释放时才取消任务（`ImagePrefetcher.swift` 的 `deinit`），
    /// 而单例永远不会释放 → 关掉章节后，之前预取的请求还会继续跑完，
    /// 白占带宽（紧接着打开下一章，首屏就得跟它们抢）。
    ///
    /// ⚠️ 按本章 URL 精确停（`stopPrefetching(with:)`），不能用无参的
    ///    `stopPrefetching()` —— 那会把书架页（`ShelfView`）的预取一起干掉。
    deinit {
        lock.lock()
        let urls = _urls
        lock.unlock()
        guard !urls.isEmpty else { return }
        var hh: [String: String] = ["Referer": referer, "User-Agent": ua]
        for (k, v) in extraHeaders { hh[k] = v }
        let reqs = urls.compactMap {
            HMDImagePipeline.request(url: $0, referer: referer, ua: ua, headers: hh)
        }
        if !reqs.isEmpty { HMDImagePipeline.prefetcher.stopPrefetching(with: reqs) }
    }

    // MARK: - 预载

    /// ⚠️ 已废弃（2026-10-16）：`prefetchAhead(from:)` 已删除。
    ///     它曾被 `image(at:)` 在**每张图加载成功后**调用，而 `runLimited` 又是走
    ///     `image(at:)` 起任务的 → 形成无限前向级联，把整章图片全部拉完
    ///     （详见 `image(at:)` 里那段注释）。预载只应由视口锚点驱动。

    /// 进入章节 / 翻页时预载：当前页往后 preloadAhead 张
    func preload(around index: Int) {
        // ⚠️ **先淘汰窗口外的已解码图**（内存治理，见 `evictOutsideWindow`）。
        //    这一步不能省：`_loaded` 原先只增不减，长章会把整章 UIImage 常驻 → Jetsam。
        evictOutsideWindow(center: index)
        // 🔴 **先砍掉「已经滑过去很远」的在飞任务**（2026-10-17 用户反馈「看太快跟不上」）：
        //    闸门只有 10 个额度，快滑时旧位置的任务还占着它们下载根本不会再看的页，
        //    真正要看的当前页反而排在后面等 —— 这是「滑过去要等一下才出图」的直接原因。
        //    取消后这些页不进 `_loaded`、不标失败（`loadRaw` 里取消直接 return nil），
        //    用户回头再看会重新请求，没有副作用。
        cancelStaleInflight(center: index)
        let start = max(0, index)
        let ahead = effectiveAhead
        lock.lock()
        let end = min(_urls.count - 1, index + ahead)
        lock.unlock()
        guard start <= end else { return }

        // ── 可视区走 normal，其余预载走 low（2026-10-17）──────────────────
        // 之前这里一股脑 `runLimited(start...end)`：锚点页和后面 6 张预载
        // 在 URLSession / 闸门里**同优先级**，快滑时新出现的当前页
        // 要排在预载后面等 —— 用户感觉「滑过去要等一下才出图」。
        // 现在把「锚点 + 紧邻 visibleBand 张」按 `.visible` 起任务，
        // 剩下的才交给 `runLimited`（内部一律 `.ahead`）。
        let visibleEnd = min(end, start + Self.visibleBand - 1)
        for j in start...visibleEnd {
            Task { [weak self] in
                _ = await self?.image(at: j, priority: .visible)
            }
        }
        if visibleEnd < end {
            runLimited(Array((visibleEnd + 1)...end))
        }

        // ── 停住不动时**继续往前补**（2026-10-17 用户反馈）──────────────────
        // 「不往下滑就不加载新的图片」：原设计只预载 anchor…anchor+ahead，
        // 用户停在那批末尾等着，后面一张都不开始下，再滑又要等。
        // 这里排一个闲置补载：锚点 1.5 秒没变就再补一批。
        lock.lock()
        lastPreloadCenter = index
        lock.unlock()
        idleExtendTask?.cancel()
        scheduleIdleExtension(center: index, ahead: ahead, round: 1)
    }

    /// 取消「已经滑过去很远」的在飞任务（见 `preload(around:)` 里的说明）。
    ///
    /// 判据：`index < center - staleBehind`。取 8 页 —— 相当于「往回翻一屏」的距离，
    /// 正常的来回微调不会被误杀，真正被甩在身后的才会被砍。
    private func cancelStaleInflight(center: Int) {
        let cutoff = center - Self.staleBehind
        guard cutoff > 0 else { return }
        lock.lock()
        var toCancel: [Task<UIImage?, Never>] = []
        for (i, t) in inflight where i < cutoff {
            toCancel.append(t)
            inflight[i] = nil     // 立刻摘牌，允许以后重新请求
        }
        lock.unlock()
        guard !toCancel.isEmpty else { return }
        for t in toCancel { t.cancel() }
        DiagLog.event("img", "stale", "取消 \(toCancel.count) 个已滑过的在飞任务（< 页 \(cutoff)）")
    }

    /// 闲置时继续往前补几批（用户停住不动 → 继续把后面的页拉进磁盘缓存）。
    ///
    /// 规则：
    ///   · 每批 = `ahead` 张，间隔 1.5 秒，最多补 **2 批**（合计 ahead×3 ≈ 30 页）
    ///   · **锚点必须没变**才补 —— 用户滑走了还补旧位置纯属浪费带宽
    ///     （2026-10-16 那次「整章被拉完」的教训：预载只能由当前视口驱动）
    ///   · 一律走 `runLimited`（低优先级 `.ahead`），可视区永远优先
    private func scheduleIdleExtension(center: Int, ahead: Int, round: Int) {
        guard round <= 2 else { return }
        idleExtendTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.lock.lock()
            let sameAnchor = (self.lastPreloadCenter == center)
            let total = self._urls.count
            self.lock.unlock()
            guard sameAnchor else { return }
            let lo = center + ahead * round + 1
            let hi = min(total - 1, center + ahead * (round + 1))
            guard lo <= hi else { return }
            DiagLog.event("img", "idle", "闲置补载第 \(round) 批：页 \(lo)…\(hi)")
            self.runLimited(Array(lo...hi))
            self.scheduleIdleExtension(center: center, ahead: ahead, round: round + 1)
        }
    }

    /// 内存窗口：保留「当前页 −back ～ 当前页 +ahead」的**已解码**图，其余释放。
    ///
    /// ## 为什么必须有它
    /// `_loaded` 原先**只增不减**（全仓库唯一的删除点是 `retry()`），
    /// 本章每一张成功加载的图都**永久驻留**。
    /// 长章（条带源 / 禁漫天堂常见 100~300 页）按单页 1080×3000 RGBA ≈ 12MB 估，
    /// 50 页就是 400MB+ → **必被 Jetsam 杀进程**。
    /// Nuke 的 `ImageCache`（`costLimit` 100MB）救不了 —— `_loaded` 持强引用，
    /// 与 Nuke 自身的逐出逻辑完全无关。
    ///
    /// ## 窗口取值
    /// 往后 10 页（主要阅读方向，与 `effectiveAhead` 一致）+
    /// 往前 5 页（回看时少一次重新解码）。共 ~16 页 ≈ 200MB 上限，
    /// 在「不杀进程」与「回看不闪白」之间取的折中。
    ///
    /// ⚠️ 淘汰**不发** `objectWillChange`：被淘汰的页都在可视窗口之外，
    ///    UI 上没有可观察变化；发通知只会白白触发一次重绘。
    private static let memoryWindowBack = 5
    private static let memoryWindowAhead = 10

    private func evictOutsideWindow(center: Int) {
        let lo = center - Self.memoryWindowBack
        let hi = center + Self.memoryWindowAhead
        lock.lock()
        let evict = _loaded.keys.filter { $0 < lo || $0 > hi }
        for k in evict { _loaded[k] = nil }
        // ⚠️ 只淘汰**图像**，`_ratios` 一律保留 —— 比例是布局的依据，
        //    丢掉它会让页面高度回退到占位估算 → 内容整体位移（视觉割裂）。
        lock.unlock()
        if !evict.isEmpty {
            DiagLog.event("img", "evict", "内存窗口淘汰 \(evict.count) 页（保留 \(lo)…\(hi)）")
        }
    }

    /// 受限并发预载：只负责「为还没加载的页起任务」，并发额度统一由 `Self.gate` 管。
    ///
    /// ⚠️ 这里**不再预先占据 inflight**。旧实现先 insert 再 await 闸门，
    /// 导致 `image(at:)` 看到 inflight 就去死等（→ 30 秒轮询的来源）。
    /// 现在统一走 `image(at:)`，由它来保证去重。
    ///
    /// ── 2026-10-17 第五轮改造：**去掉并行的 Nuke 预取器** ────────────────
    /// 原来这里先 `HMDImagePipeline.prefetcher.startPrefetching(with:)` 预取字节，
    /// 再起一遍加载任务（「两路并行」）。实测问题：
    ///   · 两路是**同一批 URL**，虽然 Nuke 会合并同 URL 请求，但预取器先起的那批
    ///     会额外占连接 → 实际并发可能到「闸门 10 + 预取器 6 = 16」，
    ///     而图站实测 **18 路就开始丢请求**（15/18 成功）→ 反而拖慢甚至失败。
    ///   · `startPrefetching` 会把请求优先级**强制改成 prefetcher 的 `.low`**，
    ///     可视区页面的任务一旦被预取器抢先建出来，就变成低优先级下载。
    ///   · 我们自己的任务本来就是**非结构化 Task**（存在 `inflight` 里），
    ///     cell 回收不会取消它 —— 预取器「与渲染解耦」的好处本来就拿到了。
    /// 现在只保留一条路径：统一走 `image(at:)` + 闸门，优先级可控、并发可控。
    private func runLimited(_ range: [Int]) {
        let pending: [Int]
        lock.lock()
        pending = range.filter { _urls.indices.contains($0) && _loaded[$0] == nil && !_failed.contains($0) && inflight[$0] == nil }
        lock.unlock()
        guard !pending.isEmpty else { return }

        // 离线章节：本地文件已经在盘上，直接读。
        if isOffline {
            for j in pending { Task { [weak self] in _ = await self?.image(at: j) } }
            return
        }

        // 起加载任务（走统一闸门）。
        // ⚠️ 预载一律 `.ahead`（低优先级）：这些页在视口之外，不该和可视区抢连接。
        for j in pending {
            Task { [weak self] in
                _ = await self?.image(at: j, priority: .ahead)
            }
        }
    }
}

/// 图片加载优先级（给 `AsyncGate` 与 Nuke 请求共用）。
///
/// 为什么不直接用 Nuke 的 `ImageRequest.Priority` 当排队键：
/// 闸门的等待队列需要一个**可排序的 Int**，而 `ImageRequest.Priority` 是 Nuke
/// 的封装类型（内部是 Float），拿它当队列键既多余又增加版本耦合风险。
/// 这里只用最朴素的两档。
enum LoadPriority: Int, Sendable {
    /// 可视区（锚点 + 紧邻几张）—— 优先拿连接
    case visible = 0
    /// 视口以外的预载 —— 让路
    case ahead = 1

    /// 传给 Nuke 的请求优先级（决定 `URLSessionTask.priority`）
    var nuke: ImageRequest.Priority {
        switch self {
        case .visible: return .normal
        case .ahead:   return .low
        }
    }
}

/// 异步并发闸门（信号量）—— 用 actor 而非 DispatchSemaphore：
/// 后者在 async 上下文里 `wait()` 会阻塞协作线程池，极易死锁。
///
/// ⚠️ 额度守恒是这个类的**唯一不变量**：`acquire()` 拿到额度（active += 1
/// 或从 waiters 里被直接移交给），`release()` 必须正好还掉一次。
/// 旧实现 `release()` 在 `guard !waiters.isEmpty` 分支里不减 `active`、
/// 直接把额度转交 —— 数学上没错，但一旦 `run` 的 body 里抛错/被取消导致
/// `release()` 被跳过，`active` 就会永久泄漏，闸门彻底堵死（所有图片全挂）。
/// 这里改用 `defer` 保证一定归还，并把「转交」写成「先减再加」，
/// 任何单点失败都不会污染额度计数。
actor AsyncGate {
    private let limit: Int
    private var active = 0

    /// 等待者。`priority` 越小越优先（`LoadPriority.visible.rawValue` = 0，
    /// `.ahead` = 1）；**同优先级严格按先来后到**（靠 `seq` + 严格小于比较保证）。
    ///
    /// 为什么要按优先级排队（2026-10-17）：闸门原来是纯 FIFO ——
    /// 用户快滑时，前面 10 个额度全被「视口以外的预载」占着，
    /// 刚滑到屏幕上的那一页只能排在它们后面，一等等 1~2 秒。
    private struct Waiter {
        let priority: Int
        let seq: Int
        let cont: CheckedContinuation<Void, Never>
    }
    private var waiters: [Waiter] = []
    private var seqCounter = 0

    init(limit: Int) { self.limit = max(1, limit) }

    private func acquire(priority: Int) async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            seqCounter += 1
            waiters.append(Waiter(priority: priority, seq: seqCounter, cont: c))
        }
        // 被 resume 时额度已经由 release() 记在自己名下，这里不再自增
    }

    private func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
            return
        }
        // 先归还再转交，保证计数始终守恒
        active = max(0, active - 1)
        // 挑优先级最高（数值最小）的那个；严格小于 ⇒ 同优先级不会被后来者插队
        var pick = 0
        var i = 1
        while i < waiters.count {
            if waiters[i].priority < waiters[pick].priority { pick = i }
            i += 1
        }
        let w = waiters.remove(at: pick)
        active += 1
        w.cont.resume()
    }

    /// - Parameter priority: 数值越小越优先（默认 1 = 预载，让路给可视区）
    func run<T>(priority: Int = 1, _ body: @Sendable () async -> T) async -> T {
        await acquire(priority: priority)
        defer { release() }        // ⚠️ 必须 defer：body 抛错/取消也要归还额度
        return await body()
    }

    /// 调试用：当前在飞数量
    var debugActive: Int { active }
    var debugWaiting: Int { waiters.count }
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - 图集收藏：取「原始字节」
// ──────────────────────────────────────────────────────────────────────────────
extension ChapterImageStore {
    /// 取某一页的**原始图片字节**（已过图源解码），供图集收藏使用。
    ///
    /// ── 为什么不复用 `loadRaw` ──────────────────────────────────────────────
    /// `loadRaw` 是阅读器的**热路径**：返回「已解码 + 已裁白边」的 `UIImage`，
    /// 且带着一整套为滚动优化的取消/重试/失败标记逻辑。
    /// 收藏是**低频动作**（用户偶尔点一下），为省一次请求去动主链路，
    /// 风险远大于收益 —— 阅读器一旦回归，用户立刻能感觉到。
    ///
    /// 这里只做「同一套 headers 取字节 → 跑同一个解码器」，
    /// 保证收藏到的字节和在线阅读看到的**是同一份**（都过了 `decodeBytes`）。
    /// 注意：**不裁白边** —— 收藏要的是原图，裁剪是阅读器的显示偏好。
    func originalBytes(at index: Int) async -> Data? {
        guard let url = urlAt(index) else { return nil }
        var hh: [String: String] = ["Referer": referer, "User-Agent": ua]
        for (k, v) in extraHeaders { hh[k] = v }
        guard let req = HMDImagePipeline.request(url: url, referer: referer, ua: ua, headers: hh) else {
            return nil
        }
        do {
            let (d, _) = try await HMDImagePipeline.shared.data(for: req)
            guard !d.isEmpty else { return nil }
            return await Self.decodeBytes(d, origin: origin, baseUrl: url, headers: hh)
        } catch {
            return nil
        }
    }
}

// ── 已删除：DecodedImageCache / ImageDiskCache ──────────────────────────────
// 第四轮改造把这两者都交给了 Nuke（`HMDImagePipeline`）：
//   · 内存缓存 → `Nuke.ImageCache`（costLimit 100MB，按像素计费，LRU + 自动逐出）
//   · 磁盘缓存 → `Nuke.DataCache`（sizeLimit 500MB，按原始字节 LRU）
// 保留自己的实现只会造成「两份缓存互不同步、内存双倍占用」。
//
// 注意：本项目仍有解密需求（`RULE_BOOK_CONTENT_DECODER`），
// 解密后的字节会**回写** Nuke 缓存（见 `loadRaw` 里 `cache.storeData(_:for:cacheType:)`），
// 因此下载一次之后，后续都是「本地命中 + 解码」。
