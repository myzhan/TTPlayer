import Foundation
import AppKit

/// 一首曲目（文件 + 元数据）
final class Track: NSObject {
    let id = UUID()
    let url: URL

    // 元数据（异步解析后填充）
    @Atomic var title: String
    @Atomic var artist: String
    @Atomic var album: String
    @Atomic var duration: Double = 0          // 秒
    @Atomic var sampleRate: Double = 0        // Hz
    @Atomic var channels: Int = 0
    @Atomic var bitRateKbps: Int = 0          // 估算平均码率
    /// 封面小档（112px）。同封面多首曲目共用同一份位图，因为封面实体挂在 coverRef 上
    var cover: NSImage? { coverRef?.art.image }
    /// 封面的共享引用：键 + 共享位图 + 大档来路；没封面时为 nil。
    /// 大图窗要的 256 档不常驻在这里，打开窗口时按它再解一次（见 MetadataReader.largeCover）
    @Atomic var coverRef: CoverArt.Ref?
    /// 封面来路（“内嵌 300×300”/“外部文件 single.png 1200×1200”），
    /// 属性面板与自检都读它；没封面时为空，属性面板会补一句怎么办
    @Atomic var coverSource: String = ""
    /// 从文件实际数据格式（fourcc）读出的编码名，如 MP3 / ALAC / WAV 24bit；
    /// 不拿扩展名猜，所以 .m4a 里的 ALAC 不会被打成 AAC
    @Atomic var formatName: String = ""
    /// 解不开时的人话原因（nil = 能解）；属性面板与日志都拿它回答“为什么放不了”
    @Atomic var decodeProblem: String?
    /// 引用还在、但文件已经不在盘上了（歌单里的失效条目：留着标出来让用户自己决定删不删，
    /// 不静默丢行，见 requirements F04）。只在按档案键还原时才会被标上
    @Atomic var missingOnDisk = false
    /// 曲子里带的 ReplayGain 标签（F02）。nil = 还没解析过；解析过但没标签是 `isEmpty`。
    /// 两者要分得开：属性面板得能回答“没标签”与“还没读到”是两回事，
    /// 响度均衡也只在有标签时动音量，绝不自己分析
    @Atomic var replayGainTags: ReplayGainTags?

    /// CUE 分轨来源（nil = 整个文件就是一曲）；一份镜像可以对应多条曲目
    var cue: CueTrackInfo?

    /// 列表里“网络电台”这一类的类型名（还没收到流信息前先用它顶着）
    static let radioFormatName = "网络电台"

    /// 网络电台：地址是 http/https，没有文件、没有总时长、不能定位
    var isRadio: Bool { RadioURL.isRadio(url) }

    var fileName: String {
        // 电台没有文件名，用 host[:port]/尾段当名字，列表与查找都能认
        if isRadio { return RadioURL.displayName(for: url) }
        return url.deletingPathExtension().lastPathComponent
    }
    var fileExtension: String { url.pathExtension.uppercased() }
    var fileSize: Int64 {
        // 广播地址不是本地资源：resourceValues 会走错路，电台直接当 0
        guard !isRadio else { return 0 }
        return (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
    }

    /// 播放区间起点（秒）：CUE 轨从镜像的该偏移开始，普通轨为 0
    var playStart: Double { cue?.start ?? 0 }
    /// 播放区间终点（秒）；CUE 末轨为 nil，放到镜像结尾
    var playEnd: Double? { cue?.nextStart }
    var isCueSegment: Bool { cue != nil }

    /// 列表去重键：同一镜像的多条 CUE 轨 url 相同，必须带上轨号。
    /// 电台必须用完整地址：两个台可能都叫 `/stream`，只看 path 会互相顶掉。
    /// 归档内条目：path 只到外层归档文件，同归档内多条目会共享，必须带上 fragment。
    var identityKey: String {
        if isRadio { return url.absoluteString }
        if url.fragment?.hasPrefix("archive-entry=") == true { return url.absoluteString }
        guard let cue else { return url.path }
        return "\(cue.sheetURL.path)#track=\(cue.number)"
    }

    init(url: URL) {
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
        self.artist = ""
        self.album = ""
    }

    /// 由电台地址构造：标题先看用户给这个地址起过什么名（F11 的台名按地址存），
    /// 没起过就用 host[:port]/尾段；类型先写“网络电台”，
    /// 真正的编码/采样率/码率要等流里回话（见 AudioEngine 的 onRadioInfo）
    convenience init(radio: URL) {
        self.init(url: radio)
        title = RadioStations.shared.displayName(for: radio)
        formatName = Track.radioFormatName
        channels = 2
    }

    /// 由 CUE 分轨构造：标题/艺人/时长直接就位，不等异步解析（列表一眼能看全）
    convenience init(cueTrack: CueTrackInfo, sheet: CueSheet) {
        self.init(url: cueTrack.fileURL)
        cue = cueTrack
        let name = cueTrack.title.isEmpty
            ? "\(String(format: "%02d", cueTrack.number)) \(sheet.albumTitle)" : cueTrack.title
        title = name
        artist = cueTrack.performer.isEmpty ? sheet.albumPerformer : cueTrack.performer
        album = sheet.albumTitle
        duration = cueTrack.duration ?? 0
    }

    /// 类型描述：优先用读出来的真实编码名，还没解析过就先按容器/扩展名给个名字
    var formatLabel: String {
        formatName.isEmpty ? AudioFormats.containerLabel(for: url) : formatName
    }

    /// 格式筛选用的档位名（requirements F05）：只看条目来路，不看异步解析出来的 `formatName`。
    /// 元数据晚到时筛选菜单不能变来变去（刚勾上「MP3」，解析完变成「MPEG1/2 Layer3」会筛掉正在看的结果）。
    /// 归档里的条目按条目自己的后缀算（外层是 .zip，把「ZIP」当音频格式没意义）；
    /// CUE 分轨的 url 就是那份镜像，自然拿到镜像的格式
    var filterFormat: String {
        if isRadio { return Track.radioFilterFormat }
        if let entry = Archive.entryName(of: url) {
            let ext = (entry as NSString).pathExtension
            return ext.isEmpty ? "归档" : ext.uppercased()
        }
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "其他" : ext
    }
    /// 电台在筛选菜单里自成一档：它没有文件后缀可言
    static let radioFilterFormat = "电台"

    var fileSizeLabel: String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: fileSize)
    }

    /// 属性对话框用的一行行文本
    var propertyLines: [(String, String)] {
        if isRadio { return radioPropertyLines }
        var lines: [(String, String)] = [
            ("文件名", fileName + "." + url.pathExtension.lowercased()),
            ("路径", url.deletingLastPathComponent().path),
            ("类型", formatLabel),
            ("大小", fileSizeLabel),
        ]
        if duration > 0 { lines.append(("时长", TimeFormat.clock(duration))) }
        if sampleRate > 0 { lines.append(("采样率", "\(Int(sampleRate.rounded())) Hz")) }
        if channels > 0 { lines.append(("声道", channels == 2 ? "立体声" : "\(channels) 声道")) }
        if bitRateKbps > 0 { lines.append(("码率", "\(bitRateKbps) kbps")) }
        lines.append(("封面", coverSource.isEmpty ? CoverArt.absentHint : coverSource))
        if missingOnDisk {
            lines.append(("文件状态", "已不在磁盘上（引用保留，可以重新定位也可以删掉）"))
        }
        if let problem = decodeProblem { lines.append(("无法播放", problem)) }
        if let cue {
            // 整盘镜像 + CUE 的情况：属性里说清本轨在镜像中的位置
            lines.append(("CUE 分轨", "第 \(String(format: "%02d", cue.number)) 轨"))
            lines.append(("镜像内起点", TimeFormat.clock(cue.start)))
            if let end = cue.nextStart { lines.append(("镜像内终点", TimeFormat.clock(end))) }
            lines.append(("分轨表", cue.sheetURL.lastPathComponent))
        }
        return lines
    }

    /// 电台的属性：没有路径/大小/封面可言，换成地址与流参数
    private var radioPropertyLines: [(String, String)] {
        var lines: [(String, String)] = [
            ("电台", title),
            ("地址", url.absoluteString),
            ("类型", formatLabel),
            ("时长", "直播（无固定时长）"),
        ]
        if sampleRate > 0 { lines.append(("采样率", "\(Int(sampleRate.rounded())) Hz")) }
        if bitRateKbps > 0 { lines.append(("码率", "\(bitRateKbps) kbps")) }
        if let problem = decodeProblem { lines.append(("无法播放", problem)) }
        return lines
    }
}

extension Track {
    override var description: String { "\(artist) - \(title)" }
}

/// 简单属性包装器（主线程读写，跨线程赋值安全）
@propertyWrapper
struct Atomic<T> {
    private let lock = NSLock()
    private var value: T
    init(wrappedValue: T) { value = wrappedValue }
    var wrappedValue: T {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
