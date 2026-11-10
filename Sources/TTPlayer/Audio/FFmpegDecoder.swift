import Foundation
import AVFoundation
import CFFmpeg

/// 统一的 FFmpeg 文件解码器：任意容器 + 任意音频编码 → 立体声 Float32 非交织 PCM。
///
/// 取代过去的两条通路：系统认得的用 `AVAudioFile` + `scheduleSegment`，系统不认的
/// 用自制 Swift 解码器（DSD/TTA/APE）。现在都由 FFmpeg 解码，`AudioEngine` 用既有的
/// 窗口化 `scheduleBuffer` 通路消费。
///
/// 约束沿用 [PCMAudioDecoder]：不整曲进内存、不在音频线程做重活、能随机定位。
/// 输出统一降到立体声：多声道降混、单声道上混交给 `swr`，这样 playerNode/EQ/频谱
/// 的连接格式恒为 2 声道，位置时基也稳定。
final class FFmpegDecoder: PCMAudioDecoder {

    enum DecodeError: Error {
        case cannotOpen(reason: String)
        case noAudioStream
        case cannotDecode(reason: String)
    }

    // MARK: - 协议静态能力

    static var fileExtensions: Set<String> { FFmpeg.demuxerExtensions() }

    static func sniff(_ url: URL) -> Bool {
        guard let r = FFmpeg.openInput(url), let ctx = r.ctx else { return false }
        return av_find_best_stream(ctx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0) >= 0
    }

    // MARK: - 解码参数（协议要求）

    let sampleRate: Double
    let channelCount: Int
    let totalFrames: Int64
    let formatName: String

    // MARK: - FFmpeg 上下文（init 全部成功后才赋值，deinit 统一释放）

    private var fmt: UnsafeMutablePointer<AVFormatContext>?
    private var cc: UnsafeMutablePointer<AVCodecContext>?
    private var swr: OpaquePointer?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var streamIndex: Int32 = -1
    private var timeBase = AVRational(num: 1, den: 1)
    private var outTB = AVRational(num: 1, den: 1)
    private let outRate: Int32
    private let outChannels = 2
    /// 归档条目非 nil；deinit 里先 avformat_close_input，再 dispose。
    private var archiveIO: ArchiveIO?
    // 重建重采样器所需参数：seek 时用同样的输入布局/格式/率冷启动 swr，
    // 让「同一位置重复 seek」和「顺序读后再跳回」都得到逐字节一致的输出
    // （swr 带滤波器记忆，不重置就会沿用上次尾巴的 warm 态而漂移）。
    private let swrInRate: Int32
    private let swrInFormat: AVSampleFormat

    // MARK: - 立体声暂存（Float32 平面）

    /// 单块输出容量；压缩音频帧最多 ~4096 样本，DSD 转换后也远小于此
    private static let stageCap = 16_384
    private var stageL = [Float](repeating: 0, count: FFmpegDecoder.stageCap)
    private var stageR = [Float](repeating: 0, count: FFmpegDecoder.stageCap)
    private var stageCount = 0     // 暂存里有效帧
    private var stageCursor = 0    // 已消费帧
    /// 下一帧待交付样本的绝对输出帧号（顺序读的定位锚）
    private var nextOutPos: Int64 = 0
    /// 无 pts 时的顺序位置计数
    private var runningOutPos: Int64 = 0
    /// seek 后要丢到的目标帧（-1 = 无需丢弃）
    private var discardUntil: Int64 = -1
    private var flushSent = false

    private static let noPTS = Int64(bitPattern: 0x8000_0000_0000_0000)

    required init(url: URL) throws {
        FFmpeg.ensureInit()

        var f: UnsafeMutablePointer<AVFormatContext>?
        var cc: UnsafeMutablePointer<AVCodecContext>?
        var swr: OpaquePointer?
        var pkt: UnsafeMutablePointer<AVPacket>?
        var fr: UnsafeMutablePointer<AVFrame>?
        var io: ArchiveIO?

        // 失败时把已分配的都收干净（Swift 里 init 抛错不会跑 deinit）
        func cleanup() {
            var p = pkt; av_packet_free(&p)
            var q = fr; av_frame_free(&q)
            var s = swr; swr_free(&s)
            var c = cc; avcodec_free_context(&c)
            var ff = f; avformat_close_input(&ff)
            io?.dispose()
        }

        var ret: Int32
        if Archive.parseEntryURL(url) != nil {
            // 归档条目：先建自定义 AVIOContext，attach 到 alloc_context，
            // 再让 avformat_open_input 从 pb 里探测容器/编码。
            guard let opened = try ArchiveIO.open(url: url), let alloc = avformat_alloc_context() else {
                throw DecodeError.cannotOpen(reason: "归档容器打不开")
            }
            opened.attach(to: alloc)
            io = opened
            f = alloc
            ret = avformat_open_input(&f, nil, nil, nil)
        } else {
            ret = url.path.withCString { avformat_open_input(&f, $0, nil, nil) }
        }
        guard ret == 0, let fmtCtx = f else {
            cleanup()
            throw DecodeError.cannotOpen(reason: FFmpeg.errstr(ret))
        }

        ret = avformat_find_stream_info(fmtCtx, nil)
        guard ret >= 0 else { cleanup(); throw DecodeError.cannotOpen(reason: FFmpeg.errstr(ret)) }

        let idx = av_find_best_stream(fmtCtx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        guard idx >= 0, let streamPtr = fmtCtx.pointee.streams[Int(idx)] else {
            cleanup(); throw DecodeError.noAudioStream
        }
        let st = streamPtr.pointee
        let tb = st.time_base
        guard let par = st.codecpar else { cleanup(); throw DecodeError.noAudioStream }

        guard let dec = avcodec_find_decoder(par.pointee.codec_id) else {
            cleanup(); throw DecodeError.cannotDecode(reason: "无解码器")
        }
        cc = avcodec_alloc_context3(dec)
        guard let codecCtx = cc else { cleanup(); throw DecodeError.cannotDecode(reason: "分配解码上下文失败") }
        guard avcodec_parameters_to_context(codecCtx, par) >= 0 else {
            cleanup(); throw DecodeError.cannotDecode(reason: "参数复制失败")
        }
        ret = avcodec_open2(codecCtx, dec, nil)
        guard ret >= 0 else { cleanup(); throw DecodeError.cannotDecode(reason: FFmpeg.errstr(ret)) }

        let inRate = codecCtx.pointee.sample_rate
        let inFmt = codecCtx.pointee.sample_fmt
        // n9.0 的 DSD 解码器内部已做 dsd2pcm，直接输出 FLTP；demuxer 把 sample_rate
        // 折成了「DSD 位率 / 8」（DSD64 → 352800），比可听 PCM 基准还高 8 倍。
        // AVAudioEngine / EQ / 频谱都按常规音频率工作，喂 352800 起不来，所以 DSD
        // 再过一层 swr 降到 PCM 基准率（÷ 8：DSD64→44100、DSD128→88200、48k 系同理）。
        let isDSD = FFmpegDecoder.isDSDCodec(par.pointee.codec_id)
        let oRate = isDSD ? max(1, inRate / 8) : inRate

        // 重采样：任意输入布局/格式 → 立体声 FLTP @ oRate
        var inLayout = codecCtx.pointee.ch_layout
        var outLayout = AVChannelLayout()
        cff_channel_layout_default(&outLayout, 2)
        swr_alloc_set_opts2(&swr, &outLayout, AV_SAMPLE_FMT_FLTP, oRate,
                            &inLayout, inFmt, inRate, 0, nil)
        guard let swrCtx = swr, swr_init(swrCtx) >= 0 else {
            cleanup(); throw DecodeError.cannotDecode(reason: "重采样器建立失败")
        }

        pkt = av_packet_alloc()
        fr = av_frame_alloc()
        guard pkt != nil, fr != nil else { cleanup(); throw DecodeError.cannotDecode(reason: "缓冲分配失败") }

        // —— 全部成功，交给 self ——
        self.outRate = oRate
        self.swrInRate = inRate
        self.swrInFormat = inFmt
        self.sampleRate = Double(oRate)
        self.channelCount = 2
        self.formatName = isDSD
            ? FFmpeg.dsdLabel(codecId: par.pointee.codec_id, dsdBitRate: Int(inRate) * 8)
            : FFmpeg.codecName(par.pointee.codec_id, profile: par.pointee.profile,
                               container: fmtCtx.pointee.iformat.flatMap { String(cString: $0.pointee.name) })
        self.fmt = fmtCtx
        self.cc = codecCtx
        self.swr = swrCtx
        self.packet = pkt
        self.frame = fr
        self.streamIndex = idx
        self.timeBase = tb
        self.outTB = AVRational(num: 1, den: oRate > 0 ? oRate : 1)
        self.archiveIO = io
        self.totalFrames = FFmpegDecoder.computeTotal(st: st, fmtDuration: fmtCtx.pointee.duration,
                                                      outTB: self.outTB)
    }

    deinit {
        av_packet_free(&packet)
        av_frame_free(&frame)
        swr_free(&swr)
        avcodec_free_context(&cc)
        avformat_close_input(&fmt)
        archiveIO?.dispose()
    }

    // MARK: - 随机定位

    /// 冷启动重建 swr：释放旧的、用相同参数 alloc_set_opts2 + init。
    /// seek 里调用，保证每次定位后重采样器都从无记忆状态开始，重复 seek 逐字节可重复。
    private func configureSwr() {
        guard let cc else { return }
        var old = swr
        swr_free(&old)
        swr = nil
        var inLayout = cc.pointee.ch_layout
        var outLayout = AVChannelLayout()
        cff_channel_layout_default(&outLayout, 2)
        var fresh: OpaquePointer?
        swr_alloc_set_opts2(&fresh, &outLayout, AV_SAMPLE_FMT_FLTP, outRate,
                            &inLayout, swrInFormat, swrInRate, 0, nil)
        guard let s = fresh, swr_init(s) >= 0 else { return }
        swr = s
    }

    private func seek(to frame: Int64) {
        guard let fmt, let cc else { return }
        let target = max(0, frame)
        let ts = target == 0 ? Int64(0) : av_rescale_q(target, outTB, timeBase)
        av_seek_frame(fmt, streamIndex, ts, AVSEEK_FLAG_BACKWARD)
        avcodec_flush_buffers(cc)
        configureSwr()
        stageCount = 0
        stageCursor = 0
        flushSent = false
        nextOutPos = target
        runningOutPos = target
        discardUntil = target
    }

    // MARK: - 读 PCM

    func read(into buffer: AVAudioPCMBuffer, frames: AVAudioFrameCount, from frame: Int64) -> AVAudioFrameCount {
        guard frames > 0, let out = buffer.floatChannelData,
              Int(buffer.format.channelCount) >= outChannels else { return 0 }

        if frame != nextOutPos || discardUntil >= 0 {
            seek(to: frame)
        }

        var produced = 0
        let need = Int(frames)
        while produced < need {
            if stageCursor >= stageCount {
                guard fillStage() else { break }
                if stageCursor >= stageCount { break }
            }
            let take = min(need - produced, stageCount - stageCursor)
            let off = stageCursor * MemoryLayout<Float>.stride
            stageL.withUnsafeBytes { src in
                _ = memcpy(out[0].advanced(by: produced), src.baseAddress!.advanced(by: off), take * MemoryLayout<Float>.stride)
            }
            stageR.withUnsafeBytes { src in
                _ = memcpy(out[1].advanced(by: produced), src.baseAddress!.advanced(by: off), take * MemoryLayout<Float>.stride)
            }
            stageCursor += take
            produced += take
            nextOutPos += Int64(take)
        }
        buffer.frameLength = AVAudioFrameCount(produced)
        return AVAudioFrameCount(produced)
    }

    /// 标准 FFmpeg 解码流水：receive 帧，没帧就 send 包；EOF 后冲 swr 尾。
    private func fillStage() -> Bool {
        guard let cc, let swr, let frame, let packet else { return false }

        while true {
            let r = avcodec_receive_frame(cc, frame)
            if r == FFmpeg.errorEAGAIN {
                if !feedOnePacket(cc: cc, packet: packet) {
                    if !flushSent { avcodec_send_packet(cc, nil); flushSent = true }
                }
                continue
            }
            if r == FFmpeg.errorEOF || r < 0 {
                return drainSwrTail(swr: swr)
            }
            defer { av_frame_unref(frame) }
            if emitFrame(swr: swr, frame: frame) { return true }
        }
    }

    /// 读一个本流音频包并送入解码器；返回 false 表示 av_read_frame 已无更多输入。
    private func feedOnePacket(cc: UnsafeMutablePointer<AVCodecContext>,
                               packet: UnsafeMutablePointer<AVPacket>) -> Bool {
        guard let fmt else { return false }
        while true {
            av_packet_unref(packet)
            let rr = av_read_frame(fmt, packet)
            if rr < 0 { return false }
            if packet.pointee.stream_index == streamIndex {
                if avcodec_send_packet(cc, packet) >= 0 { return true }
            }
        }
    }

    /// 把当前 AVFrame 重采样进立体声暂存，应用 seek 丢弃；返回是否产生了可交付样本。
    private func emitFrame(swr: OpaquePointer,
                           frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        let inCount = Int(frame.pointee.nb_samples)
        guard inCount > 0 else { return false }

        let blockStart: Int64
        if frame.pointee.pts != FFmpegDecoder.noPTS {
            blockStart = av_rescale_q(frame.pointee.pts, timeBase, outTB)
        } else {
            blockStart = runningOutPos
        }

        let inData = frame.pointee.extended_data
        let got = convert(swr: swr, in: inData, inCount: Int32(inCount))
        guard got > 0 else { return false }

        var valid = got
        var start = blockStart
        runningOutPos = blockStart + Int64(valid)

        if discardUntil >= 0 {
            if start + Int64(valid) <= discardUntil { return false }
            if start < discardUntil {
                let drop = Int(discardUntil - start)
                shiftStageLeft(by: drop)
                valid -= drop
                start = discardUntil
            }
            discardUntil = -1
        }

        stageCount = valid
        stageCursor = 0
        nextOutPos = max(nextOutPos, start)
        return true
    }

    /// 冲 swr 端延迟：NULL 输入再转一次，把内部缓冲尾巴落到暂存。
    private func drainSwrTail(swr: OpaquePointer) -> Bool {
        let valid = convert(swr: swr, in: nil, inCount: 0)
        guard valid > 0 else { return false }
        var v = valid
        if discardUntil >= 0 {
            let start = runningOutPos
            if start + Int64(v) <= discardUntil { return false }
            if start < discardUntil {
                let drop = Int(discardUntil - start)
                shiftStageLeft(by: drop)
                v -= drop
            }
            discardUntil = -1
        }
        stageCount = v
        stageCursor = 0
        runningOutPos += Int64(v)
        return true
    }

    /// swr_convert 到立体声 stageL/stageR（FLTP）。返回产出的每声道帧数。
    private func convert(swr: OpaquePointer,
                         in inData: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
                         inCount: Int32) -> Int {
        // swr_convert 的入参是 const uint8_t **，extended_data 是 uint8_t **，
        // 两者内存布局一致（都是“指针数组”），做一次裸指针重解释即可。
        let inConst: UnsafePointer<UnsafePointer<UInt8>?>? =
            inData.map { UnsafeRawPointer($0).assumingMemoryBound(to: UnsafePointer<UInt8>?.self) }
        return stageL.withUnsafeMutableBufferPointer { l in
            stageR.withUnsafeMutableBufferPointer { r in
                var planes: [UnsafeMutablePointer<UInt8>?] = [
                    UnsafeMutableRawPointer(l.baseAddress!).assumingMemoryBound(to: UInt8.self),
                    UnsafeMutableRawPointer(r.baseAddress!).assumingMemoryBound(to: UInt8.self),
                ]
                let got = planes.withUnsafeMutableBufferPointer { pb in
                    swr_convert(swr, pb.baseAddress, Int32(Self.stageCap), inConst, inCount)
                }
                return max(0, Int(got))
            }
        }
    }

    /// 把暂存左移 drop 帧（丢头部样本），保持数组容量不变（尾部补零）。
    private func shiftStageLeft(by drop: Int) {
        guard drop > 0 else { return }
        stageL.removeFirst(drop)
        stageL.append(contentsOf: repeatElement(Float(0), count: drop))
        stageR.removeFirst(drop)
        stageR.append(contentsOf: repeatElement(Float(0), count: drop))
    }

    // MARK: - 静态工具

    private static func isDSDCodec(_ id: AVCodecID) -> Bool {
        let dsd: [AVCodecID] = [AV_CODEC_ID_DSD_LSBF, AV_CODEC_ID_DSD_MSBF,
                                AV_CODEC_ID_DSD_LSBF_PLANAR, AV_CODEC_ID_DSD_MSBF_PLANAR]
        return dsd.contains(id)
    }

    private static func computeTotal(st: AVStream, fmtDuration: Int64, outTB: AVRational) -> Int64 {
        if st.duration > 0 {
            return av_rescale_q(st.duration, st.time_base, outTB)
        }
        if fmtDuration > 0 {
            return av_rescale_q(fmtDuration, AVRational(num: 1, den: Int32(AV_TIME_BASE)), outTB)
        }
        if st.nb_frames > 0 { return Int64(st.nb_frames) }
        return 0
    }
}
