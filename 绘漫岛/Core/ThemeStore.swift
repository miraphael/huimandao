import SwiftUI
import UIKit

/// ── 一套**可自定义**的主题 ──────────────────────────────────────────────────
///
/// 用户能自己造主题：挑底色 / 强调色 / 文字色，还能**塞一张自己的图**当背景
/// （喜欢的插画、纯色纹理、纸纹…），并调它的透明度与填充方式。
///
/// ## 为什么不是「只读的预设列表」
/// 需求是「设计自己想要的主题的样子」—— 预设只能选，不能造。所以主题被
/// **序列化成 JSON 存进 UserDefaults**、背景图**落盘到 Documents/theme_bg/**，
/// 于是「造一个主题」= 往列表加一条 + 存一张图，**不需要改代码**。
///
/// ## 与阅读器的关系
/// `ReaderView` 及其三种翻页模式的背景 / 文字 / 强调色都读这里，
/// 所以**漫画界面也跟着主题走** —— 这是「解析出来的漫画界面也同步主题」的落点。
///
/// ## ⚠️ 为什么 `ThemeStore` 必须是 `ObservableObject` 且用 `@Published`
/// 上一版把开关放在 `AppSettings`（普通 class）里当 `@AppStorage` 用 ——
/// **`@AppStorage` 在 class 里不会发 `objectWillChange`**，于是 `App.body`
/// 不重算、`.preferredColorScheme` 永远停在初始值，用户看到的就是
/// **「按了深色没反应」**。这里用 `@Published` 显式发通知，从根上避开这个坑。
struct ThemeConfig: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// 是否深色（决定状态栏样式、系统控件与默认文字色）
    var isDark: Bool
    /// 强调色 #RRGGBB
    var accentHex: String
    /// 背景纯色 #RRGGBB —— 没设背景图时用它；设了图则作为图的**垫底色**
    var backgroundHex: String
    /// 卡片 / 分组容器底色 #RRGGBB
    var surfaceHex: String
    /// 主文字色 #RRGGBB
    var textHex: String
    /// 背景图文件名（存在 Documents/theme_bg/ 下）；nil = 纯色背景
    var backgroundImage: String?
    /// 背景图不透明度 0…1
    var backgroundOpacity: Double
    /// 背景图填充方式：fill / fit / tile
    var backgroundFill: String
    /// 内置主题不可删除（可复制后改）
    var builtin: Bool
    /// 背景图模糊半径（pt，0 = 不模糊）—— 图太花时压一压，避免干扰文字
    var backgroundBlur: Double
    /// 背景图压暗强度 0…0.7 —— 浅色文字压不住亮图时用
    var backgroundDim: Double

    // MARK: 显式构造（手写 `init(from:)` 之后，合成的 memberwise init 会消失）

    init(id: String, name: String, isDark: Bool, accentHex: String,
         backgroundHex: String, surfaceHex: String, textHex: String,
         backgroundImage: String?, backgroundOpacity: Double,
         backgroundFill: String, builtin: Bool,
         backgroundBlur: Double = 0, backgroundDim: Double = 0) {
        self.id = id
        self.name = name
        self.isDark = isDark
        self.accentHex = accentHex
        self.backgroundHex = backgroundHex
        self.surfaceHex = surfaceHex
        self.textHex = textHex
        self.backgroundImage = backgroundImage
        self.backgroundOpacity = backgroundOpacity
        self.backgroundFill = backgroundFill
        self.builtin = builtin
        self.backgroundBlur = backgroundBlur
        self.backgroundDim = backgroundDim
    }

    /// 🔴 **手写解码**，新字段一律 `decodeIfPresent` 兜底。
    ///
    /// ⚠️ 为什么不能靠合成的 `init(from:)`：Swift 合成的解码器**不会**对
    ///    「带默认值的属性」做「缺失即用默认」—— JSON 里少一个键就直接抛
    ///    `keyNotFound`，于是**用户已存的全部主题会一次性丢失**。
    ///    以后再加字段，记得同样在这里补一行 `decodeIfPresent`。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isDark = try c.decode(Bool.self, forKey: .isDark)
        accentHex = try c.decode(String.self, forKey: .accentHex)
        backgroundHex = try c.decode(String.self, forKey: .backgroundHex)
        surfaceHex = try c.decode(String.self, forKey: .surfaceHex)
        textHex = try c.decode(String.self, forKey: .textHex)
        backgroundImage = try c.decodeIfPresent(String.self, forKey: .backgroundImage)
        backgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.9
        backgroundFill = try c.decodeIfPresent(String.self, forKey: .backgroundFill) ?? "fill"
        builtin = try c.decodeIfPresent(Bool.self, forKey: .builtin) ?? false
        backgroundBlur = try c.decodeIfPresent(Double.self, forKey: .backgroundBlur) ?? 0
        backgroundDim = try c.decodeIfPresent(Double.self, forKey: .backgroundDim) ?? 0
    }

    static func newCustom(name: String) -> ThemeConfig {
        ThemeConfig(id: "custom-\(UUID().uuidString.prefix(8))",
                    name: name.isEmpty ? "我的主题" : name,
                    isDark: false,
                    accentHex: "#FF6B9D",
                    backgroundHex: "#FDF6F0",
                    surfaceHex: "#FFFFFF",
                    textHex: "#2B2B2B",
                    backgroundImage: nil,
                    backgroundOpacity: 0.9,
                    backgroundFill: "fill",
                    builtin: false)
    }

    var accentColor: Color { Color(hex: accentHex) ?? .pink }
    var backgroundColor: Color { Color(hex: backgroundHex) ?? .white }
    var surfaceColor: Color { Color(hex: surfaceHex) ?? .white }
    var textColor: Color { Color(hex: textHex) ?? .primary }
    /// 次要文字（主文字色降透明度）
    var secondaryTextColor: Color { textColor.opacity(0.6) }

    /// **强调色上该用什么颜色的文字** —— 按强调色的相对亮度自动选黑 / 白。
    ///
    /// ⚠️ 不这么做的话，用户挑一个浅黄 / 浅青当强调色，所有「强调色底 + 白字」
    ///    的地方（图源切换栏、JS 标签、书架更新角标、圆点序号…）会**直接看不见**。
    ///    这是「完整主题系统」该有的保护，不是可选项。
    var onAccentColor: Color {
        // ⚠️ 用 **WCAG 对比度**判定，不要用「亮度 > 0.62」这种拍脑袋阈值：
        //    阈值取高了，中等亮度的强调色（浅绿 / 浅橙 / 浅青）仍被判成「用白字」，
        //    而白字压在浅底上**几乎看不见** —— 用户反馈的
        //    「切到自定义主题后，漫画台顶部的图源切换栏消失了」就是这个原因。
        //    这里直接比较「白字对比度」与「黑字对比度」，取更大的那个：
        //    任何强调色都保证可读，不依赖任何魔法阈值。
        let l = accentLuminance
        let contrastWithWhite = 1.05 / (l + 0.05)
        let contrastWithBlack = (l + 0.05) / 0.05
        return contrastWithBlack > contrastWithWhite ? Color(white: 0.10) : .white
    }

    /// 强调色的相对亮度（sRGB 近似，0…1）
    ///
    /// ⚠️ **直接解析 `accentHex`**，不要走 `UIColor(accentColor)`：
    ///    后者对动态构造的 `Color` 可能取不到分量（返回 nil），亮度于是恒为 0
    ///    → 永远被判成「用白字」→ 浅色强调色下文字直接消失。
    var accentLuminance: Double {
        let h = accentHex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return 0 }
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >> 8) & 0xFF) / 255.0
        let b = Double(v & 0xFF) / 255.0
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// 卡片色与文字色对比度是否过低 —— 编辑器里据此提示用户「这样会看不清」
    var hasLowContrast: Bool {
        guard let t = UIColor(textColor).rgbComponents,
              let s = UIColor(surfaceColor).rgbComponents else { return false }
        let lt = 0.2126 * t.r + 0.7152 * t.g + 0.0722 * t.b
        let ls = 0.2126 * s.r + 0.7152 * s.g + 0.0722 * s.b
        return abs(lt - ls) < 0.28
    }
}

// MARK: - 内置主题

extension ThemeConfig {
    static let builtins: [ThemeConfig] = [
        ThemeConfig(id: "builtin.light", name: "明亮", isDark: false,
                    accentHex: "#FF6B9D", backgroundHex: "#FFFFFF",
                    surfaceHex: "#F5F5F7", textHex: "#1C1C1E",
                    backgroundImage: nil, backgroundOpacity: 1, backgroundFill: "fill",
                    builtin: true),
        ThemeConfig(id: "builtin.dark", name: "深色", isDark: true,
                    accentHex: "#FF6B9D", backgroundHex: "#101014",
                    surfaceHex: "#1C1C22", textHex: "#F2F2F7",
                    backgroundImage: nil, backgroundOpacity: 1, backgroundFill: "fill",
                    builtin: true),
        ThemeConfig(id: "builtin.oled", name: "纯黑 OLED", isDark: true,
                    accentHex: "#4FC3F7", backgroundHex: "#000000",
                    surfaceHex: "#0E0E0E", textHex: "#EDEDED",
                    backgroundImage: nil, backgroundOpacity: 1, backgroundFill: "fill",
                    builtin: true),
        ThemeConfig(id: "builtin.eyecare", name: "护眼绿", isDark: false,
                    accentHex: "#2E7D32", backgroundHex: "#CCE8CF",
                    surfaceHex: "#E4F3E5", textHex: "#1B3A1E",
                    backgroundImage: nil, backgroundOpacity: 1, backgroundFill: "fill",
                    builtin: true),
        ThemeConfig(id: "builtin.manga", name: "黑白纸", isDark: false,
                    accentHex: "#14141A", backgroundHex: "#F3EEE1",
                    surfaceHex: "#FAF6EC", textHex: "#14141A",
                    backgroundImage: nil, backgroundOpacity: 1, backgroundFill: "fill",
                    builtin: true),
        ThemeConfig(id: "builtin.parchment", name: "羊皮纸", isDark: false,
                    accentHex: "#8D6E63", backgroundHex: "#F5ECD9",
                    surfaceHex: "#FBF4E6", textHex: "#4A3B2A",
                    backgroundImage: nil, backgroundOpacity: 1, backgroundFill: "fill",
                    builtin: true),
        ThemeConfig(id: "builtin.ink", name: "水墨", isDark: true,
                    accentHex: "#C9A227", backgroundHex: "#14171A",
                    surfaceHex: "#1E2328", textHex: "#E8E3D9",
                    backgroundImage: nil, backgroundOpacity: 1, backgroundFill: "fill",
                    builtin: true),
    ]
}

// MARK: - 存储

/// 主题仓库：列表 + 当前选中 + 背景图文件管理。
///
/// ⚠️ 所有 `@Published` 的写入都**必须回到主线程** —— 否则 SwiftUI 会报
///    「Publishing changes from background threads」并在真机上偶发不刷新。
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    /// 全部主题（内置 + 用户自建）
    @Published private(set) var themes: [ThemeConfig] = []
    /// 当前主题 id
    @Published var currentID: String = "builtin.light" {
        didSet {
            persist()
            // 换主题要立刻把 UIKit 的标签栏一起改掉（SwiftUI 管不到它）
            applySystemAppearance()
        }
    }

    private let listKey = "hmd.themes.v1"
    private let currentKey = "hmd.theme.current.v1"
    private let bgDirName = "theme_bg"

    private init() {
        load()
        // 🔎 黑白纸预览（2026-10-18）：首次跑到这版时**强制切到「黑白纸」**，
        //    好让用户直接看到新设计（否则他手机上存的是旧主题，根本不会变）。
        //    只切一次 —— 之后用户自己在设置里改主题不会被覆盖。
        let k = "hmd.bw.preview.v1"
        if !UserDefaults.standard.bool(forKey: k) {
            UserDefaults.standard.set(true, forKey: k)
            if themes.contains(where: { $0.id == "builtin.manga" }) {
                currentID = "builtin.manga"
            }
        }
    }

    var current: ThemeConfig {
        themes.first { $0.id == currentID } ?? ThemeConfig.builtins[0]
    }

    /// 当前主题是否为深色
    var isDark: Bool { current.isDark }

    // MARK: - 系统栏外观（标签栏）

    /// 把当前主题应用到 UIKit 的**标签栏**。
    ///
    /// ## 为什么需要它
    /// SwiftUI 的 `List` / `Form` 只管**内容区**；底部标签栏是 UIKit 的，
    /// 它只跟随系统深浅色 —— 于是「换了主题，页面背景变了，底栏却还是原来那样」。
    /// 标签栏是三个主页面**始终可见**的元素，把它接上主题，主题才算真的落到界面上。
    ///
    /// ## ⚠️ 为什么**不动导航栏**
    /// 阅读器是**恒定深色**（用户明确要求主题不作用到漫画界面）。一旦把导航栏标题色
    /// 绑到主题，浅色主题下阅读器的标题会变成深色、压在黑色画面上直接看不见。
    /// 导航栏交给 `preferredColorScheme` 处理 —— 深浅色它自己会配对好。
    ///
    /// ## ⚠️ 为什么要遍历窗口
    /// `appearance()` 代理只对**之后新建**的栏生效。不遍历当前窗口里**已存在**的
    /// 标签栏，用户切完主题当前这一页不会立刻变（要杀进程重开才生效）。
    func applySystemAppearance() {
        let t = current
        let app = UITabBarAppearance()
        app.configureWithOpaqueBackground()
        app.backgroundColor = UIColor(t.surfaceColor)
        app.shadowColor = UIColor(t.textColor).withAlphaComponent(0.12)

        let item = UITabBarItemAppearance()
        item.normal.iconColor = UIColor(t.secondaryTextColor)
        item.normal.titleTextAttributes = [.foregroundColor: UIColor(t.secondaryTextColor)]
        item.selected.iconColor = UIColor(t.accentColor)
        item.selected.titleTextAttributes = [.foregroundColor: UIColor(t.accentColor)]
        app.stackedLayoutAppearance = item
        app.inlineLayoutAppearance = item
        app.compactInlineLayoutAppearance = item

        let proxy = UITabBar.appearance()
        proxy.standardAppearance = app
        proxy.scrollEdgeAppearance = app

        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for win in ws.windows {
                Self.applyTabAppearance(app, in: win)
            }
        }
    }

    private static func applyTabAppearance(_ app: UITabBarAppearance, in view: UIView) {
        if let bar = view as? UITabBar {
            bar.standardAppearance = app
            bar.scrollEdgeAppearance = app
        }
        for sub in view.subviews { applyTabAppearance(app, in: sub) }
    }

    // MARK: 增删改

    func add(_ theme: ThemeConfig) {
        themes.append(theme)
        persist()
        // 🔎 插桩：确认「新建主题」真的进了列表
        DiagLog.event("theme", "add", "新增 id=\(theme.id) name=\(theme.name) 共 \(themes.count) 个")
    }

    func update(_ theme: ThemeConfig) {
        guard let i = themes.firstIndex(where: { $0.id == theme.id }) else {
            // 🔎 插桩：**找不到 id** 是「保存了但没反应」的头号嫌疑
            DiagLog.event("theme", "update", "❌ 找不到 id=\(theme.id)（列表里只有 \(themes.map { $0.id }.joined(separator: ","))）")
            return
        }
        themes[i] = theme
        persist()
        // 🔴 改的正好是**当前主题**时必须重刷系统外观 —— `currentID` 的 didSet 只在
        //    值**变化**时触发，而这里赋的是同一个 id（值没变）→ 不触发 →
        //    标签栏/状态栏保持旧配色，「编辑当前主题后要杀进程才生效」。
        //    （由智能体「主题」发现）
        if currentID == theme.id { applySystemAppearance() }
        DiagLog.event("theme", "update",
                      "更新 id=\(theme.id) bg=\(theme.backgroundHex) img=\(theme.backgroundImage ?? "无")")
    }

    /// 删除（内置不可删）；若删的是当前主题则回落到明亮
    func remove(id: String) {
        guard let t = themes.first(where: { $0.id == id }), !t.builtin else { return }
        themes.removeAll { $0.id == id }
        if currentID == id { currentID = "builtin.light" }
        if let img = t.backgroundImage { deleteBackground(named: img) }
        persist()
    }

    /// 复制一份再改（内置主题「另存为我的主题」）
    func duplicate(_ t: ThemeConfig) -> ThemeConfig {
        var copy = t
        copy.id = "custom-\(UUID().uuidString.prefix(8))"
        copy.name = t.name + " 副本"
        copy.builtin = false
        // 图片共享同一份文件：引用计数太复杂，直接复制文件更省心
        if let img = t.backgroundImage, let data = backgroundData(named: img) {
            let newName = "\(copy.id).img"
            _ = saveBackground(data: data, name: newName)
            copy.backgroundImage = newName
        }
        add(copy)
        return copy
    }

    // MARK: 背景图文件

    var backgroundDir: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bgDirName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func backgroundURL(named name: String) -> URL {
        backgroundDir.appendingPathComponent(name)
    }

    /// 已经报过「背景图文件不存在」的文件名 —— 避免反复刷屏。
    /// 只在主线程（SwiftUI `.onAppear`）访问，故用普通静态 Set。
    static var didReportMissingBG = Set<String>()

    /// 报告一次「背景图文件缺失」（同名的只报一次）
    static func reportMissingBackground(_ name: String, themeName: String) {
        guard !didReportMissingBG.contains(name) else { return }
        didReportMissingBG.insert(name)
        DiagLog.event("theme", "bg",
                      "⚠️ 主题「\(themeName)」的背景图文件不存在：\(name)（主题设置还在，图没了）")
    }

    func backgroundData(named name: String) -> Data? {
        try? Data(contentsOf: backgroundURL(named: name))
    }

    /// 已解码的背景图缓存。
    ///
    /// ⚠️ **必须缓存**：`ThemeBackground` 是铺在最底层的视图，任何一次 body 重算
    ///    （滚动、切页、动画）都会走到这里。不缓存的话每帧都要
    ///    `Data(contentsOf:)` + `UIImage(data:)` 解码一张可能几 MB 的图 —— 滚动直接掉帧。
    private var imageCache: [String: UIImage] = [:]

    func backgroundImage(named name: String) -> UIImage? {
        if let cached = imageCache[name] { return cached }
        guard let data = backgroundData(named: name),
              let img = UIImage(data: data) else { return nil }
        imageCache[name] = img
        return img
    }

    /// 清掉某张图的缓存（换图 / 删图后必须调，否则界面还是旧图）
    private func invalidateCache(_ name: String) {
        imageCache[name] = nil
    }

    /// 保存背景图（压成 JPEG 控制体积 —— 主题图动辄几 MB，PNG 会撑爆 Documents）
    @discardableResult
    func saveBackground(data: Data, name: String) -> Bool {
        var payload = data
        if let img = UIImage(data: data) {
            let maxSide: CGFloat = 2000
            let scale = min(1, maxSide / max(img.size.width, img.size.height))
            if scale < 1 || data.count > 3_000_000 {
                let newSize = CGSize(width: img.size.width * scale, height: img.size.height * scale)
                let fmt = UIGraphicsImageRendererFormat.default()
                fmt.scale = 1
                let resized = UIGraphicsImageRenderer(size: newSize, format: fmt).image { _ in
                    img.draw(in: CGRect(origin: .zero, size: newSize))
                }
                if let jpeg = resized.jpegData(compressionQuality: 0.85) { payload = jpeg }
            }
        }
        do {
            try payload.write(to: backgroundURL(named: name), options: .atomic)
            invalidateCache(name)   // 同名覆盖时必须失效，否则界面还是旧图
            DiagLog.event("theme", "img", "✅ 背景图已存 \(name)（\(payload.count) 字节）")
            return true
        } catch {
            // 🔎 插桩：写盘失败是「选了图没反应」的直接原因，把 errno 记下来
            DiagLog.event("theme", "img",
                          "❌ 背景图写盘失败 \(name)：\(error.localizedDescription)")
            return false
        }
    }

    func deleteBackground(named name: String) {
        try? FileManager.default.removeItem(at: backgroundURL(named: name))
        invalidateCache(name)
    }

    /// 导入一张用户选中的图片，返回文件名
    func importBackground(from data: Data) -> String? {
        let name = "bg-\(UUID().uuidString.prefix(8)).jpg"
        return saveBackground(data: data, name: name) ? name : nil
    }

    // MARK: 持久化

    private func persist() {
        let enc = JSONEncoder()
        // 🔴 **双写**：UserDefaults + Documents/themes.json。
        //    为什么需要镜像文件：主题以前**只存 UserDefaults**，而重装 App 后
        //    UserDefaults 会被清掉（真机实测 2026-10-14：`读入 7 个（自建 1 个）`
        //    → 重装后 `读入 6 个（自建 0 个）`，用户自建主题直接消失，
        //    背景图文件还在 Documents 里却没人引用）。
        //    Documents 目录随容器保留，镜像一份就能扛住重装。
        if let d = try? enc.encode(themes) {
            UserDefaults.standard.set(d, forKey: listKey)
            try? d.write(to: themesMirrorURL, options: .atomic)
        } else {
            // 🔎 插桩：编码失败会让主题**写不进 UserDefaults**（界面当场生效、重启就没了）
            DiagLog.event("theme", "persist", "❌ 主题 JSON 编码失败，共 \(themes.count) 个")
        }
        UserDefaults.standard.set(currentID, forKey: currentKey)
        DiagLog.event("theme", "persist", "已存 \(themes.count) 个主题，current=\(currentID)")
    }

    /// 主题镜像文件（抗重装，见 `persist` 的说明）
    private var themesMirrorURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("themes.json")
    }

    private func load() {
        var fromDefaults: [ThemeConfig] = []
        if let d = UserDefaults.standard.data(forKey: listKey),
           let decoded = try? JSONDecoder().decode([ThemeConfig].self, from: d) {
            fromDefaults = decoded
        }
        var fromMirror: [ThemeConfig] = []
        if let d = try? Data(contentsOf: themesMirrorURL),
           let decoded = try? JSONDecoder().decode([ThemeConfig].self, from: d) {
            fromMirror = decoded
        }
        // 🔴 两份取**自建主题更多**的那份 —— UserDefaults 被清后镜像文件还在，
        //    反过来镜像写失败时 UserDefaults 也能兜底。（见 `persist` 的说明）
        let a = fromDefaults.filter { !$0.builtin }
        let b = fromMirror.filter { !$0.builtin }
        let saved = b.count > a.count ? b : a
        if b.count > a.count {
            DiagLog.event("theme", "load", "⚠️ UserDefaults 里的自建主题(\(a.count)) 少于镜像文件(\(b.count))，已用镜像恢复")
        }
        // 内置主题**始终以代码定义为准**（改了配色，老用户也能看到），
        // 并**固定排在最前**；用户自建的主题按原顺序接在后面。
        var merged = ThemeConfig.builtins
        merged.append(contentsOf: saved)
        themes = merged

        if let c = UserDefaults.standard.string(forKey: currentKey),
           merged.contains(where: { $0.id == c }) {
            currentID = c
        } else {
            currentID = merged[0].id
        }
        // 🔎 插桩：启动时到底读到了几个主题、当前是哪个 —— 主题「重启就没了」一看便知
        DiagLog.event("theme", "load",
                      "读入 \(merged.count) 个（自建 \(merged.count - ThemeConfig.builtins.count) 个，默认 \(a.count) 镜像 \(b.count)），current=\(currentID)")
        // 两份不一致时把更全的那份回写，保持同步
        if b.count > a.count { persist() }
        // 🔎 插桩：启动时把「当前主题有没有背景图名 + 文件在不在」打出来 ——
        //    用户报「放了图片后无法显示」时，这一条直接区分三种情况：
        //      ① `img=无`            → 主题**根本没记下**图名（保存/装填丢了）
        //      ② `img=bg-x.jpg 文件=缺` → 名字记了但文件没了（容器被清）
        //      ③ `img=bg-x.jpg 文件=有` → 数据都对，**问题在渲染层**，继续往下查
        if let cur = themes.first(where: { $0.id == currentID }) {
            let has = cur.backgroundImage != nil
            var exists = false
            if let n = cur.backgroundImage { exists = FileManager.default.fileExists(atPath: backgroundDir.appendingPathComponent(n).path) }
            DiagLog.event("theme", "verify",
                          "启动：当前主题「\(cur.name)」 id=\(cur.id) img=\(cur.backgroundImage ?? "无")"
                          + (has ? " 文件=\(exists ? "有" : "缺")" : ""))
        }
    }
}

// MARK: - 颜色工具

extension UIColor {
    /// 取 sRGB 分量（0…1）；色彩空间取不到时返回 nil。
    /// 用于算**相对亮度** —— 决定强调色上该配黑字还是白字。
    var rgbComponents: (r: Double, g: Double, b: Double)? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return (Double(r), Double(g), Double(b))
    }
}

extension Color {
    /// `#RRGGBB` / `#RGB` / `RRGGBB` → Color；解析失败返回 nil
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255,
                  opacity: 1)
    }

    /// → `#RRGGBB`
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X",
                      Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }
}

// MARK: - 背景视图

/// 主题背景：纯色 + 可选的用户图片（带透明度与填充方式）。
///
/// ⚠️ 图片用 `Image(uiImage:)` 直接渲染 —— 主题图是**本地文件**，
///    不需要也不应该走网络图片管线（Nuke）。
// ─────────────────────────────────────────────────────────────────────────────
// 🔴 主题背景 —— 2026-10-14 **重新设计**（第 19 次修复，前 18 次全是在旧骨架上打补丁）
//
// 旧的实现挂在 SwiftUI 视图层级里（appearance 代理 / .background() / ZStack），
// 只要链条上任何一层不透明（iOS 16+ 的 List 就是 UICollectionView，自带白底），
// 整张图就消失，而且**线上查不出是哪一层**。
//
// 新设计 = **两条互相独立的通路**，任一条通都能显示：
//   通路 A（SwiftUI 内）：`ThemeBackground` 用 `GeometryReader` 拿**真实像素尺寸**，
//      再显式 `.frame(width:height:)` —— 绝不依赖「ZStack 按子视图收缩」那种隐式布局。
//   通路 B（窗口层）：`ThemeWallpaper` 直接往 `UIWindow` 里插一个 `UIImageView`
//      （index 0，最底层）。它在**所有 SwiftUI 内容之下**，SwiftUI 谁也盖不住它。
//
// 两条通路同时生效；任一条被上层不透明视图盖住，另一条仍然可见。
// ─────────────────────────────────────────────────────────────────────────────

/// 通路 A：SwiftUI 内的主题背景。
struct ThemeBackground: View {
    let theme: ThemeConfig
    /// 覆盖背景色（阅读器需要「纯色背景」时用，不显示图）
    var solidOnly: Bool = false
    /// ⚠️ **已废弃，保留仅为兼容旧调用点** —— 新实现走 `GeometryReader` +
    ///    `ignoresSafeArea()`，天然铺满，不再需要调用方区分「根层/页内」。
    var fillSafeArea: Bool = true

    var body: some View {
        // GeometryReader：拿的是**父级给的真实像素尺寸**，不是「子视图需要的大
        // 小」。旧实现缺了这一层 —— ZStack 会按子视图收缩，`scaledToFit` 的图
        // 在 `.background(...)` 场景下被压成 0 高，视觉上就是「完全不显示」。
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let h = max(geo.size.height, 1)
            ZStack {
                theme.backgroundColor
                if !solidOnly, let name = theme.backgroundImage,
                   let img = ThemeStore.shared.backgroundImage(named: name) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()                 // 铺满；用户想要 fit 时见 fillView
                        .frame(width: w, height: h)     // 🔴 显式定尺，杜绝 0 高
                        .clipped()
                        .opacity(theme.backgroundOpacity)
                        .blur(radius: theme.backgroundBlur)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: w, height: h)                 // 🔴 根节点也显式定尺
            // 🔎 插桩：打印 GeometryReader 拿到的**真实尺寸**。
            //    `geo=(0.0, 0.0)` = 根层布局塌了（背景不可能显示）；
            //    正常应该是全屏尺寸。配合 `[app] version` 指纹一起看。
            .onAppear {
                DiagLog.event("theme", "render",
                              "ThemeBackground 布局：geo=\(Int(w))×\(Int(h)) 主题「\(theme.name)」"
                              + " img=\(theme.backgroundImage ?? "无")")
            }
        }
        .ignoresSafeArea()
    }
}

/// 通路 B：**窗口层**主题壁纸（UIKit）。
///
/// 为什么需要它：SwiftUI 侧只要有一层不透明视图（List / Form / NavigationStack
/// 在某些 iOS 版本下的系统底色），整张图就被盖住，而且从 SwiftUI 内部查不出来。
/// 直接往 `UIWindow` 的 index 0 插一个 `UIImageView`，它在**所有 SwiftUI 内容
/// 之下**，是最后一道保险。
enum ThemeWallpaper {
    private static let tag = 0x5A7E_BA01

    /// 把当前主题的背景图铺到所有窗口的最底层。没有自定义图时移除旧壁纸。
    static func apply(_ theme: ThemeConfig) {
        DispatchQueue.main.async {
            // 🔴 遍历**全部** window，不只是 `.first` —— `.first` 不保证是 key/main window，
            //    多 window（外接屏 / 键盘 window）场景下会插错地方。
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            var hit = 0
            for scene in scenes {
                for window in scene.windows {
                    // 🔴 **最关键的一步**：光 `insertSubview(at: 0)` 不够。
                    //    `window.rootViewController.view` 本身就是 window 的子视图，
                    //    index 0 只是把它插到**这个宿主视图下面** —— 宿主（UIHostingController
                    //    的 view，即整个 SwiftUI 树的根）只要不是全透明，图就被盖死。
                    //    （真机 19 轮排查 + 两个智能体一致结论，2026-10-14）
                    window.backgroundColor = .clear
                    if let rv = window.rootViewController?.view {
                        rv.backgroundColor = .clear
                        rv.isOpaque = false
                    }

                    // 先清掉旧的，避免主题切换后残留上一张
                    window.viewWithTag(tag)?.removeFromSuperview()

                    guard let name = theme.backgroundImage,
                          let img = ThemeStore.shared.backgroundImage(named: name) else {
                        // 没有自定义图 → 用主题纯色当窗口底色
                        window.backgroundColor = UIColor(theme.backgroundColor)
                        continue
                    }

                    let iv = UIImageView(image: img)
                    iv.tag = tag
                    iv.frame = window.bounds
                    iv.contentMode = .scaleAspectFill
                    iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    iv.alpha = CGFloat(theme.backgroundOpacity)
                    iv.isUserInteractionEnabled = false
                    // index 0 = 最底层，SwiftUI 内容都在它上面
                    window.insertSubview(iv, at: 0)
                    hit += 1
                }
            }
            DiagLog.event("theme", "wall",
                          "窗口层壁纸：theme=\(theme.name) img=\(theme.backgroundImage ?? "无") 铺到 \(hit) 个窗口")
        }
    }
}

/// 🔴 **把整条宿主链清成透明** —— 窗口层壁纸能不能看见，全看这一步。
///
/// 背景：`ThemeWallpaper` 把图插在 `UIWindow` 的 index 0，但 `UIHostingController.view`
/// （SwiftUI 整棵树的根）本身也是 window 的子视图，它只要不是全透明，图就被盖住。
///
/// ⚠️⚠️ **踩过的坑（2026-10-14，真机「新建主题直接卡死」）**：
///    在 `didMoveToWindow` 里改 `window.backgroundColor` / `rootViewController.view`
///    的属性，会**再次触发布局** → `didMoveToWindow` 又被调用 → **死循环卡死**。
///    所以这里改成：只在**首次**上屏时执行一次，之后立刻置位，绝不在回调里改 window。
struct WindowTransparency: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { Probe() }
    func updateUIView(_ v: UIView, context: Context) {}

    final class Probe: UIView {
        /// 全局只清一次 —— 防止重入导致死循环
        private static var done = false
        private var fired = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard !fired, let w = window else { return }
            fired = true
            guard !Probe.done else { return }
            Probe.done = true
            // ⚠️ 异步执行，避免在布局回调里同步改 window 造成重入
            DispatchQueue.main.async {
                w.backgroundColor = .clear
                w.rootViewController?.view.backgroundColor = .clear
                w.rootViewController?.view.isOpaque = false
            }
        }
    }
}

// MARK: - 页面级主题背景

extension View {
    /// 给一页铺上**主题背景**（含用户自定义图），并让页内 `List` / `Form` 的
    /// 滚动背景透明 —— 不透明的话 List 自带的底色会把主题背景整个盖住。
    ///
    /// ## ⚠️ 为什么必须走 `scrollContentBackground(.hidden)`
    /// 真机是 **iOS 17**，而 iOS 16 起 SwiftUI 的 `List` / `Form` 改用
    /// `UICollectionView` 实现 —— `AppDelegate` 里那套
    /// `UITableView.appearance().backgroundColor = .clear` 对 `List` **完全失效**。
    /// 这就是「换了主题，设置页 / 漫画台看着没变」的真正原因。
    /// 部署目标仍是 iOS 15（用不了这个 API），所以按版本分流：
    /// 老系统继续吃 appearance 代理那套。
    @ViewBuilder
    func themedPageBackground(_ theme: ThemeConfig) -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
                // ⚠️ `fillSafeArea: false` —— 见 `ThemeBackground.fillSafeArea` 的说明：
                //    在导航栈内部用 `ignoresSafeArea` 会让上一页快照残留（转场错位）。
                .background(ThemeBackground(theme: theme, fillSafeArea: false))
        } else {
            self.background(ThemeBackground(theme: theme, fillSafeArea: false))
        }
    }

    /// 只把滚动背景变透明（**不带**任何背景视图）—— 给导航栈**内部**的页面用。
    ///
    /// 主题背景由更外层（`HMDApp` 根层 / 各 tab 根）负责铺，页面自身只要透明就能露出来。
    /// 这样页面里**不会**出现 `ignoresSafeArea` 的背景视图 → 导航转场不会残留上一页快照。
    @ViewBuilder
    func scrollContentBackgroundCompat() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    /// 🔴 让 `List` / `Form` **本体**完全透明，露出 App 根层铺的主题背景（含自定义图）。
    ///
    /// 为什么必须三层一起上（两个智能体 + 真机 18 轮排查的结论）：
    ///   ① `scrollContentBackground(.hidden)` —— iOS 16+ **官方** API，清掉容器背景。
    ///      ⚠️ 它只对**所绑定的那个视图**生效，**不会往子树里传** ——
    ///      这就是「挂在 tab 根 / NavigationStack 外面 → 里面两页还是一片白」的原因。
    ///   ② `listRowBackground(Color.clear)` —— iOS 16 起 List 的 cell 是
    ///      `UICollectionViewListCell`，行自己有底色，容器透明了行还是白的。
    ///   ③ `background(Color.clear)` —— 兜底，防止某些容器（Form 的 header/footer）
    ///      残留系统 grouped 背景。
    ///
    /// ⚠️ `UITableView/UICollectionView.appearance().backgroundColor = .clear`
    ///    在 iOS 16+ **不可靠**（SwiftUI 会在视图创建后显式覆盖它），
    ///    只能当老系统兜底，不能当主力。
    ///
    /// `listRowBackground` / `scrollContentBackground` 在 iOS 15 就有，
    /// 但部署目标是 16，这里不额外做版本分流。
    func transparentScrollBackground() -> some View {
        self
            .scrollContentBackgroundCompat()
            .listRowBackground(Color.clear)
            .background(Color.clear)
    }

    /// 让当前页的**导航栏**使用深色配色（标题 / 按钮变浅色）。
    /// 给「恒定深色」的阅读器用。
    ///
    /// ⚠️ 为什么不用 `.preferredColorScheme(.dark)`：那个会改**整个 window** 的
    ///    深浅色，进 / 出阅读器时全 App 会闪一下颜色 —— 正是我们要修的
    ///    「打开 / 离开闪一下」。`toolbarColorScheme` 只作用于导航栏，无此副作用。
    @ViewBuilder
    func darkToolbarScheme() -> some View {
        if #available(iOS 16.0, *) {
            self.toolbarColorScheme(.dark, for: .navigationBar)
        } else {
            self
        }
    }
}
