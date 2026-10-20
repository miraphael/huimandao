import SwiftUI
import UIKit

/// 图源 → 二维码（放在「图源管理」页：多选后点底部「二维码」）。
///
/// 一份图源 JSON 往往有几十 KB，一个二维码装不下，所以会生成**多张码**，
/// 用 TabView 左右翻，对方按顺序扫完即可还原（见 `SourceQRCodec`）。
///
/// **压缩后 1 个源 ≈ 1 张码**（实测：单源 3336 字节 → zlib 1437 → base64 1916，
/// 一个二维码 L 纠错能装约 2200 字符）。选得越多张数越多。
struct SourceQRExportView: View {
    @Environment(\.dismiss) private var dismiss
    /// 要导出的源；空数组表示「导出全部已启用的」
    let sources: [ComicSource]

    /// 纠错等级：`L` 容量大、码更密；`M` 码更稀、更容易扫，但张数更多
    @State private var dense = true
    @State private var codes: [String] = []
    @State private var total: Int = 0
    @State private var failMsg: String? = nil
    @State private var toast: String? = nil

    private var chunk: Int { dense ? SourceQRCodec.chunkLength : SourceQRCodec.chunkLengthM }
    private var correction: String { dense ? "L" : "M" }

    var body: some View {
        NavigationStack {
            Group {
                if codes.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "qrcode").font(.system(size: 44)).foregroundStyle(.secondary)
                        Text(failMsg ?? "正在生成…").font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 0) {
                        TabView {
                            ForEach(Array(codes.enumerated()), id: \.offset) { i, code in
                                VStack(spacing: 10) {
                                    if let img = SourceQRCodec.image(code, correction: correction) {
                                        Image(uiImage: img)
                                            .interpolation(.none)
                                            .resizable()
                                            .scaledToFit()
                                            .padding(14)
                                            .background(Color.white)
                                            .overlay(Rectangle().stroke(Color.primary.opacity(0.85), lineWidth: 2))
                                            .padding(.horizontal, codes.count > 1 ? 34 : 26)
                                    }
                                    Text(codes.count > 1 ? "第 \(i + 1) / \(codes.count) 张" : "单张即可")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: codes.count > 1 ? .always : .never))
                        .indexViewStyle(.page(backgroundDisplayMode: .always))

                        VStack(spacing: 8) {
                            Text("对方打开：App → 图源 → 导入图源 → 相机扫码，按顺序扫完这 \(codes.count) 张")
                                .font(.caption)
                            Text("\(total) 个图源 · \(dense ? "高密度(张数少)" : "低密度(更好扫)")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 10)
                    }
                }
            }
            .navigationTitle("图源二维码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle(isOn: $dense) {
                            Label(dense ? "高密度（张数少）" : "低密度（更好扫）", systemImage: "dial.low")
                        }
                        Divider()
                        Button {
                            saveAll()
                        } label: { Label("保存全部到相册", systemImage: "square.and.arrow.down") }
                        .disabled(codes.isEmpty)
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .alert("图源二维码", isPresented: Binding(get: { failMsg != nil },
                                                     set: { if !$0 { failMsg = nil } })) {
                Button("知道了") { dismiss() }
            } message: { Text(failMsg ?? "") }
            .safeAreaInset(edge: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.callout)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 8)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                                if self.toast == toast { self.toast = nil }
                            }
                        }
                }
            }
            .onAppear { rebuild() }
            .onChange(of: dense) { _ in rebuild() }
        }
    }

    private func rebuild() {
        let list = sources.isEmpty
            ? ComicRepository.shared.allSources(includeDisabled: false)
            : sources
        total = list.count
        guard total > 0 else {
            codes = []
            failMsg = "没有可导出的图源"
            return
        }
        // 🔴 必须 **pretty: false**：压缩后的 JSON 才可能少几张码。
        let json = SourceCodec.exportJson(list, pretty: false)
        codes = SourceQRCodec.encode(json: json, chunk: chunk)
        DiagLog.event("qr", "export",
                      "\(total) 个源 → \(codes.count) 张码（\(json.count) 字符 → 压缩后 \(dense ? "L" : "M") 级）")
    }

    private func saveAll() {
        var ok = 0
        for code in codes {
            guard let img = SourceQRCodec.image(code, correction: correction) else { continue }
            UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
            ok += 1
        }
        toast = ok == codes.count ? "已保存 \(ok) 张到相册" : "只保存成功 \(ok)/\(codes.count) 张"
    }
}
