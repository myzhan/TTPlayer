import CLibarchive
import CFFmpeg
import Foundation

/// 归档容器流式读取。zip / tar / tar.gz / tar.bz2 / 7z / rar / rar5 一次覆盖，
/// 底层是 macOS SDK 自带的 libarchive（`/usr/lib/libarchive.2.dylib`，
/// 声明见 Sources/CLibarchive/include/shim.h）。
///
/// 三条硬约束：
/// - **不解压到磁盘**：条目要么整个进 `Data`（≤ 200 MB），要么以 libarchive 游标
///   为准做流式重放；LRU 池 5 个 EntryReader，超出淘汰。
/// - **同归档被外部改动**：mtime 变了就把 LRU 里同 path 的 reader 全清掉，避免
///   旧偏移读到错位的字节。
/// - **加密条目**：`archive_entry_is_encrypted` 非 0 时不读，`Archive.list` 里
///   会带出 encrypted 标志，让 `LibraryStore.absorbArchive` 决定是整档拒收还是
///   单条跳过。
enum Archive {
    struct Entry {
        let path: String
        let size: Int64
        let encrypted: Bool
    }

    /// 全量入内存的条目上限。超过这个尺寸走流式重放分支。
    static let inMemoryCap: Int64 = 200 * 1024 * 1024

    // MARK: - URL 复合表示

    /// 归档内条目的 URL 写法：`file:///…/album.zip#archive-entry=<percent-encoded path>`
    /// 归档 file URL 保持不变，只在 fragment 里挂条目路径；
    /// `Track.identityKey` 见到这个 fragment 会走 `absoluteString` 分支去重。
    private static let fragmentPrefix = "archive-entry="

    static func makeEntryURL(archive: URL, entry: String) -> URL? {
        guard var c = URLComponents(url: archive, resolvingAgainstBaseURL: false) else { return nil }
        // .alphanumerics 只留字母与数字，其他全 escape；round-trip 靠 removingPercentEncoding
        c.percentEncodedFragment = fragmentPrefix +
            (entry.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? entry)
        return c.url
    }

    static func parseEntryURL(_ url: URL) -> (archive: URL, entry: String)? {
        guard let f = url.fragment, f.hasPrefix(fragmentPrefix) else { return nil }
        let enc = String(f.dropFirst(fragmentPrefix.count))
        guard let entry = enc.removingPercentEncoding else { return nil }
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.fragment = nil
        c.percentEncodedFragment = nil
        guard let archive = c.url else { return nil }
        return (archive, entry)
    }

    // MARK: - 条目枚举

    /// 打开归档一次，返回条目表；失败返回 nil，lastError 里带一句人话。
    /// 只读 header 不读 data，即使 10 GB 归档也秒回（除非容器格式本身需要索引扫全表）。
    static func list(url: URL) -> [Entry]? {
        guard let a = archive_read_new() else {
            lastError = "libarchive 分配失败"
            return nil
        }
        defer { archive_read_free(a) }
        _ = archive_read_support_filter_all(a)
        _ = archive_read_support_format_all(a)
        let path = url.path
        if archive_read_open_filename(a, path, 16384) != CLARCHIVE_OK {
            lastError = errString(a) ?? "打不开"
            return nil
        }
        var entries: [Entry] = []
        var entryPtr: UnsafeMutablePointer<archive_entry>?
        while true {
            let r = archive_read_next_header(a, &entryPtr)
            if r == CLARCHIVE_EOF { break }
            if r < CLARCHIVE_OK {
                lastError = errString(a) ?? "条目枚举中断"
                return nil
            }
            guard let e = entryPtr else { continue }
            let nameP = archive_entry_pathname(e)
            let name = nameP.map { String(cString: $0) } ?? ""
            let size = archive_entry_size(e)
            let enc = archive_entry_is_encrypted(e) != 0
            entries.append(Entry(path: name, size: size, encrypted: enc))
        }
        return entries
    }

    /// 上一次 list/open 失败的描述，给拒收提示用。
    private(set) static var lastError: String?

    private static func errString(_ a: UnsafeMutablePointer<archive>?) -> String? {
        a.flatMap { archive_error_string($0) }.map { String(cString: $0) }
    }

    // MARK: - Reader 缓存

    /// LRU 池：key = archive path + entry name + mtime。
    /// 单进程内共享，播放器同一时刻只可能有一个真在放，但元数据/封面探测可能并行。
    static func reader(archive: URL, entry: String) -> EntryReader? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: archive.path)
        let mtime = (attrs?[.modificationDate] as? Date) ?? Date.distantPast
        let key = "\(archive.path)\u{0}\(entry)\u{0}\(mtime.timeIntervalSince1970)"
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cache[key] {
            cache.removeValue(forKey: key)   // 触到就重新插入更新 LRU
            cache[key] = hit
            return hit
        }
        guard let r = EntryReader(archive: archive, entry: entry) else { return nil }
        cache[key] = r
        while cache.count > cacheCapacity, let oldest = cache.first?.key {
            cache.removeValue(forKey: oldest)
        }
        return r
    }

    /// 归档外部改动后调，把旧条目 reader 全清；下次访问重开。
    static func invalidate(archive: URL) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        let prefix = archive.path + "\u{0}"
        for k in cache.keys where k.hasPrefix(prefix) { cache.removeValue(forKey: k) }
    }

    private static let cacheLock = NSRecursiveLock()
    private static var cache: [String: EntryReader] = [:]
    private static let cacheCapacity = 5

    /// 外层归档文件名当 album：“TestArtist-Album.zip” → “TestArtist-Album”；
    /// "album.tar.gz" → "album"（一次剥掉 archiveExtensions 里能剥的后缀）。
    static func albumName(for url: URL) -> String {
        var name = url.lastPathComponent
        let lowers = ["tar.gz", "tar.bz2"]
        for dbl in lowers where name.lowercased().hasSuffix(dbl) {
            // 剥掉 "<dbl>" 前面那个点（否则“专辑.tar.gz”会剩“专辑.”）
            name = String(name.dropLast(dbl.count + 1))
            return name.isEmpty ? url.deletingPathExtension().lastPathComponent : name
        }
        if let ext = url.pathExtension as String?, !ext.isEmpty,
           name.lowercased().hasSuffix("." + ext.lowercased()) {
            name = String(name.dropLast(ext.count + 1))
        }
        return name.isEmpty ? url.deletingPathExtension().lastPathComponent : name
    }
}

// MARK: - EntryReader

/// 单个条目的读取端；对上层（FFmpeg AVIOContext）呈现"一段可 seek 的字节流"。
///
/// 两种模式：
/// - **cached**：条目 ≤ `Archive.inMemoryCap`，open 时一次读完进 `Data`，
///   read/seek 就是纯内存拷贝。绝大多数歌/整盘 wav 走这条。
/// - **streaming**：条目 > 200 MB 或 size 元数据缺失；保留 libarchive 游标，
///   前向读增量，seek 后向 = close+reopen+iterate 到同 entry+skip 到目标偏移。
final class EntryReader {
    let size: Int64
    private var offset: Int64 = 0
    private var cached: Data?
    private let archiveURL: URL
    private let entryName: String
    /// streaming 模式下 live archive 句柄；cached 模式为 nil。
    private var a: UnsafeMutablePointer<archive>?
    private let lock = NSRecursiveLock()

    /// 打开并（若适用）全量缓存。返回 nil 表示打不开或 entry 不存在。
    init?(archive: URL, entry: String) {
        archiveURL = archive
        entryName = entry
        // 先扫一遍 header 拿到 entry.size 与 encrypted
        guard let listed = Archive.list(url: archive),
              let target = listed.first(where: { $0.path == entry }) else { return nil }
        if target.encrypted { return nil }
        size = target.size
        if target.size >= 0 && target.size <= Archive.inMemoryCap {
            // cached 模式：一次读完
            var buf = Data(capacity: Int(target.size))
            guard let a = archive_read_new() else { return nil }
            defer { archive_read_free(a) }
            _ = archive_read_support_filter_all(a)
            _ = archive_read_support_format_all(a)
            let path = archive.path
            if archive_read_open_filename(a, path, 16384) != CLARCHIVE_OK { return nil }
            var ePtr: UnsafeMutablePointer<archive_entry>?
            while true {
                let r = archive_read_next_header(a, &ePtr)
                if r == CLARCHIVE_EOF { return nil }
                if r < CLARCHIVE_OK { return nil }
                if let e = ePtr, let n = archive_entry_pathname(e), String(cString: n) == entry { break }
            }
            let cap = Int(target.size)
            buf.count = cap
            let got = buf.withUnsafeMutableBytes { raw -> Int in
                let p = raw.baseAddress!
                return cff_archive_read_all(a, p, raw.count)
            }
            if got < 0 { return nil }
            buf.count = got
            cached = buf
        } else {
            // streaming：保留 live 句柄；游标定位到 entry 起始
            cached = nil
            if reopen(skipTo: 0) < 0 { return nil }
        }
    }

    deinit { closeLive() }

    // MARK: AVIO 回调对偶

    /// AVIOContext.read_packet：把最多 count 字节拷进 buf，返回实际读的（0 = EOF，<0 错误）
    func read(into buf: UnsafeMutableRawPointer?, count: Int) -> Int {
        guard count > 0, let buf else { return 0 }
        lock.lock(); defer { lock.unlock() }
        if let data = cached {
            let remain = max(0, data.count - Int(offset))
            let n = min(count, remain)
            if n <= 0 { return 0 }
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
                _ = memcpy(buf, raw.baseAddress!.advanced(by: Int(offset)), n)
            }
            offset += Int64(n)
            return n
        }
        guard let a else { return -1 }
        // streaming：直接读，libarchive 会按 entry 尾返回 0
        let r = cff_archive_read_all(a, buf, min(count, 65536))
        if r < 0 { return Int(r) }
        offset += Int64(r)
        return Int(r)
    }

    /// AVIOContext.seek：whence 0=SET/1=CUR/2=END，0x10000=SIZE（只回 size 不动游标）
    func seek(to pos: Int64, whence: Int32) -> Int64 {
        // AVIOSEEK_SIZE：AVIO 用它拿总长
        if whence == 0x10000 { return size }
        lock.lock(); defer { lock.unlock() }
        let target: Int64
        switch whence {
        case 0: target = pos
        case 1: target = offset + pos
        case 2: target = (size >= 0 ? size : 0) + pos
        default: return -1
        }
        if target < 0 { return -1 }
        if cached != nil {
            offset = target
            return offset
        }
        // streaming：往前近跳 = skip 增量，往后远跳 = 关闭重开
        if target >= offset {
            return skipForward(to: target)
        }
        return reopen(skipTo: target)
    }

    /// 当前位置（给上层的诊断/测试用）
    var currentPosition: Int64 { offset }

    // MARK: 内部

    private func skipForward(to target: Int64) -> Int64 {
        let need = target - offset
        if need == 0 { return offset }
        guard let a else { return -1 }
        // 64 KB 步长丢弃
        let chunk = 65536
        let tmp = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { tmp.deallocate() }
        var left = need
        while left > 0 {
            let step = Int(min(Int64(chunk), left))
            let r = cff_archive_read_all(a, tmp, step)
            if r <= 0 { break }     // 提前 EOF：接受
            left -= Int64(r)
        }
        offset = target - left
        return offset
    }

    /// 关档 + 重开 + iterate 到目标 entry + skip 到 target；返回最终 offset。
    @discardableResult
    private func reopen(skipTo target: Int64) -> Int64 {
        closeLive()
        guard let newA = archive_read_new() else { return -1 }
        _ = archive_read_support_filter_all(newA)
        _ = archive_read_support_format_all(newA)
        let path = archiveURL.path
        if archive_read_open_filename(newA, path, 16384) != CLARCHIVE_OK {
            archive_read_free(newA)
            return -1
        }
        var ePtr: UnsafeMutablePointer<archive_entry>?
        while true {
            let r = archive_read_next_header(newA, &ePtr)
            if r == CLARCHIVE_EOF { archive_read_free(newA); return -1 }
            if r < CLARCHIVE_OK { archive_read_free(newA); return -1 }
            if let e = ePtr, let n = archive_entry_pathname(e), String(cString: n) == entryName { break }
        }
        a = newA
        offset = 0
        return skipForward(to: target)
    }

    private func closeLive() {
        if let a {
            archive_read_close(a)
            archive_read_free(a)
        }
        self.a = nil
    }
}

// MARK: - FFmpeg AVIOContext 桥接

/// 把 EntryReader 包成 FFmpeg 的自定义 IO：分配 read buffer + avio_alloc_context，
/// 提供 read/seek 的 @convention(c) 桥接。FFmpegDecoder、FFmpegProbe、
/// AVFormatOpenResult 共用这一份，避免三处各写一遍生命周期。
///
/// 生命周期：
/// - `attach(to:)` 把 AVIOContext 挂到 fmtCtx.pb，并置 `AVFMT_FLAG_CUSTOM_IO`，
///   这样 `avformat_close_input` 只关闭容器资源、不动 pb；
/// - 上层调用 `avformat_close_input` 之后再调 `dispose()` 释放 buffer 和 AVIOContext；
/// - reader 走 `Unmanaged.passUnretained` 传下去，`Archive.reader(...)` 里的 LRU
///   池持有强引用；`ArchiveIO` 自己也保留 reader 引用，防止 dispose 前被淘汰。
final class ArchiveIO {
    /// AVIOContext 内部缓冲；一次填充满，FFmpeg 按需消费。
    private static let bufferCapacity = 32 * 1024

    private var io: UnsafeMutablePointer<AVIOContext>?
    /// reader 由 Archive 的 LRU 池持有；这里保留一份引用，防止中途被淘汰后野指针。
    private let reader: EntryReader

    /// url 不是归档条目时返回 nil（走普通文件路径）；是归档条目但 reader 打不开时抛错。
    /// 抛错以便上层给出「归档打不开」的提示，而不是回退到「把这个 URL 当文件打开」。
    static func open(url: URL) throws -> ArchiveIO? {
        guard let (archive, entry) = Archive.parseEntryURL(url) else { return nil }
        guard let reader = Archive.reader(archive: archive, entry: entry) else {
            throw FFmpegDecoder.DecodeError.cannotOpen(reason: "归档条目打不开：\(entry)")
        }
        // 重置 reader 游标到 0：LRU 可能返回一个已被前一次探测消费过的实例，
        // FFmpeg 的 probe_format 不会主动 seek(0)，它假定 pb 起始位置就是文件头。
        _ = reader.seek(to: 0, whence: 0)
        guard let raw = av_malloc(bufferCapacity) else {
            throw FFmpegDecoder.DecodeError.cannotOpen(reason: "IO 缓冲分配失败")
        }
        let opaque = Unmanaged.passUnretained(reader).toOpaque()
        guard let io = avio_alloc_context(raw.assumingMemoryBound(to: UInt8.self),
                                          Int32(bufferCapacity), 0, opaque,
                                          readCB, nil, seekCB) else {
            av_free(raw)
            throw FFmpegDecoder.DecodeError.cannotOpen(reason: "IO 上下文分配失败")
        }
        return ArchiveIO(io: io, reader: reader)
    }

    private init(io: UnsafeMutablePointer<AVIOContext>, reader: EntryReader) {
        self.io = io
        self.reader = reader
    }

    /// 把自定义 IO 挂到容器上下文；调用方随后必须 `avformat_open_input(&fmt, nil, nil, nil)`。
    func attach(to fmt: UnsafeMutablePointer<AVFormatContext>) {
        guard let io else { return }
        fmt.pointee.pb = io
        fmt.pointee.flags |= Int32(AVFMT_FLAG_CUSTOM_IO)
    }

    /// 必须在 `avformat_close_input` **之后** 调；deinit 里也会兜底一次。
    /// 释放当前 io->buffer（FFmpeg 可能已 realloc 过）+ io 本身。
    func dispose() {
        guard io != nil else { return }
        if let b = io?.pointee.buffer { av_free(b) }
        avio_context_free(&io)
    }

    deinit { dispose() }

    private static let readCB: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, Int32) -> Int32 = { opq, buf, size in
        guard let opq, let buf, size > 0 else { return 0 }
        let reader = Unmanaged<EntryReader>.fromOpaque(opq).takeUnretainedValue()
        return Int32(reader.read(into: buf, count: Int(size)))
    }

    private static let seekCB: @convention(c) (UnsafeMutableRawPointer?, Int64, Int32) -> Int64 = { opq, pos, whence in
        guard let opq else { return -1 }
        let reader = Unmanaged<EntryReader>.fromOpaque(opq).takeUnretainedValue()
        return reader.seek(to: pos, whence: whence)
    }
}
