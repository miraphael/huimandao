import SwiftUI

/// 关于页 —— 绘漫岛：这是什么、怎么用、能力边界
struct AboutView: View {
    var body: some View {
        // ⚠️ 用系统 `List`（与设置主页同一个容器），不再自绘 `ScrollView + VStack` ——
        //    这正是「设置界面跟里面的界面有点分割」的修法：容器一致，风格才一致。
        List {
            Section {
                HStack(spacing: 12) {
                    Image("AppIcon")
                        .resizable().scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("绘漫岛").font(.title2.bold())
                        Text("v\((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0")").font(.caption).foregroundStyle(.secondary)
                        Text("把散落各站的漫画，收进一座岛").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

                section("这是什么") {
                    Text("绘漫岛是一座**漫画聚合阅读器**。它自己不存放任何漫画，而是通过「图源规则」把各个漫画站的内容汇集到你面前——搜索一次，几十个站点同时出结果；加入书架，全站更新一屏追完。")
                    Text("你可以把绘漫岛理解成一盏灯：灯本身不发光，是它照亮的那些东西组成了整片风景。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                section("快速上手") {
                    step("1", "添加图源", "「漫画台 → 图源」右上角 + ，或在「设置 → 图源管理」里粘贴 / 文件 / 二维码 / 链接导入")
                    step("2", "搜索漫画", "「漫画台 → 推荐」右上角放大镜，或图源页里搜；线程数可在设置里调")
                    step("3", "加入书架", "漫画详情页点「加入书架」，之后在「书架」里等更新")
                    step("4", "开始阅读", "详情页点「开始阅读」进入章节列表；三种翻页模式，阅读进度自动记住")
                    step("5", "离线追更", "章节列表页可多选章节批量下载，在「设置 → 下载管理」看进度")
                }

                section("功能地图") {
                    kv("漫画", "书架 + 下载；封面墙、分组、更新红点")
                    kv("漫画台", "推荐 + 发现 + 图源；单图源浏览、栏目横滑、跨源聚合")
                    kv("设置", "账号 / 外观 / 阅读 / 网络 / 备份 / 历史 / 本地 / 图源管理 / 下载")
                    kv("本地", "文件夹、zip / rar / 7z 压缩包，支持导入")
                    kv("图源", "导入、导出、编辑、批量启停、网页登录、局域网分享")
                    kv("备份", "WebDAV 云备份 + 本地文件导出恢复")
                    kv("网络", "DoH 防污染、HTTP/2/3、按源持久化 Cookie")
                }

                section("阅读体验") {
                    kv("翻页", "滚动 / 普通翻页 / 日漫模式")
                    kv("手势", "屏幕三等分点击翻页、双击缩放、长按保存图片")
                    kv("进度", "自动记住读到哪一页，下次直接续读（始终开启）")
                    kv("图片", "自动裁剪白边、按需加载不占内存")
                }

                section("解析引擎") {
                    Text("图源解析用的不是现成方案，而是绘漫岛**自己设计的一套内核**——它只负责三件事：谁先试、什么时候降级、这次结果可不可信。")
                    Text("三种各有所长的解析方式通过一个兼容层接入内核：")
                        .font(.caption).foregroundStyle(.secondary)
                    kv("规则", "精确、快，懂章节顺序与字段含义；站点改版即失效")
                    kv("脚本", "表达力最强，能处理解密与签名；最慢，且可能陷入死循环")
                    kv("万用", "不怕改版、召回高，擅长发现规则漏掉的内容；噪声大、不懂语义")
                    Text("内核用四条机制让它们互相补短：")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("• **语义骨架 + 召回补全** —— 规则提供顺序与命名，万用只补规则没覆盖到的部分，而不是简单拼在一起\n• **交叉验证 + 置信度** —— 两种方式都出结果时，算它们身份集合的重合率，给出「高 / 中 / 低」三档可信度；低置信度会明确提示，而不是默默给你一份可能是错的列表\n• **成本感知的顺序** —— 便宜的先试，可能卡死的脚本排到最后，只在必要时才用\n• **自适应记忆** —— 记住某个源在某一步哪条路走得通，下次优先走它（仅本次运行内，站点改版后自动失效）")
                }

                section("图源解析失灵怎么办") {
                    Text("网络波动、站点改版、临时限流都可能让某次解析失败。绘漫岛做了这些兜底：")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("• 失败自动重试（指数退避，最多 3 轮）\n• 规则多策略回退：CSS → XPath → 正则 → JS 逐个尝试\n• 章节列表为空时提示「重新解析」，不必退出去再进\n• 「设置 → 图源连通性诊断」逐段探测：详情页 → 章节 → 正文 → 图片，直接告诉你是哪一环断了\n• 报错不再含糊，会明确写「域名解析失败 / 连接超时 / TLS 证书失败 / 规则未匹配」")
                }

                section("常见问题") {
                    Text("• 导入失败、显示网页或跳转 → 该站点需要网络代理\n• 搜索无结果 → 确认图源已启用；部分站点需先在「图源」里网页登录\n• 某站点一直转圈 → 设置里开启 DoH 防污染，或换个图源\n• 出现闪退 → 设置 → 导出崩溃日志，发给开发者")
                }

            Section {
                Text("绘漫岛仅提供阅读工具，所有内容均来自第三方图源。请支持正版。")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .transparentScrollBackground()
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// ⚠️ 返回 **`Section`** 而不是自绘灰底卡片 —— 设置主页用的是系统 `Form`，
    ///    子页若自绘卡片就会「风格割裂」（用户反馈的「设置界面跟里面的界面有点分割」）。
    ///    统一成 `Section` 后，两处的分组、间距、深浅色行为完全一致，
    ///    也能正确露出主题背景。
    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        Section {
            content()
        } header: {
            Text(title)
        }
    }

    @ViewBuilder
    private func step(_ n: String, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(n).font(.caption.bold()).foregroundStyle(Theme.onAccent)
                .frame(width: 18, height: 18).background(Theme.accent).clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.caption.bold()).frame(width: 40, alignment: .leading)
            Text(v).font(.caption).foregroundStyle(.secondary)
        }
    }
}
