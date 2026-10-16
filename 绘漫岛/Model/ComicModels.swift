import Foundation

/// 漫画详情（运行时模型）
///
/// 只承载跨 UI / Engine / Store 传递的数据，不在仓库或页面文件里定义，
/// 让依赖方向保持 `UI → Session → Engine/Store → Model`。
struct ComicInfo {
    var name = ""
    var noteUrl = ""       // 详情页 URL
    var origin = ""        // 图源 URL
    var chapterUrl = ""    // 章节列表页 URL
    var coverUrl = ""
    var author = ""
    var introduce = ""
    var kind = ""
    var lastChapter = ""
    var chapters: [Chapter] = []
    var variables: [String: String] = [:]
    /// 加载失败时的可行动诊断（网络层 / HTTP 状态 / 规则层分别说明）。
    var diagnosis = ""

    struct Chapter: Identifiable, Equatable {
        static func == (lhs: Chapter, rhs: Chapter) -> Bool {
            lhs.url == rhs.url && lhs.name == rhs.name
        }

        var id: String { url }
        var name = ""
        var url = ""
        var group = ""      // 分卷名（ruleChapterParentName）
    }
}

/// 搜索结果（模型层）。`id` 是派生值，不属于 memberwise initializer 参数。
struct SearchResult: Identifiable {
    /// JS 源 origin 的统一前缀：`js://<manifest.id>`。
    ///
    /// ⚠️ 常量放在**模型层**而不是各处手写字符串：这个前缀同时在
    ///    `JSProvider.sourceOrigin`（生产）、`SourceProviderRegistry.displayName`
    ///    （翻译）、搜索页/详情页（打「JS」徽标）三处出现 ——
    ///    散落成字面量时改一处漏两处是迟早的事。
    static let jsOriginPrefix = "js://"

    var id: String { "\(origin)|\(noteUrl)" }
    var name = ""
    var author = ""
    var kind = ""
    var coverUrl = ""
    var lastChapter = ""
    var introduce = ""
    var noteUrl = ""
    var origin = ""
    var originName = ""
    var urlNext: String? = nil
    var noteHeaders: [String: String] = [:]

    /// 是否来自 JS 类源。UI 用它决定要不要打「JS」徽标（行为差异大，需让用户对号入座）。
    var isJSSource: Bool { origin.hasPrefix(Self.jsOriginPrefix) }
}
