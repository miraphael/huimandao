import SwiftUI
import WebKit

/// 图源网页登录 —— WKWebView 打开 loginUrl，捕获 Cookie 持久化。
///
/// 🔴 2026-10-25 修「登录功能残缺」：
///   旧实现只在 `didFinish` 时抓一次 Cookie，**点「完成」时不再抓** ——
///   用户输完账号密码、页面还在跳转就点完成 → 抓到的还是未登录的 Cookie。
///   而且**从不回写 `loginUrlResult`** → 发现页的「需要登录」判断永远成立，
///   登录完还一直提示「去网页登录」，看起来就是「功能残缺」。
///
///   现在：点「完成」→ **强制再抓一次** → 存 CookieStore → 回写 `loginUrlResult`
///   → 广播 `hmdSourcesChanged` 让图源页/发现页刷新。
struct SourceLoginView: View {
    let source: ComicSource
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = LoginSession()
    @State private var capturedKeys: [String] = []
    @State private var saving = false

    var body: some View {
        LoginWebView(url: source.loginUrl ?? source.bookSourceUrl, session: session)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("图源登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "完成") { saveAndClose() }
                        .fontWeight(.semibold)
                        .disabled(saving)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 4) {
                    if capturedKeys.isEmpty {
                        Text("登录完成后点右上角「完成」——会保存登录状态")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("已捕获 \(capturedKeys.count) 个 Cookie：\(capturedKeys.prefix(6).joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if !(source.loginUrlResult ?? "").isEmpty {
                        Text("该图源已登录过（可重新登录刷新令牌）")
                            .font(.caption2)
                            .foregroundStyle(HMD.Semantic.success)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .onReceive(session.$lastKeys) { keys in
                    if !keys.isEmpty { capturedKeys = keys }
                }
            }
    }

    /// 点「完成」：**再抓一次**（不等 didFinish），存 Cookie + 回写登录标记
    private func saveAndClose() {
        saving = true
        session.capture { cookies in
            let host = source.host()
            for (name, value) in cookies where !name.isEmpty {
                CookieStore.set(host: host, name: name, value: value)
            }
            // 🔴 回写 loginUrlResult：发现页的「需要登录」判断靠它
            if var s = ComicRepository.shared.source(url: source.bookSourceUrl) {
                s.loginUrlResult = cookies.isEmpty
                    ? ""
                    : "ok:" + cookies.keys.sorted().joined(separator: ",")
                ComicRepository.shared.saveSource(s)
            }
            DiagLog.event("login", "save",
                          "保存 \(cookies.count) 个 cookie（域 \(host)）；loginUrlResult 已置位")
            NotificationCenter.default.post(name: .hmdSourcesChanged, object: nil)
            saving = false
            dismiss()
        }
    }
}

/// 登录会话：持有 WKWebView，随时可主动抓 Cookie（不依赖 didFinish 时机）
final class LoginSession: NSObject, ObservableObject {
    @Published var lastKeys: [String] = []
    weak var webView: WKWebView?

    /// 抓当前页面的全部 Cookie（WKHTTPCookieStore + document.cookie 两处合并）
    func capture(completion: @escaping ([String: String]) -> Void) {
        guard let wv = webView else { completion([:]); return }
        wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            var map: [String: String] = [:]
            for c in cookies where !c.name.isEmpty { map[c.name] = c.value }
            wv.evaluateJavaScript("document.cookie") { value, _ in
                if let raw = value as? String {
                    for part in raw.split(separator: ";") {
                        let item = part.trimmingCharacters(in: .whitespaces)
                        guard let eq = item.firstIndex(of: "=") else { continue }
                        let name = item[..<eq].trimmingCharacters(in: .whitespaces)
                        let val = item[item.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty { map[String(name)] = String(val) }
                    }
                }
                DispatchQueue.main.async {
                    self.lastKeys = map.keys.sorted()
                    completion(map)
                }
            }
        }
    }
}

struct LoginWebView: UIViewRepresentable {
    let url: String
    let session: LoginSession

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        session.webView = wv
        if let u = URL(string: url) {
            wv.load(URLRequest(url: u))
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    class Coordinator: NSObject, WKNavigationDelegate {
        let session: LoginSession
        init(session: LoginSession) { self.session = session }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 每次加载完刷新「已捕获的 Cookie 列表」（仅用于界面提示）
            session.capture { _ in }
        }
    }
}
