import Foundation

/// 播放列表左栏的列表组（皮肤里那一列名字）。
/// `[默认]` 是可编辑的真实列表（存档 trackPaths）；`网络电台` 是它里面电台地址的投影，
/// `最近听的台` / `最近播放` / `我的收藏` 是他们各自档案算出来的派生列表。
enum GroupKind: Int, CaseIterable {
    case main = 0
    /// 网络电台：内容不是另存一份地址，而是 `[默认]` 里电台那几条的投影（删一处就没了）
    case radio = 1
    /// 最近听的台：台是地址，后来被删出列表也还能从这里回听
    case recentRadio = 2
    case recent = 3
    case favorites = 4

    var name: String {
        switch self {
        case .main: return "[默认]"
        case .radio: return "网络电台"
        case .recentRadio: return "最近听的台"
        case .recent: return "最近播放"
        case .favorites: return "我的收藏"
        }
    }

    /// 派生组：内容由投影或档案算出来，用户不能往里塞别的歌（加歌/拖入都会先切回 [默认]）
    var isDerived: Bool { self != .main }

    /// 列表空着时表格中央那句提示；[默认] 保持原版那样什么都不画
    var emptyHint: String? {
        switch self {
        case .main: return nil
        case .radio: return "工具条「电台」键添加地址，或拖入带 http 行的 m3u"
        case .recentRadio: return "还没有听过的台"
        case .recent: return "还没有播放记录"
        case .favorites: return "右键曲目 → 加入收藏，或按 ⌘D"
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
        // [默认] 与「网络电台」由调用处动真实列表（投影组里删台就是真删台）
        case .main, .radio: return
        }
    }

    func clear(_ kind: GroupKind) {
        switch kind {
        case .recent: recentKeys.removeAll()
        case .recentRadio: recentRadioKeys.removeAll()
        case .favorites: favoriteKeys.removeAll()
        case .main, .radio: return
        }
    }

    /// 派生组的键序列（[默认] 与「网络电台」的内容在 PlayerController 那边，这里管不到）
    func entries(for kind: GroupKind) -> [String] {
        switch kind {
        case .recent: return recentKeys
        case .recentRadio: return recentRadioKeys
        case .favorites: return favoriteKeys
        case .main, .radio: return []
        }
    }
}
