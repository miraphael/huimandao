import Combine
import Foundation

/// 漫画详情的一次用户会话：负责首屏加载、章节补全、刷新与竞态保护。
///
/// ComicEngine 负责请求和规则解析；本类负责同一个详情页面生命周期内的
/// 状态切换。View 不再自己编排两个 detail() 请求，也不直接维护异步写回竞态。
@MainActor
final class DetailSession: ObservableObject {
    enum State: Equatable {
        case idle
        case loadingFirstPage
        case enrichingChapters
        case refreshing
        case loaded
        case failed
    }

    @Published private(set) var info: ComicInfo?
    @Published private(set) var state: State = .idle

    // 换源/多源核验状态（与当前详情同属一个会话）。
    @Published private(set) var alternatives: [SearchResult] = []
    @Published private(set) var chapterCounts: [String: Int] = [:]
    @Published private(set) var isSearchingAlternatives = false
    @Published private(set) var isProbingAlternatives = false
    @Published private(set) var didSearchAlternatives = false

    /// 首次加载和显式刷新显示加载状态；后台补全不挡住页面交互。
    var isLoading: Bool {
        state == .loadingFirstPage || state == .refreshing
    }

    var isEnrichingChapters: Bool { state == .enrichingChapters }

    private let noteUrl: String
    private let origin: String
    private let noteHeaders: [String: String]
    private var requestID = UUID()
    private var alternativeSearchID = UUID()
    private var enrichmentTask: Task<Void, Never>?

    init(noteUrl: String, origin: String, noteHeaders: [String: String] = [:]) {
        self.noteUrl = noteUrl
        self.origin = origin
        self.noteHeaders = noteHeaders
    }

    /// 首屏只解析第一页，先让用户看到简介与可读章节；后台再补完整章节列表。
    /// 重复调用是安全的（SwiftUI `.task` 重入、页面重新出现时不会重复请求）。
    func loadIfNeeded() async {
        guard info == nil else { return }
        guard state == .idle || state == .failed else { return }

        let id = UUID()
        requestID = id
        state = .loadingFirstPage

        let firstPage = await ComicEngine.shared.detail(
            noteUrl: noteUrl,
            origin: origin,
            extraHeaders: noteHeaders,
            skipPagination: true)
        guard requestID == id else { return }
        guard !Task.isCancelled else {
            state = .idle
            return
        }

        info = firstPage
        guard !Self.isFailure(firstPage) else {
            state = .failed
            return
        }
        ComicRepository.shared.addHistory(info: firstPage)

        // 🔴 **只有「首屏可能不完整」时才补全**（2026-10-29「更快更精确」）。
        //    补全会翻页的条件只有两个：源有 `ruleChapterUrlNext`，或详情页有分页痕迹。
        //    两个都不成立时，补全必然返回一模一样的列表 —— 图库 2672 章实测白等 2.1 秒
        //    （真机日志原话：`章节补全：首屏 2672 章 → 完整 2672 章（未替换）`）。
        let worthEnrich = await ComicEngine.shared.needsChapterEnrichment(
            noteUrl: noteUrl, origin: origin)
        guard requestID == id, !Task.isCancelled else { return }

        guard worthEnrich else {
            DiagLog.event("detail", "enrich", "首屏章节已完整（无分页线索）→ 跳过补全")
            state = .loaded
            return
        }

        state = .enrichingChapters

        enrichmentTask?.cancel()
        enrichmentTask = Task { [weak self] in
            guard let self else { return }
            await self.loadCompleteDetails(requestID: id, firstPage: firstPage)
        }
    }

    /// 忽略缓存强制刷新；旧详情在请求期间保留，成功后再整体替换。
    func refresh() async {
        enrichmentTask?.cancel()
        enrichmentTask = nil

        let id = UUID()
        requestID = id
        state = .refreshing
        let refreshed = await ComicEngine.shared.detail(
            noteUrl: noteUrl,
            origin: origin,
            extraHeaders: noteHeaders,
            forceRefresh: true)
        guard requestID == id else { return }
        guard !Task.isCancelled else {
            state = info == nil ? .idle : .loaded
            return
        }

        if Self.isFailure(refreshed) {
            // 强刷失败不抹掉当前可用详情；首次加载时则保留失败诊断供 UI 展示。
            if info == nil { info = refreshed }
            state = .failed
            return
        }
        info = refreshed
        state = .loaded
    }

    /// 搜索其他图源，并并发核验前 12 个候选的真实章节数。
    /// 解析仍由 ComicEngine 完成；本会话负责流式聚合、排除当前源、进度和取消竞态。
    func findAlternatives(name: String, excludingOrigin: String) async {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !isSearchingAlternatives else { return }

        let id = UUID()
        alternativeSearchID = id
        isSearchingAlternatives = true
        isProbingAlternatives = false
        didSearchAlternatives = false
        defer {
            if alternativeSearchID == id {
                isSearchingAlternatives = false
                isProbingAlternatives = false
            }
        }

        let result = await ComicEngine.shared.search(title) { [weak self] batch in
            Task { @MainActor [weak self] in
                self?.mergeAlternatives(batch, title: title,
                                        excludingOrigin: excludingOrigin, requestID: id)
            }
        }
        guard alternativeSearchID == id, !Task.isCancelled else { return }
        mergeAlternatives(result, title: title, excludingOrigin: excludingOrigin, requestID: id)
        didSearchAlternatives = true
        await probeAlternativeChapters(requestID: id)
    }

    /// 取消当前换源搜索/章节核验；晚到的批次由 request id 丢弃。
    func cancelAlternativeSearch() {
        alternativeSearchID = UUID()
        isSearchingAlternatives = false
        isProbingAlternatives = false
    }

    /// 使当前详情和换源请求的迟到结果失效，并停止后台补全。
    func cancel() {
        requestID = UUID()
        enrichmentTask?.cancel()
        enrichmentTask = nil
        cancelAlternativeSearch()
        state = info == nil ? .idle : .loaded
    }

    private func mergeAlternatives(_ batch: [SearchResult], title: String,
                                   excludingOrigin: String, requestID id: UUID) {
        guard alternativeSearchID == id else { return }
        var known = Set(alternatives.map(\.id))
        for hit in batch where (hit.name.contains(title) || title.contains(hit.name))
            && hit.origin != excludingOrigin && known.insert(hit.id).inserted {
            alternatives.append(hit)
        }
    }

    private func probeAlternativeChapters(requestID id: UUID) async {
        let targets = Array(alternatives.prefix(12))
        guard !targets.isEmpty else { return }
        isProbingAlternatives = true
        chapterCounts = [:]

        // 以 4 个为一批，限制并发，避免同时冲击过多图源。
        var offset = 0
        while offset < targets.count {
            guard alternativeSearchID == id, !Task.isCancelled else { return }
            let end = min(offset + 4, targets.count)
            let batch = Array(targets[offset..<end])
            let counts = await withTaskGroup(of: (String, Int).self) { group in
                for hit in batch {
                    let hitID = hit.id
                    let hitUrl = hit.noteUrl
                    let hitOrigin = hit.origin
                    let headers = hit.noteHeaders
                    group.addTask {
                        // ── 两个改动都是为了「切源一直转圈」（2026-10-28 用户实测）──
                        //
                        // ① `skipPagination: true`
                        //    核验只需要回答「这个源有没有章节」，不需要完整章节列表。
                        //    而分页探测恰恰是最慢的一段：每个源要多发 2~5 次请求，
                        //    慢站单源就能吃掉 20 秒。12 个候选串下来就是两分钟。
                        //
                        // ② 8 秒硬上限
                        //    详情页主取数最坏是 15s + 30s（首次+重试）。没有上限时，
                        //    一个坏源能让整批停在原地 —— 用户看到的就是「一直加载」。
                        //    超时返回 -1（未核验），列表里标出来，而不是让它消失。
                        let count = await AsyncTimeout.run(seconds: 8, fallback: -1) {
                            let detail = await ComicEngine.shared.detail(
                                noteUrl: hitUrl, origin: hitOrigin,
                                extraHeaders: headers, skipPagination: true)
                            return detail.chapters.count
                        }
                        return (hitID, count)
                    }
                }
                var values: [(String, Int)] = []
                for await value in group { values.append(value) }
                return values
            }
            guard alternativeSearchID == id, !Task.isCancelled else { return }
            for (hitID, count) in counts { chapterCounts[hitID] = count }
            offset = end
        }
    }

    private func loadCompleteDetails(requestID id: UUID, firstPage: ComicInfo) async {
        // ⚡️ 补全阶段复用首屏解析好的元信息，只重新解析**章节列表**。
        // 首屏已经串行 await 过 7 个元信息字段（含 JS 规则时相当慢），补全再解析一遍
        // 纯属重复劳动 —— 表现为「详情页首屏出来了，但章节还在转很久」。
        // 传 reuseMetadataFrom 让引擎跳过元信息段，直接进章节解析（含分页探测）。
        let complete = await ComicEngine.shared.detail(
            noteUrl: noteUrl,
            origin: origin,
            extraHeaders: noteHeaders,
            reuseMetadataFrom: firstPage)
        guard requestID == id, !Task.isCancelled else { return }

        // 保持现有行为：只在完整请求确实解析出更多章节时替换首屏结果。
        // 网络异常/规则暂时失败时，避免把已显示的简介和章节抹掉。
        //
        // 🔎 插桩：用户报「章节不全」时，这一条就是判据 ——
        //    首屏 N 章 / 补全 M 章。若 M 明显大于 N 却没替换（或 M 也很小），
        //    说明是「分页没探测到」而不是「解析失败」，两者修法完全不同。
        DiagLog.event("detail", "enrich",
                      "章节补全：首屏 \(firstPage.chapters.count) 章 → 完整 \(complete.chapters.count) 章"
                      + (complete.chapters.count > firstPage.chapters.count ? "（已替换）" : "（未替换）"))
        if complete.chapters.count > firstPage.chapters.count {
            info = complete
        }
        let settled = info ?? complete
        state = Self.isFailure(settled) ? .failed : .loaded
        enrichmentTask = nil
    }

    private static func isFailure(_ info: ComicInfo) -> Bool {
        !info.diagnosis.isEmpty
            && info.name.isEmpty
            && info.author.isEmpty
            && info.coverUrl.isEmpty
            && info.introduce.isEmpty
            && info.chapters.isEmpty
    }
}
