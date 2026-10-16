import Foundation
import CryptoKit

/// 本地账号 —— 阅读档案 + 跨设备同步标识。
///
/// ⚠️ 诚实说明：本项目**没有自建服务端**，所以这里的「账号」不是联网注册的
/// 云端账号，而是一个**本地档案**：
///   · 昵称 + 头像 emoji + 一个设备无关的用户 ID
///   · 与「阅读统计」绑定（已读书数 / 章节数 / 总时长 / 连续天数）
///   · 通过 WebDAV 做跨设备同步（设置里已配置的那个 WebDAV 就是后端）
///
/// 这样既满足「设置里要有账号功能」，又不虚构一个并不存在的服务器。
/// 若将来接入了真实后端，只要把 `AccountStore` 的 persist 换成网络请求即可。
struct UserAccount: Codable, Equatable {
    var userID: String = ""
    var nickname: String = "漫画读者"
    var avatar: String = "🐱"
    var createdAt: Int64 = 0

    /// 阅读统计（由 ComicRepository 汇总后写入）
    var booksRead: Int = 0
    var chaptersRead: Int = 0
    var totalMinutes: Int = 0
    var streakDays: Int = 0
    var lastReadDay: String = ""

    var isRegistered: Bool { !userID.isEmpty }
}

/// 账号持久化（UserDefaults；同步走 WebDAV 备份通道）
enum AccountStore {
    private static let key = "hmd_account_v1"

    static func load() -> UserAccount {
        guard let d = UserDefaults.standard.data(forKey: key),
              let a = try? JSONDecoder().decode(UserAccount.self, from: d) else {
            return UserAccount()
        }
        return a
    }

    static func save(_ a: UserAccount) {
        if let d = try? JSONEncoder().encode(a) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }

    /// 创建本地账号：生成一个稳定的设备无关 ID（时间戳 + 随机盐的 SHA256 前 16 位）
    static func register(nickname: String, avatar: String) -> UserAccount {
        var a = UserAccount()
        let seed = "\(Date().timeIntervalSince1970)-\(UUID().uuidString)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        a.userID = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
        a.nickname = nickname.isEmpty ? "漫画读者" : nickname
        a.avatar = avatar
        a.createdAt = Int64(Date().timeIntervalSince1970 * 1000)
        save(a)
        return a
    }

    static func logout() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// 从书架/历史/章节表汇总统计，并更新连续天数。
    static func refreshStats(into a: inout UserAccount) {
        a.booksRead = ComicRepository.shared.shelfCount()
        a.chaptersRead = ComicRepository.shared.readChapterCount()
        a.totalMinutes = ComicRepository.shared.totalReadMinutes()

        // 连续天数：今天读过就把 lastReadDay 设为今天，昨天读过则 +1，否则归 1
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: Date())
        let yesterday = fmt.string(from: Date().addingTimeInterval(-86400))
        if a.lastReadDay != today {
            if a.lastReadDay == yesterday { a.streakDays += 1 } else { a.streakDays = 1 }
            a.lastReadDay = today
        }
        save(a)
    }
}
