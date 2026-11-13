import Foundation
import AVFoundation
import Security
import CFFmpeg

// MARK: - 地址归一化

/// 网络电台地址：用户粘贴的东西五花八门（带空格、少协议、复制了整段文字），
/// 先归一化再入表，否则存档里会留下永远放不起来的字符串
enum RadioURL {
    /// 只认 http/https；没写协议就补 http://（国内电台绝大多数是明文 http）
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        // 从浏览器复制时常带引号或首尾包裹的空白
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>"))
        if !s.contains("://") { s = "http://" + s }
        guard let url = URL(string: s),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// 是不是电台（http/https 一律按流处理，本地文件走文件通路）
    static func isRadio(_ url: URL) -> Bool {
        guard let s = url.scheme?.lowercased() else { return false }
        return s == "http" || s == "https"
    }

    /// 明确写了协议才算电台。m3u 里一行可能是相对路径，不能拿 normalize 去“补协议”猜：
    /// `Music/a.mp3` 一旦被补成 http://Music/a.mp3 就会当成电台入表
    static func explicit(_ line: String) -> URL? {
        let s = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.hasPrefix("http://") || s.hasPrefix("https://") else { return nil }
        return normalize(line)
    }

    /// 用户没填名字时的显示名：host[:port] + 路径尾段（够识别，又不至于长得离谱）
    static func displayName(for url: URL) -> String {
        let host = url.host ?? url.absoluteString
        var name = url.port.map { "\(host):\($0)" } ?? host
        let tail = url.lastPathComponent
        if !tail.isEmpty, tail != "/" { name += "/" + tail }
        return name
    }
}

// MARK: - ICY 元数据拆分

/// Shoutcast / Icecast 的 ICY 元数据：每 `metaInt` 字节音频后面跟「1 字节长度 × 16」的元数据块。
/// 拆成纯结构体，自检喂几段字节就能验（不需要联网）。
struct ICYDemuxer {
    /// 服务器给的间隔；0 表示这条流不带元数据
    let metaInt: Int
    private var audioLeft: Int
    /// >0 = 还剩多少字节元数据；-1 = 下一个字节是长度；0 = 不在元数据段
    private var metaLeft = 0
    private var metaBuf = Data()

    init(metaInt: Int) {
        let n = max(0, metaInt)
        self.metaInt = n
        self.audioLeft = n > 0 ? n : 0
    }

    var carriesMetadata: Bool { metaInt > 0 }

    /// 喂一块网络数据 → 纯音频字节 + 这一块里读到的流标题（没有就是 nil）
    mutating func demux(_ input: Data) -> (audio: Data, title: String?) {
        guard metaInt > 0 else { return (input, nil) }
        var out = Data()
        var title: String?
        var i = input.startIndex
        while i < input.endIndex {
            if metaLeft > 0 {
                let take = min(metaLeft, input.endIndex - i)
                metaBuf.append(contentsOf: input[i..<(i + take)])
                metaLeft -= take
                i += take
                if metaLeft == 0 {
                    if let t = ICYDemuxer.parseTitle(metaBuf) { title = t }
                    metaBuf.removeAll(keepingCapacity: true)
                    audioLeft = metaInt
                }
            } else if metaLeft == -1 {
                let len = Int(input[i]) * 16
                i += 1
                if len == 0 {
                    metaLeft = 0
                    audioLeft = metaInt
                } else {
                    metaLeft = len
                }
            } else if audioLeft > 0 {
                let take = min(audioLeft, input.endIndex - i)
                out.append(contentsOf: input[i..<(i + take)])
                audioLeft -= take
                i += take
                if audioLeft == 0 { metaLeft = -1 }
            } else {
                break
            }
        }
        return (out, title)
    }

    /// 从 `StreamTitle='xxx';StreamUrl='';` 里抠出标题；空串当没有
    ///
    /// 只在 ASCII 字节上找标记，再单独解标题那一段：整块一起解的话，块尾多出来的
    /// 一个 0xFF（AAC 帧头就是 FF F1）就会让 UTF-8 解码失败、整块掉进 latin1 回落，
    /// 中文台名跟着全变乱码——实测真电台与本地 ICY 服务器都能撞上。
    ///
    /// 编码得先试 UTF-8：ICY 规范写的是 ISO-8859-1，但国内电台早都把中文按 UTF-8
    /// 塞进去了，而 isoLatin1 对任何字节都能“成功”，先试它等于中文台名永远乱码。
    static func parseTitle(_ block: Data) -> String? {
        guard !block.isEmpty,
              let mark = block.range(of: Data("StreamTitle='".utf8)) else { return nil }
        let rest = block[mark.upperBound...]
        guard let end = rest.firstIndex(of: 0x27) else { return nil }
        let raw = Data(rest[..<end])
        guard let s = String(data: raw, encoding: .utf8)
                ?? String(data: raw, encoding: .isoLatin1) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - 流式解码

/// 网络电台的解码器：字节流 → PCM。
///
/// 电台是"永远放不完"的流，AVAudioFile 那条路（要文件长度、要随机定位）根本用不了。
/// 统一交给 FFmpeg：用一块自定义 `AVIOContext` 把 URLSession 推来的字节喂给它，
/// FFmpeg 负责切包与解码，swresample 把任意编码转成 float32 立体声 PCM，
/// 再交给 AudioEngine 的 playerNode —— EQ 与频谱照常工作。
///
/// FFmpeg 的读是阻塞式的，而电台字节是异步一块块到的，所以解码跑在独立线程上，
/// 与 `feed()`（URLSession 串行队列）通过一条 `NSCondition` 保护的环缓冲交接：
/// `feed()` 只追加字节并唤醒，读回调没数据时挂起等待。`close()` 置 EOF 让解码线程
/// 排空已缓冲的数据后自然收尾，再 join——避免边解边释放上下文导致 use-after-free。
final class RadioStreamDecoder {
    struct Info: Equatable {
        var sampleRate: Double = 0
        var channels: Int = 2
        var bitRateKbps: Int = 0
        /// 给人看的编码名（FFmpeg 的解码器名，如 MP3 / AAC / Opus）
        var codec: String = ""

        var bitRateText: String { bitRateKbps > 0 ? "\(bitRateKbps)k" : "" }
        var sampleRateText: String {
            sampleRate > 0 ? String(format: "%.1fk", sampleRate / 1000) : ""
        }
    }

    /// 格式就绪（首次 / 广告插播导致编码变化时由上层重新回报）
    var onInfo: ((Info, AVAudioFormat) -> Void)?
    /// 一块 PCM（float32 非交错，立体声）
    var onPCM: ((AVAudioPCMBuffer) -> Void)?
    /// 解码层面的错误（调用方决定是提示还是重连）
    var onFailure: ((String) -> Void)?

    private(set) var info = Info()
    /// 送进解码器的音频包数（自检用来确认真的解出东西了）
    private(set) var packetsSeen = 0
    private(set) var framesOut: Int64 = 0

    // 环缓冲 + 条件变量：feed() 是生产者，读回调是消费者
    private let cond = NSCondition()
    private var ring = Data()
    private var eof = false
    private var aborted = false
    private var started = false
    /// 解码线程是否已被 join 过：close() 会被显式调一次、deinit 再调一次，
    /// 而 readDone 只 signal 一次，重复 close 若不短路，第二次会卡在无上限的 wait 上。
    private var joined = false

    private let readDone = DispatchSemaphore(value: 0)
    /// 解码线程（独立于 URLSession 队列，因为 FFmpeg 的读会阻塞）
    private let workQueue = DispatchQueue(label: "ttplayer.radio.decode")

    /// 单次喂给 FFmpeg 的读缓冲大小
    private static let ioBufferSize = 32_768
    /// close() 等待解码线程收尾的上限：超时后强制中断
    private static let joinTimeout = 1.0

    deinit { close() }

    /// 起解码线程（幂等）。真正的 avformat_open_input 在线程里做，格式解出来才回 onInfo。
    @discardableResult
    func open() -> Bool {
        cond.lock()
        defer { cond.unlock() }
        guard !started else { return true }
        started = true
        let me = Unmanaged.passUnretained(self).toOpaque()
        workQueue.async { [me] in self.decodeLoop(opaque: me) }
        return true
    }

    /// 喂一块网络字节（音频部分，ICY 元数据要先剥掉）
    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        cond.lock()
        if aborted || eof { cond.unlock(); return }
        ring.append(data)
        cond.broadcast()
        cond.unlock()
    }

    /// 收尾：置 EOF 让解码线程排空已缓冲字节后自然退出，再 join；超时才强制中断。
    /// 幂等：显式 close() 与随后的 deinit 会各调一次，而 readDone 只被 signal 一次，
    /// 第二次若再去 wait 会永久卡住主线程（自检里 decoder.close() 后离开作用域触发 deinit 就撞上）。
    func close() {
        cond.lock()
        guard started, !joined else { cond.unlock(); return }
        joined = true
        if !eof { eof = true; cond.broadcast() }
        cond.unlock()
        if readDone.wait(timeout: .now() + RadioStreamDecoder.joinTimeout) == .timedOut {
            cond.lock(); aborted = true; cond.broadcast(); cond.unlock()
            readDone.wait()
        }
    }

    /// 是否已被强制中断（供 FFmpeg 在两次调用之间自查）
    private var interrupted: Bool {
        cond.lock(); defer { cond.unlock() }
        return aborted
    }

    /// 读回调的落点：从环缓冲取最多 `want` 字节到 `dest`。
    /// 没数据时挂起等待；EOF 或中断且取空返回 `AVERROR_EOF`——**不能回 0**：
    /// FFmpeg n9 的 `fill_buffer` 只把 `AVERROR_EOF` 和负数当结束，回 0 算
    /// 「这趟没读到」并接着重试，断流后的解码线程就会 100% CPU 原地空转而不退
    fileprivate func consume(_ dest: UnsafeMutablePointer<UInt8>?, _ want: Int32) -> Int32 {
        guard let dest, want > 0 else { return Int32(cff_averror_eof()) }
        cond.lock()
        while ring.isEmpty, !eof, !aborted {
            cond.wait()
        }
        if ring.isEmpty {   // eof 或 aborted 且无数据
            cond.unlock()
            return Int32(cff_averror_eof())
        }
        let n = min(Int(want), ring.count)
        _ = ring.withUnsafeBytes { src in memcpy(dest, src.baseAddress!, n) }
        ring.removeFirst(n)
        cond.unlock()
        return Int32(n)
    }

    private func decodeLoop(opaque: UnsafeMutableRawPointer) {
        FFmpeg.ensureInit()
        defer { readDone.signal() }

        // 1) 自定义 IO：用环缓冲喂 FFmpeg，直播不可 seek
        let bufSize = Int32(Self.ioBufferSize)
        guard let raw = av_malloc(Int(bufSize)) else {
            onFailure?("解码缓冲分配失败"); return
        }
        var io: UnsafeMutablePointer<AVIOContext>? = avio_alloc_context(
            raw.assumingMemoryBound(to: UInt8.self), bufSize, 0, opaque, Self.readCB, nil, nil)
        guard io != nil else {
            av_free(raw); onFailure?("IO 上下文分配失败"); return
        }

        var fmt: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard let fc = fmt, let ioCtx = io else {
            av_free(raw); onFailure?("容器上下文分配失败"); return
        }
        // 声明“IO 由我们自己管”：这样 avformat_close_input 不会去关/释放 pb
        fc.pointee.pb = ioCtx
        fc.pointee.flags |= Int32(AVFMT_FLAG_CUSTOM_IO)
        let cb = AVIOInterruptCB(callback: Self.interruptCB, opaque: opaque)
        fc.pointee.interrupt_callback = cb

        defer {
            avformat_close_input(&fmt)
            if let b = io?.pointee.buffer { av_free(b) }
            avio_context_free(&io)
        }

        var ret = avformat_open_input(&fmt, nil, nil, nil)
        guard ret >= 0, let fmt else {
            onFailure?("打不开流（\(FFmpeg.errstr(ret))）"); return
        }
        guard avformat_find_stream_info(fmt, nil) >= 0 else {
            onFailure?("解析不出流信息"); return
        }
        let idx = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        guard idx >= 0, let stream = fmt.pointee.streams[Int(idx)],
              let par = stream.pointee.codecpar else {
            onFailure?("流里没有音频"); return
        }
        guard let dec = avcodec_find_decoder(par.pointee.codec_id) else {
            onFailure?("没有 \(FFmpeg.codecName(par.pointee.codec_id)) 的解码器"); return
        }
        var cc = avcodec_alloc_context3(dec)
        guard let codecCtx = cc else { onFailure?("分配解码上下文失败"); return }
        defer { avcodec_free_context(&cc) }
        guard avcodec_parameters_to_context(codecCtx, par) >= 0,
              avcodec_open2(codecCtx, dec, nil) >= 0 else {
            onFailure?("打开解码器失败"); return
        }

        let inRate = codecCtx.pointee.sample_rate
        let inFmt = codecCtx.pointee.sample_fmt
        var inLayout = codecCtx.pointee.ch_layout
        var outLayout = AVChannelLayout()
        cff_channel_layout_default(&outLayout, 2)
        var swrOpt: OpaquePointer?
        swr_alloc_set_opts2(&swrOpt, &outLayout, AV_SAMPLE_FMT_FLTP, inRate,
                            &inLayout, inFmt, inRate, 0, nil)
        guard let swr = swrOpt, swr_init(swr) >= 0 else {
            onFailure?("重采样器建立失败"); return
        }
        defer { var s = swrOpt; swr_free(&s) }

        guard let outAVFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: Double(inRate), channels: 2,
                                              interleaved: false) else {
            onFailure?("输出格式非法"); return
        }
        info = Info(sampleRate: Double(inRate), channels: 2,
                    bitRateKbps: Int(max(0, par.pointee.bit_rate) / 1000),
                    codec: FFmpeg.codecName(par.pointee.codec_id))
        onInfo?(info, outAVFormat)

        var pktOpt = av_packet_alloc()
        var frOpt = av_frame_alloc()
        defer {
            av_packet_free(&pktOpt)
            av_frame_free(&frOpt)
        }
        guard let packet = pktOpt, let frame = frOpt else {
            onFailure?("缓冲分配失败"); return
        }

        // 2) 解码主循环：读包→送解码器→收帧→重采样→排 PCM
        var planeL = [Float](repeating: 0, count: 16_384)
        var planeR = [Float](repeating: 0, count: 16_384)
        while !interrupted {
            av_packet_unref(packet)
            ret = av_read_frame(fmt, packet)
            if ret == FFmpeg.errorEOF { break }
            if ret < 0 { break }
            if packet.pointee.stream_index != idx { continue }
            packetsSeen += 1
            if avcodec_send_packet(codecCtx, packet) < 0 { continue }
            while !interrupted, avcodec_receive_frame(codecCtx, frame) == 0 {
                emitFrame(frame: frame, swr: swr, out: outAVFormat, l: &planeL, r: &planeR)
                av_frame_unref(frame)
            }
        }
        // 冲尾：送 NULL 让解码器吐出延迟帧，再经 swr 落完
        avcodec_send_packet(codecCtx, nil)
        while avcodec_receive_frame(codecCtx, frame) == 0 {
            emitFrame(frame: frame, swr: swr, out: outAVFormat, l: &planeL, r: &planeR)
            av_frame_unref(frame)
        }
    }

    /// 收一帧 → swr 到立体声 float → 造 AVAudioPCMBuffer 交 onPCM。
    private func emitFrame(frame: UnsafeMutablePointer<AVFrame>, swr: OpaquePointer,
                           out: AVAudioFormat, l: inout [Float], r: inout [Float]) {
        let inCount = Int(frame.pointee.nb_samples)
        guard inCount > 0, let inData = frame.pointee.extended_data else { return }
        let cap = max(inCount + 16, l.count)
        if l.count < cap {
            l = [Float](repeating: 0, count: cap); r = [Float](repeating: 0, count: cap)
        }
        // swr_convert 入参是 const uint8_t **；extended_data 是 uint8_t **，布局一致
        let inConst: UnsafePointer<UnsafePointer<UInt8>?>? =
            UnsafeRawPointer(inData).assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
        let got = l.withUnsafeMutableBufferPointer { lb in
            r.withUnsafeMutableBufferPointer { rb in
                var planes: [UnsafeMutablePointer<UInt8>?] = [
                    UnsafeMutableRawPointer(lb.baseAddress!).assumingMemoryBound(to: UInt8.self),
                    UnsafeMutableRawPointer(rb.baseAddress!).assumingMemoryBound(to: UInt8.self),
                ]
                return planes.withUnsafeMutableBufferPointer { pb in
                    swr_convert(swr, pb.baseAddress, Int32(lb.count), inConst, Int32(inCount))
                }
            }
        }
        guard got > 0, let pcm = AVAudioPCMBuffer(pcmFormat: out,
                                                  frameCapacity: AVAudioFrameCount(got)) else { return }
        pcm.frameLength = AVAudioFrameCount(got)
        if let ch = pcm.floatChannelData {
            l.withUnsafeMutableBufferPointer { lb in
                r.withUnsafeMutableBufferPointer { rb in
                    memcpy(ch[0], lb.baseAddress!, Int(got) * MemoryLayout<Float>.stride)
                    memcpy(ch[1], rb.baseAddress!, Int(got) * MemoryLayout<Float>.stride)
                }
            }
        }
        framesOut += Int64(got)
        onPCM?(pcm)
    }

    // MARK: C 回调（不捕获上下文，靠 opaque 找回 self）

    private static let readCB: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, Int32) -> Int32 = { opq, buf, size in
        // opaque 丢了就没有任何数据可给了，只能报 EOF：回 0 会让 FFmpeg 反复重试而空转
        guard let opq else { return Int32(cff_averror_eof()) }
        let me = Unmanaged<RadioStreamDecoder>.fromOpaque(opq).takeUnretainedValue()
        return me.consume(buf, size)
    }

    private static let interruptCB: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { opq in
        guard let opq else { return 0 }
        let me = Unmanaged<RadioStreamDecoder>.fromOpaque(opq).takeUnretainedValue()
        return me.interrupted ? 1 : 0
    }
}

// MARK: - 失败归类

/// 一次连接失败该怎么收场。
///
/// 退避重连是为「走路换 Wi-Fi、服务器踢人、广告段切码流」准备的；证书域名不匹配、
/// 地址写错这类是站点自己的毛病，重连 5 次也只是白等半分钟，得当场把话说清楚。
enum RadioFault: Equatable {
    /// 重连不会自愈：原因直接摆给用户
    case fatal(String)
    /// 换个网络、过两秒也许就好：按退避重连
    case transient(String)
    /// HTTPS 证书不可信，明文口通常还活着：换成 http 再试（一条会话只降一次），
    /// 带上证书为什么过不了——降级这件得说给用户听，不能只写进日志
    case downgrade(URL, String)
}

// MARK: - 拉流与重连

/// 一条电台会话：URLSession 拉字节 → 剥 ICY → 解码 → PCM 回调。
///
/// 「电台能不能听」几乎全看重连策略：走路换 Wi-Fi、服务器踢人、广告段切码流都会断。
/// 断线不当作错误报给用户，先按退避重连；连续失败到上限才说"连不上"。
final class RadioPlayer: NSObject {
    enum State: Equatable {
        case idle
        case connecting
        case playing
        case reconnecting(attempt: Int)
        /// HTTPS 证书过不了，正改用明文重连（不声张地降级会让用户以为站点本来就安全）
        case fallingBack
        case failed(String)

        var displayText: String {
            switch self {
            case .idle: return "未连接"
            case .connecting: return "正在连接电台…"
            case .playing: return "直播中"
            case .reconnecting(let n): return "信号中断，重连中（第 \(n) 次）…"
            case .fallingBack: return "证书与域名不符，改用明文重连…"
            case .failed(let reason): return reason
            }
        }
    }

    /// 退避：2s、4s、8s… 封顶 8s；连续失败超过上限就收手
    static let maxAttempts = 5
    static func retryDelay(attempt: Int) -> Double {
        min(8, 2 * pow(2, Double(max(0, attempt - 1))))
    }

    /// 自检把退避整体压到 1/8（2/4/8 s → 0.25/0.5/1 s）。电台那几套的凭据是
    /// 「比最长一档退避还久的时间窗里没有新连接」，等的是真实时钟，全量光这几条就 30 s。
    /// 压的是排定时器这一处：`retryDelay` 的出厂数值不跟着变（RadioSuite 直接断言
    /// 2/4/8/8，改档位仍要过发布说明），自检拿 `retryWait(attempt:)` 算窗口也不会写死常数
    static let retryScale: Double =
        ProcessInfo.processInfo.environment["TTPLAYER_SELFTEST"] != nil ? 0.125 : 1

    /// 排下去的真实等待（出厂档位 × 自检压缩比）：自检要「等得比它久」就拿这个数
    static func retryWait(attempt: Int) -> Double {
        retryDelay(attempt: attempt) * retryScale
    }

    /// HTTP 应答码 → 该怎么收场（nil = 这个码可以听）
    ///
    /// 404 算临时：实测有流媒体服务器好好推流时也会偶发吐一个 404，
    /// 过两秒再连就 200 了；401/403/410 则无论如何重连不回。
    static func classify(status: Int) -> RadioFault? {
        switch status {
        case 200..<300: return nil
        case 300..<400: return .transient("服务器让路，但没接到流（HTTP \(status)）")
        case 401, 403: return .fatal("电台要账号或密码（HTTP \(status)）")
        case 404: return .transient("服务器返回 404")
        case 408, 429: return .transient("服务器忙（HTTP \(status)）")
        case 410: return .fatal("电台已停播（HTTP 410）")
        case 500..<600: return .transient("服务器出错（HTTP \(status)）")
        default: return .fatal("服务器返回 HTTP \(status)")
        }
    }

    /// 传输层错误 → 人话 + 能不能靠重连自救
    /// - Parameter url: 这次要连的地址（降级要用；错误里没带就用它）
    static func classify(_ error: Error, trying url: URL?) -> RadioFault {
        // 不是 NSURLErrorDomain 的错误桥不成 URLError，一律当临时处理
        guard let fault = error as? URLError else {
            return .transient(error.localizedDescription)
        }
        let info = (error as NSError).userInfo
        let host = (info[NSURLErrorFailingURLErrorKey] as? URL)?.host ?? url?.host ?? "电台"
        switch fault.code {
        case .badURL, .unsupportedURL:
            return .fatal("这地址不是能播的电台链接")
        case .cannotParseResponse:
            return .fatal("服务器的应答不合 HTTP 规范，读不出流")
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            // 证书签给别人的域名（或过期、或自签）：站点自己的事，重连多少次都是一个结果
            let cert = certificateSubject(info).map { "证书签给 \($0)，与 \(host) 对不上" }
                ?? "HTTPS 证书校验没过"
            if let plain = url.flatMap(plaintextAlternate) { return .downgrade(plain, cert) }
            return .fatal("\(cert)；这台没给出能用的明文地址")
        case .timedOut:
            return .transient("连接超时")
        case .cannotFindHost, .dnsLookupFailed:
            return .transient("解不出 \(host)")
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .internationalRoamingOff:
            return .transient("本机网络断了")
        case .cannotConnectToHost:
            return .transient("连不上 \(host)")
        case .cancelled:
            return .transient("已断开")        // 自己掐的不算失败，调用处会先挡住
        default:
            return .transient(fault.localizedDescription)
        }
    }

    /// https → 同址的 http；已经明文、或带了非默认端口（明文口在哪不确定）时不降
    static func plaintextAlternate(of url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https",
              url.port == nil || url.port == 443,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "http"
        parts.port = nil
        return parts.url
    }

    /// 从错误里取叶子证书的主题名（只看名字，不碰信任链）；取不到就 nil
    ///
    /// 这一步是纯拼消息用的，拿不到证书也不能影响归类：没有主题名就只说“证书校验没过”。
    private static func certificateSubject(_ info: [String: Any]) -> String? {
        guard let chain = info["NSErrorPeerCertificateChainKey"] as? [SecCertificate] else { return nil }
        for cert in chain {
            if let summary = SecCertificateCopySubjectSummary(cert) { return summary as String }
        }
        return nil
    }

    var onState: ((State) -> Void)?
    var onInfo: ((RadioStreamDecoder.Info, AVAudioFormat) -> Void)?
    var onPCM: ((AVAudioPCMBuffer) -> Void)?
    /// 流里带的「正在播」（ICY StreamTitle）
    var onTitle: ((String) -> Void)?

    private(set) var state: State = .idle
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var decoder: RadioStreamDecoder?
    private var demuxer: ICYDemuxer?
    private var attempt = 0
    /// 连接代号：`open()`（换台、重试、暂停后又按播放）与 `stop()` 各推进一格。
    /// 退避定时器登记的是它被排下去时那一格，过期的定时器一律不作数：不然用户在
    /// 断线退避当中点了「重试这个电台」，新流刚连上，旧定时器到点又会把它掐掉重连
    /// ——听着就是「好好的又咔一下」（F11 要的「退避与过期回调防护」）
    private var generation = 0
    /// 证书不可信时已经换过一次明文（用户重新点播放会复位）
    private var fallbackTried = false
    private var wantsPlayback = false
    private var closed = false

    /// 最近一次要连的地址（主线程写，队列读；降级后会换成明文地址）
    private(set) var currentURL: URL?

    /// 所有流状态都在这条串行队列上改，URLSession 的回调也派到这里。
    ///
    /// 不串行化的后果实测是 SIGSEGV：主线程点暂停 → AudioFileStreamClose，
    /// 而回调队列正在这个流里 ParseBytes，两边一夹就是 use-after-free。
    private let queue = DispatchQueue(label: "ttplayer.radio")
    private static let queueKey = DispatchSpecificKey<Bool>()

    override init() {
        super.init()
        queue.setSpecific(key: RadioPlayer.queueKey, value: true)
    }

    /// 在队列上就地做；从主线程进来时等它做完（切歌/退出要确定断干净）
    private func sync(_ block: () -> Void) {
        if DispatchQueue.getSpecific(key: RadioPlayer.queueKey) == true {
            block()
        } else {
            queue.sync(execute: block)
        }
    }

    /// 主线程要按「现在到底连着没有」做决定时问一句。
    ///
    /// 不能直接读 `state`：那是从队列异步转到主线程的，暂停后立刻按播放时它可能
    /// 还停在「直播中」，于是既不重连也不出声（实测过：恢复后只会排空旧缓冲，时基照走）。
    func snapshotState() -> State {
        var out = state
        sync { out = state }
        return out
    }

    /// 开一条流（重复调用会先断掉旧的）
    func open(_ url: URL) {
        currentURL = url
        sync {
            generation += 1        // 之前排下去的退避定时器当场作废
            closed = false
            wantsPlayback = true
            attempt = 0
            fallbackTried = false
            start()
        }
    }

    /// 暂停：电台没有"接着放"，直接断流；恢复靠 open 重连
    func pause() {
        sync {
            wantsPlayback = false
            teardown()
            setState(.idle)
        }
    }

    func stop() {
        sync {
            generation += 1
            closed = true
            wantsPlayback = false
            teardown()
            setState(.idle)
        }
    }

    // MARK: 连接

    private func start(announce: State? = nil) {
        guard wantsPlayback, let url = currentURL, !closed else { return }
        teardown()
        setState(announce ?? (attempt == 0 ? .connecting : .reconnecting(attempt: attempt + 1)))

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = .infinity     // 电台是无限流
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpAdditionalHeaders = [
            // 要 ICY 元数据（正在播的歌名）就得自己点名要
            "Icy-MetaData": "1",
            "User-Agent": "TTPlayer/1.0",
            "Accept": "*/*",
        ]
        // 代理队列挂到同一条串行队列上：回调与「暂停/停止」天然互斥
        let ops = OperationQueue()
        ops.maxConcurrentOperationCount = 1
        ops.name = "ttplayer.radio.session"
        ops.underlyingQueue = queue
        let s = URLSession(configuration: config, delegate: self, delegateQueue: ops)
        session = s
        let t = s.dataTask(with: url)
        task = t
        t.resume()
        Diagnostics.log("电台连接 \(url.absoluteString)")
    }

    private func teardown() {
        task?.cancel()
        task = nil
        decoder?.close()
        decoder = nil
        demuxer = nil
        // 每次重连都换一个新会话：旧会话不 invalidate 会连着自己（= 本对象）一起留着
        session?.invalidateAndCancel()
        session = nil
    }

    private func setState(_ new: State) {
        state = new
        DispatchQueue.main.async { [weak self] in self?.onState?(new) }
    }

    /// 断线后按退避重连；超过上限就报失败（用户点播放会重新从第 0 次开始）
    private func scheduleRetry(reason: String) {
        guard wantsPlayback, !closed else { return }
        attempt += 1
        guard attempt <= RadioPlayer.maxAttempts else {
            setState(.failed("电台连不上（\(reason)）"))
            wantsPlayback = false
            teardown()
            return
        }
        setState(.reconnecting(attempt: attempt))
        let delay = RadioPlayer.retryWait(attempt: attempt)
        let gen = generation
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == gen, self.wantsPlayback, !self.closed else { return }
            self.start()
        }
    }

    /// 一次失败的收尾：能自愈的退避重连，不能的当场说清楚，证书对不上号的换明文试一次
    private func handle(_ fault: RadioFault) {
        guard wantsPlayback, !closed else { return }
        switch fault {
        case .fatal(let why):
            // 重连不会变好：不拖 30 秒，直接把原因摆到显示区与曲目上
            Diagnostics.error("电台连不上：\(why)")
            setState(.failed(why))
            wantsPlayback = false
            teardown()
        case .transient(let why):
            Diagnostics.log("电台断开：\(why)")
            scheduleRetry(reason: why)
        case .downgrade(let plain, let why) where !fallbackTried && plain != currentURL:
            // 只降一次，并把降级写在状态条上：用户给的是 https，播放器擅自走明文必须让人看见
            fallbackTried = true
            attempt = 0
            teardown()
            currentURL = plain
            Diagnostics.error("电台 \(why)，改用明文重连 \(plain.absoluteString)")
            start(announce: .fallingBack)
        case .downgrade(let plain, let why):
            handle(.fatal("\(why)，换成明文 \(plain.absoluteString) 也没连上"))
        }
    }
}

extension RadioPlayer: URLSessionDataDelegate {
    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            handle(.fatal("服务器的应答不是 HTTP 数据流"))
            return
        }
        if let fault = RadioPlayer.classify(status: http.statusCode) {
            completionHandler(.cancel)
            handle(fault)
            return
        }
        // 服务器愿意给元数据时才会带这个头；大小写各站不一样
        var metaInt = 0
        for (key, value) in http.allHeaderFields {
            let name = "\(key)".lowercased()
            if name == "icy-metaint", let n = Int("\(value)") { metaInt = n }
        }
        demuxer = ICYDemuxer(metaInt: metaInt)
        if metaInt > 0 { Diagnostics.log("电台带 ICY 元数据，间隔 \(metaInt) 字节") }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard wantsPlayback, !closed else { return }
        if decoder == nil {
            let d = RadioStreamDecoder()
            d.onInfo = { [weak self] info, format in
                guard let self else { return }
                // 第一块 PCM 出来才算“能听了”；这里只把格式交上去
                DispatchQueue.main.async { self.onInfo?(info, format) }
            }
            d.onPCM = { [weak self] buffer in
                guard let self else { return }
                if self.state != .playing {
                    self.attempt = 0
                    self.setState(.playing)
                }
                DispatchQueue.main.async { self.onPCM?(buffer) }
            }
            d.onFailure = { reason in
                // 单块解码失败不重连（广告段常这样），只有持续没声音才由 URLSession 的错误路径接管
                Diagnostics.error("电台解码：\(reason)")
            }
            guard d.open() else {
                scheduleRetry(reason: "解析器打不开")
                return
            }
            decoder = d
        }
        let chunk: Data
        if var d = demuxer {
            let result = d.demux(data)
            demuxer = d                     // 拆包状态（还剩多少音频/元数据字节）必须留到下一块
            chunk = result.audio
            if let title = result.title {
                DispatchQueue.main.async { self.onTitle?(title) }
            }
        } else {
            chunk = data
        }
        decoder?.feed(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard wantsPlayback, !closed else { return }
        // 状态码不对时是自己在上面掐的，那一遍已经收过场了，不能重复计一次退避
        if let code = (error as? URLError)?.code, code == .cancelled { return }
        guard let error else {
            handle(.transient("服务器结束推流"))
            return
        }
        handle(RadioPlayer.classify(error, trying: currentURL))
    }
}
