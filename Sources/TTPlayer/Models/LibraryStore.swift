import Foundation

/// 应用持久化状态：播放列表文件路径、音量、播放模式、均衡器等
/// 存放于 ~/Library/Application Support/TTPlayer/state.json
struct AppState: Codable {
    /// 默认均衡器增益（与 AudioEngine 段数一致）
    static let defaultGains: [Float] = Array(repeating: 0, count: 10)

    var trackPaths: [String] = []
    var playMode: Int = PlayMode.listLoop.rawValue
    var volume: Float = 0.8
    var muted: Bool = false
    var eqEnabled: Bool = true
    var eqGains: [Float] = AppState.defaultGains
    /// 均衡器前置放大（dB）
    var eqPreGain: Float = 0
    var eqPresetName: String = "默认"
    /// 旧版单窗几何（"x,y,w,h"），三窗停靠改版后只用作首次迁移
    var windowFrame: String = ""
    var listVisible: Bool = true
    /// 停靠组几何（"left,top,width,height"，top 是组顶边 y）
    var dockGeometry: String = ""
    /// 均衡器面板是否停靠显示
    var eqVisible: Bool = false
    /// 半透明玻璃（壳层透出桌面 + 鼠标驱动的镜面柔光）
    var glass: Bool = true
    /// 透明度（0=全透明 1=不透明），默认 0.15
    var transparency: Double = 0.15
    /// 歌词秀窗口几何（"x,y,w,h"）
    var lyricFrame: String = ""
    /// 皮肤布局版本：改版后旧的窗口宽度/位置不再适用，靠它一次性丢弃重排
    var skinLayout: Int = 0
    /// 最近播放的键（最近的在最前），与 trackPaths 同一套写法
    var recentKeys: [String] = []
    /// 收藏的键，按加入顺序
    var favoriteKeys: [String] = []
    /// 最近听过的台的地址（最近的在最前）：台被删出列表也还留在这里
    var recentRadioKeys: [String] = []

    // MARK: 宽容解码
    // 逐字段 decodeIfPresent：旧版 state.json 缺少新增字段时不能整档解码失败，
    // 否则 LibraryStore.load() 会回退到空默认值，把播放列表与设置一起丢掉。
    private enum CodingKeys: String, CodingKey {
        case trackPaths, playMode, volume, muted, eqEnabled, eqGains, eqPreGain
        case eqPresetName, windowFrame, listVisible, dockGeometry, eqVisible, lyricFrame
        case skinLayout, recentKeys, favoriteKeys, recentRadioKeys, glass, transparency
    }

    /// 显式写默认构造：定义了 init(from:) 后 struct 的成员构造不再合成
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trackPaths = try c.decodeIfPresent([String].self, forKey: .trackPaths) ?? []
        playMode = try c.decodeIfPresent(Int.self, forKey: .playMode) ?? PlayMode.listLoop.rawValue
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 0.8
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        eqEnabled = try c.decodeIfPresent(Bool.self, forKey: .eqEnabled) ?? true
        eqGains = try c.decodeIfPresent([Float].self, forKey: .eqGains) ?? AppState.defaultGains
        eqPreGain = try c.decodeIfPresent(Float.self, forKey: .eqPreGain) ?? 0
        eqPresetName = try c.decodeIfPresent(String.self, forKey: .eqPresetName) ?? "默认"
        windowFrame = try c.decodeIfPresent(String.self, forKey: .windowFrame) ?? ""
        listVisible = try c.decodeIfPresent(Bool.self, forKey: .listVisible) ?? true
        dockGeometry = try c.decodeIfPresent(String.self, forKey: .dockGeometry) ?? ""
        eqVisible = try c.decodeIfPresent(Bool.self, forKey: .eqVisible) ?? false
        glass = try c.decodeIfPresent(Bool.self, forKey: .glass) ?? true
        transparency = try c.decodeIfPresent(Double.self, forKey: .transparency) ?? 0.15
        lyricFrame = try c.decodeIfPresent(String.self, forKey: .lyricFrame) ?? ""
        skinLayout = try c.decodeIfPresent(Int.self, forKey: .skinLayout) ?? 0
        recentKeys = try c.decodeIfPresent([String].self, forKey: .recentKeys) ?? []
        favoriteKeys = try c.decodeIfPresent([String].self, forKey: .favoriteKeys) ?? []
        recentRadioKeys = try c.decodeIfPresent([String].self, forKey: .recentRadioKeys) ?? []
    }
}

enum LibraryStore {
    /// 可播扩展名的唯一来源是 AudioFormats（向 CoreAudio 现场问出来的）
    static var supportedExtensions: Set<String> { AudioFormats.scanExtensions }
    /// 分轨表（单独统计，命中时把一份镜像拆成多首）
    static let cueExtension = AudioFormats.cueExtension

    private static var stateURL: URL {
        let env = ProcessInfo.processInfo.environment
        // 自检模式把存档落在测试目录里，避免跑一次自检就覆盖用户的播放列表与窗口布局
        if env["TTPLAYER_SELFTEST"] == "1", let dir = env["TTPLAYER_TESTDIR"], !dir.isEmpty {
            let base = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            return base.appendingPathComponent("state.json")
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TTPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    /// 自检每次从干净存档起跑：上一轮留下的面板开关、窗口位置会让首批断言时灵时不灵
    static func resetSelfTestStateIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["TTPLAYER_SELFTEST"] == "1" else { return }
        try? FileManager.default.removeItem(at: stateURL)
    }

    static func load() -> AppState {
        if let data = try? Data(contentsOf: stateURL),
           let state = try? JSONDecoder().decode(AppState.self, from: data) {
            return state
        }
        return AppState()
    }

    static func save(_ state: AppState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    /// 按扩展名收集一批 URL 里的文件（文件夹递归，跳过隐藏文件），按文件名自然序排列
    static func files(in urls: [URL], extensions: Set<String>) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles]) {
                    for case let fileURL as URL in enumerator
                    where extensions.contains(fileURL.pathExtension.lowercased()) {
                        result.append(fileURL)
                    }
                }
            } else if extensions.contains(url.pathExtension.lowercased()) {
                result.append(url)
            }
        }
        return result.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    // MARK: - 成批入表（含 CUE 分轨与 m3u 歌单）

    /// 存档里 CUE 轨的写法：`<cue 路径>#track=<轨号>`
    static let cueArchiveMarker = "#track="

    /// 一次导入的结果：入表曲目 + 被挡在门外的文件（附一句人话原因）
    struct ImportResult {
        var tracks: [Track] = []
        var skipped: [(url: URL, reason: String)] = []

        /// 给日志/显示区用的一句话
        var skipNote: String? {
            guard !skipped.isEmpty else { return nil }
            let head = skipped.first!
            if skipped.count == 1 { return head.reason }
            return "\(head.url.lastPathComponent)：\(head.reason)（另有 \(skipped.count - 1) 个文件未入表）"
        }
    }

    /// 展开一批拖入/选中的 URL（文件、文件夹、.cue、m3u 歌单都能接）
    static func importURLs(_ urls: [URL]) -> ImportResult {
        var importer = Importer()
        for url in urls { importer.absorb(url) }
        return importer.result
    }

    /// 只要曲目、不管被跳过了什么（存档还原、m3u 行展开走这里）
    static func tracks(in urls: [URL]) -> [Track] {
        importURLs(urls).tracks
    }

    /// 每个来源（拖入的一个 URL）内部自己定序，来源之间按拖入顺序拼接：
    /// - 文件夹：按专辑名 + 镜像内偏移排（一张盘的轨次不能乱）
    /// - m3u 歌单：保留歌单里的行顺序（用户自己排好的次序）
    /// - 单个 cue / 音频：按轨次或就地一首
    struct Importer {
        var result = ImportResult()
        /// 拖进来的目录不能因为里面有个 .jpg 就报告“放不了”，只有单文件被挡才算拒收
        var directURLs = Set<String>()
        var sheetCache: [String: CueSheet?] = [:]
        var covered = Set<String>()          // 已按分轨展开的镜像，不再整盘入表
        var seenKeys = Set<String>()
        let fm = FileManager.default

        mutating func absorb(_ url: URL) {
            directURLs.insert(url.path)
            absorbSource(url)
        }

        /// cue 只算一次（一份盘的多轨共用一个来源键）
        private mutating func key(for track: Track, via sheet: URL? = nil) -> String {
            if let sheet { return "sheet:\(sheet.path):\(track.identityKey)" }
            return track.identityKey
        }

        private mutating func emit(_ track: Track, via sheet: URL? = nil) {
            guard seenKeys.insert(key(for: track, via: sheet)).inserted else { return }
            result.tracks.append(track)
        }

        mutating func absorbSource(_ url: URL) {
            // 电台地址：没有文件可查，直接入表（磁盘检查会把它们全挡在外面）
            if RadioURL.isRadio(url) {
                emit(Track(radio: url))
                return
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                reject(url, reason: "文件已不在磁盘上")
                return
            }
            if isDir.boolValue { absorbDirectory(url); return }
            let ext = url.pathExtension.lowercased()
            if AudioFormats.isPlaylist(url) { absorbPlaylist(url) }
            else if ext == cueExtension { absorbCue(url) }
            else if AudioFormats.isArchive(url) { absorbArchive(url) }
            else if AudioFormats.isPlayable(url) { absorbAudio(url) }
            else { reject(url, reason: AudioFormats.rejectionReason(for: url)) }
        }

        private mutating func reject(_ url: URL, reason: String) {
            guard directURLs.contains(url.path) else { return }
            result.skipped.append((url: url, reason: reason))
        }

        // MARK: 各类型展开

        mutating func sheet(at url: URL) -> CueSheet? {
            // 键存在即算解析过（值可为 nil，表示这张 cue 不可用），避免反复读盘
            if let cached = sheetCache[url.path] { return cached }
            let parsed = CueSheet.parse(url: url).flatMap { $0.hasUsableAudio ? $0 : nil }
            sheetCache[url.path] = parsed
            return parsed
        }

        /// 整张盘展开成多轨；被展开的镜像不再整盘入表
        mutating func expand(_ sheet: CueSheet, sheetURL: URL, under name: String) {
            for audioURL in sheet.audioURLs { covered.insert(audioURL.path) }
            for info in sheet.tracks {
                emit(Track(cueTrack: info, sheet: sheet), via: sheetURL)
            }
        }

        mutating func absorbCue(_ url: URL) {
            guard let sheet = sheet(at: url) else {
                reject(url, reason: "分轨表能用，但它引用的镜像不在磁盘上")
                return
            }
            expand(sheet, sheetURL: url, under: url.lastPathComponent)
        }

        mutating func absorbAudio(_ url: URL) {
            // 只选中镜像但同目录有同名 cue 时同样自动分轨（拖 wav 也能拿到整张盘的轨次）
            let sibling = url.deletingPathExtension().appendingPathExtension(cueExtension)
            if let sheet = sheet(at: sibling),
               sheet.tracks.contains(where: { $0.fileURL.path == url.path }) {
                expand(sheet, sheetURL: sibling, under: sibling.lastPathComponent)
                return
            }
            guard !covered.contains(url.path) else { return }
            emit(Track(url: url))
        }

        /// m3u/m3u8：一行一个路径（也可以是电台地址），相对路径按歌单所在目录解析，保序入表
        mutating func absorbPlaylist(_ url: URL) {
            guard let text = LibraryStore.readText(url) else {
                reject(url, reason: "歌单读不出文本（不是 UTF-8/GBK 编码的 m3u）")
                return
            }
            let base = url.deletingLastPathComponent()
            enum Entry {
                case file(URL)
                /// 电台地址 + #EXTINF 里写的台名（空串 = 没写）
                case radio(URL, String)
            }
            var pending: [Entry] = []
            var extTitle: String?
            for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                if line.hasPrefix("#") {
                    // #EXTINF:-1,台名：只给下一行用（我们自己导出的 m3u 就长这样）
                    if line.uppercased().hasPrefix("#EXTINF"), let comma = line.firstIndex(of: ",") {
                        let name = line[line.index(after: comma)...].trimmingCharacters(in: .whitespaces)
                        extTitle = name.isEmpty ? nil : name
                    }
                    continue
                }
                if let radio = RadioURL.explicit(line) {
                    pending.append(.radio(radio, extTitle ?? ""))
                    extTitle = nil
                    continue
                }
                extTitle = nil
                let path = (line.hasPrefix("/") || line.hasPrefix("file://"))
                    ? line : base.appendingPathComponent(line).path
                let fileURL = path.hasPrefix("file")
                    ? (URL(string: path) ?? URL(fileURLWithPath: path))
                    : URL(fileURLWithPath: path)
                pending.append(.file(fileURL))
            }
            // 歌单里的条目不再是“用户直接拖进来的文件”，拒收原因只在歌单级别给
            for item in pending {
                switch item {
                case .radio(let radioURL, let name):
                    let track = Track(radio: radioURL)
                    if !name.isEmpty { track.title = name }
                    emit(track)
                case .file(let entry):
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), !isDir.boolValue else {
                        continue
                    }
                    let ext = entry.pathExtension.lowercased()
                    if AudioFormats.isPlaylist(entry) { absorbPlaylistSource(entry) }
                    else if ext == cueExtension { absorbCue(entry) }
                    else if AudioFormats.isPlayable(entry) { absorbAudio(entry) }
                }
            }
        }

        /// 歌单里嵌歌单：只跟进一层，不记录额外拒收原因
        private mutating func absorbPlaylistSource(_ url: URL) {
            let before = directURLs
            directURLs = []
            absorbPlaylist(url)
            directURLs = before
        }

        mutating func absorbDirectory(_ dir: URL) {
            var extensions = AudioFormats.scanExtensions
            extensions.insert(cueExtension)
            extensions.formUnion(AudioFormats.playlistExtensions)
            extensions.formUnion(AudioFormats.archiveExtensions)
            let found = LibraryStore.files(in: [dir], extensions: extensions)
            // 按文件名自然序逐个展开（和旧行为一致：一张盘的 cue 与单曲按名字交错时不乱）；
            // 同名 cue 排在镜像后面也不会重复：absorbAudio 会主动找同名 cue，后面的 cue 条目靠去重失效
            for url in found {
                if AudioFormats.isCue(url) { absorbCue(url) }
                else if AudioFormats.isPlaylist(url) { absorbPlaylist(url) }
                else if AudioFormats.isArchive(url) { absorbArchive(url) }
                else { absorbAudio(url) }
            }
        }

        /// v1.23 归档容器：一次 list 拿到 entry 表，音频条目扁平入表；
        /// 归档内 .cue / .m3u / 另一个归档 都跳过（不递归，避免炸弹）；
        /// 加密条目直接拒收；album 强制取外层归档文件名去后缀。
        mutating func absorbArchive(_ url: URL) {
            guard let entries = Archive.list(url: url) else {
                let msg = Archive.lastError ?? "归档打不开或格式不支持"
                reject(url, reason: msg)
                return
            }
            let albumName = Archive.albumName(for: url)
            var sawEncrypted = false
            let beforeCount = result.tracks.count
            for e in entries where !e.path.isEmpty {
                let ext = (e.path as NSString).pathExtension.lowercased()
                // 目录条目 / 嵌套归档 / cue / 歌单 / 非白名单音频：一律不展开
                if e.path.hasSuffix("/") { continue }
                if AudioFormats.isArchive(URL(fileURLWithPath: e.path)) { continue }
                if ext == cueExtension || AudioFormats.isPlaylist(URL(fileURLWithPath: e.path)) { continue }
                if !AudioFormats.playableExtensions.contains(ext) { continue }
                if e.encrypted { sawEncrypted = true; continue }
                guard let entryURL = Archive.makeEntryURL(archive: url, entry: e.path) else { continue }
                let track = Track(url: entryURL)
                track.album = albumName
                // 默认标题会退到外层归档文件名（zip 本身），同档内多条目全同名；
                // 改取条目 basename 去后缀，与拖拆开后看到的形式一致。
                let base = (e.path as NSString).lastPathComponent
                let stripped = (base as NSString).deletingPathExtension
                if !stripped.isEmpty { track.title = stripped }
                emit(track)
            }
            if sawEncrypted && result.tracks.count == beforeCount {
                // 一个音频都没拿到才归为拒收，否则默默入表不卡 UI
                reject(url, reason: "归档内条目均加密，暂不支持")
            }
        }
    }

    /// m3u/cue 文本都能是 UTF-8 或国内抓轨常见的 GB18030
    static func readText(_ url: URL) -> String? {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        return try? String(contentsOf: url, encoding: gb)
    }

    /// 从存档条目还原曲目（CUE 轨会重新解析分轨表，因此旧存档不写死起止点）
    static func tracks(fromArchiveEntries entries: [String]) -> [Track] {
        let fm = FileManager.default
        var sheetCache: [String: CueSheet?] = [:]
        func sheet(at path: String) -> CueSheet? {
            if let cached = sheetCache[path] { return cached }
            let parsed = CueSheet.parse(url: URL(fileURLWithPath: path))
            sheetCache[path] = parsed
            return parsed
        }
        var result: [Track] = []
        for entry in entries {
            // 电台：存档里就是完整地址，不查磁盘
            if let radio = RadioURL.explicit(entry) {
                result.append(Track(radio: radio))
                continue
            }
            guard let marker = entry.range(of: cueArchiveMarker) else {
                if fm.fileExists(atPath: entry) { result.append(Track(url: URL(fileURLWithPath: entry))) }
                continue
            }
            let sheetPath = String(entry[..<marker.lowerBound])
            guard let number = Int(entry[marker.upperBound...]),
                  fm.fileExists(atPath: sheetPath),
                  let sheet = sheet(at: sheetPath),
                  let info = sheet.tracks.first(where: { $0.number == number }) else { continue }
            result.append(Track(cueTrack: info, sheet: sheet))
        }
        return result
    }
}
