import Foundation

/// ──────────────────────────────────────────────────────────────────────────
/// 图源「再探闭环」—— 把**观察到的事实**转成**对源库的动作**。
///
/// ## 为什么需要它
/// 在它之前，链路是断的：
///   体检（`SourceCheckView`）→ `SourceHealth.mergeObserved` → 写 `source_health.json`
///   → **然后就没有了**。
/// 结论只用来在列表上显示个角标，源本身该坏还是坏、该被停用还是照常启用。
/// 用户看到的仍是「一堆打不开的源」，只是旁边多了个红色角标 —— 等于没闭环。
///
/// ## 本文件做的事
/// 把「体检结论」按**保守规则**作用到 `ComicRepository`：
///   ① **坏源降级**：连续 N 次探到确定性失败（站点不可达 / 列表解析 0）→ 自动禁用。
///      只在**连续**失败时做 —— 单次失败可能只是当时网络抖动，据此禁用是误伤。
///   ② **恢复回正**：之前被「自动禁用」的源探到可用 → **自动恢复启用**。
///      只恢复「我们自己禁的」，用户手动关掉的源绝不擅自打开。
///   ③ **不碰手工状态**：用户自己禁用的源，我们不恢复；用户自己启用的坏源，我们照规则降级
///      但会记下理由，用户可以在图源页看到为什么被关。
///
/// ## 边界
///   · 只处理**确定性失败**（`dead` / `no_list`）。`challenge`（需过验证）、
///     `need_js` 不降级 —— 那是源的设计使然，不是坏了。
///   · 需要连续失败达阈值，阈值与计数持久化在 `UserDefaults`，重启不丢。
/// ---------------------------------------------------------------------------
enum SourceReprobeLoop {

    /// 连续失败多少次才自动禁用。
    ///
    /// 为什么不是 1：图源失败常见原因是**当时的网络**（代理没开、站点临时 502）。
    /// 一次失败就禁用，用户开代理前体检一遍会把好源全关掉。
    /// 3 次是「跨会话仍失败」的信号，误伤概率低。
    static let failThreshold = 3

    /// 我们自己禁用源时打的标记（放在 `UserDefaults`，因为 `ComicSource` 没有这个字段）。
    /// key = bookSourceUrl
    private static let autoDisabledKey = "hmd.autoDisabledSources"
    private static let failCountKey = "hmd.sourceFailCounts"

    private static let lock = NSLock()

    // MARK: - 计数存储

    private static func loadFailCounts() -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: failCountKey) as? [String: Int]) ?? [:]
    }

    private static func saveFailCounts(_ m: [String: Int]) {
        UserDefaults.standard.set(m, forKey: failCountKey)
    }

    static func autoDisabledUrls() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: autoDisabledKey) ?? [])
    }

    private static func setAutoDisabled(_ urls: Set<String>) {
        UserDefaults.standard.set(Array(urls).sorted(), forKey: autoDisabledKey)
    }

    // MARK: - 主入口

    /// 一次闭环处理的结果（供 UI 汇报「自动做了哪些调整」）。
    struct Outcome {
        var disabled: [String] = []      // 被自动禁用的源名
        var reEnabled: [String] = []     // 被自动恢复的源名
        var observedBad: [String] = []   // 本次观察到坏、但还没到阈值的源名

        var isEmpty: Bool { disabled.isEmpty && reEnabled.isEmpty }

        var summary: String? {
            guard !isEmpty else { return nil }
            var parts: [String] = []
            if !disabled.isEmpty {
                parts.append("自动停用 \(disabled.count) 个打不开的源（连续 \(failThreshold) 次失败）")
            }
            if !reEnabled.isEmpty {
                parts.append("自动恢复 \(reEnabled.count) 个已可用的源")
            }
            return parts.joined(separator: "；")
        }
    }

    /// 把体检结果作用到源库。
    ///
    /// - Parameter results: `SourceCheckView` 的体检结果（含未完成的）
    /// - Returns: 本次实际做的调整
    @discardableResult
    static func apply(_ results: [SourceCheckResult]) -> Outcome {
        let checked = results.filter { $0.checked }
        guard !checked.isEmpty else { return Outcome() }

        let repo = ComicRepository.shared
        var byUrl: [String: ComicSource] = [:]
        for s in repo.allSources() { byUrl[s.bookSourceUrl] = s }

        var counts = loadFailCounts()
        var autos = autoDisabledUrls()
        var outcome = Outcome()

        // 预先按名字取好，避免循环里反复查库
        func name(of url: String) -> String {
            byUrl[url]?.bookSourceName ?? url
        }

        for r in checked {
            let url = r.sourceUrl
            guard byUrl[url] != nil else { continue }
            let st = SourceHealth.observedStateName(r)

            if isDeterministicFailure(st) {
                // 确定性失败 → 累加计数
                counts[url] = (counts[url] ?? 0) + 1
                if counts[url]! >= failThreshold,
                   let cur = byUrl[url], (cur.enable ?? true) == true {
                    // 到达阈值 → 停用（如果它还是启用状态）
                    var s = cur
                    s.enable = false
                    repo.saveSource(s)
                    autos.insert(url)
                    outcome.disabled.append(s.bookSourceName ?? url)
                } else if counts[url]! < failThreshold {
                    outcome.observedBad.append(name(of: url))
                }
            } else if SourceHealth.isGoodState(st) {
                // 可用 → 清零失败计数
                counts[url] = 0
                // 若之前是「我们自动禁的」且当前确实被禁 → 恢复
                if autos.contains(url), let cur = byUrl[url], (cur.enable ?? true) == false {
                    var s = cur
                    s.enable = true
                    repo.saveSource(s)
                    autos.remove(url)
                    outcome.reEnabled.append(s.bookSourceName ?? url)
                }
            }
            // challenge / need_js / unknown：既不加失败计数也不清零（保持现状）
        }

        // 清掉已不存在的源留下的计数，避免 UserDefaults 无限增长
        let liveUrls = Set(byUrl.keys)
        counts = counts.filter { liveUrls.contains($0.key) }
        autos = autos.filter { liveUrls.contains($0) }

        saveFailCounts(counts)
        setAutoDisabled(autos)

        if !outcome.isEmpty {
            NotificationCenter.default.post(name: .hmdSourcesChanged, object: nil)
        }
        return outcome
    }

    /// 确定性失败 —— 才值得计入「连续失败」并最终停用。
    ///
    /// ⚠️ 刻意**排除** `challenge` 与 `need_js`：
    ///    前者是站点开了人机校验（换个网络/过验证就能用），
    ///    后者是源本身需要 JS 能力；两者都不是「这个源坏了」，
    ///    自动停用会让用户彻底失去它。
    private static func isDeterministicFailure(_ state: String) -> Bool {
        ["dead", "no_list"].contains(state)
    }

    // MARK: - 诊断 / 重置

    /// 当前失败计数快照（供诊断页展示）
    static func failCountsSnapshot() -> [(url: String, count: Int)] {
        loadFailCounts().map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }

    /// 清空所有自动调整（用户想「让一切回到手动状态」时用）
    static func reset() {
        UserDefaults.standard.removeObject(forKey: failCountKey)
        UserDefaults.standard.removeObject(forKey: autoDisabledKey)
    }
}
