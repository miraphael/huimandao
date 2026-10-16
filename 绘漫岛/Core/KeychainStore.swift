import Foundation
import Security
import SwiftUI

/// ──────────────────────────────────────────────────────────────────────────
/// 极简 Keychain 封装 —— 只做「字符串读写 / 删除」。
///
/// ## 为什么需要它
/// `@AppStorage` 底层是 `UserDefaults`，而 `UserDefaults` 是**明文 plist**：
/// 越狱设备、iTunes/Finder 备份文件、`Documents` 目录里都能直接读到。
/// `SecureField` 只负责「输入时不回显」，**不负责存储加密** ——
/// 把 WebDAV 密码放进 `@AppStorage` 是典型的「看起来安全、实际明文落盘」。
///
/// 敏感值（密码 / token / Cookie）必须走 Keychain。
/// ──────────────────────────────────────────────────────────────────────────
enum KeychainStore {

    /// 统一 service 名（用 bundle id 派生，避免与其他 App 撞车）
    private static let service = "app.jujube3424.yew7522.settings"

    /// 读一个字符串；不存在返回 nil。
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 写一个字符串（存在则更新，不存在则新增）。
    @discardableResult
    static func set(_ value: String, forKey key: String) -> Bool {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        // ① 先试更新
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(base as CFDictionary, update as CFDictionary) == errSecSuccess {
            return true
        }
        // ② 不存在 → 新增。`kSecAttrAccessibleWhenUnlocked`：
        //    锁屏时读不到（后台同步拿不到密码也不会崩），解锁后正常。
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func remove(_ key: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        return SecItemDelete(q as CFDictionary) == errSecSuccess
    }
}

/// ──────────────────────────────────────────────────────────────────────────
/// Keychain 支撑的字符串设置 —— `@AppStorage` 的**敏感值替代品**。
///
/// 用法与 `@AppStorage` 基本一致（含 `$value` 绑定）：
/// ```swift
/// @KeychainSetting("webdavPass") var webdavPass: String
/// ```
///
/// ⚠️ 与 `@AppStorage` 的差异：本包装器**不参与 SwiftUI 的观察**
///    （没有 `objectWillChange` 触发）。对 `SecureField` 这类「用户输入 → 写回」
///    的绑定没有影响（输入框自己维护编辑态），但**不要**用它驱动需要自动刷新的 UI。
/// ──────────────────────────────────────────────────────────────────────────
@propertyWrapper
struct KeychainSetting {
    private let key: String
    private let fallback: String

    init(_ key: String, default fallback: String = "") {
        self.key = key
        self.fallback = fallback
    }

    var wrappedValue: String {
        get { KeychainStore.get(key) ?? fallback }
        set { KeychainStore.set(newValue, forKey: key) }
    }

    var projectedValue: Binding<String> {
        Binding(get: { KeychainStore.get(key) ?? fallback },
                set: { KeychainStore.set($0, forKey: key) })
    }
}
