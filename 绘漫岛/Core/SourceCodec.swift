import Foundation

extension ComicSource {
    func host() -> String {
        URL(string: bookSourceUrl)?.host ?? bookSourceUrl
    }

    func absoluteUrl(_ path: String, base: String? = nil) -> String {
        NetUrl.absolute(path, base: base ?? bookSourceUrl)
    }
}

enum SourceCodec {
    /// 只解析不解密 —— 供需要「后台分批解密 + 边解边存」的调用方使用。
    /// ⚠️ 解密 535 源（1965 次 1024-bit RSA 模幂）要几十秒，绝不能同步跑在启动主线程，
    /// 否则会触发 0x8BADF00D 启动看门狗（scene-create 20s 超时）被直接 SIGKILL。
    static func parseJson(_ text: String) -> [ComicSource] {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.hasPrefix("{") && !trimmed.hasPrefix("[") {
            if let inflated = decompressShare(trimmed) { trimmed = inflated }
        }

        // ── ① 先走 Legado 嵌套格式（`yuedu/shuyuan` 与绝大多数 GitHub 书源仓库）──
        // 嵌套式（`ruleSearch`/`ruleBookInfo`/`ruleToc`/`ruleContent` 子对象）
        // 用 Codable 解出来会**字段全空** —— 表现为「源加进去了但什么都搜不到」。
        // 所以必须在 Codable 之前识别并转换。见 `LegadoConverter`。
        if let data = trimmed.data(using: .utf8),
           let any = try? JSONSerialization.jsonObject(with: data) {
            var objs: [[String: Any]] = []
            if let arr = any as? [[String: Any]] { objs = arr }
            else if let one = any as? [String: Any] { objs = [one] }
            let nested = objs.filter { LegadoConverter.isNested($0) }
            if !nested.isEmpty {
                let converted = nested.compactMap { LegadoConverter.convert($0) }
                // 混合格式（一半嵌套一半扁平）时把扁平的也补上
                if nested.count == objs.count { return converted }
                var out = converted
                let flatObjs = objs.filter { !LegadoConverter.isNested($0) }
                if let d = try? JSONSerialization.data(withJSONObject: flatObjs),
                   let f = try? JSONDecoder().decode([ComicSource].self, from: d) {
                    out.append(contentsOf: f)
                }
                return out
            }
        }

        if let arr = try? JSONDecoder().decode([ComicSource].self, from: Data(trimmed.utf8)) {
            return arr
        }
        if let one = try? JSONDecoder().decode(ComicSource.self, from: Data(trimmed.utf8)) {
            return [one]
        }
        // 宽松解析：逐个提取 {...} 块
        var list: [ComicSource] = []
        let blocks = trimmed.split(separator: "\n").map(String.init)
        for b in blocks where b.contains("{") {
            if let s = try? JSONDecoder().decode(ComicSource.self, from: Data(b.utf8)) { list.append(s) }
        }
        return list
    }

    /// 导入 JSON（单个对象或数组），并自动解密 `:_版本_密文` 规则
    /// 兼容三种载体：明文 JSON / base64+zlib 压缩分享串（yckceo 的 eNr... 格式）/ 每行一个 JSON
    static func importJson(_ text: String, sourceHost: String = "") -> [ComicSource] {
        let list = parseJson(text)
        // 第一遍：登记「H/T 密文 → 源URL」，让共享密文（镜像域名）能互相试解
        SourceDecrypt.registerCandidates(collectHTCipherPairs(list))
        // 第二遍：用完整 bookSourceUrl 解密
        return list.map { s in
            var s = s
            s.decryptRules(sourceUrl: s.bookSourceUrl)
            return s
        }
    }

    /// 扫描图源集合，收集 `:_H###_/:_T###_` 密文与其所属源 URL 的对应关系
    static func collectHTCipherPairs(_ sources: [ComicSource]) -> [(cipher: String, url: String)] {
        let enc = JSONEncoder()
        var pairs: [(cipher: String, url: String)] = []
        for s in sources {
            let url = s.bookSourceUrl
            guard !url.isEmpty,
                  let data = try? enc.encode(s),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for (k, v) in obj where k.hasPrefix("rule") {
                guard let str = v as? String, str.hasPrefix(":_") else { continue }
                let parts = str.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 3 else { continue }
                let ver = parts[1].uppercased()
                guard ver.hasPrefix("H") || ver.hasPrefix("T") else { continue }
                // 必须与 SourceDecrypt.auto() 用同样的归一化，否则共享密文的 key 对不上
                let cipher = parts[2].components(separatedBy: .whitespacesAndNewlines).joined()
                guard !cipher.isEmpty else { continue }
                pairs.append((cipher, url))
            }
        }
        return pairs
    }

    /// Legado/绘漫岛 分享压缩格式：base64(zlib(json))，特征是解 base64 后首字节 0x78
    static func decompressShare(_ t: String) -> String? {
        guard let data = SourceDecrypt.base64Flexible(t), let f = data.first, f == 0x78 else { return nil }
        guard let out = Zlib.inflate(data),
              let s = String(data: out, encoding: .utf8) ?? String(data: out, encoding: .isoLatin1) else { return nil }
        return (s.hasPrefix("{") || s.hasPrefix("[")) ? s : nil
    }

    static func exportJson(_ sources: [ComicSource], pretty: Bool = true) -> String {
        let enc = JSONEncoder()
        if pretty { enc.outputFormatting = [.prettyPrinted, .sortedKeys] }
        guard let data = try? enc.encode(sources) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}

extension ComicSource {
    /// 是否还残留未解密的 `:_版本_密文` 规则。
    /// 旧版本解密失败时会把密文原样存库，升级后需要据此把它们重新解一次。
    func hasEncryptedRules() -> Bool {
        guard let data = try? JSONEncoder().encode(self),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        for (k, v) in obj where k.hasPrefix("rule") {
            if let str = v as? String, str.hasPrefix(":_") { return true }
        }
        return false
    }

    /// 规则字段批量解密（对应 utils/Cfor 载入逻辑）
    mutating func decryptRules(sourceUrl: String) {
        ruleFindUrl = ruleFindUrl.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
        ruleSearchUrl = ruleSearchUrl.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
        ruleSearchList = ruleSearchList.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
        ruleSearchName = ruleSearchName.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
        ruleSearchAuthor = ruleSearchAuthor.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
        ruleSearchKind = ruleSearchKind.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
        ruleSearchLastChapter = ruleSearchLastChapter.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
        ruleSearchCoverUrl = ruleSearchCoverUrl.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
        ruleSearchNoteUrl = ruleSearchNoteUrl.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
        ruleBookName = ruleBookName.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
        ruleBookAuthor = ruleBookAuthor.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
        ruleBookKind = ruleBookKind.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
        ruleBookLastChapter = ruleBookLastChapter.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
        ruleIntroduce = ruleIntroduce.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
        ruleCoverUrl = ruleCoverUrl.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
        ruleChapterId = ruleChapterId.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
        ruleChapterList = ruleChapterList.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
        ruleChapterName = ruleChapterName.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
        ruleChapterUrl = ruleChapterUrl.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
        ruleChapterUrlNext = ruleChapterUrlNext.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
        ruleChapterParentId = ruleChapterParentId.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
        ruleChapterParentName = ruleChapterParentName.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
        ruleContentUrl = ruleContentUrl.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
        ruleContentUrlNext = ruleContentUrlNext.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
        ruleBookContent = ruleBookContent.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
        ruleBookContentDecoder = ruleBookContentDecoder.map { SourceDecrypt.auto($0, sourceUrl: sourceUrl) }
    }
}
