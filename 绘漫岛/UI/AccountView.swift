import SwiftUI

/// 账号页 —— 本地阅读档案 + 阅读统计 + 跨设备同步（走 WebDAV）。
///
/// 说明：本项目没有自建服务端，「账号」是本地档案（见 AccountStore 注释）。
/// 想真正跨设备，就在「设置 → 备份(WebDAV)」里配好 WebDAV，
/// 这里的「同步」按钮会把账号 + 书架 + 图源一起推上去。
struct AccountView: View {
    @EnvironmentObject var s: AppSettings
    @State private var acc = AccountStore.load()
    @State private var editing = false
    @State private var draftName = ""
    @State private var draftAvatar = "🐱"
    @State private var syncMsg = ""
    @State private var syncing = false

    private let avatars = ["🐱", "🦊", "🐼", "🐶", "🐰", "🐯", "🦁", "🐸", "🐧", "🦄", "👾", "🎃"]

    var body: some View {
        List {
            if acc.isRegistered {
                profileSection
                statsSection
                syncSection
                dangerSection
            } else {
                registerSection
            }
        }
        .transparentScrollBackground()
        .navigationTitle("账号")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            var a = AccountStore.load()
            if a.isRegistered { AccountStore.refreshStats(into: &a) }
            acc = a
        }
    }

    // MARK: - 未注册

    private var registerSection: some View {
        Section {
            VStack(spacing: 14) {
                Text("还没有账号")
                    .font(.headline)
                Text("创建一个本地档案，用来记录你的阅读统计，并可跨设备同步书架与图源。")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    acc = AccountStore.register(nickname: "漫画读者", avatar: avatars.randomElement() ?? "🐱")
                    var a = acc
                    AccountStore.refreshStats(into: &a)
                    acc = a
                    NotificationCenter.default.post(name: .hmdAccountChanged, object: nil)
                } label: {
                    Text("一键创建本地账号").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - 已注册

    private var profileSection: some View {
        Section {
            HStack(spacing: 16) {
                Text(acc.avatar)
                    .font(.system(size: 44))
                    .frame(width: 72, height: 72)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    if editing {
                        TextField("昵称", text: $draftName)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Text(acc.nickname).font(.title3).bold()
                    }
                    Text("ID \(acc.userID)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if acc.createdAt > 0 {
                        Text("创建于 " + Date(timeIntervalSince1970: TimeInterval(acc.createdAt) / 1000)
                            .formatted(date: .numeric, time: .omitted))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)

            if editing {
                // 头像选择
                VStack(alignment: .leading, spacing: 8) {
                    Text("选个头像").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                        ForEach(avatars, id: \.self) { a in
                            Text(a)
                                .font(.system(size: 26))
                                .frame(width: 44, height: 44)
                                .background(draftAvatar == a ? Color.accentColor.opacity(0.22) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 10))
                                .onTapGesture { draftAvatar = a }
                        }
                    }
                }
                HStack {
                    Button("取消") { editing = false }
                    Spacer()
                    Button("保存") {
                        acc.nickname = draftName.isEmpty ? acc.nickname : draftName
                        acc.avatar = draftAvatar
                        AccountStore.save(acc)
                        editing = false
                        NotificationCenter.default.post(name: .hmdAccountChanged, object: nil)
                    }
                    .bold()
                }
            } else {
                Button("编辑资料") {
                    draftName = acc.nickname
                    draftAvatar = acc.avatar
                    editing = true
                }
            }
        }
    }

    private var statsSection: some View {
        Section("阅读统计") {
            statRow("在书架", "\(acc.booksRead)", "books.vertical")
            statRow("已读章节", "\(acc.chaptersRead)", "book.pages")
            statRow("累计时长", "约 \(acc.totalMinutes) 分钟", "clock")
            statRow("连续阅读", "\(acc.streakDays) 天", "flame")
            Text("统计为本地估算值（时长按 3 分钟/话折算）。数据只存在这台设备上，除非你手动同步。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func statRow(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var syncSection: some View {
        Section("跨设备同步") {
            if s.webdavUrl.isEmpty {
                Text("还没配置 WebDAV。到「设置 → 备份(WebDAV)」填好地址与账号，回来后即可同步。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("服务：\(s.webdavUrl)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button {
                    Task { await sync() }
                } label: {
                    HStack {
                        if syncing { ProgressView().scaleEffect(0.7) }
                        Text(syncing ? "同步中…" : "立即同步（上传账号+书架+图源）")
                    }
                }
                .disabled(syncing)
            }
            if !syncMsg.isEmpty {
                Text(syncMsg).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var dangerSection: some View {
        Section {
            Button("退出登录（仅清除本机账号）", role: .destructive) {
                AccountStore.logout()
                acc = UserAccount()
                NotificationCenter.default.post(name: .hmdAccountChanged, object: nil)
            }
        } footer: {
            Text("只清除账号档案，书架、历史、图源都不会删除。")
        }
    }

    private func sync() async {
        syncing = true
        syncMsg = ""
        var a = acc
        AccountStore.refreshStats(into: &a)
        acc = a
        // 走统一的「先版本文件、再 latest」流程 —— 中途失败不会把唯一一份备份写坏
        let r = await BackupManager.webdavBackup(cfg: (s.webdavUrl, s.webdavUser, s.webdavPass))
        syncMsg = (r.ok ? "✅ 同步成功：" : "❌ 同步失败：") + r.detail
        syncing = false
    }
}
