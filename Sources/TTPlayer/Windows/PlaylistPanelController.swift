import AppKit

/// 播放列表独立面板（停靠组的第二块窗）：
/// 工具条「添加 删除 列表 排序 查找 编辑 模式」→ 左列表组 + 右歌曲表
/// 顶部不再有标题条，开关走主面板底部的「列表」键
final class PlaylistPanelWindow: SkinPanelWindow {
    override var contentHeight: CGFloat { MainWindowController.playlistPanelH }
}

final class PlaylistPanelController: NSObject {
    let window: PlaylistPanelWindow
    let playlistView: PlaylistView
    private let toolbar = NSStackView()
    private let groupWell = WellView()
    private let listWell = WellView()
    private let groupStack = NSStackView()
    private let groupCaption = NSTextField(labelWithString: "播放列表")
    private let listCaption = NSTextField(labelWithString: "歌曲列表")
    private let infoField = NSTextField(labelWithString: "共 0 首")
    /// 派生组空表时表格中央那句提示（点一下组名总得看见变化）
    private let emptyHint = NSTextField(labelWithString: "")
    private var groupItems: [GroupItemView] = []
    private var sortAscending = true
    private var searchKeyword = ""
    /// 上次输入的电台地址（弹框预填，手滑取消也不丢）
    private var radioInput = ""

    private let controller = PlayerController.shared

    init(width: CGFloat) {
        let height = MainWindowController.playlistPanelH
        window = PlaylistPanelWindow(width: width, height: height, title: "播放列表")
        playlistView = PlaylistView(frame: .zero)
        super.init()

        buildToolbar()
        buildBodies()
        subscribe()
        updateInfo()
    }

    // MARK: - 搭建

    private func buildToolbar() {
        func tool(_ title: String, _ action: Selector, _ tip: String) -> TTButton {
            let b = TTButton(.title(title), target: self, action: action,
                             size: NSSize(width: CGFloat(12 + title.count * 13), height: 20),
                             face: .flatOnLight)
            b.toolTip = tip
            return b
        }
        toolbar.orientation = .horizontal
        toolbar.spacing = 3
        toolbar.distribution = .fill
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addArrangedSubview(tool("添加", #selector(addAction), "添加文件或文件夹（⌘O）"))
        toolbar.addArrangedSubview(tool("电台", #selector(radioAction), "添加网络电台（粘贴 http/https 地址）"))
        toolbar.addArrangedSubview(tool("删除", #selector(removeAction), "从列表删除选中曲目"))
        toolbar.addArrangedSubview(tool("列表", #selector(listAction(_:)), "保存/载入播放列表（m3u）"))
        toolbar.addArrangedSubview(tool("排序", #selector(sortAction(_:)), "按标题/艺术家/时长排序"))
        toolbar.addArrangedSubview(tool("查找", #selector(findAction), "按关键字跳到下一首匹配曲"))
        toolbar.addArrangedSubview(tool("编辑", #selector(editAction), "修改当前曲目的标题/艺术家"))
        toolbar.addArrangedSubview(tool("模式", #selector(modeAction(_:)), "播放方式（F1~F4）"))

        window.skinRoot.addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: window.skinRoot.topAnchor, constant: 6),
            toolbar.leadingAnchor.constraint(equalTo: window.skinRoot.leadingAnchor, constant: 8),
            toolbar.heightAnchor.constraint(equalToConstant: 20),
        ])

        infoField.font = Theme.tinyFont
        infoField.textColor = Theme.titleText
        infoField.alignment = .right
        infoField.translatesAutoresizingMaskIntoConstraints = false
        window.skinRoot.addSubview(infoField)
        NSLayoutConstraint.activate([
            infoField.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            infoField.trailingAnchor.constraint(equalTo: window.skinRoot.trailingAnchor, constant: -8),
            infoField.leadingAnchor.constraint(greaterThanOrEqualTo: toolbar.trailingAnchor, constant: 8),
        ])
    }

    private func buildBodies() {
        groupWell.dark = true
        listWell.dark = true
        for w in [groupWell, listWell] as [WellView] {
            w.cornerRadius = 4
            w.translatesAutoresizingMaskIntoConstraints = false
            window.skinRoot.addSubview(w)
        }
        for label in [groupCaption, listCaption] as [NSTextField] {
            label.font = Theme.tinyFont
            label.textColor = Theme.textSecondary
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        groupWell.addSubview(groupCaption)
        listWell.addSubview(listCaption)

        // 左栏：列表组（点名字切列表，是真的换内容，不是摆设）
        groupStack.orientation = .vertical
        groupStack.spacing = 2
        groupStack.alignment = .leading
        groupStack.translatesAutoresizingMaskIntoConstraints = false
        for (i, name) in Self.groupNames.enumerated() {
            let item = GroupItemView(title: name, selected: i == 0)
            item.translatesAutoresizingMaskIntoConstraints = false
            item.widthAnchor.constraint(equalToConstant: 110).isActive = true
            item.heightAnchor.constraint(equalToConstant: 20).isActive = true
            item.onClick = { [weak self] in self?.selectGroup(GroupKind(rawValue: i) ?? .main) }
            groupItems.append(item)
            groupStack.addArrangedSubview(item)
        }
        groupWell.addSubview(groupStack)

        emptyHint.font = Theme.smallFont
        emptyHint.textColor = Theme.textSecondary
        emptyHint.alignment = .center
        emptyHint.isHidden = true
        emptyHint.translatesAutoresizingMaskIntoConstraints = false

        playlistView.translatesAutoresizingMaskIntoConstraints = false
        listWell.addSubview(playlistView)
        // 提示压表格上面加：表格是透明的，但后加的视图才保证在它之上
        listWell.addSubview(emptyHint)

        let bodyTop = toolbar.bottomAnchor
        NSLayoutConstraint.activate([
            groupWell.topAnchor.constraint(equalTo: bodyTop, constant: 4),
            groupWell.leadingAnchor.constraint(equalTo: window.skinRoot.leadingAnchor, constant: 6),
            groupWell.widthAnchor.constraint(equalToConstant: 122),
            groupWell.bottomAnchor.constraint(equalTo: window.skinRoot.bottomAnchor, constant: -6),

            groupCaption.topAnchor.constraint(equalTo: groupWell.topAnchor, constant: 4),
            groupCaption.leadingAnchor.constraint(equalTo: groupWell.leadingAnchor, constant: 6),
            groupStack.topAnchor.constraint(equalTo: groupCaption.bottomAnchor, constant: 4),
            groupStack.leadingAnchor.constraint(equalTo: groupWell.leadingAnchor, constant: 4),
            groupStack.bottomAnchor.constraint(lessThanOrEqualTo: groupWell.bottomAnchor, constant: -4),

            listWell.topAnchor.constraint(equalTo: bodyTop, constant: 4),
            listWell.leadingAnchor.constraint(equalTo: groupWell.trailingAnchor, constant: 4),
            listWell.trailingAnchor.constraint(equalTo: window.skinRoot.trailingAnchor, constant: -6),
            listWell.bottomAnchor.constraint(equalTo: window.skinRoot.bottomAnchor, constant: -6),

            listCaption.topAnchor.constraint(equalTo: listWell.topAnchor, constant: 4),
            listCaption.leadingAnchor.constraint(equalTo: listWell.leadingAnchor, constant: 6),
            playlistView.topAnchor.constraint(equalTo: listCaption.bottomAnchor, constant: 3),
            playlistView.leadingAnchor.constraint(equalTo: listWell.leadingAnchor, constant: 3),
            playlistView.trailingAnchor.constraint(equalTo: listWell.trailingAnchor, constant: -3),
            playlistView.bottomAnchor.constraint(equalTo: listWell.bottomAnchor, constant: -3),

            emptyHint.centerXAnchor.constraint(equalTo: listWell.centerXAnchor),
            emptyHint.centerYAnchor.constraint(equalTo: listWell.centerYAnchor),
            emptyHint.leadingAnchor.constraint(greaterThanOrEqualTo: listWell.leadingAnchor, constant: 8),
        ])
    }

    /// 左栏的列表组名字（与 GroupKind 一一对应）
    static let groupNames = GroupKind.allCases.map { $0.name }

    // MARK: - 事件

    /// 工具条按钮数（自检用：添加/电台/删除/列表/排序/查找/编辑/模式）
    var toolbarButtonCount: Int { toolbar.arrangedSubviews.count }

    /// 自检用：左栏有几个组（五个组名共用一个条目尺寸，面板高度不够就会看不出被裁）
    var groupItemCount: Int { groupItems.count }

    /// 工具条本身（自检用：确认面板顶部直接就是它，不再有标题条占位）
    var toolbarView: NSView { toolbar }

    /// 当前选中的组（左栏高亮与控制器保持一致）
    var selectedGroup: GroupKind { controller.activeGroup }

    /// 切到某组：左栏高亮、列表内容、标题/统计一起变
    func selectGroup(_ kind: GroupKind) {
        // switchGroup 会发 ttPlaylistChanged，下面的 playlistChanged 统一收尾
        controller.switchGroup(kind)
        syncGroupItems()
        updateInfo()
    }

    /// 左栏高亮跟着控制器的当前组走（加歌、拖入、清空都会回 [默认]）
    private func syncGroupItems() {
        let active = controller.activeGroup.rawValue
        for (i, item) in groupItems.enumerated() { item.selected = i == active }
    }

    /// 自检用：走一遍真实的点击链路（mouseDown → onClick）
    func clickGroup(at index: Int) {
        guard groupItems.indices.contains(index) else { return }
        groupItems[index].performClick()
    }

    /// 自检用：派生组空表时中央那句提示露出来没有
    var showsEmptyHint: Bool { !emptyHint.isHidden && !emptyHint.stringValue.isEmpty }

    /// 自检用：那一行统计文字（电台两页的计数单位得是「台」）
    var infoText: String { infoField.stringValue }

    /// 自检用：最后一个组条目还完整落在左栏里吗。面板不会跟着组数长高，
    /// 组数再涨就得看看最后一行有没有被裁掉
    var groupsFitInWell: Bool {
        window.contentView?.layoutSubtreeIfNeeded()
        guard let last = groupItems.last else { return false }
        return groupWell.bounds.contains(last.convert(last.bounds, to: groupWell))
    }

    private func subscribe() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(playlistChanged), name: .ttPlaylistChanged, object: nil)
        nc.addObserver(self, selector: #selector(trackChanged(_:)), name: .ttTrackChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func playlistChanged() {
        syncGroupItems()
        updateInfo()
    }
    @objc private func trackChanged(_ note: Notification) { updateInfo() }

    private func updateInfo() {
        let pl = controller.playlist
        switch controller.activeGroup {
        case .main:
            infoField.stringValue = pl.isEmpty ? "空列表"
                : "共 \(pl.count) 首 · \(TimeFormat.clock(pl.totalDuration))"
            listCaption.stringValue = pl.isEmpty ? "歌曲列表" : "歌曲列表（\(pl.count)）"
        case .recent, .favorites:
            let name = controller.activeGroup.name
            infoField.stringValue = pl.isEmpty ? "\(name) 为空" : "\(name) \(pl.count) 首"
            listCaption.stringValue = "\(name)（\(pl.count)）"
            // 表格空着但组已经切过去了：中央给一句“这里会有什么”
            emptyHint.stringValue = controller.activeGroup.emptyHint ?? ""
        case .radio, .recentRadio:
            // 电台两页：单位是「台」不是「首」，这里放的是地址，“首”听起来像本地曲目数错了
            let name = controller.activeGroup.name
            infoField.stringValue = pl.isEmpty ? "\(name) 为空" : "\(name) \(pl.count) 个台"
            listCaption.stringValue = "\(name)（\(pl.count)）"
            emptyHint.stringValue = controller.activeGroup.emptyHint ?? ""
        }
        emptyHint.isHidden = !(pl.isEmpty && controller.activeGroup.isDerived)
    }

    @objc private func addAction() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "添加"
        panel.message = "选择音乐文件或文件夹"
        if panel.runModal() == .OK {
            let added = controller.addFiles(panel.urls, playNow: controller.currentTrack == nil)
            if added > 0 { playlistView.scrollToCurrent() }
        }
    }

    /// 工具条「电台」键与主菜单「添加网络电台…」共用：弹输入框，地址交给 PlayerController 归一化
    @objc func promptAddRadio() {
        let alert = NSAlert()
        alert.messageText = "添加网络电台"
        alert.informativeText = "粘贴电台地址（http:// 或 https://）。加进列表后双击即可收听。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "http://example.com/live.mp3"
        field.stringValue = radioInput
        alert.accessoryView = field
        alert.addButton(withTitle: "添加并播放")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        radioInput = field.stringValue
        if let problem = controller.addRadio(field.stringValue) {
            // 地址不合法：只说一句原因，不要再叠一层看不懂的系统弹窗
            let warn = NSAlert()
            warn.messageText = "这个地址加不进去"
            warn.informativeText = problem
            warn.addButton(withTitle: "好")
            warn.runModal()
            return
        }
        playlistView.scrollToCurrent()
    }

    @objc private func radioAction() { promptAddRadio() }

    @objc private func removeAction() {
        var rows = playlistView.selectedRowIndexes
        let target = playlistView.targetRow
        if rows.isEmpty, target >= 0 { rows = IndexSet(integer: target) }
        guard !rows.isEmpty else { return }
        controller.removeTracks(at: rows)
    }

    @objc private func listAction(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "保存列表为 m3u…", action: #selector(saveListAsM3U), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "载入列表…", action: #selector(openListM3U), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "清空列表", action: #selector(clearList), keyEquivalent: "")
            .target = self
        menu.popUp(under: sender)
    }

    @objc private func saveListAsM3U() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "播放列表.m3u"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !controller.playlist.exportAsM3U(to: url) {
            Diagnostics.log("ERROR 列表导出失败 \(url.path)")
        }
    }

    @objc private func openListM3U() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择 m3u 播放列表"
        if panel.runModal() == .OK, let url = panel.url {
            // 走统一的导入入口：m3u 解析规则（相对路径、保序、cue 分轨）只在 LibraryStore 一处
            let added = controller.addFiles([url])
            if added > 0 { playlistView.scrollToCurrent() }
            Diagnostics.log("列表载入 +\(added) \(url.lastPathComponent)")
        }
    }

    @objc private func clearList() { controller.clearPlaylist() }

    @objc private func sortAction(_ sender: NSButton) {
        let menu = NSMenu()
        for key: Playlist.SortKey in [.title, .artist, .album, .duration, .fileName] {
            for asc in [true, false] {
                let item = menu.addItem(withTitle: "按\(key.rawValue)\(asc ? "升序" : "降序")",
                                        action: #selector(applySort(_:)), keyEquivalent: "")
                item.target = self
                item.tag = asc ? 1 : 0
                item.representedObject = key.rawValue
            }
        }
        menu.popUp(under: sender)
    }

    @objc private func applySort(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let key = Playlist.SortKey(rawValue: raw) else { return }
        controller.playlist.sort(by: key, ascending: sender.tag == 1)
        NotificationCenter.default.post(name: .ttPlaylistChanged, object: nil)
        playlistView.scrollToCurrent()
        Diagnostics.log("列表按 \(raw) 排序")
    }

    @objc private func findAction() {
        let alert = NSAlert()
        alert.messageText = "在播放列表中查找"
        alert.informativeText = "输入曲名/艺术家关键字，回车跳到下一首匹配。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = searchKeyword
        field.placeholderString = "关键字"
        alert.accessoryView = field
        alert.addButton(withTitle: "查找")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        searchKeyword = field.stringValue
        guard !searchKeyword.isEmpty else { return }
        let from = playlistView.targetRow >= 0 ? playlistView.targetRow : controller.playlist.currentIndex
        if let hit = controller.playlist.indexOfNext(matching: searchKeyword, after: from) {
            playlistView.focusRow(hit)
        } else {
            NSSound.beep()
        }
    }

    @objc private func editAction() {
        let row = playlistView.targetRow
        guard row >= 0, let track = controller.playlist.track(at: row) else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = "编辑标签"
        alert.informativeText = track.fileName
        let title = NSTextField(frame: NSRect(x: 0, y: 46, width: 250, height: 24))
        title.stringValue = track.title
        title.placeholderString = "标题"
        let artist = NSTextField(frame: NSRect(x: 0, y: 16, width: 250, height: 24))
        artist.stringValue = track.artist
        artist.placeholderString = "艺术家"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 76))
        box.addSubview(title)
        box.addSubview(artist)
        alert.accessoryView = box
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        track.title = title.stringValue.isEmpty ? track.fileName : title.stringValue
        track.artist = artist.stringValue
        NotificationCenter.default.post(name: .ttPlaylistChanged, object: nil)
        NotificationCenter.default.post(name: .ttTrackChanged, object: nil,
                                       userInfo: ["track": track])
    }

    @objc private func modeAction(_ sender: NSButton) {
        let menu = NSMenu()
        for mode in PlayMode.allCases {
            let item = menu.addItem(withTitle: mode.displayName,
                                    action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode.rawValue
            item.state = controller.playMode == mode ? .on : .off
        }
        menu.popUp(under: sender)
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        controller.setMode(PlayMode(rawValue: sender.tag) ?? .listLoop)
    }
}

/// 左栏的列表组条目：自绘选中底，单击切组
private final class GroupItemView: NSView {
    let title: String
    var selected: Bool { didSet { needsDisplay = true } }
    /// 单击回调（由面板接到 selectGroup）
    var onClick: (() -> Void)?
    private var isHot = false
    private var trackingAreaRef: NSTrackingArea?

    init(title: String, selected: Bool) {
        self.title = title
        self.selected = selected
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseEntered(with event: NSEvent) { isHot = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHot = false; needsDisplay = true }

    /// 单击真的切组；鼠标与自检都走这里，避免两套路径
    override func mouseDown(with event: NSEvent) { performClick() }

    func performClick() { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 3, bounds.height > 3 else { return }
        if selected || isHot {
            (selected ? Theme.textAccent : Theme.flatHotBG).withAlphaComponent(selected ? 0.28 : 1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.tinyFont,
            .foregroundColor: selected ? Theme.textAccent : Theme.textPrimary,
        ]
        let str = title as NSString
        let sz = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: 5, y: bounds.midY - sz.height / 2), withAttributes: attrs)
    }
}
