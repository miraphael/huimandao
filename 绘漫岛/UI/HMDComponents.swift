import SwiftUI

/// ── 组件层：借鉴 Legado-Tauri 的 AppListItem / AppSheet / AppTabs ────────────
///
/// 设计系统的「积木」：页面只负责拼装这些组件，不再各自手写样式。
/// 全部走 `HMD` token + `Theme.*`，保证 6 个页面风格一致。

// MARK: - 分组标题

/// 设置页 / 详情页的小节标题（13pt、字距 0.6、次级色）
struct HMDSectionHeader: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
    }
}

// MARK: - 列表项

/// 通用列表项：图标 + 标题 + 副标题 + 尾部，选中态 = 强调色浅底。
/// 对齐 Legado 的 `AppListItem`（title / desc / leading / trailing / selected）。
struct HMDListItem: View {
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    var selected: Bool = false
    var disabled: Bool = false
    /// 尾部自定义内容（角标 / 开关 / 箭头）
    var trailing: AnyView? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        Button {
            if !disabled { action?() }
        } label: {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(selected ? Theme.accent : Theme.text.opacity(0.6))
                        .frame(width: 22)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15))
                        .foregroundStyle(selected ? Theme.accent : Theme.text)
                        .lineLimit(2)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text.opacity(0.45))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, HMD.S.m)
            .padding(.vertical, 10)
            .background(
                selected ? HMD.activeFill : Color.clear,
                in: RoundedRectangle(cornerRadius: HMD.R.card - 4, style: .continuous)
            )
            .contentShape(Rectangle())
            .opacity(disabled ? 0.56 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

// MARK: - 底部抽屉

/// 顶部圆角的底部抽屉（对齐 Legado 的 `AppSheet`）。
/// 点背景收起；iOS 16.0 兼容（不用 `UnevenRoundedRectangle`，那个是 16.4+）。
struct HMDSheet<Content: View>: View {
    @Binding var isPresented: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: .bottom) {
            if isPresented {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(HMD.Motion.fast) { isPresented = false }
                    }
                    .transition(.opacity)

                VStack {
                    content()
                }
                .frame(maxWidth: .infinity)
                .background(
                    Theme.surface,
                    in: TopRoundedShape(radius: HMD.R.panel)
                )
                .overlay(
                    TopRoundedShape(radius: HMD.R.panel)
                        .strokeBorder(HMD.stroke, lineWidth: 0.8)
                )
                .transition(.move(edge: .bottom))
            }
        }
        .animation(HMD.Motion.fast, value: isPresented)
    }
}

/// 只有顶部两个圆角的矩形（iOS 16.0 兼容写法）
struct TopRoundedShape: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let p = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: [.topLeft, .topRight],
            cornerRadii: CGSize(width: radius, height: radius))
        return Path(p.cgPath)
    }
}

// MARK: - 页签

/// 下划线式页签（区别于胶囊 `HMDPillPicker`：用于页内主切换，更轻）
struct HMDTabs<Item: Hashable>: View {
    let items: [(id: Item, title: String)]
    @Binding var selection: Item

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.id) { it in
                let active = it.id == selection
                Button {
                    guard !active else { return }
                    withAnimation(HMD.Motion.fast) { selection = it.id }
                } label: {
                    VStack(spacing: 5) {
                        Text(it.title)
                            .font(.system(size: 14, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? Theme.text : Theme.text.opacity(0.5))
                        RoundedRectangle(cornerRadius: 1)
                            .fill(active ? Theme.accent : Color.clear)
                            .frame(height: 2)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 页头

/// 页面级标题行：大标题 + 右侧操作区
struct HMDPageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text.opacity(0.45))
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}
