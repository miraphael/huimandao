import SwiftUI

/// ──────────────────────────────────────────────────────────────────────────
/// 图集收藏 —— 阅读时收藏的单张图，在这里集中浏览
///
/// 与「下载管理」的区别：下载是**整章**离线；收藏是**单张图**长期留存。
/// 两者目录分开（`Downloads/` vs `Favorites/`），清理互不影响。
/// ---------------------------------------------------------------------------
struct FavoritesView: View {
    @ObservedObject private var session = FavoriteSession.shared
    @State private var preview: FavoriteImage?
    @State private var confirmClear = false
    @State private var confirmPrune = false

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    var body: some View {
        Group {
            if session.items.isEmpty {
                EmptyState(title: "还没有收藏图片",
                           systemImage: "heart",
                           description: "在阅读器里点右上角的收藏按钮，就能把当前这一页存到这里。\n收藏的是原图，离线也能看。")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(session.items) { item in
                            Button { preview = item } label: {
                                FavoriteCell(item: item)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    session.remove(id: item.id)
                                } label: {
                                    Label("取消收藏", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }
            }
        }
        .navigationTitle("图集收藏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    LabeledContent("张数", value: "\(session.count)")
                    LabeledContent("占用", value: session.sizeText)
                    Divider()
                    Button {
                        confirmPrune = true
                    } label: {
                        Label("清理残留文件", systemImage: "wand.and.stars")
                    }
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Label("清空收藏", systemImage: "trash")
                    }
                    .disabled(session.items.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !session.items.isEmpty {
                Text("共 \(session.count) 张 · \(session.sizeText)")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
        }
        .onAppear { session.reload() }
        .sheet(item: $preview) { item in
            FavoritePreview(item: item) {
                session.remove(id: item.id)
                preview = nil
            }
        }
        .alert("清空收藏", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { session.removeAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除全部 \(session.count) 张收藏图片（\(session.sizeText)），不影响已下载的离线章节。")
        }
        .alert("清理残留文件", isPresented: $confirmPrune) {
            Button("清理") { _ = session.pruneOrphans() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除「有文件但数据库没有记录」的孤儿文件（通常是写入过程中被强杀留下的），不会动正常收藏。")
        }
        .alert("提示", isPresented: Binding(
            get: { !session.message.isEmpty },
            set: { if !$0 { session.message = "" } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(session.message)
        }
    }
}

/// 单个收藏格子 —— 缩略图 + 章节名
private struct FavoriteCell: View {
    let item: FavoriteImage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FavoriteThumb(url: FavoriteStore.shared.fileURL(for: item))
                .frame(height: 132)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(item.comicName.isEmpty ? "未命名" : item.comicName)
                .font(.caption2).lineLimit(1)
            Text("\(item.chapterName.isEmpty ? "未知章节" : item.chapterName) · 第\(item.imageIndex + 1)页")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// 缩略图加载。
///
/// ⚠️ 必须**降采样**（`preparingThumbnail`）：漫画原图动辄 1~2 MB、几千像素宽，
///    一屏 20 个格子直接解码原图 = 几十 MB 内存 + 明显卡顿。
///    解码放到 `Task.detached`，不占主线程。
private struct FavoriteThumb: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.gray.opacity(0.15)
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
        }
        .clipped()
        .task(id: url) {
            let path = url.path
            let img = await Task.detached(priority: .utility) { () -> UIImage? in
                guard let full = UIImage(contentsOfFile: path) else { return nil }
                return full.preparingThumbnail(of: CGSize(width: 320, height: 320)) ?? full
            }.value
            if !Task.isCancelled { image = img }
        }
    }
}

/// 大图预览 + 基本信息 + 取消收藏
private struct FavoritePreview: View {
    let item: FavoriteImage
    let onRemove: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                if let img = UIImage(contentsOfFile: FavoriteStore.shared.fileURL(for: item).path) {
                    Image(uiImage: img).resizable().scaledToFit()
                } else {
                    Text("图片文件已丢失，可取消收藏后重新收藏")
                        .foregroundStyle(.secondary).padding(40)
                }
            }
            .navigationTitle("第\(item.imageIndex + 1)页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { onRemove() } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.comicName.isEmpty ? "未命名" : item.comicName).font(.footnote)
                    Text("\(item.chapterName) · 图源 \(URL(string: item.origin)?.host ?? item.origin)")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file))")
                        .font(.caption2).foregroundStyle(.tertiary)
                    // 跳回原作品 —— 收藏的是单张图，想接着读要回到详情页选章节。
                    // ⚠️ 直接构造 `ReaderView` 需要完整 `ComicInfo`（含章节表），
                    //    这里没有；走详情页既准确又不用猜。
                    if !item.noteUrl.isEmpty {
                        NavigationLink {
                            ComicDetailView(noteUrl: item.noteUrl, origin: item.origin)
                        } label: {
                            Label("打开该漫画", systemImage: "book").font(.footnote)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.thinMaterial)
            }
        }
    }
}
