import Foundation
import SwiftUI

/// ──────────────────────────────────────────────────────────────────────────
/// 搜索模块 · 会话层（SearchSession）
///
/// 职责边界（刻意不把解析逻辑搬进来）：
///   · **解析**仍在 `ComicEngine`（那是引擎的事，详情/栏目也共用）
///   · 本类只管**编排**：多源并发 → 去重聚合 → 排序 → 分页 → 统计
///
/// 为什么要有这一层：
///   原 `SearchView` 把「搜索 / 分页 / 去重 / 展示」全塞在一个 285 行的 View 里，
///   于是出现两个问题（都已实测）：
///     ① 分页状态无处安放 → `page` 只是个 @State 计数，**urlNext 根本没实现**
///     ② 空结果静默返回 → 用户以为按钮坏了
///   拆出会话层后，这两件事都有明确归属，也能单独测。
///
/// 对齐参考实现：绘漫岛的 `SearchComicModel`（多源并发 + `Map<源,urlNext>`）
/// 与 `SearchComicBean`（聚合 + 排序维度）。
/// ──────────────────────────────────────────────────────────────────────────
@MainActor
final class SearchSession: ObservableObject {

    // MARK: - 输出

    @Published private(set) var groups: [SearchGroup] = []
    @Published private(set) var summary = SearchSummary()
    @Published private(set) var searching = false
    @Published private(set) var loadingMore = false
    /// 分页到底 / 失败时的提示（UI 直接显示，不再静默）
    @Published private(set) var moreMessage = ""
    /// 上一次「加载更多」的诊断串（真机反馈时能直接看到发生了什么）
    @Published private(set) var lastMoreDiag = ""
    /// 连续空页次数（≥2 就认为该源确实不支持翻页，不再给「重试」）
    @Published private(set) var emptyStreak = 0

    // MARK: - 输入

    @Published var keyword = ""
    @Published var sort: SearchSort = .default { didSet { regroup() } }
    /// 只看某个源（nil = 全部）
    @Published var filterOrigin: String? { didSet { regroup() } }

    // MARK: - 内部

    private var raw: [SearchResult] = []          // 去重前
    private var searchID = 0
    private var startedAt = Date()
    /// 已加载到第几页（会话级）。
    /// ⚠️ 页码是**会话级**而不是每源独立 —— `ComicEngine.search(page:)` 的签名
    ///    就是全局 page，多源各自维护页码需要改引擎签名，收益不大。
    ///    每源的「下一页地址 / 已访问 URL / 是否到底」统一由 `ComicEngine` 的
    ///    `PageCursor` 维护（key = `SEARCH|<源URL>|<关键词>`），本会话只记全局页码。
    private var loadedPage = 1

    /// 可选的源列表（nil = 用全部启用源）
    var sources: [ComicSource]?

    /// 源名映射（用于按源筛选的下拉）
    var sourceNames: [(origin: String, name: String)] {
        var seen = Set<String>()
        var out: [(String, String)] = []
        for r in raw where !seen.contains(r.origin) {
            seen.insert(r.origin)
            out.append((r.origin, r.originName.isEmpty ? r.origin : r.originName))
        }
        return out.sorted { $0.1 < $1.1 }
    }

    // MARK: - 搜索

    func search(_ kw: String) async {
        let k = kw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        keyword = k
        searchID += 1
        let myID = searchID

        searching = true
        moreMessage = ""
        lastMoreDiag = ""
        emptyStreak = 0
        raw = []
        groups = []
        summary = SearchSummary(keyword: k)
        ComicEngine.shared.resetSearchPaging()
        loadedPage = 1
        startedAt = Date()
        SearchHistory.shared.add(k)

        // 流式：哪个源先返回就先显示（不阻塞 UI）
        var timings: [SourceTiming] = []
        let result = await ComicEngine.shared.search(k, sources: sources, page: 1) { [weak self] batch in
            guard let self else { return }
            Task { @MainActor in
                guard myID == self.searchID else { return }
                self.raw.append(contentsOf: batch)
                // ⚠️ **不要每批都 `regroup()`**。
                //    源有 300~500 个 → 流式回调会触发几百次，而 `regroup()` 每次都
                //    对**当前累计的全部** raw 做「分组（含 normalize 字符串清洗）+ 排序 + 过滤」。
                //    终态 raw 可达 1~2k 条 → 累计约 Σ(1..N) ≈ **30 万次**结果分组，
                //    全部在 `@MainActor` 上跑 —— 直接表现为「搜索时结果区一卡一卡」。
                //    改为 150ms 去抖：期间只追加，静默 150ms 才重排一次。
                self.scheduleRegroup()
            }
        }
        guard myID == searchID else { return }

        // 统计（绘漫岛的 searchTime / 命中数）
        let byOrigin = Dictionary(grouping: result, by: \.origin)
        for (origin, hits) in byOrigin {
            let name = hits.first?.originName ?? origin
            timings.append(SourceTiming(origin: origin, originName: name, ms: 0, count: hits.count))
        }
        let totalMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        summary = SearchSummary(
            keyword: k, totalMs: totalMs,
            sourcesTried: sourceNames.count, sourcesOK: byOrigin.count,
            rawCount: result.count, uniqueCount: Set(result.map(\.id)).count,
            timings: timings.sorted { $0.count > $1.count })

        // 记「最近搜到的书」供「猜你想搜」
        SearchHistory.shared.recordBooks(result.prefix(40).map(\.name))

        raw = result
        regroupTask?.cancel()   // 终态直接重排，取消挂起的去抖任务
        regroup()
        searching = false
    }

    /// 加载下一页。
    ///
    /// 三级策略统一由 `ComicEngine` 的 `PageCursor` 执行：
    ///   ① 上一页响应里提取的 urlNext → 直接请求该地址
    ///   ② 有 searchPage/{{page}} 占位符 → 页码替换
    ///   ③ 都没有 → 自动追加 `&page=N` 兜底（同一 URL 会被游标挡掉，不会白抓）
    func loadMore() async {
        // 🔴 **绝对不要在这里判 `!searching`** —— 这是「加载更多点了没反应」的真正原因。
        //    流式搜索（`onBatch`）让结果提前显示，而 `searching` 要等**全部 300+ 源**
        //    都返回才置 false，慢源能拖 30~60 秒。这段时间用户点「加载更多」
        //    会被 `guard` 静默 return —— 界面上什么都不会发生，连提示都没有。
        //    现在允许并发：分页请求与首次搜索互不干扰
        //    （`ComicEngine` 的 `PageCursor` 按「源 + 关键词」隔离游标，
        //      晚到的第 1 页不会覆盖第 2 页，不同关键词也不会互相串页）。
        guard !loadingMore, !keyword.isEmpty else { return }
        loadingMore = true
        moreMessage = ""
        defer { loadingMore = false }
        let myID = searchID

        let nextPage = loadedPage + 1
        let t0 = Date()
        let more = await ComicEngine.shared.search(keyword, sources: sources, page: nextPage)
        guard myID == searchID else { return }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)

        let existing = Set(raw.map(\.id))
        let fresh = more.filter { !existing.contains($0.id) }
        // 诊断串 —— 真机出问题时让用户截图就能定位（我这边测不到真机网络）
        lastMoreDiag = "第\(nextPage)页 返回\(more.count)条 · 新增\(fresh.count)条 · \(ms)ms"

        if fresh.isEmpty {
            emptyStreak += 1
            if more.isEmpty {
                moreMessage = emptyStreak >= 2
                    ? "第 \(nextPage) 页没有内容 —— 该源可能不支持翻页（已停在第 \(loadedPage) 页）"
                    : "第 \(nextPage) 页没有返回内容，再点一次试试"
            } else {
                moreMessage = "第 \(nextPage) 页返回 \(more.count) 条，但都与已显示的重复（可能已到末页）"
            }
        } else {
            emptyStreak = 0
            raw.append(contentsOf: fresh)
            loadedPage = nextPage
            summary.rawCount += fresh.count
            summary.uniqueCount = Set(raw.map(\.id)).count
            regroup()
        }
    }

    /// 还能不能重试「加载更多」（连续两次空就不给了，免得用户一直点）
    var canRetryMore: Bool { emptyStreak > 0 && emptyStreak < 2 && !moreMessage.isEmpty }

    func clear() {
        searchID += 1
        regroupTask?.cancel()
        raw = []
        groups = []
        summary = SearchSummary()
        moreMessage = ""
        loadedPage = 1
        // ⚠️ **必须在这里复位这三个状态位**。
        //    `searching` 原先只在 `search()` 的末尾置 false，且被
        //    `guard myID == searchID else { return }` 保护 ——
        //    用户点「结束搜索」→ `clear()` 把 `searchID+1`，正在飞行的
        //    `search` 续体随后命中 guard **直接 return，永远走不到复位那一行**。
        //    于是 `searching` 恒为 true 且 `groups.isEmpty` → 界面卡在
        //    「正在搜索全部图源… + 结束搜索」，再点也没用（确定性死锁）。
        searching = false
        loadingMore = false
        emptyStreak = 0
        ComicEngine.shared.resetSearchPaging()
    }

    // MARK: - 分组 / 排序 / 筛选

    /// 流式期间的**去抖重排**（见 `search` 里的说明）。
    private var regroupTask: Task<Void, Never>?

    private func scheduleRegroup() {
        regroupTask?.cancel()
        regroupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            self.regroup()
        }
    }

    private func regroup() {
        let g = SearchOrganizer.group(raw)
        let sorted = SearchOrganizer.sort(g, by: sort, keyword: keyword)
        groups = SearchOrganizer.filter(sorted, origin: filterOrigin)
    }

    /// 单条结果的「同书其他源」（详情页可切换源）
    func alternatives(for result: SearchResult) -> [SearchResult] {
        let k = SearchGroup.normalize(result.name.isEmpty ? result.noteUrl : result.name)
        return SearchOrganizer.group(raw).first { $0.key == k }?.hits ?? [result]
    }

    // MARK: - 展示文案

    var statusLine: String {
        guard !searching else { return "搜索中…" }
        if groups.isEmpty { return "" }
        var s = "\(groups.count) 本"
        if summary.mergedGroups > 0 { s += "（聚合了 \(summary.mergedGroups) 条重复）" }
        s += " · \(summary.sourcesOK)/\(summary.sourcesTried) 源 · \(summary.totalMs)ms"
        return s
    }
}
