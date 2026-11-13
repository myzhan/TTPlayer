import AppKit

/// 播放列表独立面板（停靠组的第二块窗）：
/// 工具条「添加 电台 删除 列表 排序 查找 编辑 模式 队列」→ 左列表组 + 右歌曲表
/// 顶部不再有标题条，开关走主面板底部的「列表」键
final class PlaylistPanelWindow: SkinPanelWindow {
    override var contentHeight: CGFloat { MainWindowController.playlistPanelH }
}

/// 标题行那个搜索框：Esc 就是把放大镜收回并退出搜索（只退焦点不退条件的话，
/// 用户下次回到列表看见的会是一张「什么都没搜到」的空表）。
/// 用普通 `NSTextField` 而不是 `NSSearchField`：后者自带一条 264pt 的必需宽度约束
///（字段里那个放大镜图标与取消按钮要地方），它会一直压住「收起 = 宽度 0」与
/// 「展开 150/90」那两条约束，连标题都被顶得只剩几个字。
/// 放大镜现在是自己的一颗键，字段里不需要再画一个
final class FilterSearchField: NSTextField {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

final class PlaylistPanelController: NSObject, NSTextFieldDelegate {
    let window: PlaylistPanelWindow
    let playlistView: PlaylistView
    private let toolbar = NSStackView()
    private let groupWell = WellView()
    private let listWell = WellView()
    /// 左栏那一列：歌单可以有很多张，装不下就得能滚
    private let groupScroll = NSScrollView()
    private let groupDoc = GroupDocView()
    private let groupCaption = NSTextField(labelWithString: "播放列表")
    private let listCaption = NSTextField(labelWithString: "歌曲列表")
    private let infoField = NSTextField(labelWithString: "共 0 首")
    /// 派生组空表时表格中央那句提示（点一下组名总得看见变化）
    private let emptyHint = NSTextField(labelWithString: "")
    /// F05 搜索框：关键字搜的是**整个播放器**（命中装在临时页「搜索结果」里），
    /// 格式档仍是这一页的条件，两者都归 `PlaylistView` 那份条件管
    private let searchField = FilterSearchField()
    /// 透明放大镜：收起时标题行只剩这颗键（平时不画底，融进 UI），点开才让搜索框占地方。
    /// 「搜索框常驻」在窄面板上吃掉一整行，而搜索不是常用到值得一直占着
    private lazy var searchToggle = TTButton(.symbol("magnifyingglass"), target: self,
                                             action: #selector(searchToggleAction),
                                             size: NSSize(width: 20, height: 16), face: .flat)
    /// 搜索框现在展开着没有（收起 = 隐藏 + 两条宽度约束的常量改 0）
    private var searchOpen = false
    /// 展开时搜索框该有的两条宽度：记住原值才能收回去再弹回来
    private var searchPreferredWidth: NSLayoutConstraint?
    private var searchMinWidth: NSLayoutConstraint?
    /// 逐字输入攒一下再搜：命中一次就换一整页表格，比页内筛选更重
    private var searchTimer: Timer?
    /// 上一次收尾时控制器在不在搜索态：用来发现「退出不是从搜索框走的」
    private var wasSearching = false
    /// 「格式」多选下拉：与关键字组合使用，勾上即为启用态（lit）
    private lazy var formatButton = TTButton(.title("格式"), target: self,
                                             action: #selector(formatAction(_:)),
                                             size: NSSize(width: 44, height: 16), face: .flat)
    private let formatMenu = NSMenu()
    private var groupItems: [GroupItemView] = []
    /// 与 groupItems 一一对应的组身份（歌单页多起来以后「第几行」不再等于身份）
    private var groupKinds: [GroupKind] = []
    private var sortAscending = true
    private var searchKeyword = ""
    /// 上次输入的电台地址（弹框预填，手滑取消也不丢）
    private var radioInput = ""
    /// 弹框里那两个控件只在弹框期间活着（`runModal` 是同步的，属性只为把它们留到
    /// 下拉回调那一刻）。用局部变量的话 target-action 拿不到地址栏
    private var radioField: NSTextField?
    private var radioPresetMenu: NSPopUpButton?

    private let controller = PlayerController.shared

    /// 工具条「队列」键的去处：队列面板是主面板管的独立窗，这里只转发一下
    var onToggleQueue: (() -> Void)?

    /// 一行条目的尺寸：面板不跟着歌单数长高，超出可视区就走滚动
    private static let groupItemW: CGFloat = 110
    /// 搜索框的两档宽度与防抖：与表格那一条页内防抖同一手感
    private static let searchW: CGFloat = 150
    private static let searchMinW: CGFloat = 90
    private static let searchDebounce: TimeInterval = 0.12
    private static let groupItemH: CGFloat = 20
    private static let groupRowH: CGFloat = 22

    init(width: CGFloat) {
        let height = MainWindowController.playlistPanelH
        window = PlaylistPanelWindow(width: width, height: height, title: "播放列表")
        playlistView = PlaylistView(frame: .zero)
        super.init()

        buildToolbar()
        buildBodies()
        subscribe()
        // 结果变了（换条件、换页、元数据晚到）都由视图推一下：面板自己不去拆条件
        playlistView.onResultsChanged = { [weak self] _ in self?.filterResultsChanged() }
        rebuildGroups()
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
        toolbar.addArrangedSubview(tool("队列", #selector(queueAction), "待播队列（下一首播放 / 稍后播放的条目）"))

        window.skinRoot.addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: window.skinRoot.topAnchor, constant: 6),
            toolbar.leadingAnchor.constraint(equalTo: window.skinRoot.leadingAnchor, constant: 8),
            toolbar.heightAnchor.constraint(equalToConstant: 20),
        ])

        infoField.font = Theme.tinyFont
        infoField.textColor = Theme.titleText
        infoField.alignment = .right
        // 歌单名是用户自己取的（最长 40 字）：统计文字装不下时截断，不能压到工具条那排键上
        infoField.lineBreakMode = .byTruncatingTail
        infoField.translatesAutoresizingMaskIntoConstraints = false
        infoField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        window.skinRoot.addSubview(infoField)
        // 工具条九键加起来的宽度已经接近面板宽度：统计文字跟工具条不重叠。
        // 这一条比文字自己的宽度重要（拉到截断为止），只剩「拉到最小宽时往后让」
        // 这种情形不能顶坏必需约束（AppKit 会打一堆冲突日志）
        let infoGap = infoField.leadingAnchor.constraint(greaterThanOrEqualTo: toolbar.trailingAnchor,
                                                          constant: 8)
        infoGap.priority = .defaultHigh
        NSLayoutConstraint.activate([
            infoField.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            infoField.trailingAnchor.constraint(equalTo: window.skinRoot.trailingAnchor, constant: -8),
            infoGap,
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

        // 左栏：列表组（点名字切列表，是真的换内容，不是摆设；右键是歌单的管理入口）
        // 条目用 frame 排：放在滚动文档视图里走约束会把高度顶死，歌单一多就滚不动
        groupScroll.drawsBackground = false
        groupScroll.backgroundColor = .clear
        groupScroll.borderType = .noBorder
        groupScroll.hasVerticalScroller = true
        groupScroll.autohidesScrollers = true
        groupScroll.scrollerStyle = .overlay
        groupScroll.hasHorizontalScroller = false
        groupScroll.translatesAutoresizingMaskIntoConstraints = false
        groupScroll.documentView = groupDoc
        groupWell.addSubview(groupScroll)

        emptyHint.font = Theme.smallFont
        emptyHint.textColor = Theme.textSecondary
        emptyHint.alignment = .center
        // 提示比列表宽时换行而不是把右半句裁掉：窄面板下被裁掉的正好是「怎么退出筛选」那半句
        emptyHint.lineBreakMode = .byWordWrapping
        emptyHint.maximumNumberOfLines = 2
        emptyHint.usesSingleLineMode = false
        emptyHint.cell?.wraps = true
        emptyHint.cell?.isScrollable = false
        emptyHint.isHidden = true
        emptyHint.translatesAutoresizingMaskIntoConstraints = false

        playlistView.translatesAutoresizingMaskIntoConstraints = false
        listWell.addSubview(playlistView)
        // 提示压表格上面加：表格是透明的，但后加的视图才保证在它之上
        listWell.addSubview(emptyHint)

        // F05：搜索控件摆在「歌曲列表」那一行的右边。不新起一行，面板高度、
        // 面板划分、三窗排布都没动，也就不必递增 skinLayoutVersion
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.controlSize = .small
        searchField.font = Theme.smallFont
        // 占位文案要短到 90pt 也装得下（窄面板下搜索框会缩）：完整口径说在鼠标提示里
        searchField.placeholderAttributedString = NSAttributedString(
            string: "搜索全部曲目",
            attributes: [.foregroundColor: Theme.shellDivider, .font: Theme.smallFont])
        // 带方角边框：不会像圆角框那样自己带一组必需尺寸约束
        searchField.isBezeled = true
        searchField.bezelStyle = .squareBezel
        // 敲字的地方就是最普通的白底深字：凹槽那套深色是给显示区用的，
        // 铺到这里只会让光标、选区与插入的字都看不清
        searchField.drawsBackground = true
        searchField.backgroundColor = .white
        searchField.textColor = Theme.titleText
        searchField.focusRingType = .none
        searchField.delegate = self
        // 回车与点 × 走 action（立刻见效），逐字输入走 controlTextDidChange（防抖）
        searchField.target = self
        searchField.action = #selector(searchCommit)
        searchField.onEscape = { [weak self] in self?.collapseSearch() }
        searchField.toolTip = "搜整个播放器：[默认]、媒体库、收藏、两份历史与每张歌单里的" +
            "标题/艺术家/专辑/文件名（⌘F 展开，Esc 或再点放大镜收起）"
        searchToggle.toolTip = "搜索全部曲目（⌘F）：点一下展开，再点一下收起"
        // 自绘按钮默认还是 frame 布局：不关掉它，AppKit 会按初始 frame 加上一组
        // 必需的 minX/width 约束，把整条标题行顶到另一个样子（搜索框会一直停在 264 宽）
        searchToggle.translatesAutoresizingMaskIntoConstraints = false
        formatButton.translatesAutoresizingMaskIntoConstraints = false
        formatButton.toolTip = "按音频格式筛选（可多选，与关键字组合）"
        formatMenu.autoenablesItems = false        // 自己管可用状态，不然系统按 target 重新置灰
        listWell.addSubview(searchToggle)
        listWell.addSubview(searchField)
        listWell.addSubview(formatButton)
        // 标题行至少留得下「匹配 0/5」这一句：宁可搜索框缩到 90 那一头，也不能把结果数截掉
        //（F05 要「明确显示结果数量」，而条件本身搜索框与格式键已经开着）
        let captionMin = listCaption.widthAnchor.constraint(greaterThanOrEqualToConstant: 72)
        captionMin.priority = NSLayoutConstraint.Priority(rawValue: 760)   // 高于搜索框那一条 750
        captionMin.isActive = true
        // 歌单名是用户自己取的：标题行挤不下时截断右边那半，不能压到搜索框
        listCaption.lineBreakMode = .byTruncatingTail
        listCaption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // 抗压缩优先级要低于下面那条 150pt 等宽约束：平级时布局引擎留着先建的那一条，
        // 搜索框就只肯按固有宽度铺开——收起时占着地方，展开时也听不进 150/90 这两档
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bodyTop = toolbar.bottomAnchor
        NSLayoutConstraint.activate([
            groupWell.topAnchor.constraint(equalTo: bodyTop, constant: 4),
            groupWell.leadingAnchor.constraint(equalTo: window.skinRoot.leadingAnchor, constant: 6),
            groupWell.widthAnchor.constraint(equalToConstant: 122),
            groupWell.bottomAnchor.constraint(equalTo: window.skinRoot.bottomAnchor, constant: -6),

            groupCaption.topAnchor.constraint(equalTo: groupWell.topAnchor, constant: 4),
            groupCaption.leadingAnchor.constraint(equalTo: groupWell.leadingAnchor, constant: 6),
            groupScroll.topAnchor.constraint(equalTo: groupCaption.bottomAnchor, constant: 4),
            groupScroll.leadingAnchor.constraint(equalTo: groupWell.leadingAnchor, constant: 4),
            groupScroll.trailingAnchor.constraint(equalTo: groupWell.trailingAnchor, constant: -4),
            groupScroll.bottomAnchor.constraint(equalTo: groupWell.bottomAnchor, constant: -4),

            listWell.topAnchor.constraint(equalTo: bodyTop, constant: 4),
            listWell.leadingAnchor.constraint(equalTo: groupWell.trailingAnchor, constant: 4),
            listWell.trailingAnchor.constraint(equalTo: window.skinRoot.trailingAnchor, constant: -6),
            listWell.bottomAnchor.constraint(equalTo: window.skinRoot.bottomAnchor, constant: -6),

            listCaption.topAnchor.constraint(equalTo: listWell.topAnchor, constant: 4),
            listCaption.leadingAnchor.constraint(equalTo: listWell.leadingAnchor, constant: 6),
            // 18pt 高刚好落在标题行自己的 3pt 间隙里，不去挤表格顶部（面板高度固定）
            searchField.centerYAnchor.constraint(equalTo: listCaption.centerYAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 18),
            // 放大镜紧贴「歌曲列表」右边，它的位置只跟着标题走：展开与收起都不动它
            searchToggle.centerYAnchor.constraint(equalTo: listCaption.centerYAnchor),
            searchToggle.leadingAnchor.constraint(equalTo: listCaption.trailingAnchor, constant: 6),
            searchToggle.widthAnchor.constraint(equalToConstant: 20),
            searchToggle.heightAnchor.constraint(equalToConstant: 16),
            // 搜索框挂在放大镜右边：宽度从 0 涨到 150 时它只会往右长。
            // 以前这一头是顶死在格式键左边的，一展开就是「框往左长、放大镜跟着往左跑」，
            // 整排在两边挤；改成只往右长以后，右边只能保证不盖住格式键（`<=`）
            searchField.leadingAnchor.constraint(equalTo: searchToggle.trailingAnchor, constant: 4),
            searchField.trailingAnchor.constraint(lessThanOrEqualTo: formatButton.leadingAnchor,
                                                  constant: -4),
            formatButton.trailingAnchor.constraint(equalTo: listWell.trailingAnchor, constant: -6),
            formatButton.centerYAnchor.constraint(equalTo: listCaption.centerYAnchor),
            formatButton.widthAnchor.constraint(equalToConstant: 44),
            formatButton.heightAnchor.constraint(equalToConstant: 16),
            playlistView.topAnchor.constraint(equalTo: listCaption.bottomAnchor, constant: 3),
            playlistView.leadingAnchor.constraint(equalTo: listWell.leadingAnchor, constant: 3),
            playlistView.trailingAnchor.constraint(equalTo: listWell.trailingAnchor, constant: -3),
            playlistView.bottomAnchor.constraint(equalTo: listWell.bottomAnchor, constant: -3),

            emptyHint.centerXAnchor.constraint(equalTo: listWell.centerXAnchor),
            emptyHint.centerYAnchor.constraint(equalTo: listWell.centerYAnchor),
            emptyHint.leadingAnchor.constraint(greaterThanOrEqualTo: listWell.leadingAnchor, constant: 8),
            emptyHint.trailingAnchor.constraint(lessThanOrEqualTo: listWell.trailingAnchor, constant: -8),
        ])
        // 搜索框的两条宽度约束要能改常量：收起就是把 150/90 一起写成 0（宽度 0 + 隐藏），
        // 而不是摘掉约束再装回去 —— 那种做法在窄面板下会让标题行与格式键之间跳一下
        let preferred = searchField.widthAnchor.constraint(equalToConstant: Self.searchW)
        preferred.priority = .defaultHigh
        preferred.isActive = true
        searchPreferredWidth = preferred
        // 搜索框缩到 90pt 就不能再窄（一个字也看不见）；常规宽度 150 可以让步
        let minWidth = searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.searchMinW)
        minWidth.isActive = true
        searchMinWidth = minWidth
        // 默认收起：搜索不该一直吃着标题行那一截地方
        setSearchOpen(false, force: true)
    }

    // MARK: - F05 搜索与筛选

    /// 搜索框那一条输入链路：真实打字与自检都用这个方法，保证测的是同一段代码。
    /// 文字先进框（手感不能卡），搜索往后攒 120 ms：命中一次就换一整页表格
    func applySearchText(_ text: String) {
        if searchField.stringValue != text { searchField.stringValue = text }
        scheduleGlobalSearch()
    }

    /// 供自检：当前搜索框里的文字
    var searchText: String { searchField.stringValue }

    /// 供自检：搜索框现在是展开着还是收起在放大镜背后
    var isSearchExpanded: Bool { searchOpen }

    /// 供自检：歌曲列表那一行的标题（筛选态要把结果数写在表格上方）
    var listCaptionText: String { listCaption.stringValue }

    /// 供自检：键盘真的进了搜索框没有（字段编辑器才是 firstResponder，`isEditingText` 看的就是它）
    var searchHasKeyboard: Bool { window.firstResponder is NSText }

    /// 供自检：搜索框与格式键是否真的在标题行里，没被表格盖住
    var searchControlsVisible: Bool {
        window.contentView?.layoutSubtreeIfNeeded()
        return !searchField.isHidden && searchField.frame.width > 40
            && formatButton.frame.width > 20
    }

    /// 供自检：走真实派发点一下放大镜（target/action 接错了什么都不会发生）
    func clickSearchToggle() { searchToggle.performClick(nil) }

    /// 供自检：收起状态下标题行里看得见什么——放大镜必须在，而且搜索框不得再占地方
    var magnifierOnlyRow: Bool {
        window.contentView?.layoutSubtreeIfNeeded()
        return searchToggle.frame.width >= 16 && !searchToggle.isHidden
            && searchField.isHidden && searchField.frame.width < 1
            && listCaption.frame.maxX <= searchToggle.frame.minX + 0.5
    }

    /// 供自检：展开后搜索框真拿到的宽度（窄面板下它会退到 90 那一档而不是挤出约束冲突）
    var expandedSearchWidth: CGFloat {
        window.contentView?.layoutSubtreeIfNeeded()
        return searchField.frame.width
    }

    /// 供自检：放大镜左边缘的横坐标。展开前后这个数应当一模一样 ——
    /// 键钉在标题右边定死了，长出来的只有搜索框，不是整排控件往两边挤
    var magnifierLeftEdge: CGFloat {
        window.contentView?.layoutSubtreeIfNeeded()
        return searchToggle.frame.minX
    }

    /// 供自检：放大镜是不是真的挨着标题（挨太远就是还挂在行尾，没搬过来）
    var magnifierHugsCaption: Bool {
        window.contentView?.layoutSubtreeIfNeeded()
        let gap = searchToggle.frame.minX - listCaption.frame.maxX
        return gap >= -0.5 && gap <= 12
    }

    /// 供自检：标题行与搜索控件有没有重叠（长歌单名只能截断）。
    /// 比的是这一排里最靠左的那一个：放大镜在搜索框左边，只校搜索框会漏了它
    var captionClearOfSearch: Bool {
        window.contentView?.layoutSubtreeIfNeeded()
        let left = searchOpen ? min(searchField.frame.minX, searchToggle.frame.minX)
            : searchToggle.frame.minX
        return listCaption.frame.maxX <= left + 0.5
    }

    /// 供自检：空状态提示有没有完整落在列表框里（该换行的换了行，没被裁掉右半句）
    var emptyHintFitsList: Bool {
        window.contentView?.layoutSubtreeIfNeeded()
        guard !emptyHint.isHidden, !emptyHint.stringValue.isEmpty else { return true }
        return emptyHint.frame.minX >= listWell.bounds.minX - 0.5
            && emptyHint.frame.maxX <= listWell.bounds.maxX + 0.5
    }

    /// 供自检：格式菜单当前列出的档与勾选情况
    var formatMenuState: [(name: String, on: Bool)] {
        rebuildFormatMenu()
        return formatMenu.items.compactMap {
            guard let name = $0.representedObject as? String else { return nil }
            return (name, $0.state == .on)
        }
    }

    /// 供自检：直接勾选/取消某个格式档（与鼠标点菜单项同一个 action）
    func toggleFormatForTest(_ name: String) {
        let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        item.representedObject = name
        toggleFormat(item)
    }

    /// ⌘F 与点放大镜共用：展开搜索框并把焦点交给它。面板是无边框窗，不先 makeKey 就收不了字
    func focusSearch() {
        setSearchOpen(true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
        // 已有条件时全选，一敲字就替换掉，不用先手动删
        if !searchField.stringValue.isEmpty { searchField.selectText(nil) }
    }

    /// 放大镜的开关：点开就聚焦，再点一下就收起（清掉关键字 = 退出搜索，
    /// 不先把命中的那一页留在背后：左栏没有「搜索结果」这一行，留着字下次看见会不认识）
    @objc private func searchToggleAction() {
        if searchOpen { collapseSearch() } else { focusSearch() }
    }

    /// 收起：先退搜索再收框。Esc 与再点一下放大镜走的都是这一条
    func collapseSearch() {
        cancelSearchTimer()
        if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            runGlobalSearch(keyword: "")
        }
        setSearchOpen(false)
        if window.firstResponder is NSText { window.makeFirstResponder(nil) }
    }

    /// 展开/收起的唯一入出口：两条宽度约束的常量一起改，搜索框才会从行里真拿回/交出地方
    private func setSearchOpen(_ open: Bool, force: Bool = false) {
        guard force || open != searchOpen else { return }
        searchOpen = open
        searchField.isHidden = !open
        searchPreferredWidth?.constant = open ? Self.searchW : 0
        searchMinWidth?.constant = open ? Self.searchMinW : 0
        searchToggle.lit = open
        if force { return }        // 搭建阶段：后面紧跟着就是第一次 updateInfo，不必多跑一次
        updateInfo()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === searchField else { return }
        scheduleGlobalSearch()
    }

    /// 回车与点 ×：这一次算一个完成动作，不等防抖
    @objc private func searchCommit() {
        cancelSearchTimer()
        runGlobalSearch(keyword: searchField.stringValue)
    }

    /// 逐字输入那一条路：每次新输入都重置计时，手停下来才算一次
    private func scheduleGlobalSearch() {
        if let old = searchTimer { old.invalidate() }
        let t = Timer(timeInterval: Self.searchDebounce, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.searchTimer = nil
            self.runGlobalSearch(keyword: self.searchField.stringValue)
        }
        // .common：菜单跟踪与拖行模式下也要能收尾，不然字卡在没搜的状态
        RunLoop.main.add(t, forMode: .common)
        searchTimer = t
    }

    private func cancelSearchTimer() {
        searchTimer?.invalidate()
        searchTimer = nil
    }

    /// 把关键字交给控制器做一次全局搜索：命中装在临时页「搜索结果」里。
    /// 格式档与关键字共用同一套条件（命中表本来就按它筛过，回给视图再筛一次是幂等的）
    private func runGlobalSearch(keyword: String) {
        let formats = playlistView.currentFilter.formats
        // 命中表一装上这一页，表格里的选中行与滚动位置说的就是命中表了：
        // 退回来时想还原的那份现场，只能在这之前取
        playlistView.noteSceneBeforeSearch()
        controller.applyGlobalSearch(TrackFilter(keyword: keyword, formats: formats))
        // 命中表换掉了表格正在看的这一页，视图的条件跟着被清掉了：格式档补回去
        if !formats.isEmpty { playlistView.setFilter(TrackFilter(keyword: "", formats: formats)) }
        // 一条都没搜到时要由这里说句话：表格默默变白看起来像没反应
        updateInfo()
    }

    /// 格式档变了：页内立刻生效，有关键字时全局命中也得重跑（否则换档后命中表里根本没有那个档的歌）
    private func applyFormatFilter(_ formats: Set<String>) {
        playlistView.setFilter(TrackFilter(keyword: "", formats: formats))
        guard !searchField.stringValue.isEmpty else { return }
        cancelSearchTimer()
        runGlobalSearch(keyword: searchField.stringValue)
    }

    @objc private func formatAction(_ sender: NSButton) {
        rebuildFormatMenu()
        formatMenu.popUp(under: sender)
    }

    /// 只列这次搜索真能搜到的那些档（不限格式算出来的）：拿命中表自己那份档去列会锁死
    private func rebuildFormatMenu() {
        let f = playlistView.currentFilter
        formatMenu.removeAllItems()
        let opts = controller.isSearching
            ? controller.searchFormatOptions : playlistView.availableFormats
        if opts.isEmpty {
            let hint = formatMenu.addItem(withTitle: controller.isSearching
                ? "这些命中里没有可筛选的格式" : "这一页没有可筛选的格式",
                                          action: nil, keyEquivalent: "")
            hint.isEnabled = false
            return
        }
        for name in opts {
            let item = formatMenu.addItem(withTitle: name, action: #selector(toggleFormat(_:)),
                                          keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = f.formats.contains(name) ? .on : .off
        }
        formatMenu.addItem(.separator())
        let all = formatMenu.addItem(withTitle: "全部格式", action: #selector(clearFormatFilter),
                                     keyEquivalent: "")
        all.target = self
        all.isEnabled = !f.formats.isEmpty
    }

    /// 勾选立即生效（不走防抖）：菜单点下去本来就是一个完成动作
    @objc private func toggleFormat(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var f = playlistView.currentFilter
        if f.formats.contains(name) { f.formats.remove(name) } else { f.formats.insert(name) }
        applyFormatFilter(f.formats)
    }

    @objc private func clearFormatFilter() {
        applyFormatFilter([])
    }

    /// 视图重算完结果后的统一收尾：格式键启用态、统计与空状态都得跟上。
    /// 关键字不回写：它现在归控制器（全局命中表），而不是视图那一页的条件
    private func filterResultsChanged() {
        formatButton.lit = !playlistView.currentFilter.formats.isEmpty
        updateInfo()
    }

    /// 重建左栏：六个固定页 + 按创建顺序排的歌单页。
    /// 新建/改名/删除都会发 .ttUserListsChanged，所以这里只有一处拼装入口
    private func rebuildGroups() {
        let kinds = controller.groupLayout
        for item in groupItems { item.removeFromSuperview() }
        groupItems = []
        groupKinds = kinds
        for (i, kind) in kinds.enumerated() {
            let item = GroupItemView(title: kind.name, selected: kind == controller.activeGroup)
            item.frame = NSRect(x: 0, y: CGFloat(i) * Self.groupRowH,
                                width: Self.groupItemW, height: Self.groupItemH)
            item.onClick = { [weak self] in self?.selectGroup(kind) }
            item.onRightClick = { [weak self] in self?.popUpGroupMenu(for: kind, over: item) }
            groupDoc.addSubview(item)
            groupItems.append(item)
        }
        groupDoc.frame = NSRect(x: 0, y: 0, width: Self.groupItemW,
                                height: max(CGFloat(kinds.count) * Self.groupRowH,
                                            Self.groupItemH))
        // 当前在看的页要露在左栏里（启动时档案停在下面某张歌单就是这种情况）；
        // 歌单变少到没有这一行时回到顶部，不能让滚动位置停在一片空白上
        if let i = groupKinds.firstIndex(of: controller.activeGroup), groupItems.indices.contains(i) {
            groupScroll.contentView.scrollToVisible(groupItems[i].frame)
        } else {
            scrollGroupsToTop()
        }
    }

    /// 把左栏那一列滚回最上面（固定页在最前，滚上去就一定看得见它们）
    func scrollGroupsToTop() {
        groupScroll.contentView.scroll(to: .zero)
        groupScroll.reflectScrolledClipView(groupScroll.contentView)
    }

    // MARK: - 事件

    /// 工具条按钮数（自检用：添加/电台/删除/列表/排序/查找/编辑/模式/队列）
    var toolbarButtonCount: Int { toolbar.arrangedSubviews.count }

    /// 自检用：左栏当前有几行（固定六页 + 歌单页）
    var groupItemCount: Int { groupItems.count }

    /// 自检用：左栏那一列的名字（固定页在前，歌单页按创建顺序跟在后面）
    var groupTitles: [String] { groupItems.map { $0.title } }

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
        for (i, kind) in groupKinds.enumerated() where groupItems.indices.contains(i) {
            groupItems[i].selected = kind == controller.activeGroup
        }
    }

    /// 自检用：走真实的点击链路（mouseDown → onClick）点中某个组；左栏没有这一行就什么都不做
    func clickGroup(_ kind: GroupKind) {
        guard let i = groupKinds.firstIndex(of: kind), groupItems.indices.contains(i) else { return }
        groupItems[i].performClick()
    }

    /// 自检用：把某个组滚到可见区（歌单页排在固定页下面，可能需要先滚才能看到）
    func scrollGroupIntoView(_ kind: GroupKind) {
        guard let i = groupKinds.firstIndex(of: kind), groupItems.indices.contains(i) else { return }
        // 得递 frame：条目自己的 bounds 原点永远是 (0,0)，拿它滚等于要求「滚到顶」
        groupScroll.contentView.scrollToVisible(groupItems[i].frame)
    }

    /// 自检用：那一列的内容是否比可视区长（歌单多起来就得靠滚动，不能把面板顶高）
    var groupColumnScrolls: Bool {
        window.contentView?.layoutSubtreeIfNeeded()
        return groupDoc.bounds.height > groupScroll.contentView.bounds.height
    }

    /// 自检用：派生组空表时中央那句提示露出来没有
    var showsEmptyHint: Bool { !emptyHint.isHidden && !emptyHint.stringValue.isEmpty }

    /// 自检用：中央那句空状态原文（媒体库页要它告诉用户去哪里加目录）
    var emptyHintText: String { emptyHint.stringValue }

    /// 自检用：那一行统计文字（电台两页的计数单位得是「台」）
    var infoText: String { infoField.stringValue }

    /// 自检用：统计文字与工具条那排键有没有重叠（长歌单名只能截断，不能压上去）
    var infoTextClearOfToolbar: Bool {
        window.contentView?.layoutSubtreeIfNeeded()
        return infoField.frame.minX >= toolbar.frame.maxX - 0.5
    }

    /// 自检用：六个固定页是否都完整落在左栏的可视区里。面板不会跟着组数长高，
    /// 固定页都被裁了就是布局坏了；歌单页多出来走滚动，不计在这里
    var fixedGroupsFitInWell: Bool {
        window.contentView?.layoutSubtreeIfNeeded()
        let clip = groupScroll.contentView
        guard !groupItems.isEmpty else { return false }
        return groupItems.prefix(GroupKind.fixedPages.count).allSatisfy {
            clip.bounds.intersects($0.convert($0.bounds, to: clip))
        }
    }

    /// 自检用：某一行的底边是否落在可视区内（滚过去之后再看）
    func groupVisible(_ kind: GroupKind) -> Bool {
        window.contentView?.layoutSubtreeIfNeeded()
        guard let i = groupKinds.firstIndex(of: kind), groupItems.indices.contains(i) else { return false }
        let item = groupItems[i]
        return groupScroll.contentView.bounds.intersects(item.convert(item.bounds, to: groupScroll.contentView))
    }

    private func subscribe() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(playlistChanged), name: .ttPlaylistChanged, object: nil)
        nc.addObserver(self, selector: #selector(trackChanged(_:)), name: .ttTrackChanged, object: nil)
        // 歌单清单变了：左栏那一列要重排（名字、行数、高亮位置一起跟上）
        nc.addObserver(self, selector: #selector(userListsChanged), name: .ttUserListsChanged, object: nil)
        // 媒体库扫描进度（F08）：只改统计行那一句话，左栏与表格由 .ttLibraryEntriesChanged 负责
        nc.addObserver(self, selector: #selector(libraryProgress), name: .ttLibraryChanged, object: nil)
        // 台名/分类/归属变了（F11）：分类页是新建出来的行，整列得重排
        nc.addObserver(self, selector: #selector(radioStationsChanged),
                       name: .ttRadioStationsChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func playlistChanged() {
        // 退出搜索不止从搜索框走：点左栏别的页、往里加歌、加电台都会被控制器直接掉。
        // 那种情况下框里留着一行搜不出东西的字，比空白更让人困惑
        if wasSearching, !controller.isSearching, !searchField.stringValue.isEmpty {
            cancelSearchTimer()
            searchField.stringValue = ""
            setSearchOpen(false)
        }
        wasSearching = controller.isSearching
        syncGroupItems()
        updateInfo()
    }
    @objc private func trackChanged(_ note: Notification) { updateInfo() }
    @objc private func userListsChanged() {
        rebuildGroups()
        updateInfo()
    }
    @objc private func libraryProgress() {
        syncGroupItems()
        updateInfo()
    }
    /// 电台档案变了：分类可增可删，左栏行数会变（与歌单同一做法，只有一处拼装入口）
    @objc private func radioStationsChanged() {
        rebuildGroups()
        updateInfo()
    }

    private func updateInfo() {
        let pl = controller.playlist
        switch controller.activeGroup {
        case .main:
            infoField.stringValue = pl.isEmpty ? "空列表"
                : "共 \(pl.count) 首 · \(TimeFormat.clock(pl.totalDuration))"
            listCaption.stringValue = pl.isEmpty ? "歌曲列表" : "歌曲列表（\(pl.count)）"
        case .library:
            // 媒体库页：这一页是盘上有什么就列什么，统计口径要说「条目」不是「首」。
            // 扫描中那句话（已看多少个文件）直接顶在这里，用户才知道磁盘为什么在转
            let name = controller.activeGroup.name
            let invalid = pl.tracks.filter { $0.missingOnDisk }.count
            var text = "\(name) \(pl.count) 条"
            if invalid > 0 { text += "（\(invalid) 条文件找不到）" }
            if let note = controller.libraryScanNote.isEmpty ? nil : controller.libraryScanNote {
                text += " · \(note)"
            }
            if !controller.offlineLibraryFolders.isEmpty {
                text += " · \(controller.offlineLibraryFolders.count) 个目录当前不在线"
            }
            infoField.stringValue = pl.isEmpty ? "\(name) 为空：菜单「媒体库」→ 添加音乐目录" : text
            listCaption.stringValue = pl.isEmpty ? name : "\(name)（\(pl.count)）"
            emptyHint.stringValue = controller.activeGroup.emptyHint ?? ""
        case .recent, .favorites:
            let name = controller.activeGroup.name
            infoField.stringValue = pl.isEmpty ? "\(name) 为空" : "\(name) \(pl.count) 首"
            listCaption.stringValue = "\(name)（\(pl.count)）"
            // 表格空着但组已经切过去了：中央给一句“这里会有什么”
            emptyHint.stringValue = controller.activeGroup.emptyHint ?? ""
        case .radio, .radioCategory, .recentRadio:
            // 电台这几页：单位是「台」不是「首」，这里放的是地址，“首”听起来像本地曲目数错了
            let name = controller.activeGroup.name
            infoField.stringValue = pl.isEmpty ? "\(name) 为空" : "\(name) \(pl.count) 个台"
            listCaption.stringValue = "\(name)（\(pl.count)）"
            emptyHint.stringValue = controller.activeGroup.emptyHint ?? ""
        case .playlist:
            // 歌单页：这一页列的是引用不是文件，文件走了的条目不能静默消失，
            // 得在统计里直说有几条找不到（F04 缺失标记）
            let name = controller.activeGroup.name
            let missing = pl.tracks.filter { $0.missingOnDisk }.count
            var text = pl.isEmpty ? "\(name) 为空"
                : "\(name) \(pl.count) 首 · \(TimeFormat.clock(pl.totalDuration))"
            if missing > 0 { text += "（\(missing) 条文件缺失）" }
            infoField.stringValue = text
            listCaption.stringValue = pl.isEmpty ? name : "\(name)（\(pl.count)）"
            emptyHint.stringValue = controller.activeGroup.emptyHint ?? ""
        case .search:
            // 命中表是一张临时页，不能下那六个固定页的口径：它说的不是
            // 「这一页有什么」而是「这次搜到了什么」，也不存在「匹配几分母」
            updateSearchInfo(pl)
            return
        }
        // F05：筛选态的结果数量要写在表格上方那一行（用户眼睛就在表格上），
        // 顶角统计也跟着加一句；空结果要给一句能听懂的话，不能让表格默默变白
        if playlistView.isFiltering {
            let n = playlistView.visibleRowCount
            // 结果数量写在最前面：标题行挤不下时截的是尾巴，不能把「匹配几条」截掉
            //（条件本身搜索框与格式键已经开着，完整说法放鼠标提示）
            let summary = playlistView.currentFilter.summary
            listCaption.stringValue = "匹配 \(n)/\(playlistView.totalCount) · 筛选\(summary)"
            listCaption.toolTip = "筛选\(summary)：匹配 \(n) / 共 \(playlistView.totalCount)\n"
                + "点搜索框的 × 或按 Esc 恢复完整列表"
            infoField.stringValue += " · 匹配 \(n)"
            emptyHint.stringValue = n == 0
                ? "没有匹配的曲目：改一下关键字，或点搜索框的 × 恢复完整列表" : ""
            emptyHint.isHidden = n != 0
            return
        }
        emptyHint.isHidden = !(pl.isEmpty && controller.activeGroup.isDerived)
    }

    /// 搜索态的标题行与统计：关键字、命中多少条、从哪儿来的、怎么退出去
    private func updateSearchInfo(_ pl: Playlist) {
        let kw = controller.searchKeyword
        let hits = pl.count
        let shown = playlistView.visibleRowCount
        listCaption.stringValue = "搜索「\(kw)」（\(shown)）"
        listCaption.toolTip = "关键字搜的是整个播放器：[默认]、媒体库、收藏、两份历史与每张歌单。\n"
            + "退出去：按 Esc、点搜索框的 ×、或再点一下放大镜（回到 "
            + (controller.groupBeforeSearch?.name ?? GroupKind.main.name) + "）"
        var text = "全局命中 \(hits) 首 · \(TimeFormat.clock(pl.totalDuration))"
        if !playlistView.currentFilter.formats.isEmpty {
            text += " · 按格式只看 \(shown)"
        }
        if controller.searchOverflow > 0 { text += " · 另有 \(controller.searchOverflow) 条没列出" }
        infoField.stringValue = text
        emptyHint.stringValue = hits == 0
            ? "整个播放器里都没搜到「\(kw)」：换个关键字，或按 Esc 收起搜索" : ""
        emptyHint.isHidden = hits != 0
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

    /// 工具条「电台」键与主菜单「添加网络电台…」共用：弹输入框，地址交给 PlayerController 归一化。
    /// 上面那一栏是内置电台：点一下只把地址填进输入框，加不加、什么时候加仍然是用户那一下 ——
    /// 「手输」与「内置」走同一个入口、同一套校验，不各开一条通路
    @objc func promptAddRadio() {
        let alert = NSAlert()
        alert.messageText = "添加网络电台"
        alert.informativeText = "粘贴电台地址（http:// 或 https://）。加进列表后双击即可收听。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "http://example.com/live.mp3"
        field.stringValue = radioInput
        radioField = field
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 30, width: 320, height: 25),
                                  pullsDown: true)
        popup.addItem(withTitle: "选一台内置电台（地址填到下面，可以改完再加）")
        for preset in RadioPresets.all {
            let row = NSMenuItem(title: preset.name, action: #selector(pickRadioPreset(_:)),
                                 keyEquivalent: "")
            row.target = self
            row.representedObject = preset.address
            row.toolTip = preset.address
            popup.menu?.addItem(row)
        }
        popup.isEnabled = !RadioPresets.all.isEmpty
        radioPresetMenu = popup
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 58))
        box.addSubview(popup)
        box.addSubview(field)
        alert.accessoryView = box
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

    /// 内置电台下拉那一项：只把地址填进输入框（台名不用填，`RadioPresets` 按地址兜底）
    @objc private func pickRadioPreset(_ sender: NSMenuItem) {
        radioField?.stringValue = sender.representedObject as? String ?? ""
    }

    @objc private func radioAction() { promptAddRadio() }

    /// 工具条「队列」键：开关待播面板（与菜单同名项走主面板同一个方法）
    @objc private func queueAction() { onToggleQueue?() }

    @objc private func removeAction() {
        // 工具条的删除只能拿原列表下标找控制器，结果行号直接递上去会删错人
        var rows = playlistView.selectedSourceRows
        if rows.isEmpty, let target = playlistView.targetSourceRow { rows = IndexSet(integer: target) }
        guard !rows.isEmpty else { return }
        controller.removeTracks(at: rows)
    }

    @objc private func listAction(_ sender: NSButton) {
        makeListMenu().popUp(under: sender)
    }

    /// 「列表」菜单（拆出来是为了自检能直接看条目与可用状态，与左栏右键同一个做法）
    func makeListMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: "保存列表为 m3u…", action: #selector(saveListAsM3U), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "载入列表…", action: #selector(openListM3U), keyEquivalent: "")
            .target = self
        let clear = menu.addItem(withTitle: controller.isSearching
            ? "清空列表（搜索结果不能清空）" : "清空列表",
            action: #selector(clearList), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !controller.isSearching     // 真要把这批歌删掉是逐行删除的事
        menu.addItem(.separator())
        // 自建歌单的入口除了左栏右键，工具条这里也得看得见（requirements F04）
        menu.addItem(withTitle: "新建歌单…", action: #selector(newListAction), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "导入 m3u 为歌单…", action: #selector(importListAction),
                     keyEquivalent: "").target = self
        return menu
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
        makeSortMenu().popUp(under: sender)
    }

    /// 「排序」菜单：搜索态里只给一句为什么不能排（同样拆出来供自检直读）
    func makeSortMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if controller.isSearching {
            // 命中的次序就是「在哪个页、那一页的第几行」：在结果里排序，下一个字敲下去就没了，
            // 看着像排序不起作用
            let hint = menu.addItem(withTitle: "搜索结果不排序：下一个字就会重排",
                                    action: nil, keyEquivalent: "")
            hint.isEnabled = false
            return menu
        }
        for key: Playlist.SortKey in [.title, .artist, .album, .duration, .fileName] {
            for asc in [true, false] {
                let item = menu.addItem(withTitle: "按\(key.rawValue)\(asc ? "升序" : "降序")",
                                        action: #selector(applySort(_:)), keyEquivalent: "")
                item.target = self
                item.tag = asc ? 1 : 0
                item.representedObject = key.rawValue
            }
        }
        return menu
    }

    @objc private func applySort(_ sender: NSMenuItem) {
        guard !controller.isSearching else { return }    // 菜单项已置灰，兼一道
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
        if !playlistView.focusNextMatch(after: playlistView.targetRow >= 0 ? playlistView.targetRow : nil,
                                        keyword: searchKeyword) {
            NSSound.beep()
        }
    }

    @objc private func editAction() {
        let row = playlistView.targetRow
        guard row >= 0, let track = playlistView.track(forDisplay: row) else {
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

    // MARK: - 自建歌单（左栏右键：新建/改名/删除/清空/导出/导入）

    /// 左栏右键菜单：固定页只能新建与导入，歌单页才有改名、导出、清空、删除；
    /// 电台那几页（[网络电台] 与各分类页）另给一段分类维护入口。
    /// 纯函数：不弹真菜单也能直接断言条目与可用状态（自检走这条路）
    func makeGroupMenu(for kind: GroupKind) -> NSMenu {
        let menu = NSMenu()
        // 自己管可用状态：不然系统会根据 target 能不能响应 action 重新把 isEnabled 盖掉
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, _ enabled: Bool, id: String? = nil) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            item.representedObject = id
        }
        // F11：分类入口只在电台页上给。摆在其他页会让人以为分类与歌单一样能往任意页建
        if kind.isRadioPage {
            add("新建电台分类…", #selector(newRadioCategoryAction), true)
            if case .radioCategory(let id) = kind, id != RadioStations.uncategorizedID {
                let name = controller.radioStations.name(of: id) ?? ""
                let n = controller.radioCount(in: id)
                add("重命名分类「\(name)」…", #selector(renameRadioCategoryAction), true, id: id)
                add("删除分类「\(name)」\(n > 0 ? "（\(n) 个台回到未分类）" : "")",
                    #selector(deleteRadioCategoryAction), true, id: id)
            } else {
                // 未分类是默认入口：行永远在，但不能改名也不能删
                add("重命名分类…", #selector(renameRadioCategoryAction), false)
                add("删除分类…", #selector(deleteRadioCategoryAction), false)
            }
            menu.addItem(.separator())
        }
        add("新建歌单…", #selector(newListAction), true)
        add("导入 m3u 为歌单…", #selector(importListAction), true)
        menu.addItem(.separator())
        guard case .playlist(let id) = kind else {
            // 固定页也列得出来这几项，但是置灰的：菜单形状不随页面变，用户才知道去哪建歌单
            add("重命名歌单…", #selector(renameListAction), false)
            add("导出歌单为 m3u…", #selector(exportListAction), false)
            add("清空歌单…", #selector(clearListAction), false)
            add("删除歌单…", #selector(deleteListAction), false)
            return menu
        }
        let name = controller.userLists.name(of: id) ?? ""
        let count = controller.userLists.keys(of: id).count
        add("重命名「\(name)」…", #selector(renameListAction), true, id: id)
        add("导出「\(name)」为 m3u…\(count > 0 ? "（\(count) 条）" : "")",
            #selector(exportListAction), count > 0, id: id)
        add("清空「\(name)」的 \(count) 条引用", #selector(clearListAction), count > 0, id: id)
        add("删除歌单「\(name)」", #selector(deleteListAction), true, id: id)
        return menu
    }

    private func popUpGroupMenu(for kind: GroupKind, over item: NSView) {
        let menu = makeGroupMenu(for: kind)
        menu.popUp(positioning: nil, at: NSPoint(x: 2, y: item.bounds.height), in: item)
    }

    /// 问一个名字（新建与改名共用）：取消返回 nil，真按了确定但只给了空白也会往下走，
    /// 由控制器那边挡下来并说一句原因
    private func promptName(title: String, message: String, prefill: String,
                            placeholder: String = "歌单名") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = prefill
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private func showNote(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "歌单"
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func newListAction() {
        guard let raw = promptName(title: "新建歌单",
                                   message: "给这张歌单起个名字。歌单只存引用，不搬文件。",
                                   prefill: "") else { return }
        guard let made = controller.createList(named: raw) else {
            showNote("歌单名不能是空的（只敲空格也算空的）")
            return
        }
        if let note = made.note { showNote(note) }     // 同名自动区分要说出来
    }

    @objc private func renameListAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let old = controller.userLists.name(of: id) else { return }
        guard let raw = promptName(title: "重命名歌单",
                                   message: "改名只影响显示，歌单里的引用、左栏那一行、存档里记的页面都不受影响。",
                                   prefill: old) else { return }
        if let problem = controller.renameList(id: id, to: raw) { showNote(problem) }
    }

    /// 删除与清空都得先把影响范围说清楚：用户听到“删除”默认会以为连文件一起没
    @objc private func deleteListAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let list = controller.userLists.item(id: id) else { return }
        let alert = NSAlert()
        alert.messageText = "删除歌单「\(list.name)」？"
        alert.informativeText = "只删这张歌单本身和它记的 \(list.keys.count) 条引用："
            + "[默认] 列表、我的收藏、最近播放与待播队列都不受影响，磁盘上的音乐文件也不动。"
        alert.addButton(withTitle: "删除歌单")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = controller.deleteList(id: id)
    }

    @objc private func clearListAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let name = controller.userLists.name(of: id) else { return }
        let count = controller.userLists.keys(of: id).count
        let alert = NSAlert()
        alert.messageText = "清空歌单「\(name)」？"
        alert.informativeText = "只清这一张里的 \(count) 条引用：歌还在 [默认] 列表与曲库里，"
            + "我的收藏、最近播放、待播队列都不受影响，正在播的那首继续播，磁盘文件不动。"
        alert.addButton(withTitle: "清空这张")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = controller.clearList(id: id)
    }

    @objc private func exportListAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(controller.userLists.name(of: id) ?? "歌单").m3u"
        panel.message = "导出这张歌单（带 #track= / #archive-entry= 的行是 TTPlayer 扩展写法）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !controller.exportList(id: id, to: url) {
            showNote("导不出去：这个位置写不了文件")
        }
    }

    /// 导入成一张新歌单：不往 [默认] 列表里塞歌（用户选的是“导入歌单”，不是“导入曲目”）
    @objc private func importListAction(_ sender: Any? = nil) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择 m3u/m3u8 歌单，导入成一张新歌单"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let made = controller.importList(from: url) else {
            showNote("这份歌单读不出文本（不是 UTF-8/GBK 编码的 m3u）")
            return
        }
        showNote(made.note)      // 几条入了、几条缺失、几行读不懂，总得有一句回音
    }

    // MARK: - 电台分类（左栏电台页右键：新建/改名/删除）

    /// 新建分类：名字只影响左栏那一行，台的归属要从电台行右键「移入分类」走
    @objc private func newRadioCategoryAction() {
        guard let raw = promptName(title: "新建电台分类",
                                   message: "给电台分个类（如「音乐」「新闻」）。分类页只把台归堆，"
                                        + "不另存一份地址，也不会动台本身。",
                                   prefill: "", placeholder: "分类名") else { return }
        guard let made = controller.createRadioCategory(named: raw) else {
            showRadioNote("分类名不能是空的（只敲空格也算空的）")
            return
        }
        if let note = made.note { showRadioNote(note) }   // 同名自动区分要说出来
    }

    @objc private func renameRadioCategoryAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let old = controller.radioStations.name(of: id) else { return }
        guard let raw = promptName(title: "重命名电台分类",
                                   message: "改名只影响显示：分类 id 不动，里面那些台的归属、"
                                        + "左栏那一行、存档里记住的页面都不受影响。",
                                   prefill: old, placeholder: "分类名") else { return }
        if let problem = controller.renameRadioCategory(id: id, to: raw) { showRadioNote(problem) }
    }

    /// 删分类先把影响说清：用户听到“删除”默认会以为连台一起没
    @objc private func deleteRadioCategoryAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let name = controller.radioStations.name(of: id) else { return }
        let n = controller.radioCount(in: id)
        let alert = NSAlert()
        alert.messageText = "删除电台分类「\(name)」？"
        alert.informativeText = "只删这个分类壳：里面 \(n) 个台回到「未分类电台」那一页，"
            + "地址、自定义台名、收藏、最近播放与正在播的都一样不动。"
        alert.addButton(withTitle: "删除分类")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if controller.deleteRadioCategory(id: id) == nil {
            showRadioNote("这个分类已经不在了")
        }
    }

    /// 分类那一档的回执（与歌单共用 NSAlert，只是标题不同）
    private func showRadioNote(_ text: String) {
        guard ProcessInfo.processInfo.environment["TTPLAYER_SELFTEST"] == nil else {
            Diagnostics.log("电台分类提示：\(text)")
            return
        }
        let alert = NSAlert()
        alert.messageText = "电台分类"
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - F11 供自检：不弹模态，直接走与菜单项同一个控制器入口

    /// 自检用：新建电台分类（等价于菜单项按下去之后的事）
    func createRadioCategoryThroughUI(named raw: String) -> (id: String, note: String?)? {
        controller.createRadioCategory(named: raw)
    }

    /// 自检用：分类改名
    @discardableResult
    func renameRadioCategoryThroughUI(id: String, to raw: String) -> String? {
        controller.renameRadioCategory(id: id, to: raw)
    }

    /// 自检用：删分类
    @discardableResult
    func deleteRadioCategoryThroughUI(id: String) -> (name: String, moved: Int)? {
        controller.deleteRadioCategory(id: id)
    }
}

/// 左栏的滚动文档视图：必须翻边（上为小 y），否则歌单多了往下滚会变成往上堆
private final class GroupDocView: NSView {
    override var isFlipped: Bool { true }
}

/// 左栏的列表组条目：自绘选中底，单击切组
private final class GroupItemView: NSView {
    let title: String
    var selected: Bool { didSet { needsDisplay = true } }
    /// 单击回调（由面板接到 selectGroup）
    var onClick: (() -> Void)?
    /// 右键回调（由面板弹歌单管理菜单）
    var onRightClick: (() -> Void)?
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

    /// 右键不抢当前页：只看这一行属于哪张歌单，弹管理菜单
    override func rightMouseDown(with event: NSEvent) { onRightClick?() }

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
