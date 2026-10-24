import SwiftUI

/// 三大主标签：漫画 / 漫画台 / 设置
///
/// ── 布局定稿（用户明确要求）──────────────────────────────────────────────
///   · 漫画   = **书架 + 下载任务**
///   · 漫画台 = **推荐 + 发现 + 图源管理**
///   · 设置   = 外观 / 阅读 / 网络 / 备份 + **历史、本地**（收纳进来）+ **账号**
///
/// 这是用户在看到 Venera / Aidoku 的模块划分后给出的最终结构，
/// 对应关系：
///   · Venera `app_shell/main_page.dart` = Home / Favorites / Explore / Categories
///     → 我们的「书架 / 推荐 / 发现 / 图源管理」
///   · Aidoku `App/Root/TabBarController.swift` = Library / Browse / Search / History / Settings
///     → 我们的「漫画 / 漫画台 / 设置」（历史与设置合并，符合用户要求）
///
/// ── 为什么把「下载任务」放漫画页 ──────────────────────────────────────
/// 下载是「我要看漫画」这条主线的延伸（离线看），不管理这套系统。
/// Aidoku 也是把 `DownloadQueueView` 挂在 Library 页里，而不是单独的「管理」标签。
struct RootTabView: View {
    @EnvironmentObject var s: AppSettings
    /// 主题 —— 三个主页面各自铺一层主题背景（含用户自定义图）。
    /// 不依赖 TabView 容器的背景透传（那层行为在系统版本间不稳定）。
    @EnvironmentObject var themeStore: ThemeStore

    var body: some View {
        TabView {
            // ⚠️ 背景铺在 **NavigationStack 外层**（这里），不要放进栈内的页面里 ——
            //    栈内用 `ignoresSafeArea` 的背景会让 push 转场残留上一页快照
            //    （用户反馈的「设置点进去，上个界面往下滑」）。
            // ⚠️ 背景已改到 `HMDApp` 的**根层 ZStack** 里统一铺一层 ——
            //    以前这里是每个 tab 各挂一个 `.background(ThemeBackground(...))`，
            //    但 `.background()` 挂在 TabView 的子项上会被 TabView 容器盖住
            //    （真机实测 2026-10-14：日志显示图加载成功却看不到）。
            //    详见 `HMDApp.body` 里的说明。这里不再重复铺。
            ComicTabView()
                .scrollContentBackgroundCompat()
                .tabItem { Label("漫画", systemImage: "books.vertical.fill") }
            ConsoleTabView()
                .scrollContentBackgroundCompat()
                .tabItem { Label("漫画台", systemImage: "square.grid.2x2.fill") }
            SettingsView()
                .scrollContentBackgroundCompat()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        // 🔴 **标签栏 / 导航栏用的是「材质」背景，不是普通颜色** ——
        //    它们会把窗口层壁纸挡在下面。必须显式关掉，否则整条栏是半透明灰，
        //    和背景图永远对不上（Agent 查证 + 真机 2026-10-14）。
        .toolbarBackground(.hidden, for: .tabBar)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

// MARK: - 漫画（书架 + 下载任务）

/// 「漫画」标签页：顶部分段切 **书架 / 下载**，右上角搜索。
///
/// 分段可见性：书架始终在，下载始终在（用户要求「漫画的就书架、下载任务就可以了」）。
/// 搜索入口放在这里而不是漫画台 —— 搜索是「找漫画看」，属于阅读主线。
struct ComicTabView: View {
    @EnvironmentObject var s: AppSettings
    /// 🔴 **必须观察 ThemeStore** —— 下面 `.background(ThemeBackground(theme: themeStore.current))`
    ///    要跟着主题变化重算。只写 `ThemeStore.shared.current`（不观察）时，
    ///    切换主题**视图不会重算** → 一直显示上一个主题的图，
    ///    **重启后才对**（真机反馈 2026-10-14）。
    @EnvironmentObject var themeStore: ThemeStore
    @State private var tab: Int = 0

    /// 可见分段：0 书架，1 下载任务
    private var visibleTabs: [(id: Int, title: String)] {
        [(0, "书架"), (1, "下载")]
    }

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case 1: DownloadTasksView(embedded: true)
                default: ShelfView(embedded: true)
                }
            }
            // 🔴 主题背景放在**这个 tab 的内容之下**（而不是 App 根层）——
            //    依据：主题编辑器里的「预览」用同样的 `ThemeBackground(theme:)`
            //    当普通内容放，**一直能显示**；根层的几种写法全都看不到。
            .background(ThemeBackground(theme: themeStore.current))
            .navigationTitle(currentTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $tab) {
                        ForEach(visibleTabs, id: \.id) { t in
                            Text(t.title).tag(t.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: CGFloat(visibleTabs.count) * 90)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // ⚠️ 用 `NavigationLink` **push** 而不是 `.sheet`（用户要求
                    //    「搜索打开应该是一个独立的界面」）。push 进当前 NavigationStack，
                    //    有自己的导航栏、支持边缘滑动返回，与「书架 / 下载」同层级。
                    //    `embedded: true` 是因为 SearchView 自带 NavigationStack，
                    //    不再嵌一层才不会出现双层导航栏。
                    NavigationLink { SearchView(embedded: true) } label: {
                        Image(systemName: "magnifyingglass")
                    }
                }
            }
        }
    }

    private var currentTitle: String {
        visibleTabs.first(where: { $0.id == tab })?.title ?? "书架"
    }
}

// MARK: - 漫画台（推荐 + 发现 + 图源管理）

/// 「漫画台」：**推荐 / 发现 / 图源管理** 三段。
///
/// 用户要求：「漫画台是 推荐 + 发现，设置: 图源管理」→
/// 即推荐与发现是两个平级的内容入口，图源管理是它们的支撑设施。
/// 三者放在同一页用分段切换：推荐/发现是「逛」，图源管理是「配置能逛哪些站」。
struct ConsoleTabView: View {
    @EnvironmentObject var s: AppSettings
    /// 🔴 必须观察 ThemeStore —— 背景用 `themeStore.current`，不观察则切主题不刷新
    @EnvironmentObject var themeStore: ThemeStore
    @State private var tab: Int = 0

    private var visibleTabs: [(id: Int, title: String)] {
        // ⚠️ **必须真正读设置**。原先这里是硬编码的 `[(0,"推荐"),(1,"发现"),(2,"图源")]`，
        //    而设置页却提供了「显示推荐 / 显示发现」两个开关 —— 拨了毫无反应，
        //    是典型的**假开关**（用户会认为 App 坏了）。
        //    图源管理是支撑设施（没有它就没有任何内容可逛），所以始终显示。
        var t: [(id: Int, title: String)] = []
        if s.showRecommend { t.append((0, "推荐")) }
        if s.showFind { t.append((1, "发现")) }
        t.append((2, "图源"))
        return t
    }

    /// 当前实际生效的分段 —— 若用户把当前分段关掉了，回退到第一个可见分段。
    /// 不这样做的话，关掉「推荐」后 `tab` 仍是 0，界面会显示一个已经不该存在的分段。
    private var effectiveTab: Int {
        visibleTabs.contains { $0.id == tab } ? tab : (visibleTabs.first?.id ?? 2)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch effectiveTab {
                case 1: FindView(embedded: true)
                case 2: SourceListView(embedded: true)
                default: RecommendView(embedded: true)
                }
            }
            .background(ThemeBackground(theme: themeStore.current))
            .navigationTitle(currentTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    // 绑定到 `effectiveTab`：用户关掉某分段后 `tab` 可能指向已隐藏的分段，
                    // 直接绑 `$tab` 会让分段控件「没有选中项」。读走 effectiveTab、写回 tab。
                    // 自绘胶囊分段（替代系统 segmented —— 更贴合「我们」的圆润风格）
                    HMDPillPicker(
                        items: visibleTabs.map { (id: $0.id, title: $0.title) },
                        selection: Binding(get: { effectiveTab }, set: { tab = $0 })
                    )
                }
            }
        }
    }

    private var currentTitle: String {
        // ⚠️ 必须用 `effectiveTab` 而不是 `tab`：用户关掉某分段后
        //    `tab` 可能指向已隐藏的分段，标题会显示一个不该存在的分段名。
        visibleTabs.first(where: { $0.id == effectiveTab })?.title ?? "推荐"
    }
}

// build retry marker: 2026-10-08
