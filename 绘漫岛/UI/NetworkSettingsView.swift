import SwiftUI

/// 设置子页 —— 网络
///
/// 从原「设置」长 Form 拆出（ARCHITECTURE §8.6）。
/// 放 DoH、UA、本地 Web 编辑器端口与「搜索线程」（搜索是网络行为，不属阅读类别）。
struct NetworkSettingsView: View {
    @EnvironmentObject var s: AppSettings
    @State private var webRunning = false

    var body: some View {
        Form {
            Section {
                Toggle("DoH 防污染(腾讯/阿里)", isOn: $s.dohEnabled)
                TextField("自定义 User-Agent", text: $s.customUA)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                // 🔴 「自动刷新书架」开关已移除：它绑的 `autoRefreshComic` **全项目没有任何
                //    消费点**，真正的自动追更由「下载与追更」页的 `hmd_follow_auto` +
                //    `FollowUpdater.shouldAutoRun` 驱动。留着它 = 用户拨了没反应
                //    （甚至以为关掉了但实际还在跑）。（由智能体「界面」「设置」分别发现）
                Stepper("搜索线程 \(s.searchThreads)", value: $s.searchThreads, in: 1...64)
            } header: {
                Label("网络", systemImage: "wifi")
            } footer: {
                Text("DoH：DNS 被污染的图源域名会自动经 DoH 解析并 IP 直连。\n搜索线程：多源搜索的并发数，调高更快，但对网络与设备压力更大。")
            }
            Section {
                Stepper("Web端口 \(s.webPort)", value: $s.webPort, in: 1024...65530)
                Button(webRunning ? "停止 Web 服务" : "启动 Web 服务(图源编辑器)") {
                    if webRunning { WebServer.shared.stop() } else { WebServer.shared.start(port: UInt16(s.webPort)) }
                    webRunning = WebServer.shared.isRunning
                }
                if webRunning {
                    // ⚠️ 必须带上访问令牌（`?t=`）—— 所有 API 端点都要求鉴权，
                    //    不带令牌打开只会拿到 401。见 `WebServer.token`。
                    Text("http://\(LocalIP.primary() ?? "127.0.0.1"):\(s.webPort)/?t=\(WebServer.token)")
                        .font(.caption).textSelection(.enabled)
                }
            } header: {
                Label("本地 Web 服务（图源编辑器）", systemImage: "safari")
            } footer: {
                Text("在电脑浏览器打开上面的地址，即可用原版网页编辑器编辑图源。\n"
                     + "地址里的 ?t=… 是访问令牌，请勿分享给他人 —— 同一 Wi-Fi 下持有令牌的人可以读写你的图源。")
            }
        }
        .transparentScrollBackground()
        .navigationTitle("网络")
        .navigationBarTitleDisplayMode(.inline)
        // ⚠️ 必须同步真实状态：`WebServer` 是全局单例，`SourceListView.webShare()`
        //    也会启动它。若用户从那里启动后再进本页，`webRunning` 初值 false
        //    会让按钮显示「启动 Web 服务」而服务其实在跑 —— 状态骗人。
        .onAppear { webRunning = WebServer.shared.isRunning }
    }
}
