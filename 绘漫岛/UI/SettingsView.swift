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
    @State private var acc = AccountStore.load()

    /// 设置入口行：图标 + 标题 + 一句说明。
    ///
    /// 旧版只有 `Label("阅读", systemImage:)` —— 用户看不出「阅读」里到底能改什么，
    /// 六个入口只能靠点进去试。加一行 secondary 描述后，不用点就能判断该进哪个。
    private func settingsRow(_ title: String, icon: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var accountSection: some View {        Section {
            NavigationLink {
                AccountView()
            } label: {
                HStack(spacing: 12) {
                    Text(acc.isRegistered ? acc.avatar : "👤")
                        .font(.system(size: 26))
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(acc.isRegistered ? acc.nickname : "未登录")
                            .font(.body)
                        Text(acc.isRegistered
                             ? "在书架 \(acc.booksRead) 本 · 已读 \(acc.chaptersRead) 话 · 连续 \(acc.streakDays) 天"
                             : "点此创建一个本地阅读档案")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("账号")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                accountSection

                Section("我的内容") {
                    NavigationLink {
                        HistoryView(embedded: true)
                    } label: {
                        Label("历史记录", systemImage: "clock.arrow.circlepath")
                    }
                    NavigationLink {
                        LocalView(embedded: true)
                    } label: {
                        Label("本地漫画", systemImage: "folder")
                    }
                    NavigationLink {
                        // 已在 SettingsView 的 NavigationStack 内 → 必须 embedded，
                        // 否则会再套一层导航栏（标题重复）。
                        DownloadTasksView(embedded: true)
                    } label: {
                        Label("下载管理", systemImage: "arrow.down.circle")
                    }
                    NavigationLink {
                        FavoritesView()
                    } label: {
                        Label("图集收藏", systemImage: "heart")
                    }
                }

                Section("设置") {
                    NavigationLink {
                        ReaderSettingsView()
                    } label: {
                        settingsRow("阅读", icon: "book",
                                    detail: "阅读模式 · 白边裁剪 · 缩放 · 进度")
                    }
                    NavigationLink {
                        SourceSettingsView()
                    } label: {
                        settingsRow("图源", icon: "square.stack.3d.up",
                                    detail: "导入 / 管理 / 校验图源规则")
                    }
                    NavigationLink {
                        DownloadFollowSettingsView()
                    } label: {
                        settingsRow("下载与追更", icon: "arrow.down.circle",
                                    detail: "下载线程 · 自动检查更新")
                    }
                    NavigationLink {
                        NetworkSettingsView()
                    } label: {
                        settingsRow("网络", icon: "wifi",
                                    detail: "DoH · UA · 搜索线程 · Web 编辑器")
                    }
                    NavigationLink {
                        BackupSettingsView()
                    } label: {
                        settingsRow("备份同步", icon: "icloud",
                                    detail: "本地备份 · WebDAV 同步")
                    }
                    NavigationLink {
                        StorageDiagSettingsView()
                    } label: {
                        settingsRow("存储与诊断", icon: "internaldrive",
                                    detail: "缓存清理 · 诊断日志")
                    }
                }

                Section {
                    NavigationLink {
                        ThemeEditorView()
                    } label: {
                        HStack(spacing: 10) {
                            Text("主题")
                            Spacer()
                            Text(ThemeStore.shared.current.name)
                                .foregroundStyle(.secondary)
                            Circle()
                                .fill(Theme.accent)
                                .frame(width: 12, height: 12)
                        }
                    }
                } header: {
                    Label("外观", systemImage: "circle.lefthalf.filled")
                } footer: {
                    Text("内置多套配色，也可以挑一张自己的图片做背景 —— 漫画阅读界面会一起跟随。")
                }

                Section {
                    Button {
                        joinQQGroup()
                    } label: {
                        HStack {
                            Label("加入 QQ 群", systemImage: "person.3.fill")
                            Spacer()
                            Text(Self.qqGroup).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Label("社区", systemImage: "bubble.left.and.bubble.right.fill")
                } footer: {
                    Text("遇到问题、想提需求、或者想分享图源，都可以进群聊。点这一行会直接打开 QQ 的加群页面。")
                }

                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        HStack {
                            Text("关于绘漫岛 / 使用说明")
                            Spacer()
                            Text(Self.version).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("版本", value: "\(Self.version) (iOS)")
                    LabeledContent("图源规则", value: "Legado 兼容格式")
                } header: {
                    Label("关于", systemImage: "info.circle")
                } footer: {
                    Text("绘漫岛只提供阅读工具，不存储任何漫画内容；所有内容均来自你导入的第三方图源规则。")
                }
            }
            .transparentScrollBackground()
            // 🔴 主题背景也铺在**设置页自己这一层** —— 与两个 tab 一致。
            //    依据：编辑器预览用同样写法能显示图，而 App 根层的写法看不到。
            .background(ThemeBackground(theme: themeStore.current))
            // ⚠️ iOS 16+ 必须显式隐藏 `Form` 的滚动背景 —— 真机是 iOS 17，
            //    SwiftUI 的 List/Form 已改用 UICollectionView，`UITableView.appearance()`
            //    那套对它们**完全失效**，不写这行主题背景会被 Form 自己的底色盖住。
            // ⚠️ 这里**只**隐藏滚动背景，**不**加背景视图：主题背景由外层（tab 根）铺。
            //    在导航栈内部的页面里放 `ignoresSafeArea` 的背景会让 push 转场残留上一页。
            .scrollContentBackgroundCompat()
            .navigationTitle("设置")
            .onAppear {
                var a = AccountStore.load()
                if a.isRegistered { AccountStore.refreshStats(into: &a) }
                acc = a
            }
            .onReceive(NotificationCenter.default.publisher(for: .hmdAccountChanged)) { _ in
                acc = AccountStore.load()
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
