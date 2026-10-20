import AVFoundation
import SwiftUI
import UIKit

/// 相机扫码导入图源（放在「导入图源」页）。
///
/// 能识别两种内容：
///  1. `hmdqr|z|1/3|…` —— App「导出二维码」生成的分片，按顺序扫齐后拼回 JSON 导入；
///  2. 普通网址 —— 保持老逻辑，App 自己下载后导入（兼容以前的相册识图）。
///
/// 🔴 **黑屏教训（v117 实测）**：预览层绝不能在 `makeUIView` 里 `layer.frame = view.bounds`
/// —— 那一刻视图还没布局，bounds 是 `.zero`，层就是 0×0，表现为**全黑**。
/// 正确做法是自定义 UIView 并把 `layerClass` 设成 `AVCaptureVideoPreviewLayer`，
/// 层会随视图自动改变尺寸。
struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var authorized = false
    @State private var denied = false
    @State private var parts: [SourceQRCodec.Part] = []
    @State private var status = "把二维码放进取景框"
    @State private var finished = false
    /// 导入成功后的源名称（要在界面上显示，不能只闪一下）
    @State private var importedNames: [String] = []
    /// 去抖：同一张码会连续回调几十次
    @State private var lastDecode = Date.distantPast

    var body: some View {
        ZStack {
            if authorized {
                CameraPreview(onDecode: handle)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "camera.fill").font(.system(size: 46)).foregroundStyle(.secondary)
                    Text(denied ? "没有相机权限" : "正在请求相机权限…")
                        .font(.callout).foregroundStyle(.secondary)
                    if denied {
                        Text("请到 设置 → 绘漫岛 → 打开「相机」")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("去设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }
            }

            // 导入成功的醒目提示（用户反馈：识别成功后要「在那里」也显示出来）
            if finished, !importedNames.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(.green)
                    Text("导入成功")
                        .font(.headline)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(importedNames.prefix(8), id: \.self) { n in
                            Label(n, systemImage: "square.stack.3d.up")
                                .font(.callout)
                                .lineLimit(1)
                        }
                        if importedNames.count > 8 {
                            Text("…等共 \(importedNames.count) 条").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
                .frame(maxWidth: 300)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.15), lineWidth: 1))
                .transition(.scale.combined(with: .opacity))
                .animation(.spring(response: 0.32, dampingFraction: 0.8), value: finished)
            }

            // 取景框 + 状态
            VStack {
                Spacer()
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.9), lineWidth: 2)
                    .frame(width: 250, height: 250)
                Spacer().frame(height: 18)
                Text(status)
                    .font(.callout).fontWeight(.medium)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.black.opacity(0.62), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.bottom, 28)
            }
        }
        .navigationTitle("扫码导入图源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
        }
        .onAppear { checkAuth() }
        .onChange(of: finished) { ok in
            guard ok else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { dismiss() }
        }
    }

    // MARK: - 权限

    private func checkAuth() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorized = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                Task { @MainActor in
                    authorized = ok
                    denied = !ok
                }
            }
        default:
            denied = true
        }
    }

    // MARK: - 识别

    private func handle(_ text: String) {
        let now = Date()
        guard now.timeIntervalSince(lastDecode) > 0.8 else { return }
        lastDecode = now
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let part = SourceQRCodec.decode(t) {
            merge(part)
        } else if t.lowercased().hasPrefix("http") {
            status = "识别到网址，正在下载…"
            Task {
                let fetched = await HttpFetcher.shared.fetchText(t)
                let trimmed = fetched.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    status = "❌ 链接下载失败（\(t.prefix(50))）"
                } else if trimmed.hasPrefix("<") || trimmed.contains("<html") {
                    status = "❌ 链接返回的是网页，不是图源"
                } else {
                    finish(trimmed)
                }
            }
        } else {
            status = "不是图源二维码：\(t.prefix(40))"
        }
    }

    private func merge(_ p: SourceQRCodec.Part) {
        // 收到不同 total 的分片 → 上一批没扫完，重来
        if let first = parts.first, first.total != p.total {
            parts = [p]
            status = "换了新的一批，重新计数：1/\(p.total)"
            return
        }
        if !parts.contains(where: { $0.index == p.index }) {
            parts.append(p)
        }
        if parts.count >= p.total, let json = SourceQRCodec.assemble(parts) {
            DiagLog.event("qr", "import", "扫码拼回 \(p.total) 片，\(json.count) 字符")
            finish(json)
        } else {
            status = "已收 \(parts.count)/\(p.total) 张，继续扫"
        }
    }

    private func finish(_ json: String) {
        let list = SourceCodec.importJson(json)
        ComicRepository.shared.saveSources(list)
        if list.isEmpty {
            status = "❌ 内容不是有效图源（\(json.count) 字符）"
            return
        }
        importedNames = list.map { $0.bookSourceName.isEmpty ? "(未命名)" : $0.bookSourceName }
        status = "✅ 导入 \(list.count) 条图源"
        finished = true
        DiagLog.event("qr", "import-ok", "\(list.count) 条：\(importedNames.joined(separator: "、"))")
        NotificationCenter.default.post(name: .hmdSourcesChanged, object: nil)
    }
}

/// 相机预览：把视图自己的 layer 当预览层（`layerClass`），尺寸自动跟随 —— 不会黑屏。
private struct CameraPreview: UIViewRepresentable {
    let onDecode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDecode: onDecode) }

    func makeUIView(context: Context) -> UIView {
        let v = PreviewUIView(frame: .zero)
        v.backgroundColor = .black
        v.onDecode = onDecode

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              v.session.canAddInput(input) else {
            DiagLog.event("qr", "camera", "❌ 拿不到摄像头输入")
            return v
        }
        v.session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard v.session.canAddOutput(output) else {
            DiagLog.event("qr", "camera", "❌ 加不了输出")
            return v
        }
        v.session.addOutput(output)
        output.setMetadataObjectsDelegate(context.coordinator, queue: DispatchQueue.main)
        output.metadataObjectTypes = [.qr]

        let layer = v.layer as? AVCaptureVideoPreviewLayer
        layer?.session = v.session
        layer?.videoGravity = .resizeAspectFill

        DispatchQueue.global(qos: .userInitiated).async { v.session.startRunning() }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        (uiView as? PreviewUIView)?.session.stopRunning()
    }

    /// 预览层随视图尺寸自动变化，`makeUIView` 时不必（也不能）手动设 frame
    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        let session = AVCaptureSession()
        var onDecode: ((String) -> Void)?
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onDecode: (String) -> Void

        init(onDecode: @escaping (String) -> Void) { self.onDecode = onDecode }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            for obj in metadataObjects {
                guard let code = obj as? AVMetadataMachineReadableCodeObject,
                      code.type == .qr, let s = code.stringValue, !s.isEmpty else { continue }
                onDecode(s)
                return
            }
        }
    }
}
