import Foundation

/// 一行歌词
struct LyricLine {
    let time: Double   // 起始时间（秒）
    let text: String
}

/// LRC 歌词解析与查找
struct Lyric {
    private(set) var lines: [LyricLine] = []

    var isEmpty: Bool { lines.isEmpty }

    /// 当前时间对应的歌词行下标（无匹配返回 -1，用于显示“纯音乐/无歌词”）
    func lineIndex(at time: Double) -> Int {
        guard !lines.isEmpty else { return -1 }
        if time < lines[0].time { return -1 }
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].time <= time { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func line(at index: Int) -> LyricLine? {
        lines.indices.contains(index) ? lines[index] : nil
    }

    /// 解析 LRC 文本；支持一行多个时间标签、[mm:ss]、[mm:ss.xx]、[mm:ss:xx]
    static func parse(_ text: String) -> Lyric {
        var result: [LyricLine] = []
        let tagPattern = try! NSRegularExpression(pattern: "\\[(\\d{1,2}):(\\d{2})(?:[.:](\\d{1,3}))?\\]")
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line.hasPrefix("[") else { continue }
            let ns = line as NSString
            let matches = tagPattern.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            // 歌词正文 = 去掉所有时间标签后的部分
            var content = line
            for m in matches.reversed() {
                content.removeSubrange(Range(m.range, in: content)!)
            }
            content = content.trimmingCharacters(in: .whitespaces)
            if content.isEmpty { continue }
            for m in matches {
                let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let ss = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var frac = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let s = ns.substring(with: m.range(at: 3))
                    // 两位小数 = 百分之一秒，三位 = 千分之一秒
                    frac = (Double(s) ?? 0) / pow(10, Double(s.count))
                }
                let time = mm * 60 + ss + frac
                result.append(LyricLine(time: max(0, time), text: content))
            }
        }
        result.sort { $0.time < $1.time }
        return Lyric(lines: result)
    }

    /// 查找并加载歌词。优先级：同名 .lrc → 同目录里名字对得上但不完全一致的
    /// （`01 - 歌名.flac` 对 `歌名.lrc`、`歌手 - 歌名.lrc` 对 `歌名.flac`），
    /// 后端只认“唯一命中”：拿不准就算没歌词，宁缺毋滥（配错歌词比没有更难受）
    static func load(for track: Track) -> Lyric? {
        for url in candidateFiles(for: track.url) {
            if let lyric = parse(file: url) { return lyric }
        }
        return nil
    }

    /// 存在可用的歌词文件（同名或同目录唯一命中）
    static func exists(for audioURL: URL) -> Bool {
        !candidateFiles(for: audioURL).isEmpty
    }

    /// 候选歌词文件（只有命中才返回，不保证能解析）
    static func candidateFiles(for audioURL: URL) -> [URL] {
        let same = audioURL.deletingPathExtension().appendingPathExtension("lrc")
        if FileManager.default.fileExists(atPath: same.path) { return [same] }
        return fuzzyMatch(for: audioURL).map { [$0] } ?? []
    }

    // MARK: - 同目录歌词索引（与 CoverArt 同一套思路：一个目录只列一次）

    private static var dirIndex: [String: [String: URL]] = [:]
    private static let dirCacheLimit = 512

    private static func fuzzyMatch(for audioURL: URL) -> URL? {
        let dir = audioURL.deletingLastPathComponent()
        let index = lrcIndex(in: dir)
        guard !index.isEmpty else { return nil }
        let want = normalized(audioURL.deletingPathExtension().lastPathComponent)
        guard !want.isEmpty else { return nil }
        if let exact = index[want] { return exact }
        // 包含关系的候选（「歌手 - 歌名」↔「歌名」），只认唯一命中
        let hits = index.filter { $0.key.contains(want) || want.contains($0.key) }
        return hits.count == 1 ? hits.first?.value : nil
    }

    private static func lrcIndex(in dir: URL) -> [String: URL] {
        let key = dir.path
        if let hit = dirIndex[key] { return hit }
        var map: [String: URL] = [:]
        if let names = try? FileManager.default.contentsOfDirectory(atPath: key) {
            for name in names where name.lowercased().hasSuffix(".lrc") {
                let url = dir.appendingPathComponent(name)
                let base = normalized((name as NSString).deletingPathExtension)
                guard !base.isEmpty else { continue }
                // 归一化名撞车时留在文件名靠前那份，保证每次结果一致
                if let old = map[base], old.lastPathComponent < url.lastPathComponent { continue }
                map[base] = url
            }
        }
        if dirIndex.count >= dirCacheLimit { dirIndex.removeAll() }
        dirIndex[key] = map
        return map
    }

    /// 归一化文件名：去掉开头的音轨号，只留字母/数字/汉字（空格、横杠、下划线不参与比较）
    private static func normalized(_ name: String) -> String {
        var s = name.lowercased()
        s = s.replacingOccurrences(of: "^\\d{1,3}\\s*[-._ ]\\s*", with: "",
                                   options: .regularExpression)
        return s.filter { $0.isLetter || $0.isNumber }
    }

    /// 按 UTF-8 → GB18030 → ISO-8859-1 回退解析一份 .lrc
    private static func parse(file url: URL) -> Lyric? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let gb18030 = String.Encoding(rawValue:
            CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        for encoding in [String.Encoding.utf8, gb18030, .isoLatin1] {
            if let text = String(data: data, encoding: encoding), text.contains("[") {
                let lyric = Lyric.parse(text)
                if !lyric.isEmpty { return lyric }
            }
        }
        return nil
    }
}
