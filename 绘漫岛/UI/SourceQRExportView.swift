import SwiftUI
import UIKit

/// 图源 → 二维码（放在「图源管理」页的菜单里）。
///
/// 一份图源 JSON 往往有几十 KB，一个二维码装不下，所以会生成**多张码**，
/// 用 TabView 左右翻，对方按顺序扫完即可还原（见 `SourceQRCodec`）。
struct SourceQRExportView: View {
    @Environment(\.dismiss) private var dismiss
    /// 导出范围：只导启用的（常用，且码更少）/ 全部
    @State private var enabledOnly = true
    @State private var codes: [String] = []
    @State private var total: Int = 0
    /// codes 为空时的错误提示（弹窗）
    @State private var failMsg: String? = nil
    /// 操作反馈（底部横幅）
    @State private var toast: String? = nil

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
                                    if let img = SourceQRCodec.image(code) {
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
                            Text("共 \(total) 个图源 · 已用压缩 JSON（越少越好）")
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
                        Picker("范围", selection: $enabledOnly) {
                            Text("只导已启用的").tag(true)
                            Text("导出全部").tag(false)
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
            .onChange(of: enabledOnly) { _ in rebuild() }
        }
    }

    private func rebuild() {
        let list = ComicRepository.shared.allSources(includeDisabled: !enabledOnly)
        total = list.count
        guard total > 0 else {
            codes = []
            failMsg = "当前范围下没有图源（\(enabledOnly ? "已启用" : "全部")）"
            return
        }
        // 🔴 必须用 **pretty: false**：压缩后的 JSON 才可能少几张码。
        //    pretty-printed 会白白多出 30%~50% 的空白字符。
        let json = SourceCodec.exportJson(list, pretty: false)
        codes = SourceQRCodec.encode(json: json)
        DiagLog.event("qr", "export", "生成 \(codes.count) 张二维码（\(total) 个源，\(json.count) 字符）")
    }

    private func saveAll() {
        var ok = 0
        for code in codes {
            guard let img = SourceQRCodec.image(code) else { continue }
            UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
            ok += 1
        }
        toast = ok == codes.count ? "已保存 \(ok) 张到相册" : "只保存成功 \(ok)/\(codes.count) 张"
    }
}
