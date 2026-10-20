import SwiftUI
import UIKit

/// 图源 → 二维码：**每个图源一张码**。
///
/// 单张码容量有限（byte 2953 / 字母数字 4296），把多个源硬塞进一张就必须
/// 丢字段 —— 旧版丢的正是「发现栏目」，导致对方导入后漫画台空掉（v128 的坑）。
/// 改成「一源一码」后，每个源都能**完整保留全部字段**，只是要逐张扫。
struct SourceQRExportView: View {
    @Environment(\.dismiss) private var dismiss
    /// 要导出的源；空数组表示「全部已启用的」
    let sources: [ComicSource]

    struct Item: Identifiable {
        let id = UUID()
        let name: String
        let result: SourceQRCodec.Result
        let image: UIImage
    }

    @State private var items: [Item] = []
    @State private var index = 0
    @State private var failMsg: String? = nil
    @State private var toast: String? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !items.isEmpty, index < items.count {
                        let it = items[index]
                        Image(uiImage: it.image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .padding(12)
                            .background(Color.white)
                            .overlay(Rectangle().stroke(Color.primary.opacity(0.85), lineWidth: 2))
                            .padding(.horizontal, 18)
                            .padding(.top, 8)

                        VStack(spacing: 6) {
                            Text("第 \(index + 1) / \(items.count) 个图源")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(it.name)
                                .font(.callout).fontWeight(.semibold)
                            Text("压缩后 \(it.result.chars) 字符")
                                .font(.caption2).foregroundStyle(.secondary)

                            if !it.result.dropped.isEmpty {
                                Text("本张已省略：" + it.result.dropped.joined(separator: "、"))
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 20)
                            }
                        }
                        .padding(.horizontal, 16)

                        if items.count > 1 {
                            HStack(spacing: 12) {
                                Button {
                                    if index > 0 { index -= 1 }
                                } label: {
                                    Label("上一个", systemImage: "chevron.left")
                                        .font(.callout).fontWeight(.medium)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(Color(.secondarySystemGroupedBackground),
                                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(index == 0)

                                Button {
                                    if index + 1 < items.count { index += 1 }
                                } label: {
                                    Label("下一个", systemImage: "chevron.right")
                                        .font(.callout).fontWeight(.medium)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(Color(.secondarySystemGroupedBackground),
                                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(index + 1 >= items.count)
                            }
                            .padding(.horizontal, 18)
                        }

                        Button {
                            if index < items.count {
                                UIImageWriteToSavedPhotosAlbum(items[index].image, nil, nil, nil)
                                toast = "已保存本张到相册"
                            }
                        } label: {
                            Label("保存本张到相册", systemImage: "square.and.arrow.down")
                                .font(.callout).fontWeight(.medium)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(Color(.secondarySystemGroupedBackground),
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 18)

                        Text("每个图源一张码，逐张扫码导入（对方：App → 图源 → 导入图源 → 相机扫码）")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    } else if let failMsg {
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 40)).foregroundStyle(.orange)
                            Text("二维码生成失败").font(.callout).fontWeight(.medium)
                            Text(failMsg).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.top, 60)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "qrcode").font(.system(size: 40)).foregroundStyle(.secondary)
                            Text("正在生成…").font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(.top, 60)
                    }
                }
                .padding(.bottom, 28)
            }
            .navigationTitle("图源二维码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.callout)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 8)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                if self.toast == toast { self.toast = nil }
                            }
                        }
                }
            }
            .onAppear { rebuild() }
        }
    }

    private func rebuild() {
        let list = sources.isEmpty
            ? ComicRepository.shared.allSources(includeDisabled: false)
            : sources
        guard !list.isEmpty else {
            failMsg = "没有可导出的图源"
            return
        }

        var out: [Item] = []
        for s in list {
            let json = SourceCodec.exportJson([s], pretty: false)
            guard let r = SourceQRCodec.encode(json: json),
                  let img = SourceQRCodec.image(r.payload) else {
                DiagLog.event("qr", "export", "❌ 源「\(s.bookSourceName)」生成失败（跳过）")
                continue
            }
            out.append(Item(name: s.bookSourceName, result: r, image: img))
        }
        guard !out.isEmpty else {
            failMsg = "没有能生成二维码的图源"
            return
        }
        items = out
        index = 0
        DiagLog.event("qr", "export",
                      "\(list.count) 个源 → 一源一码，共 \(out.count) 张；字符 " +
                      out.map { "\($0.result.chars)" }.joined(separator: "/"))
    }
}
