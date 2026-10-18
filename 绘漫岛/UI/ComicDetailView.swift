import SwiftUI
import UIKit

/// 漫画详情 —— 对应 ComicDetailActivity
/// 续读定位。详情页与章节列表页**共用**，做成 fileprivate 自由函数 ——
/// 两边调用的是同一份进度，逻辑必须一致（否则同一个功能两个入口行为不同）。
fileprivate enum ResumeLocator {
    static func page(for ch: ComicInfo.Chapter,
                     info: ComicInfo?,
                     progress: (chapterUrl: String, chapterName: String, page: Int)?) -> Int {
        guard let r = progress else { return 0 }
        // URL 命中最可靠，直接用它
        if r.chapterUrl == ch.url { return max(0, r.page) }
        // 🔴 章名兜底必须**带唯一性约束** —— 图集站每章都叫「正文」，
        //    不加约束时 URL（带会变的 token）对不上就落到「章名相等」→
        //    点任意一章都恢复到**另一个同名章**的进度页（用户以为进度错乱）。
        //    只有「这本书里该章名唯一」才认章名命中。（由复审智能体发现的回归）
        if !r.chapterName.isEmpty, r.chapterName == ch.name, isChapterNameUnique(r.chapterName, in: info) {
            return max(0, r.page)
        }
        return 0
    }

    /// 该书内该章节名是否**唯一**（唯一才可用于续读兜底匹配）
    static func isChapterNameUnique(_ name: String, in info: ComicInfo?) -> Bool {
        guard !name.isEmpty, let info else { return false }
        return info.chapters.filter { $0.name == name }.count == 1
    }
}

struct ComicDetailView: View {
    let noteUrl: String
    let origin: String
    let noteHeaders: [String: String]
    @StateObject private var session: DetailSession
    @State private var ascending = true
    @State private var inShelf = false
    /// 彩蛋主题「黑白纸」：封面转黑白、直角黑边、按钮墨色
    @EnvironmentObject private var themeStore: ThemeStore

    private var isManga: Bool { themeStore.currentID == ThemeStore.mangaThemeID }

    private var info: ComicInfo? { session.info }
    private var loading: Bool { session.isLoading }

    init(noteUrl: String, origin: String, noteHeaders: [String: String] = [:]) {
        self.noteUrl = noteUrl
        self.origin = origin
        self.noteHeaders = noteHeaders
        _session = StateObject(wrappedValue: DetailSession(
            noteUrl: noteUrl, origin: origin, noteHeaders: noteHeaders))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if loading && info == nil {
                    // 首屏在等详情页 HTML（慢站可能要几秒到几十秒）。只放一个转圈会让用户
                    // 以为卡死；这里给出阶段文案 + 目标图源，明确「正在做什么」。
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在连接图源并解析详情…").font(.footnote).foregroundStyle(.secondary)
                        Text(origin).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                }
                if let info {
                    HStack(alignment: .top, spacing: 12) {
                        CoverImage(url: info.coverUrl)
                            .grayscale(isManga ? 1 : 0)
                            .frame(width: 110, height: 152)
                            .clipShape(RoundedRectangle(cornerRadius: isManga ? 0 : 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: isManga ? 0 : 8)
                                    .strokeBorder(Color(hex: "#14141A") ?? .black,
                                                  lineWidth: isManga ? 1.8 : 0)
                            )
                        VStack(alignment: .leading, spacing: 6) {
                            Text(info.name).font(.title3.bold())
                            if !info.author.isEmpty { Text(info.author).font(.subheadline).foregroundStyle(.secondary) }
                            if !info.lastChapter.isEmpty { Text("最新: \(info.lastChapter)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            if !info.kind.isEmpty {
                                Text(info.kind.split(whereSeparator: { ",;，|".contains($0) }).prefix(5).joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(.tint)
                            }
                            Text("图源: \(SourceProviderRegistry.shared.displayName(forOrigin: info.origin))").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)

                    HStack {
                        Button {
                            if inShelf { ComicRepository.shared.removeFromShelf(noteUrl: info.noteUrl) }
                            else { ComicRepository.shared.addToShelf(info: info) }
                            inShelf = ComicRepository.shared.inShelf(noteUrl: info.noteUrl)
                        } label: {
                            Label(inShelf ? "已在书架" : "加入书架", systemImage: inShelf ? "checkmark" : "plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(isManga
                              ? (inShelf ? (Color(hex: "#8E897A") ?? .gray) : (Color(hex: "#14141A") ?? .black))
                              : (inShelf ? .gray : .pink))
                        NavigationLink {
                            // 「开始阅读」的去向：
                            //   ① 有阅读进度 → 直接跳上次那一章那一页
                            //   ② **只有一章** → 直接进阅读器，不再让用户多点一次
                            //      图集类站点（紳士漫畫 wnacg 就是这种）一个相册就是一章，
                            //      章名恒为「正文」。旧行为是先进一个只有一行「正文」的
                            //      章节列表，用户反馈「只显示一个正文，然后就没了」。
                            //   ③ 其余 → 进章节列表
                            // ⚠️ `ComicInfo` 本身不带进度字段（进度存在书架表里），
                            //    必须走 `ComicRepository.progress(noteUrl:)` 查。
                            if let p = ComicRepository.shared.progress(noteUrl: info.noteUrl),
                               p.page > 0 || !p.chapterUrl.isEmpty,
                               let last = info.chapters.first(where: { $0.url == p.chapterUrl }) {
                                ReaderView(info: info, startChapter: last, startPage: p.page)
                            } else if info.chapters.count == 1, let only = info.chapters.first {
                                ReaderView(info: info, startChapter: only)
                            } else {
                                ChapterListView(info: info, resumeProgress: resumeProgress)
                            }
                        } label: {
                            Label("开始阅读", systemImage: "book").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(isManga ? (Color(hex: "#14141A") ?? .black) : .pink)
                        .disabled(info.chapters.isEmpty)
                    }
                    .padding(.horizontal)

                    // 次行操作：下载 / 换源 / 刷新章节
                    HStack(spacing: 8) {
                        NavigationLink {
                            ChapterListView(info: info, resumeProgress: resumeProgress, downloadMode: true)
                        } label: {
                            Label("下载", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(info.chapters.isEmpty)

                        NavigationLink {
                            // ⚠️ 两个坑（都踩过，CI 实测报错）：
                            //   ① 不要传 `id:` —— `SearchResult.id` 是**计算属性**
                            //      （`"\(origin)|\(noteUrl)"`），没有 setter，
                            //      也不在 memberwise init 的参数表里
                            //      → `extra argument 'id' in call`
                            //   ② **实参顺序必须与属性声明顺序一致**，Swift 的
                            //      memberwise init 不按标签重排
                            //      → `argument 'lastChapter' must precede argument 'origin'`
                            MultiSourceDetail(name: info.name, firstHit: SearchResult(
                                name: info.name, author: info.author, coverUrl: info.coverUrl,
                                lastChapter: info.lastChapter, noteUrl: info.noteUrl,
                                origin: info.origin, originName: info.origin,
                                noteHeaders: noteHeaders))
                        } label: {
                            Label("换源", systemImage: "arrow.left.arrow.right").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            // ⚠️ 不能在 `if let info { ... }` 里直接写 `info = ...` ——
                            //    那个 `info` 是 **let 常量**（shadow 了 @State 属性），
                            //    编译报 `cannot assign to value: 'info' is a 'let' constant`（CI 实测）。
                            //    收进方法里，方法内 `info` 解析到 @State 属性（其 setter 是
                            //    nonmutating，非 mutating 方法里也能赋值）。
                            Task { await reload() }
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal)

                    if !info.introduce.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("简介").font(.headline)
                            Text(info.introduce.trimmingCharacters(in: .whitespacesAndNewlines)).font(.footnote).foregroundStyle(.secondary)
                        }.padding(.horizontal)
                    }

                    HStack(spacing: 8) {
                        Text("章节 \(info.chapters.count)").font(.headline)
                        // 首屏只解析了第一页章节，后台正在补全完整列表（可能含分页探测，要几秒）。
                        // 不给提示的话用户会以为「这本就只有这么多章」——这里明确标注补全中。
                        if session.isEnrichingChapters {
                            HStack(spacing: 4) {
                                ProgressView().scaleEffect(0.6)
                                Text("补全中…").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(ascending ? "正序" : "倒序") { ascending.toggle() }
                    }.padding(.horizontal)

                    if info.chapters.isEmpty && !loading {
                        // ── 章节为 0 时的「自救」入口 ────────────────────────────
                        // 用户不该为了「这个源不行」自己去别的源搜一遍。
                        // 这里直接把「自动换源」摆在最显眼的位置：进 MultiSourceDetail
                        // 并**自动开搜**，跨源找同名漫画，命中就直接跳过去。
                        VStack(spacing: 10) {
                            EmptyState(title: "该图源没解析出章节",
                                       systemImage: "list.bullet.rectangle",
                                       description: "常见原因：站点改版导致规则不匹配、站点需要代理、或该源已失效。\n可以直接在其它图源里找这本漫画。")
                            NavigationLink {
                                // ⚠️ 实参顺序必须与属性声明顺序一致（name → firstHit → autoSearch）
                                MultiSourceDetail(name: info.name, firstHit: SearchResult(
                                    name: info.name, author: info.author, coverUrl: info.coverUrl,
                                    lastChapter: info.lastChapter, noteUrl: info.noteUrl,
                                    origin: info.origin, originName: info.origin,
                                    noteHeaders: noteHeaders), autoSearch: true)
                            } label: {
                                Label("自动换源（在其它图源找这本）", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    // 分卷分组显示（对应 ruleChapterParentName 抓取的分卷）
                    ForEach(chapterSections, id: \.0) { section in
                        if chapterSections.count > 1 {
                            Text(section.0).font(.subheadline.bold()).foregroundStyle(.secondary)
                                .padding(.horizontal)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(section.1) { ch in
                                NavigationLink {
                                    ReaderView(info: info, startChapter: ch,
                                               startPage: resumePage(for: ch))
                                } label: {
                                    Text(ch.name.isEmpty ? "未命名" : ch.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(8)
                                        .background(.gray.opacity(0.08))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    Spacer(minLength: 30)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 详情页两阶段加载由 DetailSession 编排：首屏结果先发布，完整章节在后台补全。
            // 这样 View 只绑定状态，不再自行持有两个异步请求及其竞态逻辑。
            await session.loadIfNeeded()
            inShelf = ComicRepository.shared.inShelf(noteUrl: noteUrl)
            // 续读位置只查一次（见 `resumeProgress` 的说明）——
            // 不能在每行的 `resumePage` 里现查，否则 300 章 = 300 次同步查库。
            refreshResumeProgress()
        }
    }

    private func ordered(_ chapters: [ComicInfo.Chapter]) -> [ComicInfo.Chapter] {
        ascending ? chapters : chapters.reversed()
    }

    /// 强制刷新详情（忽略缓存），由会话层保留旧结果并在请求完成后更新状态。
    private func reload() async {
        await session.refresh()
    }

    /// 点某一章时，如果它就是上次读到的那一章，恢复到上次的页码
    /// 续读位置缓存。
    ///
    /// ⚠️ 为什么必须缓存：`resumePage(for:)` 被**每一个章节行**的 `NavigationLink`
    ///    destination 求值调用一次。若每次现查库，一个 300 章的源就是 **300 次
    ///    主线程同步 SQLite 往返**（`Database.query` 走 `queue.sync`）——
    ///    这就是「详情页一进去就卡一下」的成因。
    ///    这里只在进入/刷新时查**一次**，之后各行读缓存。
    @State private var resumeProgress: (chapterUrl: String, chapterName: String, page: Int)?

    private func refreshResumeProgress() {
        if let p = ComicRepository.shared.progress(noteUrl: noteUrl) {
            resumeProgress = (chapterUrl: p.chapterUrl, chapterName: p.chapterName, page: p.page)
        } else {
            resumeProgress = nil
        }
    }

    private func resumePage(for ch: ComicInfo.Chapter) -> Int {
        ResumeLocator.page(for: ch, info: info, progress: resumeProgress)
    }

    /// 按分卷聚合；无分卷时返回单组
    private var chapterSections: [(String, [ComicInfo.Chapter])] {
        guard let info else { return [("", [])] }
        let chs = ordered(info.chapters)
        guard chs.contains(where: { !$0.group.isEmpty }) else { return [("", chs)] }
        var order: [String] = []
        var dict: [String: [ComicInfo.Chapter]] = [:]
        for c in chs {
            let g = c.group.isEmpty ? "正文" : c.group
            if dict[g] == nil { order.append(g); dict[g] = [] }
            dict[g]?.append(c)
        }
        return order.map { ($0, dict[$0] ?? []) }
    }
}

/// 章节列表页 —— 对应 ChapterActivity（含批量下载）
struct ChapterListView: View {
    let info: ComicInfo
    /// 详情页的续读进度 —— 章节列表点进来时用来定位页码。
    /// 必须由详情页传进来：`ChapterListView` 拿不到 `ComicDetailView` 的状态。
    var resumeProgress: (chapterUrl: String, chapterName: String, page: Int)? = nil
    /// 从详情页的「下载」按钮进入时为 true：默认全选、并自动弹出下载提示
    var downloadMode: Bool = false
    @State private var selection = Set<String>()
    /// 章节显示顺序：true = 按引擎给的顺序（第 1 话在最前）。
    ///
    /// 🔴 这里**必须默认 true** —— 以前是 `false`，配合
    ///    `ascending ? chapters : chapters.reversed()` 就变成**一律反转**，
    ///    于是引擎的升序列表被倒过来显示，用户看到「88 章排在 1 章前面」。
    ///    详情页（`ComicDetailView`）一直是 true，只有这里漏了 → 同一本书
    ///    在两个入口的顺序不一样。（真机反馈 2026-10-14）
    @State private var ascending = true
    @State private var downloadMsg: String? = nil
    /// 已下载（离线可读）的章节 URL 集合 —— 用于打角标 / 提供删除入口
    @State private var downloaded: Set<String> = []

    var body: some View {
        List(info.chapters.reversed(), selection: $selection) { ch in
            NavigationLink {
                ReaderView(info: info, startChapter: ch,
                           startPage: ResumeLocator.page(for: ch, info: info, progress: resumeProgress))
            } label: {
                HStack(spacing: 6) {
                    Text(ch.name).font(.callout)
                    Spacer(minLength: 4)
                    if downloaded.contains(ch.url) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption2).foregroundStyle(.green)
                    }
                }
            }
            // ⚠️ 本页长期处于 editMode(.active)，`swipeActions` 在编辑模式下不生效，
            //    所以删除入口用长按 contextMenu 而不是侧滑。
            .contextMenu {
                if downloaded.contains(ch.url) {
                    Button(role: .destructive) { removeDownload(ch) } label: {
                        Label("删除这一话的下载", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(downloadMode ? "下载章节" : "章节 \(info.chapters.count)")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(selection.count == info.chapters.count ? "取消全选" : "全选") {
                        if selection.count == info.chapters.count { selection.removeAll() }
                        else { selection = Set(info.chapters.map(\.url)) }
                    }
                    // ⚠️ 不要写成 `"下载选中\(sel ? "" : "(\(n))")"` ——
                    //    插值里再嵌字符串极易漏掉外层收尾引号（已踩过，
                    //    brace2.py 校验器抓出来的）。用三元表达式更安全。
                    Button(selection.isEmpty ? "下载选中" : "下载选中(\(selection.count))") { enqueue() }
                        .disabled(selection.isEmpty)
                    Divider()
                    Button("下载最新 10 话") { selectThenDownload(10) }
                    Button("下载全部 \(info.chapters.count) 话") { selectThenDownload(info.chapters.count) }
                    if !downloaded.isEmpty {
                        Divider()
                        Button(role: .destructive) { removeAllDownloads() } label: {
                            Label("删除全部下载(\(downloaded.count))", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .alert("已加入下载", isPresented: Binding(get: { downloadMsg != nil }, set: { if !$0 { downloadMsg = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(downloadMsg ?? "")
        }
        .task {
            // 下载模式：进来就默认选中「最新 10 话」，用户直接点下载即可
            if downloadMode && selection.isEmpty && !info.chapters.isEmpty {
                selection = Set(info.chapters.suffix(10).map(\.url))
            }
            refreshDownloaded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hmdDownloadsChanged)) { _ in
            refreshDownloaded()
        }
    }

    private func refreshDownloaded() {
        downloaded = OfflineLibrary.shared.downloadedChapterUrls(origin: info.origin, noteUrl: info.noteUrl)
    }

    private func removeDownload(_ ch: ComicInfo.Chapter) {
        DownloadManager.shared.removeDownload(chapterUrl: ch.url, origin: info.origin, noteUrl: info.noteUrl)
        refreshDownloaded()
    }

    private func removeAllDownloads() {
        for ch in info.chapters where downloaded.contains(ch.url) {
            DownloadManager.shared.removeDownload(chapterUrl: ch.url, origin: info.origin, noteUrl: info.noteUrl)
        }
        refreshDownloaded()
    }

    private func selectThenDownload(_ count: Int) {
        selection = Set(info.chapters.suffix(count).map(\.url))
        enqueue()
    }

    private func enqueue() {
        let items = info.chapters.filter { selection.contains($0.url) }
        var added = 0
        for ch in items {
            // 已下载的跳过（DownloadManager.addTask 内部也会挡一次）
            if downloaded.contains(ch.url) { continue }
            DownloadManager.shared.addTask(.init(comicKey: "\(info.origin)|\(info.noteUrl)",
                comicName: info.name, chapterName: ch.name, chapterUrl: ch.url,
                origin: info.origin, noteUrl: info.noteUrl))
            added += 1
        }
        downloadMsg = added == 0
            ? "选中的章节都已经下载过了。"
            : "已加入 \(added) 话到下载队列。\n可在「设置 → 下载管理」查看进度；下载完成后离线也能直接打开。"
    }
}

/// 多源聚合/换源 —— 默认只显示当前源；「查找其他图源」按需并发搜索，避免整页无限转圈
struct MultiSourceDetail: View {
    let name: String
    let firstHit: SearchResult
    /// true 时进页即自动开搜（从「章节为 0 → 自动换源」进来时用）
    let autoSearch: Bool
    @StateObject private var session: DetailSession

    private var hits: [SearchResult] { session.alternatives }
    private var searching: Bool { session.isSearchingAlternatives }
    private var searchedOnce: Bool { session.didSearchAlternatives }
    private var chapterCounts: [String: Int] { session.chapterCounts }
    private var probing: Bool { session.isProbingAlternatives }

    init(name: String, firstHit: SearchResult, autoSearch: Bool = false) {
        self.name = name
        self.firstHit = firstHit
        self.autoSearch = autoSearch
        _session = StateObject(wrappedValue: DetailSession(
            noteUrl: firstHit.noteUrl, origin: firstHit.origin,
            noteHeaders: firstHit.noteHeaders))
    }

    var body: some View {
        List {
            Section("当前图源") {
                NavigationLink {
                    ComicDetailView(noteUrl: firstHit.noteUrl, origin: firstHit.origin, noteHeaders: firstHit.noteHeaders)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(firstHit.originName).font(.body)
                        if !firstHit.lastChapter.isEmpty { Text("最新: \(firstHit.lastChapter)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
            }
            Section {
                if searching {
                    HStack { ProgressView().scaleEffect(0.8)
                        Text(probing ? "正在核对各源章节数…（\(chapterCounts.count)/\(min(hits.count, 12))）"
                                     : "查找中…（已找到 \(hits.count) 个）")
                            .font(.callout) }
                } else if hits.isEmpty {
                    Button {
                        Task { await find() }
                    } label: { Label("查找其他图源", systemImage: "magnifyingglass") }
                } else {
                    ForEach(sortedHits) { h in
                        NavigationLink {
                            ComicDetailView(noteUrl: h.noteUrl, origin: h.origin, noteHeaders: h.noteHeaders)
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(h.originName).font(.body)
                                    if !h.lastChapter.isEmpty { Text("最新: \(h.lastChapter)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                Spacer()
                                chapterBadge(h)
                            }
                        }
                    }
                }
            } header: {
                Text("其他图源")
            } footer: {
                if !hits.isEmpty && !probing {
                    Text("已逐个核对各源的真实章节数 —— 有章节的排在前面，优先选它们。")
                        .font(.caption2)
                }
            }
        }
        .transparentScrollBackground()
        .navigationTitle("换源 · \(name)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 从「章节为 0 → 自动换源」进来时自动开搜，用户不用再点一次
            if autoSearch, !searchedOnce, !searching { await find() }
        }
        .onDisappear { session.cancelAlternativeSearch() }
    }

    /// 有章节的排前面，其次按章节数降序
    private var sortedHits: [SearchResult] {
        hits.sorted { a, b in
            let na = chapterCounts[a.id] ?? -1
            let nb = chapterCounts[b.id] ?? -1
            if na != nb { return na > nb }
            return a.originName < b.originName
        }
    }

    @ViewBuilder
    private func chapterBadge(_ h: SearchResult) -> some View {
        if let n = chapterCounts[h.id] {
            Text(n > 0 ? "\(n) 章" : "0 章")
                .font(.caption2)
                .foregroundStyle(n > 0 ? .green : .orange)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background((n > 0 ? Color.green : Color.orange).opacity(0.12), in: Capsule())
        } else if probing {
            ProgressView().scaleEffect(0.6)
        }
    }

    private func find() async {
        await session.findAlternatives(name: name, excludingOrigin: firstHit.origin)
    }
}

/// 本地阅读器
struct LocalReaderView: View {
    let comic: LocalComicScanner.LocalComic
    @State private var pages: [UIImage] = []

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(pages.indices, id: \.self) { i in
                    Image(uiImage: pages[i]).resizable().scaledToFit()
                }
            }
        }
        .navigationTitle(comic.name)
        .task {
            if pages.isEmpty {
                pages = await Task.detached { LocalComicScanner.pages(of: comic).compactMap(UIImage.init(data:)) }.value
            }
        }
    }
}
