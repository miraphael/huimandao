import Foundation
import Nuke
import UIKit

/// 全局图片管线 —— 借鉴 Aidoku（`AppDelegate.swift` 里 `ImagePipeline.shared = pipeline`）。
///
/// ── 为什么要换掉手写缓存 ─────────────────────────────────────────────
/// 我们自己写的 `ImageDiskCache` + `DecodedImageCache` + `AsyncGate` 三件套，
/// 在「并发去重 / 磁盘 LRU / 解码 / 取消传播 / 请求优先级」这些点上要处理的
/// 边界情况太多，实测仍然出现「图片划水经常转圈」「等几分钟不出来」。
///
/// Nuke 是 iOS 上最成熟的图片管线，Aidoku（8.5 万行 Swift、App Store 上架）
/// 用的就是它。核心能力正好覆盖我们的痛点：
///   · **请求去重**：同一个 URL 的并发请求自动合并成一个（我们手写的 `inflight` 就是这个）
///   · **双层缓存**：内存（按像素 cost 计费）+ 磁盘（按字节 LRU）
///   · **取消传播**：cell 回收时自动取消下载，不再浪费带宽
///   · **预取器**：`ImagePrefetcher` 按顺序预取后 N 页（对应我们的 `preloadAhead`）
///   · **渐进解码**：大图边下边解，首屏更快
///
/// ── 配置取值（对齐 Aidoku，做了注释说明）────────────────────────────
///   · 磁盘 500MB（`DataCache.sizeLimit`）—— 与 Aidoku 一致；漫画单章几十 MB，
///     500MB 能缓存十几到几十章，杀进程重开依然秒开
///   · 内存 100MB（`ImageCache.costLimit`）—— 与 Aidoku 一致，避免被系统 Jetsam
///   · `dataCachePolicy = .storeOriginalData` —— 存**原始字节**而不是解码结果。
///     这样磁盘缓存可跨 App 版本复用，也避免我们之前「密文/明文存错」的坑
///   · `isStoringPreviewsInMemoryCache = false` —— 渐进预览图不进内存缓存，
///     防止半成品图占满内存（Aidoku 同款设置）
///
/// ⚠️ 自定义请求头（Referer/UA）：不少图站校验 Referer，不带就 403。
///    Nuke 通过 `ImageRequest.userAgent` 与 `URLRequest` 级别的头来传，
///    见 `request(url:referer:ua:)`。
enum HMDImagePipeline {

    /// 管线实例（全局共享）。App 启动时调用一次 `setup()`。
    static let shared = ImagePipeline(delegate: nil) {
        // 磁盘缓存：500MB，按「原始字节」计
        let dataCache = try? DataCache(name: "com.wsw.cospa.imagecache")
        dataCache?.sizeLimit = 500 * 1024 * 1024
        $0.dataCache = dataCache

        // 内存缓存：100MB（按像素 cost 计费），系统内存吃紧时自动逐出
        let imageCache = Nuke.ImageCache()
        imageCache.costLimit = 100 * 1024 * 1024
        imageCache.countLimit = 120
        $0.imageCache = imageCache

        // 数据加载：独立的 URLSession，不启用 URLSession 自己的缓存（避免与 DataCache 双份）
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        $0.dataLoader = DataLoader(configuration: config)

        // 存原始数据（见类注释）：磁盘缓存跨版本可复用，也便于我们排查「存进去的是什么」
        $0.dataCachePolicy = .storeOriginalData
        // 渐进预览不进内存缓存，防止半成品图占内存
        $0.isStoringPreviewsInMemoryCache = false
    }

    /// 预取器（对应我们的 `preloadAhead`）。
    /// Aidoku 用的是 `ImagePrefetcher(pipeline:destination:)`；
    /// 这里也把目标设为磁盘缓存 —— 预取的目的是「后续显示时命中缓存」，
    /// 不需要占用内存（内存由显示时的 `loadImage` 自己填）。
    static let prefetcher = ImagePrefetcher(pipeline: shared, destination: .diskCache)

    /// App 启动时调用，把 Nuke 的全局管线替换成上面的配置。
    ///
    /// ⚠️ 必须在**任何**图片加载之前调用（否则默认管线已建立，
    /// 后面再换会导致已建立的缓存被丢弃）。
    static func setup() {
        // ⚠️ Aidoku 同款做法：把 Nuke 默认 DataLoader 的 URLSession 磁盘缓存关掉。
        //
        // Nuke 的 `DataLoader` 内部有一个共享的 `URLSession`（`sharedUrlCache`）。
        // 若不关，同一张图会被缓存**两份**：URLSession 的 HTTP 缓存 + 我们的
        // `DataCache`。结果是磁盘占用翻倍，而且两份缓存的过期策略不一致，
        // 出现「明明缓存里有却还是转圈」。
        // 设 `diskCapacity = 0` 后，磁盘缓存完全由 `DataCache` 统一管理。
        DataLoader.sharedUrlCache.diskCapacity = 0
        ImagePipeline.shared = shared
    }

    /// 构造带自定义头的图片请求。
    ///
    /// - Parameters:
    ///   - url: 图片地址（支持 `http(s)` 与 `file`）
    ///   - referer: 图站要求的 Referer（很多站不带就 403）
    ///   - ua: 自定义 User-Agent（个别站按 UA 返回不同清晰度）
    ///   - headers: 规则尾部 `@Header:{...}` 带来的额外头（优先级最高）
    ///
    /// ⚠️ 这些头必须加在 **URLRequest** 上而不是 `ImageRequest` 的属性上：
    ///    Nuke 只透传 `URLRequest` 的自定义头；`ImageRequest.userAgent` 是给
    ///    URLSession 层用的，部分站的 Referer 校验只看 URLRequest。
    static func request(url: String, referer: String = "", ua: String = "",
                        headers: [String: String] = [:]) -> ImageRequest? {
        guard var comp = URLComponents(string: url), comp.scheme != nil else { return nil }
        // 把中文/空格等转义，避免 URL(string:) 返回 nil
        comp.percentEncodedQuery = comp.percentEncodedQuery?
            .replacingOccurrences(of: " ", with: "%20")
        guard let u = comp.url else { return nil }

        var req = URLRequest(url: u)
        if !referer.isEmpty { req.setValue(referer, forHTTPHeaderField: "Referer") }
        if !ua.isEmpty { req.setValue(ua, forHTTPHeaderField: "User-Agent") }
        // 规则头优先级最高（可覆盖上面的默认值）
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        // ── 反反爬：图片请求也必须带 Cookie / 过挑战后的 UA ──────────────────
        // ⚠️ 这是「页面能打开、图片全是 403」的常见原因：`cf_clearance` 是
        //    **域级** Cookie，同域的图片 CDN 不带它一样被拦。
        //    过挑战时 `AntiBot.solve` 已把 Cookie 与 WebView 的 UA 写进
        //    `CookieStore`，这里统一注入。
        //    ⚠️ 故意**不**把 Cookie 计入 `imageID` 缓存键：cf_clearance 每几小时
        //       轮换一次，计进去会让整份图片缓存周期性失效（缓存抖动）。
        //       失败的请求本来就不会进缓存，所以没有「缓存了 403 结果」的风险。
        let host = u.host ?? ""
        if req.value(forHTTPHeaderField: "Cookie") == nil {
            let ck = CookieStore.header(host: host)
            if !ck.isEmpty { req.setValue(ck, forHTTPHeaderField: "Cookie") }
        }
        if req.value(forHTTPHeaderField: "User-Agent") == nil, let cu = CookieStore.ua(host: host) {
            req.setValue(cu, forHTTPHeaderField: "User-Agent")
        }

        var imageReq = ImageRequest(urlRequest: req)
        // ⚠️ `ImageRequest` **没有** `userAgent` 属性（写过会报
        //    "value of type 'ImageRequest' has no member 'userAgent'"）。
        //    UA 已经通过上面的 `URLRequest.setValue(_:forHTTPHeaderField:)` 设进去了 —— 
        //    Nuke 只透传 URLRequest 上的自定义头，这也是 Aidoku 的做法。
        //
        // 缓存 key 必须包含「会改变响应内容」的头，否则 A 站图会被当成 B 站的命中。
        // ⚠️ Nuke 13.x **没有** `cacheKey` 属性；覆盖缓存标识的正确 API 是
        //    `imageID`（`public var imageID: String?`，默认取绝对 URL 字符串）。
        //    已拉 13.2.0 的 `Sources/Nuke/ImageRequest.swift` 核实：
        //      · 第 101 行 `public var imageID: String?`
        //      · 第 355-360 行 `struct UserInfoKey: Hashable, ExpressibleByStringLiteral`
        //        + `public init(_ rawValue: String)` —— **无参数标签**，
        //        写 `.init(rawValue:)` 会报 "extraneous argument label 'rawValue:'"
        if !referer.isEmpty || !ua.isEmpty {
            // 把非空的头按固定顺序拼成 key 后缀，保证同图不同头 = 不同缓存条目
            var parts: [String] = []
            if !referer.isEmpty { parts.append("r=\(referer)") }
            if !ua.isEmpty { parts.append("u=\(ua)") }
            let suffix = parts.joined(separator: "&")
            imageReq.imageID = "\(u.absoluteString)#\(suffix)"
            // 同时记进 userInfo，便于调试/排查时看出这张图是按哪组头缓存的
            imageReq.userInfo[ImageRequest.UserInfoKey("hmdHeaders")] = suffix
        }
        // 优先级：默认 normal；阅读器当前页会调高（见 ReaderView）
        imageReq.priority = .normal
        return imageReq
    }
}
