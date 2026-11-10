import Foundation

// MARK: - CUE 分轨表

/// 一张 CUE 里的单曲信息：整盘压成一份音频镜像（WAV/FLAC）时，靠它切出每一首的起止
struct CueTrackInfo {
    /// TRACK 序号（CUE 里写 01、02…）
    let number: Int
    /// 来源的 .cue 文件（存档时靠它 + 轨号还原分轨，不写死起止点）
    let sheetURL: URL
    let title: String
    let performer: String
    /// 所属音频镜像的绝对路径
    let fileURL: URL
    /// 本段在镜像里的起点（秒）
    let start: Double
    /// 下一轨起点；同一镜像的最后一轨为 nil（放到文件结尾）
    let nextStart: Double?

    /// 本段时长；末段在拿到镜像总时长前为 nil
    var duration: Double? {
        guard let next = nextStart else { return nil }
        return max(0, next - start)
    }
}

/// CUE 分轨表（.cue 文本文件）
struct CueSheet {
    let url: URL
    let albumTitle: String
    let albumPerformer: String
    let tracks: [CueTrackInfo]

    /// 这张盘引用的所有音频镜像
    var audioURLs: [URL] {
        var seen = Set<String>()
        return tracks.compactMap { seen.insert($0.fileURL.path).inserted ? $0.fileURL : nil }
    }

    /// 至少有一轨的镜像在磁盘上才算可用（否则加进来也是哑条目）
    var hasUsableAudio: Bool {
        let fm = FileManager.default
        return tracks.contains { fm.fileExists(atPath: $0.fileURL.path) }
    }
}

// MARK: - 解析

extension CueSheet {
    /// 从磁盘读取并解析（自动做编码回退：UTF-8 → GB18030 → Big5 → Latin1，
    /// 国内抓轨的 cue 大量是 GBK/GB2312 存盘，直接按 UTF-8 读会得到乱码标题）
    static func parse(url: URL) -> CueSheet? {
        guard let data = try? Data(contentsOf: url), let text = decode(data) else { return nil }
        return parse(text: text, sheetURL: url)
    }

    static func parse(text raw: String, sheetURL: URL) -> CueSheet? {
        let base = sheetURL.deletingLastPathComponent()
        var albumTitle = ""
        var albumPerformer = ""
        var currentFile: URL?
        var draft: Draft?
        var entries: [CueTrackInfo] = []

        func flush() {
            guard let d = draft, let file = d.file, let start = d.index01 ?? d.index00 else {
                draft = nil
                return
            }
            entries.append(CueTrackInfo(number: d.number, sheetURL: sheetURL, title: d.title,
                                        performer: d.performer, fileURL: file,
                                        start: start, nextStart: nil))
            draft = nil
        }

        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            let cmd = (parts.first.map(String.init) ?? "").uppercased()
            let rest = parts.count > 1 ? String(parts[1]) : ""
            switch cmd {
            case "REM":
                break                                   // 注释/扩展信息（GENRE、REPLAYGAIN…）不影响分轨
            case "FILE":
                flush()
                if let name = quotedValue(rest) { currentFile = resolve(name, in: base) }
            case "TITLE":
                guard let v = quotedValue(rest) else { continue }
                if draft != nil { draft?.title = v } else if albumTitle.isEmpty { albumTitle = v }
            case "PERFORMER":
                guard let v = quotedValue(rest) else { continue }
                if draft != nil { draft?.performer = v } else if albumPerformer.isEmpty { albumPerformer = v }
            case "TRACK":
                flush()
                let num = Int(rest.split(separator: " ").first.map(String.init) ?? "")
                    ?? (entries.count + 1)
                draft = Draft(number: num, file: currentFile)
            case "INDEX":
                let fields = rest.split(separator: " ").map(String.init)
                guard fields.count >= 2, let idx = Int(fields[0]),
                      let seconds = parseCueTime(fields[1]) else { continue }
                if idx == 1 {
                    if draft?.index01 == nil { draft?.index01 = seconds }
                } else if idx == 0 {
                    if draft?.index00 == nil { draft?.index00 = seconds }
                }
            default:
                break
            }
        }
        flush()

        let valid = entries.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        guard !valid.isEmpty else { return nil }
        return CueSheet(url: sheetURL, albumTitle: albumTitle, albumPerformer: albumPerformer,
                        tracks: fillEndTimes(valid))
    }

    /// 同一份镜像内的下一轨起点即为本轨终点（跨镜像不相连，末轨留 nil 由引擎放到文件尾）
    private static func fillEndTimes(_ entries: [CueTrackInfo]) -> [CueTrackInfo] {
        let byFile = Dictionary(grouping: entries) { $0.fileURL.path }
        var result: [CueTrackInfo] = []
        for (_, group) in byFile {
            let sorted = group.sorted { $0.start < $1.start }
            for (i, t) in sorted.enumerated() {
                let next = i + 1 < sorted.count ? sorted[i + 1].start : nil
                result.append(CueTrackInfo(number: t.number, sheetURL: t.sheetURL, title: t.title,
                                           performer: t.performer, fileURL: t.fileURL,
                                           start: t.start, nextStart: next))
            }
        }
        // 保持 cue 里的书写顺序（多镜像盘也能按轨号排）
        return result.sorted {
            if $0.fileURL.path != $1.fileURL.path { return $0.fileURL.path < $1.fileURL.path }
            return $0.start < $1.start
        }
    }

    /// 正在累积的一条 TRACK
    private struct Draft {
        var number: Int
        var title = ""
        var performer = ""
        var file: URL?
        var index01: Double?
        var index00: Double?
    }

    /// MM:SS:FF，FF 是 1/75 秒（CD 帧）
    static func parseCueTime(_ text: String) -> Double? {
        let f = text.split(separator: ":").map(String.init)
        guard f.count == 3, let m = Double(f[0]), let s = Double(f[1]), let frame = Double(f[2])
        else { return nil }
        guard m >= 0, s >= 0, frame >= 0 else { return nil }
        return m * 60 + s + frame / 75
    }

    /// 取引号内的值；没有引号时取到下一个空格（有些抓轨软件不写引号）
    private static func quotedValue(_ rest: String) -> String? {
        if let first = rest.firstIndex(of: "\"") {
            let after = rest[rest.index(after: first)...]
            if let last = after.lastIndex(of: "\"") {
                return String(after[..<last])
            }
            return String(after)
        }
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed.split(separator: " ").first.map(String.init)
    }

    private static func resolve(_ name: String, in base: URL) -> URL {
        if name.hasPrefix("/") { return URL(fileURLWithPath: name) }
        return base.appendingPathComponent(name)
    }

    /// 编码回退：UTF-8 是严格解码（非法字节直接失败），因此可以放心排在最前
    static func decode(_ data: Data) -> String? {
        func nsEncoding(_ cf: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(cf.rawValue)))
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        for cf in [CFStringEncodings.GB_18030_2000, .big5] {
            if let text = String(data: data, encoding: nsEncoding(cf)) { return text }
        }
        return String(data: data, encoding: .isoLatin1)
    }
}
