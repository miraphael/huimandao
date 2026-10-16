import Foundation
import CryptoKit
import CommonCrypto
import Compression
import BigInt

/// zlib/deflate 解压（Legado 分享格式 + 通用压缩数据）
enum Zlib {
    /// data 可能带 0x78 zlib 头（eNr/eNp/eNo 等 base64 前缀家族）或裸 deflate
    static func inflate(_ data: Data) -> Data? {
        var candidates: [Data] = []
        if let f = data.first, f == 0x78 { candidates.append(Data(data.dropFirst(2))) }
        candidates.append(data)
        for d in candidates {
            let dstCap = max(d.count * 10, 1 << 20)
            var dst = Data(count: dstCap)
            let n = dst.withUnsafeMutableBytes { db -> Int in
                d.withUnsafeBytes { sb -> Int in
                    compression_decode_buffer(db.bindMemory(to: UInt8.self).baseAddress!, dstCap,
                                              sb.bindMemory(to: UInt8.self).baseAddress!, d.count,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            if n > 0 { return dst.prefix(n) }
        }
        return nil
    }
}

/// 图源规则解密：`:_版本_密文` 格式（对应原版 utils/Cfor + Cif + Cimplements）
enum SourceDecrypt {
    static let aesIV = Qk9Keys.aesIV
    static let keyPad = Qk9Keys.keyPad

    // 版本 -> 密钥（S: 直接 key；H/T: md5 派生；R: RSA 模数+指数）
    static let versionKeys: [String: String] = Qk9Keys.versionKeys
    // R 版本 RSA：(模数, 指数) —— 顺序对应 R001..R006
    static let rsaKeys: [String: (String, String)] = [
        "R001": ("124894949392799470526501691427201380722059386407429374904963151579445000167700084219094797780867267785897015633452737623494882167165602560066550153229779581419202243260024600553243026875623862252970534410045512718055164222767734268476307217370858508842021185622033555296345081105287930968885783895899183401631",
                 "19086069456853159241873580673390497400881106826700537018310625401326552189545004503333042132561491952439938676955532641951444640195991636879317701597903178032251524558220594586042774566667098468523075912221587922761078702629673680760823904240579535052710120226686686757549111111483582028698505555454486750265"),
        "R002": ("134637879530725842045797524508160121551609494553379149906687560348617712247282090903147805955484430250432335457792034049708343226865029205108006451147296816481047287446612470453679013649723292054233709641226286065157635394380094379354568922533499017531342766295713079603926199948346272171926131302561430658419",
                 "26112192620585178072281450711216095106302279331075967543356458730352402940614904808344296925357963451151566288299214928800797970384179222599833925832853439888342640415696699869357785949087891627998411565633711986243813092664335597492895203854674537798891101584434089581685869173590440642207295109926796080873"),
        "R003": ("129687005002893678462258796476531399533182790367431241886401469844966355386036128571070619438228618154986229861190436546865018454538596851401582310946251118113102749171640191782313442529234243995625586165944107120885398307387122000295641915645959373878533198490065094178492877982169810374840993728562031519451",
                 "41468496831417976499612361550913102653728100995466516700053850528268229297492608913062177105261438913222934113113306808003163506619327030806591069291997466282358213608270495908597272131676474848064702792913802149316731747013886568532033632097590127095715137913435615888935607179182373719289689782848795732129"),
        "R004": ("114737282646053411153191125552464961684877527566486697407657067497223857621606510099134620159886510385369743052921265046412650960670405167324511418769565986785130279303309025131430922680512927459659347040053031505170887511387363963040194542702287631882079335182228304208113000751602157929985817627734352710973",
                 "6257529830441680345671809519903228547266025343004944965581553527045064209591941479192393855478193383049388957488194937091115212722220969365543661420832829565415921870538601853029528477108725351697612171310930129800532652860831639423337379483853627148984644975559139383848088176284172307975953124337029486825"),
        "R005": ("146372144379205490318397651279575810877674630401376756713544888234448441631421195469371449557009813069179225328595244812888859210444267899624134179269439598626750554744149486431693991900726482490381030602289706414213778315170872098929393476937274144247556843764280070143422500796941791167495767154628182240551",
                 "70387587411429431162998934630841684357162439757916736747268320569338844656225562442818193059095514957683718751901115978769227191460645513078175698105894729760343620214532047321719776584517760097231040938346123064264290930257656668906635959708481115861769263421653051042270366207333290378393268508256115557261"),
        "R006": ("147016280108323395424425110933109423982167754606681218202836670921323970403694758493534062597366854555224174098104812131753688557538322792080358547319739657444425204231632640918083014064617176044848677821564756438387138009504153779014931647274809221226629782150732202102138976504029597451845107605372273052759",
                 "3106162053852405941646509660274026108518469732803117732042375711466702132927191392048972316042652312548134230554380932884247688420353860558675808604636558666900217700811222405994977417661504605591182755170180239765097621852782385920349085783253187007506297779008899163668213273497487603412074635153582808353"),
    ]

    /// 规则字段自动解密入口；非 `:_V_` 格式原样返回，失败也原样返回（与原版 catch 行为一致）
    /// - Parameter sourceUrl: 该图源的 **完整 bookSourceUrl**（H/T 密钥派生依赖它）
    static func auto(_ rule: String, sourceUrl: String) -> String {
        guard rule.hasPrefix(":_") else { return rule }
        let parts = rule.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        // ":_S001_xxx" → ["", "S001", "xxx"]；":_" + "_S001_" 时首段为空
        guard parts.count >= 3 else { return rule }
        // 密文常含换行折行，先剔除所有空白（同时保证共享密文的 key 能对上）
        let ver = parts[1].components(separatedBy: .whitespacesAndNewlines).joined().uppercased()
        let payload = parts[2].components(separatedBy: .whitespacesAndNewlines).joined()
        guard !payload.isEmpty else { return rule }

        // R：声明版本优先，失败回退其余 R 密钥 ——
        // 实测存在「标记版本与实际密钥不符」的图源（733动漫 www.733.so 标 R003 实为 R002 密钥）
        if ver.hasPrefix("R") {
            for v in keyOrder(declared: ver, from: Array(rsaKeys.keys)) {
                guard let (n, e) = rsaKeys[v] else { continue }
                if let pt = rsaDecrypt(payload, modulus: n, exponent: e), isPlausibleRule(pt) {
                    return pt
                }
            }
            return rule
        }

        guard let key = versionKeys[ver] else { return rule }

        // H/T：Cgoto 派生 key，带回退（多版本 key × 多候选 URL）
        if ver.hasPrefix("H") || ver.hasPrefix("T") {
            return htDecrypt(payload, declaredVer: ver, sourceUrl: sourceUrl) ?? rule
        }

        // S：版本 key 直接作 AES key（原版为 32 字节零填充）
        return aesDecrypt(payload, keyBytes: pad32Bytes(key)) ?? rule
    }

    /// 尝试顺序：声明版本排最前，其余按字典序（结果确定、可复现）
    private static func keyOrder(declared: String, from all: [String]) -> [String] {
        var out = [declared]
        out.append(contentsOf: all.sorted().filter { $0 != declared })
        return out
    }

    // MARK: - H/T 回退层（共享密文 + 版本标记纠错）

    /// 密文 → 候选源 URL。同一密文常被多个镜像域名共用（copymanga.tv / copymanga.site 等 6 组），
    /// 而 H/T 的 key 依赖 bookSourceUrl，故必须对候选逐个试解。
    private static var cipherCandidates: [String: [String]] = [:]
    private static let candLock = NSLock()

    /// 登记「密文 → 源URL」映射（导入图源时批量调用）
    static func registerCandidates(_ pairs: [(cipher: String, url: String)]) {
        guard !pairs.isEmpty else { return }
        candLock.lock()
        defer { candLock.unlock() }
        for p in pairs where !p.cipher.isEmpty && !p.url.isEmpty {
            var arr = cipherCandidates[p.cipher] ?? []
            if !arr.contains(p.url) && arr.count < 12 { arr.append(p.url) }
            cipherCandidates[p.cipher] = arr
        }
    }

    /// 取该密文已知的候选 URL
    static func candidateURLs(for cipher: String) -> [String] {
        candLock.lock()
        defer { candLock.unlock() }
        return cipherCandidates[cipher] ?? []
    }

    /// H/T 解密：尝试顺序 = [声明版本key + 其余 H/T key] × [源URL + 共享该密文的其他候选URL]
    ///
    /// 性能要点：base64 解码与 `htKeyComponent`（伪 hex + Cgoto 解码）都与后缀无关，
    /// 必须**在循环外只算一次** —— 否则 T 版本穷举后缀时会重复 10 万次，白白拖慢几十倍。
    static func htDecrypt(_ payload: String, declaredVer: String, sourceUrl: String) -> String? {
        var seenURL = Set<String>()
        var urls = [sourceUrl]
        urls.append(contentsOf: candidateURLs(for: payload))
        let uniqURLs = urls.filter { !$0.isEmpty && seenURL.insert($0).inserted }
        guard !uniqURLs.isEmpty, let cipher = base64Flexible(payload) else { return nil }
        let components = uniqURLs.map { htKeyComponent(sourceUrl: $0) }

        let htKeys = Array(versionKeys.keys).filter { $0.hasPrefix("H") || $0.hasPrefix("T") }
        for ver in keyOrder(declared: declaredVer, from: htKeys) {
            guard let vk = versionKeys[ver] else { continue }
            // H 无后缀；T 原版 Cfor 写死 648L
            let suffix = ver.hasPrefix("T") ? tSuffixDefault : ""
            if let pt = tryHTKey(cipher, versionKey: vk, suffix: suffix, components: components) { return pt }
        }

        // T 版本兜底：后缀实测会随 App 版本变化（快看漫画 T004 用的是 635 而非 648），
        // 因此默认后缀失败后在 0...99999 内穷举。仅 T 版本、仅失败时才会走到这里。
        if declaredVer.hasPrefix("T"), let vk = versionKeys[declaredVer] {
            if let pt = bruteForceTSuffix(cipher, versionKey: vk, components: components) { return pt }
        }
        return nil
    }

    /// 用给定后缀尝试所有候选 URL（cipher 已 base64 解码，components 已算好）
    private static func tryHTKey(_ cipher: Data, versionKey: String, suffix: String, components: [String]) -> String? {
        for comp in components {
            let h = md5Hex((comp + versionKey + suffix).data(using: .utf8) ?? Data())
            guard let dec = AESCBCCrypt.run(cipher, key: Array(h.utf8), iv: Array(aesIV.utf8), encrypt: false),
                  let pt = str(dec) else { continue }
            if isPlausibleRule(pt) { return pt }
        }
        return nil
    }

    /// T 版本后缀：原版 Cfor 里是 648L，但实测有图源用其他数字（疑为不同 App 版本的内置常量）
    private static let tSuffixDefault = "648"
    private static var tSuffixKnown: [String] = []
    private static let tSuffixLock = NSLock()

    /// 穷举 T 后缀；命中后记入缓存，后续同版本密文优先复用
    private static func bruteForceTSuffix(_ cipher: Data, versionKey: String, components: [String]) -> String? {
        tSuffixLock.lock()
        let cached = tSuffixKnown.filter { $0 != tSuffixDefault }
        tSuffixLock.unlock()

        for s in cached {
            if let pt = tryHTKey(cipher, versionKey: versionKey, suffix: s, components: components) { return pt }
        }
        for n in 0...99999 {
            let s = String(n)
            if s == tSuffixDefault || cached.contains(s) { continue }
            if let pt = tryHTKey(cipher, versionKey: versionKey, suffix: s, components: components) {
                tSuffixLock.lock()
                if !tSuffixKnown.contains(s) { tSuffixKnown.append(s) }
                tSuffixLock.unlock()
                return pt
            }
        }
        return nil
    }

    /// 解密结果可信度：错 key 偶发通过 PKCS7 校验时用于过滤（控制字符/替换符占比 < 5%）
    static func isPlausibleRule(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        var bad = 0
        var total = 0
        for ch in s.unicodeScalars {
            total += 1
            let v = ch.value
            if v == 0xFFFD || (v < 0x20 && v != 0x0A && v != 0x09 && v != 0x0D) { bad += 1 }
        }
        return total > 0 && Double(bad) / Double(total) < 0.05
    }

    /// Cfor.m26510case —— 32 字节缓冲清零后拷入 key（不足部分保持 0x00）
    /// 注意：原版 keyPad 常量声明但从未被引用，实际是**零填充**，不是 keyPad 循环补齐。
    static func pad32Bytes(_ key: String) -> [UInt8] {
        var k = [UInt8](repeating: 0, count: 32)
        let b = Array(key.utf8)
        let n = min(b.count, 32)
        if n > 0 { for i in 0..<n { k[i] = b[i] } }
        return k
    }

    // MARK: - H/T 版密钥派生（复刻 Cgoto$if + wd.m8551case）

    /// H/T 版：key = md5hex( Cgoto$if.decode( wd.m8551case(bookSourceUrl) ) + versionKey )，T 版再拼 "648"
    static func htKeyComponent(sourceUrl: String) -> String {
        let bytes = pseudoHex(sourceUrl)
        var dec = HTCifDecoder(bytes)
        return dec.decode()
    }

    /// wd.m8551case —— 把字符串按"伪 hex"逐两字符转 byte（非 hex 字符 digit=-1，奇数长度前补 '0'）
    private static func pseudoHex(_ s: String) -> [UInt8] {
        var str = s
        if str.count % 2 == 1 { str = "0" + str }
        let chars = Array(str)
        var out = [UInt8]()
        var i = 0
        while i < chars.count {
            let hi = Int(String(chars[i]), radix: 16) ?? -1
            let lo = Int(String(chars[i + 1]), radix: 16) ?? -1
            out.append(UInt8(truncatingIfNeeded: (hi << 4) + lo))
            i += 2
        }
        return out
    }

    static func pad32(_ key: String) -> String {
        if key.count >= 32 { return String(key.prefix(32)) }
        var k = key
        var i = 0
        while k.count < 32 {
            let idx = keyPad.index(keyPad.startIndex, offsetBy: i % keyPad.count)
            k.append(keyPad[idx])
            i += 1
        }
        return k
    }

    static func md5Hex(_ s: String) -> String {
        md5Hex(Data(s.utf8))
    }
    static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func aesDecrypt(_ b64: String, key: String) -> String? {
        aesDecrypt(b64, keyBytes: Array(key.utf8))
    }
    static func aesDecrypt(_ b64: String, keyBytes: [UInt8]) -> String? {
        guard let data = base64Flexible(b64) else { return nil }
        guard let dec = AESCBCCrypt.run(data, key: keyBytes, iv: Array(aesIV.utf8), encrypt: false) else { return nil }
        return str(dec)   // CCCrypt 已按 PKCS7 去 padding
    }
    static func aesEncrypt(_ text: String, key: String) -> String? {
        var padded = Array(text.utf8)
        let pad = 16 - padded.count % 16
        padded.append(contentsOf: [UInt8](repeating: UInt8(pad), count: pad))
        guard let enc = AESCBCCrypt.run(Data(padded), key: Array(key.utf8), iv: Array(aesIV.utf8), encrypt: true) else { return nil }
        return Data(enc).base64EncodedString()
    }

    private static func str(_ bytes: some Collection<UInt8>) -> String? {
        let d = Data(bytes)
        if let s = String(data: d, encoding: .utf8) { return s }
        return String(data: d, encoding: .gbk)
    }

    static func base64Flexible(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        // 密文常被换行折行（669 个加密字段里有 55 个含换行）。
        // Data(base64Encoded:) 默认遇到字母表外字符会直接返回 nil，必须先剔除所有空白。
        t = t.components(separatedBy: .whitespacesAndNewlines).joined()
        while t.count % 4 != 0 { t += "=" }
        if let d = Data(base64Encoded: t) { return d }
        return Data(base64Encoded: t, options: .ignoreUnknownCharacters)
    }

    /// RSA 幂运算解密（c^e mod n，BigInt）
    /// R 版本解密（实测真实现，2026-10-07 用六漫画 R002 真实密文验证）：
    /// 载荷为 HEX → 128 字节分块 → 每块 RSA(m^e mod n) → PKCS1(00 02 随机 00 数据) 解封装 → 拼接 → URL 解码
    static func rsaDecrypt(_ payload: String, modulus: String, exponent: String) -> String? {
        // 载荷解码：纯 hex 优先（R 版本标准），否则 base64 兼容
        let data: Data
        if payload.count % 2 == 0,
           payload.range(of: "^[0-9a-fA-F]+$", options: .regularExpression) != nil,
           let d = Data(hexEncoded: payload) {
            data = d
        } else if let d = base64Flexible(payload) {
            data = d
        } else {
            return nil
        }
        guard let n = BigUInt(modulus), let e = BigUInt(exponent), !data.isEmpty else { return nil }

        let blockSize = (n.bitWidth + 7) / 8
        var out = Data()
        func unpad(_ m: Data) -> Data? {
            // PKCS1 v1.5: 00 02 rand 00 data（加密型）或 00 01 FF..00 data（签名型）
            if m.count >= 11, m[0] == 0x00, (m[1] == 0x02 || m[1] == 0x01) {
                for i in 2..<m.count where m[i] == 0x00 {
                    return Data(m[(i + 1)...])
                }
                return nil
            }
            // 无壳：去前导 0
            var i = 0
            while i < m.count, m[i] == 0 { i += 1 }
            return Data(m[i...])
        }
        if data.count % blockSize == 0 {
            for off in stride(from: 0, to: data.count, by: blockSize) {
                let chunk = data.subdata(in: off..<(off + blockSize))
                let c = BigUInt(chunk)
                var m = c.power(e, modulus: n).serialize()
                while m.count < blockSize { m.insert(0x00, at: 0) }   // BigInt 序列化丢前导 0，补齐块长
                guard let part = unpad(Data(m)) else { return nil }
                out.append(part)
            }
        } else {
            // 整块（异常长度时兜底）
            let c = BigUInt(data)
            var m = c.power(e, modulus: n).serialize()
            while m.count < blockSize { m.insert(0x00, at: 0) }
            guard let part = unpad(Data(m)) else { return nil }
            out = part
        }
        var s = String(data: out, encoding: .utf8) ?? String(data: out, encoding: .isoLatin1)
        // 解出的规则是 URL 编码的（%40=@, + = 空格）
        if let s2 = s?.replacingOccurrences(of: "+", with: " ").removingPercentEncoding {
            s = s2
        }
        return s
    }
}



/// 复刻 Cgoto$if（smali goto$if）的比特打包解码器：把 m8551case 产生的字节流解回字符串
private struct HTCifDecoder {
    static let escapeTable = [0, 10, 13, 34, 38, 92]
    private let data: [UInt8]
    private var byteIndex = 0
    private var bitOffset = 0

    init(_ bytes: [UInt8]) { self.data = bytes }

    private mutating func read() -> Int8 {
        let i = byteIndex
        if i >= data.count { return -128 }
        let b = Int(data[i])
        let i2 = bitOffset
        let v = ((b & (0xFE >> i2)) << i2) >> 1
        let i4 = i2 + 7
        bitOffset = i4
        if i4 < 8 { return Int8(truncatingIfNeeded: v) }
        let i5 = i4 - 8
        bitOffset = i5
        let i6 = i + 1
        byteIndex = i6
        if i6 >= data.count { return Int8(truncatingIfNeeded: v) }
        let b6 = Int(data[i6])
        let combined = (((b6 & (0xFF00 >> i5)) & 0xFF) >> (8 - i5)) | v
        return Int8(truncatingIfNeeded: combined)
    }

    mutating func decode() -> String {
        var out = [UInt8]()
        while true {
            let b = read()
            if b == -128 { break }
            if let idx = Self.escapeTable.firstIndex(of: Int(b)) {
                let b2 = read()
                let first: Int
                let dataB: Int
                if b2 == -128 {
                    first = -34
                    dataB = Int(b)
                } else {
                    first = ((idx & 7) << 2) | 0xC2
                    dataB = Int(b2)
                }
                let flag = (dataB & 0x40) > 0 ? 1 : 0
                out.append(UInt8(truncatingIfNeeded: first | flag))
                out.append(UInt8(truncatingIfNeeded: (dataB & 0x3F) | 0x80))
            } else {
                out.append(UInt8(truncatingIfNeeded: Int(b)))
            }
        }
        return String(decoding: Data(out), as: UTF8.self)
    }
}

enum AESCBCCrypt {    static func run(_ data: Data, key: [UInt8], iv: [UInt8], encrypt: Bool) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: data.count + 32)
        var outLen = 0
        let status = key.withUnsafeBufferPointer { kp in
            iv.withUnsafeBufferPointer { ip in
                data.withUnsafeBytes { dp in
                    CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            kp.baseAddress, kp.count, ip.baseAddress,
                            dp.baseAddress, dp.count,
                            &out, out.count, &outLen)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Array(out[0..<outLen])
    }
}

extension Data {
    /// hex 字符串 → Data（R 版本密文载荷）
    init?(hexEncoded: String) {
        let h = hexEncoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard h.count % 2 == 0 else { return nil }
        var d = Data(capacity: h.count / 2)
        var gen = h.makeIterator()
        while let a = gen.next(), let b = gen.next() {
            guard let hi = UInt8(String(a), radix: 16), let lo = UInt8(String(b), radix: 16) else { return nil }
            d.append(hi << 4 | lo)
        }
        self = d
    }
}
