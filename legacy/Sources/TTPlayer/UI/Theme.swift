import AppKit

extension NSColor {
    /// 从截图取色用的 0xRRGGBB 构造器
    static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }
}

/// 皮肤配色：照抄经典千千静听官方皮肤的蓝灰玻璃质感
/// 外壳/标题条/传输键是浅色玻璃，显示区/列表/均衡器/歌词是内嵌的深蓝灰玻璃槽
enum Theme {
    // MARK: - 面板外壳（浅蓝灰玻璃）
    static let windowTop = NSColor.hex(0xEAF1F9)
    static let windowBottom = NSColor.hex(0xAFC2D8)
    static let panel = NSColor.hex(0xC6D6E7)

    /// 皮肤外描边（截图里每个面板都有一圈近白的细边）
    static let skinEdge = NSColor.hex(0xF8FBFF)
    static let innerHighlight = NSColor(calibratedWhite: 1, alpha: 0.55)
    /// 浅玻璃面板之间的分隔线/压边
    static let shellDivider = NSColor.hex(0x8AA2BD)

    // MARK: - 标题条
    static let titleTop = NSColor.hex(0xF6FAFE)
    static let titleBottom = NSColor.hex(0xC5D5E8)
    /// 标题条上的深色文字（浅底）
    static let titleText = NSColor.hex(0x223A57)

    // MARK: - 内嵌深蓝灰槽（显示区 / 列表 / 均衡器 / 歌词）
    static let wellTop = NSColor.hex(0x51667F)
    static let wellBottom = NSColor.hex(0x3A4E66)
    static let listBackground = NSColor.hex(0x40566F)
    static let wellBevelDark = NSColor.hex(0x27394D)
    static let wellBevelLight = NSColor.hex(0x9BB3CC)
    static let groove = NSColor.hex(0x2B3D51)

    // MARK: - 文字（深底上用亮字）
    static let textPrimary = NSColor.hex(0xEFF5FC)
    static let textSecondary = NSColor.hex(0xA9BED4)
    static let textAccent = NSColor.hex(0x8CCDFF)      // 正在播放 / 高亮
    static let textHighlight = NSColor.hex(0xFFFFFF)

    // MARK: - 控件（浅玻璃按钮）
    static let buttonTop = NSColor.hex(0xF7FBFF)
    static let buttonBottom = NSColor.hex(0xC4D5E8)
    /// 凸起按钮的三段面（顶白 → 中浅蓝 → 底灰蓝）。
    /// 两段线性渐变压在 20pt 高的键上，中间几乎没有变化，会被读成“嵌在面板里的浅坑”；
    /// 中途补一道过渡色，才有“鼓起来”的弧度。
    static let buttonLightTop = NSColor.hex(0xFFFFFF)
    static let buttonLightMid = NSColor.hex(0xE9F3FC)
    static let buttonLightBottom = NSColor.hex(0xB7CBE1)
    /// 按下（凹下去）时的三段：光的方向反过来，上暗下亮
    static let buttonDownTop = NSColor.hex(0xAFC4D9)
    static let buttonDownMid = NSColor.hex(0xC8D9E9)
    static let buttonDownBottom = NSColor.hex(0xF2F8FE)
    static let buttonHotTop = NSColor.hex(0xFFFFFF)
    static let buttonHotBottom = NSColor.hex(0xDCEAF8)
    static let buttonFace = NSColor.hex(0xDCE8F4)
    static let buttonHot = NSColor.hex(0xEEF6FF)
    static let buttonPressed = NSColor.hex(0xA9BED4)
    static let buttonEdge = NSColor.hex(0x7B95B1)
    static let border = NSColor.hex(0x6E88A4)
    /// 扁平文字按钮（显示区底部的「列表/均衡器/歌词」，深底）
    static let flatText = NSColor.hex(0xF0F6FC)
    static let flatTextHot = NSColor.hex(0xFFFFFF)
    static let flatHotBG = NSColor.hex(0x7FA0C2, 0.55)
    static let flatEdgeHot = NSColor.hex(0xBFD8EE, 0.8)
    /// 浅底面板上的扁平文字按钮（列表工具条）
    static let flatTextOnLight = NSColor.hex(0x2C4664)
    static let flatTextOnLightHot = NSColor.hex(0x0F2C4D)
    static let flatHotOnLightBG = NSColor.hex(0xC7DDF2, 0.9)

    // MARK: - 频谱（蓝白柱）
    static let spectrumTop = NSColor.hex(0xBFE4FF)
    static let spectrumBottom = NSColor.hex(0x3F79AE)
    static let spectrumPeak = NSColor.hex(0xFFFFFF)
    static let spectrumGrid = NSColor(calibratedWhite: 1, alpha: 0.07)

    // MARK: - 电平表
    static let meterGreen = NSColor.hex(0x86D98F)
    static let meterYellow = NSColor.hex(0xF0DC82)
    static let meterRed = NSColor.hex(0xE88C7A)

    static func windowGradient() -> NSGradient {
        NSGradient(starting: windowTop, ending: windowBottom) ?? NSGradient(colors: [windowBottom])!
    }

    static func titleGradient() -> NSGradient {
        NSGradient(starting: titleTop, ending: titleBottom) ?? NSGradient(colors: [titleBottom])!
    }

    static func buttonGradient(hot: Bool = false, pressed: Bool = false) -> NSGradient {
        if pressed {
            return NSGradient(starting: buttonPressed, ending: buttonTop)
                ?? NSGradient(colors: [buttonPressed])!
        }
        return NSGradient(starting: hot ? buttonHotTop : buttonTop,
                          ending: hot ? buttonHotBottom : buttonBottom)
            ?? NSGradient(colors: [buttonBottom])!
    }

    // MARK: - 字体
    static let baseFont = NSFont.systemFont(ofSize: 13)
    static let smallFont = NSFont.systemFont(ofSize: 12)
    static let tinyFont = NSFont.systemFont(ofSize: 11)
    static let titleFont = NSFont.boldSystemFont(ofSize: 13)
    /// 面板标题条文字
    static let panelTitleFont = NSFont.boldSystemFont(ofSize: 13)
}

// MARK: - 玻璃质感开关

/// 半透明玻璃的全局开关与参数。
///
/// 为什么做成全局而不是每个窗口自己存：三窗是竖排一体的，只要有一个面板
/// 不透明，缝隙处就会看出一条“实心块”，半透明会显得只做了一半。
enum GlassStyle {
    /// 用户可调节的透明度主参数（0 = 完全透明，1 = 完全不透明），默认 0.15。
    /// 壳层/按钮直接用它，内嵌槽在它基础上 +0.10（给白字留对比）。
    private(set) static var transparency: CGFloat = 0.15

    /// 壳层不透明度：等于 transparency
    static var bodyAlpha: CGFloat { transparency }
    /// 内嵌深底槽不透明度：比壳层多一点，保证文字可读
    static var wellAlpha: CGFloat { min(transparency + 0.10, 1.0) }
    /// 玻璃按钮不透明度：与壳层一致，靠描边标识按钮
    static var buttonAlpha: CGFloat { transparency }

    private(set) static var enabled = true
    static let didChange = Notification.Name("ttplayer.glassStyleChanged")

    static func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func setTransparency(_ value: CGFloat) {
        let clamped = max(0, min(1, value))
        guard abs(clamped - transparency) > 0.001 else { return }
        transparency = clamped
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

/// 通用渐变背景视图；可选圆角 + 外描边 + 内侧高光 + 上半玻璃高光（aqua 质感）
class GradientView: NSView {
    var colors: [NSColor] = [Theme.windowTop, Theme.windowBottom] { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0
    /// 外 1px 描边颜色，nil 表示不描边
    var edgeColor: NSColor?
    /// 内侧 1px 高光（上边与左边）
    var innerHighlight = false
    /// 上半覆盖一层白色渐隐高光，做出玻璃反光
    var gloss = false
    /// 参与半透明玻璃：底色按 `GlassStyle` 乘上 alpha，并会随着开关变化重绘
    var glassBody = false { didSet { installGlassObserver(); needsDisplay = true } }
    /// 子类可以设这个值来用不同的 alpha（比如按钮带用 buttonAlpha、底部条用 wellAlpha）；
    /// nil 表示用默认的 GlassStyle.bodyAlpha
    var glassAlphaOverride: CGFloat?
    /// 实际使用的底色不透明度：1 = 原版不透明皮肤，其余为半透明
    var bodyAlpha: CGFloat {
        guard glassBody && GlassStyle.enabled else { return 1 }
        return glassAlphaOverride ?? GlassStyle.bodyAlpha
    }

    private var glassObserver: NSObjectProtocol?

    deinit {
        if let observer = glassObserver { NotificationCenter.default.removeObserver(observer) }
    }

    /// 只在真的用到玻璃效果时才监听开关，普通渐变视图不付这份成本
    private func installGlassObserver() {
        guard glassObserver == nil else { return }
        glassObserver = NotificationCenter.default.addObserver(
            forName: GlassStyle.didChange, object: nil, queue: .main) { [weak self] _ in
                self?.needsDisplay = true
            }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // 自动布局完成前，视图可能以零尺寸被要求绘制；
        // 此时 NSBezierPath(roundedRect:) 会退化成空路径，取 .bounds / stroke 都会抛异常。
        guard bounds.width > 1, bounds.height > 1 else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let alpha = bodyAlpha
        let body = alpha < 0.999
            ? colors.map { $0.withAlphaComponent($0.alphaComponent * alpha) }
            : colors
        if let gradient = NSGradient(colors: body) {
            gradient.draw(in: bounds, angle: -90)
        }
        if gloss, bounds.height > 8 {
            let shineH = max(1, bounds.height * 0.45)
            NSGradient(starting: NSColor(calibratedWhite: 1, alpha: 0.42 * min(1, alpha + 0.08)),
                       ending: NSColor(calibratedWhite: 1, alpha: 0.02))?
                .draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: shineH), angle: -90)
        }
        if innerHighlight {
            Theme.innerHighlight.setFill()
            NSRect(x: 1, y: 1, width: bounds.width - 2, height: 1).fill()
            NSRect(x: 1, y: 1, width: 1, height: bounds.height - 2).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        if let edge = edgeColor {
            edge.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

/// 内嵌凹陷槽：显示区、列表、均衡器、歌词共用的深蓝灰玻璃底
final class WellView: NSView {
    var cornerRadius: CGFloat = 3
    /// 是否绘制顶部频率刻度网格（频谱区用）
    var showGrid = false
    var gridColumns = 0
    /// 深底（列表区用略深的色调）
    var dark = false
    private var glassObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glassObserver = NotificationCenter.default.addObserver(
            forName: GlassStyle.didChange, object: nil, queue: .main) { [weak self] _ in
                self?.needsDisplay = true
            }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let o = glassObserver { NotificationCenter.default.removeObserver(o) }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 3, bounds.height > 3 else { return }
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        let top = dark ? Theme.wellBevelDark.blended(withFraction: 0.45, of: Theme.wellTop) ?? Theme.wellBevelDark
                       : Theme.wellTop
        let bottom = dark ? Theme.listBackground : Theme.wellBottom
        // 玻璃开启时把内嵌槽也按 wellAlpha 透一下：不留任何透明度时“全界面透明”就只是壳透、
        // 列表/频谱/歌词三块还是实色深蓝，不统一。bevel 描边保持不透明，确保“凹槽”轮廓还在。
        let wellA: CGFloat = GlassStyle.enabled ? GlassStyle.wellAlpha : 1
        let topDraw = top.withAlphaComponent(top.alphaComponent * wellA)
        let bottomDraw = bottom.withAlphaComponent(bottom.alphaComponent * wellA)
        NSGradient(starting: topDraw, ending: bottomDraw)?
            .draw(in: path, angle: -90)
        // 上沿压深、下沿打亮 → 视觉凹陷
        Theme.wellBevelDark.setStroke()
        path.lineWidth = 1
        path.stroke()
        Theme.wellBevelLight.withAlphaComponent(0.30).setStroke()
        let innerRect = rect.insetBy(dx: 1, dy: 1)
        if innerRect.width > 0, innerRect.height > 0 {
            let inner = NSBezierPath(roundedRect: innerRect,
                                     xRadius: cornerRadius, yRadius: cornerRadius)
            inner.lineWidth = 1
            inner.stroke()
        }

        if showGrid {
            Theme.spectrumGrid.setFill()
            for i in 1..<5 {
                NSRect(x: 2, y: rect.height * CGFloat(i) / 5,
                       width: rect.width - 4, height: 1).fill()
            }
            for i in 1..<max(2, gridColumns) {
                NSRect(x: rect.width * CGFloat(i) / CGFloat(gridColumns), y: 2,
                       width: 1, height: rect.height - 4).fill()
            }
        }
    }
}

/// 皮肤按钮：浅玻璃方块（标题栏/传输条）与扁平文字（显示区底部、列表工具条）两种面
final class TTButton: NSButton {
    enum Content {
        case symbol(String)          // SF Symbol
        case title(String)           // 文字
        case badge(String, String?)  // 圆形徽章（单字 + 可选 tooltip）
    }
    enum Face {
        case glass       // 浅蓝灰玻璃贴片
        case flat        // 平时透明，悬停才出底（深底上的文字快捷键）
        case flatOnLight // 同上，但用于浅灰面板（列表工具条），字为深色
        case none        // 完全不画底（只有内容）
    }

    var content: Content = .symbol("play.fill") { didSet { needsDisplay = true } }
    var face: Face = .glass { didSet { needsDisplay = true } }
    var isHot = false { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 3
    /// 高亮状态（如均衡器开启、非顺序播放模式）
    var lit: Bool = false { didSet { needsDisplay = true } }
    /// 内容缩放（传输条中间的大播放键用）
    var glyphScale: CGFloat = 0.62 { didSet { needsDisplay = true } }
    /// 自绘按钮没有标题，必须自己报一个固有尺寸，
    /// 否则关掉 translatesAutoresizingMaskIntoConstraints 后会撑成 0×0（按钮看不见）
    var preferredSize = NSSize(width: 32, height: 24) {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: NSSize { preferredSize }
    /// 按下状态（自绘按钮自行跟踪）
    private var pressed = false

    override func mouseDown(with event: NSEvent) {
        pressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        needsDisplay = true
        if inside, let action { NSApp.sendAction(action, to: target, from: self) }
    }

    private var trackingAreaRef: NSTrackingArea?

    convenience init(_ content: Content, target: AnyObject?, action: Selector?,
                     size: NSSize = NSSize(width: 32, height: 24), face: Face = .glass) {
        self.init(frame: NSRect(origin: .zero, size: size))
        self.content = content
        self.face = face
        self.preferredSize = size
        self.target = target
        self.action = action
        self.isBordered = false
        self.title = ""
        self.setButtonType(.momentaryChange)
        if face == .glass {
            glassObs = NotificationCenter.default.addObserver(
                forName: GlassStyle.didChange, object: nil, queue: .main) { [weak self] _ in
                    self?.needsDisplay = true
                }
        }
    }

    private var glassObs: NSObjectProtocol?
    deinit { if let o = glassObs { NotificationCenter.default.removeObserver(o) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseEntered(with event: NSEvent) { isHot = true }
    override func mouseExited(with event: NSEvent) { isHot = false }

    override func draw(_ dirtyRect: NSRect) {
        // 零/缩小尺寸下 roundedRect 会变成空路径，后续取 bounds 会抛异常，直接跳过绘制。
        guard bounds.width > 3, bounds.height > 3 else { return }
        let frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = min(cornerRadius, frame.height / 2)
        let path = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)

        switch face {
        case .glass:
            // 凸起的玻璃砖：三段渐变 + 上沿强高光 + 上半白渐隐 + 下沿压深。
            // 只给“两段渐变 + 顶部 1px 白线”时，四周那圈深描边会占据视觉，
            // 整个键读成“挖出来又填平的坑”；厚度感全靠这几层明暗叠出来。
            let stops: [CGFloat] = [0, 0.45, 1]
            let bA = GlassStyle.enabled ? GlassStyle.buttonAlpha : 1
            let faceColors: [NSColor] = (pressed
                ? [Theme.buttonDownTop, Theme.buttonDownMid, Theme.buttonDownBottom]
                : [Theme.buttonLightTop, Theme.buttonLightMid, Theme.buttonLightBottom])
                .map { $0.withAlphaComponent($0.alphaComponent * bA) }
            NSGradient(colors: faceColors, atLocations: stops, colorSpace: .deviceRGB)?
                .draw(in: path, angle: -90)

            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            // 开启态（lit）压一层淡蓝：灰玻璃上一道蓝边太弱，开关要一眼看得出来
            if lit {
                Theme.textAccent.withAlphaComponent(0.20).setFill()
                path.fill()
            }
            // 悬停：整体提亮一档（原来靠换一组更亮的渐变色，现在叠一层白）
            if isHot, !pressed {
                NSColor(calibratedWhite: 1, alpha: 0.10).setFill()
                path.fill()
            }
            let inner = frame.insetBy(dx: 1, dy: 1)
            if !pressed, inner.height > 4 {
                // 上半层白渐隐：光从上方打下来的高光区，不带就不像鼓起
                NSGradient(colors: [NSColor(calibratedWhite: 1, alpha: 0.55),
                                    NSColor(calibratedWhite: 1, alpha: 0.015)],
                           atLocations: [0, 1], colorSpace: .deviceRGB)?
                    .draw(in: NSRect(x: inner.minX, y: inner.minY,
                                     width: inner.width, height: inner.height * 0.55), angle: -90)
            }
            // 上沿 1px 强高光（小按钮上多这一道，体积感差很多）
            NSColor(calibratedWhite: 1, alpha: pressed ? 0.25 : 0.92).setFill()
            let highlightY = isFlipped ? inner.minY : inner.maxY - 1
            NSRect(x: inner.minX + 1, y: highlightY,
                   width: max(0, inner.width - 2), height: 1).fill()
            // 第二像素补一道半透白：头顶变“厚”，才不会只剩一条白线
            if !pressed, inner.height > 10 {
                NSColor(calibratedWhite: 1, alpha: 0.45).setFill()
                NSRect(x: inner.minX + 1, y: highlightY + (isFlipped ? 1 : -1),
                       width: max(0, inner.width - 2), height: 1).fill()
            }
            // 下沿压深：背光面收口，按钮才“落”在自己身上而不是浮着
            Theme.shellDivider.withAlphaComponent(pressed ? 0.30 : 0.55).setFill()
            let shadowY = isFlipped ? inner.maxY - 1 : inner.minY
            NSRect(x: inner.minX + 1, y: shadowY,
                   width: max(0, inner.width - 2), height: 1).fill()
            NSGraphicsContext.restoreGraphicsState()

            (lit ? Theme.textAccent : Theme.buttonEdge).setStroke()
            path.lineWidth = 1
            path.stroke()
        case .flat, .flatOnLight:
            guard isHot || pressed || lit else { break }
            let onLight = face == .flatOnLight
            let bg = pressed ? Theme.buttonPressed
                : (onLight ? Theme.flatHotOnLightBG : Theme.flatHotBG)
            bg.setFill()
            path.fill()
            (onLight ? Theme.buttonEdge : Theme.flatEdgeHot).setStroke()
            path.lineWidth = 1
            path.stroke()
        case .none:
            // 贴在玻璃带里的分格：自己不画底，只在悬停/按下时压一层淡色
            guard isHot || pressed else { break }
            (pressed ? Theme.buttonPressed : Theme.flatHotBG)
                .withAlphaComponent(pressed ? 0.75 : 0.45).setFill()
            path.fill()
        }

        let fg: NSColor
        switch (face, lit, isHot) {
        // 玻璃贴片与玻璃带分格：都是浅蓝灰底，沿用深字
        case (.glass, true, _), (.none, true, _): fg = NSColor.hex(0x1B4F7B)
        case (.glass, false, true), (.none, _, true): fg = NSColor.hex(0x14304E)
        case (.glass, false, false), (.none, _, _): fg = NSColor.hex(0x2A4463)
        case (.flat, _, _): fg = lit ? Theme.textAccent : (isHot ? Theme.flatTextHot : Theme.flatText)
        case (.flatOnLight, true, _): fg = NSColor.hex(0x14497A)
        case (.flatOnLight, _, _): fg = isHot ? Theme.flatTextOnLightHot : Theme.flatTextOnLight
        }
        drawContent(in: bounds, color: fg)
    }

    private func drawContent(in rect: NSRect, color: NSColor) {
        switch content {
        case .symbol(let name):
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil),
                  image.size.width > 0, image.size.height > 0 else { return }
            let s = image.size
            let scale = min(rect.width * glyphScale / s.width, rect.height * glyphScale / s.height)
            let drawSize = NSSize(width: max(1, (s.width * scale).rounded()),
                                  height: max(1, (s.height * scale).rounded()))
            let drawRect = NSRect(x: rect.midX - drawSize.width / 2,
                                  y: rect.midY - drawSize.height / 2,
                                  width: drawSize.width, height: drawSize.height)
            let tinted = NSImage(size: drawSize, flipped: false) { _ in
                image.draw(in: NSRect(origin: .zero, size: drawSize))
                color.set()
                NSRect(origin: .zero, size: drawSize).fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0,
                        respectFlipped: true, hints: nil)
        case .title(let t):
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Theme.tinyFont,
                .foregroundColor: color,
                .paragraphStyle: style,
            ]
            let str = NSAttributedString(string: t, attributes: attrs)
            let sz = str.size()
            str.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
        case .badge(let text, _):
            let diameter = max(1, min(rect.width, rect.height) - 5)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let circle = NSBezierPath(ovalIn: NSRect(x: center.x - diameter / 2,
                                                     y: center.y - diameter / 2,
                                                     width: diameter, height: diameter))
            (lit ? Theme.textAccent : Theme.buttonHot).setFill()
            circle.fill()
            Theme.buttonEdge.withAlphaComponent(0.8).setStroke()
            circle.lineWidth = 1
            circle.stroke()
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: diameter * 0.60, weight: .bold),
                .foregroundColor: lit ? NSColor.hex(0x0E2B45) : Theme.titleText,
                .paragraphStyle: style,
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            let sz = str.size()
            str.draw(at: NSPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2))
        }
    }
}
