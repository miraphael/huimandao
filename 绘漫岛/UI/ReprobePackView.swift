import SwiftUI
import UniformTypeIdentifiers
import Foundation

/// 导入源核「重探补丁包」—— **先看清差异，再决定要不要应用**
///
/// 与普通「导入图源」的区别：这里把每个源**改了哪几个字段、旧规则多少分、新的多少分、
/// 证据有几条章节几张图**都摊开给用户看，逐条勾选后应用。
/// 覆盖规则是破坏性操作，不能让用户盲导。
struct ReprobePackView: View {
    @State private var plans: [ReprobePack.Plan] = []
    @State private var selection: Set<String> = []
    @State private var skipped = 0
    @State private var showPicker = false
    @State private var showURLSheet = false
    @State private var urlText = ""
    @State private var msg = ""

    private var existing: [ComicSource] { ComicRepository.shared.allSources() }

    var body: some View {
        Group {
            if plans.isEmpty {
                EmptyState(title: "还没有加载补丁包", systemImage: "square.and.arrow.down",
                           description: "选择源核重探产出的 .json 补丁包。\n加载后会列出每个源要改哪些字段，勾完再应用。")
            } else {
                List {
                    Section {
                        ForEach(plans, id: \.item.source.bookSourceUrl) { p in
                            Button {
                                toggle(p)
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: selection.contains(p.item.source.bookSourceUrl)
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selection.contains(p.item.source.bookSourceUrl) ? .green : .secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(displayName(p)).font(.callout).lineLimit(1)
                                            Spacer()
                                            Text(p.isNew ? "新增" : "修复")
                                                .font(.caption2)
                                                .foregroundStyle(p.isNew ? .blue : .orange)
                                        }
                                        Text(URL(string: p.item.source.bookSourceUrl)?.host
                                             ?? p.item.source.bookSourceUrl)
                                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                        Text(changeLine(p))
                                            .font(.caption2).foregroundStyle(.secondary)
                                        Text("改：\(p.item.changedFields.joined(separator: "、"))")
                                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("共 \(plans.count) 个源\(skipped > 0 ? "（跳过 \(skipped) 条无法解析）" : "")")
                    } footer: {
                        Text("应用时保留你现有的启用/禁用状态和发现页栏目；只更新解析规则字段。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .transparentScrollBackground()
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("重探补丁包")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    Button("拉取") {
                        if urlText.isEmpty { urlText = AppSettings.shared.reprobePackUrl }
                        showURLSheet = true
                    }
                    Button("全选") { selection = Set(plans.map { $0.item.source.bookSourceUrl }) }
                        .disabled(plans.isEmpty)
                    Button("应用\(selection.isEmpty ? "" : "(\(selection.count))")") { applySelected() }
                        .disabled(selection.isEmpty)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if plans.isEmpty {
                Button {
                    showPicker = true
                } label: {
                    Label("选择补丁包文件", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.json, .text, .data]) { result in
            guard case .success(let url) = result else { return }
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            guard let t = try? String(contentsOf: url, encoding: .utf8) else {
                msg = "文件读不出来"
                return
            }
            load(t)
        }
        .sheet(isPresented: $showURLSheet) {
            NavigationStack {
                Form {
                    Section("补丁包地址") {
                        TextField("https://.../reprobe_pack.json", text: $urlText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                    Section {
                        Text("从源核重探产出的补丁包地址拉取；应用逻辑与本地导入一致（逐条勾选、保留启用状态与发现页栏目）。地址填好后可存进「设置 → 重探补丁包地址」以便一键更新。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .transparentScrollBackground()
                .navigationTitle("拉取远程补丁包")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("取消") { showURLSheet = false }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("拉取") {
                            let u = urlText
                            showURLSheet = false
                            Task { await fetchRemote(u) }
                        }
                        .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .alert("提示", isPresented: Binding(
            get: { !msg.isEmpty },
            set: { if !$0 { msg = "" } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(msg)
        }
        .task {
            // 一键更新：若已存远程地址且还没加载过，进页面就自动拉一次
            let stored = AppSettings.shared.reprobePackUrl
            guard !stored.isEmpty, plans.isEmpty else { return }
            await fetchRemote(stored)
        }
    }

    private func fetchRemote(_ raw: String) async {
        let u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return }
        do {
            let text = try await ReprobePack.download(u)
            await MainActor.run {
                AppSettings.shared.reprobePackUrl = u   // 持久化，下次进页面可一键更新
                load(text)
            }
        } catch {
            await MainActor.run { msg = "拉取失败：\(error.localizedDescription)" }
        }
    }

    private func displayName(_ p: ReprobePack.Plan) -> String {
        if !p.existingName.isEmpty { return p.existingName }
        let n = p.item.source.bookSourceName
        return n.isEmpty ? "(未命名)" : n
    }

    private func changeLine(_ p: ReprobePack.Plan) -> String {
        let e = p.item.evidence
        if p.isNew {
            return "新源 · 列表\(e.list) / 章\(e.chapter) / 图\(e.image)"
        }
        return "质量 \(p.item.oldQuality) → \(p.item.newQuality) · 列表\(e.list) / 章\(e.chapter) / 图\(e.image)"
    }

    private func toggle(_ p: ReprobePack.Plan) {
        let k = p.item.source.bookSourceUrl
        if selection.contains(k) { selection.remove(k) } else { selection.insert(k) }
    }

    private func load(_ text: String) {
        let (items, skip) = ReprobePack.parse(text)
        skipped = skip
        plans = ReprobePack.plan(items, existing: existing)
        // 默认只勾「修复」中不降低质量的；新增源默认勾上
        selection = Set(plans.filter { $0.isNew || $0.item.newQuality > $0.item.oldQuality }
            .map { $0.item.source.bookSourceUrl })
        msg = plans.isEmpty
            ? "这个文件里没有可用的补丁（可能不是重探产出的包）"
            : "已加载 \(plans.count) 个源，默认勾选了有改进的 \(selection.count) 个"
    }

    private func applySelected() {
        let chosen = plans.filter { selection.contains($0.item.source.bookSourceUrl) }
            .map { $0.item.source }
        guard !chosen.isEmpty else { return }
        let n = ReprobePack.apply(chosen, existing: existing)
        msg = "已应用 \(n) 个源的规则更新（启用状态与发现页栏目保持不变）"
        plans = []
        selection = []
    }
}
