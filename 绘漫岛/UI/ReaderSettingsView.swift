import SwiftUI

/// 设置子页 —— 阅读
///
/// 从原「设置」长 Form 拆出（ARCHITECTURE §8.6）。只放与**阅读本身**有关的项：
/// 阅读模式、白边裁剪、双击缩放、常亮、进度保存，以及漫画页顶部分段显示。
/// ⚠️ 搜索线程 / 下载线程**不放在这里** —— 它们属于「网络」「下载与追更」。
struct ReaderSettingsView: View {
    @EnvironmentObject var s: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("默认阅读模式", selection: $s.readMode) {
                    Text("滚动").tag(1); Text("普通翻页").tag(2); Text("日漫模式").tag(3)
                    Text("双页").tag(4); Text("双页·日漫").tag(5)
                }
                Toggle("白边裁剪", isOn: $s.whiteEdgeCut)
                Toggle("双击缩放", isOn: $s.doubleTapZoom)
                Toggle("常亮", isOn: $s.keepScreenOn)
                LabeledContent("自动保存进度", value: "始终开启")
            } header: {
                Label("阅读设置", systemImage: "book")
            } footer: {
                Text("阅读到哪一页会自动记住，下次打开直接续读；此功能不提供关闭选项。")
            }
            Section {
                // 🔴 这两个开关控制的是**「漫画台」标签页**的分段，不是「漫画」标签页
                //    （旧文案写成「漫画标签页」，真机反馈 2026-10-15：用户按说明去关「推荐」，
                //      结果把「漫画台」关得只剩「图源」，以为 App 坏了）。
                // 🔴 而且不能两个都关：全关掉后「漫画台」只剩「图源」一个分段，
                //    看起来就像"漫画台变成了图源界面"。这里用自定义 Binding 拦住
                //    「关掉最后一个」的操作，保证至少留一个分段。
                Toggle("推荐", isOn: recommendBinding)
                Toggle("发现", isOn: findBinding)
            } header: {
                Label("漫画台显示", systemImage: "rectangle.3.group")
            } footer: {
                Text("控制「漫画台」标签页里顶部有哪几个分段（图源始终显示，且至少要留一个分段）。")
            }
        }
        .transparentScrollBackground()
        .navigationTitle("阅读")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 「漫画台」分段的开关绑定

    /// 「推荐」开关：**当「发现」已经是关的时候，不允许再关掉推荐** ——
    /// 否则「漫画台」会只剩「图源」，用户会以为界面坏了。
    private var recommendBinding: Binding<Bool> {
        Binding(get: { s.showRecommend },
                set: { v in
                    if !v && !s.showFind { return }   // 会全关 → 忽略这次操作
                    s.showRecommend = v
                })
    }

    /// 「发现」开关：同理，当「推荐」已经是关的时候不允许再关掉发现。
    private var findBinding: Binding<Bool> {
        Binding(get: { s.showFind },
                set: { v in
                    if !v && !s.showRecommend { return }
                    s.showFind = v
                })
    }
}

