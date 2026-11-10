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

    var listVisible: Bool { dock.isVisible(.playlist) }
    var eqVisible: Bool { dock.isVisible(.equalizer) }
    /// 歌词秀不在停靠组里，显隐直接看窗口
    var lyricVisible: Bool { lyricWindow?.window.isVisible ?? false }

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
            self.scheduleLayoutPersist()
        }
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
        dock.layout()
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

    /// 封面大图窗：点显示区那一格封面就是它（也挂在菜单上）
    func toggleCoverWindow() {
        if coverWindow == nil { coverWindow = CoverWindow() }
        coverWindow?.toggle(near: window)
    }

    // MARK: - 弹出菜单（千千静听的“菜单”按钮）

    func showPopupMenu(under anchor: NSView) {
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
        menu.addItem(.separator())
        for mode in PlayMode.allCases {
            let item = menu.addItem(withTitle: mode.displayName,
                                    action: #selector(selectMode(_:)), keyEquivalent: "")
            item.tag = mode.rawValue
            item.target = self
            item.state = controller.playMode == mode ? .on : .off
        }
        menu.addItem(.separator())
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

        // 菜单开在被点的那个键正下方（以前锚到整条标题条的左端，菜单会飞到最左边）
        menu.popUp(under: anchor)
    }

    @objc private func titleMenuAction(_ sender: NSButton) {
        showPopupMenu(under: sender)
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
            case "q": quitApp(); return true
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
}
