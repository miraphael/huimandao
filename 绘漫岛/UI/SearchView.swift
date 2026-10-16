import SwiftUI
import UIKit

/// 多源并发搜索 —— 对应 SearchComicActivity + SearchComicModel
/// 多源并发搜索 —— 对齐绘漫岛 SearchComicActivity + SearchComicModel
///
/// 本视图只负责**展示与交互**；搜索编排（并发/去重/聚合/分页/统计）
/// 全部在 `Search/` 模块里（SearchSession / SearchModels）。
/// 拆分的理由：原来 285 行全塞在这个 View 里，导致
///   ① 分页状态无处安放（`page` 只是个 @State 计数，urlNext 根本没实现）
///   ② 空结果静默返回（用户以为按钮坏了）
struct SearchView: View {
    @StateObject private var session = SearchSession()
    @State private var input = ""
    @FocusState private var focused: Bool
    @State private var showSuggestions = false
    /// 搜索历史的本地快照。
    /// ⚠️ 不能直接读 `SearchHistory.shared.keywords` —— 它是 `private(set) var`，
    ///    改它不会触发 SwiftUI 刷新（历史增删后界面不更新）。用 @State 缓存一份。
    @State private var history: [String] = []

    /// 是否嵌入外层 NavigationStack。
    /// ⚠️ 从书架 / 推荐页 push 进来时**必须传 true** —— SearchView 自带 NavigationStack，
    ///    再嵌一层会出现**双层导航栏**（本项目已踩过这个坑）。
    var embedded: Bool = false

    var body: some View {
        if embedded {
            core
        } else {
            NavigationStack { core }
        }
    }

    private var core: some View {
        VStack(spacing: 0) {
            searchBar
            if showSuggestions && !input.isEmpty {
                suggestionList
            }
            content
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if input.isEmpty { input = session.keyword }
            history = SearchHistory.shared.keywords
        }
        .onChange(of: session.searching) { _ in history = SearchHistory.shared.keywords }
    }

    // MARK: - 搜索框

    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索漫画名 / 作者", text: $input)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit { submit() }
                    .onChange(of: input) { _ in showSuggestions = true }
                if !input.isEmpty {
                    Button {
                        input = ""
                        session.clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(.bar)

            if !session.groups.isEmpty {
                toolbar
            }
        }
    }

    /// 排序 / 按源筛选 / 状态行
    private var toolbar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(SearchSort.allCases) { s in
                        Button {
                            session.sort = s
                        } label: {
                            Label(s.rawValue, systemImage: session.sort == s ? "checkmark" : s.icon)
                        }
                    }
                } label: {
                    Label(session.sort.rawValue, systemImage: "arrow.up.arrow.down")
                        .font(.caption)
                }

                Menu {
                    Button("全部来源") { session.filterOrigin = nil }
                    Divider()
                    ForEach(session.sourceNames, id: \.origin) { item in
                        Button(item.name) { session.filterOrigin = item.origin }
                    }
                } label: {
                    Label(session.filterOrigin == nil ? "全部来源"
                          : (session.sourceNames.first { $0.origin == session.filterOrigin }?.name ?? "来源"),
                          systemImage: "square.stack.3d.up")
                        .font(.caption)
                }
                Spacer()
                Text(session.statusLine).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
        }
        .padding(.bottom, 4)
        .background(.bar)
    }

    // MARK: - 搜索建议

    private var suggestionList: some View {
        let sug = SearchHistory.shared.suggest(input)
        return Group {
            if !sug.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(sug, id: \.self) { k in
                            Button(k) { input = k; submit() }
                                .font(.caption)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if session.searching && session.groups.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在搜索全部图源…").font(.caption).foregroundStyle(.secondary)
                Button("结束搜索") { session.clear() }.font(.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.groups.isEmpty {
            if input.isEmpty {
                historyEntry
            } else {
                EmptyState(title: "无结果", systemImage: "magnifyingglass")
            }
        } else {
            resultList
        }
    }

    private var historyEntry: some View {
        List {
            if !history.isEmpty {
                Section {
                    ForEach(history, id: \.self) { k in
                        Button {
                            input = k
                            submit()
                        } label: {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                                Text(k)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { idx in
                        for i in idx where i < history.count { SearchHistory.shared.remove(history[i]) }
                        history = SearchHistory.shared.keywords
                    }
                } header: {
                    HStack {
                        Text("搜索历史")
                        Spacer()
                        Button("清空") {
                            SearchHistory.shared.clear()
                            history = []
                        }.font(.caption)
                    }
                }
            }
        }
        .transparentScrollBackground()
        .listStyle(.insetGrouped)
    }

    private var resultList: some View {
        List {
            ForEach(session.groups) { g in
                Section {
                    ForEach(g.hits) { r in
                        NavigationLink {
                            MultiSourceDetail(name: r.name, firstHit: r)
                        } label: {
                            ResultCell(r: r)
                        }
                    }
                } header: {
                    HStack {
                        Text(g.displayName).font(.subheadline).textCase(nil)
                        if g.isMerged {
                            Text("\(g.hits.count) 个源")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }
                    }
                }
            }
            moreSection
        }
        .transparentScrollBackground()
        .listStyle(.plain)
    }

    /// 「加载更多」区域。
    ///
    /// 三条原则（都是「点了没反应」逼出来的）：
    ///   ① 按钮**永远可点**（除非正在加载）—— 不要因为其它状态把它藏起来或禁用
    ///   ② 点了必须有反馈：加载中转圈、失败给文案、空页给原因
    ///   ③ 给「诊断串」：真机出问题时截图就能定位（我这边测不到真机网络）
    @ViewBuilder
    private var moreSection: some View {
        if session.loadingMore {
            HStack(spacing: 8) {
                Spacer()
                ProgressView().scaleEffect(0.8)
                Text("正在加载下一页…").font(.footnote).foregroundStyle(.secondary)
                Spacer()
            }
        } else if !session.moreMessage.isEmpty {
            VStack(spacing: 6) {
                Text(session.moreMessage)
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if session.canRetryMore {
                    Button("再试一次") { Task { await session.loadMore() } }
                        .font(.footnote)
                }
                if !session.lastMoreDiag.isEmpty {
                    Text(session.lastMoreDiag).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        } else {
            Button {
                Task { await session.loadMore() }
            } label: {
                HStack {
                    Spacer()
                    Text("加载更多").foregroundStyle(.tint)
                    Spacer()
                }
            }
        }
    }

    // MARK: - 动作

    private func submit() {
        showSuggestions = false
        focused = false
        let k = input
        Task { await session.search(k) }
    }
}

/// 结果单元格 —— 搜索页与发现页（栏目页）**共用同一个类型**。
///
/// ⚠️ 栏目页的 origin 是 JSON 源 URL，永远不会出现 `js://` 前缀，
///    所以「JS」徽标天然只会在搜索页出现，不需要为两处各写一份 Cell。
struct ResultCell: View {
    let r: SearchResult

    /// 来源显示名。
    ///
    /// ⚠️ 两层兜底：
    ///   ① `JSProvider.decodeSearch` 已保证 JS 源结果带 manifest 名；
    ///      但**历史记录/缓存**里的旧数据仍可能是空的（源后来被删、或旧版本存的）。
    ///   ② 这里再走一次 `displayName(forOrigin:)` —— 空串或 `js://id` 都能翻成可读名字。
    /// 不做这层兜底的表现是「来源: 」留白，用户以为 App 坏了。
    private var sourceLabel: String {
        if !r.originName.isEmpty { return r.originName }
        return SourceProviderRegistry.shared.displayName(forOrigin: r.origin)
    }

    /// 该结果是否来自 JS 类源（用于打标）—— 定义在 `YCSource` 上，详情页等多处复用。
    private var isJS: Bool { r.isJSSource }

    var body: some View {
        HStack(spacing: 10) {
            CoverImage(url: r.coverUrl).frame(width: 52, height: 72).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(r.name).font(.body).lineLimit(1)
                if !r.author.isEmpty { Text(r.author).font(.caption).foregroundStyle(.secondary) }
                if !r.kind.isEmpty { Text(r.kind).font(.caption2).foregroundStyle(.tint).lineLimit(1) }
                HStack(spacing: 4) {
                    Text("来源: \(sourceLabel)").font(.caption2).foregroundStyle(.secondary)
                    // JS 源与 JSON 规则源的行为差异较大（脚本可能死循环、需显式信任），
                    // 打个标让用户知道「这条来自 JS 源」，出问题时能对号入座。
                    if isJS {
                        Text("JS")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.85), in: Capsule())
                    }
                }
            }
            Spacer()
        }
    }
}

/// 发现页 —— 对应 FindCategoryActivity：聚合所有启用图源 ruleFindUrl 栏目
struct FindView: View {
    /// 被「漫画」标签页包在它的 NavigationStack 里时为 true（不再自带导航栈）
    var embedded: Bool = false
    @State private var columns: [FindColumn] = []

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
        }
    }

    private var content: some View {
        List(columns) { col in
            NavigationLink {
                FindColumnView(column: col)
            } label: {
                VStack(alignment: .leading) {
                    Text(col.title)
                    Text(col.originName).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("发现")
        .onAppear { columns = ComicEngine.shared.findColumns() }
    }
}

struct FindColumnView: View {
    let column: FindColumn
    @State private var results: [SearchResult] = []
    @State private var loading = true
    @State private var page = 1

    var body: some View {
        List(results) { r in
            NavigationLink {
                ComicDetailView(noteUrl: r.noteUrl, origin: r.origin)
            } label: { ResultCell(r: r) }
        }
        .listStyle(.plain)
        .navigationTitle(column.title)
        .overlay { if loading { ProgressView() } }
        .task {
            if results.isEmpty {
                results = await ComicEngine.shared.explore(column)
                loading = false
            }
        }
        .refreshable {
            results = await ComicEngine.shared.explore(column, page: 1)
        }
    }
}

/// 历史页 —— 对应 HistoryRecordFragment
///
/// `HistoryItem` 已迁至 `Model/HistoryItem.swift`（ARCHITECTURE §7.2 · 批次 1）。
struct HistoryView: View {
    /// 从「设置」里被 NavigationLink 推入时为 true（不再自带导航栈，否则叠两层）
    var embedded: Bool = false
    @State private var items: [HistoryItem] = []

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
        }
    }

    private var content: some View {
        List(items) { h in
            NavigationLink {
                ComicDetailView(noteUrl: h.noteUrl, origin: h.origin)
            } label: {
                HStack {
                    CoverImage(url: h.coverUrl).frame(width: 44, height: 60).clipShape(RoundedRectangle(cornerRadius: 5))
                    VStack(alignment: .leading) {
                        Text(h.name).lineLimit(1)
                        Text(Date(timeIntervalSince1970: TimeInterval(h.upTime) / 1000).formatted(.dateTime))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("历史")
        .onAppear { items = ComicRepository.shared.historyList().map { HistoryItem(noteUrl: $0.noteUrl, name: $0.name, coverUrl: $0.coverUrl, origin: $0.origin, upTime: $0.upTime) } }
    }
}

/// 本地漫画 —— 对应 LocalComicFragment（png/jpg/webp/gif/zip 文件夹扫描）
struct LocalView: View {
    /// 从「设置」里被 NavigationLink 推入时为 true（不再自带导航栈）
    var embedded: Bool = false
    @State private var comics: [LocalComicScanner.LocalComic] = []
    @State private var showImporter = false
    @State private var importMsg: String? = nil

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
        }
    }

    private var content: some View {
        List(comics) { c in
            NavigationLink {
                LocalReaderView(comic: c)
            } label: {
                HStack {
                    if let d = c.coverData, let img = UIImage(data: d) {
                        Image(uiImage: img).resizable().scaledToFill()
                            .frame(width: 44, height: 60).clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    VStack(alignment: .leading) {
                        Text(c.name)
                        Text(kindLabel(c)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("本地")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImporter = true } label: { Label("导入", systemImage: "plus") }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .archive, .item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                var copied = 0
                for url in urls {
                    let secured = url.startAccessingSecurityScopedResource()
                    let dest = docs.appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.removeItem(at: dest)
                    if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { copied += 1 }
                    if secured { url.stopAccessingSecurityScopedResource() }
                }
                importMsg = copied > 0 ? "已导入 \(copied) 个文件" : "导入失败"
                comics = LocalComicScanner.scan()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let msg = importMsg {
                Text(msg).font(.caption).padding(6).frame(maxWidth: .infinity).background(.ultraThinMaterial)
            }
        }
        .overlay { if comics.isEmpty { EmptyState(title: "未找到本地漫画", systemImage: "folder", description: "点右上角 + 导入 zip/rar/7z，或把漫画文件夹放进「文件 App → 绘漫岛」") } }
        .onAppear { comics = LocalComicScanner.scan() }
    }

    private func kindLabel(_ c: LocalComicScanner.LocalComic) -> String {
        switch c.kind {
        case .folder: return "文件夹 · \(c.pageCount)张"
        case .zip: return "ZIP · \(c.pageCount)页"
        case .rar: return "RAR · \(c.pageCount)页"
        case .sevenZip: return "7Z · \(c.pageCount)页"
        }
    }
}
