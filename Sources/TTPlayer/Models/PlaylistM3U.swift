import Foundation

/// 自建歌单的 M3U / M3U8 读写（requirements F04）。
///
/// 一套行写法，四种来路都能保住身份：
/// - 普通文件 → 绝对路径（第三方播放器也认这种）
/// - 电台 → 完整 http/https 地址
/// - 精确选中的一条 CUE 分轨 → `<分轨表路径>#track=<轨号>`
/// - 归档里的一个条目 → `file://…#archive-entry=<条目>`
///
/// 后两种是 TTPlayer 扩展写法：`#` 后面那一段别的播放器读不懂，会把整行当成一个
/// 找不到的文件跳过（导出去给别人听时这部分会掉），但 TTPlayer 自己读回来仍然精确到
/// 用户选的那一轨 / 那一个条目 —— 不会静默丢失，也不会展开成用户没选的曲目。
/// 普通文件那一行 identityKey 就等于 `url.path`，所以「导出 → 导入」的往返是逐字符保真的，
/// 指向已经不在盘上的文件的行也照样写、照样读回来（失效引用要能看见，不能悄悄蒸发）。
/// 唯一的歧义边界：本地路径里正好带 `#track=` 会被当成分轨扩展写法（第三方 m3u 也一样歧义，
/// 真碰到了就走 TTPlayer 自己的存档而不是 m3u）。
enum PlaylistM3U {
    /// 扩展格式标记行：读到它就确认这份 m3u 是按上面那套写法导出的
    static let marker = "#EXT-X-TTPLAYER:1"
    /// 给人看的兼容说明（跟着写进导出文件，用户拿别的编辑器也知道那两类行是什么）
    static let compatibilityNote = "# TTPlayer 扩展：带 #track= 的行是分轨表里精确的一轨，"
        + "带 #archive-entry= 的行是归档里的一个条目；其它播放器读不懂这两类行"

    /// 导入结果：键的次序（歌单里就是行次序）+ 哪些行指向不在盘上的东西
    struct Imported {
        private(set) var keys: [String] = []
        /// 与 keys 里同一批写法，单列出来是为了给用户一句「有几条暂时找不到文件」
        private(set) var missing: [String] = []
        /// 读不懂的行数（不是路径、不是电台、也不是上面两类扩展写法）
        private(set) var unreadable = 0
        /// 已经收下的键：嵌套 / 循环引用会反复把同一首递过来，歌单里只留一行
        private var seen = Set<String>()

        mutating func keep(_ key: String, exists: Bool) {
            guard seen.insert(key).inserted else { return }
            keys.append(key)
            if !exists { missing.append(key) }
        }
        mutating func fail() { unreadable += 1 }
    }

    // MARK: - 导出

    /// 一行该写什么：四种来路都直接用 identityKey（普通文件的 identityKey 就是绝对路径）
    static func line(for track: Track) -> String { track.identityKey }

    /// 按键导出。`names` 是键 → 显示名（拿来写 #EXTINF，缺失的条目没有名字可写就留空）
    static func export(keys: [String], names: [String: String], durations: [String: Double],
                       to url: URL) -> Bool {
        var text = "#EXTM3U\n" + marker + "\n" + compatibilityNote + "\n"
        for key in keys {
            let name = names[key] ?? ""
            let dur = durations[key] ?? 0
            text += "#EXTINF:\(dur > 0 ? Int(dur.rounded()) : -1),\(name)\n"
            text += key + "\n"
        }
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    /// 用界面上正在显示的那批曲目导出（键从曲目现算，保证与存档写法一致）
    static func export(_ tracks: [Track], to url: URL) -> Bool {
        var names: [String: String] = [:]
        var durations: [String: Double] = [:]
        for t in tracks {
            names[t.identityKey] = t.artist.isEmpty ? t.title : "\(t.artist) - \(t.title)"
            durations[t.identityKey] = t.duration
        }
        return export(keys: tracks.map { $0.identityKey }, names: names, durations: durations, to: url)
    }

    // MARK: - 导入

    /// 读一个 m3u/m3u8 当成一张歌单。nil = 这个文件连文本都读不出来
    static func `import`(_ url: URL) -> Imported? {
        guard let text = LibraryStore.readText(url) else { return nil }
        var reader = Reader()
        reader.absorbPlaylist(url: url, text: text)
        return reader.result
    }

    /// 一次导入的内部状态：`visited` 是循环引用防护（a.m3u 引 b.m3u 引 a.m3u 不能没完）
    private struct Reader {
        var result = Imported()
        var visited = Set<String>()

        /// 展开一份歌单文件：相对路径按它所在目录解析，嵌套的歌单递归进来
        mutating func absorbPlaylist(url: URL, text: String? = nil) {
            guard visited.insert(url.path).inserted else { return }
            guard let text = text ?? LibraryStore.readText(url) else {
                result.fail()
                return
            }
            let base = url.deletingLastPathComponent()
            for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                // 注释行（含 #EXTINF）一律跳过：这里只关心身份，显示名跟着曲目自己走
                if line.hasPrefix("#") { continue }
                absorbLine(line, base: base)
            }
        }

        mutating func absorbLine(_ line: String, base: URL) {
            // 电台：地址本身就是全部内容
            if let radio = RadioURL.explicit(line) {
                result.keep(radio.absoluteString, exists: true)
                return
            }
            // TTPlayer 扩展写法：精确的一条 CUE 分轨 / 归档里的一个条目，原样留着就是身份
            if line.contains(LibraryStore.cueArchiveMarker) || line.contains("#archive-entry=") {
                result.keep(line, exists: LibraryStore.entryExists(line))
                return
            }
            let path = (line.hasPrefix("/") || line.hasPrefix("file://"))
                ? line : base.appendingPathComponent(line).path
            // 带 scheme 的写法（file://…）走 URL(string:)，裸路径必须走 fileURLWithPath：
            // 后者才不会把文件名里的 `#` 当 fragment 截掉、也不会被空格弄解不出来
            let fileURL = path.hasPrefix("file")
                ? (URL(string: path) ?? URL(fileURLWithPath: path))
                : URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir) else {
                // 文件不在盘上：引用照样留下（表格里标成失效），不静默丢行。
                // 但扩展名本来就不可播的行（第三方 m3u 里夹的备注、封面、cue 之外的文本）
                // 永远也放不出来，留下只是一条删了还会回来的假失效条目，算读不懂
                if AudioFormats.isPlaylist(fileURL) || AudioFormats.isArchive(fileURL)
                    || AudioFormats.isCue(fileURL) || AudioFormats.isScannable(fileURL) {
                    result.keep(fileURL.path, exists: false)
                } else {
                    result.fail()
                }
                return
            }
            let ext = fileURL.pathExtension.lowercased()
            if AudioFormats.isPlaylist(fileURL) {
                absorbPlaylist(url: fileURL)
            } else if isDir.boolValue || ext == LibraryStore.cueExtension
                || AudioFormats.isArchive(fileURL) {
                // 目录 / 整张分轨表 / 整个归档：交给既有的展开规则，展开成一串 identityKey
                for key in LibraryStore.tracks(in: [fileURL]).map({ $0.identityKey }) {
                    result.keep(key, exists: true)
                }
            } else if AudioFormats.isPlayable(fileURL) {
                result.keep(fileURL.path, exists: true)
            } else {
                result.fail()
            }
        }
    }
}
