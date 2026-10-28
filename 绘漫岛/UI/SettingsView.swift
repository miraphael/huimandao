import SwiftUI
import UIKit
import Network

/// 设置 —— 首页
///
/// 从原「长 Form」重构为「首页摘要 + 主题子页」（ARCHITECTURE §8.6）：
/// 首页只保留账号、高频直达（我的内容）与分组入口；具体设置项分散到
/// `ReaderSettingsView` / `SourceSettingsView` / `DownloadFollowSettingsView` /
/// `NetworkSettingsView` / `BackupSettingsView` / `StorageDiagSettingsView`。
///
/// ⚠️ 所有设置项仍由 `AppSettings`（@EnvironmentObject）与原有 `@AppStorage` 键驱动，
///    **键名一个都没改** —— 升级不会丢设置。
struct SettingsView: View {
    @EnvironmentObject var s: AppSettings
    /// 主题 —— 让本页真正跟随主题（背景 + 自定义图）。
    /// ⚠️ 必须显式观察：不读它的话换主题时本页不会重算 body。
    @EnvironmentObject var themeStore: ThemeStore
    /// 版本号单一来源：读 Info.plist（与 project.yml 保持一致，避免多处手改漂移）
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.01"
    }

    /// 构建号（`CURRENT_PROJECT_VERSION`）。
    ///
    /// 🔴 为什么要显示它：同一个版本号会**反复出包**（改规则、修 bug 都要重新构建），
    ///    只看 `1.1.0` 根本分不清手机上装的是哪一次构建 —— 真机排查时
    ///    「日志指纹没变 → 以为代码没生效」白绕过好几轮（其实是 App 没重启）。
    ///    显示成 `1.1.0 (2)` 就能一眼对上。
    static var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }

    /// 完整版本串：`1.0.01 (3)` —— 界面只显示版本号，构建号留给日志排查用。
    /// 版本号规则是「每次升级只加 0.01」，所以版本号本身已经能标识每一次构建。
    static var fullVersion: String { "\(version) (\(buildNumber))" }

    // MARK: - 概览数据

    /// 图源数 / 书架数 —— 一次读库，避免每次重绘都查
    @State private var sourceCount = 0
    @State private var shelfCount = 0
    @State private var readCount = 0

    // MARK: - 卡片与图标

    /// 白色圆角卡片（深浅色都跟着系统走）
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        // 对齐 Legado：surface 底 + 1px border + 小圆角（radius-2 = 12px）
        content()
            .background(Theme.surface,
                        in: RoundedRectangle(cornerRadius: HMD.R.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HMD.R.card, style: .continuous)
                    .strokeBorder(HMD.stroke, lineWidth: 1)
            )
    }

    /// 图标块 —— **统一用强调色浅底 + 强调色图标**。
    ///
    /// 原来是红/橙/绿/蓝/青/灰六种彩色渐变块，一屏看下来像调色板，很杂。
    /// 统一成单色后，整页安静下来，也更「简洁精美」。
    /// （`color` 参数保留，避免改所有调用点；实际不再使用。）
    private func tile(_ icon: String, _ color: Color, size: CGFloat = 30) -> some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(width: size, height: size)
            .background(Theme.accent.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }

    /// 卡片内的一行导航
    private func navRow<D: View>(_ title: String, detail: String?, icon: String,
                                 color: Color, @ViewBuilder destination: () -> D) -> some View {
        NavigationLink { destination() } label: {
            HStack(spacing: 12) {
                tile(icon, color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let detail {
                        Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var hairline: some View {
        Divider().padding(.leading, 56)
    }

    /// 分组标题（对齐 Legado `.setting-section__title`：15pt 粗体 + 底部分隔线）
    private func groupTitle(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.text)
            Rectangle().fill(HMD.stroke).frame(height: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 各区块

    /// 顶部卡：品牌 + 账号 + 统计（三合一，一块渐变）
    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 品牌
            HStack(spacing: 11) {
                Text("绘")
                    .font(.system(size: 19, weight: .black))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.18),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("绘漫岛")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .tracking(1.2)
                    Text("v\(Self.version) · build \(Self.buildNumber)")
                        .font(.system(size: 11))
                        .opacity(0.82)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)

            Rectangle().fill(.white.opacity(0.16)).frame(height: 1)

            // 统计（🔴 账号行已删：用户反馈「估计没用」）
            HStack(spacing: 0) {
                statCell("\(sourceCount)", "图源")
                Rectangle().fill(.white.opacity(0.22)).frame(width: 1, height: 24)
                statCell("\(shelfCount)", "书架")
                Rectangle().fill(.white.opacity(0.22)).frame(width: 1, height: 24)
                statCell("\(readCount)", "在读")
            }
        }
        .padding(16)
        .background(
            LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.70)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: Theme.accent.opacity(0.28), radius: 14, x: 0, y: 8)
    }

    private func statCell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
            Text(label).font(.caption2).foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
    }

    /// 「我的内容」四宫格
    private var contentGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)],
                  spacing: 12) {
            quickTile("历史记录", "clock.arrow.circlepath", .orange) { HistoryView(embedded: true) }
            quickTile("本地漫画", "folder.fill", .blue) { LocalView(embedded: true) }
            quickTile("下载管理", "arrow.down.circle.fill", .green) { DownloadTasksView(embedded: true) }
            quickTile("图集收藏", "heart.fill", .pink) { FavoritesView() }
        }
    }

    private func quickTile<D: View>(_ title: String, _ icon: String, _ color: Color,
                                    @ViewBuilder destination: () -> D) -> some View {
        NavigationLink { destination() } label: {
            HStack(spacing: 10) {
                tile(icon, color, size: 34)
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 14)
            .contentShape(Rectangle())
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// 设置入口卡
    private var settingsCard: some View {
        card {
            VStack(spacing: 0) {
                navRow("阅读", detail: "白边裁剪 · 缩放 · 进度",
                       icon: "book.fill", color: .orange) { ReaderSettingsView() }
                hairline
                navRow("下载与追更", detail: "下载线程 · 自动检查更新",
                       icon: "arrow.down.circle.fill", color: .green) { DownloadFollowSettingsView() }
                hairline
                navRow("网络", detail: "DoH · UA · 搜索线程 · Web 编辑器",
                       icon: "wifi", color: .blue) { NetworkSettingsView() }
                hairline
                navRow("备份同步", detail: "本地备份 · WebDAV 同步",
                       icon: "icloud.fill", color: .teal) { BackupSettingsView() }
                hairline
                navRow("存储与诊断", detail: "缓存清理 · 诊断日志",
                       icon: "internaldrive.fill", color: .gray) { StorageDiagSettingsView() }
                hairline
                // 「两面」视觉底座的真机验收页（F1）。
                // 只新增材质/令牌/翻面容器，不动任何业务界面 —— 但总得有地方看，
                // 否则装到手机上找不到任何变化。正式版可收进开发者选项。
                navRow("设计预览（开发）", detail: "两面 · 令牌 · 翻面",
                       icon: "square.on.square", color: .pink) { DesignPreviewView() }
            }
            .padding(.vertical, 4)
        }
    }

    /// 外观卡
    private var appearanceCard: some View {
        card {
            navRow("主题", detail: "当前：\(themeStore.current.name)",
                   icon: "circle.lefthalf.filled", color: .purple) { ThemeEditorView() }
        }
    }

    /// 社区卡
    private var communityCard: some View {
        card {
            Button { joinQQGroup() } label: {
                HStack(spacing: 12) {
                    tile("person.3.fill", .indigo)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("加入 QQ 群").foregroundStyle(.primary)
                        Text("群号 \(Self.qqGroup) · 问题反馈 / 提需求 / 分享图源")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// 关于卡
    private var aboutCard: some View {
        card {
            VStack(spacing: 0) {
                navRow("关于绘漫岛 / 使用说明", detail: "版本 \(Self.fullVersion)",
                       icon: "info.circle.fill", color: .blue) { AboutView() }
                hairline
                HStack {
                    Text("图源规则").font(.subheadline)
                    Spacer()
                    Text("Legado 兼容格式").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                hairline
                Text("绘漫岛只提供阅读工具，不存储任何漫画内容；所有内容均来自你导入的第三方图源规则。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 页面

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // 品牌 + 账号 + 统计合并成**一块**，避免两块渐变大卡叠在一起（视觉太重）
                    headerCard

                    groupTitle("我的内容")
                    contentGrid

                    groupTitle("设置")
                    settingsCard

                    groupTitle("外观")
                    appearanceCard

                    groupTitle("社区")
                    communityCard

                    groupTitle("关于")
                    aboutCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 32)
            }
            // 主题背景铺在本页这一层（与两个 tab 一致）
            .background(
                ZStack {
                    ThemeBackground(theme: themeStore.current)
                    // Legado `.settings-view--mobile`：右上角强调色 8% 径向渐变
                    RadialGradient(colors: [Theme.accent.opacity(0.08), .clear],
                                   center: .topTrailing, startRadius: 0, endRadius: 420)
                        .ignoresSafeArea()
                }
            )
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                let shelf = ComicRepository.shared.shelfList()
                sourceCount = ComicRepository.shared.allSources().count
                shelfCount = shelf.count
                readCount = shelf.filter { !$0.durChapterUrl.isEmpty }.count
            }
        }
    }

    // MARK: - QQ 群（2026-10-18）

    /// 官方交流群号
    static let qqGroup = "1129980979"

    /// 打开 QQ 的**加群页面**。
    ///
    /// 优先用 QQ 的 URL Scheme 直接跳「群资料卡」（用户点一下就能申请加入）：
    ///   `mqqapi://card/show_pslcard?src_type=internal&version=1&uin=<群号>&card_type=group`
    /// 两个 scheme 依次试（mqqapi 是 QQ 的通用 scheme，mqq 是老版本兜底）。
    /// 都没成功（没装 QQ）→ 复制群号并提示，**不把用户丢去 App Store**。
    private func joinQQGroup() {
        let g = Self.qqGroup
        let schemes = [
            "mqqapi://card/show_pslcard?src_type=internal&version=1&uin=\(g)&card_type=group&source=qrcode",
            "mqq://card/show_pslcard?src_type=internal&version=1&uin=\(g)&card_type=group"
        ]
        openFirst(schemes) {
            UIPasteboard.general.string = g
            let av = UIAlertController(title: "没找到 QQ",
                                       message: "群号 \(g) 已复制到剪贴板，打开 QQ 粘贴搜索就能加入。",
                                       preferredStyle: .alert)
            av.addAction(UIAlertAction(title: "好", style: .cancel))
            UIApplication.shared.topViewController()?.present(av, animated: true)
        }
    }

    /// 依次尝试打开一串 URL，全失败才调用 `fallback`
    private func openFirst(_ urls: [String], fallback: @escaping () -> Void) {
        guard let s = urls.first, let url = URL(string: s) else { fallback(); return }
        UIApplication.shared.open(url, options: [:]) { ok in
            if ok { return }
            DispatchQueue.main.async {
                self.openFirst(Array(urls.dropFirst()), fallback: fallback)
            }
        }
    }
}

extension Notification.Name {
    /// 账号档案发生变化（注册/编辑/退出）—— 设置页据此刷新入口行
    static let hmdAccountChanged = Notification.Name("hmdAccountChanged")
}

/// 推荐页已迁至 RecommendView.swift（对齐安卓：单图源+倒三角切换+栏目Tab）

enum LocalIP {
    static func primary() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let p = ptr {
            let iface = p.pointee
            if let sa = iface.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    let name = iface.ifa_name.map { String(cString: $0) } ?? ""
                    if name == "en0" { return ip }
                }
            }
            ptr = iface.ifa_next
        }
        return nil
    }
}

enum CacheCleaner {
    static func clear() {
        // ① Nuke 的**内存**图片缓存
        HMDImagePipeline.shared.cache.removeAll()

        // ② Nuke 的**磁盘**数据缓存（500MB 上限，占空间的大头）
        //    通过管线重建 `DataCache` 来清空：`DataCache` 自己没有公开的
        //    `removeAll()`（它是按 key 删的），最可靠的做法是删掉它的目录。
        //    ⚠️ 以前这里直接删了整个 Caches 目录 —— 太粗暴：
        //    DataCache 的目录被删后，管线的写入会因为目录不存在而静默失败，
        //    表现为「清完缓存后图片再也缓存不住了」。
        //    现在只删我们自己的缓存目录。
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let ours = caches.appendingPathComponent("com.wsw.cospa.imagecache")
        try? FileManager.default.removeItem(at: ours)

        // ③ 旧的封面/临时缓存目录（历史遗留，若存在一并清掉）
        for legacy in ["covers"] {
            try? FileManager.default.removeItem(at: caches.appendingPathComponent(legacy))
        }
    }
}
