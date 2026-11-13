import AppKit

/// 主面板窗口：内容高度由皮肤层级决定，交给停靠组排布
final class MainPanelWindow: SkinPanelWindow {
    override var contentHeight: CGFloat { MainWindowController.mainPanelH }
}

/// 主面板控制器：标题条 → 显示区（含传输键一行）→ 整行进度条，作为停靠组的第一块窗
/// 播放列表、均衡器各是独立无边框窗，由 SkinDock 竖排吸附、同宽、整体拖动
final class MainWindowController: NSObject {
    // MARK: - 皮肤尺寸常量（默认 compactWidth 宽；三窗竖排）
    static let titleBarH: CGFloat = 22
    static let displayH: CGFloat = 150
    /// 控制条：只剩整行细进度条（传输键已并入显示区底部条）
    static let controlH: CGFloat = 18
    /// 传输键/音量条里小控件的高度
    static let transportH: CGFloat = 22
    /// 标题条高度（只剩封面大图窗在用：列表/均衡器/歌词已去掉标题条）
    static let panelHeaderH: CGFloat = 26
    static let compactWidth: CGFloat = 480
    /// 显示区底部一行要放下「音量 + 静音 + 五个传输键 + 三个文字键」，再窄就会互相顶住
    /// （时间读数去掉后释放了 ~100pt，默认档跟着收紧）
    static let minWidth: CGFloat = 420
    /// 皮肤布局版本：每次改版（宽度、面板划分）递增，旧存档的几何不再适用
    static let skinLayoutVersion = 6

    /// 主面板整块高度（停靠组用）：含 skinRoot 顶部 4pt 内边距，
    /// 必须与 buildTitleBar 里那组 required 约束的拟合高度一致，否则布局时冲突
    static var mainPanelH: CGFloat {
        4 + titleBarH + 2 + displayH + 4 + controlH + 6
    }
    /// 播放列表面板高度
    static let playlistPanelH: CGFloat = 280
    /// 均衡器面板高度
    static let eqPanelH: CGFloat = 178
    /// 待播队列面板高度（独立窗，不进停靠组）
    static let queuePanelH: CGFloat = QueuePanelController.defaultHeight

    let window: MainPanelWindow
    let displayPanel: DisplayPanelView
    let controlBar: ControlBarView
    let playlistPanel: PlaylistPanelController
    let eqPanel: EQPanelController
    let dock: SkinDock

    /// 主面板皮肤根视图（标题栏/显示区/控制条都挂在上面）
    var skinRoot: GradientView { window.skinRoot }
    var playlistView: PlaylistView { playlistPanel.playlistView }
    /// 标题栏字幕（与显示区歌名同一份）
    var marquee: MarqueeLabel { displayPanel.marqueeLabel }

    private(set) var titleBar = GradientView()
    private let titleLabel = NSTextField(labelWithString: "千千静听")
    private let modeBadge = NSTextField(labelWithString: "")
    /// 标题条的「菜单」键（视图层级自己持有，这里供自检确认菜单锚点）
    private(set) weak var titleMenuButton: NSButton?

    private let controller = PlayerController.shared
    private(set) var lyricWindow: LyricWindow?
    private(set) var coverWindow: CoverWindow?
    /// 待播队列面板（F03）：第一次打开才建，之后反复开关复用同一个表格
    private(set) var queuePanel: QueuePanelController?

    var listVisible: Bool { dock.isVisible(.playlist) }
    var eqVisible: Bool { dock.isVisible(.equalizer) }
    /// 歌词秀不在停靠组里，显隐直接看窗口
    var lyricVisible: Bool { lyricWindow?.window.isVisible ?? false }
    /// 队列面板也不在停靠组里，同上
    var queueVisible: Bool { queuePanel?.panelVisible ?? false }

    override init() {
        let state = Self.migrateSkinLayout(LibraryStore.load())
        let width = Self.savedWidth(state: state, fallback: Self.compactWidth)
        // 玻璃开关必须在建窗口之前定下来：壳层与标题条是建窗时就装好风格的
        GlassStyle.setEnabled(state.glass)
        GlassStyle.setTransparency(CGFloat(state.transparency))
        window = MainPanelWindow(width: width, height: Self.mainPanelH, title: "千千静听")
        displayPanel = DisplayPanelView(analyzer: controller.engine.spectrum)
        controlBar = ControlBarView()
        playlistPanel = PlaylistPanelController(width: width)
        eqPanel = EQPanelController(width: width)
        dock = SkinDock(width: width, originTopLeft: Self.defaultTopLeft(width: width))
        super.init()

        // 不允许拉到最小宽以下：底部那一行控件宽度钉死，再窄就会互相顶住
        window.contentMinSize = NSSize(width: Self.minWidth, height: Self.mainPanelH)

        // 显示区/控制条必须先入视图层级：buildTitleBar 末尾会激活它们的约束，
        // 视图没有共同祖先时 AutoLayout 会抛异常（且被 AppKit 吞掉，启动静默中断）
        displayPanel.owner = self
        displayPanel.onCoverClick = { [weak self] in self?.toggleCoverWindow() }
        displayPanel.translatesAutoresizingMaskIntoConstraints = false
        window.skinRoot.addSubview(displayPanel)
        controlBar.translatesAutoresizingMaskIntoConstraints = false
        window.skinRoot.addSubview(controlBar)
        buildTitleBar()

        dock.register(.main, window, height: Self.mainPanelH, visible: true)
        dock.register(.playlist, playlistPanel.window, height: Self.playlistPanelH,
                      visible: state.listVisible)
        dock.register(.equalizer, eqPanel.window, height: Self.eqPanelH, visible: state.eqVisible)
        dock.onGeometryChanged = { [weak self] in
            guard let self else { return }
            // 歌词窗与停靠组同宽：拉宽/收窄主面板时一起跟着走（未打开时是空操作）
            self.lyricWindow?.matchWidth(self.dock.width)
            self.queuePanel?.matchWidth(self.dock.width)
            self.scheduleLayoutPersist()
        }
        // 列表面板工具条的「队列」键开独立窗：这里接回调，面板自己不认识主面板
        playlistPanel.onToggleQueue = { [weak self] in self?.toggleQueuePanel() }
        // 三键的 lit 要跟存档里的面板显隐一致（DisplayPanelView 建好时 owner 还没接上）
        displayPanel.refreshPanelLits()

        subscribe()
        restoreGeometry(state)
        Diagnostics.log("主面板就绪 \(Int(dock.width))×\(Int(Self.mainPanelH)) "
            + "列表=" + (listVisible ? "展开" : "折叠")
            + " 均衡器=" + (eqVisible ? "展开" : "折叠"))
    }

    // MARK: - 几何

    /// 皮肤改版后旧存档的宽度/位置（比如上一版默认 760 宽）直接丢弃，回到新默认档
    private static func migrateSkinLayout(_ state: AppState) -> AppState {
        var s = state
        guard s.skinLayout != skinLayoutVersion else { return s }
        s.skinLayout = skinLayoutVersion
        s.dockGeometry = ""
        s.windowFrame = ""
        // 歌词窗宽度改为跟停靠组走，旧存档里的绝对位置也没意义了：清掉让它第一次打开时贴到组下方
        s.lyricFrame = ""
        LibraryStore.save(s)
        return s
    }

    /// 旧版单窗存档只取宽度，位置由停靠组重新排
    private static func savedWidth(state: AppState, fallback: CGFloat) -> CGFloat {
        if !state.dockGeometry.isEmpty {
            let parts = state.dockGeometry.split(separator: ",").compactMap { Double($0) }
            if parts.count == 4, parts[2] >= SkinDock.minWidth {
                return CGFloat(parts[2])
            }
        }
        let parts = state.windowFrame.split(separator: ",").compactMap { Double($0) }
        if parts.count == 4, parts[2] >= SkinDock.minWidth {
            return CGFloat(parts[2])
        }
        return fallback
    }

    /// 默认位置：屏幕上方居中（左上角坐标，y 是组顶边）
    private static func defaultTopLeft(width: CGFloat) -> NSPoint {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let top = screen.maxY - 40
        return NSPoint(x: screen.midX - width / 2, y: top)
    }

    private func restoreGeometry(_ state: AppState) {
        if state.dockGeometry.isEmpty, !state.windowFrame.isEmpty,
           let old = rectFromString(state.windowFrame) {
            // 首次从单窗版本升级：沿用原来的位置当组左上角
            dock.originTopLeft = NSPoint(x: old.minX, y: old.maxY)
        }
        dock.restore(state.dockGeometry)
        dock.constrainToScreen()
    }

    func showWindow() {
        dock.showGroup()
        window.makeKeyAndOrderFront(nil)
        if listVisible { playlistPanel.window.orderFront(nil) }
        if eqVisible { eqPanel.window.orderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
        playlistView.scrollToCurrent()
    }

    /// 供持久化：停靠组几何 + 列表/EQ 开关
    func saveCurrentFrame() -> String { dock.geometryString }

    func persistWindowLayout() {
        var state = LibraryStore.load()
        state.dockGeometry = dock.geometryString
        state.listVisible = listVisible
        state.eqVisible = eqVisible
        state.glass = GlassStyle.enabled
        state.transparency = Double(GlassStyle.transparency)
        if let win = lyricWindow?.window {
            state.lyricFrame = rectString(win.frame)
        }
        // 兼容旧字段：主面板自身 frame
        state.windowFrame = rectString(window.frame)
        LibraryStore.save(state)
    }

    private func rectString(_ r: NSRect) -> String {
        "\(r.minX),\(r.minY),\(r.width),\(r.height)"
    }

    private func rectFromString(_ s: String) -> NSRect? {
        let parts = s.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    private var layoutSavePending: DispatchWorkItem?

    /// 拖动/拉伸每个事件都写盘太重，合并成 0.4s 后的一次
    private func scheduleLayoutPersist() {
        layoutSavePending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.persistWindowLayout() }
        layoutSavePending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    // MARK: - 标题条

    /// 标题条 = 图标 + 程序名 + 播放方式徽章 + 拖动区 + 菜单/最小化/关闭
    private func buildTitleBar() {
        titleBar.colors = [Theme.titleTop, Theme.titleBottom]
        titleBar.cornerRadius = 6
        titleBar.gloss = true
        titleBar.glassBody = true
        titleBar.wantsLayer = true
        titleBar.layer?.cornerRadius = 6
        titleBar.layer?.masksToBounds = true
        titleBar.translatesAutoresizingMaskIntoConstraints = false
        window.skinRoot.addSubview(titleBar)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: "千千静听")
        icon.contentTintColor = Theme.titleText
        icon.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = "千千静听"
        titleLabel.font = Theme.panelTitleFont
        titleLabel.textColor = Theme.titleText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        modeBadge.font = Theme.tinyFont
        modeBadge.textColor = Theme.titleText.withAlphaComponent(0.75)
        modeBadge.translatesAutoresizingMaskIntoConstraints = false

        let menuBtn = TTButton(.symbol("line.3.horizontal"), target: self, action: #selector(titleMenuAction(_:)),
                               size: NSSize(width: 22, height: 18))
        menuBtn.toolTip = "菜单"
        titleMenuButton = menuBtn
        let pinBtn = TTButton(.symbol("pin"), target: self, action: #selector(toggleLyricWindow),
                              size: NSSize(width: 22, height: 18))
        pinBtn.toolTip = "歌词秀（⌘L）"
        let miniBtn = TTButton(.symbol("minus"), target: self, action: #selector(miniaturizeAction),
                               size: NSSize(width: 22, height: 18))
        miniBtn.toolTip = "最小化（隐藏到后台，继续播放）"
        let closeBtn = TTButton(.symbol("xmark"), target: self, action: #selector(closeAction),
                                size: NSSize(width: 22, height: 18))
        closeBtn.toolTip = "关闭（退出程序）"

        let buttons = NSStackView(views: [menuBtn, pinBtn, miniBtn, closeBtn])
        buttons.orientation = .horizontal
        buttons.spacing = 3
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let dragArea = TitleBarDragView(frame: .zero)
        dragArea.translatesAutoresizingMaskIntoConstraints = false
        titleBar.addSubview(dragArea, positioned: .below, relativeTo: titleLabel)

        for v in [icon, titleLabel, modeBadge, buttons] as [NSView] {
            titleBar.addSubview(v)
        }

        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: window.skinRoot.topAnchor, constant: 4),
            titleBar.leadingAnchor.constraint(equalTo: window.skinRoot.leadingAnchor, constant: 6),
            titleBar.trailingAnchor.constraint(equalTo: window.skinRoot.trailingAnchor, constant: -6),
            titleBar.heightAnchor.constraint(equalToConstant: Self.titleBarH),

            icon.leadingAnchor.constraint(equalTo: titleBar.leadingAnchor, constant: 5),
            icon.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            titleLabel.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),

            modeBadge.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            modeBadge.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),

            buttons.trailingAnchor.constraint(equalTo: titleBar.trailingAnchor, constant: -5),
            buttons.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),

            dragArea.leadingAnchor.constraint(equalTo: modeBadge.trailingAnchor, constant: 8),
            dragArea.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -6),
            dragArea.topAnchor.constraint(equalTo: titleBar.topAnchor),
            dragArea.bottomAnchor.constraint(equalTo: titleBar.bottomAnchor),

            displayPanel.topAnchor.constraint(equalTo: titleBar.bottomAnchor, constant: 2),
            displayPanel.leadingAnchor.constraint(equalTo: window.skinRoot.leadingAnchor, constant: 6),
            displayPanel.trailingAnchor.constraint(equalTo: window.skinRoot.trailingAnchor, constant: -6),

            controlBar.topAnchor.constraint(equalTo: displayPanel.bottomAnchor, constant: 4),
            controlBar.leadingAnchor.constraint(equalTo: window.skinRoot.leadingAnchor, constant: 6),
            controlBar.trailingAnchor.constraint(equalTo: window.skinRoot.trailingAnchor, constant: -6),
            controlBar.bottomAnchor.constraint(equalTo: window.skinRoot.bottomAnchor, constant: -6),
        ])
        updateModeBadge()
    }

    // MARK: - 面板开关

    @objc func togglePlaylist() { setListVisible(!listVisible) }

    func setListVisible(_ on: Bool) {
        dock.setVisible(on, for: .playlist)
        displayPanel.refreshPanelLits()
        scheduleLayoutPersist()
        Diagnostics.log("列表\(on ? "展开" : "折叠")")
    }

    @objc func toggleEQPanel() { setEQVisible(!eqVisible) }

    /// 供自检：经均衡器面板（UI 同一条路径）改增益
    func setEQGainThroughUI(band: Int, gain: Float) {
        eqPanel.setBandGain(band, gain: gain)
    }

    func setEQVisible(_ on: Bool) {
        dock.setVisible(on, for: .equalizer)
        if on { eqPanel.showAndSync() }
        displayPanel.refreshPanelLits()
        scheduleLayoutPersist()
        Diagnostics.log("均衡器\(on ? "展开" : "折叠")")
    }

    // MARK: - 事件订阅

    private func subscribe() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(modeChanged(_:)), name: .ttPlayModeChanged, object: nil)
        nc.addObserver(self, selector: #selector(trackChanged(_:)), name: .ttTrackChanged, object: nil)
        nc.addObserver(self, selector: #selector(playStateChanged(_:)), name: .ttPlaybackStateChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func trackChanged(_ note: Notification) {
        let track = note.userInfo?["track"] as? Track
        window.title = track.map { "千千静听 - \($0.title)" } ?? "千千静听"
        updateModeBadge()
    }

    @objc private func playStateChanged(_ note: Notification) {
        displayPanel.refreshPanelLits()
        eqPanel.showAndSync()
    }

    @objc private func modeChanged(_ note: Notification) {
        updateModeBadge()
    }

    private func updateModeBadge() {
        modeBadge.stringValue = "[\(controller.playMode.displayName)]"
    }

    // MARK: - 窗口控制

    @objc private func closeAction() {
        // 用户要求：× = 直接退出进程，最小化 = 隐藏到后台
        NSApp.terminate(nil)
    }

    @objc private func miniaturizeAction() {
        // 隐藏整组到菜单栏，进程继续后台播放
        dock.hideGroup()
    }

    // MARK: - 附属窗口

    @objc func toggleLyricWindow() {
        if let win = lyricWindow, win.window.isVisible {
            // 标题条去掉后没有关闭键了，位置记忆必须在这条路径上落盘
            win.persistFrame()
            win.window.orderOut(nil)
            displayPanel.refreshPanelLits()
            return
        }
        if lyricWindow == nil {
            let lyric = LyricWindow(width: dock.width)
            // 第一次打开且没存档：贴在整组下方，同宽左对齐，上下叠成一块
            if !lyric.usedSavedFrame {
                lyric.placeBelow(groupLeft: dock.originTopLeft.x,
                                 groupBottom: dock.originTopLeft.y - dock.totalHeight)
            }
            lyricWindow = lyric
        }
        lyricWindow?.matchWidth(dock.width)
        lyricWindow?.showAndSync()
        displayPanel.refreshPanelLits()
    }

    /// 待播队列面板（F03）：工具条「队列」键与「菜单」里的同名项都走这里
    @objc func toggleQueuePanel() {
        if let panel = queuePanel, panel.panelVisible {
            panel.hide()
            return
        }
        if queuePanel == nil {
            let panel = QueuePanelController(width: dock.width)
            // 第一次开：贴在整组下方；歌词窗开着就往下再让一层，两块窗不会叠成一团
            var bottom = dock.originTopLeft.y - dock.totalHeight
            if let lyric = lyricWindow?.window, lyric.isVisible {
                bottom = min(bottom, lyric.frame.minY)
            }
            panel.placeBelow(groupLeft: dock.originTopLeft.x, groupBottom: bottom)
            queuePanel = panel
        }
        queuePanel?.matchWidth(dock.width)
        queuePanel?.show()
    }

    /// 封面大图窗：点显示区那一格封面就是它（也挂在菜单上）
    func toggleCoverWindow() {
        if coverWindow == nil { coverWindow = CoverWindow() }
        coverWindow?.toggle(near: window)
    }

    // MARK: - 弹出菜单（千千静听的“菜单”按钮）

    func showPopupMenu(under anchor: NSView) {
        // 菜单开在被点的那个键正下方（以前锚到整条标题条的左端，菜单会飞到最左边）
        buildPopupMenu().popUp(under: anchor)
    }

    /// 弹出菜单的全部内容。拆出来是给自检留的口子：菜单项与快捷键得能直接断言，
    /// 不能只靠「按了有反应」（F05 的搜索入口就在这份清单里）
    func buildPopupMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String = "",
                 _ mods: NSEvent.ModifierFlags = .command) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = self
        }
        add("添加文件…", #selector(addFiles), "o")
        add("添加文件夹…", #selector(addFolder), "O", [.command, .shift])
        add("添加网络电台…", #selector(addRadioStream), "")
        menu.addItem(.separator())
        add("播放/暂停", #selector(togglePlay), " ")
        add("停止", #selector(stopPlay))
        add("下一曲", #selector(playNext))
        add("上一曲", #selector(playPrev))
        add("加入/取消收藏", #selector(toggleFavorite), "d")
        add("搜索全部曲目…", #selector(focusSearch), "f")
        menu.addItem(.separator())
        for mode in PlayMode.allCases {
            let item = menu.addItem(withTitle: mode.displayName,
                                    action: #selector(selectMode(_:)), keyEquivalent: "")
            item.tag = mode.rawValue
            item.target = self
            item.state = controller.playMode == mode ? .on : .off
        }
        menu.addItem(.separator())
        // F06 的唯一开关：默认关。开了也只在上次退出前处于播放时才自动开播，
        // 手动停止过就再也不会自己响起来
        let resumeItem = menu.addItem(withTitle: "启动后自动继续播放",
                                      action: #selector(toggleAutoResume), keyEquivalent: "")
        resumeItem.target = self
        resumeItem.state = controller.autoResumePlay ? .on : .off
        resumeItem.toolTip = "重启后接着上次的曲目与进度；默认只恢复到暂停，上次确实在播才自动开播"
        // F01 的唯一开关：默认开。关掉就是「换曲必冲节点」的硬切，专辑中间会多一段空白
        let gaplessItem = menu.addItem(withTitle: "无缝播放（不插空白）",
                                       action: #selector(toggleGapless), keyEquivalent: "")
        gaplessItem.target = self
        gaplessItem.state = controller.gaplessPlay ? .on : .off
        gaplessItem.toolTip = "相邻两曲之间不重新拉起输出：同采样率的本地音频与同镜像相邻分轨直接接上"
        // F02 响度均衡：模式三选一 + 峰值防削波 + 前置增益滑块。默认关闭，
        // 因为它会改掉母带之间的相对响度，不能像无缝那样默默默认开起来
        for mode in ReplayGainMode.allCases {
            let item = menu.addItem(withTitle: mode.displayName,
                                    action: #selector(selectReplayGainMode(_:)), keyEquivalent: "")
            item.tag = mode.rawValue
            item.target = self
            item.state = controller.replayGainMode == mode ? .on : .off
            item.toolTip = mode.toolTip
        }
        let peakItem = menu.addItem(withTitle: "峰值防削波（按标签 Peak 限制）",
                                    action: #selector(toggleReplayPeakLimit), keyEquivalent: "")
        peakItem.target = self
        peakItem.state = controller.replayGainPeakLimit ? .on : .off
        peakItem.toolTip = "只拿 ReplayGain 与前置增益的合成值限制到满量程以内；"
            + "均衡器把某个频段推高引起的削波抵消不了"
        // 前置增益滑块：与透明度滑块一样嵌在菜单里，拖动实时生效不关菜单
        let gainItem = NSMenuItem()
        let gainView = GainSliderView(decibels: controller.replayGainPreamp)
        gainView.onChange = { [weak self] v in self?.controller.setReplayGainPreamp(v) }
        gainItem.view = gainView
        menu.addItem(gainItem)
        menu.addItem(.separator())
        // F07 输出设备：子菜单里列可用设备，顶上那一行说清「现在真在往哪台出声」
        menu.addItem(buildOutputDeviceItem())
        // F08 媒体库：目录清单与扫描入口都在这一支（左栏那一页只负责看）
        menu.addItem(buildLibraryItem())
        // F09 睡眠定时器：到点要停的是什么、还剩多久，都得在菜单里看得见
        menu.addItem(buildSleepTimerItem())
        // F10 歌词时间校准：当前偏了多少、能不能调，菜单里就要说出来
        menu.addItem(buildLyricShiftItem())
        let listItem = menu.addItem(withTitle: "显示播放列表", action: #selector(togglePlaylist), keyEquivalent: "1")
        listItem.keyEquivalentModifierMask = .command
        listItem.target = self
        listItem.state = listVisible ? .on : .off
        let eqItem = menu.addItem(withTitle: "显示均衡器", action: #selector(openEQ), keyEquivalent: "e")
        eqItem.keyEquivalentModifierMask = .command
        eqItem.target = self
        eqItem.state = eqVisible ? .on : .off
        let lyricItem = menu.addItem(withTitle: "歌词秀", action: #selector(openLyric), keyEquivalent: "l")
        lyricItem.keyEquivalentModifierMask = .command
        lyricItem.target = self
        lyricItem.state = (lyricWindow?.window.isVisible ?? false) ? .on : .off
        let queueItem = menu.addItem(withTitle: "待播队列", action: #selector(toggleQueuePanel),
                                     keyEquivalent: "")
        queueItem.target = self
        queueItem.state = queueVisible ? .on : .off
        let coverItem = menu.addItem(withTitle: "专辑封面", action: #selector(openCover), keyEquivalent: "")
        coverItem.target = self
        coverItem.state = (coverWindow?.isVisible ?? false) ? .on : .off
        let glassItem = menu.addItem(withTitle: "半透明玻璃", action: #selector(toggleGlass), keyEquivalent: "")
        glassItem.target = self
        glassItem.state = GlassStyle.enabled ? .on : .off
        // 透明度滑块：放在“半透明玻璃”下面，拖完实时生效
        let sliderItem = NSMenuItem()
        let sliderView = TransparencySliderView(value: Float(GlassStyle.transparency))
        sliderView.onChange = { [weak self] v in
            GlassStyle.setTransparency(CGFloat(v))
            self?.persistWindowLayout()
        }
        sliderItem.view = sliderView
        menu.addItem(sliderItem)
        menu.addItem(.separator())
        add("属性…", #selector(showProps))
        add("清空播放列表", #selector(clearList))
        add("退出千千静听", #selector(quitApp), "q")
        return menu
    }

    @objc private func titleMenuAction(_ sender: NSButton) {
        showPopupMenu(under: sender)
    }

    /// 「启动后自动继续播放」开关（菜单项与自检都走这一条，不另开内部口子）
    @objc func toggleAutoResume() {
        controller.setAutoResumePlay(!controller.autoResumePlay)
    }

    /// 「无缝播放」开关（菜单项与自检都走这一条）
    @objc func toggleGapless() {
        controller.setGaplessPlay(!controller.gaplessPlay)
    }

    /// 响度均衡模式（菜单项与自检都走这一条）
    @objc func selectReplayGainMode(_ sender: NSMenuItem) {
        controller.setReplayGainMode(ReplayGainMode(rawValue: sender.tag) ?? .off)
    }

    /// 峰值防削波开关
    @objc func toggleReplayPeakLimit() {
        controller.setReplayGainPeakLimit(!controller.replayGainPeakLimit)
    }

    /// 输出设备子菜单。拆成单独一个函数是给自检留口子：菜单项与勾都得能直接断言
    func buildOutputDeviceItem() -> NSMenuItem {
        let item = NSMenuItem(title: "输出设备", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "输出设备")
        // 第一行不参与选择，只回答「现在真在往哪台出声」（需求：明确显示当前实际输出设备）
        let actual = NSMenuItem(title: "当前实际输出：\(controller.outputDeviceNameText)",
                                action: nil, keyEquivalent: "")
        actual.toolTip = controller.outputDeviceSummary
        sub.addItem(actual)
        sub.addItem(.separator())
        let follow = NSMenuItem(title: "跟随系统默认", action: #selector(selectOutputDevice(_:)),
                                keyEquivalent: "")
        follow.target = self
        follow.state = controller.outputDeviceUID.isEmpty ? .on : .off
        follow.toolTip = "系统默认换了就跟着换；已固定到某台设备时不抢输出"
        sub.addItem(follow)
        let devices = controller.availableOutputDevices
        if devices.isEmpty {
            // 一台能出声的都没找到：空状态也要说人话，不能只给一个光秃秃的「跟随系统默认」
            let none = NSMenuItem(title: "没找到可用的输出设备", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        let defaultUID = OutputDevices.systemDefault()?.uid
        for d in devices {
            let row = NSMenuItem(title: d.name, action: #selector(selectOutputDevice(_:)),
                                 keyEquivalent: "")
            row.target = self
            row.representedObject = d.uid
            row.state = controller.outputDeviceUID == d.uid ? .on : .off
            var tip = "\(d.channels) 声道"
            let rates = OutputDevices.ratesSummary(d)
            if !rates.isEmpty { tip += "·支持 " + rates }
            if d.uid == defaultUID { tip += "·系统默认" }
            row.toolTip = tip
            sub.addItem(row)
        }
        item.submenu = sub
        return item
    }

    /// 选输出设备（菜单项与自检都走这一条）：切不动时响一声，原因由控制层写到显示区与属性面板
    @objc func selectOutputDevice(_ sender: NSMenuItem) {
        let uid = (sender.representedObject as? String) ?? ""
        if let reason = controller.setOutputDevice(uid: uid) {
            NSSound.beep()
            Diagnostics.error("输出设备没改成：\(reason)")
        }
    }

    /// 睡眠定时器子菜单（F09）。拆成单独函数同样是为了自检能直接断言：
    /// 哪一档打了勾、「播完当前曲」在电台下为什么给不出、「取消定时」何时才可点
    func buildSleepTimerItem() -> NSMenuItem {
        let item = NSMenuItem(title: "睡眠定时器", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "睡眠定时器")
        sub.autoenablesItems = false
        let timer = controller.sleepTimer
        // 第一行不参与选择，只回话：正在倒计时就报剩余，等播完就报等哪一首
        let status = NSMenuItem(title: timer.isArmed ? controller.sleepStatusText : "未设置定时",
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        sub.addItem(status)
        // 上一轮怎么收场的（到点/取消/被拒）留在菜单里，只看一眼状态行不会错过
        if let note = controller.sleepNote, !timer.isArmed {
            let row = NSMenuItem(title: "上一次：\(note)", action: nil, keyEquivalent: "")
            row.isEnabled = false
            sub.addItem(row)
        }
        sub.addItem(.separator())
        for m in SleepTimer.presets {
            let row = NSMenuItem(title: "\(m) 分钟后停止", action: #selector(selectSleepMinutes(_:)),
                                 keyEquivalent: "")
            row.target = self
            row.tag = m
            row.state = timer.minutes == m ? .on : .off
            sub.addItem(row)
        }
        let custom = NSMenuItem(title: "自定义分钟数…", action: #selector(setSleepCustom), keyEquivalent: "")
        custom.target = self
        custom.toolTip = "只收正整数（上限 \(SleepTimer.maxMinutes / 1_440) 天）"
        sub.addItem(custom)
        let oneTrack = NSMenuItem(title: "播完当前曲后停止", action: #selector(setSleepAfterTrack),
                                  keyEquivalent: "")
        oneTrack.target = self
        oneTrack.state = timer.waitingTrack ? .on : .off
        // 电台那一档点了会被挡下并说清为什么（比直接置灰多一句人话）
        oneTrack.toolTip = controller.isRadio
            ? "现在是电台：无限流没有「播完」的时刻，只能用按分钟那一档"
            : "绑定设定时这一刻的那一条：单曲循环也在本轮结束时停下；手动跳曲或停止就算取消"
        sub.addItem(oneTrack)
        let cancel = NSMenuItem(title: "取消定时", action: #selector(cancelSleepTimer), keyEquivalent: "")
        cancel.target = self
        cancel.isEnabled = timer.isArmed
        sub.addItem(cancel)
        sub.addItem(.separator())
        let fade = NSMenuItem(title: "到点前 \(Int(PlayerController.sleepFadeSeconds)) 秒淡出",
                              action: #selector(toggleSleepFade), keyEquivalent: "")
        fade.target = self
        fade.state = controller.sleepFadeEnabled ? .on : .off
        fade.toolTip = "关掉就是当场硬停（听感上是一个台阶）；淡出只加在输出链路上，不动你的音量与静音设置"
        sub.addItem(fade)
        item.submenu = sub
        return item
    }

    /// 选预设档位（菜单项与自检共用）
    @objc func selectSleepMinutes(_ sender: NSMenuItem) {
        showSleepProblem(controller.setSleepMinutes(sender.tag))
    }

    @objc func setSleepAfterTrack() {
        showSleepProblem(controller.setSleepAfterCurrentTrack())
    }

    @objc func cancelSleepTimer() {
        controller.cancelSleepTimer("已取消睡眠定时器")
    }

    @objc func toggleSleepFade() {
        controller.setSleepFadeEnabled(!controller.sleepFadeEnabled)
    }

    /// 自定义那一档：开框问分钟数（自检不走这一步，它直接给 `applyCustomSleepMinutes` 喂字符串）
    @objc func setSleepCustom() {
        guard let text = promptSleepMinutes() else { return }   // 按了取消：什么都没设过
        showSleepProblem(controller.applyCustomSleepMinutes(text))
    }

    /// 被挡下的原因给一个模态框：倒计时这种事一旦没设成，默默留在菜单里没人会去翻
    private func showSleepProblem(_ error: String?) {
        guard let error else { return }
        let alert = NSAlert()
        alert.messageText = "睡眠定时器"
        alert.informativeText = error
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    /// 问一个分钟数：取消返回 nil，填了非法值也往下走，由控制层挡下并给原因
    private func promptSleepMinutes() -> String? {
        let alert = NSAlert()
        alert.messageText = "自定义定时分钟数"
        alert.informativeText = "从设定这一刻起按真实经过时间倒计时：暂停、合盖休眠都算在内，"
            + "改系统时间不会把它拉长。只收 1 到 \(SleepTimer.maxMinutes / 1_440) 天之间的正整数。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "分钟数（正整数）"
        field.stringValue = "90"
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// 歌词时间校准子菜单（F10）。同样拆成单独函数给自检留口子：当前偏移那句、
    /// 三项能不能点、快捷键挂没挂在菜单上，都要能直接断言
    func buildLyricShiftItem() -> NSMenuItem {
        let item = NSMenuItem(title: "歌词时间校准", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "歌词时间校准")
        sub.autoenablesItems = false
        let applies = controller.lyricShiftApplies
        // 第一行不参与选择，只回答「现在这一曲偏了多少」；不能调时它就是说原因的那一句
        let status = NSMenuItem(title: applies ? "当前：\(controller.lyricShiftText)"
                                               : (controller.lyricShiftProblem ?? "没有歌词可校准"),
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.toolTip = controller.lyricShiftDetail
        sub.addItem(status)
        sub.addItem(.separator())
        func row(_ title: String, _ key: String, _ mods: NSEvent.ModifierFlags, _ action: Selector,
                 _ tip: String) {
            let it = sub.addItem(withTitle: title, action: action, keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            it.target = self
            it.isEnabled = applies
            it.toolTip = applies ? tip : (controller.lyricShiftProblem ?? "")
        }
        row("提前 \(Self.lyricShiftStepText) 秒", Self.leftArrowKey, [.option],
            #selector(shiftLyricEarlier), "歌词提前 \(Self.lyricShiftStepText) 秒出现（⌥←）；" +
            "上限 ±\(Int(PlayerController.lyricShiftLimit)) 秒，只记在应用里不改写 .lrc")
        row("延后 \(Self.lyricShiftStepText) 秒", Self.rightArrowKey, [.option],
            #selector(shiftLyricLater), "歌词延后 \(Self.lyricShiftStepText) 秒出现（⌥→）；" +
            "上限 ±\(Int(PlayerController.lyricShiftLimit)) 秒，只记在应用里不改写 .lrc")
        row("重置（归零）", "0", [.option], #selector(resetLyricShiftKey),
            "把这一曲的校准抹回 0（⌥ 0）；文件自带的 offset 仍然生效")
        item.submenu = sub
        return item
    }

    /// 菜单上写左右箭头要用那个字符（跟系统菜单里「前进/后退」一样的写法）
    static let leftArrowKey = String(Character(UnicodeScalar(0x2190)!))
    static let rightArrowKey = String(Character(UnicodeScalar(0x2192)!))
    /// 步进在文案里只出现一种写法：菜单、tooltip 与自检拿同一个数
    static let lyricShiftStepText = "0.5"

    @objc func shiftLyricEarlier() {
        answerLyric(controller.nudgeLyricShift(-PlayerController.lyricShiftStep))
    }

    @objc func shiftLyricLater() {
        answerLyric(controller.nudgeLyricShift(PlayerController.lyricShiftStep))
    }

    @objc func resetLyricShiftKey() {
        answerLyric(controller.resetLyricShift())
    }

    /// 校准的答复：歌词秀开着时那句已经写在它自己的状态格里，没开就走主显示区那一行
    private func answerLyric(_ text: String) {
        if lyricWindow?.window.isVisible == true { return }
        displayPanel.flashLyricNote(text)
    }

    /// 媒体库子菜单（F08）。与输出设备一样拆成单独函数给自检留口子：
    /// 目录清单、扫描状态那句、每一项能不能点，都要能直接断言
    func buildLibraryItem() -> NSMenuItem {
        let item = NSMenuItem(title: "媒体库", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "媒体库")
        // 自己管可用状态：不然系统会拿 target 能不能响应 action 把 isEnabled 盖掉
        sub.autoenablesItems = false
        // 第一行不参与选择，只回话：几个目录、多少条、几处失效、在不在扫
        let status = NSMenuItem(title: controller.libraryStatusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        sub.addItem(status)
        sub.addItem(.separator())
        let addItem = NSMenuItem(title: "添加音乐目录…", action: #selector(libraryAddFolder),
                                 keyEquivalent: "")
        addItem.target = self
        addItem.toolTip = "选定目录后递归收录其中的音频、CUE 分轨表、歌单与归档；只读不写，不搬不改原始文件"
        sub.addItem(addItem)
        let rescan = NSMenuItem(title: "重新扫描", action: #selector(libraryRescan), keyEquivalent: "")
        rescan.target = self
        // 一趟正在跑就不给再起一趟（要停请先按「停止扫描」）
        rescan.isEnabled = !controller.libraryFolders.isEmpty && !controller.isLibraryScanning
        sub.addItem(rescan)
        let cancel = NSMenuItem(title: "停止扫描", action: #selector(libraryCancelScan), keyEquivalent: "")
        cancel.target = self
        cancel.isEnabled = controller.isLibraryScanning
        cancel.toolTip = "已经并进去的部分不回滚"
        sub.addItem(cancel)
        // 上一句失败原因留在菜单里：只在状态行闪一下的话，用户回头就找不到它了
        if let problem = controller.libraryProblem {
            let row = NSMenuItem(title: "上一次没成：\(problem)", action: nil, keyEquivalent: "")
            row.isEnabled = false
            sub.addItem(row)
        }
        let openPage = NSMenuItem(title: "打开媒体库列表", action: #selector(libraryOpenPage),
                                  keyEquivalent: "")
        openPage.target = self
        sub.addItem(openPage)
        sub.addItem(.separator())
        if controller.libraryFolders.isEmpty {
            let hint = NSMenuItem(title: "还没有音乐目录", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            sub.addItem(hint)
        }
        for dir in controller.libraryFolders {
            sub.addItem(libraryFolderItem(dir))
        }
        item.submenu = sub
        return item
    }

    /// 一个目录一行：整条路径写在 tooltip 里（标题只到上一级目录，两条同名目录靠它区分）
    private func libraryFolderItem(_ dir: String) -> NSMenuItem {
        let name = (dir as NSString).lastPathComponent
        let offline = controller.offlineLibraryFolders.contains(dir)
        let row = NSMenuItem(title: offline ? "\(name)（当前不在线）" : name, action: nil,
                             keyEquivalent: "")
        row.toolTip = dir
        row.isEnabled = true
        let sub = NSMenu(title: dir)
        sub.autoenablesItems = false
        let relocate = NSMenuItem(title: "重新定位此目录…（批量换前缀）",
                                  action: #selector(libraryFolderRelocate(_:)), keyEquivalent: "")
        relocate.target = self
        relocate.representedObject = dir
        relocate.toolTip = "目录整个搬走或改名时用：一次覆盖库、列表、歌单、收藏、历史与待播队列；位置对不上时先问用户，不拿同名就当同一首"
        sub.addItem(relocate)
        let scan = NSMenuItem(title: "只重扫此目录", action: #selector(libraryFolderRescan(_:)),
                              keyEquivalent: "")
        scan.target = self
        scan.representedObject = dir
        scan.isEnabled = !controller.isLibraryScanning
        sub.addItem(scan)
        let remove = NSMenuItem(title: "从媒体库移除", action: #selector(libraryFolderRemove(_:)),
                               keyEquivalent: "")
        remove.target = self
        remove.representedObject = dir
        remove.toolTip = "只摘这片扫出来的引用：磁盘上的文件、歌单、收藏、历史一概不动"
        sub.addItem(remove)
        row.submenu = sub
        return row
    }

    /// 添加音乐目录（菜单那一行）：选完路径交给 PlayerController，自检走同一个控制器入口
    @objc private func libraryAddFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "收录"
        panel.message = "选择一个音乐目录：递归收录其中的音频、CUE 分轨表、歌单与归档"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let problem = controller.addLibraryFolder(url.path) {
            NSSound.beep()
            Diagnostics.error("媒体库目录没加上：\(problem)")
        }
        showLibraryPage()
    }

    /// 重新扫描全部目录（菜单与自检同一条）：只并差量，不开播、不插队
    @objc func libraryRescan() { controller.rescanLibrary() }
    /// 停止扫描（菜单与自检同一条）：已并进去的部分不回滚
    @objc func libraryCancelScan() { controller.cancelLibraryScan() }
    @objc private func libraryOpenPage() { showLibraryPage() }

    /// 重新定位整个目录（菜单逐目录那一项）：选新位置后走批量前缀替换
    @objc private func libraryFolderRelocate(_ sender: NSMenuItem) {
        guard let old = sender.representedObject as? String else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "这就是新位置"
        panel.message = "为「\((old as NSString).lastPathComponent)」选一个新位置（旧位置下的引用会整体搬过去）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let problem = controller.replaceLibraryPrefix(old: old, new: url.path) {
            NSSound.beep()
            Diagnostics.error("目录前缀没换成：\(problem)")
        }
        showLibraryPage()
    }

    /// 只重扫一个目录（菜单与自检同一条）
    @objc func libraryFolderRescan(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? String else { return }
        controller.scanLibraryFolders([dir])
        showLibraryPage()
    }

    /// 从库里摘掉一个目录（菜单与自检同一条）：只扫出来的引用没了，歌单收藏历史都不动
    @objc func libraryFolderRemove(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? String else { return }
        _ = controller.removeLibraryFolder(dir)
    }

    /// 媒体库的改动都要让用户看得见：面板没开就开，组切到「媒体库」那一页
    private func showLibraryPage() {
        if !listVisible { setListVisible(true) }
        playlistPanel.selectGroup(.library)
    }

    /// 半透明玻璃开关：壳层底色按 alpha 切换，阴影跟着重算（不透明度的变化影响投影）
    @objc func toggleGlass() {
        GlassStyle.setEnabled(!GlassStyle.enabled)
        for w in NSApp.windows where w is TTWindow { w.invalidateShadow() }
        persistWindowLayout()
    }

    @objc private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "添加"
        panel.message = "选择音乐文件或文件夹"
        if panel.runModal() == .OK {
            let added = controller.addFiles(panel.urls, playNow: controller.currentTrack == nil)
            if added > 0 {
                if !listVisible { setListVisible(true) }
                playlistView.scrollToCurrent()
            }
        }
    }

    /// 添加网络电台（菜单项）：输入框在列表面板里，与工具条「电台」键走同一条路
    @objc private func addRadioStream() {
        if !listVisible { setListVisible(true) }
        playlistPanel.promptAddRadio()
    }

    /// ⌘F / 菜单与右键菜单那一项：展开列表的搜索框并把键盘交给它（F05）。
    /// 面板折叠时先展开，不然控件在看不见的窗口里，用户只会敲下一堆空字
    @objc private func focusSearch() {
        if !listVisible { setListVisible(true) }
        playlistPanel.focusSearch()
    }

    @objc private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK {
            controller.addFiles(panel.urls)
        }
    }

    @objc private func togglePlay() { controller.togglePlay() }
    @objc private func stopPlay() { controller.stop() }
    @objc private func playNext() { controller.next() }
    @objc private func playPrev() { controller.previous() }

    @objc private func selectMode(_ sender: NSMenuItem) {
        controller.setMode(PlayMode(rawValue: sender.tag) ?? .listLoop)
    }

    @objc private func openEQ() { toggleEQPanel() }
    @objc private func openLyric() { toggleLyricWindow() }
    @objc private func openCover() { toggleCoverWindow() }

    /// 收藏 / 取消收藏当前曲（菜单与 ⌘D 都走这里）
    @objc private func toggleFavorite() {
        guard let track = controller.currentTrack else { NSSound.beep(); return }
        _ = controller.toggleFavorite(track)
    }
    @objc private func clearList() { controller.clearPlaylist() }
    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func showProps() {
        guard let track = controller.currentTrack else { return }
        PropertyPanel.show(for: track, over: window)
    }

    // MARK: - 键盘（复刻千千静听快捷键）

    func handleKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "o": addFiles(); return true
            case "d": toggleFavorite(); return true
            case "e": openEQ(); return true
            case "l": openLyric(); return true
            case "1": togglePlaylist(); return true
            case "f": focusSearch(); return true
            case "q": quitApp(); return true
            default: break
            }
        }
        // 输入框正在吃键盘（F05 搜索框、弹框里的输入框都算）：打字、空格、左右键一律归它，
        // 否则在搜索框里敲个 "m" 就把播放器静音了。F1~F4 不可能是打字键，照旧切播放模式
        if isEditingText(event), ![122, 120, 99, 118].contains(Int(event.keyCode)) {
            return false
        }
        // F10 歌词校准：⌥← / ⌥→ 提前延后 0.5 秒，⌥ 0 归零。必须排在输入框守卫之后、
        // 也排在←/→（上一曲/下一曲）之前：否则在搜索框里按 Option+左右选字就把歌词偷偷搬了
        if event.modifierFlags.contains(.option) {
            switch Int(event.keyCode) {
            case 123: shiftLyricEarlier(); return true
            case 124: shiftLyricLater(); return true
            case 29:  resetLyricShiftKey(); return true   // 主键盘的 0
            default: break
            }
        }
        switch event.keyCode {
        case 49: // 空格
            togglePlay(); return true
        case 123: // ←
            controller.previous(); return true
        case 124: // →
            controller.next(); return true
        case 122: // F1
            controller.setMode(.order); return true
        case 120: // F2
            controller.setMode(.singleLoop); return true
        case 99: // F3
            controller.setMode(.listLoop); return true
        case 118: // F4
            controller.setMode(.random); return true
        default:
            if event.charactersIgnoringModifiers?.lowercased() == "m" {
                controller.toggleMute(); return true
            }
            return false
        }
    }

    /// 这条键盘事件要去的那个窗口里是不是有个文本输入正吃着键盘（字段编辑器是 NSText 的子类）。
    /// 先拿事件自己的 window：没激活的构型（自检、裸二进制）下 keyWindow 会是 nil，
    /// 只看 keyWindow 就会把「正在打字」误判成「没人在打字」
    private func isEditingText(_ event: NSEvent) -> Bool {
        (event.window ?? NSApp.keyWindow)?.firstResponder is NSText
    }
}
