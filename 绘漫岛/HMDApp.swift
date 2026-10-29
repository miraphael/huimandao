import SwiftUI

// ⚠️ 这里**不能**写 `@main` —— 入口是 `Main.swift` 里的 `AppEntry`，
//    它要先跑 `StorageMigration`（存储迁移必须早于任何 UserDefaults 读取）。
//    两个 `@main` 会编译报错。
struct HMDApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// 🔴 主题仓库必须在这里以 `@StateObject` **观察** —— 这正是「按了深色没反应」的根因：
    ///    旧写法读的是 `AppSettings.shared.darkMode`，而 `AppSettings` 是普通 class、
    ///    里面的 `@AppStorage` **不会发 `objectWillChange`** → `App.body` 不重算 →
    ///    `.preferredColorScheme` 永远停在启动时的值。用户看到的就是「开关动了，界面不变」。
    ///    `ThemeStore` 用 `@Published` 显式发通知，`@StateObject` 订阅它，问题从根上消失。
    @StateObject private var themeStore = ThemeStore.shared

    /// 跟随系统深浅色 —— 与主题页里那个开关**同一个键**，
    /// 所以在主题页一拨，这里就会重算 `preferredColorScheme`。
    @AppStorage("theme.followSystem") private var followSystem = false

    /// 从外部（微信 / QQ / 文件 App）用绘漫岛打开 JSON 后的结果提示。
    @State private var importMsg: String?

    var body: some Scene {
        WindowGroup {
            // 🔴 主题背景必须放在 **ZStack 的最底层**，不能挂在 TabView 上用 `.background()`。
            //
            //    为什么：`RootTabView` 是个 `TabView`（底层 `UITabBarController`），
            //    它自己的 view 会把 `.background()` 画在它后面的东西**整个盖住**。
            //    真机实测（2026-10-14）：日志显示 `ThemeBackground 求值 … 取到=是`
            //   （背景图明明加载成功了），但用户始终看不到 —— 前后改了 4 轮都没用，
            //    就是因为改的都是「背景内部」，而它在**被 TabView 盖住**之前就已经输了。
            //
            //    ZStack 第一个子视图在最底层，TabView 画在它上面，中间没有任何
            //    系统不透明层 —— 这是 SwiftUI 里唯一可靠的铺法。
            ZStack {
                // 最底层：主题背景（含用户自定义图），铺满 + 延伸进安全区
                ThemeBackground(theme: themeStore.current, fillSafeArea: true)
                    .zIndex(0)

                AppShellView()
                    .environmentObject(AppSettings.shared)
                    .environmentObject(themeStore)
                    .tint(Theme.accent)
                    // nil = 跟随系统；否则用主题自带的深 / 浅色
                    .preferredColorScheme(followSystem ? nil
                                                      : (themeStore.current.isDark ? .dark : .light))
                    // 每个 tab 内部各自把 List / Form 的滚动背景设成透明
                    // （iOS 16+ 必须走 `scrollContentBackground(.hidden)`，
                    //  `UITableView.appearance()` 对 List 已失效 —— 见 `themedPageBackground`）
                    .scrollContentBackgroundCompat()
                    .zIndex(1)
            }
            .onOpenURL { url in
                // 🔴 「微信/QQ/文件 App → 用绘漫岛打开 JSON」走的是这条链路，
                //    不是 `fileImporter`。以前没接 → 用户点了没反应，
                //    看起来就是「JSON 文件导入不进去」。
                if url.isFileURL {
                    SourceImporter.importFile(url)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .hmdImportResult)) { note in
                importMsg = note.object as? String
            }
            .alert("图源导入",
                   isPresented: Binding(get: { importMsg != nil },
                                        set: { if !$0 { importMsg = nil } })) {
                Button("好") { importMsg = nil }
            } message: {
                Text(importMsg ?? "")
            }
            // ⚠️ **窗口层壁纸（ThemeWallpaper / WindowTransparency）已移除**（2026-10-14）
            //    原因：① 每 tab 各自铺背景已经能正常显示图，窗口层是多余的；
            //          ② 它会往 UIWindow 里插/删子视图，**在新建主题（弹 sheet）时卡死**
            //             —— 真机反馈「新建主题会卡着动不了只能重开」。
            //    教训：能在一个层级解决的事，不要为了「保险」再叠一层 UIKit hack，
            //          多出来的副作用比收益大得多。
            .onAppear {
                // 🔎 **版本指纹**：用来确认手机上跑的到底是哪一版。
                //    真机排查时踩过坑 —— 日志里出现了早已删除的插桩，说明跑的是旧包。
                //    指纹里带上真实的版本号 + 构建号，和设置页显示的对得上，
                //    这样「手机上跑的是哪一版」永远能一句话说清。
                let shortVer = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
                let buildVer = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
                DiagLog.event("app", "version",
                              "构建指纹 build-202-instant-switch · App 版本 \(shortVer) (\(buildVer))")

                // 🔴 一次性数据补丁：给内置图源补**正文图规则**。
                //    真因：图源 JSON 写的是 `ruleContentList`，模型里没这个字段 →
                //    解码时被静默丢弃 → 引擎只能扫 `<img>` → JS 生成图的站白屏。
                //    只补空字段，用户自己配过规则的不动；跑一次就置 flag。
                SourceContentPatch.applyIfNeeded()

                // 🔎 纯逻辑自检（2026-10-28）：后台跑一组断言，结果写 `[selftest]`。
                //    本项目还没有单元测试，两天内连续栽在 `{{page}}` 编码、
                //    `ruleContentList` 字段名、`Referer: -` 字面量这三类**纯函数错误**上。
                //    这一步零成本（不加 target、不动 CI），但能保证「改坏了日志立刻看得见」。
                Task.detached(priority: .utility) { SelfCheck.run() }
            }
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // ⚠️ 图片管线必须**最先**建立：Nuke 默认会 lazily 建一个共享管线，
        // 一旦有任何图片先加载过，再替换全局管线就会丢掉已建立的缓存。
        // 故这里是 didFinishLaunching 的第一件事（在任何网络/DB/UI 之前）。
        HMDImagePipeline.setup()

        // 让所有 List / Form 的背景透明，露出 `HMDApp` 铺的主题背景（含自定义图）。
        // ⚠️ 这两行只对 **iOS 15** 有效（那时 List 还是 UITableView 实现）。
        //    真机是 iOS 17 —— 那里必须用 `themedPageBackground` 里的
        //    `.scrollContentBackground(.hidden)`，appearance 代理对 List 已失效。
        //    两套都留着：老系统吃这套，新系统吃那套。
        UITableView.appearance().backgroundColor = .clear
        UITableViewCell.appearance().backgroundColor = .clear

        // 🔴 **必须补 UICollectionView 这套** —— iOS 16 起 SwiftUI 的 `List`/`Form`
        //    改用 `UICollectionView` 实现，`UITableView.appearance()` 对它**完全无效**。
        //    真机实测（2026-10-14）：主题背景图确实加载成功（日志 `取到=是`），
        //    但「书架 / 漫画台」两页一片白、把根层 ZStack 的主题背景**整个盖住**；
        //    只有「设置」页（Form）透了出来。差别就在这两页用的是 `List`。
        //
        //    ⚠️ `scrollContentBackground(.hidden)` 只对**当前这个修饰符所绑的视图**生效，
        //       不会往子树里的 List/Form 传 —— 所以只靠它是盖不住所有页面的，
        //       必须在这里做全局兜底。
        if #available(iOS 16.0, *) {
            UICollectionView.appearance().backgroundColor = .clear
            // List/Form 的 cell 背景（否则 cell 自己是不透明白）
            UITableViewCell.appearance().backgroundColor = .clear
        }

        // 标签栏跟随主题（导航栏故意不动 —— 阅读器恒定深色，见 `applySystemAppearance`）
        ThemeStore.shared.applySystemAppearance()

        Database.shared.migrate()
        // ⚠️ JS 类源必须在 DB 迁移之后、任何搜索/详情之前装载 ——
        //    注册表是**纯内存**的，不装载的话重启后导入的 JS 源全部"消失"
        //    （表现为「导入成功了，但搜不到、打不开」）。
        //    这里只读库、不做网络，开销与源数量成正比（通常个位数），可忽略。
        _ = SourceProviderRegistry.shared.loadFromStore()
        CookieStore.load()
        CrashCatcher.install()
        // 加固：反调试 / 反注入 / 越狱检测 / 完整性校验。
        // ⚠️ 内部走后台队列 + 只降级不闪退，不阻塞启动看门狗。
        Zx7Guard.install()
        importBuiltinSources()
        // 🔴 重新解密历史图源 —— **必须在版本门控之外、每次启动都跑**。
        //    以前它被塞在 `importBuiltinSources()` 里，而那个函数开头就是
        //        guard builtinImportedVersion != builtinImportVersion else { return }
        //    版本号不变就整体返回 → **解密失败的源永远修不过来**，密文被当成规则用 →
        //    解析全空、章节名丢失、章节数不全。
        //    真机实测（2026-10-14）：知音漫客的规则是 `:_H006_` 加密的，
        //    漫画台显示 533 章，进详情只剩 249 章且**全都没有章节名**。
        //    这个函数幂等（只处理 `hasEncryptedRules()` 的源），正常情况下命中 0 条。
        repairStoredRules()
        importBuiltinJSSources()
        return true
    }

    /// 内置图源 / 解密逻辑的版本号。
    /// ⚠️ 每次改动 SourceDecrypt 的解析能力后必须递增，否则已装机用户既不会重新导入、
    /// 也不会重新解密，改动在他们机器上等于没生效。
    ///
    /// ── v6（2026-10-11）────────────────────────────────────────────────
    /// ⚠️ **新增数据库列后也必须递增**，这是真机验证才发现的坑：
    ///   本轮给 `COMIC_SOURCE_BEAN` 加了 `HEADER` 列（承载 Legado 的 `header`
    ///   字段，很多源靠它带 Referer/UA）。`ALTER TABLE` 只会给**已有行**填 NULL，
    ///   而内置导入有版本门控 —— 版本没变就不重导，
    ///   于是**已装机用户那 309 条源的 header 永远是 NULL**（实测确认：
    ///   `SELECT COUNT(*) ... WHERE HEADER<>''` 返回 0，而内置 JSON 里有 16 条带 header）。
    ///   结论：**「加列」和「回填数据」是两件事**，加列之后必须同时 bump 版本号。
    /// ── v7（2026-10-14）────────────────────────────────────────────────
    /// 🔴 **解密逻辑的修复必须 bump**，否则已装机用户永远不会重新解密。
    ///   真机实测（2026-10-14）：知音漫客（规则是 `:_H006_` 加密的）在漫画台显示
    ///   533 章，进详情只剩 249 章且**全都没有章节名** —— 因为 `repairStoredRules()`
    ///   被塞在 `importBuiltinSources()` 里，而后者有版本门控，版本不变就整体 return，
    ///   解密失败的源**永远修不过来**，密文被当成规则用。
    ///   影响面：**309 条内置源里 195 条（63%）的规则是加密的**（H006 166 条 / R002 185 条 …）。
    ///   结论：① `repairStoredRules()` 改成每次启动都跑；② 这里 bump 逼一次全量重导。
    /// ── v8（2026-10-14）────────────────────────────────────────────────
    /// 🔴 **App 不再内置图源**（用户要求：软件不能内置图源）。
    ///   资源包里的 `builtin_sources.json`（309 条）/ `builtin_js_sources.json`（26 条）
    ///   / `builtin_health.json` 已全部移除，备份在仓库根 `source_backup/`。
    ///   bump 到 8 的作用：让**老用户**跑一次 `purgeLegacyBuiltinSources()`，
    ///   把当年自动导入到数据库里的那几百条清掉 —— 否则「不内置」只对新装用户成立。
    ///   ⚠️ 清理只按备份清单里的 URL 匹配，用户自建/自己导入的源**不会**被误删。
    private static let builtinImportVersion = "8"

    /// 首次启动导入内置图源合集（yck2026 仓库 535 源）；版本变化时重新导入并修复历史图源
    ///
    /// ⚠️ 必须在后台线程执行：535 源里有 669 个加密字段，其中 604 个是 R 版 RSA
    /// （共 1965 次 1024-bit 模幂），实测要 30+ 秒。若同步跑在
    /// `didFinishLaunchingWithOptions` 里，会耗尽启动看门狗的 20 秒配额
    /// （`0x8BADF00D scene-create watchdog transgression`）被直接 SIGKILL —— 表现就是**白屏**。
    private func importBuiltinSources() {
        guard UserDefaults.standard.string(forKey: "builtinImportedVersion") != Self.builtinImportVersion else { return }
        let version = Self.builtinImportVersion

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var imported = false
            if let url = Bundle.main.url(forResource: "builtin_sources", withExtension: "json"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                imported = Self.importInBatches(text)
            } else {
                // ── 🔴 App 已不再内置图源（2026-10-14 起）───────────────────
                //   资源包里的 `builtin_sources.json` / `builtin_js_sources.json` /
                //   `builtin_health.json` 都已移除（备份在仓库根的 `source_backup/`）。
                //   但**老用户数据库里还留着当年自动导入的那几百条** —— 这里做一次性清理，
                //   否则「App 不内置图源」只对新装用户成立，老用户看起来还是内置的。
                //   ⚠️ 只清一次（版本门控），之后用户自己导入/新建的源不受影响。
                let removed = Self.purgeLegacyBuiltinSources()
                DiagLog.event("init", "purge",
                              "App 已不再内置图源，清理历史导入的 \(removed) 条内置源（用户自建的保留）")
            }
            // 修复历史遗留：旧版本解密失败时会把 `:_版本_密文` 原样存库
            self?.repairStoredRules()

            // 无论有没有可导入的 JSON，都要把版本号落下 —— 否则清理逻辑每次启动都跑
            UserDefaults.standard.set(version, forKey: "builtinImportedVersion")
            Self.notifySourcesChanged()
        }
    }

    /// 一次性清理「历史版本自动导入的内置源」。
    ///
    /// 判据：**只删那些能从备份清单里对上的 URL**（备份清单以代码常量形式内联，
    /// 不占资源包体积，也不算「内置图源」）。这样用户自己导入/新建的源不会被误删。
    /// 若备份清单为空（理论上不会），则退化为「不删」而不是「全删」——
    /// 宁可少删也不能误删用户数据。
    private static func purgeLegacyBuiltinSources() -> Int {
        guard let url = Bundle.main.url(forResource: "builtin_purge_list", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return 0
        }
        let urls = Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty })
        guard !urls.isEmpty else { return 0 }
        var removed = 0
        for s in ComicRepository.shared.allSources() where urls.contains(s.bookSourceUrl) {
            ComicRepository.shared.deleteSources(urls: [s.bookSourceUrl])
            removed += 1
        }
        return removed
    }

    /// 必须在主线程发通知 —— 视图用 `.onReceive` 直接改 @State，
    /// 从后台线程发会在 SwiftUI 里触发「Publishing changes from background threads」问题。
    private static func notifySourcesChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .hmdSourcesChanged, object: nil)
        }
    }

    /// 解析 → 登记候选 → 逐条解密并落库，每 25 条通知一次 UI，避免用户盯着空列表
    private static func importInBatches(_ text: String) -> Bool {
        let list = SourceCodec.parseJson(text)
        guard !list.isEmpty else { return false }
        // 先登记候选 URL，共享密文（镜像域名）才解得开
        SourceDecrypt.registerCandidates(SourceCodec.collectHTCipherPairs(list))

        // ⚠️ 已存在的源要**保留用户自己调过的启用/禁用状态**。
        //    内置库会随版本更新（736 源），若无脑覆盖，用户手动停用过的源会被重新打开 ——
        //    这是「更新一次，之前调好的又乱了」的经典坑。
        //    （与 `SourceUpdater.updateAll` 同一套策略）
        var existingEnable: [String: Bool] = [:]
        for e in ComicRepository.shared.allSources() {
            existingEnable[e.bookSourceUrl] = e.enable ?? true
        }

        for (i, raw) in list.enumerated() {
            var s = raw
            s.decryptRules(sourceUrl: s.bookSourceUrl)
            if let keep = existingEnable[s.bookSourceUrl] { s.enable = keep }
            ComicRepository.shared.saveSource(s)
            if i % 25 == 24 { notifySourcesChanged() }
        }
        // ── 清理旧版遗留的死源 ──────────────────────────────────────────
        // 内置库从 736 裁到 309（删掉「站点不可达 / 列表规则失效」的 427 个）。
        // 但**只缩小内置库不会删掉设备上已导入的旧源** —— 它们还留在数据库里。
        // 这里做安全清理，删除条件**同时满足**：
        //   ① enable == false（已禁用 —— 死源本来就被标为禁用）
        //   ② URL 不在新内置库里
        // ⚠️ 为什么不直接「删掉所有不在新库里的」：那样会误删**用户手动添加**的源。
        //    加上「已禁用」这个条件后，用户手动加的源（默认启用）不受影响。
        let newURLs = Set(list.map { $0.bookSourceUrl })
        let stale = ComicRepository.shared.allSources()
            .filter { ($0.enable ?? true) == false && !newURLs.contains($0.bookSourceUrl) }
            .map { $0.bookSourceUrl }
        if !stale.isEmpty {
            ComicRepository.shared.deleteSources(urls: stale)
            print("[Init] 已清理旧版遗留的死源 \(stale.count) 条")
        }

        print("[Init] 已导入内置图源 \(list.count) 条")
        return true
    }

    /// 把库里仍处于密文形态的图源重新解密并写回。
    /// 已解密的规则不含 `:_` 前缀，auto() 会原样返回 —— 因此本操作幂等，可安全重复执行。
    private func repairStoredRules() {
        let pending = ComicRepository.shared.allSources().filter { $0.hasEncryptedRules() }
        guard !pending.isEmpty else { return }
        // 先登记候选 URL，共享密文（镜像域名）才解得开
        // ⚠️ 候选有两个来源，都要登记：
        //   ① 库里的密文源本身（镜像域名共享同一段密文）
        //   ② 内置 JSON —— 因为 `importBuiltinSources` 被版本门控挡住时，
        //      内置那份候选根本没登记过，而 H/T 版本密钥是「从 URL 派生」的，
        //      没有候选 URL 就解不开。
        SourceDecrypt.registerCandidates(SourceCodec.collectHTCipherPairs(pending))
        if let url = Bundle.main.url(forResource: "builtin_sources", withExtension: "json"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            let builtin = SourceCodec.parseJson(text)
            SourceDecrypt.registerCandidates(SourceCodec.collectHTCipherPairs(builtin))
        }
        var fixed = 0
        for var s in pending {
            s.decryptRules(sourceUrl: s.bookSourceUrl)
            // 只统计「真的解开了」的；仍为密文的留待下次（可能后续注册到新候选）
            if !s.hasEncryptedRules() { fixed += 1 }
            ComicRepository.shared.saveSource(s)
        }
        DiagLog.event("init", "repair",
                      "重新解密 \(pending.count) 条密文图源，成功 \(fixed) 条"
                      + (fixed < pending.count ? "，仍有 \(pending.count - fixed) 条解不开（缺候选 URL 或密钥）" : ""))
        print("[Init] 已重新解密 \(pending.count) 条历史图源（成功 \(fixed)）")
    }

    // MARK: - 内置 JS 类源

    /// 内置 JS 源合集 / 转换逻辑的版本号。
    /// ⚠️ 与 `builtinImportVersion` 同理：改了 `engine/legado_to_js.py` 的转换规则后
    ///    必须递增这个值，否则已装机用户不会重新导入，改动等于没生效。
    ///
    /// v1 → v2（2026-10-11）：修好「单 `|` 也算 OR」与「`XPath:` 前缀识别」两个漏检后，
    ///    产物从 38 条降到 30 条 —— 被剔掉的 8 个禁漫天堂系源此前带着
    ///    `XPath://*[` 这种被 `@` 切碎的残片（设备上表现为「能加载、搜不到封面」）。
    ///    **不递增这个值，已装机用户就永远收不到这次修复。**
    ///
    /// v2 → v3（2026-10-11 二次）：修好转换器**丢弃中间选择步**这个致命缺陷 ——
    ///    `class.book-list@tag.li` 原先只生成 `.book-list`（在**容器**上取 href →
    ///    恒空），正确产物是 `.book-list li`；`@Header:` 请求后缀也不再被当成属性名。
    ///    产物 30 → 26 条。**这 26 条的解析行为全部改变**，必须重导。
    private static let builtinJSImportVersion = "3"

    /// 首次启动导入**内置 JS 类源**。
    ///
    /// ## 为什么需要它
    /// JS 引擎（`JSProvider` / `JSEvaluator` / `JSSourceWKExecutor`）早就编进 App 了，
    /// 但 `JS_SOURCE` 表默认是**空的** —— 内置的 309 个源是 Legado 格式，
    /// 走 `COMIC_SOURCE_BEAN` 通道，**不会**变成 JS 源。
    /// 结果：用户装完新包，感觉「JS 引擎根本没生效」。
    ///
    /// 这里在首次启动（或版本升级）时，把 `builtin_js_sources.json`
    /// （由 `engine/legado_to_js.py` 从内置源自动转换而来）批量写入 `JS_SOURCE` 表。
    ///
    /// ## 约束
    ///   • **不覆盖用户改动**：已存在的源保留其启用状态（与 `importInBatches` 同策略）。
    ///   • **单个源非法不影响其他**：`save` 前逐个 `validate()`，坏的跳过并计数。
    ///   • **开销可控**：30 条 × 每个 ~3.5 KB，纯本地解码+写库，无需后台看门狗兜底，
    ///     但仍放后台线程，避免与启动期的其他 IO 抢主线程。
    ///   • **会清理过时内置源**：见下方 `packIds` 处说明（产物收缩时必须删旧记录）。
    private func importBuiltinJSSources() {
        guard UserDefaults.standard.string(forKey: "builtinJSImportedVersion")
                != Self.builtinJSImportVersion else { return }
        let version = Self.builtinJSImportVersion

        DispatchQueue.global(qos: .userInitiated).async {
            guard let url = Bundle.main.url(forResource: "builtin_js_sources",
                                            withExtension: "json"),
                  let data = try? Data(contentsOf: url) else {
                print("[Init] ⚠️ 未找到内置 JS 源合集（builtin_js_sources.json）—— 跳过")
                return
            }
            let decoder = JSONDecoder()
            guard let pack = try? decoder.decode(BuiltinJSPack.self, from: data) else {
                print("[Init] ⚠️ 内置 JS 源合集解码失败 —— 跳过")
                return
            }

            // 保留用户已调过的启用状态（源被停用过就别再打开）
            var existing: [String: Bool] = [:]
            for item in JSSourceStore.list() { existing[item.id] = item.enabled }

            // ⚠️ **不要把用户主动删掉的内置源复活**。
            //    这里与「首次导入」不同：这是**版本升级时的重导**。用户在上一版里
            //    手动删过某个内置 JS 源（`JSSourceStore.remove`），如果升级时无脑
            //    `save`，那条源就会「删了又回来」—— 用户会认为 App 存不住状态。
            //    JSON 规则源早就用 `TombstoneStore` 解决了这个问题（见 §8.2 阶段 B），
            //    JS 源此前漏了，这里补齐。
            let tombstones = Set(
                TombstoneStore.all()
                    .filter { $0.kind == TombstoneStore.Kind.jssource.rawValue }
                    .map(\.id))

            var saved = 0, skipped = 0, revivedSkipped = 0
            for m in pack.sources {
                guard (try? m.validate()) != nil else { skipped += 1; continue }
                if tombstones.contains(m.id) { revivedSkipped += 1; continue }
                let enabled = existing[m.id] ?? true
                if JSSourceStore.save(m, enabled: enabled) { saved += 1 }
            }

            // ⚠️ **清理本次合集已不再包含的内置源**。
            //    只删「由内置导入产生、且 id 属于本合集命名空间(`legado.` 前缀)」的记录：
            //    产物收缩时（v1 的 38 → v2 的 30），若不删，旧的坏源会一直留在库里，
            //    用户仍能看到并启用它 —— 修了等于没修。
            //    绝不碰用户自己导入的源（它们的 id 不会是 `legado.` 开头）。
            let packIds = Set(pack.sources.map { $0.id })
            var removed = 0
            for item in JSSourceStore.list() {
                guard item.id.hasPrefix("legado.") else { continue }
                guard !packIds.contains(item.id) else { continue }
                // 这是 App 自己的版本收缩，不是用户的删除意愿 → 不记墓碑
                JSSourceStore.removeWithoutTombstone(id: item.id)
                removed += 1
            }

            // 注册表是纯内存的，写完库要重新装载，否则本次启动仍然搜不到。
            let loaded = SourceProviderRegistry.shared.loadFromStore()
            print("[Init] 内置 JS 源：写入 \(saved) 条（跳过非法 \(skipped)，"
                  + "尊重已删墓碑 \(revivedSkipped)），清理过时 \(removed) 条，注册 \(loaded) 条")

            if saved > 0 || removed > 0 {
                UserDefaults.standard.set(version, forKey: "builtinJSImportedVersion")
            }
            if saved > 0 || removed > 0 { Self.notifySourcesChanged() }
        }
    }
}

/// `builtin_js_sources.json` 的顶层结构（与 `engine/legado_to_js.py` 产出对齐）。
private struct BuiltinJSPack: Decodable {
    var version: Int
    var sources: [JSSourceManifest]
}

extension Notification.Name {
    /// 图源集合发生变化（后台导入/修复过程中及完成后发出），UI 据此刷新
    static let hmdSourcesChanged = Notification.Name("hmdSourcesChanged")
    /// 书架数据变化（追更完成 / 标为已读）—— 书架页监听它刷新
    static let hmdShelfChanged = Notification.Name("hmdShelfChanged")
}

/// 主框架已迁至 RootTabView.swift（漫画 / 漫画台 / 设置 三大标签）
