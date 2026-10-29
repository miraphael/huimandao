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
///
/// ## 为什么用「占用者集合」而不是一个布尔值（2026-10-29 用户实测「打开漫画后
/// 底栏又冒出来了」）
///
/// 原来的实现是 `hidden: Bool`，阅读器 `onAppear` 置 true、`onDisappear` 置 false。
/// 但 SwiftUI **可能重复触发**这两个回调（视图身份变化、重新布局、
/// `@State` 批量更新时都可能）。只要多来一次 `onDisappear`，布尔值就被打成 false
/// —— 用户正在看漫画，底栏凭空出现。
///
/// 用「占用者 token 集合」：
/// · 每个阅读器实例有唯一 token，`hide(owner:)` 是幂等的（重复调用无副作用）
/// · 旧实例的 `restore(owner:)` 只移除**自己**的 token
///   —— 新实例已经占位时，集合非空，底栏仍然保持隐藏
final class ShellBarState: ObservableObject {
    static let shared = ShellBarState()

    private var owners: Set<String> = []

    @Published private(set) var hidden = false

    func hide(owner: String) {
        owners.insert(owner)
        if !hidden { hidden = true }
    }

    func restore(owner: String) {
        owners.remove(owner)
        if owners.isEmpty, hidden { hidden = false }
    }

    /// 兜底：切页 / 回前台时强制恢复（防止 onDisappear 压根没触发导致底栏永久消失）
    func reset() {
        owners.removeAll()
        if hidden { hidden = false }
    }
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
        // 🔴 保险：切页 / 回前台 一律恢复底栏 ——
        //    阅读器用 `hidden` 隐藏底栏，万一 onDisappear 没触发（SwiftUI 偶发），
        //    底栏会永久消失。这两条兜底把它拉回来。
        .onChange(of: page) { _ in
            ShellBarState.shared.reset()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)) { _ in
            ShellBarState.shared.reset()
        }
        .onAppear {
            DiagLog.event("shell", "bar", "底栏出现（hidden=\(bar.hidden)）")
        }
        .onChange(of: bar.hidden) { v in
            DiagLog.event("shell", "bar", v ? "底栏隐藏（进入阅读）" : "底栏恢复")
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
                            .font(.system(size: 18, weight: active ? .semibold : .regular))
                            .symbolRenderingMode(.hierarchical)
                        Text(p.title)
                            .font(.system(size: 9, weight: active ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .foregroundStyle(active ? Theme.accent : Theme.text.opacity(0.62))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(p.title)
            }
        }
        .padding(.top, 7)
        // 🔴 底栏必须**看得出是个栏**：v166 按截图改成「页面底色延续」后，
        //    浅色主题下和页面几乎同色 + 图标 52% 灰 → 用户反馈「底部没看到有东西」。
        //    现在用 surface 卡面 + 顶部细线 + 上投影，明确分层。
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(HMD.stroke).frame(height: 0.6)
        }
        .shadow(color: .black.opacity(0.07), radius: 10, x: 0, y: -3)
    }
}
