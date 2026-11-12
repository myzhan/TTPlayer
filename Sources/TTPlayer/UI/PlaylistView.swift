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
    /// F05「清除筛选」：只在条件生效时露出来
    private var clearFilterItem: NSMenuItem?
    /// F03 队列两项：选中行里一个曲目都取不到时置灰（空列表）
    private var playNextItem: NSMenuItem?
    private var playLaterItem: NSMenuItem?
    /// F04「加入歌单」子菜单：项是每次弹菜单时按当前歌单列表重建的
    private var addToListItem: NSMenuItem?
    /// F08「从列表删除」与「重新定位文件…」：媒体库页不接受删行，
    /// 而重新定位只对「盘上已经找不到」的那一行有意义
    private var removeItem: NSMenuItem?
    private var relocateItem: NSMenuItem?
    private let relocateMenu = NSMenu()
    private let addToListMenu = NSMenu()
    /// F11 电台四项：只在右键落到电台行时露出来（本地文件那几项对它们没意义）
    private var radioGroup: [NSMenuItem] = []
    private var radioNameItem: NSMenuItem?
    private var radioEditItem: NSMenuItem?
    private var radioMoveItem: NSMenuItem?
    private var radioRetryItem: NSMenuItem?
    private let radioMoveMenu = NSMenu()

    // MARK: - F05 即时搜索与筛选

    /// 当前筛选条件。只影响「哪些行看得见」：`Playlist`、播放队列、存档都不经由它改动
    private var filter = TrackFilter.none
    /// 结果行 → 原列表行。没条件时是空数组走恒等映射（一万行不必每次建表）
    private var rowMap: [Int] = []
    /// rowMap 是哪一版列表内容算出来的（`Playlist.revision`）：-1 = 还没算过
    private var mappedRevision = -1
    /// 进筛选之前的现场：选中了哪几首（原列表行）+ 滚到哪，清除筛选时还回去
    private var sceneBeforeFilter: (selection: IndexSet, origin: NSPoint)?
    /// 攒着还没生效的条件（敲字防抖）与「该重算一次可见行」的合并标记
    private var pendingFilter: TrackFilter?
    private var pendingRefresh = false
    private var filterTimer: Timer?
    /// 本视图当前停在哪个组：换页要把筛选条件留在原来那一页
    private var groupSeen = GroupKind.main
    /// 进搜索之前那一页的现场：哪一页 + 选中了哪几首（身份）+ 滚到哪。
    /// 命中表把整页内容换掉了，退回来时不能把用户丢在列表顶上
    private var sceneBeforeSearch: (group: GroupKind, keys: [String], origin: NSPoint)?
    /// 上一次收尾时控制器在不在搜索态：只有「进/出」那一次才动现场
    private var viewWasSearching = false
    /// 可见结果变了（换条件、换页、元数据晚到）：面板拿它同步搜索框文字、结果数与空状态
    var onResultsChanged: ((TrackFilter) -> Void)?

    /// 一万行列表每敲一个字全扫一遍是能感觉到的卡顿，120 ms 足够让用户觉得「跟着字走」
    private static let filterDebounce: TimeInterval = 0.12

    /// 歌单页行内拖动排序用的拖拽类型（与队列面板同一套做法：自定义类型只在本表内部用）
    static let listReorderType = NSPasteboard.PasteboardType(rawValue: "com.ttplayer.list.reorder")

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
        tableView.registerForDraggedTypes([.fileURL, Self.listReorderType])

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

    deinit {
        NotificationCenter.default.removeObserver(self)
        filterTimer?.invalidate()
    }

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
    func durationText(row: Int) -> String? { cellText(row: row, column: "cell_duration") }

    /// 供自检：读某行名称列的文字（筛选态要拿它确认序号写的仍是原列表位置）
    func titleText(row: Int) -> String? { cellText(row: row, column: "cell_name") }

    private func cellText(row: Int, column: String) -> String? {
        func text() -> String? {
            guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) else { return nil }
            for case let cell as NSTableCellView in rowView.subviews
            where cell.identifier == NSUserInterfaceItemIdentifier(column) {
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
        // 进搜索：记下这一页的现场；退搜索：只有回到同一页才把它落回去
        //（用户是点了左栏别的页才退出的，那种情况不该把上一页的滚动位置搬过来）
        let searchingNow = controller.isSearching
        var restoredScene: (group: GroupKind, keys: [String], origin: NSPoint)?
        if searchingNow != viewWasSearching {
            viewWasSearching = searchingNow
            if searchingNow {
                // 面板在把命中交给控制器之前已经取过现场了（那时候这一页还是原来的内容）。
                // 走到这里表格装的已经是命中表：再取一次只会存下「结果第几行」这种回去找不着人的东西。
                // 取到了就得留着 —— 它是退出时要还原的唯一依据
                if sceneBeforeSearch == nil {
                    sceneBeforeSearch = (groupSeen, selectedKeys(), scroll.contentView.bounds.origin)
                }
            } else {
                if let scene = sceneBeforeSearch, scene.group == controller.activeGroup {
                    restoredScene = scene
                }
                // 退出就用一次：用户是点了左栏别的页才退的，那份上一页的滚动位置不该搬过来
                sceneBeforeSearch = nil
            }
        }
        if groupSeen != controller.activeGroup {
            // 换页：关键字与勾选的格式属于上一页的现场，带过去只会让用户看见
            // 「搜不到东西却不知道为什么」（下一页根本没有那些曲目）
            groupSeen = controller.activeGroup
            resetFilter()
        }
        // `reloadData()` 会把表格选择清空：先按原列表口径记下选中了哪几首，
        // 不然在结果里选好了正要操作，一条元数据/播放通知就把选中抹干了
        let keep = selectedSourceRows
        // 结构变了（增删行/排序/切组）必须当场重算；只是元数据到了（revision 没变）就攒一次：
        // 一万行导入会跟着来上万条通知，每条都扫全表的话输入就被堵死了
        if isFiltering, controller.playlist.revision == mappedRevision {
            scheduleVisibilityRefresh()
        } else {
            refreshVisibility()
        }
        fitColumns()
        scheduleFit()
        tableView.reloadData()
        if let scene = restoredScene {
            applyScene(scene)
        } else {
            selectSourceRows(keep)
        }
        // 搜索态里整张表就是命中表：外面动了内容（加歌、改标签、别的页改了归属）
        // 都该让命中重算一次，否则用户要在结果里再敲一个字才看得见变化。
        // 重跑那一头命中没变就不重装，不会与这条通知绕成环
        if controller.isSearching { controller.scheduleSearchRerun() }
        // 面板和本视图监听的是同一条通知，谁先收到没保证：这里再推一次，
        // 让它拿到的结果数一定是重算之后的
        onResultsChanged?(filter)
    }

    @objc private func trackChanged(_ note: Notification) {
        let keep = selectedSourceRows
        tableView.reloadData()
        selectSourceRows(keep)
        scrollToCurrent()
        // 元数据晚到也会改变命中结果（标题/艺术家/专辑是异步填的）：
        // 但一条一条事件都去扫一万行会把主线程吃干，攒着刷
        if filter.isActive { scheduleVisibilityRefresh() }
        // 全局搜索态里标签晚到不只改行内文字：命中集本身可能多了几条，
        // 而表格这一页装的就是命中表，光重算可见行搜不出新东西来
        if controller.isSearching { controller.scheduleSearchRerun() }
    }

    /// 选中的是哪几首（身份口径）：跨页还原只能拿它找得人，行号到下一页就不一样了
    private func selectedKeys() -> [String] {
        selectedSourceRows.compactMap { controller.playlist.track(at: $0)?.identityKey }
    }

    /// 面板把关键字交给控制器之前先记一笔：从这一刻起这一页就要被命中表换掉，
    /// 退出搜索时还回去的选中行与滚动位置只能是现在这份现场
    func noteSceneBeforeSearch() {
        guard !controller.isSearching else { return }     // 已经在搜：留着最初那一份
        sceneBeforeSearch = (groupSeen, selectedKeys(), scroll.contentView.bounds.origin)
    }

    /// 把上一页的现场落回这张表：选中行按身份找回，滚动位置夹在「还滚得动」的范围里
    private func applyScene(_ scene: (group: GroupKind, keys: [String], origin: NSPoint)) {
        selectSourceRows(IndexSet(scene.keys.compactMap { controller.playlist.index(ofKey: $0) }))
        tableView.layoutSubtreeIfNeeded()
        let maxY = max(0, tableView.frame.height - scroll.contentView.bounds.height)
        let y = min(max(0, scene.origin.y), maxY)
        if abs(y - scroll.contentView.bounds.origin.y) > 0.5 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    func scrollToCurrent() {
        guard let i = controller.playlist.currentIndex else { return }
        // 当前曲被筛掉了就不滚：结果里没有它，滚过去只会把用户拽到别处
        guard let row = displayRow(forSource: i) else { return }
        tableView.scrollRowToVisible(row)
    }

    // MARK: - 行号换算（结果行 ↔ 原列表行）

    /// 当前条件（搜索框回填、菜单勾选、统计文案都读它）
    var currentFilter: TrackFilter { filter }
    /// 有没有条件生效中（哪怕一条都没命中也算）
    var isFiltering: Bool { filter.isActive }
    var totalCount: Int { controller.playlist.count }
    /// 表格里的行数（= 结果数）
    var visibleRowCount: Int { isFiltering ? rowMap.count : totalCount }
    /// 结果行 → 原列表行；不在可见集里返回 nil
    func sourceRow(forDisplay row: Int) -> Int? {
        guard row >= 0 else { return nil }
        guard isFiltering else { return row < totalCount ? row : nil }
        return row < rowMap.count ? rowMap[row] : nil
    }
    /// 原列表行 → 结果行（被筛掉的行没有结果行）
    func displayRow(forSource row: Int) -> Int? {
        guard row >= 0, row < totalCount else { return nil }
        guard isFiltering else { return row }
        return rowMap.firstIndex(of: row)
    }
    /// 结果行集合 → 原列表行集合（控制器那一边只认原列表下标）
    func sourceRows(forDisplay rows: IndexSet) -> IndexSet {
        guard isFiltering else { return rows }
        var out = IndexSet()
        for r in rows { if let s = sourceRow(forDisplay: r) { out.insert(s) } }
        return out
    }
    /// 原列表行集合 → 结果行集合（不在结果里的行丢掉，不硬塞一个位置给它）
    func displayRows(forSource rows: IndexSet) -> IndexSet {
        guard isFiltering else { return rows }
        var out = IndexSet()
        for r in rows { if let d = displayRow(forSource: r) { out.insert(d) } }
        return out
    }
    /// 结果里那一行是哪首歌
    func track(forDisplay row: Int) -> Track? {
        guard let src = sourceRow(forDisplay: row) else { return nil }
        return controller.playlist.track(at: src)
    }
    /// 供自检：可见行的身份序列（顺序就是表格里看到的顺序）
    var visibleKeys: [String] {
        let rows = isFiltering ? rowMap : Array(0..<totalCount)
        return rows.compactMap { controller.playlist.track(at: $0)?.identityKey }
    }

    /// 选中的是哪几首（原列表行）：工具条「删除」与控制器打交道只能用这个口径
    var selectedSourceRows: IndexSet { sourceRows(forDisplay: tableView.selectedRowIndexes) }

    /// 供自检：当前滚动位置（清除筛选要还原的就是它）
    var scrollOrigin: NSPoint { scroll.contentView.bounds.origin }

    /// 供自检：还能滚多远（文档高度扣掉可视区）。列表变短时还原的位置只能夹在这里
    var maxScrollY: CGFloat {
        tableView.layoutSubtreeIfNeeded()
        return max(0, tableView.frame.height - scroll.contentView.bounds.height)
    }

    /// 供自检：行多到滚得动了吗（「还原滚动位置」只对长列表有意义）
    var documentOverflowViewport: Bool { tableView.frame.height > scroll.contentView.bounds.height + 0.5 }

    /// 面板「格式」菜单要用：这一页里真出现过的档
    var availableFormats: [String] { TrackFilter.formatOptions(in: controller.playlist.tracks) }

    // MARK: - 条件入口

    /// 搜索框/格式菜单的唯一入口。`debounced` = 打字那条路，先攒一小会儿再算
    func setFilter(_ newFilter: TrackFilter, debounced: Bool = false) {
        if filter == newFilter {
            // 又敲回原样（含防抖期间删干净）：攒着的那份不要了
            cancelPendingFilter()
            return
        }
        // 只有「还在往里加东西」才值得防抖；清除与勾选格式要立刻见效
        if debounced, newFilter.isActive, newFilter.formats == filter.formats {
            pendingFilter = newFilter
            scheduleFilterTimer(reset: true)
            return
        }
        cancelPendingFilter()
        applyFilter(newFilter)
    }

    /// 清除筛选：立刻生效（不走防抖），并恢复搜索前的选择与滚动位置
    func clearFilter() {
        cancelPendingFilter()
        applyFilter(.none)
    }

    /// 换页/收尾用：把条件与现场一起丢掉，但不还原上一页的滚动位置
    private func resetFilter() {
        cancelPendingFilter()
        sceneBeforeFilter = nil
        filter = .none
        rebuildRowMap()
        onResultsChanged?(filter)
    }

    /// 真正换条件：只重算可见行，原列表/排序/队列一律不动
    private func applyFilter(_ newFilter: TrackFilter) {
        let wasActive = filter.isActive
        let keep = selectedSourceRows
        if !wasActive && newFilter.isActive {
            // 记下进筛选前的现场，清除时原样还回去
            sceneBeforeFilter = (keep, scroll.contentView.bounds.origin)
        }
        filter = newFilter
        rebuildRowMap()
        tableView.reloadData()
        if wasActive && !newFilter.isActive {
            restoreSceneBeforeFilter()
        } else {
            selectSourceRows(keep)
        }
        onResultsChanged?(filter)
        Diagnostics.log(newFilter.isActive
            ? "筛选：\(newFilter.summary) → \(rowMap.count)/\(totalCount) 条"
            : "清除筛选：恢复 \(totalCount) 条")
    }

    /// 重算可见行（幂等）；条件为空时就是恒等映射，不必建表
    private func rebuildRowMap() {
        rowMap = filter.visibleRows(in: controller.playlist.tracks)
        mappedRevision = controller.playlist.revision
    }

    /// 列表内容变了（加歌/删除/排序/切组）：结果要跟上，选中行尽量保住
    private func refreshVisibility() {
        let keep = isFiltering ? selectedSourceRows : nil
        rebuildRowMap()
        if let keep { selectSourceRows(keep) }
    }

    /// 把「选中的是哪几首」按新的可见集落回表格（一条都不在结果里就真的什么都不选）
    private func selectSourceRows(_ rows: IndexSet) {
        let target = displayRows(forSource: rows)
        if target != tableView.selectedRowIndexes {
            tableView.selectRowIndexes(target, byExtendingSelection: false)
        }
    }

    /// 清除筛选：还原搜索前的选择与「还能用」的滚动位置（列表被改短了就夹到底）
    private func restoreSceneBeforeFilter() {
        guard let scene = sceneBeforeFilter else { return }
        sceneBeforeFilter = nil
        selectSourceRows(scene.selection)
        tableView.layoutSubtreeIfNeeded()
        let maxY = max(0, tableView.frame.height - scroll.contentView.bounds.height)
        let y = min(max(0, scene.origin.y), maxY)
        if abs(y - scroll.contentView.bounds.origin.y) > 0.5 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// 敲字那条路：手停下来才算一次，所以每次新输入都重置
    private func scheduleFilterTimer(reset: Bool) {
        if reset, let old = filterTimer {
            old.invalidate()
            filterTimer = nil            // 不清掉下面的 guard 会以为还有定时器在飞，这一轮就再也不生效了
        }
        guard filterTimer == nil else { return }
        let t = Timer(timeInterval: Self.filterDebounce, repeats: false) { [weak self] _ in
            self?.fireFilterTimer()
        }
        // .common：表格拖行、菜单跟踪这些模式下也要能收尾，不然条件会卡在没生效的状态
        RunLoop.main.add(t, forMode: .common)
        filterTimer = t
    }

    /// 元数据那种「事件一直来」的场合相反：不能每条都重置，否则永远不刷新结果。
    /// 至少每 120 ms 保证刷一次，刷完接着排下一次
    private func scheduleVisibilityRefresh() {
        guard filterTimer == nil else { return }
        pendingRefresh = true
        scheduleFilterTimer(reset: false)
    }

    private func fireFilterTimer() {
        filterTimer = nil
        if let next = pendingFilter {
            pendingFilter = nil
            applyFilter(next)
        } else if pendingRefresh {
            pendingRefresh = false
            refreshVisibility()
            tableView.reloadData()
            onResultsChanged?(filter)   // 结果数跟着元数据变了，标题那行得跟上
            scheduleVisibilityRefresh()  // 元数据还没读完就继续攒下一次
        }
    }

    private func cancelPendingFilter() {
        pendingFilter = nil
        pendingRefresh = false
        filterTimer?.invalidate()
        filterTimer = nil
    }

    /// 供自检/工具条读取行高与选中行
    var rowHeight: CGFloat { tableView.rowHeight }
    /// 表格本体（自检要确认它把拖放接在了系统方法上）
    var table: NSTableView { tableView }
    var numberOfRows: Int { visibleRowCount }
    var selectedRowIndexes: IndexSet { tableView.selectedRowIndexes }
    /// 当前高亮/选中行（表格里的**结果行**：与控制器打交道前先经 sourceRow 换成原列表行）
    var targetRow: Int {
        if tableView.clickedRow >= 0 { return tableView.clickedRow }
        if tableView.selectedRow >= 0 { return tableView.selectedRow }
        // 正在播的那首被筛掉了就不算目标行：工具条那几个键不能对看不见的行动手
        if let cur = controller.playlist.currentIndex, let row = displayRow(forSource: cur) { return row }
        return -1
    }
    /// 目标行的原列表下标（没有可见目标时 nil）
    var targetSourceRow: Int? { targetRow >= 0 ? sourceRow(forDisplay: targetRow) : nil }

    func refresh() {
        fitColumns()
        scheduleFit()
        tableView.reloadData()
    }

    /// 供自检：「加入歌单」子菜单此刻列出的名字（重建后读，与右键看到的同一份）
    var addToListTitles: [String] { addToListMenu.items.map { $0.title } }
    /// 供自检：「加入歌单」这一项能不能点
    var canAddToList: Bool { addToListItem?.isEnabled ?? false }
    /// 供自检：「清空…」那一项的标题（歌单页要带上歌单名，筛选中还要说清范围）
    var clearItemTitle: String? { clearItem?.title }
    /// 供自检：「从列表删除」能不能点（媒体库页置灰，那里不能删行）
    var canRemoveRows: Bool { removeItem?.isEnabled ?? false }
    /// 供自检：「重新定位文件…」能不能点（只有失效条目才开放）
    var canRelocateRow: Bool { relocateItem?.isEnabled ?? false }
    /// 供自检：重新定位子菜单此刻列出的候选（最后一项总是「其他位置…」）
    var relocateTitles: [String] { relocateMenu.items.map { $0.title } }
    /// 供自检：走与右键同一个入口把第 row 行重新定位到 newPath（菜单真按下去的就是那一段）
    @discardableResult
    func relocateRowThroughUI(_ row: Int, to newPath: String) -> String? {
        guard let track = track(forDisplay: row) ?? controller.playlist.track(at: row) else {
            return "没有这一行"
        }
        return relocate(track: track, to: newPath)
    }
    /// 供自检/面板：右键菜单里「清除筛选」这一项（不筛选时藏着，读到 nil）
    var clearFilterItemTitle: String? {
        guard let item = clearFilterItem, !item.isHidden else { return nil }
        return item.title
    }

    /// 供自检：按菜单真要打开时的同一路径重建一次（NSMenu 回调的就是 menuNeedsUpdate）
    func refreshContextMenus() {
        if let menu = tableView.menu { menuNeedsUpdate(menu) }
    }

    /// 供自检：选中这些行后点「加入歌单」里的某一张（与鼠标走同一个 action）
    func addRowsToListThroughUI(_ rows: IndexSet, list id: String) {
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        guard let item = addToListMenu.items.first(where: { $0.representedObject as? String == id })
        else { return }
        menuAddToList(item)
    }

    /// 供自检：把结果里的第 fromRow 行拖到第 toRow 行（与 acceptDrop 走同一段换算）
    @discardableResult
    func reorderListRowThroughUI(fromRow: Int, toRow: Int) -> Bool {
        guard let key = track(forDisplay: fromRow)?.identityKey else { return false }
        return applyListReorder(movedKeys: [key], toRow: toRow)
    }

    /// 选中并滚动到原列表的第 row 行（工具条“查找”用）。
    /// 筛选态下结果里没有这一行就不动，返回 false 让调用处说一句听话
    @discardableResult
    func focusRow(sourceRow row: Int) -> Bool {
        guard let display = displayRow(forSource: row) else { return false }
        tableView.selectRowIndexes(IndexSet(integer: display), byExtendingSelection: false)
        tableView.scrollRowToVisible(display)
        return true
    }

    /// 快捷查找：从结果行 `from` 往后环形找下一首命中关键字的曲。
    /// 筛选态只在可见行里找：跳到被筛掉的行上等于把用户从他在看的东西旁边拽走
    @discardableResult
    func focusNextMatch(after from: Int?, keyword: String) -> Bool {
        let hit = TrackFilter(keyword: keyword).matcher()
        let tracks = controller.playlist.tracks
        guard !hit.isEmpty, !tracks.isEmpty else { return false }
        let order: [Int] = isFiltering ? rowMap : Array(tracks.indices)
        guard !order.isEmpty else { return false }
        // 先把落点换成原列表行，再在 order 里找它之后的第一个：
        // order 里的行号本来就是递增的，不筛选时就等价于老口径的 from+1
        let anchor = from.flatMap { sourceRow(forDisplay: $0) }
        let pos = anchor == nil ? 0 : (order.firstIndex(where: { $0 > anchor! }) ?? 0)
        for offset in 0..<order.count {
            let src = order[(pos + offset) % order.count]
            if hit.hit(tracks[src]) { return focusRow(sourceRow: src) }
        }
        return false
    }

    @objc private func doubleClicked() { _ = playFromDisplayRow(tableView.clickedRow) }

    /// 播结果里的第 row 行：双击与自检走同一段换算，“这一行是哪首歌”只能在这一处定
    @discardableResult
    func playFromDisplayRow(_ row: Int) -> Bool {
        guard let src = sourceRow(forDisplay: row) else { return false }
        controller.playRowAt(src)
        return true
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
        removeItem = menu.addItem(withTitle: "从列表删除", action: #selector(menuRemove),
                                  keyEquivalent: "")
        removeItem?.target = self
        menu.addItem(.separator())
        // 排队两项只在浏览列表上动手，不重新起播 —— 声音得继续是当前曲（F03）
        playNextItem = menu.addItem(withTitle: "下一首播放", action: #selector(menuPlayNext),
                                    keyEquivalent: "")
        playNextItem?.target = self
        playLaterItem = menu.addItem(withTitle: "稍后播放", action: #selector(menuPlayLater),
                                     keyEquivalent: "")
        playLaterItem?.target = self
        menu.addItem(.separator())
        // 加入歌单：子菜单里是现有的每一张（无歌单时只一句提示并置灰）
        addToListItem = menu.addItem(withTitle: "加入歌单", action: nil, keyEquivalent: "")
        addToListMenu.autoenablesItems = false
        addToListItem?.submenu = addToListMenu
        menu.addItem(.separator())
        // F11：电台专属四项。整组在本地文件行上藏起来（置灰一排看不懂的入口不如不给）
        let radioSep = NSMenuItem.separator()
        menu.addItem(radioSep)
        radioNameItem = menu.addItem(withTitle: "自定义台名…", action: #selector(menuRadioName),
                                     keyEquivalent: "")
        radioNameItem?.target = self
        radioEditItem = menu.addItem(withTitle: "修改地址…", action: #selector(menuRadioEditURL),
                                     keyEquivalent: "")
        radioEditItem?.target = self
        radioMoveItem = menu.addItem(withTitle: "移入分类", action: nil, keyEquivalent: "")
        radioMoveMenu.autoenablesItems = false
        radioMoveItem?.submenu = radioMoveMenu
        radioRetryItem = menu.addItem(withTitle: "重试这个电台", action: #selector(menuRadioRetry),
                                      keyEquivalent: "")
        radioRetryItem?.target = self
        radioGroup = [radioSep, radioNameItem, radioEditItem, radioMoveItem, radioRetryItem]
            .compactMap { $0 }
        clearItem = menu.addItem(withTitle: "清空列表", action: #selector(menuClear), keyEquivalent: "")
        clearItem?.target = self
        // F08：重新定位。子菜单每次弹菜单重建：库里同名文件都列出来让用户选，
        // 加一项「其他位置…」走选文件面板（不拿同名就当是同一首）
        relocateItem = menu.addItem(withTitle: "重新定位文件…", action: nil, keyEquivalent: "")
        relocateMenu.autoenablesItems = false
        relocateItem?.submenu = relocateMenu
        revealItem = menu.addItem(withTitle: "在访达中显示", action: #selector(menuReveal),
                                  keyEquivalent: "")
        revealItem?.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "属性", action: #selector(menuProperties), keyEquivalent: "")
            .target = self
        // F05：筛选态里给一个就地清除入口（标题只有条件生效时才露出来）
        clearFilterItem = menu.addItem(withTitle: "清除筛选", action: #selector(menuClearFilter),
                                       keyEquivalent: "")
        clearFilterItem?.target = self
        clearFilterItem?.isHidden = true
        return menu
    }

    @objc func menuClearFilter() {
        // 搜索态里这一项说的是「退出搜索」（条件本身只剩格式档，清它不回到原来的页）
        if controller.isSearching { controller.endGlobalSearch() } else { clearFilter() }
    }

    @objc func menuToggleFavorite() {
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
        // 排队与加入歌单：只要选中的行里有能取到的曲目就可用（电台也能排，它本来就是可播条目）
        let picked = orderedSelectedTracks()
        playNextItem?.isEnabled = !picked.isEmpty
        playLaterItem?.isEnabled = !picked.isEmpty
        rebuildAddToList(items: picked)
        switch controller.activeGroup {
        case .main: clearItem?.title = "清空列表"
        case .library: clearItem?.title = "媒体库不能清空（想不收录请去菜单移除目录）"
        case .radio: clearItem?.title = "清空电台"
        case .radioCategory(let id):
            // 分类页与「网络电台」是同一套投影：清空 = 把这一页列的那几台从列表里删掉，
            // 不是移出分类（移出用「移入分类 → 未分类」）。标题必须把这层区别说在前面，
            // 否则用户以为自己只是收拾了一下归属，回头发现台没了
            clearItem?.title = "清空分类「\(controller.radioStations.name(of: id) ?? "")」的台（真删这几台，不是移出分类）"
        case .recentRadio: clearItem?.title = "清空最近听的台"
        case .recent: clearItem?.title = "清空最近播放"
        case .favorites: clearItem?.title = "清空收藏"
        case .playlist(let id):
            // 在歌单页上这一项只动这一张的引用，不动曲库（标题里把名字写清楚）
            clearItem?.title = "清空歌单「\(controller.userLists.name(of: id) ?? "")」"
        case .search:
            // 命中表不是一份内容：清它既不该把这几首歌从各个页里摘光（那是逐行删除的事，
            // 拿身份动手），也不该被当成清库。这一项在搜索态置灰
            clearItem?.title = "清空列表（搜索结果不是一份列表）"
        }
        let searching = controller.activeGroup == .search
        // 筛选中点「清空」清的是整页而不是结果：这一点必须写在标题里，
        // 不能让用户以为自己只删了看到的几首
        if isFiltering, !searching {
            clearItem?.title = "\(clearItem?.title ?? "清空列表")（全部 \(totalCount) 条，不只是结果）"
        }
        if searching {
            clearFilterItem?.isHidden = false
            clearFilterItem?.title = "退出搜索（回到 "
                + (controller.groupBeforeSearch?.name ?? GroupKind.main.name) + "）"
        } else {
            clearFilterItem?.isHidden = !isFiltering
            clearFilterItem?.title = "清除筛选（现只显 \(visibleRowCount) 条）"
        }
        // F08：这一页列的是盘上内容，删行与清空都不适用（真按下去控制器也会拒，
        // 但菜单不能留着能点的假入口）
        let library = controller.activeGroup == .library
        // 搜索页的「从列表删除」照旧可点：它拿身份去各处摘（见 removeSearchHits）
        removeItem?.isEnabled = !library && track != nil
        clearItem?.isEnabled = !library && !searching
        rebuildRelocate(for: track)
        // F11：电台四项跟着落点那一行走（多选时台名/地址只能一行一行改，入口就只给单行）
        applyRadioItems(for: track)
    }

    /// 电台专属菜单项的可见性与标题：落点不是电台就整组藏起来
    private func applyRadioItems(for track: Track?) {
        let isRadio = track?.isRadio == true
        for item in radioGroup { item.isHidden = !isRadio }
        guard let track, isRadio else { return }
        let named = controller.radioStations.hasCustomName(for: track.url)
        radioNameItem?.title = named ? "修改台名「\(track.title)」…" : "自定义台名…"
        radioRetryItem?.title = (controller.currentTrack?.identityKey == track.identityKey
            && controller.playbackProblem != nil)
            ? "重试这个电台（上次没连上）" : "重试这个电台"
        rebuildRadioMoveCategories(for: track)
    }

    /// 「移入分类」子菜单：未分类 + 每个分类，当前归属打个勾（看得出现在在哪家）
    private func rebuildRadioMoveCategories(for track: Track) {
        radioMoveMenu.removeAllItems()
        let current = controller.radioStations.categoryID(of: track.identityKey)
        let uncategorized = radioMoveMenu.addItem(withTitle: "未分类", action: #selector(menuRadioMove(_:)),
                                                  keyEquivalent: "")
        uncategorized.target = self
        uncategorized.state = current == nil ? .on : .off
        if controller.radioStations.isEmpty {
            // 一个分类都还没建：这一行看得见才知道入口在哪（左栏电台页右键 → 新建电台分类）
            let hint = radioMoveMenu.addItem(withTitle: "还没有分类：右键左栏「网络电台」新建", action: nil,
                                             keyEquivalent: "")
            hint.isEnabled = false
            return
        }
        for cat in controller.radioStations.categories {
            let item = radioMoveMenu.addItem(withTitle: cat.name, action: #selector(menuRadioMove(_:)),
                                             keyEquivalent: "")
            item.target = self
            item.representedObject = cat.id
            item.state = current == cat.id ? .on : .off
        }
    }

    @objc private func menuRadioMove(_ sender: NSMenuItem) {
        guard let track = clickedTrack(), track.isRadio else { return }
        let note = controller.moveRadios(keys: [track.identityKey],
                                         to: sender.representedObject as? String)
        if let note { showNote(note, title: "电台分类") }
    }

    @objc private func menuRadioName() {
        guard let track = clickedTrack(), track.isRadio else { return }
        let named = controller.radioStations.hasCustomName(for: track.url)
        let prefill = named ? track.title : ""
        guard let raw = promptLine(title: named ? "修改台名" : "自定义台名",
                                   message: "名字记在这个地址上：下次添加同一家电台、重启、导进来都是这个名字。"
                                        + "流里报的「正在播放」不会覆盖它；留空就是取消自定义，回到按地址显示。",
                                   placeholder: "台名（留空 = 取消自定义）",
                                   prefill: prefill) else { return }
        if let problem = applyRadioName(track: track, to: raw) { showNote(problem, title: "电台台名") }
    }

    @objc private func menuRadioEditURL() {
        guard let track = clickedTrack(), track.isRadio else { return }
        guard let raw = promptLine(title: "修改电台地址",
                                   message: "旧连接会当场停掉，台名、分类归属、收藏、最近播放与歌单引用"
                                        + "一起搬到新地址上（新地址已有同名台时先处理重复）。",
                                   placeholder: "http:// 或 https://",
                                   prefill: track.url.absoluteString) else { return }
        if let problem = applyRadioAddress(track: track, to: raw) { showNote(problem, title: "电台地址") }
    }

    @objc private func menuRadioRetry() {
        guard let track = clickedTrack(), track.isRadio else { return }
        if let problem = retryRadio(track: track) { showNote(problem, title: "电台重试") }
    }

    /// 问一行文本（台名/地址共用）：取消返回 nil
    private func promptLine(title: String, message: String, placeholder: String,
                            prefill: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.stringValue = prefill
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    // MARK: - F11 供自检（菜单项的真实执行体，不弹模态）

    /// 起/改/取消台名（`to` 留空 = 取消自定义）
    @discardableResult
    func applyRadioName(track: Track, to name: String) -> String? {
        controller.setRadioName(track, to: name)
    }

    /// 改地址（与「修改地址…」菜单项同一条路）
    @discardableResult
    func applyRadioAddress(track: Track, to raw: String) -> String? {
        controller.updateRadioAddress(track, to: raw)
    }

    /// 移入分类（nil = 未分类）
    @discardableResult
    func moveRadio(track: Track, to id: String?) -> String? {
        controller.moveRadios(keys: [track.identityKey], to: id)
    }

    /// 手动重试（与「重试这个电台」菜单项同一条路）
    @discardableResult
    func retryRadio(track: Track) -> String? {
        controller.retryRadio(track)
    }

    /// 自检用：当前右键菜单的项（不弹窗也能断言可见性与标题）
    var contextMenuItems: [NSMenuItem] { (tableView.menu?.items ?? []).filter { !$0.isHidden } }

    /// 自检专用：把右键落点定在第 row 行。真鼠标点不到时拿它顶替 `clickedRow`，
    /// 行号→曲目的换算仍然走 `track(forDisplay:)` 那一段，不能两套口径
    private var selftestClickedRow: Int?

    /// 自检用：按给定落点刷新右键菜单（等价于系统弹菜单那一刻的 menuNeedsUpdate），
    /// 返回没被藏起来的项；「移入分类」的子菜单项跟着 `radioMoveChoices` 读
    @discardableResult
    func refreshContextMenu(over row: Int) -> [NSMenuItem] {
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        selftestClickedRow = row
        defer { selftestClickedRow = nil }
        if let menu = tableView.menu { menuNeedsUpdate(menu) }
        return contextMenuItems
    }

    /// 自检用：刷新菜单后读「移入分类」子菜单（含打勾那一项）
    func radioMoveChoices(over row: Int) -> [NSMenuItem] {
        refreshContextMenu(over: row)
        return radioMoveMenu.items
    }

    /// 自检用：按标题在子菜单里找那一项并真走它的 action（与用户点下去同一条路）
    @discardableResult
    func clickRadioMoveItem(named title: String, over row: Int) -> Bool {
        let items = radioMoveChoices(over: row)
        guard let item = items.first(where: { $0.title == title }), item.isEnabled,
              let action = item.action else { return false }
        selftestClickedRow = row
        defer { selftestClickedRow = nil }
        performsActionOnMenu(item, action: action)
        return true
    }

    /// 把菜单项的 action 递回自己（target 就是本视图）：不依赖 responder chain
    private func performsActionOnMenu(_ item: NSMenuItem, action: Selector) {
        // `perform` 会带回 ObjC 方法的返回值（这里是 `Unmanaged<AnyObject>?`），
        // 我们只要副作用，不接住它编译会警告「结果未使用」
        _ = (item.target ?? self).perform(action, with: item)
    }

    /// 「重新定位文件…」子菜单：只有盘上找不到的那一行才有意义。
    /// 候选 = 库里各目录下的同名文件，一个都不替他挑；最后一项是「其他位置…」
    private func rebuildRelocate(for track: Track?) {
        relocateMenu.removeAllItems()
        guard let track, track.missingOnDisk, !track.isRadio else {
            relocateItem?.isEnabled = false
            return
        }
        let key = track.identityKey
        let hits = controller.relocateCandidates(for: key)
        if hits.isEmpty {
            let hint = relocateMenu.addItem(withTitle: "库里没有同名的文件", action: nil,
                                            keyEquivalent: "")
            hint.isEnabled = false
        }
        // 候选标题带上上一级目录：只写文件名时两个候选看起来一模一样
        for path in hits.prefix(12) {
            let item = relocateMenu.addItem(withTitle: Self.relocateTitle(path),
                                            action: #selector(menuRelocateTo(_:)),
                                            keyEquivalent: "")
            item.target = self
            item.representedObject = path
        }
        if hits.count > 12 {
            let more = relocateMenu.addItem(withTitle: "（另有 \(hits.count - 12) 个同名文件，请用「其他位置…」）",
                                             action: nil, keyEquivalent: "")
            more.isEnabled = false
        }
        relocateMenu.addItem(.separator())
        let browse = relocateMenu.addItem(withTitle: "其他位置…", action: #selector(menuRelocateBrowse),
                                           keyEquivalent: "")
        browse.target = self
        relocateItem?.isEnabled = true
    }

    /// 候选在菜单里怎么写：文件名 + 上一级目录（路径长了看不出来哪个是哪个）
    private static func relocateTitle(_ path: String) -> String {
        let ns = path as NSString
        let dir = ns.lastPathComponent
        let parent = (ns.deletingLastPathComponent as NSString).lastPathComponent
        return parent.isEmpty ? dir : "\(dir)（在「\(parent)」）"
    }

    /// 真的把一条引用改到新位置（菜单与自检都走这一条，不能两套口径）
    @discardableResult
    func relocate(track: Track, to newPath: String) -> String? {
        guard let problem = controller.relocate(key: track.identityKey, to: newPath) else {
            showNote("已重新定位：引用改到新位置，歌单、收藏、历史与待播队列一起跟上")
            return nil
        }
        showNote(problem)
        return problem
    }

    @objc private func menuRelocateTo(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, let track = clickedTrack() else { return }
        _ = relocate(track: track, to: path)
    }

    @objc private func menuRelocateBrowse() {
        guard let track = clickedTrack() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "定位到这里"
        panel.message = "为「\(track.title)」选一个新位置（同一条目的 CUE / 归档身份会保留）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = relocate(track: track, to: url.path)
    }

    /// 菜单里的一句话回执（与面板共用 NSAlert，不开新窗）。
    /// 自检模式下不弹：模态循环会把主线程扣住，而套件本来就按返回值断言，
    /// 这里只留一行日志给人看
    private func showNote(_ text: String, title: String = "媒体库") {
        guard ProcessInfo.processInfo.environment["TTPLAYER_SELFTEST"] == nil else {
            Diagnostics.log("\(title)提示：\(text)")
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// 「加入歌单」子菜单：每张歌单一行，按显示顺序把选中曲目加进去
    private func rebuildAddToList(items: [Track]) {
        addToListMenu.removeAllItems()
        let lists = controller.userLists
        if lists.isEmpty {
            let hint = addToListMenu.addItem(withTitle: "还没有歌单：右键左栏→「新建歌单…」",
                                             action: nil, keyEquivalent: "")
            hint.isEnabled = false
        } else {
            for list in lists.items {
                let item = addToListMenu.addItem(withTitle: list.name,
                                                 action: #selector(menuAddToList(_:)),
                                                 keyEquivalent: "")
                item.target = self
                item.representedObject = list.id
            }
        }
        // 没选东西或本来就在这一张里也不是错事，但菜单项得置灰，不能点下去什么都不发生
        addToListItem?.isEnabled = !lists.isEmpty && !items.isEmpty
    }

    @objc private func menuAddToList(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        _ = controller.addTracks(orderedSelectedTracks(), toList: id)
    }

    @objc private func menuPlay() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard let src = sourceRow(forDisplay: row) else { return }
        controller.playRowAt(src)
    }

    @objc func menuRemove() {
        // 多选右键：删除要拿原列表行去找控制器，结果行号直接递上去会删错人
        let rows = sourceRows(forDisplay: clickedRows())
        guard !rows.isEmpty else { return }
        controller.removeTracks(at: rows)
    }

    /// 右键落点那一行如果不在已多选中，就只当它一条（和「从列表删除」一个规矩）
    /// 返回的是表格里的结果行
    private func clickedRows() -> IndexSet {
        var rows = tableView.selectedRowIndexes
        if !rows.contains(tableView.clickedRow), tableView.clickedRow >= 0 {
            rows = IndexSet(integer: tableView.clickedRow)
        }
        return rows
    }

    /// 按显示顺序取曲目：多选时用户看到的就是这个顺序，排队与加入歌单的次序不能按
    /// IndexSet 内部乱序来，也不能拿结果行号去当原列表下标用
    private func orderedSelectedTracks() -> [Track] {
        clickedRows().sorted().compactMap { track(forDisplay: $0) }
    }

    @objc func menuPlayNext() {
        let tracks = orderedSelectedTracks()
        guard !tracks.isEmpty else { return }
        controller.playNext(tracks)
    }

    @objc func menuPlayLater() {
        let tracks = orderedSelectedTracks()
        guard !tracks.isEmpty else { return }
        controller.playLater(tracks)
    }

    @objc func menuClear() {
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
        let row = selftestClickedRow ?? (tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow)
        return track(forDisplay: row)
    }
}

// MARK: - 数据源 / 代理

extension PlaylistView: NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleRowCount
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = Column(rawValue: tableColumn?.identifier.rawValue ?? "") else { return nil }
        // row 是表格里的结果行，取曲与判当前都要先换成原列表行
        guard let src = sourceRow(forDisplay: row) else { return nil }
        let isCurrent = controller.playlist.currentIndex == src
        let track = controller.playlist.track(at: src)

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
            // 截图样式：序号. 艺术家 - 标题（艺术家缺失时只写标题）。
            // 序号写原列表里的位置：结果行只是「第几条匹配」，拿它当序号会让用户
            // 以为列表被重新排过（搜完清除后序号又变回去，那就是假的）
            let head = (track?.artist ?? "").isEmpty ? (track?.title ?? "")
                : "\(track?.artist ?? "") - \(track?.title ?? "")"
            var line = "\(src + 1). \(head)"
            // 全局搜索的命中表里补一句「它还在哪几页」：那一页就是把好几个页拍成了一张表，
            // 不写来源就看不出「收藏里也有它」，而删这一行会连收藏一起删
            if controller.isSearching, let key = track?.identityKey {
                line += controller.searchAnnotation(for: key)
            }
            text = line
        case .duration:
            // 引用失效：文件不在了但条目还在（只可能在歌单页），时长位置拿来说状态
            // 比留一个“...” 诚实：那个点本来就是「还没解析完」的意思
            if track?.missingOnDisk == true {
                text = "缺失"
            } else if track?.isRadio == true {
                // 电台是直播：没有总长，“...”会让人以为还没解析完
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
        rv.isCurrentRow = sourceRow(forDisplay: row) != nil
            && sourceRow(forDisplay: row) == controller.playlist.currentIndex
        rv.isZebra = row % 2 == 1
        return rv
    }

    // 拖入文件/文件夹添加。名字必须是系统认的 acceptDrop:row:dropOperation:——
    // 原来写成自定义的 acceptDrag:，NSTableView 根本不会调用，等于拖进去没反应
    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        // 列表内部拖行是排序语义，只在歌单页生效（别的页拖行不改次序，也不当导入）
        if let source = info.draggingSource as? NSTableView, source === tableView {
            return info.draggingPasteboard.data(forType: Self.listReorderType) != nil ? .copy : []
        }
        return .copy
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        if let source = info.draggingSource as? NSTableView, source === tableView {
            guard let data = info.draggingPasteboard.data(forType: Self.listReorderType),
                  let keys = try? JSONDecoder().decode([String].self, from: data) else { return false }
            return applyListReorder(movedKeys: keys, toRow: row)
        }
        let urls = DragPayload.urls(from: info.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        let added = controller.addFiles(urls)
        if added > 0 { scrollToCurrent() }
        // 全都已经入过表也算这次拖放被接住，别让系统把拖影弹回去
        return true
    }

    /// 拖行开始：把「这几行是哪几条引用」写进拖拽板。拖到访达照旧走
    /// pasteboardWriterForRow 的文件地址，这一条类型只有本表自己认
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        guard controller.activeGroup.isUserPlaylist else { return }
        // rowIndexes 是筛选结果里的行，排序要的是身份，走映射取曲即可
        let keys = rowIndexes.sorted().compactMap { track(forDisplay: $0)?.identityKey }
        guard !keys.isEmpty, let data = try? JSONEncoder().encode(keys) else { return }
        session.draggingPasteboard.setData(data, forType: Self.listReorderType)
        // 默认的来源许可不包含自定义类型的内部移动，不声明一下落点不会亮
        //（这个开关在 NSTableView 上，不在 dragging session 上）
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
    }

    /// 把拖动的条目放到第 `row` 行所占的位置（一次提交，走控制器的整体重排）。
    /// 自检也经由这里，拖放与断言用的是同一段次序换算
    /// `row` 是表格里的结果行：筛选时落点要换成原列表里的插入位置，否则「拖到第 2 行」
    /// 会按结果序号插到列表前段去
    @discardableResult
    func applyListReorder(movedKeys rawKeys: [String], toRow row: Int) -> Bool {
        guard let id = controller.activeListID, row >= 0 else { return false }
        let anchor: Int
        if !isFiltering {
            anchor = row
        } else if let src = sourceRow(forDisplay: row) {
            anchor = src                                  // 落在某条可见结果上 = 插在它原位置前
        } else {
            anchor = totalCount                           // 落在结果末尾之下 = 插到列表末尾
        }
        // 多选拖动时系统会逐项回调，先去掉重复身份，否则移除后第二份就找不着了
        var seen = Set<String>()
        let keys = rawKeys.filter { seen.insert($0).inserted }
        guard !keys.isEmpty else { return false }
        var order = controller.userLists.keys(of: id)
        var moved: [String] = []
        for key in keys {
            guard order.contains(key) else { return false }   // 不是这一张的东西什么都不改
            order.removeAll { $0 == key }
            moved.append(key)
        }
        // 移除被拖条目后，落点越界就夹到队尾；「放到第 anchor 位」= 新序列里第 anchor 个
        let target = min(max(anchor, 0), order.count)
        order.insert(contentsOf: moved, at: target)
        return controller.reorderList(id: id, to: order)
    }

    // 列表向外部拖出（如拖到桌面 / 访达）
    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let track = track(forDisplay: row) else { return nil }
        return track.url as NSURL
    }

    func tableView(_ tableView: NSTableView,
                   namesOfPromisedFilesDroppedAtDestination dropDestination: URL,
                   forDraggedRowsWith indexSet: IndexSet) -> [String] {
        indexSet.compactMap { track(forDisplay: $0)?.url.lastPathComponent }
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
