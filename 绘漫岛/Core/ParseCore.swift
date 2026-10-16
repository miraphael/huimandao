import Foundation

/// ──────────────────────────────────────────────────────────────────────────
/// ParseCore —— 绘漫岛**独立研发**的解析内核
///
/// ## 它是什么
/// 一个**不依赖任何具体解析引擎**的调度内核。三个既有解析器
/// （LE 规则 / JS 脚本 / 万用启发式）通过 `CompatKit` 以**适配器**形式接入，
/// 内核只依赖「策略 + 成本 + 质量」这三个抽象。
///
/// ## 为什么要独立做一个内核（而不是继续散在 ComicEngine 里）
/// 三个引擎此前是三条互不相干的路径，降级链是断的：
///   · 规则源：`chapters()` 内部有兜底；
///   · **JS 源：完全没有兜底**；
///   · **搜索：完全没有兜底**。
/// 把「谁先试、什么时候降级、结果可不可信」收进一个内核后，这些规则只有一处，
/// 不会再出现「某条路径漏了兜底」。
///
/// ## 独创点：不是「谁非空用谁」，而是**取长补短**
/// 三个引擎各有硬伤，单用任何一个都会漏：
///
/// | 引擎 | 长 | 短 |
/// |---|---|---|
/// | 规则 rule | 精确、快、**有语义**（顺序/命名/分页/字段） | 站点改版即失效 |
/// | JS js | **表达力最强**（任意逻辑、解密、签名） | 最慢、**不可终止**、维护成本高 |
/// | 万用 universal | **不怕改版**、召回高（能发现「漏了」） | 噪声大、**无语义**（不知分页） |
///
/// 内核用四条机制把它们**互相补短**：
///
/// **① 语义骨架 + 召回补全**
///    规则提供语义骨架（顺序/命名），万用只**补**规则没有的那些，
///    而不是简单拼接 —— 既拿到召回，又不破坏顺序。
///    （实现：`CompatKit.mergePreservingOrder`）
///
/// **② 交叉验证 + 置信度**（本内核的招牌能力）
///    两级都产出时，算身份集合的 **Jaccard 重合率 J = |交| / |并|**：
///      · J ≥ 0.60 → `high`   两个引擎互相印证，可信
///      · 0.20 ≤ J < 0.60 → `medium` 取更全的那个，标注待观察
///      · J < 0.20 → `low`    两者可能在解析**不同的东西**，取更全者但明确告警
///    ⚠️ 旧实现只有「谁多选谁」，**没有任何置信度** —— 用户和诊断都看不出
///       「这次的结果靠不靠得住」。这是内核与「按序试」的本质区别。
///
/// **③ 成本感知的顺序**
///    最慢且**不可终止**的 JS 只在必要时才上；便宜的先上。
///    同时尊重源的本意：源**自带 JS manifest** 时 JS 优先（那是作者写的逻辑）。
///
/// **④ 自适应记忆**
///    记住「某源某阶段哪条策略胜出」，下次先试它。纯内存、不落库
///    （策略优劣随站点改版变化，固化陈旧偏好反而有害）。
///
/// ## 非目标
/// 不做「多策略结果加权合并」：并集会让本来正确的规则结果被启发式的噪声污染。
/// 内核的语义是**「选一条最好的，并告诉你有多可信」**。
/// ──────────────────────────────────────────────────────────────────────────
enum ParseCore {

    // MARK: - 阶段与策略

    /// 解析阶段。决定日志分类，以及调用方该用哪套质量判据。
    enum Stage: String {
        case search      // 搜索列表
        case detail      // 详情（元信息 + 章节）
        case chapters    // 章节列表
        case images      // 正文图片

        var label: String {
            switch self {
            case .search:   return "搜索"
            case .detail:   return "详情"
            case .chapters: return "章节"
            case .images:   return "正文"
            }
        }
    }

    /// 解析策略（即「三个引擎」）
    enum Strategy: String {
        case rule       // LE 规则引擎 —— AnalyzeRule
        case js         // JS 引擎 —— JSProvider
        case universal  // 万用引擎 —— UniversalParser

        var label: String {
            switch self {
            case .rule:      return "规则"
            case .js:        return "JS"
            case .universal: return "万用"
            }
        }
    }

    // MARK: - 质量评估

    /// 一次策略产出的质量评估。
    ///
    /// 由**调用方**给出 —— 因为「多少算够」是领域知识（章节页首屏本来就少、
    /// 图片列表至少要有 2 张…），内核本身不该猜。
    struct Quality {
        /// 产出条数
        var count: Int
        /// 是否「达标」→ 达标则立即采用（短路）
        var usable: Bool
        /// 择优用的分数（越大越好）。默认等于 `count`。
        var score: Int

        /// 常用构造：条数 ≥ `usableWhenAtLeast` 才算达标。
        ///
        /// ⚠️ 名字故意不叫 `count(...)` —— 本结构体已有同名**实例属性** `count`。
        static func of(_ n: Int, usableWhenAtLeast min: Int = 1) -> Quality {
            Quality(count: n, usable: n >= min, score: n)
        }

        /// 全落空
        static var none: Quality { Quality(count: 0, usable: false, score: 0) }
    }

    // MARK: - 置信度

    /// 交叉验证得出的置信度 —— 两个引擎的结果**互相印证的程度**。
    enum Confidence: String {
        case high      // 高度一致：互相印证
        case medium    // 部分一致：取更全的，待观察
        case low       // 几乎不一致：可能解析的是不同的东西
        case single    // 只有一级产出，无从交叉验证
        case none      // 全落空

        var label: String {
            switch self {
            case .high:   return "高"
            case .medium: return "中"
            case .low:    return "低"
            case .single: return "单级"
            case .none:   return "无"
            }
        }
    }

    /// 交叉验证：Jaccard 重合率 → 置信度。
    ///
    /// 阈值是**拍的初值**，真机跑起来应按实测调整（见文件头 ② 的说明）。
    static func confidence(between a: Set<String>, and b: Set<String>) -> Confidence {
        if a.isEmpty && b.isEmpty { return .none }
        if a.isEmpty || b.isEmpty { return .single }   // 只有一级有产出
        let inter = a.intersection(b).count
        let union = a.union(b).count
        guard union > 0 else { return .none }
        let j = Double(inter) / Double(union)
        if j >= 0.60 { return .high }
        if j >= 0.20 { return .medium }
        return .low
    }

    // MARK: - 结果与记录

    /// 一次尝试的记录（诊断用）
    struct Attempt {
        var strategy: Strategy
        var count: Int
        var usable: Bool
        var ms: Int
    }

    /// 内核产出
    struct Outcome<T> {
        var value: T
        /// 胜出的策略；`nil` 表示三级全落空
        var winner: Strategy?
        var attempts: [Attempt]
        /// 诊断摘要，如 `规则(26 可疑)→万用(376) 取万用 · 置信低`
        var summary: String
        /// 交叉验证得出的置信度
        var confidence: Confidence

        /// 是否走了兜底（胜出者不是第一级）
        var didFallBack: Bool {
            guard let w = winner else { return true }
            return attempts.first?.strategy != w
        }

        /// 是否值得提示用户/记诊断（降级 或 低置信）
        var needsAttention: Bool {
            didFallBack || confidence == .low || confidence == .medium
        }
    }

    // MARK: - 策略记忆（纯内存）

    private static var memory: [String: Strategy] = [:]
    private static let lock = NSLock()

    private static func memoryKey(_ stage: Stage, _ sourceKey: String) -> String {
        "\(stage.rawValue)|\(sourceKey)"
    }

    private static func remembered(_ stage: Stage, _ sourceKey: String) -> Strategy? {
        lock.lock(); defer { lock.unlock() }
        return memory[memoryKey(stage, sourceKey)]
    }

    private static func remember(_ stage: Stage, _ sourceKey: String, _ s: Strategy) {
        lock.lock(); memory[memoryKey(stage, sourceKey)] = s; lock.unlock()
    }

    /// 清空策略记忆（供「重置诊断」/测试使用）
    static func forgetAll() {
        lock.lock(); memory.removeAll(); lock.unlock()
    }

    // MARK: - 执行

    /// 跑一条降级链。
    ///
    /// - Parameters:
    ///   - stage: 阶段（决定记忆键与日志分类）
    ///   - sourceKey: 源标识（记忆键的一部分）
    ///   - empty: 三级全落空时的返回值
    ///   - identity: 从产出里取出**身份集合**（如章节 URL 集合）—— 用于交叉验证。
    ///               返回空集表示「无法交叉验证」，此时置信度退化为 `single`。
    ///   - steps: 按**默认优先级**排列的「策略 + 执行闭包」。
    ///            记忆命中时，胜出过的那条会被**提前**（其余保持相对顺序）。
    ///
    /// ⚠️ 执行闭包必须**自己处理异常**（返回空值而非抛出）——
    ///    内核不吞异常，因为它不知道该返回什么类型的空值。
    @discardableResult
    static func run<T>(stage: Stage, sourceKey: String, empty: T,
                       identity: @escaping (T) -> Set<String>,
                       steps: [(Strategy, () async -> (T, Quality))]) async -> Outcome<T> {
        guard !steps.isEmpty else {
            return Outcome(value: empty, winner: nil, attempts: [], summary: "无可用策略",
                           confidence: .none)
        }

        // ① 策略记忆：把上次胜出的那条提到最前（保持其余相对顺序，稳定）
        var ordered = steps
        if let m = remembered(stage, sourceKey),
           let i = ordered.firstIndex(where: { $0.0 == m }), i > 0 {
            let hit = ordered.remove(at: i)
            ordered.insert(hit, at: 0)
        }

        var attempts: [Attempt] = []
        var best: (value: T, strategy: Strategy, score: Int, ids: Set<String>)?
        /// 供交叉验证用的「第一级非空产出」
        var firstIds: Set<String>?

        for (strategy, exec) in ordered {
            let t0 = Date()
            let (value, q) = await exec()
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            attempts.append(Attempt(strategy: strategy, count: q.count, usable: q.usable, ms: ms))

            var ids: Set<String> = []
            if q.count > 0 {
                ids = identity(value)
                if best == nil || q.score > best!.score {
                    best = (value, strategy, q.score, ids)
                }
                if firstIds == nil { firstIds = ids }
            }

            // ② 达标 → 立即采用（短路，把「快」留给绝大多数正常源）
            if q.usable {
                remember(stage, sourceKey, strategy)
                // 只有一级产出 → 无从交叉验证，置信度记 `single`
                let conf = firstIds == nil ? Confidence.none : Confidence.single
                let out = Outcome(value: value, winner: strategy, attempts: attempts,
                                  summary: summaryText(attempts, winner: strategy),
                                  confidence: conf)
                log(stage: stage, sourceKey: sourceKey, out: out)
                return out
            }
        }

        // ③ 全都没达标 → 取「非空里最优的那个」
        if let b = best {
            remember(stage, sourceKey, b.strategy)
            // 交叉验证：把「最优的那个」与「第一级产出」比对
            // （两者是同一条链上的两个引擎，正好互相印证）
            let conf: Confidence
            if let f = firstIds, b.ids != f {
                conf = confidence(between: f, and: b.ids)
            } else {
                conf = .single
            }
            let out = Outcome(value: b.value, winner: b.strategy, attempts: attempts,
                              summary: summaryText(attempts, winner: b.strategy),
                              confidence: conf)
            log(stage: stage, sourceKey: sourceKey, out: out)
            return out
        }

        let out = Outcome(value: empty, winner: nil, attempts: attempts,
                          summary: summaryText(attempts, winner: nil), confidence: .none)
        log(stage: stage, sourceKey: sourceKey, out: out)
        return out
    }

    // MARK: - 诊断

    private static func summaryText(_ attempts: [Attempt], winner: Strategy?) -> String {
        guard !attempts.isEmpty else { return "无可用策略" }
        let chain = attempts.map { a -> String in
            if a.usable { return "\(a.strategy.label)(\(a.count))" }
            if a.count > 0 { return "\(a.strategy.label)(\(a.count) 可疑)" }
            return "\(a.strategy.label)(空)"
        }.joined(separator: "→")
        guard let w = winner else { return "\(chain) 全落空" }
        let first = attempts.first?.strategy
        return first == w ? chain : "\(chain) 取\(w.label)"
    }

    private static func log<T>(stage: Stage, sourceKey: String, out: Outcome<T>) {
        // 只在「有降级 / 全落空 / 置信度偏低」时记日志：正常命中第一级是绝大多数情况，
        // 每条都记会把诊断日志刷满，反而看不到异常。
        guard out.needsAttention else { return }
        let confNote = (out.confidence == .high || out.confidence == .single)
            ? "" : " · 置信\(out.confidence.label)"
        DiagLog.event("core", stage.rawValue,
                      "\(stage.label) \(DiagLog.safeURL(sourceKey)) → \(out.summary)\(confNote)")
    }
}
