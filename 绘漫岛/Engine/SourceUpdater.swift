import Compression
import Foundation

/// ──────────────────────────────────────────────────────────────────────────
/// 从「源仓库」在线更新图源规则
///
/// ## 为什么需要它
/// 内置的 535 个源是**一次快照**。站点改版、镜像换域名、规则修正都发生在
/// 源仓库里，用户不可能每次重装 App。有了这个，规则可以像订阅一样更新 ——
/// 「某个源不能用了」的修法从「等作者发版」变成「点一下更新」。
///
/// 源仓库：`https://www.yck2026.fun/yiciyuan/tuyuan/`
///   · 索引页 `/index.html?page=N` 里含 `/yiciyuan/tuyuan/content/id/{id}.html`
///   · 单条 `/yiciyuan/tuyuan/json/id/{id}.json`
///     —— 可能是明文 JSON，也可能是 **base64 + zlib/deflate**（实测两种都有）
///
/// ## 合并策略（重要）
/// 按 `bookSourceUrl` 对齐：
///   · 已存在 → 更新规则字段，但**保留用户自己的启用/禁用状态**
///     （否则用户手动关掉的源会被更新重新打开）
///   · 不存在 → 新增，采用仓库里的 enable
/// 这样「更新」永远不会破坏用户已经调好的源列表。
///
/// ## 与内置源导入的关系
/// 启动时的内置导入走 `HMDApp.importInBatches`；本类是**手动触发**的增量更新。
/// 两者共用 `SourceCodec.parseJson` + `decryptRules`，行为一致。
/// ──────────────────────────────────────────────────────────────────────────
enum SourceUpdater {

    static let indexURL = "https://www.yck2026.fun/yiciyuan/tuyuan/index.html"
    static func jsonURL(_ id: Int) -> String {
        "https://www.yck2026.fun/yiciyuan/tuyuan/json/id/\(id).json"
    }

    struct Report {
        var total = 0          // 仓库里的条目数
        var added = 0          // 新增
        var updated = 0        // 更新
        var unchanged = 0      // 无变化
        var failed = 0         // 抓取/解码失败
        var text: String { "新增 \(added) · 更新 \(updated) · 无变化 \(unchanged) · 失败 \(failed)" }
    }

    // MARK: - 索引

    /// 拉取全部条目 id（翻页直到没有新 id）
    static func fetchIDs(maxPages: Int = 40) async -> [Int] {
        var ids = Set<Int>()
        for page in 1...maxPages {
            let url = page == 1 ? indexURL : "\(indexURL)?page=\(page)"
            let html = await HttpFetcher.shared.fetchText(url, timeout: 20)
            if html.isEmpty { break }
            let found = Self.matches(in: html, pattern: #"/yiciyuan/tuyuan/content/id/(\d+)\.html"#)
            let new = Set(found).subtracting(ids)
            if new.isEmpty { break }
            ids.formUnion(new)
        }
        return ids.sorted()
    }

    // MARK: - 单条

    /// 拉单条源，返回**已解码**的 JSON 文本（明文或 base64+zlib 都已还原）
    static func fetchPayload(_ id: Int) async -> String? {
        let raw = await HttpFetcher.shared.fetchText(jsonURL(id), timeout: 20)
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("{") || t.hasPrefix("[") { return t }
        guard let d = Data(base64Encoded: t, options: [.ignoreUnknownCharacters]) else { return nil }
        return inflateToString(d)
    }

    /// base64 解出来的字节 → 文本。可能是 zlib 包裹的 deflate，也可能是裸 deflate。
    /// 做法：两种偏移各试一次，取**能解出 JSON 文本**的那个（自校验，不猜格式）。
    static func inflateToString(_ data: Data) -> String? {
        guard data.count > 2 else { return nil }
        for skip in [2, 0] {
            guard data.count > skip else { continue }
            let body = data.dropFirst(skip)
            guard let out = inflateRaw(Data(body)),
                  let s = String(data: out, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  s.hasPrefix("{") || s.hasPrefix("[") else { continue }
            return s
        }
        return nil
    }

    /// raw deflate 解压（Apple 的 `COMPRESSION_ZLIB` 就是裸 deflate，不含 zlib 头）
    static func inflateRaw(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var cap = max(data.count * 8, 256 * 1024)
        for _ in 0..<4 {                       // 容量不够就翻倍重试
            var out = Data(count: cap)
            let n = out.withUnsafeMutableBytes { dst -> Int in
                data.withUnsafeBytes { src -> Int in
                    guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                          let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(d, cap, s, data.count, nil, COMPRESSION_ZLIB)
                }
            }
            if n > 0 { return out.prefix(n) }
            cap *= 4
        }
        return nil
    }

    // MARK: - 全量更新

    /// 全量更新。并发 6 拉取（仓库是自己的小站，别打太狠），逐条合并落库。
    static func updateAll(threads: Int = 6,
                          onProgress: @escaping (Report) -> Void) async -> Report {
        var rep = Report()
        let ids = await fetchIDs()
        guard !ids.isEmpty else {
            onProgress(rep)
            return rep
        }
        rep.total = ids.count

        // 现有源的启用状态（更新时保留用户的选择）
        var existingEnable: [String: Bool] = [:]
        var existingURLs = Set<String>()
        for s in ComicRepository.shared.allSources() {
            existingEnable[s.bookSourceUrl] = s.enable ?? true
            existingURLs.insert(s.bookSourceUrl)
        }

        var texts: [String] = []
        var done = 0
        await withTaskGroup(of: String?.self) { group in
            var active = 0
            var it = ids.makeIterator()
            func fill() {
                while active < threads, let id = it.next() {
                    active += 1
                    group.addTask { await fetchPayload(id) }
                }
            }
            fill()
            for await r in group {
                active -= 1
                done += 1
                if let r { texts.append(r) } else { rep.failed += 1 }
                rep.unchanged = done - rep.added - rep.updated - rep.failed
                onProgress(rep)
                fill()
            }
        }

        // 解析 + 解密 + 合并
        var all: [ComicSource] = []
        for t in texts { all.append(contentsOf: SourceCodec.parseJson(t)) }
        guard !all.isEmpty else {
            onProgress(rep)
            return rep
        }
        // 先登记共享密文候选（镜像域名共用密文，必须一起登记才解得开）
        SourceDecrypt.registerCandidates(SourceCodec.collectHTCipherPairs(all))

        rep.added = 0; rep.updated = 0; rep.unchanged = 0
        for var s in all {
            let url = s.bookSourceUrl
            guard !url.isEmpty else { continue }
            s.decryptRules(sourceUrl: url)
            if existingURLs.contains(url) {
                // 保留用户手动调过的启用状态
                if let keep = existingEnable[url] { s.enable = keep }
                rep.updated += 1
            } else {
                rep.added += 1
            }
            ComicRepository.shared.saveSource(s)
            if (rep.added + rep.updated) % 25 == 0 {
                Self.postSourcesChanged()
            }
        }
        Self.postSourcesChanged()
        return rep
    }

    /// 发「源集合已变化」通知。
    ///
    /// ⚠️ **必须回主线程发**：`updateAll` 是 nonisolated `async`，
    ///    在全局执行器上跑；而 `SourceListView` 的 `.onReceive` 闭包
    ///    **在发布线程上执行**，里面会直接写 `@State sources`。
    ///    从后台线程发 = 在后台线程写 SwiftUI 状态 → 偶发崩溃/UI 撕裂。
    ///    （`HMDApp.importInBatches` 与 `SourceCheckView` 都已显式回到主线程，
    ///     唯独这条在线更新路径漏了。）
    static func postSourcesChanged() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: .hmdSourcesChanged, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .hmdSourcesChanged, object: nil)
            }
        }
    }

    // MARK: - 工具

    private static func matches(in text: String, pattern: String) -> [Int] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            Int(ns.substring(with: $0.range(at: 1)))
        }
    }
}
