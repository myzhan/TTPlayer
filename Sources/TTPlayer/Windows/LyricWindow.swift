import AppKit

/// 歌词秀：独立无边框皮肤窗（不加入停靠组，可单独置顶/拖动）
/// 当前行居中高亮，其余行按距离渐隐，随播放时间平滑滚动
/// 顶部不再有标题条：开关走主面板底部的「歌词」键，右上角只留一个置顶小键
/// 宽度始终与停靠组一致（上下叠放时左右边缘对齐），存档只沿用位置与高度
final class LyricWindow: NSObject {
    let window: SkinPanelWindow
    private let view: LyricContentView
    private let pinButton: TTButton
    private let controller = PlayerController.shared
    private var syncTimer: Timer?

    /// 默认高度（宽度由停靠组决定）
    static let defaultHeight: CGFloat = 260
    /// 建档时是否用上了存档的位置（否则由主面板贴到组下方）
    private(set) var usedSavedFrame = false

    init(width: CGFloat) {
        let w = max(MainWindowController.minWidth, width)
        let rect = NSRect(x: 0, y: 0, width: w, height: Self.defaultHeight)
        window = SkinPanelWindow(width: w, height: Self.defaultHeight, title: "歌词秀")
        pinButton = TTButton(.symbol("pin"), target: nil, action: nil,
                             size: NSSize(width: 22, height: 18))
        view = LyricContentView(frame: rect)
        super.init()

        window.isMovableByWindowBackground = true
        window.level = .normal
        pinButton.target = self
        pinButton.action = #selector(togglePin)
        pinButton.toolTip = "总在最前"

        pinButton.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        window.skinRoot.addSubview(view)
        window.skinRoot.addSubview(pinButton)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: window.skinRoot.topAnchor, constant: 6),
            view.leadingAnchor.constraint(equalTo: window.skinRoot.leadingAnchor, constant: 6),
            view.trailingAnchor.constraint(equalTo: window.skinRoot.trailingAnchor, constant: -6),
            view.bottomAnchor.constraint(equalTo: window.skinRoot.bottomAnchor, constant: -6),

            // 置顶键浮在右上角：不再是“标题条里的一排键”
            pinButton.trailingAnchor.constraint(equalTo: window.skinRoot.trailingAnchor, constant: -7),
            pinButton.topAnchor.constraint(equalTo: window.skinRoot.topAnchor, constant: 7),
            pinButton.widthAnchor.constraint(equalToConstant: 22),
            pinButton.heightAnchor.constraint(equalToConstant: 18),
        ])

        usedSavedFrame = restoreFrame()
        applyWidthLimits(w)
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(trackChanged(_:)), name: .ttTrackChanged, object: nil)
        nc.addObserver(self, selector: #selector(willClose(_:)),
                       name: NSWindow.willCloseNotification, object: window)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// 歌词绘制视图（自检用：确认它直接顶到窗口上沿，不再有标题条）
    var contentView: NSView { view }

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
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var f = window.frame
        f.origin = NSPoint(x: groupLeft, y: groupBottom - SkinDock.gap - f.height)
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
            let time = self.controller.isPlaying ? self.controller.currentTime : -1
            self.view.update(lyric: self.controller.lyric, currentTime: time)
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

    func update(lyric: Lyric?, currentTime: Double) {
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
        let idx = currentTime >= 0 ? lyric.lineIndex(at: currentTime) : currentIndex
        if idx != currentIndex {
            currentIndex = idx
        }
        // 目标位置：当前行居中
        let lineH: CGFloat = Self.lineHeight
        targetOffset = CGFloat(max(0, idx)) * lineH - (bounds.height - lineH) / 2
        // 行内微滚动（两行之间线性过渡）
        if idx >= 0, idx + 1 < lines.count {
            let cur = lines[idx], next = lines[idx + 1]
            let span = max(0.001, next.time - cur.time)
            let f = min(1, max(0, (currentTime - cur.time) / span))
            targetOffset += CGFloat(f) * lineH
        }
        // 平滑逼近
        scrollOffset += (targetOffset - scrollOffset) * 0.12
        if abs(targetOffset - scrollOffset) > 0.3 {
            needsDisplay = true
        } else if currentTime >= 0 {
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
