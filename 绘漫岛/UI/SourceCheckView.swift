import SwiftUI
import UIKit

/// 图源批量体检页
///
/// ── 为什么要有「全链路」这一档 ────────────────────────────────────────
/// 用户报的是「**很多源显示不出章节**」。旧的检验只走到「列表」就下结论，
/// 于是大量「列表能出、章节恒 0」的源全被判成 ✅ —— 体检结果和实际体验对不上。
/// 现在按 `入口 → 列表 → 详情 → 章节 → 正文` 逐段判定，并直接告诉用户断在哪一环。
struct SourceCheckView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case quick = "快速（只到列表）"
        case full = "全链路（含章节+正文）"
        var id: String { rawValue }
    }

    @State private var results: [SourceCheckResult] = []
    @State private var running = false
    @State private var doneCount = 0
    @State private var sources: [ComicSource] = []
    @State private var mode: Mode = .full
    @State private var reportURL: URL? = nil
    @State private var confirmKeepOnlyOK = false
    /// 「删除全部失败源」的二次确认（不可恢复操作）
    @State private var confirmDeleteFailed = false
    /// 批量操作 / 体检收尾的提示（不静默：用户点了要知道结果）
    @State private var updateMsg = ""
    /// 只看失败项（默认开 —— 用户最关心的是「哪些不能用」）
    @State private var onlyFailed = true

    var body: some View {
        VStack(spacing: 0) {
            summaryBar
            if !running && !results.isEmpty { stageBreakdown }
            reprobeLoopSection
            resultList
        }
        .navigationTitle("图源体检")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("检验档位", selection: $mode) {
                        ForEach(Mode.allCases) { m in Text(m.rawValue).tag(m) }
                    }
                    .disabled(running)
                    Divider()
                    Button { onlyFailed.toggle() } label: {
                        Label(onlyFailed ? "显示全部结果" : "只看失败项", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    Divider()
                    Button { running = false; Task { await start() } } label: {
                        Label("开始体检", systemImage: "stethoscope")
                    }
                    // ⚠️ 体检期间必须禁用：原先没有 `.disabled`，`start()` 开头也没有守卫
                    //    → 连点两次会**并发跑两份**：`doneCount` 被两个回调各加一次
                    //    （进度条冲到 200%）、`results` 互相覆盖、先跑完的那份把
                    //    `running` 置 false 而另一份还在跑（UI 显示「未运行」）。
                    .disabled(running)
                    Divider()
                    Button { exportReport() } label: {
                        Label("导出报告", systemImage: "square.and.arrow.up")
                    }
                    .disabled(results.filter { $0.checked }.isEmpty)
                    Divider()
                    Button(role: .destructive) { batchDisableFailed() } label: {
                        Label("停用全部失败源", systemImage: "pause.circle")
                    }
                    .disabled(failedCount == 0)
                    Button(role: .destructive) { confirmKeepOnlyOK = true } label: {
                        Label("只保留可用源（其余禁用）", systemImage: "checkmark.circle")
                    }
                    .disabled(failedCount == 0)
                    Button(role: .destructive) { confirmDeleteFailed = true } label: {
                        Label("删除全部失败源", systemImage: "trash")
                    }
                    .disabled(failedCount == 0)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("只保留体检通过的图源？", isPresented: $confirmKeepOnlyOK, titleVisibility: .visible) {
            Button("确定（其余全部禁用）", role: .destructive) { keepOnlyOK() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("未通过的 \(failedCount) 个源会被禁用（不删除，随时可在图源管理里重新启用）。")
        }
        // ⚠️ 「删除全部失败源」是**不可恢复**的操作，必须二次确认。
        //    原先它是菜单里一点就直落 `deleteSources` —— 比它更温和的
        //    「只保留可用源（其余禁用）」反倒有确认，顺序完全反了。
        .confirmationDialog("删除全部失败源？", isPresented: $confirmDeleteFailed, titleVisibility: .visible) {
            Button("永久删除 \(failedCount) 个源", role: .destructive) { batchDeleteFailed() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会从图源库里永久删除这些源，**无法撤销**（若要保留可改用「停用」）。")
        }
        .task {
            if results.isEmpty { await start() }
        }
        .alert("提示", isPresented: Binding(
            get: { !updateMsg.isEmpty },
            set: { if !$0 { updateMsg = "" } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(updateMsg)
        }
    }

    // MARK: - 汇总条

    private var summaryBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Label("\(doneCount)/\(sources.count)", systemImage: "checklist")
                Label("✅ \(okCount)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("❌ \(failedCount)", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                Spacer()
                if running { ProgressView().scaleEffect(0.8) }
            }
            .font(.callout)
            if running {
                ProgressView(value: Double(doneCount), total: Double(max(sources.count, 1)))
            }
        }
        .padding(10)
        .background(.bar)
    }

    /// 失败环节分布 —— 一眼看出是「站点没了」还是「规则不匹配」
    private var stageBreakdown: some View {
        let groups = Dictionary(grouping: results.filter { $0.checked && !$0.ok }, by: { $0.stage })
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(groups.keys.sorted(), id: \.self) { k in
                    Text("\(k) \(groups[k]?.count ?? 0)")
                        .font(.caption2)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    // MARK: - 再探闭环状态

    /// 展示「自动调整」的当前状态，让用户看得见闭环做了什么、还能撤销。
    ///
    /// 没有这块的话，用户只会发现「我的源怎么少了」却找不到原因 ——
    /// 自动禁用必须是**可见且可撤销**的，否则和 bug 没区别。
    @ViewBuilder
    private var reprobeLoopSection: some View {
        let autos = SourceReprobeLoop.autoDisabledUrls()
        let counts = SourceReprobeLoop.failCountsSnapshot().filter { $0.count > 0 }
        if !autos.isEmpty || !counts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("自动调整", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("全部还原") {
                        SourceReprobeLoop.reset()
                        // 把被自动禁用的源重新打开
                        for u in autos { ComicRepository.shared.setEnable(url: u, enable: true) }
                        updateMsg = "已还原所有自动调整（源恢复为你的手动状态）"
                    }
                    .font(.caption2)
                }
                if !autos.isEmpty {
                    Text("已自动停用 \(autos.count) 个连续 \(SourceReprobeLoop.failThreshold) 次打不开的源")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if !counts.isEmpty {
                    let preview = counts.prefix(3)
                        .map { "\(SourceHealth.displayName(forUrl: $0.url) ?? $0.url) \($0.count)次" }
                        .joined(separator: "、")
                    Text("失败计数：\(preview)\(counts.count > 3 ? " 等" : "")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text("规则：连续 \(SourceReprobeLoop.failThreshold) 次确定性失败才停用；"
                     + "只恢复本功能自己停用的源，不碰你手动关闭的。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08))
        }
    }

    // MARK: - 结果列表

    private var resultList: some View {
        List {
            ForEach(shown) { r in
                HStack(spacing: 10) {
                    Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(r.ok ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.name.isEmpty ? "(未命名)" : r.name).lineLimit(1)
                        Text(subtitle(r)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    if r.chapters > 0 {
                        Text("\(r.chapters)章").font(.caption2)
                            .foregroundStyle(r.ok ? .green : .orange)
                    }
                }
            }
            ForEach(results.filter { !$0.checked }) { r in
                HStack {
                    ProgressView()
                    Text(r.name.isEmpty ? "(未命名)" : r.name).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
            }
        }
        .transparentScrollBackground()
        .listStyle(.plain)
    }

    private func subtitle(_ r: SourceCheckResult) -> String {
        let stage = r.stage.isEmpty ? "" : "[\(r.stage)] "
        return "\(stage)\(r.message) · \(r.ms)ms"
    }

    private var shown: [SourceCheckResult] {
        let checked = results.filter { $0.checked }
        let list = onlyFailed ? checked.filter { !$0.ok } : checked
        // 失败的排前面
        return list.sorted { a, b in
            if a.ok != b.ok { return !a.ok }
            return a.name < b.name
        }
    }

    private var okCount: Int { results.filter { $0.checked && $0.ok }.count }
    private var failedCount: Int { results.filter { $0.checked && !$0.ok }.count }

    // MARK: - 动作

    private func start() async {
        // ⚠️ 守卫：防止并发跑两份体检（UI 已 `.disabled(running)`，这里是第二道防线）
        guard !running else { return }
        running = true
        reportURL = nil
        // 体检范围：只查启用中的源（用户关心的是「我现在能用的有哪些」）
        sources = ComicRepository.shared.allSources(includeDisabled: false)
        results = sources.map {
            SourceCheckResult(name: $0.bookSourceName, sourceUrl: $0.bookSourceUrl,
                              ok: false, ms: 0, message: "等待体检")
        }
        doneCount = 0
        let useFull = (mode == .full)
        let all = sources
        await SourceValidator.run(all, threads: useFull ? 6 : 8, full: useFull,
                                  probeContent: useFull) { r in
            DispatchQueue.main.async {
                if let idx = self.results.firstIndex(where: { $0.sourceUrl == r.sourceUrl }) {
                    self.results[idx] = r
                }
                self.doneCount += 1
            }
        }
        reportURL = SourceValidator.writeReport(results)
        // 把「手机自己的体检结果」写进健康清单 —— 图源列表的角标从此以**手机实测**为准，
        // 而不是那份随发版固化的桌面报告（两者网络环境不同）。
        let merged = SourceHealth.mergeObserved(results)
        if merged > 0 {
            updateMsg = "已用本次体检更新 \(merged) 个源的本地健康结论"
        }
        // ── 再探闭环 ────────────────────────────────────────────────
        // 体检结论不能只停在「列表上多了个角标」。这里把它作用到源库：
        // 连续失败达阈值的源自动停用；之前被自动停用、现在又好了的自动恢复。
        // ⚠️ 必须在主线程调用 —— `apply` 会写 `ComicRepository` 并发通知，
        //    从后台线程改源库会触发 SwiftUI 的「Publishing changes from background threads」。
        let outcome = SourceReprobeLoop.apply(results)
        if let s = outcome.summary {
            updateMsg = updateMsg.isEmpty ? s : updateMsg + "；" + s
        }
        running = false
    }

    private var failedUrls: [String] {
        results.filter { $0.checked && !$0.ok }.map { $0.sourceUrl }
    }

    private func batchDisableFailed() {
        for u in failedUrls { ComicRepository.shared.setEnable(url: u, enable: false) }
    }

    private func keepOnlyOK() {
        // ⚠️ 必须守卫：若在体检出结果前（或 `okUrls` 为空时）触发，
        //    下面的循环会把**所有**源停用（`okUrls` 空集 → 没有源能豁免）。
        //    按钮已 `.disabled(failedCount == 0)`，这里是第二道防线。
        guard failedCount > 0 else { return }
        let okUrls = Set(results.filter { $0.checked && $0.ok }.map { $0.sourceUrl })
        for s in ComicRepository.shared.allSources() where !okUrls.contains(s.bookSourceUrl) {
            ComicRepository.shared.setEnable(url: s.bookSourceUrl, enable: false)
        }
    }

    private func batchDeleteFailed() {
        ComicRepository.shared.deleteSources(urls: failedUrls)
        results.removeAll { !$0.ok && $0.checked }
    }

    private func exportReport() {
        let url = reportURL ?? SourceValidator.writeReport(results)
        guard let url else { return }
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        UIApplication.shared.topViewController()?.present(av, animated: true)
    }
}
