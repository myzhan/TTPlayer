import Foundation
import CFFmpeg

/// 一次容器探测的结果（时长/编码/采样率/声道/码率 + 标签 + 内嵌封面）。
struct ProbeInfo {
    var formatName = ""
    /// 解复用器名（"au"/"w64"/"mp3"/"mov"…）；给 PCM 家族拼容器前缀用，同名字段不多。
    var containerName: String? = nil
    var sampleRate: Double = 0
    var channels: Int = 0
    var durationSeconds: Double = 0
    var bitRateKbps: Int = 0
    /// 归一化后的标签（键小写：title / artist / album / track / genre / date）
    var tags: [String: String] = [:]
    /// 内嵌封面原始字节（jpeg/png…），交给 CoverArt/ImageIO 再解码
    var coverData: Data?
    var coverMime: String?
}

/// 元数据探测统一走 FFmpeg：取代过去的 `AVAudioFile`（解码参数）与 `AVURLAsset`（标签/封面）。
enum FFmpegProbe {

    static func probe(_ url: URL) -> ProbeInfo? {
        FFmpeg.ensureInit()
        var fmt: UnsafeMutablePointer<AVFormatContext>?
        var archiveIO: ArchiveIO? = nil
        let openRet: Int32
        if Archive.parseEntryURL(url) != nil {
            guard let io = try? ArchiveIO.open(url: url), let alloc = avformat_alloc_context() else { return nil }
            io.attach(to: alloc)
            archiveIO = io
            fmt = alloc
            openRet = avformat_open_input(&fmt, nil, nil, nil)
        } else {
            openRet = url.path.withCString { avformat_open_input(&fmt, $0, nil, nil) }
        }
        defer {
            var c: UnsafeMutablePointer<AVFormatContext>? = fmt
            if c != nil { avformat_close_input(&c) }
            archiveIO?.dispose()
        }
        guard openRet == 0, let ctx = fmt else { return nil }

        // 探测超时设短一点：损坏/超大头文件不要拖住导入线程
        if avformat_find_stream_info(ctx, nil) < 0 { return nil }

        var info = ProbeInfo()
        if let iformat = ctx.pointee.iformat {
            info.containerName = String(cString: iformat.pointee.name)
        }

        // 主音轨：编码/采样率/声道
        let idx = av_find_best_stream(ctx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        if idx >= 0, let stream = ctx.pointee.streams[Int(idx)], let par = stream.pointee.codecpar {
            info.formatName = FFmpeg.codecName(par.pointee.codec_id, profile: par.pointee.profile,
                                               container: info.containerName)
            info.sampleRate = Double(par.pointee.sample_rate)
            info.channels = Int(par.pointee.ch_layout.nb_channels)
            if par.pointee.bit_rate > 0 {
                info.bitRateKbps = Int(par.pointee.bit_rate / 1000)
            }
            if stream.pointee.duration > 0 {
                let tb = stream.pointee.time_base
                info.durationSeconds = Double(stream.pointee.duration) *
                    Double(tb.num) / Double(max(1, tb.den))
            }
        }

        // 整容器时长优先（更准），码率兜底
        if ctx.pointee.duration > 0 {
            info.durationSeconds = Double(ctx.pointee.duration) / Double(AV_TIME_BASE)
        }
        if info.bitRateKbps == 0, ctx.pointee.bit_rate > 0 {
            info.bitRateKbps = Int(ctx.pointee.bit_rate / 1000)
        }

        // 裸流(如 ADTS)无容器时长→逐包计数估算。HE-AAC 的 par.sample_rate 是核心 SBR 前的
        // 一半、frame_size 仍 1024，两者相除与播放时实际 44.1k/2048 完全一致，无需特判。
        if info.durationSeconds == 0, idx >= 0,
           let stream = ctx.pointee.streams[Int(idx)], let par = stream.pointee.codecpar,
           par.pointee.sample_rate > 0 {
            info.durationSeconds = estimateDurationByPackets(ctx, streamIndex: idx, par: par)
        }

        // 标签：容器级 + 音频流级（后者补前者缺的字段）
        var tags = collectTags(ctx.pointee.metadata)
        if idx >= 0, let stream = ctx.pointee.streams[Int(idx)] {
            for (k, v) in collectTags(stream.pointee.metadata) where tags[k] == nil {
                tags[k] = v
            }
        }
        info.tags = tags

        // 内嵌封面：找带 ATTACHED_PIC 属性的流
        let nb = Int(ctx.pointee.nb_streams)
        for i in 0..<nb {
            guard let stream = ctx.pointee.streams[i] else { continue }
            guard stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC != 0 else { continue }
            if let pic = attachedPicture(stream) {
                info.coverData = pic.data
                info.coverMime = pic.mime
                break
            }
        }

        return info
    }

    /// 无时长时逐包计数估算：适用于 ADTS 这类无容器头的裸流（上游 st.duration=AV_NOPTS_VALUE、
    /// nb_frames=0）。“只计数不解码”，1 万包 AAC ≈ 2 分钟时长，循环成本可控；
    /// 200k 包≈ 3400s 为上限，到头就抛，防失把长无损/子流拉挂导入线程。
    private static func estimateDurationByPackets(_ ctx: UnsafeMutablePointer<AVFormatContext>,
                                                  streamIndex: Int32,
                                                  par: UnsafeMutablePointer<AVCodecParameters>) -> Double {
        let frameSize = par.pointee.frame_size > 0 ? Int64(par.pointee.frame_size) : 1024
        var count: Int64 = 0
        var pkt = av_packet_alloc()
        defer { av_packet_free(&pkt) }
        // 从头读；调用方后续会 avformat_close_input，无需回卷
        while av_read_frame(ctx, pkt) >= 0 {
            if pkt!.pointee.stream_index == streamIndex { count += 1 }
            av_packet_unref(pkt)
            if count >= 200_000 { break }
        }
        guard count > 0 else { return 0 }
        return Double(count * frameSize) / Double(par.pointee.sample_rate)
    }

    /// 遍历 AVDictionary（key/value），键归一化为小写、去前缀（ID3 的 TIT2 之类由 FFmpeg 已规范化）。
    private static func collectTags(_ dict: OpaquePointer?) -> [String: String] {
        var out: [String: String] = [:]
        var entry: UnsafeMutablePointer<AVDictionaryEntry>?
        while let e = av_dict_get(dict, "", entry, AV_DICT_IGNORE_SUFFIX) {
            let key = String(cString: e.pointee.key).lowercased()
            let value = String(cString: e.pointee.value)
            if !value.isEmpty { out[key] = value }
            entry = e
        }
        return out
    }

    /// 取某流的 attached picture 字节。优先用 AVStream.attached_pic（多数 demuxer 已备好），
    /// 拿不到再在该流上读一帧。
    private static func attachedPicture(_ stream: UnsafeMutablePointer<AVStream>)
        -> (data: Data, mime: String?)? {
        let pic = stream.pointee.attached_pic
        if pic.size > 0, let bytes = pic.data {
            let data = Data(bytes: bytes, count: Int(pic.size))
            return (data, mimeHint(data))
        }
        return nil
    }

    /// 从字节魔判一个粗 mime（只为属性面板/日志用，真正解码交给 ImageIO）
    private static func mimeHint(_ data: Data) -> String? {
        guard data.count > 4 else { return nil }
        let b = [UInt8](data.prefix(4))
        if b[0] == 0xFF, b[1] == 0xD8 { return "image/jpeg" }
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "image/png" }
        return nil
    }
}
