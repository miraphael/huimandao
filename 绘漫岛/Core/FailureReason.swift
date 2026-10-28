import Foundation

/// 统一的**失败归因** —— 让每一次失败都能说清"为什么"和"该怎么办"。
///
/// ## 为什么需要它（2026-10-28 设计）
/// 真机日志里 202 条 `[err] img`、156 条 `[fail] cover`，但用户界面上只有四个字
/// 「点击重试」。于是：
///   · 包子图床整站 404（站点故障）→ 用户以为是自己网络问题，一直点重试；
///   · 瓜子被站点拦截 403（要换 Referer）→ 同上；
///   · 飞行模式 → 同上。
/// 三种完全不同的原因，界面长得一模一样 —— 这是"软件不成熟"最直接的观感来源。
///
/// 这个类型把「底层错误」翻译成「人话 + 下一步动作」，UI 只负责展示。
enum FailureReason: String, Equatable {

    case network      // 断网 / DNS 失败 / TLS 握手失败
    case timeout      // 请求超时
    case blocked      // 401 / 403 / 412 / 429 / 挑战页
    case notFound     // 404 / 410（地址失效、图床挂掉）
    case server       // 5xx
    case ruleMiss     // 规则没命中 / 规则产出坏地址
    case needLogin    // 需要登录态
    case decode       // 拿到了字节但不是图片
    case unknown

    /// 一句话说清「发生了什么」（阅读器/封面失败页的主标题）
    var title: String {
        switch self {
        case .network:   return "网络不通"
        case .timeout:   return "请求超时"
        case .blocked:   return "被站点拦截"
        case .notFound:  return "图片地址失效"
        case .server:    return "站点故障"
        case .ruleMiss:  return "规则没匹配上"
        case .needLogin: return "需要登录"
        case .decode:    return "图片数据异常"
        case .unknown:   return "加载失败"
        }
    }

    /// 一句话告诉用户「接下来能做什么」
    var advice: String {
        switch self {
        case .network:   return "检查网络（或切换 Wi-Fi / 流量）后重试"
        case .timeout:   return "等几秒再试；持续超时说明该图床很慢"
        case .blocked:   return "该源需要过验证或登录，可在图源里点「网页登录」"
        case .notFound:  return "这个源的图床已失效，建议换一个源看同一本"
        case .server:    return "站点自己出问题了，过一会儿再试"
        case .ruleMiss:  return "该源规则已过期，建议换源或反馈给我"
        case .needLogin: return "去图源页点「网页登录」过一次"
        case .decode:    return "可能被站点返回了占位/错误页，换个源试试"
        case .unknown:   return "点一下重试；反复失败就换源"
        }
    }

    /// 失败页图标
    var symbol: String {
        switch self {
        case .network:   return "wifi.exclamationmark"
        case .timeout:   return "clock.badge.exclamationmark"
        case .blocked:   return "hand.raised.slash"
        case .notFound:  return "questionmark.folder"
        case .server:    return "exclamationmark.icloud"
        case .ruleMiss:  return "text.magnifyingglass"
        case .needLogin: return "person.badge.key"
        case .decode:    return "doc.questionmark"
        case .unknown:   return "arrow.clockwise"
        }
    }

    /// 是否值得「立刻重试」——站点故障/地址失效这类重试基本没用
    var isWorthRetrying: Bool {
        switch self {
        case .network, .timeout, .server, .unknown: return true
        case .blocked, .notFound, .ruleMiss, .needLogin, .decode: return false
        }
    }

    // MARK: - 归因

    /// HTTP 状态码 → 原因
    static func from(status: Int) -> FailureReason {
        switch status {
        case 401, 402, 403, 405, 407, 412, 429, 451: return .blocked
        case 404, 410:                               return .notFound
        case 500...599:                              return .server
        default:                                     return .unknown
        }
    }

    /// 底层错误 → 原因（优先按 URLError 码，其次按 NSError 域）
    static func from(error: Error) -> FailureReason {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateUntrusted:
                return .network
            case NSURLErrorTimedOut:
                return .timeout
            case NSURLErrorBadServerResponse:
                return .server
            default:
                return .unknown
            }
        }
        // Nuke 把底层错误包成 `ImagePipeline.Error`，文本里带状态码，
        // 这里兜底嗅一下（`Response status code was unacceptable: 404`）。
        let text = String(describing: error)
        if let r = text.range(of: "status code was unacceptable: ") {
            let digits = text[r.upperBound...].prefix { $0.isNumber }
            if let code = Int(digits) { return from(status: code) }
        }
        if text.contains("dataIsEmpty") { return .decode }
        return .unknown
    }
}
