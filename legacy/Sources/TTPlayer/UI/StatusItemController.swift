import AppKit

/// 菜单栏状态项：常态显示「正在播放的歌」，鼠标一上去原地变成三个控制键
///
/// 两态的实现取舍：
/// - 常态那行歌名交给系统画（`statusItem.button` 的 attributedTitle + 耳机图标）：
///   明暗模式、菜单栏半透明、被系统点亮这些全由 AppKit 负责，自绘很难对齐。
/// - 悬停态需要三块可点区域，才让叠在按钮上的 strip 接管：它常态 `hitTest` 返回 nil
///   （点击照旧落到按钮上弹菜单），只有悬停时吃点击。
///
/// 宽度取 `max(常态宽, 三个键的宽)`：状态项在悬停时突然变窄会让鼠标“掉出去”，
/// 于是 exited → 收起 → 变宽 → 又 entered，肉眼就是来回闪。
final class StatusItemController: NSObject {
    /// 悬停条上的三个键，顺序即从左到右
    enum Key: Int, CaseIterable {
        case previous, playPause, next
    }

    /// 需要在主界面做的事（菜单里的「显示主界面」）交回 AppDelegate
    var onShowMain: (() -> Void)?

    private let item: NSStatusItem
    private let strip: StripView
    /// 常态宽度（按歌名算出来的）
    private var collapsedWidth: CGFloat = NSStatusItem.squareLength
    private var expanded = false
    /// 收起的宽限：鼠标掠过边缘、或跳出后马上回来都不会闪
    private var collapseTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var headerItem: NSMenuItem?
    /// 常态那一态要恢复的内容（悬停时被清空）
    private var titleForCollapse = NSAttributedString(string: "")
    private var iconForCollapse: NSImage? = AppIcon.menuBarImage()

    private static let menuFont: NSFont = NSFont.menuBarFont(ofSize: 0)
    /// 歌名最多占多宽：再长就截断，不能一首歌把菜单栏铺满
    private static let maxTextWidth: CGFloat = 150
    private static let keySide: CGFloat = 20
    private static let keyGap: CGFloat = 4
    /// 三个键的整组宽度（StripView 的布局与这里算的是同一个数）
    private static let stripWidth = 3 * keySide + 2 * keyGap
    /// 离开状态项后多久才收起（宽限）：够鼠标从边缘掠过去或点进菜单
    private static let collapseGrace: TimeInterval = 0.08

    override init() {
        strip = StripView(frame: .zero)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        strip.onPick = { [weak self] key in self?.perform(key) }
        strip.onBackgroundClick = { [weak self] in self?.popUpMenu() }
        strip.onHover = { [weak self] inside in self?.setHovered(inside) }
        strip.autoresizingMask = [.width, .height]
        item.button?.addSubview(strip)
        item.button?.imagePosition = .imageLeading

        buildMenu()
        observe()
        refresh()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        NSStatusBar.system.removeStatusItem(item)
    }

    // MARK: - 显示内容

    /// 菜单栏那行字：有曲目时「歌名 · 艺人」，没有就空（只留耳机图标）
    /// 艺人只是占位值时省掉——菜单栏宽度宝贵，「未知艺术家」这种字信息量为零
    static func label(title: String, artist: String, fileName: String) -> String {
        let name = title.isEmpty ? fileName : title
        let realArtist = artist == MetadataReader.unknownArtist ? "" : artist
        return realArtist.isEmpty ? name : "\(name) · \(realArtist)"
    }

    /// 按宽度截成「前缀…」：宁可少两个字，也不能把状态项越撑越宽
    static func truncated(_ text: String, font: NSFont, maxWidth: CGFloat) -> String {
        func width(_ s: String) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: font]).width
        }
        guard maxWidth > 0, width(text) > maxWidth else { return text }
        var low = 0, high = text.count
        while low < high {
            let mid = (low + high + 1) / 2
            if width(String(text.prefix(mid)) + "…") <= maxWidth { low = mid } else { high = mid - 1 }
        }
        return String(text.prefix(low)) + "…"
    }

    /// 曲目/播放状态变了就重算歌名与宽度
    func refresh() {
        let player = PlayerController.shared
        strip.isPlaying = player.isPlaying
        guard let track = player.currentTrack else {
            titleForCollapse = NSAttributedString(string: "")
            iconForCollapse = Self.headphoneIcon
            collapsedWidth = NSStatusItem.squareLength
            apply()
            return
        }
        let text = Self.label(title: track.title, artist: track.artist, fileName: track.fileName)
        let shown = Self.truncated(text, font: Self.menuFont, maxWidth: Self.maxTextWidth)
        let textWidth = (shown as NSString).size(withAttributes: [.font: Self.menuFont]).width
        titleForCollapse = NSAttributedString(string: shown, attributes: [
            .font: Self.menuFont,
            .foregroundColor: NSColor.labelColor,
        ])
        iconForCollapse = Self.headphoneIcon
        // 耳机图标约 20 + 文字 + 左右内边距；短标题也留够能点住的宽度
        collapsedWidth = min(max(textWidth + 20 + 12, 56), 176)
        apply()
    }

    /// 耳机图标：模板图，颜色由菜单栏明暗/高亮决定（与 Dock 图标同一套几何，只是不带蓝底）。
    /// 静态缓存一份：refresh() 每换一首歌都会走到这里，没必要每次重画
    private static let headphoneIcon: NSImage? = AppIcon.menuBarImage()

    // MARK: - 两态切换

    /// 鼠标进入/离开状态项（strip 的回调；自检也走这里验宽度切换）
    func setHovered(_ inside: Bool) {
        if inside { expand() } else { scheduleCollapse() }
    }

    /// 自检用：菜单栏当前显示的文字与宽度，不参与正常逻辑
    func snapshot() -> (length: CGFloat, title: String, expanded: Bool) {
        (item.length, item.button?.attributedTitle.string ?? "", expanded)
    }

    /// 自检用：常态那颗图标（尺寸 + 是不是模板图）。
    /// 只查 `isTemplate` 辨不出“又换回系统符号”（符号也是模板图），所以连尺寸一起报
    var iconSnapshot: (width: CGFloat, height: CGFloat, template: Bool)? {
        guard let image = item.button?.image else { return nil }
        return (image.size.width, image.size.height, image.isTemplate)
    }

    /// 自检用：菜单首行（先模拟一次弹出前的刷新）；委托没接上它会一直停在「未在播放」
    var menuHeaderTitle: String? {
        if let menu = item.menu { menuNeedsUpdate(menu) }
        return headerItem?.title
    }

    /// 自检用：悬停条上真的装了 tracking area 吗（没装就永远收不到 mouseEntered）
    var hoverTrackingReady: Bool { !strip.trackingAreas.isEmpty }

    /// 自检用：把悬停条离屏画一张（画的就是挂在状态项上的那个），不碰真实状态项也不需录屏权限
    /// `cacheDisplay` 会直接调 `draw`，所以翻 `playing` 再画就能对比两种中键画法
    func hoverShot(playing: Bool) -> (rep: NSBitmapImageRep, points: CGFloat)? {
        guard strip.bounds.width > 0,
              let rep = strip.bitmapImageRepForCachingDisplay(in: strip.bounds) else { return nil }
        let was = strip.isPlaying
        strip.isPlaying = playing
        strip.cacheDisplay(in: strip.bounds, to: rep)
        strip.isPlaying = was
        return (rep, strip.bounds.width)
    }

    private func expand() {
        collapseTimer?.invalidate()
        collapseTimer = nil
        guard !expanded, item.button != nil else { return }
        expanded = true
        apply()
    }

    private func scheduleCollapse() {
        collapseTimer?.invalidate()
        let timer = Timer(timeInterval: Self.collapseGrace, repeats: false) { [weak self] _ in
            guard let self, self.expanded else { return }
            self.collapseTimer = nil
            self.expanded = false
            self.apply()
        }
        collapseTimer = timer
        // 用 runloop 定时器 + .common，而不是主队列的 asyncAfter：自检在 didFinishLaunching
        // 里用嵌套 runloop 等结果，主队列定时器在那里实测会晚两秒才炸
        RunLoop.main.add(timer, forMode: .common)
    }

    private func apply() {
        guard let button = item.button else { return }
        if expanded {
            button.image = nil
            button.attributedTitle = NSAttributedString(string: "")
            item.length = max(collapsedWidth, Self.stripWidth)
        } else {
            button.image = iconForCollapse
            button.attributedTitle = titleForCollapse
            item.length = collapsedWidth
        }
        // 显式跟上目标尺寸：subview 初帧是 zero，只靠 autoresizing 可能一直是零宽，
        // 那样 tracking area 和自绘都跟着没面积。宽度直接用刚设好的 item.length
        // （-1/-2 是 variableLength/squareLength 两个常量，那两种情形量不到，回落按钮宽度）
        let width = item.length > 0 ? item.length : button.bounds.width
        strip.frame = NSRect(x: 0, y: 0, width: width, height: button.bounds.height)
        strip.expanded = expanded
    }

    // MARK: - 动作

    private func perform(_ key: Key) {
        let player = PlayerController.shared
        switch key {
        case .previous: player.previous()
        case .playPause: player.togglePlay()
        case .next: player.next()
        }
        // 没在放列表里的任何曲子时按播放也不会变状态，这里统一按真实状态重画
        refresh()
    }

    // MARK: - 菜单

    private func buildMenu() {
        let menu = NSMenu()
        // 委托得显式给：`item.menu = menu` 不会自动把菜单的委托设成自己，
        // 不设的话 `menuNeedsUpdate` 永不调用，第一行永远是「未在播放」
        menu.delegate = self
        let header = menu.addItem(withTitle: "未在播放", action: nil, keyEquivalent: "")
        header.isEnabled = false
        headerItem = header
        menu.addItem(.separator())
        menu.addItem(withTitle: "显示主界面", action: #selector(showMain), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "播放/暂停", action: #selector(togglePlay), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "停止", action: #selector(stopPlay), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "上一曲", action: #selector(previousTrack), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "下一曲", action: #selector(nextTrack), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        item.menu = menu
    }

    @objc private func showMain() { onShowMain?() }
    @objc private func togglePlay() { perform(.playPause) }
    @objc private func stopPlay() {
        PlayerController.shared.stop()
        refresh()
    }
    @objc private func previousTrack() { perform(.previous) }
    @objc private func nextTrack() { perform(.next) }

    /// 悬停态点空白处：让按钮自己走一次点击，菜单才会贴在状态项下面正常弹出
    private func popUpMenu() {
        if let button = item.button {
            button.performClick(nil)
        } else if let menu = item.menu {
            menu.popUp(positioning: nil, at: .zero, in: nil)
        }
    }

    private func observe() {
        let nc = NotificationCenter.default
        for name in [NSNotification.Name.ttTrackChanged, .ttPlaybackStateChanged, .ttPlaylistChanged] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
    }
}

extension StatusItemController: NSMenuDelegate {
    /// 菜单第一行永远是「现在在放什么」，否则从菜单里看不出点的是哪首
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let track = PlayerController.shared.currentTrack else {
            headerItem?.title = "未在播放"
            return
        }
        let text = Self.label(title: track.title, artist: track.artist, fileName: track.fileName)
        headerItem?.title = "正在播放：" + Self.truncated(text, font: Self.menuFont, maxWidth: 260)
    }
}

// MARK: - 悬停条

/// 叠在状态按钮上的悬停条：常态什么也不画、点击穿透；悬停时画三个键并接管点击
private final class StripView: NSView {
    var onPick: ((StatusItemController.Key) -> Void)?
    var onBackgroundClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    var isPlaying = false {
        didSet { if expanded { needsDisplay = true } }
    }

    /// true = 悬停态。常态既不吃点击也不画东西，按钮该弹菜单照旧弹
    var expanded = false {
        didSet {
            guard expanded != oldValue else { return }
            hoveredKey = nil
            needsDisplay = true
        }
    }

    private var hoveredKey: StatusItemController.Key?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    /// 装 tracking area 不能只靠 AppKit 在布局时回调 `updateTrackingAreas`：
    /// 悬停是这个控件的唯一入口，装不上就等于功能不存在，进窗口时先主动装一次
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    /// 常态放行：事件必须落到下面的状态按钮上，否则点不出菜单
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard expanded, !isHidden else { return nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .mouseMoved,
                                                 .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseMoved(with event: NSEvent) {
        let key = key(at: convert(event.locationInWindow, from: nil))
        guard key != hoveredKey else { return }
        hoveredKey = key
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if let key = key(at: convert(event.locationInWindow, from: nil)) {
            onPick?(key)
        } else {
            onBackgroundClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) { onBackgroundClick?() }

    private func key(at point: NSPoint) -> StatusItemController.Key? {
        StatusItemController.Key.allCases.first {
            Self.keyRect($0, in: bounds).insetBy(dx: -2, dy: -2).contains(point)
        }
    }

    static func keyRect(_ key: StatusItemController.Key, in bounds: NSRect) -> NSRect {
        let side: CGFloat = 20, gap: CGFloat = 4
        let group = 3 * side + 2 * gap
        let startX = bounds.midX - group / 2
        return NSRect(x: startX + CGFloat(key.rawValue) * (side + gap),
                      y: bounds.midY - side / 2, width: side, height: side)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard expanded else { return }
        // 一块淡底：示意“这里现在是可以点的按钮”，颜色跟着系统明暗走
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 3), xRadius: 5, yRadius: 5).fill()
        for key in StatusItemController.Key.allCases {
            let rect = Self.keyRect(key, in: bounds)
            if key == hoveredKey {
                NSColor.labelColor.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 2), xRadius: 4, yRadius: 4).fill()
            }
            draw(key, in: rect)
        }
    }

    private func draw(_ key: StatusItemController.Key, in rect: NSRect) {
        NSColor.labelColor.setFill()
        let box = rect.insetBy(dx: 6, dy: 6)      // 20 → 8 的符号区
        switch key {
        case .previous, .next:
            let barW: CGFloat = 1.5
            NSBezierPath(rect: NSRect(x: key == .previous ? box.minX : box.maxX - barW,
                                      y: box.minY, width: barW, height: box.height)).fill()
            triangle(NSRect(x: key == .previous ? box.minX + barW + 1.5 : box.minX,
                            y: box.minY,
                            width: box.width - barW - 1.5, height: box.height),
                     pointsLeft: key == .previous)
        case .playPause:
            if isPlaying {
                let w = box.width * 0.34
                NSBezierPath(rect: NSRect(x: box.minX + box.width * 0.10, y: box.minY,
                                          width: w, height: box.height)).fill()
                NSBezierPath(rect: NSRect(x: box.maxX - box.width * 0.10 - w, y: box.minY,
                                          width: w, height: box.height)).fill()
            } else {
                triangle(box, pointsLeft: false)
            }
        }
    }

    private func triangle(_ rect: NSRect, pointsLeft: Bool) {
        let path = NSBezierPath()
        if pointsLeft {
            path.move(to: NSPoint(x: rect.minX, y: rect.midY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.move(to: NSPoint(x: rect.maxX, y: rect.midY))
            path.line(to: NSPoint(x: rect.minX, y: rect.minY))
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        }
        path.close()
        path.fill()
    }
}
