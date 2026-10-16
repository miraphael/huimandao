import SwiftUI

/// 图源连通性诊断页 —— 选一个图源、填一个详情页地址，跑一遍全链路探测。
///
/// 面对的场景：用户说「XX 图源章节解析不出来，我挂了梯子」。以前只能猜，
/// 现在这里直接输出「是详情页不通 / 是选择器过期 / 还是图片 CDN 没走代理」。
struct SourceDiagnoseView: View {
    @EnvironmentObject var s: AppSettings
    @State private var sources: [ComicSource] = []
    @State private var selected: String = ""
    @State private var noteUrl: String = ""
    @State private var keyword: String = ""
    @State private var running = false
    @State private var report: SourceDiagnostics.Report?

    var body: some View {
        Form {
            Section("选择图源") {
                if sources.isEmpty {
                    Text("暂无图源").foregroundStyle(.secondary)
                } else {
                    Picker("图源", selection: $selected) {
                        ForEach(sources, id: \.bookSourceUrl) { src in
                            Text(src.bookSourceName).tag(src.bookSourceUrl)
                        }
                    }
                    TextField("图源详情页地址（可从搜索结果的地址栏粘贴）", text: $noteUrl)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("「详情页地址」随便填一本该图源的漫画页面即可，用于探测全链路。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    Task { await runDiagnose() }
                } label: {
                    HStack {
                        if running { ProgressView().scaleEffect(0.8) }
                        Text(running ? "检测中…" : "开始检测")
                    }
                }
                .disabled(running || selected.isEmpty)
                if running {
                    Text("会依次抓详情页、解析章节、抓正文、探图片域名，约 10~30 秒")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            if let r = report {
                Section("结论") {
                    Text(r.conclusion)
                        .font(.system(.body, design: .rounded))
                        .textSelection(.enabled)
                }
                Section("逐步结果") {
                    ForEach(Array(r.steps.enumerated()), id: \.offset) { _, st in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: icon(st.level))
                                    .foregroundStyle(color(st.level))
                                Text(st.title).font(.subheadline).bold()
                                Spacer()
                                if st.ms > 0 {
                                    Text("\(st.ms)ms").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Text(st.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .transparentScrollBackground()
        .navigationTitle("图源诊断")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            sources = ComicRepository.shared.allSources().sorted { $0.bookSourceName < $1.bookSourceName }
            if selected.isEmpty, let first = sources.first { selected = first.bookSourceUrl }
        }
    }

    private func runDiagnose() async {
        running = true
        report = nil
        defer { running = false }
        guard let src = sources.first(where: { $0.bookSourceUrl == selected }) else { return }
        var url = noteUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty {
            // 没填就用图源主页兜底（至少能测出「域名通不通」）
            url = src.bookSourceUrl
        }
        report = await SourceDiagnostics.run(source: src, noteUrl: url)
    }

    private func icon(_ l: SourceDiagnostics.Step.Level) -> String {
        switch l {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private func color(_ l: SourceDiagnostics.Step.Level) -> Color {
        switch l {
        case .ok: return .green
        case .warn: return .orange
        case .fail: return .red
        case .info: return .blue
        }
    }
}
