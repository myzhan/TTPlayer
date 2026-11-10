import Foundation
import CFFmpeg

/// FFmpeg 全局运行时：一次性初始化、日志转接、版本与能力查询。
///
/// 这里是整个解码层的底座：`FFmpegDecoder`（文件解码）、`FFmpegProbe`（元数据）、
/// 电台流解码都建立在它之上。项目里“所有音频解码交给 FFmpeg”就落在这几个文件。
enum FFmpeg {

    /// FFmpeg 的日志走它自己的回调，转接到本项目的 Diagnostics，
    /// 这样解码层的告警/错误能和 App 其它日志汇到一处（--dump-diagnostics 能看到）。
    private static let bootstrap: Void = {
        av_log_set_callback { ctx, level, fmt, va in
            _ = ctx
            // 级别高于 WARNING 的（即更不重要的 debug）直接丢，避免刷屏
            if Int(level) > Int(AV_LOG_WARNING) { return }
            var buf = [CChar](repeating: 0, count: 1024)
            // av_log 用的是 printf 风格，用 vsnprintf 展开（AV_LOG 的 fmt/va 就是这么约定）
            if let va {
                _ = buf.withUnsafeMutableBufferPointer { b in
                    vsnprintf(b.baseAddress, b.count, fmt, va)
                }
            }
            let text = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if Int(level) <= Int(AV_LOG_ERROR) {
                Diagnostics.error("ffmpeg: \(text)")
            } else {
                Diagnostics.log("ffmpeg: \(text)")
            }
        }
    }()

    /// 确保只初始化一次（Swift 静态属性的惰性初始化本身就是线程安全的一次性执行）
    static func ensureInit() {
        _ = bootstrap
    }

    /// FFmpeg 版本串（用于属性面板/自检报告解码来源）
    static var versionString: String {
        ensureInit()
        return String(cString: av_version_info())
    }

    // MARK: - 错误码

    /// 负错误码常量（Swift 拿不到函数式宏，走 C 辅助）
    static var errorEOF: Int32 { cff_averror_eof() }
    static var errorInvalidData: Int32 { cff_averror_invalid_data() }
    static var errorEAGAIN: Int32 { cff_averror_eagain() }

    /// 负错误码 → 可读文本
    static func errstr(_ code: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        cff_errstr(Int32(code), &buf, Int32(buf.count))
        let s = String(cString: buf)
        return s.isEmpty ? "ffmpeg error \(code)" : s
    }

    // MARK: - 编码名

    /// 由 AVCodecID 取人类可读编码名（大写规范化，尽量对齐旧实现里 fourcc 的产物）。
    /// AAC 家族（LC/HE/HEv2/LD/ELD）共用一个 codec_id，只能靠 profile 细分；
    /// 不传 profile（电台流等只看基型）时退回普通“AAC”。
    /// container 是解复用器名（如 "au"/"w64"）：PCM 家族在裸容器里 codec_id 全一样，
    /// 光看编码分不清是 AU 头还是 Wave64 头，加容器前缀让属性面板可辨。
    static func codecName(_ id: AVCodecID, profile: Int32 = AV_PROFILE_UNKNOWN,
                          container: String? = nil) -> String {
        guard id != AV_CODEC_ID_NONE, let c = avcodec_get_name(id) else { return "" }
        let raw = String(cString: c)
        // HE-AAC（SBR）/ HE-AACv2（SBR+PS）不能只写“AAC”，否则用户分不清码流档位
        if id == AV_CODEC_ID_AAC {
            switch profile {
            case AV_PROFILE_AAC_HE: return "HE-AAC"
            case AV_PROFILE_AAC_HE_V2: return "HE-AACv2"
            case AV_PROFILE_AAC_LD: return "AAC-LD"
            case AV_PROFILE_AAC_ELD: return "AAC-ELD"
            default: break
            }
        }
        if let container, let tag = containerPrefixes[container],
           raw.hasPrefix("pcm_"), let bits = pcmBitsLabel(raw) {
            return "\(tag) \(bits)"
        }
        // FFmpeg 名字大小写不一（"mp3" / "aac" / "pcm_s16le" / "ALAC"），
        // 统一映射到和过去一致的展示名
        return nameOverrides[raw] ?? raw.uppercased()
    }

    /// 需要给 PCM 家族加容器前缀的裸容器：WAV/AIFF 的展示名过去就是“PCM 16bit”，
    /// 不在这次范围；AU 与 Wave64 是这次迁回 FFmpeg 才重新露出来的，用户看得出现壳更直观。
    private static let containerPrefixes: [String: String] = [
        "au": "AU",
        "w64": "Wave64",
    ]

    /// pcm_sXXle/be 里抠出位深标签；浮点/对数等变体这里不认（走 nameOverrides）
    private static func pcmBitsLabel(_ raw: String) -> String? {
        switch raw {
        case "pcm_s8", "pcm_u8": return "8bit"
        case "pcm_s16le", "pcm_s16be": return "16bit"
        case "pcm_s24le", "pcm_s24be": return "24bit"
        case "pcm_s32le", "pcm_s32be": return "32bit"
        default: return nil
        }
    }

    /// 覆盖表：把 FFmpeg 内部编码名翻译成用户过去看到的叫法
    private static let nameOverrides: [String: String] = [
        "pcm_s8": "PCM 8bit", "pcm_u8": "PCM 8bit",
        "pcm_s16le": "PCM 16bit", "pcm_s16be": "PCM 16bit",
        "pcm_s24le": "PCM 24bit", "pcm_s24be": "PCM 24bit",
        "pcm_s32le": "PCM 32bit", "pcm_s32be": "PCM 32bit",
        "pcm_f32le": "PCM 32bit 浮点", "pcm_f32be": "PCM 32bit 浮点",
        "pcm_f64le": "PCM 64bit 浮点", "pcm_f64be": "PCM 64bit 浮点",
        "pcm_alaw": "A-law", "pcm_mulaw": "μ-law",
        "mp1": "MP1", "mp2": "MP2", "mp3": "MP3",
        "aac": "AAC", "aac_latm": "AAC LATM",
        "flac": "FLAC", "vorbis": "Vorbis", "opus": "Opus",
        "alac": "ALAC", "ape": "APE", "wavpack": "WavPack", "tta": "TTA",
        "wmav1": "WMA", "wmav2": "WMA",
        "dsd_lsbf": "DSD", "dsd_msbf": "DSD",
        "dsd_lsbf_planar": "DSD", "dsd_msbf_planar": "DSD",
        "ac3": "AC-3", "eac3": "E-AC-3", "mlp": "MLP", "truehd": "TrueHD",
        "adpcm_ima_qt": "IMA ADPCM", "adpcm_ima_wav": "IMA ADPCM",
        "adpcm_ms": "MS ADPCM", "adpcm_ieee_adpcm": "IMA ADPCM",
    ]

    /// DSD 的展示名：把位率折算成 DSD64/128/… 并附 MHz（对齐旧 DSDDecoder 的“DSD64 2.8224MHz”风格）。
    static func dsdLabel(codecId: AVCodecID, dsdBitRate: Int) -> String {
        guard dsdBitRate > 0 else { return "DSD" }
        let a = Double(dsdBitRate) / 44_100
        let b = Double(dsdBitRate) / 48_000
        let order = (abs(a - a.rounded()) < abs(b - b.rounded()) ? a : b).rounded()
        let mhz = String(format: "%.4g", Double(dsdBitRate) / 1_000_000)
        return "DSD\(Int(order)) \(mhz)MHz"
    }

    // MARK: - 能力白名单

    /// 遍历注册的解复用器，收集它们声明的扩展名 → 可播白名单。
    /// 不再向 CoreAudio 现场问能力：FFmpeg 认什么就播什么。
    static func demuxerExtensions() -> Set<String> {
        ensureInit()
        var result = Set<String>()
        var opaque: UnsafeMutableRawPointer?
        while let f = av_demuxer_iterate(&opaque) {
            guard let ext = f.pointee.extensions else { continue }
            let csv = String(cString: ext)
            for e in csv.split(separator: ",") {
                let lowered = e.lowercased()
                // 只认 1~6 位的正常字母数字扩展名，防怪值撑歪白名单
                if lowered.count >= 1, lowered.count <= 6,
                   lowered.allSatisfy({ $0.isLetter || $0.isNumber }) {
                    result.insert(lowered)
                }
            }
        }
        return result
    }

    /// 打开容器但只探测不播——给属性/自检用的轻量入口；调用方负责关闭。
    static func openInput(_ url: URL) -> AVFormatOpenResult? {
        return AVFormatOpenResult(url: url)
    }
}

/// 用 `avformat_open_input` + `avformat_find_stream_info` 打开一个输入的薄封装，
/// 解码器与探针共用；持有 AVFormatContext，deinit 里关闭。
/// 归档条目（`file://…#archive-entry=…`）走自定义 AVIOContext + EntryReader，
/// 其他 URL 依旧读 `url.path`。
final class AVFormatOpenResult {
    var ctx: UnsafeMutablePointer<AVFormatContext>?
    private var archiveIO: ArchiveIO?

    convenience init?(url: URL) {
        FFmpeg.ensureInit()
        var c: UnsafeMutablePointer<AVFormatContext>?
        var io: ArchiveIO? = nil
        if Archive.parseEntryURL(url) != nil {
            guard let opened = try? ArchiveIO.open(url: url), let alloc = avformat_alloc_context() else { return nil }
            opened.attach(to: alloc)
            io = opened
            c = alloc
            let ret = avformat_open_input(&c, nil, nil, nil)
            if ret < 0 {
                if var f: UnsafeMutablePointer<AVFormatContext>? = c { avformat_close_input(&f) }
                io?.dispose()
                return nil
            }
        } else {
            let ret = url.path.withCString { avformat_open_input(&c, $0, nil, nil) }
            guard ret == 0 else { return nil }
        }
        guard let openedCtx = c else {
            io?.dispose()
            return nil
        }
        self.init(ctx: openedCtx, archiveIO: io)
        if avformat_find_stream_info(openedCtx, nil) < 0 {
            avformat_close_input(&self.ctx)
            self.archiveIO?.dispose()
            self.archiveIO = nil
            return
        }
    }

    private init(ctx: UnsafeMutablePointer<AVFormatContext>, archiveIO: ArchiveIO?) {
        self.ctx = ctx
        self.archiveIO = archiveIO
    }

    deinit {
        avformat_close_input(&ctx)
        archiveIO?.dispose()
    }
}
