import AppKit

/// 待播队列面板的窗口壳（F03）：独立无边框皮肤窗，不加入停靠组 ——
/// 和「歌词秀」一样是按需开关的附属窗，这样不必给停靠组再加一个面板编号
final class QueuePanelWindow: SkinPanelWindow {
    override var contentHeight: CGFloat { MainWindowController.queuePanelH }
}

/// 待播队列面板：上面一行写「正在播放」，下面是待播条目表。
///
/// 面板只读队列、只改队列，绝不碰浏览列表：切组/搜索/排序都在那边发生，
/// 这一块的次序必须不受影响（requirements F03）。拖动行重排待播、双击行直接播它。
final class QueuePanelController: NSObject {
    /// 内部重排专用的拖放类型：不接受 .fileURL，免得把桌面文件拖进来当成改队列
    static let dragType = NSPasteboard.PasteboardType(rawValue: "com.ttplayer.queue.reorder")
    static let defaultHeight: CGFloat = 210

    let window: QueuePanelWindow
    private let table: NSTableView
    private let currentLabel = NSTextField(labelWithString: "正在播放：无")
    private let caption = NSTextField(labelWithString: "待播队列")
    private let infoField = NSTextField(labelWithString: "0 首")
    private let emptyHint = NSTextField(labelWithString: "队列为空（在列表里右键选「下一首播放」或「稍后播放」）")
    private let removeButton: TTButton
    private let clearButton: TTButton
    private let controller = PlayerController.shared

    init(width: CGFloat) {
        let w = max(MainWindowController.minWidth, width)
        window = QueuePanelWindow(width: w, height: Self.defaultHeight, title: "待播队列")
        table = NSTableView(frame: .zero)
        removeButton = TTButton(.title("移除"), target: nil, action: nil,
                                size: NSSize(width: 38, height: 20), face: .flatOnLight)
        clearButton = TTButton(.title("清空待播"), target: nil, action: nil,
                               size: NSSize(width: 64, height: 20), face: .flatOnLight)
        super.init()

        // 先装顶部那一行：表格外壳的顶边钉在 currentLabel 下沿，
        // 那一行还没挂进 skinRoot 之前就激活约束，AppKit 找不到共同父视图会直接报错
        buildChrome()
        buildTable()

        removeButton.target = self
        removeButton.action = #selector(removeAction)
        clearButton.target = self
        clearButton.action = #selector(clearAction)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(queueChanged), name: .ttQueueChanged, object: nil)
        nc.addObserver(self, selector: #selector(queueChanged), name: .ttTrackChanged, object: nil)
        nc.addObserver(self, selector: #selector(queueChanged), name: .ttPlaylistChanged, object: nil)
        reload()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - 搭建

    private func buildTable() {
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("q_name"))
        name.width = 320
        name.minWidth = 120
        // 名称列吃掉剩余宽度，时长列固定：面板拉宽时序号和时长不能跟着漂
        name.resizingMask = [.autoresizingMask, .userResizingMask]
        let dur = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("q_dur"))
        dur.width = 56
        dur.minWidth = 44
        dur.resizingMask = []
        table.addTableColumn(name)
        table.addTableColumn(dur)
        table.columnAutoresizingStyle = .sequentialColumnAutoresizingStyle
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.rowHeight = 22
        table.gridStyleMask = []
        table.style = .plain
        table.headerView = nil
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.selectionHighlightStyle = .regular
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        // 拖拽起点由表格自报（默认 .copy），能不能落看 validateDrop
        table.registerForDraggedTypes([Self.dragType])

        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false
        scroll.documentView = table

        let well = WellView()
        well.dark = true
        well.cornerRadius = 4
        well.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(scroll)
        window.skinRoot.addSubview(well)
        NSLayoutConstraint.activate([
            well.topAnchor.constraint(equalTo: currentLabel.bottomAnchor, constant: 6),
            well.leadingAnchor.constraint(equalTo: window.skinRoot.leadingAnchor, constant: 8),
            well.trailingAnchor.constraint(equalTo: window.skinRoot.trailingAnchor, constant: -8),
            well.bottomAnchor.constraint(equalTo: window.skinRoot.bottomAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: well.topAnchor, constant: 3),
            scroll.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 3),
            scroll.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -3),
            scroll.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -3),
        ])
        emptyHint.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(emptyHint)
        NSLayoutConstraint.activate([
            emptyHint.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            emptyHint.centerYAnchor.constraint(equalTo: well.centerYAnchor),
        ])
    }

    private func buildChrome() {
        currentLabel.font = Theme.smallFont
        currentLabel.textColor = Theme.textAccent
        currentLabel.lineBreakMode = .byTruncatingMiddle
        caption.font = Theme.tinyFont
        caption.textColor = Theme.textSecondary
        infoField.font = Theme.tinyFont
        infoField.textColor = Theme.textSecondary
        infoField.alignment = .right
        emptyHint.font = Theme.tinyFont
        emptyHint.textColor = Theme.textSecondary
        emptyHint.alignment = .center

        for v in [currentLabel, caption, infoField, removeButton, clearButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            window.skinRoot.addSubview(v)
        }
        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: window.skinRoot.topAnchor, constant: 8),
            caption.leadingAnchor.constraint(equalTo: window.skinRoot.leadingAnchor, constant: 10),

            infoField.centerYAnchor.constraint(equalTo: caption.centerYAnchor),
            infoField.trailingAnchor.constraint(equalTo: window.skinRoot.trailingAnchor, constant: -10),

            clearButton.centerYAnchor.constraint(equalTo: caption.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: infoField.leadingAnchor, constant: -10),
            removeButton.centerYAnchor.constraint(equalTo: caption.centerYAnchor),
            removeButton.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -6),
            // 两个键宽度写死，高度 20，避免被文本基线拉歪
            removeButton.widthAnchor.constraint(equalToConstant: 38),
            removeButton.heightAnchor.constraint(equalToConstant: 20),
            clearButton.widthAnchor.constraint(equalToConstant: 64),
            clearButton.heightAnchor.constraint(equalToConstant: 20),
            currentLabel.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 4),
            currentLabel.leadingAnchor.constraint(equalTo: window.skinRoot.leadingAnchor, constant: 10),
            currentLabel.trailingAnchor.constraint(equalTo: window.skinRoot.trailingAnchor, constant: -10),
        ])
        // 统计文字与两个键不重叠只是一条偏好：面板拉到最小宽时往后让，而不是报约束冲突
        let infoGap = infoField.leadingAnchor.constraint(greaterThanOrEqualTo: removeButton.trailingAnchor,
                                                          constant: 8)
        infoGap.priority = .defaultLow
        infoGap.isActive = true
    }

    /// 与停靠组同宽（主面板拉宽/收窄时跟着走）
    func matchWidth(_ width: CGFloat) {
        let w = max(MainWindowController.minWidth, width)
        guard abs(window.frame.width - w) > 0.5 else { return }
        var f = window.frame
        f.size.width = w
        window.setFrame(f, display: true)
    }

    /// 首次打开时贴在停靠组下方，同宽左对齐（和歌词窗同一套摆法）
    func placeBelow(groupLeft: CGFloat, groupBottom: CGFloat) {
        var f = window.frame
        f.origin = NSPoint(x: groupLeft, y: groupBottom - SkinDock.gap - f.height)
        // 夹回组所在那块屏：拿 NSScreen.main 会在多屏时把面板夹到另一块屏上
        let screen = SkinDock.visibleFrame(near: NSPoint(x: groupLeft + f.width / 2, y: groupBottom - 1))
        f.origin.x = min(max(f.origin.x, screen.minX), max(screen.minX, screen.maxX - f.width))
        f.origin.y = min(max(f.origin.y, screen.minY), max(screen.minY, screen.maxY - f.height))
        window.setFrame(f, display: false)
    }

    func show() {
        reload()
        window.makeKeyAndOrderFront(nil)
    }

    func hide() { window.orderOut(nil) }

    // MARK: - 刷新

    @objc private func queueChanged() { reload() }

    private func reload() {
        table.reloadData()
        let q = controller.queue
        if let t = q.currentTrack {
            currentLabel.stringValue = "正在播放：\(displayName(t))"
        } else {
            currentLabel.stringValue = "正在播放：无"
        }
        infoField.stringValue = "待播 \(q.pendingCount) 首"
        emptyHint.isHidden = q.pendingCount > 0
    }

    /// 没有标签的曲子也要有名字（写空串会让用户以为面板没刷新）
    private func displayName(_ t: Track) -> String {
        if t.artist.isEmpty { return t.title.isEmpty ? t.fileName : t.title }
        return "\(t.artist) - \(t.title.isEmpty ? t.fileName : t.title)"
    }

    // MARK: - 交互

    /// 待播条目的显示顺序（行号 → 条目身份），重排与移除都以此为准
    private var pendingIDs: [UUID] { controller.queue.pending.map { $0.id } }

    @objc private func removeAction() {
        removeRows(selectedRows())
    }

    @objc private func clearAction() {
        controller.clearPendingQueue()
    }

    private func selectedRows() -> IndexSet {
        table.selectedRowIndexes
    }

    private func removeRows(_ rows: IndexSet) {
        let ids = pendingIDs
        let drop = Set(rows.compactMap { ids.indices.contains($0) ? ids[$0] : nil })
        guard !drop.isEmpty else { return }
        controller.removeQueued(ids: drop)
    }

    @objc private func doubleClicked() {
        playRowAt(table.clickedRow >= 0 ? table.clickedRow : table.selectedRow)
    }

    /// 双击某行 = 从它开始播（只把游标移过去，后面的次序不变）
    private func playRowAt(_ row: Int) {
        let ids = pendingIDs
        guard ids.indices.contains(row) else { return }
        controller.playQueued(id: ids[row])
    }

    /// 把拖动的条目放到目标行所占的位置（一次提交，走控制器的整体重排）。
    /// 自检也经由这里，拖放与断言用的是同一段次序换算
    @discardableResult
    func applyReorder(dragged rawIDs: [UUID], toRow row: Int) -> Bool {
        // 多选拖动时系统会逐项回调，先去掉重复身份，否则移除后第二份就找不着了
        var seen = Set<UUID>()
        let ids = rawIDs.filter { seen.insert($0).inserted }
        let current = controller.queue.pending.map { $0.id }
        guard !ids.isEmpty, row >= 0 else { return false }
        var order = current
        var moved: [UUID] = []
        for id in ids where order.contains(id) {
            order.removeAll { $0 == id }
            moved.append(id)
        }
        guard moved.count == ids.count else { return false }
        // 移除被拖条目后，落点越界就夹到队尾；「放到第 row 行」= 新序列里第 row 个
        let target = min(max(row, 0), order.count)
        order.insert(contentsOf: moved, at: target)
        return controller.reorderQueued(to: order)
    }

    // MARK: - 供自检

    var panelVisible: Bool { window.isVisible }
    var pendingRowCount: Int { table.numberOfRows }
    var currentText: String { currentLabel.stringValue }
    var infoText: String { infoField.stringValue }
    var showsEmptyHint: Bool { !emptyHint.isHidden }
    /// 待播首行的名称列文字（自检用：只能读已经 realized 的行）
    var firstCellText: String {
        window.contentView?.layoutSubtreeIfNeeded()
        guard let rv = table.rowView(atRow: 0, makeIfNecessary: true),
              let cell = rv.subviews.compactMap({ $0 as? NSTableCellView }).first
        else { return "" }
        return cell.textField?.stringValue ?? ""
    }
    /// 自检用：模拟一次「拖到某行」的完整重排（与 acceptDrop 同一函数）
    @discardableResult
    func reorderThroughUI(fromRow: Int, toRow: Int) -> Bool {
        let ids = pendingIDs
        guard ids.indices.contains(fromRow) else { return false }
        return applyReorder(dragged: [ids[fromRow]], toRow: toRow)
    }
    /// 自检用：选中若干行后点「移除」（走与鼠标同一个 action）
    func removeSelectionThroughUI(rows: IndexSet) {
        table.selectRowIndexes(rows, byExtendingSelection: false)
        removeButton.performClick(nil)
    }
    /// 自检用：不选任何行时直接点清空（表体为空也不能报崩溃）
    func clearThroughUI() { clearButton.performClick(nil) }
    /// 自检用：把某行当成双击落点（与 doubleClicked 同一个内部入口）
    func playRowThroughUI(_ row: Int) { playRowAt(row) }
}

// MARK: - 数据源 / 代理 / 拖放

extension QueuePanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        controller.queue.pendingCount
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let items = controller.queue.pending
        guard items.indices.contains(row),
              let colID = tableColumn?.identifier.rawValue else { return nil }
        let item = items[row]
        let id = NSUserInterfaceItemIdentifier(colID)
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.font = Theme.smallFont
            tf.lineBreakMode = .byTruncatingMiddle
            tf.textColor = Theme.textPrimary
            cell.addSubview(tf)
            cell.textField = tf
            tf.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.identifier = id
        }
        let t = item.track
        switch colID {
        case "q_name":
            // 「序号. 艺术家 - 标题」：待播里允许同一首歌占两行，序号就是它们的区分
            cell.textField?.stringValue = "\(row + 1). \(displayName(t))"
            cell.textField?.textColor = Theme.textPrimary
        default:
            cell.textField?.stringValue = t.isRadio ? "直播"
                : (t.duration > 0 ? TimeFormat.clock(t.duration) : "...")
            cell.textField?.textColor = Theme.textSecondary
            cell.textField?.alignment = .right
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rv = SkinRowView()
        // 待播段没有「当前行」概念（当前曲写在表头那行），只保留斑马底
        rv.isCurrentRow = false
        rv.isZebra = row % 2 == 1
        return rv
    }

    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let ids = pendingIDs
        guard ids.indices.contains(row) else { return nil }
        // 一次只携带这一条的身份；多选拖动的多个条目会各自写一份，
        // acceptDrop 里按出现顺序去重，不会把同一个条目插两次
        let item = NSPasteboardItem()
        item.setString(ids[row].uuidString, forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard (info.draggingSource as? NSTableView) === tableView,
              info.draggingPasteboard.data(forType: Self.dragType) != nil else { return [] }
        // 拿 .copy 当「内部重排」的通行证：只认自己发出的拖拽与自家拖放类型
        return .copy
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        // 只接自家重排类型：.fileURL 从桌面拖进来应当走“加入列表”，不是改队列次序
        guard (info.draggingSource as? NSTableView) === tableView,
              let data = info.draggingPasteboard.data(forType: Self.dragType),
              let text = String(data: data, encoding: .utf8) else { return false }
        let ids = text.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
        return applyReorder(dragged: ids, toRow: row)
    }
}
