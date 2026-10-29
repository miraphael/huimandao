import SwiftUI

/// 推荐页 —— 对齐安卓 RecommendFragmant 设计：
/// 顶栏 = 当前图源名 + 倒三角切换；栏目横向 Tab（ruleFindUrl）；内容 = 该源栏目下的漫画列表
struct RecommendView: View {
    /// 被「漫画」标签页包在它的 NavigationStack 里时为 true（不再自带导航栈）
    var embedded: Bool = false
    /// 主题 —— 本页内容是一个 `List`，必须显式隐藏它的滚动背景，
    /// 否则主题背景（含自定义图）会被 List 自己的底色整个盖住。
    @EnvironmentObject var themeStore: ThemeStore
    @AppStorage("lastRecommendSource") private var lastSourceUrl = ""
    @State private var sources: [ComicSource] = []
    @State private var selectedSource: ComicSource?
    @State private var columns: [FindColumn] = []
    @State private var selectedColumn: FindColumn?
    @State private var items: [SearchResult] = []
    @State private var loading = false
    @State private var page = 1
    @State private var loadingMore = false
    /// 请求代 —— 见 `load(page:)` 的说明（防止晚到的旧栏目结果覆盖新栏目）
    @State private var loadGen = 0
    @State private var hasMore = true
    @State private var moreMessage = ""
    /// 漫画台空着时的**具体原因**（别只写「还没有图源」—— 用户明明有源）
    @State private var emptyReason = ""
    @State private var showLogin = false
    /// 详情页预取任务 —— 换栏目/换源时取消，避免为旧列表白拉
    @State private var prefetchTask: Task<Void, Never>?

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
        }
    }

    private var content: some View {
        Group {
            VStack(spacing: 0) {
                // 顶栏：图源切换（倒三角）
                HStack {
                    Spacer()
                    Menu {
                        ForEach(sources, id: \.bookSourceUrl) { s in
                            Button {
                                switchSource(s)
                            } label: {
                                HStack {
                                    Text(s.bookSourceName)
                                    if s.bookSourceUrl == selectedSource?.bookSourceUrl { Image(systemName: "checkmark") }
                                }
                            }
                        }
                        if sources.isEmpty {
                            Text("无可用图源（先到「图源」导入）")
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text("发现 · ")
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.text.opacity(0.45))
                            Text(selectedSource?.bookSourceName ?? "选择图源")
                                .font(.system(size: 15, weight: .semibold))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        .foregroundStyle(Theme.text)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(height: 46)

                // 栏目横向 Tab（每日更新/综合榜/自制榜…）
                if !columns.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 22) {
                            ForEach(columns) { col in
                                Button {
                                    selectedColumn = col
                                    Task { await load(page: 1) }
                                } label: {
                                    VStack(spacing: 4) {
                                        Text(col.title)
                                            .font(.subheadline)
                                            .fontWeight(selectedColumn?.id == col.id ? .bold : .regular)
                                            .foregroundStyle(selectedColumn?.id == col.id ? .primary : .secondary)
                                        Capsule()
                                            .fill(selectedColumn?.id == col.id ? Theme.accent : .clear)
                                            .frame(width: 22, height: 3)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .frame(height: 40)
                }

                // 内容列表 —— 用 ScrollView + LazyVStack 而不是 List：
                // 🔴 `List` 里的 `NavigationLink` 会在右侧自动加一个**箭头**（disclosure
                //    indicator），而这里每行本身就是一张卡片，箭头纯属多余且挡内容
                //    （2026-10-24 用户反馈「右箭头不需要，影响观看」）。
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(items) { r in
                            NavigationLink {
                                ComicDetailView(noteUrl: r.noteUrl, origin: r.origin, noteHeaders: r.noteHeaders,
                                                prefillName: r.name, prefillCover: r.coverUrl)
                            } label: {
                                RecommendCell(r: r)
                            }
                            .buttonStyle(.plain)   // 去掉系统蓝色高亮
                        }
                        if !items.isEmpty {
                            HStack {
                                Spacer()
                                if loadingMore {
                                    ProgressView()
                                } else if hasMore {
                                    Button("加载更多") { Task { await loadMore() } }
                                        .font(.callout)
                                        .foregroundStyle(.tint)
                                } else {
                                    Text(moreMessage.isEmpty ? "没有更多内容" : moreMessage)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 12)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                }
                .refreshable { await load(page: 1, force: true) }
                .sheet(isPresented: $showLogin) {
                    if let src = selectedSource {
                        NavigationStack { SourceLoginView(source: src) }
                    }
                }
                // 🔴 登录 sheet 关闭后**立即重载栏目** —— 令牌已进 CookieStore，
                //    不重载的话用户以为登录没用（要手动下拉刷新才能看到内容）。
                .onChange(of: showLogin) { open in
                    if !open, selectedSource != nil {
                        Task { await load(page: 1) }
                    }
                }
                .overlay {
                    if loading && items.isEmpty {
                        // 🔴 骨架网格而不是居中转圈（2026-10-29）。
                        //    真机实测：慢站（W漫画）首屏要 1~10 秒，这段时间原来是一整屏空白
                        //    只放一个转圈 —— 用户完全不知道要等多久，观感就是「卡住了」。
                        //    骨架能同时传达三件事：正在加载、内容是网格、大概有几本。
                        skeletonGrid
                    }
                    if !loading && items.isEmpty && !columns.isEmpty {
                        // 🔴 卡拉这类源需要**网页登录拿令牌**，否则抓取一直失败
                        //    （真机日志：`[browse] find ❌ 抓取失败 .../type/Cc-----.html` 反复出现）。
                        //    有 loginUrl 的源给出明确的引导动作，而不是让用户猜。
                        let needsLogin = selectedSource?.loginUrl?.isEmpty == false
                                     && selectedSource?.loginUrlResult?.isEmpty != false
                        // 🔴 空态要说清「为什么空」（2026-10-28 成熟度改造）。
                        //    以前只会说「站点可能限流或需要过验证」—— 但实测三类原因完全不同：
                        //      · 规则过期（站点改版，列表解析 0）→ 换源/用搜索，重试没用
                        //      · 站点不可达（域名解析失败）→ 换源
                        //      · 需要过验证 → 点「手动过验证」
                        //    体检过的源直接读 `SourceHealth` 的结论，没体检过才用通用文案。
                        let health = selectedSource.flatMap {
                            SourceHealth.state(sourceUrl: $0.bookSourceUrl)
                        }
                        let healthHint: String? = {
                            guard let h = health else { return nil }
                            if h.isChallenge { return "该源需要过人机验证 —— 到「图源」页点「手动过验证」过一次即可" }
                            if h.state == "no_list" {
                                return "该源的「发现栏目」规则已过期（站点改版），建议改用「搜索」找漫画，或换一个源"
                            }
                            if h.state == "dead" { return "该源站点当前不可达（域名解析失败或被墙），建议换源" }
                            if h.state == "no_image" { return "该源正文图解析不到（图床或规则已失效），建议换源" }
                            return nil
                        }()
                        EmptyState(title: "该栏目暂无内容", systemImage: "sparkles",
                                   description: needsLogin
                                       ? "「\(selectedSource?.bookSourceName ?? "该图源")」需要先网页登录获取访问令牌，否则抓取会一直失败"
                                       : (healthHint ?? "可能是站点限流或网络波动，点下面重试一次（会自动尝试内置浏览器过验证）"),
                                   actionTitle: needsLogin ? "去网页登录" : "重新加载") {
                            if needsLogin { showLogin = true }
                            else { Task { await load(page: 1) } }
                        }
                    }
                    if !loading && sources.isEmpty {
                        EmptyState(title: emptyReason.isEmpty ? "还没有图源" : emptyReason,
                                   systemImage: "square.stack.3d.up",
                                   description: emptyReason.contains("发现栏目")
                                       ? "到「图源」→ 编辑该源 → 填「发现栏目」（格式：名称::网址）\n或者直接用「搜索」页找漫画"
                                       : "到「图源」页导入（支持二维码 / 链接 / 粘贴）")
                    }
                    // 🔴 补上第三种情况（此前是「空白无解释」的真空地带）：
                    //    **有图源、但该源的 ruleFindUrl 为空** → 栏目 Tab 不显示
                    //    （`if !columns.isEmpty`），而上面两个 EmptyState 也都不命中
                    //    → 整页空白，用户只会说「发现页没有栏目」，完全无从下手。
                    //    2026-10-15 用户实测反馈。
                    if !loading && !sources.isEmpty && columns.isEmpty {
                        EmptyState(title: "该图源没有发现栏目", systemImage: "square.grid.2x2",
                                   description: "「\(selectedSource?.bookSourceName ?? "当前图源")」没有配置发现栏目。\n到「图源」→ 编辑它 → 填写「发现栏目」字段（格式：名称::网址，多个用换行分隔）")
                    }
                }
            }
            .navigationBarHidden(true)
            .onAppear { bootstrap() }
        }
    }

    private func bootstrap() {
        if sources.isEmpty {
            // 去重：同一 URL 只留一个（重复导入包时防 SwiftUI ForEach 重复 ID 崩溃）
            var seen = Set<String>()
            let enabled = ComicRepository.shared.allSources(includeDisabled: false)
            let withFind = enabled.filter { !($0.ruleFindUrl ?? "").isEmpty }
            var usable = withFind.filter { $0.isExploreEnabled }
                .filter { seen.insert($0.bookSourceUrl).inserted }

            // 🩹 自愈：有栏目却一个都不可用 → 说明「发现开关」被误关（导入的源常见），
            //    自动打开并把原因记进日志，别让用户面对一片空白。
            if usable.isEmpty && !withFind.isEmpty {
                ComicRepository.shared.setExploreEnabled(urls: withFind.map(\.bookSourceUrl), enable: true)
                seen.removeAll()
                usable = withFind.filter { seen.insert($0.bookSourceUrl).inserted }
                DiagLog.event("recommend", "selfheal",
                              "有 \(withFind.count) 个源配了发现栏目但开关全关 → 已自动打开")
            }
            sources = usable
            if usable.isEmpty {
                if enabled.isEmpty {
                    emptyReason = "还没有启用的图源"
                } else if withFind.isEmpty {
                    emptyReason = "\(enabled.count) 个图源都没有配置「发现栏目」"
                } else {
                    emptyReason = "图源暂时不可用"
                }
            } else {
                emptyReason = ""
            }
            DiagLog.event("recommend", "sources",
                          "启用 \(enabled.count) · 有栏目 \(withFind.count) · 可用 \(usable.count)")
            if selectedSource == nil {
                // 默认漫画台；其次记住的上次选择；最后第一个
                let preferred = sources.first(where: { $0.bookSourceUrl == lastSourceUrl })
                    ?? sources.first(where: { $0.bookSourceName.contains("漫画台") })
                    ?? sources.first
                switchSource(preferred)
            }
        }
    }

    private func switchSource(_ s: ComicSource?) {
        selectedSource = s
        if let s { lastSourceUrl = s.bookSourceUrl }
        guard let s else { columns = []; items = []; return }
        // 该源的发现栏目
        columns = ComicEngine.shared.findColumns(sources: [s])
        selectedColumn = columns.first
        Task { await load(page: 1) }
    }

    /// 首屏骨架 —— 形状**对齐 `RecommendCell`**（64×88 封面 + 三行文字），
    /// 这样数据回来时是「占位被真实内容原地替换」，不会有跳变。
    private var skeletonGrid: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(0..<8, id: \.self) { i in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.16))
                            .frame(width: 64, height: 88)
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.gray.opacity(0.16))
                                .frame(height: 13)
                                .frame(maxWidth: i % 2 == 0 ? 190 : 150)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.gray.opacity(0.12))
                                .frame(width: 46, height: 12)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.gray.opacity(0.10))
                                .frame(width: 110, height: 10)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
            }
            .padding(.top, 8)
        }
        .allowsHitTesting(false)
        .modifier(SkeletonPulse())
    }

    private func load(page p: Int, force: Bool = false) async {
        guard let col = selectedColumn else { items = []; return }
        // 🔴 请求代校验：快速切图源/栏目时每次都会起新 Task，**先发的 explore 晚到**
        //    会用旧栏目的结果覆盖新栏目的 `items`（用户看到「切了没反应」或内容对不上）。
        //    `ReaderView`(loadToken) / `DetailSession`(requestID) / `SearchSession`(searchID)
        //    都有这层防护，**只有这里漏了**。（由智能体「并发」发现）
        loadGen &+= 1
        let gen = loadGen
        loading = p == 1
        if p == 1 {
            page = 1
            hasMore = true
            moreMessage = ""
        } else {
            page = p
        }
        defer { if gen == loadGen { loading = false } }
        let r = await ComicEngine.shared.explore(col, page: p, forceRefresh: force)
        guard gen == loadGen else { return }     // 晚到的旧结果：整段丢弃，不碰 items
        items = r
        if p == 1, r.isEmpty {
            hasMore = false
            moreMessage = "栏目暂无可解析内容"
        }
        if p == 1 { startPrefetch(r) }
    }

    /// 预取前几本书的**详情 HTML** —— 用户滑两下再点就是 0ms。
    ///
    /// 这是「打开漫画很慢」的正面解法：慢站的网络延迟无法消除，
    /// 只能**在用户点击之前**把它走完。详见 `ComicEngine.prefetchDetails`。
    private func startPrefetch(_ list: [SearchResult]) {
        prefetchTask?.cancel()
        guard !list.isEmpty else { return }
        let seeds = list.prefix(6).map {
            (noteUrl: $0.noteUrl, origin: $0.origin, headers: $0.noteHeaders)
        }
        prefetchTask = Task {
            await ComicEngine.shared.prefetchDetails(seeds, limit: 6)
        }
    }

    private func loadMore() async {
        guard let col = selectedColumn, !loadingMore, hasMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let requestedPage = page + 1
        let more = await ComicEngine.shared.explore(col, page: requestedPage)
        let existing = Set(items.map(\.id))
        let fresh = more.filter { !existing.contains($0.id) }
        guard !fresh.isEmpty else {
            hasMore = false
            moreMessage = more.isEmpty
                ? "没有解析到新内容，可能已到末页或该栏目不支持翻页"
                : "下一页内容与已显示项目重复，已停止翻页"
            return
        }
        page = requestedPage
        items += fresh
        moreMessage = ""
    }
}

struct RecommendCell: View {
    let r: SearchResult
    var body: some View {
        HStack(spacing: 12) {
            // 🔴 必须带源站 Referer：`image.kalaimg.top` 这类图床**无 Referer 直接 403**
            CoverImage(url: r.coverUrl, referer: r.origin)
                .frame(width: 64, height: 88)
                .hmdThumb()
            VStack(alignment: .leading, spacing: 6) {
                Text(r.name)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                // 来源做成强调色小胶囊 —— 一眼区分「这本书来自哪个源」
                Text(r.originName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Theme.accent.opacity(0.13), in: Capsule())
                    .lineLimit(1)
                if !r.lastChapter.isEmpty {
                    Text(r.lastChapter)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text.opacity(0.45))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .hmdRowCard()
    }
}

/// 骨架呼吸动画 —— 1.1 秒一次透明度往返。
///
/// 用 `.animation(_:value:)` 而不是 `withAnimation` 反复触发：
/// 后者需要 Timer 驱动，页面切走时容易漏停；前者由 SwiftUI 自己管理生命周期。
private struct SkeletonPulse: ViewModifier {
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.55 : 1)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}
