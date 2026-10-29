import Foundation

/// 启动自检 —— 对**纯逻辑**跑一组断言，把结果写进诊断日志。
///
/// ## 为什么需要它（2026-10-28）
/// 这个项目目前 **0 个单元测试**，所有验证都靠"装到手机上点一遍"。
/// 于是最近两天反复出现同一类事故：
///   · `{{page}}` 被百分号编码 → 图库整栏目 0 条（装到手机上才发现）
///   · `ruleContentList` 字段名错 → 6 个源正文规则静默丢弃（查了 3 轮才发现）
///   · `Referer: -` 当字面量发出去 → 瓜子图片全 403
///
/// 这些都是**纯函数级别**的错误，本来一个断言就能拦住。
/// 这里先做最小闭环：启动时在后台跑一组纯逻辑断言，结果写 `[selftest]`。
/// 每次装机拉日志就能看到 `pass N / fail M`，改坏了立刻暴露，不用等你点出来。
///
/// ⚠️ 它**不替代**真正的单元测试（XCTest + CI），只是零成本的第一步：
///    不新增 target、不改 CI，永远不会让构建挂掉。
enum SelfCheck {

    private struct Case {
        let name: String
        let run: () -> Bool
    }

    /// 跑一遍并把结果写进日志。调用方应在后台 Task 里调，别阻塞启动。
    static func run() {
        let cases: [Case] = [
            // ── 失败归因（v190 新增，UI 全靠它说人话）──────────────────
            Case(name: "FailureReason 404→notFound") { FailureReason.from(status: 404) == .notFound },
            Case(name: "FailureReason 403→blocked") { FailureReason.from(status: 403) == .blocked },
            Case(name: "FailureReason 503→server") { FailureReason.from(status: 503) == .server },
            Case(name: "FailureReason 断网→network") {
                FailureReason.from(error: URLError(.notConnectedToInternet)) == .network
            },
            Case(name: "FailureReason 超时→timeout") {
                FailureReason.from(error: URLError(.timedOut)) == .timeout
            },
            Case(name: "404 不值得重试") { FailureReason.notFound.isWorthRetrying == false },
            Case(name: "超时值得重试") { FailureReason.timeout.isWorthRetrying },

            // ── 分页占位符（v189 修的真 bug：%7B%7B 没还原 → 图库 0 条）──
            Case(name: "{{page}} 正常替换") {
                AnalyzeUrl.evalVars("https://a.com/p{{page}}/", searchKey: "", page: 3,
                                    charset: nil, urlEncode: true) == "https://a.com/p3/"
            },
            Case(name: "{{page}} 被编码后仍能替换") {
                AnalyzeUrl.evalVars("https://a.com/p%7B%7Bpage%7D%7D/", searchKey: "", page: 2,
                                    charset: nil, urlEncode: true) == "https://a.com/p2/"
            },
            Case(name: "searchPage 替换") {
                AnalyzeUrl.evalVars("https://a.com/s?p=searchPage", searchKey: "", page: 4,
                                    charset: nil, urlEncode: true) == "https://a.com/s?p=4"
            },

            // ── Referer 占位值（v189 修的真 bug：`-` 当字面量发出 → 瓜子 403）──
            Case(name: "Referer: - 视为不发") {
                ComicEngine.SourceReferer.override(in: "Referer: -") == ""
            },
            Case(name: "Referer 空值视为不发") {
                ComicEngine.SourceReferer.override(in: "Referer: ") == ""
            },
            Case(name: "Referer 正常值保留") {
                ComicEngine.SourceReferer.override(in: "Referer: https://a.com/") == "https://a.com/"
            },
            Case(name: "无 header 返回 nil") {
                ComicEngine.SourceReferer.override(in: nil) == nil
            },

            // ── 图片 URL 编码（中文路径，图库在用）────────────────────
            Case(name: "中文路径百分号编码") {
                HMDImagePipeline.asciiEncoded("/h/海贼王/1.jpg")
                    == "/h/%E6%B5%B7%E8%B4%BC%E7%8E%8B/1.jpg"
            },
            Case(name: "纯 ASCII 不编码（保留 [ ] ?）") {
                HMDImagePipeline.asciiEncoded("/a[1]/b.jpg?x=1") == "/a[1]/b.jpg?x=1"
            },

            // ── 章节排序（番外要排在正文后面）────────────────────────
            Case(name: "章节排序：番外不插到正文中间") {
                let chs = [
                    ComicInfo.Chapter(name: "第2话", url: "u2"),
                    ComicInfo.Chapter(name: "番外1", url: "ex1"),
                    ComicInfo.Chapter(name: "第1话", url: "u1"),
                ]
                let out = ChapterSorter.sort(chs).map(\.name)
                // 正文两话必须相对有序；番外必须落在最后
                return out.firstIndex(of: "第1话")! < out.firstIndex(of: "第2话")!
                    && out.last == "番外1"
            },

            // ── header 解析（图源大量依赖）────────────────────────────
            Case(name: "header 行解析") {
                let h = LegadoConverter.parseHeader("Referer: https://a.com/\nUser-Agent: X")
                return h["Referer"] == "https://a.com/" && h["User-Agent"] == "X"
            },

            // ── 源级熔断（v194 新增：修「切源一直转圈」）─────────────────
            // ⚠️ 每个用例都新建实例，绝不用 `SourceBreaker.shared` ——
            //    否则自检会污染真实运行时的熔断状态（等于开机就把某个源跳过）。
            Case(name: "熔断：2 次失败还不熔断") {
                let b = SourceBreaker(limit: 3, cooldown: 120)
                b.recordFailure("o", reason: .timeout)
                b.recordFailure("o", reason: .timeout)
                return b.shouldSkip("o") == nil && b.snapshot("o")?.failures == 2
            },
            Case(name: "熔断：连续 3 次失败 → 跳过") {
                let b = SourceBreaker(limit: 3, cooldown: 120)
                for _ in 0..<3 { b.recordFailure("o", reason: .timeout) }
                return b.shouldSkip("o")?.failures == 3
            },
            Case(name: "熔断：成功后计数清零") {
                let b = SourceBreaker(limit: 3, cooldown: 120)
                for _ in 0..<3 { b.recordFailure("o", reason: .timeout) }
                b.recordSuccess("o")
                return b.shouldSkip("o") == nil && b.snapshot("o") == nil
            },
            Case(name: "熔断：冷却到期后放行（半开）") {
                let b = SourceBreaker(limit: 3, cooldown: 0)
                for _ in 0..<3 { b.recordFailure("o", reason: .timeout) }
                return b.shouldSkip("o") == nil && b.snapshot("o")?.failures == 3
            },
            Case(name: "熔断：404 不计数（书下架 ≠ 源坏了）") {
                let b = SourceBreaker(limit: 3, cooldown: 120)
                for _ in 0..<5 { b.recordFailure("o", reason: .notFound) }
                return b.snapshot("o") == nil
            },
            Case(name: "熔断：解析 0 条不计数") {
                let b = SourceBreaker(limit: 3, cooldown: 120)
                for _ in 0..<5 { b.recordFailure("o", reason: .ruleMiss) }
                return b.snapshot("o") == nil
            },
            Case(name: "熔断：403 计数（被拦 = 源够不到）") {
                let b = SourceBreaker(limit: 3, cooldown: 120)
                for _ in 0..<3 { b.recordFailure("o", reason: .blocked) }
                return b.shouldSkip("o") != nil
            },
            Case(name: "熔断：不同源互不影响") {
                let b = SourceBreaker(limit: 3, cooldown: 120)
                for _ in 0..<3 { b.recordFailure("a", reason: .timeout) }
                return b.shouldSkip("a") != nil && b.shouldSkip("b") == nil
            },

            // ── 章号归一化（v4「织」引擎的地基：跨源对齐的唯一依据）──────
            // 这些用例全部取自 6 个图源真实出现过的写法。
            // ⚠️ 这一组挂了 = 拼源会错页，比「打不开」严重得多。
            Case(name: "章号：第12话 → 12") {
                ChapterKeyParser.parse("第12话")?.no == 12
            },
            Case(name: "章号：第12話（繁体）→ 12") {
                ChapterKeyParser.parse("第12話")?.no == 12
            },
            Case(name: "章号：Ch.12 → 12") {
                ChapterKeyParser.parse("Ch.12")?.no == 12
            },
            Case(name: "章号：chapter 12 → 12") {
                ChapterKeyParser.parse("chapter 12")?.no == 12
            },
            Case(name: "章号：#12 → 12") {
                ChapterKeyParser.parse("#12")?.no == 12
            },
            Case(name: "章号：纯数字 12 → 12") {
                ChapterKeyParser.parse("12")?.no == 12
            },
            Case(name: "章号：第十二话 → 12") {
                ChapterKeyParser.parse("第十二话")?.no == 12
            },
            Case(name: "章号：第一百二十话 → 120") {
                ChapterKeyParser.parse("第一百二十话")?.no == 120
            },
            Case(name: "章号：一千零一话 → 1001") {
                ChapterKeyParser.parse("第一千零一话")?.no == 1001
            },
            Case(name: "章号：第12.5话 → 12.5") {
                ChapterKeyParser.parse("第12.5话")?.no == 12.5
            },
            Case(name: "章号：全角 １２ 也能认") {
                ChapterKeyParser.parse("第１２话")?.no == 12
            },
            Case(name: "章号：序章 → 0") {
                ChapterKeyParser.parse("序章")?.no == 0
            },
            // 番外类必须落在负数区，否则「番外1」会排到「第1话」前面
            Case(name: "章号：番外1 → 负数") {
                (ChapterKeyParser.parse("番外1")?.no ?? 1) < 0
            },
            Case(name: "章号：番外2 与 外传1 不撞号") {
                guard let a = ChapterKeyParser.parse("番外2")?.no,
                      let b = ChapterKeyParser.parse("外传1")?.no else { return false }
                return a < 0 && b < 0 && a != b
            },
            Case(name: "章号：第3卷第12话 → 取 12 不是 3") {
                ChapterKeyParser.parse("第3卷第12话")?.no == 12
            },
            Case(name: "章号：Vol.3 Ch.12 不能串成 3") {
                ChapterKeyParser.parse("Vol.3 Ch.12")?.no == 12
            },
            // 置信度闸门：不可靠的解析绝不能参与跨源对齐
            Case(name: "对齐：两个可信且同号 → 可对齐") {
                ChapterKeyParser.alignable(ChapterKeyParser.parse("第12话"),
                                           ChapterKeyParser.parse("Ch.12"))
            },
            Case(name: "对齐：番外与正文同数字 → 不可对齐") {
                !ChapterKeyParser.alignable(ChapterKeyParser.parse("番外1"),
                                            ChapterKeyParser.parse("第1话"))
            },
            Case(name: "对齐：低置信（含年份）→ 不可对齐") {
                let a = ChapterKeyParser.parse("2024年12月更新")
                return a != nil && !a!.isTrustworthy
                    && !ChapterKeyParser.alignable(a, ChapterKeyParser.parse("第12话"))
            },

            // ── 发现栏目专用列表规则（tuku.cc 改版：栏目页与搜索页是两个 DOM）──
            Case(name: "发现补丁：tuku 用新列表选择器且不改原对象") {
                var s = ComicSource()
                s.bookSourceUrl = "https://www.tuku.cc"
                s.ruleSearchList = "class.manga-content-item"
                let c = SourceContentPatch.sourceForExplore(s)
                // 副本换成新选择器，原对象保持旧值（搜索页仍靠旧规则）
                return c.ruleSearchList == "class.swiper-card-item"
                    && s.ruleSearchList == "class.manga-content-item"
            },
            Case(name: "发现补丁：未登记的源原样返回") {
                var s = ComicSource()
                s.bookSourceUrl = "https://example.com"
                s.ruleSearchList = "class.foo"
                let c = SourceContentPatch.sourceForExplore(s)
                return c.ruleSearchList == "class.foo"
                    && c.ruleSearchName == s.ruleSearchName
            },
            // 源 JSON 已用 `||` 兼容新旧 DOM 时，补丁**不能**把它降级成单选择器
            Case(name: "发现补丁：已有 || 双选择器时不覆盖") {
                var s = ComicSource()
                s.bookSourceUrl = "https://www.tuku.cc"
                s.ruleSearchList = "class.manga-content-item||class.swiper-card-item"
                let c = SourceContentPatch.sourceForExplore(s)
                return c.ruleSearchList == s.ruleSearchList
            },

            // ── 封面 Referer 归一化（2026-10-29 真机：瓜子封面全 403）────────
            //
            // 瓜子图床对 Referer 做**严格前缀匹配**，少一个尾斜杠就判盗链：
            //   `https://www.guazimanhua.com`  → 403 / 4548B
            //   `https://www.guazimanhua.com/` → 200 / 118KB
            // 而 `bookSourceUrl` 存的正是**无尾斜杠**的形式 → 该源封面永远 403。
            Case(name: "Referer：裸源站补尾斜杠") {
                HMDImagePipeline.normalizedReferer("https://www.guazimanhua.com")
                    == "https://www.guazimanhua.com/"
            },
            Case(name: "Referer：带路径的原样保留") {
                let r = "https://www.tuku.cc/comics-p1/"
                return HMDImagePipeline.normalizedReferer(r) == r
            },
            // Legado 里 `-` = 显式不带 Referer。原样发 `Referer: -` 会 403 / 4548B
            // （瓜子实测），必须映射成空串 —— 空串在 request() 里表示「不设这个头」。
            Case(name: "Referer：`-` 视为不发送") {
                HMDImagePipeline.normalizedReferer("-").isEmpty
            },
            Case(name: "Referer：空串仍为空") {
                HMDImagePipeline.normalizedReferer("   ").isEmpty
            },

            // ── 章节补全的判据（2026-10-29「更快更精确」）────────────────
            //
            // 详情页两阶段加载里，第二阶段（分页探测）只在两个条件下才可能有新内容：
            // 源配了 `ruleChapterUrlNext`，或页面里有分页痕迹。
            // 判据错判成「有分页」→ 白跑一次完整解析（图库 2672 章 = 2.1 秒）；
            // 错判成「没分页」→ 章节只显示第一页（更严重）。
            // 这里用最小样本锁住「不误报 / 不漏报」两个方向。
            Case(name: "分页痕迹：普通章节列表不误报") {
                !UniversalParser.hasPaginationHint(
                    "<div class='chapters'><a href='/c/1'>第1话</a><a href='/c/2'>第2话</a></div>")
            },
            Case(name: "分页痕迹：出现「下一页」即命中") {
                UniversalParser.hasPaginationHint("<a href='?page=2'>下一页</a>")
            },
            Case(name: "分页痕迹：空页面不误报") {
                !UniversalParser.hasPaginationHint("")
            },

            // ── 挑战页判定（2026-10-29 真机抓到的误判）──────────────────
            //
            // 漫画网详情页 45KB 的**正常** HTML 里含一句 Cloudflare JS 检测信标
            //   `a.src='/cdn-cgi/challenge-platform/scripts/jsd/main.js'`
            // 旧强特征表里有 `"challenge-platform"` → 判成挑战页 → 走完 L1/L2/L3
            // → 返回空串。真机日志：`全链失败 status=200 bytes=45659`。
            Case(name: "挑战判定：CF 正常页的 jsd 信标不误判") {
                let body = "<html><body><script>var a=document.createElement('script');"
                    + "a.src='/cdn-cgi/challenge-platform/scripts/jsd/main.js';</script>"
                    + String(repeating: "<div>正文内容</div>", count: 120)
                    + "</body></html>"
                return !AntiBot.isChallenge(status: 200, headers: [:], body: body)
            },
            // 反过来：真的挑战页必须还能认出来，否则「过挑战」整条链就失效了
            Case(name: "挑战判定：真实挑战页仍能认出") {
                let body = "<html><head><title>Just a moment...</title></head>"
                    + "<body><form id=\"challenge-form\" action=\"/x\"></form></body></html>"
                return AntiBot.isChallenge(status: 200, headers: [:], body: body)
            },
            Case(name: "挑战判定：2xx 且无强特征 → 不算挑战") {
                !AntiBot.isChallenge(status: 200, headers: [:],
                                     body: "<html><body>正常漫画列表</body></html>")
            },

            // ── 底栏占用（2026-10-29「打开漫画后底栏又冒出来」）────────────
            //
            // 旧实现是 `hidden: Bool`，阅读器 onAppear 置 true / onDisappear 置 false。
            // SwiftUI 重复触发回调时，多一次 onDisappear 就把底栏放出来了。
            // 现在用「占用者 token 集合」，这两条锁住关键行为。
            Case(name: "底栏：重复 hide/restore 幂等") {
                let b = ShellBarState()
                b.hide(owner: "reader")
                b.hide(owner: "reader")     // 重复 onAppear
                let hid = b.hidden
                b.restore(owner: "reader")
                b.restore(owner: "reader")  // 重复 onDisappear
                return hid && !b.hidden
            },
            Case(name: "底栏：旧实例退出不影响新实例") {
                let b = ShellBarState()
                b.hide(owner: "old")
                b.hide(owner: "new")        // 阅读器被重建，新实例占位
                b.restore(owner: "old")     // 旧实例 onDisappear 迟到
                return b.hidden             // 新实例还在阅读 → 必须保持隐藏
            },
            Case(name: "底栏：reset 强制恢复") {
                let b = ShellBarState()
                b.hide(owner: "a")
                b.hide(owner: "b")
                b.reset()
                return !b.hidden
            },
        ]

        var failed: [String] = []
        for c in cases where !c.run() { failed.append(c.name) }

        if failed.isEmpty {
            DiagLog.event("selftest", "pass", "纯逻辑自检 \(cases.count)/\(cases.count) 通过 ✅")
        } else {
            DiagLog.event("selftest", "FAIL",
                          "纯逻辑自检 失败 \(failed.count)/\(cases.count)：\(failed.joined(separator: "；"))")
        }
    }
}
