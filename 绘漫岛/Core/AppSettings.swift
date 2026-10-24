import SwiftUI
import Combine

/// 全局设置（对应 ComicSettingActivity / AppSettingActivity 的 jq.* 键位）
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private init() {
        loadThreadCounts()
        Self.migrateWebDAVPasswordToKeychain()
        Self.migrateReaderNoDarkVeil()
        Self.migrateScrollOnlyMode()
    }

    /// 迁移：**只保留滚动模式**（2026-10-24 用户要求）。
    ///
    /// 翻页 / 日漫 / 双页 / 双页日漫 的界面入口已删除；
    /// 这里把老用户的 `readMode` 强制归到 1（滚动），避免停在已隐藏的模式上。
    private static func migrateScrollOnlyMode() {
        let flag = "reader.scrollOnly.v1"
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: flag) else { return }
        ud.set(true, forKey: flag)
        if ud.integer(forKey: "readMode") != 1 {
            ud.set(1, forKey: "readMode")
            DiagLog.event("reader", "mode", "只保留滚动模式：readMode 归 1")
        }
    }


    /// 迁移：去掉阅读器那层「黑幕」（2026-10-23 用户明确要求）。
    ///
    /// 用户的设备上是「护眼 25% 黑 + 亮度 0.25（再叠约 15% 黑）」，
    /// 两层叠加 ≈44% 的暗色 —— 看起来就是一层黑幕。
    /// 这里**一次性**把护眼关掉、亮度归位到 0.5（= 原样），
    /// 两个功能本身保留，用户想用可以随时再打开。
    private static func migrateReaderNoDarkVeil() {
        let flag = "reader.noDarkVeil.v1"
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: flag) else { return }
        ud.set(true, forKey: flag)
        ud.set(false, forKey: "eyeCare")
        ud.set(0.5, forKey: "brightness")
        DiagLog.event("reader", "veil", "已关闭护眼 + 亮度归位 0.5（去除黑色蒙层）")
    }


    /// 迁移：历史版本把 WebDAV 密码**明文**存在 `UserDefaults("webdavPass")`。
    /// 搬进 Keychain，并把 UserDefaults 里那份**删掉**。
    ///
    /// ⚠️ **只搬不删等于没修** —— 明文仍然留在 plist 里，安全收益为零。
    ///    所以无论搬没搬，只要 UserDefaults 里还有这个键就一律清除。
    private static func migrateWebDAVPasswordToKeychain() {
        let key = "webdavPass"
        let legacy = UserDefaults.standard.string(forKey: key)
        // ① Keychain 还是空的、而 UserDefaults 有值 → 搬过去
        if KeychainStore.get(key) == nil, let v = legacy, !v.isEmpty {
            KeychainStore.set(v, forKey: key)
        }
        // ② 抹掉 UserDefaults 里的明文
        if legacy != nil {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @AppStorage("showRecommend") var showRecommend = true

    /// 章节智能排序（2026-10-18，默认开）
    ///
    /// 不少站的章节是**倒序**（最新话在最前）。原样显示会让 ① 列表反着排；
    /// ② 阅读器「下一章」往回走。开启后按章节名里的**话数升序**重排，
    /// 与站点顺序无关（见 `ChapterSorter`）。认不出话数的源会自动放弃排序。
    @AppStorage("chapterAutoSort") var chapterAutoSort = true
    @AppStorage("showFind") var showFind = false        // 原版发现默认隐藏

    // ── 安全防护（加固）──────────────────────────────────────────────────
    /// 加固总开关（反调试/反注入/越狱检测/完整性校验）。
    /// 默认开；用户可在「设置 → 安全」里关掉 —— 排查故障时不该被自己的防护挡住。
    /// ⚠️ 关闭只影响**检测与降级**，不影响任何正常功能。
    @AppStorage("securityEnabled") var securityEnabled = true

    // ── 🔴 2026-10-14 清理掉的「僵尸键」（声明了但**全项目零消费点**）───────────
    //    `showHistory` / `showLocal` / `darkMode` / `autoDarkMode` /
    //    `volumeKeyPaging` / `pagingReverse` / `originalImage` / `autoBackup` /
    //    `autoRefreshComic`
    //
    //    这些键从来没有（或曾经有、后来删了）任何读取方：
    //      · 深色外观实际由 `ThemeStore` + `theme.followSystem` 控制，与 `darkMode` 无关
    //      · 「自动追更」真正的开关是「下载与追更」页的 `hmd_follow_auto`
    //      · 音量键翻页 / 反转翻页 / 原图加载 **从未实现**
    //    留着它们会让后续开发误以为「有开关可用」，也会让排查者白找消费点。
    //    （由智能体「界面」「设置」分别发现）

    // 阅读器
    /// 阅读模式：**现在只支持 1 = 滚动（条漫）**。
    /// 2/3/4/5（翻页/日漫/双页）已停用并隐藏（2026-10-24 用户要求）。
    @AppStorage("readMode") var readMode = 1
    @AppStorage("whiteEdgeCut") var whiteEdgeCut = true
    @AppStorage("keepScreenOn") var keepScreenOn = false
    @AppStorage("eyeCare") var eyeCare = false
    @AppStorage("brightness") var brightness = 0.5
    @AppStorage("doubleTapZoom") var doubleTapZoom = true


    // 并发
    @AppStorage("searchThreads") var searchThreads = 32
    @AppStorage("downloadThreads") var downloadThreads = 2
    @AppStorage("refreshThreads") var refreshThreads = 2

    // 网络
    @AppStorage("webPort") var webPort = 1122
    @AppStorage("customUA") var customUA = ""
    @AppStorage("dohEnabled") var dohEnabled = false

    // 备份
    @AppStorage("webdavUrl") var webdavUrl = ""
    @AppStorage("webdavUser") var webdavUser = ""
    /// ⚠️ **密码走 Keychain，不走 `@AppStorage`**。
    ///    `@AppStorage` 底层是 `UserDefaults`（明文 plist），越狱设备 / 备份文件
    ///    里能直接读到；`SecureField` 只管「不回显」，不管存储加密。
    ///    换成 `@KeychainSetting` 后 `$webdavPass` 绑定照常可用（见包装器说明）。
    @KeychainSetting("webdavPass") var webdavPass: String

    // 源核重探补丁包：存储远程包地址，进「重探补丁包」页面可一键更新。
    // ⚠️ UI 入口已在 `SourceSettingsView` 隐藏（用户要求），但**代码保留**：
    //    `Engine/ReprobePack.swift` / `UI/ReprobePackView.swift` 仍依赖这个字段，
    //    删掉会编译不过。要恢复功能，把 SourceSettingsView 里注释掉的两段放回去即可。
    @AppStorage("reprobePackUrl") var reprobePackUrl = ""

    func loadThreadCounts() {
        searchThreads = min(max(searchThreads, 1), 64)
        downloadThreads = min(max(downloadThreads, 1), 10)
    }

    var httpUA: String {
        // 对齐安卓默认：Windows 桌面 Chrome（多数源规则按桌面页结构编写）
        customUA.isEmpty ? "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/62.0.3202.94 Safari/537.36" : customUA
    }
}

enum Theme {
    /// 当前主题的强调色 —— **跟随 `ThemeStore`**，所以换主题后所有用它着色的地方
    /// （`RootTabView` 的 tint、关于页的序号圆点、阅读器高亮…）会一起变。
    ///
    /// ⚠️ 曾经是 `static let accent = Color.pink` 这种写死的常量 —— 那样主题
    ///    一改就散架（有的地方跟着变、有的地方还是粉的）。改成计算属性后，
    ///    全仓库只剩这一个「强调色」入口。
    static var accent: Color { ThemeStore.shared.current.accentColor }

    /// **强调色之上**该用的文字色（按亮度自动黑 / 白）。
    /// 任何「accent 底 + 文字」的地方都用它 —— 否则用户挑个浅色强调色，
    /// 白字会直接看不见。
    static var onAccent: Color { ThemeStore.shared.current.onAccentColor }

    /// 主文字色 / 卡片色 / 背景色 —— 子页与阅读器统一从这里取，别再写死 `.white` / `Color.black`。
    static var text: Color { ThemeStore.shared.current.textColor }
    static var surface: Color { ThemeStore.shared.current.surfaceColor }
    static var background: Color { ThemeStore.shared.current.backgroundColor }
    /// 当前主题是否为深色
    static var isDark: Bool { ThemeStore.shared.current.isDark }
}
