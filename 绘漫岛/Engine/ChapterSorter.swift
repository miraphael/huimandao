import Foundation

/// 章节智能排序（2026-10-18，v113 定稿）
///
/// ## 为什么必须由引擎来排
/// 详情页那个「正序/倒序」按钮只是视图层 `.reversed()`，而阅读器的「下一章」
/// 按**数组顺序**取下一项 —— 站点给倒序时，「下一章」会往回走。所以排序必须
/// 落在引擎里，排完再交给 UI。
///
/// ## 排法：按「类型 → 季 → 号」升序（稳定）
///
/// 站点给的顺序经常**根本不是章节顺序**（图库漫画《海贼王》实测：第1卷…第160卷、
/// 第368话…、外传…、第1159话…第1168话 混在一起，像是按内部 id 排的），
/// 所以不能「原样保留」，必须真的排一遍。
///
/// | tier | 类型 | 例 |
/// |---|---|---|
/// | 0 | **正文**（话 / 章 / 回） | `第12话`、`第3卷 第5话`、`第二季第1话` |
/// | 1 | **卷**（只有卷号，没有话数） | `第1卷`、`全彩版01卷` |
/// | 2 | **番外类** | `外传：第1话`、`15卷番外`、`特别篇 第2话` |
/// | 3 | 抽不出话数 | `小剧场RPG`、`序` |
///
/// 正文永远在最前（用户反馈：不能让「第1卷」顶在最上面），番外与杂项沉底。
///
/// ⚠️ **能认出话数的不足一半 → 整体放弃排序**（保持站点原顺序）——
///    命名完全没规律的源，任何重排都只会更乱。
enum ChapterSorter {

    struct Key: Comparable {
        /// 0 正文 / 1 卷 / 2 番外 / 3 抽不出
        let tier: Int
        /// 季号（`第二季第1话` → 2），没有季则为 0
        let season: Int
        /// 话数（`第3卷 第5话` → 卷×10000 + 话，保证卷序主导、卷内按话）
        let number: Double
        /// 原始下标 —— 同 key 时保持站点原顺序
        let original: Int

        static func < (a: Key, b: Key) -> Bool {
            if a.tier != b.tier { return a.tier < b.tier }
            if a.season != b.season { return a.season < b.season }
            if a.number != b.number { return a.number < b.number }
            return a.original < b.original
        }
    }

    /// 排序入口（只调顺序，不改内容）
    static func sort(_ chapters: [ComicInfo.Chapter]) -> [ComicInfo.Chapter] {
        guard chapters.count > 1 else { return chapters }
        let keys = chapters.enumerated().map { idx, ch in key(for: ch.name, original: idx) }
        let withNumber = keys.filter { $0.tier < 3 }.count
        // 能认出编号的不到一半 → 这个源命名不规律，别动
        guard withNumber * 2 >= chapters.count else { return chapters }
        let out = zip(chapters, keys).sorted { $0.1 < $1.1 }.map { $0.0 }
        if out.map(\.url) != chapters.map(\.url) {
            DiagLog.event("sort", "order",
                          "章节已重排：首章「\(chapters.first?.name ?? "")」→「\(out.first?.name ?? "")」")
        }
        return out
    }

    // MARK: - 番外标记

    /// 名字里出现这些词 → 归到「番外类」（tier 2），沉到列表末尾。
    ///
    /// ⚠️ 只收**明确的番外词**，不要收裸「特别」——
    ///    实测《海贼王》有一话叫「第738话 托雷波尔军 **特别**干部砂糖」，
    ///    收裸「特别」会把正篇第 738 话扔进番外区。
    private static let extraMarkers = [
        "外传", "外傳", "番外", "特别篇", "特別篇", "小剧场", "小劇場",
        "剧场版", "劇場版", "设定集", "設定集", "附录", "附錄", "后记", "後記",
        "彩蛋", "特典", "短篇", "总集篇", "總集篇",
        // 「OP20周年杂志—特别剧情1-3话」这种周年特辑 —— 不归进番外会按数字 3
        // 排到正文最前面（实测《海贼王》就是这样顶在第一行）。
        "周年",
    ]

    static func isExtra(_ name: String) -> Bool {
        extraMarkers.contains { name.contains($0) }
    }

    // MARK: - 解析

    static func key(for name: String, original: Int) -> Key {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return Key(tier: 3, season: 0, number: 0, original: original) }

        let season = seasonOf(n)
        // 番外优先判（`15卷番外` 既是卷又是番外 → 归番外）
        if isExtra(n) {
            return Key(tier: 2, season: season,
                       number: numberIn(n) ?? 0, original: original)
        }
        // ① 「第3卷 第5话」→ 卷×10000 + 话
        if let v = firstInt(n, pattern: "(\\d+)\\s*卷"),
           let inner = firstDouble(n, pattern: "第?\\s*(\\d+(?:\\.\\d+)?)\\s*[话話章回]") {
            return Key(tier: 0, season: season,
                       number: Double(v) * 10_000 + inner, original: original)
        }
        // ② 只有话数（正文）
        if let x = numberIn(n) {
            return Key(tier: 0, season: season, number: x, original: original)
        }
        // ③ 只有卷号 → 归「卷」层，排在正文之后
        if let v = firstInt(n, pattern: "(\\d+)\\s*卷") {
            return Key(tier: 1, season: season, number: Double(v), original: original)
        }
        return Key(tier: 3, season: 0, number: 0, original: original)
    }

    /// 抽话数：阿拉伯数字 → 中文数字 → 纯数字标题
    private static func numberIn(_ n: String) -> Double? {
        if let x = firstDouble(n, pattern: "第?\\s*(\\d+(?:\\.\\d+)?)\\s*[话話章回]") { return x }
        if let s = firstGroup(n, pattern: "第?\\s*([零一二三四五六七八九十百]+)\\s*[话話章回]"),
           let x = chineseNumber(s) { return Double(x) }
        return Double(n)
    }

    /// 季号：`第2季` / `第二季` / `Season 2` / `S2`
    private static func seasonOf(_ n: String) -> Int {
        if let v = firstInt(n, pattern: "第?\\s*(\\d+)\\s*季") { return v }
        if let s = firstGroup(n, pattern: "第\\s*([零一二三四五六七八九十]+)\\s*季"),
           let v = chineseNumber(s) { return v }
        if let v = firstInt(n, pattern: "(?i)season\\s*(\\d+)") { return v }
        return 0
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
