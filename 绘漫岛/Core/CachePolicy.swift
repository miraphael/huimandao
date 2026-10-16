import Foundation

/// ──────────────────────────────────────────────────────────────────────────
/// 缓存域 —— **key 组成与 TTL 的唯一真相源**
///
/// ## 为什么必须集中（这是「Cache 横切」的第一片）
/// 缓存 key 之前是散在 6 个调用点手拼的字符串：
/// `"DETAIL|\(origin)|\(noteUrl)"`、`"CHAPTERS|\(origin)|\(url)"` …
/// 任何一处改了格式而另一处没跟上，后果是**读不到自己写的缓存** ——
/// 表现为「缓存完全失效」，但**不会报任何错**，只能靠体感变慢才发现。
/// TTL 同理：以前 `ResponseCache.TTL` 与 key 是两个互不相干的定义，
/// 容易出现「用了 detail 的 key 配 chapters 的 TTL」这种错配。
///
/// 现在：**一个域 = 一个 key 前缀 + 一份 TTL**，调用点只写
/// `CacheDomain.detail.key(origin, noteUrl)`。
///
/// ## key 组成约定
/// ```
/// <DOMAIN>|<关键参数1>|<关键参数2>…
/// ```
/// ⚠️ 参数里**不要放可能变的东西**（时间戳、签名 query、随机数）——
///    那会让缓存永远不命中。要放「同一份内容永远相同」的标识
///    （图源 URL、详情页 URL、章节 URL）。
///
/// ⚠️ `rawValue` 沿用历史字符串（`DETAIL` / `CHAPTERS` / …）：
///    改大小写会让**老用户的磁盘缓存全部失效**（一次性，无害但没必要）。
/// ---------------------------------------------------------------------------
enum CacheDomain: String {
    /// 详情页 HTML（书名/作者/简介/最新章节）
    case detail = "DETAIL"
    /// 章节列表**解析结果**（JSON 数组，不是 HTML）
    case chapterList = "CHAPLIST"
    /// 独立章节页 HTML（`ruleChapterUrl` 指向单独一页时）
    case chapters = "CHAPTERS"
    /// 正文页 HTML（图片列表所在页）
    case content = "CONTENT"
    /// 搜索响应
    case search = "SEARCH"

    /// TTL（量级参考 daisy，但更保守）
    var ttl: TimeInterval {
        switch self {
        case .detail:      return 2 * 3600      // 慢站重抓详情页很贵
        case .chapterList: return 3600          // 章节会更新，折中 1 小时
        case .chapters:    return 3600
        case .content:     return 1800
        case .search:      return 600
        }
    }

    /// 拼 key —— 调用点不再手写分隔符与前缀
    func key(_ parts: String...) -> String {
        ([rawValue] + parts).joined(separator: "|")
    }
}
