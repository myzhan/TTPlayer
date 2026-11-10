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
    private var baseSample: Int64 = 0          // 当前调度段的起始帧
    private var baseRenderTime: Int64 = 0      // play() 时刻的渲染器采样时间
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
    /// 下一个要解的帧、已排进节点但还没被取走的块数（只在 decodeQueue 上读写）
    private var decodeNextFrame: Int64 = 0
    private var decodeInFlight = 0
    /// 一块多少帧：8192 ≈ 186ms@44.1k，4 块约 0.7 秒的预取量
    private static let decodeChunkFrames: Int64 = 8_192
    private static let decodeWindow = 4

    /// 自然播放结束（在主线程回调）
    var onPlaybackFinished: (() -> Void)?

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
    /// 用户按了播放，但流的格式还没解出来：格式一到就起引擎开声（见 attachRadioFormat）
    private var radioWantsPlay = false
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
    /// fadeNode 当前音量（新流真起播了才抬回 1）
    var radioFadeVolume: Float { outputWired ? fadeNode.outputVolume : 1 }

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

    /// 加载文件（不自动播放）；from/to 是 CUE 分轨在镜像里的起止秒，to 为 nil 则放到文件结尾
    func load(url: URL, from: Double = 0, to: Double? = nil) throws {
        // 切回本地文件：电台会话要彻底断掉，否则它会继续往节点里塞流
        stopRadio()
        scheduleToken += 1
        disarmEndWatch()
        playerNode.stop()
        cancelDecoding()
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
        fadeNode.outputVolume = g
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
        fadeNode.outputVolume = 1
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
        if key != connectionKey {
            radioFormat = format
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
        let frames = Int64(buffer.frameLength)
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.radioPendingFrames -= frames }
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
        baseRenderTime = playerNode.lastRenderTime?.sampleTime ?? 0
        pausedSnapshot = -1
        // 本段已播完（如在结尾处暂停后又按播放）：回到段起点，避免调度零帧后卡住
        if baseSample >= rangeEndFrame { baseSample = rangeStartFrame }
        startDecoding(from: baseSample, token: token)
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
        baseSample = rangeStartFrame
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
            let pos = rt.sampleTime - baseRenderTime + baseSample
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

    /// 起一次解码：代数加一（旧循环自己退出），再从 frame 开始按窗口送数
    private func startDecoding(from frame: Int64, token: Int) {
        guard decoder != nil, decodeFormat != nil else { return }
        let gen = bumpGeneration()
        decodeQueue.async { [weak self] in
            guard let self, gen == self.generation else { return }
            self.decodeNextFrame = frame
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

    /// 在 decodeQueue 上跑：把窗口填满。每块被节点取走后由完成回调回来再续一块，
    /// 所以内存里同时最多只有 decodeWindow 块 PCM（约 256KB），整曲从不全部解码
    private func fillDecodeWindow(generation gen: Int, token: Int) {
        while gen == generation,
              decodeInFlight < Self.decodeWindow,
              decodeNextFrame < rangeEndFrame {
            guard let decoder, let format = decodeFormat else { return }
            let frames = min(Self.decodeChunkFrames, rangeEndFrame - decodeNextFrame)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(frames)) else { return }
            let got = decoder.read(into: buffer, frames: AVAudioFrameCount(frames),
                                   from: decodeNextFrame)
            guard got > 0 else {
                armEnd(token: token)        // 解不出来了（坏块/文件尾）：当作本段结束
                return
            }
            buffer.frameLength = got
            decodeNextFrame += Int64(got)
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
        // 窗口没满且已经排到段尾 = 本段数据全交给节点了，剩下的交给结束监视计时器
        if gen == generation, decodeNextFrame >= rangeEndFrame {
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
            if !self.playerNode.isPlaying || self.positionFrames >= self.rangeEndFrame {
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
}
