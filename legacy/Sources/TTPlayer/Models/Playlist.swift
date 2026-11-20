import Foundation

/// 播放模式（对应千千静听的“播放方式”）
enum PlayMode: Int, CaseIterable {
    case order      // 顺序播放：播完列表停止
    case singleLoop // 单曲循环
    case listLoop   // 列表循环
    case random     // 随机播放

    var displayName: String {
        switch self {
        case .order: return "顺序播放"
        case .singleLoop: return "单曲循环"
        case .listLoop: return "列表循环"
        case .random: return "随机播放"
        }
    }

    /// 标题栏小图标上显示的单字
    var badgeText: String {
        switch self {
        case .order: return "顺"
        case .singleLoop: return "单"
        case .listLoop: return "循"
        case .random: return "随"
        }
    }

    /// 传输条模式键用的图标（用户反馈：不要用单字，换回常规图标）
    var symbolName: String {
        switch self {
        case .order: return "arrow.right"
        case .singleLoop: return "repeat.1"
        case .listLoop: return "repeat"
        case .random: return "shuffle"
        }
    }
}

/// 浏览列表：只负责「表格里列着什么、选中哪一行」。
/// 接下来播谁是 `PlayQueue` 的事 —— 切组、筛选、排序都不该动到正在播放的音频，
/// 所以这两份状态必须分开存（见 requirements F03）。
final class Playlist {
    private(set) var tracks: [Track] = []
    /// 表格里选中的行；不等于「正在播的那首」（正在播的可能已经被删出这张表）
    private(set) var currentIndex: Int?
    /// 结构版本号：加行/删行/整页换内容/排序都 +1。
    /// 筛选的可见行映射靠它判断「要不要立刻重算」：元数据晚到不涨这个号，
    /// 一万行导入时几百条 ttPlaylistChanged 不能各扫一遍全表（见 PlaylistView）
    private(set) var revision = 0

    var currentTrack: Track? {
        guard let i = currentIndex, tracks.indices.contains(i) else { return nil }
        return tracks[i]
    }

    var isEmpty: Bool { tracks.isEmpty }
    var count: Int { tracks.count }

    var totalDuration: Double { tracks.reduce(0) { $0 + $1.duration } }

    @discardableResult
    func add(_ track: Track) -> Int {
        tracks.append(track)
        revision += 1
        return tracks.count - 1
    }

    @discardableResult
    func add(contentsOf newTracks: [Track]) -> [Int] {
        var indexes: [Int] = []
        for t in newTracks { indexes.append(add(t)) }
        return indexes
    }

    func remove(at indexes: IndexSet) {
        revision += 1
        // 从后往前删，保持索引有效
        for i in indexes.sorted(by: >) {
            guard tracks.indices.contains(i) else { continue }
            tracks.remove(at: i)
            if let cur = currentIndex {
                if i == cur {
                    // 删除的是选中行：保持同一位置，自然指向后一首；越界则清空
                    currentIndex = tracks.indices.contains(i) ? i : nil
                } else if i < cur {
                    currentIndex = cur - 1
                }
            }
        }
    }

    func removeAll() {
        tracks.removeAll()
        currentIndex = nil
        revision += 1
    }

    /// 逐行换对象（F08 重新定位）：次序与选中行都不动，只把命中的那几行换成
    /// 「同一个身份、新的位置」。revision 要涨：筛选映射按行内容算，位置换了就得重算
    /// - Returns: 换掉了几行
    @discardableResult
    func replaceTracks(_ swap: (Track) -> Track?) -> Int {
        var n = 0
        for i in tracks.indices {
            guard let next = swap(tracks[i]), next !== tracks[i] else { continue }
            tracks[i] = next
            n += 1
        }
        if n > 0 { revision += 1 }     // 选中行还在原来那一格，不用动 currentIndex
        return n
    }

    func track(at index: Int) -> Track? {
        tracks.indices.contains(index) ? tracks[index] : nil
    }

    func index(of track: Track) -> Int? {
        tracks.firstIndex { $0 === track }
    }

    /// 按稳定身份找行：切组、派生组还原出来的 Track 未必是同一个对象，
    /// 但 identityKey 一定是同一首（归档/CUE/电台各自都有自己的写法）
    func index(ofKey key: String) -> Int? {
        tracks.firstIndex { $0.identityKey == key }
    }

    // MARK: - 选中

    /// 直接选中某行（双击列表、查找定位）
    func select(_ index: Int) -> Track? {
        guard tracks.indices.contains(index) else { return nil }
        currentIndex = index
        return tracks[index]
    }

    /// 取消选中：正在播的那首已经被删出这张表时，宁可一行都不高亮，
    /// 也不能把旁边那行标成「当前播放」
    func clearSelection() {
        currentIndex = nil
    }

    // MARK: - 列表文件导入导出（列表工具条的“列表”菜单）

    /// 导出为 m3u（绝对路径 / 电台完整地址，UTF-8）
    /// CUE 分轨只写一次 .cue 路径（导入时重新展开成整张盘的轨次），不写重复的镜像行
    func exportAsM3U(to url: URL) -> Bool {
        var text = "#EXTM3U\n"
        var writtenSheets = Set<String>()
        for t in tracks {
            if let cue = t.cue {
                guard writtenSheets.insert(cue.sheetURL.path).inserted else { continue }
                let album = t.album.isEmpty ? cue.sheetURL.deletingPathExtension().lastPathComponent : t.album
                text += "#EXTINF:-1,\(album)\n" + cue.sheetURL.path + "\n"
            } else if t.isRadio {
                // 电台写地址，不写 path（path 只到主机那一段，台名另写在 EXTINF 里）
                text += "#EXTINF:-1,\(t.title)\n" + t.url.absoluteString + "\n"
            } else {
                text += "#EXTINF:\(Int(t.duration.rounded())),"
                    + "\(t.artist.isEmpty ? t.title : "\(t.artist) - \(t.title)")\n"
                text += t.url.path + "\n"
            }
        }
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    // MARK: - 查找（列表工具条的“查找”按钮）

    /// 从 from+1 开始环形查找标题/艺术家/专辑/文件名包含 keyword 的曲目标引。
    /// 判定与搜索框共用一份 `TrackFilter`：两套「什么算命中」不能各说各话
    func indexOfNext(matching keyword: String, after from: Int?) -> Int? {
        let hit = TrackFilter(keyword: keyword).matcher()
        guard !hit.isEmpty, !tracks.isEmpty else { return nil }
        let start = (from ?? -1) + 1
        for offset in 0..<tracks.count {
            let i = (start + offset) % tracks.count
            if hit.hit(tracks[i]) { return i }
        }
        return nil
    }

    // MARK: - 排序（列表工具条的“排序”按钮）

    enum SortKey: String, CaseIterable {
        case title = "标题"
        case artist = "艺术家"
        case album = "专辑"
        case duration = "时长"
        case fileName = "文件名"
    }

    /// 按指定字段排序。无当前曲目时照样排序；有当前曲目时排序后仍指向同一个 Track。
    func sort(by key: SortKey, ascending: Bool) {
        guard tracks.count > 1 else { return }
        revision += 1
        let cur = currentTrack
        func compare(_ a: Track, _ b: Track) -> ComparisonResult {
            switch key {
            case .title: return a.title.localizedStandardCompare(b.title)
            case .artist: return a.artist.localizedStandardCompare(b.artist)
            case .album: return a.album.localizedStandardCompare(b.album)
            case .duration: return a.duration < b.duration ? .orderedAscending
                : (a.duration > b.duration ? .orderedDescending : .orderedSame)
            case .fileName: return a.fileName.localizedStandardCompare(b.fileName)
            }
        }
        let sorted = tracks.sorted {
            let r = compare($0, $1)
            // 相等时用文件名做稳定次级键，避免相等元素每次排序结果抖动
            if r == .orderedSame { return $0.url.path < $1.url.path }
            return ascending ? r == .orderedAscending : r == .orderedDescending
        }
        tracks = sorted
        if let cur { currentIndex = sorted.firstIndex { $0 === cur } }
    }
}
