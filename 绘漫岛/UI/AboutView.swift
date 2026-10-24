import SwiftUI

/// 关于页 —— 借鉴 Legado：**首屏只放「它是什么」**，长文收进「了解更多」子页。
///
/// 设计原则：
///  · 一屏看完：图标 + 名称 + 版本 + 一句话 + 两个入口 + 一行声明；
///  · 不放长段落 —— 原来七八段功能介绍堆在这里，没人会读；
///  · 分组仍用系统 `Section`（与设置主页同容器，不割裂）。
struct AboutView: View {
    @State private var sourceCount = 0
    @State private var shelfCount = 0
    @State private var readCount = 0

    private static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
    private static var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    }

    var body: some View {
        List {
            // ── 品牌 ──
            Section {
                VStack(spacing: 12) {
                    // Legado `.about-hero__eyebrow`：大写强调色小标签
                    Text("HUIDAO ISLAND")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(2.2)
                        .foregroundStyle(Theme.accent)
                    Image("AppIcon")
                        .resizable().scaledToFill()
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(HMD.stroke, lineWidth: 0.8)
                        )
                        .shadow(color: .black.opacity(0.14), radius: 14, x: 0, y: 7)

                    VStack(spacing: 3) {
                        Text("绘漫岛")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .tracking(1.6)
                        Text("v\(Self.version) · build \(Self.build)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Text("把散落各站的漫画，收进一座岛")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .listRowBackground(Color.clear)
            }

            // ── 一句话说明 ──
            Section {
                Text("绘漫岛是一个漫画聚合阅读器。它自己不存放漫画，而是通过「图源规则」把各个漫画站的内容汇集到你面前 —— 搜索一次，几十个站点同时出结果。")
                    .font(.system(size: 13))
                    .lineSpacing(4)
            }

            // ── 费用说明（Legado 同款：「没有收费功能」）──
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(HMD.Semantic.success)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("没有收费功能")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text("本应用所有功能完全免费开放，永无付费项目。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            // ── 入口 ──
            Section {
                NavigationLink {
                    AboutDetailView()
                } label: {
                    Label("了解更多", systemImage: "info.circle.fill")
                }
                NavigationLink {
                    LicenseView()
                } label: {
                    Label("开源许可", systemImage: "doc.text.fill")
                }
            }

            // ── 数据（Legado `.about-badge-row`：标签左 · 值右 · 分隔线）──
            Section {
                badgeRow("图源", "\(sourceCount) 个")
                badgeRow("书架", "\(shelfCount) 本")
                badgeRow("在读", "\(readCount) 本")
            }

            // ── 声明 ──
            Section {
                Text("绘漫岛仅提供阅读工具，所有内容均来自第三方图源。请支持正版。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            }
        }
        .transparentScrollBackground()
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            sourceCount = ComicRepository.shared.allSources().count
            let shelf = ComicRepository.shared.shelfList()
            shelfCount = shelf.count
            readCount = shelf.filter { !$0.durChapterUrl.isEmpty }.count
        }
    }

    /// Legado `.about-badge-row`：标签左 · 值右 · 底部分隔线
    private func badgeRow(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).font(.system(size: 13)).foregroundStyle(Theme.text.opacity(0.6))
                Spacer()
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            .padding(.vertical, 9)
            Rectangle().fill(HMD.stroke).frame(height: 0.8)
        }
    }
}

// MARK: - 了解更多（原来的长文搬到这里）

/// 详细介绍：定位 / 上手 / 能力地图 / 解析引擎 / 排障。
/// 首屏不再堆长文，想看的人点进来。
struct AboutDetailView: View {
    var body: some View {
        List {
            section("这是什么") {
                Text("绘漫岛是一座漫画聚合阅读器。它自己不存放任何漫画，而是通过「图源规则」把各个漫画站的内容汇集到你面前——搜索一次，几十个站点同时出结果；加入书架，全站更新一屏追完。")
                Text("你可以把绘漫岛理解成一盏灯：灯本身不发光，是它照亮的那些东西组成了整片风景。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            section("快速上手") {
                step("1", "添加图源", "「漫画台 → 图源」右上角 +，或在「设置 → 图源」里粘贴 / 文件 / 二维码 / 链接导入")
                step("2", "搜索漫画", "「漫画」页右上角放大镜，或图源页里搜")
                step("3", "加入书架", "详情页点「加入书架」，之后在书架里等更新")
                step("4", "开始阅读", "详情页点「开始阅读」，进度自动记住")
                step("5", "离线追更", "章节列表页可多选章节批量下载")
            }

            section("功能地图") {
                kv("漫画", "书架 + 搜索；封面墙、分组、更新角标")
                kv("漫画台", "图源管理 + 继续阅读；导入 / 导出 / 校验")
                kv("设置", "账号 / 外观 / 阅读 / 网络 / 备份 / 诊断")
                kv("本地", "文件夹、zip / rar / 7z 压缩包")
                kv("备份", "WebDAV 云备份 + 本地文件导出恢复")
            }

            section("阅读体验") {
                kv("模式", "滚动（条漫）—— 按屏幕宽度自适应")
                kv("手势", "点击呼出菜单、双击缩放、长按保存图片")
                kv("进度", "自动记住读到哪一页，下次直接续读")
                kv("图片", "自动裁剪白边、按需加载不占内存")
            }

            section("解析引擎") {
                Text("图源解析不是现成方案，而是绘漫岛自己设计的一套内核——它只负责三件事：谁先试、什么时候降级、这次结果可不可信。")
                    .font(.caption)
                kv("规则", "精确、快；站点改版即失效")
                kv("脚本", "表达力最强；最慢，可能陷入死循环")
                kv("万用", "不怕改版、召回高；噪声大")
                Text("四条机制让它们互补：语义骨架 + 召回补全、交叉验证 + 置信度、成本感知的顺序、自适应记忆。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            section("图源解析失灵怎么办") {
                Text("• 失败自动重试（指数退避，最多 3 轮）\n• 规则多策略回退：CSS → XPath → 正则 → JS\n• 章节为空时可「重新解析」\n• 「设置 → 图源连通性诊断」逐段探测：详情 → 章节 → 正文 → 图片\n• 报错会写明「域名解析失败 / 连接超时 / 规则未匹配」")
                    .font(.caption)
            }

            section("常见问题") {
                Text("• 导入失败、显示网页或跳转 → 该站点可能需要网络代理\n• 搜索无结果 → 确认图源已启用\n• 一直转圈 → 开启 DoH 防污染，或换个图源")
                    .font(.caption)
            }
        }
        .transparentScrollBackground()
        .navigationTitle("了解更多")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        Section { content() } header: { Text(title) }
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
            Text(k).font(.caption.bold()).frame(width: 44, alignment: .leading)
            Text(v).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 开源许可

struct LicenseView: View {
    private struct Lib: Identifiable {
        let id = UUID()
        let name: String
        let desc: String
    }

    private let libs: [Lib] = [
        .init(name: "Nuke", desc: "图片加载与缓存（MIT）"),
        .init(name: "SQLCipher", desc: "加密数据库（BSD-style）"),
        .init(name: "UnrarKit / unrar", desc: "RAR 解压（UnRAR License）"),
        .init(name: "SwiftSoup", desc: "HTML 解析（MIT）"),
        .init(name: "ZIPFoundation", desc: "ZIP 解压（MIT）"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(libs) { lib in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lib.name).font(.system(size: 14, weight: .medium))
                        Text(lib.desc).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("第三方组件")
            } footer: {
                Text("以上组件遵循各自的开源许可。绘漫岛在此致谢。")
            }
        }
        .transparentScrollBackground()
        .navigationTitle("开源许可")
        .navigationBarTitleDisplayMode(.inline)
    }
}
