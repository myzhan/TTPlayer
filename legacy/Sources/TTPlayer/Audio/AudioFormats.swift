import Foundation
import AVFoundation

/// 音频格式能力表。
///
/// 能力全部来自 FFmpeg，不再问 CoreAudio：
/// 1. **白名单**：开机时枚举 FFmpeg 注册的解复用器声明的扩展名，它认什么就播什么
///    （`FFmpeg.demuxerExtensions()`）；问不到才退回保底集合。
/// 2. **编码名**：由 `FFmpegProbe` 从容器里读实际编码（`FFmpeg.codecName`），
///    不拿扩展名猜——m4a 里的 ALAC 该叫 ALAC，而不是 AAC。
/// 3. **放不了的原因**：FFmpeg 也解不了的格式（WMA/APE/WavPack…），
///    给一句人话说明，而不是静默跳过。
enum AudioFormats {

    // MARK: - 扩展名分类

    /// 保底白名单：本项目从第一天就支持的格式，运行时查询失败时仍可用
    static let floorExtensions: Set<String> = [
        "mp3", "m4a", "mp4", "aac", "flac", "wav", "aiff", "aif", "caf",
    ]

    /// 视频容器：里面可能有音轨，拖单文件时值得试一试，但整目录扫描不该把电影当歌曲灌进列表
    static let videoExtensions: Set<String> = ["mov", "qt"]

    /// 歌单文件（展开后入表，本身不是一首曲子）
    static let playlistExtensions: Set<String> = ["m3u", "m3u8"]

    /// 分轨表（单独统计，命中时把一份镜像拆成多首）
    static let cueExtension = "cue"

    /// 归档容器（v1.23 新增）：zip / tar / tar.gz / tar.bz2 / 7z / rar / rar5。
    /// 不进 `playableExtensions` 也不进 `scanExtensions`，避免把归档当一首歌入表；
    /// 目录扫描时 `absorbDirectory` 会把 `archiveExtensions` 单独并入发现集，命中
    /// 后路由到 `absorbArchive`。`gz/bz2` 单写也能进（libarchive 能嗅探 single-stream
    /// 压缩包）。
    static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "bz2", "7z", "rar"]

    /// FFmpeg 注册的解复用器声明的扩展名（开机时枚举一次）
    private static let ffmpegExtensions: Set<String> = FFmpeg.demuxerExtensions()

    /// FFmpeg 认得、但解复用器没在 `AVInputFormat.extensions` 里声明的容器：
    /// 枚举拿不到扩展名，目录扫描就会漏掉它们，这里手动补上。
    /// - dsf：DSD Stream File；
    /// - au / snd：Sun AU（ff_au_demuxer 只写了 codec_tag不写 extensions）；
    /// - w64：Sony Wave64（wavdec.c 里与 wav 共用一个实现，也没声明 extensions）。
    /// DFF（DSDIFF）本 build 不在支持范围：FFmpeg n9.0 开头就没有 DSDIFF demuxer（只有 iff 壳内），
    /// 手动补进去反而会在导入时给“解不开”的回执，不如不在白名单。
    private static let undeclaredExtensions: Set<String> = ["dsf", "au", "snd", "w64"]

    /// FFmpeg 实测可读的扩展名（问不到就退回 floorExtensions）
    static let systemExtensions: Set<String> =
        ffmpegExtensions.isEmpty
            ? floorExtensions.union(undeclaredExtensions)
            : ffmpegExtensions.union(undeclaredExtensions)

    /// 可以直接播放的音频扩展名：FFmpeg 认得 ∪ 保底集合
    static let playableExtensions: Set<String> =
        systemExtensions.union(floorExtensions).union(PCMDecoders.extensions)

    /// 目录递归时认作歌曲的扩展名（排除视频容器，避免扫 ~/Movies 灌进一堆电影）
    static let scanExtensions: Set<String> = playableExtensions.subtracting(videoExtensions)

    /// 打包脚本用：交给 LaunchServices 登记的扩展名
    /// （跟着运行面白名单走，不在 plist 里手抄；视频容器不登记，免得 Finder 把电影也递过来）
    static var documentExtensions: [String] {
        scanExtensions.union(playlistExtensions).union([cueExtension]).sorted()
    }

    // MARK: - 判定

    /// 单个文件被直接拖进来/选中时是否算音频（视频容器也算，因为可能带音轨）
    static func isPlayable(_ url: URL) -> Bool {
        playableExtensions.contains(url.pathExtension.lowercased())
    }

    /// 目录扫描时是否算一首歌
    static func isScannable(_ url: URL) -> Bool {
        scanExtensions.contains(url.pathExtension.lowercased())
    }

    static func isPlaylist(_ url: URL) -> Bool {
        playlistExtensions.contains(url.pathExtension.lowercased())
    }

    static func isCue(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == cueExtension
    }

    /// 归档容器判定。目前一律看单后缀命中 archiveExtensions；tar.gz / tar.bz2 里
    /// pathExtension 取到的是 gz/bz2，也在集合内，自然命中。
    static func isArchive(_ url: URL) -> Bool {
        archiveExtensions.contains(url.pathExtension.lowercased())
    }

    /// 白名单之外、用户手里的“音频文件”扩展名 → FFmpeg 也解不了的原因
    /// （键为小写扩展名；只列 FFmpeg 未编入解码器的真不支持格式，没命中的一律走兜底文案）
    static let unsupportedReasons: [String: String] = [
        "tak": "TAK 无损压缩，本播放器的 FFmpeg 未编入该解码器",
        "mpc": "Musepack（.mpc）是有损压缩，本播放器的 FFmpeg 未编入该解码器",
        "mp+": "Musepack（.mp+）本播放器的 FFmpeg 未编入该解码器",
        "mpp": "Musepack（.mpp）本播放器的 FFmpeg 未编入该解码器",
        "shn": "Shorten 无损格式，本播放器的 FFmpeg 未编入该解码器",
        "ra": "RealAudio（.ra）本播放器的 FFmpeg 未编入该解码器",
        "ram": "RealAudio（.ram）本播放器的 FFmpeg 未编入该解码器",
        "rm": "RealMedia（.rm）本播放器的 FFmpeg 未编入该解码器",
        "mid": "MIDI 是音符指令不是录音，本播放器未接音色合成",
        "midi": "MIDI 是音符指令不是录音，本播放器未接音色合成",
        "kar": "MIDI karaoke 文件是音符指令，本播放器未接音色合成",
        "mod": "Tracker 模块音乐（.mod）需要专用解调器，本播放器的 FFmpeg 未编入",
        "xm": "Tracker 模块音乐（.xm）需要专用解调器，本播放器的 FFmpeg 未编入",
        "s3m": "Tracker 模块音乐（.s3m）需要专用解调器，本播放器的 FFmpeg 未编入",
        "it": "Tracker 模块音乐（.it）需要专用解调器，本播放器的 FFmpeg 未编入",
        "nsf": "FC 音芯转储（.nsf）需要专用模拟器，本播放器的 FFmpeg 未编入",
        "sid": "C64 音芯转储（.sid）需要专用模拟器，本播放器的 FFmpeg 未编入",
        "gym": "MD 音芯转储（.gym）需要专用模拟器，本播放器的 FFmpeg 未编入",
        "vgz": "游戏音乐压缩转储（.vgz）需要专用模拟器，本播放器的 FFmpeg 未编入",
        "m4v": "M4V 是带 DRM 的视频文件，不是可解的音频",
        "aa": "Audible 有声书（.aa）带专有加密，无法解密",
        "m4p": "受保护的 M4P（旧 iTunes DRM）无法解密播放",
    ]

    /// 为什么放不了：优先给“这个格式叫什么、缺什么”，其次给兜底文案
    static func rejectionReason(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if archiveExtensions.contains(ext) {
            return "已支持的归档容器（.\(ext)），用 '添加文件…' 或直接拖进来即可展开"
        }
        if let reason = unsupportedReasons[ext] {
            // 少数条目自己已经写了替代方案（如 DSD 要转 FLAC），不再挂一句重复的
            return reason.contains("转成") ? reason : reason + "；可先转成 MP3 / M4A / FLAC / WAV"
        }
        if videoExtensions.contains(ext) {
            return "QuickTime 影片（.\(ext)）里没找到可解码的音轨"
        }
        if ext.isEmpty { return "这个文件没有扩展名，FFmpeg 从内容也认不出音频" }
        // 同时给出 `.ext`（小写带点，照着用户看到的文件名说）与 `EXT`（大写规范名）：
        // 前者让未知扩展名的兜底能自证是哪个后缀，后者让 WMA 这类有正式写法的格式认得出名字
        return "本播放器的 FFmpeg 不认识 .\(ext)（\(ext.uppercased()) 不在可解容器清单里）"
    }

    // MARK: - 容器显示名

    /// 容器扩展名 → 显示名（PCM 类数据要靠容器名才有意义）
    static let containerNames: [String: String] = [
        "wav": "WAV", "bwf": "BWF", "wave": "WAV", "rf64": "RF64", "w64": "Wave64",
        "aif": "AIFF", "aiff": "AIFF", "aifc": "AIFC", "caf": "CAF", "caff": "CAF",
        "au": "AU", "snd": "AU", "sd2": "SD2",
        "m4a": "M4A", "m4b": "M4B", "m4r": "M4R", "mp4": "MP4", "mov": "MOV", "qt": "MOV",
        "3gp": "3GP", "3g2": "3GP", "mpg4": "MP4",
        "ogg": "Ogg", "oga": "Ogg", "opus": "Opus", "spx": "Speex",
        "mp1": "MP1", "mp2": "MP2", "mp3": "MP3", "mpa": "MP2", "m1a": "MP1", "m2a": "MP2",
        "mpeg": "MP2", "aac": "AAC", "adts": "AAC", "latm": "AAC", "loas": "AAC", "xhe": "AAC",
        "flac": "FLAC", "dsf": "DSF", "dff": "DFF",
        "ac3": "AC-3", "ec3": "E-AC-3", "eac3": "E-AC-3",
        "amr": "AMR", "awb": "AMR-WB",
    ]

    static func containerLabel(for url: URL) -> String {
        containerNames[url.pathExtension.lowercased()] ?? url.pathExtension.uppercased()
    }

    /// UInt32 fourcc → 4 字符（不可打印字符补空格后裁掉）
    static func fourCC(_ id: UInt32) -> String {
        guard id != 0 else { return "" }
        var value = id.bigEndian
        return withUnsafeBytes(of: &value) { raw in
            let bytes = raw.prefix(4).map { ($0 >= 32 && $0 < 127) ? $0 : UInt8(32) }
            return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
    }

    /// 点了播但引擎加载失败时的人话原因。
    /// 顺序很关键：先看文件还在不在/是不是空文件，再看这个格式系统解不解，
    /// 最后才把系统错误文本透出去（不然用户只看到“操作无法完成”这种废话）
    static func playbackProblem(for track: Track, error: Error) -> String {
        let url = track.url
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            return track.isCueSegment
                ? "分轨表引用的镜像已不在磁盘上（\(url.lastPathComponent)）"
                : "文件已不在磁盘上（可能被移动或删除）"
        }
        if track.fileSize == 0 { return "文件是 0 字节，里面没有音频数据" }
        let ext = url.pathExtension.lowercased()
        if PCMDecoders.owns(url) { return "\(ext.uppercased()) 解码失败：FFmpeg 打不开（文件头不符合规范，疑是损坏或伪装的 .\(ext)）" }
        if unsupportedReasons[ext] != nil { return rejectionReason(for: url) }
        if !playableExtensions.contains(ext) { return rejectionReason(for: url) }
        if videoExtensions.contains(ext) {
            return "QuickTime 影片（.\(ext)）里没找到系统能解码的音轨"
        }
        let detail = systemErrorText(error)
        let codec = track.formatName.isEmpty ? containerLabel(for: url) : track.formatName
        return "\(codec) 数据解码失败（\(detail)），可能是文件损坏或使用了系统不支持的子格式"
    }

    /// 系统错误的可读形式。CoreAudio 的 OSStatus 常常是四个字符拼出来的整数，
    /// 直接打 localizedDescription 只会得到“操作无法完成”这种废话，所以能反成 fourcc 就反成 fourcc
    static func systemErrorText(_ error: Error) -> String {
        // 引擎自己包的“打不开”里带着系统原始错误，剥开看里层
        let cause: Error
        if case AudioEngine.EngineError.unsupportedFile(let underlying) = error {
            cause = underlying
        } else {
            cause = error
        }
        let ns = cause as NSError
        let code = fourCC(UInt32(truncatingIfNeeded: ns.code))
        if !code.isEmpty, ns.domain == "com.apple.coreaudio.avfaudio" || ns.domain == NSOSStatusErrorDomain {
            return "系统解码器报错 '\(code)'"
        }
        let text = ns.localizedDescription
        // 系统自己那句“操作无法完成（error 0）”没有信息量，不原文往上报；
        // 比对用“be completed”，因为本地化文案里的撇号是 U+2019，写 ASCII 撇号对不上
        return text.contains("be completed") || text.contains("error 0")
            ? "系统解码器不肯读这个文件" : text
    }

}

