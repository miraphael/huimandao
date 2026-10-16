import Foundation

/// ──────────────────────────────────────────────────────────────────────────
/// 搜索模块 · 模型层
///
/// 对齐绘漫岛 `SearchComicBean` 的设计（`decoded/jadx/.../bean/SearchComicBean.java`）。
/// 那个类的字段揭示了完整搜索该有什么：
///
/// | 字段 | 作用 | 本文件对应 |
/// |---|---|---|
/// | `originUrls: List<String>` | **多源聚合** —— 同一本书在多个源的地址 | `SearchGroup` |
/// | `lastChapterNum` / `upTime` | 排序维度 | `SearchSort` |
/// | `searchTime` | 搜索耗时 | `SourceTiming` |
/// | `isCurrentSource` | 当前源标记 | `SearchHit.isCurrentSource` |
/// | `urlNext` | 分页状态 | `ComicEngine` 的 `PageCursor`（每「源 + 关键词」一份） |
///
/// 我们原来的 `SearchView` 只有「一个扁平列表」，既不能按源分组，
/// 也不能排序，同一个书名在 5 个源都出现时会刷屏 5 条。
/// ──────────────────────────────────────────────────────────────────────────

/// 搜索结果的排序维度
enum SearchSort: String, CaseIterable, Identifiable {
    case `default` = "综合"
    case source = "按来源"
    case name = "按书名"
    case chapter = "按更新章节"
    case relevance = "按匹配度"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .default: return "list.number"
        case .source: return "square.stack.3d.up"
        case .name: return "textformat.abc"
        case .chapter: return "book.pages"
        case .relevance: return "scope"
        }
    }
}

/// 单个源的搜索耗时（对齐绘漫岛的 `searchTime`）
struct SourceTiming: Identifiable {
    var id: String { origin }
    var origin: String
    var originName: String
    var ms: Int
    var count: Int
    var error: String = ""
    var ok: Bool { error.isEmpty }
}

/// 一次搜索的汇总统计
struct SearchSummary {
    var keyword: String = ""
    var totalMs: Int = 0
    var sourcesTried: Int = 0
    var sourcesOK: Int = 0
    var rawCount: Int = 0            // 去重前
    var uniqueCount: Int = 0         // 去重后
    var timings: [SourceTiming] = []

    var slowest: SourceTiming? { timings.filter(\.ok).max { $0.ms < $1.ms } }
    var fastest: SourceTiming? { timings.filter(\.ok).min { $0.ms < $1.ms } }
    /// 「聚合省下多少」—— 多源命中的重复书有几本
    var mergedGroups: Int { max(0, rawCount - uniqueCount) }
}

/// 同一本书的「多源聚合」—— 对齐绘漫岛的 `originUrls`
///
/// 判定「同一本书」用**归一化书名**（去空格/标点/繁简差异不处理，只做轻量归一）。
/// 绘漫岛是直接拿 `name` 比；这里加一层归一化，避免「海贼王」和「海贼王 」被拆成两条。
struct SearchGroup: Identifiable {
    var id: String { key }
    var key: String                   // 归一化后的书名
    var displayName: String           // 展示用（取第一个命中）
    var hits: [SearchResult]          // 各源的命中
    var isMerged: Bool { hits.count > 1 }

    /// 主命中：优先「当前选中的源」，其次章节数最多的。
    /// ⚠️ 当前源**显式传参**而不是给 struct 挂全局状态 ——
    ///    `SearchResult` 是值类型，挂外部标记既破坏值语义又多线程不安全。
    func primary(currentOrigin: String? = nil) -> SearchResult {
        if let o = currentOrigin, let hit = hits.first(where: { $0.origin == o }) { return hit }
        return hits.max { Self.chapterNum($0.lastChapter) < Self.chapterNum($1.lastChapter) } ?? hits[0]
    }

    /// 归一化书名：去掉空白与常见标点，统一小写（英文）
    static func normalize(_ s: String) -> String {
        let drop: Set<Character> = [" ", "\t", "　", "·", "・", "-", "－", "_", "（", "）",
                                    "(", ")", "【", "】", "[", "]", "《", "》", ":", "：",
                                    "!", "！", "?", "？", ".", "。", ",", "，"]
        return String(s.filter { !drop.contains($0) }).lowercased()
    }

    /// 从章节文本里抽数字（「更新至 第156话」→ 156），用于排序
    static func chapterNum(_ s: String) -> Int {
        var best = 0, cur = ""
        for ch in s {
            if ch.isNumber {
                cur.append(ch)
            } else {
                if let v = Int(cur), v > best { best = v }
                cur = ""
            }
        }
        if let v = Int(cur), v > best { best = v }
        return best
    }
}

extension SearchResult {
    /// 章节数（排序用）
    var chapterNumber: Int { SearchGroup.chapterNum(lastChapter) }
}

/// 分组 + 排序（搜索结果的展示变换）
enum SearchOrganizer {

    /// 按书名聚合去重（保留多源命中），返回分组
    static func group(_ results: [SearchResult]) -> [SearchGroup] {
        var byKey: [String: [SearchResult]] = [:]
        var order: [String] = []
        for r in results {
            let k = SearchGroup.normalize(r.name.isEmpty ? r.noteUrl : r.name)
            if byKey[k] == nil { order.append(k) }
            byKey[k, default: []].append(r)
        }
        return order.compactMap { k in
            guard let hits = byKey[k], !hits.isEmpty else { return nil }
            return SearchGroup(key: k, displayName: hits[0].name, hits: hits)
        }
    }

    /// 排序
    static func sort(_ groups: [SearchGroup], by: SearchSort, keyword: String = "") -> [SearchGroup] {
        switch by {
        case .default:
            // 综合：多源命中的排前面，其次章节数多的
            return groups.sorted {
                if $0.hits.count != $1.hits.count { return $0.hits.count > $1.hits.count }
                return $0.primary().chapterNumber > $1.primary().chapterNumber
            }
        case .source:
            return groups.sorted { $0.primary().originName < $1.primary().originName }
        case .name:
            return groups.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .chapter:
            return groups.sorted { $0.primary().chapterNumber > $1.primary().chapterNumber }
        case .relevance:
            // 匹配度：书名完全等于关键词 > 以关键词开头 > 包含
            func score(_ g: SearchGroup) -> Int {
                let n = SearchGroup.normalize(g.displayName)
                let k = SearchGroup.normalize(keyword)
                if n == k { return 3 }
                if n.hasPrefix(k) { return 2 }
                if n.contains(k) { return 1 }
                return 0
            }
            return groups.sorted {
                let a = score($0), b = score($1)
                if a != b { return a > b }
                return $0.hits.count > $1.hits.count
            }
        }
    }

    /// 只保留某个源的结果
    static func filter(_ groups: [SearchGroup], origin: String?) -> [SearchGroup] {
        guard let origin, !origin.isEmpty else { return groups }
        return groups.compactMap { g in
            let hits = g.hits.filter { $0.origin == origin }
            guard !hits.isEmpty else { return nil }
            return SearchGroup(key: g.key, displayName: g.displayName, hits: hits)
        }
    }
}
