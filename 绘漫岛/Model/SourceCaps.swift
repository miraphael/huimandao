import Foundation

/// ──────────────────────────────────────────────────────────────────────────
/// 源能力矩阵 —— 从规则字段推断「这个源到底支持什么」。
///
/// ## 为什么需要（用户反复遇到「点了没反应」）
/// 源的能力**完全由规则字段决定**。但 UI 之前是**假设所有源都支持一切**，
/// 于是不支持的功能点下去**毫无反应**—— 用户不知道是「不支持」还是「坏了」。
/// 有了能力矩阵，UI 可以直接**禁用 / 隐藏**不支持的入口，
/// 或者明确告诉用户「这个源没写搜索规则」。
///
/// ## 设计要点
/// · 只做**静态推断**（读规则字段），**不发网络请求** ——
///   图源列表一屏要显示几十个源，不能每个都去探测。
/// · 与源核的探测结果互补：
///     探测产出的是「站点**真实**的解析结构」
///     这里产出的是「这份**规则声明**了什么能力」
///   两者不一致时，往往就是「规则过时了」的信号（可提示用户重探）。
///
/// ## 字段对照（309 个启用源里的实测覆盖率）
/// · `ruleSearchUrl`          304 / 309
/// · `ruleFindUrl`            285 / 309
/// · `ruleContentUrlNext`      29 / 309   ← 只有这些源声明了正文翻页
/// · `ruleChapterUrlNext`      10 / 309   ← 章节列表翻页
/// · `ruleSearchUrlNext`        5 / 309   ← 搜索翻页
/// ──────────────────────────────────────────────────────────────────────────
struct SourceCaps {

    let search: Bool          // 有搜索规则
    let discover: Bool        // 有发现/栏目规则
    let searchPaging: Bool    // 搜索能翻页
    let chapterPaging: Bool   // 章节列表能翻页
    let contentPaging: Bool   // 正文能翻页（多页章节）
    let hasJS: Bool           // 规则里含 JS
    let needLogin: Bool       // 需要登录
    let cover: Bool           // 能取封面
    let intro: Bool           // 能取简介

    init(_ s: ComicSource) {
        search = !(s.ruleSearchUrl ?? "").isEmpty
        discover = !(s.ruleFindUrl ?? "").isEmpty
        searchPaging = !(s.ruleSearchUrlNext ?? "").isEmpty
        chapterPaging = !(s.ruleChapterUrlNext ?? "").isEmpty
        contentPaging = !(s.ruleContentUrlNext ?? "").isEmpty
        hasJS = Self.containsJS(s)
        needLogin = !(s.loginUrl ?? "").isEmpty
        cover = !(s.ruleCoverUrl ?? "").isEmpty || !(s.ruleSearchCoverUrl ?? "").isEmpty
        intro = !(s.ruleIntroduce ?? "").isEmpty
    }

    /// 规则里有没有 JS（`@js:` / `<js>`）。
    ///
    /// ⚠️ 为什么要知道这个：含 JS 的规则**必须走 JS 引擎**求值，
    ///    在「JS 桥没初始化好」的环境下会静默返回空 —— 又是一个「点了没反应」的来源。
    ///    标出来之后，UI 至少能提示「该源依赖 JS 规则」。
    private static func containsJS(_ s: ComicSource) -> Bool {
        let fields = [s.ruleSearchUrl, s.ruleSearchList, s.ruleSearchName,
                      s.ruleChapterList, s.ruleChapterName, s.ruleContentUrl,
                      s.ruleBookContent, s.ruleCoverUrl, s.ruleIntroduce,
                      s.ruleFindUrl, s.ruleSearchUrlNext, s.ruleChapterUrlNext,
                      s.ruleContentUrlNext]
        for f in fields {
            guard let v = f, !v.isEmpty else { continue }
            if v.contains("@js:") || v.contains("<js>") || v.contains("</js>") { return true }
        }
        return false
    }

    // MARK: - 展示

    /// 图源列表用的能力徽标（只列「支持」的，避免一屏全是灰标）
    var badges: [String] {
        var out: [String] = []
        if search { out.append("搜索") }
        if discover { out.append("发现") }
        if contentPaging { out.append("正文翻页") }
        if chapterPaging { out.append("章节翻页") }
        if searchPaging { out.append("搜索翻页") }
        if hasJS { out.append("JS") }
        if needLogin { out.append("需登录") }
        return out
    }

    /// 一行摘要（诊断页 / 长按菜单用）
    var summary: String {
        badges.isEmpty ? "无可用能力" : badges.joined(separator: " · ")
    }
}

extension ComicSource {
    /// 这个源的能力矩阵（每次算，很轻 —— 只是几个字符串判空）
    var caps: SourceCaps { SourceCaps(self) }
}
