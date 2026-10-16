import Foundation
import MachO
import UIKit

/// ──────────────────────────────────────────────────────────────────────────────
/// 安全防护（加固第 1 重）—— 反调试 / 反注入 / 越狱检测 / 完整性校验
///
/// ## 设计红线：**只降级，不闪退**
/// 这类代码最常见的翻车方式是「检测到异常 → exit(0)」——正常用户在某些环境
/// （企业 MDM、越狱但只是用插件、某些调试工具残留）下会被误伤，直接白屏闪退，
/// 用户只会认为「这 App 坏了」，投诉无门。
///
/// 所以这里全部走 `Zx7Guard.risk` 打分模型：
///   · 每个检测项命中 → 累加一个**权重分**
///   · 总分超过阈值 → 标记为 `isTampered`，由调用方决定**降级行为**
///     （例如：图源规则解密失败、禁用导出、清空缓存），**绝不主动退出**
///
/// 另有一个总开关 `AppSettings.securityEnabled`（默认开），
/// 用户可在设置里关掉 —— 调试/排查时不至于被自己的防护挡住。
///
/// ## 为什么用「打分」而不是「任一命中即判」
/// 单项检测都有假阳性：越狱设备上正常使用、企业设备装了 MDM、
/// 某些系统版本 `sysctl` 返回值差异……单点判定必然误伤。
/// 打分后取阈值，能容忍单项误报，同时真正的「调试器 + 注入 + 越狱」组合
/// 依然会稳定越过阈值。
/// ──────────────────────────────────────────────────────────────────────────────
enum Zx7Guard {

    // MARK: - 检测结果

    /// 各项检测的命中明细（用于诊断日志 / 排查误伤）
    struct Report {
        var debuggerAttached = false
        var injectedLibraries: [String] = []
        var jailbroken = false
        var suspiciousPaths: [String] = []
        var reSigned = false
        /// Frida / objection 之类的默认监听端口是否处于监听状态
        var fridaListening = false
        var score = 0
        var isTampered: Bool { score >= Self.threshold }

        static let threshold = 3

        var summary: String {
            var parts: [String] = []
            if debuggerAttached { parts.append("调试器已附加") }
            if !injectedLibraries.isEmpty { parts.append("注入: \(injectedLibraries.joined(separator: ","))") }
            if jailbroken { parts.append("越狱环境") }
            if !suspiciousPaths.isEmpty { parts.append("可疑路径 \(suspiciousPaths.count) 个") }
            if reSigned { parts.append("签名不匹配（疑似重打包）") }
            if fridaListening { parts.append("Frida 监听端口开放") }
            return parts.isEmpty ? "无异常" : parts.joined(separator: " · ")
        }
    }

    // MARK: - 对外入口

    private(set) static var report = Report()

    /// App 启动时调用一次（`HMDApp` 的 didFinishLaunching）。
    /// **不做任何会阻塞启动的重活** —— 越狱检测要访问文件系统，
    /// 放到后台队列，避免拖慢启动看门狗（踩过 0x8BADF00D 白屏）。
    static func install() {
        guard AppSettings.shared.securityEnabled else {
            DiagLog.event("security", "skip", "安全防护已在设置中关闭")
            return
        }
        DispatchQueue.global(qos: .utility).async {
            var r = Report()

            // ① 反调试：调试器附加检测
            r.debuggerAttached = isDebuggerAttached()
            if r.debuggerAttached { r.score += 3 }

            // ② 反注入：DYLD_INSERT_LIBRARIES + 可疑镜像扫描
            r.injectedLibraries = injectedLibraryHits()
            if !r.injectedLibraries.isEmpty { r.score += 3 }

            // ③ 越狱检测：可疑文件路径
            r.suspiciousPaths = jailbreakPathHits()
            if !r.suspiciousPaths.isEmpty { r.jailbroken = true; r.score += 2 }

            // ④ 完整性：签名/重打包校验
            r.reSigned = isReSigned()
            if r.reSigned { r.score += 2 }

            // ⑤ Frida / objection 默认监听端口是否开放
            r.fridaListening = fridaPortOpen()
            if r.fridaListening { r.score += 3 }

            report = r
            DiagLog.event("security", "scan",
                          "加固自检：\(r.summary)（分值 \(r.score)/\(Report.threshold)）"
                          + (r.isTampered ? " ⚠️ 判定为被篡改" : " ✅ 正常"))
        }
    }

    /// 是否处于「被篡改」状态（调用方据此降级，**不要**用它来闪退）
    static var isTampered: Bool { report.isTampered }

    // MARK: - ① 反调试

    /// 检测调试器是否已附加。
    ///
    /// 用 `sysctl` 读 `kinfo_proc.kp_proc.p_flag` 的 `P_TRACED` 位 ——
    /// 这是**只读探测**，不像 `ptrace(PT_DENY_ATTACH)` 那样会改变进程状态，
    /// 因此不会干扰正常调试（我们自己也还在开发期）。
    /// 想更激进可以另加 `ptrace`，但那会让 Xcode 附加失败，本项目不需要。
    private static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var size = MemoryLayout<kinfo_proc>.stride
        let ok = mib.withUnsafeMutableBufferPointer { mibPtr in
            sysctl(mibPtr.baseAddress, 4, &info, &size, nil, 0)
        }
        guard ok == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    // MARK: - ② 反注入

    /// 扫描已加载镜像，命中 Frida / cycript / 注入框架的已知特征。
    /// 同时检查 `DYLD_INSERT_LIBRARIES` 环境变量。
    private static func injectedLibraryHits() -> [String] {
        var hits: [String] = []

        if let env = getenv("DYLD_INSERT_LIBRARIES"), String(cString: env).isEmpty == false {
            hits.append("DYLD_INSERT_LIBRARIES")
        }

        // 已知的动态分析框架特征（小写匹配）
        let needles = ["frida", "cycript", "substitute", "substrate",
                       "libhooker", "ellekit", "cydia", "tweakInject"]

        let count = _dyld_image_count()
        for i in 0..<count {
            guard let cName = _dyld_get_image_name(i) else { continue }
            let name = String(cString: cName).lowercased()
            for n in needles where name.contains(n) {
                hits.append(URL(fileURLWithPath: name).lastPathComponent)
                break
            }
        }
        return Array(Set(hits))
    }

    // MARK: - ③ 越狱检测

    /// 越狱特征路径。**只做「文件是否存在」的只读判断**，
    /// 不做 URL Scheme 探测（那会触发系统弹窗，用户体验很差）。
    private static func jailbreakPathHits() -> [String] {
        let paths = [
            "/Applications/Cydia.app",
            "/Applications/Sileo.app",
            "/Applications/Zebra.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/usr/lib/libsubstitute.dylib",
            "/usr/lib/substrate",
            "/usr/sbin/sshd",
            "/etc/apt",
            "/private/var/lib/apt",
            "/var/jb",                       // 现代 rootless 越狱根目录
        ]
        return paths.filter { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - ④ 完整性 / 防重打包

    /// 检测「签名被替换」（二次打包）。
    ///
    /// 原理：正常安装时，`embedded.mobileprovision` 里的 Team ID
    /// 与二进制签名者的 Team ID 一致。zsign 之类工具重签后，
    /// 两者可能来自不同证书 —— 这里比对 Team ID 是否落在**允许集合**内。
    ///
    /// ⚠️ 本项目自己就是用 zsign 签的（Team `STW4VDB85Z`），
    /// 所以「允许集合」必须包含它，否则会把自己的包判成篡改。
    /// 将来换证书时**记得同步改这里**。
    private static func isReSigned() -> Bool {
        let allowedTeams: Set<String> = ["STW4VDB85Z"]

        // ① 读 embedded.mobileprovision 里的 TeamIdentifier
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let raw = try? Data(contentsOf: url),
              let text = String(data: raw, encoding: .isoLatin1),
              let teamRange = text.range(of: "<key>TeamIdentifier</key>") else {
            // 拿不到描述文件（例如 App Store 包）→ 不判篡改，避免误伤
            return false
        }
        let tail = text[teamRange.upperBound...].prefix(200)
        guard let start = tail.range(of: "<string>"),
              let end = tail.range(of: "</string>") else { return false }
        let team = String(tail[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if team.isEmpty { return false }
        return !allowedTeams.contains(team)
    }

    // MARK: - ⑤ 反 Frida / 反 Hook

    /// Frida 默认监听端口（27042 / 27043）是否处于**被占用**状态。
    ///
    /// 这是**最廉价也最实用**的动态分析信号：正常用户手机上
    /// 不会有进程监听 27042；一旦 Frida-server 或 objection 起来，
    /// 这个端口就会被占住。检测成本几乎为零（一次 `bind` 试探）。
    ///
    /// ⚠️ 判据是「**绑不上** = 有人在监听」。反过来：
    /// 若 `socket()` 本身失败（沙盒/权限），一律当作空闲，**不误报**。
    private static func fridaPortOpen() -> Bool {
        for port in [27042, 27043] {
            if canBindLocalhost(UInt16(port)) == false { return true }
        }
        return false
    }

    /// 试探性绑定本机端口：能绑上 = 空闲；绑不上 = 已被占用（有人监听）
    private static func canBindLocalhost(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }        // 拿不到 socket → 当空闲，不误报
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                bind(fd, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }
}
