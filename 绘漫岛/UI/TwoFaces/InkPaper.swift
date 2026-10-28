import SwiftUI
import UIKit

/// ──────────────────────────────────────────────────────────────────────────
/// 纸与网点 —— 「两面」的两种材质底（定稿 §3.2 / §4.6）
///
/// · `InkPaper`   印刷面：纸白 + 纤维噪点
/// · `DraftPaper` 草稿面：牛皮灰 + 方格网
/// · `HalftoneView` 网点填充（空态 / 骨架 / 装饰）
///
/// ## 为什么噪点是「一张缓存图」而不是 Canvas
/// 全屏噪点如果用 Canvas 逐点画，一帧要画 390×800/4 ≈ 7.8 万个点，
/// 滚动时直接掉帧。这里一次性生成 128×128 灰度噪点（约 1.6 万字节），
/// 用 `.resizable(resizingMode: .tile)` 平铺 —— 生成一次，之后零开销。
///
/// ## 为什么网点可以用 Canvas
/// 网点只出现在**小面积**（空态插画 56pt 高、骨架块、装饰条），
/// 6pt 间距下 390×56 只有约 600 个圆点，Canvas 完全撑得住。
/// **不要**把 `HalftoneView` 铺满整屏。
/// ──────────────────────────────────────────────────────────────────────────

enum InkTexture {

    /// 128×128 灰度噪点，全 App 复用同一张（`static let` 懒加载，只生成一次）
    static let noise: UIImage = makeNoise(128)

    /// 确定性 xorshift64 噪点 —— 不用 `arc4random`，这样每次启动纹理一致，
    /// 截图对比时不会因为噪点不同而误判「界面变了」。
    private static func makeNoise(_ size: Int) -> UIImage {
        let bytesPerRow = size * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * size)
        var s: UInt64 = 0x2545_F491_4F6C_DD1D
        for i in 0..<(size * size) {
            s ^= s << 13
            s ^= s >> 7
            s ^= s << 17
            let v = UInt8(truncatingIfNeeded: s)
            let o = i * 4
            buffer[o] = v
            buffer[o + 1] = v
            buffer[o + 2] = v
            buffer[o + 3] = 255
        }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(buffer) as CFData),
              let cg = CGImage(width: size, height: size,
                               bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: bytesPerRow, space: space,
                               bitmapInfo: CGBitmapInfo(
                                   rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent)
        else { return UIImage() }
        return UIImage(cgImage: cg)
    }
}

/// 印刷面底 —— 纸白 + 纤维噪点。用作整页背景时铺满并忽略安全区。
struct InkPaper: View {
    /// 噪点强度。默认 5%，调高会显得"脏"，别超过 8%。
    var grain: Double = 0.05
    /// 是否铺满安全区。整页背景用 true（默认）；卡片内的材质样例用 false。
    var fullBleed: Bool = true

    var body: some View {
        ZStack {
            Ink.paper
            Image(uiImage: InkTexture.noise)
                .resizable(resizingMode: .tile)
                .opacity(grain)
                // 浅色下噪点压暗（纸的纤维），深色下提亮（黑纸的白纤维）
                .blendMode(Theme.isDark ? .screen : .multiply)
                .allowsHitTesting(false)
        }
        .modifier(FullBleedIfNeeded(on: fullBleed))
    }
}

/// 草稿面底 —— 牛皮灰 + 16pt 方格网。
struct DraftPaper: View {
    /// 方格边长。默认 16pt（定稿 §3.2）。
    var grid: CGFloat = 16
    /// 是否铺满安全区（整页用 true，卡片内用 false）
    var fullBleed: Bool = false

    var body: some View {
        ZStack {
            Ink.draft
            Canvas { ctx, size in
                var path = Path()
                var x: CGFloat = 0
                while x <= size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += grid
                }
                var y: CGFloat = 0
                while y <= size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += grid
                }
                ctx.stroke(path, with: .color(Ink.draftGrid), lineWidth: 0.5)
            }
            .allowsHitTesting(false)
        }
        .modifier(FullBleedIfNeeded(on: fullBleed))
    }
}

/// 只在需要时 `ignoresSafeArea()` —— 写成 modifier 避免在 `body` 里做条件分支
/// （`if` 包 modifier 会让类型检查变慢，且容易踩到 `some View` 的推断问题）。
private struct FullBleedIfNeeded: ViewModifier {
    let on: Bool
    init(on: Bool) { self.on = on }
    func body(content: Content) -> some View {
        if on {
            content.ignoresSafeArea()
        } else {
            content
        }
    }
}

/// 网点填充 —— 印刷的灰度靠网点堆，不靠透明度。
///
/// ⚠️ **只用于小面积**（空态插画、骨架块、装饰条）。铺满整屏会掉帧。
struct HalftoneView: View {
    var color: Color = Ink.ink
    /// 网点间距（6pt 为定稿值）
    var spacing: CGFloat = 6
    /// 圆点半径
    var dot: CGFloat = 1.1
    /// 整体不透明度
    var opacity: Double = 0.26
    /// 边缘渐隐（空态插画用；纯色块用 false）
    var fadesOut: Bool = false

    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            while y <= size.height {
                var x: CGFloat = 0
                while x <= size.width {
                    let rect = CGRect(x: x - dot, y: y - dot,
                                      width: dot * 2, height: dot * 2)
                    ctx.fill(Path(ellipseIn: rect),
                             with: .color(color.opacity(opacity)))
                    x += spacing
                }
                y += spacing
            }
        }
        .allowsHitTesting(false)
        .modifier(HalftoneFade(on: fadesOut))
    }
}

private struct HalftoneFade: ViewModifier {
    let on: Bool
    init(on: Bool) { self.on = on }
    func body(content: Content) -> some View {
        if on {
            content.mask(
                RadialGradient(colors: [.black, .black.opacity(0.85), .clear],
                               center: .center,
                               startRadius: 8,
                               endRadius: 130)
            )
        } else {
            content
        }
    }
}
