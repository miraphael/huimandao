import CoreImage
import Foundation
import UIKit

/// 图源二维码：**永远只有一张**。
///
/// ## 容量上限是硬约束
/// 一个二维码（L 级纠错、版本 40）最多装 **2953 字节**。为了让「无论多少图源都只有一张码」
/// 尽可能成立，这里叠了三层压缩：
///
/// 1. **短键名打包**：33 个字段压成「按固定顺序的数组」，省掉每个源的键名（约 16%）
/// 2. **LZMA**：比 zlib 再小 8%~10%（图源 JSON 字段高度重复）
/// 3. **base64**：二维码只能装文本，base64 有 33% 膨胀 —— 这就是最后的天花板
///
/// 实测（6 个源，15765 B）：
/// ```
/// 原样                      6165 字符  ❌
/// 去备注                    3555 字符  ❌
/// 去备注 + 发现栏目          2944 字符  ✅ 刚好
/// 再去 UA                   2731 字符  ✅
/// ```
/// 所以按「备注 → 发现栏目 → UA」逐级丢弃，尽量塞进一张；仍装不下就只导前 N 个源，
/// 并在导出页把「丢了什么、少了几个」写清楚 —— **不静默丢数据**。
///
/// ## 协议
/// ```
/// hmdqr|2|<base64(LZMA(JSON 数组))>
/// ```
/// 数组 = `[[值…], …]`，每行按 `fields` 的固定顺序取值，空值用 `null`。
enum SourceQRCodec {

    static let prefix = "hmdqr|"
    static let version = "2"

    /// 打包顺序 —— **编码和解码必须完全一致**，改动就要升 version。
    static let fields: [String] = [
        "bookSourceGroup", "bookSourceName", "bookSourceType", "bookSourceUrl",
        "enable", "header", "httpUserAgent", "lastUpdateTime", "loginUrl",
        "ruleBookAuthor", "ruleBookContent", "ruleBookKind", "ruleBookName",
        "ruleChapterApi", "ruleChapterApiList", "ruleChapterApiUrl",
        "ruleChapterList", "ruleChapterName", "ruleContentFlow",
        "ruleContentUrl", "ruleContentUrlNext", "ruleCoverUrl",
        "ruleFindUrl", "ruleIntroduce",
        "ruleSearchAuthor", "ruleSearchCoverUrl", "ruleSearchList", "ruleSearchName",
        "ruleSearchNoteUrl", "ruleSearchUrl",
        "serialNumber", "sourceRemark", "weight",
    ]

    /// 单张二维码的安全容量。
    ///
    /// 理论极限是 **2953 字符**（L 级、版本 40）。这里取 2800，留 5% 余量 ——
    /// 因为 Apple 的 LZMA 与 Python 实测有 ±100 字节差异，卡在 2900 有「超限后
    /// CIQRCodeGenerator 直接返回 nil（生成不出码）」的风险。
    static let maxChars = 2800

    struct Result {
        var payload: String
        var included: Int
        var total: Int
        var dropped: [String]
        var chars: Int
    }

    // MARK: - 编码

    /// 把图源 JSON 编码成**一张**二维码的内容。
    static func encode(json: String) -> Result? {
        guard let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              !arr.isEmpty else { return nil }

        // 逐级降级：备注 → 发现栏目 → UA
        let tiers: [(drop: [String], note: [String])] = [
            (["sourceRemark"], ["源备注"]),
            (["sourceRemark", "ruleFindUrl"], ["源备注", "发现栏目"]),
            (["sourceRemark", "ruleFindUrl", "httpUserAgent"], ["源备注", "发现栏目", "自定义 UA"]),
        ]

        for (drop, note) in tiers {
            let packed = pack(arr, drop: Set(drop))
            if let payload = build(packed), payload.count <= maxChars {
                return Result(payload: payload, included: arr.count, total: arr.count,
                              dropped: note, chars: payload.count)
            }
        }

        // 还是装不下 → 二分找能装下的最大源数
        let drop = Set(["sourceRemark", "ruleFindUrl", "httpUserAgent"])
        var lo = 1, hi = arr.count, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if let p = build(pack(Array(arr.prefix(mid)), drop: drop)), p.count <= maxChars {
                best = mid; lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        guard best > 0,
              let payload = build(pack(Array(arr.prefix(best)), drop: drop)) else { return nil }
        return Result(payload: payload, included: best, total: arr.count,
                      dropped: ["源备注", "发现栏目", "自定义 UA",
                                "仅含前 \(best) 个源（其余超出单张码容量）"],
                      chars: payload.count)
    }

    /// 打包成「数组的数组」：键名全省掉
    private static func pack(_ list: [[String: Any]], drop: Set<String>) -> [[Any]] {
        list.map { src in
            fields.map { key -> Any in
                if drop.contains(key) { return NSNull() }
                guard let v = src[key] else { return NSNull() }
                if v is NSNull { return NSNull() }
                if let s = v as? String, s.isEmpty { return NSNull() }
                return v
            }
        }
    }

    /// 压缩 + 加前缀
    private static func build(_ packed: [[Any]]) -> String? {
        guard let json = try? JSONSerialization.data(withJSONObject: packed),
              let zip = try? (json as NSData).compressed(using: .lzma) else { return nil }
        return "\(prefix)\(version)|\((zip as Data).base64EncodedString())"
    }

    // MARK: - 解码

    /// 是不是本 App 生成的图源码（用来和「网址码」区分）
    static func isSourceCode(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("\(prefix)\(version)|")
    }

    /// 解出图源 JSON；不是本格式返回 nil
    static func decode(_ scanned: String) -> String? {
        let t = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("\(prefix)\(version)|") else { return nil }
        let body = String(t.dropFirst("\(prefix)\(version)|".count))
        guard let zip = Data(base64Encoded: body),
              let raw = try? (zip as NSData).decompressed(using: .lzma),
              let arr = (try? JSONSerialization.jsonObject(with: raw as Data)) as? [[Any]]
        else { return nil }

        var out: [[String: Any]] = []
        for row in arr {
            var dict: [String: Any] = [:]
            for (i, key) in fields.enumerated() where i < row.count {
                let v = row[i]
                if v is NSNull { continue }
                dict[key] = v
            }
            out.append(dict)
        }
        guard let json = try? JSONSerialization.data(withJSONObject: out),
              let text = String(data: json, encoding: .utf8) else { return nil }
        return text
    }

    // MARK: - 图片

    /// 生成二维码图片。用系统 `CIQRCodeGenerator`，不引第三方库。
    ///
    /// - Parameter correction: `"L"` 容量最大（单张码必须用它）；`"M"` 更耐脏但容量小 10%。
    static func image(_ text: String, correction: String = "L", scale: CGFloat = 10) -> UIImage? {
        guard let data = text.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else {
            DiagLog.event("qr", "image", "❌ 拿不到 CIQRCodeGenerator")
            return nil
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue(correction, forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage else {
            // 数据超过该纠错等级容量时，outputImage 会是 nil
            DiagLog.event("qr", "image", "❌ outputImage 为 nil（\(data.count) 字节，可能超容量）")
            return nil
        }
        let big = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // 🔴 **必须转成 CGImage**。
        //    `UIImage(ciImage:)` 是「懒」的 CIImage 包装，**没有 CGImage 备份** ——
        //    放在 SwiftUI 的 `Image(uiImage:)` 里渲染出来是**空白**（v124 用户反馈「二维码不显示」）。
        //    UIKit 的 UIImageView 能显示，SwiftUI 不行，所以必须过一次 CIContext。
        let ctx = CIContext(options: nil)
        guard let cg = ctx.createCGImage(big, from: big.extent) else {
            DiagLog.event("qr", "image", "❌ CIContext 转 CGImage 失败")
            return nil
        }
        return UIImage(cgImage: cg)
    }
}
