import SwiftUI
import UIKit

/// 图源分组管理（对齐 Legado 的 `GroupManageDialog`）。
///
/// 分组不是独立的表，而是从每个源的 `bookSourceGroup`（逗号分隔）里汇总出来的，
/// 所以这里「重命名 / 删除分组」实际是**批量改写所有属于该分组的源**。
struct SourceGroupManageView: View {
    @Environment(\.dismiss) private var dismiss
    var onChanged: () -> Void

    @State private var groups: [(name: String, count: Int)] = []
    @State private var renaming: String? = nil
    @State private var renameText = ""
    @State private var deleting: String? = nil

    var body: some View {
        NavigationStack {
            Group {
                if groups.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "folder").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("还没有分组").font(.callout).foregroundStyle(.secondary)
                        Text("在图源列表勾选若干源 → ⋯ →「加入分组」").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    List {
                        ForEach(groups, id: \.name) { g in
                            HStack {
                                Image(systemName: "folder.fill").foregroundStyle(.tint)
                                Text(g.name)
                                Spacer()
                                Text("\(g.count) 个源").font(.caption).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                renameText = g.name
                                renaming = g.name
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    deleting = g.name
                                } label: { Label("删除", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("分组管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
            }
            .alert("重命名分组", isPresented: Binding(get: { renaming != nil },
                                                     set: { if !$0 { renaming = nil } })) {
                TextField("新分组名", text: $renameText)
                Button("保存") { rename(old: renaming ?? "", to: renameText) }
                Button("取消", role: .cancel) { renaming = nil }
            } message: {
                Text("会同时改掉所有属于该分组的图源")
            }
            .alert("删除分组「\(deleting ?? "")」？",
                   isPresented: Binding(get: { deleting != nil },
                                        set: { if !$0 { deleting = nil } })) {
                Button("删除", role: .destructive) { removeGroup(deleting ?? "") }
                Button("取消", role: .cancel) { deleting = nil }
            } message: {
                Text("只删「分组标签」，图源本身不会被删除。")
            }
            .onAppear { reload() }
        }
    }

    private func reload() {
        var map: [String: Int] = [:]
        for s in ComicRepository.shared.allSources() {
            for g in s.groupList { map[g, default: 0] += 1 }
        }
        groups = map.map { (name: $0.key, count: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func rename(old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !name.isEmpty, name != old else { return }
        for s in ComicRepository.shared.allSources() where s.groupList.contains(old) {
            let next = s.groupList.map { $0 == old ? name : $0 }
            ComicRepository.shared.setSourceGroups(url: s.bookSourceUrl, groups: next)
        }
        reload()
        onChanged()
    }

    private func removeGroup(_ name: String) {
        deleting = nil
        guard !name.isEmpty else { return }
        for s in ComicRepository.shared.allSources() where s.groupList.contains(name) {
            ComicRepository.shared.setSourceGroups(url: s.bookSourceUrl,
                                                  groups: s.groupList.filter { $0 != name })
        }
        reload()
        onChanged()
    }
}

/// 系统分享面板（用于「分享图源」：把 JSON 文本发给别人）
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
