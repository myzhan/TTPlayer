import Foundation
import AppKit

/// 元数据统一走 FFmpeg 探测：`FFmpegProbe` 一次读回编码/采样率/声道/时长/码率 + 标签 + 内嵌封面，
/// 取代过去的 `AVAudioFile`（解码参数）、`AVURLAsset`（标签/封面）与自制的 `APETag`。
enum MetadataReader {

    /// 元数据解析会同时打开容器与解码封面图片。直接扔进 global queue 会在一次导入几百首歌时
    /// 并发铺开，短时间堆出大量框架缓存。限制为两个工人既能并行读盘，又把峰值内存钉住；
    /// 每首结束的 autoreleasepool 让 Objective-C 临时对象及时归还。
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ttplayer.metadata"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    /// 标签缺失时的占位值。界面不必原样展示（菜单栏那种一行字的位置就只显示歌名）
    static let unknownArtist = "未知艺术家"
    static let unknownAlbum = "未知专辑"

    /// 后台解析轨道元数据，完成后回调（回调在主线程）
    static func read(_ track: Track, completion: @escaping () -> Void) {
        // 电台没有文件可读：参数由流里回报，不要去开"文件"（会白等一次网络超时）
        guard !track.isRadio else { return }
        queue.addOperation {
            autoreleasepool { readSync(track) }
            OperationQueue.main.addOperation { completion() }
        }
    }

    static func readSync(_ track: Track) {
        guard !track.isRadio else { return }
        // 一次探测：解码参数 + 标签 + 内嵌封面都由 FFmpeg 读回
        guard let info = FFmpegProbe.probe(track.url) else {
            // 认不出容器：把原因留在曲目上（入表/属性面板/日志才能回答“为什么放不了”）
            track.decodeProblem = AudioFormats.rejectionReason(for: track.url)
            return
        }
        track.decodeProblem = nil
        track.formatName = info.formatName
        track.sampleRate = info.sampleRate
        track.channels = info.channels
        let full = info.durationSeconds
        let bytes = track.fileSize
        if full > 0, bytes > 0 {
            // 码率按整份镜像算（CUE 分轨不能拿本段时长去除整盘字节）
            track.bitRateKbps = Int(Double(bytes) * 8 / full / 1000)
        }
        if let cue = track.cue {
            // CUE 分轨：时长 = 下一轨起点（末轨为镜像结尾）- 本段起点
            track.duration = max(1, (cue.nextStart ?? full) - cue.start)
        } else {
            track.duration = full
        }

        // 标签：分轨的标题/艺人取自 cue，不让镜像自身的标签覆盖
        if track.cue == nil {
            applyTags(info.tags, to: track)
        }
        // 封面照旧要读（整盘镜像里那张 attached_pic 就是这一盘的封面）
        if track.cover == nil, let data = info.coverData {
            attachEmbeddedCover(data, to: track, name: "")
        }
        if track.cover == nil { attachExternalCover(track) }
        if track.artist.isEmpty { track.artist = track.cue?.performer ?? "" }
        if track.artist.isEmpty { track.artist = unknownArtist }
        if track.album.isEmpty { track.album = unknownAlbum }
    }

    /// FFmpeg 已把各容器的标签键规范化成小写（title/artist/album/album_artist…），
    /// 直接按语义键取值即可，不必再解 fourcc/itsk 那套 keySpace 差异。
    private static func applyTags(_ tags: [String: String], to track: Track) {
        let title = tags["title"] ?? ""
        let artist = tags["artist"] ?? ""
        let albumArtist = tags["album_artist"] ?? tags["composer"] ?? ""
        let album = tags["album"] ?? ""
        if !title.isEmpty { track.title = title }
        if !artist.isEmpty { track.artist = artist }
        else if !albumArtist.isEmpty { track.artist = albumArtist }   // 没标单曲艺人时用整盘艺人
        if !album.isEmpty { track.album = album }
    }

    /// 内嵌封面字节 → 常驻小档；同专辑字节相同会命中 CoverArt 的共享键，只解一次。
    private static func attachEmbeddedCover(_ data: Data, to track: Track, name: String) {
        guard data.count > 100, let art = CoverArt.fromData(data) else { return }
        track.coverRef = CoverArt.Ref(key: art.key, art: art, origin: .embedded(track.url))
        track.coverSource = name.isEmpty
            ? "内嵌 \(art.pixelLabel)" : "内嵌 \(name) \(art.pixelLabel)"
    }

    /// 没内嵌图时的回落：同目录的 cover.jpg / folder.png / 与音频同名的图片。
    /// 国内发行的 MP3 很多不带内嵌图但目录里躺着一张封面，这一步直接决定列表好不好看；
    /// 内嵌图存在时不会走到这里，所以外部文件永远不能盖掉真正打进容器的封面
    private static func attachExternalCover(_ track: Track) {
        guard let found = CoverArt.external(for: track) else {
            track.coverSource = ""
            return
        }
        track.coverRef = CoverArt.Ref(key: found.art.key, art: found.art, origin: .file(found.url))
        track.coverSource = "外部文件 \(found.url.lastPathComponent) \(found.art.pixelLabel)"
    }

    /// 封面大图窗要放大时调：曲目上只常驻 112px 的小档，240pt 的格子拿它放大会糊，
    /// 所以按记下的来路把原图再读一次、再解一档大的（同一张图在 CoverArt 的槽位里复用）。
    /// 只有窗口打开才走到这里，所以这笔重读的 I/O 不该压在每首曲目上
    static func largeCover(for track: Track) -> NSImage? {
        guard let ref = track.coverRef else { return nil }
        switch ref.origin {
        case .file(let url):
            return CoverArt.large(fromFile: url, key: ref.key)
        case .embedded(let url):
            guard let data = embeddedCoverData(url) else { return nil }
            return CoverArt.large(fromData: data, key: ref.key)
        }
    }

    /// 再读一次文件里的内嵌封面：统一走 FFmpeg 的 attached_pic
    private static func embeddedCoverData(_ url: URL) -> Data? {
        FFmpegProbe.probe(url)?.coverData
    }
}
