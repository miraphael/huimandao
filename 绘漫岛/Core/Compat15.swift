import SwiftUI

// MARK: - iOS 15 兼容层
//
// project.yml 部署目标已从 16.0 降到 15.0。
// 以下 API 只在 iOS 16+ 可用，需要条件分支：
//   NavigationStack / navigationDestination / .bold() /
//   .toolbar(.hidden, for:) / .presentationDetents / .listRowSeparator / PhotosPicker
//
// 策略：
//   - NavigationStack → iOS 15 用 NavigationView(.stack)
//   - .bold() → 用 .fontWeight(.bold) （所有版本可用）
//   - .toolbar(.hidden, for:) → iOS 15 用 .navigationBarHidden / .toolbar(.hidden)
//   - .presentationDetents → iOS 15 直接跳过（sheet 全高）
//   - .listRowSeparator → iOS 15 直接跳过
//   - PhotosPicker → iOS 15 用已有 ImagePicker (UIKit bridge)

// MARK: - HMDNavigationStack：NavigationStack 的 iOS 15 兼容替代

/// 用法：把 `NavigationStack { ... }` 替换为 `HMDNavigationStack { ... }`。
/// iOS 16+: 使用 NavigationStack（支持 navigationDestination / 类型安全路由）
/// iOS 15:  回退到 NavigationView + .stack 样式（用 NavigationLink 导航）
struct HMDNavigationStack<Root: View>: View {
    @ViewBuilder var root: Root

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack { root }
        } else {
            NavigationView { root }
                .navigationViewStyle(.stack)
        }
    }
}

// MARK: - HMDNavigationStackWithPath：带路径的版本（替代 NavigationStack(path:)）

/// 用法：把 `NavigationStack(path: $path) { ... }` 替换。
/// iOS 16+: NavigationStack(path:) + navigationDestination
/// iOS 15:  回退到 NavigationView(.stack)，路径绑定用 @State + programmatic push
@available(iOS 16.0, *)
struct HMDNavigationStackWithPath<Path: Hashable, Root: View>: View {
    @Binding var path: [Path]
    @ViewBuilder var root: Root

    var body: some View {
        NavigationStack(path: $path) { root }
    }
}

// MARK: - .hmdBold()：替代 .bold() View 修饰符

extension View {
    /// iOS 16+ 的 `.bold()` 修饰符在 iOS 15 不可用。
    /// 用 `.fontWeight(.bold)` 替代，所有版本通用。
    @ViewBuilder
    func hmdBold() -> some View {
        self.fontWeight(.bold)
    }
}

// MARK: - .hmdToolbarHidden：替代 .toolbar(.hidden, for: .tabBar/.navigationBar)

extension View {
    /// iOS 16+: `.toolbar(.hidden, for: .tabBar)`
    /// iOS 15:  `.toolbar(.hidden)` 只隐藏导航栏；tabBar 隐藏需要外部控制。
    @ViewBuilder
    func hmdHideTabBar() -> some View {
        if #available(iOS 16.0, *) {
            self.toolbar(.hidden, for: .tabBar)
        } else {
            // iOS 15 没有 tabBar 工具栏 API
            // 阅读器已通过 ShellBarState 隐藏底栏，这里无需额外操作
            self
        }
    }

    /// iOS 16+: `.toolbar(.hidden, for: .navigationBar)`
    /// iOS 15:  `.navigationBarHidden(true)` + `.toolbar(.hidden)`
    @ViewBuilder
    func hmdHideNavBar() -> some View {
        if #available(iOS 16.0, *) {
            self.toolbar(.hidden, for: .navigationBar)
        } else {
            self.navigationBarHidden(true)
                .toolbar(.hidden)
        }
    }

    /// iOS 16+: `.toolbar(.visible, for: .navigationBar)`
    /// iOS 15:  `.navigationBarHidden(false)` + `.toolbar(.visible)`
    @ViewBuilder
    func hmdShowNavBar() -> some View {
        if #available(iOS 16.0, *) {
            self.toolbar(.visible, for: .navigationBar)
        } else {
            self.navigationBarHidden(false)
                .toolbar(.visible)
        }
    }

    /// iOS 16+: `.toolbar(.visible/.hidden, for: .navigationBar)` 按条件显隐
    /// iOS 15:  `.navigationBarHidden(!visible)` + `.toolbar(visible ? .visible : .hidden)`
    @ViewBuilder
    func hmdNavBarVisibility(_ visible: Bool) -> some View {
        if #available(iOS 16.0, *) {
            self.toolbar(visible ? .visible : .hidden, for: .navigationBar)
        } else {
            self.navigationBarHidden(!visible)
                .toolbar(visible ? .visible : .hidden)
        }
    }
}

// MARK: - .hmdListRowSeparator：替代 .listRowSeparator(.hidden)

extension View {
    /// iOS 16+: `.listRowSeparator(.hidden)`
    /// iOS 15:  不支持，直接跳过（行分隔线仍显示但不影响功能）
    @ViewBuilder
    func hmdListRowSeparatorHidden() -> some View {
        if #available(iOS 16.0, *) {
            self.listRowSeparator(.hidden)
        } else {
            self
        }
    }

    /// iOS 16+: `.listRowSeparator(.automatic)` / `.listRowSeparator(.hidden)`
    @ViewBuilder
    func hmdListRowSeparator(_ visibility: Bool) -> some View {
        if #available(iOS 16.0, *) {
            self.listRowSeparator(visibility ? .automatic : .hidden)
        } else {
            self
        }
    }
}

// MARK: - .hmdNavigationDestination(isPresented:)：替代 .navigationDestination(isPresented:)

extension View {
    /// iOS 16+: `.navigationDestination(isPresented:) { destination }`
    /// iOS 15:  用隐藏的 NavigationLink(isActive:) 实现 programmatic push。
    ///
    /// 用法：
    /// ```swift
    /// // 原来：
    /// .navigationDestination(isPresented: $show) { DestView() }
    /// // 改成：
    /// .hmdNavigationDestination(isPresented: $show) { DestView() }
    /// ```
    @ViewBuilder
    func hmdNavigationDestination<Destination: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        if #available(iOS 16.0, *) {
            self.navigationDestination(isPresented: isPresented, destination: destination)
        } else {
            self.background(
                NavigationLink(
                    destination: destination(),
                    isActive: isPresented,
                    label: { EmptyView() }
                )
                .opacity(0)
                .frame(width: 0, height: 0)
            )
        }
    }
}

// MARK: - HMDNavigationLink：替代 NavigationLink(value:)（iOS 16+ 类型安全路由）

/// iOS 16+: `NavigationLink(value: T) { label }` + `navigationDestination(for: T.self)`
/// iOS 15:  回退到 `NavigationLink(destination:) { label }`
///
/// 用法：
/// ```swift
/// // 原来：
/// NavigationLink(value: ShelfRoute.detail(item)) { label }
/// // 改成：
/// HMDNavigationLink(value: ShelfRoute.detail(item)) { label } destination: { route in
///     switch route { ... }
/// }
/// ```
/// ⚠️ 这个方案要求每个使用点都提供 destination builder，比较繁琐。
/// 更简洁的方案是在 ShelfView 等页面直接用 `NavigationLink(destination:)` 替代。

// MARK: - HMDLabeledContent：替代 LabeledContent（iOS 16+）

/// iOS 16+: `LabeledContent("标签", value: "值")`
/// iOS 15:  用 HStack + Text 手动构建
struct HMDLabeledContent: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - .hmdPresentationDetents：替代 .presentationDetents

extension View {
    /// iOS 16+: `.presentationDetents([.medium, .large])`
    /// iOS 15:  不支持，sheet 始终全高展示
    @ViewBuilder
    func hmdPresentationDetents(_ detents: Set<HMDPresentationDetent>) -> some View {
        if #available(iOS 16.0, *) {
            let mapped = detents.map { $0.toDetent }
            self.presentationDetents(Set(mapped))
        } else {
            self
        }
    }
}

/// iOS 15 兼容的 PresentationDetent 替代
enum HMDPresentationDetent: Hashable {
    case medium
    case large

    @available(iOS 16.0, *)
    var toDetent: PresentationDetent {
        switch self {
        case .medium: return .medium
        case .large: return .large
        }
    }
}
