import SwiftUI

/// 下载任务列表 —— 对应 DownloadTaskActivity：进度/状态/错误
///
/// `embedded`：被「漫画」标签页包在它的 NavigationStack 里时传 true，
/// 此时**不再自带** NavigationStack（否则会出现二层导航栏、标题重复）。
struct DownloadTasksView: View {
    var embedded: Bool = false
    @ObservedObject var dm = DownloadManager.shared
    @State private var offlineCount = 0
    @State private var offlineSize: Int64 = 0
    @State private var confirmClear = false
    /// 批量操作后的提示（不静默：用户点了要知道结果）
    @State private var msg = ""

    /// 队列概览 —— 让「暂停/排队/失败/完成」各自多少一目了然
    private var queueFooter: String {
        var parts: [String] = []
        if dm.paused { parts.append("已暂停（当前这一章会下完）") }
        if dm.pendingCount > 0 { parts.append("排队 \(dm.pendingCount)") }
        if dm.failedCount > 0 { parts.append("失败 \(dm.failedCount)") }
        let done = dm.tasks.filter { $0.state == 0 }.count
        if done > 0 { parts.append("完成 \(done)") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
        }
    }

    private var content: some View {
        List {
            // ── 正在下载（按**整本漫画**聚合）──────────────────────────────
            // ⚠️ 旧实现是「一章一行」：一本 50 话的漫画就是 50 行，
            //    用户看不出「这本下到哪了」，只能一行行数。
            //    现在一行一本：`12/50 章`，展开才看单章。
            if !dm.activeGroups.isEmpty {
                Section {
                    ForEach(dm.activeGroups) { g in comicRow(g) }
                } header: {
                    Text("正在下载")
                } footer: {
                    Text(queueFooter).font(.caption2).foregroundStyle(.secondary)
                }
            }

            // ── 已结束（完成 / 失败待处理）─────────────────────────────────
            if !dm.settledGroups.isEmpty {
                Section {
                    ForEach(dm.settledGroups) { g in comicRow(g) }
                } header: {
                    Text("已完成 / 待处理")
                } footer: {
                    if dm.settledGroups.contains(where: { $0.failedChapters > 0 }) {
                        Text("展开可见失败的是哪几话；也可用右上角「重试全部失败」。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            // 已下载（离线可读）的章节汇总 —— 让「下载到底存哪了、占多大」可见
            Section {
                LabeledContent("已下载章节", value: "\(offlineCount) 话")
                LabeledContent("占用空间", value: byteText(offlineSize))
                Text("已下载的章节打开时**不联网**，直接从本地读取。在章节列表长按可删除单话下载。")
                    .font(.caption2).foregroundStyle(.secondary)
                if offlineCount > 0 {
                    Button("清空全部下载", role: .destructive) { confirmClear = true }
                }
            } header: {
                Text("离线内容")
            }
        }
        .transparentScrollBackground()
        .navigationTitle("下载任务")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // 暂停 / 继续：批量下载几十话时，用户需要能先停下去干别的
                    if dm.paused {
                        Button { dm.resumeAll() } label: { Label("继续下载", systemImage: "play.fill") }
                            .disabled(dm.pendingCount == 0)
                    } else {
                        Button { dm.pauseAll() } label: { Label("暂停下载", systemImage: "pause.fill") }
                            .disabled(dm.pendingCount == 0)
                    }
                    Divider()
                    Button {
                        let n = dm.retryFailed()
                        msg = n > 0 ? "已重新排队 \(n) 个失败任务" : "没有失败的任务"
                    } label: {
                        Label("重试全部失败\(dm.failedCount > 0 ? "(\(dm.failedCount))" : "")",
                              systemImage: "arrow.clockwise")
                    }
                    .disabled(dm.failedCount == 0)
                    Button {
                        let n = dm.clearFinished()
                        msg = n > 0 ? "已清除 \(n) 条完成记录（文件保留）" : "没有已完成的记录"
                    } label: {
                        Label("清除已完成", systemImage: "checkmark.circle")
                    }
                    .disabled(!dm.tasks.contains { $0.state == 0 })
                    Button(role: .destructive) {
                        let n = dm.clearFailed()
                        msg = n > 0 ? "已清除 \(n) 条失败记录" : "没有失败的记录"
                    } label: {
                        Label("清除失败记录", systemImage: "trash")
                    }
                    .disabled(dm.failedCount == 0)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .overlay {
            if dm.tasks.isEmpty && offlineCount == 0 {
                EmptyState(title: "暂无下载任务", systemImage: "arrow.down.circle",
                           description: "在漫画详情或章节列表里选择章节下载")
            }
        }
        .confirmationDialog("确定清空全部已下载章节？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { clearAllOffline() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除磁盘上所有已下载的漫画图片，此操作不可恢复。")
        }
        .task {
            // 上次没下完的任务捞回来续跑（否则杀掉 App 后队列就丢了）
            dm.restorePersisted()
            refreshOffline()
        }
        .alert("提示", isPresented: Binding(
            get: { !msg.isEmpty },
            set: { if !$0 { msg = "" } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(msg)
        }
        .onReceive(NotificationCenter.default.publisher(for: .hmdDownloadsChanged)) { _ in
            refreshOffline()
        }
    }

    private func refreshOffline() {
        offlineCount = OfflineLibrary.shared.count()
        offlineSize = OfflineLibrary.shared.totalSize()
    }

    private func clearAllOffline() {
        let root = OfflineLibrary.shared.rootDir()
        let fm = FileManager.default
        if let comics = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for c in comics where c.lastPathComponent != "Inbox" {
                try? fm.removeItem(at: c)
            }
        }
        Database.shared.exec("DELETE FROM LOCAL_CHAPTER")
        Database.shared.exec("DELETE FROM TASK_BEAN")
        // ⚠️ 必须走 `cancelAllPending()` 而不是 `dm.tasks.removeAll()` ——
        //    后者只清内存里的任务列表，`DownloadManager` 内部的 `queue` 仍是满的，
        //    后台 `pump()` 会继续把整个队列下完并重新登记进离线库
        //    （用户看到「清空了，过一会儿文件又回来了」）。
        _ = dm.cancelAllPending()
        refreshOffline()
        NotificationCenter.default.post(name: .hmdDownloadsChanged, object: nil)
    }

    private func byteText(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: n)
    }

    // MARK: - 行构建

    /// 一整本漫画的行（可展开看单章）。
    ///
    /// 用 `DisclosureGroup` 而不是自己维护展开状态：它在 `List` 里有原生的展开动画
    /// 与无障碍支持，且**不会**因为 `dm.tasks` 高频刷新而丢掉展开状态。
    @ViewBuilder
    private func comicRow(_ g: ComicDownloadGroup) -> some View {
        DisclosureGroup {
            ForEach(g.tasks) { t in
                chapterRow(t)
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(g.comicName).font(.callout).lineLimit(1)
                    Spacer(minLength: 8)
                    groupBadge(g)
                }
                // 进度条按「章节」算 —— 页数只有下载中/已完成才知道，做不了权威总进度
                ProgressView(value: g.progress)
                Text(g.summary).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .swipeActions {
            Button(role: .destructive) {
                removeGroup(g)
            } label: { Label("删除整本", systemImage: "trash") }
        }
    }

    /// 展开后的单章行
    @ViewBuilder
    private func chapterRow(_ t: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(t.chapterName.isEmpty ? t.chapterUrl : t.chapterName)
                    .font(.caption).lineLimit(1)
                Spacer(minLength: 8)
                statusBadge(t.state)
            }
            if t.state == 3 && t.max > 0 {
                ProgressView(value: Double(t.progress), total: Double(max(t.max, 1)))
                Text("\(t.progress)/\(t.max) 张").font(.caption2).foregroundStyle(.secondary)
            }
            if !t.error.isEmpty {
                Text(t.error).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                dm.removeDownload(chapterUrl: t.chapterUrl, origin: t.origin, noteUrl: t.noteUrl)
                refreshOffline()
            } label: { Label("删除", systemImage: "trash") }
        }
    }

    /// 整本的聚合状态徽标
    @ViewBuilder
    private func groupBadge(_ g: ComicDownloadGroup) -> some View {
        if g.isAllDone {
            Text("完成").font(.caption2).foregroundStyle(.green)
        } else if g.runningChapters > 0 {
            Text("下载中").font(.caption2).foregroundStyle(.tint)
        } else if g.waitingChapters > 0 {
            Text("排队").font(.caption2).foregroundStyle(.secondary)
        } else if g.failedChapters > 0 {
            Text("有失败").font(.caption2).foregroundStyle(.red)
        } else {
            Text("已停止").font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// 删掉一整本（组内所有章节任务）
    private func removeGroup(_ g: ComicDownloadGroup) {
        for t in g.tasks {
            dm.removeDownload(chapterUrl: t.chapterUrl, origin: t.origin, noteUrl: t.noteUrl)
        }
        refreshOffline()
    }

    @ViewBuilder
    private func statusBadge(_ state: Int) -> some View {
        switch state {
        case 2: Text("等待").font(.caption2).foregroundStyle(.secondary)
        case 3: Text("下载中").font(.caption2).foregroundStyle(.tint)
        case 5: Text("失败").font(.caption2).foregroundStyle(.red)
        default: Text("完成").font(.caption2).foregroundStyle(.green)
        }
    }
}
