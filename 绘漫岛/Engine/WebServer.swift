import Foundation
import Network

/// 内嵌 Web 服务器 —— 对应 WebService/HttpServer/ShareServer（端口 1122，协议一致）
/// GET  /getChapterList /getBookshelf /getSources /getSource?url= /getBookContent?url=
/// POST /saveSource /saveSources /deleteSources /saveBook   body 字段 postData
/// 其它路径 → Resources/web 静态页（图源编辑器 v3.8，CORS 全开）
final class WebServer {
    static let shared = WebServer()
    private var listener: NWListener?
    private(set) var isRunning = false

    func start(port: UInt16) {
        stop()
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: p) else { return }
        listener = l
        l.newConnectionHandler = { conn in self.handle(conn) }
        l.stateUpdateHandler = { [weak self] state in
            self?.isRunning = state == .ready
        }
        l.start(queue: .global())
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - 访问令牌（鉴权）

    /// 访问令牌 —— **除静态页外的所有端点都必须带上它**。
    ///
    /// ## ⚠️ 为什么必须加
    /// `NWListener` 默认监听 `0.0.0.0`（**局域网可访问**），而原先
    /// **没有任何鉴权**、CORS 还是全开（`Access-Control-Allow-Origin: *`）。
    /// 于是同一网段（咖啡厅 / 酒店 / 宿舍 Wi-Fi）的任何人：
    ///   · `POST /saveSources` → 把**任意图源写进库**（源里的 `@js:` 会在
    ///     用户后续搜索/阅读时被执行）；
    ///   · `POST /deleteSources` → **清空用户全部图源**；
    ///   · `GET /shareSources` → 拉走全部源定义。
    /// 这是一条「零凭据 → 远程写入」的完整链，必须堵上。
    ///
    /// 令牌持久化在 `UserDefaults`：重启后 URL 不变，用户保存的书签仍然有效。
    /// 常量时间字符串比较（用于令牌校验）。
    ///
    /// 🔴 不能直接用 `==`：Swift 的 `String` 比较是**短路**的，一旦首字节不同就返回，
    ///    攻击者能靠响应时间差**逐字节**把令牌试出来。本地服务虽然只监听本机 +
    ///    局域网，但令牌就是唯一防线，值得用正确写法。（由智能体「守卫」发现）
    static func tokenEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        // 长度不同直接判否（长度本身不是秘密，令牌长度固定）
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    /// 单次请求体的硬上限（见 body 处的说明）
    static let maxBodyBytes = 8 * 1024 * 1024

    static var token: String {
        let key = "hmd_web_token"
        if let v = UserDefaults.standard.string(forKey: key), v.count >= 8 { return v }
        // 去掉易混字符（0/o、1/l/i）
        let alphabet = "abcdefghijkmnpqrstuvwxyz23456789"
        let v = String((0..<10).map { _ in alphabet.randomElement()! })
        UserDefaults.standard.set(v, forKey: key)
        return v
    }

    /// 该路径是否需要鉴权（静态编辑器页面本身允许匿名加载 —— 用户得先打开它才能填令牌）。
    private func requiresAuth(_ path: String) -> Bool {
        let apiPrefixes = ["/get", "/save", "/delete", "/share", "/put"]
        return apiPrefixes.contains { path.hasPrefix($0) }
    }

    private func respond(_ conn: NWConnection, status: String, contentType: String, data: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\n"
            + "Content-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, _ in
            var buf = buffer
            if let d = data { buf += d }
            if done || (buf.count >= 4 && buf.range(of: Data("\r\n\r\n".utf8)) != nil) {
                if let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(data: buf[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
                    let lower = head.lowercased()
                    let contentLength = lower.range(of: "content-length:").flatMap { r -> Int? in
                        let digits = String(lower[r.upperBound...].prefix { $0.isNumber })
                        return Int(digits)
                    } ?? 0
                    let bodyStart = headerEnd.upperBound
                    let haveBody = buf.count - bodyStart
                    if haveBody < contentLength {
                        // 继续收 body
                        conn.receive(minimumIncompleteLength: contentLength - haveBody, maximumLength: contentLength - haveBody) { more, _, _, _ in
                            var full = buf
                            if let more { full += more }
                            self.route(conn, request: full, head: head)
                        }
                        return
                    }
                    self.route(conn, request: buf, head: head)
                    return
                }
                conn.cancel()
                return
            }
            self.receive(conn, buffer: buf)
        }
    }

    private func route(_ conn: NWConnection, request: Data, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { conn.cancel(); return }
        let parts = first.split(separator: " ").map(String.init)
        let method = parts.count > 0 ? parts[0] : "GET"
        let rawPath = parts.count > 1 ? parts[1] : "/"
        let path = String(rawPath.split(separator: "?").first ?? "/")
        let query = rawPath.contains("?") ? String(rawPath.split(separator: "?", maxSplits: 1)[1]) : ""
        let bodyStart = request.range(of: Data("\r\n\r\n".utf8))?.upperBound ?? request.count
        // 🔴 POST body 上限（2026-10-19 安全加固）：
        //    这个服务监听 0.0.0.0，同一局域网内**知道令牌**的对端可以 POST 一个
        //    几百 MB 的 body 把 App 内存打满（`request` 已经是整包读进内存的）。
        //    图源 JSON 正常几 KB ~ 几百 KB，8MB 非常宽松。
        let bodyBytes = request.count - bodyStart
        guard bodyBytes <= Self.maxBodyBytes else {
            DiagLog.event("web", "oversize", "请求体 \(bodyBytes / 1_048_576)MB 超上限，已拒绝")
            respond(conn, status: "413 Payload Too Large",
                    contentType: "application/json; charset=utf-8",
                    data: Data(#"{"isOk":false,"msg":"请求体过大"}"#.utf8))
            return
        }
        let body = String(data: request[bodyStart...], encoding: .utf8) ?? ""
        // POST body 可能是 form: postData=xxx
        var payload = body
        if payload.hasPrefix("postData="), let unescaped = payload.dropFirst(9).removingPercentEncoding {
            payload = unescaped
        }

        // ── 鉴权（见 `token` 的说明）──────────────────────────────────
        if requiresAuth(path) {
            let fromQuery = queryParams(query)["t"]
            let fromHeader = lines.first { $0.lowercased().hasPrefix("x-hmd-token:") }
                .map { String($0.dropFirst("x-hmd-token:".count))
                        .trimmingCharacters(in: .whitespaces) }
            // 🔴 用**常量时间**比较，不用 `==` —— `String ==` 是短路比较，
            //    理论上能靠响应时间差逐字节猜出令牌（本地服务 + 局域网可达，
            //    这个面是真实存在的）。（由智能体「守卫」发现）
            guard let given = fromQuery ?? fromHeader, Self.tokenEqual(given, Self.token) else {
                respond(conn, status: "401 Unauthorized",
                        contentType: "application/json; charset=utf-8",
                        data: Data(#"{"isOk":false,"msg":"缺少或错误的访问令牌。请在 App 的「网络设置」里复制带 ?t= 的完整地址。"}"#.utf8))
                return
            }
        }

        let response: (status: String, contentType: String, data: Data)
        switch path {
        case "/getSources":
            response = json(ComicRepository.shared.allSources().map { SourceCodec.exportJson([$0], pretty: false) }.compactMap { $0.data(using: .utf8) }.map { try? JSONSerialization.jsonObject(with: $0) }.compactMap { $0 })
        case "/getSource":
            let url = queryParams(query)["url"] ?? ""
            if let s = ComicRepository.shared.source(url: url) {
                response = json([s])
            } else { response = json([]) }
        case "/saveSource", "/saveSources":
            let list = SourceCodec.importJson(payload)
            ComicRepository.shared.saveSources(list)
            response = json(["isOk": true, "msg": "导入\(list.count)条"])
        case "/deleteSources":
            let urls = payload.split(separator: "\n").map(String.init)
            ComicRepository.shared.deleteSources(urls: urls)
            response = json(["isOk": true])
        case "/getBookshelf":
            let items = ComicRepository.shared.shelfList()
            let arr: [[String: Any]] = items.map { ["name": $0.name, "url": $0.noteUrl, "origin": $0.origin,
                                                    "coverUrl": $0.coverUrl, "lastChapter": $0.lastChapterName,
                                                    "durChapterName": $0.durChapterName, "durChapterPage": $0.durChapterPage] }
            response = json(arr)
        case "/getChapterList":
            // 异步引擎取真实章节列表（对应 BookshelfController.getChapterList）
            let url = queryParams(query)["url"] ?? ""
            let origin = queryParams(query)["origin"] ?? ComicRepository.shared.shelfList().first(where: { $0.noteUrl == url })?.origin ?? ""
            respondAsync(conn) {
                let chapters = await ComicEngine.shared.webChapters(noteUrl: url, origin: origin)
                return self.json(["chapters": chapters])
            }
            return
        case "/getBookContent":
            // 真实正文图片列表
            let url = queryParams(query)["url"] ?? ""
            let origin = queryParams(query)["origin"] ?? ""
            respondAsync(conn) {
                let images = await ComicEngine.shared.webContent(chapterUrl: url, origin: origin)
                return self.json(["images": images])
            }
            return
        case "/shareSources":
            let data = SourceCodec.exportJson(ComicRepository.shared.allSources(), pretty: false)
            response = ("200 OK", "application/json; charset=utf-8", Data(data.utf8))
        default:
            response = staticPage(path)
        }
        // ⚠️ 不再下发 `Access-Control-Allow-Origin: *`。
        //    编辑器页面由本服务器**同源**提供，同源请求本来就不需要 CORS 头；
        //    而 `*` 会让**任意网页**（用户在其他标签页打开的）也能读走这里的
        //    源列表 / 书架 / 章节。删掉它，只保留同源可用。
        var head = "HTTP/1.1 \(response.status)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.data.count)\r\nConnection: close\r\n\r\n"
        if method == "OPTIONS" { head = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n" }
        conn.send(content: Data(head.utf8) + response.data, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// 异步构建响应（引擎方法为 async）
    private func respondAsync(_ conn: NWConnection, _ build: @escaping () async -> (String, String, Data)) {
        Task {
            let r = await build()
            // 🔴 不能下发 `Access-Control-Allow-Origin: *` —— 同步路径早就去掉了
            //    （见上面 respond 的说明），异步路径却还留着，等于**任意网页都能
            //    跨域读走用户的章节列表与正文**（/getChapterList、/getBookContent）。
            //    本地服务只给 App 自己用，不需要 CORS。（由智能体「守卫」发现）
            let head = "HTTP/1.1 \(r.0)\r\nContent-Type: \(r.1)\r\nContent-Length: \(r.2.count)\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(head.utf8) + r.2, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    private func queryParams(_ query: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
        }
        return out
    }

    private func json(_ obj: Any) -> (String, String, Data) {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed])) ?? Data("[]".utf8)
        return ("200 OK", "application/json; charset=utf-8", data)
    }

    private func staticPage(_ path: String) -> (String, String, Data) {
        let name = path == "/" ? "index.html" : String(path.dropFirst())
        guard let url = Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: (name as NSString).pathExtension, subdirectory: "web"),
              let data = try? Data(contentsOf: url) else {
            return ("404 Not Found", "text/html; charset=utf-8", Data("<h1>404</h1>".utf8))
        }
        let mime: String
        switch (name as NSString).pathExtension.lowercased() {
        case "html": mime = "text/html; charset=utf-8"
        case "css": mime = "text/css; charset=utf-8"
        case "js": mime = "application/javascript; charset=utf-8"
        case "ico": mime = "image/x-icon"
        default: mime = "application/octet-stream"
        }
        return ("200 OK", mime, data)
    }
}
