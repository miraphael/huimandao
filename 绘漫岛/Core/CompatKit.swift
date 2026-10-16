import Foundation

/// ──────────────────────────────────────────────────────────────────────────
/// CompatKit —— ParseCore 的**兼容模块**
///
/// 职责单一：把三个既有解析引擎（LE 规则 / JS 脚本 / 万用启发式）以
/// **统一适配器**的形式接入 `ParseCore`，让内核**只依赖抽象**、
/// 不 import 任何一个具体引擎的类型。
///
/// ## 为什么要有这一层（而不是在内核里直接调三个引擎）
/// ① **可替换**：将来加第四个引擎（例如「AI 解析」「XPath 专用引擎」）时，
///    只写一个适配器，内核一行都不用改。
/// ② **成本可声明**：内核靠 `Capability.cost` 决定尝试顺序，
///    而「谁便宜谁贵」是各引擎的**固有属性**，应该由引擎自己声明、不该写死在内核里。
/// ③ **取长补短的落点**：`mergePreservingOrder`（语义骨架+召回补全）与
///    `dropForeign`（污染剔除）都是**跨引擎协作**，天然属于兼容层。
///
/// ## 各引擎的能力声明（这是「取长补短」的依据）
///
/// | 引擎 | 成本 | 语义精度 | 召回 | 自带取数 | 可终止 |
/// |---|---|---|---|---|---|
/// | rule      | 1（最便宜） | ✅ 高 | ❌ 低 | ❌ 需外部喂文档 | ✅ |
/// | universal | 1（便宜）   | ❌ 无 | ✅ 高 | ❌ 需外部喂文档 | ✅ |
/// | js        | 3（最贵）   | ✅ 高 | ❌ 低 | ✅ 自己发网络 | ❌ **不可终止** |
///
/// 「不可终止」是 JS 的硬伤（`JSCore` 没有中断 API）—— 所以它必须排在最后，
/// 只有前两者都失败时才值得冒这个风险。
/// ──────────────────────────────────────────────────────────────────────────
enum CompatKit {

    // MARK: - 能力声明

    /// 一个引擎的固有属性 —— 内核据此决定顺序与协作方式。
    struct Capability {
        /// 相对成本：1 = 最便宜（本地解析），越大越贵（要起 JS 上下文/网络）
        var cost: Int
        /// 是否有**语义精度**：知道顺序、命名、分页、字段含义
        var semantic: Bool
        /// 召回是否高：是否擅长「发现规则漏掉的东西」
        var highRecall: Bool
        /// 是否能自己取数（自带网络能力）
        var fetchesItself: Bool
        /// 是否**可终止** —— false 表示一旦脚本死循环就只能等它自己停
        var terminable: Bool

        /// 人类可读的一行摘要（诊断用）
        var summary: String {
            "成本\(cost)·\(semantic ? "有语义" : "无语义")·\(highRecall ? "高召回" : "低召回")"
                + (terminable ? "" : "·不可终止")
        }
    }

    static let ruleCap = Capability(cost: 1, semantic: true, highRecall: false,
                                    fetchesItself: false, terminable: true)
    static let universalCap = Capability(cost: 1, semantic: false, highRecall: true,
                                         fetchesItself: false, terminable: true)
    static let jsCap = Capability(cost: 3, semantic: true, highRecall: false,
                                  fetchesItself: true, terminable: false)

    /// 取某策略的能力声明
    static func capability(of s: ParseCore.Strategy) -> Capability {
        switch s {
        case .rule:      return ruleCap
        case .universal: return universalCap
        case .js:        return jsCap
        }
    }

    // MARK: - 成本感知排序

    /// 按成本升序排列（便宜的先试）。**稳定排序**：同成本保持调用方给的相对顺序。
    ///
    /// ⚠️ 不可终止的引擎（JS）永远排在最后 —— 除非调用方显式把它放第一位
    ///    （源自带 JS manifest 时应当如此：那是源作者写的逻辑，是他的本意）。
    ///    这里只做「同成本稳定 + 成本升序」，不强行重排调用方的首位意图：
    ///    若调用方把 JS 放第一，它成本高，会被排到后面 —— 所以
    ///    **源自带 manifest 的场景请直接用 `steps` 的原始顺序**，不要走这个函数。
    static func orderByCost<T>(_ steps: [(ParseCore.Strategy, () async -> (T, ParseCore.Quality))])
        -> [(ParseCore.Strategy, () async -> (T, ParseCore.Quality))] {
        steps.enumerated()
            .sorted { a, b in
                let ca = capability(of: a.element.0).cost
                let cb = capability(of: b.element.0).cost
                if ca != cb { return ca < cb }
                return a.offset < b.offset          // 稳定：同成本保持原序
            }
            .map(\.element)
    }

    // MARK: - ① 语义骨架 + 召回补全

    /// 以 `primary`（有语义的引擎，通常是规则）的顺序为**骨架**，
    /// 把 `secondary`（高召回的引擎，通常是万用）里**骨架没有的**追加到末尾。
    ///
    /// 这就是「取长补短」最直接的一条：
    ///   · 规则的长处是**顺序与命名**（它知道第 1 话在第 2 话前面）；
    ///   · 万用的长处是**召回**（它能发现规则漏掉的那些）；
    ///   · 简单拼接会破坏顺序、也可能重复 → 这里按 `identity` 去重后**追加**。
    ///
    /// - Parameter identity: 取元素的身份键（章节用 URL，图片用 URL 字符串）
    static func mergePreservingOrder<T>(primary: [T], secondary: [T],
                                        identity: (T) -> String) -> [T] {
        var seen = Set(primary.map(identity))
        var out = primary
        for item in secondary {
            let k = identity(item)
            guard !k.isEmpty, !seen.contains(k) else { continue }
            seen.insert(k)
            out.append(item)
        }
        return out
    }

    // MARK: - ④ 污染剔除

    /// 剔除**跨作品**的候选。
    ///
    /// 万用引擎召回高，但详情页常带「猜你喜欢 / 热门推荐」侧栏 ——
    /// 不过滤就会把**别的作品**的章节/图片一起捞进来（实测某源捞到 58 条，
    /// 其中 30+ 条是别人的）。
    ///
    /// 这里用 `UniversalParser.comicPathPrefix` 求出的「本作品路径前缀」过滤 ——
    /// 这是用**规则侧的语义**（作品 URL 的路径规律）去补**万用侧无语义**的短。
    ///
    /// - Parameter pageUrl: 详情页 / 章节页地址（前缀由它推出）
    static func dropForeign(_ candidates: [String], pageUrl: String) -> [String] {
        let prefix = UniversalParser.comicPathPrefix(pageUrl)
        guard !prefix.isEmpty else { return candidates }   // 推不出前缀 → 不做过滤（宁可不过滤也不要误删）
        return candidates.filter { $0.contains(prefix) }
    }

    // MARK: - 引擎的「原始能力」→ 内核的 Step

    /// 把一个引擎的原始执行闭包包成内核认识的 `(Strategy, Step)`。
    ///
    /// 存在的意义是**把「这是哪个引擎」与「怎么执行」解耦**：
    /// 调用方只需说「这是规则引擎，它这样跑」，不必关心内核怎么调度。
    static func step<T>(_ strategy: ParseCore.Strategy,
                        _ body: @escaping () async -> (T, ParseCore.Quality))
        -> (ParseCore.Strategy, () async -> (T, ParseCore.Quality)) {
        (strategy, body)
    }

    /// 三级全落空、或置信度低时，给出可直接展示给用户的诊断文案。
    ///
    /// ⚠️ 用泛型 `T` 而不是 `some Any`：`Outcome` 的字段里只有 `winner` /
    ///    `confidence` / `summary` 被用到，与 `T` 无关，泛型最直接也最稳。
    static func diagnoseNote<T>(_ out: ParseCore.Outcome<T>) -> String? {
        guard out.winner == nil || out.confidence == .low else { return nil }
        let conf = out.confidence == .low ? "（置信度低：两个引擎结果差异很大）" : ""
        return "解析策略：\(out.summary)\(conf)"
    }
}
