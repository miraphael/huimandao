import Foundation

/// ──────────────────────────────────────────────────────────────────────────
/// 章号归一化 —— 「织」引擎的地基
///
/// ## 为什么它是地基
/// 要把 6 个源的章节「织」成一条连续的流，第一件事是回答：
/// **卡拉的第 12 话和漫画网的第 12 话，是不是同一话？**
/// 它们的写法可能完全不同：
///
/// ```
///   第12话   第12話   Ch.12   chapter 12   #12   12   第十二话   第一百二十话
///   第12.5话  12.5    番外1   特别篇 3     序章   第3卷第12话
/// ```
///
/// 对不齐 → 拼出来的流会错页、错章、重复。**错页比打不开更伤体验**，
/// 所以这里的原则是：**宁可返回 nil（放弃对齐），也不要猜错。**
///
/// ## 两个关键设计
///
/// **① 置信度分级。** 不是所有解析都一样可靠：
///    · `第12话` / `Ch.12` / `第十二话`  → 1.0 / 0.95  可靠
///    · 纯数字 `12`                      → 0.85       较可靠
///    · 任意位置的第一个数字 `12`（从「2024年12月」里抓）→ 0.6  不可靠
///    拼源只接受 `>= 0.85`；低于这个值只允许单源阅读，不参与跨源对齐。
///
/// **② 番外类单独编码。** 番外/外传/特别篇/小剧场 不是「第几话」，
///    硬塞进正文序列会让「番外1」排到「第1话」前面。
///    这里给每类一个独立的负数基底（番外 -1、外传 -1001、特别篇 -2001…），
///    既能在同类内按序号排序，又不会和正文串号。
///
/// ## 已知不做（写清楚，免得后人以为漏了）
/// · **繁简转换**：`進擊的巨人` 与 `进击的巨人` 这里不归一。
///   原因：整表转换体积大且容易误伤（「干」与「乾」）。**索引不靠书名对齐**，
///   靠我们自己的书架 ID —— 书名模糊匹配只在「搜到其他源」时做一次，
///   之后索引锚定在 bookID 上，与繁简无关。
/// · **分册 `12-1`**：只取主号 12。分册在漫画站极少见，为此增加歧义不划算。
/// · **URL 里的数字**：绝不用。`/chapter/102765` 在不同源之间毫无可比性。
/// ──────────────────────────────────────────────────────────────────────────
enum ChapterKeyParser {

    /// 解析结果。`confidence` 决定它能不能参与跨源拼装。
    struct Parsed: Equatable {
        /// 归一化章号。正文 ≥ 0；番外类为负数（见 `extraBase`）
        let no: Double
        /// 0~1。`>= 0.85` 才允许参与跨源对齐
        let confidence: Double

        var isExtra: Bool { no < 0 }
        var isTrustworthy: Bool { confidence >= 0.85 }
    }

    /// 拼源可接受的最低置信度。低于它只做单源阅读。
    static let alignmentThreshold: Double = 0.85

    // MARK: - 入口

    /// 从章节名（可带 URL 兜底，但**当前刻意不用 URL**）解析章号。
    static func parse(_ raw: String) -> Parsed? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        // 全角数字/字母 → 半角（`１２` → `12`，`ＣＨ` → `CH`）
        t = t.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? t
        // NBSP / 全角空格 → 普通空格
        t = t.replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "\u{3000}", with: " ")

        // ① 番外类优先判定 —— 否则「番外1」会被正文规则当成「第 1 话」
        if let e = parseExtra(t) { return e }

        // ② 序章 / 楔子 / 引子 → 0
        for k in ["序章", "序", "楔子", "引子", "前言"] where t.contains(k) {
            // 「序」单字太容易误伤（「顺序」），只在开头或极短标题里认
            if k == "序", !(t.hasPrefix("序") || t.count <= 3) { continue }
            return Parsed(no: 0, confidence: 0.9)
        }

        // ③ 第 N 话/章/回/集（阿拉伯数字，最高置信）
        if let n = firstMatch(t, #"第\s*([0-9]+(?:\.[0-9]+)?)\s*[话話章回集]"#) {
            return Parsed(no: n, confidence: 1.0)
        }

        // ④ 第 N 话（中文数字）
        if let s = firstMatchString(t, #"第\s*([零〇一二三四五六七八九十百千万两]+)\s*[话話章回集]"#),
           let n = chineseToInt(s) {
            return Parsed(no: Double(n), confidence: 0.95)
        }

        // ⑤ Ch.N / Chapter N / EP.N / #N
        //
        // ⚠️ **不能把 `vol` 放进这一组**：`Vol.3 Ch.12` 里左起第一个匹配会是
        //    `Vol.3`，于是「第 3 卷」被当成「第 3 话」，置信度还是 0.95 ——
        //    卷和话会被静默串号。卷只在 ⑦ 里用低置信度单独处理。
        // ⚠️ 必须加 `\b`：否则 `step 5` 里的 `ep 5` 会被当成 EP.5。
        if let n = firstMatch(t, #"\b(?:ch|chapter|chap|ep|episode)\s*\.?\s*([0-9]+(?:\.[0-9]+)?)"#) {
            return Parsed(no: n, confidence: 0.95)
        }
        if let n = firstMatch(t, #"#\s*([0-9]+(?:\.[0-9]+)?)"#) {
            return Parsed(no: n, confidence: 0.95)
        }

        // ⑥ 纯数字（可能带小数）
        let digitsOnly = t.trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))
        if !digitsOnly.isEmpty,
           digitsOnly.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil,
           let n = Double(digitsOnly) {
            return Parsed(no: n, confidence: 0.85)
        }

        // ⑦ 卷：单独成卷时用 n×1000 占位（置信度低，只做排序不做对齐）
        if let n = firstMatch(t, #"第?\s*([0-9]+)\s*卷"#) {
            return Parsed(no: n * 1000, confidence: 0.5)
        }

        // ⑧ 兜底：任意位置的第一个数字。置信度低 —— 可能抓到年份、页数、卷号
        if let n = firstMatch(t, #"([0-9]+(?:\.[0-9]+)?)"#) {
            return Parsed(no: n, confidence: 0.6)
        }

        return nil
    }

    /// 两个源的同名章节能否视为「同一话」。
    ///
    /// 只有双方都可信、且章号一致才成立。任一方不可信 → 不对齐（宁可重复，不可错页）。
    static func alignable(_ a: Parsed?, _ b: Parsed?) -> Bool {
        guard let a, let b else { return false }
        guard a.isTrustworthy, b.isTrustworthy else { return false }
        return abs(a.no - b.no) < 0.001
    }

    // MARK: - 番外类

    /// 每类番外的负数基底。同类内按序号递增，跨类不冲突。
    ///
    /// 用 `-1 / -1001 / -2001 …` 而不是 `-1 / -2 / -3`：
    /// 这样「番外第 500 篇」也不会撞上「外传第 1 篇」。
    private static let extraTypes: [(keys: [String], base: Double)] = [
        (["番外"], -1),
        (["外传", "外傳"], -1001),
        (["特别篇", "特別篇"], -2001),
        (["小剧场", "小劇場"], -3001),
        (["剧场版", "劇場版"], -4001),
        (["特典"], -5001),
        (["设定集", "設定集"], -6001),
        (["周年"], -7001),
    ]

    private static func parseExtra(_ t: String) -> Parsed? {
        for (keys, base) in extraTypes {
            for k in keys where t.contains(k) {
                // 关键词后面的数字就是序号；没有则当第 1 篇
                let tail = t.components(separatedBy: k).last ?? ""
                let n = firstMatch(tail, #"([0-9]+)"#).map { Int($0) } ?? 1
                // 上限 999，避免越界撞到下一类的基底
                let idx = min(max(n, 1), 999)
                return Parsed(no: base - Double(idx - 1), confidence: 0.9)
            }
        }
        return nil
    }

    // MARK: - 中文数字

    private static let cnDigits: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
    ]
    private static let cnUnits: [Character: Int] = ["十": 10, "百": 100, "千": 1000, "万": 10000]

    /// 「十二」→12 ·「一百二十」→120 ·「一千零一」→1001 ·「两百」→200
    static func chineseToInt(_ s: String) -> Int? {
        var total = 0        // 已结算的「万」以上部分
        var section = 0      // 当前「万」以内累计
        var number = 0       // 待结算的个位数
        var sawAny = false
        for ch in s {
            if let d = cnDigits[ch] {
                number = d
                sawAny = true
            } else if let u = cnUnits[ch] {
                sawAny = true
                if u == 10000 {
                    section = (section + number) * 10000
                    total += section
                    section = 0
                } else {
                    // 「十二」的十前面没有数字 → 按 1 算
                    let n = number == 0 ? 1 : number
                    section += n * u
                }
                number = 0
            } else {
                return nil      // 混入非数字字符 → 放弃（宁可 nil 不可猜）
            }
        }
        guard sawAny else { return nil }
        return total + section + number
    }

    // MARK: - 正则小工具

    private static func firstMatch(_ text: String, _ pattern: String) -> Double? {
        firstMatchString(text, pattern).flatMap { Double($0) }
    }

    private static func firstMatchString(_ text: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        let r = m.range(at: 1)
        guard r.location != NSNotFound else { return nil }
        return ns.substring(with: r)
    }
}
