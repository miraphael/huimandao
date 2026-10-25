import SwiftUI
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
                    // 下划线式页签（组件层 HMDTabs）：比系统 segmented 更轻
                    HMDTabs(items: visibleTabs.map { (id: $0.id, title: $0.title) },
                            selection: $tab)
                        .frame(width: 180)
                }
                // 「搜索」已有独立 Tab（AppShellView），书架工具栏不再放放大镜
            }
        }
    }

    private var currentTitle: String {
        visibleTabs.first(where: { $0.id == tab })?.title ?? "书架"
    }
}
