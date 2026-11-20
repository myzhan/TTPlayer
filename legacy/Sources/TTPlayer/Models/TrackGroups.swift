import Foundation

/// 播放列表左栏的列表组（皮肤里那一列名字）。
/// `[默认]` 是可编辑的真实列表（存档 trackPaths）；`媒体库` 是扫出来的目录里有什么（F08）；
/// `网络电台` 是 `[默认]` 里电台地址的投影，
/// `最近听的台` / `最近播放` / `我的收藏` 是他们各自档案算出来的派生列表；
/// `playlist` 那一种是用户自己建的歌单（可以有很多张，见 UserPlaylists，requirements F04）。
/// 身份不能再用整型下标：歌单页多出来之后「第几行」会随着创建/删除漂移，
/// 只有枚举本身 + 歌单的稳定 ID 能既当缓存的键又写进存档。
enum GroupKind: Hashable {
    case main
    /// 媒体库：内容不另外存一份，直接读 MediaLibrary 扫出来的引用（这一页不能删行，
    /// 盘上有什么就是什么，想少收几片目录得去菜单里移除目录）
    case library
    /// 网络电台：内容不是另存一份地址，而是 `[默认]` 里电台那几条的投影（删一处就没了）
    case radio
    /// 最近听的台：台是地址，后来被删出列表也还能从这里回听
    case recentRadio
    case recent
    case favorites
    /// 自建歌单：关联值是歌单自己的稳定 ID，改名、增删条目、拖动排序都不动它
    case playlist(String)
    /// 电台分类（F11）：`[默认]` 里电台地址按 `RadioStations` 的归属分组投影。
    /// `RadioStations.uncategorizedID` 那一格是「未分类电台」，它是默认入口、永远在，
    /// 不是一张真分类 —— 删分类只是把台送回这一格，一条地址都不丢
    case radioCategory(String)
    /// 全局搜索的临时页（F05）：内容是「命中表」，不是一份档案。
    /// 它不摆进左栏（没有稳定身份可以记，下次启动看见一张空的「搜索结果」没意义），
    /// 退出搜索就回到进入之前那一页
    case search

    /// 六个固定页（左栏永远按这个次序排在最前面，电台分类与歌单页跟在它们后面）
    static let fixedPages: [GroupKind] = [.main, .library, .radio, .recentRadio, .recent, .favorites]

    /// 不用用户创建也一定会有的行：固定页 + 未分类电台（F11 的兜底入口）。
    /// 自检与布局都读这一份，免得两处各算各的“应该有六行”。
    /// 搜索临时页不在任何一份名单里：它不是一个能被点开的页
    static let alwaysPages: [GroupKind] = fixedPages + [.radioCategory(RadioStations.uncategorizedID)]

    /// 左栏当前的次序：固定页 + 未分类与各个电台分类 + 按创建顺序排的歌单页。
    /// 「未分类」这一行不由用户创建，所以在这里补在前面：它是所有台的兜底入口
    static func layout(playlists: [UserPlaylist], categories: [RadioCategory]) -> [GroupKind] {
        alwaysPages + categories.map { .radioCategory($0.id) }
            + playlists.map { .playlist($0.id) }
    }

    var name: String {
        switch self {
        case .main: return "[默认]"
        case .library: return "媒体库"
        case .radio: return "网络电台"
        case .recentRadio: return "最近听的台"
        case .recent: return "最近播放"
        case .favorites: return "我的收藏"
        case .playlist(let id):
            // 存档里记着一张已经被删掉的歌单时也要有句话，不能让左栏出现一个空名字条目
            return UserPlaylists.shared.name(of: id) ?? "歌单已不存在"
        case .radioCategory(let id):
            // 同理：分类被删掉但存档还停在它上面时，这一行也得有名字（未分类有固定名字）
            return RadioStations.shared.name(of: id) ?? "分类已不存在"
        case .search: return "搜索结果"
        }
    }

    /// 派生组：内容由投影或档案算出来，用户不能往里塞别的歌（加歌/拖入都会先切回 [默认]）。
    /// 搜索临时页也算派生：它的命中表是从各页算出来的，本身不留内容
    var isDerived: Bool { self != .main }

    /// 这一页的条目是谁存的：歌单页归 UserPlaylists，媒体库页归 MediaLibrary，
    /// TrackGroups 那份档案都管不到
    var isUserPlaylist: Bool { if case .playlist = self { return true }; return false }

    /// 电台那一类页面（全部台 / 各个分类）：列的都是 `[默认]` 里的电台地址投影，
    /// 删一处就真没了，不存在「这一页自己存一份地址」
    var isRadioPage: Bool {
        if self == .radio { return true }
        if case .radioCategory = self { return true }
        return false
    }

    /// 失效引用要不要留在表里：歌单页与媒体库页都是「看得见才修得了」的页，
    /// 文件走了也得占一行，用户才能决定重新定位还是删掉；
    /// 收藏 / 历史那一类是「能列多少算多少」，盘上没这东西就掉队
    var keepsMissingEntries: Bool { isUserPlaylist || self == .library }

    /// 存档写法（F06「当前浏览组」要能跨进程记住）：固定页用名字，歌单页用
    /// `playlist:<稳定 ID>`。存 ID 不存名字：改了名也找得回来；认不出来的一律回 [默认]
    var archiveValue: String {
        switch self {
        case .main: return "main"
        case .search: return "main"      // 临时页不跨进程：写盘时由 `persistGroup` 换成真实那一页
        case .library: return "library"
        case .radio: return "radio"
        case .recentRadio: return "recentRadio"
        case .recent: return "recent"
        case .favorites: return "favorites"
        case .playlist(let id): return "playlist:\(id)"
        case .radioCategory(let id): return "radioCat:\(id)"
        }
    }

    /// 解不开就返回 nil（旧档没这一项、或那张歌单已经被删了），由调用处决定回落
    init?(archiveValue: String) {
        switch archiveValue {
        case "main": self = .main
        case "library": self = .library
        case "radio": self = .radio
        case "recentRadio": self = .recentRadio
        case "recent": self = .recent
        case "favorites": self = .favorites
        default:
            if archiveValue.hasPrefix("playlist:") {
                self = .playlist(String(archiveValue.dropFirst("playlist:".count)))
            } else if archiveValue.hasPrefix("radioCat:") {
                self = .radioCategory(String(archiveValue.dropFirst("radioCat:".count)))
            } else {
                return nil
            }
        }
    }

    /// 列表空着时表格中央那句提示；[默认] 保持原版那样什么都不画
    var emptyHint: String? {
        switch self {
        case .main: return nil
        case .library: return "菜单「媒体库」→ 添加音乐目录，扫到的歌就在这一页"
        case .radio: return "工具条「电台」键添加地址，或拖入带 http 行的 m3u"
        case .recentRadio: return "还没有听过的台"
        case .recent: return "还没有播放记录"
        case .favorites: return "右键曲目 → 加入收藏，或按 ⌘D"
        case .playlist: return "右键曲目 → 加入歌单，或右键这里导入 m3u"
        case .radioCategory(let id): return id == RadioStations.uncategorizedID
            ? "工具条「电台」键添加地址；右键台 → 移入分类"
            : "右键电台 → 移入分类，把常听的台归到这一页"
        case .search: return "没有搜到：换个关键字，或按 Esc 收起搜索"
        }
    }
}

/// 最近听的台 / 最近播放 / 我的收藏的档案。
/// 只存 identityKey（与存档同一套写法：普通轨是文件路径，CUE 轨是 `分轨表#track=N`，台是完整地址），
/// 切组时再按需还原成 Track —— 这样 CUE 分轨、移动过目录的整张盘都能对上号。
final class TrackGroups {
    static let shared = TrackGroups()

    /// 最近播放留多少首：再多也没人回看，白占存档
    static let recentLimit = 50
    /// 最近听的台留多少个：台一般个位数，一长串里也没人会翻到底
    static let recentRadioLimit = 20

    /// 最近播过的键，最近的在最前
    private(set) var recentKeys: [String] = []
    /// 收藏的键，按加入顺序排（不按播放顺序）
    private(set) var favoriteKeys: [String] = []
    /// 最近听过的台的地址，最近的在最前
    private(set) var recentRadioKeys: [String] = []

    func restore(recent: [String], favorites: [String], recentRadios: [String]) {
        recentKeys = recent
        favoriteKeys = favorites
        recentRadioKeys = recentRadios
    }

    /// 开播就记一笔：已经在历史里的先摘掉再放回最前，不重复堆积
    func recordPlay(_ track: Track) {
        Self.touch(track.identityKey, into: &recentKeys, limit: Self.recentLimit)
    }

    /// 听过的台另记一份：电台不像本地文件那样删了就找不回来，地址本身就是全部内容
    func recordRadioPlay(_ track: Track) {
        guard track.isRadio else { return }
        Self.touch(track.identityKey, into: &recentRadioKeys, limit: Self.recentRadioLimit)
    }

    /// 「最近的挪到最前，多余的从尾巴上剪掉」——三份档案都是这一条规矩
    private static func touch(_ key: String, into list: inout [String], limit: Int) {
        list.removeAll { $0 == key }
        list.insert(key, at: 0)
        if list.count > limit {
            list.removeLast(list.count - limit)
        }
    }

    func isFavorite(_ track: Track) -> Bool { favoriteKeys.contains(track.identityKey) }

    /// 返回操作后的收藏状态（true = 已在收藏里）
    @discardableResult
    func toggleFavorite(_ track: Track) -> Bool {
        let key = track.identityKey
        if let i = favoriteKeys.firstIndex(of: key) {
            favoriteKeys.remove(at: i)
            return false
        }
        favoriteKeys.append(key)
        return true
    }

    func remove(keys: [String], from kind: GroupKind) {
        let gone = Set(keys)
        switch kind {
        case .recent: recentKeys.removeAll { gone.contains($0) }
        case .recentRadio: recentRadioKeys.removeAll { gone.contains($0) }
        case .favorites: favoriteKeys.removeAll { gone.contains($0) }
        // [默认]、「网络电台」与各个电台分类页由调用处动真实列表（投影组里删台就是真删台）；
        // 媒体库页根本不接受删行（调用处先拦住），歌单页的条目在 UserPlaylists 那边，
        // 调用处会先按 isUserPlaylist 分走。
        // 搜索临时页在这里也走不到：调用处删的是命中表里那几首「本来存着它们的地方」
        // （见 PlayerController.removeSearchHits）
        case .main, .library, .radio, .radioCategory, .playlist, .search: return
        }
    }

    func clear(_ kind: GroupKind) {
        switch kind {
        case .recent: recentKeys.removeAll()
        case .recentRadio: recentRadioKeys.removeAll()
        case .favorites: favoriteKeys.removeAll()
        case .main, .library, .radio, .radioCategory, .playlist, .search: return
        }
    }

    /// 重新定位（F08）：把这些键换成新位置的写法，次序不动。
    /// 收藏与两份历史都是纯键档案，换完就能继续对上号
    func replaceKeys(_ map: [String: String]) {
        func swap(_ list: inout [String]) {
            for i in list.indices { list[i] = map[list[i]] ?? list[i] }
        }
        swap(&recentKeys)
        swap(&favoriteKeys)
        swap(&recentRadioKeys)
    }

    /// 派生组的键序列（[默认]、「网络电台」与电台分类页的内容在 PlayerController 那边，这里管不到；
    /// 媒体库页读 MediaLibrary，歌单页读 UserPlaylists，同理都不在这里）
    func entries(for kind: GroupKind) -> [String] {
        switch kind {
        case .recent: return recentKeys
        case .recentRadio: return recentRadioKeys
        case .favorites: return favoriteKeys
        case .main, .library, .radio, .radioCategory, .playlist, .search: return []
        }
    }
}
