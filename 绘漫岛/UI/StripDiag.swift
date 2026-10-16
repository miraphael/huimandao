import CoreGraphics
import Foundation

/// ── 诊断操作 ────────────────────────────────────────────────────────────────
///
/// 外部（阅读器设置面板 / 自动化脚本）驱动缩放容器执行的**最小动作集**。
/// 刻意做得极窄：只包含复现「缩放后黑屏 / 跳页」所必需的三件事。
enum StripDiagOp {
    /// 直接设置 `zoomScale`（**绕过 `setZoomScale` 的 clamp**）。
    ///
    /// ⚠️ 为什么不用 `setZoomScale(_:animated:)`：它会把值 clamp 到
    ///    `[minimumZoomScale, maximumZoomScale]`，而 `minimumZoomScale = 1`
    ///    → **永远设不出 `< 1` 的值**。但「缩到 < 1 的弹性回弹」正是黑屏跳页的
    ///    触发条件（`bouncesZoom = true` 时用户往下捏就会短暂进入这个区间）。
    ///    直接给 `zoomScale` 赋值不经过 clamp，所以能精确复现该状态。
    case setZoom(CGFloat)
    /// 在当前偏移基础上滚动 `dy`（**内容坐标**，会自动乘 `zoomScale`）
    case scrollBy(CGFloat)
    /// 记录一次状态快照到 `log`
    case snapshot(String)
}

/// ── 诊断桥 ──────────────────────────────────────────────────────────────────
///
/// ## 为什么需要它
/// 本机拿不到 iOS 的 UI 控制通道：免 root 的 RSD 隧道要 **iOS 17.4+**，
/// 而目标设备是 **iOS 17.2.1** —— 这条路对这台设备根本不存在（见项目记忆）。
/// 于是「缩放后黑屏」这类问题此前只能靠**用户手动操作 + 录屏**：
/// 慢、每轮要人配合、而且无法精确复现同一串操作。
///
/// 有了这个桥，App 能**自己**跑一串操作（跳页 → 滚动 → 缩小 → 还原），
/// 每一步记录 `contentOffset / zoomScale / 渲染窗口 / 可见页`，
/// 结果落盘到 `Documents/diag_result.txt`，再用
/// `pymobiledevice3 apps pull <bundle> Documents/diag_result.txt .` 取回即可。
/// 于是「复现 → 取证」全自动，人只需点一次按钮。
///
/// ## 为什么不做 `ObservableObject`
/// 它是被 `Coordinator` **轮询消费**的，不是 SwiftUI 的渲染输入 ——
/// 发 `objectWillChange` 只会白白触发一次重绘。外部靠「递增 tick」
/// （见 `ReaderView.diagTick`）来驱动一次 `updateUIView`，从而让 Coordinator 消费。
final class StripDiagBridge {
    /// 待执行的操作（外部追加，Coordinator 按顺序逐个消费）
    var pending: [StripDiagOp] = []
    /// 执行日志（Coordinator 追加；每行带时间戳）
    var log: [String] = []
    /// 由 Coordinator 注入的「当前状态快照器」——
    /// 让外部不必了解 Coordinator 的内部结构就能取到 offset / zoom / 窗口。
    var snapshotProvider: (() -> String)?
    /// Coordinator 是否正在执行（避免同一批操作被消费两次）
    var busy = false

    /// 清空待执行与日志（每轮诊断开始前调用）
    func reset() {
        pending.removeAll()
        log.removeAll()
        busy = false
    }

    /// 追加一行日志（自动加时间戳）
    func record(_ line: String) {
        let t = String(format: "%.3f", Date().timeIntervalSince1970)
        log.append("[\(t)] \(line)")
    }

    /// 把日志落到 App 的 Documents 目录
    @discardableResult
    func flushToDisk(name: String = "diag_result.txt") -> String {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent(name)
        let text = log.joined(separator: "\n") + "\n"
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return "已写入 \(name)（\(log.count) 行）"
        } catch {
            return "写入 \(name) 失败: \(error.localizedDescription)"
        }
    }
}
