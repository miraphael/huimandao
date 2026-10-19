import SwiftUI

/// 分组管理（2026-10-19）
///
/// 为什么要单独一页：分组原来只活在**工具栏的下拉菜单**里，而菜单里没有「左滑」这个手势。
/// 想用左滑删除，分组就必须先变成一个**列表**——所以这里给分组一个正经的管理页：
///   · 点一行 = 按该分组筛选书架
///   · 左滑一行 = 删除分组（组里的书移回「未分组」，不会删书）
///
/// 交互取舍：左滑删除**不再二次确认**。理由是这一步只删分类、不动书，
/// 误触的代价是「分组没了，书还在未分组里」，可以重新建组再拖回去。
struct GroupManageView: View {
    let groups: [(id: Int64, name: String)]
    let selectedGroup: Int64?
    /// 选中某个分组（nil = 全部）后回调，由父视图刷新书架
    var onSelect: (Int64?) -> Void
    /// 分组被增删后回调，由父视图重新读库
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var counts: [Int64: Int] = [:]
    @State private var showNewGroup = false
    @State private var newGroupName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(title: "全部", count: nil, isSelected: selectedGroup == nil) {
                        onSelect(nil)
                        dismiss()
                    }
                }

                Section {
                    if groups.isEmpty {
                        Text("还没有分组")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(groups, id: \.id) { g in
                        row(title: g.name, count: counts[g.id] ?? 0, isSelected: selectedGroup == g.id) {
                            onSelect(g.id)
                            dismiss()
                        }
                        // 左滑删除：只删分类，组里的书移回「未分组」
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                _ = ComicRepository.shared.deleteGroup(id: g.id)
                                counts = ComicRepository.shared.groupCounts()
                                onChanged()
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("分组")
                } footer: {
                    Text("左滑分组可删除。组里的漫画会移到「未分组」，不会被删除。")
                }
            }
            .navigationTitle("分组")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewGroup = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("新建分组", isPresented: $showNewGroup) {
                TextField("分组名", text: $newGroupName)
                Button("创建") {
                    let n = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !n.isEmpty else { return }
                    _ = ComicRepository.shared.createGroup(name: n)
                    newGroupName = ""
                    counts = ComicRepository.shared.groupCounts()
                    onChanged()
                }
                Button("取消", role: .cancel) { newGroupName = "" }
            }
        }
        .onAppear { counts = ComicRepository.shared.groupCounts() }
    }

    /// 一行：名称 + 本数 + 当前选中打勾
    @ViewBuilder
    private func row(title: String, count: Int?, isSelected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if let count {
                    Text("\(count) 本")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
    }
}
