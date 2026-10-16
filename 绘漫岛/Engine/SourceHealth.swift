import Foundation

/// ──────────────────────────────────────────────────────────────────────────
/// 源健康清单 —— 「哪些源本来就不能用」的**预置知识**
///
/// ## 为什么要预置
/// 桌面端对 501 个启用源跑了一次全链路体检（走代理，每源 3~4 次请求）：
/// ```
///   站点不可达        238
///   页面可达但列表 0   139
///   被反爬拦截         26
///   详情可达但章节 0   21
///   规则含 JS          19
///   入口+列表可用       7
///   全链路可用          1
/// ```
/// **接近一半的源指向的域名早就没了**（status=000 / 502 / 404）。
/// 用户看到的是「这么多源都不能用」，但其中大部分**不是解析问题，是站点没了**。
/// 把这份清单内置进来，App 就能明确区分：
///   · 「此源站点已不可达」——不用浪费时间去试
///   · 「此源被反爬拦截」——App 会自动用 WebView 过挑战（见 `AntiBot`）
///   · 「此源规则命中 0」——可能是规则过时，值得跑一次在线更新
///
/// ## ⚠️ 只作提示，绝不自动禁用
/// 桌面网络（走本机代理）与手机网络不同 —— 「桌面测出不可达」≠「手机上不可达」。
/// 所以这里只给**角标 + 一键停用入口**，真正的判定交给 App 内的全链路体检
/// （用手机自己的网络跑）。
///
/// ## 可更新
/// 优先读 `Documents/source_health.json`（用户导入/在线更新的），
/// 没有再回落到打包内置的 `builtin_health.json`。
/// 这样清单可以像规则一样更新，不用重新发版。
/// ──────────────────────────────────────────────────────────────────────────
enum SourceHealth {

    struct Entry {
        var state: String = "unknown"
        var stage: String = ""
        var chapters: Int = 0
        var images: Int = 0
        var detail: String = ""
        /// 体检时记下的源名（`mergeObserved` 写入 `name`）。仅用于展示。
        ///
        /// ⚠️ 老清单里没有这个键 —— 缺失就是空串，不能因此让整份清单加载失败。
        var name: String = ""

        /// 是否属于「已知不可用」（值得提示用户）
        var isBad: Bool {
            ["dead", "no_list", "no_chapter", "no_image"].contains(state)
        }
        var isChallenge: Bool { state == "challenge" }
        var isGood: Bool { state == "ok" || state == "list_ok" }

        /// 角标文案
        var badge: String? {
            switch state {
            case "dead": return "站点不可达"
            case "no_list": return "列表解析 0"
            case "no_chapter": return "章节 0"
            case "no_image": return "正文 0 图"
            case "challenge": return "需过验证"
            case "need_js": return "需 JS 规则"
            case "list_ok": return "入口可用"
            case "ok": return chapters > 0 ? "\(chapters) 章" : "可用"
            default: return nil
            }
        }
        var badgeIsBad: Bool { isBad }
    }

    private static let lock = NSLock()
    private static var hosts: [String: Entry]?
    private static var meta: (generatedAt: TimeInterval, note: String) = (0, "")

    private static var userFile: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("source_health.json")
    }

    /// 懒加载（优先用户文件 → 内置）
    private static func ensureLoaded() {
        lock.lock(); defer { lock.unlock() }
        guard hosts == nil else { return }
        var data: Data? = try? Data(contentsOf: userFile)
        if data == nil, let u = Bundle.main.url(forResource: "builtin_health", withExtension: "json") {
            data = try? Data(contentsOf: u)
        }
        guard let d = data,
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            hosts = [:]
            return
        }
        meta.note = obj["note"] as? String ?? ""
        if let t = obj["generatedAt"] as? NSNumber {
            meta.generatedAt = t.doubleValue
        }
        var m: [String: Entry] = [:]
        if let hs = obj["hosts"] as? [String: Any] {
            for (h, v) in hs {
                guard let d2 = v as? [String: Any] else { continue }
                m[h] = Entry(state: d2["state"] as? String ?? "unknown",
                             stage: d2["stage"] as? String ?? "",
                             chapters: (d2["chapters"] as? NSNumber)?.intValue ?? 0,
                             images: (d2["images"] as? NSNumber)?.intValue ?? 0,
                             detail: d2["detail"] as? String ?? "",
                             name: d2["name"] as? String ?? "")
            }
        }
        hosts = m
    }

    /// 按图源 URL 查状态（自动取 host）
    static func state(sourceUrl: String) -> Entry? {
        guard let h = URL(string: sourceUrl)?.host?.lowercased(), !h.isEmpty else { return nil }
        ensureLoaded()
        lock.lock(); defer { lock.unlock() }
        if let e = hosts?[h] { return e }
        // 镜像域名兜底：按主域匹配（a.example.com → example.com）
        let parts = h.components(separatedBy: ".")
        if parts.count > 2 {
            let root = parts.suffix(2).joined(separator: ".")
            return hosts?[root]
        }
        return nil
    }

    // ⚠️ 原来这里有个 `knownBadCount()`（全清单里 isBad 的 host 数）。
    //    它**不考虑健康数据是否过期**，用它去批量停用源会用旧结论误伤好源，
    //    已被 `badSources(_:)` / `staleCount(_:)` 取代 —— 故意不再保留，
    //    免得后来者顺手用它又踩回同一个坑。

    static func totalCount() -> Int {
        ensureLoaded()
        lock.lock(); defer { lock.unlock() }
        return hosts?.count ?? 0
    }

    static var generatedAt: Date? {
        ensureLoaded()
        return meta.generatedAt > 0 ? Date(timeIntervalSince1970: meta.generatedAt) : nil
    }

    /// 这条健康数据是否**比源规则还旧** —— 规则更新过，旧结论就不可信。
    ///
    /// ── 为什么用时间戳而不是规则指纹 ──────────────────────────────────────
    /// 规则指纹要在 Swift 与 Python 两边算出**逐字节一致**的哈希才能比对；
    /// 一旦不一致（字段顺序、空白处理差一点），后果是**所有源都显示「数据过期」**，
    /// 比不做还糟。时间戳两边都现成：
    ///   · `ComicSource.lastUpdateTime` —— 源被更新的时刻（毫秒）
    ///   · 报告的 `generatedAt`          —— 体检跑完的时刻（秒）
    ///
    /// ⚠️ 这是一个**保守**判据：源只要更新过就判过期，哪怕更新与规则无关。
    ///    宁可多提示「数据可能过期」，也不要拿旧结论去禁用本来可用的源。
    static func isStale(for source: ComicSource) -> Bool {
        let updatedMs = source.lastUpdateTime ?? 0
        guard updatedMs > 0 else { return false }
        // ⚠️ 必须先 ensureLoaded() 再读 meta —— 否则首次调用时 generatedAt 还是 0，
        //    会直接判「不过期」，这个守卫就形同虚设。
        ensureLoaded()
        let gen = meta.generatedAt
        guard gen > 0 else { return false }
        return Double(updatedMs) / 1000.0 > gen + 1     // +1s 容忍取整/时钟误差
    }

    /// 「已知不可用且健康数据未过期」的源 —— 批量停用只该动这些。
    static func badSources(_ sources: [ComicSource]) -> [ComicSource] {
        sources.filter { s in
            guard !isStale(for: s) else { return false }
            return state(sourceUrl: s.bookSourceUrl)?.isBad == true
        }
    }

    /// 健康数据已过期的源数量（用于提示「该重跑体检了」）
    static func staleCount(_ sources: [ComicSource]) -> Int {
        sources.filter { isStale(for: $0) }.count
    }

    static var note: String {
        ensureLoaded()
        return meta.note
    }

    /// 丢弃缓存，下次查询重新加载。
    ///
    /// ⚠️ 必须是**同步**函数：`NSLock.lock()` 标了 `@available(*, noasync)`，
    ///    在 async 函数体内直接调用是 Swift 6 编译错误（`probe/async_lock.py` 扫这个）。
    private static func invalidate() {
        lock.lock(); hosts = nil; lock.unlock()
    }

    // MARK: - observed：把「手机自己的体检结果」写进清单

    /// 把 App 的全链路体检结果**合并**进本地健康清单。
    ///
    /// ── 为什么要这一步（declared 与 observed 必须分开）────────────────────
    /// 内置的 `builtin_health.json` 是**桌面端**测的：桌面走代理、和手机网络不一样，
    /// 而且随发版固化、很快就过期。手机自己跑一次全链路体检，才是
    /// 「这个源在我这儿、现在、到底行不行」。
    /// 这里把结果写进 `Documents/source_health.json`（`SourceHealth` 本来就优先读它），
    /// 于是图源列表的角标自动从「桌面结论」切换成「手机实测」。
    ///
    /// ⚠️ 只**合并**，不整份覆盖：这次没体检到的 host 保留原结论。
    /// ⚠️ `generatedAt` 更新为本次体检时间 —— 之后 `isStale(for:)` 才能正确判断
    ///    「源规则更新过 → 旧结论作废」。
    /// - Returns: 合并进去的 host 数
    @discardableResult
    static func mergeObserved(_ results: [SourceCheckResult]) -> Int {
        let checked = results.filter { $0.checked }
        guard !checked.isEmpty else { return 0 }

        var root: [String: Any] = [:]
        if let d = try? Data(contentsOf: userFile),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            root = o
        } else if let u = Bundle.main.url(forResource: "builtin_health", withExtension: "json"),
                  let d = try? Data(contentsOf: u),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            root = o
        }
        var hosts = (root["hosts"] as? [String: Any]) ?? [:]
        let now = Int(Date().timeIntervalSince1970)
        var merged = 0
        for r in checked {
            guard let h = URL(string: r.sourceUrl)?.host?.lowercased(), !h.isEmpty else { continue }
            var entry = (hosts[h] as? [String: Any]) ?? [:]
            entry["state"] = observedState(r)
            entry["stage"] = r.stage
            entry["chapters"] = r.chapters
            entry["images"] = r.images
            entry["detail"] = "手机实测：\(r.message.prefix(60))"
            entry["observedAt"] = now
            entry["name"] = String(r.name.prefix(24))
            hosts[h] = entry
            merged += 1
        }
        root["hosts"] = hosts
        root["generatedAt"] = now
        root["note"] = "含**手机端全链路体检**结果（最后一次 \(Date())）。同一 host 以手机实测为准，"
            + "未体检到的 host 保留桌面端结论。"
        guard let data = try? JSONSerialization.data(withJSONObject: root) else { return 0 }
        try? data.write(to: userFile, options: .atomic)
        invalidate()
        return merged
    }

    /// 把一次体检结果映射成清单里的 `state`（与 `builtin_health.json` 的 legend 对齐）。
    ///
    /// ⚠️ `images == 0` 只有在**真的探过正文**时才能判「正文 0 图」——
    ///    轻量档不会请求正文页，`images` 恒为 0，据此判坏会把一堆正常源标成坏的。
    private static func observedState(_ r: SourceCheckResult) -> String {
        if r.ok {
            if r.chapters == 0 { return "no_chapter" }
            if r.probedContent && r.images == 0 { return "no_image" }
            return "ok"
        }
        switch r.stage {
        case "入口": return "no_entry"
        case "网络": return "dead"
        case "列表": return "no_list"
        case "详情", "章节": return "no_chapter"
        case "正文": return "no_image"
        default: return "no_list"
        }
    }

    /// `observedState` 的对外只读版本。
    ///
    /// `SourceReprobeLoop` 需要拿这个状态去决定「要不要降级/恢复」，
    /// 但不能把整个映射逻辑抄一遍（两处实现迟早会漂移）。
    static func observedStateName(_ r: SourceCheckResult) -> String {
        observedState(r)
    }

    /// 该状态算不算「可用」—— 供闭环决定是否清零失败计数、恢复启用。
    ///
    /// ⚠️ 与 `Entry.isGood`（`ok` / `list_ok`）**不完全相同**：
    ///    实测结果里没有 `list_ok` 这个中间态（那是桌面探针的结论），
    ///    手机实测「能搜到但章节 0」会落到 `no_chapter`，那是**不好**的。
    static func isGoodState(_ state: String) -> Bool {
        state == "ok"
    }

    /// 健康清单里记的名字（体检时写进去的 `name`）。
    ///
    /// ⚠️ 清单是 `[host: entry]`，**不保存源 URL**。所以这里只能拿 host 去查，
    ///    查不到返回 nil，调用方自己兜底（通常回落到显示 URL）。
    ///    同 host 多源时可能显示成同一个名字 —— 这可以接受：
    ///    该字段只用于「自动调整」的简报，不是唯一标识。
    static func displayName(forUrl url: String) -> String? {
        guard let h = URL(string: url)?.host?.lowercased(), !h.isEmpty else { return nil }
        ensureLoaded()
        lock.lock()
        let n = hosts?[h]?.name
        lock.unlock()
        return (n?.isEmpty == false) ? n : nil
    }

    /// 从 URL 在线更新健康清单（写到 Documents，下次启动生效）。    ///
    /// 想更新清单时把新 JSON 放到任意可访问的地址即可 —— 不需要重新发版。
    @discardableResult
    static func updateFrom(url: String) async -> Bool {
        guard url.lowercased().hasPrefix("http") else { return false }
        let text = await HttpFetcher.shared.fetchPage(url, timeout: 30)
        guard let d = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              obj["hosts"] is [String: Any] else { return false }
        try? d.write(to: userFile)
        invalidate()
        return true
    }

    /// 从本地文件导入（体检报告 / 别人分享的清单）
    @discardableResult
    static func importFile(_ url: URL) -> Bool {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        guard let d = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              obj["hosts"] is [String: Any] else { return false }
        try? d.write(to: userFile)
        invalidate()
        return true
    }
}
