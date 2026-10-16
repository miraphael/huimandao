import SwiftUI
import WebKit

/// 图源网页登录 —— 对应 SourceLoginActivity：WKWebView 打开 loginUrl，捕获 Cookie 持久化
struct SourceLoginView: View {
    let source: ComicSource
    @Environment(\.dismiss) private var dismiss
    @State private var captured = false

    var body: some View {
        LoginWebView(url: source.loginUrl ?? source.bookSourceUrl) { cookies in
            let host = source.host()
            for (name, value) in cookies where !name.isEmpty {
                CookieStore.set(host: host, name: name, value: value)
            }
            // 不记录 Cookie 值，只记录键名，方便定位「网页登录后仍被拦截」的问题。
            // 卡拉漫画的 `omo_token` 是页面 JS 通过 document.cookie 写入的，
            // 某些 iOS 版本/重定向时序下不一定及时出现在 WKHTTPCookieStore，
            // 因此 Coordinator 会同时从 document.cookie 读取它。
            DiagLog.event("login", "cookie", "WebView 捕获域 \(host)：\(cookies.keys.sorted().joined(separator: ","))")
            captured = true
        }
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle("图源登录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if captured {
                Text("已捕获登录 Cookie，返回后搜索/阅读将带上登录态")
                    .font(.caption)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
            }
        }
    }
}

struct LoginWebView: UIViewRepresentable {
    let url: String
    let onCookies: ([String: String]) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        if let u = URL(string: url) {
            wv.load(URLRequest(url: u))
        }
        return wv
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onCookies: onCookies) }

    class Coordinator: NSObject, WKNavigationDelegate {
        let onCookies: ([String: String]) -> Void
        init(onCookies: @escaping ([String: String]) -> Void) { self.onCookies = onCookies }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 同时读两处：
            // ① WKHTTPCookieStore：拿 HttpOnly / 普通 Cookie；
            // ② document.cookie：补上卡拉漫画这类由页面 JS 写入、但在重定向时序下
            //    还没及时同步到 CookieStore 的 `omo_token`。
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                var map: [String: String] = [:]
                for c in cookies { map[c.name] = c.value }
                webView.evaluateJavaScript("document.cookie") { value, _ in
                    if let raw = value as? String {
                        for part in raw.split(separator: ";") {
                            let item = part.trimmingCharacters(in: .whitespaces)
                            guard let eq = item.firstIndex(of: "=") else { continue }
                            let name = item[..<eq].trimmingCharacters(in: .whitespaces)
                            let val = item[item.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                            if !name.isEmpty { map[String(name)] = String(val) }
                        }
                    }
                    self.onCookies(map)
                }
            }
        }
    }
}
