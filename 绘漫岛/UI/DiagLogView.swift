import SwiftUI

/// 诊断日志查看器 —— 「刚才那次操作到底卡在哪一步」
///
/// 同一 `session` 的若干行属于同一次操作（详情/搜索/下载），按它串链路。
/// 日志默认只在内存里（环形缓冲，最多 400 条），需要留存时由用户显式导出。
struct DiagLogView: View {
    @State private var entries: [DiagLog.Entry] = []
    @State private var copied = false

    var body: some View {
        Group {
            if entries.isEmpty {
                EmptyState(title: "暂无诊断日志", systemImage: "doc.text.magnifyingglass",
                           description: "日志只保留最近 400 条。\n去搜索、打开一本漫画或下载一章，再回来看看。")
            } else {
                List {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(e.category)
                                    .font(.caption2).foregroundStyle(.tint)
                                Text(e.session)
                                    .font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Text(Self.timeText(e.at))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            Text(e.message)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 1)
                    }
                }
                .transparentScrollBackground()
                .listStyle(.plain)
            }
        }
        .navigationTitle("诊断日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        UIPasteboard.general.string = DiagLog.exportText()
                        copied = true
                    } label: {
                        Label("复制全部", systemImage: "doc.on.doc")
                    }
                    Button {
                        let url = FileManager.default.temporaryDirectory
                            .appendingPathComponent("hmd_diag_log.txt")
                        try? DiagLog.exportText().write(to: url, atomically: true, encoding: .utf8)
                        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                        UIApplication.shared.topViewController()?.present(av, animated: true)
                    } label: {
                        Label("导出为文件", systemImage: "square.and.arrow.up")
                    }
                    Divider()
                    Button(role: .destructive) {
                        DiagLog.clear()
                        reload()
                    } label: {
                        Label("清空日志", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .overlay(alignment: .bottom) {
            if copied {
                Text("已复制到剪贴板")
                    .font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 12)
            }
        }
        .task { reload() }
        .refreshable { reload() }
    }

    private func reload() {
        entries = DiagLog.recent(400)
        copied = false
    }

    private static func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: d)
    }
}
