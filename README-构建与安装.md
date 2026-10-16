# 绘漫岛 iOS —— 构建与安装指南

> 由原 Android 版（com.wsw.cospa）的逆向规格重写而成的原生 iOS 应用（Swift/SwiftUI）。
> 逆向分析详见 `../逆向分析报告.md`。

## 目录结构

```
huimandao/
├── 逆向分析报告.md          ← 完整逆向规格（功能地图/规则引擎/加密体系/DB/Web协议）
├── decoded/                 ← 反编译产物（jadx Java 源码 + apktool 资源/smali）
├── ios/                     ← iOS 工程（本目录）
│   ├── project.yml          ← XcodeGen 工程定义
│   ├── 绘漫岛/                 ← 22 个 Swift 源文件
│   │   ├── Core/            ← 图源模型/解密(:_V_)/规则引擎/JSONPath/XPath/JS/网络
│   │   ├── Store/           ← SQLite(GreenDAO 表结构 1:1)/仓库层
│   │   ├── Engine/          ← 搜索/详情/章节/正文/下载/本地/Web服务器/WebDAV备份
│   │   ├── UI/              ← 书架/搜索/发现/历史/本地/详情/阅读器/图源管理/设置
│   │   └── Resources/web/   ← 原版网页图源编辑器 v3.8（Web 服务器直接托管）
│   └── .github/workflows/build-ipa.yml   ← 云端一键构建 IPA
```

## 产出 IPA 的三条路径

### 方式 A：GitHub Actions 云端构建（无 Mac 要求，推荐）

1. 在 GitHub 新建**私有**仓库，把 `ios/` 内容推上去（`.github` 在仓库根）：
   ```bash
   cd ios
   git init && git add . && git commit -m "绘漫岛 iOS port"
   git remote add origin https://github.com/<你的用户名>/huimandao.git
   git push -u origin main
   ```
2. 仓库 → Actions → "Build iOS IPA" → Run workflow。
3. 构建完成后在 Artifacts 下载 **绘漫岛-unsigned-ipa**（未签名 IPA）。

### 方式 B：本地签名安装（Windows 上即可做）

下载的未签名 IPA 用以下任一工具签名后安装：

| 工具 | 说明 |
|---|---|
| **Sideloadly**（推荐） | Windows 直接可用：插上 iPhone → 拖入 IPA → 输入 Apple ID → 自动签名安装（免费证书 7 天有效，付费开发者账号 1 年） |
| **AltStore** | Windows 装 AltServer + iPhone 装 AltStore，可自动续签 |
| **爱思助手** | 自签模式同样可装 |
| **TrollStore** | 支持 TrollStore 的系统版本可直接装未签名 IPA |
| **Apple 开发者账号** | 有 $99 账号可用 Xcode/爱思做开发签装 + 长期有效 |

### 方式 C：有 Mac 时本地构建

```bash
brew install xcodegen
cd ios && xcodegen generate
open 绘漫岛.xcodeproj
# 选自己的开发团队后 Cmd+R 直接真机运行，或 Product→Archive 导出签名 IPA
```

## 功能保全对照（Android → iOS）

| 功能 | 状态 | iOS 实现位置 |
|---|---|---|
| 图源导入(粘贴/URL/导出/局域网分享) | ✅ | SourceListView + WebServer(1122端口同协议) |
| 原版加密图源 `:_版本_密文` 解密 | ✅ | SourceDecrypt（S/H/T 的 AES-CBC + R 版 RSA，密钥表已移植） |
| Legado 漫画书源 JSON 兼容导入 | ✅ | ComicSource 字段一一对应 |
| 规则引擎(jsoup链式/@CSS/@JSon/$/@XPath//、<js>、{{}}、@get/@put、##正则、& %%) | ✅ | AnalyzeRule（SwiftSoup + 自实现 JsonPath + libxml2 XPath + JavaScriptCore） |
| URL 规则({{key}}/{{page}}/{page1,page2}/|char=gbk/@Body/@Header) | ✅ | AnalyzeUrl |
| 多源并发搜索(线程数可调 1-64) | ✅ | ComicEngine.search（Swift TaskGroup） |
| 发现栏目(ruleFindUrl `名::url`) | ✅ | findColumns + FindView |
| 漫画详情/章节列表/分卷/下一页 | ✅ | detail/chapters |
| 阅读器 3 模式(滚动/翻页/日漫)+三分区点击+自动换章 | ✅ | ReaderView |
| 亮度/护眼/常亮/白边裁剪/长按保存图片 | ✅ | ReaderView + WhiteEdgeCutter |
| 阅读进度/历史/书架分组/更新检测 | ✅ | ComicRepository |
| 下载(章并发可调、图片 20 次重试) | ✅ | DownloadManager |
| 本地漫画(文件夹/zip；rar/7z 受系统限制) | ✅ | LocalComicScanner + ZipReader(zlib) |
| WebDAV 备份/恢复 | ✅ | BackupManager |
| Web 图源编辑器 v3.8(原版网页资源) | ✅ | 内嵌 NWListener 服务器，路由/端口与原版一致 |
| 图源登录(Web 网页登录留 Cookie) | ⚠️ 半 | CookieStore 已就绪，登录 UI 用 WKWebView 打开 loginUrl（可后续接入） |
| 音量键翻页 | ➖ | iOS 无公开 API；用三分区点击替代 |
| DoH 自定义 DNS / Cronet 内核 | ➖ | iOS 平台限制（URLSession 原生 HTTP/2 已足够） |
| 友盟统计/广告 SDK | ✂️ 刻意不移植 | 隐私净版 |

## 已知限制（2026-10-07 更新：CI 已全绿，IPA 已产出）

- ~~rar/7z 压缩包不支持~~ → **已解决**：vendor 官方 unrar 7.0.9 源码（C++，RARDLL 库模式）+ SWCompression(7z/LZMA)，本地页现支持 png/jpg/webp/gif/zip/rar/7z。
- ~~复杂 DOM 的 JS 规则解析不到~~ → **已解决**：新增 WebViewRuleEngine（WKWebView + 原版 jquery.js + 真实 DOM），检测到 document/$/window 引用的 <js> 规则自动走 WebView 通道；@web:/@webm: 规则同通道（渲染后 HTML 抓取）。
- **免费 Apple ID 签名**：IPA 安装后 7 天需重签（Sideloadly 重签即可）；付费开发者账号 1 年。这是 Apple 平台规则，无法绕过。
- ~~CI SPM 拉取失败需重跑~~ → **已解决**：CI 已跑 10 轮迭代全部收敛，最终构建成功（Swift 23 文件 + unrar 83→48 编译单元 + 3 个 SPM 包）。
- 部署目标 **iOS 16.0**（已验证 IPA 内 MinimumOSVersion=16.0），覆盖 iOS 16 / 17 / 18 / 26 / 27 全系机型（iPhone 8 及之后）；上端由最新 Xcode SDK 构建自动兼容。用户手机 iOS 17.2 实测目标环境。
- SWCompression/BitByteData 官方版声明 iOS 17 → 使用自有 fork（miraphael/SWCompression tag 4.9.3、miraphael/BitByteData tag 2.1.1，仅把 Package.swift 平台声明降为 .iOS(.v16)，代码未动）。
- UI 层已剔除 iOS 17 专属 API（ContentUnavailableView → 自研 EmptyState 组件）。
- 音量键翻页：iOS 无公开 API，保留三分区点击方案（原版也有）。
- app bundle 里混入了几个 unrar 的说明文件（.vcxproj/acknow.txt 等，XcodeGen 把未知扩展名当资源），无害，仅约 40KB。
