import SwiftUI
import Combine

/// 全局设置（对应 ComicSettingActivity / AppSettingActivity 的 jq.* 键位）
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private init() {
        loadThreadCounts()
        Self.migrateWebDAVPasswordToKeychain()
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
    @AppStorage("readMode") var readMode = 1            // 1滚动 2翻页 3日漫 4双页 5双页日漫
    /// 翻页 / 双页模式的显示方式。
    ///   · `true`（默认）= **适应屏幕**：整页完整显示在屏内，不裁切、不留黑边
    ///   · `false`       = **铺满屏幕**：按屏幕比例放大后裁掉溢出的部分（画面更满）
    /// 滚动模式不受它影响（滚动模式恒为「按宽度铺满 + 纵向滚动」）。
    @AppStorage("fitScreen") var fitScreen = true
    @AppStorage("whiteEdgeCut") var whiteEdgeCut = true
    @AppStorage("keepScreenOn") var keepScreenOn = false
    @AppStorage("eyeCare") var eyeCare = false
    @AppStorage("brightness") var brightness = 0.5
    @AppStorage("doubleTapZoom") var doubleTapZoom = true
    @AppStorage("tapZones") var tapZones = "next,menu,prev"   // 三分区动作

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

    // 源核重探补丁包：存储远程包地址，进「重探补丁包」页面可一键更新
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
