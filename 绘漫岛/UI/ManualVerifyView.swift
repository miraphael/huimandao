import SwiftUI
import WebKit

/// 手动过验证 —— 卡在人机验证（Cloudflare / 盾 / 滑块）时的兜底入口。
///
/// 🔴 为什么需要：`AntiBot` 能自动过**一部分**挑战（把页面丢进 WebView 渲染、
///    等它自己放行、再把 `cf_clearance` 之类存进 `CookieStore`），
///    但**需要人工介入**的（滑块拖动、点选图片、勾选「我不是机器人」）它做不到，
///    用户看到的就是「需过验证 / 一直重试」。
///
///    这个页面给一个**真实的 WKWebView**：用户自己点一下把验证过掉，
///    然后把 WebView 里所有 Cookie 倒进 `CookieStore`，
///    后续 `HttpFetcher` 的请求（会自动带上该 host 的 Cookie）就能通过。
///
/// 用法：填站点地址（通常直接填图源的 bookSourceUrl）→ 过验证 → 点「保存验证结果」。
struct ManualVerifyView: View {
    /// 预填地址（从图源管理进来时带上该源的域名）
    var presetURL: String = ""

    @State private var urlText: String = ""
    @State private var goURL: URL? = nil
    @State private var savedMsg: String = ""
    @State private var savedCount = 0
    @State private var reloadToken = 0

    var body: some View {
        VStack(spacing: 0) {
            // ── 地址栏 ──
            HStack(spacing: 8) {
                TextField("https://站点地址", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.callout)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                Button("打开") { open() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            // ── 提示条 ──
            if !savedMsg.isEmpty {
                Text(savedMsg)
                    .font(.caption)
                    .foregroundStyle(savedCount > 0 ? Color.green : Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            } else {
                Text("在下方页面里完成人机验证（拖动滑块 / 点选图片等），然后点「保存验证结果」。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }

            // ── 真实 WebView ──
            if let u = goURL {
                VerifyWebView(url: u, reloadToken: reloadToken)
                    .id("\(u.absoluteString)#\(reloadToken)")
            } else {
                Spacer()
                // ⚠️ 必须用项目自己的 `EmptyState` —— 部署目标是 **iOS 16**，
                //    系统 `ContentUnavailableView` 是 iOS 17+，直接写会**编译失败**。
                EmptyState(title: "还没有打开页面", systemImage: "hand.raised.slash",
                           description: "在上面的输入框填站点地址，点「打开」")
                Spacer()
            }

            // ── 底部操作 ──
            HStack(spacing: 10) {
                Button {
                    reloadToken &+= 1
                } label: {
                    Label("重新加载", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(goURL == nil)

                Spacer()

                Button {
                    save()
                } label: {
                    Label("保存验证结果", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(goURL == nil)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .navigationTitle("手动过验证")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if urlText.isEmpty, !presetURL.isEmpty { urlText = presetURL }
            if goURL == nil, !urlText.isEmpty { open() }
        }
    }

    private func open() {
        var s = urlText.trimmingCharacters(in: .whitespaces)
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        guard let u = URL(string: s), u.host != nil else {
            savedMsg = "地址不合法"; savedCount = 0; return
        }
        // 自动补全到根路径 —— 图源给的往往是 `https://site.com`（没有结尾斜杠）
        urlText = u.absoluteString
        savedMsg = ""
        goURL = u
    }

    /// 把 WebView 里所有 Cookie 倒进 `CookieStore`（按 host 分组）
    private func save() {
        guard let host = goURL?.host else { return }
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            var n = 0
            for c in cookies {
                // 只收当前站及其子域的 Cookie，避免把别的站的东西写进来
                let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
                guard host == d || host.hasSuffix("." + d) else { continue }
                // 复用与正常请求同一套解析（`name=value; ...`）
                CookieStore.parseAndStore(host: host, setCookie: "\(c.name)=\(c.value)")
                n += 1
            }
            DispatchQueue.main.async {
                savedCount = n
                savedMsg = n > 0
                    ? "✅ 已保存 \(n) 个 Cookie（\(host)），现在回图源里重试即可。"
                    : "⚠️ 没抓到 \(host) 的 Cookie —— 可能是验证还没过，或者该站用的是别的机制。"
                DiagLog.event("verify", "save", "手动过验证：host=\(host) 保存 \(n) 个 Cookie")
            }
        }
    }
}

/// 承载验证页的 WKWebView（与 `WebViewRuleEngine` 共用持久化 DataStore，
/// 这样 Cookie / localStorage 与自动过挑战那条路是一致的）
private struct VerifyWebView: UIViewRepresentable {
    let url: URL
    let reloadToken: Int

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.allowsBackForwardNavigationGestures = true
        w.load(URLRequest(url: url))
        return w
    }

    func updateUIView(_ w: WKWebView, context: Context) {
        // `reloadToken` 变化 → 重新加载（`reload()` 对已被挑战页替换的页面常常无效）
        if w.url == nil { w.load(URLRequest(url: url)) }
    }
}
