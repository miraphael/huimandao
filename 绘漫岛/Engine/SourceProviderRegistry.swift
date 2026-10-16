import Foundation

/// 图源提供者注册表 —— 按源类型路由到对应 `SourceProvider`。
///
/// ⚠️ 现状与边界：
///   • **纯内存、不改 DB schema**。JS 源的持久化（manifest 落库/落盘）留待后续阶段，
///     本文件先用显式 `register` 打通「注册 → 取用」链路，不碰现有导入路径。
///   • 锁只在**同步方法**内使用（`NSLock` 不可直接用于 async 函数 —— 项目硬约束）。
final class SourceProviderRegistry {
    static let shared = SourceProviderRegistry()

    /// key = `bookSourceUrl`
    private var jsonProviders: [String: JSONRuleProvider] = [:]
    /// key = `manifest.id`
    private var jsProviders: [String: JSProvider] = [:]
    private let lock = NSLock()

    private init() {}

    /// 取（或惰性创建）JSON 规则源的 Provider。
    ///
    /// ⚠️ 惰性缓存是安全的：`JSONRuleProvider` 只持有 `ComicSource` 值，无状态。
    func jsonProvider(for source: ComicSource) -> JSONRuleProvider {
        let key = source.bookSourceUrl
        lock.lock()
        defer { lock.unlock() }
        if let p = jsonProviders[key] { return p }
        let p = JSONRuleProvider(source: source)
        jsonProviders[key] = p
        return p
    }

    /// 注册一个 JS 类源。manifest 校验失败会抛 `SourceProviderError.invalidSource`。
    @discardableResult
    func register(manifest: JSSourceManifest) throws -> JSProvider {
        let p = try JSProvider(manifest: manifest)
        lock.lock()
        jsProviders[manifest.id] = p
        lock.unlock()
        return p
    }

    func jsProvider(id: String) -> JSProvider? {
        lock.lock()
        defer { lock.unlock() }
        return jsProviders[id]
    }

    /// 已注册的 JS 源 id 列表（供「图源管理」展示）
    var registeredJSIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(jsProviders.keys).sorted()
    }

    /// 当前所有已注册的 JS 源 Provider（供搜索等批量场景并发调用）
    func allJSProviders() -> [JSProvider] {
        lock.lock()
        defer { lock.unlock() }
        return Array(jsProviders.values)
    }

    /// 从持久化装载全部**启用且合法**的 JS 源（App 启动时调用一次即可）。
    ///
    /// ⚠️ 单个源 manifest 非法会被 `JSSourceStore.load` 过滤掉，
    ///    **不影响其他源**（§9.1 验收：一个源异常不拖累其他源）。
    @discardableResult
    func loadFromStore() -> Int {
        var loaded = 0
        for m in JSSourceStore.loadEnabled() {
            if (try? register(manifest: m)) != nil { loaded += 1 }
        }
        return loaded
    }

    /// 源失效时清理（删除/禁用源后调用，避免持有过期引用）
    func invalidate(sourceId: String) {
        lock.lock()
        jsonProviders[sourceId] = nil
        jsProviders[sourceId] = nil
        lock.unlock()
    }

    /// 把「源标识」翻译成**给人看的名字**。
    ///
    /// JS 源的 `origin` 是内部标识 `js://<id>`（上层靠它路由回 Provider），
    /// 但直接展示给用户毫无意义（详情页的「图源: …」、搜索结果的「来源: …」）。
    /// 这里统一做一次翻译，调用方不必各自判断前缀。
    ///
    /// - Returns: JS 源返回 manifest 的显示名；其它来源**原样返回**（JSON 源传的是 URL，
    ///   上层本来就直接显示，不在这里做二次加工）。
    func displayName(forOrigin origin: String) -> String {
        let prefix = SearchResult.jsOriginPrefix
        guard origin.hasPrefix(prefix) else { return origin }
        let id = String(origin.dropFirst(prefix.count))
        lock.lock()
        let name = jsProviders[id]?.manifest.name
        lock.unlock()
        if let name, !name.isEmpty { return name }
        // 未注册（源被删除/禁用，或尚未装载）时给出可辨识的兜底，
        // 而不是把 `js://xxx` 原样丢给用户。
        return id.isEmpty ? "JS 源" : "JS 源（\(id)）"
    }

    /// 按 `ComicSource` 取统一 Provider。
    ///
    /// 当前 `ComicSource` 只承载 JSON 规则源；JS 源走 `jsProvider(id:)`。
    /// 待 ComicSource 增加显式 provider type 字段后，这里改为按其分派。
    func provider(for source: ComicSource) -> SourceProvider {
        jsonProvider(for: source)
    }
}
