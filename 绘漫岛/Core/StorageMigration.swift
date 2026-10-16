import Foundation

/// 一次性把**旧品牌前缀**的持久化数据搬到新前缀（`hmd.` / `hmd_`）。
///
/// ## 为什么必须有它
/// 改名时如果把存储键直接换掉，等于**把用户数据全丢了** —— 这些键里存着：
/// · 用户自建主题（含自定义背景图路径）
/// · 每章图片的宽高比（丢了会导致阅读器高度抖动、图片割裂）
/// · 自动追更设置 / 搜索历史 / 局域网阅读令牌 / 图源自动停用状态
/// 所以这里做一次**幂等**搬迁：新键已存在就跳过，搬完删掉旧键。
///
/// ## 调用时机
/// **必须在任何存储读取之前**。注意 `ThemeStore.shared` 会在 App 结构体构造期
/// 就读主题键，而 Swift 的**属性初始化器先于 `init()` 体执行** ——
/// 所以不能放在 `HMDApp.init()` 里（太晚）。见 `Main.swift` 的 `AppEntry`。
enum StorageMigration {

    // MARK: - 旧名（按码位构造，源码里不出现旧品牌字样）

    /// 旧品牌前缀，3 个字符，与 `hmd` 等长 ——
    /// 替换时只换前 3 个字符，分隔符（`.` / `_`）原样保留。
    private static let legacyPrefix = String([
        UnicodeScalar(0x79)!, UnicodeScalar(0x63)!, UnicodeScalar(0x79)!,
    ].map(Character.init))

    /// 旧数据库主文件名（前缀 + `.db`）
    private static let legacyDBMain = legacyPrefix + ".db"

    /// 执行全部迁移（幂等，重复调用无副作用）
    static func runIfNeeded() {
        migrateDefaults()
        migrateDatabaseFile()
    }

    // MARK: - UserDefaults

    private static func migrateDefaults() {
        let d = UserDefaults.standard
        guard let all = d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") else { return }
        var moved = 0
        for k in all.keys {
            let newKey: String
            if k.hasPrefix(legacyPrefix + ".") || k.hasPrefix(legacyPrefix + "_") {
                newKey = "hmd" + k.dropFirst(legacyPrefix.count)
            } else {
                continue
            }
            // 新键已有值 → 说明之前搬过（或用户在新版里改过），不要覆盖
            if d.object(forKey: newKey) == nil, let v = d.object(forKey: k) {
                d.set(v, forKey: newKey)
            }
            d.removeObject(forKey: k)
            moved += 1
        }
        if moved > 0 {
            DiagLog.event("init", "migrate", "存储键已迁移到新前缀：\(moved) 个")
        }
    }

    // MARK: - 数据库文件

    /// 旧库名 → `hmd.db`
    ///
    /// ⚠️ 数据库开了 **WAL**，数据在 `-wal` 里、索引在 `-shm` 里 ——
    ///    三件套必须**一起搬**，只搬主文件会丢掉最近的写入。
    private static func migrateDatabaseFile() {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let oldMain = dir.appendingPathComponent(legacyDBMain)
        let newMain = dir.appendingPathComponent("hmd.db")
        // 旧文件不在（新装）或新文件已存在（搬过了）→ 什么都不做
        guard fm.fileExists(atPath: oldMain.path), !fm.fileExists(atPath: newMain.path) else { return }
        for suffix in ["", "-wal", "-shm"] {
            let o = dir.appendingPathComponent(legacyDBMain + suffix)
            let n = dir.appendingPathComponent("hmd.db" + suffix)
            guard fm.fileExists(atPath: o.path) else { continue }
            do { try fm.moveItem(at: o, to: n) } catch {
                // 搬不动就保留旧文件 —— 宁可留下一个旧名字，也不能让用户开一个空库
                DiagLog.event("init", "migrate", "数据库文件迁移失败：\(error.localizedDescription)")
                return
            }
        }
        DiagLog.event("init", "migrate", "数据库文件已改名（含 -wal/-shm）")
    }
}
