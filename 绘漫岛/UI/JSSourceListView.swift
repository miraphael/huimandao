import SwiftUI
import UIKit
import PhotosUI

/// JS 类源管理（ARCHITECTURE §9.1）。
///
/// 与 JSON 规则源**分开管理**（分表 `JS_SOURCE`、校验规则与安全模型都不同），
/// 所以这里是独立页面，不混进 `SourceListView`。
///
/// ⚠️ 发布门槛（见 `JS隔离方案评估.md`）：JS 源**必须由用户显式导入**，
///    且界面必须明确告知「不保证超时保护」—— 恶意/死循环脚本会占住 JS 执行队列。
///    这个提示不是免责声明，是必须先让用户知道的使用前提。
struct JSSourceListView: View {
    @State private var items: [JSSourceStore.Item] = []
    @State private var showImport = false
    @State private var pendingDelete: JSSourceStore.Item? = nil
    /// 正在测试的源（非 nil 时弹出测试面板）
    @State private var testing: JSSourceStore.Item? = nil
    /// 正在编辑的源（非 nil 时弹出编辑面板）
    @State private var editing: JSSourceStore.Item? = nil

    var body: some View {
        List {
            Section {
                if items.isEmpty {
                    EmptyState(title: "还没有 JS 源",
                               systemImage: "curlybraces",
                               description: "JS 源是比 JSON 规则更灵活的一类图源（用 JavaScript 直接解析站点）。\n点右上角「+」粘贴 manifest JSON 导入。")
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(items) { item in
                        row(item)
                    }
                }
            } footer: {
                if !items.isEmpty {
                    Text("JS 源由第三方脚本驱动，App 不提供任何内容。死循环脚本可能占住解析队列，发布前请只导入可信来源。")
                        .font(.caption2)
                }
            }
        }
        .transparentScrollBackground()
        .navigationTitle("JS 源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImport = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showImport) {
            JSSourceImportSheet(onDone: reload)
        }
        .sheet(item: $testing) { item in
            JSSourceTestSheet(item: item)
        }
        .sheet(item: $editing) { item in
            JSSourceEditorSheet(id: item.id, onDone: reload)
        }
        .alert("删除这个 JS 源？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } })) {
            Button("删除", role: .destructive) {
                if let p = pendingDelete { JSSourceStore.remove(id: p.id); reload() }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete.map { "「\($0.name)」将被移除。" } ?? "")
        }
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .hmdJSSourcesChanged)) { _ in reload() }
    }

    @ViewBuilder
    private func row(_ item: JSSourceStore.Item) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.body)
                    if !item.version.isEmpty {
                        Text("v\(item.version)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.gray.opacity(0.12), in: Capsule())
                    }
                    // 「可终止」徽章：WKWebView 通道的源超时会被回收，不会卡死解析队列。
                    // 这是用户选择信任一个源时最该看到的差异，所以在列表上直接标出来。
                    if JSSourceStore.runtime(forID: item.id) == .wkwebview {
                        Text("可终止")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.green.opacity(0.85), in: Capsule())
                    }
                }
                Text(item.domain.isEmpty ? item.id : item.domain)
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { item.enabled },
                set: { v in
                    JSSourceStore.setEnabled(v, id: item.id)
                    reload()
                }))
                .labelsHidden()
        }
        .contextMenu {
            Button { editing = item } label: {
                Label("编辑", systemImage: "pencil")
            }
            Button { testing = item } label: {
                Label("测试搜索", systemImage: "magnifyingglass")
            }
            Button(role: .destructive) { pendingDelete = item } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func reload() {
        items = JSSourceStore.list()
        // 源集合变化 → 让注册表重新装载（搜索/详情会用到）。
        // ⚠️ 这里**不发** `.hmdJSSourcesChanged` —— 本视图已经订阅了它，
        //    再发会「通知自己 → reload → 再通知」无限递归。
        //    需要广播变化的是**其它**入口（如设置页统计、导入面板），本列表只管自己刷新。
        _ = SourceProviderRegistry.shared.loadFromStore()
    }
}

/// JS 源导入面板。
///
/// 与图源导入（JSON 规则）**分开**：这里导入的是**单个 manifest 对象**，
/// 不是图源数组；校验规则也不同（`apiVersion` 必须在支持区间内，否则直接拒绝）。
struct JSSourceImportSheet: View {
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var resultMsg: String? = nil
    /// 解析+校验成功时的预览（未点保存前不落库）
    @State private var preview: JSSourceManifest? = nil
    @State private var previewError: String? = nil
    @State private var fromWeb = ""
    @State private var downloading = false
    @State private var showFilePicker = false
    @State private var pickedPhoto: PhotosPickerItem? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 180)
                        .font(.system(.caption, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("粘贴 JS 源 manifest（JSON 对象）")
                } footer: {
                    Text("必填：id / name / version / apiVersion / domain / script / entry。apiVersion 必须为 1。")
                        .font(.caption2)
                }

                Section {
                    Button {
                        showFilePicker = true
                    } label: { Label("从文件导入（JSON/TXT）", systemImage: "doc") }
                    PhotosPicker(selection: $pickedPhoto, matching: .images) {
                        Label("从相册二维码导入", systemImage: "qrcode.viewfinder")
                    }
                } header: {
                    Text("从文件 / 二维码")
                } footer: {
                    Text("文件需是单个 manifest JSON；二维码内容可以是 manifest JSON 本身，也可以是它的下载链接。")
                        .font(.caption2)
                }

                Section("或从 URL 导入") {
                    TextField("https://…/manifest.json", text: $fromWeb)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await downloadAndPreview() }
                    } label: {
                        if downloading {
                            HStack(spacing: 6) { ProgressView().scaleEffect(0.8); Text("下载中…") }
                        } else {
                            Label("下载并校验", systemImage: "arrow.down.circle")
                        }
                    }
                    .disabled(fromWeb.trimmingCharacters(in: .whitespaces).isEmpty || downloading)
                }

                // ── 校验结果 ──
                if let m = preview {
                    Section("校验通过") {
                        LabeledContent("名称", value: m.name)
                        LabeledContent("标识", value: m.id)
                        LabeledContent("版本", value: m.version)
                        LabeledContent("主域", value: m.domain)
                        LabeledContent("API 版本", value: "\(m.apiVersion)")
                        LabeledContent("运行时", value: m.effectiveRuntime.displayName)
                        LabeledContent("能力", value: capabilityText(m))
                        if let hs = m.headers, !hs.isEmpty {
                            LabeledContent("附加请求头", value: "\(hs.count) 项")
                        }
                    }
                    Section {
                        Button("导入并保存") {
                            if JSSourceStore.save(m) {
                                resultMsg = "✅ 已导入「\(m.name)」"
                                // 广播：设置页的数量角标、其它订阅者据此更新。
                                // ⚠️ 本列表**不**通过该通知刷新（避免递归），而是直接调 onDone。
                                NotificationCenter.default.post(name: .hmdJSSourcesChanged, object: nil)
                                onDone()
                            } else {
                                resultMsg = "❌ 保存失败（manifest 无法序列化）"
                            }
                            preview = nil
                            text = ""
                        }
                    }
                } else if let err = previewError {
                    Section {
                        Label("校验未通过", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(err).font(.callout)
                    }
                } else {
                    Section {
                        Button("校验") { validate() }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if let msg = resultMsg { Text(msg).font(.callout) }
                    }
                }
            }
            .transparentScrollBackground()
            .navigationTitle("导入 JS 源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .fileImporter(isPresented: $showFilePicker,
                          allowedContentTypes: [.json, .text, .data]) { result in
                handleFile(result)
            }
            .onChange(of: pickedPhoto) { item in
                guard let item else { return }
                Task { await handlePhoto(item) }
            }
        }
    }

    /// 从文件导入：读文本 → 走同一条校验路径
    private func handleFile(_ result: Result<URL, Error>) {
        preview = nil
        previewError = nil
        resultMsg = nil
        guard case .success(let url) = result else {
            previewError = "文件选择失败"
            return
        }
        // ⚠️ 沙盒外的文件必须先申请安全作用域访问，否则读出来是空/失败
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        guard let t = try? String(contentsOf: url, encoding: .utf8) else {
            previewError = "文件读取失败（可能不是 UTF-8 文本）"
            return
        }
        text = t
        validate()
    }

    /// 从相册二维码导入：二维码内容可能是 manifest JSON 本身，也可能是一个下载链接
    private func handlePhoto(_ item: PhotosPickerItem) async {
        defer { pickedPhoto = nil }
        preview = nil
        previewError = nil
        resultMsg = nil
        guard let data = try? await item.loadTransferable(type: Data.self),
              let img = UIImage(data: data) else {
            previewError = "图片读取失败"
            return
        }
        guard let code = QRDecoder.decode(img) else {
            previewError = "未识别到二维码（换一张更清晰的图试试）"
            return
        }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        // 是链接 → 下载后校验；否则当作 manifest 原文直接校验
        if trimmed.lowercased().hasPrefix("http") {
            resultMsg = "⏳ 已识别链接，正在下载…"
            let fetched = await HttpFetcher.shared.fetchText(trimmed)
            let body = fetched.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty {
                resultMsg = nil
                previewError = "链接下载失败（\(trimmed)）——该站点可能需要网络代理"
                return
            }
            if body.hasPrefix("<") || body.contains("<html") {
                resultMsg = nil
                previewError = "链接返回网页而非 manifest（需要网络代理）：\(trimmed)"
                return
            }
            text = body
        } else {
            text = trimmed
        }
        resultMsg = nil
        validate()
    }

    /// 解析 + 校验（不落库），把错误原文交给用户
    private func validate() {
        resultMsg = nil
        previewError = nil
        preview = nil
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        guard let data = raw.data(using: .utf8) else {
            previewError = "内容不是合法的 UTF-8 文本"
            return
        }
        let decoded: JSSourceManifest
        do {
            decoded = try JSONDecoder().decode(JSSourceManifest.self, from: data)
        } catch {
            // 把 DecodingError 翻成人能看懂的一句话（缺字段/类型不对最常见）
            previewError = Self.describeDecodeError(error)
            return
        }
        do {
            try decoded.validate()
        } catch let e as SourceProviderError {
            // `description` 自带「源定义无效：」前缀 —— 这里是「校验未通过」区块，
            // 前缀重复了，剥掉它（用分隔符切一刀，找不到分隔符就用原文）。
            switch e {
            case .invalidSource(let m): previewError = m
            default: previewError = e.description
            }
            return
        } catch {
            previewError = error.localizedDescription
            return
        }
        preview = decoded
    }

    private func downloadAndPreview() async {
        downloading = true
        defer { downloading = false }
        resultMsg = "⏳ 正在下载…"
        previewError = nil
        preview = nil
        let t = await HttpFetcher.shared.fetchText(fromWeb)
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            resultMsg = nil
            previewError = "下载失败：无法连接（该站点可能需要网络代理）"
            return
        }
        if trimmed.hasPrefix("<") || trimmed.contains("<html") {
            resultMsg = nil
            previewError = "返回的是网页而非 manifest（该站点需要网络代理，或链接已失效）"
            return
        }
        text = trimmed
        resultMsg = nil
        validate()
    }

    private func capabilityText(_ m: JSSourceManifest) -> String {
        var out: [String] = []
        if m.entry.search != nil { out.append("搜索") }
        if m.entry.detail != nil { out.append("详情") }
        if m.entry.chapters != nil { out.append("章节") }
        if m.entry.images != nil { out.append("图片") }
        return out.isEmpty ? "（无）" : out.joined(separator: " · ")
    }

    /// `DecodingError` → 可读定位（哪个字段、期望什么类型）
    private static func describeDecodeError(_ error: Error) -> String {
        guard let de = error as? DecodingError else { return error.localizedDescription }
        switch de {
        case .keyNotFound(let key, _):
            return "缺少必填字段「\(key.stringValue)」"
        case .typeMismatch(let type, let ctx):
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            return "字段「\(path.isEmpty ? "(根)" : path)」类型不对（期望 \(type)）"
        case .valueNotFound(let type, let ctx):
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            return "字段「\(path.isEmpty ? "(根)" : path)」为空（期望 \(type)）"
        case .dataCorrupted(let ctx):
            return "JSON 格式错误：\(ctx.debugDescription)"
        @unknown default:
            return de.localizedDescription
        }
    }
}

extension Notification.Name {
    /// JS 源集合发生变化（导入/删除/启用切换）—— 列表与设置页据此刷新
    static let hmdJSSourcesChanged = Notification.Name("hmdJSSourcesChanged")
}

/// JS 源编辑面板。
///
/// 与导入面板（`JSSourceImportSheet`）的分工：
///   • 导入面板 —— 粘贴/下载**整份** manifest，面向「拿到一个新源」；
///   • 编辑面板 —— 改已有源的**字段**，面向「这个源有小问题，我修一下」。
///
/// ⚠️ `id` **只读**：它是 `JS_SOURCE` 表的主键、也是 `js://<id>` 的来源。
///    允许改 id 等于「删旧建新」，但注册表缓存与用户已加入书架的书仍指向旧 id，
///    会静默变成打不开的孤儿数据。要换 id 就删除后重新导入 —— 这是显式的。
struct JSSourceEditorSheet: View {
    let id: String
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    /// 编辑草稿。加载失败时保持 nil，界面显示错误态。
    @State private var draft: JSSourceManifest? = nil
    @State private var loadError: String? = nil
    @State private var saveError: String? = nil
    /// 请求头编辑用的文本形式（`Key: Value` 每行一条）——比字典输入友好得多
    @State private var headersText = ""

    var body: some View {
        NavigationStack {
            Group {
                if let m = draft {
                    editor(m)
                } else if let e = loadError {
                    Form {
                        Section {
                            Label("无法打开该源", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(e).font(.callout)
                        }
                    }
                    .transparentScrollBackground()
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(draft?.name.isEmpty == false ? draft!.name : "编辑 JS 源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(draft == nil)
                }
            }
            .task { load() }
        }
    }

    @ViewBuilder
    private func editor(_ base: JSSourceManifest) -> some View {
        // 用绑定把 `draft` 解包给各输入控件 —— 拿不到 draft 时根本不进这个分支
        let b = Binding<JSSourceManifest>(
            get: { draft ?? base },
            set: { draft = $0 })
        Form {
            Section {
                LabeledContent("标识", value: id)
                TextField("显示名", text: b.name)
                    .autocorrectionDisabled()
                TextField("版本（如 1.0）", text: b.version)
                    .autocorrectionDisabled()
                TextField("主域（网络白名单基准）", text: b.domain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            } header: {
                Text("基础信息")
            } footer: {
                Text("标识不可修改（它是源的主键）。主域用于网络白名单：脚本只能请求该域及其子域。")
                    .font(.caption2)
            }

            Section {
                LabeledContent("apiVersion", value: "\(base.apiVersion)")
                Text("当前版本支持的区间为 1…1，脚本不匹配时会被拒绝加载。")
                    .font(.caption2).foregroundStyle(.secondary)
            } header: {
                Text("桥接 API 版本")
            }

            Section {
                Picker("执行通道", selection: Binding(
                    get: { (draft?.runtime) ?? .jscore },
                    set: { draft?.runtime = $0 })) {
                    Text("JSCore").tag(JSSourceManifest.Runtime.jscore)
                    Text("WKWebView").tag(JSSourceManifest.Runtime.wkwebview)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("运行时")
            } footer: {
                Text("JSCore：支持网络桥（脚本可抓网页），但**无法终止死循环**。\nWKWebView：**超时可终止**（超时回收进程），但**没有网络桥**。\n按你的脚本是否需要联网来选择。")
                    .font(.caption2)
            }

            Section {
                entryField("搜索函数名", text: b.entry.search)
                entryField("详情函数名", text: b.entry.detail)
                entryField("章节函数名", text: b.entry.chapters)
                entryField("图片函数名", text: b.entry.images)
            } header: {
                Text("入口函数")
            } footer: {
                Text("留空表示不支持该能力。至少要有 search 或 detail 之一，否则校验不通过。")
                    .font(.caption2)
            }

            Section {
                TextEditor(text: b.script)
                    .frame(minHeight: 260)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("脚本源码（JavaScript）")
            } footer: {
                Text("入口函数必须**同步返回**可 JSON 序列化的值（v1 不支持 Promise）。")
                    .font(.caption2)
            }

            Section {
                TextEditor(text: $headersText)
                    .frame(minHeight: 90)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("附加请求头")
            } footer: {
                Text("每行一条，格式 `名字: 值`，例如 `Referer: https://example.com`。\n⚠️ 不要放 Cookie / Token 等凭据，它们会被明文存进数据库。")
                    .font(.caption2)
            }

            if let e = saveError {
                Section {
                    Label("保存失败", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(e).font(.callout)
                }
            }
        }
        .transparentScrollBackground()
    }

    /// 入口函数名输入框：空串 ↔ nil 需要显式转换（`TextField` 只能绑字符串）
    @ViewBuilder
    private func entryField(_ title: String, text: Binding<String?>) -> some View {
        TextField(title, text: Binding(
            get: { text.wrappedValue ?? "" },
            set: { text.wrappedValue = $0.isEmpty ? nil : $0 }))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    private func load() {
        guard let m = JSSourceStore.load(id: id) else {
            loadError = "该源的 manifest 无法解析或已不合法（可能来自更早的版本）。\n可以删除后重新导入。"
            return
        }
        draft = m
        headersText = Self.formatHeaders(m.headers)
    }

    private func save() {
        guard var m = draft else { return }
        saveError = nil
        m.headers = Self.parseHeaders(headersText)
        do {
            try m.validate()
        } catch let e as SourceProviderError {
            if case .invalidSource(let msg) = e { saveError = msg } else { saveError = e.description }
            return
        } catch {
            saveError = error.localizedDescription
            return
        }
        guard JSSourceStore.save(m) else {
            saveError = "写入数据库失败"
            return
        }
        // 注册表重新装载，让改动立即生效（不必重启）
        _ = SourceProviderRegistry.shared.loadFromStore()
        NotificationCenter.default.post(name: .hmdJSSourcesChanged, object: nil)
        onDone()
        dismiss()
    }

    /// 字典 → 文本（排序保证每次打开顺序稳定，避免"看着像变了"）
    private static func formatHeaders(_ h: [String: String]?) -> String {
        guard let h, !h.isEmpty else { return "" }
        return h.keys.sorted().map { "\($0): \(h[$0] ?? "")" }.joined(separator: "\n")
    }

    /// 文本 → 字典。忽略空行与不含 `:` 的行；值里允许再出现 `:`（只按**第一个**切分）。
    private static func parseHeaders(_ text: String) -> [String: String]? {
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            out[key] = value
        }
        return out.isEmpty ? nil : out
    }
}

/// JS 源测试面板 —— 导入后**先验证它能跑**，再决定是否留着。
///
/// 为什么必须有这一步：JS 源是黑盒脚本，导入成功 ≠ 能工作（可能脚本写错、
/// 站点改版、或域名白名单拦掉了请求）。没有测试入口，用户只能去搜索页碰运气，
/// 失败时也分不清是源的问题还是 App 的问题。
///
/// ⚠️ 这是**唯一**会真正执行第三方 JS 的入口之一，且必须显式由用户点击触发。
///    脚本死循环会占住 JS 执行队列（JSCore 无终止 API，见 `JS隔离方案评估.md`），
///    所以这里给出明确警示，不做「导入即自动跑」。
struct JSSourceTestSheet: View {
    let item: JSSourceStore.Item
    @Environment(\.dismiss) private var dismiss
    @State private var keyword = ""
    @State private var running = false
    @State private var log: [String] = []
    @State private var results: [SearchResult] = []
    @State private var caps: ProviderCapabilities = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("名称", value: item.name)
                    LabeledContent("标识", value: item.id)
                    LabeledContent("主域", value: item.domain.isEmpty ? "（未声明）" : item.domain)
                    if !caps.isEmpty {
                        LabeledContent("能力", value: capabilityText)
                    }
                } header: {
                    Text("源信息")
                }

                Section {
                    if caps.contains(.search) {
                        TextField("输入关键词，例如：海贼", text: $keyword)
                            .autocorrectionDisabled()
                        Button {
                            Task { await runSearch() }
                        } label: {
                            if running {
                                HStack(spacing: 6) { ProgressView().scaleEffect(0.8); Text("执行中…") }
                            } else {
                                Label("测试搜索", systemImage: "magnifyingglass")
                            }
                        }
                        .disabled(running || keyword.trimmingCharacters(in: .whitespaces).isEmpty)
                    } else {
                        Label("该源未声明 search 入口，无法测试搜索", systemImage: "nosign")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("测试")
                } footer: {
                    Text("测试会在你的设备上执行该源的 JavaScript。只测试你信任的源 —— 恶意脚本可能占用解析队列。")
                        .font(.caption2)
                }

                if !log.isEmpty {
                    Section("执行日志") {
                        ForEach(log.indices, id: \.self) { i in
                            Text(log[i]).font(.system(.caption, design: .monospaced))
                        }
                    }
                }

                if !results.isEmpty {
                    Section("结果（\(results.count) 条）") {
                        // ⚠️ 用**下标**而不是 `SearchResult.id` 做 ForEach 标识：
                        //    它的 id 是 `origin|noteUrl`，同一个源返回两条同 URL 结果时
                        //    会撞标识、触发 SwiftUI 的 id 冲突告警并导致列表错乱。
                        ForEach(results.indices, id: \.self) { i in
                            let r = results[i]
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name).font(.body)
                                if !r.author.isEmpty {
                                    Text(r.author).font(.caption).foregroundStyle(.secondary)
                                }
                                if !r.noteUrl.isEmpty {
                                    Text(r.noteUrl).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .transparentScrollBackground()
            .navigationTitle("测试 JS 源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .task { loadCaps() }
        }
    }

    private var capabilityText: String {
        var out: [String] = []
        if caps.contains(.search) { out.append("搜索") }
        if caps.contains(.detail) { out.append("详情") }
        if caps.contains(.chapters) { out.append("章节") }
        if caps.contains(.images) { out.append("图片") }
        return out.isEmpty ? "（无）" : out.joined(separator: " · ")
    }

    private func loadCaps() {
        guard let m = JSSourceStore.load(id: item.id) else {
            log.append("❌ 无法读取该源（manifest 已损坏或被禁用）")
            return
        }
        caps = m.declaredCapabilities
    }

    private func runSearch() async {
        guard let m = JSSourceStore.load(id: item.id) else {
            log.append("❌ 无法读取该源")
            return
        }
        running = true
        log.removeAll()
        results = []
        log.append("▶ 开始测试：keyword=\(keyword)")
        let t0 = Date()
        do {
            let provider = try JSProvider(manifest: m)
            let hits = try await provider.search(keyword: keyword, page: 1)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            results = hits
            if hits.isEmpty {
                log.append("⚠️ 执行完成（\(ms)ms），但返回 0 条结果。")
                log.append("  可能原因：脚本逻辑错误 / 站点改版 / 域名白名单拦截了请求。")
            } else {
                log.append("✅ 执行成功（\(ms)ms），返回 \(hits.count) 条。")
            }
        } catch let e as SourceProviderError {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            log.append("❌ \(e.description)（\(ms)ms）")
        } catch {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            log.append("❌ \(error.localizedDescription)（\(ms)ms）")
        }
        running = false
    }
}
