import SwiftUI
import UIKit
import PhotosUI
import CoreImage
import UniformTypeIdentifiers

/// 图源管理 —— 对应 AddComicSourceActivity（导入方式：粘贴/文件/二维码/WebDAV）
///
/// `embedded`：被「漫画台」标签页包在它的 NavigationStack 里时传 true，
/// 此时**不再自带** NavigationStack（否则会出现二层导航栏、标题重复）。
struct SourceListView: View {
    var embedded: Bool = false
    @State private var sources: [ComicSource] = []
    @State private var importText = ""
    @State private var showImport = false
    @State private var showEditor = false
    /// 图源导出成二维码（见 SourceQRExportView）
    @State private var showQRExport = false
    @State private var editingSource: ComicSource?
    @State private var loginSource: ComicSource?
    /// 待删除的图源（等二次确认）—— 见侧滑「删除」处的说明
    @State private var pendingDelete: ComicSource?
    /// JS 类源（与规则类源混排在同一列表里，见 body 里的说明）
    @State private var jsItems: [JSSourceStore.Item] = []
    @State private var jsEditing: JSSourceStore.Item?
    @State private var jsTesting: JSSourceStore.Item?

    /// JS 类源的一行 —— 视觉上与规则源保持一致，右侧用 `{ }` 角标区分。
    @ViewBuilder
    private func jsRow(_ item: JSSourceStore.Item) -> some View {
        Button {
            jsEditing = item
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name.isEmpty ? "(未命名 JS 源)" : item.name)
                    Image(systemName: "curlybraces")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !item.enabled {
                        Text("已停用").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(item.domain)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                JSSourceStore.remove(id: item.id)
                reload()
            } label: { Label("删除", systemImage: "trash") }
            Button {
                JSSourceStore.setEnabled(!item.enabled, id: item.id)
                reload()
            } label: { Label(item.enabled ? "停用" : "启用", systemImage: "power") }
                .tint(.orange)
            Button {
                jsTesting = item
            } label: { Label("测试", systemImage: "checkmark.seal") }
                .tint(.blue)
        }
    }
    @State private var showCheck = false
    @State private var searchText = ""
    @State private var updating = false
    @State private var updateMsg = ""

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
        }
    }

    private var content: some View {
        Group {
            // ⚠️ 空态判据要**同时看 JS 源** —— 只有 JS 源、没有规则源时不能显示「还没有图源」
            if sources.isEmpty && jsItems.isEmpty {
                EmptyState(title: "还没有图源", systemImage: "square.stack.3d.up",
                           description: "点右上角 + 导入（粘贴 / 文件 / 局域网分享）")
            } else {
                    List {
                        // 🔴 **JS 类源与规则类源合并成同一个列表** ——
                        //    用户反馈：「我不喜欢看到 JS 的源单独被列出来，图源应该都在
                        //    那个图源管理里面」。所以这里不再单开一个「JS 类图源」入口，
                        //    而是把 JS 源**作为普通行**混排在主列表里（带 `{ }` 角标区分）。
                        //    点进去直接开 JS 源编辑器，与规则源的编辑体验一致。
                        ForEach(jsItems) { item in
                            jsRow(item)
                        }
                        ForEach(filtered) { s in
                            NavigationLink {
                                SourceEditorView(source: s) { reload() }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(s.bookSourceName.isEmpty ? "(未命名)" : s.bookSourceName)
                                        Spacer()
                                        // 预置健康清单角标：明确区分「站点没了」和「规则问题」
                                        // ⚠️ 健康数据比源规则还旧时**不显示结论** ——
                                        //    否则用户会看到「站点不可达」，但那个结论是基于旧规则的。
                                        if SourceHealth.isStale(for: s) {
                                            Text("健康数据过期").font(.caption2)
                                                .foregroundStyle(.secondary)
                                        } else if let h = SourceHealth.state(sourceUrl: s.bookSourceUrl),
                                                  let b = h.badge {
                                            Text(b).font(.caption2)
                                                .foregroundStyle(h.badgeIsBad ? .red : (h.isGood ? .green : .orange))
                                        }
                                        if !s.isEnabled { Text("已停用").font(.caption2).foregroundStyle(.secondary) }
                                    }
                                    Text(s.bookSourceUrl).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    if let g = s.bookSourceGroup, !g.isEmpty {
                                        Text(g).font(.caption2).foregroundStyle(.tint).lineLimit(1)
                                    }
                                    // 能力徽标：一眼看出这个源支持什么（搜索 / 发现 / 翻页 / JS）。
                                    // 根治「点了没反应」—— 不支持的功能在列表里就能看出来，
                                    // 而不是让用户点进去才发现。
                                    if !s.caps.badges.isEmpty {
                                        Text(s.caps.badges.joined(separator: " · "))
                                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                            .contextMenu {
                                Button { loginSource = s } label: { Label("网页登录(捕获Cookie)", systemImage: "person.badge.key") }
                            }
                            .swipeActions {
                                Button {
                                    ComicRepository.shared.setEnable(url: s.bookSourceUrl, enable: !s.isEnabled)
                                    reload()
                                } label: { Label(s.isEnabled ? "停用" : "启用", systemImage: "power") }
                                    .tint(.orange)
                                Button(role: .destructive) {
                                    // 🔴 删图源加二次确认 —— 删掉后该源下的书架/进度/下载
                                    //    都会变成孤儿（不可恢复）。原来侧滑一下就直接删。
                                    //    （由智能体「设置」发现）
                                    pendingDelete = s
                                } label: { Label("删除", systemImage: "trash") }
                            }
                        }
                    }
                    .transparentScrollBackground()
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("图源")
            .searchable(text: $searchText, prompt: "搜索图源")
            // JS 源编辑 / 测试（与规则源同在一个列表里，见 body 里的说明）
            .sheet(item: $jsEditing) { item in
                JSSourceEditorSheet(id: item.id) { reload() }
            }
            .sheet(item: $jsTesting) { item in
                JSSourceTestSheet(item: item)
            }
            .confirmationDialog("确定删除图源「\(pendingDelete?.bookSourceName ?? "")」？",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let s = pendingDelete {
                        ComicRepository.shared.deleteSources(urls: [s.bookSourceUrl])
                        reload()
                    }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("该源下的书架条目、阅读进度与已下载章节会变成孤儿数据，且不可恢复。")
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showImport = true } label: { Label("导入图源", systemImage: "square.and.arrow.down") }
                        Button { showEditor = true } label: { Label("新建图源", systemImage: "plus.square") }
                        Button { exportAll() } label: { Label("导出全部", systemImage: "square.and.arrow.up") }
                        Button { showQRExport = true } label: { Label("导出为二维码…", systemImage: "qrcode") }
                        Button { exportEncrypted() } label: { Label("一键加密导出(S001)", systemImage: "lock") }
                        Divider()
                        Button { ComicRepository.shared.setAllSourcesEnabled(true); reload() } label: { Label("全部启用", systemImage: "checkmark.circle") }
                        Button { ComicRepository.shared.setAllSourcesEnabled(false); reload() } label: { Label("全部停用", systemImage: "pause.circle") }
                        Divider()
                        Button { showCheck = true } label: { Label("图源检验(批量)", systemImage: "checkmark.seal") }
                        Button { Task { await runUpdate() } } label: {
                            Label(updating ? "正在更新… \(updateMsg)" : "从源仓库在线更新", systemImage: "arrow.down.circle")
                        }
                        .disabled(updating)
                        Button { disableKnownBad() } label: {
                            Label("停用已知不可用源(\(SourceHealth.badSources(sources).count))", systemImage: "exclamationmark.triangle")
                        }
                        Button { Task { await webShare() } } label: { Label("局域网分享(Web服务)", systemImage: "wifi") }
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showImport) { ImportSheet(onDone: reload) }
            .sheet(isPresented: $showQRExport) { SourceQRExportView() }
            .sheet(isPresented: $showCheck) { NavigationStack { SourceCheckView() } }
            .sheet(item: $loginSource) { src in
                NavigationStack { SourceLoginView(source: src) }
            }
            .sheet(isPresented: $showEditor) {
                NavigationStack { SourceEditorView(source: nil) { reload() } }
            }
            .onAppear { reload() }
            // 后台导入/修复图源时，边解边刷新（首次启动要几十秒）
            .onReceive(NotificationCenter.default.publisher(for: .hmdSourcesChanged)) { _ in reload() }
    }

    private var filtered: [ComicSource] {
        searchText.isEmpty ? sources : sources.filter { $0.bookSourceName.contains(searchText) || $0.bookSourceUrl.contains(searchText) }
    }

    private func reload() {
        sources = ComicRepository.shared.allSources()
        // JS 类源与规则类源同列表展示，一起刷新
        jsItems = JSSourceStore.list()
    }

    /// 停用「预置健康清单」里已知不可用的源。
    /// 清单来自桌面端全链路体检（域名不可达 / 列表 0 / 章节 0 / 被反爬）。
    /// ⚠️ 只作提示，不自动执行 —— 桌面网络与手机不同，用户自己决定。
    /// ⚠️ 跳过「健康数据比规则还旧」的源：那个结论是基于**旧规则**得出的，
    ///    拿它禁用源等于用过期信息替用户做决定。
    private func disableKnownBad() {
        var n = 0
        for s in SourceHealth.badSources(sources) where s.isEnabled {
            ComicRepository.shared.setEnable(url: s.bookSourceUrl, enable: false)
            n += 1
        }
        let stale = SourceHealth.staleCount(sources)
        updateMsg = n > 0
            ? "已停用 \(n) 个已知不可用源" + (stale > 0 ? "（另有 \(stale) 个源健康数据已过期，已跳过）" : "")
            : (stale > 0 ? "没有可直接停用的源（\(stale) 个源的健康数据已过期，建议重跑体检）" : "没有需要停用的源")
        reload()
    }

    /// 从源仓库（yck2026.fun）在线拉取最新图源规则并合并。
    /// 已存在的源只更新规则、**保留用户自己的启用/禁用状态**。
    private func runUpdate() async {
        updating = true
        updateMsg = "获取索引…"
        let rep = await SourceUpdater.updateAll { r in
            DispatchQueue.main.async {
                updateMsg = "\(r.total) 条 · 失败 \(r.failed)"
            }
        }
        updateMsg = rep.text
        updating = false
        reload()
    }

    private func exportAll() {
        let text = SourceCodec.exportJson(sources)
        let av = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        UIApplication.shared.topViewController()?.present(av, animated: true)
    }

    /// 一键加密导出（对应 OnkeyEncryptActivity：加密章节/正文规则为 S001 格式）
    private func exportEncrypted() {
        var list = sources
        guard let rawKey = SourceDecrypt.versionKeys["S001"] else { return }
        let key = SourceDecrypt.pad32(rawKey)
        for i in list.indices {
            if let v = list[i].ruleChapterList, !v.isEmpty, !v.hasPrefix(":_"),
               let enc = SourceDecrypt.aesEncrypt(v, key: key) { list[i].ruleChapterList = ":_S001_\(enc)" }
            if let v = list[i].ruleBookContent, !v.isEmpty, !v.hasPrefix(":_"),
               let enc = SourceDecrypt.aesEncrypt(v, key: key) { list[i].ruleBookContent = ":_S001_\(enc)" }
        }
        let text = SourceCodec.exportJson(list)
        let av = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        UIApplication.shared.topViewController()?.present(av, animated: true)
    }

    private func webShare() {
        let port = UInt16(AppSettings.shared.webPort)
        WebServer.shared.start(port: port)
        let ip = LocalIP.primary() ?? "127.0.0.1"
        // 带上访问令牌：所有 API 端点都要求鉴权（见 `WebServer.token`）
        let url = "http://\(ip):\(port)/?t=\(WebServer.token)"
        let av = UIAlertController(title: "Web 服务已启动",
                                   message: "浏览器访问 \(url)\n图源编辑器/Web书架，协议与安卓版一致\n\n"
                                          + "⚠️ ?t=… 是访问令牌，别分享给他人。",
                                   preferredStyle: .alert)
        av.addAction(UIAlertAction(title: "停止服务", style: .destructive) { _ in WebServer.shared.stop() })
        av.addAction(UIAlertAction(title: "好", style: .cancel))
        UIApplication.shared.topViewController()?.present(av, animated: true)
    }
}

/// 导入面板（对应 AddComicSourceActivity 三种方式）
struct ImportSheet: View {
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var fromWeb = ""
    @State private var showFilePicker = false
    @State private var pickedPhoto: PhotosPickerItem? = nil
    @State private var showScanner = false
    @State private var resultMsg: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("粘贴图源 JSON（支持 Legado 漫画源/原版加密源）") {
                    TextEditor(text: $text).frame(minHeight: 160).font(.caption)
                }
                Section("文件 / 二维码") {
                    Button {
                        showFilePicker = true
                    } label: { Label("从文件导入（JSON/TXT）", systemImage: "doc") }
                    PhotosPicker(selection: $pickedPhoto, matching: .images) {
                        Label("从相册二维码导入", systemImage: "qrcode.viewfinder")
                    }
                    Button {
                        showScanner = true
                    } label: {
                        Label("相机扫码导入", systemImage: "camera.viewfinder")
                    }
                }
                Section("或从 URL 导入") {
                    TextField("https://…/source.json", text: $fromWeb)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    Button("下载并导入") {
                        Task {
                            resultMsg = "⏳ 正在下载…"
                            let t = await HttpFetcher.shared.fetchText(fromWeb)
                            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed.isEmpty {
                                resultMsg = "❌ 下载失败：无法连接（该站点可能需要网络代理）"
                            } else if trimmed.hasPrefix("<") || trimmed.contains("<html") {
                                resultMsg = "❌ 返回的是网页而非图源数据（该站点需要网络代理，或链接已失效）"
                            } else {
                                let n = importText(t)
                                resultMsg = n > 0 ? "✅ 从链接导入 \(n) 条图源" : "❌ 下载到 \(trimmed.count) 字符但未识别出图源（格式不支持）"
                                if n > 0 { onDone() }
                            }
                        }
                    }
                }
                Section {
                    Button("导入并保存") {
                        let n = importText(text)
                        resultMsg = n > 0 ? "✅ 成功导入 \(n) 条图源，可关闭本页" : "❌ 未识别到有效图源：请检查 JSON 格式（应为图源数组或单个对象）"
                        if n > 0 { onDone() }
                    }
                    .disabled(text.isEmpty)
                    if let msg = resultMsg {
                        Text(msg).font(.callout)
                    }
                }
            }
            .transparentScrollBackground()
            .navigationTitle("导入图源")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .sheet(isPresented: $showScanner) {
                NavigationStack { QRScannerView() }
            }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.json, .text, .data]) { result in
                if case .success(let url) = result {
                    let secured = url.startAccessingSecurityScopedResource()
                    if let t = try? String(contentsOf: url, encoding: .utf8) {
                        let n = importText(t)
                        resultMsg = n > 0 ? "✅ 从文件导入 \(n) 条图源" : "❌ 文件内容不是有效图源 JSON"
                        if n > 0 { onDone() }
                    } else {
                        resultMsg = "❌ 文件读取失败"
                    }
                    if secured { url.stopAccessingSecurityScopedResource() }
                }
            }
            .onChange(of: pickedPhoto) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let img = UIImage(data: data), let code = QRDecoder.decode(img) {
                        // 分片码要按顺序收齐，相册一次只能选一张 → 引导用相机扫
                        if SourceQRCodec.decode(code) != nil {
                            resultMsg = "这是多张一组的图源二维码，请用「相机扫码导入」按顺序扫完"
                            pickedPhoto = nil
                            return
                        }
                        resultMsg = "⏳ 已识别二维码，正在下载…"
                        let fetched = await HttpFetcher.shared.fetchText(code)
                        let trimmed = fetched.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            resultMsg = "❌ 链接下载失败（\(code)）——该站点可能需要网络代理"
                        } else if trimmed.hasPrefix("<") || trimmed.contains("<html") {
                            resultMsg = "❌ 链接返回网页而非图源（需要网络代理）：\(code)"
                        } else {
                            let n = importText(fetched)
                            resultMsg = n > 0 ? "✅ 二维码导入 \(n) 条图源" : "❌ 下载到 \(trimmed.count) 字符但不是有效图源"
                            if n > 0 { onDone() }
                        }
                    } else {
                        resultMsg = "❌ 二维码识别失败或内容无效"
                    }
                    pickedPhoto = nil
                }
            }
        }
    }

    private func importText(_ t: String) -> Int {
        let list = SourceCodec.importJson(t)
        ComicRepository.shared.saveSources(list)
        return list.count
    }
}

/// 图源编辑器（对应 web 编辑器 v3.8 的原生版：全部规则字段）
struct SourceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var source: ComicSource
    var onDone: () -> Void

    init(source: ComicSource?, onDone: @escaping () -> Void) {
        _source = State(initialValue: source ?? ComicSource())
        self.onDone = onDone
    }

    var body: some View {
        Form {
            Section("基础信息") {
                Field("图源名称", text: $source.bookSourceName)
                Field("图源域名(主键)", text: $source.bookSourceUrl)
                Field("分组", text: optional($source.bookSourceGroup))
                Field("备注", text: optional($source.sourceRemark))
                Toggle("启用", isOn: Binding(get: { source.isEnabled }, set: { source.enable = $0 }))
            }
            Section("搜索") {
                Field("搜索地址 {{key}} {{page}}", text: optional($source.ruleSearchUrl))
                Field("列表规则", text: optional($source.ruleSearchList))
                Field("书名", text: optional($source.ruleSearchName))
                Field("作者", text: optional($source.ruleSearchAuthor))
                Field("分类", text: optional($source.ruleSearchKind))
                Field("最新章节", text: optional($source.ruleSearchLastChapter))
                Field("封面", text: optional($source.ruleSearchCoverUrl))
                Field("详情页链接", text: optional($source.ruleSearchNoteUrl))
            }
            Section("发现") {
                Field("发现栏目 名::url && 分隔", text: optional($source.ruleFindUrl))
            }
            Section("详情") {
                Field("书名", text: optional($source.ruleBookName))
                Field("作者", text: optional($source.ruleBookAuthor))
                Field("分类", text: optional($source.ruleBookKind))
                Field("简介", text: optional($source.ruleIntroduce))
                Field("封面", text: optional($source.ruleCoverUrl))
                Field("最新章节", text: optional($source.ruleBookLastChapter))
            }
            Section("章节") {
                Field("章节列表", text: optional($source.ruleChapterList))
                Field("章节名", text: optional($source.ruleChapterName))
                Field("章节链接", text: optional($source.ruleChapterUrl))
                Field("下一页(章节列表)", text: optional($source.ruleChapterUrlNext))
                Field("分卷名", text: optional($source.ruleChapterParentName))
            }
            Section("正文") {
                Field("图片规则", text: optional($source.ruleBookContent))
                Field("图片下一页", text: optional($source.ruleContentUrlNext))
                Field("图片解码器(JS)", text: optional($source.ruleBookContentDecoder))
            }
            Section("网络") {
                Field("User-Agent", text: optional($source.httpUserAgent))
                Field("登录URL", text: optional($source.loginUrl))
            }
        }
        .transparentScrollBackground()
        .navigationTitle(source.bookSourceName.isEmpty ? "新建图源" : source.bookSourceName)
        .toolbar {
            // 🔎 规则调试器入口 —— 自建源时「写完不知道对不对」是最大的门槛。
            //    这里带上本源的域名预填，进去直接粘规则就能测。
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    RuleDebugView(presetBaseURL: source.bookSourceUrl)
                } label: {
                    Image(systemName: "ladybug")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    source.lastUpdateTime = Int64(Date().timeIntervalSince1970 * 1000)
                    ComicRepository.shared.saveSource(source)
                    onDone()
                    dismiss()
                }
            }
        }
    }

    struct Field: View {
        let label: String
        @Binding var text: String
        init(_ label: String, text: Binding<String>) {
            self.label = label
            self._text = text
        }
        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                TextField("", text: $text).font(.callout).autocorrectionDisabled()
            }
        }
    }
}

func optional(_ binding: Binding<String?>) -> Binding<String> {
    Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
}

/// 相册图片二维码识别（对应 QRCodeScanActivity 的相册路径）
enum QRDecoder {
    static func decode(_ image: UIImage) -> String? {
        guard let cg = image.cgImage,
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return nil }
        for f in detector.features(in: CIImage(cgImage: cg)) {
            if let qr = f as? CIQRCodeFeature, let msg = qr.messageString { return msg }
        }
        return nil
    }
}
