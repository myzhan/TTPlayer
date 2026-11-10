import AppKit

/// 跑马灯字幕：文字超出可用宽度时左右往返滚动（千千静听标题区的标志性行为）
final class MarqueeLabel: NSView {
    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            resetScroll()
            needsDisplay = true
        }
    }
    var font = Theme.smallFont { didSet { needsDisplay = true } }
    var textColor = Theme.textPrimary { didSet { needsDisplay = true } }
    /// 左侧固定图标（不随文字滚动）
    var symbolName: String? { didSet { needsDisplay = true } }

    private var xOffset: CGFloat = 0
    private var scrollingRight = false
    private var pauseTicks = 0
    private var timer: Timer?
    private let speed: CGFloat = 0.7

    override var isFlipped: Bool { true }

    deinit { stop() }

    private func resetScroll() {
        xOffset = 0
        scrollingRight = false
        pauseTicks = 40          // 先静止一会儿再开始滚
        restartTimerIfNeeded()
    }

    private var overflow: CGFloat {
        textWidth + iconWidth + 6 - bounds.width
    }

    private var textWidth: CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private var iconWidth: CGFloat {
        symbolName == nil ? 0 : 18
    }

    private func restartTimerIfNeeded() {
        if overflow > 0 {
            guard timer == nil else { return }
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            timer?.invalidate()
            timer = nil
            xOffset = 0
        }
    }

    private func tick() {
        guard overflow > 0 else { return }
        if pauseTicks > 0 {
            pauseTicks -= 1
            return
        }
        if scrollingRight {
            xOffset += speed
            if xOffset >= 0 {
                xOffset = 0
                scrollingRight = false
                pauseTicks = 60
            }
        } else {
            xOffset -= speed
            if xOffset <= -overflow {
                xOffset = -overflow
                scrollingRight = true
                pauseTicks = 30
            }
        }
        needsDisplay = true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    override func layout() {
        super.layout()
        restartTimerIfNeeded()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        var textX = bounds.minX
        if let name = symbolName, let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            let h: CGFloat = max(6, min(14, bounds.height - 10))
            let ratio = h / image.size.height
            let w = image.size.width * ratio
            let rect = NSRect(x: bounds.minX + 1, y: (bounds.height - h) / 2, width: w, height: h)
            let tinted = NSImage(size: rect.size, flipped: false) { _ in
                image.draw(in: NSRect(origin: .zero, size: rect.size))
                Theme.textAccent.set()
                NSRect(origin: .zero, size: rect.size).fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                        respectFlipped: true, hints: nil)
            textX = rect.maxX + 4
        }
        guard !text.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let textHeight = (text as NSString).size(withAttributes: attrs).height

        // 只在文字区裁剪，图标固定不动
        let clipW = max(0, bounds.maxX - textX)
        let clip = NSBezierPath(rect: NSRect(x: textX, y: bounds.minY,
                                             width: clipW, height: bounds.height))
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        (text as NSString).draw(at: NSPoint(x: textX + xOffset,
                                            y: (bounds.height - textHeight) / 2),
                                withAttributes: attrs)
        // 右边缘淡出，避免文字被硬切
        NSGradient(starting: NSColor.clear,
                   ending: Theme.titleBottom.withAlphaComponent(0.9))?
            .draw(in: NSRect(x: bounds.maxX - 14, y: bounds.minY, width: 14, height: bounds.height), angle: 0)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// 迷你音量槽：细凹槽 + 玻璃圆推子（照原版皮肤的样子），右侧带百分比
final class VolumeWellView: NSControl {
    var value: Double = 0.8 {
        didSet {
            value = max(0, min(1, value))
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }
    }
    var isMuted = false { didSet { needsDisplay = true } }
    private var isHot = false

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 22) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    private var trackingAreaRef: NSTrackingArea?

    override func mouseEntered(with event: NSEvent) { isHot = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHot = false; needsDisplay = true }

    private func update(from event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let grooveRect = grooveBounds
        guard grooveRect.width > 0 else { return }
        value = Double(max(0, min(1, (p.x - grooveRect.minX) / grooveRect.width)))
        sendAction(action, to: target)
    }

    override func mouseDown(with event: NSEvent) { update(from: event) }
    override func mouseDragged(with event: NSEvent) { update(from: event) }

    private var grooveBounds: NSRect {
        NSRect(x: 2, y: (bounds.height - 5) / 2, width: max(1, bounds.width - 58), height: 5)
    }

    override func draw(_ dirtyRect: NSRect) {
        let groove = grooveBounds
        guard groove.width > 1, groove.height > 1, bounds.height > 6 else { return }
        let path = NSBezierPath(roundedRect: groove, xRadius: 2.5, yRadius: 2.5)
        Theme.groove.setFill()
        path.fill()
        (isHot ? Theme.wellBevelLight : Theme.wellBevelDark).withAlphaComponent(0.8).setStroke()
        path.lineWidth = 1
        path.stroke()

        let ratio = isMuted ? 0 : CGFloat(max(0, min(1, value)))
        let fillW = groove.width * ratio
        if fillW > 1 {
            let fillRect = NSRect(x: groove.minX, y: groove.minY, width: fillW, height: groove.height)
            NSGradient(colors: [Theme.spectrumBottom, Theme.textAccent])?
                .draw(in: NSBezierPath(roundedRect: fillRect, xRadius: 2.5, yRadius: 2.5), angle: -90)
        }

        // 玻璃圆推子
        let knobD = min(bounds.height - 4, 16)
        if knobD > 2 {
            let cx = groove.minX + fillW
            let knob = NSRect(x: cx - knobD / 2, y: bounds.midY - knobD / 2,
                              width: knobD, height: knobD)
            let knobPath = NSBezierPath(ovalIn: knob)
            Theme.buttonGradient(hot: isHot).draw(in: knobPath, angle: -90)
            Theme.buttonEdge.setStroke()
            knobPath.lineWidth = 1
            knobPath.stroke()
            NSColor(calibratedWhite: 1, alpha: 0.7).setFill()
            NSRect(x: knob.minX + 3, y: knob.minY + 2,
                   width: max(1, knob.width - 6), height: 2).fill()
        }

        let pct = isMuted ? "静音" : "\(Int((value * 100).rounded()))%"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.tinyFont,
            .foregroundColor: (isMuted || value == 0) ? Theme.meterRed : Theme.textSecondary,
        ]
        let str = pct as NSString
        let sz = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: bounds.maxX - sz.width - 1, y: bounds.midY - sz.height / 2),
                 withAttributes: attrs)
    }
}

/// 面板标题条：浅蓝灰玻璃 + 左侧深色标题 + 右侧一组皮肤小按钮
final class PanelHeaderView: GradientView {
    let titleLabel = NSTextField(labelWithString: "")
    private let buttonRow = NSStackView()

    /// 拖动区（整条空白处都能拖动停靠组）
    private(set) var dragArea: TitleBarDragView!

    init(title: String, height: CGFloat = 26) {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: height))
        colors = [Theme.titleTop, Theme.titleBottom]
        cornerRadius = 6
        gloss = true
        glassBody = true
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        titleLabel.stringValue = title
        titleLabel.font = Theme.panelTitleFont
        titleLabel.textColor = Theme.titleText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        buttonRow.orientation = .horizontal
        buttonRow.spacing = 3
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttonRow)

        dragArea = TitleBarDragView(frame: .zero)
        dragArea.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dragArea, positioned: .below, relativeTo: titleLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            buttonRow.centerYAnchor.constraint(equalTo: centerYAnchor),
            dragArea.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            dragArea.trailingAnchor.constraint(equalTo: buttonRow.leadingAnchor, constant: -6),
            dragArea.topAnchor.constraint(equalTo: topAnchor),
            dragArea.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 追加右侧小按钮（自动按加入顺序从右往左排）
    func addControl(_ view: NSView) {
        buttonRow.addArrangedSubview(view)
    }
}

/// 竖向推子：细凹槽 + 玻璃圆帽，均衡器 10 段用
final class FaderView: NSControl {
    var minValue: Double = -12
    var maxValue: Double = 12
    var gain: Double = 0 {
        didSet { needsDisplay = true }
    }
    /// 轨道颜色（预放大用蓝色，频段用默认）
    var tint = Theme.textAccent
    private var isHot = false
    private var trackingAreaRef: NSTrackingArea?

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: 26, height: 120) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseEntered(with event: NSEvent) { isHot = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHot = false; needsDisplay = true }

    private func update(from event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let travel = trackTravel
        guard travel.height > 1 else { return }
        // 顶部 = maxValue，底部 = minValue
        let ratio = 1 - min(1, max(0, (p.y - travel.minY + capHeight / 2) / travel.height))
        gain = minValue + ratio * (maxValue - minValue)
        sendAction(action, to: target)
    }

    override func mouseDown(with event: NSEvent) { update(from: event) }
    override func mouseDragged(with event: NSEvent) { update(from: event) }

    private var capHeight: CGFloat { min(18, max(10, bounds.width * 0.7)) }

    /// 推帽中心可活动的范围
    private var trackTravel: NSRect {
        let x = bounds.midX
        let top = capHeight / 2 + 1
        let bottom = bounds.height - capHeight / 2 - 1
        return NSRect(x: x, y: top, width: 1, height: max(1, bottom - top))
    }

    private var valueRatio: CGFloat {
        CGFloat((gain - minValue) / max(0.0001, maxValue - minValue))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 3, bounds.height > 6 else { return }
        let travel = trackTravel
        // 凹槽
        let grooveW: CGFloat = 5
        let groove = NSRect(x: bounds.midX - grooveW / 2, y: travel.minY - capHeight / 2 + 2,
                            width: grooveW, height: travel.height + capHeight - 4)
        let groovePath = NSBezierPath(roundedRect: groove, xRadius: 2.5, yRadius: 2.5)
        Theme.groove.setFill()
        groovePath.fill()
        Theme.wellBevelDark.setStroke()
        groovePath.lineWidth = 1
        groovePath.stroke()

        // 0 位刻度线
        Theme.wellBevelLight.withAlphaComponent(0.55).setFill()
        let zeroY = travel.maxY - travel.height * CGFloat((0 - minValue) / (maxValue - minValue))
        NSRect(x: bounds.midX - 8, y: zeroY - 0.5, width: 16, height: 1).fill()

        // 推帽：浅玻璃椭圆 + 高光 + 中心指针线
        let capW = min(bounds.width - 2, capHeight * 1.35)
        let capY = travel.maxY - travel.height * valueRatio
        let cap = NSRect(x: bounds.midX - capW / 2, y: capY - capHeight / 2,
                         width: capW, height: capHeight)
        let capPath = NSBezierPath(roundedRect: cap, xRadius: 4, yRadius: 4)
        Theme.buttonGradient(hot: isHot).draw(in: capPath, angle: -90)
        Theme.buttonEdge.setStroke()
        capPath.lineWidth = 1
        capPath.stroke()
        NSColor(calibratedWhite: 1, alpha: 0.8).setFill()
        NSRect(x: cap.minX + 2, y: cap.minY + 2, width: max(1, cap.width - 4), height: 1.5).fill()
        tint.setFill()
        NSRect(x: cap.minX + 2, y: cap.midY - 0.5,
               width: max(1, cap.width - 4), height: 1).fill()
    }
}

/// 旋钮：圆弧刻度 + 指针，拖动上下（左右）调节
final class KnobView: NSControl {
    var minValue: Double = -12
    var maxValue: Double = 12
    var gain: Double = 0 { didSet { needsDisplay = true } }
    var caption = ""
    private var isHot = false
    private var lastDragY: CGFloat?
    private var trackingAreaRef: NSTrackingArea?

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 34) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseEntered(with event: NSEvent) { isHot = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHot = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) { lastDragY = event.locationInWindow.y }

    /// 向上拖增大：60pt 对应一个满量程
    override func mouseDragged(with event: NSEvent) {
        let y = event.locationInWindow.y
        defer { lastDragY = y }
        guard let prev = lastDragY else { return }
        let span = max(0.0001, maxValue - minValue)
        gain = min(maxValue, max(minValue, gain + Double(y - prev) / 60 * span))
        sendAction(action, to: target)
    }

    override func mouseUp(with event: NSEvent) { lastDragY = nil }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 6, bounds.height > 6 else { return }
        let d = min(bounds.width, bounds.height - (caption.isEmpty ? 0 : 12))
        guard d > 4 else { return }
        let knobRect = NSRect(x: bounds.midX - d / 2, y: bounds.minY,
                              width: d, height: d)
        let path = NSBezierPath(ovalIn: knobRect.insetBy(dx: 1, dy: 1))
        Theme.buttonGradient(hot: isHot).draw(in: path, angle: -90)
        Theme.buttonEdge.setStroke()
        path.lineWidth = 1
        path.stroke()

        // 指针：-135°...+135°
        let ratio = CGFloat((gain - minValue) / max(0.0001, maxValue - minValue))
        let angle = (-135 + Double(ratio) * 270) * .pi / 180
        let center = NSPoint(x: knobRect.midX, y: knobRect.midY)
        let r = d / 2 - 3
        NSColor.hex(0x1B3A5C).setStroke()
        let needle = NSBezierPath()
        needle.move(to: center)
        needle.line(to: NSPoint(x: center.x + r * cos(angle), y: center.y - r * sin(angle)))
        needle.lineWidth = 2
        needle.stroke()

        if !caption.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Theme.tinyFont,
                .foregroundColor: Theme.textSecondary,
            ]
            let str = caption as NSString
            let sz = str.size(withAttributes: attrs)
            str.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: knobRect.maxY + 1),
                     withAttributes: attrs)
        }
    }
}

// MARK: - 传输键玻璃带：一整条连续渐变底，每格各自有一道上下明暗

/// 截图里的传输键不是几个独立贴片，而是贴在一起的一整条玻璃（上亮下暗渐变 + 格间分界线）。
/// 但只画整条渐变 + 1px 分隔线，它会被读成一整块“凹槽”；所以每一格再单独叠一层
/// 上高光/下暗线，格间用“暗线 + 右侧亮线”收口，一排才读作几个鼓起来的键。
final class SegmentedGlassBar: GradientView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        colors = [Theme.buttonTop, Theme.buttonBottom]
        cornerRadius = 4
        edgeColor = Theme.buttonEdge
        innerHighlight = true
        gloss = true
        glassBody = true
        glassAlphaOverride = GlassStyle.buttonAlpha
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 分格位置随布局变化，重排后补一次重绘
    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let cells = subviews.compactMap { $0 as? TTButton }
            .filter { $0.frame.width > 1 }
            .sorted { $0.frame.minX < $1.frame.minX }
        guard cells.count > 1 else { return }

        // 每格自己的体积：上沿高光 + 下沿暗线（isFlipped = true，minY 是顶部）
        for cell in cells {
            let r = cell.frame.insetBy(dx: 1, dy: 1)
            guard r.width > 3, r.height > 4 else { continue }
            NSColor(calibratedWhite: 1, alpha: 0.55).setFill()
            NSRect(x: r.minX + 1, y: r.minY + 1, width: r.width - 2, height: 1).fill()
            Theme.shellDivider.withAlphaComponent(0.35).setFill()
            NSRect(x: r.minX + 1, y: r.maxY - 2, width: r.width - 2, height: 1).fill()
        }

        // 格间分隔：暗线 + 右侧亮线，两侧有明暗差，键才“鼓”得起来
        for cell in cells.dropLast() {
            let x = cell.frame.maxX.rounded() - 0.5
            let top = cell.frame.minY + 3
            let height = cell.frame.height - 6
            guard height > 2 else { continue }
            Theme.buttonEdge.withAlphaComponent(0.8).setFill()
            NSRect(x: x, y: top, width: 1, height: height).fill()
            NSColor(calibratedWhite: 1, alpha: 0.55).setFill()
            NSRect(x: x + 1, y: top, width: 1, height: height).fill()
        }
    }
}

// MARK: - 菜单弹出锚点

extension NSMenu {
    /// 在某个控件的正下方弹出菜单（左边缘对齐该控件）。
    /// 两个坑：拿「整条工具条 + x=0」当锚点会把菜单飞到面板最左边；
    /// 拿 bounds.height 直接拼点位在翻转视图（isFlipped）下 y 轴是反的。
    /// 这里统一换算到窗口基坐标（y 向上，rect.minY 就是下边缘），再交给 contentView 坐标系。
    func popUp(under anchor: NSView) {
        guard let point = Self.popPoint(under: anchor),
              let content = anchor.window?.contentView else { return }
        popUp(positioning: nil, at: point, in: content)
    }

    /// 锚点换算单独拆出来：自检可以在不真弹菜单的情况下验证点位落在被点的键上
    static func popPoint(under anchor: NSView) -> NSPoint? {
        guard let win = anchor.window, let content = win.contentView else { return nil }
        let rect = anchor.convert(anchor.bounds, to: nil)
        return content.convert(NSPoint(x: rect.minX, y: rect.minY), from: nil)
    }
}

// MARK: - 透明度滑块（右键菜单内嵌控件）

/// 放在 NSMenuItem.view 里的水平滑块，左侧显示“透明度”标签，右侧实时显示百分比。
/// 拖动时调用 onChange，不关闭菜单。
final class TransparencySliderView: NSView {
    var onChange: ((Float) -> Void)?
    private let slider = NSSlider()
    private let label = NSTextField(labelWithString: "透明度")
    private let percent = NSTextField(labelWithString: "")

    init(value: Float) {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
        label.font = NSFont.systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = Double(value)
        slider.target = self
        slider.action = #selector(changed)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.controlSize = .small
        addSubview(slider)

        percent.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        percent.alignment = .right
        percent.translatesAutoresizingMaskIntoConstraints = false
        percent.stringValue = "\(Int(value * 100))%"
        addSubview(percent)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            percent.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 6),
            percent.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            percent.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() {
        let v = Float(slider.doubleValue)
        percent.stringValue = "\(Int(v * 100))%"
        onChange?(v)
    }
}
