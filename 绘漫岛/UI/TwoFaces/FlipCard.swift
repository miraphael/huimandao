import Foundation
import SwiftUI

/// ──────────────────────────────────────────────────────────────────────────
/// 翻面容器 + 折角 —— 「两面」的核心交互（定稿 §3.5）
///
/// ## 为什么翻面要这么实现（踩过坑才这么写）
///
/// 直觉写法是「两层都渲染，靠 `opacity` 切换」。但 3D 旋转过程中
/// 0°–90° 之间两层同时可见 → **背面的字是镜像的**，用户会看到一瞬反字。
///
/// 正确做法：**在转到侧面（90°）那一刻交换内容**。
/// SwiftUI 没有「背面剔除」（backface culling），所以这里用
/// 「翻转开始 → 0.30s 后（约 90°）交换渲染的内容」来模拟。
///
/// ⚠️ 交换时机**不能**用 `.animation(delay:)` 挂在 `opacity` 上 ——
///    那只是把透明度动画延后，两层仍然同时存在于视图树里，
///    在某些机型上会出现一层残留（半透明反字）。
///    这里用 `@State showBack` 真正地**只渲染一层**，物理上不可能出现反字。
///
/// ## 折角（DogEar）
/// 翻面如果只靠长按，用户永远发现不了。折角是**纸被翻过的痕迹**，
/// 不需要教学。它放在 `topTrailing`，只有正面显示（翻到背面后不该再有折角）。
/// ──────────────────────────────────────────────────────────────────────────

/// 翻面轴向
enum FlipAxis {
    /// 卡片：绕 Y 轴左右翻
    case horizontal
    /// 行：绕 X 轴上下翻
    case vertical
}

struct FlipCard<Front: View, Back: View>: View {
    @Binding var flipped: Bool

    var axis: FlipAxis = .horizontal
    var showsDogEar: Bool = true
    var radius: CGFloat = Ink.Radius.card
    /// 转到侧面（约 90°）时交换内容的延时。0.64s 的一半取 0.30s。
    var swapDelay: Double = 0.30

    /// 真正决定「渲染哪一面」的状态 —— 与 `flipped` 分开，才能延后交换
    @State private var showBack: Bool

    private let front: Front
    private let back: Back

    init(flipped: Binding<Bool>,
         axis: FlipAxis = .horizontal,
         showsDogEar: Bool = true,
         radius: CGFloat = Ink.Radius.card,
         @ViewBuilder front: () -> Front,
         @ViewBuilder back: () -> Back) {
        self._flipped = flipped
        self.axis = axis
        self.showsDogEar = showsDogEar
        self.radius = radius
        self.front = front()
        self.back = back()
        self._showBack = State(initialValue: flipped.wrappedValue)
    }

    private var rotationAxis: (x: CGFloat, y: CGFloat, z: CGFloat) {
        switch axis {
        case .horizontal: return (x: 0, y: 1, z: 0)
        case .vertical:   return (x: 1, y: 0, z: 0)
        }
    }

    var body: some View {
        ZStack {
            if showBack {
                back
                    // 背面本身先转 180°，容器再转 180° → 合起来是正向
                    .rotation3DEffect(.degrees(180), axis: rotationAxis)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { toggle() }
            } else {
                front
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { toggle() }
            }
        }
        .rotation3DEffect(.degrees(flipped ? 180 : 0),
                          axis: rotationAxis,
                          perspective: 0.55)
        .overlay(alignment: .topTrailing) {
            if showsDogEar && !showBack {
                DogEar(size: 22) { toggle() }
            }
        }
        .onAppear { showBack = flipped }
        .onChange(of: flipped) { value in
            // 翻面开始后 0.30s（约 90°，纸是侧着的）再换内容
            DispatchQueue.main.asyncAfter(deadline: .now() + swapDelay) {
                showBack = value
            }
        }
    }

    private func toggle() {
        Ink.Haptic.light()
        withAnimation(Ink.Motion.flip) {
            flipped.toggle()
        }
    }
}

// MARK: - 折角

/// 折角 —— 纸被翻过的痕迹。点它翻面。
struct DogEar: View {
    var size: CGFloat = 22
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                DogEarShape()
                    .fill(Ink.card)
                DogEarShape()
                    .stroke(Ink.line, lineWidth: 0.8)
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("翻面")
    }
}

/// 右上角的直角三角形（斜边从左上到右下）
struct DogEarShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
