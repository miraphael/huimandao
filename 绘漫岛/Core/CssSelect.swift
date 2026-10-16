import Foundation
import SwiftSoup

/// ──────────────────────────────────────────────────────────────────────────
/// CSS 选择器执行 —— 补上 Legado 的 `|`（或）语法
///
/// ## 为什么需要它（2026-10 定位到的全局性根因）
/// Legado 的规则语法里 `|` 表示「或」：
/// ```
/// a[href*='photos-slide-aid-'] | a[href*='photos-list-aid-']
/// ```
/// 但 **CSS 里 `|` 是命名空间分隔符**（`abc|def` ⇔ 命名空间 abc 下的 def）。
/// 读 SwiftSoup 的 `QueryParser.byTag()` 可确认它只做这一件事：
/// ```swift
/// if (tagName.contains("|")) { tagName = tagName.replacingOccurrences(of: "|", with: ":") }
/// ```
/// 而 `combinators = [",", ">", "+", "~", " "]` **不含 `|`**，于是解析到 `|`
/// 时既不是 word、也不是 `[`、也不是 `*` → 直接抛
/// `SelectorParseException: Could not parse query`。
/// 而调用点全都写成 `(try? el.select(css)) ?? Elements()` —— **异常被静默吞掉，
/// 结果是「0 个元素」，看起来就像「站点改版了 / 规则失效了」**。
///
/// ## 影响面（对内置 501 个启用源统计）
/// | 字段 | 含 `|` 的启用源数 |
/// |---|---|
/// | `ruleSearchList` | **84** |
/// | `ruleIntroduce` | 29 |
/// | `ruleBookContent` | 7 |
/// | `ruleChapterName` | 6 |
/// | `ruleBookName` | 5 |
/// | `ruleChapterList` | 3（含「紳士漫畫」，用户实测「章节解析不出来」）|
/// | `ruleCoverUrl` | 2 |
/// | `ruleContentUrl` | 1 |
///
/// 这解释了两类长期投诉：**「章节解析为 0」**（章节列表规则失效）与
/// **「搜索出来一堆不相干的」**（84 个源的搜索列表规则失效后落到兜底路径，
/// 把导航/侧栏链接当成了搜索结果）。
///
/// ## 语义对齐
/// Legado 的 `AnalyzeRule` 遇到 `|` 是把各分支分别求值再**合并**。
/// 这里照做：按顶层 `|` 切分 → 各自 `select` → 按元素身份去重合并。
/// ⚠️ 只切**顶层** `|`：`[href|=x]`（属性运算符）与 `||`（JS 或）都不动。
/// ──────────────────────────────────────────────────────────────────────────
enum CssSelect {

    /// 在一个元素/文档上执行选择器，支持 Legado 的 `|` 或语法。
    ///
    /// 单分支（绝大多数情况）时零额外开销，直接透传 `select`。
    static func all(_ root: Element, _ selector: String) -> [Element] {
        let s = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return [] }
        let parts = splitOr(s)
        if parts.count <= 1 { return (try? root.select(s))?.array() ?? [] }

        var out: [Element] = []
        var seen = Set<ObjectIdentifier>()
        for p in parts where !p.isEmpty {
            // ⚠️ 单分支失败不能影响其他分支：Legado 同样是「能算出来的都算」
            guard let els = try? root.select(p) else { continue }
            for e in els.array() where seen.insert(ObjectIdentifier(e)).inserted {
                out.append(e)
            }
        }
        return out
    }

    /// 按**顶层** `|` 切分。
    ///
    /// 不切的情况：
    ///   · `||` —— JS 的「或」，切成两半会毁掉表达式
    ///   · `[href|=x]` —— CSS 属性运算符，`|` 在方括号内（深度 > 0）
    ///   · 引号内 —— `a[href*='x|y']`
    static func splitOr(_ s: String) -> [String] {
        var parts: [String] = []
        var cur = ""
        var depth = 0
        var quote: Character? = nil
        let chars = Array(s)
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                cur.append(c)
                if c == q { quote = nil }
                i += 1
                continue
            }
            switch c {
            case "'", "\"":
                quote = c
                cur.append(c)
            case "[", "(":
                depth += 1
                cur.append(c)
            case "]", ")":
                depth = max(0, depth - 1)
                cur.append(c)
            case "|" where depth == 0:
                // ⚠️ `||`（JS 的或）不能切：必须同时看前后一个字符。
                //    只看前一个不够 —— 第一个 `|` 的前面不是 `|`，会被误切。
                let nextIsPipe = (i + 1 < chars.count && chars[i + 1] == "|")
                let prevIsPipe = (i > 0 && chars[i - 1] == "|")
                if !nextIsPipe, !prevIsPipe {
                    parts.append(cur)
                    cur = ""
                    i += 1
                    continue
                }
                cur.append(c)
            default:
                cur.append(c)
            }
            i += 1
        }
        parts.append(cur)

        let cleaned = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? [s] : cleaned
    }
}
