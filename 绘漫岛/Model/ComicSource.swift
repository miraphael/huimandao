import Foundation

/// 图源数据模型 —— 对应 ComicSourceBean / Legado 漫画书源 JSON 字段。
/// 仅承载图源元数据、规则和 Codable 转换；URL/解密/导入服务留在 Core。
struct ComicSource: Codable, Identifiable, Hashable {
    var bookSourceType: String? = "漫画"
    var bookSourceUrl: String = ""
    var bookSourceName: String = ""
    var bookSourceGroup: String? = nil
    var bookSingleThread: String? = nil
    var bookDelayTime: String? = nil
    var enable: Bool? = true
    var weight: Int? = 0
    var serialNumber: Int? = 0
    var lastUpdateTime: Int64? = 0
    var checkUrl: String? = nil
    var httpUserAgent: String? = nil
    var loginUrl: String? = nil
    var loginUrlResult: String? = nil
    var sourceRemark: String? = nil
    /// Legado 全局请求头 JSON 字符串。
    var header: String? = nil

    var ruleFindUrl: String? = nil
    var ruleSearchUrl: String? = nil
    var ruleSearchUrlNext: String? = nil
    var ruleSearchList: String? = nil
    var ruleSearchName: String? = nil
    var ruleSearchAuthor: String? = nil
    var ruleSearchKind: String? = nil
    var ruleSearchLastChapter: String? = nil
    var ruleSearchCoverUrl: String? = nil
    var ruleSearchCoverDecoder: String? = nil
    var ruleSearchNoteUrl: String? = nil

    var ruleBookName: String? = nil
    var ruleBookAuthor: String? = nil
    var ruleBookKind: String? = nil
    var ruleBookLastChapter: String? = nil
    var ruleBookUrlPattern: String? = nil
    var ruleIntroduce: String? = nil
    var ruleCoverUrl: String? = nil
    var ruleCoverDecoder: String? = nil

    var ruleChapterId: String? = nil
    var ruleChapterList: String? = nil
    var ruleChapterName: String? = nil
    var ruleChapterUrl: String? = nil
    var ruleChapterUrlNext: String? = nil
    var ruleChapterParentId: String? = nil
    var ruleChapterParentName: String? = nil

    var ruleContentUrl: String? = nil
    var ruleContentUrlNext: String? = nil
    var ruleBookContent: String? = nil
    var ruleBookContentDecoder: String? = nil

    /// 声明式「多步内容流」（见 `ContentFlowEngine`）。
    /// 用于卡拉漫画这类「抽 hex → 取 token → 带 token 取阅读器 → 出图」的多级挑战流。
    /// 图源 JSON 里写一段数组即可，无需改 Swift 代码。无此字段的源完全不受影响。
    var ruleContentFlow: [ContentFlowStep]? = nil

    var id: String { bookSourceUrl }
    var isEnabled: Bool { enable ?? true }

    /// 宽容解码：缺失或类型不符的字段不使整个图源导入失败。
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookSourceType = try? c.decodeIfPresent(String.self, forKey: .bookSourceType)
        bookSourceUrl = (try? c.decodeIfPresent(String.self, forKey: .bookSourceUrl)) ?? ""
        bookSourceName = (try? c.decodeIfPresent(String.self, forKey: .bookSourceName)) ?? ""
        func s(_ k: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil }
        bookSourceGroup = s(.bookSourceGroup)
        bookSingleThread = s(.bookSingleThread)
        bookDelayTime = s(.bookDelayTime)
        enable = (try? c.decodeIfPresent(Bool.self, forKey: .enable)) ?? true
        weight = (try? c.decodeIfPresent(Int.self, forKey: .weight)) ?? 0
        serialNumber = (try? c.decodeIfPresent(Int.self, forKey: .serialNumber)) ?? 0
        lastUpdateTime = (try? c.decodeIfPresent(Int64.self, forKey: .lastUpdateTime)) ?? 0
        checkUrl = s(.checkUrl)
        httpUserAgent = s(.httpUserAgent)
        loginUrl = s(.loginUrl)
        loginUrlResult = s(.loginUrlResult)
        sourceRemark = s(.sourceRemark)
        header = s(.header)
        ruleFindUrl = s(.ruleFindUrl)
        ruleSearchUrl = s(.ruleSearchUrl)
        ruleSearchUrlNext = s(.ruleSearchUrlNext)
        ruleSearchList = s(.ruleSearchList)
        ruleSearchName = s(.ruleSearchName)
        ruleSearchAuthor = s(.ruleSearchAuthor)
        ruleSearchKind = s(.ruleSearchKind)
        ruleSearchLastChapter = s(.ruleSearchLastChapter)
        ruleSearchCoverUrl = s(.ruleSearchCoverUrl)
        ruleSearchCoverDecoder = s(.ruleSearchCoverDecoder)
        ruleSearchNoteUrl = s(.ruleSearchNoteUrl)
        ruleBookName = s(.ruleBookName)
        ruleBookAuthor = s(.ruleBookAuthor)
        ruleBookKind = s(.ruleBookKind)
        ruleBookLastChapter = s(.ruleBookLastChapter)
        ruleBookUrlPattern = s(.ruleBookUrlPattern)
        ruleIntroduce = s(.ruleIntroduce)
        ruleCoverUrl = s(.ruleCoverUrl)
        ruleCoverDecoder = s(.ruleCoverDecoder)
        ruleChapterId = s(.ruleChapterId)
        ruleChapterList = s(.ruleChapterList)
        ruleChapterName = s(.ruleChapterName)
        ruleChapterUrl = s(.ruleChapterUrl)
        ruleChapterUrlNext = s(.ruleChapterUrlNext)
        ruleChapterParentId = s(.ruleChapterParentId)
        ruleChapterParentName = s(.ruleChapterParentName)
        ruleContentUrl = s(.ruleContentUrl)
        ruleContentUrlNext = s(.ruleContentUrlNext)
        ruleBookContent = s(.ruleBookContent)
        ruleBookContentDecoder = s(.ruleBookContentDecoder)
        ruleContentFlow = (try? c.decodeIfPresent([ContentFlowStep].self, forKey: .ruleContentFlow))
    }

    private enum CodingKeys: String, CodingKey {
        case bookSourceType, bookSourceUrl, bookSourceName, bookSourceGroup, bookSingleThread, bookDelayTime
        case enable, weight, serialNumber, lastUpdateTime, checkUrl, httpUserAgent, loginUrl, loginUrlResult, sourceRemark
        case header
        case ruleFindUrl, ruleSearchUrl, ruleSearchUrlNext, ruleSearchList, ruleSearchName, ruleSearchAuthor
        case ruleSearchKind, ruleSearchLastChapter, ruleSearchCoverUrl, ruleSearchCoverDecoder, ruleSearchNoteUrl
        case ruleBookName, ruleBookAuthor, ruleBookKind, ruleBookLastChapter, ruleBookUrlPattern, ruleIntroduce
        case ruleCoverUrl, ruleCoverDecoder, ruleChapterId, ruleChapterList, ruleChapterName, ruleChapterUrl
        case ruleChapterUrlNext, ruleChapterParentId, ruleChapterParentName, ruleContentUrl, ruleContentUrlNext
        case ruleBookContent, ruleBookContentDecoder, ruleContentFlow
    }

    var groupList: [String] {
        (bookSourceGroup ?? "").split(whereSeparator: { ",;，；".contains($0) }).map(String.init).filter { !$0.isEmpty }
    }

    var delayMs: Int { Int(bookDelayTime ?? "") ?? 0 }
    var singleThread: Bool { bookSingleThread != nil && bookSingleThread != "否" }
}
