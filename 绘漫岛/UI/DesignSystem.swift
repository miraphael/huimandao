import SwiftUI

/// ── 绘漫岛设计系统 ──────────────────────────────────────────────────────────
///
/// 目标：让「书架 / 漫画台 / 设置 / 详情」看起来是**同一个 App**，而不是
/// 系统控件拼出来的。所有尺寸、圆角、描边、阴影都从这里取，别再各写各的。
///
/// ⚠️ 颜色**不在这里写死**：主色/文字色/卡片色都走 `Theme.*`（跟随主题），
///    这里只负责「形状语言」—— 圆角、间距、描边透明度、投影。
enum HMD {

    /// 圆角
    enum R {
        /// 封面缩略图（Legado 用 6px，取 8 兼顾圆角观感）
        static let thumb: CGFloat = 8
        /// 普通卡片
        static let card: CGFloat = 12
        /// 大面板 / 弹层
        static let panel: CGFloat = 16
        /// 胶囊
        static let pill: CGFloat = 999
    }

    /// 间距（8pt 栅格）
    enum S {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 6
        static let s: CGFloat = 10
        static let m: CGFloat = 14
        static let l: CGFloat = 20
        static let xl: CGFloat = 28
    }

    /// 卡片描边：浅色主题用黑 6%，深色主题用白 8%
    static var stroke: Color { Color.primary.opacity(Theme.isDark ? 0.09 : 0.06) }

    /// 投影：深色主题更重（否则看不见）
    static var shadow: Color { Color.black.opacity(Theme.isDark ? 0.45 : 0.10) }
}

extension View {

    /// 统一「卡片」外观：圆角 + 细描边 + 柔和投影
    func hmdCard(radius: CGFloat = HMD.R.card, fill: Color? = nil) -> some View {
        self
            .background(fill ?? Theme.surface,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(HMD.stroke, lineWidth: 0.8)
            )
            .shadow(color: HMD.shadow, radius: 10, x: 0, y: 4)
    }

    /// 列表「行卡片」：半透明底 + 细描边，**不带投影**（列表里几十行，投影会拖慢滚动）
    func hmdRowCard(radius: CGFloat = 14) -> some View {
        self
            .background(Theme.surface.opacity(0.55),
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(HMD.stroke, lineWidth: 0.8)
            )
    }

    /// 封面缩略图：圆角 + 细描边 + 轻投影（书架 / 搜索结果 / 详情共用）
    func hmdThumb(radius: CGFloat = HMD.R.thumb) -> some View {
        self
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(HMD.stroke, lineWidth: 0.8)
            )
            .shadow(color: HMD.shadow, radius: 8, x: 0, y: 3)
    }
}

/// 品牌字标 —— 首页/空状态/关于页用，形成统一的「我们」识别。
struct HMDWordmark: View {
    var size: CGFloat = 26
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: HMD.S.xs + 2) {
            // 用「手绘线条」图标呼应「绘」
            Image(systemName: "scribble.variable")
                .font(.system(size: size * 0.74, weight: .semibold))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("绘漫岛")
                    .font(.system(size: size, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .tracking(1.5)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: size * 0.42, weight: .medium))
                        .foregroundStyle(Theme.text.opacity(0.45))
                        .tracking(0.6)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 胶囊分段控件 —— 替代系统 `.segmented`（系统样式在深浅主题下都不够「我们」）。
///
/// 选中项用强调色实心胶囊，未选中项透明；整体是一个半透明胶囊底 + 细描边。
struct HMDPillPicker<T: Hashable>: View {
    let items: [(id: T, title: String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.id) { it in
                let active = it.id == selection
                Button {
                    guard !active else { return }
                    withAnimation(.easeOut(duration: 0.16)) { selection = it.id }
                } label: {
                    Text(it.title)
                        .font(.system(size: 13, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Theme.onAccent : Theme.text.opacity(0.66))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background {
                            if active {
                                Capsule(style: .continuous).fill(Theme.accent)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.surface.opacity(0.92), in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(HMD.stroke, lineWidth: 0.8))
    }
}
