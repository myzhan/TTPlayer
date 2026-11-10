import Foundation
import AVFoundation
import AppKit

/// 网络电台：地址归一化 → 模型/存档/歌单往返 → 左栏分组与台历史 → ICY 拆包 → 流式解码 → 切台淡出。
///
/// 全程离线，不自检不出网：回归机器未必有网，一次 DNS 超时就够把整套拖垮。
/// 「真拉流」那一段（URLSession + 退避重连）只验纯逻辑（retryDelay / 失败归类 / 状态文案），
/// 字节流的解析则拿 afconvert 现造的 ADTS AAC 当网络数据直接喂进去——真实网络也是
/// 一块一块到的，所以按 1 KB 切着喂，顺带验跨块续接。
struct RadioSuite: SelfTestSuite {
    func run(_ ctx: SelfTestContext) {
        checkNormalize(ctx)
        checkModel(ctx)
        checkArchive(ctx)
        checkPlaylist(ctx)
        checkDurationColumn(ctx)
        checkGroups(ctx)
        checkFadeMath(ctx)
        checkICY(ctx)
        checkRetry(ctx)
        checkDecoder(ctx)
        checkLiveStream(ctx)
    }

    // MARK: - 地址归一化

    private func checkNormalize(_ ctx: SelfTestContext) {
        let cases: [(String, String)] = [
            ("  http://a.example.com/live  ", "http://a.example.com/live"),
            ("a.example.com/live", "http://a.example.com/live"),
            ("\"https://b.example.com:8000/s\"", "https://b.example.com:8000/s"),
        ]
        var bad: [String] = []
        for (raw, want) in cases where RadioURL.normalize(raw)?.absoluteString != want {
            bad.append("\(raw) → \(RadioURL.normalize(raw)?.absoluteString ?? "nil")")
        }
        ctx.check("电台-地址归一化（去空白/补协议/去引号）", bad.isEmpty,
                  bad.isEmpty ? "3 例" : bad.joined(separator: " / "))

        let rejected = ["ftp://a.example.com/x", "file:///tmp/a.mp3", "   ", "http://"]
        let leaked = rejected.filter { RadioURL.normalize($0) != nil }
        ctx.check("电台-只收 http/https 且有主机", leaked.isEmpty,
                  leaked.isEmpty ? "4 例全挡" : "放过了 \(leaked)")

        let url = URL(string: "http://192.168.1.5:8000/stream")!
        ctx.check("电台-显示名用主机加端口",
                  RadioURL.displayName(for: url) == "192.168.1.5:8000/stream",
                  RadioURL.displayName(for: url))
        // m3u 里的相对路径不能靠“补协议”猜成电台
        ctx.check("电台-相对路径不当成电台",
                  RadioURL.explicit("Music/a.mp3") == nil
                    && RadioURL.explicit("HTTP://c.example.com/x") != nil)
    }

    // MARK: - 模型

    private func checkModel(_ ctx: SelfTestContext) {
        let url = RadioURL.normalize("http://radio.example.com:8000/live")!
        let track = Track(radio: url)
        ctx.check("电台-模型-类型与去重键",
                  track.isRadio && track.formatLabel == "网络电台"
                    && track.identityKey == url.absoluteString
                    && track.fileName == "radio.example.com:8000/live",
                  "fmt=\(track.formatLabel) key=\(track.identityKey)")
        ctx.check("电台-模型-没有文件大小与时长",
                  track.fileSize == 0 && track.duration == 0,
                  "size=\(track.fileSize) dur=\(track.duration)")
        let lines = track.propertyLines
        ctx.check("电台-属性面板讲地址与直播",
                  lines.contains { $0.0 == "地址" && $0.1 == url.absoluteString }
                    && lines.contains { $0.0 == "时长" && $0.1.contains("直播") }
                    && !lines.contains { $0.0 == "路径" },
                  lines.map { $0.0 }.joined(separator: "/"))

        let p = ctx.player
        p.clearPlaylist()
        let invalid = p.addRadio("http://")
        ctx.check("电台-坏地址给人话",
                  invalid?.contains("http") == true && p.playlist.isEmpty, invalid ?? "nil")
        let first = p.addRadio("radio.example.com/live", playNow: false)
        let again = p.addRadio("http://radio.example.com/live", playNow: false)
        ctx.check("电台-入表并去重",
                  first == nil && again == nil && p.playlist.count == 1
                    && p.playlist.tracks[0].isRadio,
                  "n=\(p.playlist.count) note=\(again ?? "nil")")
        p.clearPlaylist()
    }

    // MARK: - 存档

    private func checkArchive(_ ctx: SelfTestContext) {
        let url = RadioURL.normalize("https://stream.example.org:9443/aac")!
        let restored = LibraryStore.tracks(fromArchiveEntries: [url.absoluteString])
        ctx.check("电台-存档往返认得它",
                  restored.count == 1 && restored[0].isRadio
                    && restored[0].url.absoluteString == url.absoluteString,
                  "n=\(restored.count)")
        // 电台行和文件行混在存档里：文件不在盘上照旧掉队，电台必须留下
        let mixed = LibraryStore.tracks(fromArchiveEntries: [
            url.absoluteString, "/nowhere/gone.mp3",
        ])
        ctx.check("电台-存档混排只丢真缺的文件",
                  mixed.count == 1 && mixed[0].isRadio, "n=\(mixed.count)")
    }

    // MARK: - 歌单（m3u）

    private func checkPlaylist(_ ctx: SelfTestContext) {
        let dir = tempDir(ctx)
        let url = RadioURL.normalize("http://radio.example.com:8000/live")!
        let list = Playlist()
        let station = Track(radio: url)
        station.title = "示例电台"
        list.add(station)
        let m3u = dir.appendingPathComponent("radio.m3u")
        let ok = list.exportAsM3U(to: m3u)
        let text = (try? String(contentsOf: m3u, encoding: .utf8)) ?? ""
        ctx.check("电台-m3u 写完整地址",
                  ok && text.contains(url.absoluteString) && text.contains("#EXTINF:-1,示例电台"),
                  text.replacingOccurrences(of: "\n", with: " | "))
        let back = LibraryStore.importURLs([m3u]).tracks
        ctx.check("电台-m3u 往返台名不丢",
                  back.count == 1 && back[0].isRadio && back[0].title == "示例电台",
                  "n=\(back.count) title=\(back.first?.title ?? "nil")")

        // 混排：本地 → 电台 → 本地，顺序不能乱（保序是 m3u 的全部意义）
        let wav = dir.appendingPathComponent("local.wav")
        _ = ctx.writeWave(wav, sampleRate: 44_100, channels: 2, bits: 16, freqs: [440, 660])
        let mixedText = """
        #EXTM3U
        #EXTINF:-1,本地一
        \(wav.path)
        #EXTINF:-1,网络台
        http://radio.example.com:8000/live
        #EXTINF:-1,本地二
        \(wav.path)
        """
        let mixedURL = dir.appendingPathComponent("mixed.m3u")
        _ = try? mixedText.write(to: mixedURL, atomically: true, encoding: .utf8)
        let mixed = LibraryStore.importURLs([mixedURL]).tracks
        ctx.check("电台-m3u 与本地文件混排保序",
                  mixed.count == 2 && !mixed[0].isRadio && mixed[1].isRadio
                    && mixed[1].title == "网络台",
                  "n=\(mixed.count) kinds=\(mixed.map { $0.isRadio ? "电台" : "文件" })")
    }

    // MARK: - 列表显示

    private func checkDurationColumn(_ ctx: SelfTestContext) {
        let dir = tempDir(ctx)
        let wav = dir.appendingPathComponent("row.wav")
        guard ctx.writeWave(wav, sampleRate: 44_100, channels: 2, bits: 16,
                            freqs: [440, 660]) else {
            ctx.check("电台-时长列写直播", false, "写不出素材")
            return
        }
        let p = ctx.player
        p.clearPlaylist()
        _ = p.addFiles([wav])
        _ = p.addRadio("http://radio.example.com:8000/live", playNow: false)
        let view = ctx.main.playlistView
        // 元数据是异步读的：固定等 0.1 s 在忙机器上会赶不上（那时列里还是占位的省略号）
        _ = ctx.waitUntil(3.0) { view.durationText(row: 0)?.contains(":") == true }
        let radioText = view.durationText(row: 1)
        let fileText = view.durationText(row: 0)
        ctx.check("电台-时长列写直播", radioText == "直播", "text=\(radioText ?? "nil")")
        ctx.check("电台-本地曲目仍写时间",
                  fileText?.contains(":") == true, "text=\(fileText ?? "nil")")
        ctx.check("电台-工具条八键（添加/电台/删除/列表/排序/查找/编辑/模式）",
                  ctx.main.playlistPanel.toolbarButtonCount == 8,
                  "count=\(ctx.main.playlistPanel.toolbarButtonCount)")
        p.clearPlaylist()
    }

    // MARK: - 列表分组（网络电台 / 最近听的台）

    /// 电台在左栏单独一组，但内容不另存一份：它就是 [默认] 里电台地址的投影。
    /// 「最近听的台」是档案——台被删出列表也还能从这一页点回来听
    private func checkGroups(_ ctx: SelfTestContext) {
        let p = ctx.player
        let panel = ctx.main.playlistPanel
        let dir = tempDir(ctx)
        p.clearPlaylist()
        p.groups.clear(.recentRadio)
        let wav = dir.appendingPathComponent("group.wav")
        _ = ctx.writeWave(wav, sampleRate: 44_100, channels: 2, bits: 16, freqs: [440, 660])
        _ = p.addFiles([wav])
        _ = p.addRadio("http://a.example.com/live", playNow: false)
        _ = p.addRadio("http://b.example.com/live", playNow: false)
        ctx.pump(0.1)

        ctx.check("电台-左栏五组与顺序",
                  panel.groupItemCount == GroupKind.allCases.count
                    && PlaylistPanelController.groupNames
                        == ["[默认]", "网络电台", "最近听的台", "最近播放", "我的收藏"],
                  PlaylistPanelController.groupNames.joined(separator: "/"))
        // 面板不跟着组数长高：五个组挤进那一列，最后一行不能被裁掉
        ctx.check("电台-五个组都露在左栏里没被裁", panel.groupsFitInWell,
                  "n=\(panel.groupItemCount)")

        panel.clickGroup(at: GroupKind.radio.rawValue)
        ctx.check("电台-电台页只投影台不投影歌",
                  p.activeGroup == .radio && p.playlist.count == 2
                    && p.playlist.tracks.allSatisfy { $0.isRadio }
                    && panel.infoText.contains("个台"),
                  "list=\(p.playlist.count) info=\(panel.infoText)")
        // 目视凭据：这一页只列台，统计行写的是「几个台」，左栏五个组都在
        ctx.snapshot(panel.window, named: "shot_group_radio")

        // 在这一页删台就是真删台：切回 [默认] 它不该又冒出来，本地那首也不跟着遭殃
        p.removeTracks(at: IndexSet(integer: 0))
        panel.clickGroup(at: GroupKind.main.rawValue)
        ctx.check("电台-电台页删台是真删且不伤本地歌",
                  p.playlist.count == 2 && !p.playlist.tracks[0].isRadio
                    && p.playlist.tracks.filter { $0.isRadio }.count == 1,
                  "list=\(p.playlist.count) 台=\(p.playlist.tracks.filter { $0.isRadio }.count)")

        // 这一页清空只删台：历史是历史，不跟着一起冲
        if let station = p.playlist.tracks.first(where: { $0.isRadio }) {
            p.groups.recordRadioPlay(station)
        }
        panel.clickGroup(at: GroupKind.radio.rawValue)
        p.clearPlaylist()
        ctx.check("电台-电台页清空只删台不冲历史",
                  p.activeGroup == .radio && p.playlist.isEmpty && panel.showsEmptyHint
                    && p.groups.recentRadioKeys.count == 1,
                  "list=\(p.playlist.count) 历史=\(p.groups.recentRadioKeys.count)")
        panel.clickGroup(at: GroupKind.main.rawValue)
        ctx.check("电台-清空电台后本地歌还在",
                  p.playlist.count == 1 && !p.playlist.tracks[0].isRadio,
                  "list=\(p.playlist.count)")

        // 「最近听的台」是档案：那个台早就被删出列表了，这一页还列得出它
        panel.clickGroup(at: GroupKind.recentRadio.rawValue)
        ctx.check("电台-最近听的台列得出没在列表里的台",
                  p.activeGroup == .recentRadio && p.playlist.count == 1
                    && p.playlist.tracks[0].isRadio
                    && p.playlist.tracks[0].url.absoluteString == "http://b.example.com/live",
                  "list=\(p.playlist.count) url=\(p.playlist.tracks.first?.url.absoluteString ?? "nil")")

        // 记账：新的在前、同一个台重听只挪位置、超过上限丢最旧的，本地歌不掺进来
        p.groups.clear(.recentRadio)
        var stations: [Track] = []
        for i in 0..<25 {
            let t = Track(radio: URL(string: "http://s\(i).example.com/live")!)
            p.groups.recordRadioPlay(t)
            stations.append(t)
        }
        p.groups.recordRadioPlay(Track(url: wav))
        ctx.check("电台-台历史新音在前并截到上限",
                  p.groups.recentRadioKeys.count == TrackGroups.recentRadioLimit
                    && p.groups.recentRadioKeys.first == stations[24].identityKey
                    && !p.groups.recentRadioKeys.contains(stations[0].identityKey)
                    && !p.groups.recentRadioKeys.contains(wav.path),
                  "n=\(p.groups.recentRadioKeys.count) 首=\(p.groups.recentRadioKeys.first ?? "nil")")
        p.groups.recordRadioPlay(stations[10])
        ctx.check("电台-重听同一个台只挪位置不重复记",
                  p.groups.recentRadioKeys.count == TrackGroups.recentRadioLimit
                    && p.groups.recentRadioKeys.first == stations[10].identityKey
                    && p.groups.recentRadioKeys.filter { $0 == stations[10].identityKey }.count == 1,
                  "n=\(p.groups.recentRadioKeys.count)")

        // 停在台这一页存档：trackPaths 写的仍是 [默认] 留档，台历史单独一份
        p.persistNow()
        let saved = LibraryStore.load()
        ctx.check("电台-台历史进存档且不冲掉默认列表",
                  saved.recentRadioKeys.count == TrackGroups.recentRadioLimit
                    && saved.trackPaths == [wav.path],
                  "paths=\(saved.trackPaths.count) 历史=\(saved.recentRadioKeys.count)")
        // 下一次启动从这个档案还原：页面跟着档案变，不是跟着上一次内存里的样子
        p.groups.restore(recent: saved.recentKeys, favorites: saved.favoriteKeys,
                         recentRadios: saved.recentRadioKeys)
        panel.clickGroup(at: GroupKind.main.rawValue)
        panel.clickGroup(at: GroupKind.recentRadio.rawValue)
        ctx.check("电台-存档还原后台历史又能列出来",
                  p.playlist.count == TrackGroups.recentRadioLimit
                    && p.playlist.tracks.allSatisfy { $0.isRadio },
                  "list=\(p.playlist.count)")

        // 用户手上那份存档是上一版写的，里面没有台历史这个字段：整档不能因此解不出来——
        // 解不出来就回退成空默认值，等于起一次应用把播放列表与设置一起冲掉
        let legacyJSON = "{\"trackPaths\":[\"\(wav.path)\",\"http://a.example.com/live\"],\"volume\":0.42}"
        let legacy = try? JSONDecoder().decode(AppState.self, from: Data(legacyJSON.utf8))
        ctx.check("电台-旧存档没有台历史字段也能整档解开",
                  legacy?.trackPaths.count == 2 && legacy?.volume == 0.42
                    && legacy?.recentRadioKeys.isEmpty == true
                    && LibraryStore.tracks(fromArchiveEntries: legacy?.trackPaths ?? []).count == 2,
                  "paths=\(legacy?.trackPaths.count ?? -1) 台历史=\(legacy?.recentRadioKeys.count ?? -1)")

        panel.clickGroup(at: GroupKind.main.rawValue)
        p.groups.clear(.recentRadio)
        p.clearPlaylist()
    }

    // MARK: - 切台淡出（纯逻辑）

    /// 音频图上的音量听不见，但「分几格、每格降多少」是纯算术，离线就能算清；
    /// 顺带确认真拉流那条淡出有凭据可读（`radioFadeCurve`）
    private func checkFadeMath(_ ctx: SelfTestContext) {
        var fade = RadioFade(steps: AudioEngine.radioFadeSteps)
        let open = fade.gain
        var curve: [Float] = []
        while !fade.finished { curve.append(fade.advance()) }
        let even = curve.enumerated().allSatisfy { i, g in
            abs(Double(g) - (1.0 - Double(i + 1) / Double(AudioEngine.radioFadeSteps))) < 1e-6
        }
        ctx.check("电台-淡出从全通逐格线性降到静音",
                  open == 1 && curve.count == AudioEngine.radioFadeSteps
                    && curve.last == 0 && even,
                  curve.map { String(format: "%.2f", $0) }.joined(separator: "→"))
        var one = RadioFade(steps: 1)
        let zero = RadioFade(steps: 0)
        ctx.check("电台-淡出格数兜底（1 格就静音、0 格不算除零）",
                  one.advance() == 0 && one.finished && one.steps == 1
                    && zero.steps == 1 && zero.gain == 1,
                  "steps=\(one.steps)/\(zero.steps)")
        one.reset()
        ctx.check("电台-淡出复位后重新从全通开始（能一段一段接着淡）",
                  one.gain == 1 && !one.finished)

        // 没声音时不能白等 120 ms：切台/暂停该当场就断
        let e = ctx.player.engine
        var landed = false
        e.fadeOutRadioStream(reason: "自检（没有流在播）") { landed = true }
        ctx.check("电台-没声音时切台不白等淡出",
                  landed && !e.isFadingRadio && e.radioFadeCurve.isEmpty,
                  "isRadio=\(e.isRadio) 有声=\(e.radioHasSound) 淡出中=\(e.isFadingRadio)")
        ctx.check("电台-淡出短到听不出、又够格子抹平台阶",
                  AudioEngine.radioFadeSeconds > 0 && AudioEngine.radioFadeSeconds <= 0.2
                    && AudioEngine.radioFadeSteps >= 4 && e.radioFadeVolume == 1,
                  "\(Int(AudioEngine.radioFadeSeconds * 1000))ms/\(AudioEngine.radioFadeSteps) 格"
                    + " 音量=\(e.radioFadeVolume)")
    }

    // MARK: - ICY 元数据

    private func checkICY(_ ctx: SelfTestContext) {
        // 4 字节音频 + 1 字节长度(1 → 16 字节) + 16 字节元数据 + 4 字节音频
        var meta = Data("StreamTitle='夏天的风';".utf8)
        // 长度字节 = 元数据块数（1 块 = 16 字节），不够就补 0
        let blocks = max(1, (meta.count + 15) / 16)
        meta.append(Data(repeating: 0, count: blocks * 16 - meta.count))
        var wire = Data([1, 2, 3, 4])
        wire.append(UInt8(blocks))
        wire.append(meta)
        wire.append(contentsOf: [5, 6, 7, 8])
        var demux = ICYDemuxer(metaInt: 4)
        let got = demux.demux(wire)
        ctx.check("电台-ICY 拆出纯音频", got.audio == Data([1, 2, 3, 4, 5, 6, 7, 8]),
                  "audio=\(got.audio as NSData)")
        ctx.check("电台-ICY 读出台名", got.title == "夏天的风", got.title ?? "nil")

        // 跨块：拆包状态必须留到下一块，否则音频会错位
        var split = ICYDemuxer(metaInt: 4)
        let head = split.demux(Data([9, 9]))
        let tail = split.demux(Data([9, 9, 0, 8, 8, 8, 8]))   // 0 = 这一段没有元数据
        ctx.check("电台-ICY 跨块续接",
                  head.audio == Data([9, 9]) && tail.audio == Data([9, 9, 8, 8, 8, 8]),
                  "head=\(head.audio.count)B tail=\(tail.audio as NSData)")
        ctx.check("电台-ICY 空标题当没有",
                  ICYDemuxer.parseTitle(Data("StreamTitle='';".utf8)) == nil)
    }

    // MARK: - 重连与失败归类（纯逻辑）

    private func checkRetry(_ ctx: SelfTestContext) {
        let delays = [1, 2, 3, 9].map { RadioPlayer.retryDelay(attempt: $0) }
        ctx.check("电台-重连退避 2/4/8 封顶", delays == [2, 4, 8, 8], "\(delays)")
        ctx.check("电台-状态文案说人话",
                  RadioPlayer.State.connecting.displayText.contains("连接")
                    && RadioPlayer.State.reconnecting(attempt: 2).displayText.contains("第 2 次")
                    && RadioPlayer.State.playing.displayText == "直播中"
                    && RadioPlayer.State.fallingBack.displayText.contains("明文")
                    && RadioPlayer.State.failed("连不上").displayText == "连不上",
                  RadioPlayer.State.reconnecting(attempt: 2).displayText)

        // 证书不匹配（真实遇到过：pianosolo.streamguys.net 的证书签给 *.streamguys1.com）
        // 重连不会变好，得换明文再试一次；退避 5 次只是白等 30 秒
        let secure = URL(string: "https://pianosolo.streamguys.net/live")!
        let clear = URL(string: "http://pianosolo.streamguys.net/live")!
        let certErr = URLError(.serverCertificateUntrusted,
                               userInfo: [NSURLErrorFailingURLErrorKey: secure])
        let demoted = RadioPlayer.classify(certErr, trying: secure)
        var plainURL: URL?
        var plainWhy = ""
        if case .downgrade(let u, let why) = demoted { plainURL = u; plainWhy = why }
        ctx.check("电台-证书不可信→换明文重连（只试 https）",
                  plainURL == clear && plainWhy.contains("证书")
                    && RadioPlayer.classify(certErr, trying: URL(string: "http://a/b")!)
                        == .fatal("HTTPS 证书校验没过；这台没给出能用的明文地址"),
                  "\(demoted) 原因=\(plainWhy.isEmpty ? "nil" : plainWhy)")
        let alternates: [(String, String?)] = [
            ("https://a.example.com/live", "http://a.example.com/live"),
            ("https://a.example.com:443/live", "http://a.example.com/live"),
            ("http://a.example.com/live", nil),
            ("https://a.example.com:8443/live", nil),   // 明文口在哪不确定，不猜
        ]
        let wrongAlt = alternates.filter {
            RadioPlayer.plaintextAlternate(of: URL(string: $0.0)!)?.absoluteString != $0.1
        }
        ctx.check("电台-明文地址只从默认 https 口推", wrongAlt.isEmpty,
                  wrongAlt.isEmpty ? "4 例" : wrongAlt.map { "\($0.0) → \($0.1 ?? "nil")" }
                    .joined(separator: " / "))

        let fatal: [(URLError.Code, String)] = [
            (.unsupportedURL, "地址"), (.badURL, "地址"), (.cannotParseResponse, "应答"),
        ]
        let misjudged = fatal.filter { reason in
            guard case .fatal(let why) = RadioPlayer.classify(URLError(reason.0), trying: secure) else {
                return true
            }
            return !why.contains(reason.1)
        }
        ctx.check("电台-重连不会自愈的错当场给人话", misjudged.isEmpty,
                  misjudged.isEmpty ? "3 例" : "误判成重连：\(misjudged)")

        let transient: [URLError.Code] = [.timedOut, .networkConnectionLost, .cannotFindHost,
                                          .cannotConnectToHost, .notConnectedToInternet]
        let overreactions = transient.filter {
            if case .transient = RadioPlayer.classify(URLError($0), trying: secure) { return false }
            return true
        }
        ctx.check("电台-网络层面的断线才走退避", overreactions.isEmpty,
                  overreactions.isEmpty ? "5 例走重连" : "被当成彻底失败：\(overreactions)")

        let codes: [(Int, String?)] = [(200, nil), (204, nil), (302, "transient"), (404, "transient"),
                                       (408, "transient"), (429, "transient"), (503, "transient"),
                                       (401, "fatal"), (403, "fatal"), (410, "fatal"),
                                       (418, "fatal")]
        let badCodes = codes.filter { code, want in
            let got = RadioPlayer.classify(status: code).map { if case .fatal = $0 { "fatal" } else { "transient" } }
            return got != want
        }
        ctx.check("电台-HTTP 状态码分得清能不能重连", badCodes.isEmpty,
                  badCodes.isEmpty ? "11 例" : "分错：\(badCodes.map { "\($0.0)→\($0.1 ?? "可听")" })")
    }

    // MARK: - 流式解码

    private func checkDecoder(_ ctx: SelfTestContext) {
        let dir = tempDir(ctx)
        let wav = dir.appendingPathComponent("streamsrc.wav")
        let aac = dir.appendingPathComponent("stream.aac")
        guard ctx.writeWave(wav, sampleRate: 44_100, channels: 2, bits: 16,
                            freqs: [440, 660]) else {
            ctx.check("电台-解码器吃 AAC 流", false, "写不出素材")
            return
        }
        // ADTS AAC：流式电台最常见的码流之一；afconvert 现造，不依赖外部文件
        if !ctx.fm.fileExists(atPath: aac.path) {
            _ = ctx.convert(source: wav, fileFmt: "adts", dataFmt: "aac", to: aac)
        }
        guard let data = try? Data(contentsOf: aac), !data.isEmpty else {
            ctx.check("电台-解码器吃 AAC 流", false, "本机 afconvert 造不出 ADTS AAC")
            return
        }

        var info: RadioStreamDecoder.Info?
        var outFormat: AVAudioFormat?
        var frames: Int64 = 0
        var peak: Float = 0
        var notes: [String] = []
        let decoder = RadioStreamDecoder()
        decoder.onInfo = { i, f in
            info = i
            outFormat = f
        }
        decoder.onFailure = { reason in notes.append(reason) }
        decoder.onPCM = { buffer in
            frames += Int64(buffer.frameLength)
            guard let data = buffer.floatChannelData else { return }
            for ch in 0..<Int(buffer.format.channelCount) {
                for i in 0..<Int(buffer.frameLength) {
                    peak = max(peak, abs(data[ch][i]))
                }
            }
        }
        ctx.check("电台-解码器打得开", decoder.open())

        // 按 1 KB 切着喂：网卡就是这样一块一块来的，跨包边界不能出错
        var offset = 0
        while offset < data.count {
            let n = min(1024, data.count - offset)
            decoder.feed(data.subdata(in: offset..<(offset + n)))
            offset += n
        }
        decoder.close()

        ctx.check("电台-解码器认 AAC 流",
                  info?.sampleRate == 44_100 && info?.channels == 2 && !(info?.codec.isEmpty ?? true),
                  "sr=\(Int(info?.sampleRate ?? 0)) ch=\(info?.channels ?? 0) codec=\(info?.codec ?? "nil")"
                    + " bitrate=\(info?.bitRateKbps ?? 0)k")
        // 一包 ADTS AAC = 1024 个采样：帧数对不上包数就说明中途丢包了
        //（曾经整批塞进压缩缓冲，500 包只解出前 9 包，这里会当场变红）
        let allFrames = frames >= Int64(decoder.packetsSeen) * 1000
        ctx.check("电台-解码器吐出立体声非静音 PCM",
                  allFrames && peak > 0.01
                    && outFormat?.channelCount == 2
                    && outFormat?.commonFormat == .pcmFormatFloat32
                    && notes.isEmpty,
                  "frames=\(frames) packets=\(decoder.packetsSeen) peak=\(String(format: "%.3f", peak))"
                    + " fmt=\(outFormat.map { "\(Int($0.sampleRate))Hz/\($0.channelCount)ch" } ?? "nil")"
                    + (notes.isEmpty ? "" : " 错=\(notes.prefix(2))"))
        ctx.check("电台-解码器一包不丢",
                  decoder.packetsSeen > 0 && frames == decoder.framesOut,
                  "frames=\(frames) out=\(decoder.framesOut) packets=\(decoder.packetsSeen)")
    }

    // MARK: - 真拉流（选做）

    /// 只有设了 `TTPLAYER_RADIO_URL` 才真出网。
    ///
    /// 回归机器未必有网，也不该因为一次 DNS 超时就整套变红，所以这一段默认不跑。
    /// 手动验法（本地起一个 ICY 服务器也能验，见文档）：
    /// `TTPLAYER_RADIO_URL=http://127.0.0.1:8731/live zsh scripts/selftest.sh radio`
    private func checkLiveStream(_ ctx: SelfTestContext) {
        guard let raw = ProcessInfo.processInfo.environment["TTPLAYER_RADIO_URL"],
              let url = RadioURL.normalize(raw) else { return }
        let p = ctx.player
        p.clearPlaylist()
        let note = p.addRadio(raw)          // 加进来就会开声（与界面上点“添加”一致）
        // 走整条链路（控制器 → 引擎 → playerNode），时基在走才叫真出声
        let heard = ctx.waitUntil(12) { p.isPlaying && p.currentTime > 0.3 }
        let onAir = p.isRadio
        let state = p.radioStateText
        let now = p.radioNowPlaying
        let elapsed = p.currentTime
        // 频谱是这条通路的证词：PCM 真过了 EQ/mixer，bars 才会亮
        let lit = p.engine.spectrum.bars.contains { $0 > 0.005 }
        // 暂停即断流（直播不补放暂停期间的内容）：时钟也得停下，
        // 否则“恢复”只是时钟又在走而已（实测过这个假象：不重连也能“续上”）
        let beforePause = p.currentTime
        p.togglePlay()
        let paused = ctx.waitUntil(3) { !p.isPlaying }
        let frozen = p.currentTime
        ctx.pump(1.0)
        let held = abs(p.currentTime - frozen) < 0.05
        p.togglePlay()
        // 得等 RadioPlayer 真报「直播中」（只有新流解出 PCM 才会到这个态）
        let resumed = ctx.waitUntil(12) {
            p.isPlaying && p.radioStateText == "直播中" && p.currentTime > beforePause + 0.3
        }
        // 目视凭据：显示区写「正在播：…」、时长写「直播」、频谱在走
        ctx.snapshot(ctx.main.window, named: "shot_radio_main")
        // 切台淡出：从电台切到本地文件，得先把旧流逐格压到静音再断。
        // 凭据是走过的格子而不是采样时刻：Timer 抖一下就会把好行为误判成坏行为
        let fadeWav = tempDir(ctx).appendingPathComponent("fade.wav")
        _ = ctx.writeWave(fadeWav, sampleRate: 44_100, channels: 2, bits: 16, freqs: [440, 660])
        _ = p.addFiles([fadeWav], playNow: false)
        if let file = p.playlist.tracks.last(where: { !$0.isRadio }) {
            p.play(track: file)
        }
        let stepped = ctx.waitUntil(2) { p.engine.radioFadeCurve.count >= AudioEngine.radioFadeSteps }
        let toFile = ctx.waitUntil(12) { !p.isRadio && p.isPlaying && p.currentTime > 0.2 }
        let curve = p.engine.radioFadeCurve
        ctx.check("电台-切台先淡出再换流且换完不是静音",
                  stepped && toFile && curve.last == 0 && p.engine.radioFadeVolume == 1,
                  "格子=\(curve.map { String(format: "%.2f", $0) }.joined(separator: "→"))"
                    + " 换到文件=\(toFile ? "有声" : "没声") 音量=\(p.engine.radioFadeVolume)")
        p.stop()
        p.clearPlaylist()
        ctx.check("电台-真拉流有声并进 EQ/频谱（\(url.host ?? "")）",
                  note == nil && heard && onAir && state == "直播中" && lit && paused && held && resumed,
                  "t=\(String(format: "%.2f", elapsed))s state=\(state) 频谱=\(lit ? "亮" : "黑")"
                    + " 暂停=\(paused ? "断流" : "没停") 冻结于\(String(format: "%.2f", frozen))s"
                    + " 暂停期间\(held ? "没走表" : "仍在走表")"
                    + " 恢复=\(resumed ? "重连上并出声" : "没声")"
                    + " 正在播=\(now.isEmpty ? "nil" : now) note=\(note ?? "nil")")
    }

    // MARK: - 工具

    /// 素材目录：造出来的东西不进 testlib，跑完也不污染下一次的曲库扫描
    private func tempDir(_ ctx: SelfTestContext) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ttplayer-radio", isDirectory: true)
        try? ctx.fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
