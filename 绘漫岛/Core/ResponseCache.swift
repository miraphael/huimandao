import Foundation

/// 带 TTL + 防击穿 的响应缓存 —— 对标 daisy `rust/src/database/cache/web_cache.rs`
/// 的 `cache_first(key, expire, fetch)`。
///
/// 行为：
/// 1. 命中且未过期 → 直接返回（零网络延迟）
/// 2. 同一 key 并发请求 → 只放一个真打网络，其余等它（防缓存击穿）
/// 3. 未命中 → 拉取成功后写内存 + 磁盘；杀 App 再开依然秒开
///
/// 用 actor 保证并发安全，避免手写锁在 async 环境下的死锁风险。
actor ResponseCache {
    static let shared = ResponseCache()

    /// 默认 TTL —— **统一由 `CacheDomain` 提供**（那里同时定义 key 前缀，
    /// 避免「用了 detail 的 key 配 chapters 的 TTL」这类错配）。
    /// 保留这层别名只是为了让老的调用点继续可用；新代码请直接用 `CacheDomain.x.ttl`。
    enum TTL {
        /// 详情页（书名/作者/简介/最新章节）
        static let detail: TimeInterval = CacheDomain.detail.ttl
        /// 章节列表（daisy 用 10h；章节会更新，折中 1h）
        static let chapters: TimeInterval = CacheDomain.chapters.ttl
        /// 正文图片列表
        static let content: TimeInterval = CacheDomain.content.ttl
        /// 搜索
        static let search: TimeInterval = CacheDomain.search.ttl
        /// 图片字节（图片不会变）
        static let image: TimeInterval = 24 * 3600
    }

    private struct Entry {
        var value: String
        var expireAt: Date
        /// 最近一次被读/写的时间 —— 内存淘汰按它排序（LRU）。
        var lastAccess: Date
    }

    // MARK: - 容量上限
    //
    // ⚠️ **为什么必须加上限**：这个缓存存的是**详情 / 章节 / 正文的 HTML**，
    //    单条从几十 KB 到几 MB。原实现里：
    //      · `mem` 只在「访问到某个已过期 key」时才删它 —— 没被再次访问的过期项
    //        **永久驻留**，长期使用内存只涨不降；
    //      · 磁盘目录**完全没有上限**，文件数随搜索/详情无限膨胀，
    //        连带 `peek` 的磁盘回读、`stats()` 的目录遍历越来越慢。
    //    对比：Nuke 图片缓存有 500MB 上限，而这个响应缓存一条都没有。
    private static let maxMemEntries = 400
    private static let maxDiskBytes: Int64 = 200 * 1024 * 1024     // 200MB

    private var mem: [String: Entry] = [:]
    /// 每 key 的「结果等待者」：同 key 只跑一次 fetch，其余挂起等
    private var waiters: [String: [CheckedContinuation<String?, Never>]] = [:]
    private var fetching: Set<String> = []

    private let diskDir: URL

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDir = base.appendingPathComponent("hmd_response_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    /// 主入口：命中直接返回；否则调用 fetch 拉取并缓存
    /// - Parameters:
    ///   - key: 唯一键（建议 `"TYPE|url"`）
    ///   - ttl: 有效期秒数
    ///   - forceRefresh: true 时忽略缓存强制重拉（下拉刷新用）
    ///   - fetch: 实际拉取逻辑，返回 nil/空表示失败（不写缓存）
    func cached(key: String, ttl: TimeInterval, forceRefresh: Bool = false,
                fetch: @escaping () async -> String?) async -> String? {
        if !forceRefresh, let hit = peek(key) { return hit }

        // 已有同 key 请求在飞 → 挂起等它的结果（防击穿）
        if fetching.contains(key) {
            return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
                waiters[key, default: []].append(cont)
            }
        }

        fetching.insert(key)
        let v = await fetch()

        // 唤醒所有等待者
        let pending = waiters.removeValue(forKey: key) ?? []
        fetching.remove(key)

        let result: String? = (v?.isEmpty == false) ? v : nil
        if let result {
            store(key, value: result, ttl: ttl)
        }
        for cont in pending { cont.resume(returning: result) }
        return result
    }

    // MARK: - 读写

    /// 直接写入（供引擎缓存「已解析好的结果」用，而不是原始 HTML）
    func put(key: String, value: String, ttl: TimeInterval) {
        store(key, value: value, ttl: ttl)
    }

    /// 读取已缓存的解析结果
    func get(_ key: String) -> String? {
        peek(key)
    }

    /// 只读（同步语义，actor 内调用）
    func peek(_ key: String) -> String? {
        if let e = mem[key] {
            if e.expireAt > Date() {
                mem[key]?.lastAccess = Date()      // 命中即刷新 LRU 时间
                return e.value
            }
            mem.removeValue(forKey: key)
        }
        // 内存未命中 → 读磁盘
        let url = fileURL(key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expire = obj["e"] as? Double,
              let value = obj["v"] as? String else { return nil }
        let expireAt = Date(timeIntervalSince1970: expire)
        guard expireAt > Date() else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        mem[key] = Entry(value: value, expireAt: expireAt, lastAccess: Date())
        evictMemIfNeeded()
        return value
    }

    private func store(_ key: String, value: String, ttl: TimeInterval) {
        let expireAt = Date().addingTimeInterval(ttl)
        mem[key] = Entry(value: value, expireAt: expireAt, lastAccess: Date())
        evictMemIfNeeded()
        let obj: [String: Any] = ["e": expireAt.timeIntervalSince1970, "v": value]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let url = fileURL(key)
        let dir = diskDir
        // 磁盘写 + 淘汰都放后台，且**淘汰用 static 函数**：
        // 它只依赖 `dir`（`let`），不必回 actor —— 回 actor 会和所有缓存读抢串行队列。
        DispatchQueue.global(qos: .utility).async {
            try? data.write(to: url, options: .atomic)
            Self.evictDiskIfNeeded(dir: dir)
        }
    }

    // MARK: - 淘汰

    /// 内存淘汰：超过 `maxMemEntries` 时按 LRU 淘汰到 80%。
    /// ⚠️ 一次淘汰到 80% 而不是「删一条」—— 否则每次插入都要全表排序，插入变成 O(n log n)。
    private func evictMemIfNeeded() {
        guard mem.count > Self.maxMemEntries else { return }
        let target = Int(Double(Self.maxMemEntries) * 0.8)
        let victims = mem.sorted { $0.value.lastAccess < $1.value.lastAccess }
            .prefix(mem.count - target)
        for (k, _) in victims { mem.removeValue(forKey: k) }
    }

    /// 磁盘淘汰：超过 `maxDiskBytes` 时按修改时间从旧到新删到 80%。
    ///
    /// ⚠️ 只有真超过上限时才动手（`contentsOfDirectory` + 逐文件 stat 不便宜）。
    /// ⚠️ 声明成 `static` 是刻意的：它只在后台线程被调用，不需要 actor 隔离。
    private static func evictDiskIfNeeded(dir: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        var items: [(url: URL, size: Int64, mtime: Date)] = []
        var total: Int64 = 0
        for f in files {
            let v = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(v?.fileSize ?? 0)
            total += size
            items.append((f, size, v?.contentModificationDate ?? .distantPast))
        }
        guard total > Self.maxDiskBytes else { return }
        let target = Int64(Double(Self.maxDiskBytes) * 0.8)
        for it in items.sorted(by: { $0.mtime < $1.mtime }) {
            if total <= target { break }
            try? FileManager.default.removeItem(at: it.url)
            total -= it.size
        }
    }

    /// 主动失效（下拉刷新时清掉某本书相关缓存）
    func invalidate(prefix: String) {
        let keys = mem.keys.filter { $0.hasPrefix(prefix) }
        for k in keys { mem.removeValue(forKey: k) }
        let files = (try? FileManager.default.contentsOfDirectory(at: diskDir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.lastPathComponent.contains(safeName(prefix)) {
            try? FileManager.default.removeItem(at: f)
        }
    }

    func clearAll() {
        mem.removeAll()
        try? FileManager.default.removeItem(at: diskDir)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    /// 缓存条目数与占用体积（设置页展示用）
    func stats() -> (count: Int, bytes: Int64) {
        let files = (try? FileManager.default.contentsOfDirectory(at: diskDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var total: Int64 = 0
        for f in files {
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return (max(mem.count, files.count), total)
    }

    // MARK: - 内部

    private func safeName(_ key: String) -> String {
        key.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "?", with: "_")
            .replacingOccurrences(of: "&", with: "_")
    }

    private func fileURL(_ key: String) -> URL {
        let name = safeName(key)
        let long = name.count > 120 ? String(name.suffix(120)) : name
        let hash = String(format: "%08x", UInt32(truncatingIfNeeded: name.hashValue))
        return diskDir.appendingPathComponent("\(hash)_\(long)")
    }
}
