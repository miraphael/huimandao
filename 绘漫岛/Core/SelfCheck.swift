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
