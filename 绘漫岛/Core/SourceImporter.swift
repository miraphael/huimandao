import Foundation
import UIKit

extension Notification.Name {
    /// 从外部打开文件导入后的结果（`String`）—— App 顶层用它弹提示。
    static let hmdImportResult = Notification.Name("hmdImportResult")
    /// 图源列表发生变化（导入 / 删除 / 启停）—— 列表页据此**立即刷新**，
    /// 不用杀掉 App 重开（用户反馈「导入后必须重启才看得到新源」）。
    static let hmdSourcesChanged = Notification.Name("hmdSourcesChanged")
}

/// 「从文件导入图源」的统一入口。
///
/// 为什么要单独一个类型：用户在**微信 / QQ / 文件 App** 里拿到 `.json` 后，
/// 通常是点「用其他应用打开 → 绘漫岛」。这条链路**不走** `fileImporter`，
/// 而是由系统通过 `onOpenURL` 把 URL 交给 App —— 以前 App 完全没处理
/// （`Info.plist` 也没注册文档类型），所以表现为「JSON 文件导入不进去」。
enum SourceImporter {

    /// 读取安全作用域文件。
    ///
    /// 用 `NSFileCoordinator` 是为了**触发 iCloud 下载**：用户从「文件」里选一个
    /// 尚未下载的 iCloud 文件时，直接 `Data(contentsOf:)` 会失败（读不到文件），
    /// 而协调读会先把文件拉下来。这也是「同一个人有时能导入、有时不能」的常见原因。
    static func read(_ url: URL) -> Data? {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }

        var data: Data?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            data = try? Data(contentsOf: u)
        }
        if data == nil { data = try? Data(contentsOf: url) }
        return data
    }

    /// 导入并落库，返回条数（0 = 失败）。结果通过 `hmdImportResult` 通知界面。
    @discardableResult
    static func importFile(_ url: URL) -> Int {
        guard let data = read(url) else {
            post("❌ 读不到文件（iCloud 未下载 / 无权限）")
            DiagLog.event("import", "openurl", "读取失败 \(url.lastPathComponent)")
            return 0
        }
        guard let text = SourceCodec.text(from: data), !text.isEmpty else {
            post("❌ 文件是空的（\(data.count) 字节）")
            return 0
        }
        let list = SourceCodec.importJson(text)
        guard !list.isEmpty else {
            let why = SourceCodec.diagnosis(text)
            post("❌ " + why)
            DiagLog.event("import", "openurl", "解析失败：\(why)")
            return 0
        }
        ComicRepository.shared.saveSources(list)
        NotificationCenter.default.post(name: .hmdSourcesChanged, object: nil)
        post("✅ 已导入 \(list.count) 条图源")
        DiagLog.event("import", "openurl", "\(url.lastPathComponent) → \(list.count) 条")
        return list.count
    }

    private static func post(_ msg: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .hmdImportResult, object: msg)
        }
    }
}
