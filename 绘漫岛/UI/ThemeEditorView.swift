import SwiftUI
import UIKit

/// ── 主题编辑器 ─────────────────────────────────────────────────────────────
///
/// 列表选主题 → 进编辑页**造**主题：配色、背景图、透明度、填充方式，带实时预览。
///
/// ## 交互约定
///   · 点一下 = 立即切换（不用再点「应用」）
///   · 左滑 = 复制 / 删除（内置主题只能「另存为」，防止误删）
///   · 「新建主题」= 从空白模板起，颜色都可改
struct ThemeEditorView: View {
    @ObservedObject private var store = ThemeStore.shared
    @State private var editing: ThemeConfig?
    @State private var showNewSheet = false
    @State private var newName = ""
    @State private var ioMessage = ""

    /// 跟随系统深浅色。
    /// ⚠️ 用 `@AppStorage` 绑同一个键 —— `HMDApp` 里也有一份同键的 `@AppStorage`，
    ///    这里一改，那边就会重算 `preferredColorScheme`，无需额外通知。
    @AppStorage("theme.followSystem") private var followSystem = false

    var body: some View {
        List {
            Section {
                ForEach(store.themes) { t in
                    Button {
                        store.currentID = t.id
                    } label: {
                        ThemeRow(theme: t, selected: t.id == store.currentID)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !t.builtin {
                            Button(role: .destructive) {
                                store.remove(id: t.id)
                            } label: { Label("删除", systemImage: "trash") }
                        }
                        Button {
                            editing = store.duplicate(t)
                        } label: { Label(t.builtin ? "另存为" : "复制", systemImage: "doc.on.doc") }
                            .tint(.blue)
                        // 🔴 内置主题**不提供「编辑」** —— 保存看着生效，但 `ThemeStore.load()`
                        //    强制内置以代码为准，重启就还原，用户会认为「主题存不住」。
                        //    想改内置主题请走「另存为」。（由智能体「主题」发现）
                        if !t.builtin {
                            Button {
                                editing = t
                            } label: { Label("编辑", systemImage: "slider.horizontal.3") }
                                .tint(.orange)
                        }
                    }
                }
            } header: {
                Text("主题")
            } footer: {
                Text("点一下即切换。左滑可编辑 / 复制 / 删除；内置主题可「另存为」再改。")
            }

            Section {
                Button {
                    newName = ""
                    showNewSheet = true
                } label: {
                    Label("新建主题", systemImage: "plus.circle.fill")
                }
            } footer: {
                Text("新建后可挑一张自己的图片当背景，透明度与填充方式都能调 —— 漫画界面会一起跟随。")
            }

            Section {
                Toggle("跟随系统深浅色", isOn: $followSystem)
            } footer: {
                Text("打开后忽略主题自带的深 / 浅色设定，完全跟着 iOS 走。")
            }

            Section {
                Button {
                    exportThemes()
                } label: {
                    Label("复制全部主题到剪贴板", systemImage: "square.and.arrow.up")
                }
                Button {
                    importThemes()
                } label: {
                    Label("从剪贴板导入主题", systemImage: "square.and.arrow.down")
                }
                if !ioMessage.isEmpty {
                    Text(ioMessage).font(.caption2).foregroundStyle(.secondary)
                }
            } header: {
                Text("分享与备份")
            } footer: {
                Text("导出为 JSON 文本（不含图片文件本身）；导入会**追加**到现有列表，不覆盖。")
            }
        }
        .transparentScrollBackground()
        .navigationTitle("主题")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { t in
            ThemeEditView(theme: t)
        }
        .alert("新建主题", isPresented: $showNewSheet) {
            TextField("主题名称", text: $newName)
            Button("创建") {
                let t = ThemeConfig.newCustom(name: newName)
                DiagLog.event("theme", "create", "新建主题 name=\(t.name) id=\(t.id)")
                store.add(t)
                store.currentID = t.id
                // 🔴 必须延到 alert **完全关闭之后**再弹 sheet。
                //    直接在 alert 的按钮里设 `editing`，SwiftUI 会因为
                //    「正在 dismiss 一个呈现的同时又要 present 另一个」而**丢掉**这次 sheet
                //    —— 用户看到的就是「点了创建，没进编辑页」（实测反馈）。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { editing = t }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: 导入 / 导出

    /// 把**用户自建**的主题序列化成 JSON 放进剪贴板。
    ///
    /// 内置主题不导出 —— 对方装同一版 App 就自带，导出去只是噪声。
    private func exportThemes() {
        let custom = store.themes.filter { !$0.builtin }
        guard !custom.isEmpty else {
            ioMessage = "没有自建主题可导出（内置主题人人都有）"
            return
        }
        guard let data = try? JSONEncoder().encode(custom),
              let text = String(data: data, encoding: .utf8) else {
            ioMessage = "编码失败"
            return
        }
        UIPasteboard.general.string = text
        ioMessage = "已复制 \(custom.count) 个主题到剪贴板"
    }

    /// 从剪贴板读 JSON，**追加**为自建主题（不覆盖现有）。
    private func importThemes() {
        guard let text = UIPasteboard.general.string,
              let data = text.data(using: .utf8) else {
            ioMessage = "剪贴板里没有文本"
            return
        }
        guard let list = try? JSONDecoder().decode([ThemeConfig].self, from: data) else {
            ioMessage = "剪贴板内容不是有效的主题 JSON"
            return
        }
        var added = 0
        for var t in list {
            // 换新 id 避免与现有主题撞车；背景图置空 ——
            // 图片文件不会跟着 JSON 走，留着文件名只会指向不存在的文件。
            t.id = "custom-\(UUID().uuidString.prefix(8))"
            t.builtin = false
            t.backgroundImage = nil
            store.add(t)
            added += 1
        }
        ioMessage = added > 0 ? "已导入 \(added) 个主题" : "没有可导入的主题"
    }
}

/// 列表行：左侧一组色块预览，右侧名称 + 当前标记
private struct ThemeRow: View {
    let theme: ThemeConfig
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            // 三色预览：背景 / 卡片 / 强调
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.backgroundColor)
                    .frame(width: 46, height: 46)
                RoundedRectangle(cornerRadius: 3)
                    .fill(theme.surfaceColor)
                    .frame(width: 22, height: 14)
                    .padding(5)
                Circle()
                    .fill(theme.accentColor)
                    .frame(width: 10, height: 10)
                    .offset(x: -30, y: -30)
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.25), lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(theme.name).font(.body)
                HStack(spacing: 6) {
                    if theme.isDark { tag("深色") }
                    if theme.backgroundImage != nil { tag("自定义图") }
                    if theme.builtin { tag("内置") }
                }
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
            }
        }
        .contentShape(Rectangle())
    }

    private func tag(_ s: String) -> some View {
        Text(s)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.gray.opacity(0.15))
            .clipShape(Capsule())
            .foregroundStyle(.secondary)
    }
}

// MARK: - 编辑页

struct ThemeEditView: View {
    @ObservedObject private var store = ThemeStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var t: ThemeConfig
    @State private var pickerShown = false
    @State private var pickedImage: UIImage?
    /// 本次编辑里被「移除图片」摘掉的文件名 —— **只在保存成功后才真删**。
    ///
    /// 🔴 以前「移除图片」是**立刻删盘**的：用户点完反悔按「取消」，
    ///    主题里还引用着那张图，文件却已经没了 → **原图永久丢失、不可恢复**。
    ///    改成先记账、保存时才删。（由智能体「主题」发现）
    @State private var pendingDelete: [String] = []

    init(theme: ThemeConfig) {
        _t = State(initialValue: theme)
    }

    var body: some View {
        NavigationView {
            Form {
                Section("名称") {
                    TextField("主题名称", text: $t.name)
                }

                Section {
                    Toggle("深色模式", isOn: $t.isDark)
                } footer: {
                    Text("深色会同时切换系统控件与状态栏样式。")
                }

                Section("配色") {
                    colorRow("强调色", hex: $t.accentHex)
                    colorRow("背景色", hex: $t.backgroundHex)
                    colorRow("卡片色", hex: $t.surfaceHex)
                    colorRow("文字色", hex: $t.textHex)
                }

                // 🔎 实时预览：直接用 `ThemeBackground` 渲染**正在编辑的主题**。
                //    （用户报「放了图片但显示不出来」，而日志确认图名/文件/参数都对 ——
                //     只能说明渲染没走到。这个预览把「ThemeBackground 本身」和
                //     「页面接入」两件事分开：这里能看到 → 是接入问题；看不到 → 是渲染问题。）
                Section("预览") {
                    ThemeBackground(theme: t)
                        .frame(height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        // 🔴 外圈要能看出边界，否则透明背景等于「看不到预览」
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.4), lineWidth: 1))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("主题文字颜色 · 12")
                        Text("卡片（surface）会铺在背景上")
                    }
                    .font(.caption)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(t.surfaceColor, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(t.textColor)
                }

                Section {
                    if let img = pickedImage ?? t.backgroundImage.flatMap({ store.backgroundImage(named: $0) }) {
                        Image(uiImage: img)
                            .resizable().scaledToFit()
                            .frame(maxHeight: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    Button {
                        pickerShown = true
                    } label: {
                        Label(t.backgroundImage == nil ? "选择图片" : "更换图片",
                              systemImage: "photo.on.rectangle.angled")
                    }
                    if t.backgroundImage != nil {
                        Button(role: .destructive) {
                            // 🔴 **不要立刻删盘** —— 用户可能马上点「取消」，
                            //    那时主题仍引用这张图，文件没了就**永久丢失**。
                            //    只记进待删列表，保存成功时才真删。
                            if let n = t.backgroundImage { pendingDelete.append(n) }
                            t.backgroundImage = nil
                            pickedImage = nil
                        } label: { Label("移除图片", systemImage: "trash") }
                    }
                } header: {
                    Text("背景图")
                } footer: {
                    Text("图片会压缩到 2000px 内并转成 JPEG 存进 App 文档目录，不会走网络。")
                }

                if t.backgroundImage != nil {
                    Section {
                        HStack {
                            Text("不透明度")
                            Slider(value: $t.backgroundOpacity, in: 0.05...1)
                            Text("\(Int(t.backgroundOpacity * 100))%")
                                .font(.caption).monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                        HStack {
                            Text("模糊")
                            Slider(value: $t.backgroundBlur, in: 0...30)
                            Text("\(Int(t.backgroundBlur))")
                                .font(.caption).monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                        HStack {
                            Text("压暗")
                            Slider(value: $t.backgroundDim, in: 0...0.7)
                            Text("\(Int(t.backgroundDim * 100))%")
                                .font(.caption).monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                        Picker("填充方式", selection: $t.backgroundFill) {
                            Text("铺满").tag("fill")
                            Text("完整显示").tag("fit")
                            Text("平铺").tag("tile")
                        }
                    } header: {
                        Text("图片显示")
                    } footer: {
                        Text("图太花就用「模糊」压一压；字看不清就用「压暗」把底色加深。")
                    }
                }

                Section {
                    ZStack {
                        ThemeBackground(theme: t)
                        VStack(spacing: 10) {
                            Text("标题示例").font(.headline).foregroundStyle(t.textColor)
                            Text("正文示例 —— 主题会同时作用到阅读界面。")
                                .font(.caption).foregroundStyle(t.secondaryTextColor)
                            Text("按钮").font(.caption.bold())
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(t.accentColor)
                                .foregroundStyle(t.onAccentColor)   // 自动黑/白
                                .clipShape(Capsule())
                        }
                        .padding(16)
                        .background(t.surfaceColor.opacity(0.92))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding()
                    }
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    if t.hasLowContrast {
                        Label("文字色与卡片色太接近，可能看不清",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("预览")
                }
            }
            .transparentScrollBackground()
            .navigationTitle(t.name.isEmpty ? "编辑主题" : t.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        // 🔎 插桩：确认「保存」被点到、以及保存时的内容
                        DiagLog.event("theme", "save",
                                      "点保存 id=\(t.id) name=\(t.name) bg=\(t.backgroundHex) img=\(t.backgroundImage ?? "无")")
                        store.update(t)
                        store.currentID = t.id
                        // 保存成功 → 这时才真正删掉被摘掉的背景图
                        //（取消路径不会走到这里，文件原样保留）
                        for n in pendingDelete { store.deleteBackground(named: n) }
                        pendingDelete.removeAll()
                        dismiss()
                    }.bold()
                }
            }
            .sheet(isPresented: $pickerShown) {
                ImagePicker { img in
                    pickedImage = img
                    if let data = img.jpegData(compressionQuality: 0.9),
                       let name = store.importBackground(from: data) {
                        t.backgroundImage = name
                        // 🔎 插桩：图片已进本地副本，**还要点「保存」才会写回 store**
                        DiagLog.event("theme", "pick",
                                      "已选图 \(name)（\(data.count) 字节）→ 待保存")
                    } else {
                        DiagLog.event("theme", "pick", "❌ jpegData 或 importBackground 失败")
                    }
                }
            }
        }
    }

    /// String(hex) ↔ Color 的双向绑定
    private func colorRow(_ title: String, hex: Binding<String>) -> some View {
        ColorPicker(title,
                    selection: Binding(
                        get: { Color(hex: hex.wrappedValue) ?? .pink },
                        set: { hex.wrappedValue = $0.hexString }),
                    supportsOpacity: false)
    }
}

// MARK: - 选图（UIImagePickerController，兼容 iOS 15）

/// ⚠️ 不用 `PhotosPicker` —— 它要 iOS 16+，而本工程部署目标是 **iOS 15.0**。
struct ImagePicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .photoLibrary
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: ImagePicker
        init(_ p: ImagePicker) { parent = p }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage {
                parent.onPick(img)
            } else {
                // 🔎 插桩：取不到图（比如 iCloud 还没下载完）会让「选了图没反应」
                DiagLog.event("theme", "pick", "❌ 取不到 originalImage")
            }
            // 🔴 必须用 **picker 自己** dismiss，不能用 `parent.dismiss()`：
            //    `parent` 是 `makeCoordinator()` 时的**值拷贝**，里面的
            //    `@Environment(\.dismiss)` 可能已失效 → 相册界面**关不掉**，
            //    用户看到的就是「选完图没反应」。
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
