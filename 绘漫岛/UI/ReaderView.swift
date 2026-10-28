import SwiftUI
import UIKit
import Combine

/// 阅读器 —— 对应 ChapterBrowseActivity
/// 模式: 1滚动(webtoon) 2普通翻页 3日漫模式(右开)
/// 图片按需加载（滚动到哪加载哪 + 前后预载2张），防止整章内存爆炸
struct ReaderView: View {
    let info: ComicInfo
    let startChapter: ComicInfo.Chapter

    @EnvironmentObject var s: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var chapterIndex: Int
    @State private var store: ChapterImageStore?
    @State private var loading = true
    @State private var error = ""
    // ⚠️ 阅读器**不跟随主题**（用户明确要求：主题只作用于漫画**外面**的界面 ——
    //    书架 / 漫画台 / 设置）。漫画是图片内容，深浅底色的选择只应由「看图的观感」
    //    决定，不该被 App 主题改掉：恒定深底 + 浅字是阅读器的标准做法。
    //    所以这里不再持有 `ThemeStore`，也不再读 `themeStore.current.textColor`。

    @State private var zoomed = false
    @State private var showSettings = false
    @State private var showMenu = false
    /// 章节列表（选章）面板 —— 阅读中想换章时随时可达。
    @State private var showChapterList = false
    /// 顶部浮层的「几秒后自动收起」任务（重复唤起时先取消上一次）。
    @State private var chromeHideTask: Task<Void, Never>?
    @State private var page = 0
    // ⚠️ 阅读器设置**必须直接读写 AppSettings**，不能另开一份 `@State`。
    //    旧实现用的是本地 `@State private var bright = 0.5` 等，
    //    而 `AppSettings` 里明明已有 `@AppStorage("brightness")` ——
    //    两套变量互不相通，结果就是用户反馈的「亮度设置之后不能保存」
    //    （改完退出阅读器就回到默认值）。
    /// 本章是否在读**本地已下载**的图片（离线秒开）。仅用于 UI 角标。
    @State private var offline = false
    /// 从书架续读时要恢复到的页码（-1 表示无需恢复）
    @State private var pendingRestorePage: Int
    /// 滚动模式的续读跳转请求（交给 `ZoomableStripView` 执行，执行后置回 -1）。
    /// 现在每页高度是**算出来的**，一次 `setContentOffset` 就能精确落位，
    /// 不再需要旧实现那套「重试 5~12 次直到图片撑开高度」的猜测式滚动。
    @State private var stripRestorePage: Int = -1
    /// 按屏翻页：点左/右分区时请求滚动一屏（`seq` 变化即执行）
    @State private var stripScrollSeq = 0
    @State private var stripScrollDelta: CGFloat = 0
    /// `store` 状态变化的订阅 —— 图片加载完会学到**真实宽高比**，
    /// 而每页高度（宽 × 比例）是布局与内容总高的依据，必须据此重算。
    @State private var storeObserver: AnyCancellable?
    /// 每收到一次 store 变化就自增，用来**触发本视图重绘**。
    ///
    /// ⚠️ 这个值**必须真的传进 `ZoomableStripView`**（见 `webtoonPager` 的
    ///    `storeTick: storeTick`）—— 2026-10-17 真机实锤：它曾经只自增、body 里
    ///    没人读，于是「store 变了」根本没变成一次 `updateUIView`，
    ///    `refresh()` 不跑、`contentSize` 停在估算总高 → 首屏定位错、少显示几页。
    @State private var storeTick = 0
    /// 诊断截图导出的结果提示
    @State private var diagMessage = ""
    /// 诊断桥 —— 让 App 自己复现「下滑后缩小」并回收证据（见 `StripDiagBridge`）
    @State private var stripDiag = StripDiagBridge()
    /// 诊断触发计数：递增即驱动一次 `updateUIView`，让 Coordinator 消费 `stripDiag.pending`
    /// （`StripDiagBridge` 是普通 class，不是 `ObservableObject`，改属性不会触发刷新）
    @State private var diagTick = 0
    /// 去抖保存进度的任务
    @State private var progressSaveTask: Task<Void, Never>?
    /// 滚动页码节流：暂存的「目标页」，150ms 稳定后再落到 `page`
    @State private var pendingVisiblePage: Int = -1
    /// 最近一次已发起预载的中心页（用于去重，保证每页只预载一次）
    @State private var preloadCenter: Int = -1
    /// 滚动页码节流的任务句柄
    @State private var scrollThrottleTask: Task<Void, Never>?
    /// 图集收藏会话 —— 订阅它才能在收藏/取消后立刻刷新心形按钮状态
    @ObservedObject private var favorites = FavoriteSession.shared
    /// 视口尺寸 —— 滚动模式用来算「每页高度」与内容总高（只测量，不参与布局）
    @State private var readerViewport: CGSize = .zero
    /// 章节加载的**请求序号**。每次 `loadChapter` 递增，await 回来后比对；
    /// 对不上说明用户在等待期间又切了章，本次结果整段丢弃 —— 防止「晚到的旧章覆盖新章」。
    @State private var loadToken: Int = 0

    init(info: ComicInfo, startChapter: ComicInfo.Chapter, startPage: Int = 0) {
        self.info = info
        self.startChapter = startChapter
        _chapterIndex = State(initialValue: info.chapters.firstIndex(where: { $0.url == startChapter.url }) ?? 0)
        _pendingRestorePage = State(initialValue: startPage)
    }

    var chapter: ComicInfo.Chapter? {
        info.chapters.indices.contains(chapterIndex) ? info.chapters[chapterIndex] : nil
    }

    /// 亮度偏移（约 -0.3 … +0.3）。`0.5` = 原样。
    ///
    /// 🔴 **必须用 `@AppStorage` 在视图里直接订阅**，不能读 `s.brightness`：
    ///    `AppSettings` 是普通 class，里面的 `@AppStorage` **不会发
    ///    `objectWillChange`**（和「主题切换没反应」是同一个坑）——
    ///    所以拖亮度滑块时阅读器 body 根本不重算，用户看到的就是「亮度没反应」。
    ///
    /// ⚠️ 滤镜只作用在**漫画图**上，不要挂到根视图 —— 见 body 里那段说明
    ///    （挂根视图会让 `TabView` 翻页时整屏黑一帧）。
    @AppStorage("brightness") private var brightnessValue = 0.5
    private var brightnessDelta: Double { Double(brightnessValue - 0.5) * 0.6 }
    /// 变暗蒙层的浓度（0…0.65）。
    ///
    /// 🔴 **只做「变暗」，不做「提亮」**（2026-10-24）：
    ///    提亮是用白色蒙层叠上去的，会把整屏糊成一层白雾 ——
    ///    用户看到的就是「图片有一层朦胧的感觉」。亮度 1.0 = 完全原样。
    private var dimOpacity: Double {
        max(0, min(0.65, (1 - brightnessValue) * 0.6))
    }
    /// 给 UIKit 页面用的蒙层颜色（纸质翻页模式已停用，保留以兼容）

    var body: some View {
        Group {
            if loading {
                VStack(spacing: 14) {
                    ProgressView().tint(.white)
                    Text("加载中…").foregroundStyle(.white.opacity(0.85))
                    Text(chapter?.name ?? "").font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                    Button("取消") { dismiss() }
                        .font(.caption).tint(.white.opacity(0.75))
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !error.isEmpty {
                VStack(spacing: 14) {
                    EmptyState(title: "加载失败", systemImage: "wifi.exclamationmark", description: error)
                    HStack(spacing: 12) {
                        Button("重试") { Task { await loadChapter(chapterIndex) } }
                            .buttonStyle(.borderedProminent)
                        Button("返回") { dismiss() }
                            .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if s.readMode == 1 {
                // 🔴 三种阅读模式都 `.ignoresSafeArea()`（2026-10-17 用户截图实锤）：
                //    阅读器内容原本被安全区内缩 → 顶部状态栏 44pt + 底部 Home 指示条 34pt
                //    露出黑底，用户看到的就是「上下两条黑边，那里没有漫画」。
                //    铺满整屏后黑边消失；顶部浮层仍然按安全区排（见 `readerChrome`），
                //    所以返回按钮不会跑到刘海下面。
                // 滚动模式：**不要用 `.brightness()`**。
                // 🔴 2026-10-23 用户反馈「滚动模式有一层模糊的黑幕」——
                //    `.brightness()` 是色彩滤镜，作用在 `UIViewRepresentable`
                //    （整条 UIScrollView）上会强制**离屏渲染**：画面发虚、发暗，
                //    看起来就是「一层模糊的黑幕」。
                //    改用普通半透明蒙层：清晰、无滤镜、无额外合成。
                webtoonPager()
                    .overlay(Color.black.opacity(dimOpacity).allowsHitTesting(false))
                    .ignoresSafeArea()
            }
        }
        // ⚠️ 关键：首次进入必须主动加载当前章。
        // 此前只有「下一章 / 翻页到底 / nextPage / prevPage」四个调用点，
        // 初始进入时 @State loading=true 且 store=nil → 永远停在「加载中…」。
        .task { await loadChapter(chapterIndex) }
        // 阅读器背景**恒定深色**（不跟随 App 主题 —— 见 `zoomed` 上方的说明）。
        .background(Color.black)
        // 视口尺寸：**三种阅读模式共用**一个测量点。
        //
        // ⚠️ 之前只在 webtoonPager 里测，翻页/双页模式拿到的是 `.zero` ——
        //    于是那两种模式的平移边界（clamp）根本不起作用（可以拖成黑屏）。
        //    放在最外层 Group 上，任何模式下都有正确的视口尺寸。
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { readerViewport = g.size }
                    .onChange(of: g.size) { readerViewport = $0 }
            }
        )
        // ── 阅读器浮层（顶栏 + 章节数小框）──────────────────────────────────
        // 🔴 自绘浮层，**不用**系统导航栏 + `.toolbar(showMenu ? .visible : .hidden)`：
        //    导航栏显隐会改变安全区 → 阅读器视口高度变化 → 布局重算 → 画面跳动
        //    （正是刚修完的「首屏定位」那类问题的温床）。自绘 overlay 只改透明度，
        //    对布局零影响。
        //
        // 🔴 用「满屏 VStack + Spacer」而不是 `.overlay(alignment: .top)`：
        //    `alignment: .top` 对齐的是**视图边界**（含状态栏/刘海区域），
        //    隐藏导航栏后浮层会顶到刘海底下（用户反馈「也要适应刘海」）。
        //    VStack 的内容由 SwiftUI 自动按**安全区**内缩，浮层就永远在刘海下方。
        .overlay {
            VStack(spacing: 0) {
                readerChrome
                Spacer(minLength: 0)
            }
            // 🔴 章节列表的 sheet 挂在**浮层**上，而不是和 `showSettings` 挂在同一个视图上。
            //    同一个视图挂两个 `.sheet` 在部分 iOS 版本下会互相抢占，
            //    表现就是「点了没反应」（用户反馈「看不到所有章目录」）。
            // 🔴 阅读器子树被强制 `.colorScheme(.dark)`（阅读区要黑底白字），
            //    弹出来的 sheet 会**继承**这个环境 → 整个设置/章节面板是黑的，
            //    用户反馈「阅读设置是黑色的，很影响观看」。
            //    这里显式按**主题**给 sheet 自己的 colorScheme。
            .sheet(isPresented: $showChapterList) {
                chapterListSheet
                    .environment(\.colorScheme, Theme.isDark ? .dark : .light)
            }
        }
        .overlay { Color.black.opacity(s.eyeCare ? 0.25 : 0).allowsHitTesting(false) }
        // 🔴 亮度**不再挂在根视图**上（2026-10-23 用户反馈「翻页每翻一页黑一下」）。
        //
        //    原因：`.brightness()` 是**色彩滤镜**，SwiftUI 会把它做成离屏合成层。
        //    根视图里包着 `TabView(.page)`（底层 UIPageViewController），翻页时
        //    整层滤镜要跟着重新合成 → 过渡的那一帧渲染不出来 → **整屏黑一下**。
        //    每翻一页都黑一次，正是这个滤镜造成的。
        //
        //    现在改为**只作用在每张漫画图上**（见 `StoreImage(brightness:)`）：
        //    滤镜跟着静态的 Image 层走，不参与翻页滚动，既不会黑帧，
        //    亮度语义也仍然保留（0.5 = 原样，1 = 更亮，0 = 更暗）。
        //    滚动模式单独在 `webtoonPager` 上应用（见 body 里的调用）。
        // 🔴 强制阅读器**子树**为深色（只作用子树，不动整个 window，所以进出阅读器不会闪）。
        //    不这么做的话，浅色主题下两处会「漏光」：
        //      ① 错误态 `EmptyState` 用 `.secondary/.tertiary`，在浅色方案下解析成深灰，
        //         压在阅读器的纯黑底上**根本看不见**（用户看到「黑屏没提示」）；
        //      ② 阅读设置 sheet 的 Form 会整片变白，违反「阅读器恒定黑底白字」。
        //    （由智能体「主题」发现两处，这里一次修掉）
        .environment(\.colorScheme, .dark)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = s.keepScreenOn
            // 进章节先把顶部浮层亮出来，几秒后自动收起（用户要求：打开时能看到标题，
            // 又不长期挡画面）
            revealChrome()
        }
        // 切章后同样亮一下再自动收起（不然换完章不知道换到哪了）
        .onChange(of: chapterIndex) { _ in revealChrome() }
        // ⚡️ 自动保存进度：进后台（上滑回桌面 / 锁屏）也强制落一次。
        // 这是用户最常触发的「离开阅读器」路径，比 onDisappear 更早也更可靠。
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            scrollThrottleTask?.cancel()
            progressSaveTask?.cancel()
            if pendingVisiblePage >= 0, pendingVisiblePage != page, pendingVisiblePage < (store?.count ?? 0) {
                page = pendingVisiblePage
            }
            saveProgress()
            // 🔴 比例立刻落盘 —— 这是「重新打开漫画就往上滑」根治的关键：
            //    下次打开时首帧就是真实高度，不再出现「占位高 → 真实高」的腰斩。
            store?.flushRatios()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            // ⚡️ 自动保存进度：常驻开启，不提供关闭开关（用户明确要求）。
            // 退出时先把被节流任务暂存的目标页落实，再立刻落库 ——
            // 用户可能马上就杀掉进程，不能等 150ms/400ms 的去抖。
            scrollThrottleTask?.cancel()
            progressSaveTask?.cancel()
            if pendingVisiblePage >= 0, pendingVisiblePage != page, pendingVisiblePage < (store?.count ?? 0) {
                page = pendingVisiblePage
            }
            saveProgress()
            store?.flushRatios()
        }
        .sheet(isPresented: $showSettings) {
            readerSettingsSheet
                // 同上：不要让阅读器的深色环境把设置面板染黑
                .environment(\.colorScheme, Theme.isDark ? .dark : .light)
        }
        .toolbar(.hidden, for: .tabBar)
        // 自绘底栏（AppShellView）也要跟着隐藏 —— 阅读必须全屏沉浸
        .onAppear { ShellBarState.shared.hidden = true }
        .onDisappear { ShellBarState.shared.hidden = false }
        // 阅读器恒定深色 → 导航栏也用深色配色，标题/按钮才看得见。
        // ⚠️ 故意**不用** `.preferredColorScheme(.dark)`：那会改整个 window 的深浅色，
        //    进/出阅读器时全 App 闪一下颜色 —— 正是我们要修的「打开/离开闪一下」。
        //    `toolbarColorScheme` 只作用于导航栏，没有这个副作用。
        .darkToolbarScheme()
        .navigationBarTitleDisplayMode(.inline)
        // 系统导航栏**永久隐藏**，顶部信息改由自绘浮层 `readerChrome` 承担 ——
        // 显隐不改变安全区，也就不会把画面顶来顶去。
        .toolbar(.hidden, for: .navigationBar)
        // 🔴 再加一道保险（2026-10-17 用户反馈「左上角返回箭头没隐藏」）：
        //    `.toolbar(.hidden)` 在部分路径下（尤其是被 `navigationDestination` 推入、
        //    或导航栏被父级重新显式）可能不生效，系统自带的返回箭头就会留在左上角 ——
        //    它**不属于**自绘浮层，自然不会跟着 `showMenu` 隐藏。
        //    显式关掉它，返回统一走浮层里的自绘按钮。
        .navigationBarBackButtonHidden(true)
    }

    // MARK: - 顶部浮层（顶栏 + 章节数小框）

    /// 顶部浮层：返回 / 章节列表 / 标题 / 收藏 / 设置 + 章节数小框。
    ///
    /// 显隐由 `showMenu` 驱动：打开章节时自动出现、约 3 秒后收起；
    /// 点画面中间可以再唤起（或立刻收起）。
    private var readerChrome: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 32, height: 30)
                }
                .accessibilityLabel("返回")

                Button { showChapterList = true } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 32, height: 30)
                }
                .accessibilityLabel("章节列表")

                Spacer(minLength: 0)

                // ⚠️ `.id(chapterIndex)` 让标题随章节重建 —— 否则新旧章节名长度相近时
                //    SwiftUI 会复用同一个 Text，出现「切了章标题还显示上一章」。
                // 标题也可点 → 直接开章节列表（用户习惯：点标题换章）
                Button { showChapterList = true } label: {
                    Text(chapter?.name ?? "")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .id(chapterIndex)
                }
                .buttonStyle(.plain)
                .animation(nil, value: chapterIndex)

                Spacer(minLength: 0)

                Button { Task { await toggleFavorite() } } label: {
                    Image(systemName: favoriteOn ? "heart.fill" : "heart")
                        .foregroundStyle(favoriteOn ? Color.pink : Color.white)
                        .frame(width: 32, height: 30)
                }
                .disabled(store == nil)
                .accessibilityLabel(favoriteOn ? "取消收藏" : "收藏本页")

                Button { showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 32, height: 30)
                }
                .accessibilityLabel("阅读设置")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            // 整条贴边（不悬浮）：用户要求顶栏更靠上、更贴合屏幕边缘
            .background(.ultraThinMaterial)

            // 章节数小框（离线角标 + 页码 + 第 X/Y 章）
            // **点一下直接开章节列表** —— 用户直觉就是点这里换章，
            // 只有 ☰ 图标太隐蔽（用户反馈「看不到所有章目录」）。
            Button { showChapterList = true } label: {
                HStack(spacing: 6) {
                    if offline {
                        Label("离线", systemImage: "arrow.down.circle.fill")
                            .font(.caption2).foregroundStyle(.green.opacity(0.9))
                    }
                    Text(chromeChipText)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.92))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 12)
        }
        .opacity(showMenu ? 1 : 0)
        .allowsHitTesting(showMenu)
        .animation(.easeInOut(duration: 0.2), value: showMenu)
    }

    /// 章节数小框的文字。
    /// ⚠️ 不要把三元表达式塞进字符串插值里（引号会互相打架，brace2.py 抓过同类问题）。
    private var chromeChipText: String {
        let pagePart = ""
        return "\(pagePart)第 \(chapterIndex + 1)/\(info.chapters.count) 章"
    }

    /// 唤起顶部浮层，并在 3 秒后自动收起。
    private func revealChrome(autoHide: Bool = true) {
        withAnimation(.easeInOut(duration: 0.2)) { showMenu = true }
        chromeHideTask?.cancel()
        guard autoHide else { return }
        chromeHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { showMenu = false }
        }
    }

    /// 点画面中间：没显示就唤起（带自动收起），已显示就立刻收起。
    private func toggleChrome() {
        if showMenu {
            chromeHideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.2)) { showMenu = false }
        } else {
            revealChrome()
        }
    }

    // MARK: - 章节列表（选章）

    /// 章节列表面板 —— 阅读到一半想换章时不用翻到章末，也不用去设置里点「下一章」。
    private var chapterListSheet: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(info.chapters.enumerated()), id: \.offset) { idx, ch in
                        Button {
                            showChapterList = false
                            guard idx != chapterIndex else { return }
                            Task { await loadChapter(idx) }
                        } label: {
                            HStack(spacing: 10) {
                                Text(ch.name)
                                    .lineLimit(1)
                                    .foregroundStyle(idx == chapterIndex ? Color.accentColor : Color.primary)
                                Spacer(minLength: 0)
                                if idx == chapterIndex {
                                    Image(systemName: "checkmark")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .id(idx)
                    }
                }
                .listStyle(.plain)
                .onAppear {
                    // 打开时滚到当前章。⚠️ 必须**延后一拍**：List 首帧还没完成布局，
                    // 立刻 scrollTo 会滚不动（iOS 16 上实测）。
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        withAnimation(nil) {
                            proxy.scrollTo(chapterIndex, anchor: .center)
                        }
                    }
                }
            }
            .navigationTitle("章节 \(chapterIndex + 1)/\(info.chapters.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { showChapterList = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// 当前页是否已收藏（按钮状态）
    private var favoriteOn: Bool {
        guard let ch = chapter else { return false }
        return FavoriteSession.shared.isFavorite(
            origin: info.origin, chapterUrl: ch.url, index: page)
    }

    /// 收藏 / 取消收藏当前页
    private func toggleFavorite() async {
        guard let store, let ch = chapter else { return }
        // 收藏结果直接反映在 `favorites.items` 上（@ObservedObject 会触发重绘），
        // 不需要额外的手动刷新标记。
        await FavoriteSession.shared.addCurrentPage(
            store: store, index: page,
            origin: info.origin, noteUrl: info.noteUrl, comicName: info.name,
            chapterUrl: ch.url, chapterName: ch.name)
    }

    // MARK: - 滚动模式
    /// 整条缩放：**单一 `UIScrollView` 承载整章内容**（详见 `ZoomableStripView`）。
    ///
    /// 每页高度由 `ZoomableStripView` 自己按「宽 × 宽高比」算（`StripMetrics`），
    /// 并且**内容视图直接观察 `store`** —— 图片加载完学到真实比例时，
    /// 只会重算各行 frame，**不会重建内容树**（重建会让画面闪一下）。
    private func webtoonPager(snap: Bool = false,
                              onTapZone: ((Int) -> Void)? = nil) -> some View {
        Group {
            if let store {
                ZoomableStripView(
                    store: store,
                    contentWidth: readerViewport.width,
                    footerHeight: Self.stripFooterHeight,
                    nextChapter: AnyView(nextChapterRow),
                    onPageChange: { reportVisiblePage($0) },
                    onZoomChanged: { z in zoomed = z },
                    onSingleTap: { toggleChrome() },
                    pageSnap: snap,
                    onTapZone: onTapZone,
                    scrollSeq: stripScrollSeq,
                    scrollBy: stripScrollDelta,
                    restorePage: stripRestorePage,
                    doubleTapZoomEnabled: s.doubleTapZoom,
                    onRestoreHandled: { stripRestorePage = -1 },
                    diag: stripDiag,
                    diagTick: diagTick,
                    // 🔴 必须把 `storeTick` 传进去（2026-10-17 真机实锤）：
                    //    原来 `storeTick` 只自增、**body 里从没读过**，而传下去的是
                    //    另一个 `diagTick` —— 于是 store 变化根本没让 representable
                    //    重建 → `updateUIView`/`refresh()` 不跑 → `contentSize`
                    //    停在估算总高（条漫会被高估近一倍）→ 首屏定位错、少几页。
                    storeTick: storeTick
                )
            } else {
                Color.clear
            }
        }
    }

    /// 章节末尾「下一章」那一行的固定高度（计入内容总高，便于滚动定位）
    private static let stripFooterHeight: CGFloat = 92


    /// 滚动模式上报当前页（由 `ZoomableStripView` 在页码真的变化时回调）。
    ///
    /// ⚠️ 性能红线：旧实现走 `onPreferenceChange`，滚动时**每帧**都会触发，
    /// 且携带全部可见页的偏移字典。现在改成「页码真的变了才回调」，
    /// 再叠加这里的 150ms 节流 —— 滚动过程中不反复触发预载与进度保存。
    private func reportVisiblePage(_ p: Int) {
        // 放大期间不得改写页码（缩放本身会动 `contentOffset`），
        // 否则会连带触发预载与续读跳转，破坏「缩放不改 chapter/page」这条不变量。
        guard !zoomed else { return }
        let clamped = max(0, min(p, (store?.count ?? 1) - 1))
        guard clamped != page else { return }

        // ── ① 预载：**立刻执行，不进节流** ────────────────────────────────
        // 🔴 这是「现在是不是没有了预加载」的根因修复。
        //    旧写法把 `preload` 放在 150ms 去抖任务里，而那个任务**每换一页就被
        //    取消重启** —— 用户**连续滑动时它永远不会执行**，预载等于没有。
        //    预载的意义就是「趁你还在看当前页，先把后面几页拉下来」，
        //    晚 150ms 才开始就已经晚了。所以这里立刻做，且**每页只做一次**
        //    （`preloadCenter` 去重，避免同一页反复起任务）。
        //    `preload` 内部自带去重与并发闸门，重复调用也只是空转。
        if clamped != preloadCenter {
            preloadCenter = clamped
            store?.preload(around: clamped)
        }

        // ── ② 页码 / 进度保存：仍然节流 ──────────────────────────────────
        //    这两件事**不能**跟着滑动高频执行（每页写一次库毫无必要），
        //    所以留在 150ms 去抖里。
        pendingVisiblePage = clamped
        scrollThrottleTask?.cancel()
        scrollThrottleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let target = pendingVisiblePage
            guard target >= 0, target != page else { return }
            page = target
            scheduleProgressSave()
        }
    }

    private var nextChapterRow: some View {
        Group {
            if chapterIndex + 1 < info.chapters.count {
                Button("下一章: \(info.chapters[chapterIndex + 1].name)") {
                    Task { await loadChapter(chapterIndex + 1) }
                }
                .buttonStyle(.bordered).tint(.white).padding(.vertical, 20)
            } else {
                Text("已是最后一章")
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.vertical, 20)
            }
        }
        .frame(maxWidth: .infinity)
    }


    /// 订阅 `store` 的变化 —— 图片加载完会学到**真实宽高比**，
    /// 而每页高度（宽 × 比例）是内容总高与滚动定位的依据，必须据此重算。
    ///
    /// ⚠️ 不订阅的后果：`updateUIView` → `refresh` 不会被触发 →
    /// 交给 `UIScrollView` 的 `contentSize`（内容总高）停留在旧值 ——
    /// 滚动条位置、续读定位、缩放比例全都会漂。
    /// （内容视图自己也观察 store，所以**行高**会更新；但 `contentSize` 只有
    ///   `refresh` 会改，这一步必须由这里触发。）
    private func observeStore(_ st: ChapterImageStore) {
        storeObserver = st.objectWillChange
            // ⚠️ 必须节流：预载会**连续**加载十几张，每张都发一次 objectWillChange。
            //    原来直接 `storeTick += 1`，等于每加载一张就把整个阅读器 body 重算一次；
            //    翻页模式下 `TabView` 被反复重建 → 用户看到的「翻页一闪一闪」。
            //    120ms 合并一次，滚动模式照样能及时 refresh，翻页模式不再抖。
            .throttle(for: .milliseconds(120), scheduler: RunLoop.main, latest: true)
            .sink { _ in
                // 只有**滚动长条**需要 storeTick 去驱动 `ZoomableStripView.refresh()`
                // （重算每页高度 / contentSize）：
                //   · 滚动模式（readMode == 1）
                //   · **按屏翻页**（pageTurnStyle == 0，翻页模式也用长条渲染）
                guard s.readMode == 1 else { return }
                storeTick &+= 1
            }
    }

    /// 诊断用：把**当前屏幕**截一张图存进 App 的 Documents。
    ///
    /// 为什么需要它：本机拿不到 iOS 的 RSD 隧道（iOS 17.2 没有 `CoreDeviceProxy`，
    /// Windows 侧又没有 Bonjour/NCM 网卡），`pymobiledevice3 developer screenshot`
    /// 走不通；而「缩放割裂 / 加载割裂」这类**视觉问题**只靠读代码极易误判。
    /// 让 App 自己截屏，是目前唯一能拿到真实画面的通道：
    /// 之后用 `pymobiledevice3 apps pull <bundle> Documents/diag_xxx.png .` 取出即可。
    private func exportDiagnosticScreenshot() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let win = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow })
                ?? scenes.first?.windows.first else {
            diagMessage = "找不到窗口"
            return
        }
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = min(UIScreen.main.scale, 2)      // 2x 足够看清，文件又不大
        let img = UIGraphicsImageRenderer(bounds: win.bounds, format: fmt).image { _ in
            win.drawHierarchy(in: win.bounds, afterScreenUpdates: true)
        }
        guard let data = img.pngData() else { diagMessage = "截图编码失败"; return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let name = "diag_\(Int(Date().timeIntervalSince1970)).png"
        do {
            try data.write(to: dir.appendingPathComponent(name))
            diagMessage = "已保存 \(name)（\(data.count / 1024) KB）"
            DiagLog.event("diag", "screenshot", name)
        } catch {
            diagMessage = "写入失败: \(error.localizedDescription)"
        }
    }

    /// 自动化复现「**下滑之后缩小 → 黑屏 / 跳页**」。
    ///
    /// ## 为什么需要它
    /// 本机拿不到 iOS 的 UI 控制通道（免 root 的 RSD 隧道要 **iOS 17.4+**，
    /// 而设备是 **17.2.1**），所以此前只能靠用户手动操作 + 录屏：
    /// 慢、每轮要人配合、而且无法保证每次都做同一串动作。
    ///
    /// 这个序列把复现条件**固化**下来（顶部缩小不复现，必须离开顶部）：
    ///   ① 跳到第 30 页（离开顶部）
    ///   ② 再滚动 +600
    ///   ③ 缩到 **0.75**（`< minimumZoomScale`，即弹性回弹区间 —— 旧守卫在这里放行）
    ///   ④ 还原 1.0
    ///   ⑤ 再滚动 +1500、缩到 0.6、还原 1.0（覆盖 offset 更大的情况）
    ///
    /// 每一步都记录 `offset / zoom / visible / window / isZooming`，
    /// **判据**：`visible` 若落在 `window` 之外 → 那一刻内容区就是空的（黑屏）。
    /// 结果写入 `Documents/diag_result.txt`，配一张截图，用 `apps pull` 取回。
    private func runDiagRepro() {
        guard s.readMode == 1 else {
            diagMessage = "仅滚动模式（设置 → 阅读模式 → 滚动）支持该诊断"
            return
        }
        stripDiag.reset()
        diagMessage = "诊断执行中…（约 15 秒，请勿操作）"
        // ① 跳到非顶部页 —— 顶部 offset≈0，缩小不会复现问题
        stripRestorePage = min(30, max(0, (store?.count ?? 1) - 1))
        Task { @MainActor in
            // 等跳页落位（UIScrollView 异步执行 + 图片开始加载）
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            stripDiag.pending.append(.snapshot("① 跳页后"))
            stripDiag.pending.append(.scrollBy(600))
            stripDiag.pending.append(.snapshot("② 滚动+600"))
            stripDiag.pending.append(.setZoom(0.75))
            stripDiag.pending.append(.snapshot("③ 缩到0.75(回弹区间)"))
            stripDiag.pending.append(.setZoom(1.0))
            stripDiag.pending.append(.snapshot("④ 还原1.0"))
            stripDiag.pending.append(.scrollBy(1500))
            stripDiag.pending.append(.snapshot("⑤ 再滚动+1500"))
            stripDiag.pending.append(.setZoom(0.6))
            stripDiag.pending.append(.snapshot("⑥ 缩到0.6"))
            stripDiag.pending.append(.setZoom(1.0))
            stripDiag.pending.append(.snapshot("⑦ 再还原1.0"))
            diagTick &+= 1          // 驱动一次 updateUIView，Coordinator 开始逐个消费
            // 12 步 × 0.55s ≈ 7s，留足余量等序列跑完
            try? await Task.sleep(nanoseconds: 13_000_000_000)
            exportDiagnosticScreenshot()
            diagMessage = stripDiag.flushToDisk()
        }
    }


    // MARK: - 菜单（对应 MenuSettingDialog）
    /// 阅读设置面板。
    ///
    /// ⚠️ 为什么不用 `Menu`（用户反馈「打开右上角设置时框架会抖动」）：
    ///    `Menu` 弹出时会**先测量内容尺寸**再决定宽度，而里面同时有
    ///    `Picker(.inline)`（选中态会改变行高）、`Slider`（宽度不确定）、`Toggle`
    ///    —— 三者混排时菜单的宽高被反复重算，表现出来就是整个菜单框在抖。
    ///    换成固定宽度的 `Form` 面板后布局完全可控，控件也更好点。
    private var readerSettingsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    settingsCard("显示", icon: "sun.max.fill") {
                        settingsToggle("护眼", icon: "eyeglasses", isOn: $s.eyeCare)
                        settingsDivider
                        settingsToggle("常亮", icon: "sun.max", isOn: $s.keepScreenOn)
                        settingsDivider
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Label("亮度", systemImage: "sun.max")
                                Spacer()
                                Text("\(Int(s.brightness * 100))%")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .padding(.horizontal, 9).padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.07), in: Capsule())
                            }
                            HStack(spacing: 10) {
                                Image(systemName: "sun.min")
                                    .font(.caption2).foregroundStyle(.tertiary)
                                Slider(value: $s.brightness, in: 0...1)
                                    .tint(Theme.accent)
                                Image(systemName: "sun.max.fill")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 8) {
                                brightnessChip("夜间", 0.35)
                                brightnessChip("适中", 0.60)
                                brightnessChip("明亮", 0.85)
                                brightnessChip("原样", 1.00)
                            }
                            Text("100% = 原样；只变暗、不提亮")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }

                    // 「阅读」卡已删（H2）：白边裁剪是全局行为 → 设置页；
                    // 这里只留「本次阅读」的 comfort 项（护眼/亮度/常亮）+ 章节导航 + 诊断。

                    settingsCard("章节", icon: "list.bullet") {
                        Text("第 \(chapterIndex + 1) / \(info.chapters.count) 章 · \(chapter?.name ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                        settingsDivider
                        settingsRow("章节列表", icon: "list.bullet", detail: "\(info.chapters.count) 章") {
                            showSettings = false
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 350_000_000)
                                showChapterList = true
                            }
                        }
                        settingsDivider
                        HStack(spacing: 10) {
                            settingsAction("上一章", icon: "chevron.left", enabled: chapterIndex > 0) {
                                showSettings = false
                                Task { await loadChapter(chapterIndex - 1) }
                            }
                            settingsAction("下一章", icon: "chevron.right",
                                           enabled: chapterIndex + 1 < info.chapters.count) {
                                showSettings = false
                                Task { await loadChapter(chapterIndex + 1) }
                            }
                        }
                    }

                    settingsCard("诊断", icon: "ladybug.fill") {
                        settingsRow("导出当前界面截图", icon: "camera", detail: nil) {
                            exportDiagnosticScreenshot()
                        }
                        settingsDivider
                        settingsRow("复现：下滑后缩小", icon: "ladybug", detail: nil) {
                            runDiagRepro()
                        }
                        if !diagMessage.isEmpty {
                            Text(diagMessage)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
            }
            // 🔴 原来是写死的 `Color(white: 0.06)` —— 跟 colorScheme 无关，
            //    所以不管怎么改环境色，面板永远是黑的（用户反馈「阅读设置是黑色」）。
            //    现在跟随主题：浅色主题就是浅色面板。
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showSettings = false }
                        .fontWeight(.semibold)
                }
            }
        }
        .onChange(of: s.keepScreenOn) { v in UIApplication.shared.isIdleTimerDisabled = v }
    }

    // MARK: - 设置页的卡片组件

    /// 一张设置卡片：小标题 + 圆角内容块
    private func settingsCard<C: View>(_ title: String, icon: String,
                                       @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption2)
                Text(title).font(.caption.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(HMD.stroke, lineWidth: 1)
                )
        }
    }

    /// 亮度快捷档位（选中态高亮）
    private func brightnessChip(_ title: String, _ value: Double) -> some View {
        let on = abs(s.brightness - value) < 0.02
        return Button {
            s.brightness = value
        } label: {
            Text(title)
                .font(.caption.weight(on ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(on ? Theme.accent.opacity(0.22) : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(on ? Theme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? Theme.accent : Color.primary)
    }

    private var settingsDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
    }

    private func settingsToggle(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { Label(title, systemImage: icon) }
            .tint(Theme.accent)
    }

    /// 一行可点条目（右侧箭头）
    private func settingsRow(_ title: String, icon: String, detail: String?,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Label(title, systemImage: icon)
                Spacer()
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    /// 半宽按钮（上一章 / 下一章）
    private func settingsAction(_ title: String, icon: String, enabled: Bool,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption.weight(.semibold))
                Text(title).font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.white.opacity(enabled ? 0.10 : 0.04),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
    }


    // MARK: - 加载

    /// 切换章节。
    ///
    /// 🐛 **修过的竞态（用户反馈「点下一章有时还是本章 / 章节名会卡」）**：
    ///
    ///   旧实现把 `chapterIndex = index` 放在**异步取数成功之后**才写。于是：
    ///
    ///   ```
    ///   tap 下一章 → loadChapter(5) 开始（await YouTube拿图）
    ///      ├─ 章节名/toolbar 读的是 chapterIndex=4 → 标题栏**还显示上一章**
    ///      │   （用户看到的就是「首部章节名卡住」）
    ///      └─ 若此时用户又点了「下一章」，第二次 loadChapter(5) 用**同一个 index**
    ///          重跑一遍 → 两个请求竞争，先回来的被后回来的覆盖，
    ///          甚至两次都基于旧 chapterIndex 算出同一个目标章（「还是本章」）
    ///   ```
    ///
    ///   修法（三处）：
    ///   ① **入口就写 `chapterIndex`**（同步、在第一个 await 之前）——
    ///      标题栏 / `nextChapterRow` / 进度保存立刻指向新章，界面不再"卡在上一章"。
    ///   ② **请求序号 `loadToken`**：每次进入 +1，await 回来后对不上就整段丢弃 ——
    ///      晚到的旧请求不会覆盖新章的内容（快速连点也只会保留最后一次）。
    ///   ③ **同章去重**：已经在加载同一章时直接返回，避免重复请求。
    /// 比例持久化的键。**必须同时满足「稳定」和「唯一」**，缺一就会复现
    /// 用户报的「打开漫画自动往上滑」：
    ///
    /// · ❌ 只用 `ch.url`：图源章节 URL **带会变的 token**，token 一换键就变，缓存永不命中。
    /// · ❌ 只用 `ch.name`：**同名章**（图集站每章都叫「正文」）共用一键 → 别章比例灌进来。
    /// · ❌ `name + 去掉 query 的 URL 路径`：`https://site/read?id=1` 与 `?id=2` 路径相同，仍碰撞。
    /// · ❌ `name + 章节序号`（我上一版）：**序号会漂移** —— 章节列表变长/重排，
    ///   或「从书架（本地缓存章节）进」与「从详情页（新拉章节）进」拿到的序号不同，
    ///   轻则缓存 miss，**重则把别章的比例灌进这一章** → 又是高度突变。
    ///
    /// ✅ 最终：用**章节首张图片 URL 的「去 query 路径」**当锚点 ——
    ///   与章节一一对应、与列表顺序**无关**、且 token 通常在 query 里所以不受影响。
    ///   拿不到图（空章节）时回退到 `序号#章节名`。
    private func ratioKey(_ ch: ComicInfo.Chapter, index: Int, images: [String]) -> String {
        let anchor: String
        if let first = images.first, !first.isEmpty {
            anchor = first.split(separator: "?", maxSplits: 1,
                                 omittingEmptySubsequences: false).first.map(String.init) ?? first
        } else {
            anchor = "\(index)#\(ch.name)"
        }
        // 🔴 锚点后面**必须再拼一个稳定区分量** —— 有些源全章节共用**同一张首图**
        //    （统一占位图 / loading 图 / 站点默认封面），光靠首图路径会把
        //    **别章的比例灌进来** → 又是「打开漫画往上滑」。
        //    （由复审智能体发现；章节名是稳定字段，为空时回退去 query 的章节 URL 路径）
        let discriminator: String
        if !ch.name.isEmpty {
            discriminator = ch.name
        } else {
            discriminator = ch.url.split(separator: "?", maxSplits: 1,
                                         omittingEmptySubsequences: false).first.map(String.init) ?? ch.url
        }
        return "\(info.origin)|\(info.noteUrl)|\(anchor)|\(discriminator)"
    }

    private func loadChapter(_ index: Int) async {
        guard info.chapters.indices.contains(index) else {
            error = "章节不存在（共 \(info.chapters.count) 章）"
            loading = false
            return
        }
        // ③ 同一章已在加载 → 直接返回（连点「下一章」不会打出两个请求）
        if index == chapterIndex, loading, store != nil { return }
        let ch = info.chapters[index]
        guard !ch.url.isEmpty else {
            error = "该章节没有链接（图源规则未解析出 ruleContentUrl）"
            loading = false
            return
        }
        // 🔴🔴 图源守卫必须**放行 JS 源** —— JS 源存在**独立的 `JS_SOURCE` 表**，
        //      而 `ComicRepository.source(url:)` 查的是 `COMIC_SOURCE_BEAN`，
        //      对 `js://<id>` **恒返回 nil** → 以前这里直接 return，报
        //      「找不到图源：js://…」（既泄漏内部标识，又让 **JS 源漫画完全打不开**）。
        //      ⚠️ 光在 `ComicEngine` 里补 JS 分支没用，会被这一句挡死 ——
        //         这是第二轮复核智能体追整条调用链才发现的（只看 diff 看不出来）。
        let src = ComicRepository.shared.source(url: info.origin)
        // ⚠️ 判「是不是 JS 源」必须用 `ComicEngine.jsSourceID(from:)` ——
        //    `isJSSource` 这个属性只长在 `SearchResult` 上，**`ComicInfo.origin`
        //    是 String，没有这个成员**，写成 `info.origin.isJSSource` 会直接编译失败。
        //    （第三轮终审智能体拦下的硬错误 —— 否则要白等一轮 1.5 小时排队才发现。）
        if ComicEngine.jsSourceID(from: info.origin) == nil, src == nil {
            error = "找不到图源：\(info.origin)\n可能该图源已被禁用或删除，请到「图源管理」检查。"
            loading = false
            return
        }
        // JS 源没有 `ComicSource` 记录：referer 退回**章节页 URL**（不能用 `js://<id>`，
        // 那是非法 Referer，部分图站会 403），UA 用全局默认；
        // 真正的图源请求头由 manifest 经 `res.headers` → `extraHeaders` 传下去并覆盖。
        // 🔴 图源可以明确要求「图片请求不发 Referer」（`header: Referer: -` 或空值）——
        //    有些图站**带任何 Referer 就返回占位图**。实测 manhua3.com 的图片 CDN：
        //      带 Referer → 301 到 `/link/link.webp`（728×728「请到本网站阅读」占位图）
        //      不带       → 200 真图（800×1150 / 158KB）
        //    默认值 `bookSourceUrl` 恰好踩中，所以这一档必须能覆盖掉。
        let refererURL = ComicEngine.SourceReferer.override(in: src?.header)
            ?? src?.bookSourceUrl ?? ch.url
        let userAgent  = src?.httpUserAgent ?? AppSettings.shared.httpUA
        // 🔴 切章必须先作废**上一章**遗留的节流任务，并把 pendingVisiblePage 复位。
        //    否则旧章的 pending 页会在 150ms 后置 `page` 并 `scheduleProgressSave`，
        //    把**旧章**的页码写进**新章**的进度上（用户看到：切到下一章，
        //    前一章却被记成读了一半）；onDisappear 也会把陈旧 pending 应用到新章
        //    → 续读跳错章。（由 10 智能体交叉审查发现）
        //
        //    ⚠️ 复位之前**先把旧章的进度落一次**，否则「切章时还没到 400ms 去抖」
        //       的那一段滚动位置会永久丢失 —— 只取消不复位是「不污染但会丢」，
        //       这才是「既不污染、也不丢」的完整解。（第二轮复核智能体指出）
        //       顺序关键：必须在 `chapterIndex` 改值**之前**调用，
        //       否则 `saveProgress()` 会把旧页码写进新章。
        scrollThrottleTask?.cancel()
        progressSaveTask?.cancel()
        // ⚠️ `store != nil` 才落库：**首次进入**阅读器时 store 还是 nil、page 初值 0，
        //    无条件 saveProgress() 会把起始章写成 page=0，把续读页码覆盖掉。
        //    （第三轮终审智能体指出的观察项）
        if store != nil {
            if pendingVisiblePage >= 0, pendingVisiblePage != page,
               pendingVisiblePage < (store?.count ?? 0) {
                page = pendingVisiblePage
            }
            saveProgress()
        }
        pendingVisiblePage = -1
        // ① 入口同步落位：标题栏、下一章按钮、进度保存立即指向新章。
        chapterIndex = index
        // ② 请求序号：本次加载的"身份"，await 回来后要重新比对。
        loadToken &+= 1
        let token = loadToken
        loading = true
        error = ""
        // 切章先清空旧图，否则会短暂显示上一章内容
        // ⚠️ 换章前必须把旧 store 的比例落盘 —— 这也是「学到比例」的重要时刻，
        //    不能指望 1.5 秒防抖一定来得及（用户可能连翻好几章）。
        store?.flushRatios()
        store = nil
        page = 0

        // ── ⓪ 离线优先：这一章如果下载过，直接从磁盘读，**零网络、零解析** ──
        //
        // 用户反馈：「下载漫画的一章下载完，我去打开看的时候还要进行加载，
        // 我不是已经把这一章图片都下载了吗，是不是这个设计本身就有问题」。
        // 确实有问题 —— 旧代码在这里**无条件**走 `contentFirstPage`（联网解析
        // 章节页拿图片 URL），再让 `ChapterImageStore` 逐张走 Nuke 从网上拉。
        // 磁盘上那份已下载的图片没有任何读取入口。
        // 现在先查 `OfflineLibrary`：命中就直接读本地文件，开章是毫秒级。
        let localFiles = OfflineLibrary.shared.images(forChapterUrl: ch.url, origin: info.origin)
        if !localFiles.isEmpty {
            let st = ChapterImageStore(localFiles: localFiles, whiteCut: s.whiteEdgeCut, origin: info.origin,
                                       persistKey: ratioKey(ch, index: index,
                                                            images: localFiles.map { $0.path }))
            store = st
            observeStore(st)
            offline = true
            if pendingRestorePage > 0, pendingRestorePage < st.count {
                page = pendingRestorePage
                stripRestorePage = pendingRestorePage
                pendingRestorePage = -1
            } else {
                if pendingRestorePage > 0 { pendingRestorePage = -1 }
                page = 0
                stripRestorePage = 0     // ⚠️ 必须显式回顶：整条 UIScrollView 会跨章复用
            }
            loading = false
            st.preload(around: page)
            saveProgress()
            return
        }
        offline = false

        // ⚡️ 只等第一页：不再等整章所有分页抓完（原来一章 5~10 页串行，
        //    用户看到的就是「打开漫画要等好久」）。剩余分页在首屏渲染后后台续。
        let res = await ComicEngine.shared.contentFirstPage(chapterUrl: ch.url, origin: info.origin)
        // ② 请求序号校验：等待期间若用户又切了章，本次结果必须整段丢弃，
        //    否则「晚到的旧章」会覆盖掉用户当前想看的新章（界面看起来就是"没换过去"）。
        guard token == loadToken else { return }
        guard !res.urls.isEmpty else {
            error = "未解析到图片\n图源规则 ruleBookContent 未命中该章节页面，或该章节需要代理。"
            loading = false
            return
        }
        let st = ChapterImageStore(urls: res.urls, referer: refererURL,
                                   ua: userAgent,
                                   whiteCut: s.whiteEdgeCut, headers: res.headers,
                                   origin: info.origin,
                                   persistKey: ratioKey(ch, index: index, images: res.urls))
        store = st
        observeStore(st)
        // ── 续读：把上次读到的页码恢复回来 ──
        if pendingRestorePage > 0, pendingRestorePage < st.count {
            page = pendingRestorePage
            stripRestorePage = pendingRestorePage   // 交给 ZoomableStripView 精确落位
            pendingRestorePage = -1
            // 🔎 插桩：确认续读真的生效（旧 bug：这里被 URL 不匹配挡掉，恒为第 0 页）
            DiagLog.event("progress", "restore",
                          "续读生效 → 第 \(page) 页（共 \(st.count) 页）")
        } else {
            // 🔎 插桩：没续读时说明原因（pending 是 0 / 越界 / 章节变了）
            DiagLog.event("progress", "restore",
                          "无续读（pending=\(pendingRestorePage) count=\(st.count)）→ 第 0 页")
            if pendingRestorePage > 0 { pendingRestorePage = -1 }   // 越界（章节变了）就忽略
            page = 0
            stripRestorePage = 0     // ⚠️ 必须显式回顶：整条 UIScrollView 会跨章复用
        }
        loading = false
        // ⚡️ 立刻开始预载当前页往后的若干张 —— 不等 SwiftUI 把 cell 渲染出来再逐张请求。
        //    这一步让首屏出图提前 1~3 秒。
        st.preload(around: page)
        saveProgress()
        // ⚡️ 后台续抓剩余分页（仅第一页时才有必要；缓存命中时 hasNext=false 直接跳过）
        if res.hasNext {
            // 捕获局部引用（ChapterImageStore 是 class，引用稳定）——
            // ReaderView 是 struct，闭包里读 @State 拿到的是快照，靠不住。
            let continuingStore = st
            Task { @MainActor in
                let more = await ComicEngine.shared.contentRemainingPages(
                    chapterUrl: ch.url, origin: info.origin, first: res.urls, headers: res.headers)
                guard !more.isEmpty else { return }
                // 后台续抓同样要认序号：章节已经切走就别再往旧 store 里追加
                guard token == loadToken else { return }
                continuingStore.appendURLs(more)
            }
        }
    }

    private func saveProgress() {
        // 🔎 插桩：进度到底写进去了没有、写的是哪一页 —— 出问题时看这条就能定案
        DiagLog.event("progress", "save",
                      "写进度 页=\(page) 章=\(chapterIndex)（\(chapter?.name ?? "?")）")
        ComicRepository.shared.updateProgress(noteUrl: info.noteUrl, chapterUrl: chapter?.url ?? "",
                                              chapterName: chapter?.name ?? "", page: page,
                                              info: info)
    }

    /// 去抖保存：滚动时 page 变化很频繁，不能每次都写 SQLite。
    /// 只保留最后一次，400ms 内没再动才落库；退出时 `onDisappear` 会强制落一次。
    private func scheduleProgressSave() {
        progressSaveTask?.cancel()
        progressSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            saveProgress()
        }
    }
}



/// 单页图片视图：按需拉取，内存友好；直接读 @Published 缓存，加载完成自动刷新
struct StoreImage: View {
    @ObservedObject var store: ChapterImageStore
    let index: Int
    /// 页面缩放：0 适应宽度 / 1 铺满 / 2 完整。
    /// 滚动长条里槽高 = 宽 × 比例，`scaledToFit` 正好铺满，且没有 GeometryReader 开销。
    var mode = 2
    /// 亮度偏移（由阅读器设置传入）。0 = 原样。
    /// ⚠️ 必须作用在**这张图**上，不能挂到外层 `TabView` —— 色彩滤镜包住翻页容器
    ///    会导致每次翻页黑一帧（2026-10-23 用户反馈「每翻一页黑一下」）。
    var brightness: Double = 0

    var body: some View {
        Group {
            // ⚠️ 用 current(_:) 单点查询，不要读 `store.loaded` 整字典
            // （后者每次访问都加锁拷贝整个字典，一屏 10 个 cell 就是 10 次全量拷贝）
            if let img = store.current(index) {
                pageImage(img)
            } else if store.failed.contains(index) {
                // 🔴 失败页必须说清「为什么 + 怎么办」（2026-10-28 成熟度改造）。
                //    以前只有「点击重试」四个字：包子图床整站 404 时，用户只能一直点，
                //    还以为是自己网络的问题。现在按 `FailureReason` 分类展示：
                //      · 网络不通 → 检查网络后重试
                //      · 图片地址失效 → 这个源图床挂了，建议换源
                //      · 被站点拦截 → 去图源页「网页登录」
                let reason = store.reason(at: index) ?? .unknown
                ZStack {
                    Color.gray.opacity(0.15)
                    VStack(spacing: 5) {
                        Image(systemName: reason.symbol)
                            .font(.system(size: 20, weight: .medium))
                        Text(reason.title)
                            .font(.caption.weight(.semibold))
                        Text(reason.advice)
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                            .opacity(0.78)
                        // 只有「重试有意义」的原因才提示点按（404/403 点多少次都没用）
                        if reason.isWorthRetrying {
                            Text("点击重试")
                                .font(.caption2)
                                .opacity(0.55)
                                .padding(.top, 2)
                        }
                    }
                    .foregroundStyle(.white.opacity(0.88))
                }
                .frame(minHeight: placeholderHeight)
                .onTapGesture { store.retry(index) }
            } else {
                // 未加载页的占位：**只显示页码，不转圈**。
                // 🔴 原来这里是 `ProgressView` + 页码 —— 翻页时图片若差一帧才到，
                //    转圈会「出现→消失」，用户看到的就是「一闪一闪」。
                //    纯色底 + 页码与阅读器底色一致，过渡完全无感。
                ZStack {
                    // 近黑而不是纯黑：万一真的出现占位，也不会是一整块死黑。
                    Color(white: 0.08)
                    Text("\(index + 1)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.28))
                }
                .frame(minHeight: placeholderHeight)
                .task {
                    // 诊断：占位出现即记一条（预载正常时不该出现）。
                    DiagLog.event("img", "placeholder", "页 \(index + 1) 未就绪，显示占位")
                    // 🔴 用 **`.ahead` 低优先级**：长条会一次渲染 8 页，占位页里
                    //    绝大多数在视口之外。以前它们按 `.visible` 抢连接，把真正的
                    //    可见页挤到后面 —— 用户看到的就是「当前这页要等一下才出图」。
                    _ = await store.image(at: index, priority: .ahead)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 按 `mode` 摆放这一页。
    ///
    /// 🔴 「适应宽度」是**默认**，也是用户要的「和滚动模式一样贴合屏幕」：
    ///    宽度 = 屏幕宽度，高度按图片比例，**超出屏幕的部分裁掉**（顶部对齐）。
    ///    滚动模式本来就是这么排的（宽铺满、高按比例往下滚），翻页模式照这个观感走，
    ///    就不会出现「整页缩在中间、上下两条黑边」的割裂感。
    @ViewBuilder
    private func pageImage(_ img: UIImage) -> some View {
        switch mode {
        case 1:
            // 铺满：裁掉溢出边缘，无黑边
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .clipped()
                .overlay(tintOverlay)
        case 2:
            // 完整：整页显示，留黑边
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
                .overlay(tintOverlay)
        default:
            // 适应宽度（默认）：宽铺满、高按比例、顶部对齐、超出裁掉
            GeometryReader { g in
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: g.size.width)
                    .overlay(tintOverlay)
                    .frame(width: g.size.width, height: g.size.height, alignment: .top)
                    .clipped()
            }
        }
    }

    /// 亮度**用蒙层实现，不用 `.brightness()` 色彩滤镜**。
    ///
    /// 🔴 滤镜会在每张图上生成离屏合成层；`TabView(.page)` 翻页时整层重新合成
    ///    → 黑一帧（2026-10-23 用户实锤「每翻一页黑一下」）。蒙层是普通半透明
    ///    色块，没有滤镜，翻页零开销。
    private var tintOverlay: Color {
        if brightness < -0.001 {
            return .black.opacity(min(0.65, -brightness * 1.7))   // 变暗
        }
        if brightness > 0.001 {
            return .white.opacity(min(0.22, brightness * 0.7))    // 提亮
        }
        return .clear
    }

    /// 未加载页的**占位高度**。
    ///
    /// ── 为什么不能只是 `minHeight: 200`（血坑）────────────────────────────
    /// `LazyVStack` 靠子视图的**估算高度**决定内容总高与「还要不要继续创建后面的 cell」。
    /// 占位符只给 200pt 时：
    ///   1. 整章内容总高被严重低估（真实漫画页 ≈ 屏宽 × 1.4~1.5 ≈ 550pt/页），
    ///      滚动条开局就快到底，用户往下滑一点立刻回弹
    ///      → 用户反馈的「**点开漫画后无法往下滑**」；
    ///   2. LazyVStack 认为可视区之外还有很长的空白，于是一直**不创建后续 cell**，
    ///      对应的 `.task` 也就永远不触发 → 下面的图**永远不开始加载**
    ///      → 用户反馈的「**等几分钟都加载不出来**」。
    ///
    /// ── 比例的取值优先级（2026-10-12 新增，修「加载时画面割裂」）────────────
    ///   ① 这一页**自己的真实比例**（`store.ratio(at:)`）——
    ///      图片被内存淘汰后比例仍留着，所以「滚回去」不会再变高变矮；
    ///   ② 本章**已加载页比例的中位数** —— 同一章比例通常一致，
    ///      比写死 1.45 准得多，首次加载的高度跳变会小一个数量级；
    ///   ③ 兜底 1.45（一个典型漫画页的高宽比）。
    /// 真图加载出来后由 `scaledToFit` 接管，高度平滑收敛到真实值。
    private var placeholderHeight: CGFloat {
        let w = max(UIScreen.main.bounds.width, 1)
        let ratio = store.ratio(at: index) ?? store.medianRatio ?? 1.45
        // ⚠️ 这里**不要**再取 `max(320, …)` 之类的下限：滚动模式下每页高度由
        //    `StripMetrics` 用同一个比例（外加 `stripSpacing`）算好后写进
        //    `.frame(height:)`，两者必须一致 —— 否则占位符的最小高度会顶开
        //    固定高度、把布局撑坏。
        return max(1, w * ratio + StripMetrics.stripSpacing)
    }
}

/// 白边裁剪（对应原版白边检测）—— 使用真实行距防越界
enum WhiteEdgeCutter {
    static func cut(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let w = cg.width, h = cg.height
        guard w > 20, h > 20, let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data as CFData) else { return image }
        let bpp = cg.bitsPerPixel / 8
        guard bpp >= 3 else { return image }   // 灰度/索引图不裁剪
        let rowBytes = max(cg.bytesPerRow, w * bpp)
        func isWhite(_ x: Int, _ y: Int) -> Bool {
            let off = y * rowBytes + x * bpp
            return ptr[off] > 245 && ptr[off + 1] > 245 && ptr[off + 2] > 245
        }
        var top = 0, bottom = h - 1
        while top < h / 4 {
            var white = true
            for x in stride(from: 0, to: w, by: max(w / 40, 1)) where !isWhite(x, top) { white = false; break }
            if !white { break }
            top += 1
        }
        while bottom > h * 3 / 4 {
            var white = true
            for x in stride(from: 0, to: w, by: max(w / 40, 1)) where !isWhite(x, bottom) { white = false; break }
            if !white { break }
            bottom -= 1
        }
        guard top > 4 || bottom < h - 5, bottom - top > h / 3 else { return image }
        let rect = CGRect(x: 0, y: top, width: w, height: bottom - top + 1)
        return image.cropped(to: rect) ?? image
    }
}

extension UIImage {
    func cropped(to rect: CGRect) -> UIImage? {
        guard let cg = cgImage?.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cg, scale: scale, orientation: imageOrientation)
    }
}

extension UIApplication {
    func topViewController() -> UIViewController? {
        guard var top = connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows }).first(where: { $0.isKeyWindow })?.rootViewController else { return nil }
        while let v = top.presentedViewController { top = v }
        return top
    }
}

extension ComicRepository {
    func execShelfReadMode(noteUrl: String, mode: Int) {
        Database.shared.exec("UPDATE COMIC_SHELF_BEAN SET READ_MODE=? WHERE NOTE_URL=?", mode, noteUrl)
    }
}

/// 只在**真的缩放/平移过**时才套 `scaleEffect` + `offset`。
///
/// 🔴 为什么必须这么写（2026-10-23 用户反馈「每翻一页黑一下」）：
///    即使 `scale == 1 && offset == .zero`，`.scaleEffect(1)` 也会让 SwiftUI
///    生成一层**离屏 transform layer**。这层包在 `TabView(.page)`
///    （底层 UIPageViewController）外面时，翻页过渡要重新合成整层 →
///    过渡的那一帧渲染不出来 → **整屏黑一下**。
///    恒等状态下**不加修饰符**，翻页就恢复原生平滑过渡。
