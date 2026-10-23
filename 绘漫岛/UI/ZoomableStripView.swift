import SwiftUI
import UIKit

/// ── 每页高度 / 占位高度的**唯一实现** ────────────────────────────────────────
///
/// 页面高度 = 内容宽度 × 宽高比。比例优先取**该页自己的真实值**，其次本章
/// **中位数**，最后兜底 1.45。
///
/// ⚠️ 内容视图与协调器**必须调同一个函数** —— 否则「渲染出来的行高之和」
///    与「我们交给 `UIScrollView` 的 `contentSize`」会对不上（底部空一块 / 内容重叠）。
enum StripMetrics {
    /// 兜底宽高比（一个典型漫画页）。只有本章一页都没加载出来时才会用到。
    static let fallbackRatio: CGFloat = 1.45

    /// 相邻页之间的视觉间距（pt）。**当前为 0：页与页严格无缝相接。**
    ///
    /// 变迁（都是包子漫画图源的真机反馈）：
    ///  · v86 曾设为 6pt —— 该源的「页」是 1280×1000 的**横版画格条**
    ///    （比例 ~0.78），滚动模式下同屏叠 2~3 条、内容天然衔接，
    ///    紧贴时被读成「图片叠加在一起」。
    ///  · 2026-10-16 改回 **0** —— 槽高 = `宽×比例 + spacing`，而图片是
    ///    `scaledToFit` 按宽度铺满（实际高 = `宽×比例`），那 6pt 会**空出来
    ///    露出黑背景**，在连续画格条上就是一条黑缝（用户：「每页图片跟下一页
    ///    有黑边，影响观看」）。要无缝，高度里就不能留余量。
    ///  · 结论：**spacing = 0** → 槽高严格等于图片高度，既不重叠也无缝。
    ///
    /// ⚠️ 仍保留「间距计入每页高度」的算法（而不是改 `VStack` 的 spacing）——
    ///    这样占位器总高、`contentSize`、续读定位（`cumY`）三处的账自动对齐，
    ///    将来若要加分隔，只改这一个常量即可。
    static let stripSpacing: CGFloat = 0

    /// 一次算出整章每页的高度（内部只向 store 取一次比例快照，不逐页加锁）
    static func heights(store: ChapterImageStore, width: CGFloat) -> [CGFloat] {
        let snap = store.ratioSnapshot()
        let w = max(width, 1)
        let est = snap.median ?? fallbackRatio
        return (0..<snap.count).map { i in
            let r = snap.known[i] ?? est
            return max(1, w * r + stripSpacing)
        }
    }
}

/// ── 整条内容（窗口内的页 + 上下等高占位 + 章节末尾那一行）────────────────────
///
/// ## 为什么高度是**自己算**、而不是外面传进来
/// 图片加载完会学到真实宽高比 → 该页高度变化。若高度由外部算好再传进来，
/// 就只能**整棵内容树重建**才能让新高度生效 —— 而重建的那一瞬间内容会空白
/// （用户看到的就是「黑屏」），而且**每加载一张图就重建一次**。
///
/// 现在这里直接 `@ObservedObject var store`：store 一变，SwiftUI 只会
/// **重新计算各行 frame**，内容树本身保留 —— 不重建、不闪。
struct StripContentView: View {
    @ObservedObject var store: ChapterImageStore
    /// 本次要渲染的页区间（窗口）
    let range: Range<Int>
    /// 内容宽度（= 视口宽度），用于算每页高度
    let width: CGFloat
    /// 章节末尾「下一章」那一行的高度
    let footerHeight: CGFloat
    /// 「下一章」那一行本身（由外部构建，因为它依赖章节信息）
    let nextChapter: AnyView

    var body: some View {
        let hs = StripMetrics.heights(store: store, width: width)
        let lo = max(0, min(range.lowerBound, hs.count))
        let hi = max(lo, min(range.upperBound, hs.count))
        VStack(spacing: 0) {
            // 窗口之前的页：等高空白占位（高度 == 该页应有的高度）→ 布局精确、滚动条准确
            Color.clear.frame(height: hs[0..<lo].reduce(0, +))
            ForEach(lo..<hi, id: \.self) { i in
                // 🔴 `alignment: .top` 是**必须的**（2026-10-17 用户反馈「首页的图片没有
                //    定格在页首上」）：`scaledToFit` 在默认（居中）对齐下，只要槽位高度
                //    与图片实际高度有一点点差异，图片就会**在槽位里垂直居中** ——
                //    表现为「图片浮在页中间、上面留一条黑」，而且高度一修正就整体上跳。
                //    顶部对齐后，图片永远贴着本页顶端（= 页首），多余的空白只出现在
                //    下方（且随比例修正立刻消失），不会再让内容"漂移"。
                StoreImage(store: store, index: i)
                    .frame(height: max(hs[i], 1), alignment: .top)
            }
            // 窗口之后的页：同样等高占位
            Color.clear.frame(height: hs[hi...].reduce(0, +))
            nextChapter.frame(height: footerHeight)
        }
    }
}

/// ── 滚动模式的整条缩放容器（**单一 `UIScrollView` 承载整章**）──────────────────
///
/// ## 为什么必须是「整条」而不是「按页」
/// 按页缩放时每页是一个独立的 `UIScrollView`，各自以自己为中心放大 ——
/// 相邻页仍是原始比例，视觉上就是「只放大一页，其余页面割裂」。
/// 整条缩放把所有页放在**同一个** `UIScrollView` 里，缩放作用于整条 →
/// 所有页等比放大、位置连续。
///
/// ## 内容总高怎么来（`UIScrollView` 缩放要求确定尺寸）
/// 不依赖图片真实高度，而是由 `StripMetrics` 按「宽 × 宽高比」算出 ——
/// 已加载过的页用真实比例，没加载过的用本章中位数估算。所以**任何时刻**都能给出
/// `contentSize`。
///
/// ## 懒加载怎么保住（内存红线）
/// 内容只渲染**窗口内**的若干页，窗口之外是**等高空白占位**。
/// 于是：① 只有窗口内的页会真正发起图片加载（不会一次解码几十张图）；
///       ② 布局高度依然精确。
///
/// ## 缩放/平移/双击为什么不用手算锚点
/// `minimumZoomScale` / `maximumZoomScale`（捏合自动以两指中点为中心）、
/// `viewForZooming`（平移边界系统 clamp）、`zoom(to:)`（双击定点放大）
/// —— 三件事 `UIScrollView` 原生就对。本文件里**没有任何锚点换算**。
struct ZoomableStripView: UIViewRepresentable {
    /// 当前章节的图片加载器（同时是内容的观察对象）。
    ///
    /// 🔴 **必须是 `@ObservedObject`**（2026-10-17 真机实锤）：原来是 `let store`，
    ///    于是 store 发布变化（图片加载完、学到真实宽高比）时**不会**触发
    ///    `updateUIView` → `refresh()` 不跑 → `contentSize` 一直停在「估算总高」。
    ///    实测：条漫真实比例 0.6~0.9、估算 1.455，总高被高估近一倍（27279 vs ~14500），
    ///    滚动视图认为内容比实际长得多 → 首屏定位错、少显示几页、滑一下才对。
    ///    真机日志：图片 11:55:52 就加载完，`[metrics]` 直到 11:56:34（缩放结束）才更新。
    @ObservedObject var store: ChapterImageStore
    /// 内容宽度（= 视口宽度）
    let contentWidth: CGFloat
    /// 章节末尾「下一章」那一行的高度（计入内容总高，但不参与页码换算）
    let footerHeight: CGFloat
    /// 「下一章」那一行本身
    let nextChapter: AnyView
    /// 当前页变化（外部做节流与进度保存）
    let onPageChange: (Int) -> Void
    /// 是否已放大（> 1.01）
    let onZoomChanged: (Bool) -> Void
    /// 单击（呼出菜单）
    let onSingleTap: () -> Void
    /// 翻页模式：**按屏幕高度吸附**（滑一次正好一屏）。滚动模式为 false。
    var pageSnap: Bool = false
    /// 翻页模式：单击分区（0 左 / 1 中 / 2 右）。滚动模式为 nil（只呼出菜单）。
    var onTapZone: ((Int) -> Void)? = nil
    /// 外部请求「滚动一屏」：`scrollSeq` 变化即执行一次，`scrollBy` 是位移（点）。
    var scrollSeq: Int = 0
    var scrollBy: CGFloat = 0
    /// 需要跳转到的页（-1 表示没有请求）
    let restorePage: Int
    /// 双击是否放大。
    ///
    /// 🔴 以前滚动模式的 `handleDoubleTap` **完全不读这个开关**，
    ///    用户关掉「双击缩放」后双击照样放大（开关是假的）。
    ///    翻页/双页模式那边是读的，只有滚动模式漏了。（由智能体「阅器」发现）
    var doubleTapZoomEnabled: Bool = true
    /// 跳转已执行
    let onRestoreHandled: () -> Void
    /// 诊断桥（可选）—— 仅用于自动化复现「缩放后黑屏 / 跳页」，正常使用传 nil。
    /// 见 `StripDiagBridge` 的说明。
    var diag: StripDiagBridge? = nil
    /// 诊断触发计数 —— 值变化会让 SwiftUI 重算 body → `updateUIView` → 消费 `diag.pending`。
    /// （`StripDiagBridge` 是普通 class，不是 `ObservableObject`，改它的属性不会触发刷新。）
    var diagTick: Int = 0

    /// `store` 的变更计数（`ReaderView` 订阅 `store.objectWillChange` 后递增）。
    ///
    /// 只用于**强制 SwiftUI 重算本视图** —— 值一变 → `updateUIView` → `refresh()`。
    /// `@ObservedObject store` 已经是主通道，这里是**双保险**：万一某条路径下
    /// representable 没有因对象变化而重建，参数变化也一定会走到 `updateUIView`。
    /// （`ReaderView` 里那个 `storeTick` 状态以前只自增、没人读，等于空转 —— 见其注释。）
    var storeTick: Int = 0

    func makeUIView(context: Context) -> UIScrollView {
        let sv = UIScrollView()
        sv.delegate = context.coordinator
        sv.minimumZoomScale = 1
        sv.maximumZoomScale = 6
        sv.bouncesZoom = true
        sv.alwaysBounceVertical = true
        sv.showsVerticalScrollIndicator = true
        sv.showsHorizontalScrollIndicator = false
        // ⚠️ 关掉系统自动 inset：否则安全区会被算进内容尺寸，整条被顶偏
        sv.contentInsetAdjustmentBehavior = .never
        sv.contentInset = .zero
        sv.scrollIndicatorInsets = .zero
        sv.backgroundColor = .clear

        let host = UIHostingController(rootView: context.coordinator.makeContent(range: 0..<0))
        host.view.backgroundColor = .clear
        context.coordinator.host = host
        sv.addSubview(host.view)
        sv.decelerationRate = pageSnap ? .fast : .normal

        let dbl = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleDoubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        sv.addGestureRecognizer(dbl)
        context.coordinator.doubleTap = dbl

        // 单击呼出菜单 —— ⚠️ **必须 `require(toFail: 双击)`**，
        // 否则双击的第一下就会先把菜单弹出来（菜单一闪一闪）。
        let single = UITapGestureRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.handleSingleTap(_:)))
        single.numberOfTapsRequired = 1
        single.require(toFail: dbl)
        single.delegate = context.coordinator
        sv.addGestureRecognizer(single)
        return sv
    }

    func updateUIView(_ sv: UIScrollView, context: Context) {
        // `diagTick` 不参与任何逻辑，唯一作用是「值变化 → SwiftUI 认为本视图要更新 →
        // 走到这里 → 消费 `diag.pending`」。显式读一下，免得将来被当成死参数删掉。
        _ = diagTick
        // 同上：`storeTick` 只用来把「store 变了」翻译成一次 `updateUIView`。
        _ = storeTick
        context.coordinator.parent = self

        // 按屏翻页：外部点了左/右分区 → 滚动一屏
        if scrollSeq != context.coordinator.lastScrollSeq {
            context.coordinator.lastScrollSeq = scrollSeq
            context.coordinator.scrollBy(points: scrollBy, in: sv)
        }

        // ── ① 续读落位：**必须在 `refresh` 之前** ─────────────────────────────
        // 🔴 顺序就是「打开漫画闪一下」的修复点：
        //    `refresh` 会按当前 `contentOffset` 决定渲染窗口。若先 `refresh` 再跳转，
        //    第一次渲染的是「第 0 页」的窗口，跳转后又重建一次 ——
        //    两次内容重建之间会**提交一帧第 0 页的画面**（用户看到的「闪一下照片」）。
        //    先摆好偏移、再让 `refresh` 第一次就按目标页建窗口，中间那一帧根本不存在。
        //
        // ⚠️ 这里只算高度 + 设偏移，**不碰渲染窗口**（窗口交给紧随其后的 `refresh`
        //    一次性决定），所以不会像 `scroll(toPage:)` 那样多重建一次内容。
        var restored = false
        if restorePage >= 0 {
            restored = context.coordinator.prepareRestore(restorePage, in: sv)
        }

        context.coordinator.refresh(sv)
        // 兜底：若缩放已结束但还没补做，这里补上（`zoomed` 翻转会走到这）
        context.coordinator.applyPendingRefreshIfNeeded(sv)
        // 诊断：消费外部排队的操作（队列为空时是空转，开销可忽略）
        context.coordinator.drainDiag(sv)

        // ⚠️ 只有「回调外部改写 `@State`」这件事必须异步 —— `updateUIView` 处于
        //    SwiftUI 的视图更新周期内，此刻改 `stripRestorePage` / `pendingVisiblePage`
        //    会触发「Modifying state during view update」。
        if restored {
            let target = restorePage
            let done = onRestoreHandled
            let report = onPageChange
            DispatchQueue.main.async {
                report(target)
                done()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: ZoomableStripView
        var host: UIHostingController<StripContentView>?
        weak var doubleTap: UITapGestureRecognizer?
        var lastScrollSeq = 0

        /// 每页高度（与 `StripContentView` 用**同一个** `StripMetrics` 算出来）
        private var heights: [CGFloat] = []
        /// 每页顶部 Y（长度 = 页数 + 1；最后一项 = 所有页总高）
        private var cumY: [CGFloat] = [0]
        /// 当前已渲染的页窗口
        private var window: Range<Int> = 0..<0
        /// 上一次上报的页码
        private var lastReported = -1
        /// 上一次渲染时用的 store 身份 —— 换章会换 store 实例，必须重建内容
        private var lastStoreID: ObjectIdentifier?
        /// 换了 store 但**还没**重建内容（因为当时一页都还没有）。
        /// ⚠️ 不能一换 store 就把内容清空 —— 清空 = 内容区全黑（用户看到的就是黑屏）。
        private var pendingStoreRebuild = false
        /// 上一次已记录的「页数」，用于只在变化时记日志（避免刷屏）
        private var lastLoggedCount = -1
        /// 放大期间有被推迟的 `refresh` —— 回到 1x 后必须补做一次。
        private var needsRefreshAfterZoom = false
        /// 正在**程序化**调整内容尺寸/偏移（不是用户滚动）。
        /// 这期间会同步触发 `scrollViewDidScroll`，必须跳过页码上报 ——
        /// 否则会在 SwiftUI 的视图更新周期里改写外部 `@State`
        /// （"Modifying state during view update"）。
        private var isAdjusting = false

        /// 🔴 缩放（捏合 / 双击 / **弹性回弹**）进行中 —— 期间**绝不**更新窗口与页码。
        ///
        /// 这是「缩小之后先黑屏、后跳页」的根因：
        ///   `bouncesZoom = true` 时，用户往下捏（缩小）会短暂缩到 `zoomScale < 1`，
        ///   松手后弹性回弹到 1。**回弹期间旧判据 `zoomScale <= 1.01` 会放行** ——
        ///   于是 `page(at: contentOffset.y / zoomScale)` 用「正在变化的 zoomScale」
        ///   去除 offset，算出**完全错误的可见页** → 窗口重建到别处（可见区无内容 =
        ///   黑屏），同时上报错误页码（跳页）。
        ///
        ///   ⚠️ 顶部时 `contentOffset.y ≈ 0`，`0 / 任何 zoomScale` 仍是 0 →
        ///      可见页恒为 0、窗口恒为 `0..<8` → **顶部缩小不出问题**；
        ///      下滑之后 offset > 0，回弹就会让可见页乱跳 —— 与用户反馈
        ///      「最上面缩小没问题、下滑一点之后缩小就出问题」完全吻合。
        private var isZooming = false

        /// 上一次记录「refresh 被推迟」时的 zoomScale（避免每个 frame 都刷日志）
        private var lastZoomLogScale: CGFloat = -1

        init(_ p: ZoomableStripView) { parent = p }

        private var pagesHeight: CGFloat { cumY.last ?? 0 }
        private var totalHeight: CGFloat { pagesHeight + parent.footerHeight }

        /// 构造内容视图（**具体类型**，不是 `AnyView`）——
        /// 具体类型能让 SwiftUI 更好地保持结构标识，避免整树重建。
        func makeContent(range: Range<Int>) -> StripContentView {
            StripContentView(store: parent.store, range: range,
                             width: parent.contentWidth,
                             footerHeight: parent.footerHeight,
                             nextChapter: parent.nextChapter)
        }

        /// 重算每页高度与累计 Y；返回「高度表是否变化」
        private func recomputeMetrics() -> Bool {
            let hs = StripMetrics.heights(store: parent.store, width: parent.contentWidth)
            guard hs != heights else { return false }
            heights = hs
            var y: CGFloat = 0
            var out: [CGFloat] = [0]
            out.reserveCapacity(hs.count + 1)
            for h in hs {
                y += max(h, 1)
                out.append(y)
            }
            cumY = out
            return true
        }

        /// 视口顶端落在第几页 —— 取「顶部已经越过视口顶端、且最靠下」的那一页。
        ///
        /// ⚠️ **必须能指定用哪张高度表**（`table`）。原因见 `refresh` 里的高度补偿：
        ///    那里拿的是一个**旧坐标系**下的 `oldTop`，一旦用**新**高度表去查，
        ///    内容变矮时会返回偏大很多的页号 —— 那是「白屏 / 画面乱跳 / 进度错乱」的根因。
        private func page(at y: CGFloat, in table: [CGFloat]) -> Int {
            // 🔴 必须以**传入的表**为界，不能用 `heights.count`（2026-10-17 真机实锤）：
            //    补偿时传进来的是**旧**高度表 `oldCum`。分页章追加页数时
            //    `oldCum` 有 50 项、新表 `heights` 有 58 项 —— 旧代码的
            //    `guard table.count > heights.count else { return 0 }` 直接判失败，
            //    于是**锚点页恒为 0**，`within` 被 clamp 到页 0 的高度，
            //    视口被往回拽几百 px（日志：`补偿 797→562（页 0 移 234px）`，
            //    而 797 明明已经在第 2 页里）→ 用户看到「跳到某页又变回第一页」。
            //    现在按 table 自己的长度二分，索引含义就正确了；
            //    调用方（补偿）另有「idx 不得超出新表」的护栏。
            let n = table.count
            guard n > 0 else { return 0 }
            var lo = 0, hi = n - 1, best = 0
            while lo <= hi {
                let mid = (lo + hi) / 2
                if table[mid] <= y + 1 { best = mid; lo = mid + 1 } else { hi = mid - 1 }
            }
            return best
        }

        /// 用当前高度表定位（绝大多数调用点用这个）
        private func page(at y: CGFloat) -> Int { page(at: y, in: cumY) }

        /// 内容尺寸 / 窗口 / 滚动补偿 —— 每次 SwiftUI 更新都会走这里
        func refresh(_ sv: UIScrollView) {
            let w = parent.contentWidth
            guard w > 0 else { return }

            // ── 🔴 缩放期间（含缩小回弹）**一律推迟**，不做任何尺寸/内容改动 ─────
            // `refresh` 会做两件在缩放态下有害的事 ——
            //   ① 改 `host.view.frame` / `sv.contentSize`：
            //      被 `viewForZooming` 缩放的那层此刻带着 `transform`，
            //      改 `frame` 会**破坏 transform**（frame 由 bounds+center+transform 决定）
            //      → 内容错位；同时 `UIScrollView` 会**重新 clamp `contentOffset`**
            //      → 位置突变（跳页）；
            //   ② 重建内容 → 正在被缩放的那一层瞬间空白（黑屏）。
            //
            // ⚠️ 判据**不能只写 `zoomScale > 1.01`** —— 那样只挡住「放大」，
            //    挡住不「缩小到 < 1 的弹性回弹」，而后者正是黑屏跳页的元凶。
            //    现在用「缩放进行中（`isZooming`）」或「zoomScale 未回到 1」两个条件**并集**。
            if isZooming || abs(sv.zoomScale - 1) > 0.01 {
                needsRefreshAfterZoom = true
                if abs(lastZoomLogScale - sv.zoomScale) > 0.02 {
                    lastZoomLogScale = sv.zoomScale
                    DiagLog.event("strip", "zoom",
                                  "refresh 被推迟（zoom=\(String(format: "%.3f", sv.zoomScale))"
                                  + " isZooming=\(isZooming)）")
                }
                return
            }

            isAdjusting = true
            defer { isAdjusting = false }

            let zoom = max(sv.zoomScale, 0.01)
            let oldTop = sv.contentOffset.y / zoom          // 视口顶端（内容坐标）
            let oldCum = cumY
            let oldTotal = totalHeight

            _ = recomputeMetrics()
            let total = max(totalHeight, 1)
            if lastLoggedCount != heights.count {
                lastLoggedCount = heights.count
                DiagLog.event("strip", "metrics",
                              "页数 \(heights.count) 内容总高 \(Int(total)) 宽度 \(Int(w))")
            }

            let size = CGSize(width: w, height: total)
            if host?.view.frame.size != size {
                host?.view.frame = CGRect(origin: .zero, size: size)
            }
            sv.contentSize = size

            // ── 高度变化补偿 ──────────────────────────────────────────────
            // 图片加载完 → 该页真实比例已知 → 高度从「估算」变成「真实」。
            // 保持**视口顶端那一页的顶端**不动，用户正在看的位置就不会跳。
            // ⚠️ 内容本身**不用重建**：`StripContentView` 观察 store，会自己重算行高。
            //
            // 🔴 这里踩过一个致命的坑，务必按下面的写法来：
            //    `oldTop` 是**旧坐标系**下的偏移，所以定位必须用**旧**高度表 `oldCum`。
            //    曾经写成 `page(at: oldTop)`（用的是**刚刚重算过的** `cumY`）——
            //    当真实比例比兜底值 1.45 小很多（宽图）时，新表整体变矮，
            //    用旧 offset 去查新表会落到**大几十页之后**的索引，
            //    于是 `delta = cumY[idx] - oldCum[idx]` 变成「跨几十页的高度差」，
            //    偏移被一把拉到 0（或被 clamp）——用户看到的就是：
            //      ① 画面瞬间跳到别处（「卡闪」）；
            //      ② 可见页与渲染窗口脱节 → 整屏空白，动一下才出来（「白屏」）；
            //      ③ 那次错误的 offset 又被 `scrollViewDidScroll` 当成用户滚动上报
            //         → 进度被写成错的页（「进度没保存」）。
            //    另外 `sv.bounds.height == 0` 说明视图还没布局 / 正在被移除，
            //    此时改 offset 只会制造抖动，直接跳过。
            // 🔴 顶端锚点必须绝对稳定（2026-10-17 用户反馈「首页的图片没有定格在页首」）：
            //    只要视口还停在首页顶端附近，任何高度变化都不该把内容推走 —— 直接钉回 0。
            //    这条与下面的补偿互不冲突：补偿要求 `oldTop > 0`，而这里处理的是 ≈0 的情况。
            if oldTop < 1, sv.contentOffset.y != 0 {
                sv.contentOffset = CGPoint(x: sv.contentOffset.x, y: 0)
            }

            // 🔴 2026-10-17：**页数变化时也必须补偿**（用户反馈「打开先出一帧、然后黑屏、
            //    下滑才正常」的真凶）。
            //
            //    原来这里的第一个条件是 `oldCum.count == cumY.count`（页数不变才补偿）。
            //    但包子漫画这类源是**分页章**：首屏先给 50 页，几秒后再追加到 88/100 页
            //    （`[metrics] 页数 50 → 88`）。追加那一刻页数变了 → 条件为 false →
            //    **此后所有高度修正都失去补偿**：图片陆续到达、页高从估算变真实，
            //    内容在用户眼前整体位移 → 视口落到渲染窗口之外，而窗口外是
            //    `Color.clear`（= 纯黑）→ 用户看到「一帧图 + 黑屏，滑一下才恢复」。
            //    真机日志实证：这两次分页章打开**一条 `[fixup]` 都没有**，
            //    且进度从 `页=1` 弹回 `页=0`。
            //
            //    页是**追加**的（index 稳定、不插入不重排），所以用**旧表**定位出的锚点页
            //    在新表里依然有效 —— 只要它没超出新表长度。
            if !oldCum.isEmpty, oldTotal != total, oldTop > 0, sv.bounds.height > 0 {
                let idx = page(at: oldTop, in: oldCum)
                if idx >= cumY.count || idx >= heights.count {
                    // 锚点页在新表里不存在（极罕见：章节内容被换掉/页数变少）
                    DiagLog.event("strip", "fixup",
                                  "⚠️ 补偿跳过：锚点页 \(idx) 超出新高度表（\(cumY.count) 页）")
                } else {
                    // 页内偏移原样保留（不要只对齐页顶端，否则页内位置也会跳）
                    let within = max(0, oldTop - oldCum[idx])
                    let newTop = cumY[idx] + min(within, max(heights[idx], 1))
                    // ── 🔴 保险：位移超过「高度表实际变化量 + 一页」就判定为误算 ───
                    //
                    // ⚠️ 这里以前写的是「超过 3 页就跳过」，**结果把正确补偿也跳掉了**。
                    //    2026-10-13 真机日志实锤（用户反馈「修了没变化」）：
                    //      `⚠️ 补偿被跳过：位移 2195px 超过 3 页上限（页 8，总高 90354→47880）`
                    //      `⚠️ 补偿被跳过：位移 2938px 超过 3 页上限（页 10，总高 90354→40697）`
                    //    总高腰斩 47%（占位比 1.45 → 真实比例 ~0.77），
                    //    **补偿本来就应该是这个量级**。跳过它 → 内容在用户眼前整体上移
                    //    = 「自动往上滑」+「黑屏」，正是没修好的那个 bug。
                    //
                    // 合理的补偿位移只会来自「锚点页**上方**的高度变化」，
                    // 所以位移 > |总高变化| + 一页高 一定是算错了（那才是该拦的情况）。
                    let shift = abs(newTop - oldTop)
                    // heights 与 cumY 同源（count = 页数），正常一定非空 —— 但这里仍防一手：
                    // `heights[heights.count - 1]` 在空数组时就是 `heights[-1]`，
                    // Swift 运行时会**直接崩溃**（阅读器里崩一下比坏一点严重得多）。
                    let pageH: CGFloat = heights.isEmpty ? 1 : heights[min(idx, heights.count - 1)]
                    let tableDelta = abs(oldTotal - total) + max(pageH, 1)
                    if shift <= tableDelta {
                        sv.contentOffset = CGPoint(x: sv.contentOffset.x,
                                                   y: max(0, newTop * sv.zoomScale))
                        if shift > 1 {
                            DiagLog.event("strip", "fixup",
                                          "补偿 \(Int(oldTop))→\(Int(newTop))（页 \(idx) 移 \(Int(shift))px，总高 \(Int(oldTotal))→\(Int(total))）")
                        }
                    } else {
                        DiagLog.event("strip", "fixup",
                                      "⚠️ 补偿被跳过：位移 \(Int(shift))px 超过高度表变化量 \(Int(tableDelta))px（页 \(idx)，总高 \(Int(oldTotal))→\(Int(total))）")
                    }
                }
            }

            // ── 渲染窗口 ──────────────────────────────────────────────────
            updateWindow(sv)

            // 🔎 逐帧视口诊断（2026-10-17 加）：只在「高度表变化」时打一条。
            //    用户反馈「首页图片没定格在页首 / 打开先出一帧再黑屏」，前两轮只能从
            //    间接线索推断，加这条就能直接看到「视口在哪、渲染窗口在哪、总高怎么变」。
            //    音量可控：只有 `oldTotal != total` 时才打（纯滚动不打）。
            if oldTotal != total {
                let off = sv.contentOffset.y / max(sv.zoomScale, 0.01)
                DiagLog.event("strip", "viewport",
                              "改高 总高 \(Int(oldTotal))→\(Int(total))"
                              + "｜offset \(Int(oldTop))→\(Int(off))"
                              + "｜可见页 \(page(at: off))"
                              + "｜窗口 \(window.lowerBound)..<\(window.upperBound)"
                              + "｜视口高 \(Int(sv.bounds.height))")
            }
        }

        /// 按当前滚动偏移刷新「已渲染的页窗口」。
        ///
        /// ⚠️ 必须**在这里**（滚动回调里）更新，不能等 SwiftUI 那边把 `page`
        ///    节流 150ms 之后再回来 —— 否则快速滑动时窗口滞后，
        ///    用户会滑进「还没渲染的空窗」（整屏空白，只有占位）。
        ///
        /// ⚠️ 窗口按 **chunk 对齐**，而不是「跟着当前页滑动」：
        ///    ① 窗口太窄 → 滑一下就可能滑出已渲染范围 → 看到空白；
        ///    ② 窗口每换一页就变一次 → 内容每页重建一次 → 掉帧；
        ///    ③ **滑动期间唯一的图片加载来源就是这个窗口**，
        ///       窗口太窄 = 几乎没有预载（用户反馈的「是不是没有了预加载」）。
        /// 现在窗口 = `[base-1, base+8)`（base 为 5 的整数倍）：
        ///    可见页往后至少 3~8 页已在渲染（= 已在加载）；
        ///    只在跨过 chunk 边界时才重建，每 5 页一次；
        ///    且始终落在 store 的内存窗口 `[page-5, page+10]` 之内，不会来回抖。
        private static let windowChunk = 5

        private func updateWindow(_ sv: UIScrollView) {
            let sid = ObjectIdentifier(parent.store)
            if lastStoreID != sid {
                lastStoreID = sid
                pendingStoreRebuild = true
                DiagLog.event("strip", "store", "换 store（当前 heights=\(heights.count)）")
            }

            let n = heights.count
            // 🔴 一页都还没有时**绝不清空内容** —— 清空会让内容区变全黑。
            //    换章瞬间 store 是新的、URL 还没到，这时清空就正好是用户看到的黑屏。
            //    保留旧内容，等有页可渲染时再由 `pendingStoreRebuild` 补重建。
            guard n > 0 else {
                if lastLoggedCount != 0 {
                    lastLoggedCount = 0
                    DiagLog.event("strip", "window", "heights=0 → 保留旧内容（不清空）")
                }
                return
            }

            let visible = page(at: sv.contentOffset.y / max(sv.zoomScale, 0.01))
            let base = (visible / Self.windowChunk) * Self.windowChunk
            // ⚠️ 下界取 `base-1`：保证渲染窗口始终落在 store 的内存窗口
            //    `[visible-5, visible+10]` 之内，不会「刚渲染就被淘汰 → 又加载」来回抖。
            let lo = max(0, base - 1)
            let hi = min(n, base + 8)
            let next = lo..<hi
            // 护栏：窗口绝不为空（空窗口 = 只有 Color.clear 占位 = 内容区全黑）
            guard !next.isEmpty else {
                DiagLog.event("strip", "window", "算出空窗口 → 拦下（visible=\(visible) n=\(n)）")
                return
            }
            guard next != window || pendingStoreRebuild else { return }
            // ── 迟滞（hysteresis）：窗口已经**舒服地**覆盖可见页时就不重建 ──────
            // 窗口按 chunk 对齐，所以可见页在 chunk 边界（如 129/130）附近来回抖时，
            // `base` 会在 125 ↔ 130 之间翻转 → 内容每帧整树重建一次 → 掉帧 + 闪烁。
            // 实测日志里就有 `重建内容 129..<137` ↔ `134..<137` 反复横跳。
            // 判据：可见页在当前窗口内，且**前后都留有余量**（前面 ≥2 页、后面 ≥3 页）。
            if !pendingStoreRebuild, window.contains(visible),
               visible - window.lowerBound >= 2, window.upperBound - visible >= 3 {
                return
            }
            pendingStoreRebuild = false
            window = next
            host?.rootView = makeContent(range: next)
            DiagLog.event("strip", "window",
                          "重建内容 \(next.lowerBound)..<\(next.upperBound)（可见页 \(visible) n=\(n)）")
        }

        /// 回到 1x 后补做被推迟的 `refresh`（见 `refresh` 里的说明）。
        /// ⚠️ 三个入口都调它：`scrollViewDidScroll` / `scrollViewDidEndZooming` /
        ///    `updateUIView`（兜底）—— 缩放结束时 `contentOffset` 不一定变化，
        ///    只挂一个入口会漏。
        /// ⚠️ 判据与 `refresh` 保持一致：**必须 `!isZooming` 且 zoomScale 回到 1**，
        ///    否则会在回弹中途（zoomScale 还在变）补做 → 同样错位。
        func applyPendingRefreshIfNeeded(_ sv: UIScrollView) {
            guard needsRefreshAfterZoom, !isZooming,
                  abs(sv.zoomScale - 1) <= 0.01, !isAdjusting else { return }
            needsRefreshAfterZoom = false
            refresh(sv)
        }

        // MARK: - 诊断（自动化复现「缩放后黑屏 / 跳页」）

        /// 消费诊断桥里排队的操作。由 `updateUIView` 触发（外部靠递增 tick 驱动）。
        ///
        /// ⚠️ **必须分步 + 每步留延时**：`zoomScale` / `contentOffset` 的变化要经过
        ///    `UIScrollView` 的布局与动画才稳定，一口气同步跑完会把**中间态**当成
        ///    终态记录 —— 那样日志全是噪声，反而掩盖真正的时序问题。
        func drainDiag(_ sv: UIScrollView) {
            guard let bridge = parent.diag else { return }
            // 无待执行操作时**立刻返回** —— 本方法会被每次 `updateUIView` 调用，
            // 不能在这里做任何多余的事（否则滚动时会白白建闭包）。
            guard !bridge.busy, !bridge.pending.isEmpty else { return }
            // 注入快照器（弱引用，避免与 Coordinator 形成强环）
            bridge.snapshotProvider = { [weak self, weak sv] in
                guard let self, let sv else { return "state=unavailable" }
                return self.diagState(sv)
            }
            bridge.busy = true
            bridge.record("开始诊断序列（\(bridge.pending.count) 步）")
            runNextDiagOp(sv)
        }

        private func runNextDiagOp(_ sv: UIScrollView) {
            guard let bridge = parent.diag else { return }
            guard !bridge.pending.isEmpty else {
                bridge.busy = false
                bridge.record("诊断序列结束")
                return
            }
            let op = bridge.pending.removeFirst()
            // 🔴 诊断指令也是**程序化**改 offset，必须和 restore/scroll/refresh 一样
            //    打上 `isAdjusting` —— 否则 `scrollViewDidScroll` 会把诊断造成的
            //    位移当成用户滚动上报页码、触发预载与进度落库（污染真机日志，
            //    严重时把进度写成错的页）。这是三条程序化路径里唯一漏网的。
            isAdjusting = true
            defer { isAdjusting = false }
            switch op {
            case .setZoom(let s):
                // ⚠️ 直接给 `zoomScale` 赋值 —— **绕过 `setZoomScale` 的 clamp**，
                //    这样才能设出 `< minimumZoomScale(=1)` 的值，复现弹性回弹区间。
                sv.zoomScale = s
                bridge.record("setZoom \(fmt(s)) → 实际 \(fmt(sv.zoomScale))")
            case .scrollBy(let dy):
                let y = sv.contentOffset.y + dy * sv.zoomScale
                let maxY = max(0, sv.contentSize.height * sv.zoomScale - sv.bounds.height)
                sv.contentOffset = CGPoint(x: sv.contentOffset.x, y: min(max(0, y), maxY))
                bridge.record("scrollBy \(fmt(dy)) → offset \(fmt(sv.contentOffset.y))")
            case .snapshot(let label):
                bridge.record("快照[\(label)] \(diagState(sv))")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak sv] in
                guard let sv else { return }
                self.runNextDiagOp(sv)
            }
        }

        /// 当前状态的一行摘要 —— 黑屏判据全在这里：
        /// `visible` 若落在 `window` 之外，内容区此刻就是空的（= 用户看到的黑屏）。
        private func diagState(_ sv: UIScrollView) -> String {
            let z = max(sv.zoomScale, 0.001)
            let top = sv.contentOffset.y / z
            let vis = page(at: top)
            return "offset=\(fmt(sv.contentOffset.y)) zoom=\(fmt(sv.zoomScale)) "
                 + "top=\(fmt(top)) visible=\(vis) window=\(window.lowerBound)..<\(window.upperBound) "
                 + "pages=\(heights.count) contentH=\(fmt(sv.contentSize.height)) isZooming=\(isZooming)"
        }

        private func fmt(_ v: CGFloat) -> String { String(format: "%.1f", v) }

        /// 续读落位 —— **只摆偏移，不碰渲染窗口**。
        ///
        /// 与 `scroll(toPage:)` 的区别：那个会顺带 `updateWindow` 重建内容。
        /// 续读发生在「第一次渲染之前」，那时内容还是空的 —— 先建一次再被 `refresh`
        /// 按新 offset 建第二次，两次之间会提交一帧错误画面（= 打开时闪一下）。
        /// 这里把窗口留给紧随其后的 `refresh` 一次性决定，中间没有多余重建。
        ///
        /// - Returns: 是否成功落位（`false` 表示宽度/高度还没准备好，调用方下次再试）
        @discardableResult
        func prepareRestore(_ i: Int, in sv: UIScrollView) -> Bool {
            guard i >= 0, parent.contentWidth > 0 else { return false }
            // `cumY` 由 `recomputeMetrics()` 产出，`scroll(toPage:)` 依赖它
            _ = recomputeMetrics()
            guard cumY.count > i else { return false }
            isAdjusting = true
            sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: cumY[i] * sv.zoomScale),
                                animated: false)
            isAdjusting = false
            lastReported = i
            // 🔎 插桩：续读落位的实际落点 —— 与后续 `[window] 可见页 N` 对照，
            //    就能看出「是谁把偏移又挪走了」
            DiagLog.event("strip", "restore",
                          "续读落位 第 \(i) 页 → offset \(Int(cumY[i]))（总高 \(Int(totalHeight))）")
            return true
        }

        /// 跳转到某一页（顶端对齐视口顶端）
        ///
        /// - Parameter report: 是否回调 `onPageChange`。传 `false` 用于
        ///   `updateUIView` 里的续读跳转 —— 那里处于 SwiftUI 视图更新周期内，
        ///   不能**同步**改外部 `@State`（页码由调用方异步补报）。
        func scroll(toPage i: Int, in sv: UIScrollView, report: Bool = true) {
            guard cumY.count > i, i >= 0 else { return }
            isAdjusting = true
            let y = cumY[i] * sv.zoomScale
            sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: y), animated: false)
            // ⚠️ 立刻把**渲染窗口**搬到目标页 —— `isAdjusting` 期间
            //    `scrollViewDidScroll` 被跳过，窗口不会自己更新；
            //    不搬的话首帧渲染的仍是「第 0 页」的窗口（= 黑屏的来源之一）。
            updateWindow(sv)
            isAdjusting = false
            lastReported = i
            if report { parent.onPageChange(i) }
        }

        // MARK: - UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { host?.view }

        func scrollViewDidScroll(_ sv: UIScrollView) {
            // 程序化调整（改内容尺寸 / 续读跳转）自己触发的回调，跳过
            guard !isAdjusting else { return }
            // 兜底：若「缩放中」标志因异常路径（手势被系统打断 / 切后台）没复位，
            // 而 zoomScale 已稳定在 1、且不在弹性回弹 —— 说明缩放实际已结束，复位它，
            // 否则内容会永远不刷新（滑到新页不渲染 = 一片空白）。
            if isZooming, !sv.isZoomBouncing, abs(sv.zoomScale - 1) <= 0.01 {
                isZooming = false
            }
            // 🔴 缩放（含缩小回弹）进行中：`contentOffset` 与 `zoomScale` **都在变**，
            //    此刻 `offset / zoomScale` 算出的可见页不可信 → 不更新窗口、不上报页码。
            //    等 `scrollViewDidEndZooming` 再对齐（那里补做一次 `updateWindow`）。
            //    （这是「缩小后黑屏跳页」的修复点，详见 `isZooming` 的说明。）
            guard !isZooming else { return }
            // 缩放期间被推迟的内容刷新，在这里补上（见 `refresh` 的说明）
            applyPendingRefreshIfNeeded(sv)
            // ⚠️ 只有**回到 1x** 才处理窗口与页码：
            //    ① 放大态（zoomScale > 1）下窗口 9 页已足够覆盖可视范围
            //       （2.5x 时一屏 ≈ 0.4 页），不需要跟着 offset 走；
            //    ② 放大态下重建 `rootView` 会让新增页短暂空白，反而更难看；
            //    ③ 缩放期间（含缩小回弹）offset 与 zoomScale 都在变，算出的页码不可信 ——
            //       这正是「缩小后黑屏 + 跳页」的根因（详见 `isZooming` 的说明）。
            guard abs(sv.zoomScale - 1) <= 0.01 else { return }
            let p = page(at: sv.contentOffset.y / max(sv.zoomScale, 0.01))
            // 🔎 诊断：可见页若**不在**已渲染窗口内，内容区此刻就是空的（= 黑屏）。
            //    这条日志是验证「黑屏 = 窗口没覆盖住视口」这个假设的直接证据。
            if !heights.isEmpty, !window.isEmpty, !window.contains(p) {
                DiagLog.event("strip", "gap",
                              "可见页 \(p) 不在窗口 \(window.lowerBound)..<\(window.upperBound)"
                              + "（offset=\(Int(sv.contentOffset.y)) zoom=\(String(format: "%.3f", sv.zoomScale))）")
            }
            // 让渲染窗口跟上（与页码节流无关，快滑时不能出现空白）
            updateWindow(sv)
            // 🔴 页码上报**只在用户真的在滚**时进行。
            //    程序化补偿 offset（见 `refresh` 的高度补偿）与 SwiftUI 布局延迟
            //    引起的 offset 变化都**不是用户意图** —— 把它们当成「用户翻到了这一页」
            //    上报，进度就会被写成错的页（用户反馈的「进度没保存」）。
            //    ⚠️ `updateWindow` 必须在上面先跑：窗口对齐与页码上报是两件事，
            //       快速滑动时窗口不能因为这条 guard 而滞后（滞后 = 空白）。
            guard sv.isDragging || sv.isDecelerating else { return }
            guard p != lastReported else { return }
            lastReported = p
            parent.onPageChange(p)
        }

        /// 🔴 缩放开始 —— 立刻挂上「缩放中」标志。
        /// 从这里到 `scrollViewDidEndZooming` 之间的**所有** `scrollViewDidScroll`
        /// 都会被拦住，窗口/页码一律不动（这是黑屏跳页的修复点）。
        func scrollViewWillBeginZooming(_ sv: UIScrollView, with view: UIView?) {
            isZooming = true
            lastZoomLogScale = -1
            DiagLog.event("strip", "zoom",
                          "开始缩放（zoom=\(String(format: "%.3f", sv.zoomScale))）")
        }

        func scrollViewDidZoom(_ sv: UIScrollView) {
            // ⚠️ 程序化缩放（双击 `zoom(to:)` / `setZoomScale`）**不一定**先走
            //    `scrollViewWillBeginZooming` —— 这里补设标志，
            //    确保双击与捏合两条路径在整个缩放期间都被拦住。
            isZooming = true
            parent.onZoomChanged(sv.zoomScale > 1.01)
        }

        func scrollViewDidEndZooming(_ sv: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            isZooming = false
            parent.onZoomChanged(sv.zoomScale > 1.01)
            DiagLog.event("strip", "zoom",
                          "结束缩放（zoom=\(String(format: "%.3f", sv.zoomScale))）")
            // ⚠️ 顺序要紧：
            //   ① 先把缩放期间**推迟**的内容刷新补做（它可能要改内容尺寸 / `contentSize`）；
            //   ② 若已回到 1x：对齐渲染窗口并重新上报页码 ——
            //      缩放期间 `scrollViewDidScroll` 被拦，窗口没跟上；不补这一下，
            //      回到 1x 后可见页可能落在窗口之外（= 黑屏）。
            //      放大态则**不动窗口**（与 `scrollViewDidScroll` 的策略保持一致，
            //      避免缩放刚结束就重建内容导致闪烁）。
            applyPendingRefreshIfNeeded(sv)
            guard abs(sv.zoomScale - 1) <= 0.01 else { return }
            updateWindow(sv)
            let p = page(at: sv.contentOffset.y / max(sv.zoomScale, 0.01))
            lastReported = p
            parent.onPageChange(p)
        }

        // MARK: - 手势

        /// 滚动彻底停下时补一次页码上报。
        ///
        /// 为什么需要：`scrollViewDidScroll` 里的上报被 `isDragging || isDecelerating`
        /// 守着（防止程序化 offset 变化污染进度），而「松手即停」这一下
        /// 可能不再产生 `scrollViewDidScroll` —— 不补的话最后一次位置就没被记住。
        private func reportCurrentPage(_ sv: UIScrollView) {
            guard !isAdjusting, !isZooming, abs(sv.zoomScale - 1) <= 0.01 else { return }
            let p = page(at: sv.contentOffset.y / max(sv.zoomScale, 0.01))
            lastReported = p
            parent.onPageChange(p)
        }

        func scrollViewDidEndDragging(_ sv: UIScrollView, willDecelerate decelerate: Bool) {
            guard !decelerate else { return }   // 还有惯性 → 等 didEndDecelerating
            reportCurrentPage(sv)
        }

        func scrollViewDidEndDecelerating(_ sv: UIScrollView) {
            reportCurrentPage(sv)
        }

        /// 按屏翻页：滚动指定距离（点），带边界钳制。缩放态下不响应。
        func scrollBy(points: CGFloat, in sv: UIScrollView) {
            guard abs(sv.zoomScale - 1) < 0.01, sv.bounds.height > 1 else { return }
            let maxY = max(0, sv.contentSize.height - sv.bounds.height)
            let target = max(0, min(sv.contentOffset.y + points, maxY))
            sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: target), animated: true)
        }

        /// 翻页模式：滑动结束**吸附到整屏边界**（滑一次 = 一屏）。
        ///
        /// 为什么用「吸附」而不是 `isPagingEnabled`：
        /// `isPagingEnabled` 是按**视图尺寸**翻页，和内容无关；而这里是**连续长条**
        /// （一屏可能含 1~3 张图、一张图也可能跨两屏），必须按屏幕高度吸附。
        func scrollViewWillEndDragging(_ sv: UIScrollView,
                                       withVelocity velocity: CGPoint,
                                       targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            guard parent.pageSnap, abs(sv.zoomScale - 1) < 0.01 else { return }
            let h = sv.bounds.height
            guard h > 1 else { return }
            let maxY = max(0, sv.contentSize.height - h)
            var target = (targetContentOffset.pointee.y / h).rounded() * h
            target = max(0, min(target, maxY))
            targetContentOffset.pointee = CGPoint(x: sv.contentOffset.x, y: target)
        }

        /// 双击：以**双击点**为中心放大 / 还原 —— 与系统相册一致。
        /// ⚠️ 这个行为**由系统完成**：`zoom(to:)` 的参数就是「要显示的区域」，
        ///    `UIScrollView` 会自己算好 `contentOffset` 与 `zoomScale`，不需要手算锚点。
        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
            // 🔴 必须尊重「双击缩放」开关 —— 以前这里无条件放大，开关是假的。
            //    关闭时只还原（放大状态下双击仍可缩回，不然用户会卡在放大态出不来）。
            guard let sv = g.view as? UIScrollView, let hv = host?.view else { return }
            if sv.zoomScale > 1.01 {
                sv.setZoomScale(1, animated: true)
                return
            }
            guard parent.doubleTapZoomEnabled else { return }
            let target: CGFloat = 2.5
            let p = g.location(in: hv)          // 内容坐标（hv 就是被缩放的那层）
            let w = sv.bounds.width / target
            let h = sv.bounds.height / target
            sv.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h),
                    animated: true)
        }

        @objc func handleSingleTap(_ g: UITapGestureRecognizer) {
            // 翻页模式：按点击位置分三区（左/中/右）；滚动模式只呼出菜单
            if let zone = parent.onTapZone, let sv = g.view as? UIScrollView {
                let w = max(sv.bounds.width, 1)
                let x = g.location(in: sv).x
                zone(Int(max(0, min(2, x / (w / 3)))))
            } else {
                parent.onSingleTap()
            }
        }

        /// 内容最底部那一行是「下一章」按钮，**单击手势要让位给 SwiftUI 的按钮**，
        /// 否则点按钮会顺带把菜单也弹出来。
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            guard let hv = host?.view else { return true }
            return touch.location(in: hv).y < pagesHeight - 1
        }
    }
}
