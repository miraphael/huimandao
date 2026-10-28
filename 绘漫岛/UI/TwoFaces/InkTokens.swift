import SwiftUI
import UIKit

/// ──────────────────────────────────────────────────────────────────────────
/// 「两面」设计令牌 —— 定稿方案 §4 的代码化
///
/// 只做一件事：把 `绘漫岛_产品设计方案_定稿.md` 里的数值搬成常量，
/// 让所有新界面从这里取值，而不是各写各的。
///
/// ## 与现有 `HMD` / `Theme` 的关系
/// · `Theme.*` 仍然负责**主题**（用户可换的强调色、背景、文字色）—— 不动它。
/// · `HMD.*` 仍然是老的「Legado 形状语言」（8pt 栅格、12pt 圆角）—— 也不动。
/// · `Ink.*` 是**新的两面语言**：纸白/草稿灰/朱红/红笔，以及纸的方正感（2–4 圆角）。
///
/// 三套并存是刻意的：老界面继续用 `Theme`/`HMD`，新界面用 `Ink`，
/// 迁移一屏换一屏，避免一次性大改导致回归。
///
/// ## 深浅色
/// 所有颜色都走 `dual(light, dark)`，由 `Theme.isDark` 决定。
/// **深色不是反色**，是「黑纸印白墨」：纸白 → `#141210`，墨黑 → `#F2EDE6`。
/// ──────────────────────────────────────────────────────────────────────────
enum Ink {

    // MARK: - 色彩

    /// 页面底（纸白 / 墨底）
    static var paper: Color { dual("#F7F4EE", "#141210") }
    /// 卡片底（比纸亮一档）
    static var card: Color { dual("#FFFDF8", "#1C1916") }
    /// 草稿面底（牛皮灰）
    static var draft: Color { dual("#E8E2D6", "#221E19") }
    /// 主文字（暖墨）
    static var ink: Color { dual("#16130F", "#F2EDE6") }
    /// 草稿面文字（石墨）
    static var graphite: Color { dual("#5A544B", "#B8B0A4") }
    /// 主强调（朱红）
    static var ver: Color { dual("#D8392B", "#E8564A") }
    /// 红笔批注 / 失败
    static var pencil: Color { dual("#B23A2A", "#D9695A") }
    /// 次强调（靛蓝）
    static var indigo: Color { dual("#2C4A7C", "#7FA3D8") }
    /// 成功 / 健康
    static var moss: Color { dual("#3F7A4A", "#6FBF87") }
    /// 警告
    static var ochre: Color { dual("#B5822A", "#D9A64A") }
    /// 次要文字
    static var ash: Color { dual("#6E6862", "#A39C93") }
    /// 说明 / 占位
    static var faint: Color { dual("#A8A29A", "#6E6862") }
    /// 描边（纸边，1px）
    static var line: Color { dual("#16130F", "#F2EDE6").opacity(Theme.isDark ? 0.14 : 0.12) }
    /// 更淡的分隔线
    static var lineSoft: Color { dual("#16130F", "#F2EDE6").opacity(Theme.isDark ? 0.08 : 0.06) }
    /// 草稿面的方格线
    static var draftGrid: Color {
        (Color(hex: "#5A544B") ?? .gray).opacity(Theme.isDark ? 0.18 : 0.10)
    }

    /// 按当前深浅色二选一
    private static func dual(_ light: String, _ dark: String) -> Color {
        Color(hex: Theme.isDark ? dark : light) ?? .gray
    }

    // MARK: - 间距（4 的倍数）

    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let huge: CGFloat = 48
        /// 页面左右留白（统一 16）
        static let page: CGFloat = 16
    }

    // MARK: - 圆角（纸是方的，所以最大只到 12）

    enum Radius {
        static let tag: CGFloat = 2
        static let button: CGFloat = 8
        static let card: CGFloat = 4
        static let sheet: CGFloat = 12
        static let pill: CGFloat = 999
    }

    // MARK: - 动效（只有 5 条曲线，按语义选 —— 定稿 §4.7）

    enum Motion {
        /// 标准：大多数状态切换
        static let standard = Animation.spring(response: 0.34, dampingFraction: 0.78)
        /// 轻快：按压、选中、chip
        static let quick = Animation.spring(response: 0.22, dampingFraction: 0.90)
        /// 强调：封面放大转场、翻面
        static let emphasis = Animation.spring(response: 0.42, dampingFraction: 0.82)
        /// 翻面专用：纸翻过去，不能有弹跳
        static let flip = Animation.timingCurve(0.36, 0.08, 0.18, 1, duration: 0.64)
    }

    // MARK: - 触感

    enum Haptic {
        static func light() {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        static func medium() {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        static func success() {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        static func error() {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

// MARK: - 字体阶梯（定稿 §4.2）

extension Font {
    /// 页面大标题：32 / Bold / 衬线
    static func inkMasthead(_ size: CGFloat = 32) -> Font {
        .system(size: size, weight: .bold, design: .serif)
    }
    /// 书名、详情标题：22 / Bold / 衬线
    static func inkTitle(_ size: CGFloat = 22) -> Font {
        .system(size: size, weight: .bold, design: .serif)
    }
    /// 区块标题：15 / Semibold / 无衬线
    static func inkSection() -> Font {
        .system(size: 15, weight: .semibold)
    }
    /// 正文：15 / Regular / 无衬线
    static func inkBody(_ size: CGFloat = 15) -> Font {
        .system(size: size)
    }
    /// 卡片副标题：13 / Medium
    static func inkSub() -> Font {
        .system(size: 13, weight: .medium)
    }
    /// 元信息：11.5 / Medium
    static func inkCaption() -> Font {
        .system(size: 11.5, weight: .medium)
    }
    /// 期号 / 页码 / 统计：等宽
    static func inkNumeral(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .semibold, design: .monospaced)
    }
    /// 草稿面全部文字：等宽
    static func inkDraft(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }
}

// MARK: - 常用小修饰

extension View {
    /// 1px 纸边（**不用阴影** —— 纸是叠在一起的，不是浮起来的）
    func inkEdge(_ radius: CGFloat = Ink.Radius.card) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Ink.line, lineWidth: 0.8)
        )
    }

    /// 等宽数字（期号 / 页码）
    ///
    /// ⚠️ 这里**不能**用 `.tracking()`：`View` 协议没有这个方法，
    ///    只有 `Text` 有（`Text.tracking`）。字距请在 `Text` 上单独加。
    func inkNumeralStyle(_ size: CGFloat = 11, color: Color? = nil) -> some View {
        self.font(.inkNumeral(size))
            .foregroundStyle(color ?? Ink.faint)
    }
}
