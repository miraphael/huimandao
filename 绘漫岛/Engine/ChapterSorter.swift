import Foundation

/// 章节智能排序（2026-10-18）
///
/// **为什么需要**：不少站的章节列表是**倒序**（最新章节在最前）。我们把站点顺序
/// 原样搬过来，会导致两件事同时出错：
///   ① 详情页 / 章节列表**反着显示**（第 121 话在最上面）；
///   ② 阅读器的「下一章」往**回**走（因为它按数组顺序取下一项）。
/// 这里改成按章节名里的**话数**升序排，与站点给的顺序无关。
///
/// 识别规则（按优先级）：
///   · `15卷番外` / `第3卷` → 卷号（卷内话数为 0，排在该卷正文前）
///   · `第12話` / `第12话` / `第12章` / `第12回` / `12话` → 12
///   · `第十二話`（中文数字）→ 12
///   · 纯数字标题 `12` / `12.5` → 12 / 12.5
///   · 抽不出数字的（「短篇」「序」）→ **保持原相对顺序**，统一排在最后
///
/// ⚠️ 抽得出数字的章节不足一半时**整体放弃排序**（保持站点原顺序）——
///    有些源的命名完全没规律，硬排只会更乱。
enum ChapterSorter {

    struct Key: Comparable {
        let volume: Int
        let number: Double
        let hasNumber: Bool
        /// 原始下标 —— 用于「抽不出数字」时的稳定排序
        let original: Int

        static func < (a: Key, b: Key) -> Bool {
            if a.hasNumber != b.hasNumber { return a.hasNumber && !b.hasNumber }
            if a.volume != b.volume { return a.volume < b.volume }
            if a.number != b.number { return a.number < b.number }
            return a.original < b.original
        }
    }

    /// 升序排序（只调顺序，不改内容）
    static func sort(_ chapters: [ComicInfo.Chapter]) -> [ComicInfo.Chapter] {
        guard chapters.count > 1 else { return chapters }
        let keys = chapters.enumerated().map { idx, ch in key(for: ch.name, original: idx) }
        let withNumber = keys.filter { $0.hasNumber }.count
        // 能认出话数的不到一半 → 这个源命名不规律，别乱排
        guard withNumber * 2 >= chapters.count else { return chapters }
        return zip(chapters, keys).sorted { $0.1 < $1.1 }.map { $0.0 }
    }

    // MARK: - 解析

    static func key(for name: String, original: Int) -> Key {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return Key(volume: 0, number: 0, hasNumber: false, original: original) }

        // ① 带「卷」的：卷号优先，卷内再按话数
        if let v = firstInt(n, pattern: "(\\d+)\\s*卷") {
            let inner = firstDouble(n, pattern: "第?\\s*(\\d+(?:\\.\\d+)?)\\s*[话話章回]") ?? 0
            return Key(volume: v, number: inner, hasNumber: true, original: original)
        }
        // ② 阿拉伯数字 + 话/章/回
        if let x = firstDouble(n, pattern: "第?\\s*(\\d+(?:\\.\\d+)?)\\s*[话話章回]") {
            return Key(volume: 0, number: x, hasNumber: true, original: original)
        }
        // ③ 中文数字 + 话/章/回
        if let s = firstGroup(n, pattern: "第?\\s*([零一二三四五六七八九十百]+)\\s*[话話章回]"),
           let x = chineseNumber(s) {
            return Key(volume: 0, number: Double(x), hasNumber: true, original: original)
        }
        // ④ 纯数字标题
        if let x = Double(n) {
            return Key(volume: 0, number: x, hasNumber: true, original: original)
        }
        return Key(volume: 0, number: 0, hasNumber: false, original: original)
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
