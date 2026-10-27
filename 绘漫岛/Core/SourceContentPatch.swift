import Foundation

/// 一次性数据补丁：给内置图源补上**正文图规则**。
///
/// ## 为什么需要它（2026-10-27 查出的真 bug）
/// 我们导出的图源 JSON 里一直写的是 `ruleContentList`，但 `ComicSource`
/// **没有这个字段** —— `init(from:)` 只挑自己认识的 key，多余的 key 被静默丢弃。
/// 于是 6 个源在库里 `ruleBookContent` 全是 nil，正文图只能靠
/// 「万用扫 `<img>`」兜底；对「图由 JS 生成/注入」的站（卡拉、W漫画、漫画网）
/// 就是**打开白屏、一直重试也没图**。
///
/// ## 做法
/// 按域名匹配，**只补空字段**（用户自己配过规则的源一律不动），补完广播刷新。
/// 规则以 JSON 文本形式内联，走 `JSONDecoder` 解成 `ContentFlowStep`
/// —— 和从文件导入的路径完全一致，不另造一套构造器。
enum SourceContentPatch {

    /// 只跑一次；以后要再补新规则时把版本号 +1。
    private static let flagKey = "patch.contentRules.v1"

    static func applyIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        var changed: [String] = []
        for var s in ComicRepository.shared.allSources() {
            guard let host = URL(string: s.bookSourceUrl)?.host?.lowercased(),
                  let patch = table.first(where: { host.contains($0.host) }) else { continue }
            let hasBook = !(s.ruleBookContent ?? "").isEmpty
            let hasFlow = (s.ruleContentFlow?.count ?? 0) > 0
            guard !hasBook, !hasFlow else { continue }   // 有规则就不动

            var applied = false
            if let book = patch.book, !book.isEmpty {
                s.ruleBookContent = book
                applied = true
            }
            if let json = patch.flowJSON, let flow = decodeFlow(json) {
                s.ruleContentFlow = flow
                applied = true
            }
            guard applied else { continue }
            ComicRepository.shared.saveSource(s)
            changed.append(s.bookSourceName)
        }

        UserDefaults.standard.set(true, forKey: flagKey)
        if !changed.isEmpty {
            NotificationCenter.default.post(name: .hmdSourcesChanged, object: nil)
        }
        DiagLog.event("patch", "contentRules", "补齐正文规则：\(changed.isEmpty ? "无（都已有规则）" : changed.joined(separator: "、"))")
    }

    // MARK: - 规则表

    private struct Patch {
        let host: String
        var book: String? = nil
        var flowJSON: String? = nil
    }

    private static let table: [Patch] = [
        // 卡拉漫画：MacPlayer 加密播放器 → 三级挑战流
        // 章节页 `player_aaaa.url`（144 hex）→ /play/min/{hex} 拿 token
        // → 带 omo_token + cf_verify 再取 → `img.comic-img[data-src]`
        // 实测：209 张，首图 200 / 295KB
        Patch(host: "kalamanhua.com", flowJSON: kalaFlowJSON),

        // W漫画：`var num = eval("17")` + `var pasd = "…/"`
        // → 图片就是 pasd + i + ".webp"。HTML 里一个 <img src> 都没有。
        Patch(host: "wmanhua.com", flowJSON: wmanhuaFlowJSON),

        // 瓜子：正文图有独立 class，不配规则会被 8 张「推荐封面」污染
        Patch(host: "guazimanhua.com", book: "tag.img.reading-image@src"),

        // 图库：懒加载在 data-original，去掉 query 后需 Referer（源 header 已配）
        Patch(host: "tuku.cc", book: "tag.img@data-original##\\?.*"),

        // 包子：图统一在 static-tw 图床，先按 host 改写
        Patch(host: "cnbzmg.com",
              book: "tag.img@src##https://s\\d+\\.bzcdn\\.net##https://static-tw.baozimh.com"),

        // 漫画网：`<div id="pics">` 是空的，由混淆过的 pic-v2.js 填充 →
        // 规则无能为力，交给「正文 0 图 → 内置浏览器渲染」兜底（v184）。
    ]

    /// 卡拉：三级挑战流（与 ContentFlow 文档里的示例一致，字段按实测校正）
    private static let kalaFlowJSON = #"""
    [
      {"input":"chapterHtml",
       "extract":{"hex":"\"url\"\\s*:\\s*\"([0-9a-f]{32,})\""}},
      {"request":{"url":"https://image.kalaimg.top/play/min/{hex}",
                  "headers":{"User-Agent":"{ua}","Referer":"{chapterUrl}"}},
       "extract":{"token":"token\\s*=\\s*['\"]([^'\"]+)['\"]"}},
      {"request":{"url":"https://image.kalaimg.top/play/min/{hex}?cf_verify={token:urlenc}",
                  "headers":{"User-Agent":"{ua}","Referer":"{chapterUrl}"},
                  "cookie":"omo_token={token}"},
       "select":{"regex":"data-src\\s*=\\s*[\"']([^\"']+)[\"']",
                 "base":"https://image.kalaimg.top"}}
    ]
    """#

    /// W漫画：脚本变量直接拼图
    private static let wmanhuaFlowJSON = #"""
    [
      {"input":"chapterHtml",
       "extract":{"pasd":"var\\s+pasd\\s*=\\s*[\"']([^\"']+)[\"']",
                  "num":"var\\s+num\\s*=\\s*eval\\(\\s*[\"'](\\d+)[\"']"}},
      {"select":{"template":"{pasd}{i}.webp","count":"{num}"}}
    ]
    """#

    private static func decodeFlow(_ json: String) -> [ContentFlowStep]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([ContentFlowStep].self, from: data)
    }
}
