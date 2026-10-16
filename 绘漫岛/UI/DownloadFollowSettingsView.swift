import SwiftUI

/// 设置子页 —— 下载与追更
///
/// 从原「设置」长 Form 拆出（ARCHITECTURE §8.6）。
/// ⚠️ `followAuto` / `followHours` 的 UserDefaults 键（`hmd_follow_auto` /
///    `hmd_follow_interval_hours`）**必须与原实现完全一致** —— `FollowUpdater`
///    读的就是这两个键，改名会让引擎行为与设置项脱节。
struct DownloadFollowSettingsView: View {
    @EnvironmentObject var s: AppSettings
    /// 追更引擎（单例，@ObservedObject 不拥有它）
    @ObservedObject private var follower = FollowUpdater.shared
    @AppStorage("hmd_follow_auto") private var followAuto = true
    @AppStorage("hmd_follow_interval_hours") private var followHours = 6.0

    var body: some View {
        Form {
            Section {
                Stepper("下载线程 \(s.downloadThreads)", value: $s.downloadThreads, in: 1...10)
                NavigationLink {
                    // 已在设置页的 NavigationStack 内 → embedded（避免双层导航栏）
                    DownloadTasksView(embedded: true)
                } label: {
                    Label("下载管理", systemImage: "arrow.down.circle")
                }
            } header: {
                Label("下载", systemImage: "arrow.down.circle")
            } footer: {
                Text("已下载的章节打开时不联网，直接从本地读取。在章节列表长按可删除单话下载。")
            }
            Section {
                Toggle("自动检查更新", isOn: $followAuto)
                Stepper("间隔 \(Int(followHours)) 小时", value: $followHours, in: 1...72)
                    .disabled(!followAuto)
                Stepper("追更线程 \(s.refreshThreads)", value: $s.refreshThreads, in: 1...8)
                LabeledContent("上次追更", value: follower.lastRunText)
                if follower.running {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.7)
                        Text("正在检查 \(follower.done)/\(follower.total)…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button("立即检查更新") { Task { await FollowUpdater.shared.checkAll() } }
                }
                Button("全部标为已读") { FollowUpdater.shared.markAllRead() }
            } header: {
                Label("追更", systemImage: "arrow.triangle.2.circlepath")
            } footer: {
                Text("书架里的漫画会自动检查有没有新章节，有更新时封面上显示「N 章」角标。")
            }
        }
        .transparentScrollBackground()
        .navigationTitle("下载与追更")
        .navigationBarTitleDisplayMode(.inline)
    }
}
