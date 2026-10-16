import Foundation
import UIKit
import JavaScriptCore

/// Android `Bitmap` / `BitmapFactory` / `Canvas` / `ByteArrayOutputStream` 的 iOS 替身。
///
/// 用途：部分图源（果果漫画、禁漫天堂等 9 个）的**图片被"条带乱序"处理过** ——
/// 服务端把图片按水平条带切分后**倒序**拼接。要还原，必须在字节层面解码图片、
/// 搬动条带、再重新编码。安卓靠 `android.graphics` 完成，iOS 没有等价 API，
/// 这里用 CoreGraphics 自己实现，并把同样的方法名挂到 JS 全局。
///
/// 真实规则形态（果果漫画，见 `probe/jm_rule.json`）：
/// ```js
/// var img  = BitmapFactory.decodeByteArray(result, 0, result.length);
/// var num  = (md5.substr(-1).charCodeAt(0) % 10 + 11) * 4;   // 条带数
/// var y    = Math.floor(img.getHeight() / num);              // 每条高度
/// var rem  = img.getHeight() % num;
/// var out  = Bitmap.createBitmap(img.getWidth(), img.getHeight(), Bitmap.Config.ARGB_8888);
/// var canvas = new Canvas(out);
/// for (var i = 1; i <= num; i++) {
///   var h = (i === num) ? rem : 0;
///   var strip = Bitmap.createBitmap(img, 0, y*(i-1), img.getWidth(), y+h);  // 源条带 i
///   canvas.drawBitmap(strip, 0, img.getHeight() - y*i - h, null);           // 画到倒序位置
/// }
/// var bos = new ByteArrayOutputStream();
/// out.compress(Bitmap.CompressFormat.PNG, 100, bos);
/// bos.toByteArray();
/// ```
/// 语义等价于「按 num 条等分（末条吃掉余数），整组**上下翻转**」。

// MARK: - Bitmap 句柄（JS 侧可见）

@objc protocol XBitmapExports: JSExport {
    func getWidth() -> Int
    func getHeight() -> Int
    func compress(_ format: String, _ quality: Int, _ stream: XByteArrayOutputStream)
}

final class XBitmap: NSObject, XBitmapExports {
    /// 内部图，可被 Canvas 替换（`createBitmap(w,h)` 出来的空白画布会不断被叠图）。
    /// `@nonobjc`：不要把 UIImage 暴露给 JS（既无必要，也会让 JSExport 桥变复杂）。
    @nonobjc var image: UIImage
    init(_ image: UIImage) { self.image = image }

    func getWidth() -> Int { Int((image.size.width * image.scale).rounded()) }
    func getHeight() -> Int { Int((image.size.height * image.scale).rounded()) }

    /// `compress(format, quality, stream)` —— 编码后写进 ByteArrayOutputStream
    func compress(_ format: String, _ quality: Int, _ stream: XByteArrayOutputStream) {
        let up = format.uppercased()
        let data: Data?
        if up.contains("JPEG") || up.contains("JPG") {
            data = image.jpegData(compressionQuality: CGFloat(max(0, min(100, quality))) / 100.0)
        } else {
            data = image.pngData()
        }
        stream.bytes = [UInt8](data ?? Data())
    }
}

/// `ByteArrayOutputStream` 替身 —— 只需要 `toByteArray()`。
@objc protocol XByteArrayOutputStreamExports: JSExport {
    func toByteArray() -> [Int]
    func byteCount() -> Int
    func writeBytes(_ b: [Int])
}

final class XByteArrayOutputStream: NSObject, XByteArrayOutputStreamExports {
    var bytes: [UInt8] = []
    func toByteArray() -> [Int] { bytes.map { Int($0) } }
    func byteCount() -> Int { bytes.count }
    func writeBytes(_ b: [Int]) { bytes.append(contentsOf: b.map { UInt8(truncatingIfNeeded: $0) }) }
}

// MARK: - Canvas

/// 极简 `Canvas`：只实现「往目标位图上叠一张子图」。
/// ⚠️ `JSExport` 协议里不要声明 `init` —— JavaScriptCore 对导出构造器的支持不稳，
///    改用 `XCanvasFactory.make(bmp)`（JS 侧由 prologue 包成 `new Canvas(bmp)`）。
@objc protocol XCanvasExports: JSExport {
    func drawBitmap(_ src: XBitmap, _ left: Int, _ top: Int, _ paint: JSValue?)
}

final class XCanvas: NSObject, XCanvasExports {
    private let target: XBitmap
    init(_ bmp: XBitmap) { target = bmp }

    /// `drawBitmap(src, left, top, paint)` —— 把 src 画到目标 (left, top)，左上为原点。
    func drawBitmap(_ src: XBitmap, _ left: Int, _ top: Int, _ paint: JSValue?) {
        guard let merged = XBitmapOps.blit(base: target.image, patch: src.image,
                                           x: CGFloat(left), y: CGFloat(top)) else { return }
        target.image = merged
    }
}

/// 构造 `Canvas` / `ByteArrayOutputStream` 的工厂（JS 侧 `new` 的替身）。
@objc protocol XCanvasFactoryExports: JSExport {
    func make(_ bmp: XBitmap) -> XCanvas
    func newBaos() -> XByteArrayOutputStream
}

final class XCanvasFactory: NSObject, XCanvasFactoryExports {
    func make(_ bmp: XBitmap) -> XCanvas { XCanvas(bmp) }
    func newBaos() -> XByteArrayOutputStream { XByteArrayOutputStream() }
}

// MARK: - BitmapFactory

@objc protocol XBitmapFactoryExports: JSExport {
    func decodeByteArray(_ bytes: [Int], _ offset: Int, _ length: Int) -> XBitmap?
}

final class XBitmapFactory: NSObject, XBitmapFactoryExports {
    /// `BitmapFactory.decodeByteArray(bytes, offset, length)` → XBitmap
    func decodeByteArray(_ bytes: [Int], _ offset: Int, _ length: Int) -> XBitmap? {
        var data = Data(bytes.map { UInt8(truncatingIfNeeded: $0) })
        if offset > 0, offset < data.count { data = data.subdata(in: offset..<data.count) }
        if length > 0, length < data.count { data = data.prefix(length) }
        guard let img = UIImage(data: data) else { return nil }
        return XBitmap(img)
    }
}

// MARK: - Bitmap 静态方法

/// JS 里 `Bitmap.createBitmap(w, h, cfg)` 与 `Bitmap.createBitmap(src, x, y, w, h)` 同名不同参，
/// JavaScriptCore 无法重载 —— 用一张「参数个数分发表」在 JS 侧适配（见 jsoupPrologue），
/// 这里只暴露两个不同名实现。
@objc protocol XBitmapStaticsExports: JSExport {
    func blank(_ width: Int, _ height: Int) -> XBitmap?
    func crop(_ src: XBitmap, _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> XBitmap?
}

final class XBitmapStatics: NSObject, XBitmapStaticsExports {
    /// `createBitmap(width, height, config)` → 全透明空白图
    func blank(_ width: Int, _ height: Int) -> XBitmap? {
        guard width > 0, height > 0 else { return nil }
        let size = CGSize(width: width, height: height)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        fmt.opaque = false
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIColor.clear.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return XBitmap(img)
    }

    /// `createBitmap(src, x, y, w, h)` → 裁剪
    func crop(_ src: XBitmap, _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> XBitmap? {
        guard w > 0, h > 0, let cg = src.image.cgImage else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let rect = CGRect(x: x, y: y, width: w, height: h).intersection(bounds)
        guard !rect.isEmpty, let cropped = cg.cropping(to: rect) else { return nil }
        return XBitmap(UIImage(cgImage: cropped, scale: 1, orientation: .up))
    }
}

// MARK: - CoreGraphics 合成

enum XBitmapOps {
    /// 把 `patch` 叠到 `base` 的 (x, y) 处，返回新图（不修改入参）。
    static func blit(base: UIImage, patch: UIImage, x: CGFloat, y: CGFloat) -> UIImage? {
        let size = base.size
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            base.draw(at: .zero)
            patch.draw(at: CGPoint(x: x, y: y))
        }
    }
}
