import SwiftUI
import UIKit
import Nuke

/// 书架 —— 对应 BookListFragment/BookShelfFragment：分组 Tab + 网格
///
/// `embedded`：被「漫画」标签页包在它的 NavigationStack 里时传 true，
/// 此时**不再自带** NavigationStack（否则会出现二层导航栏、标题重复）。
struct ShelfView: View {
    var embedded: Bool = false
    @State private var items: [ShelfItem] = []
    @State private var selectedGroup: Int64? = nil
    /// 只看有更新的（书架几十本时，红点散在网格里很难找）
    @State private var onlyUpdates = false
    /// 追更引擎（单例，用 @ObservedObject 而不是 @StateObject —— 不拥有它）
    @ObservedObject private var follower = FollowUpdater.shared
    @State private var groups: [(id: Int64, name: String)] = []
    /// 主题：`builtin.manga`「黑白纸」会连带把书架/详情切成漫画分格版式（彩蛋）
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    /// 分组管理页（左滑删除分组的地方）—— 菜单里没法左滑，所以给它一个正经列表页
    @State private var showManageGroups = false

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
        }
    }

    /// 当前要显示的条目（应用「只看有更新」筛选）
    private var shownItems: [ShelfItem] {
        onlyUpdates ? items.filter(\.hasUpdate) : items
    }

    private var updateBadge: Int { items.filter(\.hasUpdate).count }

    private var content: some View {
        Group {
            if items.isEmpty {
                EmptyState(title: "书架空空如也", systemImage: "books.vertical",
                           description: "去「发现」或「搜索」加入漫画吧")
            } else if shownItems.isEmpty {
                EmptyState(title: "没有更新", systemImage: "checkmark.circle",
                           description: "上次追更：\(follower.lastRunText)")
            } else {
                ScrollView {
                    if follower.running || updateBadge > 0 || !follower.lastMessage.isEmpty {
                        updateHeader
                    }
                    // 🎁 主题「黑白纸」= 彩蛋：切成漫画分格（大小错落 + 黑白封面 + 旁白框）
                    //    其它主题保持原来的等宽网格 —— 黑白只是**一个可选主题**，不是全局改造。
                    if themeStore.currentID == ThemeStore.mangaThemeID {
                        ShelfPanelGrid(items: shownItems, groups: groups) { load() }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 14)], spacing: 16) {
                            ForEach(shownItems) { item in
                                // 点击 = 直接续读（对齐安卓 BookShelfFragment.i(int)：
                                // 后台拉详情+章节 → 直接进阅读器，而不是进简介页）
                                NavigationLink(value: ShelfRoute.continue_(item)) {
                                    // 传入**整张书架列表**：预取邻居时不必每个 cell 重查全表
                                    ShelfCell(item: item, all: shownItems)
                                }
                                .contextMenu {
                                    NavigationLink(value: ShelfRoute.detail(item)) {
                                        Label("查看详情", systemImage: "info.circle")
                                    }
                                    Menu("移动到分组") {
                                        Button("未分组") {
                                            ComicRepository.shared.moveToGroup(noteUrl: item.noteUrl, groupId: 0)
                                            load()
                                        }
                                        ForEach(groups, id: \.id) { g in
                                            Button(g.name) {
                                                ComicRepository.shared.moveToGroup(noteUrl: item.noteUrl, groupId: g.id)
                                                load()
                                            }
                                        }
                                    }
                                    Button("移出书架", role: .destructive) {
                                        ComicRepository.shared.removeFromShelf(noteUrl: item.noteUrl)
                                        load()
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
                // 🔴 ScrollView 显式清底 —— 虽然 ScrollView 默认透明，但它是
                //    LazyVGrid 的宿主，某些 iOS 版本下 grid 的容器会留下白底。
                //    `BackgroundAsset` 在根层，这里清了才透得出来。
                .background(Color.clear)
            }
        }
        // 用户要求：书架页顶部那个「书架」标题隐藏。
        // ⚠️ 只清标题、**不隐藏整条导航栏** —— 栏里还有「分组筛选」按钮（topBarLeading），
        //    整条隐藏会把筛选入口一起干掉；而且详情页的返回按钮也依赖它。
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: ShelfRoute.self) { route in
            switch route {
            case .continue_(let item):
                // 续读跳板：拉详情 → 定位到上次读到的那一章 → 直接进阅读器
                ShelfContinueView(item: item)
            case .detail(let item):
                ComicDetailView(noteUrl: item.noteUrl, origin: item.origin)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // 分组筛选（对应 ComicShelfGroupBean 分组 Tab）
                Menu {
                    Button(selectedGroup == nil ? "✓ 全部" : "全部") { selectedGroup = nil; load() }
                    ForEach(groups, id: \.id) { g in
                        Button(selectedGroup == g.id ? "✓ \(g.name)" : g.name) { selectedGroup = g.id; load() }
                    }
                    Divider()
                    Button("新建分组…") { showNewGroup = true }
                    // 删除分组改到这里：菜单里没有「左滑」，所以分组要有个列表页
                    Button {
                        showManageGroups = true
                    } label: {
                        Label("管理分组…", systemImage: "folder.badge.minus")
                    }
                } label: {
                    Label(groups.first(where: { $0.id == selectedGroup })?.name ?? "分组", systemImage: "folder.badge.plus")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: $onlyUpdates) {
                        Label("只看有更新\(updateBadge > 0 ? "（\(updateBadge)）" : "")",
                              systemImage: "arrow.down.circle")
                    }
                    Button {
                        follower.markAllRead()
                        load()
                    } label: {
                        Label("全部标为已读", systemImage: "checkmark.circle")
                    }
                    .disabled(updateBadge == 0)
                    Divider()
                    Button {
                        Task { await refreshUpdates() }
                    } label: {
                        Label(follower.running ? "追更中 \(follower.done)/\(follower.total)" : "检查更新",
                              systemImage: "arrow.clockwise")
                    }
                    .disabled(follower.running)
                } label: {
                    // 有更新时图标带填充色，一眼能看出来
                    Image(systemName: updateBadge > 0
                          ? "arrow.clockwise.circle.fill" : "arrow.clockwise")
                }
            }
        }
        .alert("新建分组", isPresented: $showNewGroup) {
            TextField("分组名", text: $newGroupName)
            Button("创建") {
                guard !newGroupName.isEmpty else { return }
                _ = ComicRepository.shared.createGroup(name: newGroupName)
                newGroupName = ""
                load()
            }
            Button("取消", role: .cancel) {}
        }
        // 分组管理页（左滑删除）
        .sheet(isPresented: $showManageGroups) {
            GroupManageView(groups: groups,
                            selectedGroup: selectedGroup,
                            onSelect: { gid in
                                selectedGroup = gid
                                load()
                            },
                            onChanged: { load() })
        }
        .onAppear {
            load()
            // ── 自动追更 ──
            // 旧实现必须手动点刷新，而没人会记得点。现在距上次超过 N 小时
            // （默认 6，可在设置里改）就静默跑一次，用户打开书架就看到「3 章」角标。
            if follower.shouldAutoRun, !items.isEmpty {
                Task { await refreshUpdates() }
            }
        }
        // 后台导入/修复图源时，边解边刷新（首次启动要几十秒）
        .onReceive(NotificationCenter.default.publisher(for: .hmdSourcesChanged)) { _ in load() }
        // 追更完成 / 标为已读
        .onReceive(NotificationCenter.default.publisher(for: .hmdShelfChanged)) { _ in load() }
    }

    private func load() {
        groups = ComicRepository.shared.groups()
        items = ComicRepository.shared.shelfList(groupId: selectedGroup)
    }

    /// 刷新书架更新。逻辑已迁到 `FollowUpdater`（原来这 20 行只比对
    /// 「最新章节名」，既不知道新增几章，也不能批量处理，见该文件注释）。
    private func refreshUpdates() async {
        await FollowUpdater.shared.checkAll()
        load()
    }

    /// 追更状态行：进度 / 上次结果 / 上次时间
    @ViewBuilder
    private var updateHeader: some View {
        HStack(spacing: 8) {
            if follower.running {
                ProgressView().scaleEffect(0.7)
                Text("正在检查更新 \(follower.done)/\(follower.total)…")
                    .font(.caption).foregroundStyle(.secondary)
            } else if updateBadge > 0 {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.red)
                Text("\(updateBadge) 本有更新").font(.caption)
            } else {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                Text(follower.lastMessage.isEmpty ? "上次追更：\(follower.lastRunText)"
                                                  : follower.lastMessage)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal).padding(.top, 8)
    }
}

struct ShelfCell: View {
    let item: ShelfItem
    /// 整张书架列表（父视图统一读取一次）——预取邻居时用，避免每 cell 全表重查。
    var all: [ShelfItem] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                CoverImage(url: item.coverUrl)
                    .frame(height: 140)
                    // 统一封面语言：12pt 圆角 + 细描边 + 轻投影（见 `HMD.hmdThumb`）
                    .hmdThumb()
                if item.hasUpdate {
                    // 显示「N 章」而不是一个红点 —— 用户能一眼看出更新了几话，
                    // 而不是点进去才知道。数量拿不到时退化成「更新」。
                    Text(item.newChapterCount > 0 ? "\(item.newChapterCount)章" : "更新")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(.red, in: Capsule())
                        .padding(4)
                }
            }
            Text(item.name)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text(item.durChapterName.isEmpty ? item.lastChapterName : "读到:\(item.durChapterName)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text.opacity(0.45))
                .lineLimit(1)
        }
        // 书架是**网格**——一屏可能十几本书。`LazyVGrid` 只创建可视区内 + 少量缓冲的 cell，
        // 用户快速滑动时会看到一片灰底转圈。
        // 这里在 cell 出现时把它后面几本的封面推进 Nuke 预取队列（只写磁盘缓存，
        // 不占内存），滑过去时就是缓存命中、直接出图。
        // 借鉴 Aidoku `Features/Library` 的网格预取做法。
        .onAppear { prefetchNeighbors(in: all) }
    }

    /// 把当前 cell 之后的若干本封面排进预取队列
    ///
    /// ⚠️ 两个曾经的性能坑（书架滑动掉帧的元凶）：
    ///   ① `shelfList()` 是**全表**读，每个 cell `onAppear` 都调一次；
    ///   ② 反查图源 Referer 时在 `for j` **循环体内**调 `allSources()`，
    ///      一次预取 = 6 个邻居 × 全表扫描（几百源 × 45 字段构造）。
    ///
    /// 现在改为：`shelfList()` 由父视图 `ShelfView` 统一传入（`all`），
    /// 域名反查走 `source(forHost:)` 的 O(1) 索引 —— 循环体内**零数据库访问**。
    private func prefetchNeighbors(in all: [ShelfItem]) {
        guard let idx = all.firstIndex(where: { $0.noteUrl == item.noteUrl }) else { return }
        let end = min(all.count, idx + 7)          // 往后预取 6 本
        guard idx + 1 < end else { return }
        var reqs: [ImageRequest] = []
        for j in (idx + 1)..<end {
            let u = all[j].coverUrl
            guard !u.isEmpty else { continue }
            // 循环体内不再触碰数据库：host 索引一次建立、反复命中
            var ref = ""
            var uag = ""
            if let host = URL(string: u)?.host,
               let s = ComicRepository.shared.source(forHost: host) {
                ref = s.bookSourceUrl
                uag = s.httpUserAgent ?? ""
            }
            if let r = HMDImagePipeline.request(url: u, referer: ref, ua: uag) {
                reqs.append(r)
            }
        }
        if !reqs.isEmpty { HMDImagePipeline.prefetcher.startPrefetching(with: reqs) }
    }
}

/// 封面图（走全局 Nuke 管线）
///
/// ── 为什么换成 Nuke ────────────────────────────────────────────────────
/// 旧的 `ImageCache`（actor + 内存字典 + 每图一个文件）在这几个点上会「转圈」：
///   · **没有请求去重**：书架网格里同一本漫画被滚出/滚回，会重复发起下载；
///   · **没有取消传播**：`CoverImage` 被回收后 URLSession 任务还在跑，占着并发额度，
///     真正可见的封面反而排队；
///   · **没有 LRU**：内存字典只增不减，磁盘上每图一个文件不做上限，久了会拖慢 IO。
/// Nuke 这三件事都是内建的（去重 / 取消 / 双层 LRU），而且和阅读器共用同一份磁盘缓存，
/// 于是「封面加载出来的图」在进阅读器时可以直接复用。
// MARK: - 彩蛋主题「黑白纸」：漫画分格网格（2026-10-18）
//
// ⚠️ 这一整套**只在主题 = `builtin.manga` 时启用**（见 ShelfView 的 body 分支）。
//    其它主题走原来的等宽网格 + `ShelfCell`，互不影响。

/// 一格分格
private struct ShelfPanel: Identifiable {
    let item: ShelfItem
    let height: CGFloat
    var id: String { item.noteUrl }
}

/// 一行里的一个槽位：单个分格，或右侧竖排两格
private enum ShelfSlot: Identifiable {
    case single(ShelfPanel, flex: CGFloat)
    case stack([ShelfPanel], flex: CGFloat)

    var id: String {
        switch self {
        case .single(let p, _): return p.id
        case .stack(let ps, _): return ps.map(\.id).joined(separator: "|")
        }
    }
    var flex: CGFloat {
        switch self {
        case .single(_, let f): return f
        case .stack(_, let f): return f
        }
    }
    var height: CGFloat {
        switch self {
        case .single(let p, _): return p.height
        case .stack(let ps, _):
            return ps.reduce(CGFloat(0)) { $0 + $1.height } + CGFloat(max(ps.count - 1, 0)) * 4
        }
    }
}

private struct ShelfPanelRow: Identifiable {
    let id: Int
    let slots: [ShelfSlot]
    var height: CGFloat { slots.map(\.height).max() ?? 104 }
}

/// 黑白纸主题的分格网格：按行型循环，让分格大小错落
///   型 0：1 大格 + 右侧竖排 2 小格（最像漫画分格）
///   型 1：3 等分
///   型 2：1 通栏
/// 竖缝 4pt / 横缝 7pt —— 真实漫画的排版节奏（竖窄横宽）。
struct ShelfPanelGrid: View {
    let items: [ShelfItem]
    /// 分组列表（父视图统一读一次，避免每个分格都查库）
    var groups: [(id: Int64, name: String)] = []
    /// 长按菜单里改了分组 / 移出书架后回调（让父视图重新读库）
    var onChanged: () -> Void

    private let vGap: CGFloat = 4
    private let hGap: CGFloat = 7

    var body: some View {
        VStack(spacing: hGap) {
            ForEach(rows) { row in
                GeometryReader { geo in
                    let total = row.slots.reduce(CGFloat(0)) { $0 + $1.flex }
                    let avail = geo.size.width - vGap * CGFloat(max(row.slots.count - 1, 0))
                    HStack(spacing: vGap) {
                        ForEach(row.slots) { slot in
                            slotView(slot, width: avail * slot.flex / max(total, 1))
                        }
                    }
                }
                .frame(height: row.height)
            }
        }
    }

    @ViewBuilder
    private func slotView(_ slot: ShelfSlot, width: CGFloat) -> some View {
        switch slot {
        case .single(let p, _):
            link(p).frame(width: width)
        case .stack(let ps, _):
            VStack(spacing: vGap) {
                ForEach(ps) { p in link(p) }
            }
            .frame(width: width)
        }
    }

    @ViewBuilder
    private func link(_ p: ShelfPanel) -> some View {
        NavigationLink(value: ShelfRoute.continue_(p.item)) {
            MangaShelfCell(item: p.item, all: items, panelHeight: p.height)
        }
        .contextMenu {
            NavigationLink(value: ShelfRoute.detail(p.item)) {
                Label("查看详情", systemImage: "info.circle")
            }
            Menu("移动到分组") {
                Button("未分组") {
                    ComicRepository.shared.moveToGroup(noteUrl: p.item.noteUrl, groupId: 0)
                    onChanged()
                }
                ForEach(groups, id: \.id) { g in
                    Button(g.name) {
                        ComicRepository.shared.moveToGroup(noteUrl: p.item.noteUrl, groupId: g.id)
                        onChanged()
                    }
                }
            }
            Button("移出书架", role: .destructive) {
                ComicRepository.shared.removeFromShelf(noteUrl: p.item.noteUrl)
                onChanged()
            }
        }
    }

    /// 分格布局 —— **每格都是 2:3**（漫画封面的标准比例）。
    ///
    /// 🔴 为什么必须这样（v124→v127 的教训）：
    /// 原来格子是「宽而矮」的（118×132、354×168），而封面是 2:3 竖版：
    /// · `scaledToFill` → 上下被裁掉 → 用户说「封面显示不全」
    /// · `scaledToFit`  → 缩到 88 宽留白 → 用户说「图片变小了」
    /// 两者都治不好，因为**问题在格子形状，不在缩放方式**。
    /// 把格子做成 2:3 后，`scaledToFill` 既不裁也不缩，正好铺满。
    ///
    /// 宽度按 iPhone 常见屏宽算：内容宽 ≈354，两列各 ≈175 → 高 = 175×1.5 ≈ 262。
    private var rows: [ShelfPanelRow] {
        let perRow = 2
        let cellHeight: CGFloat = 262
        var out: [ShelfPanelRow] = []
        var i = 0, n = 0
        while i < items.count {
            let take = min(perRow, items.count - i)
            let ps = (0..<take).map { ShelfPanel(item: items[i + $0], height: cellHeight) }
            out.append(ShelfPanelRow(id: n, slots: ps.map { .single($0, flex: 1) }))
            i += take
            n += 1
        }
        return out
    }
}

/// 黑白纸主题的分格 cell：封面转黑白 + 直角黑边 + 旁白框书名
struct MangaShelfCell: View {
    let item: ShelfItem
    var all: [ShelfItem] = []
    var panelHeight: CGFloat = 140

    private static let ink = Color(hex: "#14141A") ?? .black
    private static let paper = Color(hex: "#F3EEE1") ?? .white

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // 格子已经是 2:3，`scaledToFill` 正好铺满 —— 不裁切、不缩小。
            // （之前用 fit: true 是为了「显示完整」，但那会让 2:3 封面在宽格子里缩水）
            CoverImage(url: item.coverUrl)
                .grayscale(1)
                .frame(maxWidth: .infinity)
                .frame(height: panelHeight)
                .background(Self.paper)
                .clipped()

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    Text(item.name)
                        .font(.system(size: 10, weight: .heavy))
                        .lineLimit(1)
                        .foregroundStyle(Self.paper)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Self.ink)
                    Spacer(minLength: 0)
                }
            }

            if item.hasUpdate {
                Text(item.newChapterCount > 0 ? "\(item.newChapterCount) 新" : "新")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(Self.paper)
                    .padding(.horizontal, 4).padding(.vertical, 1.5)
                    .background(Self.ink)
                    .padding(3)
            }
        }
        .frame(height: panelHeight)
        .clipped()
        .overlay(Rectangle().strokeBorder(Self.ink, lineWidth: 1.6))
        .contentShape(Rectangle())
        .onAppear { prefetchNeighbors(in: all) }
    }

    /// 把当前 cell 之后的若干本封面排进 Nuke 预取队列（与 `ShelfCell` 同一套逻辑）
    private func prefetchNeighbors(in all: [ShelfItem]) {
        guard let idx = all.firstIndex(where: { $0.noteUrl == item.noteUrl }) else { return }
        let end = min(all.count, idx + 7)
        guard idx + 1 < end else { return }
        var reqs: [ImageRequest] = []
        for j in (idx + 1)..<end {
            let u = all[j].coverUrl
            guard !u.isEmpty else { continue }
            var ref = ""
            var uag = ""
            if let host = URL(string: u)?.host,
               let src = ComicRepository.shared.source(forHost: host) {
                ref = src.bookSourceUrl
                uag = src.httpUserAgent ?? ""
            }
            if let r = HMDImagePipeline.request(url: u, referer: ref, ua: uag) {
                reqs.append(r)
            }
        }
        if !reqs.isEmpty { HMDImagePipeline.prefetcher.startPrefetching(with: reqs) }
    }
}

struct CoverImage: View {
    let url: String
    /// 防盗链头；留空时由 `ComicRepository` 按域名反查图源的 Referer / UA。
    var referer: String = ""
    var ua: String = ""
    /// `true` = 完整显示整张封面（不裁切、不拉伸），空白处留底色。
    /// 「黑白纸」主题用它 —— 用户反馈：原来 aspectFill 把 2:3 的封面裁成一条，
    /// 看着像被压扁了。
    var fit: Bool = false
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.gray.opacity(0.15))
            if let image {
                if fit {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: url) {
            image = await Self.load(url: url, referer: referer, ua: ua)
        }
    }

    /// 加载封面：主线程外完成 IO + 解码，避免长列表滚动掉帧。
    static func load(url: String, referer: String, ua: String) async -> UIImage? {
        guard !url.isEmpty else { return nil }
        // 按域名反查图源，补齐 Referer / UA（很多站对封面做防盗链）
        var ref = referer
        var uag = ua
        if ref.isEmpty, let host = URL(string: url)?.host {
            if let s = ComicRepository.shared.source(forHost: host) {
                ref = s.bookSourceUrl
                if uag.isEmpty { uag = s.httpUserAgent ?? "" }
            }
        }
        var hh: [String: String] = [:]
        if !ref.isEmpty { hh["Referer"] = ref }
        if !uag.isEmpty { hh["User-Agent"] = uag }
        guard let req = HMDImagePipeline.request(url: url, referer: ref, ua: uag, headers: hh) else { return nil }
        // ⚠️ `ImagePipeline.image(for:)` 直接返回 `PlatformImage`（= `UIImage`），
        //    **不是** `ImageResponse`，所以没有 `.image` 成员
        //    （写过会报 "value of type 'PlatformImage' has no member 'image'"）。
        //    返回类型是 `PlatformImage` 而非可选，成功即图片，失败则抛错。
        return try? await HMDImagePipeline.shared.image(for: req)
    }
}

// MARK: - 书架续读

/// 书架导航路由
enum ShelfRoute: Hashable {
    case continue_(ShelfItem)
    case detail(ShelfItem)
}

/// 续读跳板 —— 对齐安卓 BookShelfFragment.i(int)：
/// 点击书架先在后台把详情+章节拉齐，然后 **直接进阅读器**（而不是先给用户看简介目录页）。
/// 上次读到哪一章就续哪一章；没有进度则从第一章开始。
struct ShelfContinueView: View {
    let item: ShelfItem
    @State private var phase: Phase = .loading
    @State private var info: ComicInfo?

    enum Phase: Equatable { case loading, failed(String), ready }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在打开《\(item.name)》…").font(.callout).foregroundStyle(.secondary)
                    Text("仅首次需要抓取章节，之后秒开").font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let msg):
                VStack(spacing: 14) {
                    EmptyState(title: "打开失败", systemImage: "exclamationmark.triangle", description: msg)
                    HStack(spacing: 12) {
                        Button("重试") { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                        NavigationLink {
                            ComicDetailView(noteUrl: item.noteUrl, origin: item.origin)
                        } label: { Text("去详情页") }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                if let info, let ch = startChapter(info) {
                    ReaderView(info: info, startChapter: ch, startPage: restorePage)
                } else {
                    EmptyState(title: "没有可读章节", systemImage: "list.bullet.rectangle",
                               description: "该图源未解析出章节，可能规则失效或站点需要代理")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // 只有「加载中 / 失败」两个阶段藏导航栏；进入阅读器后交还给 ReaderView，
        // 否则它自己的章节名标题和设置菜单会被一起藏掉。
        .toolbar(phase == .ready ? .visible : .hidden, for: .navigationBar)
        .task { if info == nil { await load() } }
    }

    /// 续读页码：只有「要打开的这一章 == 上次读到的那一章」时才恢复页码。
    /// 如果上次读的章节已不存在（被站点删了/改名了）而回退到别的章，页码就无效，必须归零。
    ///
    /// ⚠️ 判据必须与 `startChapter` **同口径**：那里先按 URL 匹配、匹配不到再按**章节名**匹配。
    ///    旧实现只认「URL 完全相等」—— 图源的章节 URL 常带会变的 token（`?m=6&c=...`），
    ///    一旦 URL 变了，`startChapter` 靠名字找到了章节、这里却判成「不是同一章」→
    ///    `restorePage` 恒为 0 → **每次打开都从第 0 页开始**（用户反馈的「进度没保存」）。
    ///    现在：URL 或名字**任一**对上就恢复页码。
    private var restorePage: Int {
        guard let info, let ch = startChapter(info) else { return 0 }
        let urlHit = !item.durChapterUrl.isEmpty && ch.url == item.durChapterUrl
        let nameHit = !item.durChapterName.isEmpty && ch.name == item.durChapterName
        guard urlHit || nameHit else { return 0 }
        return max(0, item.durChapterPage)
    }

    /// 续读起点：优先上次读到的章节 URL；找不到就回到上次章节名匹配；再不行取第一章
    private func startChapter(_ info: ComicInfo) -> ComicInfo.Chapter? {
        if !item.durChapterUrl.isEmpty,
           let hit = info.chapters.first(where: { $0.url == item.durChapterUrl }) {
            return hit
        }
        if !item.durChapterName.isEmpty,
           let hit = info.chapters.first(where: { $0.name == item.durChapterName }) {
            return hit
        }
        return info.chapters.first
    }

    /// 🔴 **自愈过期的章节 URL** —— 图源规则改了之后，同一章的 URL 可能整个变样。
    ///
    /// 真实案例（2026-10-15，manhua3.com）：章节规则从
    /// 「`@js:` 解 `/jump?url=` 参数」改成「直接用 `href`」，
    /// 新 URL 是 `…/jump?url=%2F563672-192739.html`，
    /// 而书架里存的还是旧规则算出来的 `…/<span>第1话 我是狼哦！</span>`
    /// —— 一个**打不开的地址**（实测抓到 1.8KB 错误页、没有 `params`）。
    ///
    /// 表现：点书架上的书「继续阅读」→ 一直**「点击重试」**。
    ///
    /// `startChapter` 本来有「按章节名回退」的逻辑，所以能定位到正确的那一章；
    /// 但**存下来的旧 URL 从没被覆盖**，于是每次都要靠名字兜底，
    /// 书架与进度的显示也一直指向坏地址。
    /// 这里按章节名找到同一章后把旧 URL 覆盖掉，让状态自己修好 ——
    /// 否则用户得手动进详情页点章节才能绕过去。
    ///
    /// ⚠️ 必须在 `load()`（async）里调用，**不能**放进 `body` 的求值路径 ——
    ///    视图更新期间写库 / 改状态会告警，严重时死循环。
    private func healStaleChapterURL(_ info: ComicInfo) {
        guard !item.durChapterUrl.isEmpty, !info.chapters.isEmpty else { return }
        // 旧 URL 还能在新列表里找到 → 没坏，什么都不做
        if info.chapters.contains(where: { $0.url == item.durChapterUrl }) { return }
        // 按章节名找同一章（名字对不上就不动，避免误改）
        guard !item.durChapterName.isEmpty,
              let hit = info.chapters.first(where: { $0.name == item.durChapterName }) else { return }
        ComicRepository.shared.updateProgress(
            noteUrl: item.noteUrl, chapterUrl: hit.url,
            chapterName: hit.name, page: item.durChapterPage, info: info)
        DiagLog.event("restore", "progress",
                      "旧章节 URL 已失效，按章节名自愈 → \(hit.url.prefix(60))")
    }

    private func load(force: Bool = false) async {
        // ── 快路径：本地已有章节列表 → 零网络直开（对齐安卓 daoSession 关联查询）──
        // 这是「每次点进去都要抓取章节」的解法：普通点开根本不发请求。
        if !force, let local = ComicRepository.shared.loadChapters(noteUrl: item.noteUrl), !local.isEmpty {
            var cached = ComicInfo()
            cached.noteUrl = item.noteUrl
            cached.origin = item.origin
            cached.name = item.name
            cached.coverUrl = item.coverUrl
            cached.author = item.author
            cached.kind = item.kind
            cached.lastChapter = item.lastChapterName
            cached.chapters = local
            info = cached
            phase = .ready
            // 图源规则改过之后，书架存的「当前章节」可能是打不开的旧 URL → 自愈
            healStaleChapterURL(cached)
            // 后台静默刷新章节 —— 但**不能每次都刷**：
            // 这个请求会跟阅读器首屏图片抢带宽，而且"刚打开就在联网"正是用户
            // 感知到的「又在抓章节」。只在本地缓存超过 10 分钟时才刷新。
            if ComicRepository.shared.chaptersAge(noteUrl: item.noteUrl) > 600 {
                Task { await refreshInBackground() }
            }
            return
        }

        // ── 慢路径：本地没有 → 联网抓一次 ──
        // 与详情页一致地走**两阶段**：先只要元信息 + 第一页章节（skipPagination）秒开，
        // 完整章节列表（含分页探测，慢站十几秒）交给后台补全。
        // 旧实现一次性抓全量，用户点一本书要盯着转圈等十几秒，正是「太慢了」的来源。
        phase = .loading
        let got = await ComicEngine.shared.detail(noteUrl: item.noteUrl, origin: item.origin,
                                                  forceRefresh: force, skipPagination: !force)
        if got.chapters.isEmpty {
            // 引擎在失败路径填了可行动诊断（网络层/HTTP/规则层），优先展示它。
            // 没有诊断（说明页面正常拿到、只是规则没匹配上）才用通用文案。
            if !got.diagnosis.isEmpty {
                phase = .failed(got.diagnosis)
            } else {
                phase = .failed("章节解析为 0：页面已取到，但 ruleChapterList 选择器没匹配上任何节点。\n图源：\(item.origin)\n→ 该图源规则可能已过期（站点改版）。")
            }
            return
        }
        persist(got)
        info = got
        phase = .ready
        // 同上：联网拿到新章节列表后，顺手修掉过期的「当前章节」URL
        healStaleChapterURL(got)
        // 首屏只带了第一页章节 → 立刻在后台补全完整列表（不阻塞用户开始阅读）。
        if !force {
            Task { await completeChaptersInBackground() }
        }
    }

    /// 首屏之后的**章节补全**：拿到完整章节列表后落库并更新。
    /// 与 `refreshInBackground` 的区别：这里不强制刷新（走缓存），纯粹是「把第一页补成全部」。
    private func completeChaptersInBackground() async {
        let got = await ComicEngine.shared.detail(noteUrl: item.noteUrl, origin: item.origin,
                                                  reuseMetadataFrom: info)
        guard !got.chapters.isEmpty, got.chapters.count > (info?.chapters.count ?? 0) else { return }
        persist(got)
        var merged = info
        merged?.chapters = got.chapters
        merged?.lastChapter = got.lastChapter
        info = merged
    }

    /// 静默后台刷新：拿到新章节就落库并更新列表，失败也不打扰用户
    private func refreshInBackground() async {
        let got = await ComicEngine.shared.detail(noteUrl: item.noteUrl, origin: item.origin,
                                                  forceRefresh: true)
        guard !got.chapters.isEmpty else { return }
        persist(got)
        // 只在章节数变化时才更新界面，避免打断正在阅读的滚动位置
        if got.chapters.count != info?.chapters.count {
            var merged = info
            merged?.chapters = got.chapters
            merged?.lastChapter = got.lastChapter
            info = merged
        }
    }

    /// 落库 + 首次进入时补写进度
    private func persist(_ got: ComicInfo) {
        ComicRepository.shared.saveChapters(noteUrl: got.noteUrl, chapters: got.chapters)
        Database.shared.exec("UPDATE COMIC_SHELF_BEAN SET LAST_CHAPTER_NAME=? WHERE NOTE_URL=? AND (LAST_CHAPTER_NAME IS NULL OR LAST_CHAPTER_NAME='')",
                             got.chapters.last?.name ?? "", got.noteUrl)
        // 已有进度就别覆盖；没有进度才把第一章作为起点
        if item.durChapterUrl.isEmpty, let first = got.chapters.first {
            ComicRepository.shared.updateProgress(noteUrl: got.noteUrl,
                                                  chapterUrl: first.url, chapterName: first.name, page: 0)
        }
    }
}
