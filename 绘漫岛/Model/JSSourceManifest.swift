import Foundation

/// JS 类源 manifest —— 显式声明元数据、桥接 API 版本与入口函数。
///
/// ⚠️ 设计约束（ARCHITECTURE §9.1）：
///   ① 用**显式 provider type + manifest/version** 判定，不做启发式猜测；
///   ② 图源脚本是**不可信输入**：manifest 只声明「要什么」，不直接给系统能力；
///   ③ `apiVersion` 决定可用桥接白名单 —— 版本不认识就**拒绝加载**，不猜兼容。
struct JSSourceManifest: Codable {
    /// 源唯一标识（建议域名反写，如 com.example.site）
    var id: String
    /// 显示名
    var name: String
    /// 源自身版本（由作者维护）
    var version: String
    /// 桥接 API 版本 —— 决定白名单与函数签名
    var apiVersion: Int
    /// 主域（网络白名单基准：只允许受控 fetch 访问该域及其子域）
    var domain: String
    /// 入口脚本源码（JS）
    var script: String
    /// 各能力对应的入口函数名（缺省 = 不支持该能力）
    var entry: Entry
    /// 附加请求头（Referer / UA 等，**不含凭据**）
    var headers: [String: String]?
    /// 执行通道（缺省 = `jscore`，保持向后兼容）。
    ///
    /// ⚠️ 两者能力不同，源作者必须按需选择：
    ///   • `jscore`  —— 默认。**支持网络桥**（`org.jsoup.*` / `java.ajax`），
    ///                  但**无法终止死循环**（JSCore 无对应 API）。
    ///   • `wkwebview` —— 可**超时终止**（超时销毁 WebView、回收进程），
    ///                  但**没有网络桥**（跨进程无法同步调用原生）。
    /// 缺省时按 `jscore` 处理 —— 老 manifest 里没有这个字段，不能因为新增字段就全部拒绝加载。
    var runtime: Runtime?

    enum Runtime: String, Codable {
        case jscore
        case wkwebview

        /// 人类可读说明（UI 展示用）
        var displayName: String {
            switch self {
            case .jscore: return "JSCore（支持网络，不可终止）"
            case .wkwebview: return "WKWebView（可终止，无网络桥）"
            }
        }
    }

    /// 未声明时使用的缺省通道
    var effectiveRuntime: Runtime { runtime ?? .jscore }

    struct Entry: Codable {
        var search: String?
        var detail: String?
        var chapters: String?
        var images: String?
    }
}

extension JSSourceManifest {
    /// 本 App 支持的桥接 API 版本区间
    static let supportedAPIVersions: ClosedRange<Int> = 1...1

    /// 校验 manifest 是否可加载；失败抛 `SourceProviderError.invalidSource`。
    func validate() throws {
        guard !id.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw SourceProviderError.invalidSource("缺少 id")
        }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw SourceProviderError.invalidSource("缺少 name")
        }
        guard !domain.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw SourceProviderError.invalidSource("缺少 domain（网络白名单基准）")
        }
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourceProviderError.invalidSource("脚本为空")
        }
        guard Self.supportedAPIVersions.contains(apiVersion) else {
            // ⚠️ 不认识就拒绝，不「尽量兼容」—— 用旧白名单跑新脚本是安全事故
            throw SourceProviderError.invalidSource(
                "不支持的 apiVersion=\(apiVersion)"
                + "（本版本支持 \(Self.supportedAPIVersions.lowerBound)…\(Self.supportedAPIVersions.upperBound)）")
        }
        guard entry.search != nil || entry.detail != nil
                || entry.chapters != nil || entry.images != nil else {
            throw SourceProviderError.invalidSource("未声明任何入口函数")
        }
    }

    /// 由入口声明推导能力集合
    var declaredCapabilities: ProviderCapabilities {
        var caps: ProviderCapabilities = [.metadata]
        if entry.search != nil { caps.insert(.search) }
        if entry.detail != nil { caps.insert(.detail) }
        if entry.chapters != nil { caps.insert(.chapters) }
        if entry.images != nil { caps.insert(.images) }
        if headers != nil { caps.insert(.headers) }
        return caps
    }
}
