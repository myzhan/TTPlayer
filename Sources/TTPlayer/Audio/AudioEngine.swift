import Foundation
import AVFoundation

/// 电台淡出的增益表：把“此刻正在播的声音”在几十毫秒内压到静音。
///
/// 单独算成一个结构体有两个原因：① 硬切（`playerNode.stop()`）在数模转换上留下的是一个
/// 台阶（当前采样值直接跳到 0），听感就是一声“啪”；② 一次把音量跳到 0 还是一次硬切，
/// 必须一格一格降才抹得平。几格、每格多少，自检要能离线算清（音频图上的音量听不见）。
struct RadioFade {
    /// 分成几格降完
    let steps: Int
    private(set) var step = 0

    init(steps: Int) { self.steps = max(1, steps) }

    /// 当前增益（第 0 格 = 全通，第 steps 格 = 静音）
    var gain: Float {
        guard step > 0 else { return 1 }
        return max(0, 1 - Float(min(step, steps)) / Float(steps))
    }

    var finished: Bool { step >= steps }

    /// 降一格，返回这一格的增益
    @discardableResult
    mutating func advance() -> Float {
        step += 1
        return gain
    }

    mutating func reset() { step = 0 }
}

/// 音频引擎：AVAudioPlayerNode + AVAudioUnitEQ(10段) + mainMixer tap 频谱采集
/// 链路：playerNode → channelMixer → eq → mainMixer → output
/// 一律经 channelMixer：AVAudioMixerNode 会顺带把采样率降到输出链约定好的速率并降混，
/// 而 AVAudioUnitEQ（AUNBandEQ）不重采样——把异于输出链采样率的 PCM 直连 eq，engine.start() 会报 -10868。
///
/// 数据通路只有一条：所有文件都交给 FFmpegDecoder 在后台队列按帧解成 float32 PCM，
/// 用 scheduleBuffer 窗口化喂给节点（固定 4 块，约 0.7 秒），数据流着走，不整曲进内存；
/// 解码串行队列不是音频线程，读盘和降采样不会卡渲染。
final class AudioEngine {
    enum EngineError: Error {
        /// 解码器打不开：把系统原始错误带在身上，由 AudioFormats 翻成人话再给用户看
        case unsupportedFile(underlying: Error)
    }

    let spectrum = SpectrumAnalyzer()

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 10)
    /// 多声道降混用：AUNBandEQ 只吃 ≤2 声道，6 声道直连 eq 会让引擎起不来（-10868）
    private let channelMixer = AVAudioMixerNode()
    /// 电台淡出专用：接在 eq → mainMixer 中间。
    /// 不拿 mainMixerNode.outputVolume 做这件事——那是用户的音量与静音，淡完还得还回去
    private let fadeNode = AVAudioMixerNode()

    /// 频点：31 / 62 / 125 / 250 / 500 / 1k / 2k / 4k / 8k / 16k（dB 增益 -12...+12）
    /// 10 段与经典千千静听皮肤均衡器一致
    static let eqFrequencies: [Float] = [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    static var eqBandCount: Int { eqFrequencies.count }

    private var songLength: Double = 0
    private var fileSampleRate: Double = 44_100
    /// 当前曲在镜像里的播放区间（帧）：普通曲目是 0..<file.length，CUE 分轨为其中一段
    private var rangeStartFrame: Int64 = 0
    private var rangeEndFrame: Int64 = 0
    private var baseSample: Int64 = 0          // 本轮排期的起始帧（暂停/ seek 之后的锚点）
    private var pausedSnapshot: Int64 = -1     // 暂停瞬间的位置快照（帧），-1 表示未暂停
    private var scheduleToken: Int = 0         // 手动 stop/seek 后作废旧回调
    private var endToken: Int = -1             // 等待触发的“自然结束”token
    private var endWatchTimer: Timer?

    // MARK: - 自带解码器通路

    private var decoder: PCMAudioDecoder?
    /// 自带解码器的输出格式（也是 playerNode→eq 的连接格式）
    private var decodeFormat: AVAudioFormat?
    /// 当前 playerNode→eq 的连接格式；换了格式必须重连，否则渲染时钟的时基不对
    private var connectionKey = ""
    /// 串行解码队列：读盘 + 降采样都在这上面，不进音频线程
    private let decodeQueue = DispatchQueue(label: "ttplayer.decode", qos: .userInitiated)
    /// 代数：每次 stop/seek/load 递增，旧解码循环看到代数变了就退出
    private let decodeLock = NSLock()
    private var decodeGeneration = 0
    /// 已排进节点但还没被取走的块数（只在 decodeQueue 上读写）。
    /// 「下一个要解的帧」现在住在排期流每一段自己身上（`Feed.nextFrame`），交接时两边才不会看串
    private var decodeInFlight = 0
    /// 一块多少帧：8192 ≈ 186ms@44.1k，4 块约 0.7 秒的预取量
    private static let decodeChunkFrames: Int64 = 8_192
    private static let decodeWindow = 4

    // MARK: - 无缝播放（F01）的排期流
    //
    // 跨曲空白的根因不是「解码来不及」，而是换曲那一下走了 `playerNode.stop()`：
    // 节点里排好的 0.7 秒当场被冲掉，重开文件、重起调度，中间就是静音。所以无缝的做法
    // 不是把下一曲提前解好就「另起一段」，而是让**同一条连接**上的排期不断流：
    // 排期流（`feed`）里按次序放着「还要交给节点的段」，[0] 就是此刻出声那一段，
    // [1] 是预取的下一曲。段与段在流里首尾相接，渲染时钟连续累加，位置换算靠
    // 「这一帧在流里的第几个」而不是「哪首歌」，所以交接时不需要重新对表。

    /// 一段要排进节点的音频：一首曲（或一个 CUE 分轨）在镜像里的可听区间
    private struct Feed {
        /// 排期流里的段号：只用来在下一次加锁时找回自己那一格（`key` 在单曲循环重复接排时会重名）
        let seq: Int64
        let key: String
        let url: URL
        let decoder: PCMAudioDecoder
        let format: AVAudioFormat
        /// 本曲进度 0 所在的帧（CUE 分轨是段起点，不是镜像开头）
        let startFrame: Int64
        /// 本曲可听终点（镜像帧坐标，按容器 duration 定；真解不出来时往下收到实际位置）
        var endFrame: Int64
        /// 实际要交给节点的第一帧：从中间恢复（seek/暂停后续播）时比 startFrame 大
        let firstFrame: Int64
        /// `firstFrame` 在排期流里的位置
        let framesInStream: Int64
        var nextFrame: Int64
        /// 已经交给节点的帧数：>0 就说明这段的声音已经在节点队列里，不能静默丢掉
        var scheduled: Int64 = 0
        /// 本段的 ReplayGain 线性增益：搭段时按身份从 `replayGains` 快照下来。
        /// 抓住“段”而不是“引擎当前”这一份，是为了让下一曲用自己那份标签，
        /// 不拿上一首的增益串过去
        var gain: Float = 1

        var totalFrames: Int64 { endFrame - firstFrame }
        var streamEnd: Int64 { framesInStream + totalFrames }
    }

    /// 预取好的下一曲。与 `feed` 分开存：`feed` 是「这一轮排期」的快照，play/seek 会
    /// 重建它（节点被 stop 冲干净了就得重算流位置），而预取的解码器不该跟着白开一次
    private struct Prefetched {
        let key: String
        let url: URL
        let decoder: PCMAudioDecoder
        let format: AVAudioFormat
        let startFrame: Int64
        let endFrame: Int64
        var gain: Float = 1
    }

    /// 只在 `decodeQueue` 与加锁的几处出入口里读写
    private var feed: [Feed] = []
    private var prefetch: Prefetched?
    /// 段号发号器（交接、截断、预取到货都靠它对上是哪一段）
    private var feedSeq: Int64 = 0
    /// 排期流第 0 帧对应的渲染采样时刻（`playerNode.stop()` 之后就要重新对表）
    private var streamAnchorRender: Int64 = 0
    /// 当前曲目的身份（交接与自检核对用；CUE 分轨写法与预取候选逐字符相同）
    private var currentKey = ""
    /// 当前曲目的来源文件（同一镜像的相邻分轨靠它认出可以复用解码器）
    private var fileURL: URL?
    /// 排期流的读写锁：主线程读位置、`decodeQueue` 写排期，两边都要过它
    private let streamLock = NSLock()
    /// 本轮排期的解码代号与调度代号（预取到货时要能接着往下排，得记住是哪一个）
    private var activeGen = 0
    private var activeToken = 0
    /// 预取请求代号：换曲 / seek / 关开关之后，旧的那次开文件结果不许再登记
    private var prefetchToken = 0

    /// 无缝衔接总开关，默认开。关掉就是「换曲必 stop」的硬切
    private(set) var gaplessEnabled = true
    /// 此刻预取好的下一曲身份（空 = 没有）
    private(set) var nextPreparedKey = ""
    /// 这一轮预取为什么没做成：支持边界要能说出口（自检、属性面板都读它）
    private(set) var gaplessNote = ""
    /// 已经无缝交接过几次（自检数得着，别拿「没报错」当「接上了」）
    private(set) var gaplessHandovers = 0
    /// 交接上报：预取的那一曲现在开始出声，带它的身份。控制层凭这条更新
    /// 显示/历史/歌词/系统 Now Playing，不能再走装载那一路（那会 stop 节点）
    var onGaplessHandover: ((String) -> Void)?

    /// 控制层算好的「曲目身份 → 线性增益」（F02）。热路径只按已经拿到的段内常数相乘，
    /// 不查表、不解析标签；这张表只在装载/预取/设置变动时整份换一次
    private var replayGains: [String: Float] = [:]
    /// 此刻真在施加的当前曲增益（属性面板要回答「到底加了多少」）
    private(set) var replayGainLinear: Float = 1

    /// 换掉整张增益表，并把已经排进流的段与预取段一起改到新值。
    /// 已经交给节点的那些 PCM 改不回来（最多 0.7 s），下一块起就是新增益——
    /// 拿 `playerNode.stop()` 去追己排完的缓冲，代价是用户听见一声硬切
    func setReplayGains(_ gains: [String: Float]) {
        streamLock.lock()
        replayGains = gains
        for i in feed.indices { feed[i].gain = gains[feed[i].key] ?? 1 }
        replayGainLinear = feed.first.map { gains[$0.key] ?? 1 } ?? 1
        if var p = prefetch {
            p.gain = gains[p.key] ?? 1
            prefetch = p
        }
        streamLock.unlock()
    }

    /// 搭段时按身份取增益（调用方持 `streamLock`）
    private func gain(for key: String) -> Float { replayGains[key] ?? 1 }

    /// 把一整块 PCM 按比例缩放。无损在解出来的这一条路上走，不重排也不重采样
    private static func applyGain(_ g: Float, to buffer: AVAudioPCMBuffer) {
        guard g != 1, let ch = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        for c in 0..<Int(buffer.format.channelCount) {
            let p = ch[c]
            for i in 0..<n { p[i] *= g }
        }
    }

    /// 自然播放结束（在主线程回调）
    var onPlaybackFinished: (() -> Void)?

    // MARK: - 无缝衔接的排期流水线

    /// 本轮排期作废：节点被冲干净了，流坐标要从头重算。
    /// `keepPrefetch` = 只换排期不换曲目（ seek / 停止），预取的解码器不该跟着白开一次；
    /// 换曲目（装载 / 卸曲 / 切电台）时必须连预取一起丢，否则下一曲会接到不相干的那条上
    private func dropStream(keepPrefetch: Bool = false) {
        streamLock.lock()
        feed = []
        if !keepPrefetch {
            prefetch = nil
            nextPreparedKey = ""
        }
        streamLock.unlock()
        prefetchToken += 1
    }

    /// 用当前曲目搭出排期流的第一段（节点刚被冲过，流坐标从 0 重来）。
    /// 预取好的下一曲直接接在后面：它一段都没交给过节点，接在哪都不会出声
    private func seedStream(from frame: Int64) {
        guard let dec = decoder, let fmt = decodeFormat, let url = fileURL else { return }
        streamLock.lock()
        let head = newFeed(key: currentKey, url: url, decoder: dec, format: fmt,
                           startFrame: rangeStartFrame, endFrame: rangeEndFrame, firstFrame: frame,
                           framesInStream: 0, gain: gain(for: currentKey))
        var list = [head]
        if let next = joinedFeed(after: head) { list.append(next) }
        feed = list
        streamLock.unlock()
    }

    /// 发号并拼一段。调用方必须持 `streamLock`（发号器不能两边同时拿）。
    /// `gain` 由调用方定：正在播的那一段按当前表查，接进来的预取段用它自己那份
    /// （预取到货之后表可能又换过，接排时再查一次会把已经算好的数值丢掉）
    private func newFeed(key: String, url: URL, decoder: PCMAudioDecoder, format: AVAudioFormat,
                         startFrame: Int64, endFrame: Int64, firstFrame: Int64,
                         framesInStream: Int64, gain: Float) -> Feed {
        feedSeq += 1
        return Feed(seq: feedSeq, key: key, url: url, decoder: decoder, format: format,
                    startFrame: startFrame, endFrame: endFrame, firstFrame: firstFrame,
                    framesInStream: framesInStream, nextFrame: firstFrame,
                    gain: gain)
    }

    /// 把预取段接在 `head` 后面（不改状态，返回 nil = 接不上）。调用方持锁
    private func joinedFeed(after head: Feed) -> Feed? {
        guard gaplessEnabled, let p = prefetch,
              p.format.sampleRate == head.format.sampleRate,
              p.format.channelCount == head.format.channelCount else { return nil }
        prefetch = nil
        nextPreparedKey = p.key
        gaplessNote = ""
        return newFeed(key: p.key, url: p.url, decoder: p.decoder, format: p.format,
                       startFrame: p.startFrame, endFrame: p.endFrame, firstFrame: p.startFrame,
                       framesInStream: head.streamEnd, gain: p.gain)
    }

    /// 预取下一曲（F01）：后台把解码器开好、区间算准，等当前段排完就地接上。
    /// 环境不允许时当场把原因写进 `gaplessNote`——支持边界要能说出口，不能闷着不说
    func prepareNext(url: URL, from: Double = 0, to: Double? = nil, key: String) {
        guard !isRadio else { gaplessNote = "电台是无限流，没有下一曲可排"; return }
        guard gaplessEnabled else { gaplessNote = "无缝播放已关闭"; return }
        guard let current = decoder, let fmt = decodeFormat, !currentKey.isEmpty else {
            gaplessNote = "当前曲目还没装载，不谈预取"
            return
        }
        streamLock.lock()
        // 同一条已经排在队里了（预取到货或已接进流）就别重开一次；
        // 单曲循环重播当前曲是控制层拿另一个 `key` 进来的，不会在这里被挡掉
        let duplicate = key == currentKey || key == nextPreparedKey
            || feed.contains(where: { $0.key == key }) || prefetch?.key == key
        streamLock.unlock()
        guard !duplicate else { return }
        prefetchToken += 1
        let token = prefetchToken
        let rate = fmt.sampleRate
        let channels = fmt.channelCount
        // 同一个镜像里的相邻分轨：接着往下读就行，不重开文件、不重新探流（也不额外占一份解码器）
        let sameFile = fileURL?.path == url.path
        let shared: PCMAudioDecoder? = sameFile ? current : nil
        decodeQueue.async { [weak self] in
            guard let self else { return }
            var prepared: Prefetched?
            var note = ""
            var opened: PCMAudioDecoder? = shared
            if shared == nil {
                do { opened = try FFmpegDecoder(url: url) }
                catch { note = "下一曲打不开，换曲那一下会停一下" }
            }
            if let dec = opened {
                let candidate = AVAudioFormat(standardFormatWithSampleRate: dec.sampleRate,
                                              channels: AVAudioChannelCount(dec.channelCount))
                // 采样率/声道不一样就得重连音频图，重连必先把引擎停下来——那正是硬切，接不上
                if let outFmt = candidate, outFmt.sampleRate == rate,
                   outFmt.channelCount == channels {
                    let total = dec.totalFrames
                    let start = min(max(0, Int64(max(0, from) * dec.sampleRate)), max(0, total - 1))
                    let end: Int64
                    if let to {
                        end = min(max(start + 1, Int64(max(0, to) * dec.sampleRate)), total)
                    } else {
                        end = total
                    }
                    if total > 0, end - start > 0 {
                        prepared = Prefetched(key: key, url: url, decoder: dec, format: outFmt,
                                              startFrame: start, endFrame: end)
                    } else {
                        note = "下一曲没有可听区间，接不上"
                    }
                } else if candidate == nil {
                    note = "下一曲的输出格式不合法，接不上"
                } else {
                    note = "下一曲是 \(Int(dec.sampleRate)) Hz/\(dec.channelCount) 声道，"
                        + "与当前曲目不同（换曲会停一下）"
                }
            }
            self.streamLock.lock()
            if token == self.prefetchToken {
                // 到货时才对一次增益：从发起预取到这一刻，用户可能已经改了设置或换了两首之间的
                // 顺序，拿发起那一刻的快照就会接上过期数值
                var ready = prepared
                ready?.gain = self.gain(for: key)
                self.prefetch = ready
                self.nextPreparedKey = ready?.key ?? ""
                self.gaplessNote = ready == nil ? note : ""
            }
            let streaming = !self.feed.isEmpty
            self.streamLock.unlock()
            // 当前段都已经排完了才会等到这一份货：补一次才接得上
            if prepared != nil, streaming {
                self.fillDecodeWindow(generation: self.activeGen, token: self.activeToken)
            }
        }
    }

    /// 丢掉预取的下一曲（队列改了、模式改了、用户 seek 了都要及时作废）。
    /// 已经开始往节点里排的（`scheduled > 0`）丢不得：那些 PCM 已经在节点队列里，
    /// 抽掉就是一段静音，那种情况只能由交接或下一次装载把节点冲掉
    func cancelNext() {
        streamLock.lock()
        let stuck = feed.count > 1 && feed[1].scheduled > 0
        if !stuck, feed.count > 1 { feed.removeLast() }
        prefetch = nil
        nextPreparedKey = ""
        if stuck { gaplessNote = "下一曲已经开始出声，改不了的次序只能等下一次换曲生效" }
        streamLock.unlock()
        prefetchToken += 1
    }

    /// 无缝开关（菜单里那一项）。关掉时把排好的下一曲退回去，让换曲回到「按老办法硬切」
    func setGaplessEnabled(_ on: Bool) {
        gaplessEnabled = on
        streamLock.lock()
        // 开关一翻，上一轮记下的原因就过期了：开回来还挂着「无缝播放已关闭」，
        // 界面就会在无缝已经生效时继续报硬切（真翻过开关才看得见）
        gaplessNote = on ? "" : "无缝播放已关闭"
        streamLock.unlock()
        guard !on else { return }
        cancelNext()
    }

    /// 渲染时钟越过本段终点、而后面还接着一段：把排期流往前挪一格。
    /// 全程不碰 `playerNode`——声音不断，只是「当前曲目」换了个人
    @discardableResult
    private func handoverIfNeeded() -> Bool {
        streamLock.lock()
        guard feed.count >= 2, let head = feed.first,
              let rt = playerNode.lastRenderTime, rt.isSampleTimeValid,
              rt.sampleTime - streamAnchorRender >= head.streamEnd else {
            streamLock.unlock()
            return false
        }
        let next = feed[1]
        feed = [next]
        gaplessHandovers += 1
        let count = gaplessHandovers
        streamLock.unlock()
        // 出声的已经是下一曲了：「当前曲目」跟着挪（不重新装载、不碰节点）
        decoder = next.decoder
        decodeFormat = next.format
        fileSampleRate = next.format.sampleRate
        rangeStartFrame = next.startFrame
        rangeEndFrame = next.endFrame
        songLength = max(0, Double(next.endFrame - next.startFrame) / next.format.sampleRate)
        baseSample = next.startFrame
        pausedSnapshot = -1
        currentKey = next.key
        fileURL = next.url
        Diagnostics.log("无缝交接 #\(count)：\(next.key)")
        onGaplessHandover?(next.key)
        decodeQueue.async { [weak self] in self?.topUp() }
        return true
    }

    /// 排期窗口重新填一次（预取到货、交接之后都要）。只在 `decodeQueue` 上叫
    private func topUp() {
        streamLock.lock()
        let gen = activeGen
        let token = activeToken
        let streaming = !feed.isEmpty
        streamLock.unlock()
        guard streaming else { return }
        fillDecodeWindow(generation: gen, token: token)
    }

    /// 解不出来了（坏块 / 文件实际比 duration 短）：把本段收尾到真交出去的位置。
    /// 流坐标是按「每段 endFrame − firstFrame 帧」排的，收在这里就不会多排一段静音
    private func truncateTail(of seg: Feed) {
        streamLock.lock()
        defer { streamLock.unlock() }
        guard let i = feed.firstIndex(where: { $0.seq == seg.seq }) else { return }
        feed[i].endFrame = max(feed[i].firstFrame, feed[i].nextFrame)
    }

    /// 排期流是否已经见底（含被截断后收短的那一截）。不能拿 `rangeEndFrame` 判：
    /// 接上下一曲后那里是「本段终点」，而本段播完不等于该收手
    private var reachedStreamEnd: Bool {
        streamLock.lock()
        defer { streamLock.unlock() }
        guard let last = feed.last else { return false }
        guard let rt = playerNode.lastRenderTime, rt.isSampleTimeValid else { return false }
        return rt.sampleTime - streamAnchorRender >= last.streamEnd
    }

    /// 流坐标（渲染时钟已经走过的帧数）→ 镜像帧号：越过几段就往后翻几段。
    /// 交接前后都走这一条，所以不需要「现在是哪首歌」参与换算
    private func frameInStream(_ consumed: Int64) -> Int64 {
        streamLock.lock()
        defer { streamLock.unlock() }
        guard var seg = feed.first else { return baseSample }
        for f in feed where consumed >= f.framesInStream { seg = f }
        let local = max(0, consumed - seg.framesInStream)
        return seg.firstFrame + min(local, max(0, seg.endFrame - seg.firstFrame))
    }


    // MARK: - 网络电台通路

    /// 电台是无限流：没有总长、不能定位，和「文件 + 随机定位」那条通路共用 playerNode，
    /// 所以 EQ / 频谱 / 音量全都照用（不然切到电台就没频谱，等于另一套播放器）
    private let radio = RadioPlayer()
    private(set) var isRadio = false
    /// 当前流的输出格式（也是 playerNode→eq 的连接格式）
    private var radioFormat: AVAudioFormat?
    /// 已排进节点、还没播完的帧数：网络冲得比声音快时靠它兜住内存
    private var radioPendingFrames: Int64 = 0
    private var radioBaseTime: Int64?
    private var radioElapsed: Double = 0
    /// 节点已经拉起来、可以往里排流的 PCM 了。流比引擎先到的那几百毫秒直接丢
    private var radioStarted = false
    /// 用户按了播放，但流的格式还没解出来：格式一到就起引擎开声（见 attachRadioFormat）。
    /// 停止与暂停都会把它抹掉，所以「晚到的流状态」能不能把界面算成在播也只认它
    private(set) var radioWantsPlay = false
    /// 引擎正在 start() 里：它内部会转主线程 runloop，期间任何 AVFAudio 图变更都不能做
    private var startingEngine = false
    /// start() 期间到的流格式，出来再接
    private var pendingRadioFormat: AVAudioFormat?
    /// 电台状态与流里的「正在播」都往控制层转（它负责显示与存档）
    var onRadioState: ((RadioPlayer.State) -> Void)?
    var onRadioTitle: ((String) -> Void)?
    var onRadioInfo: ((RadioStreamDecoder.Info) -> Void)?
    private(set) var radioState: RadioPlayer.State = .idle
    private(set) var radioInfo = RadioStreamDecoder.Info()

    // MARK: - 电台淡出
    // 换台/降级那一下原来是硬切：`playerNode.stop()` 把当前采样值直接跳到 0，
    // 数模转换上留下的是一个台阶，听感就是「啪」。这里在 eq 与用户音量之间插一层
    // fadeNode，切之前先花 120 ms 把它逐格降到静音，断流发生在听不见的时候。

    /// 淡出总时长（秒）：换台本来就要等网络，多等这一小段没人感觉得到
    static let radioFadeSeconds = 0.12
    /// 分几格降完：一次把音量跳到 0 还是一次硬切，必须一格一格走才抹得平
    static let radioFadeSteps = 6
    private var radioFade = RadioFade(steps: AudioEngine.radioFadeSteps)
    private var fadeTimer: Timer?
    /// 淡完要做的事（冲缓冲、重新开声），带代号：新流起播后就不该再去碰节点
    private var fadeTails: [(token: Int, action: () -> Void)] = []
    /// 淡完要切的台。这是用户的点选，中途按了播放/停止也不能悄悄丢掉，
    /// 所以它不受代号约束；只留最后一个（连按下一曲只需落到最后选中的那条）
    private var fadeSwitch: (() -> Void)?
    /// 会话号：每开一条新流（或彻底断开电台）加一，延后的动作只认登记时那个会话
    private var radioSession = 0
    /// 已经淡完的会话：同一个会话不重复淡（新流起播会复位，所以淡过又响的还能再淡）
    private var fadedSession = -1
    /// 淡出机代号：新起播时递增，作废还没执行的延后动作
    private var fadeToken = 0

    /// 电台此刻真在出声吗（没出声时淡出纯属白等）
    var radioHasSound: Bool { isRadio && (playerNode.isPlaying || radioPendingFrames > 0) }
    /// 正在淡出（延后的动作还没执行）
    var isFadingRadio: Bool { fadeTimer != nil }
    /// 最近一段淡出走出来的增益序列。自检凭据：音量听不见，采样时刻又会被 Timer 抖动带偏，
    /// 只有「走过哪几格」是确定的；它在下一段淡出开始时才清空，所以换完流仍读得到上一段
    private(set) var radioFadeCurve: [Float] = []
    /// 电台淡出机自己那一格的值（不含睡眠系数）：新流真起播了才抬回 1
    var radioFadeVolume: Float { radioFadeGain }

    // MARK: - 电台缓冲与连接质量（F11）
    // 直播的卡顿只能拿「节点里还排着多少秒没播完」与「排空了几回」说清楚。
    // 这里不碰码率：那是流的属性，既不是网速也不是音质，拿它当质量分是需求明令禁止的。

    /// 这一场收听（从装载这台电台到换台/停止）的质量台账，内部自动重连算在同一场里
    private(set) var radioQuality = RadioQuality()
    /// 电台时基用的秒表：`systemUptime` 是单调时钟，不会被改系统时间/休眠唤醒带跑，
    /// 而且只依赖 Foundation（不为了一个读数把 QuartzCore 拖进音频层）
    private var radioClock: Double { ProcessInfo.processInfo.systemUptime }

    /// 节点里已经排好、还没播完的音频有多少秒（0 = 此刻排空）
    var radioBufferedSeconds: Double {
        guard let sr = radioFormat?.sampleRate, sr > 0 else { return 0 }
        return Double(max(0, radioPendingFrames)) / sr
    }
    /// 「缓冲不足」该不该说出口（只在流已经连上、节点真的在往外播时才报，
    /// 刚连上还没排块那一瞬只能叫「连接中」，不能拉一次「缓冲不足」误导人）
    var radioBufferLow: Bool { radioStarted && radioQuality.isBufferLow }
    /// 台账那句话（统计窗口与本会话累计都在里面）
    var radioQualitySummary: String { radioQuality.summary(now: radioClock) }
    /// fadeNode 上真正写进去的那个数（两层淡出相乘），自检拿它对实际输出链路
    var fadeNodeVolume: Float { outputWired ? fadeNode.outputVolume : 1 }

    // MARK: - 睡眠定时器淡出（F09）
    // 到点前最后十秒要慢慢收到无声。这件事只能做在 fadeNode 那一层：它是 eq 与
    // 用户音量中间的独立一级，碰它不会改到用户的音量与静音（mainMixer.outputVolume），
    // 也不会和电台换台那 120 ms 的淡出互相覆盖（两者相乘）。

    /// 睡眠淡出的当前系数（1 = 不动音量），由 `PlayerController` 按倒计时逐格递下来
    private var sleepGain: Float = 1
    /// 电台淡出机自己那一格的值（不乘睡眠系数，留给自检读上一段淡出走成什么样）
    private var radioFadeGain: Float = 1

    /// 两层淡出合成后写进节点
    private func applyFadeVolume() {
        fadeNode.outputVolume = radioFadeGain * sleepGain
    }

    /// 递一档睡眠淡出系数（0…1）。取消定时或重新播放时递回 1 就是「恢复正常增益」
    func setSleepGain(_ g: Float) {
        sleepGain = max(0, min(1, g))
        applyFadeVolume()
    }

    /// 此刻输出链路上睡眠淡出给多少（自检与属性面板读它）
    var sleepFadeVolume: Float { sleepGain }

    private var volume: Float = 0.8
    private var muted = false

    init() {
        engine.attach(playerNode)
        engine.attach(eq)
        engine.attach(channelMixer)
        engine.attach(fadeNode)
        configureEQBands()
        // 这里不接 eq → mainMixer：取 mainMixerNode 就会建输出节点（打开默认输出设备），
        // 实测 130 ms，启动时根本没有声音要出，这笔开销留到真正加载/播放时再付（见 wireOutputIfNeeded）。
        // 多声道支路同理：先给 channelMixer 挂一个空输出再去接 6 声道输入，引擎初始化会报 -10868，
        // 所以 playerNode / channelMixer 的连线必须“什么时候用、什么时候接”。
        // 电台：状态与「正在播」往上转（stopRadio 时 isRadio 已置 false，回调自然被丢掉）
        radio.onState = { [weak self] state in
            guard let self, self.isRadio else { return }
            self.radioState = state
            // 降级重连（证书对不上号 → 换明文）：旧流在节点里最多排着 3 秒，
            // 新流的格式又可能对不上，两条流的缓冲叠在一起迟早是一次硬切，
            // 所以先把旧缓冲淡掉再交接
            if case .fallingBack = state { self.fadeOutRadioBuffer(reason: "改用明文重连") }
            // 重连与降级都是「这一场里又断了一次」的凭据，进台账（F11）
            switch state {
            case .reconnecting, .fallingBack: self.radioQuality.noteReconnect(now: self.radioClock)
            default: break
            }
            self.onRadioState?(state)
        }
        radio.onInfo = { [weak self] info, format in
            guard let self, self.isRadio else { return }
            self.radioInfo = info
            // 引擎正在 start() 里转 runloop：这条回调就是通过那个 runloop 进来的，
            // 此时改音频图会跟启动撞在引擎锁上（实测卡死），先存起来出去再接
            if self.startingEngine {
                self.pendingRadioFormat = format
            } else {
                self.attachRadioFormat(format)
            }
            self.onRadioInfo?(info)
        }
        radio.onPCM = { [weak self] buffer in self?.enqueueRadio(buffer) }
        radio.onTitle = { [weak self] title in self?.onRadioTitle?(title) }
    }

    private func configureEQBands() {
        for (i, freq) in Self.eqFrequencies.enumerated() {
            let band = eq.bands[i]
            band.filterType = .parametric
            band.frequency = freq
            band.bandwidth = 1.0
            band.bypass = false
            band.gain = 0
        }
        eq.globalGain = 0   // 前置放大 0dB
    }

    // MARK: - 加载与播放

    /// 加载文件（不自动播放）；from/to 是 CUE 分轨在镜像里的起止秒，to 为 nil 则放到文件结尾。
    /// `key` 是曲目身份（普通文件 / CUE 分轨 / 归档条目各有一套写法），无缝衔接凭它核对预取到货
    func load(url: URL, from: Double = 0, to: Double? = nil, key: String = "") throws {
        // 切回本地文件：电台会话要彻底断掉，否则它会继续往节点里塞流
        stopRadio()
        scheduleToken += 1
        disarmEndWatch()
        playerNode.stop()
        cancelDecoding()
        dropStream()
        decoder = nil

        // 一律交给 FFmpeg 解码（不再问系统 AVAudioFile）：解出来的立体声 float32
        // 走既有的窗口化 scheduleBuffer 通路，EQ/频谱/精确定位照常工作。
        let dec: FFmpegDecoder
        do {
            dec = try FFmpegDecoder(url: url)
        } catch {
            throw EngineError.unsupportedFile(underlying: error)
        }
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: dec.sampleRate,
                                      channels: AVAudioChannelCount(dec.channelCount)) else {
            throw EngineError.unsupportedFile(
                underlying: FFmpegDecoder.DecodeError.cannotDecode(reason: "输出格式非法"))
        }
        decoder = dec
        decodeFormat = fmt
        let total = dec.totalFrames
        connectPlayer(format: fmt)
        fileSampleRate = fmt.sampleRate
        // 区间必须落在文件内，否则调度段数为负会直接静音；
        // 末轨没有终点，不能拿无穷大乘采样率（转 Int64 会溢出），直接取文件尾
        let start = min(max(0, Int64(max(0, from) * fileSampleRate)), max(0, total - 1))
        let end: Int64
        if let to {
            end = min(max(start + 1, Int64(max(0, to) * fileSampleRate)), total)
        } else {
            end = total
        }
        rangeStartFrame = start
        rangeEndFrame = end
        songLength = Double(end - start) / fileSampleRate
        baseSample = start
        pausedSnapshot = -1
        fileURL = url
        currentKey = key.isEmpty ? url.path : key
        spectrum.setSampleRate(fmt.sampleRate)
    }

    // MARK: - 网络电台

    /// 加载电台（不自动播放）：playerNode 用什么格式连要等流里解出第一帧才知道（见 attachRadioFormat）
    func loadRadio(url: URL) {
        stopRadio()
        scheduleToken += 1
        disarmEndWatch()
        playerNode.stop()
        cancelDecoding()
        dropStream()
        decoder = nil
        decodeFormat = nil
        isRadio = true
        songLength = 0
        rangeStartFrame = 0
        rangeEndFrame = 0
        baseSample = 0
        pausedSnapshot = -1
        radioElapsed = 0
        radioBaseTime = nil
        radioPendingFrames = 0
        radioStarted = false
        radioWantsPlay = false
        pendingRadioFormat = nil
        radioFormat = nil
        radioInfo = RadioStreamDecoder.Info()
        radioState = .connecting
        radioSession += 1
        // 台账翻页：上一场听另一个台卡了几回，不该记到这一场头上
        radioQuality.startSession(radioSession)
        radio.open(url)
        Diagnostics.log("电台加载 \(url.absoluteString)")
    }

    /// 停掉电台会话并复位（切回本地文件、停止、换台都要走）
    func stopRadio() {
        guard isRadio else { return }
        // 上一段淡出还没走完：当场收尾。待办的换轨照样做掉，不因为按了停止就丢
        commitRadioFade()
        isRadio = false
        radioSession += 1
        radio.stop()
        radioFormat = nil
        radioPendingFrames = 0
        radioBaseTime = nil
        radioElapsed = 0
        radioStarted = false
        radioWantsPlay = false
        radioState = .idle
        radioInfo = RadioStreamDecoder.Info()
        resetRadioFade()
    }

    // MARK: - 电台淡出的接线

    /// 切台前把正在播的流淡掉，淡完再执行 `then`（换哪个轨由控制层定，引擎只负责抹平台阶）。
    /// 没声音、输出还没接、这个会话刚淡过时不白等 120 ms，当场就执行
    func fadeOutRadioStream(reason: String, then: @escaping () -> Void) {
        if isFadingRadio {
            fadeSwitch = then
            return
        }
        guard radioHasSound, outputWired, fadedSession != radioSession else {
            then()
            return
        }
        fadeSwitch = then
        startRadioFade(reason: reason)
    }

    /// 把此刻的声音淡到静音，淡完冲掉节点里排着的缓冲（暂停、停止、降级重连都走这里）。
    /// 不能只 `playerNode.pause()`：暂停期间渲染时钟照走、排期回调不再触发，
    /// 背压计数会算虚高，恢复后新到的块会被「已经排够 3 秒」全部挡掉
    private func fadeOutRadioBuffer(reason: String) {
        // 已经在淡：淡完自然会冲缓冲，不重开一格（尾巴里那份就是本会话要做的同一件事）
        if isFadingRadio { return }
        guard radioHasSound, outputWired, fadedSession != radioSession else {
            flushRadioBuffers()
            return
        }
        let token = fadeToken
        fadeTails.append((token: token, action: { [weak self] in self?.flushRadioBuffers() }))
        startRadioFade(reason: reason)
    }

    /// 冲掉旧流在节点里排着的缓冲；用户还想听（降级重连）就当场重新开声
    private func flushRadioBuffers() {
        playerNode.stop()
        radioPendingFrames = 0
        // 这是播放器自己把旧流冲掉（暂停/停止/降级交接），不是「网络跟不上」：
        // 只把缓冲读数抹成 0，不能计一笔欠载，否则用户按个暂停就成了「网络差」
        radioQuality.noteBuffer(seconds: 0, now: radioClock)
        if radioWantsPlay { startRadioPlayback() }
    }

    /// 起一段淡出：格子清零，每格把 fadeNode 的音量往下压一截
    private func startRadioFade(reason: String) {
        radioFade.reset()
        radioFadeCurve = []
        Diagnostics.log("电台淡出：\(reason)")
        let t = Timer(timeInterval: Self.radioFadeSeconds / Double(Self.radioFadeSteps),
                      repeats: true) { [weak self] _ in
            self?.advanceRadioFade()
        }
        RunLoop.main.add(t, forMode: .common)
        fadeTimer = t
    }

    /// 降一格并写下凭据，走完最后一格就收尾。返回这段淡出是否已经走完
    @discardableResult
    func advanceRadioFade() -> Bool {
        guard isFadingRadio else { return false }
        let g = radioFade.advance()
        radioFadeCurve.append(g)
        radioFadeGain = g
        applyFadeVolume()
        let done = radioFade.finished
        if done { finishRadioFade() }
        return done
    }

    /// 淡完了：把待办的事按序做掉。先记 `fadedSession` 再执行——
    /// 尾巴里紧跟的 `engine.stop()` 会再请求一次淡出，那时它应当当场放行而不是又等 120 ms
    private func finishRadioFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        let tails = fadeTails
        let station = fadeSwitch
        fadeTails = []
        fadeSwitch = nil
        let token = fadeToken
        radioFade.reset()
        fadedSession = radioSession
        for (t, action) in tails where t == token { action() }
        station?()
    }

    /// 淡出还没走完用户又按了播放/暂停/停止：当场收尾（不等剩下的格子）。
    /// 音量不在这里抬回来，也先不冲缓冲——两者都由接下来的新会话自己负责
    private func commitRadioFade() {
        guard isFadingRadio else { return }
        finishRadioFade()
    }

    /// 让 fadeNode 回到全通。淡出机只管电台，但电台 → 本地文件 也会留下那个 0，
    /// 抬音量两侧都得记得做，否则换过去就是一句“怎么没声了”
    private func openRadioFade() {
        guard outputWired else { return }
        radioFadeGain = 1
        applyFadeVolume()
    }

    /// 淡出机复位（开新会话或新流真起播）：格子从头开始、待办丢掉。
    /// 音量不在这里抬：提前抬等于让旧缓冲在节点里又响一次，抬音量只能到真起播那一刻；
    /// `radioFadeCurve` 也不在这里清，留给自检读上一段淡出走成了什么样
    private func resetRadioFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        fadeTails = []
        fadeSwitch = nil
        radioFade.reset()
        fadedSession = -1
        fadeToken += 1
    }

    /// 流解出格式后重连 playerNode→eq。广告段切码流（采样率变了）才重连。
    ///
    /// 「起引擎」只能在这里做，不能提前到 play()：playerNode 挂着却没接输出时
    /// `engine.start()` 会失败（实测 AVFAudio code 35，kAUStartIO 起不来），
    /// 节点没拉起来则时基不走、也听不见。
    private func attachRadioFormat(_ format: AVAudioFormat) {
        let key = "\(format.sampleRate)/\(format.channelCount)"
        // radioFormat 无论要不要重连都得记下：`enqueueRadio` 拿它挡错格式的块、
        // `startRadioPlayback` 拿它当「图已接好」的凭据。只放进「要重连」那一支，
        // 刚播过 44.1 kHz 立体声本地文件再切进同格式的电台（最常见的一档）就会
        // 一声不响：流在解、状态在走「直播中」，就是没一块 PCM 排进节点（实测）
        radioFormat = format
        if key != connectionKey {
            fileSampleRate = format.sampleRate
            connectPlayer(format: format)
            radioBaseTime = nil
            radioPendingFrames = 0
            spectrum.setSampleRate(format.sampleRate)
        }
        // connectPlayer 在引擎运行时接线会先把引擎停掉，接完必须重新拉起来；
        // 只是连着（还没按播放）就不起引擎，等 play() 再说
        if radioWantsPlay { startRadioPlayback() }
    }

    /// 把引擎和节点真正拉起来（调用前 radioFormat 必须已经有值）
    private func startRadioPlayback() {
        guard radioFormat != nil, !startingEngine else { return }
        // 淡出还在走、后面挂着用户要点的那个台：这时候抬音量、把节点再开起来，
        // 等于把正要淡掉的旧流又放出声，而且 `resetRadioFade()` 会连带把那条待办丢掉——
        // 实测：断线退避中按「重试这个电台」，淡出走一半旧连接的格式到了，重试就此没了影。
        // 这里不是拒绝播放，而是把开声让给待办里那一次装载（它紧跟着就会重走这条路）
        if isFadingRadio, fadeSwitch != nil { return }
        tryStartEngine()
        guard engine.isRunning else {
            Diagnostics.error("电台：音频引擎没起来，暂不排流")
            return
        }
        // 引擎真起来了才开闸放 PCM：start() 里转主线程 runloop 的时候排流会撞引擎锁
        radioStarted = true
        // 新流要出声了：先把淡出机复位再把音量抬回来（上一段淡出压下去的 0 不能跟着新流走）
        resetRadioFade()
        openRadioFade()
        playerNode.play()
        if radioBaseTime == nil { radioBaseTime = playerNode.lastRenderTime?.sampleTime }
    }

    /// 把一块流 PCM 排进节点。声音是实时的，网络往往更快：已排超过 3 秒就先丢掉新块，
    /// 否则一条高码率电台能把常驻内存顶上去（直播丢一点数据比涨内存可接受）
    private func enqueueRadio(_ buffer: AVAudioPCMBuffer) {
        // 只在引擎与节点真拉起来之后才排（startRadioPlayback 开闸）：
        // engine.start() 内部转主线程 runloop，那时排流会跟启动撞引擎锁（实测卡死）
        guard isRadio, radioStarted, let radioFormat,
              buffer.format.sampleRate == radioFormat.sampleRate else { return }
        let maxPending = Int64(radioFormat.sampleRate * 3)
        guard radioPendingFrames <= maxPending else { return }
        radioPendingFrames += Int64(buffer.frameLength)
        // 到货了就把缓冲时长报上去（高于水线时它顺手把「见底」那个状态摘掉）
        radioQuality.noteBuffer(seconds: radioBufferedSeconds, now: radioClock)
        let frames = Int64(buffer.frameLength)
        // 用 `.dataConsumed` 而不是 `.dataPlayedBack`：后者要等音频真从设备放出去才回调，
        // AVFAudio 只能为每一块排一个「未来某时刻触发」的派发定时器；电台连续播几小时
        // 又不 reset，那些定时器连同 Command/回调块全堆在堆里（实测 ~3MB/min 只涨不落）。
        // `.dataConsumed` 在渲染线程就地取走这块时回调，不需要定时器，也不漏——本地文件
        // 那条 scheduleBuffer 走的就是它。递减背压的语义不变：块被节点取走即不再算 pending。
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            DispatchQueue.main.async { self?.releaseRadioFrames(frames) }
        }
    }

    /// 一块被节点取走（渲染消费掉了）：递减背压计数。排到归零就是需求说的「欠载」——
    /// 节点里一块不剩而用户还想听，这比任何估算都直接（F11）。
    /// 只算下降沿：`RadioQuality.noteUnderrun` 自己在见底期间不重复计数
    private func releaseRadioFrames(_ frames: Int64) {
        radioPendingFrames = max(0, radioPendingFrames - frames)
        guard isRadio, radioStarted else { return }
        if radioPendingFrames == 0 {
            radioQuality.noteUnderrun(now: radioClock)
        } else {
            radioQuality.noteBuffer(seconds: radioBufferedSeconds, now: radioClock)
        }
    }

    /// eq → fade → mainMixer 是否已接好。首次取 `mainMixerNode` 会建输出节点并打开默认输出设备，
    /// 实测 130 ms；启动阶段不需要出声，所以推迟到 load/play 时再付这笔钱
    private var outputWired = false

    /// 自检不送物理设备（`TTPLAYER_SILENT_OUTPUT=1`）：把 mainMixer 主输出到硬件的增益锁到 0，
    /// 同时把频谱 tap 从 mainMixer 挪到 fadeNode（音量推子上游）——这样硬件接到静音，
    /// tap 仍读到完整 PCM，不影响其他应用，也不需要 osascript 去改系统 mute。
    /// macOS 没有公开的 `kAudioHardwarePropertyNullAudioDevice`（iOS-only），也没
    /// 有公开的“给本进程挂个 null device”入口；CoreAudio 层此路走不通，只在 AU 拓扑里改个接位。
    private var silentOutput: Bool {
        ProcessInfo.processInfo.environment["TTPLAYER_SILENT_OUTPUT"] != nil
    }

    private func wireOutputIfNeeded() {
        guard !outputWired else { return }
        outputWired = true
        // 中间插一层淡出节点（eq → fade → mainMixer）：电台切台要逐格降音量，
        // 而 eq 后面直接就是用户的音量，不能拿它做这件事
        engine.connect(eq, to: fadeNode, format: nil)
        engine.connect(fadeNode, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = silentOutput ? 0 : (muted ? 0 : volume)
        // 用户固定过输出设备：输出链第一次接起来时就按那台谈。不接这一笔，
        // 启动时记下的选择会在第一次播放时默默回到系统默认（需求里“不擅自抢走输出”那一档）
        guard !desiredOutputDeviceUID.isEmpty, !applyingDesiredDevice,
              let unit = engine.outputNode.audioUnit,
              let want = OutputDevices.resolve(desiredOutputDeviceUID),
              OutputDevices.currentDeviceID(in: unit) != want.id else { return }
        applyingDesiredDevice = true
        defer { applyingDesiredDevice = false }
        if OutputDevices.setCurrentDevice(want.id, in: unit) == noErr {
            Diagnostics.log("输出设备按设置接回「\(want.name)」")
            renegotiateOutputChain()
        }
    }

    /// playerNode→eq 的连接格式决定 lastRenderTime 的时基。
    /// 一律按「输入数据的真实格式」连：节点里不做格式转换，渲染时钟的 1 tick 就等于 1 帧数据，
    /// 位置换算和 seek 才对得上；采样率变换交给后面的 mixer。
    private func connectPlayer(format: AVAudioFormat) {
        wireOutputIfNeeded()
        let key = "\(format.sampleRate)/\(format.channelCount)"
        guard key != connectionKey else { return }
        connectionKey = key
        if engine.isRunning {
            engine.stop()
            tapInstalled = false       // 引擎重启后按新格式重装频谱 tap
        }
        // 采样率变了：旧 tap 是按上一首的总线格式装的，留着会让 engine.start()
        // 在输出链初始化时以 -10868 收场；先把 tap 摘掉，起来后按新格式重接。
        engine.mainMixerNode.removeTap(onBus: 0)
        // 换了采样率/声道：整条 player→eq→fade→mainMixer 都要重新协商。
        // 只拆 playerNode 这侧的输出、留着 eq→fade→mainMixer 上次谈好的旧格式，
        // 再按新采样率起引擎会 -10868（AUGraph 输出链初始化：格式不支持）。
        // 过去只有 DSD 这类自制解码文件会走这条，迁移后所有文件都经
        // scheduleBuffer 喂节点，一次 44.1k→48k 的切换就会当场把它撞出来。
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(channelMixer)
        engine.disconnectNodeOutput(eq)
        engine.disconnectNodeOutput(fadeNode)
        outputWired = false
        // 一律经 channelMixer 再进 EQ：AVAudioMixerNode 会顺带把采样率降到输出链
        // 约定好的速率，而 AVAudioUnitEQ（AUNBandEQ）不会重采样——直接把 48k 喂给
        // eq 会在 engine.start() 报 -10868。FFmpegDecoder 已把声道归一到 ≤2，
        // mixer 这层现在主要兜重采样这一档（多声道降混也走同一口）。player 这侧
        // 仍按数据原格式连，lastRenderTime 的时基不变。
        engine.connect(playerNode, to: channelMixer, format: format)
        engine.connect(channelMixer, to: eq, format: nil)
        wireOutputIfNeeded()          // 用新格式重建 eq→fade→mainMixer
    }

    var duration: Double { isRadio ? 0 : songLength }

    var isPlaying: Bool { playerNode.isPlaying }

    /// 从头/暂停位置播放
    func play() {
        if isRadio {
            // 上一段淡出还没走完用户就按了播放：当场收尾，待办的换轨先落地。
            // 收尾可能已经把电台换成了本地文件（台 → 文件），那时它已经自己起播了，这里别再插手
            commitRadioFade()
            guard isRadio else { return }
            radioWantsPlay = true
            // 暂停过（流已断）或上次连不上：重新开一条，退避从第 0 次算起。
            // 问的是 RadioPlayer 而不是缓存的 radioState：后者从队列异步转过来，
            // 暂停后立刻按播放时可能还停在「直播中」，那样既不重连也不出声
            let live = radio.snapshotState()
            radioState = live
            switch live {
            case .idle, .failed:
                if let url = radio.currentURL { radio.open(url) }
            default:
                break
            }
            // 格式已经到手就直接开声；还没到就挂着，等 attachRadioFormat 接到格式
            // 再起引擎——图没画完时 start() 会失败
            if let pending = pendingRadioFormat {
                pendingRadioFormat = nil
                attachRadioFormat(pending)
            } else if radioFormat != nil {
                startRadioPlayback()
            }
            return
        }
        guard decoder != nil else { return }
        tryStartEngine()
        // 上一首是电台时淡出把音量压到了 0：文件这一侧也要抬回来，不然切过去是静音
        openRadioFade()
        let token = scheduleToken + 1
        scheduleToken = token
        playerNode.stop()
        playerNode.play()
        streamAnchorRender = playerNode.lastRenderTime?.sampleTime ?? 0
        pausedSnapshot = -1
        // 本段已播完（如在结尾处暂停后又按播放）：回到段起点，避免调度零帧后卡住
        if baseSample >= rangeEndFrame { baseSample = rangeStartFrame }
        seedStream(from: baseSample)
        startDecoding(token: token)
    }

    /// 暂停：记录位置快照（暂停期间渲染时钟仍会前进，不能直接读取）
    func pause() {
        commitRadioFade()
        if isRadio {
            // 电台没有“接着放”：断流，恢复时重连（直播本来就该听当下的）
            radioElapsed = currentTime
            radioBaseTime = nil
            // 暂停期间不能再“自动开声”：广告段切码流会重新报格式，
            // 要是还标记着“想放”，attachRadioFormat 会把引擎和节点又拉起来
            radioWantsPlay = false
            radioStarted = false
            radio.pause()
            // 同步复位状态：不然紧跟一次的 play() 会读到旧的「直播中」而不重连
            radioState = .idle
            // stop 而不是 pause：排着的最多 3 s 旧音频得清掉，直播不补放暂停期间的内容。
            // 被取消的缓冲不会再回调递减计数，这里自己归零，否则恢复后新块全被背压挡掉。
            // 归零之前先把它淡到静音：时基已经在上面当场冻结，淡出的 120 ms 不算在听感时间里
            fadeOutRadioBuffer(reason: "暂停")
            onRadioState?(.idle)
            return
        }
        guard playerNode.isPlaying else { return }
        pausedSnapshot = positionFrames
        // 恢复播放时以该位置为新的调度起点，否则会从头重新调度
        baseSample = pausedSnapshot
        scheduleToken += 1
        disarmEndWatch()
        playerNode.pause()
    }

    /// 完全停止（回到本段起点，不释放已加载的文件）
    func stop() {
        commitRadioFade()
        if isRadio {
            radioElapsed = 0
            radioBaseTime = nil
            radioWantsPlay = false
            radioStarted = false
            // 同样先淡再断：`playerNode.stop()` 换成淡完之后由尾巴执行
            fadeOutRadioBuffer(reason: "停止")
            radio.stop()
            radioState = .idle
            return
        }
        scheduleToken += 1
        disarmEndWatch()
        playerNode.stop()
        cancelDecoding()
        dropStream(keepPrefetch: true)   // 停止不动播放上下文：重新按播放时下一曲照样接得上
        baseSample = rangeStartFrame
        pausedSnapshot = -1
    }

    /// 卸掉当前曲目，回到「刚建出来」的样子。与 `stop()` 的区别就是 `stop()` 故意留着
    /// 已加载的文件（停止后还能从头播）；恢复现场前必须连 decoder、区间、时长一起清掉，
    /// 否则「上一首的残值」会被当成当前曲目信息报出去（自检里模拟重启要靠它）
    func unload() {
        stopRadio()
        commitRadioFade()
        scheduleToken += 1
        disarmEndWatch()
        playerNode.stop()
        cancelDecoding()
        dropStream()
        decoder = nil
        decodeFormat = nil
        songLength = 0
        rangeStartFrame = 0
        rangeEndFrame = 0
        baseSample = 0
        currentKey = ""
        fileURL = nil
        pausedSnapshot = -1
    }

    /// 跳转到本段内的秒数（CUE 分轨的 0 是段起点，不是镜像开头）
    func seek(seconds: Double) {
        guard !isRadio else { return }        // 直播流不能往回跳
        guard decoder != nil else { return }
        let offset = Int64(min(max(seconds, 0), songLength) * fileSampleRate)
        let target = min(rangeStartFrame + offset, rangeEndFrame)
        let wasPlaying = playerNode.isPlaying
        scheduleToken += 1
        disarmEndWatch()
        playerNode.stop()
        cancelDecoding()
        dropStream(keepPrefetch: true)   // 跳的是本曲里的位置，下一曲的预取照样有用
        baseSample = target
        pausedSnapshot = wasPlaying ? -1 : target
        if wasPlaying { play() }
    }

    /// 当前播放位置（秒，相对本段起点）
    var currentTime: Double {
        if isRadio {
            // 直播没有“总长”，但“已经听了多久”仍然成立：累计到暂停前的量 + 本次渲染时钟
            guard playerNode.isPlaying,
                  let base = radioBaseTime,
                  let rt = playerNode.lastRenderTime, rt.isSampleTimeValid else { return radioElapsed }
            return radioElapsed + Double(rt.sampleTime - base) / fileSampleRate
        }
        return Double(positionFrames - rangeStartFrame) / fileSampleRate
    }

    private var positionFrames: Int64 {
        let lastFrame = rangeEndFrame      // 段尾已在 load() 里夹到文件范围内，不再看 file.length
        if pausedSnapshot >= 0 {
            return min(pausedSnapshot, lastFrame)
        }
        if playerNode.isPlaying, let rt = playerNode.lastRenderTime, rt.isSampleTimeValid {
            // 从排期流换算：交接前后都只看「流里走到第几个」，不拿上一曲的锚去减
            let pos = frameInStream(rt.sampleTime - streamAnchorRender)
            return min(max(pos, rangeStartFrame), lastFrame)
        }
        return min(max(baseSample, rangeStartFrame), lastFrame)
    }

    /// 启动引擎并在运行后安装频谱 tap
    private func tryStartEngine() {
        guard !startingEngine else { return }
        startingEngine = true
        defer { startingEngine = false }
        // eq → mainMixer 必须先接上：图里没有通往输出的连线时 start() 会卡在等设备
        //（电台首帧还没到时这种情况很常见：格式要等流里解出来才知道）
        wireOutputIfNeeded()
        if !engine.isRunning {
            do {
                try engine.start()
                installSpectrumTapIfNeeded()
            } catch {
                Diagnostics.error("音频引擎启动失败 \(error)")
            }
        } else {
            installSpectrumTapIfNeeded()
        }
    }

    // MARK: - 自带解码器送数

    /// 起一次解码：代数加一（旧循环自己退出），记住本轮代号，从排期流当前要喂的那一段按窗口送数
    private func startDecoding(token: Int) {
        guard decoder != nil, decodeFormat != nil else { return }
        let gen = bumpGeneration()
        activeGen = gen
        activeToken = token
        decodeQueue.async { [weak self] in
            guard let self, gen == self.generation else { return }
            self.decodeInFlight = 0
            self.fillDecodeWindow(generation: gen, token: token)
        }
    }

    /// 作废正在进行的解码；已经排进节点的块由 playerNode.stop() 一起冲掉
    private func cancelDecoding() {
        _ = bumpGeneration()
    }

    private func bumpGeneration() -> Int {
        decodeLock.lock()
        decodeGeneration += 1
        let g = decodeGeneration
        decodeLock.unlock()
        return g
    }

    private var generation: Int {
        decodeLock.lock()
        defer { decodeLock.unlock() }
        return decodeGeneration
    }

    /// 在 decodeQueue 上跑：把窗口填满。每块被节点取走后由完成回调回来续一块，
    /// 所以内存里同时最多只有 decodeWindow 块 PCM（约 256KB），整曲从不全部解码。
    /// 只喂排期流的**最后一段**：前面那段的声音已经在节点队列里，不该再碰它的解码器
    private func fillDecodeWindow(generation gen: Int, token: Int) {
        while gen == generation, decodeInFlight < Self.decodeWindow {
            streamLock.lock()
            let tail = feed.last
            streamLock.unlock()
            guard let seg = tail else { return }
            if seg.nextFrame >= seg.endFrame {
                // 本段全交给节点了：接得上下一曲就接（不碰节点），接不上就当这段到头
                streamLock.lock()
                let joined = feed.count == 1 ? joinedFeed(after: feed[0]) : nil
                if let joined { feed.append(joined) }
                streamLock.unlock()
                if joined == nil { break }
                continue
            }
            let frames = min(Self.decodeChunkFrames, seg.endFrame - seg.nextFrame)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: seg.format,
                                                frameCapacity: AVAudioFrameCount(frames)) else { return }
            let got = seg.decoder.read(into: buffer, frames: AVAudioFrameCount(frames),
                                       from: seg.nextFrame)
            // 解这一块期间用户 seek / 换曲了：节点已经被冲干净，这块再排进去就是抢跑
            guard gen == generation else { return }
            guard got > 0 else {
                truncateTail(of: seg)     // 解不出来了（坏块/文件比 duration 短）：收尾到真实位置
                armEnd(token: token)
                return
            }
            buffer.frameLength = got
            if seg.gain != 1 { Self.applyGain(seg.gain, to: buffer) }
            streamLock.lock()
            if let i = feed.firstIndex(where: { $0.seq == seg.seq }) {
                feed[i].nextFrame += Int64(got)
                feed[i].scheduled += Int64(got)
            }
            streamLock.unlock()
            decodeInFlight += 1
            playerNode.scheduleBuffer(buffer, at: nil, options: [],
                                      completionCallbackType: .dataConsumed) { [weak self] _ in
                guard let self else { return }
                self.decodeQueue.async {
                    self.decodeInFlight -= 1
                    self.fillDecodeWindow(generation: gen, token: token)
                }
            }
        }
        // 窗口没满且已经排到流尾 = 本轮数据全交给节点了，剩下的交给结束监视计时器。
        // 排期流里接着第二段时也要把计时器立起来：接缝（交接）就挂在这条计时器上，
        // 而「本段只剩 0.2 s、下一段还有一整曲要排」时流尾永远排不满——一 seek 到曲尾
        // 就变成「接上了但没人看守」，接缝永远不报（实测 4 s 内交接次数为 0）
        streamLock.lock()
        let drained = feed.last.map { $0.nextFrame >= $0.endFrame } ?? false
        let seamPending = feed.count > 1
        streamLock.unlock()
        if gen == generation, drained || (seamPending && playerNode.isPlaying) {
            armEnd(token: token)
        }
    }

    /// 排完最后一块：把结束 token 立起来，计时器等到渲染时钟跑到段尾就报自然结束
    private func armEnd(token: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.scheduleToken == token else { return }
            self.endToken = self.scheduleToken
            self.startEndWatchTimerIfNeeded()
        }
    }

    // MARK: - 输出设备（F07）
    //
    // 只改 AUHAL 的 `kAudioOutputUnitProperty_CurrentDevice`：本进程往哪台设备出声由它说了算，
    // 系统默认设备、别的应用都不受影响（实测：切完之后系统默认仍是原来那台）。
    // 麻烦在于「换设备 = 换硬件格式」：采样率、声道数都可能变，混音链是按旧设备谈好的格式
    // 连到输出节点的，不重谈一次 `engine.start()` 会以「格式不合法」收场（实测 -10875）。
    // 所以这里必须先停 IO、拆链、重连，再按现场恢复——播放现场本身不在这里存。

    /// 音频引擎此刻在不在跑（自检要看「切完设备是否真的重新出声」，不能只看函数返回成没成）
    var audioEngineRunning: Bool { engine.isRunning }

    /// 当前实际在出声的设备（AUHAL 报的，不是系统默认报的）。输出链还没建起来时为 nil
    var outputDevice: OutputDevices.Device? {
        guard outputWired, let unit = engine.outputNode.audioUnit,
              let id = OutputDevices.currentDeviceID(in: unit) else { return nil }
        return OutputDevices.device(id)
    }

    /// 当前实际输出设备的 UID（没接输出链时为空串）
    var outputDeviceUID: String { outputDevice?.uid ?? "" }

    /// 用户选定的设备（空串 = 跟随系统默认）。只记成功应用过的：对账时拿它跟
    /// `outputDeviceUID` 比，不一致就说明「设置与实际脱开了」（睡了一觉、设备被拔走）
    private(set) var desiredOutputDeviceUID = ""
    /// 接线时补设备的那一步不许递归回去重谈格式
    private var applyingDesiredDevice = false

    /// 启动恢复：只记下用户选过哪台，等输出链第一次接起来时按它谈，
    /// 不为了一台还没出声的设备提前付建输出节点那 130 ms（见 wireOutputIfNeeded）
    func restoreOutputDevice(uid: String) {
        desiredOutputDeviceUID = uid
        if outputWired { _ = setOutputDevice(uid: uid) }
    }

    /// 把输出接到指定设备（空串 = 跟随系统默认）。返回 nil 是成功，否则是一句人话原因。
    ///
    /// 保留的东西：当前曲目、进度、待播队列与预取、EQ（在 eq 节点上）、音量与静音
    /// （在 mainMixer 上）——它们都不属于输出设备这一层，拆链重连碰不到。
    /// 电台没有「接着放」：换设备只能把已经排进节点的几秒冲掉，接着听当下的（跟切台一个路子）。
    @discardableResult
    func setOutputDevice(uid: String) -> String? {
        wireOutputIfNeeded()
        guard let unit = engine.outputNode.audioUnit else {
            return "音频输出节点还没建立，切不了输出设备"
        }
        let target: OutputDevices.Device
        if uid.isEmpty {
            guard let d = OutputDevices.systemDefault() else {
                return "系统里没找到可用的默认输出设备"
            }
            target = d
        } else if let d = OutputDevices.resolve(uid) {
            target = d
        } else {
            return "这台输出设备当前不可用（可能已拔出），请另选一台"
        }
        guard OutputDevices.currentDeviceID(in: unit) != target.id else {
            desiredOutputDeviceUID = uid
            return nil
        }

        // 现场快照：进度换算成秒，播与不播以节点为准（暂停时 playerNode.isPlaying 已是 false）
        let position = isRadio ? radioElapsed : currentTime
        let wasPlaying = !isRadio && playerNode.isPlaying
        let radioWanted = isRadio && radioWantsPlay
        playerNode.stop()
        cancelDecoding()
        if isRadio { radioStarted = false; radioPendingFrames = 0; radioBaseTime = nil }
        engine.stop()

        // 先把「期望」写成新的：下面重谈输出链时 `wireOutputIfNeeded` 会照这个值补设备，
        // 留在成功之后才写，从 A 切到 B 的那一轮它就会把 AUHAL 又按回 A（实测：第二次
        // 切换后读回来还是第一台，界面却已经报了成功）
        let previousDesired = desiredOutputDeviceUID
        desiredOutputDeviceUID = uid
        let status = OutputDevices.setCurrentDevice(target.id, in: unit)
        // 写成功不等于真接上了：读回一次才算数（设备中途又拔了就会在这里拦下来）
        let applied = OutputDevices.currentDeviceID(in: unit) == target.id
        renegotiateOutputChain()
        resumeAfterDeviceChange(radioWanted: radioWanted, wasPlaying: wasPlaying, position: position)
        guard status == noErr, applied else {
            // 没换成就把期望退回原样：留着一个实际没接上的期望，之后每次接线都会白试一遍
            desiredOutputDeviceUID = previousDesired
            let reason = "切到「\(target.name)」没成功（CoreAudio \(status)），声音仍走原来的输出设备"
            Diagnostics.error(reason)
            return reason
        }
        Diagnostics.log("输出设备 → 「\(target.name)」")
        return nil
    }

    /// 不换设备、只把输出链重谈一遍并按现场恢复出声。
    /// 睡了一觉之后引擎停了、设备被系统换掉了都走这一条（setOutputDevice 拿它复用）
    @discardableResult
    func restartOutputChain() -> String {
        let position = isRadio ? radioElapsed : currentTime
        let wasPlaying = !isRadio && playerNode.isPlaying
        let radioWanted = isRadio && radioWantsPlay
        playerNode.stop()
        cancelDecoding()
        if isRadio { radioStarted = false; radioPendingFrames = 0; radioBaseTime = nil }
        engine.stop()
        renegotiateOutputChain()
        resumeAfterDeviceChange(radioWanted: radioWanted, wasPlaying: wasPlaying, position: position)
        return wasPlaying || radioWanted
            ? "已重建输出链并从 \(TimeFormat.clock(position)) 续播" : "已重建输出链（本来就没在播）"
    }

    /// 换完设备（或退回原设备）之后把声音接回去
    private func resumeAfterDeviceChange(radioWanted: Bool, wasPlaying: Bool, position: Double) {
        if isRadio {
            // 流一直在收，只是节点被冲掉了：重新拉起引擎开闸，新到的 PCM 就往新设备排
            if radioWanted { startRadioPlayback() }
            return
        }
        guard wasPlaying, decoder != nil else { return }
        // seek 这条老路已经把「停节点、清排期、从指定帧重新起流、顺带起引擎」都管好了，
        // 但它那句「在播就重新起流」问的是节点此刻的状态，而换设备早就把节点停了：
        // 只 seek 会把现场停在暂停态（实测：界面写着播放中、engine 却没跑、一声不响），
        // 所以补一次 play()，它按 seek 落好的 baseSample 接着放
        seek(seconds: position)
        play()
    }

    /// 换设备后重谈输出链：整条 player→mixer→eq→fade→mainMixer 全拆，按新设备的格式重连。
    /// 源侧格式（`decodeFormat`/`radioFormat`）一个字不改：采样率适配交给混音链，
    /// 既不要求独占，也不去动设备的硬件采样率
    private func renegotiateOutputChain() {
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(channelMixer)
        engine.disconnectNodeOutput(eq)
        engine.disconnectNodeOutput(fadeNode)
        outputWired = false
        connectionKey = ""
        tapInstalled = false
        if let fmt = decodeFormat ?? radioFormat {
            connectPlayer(format: fmt)
        } else {
            wireOutputIfNeeded()
        }
    }

    // MARK: - 频谱 tap

    private var tapInstalled = false

    /// 优先用混音器当前输出格式；不可用时回退到标准 44.1kHz/立体声 float
    private func installSpectrumTapIfNeeded() {
        guard !tapInstalled else { return }
        wireOutputIfNeeded()
        let block: (AVAudioPCMBuffer, AVAudioTime) -> Void = { [weak self] buf, _ in
            self?.spectrum.process(buffer: buf)
        }
        // 静音自检下把 tap 挪到 fadeNode（音量推子上游）：mainMixer.outputVolume 锁到 0 后，
        // 同位 tap 会读到 0，无法验证引擎真的推了声音
        let tapNode: AVAudioNode = silentOutput ? fadeNode : engine.mainMixerNode
        let out = tapNode.outputFormat(forBus: 0)
        let candidates: [AVAudioFormat?] = [
            out.sampleRate > 0 ? out : nil,
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false),
            nil,
        ]
        for fmt in candidates {
            tapNode.removeTap(onBus: 0)
            if let fmt {
                tapNode.installTap(onBus: 0, bufferSize: 1024, format: fmt, block: block)
            } else {
                tapNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: block)
            }
            tapInstalled = true
            return
        }
    }

    /// 结束监视：scheduleSegment 回调可能早于实际听感结束（缓冲余量），
    /// 而节点排期数据放完后 isPlaying 依然是 true（只有 pause/stop 会改它），
    /// 所以以“渲染时钟走到本段终点”为准——CUE 分轨尤其依赖这条，否则会播穿到镜像下一轨。
    private func startEndWatchTimerIfNeeded() {
        guard endWatchTimer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.endToken == self.scheduleToken, self.scheduleToken >= 0 else {
                self.disarmEndWatch()
                return
            }
            if !self.playerNode.isPlaying {
                self.disarmEndWatch()
                self.onPlaybackFinished?()
                return
            }
            // 无缝交接：本段听完了、后面还接着一段——只把排期流往前挪一格，不报「播完了」
            if self.handoverIfNeeded() { return }
            if self.reachedStreamEnd {
                self.disarmEndWatch()
                self.onPlaybackFinished?()
            }
        }
        t.tolerance = 0.04
        RunLoop.main.add(t, forMode: .common)
        endWatchTimer = t
    }

    private func disarmEndWatch() {
        endToken = -1
        endWatchTimer?.invalidate()
        endWatchTimer = nil
    }

    // MARK: - 音量

    func setVolume(_ v: Float, mute: Bool) {
        volume = max(0, min(1, v))
        muted = mute
        // 图还没接起来时只记数值：先去碰 mainMixerNode 等于把输出节点提前建出来
        guard outputWired else { return }
        engine.mainMixerNode.outputVolume = silentOutput ? 0 : (mute ? 0 : volume)
    }

    // MARK: - 均衡器

    func setEQEnabled(_ enabled: Bool) {
        eq.bypass = !enabled
    }

    func setEQGain(band: Int, gain: Float) {
        guard eq.bands.indices.contains(band) else { return }
        eq.bands[band].gain = max(-12, min(12, gain))
    }

    func eqGain(band: Int) -> Float {
        eq.bands.indices.contains(band) ? eq.bands[band].gain : 0
    }

    /// 前置放大（dB）：皮肤均衡器左侧的旋钮
    func setPreGain(_ db: Float) {
        eq.globalGain = max(-12, min(12, db))
    }

    var preGain: Float { eq.globalGain }

    // MARK: - 自检取流
    // 有些断言只能看数据：恢复到的位置是不是真对上了音频内容、两曲衔接处有没有缺帧，
    // 光看 `currentTime` 与布尔值都证不了。这里在 playerNode 的输出上抄一份真实排给
    // 音频图的 PCM（tap 只读不改，摘掉就恢复原样），与频谱那条 mainMixer/fadeNode 的 tap 不冲突。

    private let captureLock = NSLock()
    private var captureSink: ((AVAudioPCMBuffer) -> Void)?

    /// 现在真排进音频图的块是什么格式（自检参照用，没连过时为 nil）。
    /// 取流钩子与自检的采样率口径必须走同一个表达式：拿上一次装 tap 时记下的格式去算音高，
    /// 44.1 kHz 之后接 96 kHz 就会把 880 Hz 算成 404 Hz（实测：自检量到「有声但音高不对」）
    var playerConnectionFormat: AVAudioFormat? {
        let fmt = decodeFormat ?? radioFormat ?? playerNode.outputFormat(forBus: 0)
        return fmt.sampleRate > 0 ? fmt : nil
    }

    /// 在 fadeNode（电台淡出与睡眠淡出都落在这层，用户音量再往下）上挂一个临时 tap。
    /// 自检凭它证明「定时到点前那十秒真的把输出链路压下去了」，而不是只改了一个数值。
    /// tap 只读不改；静音自检下频谱用的也是 fadeNode 这一条总线，所以取流期间顶掉它，
    /// 收尾时再按原样装回去（见 `endFadeCapture`）
    private var fadeSink: ((AVAudioPCMBuffer) -> Void)?

    func beginFadeCapture(_ sink: @escaping (AVAudioPCMBuffer) -> Void) {
        wireOutputIfNeeded()
        fadeSink = sink
        let out = fadeNode.outputFormat(forBus: 0)
        let fmt = out.sampleRate > 0 ? out
            : AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                            channels: 2, interleaved: false)
        fadeNode.removeTap(onBus: 0)
        fadeNode.installTap(onBus: 0, bufferSize: 4_096, format: fmt) { [weak self] buf, _ in
            self?.fadeSink?(buf)
        }
    }

    /// 摘掉 fadeNode 上的 tap。静音自检下频谱的 tap 本来也挂在这一层、刚被顶掉了，
    /// 这里要把它补回来：不然取流之后频谱就一直是静音读数（`tapInstalled` 还写着 true，
    /// 下一次 `start()` 也不会重装）
    func endFadeCapture() {
        fadeNode.removeTap(onBus: 0)
        fadeSink = nil
        if silentOutput {
            tapInstalled = false
            installSpectrumTapIfNeeded()
        }
    }

    /// 装上取流钩子：每块排给音频图的 PCM 都会回调一次（音频线程，实现自己加锁）
    func beginCapture(_ sink: @escaping (AVAudioPCMBuffer) -> Void) {
        captureLock.lock()
        captureSink = sink
        captureLock.unlock()
        guard let fmt = playerConnectionFormat else { return }
        playerNode.installTap(onBus: 0, bufferSize: 4_096, format: fmt) { [weak self] buf, _ in
            guard let self else { return }
            self.captureLock.lock()
            let s = self.captureSink
            self.captureLock.unlock()
            s?(buf)
        }
    }

    /// 取流结束：摘 tap，后续块不再上报
    func endCapture() {
        playerNode.removeTap(onBus: 0)
        captureLock.lock()
        captureSink = nil
        captureLock.unlock()
    }
}
