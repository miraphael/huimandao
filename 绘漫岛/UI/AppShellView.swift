import SwiftUI

/// ── 应用外壳：6 页面 + 自绘底栏（对齐 Legado-Tauri 的页面划分）──────────────
///
/// 页面：漫画 / 发现 / 搜索 / 图源 / 扩展 / 设置。
///
/// 为什么不用系统 `TabView`：
/// · UIKit 的 TabBar **最多 5 个** item，第 6 个会被塞进「更多」—— 体验很差；
/// · 自绘底栏可以完全贴合设计系统（强调色选中、zinc 分隔线）。
///
/// 为什么 6 页全部常驻（ZStack + opacity）而不是 `switch`：
/// `switch` 切页会**销毁页面状态** —— 搜索框里输了一半、书架的滚动位置都会丢。
/// 全部常驻 + `allowsHitTesting` 控制，行为与 TabView 一致。
enum ShellPage: String, CaseIterable, Identifiable {
    case comics, explore, search, sources, extensions, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .comics: return "漫画"
        case .explore: return "发现"
        case .search: return "搜索"
        case .sources: return "图源"
        case .extensions: return "扩展"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .comics: return "books.vertical.fill"
        case .explore: return "safari.fill"
        case .search: return "magnifyingglass"
        case .sources: return "square.stack.3d.up.fill"
        case .extensions: return "puzzlepiece.extension.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

/// 底栏显隐的全局开关：阅读器要**全屏沉浸**，进入时隐藏底栏。
final class ShellBarState: ObservableObject {
    static let shared = ShellBarState()
    @Published var hidden = false
}

struct AppShellView: View {
    @State private var page: ShellPage = .comics
    @StateObject private var bar = ShellBarState.shared

    var body: some View {
        ZStack {
            ForEach(ShellPage.allCases) { p in
                pageView(p)
                    .opacity(page == p ? 1 : 0)
                    .allowsHitTesting(page == p)
                    .accessibilityHidden(page != p)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !bar.hidden { shellBar }
        }
    }

    // MARK: - 页面

    @ViewBuilder
    private func pageView(_ p: ShellPage) -> some View {
        switch p {
        case .comics: ComicTabView()
        // 发现 = 老漫画台的「选源 → 栏目 → 内容列表」（RecommendView）
        case .explore: RecommendView()
        case .search: SearchView()
        // 图源 = 纯图源管理（导入/导出/校验/启停，全部功能集中在这）
        case .sources: SourceListView()
        case .extensions: extensionsPage
        case .settings: SettingsView()
        }
    }

    /// 扩展页：JS 源 / 插件（目前是 JS 图源，后续接入更多扩展类型）
    private var extensionsPage: some View {
        NavigationStack {
            JSSourceListView()
                .transparentScrollBackground()
                .navigationTitle("扩展")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - 底栏

    private var shellBar: some View {
        HStack(spacing: 0) {
            ForEach(ShellPage.allCases) { p in
                let active = page == p
                Button {
                    guard page != p else { return }
                    withAnimation(.easeOut(duration: 0.15)) { page = p }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: p.icon)
                            .font(.system(size: 17, weight: active ? .semibold : .regular))
                            .symbolRenderingMode(.hierarchical)
                        Text(p.title)
                            .font(.system(size: 9, weight: active ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .foregroundStyle(active ? Theme.accent : Theme.text.opacity(0.52))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(p.title)
            }
        }
        .padding(.top, 7)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle().fill(HMD.stroke).frame(height: 0.6)
        }
    }
}
