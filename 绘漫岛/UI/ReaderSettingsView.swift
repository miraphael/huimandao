import SwiftUI

/// 设置子页 —— 阅读
///
/// 从原「设置」长 Form 拆出（ARCHITECTURE §8.6）。只放与**阅读本身**有关的项：
/// 白边裁剪、章节排序、双击缩放、常亮、进度保存，以及漫画台分段显示。
/// （「阅读模式」选项已移除 —— 只保留滚动模式。）
/// ⚠️ 搜索线程 / 下载线程**不放在这里** —— 它们属于「网络」「下载与追更」。
struct ReaderSettingsView: View {
    @EnvironmentObject var s: AppSettings

    var body: some View {
        Form {
            Section {
                // 🔴 「默认阅读模式」已删除（2026-10-24 用户要求：只保留滚动模式）。
                //    现在全 App 只有「滚动（条漫）」一种阅读方式，`readMode` 恒为 1。
                Toggle("白边裁剪", isOn: $s.whiteEdgeCut)
                // 章节智能排序（2026-10-18）：按话数升序重排，解决倒序站点
                // ① 列表反着排 ② 「下一章」往回走 两个问题。
                Toggle("章节智能排序", isOn: Binding(
                    get: { AppSettings.shared.chapterAutoSort },
                    set: { AppSettings.shared.chapterAutoSort = $0 }))
                    .help("按章节名里的话数升序排列，与站点给的顺序无关")
                Toggle("双击缩放", isOn: $s.doubleTapZoom)
                // 「常亮」移到阅读器内的设置面板（那是阅读时的 comfort 项，
                //  放全局设置里语义不对 —— H2：两套 UI 按「全局行为 vs 本次阅读」划界）
                LabeledContent("自动保存进度", value: "始终开启")
            } header: {
                Label("阅读设置", systemImage: "book")
            } footer: {
                Text("阅读到哪一页会自动记住，下次打开直接续读；此功能不提供关闭选项。")
            }
            // 🔴 「漫画台显示」整节已删除（2026-10-24）：
            //    漫画台只剩「图源」一个分段，推荐/发现已下线，
            //    再留着这两个开关就是**假开关**（拨了毫无反应）。
        }
        .transparentScrollBackground()
        .navigationTitle("阅读")
        .navigationBarTitleDisplayMode(.inline)
    }

}
