import AppKit

// MARK: - 显示面板：深蓝灰玻璃大槽，上层歌名/状态，中层封面 + 频谱，底层音量/传输键/文字键
// （照经典皮肤：标题条写程序名，曲目信息全在显示区里；
//  时间读数已去掉，播放进度由下方整行进度条承担）

final class DisplayPanelView: NSView {
    let spectrumView: SpectrumView
    private let well = WellView()
    private let songMarquee = MarqueeLabel()
    private let channelField = NSTextField(labelWithString: "立体声")
    private let statusField = NSTextField(labelWithString: "状态: 停止")
    private let codecField = NSTextField(labelWithString: "")
    /// 主显示区的歌词两行（F10）：只念控制层查出来的那一行，查行的时间轴与歌词秀共用
    private let lyricField = NSTextField(labelWithString: "")
    private let lyricNextField = NSTextField(labelWithString: "")
    private let coverView = CoverView()
    private let bottomStrip = GradientView()
    private let volumeWell = VolumeWellView()
    private let muteButton: TTButton
    let listButton: TTButton
    let eqButton: TTButton
    let lyricButton: TTButton
    /// 传输键：与音量/时间同一行，贴在一起的一整条玻璃带
    private let transportBar = SegmentedGlassBar(frame: .zero)
    private let stopButton: TTButton
    private let prevButton: TTButton
    private let playButton: TTButton
    private let nextButton: TTButton
    private let modeButton: TTButton

    private let controller = PlayerController.shared
    /// 回指主面板控制器（列表/均衡器/歌词三个文字键要用）
    weak var owner: MainWindowController?

    init(analyzer: SpectrumAnalyzer) {
        spectrumView = SpectrumView(analyzer: analyzer)
        muteButton = TTButton(.symbol("speaker.wave.2.fill"), target: nil, action: #selector(muteAction),
                              size: NSSize(width: 24, height: 20), face: .glass)
        // 三个文字键跟参考皮肤一样是浅玻璃凸起键（深字），不是半透明的扁平文字
        listButton = TTButton(.title("列表"), target: nil, action: #selector(listAction),
                              size: NSSize(width: 34, height: 20), face: .glass)
        eqButton = TTButton(.title("均衡器"), target: nil, action: #selector(eqAction),
                            size: NSSize(width: 42, height: 20), face: .glass)
        lyricButton = TTButton(.title("歌词"), target: nil, action: #selector(lyricAction),
                               size: NSSize(width: 34, height: 20), face: .glass)
        stopButton = TTButton(.symbol("stop.fill"), target: nil, action: #selector(stopAction))
        prevButton = TTButton(.symbol("backward.end.fill"), target: nil, action: #selector(prevAction))
        playButton = TTButton(.symbol("play.fill"), target: nil, action: #selector(togglePlayAction))
        nextButton = TTButton(.symbol("forward.end.fill"), target: nil, action: #selector(nextAction))
        modeButton = TTButton(.symbol("arrow.right"), target: nil, action: #selector(modeAction))
        super.init(frame: .zero)

        well.cornerRadius = 5
        well.dark = false
        well.translatesAutoresizingMaskIntoConstraints = false
        addSubview(well)

        // 频谱铺满槽的中部，作为背景层（截图里没有独立频谱区）
        spectrumView.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(spectrumView)

        songMarquee.font = Theme.titleFont
        songMarquee.textColor = Theme.textPrimary
        songMarquee.symbolName = nil
        channelField.font = Theme.smallFont
        channelField.textColor = Theme.textAccent
        channelField.alignment = .right
        statusField.font = Theme.smallFont
        statusField.textColor = Theme.textSecondary
        statusField.alignment = .right
        codecField.font = Theme.tinyFont
        codecField.textColor = Theme.textSecondary
        codecField.lineBreakMode = .byTruncatingTail
        codecField.alignment = .right
        // 当前行比下一行重一档，跟歌词秀一个道理：眼睛先落在要唱的那句上
        lyricField.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        lyricField.textColor = Theme.textPrimary
        lyricField.lineBreakMode = .byTruncatingTail
        lyricNextField.font = Theme.smallFont
        lyricNextField.textColor = Theme.textSecondary
        lyricNextField.lineBreakMode = .byTruncatingTail

        coverView.cornerRadius = 3

        for v in [songMarquee, channelField, statusField, codecField, lyricField, lyricNextField,
                  coverView, bottomStrip] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        well.addSubview(songMarquee)
        well.addSubview(channelField)
        well.addSubview(statusField)
        well.addSubview(codecField)
        well.addSubview(lyricField)
        well.addSubview(lyricNextField)
        well.addSubview(coverView)

        // 底部条：更深的玻璃条，装音量、传输键、三个文字键
        bottomStrip.colors = [NSColor.hex(0x2E4157), NSColor.hex(0x3E5470)]
        bottomStrip.cornerRadius = 4
        bottomStrip.glassBody = true
        bottomStrip.glassAlphaOverride = GlassStyle.wellAlpha
        bottomStrip.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(bottomStrip)

        volumeWell.target = self
        volumeWell.action = #selector(volumeAction(_:))
        volumeWell.value = Double(controller.volume)
        volumeWell.isMuted = controller.isMuted
        // 三个面板键和静音键一样必须接上 target：只给 action 的话
        // NSApp.sendAction 会去响应链里找一个不存在的方法，点了等于没点
        for b in [muteButton, listButton, eqButton, lyricButton] { b.target = self }

        for v in [volumeWell, muteButton, listButton, eqButton, lyricButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bottomStrip.addSubview(v)
        }

        // 传输键本体不画底，底由 transportBar 整条画（渐变 + 格间 1px 分界线）
        playButton.glyphScale = 0.68
        transportBar.translatesAutoresizingMaskIntoConstraints = false
        bottomStrip.addSubview(transportBar)
        for b in [stopButton, prevButton, playButton, nextButton, modeButton] {
            b.target = self
            b.face = .none
            b.cornerRadius = 2
            b.translatesAutoresizingMaskIntoConstraints = false
            transportBar.addSubview(b)
        }
        stopButton.toolTip = "停止"
        prevButton.toolTip = "上一曲（←）"
        playButton.toolTip = "播放/暂停（空格）"
        nextButton.toolTip = "下一曲（→）"
        // 音量滑条让位：空间不够时先缩短滑条（56...132），保证传输键不被顶出右边界
        let volumeIdeal = volumeWell.widthAnchor.constraint(equalToConstant: 132)
        volumeIdeal.priority = .defaultHigh
        let transportH = MainWindowController.transportH
        let cellTop = transportBar.topAnchor
        let cellBottom = transportBar.bottomAnchor

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: MainWindowController.displayH),

            well.topAnchor.constraint(equalTo: topAnchor),
            well.leadingAnchor.constraint(equalTo: leadingAnchor),
            well.trailingAnchor.constraint(equalTo: trailingAnchor),
            well.bottomAnchor.constraint(equalTo: bottomAnchor),

            songMarquee.topAnchor.constraint(equalTo: well.topAnchor, constant: 5),
            songMarquee.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 6),
            songMarquee.trailingAnchor.constraint(equalTo: channelField.leadingAnchor, constant: -8),
            songMarquee.heightAnchor.constraint(equalToConstant: 20),

            channelField.topAnchor.constraint(equalTo: songMarquee.topAnchor),
            channelField.heightAnchor.constraint(equalToConstant: 20),
            channelField.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -8),
            channelField.widthAnchor.constraint(equalToConstant: 76),

            statusField.topAnchor.constraint(equalTo: songMarquee.bottomAnchor, constant: 2),
            statusField.trailingAnchor.constraint(equalTo: channelField.trailingAnchor),
            statusField.heightAnchor.constraint(equalToConstant: 18),
            statusField.widthAnchor.constraint(equalToConstant: 150),

            codecField.topAnchor.constraint(equalTo: statusField.bottomAnchor, constant: 2),
            codecField.trailingAnchor.constraint(equalTo: channelField.trailingAnchor),
            codecField.heightAnchor.constraint(equalToConstant: 16),
            codecField.widthAnchor.constraint(equalToConstant: 190),

            // 歌词两行就填在封面右侧、状态/格式那两列左侧那块空档里（不新加高度，
            // 窄窗时先截尾，传输键那一行不受影响）
            lyricField.topAnchor.constraint(equalTo: statusField.topAnchor),
            lyricField.leadingAnchor.constraint(equalTo: coverView.trailingAnchor, constant: 10),
            lyricField.trailingAnchor.constraint(equalTo: statusField.leadingAnchor, constant: -8),
            lyricField.heightAnchor.constraint(equalToConstant: 18),

            lyricNextField.topAnchor.constraint(equalTo: codecField.topAnchor),
            lyricNextField.leadingAnchor.constraint(equalTo: lyricField.leadingAnchor),
            lyricNextField.trailingAnchor.constraint(equalTo: codecField.leadingAnchor, constant: -8),
            lyricNextField.heightAnchor.constraint(equalToConstant: 16),

            coverView.topAnchor.constraint(equalTo: songMarquee.bottomAnchor, constant: 6),
            coverView.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 8),
            coverView.widthAnchor.constraint(equalToConstant: 56),
            coverView.heightAnchor.constraint(equalToConstant: 56),

            // 频谱带：避开右上角的文字栏，排在封面右侧、底部条上方
            spectrumView.topAnchor.constraint(equalTo: codecField.bottomAnchor, constant: 4),
            spectrumView.leadingAnchor.constraint(equalTo: coverView.trailingAnchor, constant: 8),
            spectrumView.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -8),
            spectrumView.bottomAnchor.constraint(equalTo: bottomStrip.topAnchor, constant: -4),

            bottomStrip.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 4),
            bottomStrip.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -4),
            bottomStrip.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -4),
            bottomStrip.heightAnchor.constraint(equalToConstant: 26),

            volumeWell.leadingAnchor.constraint(equalTo: bottomStrip.leadingAnchor, constant: 4),
            volumeWell.centerYAnchor.constraint(equalTo: bottomStrip.centerYAnchor),
            volumeIdeal,
            volumeWell.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
            volumeWell.heightAnchor.constraint(equalToConstant: 20),

            muteButton.leadingAnchor.constraint(equalTo: volumeWell.trailingAnchor, constant: 3),
            muteButton.centerYAnchor.constraint(equalTo: bottomStrip.centerYAnchor),
            // 这一行的四个键必须钉宽：自绘按钮的固有尺寸优先级只有 250，
            // 不钉住的话窄窗时会被求解器挤成一条缝（而音量槽反而不让位）
            muteButton.widthAnchor.constraint(equalToConstant: 24),
            listButton.widthAnchor.constraint(equalToConstant: 34),
            eqButton.widthAnchor.constraint(equalToConstant: 42),
            lyricButton.widthAnchor.constraint(equalToConstant: 34),

            lyricButton.trailingAnchor.constraint(equalTo: bottomStrip.trailingAnchor, constant: -4),
            lyricButton.centerYAnchor.constraint(equalTo: bottomStrip.centerYAnchor),
            eqButton.trailingAnchor.constraint(equalTo: lyricButton.leadingAnchor, constant: -2),
            eqButton.centerYAnchor.constraint(equalTo: bottomStrip.centerYAnchor),
            listButton.trailingAnchor.constraint(equalTo: eqButton.leadingAnchor, constant: -2),
            listButton.centerYAnchor.constraint(equalTo: bottomStrip.centerYAnchor),

            // 传输带：紧跟静音键（时间 LED 已去掉），右边界不得碰到「列表」键
            transportBar.centerYAnchor.constraint(equalTo: bottomStrip.centerYAnchor),
            transportBar.leadingAnchor.constraint(equalTo: muteButton.trailingAnchor, constant: 5),
            transportBar.heightAnchor.constraint(equalToConstant: transportH),
            transportBar.trailingAnchor.constraint(lessThanOrEqualTo: listButton.leadingAnchor,
                                                  constant: -6),

            stopButton.topAnchor.constraint(equalTo: cellTop, constant: 1),
            stopButton.bottomAnchor.constraint(equalTo: cellBottom, constant: -1),
            stopButton.leadingAnchor.constraint(equalTo: transportBar.leadingAnchor, constant: 1),
            stopButton.widthAnchor.constraint(equalToConstant: 26),

            prevButton.topAnchor.constraint(equalTo: stopButton.topAnchor),
            prevButton.bottomAnchor.constraint(equalTo: stopButton.bottomAnchor),
            prevButton.leadingAnchor.constraint(equalTo: stopButton.trailingAnchor),
            prevButton.widthAnchor.constraint(equalToConstant: 30),

            playButton.topAnchor.constraint(equalTo: stopButton.topAnchor),
            playButton.bottomAnchor.constraint(equalTo: stopButton.bottomAnchor),
            playButton.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 38),

            nextButton.topAnchor.constraint(equalTo: stopButton.topAnchor),
            nextButton.bottomAnchor.constraint(equalTo: stopButton.bottomAnchor),
            nextButton.leadingAnchor.constraint(equalTo: playButton.trailingAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 30),

            modeButton.topAnchor.constraint(equalTo: stopButton.topAnchor),
            modeButton.bottomAnchor.constraint(equalTo: stopButton.bottomAnchor),
            modeButton.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor),
            modeButton.widthAnchor.constraint(equalToConstant: 26),
            modeButton.trailingAnchor.constraint(equalTo: transportBar.trailingAnchor, constant: -1),
        ])

        subscribe()
        refreshTrack()
        refreshState()
        updateModeButton()
    }

    /// 供自检/外部读取音量显示
    var volumeValue: Double { volumeWell.value }
    /// 供自检：传输键按 x 排序（都在同一条玻璃带里）
    var transportKeys: [TTButton] {
        transportBar.subviews.compactMap { $0 as? TTButton }
            .sorted { $0.frame.minX < $1.frame.minX }
    }
    /// 供自检：传输键所在的连续玻璃带
    var transportStrip: NSView { transportBar }
    /// 供自检：传输带左侧的锚点（静音键）与音量滑条，验证同一行且中间不再夹时间读数
    var muteView: NSView { muteButton }
    var volumeView: NSView { volumeWell }
    /// 供自检：显示区那行说明文字（格式信息 / 放不起来的原因 / 未入表提示 / 未播放提示都走它）
    var noteText: String { codecField.stringValue }
    /// 供自检：状态那一行（播放/暂停/直播 + 睡眠定时器的剩余时间缀在后面，F09）
    var statusText: String { statusField.stringValue }
    /// 供自检：主显示区那两行歌词（与歌词秀走同一份校准结果，两处必须一模一样）
    var lyricText: String { lyricField.stringValue }
    var lyricNextText: String { lyricNextField.stringValue }
    /// 供自检：显示区左上贴的是当前曲目的封面（而不是占位光盘）
    var showsTrackCover: Bool { coverView.showsCoverImage && coverView.image === controller.currentTrack?.cover }
    /// 点封面弹大图窗（由主面板控制器决定开哪个窗）
    var onCoverClick: (() -> Void)? {
        didSet { coverView.onClick = onCoverClick }
    }
    /// 主面板把标题栏字幕复用为显示区歌名
    var marqueeLabel: MarqueeLabel { songMarquee }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func subscribe() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(trackChanged(_:)), name: .ttTrackChanged, object: nil)
        nc.addObserver(self, selector: #selector(playStateChanged(_:)), name: .ttPlaybackStateChanged, object: nil)
        nc.addObserver(self, selector: #selector(volumeChanged(_:)), name: .ttVolumeChanged, object: nil)
        nc.addObserver(self, selector: #selector(modeChanged(_:)), name: .ttPlayModeChanged, object: nil)
        // 列表变化也要刷新：从存档恢复出曲目但还没播放时，只跟 ttTrackChanged 会让
        // 显示区停在“拖入文件开始播放”上
        nc.addObserver(self, selector: #selector(playlistChanged), name: .ttPlaylistChanged, object: nil)
        // 电台状态/正在播变化：格式行与状态字都要跟着变
        nc.addObserver(self, selector: #selector(radioChanged(_:)), name: .ttRadioChanged, object: nil)
        // 输出设备换了/拔了：那一行要说为什么没声（F07）
        nc.addObserver(self, selector: #selector(outputChanged(_:)), name: .ttOutputChanged, object: nil)
        // 睡眠定时器走了一格：状态行后缀的剩余时间要跟着跳（F09）
        nc.addObserver(self, selector: #selector(sleepChanged(_:)), name: .ttSleepChanged, object: nil)
        // 歌词行换了（包括查行被校准量扳回去那一档）：主显示区跟着说一句（F10）
        nc.addObserver(self, selector: #selector(lyricChanged(_:)), name: .ttLyricChanged, object: nil)
    }

    // MARK: - 状态

    @objc private func trackChanged(_ note: Notification) { refreshTrack() }
    @objc private func playlistChanged() { refreshTrack() }
    @objc private func radioChanged(_ note: Notification) {
        refreshTrack()
        refreshState()
    }

    private func refreshTrack() {
        // 设备层面的问题优先于格式信息：这时候放不出声，先回答为何没声（完整原因悬在 tooltip）
        let outputIssue = controller.outputProblem
        if let problem = outputIssue {
            codecField.stringValue = "输出：" + Self.brief(problem)
            codecField.toolTip = problem
        } else {
            codecField.toolTip = nil
        }
        guard let track = controller.currentTrack else {
            // 没有当前曲：封面格自己画占位光盘，不再摆 SF Symbol
            coverView.image = nil
            if outputIssue == nil { codecField.stringValue = idleHint }
            songMarquee.text = "千千静听 复刻版"
            return
        }
        coverView.image = track.cover
        if outputIssue == nil {
            if let problem = controller.playbackProblem {
                // 这一行本来放格式信息，播不动的时候改成说人话（完整原因在属性面板）
                codecField.stringValue = "放不了：" + Self.brief(problem)
            } else if track.isRadio {
                // 电台：参数由流里报，后面跟一句直播状态（正在连接/直播中/重连中）
                let sr = track.sampleRate > 0 ? String(format: " %.1fk", track.sampleRate / 1000) : ""
                let head = track.bitRateKbps > 0 ? "\(track.formatLabel) \(track.bitRateKbps)k" : track.formatLabel
                codecField.stringValue = "\(head)\(sr) · \(controller.radioStateText)"
            } else {
                let sr = track.sampleRate > 0 ? String(format: "%.1fk", track.sampleRate / 1000) : ""
                codecField.stringValue = "\(track.formatLabel) \(track.bitRateKbps)k · \(sr) · "
                    + (track.channels == 2 ? "立体声" : "\(track.channels)声道")
            }
        }
        // 电台真在唱时，“正在播”的歌名比台名更有用；两个都写上
        if track.isRadio, !controller.radioNowPlaying.isEmpty {
            songMarquee.text = "\(track.title) · \(controller.radioNowPlaying)"
        } else {
            let head = track.artist.isEmpty ? track.title : "\(track.artist) - \(track.title)"
            songMarquee.text = head
        }
    }

    /// 未播放时的提示：列表里已有曲目就不能再让用户“拖文件”
    private var idleHint: String {
        // 拖进来的东西被挡在门外时先回答“为什么列表没动静”
        if let problem = controller.lastImportProblem { return "未入表：" + Self.brief(problem) }
        let pl = controller.playlist
        guard !pl.isEmpty else { return "拖入文件开始播放" }
        return "已载入 \(pl.count) 首"
    }

    /// 长原因在窄窄的一行里放不下：只留第一段，末尾补省略号
    private static func brief(_ text: String, limit: Int = 18) -> String {
        let head = text.components(separatedBy: "；").first ?? text
        guard head.count > limit else { return head }
        return String(head.prefix(limit)) + "…"
    }

    @objc private func playStateChanged(_ note: Notification) { refreshState() }

    /// 输出设备变化：重画那一行（拔了要说不可用，接回来/换了要把那句说出去的话收回来）
    @objc private func outputChanged(_ note: Notification) { refreshTrack() }

    /// 定时器变化：只有状态行那一截后缀要重算，格式行不跟着动
    @objc private func sleepChanged(_ note: Notification) { refreshState() }

    /// 歌词行：控制层已经按校准后的时间轴查好了，这里只负责念，不再算一次
    @objc private func lyricChanged(_ note: Notification) {
        let info = note.userInfo ?? [:]
        pendingLine = (info["line"] as? String) ?? ""
        pendingNext = (info["next"] as? String) ?? ""
        applyLyricLine()
        lyricField.toolTip = PlayerController.shared.lyricShiftDetail
    }

    private var pendingLine = ""
    private var pendingNext = ""
    /// 一次性说明的代号：新的歌词行一到就把它推一把，旧的那份定时回来也盖不上现在
    private var lyricFlashToken = 0

    private func applyLyricLine() {
        lyricFlashToken += 1
        lyricField.stringValue = pendingLine
        lyricNextField.stringValue = pendingNext
    }

    /// 快捷键按下去的答复落在这一行歌词上：歌词秀没开时也要有个地方说话，
    /// 三秒后回到歌词本身（期间来了新的歌词行就以新的为准）
    func flashLyricNote(_ text: String) {
        lyricFlashToken += 1
        let token = lyricFlashToken
        lyricField.stringValue = text
        lyricNextField.stringValue = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.lyricFlashToken == token else { return }
            self.applyLyricLine()
        }
    }

    private func refreshState() {
        let playing = controller.isPlaying
        // 电台的“播放”就是直播：没有进度可言，用直播/停播两个字才不让人误会
        if controller.isRadio {
            statusField.stringValue = "状态: " + (playing ? "直播" : "停止")
        } else {
            statusField.stringValue = "状态: "
                + (playing ? "播放" : (controller.currentTrack == nil ? "停止" : "暂停"))
        }
        playButton.content = .symbol(playing ? "pause.fill" : "play.fill")
        // 睡眠定时器设着就缀一句（F09）：「剩 12:34」或「播完停」。
        // 完整那句（等哪一首、淡出开没开）悬在 tooltip 与属性面板里，窄窄一行放不下
        if let hint = controller.sleepMenuHint {
            statusField.stringValue += " \(hint)"
            statusField.toolTip = controller.sleepDetailText
        } else {
            statusField.toolTip = controller.sleepNote
        }
        if playing {
            spectrumView.startAnimating()
        } else {
            spectrumView.stopAnimating()
        }
        refreshPanelLits()
    }

    @objc private func volumeChanged(_ note: Notification) {
        let v = (note.userInfo?["volume"] as? Float) ?? 0.8
        let muted = (note.userInfo?["muted"] as? Bool) ?? false
        volumeWell.value = Double(v)
        volumeWell.isMuted = muted
        muteButton.content = .symbol(muted || v == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
        muteButton.lit = muted
    }

    @objc private func volumeAction(_ sender: VolumeWellView) {
        controller.setVolume(Float(sender.value))
    }

    @objc private func muteAction() { controller.toggleMute() }
    @objc private func listAction() { owner?.togglePlaylist() }
    @objc private func eqAction() { owner?.toggleEQPanel() }
    @objc private func lyricAction() { owner?.toggleLyricWindow() }

    // MARK: - 传输键

    @objc private func stopAction() { controller.stop() }
    @objc private func prevAction() { controller.previous() }
    @objc private func nextAction() { controller.next() }
    @objc private func togglePlayAction() { controller.togglePlay() }
    @objc private func modeAction() { controller.cycleMode() }

    @objc private func modeChanged(_ note: Notification) { updateModeButton() }

    /// 模式键用常规图标（顺序/单曲循环/列表循环/随机），非默认模式时点亮
    private func updateModeButton() {
        let mode = controller.playMode
        modeButton.content = .symbol(mode.symbolName)
        modeButton.toolTip = "播放方式：\(mode.displayName)（F1~F4）"
        modeButton.lit = mode != .order
    }

    /// 三个面板键的点亮状态跟着对应面板的显隐走（不是均衡器 DSP 开关）
    func refreshPanelLits() {
        listButton.lit = owner?.listVisible ?? true
        eqButton.lit = owner?.eqVisible ?? false
        lyricButton.lit = owner?.lyricVisible ?? false
    }
}

// MARK: - 控制条：整行细进度条
// （传输键已上移到显示区底部条，与音量/时间同一行，这一行只剩进度）

/// 只负责拖动进度：播放/暂停等五个键在 DisplayPanelView 的底部条里
final class ControlBarView: NSView {
    private let controller = PlayerController.shared

    private let slider = TimeSlider(frame: .zero)

    init() {
        super.init(frame: .zero)

        slider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slider)
        slider.target = self
        slider.action = #selector(sliderAction)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: MainWindowController.controlH),

            slider.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            slider.heightAnchor.constraint(equalToConstant: 14),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(timeUpdated(_:)),
                                               name: .ttTimeUpdated, object: nil)
    }

    /// 供自检读取进度槽位置（0...1）
    var progressValue: Double { slider.secondsValue }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func timeUpdated(_ note: Notification) {
        // 电台是直播：没有总长可除，进度条回零（拖动也无效，engine.seek 自己会挡）
        if controller.isRadio {
            slider.setProgress(0)
            return
        }
        guard let info = note.userInfo,
              let t = info["time"] as? Double,
              let d = info["duration"] as? Double, d > 0 else { return }
        slider.setProgress(t / d)
    }

    @objc private func sliderAction() {
        controller.seek(to: slider.secondsValue * controller.duration)
    }
}
