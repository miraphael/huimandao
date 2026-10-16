import SwiftUI
import UniformTypeIdentifiers

/// 设置子页 —— 备份同步（WebDAV）
///
/// 从原「设置」长 Form 拆出（ARCHITECTURE §8.6）。
/// 分「凭据 / 备份与恢复」两块；恢复走「预览 → 二次确认 → 先快照」的安全流程。
struct BackupSettingsView: View {
    @EnvironmentObject var s: AppSettings
    @State private var backupMsg = ""
    @State private var showRestorePicker = false
    /// 恢复前预览（只解析不写入）—— 用户确认后才真正恢复
    @State private var pendingRestore: BackupManager.RestoreReport?
    @State private var pendingRestoreText: String?
    @State private var confirmRestore = false
    @State private var confirmRollback = false

    var body: some View {
        Form {
            Section {
                TextField("WebDAV 地址", text: $s.webdavUrl).textInputAutocapitalization(.never)
                TextField("账号", text: $s.webdavUser)
                SecureField("密码", text: $s.webdavPass)
                Text("建议使用 HTTPS 地址。密码仅保存在本机，不会随备份上传。")
                    .font(.caption2).foregroundStyle(.secondary)
            } header: {
                Text("WebDAV 凭据")
            }

            Section {
                Button("备份到云端") {
                    Task {
                        let r = await BackupManager.webdavBackup(
                            cfg: (s.webdavUrl, s.webdavUser, s.webdavPass))
                        backupMsg = (r.ok ? "✅ " : "❌ ") + r.detail
                    }
                }
                Button("从云端恢复") {
                    Task {
                        guard let text = await BackupManager.webdavGet(
                            path: BackupManager.remoteLatest,
                            cfg: (s.webdavUrl, s.webdavUser, s.webdavPass)) else {
                            backupMsg = "❌ 读取云端备份失败，检查地址/账号/网络"
                            return
                        }
                        // 恢复即「接受云端版本」——冲突标记到此解除（ETag 也已在 webdavGet 里刷新）
                        BackupManager.clearConflict()
                        pendingRestore = BackupManager.inspect(text)
                        pendingRestoreText = text
                        confirmRestore = true
                    }
                }
                Button("导出备份到文件") {
                    let data = BackupManager.makePayload().encode() ?? Data()
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hmd_backup.json")
                    try? data.write(to: url)
                    let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                    UIApplication.shared.topViewController()?.present(av, animated: true)
                }
                Button("从文件恢复") { showRestorePicker = true }
                    .fileImporter(isPresented: $showRestorePicker, allowedContentTypes: [.json, .text, .data]) { result in
                        guard case .success(let url) = result else { return }
                        let secured = url.startAccessingSecurityScopedResource()
                        defer { if secured { url.stopAccessingSecurityScopedResource() } }
                        guard let t = try? String(contentsOf: url, encoding: .utf8) else {
                            backupMsg = "❌ 文件读不出来"
                            return
                        }
                        pendingRestore = BackupManager.inspect(t)
                        pendingRestoreText = t
                        confirmRestore = true
                    }
                if !backupMsg.isEmpty {
                    Text(backupMsg).font(.caption).foregroundStyle(.secondary)
                }
                // 并发写冲突提示：别的设备改过云端 latest，本次没覆盖。
                // 单独显示（而不是混进 backupMsg）—— 它不是「失败」，是「主动让位」，
                // 用户需要知道该先「从云端恢复」再重新备份，否则会一直以为同步成功了。
                if let c = BackupManager.lastConflict {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("云端有更新，本次未覆盖", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                        Text(c).font(.caption2).foregroundStyle(.secondary)
                        Text("建议：先点「从云端恢复」合并别人的改动，再重新备份。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Button("回滚到最近快照") { confirmRollback = true }
                    .disabled(BackupManager.snapshots().isEmpty)
                Text("恢复前会自动在本地存一份快照（保留最近 5 份），恢复错了可以回滚。恢复是**合并**，不会清空你现有的源和书架。")
                    .font(.caption2).foregroundStyle(.secondary)
            } header: {
                Text("备份与恢复")
            }
        }
        .transparentScrollBackground()
        .navigationTitle("备份")
        .navigationBarTitleDisplayMode(.inline)
        .alert("确认恢复备份", isPresented: $confirmRestore) {
            Button("恢复", role: .destructive) { performRestore() }
            Button("取消", role: .cancel) { pendingRestoreText = nil; pendingRestore = nil }
        } message: {
            if let r = pendingRestore {
                if let w = r.warnings.first {
                    Text("⚠️ \(w)")
                } else {
                    Text("\(r.origin)\n\n将合并导入：\(r.summary)\n\n恢复前会自动存一份本地快照。")
                }
            }
        }
        .alert("回滚到最近快照", isPresented: $confirmRollback) {
            Button("回滚", role: .destructive) { performRollback() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会用最近一份本地快照覆盖合并当前数据（同样是合并，不会清空）。适合「刚恢复错了」的场景。")
        }
    }

    /// 真正执行恢复：**先存快照再写**，这样恢复错了能回滚。
    private func performRestore() {
        guard let text = pendingRestoreText else { return }
        let snap = BackupManager.makeSnapshot()
        let r = BackupManager.restore(from: text)
        if r.ok {
            backupMsg = "✅ 恢复完成：\(r.summary)" + (snap == nil ? "（⚠️ 快照保存失败）" : "（已存快照）")
        } else {
            backupMsg = "❌ 恢复失败：" + (r.warnings.first ?? "备份内容为空或格式不支持")
        }
        pendingRestoreText = nil
        pendingRestore = nil
        NotificationCenter.default.post(name: .hmdSourcesChanged, object: nil)
    }

    private func performRollback() {
        guard let latest = BackupManager.snapshots().first else {
            backupMsg = "没有可用的本地快照"
            return
        }
        let r = BackupManager.rollback(to: latest)
        backupMsg = r.ok ? "✅ 已回滚：\(r.summary)" : "❌ 回滚失败：" + (r.warnings.first ?? "快照为空")
        NotificationCenter.default.post(name: .hmdSourcesChanged, object: nil)
    }
}
