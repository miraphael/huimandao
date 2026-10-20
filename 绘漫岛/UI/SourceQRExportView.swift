import SwiftUI
import UIKit

/// 图源 → 二维码（**永远一张**）。
///
/// 一个二维码最多 2953 字节，所以导出时按「备注 → 发现栏目 → UA」逐级丢弃 + LZMA 压缩，
/// 尽量把选中的源全塞进一张；实在装不下只带前 N 个，并在这里写清楚。
struct SourceQRExportView: View {
    @Environment(\.dismiss) private var dismiss
    /// 要导出的源；空数组表示「全部已启用的」
    let sources: [ComicSource]

    @State private var result: SourceQRCodec.Result? = nil
    @State private var failMsg: String? = nil
    @State private var toast: String? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let r = result {
                        Image(uiImage: SourceQRCodec.image(r.payload) ?? UIImage())
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .padding(12)
                            .background(Color.white)
                            .overlay(Rectangle().stroke(Color.primary.opacity(0.85), lineWidth: 2))
                            .padding(.horizontal, 18)
                            .padding(.top, 8)

                        VStack(spacing: 6) {
                            Text("共 \(r.included) 个图源 · 单张二维码")
                                .font(.callout).fontWeight(.medium)
                            Text("压缩后 \(r.chars) / \(SourceQRCodec.maxChars) 字符")
                                .font(.caption2).foregroundStyle(.secondary)

                            if r.included < r.total {
                                Label("只包含了前 \(r.included) 个源（其余超出单张码容量）",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .padding(.top, 2)
                            }

                            if !r.dropped.isEmpty {
                                Text("为塞进一张，已省略：" + r.dropped.joined(separator: "、"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 20)
                            }
                        }
                        .padding(.horizontal, 16)

                        Button {
                            if let img = SourceQRCodec.image(r.payload) {
                                UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                                toast = "已保存到相册"
                            }
                        } label: {
                            Label("保存到相册", systemImage: "square.and.arrow.down")
                                .font(.callout).fontWeight(.medium)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(Color(.secondarySystemGroupedBackground),
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 18)

                        Text("对方打开：App → 图源 → 导入图源 → 相机扫码")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "qrcode").font(.system(size: 40)).foregroundStyle(.secondary)
                            Text(failMsg ?? "正在生成…").font(.callout).foregroundStyle(.secondary)
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
        let json = SourceCodec.exportJson(list, pretty: false)
        guard let r = SourceQRCodec.encode(json: json) else {
            failMsg = "生成失败（数据异常）"
            return
        }
        result = r
        DiagLog.event("qr", "export",
                      "\(r.total) 个源 → 单张码 \(r.chars) 字符，实际含 \(r.included) 个，省略 \(r.dropped.joined(separator: "/"))")
    }
}
