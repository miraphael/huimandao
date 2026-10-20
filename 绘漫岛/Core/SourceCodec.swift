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
    /// 清洗导入文本 —— **这是「别人导入失败、我却没问题」最常见的原因**。
    ///
    /// 实际遇到的脏数据：
    /// · **BOM**：文件被某些编辑器/导出工具加了 `EF BB BF`，`hasPrefix("{")` 就 false，
    ///   于是被当成「加密分享串」去解，必然失败。`trimmingCharacters(in: .whitespacesAndNewlines)`
    ///   **不会**去掉 U+FEFF（它不算空白字符）。
    /// · **零宽字符**：微信/QQ 复制时偶尔带 U+200B。
    /// · **智能引号**：聊天软件把 `"` 转成 `“ ”`，JSON 直接解析不了。
    /// · **全角逗号/冒号**：中文输入法手打 JSON 的常见后果。
    static func normalize(_ text: String) -> String {
        var t = text
        // BOM / 零宽
        t = t.replacingOccurrences(of: "\u{FEFF}", with: "")
        t = t.replacingOccurrences(of: "\u{200B}", with: "")
        t = t.replacingOccurrences(of: "\u{200C}", with: "")
        t = t.replacingOccurrences(of: "\u{200D}", with: "")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把「中文标点」修成 JSON 能认的 ASCII 标点。
    ///
    /// 只在**正常解析失败之后**才调用 —— 直接全局替换会破坏字符串里本来就该是
    /// 中文标点的内容（比如书名里的「，」），所以不能放进 `normalize`。
    static func repairQuotes(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: "\u{201C}", with: "\"")   // “
        t = t.replacingOccurrences(of: "\u{201D}", with: "\"")   // ”
        t = t.replacingOccurrences(of: "\u{2018}", with: "'")   // ‘
        t = t.replacingOccurrences(of: "\u{2019}", with: "'")   // ’
        // 全角逗号/冒号只在「引号外」才该换；这里保守处理：JSON 结构里出现全角，
        // 基本可以确定是手打/输入法问题。
        t = t.replacingOccurrences(of: "\u{FF0C}", with: ",")     // ，
        t = t.replacingOccurrences(of: "\u{FF1A}", with: ":")     // ：
        return t
    }

    /// 从任意编码的字节里取出文本。
    ///
    /// 文件导入原来只认 UTF-8 —— Windows 记事本存的 GBK、Excel 导出的 GB18030、
    /// 部分工具存的 UTF-16 都会直接「文件读取失败」。
    static func text(from data: Data) -> String? {
        if data.isEmpty { return nil }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .utf16LittleEndian) { return s }
        // GB18030（兼容 GBK / GB2312）
        let gb = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { return s }
        return String(data: data, encoding: .isoLatin1)
    }

    /// 导入失败时告诉用户**到底哪一步坏了**（原来只有一句「不是有效图源」）。
    static func diagnosis(_ text: String) -> String {
        let t = normalize(text)
        if t.isEmpty { return "内容为空" }
        if t.hasPrefix("{") || t.hasPrefix("[") {
            // 看起来是 JSON，但解析不出源
            let head = String(t.prefix(60)).replacingOccurrences(of: "\n", with: " ")
            if t.contains("“") || t.contains("”") {
                return "JSON 里的引号是中文引号（“ ”）—— 聊天软件复制时被转换了，请改用「从文件导入」"
            }
            if t.contains("，") && !t.contains(",") {
                return "JSON 里的逗号是中文逗号（，）—— 请换成英文逗号"
            }
            return "JSON 结构不对，开头是：\(head)"
        }
        if t.hasPrefix(":_") {
            return "这是「加密图源」密文，需要 App 升级到最新版才能导入"
        }
        return "既不是 JSON 也不是加密分享串，开头是：\(String(t.prefix(40)))"
    }

    static func parseJson(_ text: String) -> [ComicSource] {
        var trimmed = normalize(text)
        if !trimmed.hasPrefix("{") && !trimmed.hasPrefix("[") {
            if let inflated = decompressShare(trimmed) { trimmed = normalize(inflated) }
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
        // ③ 兜底：把中文引号/逗号修成 ASCII 再试一次
        //    （聊天软件复制会把 " 变成 “ ”，这是「我这边能导入、朋友那边不行」的典型原因）
        let repaired = repairQuotes(trimmed)
        if repaired != trimmed {
            let fixed = parseJson(repaired)
            if !fixed.isEmpty { return fixed }
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
            // 「发现」开关：从 Legado 导入的源常带 `enabledExplore: false`（Legado 的默认值），
            // 而我们的漫画台只列「有栏目 + 开关打开」的源 —— 结果整片漫画台空掉。
            // 只要它配了发现栏目，就默认打开；用户仍可在图源页用那个小圆点关掉。
            if let f = s.ruleFindUrl, !f.isEmpty, s.enabledExplore == false {
                s.enabledExplore = true
                DiagLog.event("import", "explore", "「\(s.bookSourceName)」有发现栏目但开关是关的 → 已自动打开")
            }
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
