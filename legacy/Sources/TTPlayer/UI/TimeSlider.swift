import AppKit

/// 类千千静听进度条：凹陷细槽 + 绿色已播段 + 金色游标竖条，支持点击/拖动 seek
final class TimeSlider: NSControl {
    private(set) var progress: Double = 0   // 0...1
    var isDragging = false
    private var dragValue: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
    }

    required init?(coder: NSCoder) { fatalError() }

    var isHot = false { didSet { needsDisplay = true } }

    override func mouseEntered(with event: NSEvent) { isHot = true }
    override func mouseExited(with event: NSEvent) { isHot = false }

    func setProgress(_ value: Double) {
        guard !isDragging else { return }
        progress = max(0, min(1, value))
        needsDisplay = true
    }

    private let trackHeight: CGFloat = 7

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 1, bounds.height > trackHeight else { return }
        let v = isDragging ? dragValue : progress
        let groove = NSRect(x: 0, y: (bounds.height - trackHeight) / 2,
                            width: bounds.width, height: trackHeight)
        let groovePath = NSBezierPath(roundedRect: groove, xRadius: 2.5, yRadius: 2.5)
        Theme.groove.setFill()
        groovePath.fill()
        Theme.wellBevelDark.setStroke()
        groovePath.lineWidth = 1
        groovePath.stroke()

        let fillW = max(0, min(bounds.width, bounds.width * CGFloat(v)))
        if fillW > 1 {
            let fillRect = NSRect(x: 0, y: groove.minY, width: fillW, height: trackHeight)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 2.5, yRadius: 2.5)
            NSGradient(colors: [Theme.spectrumBottom, Theme.textAccent])?
                .draw(in: fillPath, angle: -90)
        }
        // 分段刻度，像皮肤上的时间格
        Theme.wellBevelDark.withAlphaComponent(0.55).setFill()
        for i in 1..<4 {
            NSRect(x: groove.width * CGFloat(i) / 4, y: groove.minY + 1,
                   width: 1, height: groove.height - 2).fill()
        }

        // 游标：竖细条 + 暗描边
        let knobW: CGFloat = 4
        let kx = min(max(0, fillW - knobW / 2), bounds.width - knobW)
        let knob = NSRect(x: kx, y: 1, width: knobW, height: bounds.height - 2)
        (isHot ? NSColor.white : Theme.textHighlight).setFill()
        knob.fill()
        Theme.border.withAlphaComponent(0.7).setStroke()
        let knobPath = NSBezierPath(rect: knob.insetBy(dx: -0.5, dy: -0.5))
        knobPath.lineWidth = 1
        knobPath.stroke()
    }

    // MARK: - 交互

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        dragValue = value(from: event)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        dragValue = value(from: event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        progress = dragValue
        sendAction(action, to: target)
        needsDisplay = true
    }

    /// 拖动结束时通过对象携带秒值（由 ControlBar 换算 duration 也可自行读取）
    var secondsValue: Double { (isDragging ? dragValue : progress) }

    private func value(from event: NSEvent) -> Double {
        let p = convert(event.locationInWindow, from: nil)
        return max(0, min(1, Double(p.x / bounds.width)))
    }
}
