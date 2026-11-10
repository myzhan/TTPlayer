import AppKit

/// 播放列表（照经典皮肤）：不显示系统表头，两列自绘 ——
/// 「序号. 艺术家 - 标题」+「时长」，当前行前面画 ▶ 并用亮蓝高亮
final class PlaylistView: NSView {
    private let tableView: NSTableView
    private let scroll: NSScrollView
    private let controller = PlayerController.shared
    /// 右键菜单里两个会变标题的项（收藏状态 / 当前组）
    private var favoriteItem: NSMenuItem?
    private var clearItem: NSMenuItem?
    /// 「在访达中显示」：电台没有本地文件，要置灰
    private var revealItem: NSMenuItem?

    private enum Column: String, CaseIterable {
        case name, duration

        var width: CGFloat {
            switch self {
            case .name: return 470
            case .duration: return 62
            }
        }
    }

    override init(frame frameRect: NSRect) {
        tableView = NSTableView(frame: frameRect)
        scroll = NSScrollView(frame: frameRect)
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.autohidesScrollers = true
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 24
        tableView.gridStyleMask = []
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.selectionHighlightStyle = .regular
        // 用无内缩的 plain 样式：系统默认的 inset 样式会给每行左右各留 16pt，
        // 把文档视图撑得比裁剪视图宽，最右边的时长列就被滚动条压掉一角；
        // 而且皮肤列表的斑马底、当前行的 ▶ 本来就该贴着面板边缘画
        tableView.style = .plain
        tableView.headerView = nil            // 皮肤列表不使用系统表头
        // 列宽自己算（见 fitColumns）：面板左边还有“播放列表”组，表格可视宽度
        // 比两列固有宽度之和小，交给系统自动调整会把时长列顶到可视区外
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.intercellSpacing = NSSize(width: 0, height: 1)

        for col in Column.allCases {
            let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.rawValue))
            tc.width = col.width
            tc.minWidth = col == .duration ? 48 : 120
            tc.resizingMask = col == .name ? [.userResizingMask, .autoresizingMask] : [.userResizingMask]
            tableView.addTableColumn(tc)
        }
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked)
        tableView.menu = buildMenu()
        tableView.registerForDraggedTypes([.fileURL])

        scroll.documentView = tableView
        addSubview(scroll)
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        scroll.hasHorizontalScroller = false

        refresh()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(playlistChanged),
                       name: .ttPlaylistChanged, object: nil)
        nc.addObserver(self, selector: #selector(trackChanged(_:)),
                       name: .ttTrackChanged, object: nil)
        // 滚动条出现/消失会改变裁剪视图宽度（行多到需要滚动时才会出现），
        // 不重新适配就会把时长列顶出可视区
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            nc.addObserver(self, selector: #selector(viewportChanged), name: name,
                           object: scroll.contentView)
        }
        // 行数增减改变文档视图高度（滚动条随之出现），但覆盖式滚动条不会改变裁剪视图
        // 宽度，上面两条通知都不会触发；表格自己的 bounds 变化才能补上这一刀
        tableView.postsBoundsChangedNotifications = true
        nc.addObserver(self, selector: #selector(viewportChanged),
                       name: NSView.boundsDidChangeNotification, object: tableView)
    }

    /// 供自检：各列当前宽度
    var columnWidths: [CGFloat] { tableView.tableColumns.map { $0.width } }

    /// 供自检：某行时长单元格在裁剪视图里的位置（先把该行滚到可见，否则拿不到 realized 行视图）
    private func durationCellRectInClip(row: Int) -> NSRect? {
        tableView.scrollRowToVisible(row)
        tableView.layoutSubtreeIfNeeded()
        guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell_duration")
        guard let cell = rowView.subviews.compactMap({ $0 as? NSTableCellView }).first(where: { $0.identifier == id })
        else { return nil }
        let clip = scroll.contentView
        return clip.convert(cell.convert(cell.bounds, to: nil), from: nil)
    }

    /// 供自检：时长单元格是否完整落在可视区内（不被滚动条压住）
    func durationCellFullyVisible(row: Int) -> Bool {
        guard let f = durationCellRectInClip(row: row) else { return false }
        let clip = scroll.contentView
        return f.minX >= clip.bounds.minX - 0.5 && f.maxX <= clip.bounds.maxX - scrollerInset + 0.5
    }

    /// 供自检：上一项失败时看真值用
    var durationCellProbeReport: String {
        let clip = scroll.contentView
        let cell = durationCellRectInClip(row: 0)
            .map { "x=\(Int($0.minX))..\(Int($0.maxX))" } ?? "nil"
        let rv = tableView.rowView(atRow: 0, makeIfNecessary: false)
        let cells = (rv?.subviews.compactMap { $0 as? NSTableCellView } ?? []).map {
            "x=\(Int($0.frame.minX))+\(Int($0.frame.width))"
        }
        return "cell=\(cell) clip=0..\(Int(clip.bounds.maxX)) inset=\(Int(scrollerInset)) "
            + "doc=\(Int(tableView.frame.width)) cells=\(cells)"
    }

    @objc private func viewportChanged() {
        fitColumns()
    }

    /// 本轮布局/刷新完成后再适配一次：滚动条刚出现时裁剪视图宽度还未更新
    private func scheduleFit() {
        DispatchQueue.main.async { [weak self] in self?.fitColumns() }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func layout() {
        super.layout()
        fitColumns()
    }

    /// 表格可视宽度：扣掉滚动条真正压住/占掉的那一条（见 scrollerInset）
    var viewportWidth: CGFloat {
        let w = scroll.contentView.bounds.width
        return (w > 1 ? w : bounds.width) - scrollerInset
    }

    /// 滚动条会从右边吃掉一条宽度：
    /// · legacy（系统设置成“始终显示”）会把裁剪视图挤窄，bounds 已如实反映；
    /// · 覆盖式不占布局，但直接画在内容之上，照样盖住时长列右端（专辑 9 首出滚动条时就是这样）。
    /// 两种都要扣，只是扣法不同。
    private var scrollerInset: CGFloat {
        guard scroll.hasVerticalScroller, let s = scroll.verticalScroller else { return 0 }
        let overflow = (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height + 0.5
        guard overflow else { return 0 }        // 行少到不出滚动条时不用预留
        return scroll.scrollerStyle == .overlay ? s.frame.width : 0
    }

    /// 名称列吸收面板宽度差额，右侧时长列固定宽度不被裁掉
    private func fitColumns() {
        guard tableView.tableColumns.count == Column.allCases.count,
              let nameCol = tableView.tableColumns.first,
              let durCol = tableView.tableColumns.last else { return }
        let spare = viewportWidth - durCol.width - tableView.intercellSpacing.width
        guard spare > nameCol.minWidth else { return }      // 面板收到极限窄时不再调
        if abs(nameCol.width - spare) > 0.5 {
            nameCol.width = spare
            // 列宽改了，已经 realized 的行不会自己按新宽度重摆单元格（还停在旧位置），
            // 必须重新走一遍 viewFor；layout 过程中不能直接 reloadData，排到下一轮
            scheduleReload()
        }
    }

    private var reloadScheduled = false

    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            self.tableView.reloadData()
        }
    }

    /// 供自检：两列总宽是否落在可视宽度内（时长列还在可见区里）
    var columnsFitInViewport: Bool {
        let total = tableView.tableColumns.reduce(tableView.intercellSpacing.width) { $0 + $1.width }
        return total <= viewportWidth + 0.5
    }

    /// 供自检：读某行时长列的文字（行未 realized 时先滚过去再读一次）
    func durationText(row: Int) -> String? {
        func text() -> String? {
            guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) else { return nil }
            for case let cell as NSTableCellView in rowView.subviews
            where cell.identifier == NSUserInterfaceItemIdentifier("cell_duration") {
                return cell.textField?.stringValue
            }
            return nil
        }
        if let t = text() { return t }
        tableView.scrollRowToVisible(row)
        tableView.layoutSubtreeIfNeeded()
        return text()
    }

    @objc private func playlistChanged() {
        fitColumns()
        scheduleFit()
        tableView.reloadData()
    }

    @objc private func trackChanged(_ note: Notification) {
        tableView.reloadData()
        scrollToCurrent()
    }

    func scrollToCurrent() {
        guard let i = controller.playlist.currentIndex else { return }
        tableView.scrollRowToVisible(i)
    }

    /// 供自检/工具条读取行高与选中行
    var rowHeight: CGFloat { tableView.rowHeight }
    /// 表格本体（自检要确认它把拖放接在了系统方法上）
    var table: NSTableView { tableView }
    var numberOfRows: Int { controller.playlist.count }
    var selectedRowIndexes: IndexSet { tableView.selectedRowIndexes }
    /// 当前高亮/选中行（工具条“删除”“编辑”用它）
    var targetRow: Int {
        tableView.clickedRow >= 0 ? tableView.clickedRow
            : (tableView.selectedRow >= 0 ? tableView.selectedRow : (controller.playlist.currentIndex ?? -1))
    }

    func refresh() {
        fitColumns()
        scheduleFit()
        tableView.reloadData()
    }

    /// 选中并滚动到某行（“查找”用）
    func focusRow(_ row: Int) {
        guard row >= 0, row < numberOfRows else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    @objc private func doubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, controller.playlist.track(at: row) != nil else { return }
        controller.playRowAt(row)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "播放", action: #selector(menuPlay), keyEquivalent: "")
            .target = self
        // 标题在 menuWillOpen 里按当前曲的收藏状态改（加入收藏 / 取消收藏）
        favoriteItem = menu.addItem(withTitle: "加入收藏", action: #selector(menuToggleFavorite),
                                    keyEquivalent: "")
        favoriteItem?.target = self
        menu.addItem(withTitle: "从列表删除", action: #selector(menuRemove), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        clearItem = menu.addItem(withTitle: "清空列表", action: #selector(menuClear), keyEquivalent: "")
        clearItem?.target = self
        revealItem = menu.addItem(withTitle: "在访达中显示", action: #selector(menuReveal),
                                  keyEquivalent: "")
        revealItem?.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "属性", action: #selector(menuProperties), keyEquivalent: "")
            .target = self
        return menu
    }

    @objc private func menuToggleFavorite() {
        guard let track = clickedTrack() else { return }
        _ = controller.toggleFavorite(track)
    }

    /// 右键菜单每次打开时按当前行的收藏状态、当前组重写两个标题
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === tableView.menu else { return }
        let track = clickedTrack()
        let on = track.map { controller.isFavorite($0) } ?? false
        favoriteItem?.title = on ? "取消收藏" : "加入收藏"
        favoriteItem?.isEnabled = track != nil
        // 电台地址不在磁盘上，访达里也没有它
        revealItem?.isEnabled = track != nil && !(track?.isRadio ?? false)
        switch controller.activeGroup {
        case .main: clearItem?.title = "清空列表"
        case .radio: clearItem?.title = "清空电台"
        case .recentRadio: clearItem?.title = "清空最近听的台"
        case .recent: clearItem?.title = "清空最近播放"
        case .favorites: clearItem?.title = "清空收藏"
        }
    }

    @objc private func menuPlay() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0 else { return }
        controller.playRowAt(row)
    }

    @objc private func menuRemove() {
        var rows = tableView.selectedRowIndexes
        if !rows.contains(tableView.clickedRow), tableView.clickedRow >= 0 {
            rows = IndexSet(integer: tableView.clickedRow)
        }
        guard !rows.isEmpty else { return }
        controller.removeTracks(at: rows)
    }

    @objc private func menuClear() {
        // 派生组里清空只清收藏/历史，[默认] 的列表不受影响（由控制器分辨）
        controller.clearPlaylist()
    }

    @objc private func menuReveal() {
        guard let track = clickedTrack(), !track.isRadio else { return }
        NSWorkspace.shared.activateFileViewerSelecting([track.url])
    }

    @objc private func menuProperties() {
        guard let track = clickedTrack() else { return }
        PropertyPanel.show(for: track, over: window)
    }

    private func clickedTrack() -> Track? {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        return row >= 0 ? controller.playlist.track(at: row) : nil
    }
}

// MARK: - 数据源 / 代理

extension PlaylistView: NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        controller.playlist.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = Column(rawValue: tableColumn?.identifier.rawValue ?? "") else { return nil }
        let isCurrent = controller.playlist.currentIndex == row
        let track = controller.playlist.track(at: row)

        let id = NSUserInterfaceItemIdentifier("cell_\(col.rawValue)")
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
            // 名称列左边多留一格：行首的 ▶ 当前曲标记不能压在文字上
            //（plain 样式不再给行内缩，这点得自己留）
            let lead: CGFloat = col == .name ? 12 : 4
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: lead),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.identifier = id
        }

        let text: String
        switch col {
        case .name:
            // 截图样式：序号. 艺术家 - 标题（艺术家缺失时只写标题）
            let head = (track?.artist ?? "").isEmpty ? (track?.title ?? "")
                : "\(track?.artist ?? "") - \(track?.title ?? "")"
            text = "\(row + 1). \(head)"
        case .duration:
            // 电台是直播：没有总长，“...”会让人以为还没解析完
            if track?.isRadio == true {
                text = "直播"
            } else if let d = track?.duration, d > 0 {
                text = TimeFormat.clock(d)
            } else {
                text = "..."
            }
        }
        cell.textField?.stringValue = text
        cell.textField?.textColor = isCurrent ? Theme.textAccent : Theme.textPrimary
        cell.textField?.font = isCurrent ? Theme.titleFont : Theme.smallFont
        if col == .duration {
            cell.textField?.alignment = .right
            cell.textField?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }
        return cell
    }

    /// 行视图：斑马底 + 当前曲标识 + 亮蓝选中高亮（避免系统蓝色）
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        // 行数不多且状态每次都重设，直接创建避免复用残留
        let rv = SkinRowView()
        rv.isCurrentRow = controller.playlist.currentIndex == row
        rv.isZebra = row % 2 == 1
        return rv
    }

    // 拖入文件/文件夹添加。名字必须是系统认的 acceptDrop:row:dropOperation:——
    // 原来写成自定义的 acceptDrag:，NSTableView 根本不会调用，等于拖进去没反应
    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        // 列表内部拖行是排序语义，不当成“导入文件”
        if let source = info.draggingSource as? NSTableView, source === tableView { return [] }
        return .copy
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        if let source = info.draggingSource as? NSTableView, source === tableView { return false }
        let urls = DragPayload.urls(from: info.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        let added = controller.addFiles(urls)
        if added > 0 { scrollToCurrent() }
        // 全都已经入过表也算这次拖放被接住，别让系统把拖影弹回去
        return true
    }

    // 列表向外部拖出（如拖到桌面 / 访达）
    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let track = controller.playlist.track(at: row) else { return nil }
        return track.url as NSURL
    }

    func tableView(_ tableView: NSTableView,
                   namesOfPromisedFilesDroppedAtDestination dropDestination: URL,
                   forDraggedRowsWith indexSet: IndexSet) -> [String] {
        indexSet.compactMap { controller.playlist.track(at: $0)?.url.lastPathComponent }
    }
}

/// 皮肤化列表行：斑马底 + 当前曲底色 + 亮蓝选中高亮，当前行左侧画 ▶
final class SkinRowView: NSTableRowView {
    var isCurrentRow = false { didSet { needsDisplay = true } }
    var isZebra = false { didSet { needsDisplay = true } }

    override func drawBackground(in dirtyRect: NSRect) {
        if isCurrentRow {
            Theme.buttonHot.withAlphaComponent(0.35).setFill()
        } else if isZebra {
            Theme.wellBottom.withAlphaComponent(0.45).setFill()
        } else {
            NSColor.clear.setFill()
        }
        dirtyRect.fill()
        if isCurrentRow {
            // 当前播放曲：行首三角标记（截图里就是 ▶）
            Theme.textAccent.setFill()
            let p = NSBezierPath()
            let y = bounds.midY
            p.move(to: NSPoint(x: 3, y: y - 4))
            p.line(to: NSPoint(x: 3, y: y + 4))
            p.line(to: NSPoint(x: 8, y: y))
            p.close()
            p.fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let base = isEmphasized ? Theme.textAccent : Theme.buttonHot
        base.withAlphaComponent(isEmphasized ? 0.24 : 0.30).setFill()
        dirtyRect.fill()
        // 左侧 2px 亮条，无焦点时也能看出选中行
        Theme.textAccent.withAlphaComponent(0.85).setFill()
        NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
    }
}
