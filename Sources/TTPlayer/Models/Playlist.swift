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

/// 播放列表
final class Playlist {
    private(set) var tracks: [Track] = []
    private(set) var currentIndex: Int?
    /// 随机播放时的播放顺序记忆
    private var shuffleHistory: [Int] = []

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
        return tracks.count - 1
    }

    @discardableResult
    func add(contentsOf newTracks: [Track]) -> [Int] {
        var indexes: [Int] = []
        for t in newTracks { indexes.append(add(t)) }
        return indexes
    }

    func remove(at indexes: IndexSet) {
        // 从后往前删，保持索引有效
        for i in indexes.sorted(by: >) {
            guard tracks.indices.contains(i) else { continue }
            tracks.remove(at: i)
            if let cur = currentIndex {
                if i == cur {
                    // 删除的是当前曲：保持同一位置，自然指向后一首；越界则清空
                    currentIndex = tracks.indices.contains(i) ? i : nil
                } else if i < cur {
                    currentIndex = cur - 1
                }
            }
            shuffleHistory.removeAll { $0 == i }
            shuffleHistory = shuffleHistory.map { $0 > i ? $0 - 1 : $0 }
        }
    }

    func removeAll() {
        tracks.removeAll()
        currentIndex = nil
        shuffleHistory.removeAll()
    }

    func track(at index: Int) -> Track? {
        tracks.indices.contains(index) ? tracks[index] : nil
    }

    func index(of track: Track) -> Int? {
        tracks.firstIndex { $0 === track }
    }

    // MARK: - 模式切换

    /// 直接选中某曲（双击列表）
    func select(_ index: Int) -> Track? {
        guard tracks.indices.contains(index) else { return nil }
        currentIndex = index
        if modeIsRandom { recordShuffle(index) }
        return tracks[index]
    }

    /// 下一曲；列表播完（顺序模式）返回 nil
    func advance(for mode: PlayMode) -> Track? {
        guard !tracks.isEmpty else { return nil }
        switch mode {
        case .singleLoop:
            guard let i = currentIndex else { return select(0) }
            return tracks[i]
        case .order:
            guard let i = currentIndex else { return select(0) }
            let next = i + 1
            return next < tracks.count ? select(next) : nil
        case .listLoop:
            guard let i = currentIndex else { return select(0) }
            return select((i + 1) % tracks.count)
        case .random:
            return select(pickRandomIndex())
        }
    }

    /// 上一曲
    func retreat(for mode: PlayMode) -> Track? {
        guard !tracks.isEmpty else { return nil }
        switch mode {
        case .random:
            // 随机模式回退到上一个播放过的曲目
            if shuffleHistory.count >= 2 {
                shuffleHistory.removeLast()
                let i = shuffleHistory.last ?? 0
                return select(i)
            }
            return select(pickRandomIndex())
        default:
            guard let i = currentIndex else { return select(0) }
            let prev = i - 1
            return prev >= 0 ? select(prev) : (mode == .listLoop ? select(tracks.count - 1) : nil)
        }
    }

    func firstTrack() -> Track? { tracks.isEmpty ? nil : select(0) }

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

    /// 从 from+1 开始环形查找标题/艺术家/文件名包含 keyword 的曲目标引
    func indexOfNext(matching keyword: String, after from: Int?) -> Int? {
        guard !keyword.isEmpty, !tracks.isEmpty else { return nil }
        let start = (from ?? -1) + 1
        for offset in 0..<tracks.count {
            let i = (start + offset) % tracks.count
            let t = tracks[i]
            if t.title.localizedCaseInsensitiveContains(keyword)
                || t.artist.localizedCaseInsensitiveContains(keyword)
                || t.fileName.localizedCaseInsensitiveContains(keyword) {
                return i
            }
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
        shuffleHistory.removeAll()
    }

    private func recordShuffle(_ index: Int) {
        if shuffleHistory.last != index { shuffleHistory.append(index) }
    }

    var modeIsRandom = false

    private func pickRandomIndex() -> Int {
        guard tracks.count > 1 else { return 0 }
        var candidate: Int
        var guardCount = 0
        repeat {
            candidate = Int.random(in: 0..<tracks.count)
            guardCount += 1
        } while candidate == currentIndex && guardCount < 16
        return candidate
    }
}
