import Foundation
import WebKit

/// DOM 级 JS 规则执行 —— 对应原版 WebViewAnalysis/AnalyzeByWeb（Rhino+Envjs+jQuery 环境的 iOS 等价物）
/// 用真实 WKWebView 提供完整 DOM：识别 document/$ 引用的 <js> 规则走这里，@web: 抓取渲染后 HTML 也走这里
@MainActor
final class WebViewRuleEngine: NSObject {
    static let shared = WebViewRuleEngine()

    private var webview: WKWebView?
    private var navContinuation: CheckedContinuation<Void, Never>?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - 对外

    /// 在 HTML 上执行规则 JS（自动注入 jQuery）；返回 (求值结果, java.put 写入的变量)
    func evaluateOnHTML(_ html: String, baseUrl: String, script: String, variables: [String: String]) async -> (String, [String: String]) {
        await acquire()
        defer { release() }
        guard let w = ensureWebview() else { return ("", [:]) }

        let escaped = html
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        let nav = w.loadHTMLString(html, baseURL: URL(string: baseUrl))
        _ = await waitNav()
        _ = nav
        // jQuery（原版 assets/jquery.js）
        if let jquery = Bundle.main.url(forResource: "jquery", withExtension: "js", subdirectory: "web"),
           let js = try? String(contentsOf: jquery, encoding: .utf8) {
            w.evaluateJavaScript(js, completionHandler: nil)
        }
        // 预置上下文：result/baseUrl/java(内存版)
        let prelude = """
        var __kv = \(json(variables));
        var baseUrl = \(json(baseUrl));
        var imgPage = null;
        var java = {
          get: function(k){ return __kv[k] !== undefined ? __kv[k] : ''; },
          put: function(k,v){ __kv[k] = String(v); },
          ajax: function(urls){ return []; },
          ajaxUrls: function(urls){ return urls; },
          log: function(m){ },
          toast: function(m){ }
        };
        var result = null;
        """
        w.evaluateJavaScript(prelude, completionHandler: nil)
        var out = ""
        do {
            let v = try await w.evaluateJavaScript(script)
            out = stringify(v)
        } catch { out = "" }
        if out.isEmpty {
            if let r = try? await w.evaluateJavaScript("String(typeof result === 'undefined' || result === null ? '' : result)") {
                out = stringify(r)
            }
        }
        var vars: [String: String] = [:]
        if let kv = try? await w.evaluateJavaScript("JSON.stringify(__kv || {})"), let s = stringify(kv).data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: s) as? [String: String] {
            vars = dict
        }
        return (out, vars)
    }

    /// 加载 URL 等待 JS 渲染后返回最终 HTML（对应 @web:/@webm: 与 getWebViewResult）
    func fetchRendered(url: String, settleMs: Int = 3000) async -> String {
        await acquire()
        defer { release() }
        guard let w = ensureWebview(), let u = URL(string: url) else { return "" }
        w.load(URLRequest(url: u))
        _ = await waitNav()
        try? await Task.sleep(nanoseconds: UInt64(settleMs) * 1_000_000)
        guard let v = try? await w.evaluateJavaScript("document.documentElement.outerHTML") else { return "" }
        return stringify(v)
    }

    // MARK: - 反反爬：过站点挑战

    /// 过挑战的结果
    struct ChallengeResult {
        var passed = false
        var ua = ""
        var cookies: [String: String] = [:]
    }

    /// 加载 URL 并等待站点挑战（Cloudflare / JS 验证）结束。
    ///
    /// 判定方式对齐 Venera-Next：轮询 `document.head/body.innerHTML`，
    /// 出现 `#challenge-form` / `challenge-platform` / `window._cf_chl_opt`
    /// 等特征 = 「还在挑战中」；特征消失即视为通过。
    ///
    /// ⚠️ 必须在通过后**同时**取走 UA 和 Cookie：
    ///    `cf_clearance` 与 UA 绑定，只回写 Cookie 不回写 UA 会导致
    ///    「挑战过了但后续请求仍被拒」。
    func passChallenge(url: String, maxWaitMs: Int = 20_000) async -> ChallengeResult {
        await acquire()
        defer { release() }
        guard let w = ensureWebview(), let u = URL(string: url) else { return ChallengeResult() }
        w.load(URLRequest(url: u))
        _ = await waitNav()

        let checkJS = """
        (function(){
          try {
            var head = (document.head && document.head.innerHTML) || '';
            var body = (document.body && document.body.innerHTML) || '';
            var s = (head + body).toLowerCase();
            var marks = ['#challenge-form','challenge-platform','window._cf_chl_opt',
                         'cf-browser-verification','cf-chl','__cf_chl',
                         'just a moment','checking your browser',
                         'enable javascript and cookies','please enable javascript',
                         '人机验证','正在验证','访问验证','安全验证','请开启javascript'];
            for (var i=0;i<marks.length;i++){ if (s.indexOf(marks[i])>=0) return 'challenge'; }
            if (body.length < 400) return 'thin';
            return 'ok';
          } catch(e) { return 'err'; }
        })()
        """
        var passed = false
        let stepMs = 600
        var waited = 0
        while waited < maxWaitMs {
            let v = try? await w.evaluateJavaScript(checkJS)
            if (v as? String) == "ok" { passed = true; break }
            try? await Task.sleep(nanoseconds: UInt64(stepMs) * 1_000_000)
            waited += stepMs
        }

        var out = ChallengeResult()
        out.passed = passed
        if let v = try? await w.evaluateJavaScript("navigator.userAgent"),
           let ua = v as? String, !ua.isEmpty {
            out.ua = ua
        }
        out.cookies = await cookies(forHost: u.host ?? "")
        return out
    }

    /// 取 WebView 里属于该域名的 Cookie（含 `cf_clearance`）。
    /// 按域名过滤 —— `getAllCookies` 会返回所有站点的 Cookie，不过滤会把
    /// 别的站点的 Cookie 也写进这个源，造成串号。
    func cookies(forHost host: String) async -> [String: String] {
        guard !host.isEmpty else { return [:] }
        let all: [HTTPCookie] = await withCheckedContinuation { (c: CheckedContinuation<[HTTPCookie], Never>) in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { list in
                c.resume(returning: list)
            }
        }
        var m: [String: String] = [:]
        for ck in all {
            let d = ck.domain.hasPrefix(".") ? String(ck.domain.dropFirst()) : ck.domain
            if host == d || host.hasSuffix("." + d) { m[ck.name] = ck.value }
        }
        return m
    }

    /// 把 `CookieStore` 里该域名的 Cookie 注入 WebView，避免每次开页都重新过挑战。
    func syncCookiesToWebView(host: String, url: URL) async {
        let header = CookieStore.header(host: host)
        guard !header.isEmpty else { return }
        let store = WKWebsiteDataStore.default().httpCookieStore
        for part in header.components(separatedBy: "; ") {
            let bits = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard bits.count == 2, !bits[0].isEmpty else { continue }
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: bits[0],
                .value: bits[1],
                .domain: host,
                .path: "/",
                .originURL: url
            ]
            if url.scheme?.lowercased() == "https" { props[.secure] = "TRUE" }
            guard let ck = HTTPCookie(properties: props) else { continue }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                store.setCookie(ck) { c.resume() }
            }
        }
    }

    // MARK: - 内部

    private func ensureWebview() -> WKWebView? {
        if let webview { return webview }
        let cfg = WKWebViewConfiguration()
        // ⚠️ 用 `.default()`（持久化）而不是 `.nonPersistent()`：
        //    Cloudflare 的 `cf_clearance` 有效期数小时，持久化后**杀 App 也不用重过挑战**。
        //    nonPersistent 会让每次启动都从零开始过挑战，慢且容易被判为异常流量。
        cfg.websiteDataStore = .default()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 1200), configuration: cfg)
        wv.navigationDelegate = self
        // 离屏不可见
        wv.alpha = 0.01
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
           let window = scene.windows.first {
            window.addSubview(wv)
            window.sendSubviewToBack(wv)
        }
        webview = wv
        return wv
    }

    private func waitNav() async -> Void {
        if navContinuation != nil { return }
        await withCheckedContinuation { c in
            // 10s 超时兜底
            self.navContinuation = c
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if let pending = self.navContinuation {
                    self.navContinuation = nil
                    pending.resume()
                }
            }
        }
    }

    private func resumeNav() {
        if let c = navContinuation {
            navContinuation = nil
            c.resume()
        }
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if let f = waiters.first {
            waiters.removeFirst()
            f.resume()   // 锁继续被持有
        } else {
            busy = false
        }
    }

    private func json(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]), let str = String(data: d, encoding: .utf8) else { return "''" }
        return str
    }
    private func json(_ dict: [String: String]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: dict), let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
    private func stringify(_ v: Any?) -> String {
        guard let v else { return "" }
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case is NSNull: return ""
        default: return "\(v)"
        }
    }
}

extension WebViewRuleEngine: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { resumeNav() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { resumeNav() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { resumeNav() }
}
