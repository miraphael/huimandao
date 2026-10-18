import Foundation

/// 章节智能排序（2026-10-18，v111 改版）
///
/// **要解决的两个问题**
///   ① **倒序站**：不少站的章节列表是「最新章节在最前」。原样搬过来会让
///      详情页反着显示，更糟的是阅读器「下一章」按数组顺序取 → **往回走**。
///   ② **番外混进正篇**：`外传：第1话` 也叫「第 1 话」，按话数硬排会被塞到
///      正篇最前面（实测图库漫画《海贼王》开头变成 外传1/2/3、OP20周年…）。
///
/// ## 做法（两步，都不打乱站点的分组）
///
/// **第一步：只修方向，不重排内容**
/// 统计相邻两章的「话数」走向：
///   · 明显在**递减**（down > up）→ 这是倒序站，整体 `.reversed()`
///   · 其余情况（递增 / 混杂）→ **原样保留**
///
/// 为什么不直接「按话数全排一遍」（v108 的做法）：站点常有分组，
/// 比如《海贼王》是「第1卷…第160卷」再「第1话…第1168话」，
/// 全局按数字排会变成 第1卷/第1话/第2卷/第2话… 的交叉乱序。
/// 只翻转方向就既修正了倒序站，又保住站点自己的分组。
///
/// **第二步：番外挪到后面（稳定分区）**
/// 按 `tier` 做一次**稳定分区**（不改组内相对顺序）：
///
/// | tier | 含义 | 例 |
/// |---|---|---|
/// | 0 | 正篇（有话数） | `第12话`、`第3卷 第5话` |
/// | 1 | 番外类（名字带番外标记） | `外传：第1话`、`15卷番外`、`特别篇 第2话` |
/// | 2 | 抽不出话数 | `小剧场RPG`、`序` |
///
/// ⚠️ 抽得出数字的章节不足一半时**整体放弃**（保持站点原顺序）——
///    命名完全没规律的源，任何重排都只会更乱。
enum ChapterSorter {

    struct Key {
        /// 0 正篇 / 1 番外类 / 2 抽不出话数
        let tier: Int
        /// 抽到的话数（卷号也折算进来），抽不到为 nil
        let number: Double?
        /// 原始下标
        let original: Int

        var hasNumber: Bool { number != nil }
    }

    /// 排序入口（只调顺序，不改内容）
    static func sort(_ chapters: [ComicInfo.Chapter]) -> [ComicInfo.Chapter] {
        guard chapters.count > 1 else { return chapters }
        let keys = chapters.enumerated().map { idx, ch in key(for: ch.name, original: idx) }
        let withNumber = keys.filter { $0.hasNumber }.count
        // 能认出话数的不到一半 → 这个源命名不规律，别动
        guard withNumber * 2 >= chapters.count else { return chapters }

        // ── 第一步：方向修正（只翻转，不重排）────────────────────────────
        var up = 0, down = 0
        var prev: Double? = nil
        for k in keys {
            guard let n = k.number else { continue }
            if let p = prev {
                if n > p { up += 1 } else if n < p { down += 1 }
            }
            prev = n
        }
        var ordered = chapters
        if down > up {
            ordered = Array(chapters.reversed())
            DiagLog.event("sort", "reverse", "章节列表是倒序（down=\(down) up=\(up)），已整体翻转")
        }

        // ── 第二步：番外类 / 无话数 挪到后面（稳定分区）────────────────────
        // 注意：key 必须按**翻转后**的顺序重算（original 用新下标），
        // 否则分区时会把刚翻转好的顺序又按旧下标拉回去。
        let newKeys = ordered.enumerated().map { idx, ch in key(for: ch.name, original: idx) }
        let out = zip(ordered, newKeys)
            .sorted { a, b in
                if a.1.tier != b.1.tier { return a.1.tier < b.1.tier }
                return a.1.original < b.1.original
            }
            .map { $0.0 }
        if out.map(\.url) != ordered.map(\.url) {
            DiagLog.event("sort", "tier", "番外/无话数章节已挪到列表末尾")
        }
        return out
    }

    // MARK: - 番外标记

    /// 名字里出现这些词 → 归到「番外类」（tier 1），排到正篇之后。
    ///
    /// ⚠️ 只收**明确的番外词**，不要收裸「特别」——
    ///    实测《海贼王》有一话叫「第738话 托雷波尔军 **特别**干部砂糖」，
    ///    收裸「特别」会把正篇第 738 话扔进番外区。
    private static let extraMarkers = [
        "外传", "外傳", "番外", "特别篇", "特別篇", "小剧场", "小劇場",
        "剧场版", "劇場版", "设定集", "設定集", "附录", "附錄", "后记", "後記",
        "彩蛋", "特典", "短篇", "总集篇", "總集篇",
    ]

    static func isExtra(_ name: String) -> Bool {
        extraMarkers.contains { name.contains($0) }
    }

    // MARK: - 解析

    static func key(for name: String, original: Int) -> Key {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return Key(tier: 2, number: nil, original: original) }
        let tier = isExtra(n) ? 1 : 0

        // ① 「第3卷 第5话」→ 卷号×10000 + 话数，保证卷序主导、卷内按话
        if let v = firstInt(n, pattern: "(\\d+)\\s*卷"),
           let inner = firstDouble(n, pattern: "第?\\s*(\\d+(?:\\.\\d+)?)\\s*[话話章回]") {
            return Key(tier: tier, number: Double(v) * 10_000 + inner, original: original)
        }
        // ② 只有卷号（`第12卷`）→ 当成话数用（与「第N话」同一量纲）
        if let v = firstInt(n, pattern: "(\\d+)\\s*卷") {
            return Key(tier: tier, number: Double(v), original: original)
        }
        // ③ 阿拉伯数字 + 话/章/回
        if let x = firstDouble(n, pattern: "第?\\s*(\\d+(?:\\.\\d+)?)\\s*[话話章回]") {
            return Key(tier: tier, number: x, original: original)
        }
        // ④ 中文数字 + 话/章/回
        if let s = firstGroup(n, pattern: "第?\\s*([零一二三四五六七八九十百]+)\\s*[话話章回]"),
           let x = chineseNumber(s) {
            return Key(tier: tier, number: Double(x), original: original)
        }
        // ⑤ 纯数字标题
        if let x = Double(n) {
            return Key(tier: tier, number: x, original: original)
        }
        return Key(tier: 2, number: nil, original: original)
    }

    /// 「一」..「九百九十九」→ 整数
    static func chineseNumber(_ s: String) -> Int? {
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "三": 3, "四": 4,
                                        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        var total = 0
        var cur = 0
        var seen = false
        for ch in s {
            if let d = digits[ch] {
                cur = d
                seen = true
            } else if ch == "十" {
                total += (cur == 0 ? 1 : cur) * 10
                cur = 0
                seen = true
            } else if ch == "百" {
                total += (cur == 0 ? 1 : cur) * 100
                cur = 0
                seen = true
            } else {
                return nil
            }
        }
        return seen ? total + cur : nil
    }

    // MARK: - 正则小工具

    private static func firstGroup(_ text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func firstDouble(_ text: String, pattern: String) -> Double? {
        firstGroup(text, pattern: pattern).flatMap { Double($0) }
    }

    private static func firstInt(_ text: String, pattern: String) -> Int? {
        firstGroup(text, pattern: pattern).flatMap { Int($0) }
    }
}
