import Foundation
import AppKit

/// 全局播放控制器（门面）：组合 AudioEngine + Playlist + Lyric，负责状态广播与持久化
final class PlayerController {
    static let shared = PlayerController()

    let engine = AudioEngine()
    let playlist = Playlist()

    /// 最近播放 / 我的收藏的档案（只存键，切组时再还原成曲目）
    let groups = TrackGroups.shared
    /// 当前在看的列表组（左栏那一列名字）
    private(set) var activeGroup: GroupKind = .main
    /// 切去派生组时把 [默认] 组的现场留在这里：曲目对象带着已解析的元数据，切回来不用重读
    private var mainSnapshot: [Track] = []
    /// 派生组内容缓存（键序列不变就不重新还原、不重新解析）
    private var derivedCache: [GroupKind: (keys: [String], tracks: [Track])] = [:]
    /// 正在放的那首不在当前组里时（在收藏页听一首没收藏的歌），显示区仍要显示它
    private var playingTrackOverride: Track?

    private(set) var playMode: PlayMode = .listLoop
    private(set) var isPlaying = false
    private(set) var volume: Float = 0.8
    private(set) var isMuted = false
    private(set) var lyric: Lyric?
    private var lyricIndex = -2          // 上一次通知的歌词行

    /// 最近一次拖入被挡下的文件（一句人话原因）；导入成功就清空
    private(set) var lastImportProblem: String?
    /// 当前曲目放不起来的原因（显示区拿它替换格式那行，属性面板也读 Track.decodeProblem）
    private(set) var playbackProblem: String?
    /// 连续失败计数：整表都解不开时必须收手，否则 next() 会绕圈递归到栈溢出
    private var consecutiveFailures = 0
    /// 电台流里带的「正在播」（ICY StreamTitle）；没有就是空串
    private(set) var radioNowPlaying = ""

    private var timeTimer: Timer?
    private var saveTimer: Timer?

    private init() {
        engine.onPlaybackFinished = { [weak self] in
            self?.trackDidFinish()
        }
        // 电台的三类回话：状态（连接/重连/失败）、流参数、「正在播」的歌名
        engine.onRadioState = { [weak self] state in self?.radioStateDidChange(state) }
        engine.onRadioInfo = { [weak self] info in self?.radioInfoDidArrive(info) }
        engine.onRadioTitle = { [weak self] title in self?.setRadioNowPlaying(title) }
    }

    // MARK: - 状态查询

    var currentTrack: Track? { playingTrackOverride ?? playlist.currentTrack }
    var currentTime: Double { engine.currentTime }
    var duration: Double { engine.duration }
    /// 当前是否在放电台（进度条要变不可拖、时长要写「直播」）
    var isRadio: Bool { engine.isRadio }
    /// 电台状态文字（“正在连接电台…”/“信号中断，重连中…”）
    var radioStateText: String { engine.radioState.displayText }

    // MARK: - 列表操作

    /// 添加文件（去重），返回新增数量
    /// 传入整盘镜像 + .cue 时按分轨表拆成多首，m3u/m3u8 会展开成里面的条目（见 LibraryStore）
    @discardableResult
    func addFiles(_ urls: [URL], playNow: Bool = false) -> Int {
        // 新曲只进 [默认] 列表：停在我的收藏页往里拖歌，会让人以为歌被加进收藏了
        switchGroup(.main)
        let imported = LibraryStore.importURLs(urls)
        if let note = imported.skipNote {
            lastImportProblem = note
            Diagnostics.error("未入表：\(note)")
        } else if imported.tracks.isEmpty && !urls.isEmpty {
            // 拖了个空目录、或里面只有封面和说明：总得给句话，否则看着像没反应
            let note = "这个位置没有可播放的音频文件"
            lastImportProblem = note
            Diagnostics.error("未入表：\(note)")
        } else {
            lastImportProblem = nil
        }
        return addTracks(imported.tracks, playNow: playNow)
    }

    /// 添加一个电台地址（工具条「电台」键/菜单输入框）：成功返回 nil，失败返回一句人话
    /// 只收 http/https：用户粘进去的东西先归一化（去空白/引号/补协议），入表后就是普通一条 Track
    @discardableResult
    func addRadio(_ raw: String, playNow: Bool = true) -> String? {
        guard let url = RadioURL.normalize(raw) else {
            let note = "地址不对：只支持 http:// 或 https:// 开头的电台地址"
            lastImportProblem = note
            Diagnostics.error("未入表：\(note)")
            return note
        }
        switchGroup(.main)
        let track = Track(radio: url)
        // 已经在表里（同一地址）就不再入一条，直接拿现成那条播
        if let existing = playlist.tracks.first(where: { $0.identityKey == track.identityKey }) {
            lastImportProblem = nil
            if playNow { play(track: existing) }
            Diagnostics.log("电台已在列表：\(url.absoluteString)")
            return nil
        }
        lastImportProblem = nil
        addTracks([track], playNow: playNow)
        Diagnostics.log("添加电台 \(url.absoluteString)")
        return nil
    }

    /// 按 identityKey 去重入表（CUE 分轨的 url 都指向同一份镜像，只能靠这个键区分）
    @discardableResult
    func addTracks(_ newTracks: [Track], playNow: Bool = false) -> Int {
        let existing = Set(playlist.tracks.map { $0.identityKey })
        var added: [Track] = []
        for track in newTracks where !existing.contains(track.identityKey) {
            playlist.add(track)
            added.append(track)
            MetadataReader.read(track) { [weak self] in
                self?.notifyPlaylistChanged()
            }
        }
        notifyPlaylistChanged()
        if playNow, let first = added.first, !isPlaying {
            play(track: first)
        }
        return added.count
    }

    func removeTracks(at indexes: IndexSet) {
        // 记下正在放的行有没有被删；删完同步引擎，免得声音留在被删那一行、界面却指向下一首
        let removedCurrent = playlist.currentIndex.map { indexes.contains($0) } ?? false
        let wasPlaying = isPlaying
        switch activeGroup {
        case .main:
            playlist.remove(at: indexes)
        case .radio:
            // 「网络电台」是 [默认] 里电台地址的投影：在这一页删台就是真删台，
            // 只删投影的话切回 [默认] 它又冒出来了（本地文件那一张表不该跟着遭殃）
            let gone = Set(indexes.compactMap { playlist.track(at: $0)?.identityKey })
            mainSnapshot.removeAll { gone.contains($0.identityKey) }
            reloadActiveGroup()
        default:
            // 其他派生组里删除 = 从收藏/历史里拿掉，不能动 [默认] 的内容
            let dropped = indexes.compactMap { playlist.track(at: $0)?.identityKey }
            groups.remove(keys: dropped, from: activeGroup)
            invalidate(activeGroup)
            reloadActiveGroup()
        }
        if removedCurrent {
            // 声音与显示一起对齐到新的当前行：正在放就立刻接手，暂停/尾部就顺手停住，不隔空跳一个
            if wasPlaying, playlist.currentTrack != nil {
                loadAndPlayCurrent()
            } else {
                stop()
                playingTrackOverride = nil
            }
        }
        notifyPlaylistChanged()
    }

    func clearPlaylist() {
        stop()
        if activeGroup == .radio {
            // 在台这一页清空 = 把台从 [默认] 里删干净；「最近听的台」是历史不是列表，不清
            mainSnapshot.removeAll { $0.isRadio }
            playlist.removeAll()
            reloadActiveGroup()       // 就留在这一组：空表 + 中央一句提示
        } else if activeGroup.isDerived {
            // 只清这一组的档案；[默认] 现场不动，切回去还在（同“在台页清空”一样靠 reloadActiveGroup 开空表 + 中央提示）
            groups.clear(activeGroup)
            invalidate(activeGroup)
            reloadActiveGroup()
        } else {
            playlist.removeAll()
        }
        lyric = nil
        playingTrackOverride = nil
        // 上一批导入留下的说明文字也一并清掉，不然列表都清空了还写着旧原因
        lastImportProblem = nil
        consecutiveFailures = 0
        notifyPlaylistChanged()
        postTrackChange()
    }

    // MARK: - 列表组（左栏 [默认] / 网络电台 / 最近听的台 / 最近播放 / 我的收藏）

    /// 切组：把目标组的内容装上当前列表。切组不丢内容 —— [默认] 的现场一直留档
    func switchGroup(_ kind: GroupKind) {
        guard kind != activeGroup else { return }
        if activeGroup == .main { mainSnapshot = playlist.tracks }
        activeGroup = kind
        install(kind == .main ? mainSnapshot : derivedTracks(for: kind))
        Diagnostics.log("列表组 → \(kind.name)（\(playlist.count) 首）")
        notifyPlaylistChanged()
    }

    /// 收藏 / 取消收藏（右键菜单与 ⌘D 走这里）；返回操作后的状态
    @discardableResult
    func toggleFavorite(_ track: Track) -> Bool {
        let on = groups.toggleFavorite(track)
        invalidate(.favorites)
        if activeGroup == .favorites { reloadActiveGroup() }
        Diagnostics.log(on ? "加入收藏 \(track.title)" : "移出收藏 \(track.title)")
        notifyPlaylistChanged()
        return on
    }

    func isFavorite(_ track: Track) -> Bool { groups.isFavorite(track) }

    /// 装上某一组的内容；正在放的那首不在里面就留个 override，避免显示区跟着空掉
    private func install(_ tracks: [Track]) {
        let playing = playlist.currentTrack ?? playingTrackOverride
        playlist.removeAll()
        playlist.add(contentsOf: tracks)
        if let playing, let i = playlist.index(of: playing) {
            _ = playlist.select(i)
            playingTrackOverride = nil
        } else {
            playingTrackOverride = isPlaying ? playing : nil
        }
    }

    /// 收藏/历史变了之后重建当前组（行数、顺序都要跟着变）
    private func reloadActiveGroup() {
        guard activeGroup.isDerived else { return }
        let playing = playlist.currentTrack ?? playingTrackOverride
        playlist.removeAll()
        playlist.add(contentsOf: derivedTracks(for: activeGroup))
        if let playing, let i = playlist.index(of: playing) {
            _ = playlist.select(i)
            playingTrackOverride = nil
        } else {
            playingTrackOverride = isPlaying ? playing : nil
        }
    }

    private func invalidate(_ kind: GroupKind) { derivedCache[kind] = nil }

    /// 这一组该列哪些键：「网络电台」不另存一份地址，直接拿 [默认] 留档里的电台投影，
    /// 所以加台 / 删台只改一处，两个页面跟着一起变；其余组读各自的档案
    private func derivedKeys(for kind: GroupKind) -> [String] {
        switch kind {
        case .main: return []
        case .radio: return mainSnapshot.filter { $0.isRadio }.map { $0.identityKey }
        case .recent, .favorites, .recentRadio: return groups.entries(for: kind)
        }
    }

    /// 按档案键还原成曲目：先复用内存里已有的 Track（元数据已解析），缺的再按存档写法重建
    private func derivedTracks(for kind: GroupKind) -> [Track] {
        let keys = derivedKeys(for: kind)
        if let cached = derivedCache[kind], cached.keys == keys { return cached.tracks }
        var pool: [String: Track] = [:]
        for t in mainSnapshot + playlist.tracks { pool[t.identityKey] = t }
        if let cached = derivedCache[kind] { for t in cached.tracks { pool[t.identityKey] = t } }
        // 只剩内存里没有的那些才去重新解析（CUE 分轨会重新读分轨表）
        let missing = keys.filter { pool[$0] == nil }
        for t in LibraryStore.tracks(fromArchiveEntries: missing) { pool[t.identityKey] = t }
        // 文件已经不在盘上的键在这里自然掉队（和存档还原同一个规矩）
        let tracks = keys.compactMap { pool[$0] }
        for t in tracks where t.duration == 0 && !t.isRadio {
            MetadataReader.read(t) { [weak self] in self?.notifyPlaylistChanged() }
        }
        derivedCache[kind] = (keys, tracks)
        return tracks
    }

    // MARK: - 播放控制

    /// 双击列表 / 点播
    func play(track: Track) {
        guard let index = playlist.index(of: track) else { return }
        _ = playlist.select(index)
        loadAndPlayCurrent()
    }

    func playRowAt(_ index: Int) {
        guard playlist.select(index) != nil else { return }
        loadAndPlayCurrent()
    }

    /// 播放 / 暂停切换
    func togglePlay() {
        if isPlaying {
            engine.pause()
            setState(playing: false)
        } else {
            // 未选中任何曲目时默认选第一首（firstTrack 内部已 select）
            if playlist.currentTrack == nil,
               playlist.firstTrack() == nil { return }
            // 电台：暂停即断流，恢复就是重连（直播本来就该听当下的，不补放暂停期间的内容）
            if engine.isRadio {
                engine.play()
                setState(playing: true)
                return
            }
            if engine.duration == 0 {
                loadAndPlayCurrent()
            } else {
                engine.play()
                setState(playing: true)
            }
        }
    }

    func stop() {
        engine.stop()
        playbackProblem = nil
        consecutiveFailures = 0
        radioNowPlaying = ""
        setState(playing: false)
        postTrackChange()
    }

    func next() {
        if playlist.advance(for: playMode) != nil {
            loadAndPlayCurrent()
        } else {
            stop()
        }
    }

    func previous() {
        if playlist.retreat(for: playMode) != nil {
            loadAndPlayCurrent()
        }
    }

    func seek(to seconds: Double) {
        engine.seek(seconds: seconds)
        if isPlaying { postTimeUpdate() }
        // 系统那一栏的时间是用「快照 + 速率」外推的，拖过进度条必须重新给一次
        NowPlaying.update(track: currentTrack, isPlaying: isPlaying, elapsed: engine.currentTime)
        updateLyricLine(force: true)
    }

    func setMode(_ mode: PlayMode) {
        playMode = mode
        playlist.modeIsRandom = (mode == .random)
        NotificationCenter.default.post(name: .ttPlayModeChanged,
                                        object: nil,
                                        userInfo: ["mode": mode.rawValue])
        scheduleSave()
    }

    func cycleMode() {
        let all = PlayMode.allCases
        let next = all[(all.firstIndex(of: playMode)! + 1) % all.count]
        setMode(next)
    }

    func setVolume(_ v: Float) {
        volume = max(0, min(1, v))
        if volume > 0, isMuted { isMuted = false }
        applyVolume()
        scheduleSave()
    }

    func toggleMute() {
        isMuted.toggle()
        applyVolume()
        scheduleSave()
    }

    private func applyVolume() {
        engine.setVolume(volume, mute: isMuted)
        NotificationCenter.default.post(name: .ttVolumeChanged, object: nil,
                                        userInfo: ["volume": volume, "muted": isMuted])
    }

    // MARK: - 均衡器

    /// 均衡器是否开启（供 UI 高亮按钮）
    var eqEnabled: Bool { !engine.eq.bypass }

    func setEQEnabled(_ enabled: Bool) {
        engine.setEQEnabled(enabled)
        scheduleSave()
    }

    func setEQGain(band: Int, gain: Float) {
        engine.setEQGain(band: band, gain: gain)
        scheduleSave()
    }

    /// 前置放大（皮肤均衡器左旋钮，dB）
    func setPreGain(_ db: Float) {
        engine.setPreGain(db)
        scheduleSave()
    }

    var preGain: Float { engine.preGain }

    // MARK: - 内部

    private func loadAndPlayCurrent() {
        guard let track = playlist.currentTrack else { return }
        // 电台切台（台 → 台、台 → 本地文件）：先把正在播的流淡掉再断。
        // 硬切在数模转换上留下的是一个台阶（听感就是“啪”），而换台本来就要等网络，
        // 多等这 120 ms 没人感觉得到
        if engine.isRadio, engine.radioHasSound {
            engine.fadeOutRadioStream(reason: "切到 \(track.title)") { [weak self] in
                self?.startLoad(of: track)
            }
            return
        }
        startLoad(of: track)
    }

    /// 真正把选中的曲目装上引擎（从电台切过来时这一步会被淡出推后 120 ms）
    private func startLoad(of track: Track) {
        engine.stop()
        if track.isRadio {
            // 电台走自家通路：没有文件、不能 seek，成败由流的状态回调说
            loadRadio(track)
            return
        }
        do {
            // CUE 分轨只播镜像里属于本轨的那一段（进度条也以本段为 0）
            try engine.load(url: track.url, from: track.playStart, to: track.playEnd)
        } catch {
            // 打不开也要说清楚为什么：系统错误文本对用户没有信息量，
            // 换成“这个格式缺什么/文件怎么了”，同时留在曲目上供属性面板显示
            let problem = AudioFormats.playbackProblem(for: track, error: error)
            track.decodeProblem = problem
            playbackProblem = problem
            consecutiveFailures += 1
            Diagnostics.error("无法播放 \(track.fileName)：\(problem)（原始错误 \(error)）")
            // 列表里每一首都试过仍失败就停手，不然列表循环模式下 next() 会无限递归
            guard consecutiveFailures < playlist.count else {
                Diagnostics.error("列表里 \(playlist.count) 首都放不起来，已停止自动跳过")
                setState(playing: false)
                postTrackChange()
                return
            }
            next()
            return
        }
        consecutiveFailures = 0
        playbackProblem = nil
        track.decodeProblem = nil
        playingTrackOverride = nil
        // 最近播放：开播就记一笔（暂停后继续不算新的一笔）
        groups.recordPlay(track)
        invalidate(.recent)
        scheduleSave()
        engine.play()
        Diagnostics.log("播放 \(track.fileName) [\(track.formatLabel) "
            + "\(track.bitRateKbps)k \(Int(track.sampleRate))Hz]"
            + (track.isCueSegment ? " CUE 段 \(String(format: "%.2f", track.playStart))s 起" : ""))
        setState(playing: true)
        postTrackChange()
        loadLyric(for: track)
        startTimeTimer()
    }

    private func trackDidFinish() {
        switch playMode {
        case .singleLoop:
            engine.seek(seconds: 0)
            engine.play()
        default:
            next()
        }
    }

    // MARK: - 电台

    private func loadRadio(_ track: Track) {
        consecutiveFailures = 0
        playbackProblem = nil
        track.decodeProblem = nil
        radioNowPlaying = ""
        playingTrackOverride = nil
        groups.recordPlay(track)
        invalidate(.recent)
        // 台另记一份“最近听的台”：台被删出列表也还能从这一组点回来听
        groups.recordRadioPlay(track)
        invalidate(.recentRadio)
        scheduleSave()
        engine.loadRadio(url: track.url)
        engine.play()
        Diagnostics.log("播放电台 \(track.url.absoluteString)")
        setState(playing: true)
        postTrackChange()
        // 电台没有 .lrc：把上一首的歌词清掉，否则显示区还挂着上一首的词
        lyric = nil
        lyricIndex = -2
        updateLyricLine(force: true)
        startTimeTimer()
    }

    /// 流状态回话：连上了、断了在重连、还是彻底失败
    private func radioStateDidChange(_ state: RadioPlayer.State) {
        switch state {
        case .failed(let reason):
            // 重连到上限：这一次就不响了，原因同时留在显示区与曲目上（属性面板能查）
            playbackProblem = reason
            playlist.currentTrack?.decodeProblem = reason
            setState(playing: false)
            selectNextAfterRadioFailure()
        case .playing:
            playbackProblem = nil
            playlist.currentTrack?.decodeProblem = nil
            if !isPlaying { setState(playing: true) }
        case .idle, .connecting, .reconnecting, .fallingBack:
            break
        }
        postRadioChange()
    }

    /// 电台连不上时不要停在那里装死：按当前播放模式跳下一首（与本地文件打不开一致）
    private func selectNextAfterRadioFailure() {
        consecutiveFailures += 1
        guard consecutiveFailures < playlist.count else {
            Diagnostics.error("列表里 \(playlist.count) 首都放不起来，已停止自动跳过")
            return
        }
        next()
    }

    /// 流里报出真实参数（编码/采样率/码率）：写回曲目，列表与属性面板跟着变
    private func radioInfoDidArrive(_ info: RadioStreamDecoder.Info) {
        guard let track = playlist.currentTrack, track.isRadio else { return }
        if !info.codec.isEmpty { track.formatName = info.codec }
        if info.sampleRate > 0 { track.sampleRate = info.sampleRate }
        if info.bitRateKbps > 0 { track.bitRateKbps = info.bitRateKbps }
        notifyPlaylistChanged()
        postRadioChange()
    }

    private func setRadioNowPlaying(_ title: String) {
        radioNowPlaying = title
        postRadioChange()
    }

    private func postRadioChange() {
        NotificationCenter.default.post(name: .ttRadioChanged, object: nil,
                                        userInfo: ["state": engine.radioState.displayText,
                                                   "title": radioNowPlaying])
    }

    private func setState(playing: Bool) {
        isPlaying = playing
        NotificationCenter.default.post(name: .ttPlaybackStateChanged, object: nil,
                                        userInfo: ["isPlaying": playing])
        NowPlaying.update(track: currentTrack, isPlaying: playing, elapsed: engine.currentTime)
        if playing { startTimeTimer() } else { timeTimer?.invalidate(); timeTimer = nil }
    }

    private func startTimeTimer() {
        guard timeTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.postTimeUpdate()
            self?.updateLyricLine(force: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        timeTimer = timer
    }

    private func postTimeUpdate() {
        NotificationCenter.default.post(name: .ttTimeUpdated, object: nil,
                                        userInfo: ["time": engine.currentTime,
                                                   "duration": engine.duration])
    }

    private func postTrackChange() {
        NotificationCenter.default.post(name: .ttTrackChanged, object: nil,
                                        userInfo: ["track": playlist.currentTrack as Any])
        // 控制中心那一栏跟播放状态一起换：只换标题不清进度，进度条会跳到上一首的位置
        NowPlaying.update(track: currentTrack, isPlaying: isPlaying, elapsed: engine.currentTime)
    }

    private func notifyPlaylistChanged() {
        NotificationCenter.default.post(name: .ttPlaylistChanged, object: nil)
        scheduleSave()
    }

    // MARK: - 歌词

    private func loadLyric(for track: Track) {
        lyric = Lyric.load(for: track)
        lyricIndex = -2
        updateLyricLine(force: true)
    }

    private func updateLyricLine(force: Bool) {
        guard let lyric else {
            if force {
                NotificationCenter.default.post(name: .ttLyricChanged, object: nil,
                                                userInfo: ["line": "", "next": "",
                                                           "start": 0.0, "end": 0.0])
            }
            return
        }
        let idx = lyric.lineIndex(at: engine.currentTime)
        guard idx != lyricIndex || force else { return }
        lyricIndex = idx
        let current = lyric.line(at: idx)
        let next = lyric.line(at: idx + 1)
        NotificationCenter.default.post(name: .ttLyricChanged, object: nil,
                                        userInfo: [
                                            "line": current?.text ?? "",
                                            "next": next?.text ?? "",
                                            "start": current?.time ?? 0,
                                            "end": next?.time ?? (current?.time ?? 0) + 5,
                                        ])
    }

    // MARK: - 持久化

    func restoreFromState() {
        let state = LibraryStore.load()
        setMode(PlayMode(rawValue: state.playMode) ?? .listLoop)
        volume = state.volume
        isMuted = state.muted
        applyVolume()
        engine.setEQEnabled(state.eqEnabled)
        engine.setPreGain(state.eqPreGain)
        // 旧存档可能是 6 段，补齐到当前段数
        let gains = state.eqGains + Array(repeating: Float(0),
                                         count: max(0, AudioEngine.eqBandCount - state.eqGains.count))
        for (i, g) in gains.prefix(AudioEngine.eqBandCount).enumerated() {
            engine.setEQGain(band: i, gain: g)
        }
        // 存档条目可能是普通音频路径，也可能是 `cue路径#track=N`（分轨重新解析即可拿到起止点）
        let restored = LibraryStore.tracks(fromArchiveEntries: state.trackPaths)
        groups.restore(recent: state.recentKeys, favorites: state.favoriteKeys,
                       recentRadios: state.recentRadioKeys)
        activeGroup = .main
        if !restored.isEmpty {
            _ = addTracks(restored)
        }
    }

    func persistNow() {
        var state = LibraryStore.load()
        // identityKey 同时是存档写法：普通轨是文件路径，CUE 轨是 `cue路径#track=N`。
        // 停在派生组时写的必须是 [默认] 组的留档，否则一次切组就把用户的列表冲了
        let mainTracks = activeGroup == .main ? playlist.tracks : mainSnapshot
        state.trackPaths = mainTracks.map { $0.identityKey }
        state.recentKeys = groups.recentKeys
        state.favoriteKeys = groups.favoriteKeys
        state.recentRadioKeys = groups.recentRadioKeys
        state.playMode = playMode.rawValue
        state.volume = volume
        state.muted = isMuted
        state.eqEnabled = !engine.eq.bypass
        state.eqGains = (0..<AudioEngine.eqBandCount).map { engine.eqGain(band: $0) }
        state.eqPreGain = engine.preGain
        LibraryStore.save(state)
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.persistNow()
        }
    }
}
