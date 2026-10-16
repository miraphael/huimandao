import Foundation

/// ──────────────────────────────────────────────────────────────────────────
/// 源核重探「补丁包」的解析与应用
///
/// 补丁包 = `engine/reprobe.py` 产出的 JSON 数组，每项是一个标准 `ComicSource`
/// （外加 `_probe` 元数据：改了哪些字段、新旧自测质量、证据条数）。
///
/// ## 为什么要有这层，而不是直接「导入图源」
/// 直接导入也能用，但用户看不到**要改什么**。这里把「差异」摊开：
///   改了哪几个字段、旧规则质量多少、新的多少、证据有几条章节几张图 ——
/// 用户勾选后再应用。规则覆盖是**破坏性操作**，必须先看得见。
///
/// ## 合并原则（与 `SourceUpdater` 一致）
///   · 按 `bookSourceUrl` 对齐；已存在 → 只更新规则字段
///   · **保留用户自己的启用/禁用状态**（否则手动关掉的源会被重新打开）
///   · **保留已有的 ruleFindUrl**（发现页栏目是人工配置，源核不知道，不能覆盖）
///   · 不存在 → 新增
/// ---------------------------------------------------------------------------
enum ReprobePack {

    struct Item {
        var source: ComicSource
        var changedFields: [String]
        var oldQuality: Int
        var newQuality: Int
        var evidence: (list: Int, chapter: Int, image: Int)
        var probedAt: Int64
        var verdict: String
    }

    /// 从远程地址拉取补丁包文本（URLSession GET）。
    /// 网络/HTTP 错误以异常抛出，由调用方转成用户提示。
    static func download(_ urlString: String) async throws -> String {
        guard let u = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              u.scheme == "http" || u.scheme == "https" else {
            throw NSError(domain: "ReprobePack", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "地址不合法（需要 http/https）"])
        }
        var req = URLRequest(url: u, timeoutInterval: 30)
        req.httpMethod = "GET"
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "ReprobePack", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "服务器返回 \(http.statusCode)"])
        }
        guard let t = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "ReprobePack", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "内容不是 UTF-8 文本，无法解析"])
        }
        return t
    }

    /// 解析补丁包文本。解析不出来的项**跳过**并计入 `skipped`。
    static func parse(_ text: String) -> (items: [Item], skipped: Int) {
        guard let data = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return ([], 0)
        }
        var items: [Item] = []
        var skipped = 0
        for raw in arr {
            guard let d = try? JSONSerialization.data(withJSONObject: raw),
                  let s = try? JSONDecoder().decode(ComicSource.self, from: d),
                  !s.bookSourceUrl.isEmpty else {
                skipped += 1
                continue
            }
            let p = raw["_probe"] as? [String: Any] ?? [:]
            let ev = p["evidence"] as? [String: Any] ?? [:]
            items.append(Item(
                source: s,
                changedFields: (p["changedFields"] as? [String]) ?? [],
                oldQuality: ReprobePack.int(p["oldQuality"]),
                newQuality: ReprobePack.int(p["newQuality"]),
                evidence: (list: ReprobePack.int(ev["list"]),
                           chapter: ReprobePack.int(ev["chapter"]),
                           image: ReprobePack.int(ev["image"])),
                probedAt: ReprobePack.int64(p["probedAt"]),
                verdict: p["verdict"] as? String ?? ""))
        }
        return (items, skipped)
    }

    /// 应用前计划：这个包对现有源分别意味着什么（新增 / 变更）
    struct Plan {
        let item: Item
        let isNew: Bool
        let existingName: String
        let existingEnabled: Bool
        var enabledAfterApply: Bool { isNew ? true : existingEnabled }
    }

    static func plan(_ items: [Item], existing: [ComicSource]) -> [Plan] {
        let byUrl = Dictionary(existing.map { ($0.bookSourceUrl, $0) }, uniquingKeysWith: { a, _ in a })
        return items.map { it in
            let old = byUrl[it.source.bookSourceUrl]
            return Plan(item: it,
                        isNew: old == nil,
                        existingName: old?.bookSourceName ?? "",
                        existingEnabled: old?.isEnabled ?? true)
        }
    }

    /// 应用选中的补丁。
    ///
    /// - Returns: 实际写入的源数量
    @discardableResult
    static func apply(_ items: [ComicSource], existing: [ComicSource]) -> Int {
        let byUrl = Dictionary(existing.map { ($0.bookSourceUrl, $0) }, uniquingKeysWith: { a, _ in a })
        var n = 0
        for var s in items {
            guard !s.bookSourceUrl.isEmpty else { continue }
            if let old = byUrl[s.bookSourceUrl] {
                // ⚠️ 保留用户的启用状态：补丁只负责修规则，不替用户决定开关
                s.enable = old.enable
                // ⚠️ 保留已有发现页栏目：源核只探测列表，不知道有哪些栏目
                if !(old.ruleFindUrl ?? "").isEmpty {
                    s.ruleFindUrl = old.ruleFindUrl
                }
                // 名称：原规则有名字就沿用（源核生成的名字可能带 emoji/截断）
                if !(old.bookSourceName ?? "").isEmpty {
                    s.bookSourceName = old.bookSourceName
                }
            }
            var saved = s
            saved.decryptRules(sourceUrl: saved.bookSourceUrl)
            ComicRepository.shared.saveSource(saved)
            n += 1
        }
        NotificationCenter.default.post(name: .hmdSourcesChanged, object: nil)
        return n
    }

    /// ⚠️ JSON 里的整数会被读成 `NSNumber`；直接 `as? Int` 在部分情况下拿不到值
    private static func int(_ v: Any?) -> Int {
        if let n = v as? NSNumber { return n.intValue }
        if let n = v as? Int { return n }
        if let n = v as? Double { return Int(n) }
        return 0
    }

    private static func int64(_ v: Any?) -> Int64 {
        if let n = v as? NSNumber { return n.int64Value }
        if let n = v as? Int { return Int64(n) }
        return 0
    }
}
