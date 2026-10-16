import Foundation

/// 分页协议类型。它描述「下一页怎么得到」，不承担 HTTP 请求或内容解析。
enum PagingStrategy: Equatable {
    /// 在当前 HTML/JSON 响应上执行图源自带的下一页规则。
    case sourceRule(String)
    /// 从 HTML 的 rel=next / 下一页锚点中发现绝对 URL。
    case linkScan
    /// URL 规则含 searchPage、{{page}} 或页码备选表达式。
    case placeholder
    /// 固定 URL 无占位符时，用受控 query 参数翻页。
    case queryParameter(String)
    /// 当前协议没有安全可用的下一页办法。
    case none
}

/// 分页策略判定与页码 URL fallback。
///
/// 只负责纯规则决策。每种业务仍可按实际协议限制候选策略：例如 JSON 正文 API
/// 不启用 linkScan，offset/cursor API 也不应猜 query 页码。
enum PagingStrategyResolver {
    static func hasSourceRule(_ rule: String?) -> Bool {
        !(rule ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// linkScan 仅适用于 HTML；若 sourceRule 已尝试但未产出可用 URL，可作为回退。
    static func canScanLinks(isHTML: Bool) -> Bool {
        isHTML
    }

    /// 按可靠性返回有序候选。运行时的 sourceRule/linkScan 可能在当前页没有
    /// 下一页值，调用方可继续尝试其后的占位符或页码 fallback。
    static func candidates(sourceRule: String?, urlRule: String,
                           allowsLinkScan: Bool = true,
                           fallbackParameter: String = "page") -> [PagingStrategy] {
        var out: [PagingStrategy] = []
        if hasSourceRule(sourceRule),
           let rule = sourceRule?.trimmingCharacters(in: .whitespacesAndNewlines) {
            out.append(.sourceRule(rule))
        }
        if allowsLinkScan { out.append(.linkScan) }
        if hasPlaceholder(urlRule) {
            out.append(.placeholder)
        } else if isLiteralHTTPURL(urlRule), isSafeParameter(fallbackParameter) {
            out.append(.queryParameter(fallbackParameter))
        }
        if out.isEmpty { out.append(.none) }
        return out
    }

    /// 检测与 AnalyzeUrl 支持的页码变量一致的几类规则写法。
    static func hasPlaceholder(_ rule: String) -> Bool {
        if rule.contains("searchPage") { return true }
        if rule.range(of: "\\{\\{[^}]*page[^}]*\\}\\}", options: .regularExpression) != nil {
            return true
        }
        // AnalyzeUrl 支持 `{p1,p2}` 页码备选；只对包含 URL 的规则检查，
        // 并避开引号/JS/对象块，避免把普通逗号表达式误认成分页表达式。
        guard isLiteralHTTPURL(rule) else { return false }
        return rule.range(of: "\\{[^{}'\":@]*,[^{}'\":@]*\\}",
                          options: .regularExpression) != nil
    }

    /// 对没有显式占位符的 HTTP(S) URL 追加或替换分页参数；规则后缀原样保留。
    static func applyingQueryParameter(_ rule: String, name: String = "page", page: Int) -> String {
        guard page > 0, isSafeParameter(name) else { return rule }
        let markers = ["@Header:", "|char=", ",{", "@Body:"]
        var cut = rule.endIndex
        for marker in markers {
            if let range = rule.range(of: marker), range.lowerBound < cut { cut = range.lowerBound }
        }
        var body = String(rule[..<cut])
        let suffix = String(rule[cut...])
        guard isLiteralHTTPURL(body) else { return rule }

        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "([?&])" + escaped + "=\\d*"
        if let range = body.range(of: pattern, options: .regularExpression) {
            let separator = String(body[range.lowerBound])
            body.replaceSubrange(range, with: separator + name + "=" + String(page))
            return body + suffix
        }
        let separator = body.contains("?") ? "&" : "?"
        body += separator + name + "=" + String(page)
        return body + suffix
    }

    private static func isLiteralHTTPURL(_ rule: String) -> Bool {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isSafeParameter(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }
}

/// 一个资源的一条分页游标。每个搜索词/栏目/作品/章节都应持有独立实例。
///
/// Cursor 只保存状态，不发网络请求。访问环路、最大页数和无进展页数都由此处
/// 统一收敛，业务层可继续决定是否允许 query fallback。
struct PageCursor {
    let scopeKey: String
    let maximumPages: Int
    let maximumNoProgressPages: Int

    private(set) var page: Int
    private(set) var nextURL: String?
    private(set) var visitedURLs: Set<String>
    private(set) var seenItemIDs: Set<String>
    private(set) var consecutiveNoProgressPages: Int
    private(set) var exhausted: Bool

    init(scopeKey: String, maximumPages: Int = 40,
         maximumNoProgressPages: Int = 2) {
        self.scopeKey = scopeKey
        self.maximumPages = max(1, maximumPages)
        self.maximumNoProgressPages = max(1, maximumNoProgressPages)
        self.page = 1
        self.nextURL = nil
        self.visitedURLs = []
        self.seenItemIDs = []
        self.consecutiveNoProgressPages = 0
        self.exhausted = false
        // URL 统一通过 beginRequest 登记，避免初始化时把第 1 页误认为已访问。
    }

    /// 是否允许请求这一页。相同 URL 再次出现即视为分页环路。
    mutating func beginRequest(page requestedPage: Int, url: String) -> Bool {
        guard !exhausted, requestedPage == page, requestedPage <= maximumPages,
              let normalized = Self.normalizedURL(url), !visitedURLs.contains(normalized) else {
            // 重复/迟到调用不应把另一条正在进行的请求标成 exhausted。
            return false
        }
        visitedURLs.insert(normalized)
        return true
    }

    /// 网络失败/取消时释放本次 URL，允许同一页安全重试。
    mutating func cancelRequest(url: String) {
        guard let normalized = Self.normalizedURL(url) else { return }
        visitedURLs.remove(normalized)
    }

    /// 完成当前页，记录结果去重状态并计算下一页游标。
    /// 返回 `true` 代表还有机会继续（已找到 next URL 或可由占位符/query 生成）。
    mutating func finishPage(page completedPage: Int, nextURL candidate: String?,
                             itemIDs: [String], allowsComputedFallback: Bool) -> Bool {
        guard !exhausted, completedPage == page else { return false }

        let previousCount = seenItemIDs.count
        seenItemIDs.formUnion(itemIDs.filter { !$0.isEmpty })
        let madeProgress = seenItemIDs.count > previousCount
        consecutiveNoProgressPages = madeProgress ? 0 : consecutiveNoProgressPages + 1

        guard consecutiveNoProgressPages < maximumNoProgressPages,
              completedPage < maximumPages else {
            exhausted = true
            nextURL = nil
            return false
        }

        page = completedPage + 1
        if let candidate, let normalized = Self.normalizedURL(candidate),
           !visitedURLs.contains(normalized) {
            nextURL = normalized
            return true
        }

        nextURL = nil
        if !allowsComputedFallback {
            exhausted = true
            return false
        }
        return true
    }

    mutating func stop() {
        exhausted = true
        nextURL = nil
    }

    private static func normalizedURL(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased() else { return nil }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        if (scheme == "http" && components.port == 80)
            || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        return components.string
    }
}
