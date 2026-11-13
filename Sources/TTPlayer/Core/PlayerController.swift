import Foundation
import AppKit

/// 全局播放控制器（门面）：组合 AudioEngine + Playlist + Lyric，负责状态广播与持久化
final class PlayerController {
    static let shared = PlayerController()

    let engine = AudioEngine()
    let playlist = Playlist()
    /// 待播队列：与浏览列表相互独立的播放上下文（切组 / 筛选 / 排序不动它）
    let queue = PlayQueue()

    /// 最近播放 / 我的收藏的档案（只存键，切组时再还原成曲目）
    let groups = TrackGroups.shared
    /// 自建歌单的档案（F04）：可变数量的歌单页，与固定页并列摆在左栏
    let userLists = UserPlaylists.shared
    /// 电台档案（F11）：自定义台名与分类，全部按地址身份存
    let radioStations = RadioStations.shared
    /// 当前在看的列表组（左栏那一列名字）
    private(set) var activeGroup: GroupKind = .main
    /// 切去派生组时把 [默认] 组的现场留在这里：曲目对象带着已解析的元数据，切回来不用重读
    private var mainSnapshot: [Track] = []
    /// 派生组内容缓存（键序列不变就不重新还原、不重新解析）
    private var derivedCache: [GroupKind: (keys: [String], tracks: [Track])] = [:]

    private(set) var playMode: PlayMode = .listLoop
    private(set) var isPlaying = false
    private(set) var volume: Float = 0.8
    private(set) var isMuted = false
    private(set) var lyric: Lyric?
    private var lyricIndex = -2          // 上一次通知的歌词行

    /// 最近一次拖入被挡下的文件（一句人话原因）；导入成功就清空
    private(set) var lastImportProblem: String?
    /// 当前曲目放不起来的原因（显示区拿它替换格式那行，属性面板也读 Track.decodeProblem）
    private(set) var playbackProblem: String?
    /// 连续失败计数：整个播放上下文都试过一遍仍解不开时必须收手，
    /// 否则 next() 会绕圈递归到栈溢出。用户手动再播一次会把它清零（F03：重试要能重新尝试）
    private var consecutiveFailures = 0
    /// 电台流里带的「正在播」（ICY StreamTitle）；没有就是空串
    private(set) var radioNowPlaying = ""

    /// 「启动后自动继续播放」（F06）：默认关闭。开了也只在上次退出前处于播放时才自动开播
    private(set) var autoResumePlay = false

    /// 无缝衔接（F01）：默认开。这是「专辑不该被播放器切出空白」的默认值，
    /// 关掉就回到「换曲必 stop 节点」的硬切
    private(set) var gaplessPlay = true
    /// 已经交给引擎预取的那一条：交接回来时凭它核对「出声的就是我登记的那首」
    private var nextCandidateID: UUID?
    private var nextCandidateKey = ""
    /// 单曲循环（或整个上下文只有一条）时接的是「同一首再来一遍」：给引擎的身份要加一笔标记，
    /// 否则它会以为在预取正在播的这一曲本身而直接拒掉
    static let replayKeySuffix = "#replay"

    private var timeTimer: Timer?
    private var saveTimer: Timer?
    /// 现场落盘的节流：正在播时 5 s 一笔，状态切换点（暂停/停止/切曲/改队列）当场一笔
    static let sceneFlushInterval: TimeInterval = 5
    private var lastSceneFlush: TimeInterval = 0
    private var sceneFlushPending: DispatchWorkItem?

    private init() {
        engine.onPlaybackFinished = { [weak self] in
            self?.trackDidFinish()
        }
        // 电台的三类回话：状态（连接/重连/失败）、流参数、「正在播」的歌名
        engine.onRadioState = { [weak self] state in self?.radioStateDidChange(state) }
        engine.onRadioInfo = { [weak self] info in self?.radioInfoDidArrive(info) }
        engine.onRadioTitle = { [weak self] title in self?.setRadioNowPlaying(title) }
        // 无缝交接：引擎自己把下一曲接上了，这边只换显示与记录（不走装载那一路）
        engine.onGaplessHandover = { [weak self] key in self?.adoptHandover(key: key) }
        // 输出设备监听（F07）：启动就挂上，不等第一次播放——用户可能在一声未响时拔设备
        startWatchingOutputs()
        // 媒体库条目变了（监控合并扫描 / 重定位）：浏览页与存档都要跟上
        NotificationCenter.default.addObserver(self, selector: #selector(libraryEntriesChanged(_:)),
                                               name: .ttLibraryEntriesChanged, object: nil)
    }

    // MARK: - 状态查询

    /// 实际在播（或最后一次播）的那首。以队列为凭，与「表格选中哪一行」无关：
    /// 在收藏页听一首没收藏的歌、或者把正在播那行删出列表，显示区都还是它
    var currentTrack: Track? { queue.currentTrack }
    var currentTime: Double { engine.currentTime }
    var duration: Double { engine.duration }
    /// 当前是否在放电台（进度条要变不可拖、时长要写「直播」）
    var isRadio: Bool { engine.isRadio }
    /// 电台状态文字（“正在连接电台…”/“信号中断，重连中…”/“缓冲不足…”）
    ///
    /// 「缓冲不足」不是一条新的连接状态：流还连着、只是节点里没排上声音。
    /// 它得顶在「直播中」那一档上说出来，用户才知道现在卡的不是网络（F11）
    var radioStateText: String {
        if engine.radioState == .playing, engine.radioBufferLow {
            return "缓冲不足，正在等数据…"
        }
        return engine.radioState.displayText
    }
    /// 连接质量那句话（统计窗口、当前缓冲、本会话欠载/重连都在里面，F11）
    var radioQualityText: String { engine.radioQualitySummary }
    /// 此刻电台缓冲有多少秒（自检与属性面板读实数，不读文案里的数字）
    var radioBufferedSeconds: Double { engine.radioBufferedSeconds }

    // MARK: - 列表操作

    /// 添加文件（去重），返回新增数量
    /// 传入整盘镜像 + .cue 时按分轨表拆成多首，m3u/m3u8 会展开成里面的条目（见 LibraryStore）
    @discardableResult
    func addFiles(_ urls: [URL], playNow: Bool = false) -> Int {
        // 新曲只进 [默认] 列表：停在我的收藏页往里拖歌，会让人以为歌被加进收藏了
        switchGroup(.main)
        let imported = LibraryStore.importURLs(urls)
        if let note = imported.skipNote {
            lastImportProblem = note
            Diagnostics.error("未入表：\(note)")
        } else if imported.tracks.isEmpty && !urls.isEmpty {
            // 拖了个空目录、或里面只有封面和说明：总得给句话，否则看着像没反应
            let note = "这个位置没有可播放的音频文件"
            lastImportProblem = note
            Diagnostics.error("未入表：\(note)")
        } else {
            lastImportProblem = nil
        }
        return addTracks(imported.tracks, playNow: playNow)
    }

    /// 添加一个电台地址（工具条「电台」键/菜单输入框）：成功返回 nil，失败返回一句人话
    /// 只收 http/https：用户粘进去的东西先归一化（去空白/引号/补协议），入表后就是普通一条 Track
    @discardableResult
    func addRadio(_ raw: String, playNow: Bool = true) -> String? {
        guard let url = RadioURL.normalize(raw) else {
            let note = "地址不对：只支持 http:// 或 https:// 开头的电台地址"
            lastImportProblem = note
            Diagnostics.error("未入表：\(note)")
            return note
        }
        switchGroup(.main)
        let track = Track(radio: url)
        // 已经在表里（同一地址）就不再入一条，直接拿现成那条播
        if let existing = playlist.tracks.first(where: { $0.identityKey == track.identityKey }) {
            lastImportProblem = nil
            if playNow { play(track: existing) }
            Diagnostics.log("电台已在列表：\(url.absoluteString)")
            return nil
        }
        lastImportProblem = nil
        addTracks([track], playNow: playNow)
        Diagnostics.log("添加电台 \(url.absoluteString)")
        return nil
    }

    /// 按 identityKey 去重入表（CUE 分轨的 url 都指向同一份镜像，只能靠这个键区分）
    @discardableResult
    func addTracks(_ newTracks: [Track], playNow: Bool = false) -> Int {
        let existing = Set(playlist.tracks.map { $0.identityKey })
        var added: [Track] = []
        for track in newTracks where !existing.contains(track.identityKey) {
            playlist.add(track)
            added.append(track)
            MetadataReader.read(track) { [weak self] in
                self?.notifyPlaylistChanged()
            }
        }
        if !added.isEmpty { markSearchStale() }     // 池子多了几条：索引得重建才能搜到它们
        notifyPlaylistChanged()
        if playNow, let first = added.first, !isPlaying {
            play(track: first)
        }
        return added.count
    }

    func removeTracks(at indexes: IndexSet) {
        // 从浏览列表删行：真正「从曲库拿掉」的两页（[默认] 与台）要把队列里对应条目一并摘掉，
        // 但正在播的那条形列外 —— 声音继续到结束，下一曲照旧顺下去，不因为少了一条而跳曲
        var dropped: Set<String> = []
        switch activeGroup {
        case .library:
            // 媒体库页不删行：盘上还有这首歌，删了下一趟扫描又回来，等于没删，
            // 反而会让人以为「从库里去掉」会动磁盘。想少收就移除目录，想修就重新定位
            libraryProblem = "媒体库列的是盘上有什么：想不收录它请移除目录，想修好某条请重新定位"
            Diagnostics.log("媒体库页删行未执行：\(libraryProblem ?? "")")
            return
        case .main:
            dropped = Set(indexes.compactMap { playlist.track(at: $0)?.identityKey })
            playlist.remove(at: indexes)
        case .search:
            // 命中表是临时页：这一行的「原列表下标」就是命中表下标，
            // 删它必须拿身份去找它本来存在的那几页（见 removeSearchHits）
            removeSearchHits(Set(indexes.compactMap { playlist.track(at: $0)?.identityKey }))
            return
        case .radio, .radioCategory:
            // 「网络电台」与各分类页都是 [默认] 里电台地址的投影：在这一页删台就是真删台，
            // 只删投影的话切回 [默认] 它又冒出来了（本地文件那一张表不该跟着遭殃）
            dropped = Set(indexes.compactMap { playlist.track(at: $0)?.identityKey })
            mainSnapshot.removeAll { dropped.contains($0.identityKey) }
            reloadActiveGroup()
        case .playlist(let id):
            // 在歌单页删行 = 从这一张歌单里拿掉引用：不动 [默认] 列表、收藏、
            // 别的歌单，更不动磁盘上的文件（歌还在曲库里，队列也不动）
            let removed = Set(indexes.compactMap { playlist.track(at: $0)?.identityKey })
            let n = userLists.remove(keys: removed, from: id)
            if n > 0 {
                listContentsChanged(id: id)
                Diagnostics.log("从歌单「\(userLists.name(of: id) ?? "")」移除 \(n) 条")
            }
        default:
            // 其他派生组里删除 = 从收藏/历史里拿掉，不能动 [默认] 的内容；
            // 歌还在曲库里，所以队列与播放上下文一行都不改
            let removed = indexes.compactMap { playlist.track(at: $0)?.identityKey }
            groups.remove(keys: removed, from: activeGroup)
            invalidate(activeGroup)
            reloadActiveGroup()
        }
        if !dropped.isEmpty {
            queue.dropTracks(keys: dropped)
            notifyQueueChanged()
        }
        // 正在播那行被删了就没有 ▶ 可标（声音还在），也不能把旁边那行当成当前曲
        syncSelectionToPlaying()
        notifyPlaylistChanged()
    }

    func clearPlaylist() {
        // 清空一张歌单：只清这一张的条目引用。[默认] 列表、收藏、最近播放、
        // 待播队列一概不动，正在播的那首也照旧 —— 所以下面那套「停 + 清队列」的
        // 收尾只能给真正的列表页用（那是「把曲库清光」的语义）
        if case .playlist(let id) = activeGroup {
            clearList(id: id)
            return
        }
        if activeGroup == .search {
            // 「清空搜索结果」不是「清空曲库」：这一页只是「此刻搜出来什么」。
            // 真要把这批歌都删掉是逐行删除的事（那一头按身份动手），
            // 不该给一个一键误入口；入口在界面里已经置灰，这里只是兼一道
            Diagnostics.log("搜索态清空未执行：搜索结果不是一份可以清空的列表")
            return
        }
        if activeGroup == .library {
            // 同理：媒体库不是「一张可以清空的表」，它是盘上内容的投影。
            // 清空它既不等于删文件（绝不做），也不等于移除目录（那是另一件事）
            libraryProblem = "媒体库不能用「清空」：盘上的歌还在，要不再收录请移除目录"
            Diagnostics.log("媒体库页清空未执行")
            return
        }
        stop()
        if activeGroup.isRadioPage {
            // 在台这一页清空 = 把这一页列的那些台从 [默认] 里删干净（分类页只删本页那几台，
            // 不动别的分类）；「最近听的台」是历史不是列表，不清
            let gone = Set(derivedKeys(for: activeGroup))
            mainSnapshot.removeAll { gone.contains($0.identityKey) }
            playlist.removeAll()
            reloadActiveGroup()       // 就留在这一组：空表 + 中央一句提示
        } else if activeGroup.isDerived {
            // 只清这一组的档案；[默认] 现场不动，切回去还在（同“在台页清空”一样靠 reloadActiveGroup 开空表 + 中央提示）
            groups.clear(activeGroup)
            invalidate(activeGroup)
            reloadActiveGroup()
        } else {
            playlist.removeAll()
        }
        lyric = nil
        queue.reset()
        notifyQueueChanged()
        // 词没了就要把主显示区那一句擦掉，否则列表都清空了屏幕上还挂着上一首的末句
        lyricIndex = -2
        updateLyricLine(force: true)
        // 上一批导入留下的说明文字也一并清掉，不然列表都清空了还写着旧原因
        lastImportProblem = nil
        consecutiveFailures = 0
        notifyPlaylistChanged()
        postTrackChange()
        flushScene()      // 清完就是「下次启动没现场可恢复」，不能把旧队列留在盘上
    }

    // MARK: - 列表组（左栏 [默认] / 网络电台 / 最近听的台 / 最近播放 / 我的收藏）

    /// 切组：把目标组的内容装上当前列表。切组不丢内容 —— [默认] 的现场一直留档
    func switchGroup(_ kind: GroupKind) {
        // 存档或界面可能指向一张已经被删掉的歌单：那种情况回到 [默认]，
        // 不能开出一张名字写着「歌单已不存在」的空页
        var target = kind
        if case .playlist(let id) = target, !userLists.contains(id: id) { target = .main }
        // 同理：存档停在一张已被删掉的电台分类上时回到 [默认]（未分类那一格永不删）
        if case .radioCategory(let id) = target, id != RadioStations.uncategorizedID,
           !radioStations.contains(id: id) { target = .main }
        guard target != activeGroup else { return }
        if activeGroup == .search {
            // 用户点了左栏另一个页、或往里加歌/拖入了文件：搜索态到此为止。
            // 命中表不是内容，不能留在内存里等着被写进存档
            clearSearchState()
        }
        if activeGroup == .main { mainSnapshot = playlist.tracks }
        activeGroup = target
        install(target == .main ? mainSnapshot : derivedTracks(for: target))
        Diagnostics.log("列表组 → \(target.name)（\(playlist.count) 首）")
        notifyPlaylistChanged()
        // 在看的页也是用户的现场：下次启动还回到这一张歌单（存档记的是稳定 ID，
        // 所以中间改过名、删过条目都找得回来；那张已经不在了就回 [默认]）
        scheduleSave()
        scheduleSceneFlush()
    }

    /// 收藏 / 取消收藏（右键菜单与 ⌘D 走这里）；返回操作后的状态
    @discardableResult
    func toggleFavorite(_ track: Track) -> Bool {
        let on = groups.toggleFavorite(track)
        invalidate(.favorites)
        if activeGroup == .favorites { reloadActiveGroup() }
        Diagnostics.log(on ? "加入收藏 \(track.title)" : "移出收藏 \(track.title)")
        notifyPlaylistChanged()
        return on
    }

    func isFavorite(_ track: Track) -> Bool { groups.isFavorite(track) }

    /// 装上某一组的内容。只换浏览列表：正在播的那首由队列说一不二，
    /// 它不在这一组里就没有高亮行，显示区照样是它（切组不能动声音）
    private func install(_ tracks: [Track]) {
        playlist.removeAll()
        playlist.add(contentsOf: tracks)
        syncSelectionToPlaying()
    }

    /// 收藏/历史变了之后重建当前组（行数、顺序都要跟着变）
    private func reloadActiveGroup() {
        guard activeGroup.isDerived else { return }
        playlist.removeAll()
        playlist.add(contentsOf: derivedTracks(for: activeGroup))
        syncSelectionToPlaying()
    }

    /// 把表格高亮落到「真在播的那首」上：在这一组里就选中那一行，
    /// 不在（被删出列表 / 这组根本没有它）就一行都不高亮 —— 宁可没有 ▶，
    /// 也不能把别行标成当前曲（它听起来就是「播这首」）
    private func syncSelectionToPlaying() {
        if let key = currentTrack?.identityKey, let i = playlist.index(ofKey: key) {
            _ = playlist.select(i)
        } else {
            playlist.clearSelection()
        }
    }

    private func invalidate(_ kind: GroupKind) {
        derivedCache[kind] = nil
        markSearchStale()
    }

    /// 这一组该列哪些键：「网络电台」不另存一份地址，直接拿 [默认] 留档里的电台投影，
    /// 所以加台 / 删台只改一处，两个页面跟着一起变；媒体库页直接读扫出来的引用，
    /// 歌单页读那张歌单自己的键，其余组读各自的档案
    private func derivedKeys(for kind: GroupKind) -> [String] {
        switch kind {
        case .main: return []
        case .library: return MediaLibrary.shared.keys
        case .radio: return mainSnapshot.filter { $0.isRadio }.map { $0.identityKey }
        case .radioCategory(let id):
            // 分类页也是投影，不另存一份地址：同一批台在「全部台」与分类页里是同一对象，
            // 删一处另一处就跟着没了（与 .radio 同一个道理）
            return mainSnapshot.filter { $0.isRadio }
                .map { ($0.identityKey, radioStations.categoryID(of: $0.identityKey)) }
                .filter { $0.1 == (id == RadioStations.uncategorizedID ? nil : id) }
                .map { $0.0 }
        case .recent, .favorites, .recentRadio: return groups.entries(for: kind)
        case .playlist(let id): return userLists.keys(of: id)
        // 临时页没有「该列哪些键」：它的内容就是上一次搜出来的那份命中表
        case .search: return []
        }
    }

    /// 按档案键还原成曲目：先复用内存里已有的 Track（元数据已解析），缺的再按存档写法重建
    private func derivedTracks(for kind: GroupKind) -> [Track] {
        let keys = derivedKeys(for: kind)
        if let cached = derivedCache[kind], cached.keys == keys { return cached.tracks }
        var pool: [String: Track] = [:]
        for t in mainSnapshot + playlist.tracks { pool[t.identityKey] = t }
        if let cached = derivedCache[kind] { for t in cached.tracks { pool[t.identityKey] = t } }
        // 只剩内存里没有的那些才去重新解析（CUE 分轨会重新读分轨表）
        let missingKeys = keys.filter { pool[$0] == nil }
        for t in LibraryStore.tracks(fromArchiveEntries: missingKeys) { pool[t.identityKey] = t }
        // 歌单页与媒体库页要「看得见的失效引用」：解不开的键不掉队，留一条指着原位置的占位
        // 条目（F04 / F08）；收藏 / 历史那两页照旧让盘上没这东西的键自然掉队（它们本来就是能列多少算多少）
        let keepMissing = kind.keepsMissingEntries
        var tracks: [Track] = []
        tracks.reserveCapacity(keys.count)
        for key in keys {
            if let t = pool[key] {
                if keepMissing { t.missingOnDisk = !t.isRadio && !LibraryStore.entryExists(key) }
                tracks.append(t)
            } else if keepMissing {
                tracks.append(LibraryStore.placeholder(for: key))
            }
        }
        for t in tracks where t.duration == 0 && !t.isRadio && !t.missingOnDisk {
            MetadataReader.read(t) { [weak self] in self?.notifyPlaylistChanged() }
        }
        derivedCache[kind] = (keys, tracks)
        return tracks
    }

    // MARK: - 全局搜索（F05：搜索框搜的是整个播放器，不再只是当前这一页）

    /// 现在看着的是不是一张命中表。搜索框里的关键字只在这一态里成立：
    /// 它是「此刻搜出来什么」的一份视图，不是一份内容
    var isSearching: Bool { activeGroup == .search }
    /// 当前搜索条件（关键字为空就是没在搜；格式档与页内筛选共用这一份）
    private(set) var searchFilter = TrackFilter.none
    /// 进入搜索之前在看的那一页：退出时回到它。左栏没有「搜索结果」这一行，
    /// 用户点左栏任何一个页、或往里加歌，都等于退出搜索
    private(set) var groupBeforeSearch: GroupKind?
    /// 命中超过上限被截掉多少条（标题行要如实说「还有几条没列出」，不能默默少给）
    private(set) var searchOverflow = 0
    /// 这次的命中里都有哪些格式档（不限格式算出来的）：搜索态下「格式」菜单列它。
    /// 拿命中表自己那份档去列会锁死：勾了 FLAC 之后菜单里就只剩 FLAC，换不到 MP3
    private(set) var searchFormatOptions: [String] = []
    /// 命中表里这个身份在左栏出现在哪几页（行末那句「（收藏 · 深夜）」从这里来）
    private var searchHitPages: [String: [String]] = [:]
    /// 上一次装进搜索页的命中序列：一样就别重装，用户的选中行与滚动位置不该
    /// 被一次后台标签到达顶掉
    private var lastSearchKeys: [String] = []
    /// 索引对应的是哪一份内容（各页规模拼出来的指纹）。用规模而不是版本号：
    /// 元数据晚到也走 notifyPlaylistChanged，一万条目录导入不能跟着重建一万次索引
    private var searchSignature = ""
    /// 搜索自己轻量建出来的条目（媒体库里那些还没被任何一页装进内存的歌）：
    /// 索引重建时复用它们，同一身份永远同一个对象，读过的标签不白读
    private var searchPool: [String: Track] = [:]
    /// 补读标签读到索引的第几条了：一次搜索最多补 `tagSweep` 条，搜得越多覆盖越全
    private var tagCursor = 0
    /// 已经为搜索排队过的条目（标签还没到的那些）：不记这一笔会把同一条重复入队
    private var tagScheduled: Set<UUID> = []
    /// 标签一条条到达时把当前条件重跑一次：攒一小会儿再跑，不能一条抖一次表格
    private var searchSettleTimer: Timer?

    /// 一次搜索最多补读多少条还没标签的条目：一上来就把一万条丢进解析队列，
    /// 用户只是在找一个歌名，不该让磁盘为他转十分钟
    static let tagSweep = 500

    /// 写盘与播放现场该记哪一页：搜索态是临时页，不能把它写进存档 ——
    /// 下次启动看见一张空的「搜索结果」没有意义，该回到的是用户进入搜索前那一页
    var persistGroup: GroupKind { isSearching ? (groupBeforeSearch ?? .main) : activeGroup }

    /// 这一串的来路是歌单页的稳定 ID，搜索态下要说的是「进入搜索前在看哪张」
    var persistListID: String? {
        if case .playlist(let id) = persistGroup { return id }
        return nil
    }

    /// 搜索覆盖哪些页：[默认]、媒体库、收藏、两份历史、以及每一张自建歌单。
    /// 「网络电台」与各个分类页不列：它们是 [默认] 里电台地址的投影，同一批地址
    /// 在 [默认] 那一页已经算过一遍；「最近听的台」要列 —— 台被删出列表之后只剩这里找得回
    var searchPageKinds: [GroupKind] {
        [.main, .library, .favorites, .recent, .recentRadio]
            + userLists.items.map { GroupKind.playlist($0.id) }
    }

    /// 应用一次全局搜索：命中装进临时页「搜索结果」。关键字为空 = 退出搜索
    /// - Parameter sweeping: 要不要为没标签的条目补读一次。
    ///   只有用户真的敲了字才算他要求的活；标签到达后的重跑不再往前扩（`false`），
    ///   否则一次搜索会在背后把整个库读到底
    /// - Returns: 表格里的行数（已算上格式档与上限截断）
    @discardableResult
    func applyGlobalSearch(_ filter: TrackFilter, sweeping: Bool = true) -> Int {
        let kw = filter.keywordText
        guard !kw.isEmpty else {
            endGlobalSearch()
            return 0
        }
        // 索引脏了就得重建：让它变脏的不只「用户敲了一下字」这一条路（搜索页删行、
        // 加歌、改档案都会）。`sweeping` 只管要不要再往下补读标签，不管索引
        ensureSearchIndex()
        let found = GlobalSearch.shared.matches(filter)
        searchFilter = TrackFilter(keyword: kw, formats: filter.formats)
        searchOverflow = max(0, found.total - found.hits.count)
        searchFormatOptions = found.formats
        if sweeping { sweepTags() }
        let keys = found.hits.map { $0.track.identityKey }
        if keys == lastSearchKeys, isSearching {
            // 命中一模一样（补读的标签没改变结果）：一行都不动
            return keys.count
        }
        if activeGroup == .main { mainSnapshot = playlist.tracks }    // 留档，与 switchGroup 同一规矩
        if activeGroup != .search { groupBeforeSearch = activeGroup }
        searchHitPages = Dictionary(uniqueKeysWithValues: found.hits.map { ($0.track.identityKey, $0.pages) })
        activeGroup = .search
        install(found.hits.map { $0.track })
        lastSearchKeys = keys
        Diagnostics.log("全局搜索 \(searchFilter.summary) → \(keys.count) 条命中"
            + "（索引 \(GlobalSearch.shared.indexedCount) 条"
            + (searchOverflow > 0 ? "，另有 \(searchOverflow) 条没列出" : "") + "）")
        notifyPlaylistChanged()
        return keys.count
    }

    /// 退出搜索：回到进入之前那一页。命中表与临时状态一起丢掉
    func endGlobalSearch() {
        guard isSearching else {
            searchFilter = .none
            return
        }
        let back = groupBeforeSearch ?? .main
        clearSearchState()
        Diagnostics.log("退出全局搜索 → 回到 \(back.name)")
        switchGroup(back)
    }

    /// 供界面：命中那一行「还在哪几页」。只在这条信息真能多说点什么时才说：
    /// 满屏的「（[默认]）」与「（媒体库）」没有信息量（本地文件几乎都在库里），
    /// 只有「这首歌不在 [默认] 里」或「它还进了某张歌单/收藏」才值得标出来
    func searchAnnotation(for key: String) -> String {
        let pages = searchHitPages[key] ?? []
        let inMain = pages.contains(GroupKind.main.name)
        let skip: Set<String> = inMain
            ? [GroupKind.main.name, GroupKind.library.name] : [GroupKind.main.name]
        let others = pages.filter { !skip.contains($0) }
        return others.isEmpty ? "" : "（" + others.joined(separator: " · ") + "）"
    }

    /// 供界面：搜索态下有没有退出入口（标题行与鼠标提示都读它）
    var searchKeyword: String { searchFilter.keywordText }

    private func clearSearchState() {
        searchFilter = .none
        groupBeforeSearch = nil
        searchHitPages = [:]
        searchOverflow = 0
        searchFormatOptions = []
        lastSearchKeys = []
        searchSettleTimer?.invalidate()
        searchSettleTimer = nil
    }

    /// 索引该不该重建：只看各页的规模。命中表自己不算一页（它在 `playlist` 里，
    /// 但搜索态下 [默认] 那一页读的是留档 `mainSnapshot`，规模不受命中表影响）
    private func searchSignatureNow() -> String {
        let main = activeGroup == .main ? playlist.count : mainSnapshot.count
        var s = "\(main)|\(MediaLibrary.shared.keys.count)|\(groups.favoriteKeys.count)"
            + "|\(groups.recentKeys.count)|\(groups.recentRadioKeys.count)"
        for item in userLists.items { s += "|\(item.id):\(item.keys.count)" }
        return s
    }

    /// 建「页序 → 曲目」的索引。与 `derivedTracks` 同一批键、同一个次序，
    /// 但**不批量读元数据**：这里只保证「有身份、有文件名」，命中的那几条才补读
    private func ensureSearchIndex() {
        let sig = searchSignatureNow()
        guard sig != searchSignature || GlobalSearch.shared.isStale else { return }
        searchSignature = sig
        // 一份「内存里已经有的曲目」：先复用现成对象（元数据、封面都已解析），
        // 缺的才按存档写法轻量建一条
        var pool: [String: Track] = [:]
        for t in mainSnapshot { pool[t.identityKey] = t }
        if activeGroup == .main { for t in playlist.tracks where pool[t.identityKey] == nil { pool[t.identityKey] = t } }
        for cached in derivedCache.values { for t in cached.tracks where pool[t.identityKey] == nil { pool[t.identityKey] = t } }
        for (key, t) in searchPool where pool[key] == nil { pool[key] = t }
        var resolver = LibraryStore.EntryResolver()
        var pages: [(name: String, tracks: [Track])] = []
        for kind in searchPageKinds {
            if kind == .main {
                pages.append((kind.name, activeGroup == .main ? playlist.tracks : mainSnapshot))
                continue
            }
            let keys = derivedKeys(for: kind)
            if kind != .search, let cached = derivedCache[kind], cached.keys == keys {
                pages.append((kind.name, cached.tracks))
                continue
            }
            var tracks: [Track] = []
            tracks.reserveCapacity(keys.count)
            for key in keys {
                if let t = pool[key] { tracks.append(t); continue }
                guard let t = resolver.track(key) else {
                    // 解不开的（文件走了）不进搜索索引：回到原来那一页还看得见它并标失效，
                    // 搜索结果页不该凭空造一条假的出来
                    continue
                }
                pool[key] = t
                searchPool[key] = t
                tracks.append(t)
            }
            pages.append((kind.name, tracks))
        }
        GlobalSearch.shared.build(pages)
        tagCursor = 0
        tagScheduled = []
    }

    /// 从索引的游标往后补读标签：按标题/艺术家能不能搜到，取决于标签读过没有。
    /// 已经读过标签的（`artist` 非空）跳过：那一条本来就在覆盖范围内
    private func sweepTags() {
        let rows = GlobalSearch.shared.rows
        var kicked = 0
        while tagCursor < rows.count, kicked < Self.tagSweep {
            let track = rows[tagCursor].track
            tagCursor += 1
            if track.isRadio || track.missingOnDisk || !track.artist.isEmpty
                || tagScheduled.contains(track.id) { continue }
            tagScheduled.insert(track.id)
            kicked += 1
            MetadataReader.read(track) { [weak self] in self?.searchTagsDidArrive() }
        }
    }

    /// 补读的标签到了：列表行要跟上，命中表也得重跑一次（否则「读到标签了」这件事
    /// 用户永远看不见，得再敲一个字才出结果）
    private func searchTagsDidArrive() {
        notifyPlaylistChanged()
        scheduleSearchRerun()
    }

    /// 命中集可能变了（就地改了标题、标签晚到）：攒一次把当前条件重跑。
    /// 不能一条通知扫一遍全库：导入一万首就是上万条这种通知
    func scheduleSearchRerun() {
        guard isSearching, searchSettleTimer == nil else { return }
        let t = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.searchSettleTimer = nil
            guard self.isSearching else { return }
            self.applyGlobalSearch(self.searchFilter, sweeping: false)
        }
        // .common：表格拖行、菜单跟踪模式下也要能收尾，与筛选的防抖同一个规矩
        RunLoop.main.add(t, forMode: .common)
        searchSettleTimer = t
    }

    /// 池子的内容变了：搜索索引作废，下次搜索前重建。
    /// 与 `invalidate(_:)`（派生组缓存）一起叫，因为触发条件本来就是同一批
    private func markSearchStale() {
        GlobalSearch.shared.invalidate()
        searchSignature = ""
    }

    /// 搜索页删行：把这几条身份从「存着它们的地方」都摘掉，再按同一条件重算命中表。
    /// 只摘命中表这一处会留下一个假象：用户在结果里删了它，切回收藏页它还在那儿，
    /// 再搜一次又回到结果里 —— 看起来就是「删除没生效」
    private func removeSearchHits(_ keys: Set<String>) {
        guard !keys.isEmpty else { return }
        // 1) [默认] 留档（电台也在这份里：在投影页删台本来就是真删台）
        mainSnapshot.removeAll { keys.contains($0.identityKey) }
        // 2) 收藏与两份历史
        groups.remove(keys: Array(keys), from: .favorites)
        groups.remove(keys: Array(keys), from: .recent)
        groups.remove(keys: Array(keys), from: .recentRadio)
        invalidate(.favorites)
        invalidate(.recent)
        invalidate(.recentRadio)
        // 3) 每一张歌单里的引用。媒体库页不动：那一页是「盘上有什么」的投影，
        //    删它既不删文件也不保证下次不扫到（与在媒体库页删行同一个道理）
        for item in userLists.items where userLists.remove(keys: keys, from: item.id) > 0 {
            listContentsChanged(id: item.id)
        }
        // 4) 待播队列里也摘掉，正在播那一条形列外（声音继续，同 `removeTracks` 的规矩）
        queue.dropTracks(keys: keys)
        notifyQueueChanged()
        markSearchStale()
        if isSearching { _ = applyGlobalSearch(searchFilter, sweeping: false) }
        Diagnostics.log("从搜索结果删除 \(keys.count) 条（各处存着它们的地方一并摘掉）")
        notifyPlaylistChanged()
    }

    // MARK: - 自建歌单（F04：左栏歌单页、右键「加入歌单」、m3u 导入导出）

    /// 当前在看的歌单 ID（停在别的页面时是 nil）
    var activeListID: String? {
        if case .playlist(let id) = activeGroup { return id }
        return nil
    }

    /// 左栏该列的组次序：固定页 + 未分类与各个电台分类 + 全部歌单页（各按创建顺序）
    var groupLayout: [GroupKind] {
        GroupKind.layout(playlists: userLists.items, categories: radioStations.categories)
    }

    /// 新建一张歌单，建完就切过去看着它（空表正好把那句提示显示出来）
    /// - Returns: nil = 名字空着，没建；否则 (新歌单 ID, 同名自动区分时的一句说明)
    @discardableResult
    func createList(named raw: String) -> (id: String, note: String?)? {
        guard let made = userLists.create(named: raw) else {
            Diagnostics.error("未建歌单：名字不能是空的")
            return nil
        }
        notifyListsChanged()
        switchGroup(.playlist(made.id))
        Diagnostics.log("新建歌单「\(userLists.name(of: made.id) ?? "")」")
        return made
    }

    /// 清空指定歌单（左栏右键与歌单页右键共用）：只丢这一张的条目引用。
    /// 不在看这一页也能清，清完不动浏览现场（免得用户被“跳页”）
    /// - Returns: 清掉了几条引用（歌单不存在时是 0）
    @discardableResult
    func clearList(id: String) -> Int {
        guard userLists.contains(id: id) else { return 0 }
        let n = userLists.keys(of: id).count
        userLists.clear(id: id)
        listContentsChanged(id: id)
        Diagnostics.log("清空歌单「\(userLists.name(of: id) ?? "")」（\(n) 条引用）："
            + "默认列表、收藏与待播队列未受影响，磁盘上的文件不动")
        return n
    }

    /// 重命名：只改显示名，`id` 一个字都不动 —— 左栏那一行、存档、正在看的页面
    /// 指的是同一张歌单，收藏与待播队列本来就不认歌单，更不受影响
    /// - Returns: nil = 改好了；否则一句没改成的原因
    @discardableResult
    func renameList(id: String, to raw: String) -> String? {
        guard let problem = userLists.rename(id: id, to: raw) else {
            notifyListsChanged()
            return nil
        }
        Diagnostics.error("歌单改名失败：\(problem)")
        return problem
    }

    /// 删除整张歌单：只丢这张歌单的定义与它的条目引用。
    /// 正在看这一页时先切回 [默认]，不然表格会停在一张没有归属的页面上；
    /// [默认] 列表、收藏、历史、待播队列、磁盘上的文件一概不动。
    /// - Returns: 被删掉的那张（nil = 根本没这张），给调用处写「影响范围」用
    @discardableResult
    func deleteList(id: String) -> UserPlaylist? {
        guard let gone = userLists.item(id: id) else { return nil }
        if activeGroup == .playlist(id) {
            // 先把浏览现场换回 [默认]：这一页的条目对象不能继续当成「正在看的列表」
            switchGroup(.main)
        }
        userLists.delete(id: id)
        invalidate(.playlist(id))
        notifyListsChanged()
        Diagnostics.log("删除歌单「\(gone.name)」（\(gone.keys.count) 条引用）："
            + "默认列表、收藏与待播队列未受影响")
        return gone
    }

    /// 把曲目加入指定歌单（右键「加入歌单」，多选按显示顺序传进来）。
    /// 同一首歌在这一张里只留一行；已经在别的歌单里也照样能加进来（歌单之间互不影响）
    @discardableResult
    func addTracks(_ tracks: [Track], toList id: String) -> Int {
        guard !tracks.isEmpty, userLists.contains(id: id) else { return 0 }
        let added = userLists.add(keys: tracks.map { $0.identityKey }, to: id)
        listContentsChanged(id: id)
        let name = userLists.name(of: id) ?? ""
        Diagnostics.log(added > 0 ? "加入歌单「\(name)」\(added) 首" : "歌单「\(name)」里已经有了")
        return added
    }

    /// 歌单页里拖动行改次序（与表格拖放同一个入口）
    @discardableResult
    func moveListRows(id: String, from: IndexSet, to: Int) -> Bool {
        guard userLists.move(id: id, from: from, to: to) else { return false }
        listContentsChanged(id: id)
        return true
    }

    /// 整体重排一张歌单（传进来的键序列不是现有条目的全排列时不做任何事）
    @discardableResult
    func reorderList(id: String, to order: [String]) -> Bool {
        guard userLists.reorder(id: id, to: order) else { return false }
        listContentsChanged(id: id)
        return true
    }

    /// 导出一张歌单为 m3u/m3u8。写的是 identityKey 那一套写法（见 PlaylistM3U），
    /// 所以精确选中的 CUE 分轨与归档条目不会被展开成用户没选的曲目
    func exportList(id: String, to url: URL) -> Bool {
        guard userLists.contains(id: id) else { return false }
        let keys = userLists.keys(of: id)
        var names: [String: String] = [:]
        var durations: [String: Double] = [:]
        // 已经还原出来的条目才有名字可写；没还原的（文件走了）只写身份那一行
        for t in derivedTracks(for: .playlist(id)) {
            names[t.identityKey] = t.artist.isEmpty ? t.title : "\(t.artist) - \(t.title)"
            durations[t.identityKey] = t.duration
        }
        let ok = PlaylistM3U.export(keys: keys, names: names, durations: durations, to: url)
        Diagnostics.log(ok ? "导出歌单「\(userLists.name(of: id) ?? "")」\(keys.count) 条 → "
                            + url.lastPathComponent : "ERROR 歌单导出失败 \(url.path)")
        return ok
    }

    /// 把一个 m3u/m3u8 导成一张新歌单：不往 [默认] 列表里塞歌，也不自动开播
    /// - Returns: nil = 这个文件连文本都读不出；否则 (新歌单 ID, 一句给人看的说明)
    @discardableResult
    func importList(from url: URL, named raw: String? = nil) -> (id: String, note: String)? {
        guard let imported = PlaylistM3U.import(url) else {
            let note = "这份歌单读不出文本（不是 UTF-8/GBK 编码的 m3u）"
            Diagnostics.error("未导入：\(note)")
            return nil
        }
        guard let made = userLists.create(named: raw ?? url.deletingPathExtension().lastPathComponent)
        else {
            let note = "歌单名不能是空的"
            Diagnostics.error("未导入：\(note)")
            return nil
        }
        let added = userLists.add(keys: imported.keys, to: made.id)
        listContentsChanged(id: made.id)
        var note = made.note ?? "\(added) 条入歌单「\(userLists.name(of: made.id) ?? "")」"
        if imported.keys.count > added {
            note += "（同一首歌只留一行，重复的已合掉）"
        }
        if !imported.missing.isEmpty {
            note += "；\(imported.missing.count) 条暂时找不到文件，已在列表里标成缺失"
        }
        if imported.unreadable > 0 {
            note += "；\(imported.unreadable) 行读不懂，未入歌单"
        }
        Diagnostics.log("导入歌单 \(url.lastPathComponent) → 「\(userLists.name(of: made.id) ?? "")」"
            + "（\(added) 条）")
        return (made.id, note)
    }

    // MARK: - 待播队列（右键「下一首播放」/「稍后播放」与队列面板走这里）

    /// 下一首播放：按传入的显示顺序插到当前曲之后、其他待播条目之前（允许重复）
    @discardableResult
    func playNext(_ tracks: [Track]) -> Int {
        guard !tracks.isEmpty else { return 0 }
        queue.insertNext(tracks)
        notifyQueueChanged()
        refreshPrefetch()      // 「下一首播放」就是把下一曲改了，预取得跟着换
        Diagnostics.log("下一首播放 \(tracks.count) 首")
        return tracks.count
    }

    /// 稍后播放：追加队尾（当前曲播完才轮到它们）
    @discardableResult
    func playLater(_ tracks: [Track]) -> Int {
        guard !tracks.isEmpty else { return 0 }
        queue.appendLater(tracks)
        notifyQueueChanged()
        refreshPrefetch()
        Diagnostics.log("稍后播放 \(tracks.count) 首")
        return tracks.count
    }

    /// 从待播里移除几条（不影响正在播的那一条）
    func removeQueued(ids: Set<UUID>) {
        queue.remove(ids: ids)
        notifyQueueChanged()
        refreshPrefetch()      // 排好的下一曲可能被拿掉了，旧预取不能留
    }

    /// 清空待播：正在播的继续播完就收手
    func clearPendingQueue() {
        queue.clearPending()
        notifyQueueChanged()
        refreshPrefetch()
        Diagnostics.log("清空待播队列")
    }

    /// 拖动调整待播顺序（落点由队列自己夹在待播区间内）
    @discardableResult
    func moveQueued(id: UUID, to index: Int) -> Bool {
        let ok = queue.movePending(id: id, to: index)
        if ok {
            notifyQueueChanged()
            refreshPrefetch()
        }
        return ok
    }

    /// 整体重排待播段（队列面板拖完行后一次性提交）：传入的 ID 不是现有待播的全排列时不做任何事
    @discardableResult
    func reorderQueued(to order: [UUID]) -> Bool {
        let ok = queue.reorderPending(to: order)
        if ok {
            notifyQueueChanged()
            refreshPrefetch()
        }
        return ok
    }

    /// 直接播队列里某一条（队列面板双击）：只把游标移到它，不重建上下文，
    /// 所以它后面的条目照样按原次序轮到
    func playQueued(id: UUID) {
        consecutiveFailures = 0
        guard queue.focus(id: id) != nil else { return }
        notifyQueueChanged()
        syncSelectionToPlaying()
        loadAndPlayCurrent()
    }

    // MARK: - 播放控制

    /// 双击列表 / 点播
    func play(track: Track) {
        consecutiveFailures = 0        // 同 playRowAt：手动点播重新开一轮尝试
        guard let index = playlist.index(of: track) ?? playlist.index(ofKey: track.identityKey) else {
            // 不在浏览列表里（例如刚导入还未入表的那首）：单独起一段只包含它的上下文
            queue.begin([track], current: 0)
            notifyQueueChanged()
            syncSelectionToPlaying()
            loadAndPlayCurrent()
            return
        }
        playRowAt(index)
    }

    func playRowAt(_ index: Int) {
        guard playlist.track(at: index) != nil else { return }
        consecutiveFailures = 0        // 用户重新点播：上一次「全部解不开」的计数不能把这一次也拦在外面
        // 双击建立新的播放上下文：以当时的列表顺序作基础序列。
        // 之后切组、筛选、排序只动浏览列表，不再影响「接下来播什么」
        queue.begin(playlist.tracks, current: index)
        notifyQueueChanged()
        // 高亮行跟着走：双击那一行就是选中那一行（同一首在列表里占两行时
        // 也不能拿 identityKey 反查，否则总亮看板上排前面的那行）
        _ = playlist.select(index)
        loadAndPlayCurrent()
    }

    /// 播放 / 暂停切换
    func togglePlay() {
        if isPlaying {
            pause()
            return
        }
        // 电台：暂停即断流，恢复就是重连（直播本来就该听当下的，不补放暂停期间的内容）
        if engine.isRadio {
            engine.play()
            setState(playing: true)
            return
        }
        // 还没建立播放上下文：先排过队就从队列头起播，别把用户排好的次序换成列表第一首
        if queue.current == nil {
            if let head = queue.items.first {
                _ = queue.focus(id: head.id)
                syncSelectionToPlaying()
                loadAndPlayCurrent()
            } else {
                playRowAt(0)
            }
            return
        }
        if engine.duration == 0 {
            loadAndPlayCurrent()
        } else {
            engine.play()
            setState(playing: true)
            // 本曲重新排进节点之后才谈预取：恢复出来的、暂停过的那一曲开声之前
            // 手上根本没有下一曲，播到结尾只能硬切（跟 startLoad 同一个次序）
            schedulePrefetch()
        }
    }

    /// 暂停：留住曲目和进度，等用户或设备事件把它接回来（区别于 stop 的「从头再说」）。
    /// 界面上没有独立的暂停键，但「固定的设备被拔走」这类不是用户按出来的暂停同样要用它，
    /// 所以这是对外方法而不是 togglePlay 的内部细节
    func pause() {
        guard isPlaying else { return }
        engine.pause()
        setState(playing: false)
        flushScene()          // 暂停位置是最要紧的一笔现场，不能等节流
    }

    func stop() {
        engine.stop()
        // 「播完当前曲」指的是把这一条听完：手动停止就没有「播完」这一说了，计划当场作废
        if sleepTimer.waitingTrack { cancelSleepTimer("已停止播放，「播完当前曲」取消") }
        playbackProblem = nil
        consecutiveFailures = 0
        radioNowPlaying = ""
        setState(playing: false)
        postTrackChange()
        // 停止后再按播放可能要隔很久，中间队列还能改：旧预取当场作废重算
        refreshPrefetch()
        // 停止就是「从头再说」：进度归零也得当场落盘，否则下次启动会从停止前的
        // 那一秒接着恢复（用户会以为「按了停止没起作用」）
        flushScene()
    }

    func next() {
        consecutiveFailures = 0        // 手动跨曲算一次新的尝试
        advanceToNext()
    }

    /// 走到队列里的下一条并装载。手动「下一首」与「这一条放不起来自动跳」都走这里，
    /// 但只有手动那条路该清零失败计数：自动跳过也清零的话，整队列都解不开时
    /// 「失败 → 跳下一条 → 又失败」会一路递归到栈溢出
    private func advanceToNext() {
        let before = queue.current?.id
        guard let item = queue.advanceByUser(mode: playMode) else {
            stop()
            return
        }
        if item.id == before {
            // 队列已走到末尾且模式是单曲循环：没有下一首可去。只能原地重播，
            // 不能再回 loadAndPlayCurrent——否则「解不开 → next → 同一条 → 又解不开」会原地递归下去
            if isPlaying { engine.seek(seconds: 0) }
            return
        }
        syncSelectionToPlaying()
        loadAndPlayCurrent()
    }

    func previous() {
        consecutiveFailures = 0        // 同上：手动回退后重新给失败条目一次机会
        guard queue.retreat(mode: playMode) != nil else { return }
        syncSelectionToPlaying()
        loadAndPlayCurrent()
    }

    func seek(to seconds: Double) {
        engine.seek(seconds: seconds)
        if isPlaying { postTimeUpdate() }
        // 系统那一栏的时间是用「快照 + 速率」外推的，拖过进度条必须重新给一次
        NowPlaying.update(track: currentTrack, isPlaying: isPlaying, elapsed: engine.currentTime)
        updateLyricLine(force: true)
        // 节点被冲干净了：排在前面的下一曲要从新位置往后重算（F01）
        refreshPrefetch()
    }

    func setMode(_ mode: PlayMode) {
        playMode = mode
        NotificationCenter.default.post(name: .ttPlayModeChanged,
                                        object: nil,
                                        userInfo: ["mode": mode.rawValue])
        // 模式直接决定「下一曲是谁」：先定选与预取都得跟着重算
        queue.invalidatePick()
        refreshPrefetch()
        scheduleSave()
    }

    func cycleMode() {
        let all = PlayMode.allCases
        let next = all[(all.firstIndex(of: playMode)! + 1) % all.count]
        setMode(next)
    }

    func setVolume(_ v: Float) {
        volume = max(0, min(1, v))
        if volume > 0, isMuted { isMuted = false }
        applyVolume()
        scheduleSave()
    }

    func toggleMute() {
        isMuted.toggle()
        applyVolume()
        scheduleSave()
    }

    private func applyVolume() {
        engine.setVolume(volume, mute: isMuted)
        NotificationCenter.default.post(name: .ttVolumeChanged, object: nil,
                                        userInfo: ["volume": volume, "muted": isMuted])
    }

    // MARK: - 均衡器

    /// 均衡器是否开启（供 UI 高亮按钮）
    var eqEnabled: Bool { !engine.eq.bypass }

    func setEQEnabled(_ enabled: Bool) {
        engine.setEQEnabled(enabled)
        scheduleSave()
    }

    func setEQGain(band: Int, gain: Float) {
        engine.setEQGain(band: band, gain: gain)
        scheduleSave()
    }

    /// 前置放大（皮肤均衡器左旋钮，dB）
    func setPreGain(_ db: Float) {
        engine.setPreGain(db)
        scheduleSave()
    }

    var preGain: Float { engine.preGain }

    // MARK: - 内部

    private func loadAndPlayCurrent() {
        guard let track = queue.currentTrack else { return }
        // 电台切台（台 → 台、台 → 本地文件）：先把正在播的流淡掉再断。
        // 硬切在数模转换上留下的是一个台阶（听感就是“啪”），而换台本来就要等网络，
        // 多等这 120 ms 没人感觉得到
        if engine.isRadio, engine.radioHasSound {
            engine.fadeOutRadioStream(reason: "切到 \(track.title)") { [weak self] in
                self?.startLoad(of: track)
            }
            return
        }
        startLoad(of: track)
    }

    /// 真正把选中的曲目装上引擎（从电台切过来时这一步会被淡出推后 120 ms）
    private func startLoad(of track: Track) {
        engine.stop()
        // 淡出中途重新点播（或到点停止后再开）：增益要跟着当前的计划重算一遍，
        // 不能留着上一轮的衰减值——计划已经结束就是 1，等于恢复正常音量
        applySleepFade()
        if track.isRadio {
            // 电台走自家通路：没有文件、不能 seek，成败由流的状态回调说
            loadRadio(track)
            return
        }
        do {
            // 先把本曲（与已登记的候选）的增益递到引擎，再搭排期流：
            // 顺序反了就会第一句按 1.0 出声、后面才变响（增益要算到段上，不能追已排的缓冲）
            applyReplayGains()
            // CUE 分轨只播镜像里属于本轨的那一段（进度条也以本段为 0）
            try engine.load(url: track.url, from: track.playStart, to: track.playEnd,
                            key: track.identityKey)
        } catch {
            // 打不开也要说清楚为什么：系统错误文本对用户没有信息量，
            // 换成“这个格式缺什么/文件怎么了”，同时留在曲目上供属性面板显示
            let problem = AudioFormats.playbackProblem(for: track, error: error)
            track.decodeProblem = problem
            playbackProblem = problem
            consecutiveFailures += 1
            Diagnostics.error("无法播放 \(track.fileName)：\(problem)（原始错误 \(error)）")
            // 上下文里每一条目都试过仍失败就停手，不然列表循环模式下会自动跳过会无限递归
            let total = max(queue.count, playlist.count)
            guard consecutiveFailures < total else {
                Diagnostics.error("队列里 \(total) 条都放不起来，已停止自动跳过")
                setState(playing: false)
                postTrackChange()
                return
            }
            advanceToNext()
            return
        }
        consecutiveFailures = 0
        playbackProblem = nil
        track.decodeProblem = nil
        markCurrentPlayed()
        // 最近播放：开播就记一笔（暂停后继续不算新的一笔）
        groups.recordPlay(track)
        invalidate(.recent)
        scheduleSave()
        engine.play()
        Diagnostics.log("播放 \(track.fileName) [\(track.formatLabel) "
            + "\(track.bitRateKbps)k \(Int(track.sampleRate))Hz]"
            + (track.isCueSegment ? " CUE 段 \(String(format: "%.2f", track.playStart))s 起" : ""))
        setState(playing: true)
        postTrackChange()
        loadLyric(for: track)
        startTimeTimer()
        // 这一曲排进节点了，紧接着把「下一曲」交给引擎有界预取（F01）
        schedulePrefetch()
        // 换曲当场落一笔：新曲的进度从 0 起，旧现场那一笔留着会在下次启动时播回上一首的中间
        flushScene()
    }

    private func trackDidFinish() {
        let before = queue.current?.id
        // 「播完当前曲」绑的就是这一条：当场收场，不能再往下推进队列（F09）。
        // 单曲循环也照停——用户要的是「这一轮听完就睡」，不是「循环到地老天荒」
        if case .afterTrack(let item) = sleepTimer.plan, item == before {
            fireSleepTimer("等的那一曲播完了")
            return
        }
        guard let item = queue.advanceOnFinish(mode: playMode) else {
            stop()
            return
        }
        if item.id == before {
            // 单曲循环且没有排队条目：原地重播，不重新解码（F01 gapless 上来后改成接排）
            engine.seek(seconds: 0)
            engine.play()
            return
        }
        syncSelectionToPlaying()
        loadAndPlayCurrent()
    }

    /// 真开播了才记一笔：预取、失败跳过都不算「听过」（随机「上一首」沿这条历史回退）
    private func markCurrentPlayed() {
        guard let item = queue.current else { return }
        queue.markPlayed(item)
        notifyQueueChanged()
    }

    // MARK: - 无缝衔接（F01）

    /// 无缝开关（菜单里那一项）。关的时候已经排好的下一曲要退回去，不然「关了还是无缝」
    func setGaplessPlay(_ on: Bool) {
        guard gaplessPlay != on else { return }
        gaplessPlay = on
        engine.setGaplessEnabled(on)
        if on {
            schedulePrefetch()
        } else {
            engine.cancelNext()
            nextCandidateID = nil
            nextCandidateKey = ""
        }
        // 开关本身是个设置（低频），直接走整档存档，不占节流的坑
        persistNow()
        Diagnostics.log("无缝衔接\(on ? "开" : "关")")
    }

    /// 无缝这一轮为什么没做成（异采样率/下一曲解不开/电台……）：属性面板与自检读它
    var gaplessNote: String { engine.gaplessNote }
    /// 已经预取/接进排期流的下一曲身份（空 = 没有）
    var nextPreparedKey: String { engine.nextPreparedKey }
    /// 本进程内已经无缝交接过几次（自检数得着，别拿「没报错」当「接上了」）
    var gaplessHandovers: Int { engine.gaplessHandovers }

    /// 无缝现在的状态，属性面板拿它给用户看一句人话：支持边界不能只写在代码注释里，
    /// 用户得能在界面上看到「这一轮到底接没接上、没接上是因为什么」
    var gaplessStatusText: String {
        if !gaplessPlay { return "已关闭（换曲会停一下）" }
        if !engine.gaplessNote.isEmpty { return engine.gaplessNote }
        if !engine.nextPreparedKey.isEmpty { return "已开，下一曲已经预取好" }
        return "已开，本进程已接上 \(engine.gaplessHandovers) 次"
    }

    /// 属性面板在曲目自带信息之后追加的那几行：内部接口都要有用户入口，
    /// 新增一项播放能力就把它的状态加到这里，别另起一套出口
    func propertyExtraLines(for track: Track) -> [(String, String)] {
        let playing = currentTrack?.identityKey == track.identityKey
        var lines: [(String, String)] = []
        if playing { lines.append(("无缝衔接", gaplessStatusText)) }
        lines.append(("响度均衡", replayGainStatusText(for: track, applied: playing)))
        // 输出设备只有一句全局状态（F07）：正在播这一曲时才值得报，
        // 否则属性面板会让人以为每首歌有自己的输出设备
        if playing { lines.append(("输出设备", outputDeviceSummary)) }
        // 睡眠定时器是全局状态（F09）：只在真的挂着倒计时时说一句。
        // 收场那句留在菜单里（要看随时翻得到），不常驻属性面板：它不是当前曲目的属性
        if sleepTimer.isArmed { lines.append(("睡眠定时器", sleepDetailText)) }
        // 歌词校准是每曲自己的设置（F10）：只在真偏过、或文件自带 offset 时多一句，
        // 没校准过的曲子不必在属性面板里占一行（多数曲子本来就没歌词）
        if playing, abs(lyricShift) >= 0.001 || abs(lyric?.fileOffset ?? 0) >= 0.0001 {
            lines.append(("歌词时间校准", lyricShiftDetail))
        }
        // 电台（F11）：台名到底是谁起的、归在哪一类、流里报的「正在播」、
        // 以及连接质量都得在属性面板看得见；没报上来的参数不写零，只说已知的
        if track.isRadio {
            lines.append(("电台台名", radioStations.hasCustomName(for: track.url)
                ? "自定义（记在这个地址上）" : "按地址显示"))
            lines.append(("电台分类", radioCategoryName(for: track)))
            if playing {
                lines.append(("电台状态", radioStateText))
                if !radioNowPlaying.isEmpty { lines.append(("正在播放", radioNowPlaying)) }
                lines.append(("连接质量", radioQualityText))
            }
        }
        return lines
    }

    /// 把「接下来那一首」交给引擎预取。有界：同时只往流里接一条，队列一变就重算
    private func schedulePrefetch() {
        guard gaplessPlay, !engine.isRadio, let current = queue.current else { return }
        // 睡眠定时器要在这里收尾（等播完 / 已进淡出窗口）：排好的下一曲会在停止那一刻漏出来
        guard !sleepBlocksPrefetch else { return }
        guard let item = queue.peekOnFinish(mode: playMode) else { return }
        let track = item.track
        // 电台下一曲要等流与队列都说话，不预取；归档条目读不到就算预取也是白开一次文件
        guard !track.isRadio else { return }
        let key = item.id == current.id ? track.identityKey + Self.replayKeySuffix : track.identityKey
        nextCandidateID = item.id
        nextCandidateKey = key
        // 先把这一首的增益递到引擎的表里：预取到货时就直接拿表里的数值，
        // 这一步漏了，接上的那一曲就会按 1.0 出声（响度均衡到第二首才生效）
        applyReplayGains()
        engine.prepareNext(url: track.url, from: track.playStart, to: track.playEnd, key: key)
    }

    /// 队列/模式/ seek / 停止之后重新对一次表：先作废旧预取，再按现在的次序重算。
    /// 不能只算不丢：旧预取还排在流里，接上的就是用户已经改拿掉的那一首
    private func refreshPrefetch() {
        engine.cancelNext()
        nextCandidateID = nil
        nextCandidateKey = ""
        schedulePrefetch()
    }

    /// 引擎把预取的那一曲接上了：只换「当前曲目」这一侧的显示与记录，绝不重新装载
    /// （装载会 `playerNode.stop()`，把刚接上的声音冲掉，那就又变成硬切）
    private func adoptHandover(key: String) {
        // 先凭登记的条目认人；队列在预取之后被改过就退到按身份找（宁可认错一次次序，
        // 也不能「听见的是 A、显示的是 B」）
        var item: QueueItem?
        if key == nextCandidateKey, let id = nextCandidateID {
            item = queue.focus(id: id)
        }
        if item == nil {
            let plain = key.hasSuffix(Self.replayKeySuffix)
                ? String(key.dropLast(Self.replayKeySuffix.count)) : key
            item = queue.confirmHandover(forKey: plain)
        }
        guard let adopted = item else {
            // 接上的那一曲已经不在上下文里了：停下来重新走「播完推进」那一路。
            // 听得多一次硬切，比让显示与声音对不上号可接受
            Diagnostics.error("无缝交接对不上号（\(key)），退回重新推进")
            engine.stop()
            trackDidFinish()
            return
        }
        nextCandidateID = nil
        nextCandidateKey = ""
        consecutiveFailures = 0
        playbackProblem = nil
        adopted.track.decodeProblem = nil
        // 交接发生的那一刻才算「真开播」：预取不能提前记播放历史、也不能提前切显示
        queue.markPlayed(adopted)
        notifyQueueChanged()
        groups.recordPlay(adopted.track)
        invalidate(.recent)
        scheduleSave()
        syncSelectionToPlaying()
        setState(playing: true)
        postTrackChange()
        loadLyric(for: adopted.track)
        flushScene()
        // 接上的这一曲也要有下一曲可接
        schedulePrefetch()
    }

    // MARK: - 响度均衡 ReplayGain（F02）

    /// 启用范围：默认关闭。旧档缺这一项时也要按关闭，不能升级一下就替用户改了音量
    private(set) var replayGainMode: ReplayGainMode = .off
    /// 独立前置增益（dB）：只算在 ReplayGain 这条链路上，不碰用户音量滑块
    private(set) var replayGainPreamp: Float = 0
    /// 峰值防削波：默认开。它只拿 Peak 限制「标签增益 + 前置增益」的合成值，
    /// EQ 把某个频段推高造成的削波它保证不了（菜单项的提示里就这么写明）
    private(set) var replayGainPeakLimit = true

    /// 三个开关都走这一对入口（菜单与自检共用），改完立即重排增益并落盘
    func setReplayGainMode(_ mode: ReplayGainMode) {
        guard replayGainMode != mode else { return }
        replayGainMode = mode
        applyReplayGains()
        persistNow()
        Diagnostics.log("响度均衡 → \(mode.displayName)")
    }

    /// 前置增益只在 -12…+12 dB 之间：越界的输入夹到边界，不把它当成「没设过」丢掉，
    /// 也不拿一个把声音推爆的数值当真
    func setReplayGainPreamp(_ db: Float) {
        let clamped = min(max(db, -12), 12)
        guard abs(clamped - replayGainPreamp) > 0.009 else { return }
        replayGainPreamp = clamped
        applyReplayGains()
        persistNow()
    }

    func setReplayGainPeakLimit(_ on: Bool) {
        guard replayGainPeakLimit != on else { return }
        replayGainPeakLimit = on
        applyReplayGains()
        persistNow()
        Diagnostics.log("峰值防削波\(on ? "开" : "关")")
    }

    /// 一首曲子在当前设置下的增益决定（属性面板与自检都读这一份，不各算一套）
    func replayGainDecision(for track: Track) -> ReplayGainDecision {
        ReplayGainDecision.decide(tags: track.replayGainTags, mode: replayGainMode,
                                  preamp: Double(replayGainPreamp),
                                  peakLimit: replayGainPeakLimit, isRadio: track.isRadio)
    }

    /// 把「此刻排期里会用到的曲目」的增益整份交给引擎。按身份递而不是只递当前曲：
    /// 下一曲已经接在流里时，它要用的是自己那份标签，不是上一首的
    private func applyReplayGains() {
        var gains: [String: Float] = [:]
        func register(_ track: Track?) {
            guard let track, !track.isRadio else { return }
            let lin = replayGainDecision(for: track).linear
            gains[track.identityKey] = lin
            // 单曲循环预取用的是加了 `#replay` 的身份，两个写法都要登记：
            // 只登记一个就会在「接自己再来一遍」时查不到而退成 1.0
            gains[track.identityKey + Self.replayKeySuffix] = lin
        }
        register(queue.currentTrack)
        // 只查不动：这里要是用了 `focus(id:)`，「看一眼下一候选」就会把播放游标挪过去
        // （实测：预取一到位，听的还是 A、显示已经跳到 B），拿 `item(id:)` 读那一条
        if let id = nextCandidateID { register(queue.item(id: id)?.track) }
        engine.setReplayGains(gains)
    }

    /// 属性面板里「响度均衡」那一行：说清用了哪份标签、回退到哪、限幅动了手没有；
    /// 没标签与标签还没读到是两回事，不能都写成 0 dB
    func replayGainStatusText(for track: Track, applied: Bool) -> String {
        let d = replayGainDecision(for: track)
        switch d.source {
        case .radio:
            return d.summaryText
        case .off:
            return "已关闭（只听原曲自己的响度）"
        case .noTag:
            // 没标签就是「不会动音量」，再说「已施加 0 dB」只会让人去找那个 0 在哪儿
            return track.replayGainTags == nil ? "标签还没读到（元数据在后台解析）" : d.summaryText
        default:
            var text = "\(applied ? "已施加 " : "未播放，按现在的设置会加 ")\(d.summaryText)"
            if abs(replayGainPreamp) > 0.009 {
                text += "｜含前置增益 \(String(format: "%+.1f", replayGainPreamp)) dB"
            }
            return text
        }
    }

    // MARK: - 睡眠定时器（F09）
    //
    // 「还剩多久、此刻该给多少淡出增益」在 `SleepTimer` 里（时钟可注入，自检不必真等十五分钟）；
    // 这一层只管三件要动引擎与队列的事：什么时候真的停下、淡出增益往输出链路上推、
    // 以及「播完当前曲」与无缝预取之间的冲突——预取要是还排在流里，停止那一刻就会漏出下一曲。
    //
    // 计划本身不进存档：需求是「退出应用即取消、不跟到下一次启动」，
    // 重启后界面上挂一个走不完的倒计时反而是错的；只有「要不要淡出」是设置。

    let sleepTimer = SleepTimer()
    /// 到点前是否淡出（设置项，重启还在）
    private(set) var sleepFadeEnabled = true
    /// 淡出时长（秒）：需求里定死 10 s，做成常量，界面与自检都读它
    static let sleepFadeSeconds: Double = 10
    /// 心跳：0.5 s 一格，够把「剩余时间」读顺，又不必为它单开一条线程
    private var sleepTickTimer: Timer?
    /// 进了淡出窗口就退一次预取，不必每格都退（`cancelNext` 刷多了日志也碍事）
    private var sleepPrefetchDropped = false
    /// 这一轮定时器怎么收场的（到点/取消/被拒），属性面板说一次就够
    private(set) var sleepNote: String?

    /// 界面上那一句：没设就是空串
    var sleepStatusText: String { sleepTimer.statusText(trackTitle: currentTrack?.title) }

    /// 状态行上那一截短字（`剩 12:34` / `播完停`）：没设就不给，界面不缀尾巴
    var sleepMenuHint: String? {
        switch sleepTimer.plan {
        case .off: return nil
        case .countdown: return "剩 \(TimeFormat.clock(sleepTimer.remaining ?? 0))"
        case .afterTrack: return "播完停"
        }
    }

    /// 计划该不该拦住预取：「等播完」那一档全程拦，按分钟那一档进淡出窗口才拦
    private var sleepBlocksPrefetch: Bool {
        switch sleepTimer.plan {
        case .off: return false
        case .countdown: return sleepTimer.inFadeWindow
        case .afterTrack: return true
        }
    }

    /// 属性面板那句完整状态（含淡出设置，用户得看得见「到点是渐弱还是硬停」）
    var sleepDetailText: String {
        let tail = sleepFadeEnabled ? "到点前淡出 \(Int(Self.sleepFadeSeconds)) 秒" : "到点直接停止"
        guard sleepTimer.isArmed else {
            return sleepNote.map { "\($0)（\(tail)）" } ?? "未设置（\(tail)）"
        }
        return "\(sleepStatusText)｜\(tail)"
    }

    /// 按分钟设一档。返回 nil = 已采纳，否则一句不采纳的原因（菜单直接把那句话弹给用户）
    @discardableResult
    func setSleepMinutes(_ minutes: Int) -> String? {
        if let err = sleepTimer.arm(minutes: minutes) { return rejectSleep(err) }
        sleepNote = nil
        sleepPrefetchDropped = false
        applySleepFade()
        startSleepTicker()
        // 从「等播完」那档换过来时可能退过预取，按分钟重新排一趟才不断歌
        refreshPrefetch()
        postSleepChange()
        Diagnostics.log("睡眠定时器：\(minutes) 分钟后停止播放")
        return nil
    }

    /// 播完当前这一条就停：绑的是设置这一刻的队列条目 ID，之后队列怎么改都不改主意
    @discardableResult
    func setSleepAfterCurrentTrack() -> String? {
        // 电台是无限流，压根没有「播完」这一说——与其默默退化成按分钟，不如说清楚
        if engine.isRadio {
            return rejectSleep("电台是无限流，没有「播完」的时刻，请改用按分钟那一档")
        }
        guard let item = queue.current else {
            return rejectSleep("现在没有正在播的曲目，先播一首再设「播完当前曲」")
        }
        sleepTimer.armTrack(item: item.id)
        sleepNote = nil
        applySleepFade()
        // 下一曲已经排进流里的话，这一曲播完引擎会直接接上，等不到我们喊停
        dropSleepPrefetch()
        startSleepTicker()
        postSleepChange()
        Diagnostics.log("睡眠定时器：播完「\(currentTrack?.title ?? "")」就停止播放")
        return nil
    }

    func cancelSleepTimer(_ note: String? = nil) {
        guard sleepTimer.isArmed else {
            if let note { sleepNote = note }
            return
        }
        sleepTimer.cancel()
        stopSleepTicker()
        sleepPrefetchDropped = false
        // 淡出中途取消：只把链路增益放回 1，用户的音量与静音一个字节都不动
        applySleepFade()
        refreshPrefetch()
        if let note { sleepNote = note }
        postSleepChange()
        Diagnostics.log("睡眠定时器已取消")
    }

    /// 淡出开关：关掉之后已经到点停止的那一轮不会倒回去，只影响往后的倒计时
    func setSleepFadeEnabled(_ on: Bool) {
        guard sleepFadeEnabled != on else { return }
        sleepFadeEnabled = on
        sleepTimer.fadeSeconds = on ? Self.sleepFadeSeconds : 0
        applySleepFade()
        persistNow()
        Diagnostics.log("睡眠淡出\(on ? "开" : "关")（关了就当场硬停）")
    }

    /// 自定义分钟那一步的校验入口：菜单与自检共用同一套判据，不各写一份
    @discardableResult
    func applyCustomSleepMinutes(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return rejectSleep("分钟数不能为空") }
        guard let n = Int(t), n > 0 else { return rejectSleep("分钟数要填正整数（1 分钟起）") }
        return setSleepMinutes(n)
    }

    @objc private func sleepTick() {
        guard sleepTimer.isArmed else { stopSleepTicker(); return }
        switch sleepTimer.plan {
        case .countdown:
            if sleepTimer.inFadeWindow, !sleepPrefetchDropped { dropSleepPrefetch() }
            applySleepFade()
            if sleepTimer.due { fireSleepTimer("到点") }    // 醒来时早已过点也算：不补播
        case .afterTrack(let item):
            // 手动跳离（上一首/下一首/双击别的行/把队列清了）都算「那一曲不播了」：计划作废
            guard queue.current?.id == item else {
                cancelSleepTimer("已经离开那一曲，「播完当前曲」取消")
                return
            }
        case .off:
            break
        }
        postSleepChange()
    }

    /// 定时器收场：先撤计划，再停手，最后把链路上的淡出残值清干净
    private func fireSleepTimer(_ reason: String) {
        Diagnostics.log("睡眠定时器\(reason)，停止播放")
        sleepTimer.cancel()
        stopSleepTicker()
        stop()                       // 里面会 refreshPrefetch，所以撤预取要排在它后面
        dropSleepPrefetch()
        applySleepFade()             // 已经无声，这里只是把增益放回 1，别带到下一次开播
        sleepNote = "\(reason)，已停止播放"
        postSleepChange()
    }

    /// 采纳不了时的一句话：既回给调用方（菜单要弹），也留在状态里供属性面板复述
    @discardableResult
    private func rejectSleep(_ err: String) -> String {
        sleepNote = err
        Diagnostics.error("睡眠定时器：\(err)")
        postSleepChange()
        return err
    }

    private func dropSleepPrefetch() {
        engine.cancelNext()
        nextCandidateID = nil
        nextCandidateKey = ""
        sleepPrefetchDropped = true
    }

    /// 把计划算出的增益推到输出链路（淡出那一级，不碰用户音量）。
    /// 装载、心跳、取消、收摊都得推一次：漏一处就会把上一轮的衰减值带到下一曲
    func applySleepFade() {
        engine.setSleepGain(sleepTimer.fadeGain)
    }

    private func startSleepTicker() {
        stopSleepTicker()
        let t = Timer(timeInterval: 0.5, target: self, selector: #selector(sleepTick),
                      userInfo: nil, repeats: true)
        // .common 模式：开着右键菜单、拖着进度条时定时器也得走，否则淡出会卡在最后一格
        RunLoop.main.add(t, forMode: .common)
        sleepTickTimer = t
    }

    private func stopSleepTicker() {
        sleepTickTimer?.invalidate()
        sleepTickTimer = nil
    }

    private func postSleepChange() {
        NotificationCenter.default.post(name: .ttSleepChanged, object: nil,
                                        userInfo: ["summary": sleepStatusText])
    }

    // MARK: - 输出设备（F07）
    //
    // 设置里存的是 UID（重插不换号），AudioDeviceID 只在当场用；引擎只回答两件事：
    // 「现在实际往哪台出声」与「把出声换到那台去」，拔出、接回、默认设备变了这些
    // 判断都收在这一层，因为它们要动的是播放状态而不只是音频图。

    /// 用户选定的输出设备 UID。空串 = 跟随系统默认（需求里的默认档）
    private(set) var outputDeviceUID = ""
    /// 设备层面的问题（固定的设备被拔走、切换没成）：显示区与属性面板都说得出
    private(set) var outputProblem: String?
    /// 拔出时那台设备的名字：它已经不在了，名字只能事先留住
    private var pinnedDeviceName = ""
    /// 上一回对账时固定的那台设备是不是不在（接回来要能说出口，不能默默清掉提示）
    private var pinnedDeviceMissing = false
    /// 监听只挂一次（进程级），所以单独有个开关量
    private var watchingOutputs = false

    /// 可选设备清单（麦克风一类 0 声道已被筛掉）
    var availableOutputDevices: [OutputDevices.Device] { OutputDevices.available() }

    /// 实际在出声那台设备的名字。输出链还没接起来时按系统默认说（那正是接起来时会用的），
    /// 一台可用设备都没有就直说，不编一个名字出来
    var outputDeviceNameText: String {
        (engine.outputDevice ?? OutputDevices.systemDefault())?.name ?? "没找到可用的输出设备"
    }

    /// 「当前实际输出设备」那一行：菜单副标题、属性面板、自检凭据共用一份
    var outputDeviceSummary: String {
        if let problem = outputProblem { return problem }
        let actual = outputDeviceNameText
        if outputDeviceUID.isEmpty { return "跟随系统默认（实际：\(actual)）" }
        let pinned = OutputDevices.resolve(outputDeviceUID)?.name ?? pinnedDeviceName
        return "\(pinned)（已固定，实际：\(actual)）"
    }

    /// 菜单与自检共用的唯一入口：切输出设备。返回 nil = 成功，否则一句人话原因。
    /// 失败时什么都不改（设置、菜单的勾、正在播的曲都停在原样），只把原因说出口
    @discardableResult
    func setOutputDevice(uid: String) -> String? {
        // 「跟随系统默认」不是存个空串就完事：AUHAL 守着它已经打开的那台不放，
        // 实测系统默认换了它也不跟，所以这一档要当场切到当前默认
        guard let reason = engine.setOutputDevice(uid: uid) else {
            outputDeviceUID = uid
            pinnedDeviceName = engine.outputDevice?.name ?? ""
            outputProblem = nil
            persistNow()
            Diagnostics.log("输出设备设置 → \(uid.isEmpty ? "跟随系统默认" : pinnedDeviceName)")
            postOutputChange()
            return nil
        }
        outputProblem = reason
        Diagnostics.error("输出设备切换失败：\(reason)")
        postOutputChange()
        return reason
    }

    /// 挂 CoreAudio 监听与休眠唤醒回调（启动时一次）。回调从专用队列转回主线程
    func startWatchingOutputs() {
        guard !watchingOutputs else { return }
        watchingOutputs = true
        OutputDevices.startWatching { [weak self] change in
            DispatchQueue.main.async {
                switch change {
                case .devicesChanged: self?.reconcileOutputDevice("设备清单变了")
                case .defaultChanged: self?.reconcileOutputDevice("系统默认输出变了")
                }
            }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(systemDidWake),
                       name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func systemDidWake() {
        // 真休眠要等系统下一次睡眠才能验（自检不能为了验证而把机器睡掉），
        // 这一条至少把「醒来就该对账」这件事落在日志里
        Diagnostics.log("系统唤醒：对一次输出设备的账")
        reconcileOutputDevice("系统唤醒")
    }

    /// 对一次账：设置里的设备还在不在、实际出声的是不是它、该出声时引擎跑没跑。
    /// 三样有不对就动手，全对不碰音频图（用户没开口，声音不该被折腾）
    @discardableResult
    func reconcileOutputDevice(_ note: String) -> String? {
        // 一声未响时输出链根本还没建（启动那 130 ms 是拖到第一次播放才付的），
        // 这时没什么可对：引擎会在接线那一刻按设置补上设备（见 wireOutputIfNeeded）
        guard engine.outputDevice != nil else {
            postOutputChange()
            return nil
        }
        if !outputDeviceUID.isEmpty, !OutputDevices.exists(uid: outputDeviceUID) {
            // 固定的设备没了：先停下来。CoreAudio 会把 AUHAL 默默挪到系统默认上，
            // 不停下来就是「怎么突然从扬声器出声」（需求点名要挡的一档）
            if isPlaying { pause() }
            let name = pinnedDeviceName.isEmpty ? outputDeviceUID : pinnedDeviceName
            pinnedDeviceMissing = true
            outputProblem = "固定的输出设备「\(name)」已不可用（拔出了？），播放已暂停；"
                + "可插回该设备，或在菜单里另选一台"
            Diagnostics.error("输出设备不可用（\(note)）：\(name)")
            postOutputChange()
            return outputProblem
        }
        // 接回来了：只清掉「不可用」那一档的提示，重新固定交给下面那一步做；
        // 保持暂停不自己开声（需求：接回后由用户恢复）
        if pinnedDeviceMissing {
            pinnedDeviceMissing = false
            outputProblem = nil
            Diagnostics.log("输出设备接回（\(note)）：\(pinnedDeviceName)，仍保持暂停等用户恢复")
        }
        let expectedUID = outputDeviceUID.isEmpty
            ? OutputDevices.systemDefault()?.uid : outputDeviceUID
        if let expectedUID, engine.outputDeviceUID != expectedUID {
            // 跟随档：系统默认换了得跟过去；固定档：AUHAL 被系统挪走了，扳回来
            if let reason = engine.setOutputDevice(uid: outputDeviceUID) {
                outputProblem = reason
                Diagnostics.error("输出设备对账没改成（\(note)）：\(reason)")
                postOutputChange()
                return reason
            }
            pinnedDeviceName = engine.outputDevice?.name ?? pinnedDeviceName
        }
        // 该出声而引擎停了（睡了一觉最常见的后患）：不换设备，只把链重谈一遍续上
        if isPlaying, !engine.audioEngineRunning {
            Diagnostics.log("输出设备对账（\(note)）：\(engine.restartOutputChain())")
        }
        postOutputChange()
        return nil
    }

    // MARK: - 电台

    private func loadRadio(_ track: Track) {
        // 不在这里清失败计数：自动推进到下一台时不能清掉它，否则每一台都连不上的列表
        // 永远走不到 `selectNextAfterRadioFailure` 的上界，会在列表里无限打转。
        // 用户发起的新点播（playRowAt / play / next / previous / stop）各自已经清零，
        // 真正连上了也在 `.playing` 回调里清零
        playbackProblem = nil
        track.decodeProblem = nil
        markCurrentPlayed()
        radioNowPlaying = ""
        groups.recordPlay(track)
        invalidate(.recent)
        // 台另记一份“最近听的台”：台被删出列表也还能从这一组点回来听
        groups.recordRadioPlay(track)
        invalidate(.recentRadio)
        scheduleSave()
        engine.loadRadio(url: track.url)
        engine.play()
        Diagnostics.log("播放电台 \(track.url.absoluteString)")
        setState(playing: true)
        postTrackChange()
        // 电台没有 .lrc：把上一首的歌词清掉，否则显示区还挂着上一首的词
        lyric = nil
        lyricIndex = -2
        updateLyricLine(force: true)
        startTimeTimer()
    }

    /// 流状态回话：连上了、断了在重连、还是彻底失败
    private func radioStateDidChange(_ state: RadioPlayer.State) {
        switch state {
        case .failed(let reason):
            // 重连到上限：这一次就不响了，原因同时留在显示区与曲目上（属性面板能查）
            playbackProblem = reason
            currentTrack?.decodeProblem = reason
            setState(playing: false)
            selectNextAfterRadioFailure()
        case .playing:
            playbackProblem = nil
            currentTrack?.decodeProblem = nil
            // 连上了才算这一轮失败周期真正结束（与本地文件装载成功时同一口径）
            consecutiveFailures = 0
            // 只认「用户还想听」那一次：停止后 engine.isRadio 依旧为真（再按播放就是重连这个台），
            // 单靠它挡不住从队列那边异步转过来的旧回调——不然按了停止，晚到的「直播中」
            // 会把播放状态重新点亮，而状态文字已经回到「未连接」（F11 的过期回调防护）
            if engine.radioWantsPlay, !isPlaying { setState(playing: true) }
        case .idle, .connecting, .reconnecting, .fallingBack:
            break
        }
        postRadioChange()
    }

    /// 电台连不上时不要停在那里装死：按当前播放模式跳下一首（与本地文件打不开一致）
    private func selectNextAfterRadioFailure() {
        consecutiveFailures += 1
        guard consecutiveFailures < max(queue.count, playlist.count) else {
            Diagnostics.error("队列里 \(max(queue.count, playlist.count)) 条都放不起来，已停止自动跳过")
            return
        }
        advanceToNext()
    }

    /// 流里报出真实参数（编码/采样率/码率）：写回曲目，列表与属性面板跟着变
    private func radioInfoDidArrive(_ info: RadioStreamDecoder.Info) {
        guard let track = currentTrack, track.isRadio else { return }
        if !info.codec.isEmpty { track.formatName = info.codec }
        if info.sampleRate > 0 { track.sampleRate = info.sampleRate }
        if info.bitRateKbps > 0 { track.bitRateKbps = info.bitRateKbps }
        notifyPlaylistChanged()
        postRadioChange()
    }

    private func setRadioNowPlaying(_ title: String) {
        radioNowPlaying = title
        postRadioChange()
    }

    private func postRadioChange() {
        NotificationCenter.default.post(name: .ttRadioChanged, object: nil,
                                        userInfo: ["state": radioStateText,
                                                   "title": radioNowPlaying])
    }

    // MARK: - 电台台名与分类（F11）

    /// 给某个地址起/改/取消自定义台名（右键「自定义台名…」）。
    ///
    /// 台名只按地址身份存：流里 ICY 报的 StreamTitle 只进「正在播」那一行，
    /// 永远不会回写这张表；空名字不是错误，是「取消自定义」，回到按地址显示。
    /// - Returns: nil = 办好了；否则一句原因
    @discardableResult
    func setRadioName(_ track: Track, to raw: String) -> String? {
        guard track.isRadio else { return "这一条不是电台：本地文件的歌名请用「编辑标签」" }
        let key = track.identityKey
        radioStations.setAlias(key: key, raw: raw)
        refreshRadioTitles(keys: [key])
        radioStationsChanged()
        if currentTrack?.identityKey == key { postTrackChange() }
        Diagnostics.log(radioStations.alias(for: key) == nil
                        ? "电台「\(RadioURL.displayName(for: track.url))」恢复按地址显示"
                        : "电台台名→「\(radioStations.alias(for: key) ?? "")」（记在地址上）")
        return nil
    }

    /// 新建电台分类（左栏右键）。名字空时不建，返回 nil 让调用处说一句人话
    /// - Returns: (新分类 ID, 同名自动区分时的一句说明)
    @discardableResult
    func createRadioCategory(named raw: String) -> (id: String, note: String?)? {
        guard let made = radioStations.createCategory(named: raw) else {
            Diagnostics.error("未建电台分类：名字不能是空的")
            return nil
        }
        radioStationsChanged()
        switchGroup(.radioCategory(made.id))
        Diagnostics.log("新建电台分类「\(radioStations.name(of: made.id) ?? "")」")
        return made
    }

    /// 重命名分类：只改显示名，id 不动，所以台的归属与存档里记住的那一页还是同一件事
    @discardableResult
    func renameRadioCategory(id: String, to raw: String) -> String? {
        guard let problem = radioStations.renameCategory(id: id, to: raw) else {
            radioStationsChanged()
            return nil
        }
        Diagnostics.error("电台分类改名失败：\(problem)")
        return problem
    }

    /// 删除分类：**只掉这个壳**，里面那些台的地址与自定义台名一条都不动，它们回到未分类。
    /// 未分类是默认入口，删不掉（返回 nil）
    /// - Returns: (被删的分类名, 回到未分类的台数)；没删成就是 nil
    @discardableResult
    func deleteRadioCategory(id: String) -> (name: String, moved: Int)? {
        guard let gone = radioStations.category(id: id) else { return nil }
        let (_, moved) = radioStations.deleteCategory(id: id)
        // 正在看这一页时先切到未分类：不能把浏览现场停在一张已经没有归属的页面上
        if activeGroup == .radioCategory(id) { switchGroup(.radioCategory(RadioStations.uncategorizedID)) }
        radioStationsChanged()
        Diagnostics.log("删除电台分类「\(gone.name)」：\(moved) 个台回到未分类，地址与台名不动")
        return (gone.name, moved)
    }

    /// 把若干台移进某个分类（`id` 为 nil 或「未分类」= 把归属摘掉，不是删台）。
    /// 目标分类不存在时一个都不动，并回一句原因
    /// - Returns: nil = 办好了；否则一句原因
    @discardableResult
    func moveRadios(keys: [String], to id: String?) -> String? {
        guard !keys.isEmpty else { return nil }
        let done = radioStations.move(keys: keys, to: id)
        guard let problem = done.problem else {
            radioStationsChanged()
            return nil
        }
        Diagnostics.error("电台移入分类失败：\(problem)")
        return problem
    }

    /// 改一个台的地址（F11「修改地址…」）：先安全停掉旧连接，再把台名/归属/收藏/
    /// 两份历史/歌单引用/歌词校准一起搬到新地址上 —— 需求要的就是「用户设置跟着走」，
    /// 不能让用户改了个地址就要重新收藏一次。
    /// 什么条件不合时（新地址非法/与列里另一个台撞车）一律不动，回一句原因
    /// - Returns: nil = 改好了；否则一句原因
    @discardableResult
    func updateRadioAddress(_ track: Track, to raw: String) -> String? {
        guard track.isRadio else { return "这一条不是电台：本地文件请在访达里移动" }
        let oldKey = track.identityKey
        guard let fresh = RadioURL.normalize(raw) else {
            let note = "地址不对：只支持 http:// 或 https:// 开头的电台地址"
            Diagnostics.error("电台改地址未执行：\(note)")
            return note
        }
        let newKey = fresh.absoluteString
        guard newKey != oldKey else { return "地址没变，不用改" }
        // 撞车比多一条更糟：两条同地址的台，台名与归属只能认一条
        if archivedKeys().contains(newKey) {
            let note = "已经有一条用这个地址的电台了：请先处理重复再改"
            Diagnostics.error("电台改地址未执行：\(note)")
            return note
        }
        // 旧连接先停：会话号当场递增，晚到的回调与还没执行的退避重试自然作废；
        // 正在播的也是这一台时不能只改内存里的对象，否则声音仍来自旧地址
        let wasPlayingThis = isRadio && currentTrack?.identityKey == oldKey
        if wasPlayingThis { stop() }
        // 台名与归属先搬到新地址，再走统一的键迁移：`applyKeyMap` 会把列表/队列/
        // 收藏/两份历史/每张歌单里的旧键换成新键，而新地址解出来的 Track 构造时
        // 就会拿到刚搬过来的台名（台名按地址存，这一段得先走）
        radioStations.replaceKeys([oldKey: newKey])
        let moved = applyKeyMap([oldKey: newKey])
        // 两个方向都不能断档：「最近听的台」里这一条换了写法仍然排在原位
        radioStationsChanged()
        Diagnostics.log("电台地址变更 \(track.url.absoluteString) → \(newKey)："
            + "迁移 \(moved) 处引用与台名/归属，旧连接已停")
        if wasPlayingThis, let next = trackForKey(newKey) { play(track: next) }
        return nil
    }

    /// 手动重试这个台（右键「重试这个电台」）：重新装载 = 旧会话当场停掉、
    /// 退避从第 0 次重新算起、质量台账翻页重记。
    /// 只走点播那一条路：显式停止后不会自己重连，用户按这一次才算一次新的意图
    /// - Returns: nil = 已经开始重试；否则一句原因
    @discardableResult
    func retryRadio(_ track: Track) -> String? {
        guard track.isRadio else { return "这一条不是电台，直接在列表里双击就能重播" }
        guard playlist.index(ofKey: track.identityKey) != nil || currentTrack?.identityKey == track.identityKey else {
            return "这一条已经不在列表里了"
        }
        playbackProblem = nil
        track.decodeProblem = nil
        play(track: track)
        Diagnostics.log("手动重试电台 \(track.url.absoluteString)")
        return nil
    }

    /// 按稳定身份找回内存里的那条（地址迁移后拿新对象用）
    private func trackForKey(_ key: String) -> Track? {
        if let i = playlist.index(ofKey: key), let t = playlist.track(at: i) { return t }
        return mainSnapshot.first { $0.identityKey == key }
    }

    /// 台名改了之后把内存里同地址的条目一起改名（曲库留档、正在看的表、待播队列
    /// 拿的都是同一个 Track 对象，改对象就等于全跟上）
    private func refreshRadioTitles(keys: Set<String>) {
        var pool: [String: Track] = [:]
        for t in mainSnapshot + playlist.tracks + queue.items.map({ $0.track }) where t.isRadio {
            pool[t.identityKey] = t
        }
        for key in keys {
            guard let t = pool[key] else { continue }
            t.title = radioStations.displayName(for: t.url)
        }
    }

    /// 台名/分类/归属变了之后的统一收尾：电台那几页都是投影，缓存与正在看的页面都得跟上
    private func radioStationsChanged() {
        for kind in groupLayout where kind.isRadioPage { invalidate(kind) }
        if activeGroup.isRadioPage { reloadActiveGroup() }
        notifyPlaylistChanged()
        NotificationCenter.default.post(name: .ttRadioStationsChanged, object: nil)
        scheduleSave()
    }

    /// 这个台在界面上的分类名（未归类时是「未分类」）：属性面板与自检读它
    func radioCategoryName(for track: Track) -> String {
        guard let id = radioStations.categoryID(of: track.identityKey),
              let name = radioStations.name(of: id) else { return "未分类" }
        return "「\(name)」"
    }

    /// 分类页实际会列出台数（与页面同一口径：拿档案里的归属与列表里真有的台求交）。
    /// 菜单标题与删除确认得说真数字，不能拿归属表里包着已被删掉的台那一份充数
    func radioCount(in id: String) -> Int {
        derivedKeys(for: .radioCategory(id)).count
    }

    /// 输出设备这一层的任何变化（用户切换、拔出、接回、默认换了）都说到界面：
    /// 显示区那行与属性面板拿得到，不必等用户去菜单里重新打开
    private func postOutputChange() {
        NotificationCenter.default.post(name: .ttOutputChanged, object: nil,
                                        userInfo: ["summary": outputDeviceSummary])
    }

    private func setState(playing: Bool) {
        isPlaying = playing
        NotificationCenter.default.post(name: .ttPlaybackStateChanged, object: nil,
                                        userInfo: ["isPlaying": playing])
        NowPlaying.update(track: currentTrack, isPlaying: playing, elapsed: engine.currentTime)
        if playing { startTimeTimer() } else { timeTimer?.invalidate(); timeTimer = nil }
    }

    private func startTimeTimer() {
        guard timeTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.postTimeUpdate()
            self?.updateLyricLine(force: false)
            // 进度落盘走节流：现场文件很小，但 0.25 s 一笔也没必要（闪退/断电最多丢 5 s）
            self?.scheduleSceneFlush()
        }
        RunLoop.main.add(timer, forMode: .common)
        timeTimer = timer
    }

    private func postTimeUpdate() {
        NotificationCenter.default.post(name: .ttTimeUpdated, object: nil,
                                        userInfo: ["time": engine.currentTime,
                                                   "duration": engine.duration])
    }

    private func postTrackChange() {
        NotificationCenter.default.post(name: .ttTrackChanged, object: nil,
                                        userInfo: ["track": currentTrack as Any])
        // 控制中心那一栏跟播放状态一起换：只换标题不清进度，进度条会跳到上一首的位置
        NowPlaying.update(track: currentTrack, isPlaying: isPlaying, elapsed: engine.currentTime)
    }

    private func notifyPlaylistChanged() {
        NotificationCenter.default.post(name: .ttPlaylistChanged, object: nil)
        scheduleSave()
    }

    /// 歌单清单变了（新建 / 改名 / 删除）：左栏那一列要重排，统计文字也要跟着改名
    private func notifyListsChanged() {
        NotificationCenter.default.post(name: .ttUserListsChanged, object: nil)
        notifyPlaylistChanged()
    }

    /// 某张歌单的条目变了：缓存作废，正在看这一页就重刷表格；
    /// 没在看这一页也要让左栏与存档跟上（别的歌单、[默认] 列表、队列都不动）
    private func listContentsChanged(id: String) {
        invalidate(.playlist(id))
        if activeGroup == .playlist(id) { reloadActiveGroup() }
        notifyListsChanged()
    }

    /// 队列变了：面板要重画待播条目与「当前」标记
    private func notifyQueueChanged() {
        NotificationCenter.default.post(name: .ttQueueChanged, object: nil)
        // 排队/移除/重排也是现场的一部分（下次启动要回到同一个待播次序）
        scheduleSceneFlush()
    }

    // MARK: - 歌词

    private func loadLyric(for track: Track) {
        lyric = Lyric.load(for: track)
        lyricIndex = -2
        updateLyricLine(force: true)
    }

    private func updateLyricLine(force: Bool) {
        guard let lyric else {
            if force {
                NotificationCenter.default.post(name: .ttLyricChanged, object: nil,
                                                userInfo: ["line": "", "next": "",
                                                           "start": 0.0, "end": 0.0])
            }
            return
        }
        // 一律按「歌词自己的时间轴」找行：整盘词要加段起点，用户校准要减掉。
        // 每次从当前位置重算，所以 seek、暂停恢复、切轨都不需要额外补一笔
        let idx = lyric.lineIndex(at: alignedLyricTime(engine.currentTime))
        guard idx != lyricIndex || force else { return }
        lyricIndex = idx
        let current = lyric.line(at: idx)
        let next = lyric.line(at: idx + 1)
        NotificationCenter.default.post(name: .ttLyricChanged, object: nil,
                                        userInfo: [
                                            "line": current?.text ?? "",
                                            "next": next?.text ?? "",
                                            "start": current?.time ?? 0,
                                            "end": next?.time ?? (current?.time ?? 0) + 5,
                                        ])
    }

    // MARK: - 歌词时间校准（F10）

    /// 一次按多少：±0.5 秒（需求定的步进）
    static let lyricShiftStep: Double = 0.5
    /// 上下限：±30 秒。到顶就停，绝不「多按几下偷偷超出」
    static let lyricShiftLimit: Double = 30

    /// 每一曲各自的校准量（秒，正值 = 歌词延后显示）。
    /// 表里按 `identityKey` 取：那是稳定身份，CUE 一轨一号、归档一条目一号，
    /// 所以各轨天生分开存，不需要额外做键。越界的存档值取回来先夹住
    var lyricShift: Double {
        guard let track = currentTrack else { return 0 }
        return Self.clampedLyricShift(lyricShifts[track.identityKey] ?? 0)
    }
    /// 全部曲目的校准表：只进 state.json，一个字都不写回用户的 .lrc
    private var lyricShifts: [String: Double] = [:]

    /// 校准不生效时的一句话（生效时 nil）。入口据此禁用，并把「为什么按了没用」说出来。
    /// 只有「拿到了一份带时间标签的词」才能调：`Lyric.load` 本来就不会交出一份空表，
    /// 没时间标签的 .lrc 与没找到同名文件是同一件事，两句并在一句里说
    var lyricShiftProblem: String? {
        if currentTrack?.isRadio == true {
            return "电台是直播，没有歌词可校准"
        }
        guard currentTrack != nil else { return "现在没有正在播的曲目，没什么可校准" }
        guard lyric != nil else { return "这一首没找到可用歌词（同名 .lrc 里没有带时间标签的句子）" }
        return nil
    }

    /// 这一首能不能校准
    var lyricShiftApplies: Bool { lyricShiftProblem == nil }

    /// 短的那句（状态行与菜单勾后面那点字）：未校准 / 延后 1.0 秒 / 提前 0.5 秒
    var lyricShiftText: String {
        let s = lyricShift
        if abs(s) < 0.001 { return "未校准" }
        return s > 0 ? String(format: "延后 %.1f 秒", s) : String(format: "提前 %.1f 秒", -s)
    }

    /// 完整一句：把文件自带的 offset 与「存在哪儿」也说清楚。offset 是解析时就叠好的一层，
    /// 用户这一侧只再叠自己那一层，两句都摆出来才看不出「重复应用」；
    /// 校准量只进存档，用户的 .lrc 一个字都不动（需求定的边界，界面上也得念得到）
    var lyricShiftDetail: String {
        guard let problem = lyricShiftProblem else {
            var text = "歌词\(lyricShiftText)"
            if let off = lyric?.fileOffset, abs(off) > 0.0001 {
                text += String(format: "（文件自带 %@%.1f 秒，已叠加不重算）",
                               off > 0 ? "+" : "-", abs(off))
            }
            return text + "；上下限 ±" + String(format: "%.0f", Self.lyricShiftLimit)
                + " 秒，只记在播放器里，不改写 .lrc"
        }
        return problem
    }

    /// 加减一次校准量（±0.5 秒那一档走这里）。返回给用户的一句话：
    /// 到边界、没歌词这些「按了不动」的场合都在这句里说清楚
    @discardableResult
    func nudgeLyricShift(_ delta: Double) -> String {
        guard let track = currentTrack, lyricShiftProblem == nil else {
            return lyricShiftProblem ?? "现在没什么可校准的"
        }
        let key = track.identityKey
        let old = lyricShift
        let want = Self.roundLyricShift(old + delta)
        if want == old {
            // 已经顶到边界还往同一个方向按：不动东西，但要说明为什么不动
            let edge = String(format: "%.0f", Self.lyricShiftLimit)
            return old > 0 ? "歌词已经延后到上限 +\(edge) 秒了，再按也不动了"
                          : "歌词已经提前到下限 -\(edge) 秒了，再按也不动了"
        }
        setLyricShift(want, key: key)
        return "歌词\(lyricShiftText)"
    }

    /// 重置这一曲的校准（也用来把「按过头」退回去）
    @discardableResult
    func resetLyricShift() -> String {
        guard let track = currentTrack, lyricShiftProblem == nil else {
            return lyricShiftProblem ?? "现在没什么可校准的"
        }
        guard abs(lyricShift) >= 0.001 else { return "这一首本来就没校准过" }
        setLyricShift(0, key: track.identityKey)
        return "歌词校准已归零（文件自带的 offset 仍然生效）"
    }

    /// 直接把当前曲目调到某个值（自检与「自定义」用）。越界就夹，返回说给用户的那句
    @discardableResult
    func setLyricShift(_ seconds: Double) -> String {
        guard let track = currentTrack else { return "现在没有正在播的曲目，没什么可校准" }
        setLyricShift(Self.roundLyricShift(seconds), key: track.identityKey)
        return "歌词\(lyricShiftText)"
    }

    private func setLyricShift(_ seconds: Double, key: String) {
        if abs(seconds) < 0.001 {
            // 没校准过的曲子不在表里占位：否则整库听一遍就会攒出一堆 0.0
            lyricShifts.removeValue(forKey: key)
        } else {
            lyricShifts[key] = min(max(seconds, -Self.lyricShiftLimit), Self.lyricShiftLimit)
        }
        // 换的是正在播这一首的词：当场把行重算一遍，两处显示立刻跟上
        updateLyricLine(force: true)
        persistNow()
        Diagnostics.log("歌词时间校准 → \(lyricShiftText)（\(key)）")
    }

    /// 0.1 秒一格，免得 0.5 累加出 1.4999999 这种数（界面上要把它写成一句话）
    private static func roundLyricShift(_ v: Double) -> Double {
        min(max((v * 10).rounded() / 10, -lyricShiftLimit), lyricShiftLimit)
    }

    private static func clampedLyricShift(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return min(max(v, -lyricShiftLimit), lyricShiftLimit)
    }

    /// 播放位置 → 歌词时间轴。显示与查行只认这一个换算，两处才可能一模一样
    func alignedLyricTime(_ segmentTime: Double) -> Double {
        lyric?.alignedTime(segmentTime: segmentTime, delay: lyricShift) ?? segmentTime
    }

    /// 自检专用：把内存里那张表抹干净，装作进程刚重启（盘上那份一个字都不动）。
    /// 跟着重查一次当前行：重启后读档之前的界面就该是「没校准过」的那一句，
    /// 不能还挂着上一份表算出来的行
    func resetLyricShiftTable() {
        lyricShifts = [:]
        updateLyricLine(force: true)
    }

    /// 从存档接回校准表：跟 `restoreFromState` 里那一行同一个口径。
    /// 拆出来是为了自检能只重放这一步：整个 restore 会重挂媒体库监控、往列表里补曲目，
    /// 拿它验一句「歌词偏移记得住」会把后面几套的现场也搅了
    @discardableResult
    func reloadLyricShiftsFromState() -> Int {
        lyricShifts = LibraryStore.load().lyricShifts
        // 表回来了就要重查一次当前行：重启后接着放的就是这一曲，不能等心跳那 0.25 秒
        updateLyricLine(force: true)
        return lyricShifts.count
    }


    // MARK: - 播放现场（F06）

    /// 当前现场的可持久化快照。只写稳定身份与段内进度：下标只作为「同一份次序里的位置」
    /// 用一次（条目 UUID 跨不了进程），曲目本身一律靠 identityKey 找回来
    func snapshotScene() -> ResumeScene {
        var s = ResumeScene()
        s.group = persistGroup.archiveValue
        s.wasPlaying = isPlaying
        s.queueKeys = queue.items.map { $0.track.identityKey }
        s.queueExplicit = queue.items.map { $0.explicit }
        s.queueNext = queue.items.map { $0.playNext }
        s.queueIndex = queue.currentIndex ?? 0
        let ids = queue.items.map { $0.id }
        s.historyIndexes = queue.history.compactMap { ids.firstIndex(of: $0) }
        if let cur = queue.current {
            s.trackKey = cur.track.identityKey
            // 电台是直播：没有「接着上次那一秒」可言，写 0、恢复时也不拿它去 seek
            s.position = engine.isRadio ? 0 : max(0, engine.currentTime)
        }
        return s
    }

    /// 立即落盘：状态切换点（暂停/停止/切曲/退出）与自检都走这条，不留延后的尾巴
    func flushScene() {
        sceneFlushPending?.cancel()
        sceneFlushPending = nil
        lastSceneFlush = ProcessInfo.processInfo.systemUptime
        LibraryStore.saveResume(snapshotScene())
    }

    /// 节流落盘：正在播时按 `sceneFlushInterval` 合并，不陪着整库一起写
    private func scheduleSceneFlush() {
        let left = Self.sceneFlushInterval - (ProcessInfo.processInfo.systemUptime - lastSceneFlush)
        if left <= 0 { flushScene(); return }
        guard sceneFlushPending == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sceneFlushPending = nil
            self.flushScene()
        }
        sceneFlushPending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + left, execute: item)
    }

    /// 开关本身是个设置（低频变动），直接走整档存档；现场文件不受它影响
    func setAutoResumePlay(_ on: Bool) {
        guard autoResumePlay != on else { return }
        autoResumePlay = on
        persistNow()
        Diagnostics.log("启动后自动继续播放 → \(on ? "开" : "关")")
    }

    /// 存档写法 → 曲目：先复用内存里已有的对象（元数据、封面都已解析），
    /// 其次按写法重建，解不开才留一条失效占位（身份逐字符相同，队列下标才对得上）
    private func track(forKey key: String, resolver: inout LibraryStore.EntryResolver) -> Track {
        for t in playlist.tracks where t.identityKey == key { return t }
        for t in mainSnapshot where t.identityKey == key { return t }
        if let t = resolver.track(key) {
            // 重建出来的条目没解析过元数据：补一次（标题/时长晚到不打断恢复，列表跟着刷）
            if t.duration == 0, !t.isRadio { MetadataReader.read(t) { [weak self] in
                self?.notifyPlaylistChanged()
            } }
            return t
        }
        return LibraryStore.placeholder(for: key)
    }

    /// 恢复启动路径上那份现场。整档里那一笔只表达歌单页（`viewListID` 是稳定 ID），
    /// 派生页它表达不了，才由现场文件补上——两边都说话时以整档为准，
    /// 否则一份更旧的 `resume.json` 会把用户刚停在的那张歌单顶回 [默认]
    private func restorePlaybackScene(allowSceneGroup: Bool) {
        restorePlaybackScene(LibraryStore.loadResume(), allowSceneGroup: allowSceneGroup)
    }

    /// 恢复指定现场。默认只装到「暂停 + 已恢复进度」，开声与否由
    /// `autoResumePlay`（默认关）与「上次退出前确实在播」共同决定
    func restorePlaybackScene(_ scene: ResumeScene, allowSceneGroup: Bool = true) {
        guard !scene.isEmpty else {
            Diagnostics.log("恢复现场：没有上次的播放记录（首次运行或旧存档）")
            return
        }
        // 浏览页：现场里那一笔比 state.viewListID 新（连非歌单页也记），能用就用它
        if allowSceneGroup, let kind = GroupKind(archiveValue: scene.group), kind != activeGroup {
            switchGroup(kind)
        }
        var resolver = LibraryStore.EntryResolver()
        var items: [QueueItem] = []
        items.reserveCapacity(scene.queueKeys.count)
        for (i, key) in scene.queueKeys.enumerated() {
            // 来路从两份标记合成：「下一首播放」与「稍后播放」在单曲循环里不等价，
            // 恢复后不能把它们并成一种（只看 `explicit` 就会把刚追加的那条当成插队）
            items.append(QueueItem(track: track(forKey: key, resolver: &resolver),
                                   source: scene.source(at: i)))
        }
        // 只有当前曲、没有待播序列的旧现场：拿 trackKey 补一段单条目上下文
        if items.isEmpty, !scene.trackKey.isEmpty {
            items = [QueueItem(track: track(forKey: scene.trackKey, resolver: &resolver),
                               source: .basic)]
        }
        guard !items.isEmpty else { return }
        queue.restoreScene(items: items, cursor: scene.queueIndex, history: scene.historyIndexes)
        notifyQueueChanged()
        syncSelectionToPlaying()
        guard let track = queue.currentTrack else { return }
        // 上一次就停在失效条目上：说清原因、保留其余条目，不碰引擎、不擅自换一首
        if track.missingOnDisk {
            playbackProblem = "上次播放的曲目已不在磁盘上：\(track.url.path)（其余待播条目已保留）"
            Diagnostics.error("恢复现场：\(playbackProblem ?? "")")
            postTrackChange()
            return
        }
        if track.isRadio {
            // 电台只恢复地址：不重连（默认是暂停）、不伪造进度，按播放时才真连上去
            Diagnostics.log("恢复现场（电台）\(track.url.absoluteString)：地址已回来，待重连")
        } else {
            do {
                // 跟 startLoad 同一条次序：先把增益递到引擎再搭装载，
                // 顺序反了恢复后的第一句会按 1.0 出声（响度均衡到第二首才生效）
                applyReplayGains()
                // key 不能省：无缝衔接的交接与预取都靠曲目身份认人，
                // 少了它恢复后的那一曲就没有「这是哪一条」的凭据
                try engine.load(url: track.url, from: track.playStart, to: track.playEnd,
                                key: track.identityKey)
            } catch {
                let problem = AudioFormats.playbackProblem(for: track, error: error)
                track.decodeProblem = problem
                playbackProblem = "上次播放的曲目现在放不起来：\(problem)"
                Diagnostics.error("恢复现场：\(playbackProblem ?? "")")
                postTrackChange()
                return
            }
            // 时长变了（文件被重新编码 / CUE 起止点改了）：夹紧恢复位置，不拿越界秒数去 seek
            let limit = engine.duration
            let position = min(max(0, scene.position), limit)
            engine.seek(seconds: position)
            loadLyric(for: track)
            Diagnostics.log(String(format: "恢复现场 %@ @ %.2f/%.2f s（暂停）",
                                   track.fileName, position, limit))
        }
        postTrackChange()
        guard autoResumePlay, scene.wasPlaying else {
            // 默认恢复为暂停：进度已经就位，此时写一次盘是为了不要把旧现场里
            // 「上次在播」那一笔当成未完成的恢复（下次启动会多一次自动开播）
            setState(playing: false)
            flushScene()
            return
        }
        if track.isRadio {
            loadAndPlayCurrent()      // 电台：按地址重新连直播（没有进度可言）
        } else {
            // 停在结尾附近：从头播。否则一开声就「本曲播完 → 自动下一首」，看着像自己乱跳
            if engine.duration > 0, engine.currentTime >= engine.duration - 0.25 {
                engine.seek(seconds: 0)
            }
            engine.play()
            setState(playing: true)
            startTimeTimer()
            // 自动续播也是从「恢复出来的那一段」开声：下一曲同样要预取
            schedulePrefetch()
        }
    }

    /// 自检用：把「上一进程」的内存痕迹抹干净（不动盘上那份现场），剩下的恢复
    /// 只能从 resume.json 里拿东西 —— 这才是重启走的那条路。真重启进程当然不必手动清，
    /// 自检只能在一个进程里把两个阶段接起来跑
    func resetPlaybackContextForRestore() {
        sceneFlushPending?.cancel()
        sceneFlushPending = nil
        // 不能只 stop()：那会留着上一首的 decoder 与区间，时长/进度都还是旧曲的残值。
        // 真重启时引擎里本来就没有任何曲目，unload() 才是等价状态
        engine.unload()
        queue.reset()
        nextCandidateID = nil
        nextCandidateKey = ""
        isPlaying = false
        playbackProblem = nil
        lastImportProblem = nil
        radioNowPlaying = ""
        lyric = nil
        lyricIndex = -2
        updateLyricLine(force: true)
        consecutiveFailures = 0
        lastSceneFlush = ProcessInfo.processInfo.systemUptime
    }

    // MARK: - 媒体库（F08）

    /// 媒体库页上「为什么没动 / 为什么改不成」的一句话（与导入、播放的说明分开存，
    /// 三句话不能互相顶掉）
    private(set) var libraryProblem: String?

    /// 库里的目录（菜单逐行列出）
    var libraryFolders: [String] { MediaLibrary.shared.folders }
    /// 扫到 / 留着的所有引用（自检与状态行都读它）
    var libraryKeys: [String] { MediaLibrary.shared.keys }
    var libraryScanNote: String { MediaLibrary.shared.scanNote }
    var isLibraryScanning: Bool { MediaLibrary.shared.isScanning }
    var libraryStats: MediaLibrary.ScanStats { MediaLibrary.shared.lastStats }
    /// 当前不在线的目录（外置盘没插上）：这几片下的条目只标失效，不摘掉
    var offlineLibraryFolders: Set<String> { MediaLibrary.shared.offlineFolders }
    /// 库里现在解不开的条数（文件没了或目录还没插回来）
    var libraryMissingCount: Int { MediaLibrary.shared.missingCount }

    /// 菜单第一行那句话：几个目录 / 多少条 / 几处失效 / 在不在扫。与媒体库页统计行
    /// 各说各的口径（这一句要把四个数一起说完），自检直接断言它
    var libraryStatusText: String {
        let lib = MediaLibrary.shared
        guard !lib.folders.isEmpty else { return "媒体库：还没有音乐目录" }
        var text = "媒体库：\(lib.folders.count) 个目录 · \(lib.keys.count) 条引用"
        let missing = lib.missingCount
        if missing > 0 { text += " · \(missing) 条文件找不到" }
        if !lib.offlineFolders.isEmpty {
            text += " · \(lib.offlineFolders.count) 个目录当前不在线"
        }
        if lib.isScanning { text += " · \(lib.scanNote)" }
        return text
    }

    /// 启动时把上次的库接回来：目录 + 条目引用 + 监控，然后后台核对一趟。
    /// 核对走合并扫描：只算差量，绝不重建列表、绝不自动开播（需求点名）。
    /// 应用关了的那段时间里盘上发生了什么只有重扫一次才知道，但扫完只并入库，
    /// 在播的东西、队列、歌单一概不动
    func setupLibrary(folders: [String], keys: [String]) {
        MediaLibrary.shared.restore(folders: folders, keys: keys)
        guard !folders.isEmpty else { return }
        MediaLibrary.shared.startWatching()
        // 上次一个条目都没存下来说明这库还没真正扫过（第一次加完目录就退了），
        // 那句话要说成「首次扫描」，用户才知道第一趟为什么慢
        MediaLibrary.shared.scanAll(initial: keys.isEmpty)
    }

    /// 添加一个音乐目录（菜单「添加目录…」选完路径走这里）。
    /// 成功 = 挂上监控 + 扫这一片；返回 nil 表示成功，否则一句没加成的原因
    @discardableResult
    func addLibraryFolder(_ path: String) -> String? {
        guard let problem = MediaLibrary.shared.addFolder(path) else {
            libraryProblem = nil
            MediaLibrary.shared.startWatching()   // 只挂新那一片，已有的不动
            persistNow()                          // 目录表是设置，当场落盘
            MediaLibrary.shared.scan(folders: [path])
            return nil
        }
        libraryProblem = problem
        Diagnostics.error("媒体库添加目录失败：\(problem)")
        return problem
    }

    /// 移除一个目录：只摘这片引用，不动文件、不动歌单与队列
    @discardableResult
    func removeLibraryFolder(_ path: String) -> String {
        let r = MediaLibrary.shared.removeFolder(path)
        invalidate(.library)
        reloadLibraryPage()
        libraryProblem = nil
        persistNow()
        return r.note
    }

    /// 手动重新扫描（菜单那一行）：全量重扫，只并差量
    func rescanLibrary() {
        libraryProblem = nil
        MediaLibrary.shared.scanAll(initial: libraryKeys.isEmpty)
    }

    /// 取消当前扫描（菜单那一行只在扫着的时候 enabled）：已并进去的部分不回滚
    func cancelLibraryScan() {
        MediaLibrary.shared.cancelScan()
    }

    /// 同步扫完某几个目录（自检用：不等异步那趟）。结果由 .ttLibraryEntriesChanged
    /// 把浏览页与存档带上，这里只补扫完那句状态
    @discardableResult
    func scanLibraryFolders(_ targets: [String]) -> MediaLibrary.Delta {
        libraryProblem = nil
        return MediaLibrary.shared.scanNow(folders: targets)
    }

    /// 自检收摊：把库整个忘掉（摘监控、清目录与引用、连存档那两笔一起清）。
    /// 磁盘上的文件不动，歌曲对象与列表也不动
    func clearLibrary() {
        MediaLibrary.shared.clearAll()
        libraryProblem = nil
        invalidate(.library)
        reloadLibraryPage()
        persistNow()
    }

    /// 退出时把监控摘掉：FSEvents 每条流都是活的 CF 资源，进程要走就自己收，
    /// 不等系统兜（也不留一个能在退出前一秒把扫描排上来的定时器）
    func shutdownLibrary() {
        MediaLibrary.shared.stopWatching()
    }

    /// 重新定位一条失效引用（右键「重新定位文件…」选完新位置走这里）。
    /// 条目身份保留：CUE 还是那一轨、归档还是那一条目，只换容器路径。
    /// 目标位置已经有同一条引用时一条都不改（让用户先决定哪一条算数）。
    /// 正在播的那一段声音不重接：定位修的是引用，重按播放就从新位置出声
    /// - Returns: nil = 改好了；否则一句没改成的原因
    func relocate(key: String, to newPath: String) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: newPath, isDirectory: &isDir),
              !isDir.boolValue else {
            let note = "选中的不是一个文件：\(newPath)"
            libraryProblem = note
            return note
        }
        guard let newKey = MediaLibrary.relabel(key: key, to: newPath) else {
            let note = "这一条不能这么定位：它靠的不是眼前这一个文件的位置"
            libraryProblem = note
            return note
        }
        guard newKey != key else { return nil }    // 位置没变：不动东西，也不报成功
        guard !MediaLibrary.hasCollision(in: [key: newKey], held: archivedKeys()) else {
            let note = "目标位置已经有这一条了：先把已经存在的那条处理掉，再来定位"
            libraryProblem = note
            return note
        }
        let n = applyKeyMap([key: newKey])
        libraryProblem = nil
        Diagnostics.log("重新定位（F08）：\(key) → \(newKey)（一并改了 \(n) 处引用）")
        return nil
    }

    /// 「重新定位」的候选：库里各目录下同名的文件。几个都列出来让用户选，
    /// 绝不替用户担一个（同名不同内容的抓轨文件太常见）
    func relocateCandidates(for key: String) -> [String] {
        MediaLibrary.shared.candidates(sameNameAs: key)
    }

    /// 整片目录换位置的批量替换：一次覆盖库、[默认] 列表、歌单、收藏、历史、队列。
    /// 歧义（两条来源撞到同一条 / 目标本来就在库里）时一条都不改，把话说明白让用户先决定
    /// - Returns: nil = 改好了；否则一句没改成的原因
    func replaceLibraryPrefix(old: String, new: String) -> String? {
        guard MediaLibrary.isDirectoryOnline(new) else {
            let note = "新目录现在不在：\(new)"
            libraryProblem = note
            return note
        }
        let map = MediaLibrary.shared.planPrefixReplacement(old: old, new: new,
                                                           extraKeys: archivedKeys())
        guard !map.isEmpty else {
            let note = "没有引用落在「\((old as NSString).lastPathComponent)」下面，没什么要改的"
            libraryProblem = note
            return note
        }
        let held = archivedKeys()
        guard !MediaLibrary.hasCollision(in: map, held: held) else {
            // 两种撞车分开说：前者是「两个旧位置并到一个新位置」，
            // 后者是「新位置本来就见过」
            let note: String
            if let clash = MediaLibrary.collisions(in: map).values.first {
                // 先算局部变量再拼句：`\((x as NSString).lastPathComponent)` 里那个右括号会被
                // 当成插值的结束，尾巴上的 `.lastPathComponent)」` 就成了原文（踩过一次）
                let name = ((clash.first ?? "") as NSString).lastPathComponent
                note = "有 \(MediaLibrary.collisions(in: map).count) 个旧位置要换成同一条（「"
                    + "\(name)」就是其一）：请逐条重新定位，先决定哪一条算数"
            } else {
                let taken = MediaLibrary.targetsAlreadyInLibrary(map, keys: held)
                let name = ((taken.first ?? "") as NSString).lastPathComponent
                note = "新位置里有 \(taken.count) 条本来就在库里（比如「\(name)」）：不猜哪一条算数，"
                    + "请先处理重复"
            }
            libraryProblem = note
            return note
        }
        let n = applyKeyMap(map)
        // 目录表也要跟着换：留着旧路径，下一趟扫描会把老位置重新当新增，
        // 同一片歌就变成两条。移除→添加→扫新位置，走的就是那两条现成的规矩
        _ = removeLibraryFolder(old)      // 旧位置已经没有引用，摘掉它不丢东西
        if let problem = addLibraryFolder(new) {
            libraryProblem = problem
            return problem
        }
        Diagnostics.log("目录前缀批量替换（F08）：\(old) → \(new)，改了 \(n) 处引用")
        return nil
    }

    /// 现在被任何档案引用的全部键：库 + [默认] 留档 + 正在看的列表 + 队列 +
    /// 收藏 / 两份历史 + 所有歌单。批量替换必须一次覆盖它们，
    /// 分两次改就会出现「歌单跟了、收藏没跟」
    private func archivedKeys() -> [String] {
        var all = MediaLibrary.shared.keys
        all.append(contentsOf: mainSnapshot.map { $0.identityKey })
        all.append(contentsOf: playlist.tracks.map { $0.identityKey })
        all.append(contentsOf: queue.items.map { $0.track.identityKey })
        all.append(contentsOf: groups.recentKeys + groups.favoriteKeys + groups.recentRadioKeys)
        for id in userLists.ids { all.append(contentsOf: userLists.keys(of: id)) }
        return all
    }

    /// 一把覆盖所有档案的键替换。只换引用，不删不挪磁盘上的东西：
    /// 队列只换曲目对象不换条目（条目 id 是游标与历史的凭据），
    /// 浏览列表只换那一行的对象，次序与选中行都不动
    /// - Returns: 实际动过的引用条数（库那一份算在内）
    @discardableResult
    private func applyKeyMap(_ map: [String: String]) -> Int {
        guard !map.isEmpty else { return 0 }
        var resolver = LibraryStore.EntryResolver()
        // 解不开的新位置（新目录在但中间那个文件还没到位）也照样留一条失效引用，
        // 不能让歌单里那一行因为改了个写法就静默消失
        func resolve(_ key: String) -> Track {
            resolver.track(key) ?? LibraryStore.placeholder(for: key)
        }
        var changed = 0
        // 1) 库自己那一份：换完再扫就对得上新位置，不会当成新增
        for (old, new) in map where MediaLibrary.shared.replaceKey(old, with: new) { changed += 1 }
        // 2) [默认] 留档与正在看的浏览列表
        mainSnapshot = mainSnapshot.map { t in map[t.identityKey].map(resolve) ?? t }
        changed += playlist.replaceTracks { t in
            guard let new = map[t.identityKey] else { return nil }
            return resolve(new)
        }
        // 3) 待播队列
        changed += queue.replaceTracks(map, resolve: resolve)
        // 4) 纯键档案：收藏 / 两份历史 / 每张歌单
        groups.replaceKeys(map)
        changed += userLists.replaceKeys(map)
        // 5) 派生页缓存整体作废（它们按键缓存），媒体库页当场重画
        derivedCache.removeAll()
        reloadLibraryPage()
        notifyQueueChanged()
        postTrackChange()
        persistNow()
        flushScene()      // 现场文件里那份键也是引用，不能等 5 s 节流
        return changed
    }

    /// 媒体库那一页重新装一次内容；只在看这一页时才动浏览列表，
    /// 别的页面切过去时自然会重算
    private func reloadLibraryPage() {
        guard activeGroup == .library else { return }
        reloadActiveGroup()
        notifyPlaylistChanged()
    }

    @objc private func libraryEntriesChanged(_ note: Notification) {
        // 缓存整体作废：盘上少了一个文件，歌单页那些「按盘上事实标的失效标记」也跟着变。
        // 只重画媒体库页的话，用户在看的那张歌单永远显不出「缺失」，也就点不到「重新定位」
        derivedCache.removeAll()
        reloadActiveGroup()
        notifyPlaylistChanged()
        scheduleSave()    // 条目引用也是库的档案，别等下一次切组才落盘
    }

    // MARK: - 持久化

    func restoreFromState() {
        let state = LibraryStore.load()
        setMode(PlayMode(rawValue: state.playMode) ?? .listLoop)
        volume = state.volume
        isMuted = state.muted
        applyVolume()
        engine.setEQEnabled(state.eqEnabled)
        engine.setPreGain(state.eqPreGain)
        // 旧存档可能是 6 段，补齐到当前段数
        let gains = state.eqGains + Array(repeating: Float(0),
                                         count: max(0, AudioEngine.eqBandCount - state.eqGains.count))
        for (i, g) in gains.prefix(AudioEngine.eqBandCount).enumerated() {
            engine.setEQGain(band: i, gain: g)
        }
        // 电台档案（F11）：台名与分类必须先回来——`Track(radio:)` 构造时就拿它。旧档没这几项
        // 就是谁都没起过名字，回到按地址显示（正常迁移）
        radioStations.restore(aliases: state.radioAliases, categories: state.radioCategories,
                              assigned: state.radioAssignments)
        // 存档条目可能是普通音频路径，也可能是 `cue路径#track=N`（分轨重新解析即可拿到起止点）
        let restored = LibraryStore.tracks(fromArchiveEntries: state.trackPaths)
        groups.restore(recent: state.recentKeys, favorites: state.favoriteKeys,
                       recentRadios: state.recentRadioKeys)
        // 歌单先恢复：左栏那一列、派生页缓存都指着它，晚一步就会拿空表算布局
        // 旧档没这一项 = 一张歌单都没建过，正常迁移
        userLists.restore(state.userLists)
        // 媒体库（F08）：目录表与条目引用先回来，监控挂上，后台核对一趟。
        // 排在现场恢复之前：resume 里那些键要能在媒体库页对上号；
        // 核对完只并入库，不会替用户开播也不会往队列里插队
        setupLibrary(folders: state.libraryFolders, keys: state.libraryKeys)
        autoResumePlay = state.autoResumePlay
        // 无缝衔接（F01）：旧档缺这一项时按需求默认开
        gaplessPlay = state.gaplessPlay
        engine.setGaplessEnabled(state.gaplessPlay)
        // 响度均衡（F02）：默认关。旧档没这几项时不能升级一下就替用户改了音量
        replayGainMode = ReplayGainMode(rawValue: state.replayGainMode) ?? .off
        replayGainPreamp = min(max(state.replayGainPreamp, -12), 12)
        replayGainPeakLimit = state.replayGainPeakLimit
        // 睡眠淡出（F09）：旧档缺这一项时按需求默认开。只恢复这个开关，不恢复倒计时本身
        sleepFadeEnabled = state.sleepFade
        sleepTimer.fadeSeconds = state.sleepFade ? Self.sleepFadeSeconds : 0
        // 歌词时间校准（F10）：旧档没这一项就是空表（谁都没校准过）。
        // 只接表，不在这里动当前曲目：校准量按身份取，取的时候才夹边界
        lyricShifts = state.lyricShifts
        // 输出设备（F07）：只存 UID。选的那台现在不在就先不接，
        // 记下原因，等设备接回时由监听对账扳回来（设置本身不动）
        outputDeviceUID = state.outputDeviceUID
        if !outputDeviceUID.isEmpty {
            if let d = OutputDevices.resolve(outputDeviceUID) {
                pinnedDeviceName = d.name
                engine.restoreOutputDevice(uid: outputDeviceUID)
            } else {
                pinnedDeviceName = state.outputDeviceName
                outputProblem = "固定的输出设备「\(state.outputDeviceName)」当前不可用（没接上？）"
                    + "，暂走系统默认；插回后会自动固定过去"
                engine.restoreOutputDevice(uid: "")
            }
        }
        activeGroup = .main
        // 上次停在某张歌单：按稳定 ID 找回来（那张没了就留在 [默认]，switchGroup 里守住）
        if !state.viewListID.isEmpty { switchGroup(.playlist(state.viewListID)) }
        if !restored.isEmpty {
            _ = addTracks(restored)
        }
        // 播放现场最后恢复：曲目对象与浏览页都到位了才谈得上「接着哪一首、播到哪一秒」。
        // 在看的歌单页整档里已经有稳定 ID 那一笔（跟 persistNow 一起写），以它为准；
        // 只有它没说话（停在 [默认]/收藏/最近/电台这些派生页）才让现场文件里的页面接管
        restorePlaybackScene(allowSceneGroup: state.viewListID.isEmpty)
    }

    func persistNow() {
        var state = LibraryStore.load()
        // identityKey 同时是存档写法：普通轨是文件路径，CUE 轨是 `cue路径#track=N`。
        // 停在派生组时写的必须是 [默认] 组的留档，否则一次切组就把用户的列表冲了。
        // 搜索态也一样：写的是「进入搜索前那一页」的留档，命中表永远不该落盘
        let mainTracks = persistGroup == .main ? playlist.tracks : mainSnapshot
        state.trackPaths = mainTracks.map { $0.identityKey }
        state.recentKeys = groups.recentKeys
        state.favoriteKeys = groups.favoriteKeys
        state.recentRadioKeys = groups.recentRadioKeys
        state.userLists = userLists.snapshot
        // 媒体库（F08）：目录表与扫出来的引用都存下来，
        // 外置盘没插上时也能列出「上次看到有什么」（标失效）
        state.libraryFolders = MediaLibrary.shared.folders
        state.libraryKeys = MediaLibrary.shared.keys
        state.viewListID = persistListID ?? ""
        // 自动续播与无缝开关都是设置（低频），跟整档一起走；进度那种高频的在 resume.json
        state.autoResumePlay = autoResumePlay
        state.gaplessPlay = gaplessPlay
        state.replayGainMode = replayGainMode.rawValue
        state.replayGainPreamp = replayGainPreamp
        state.replayGainPeakLimit = replayGainPeakLimit
        state.sleepFade = sleepFadeEnabled
        // 歌词校准（F10）：整张表随整档走。归零的那一首已从表里摘掉，不在这堆里占位
        state.lyricShifts = lyricShifts
        // 电台档案（F11）：台名与分类都按地址存，重启后同一家台还是那个名字；
        // 分类本身是应用内状态，不靠 m3u 带回
        state.radioAliases = radioStations.snapshotAliases
        state.radioCategories = radioStations.snapshotCategories
        state.radioAssignments = radioStations.snapshotAssigned
        // 输出设备：UID 与实际设备名一起存。设备已经不在了还能把名字说出来，
        // 不至于提示里只剩一串 BuiltInHeadphoneOutputDevice
        state.outputDeviceUID = outputDeviceUID
        state.outputDeviceName = engine.outputDevice?.name ?? pinnedDeviceName
        state.playMode = playMode.rawValue
        state.volume = volume
        state.muted = isMuted
        state.eqEnabled = !engine.eq.bypass
        state.eqGains = (0..<AudioEngine.eqBandCount).map { engine.eqGain(band: $0) }
        state.eqPreGain = engine.preGain
        LibraryStore.save(state)
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.persistNow()
        }
    }
}
