import Foundation

/// JS 类源提供者 —— 按 manifest 声明的入口函数驱动脚本，产出统一结果。
///
/// 安全与资源约束（ARCHITECTURE §9.1）：
///   • **上下文隔离**：复用 `JSEvaluator.evaluate`，它每次调用都新建 `JSContext`
///     并在闭包内销毁（见 JSEvaluator.swift:155），天然满足「每次运行独立上下文、
///     不跨源共享 JS 全局对象」。
///   • **专用队列**：JS 执行统一走 `JSExecQueue`（JSEvaluator 内部已保证），
///     不占 Swift 协作线程池。
///   • **不做硬超时声明**：现有 JSCore 无法安全强杀执行中的脚本，
///     因此本 Provider **不宣称**超时能力；死循环防护留给后续隔离进程方案。
///   • **网络**：脚本内的网络只能经受控桥（`java.ajax` / `JsoupOrg.connect`），
///     域名白名单在桥层收紧（见后续 TODO），本文件不直接发起网络。
final class JSProvider: SourceProvider {
    let manifest: JSSourceManifest

    var sourceId: String { manifest.id }
    /// JS 源的统一 origin 标识：`js://<manifest.id>`。
    ///
    /// 用作 `SearchResult.origin` / `ComicInfo.origin` —— 上层（`ComicEngine.detail` 等）
    /// 据此把后续请求**路由回本 Provider**，而不是去 `ComicRepository` 找不存在的 ComicSource。
    var sourceOrigin: String { "\(SearchResult.jsOriginPrefix)\(manifest.id)" }
    var kind: SourceKind { .javaScript }
    var capabilities: ProviderCapabilities { manifest.declaredCapabilities }

    init(manifest: JSSourceManifest) throws {
        try manifest.validate()
        self.manifest = manifest
    }

    // MARK: - 能力实现

    func search(keyword: String, page: Int) async throws -> [SearchResult] {
        try require(.search, "search")
        let raw = try await invoke(entry: manifest.entry.search!,
                                   args: [Self.jsLiteral(keyword), "\(page)"])
        return Self.decodeSearch(raw, origin: sourceOrigin, fallbackName: manifest.name)
    }

    func detail(noteUrl: String, origin: String,
                extraHeaders: [String: String]) async throws -> ComicInfo {
        try require(.detail, "detail")
        let raw = try await invoke(entry: manifest.entry.detail!, args: [Self.jsLiteral(noteUrl)])
        // origin 仍传 `js://<id>`（上层靠它把后续请求路由回本 Provider），
        // 但显示名用 manifest.name —— 详情页写的是「图源: <name>」，
        // 若直接把 `js://id` 展示给用户，可读性为零。
        return Self.decodeDetail(raw, noteUrl: noteUrl, origin: origin)
    }

    func chapters(of comic: ComicInfo) async throws -> [ComicInfo.Chapter] {
        try require(.chapters, "chapters")
        if !comic.chapters.isEmpty { return comic.chapters }
        let raw = try await invoke(entry: manifest.entry.chapters!,
                                   args: [Self.jsLiteral(comic.noteUrl)])
        return Self.decodeChapters(raw)
    }

    func images(chapterUrl: String, origin: String, page: Int,
                extraHeaders: [String: String]) async throws
        -> (urls: [String], headers: [String: String]) {
        try require(.images, "images")
        let raw = try await invoke(entry: manifest.entry.images!,
                                   args: [Self.jsLiteral(chapterUrl), "\(page)"])
        return (Self.decodeStringArray(raw), manifest.headers ?? [:])
    }

    // MARK: - JS 调用

    /// 调用 manifest 声明的入口函数，返回其 JSON 字符串结果。
    ///
    /// ⚠️ **v1 约定**：入口函数**同步返回**可 JSON 序列化的值（不支持 Promise）。
    ///    异常一律转成空结果，避免脚本错误冒泡成 App 崩溃；
    ///    具体失败原因由 `SourceDiagnostics` 在调用方记录。
    ///
    /// 🔴 **脚本必须先注入**：`JSEvaluator.evaluate` 每次调用都**新建 `JSContext`**
    ///    （见 JSEvaluator.swift 的 evaluateSync），上下文之间不共享全局。
    ///    因此「入口函数的定义」（`manifest.script`）与「对它的调用」**必须在同一次
    ///    evaluate 里**，否则调用时 `typeof entry === 'function'` 恒为假、
    ///    所有 JS 源都返回空结果。（此前这里只发了调用表达式、没带脚本，是**致命断链**。）
    ///
    /// 通道选择由 `manifest.effectiveRuntime` 决定：
    ///   • `jscore`    —— 先 eval 脚本再调用；支持网络桥，但不可终止。
    ///   • `wkwebview` —— 交给 `JSSourceWKExecutor`，**可超时终止**；无网络桥。
    private func invoke(entry: String, args: [String]) async throws -> String {
        let argList = args.joined(separator: ", ")
        // 把「脚本定义」+「调用」包在同一个 IIFE 里：脚本用函数声明/var 定义入口，
        // 在同一作用域内可直接调用（不污染全局，也不会因上下文重建而丢失）。
        let code = """
        (function(){
          \(manifest.script)
          try {
            if (typeof \(entry) !== 'function') { return '[]'; }
            var r = \(entry)(\(argList));
            if (r === null || r === undefined) { return '[]'; }
            if (typeof r === 'string') { return r; }
            return JSON.stringify(r);
          } catch (e) { return '[]'; }
        })()
        """

        switch manifest.effectiveRuntime {
        case .wkwebview:
            // 可终止通道：超时后销毁 WebView（进程回收）。无网络桥 —— 依赖网络的源不适用。
            let out = await JSSourceWKExecutor.shared.run(script: code)
            guard let out else {
                // 超时 / 执行异常。这里**抛错**而不是返回 "[]"：
                // 调用方（上层）能据此把「源无响应」与「源正常返回 0 条」区分开。
                throw SourceProviderError.cancelled("WKWebView 通道执行超时或异常（已回收）")
            }
            return out
        case .jscore:
            let outcome = await JSEvaluator.shared.evaluate(
                code, java: nil, result: "", baseUrl: manifest.domain,
                variables: [:], headers: manifest.headers ?? [:],
                // ⚠️ 网络白名单：脚本内的 `Jsoup.connect(url).get()` 只允许访问 manifest.domain
                //    及其子域；越界返回空文档（不抛异常，对齐原版「JS 出错返回空」语义）。
                allowedDomains: [manifest.domain])
            return outcome.text
        }
    }

    /// 把 Swift 字符串安全嵌进 JS 字面量（转义引号/反斜杠/换行）
    static func jsLiteral(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:   out.append(ch)
            }
        }
        return out + "\""
    }

    // MARK: - 结果解析（JSON → Model）

    private static func json(_ raw: String) -> Any? {
        guard let d = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }

    private static func str(_ dict: [String: Any], _ keys: String...) -> String {
        for k in keys {
            if let v = dict[k] as? String, !v.isEmpty { return v }
            if let v = dict[k] as? NSNumber { return v.stringValue }
        }
        return ""
    }

    /// - Parameter fallbackName: 脚本未返回 `originName` 时使用的显示名（通常传 manifest.name）。
    ///
    /// ⚠️ 必须有兜底：搜索结果里「来源: \(originName)」是用户判断「这条来自哪个源」的唯一线索。
    ///    脚本漏写 originName 时若留空，界面显示「来源: 」——看起来像 App 出 bug，
    ///    用户也无法区分同一本书来自哪个源。宁可显示 manifest 的名字，也不要留白。
    static func decodeSearch(_ raw: String, origin: String, fallbackName: String = "") -> [SearchResult] {
        guard let arr = json(raw) as? [[String: Any]] else { return [] }
        return arr.compactMap { d -> SearchResult? in
            let note = str(d, "noteUrl", "url", "link")
            guard !note.isEmpty else { return nil }
            var r = SearchResult()
            r.name = str(d, "name", "title")
            r.author = str(d, "author")
            r.kind = str(d, "kind", "category")
            r.coverUrl = str(d, "coverUrl", "cover", "image")
            r.lastChapter = str(d, "lastChapter")
            r.introduce = str(d, "introduce", "intro", "description")
            r.noteUrl = note
            r.origin = origin
            let declared = str(d, "originName").trimmingCharacters(in: .whitespaces)
            r.originName = declared.isEmpty ? fallbackName : declared
            let next = str(d, "urlNext", "next")
            r.urlNext = next.isEmpty ? nil : next
            return r
        }
    }

    /// 解析 `entry.detail` 的返回。
    ///
    /// ⚠️ 这里**不需要** `displayName` 参数：`ComicInfo` 没有存显示名的字段，
    ///    详情页的「图源: X」由 `SourceProviderRegistry.displayName(forOrigin:)`
    ///    在 UI 层解析（它能把 `js://<id>` 翻成 manifest 名）。
    ///    早先误加过一个 `originName` 参数与赋值 —— `ComicInfo` 根本没这个成员，编译不过。
    static func decodeDetail(_ raw: String, noteUrl: String, origin: String) -> ComicInfo {
        var info = ComicInfo()
        info.noteUrl = noteUrl
        info.origin = origin
        guard let d = json(raw) as? [String: Any] else { return info }
        info.name = str(d, "name", "title")
        info.author = str(d, "author")
        info.coverUrl = str(d, "coverUrl", "cover", "image")
        info.introduce = str(d, "introduce", "intro", "description")
        info.kind = str(d, "kind", "category")
        info.lastChapter = str(d, "lastChapter")
        let cu = str(d, "chapterUrl")
        info.chapterUrl = cu.isEmpty ? noteUrl : cu
        if let chs = d["chapters"] as? [[String: Any]] {
            info.chapters = chs.compactMap { c in
                let u = str(c, "url", "noteUrl")
                guard !u.isEmpty else { return nil }
                return ComicInfo.Chapter(name: str(c, "name", "title"), url: u, group: str(c, "group"))
            }
        }
        return info
    }

    static func decodeChapters(_ raw: String) -> [ComicInfo.Chapter] {
        guard let arr = json(raw) as? [[String: Any]] else { return [] }
        return arr.compactMap { c in
            let u = str(c, "url", "noteUrl")
            guard !u.isEmpty else { return nil }
            return ComicInfo.Chapter(name: str(c, "name", "title"), url: u, group: str(c, "group"))
        }
    }

    static func decodeStringArray(_ raw: String) -> [String] {
        if let arr = json(raw) as? [String] { return arr.filter { !$0.isEmpty } }
        if let arr = json(raw) as? [[String: Any]] {
            return arr.compactMap { str($0, "url", "src", "image") }.filter { !$0.isEmpty }
        }
        return []
    }
}
