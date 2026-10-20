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
    // ── 多选模式（开源阅读那套）─────────────────────────────────
    // 长按任意一行 / 菜单「多选…」进入；底部出现 全选 / 反选 / 删除 / 二维码。
    @State private var selected = Set<String>()     // "s:图源URL" 或 "j:JS源ID"
    /// 点底部「二维码」时，把勾中的规则源交给导出页
    @State private var exportList: [ComicSource] = []

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
    /// 轻提示（多选相关操作反馈）
    @State private var toast: String? = nil
    /// 排序方式（对齐 Legado 的「排序」菜单：手动/名称/链接/启用状态）
    @State private var sortMode: SourceSort = .manual
    /// 分组筛选：nil = 全部，"\u{0}未分组" = 未分组
    @State private var groupFilter: String? = nil
    @State private var showGroupManage = false
    /// 按域名分组显示
    @State private var groupByHost = false
    /// 手动排序时进入编辑模式（出拖动把手）
    @State private var editMode: EditMode = .inactive
    /// 分享面板的内容（图源 JSON 文本）
    @State private var shareItems: [Any]? = nil

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
                        listContent
                    }
                    // 选中后的底部操作条：挂在 List 外层（原来嵌在 List 里，
                    // 和 if/else 叠在一起把类型检查器压垮了 —— 报
                    // "unable to type-check this expression in reasonable time"）
                    .safeAreaInset(edge: .bottom) {
                        if hasSelection { selectBar }
                    }
                    .environment(\.editMode, $editMode)
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
            .alert("加入分组", isPresented: $showGroupAdd) {
                TextField("分组名，多个用逗号分隔", text: $groupInput)
                Button("加入") { addToGroup(groupInput) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("给选中的 \(selected.count) 个图源加上这些分组（已有分组会保留）")
            }
            .alert("移出分组", isPresented: $showGroupRemove) {
                TextField("要移除的分组名", text: $groupInput)
                Button("移出", role: .destructive) { removeFromGroup(groupInput) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("从选中的 \(selected.count) 个图源里移除这些分组")
            }
            // 多选删除：一次删多个，同样要二次确认
            .confirmationDialog("删除选中的 \(selected.count) 个图源？",
                                isPresented: Binding(get: { pendingMultiDelete },
                                                     set: { if !$0 { pendingMultiDelete = false } }),
                                titleVisibility: .visible) {
                Button("删除", role: .destructive) { deleteSelected() }
                Button("取消", role: .cancel) { pendingMultiDelete = false }
            } message: {
                Text("这些源下的书架条目、阅读进度与已下载章节会变成孤儿数据，且不可恢复。")
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    toolbarMenu
                }
            }
            .sheet(isPresented: $showImport) { ImportSheet(onDone: reload) }
            .sheet(isPresented: $showQRExport) { SourceQRExportView(sources: exportList) }
            .sheet(isPresented: $showGroupManage) {
                SourceGroupManageView { reload() }
            }
            .sheet(isPresented: Binding(get: { shareItems != nil },
                                        set: { if !$0 { shareItems = nil } })) {
                ShareSheet(items: shareItems ?? [])
            }
            .sheet(isPresented: $showCheck) { NavigationStack { SourceCheckView() } }
            .sheet(item: $loginSource) { src in
                NavigationStack { SourceLoginView(source: src) }
            }
            .sheet(isPresented: $showEditor) {
                NavigationStack { SourceEditorView(source: nil) { reload() } }
            }
            .sheet(item: $editingSource) { src in
                NavigationStack { SourceEditorView(source: src) { reload() } }
            }
            .onAppear { reload() }
            // 后台导入/修复图源时，边解边刷新（首次启动要几十秒）
            .onReceive(NotificationCenter.default.publisher(for: .hmdSourcesChanged)) { _ in reload() }
            .overlay(alignment: .top) {
                if let toast {
                    Text(toast)
                        .font(.callout)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                        .onAppear {
                            let keep = toast
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                                if self.toast == keep { self.toast = nil }
                            }
                        }
                }
            }
    }

    // MARK: - 多选（对齐 Legado 书源页）

    private func keyOf(_ s: ComicSource) -> String { "s:" + s.bookSourceUrl }
    private func keyOf(_ j: JSSourceStore.Item) -> String { "j:" + j.id }

    /// 参与「全选/反选」的总数（规则源 + JS 源，与列表一致）
    private var selectableCount: Int { filtered.count + jsItems.count }
    private var hasSelection: Bool { !selected.isEmpty }
    private var selectAllChecked: Bool { !selected.isEmpty && selected.count >= selectableCount }

    private func toggleSelect(_ key: String) {
        if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
    }

    private func selectAll() {
        selected.removeAll()
        filtered.forEach { selected.insert(keyOf($0)) }
        jsItems.forEach { selected.insert(keyOf($0)) }
    }

    private func invertSelection() {
        var next = Set<String>()
        filtered.forEach { if !selected.contains(keyOf($0)) { next.insert(keyOf($0)) } }
        jsItems.forEach { if !selected.contains(keyOf($0)) { next.insert(keyOf($0)) } }
        selected = next
    }

    /// 当前勾中的规则源（顺序跟随列表）
    private var selectedSources: [ComicSource] {
        filtered.filter { selected.contains(keyOf($0)) }
    }
    private var selectedURLs: [String] { selectedSources.map(\.bookSourceUrl) }
    private var selectedJSIDs: [String] {
        jsItems.filter { selected.contains(keyOf($0)) }.map(\.id)
    }

    private func enableSelection(_ on: Bool) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        ComicRepository.shared.setEnable(urls: urls, enable: on)
        toast = on ? "已启用 \(urls.count) 个图源" : "已停用 \(urls.count) 个图源"
        reload()
    }

    private func toggleExplore(_ s: ComicSource) {
        ComicRepository.shared.setExploreEnabled(urls: [s.bookSourceUrl], enable: !s.isExploreEnabled)
        reload()
    }

    private func setExplore(_ on: Bool, urls: [String]) {
        guard !urls.isEmpty else { return }
        ComicRepository.shared.setExploreEnabled(urls: urls, enable: on)
        toast = on ? "已启用 \(urls.count) 个源的发现" : "已禁用 \(urls.count) 个源的发现"
        reload()
    }

    private func moveToTop(_ urls: [String]) {
        guard !urls.isEmpty else { return }
        ComicRepository.shared.moveSources(urls: urls, toTop: true)
        toast = "已置顶 \(urls.count) 个"
        reload()
    }

    private func moveToBottom(_ urls: [String]) {
        guard !urls.isEmpty else { return }
        ComicRepository.shared.moveSources(urls: urls, toTop: false)
        toast = "已置底 \(urls.count) 个"
        reload()
    }

    /// 分享选中：写成临时 JSON 文件交给系统分享面板
    private func shareSelected() {
        shareJSONFile(selectedSources, name: "绘漫岛图源")
    }

    /// 导出为 **JSON 文件**（系统分享面板 → 可存到「文件」/ 微信 / AirDrop / 邮件）。
    ///
    /// ⚠️ 必须传**文件 URL**而不是 JSON 字符串：传字符串时系统常把它当纯文本，
    ///    对方收到的是 .txt 或被截断，导入端识别不出「这是图源 JSON」。
    private func shareJSONFile(_ list: [ComicSource], name: String) {
        guard !list.isEmpty else {
            toast = "没有可导出的图源"
            return
        }
        let json = SourceCodec.exportJson(list, pretty: true)
        let safeName = name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName)_\(list.count)个.json")
        do {
            try json.data(using: .utf8)?.write(to: url)
            shareItems = [url]
            DiagLog.event("sources", "export",
                          "JSON 文件 \(url.lastPathComponent)（\(json.count) 字符 / \(list.count) 源）")
        } catch {
            toast = "生成 JSON 文件失败"
        }
    }

    private func exportSelected() {
        let picked = selectedSources
        guard !picked.isEmpty else {
            toast = "先勾选要导出的图源"
            return
        }
        exportList = picked
        selected.removeAll()
        showQRExport = true
    }

    // 加入 / 移出分组
    @State private var groupInput = ""
    @State private var showGroupAdd = false
    @State private var showGroupRemove = false

    private func addToGroup(_ raw: String) {
        let names = raw.split(whereSeparator: { ",;，；".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return }
        for s in selectedSources {
            ComicRepository.shared.setSourceGroups(url: s.bookSourceUrl,
                                                  groups: s.groupList + names)
        }
        toast = "已加入分组：\(names.joined(separator: "、"))"
        reload()
    }

    private func removeFromGroup(_ raw: String) {
        let names = Set(raw.split(whereSeparator: { ",;，；".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        guard !names.isEmpty else { return }
        for s in selectedSources {
            ComicRepository.shared.setSourceGroups(url: s.bookSourceUrl,
                                                  groups: s.groupList.filter { !names.contains($0) })
        }
        toast = "已移出分组"
        reload()
    }

    @State private var pendingMultiDelete = false

    private func deleteSelected() {
        let urls = selectedURLs
        let jsIDs = selectedJSIDs
        guard !urls.isEmpty || !jsIDs.isEmpty else { return }
        if !urls.isEmpty { ComicRepository.shared.deleteSources(urls: urls) }
        for id in jsIDs { JSSourceStore.remove(id: id) }
        DiagLog.event("sources", "multidelete", "删除 \(urls.count) 个规则源 + \(jsIDs.count) 个 JS 源")
        selected.removeAll()
        reload()
    }

    /// 选中后的操作条（Legado 的 selectActionBar）：主操作删除，其余进 ⋮
    private var selectBar: some View {
        HStack(spacing: 10) {
            barButton("全选（\(selected.count)/\(selectableCount)）",
                      systemImage: selectAllChecked ? "checkmark.square.fill" : "square",
                      action: selectAll)
            barButton("反选", systemImage: "arrow.triangle.2.circlepath", action: invertSelection)
            Spacer(minLength: 6)
            barButton("删除", systemImage: "trash", destructive: true) { pendingMultiDelete = true }
            selectMenu
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    /// 底部条的描边按钮（Legado 那种细线圆角框）
    private func barButton(_ title: String, systemImage: String,
                           destructive: Bool = false, tint: Color? = nil,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.caption)
                Text(title).font(.callout)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .foregroundStyle(destructive ? Color.red : (tint ?? Color.primary))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke((destructive ? Color.red.opacity(0.45) : Color.primary.opacity(0.22)), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }


    /// 选择条的 ⋮ 菜单（拆出来避免和 HStack 一起超时）
    private var selectMenu: some View {
        Menu {
            Button { exportSelected() } label: { Label("导出选中为二维码", systemImage: "qrcode") }
            Divider()
            Button { enableSelection(true) } label: { Label("启用选中", systemImage: "power") }
            Button { enableSelection(false) } label: { Label("停用选中", systemImage: "pause") }
            Button { shareSelected() } label: { Label("导出选中为 JSON 文件", systemImage: "doc.badge.arrow.up") }
            Divider()
            Button { groupInput = ""; showGroupAdd = true } label: { Label("加入分组…", systemImage: "folder.badge.plus") }
            Button { groupInput = ""; showGroupRemove = true } label: { Label("移出分组…", systemImage: "folder.badge.minus") }
            Button { showGroupManage = true } label: { Label("分组管理…", systemImage: "folder.badge.gearshape") }
            Divider()
            Button { setExplore(true, urls: selectedURLs) } label: { Label("启用发现", systemImage: "square.grid.2x2") }
            Button { setExplore(false, urls: selectedURLs) } label: { Label("禁用发现", systemImage: "square.grid.2x2.fill") }
            Divider()
            Button { moveToTop(selectedURLs) } label: { Label("置顶", systemImage: "arrow.up.to.line") }
            Button { moveToBottom(selectedURLs) } label: { Label("置底", systemImage: "arrow.down.to.line") }
            Divider()
            Button { showCheck = true } label: { Label("图源检验", systemImage: "checkmark.seal") }
            Button { selected.removeAll() } label: { Label("取消选择", systemImage: "xmark.circle") }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .padding(.horizontal, 4)
        }
    }

    /// 开源阅读的一行：`[☑ 名称（分组）] [红开关] [✏️] [⋮]`
    ///
    /// 🔴 **关键差异（对照 Legado 源码 `BookSourceAdapter` + `item_book_source.xml`）**：
    ///    `cbBookSource.text = item.getDisPlayNameGroup()` —— 勾选框**就是名字本身**，
    ///    点名字 = 勾选/取消勾选，**不是**打开编辑器。编辑走 ✏️ 或 ⋮。
    ///    我们之前做成「独立勾选框 + 点名字进编辑器」，手感完全不同。
    @ViewBuilder
    private func sourceRow(_ s: ComicSource) -> some View {
        let key = keyOf(s)
        let isSel = selected.contains(key)
        HStack(spacing: 6) {
            // 名称 + 勾选框合并成一个控件
            Button { toggleSelect(key) } label: {
                HStack(spacing: 8) {
                    Image(systemName: isSel ? "checkmark.square.fill" : "square")
                        .font(.system(size: 19))
                        .foregroundStyle(isSel ? Color.accentColor : Color.secondary)
                    sourceInfo(s)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 红开关（缩到 0.78，给名字腾地方）
            Toggle("", isOn: Binding(get: { s.isEnabled },
                                     set: { v in
                                         ComicRepository.shared.setEnable(url: s.bookSourceUrl, enable: v)
                                         reload()
                                     }))
                .labelsHidden()
                .fixedSize()
                .tint(.red)
                .scaleEffect(0.78)
                .frame(width: 40)
            // ⋮（编辑、置顶、发现开关都在里面）
            Menu {
                Button { editingSource = s } label: { Label("编辑", systemImage: "square.and.pencil") }
                Button { loginSource = s } label: { Label("网页登录(捕获Cookie)", systemImage: "person.badge.key") }
                Button { toggleSelect(key) } label: {
                    Label(isSel ? "取消选择" : "选择", systemImage: "checkmark.circle")
                }
                if !(s.ruleFindUrl ?? "").isEmpty {
                    Button { toggleExplore(s) } label: {
                        Label(s.isExploreEnabled ? "禁用发现" : "启用发现", systemImage: "square.grid.2x2")
                    }
                }
                Divider()
                Button { moveToTop([s.bookSourceUrl]) } label: { Label("置顶", systemImage: "arrow.up.to.line") }
                Button { moveToBottom([s.bookSourceUrl]) } label: { Label("置底", systemImage: "arrow.down.to.line") }
                Divider()
                Button(role: .destructive) { pendingDelete = s } label: { Label("删除", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    /// 行的两行文字（拆出来单独类型检查，避免整行表达式过大）
    @ViewBuilder
    private func sourceInfo(_ s: ComicSource) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(displayName(s)).lineLimit(1)
                if !s.isEnabled {
                    Text("已停用").font(.caption2).foregroundStyle(.secondary)
                }
                healthBadge(s)
            }
            HStack(spacing: 4) {
                // 「发现」状态：绿=启用、红=禁用（原来是一个独立按钮，太占地方）
                if !(s.ruleFindUrl ?? "").isEmpty {
                    Circle()
                        .fill(s.isExploreEnabled ? Color.green : Color.red)
                        .frame(width: 5, height: 5)
                }
                Text(subtitle(s))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func healthBadge(_ s: ComicSource) -> some View {
        if SourceHealth.isStale(for: s) {
            Text("健康数据过期").font(.caption2).foregroundStyle(.secondary)
        } else if let h = SourceHealth.state(sourceUrl: s.bookSourceUrl), let b = h.badge {
            Text(b).font(.caption2)
                .foregroundStyle(h.badgeIsBad ? .red : (h.isGood ? .green : .orange))
        }
    }

    /// 副标题：域名 + 能力徽标
    private func subtitle(_ s: ComicSource) -> String {
        let host = hostOf(s.bookSourceUrl)
        return s.caps.badges.isEmpty ? host : host + " · " + s.caps.badges.joined(separator: " ")
    }

    /// 显示名 = 名称（分组），对齐 Legado 的 `getDisPlayNameGroup()`
    private func displayName(_ s: ComicSource) -> String {
        let name = s.bookSourceName.isEmpty ? "(未命名)" : s.bookSourceName
        let groups = s.groupList.joined(separator: "，")
        return groups.isEmpty ? name : "\(name)（\(groups)）"
    }

    /// 取域名（列表里显示域名比完整 URL 干净，和 Legado 一致）
    private func hostOf(_ url: String) -> String {
        URLComponents(string: url)?.host ?? url
    }

    /// 「未分组」用的哨兵 key（真实分组名不可能等于它）
    static let ungroupedKey = "\u{0}__ungrouped__"

    /// 按域名聚合（保持当前排序后的相对顺序）
    private var hostGroups: [(host: String, items: [ComicSource])] {
        var order: [String] = []
        var map: [String: [ComicSource]] = [:]
        for s in filtered {
            let h = hostOf(s.bookSourceUrl)
            if map[h] == nil { order.append(h) }
            map[h, default: []].append(s)
        }
        return order.map { (host: $0, items: map[$0] ?? []) }
    }

    /// 拖动排序落库：按新顺序重写 WEIGHT（列表是 WEIGHT DESC，所以越大越靠前）
    private func moveRows(from: IndexSet, to: Int) {
        var arr = filtered
        arr.move(fromOffsets: from, toOffset: to)
        let total = arr.count
        for (idx, s) in arr.enumerated() {
            // 越靠前 WEIGHT 越大
            ComicRepository.shared.setSourceWeight(url: s.bookSourceUrl, weight: total - idx)
        }
        reload()
    }

    /// 所有源里出现过的分组名（去重、按名称排序）
    private var allGroups: [String] {
        var set = Set<String>()
        sources.forEach { $0.groupList.forEach { set.insert($0) } }
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }


    /// 右上角「+」菜单（12 项，抽成独立属性 —— 和 List 放在同一表达式里会超时）
    private var toolbarMenu: some View {
        Menu {
                        Button { showImport = true } label: { Label("导入图源", systemImage: "square.and.arrow.down") }
                        Menu {
                            Button { groupFilter = nil } label: {
                                Label("全部分组", systemImage: groupFilter == nil ? "checkmark" : "folder")
                            }
                            ForEach(allGroups, id: \.self) { g in
                                Button { groupFilter = g } label: {
                                    Label(g, systemImage: groupFilter == g ? "checkmark" : "folder")
                                }
                            }
                            Button { groupFilter = Self.ungroupedKey } label: {
                                Label("未分组", systemImage: groupFilter == Self.ungroupedKey ? "checkmark" : "tray")
                            }
                        } label: { Label("分组筛选", systemImage: "line.3.horizontal.decrease.circle") }
                        Button { showGroupManage = true } label: { Label("分组管理", systemImage: "folder.badge.gearshape") }
                        Toggle(isOn: $groupByHost) {
                            Label("按域名分组显示", systemImage: "rectangle.3.group")
                        }
                        Button {
                            sortMode = .manual
                            withAnimation { editMode = (editMode == .active ? .inactive : .active) }
                        } label: {
                            Label(editMode == .active ? "完成排序" : "手动排序（拖动）",
                                  systemImage: "arrow.up.arrow.down.square")
                        }
                        Menu {
                            Picker("排序", selection: $sortMode) {
                                ForEach(SourceSort.allCases, id: \.self) { m in
                                    Text(m.title).tag(m)
                                }
                            }
                        } label: { Label("排序", systemImage: "arrow.up.arrow.down") }
                        Button { showEditor = true } label: { Label("新建图源", systemImage: "plus.square") }
                        Button { exportAll() } label: { Label("导出全部为 JSON 文件", systemImage: "doc.badge.arrow.up") }
                        Button {
                            toast = "先勾选图源，再点底部 ⋯ →「导出选中为二维码」"
                        } label: { Label("导出为二维码…", systemImage: "qrcode") }
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
        } label: {
            Image(systemName: "plus")
        }
    }

    /// 列表内容：按域名分组 / 平铺（拆成独立子视图，避免类型检查超时）
    @ViewBuilder
    private var listContent: some View {
        if groupByHost {
            groupedRows
        } else {
            flatRows
        }
    }

    /// 平铺：JS 源混排在前面 + 规则源（支持拖动排序）
    @ViewBuilder
    private var flatRows: some View {
        ForEach(jsItems) { item in
            jsRow(item)
        }
        ForEach(filtered) { s in
            sourceRow(s)
        }
        .onMove { from, to in
            moveRows(from: from, to: to)
        }
    }

    /// 按域名分组显示（对齐 Legado 的 menu_group_sources_by_domain）
    @ViewBuilder
    private var groupedRows: some View {
        ForEach(hostGroups, id: \.host) { g in
            Section {
                ForEach(g.items) { s in
                    sourceRow(s)
                }
            } header: {
                HStack {
                    Text(g.host)
                    Spacer()
                    Text("\(g.items.count)").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var filtered: [ComicSource] {
        let base = searchText.isEmpty
            ? sources
            : sources.filter { $0.bookSourceName.contains(searchText) || $0.bookSourceUrl.contains(searchText) }
        let byGroup = base.filter { s in
            guard let f = groupFilter else { return true }
            if f == Self.ungroupedKey { return s.groupList.isEmpty }
            return s.groupList.contains(f)
        }
        switch sortMode {
        case .manual:
            return byGroup
        case .name:
            return byGroup.sorted { $0.bookSourceName.localizedStandardCompare($1.bookSourceName) == .orderedAscending }
        case .host:
            return byGroup.sorted { hostOf($0.bookSourceUrl) < hostOf($1.bookSourceUrl) }
        case .enabled:
            // 启用的在前，停用的沉底；同组保持原顺序（稳定排序）
            return byGroup.sorted { $0.isEnabled && !$1.isEnabled }
        }
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

    /// 导出全部为 JSON 文件（可存到「文件」/ 微信 / AirDrop）
    private func exportAll() {
        shareJSONFile(sources, name: "绘漫岛图源_全部")
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
/// 图源排序（对齐 Legado 的「排序」菜单）
enum SourceSort: String, CaseIterable {
    case manual, name, host, enabled

    var title: String {
        switch self {
        case .manual:  return "手动（原顺序）"
        case .name:    return "按名称"
        case .host:    return "按域名"
        case .enabled: return "启用的在前"
        }
    }
}

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
                        if n > 0 {
                            resultMsg = "✅ 成功导入 \(n) 条图源，可关闭本页"
                            onDone()
                        } else {
                            let why = SourceCodec.diagnosis(text)
                            resultMsg = "❌ " + why
                            DiagLog.event("import", "paste", "解析失败：\(why)")
                        }
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
                guard case .success(let url) = result else {
                    resultMsg = "❌ 没选到文件"
                    return
                }
                let secured = url.startAccessingSecurityScopedResource()
                defer { if secured { url.stopAccessingSecurityScopedResource() } }

                // 🔴 按**字节**读，不要只认 UTF-8 —— Windows 记事本存的 GBK、
                //    某些工具存的 UTF-16 都会让 `String(contentsOf:encoding:.utf8)` 直接失败，
                //    表现就是「文件读取失败」，而同一份文件在别人手机上能导入。
                guard let data = try? Data(contentsOf: url) else {
                    resultMsg = "❌ 读不到文件（iCloud 未下载 / 无权限）。可改用「粘贴 JSON」"
                    DiagLog.event("import", "file", "Data(contentsOf:) 失败")
                    return
                }
                guard let t = SourceCodec.text(from: data), !t.isEmpty else {
                    resultMsg = "❌ 文件是空的（\(data.count) 字节）"
                    return
                }
                let n = importText(t)
                if n > 0 {
                    resultMsg = "✅ 从文件导入 \(n) 条图源"
                    onDone()
                } else {
                    let why = SourceCodec.diagnosis(t)
                    resultMsg = "❌ " + why
                    DiagLog.event("import", "file", "解析失败 \(data.count) B：\(why)")
                }
            }
            .onChange(of: pickedPhoto) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let img = UIImage(data: data), let code = QRDecoder.decode(img) {
                        // 图源码：单张就含全部数据，相册识图也能直接导入
                        if SourceQRCodec.isSourceCode(code) {
                            if let json = SourceQRCodec.decode(code) {
                                let n = importText(json)
                                resultMsg = n > 0 ? "✅ 从图片导入 \(n) 条图源" : "❌ 图源码解析不出图源"
                                if n > 0 { onDone() }
                            } else {
                                resultMsg = "❌ 图源码解析失败"
                            }
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
        DiagLog.event("import", "ok", "\(t.count) 字符 → \(list.count) 条图源")
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
