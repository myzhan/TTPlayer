import AppKit

/// 千千静听风格的频谱视图：左侧 64 条渐变柱状频谱 + 顶部峰值帽，右侧 L/R 分段电平表
final class SpectrumView: NSView {
    private static let spectrumGradient = NSGradient(colors: [Theme.spectrumBottom, Theme.spectrumTop])
    private static let meterLabelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 8),
        .foregroundColor: Theme.textSecondary,
    ]
    private static let meterLabels = ["L", "R"].map {
        NSAttributedString(string: $0, attributes: meterLabelAttributes)
    }
    private static let dimMeterColors = [Theme.meterGreen, Theme.meterYellow, Theme.meterRed]
        .map { $0.withAlphaComponent(0.15) }

    private let analyzer: SpectrumAnalyzer
    private var displayTimer: Timer?
    private var wantsAnimation = false
    private var occlusionObserver: NSObjectProtocol?

    // 峰值帽（每根柱子的落顶指示）
    private var peaks: [Float]
    private let peakDecay: Float = 0.018

    // 电平表平滑值
    private var meterL: Float = 0
    private var meterR: Float = 0

    private let barCount = SpectrumAnalyzer.barCount
    private let meterSegments = 24

    init(analyzer: SpectrumAnalyzer) {
        self.analyzer = analyzer
        self.peaks = [Float](repeating: 0, count: barCount)
        super.init(frame: .zero)
        // 凹陷背景与网格由外层 WellView 绘制，这里只画谱线与电平。
        // 必须自成一个图层：外层 skinRoot 是 layer-backed，混入一个非图层子视图会让 AppKit 每帧
        // 重绘整个面板背景，30fps 下这笔开销比画频谱本身还大。
        wantsLayer = true
        // 是否分析由 viewDidMoveToWindow / 播放状态决定；创建离屏绘制视图不能清掉输入数据。
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in self?.applyAnimationState() }
        }
        applyAnimationState()
    }

    func startAnimating() {
        wantsAnimation = true
        applyAnimationState()
    }

    private func applyAnimationState() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        guard wantsAnimation && visible else {
            displayTimer?.invalidate()
            displayTimer = nil
            analyzer.setEnabled(false)
            return
        }
        analyzer.setEnabled(true)
        guard displayTimer == nil else { return }
        // AppKit/图层提交的固定成本远大于画柱子本身。16fps 对频谱已经足够流畅，
        // 相比原来的 24fps 少三分之一主线程唤醒；FFT 也只在真正可见时运行。
        let t = Timer(timeInterval: 1.0 / 16.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        displayTimer = t
    }

    func stopAnimating() {
        wantsAnimation = false
        displayTimer?.invalidate()
        displayTimer = nil
        analyzer.setEnabled(false)
        for i in peaks.indices { peaks[i] = 0 }
        for i in lastBars.indices { lastBars[i] = 0 }
        meterL = 0
        meterR = 0
        drawnIdle = false
        needsDisplay = true
    }

    /// 动画与离屏回归共用的逐帧入口。
    func tick() {
        // 看不见就不画：窗口被盖住、最小化或熄屏时，任何重绘与 FFT 都是浪费。
        if let w = window, !w.occlusionState.contains(.visible) {
            applyAnimationState()
            return
        }
        let bars = analyzer.bars
        var changed = false
        let scale = window?.backingScaleFactor ?? 2
        let height = max(1, bounds.height - 6) * scale
        // 小于一个物理像素的波动不需要重新光栅化、提交整个图层。
        func pixel(_ value: Float) -> Int { Int((CGFloat(value) * height).rounded()) }
        for i in 0..<barCount {
            let v = bars[i]
            let peak = max(v, peaks[i] - peakDecay)
            if pixel(peak) != pixel(peaks[i]) { changed = true }
            peaks[i] = peak
            if pixel(v) != pixel(lastBars[i]) { changed = true }
        }
        let levels = analyzer.levels
        let nextL = max(levels.left, meterL * 0.90)
        let nextR = max(levels.right, meterR * 0.90)
        func segments(_ value: Float) -> Int {
            Int((min(1, max(0, value)) * Float(meterSegments)).rounded())
        }
        if segments(nextL) != segments(meterL) || segments(nextR) != segments(meterR) {
            changed = true
        }
        meterL = nextL
        meterR = nextR
        // 无信号且峰值已落到底时不重绘，省电
        let idle = bars.allSatisfy { $0 < 0.002 } && levels.left < 0.005 && levels.right < 0.005
            && peaks.allSatisfy { $0 < 0.002 }
        if changed && !idle {
            lastBars = bars
            needsDisplay = true
        } else if idle && !drawnIdle {
            drawnIdle = true
            needsDisplay = true
        }
    }

    private var lastBars: [Float] = Array(repeating: 0, count: SpectrumAnalyzer.barCount)
    private var drawnIdle = false

    override func draw(_ dirtyRect: NSRect) {
        // 布局未定型时尺寸可能为 0/负，渐变绘制会抛异常，直接跳过
        guard bounds.width > 20, bounds.height > 20 else { return }
        drawnIdle = analyzer.bars.allSatisfy { $0 < 0.002 }
        drawSpectrum()
        drawLevelMeters()
    }

    private func drawSpectrum() {
        let meterWidth = min(150.0, bounds.width * 0.26)
        let area = NSRect(x: 3, y: 3, width: bounds.width - meterWidth - 7, height: bounds.height - 6)
        let bars = analyzer.bars
        let gap: CGFloat = 1
        let barW = (area.width - gap * CGFloat(barCount - 1)) / CGFloat(barCount)
        guard barW > 0.1, area.height > 1 else { return }
        let isFlipped = self.isFlipped

        // 64 根柱子各画一条渐变 = 64 次光栅化，是播放时单核里最大的一笔开销（实测占掉一半以上）。
        // 改成“一条整块渐变按柱子路径裁一次 + 柱尖高光一次填充”，观感不变，成本降到约 1/3。
        let bodyPath = NSBezierPath()
        let tipPath = NSBezierPath()
        let capPath = NSBezierPath()
        for i in 0..<barCount {
            let v = max(0.004, bars[i])
            let x = area.minX + CGFloat(i) * (barW + gap)
            let h = max(2, area.height * CGFloat(v))
            let tipH = min(3, h)
            let peakY: CGFloat
            if isFlipped {
                bodyPath.appendRect(NSRect(x: x, y: area.maxY - h, width: barW, height: h))
                tipPath.appendRect(NSRect(x: x, y: area.maxY - h, width: barW, height: tipH))
                peakY = area.maxY - CGFloat(peaks[i]) * area.height
            } else {
                bodyPath.appendRect(NSRect(x: x, y: area.minY, width: barW, height: h))
                tipPath.appendRect(NSRect(x: x, y: area.minY + h - tipH, width: barW, height: tipH))
                peakY = area.minY + CGFloat(peaks[i]) * area.height
            }
            // 峰值帽
            let capRect = NSRect(x: x, y: peakY, width: barW, height: 2).intersection(area)
            if !capRect.isNull, peaks[i] > 0.01 { capPath.appendRect(capRect) }
        }

        if let gradient = Self.spectrumGradient {
            NSGraphicsContext.saveGraphicsState()
            bodyPath.addClip()
            gradient.draw(in: area, angle: isFlipped ? -90 : 90)
            NSGraphicsContext.restoreGraphicsState()
        }
        // 柱尖高光：渐变按整块裁剪后，短柱只剩低段颜色，补一条顶端亮边保住“每根柱子尖上发亮”的观感
        Theme.spectrumTop.setFill()
        tipPath.fill()
        Theme.spectrumPeak.setFill()
        capPath.fill()
    }

    private func drawLevelMeters() {
        let meterWidth = min(150.0, bounds.width * 0.26)
        let area = NSRect(x: bounds.width - meterWidth - 3, y: 3,
                          width: meterWidth, height: bounds.height - 6)
        let levels = analyzer.levels
        // 动画的平滑在 tick 中推进，不能依赖 draw 的调用次数；离屏自检直接取输入。
        if !wantsAnimation {
            meterL = levels.left
            meterR = levels.right
        }

        let segGap: CGFloat = 1
        let segW = (area.width - segGap * CGFloat(meterSegments - 1)) / CGFloat(meterSegments)
        let rowH = max(6, (area.height - 14) / 2)
        guard segW > 0.1, area.height > 10 else { return }
        let channels: [(Float, CGFloat, Int)] = [
            (meterL, area.maxY - rowH, 0),
            (meterR, area.minY, 1),
        ]
        for (level, y, labelIndex) in channels {
            // 标签
            Self.meterLabels[labelIndex].draw(
                at: NSPoint(x: area.minX, y: isFlipped ? y - 9 : y + rowH + 1)
            )
            let litCount = Int(round(CGFloat(min(1, max(0, level))) * CGFloat(meterSegments)))
            for s in 0..<meterSegments {
                let x = area.minX + CGFloat(s) * (segW + segGap)
                let rect = NSRect(x: x, y: y, width: segW, height: rowH)
                let ratio = CGFloat(s) / CGFloat(meterSegments)
                let color: NSColor
                let colorIndex: Int
                if ratio > 0.85 { color = Theme.meterRed; colorIndex = 2 }
                else if ratio > 0.65 { color = Theme.meterYellow; colorIndex = 1 }
                else { color = Theme.meterGreen; colorIndex = 0 }
                if s < litCount {
                    color.setFill()
                    rect.fill()
                } else {
                    Self.dimMeterColors[colorIndex].setFill()
                    rect.fill()
                }
            }
        }
    }
}
