import SwiftUI

/// 设置子页 —— 图源（导入 / 管理 / 新建）
///
/// 从原「设置」长 Form 拆出（ARCHITECTURE §8.6）。
struct SourceSettingsView: View {
    @State private var showSourceImport = false
    @State private var showSourceEditor = false
    /// JS 源数量（导入/删除后刷新，作为入口行的角标）
    @State private var jsCount = 0

    /// JS 源入口行：带数量角标，让用户知道「里面有没有东西」。
    private var jSSourceRow: some View {
        HStack {
            Label("JS 源", systemImage: "curlybraces")
            Spacer()
            if jsCount > 0 {
                Text("\(jsCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.gray.opacity(0.12), in: Capsule())
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Button {
                    showSourceImport = true
                } label: {
                    Label("导入图源", systemImage: "square.and.arrow.down")
                }
                NavigationLink {
                    SourceListView()
                } label: {
                    Label("图源管理", systemImage: "square.stack.3d.up")
                }
                // 🔴 「手动过验证」入口 —— 图源显示「需过验证 / 一直重试」时的兜底。
                //    `AntiBot` 只能自动过一部分挑战，滑块/点选图片这类必须人工介入。
                // 🔎 规则调试器 —— 自建/改源的核心工具（写完规则立刻能验）
                NavigationLink {
                    RuleDebugView()
                } label: {
                    Label("规则调试器", systemImage: "ladybug")
                }
                NavigationLink {
                    ManualVerifyView()
                } label: {
                    Label("手动过验证", systemImage: "hand.raised")
                }
                Button {
                    showSourceEditor = true
                } label: {
                    Label("新建图源", systemImage: "plus.square")
                }

                // ── 已隐藏（用户要求：不删代码，只藏入口）──────────────────────────
                // 「导入重探补丁包」+「源核重探（自动更新）」两个入口不再显示。
                // 底层代码完整保留：Engine/ReprobePack.swift、UI/ReprobePackView.swift、
                // AppSettings.reprobePackUrl。要恢复功能，把下面两段取消注释即可。
                //
                // NavigationLink {
                //     ReprobePackView()
                // } label: {
                //     Label("导入重探补丁包", systemImage: "wand.and.stars")
                // }
            } header: {
                Text("图源管理")
            } footer: {
                Text("导入支持：粘贴 JSON / 文件 / 相册二维码 / 链接下载。图源即规则，App 不提供任何内容。")
                    .font(.caption2)
            }

            // ── 已隐藏（用户要求：不删代码，只藏入口）──────────────────────────
            // 恢复时：① 取消注释；② 在本结构体顶部加回 `@EnvironmentObject var s: AppSettings`。
            // Section("源核重探（自动更新）") {
            //     TextField("重探补丁包地址", text: $s.reprobePackUrl)
            //         .textInputAutocapitalization(.never)
            //         .autocorrectionDisabled()
            //         .keyboardType(.URL)
            //     NavigationLink {
            //         ReprobePackView()
            //     } label: {
            //         Label("去应用 / 更新", systemImage: "wand.and.stars")
            //     }
            //     Text("填好源核重探产出的补丁包地址后，进「重探补丁包」页面会自动拉取并列出可更新的源（保留你的启用状态与发现页栏目）。")
            //         .font(.caption2).foregroundStyle(.secondary)
            // }
        }
        .transparentScrollBackground()
        .navigationTitle("图源")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSourceImport) {
            ImportSheet(onDone: {
                NotificationCenter.default.post(name: .hmdSourcesChanged, object: nil)
            })
        }
        .sheet(isPresented: $showSourceEditor) {
            NavigationStack {
                SourceEditorView(source: nil) {
                    NotificationCenter.default.post(name: .hmdSourcesChanged, object: nil)
                }
            }
        }
        .task { jsCount = JSSourceStore.count() }
        .onReceive(NotificationCenter.default.publisher(for: .hmdJSSourcesChanged)) { _ in
            jsCount = JSSourceStore.count()
        }
    }
}
