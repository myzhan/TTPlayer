import AppKit

/// 歌词秀：独立无边框皮肤窗（不加入停靠组，可单独置顶/拖动）
/// 当前行居中高亮，其余行按距离渐隐，随播放时间平滑滚动
/// 顶部不再有标题条：开关走主面板底部的「歌词」键，右上角只留一个置顶小键
/// 底部一条校准行（F10）：提前/延后 0.5 秒、重置与当前偏移
/// 宽度始终与停靠组一致（上下叠放时左右边缘对齐），存档只沿用位置与高度
final class LyricWindow: NSObject {
    let window: SkinPanelWindow
    private let view: LyricContentView
    private let pinButton: TTButton
    /// 校准行三件：与⌥←/⌥→/⌥0 是同一个入口的两个形体，走的都是控制层那一个方法
    private let shiftPrev: TTButton
    private let shiftNext: TTButton
    private let shiftReset: TTButton
    /// 当前偏移（或一句「为什么按不动」）
    private let shiftField = NSTextField(labelWithString: "")
    /// 三个键各自本来的悬停说明：能用时念它，不能用时换成「为什么不能用」
    private var shiftHints: [(TTButton, String)] = []
    private let controller = PlayerController.shared
    private var syncTimer: Timer?
    /// 一次性说明（到边界、没歌词）挂到什么时候：值真变了就不挂，
    /// 状态格里那句新偏移就是答复，没必要再叠一层提示
    private var noteText: String?
    private var noteUntil = Date.distantPast

    /// 默认高度（宽度由停靠组决定）
    static let defaultHeight: CGFloat = 260
    /// 底部校准行占的高度（含上下留白）：歌词视图不再顶到窗口下沿，
    /// 免得按钮压在字上。界面自检按这个数算视图高度
    static let controlsRowHeight: CGFloat = 26
    /// 建档时是否用上了存档的位置（否则由主面板贴到组下方）
    private(set) var usedSavedFrame = false

    init(width: CGFloat) {
        let w = max(MainWindowController.minWidth, width)
        let rect = NSRect(x: 0, y: 0, width: w, height: Self.defaultHeight)
        window = SkinPanelWindow(width: w, height: Self.defaultHeight, title: "歌词秀")
        pinButton = TTButton(.symbol("pin"), target: nil, action: nil,
                             size: NSSize(width: 22, height: 18))
        // 校准行用文字键（与主面板那三个文字键同一类造型）：±0.5 秒写在 tooltip 与状态格里
        shiftPrev = TTButton(.title("提前"), target: nil, action: nil,
                             size: NSSize(width: 42, height: 18), face: .glass)
        shiftNext = TTButton(.title("延后"), target: nil, action: nil,
                             size: NSSize(width: 42, height: 18), face: .glass)
        shiftReset = TTButton(.title("重置"), target: nil, action: nil,
                              size: NSSize(width: 42, height: 18), face: .glass)
        view = LyricContentView(frame: rect)
        super.init()

        window.isMovableByWindowBackground = true
        window.level = .normal
        pinButton.target = self
        pinButton.action = #selector(togglePin)
        pinButton.toolTip = "总在最前"
        for (btn, say, step) in [(shiftPrev, "歌词提前 0.5 秒（⌥←）", -PlayerController.lyricShiftStep),
                                 (shiftNext, "歌词延后 0.5 秒（⌥→）", PlayerController.lyricShiftStep)] {
            btn.target = self
            btn.action = #selector(shiftTapped(_:))
            btn.toolTip = say
            btn.tag = Int(step * 10)          // ±5 ↔ ±0.5 秒：tag 存十进制，免得浮点比较
            shiftHints.append((btn, say))
        }
        let resetHint = "把这一曲的歌词校准归零（⌥ 0）"
        shiftReset.target = self
        shiftReset.action = #selector(shiftResetTapped)
        shiftReset.toolTip = resetHint
        shiftHints.append((shiftReset, resetHint))
        shiftField.font = NSFont.systemFont(ofSize: 11)
        shiftField.textColor = Theme.textSecondary
        shiftField.alignment = .right
        shiftField.lineBreakMode = .byTruncatingHead

        pinButton.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        for btn in [shiftPrev, shiftNext, shiftReset] { btn.translatesAutoresizingMaskIntoConstraints = false }
        shiftField.translatesAutoresizingMaskIntoConstraints = false
        window.skinRoot.addSubview(view)
        window.skinRoot.addSubview(pinButton)
        window.skinRoot.addSubview(shiftPrev)
        window.skinRoot.addSubview(shiftNext)
        window.skinRoot.addSubview(shiftReset)
        window.skinRoot.addSubview(shiftField)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: window.skinRoot.topAnchor, constant: 6),
            view.leadingAnchor.constraint(equalTo: window.skinRoot.leadingAnchor, constant: 6),
            view.trailingAnchor.constraint(equalTo: window.skinRoot.trailingAnchor, constant: -6),
            // 底下留出校准行那一挡（不然按钮与字叠在一起）
            view.bottomAnchor.constraint(equalTo: shiftPrev.topAnchor, constant: -2),

            pinButton.trailingAnchor.constraint(equalTo: window.skinRoot.trailingAnchor, constant: -7),
            pinButton.topAnchor.constraint(equalTo: window.skinRoot.topAnchor, constant: 7),
            pinButton.widthAnchor.constraint(equalToConstant: 22),
            pinButton.heightAnchor.constraint(equalToConstant: 18),

            shiftPrev.leadingAnchor.constraint(equalTo: window.skinRoot.leadingAnchor, constant: 8),
            shiftPrev.bottomAnchor.constraint(equalTo: window.skinRoot.bottomAnchor, constant: -6),
            shiftNext.leadingAnchor.constraint(equalTo: shiftPrev.trailingAnchor, constant: 4),
            shiftNext.centerYAnchor.constraint(equalTo: shiftPrev.centerYAnchor),
            shiftReset.leadingAnchor.constraint(equalTo: shiftNext.trailingAnchor, constant: 4),
            shiftReset.centerYAnchor.constraint(equalTo: shiftPrev.centerYAnchor),

            shiftField.trailingAnchor.constraint(equalTo: window.skinRoot.trailingAnchor, constant: -8),
            shiftField.centerYAnchor.constraint(equalTo: shiftPrev.centerYAnchor),
            shiftField.widthAnchor.constraint(equalToConstant: 176),
            shiftField.leadingAnchor.constraint(greaterThanOrEqualTo: shiftReset.trailingAnchor,
                                                constant: 6),
        ])

        usedSavedFrame = restoreFrame()
        applyWidthLimits(w)
        refreshShiftRow()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(trackChanged(_:)), name: .ttTrackChanged, object: nil)
        nc.addObserver(self, selector: #selector(willClose(_:)),
                       name: NSWindow.willCloseNotification, object: window)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// 歌词绘制视图（自检用：确认它直接顶到窗口上沿，不再有标题条）
    var contentView: NSView { view }

    // MARK: - 校准行（F10）

    /// 自检入口：状态格当前那句话
    var shiftLabelText: String { shiftField.stringValue }
    /// 自检入口：歌词秀当前高亮那一行（与主显示区那句对得上才叫「同一校准结果」）
    var currentLineText: String { view.currentLineText }
    /// 自检入口：状态格悬停那一句完整说明（含上下限与「不改写 .lrc」）
    var shiftToolTip: String { shiftField.toolTip ?? "" }
    /// 自检入口：三个键的当前可用性（没歌词时应全部按不动）
    var shiftButtons: [TTButton] { [shiftPrev, shiftNext, shiftReset] }

    @objc private func shiftTapped(_ sender: TTButton) {
        let before = controller.lyricShift
        let said = controller.nudgeLyricShift(Double(sender.tag) / 10)
        note(said, changed: controller.lyricShift != before)
    }

    @objc private func shiftResetTapped() {
        let before = controller.lyricShift
        let said = controller.resetLyricShift()
        note(said, changed: before != 0 && controller.lyricShift == 0)
    }

    /// 值真变了：不挂提示，状态格自己会说；值没变（到边界、没歌词）：
    /// 这才是需要说清「为什么按了不动」的一次性说明，挂三秒
    private func note(_ text: String, changed: Bool) {
        if changed {
            noteText = nil
        } else {
            noteText = text
            noteUntil = Date().addingTimeInterval(3)
        }
        refreshShiftRow()
    }

    /// 把校准行对齐到当前曲目：没歌词就禁用三个键并把原因写在状态格里
    private func refreshShiftRow() {
        let applies = controller.lyricShiftApplies
        for (btn, hint) in shiftHints {
            btn.isEnabled = applies
            // 自绘键不读 isEnabled，用透明度把「按不动」画出来
            btn.alphaValue = applies ? 1 : 0.42
            // 键按不动时悬停也要说清「为什么不动」，否则只当界面坏了
            btn.toolTip = applies ? hint : (controller.lyricShiftProblem ?? hint)
        }
        shiftField.toolTip = controller.lyricShiftDetail
        if let pending = noteText {
            if Date() < noteUntil {
                shiftField.stringValue = pending
                return
            }
            noteText = nil
        }
        shiftField.stringValue = applies ? "校准：\(controller.lyricShiftText)"
            : (controller.lyricShiftProblem ?? "没有歌词可校准")
    }

    /// 只沿用存档的位置与高度：宽度跟着停靠组走（旧存档的 520 宽会被对齐到组宽）
    @discardableResult
    private func restoreFrame() -> Bool {
        let saved = LibraryStore.load().lyricFrame
        let parts = saved.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4, parts[3] > 120 else { return false }
        let frame = NSRect(x: parts[0], y: parts[1],
                           width: window.frame.width, height: CGFloat(parts[3]))
        guard NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else { return false }
        window.setFrame(frame, display: false)
        return true
    }

    /// 停靠组变宽/变窄后跟着对齐（保持位置与高度）
    func matchWidth(_ width: CGFloat) {
        let w = max(MainWindowController.minWidth, width)
        // 先把可拉范围跟上：宽度锁死在组宽上，只能手动拉高
        applyWidthLimits(w)
        guard abs(window.frame.width - w) > 0.5 else { return }
        var f = window.frame
        f.size.width = w
        window.setFrame(f, display: true)
    }

    /// 横向不再放开：宽度最小=最大=组宽，防止拉边把手动对齐拉散（高度仍可拉伸）
    private func applyWidthLimits(_ w: CGFloat) {
        window.contentMinSize = NSSize(width: w, height: 140)
        window.contentMaxSize = NSSize(width: w, height: 1200)
    }

    /// 首次打开且没有存档时贴在停靠组下方（同宽、左对齐），上下叠放就是一块
    func placeBelow(groupLeft: CGFloat, groupBottom: CGFloat) {
        var f = window.frame
        f.origin = NSPoint(x: groupLeft, y: groupBottom - SkinDock.gap - f.height)
        // 夹回组所在那块屏：拿 NSScreen.main 会在多屏时把歌词窗夹到另一块屏上
        let screen = SkinDock.visibleFrame(near: NSPoint(x: groupLeft + f.width / 2, y: groupBottom - 1))
        f.origin.x = min(max(f.minX, screen.minX), max(screen.minX, screen.maxX - f.width))
        f.origin.y = min(max(f.minY, screen.minY), max(screen.minY, screen.maxY - f.height))
        window.setFrame(f, display: false)
    }

    func persistFrame() {
        var state = LibraryStore.load()
        let f = window.frame
        state.lyricFrame = "\(f.minX),\(f.minY),\(f.width),\(f.height)"
        LibraryStore.save(state)
    }

    @objc private func willClose(_ note: Notification) {
        persistFrame()
    }

    @objc private func trackChanged(_ note: Notification) {
        view.resetScroll()
        // 换曲等于换了一整套校准量（各轨各存），状态行与按键可用性当场跟着走
        refreshShiftRow()
    }

    func showAndSync() {
        window.makeKeyAndOrderFront(nil)
        startTimer()
    }

    @objc private func togglePin() {
        window.level = window.level == .floating ? .normal : .floating
        pinButton.lit = window.level == .floating
    }

    private func startTimer() {
        guard syncTimer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            // 暂停时引擎报的就是停住的那一秒，照样能查行（拖过进度条再停下，两处得说同一句）；
            // 只有真的没在放东西（没曲目）才保持原位不重算
            let time = self.controller.currentTrack == nil ? -1 : self.controller.currentTime
            // 滚动只认控制器那一份校准量：与主显示区查行用的是同一个数，两处才不会各说一套
            self.view.update(lyric: self.controller.lyric, currentTime: time,
                             delay: self.controller.lyricShift)
            // 校准行也挂在这个节拍上：一次性说明（到边界、没歌词）到点自己消失
            self.refreshShiftRow()
        }
        RunLoop.main.add(t, forMode: .common)
        syncTimer = t
    }
}

/// 歌词绘制视图：深蓝灰内槽底 + 居中逐行 + 当前行高亮
final class LyricContentView: NSView {
    override var isFlipped: Bool { true }

    private var lines: [LyricLine] = []
    private var currentIndex = -1
    /// 行步进（字号变大后同步拉开，避免当前行与相邻行重叠）
    static let lineHeight: CGFloat = 40

    private var scrollOffset: CGFloat = 0        // 平滑滚动当前偏移
    private var targetOffset: CGFloat = 0
    private var hasLyric = true
    private var lastEmptyDescriptor: LyricStateDescriptor? = nil

    /// 用于去重“无歌词”状态的描述
    private struct LyricStateDescriptor: Equatable {
        let lyric: Lyric?
        init(lyric: Lyric?) { self.lyric = lyric }
        static func == (a: LyricStateDescriptor, b: LyricStateDescriptor) -> Bool {
            (a.lyric == nil && b.lyric == nil) ||
            (a.lyric != nil && b.lyric != nil && a.lyric?.isEmpty == true && b.lyric?.isEmpty == true)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glassObs = NotificationCenter.default.addObserver(
            forName: GlassStyle.didChange, object: nil, queue: .main) { [weak self] _ in
                self?.needsDisplay = true
            }
    }

    private var glassObs: NSObjectProtocol?
    deinit { if let o = glassObs { NotificationCenter.default.removeObserver(o) } }

    required init?(coder: NSCoder) { fatalError() }

    /// 换曲时回到顶部
    func resetScroll() {
        scrollOffset = 0
        targetOffset = 0
        currentIndex = -1
        needsDisplay = true
    }

    /// 自检入口：当前高亮的那一行（与主显示区同一句才是「两处用同一校准结果」）
    var currentLineText: String {
        lines.indices.contains(currentIndex) ? lines[currentIndex].text : ""
    }

    /// 滚动位置按「歌词自己的时间轴」算：整盘词补段起点、用户校准（正值 = 延后）减掉，
    /// 换算只走 `Lyric.alignedTime` 这一条路，与控制层找当前行那一句一模一样
    func update(lyric: Lyric?, currentTime: Double, delay: Double = 0) {
        guard let lyric, !lyric.isEmpty else {
            // 无歌词：只在状态变化时重绘
            let empty = LyricStateDescriptor(lyric: lyric)
            if empty != lastEmptyDescriptor {
                lastEmptyDescriptor = empty
                lines = []
                currentIndex = -1
                hasLyric = (lyric != nil)   // 有歌词文件但全空 → 纯音乐
                needsDisplay = true
            }
            return
        }
        lastEmptyDescriptor = nil
        hasLyric = true
        lines = lyric.lines
        // 没在播（传 -1）时不重新查行：换曲刚回到顶部、暂停那一瞬的余量都要接着走完，
        // 但不能再拿一个没有意义的播放位置去算行
        let aligned = currentTime >= 0 ? lyric.alignedTime(segmentTime: currentTime, delay: delay) : nil
        if let aligned { currentIndex = lyric.lineIndex(at: aligned) }
        let idx = currentIndex
        // 目标位置：当前行居中
        let lineH: CGFloat = Self.lineHeight
        targetOffset = CGFloat(max(0, idx)) * lineH - (bounds.height - lineH) / 2
        // 行内微滚动（两行之间线性过渡）
        if let aligned, idx >= 0, idx + 1 < lines.count {
            let cur = lines[idx], next = lines[idx + 1]
            let span = max(0.001, next.time - cur.time)
            let f = min(1, max(0, (aligned - cur.time) / span))
            targetOffset += CGFloat(f) * lineH
        }
        // 平滑逼近
        scrollOffset += (targetOffset - scrollOffset) * 0.12
        if abs(targetOffset - scrollOffset) > 0.3 || currentTime >= 0 {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // 内槽底（与显示区同一块深蓝灰玻璃）：玻璃开启时按 wellAlpha 透一下
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        guard rect.width > 3, rect.height > 3 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        let wA = GlassStyle.enabled ? GlassStyle.wellAlpha : 1
        NSGradient(colors: [Theme.wellTop.withAlphaComponent(Theme.wellTop.alphaComponent * wA),
                            Theme.wellBottom.withAlphaComponent(Theme.wellBottom.alphaComponent * wA)])?
            .draw(in: path, angle: -90)
        Theme.wellBevelDark.setStroke()
        path.lineWidth = 1
        path.stroke()

        guard hasLyric, !lines.isEmpty else {
            drawMessage(hasLyric ? "♪ 纯音乐，请欣赏 ♪" : "未找到歌词（支持同名 .lrc 文件）")
            return
        }

        // 当前行居中，上下渐隐
        let lineH: CGFloat = Self.lineHeight
        let lo = max(0, Int(scrollOffset / lineH) - 2)
        let hi = min(lines.count - 1, Int((scrollOffset + bounds.height) / lineH) + 2)
        guard lo <= hi else { return }
        let centerZone = bounds.height / 2
        for i in lo...hi {
            let y = CGFloat(i) * lineH - scrollOffset + centerZone - lineH / 2
            let isCurrent = i == currentIndex
            let attrs: [NSAttributedString.Key: Any]
            if isCurrent {
                attrs = [
                    .font: NSFont.systemFont(ofSize: 24, weight: .bold),
                    .foregroundColor: Theme.textHighlight,
                ]
            } else {
                let distance = abs(Double(i - currentIndex))
                let alpha = max(0.15, 0.6 - distance * 0.12)
                attrs = [
                    .font: NSFont.systemFont(ofSize: 16),
                    .foregroundColor: Theme.textAccent.withAlphaComponent(alpha),
                ]
            }
            let str = NSAttributedString(string: lines[i].text, attributes: attrs)
            let sz = str.size()
            str.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: y))
        }
    }

    private func drawMessage(_ msg: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18),
            .foregroundColor: Theme.textSecondary,
        ]
        let str = NSAttributedString(string: msg, attributes: attrs)
        let sz = str.size()
        str.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: bounds.height / 2 - sz.height / 2))
    }
}
