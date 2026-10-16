import SwiftUI

/// App 入口。
///
/// ## 🔴 为什么不用 `@main struct HMDApp: App` 直接当入口
/// Swift 的**属性初始化器先于 `init()` 体执行**。而 `HMDApp` 的属性里有
/// `ThemeStore.shared` —— 它一构造就要读 UserDefaults 里的主题键。
/// 把存储迁移放在 `HMDApp.init()` 里**太晚了**：主题已经按旧键读成空的了，
/// 用户会发现「自建主题全没了」。
///
/// 所以这里用自定义 `main()`：**先迁移，再把控制权交给 SwiftUI**。
/// 这是整个 App 里最早能执行代码的位置。
@main
enum AppEntry {
    static func main() {
        StorageMigration.runIfNeeded()
        HMDApp.main()
    }
}
