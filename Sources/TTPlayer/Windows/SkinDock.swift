import AppKit

/// 拖拽粘贴板里的文件 URL（文件夹也认）——窗口级拖放与列表表格拖放共用同一套取法
enum DragPayload {
    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self],
                               options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

/// 无边框皮肤窗口，支持成为 key 窗口以接收键盘事件
class TTWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// 无边框窗口仍允许拉边改变大小（配合 minSize）
    override var isResizable: Bool { true }

    /// 拖进来的文件/文件夹怎么处理（返回新增条数）。nil = 这个窗不接拖放
    var onFileDrop: (([URL]) -> Int)?

    /// 皮肤宽度约束：AppKit 会在窗口首次可见前用约束的“拟合尺寸”反向设置窗口宽度
    /// （横向是“填满”而不被约束决定，会被压到水平必需约束的最小值，实测 760 被改成 240），
    /// 所以用一条必需等宽约束钉住宽度；setFrame 前先把常量跟上新宽度，拉边拉伸仍然有效。
    var skinWidthConstraint: NSLayoutConstraint?

    override func setFrame(_ frame: NSRect, display flag: Bool) {
        if let c = skinWidthConstraint, abs(c.constant - frame.width) > 0.5 {
            c.constant = frame.width
        }
        super.setFrame(frame, display: flag)
    }

    // MARK: - 窗口级拖放

    // 无边框窗默认不是拖放目的地：不 registerForDraggedTypes + 不实现这几个回调，
    // 把文件/文件夹拖到窗口上会一点反应都没有（只有列表里的表格自己接过拖放）。
    // NSWindow 是通过 ObjC 类别采纳 NSDraggingDestination 的， Swift 里只能 @objc 实现、
    // 不能 override

    @objc func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsDrop(sender) ? .copy : []
    }

    @objc func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsDrop(sender) ? .copy : []
    }

    @objc func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptsDrop(sender)
    }

    @objc func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = DragPayload.urls(from: sender.draggingPasteboard)
        guard !urls.isEmpty, let onFileDrop else { return false }
        _ = onFileDrop(urls)
        // 全部已在列表里也算被接住，别让系统把拖影弹回去
        return true
    }

    private func acceptsDrop(_ info: NSDraggingInfo) -> Bool {
        onFileDrop != nil && !DragPayload.urls(from: info.draggingPasteboard).isEmpty
    }
}

/// 一块可停靠的皮肤面板：无边框窗 + 圆角描边外壳 + 内容根视图（宽度已钉住）
class SkinPanelWindow: TTWindow {
    /// 内容根视图，所有子控件往这里挂
    let skinRoot = GradientView()
    /// 壳层背后的 vibrancy 层：v1.20 一度把 material 定为 .hudWindow + blendingMode=.behindWindow
    /// 想拿“毛玻璃”。用户实际看到“完全没透”——material 本身很接近壳层渐变，叠起来看上去就像不透明；
    /// 且 borderless 窗上 `behindWindow` 归 WindowServer 合成，在没开 wantsLayer 的 container 里很不容易
    /// 真报到桌面层。现在 vibrancy 保留代码、默认隐藏，主链路只靠 skinRoot 自身的 alpha 把壁纸直透出来。
    private let vibrancy = NSVisualEffectView()
    private var vibrancyEnabled: Bool { false }
    private var glassObserver: NSObjectProtocol?
    /// 所属停靠组（拖动标题条时整组跟随）
    weak var dock: SkinDock?
    /// 停靠组用的面板编号
    var panel: SkinPanel?
    /// 内容需要的高度（子类重写；停靠组按这个值排布）
    var contentHeight: CGFloat { 200 }

    init(width: CGFloat, height: CGFloat, title: String) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        self.title = title
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        appearance = NSAppearance(named: .aqua)
        isMovableByWindowBackground = false
        collectionBehavior = [.fullScreenAuxiliary]

        // contentView 只做空容器：往它上面加约束会让 AppKit 用拟合尺寸反向改窗口宽度
        let container = NSView(frame: NSRect(origin: .zero, size: contentLayoutRect.size))
        container.autoresizesSubviews = true
        // container 开 wantsLayer：子视图（skinRoot 以 alpha 0.55 自绘）的 layer 才能跟窗口 layer
        // 树一起合成，下面就是真正的桌面；不开时 AppKit 会拿默认路径回刷，半透明很容易“看得到描边看不到壁纸”
        container.wantsLayer = true
        contentView = container

        // vibrancy 默认隐藏，壳层下面不留中间层，直接看到模糊之前的桌面
        vibrancy.frame = container.bounds
        vibrancy.autoresizingMask = [.width, .height]
        vibrancy.material = .hudWindow
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .followsWindowActiveState
        vibrancy.wantsLayer = true
        vibrancy.layer?.cornerRadius = 8
        vibrancy.layer?.masksToBounds = true
        vibrancy.isHidden = !vibrancyEnabled
        container.addSubview(vibrancy)

        skinRoot.frame = container.bounds
        skinRoot.autoresizingMask = [.width, .height]
        skinRoot.colors = [Theme.windowTop, Theme.windowBottom]
        skinRoot.cornerRadius = 8
        skinRoot.gloss = true
        skinRoot.glassBody = true
        skinRoot.innerHighlight = true
        skinRoot.wantsLayer = true
        skinRoot.layer?.cornerRadius = 8
        skinRoot.layer?.masksToBounds = true
        skinRoot.layer?.borderWidth = 1
        skinRoot.layer?.borderColor = Theme.skinEdge.cgColor
        container.addSubview(skinRoot)

        let pin = skinRoot.widthAnchor.constraint(equalToConstant: width)
        pin.isActive = true
        skinWidthConstraint = pin

        // GlassStyle 切换时同步 vibrancy（当前 vibrancyEnabled=false 恒隐藏，接口保留方便日后把
        // “毛玻璃”作为可选项重新打开）
        glassObserver = NotificationCenter.default.addObserver(
            forName: GlassStyle.didChange, object: nil, queue: .main) { [weak self] _ in
                self?.vibrancy.isHidden = !(self?.vibrancyEnabled ?? false) || !GlassStyle.enabled
            }

        // 拖文件/文件夹进任一块皮肤窗 = 加到播放列表（目录会递归展开）。
        // 列表窗里的表格自己也登记了 .fileURL，鼠标在表格上时由表格先接
        registerForDraggedTypes([.fileURL])
        onFileDrop = { urls in PlayerController.shared.addFiles(urls) }
    }

    deinit {
        if let observer = glassObserver { NotificationCenter.default.removeObserver(observer) }
    }
}

/// 可停靠的面板种类（决定竖排顺序）
enum SkinPanel: Int, CaseIterable {
    case main = 0
    case playlist = 1
    case equalizer = 2
}

/// 皮肤停靠组：主面板 / 播放列表 / 均衡器 三窗同宽竖排，
/// 拖动任一标题条整组跟随，拉宽主面板三窗一起变宽。
final class SkinDock {
    /// 面板之间的缝隙（截图里是露出一条桌面细缝）
    static let gap: CGFloat = 6
    /// 与主面板一致：底部一行控件的宽度下限
    static let minWidth: CGFloat = MainWindowController.minWidth

    private(set) var width: CGFloat
    /// 组左上角（屏幕坐标，y 为最上边）；升级旧存档时可直接写入
    var originTopLeft: NSPoint

    private struct Member {
        let window: SkinPanelWindow
        var height: CGFloat
        var visible: Bool
    }
    private var members: [SkinPanel: Member] = [:]
    private var order: [SkinPanel] = []
    private var observers: [NSObjectProtocol] = []
    private var layingOut = false
    private var raising = false
    /// 布局变化后回调（用于持久化）
    var onGeometryChanged: (() -> Void)?

    init(width: CGFloat, originTopLeft: NSPoint) {
        self.width = max(Self.minWidth, width)
        self.originTopLeft = originTopLeft
        // 从其他软件切回来时也要整组置前（无边框面板不会随激活而自动浮起）
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
            [weak self] _ in self?.raiseGroup()
        }
        observers.append(token)
    }

    deinit {
        let nc = NotificationCenter.default
        observers.forEach { nc.removeObserver($0) }
    }

    /// 加入面板，order 决定竖排顺序
    func register(_ panel: SkinPanel, _ window: SkinPanelWindow, height: CGFloat, visible: Bool = true) {
        members[panel] = Member(window: window, height: height, visible: visible)
        if !order.contains(panel) { order.append(panel) }
        window.dock = self
        window.panel = panel
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
            self?.moved(panel)
        })
        observers.append(nc.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
            self?.resized(window)
        })
        // 点任一面板时整组一起提到前面：否则其他面板会被别的软件压住，三窗看起来是散的
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            self?.raiseGroup()
        })
    }

    /// 按竖排顺序把可见面板依次置前（彼此不重叠，顺序只影响与其他软件的层级）
    func raiseGroup() {
        guard !raising else { return }
        raising = true
        defer { raising = false }
        for panel in order {
            guard let m = members[panel], m.visible else { continue }
            m.window.orderFront(nil)
        }
    }

    func heightForChange(_ panel: SkinPanel, to height: CGFloat) {
        guard var m = members[panel], abs(m.height - height) > 0.5 else { return }
        m.height = height
        members[panel] = m
        layout()
    }

    func setVisible(_ visible: Bool, for panel: SkinPanel) {
        guard var m = members[panel], m.visible != visible else { return }
        m.visible = visible
        members[panel] = m
        if !visible { m.window.orderOut(nil) }
        layout()
        if visible { m.window.makeKeyAndOrderFront(nil) }
    }

    func isVisible(_ panel: SkinPanel) -> Bool { members[panel]?.visible ?? false }

    func window(for panel: SkinPanel) -> SkinPanelWindow? { members[panel]?.window }

    /// 停靠组内的窗口数（>1 时标题条拖动要走“整组平移”）
    var memberCount: Int { members.count }

    /// 拖动开始时记录每个窗口的位置（屏幕坐标，AppKit 的 y 向上）
    func windowsByIdentifier() -> [ObjectIdentifier: NSPoint] {
        var dict: [ObjectIdentifier: NSPoint] = [:]
        for m in members.values where m.visible { dict[ObjectIdentifier(m.window)] = m.window.frame.origin }
        return dict
    }

    /// 整组高度（含缝隙），用于自检与屏幕夹取
    var totalHeight: CGFloat {
        let heights = order.compactMap { members[$0] }.filter { $0.visible }.map { $0.height }
        guard !heights.isEmpty else { return 0 }
        return heights.reduce(0, +) + Self.gap * CGFloat(heights.count - 1)
    }

    /// 组整体外接框（左上角坐标 + 尺寸）
    var groupFrame: NSRect {
        NSRect(x: originTopLeft.x, y: originTopLeft.y - totalHeight, width: width, height: totalHeight)
    }

    /// 按 originTopLeft / width / 各面板高度重排
    func layout() {
        guard !layingOut else { return }
        layingOut = true
        defer { layingOut = false }
        var top = originTopLeft.y
        for panel in order {
            guard var m = members[panel] else { continue }
            guard m.visible else {
                if m.window.isVisible { m.window.orderOut(nil) }
                continue
            }
            // 面板内容变化（如均衡器改了行高）时以内容为准
            if abs(m.window.contentHeight - m.height) > 0.5 {
                m.height = m.window.contentHeight
                members[panel] = m
            }
            let frame = NSRect(x: originTopLeft.x, y: top - m.height, width: width, height: m.height)
            if m.window.frame != frame {
                m.window.setFrame(frame, display: true)
            }
            if !m.window.isVisible { m.window.orderFront(nil) }
            top -= m.height + Self.gap
        }
        onGeometryChanged?()
    }

    /// 整组平移（标题条拖动时由 TitleBarDragView 调用）
    func moveGroup(by delta: NSSize) {
        guard !delta.height.isZero || !delta.width.isZero else { return }
        originTopLeft = NSPoint(x: originTopLeft.x + delta.width, y: originTopLeft.y + delta.height)
        layout()
    }

    /// 某个面板被拖动：以它为基准反推组左上角
    private func moved(_ panel: SkinPanel) {
        guard !layingOut, let m = members[panel] else { return }
        let above = order.prefix { $0 != panel }.compactMap { members[$0] }
            .filter { $0.visible }
        let offset = above.reduce(CGFloat(0)) { $0 + $1.height + Self.gap }
        originTopLeft = NSPoint(x: m.window.frame.minX, y: m.window.frame.maxY + offset)
        layout()
    }

    /// 整组隐藏（主面板“关闭”= 千千静听的隐藏到后台）
    func hideGroup() {
        for m in members.values where m.window.isVisible {
            m.window.orderOut(nil)
        }
    }

    /// 整组显示
    func showGroup() {
        layout()
    }

    /// 拉宽：三窗同步
    private func resized(_ window: SkinPanelWindow) {
        guard !layingOut, members.values.contains(where: { $0.window === window }) else { return }
        let w = window.frame.width
        guard w >= Self.minWidth - 1, abs(w - width) > 0.5 else { return }
        width = w
        layout()
    }

    // MARK: - 几何持久化（"left,top,width,height"，top 是组顶边 y）

    var geometryString: String {
        "\(originTopLeft.x),\(originTopLeft.y),\(width),\(totalHeight)"
    }

    /// 还原组位置；返回是否用上了存档
    @discardableResult
    func restore(_ string: String) -> Bool {
        let parts = string.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4, parts[2] >= Self.minWidth, parts[3] >= 120 else { return false }
        let topLeft = NSPoint(x: parts[0], y: parts[1])
        let probe = NSRect(x: topLeft.x, y: topLeft.y - parts[3], width: parts[2], height: parts[3])
        guard NSScreen.screens.contains(where: { $0.frame.intersects(probe) }) else { return false }
        width = parts[2]
        originTopLeft = topLeft
        layout()
        return true
    }

    /// 把组挪进屏幕（插拔显示器、存档越界时用）
    func constrainToScreen() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        var p = originTopLeft
        p.x = min(max(p.x, visible.minX), visible.maxX - width)
        p.y = min(max(p.y, visible.minY + totalHeight), visible.maxY)
        if abs(p.x - originTopLeft.x) > 0.5 || abs(p.y - originTopLeft.y) > 0.5 {
            originTopLeft = p
            layout()
        }
    }
}

/// 标题条空白区拖动：属于停靠组时整组一起动，否则只拖本窗
/// （整组拖动靠手动跟鼠标准，因为 performDrag 只会移动一个窗口）
final class TitleBarDragView: NSView {
    private var startLocations: [ObjectIdentifier: NSPoint] = [:]
    private var lastMouse: NSPoint?

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if let dock = (window as? SkinPanelWindow)?.dock, dock.memberCount > 1 {
            startLocations = dock.windowsByIdentifier()
            lastMouse = NSEvent.mouseLocation
        } else {
            window.performDrag(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !startLocations.isEmpty, let last = lastMouse else { return }
        let now = NSEvent.mouseLocation
        lastMouse = now
        (window as? SkinPanelWindow)?.dock?.moveGroup(by: NSSize(width: now.x - last.x,
                                                                 height: now.y - last.y))
    }

    override func mouseUp(with event: NSEvent) {
        startLocations.removeAll()
        lastMouse = nil
    }
}
