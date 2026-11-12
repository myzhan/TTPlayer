import Foundation

/// 即时搜索与筛选的条件（requirements F05）。
///
/// 它只是「哪些行看得见」的一份描述：不写进 `Playlist`，不进播放队列，也不进存档 ——
/// 筛选态一旦落到数据层，清除搜索之后就再也还原不回用户原来那张完整的列表了。
/// 行号的换算（结果行 ↔ 原列表行）在 `PlaylistView`，这里只管判定。
struct TrackFilter: Equatable {
    /// 关键字：标题/艺术家/专辑/文件名任一命中（大小写不敏感）
    var keyword = ""
    /// 勾选的格式档（取自 `Track.filterFormat`）；空集 = 不限格式
    var formats: Set<String> = []

    static let none = TrackFilter()

    init(keyword: String = "", formats: Set<String> = []) {
        self.keyword = keyword
        self.formats = formats
    }

    /// 去掉首尾空白后的关键字：只敲空格不算要搜空格
    var keywordText: String { keyword.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isActive: Bool { !keywordText.isEmpty || !formats.isEmpty }
    /// 一句话说明当前条件（日志与界面文案用）
    var summary: String {
        var parts: [String] = []
        if !keywordText.isEmpty { parts.append("「\(keywordText)」") }
        if !formats.isEmpty { parts.append(formats.sorted().joined(separator: "/")) }
        return parts.isEmpty ? "全部" : parts.joined(separator: " + ")
    }

    /// 建一次判定器：关键字归一化只做一遍，不能一万行各做一遍
    func matcher() -> Matcher { Matcher(keyword: keywordText, formats: formats) }

    /// 一条曲目在当前条件下是否可见（单次判定，循环里请直接用 `matcher()`）
    func matches(_ track: Track) -> Bool { matcher().hit(track) }

    /// 命中的**原列表**行号（`Playlist.tracks` 的下标）。
    /// 没有条件时返回空数组，由调用处走恒等映射：一万行的列表不该每次刷新都白建一万个数
    func visibleRows(in tracks: [Track]) -> [Int] {
        let hit = matcher()
        guard !hit.isEmpty else { return [] }
        var rows: [Int] = []
        rows.reserveCapacity(tracks.count)
        for (i, track) in tracks.enumerated() where hit.hit(track) { rows.append(i) }
        return rows
    }

    /// 当前列表里真出现过的格式档（不把用户手里没有的后缀摆到菜单上）
    static func formatOptions(in tracks: [Track]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for t in tracks where seen.insert(t.filterFormat).inserted { out.append(t.filterFormat) }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

extension TrackFilter {
    /// 一轮筛选判定共用一份比较器：先夹格式（一次集合查询），再看文本（四个字段命中即过）
    struct Matcher {
        let keyword: String
        let formats: Set<String>
        /// 纯 ASCII 关键字的小写字节；含非 ASCII 时为 nil（走字符串包含判定）
        private let asciiNeedle: [UInt8]?
        /// 关键字里有没有「分大小写的字符」：全是中文/数字/符号时，大小写折叠不可能多匹配
        /// 任何东西，精确包含就是全部，不必再补一遍 NSString 折叠扫描（一万行能省一半）
        private let needCaseFold: Bool

        init(keyword: String, formats: Set<String>) {
            self.keyword = keyword
            self.formats = formats
            asciiNeedle = keyword.utf8.allSatisfy { $0 < 0x80 }
                ? Array(keyword.lowercased().utf8) : nil
            needCaseFold = keyword.lowercased() != keyword || keyword.uppercased() != keyword
        }

        var isEmpty: Bool { keyword.isEmpty && formats.isEmpty }

        func hit(_ track: Track) -> Bool {
            if !formats.isEmpty, !formats.contains(track.filterFormat) { return false }
            guard !keyword.isEmpty else { return true }
            // 次序有讲究：标题/艺术家是元数据里最短、最容易命中的，文件名要现取路径末段，放最后
            return hit(track.title) || hit(track.artist) || hit(track.album) || hit(track.fileName)
        }

        /// 单个字段的包含判定（大小写不敏感）
        func hit(_ text: String) -> Bool {
            if let needle = asciiNeedle { return Self.asciiFoldedContains(text, needle) }
            // 关键字里有中文等非 ASCII：不分大小写的（纯中文、纯数字）精确包含就是全部；
            // 带字母的写法（“混排TT静”）才要在精确包含没中时再走一遍大小写兜底
            if !needCaseFold { return text.contains(keyword) }
            return text.contains(keyword)
                || text.range(of: keyword, options: .caseInsensitive, locale: nil) != nil
        }

        /// ASCII 大小写不敏感的字节扫描：一万行 × 四个字段每敲一个字都要跑一遍，
        /// 拿 `text.lowercased()` 这类写法会先建四万个字符串再比，输入就卡在这里。
        /// `withCString` 在 UTF-8 存储上是零拷贝；针全为 ASCII，而 UTF-8 多字节序列里
        /// 不含 <0x80 的字节，所以中文串里不会误命中英文针。
        private static func asciiFoldedContains(_ text: String, _ needle: [UInt8]) -> Bool {
            guard !needle.isEmpty else { return true }
            let n = needle.count
            return text.withCString { ptr in
                let h = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
                var i = 0
                while true {
                    if h[i] == 0 { return false }              // 走到串尾还没匹配上
                    if lower(h[i]) == needle[0] {
                        var k = 1
                        while k < n {
                            if h[i + k] == 0 { return false }
                            if lower(h[i + k]) != needle[k] { break }
                            k += 1
                        }
                        if k == n { return true }
                    }
                    i += 1
                }
            }
        }

        private static func lower(_ b: UInt8) -> UInt8 {
            (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z")) ? b + 32 : b
        }
    }
}
