import AppKit

/// 均衡器独立面板（停靠组的第三块窗）：
/// 两个旋钮 + 开关/重置/预设小键（左栏旋钮下方）+ dB 刻度 + 10 段竖推子
/// 顶部不再有标题条，开关走主面板底部的「均衡器」键
final class EQPanelWindow: SkinPanelWindow {
    override var contentHeight: CGFloat { MainWindowController.eqPanelH }
}

final class EQPanelController: NSObject {
    let window: EQPanelWindow
    private let body = EQBodyView()
    private let enableButton: TTButton
    private let resetButton: TTButton
    private let presetButton: TTButton
    private let controller = PlayerController.shared
    private var currentPreset = "默认"

    /// 10 段预设（顺序对应 AudioEngine.eqFrequencies）
    static let presets: [(String, [Float])] = [
        ("默认", Array(repeating: 0, count: 10)),
        ("摇滚", [5.0, 4.0, 3.0, -1.0, -2.0, -1.0, 2.0, 4.5, 5.0, 4.5]),
        ("流行", [-1.5, 0, 2.0, 3.5, 3.5, 3.0, 1.5, 0, -1.0, -1.5]),
        ("古典", [4.5, 3.5, 0.5, 0, 0, -1.0, -2.0, -3.0, -4.0, -4.5]),
        ("爵士", [4.0, 3.0, 1.5, 1.0, 0, 1.0, 2.0, 3.0, 4.0, 3.5]),
        ("低音增强", [7.0, 6.0, 4.5, 2.0, 0, -0.5, -1.0, -1.5, -2.0, -2.0]),
        ("高音增强", [-2.0, -1.5, -1.0, 0, 0.5, 1.5, 3.0, 4.5, 6.0, 7.0]),
        ("人声", [-2.5, -1.0, 0, 2.5, 4.0, 4.0, 3.0, 1.0, -0.5, -1.5]),
    ]

    init(width: CGFloat) {
        let height = MainWindowController.eqPanelH
        window = EQPanelWindow(width: width, height: height, title: "均衡器")
        enableButton = TTButton(.symbol("power"), target: nil, action: nil,
                                size: NSSize(width: 22, height: 18))
        resetButton = TTButton(.symbol("arrow.uturn.backward"), target: nil, action: nil,
                               size: NSSize(width: 22, height: 18))
        presetButton = TTButton(.symbol("list.dash"), target: nil, action: nil,
                                size: NSSize(width: 22, height: 18))
        super.init()

        buildBody()
        buildControls()
        subscribe()
        syncFromEngine()
    }

    // MARK: - 搭建

    /// 三个小键排在左栏旋钮下方：去掉标题条后功能不能跟着没
    private func buildControls() {
        enableButton.target = self
        enableButton.action = #selector(toggleEnabled)
        enableButton.toolTip = "开启/关闭均衡器"
        resetButton.target = self
        resetButton.action = #selector(resetAction)
        resetButton.toolTip = "全部归零"
        presetButton.target = self
        presetButton.action = #selector(presetAction(_:))
        presetButton.toolTip = "预设（\(currentPreset)）"
        for b in [enableButton, resetButton, presetButton] {
            body.controlRow.addArrangedSubview(b)
        }
    }

    private func buildBody() {
        body.translatesAutoresizingMaskIntoConstraints = false
        window.skinRoot.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: window.skinRoot.topAnchor, constant: 6),
            body.leadingAnchor.constraint(equalTo: window.skinRoot.leadingAnchor, constant: 6),
            body.trailingAnchor.constraint(equalTo: window.skinRoot.trailingAnchor, constant: -6),
            body.bottomAnchor.constraint(equalTo: window.skinRoot.bottomAnchor, constant: -6),
        ])
        body.onGainChange = { [weak self] band, gain in
            self?.controller.setEQGain(band: band, gain: gain)
            self?.refreshReadout()
        }
        body.onPreampChange = { [weak self] db in
            self?.controller.setPreGain(db)
        }
        body.onVolumeChange = { [weak self] v in
            self?.controller.setVolume(v)
        }
    }

    private func subscribe() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(volumeChanged(_:)), name: .ttVolumeChanged, object: nil)
        nc.addObserver(self, selector: #selector(stateChanged(_:)), name: .ttPlaybackStateChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func volumeChanged(_ note: Notification) {
        let v = (note.userInfo?["volume"] as? Float) ?? controller.volume
        body.volumeKnob.gain = Double(v)
    }

    @objc private func stateChanged(_ note: Notification) { syncFromEngine() }

    // MARK: - 同步

    func showAndSync() {
        syncFromEngine()
    }

    private func syncFromEngine() {
        enableButton.lit = controller.eqEnabled
        let enabled = controller.eqEnabled
        body.faders.forEach { $0.isEnabled = enabled }
        body.refreshBacking()
        for (i, fader) in body.faders.enumerated() {
            fader.gain = Double(controller.engine.eqGain(band: i))
        }
        body.preampKnob.gain = Double(controller.preGain)
        body.volumeKnob.gain = Double(controller.volume)
        refreshReadout()
    }

    private func refreshReadout() {
        for (i, label) in body.gainLabels.enumerated() {
            label.stringValue = body.faders[i].gain >= 0
                ? String(format: "+%.0f", body.faders[i].gain)
                : String(format: "%.0f", body.faders[i].gain)
        }
        // 与预设完全一致时高亮预设名
        let gains = (0..<AudioEngine.eqBandCount).map { controller.engine.eqGain(band: $0) }
        if let hit = Self.presets.firstIndex(where: { zip($0.1, gains).allSatisfy { abs($0 - $1) < 0.05 } }) {
            currentPreset = Self.presets[hit].0
        } else {
            currentPreset = "自定义"
        }
        presetButton.toolTip = "预设（\(currentPreset)）"
    }

    // MARK: - 动作

    /// 推子数量（自检用）
    var faderCount: Int { body.faders.count }

    /// 主体视图（自检用：确认面板顶部直接是它，不再有标题条占位）
    var bodyView: NSView { body }

    /// 走 UI 同一条路径改某段增益（自检用）
    func setBandGain(_ band: Int, gain: Float) {
        guard body.faders.indices.contains(band) else { return }
        body.faders[band].gain = Double(gain)
        controller.setEQGain(band: band, gain: gain)
        refreshReadout()
    }

    @objc private func toggleEnabled() {
        controller.setEQEnabled(!controller.eqEnabled)
        syncFromEngine()
        NotificationCenter.default.post(name: .ttPlaybackStateChanged, object: nil,
                                        userInfo: ["isPlaying": controller.isPlaying])
    }

    @objc private func resetAction() {
        for i in 0..<body.faders.count {
            body.faders[i].gain = 0
            controller.setEQGain(band: i, gain: 0)
        }
        body.preampKnob.gain = 0
        controller.setPreGain(0)
        refreshReadout()
    }

    @objc private func presetAction(_ sender: NSButton) {
        let menu = NSMenu()
        for (name, gains) in Self.presets {
            let item = menu.addItem(withTitle: name, action: #selector(applyPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = gains
            item.state = name == currentPreset ? .on : .off
        }
        menu.popUp(under: sender)
    }

    @objc private func applyPreset(_ sender: NSMenuItem) {
        guard let gains = sender.representedObject as? [Float] else { return }
        for (i, g) in gains.enumerated() where body.faders.indices.contains(i) {
            body.faders[i].gain = Double(g)
            controller.setEQGain(band: i, gain: g)
        }
        currentPreset = sender.title
        refreshReadout()
        Diagnostics.log("均衡器预设 \(sender.title)")
    }
}

/// 均衡器主体：左侧两个旋钮 + dB 刻度 + 10 根竖推子（手动排布，跟随面板宽度变化）
final class EQBodyView: NSView {
    let preampKnob = KnobView()
    let volumeKnob = KnobView()
    let scale = EQScaleView()
    private(set) var faders: [FaderView] = []
    private(set) var gainLabels: [NSTextField] = []
    private(set) var freqLabels: [NSTextField] = []
    /// 开关/重置/预设三个小键（排左栏旋钮下方）
    let controlRow = NSStackView()

    var onGainChange: ((Int, Float) -> Void)?
    var onPreampChange: ((Float) -> Void)?
    var onVolumeChange: ((Float) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glassObs = NotificationCenter.default.addObserver(
            forName: GlassStyle.didChange, object: nil, queue: .main) { [weak self] _ in
                self?.needsDisplay = true
            }

        configure(knob: preampKnob, caption: "前置", min: -12, max: 12)
        preampKnob.action = #selector(preampAction(_:))
        addSubview(preampKnob)
        configure(knob: volumeKnob, caption: "音量", min: 0, max: 1)
        volumeKnob.action = #selector(volumeAction(_:))
        addSubview(volumeKnob)
        addSubview(scale)

        controlRow.orientation = .horizontal
        controlRow.spacing = 3
        addSubview(controlRow)

        for (i, freq) in AudioEngine.eqFrequencies.enumerated() {
            let f = FaderView()
            f.minValue = -12
            f.maxValue = 12
            f.tag = i
            f.target = self
            f.action = #selector(faderAction(_:))
            addSubview(f)
            faders.append(f)

            let gain = NSTextField(labelWithString: "0")
            gain.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            gain.textColor = Theme.textAccent
            gain.alignment = .center
            addSubview(gain)
            gainLabels.append(gain)

            let name = NSTextField(labelWithString: EQPanelController.freqLabel(freq))
            name.font = Theme.tinyFont
            name.textColor = Theme.textSecondary
            name.alignment = .center
            addSubview(name)
            freqLabels.append(name)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configure(knob: KnobView, caption: String, min: Double, max: Double) {
        knob.minValue = min
        knob.maxValue = max
        knob.caption = caption
        knob.target = self
    }

    /// 旋钮占的宽度（两个并排）
    static let knobColumnW: CGFloat = 96
    static let scaleW: CGFloat = 34

    override func layout() {
        super.layout()
        guard bounds.width > 120, bounds.height > 40 else { return }
        let knobH: CGFloat = 46
        let knobW: CGFloat = 44
        let labelH: CGFloat = 12
        // 底部两行文字：增益读数 + 频率名
        let faderBottom = bounds.height - labelH * 2 - 4
        let faderTop: CGFloat = 2
        // 旋钮放左上，刻度与推子同高
        preampKnob.frame = NSRect(x: 2, y: faderTop, width: knobW, height: knobH)
        volumeKnob.frame = NSRect(x: 2 + knobW + 4, y: faderTop, width: knobW, height: knobH)
        // 三小键紧贴旋钮下沿：左栏只占 96pt，按钮总宽 22×3 + 间隙正好排得下
        controlRow.frame = NSRect(x: 2, y: faderTop + knobH + 5,
                                  width: Self.knobColumnW - 4, height: 18)
        scale.frame = NSRect(x: Self.knobColumnW, y: faderTop, width: Self.scaleW,
                             height: faderBottom - faderTop)
        let fadersX = Self.knobColumnW + Self.scaleW + 2
        let avail = max(1, bounds.width - fadersX - 2)
        let cell = avail / CGFloat(faders.count)
        for (i, f) in faders.enumerated() {
            let x = fadersX + CGFloat(i) * cell
            let w = min(26, cell - 2)
            f.frame = NSRect(x: x + (cell - w) / 2, y: faderTop, width: w,
                             height: faderBottom - faderTop)
            let labelW = max(20, cell - 2)
            gainLabels[i].frame = NSRect(x: x + (cell - labelW) / 2, y: faderBottom + 1,
                                         width: labelW, height: labelH)
            freqLabels[i].frame = NSRect(x: x + (cell - labelW) / 2, y: faderBottom + 1 + labelH,
                                         width: labelW, height: labelH)
        }
    }

    /// 推子实际可用高度对应的量程区（刻度视图与推子共享同一算法）
    static var faderTopInset: CGFloat { 10 }

    @objc private func faderAction(_ sender: FaderView) {
        onGainChange?(sender.tag, Float(sender.gain))
    }

    @objc private func preampAction(_ sender: KnobView) {
        onPreampChange?(Float(sender.gain))
    }

    @objc private func volumeAction(_ sender: KnobView) {
        onVolumeChange?(Float(sender.gain))
    }

    /// 面板宽度变了以后重画刻度/读数
    func refreshBacking() {
        scale.needsDisplay = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // 深蓝灰内槽底，推子区像嵌在面板里的一块硬件：玻璃开启时按 wellAlpha 透一下
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
    }

    private var glassObs: NSObjectProtocol?
    deinit { if let o = glassObs { NotificationCenter.default.removeObserver(o) } }
}

/// dB 刻度：+12 / +6 / 0 / -6 / -12 横线 + 文字，与推子行程对齐
final class EQScaleView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.height > 10, bounds.width > 10 else { return }
        let top = EQBodyView.faderTopInset
        let bottom = bounds.height - EQBodyView.faderTopInset
        let travel = max(1, bottom - top)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.tinyFont,
            .foregroundColor: Theme.textSecondary,
        ]
        for db in [12.0, 6.0, 0, -6.0, -12.0] {
            // 顶部 = +12，底部 = -12
            let ratio = (12 - db) / 24
            let y = top + travel * CGFloat(ratio)
            Theme.wellBevelLight.withAlphaComponent(db == 0 ? 0.75 : 0.35).setFill()
            NSRect(x: 1, y: (y - 0.5).rounded(), width: bounds.width - 3,
                   height: db == 0 ? 1.5 : 1).fill()
            let label = (db > 0 ? "+\(Int(db))" : "\(Int(db))") as NSString
            let sz = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: bounds.width - sz.width - 2, y: y - sz.height / 2),
                       withAttributes: attrs)
        }
    }
}

extension EQPanelController {
    static func freqLabel(_ hz: Float) -> String {
        hz >= 1000 ? "\(Int(hz / 1000))K" : "\(Int(hz))"
    }
}
