import SwiftUI
import UIKit

/// 设置子页 —— 存储与诊断
///
/// 从原「设置」长 Form 拆出（ARCHITECTURE §8.6）。
/// ⚠️ 「清理缓存」只清图片缓存，**不得误删下载章节与收藏文件**（见 `CacheCleaner`）。
struct StorageDiagSettingsView: View {
    @State private var msg = ""
    /// 🔴 清缓存加二次确认 —— 原来点一下**立刻执行**，误触后所有图片缓存全没，
    ///    下次开漫画要全部重新下载。（由智能体「设置」发现）
    @State private var showClearConfirm = false

    var body: some View {
        Form {
            Section("缓存") {
                Button("清理缓存", role: .destructive) { showClearConfirm = true }
                    .confirmationDialog("确定清理图片缓存？", isPresented: $showClearConfirm,
                                        titleVisibility: .visible) {
                        Button("清理", role: .destructive) {
                            CacheCleaner.clear()
                            msg = "图片缓存已清理"
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("只清理图片缓存，不会删除已下载的章节与收藏。清理后首次打开漫画需要重新下载图片。")
                    }
                Text("只清理图片缓存，不会删除已下载的章节与收藏。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section("诊断") {
                NavigationLink {
                    SourceDiagnoseView()
                } label: {
                    HStack {
                        Image(systemName: "stethoscope")
                        Text("图源连通性诊断")
                    }
                }
                Text("逐段探测：详情页 → 章节列表 → 正文页 → 图片 CDN，直接告诉你是哪一环断了")
                    .font(.caption2).foregroundStyle(.secondary)
                NavigationLink {
                    DiagLogView()
                } label: {
                    HStack {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text("诊断日志")
                        Spacer()
                        Text("\(DiagLog.count())").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("记录最近 400 条操作链路（同一 session id 属于同一次操作）。只记数量/耗时/状态，不记正文与凭据。")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("导出崩溃日志") {
                    let logs = CrashCatcher.pendingLogs()
                    if logs.isEmpty {
                        msg = "暂无崩溃日志"
                    } else {
                        let av = UIActivityViewController(activityItems: logs, applicationActivities: nil)
                        UIApplication.shared.topViewController()?.present(av, animated: true)
                    }
                }
                if !msg.isEmpty {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .transparentScrollBackground()
        .navigationTitle("存储与诊断")
        .navigationBarTitleDisplayMode(.inline)
    }
}
