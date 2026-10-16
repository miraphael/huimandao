import Foundation
import Compression
import SWCompression

/// 本地漫画扫描 —— 对应 LocalComicFragment：png/jpg/jpeg/webp/gif/zip/rar/7z，文件夹即一本
enum LocalComicScanner {
    static let imageExts = ["png", "jpg", "jpeg", "webp", "gif"]
    static let archiveExts = ["zip", "rar", "7z", "cbz", "cbr"]

    /// 把漫画圈常见的别名扩展名归一到内部使用的三种。
    ///
    /// ⚠️ 为什么必须归一：`cbz` / `cbr` 是漫画打包的**最常见**格式
    ///    （cbz = zip，cbr = rar）。`fileImporter` 用 `.data/.item` 放行，
    ///    所以这两种文件**能被选中并复制进来**，但原先 `scan()` 只认
    ///    `zip/rar/7z` → `cbz/cbr` 落到所有 `else if` 之外 →
    ///    **既不进列表、也不报错**。用户看到「已导入 1 个文件」却列表为空，
    ///    是典型的静默数据丢失。
    static func normalizedArchiveExt(_ ext: String) -> String {
        switch ext.lowercased() {
        case "cbz", "zip":  return "zip"
        case "cbr", "rar":  return "rar"
        case "7z":          return "7z"
        default:            return ext.lowercased()
        }
    }

    struct LocalComic: Identifiable {
        var id: String { path }
        var name: String
        var path: String
        var kind: Kind
        var pageCount: Int
        var coverData: Data?

        enum Kind { case folder, zip, rar, sevenZip }
    }

    static func scan(root: URL? = nil) -> [LocalComic] {
        let base = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var out: [LocalComic] = []
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey]) else { return out }
        for d in dirs where d.lastPathComponent != "Downloads" && d.lastPathComponent != "Inbox" {
            let isDir = (try? d.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                let imgs = ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [])
                    .filter { imageExts.contains($0.pathExtension.lowercased()) }
                    .sorted { naturalCompare($0.lastPathComponent, $1.lastPathComponent) }
                if !imgs.isEmpty {
                    out.append(LocalComic(name: d.lastPathComponent, path: d.path, kind: .folder,
                                          pageCount: imgs.count, coverData: try? Data(contentsOf: imgs[0])))
                }
            } else {
                // ⚠️ 必须归一化扩展名：`cbz`(=zip) / `cbr`(=rar) 是漫画圈最常见的格式，
                //    不归一就会被静默忽略（文件已复制进来但列表里看不到）。
                let ext = normalizedArchiveExt(d.pathExtension)
                if ext == "zip" {
                    let names = ZipReader.list(d.path).filter { imageExts.contains(($0 as NSString).pathExtension.lowercased()) }
                    var cover: Data?
                    if let first = names.sorted(by: { naturalCompare($0, $1) }).first { cover = ZipReader.read(path: d.path, entry: first) }
                    out.append(LocalComic(name: d.deletingPathExtension().lastPathComponent, path: d.path,
                                          kind: .zip, pageCount: names.count, coverData: cover))
                } else if ext == "rar" {
                    let comic = rarComic(d)
                    out.append(comic)
                } else if ext == "7z" {
                    // 一次 open 同时拿「页名 + 封面」。
                    // ⚠️ 原实现是 `list()` + `read()` —— 两次 `open()`，
                    //    而 `open()` 会解压整个包，封面一项就要解压两遍。
                    //    另外原实现用未排序的 `names.first` 当封面，可能是 readme 而非第一页。
                    let (names, cover) = SevenZipBridge.listAndCover(d.path)
                    out.append(LocalComic(name: d.deletingPathExtension().lastPathComponent, path: d.path,
                                          kind: .sevenZip, pageCount: names.count, coverData: cover))
                }
            }
        }
        return out
    }

    private static func rarComic(_ url: URL) -> LocalComic {
        var count: Int32 = 0
        var err: Int32 = 0
        var cover: Data?
        let names = RarBridge.list(url.path, count: &count, err: &err)
        let images = names.filter { imageExts.contains(($0 as NSString).pathExtension.lowercased()) }
        if let first = images.first {
            cover = RarBridge.read(path: url.path, entry: first)
        }
        return LocalComic(name: url.deletingPathExtension().lastPathComponent, path: url.path,
                          kind: .rar, pageCount: images.count, coverData: cover)
    }

    static func pages(of comic: LocalComic) -> [Data] {
        switch comic.kind {
        case .folder:
            let fm = FileManager.default
            let files = ((try? fm.contentsOfDirectory(atPath: comic.path)) ?? [])
                .filter { imageExts.contains(($0 as NSString).pathExtension.lowercased()) }
                .sorted { naturalCompare($0, $1) }
                .map { URL(fileURLWithPath: comic.path).appendingPathComponent($0).path }
            return files.compactMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
        case .zip:
            return ZipReader.list(comic.path)
                .filter { imageExts.contains(($0 as NSString).pathExtension.lowercased()) }
                .sorted { naturalCompare($0, $1) }
                .compactMap { ZipReader.read(path: comic.path, entry: $0) }
        case .rar:
            return RarBridge.pages(comic.path)
        case .sevenZip:
            return SevenZipBridge.pages(comic.path)
        }
    }

    /// 自然排序：page2 在 page10 之前
    static func naturalCompare(_ a: String, _ b: String) -> Bool {
        return a.compare(b, options: .numeric, range: nil, locale: nil) == .orderedAscending
    }
}

/// RAR —— 通过 unrar C 桥接（Bridging Header: unrar_list/unrar_extract）
enum RarBridge {
    static func list(_ path: String, count: UnsafeMutablePointer<Int32>, err: UnsafeMutablePointer<Int32>) -> [String] {
        var c = count.pointee
        var e = err.pointee
        guard let names = unrar_list(path, &c, &e) else {
            count.pointee = c
            err.pointee = e
            return []
        }
        var out: [String] = []
        for i in 0..<Int(c) {
            if let ptr = names[i] { out.append(String(cString: ptr)) }
        }
        unrar_free_list(names, c)
        return out
    }

    static func read(path: String, entry: String) -> Data? {
        var len: Int32 = 0
        var err: Int32 = 0
        guard let ptr = unrar_extract(path, entry, &len, &err), len > 0 else { return nil }
        return Data(bytes: ptr, count: Int(len))   // Data 拷贝，缓冲区下轮复用
    }

    static func pages(_ path: String) -> [Data] {
        var count: Int32 = 0
        var err: Int32 = 0
        let names = list(path, count: &count, err: &err)
            .filter { LocalComicScanner.imageExts.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { LocalComicScanner.naturalCompare($0, $1) }
        return names.compactMap { read(path: path, entry: $0) }
    }
}

/// 7z —— SWCompression（纯 Swift）。open 返回 (info, [SevenZipEntry])
enum SevenZipBridge {

    /// 超过这个大小就**不再解析** 7z。
    ///
    /// ⚠️ 为什么必须设闸门：`SevenZipContainer.open(container:)` 会把
    ///    **整个压缩包读进内存**，并把**所有条目**都解压出来（返回的每个 entry
    ///    都带 `data`）。一个几百 MB、高压缩比的 7z 会瞬间吃掉数 GB 内存 →
    ///    被系统直接杀掉（Jetsam）。
    ///    SWCompression 没有公开「按条目惰性解压」的 API，所以只能靠大小设限。
    ///    超过上限的包**仍然会出现在本地漫画列表里**（`scan` 里按文件名列出），
    ///    只是不解析封面 / 页数 —— 比整个 App 被杀掉好得多。
    private static let maxBytes: Int64 = 300 * 1024 * 1024      // 300MB

    private static func fileSize(_ path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func open(_ path: String) -> [SWCompression.SevenZipEntry]? {
        guard fileSize(path) <= maxBytes else { return nil }
        guard let data = FileManager.default.contents(atPath: path),
              let entries = try? SevenZipContainer.open(container: data) else { return nil }
        return entries
    }

    static func list(_ path: String) -> [String] {
        guard let entries = open(path) else { return [] }
        return entries
            .filter { $0.info.type != .directory }
            .map { $0.info.name }
    }

    static func read(path: String, entry: String) -> Data? {
        guard let entries = open(path) else { return nil }
        guard let target = entries.first(where: { $0.info.type != .directory && $0.info.name == entry }) else { return nil }
        return target.data ?? nil
    }

    /// **一次** `open` 同时取「图片页名列表」和「第一页数据」。
    ///
    /// ⚠️ 为什么需要它：`scan()` 原本先 `list()` 再 `read(path:entry:)`，
    ///    而两个方法各自 `open()` 一次 —— `open()` 会把整个包解压一遍，
    ///    于是**封面一项就要解压两次**（内存与 CPU 都翻倍）。
    ///    顺带修掉一个老问题：原实现用 `names.first`（**未排序、未过滤**）当封面，
    ///    拿到的可能是 `readme.txt` 而不是第一页；这里改成「按自然序排序后的首张图」。
    static func listAndCover(_ path: String) -> (names: [String], cover: Data?) {
        guard let entries = open(path) else { return ([], nil) }
        let imgs = entries
            .filter { $0.info.type != .directory
                      && LocalComicScanner.imageExts.contains(($0.info.name as NSString).pathExtension.lowercased()) }
            .sorted { LocalComicScanner.naturalCompare($0.info.name, $1.info.name) }
        guard let first = imgs.first else { return ([], nil) }
        return (imgs.map { $0.info.name }, first.data ?? nil)
    }

    static func pages(_ path: String) -> [Data] {
        guard let entries = open(path) else { return [] }
        return entries
            .filter { $0.info.type != .directory && LocalComicScanner.imageExts.contains(($0.info.name as NSString).pathExtension.lowercased()) }
            .sorted { LocalComicScanner.naturalCompare($0.info.name, $1.info.name) }
            .compactMap { $0.data ?? nil }
    }
}

/// 轻量 ZIP 读取（中央目录 + zlib 原始 deflate，系统库实现）
enum ZipReader {
    static func list(_ path: String) -> [String] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let tailLen = min(Int(size), 65557)
        try? fh.seek(toOffset: UInt64(size - UInt64(tailLen)))
        let tail = fh.readData(ofLength: tailLen)
        guard let eocd = findEOCD(tail) else { return [] }
        let cdCount = Int(readU16(tail, eocd + 10))
        let cdOffset = Int(readU32(tail, eocd + 16))
        // ⚠️ **必须校验 cdOffset 的范围**：它直接来自文件尾的 EOCD，是**文件内容可控**的。
        //    构造 `cdOffset = 0` 时 `size - cdOffset` 就是**整个文件大小** →
        //    `readData` 会把整个压缩包读进内存当「中央目录」解析。
        //    对几百 MB 的包即内存放大 → 有被构造文件打爆的风险。
        guard cdOffset >= 0, cdOffset < Int(size),
              Int(size) - cdOffset <= 16 * 1024 * 1024 else { return [] }
        try? fh.seek(toOffset: UInt64(cdOffset))
        let cd = fh.readData(ofLength: max(Int(size) - cdOffset, 1))
        var names: [String] = []
        var p = 0
        for _ in 0..<cdCount {
            guard p + 46 <= cd.count, readU32(cd, p) == 0x02014b50 else { break }
            let nameLen = Int(readU16(cd, p + 28))
            let extraLen = Int(readU16(cd, p + 30))
            let commentLen = Int(readU16(cd, p + 32))
            if p + 46 + nameLen <= cd.count {
                let d = cd.subdata(in: (p + 46)..<(p + 46 + nameLen))
                if let name = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1), !name.hasSuffix("/") {
                    names.append(name)
                }
            }
            p += 46 + nameLen + extraLen + commentLen
        }
        return names
    }

    static func read(path: String, entry: String) -> Data? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let tailLen = min(Int(size), 65557)
        try? fh.seek(toOffset: UInt64(size - UInt64(tailLen)))
        let tail = fh.readData(ofLength: tailLen)
        guard let eocd = findEOCD(tail) else { return nil }
        let cdCount = Int(readU16(tail, eocd + 10))
        let cdOffset = Int(readU32(tail, eocd + 16))
        // ⚠️ **必须校验 cdOffset 的范围**：它直接来自文件尾的 EOCD，是**文件内容可控**的。
        //    构造 `cdOffset = 0` 时 `size - cdOffset` 就是**整个文件大小** →
        //    `readData` 会把整个压缩包读进内存当「中央目录」解析。
        //    对几百 MB 的包即内存放大 → 有被构造文件打爆的风险。
        guard cdOffset >= 0, cdOffset < Int(size),
              Int(size) - cdOffset <= 16 * 1024 * 1024 else { return nil }
        try? fh.seek(toOffset: UInt64(cdOffset))
        let cd = fh.readData(ofLength: max(Int(size) - cdOffset, 1))
        var p = 0
        for _ in 0..<cdCount {
            guard p + 46 <= cd.count, readU32(cd, p) == 0x02014b50 else { break }
            let nameLen = Int(readU16(cd, p + 28))
            let extraLen = Int(readU16(cd, p + 30))
            let commentLen = Int(readU16(cd, p + 32))
            let compSize = Int(readU32(cd, p + 20))
            let localOffset = Int(readU32(cd, p + 42))
            let method = Int(readU16(cd, p + 10))
            guard p + 46 + nameLen <= cd.count else { break }
            let nameData = cd.subdata(in: (p + 46)..<(p + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? ""
            p += 46 + nameLen + extraLen + commentLen
            guard name == entry else { continue }
            try? fh.seek(toOffset: UInt64(localOffset))
            let lh = fh.readData(ofLength: 30)
            guard lh.count == 30, readU32(lh, 0) == 0x04034b50 else { return nil }
            let lNameLen = Int(readU16(lh, 26))
            let lExtraLen = Int(readU16(lh, 28))
            try? fh.seek(toOffset: UInt64(localOffset + 30 + lNameLen + lExtraLen))
            let comp = fh.readData(ofLength: compSize)
            if method == 0 { return comp }
            return inflate(comp)
        }
        return nil
    }

    /// deflate → Compression framework
    private static func inflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let dstCap = max(data.count * 8, 1 << 20)
        var dst = Data(count: dstCap)
        let n = dst.withUnsafeMutableBytes { db -> Int in
            data.withUnsafeBytes { sb -> Int in
                compression_decode_buffer(db.bindMemory(to: UInt8.self).baseAddress!, dstCap,
                                          sb.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        if n > 0 { return dst.prefix(n) }
        return nil
    }

    private static func findEOCD(_ tail: Data) -> Int? {
        if tail.count < 22 { return nil }
        for i in stride(from: tail.count - 22, through: max(tail.count - 22 - 65536, 0), by: -1) where readU32(tail, i) == 0x06054b50 {
            return i
        }
        return nil
    }
    private static func readU16(_ d: Data, _ off: Int) -> UInt16 {
        UInt16(d[off]) | (UInt16(d[off + 1]) << 8)
    }
    private static func readU32(_ d: Data, _ off: Int) -> UInt32 {
        UInt32(readU16(d, off)) | (UInt32(readU16(d, off + 2)) << 16)
    }
}
