import AppKit

/// 封面大图窗：点显示区那一格封面弹出。独立无边框皮肤窗（不进停靠组），
/// 跟随当前曲目换图；再点一次大图就关掉，不用去摸标题条上的 ✕
final class CoverWindow: NSObject {
    let window: SkinPanelWindow
    private let header: PanelHeaderView
    private let art = CoverView()
    private let caption = NSTextField(labelWithString: "")
    private let sourceField = NSTextField(labelWithString: "")
    private let controller = PlayerController.shared

    /// 封面格边长：CoverArt 最大的一档是 256，放到 240 已经接近 1:1，再放大会糊
    static let artSide: CGFloat = 240
    static let defaultSize = NSSize(width: artSide + 12, height: 320)

    override init() {
        let rect = NSRect(origin: .zero, size: Self.defaultSize)
        window = SkinPanelWindow(width: rect.width, height: rect.height, title: "专辑封面")
        header = PanelHeaderView(title: "专辑封面", height: MainWindowController.panelHeaderH)
        super.init()

        window.isMovableByWindowBackground = true
        window.level = .normal

        let close = TTButton(.symbol("xmark"), target: self, action: #selector(hideAction),
                             size: NSSize(width: 22, height: 18))
        close.toolTip = "关闭封面窗（再点一次封面也能关）"
        header.addControl(close)
        art.cornerRadius = 6
        art.onClick = { [weak self] in self?.hideAction() }

        // 两行字落在浅玻璃外壳上，必须用深字（沿用标题条那套配色）；
        // 拿深底用的 textPrimary 会白到看不见
        caption.font = Theme.titleFont
        caption.textColor = Theme.titleText
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingMiddle
        sourceField.font = Theme.tinyFont
        sourceField.textColor = Theme.flatTextOnLight
        sourceField.alignment = .center
        sourceField.lineBreakMode = .byTruncatingTail

        for v in [header, art, caption, sourceField] {
            v.translatesAutoresizingMaskIntoConstraints = false
            window.skinRoot.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: window.skinRoot.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: window.skinRoot.leadingAnchor, constant: 6),
            header.trailingAnchor.constraint(equalTo: window.skinRoot.trailingAnchor, constant: -6),
            header.heightAnchor.constraint(equalToConstant: MainWindowController.panelHeaderH),

            art.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            art.centerXAnchor.constraint(equalTo: window.skinRoot.centerXAnchor),
            art.widthAnchor.constraint(equalToConstant: Self.artSide),
            art.heightAnchor.constraint(equalToConstant: Self.artSide),

            caption.topAnchor.constraint(equalTo: art.bottomAnchor, constant: 6),
            caption.leadingAnchor.constraint(equalTo: window.skinRoot.leadingAnchor, constant: 8),
            caption.trailingAnchor.constraint(equalTo: window.skinRoot.trailingAnchor, constant: -8),
            caption.heightAnchor.constraint(equalToConstant: 18),

            sourceField.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 2),
            sourceField.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
            sourceField.trailingAnchor.constraint(equalTo: caption.trailingAnchor),
            sourceField.heightAnchor.constraint(equalToConstant: 14),
        ])

        refresh()
        NotificationCenter.default.addObserver(self, selector: #selector(trackChanged(_:)),
                                               name: .ttTrackChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// 供自检：大图窗贴的是不是当前曲的封面。比共享键而不是比实例：
    /// 窗口里贴的是按需解出来的大档，曲目上常驻的是小档，两者本来就不是同一个对象
    var showsCurrentCover: Bool {
        guard let track = controller.currentTrack else { return false }
        return art.showsCoverImage && art.coverKey == (track.coverRef?.key ?? "")
    }
    var isVisible: Bool { window.isVisible }

    @objc private func trackChanged(_ note: Notification) {
        // 窗口没开就不必解大档：换曲很频繁，白解一档 256 只是白烧 CPU
        refresh(loadLarge: window.isVisible)
    }

    /// - Parameter loadLarge: 大档要不要现在就解。曲目上只常驻小档（112px），
    ///   240pt 的格子拿它放大会糊，所以窗口要展示时再按需解一档 256
    private func refresh(loadLarge: Bool = false) {
        guard let track = controller.currentTrack else {
            art.image = nil
            art.coverKey = ""
            caption.stringValue = "还没有播放中的曲目"
            sourceField.stringValue = ""
            return
        }
        art.image = track.cover
        art.coverKey = track.coverRef?.key ?? ""
        if loadLarge, let big = MetadataReader.largeCover(for: track) {
            art.image = big
        }
        caption.stringValue = track.artist.isEmpty ? track.title : "\(track.artist) - \(track.title)"
        sourceField.stringValue = track.coverSource.isEmpty ? CoverArt.absentHint : track.coverSource
    }

    /// 摆到主面板右侧（放不下就放左侧），首次打开落在屏幕中间
    private func position(near parent: NSWindow?) {
        let size = window.frame.size
        guard let screen = (parent?.screen ?? NSScreen.main) ?? NSScreen.screens.first,
              let parentFrame = parent?.frame else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        var origin = NSPoint(x: parentFrame.maxX + 12, y: parentFrame.maxY - size.height)
        if origin.x + size.width > visible.maxX {
            origin.x = parentFrame.minX - 12 - size.width      // 右边挤了就让到左边
        }
        if origin.x < visible.minX { origin = NSPoint(x: visible.midX - size.width / 2,
                                                      y: visible.midY - size.height / 2) }
        origin.y = min(origin.y, visible.maxY - size.height)
        origin.y = max(origin.y, visible.minY)
        window.setFrameOrigin(origin)
    }

    func show(near parent: NSWindow?) {
        // 用户点了封面：这一次同步解大档（一张图十几毫秒，点一下等得起），
        // 免得大图窗先糊一下再变清晰
        refresh(loadLarge: true)
        position(near: parent)
        window.makeKeyAndOrderFront(nil)
    }

    func toggle(near parent: NSWindow?) {
        if window.isVisible { hideAction(); return }
        show(near: parent)
    }

    @objc private func hideAction() {
        window.orderOut(nil)
    }
}
