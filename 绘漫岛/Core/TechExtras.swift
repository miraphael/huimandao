import Foundation
import Network
import Security

/// 技术对齐层 —— 对应安卓 Cronet/DoH/崩溃 SDK 的 iOS 实现
/// - HTTP/2、HTTP/3(QUIC)：URLSession 原生支持（HttpFetcher 已开启 assumesHTTP3Capable）
/// - DoH 防污染：阿里 DoH + 腾讯 HTTPDNS，解析失败时经 RawHttpClient 走 IP 直连（带 SNI）
/// - 崩溃捕获：写入 Documents/CrashReports，可从文件 App 导出

// MARK: - DoH 域名解析（对应 utils/Ctransient 的 DoH/httpdns）

enum DoHResolver {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "dohEnabled") }

    private static var cache: [String: (ip: String, exp: Date)] = [:]
    private static let lock = NSLock()

    /// 依次尝试 腾讯 HTTPDNS → 阿里 DoH（JSON API）
    static func resolve(_ host: String) async -> String? {
        if let c = cached(host) { return c }
        let candidates: [(String, String?)] = [
            ("https://119.29.29.29/d?dn=%@", nil),
            ("https://dns.alidns.com/resolve?name=%@&type=1", "application/dns-json"),
        ]
        let hostQ = host.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? host
        for (tpl, accept) in candidates {
            guard let url = URL(string: String(format: tpl, hostQ)) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 5
            if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            // 腾讯: {"data":["1.2.3.4"]}  阿里: {"Status":0,"Answer":[{"type":1,"data":"1.2.3.4"}]}
            if let arr = obj["data"] as? [String], let ip = arr.first, ip.contains(".") {
                store(host: host, ip: ip)
                return ip
            }
            if let answers = obj["Answer"] as? [[String: Any]],
               let ip = answers.compactMap({ $0["data"] as? String }).first(where: { $0.range(of: #"^\d+\.\d+\.\d+\.\d+$"#, options: .regularExpression) != nil }) {
                store(host: host, ip: ip)
                return ip
            }
        }
        return nil
    }

    private static func cached(_ host: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[host], c.exp > Date() { return c.ip }
        return nil
    }
    private static func store(host: String, ip: String) {
        lock.lock(); defer { lock.unlock() }
        cache[host] = (ip, Date().addingTimeInterval(600))
    }
}

// MARK: - IP 直连 HTTP 客户端（SNI 保持域名，等价 cronet 的 IP 直连能力）

enum RawHttpClient {
    /// 纯 TCP HTTP/1.1 直连指定 IP（Host 头保持原域名）；支持 Content-Length / 连接关闭定界
    static func request(_ url: URL, ip: String, method: String = "GET", body: Data? = nil, headers: [String: String] = [:], timeout: TimeInterval = 20) async -> (Data, Int)? {
        // DoH 直连场景统一走明文 80 端口（HTTPS 的 SNI 覆盖在新 SDK 不可用，见 README 已知限制）
        let host = url.host ?? ip
        let port: UInt16 = url.scheme == "https" ? 80 : UInt16(url.port ?? 80)
        let path = url.path.isEmpty ? "/" : url.path + (url.query.map { "?\($0)" } ?? "")

        var head = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n"
        for (k, v) in headers where k.lowercased() != "host" { head += "\(k): \(v)\r\n" }
        if let body { head += "Content-Length: \(body.count)\r\n" }
        head += "\r\n"

        return await withCheckedContinuation { cont in
            guard let p = NWEndpoint.Port(rawValue: port), !ip.isEmpty else {
                cont.resume(returning: nil)
                return
            }
            let conn = NWConnection(host: NWEndpoint.Host(ip), port: p, using: .tcp)
            let queue = DispatchQueue(label: "rawhttp")

            // ⚠️ Swift 6：局部 `func` 捕获可变局部变量（received/status/finished）后被
            //    `@Sendable` 的 NWConnection 回调捕获，会报
            //    "concurrently-executed local function must be marked as '@Sendable'"。
            //    改成把状态与逻辑收进一个引用类型，闭包只捕获这个对象（它自己加锁保护）。
            let session = RawHTTPSession(conn: conn, head: head, body: body, cont: cont)
            queue.asyncAfter(deadline: .now() + timeout) { session.finish() }

            conn.stateUpdateHandler = { state in
                if state == .ready { session.sendHead() }
                if case .failed = state { session.finish() }
            }
            conn.start(queue: queue)
        }
    }
}

/// 一次 IP 直连 HTTP 请求的会话状态。所有可变状态由 `lock` 保护，
/// 供 NWConnection 的多个 `@Sendable` 回调并发访问。
private final class RawHTTPSession: @unchecked Sendable {
    private let conn: NWConnection
    private let head: String
    private let body: Data?
    private let cont: CheckedContinuation<(Data, Int)?, Never>

    private let lock = NSLock()
    private var received = Data()
    private var status = 0
    private var finished = false

    init(conn: NWConnection, head: String, body: Data?,
         cont: CheckedContinuation<(Data, Int)?, Never>) {
        self.conn = conn
        self.head = head
        self.body = body
        self.cont = cont
    }

    func finish() {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let payload: (Data, Int)? = status > 0 ? (received, status) : nil
        lock.unlock()
        conn.cancel()
        cont.resume(returning: payload)
    }

    func sendHead() {
        let data = Data(head.utf8) + (body ?? Data())
        conn.send(content: data, completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            if err != nil { self.finish(); return }
            // ⚠️ 旧代码漏了这一步：`sendHead` 之后必须启动 `receive`，
            //    否则响应永远不会被读取，只能在超时后返回 nil。
            self.receive()
        })
    }

    func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, err in
            guard let self else { return }
            self.lock.lock()
            if let d = data { self.received += d }
            // 解析状态行
            if self.status == 0, let r = self.received.range(of: Data("\r\n\r\n".utf8)) {
                let headStr = String(data: self.received[..<r.lowerBound], encoding: .utf8) ?? ""
                let parts = headStr.split(separator: " ")
                self.status = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
            }
            self.lock.unlock()
            if isComplete || err != nil { self.finish(); return }
            self.receive()
        }
    }
}

// MARK: - 崩溃捕获（等价 crashsdk：落盘到 Documents/CrashReports）

enum CrashCatcher {
    private static var fd: Int32 = -1

    static func install() {
        // 预打开日志文件（信号处理器里只能用 async-signal-safe 的 open/write）
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CrashReports")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("last-crash.log").path
        fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)

        NSSetUncaughtExceptionHandler { exc in
            let msg = "NSException: \(exc.name.rawValue)\nreason: \(exc.reason ?? "-")\n" +
                exc.callStackSymbols.prefix(30).joined(separator: "\n")
            CrashCatcher.safeWrite(msg)
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            signal(sig) { s in
                CrashCatcher.safeWrite("signal \(s)\n")
                // 恢复默认处理并重抛 → 系统 CrashReporter 照常生成 .ips（不再吞崩溃）
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    /// 信号上下文安全写入
    private static func safeWrite(_ text: String) {
        guard fd >= 0 else { return }
        text.withCString { cstr in
            var len = 0
            while cstr[len] != 0 { len += 1 }
            _ = write(fd, cstr, len)
        }
    }

    static func pendingLogs() -> [URL] {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CrashReports")
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    }
}
