import CoreImage
import Foundation
import UIKit

/// 图源二维码：压缩 + 分片协议 + 图片生成。
///
/// ## 容量账（实测，决定分片大小）
/// 图库漫画单个源 JSON 3336 字节 → zlib 压缩 **1437**（43%）→ base64 **1916** 字符。
/// 六源合集 17496 → 5342 → base64 7124。
/// 一个二维码 L 级纠错能装约 **2200 字符**，所以：
///   · 选 1 个源 → **正好 1 张码**
///   · 六源合集 → 4 张
///
/// ## 协议
/// ```
/// hmdqr|<压缩标记>|<当前序号>/<总片数>|<base64 分片>
/// ```
/// - `<压缩标记>`：`z` = zlib 压缩过；`r` = 原文（压缩反而更大的极端情况）
/// - 前缀 `hmdqr|` 用来区分「分片数据」和「普通网址」；非前缀内容继续按 URL 处理，
///   老的相册识图逻辑不受影响。
enum SourceQRCodec {

    static let prefix = "hmdqr|"

    /// 每片最大字符数。2200 ≈ 一个二维码 L 纠错下的容量上限，
    /// 选它是为了让「1 个源只出 1 张码」。代价是码偏密——扫不上就换 `chunkLengthM`。
    static let chunkLength = 2200

    /// 兜底：码太密扫不上时用这个（每片更短 → 码更稀 → 张数更多）
    static let chunkLengthM = 1200

    struct Part {
        let index: Int      // 从 1 开始
        let total: Int
        let packed: Bool    // true = zlib
        let data: String    // base64 分片
    }

    // MARK: - 编码

    /// 把图源 JSON 编码成 N 个二维码内容（至少 1 个）
    static func encode(json: String, chunk: Int = chunkLength) -> [String] {
        let raw = Data(json.utf8)
        guard !raw.isEmpty else { return [] }
        // 压一压：图源 JSON 字段名高度重复，实测压缩率 40%~70%。
        // 🔴 `NSData.compressed` 返回 **NSData**，`try?` 之后是 `NSData?`，
        //    不能和 `Data()` 一起 `??`（编译报 binary operator '??' cannot be applied）。
        //    必须先桥接 `as Data`。
        var zipped = Data()
        if let n = try? (raw as NSData).compressed(using: .zlib) { zipped = n as Data }
        let useZip = zipped.count > 0 && zipped.count < raw.count
        let b64 = (useZip ? zipped : raw).base64EncodedString()
        guard !b64.isEmpty else { return [] }

        var parts: [String] = []
        var i = b64.startIndex
        while i < b64.endIndex {
            let j = b64.index(i, offsetBy: chunk, limitedBy: b64.endIndex) ?? b64.endIndex
            parts.append(String(b64[i..<j]))
            i = j
        }
        let total = parts.count
        let flag = useZip ? "z" : "r"
        return parts.enumerated().map { idx, s in
            String(format: "%@%@|%d/%d|%@", prefix, flag, idx + 1, total, s)
        }
    }

    // MARK: - 解码

    /// 解析扫到的一段；不是分片协议（比如是个网址）返回 nil
    static func decode(_ scanned: String) -> Part? {
        let s = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix(prefix) else { return nil }
        let rest = String(s.dropFirst(prefix.count))            // "z|1/4|base64…"
        let segs = rest.split(separator: "|", maxSplits: 2).map(String.init)
        guard segs.count == 3 else { return nil }
        let flag = segs[0]
        let head = segs[1].split(separator: "/", maxSplits: 1).map(String.init)
        guard head.count == 2, let idx = Int(head[0]), let total = Int(head[1]),
              idx >= 1, idx <= total, total >= 1 else { return nil }
        return Part(index: idx, total: total, packed: flag == "z", data: segs[2])
    }

    /// 把收齐的分片拼回原始 JSON。**没收齐 / 解压失败都返回 nil**。
    static func assemble(_ parts: [Part]) -> String? {
        guard let first = parts.first else { return nil }
        let total = first.total
        guard total >= 1, parts.count == total else { return nil }
        guard Set(parts.map(\.index)).count == total else { return nil }
        var b64 = ""
        for i in 1...total {
            guard let p = parts.first(where: { $0.index == i }) else { return nil }
            b64 += p.data
        }
        guard let data = Data(base64Encoded: b64) else { return nil }
        if first.packed {
            // 同样：`NSData.decompressed` 返回 NSData，先桥接再解字符串
            guard let n = try? (data as NSData).decompressed(using: .zlib) else { return nil }
            let un = n as Data
            return String(data: un, encoding: .utf8)
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 图片

    /// 生成二维码图片。用系统 `CIQRCodeGenerator`，不引第三方库。
    ///
    /// - Parameter correction: `"L"` 容量大、容错低（适合屏幕上这种干净场景）；
    ///   `"M"` 更耐脏但容量小 ~10%。扫码困难时改用 `"M"`（更稀）。
    /// - Parameter scale: 整数倍放大。滤镜默认 1 像素/模块，直接放大会糊。
    static func image(_ text: String, correction: String = "L", scale: CGFloat = 12) -> UIImage? {
        guard let data = text.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue(correction, forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage else { return nil }
        let big = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return UIImage(ciImage: big)
    }
}
