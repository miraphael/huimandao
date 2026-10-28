import SwiftUI

/// ──────────────────────────────────────────────────────────────────────────
/// 设计预览 —— 「两面」视觉底座的**真机验收页**
///
/// 入口：设置 → 存储与诊断 下方「设计预览（开发）」
///
/// ## 为什么要有这一页
/// F1 阶段只新增材质与翻面容器，**不改任何业务界面**。但如果没地方看，
/// 就等于没做 —— 装到手机上找不到任何变化。
/// 这一页把所有新东西摆在一起：色板、字阶、两种材质、三个可翻面的样例、网点、状态。
///
/// 它同时是一份**活文档**：以后改令牌，这里立刻能看出影响。
/// 正式版上线前可以删掉（或收进「开发者选项」）。
/// ──────────────────────────────────────────────────────────────────────────
struct DesignPreviewView: View {

    @State private var bookFlipped = false
    @State private var chapterFlipped = false
    @State private var sourceFlipped = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Space.xxl) {
                headerBlock
                colorBlock
                typeBlock
                materialBlock
                flipBlock
                halftoneBlock
                stateBlock
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.top, Ink.Space.m)
            .padding(.bottom, Ink.Space.huge)
        }
        .background(InkPaper())
        .navigationTitle("设计预览")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 页头

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("H U I M A N D A O")
                .font(.inkDraft(8))
                .foregroundStyle(Ink.ver)
            Text("两面")
                .font(.inkMasthead(34))
                .foregroundStyle(Ink.ink)
            Text("正面是漫画，背面是它的来路。点右上折角翻面。")
                .font(.inkCaption())
                .foregroundStyle(Ink.ash)
        }
    }

    // MARK: - 色板

    private var swatches: [(String, Color)] {
        [("纸白", Ink.paper), ("卡白", Ink.card), ("草稿", Ink.draft),
         ("墨黑", Ink.ink), ("石墨", Ink.graphite), ("朱红", Ink.ver),
         ("红笔", Ink.pencil), ("靛蓝", Ink.indigo), ("苔绿", Ink.moss),
         ("赭黄", Ink.ochre), ("灰墨", Ink.ash), ("淡墨", Ink.faint)]
    }

    private var colorBlock: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            sectionTitle("色彩", "C O L O R")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                      spacing: 10) {
                ForEach(swatches.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 5) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(swatches[i].1)
                            .frame(height: 40)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .strokeBorder(Ink.line, lineWidth: 0.8)
                            )
                        Text(swatches[i].0)
                            .font(.inkDraft(8))
                            .foregroundStyle(Ink.ash)
                    }
                }
            }
        }
    }

    // MARK: - 字阶

    private var typeBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("字体", "T Y P E")
            typeRow("32 / 700 / 衬线") {
                Text("书架").font(.inkMasthead(28)).foregroundStyle(Ink.ink)
            }
            typeRow("22 / 700 / 衬线") {
                Text("海贼王").font(.inkTitle(20)).foregroundStyle(Ink.ink)
            }
            typeRow("15 / 650 / 无衬线") {
                Text("今日号外 · 3 本更新").font(.inkSection()).foregroundStyle(Ink.ink)
            }
            typeRow("15 / 400 / 无衬线") {
                Text("「想要我的财宝吗？」").font(.inkBody(14)).foregroundStyle(Ink.ash)
            }
            typeRow("11 / 600 / 等宽") {
                Text("VOL.42 · CH.128").font(.inkNumeral(11)).foregroundStyle(Ink.ash)
            }
        }
    }

    private func typeRow<C: View>(_ spec: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(spec)
                .font(.inkDraft(8))
                .foregroundStyle(Ink.faint)
                .frame(width: 106, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }

    // MARK: - 两种材质

    private var materialBlock: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            sectionTitle("材质", "M A T E R I A L")
            HStack(alignment: .top, spacing: 10) {
                materialTile(title: "印刷面", en: "F R O N T", draft: false)
                materialTile(title: "草稿面", en: "B A C K", draft: true)
            }
        }
    }

    private func materialTile(title: String, en: String, draft: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if draft {
                    DraftPaper(grid: 16)
                } else {
                    InkPaper(fullBleed: false)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if draft {
                        Text("来 源 分 布")
                            .font(.inkDraft(7.5))
                            .foregroundStyle(Ink.graphite.opacity(0.62))
                        Text("卡拉 ███ 1–40")
                            .font(.inkDraft(8.5))
                            .foregroundStyle(Ink.graphite)
                        Text("漫画 ██  41–60")
                            .font(.inkDraft(8.5))
                            .foregroundStyle(Ink.graphite)
                    } else {
                        Text("海贼王")
                            .font(.inkTitle(17))
                            .foregroundStyle(Ink.ink)
                        Text("VOL.1128")
                            .font(.inkNumeral(8))
                            .foregroundStyle(Ink.faint)
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 106)
            .clipShape(RoundedRectangle(cornerRadius: Ink.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Ink.Radius.card, style: .continuous)
                    .strokeBorder(Ink.line, lineWidth: 0.8)
            )

            Text(title).font(.inkCaption()).foregroundStyle(Ink.ash)
            Text(en).font(.inkDraft(7.5)).foregroundStyle(Ink.faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 翻面

    private var flipBlock: some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            sectionTitle("翻面", "F L I P")

            FlipCard(flipped: $bookFlipped, axis: .horizontal) {
                bookFront
            } back: {
                bookBack
            }
            .frame(width: 300, height: 392)

            FlipCard(flipped: $chapterFlipped, axis: .vertical) {
                chapterFront
            } back: {
                chapterBack
            }
            .frame(height: 96)

            FlipCard(flipped: $sourceFlipped, axis: .vertical) {
                sourceFront
            } back: {
                sourceBack
            }
            .frame(height: 96)
        }
    }

    private var bookFront: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                gradient: Gradient(colors: [Color(hex: "#C8452F") ?? .red,
                                            Color(hex: "#8E2A1C") ?? .brown,
                                            Color(hex: "#5C1A10") ?? .black]),
                startPoint: .topLeading, endPoint: .bottomTrailing)
            LinearGradient(gradient: Gradient(colors: [.clear, .black.opacity(0.62)]),
                           startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 6) {
                Text("V O L . 1 1 2 8")
                    .font(.inkNumeral(9))
                    .foregroundStyle(.white.opacity(0.82))
                Text("海贼王")
                    .font(.inkTitle(27))
                    .foregroundStyle(.white)
                Text("尾田荣一郎 · 连载中")
                    .font(.inkCaption())
                    .foregroundStyle(.white.opacity(0.76))
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bookBack: some View {
        ZStack(alignment: .topLeading) {
            DraftPaper(grid: 16)
            VStack(alignment: .leading, spacing: 9) {
                Text("来 源 分 布")
                    .font(.inkDraft(8))
                    .foregroundStyle(Ink.graphite.opacity(0.62))
                draftBar("卡拉", width: 0.33, range: "1–40")
                draftBar("漫画网", width: 0.17, range: "41–60")
                draftBar("W漫画", width: 0.50, range: "61–120")
                Rectangle()
                    .fill(Ink.graphite.opacity(0.22))
                    .frame(height: 1)
                    .padding(.vertical, 3)
                draftKV("覆 盖", "100% · 无缺章")
                draftKV("最 近 验 证", "2 分钟前")
                draftKV("页 均 耗 时", "0.8s")
                draftKV("脆 弱 区", "CH.1–12 单源")
                Spacer(minLength: 0)
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func draftBar(_ name: String, width: CGFloat, range: String) -> some View {
        HStack(spacing: 7) {
            Text(name)
                .font(.inkDraft(9))
                .foregroundStyle(Ink.graphite)
                .frame(width: 44, alignment: .leading)
            Capsule()
                .fill(Ink.graphite.opacity(0.14))
                .frame(height: 5)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Ink.graphite.opacity(0.62))
                        .scaleEffect(x: width, y: 1, anchor: .leading)
                }
            Text(range)
                .font(.inkDraft(8))
                .foregroundStyle(Ink.graphite.opacity(0.66))
                .frame(width: 46, alignment: .trailing)
        }
    }

    private func draftKV(_ key: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.inkDraft(9))
                .foregroundStyle(Ink.graphite.opacity(0.66))
            Spacer(minLength: 0)
            Text(value)
                .font(.inkDraft(9))
                .foregroundStyle(Ink.graphite)
        }
    }

    private var chapterFront: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("C H . 0 1 2")
                    .font(.inkNumeral(9))
                    .foregroundStyle(Ink.faint)
                Text("传说开始了")
                    .font(.inkTitle(16))
                    .foregroundStyle(Ink.ink)
            }
            Spacer(minLength: 0)
            Text("读至 34%")
                .font(.inkNumeral(10))
                .foregroundStyle(Ink.ver)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Ink.card)
        .inkEdge()
    }

    private var chapterBack: some View {
        ZStack(alignment: .topLeading) {
            DraftPaper(grid: 14)
            VStack(alignment: .leading, spacing: 5) {
                Text("这 一 话 的 三 个 来 源")
                    .font(.inkDraft(7.5))
                    .foregroundStyle(Ink.graphite.opacity(0.6))
                sourceLine("卡拉", "18 页", "0.6s", ok: true)
                sourceLine("漫画网", "18 页", "0.9s", ok: true)
                sourceLine("W漫画", "20 页", "✗ 页数不同", ok: false)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sourceFront: some View {
        HStack(spacing: 12) {
            Text("卡拉漫画")
                .font(.inkTitle(16))
                .foregroundStyle(Ink.ink)
            Spacer(minLength: 0)
            Text("● 24 栏目")
                .font(.inkNumeral(10))
                .foregroundStyle(Ink.moss)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Ink.card)
        .inkEdge()
    }

    private var sourceBack: some View {
        ZStack(alignment: .topLeading) {
            DraftPaper(grid: 14)
            VStack(alignment: .leading, spacing: 5) {
                Text("这 个 源 现 在 什 么 状 态")
                    .font(.inkDraft(7.5))
                    .foregroundStyle(Ink.graphite.opacity(0.6))
                draftKV("规 则", "24 条 · 更新于 10-26")
                draftKV("近 20 次", "成功 19 / 失败 1")
                draftKV("承 担", "本书 CH.1–40")
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sourceLine(_ name: String, _ pages: String, _ tail: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.inkDraft(9))
                .foregroundStyle(Ink.graphite)
                .frame(width: 48, alignment: .leading)
            Text(pages)
                .font(.inkDraft(9))
                .foregroundStyle(Ink.graphite.opacity(0.7))
                .frame(width: 38, alignment: .trailing)
            Spacer(minLength: 0)
            Text(tail)
                .font(.inkDraft(9))
                .foregroundStyle(ok ? Ink.moss : Ink.pencil)
        }
    }

    // MARK: - 网点

    private var halftoneBlock: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            sectionTitle("网点", "H A L F T O N E")
            HStack(spacing: 10) {
                ZStack {
                    Ink.card
                    HalftoneView(opacity: 0.22)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 92)
                .clipShape(RoundedRectangle(cornerRadius: Ink.Radius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Ink.Radius.card, style: .continuous)
                        .strokeBorder(Ink.line, lineWidth: 0.8)
                )

                ZStack {
                    Ink.card
                    HalftoneView(opacity: 0.32, fadesOut: true)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 92)
                .clipShape(RoundedRectangle(cornerRadius: Ink.Radius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Ink.Radius.card, style: .continuous)
                        .strokeBorder(Ink.line, lineWidth: 0.8)
                )
            }
        }
    }

    // MARK: - 状态

    private var stateBlock: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            sectionTitle("状态", "S T A T E S")

            // 骨架：网点呼吸 + 内容等高的灰条（不是居中转圈）
            HStack(spacing: 12) {
                ZStack {
                    Ink.lineSoft
                    HalftoneView(opacity: 0.16)
                }
                .frame(width: 54, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))

                VStack(alignment: .leading, spacing: 7) {
                    Capsule().fill(Ink.lineSoft).frame(width: 130, height: 9)
                    Capsule().fill(Ink.lineSoft).frame(width: 84, height: 7)
                    Capsule().fill(Ink.lineSoft).frame(width: 104, height: 7)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Ink.card)
            .inkEdge()
            .overlay(alignment: .topLeading) {
                Text("骨架").font(.inkDraft(7)).foregroundStyle(Ink.faint).padding(5)
            }

            // 错误：原因 + 下一步（禁止只写"加载失败"）
            VStack(alignment: .leading, spacing: 5) {
                Text("图片地址失效")
                    .font(.inkTitle(15))
                    .foregroundStyle(Ink.ink)
                Text("这个源的图床挂了，建议换一个源。")
                    .font(.inkCaption())
                    .foregroundStyle(Ink.ash)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Ink.card)
            .inkEdge()
        }
    }

    // MARK: - 小工具

    private func sectionTitle(_ zh: String, _ en: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(zh).font(.inkSection()).foregroundStyle(Ink.ink)
            Text(en).font(.inkDraft(7.5)).foregroundStyle(Ink.faint)
            Spacer(minLength: 0)
        }
        .padding(.bottom, 4)
    }
}
