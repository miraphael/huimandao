import CoreImage
import Foundation
import UIKit

/// 图源二维码：分片协议 + 图片生成。
///
/// ## 为什么要分片
/// 一份「6 个图源」的 JSON 有 **17KB**，而一个二维码在 M 级纠错下实际只能装 1~2KB
/// （版本上限 40）。所以必须拆成多张码，扫码端按序号收集、拼回 —— Legado 也是这个做法。
///
/// ## 协议
/// ```
/// hmdqr|<当前序号>/<总片数>|<base64 分片>
/// ```
/// - 前缀 `hmdqr|` 用来区分「这是分片数据」还是「一个普通网址」。
///   老逻辑（相册识图导入）是「扫码内容 = URL → App 自己下载」，
///   所以非 `hmdqr|` 开头的内容继续按 URL 处理，保持兼容。
///
/// ## 分片大小
/// 700 字符 → M 纠错下二维码版本约 22，在手机屏幕上正常手持距离能稳定识别。
/// 调更大只会让码更密、反而扫不出来。
enum SourceQRCodec {

    static let prefix = "hmdqr|"
    static let chunkLength = 700

    struct Part {
        let index: Int      // 从 1 开始
        let total: Int
        let data: String    // base64 分片
    }

    /// 把图源 JSON 编码成 N 个二维码内容（至少 1 个）
    static func encode(json: String) -> [String] {
        let b64 = Data(json.utf8).base64EncodedString()
        guard !b64.isEmpty else { return [] }
        var parts: [String] = []
        var i = b64.startIndex
        while i < b64.endIndex {
            let j = b64.index(i, offsetBy: chunkLength, limitedBy: b64.endIndex) ?? b64.endIndex
            parts.append(String(b64[i..<j]))
            i = j
        }
        let total = parts.count
        return parts.enumerated().map { idx, s in String(format: "%@%d/%d|%@", prefix, idx + 1, total, s) }
    }

    /// 解析扫到的一段；不是分片协议（比如是个网址）返回 nil
    static func decode(_ scanned: String) -> Part? {
        let s = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix(prefix) else { return nil }
        let body = String(s.dropFirst(prefix.count))              // "1/3|base64…"
        let segs = body.split(separator: "|", maxSplits: 1).map(String.init)
        guard segs.count == 2 else { return nil }
        let head = segs[0].split(separator: "/", maxSplits: 1).map(String.init)
        guard head.count == 2, let idx = Int(head[0]), let total = Int(head[1]),
              idx >= 1, idx <= total, total >= 1 else { return nil }
        return Part(index: idx, total: total, data: segs[1])
    }

    /// 把收齐的分片拼回原始 JSON。**没收齐返回 nil**。
    static func assemble(_ parts: [Part]) -> String? {
        guard let first = parts.first else { return nil }
        let total = first.total
        guard parts.count == total, total >= 1 else { return nil }
        guard Set(parts.map(\.index)).count == total else { return nil }
        var b64 = ""
        for i in 1...total {
            guard let p = parts.first(where: { $0.index == i }) else { return nil }
            b64 += p.data
        }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 生成二维码图片。用系统 `CIQRCodeGenerator`，不引第三方库。
    ///
    /// - Parameter scale: 放大倍数。滤镜默认 1 像素/模块，直接放大会糊；
    ///   这里用整数倍放大，保证边缘是硬的（扫得动）。
    static func image(_ text: String, scale: CGFloat = 12) -> UIImage? {
        guard let data = text.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage else { return nil }
        let big = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return UIImage(ciImage: big)
    }
}
