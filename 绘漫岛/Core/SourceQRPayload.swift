import CoreImage
import Foundation
import UIKit

/// 图源二维码：**始终只有一张**。
///
/// ## 容量上限是硬约束
/// 一个二维码（版本 40）能装多少，取决于编码模式：
/// ```
/// byte 模式（base64）        2953 字节
/// 字母数字模式（base45）     4296 字符   ← 多 45%
/// ```
/// 6 个源（含「发现栏目」）实测：
/// ```
/// base64（byte 模式）  3536 字符  ❌ 超 2953
/// base45（字母数字）   3976 字符  ✅ ≤ 4296
/// ```
/// 🔴 **旧版为了塞进一张，直接丢掉了「发现栏目」** —— 用户导出再导入后
///    `ruleFindUrl` 全空，漫画台显示「N 个图源都没有配置发现栏目」。
///    发现栏目是漫画台唯一的入口，不能为了「一张码」牺牲它。
///
/// 所以现在：**优先用 base45**（进字母数字模式，容量大 45%），把全部字段塞进一张。
/// 只有在「base45 也画不出码」时（说明系统编码器走了 byte 模式），才退回 base64，
/// 并**优先减少源数量**而不是丢发现栏目。
///
/// ## 协议
/// ```
/// hmdqr|3|<base45(LZMA(JSON 数组))>     ← 字母数字模式（新，容量最大）
/// hmdqr|2|<base64(LZMA(JSON 数组))>     ← byte 模式（兼容旧码）
/// ```
/// 数组 = `[[值…], …]`，每行按 `fields` 的固定顺序取值，空值用 `null`。
enum SourceQRCodec {

    static let prefix = "hmdqr|"
    static let version45 = "3"
    static let version64 = "2"

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

    /// byte 模式（base64）的安全容量。理论极限 2953，留余量。
    static let maxChars = 2900
    /// 字母数字模式（base45）的安全容量。理论极限 4296，留余量。
    static let maxCharsAlnum = 4200

    struct Result {
        var payload: String
        var included: Int
        var total: Int
        var dropped: [String]
        var chars: Int
    }

    // MARK: - 编码

    /// 把图源 JSON 编码成**一张**二维码的内容。
    ///
    /// 优先级（越靠前越完整）：
    /// 1. base45 + 全字段
    /// 2. base45 + 去备注
    /// 3. base45 + 去备注/UA
    /// 4. base64 + 去备注/UA + **减少源数量**（发现栏目绝不丢）
    static func encode(json: String) -> Result? {
        guard let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              !arr.isEmpty else { return nil }

        // ① base45：字母数字模式，容量 4296 —— 优先保住全部字段
        let alnumTiers: [(drop: Set<String>, note: [String])] = [
            ([], []),
            (["sourceRemark"], ["源备注"]),
            (["sourceRemark", "httpUserAgent"], ["源备注", "自定义 UA"]),
        ]
        for tier in alnumTiers {
            guard let p = build45(pack(arr, drop: tier.drop)),
                  p.count <= maxCharsAlnum,
                  image(p, quiet: true) != nil else { continue }
            return Result(payload: p, included: arr.count, total: arr.count,
                          dropped: tier.note, chars: p.count)
        }

        // ② 退回 base64（byte 模式）—— 宁可少带源，也不丢发现栏目
        let drop: Set<String> = ["sourceRemark", "httpUserAgent"]
        var n = arr.count
        while n >= 1 {
            let sub = Array(arr.prefix(n))
            if let p = build64(pack(sub, drop: drop)), p.count <= maxChars,
               image(p, quiet: true) != nil {
                var note = ["源备注", "自定义 UA"]
                if n < arr.count {
                    note.append("仅含前 \(n) 个源（其余超出单张码容量）")
                }
                return Result(payload: p, included: n, total: arr.count,
                              dropped: note, chars: p.count)
            }
            n -= 1
        }
        return nil
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

    private static func compress(_ packed: [[Any]]) -> Data? {
        guard let json = try? JSONSerialization.data(withJSONObject: packed) else { return nil }
        guard let zip = try? (json as NSData).compressed(using: .lzma) else { return nil }
        return zip as Data
    }

    /// base64（byte 模式）
    private static func build64(_ packed: [[Any]]) -> String? {
        guard let zip = compress(packed) else { return nil }
        return "\(prefix)\(version64)|\(zip.base64EncodedString())"
    }

    /// base45（字母数字模式）
    ///
    /// ⚠️ base45 的字母表里**空格是有效字符**，而扫码链路/复制粘贴常会
    ///    `trimmingCharacters(in: .whitespaces)` 把末尾空格吃掉 → 整段解码失败。
    ///    所以在末尾追加一个非空格标记 `0`（也在字母数字集内，不破坏模式），
    ///    解码时固定去掉最后一个字符。
    private static let b45Tail: Character = "0"

    private static func build45(_ packed: [[Any]]) -> String? {
        guard let zip = compress(packed) else { return nil }
        return "\(prefix)\(version45)|\(base45Encode(zip))\(b45Tail)"
    }

    // MARK: - base45（RFC 9285）

    private static let b45 = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:")
    private static let b45Index: [Character: Int] = {
        var m: [Character: Int] = [:]
        for (i, c) in b45.enumerated() { m[c] = i }
        return m
    }()

    static func base45Encode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        var out = ""
        out.reserveCapacity(bytes.count * 3 / 2 + 2)
        var i = 0
        while i + 1 < bytes.count {
            let v = Int(bytes[i]) * 256 + Int(bytes[i + 1])
            out.append(b45[v % 45])
            out.append(b45[(v / 45) % 45])
            out.append(b45[v / 2025])
            i += 2
        }
        if i < bytes.count {
            let v = Int(bytes[i])
            out.append(b45[v % 45])
            out.append(b45[v / 45])
        }
        return out
    }

    static func base45Decode(_ s: String) -> Data? {
        let chars = Array(s)
        var out = [UInt8]()
        out.reserveCapacity(chars.count * 2 / 3 + 1)
        var i = 0
        while i + 2 < chars.count {
            guard let c0 = b45Index[chars[i]], let c1 = b45Index[chars[i + 1]],
                  let c2 = b45Index[chars[i + 2]] else { return nil }
            let v = c0 + c1 * 45 + c2 * 2025
            guard v <= 0xFFFF else { return nil }
            out.append(UInt8(v >> 8))
            out.append(UInt8(v & 0xFF))
            i += 3
        }
        if i < chars.count {
            guard i + 1 < chars.count,
                  let c0 = b45Index[chars[i]], let c1 = b45Index[chars[i + 1]] else { return nil }
            let v = c0 + c1 * 45
            guard v <= 0xFF else { return nil }
            out.append(UInt8(v))
        }
        return Data(out)
    }

    // MARK: - 解码

    /// 是不是本 App 生成的图源码（用来和「网址码」区分）
    static func isSourceCode(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .newlines)
        return t.hasPrefix("\(prefix)\(version45)|") || t.hasPrefix("\(prefix)\(version64)|")
    }

    /// 解出图源 JSON；不是本格式返回 nil
    static func decode(_ scanned: String) -> String? {
        // ⚠️ 只去换行，**不能去空格** —— base45 的字母表里「空格」是有效字符，
        //    去空格会吃掉末尾一个字符导致整段解码失败。
        let t = scanned.trimmingCharacters(in: .newlines)

        let zip: Data
        if t.hasPrefix("\(prefix)\(version45)|") {
            var body = String(t.dropFirst("\(prefix)\(version45)|".count))
            // 去掉 build45 追加的末尾标记（见 b45Tail 说明）
            if body.last == b45Tail { body.removeLast() }
            guard let d = base45Decode(body) else { return nil }
            zip = d
        } else if t.hasPrefix("\(prefix)\(version64)|") {
            let body = String(t.dropFirst("\(prefix)\(version64)|".count))
            guard let d = Data(base64Encoded: body) else { return nil }
            zip = d
        } else {
            return nil
        }

        guard let raw = try? (zip as NSData).decompressed(using: .lzma),
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
    /// - Parameter quiet: 生成失败时是否写日志（探测容量时会反复试，不要刷屏）。
    static func image(_ text: String, correction: String = "L", scale: CGFloat = 10,
                      quiet: Bool = false) -> UIImage? {
        guard let data = text.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else {
            if !quiet { DiagLog.event("qr", "image", "❌ 拿不到 CIQRCodeGenerator") }
            return nil
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue(correction, forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage else {
            // 数据超过该纠错等级容量时，outputImage 会是 nil
            if !quiet { DiagLog.event("qr", "image", "❌ outputImage 为 nil（\(data.count) 字节，可能超容量）") }
            return nil
        }
        let big = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // 🔴 **必须转成 CGImage**。
        //    `UIImage(ciImage:)` 是「懒」的 CIImage 包装，**没有 CGImage 备份** ——
        //    放在 SwiftUI 的 `Image(uiImage:)` 里渲染出来是**空白**（v124 用户反馈「二维码不显示」）。
        //    UIKit 的 UIImageView 能显示，SwiftUI 不行，所以必须过一次 CIContext。
        let ctx = CIContext(options: nil)
        guard let cg = ctx.createCGImage(big, from: big.extent) else {
            if !quiet { DiagLog.event("qr", "image", "❌ CIContext 转 CGImage 失败") }
            return nil
        }
        return UIImage(cgImage: cg)
    }
}
