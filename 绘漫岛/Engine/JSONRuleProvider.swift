import Foundation

/// JSON 规则源提供者 —— 把现有 `ComicEngine` 能力适配到 `SourceProvider` 协议。
///
/// ⚠️ **纯转发**：不改变任何现有行为，只把 `ComicEngine` 的公开方法包成统一协议。
///    原有调用点（SearchSession / DetailSession / ReaderView …）仍直接调 `ComicEngine`，
///    不受本文件影响 —— 这是「加适配层而不改坏现有路径」（ARCHITECTURE §9.1）的落地方式。
final class JSONRuleProvider: SourceProvider {
    let source: ComicSource

    var sourceId: String { source.bookSourceUrl }
    var kind: SourceKind { .jsonRule }

    var capabilities: ProviderCapabilities {
        // metadata / detail / chapters / images / headers 是 JSON 规则源的基线能力
        var caps: ProviderCapabilities = [.metadata, .detail, .chapters, .images, .headers]
        // 只有声明了搜索规则才暴露 search —— 否则上层会对不可搜的源发起无谓请求
        if !(source.ruleSearchUrl ?? "").isEmpty { caps.insert(.search) }
        // 有任一下一页规则才声明 nextPage
        if !(source.ruleSearchUrlNext ?? "").isEmpty
            || !(source.ruleChapterUrlNext ?? "").isEmpty
            || !(source.ruleContentUrlNext ?? "").isEmpty {
            caps.insert(.nextPage)
        }
        return caps
    }

    init(source: ComicSource) {
        self.source = source
    }

    func search(keyword: String, page: Int) async throws -> [SearchResult] {
        try require(.search, "search")
        return await ComicEngine.shared.searchOne(source, keyword: keyword, page: page)
    }

    func detail(noteUrl: String, origin: String,
                extraHeaders: [String: String]) async throws -> ComicInfo {
        try require(.detail, "detail")
        return await ComicEngine.shared.detail(noteUrl: noteUrl, origin: origin,
                                               extraHeaders: extraHeaders)
    }

    func chapters(of comic: ComicInfo) async throws -> [ComicInfo.Chapter] {
        try require(.chapters, "chapters")
        // 详情已解析出章节时直接复用（JSON 规则源的章节本来就在详情页里），
        // 避免为了「再取一次章节」重复走一遍网络/缓存。
        if !comic.chapters.isEmpty { return comic.chapters }
        let full = await ComicEngine.shared.detail(noteUrl: comic.noteUrl, origin: comic.origin)
        return full.chapters
    }

    func images(chapterUrl: String, origin: String, page: Int,
                extraHeaders: [String: String]) async throws -> (urls: [String], headers: [String: String]) {
        try require(.images, "images")
        return await ComicEngine.shared.contentWithHeaders(
            chapterUrl: chapterUrl, origin: origin, page: page, headers: extraHeaders)
    }
}
