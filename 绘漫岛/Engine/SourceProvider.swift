import Foundation

/// ──────────────────────────────────────────────────────────────────────────
/// 图源「提供者」抽象（ARCHITECTURE §9.1）
///
/// 目的：把**JSON 规则源**与**JS 类源**分别适配到同一组能力接口，让上层
/// （搜索 / 详情 / 章节 / 正文 / 分页）不再关心源是哪一种实现。
///
/// ⚠️ 边界（必须遵守）：
///   ① **不把 JS 类源代码拼成伪 JSON 规则**，也不改坏现有导入路径；
///   ② 本文件只定义**协议与能力**，具体实现由各自的 Provider 承担；
///   ③ 现有 `ComicEngine` 的调用点**保持原样**，适配通过新增 Provider 完成。
///
/// 能力最小集：metadata / search / detail / chapters / images / next / headers。
/// 下载、登录、收藏等属于 optional capability，后续再补。
/// ---------------------------------------------------------------------------

/// 图源实现类型 —— 用于「显式判定走哪条通道」，不做启发式猜测。
enum SourceKind: String, Codable, CaseIterable {
    /// 内置 JSON 规则源（Legado / 绘漫岛兼容格式）
    case jsonRule
    /// JS 类源（独立运行时 + 白名单桥）
    case javaScript
    /// 依赖真实 DOM 渲染的源（WKWebView 兜底通道）
    case webView
}

/// 提供者能力声明。
///
/// ⚠️ 这是「**声明**」而非「实测结果」—— 实测健康度见 `SourceCaps` / `SourceCheckResult`，
///    两者不能混（ARCHITECTURE §3.3 / §7.5）。
struct ProviderCapabilities: OptionSet {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let metadata = ProviderCapabilities(rawValue: 1 << 0)
    static let search   = ProviderCapabilities(rawValue: 1 << 1)
    static let detail   = ProviderCapabilities(rawValue: 1 << 2)
    static let chapters = ProviderCapabilities(rawValue: 1 << 3)
    static let images   = ProviderCapabilities(rawValue: 1 << 4)
    /// 支持「下一页」发现（源规则 next / HTML next 链接 / 页码占位符）
    static let nextPage = ProviderCapabilities(rawValue: 1 << 5)
    /// 支持自定义请求头（Referer / Cookie / UA）
    static let headers  = ProviderCapabilities(rawValue: 1 << 6)

    /// 最小可用集合（能完成「搜索 → 详情 → 章节 → 图片」全链路）
    static let core: ProviderCapabilities = [.metadata, .search, .detail, .chapters, .images]
}

/// 提供者错误 —— 必须能映射到可读的阶段诊断，而不是一句「失败了」。
///
/// ⚠️ 不要往 message 里塞 Cookie / Authorization / 带签名的完整 URL（§9.1 安全约束）。
enum SourceProviderError: Error, CustomStringConvertible {
    /// 该提供者不具备此能力
    case unsupportedCapability(String)
    /// 源脚本/规则本身有问题（语法、manifest 缺字段）
    case invalidSource(String)
    /// 网络层失败（可重试）
    case network(String)
    /// 解析阶段失败（页面结构变了 / 规则过时）
    case parse(String)
    /// 运行超时或用户取消
    case cancelled(String)
    /// 安全边界拦截（试图访问白名单外的能力）
    case blocked(String)

    var description: String {
        switch self {
        case .unsupportedCapability(let m): return "不支持的能力：\(m)"
        case .invalidSource(let m):         return "源定义无效：\(m)"
        case .network(let m):               return "网络失败：\(m)"
        case .parse(let m):                 return "解析失败：\(m)"
        case .cancelled(let m):             return "已取消/超时：\(m)"
        case .blocked(let m):               return "被安全策略拦截：\(m)"
        }
    }

    /// 是否值得重试（网络类可重试；解析/定义类重试无意义）
    var isRetryable: Bool {
        if case .network = self { return true }
        return false
    }
}

/// 统一图源提供者协议。
///
/// ⚠️ 签名刻意与现有 `ComicEngine` 的公开方法保持一致（`noteUrl` / `origin` /
///    `extraHeaders`），这样 `JSONRuleProvider` 可以**纯转发**、零行为变更。
///    后续接入 JS 类源时再按需扩展 optional 能力，不改已有调用点。
protocol SourceProvider: AnyObject {
    /// 源唯一标识（沿用源 URL，与现有缓存 key / 游标 key 一致）
    var sourceId: String { get }
    /// 实现类型
    var kind: SourceKind { get }
    /// 能力声明
    var capabilities: ProviderCapabilities { get }

    /// 搜索（单源）
    func search(keyword: String, page: Int) async throws -> [SearchResult]

    /// 详情（简介 + 章节，支持首屏/补全两阶段由调用方决定）
    func detail(noteUrl: String, origin: String,
                extraHeaders: [String: String]) async throws -> ComicInfo

    /// 章节列表。
    ///
    /// ⚠️ 用 `ComicInfo` 而非裸 URL：JSON 规则源的章节通常就在详情页里，
    ///    重新解析会命中 `ResponseCache`，不产生额外网络请求；
    ///    JS 类源则可直接用 manifest 声明的章节接口。
    func chapters(of comic: ComicInfo) async throws -> [ComicInfo.Chapter]

    /// 正文图片（返回 URL 列表 + 该次请求应带的 headers）。
    ///
    /// ⚠️ 与现有 `ComicEngine.contentWithHeaders` 返回结构一致 —— 便于 JSON 规则源
    ///    纯转发、零行为变更。是否还有下一页由 `.nextPage` 能力声明 + 调用方处理。
    func images(chapterUrl: String, origin: String, page: Int,
                extraHeaders: [String: String]) async throws -> (urls: [String], headers: [String: String])
}

/// 协议的默认实现：不支持的能力统一抛 `unsupportedCapability`，
/// 避免每个 Provider 都写一遍守卫。
extension SourceProvider {
    func require(_ cap: ProviderCapabilities, _ name: String) throws {
        guard capabilities.contains(cap) else {
            throw SourceProviderError.unsupportedCapability(name)
        }
    }
}
