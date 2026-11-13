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
    /// 自建歌单：名字 + 条目引用（写法同 trackPaths），旧档没这一项时是空表
    var userLists: [UserPlaylist] = []
    /// 上次在看的歌单 ID（空 = 停在固定页）。存 ID 不存名字：改了名也找得回来
    var viewListID: String = ""
    /// 「启动后自动继续播放」：默认关闭。只在上次退出前处于播放状态时才自动开播，
    /// 手动停止过就再也不会自己响起来（requirements F06）
    var autoResumePlay: Bool = false
    /// 无缝衔接（F01）：默认开。旧档缺这一项时不能「升级一下就又跳出空白」
    var gaplessPlay: Bool = true
    /// 响度均衡（F02）：`ReplayGainMode.rawValue`。默认 0 = 关闭，
    /// 存整数不存枚举名：以后加模式不用改动存档写法
    var replayGainMode: Int = 0
    /// ReplayGain 前置增益（dB，-12…+12）。默认 0：它只是在已经算好的增益上再推一把
    var replayGainPreamp: Float = 0
    /// 峰值防削波（F02）：默认开。开着时合成增益会被 Peak 压到不越过满量程
    var replayGainPeakLimit: Bool = true
    /// 输出设备（F07）：只存 UID，不存临时的 AudioDeviceID（重插一次就换号）。
    /// 空串 = 跟随系统默认（需求里的默认档）
    var outputDeviceUID: String = ""
    /// 那台设备的可读名字：只为「设备已经不在了还能说出它叫什么」而存，不参与查找
    var outputDeviceName: String = ""
    /// 媒体库（F08）：用户添加的音乐目录，按添加顺序。
    /// 只存目录本身，不存目录里的文件：那一片盘的东西随时会变，以扫描结果为准
    var libraryFolders: [String] = []
    /// 媒体库扫出来的条目引用（与 trackPaths 同一套写法）。存下来是为了
    /// 启动时盘还没接上也能先列出「上次看到有什么」（标失效），不是重新扫一次的成果
    var libraryKeys: [String] = []
    /// 睡眠定时器到期前要不要淡出最后十秒（F09）：默认开。
    /// 只有这个开关入库，定时器本身不入库 —— 睡前设的那三特别不能下次开机自己冒出来
    var sleepFade: Bool = true
    /// 歌词时间校准（F10）：键是曲目的稳定身份（`Track.identityKey` 那一套写法，
    /// CUE 轨自带轨号、归档条目自带条目名），值是用户校准量（秒，正值 = 歌词延后显示）。
    /// 只存这一份表，绝不回写用户的 .lrc；没调过的曲子不占位
    var lyricShifts: [String: Double] = [:]
    /// 电台自定义台名（F11）：键是电台地址（与 `Track.identityKey` 同一写法），
    /// 值是用户起的名字。没起过名字的台不占位，显示时回落 host/端口
    var radioAliases: [String: String] = [:]
    /// 电台分类（F11）：只有用户自己建的那些，未分类不是分类所以不在这里（它是默认入口）
    var radioCategories: [RadioCategory] = []
    /// 地址 → 分类 id。没归类的台不在这里占位
    var radioAssignments: [String: String] = [:]
    /// 用户亲手删掉的内置电台（F11 出厂那几台的身份键）。种入只认这一份黑名单：
    /// 「不需要就自己删」得真能删掉，否则每天启动又被塞回来，就成了删不掉的僵尸条目。
    /// 旧档没这一项 = 谁也没删过，首次升级上来会补种一台（跟新装同一个行为）
    var declinedRadioKeys: [String] = []

    // MARK: 宽容解码
    // 逐字段 decodeIfPresent：旧版 state.json 缺少新增字段时不能整档解码失败，
    // 否则 LibraryStore.load() 会回退到空默认值，把播放列表与设置一起丢掉。
    private enum CodingKeys: String, CodingKey {
        case trackPaths, playMode, volume, muted, eqEnabled, eqGains, eqPreGain
        case eqPresetName, windowFrame, listVisible, dockGeometry, eqVisible, lyricFrame
        case skinLayout, recentKeys, favoriteKeys, recentRadioKeys, glass, transparency
        case userLists, viewListID, autoResumePlay, gaplessPlay
        case replayGainMode, replayGainPreamp, replayGainPeakLimit
        case outputDeviceUID, outputDeviceName
        case libraryFolders, libraryKeys
        case sleepFade, lyricShifts
        case radioAliases, radioCategories, radioAssignments, declinedRadioKeys
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
        userLists = try c.decodeIfPresent([UserPlaylist].self, forKey: .userLists) ?? []
        viewListID = try c.decodeIfPresent(String.self, forKey: .viewListID) ?? ""
        autoResumePlay = try c.decodeIfPresent(Bool.self, forKey: .autoResumePlay) ?? false
        gaplessPlay = try c.decodeIfPresent(Bool.self, forKey: .gaplessPlay) ?? true
        replayGainMode = try c.decodeIfPresent(Int.self, forKey: .replayGainMode) ?? 0
        replayGainPreamp = try c.decodeIfPresent(Float.self, forKey: .replayGainPreamp) ?? 0
        replayGainPeakLimit = try c.decodeIfPresent(Bool.self, forKey: .replayGainPeakLimit) ?? true
        outputDeviceUID = try c.decodeIfPresent(String.self, forKey: .outputDeviceUID) ?? ""
        outputDeviceName = try c.decodeIfPresent(String.self, forKey: .outputDeviceName) ?? ""
        libraryFolders = try c.decodeIfPresent([String].self, forKey: .libraryFolders) ?? []
        libraryKeys = try c.decodeIfPresent([String].self, forKey: .libraryKeys) ?? []
        sleepFade = try c.decodeIfPresent(Bool.self, forKey: .sleepFade) ?? true
        lyricShifts = try c.decodeIfPresent([String: Double].self, forKey: .lyricShifts) ?? [:]
        radioAliases = try c.decodeIfPresent([String: String].self, forKey: .radioAliases) ?? [:]
        radioCategories = try c.decodeIfPresent([RadioCategory].self, forKey: .radioCategories) ?? []
        radioAssignments = try c.decodeIfPresent([String: String].self, forKey: .radioAssignments) ?? [:]
        declinedRadioKeys = try c.decodeIfPresent([String].self, forKey: .declinedRadioKeys) ?? []
    }
}

enum LibraryStore {
    /// 可播扩展名的唯一来源是 AudioFormats（向 CoreAudio 现场问出来的）
    static var supportedExtensions: Set<String> { AudioFormats.scanExtensions }
    /// 分轨表（单独统计，命中时把一份镜像拆成多首）
    static let cueExtension = AudioFormats.cueExtension

    /// 整目录扫描的发现集：可播 ∪ 分轨表 ∪ 歌单 ∪ 归档容器。
    /// 拖目录与媒体库扫描共用这一份 —— 两条路必须认同一批扩展名，
    /// 不然同一个目录会给出两种结果（F08）
    static let directoryExtensions: Set<String> = {
        var ext = AudioFormats.scanExtensions
        ext.insert(cueExtension)
        ext.formUnion(AudioFormats.playlistExtensions)
        ext.formUnion(AudioFormats.archiveExtensions)
        return ext
    }()

    /// 存档目录：自检用 TTPLAYER_TESTDIR 隔离，避免跑一次自检就覆盖用户的播放列表与窗口布局
    private static var storeDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        if env["TTPLAYER_SELFTEST"] == "1", let dir = env["TTPLAYER_TESTDIR"], !dir.isEmpty {
            let base = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            return base
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TTPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func stateFile(named name: String) -> URL {
        storeDirectory.appendingPathComponent(name)
    }

    private static var stateURL: URL { stateFile(named: "state.json") }

    /// 播放现场（F06）单独一份文件：进度要 5 秒落一次，不能陪着整库一起重写
    private static var resumeURL: URL { stateFile(named: "resume.json") }

    /// 自检用：两份存档文件的位置。「旧版存档兼容」与「进度只写小文件」这两类断言
    /// 要直接读写原始 JSON 与文件字节数，走不了 load/save 这一层封装
    static var selfTestResumeURL: URL { resumeURL }
    static var selfTestStateURL: URL { stateURL }

    /// 自检每次从干净存档起跑：上一轮留下的面板开关、窗口位置、播放现场会让
    /// 首批断言时灵时不灵
    static func resetSelfTestStateIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["TTPLAYER_SELFTEST"] == "1" else { return }
        try? FileManager.default.removeItem(at: stateURL)
        try? FileManager.default.removeItem(at: resumeURL)
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

    /// 读播放现场：没有文件、或是旧版从没写过这一项 → 空现场（`isEmpty`），
    /// 恢复正常启动流程，不报错也不自动开播
    static func loadResume() -> ResumeScene {
        guard let data = try? Data(contentsOf: resumeURL),
              let scene = try? JSONDecoder().decode(ResumeScene.self, from: data) else {
            return ResumeScene()
        }
        return scene.sanitized
    }

    /// 原子写（`.atomic` 先落临时文件再改名）：进度是 5 秒一次频繁写，
    /// 半途断电/崩溃不能留下半截 JSON 让下次启动解不开
    static func saveResume(_ scene: ResumeScene) {
        guard let data = try? JSONEncoder().encode(scene) else { return }
        try? data.write(to: resumeURL, options: .atomic)
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
        /// m3u/m3u8 展开过程中已进过的歌单文件（防自引用/互引无限递归）
        var visitedPlaylists = Set<String>()
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
            // 循环引用防护：同一个 m3u 在本次导入里只展开一次（直接拖 / 嵌套 / 目录扫描都算）；
            // A→B→A 跟自引用都会在下一次进入时短路，不致无限递归
            guard visitedPlaylists.insert(url.path).inserted else { return }
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
                    // 台名按地址存（F11）：用户已经给这个地址起过名，就不能因为
                    // 某一版 m3u 里写的是另一个名字就把它改掉 —— m3u 里那一句
                    // 本来就是从某个地方抄来的标题，不是用户在这台机器上的设置
                    if !name.isEmpty, !RadioStations.shared.hasCustomName(for: radioURL) {
                        track.title = name
                    }
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

        /// 歌单里嵌歌单：不记额外拒收原因；循环防护靠 absorbPlaylist 自己的 visitedPlaylists
        private mutating func absorbPlaylistSource(_ url: URL) {
            let before = directURLs
            directURLs = []
            absorbPlaylist(url)
            directURLs = before
        }

        mutating func absorbDirectory(_ dir: URL) {
            let found = LibraryStore.files(in: [dir], extensions: LibraryStore.directoryExtensions)
            // 按文件名自然序逐个展开（和旧行为一致：一张盘的 cue 与单曲按名字交错时不乱）；
            // 同名 cue 排在镜像后面也不会重复：absorbAudio 会主动找同名 cue，后面的 cue 条目靠去重失效
            for url in found { absorbScanned(url) }
        }

        /// 已经在发现集里的文件 → 按类型路由入表。媒体库扫描自己走盘收集路径，
        /// 但路由必须走这一条，否则「拖目录」与「扫目录」对同一个位置会有两种写法
        mutating func absorbScanned(_ url: URL) {
            if AudioFormats.isCue(url) { absorbCue(url) }
            else if AudioFormats.isPlaylist(url) { absorbPlaylist(url) }
            else if AudioFormats.isArchive(url) { absorbArchive(url) }
            else { absorbAudio(url) }
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
        var resolver = EntryResolver()
        return entries.compactMap { resolver.track($0) }
    }

    /// 存档写法 → 曲目的解析器（分轨表只解一次，多轨共享一份）。
    /// 播放现场（F06）直接用它逐条解：解不开的那条要留占位，队列的次序与下标
    /// 是照条目算的，丢掉一条就把「当前位置」和后面的条目全顶歪了
    struct EntryResolver {
        private let fm = FileManager.default
        private var sheetCache: [String: CueSheet?] = [:]

        private mutating func sheet(at path: String) -> CueSheet? {
            if let cached = sheetCache[path] { return cached }
            let parsed = CueSheet.parse(url: URL(fileURLWithPath: path))
            sheetCache[path] = parsed
            return parsed
        }

        /// 解不开（文件不在了、分轨表里没这一轨了）返回 nil
        mutating func track(_ entry: String) -> Track? {
            // 电台：存档里就是完整地址，不查磁盘
            if let radio = RadioURL.explicit(entry) {
                return Track(radio: radio)
            }
            guard let marker = entry.range(of: cueArchiveMarker) else {
                // 归档条目 URL：file:///…/album.zip#archive-entry=<percent-encoded>，
                // identityKey 在 Track 那边已经专走 absoluteString，这里按外层存在与否判断
                if let url = URL(string: entry), Archive.parseEntryURL(url) != nil {
                    return fm.fileExists(atPath: url.path) ? Track(url: url) : nil
                }
                return fm.fileExists(atPath: entry) ? Track(url: URL(fileURLWithPath: entry)) : nil
            }
            let sheetPath = String(entry[..<marker.lowerBound])
            guard let number = Int(entry[marker.upperBound...]),
                  fm.fileExists(atPath: sheetPath),
                  let sheet = sheet(at: sheetPath),
                  let info = sheet.tracks.first(where: { $0.number == number }) else { return nil }
            return Track(cueTrack: info, sheet: sheet)
        }
    }

    /// 一条存档写法现在还在不在盘上（电台没有文件可言，算“在”）。
    /// CUE 轨看分轨表，归档条目看外层归档，普通文件看自己
    static func entryExists(_ entry: String) -> Bool {
        let fm = FileManager.default
        if RadioURL.explicit(entry) != nil { return true }
        if let url = URL(string: entry), Archive.parseEntryURL(url) != nil {
            return fm.fileExists(atPath: url.path)
        }
        if let marker = entry.range(of: cueArchiveMarker) {
            return fm.fileExists(atPath: String(entry[..<marker.lowerBound]))
        }
        return fm.fileExists(atPath: entry)
    }

    /// 解不出来的存档写法 → 一条指着原位置的占位引用，并标上失效。
    /// 歌单页要用它：用户的引用不能因为文件走了就在表里静默消失（F04「缺失文件标记」），
    /// 放在表里看得见，才能决定是重新定位还是删掉。
    static func placeholder(for entry: String) -> Track {
        let track: Track
        if let radio = RadioURL.explicit(entry) {
            track = Track(radio: radio)
            return track            // 电台没有盘上文件，不进失效这条路
        }
        if let marker = entry.range(of: cueArchiveMarker),
           let number = Int(entry[marker.upperBound...]) {
            let sheetURL = URL(fileURLWithPath: String(entry[..<marker.lowerBound]))
            track = Track(url: sheetURL)
            // 分轨身份一并留着：占位条目的 identityKey 必须与存档写法逐字符相同，
            // 不然用户在歌单页删掉一条失效的 CUE 引用会删不掉（删行是按 identityKey 找键的）
            track.cue = CueTrackInfo(number: number, sheetURL: sheetURL, title: "",
                                      performer: "", fileURL: sheetURL, start: 0,
                                      nextStart: nil)
            track.title = "\(sheetURL.deletingPathExtension().lastPathComponent) 第"
                + " \(String(format: "%02d", number)) 轨"
        } else if let url = URL(string: entry), let parsed = Archive.parseEntryURL(url) {
            track = Track(url: url)
            // 条目名字就是本来在归档里的那一段，不然标题只能退到外层 zip 本身
            track.title = (parsed.entry as NSString).lastPathComponent
        } else {
            track = Track(url: URL(fileURLWithPath: entry))
        }
        track.missingOnDisk = true
        return track
    }
}
