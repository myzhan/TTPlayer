import AppKit

/// 封面视图：显示区左上那一格与大图窗共用一套画法（圆角 + 外圈压深 + 顶边内高光），
/// 让封面像是贴在玻璃槽里，而不是随便悬着一张方图。没有封面时画一张光盘占位，不留黑洞
final class CoverView: NSView {
    /// 当前封面；nil 表示画占位光盘
    var image: NSImage? { didSet { needsDisplay = true } }
    /// 贴的是哪一张封面（共享键，空 = 占位光盘）。供自检比对“贴的是不是当前曲的封面”：
    /// 大图窗贴的是按需解出来的大档，跟曲目上的小档不是同一个实例，只能比键
    var coverKey: String = ""
    /// 点这张封面要干什么（显示区拿它弹大图窗；不设置就不响应点击）
    var onClick: (() -> Void)? {
        didSet { toolTip = onClick == nil ? nil : "点击查看大封面" }
    }

    /// 圆角：显示区 56 那一格用 3，大图窗 240 用 6
    var cornerRadius: CGFloat = 3 { didSet { needsDisplay = true } }

    /// 自绘视图必须自己报固有尺寸，否则没钉宽高的场合会被压成 0（见开发规范）
    static let defaultSide: CGFloat = 56
    override var intrinsicContentSize: NSSize { NSSize(width: Self.defaultSide, height: Self.defaultSide) }
    override var isFlipped: Bool { true }

    /// 供自检：贴的是真封面，还是占位光盘
    var showsCoverImage: Bool { image != nil }

    override func draw(_ dirtyRect: NSRect) {
        // 布局完成前可能以零尺寸被要求绘制：空路径取 bounds/stroke 都会抛异常
        guard bounds.width > 3, bounds.height > 3 else { return }
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: cornerRadius, yRadius: cornerRadius)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        // 底用显示区同款的深蓝灰：封面不是正方形时四周露出来的就是它
        let wA = GlassStyle.enabled ? GlassStyle.wellAlpha : 1
        NSGradient(colors: [Theme.wellTop.withAlphaComponent(Theme.wellTop.alphaComponent * wA),
                            Theme.wellBottom.withAlphaComponent(Theme.wellBottom.alphaComponent * wA)])?
            .draw(in: box, angle: -90)
        if let image { drawCover(image, in: box) } else { drawDisc(in: box) }
        NSGraphicsContext.restoreGraphicsState()
        Theme.wellBevelDark.setStroke()
        path.lineWidth = 1
        path.stroke()
        Theme.innerHighlight.setFill()
        NSRect(x: 1, y: 1, width: max(1, box.width - 2), height: 1).fill()
    }

    /// 完整显示不裁边（专辑封面上的字被切掉半张比留边更难看）
    private func drawCover(_ image: NSImage, in box: NSRect) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let factor = min(box.width / size.width, box.height / size.height)
        let w = size.width * factor
        let h = size.height * factor
        let rect = NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.medium.rawValue])
    }

    /// 占位光盘：两道数据圈 + 中心孔 + 一层斜向高光
    private func drawDisc(in box: NSRect) {
        let side = min(box.width, box.height)
        let center = NSPoint(x: box.midX, y: box.midY)
        let outer = side * 0.42
        let discRect = NSRect(x: center.x - outer, y: center.y - outer,
                              width: outer * 2, height: outer * 2)
        let disc = NSBezierPath(ovalIn: discRect)
        NSGradient(starting: NSColor.hex(0xC3D6EA), ending: NSColor.hex(0x6B86A6))?
            .draw(in: disc, angle: -60)
        Theme.wellBevelDark.withAlphaComponent(0.75).setStroke()
        disc.lineWidth = 1
        disc.stroke()

        NSColor(calibratedWhite: 1, alpha: 0.30).setStroke()
        for ratio in [0.34, 0.66] as [CGFloat] {
            let r = outer * ratio
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r,
                                                   width: r * 2, height: r * 2))
            ring.lineWidth = 1
            ring.stroke()
        }

        let hole = outer * 0.17
        Theme.groove.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - hole, y: center.y - hole,
                                    width: hole * 2, height: hole * 2)).fill()
        Theme.wellBevelLight.withAlphaComponent(0.6).setStroke()
        let edge = NSBezierPath(ovalIn: NSRect(x: center.x - hole - 0.5, y: center.y - hole - 0.5,
                                               width: hole * 2 + 1, height: hole * 2 + 1))
        edge.lineWidth = 1
        edge.stroke()
    }

    override func mouseUp(with event: NSEvent) {
        guard onClick != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }     // 按住拖出去再松开不算点
        onClick?()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
}
