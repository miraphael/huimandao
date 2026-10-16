import Foundation

/// 图源检验结果 —— 一次「源能不能用」的结论。
///
/// ⚠️ 这是**纯数据**：只描述结论，不含探测逻辑（逻辑在 `SourceValidator`）。
///    放在 Model 层是为了让 UI（`SourceCheckView`）、引擎、导出报告三处
///    引用同一个类型，而不是各自复制一份字段。
struct SourceCheckResult: Identifiable {
    var id: String { sourceUrl }
    let name: String
    let sourceUrl: String
    var ok: Bool
    var ms: Int
    var message: String
    var checked: Bool = false
    /// 失败发生在哪一环：入口 / 网络 / 列表 / 详情 / 章节 / 正文 / 完成
    var stage: String = ""
    /// 解析出的章节数（0 = 没解析出来）
    var chapters: Int = 0
    /// 首章解析出的图片数（0 = 正文也没出来）
    var images: Int = 0
    /// 这次体检**有没有真的去探正文**。
    ///
    /// ⚠️ 必须有这个字段：轻量档（只探到列表）不会请求正文页，`images` 恒为 0。
    ///    拿它去判「这个源正文 0 图」是**假结论** —— 会把一堆本来正常的源标成坏的。
    var probedContent: Bool = false
}
