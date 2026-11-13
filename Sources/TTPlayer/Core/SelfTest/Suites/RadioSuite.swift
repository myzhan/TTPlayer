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
        checkRadioAllFailStops(ctx)
        checkDecoder(ctx)
        checkStations(ctx)
        checkBuiltinStations(ctx)
        checkQuality(ctx)
        checkLocalStream(ctx)
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
        ctx.check("电台-工具条九键（添加/电台/删除/列表/排序/查找/编辑/模式/队列）",
                  ctx.main.playlistPanel.toolbarButtonCount == 9,
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

        // 左栏现在是「固定几页 + 可变数量的歌单页」：固定页的次序不能因为建了歌单而变
        let titles = panel.groupTitles
        let fixed = GroupKind.fixedPages.map { $0.name }
        ctx.check("电台-左栏固定页与顺序",
                  Array(titles.prefix(fixed.count)) == fixed && panel.groupItemCount >= fixed.count,
                  titles.joined(separator: "/"))
        // 面板不跟着组数长高：固定页挤不进左栏就是布局坏了（歌单页走滚动）
        ctx.check("电台-固定页都露在左栏里没被裁", panel.fixedGroupsFitInWell,
                  "n=\(panel.groupItemCount)")

        panel.clickGroup(.radio)
        ctx.check("电台-电台页只投影台不投影歌",
                  p.activeGroup == .radio && p.playlist.count == 2
                    && p.playlist.tracks.allSatisfy { $0.isRadio }
                    && panel.infoText.contains("个台"),
                  "list=\(p.playlist.count) info=\(panel.infoText)")
        // 目视凭据：这一页只列台，统计行写的是「几个台」，固定页全部都在
        ctx.snapshot(panel.window, named: "shot_group_radio")

        // 在这一页删台就是真删台：切回 [默认] 它不该又冒出来，本地那首也不跟着遭殃
        p.removeTracks(at: IndexSet(integer: 0))
        panel.clickGroup(.main)
        ctx.check("电台-电台页删台是真删且不伤本地歌",
                  p.playlist.count == 2 && !p.playlist.tracks[0].isRadio
                    && p.playlist.tracks.filter { $0.isRadio }.count == 1,
                  "list=\(p.playlist.count) 台=\(p.playlist.tracks.filter { $0.isRadio }.count)")

        // 这一页清空只删台：历史是历史，不跟着一起冲
        if let station = p.playlist.tracks.first(where: { $0.isRadio }) {
            p.groups.recordRadioPlay(station)
        }
        panel.clickGroup(.radio)
        p.clearPlaylist()
        ctx.check("电台-电台页清空只删台不冲历史",
                  p.activeGroup == .radio && p.playlist.isEmpty && panel.showsEmptyHint
                    && p.groups.recentRadioKeys.count == 1,
                  "list=\(p.playlist.count) 历史=\(p.groups.recentRadioKeys.count)")
        panel.clickGroup(.main)
        ctx.check("电台-清空电台后本地歌还在",
                  p.playlist.count == 1 && !p.playlist.tracks[0].isRadio,
                  "list=\(p.playlist.count)")

        // 「最近听的台」是档案：那个台早就被删出列表了，这一页还列得出它
        panel.clickGroup(.recentRadio)
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
        panel.clickGroup(.main)
        panel.clickGroup(.recentRadio)
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

        panel.clickGroup(.main)
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
        // 自检为了不把全量拖长，拿真实时钟等退避的地方只等出厂档位的 1/8。这一条钉住两件事：
        // 出厂 `retryDelay` 没被污染，压的只是排下去的那一层（用户那边仍然是 2/4/8 s）
        ctx.check("电台-自检只压排下去的等待，不压出厂档位",
                  RadioPlayer.retryScale == 0.125
                    && RadioPlayer.retryWait(attempt: 3) == RadioPlayer.retryDelay(attempt: 3) / 8,
                  "scale=\(RadioPlayer.retryScale) 第 3 档排下去=\(RadioPlayer.retryWait(attempt: 3))s")
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

    // MARK: - 整串台都连不上要收手（跨台失败计数）

    /// `.failed` 是 RadioPlayer 退避到上限之后的终态：控制层凭它跳下一台。
    /// 每一台都失败时这个周期必须能攒到「上下文里每条都试过」，不然会在列表里
    /// 无限打转。这里注入终态事件而不是真等五次退避：要验的是跨台计数，不是网络。
    /// 地址用不可路由的内网段：真连那一路只会在后台慢慢超时，也不会插进这几步同步断言
    private func checkRadioAllFailStops(_ ctx: SelfTestContext) {
        let p = ctx.player
        let savedMode = p.playMode
        let savedList = p.playlist.tracks
        p.stop()
        p.clearPlaylist()
        let r1 = Track(radio: URL(string: "http://10.255.255.1:81/a")!)
        let r2 = Track(radio: URL(string: "http://10.255.255.1:82/b")!)
        guard p.addTracks([r1, r2]) == 2 else {
            ctx.check("电台-全失败素材能入表", false); return
        }
        p.setMode(.listLoop)
        p.playRowAt(0)
        _ = ctx.waitUntil(4) { p.isRadio && p.currentTrack?.identityKey == r1.identityKey }
        // 第一条失败：该跳到第二条（这一步本身不能把周期清掉）
        p.engine.onRadioState?(.failed("自检注入"))
        let ontoSecond = p.currentTrack?.identityKey == r2.identityKey
        // 两条都试过（上界 = 队列长度 2）：到这里就该收手，不能再绕回第一条
        p.engine.onRadioState?(.failed("自检注入"))
        let stoppedAt = p.currentTrack?.identityKey
        let idx = p.queue.currentIndex
        p.engine.onRadioState?(.failed("自检注入"))
        ctx.check("电台-每台都连不上时在有限次后停下",
                  ontoSecond && stoppedAt == r2.identityKey && p.queue.currentIndex == idx
                    && !p.isPlaying,
                  "跳过第二条=\(ontoSecond) cur=\(p.currentTrack?.fileName ?? "nil") idx=\(String(describing: p.queue.currentIndex))")
        let stuck = p.queue.currentIndex
        let why = p.playbackProblem ?? ""
        ctx.check("电台-停下之后那句原因还在显示区",
                  why.contains("自检注入"), why)
        // 真连上过一次就得把周期归零：下一台失败时还能接着跳，而不是卡死在「已经全都试过」
        p.engine.onRadioState?(.playing)
        p.engine.onRadioState?(.failed("自检注入"))
        ctx.check("电台-连上过一次就把失败周期归零",
                  p.queue.currentIndex != stuck && p.currentTrack?.identityKey == r1.identityKey,
                  "cur=\(p.currentTrack?.fileName ?? "nil") idx=\(String(describing: p.queue.currentIndex))")
        // 用户重新点播也要能重开一轮：上一轮攒下的计数不能把这一次也拦死
        p.stop()
        p.play(track: r1)
        p.engine.onRadioState?(.failed("自检注入"))
        ctx.check("电台-手动重播重新开一轮失败周期",
                  p.currentTrack?.identityKey == r2.identityKey,
                  "cur=\(p.currentTrack?.fileName ?? "nil")")
        p.stop()
        p.clearPlaylist()
        p.setMode(savedMode)
        _ = p.addTracks(savedList)
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

    // MARK: - 台名、分类与改地址（F11）

    /// 台名按地址身份存、分类建/改名/删、台移进分类、改地址要把设置一起搬过去 ——
    /// 这些都是控制器与模型的真入口，不连网也能钉死。
    /// 电台档案是进程级单例：起手与收摊各擦一遍，否则换个顺序跑就时灵时不灵
    private func checkStations(_ ctx: SelfTestContext) {
        let p = ctx.player
        let view = ctx.main.playlistView
        let panel = ctx.main.playlistPanel
        let stations = p.radioStations
        let dir = tempDir(ctx)
        func trackOn(_ host: String) -> Track? { p.playlist.tracks.first { $0.url.host == host } }
        func radioKeysInMain() -> [String] { p.playlist.tracks.filter { $0.isRadio }.map { $0.identityKey } }
        func categoryRows() -> Int { p.groupLayout.filter { if case .radioCategory = $0 { return true }; return false }.count }

        func wipe() {
            p.stop()
            p.switchGroup(.main)
            p.clearPlaylist()
            p.groups.clear(.recentRadio)
            stations.restore(aliases: [:], categories: [], assigned: [:])
            ctx.pump(0.1)
        }
        wipe()
        let wav = dir.appendingPathComponent("stations.wav")
        guard ctx.writeWave(wav, sampleRate: 44_100, channels: 2, bits: 16, freqs: [440, 660]) else {
            ctx.check("电台-台名与分类写得出本地素材", false, "writeWave 失败")
            return
        }

        // MARK: 台名
        _ = p.addFiles([wav])
        _ = p.addRadio("http://a.example.com/live", playNow: false)
        _ = p.addRadio("http://b.example.com/live", playNow: false)
        ctx.pump(0.1)
        guard let a = trackOn("a.example.com"), let b = trackOn("b.example.com") else {
            ctx.check("电台-台名前提交两个台", false, "n=\(p.playlist.count)")
            return
        }
        let keyA = a.identityKey
        ctx.check("电台-台名-没起过名字的台按地址显示",
                  a.title == "a.example.com/live" && !stations.hasCustomName(for: a.url)
                    && stations.alias(for: keyA) == nil, "title=\(a.title)")
        ctx.check("电台-台名-自定义后列表这一行跟着改",
                  p.setRadioName(a, to: "城市之声") == nil
                    && stations.alias(for: keyA) == "城市之声"
                    && a.title == "城市之声" && stations.hasCustomName(for: a.url),
                  "title=\(a.title) alias=\(stations.alias(for: keyA) ?? "nil")")
        // 台名记在地址上而不是记在对象上：同地址新建的对象一出生就叫这个名字
        ctx.check("电台-台名-记在地址上（同址新建的条目一出生就是这个名字）",
                  Track(radio: a.url).title == "城市之声"
                    && stations.displayName(for: a.url) == "城市之声")
        _ = p.addRadio("http://a.example.com/live", playNow: false)
        ctx.check("电台-台名-相同地址复用条目不多塞一条",
                  p.playlist.count == 3
                    && p.playlist.tracks.filter { $0.url.host == "a.example.com" }.count == 1,
                  "n=\(p.playlist.count)")
        ctx.check("电台-台名-空名是取消自定义不是报错",
                  p.setRadioName(a, to: "  ") == nil && stations.alias(for: keyA) == nil
                    && a.title == "a.example.com/live" && !stations.hasCustomName(for: a.url))
        _ = p.setRadioName(a, to: "城市之声")
        ctx.check("电台-台名-全角空格也算空（中文用户敲的那个空格）",
                  p.setRadioName(a, to: "\u{3000} \u{3000}") == nil
                    && stations.alias(for: keyA) == nil)
        _ = p.setRadioName(a, to: String(repeating: "名", count: 80))
        ctx.check("电台-台名-超长截到上限不顶穿标题区",
                  stations.alias(for: keyA)?.count == RadioStations.aliasLimit,
                  "n=\(stations.alias(for: keyA)?.count ?? 0)")
        ctx.check("电台-台名-首尾空白去掉再存",
                  p.setRadioName(a, to: "  城市之声  ") == nil
                    && stations.alias(for: keyA) == "城市之声",
                  stations.alias(for: keyA) ?? "nil")
        ctx.check("电台-台名-本地文件不走这个入口（该用编辑标签）",
                  p.setRadioName(Track(url: wav), to: "不行")?.contains("不是电台") == true)

        // MARK: 分类建与改名
        ctx.check("电台-分类-名字空就不建（不产出看不见的页）",
                  p.createRadioCategory(named: "   ") == nil && stations.isEmpty)
        guard let pop = p.createRadioCategory(named: "通勤") else {
            ctx.check("电台-分类-建得出一张", false, "返回 nil"); return
        }
        ctx.check("电台-分类-建出来左栏多一行且正看着它",
                  panel.groupTitles.contains("通勤") && p.activeGroup == .radioCategory(pop.id)
                    && stations.count == 1, "titles=\(panel.groupTitles)")
        let dup = p.createRadioCategory(named: "通勤")
        ctx.check("电台-分类-同名自动区分并把实际用的名说出来",
                  dup?.note?.contains("已经有叫") == true
                    && dup.flatMap { stations.name(of: $0.id) } == "通勤 (2)",
                  "note=\(dup?.note ?? "nil")")
        ctx.check("电台-分类-全角空格不算名字（与歌单同一套规矩）",
                  p.createRadioCategory(named: "\u{3000}") == nil)
        let long = p.createRadioCategory(named: String(repeating: "分", count: 60))
        ctx.check("电台-分类-名字截到上限（左栏那一列只有 110pt）",
                  long.flatMap { stations.name(of: $0.id) }?.count == RadioStations.nameLimit,
                  "n=\(long.flatMap { stations.name(of: $0.id) }?.count ?? 0)")
        ctx.check("电台-分类-未分类是默认入口改不了名",
                  p.renameRadioCategory(id: RadioStations.uncategorizedID, to: "别的")?
                    .contains("改不了") == true
                    && stations.name(of: RadioStations.uncategorizedID) == "未分类电台")
        ctx.check("电台-分类-未分类删不掉且左栏永远有这一行",
                  p.deleteRadioCategory(id: RadioStations.uncategorizedID) == nil
                    && panel.groupTitles.contains("未分类电台"))
        ctx.check("电台-分类-改名只动显示名不动 id 与归属",
                  p.moveRadios(keys: [keyA], to: pop.id) == nil
                    && p.renameRadioCategory(id: pop.id, to: "深夜") == nil
                    && stations.name(of: pop.id) == "深夜"
                    && stations.categoryID(of: keyA) == pop.id
                    && p.radioCount(in: pop.id) == 1,
                  "n=\(p.radioCount(in: pop.id))")
        ctx.check("电台-分类-改名后左栏那一行也跟着换名",
                  panel.groupTitles.contains("深夜") && !panel.groupTitles.contains("通勤"),
                  "titles=\(panel.groupTitles)")
        ctx.check("电台-分类-空名不能改名",
                  p.renameRadioCategory(id: pop.id, to: " ")?.contains("不能是空的") == true
                    && stations.name(of: pop.id) == "深夜")

        // MARK: 归属与投影
        p.switchGroup(.main)
        let both = [keyA, b.identityKey]
        ctx.check("电台-分类-一次移进两个台",
                  p.moveRadios(keys: both, to: pop.id) == nil && p.radioCount(in: pop.id) == 2,
                  "n=\(p.radioCount(in: pop.id))")
        panel.clickGroup(.radioCategory(pop.id))
        ctx.pump(0.2)
        ctx.check("电台-分类页只列归到这一类的台（统计行写个台）",
                  p.playlist.count == 2 && p.playlist.tracks.allSatisfy { $0.isRadio }
                    && panel.infoText.contains("个台"),
                  "list=\(p.playlist.count) info=\(panel.infoText)")
        ctx.snapshot(panel.window, named: "shot_radio_category")
        ctx.check("电台-分类-移回未分类是摘归属不是删台",
                  p.moveRadios(keys: [keyA], to: nil) == nil && p.radioCount(in: pop.id) == 1
                    && stations.categoryID(of: keyA) == nil && p.playlist.count == 1,
                  "分类里=\(p.radioCount(in: pop.id)) 本页=\(p.playlist.count)")
        ctx.check("电台-分类-台地址一条都没丢",
                  { panel.clickGroup(.radio)
                    return p.playlist.count == 2 && p.playlist.tracks.allSatisfy { $0.isRadio } }())
        ctx.check("电台-分类-移进一个已经不存在的分类时一个都不动",
                  p.moveRadios(keys: both, to: "已经不存在的ID")?.contains("已经不在了") == true
                    && p.radioCount(in: pop.id) == 1, "n=\(p.radioCount(in: pop.id))")

        // 在分类页删行 = 真删台（投影页只有一份地址）；台名与归属仍留在地址上，
        // 同地址再加回来时不用重新起名——这就是需求说的「复用既有条目与设置」
        panel.clickGroup(.radioCategory(pop.id))
        ctx.pump(0.2)
        guard let doomed = p.playlist.tracks.first else {
            ctx.check("电台-分类-删行前置：分类页有台", false, "本页空"); return
        }
        let doomedKey = doomed.identityKey
        _ = p.setRadioName(doomed, to: "要删的台")
        p.removeTracks(at: IndexSet(integer: 0))
        ctx.check("电台-分类-在分类页删行是真删台（切回全部台也没了）",
                  p.radioCount(in: pop.id) == 0
                    && { panel.clickGroup(.radio); return p.playlist.count == 1 }(),
                  "分类里=\(p.radioCount(in: pop.id))")
        ctx.check("电台-分类-删台不伤本地歌",
                  { panel.clickGroup(.main); return p.playlist.tracks.filter { !$0.isRadio }.count == 1 }())
        _ = p.addRadio(doomed.url.absoluteString, playNow: false)
        ctx.check("电台-分类-同址再加回来台名与归属还认得（复用设置）",
                  trackOn(doomed.url.host ?? "")?.title == "要删的台"
                    && stations.alias(for: doomedKey) == "要删的台"
                    && stations.categoryID(of: doomedKey) == pop.id,
                  "title=\(trackOn(doomed.url.host ?? "")?.title ?? "nil")")

        // MARK: 清空分类页与删分类
        panel.clickGroup(.radioCategory(pop.id))
        ctx.pump(0.2)
        let clearTitle = view.refreshContextMenu(over: 0)
            .first { $0.title.contains("清空分类") }?.title ?? ""
        ctx.check("电台-分类-清空那一行说清真删而不是移出",
                  clearTitle.contains("真删") && clearTitle.contains("不是移出分类"), clearTitle)
        _ = p.addRadio("http://d.example.com/live", playNow: false)
        guard let gym = p.createRadioCategory(named: "健身") else {
            ctx.check("电台-分类-建得出第二张", false); return
        }
        p.switchGroup(.main)
        _ = p.moveRadios(keys: ["http://d.example.com/live"], to: gym.id)
        panel.clickGroup(.radioCategory(pop.id))     // 这一页只有那个「要删的台」
        p.clearPlaylist()
        ctx.check("电台-分类-清空只删这一页那几台（别的分类与本地歌不动）",
                  p.playlist.isEmpty && panel.showsEmptyHint
                    && { panel.clickGroup(.radioCategory(gym.id)); return p.playlist.count == 1 }()
                    && { panel.clickGroup(.main); return p.playlist.count == 3
                        && p.playlist.tracks.filter { !$0.isRadio }.count == 1 }(),
                  "全部台=\(radioKeysInMain().count)")
        let aliasesBefore = stations.snapshotAliases
        _ = p.moveRadios(keys: [keyA], to: gym.id)
        p.switchGroup(.radioCategory(gym.id))
        let gone = p.deleteRadioCategory(id: gym.id)
        ctx.check("电台-分类-删除只掉壳：两个台回未分类、地址与台名都不动",
                  gone?.name == "健身" && gone?.moved == 2 && p.radioCount(in: gym.id) == 0
                    && stations.snapshotAliases == aliasesBefore
                    && stations.categoryID(of: keyA) == nil, "gone=\(gone?.moved ?? -1)")
        ctx.check("电台-分类-正在看这一页时删除会落到未分类页",
                  p.activeGroup == .radioCategory(RadioStations.uncategorizedID)
                    && p.playlist.count == 2, "group=\(p.activeGroup) n=\(p.playlist.count)")
        ctx.check("电台-分类-存档停在已删分类上只能回默认页",
                  { p.switchGroup(.radioCategory("已经不存在的ID")); return p.activeGroup == .main }())

        // MARK: 改地址（换身份就得把设置搬过去）
        p.switchGroup(.main)
        _ = p.addRadio("http://c.example.com/live", playNow: false)
        guard let c = trackOn("c.example.com") else {
            ctx.check("电台-改地址-前置：有个台", false); return
        }
        let oldKey = c.identityKey
        _ = p.setRadioName(c, to: "三台")
        guard let moveID = p.createRadioCategory(named: "搬得走")?.id else {
            ctx.check("电台-改地址-建得出分类", false); return
        }
        _ = p.moveRadios(keys: [oldKey], to: moveID)
        p.groups.recordRadioPlay(c)
        _ = p.toggleFavorite(c)
        p.switchGroup(.main)
        ctx.check("电台-改地址-非法地址不动任何东西",
                  p.updateRadioAddress(c, to: "ftp://x/y")?.contains("地址不对") == true
                    && stations.alias(for: oldKey) == "三台" && c.url.host == "c.example.com")
        ctx.check("电台-改地址-与列里另一个台撞地址先拒（台名与归属认不出谁是谁）",
                  p.updateRadioAddress(c, to: "http://a.example.com/live")?
                    .contains("已经有一条") == true && stations.alias(for: oldKey) == "三台")
        ctx.check("电台-改地址-一模一样的地址不用改",
                  p.updateRadioAddress(c, to: "http://c.example.com/live")?.contains("没变") == true)
        let newAddr = "http://c.example.com:8000/new"
        let radiosBeforeRewrite = radioKeysInMain().count
        ctx.check("电台-改地址-台名与归属搬到新地址且旧地址不留悬空条目",
                  p.updateRadioAddress(c, to: newAddr) == nil
                    && stations.alias(for: newAddr) == "三台" && stations.alias(for: oldKey) == nil
                    && stations.categoryID(of: newAddr) == moveID
                    && stations.snapshotAssigned[oldKey] == nil,
                  "新址台名=\(stations.alias(for: newAddr) ?? "nil")")
        // 行数必须一字不变：改地址是「同一条换个写法」，多出一条就意味着旧址被复制了一份
        ctx.check("电台-改地址-列表里是同一条换了写法不是多出一条",
                  radioKeysInMain().count == radiosBeforeRewrite
                    && p.playlist.tracks.contains { $0.url.absoluteString == newAddr }
                    && !p.playlist.tracks.contains { $0.identityKey == oldKey },
                  "台\(radiosBeforeRewrite)→\(radioKeysInMain().count)")
        ctx.check("电台-改地址-列表那一行还是那个台名（换的是地址不是身份）",
                  p.playlist.tracks.first { $0.url.absoluteString == newAddr }?.title == "三台",
                  p.playlist.tracks.first { $0.url.absoluteString == newAddr }?.title ?? "nil")
        ctx.check("电台-改地址-收藏与台历史里的键一起换（不用重新收藏）",
                  p.groups.favoriteKeys.contains(newAddr) && !p.groups.favoriteKeys.contains(oldKey)
                    && p.groups.recentRadioKeys.contains(newAddr)
                    && !p.groups.recentRadioKeys.contains(oldKey),
                  "收藏=\(p.groups.favoriteKeys.prefix(3)) 历史=\(p.groups.recentRadioKeys.prefix(3))")
        // 新地址上本来就有用户给那个台起的名字：以那一份为准，旧址那份随即作废
        let hitAddr = "http://hit.example.com/live"
        stations.setAlias(key: hitAddr, raw: "那边已经有了")
        ctx.check("电台-改地址-目标地址已有台名时以那一份为准（不拿旧名覆了它）",
                  p.updateRadioAddress(p.playlist.tracks.first { $0.url.absoluteString == newAddr }!,
                                       to: hitAddr) == nil
                    && stations.alias(for: hitAddr) == "那边已经有了"
                    && stations.alias(for: newAddr) == nil
                    && stations.categoryID(of: hitAddr) == moveID,
                  "新址台名=\(stations.alias(for: hitAddr) ?? "nil") 归类=\(stations.categoryID(of: hitAddr) ?? "nil")")

        // MARK: 存档往返与旧档宽容
        p.switchGroup(.main)
        p.persistNow()
        let saved = LibraryStore.load()
        ctx.check("电台-存档-台名分类归属三份都写进档",
                  saved.radioAliases == stations.snapshotAliases
                    && saved.radioCategories == stations.snapshotCategories
                    && saved.radioAssignments == stations.snapshotAssigned
                    && saved.radioAliases[hitAddr] == "那边已经有了",
                  "台名=\(saved.radioAliases.count) 分类=\(saved.radioCategories.count)")
        stations.restore(aliases: [:], categories: [], assigned: [:])
        ctx.check("电台-存档-内存擦干净后左栏只剩未分类那一格电台页",
                  categoryRows() == 1 && stations.isEmpty, "分类=\(stations.count)")
        stations.restore(aliases: saved.radioAliases, categories: saved.radioCategories,
                         assigned: saved.radioAssignments)
        ctx.check("电台-存档-重启后台名分类归属都回来了",
                  stations.snapshotAliases == saved.radioAliases
                    && stations.snapshotCategories == saved.radioCategories
                    && stations.snapshotAssigned == saved.radioAssignments
                    && stations.alias(for: hitAddr) == "那边已经有了"
                    && categoryRows() == saved.radioCategories.count + 1,
                  "分类=\(stations.count) 行数=\(categoryRows())")
        let legacyJSON = "{\"trackPaths\":[],\"volume\":0.42}"
        let legacy = try? JSONDecoder().decode(AppState.self, from: Data(legacyJSON.utf8))
        ctx.check("电台-存档-旧版档缺这三项也能整档解开",
                  legacy?.volume == 0.42 && legacy?.radioAliases.isEmpty == true
                    && legacy?.radioCategories.isEmpty == true
                    && legacy?.radioAssignments.isEmpty == true,
                  "volume=\(legacy?.volume ?? -1)")
        stations.restore(aliases: ["http://x.example.com/live": "  ",
                                   "http://y.example.com/live": "有名字"],
                         categories: [RadioCategory(id: "", name: "空ID"),
                                      RadioCategory(id: "dup", name: "甲"),
                                      RadioCategory(id: "dup", name: "甲"),
                                      RadioCategory(id: RadioStations.uncategorizedID, name: "未分类"),
                                      RadioCategory(id: "keep", name: "乙")],
                         assigned: ["http://z.example.com/live": "已经不存在的分类"])
        ctx.check("电台-存档-空台名不收（回落成按地址显示）",
                  stations.snapshotAliases.count == 1
                    && stations.alias(for: "http://y.example.com/live") == "有名字",
                  "n=\(stations.snapshotAliases.count)")
        ctx.check("电台-存档-空 ID / 重复 ID / 未分类那种 ID 都不认",
                  stations.ids == ["dup", "keep"] && stations.name(of: "keep") == "乙",
                  "ids=\(stations.ids)")
        ctx.check("电台-存档-指向不存在的分类的归属当场丢弃（不把台藏起来）",
                  stations.snapshotAssigned.isEmpty && stations.unassignedCount == 0,
                  "n=\(stations.snapshotAssigned.count)")

        // MARK: 用户入口（行右键四项 + 左栏分类三项）
        p.switchGroup(.main)
        p.clearPlaylist()
        stations.restore(aliases: [:], categories: [], assigned: [:])
        _ = p.addFiles([wav])
        _ = p.addRadio("http://a.example.com/live", playNow: false)
        _ = p.addRadio("http://b.example.com/live", playNow: false)
        guard let entryID = p.createRadioCategory(named: "入口类")?.id else {
            ctx.check("电台-入口-建得出一张分类", false); return
        }
        _ = p.moveRadios(keys: [keyA], to: entryID)
        _ = p.setRadioName(trackOn("a.example.com")!, to: "城市之声")
        p.switchGroup(.main)
        ctx.pump(0.3)
        guard let fileRow = p.playlist.tracks.firstIndex(where: { !$0.isRadio }),
              let radioRow = p.playlist.tracks.firstIndex(where: { $0.isRadio }) else {
            ctx.check("电台-入口-前置有一行歌一行台", false,
                      "list=\(p.playlist.tracks.map { $0.isRadio ? "台" : "歌" })")
            return
        }
        let fileTitles = view.refreshContextMenu(over: fileRow).map { $0.title }
        ctx.check("电台-入口-本地歌那一行不出电台四项（置灰一排看不懂的入口不如不给）",
                  !fileTitles.contains("修改地址…") && !fileTitles.contains("移入分类")
                    && !fileTitles.contains("重试这个电台")
                    && !fileTitles.contains { $0.hasPrefix("自定义台名") || $0.hasPrefix("修改台名") },
                  fileTitles.joined(separator: "/"))
        let radioItems = view.refreshContextMenu(over: radioRow)
        ctx.check("电台-入口-台那一行四项齐全且都有真动作",
                  radioItems.contains(where: { $0.title == "修改台名「城市之声」…" && $0.action != nil })
                    && radioItems.contains(where: { $0.title == "修改地址…" && $0.action != nil })
                    && radioItems.contains(where: { $0.title == "重试这个电台" && $0.action != nil })
                    && radioItems.contains(where: { $0.title == "移入分类" && $0.submenu != nil }),
                  radioItems.map { $0.title }.joined(separator: "/"))
        let choices = view.radioMoveChoices(over: radioRow)
        ctx.check("电台-入口-「移入分类」子菜单把勾打在当前位置上",
                  choices.first { $0.title == "未分类" }?.state == .off
                    && choices.first(where: { $0.representedObject as? String == entryID })?.state == .on,
                  choices.map { "\($0.title):\($0.state == .on ? "勾" : "空")" }.joined(separator: "/"))
        ctx.check("电台-入口-点子菜单那一项真把台移回未分类",
                  view.clickRadioMoveItem(named: "未分类", over: radioRow)
                    && stations.categoryID(of: keyA) == nil && p.radioCount(in: entryID) == 0,
                  "n=\(p.radioCount(in: entryID))")
        let radioPageMenu = panel.makeGroupMenu(for: .radio).items.map { $0.title }
        let catMenu = panel.makeGroupMenu(for: .radioCategory(entryID)).items
        let uncatMenu = panel.makeGroupMenu(for: .radioCategory(RadioStations.uncategorizedID)).items
        ctx.check("电台-入口-左栏电台页给新建分类，分类页给改名与删除",
                  radioPageMenu.contains("新建电台分类…")
                    && catMenu.contains(where: { $0.title.hasPrefix("重命名分类「入口类」") && $0.isEnabled })
                    && catMenu.contains(where: { $0.title.hasPrefix("删除分类「入口类」") && $0.isEnabled }),
                  catMenu.map { $0.title }.joined(separator: "/"))
        ctx.check("电台-入口-未分类那一行的改名与删除是灰的（默认入口不能没）",
                  uncatMenu.contains(where: { $0.title == "重命名分类…" && !$0.isEnabled })
                    && uncatMenu.contains(where: { $0.title == "删除分类…" && !$0.isEnabled }))
        let madeByPanel = panel.createRadioCategoryThroughUI(named: "面板建的")
        ctx.check("电台-入口-左栏三个分类动作走的是与菜单项同一个入口",
                  madeByPanel != nil && panel.groupTitles.contains("面板建的")
                    && panel.renameRadioCategoryThroughUI(id: madeByPanel?.id ?? "", to: "面板改的名") == nil
                    && panel.groupTitles.contains("面板改的名")
                    && panel.deleteRadioCategoryThroughUI(id: madeByPanel?.id ?? "") != nil
                    && !panel.groupTitles.contains("面板改的名"),
                  "titles=\(panel.groupTitles)")

        // MARK: m3u 与属性面板
        p.switchGroup(.main)
        guard let named = trackOn("a.example.com") else {
            ctx.check("电台-入口-m3u 前置：台还在列", false); return
        }
        _ = p.setRadioName(named, to: "导出带这名")
        let list = Playlist()
        list.add(named)
        let m3u = dir.appendingPathComponent("alias.m3u")
        _ = list.exportAsM3U(to: m3u)
        let text = (try? String(contentsOf: m3u, encoding: .utf8)) ?? ""
        ctx.check("电台-m3u 导出至少携带自定义台名",
                  text.contains("#EXTINF:-1,导出带这名") && text.contains("http://a.example.com/live"),
                  text.replacingOccurrences(of: "\n", with: " | "))
        let extraLines = p.propertyExtraLines(for: named)
        ctx.check("电台-属性面板说清台名来路与分类（没在播就不编状态）",
                  extraLines.contains { $0.0 == "电台台名" && $0.1.contains("自定义") }
                    && extraLines.contains { $0.0 == "电台分类" }
                    && !extraLines.contains { $0.0 == "电台状态" || $0.0 == "连接质量" }
                    && !extraLines.contains { $0.1.contains("0 k") },
                  extraLines.map { $0.0 }.joined(separator: "/"))

        // 收摊：档案、列表、历史、收藏都擦干净，不给下一段留现场
        p.stop()
        p.switchGroup(.main)
        p.clearPlaylist()
        p.groups.clear(.recentRadio)
        for key in [hitAddr, keyA, newAddr, oldKey] {
            let t = Track(radio: URL(string: key)!)
            if p.isFavorite(t) { _ = p.toggleFavorite(t) }
        }
        stations.restore(aliases: [:], categories: [], assigned: [:])
        p.persistNow()
        let after = LibraryStore.load()
        ctx.check("电台-收尾-档案与存档都擦干净不留给下一段",
                  after.radioAliases.isEmpty && after.radioCategories.isEmpty
                    && after.radioAssignments.isEmpty && after.trackPaths.isEmpty
                    && after.recentRadioKeys.isEmpty && p.playlist.isEmpty
                    && categoryRows() == 1 && stations.isEmpty,
                  "台名=\(after.radioAliases.count) 分类=\(after.radioCategories.count)")
    }

    // MARK: - 内置电台（F11 的出厂内容）

    /// 出厂那几台验三件事：清单本身写没写错、默认入表那条路幂不幂等、用户删过之后还回不回得来。
    /// 全程离线：种入走的是 addRadio，真连网只发生在「双击那一行」，自检不碰
    private func checkBuiltinStations(_ ctx: SelfTestContext) {
        let p = ctx.player
        let stations = p.radioStations
        func wipe() {
            p.stop()
            p.switchGroup(.main)
            p.clearPlaylist()
            p.groups.clear(.recentRadio)
            stations.restore(aliases: [:], categories: [], assigned: [:])
            ctx.pump(0.1)
        }
        wipe()
        guard let preset = RadioPresets.all.first, let url = preset.url else {
            ctx.check("电台-内置-清单里至少有一台且地址解得开", false,
                      "\(RadioPresets.all.count) 台，第一台 url=\(RadioPresets.all.first?.address ?? "nil")")
            return
        }
        let key = preset.identityKey
        func builtinTrack() -> Track? { p.playlist.tracks.first { $0.identityKey == key } }

        // MARK: 清单本身
        let broken = RadioPresets.all.filter { $0.url == nil }.map { $0.address }
        ctx.check("电台-内置-每台地址都归一化得开", broken.isEmpty, broken.joined(separator: " / "))
        ctx.check("电台-内置-出厂那台的名字与地址钉死（改了要过发布说明）",
                  RadioPresets.all.count == 1 && preset.name == "Whispering Solo Piano Radio"
                    && preset.address == "https://pianosolo.streamguys1.com/live",
                  "\(RadioPresets.all.count) 台：\(preset.name) / \(preset.address)")
        ctx.check("电台-内置-键与 Track.identityKey 同一写法（才能跟手输的台去重）",
                  key == Track(radio: url).identityKey && RadioURL.normalize(preset.address) == url,
                  key)

        // MARK: 默认入表（入口埋得深等于没有，出厂那台一启动就在列表里）
        ctx.check("电台-内置-没删过时种入一次就入表，且不开播不抢页",
                  p.seedPresetRadios() == 1 && builtinTrack() != nil
                    && !p.isPlaying && p.activeGroup == .main,
                  "n=\(p.playlist.count) isPlaying=\(p.isPlaying)")
        ctx.check("电台-内置-再种一次不多塞一条（与手输同址同一个去重）",
                  p.seedPresetRadios() == 0
                    && p.playlist.tracks.filter { $0.identityKey == key }.count == 1,
                  "n=\(p.playlist.count)")
        ctx.check("电台-内置-入表不往台名存档写别名（台名按地址兜底）",
                  stations.alias(for: key) == nil && !stations.hasCustomName(for: url)
                    && stations.snapshotAliases.isEmpty,
                  "aliases=\(stations.snapshotAliases.count)")
        ctx.check("电台-内置-同址新建的条目一出生就叫内置名",
                  Track(radio: url).title == preset.name
                    && stations.displayName(for: url) == preset.name,
                  Track(radio: url).title)
        guard let track = builtinTrack() else {
            ctx.check("电台-内置-入表后拿得到那一条", false, "列表里找不到内置台"); return
        }
        ctx.check("电台-内置-列表那一行显示内置台名而不是主机名",
                  track.title == preset.name && track.isRadio, "title=\(track.title)")

        // MARK: 台名的三种来路
        ctx.check("电台-内置-没起过名字时来路是内置不是自定义",
                  stations.nameSource(for: url) == .builtin
                    && p.radioNameSourceText(for: url).contains("内置台名")
                    && !stations.hasCustomName(for: url),
                  p.radioNameSourceText(for: url))
        ctx.check("电台-内置-用户起的名字优先于内置名",
                  p.setRadioName(track, to: "深夜钢琴") == nil && track.title == "深夜钢琴"
                    && stations.nameSource(for: url) == .custom,
                  "title=\(track.title) 来路=\(p.radioNameSourceText(for: url))")
        ctx.check("电台-内置-取消自定义落回内置名（不是落回地址）",
                  p.setRadioName(track, to: "  ") == nil && track.title == preset.name
                    && stations.alias(for: key) == nil
                    && stations.fallbackText(for: url).contains("内置台名"),
                  "title=\(track.title) 落回=\(stations.fallbackText(for: url))")
        _ = p.addRadio("http://a.example.com/live", playNow: false)
        ctx.pump(0.1)
        let plain = URL(string: "http://a.example.com/live")!
        ctx.check("电台-内置-出厂之外的台仍按地址（不会被误判成内置）",
                  stations.nameSource(for: plain) == .address
                    && p.radioNameSourceText(for: plain) == "按地址显示"
                    && stations.fallbackText(for: plain) == "按地址显示",
                  p.radioNameSourceText(for: plain))

        // MARK: 属性面板与菜单入口
        let extra = p.propertyExtraLines(for: track)
        ctx.check("电台-内置-属性面板把台名来路说清（带上台名与「不占存档」）",
                  extra.contains { $0.0 == "电台台名" && $0.1.contains("内置台名")
                      && $0.1.contains(preset.name) && $0.1.contains("不占台名存档") },
                  extra.first { $0.0 == "电台台名" }?.1 ?? "没有那一行")
        let items = ctx.main.buildPopupMenu().items
        ctx.check("电台-内置-菜单里不再有「内置电台」那一支（默认就在列表里，入口是多余的）",
                  !items.contains { $0.title == "内置电台" }
                    && items.contains { $0.title == "添加网络电台…" },
                  items.compactMap { $0.title.isEmpty ? nil : $0.title }.joined(separator: "|"))

        // MARK: 删过就不回来（「不需要就自己删」得真能删掉）
        if let idx = p.playlist.tracks.firstIndex(where: { $0.identityKey == key }) {
            p.removeTracks(at: IndexSet(integer: idx))
        }
        ctx.pump(0.1)
        ctx.check("电台-内置-从列表删掉就进黑名单，再种一次也不回来",
                  builtinTrack() == nil && p.seedPresetRadios() == 0 && builtinTrack() == nil,
                  "n=\(p.playlist.count) 黑名单=\(p.declinedRadios.count)")
        p.persistNow()
        let after = LibraryStore.load()
        ctx.check("电台-内置-加过又删掉，存档里不会多出一条谁也没写过的别名",
                  stations.alias(for: key) == nil
                    && after.radioAliases[key] == nil && after.radioAliases.isEmpty,
                  "aliases=\(after.radioAliases.count)")
        ctx.check("电台-内置-黑名单落盘（下次启动才知道用户删过这一台）",
                  after.declinedRadioKeys == [key],
                  after.declinedRadioKeys.joined(separator: " / "))
        let legacy = try? JSONDecoder().decode(AppState.self,
                                               from: Data("{\"trackPaths\":[],\"volume\":0.42}".utf8))
        ctx.check("电台-内置-旧档没这一项就是谁也没删过（升级后照样补种一台）",
                  legacy?.declinedRadioKeys.isEmpty == true,
                  "黑名单=\(legacy?.declinedRadioKeys.count ?? -1)")

        // 收摊：不给后面的段留现场（内置台在列表里挂着会让下一段以为已经入表）
        wipe()
        p.persistNow()
        let clean = LibraryStore.load()
        // 拿「列表空 + 没在播 + 两份台名表都空」当凭据，不拿 `isRadio`：电台
        // 停下后那个标记照旧为真（跟本地文件一样是「装载着但停住」）
        ctx.check("电台-内置-收尾擦干净不留给下一段",
                  p.playlist.isEmpty && !p.isPlaying && clean.radioAliases.isEmpty
                    && stations.snapshotAliases.isEmpty,
                  "n=\(p.playlist.count) isPlaying=\(p.isPlaying) aliases=\(clean.radioAliases.count)")
    }

    // MARK: - 连接质量台账（F11：时间由调用处递进来）

    /// 需求要「统计窗口说清楚、每场会话正确重置」，而窗口进退拿真时钟验就是碰运气。
    /// RadioQuality 自己不读时钟（方法都带 `now:`），所以这里能给一串已知时刻，
    /// 把三十秒窗口与「一次见底只记一笔」钉死
    private func checkQuality(_ ctx: SelfTestContext) {
        var q = RadioQuality()
        ctx.check("电台-质量-没在连的电台不编一句统计",
                  q.session == 0 && q.summary(now: 100) == "没有正在连的电台", q.summary(now: 100))
        q.startSession(7)
        ctx.check("电台-质量-新一页从零开始且只记住是哪一页",
                  q.session == 7 && q.totalUnderruns == 0 && q.totalReconnects == 0
                    && q.windowUnderruns(now: 100) == 0)
        q.noteBuffer(seconds: 0.5, now: 100)
        ctx.check("电台-质量-半秒缓冲不算不足（水线只用来显示）",
                  q.bufferedSeconds == 0.5 && !q.isBufferLow)
        q.noteBuffer(seconds: RadioQuality.lowBufferSeconds - 0.1, now: 100)
        ctx.check("电台-质量-低于水线就该说缓冲不足", q.isBufferLow,
                  "水线=\(RadioQuality.lowBufferSeconds)s")
        q.noteBuffer(seconds: -1, now: 100)
        ctx.check("电台-质量-缓冲读数不会是负的", q.bufferedSeconds == 0 && q.isBufferLow)
        q.noteUnderrun(now: 101)
        q.noteUnderrun(now: 101.05)
        q.noteUnderrun(now: 101.1)
        ctx.check("电台-质量-一次见底只记一笔欠载（反复报不能刷数字）",
                  q.totalUnderruns == 1 && q.windowUnderruns(now: 101.1) == 1,
                  "n=\(q.totalUnderruns)")
        ctx.check("电台-质量-见底时那句写明在等数据",
                  q.summary(now: 101.1).contains("已经排空"), q.summary(now: 101.1))
        q.noteBuffer(seconds: 0.5, now: 102)
        q.noteUnderrun(now: 103)
        ctx.check("电台-质量-缓过来又见底算新的一笔",
                  q.totalUnderruns == 2 && q.windowUnderruns(now: 103) == 2,
                  "n=\(q.totalUnderruns)")
        q.noteReconnect(now: 103.5)
        ctx.check("电台-质量-欠载与重连分开记账",
                  q.totalReconnects == 1 && q.totalUnderruns == 2
                    && q.windowReconnects(now: 103.5) == 1)
        ctx.check("电台-质量-那句质量话把窗口与本会话都点名（统计窗口不含糊其辞）",
                  q.summary(now: 104).contains("近 30 秒")
                    && q.summary(now: 104).contains("本次收听累计"),
                  q.summary(now: 104))
        ctx.check("电台-质量-不把码率当质量（那句里一个码率有关的字都没有）",
                  RadioQuality.windowSeconds == 30
                    && !q.summary(now: 104).contains("kbps")
                    && !q.summary(now: 104).contains("码率")
                    && !q.summary(now: 104).contains("音质"),
                  q.summary(now: 104))
        ctx.check("电台-质量-窗口外的旧账不算「近期」（累计仍留着）",
                  q.windowUnderruns(now: 132.5) == 1 && q.windowUnderruns(now: 133.5) == 0
                    && q.windowReconnects(now: 133.5) == 0 && q.totalUnderruns == 2,
                  "32.5s 前=\(q.windowUnderruns(now: 132.5)) 33.5s 前=\(q.windowUnderruns(now: 133.5))")
        // 先让它缓过来：`starved` 还挂着的时候再报一笔会被「一次见底只记一笔」挡掉，
        // 那一笔根本进不了窗口，就验不到清窗口这一步
        q.noteBuffer(seconds: 1.0, now: 380)
        q.noteUnderrun(now: 400)
        ctx.check("电台-质量-报一笔时顺手把过期的清出窗口（不靠 filter 堆看运气）",
                  q.windowUnderruns(now: 400) == 1 && q.totalUnderruns == 3,
                  "窗口=\(q.windowUnderruns(now: 400)) 累计=\(q.totalUnderruns)")
        q.startSession(8)
        ctx.check("电台-质量-换台把上一场的账整本翻页重记",
                  q.session == 8 && q.totalUnderruns == 0 && q.totalReconnects == 0
                    && q.windowUnderruns(now: 400) == 0 && q.bufferedSeconds == 0,
                  "累计=\(q.totalUnderruns)")
        // 未知码率不伪造：解不出来就一个字不写，不拿 0 凑一条「0 kbps」给用户看
        let unknown = RadioStreamDecoder.Info()
        let known = RadioStreamDecoder.Info(sampleRate: 44_100, channels: 2, bitRateKbps: 64, codec: "AAC")
        ctx.check("电台-质量-未知码率不伪造（空文案而不是 0k）",
                  unknown.bitRateText.isEmpty && unknown.sampleRateText.isEmpty
                    && known.bitRateText == "64k" && known.sampleRateText == "44.1k",
                  "unknown=\"\(unknown.bitRateText)\" known=\(known.bitRateText)")
    }

    // MARK: - 本地 HTTP 流按剧本演（F11 验收：不依赖公网）

    /// 需求写死了「用可控本地 HTTP 流测失败与慢速」。这里走的仍是 URLSession → ICY 拆包 →
    /// FFmpeg → playerNode 那条真链路，只是服务器在 127.0.0.1 上，能把「推得比realtime慢」、
    /// 「推够一点就掐」、「只回 503」这些公网给不了的条件摆出来。
    /// 本机造不出 ADTS AAC 或服务器起不来时整段 SKIP（不是本机错，不让整套变红）
    private func checkLocalStream(_ ctx: SelfTestContext) {
        let dir = tempDir(ctx)
        let p = ctx.player
        let view = ctx.main.playlistView
        let stations = p.radioStations
        let wav = dir.appendingPathComponent("localstream.wav")
        let aac = dir.appendingPathComponent("localstream.aac")
        func finishUp() {
            p.stop()
            p.switchGroup(.main)
            p.clearPlaylist()
            p.groups.clear(.recentRadio)
            stations.restore(aliases: [:], categories: [], assigned: [:])
            ctx.pump(0.2)
        }
        guard ctx.writeWave(wav, sampleRate: 44_100, channels: 2, bits: 16, freqs: [440, 660]) else {
            ctx.check("电台-本地流-写得出素材", false, "writeWave 失败")
            return
        }
        if !ctx.fm.fileExists(atPath: aac.path) {
            _ = ctx.convert(source: wav, fileFmt: "adts", dataFmt: "aac", to: aac)
        }
        guard let body = try? Data(contentsOf: aac), !body.isEmpty else {
            ctx.emit("[selftest] SKIP 电台-本地 HTTP 流（本机 afconvert 造不出 ADTS AAC）")
            return
        }
        let srv = LocalRadioStream(file: aac)
        var cfg = LocalRadioStream.Config()
        cfg.metaint = 4_096                    // 要 ICY 元数据：台名与「正在播」分离就靠它
        cfg.title = "TT - 本地台"
        cfg.bytesPerSecond = 64_000            // 推得比 128 kbps 的 AAC 快，正常不该卡
        srv.config = cfg
        guard let stream = srv.start() else {
            ctx.emit("[selftest] SKIP 电台-本地 HTTP 流（本地服务器起不来）")
            return
        }
        defer { srv.stop() }
        let key = stream.absoluteString
        func station() -> Track? { p.playlist.tracks.first { $0.isRadio } }

        // ---- 一、出声、ICY 分离、已知值报得出、未知值不伪造 ----
        p.clearPlaylist()
        stations.setAlias(key: key, raw: "本地测试台")
        if let note = p.addRadio(key, playNow: true) {
            ctx.check("电台-本地流-加得进来", false, note)
            finishUp()
            return
        }
        let heard = ctx.waitUntil(20) { p.isRadio && p.isPlaying && p.engine.radioHasSound }
        let scene = "状态=\(p.radioStateText) isRadio=\(p.isRadio) isPlaying=\(p.isPlaying) "
            + "有声=\(p.engine.radioHasSound) 连接=\(srv.connections) 推出=\(srv.servedBytes)B"
        ctx.check("电台-本地流-本地 HTTP 流真能出声（URLSession→ICY→FFmpeg→节点）", heard, scene)
        guard heard else { finishUp(); return }
        let onAir = ctx.waitUntil(6) { p.radioStateText == "直播中" }
        let titled = ctx.waitUntil(8) { !p.radioNowPlaying.isEmpty }
        let measured = ctx.waitUntil(6) { (station()?.sampleRate ?? 0) > 0 }
        ctx.check("电台-本地流-连上后状态走到直播中", onAir, p.radioStateText)
        ctx.check("电台-本地流-ICY 标题只进「正在播」（不覆盖用户起的台名）",
                  titled && p.radioNowPlaying == "TT - 本地台"
                    && station()?.title == "本地测试台"
                    && stations.alias(for: key) == "本地测试台",
                  "正在播=\(p.radioNowPlaying) 台名=\(station()?.title ?? "nil")")
        ctx.check("电台-本地流-编码与采样率报得出流里的真值",
                  measured && station()?.formatName.uppercased().contains("AAC") == true
                    && station()?.sampleRate == 44_100,
                  "codec=\(station()?.formatName ?? "nil") sr=\(station()?.sampleRate ?? 0)")
        if let t = station() {
            let lines = t.propertyLines
            ctx.check("电台-本地流-未知码率不伪造（要么真值要么整行不写）",
                      !lines.contains { $0.1.contains("unknown") || $0.1.contains("0 kbps") }
                        && (t.bitRateKbps > 0) == lines.contains(where: { $0.0 == "码率" }),
                      lines.map { "\($0.0)=\($0.1)" }.joined(separator: "/"))
            let extra = p.propertyExtraLines(for: t)
            ctx.check("电台-属性面板-正在播时才写状态、正在播与连接质量",
                      extra.contains { $0.0 == "电台状态" && $0.1 == "直播中" }
                        && extra.contains { $0.0 == "正在播放" && $0.1.contains("TT - 本地台") }
                        && extra.contains { $0.0 == "电台分类" && $0.1.contains("未分类") }
                        && extra.contains { $0.0 == "连接质量" },
                      extra.map { $0.0 }.joined(separator: "/"))
        }
        let quality = p.radioQualityText
        ctx.check("电台-本地流-连接质量那句只说可测量（近 30 秒、缓冲、欠载、重连）",
                  quality.contains("近 30 秒") && quality.contains("缓冲")
                    && !quality.contains("kbps") && !quality.contains("码率"), quality)
        ctx.check("电台-本地流-台账认得这是哪一场且缓冲读数已排进去",
                  p.engine.radioQuality.session != 0 && p.radioBufferedSeconds >= 0,
                  "会话=\(p.engine.radioQuality.session) 缓冲=\(p.radioBufferedSeconds)s")
        // 频谱是「解码→EQ→mixer→输出」这条通路唯一的证词。不能单点读 `bars`：
        // `SpectrumView` 在窗口 occlusion 不可见时会 `analyzer.setEnabled(false)` 把 bars 抹成 0，
        // 而我们要验的是引擎真的把 PCM 推到了 tap，不是 UI 此刻可见不可见（
        // `ctx.spectrumEnergy` 就是为这个准备的：测量期间临时 enable、测完还原、多次取 max）
        let streamEnergy = ctx.spectrumEnergy(p)
        ctx.check("电台-本地流-PCM 真过了 EQ/mixer（频谱亮）", streamEnergy > 0.005,
                  "max=\(String(format: "%.3f", streamEnergy))")
        ctx.snapshot(ctx.main.window, named: "shot_radio_local_stream")

        // ---- 二、暂停不算网络差，恢复就是重连上又出声 ----
        let underrunBefore = p.engine.radioQuality.totalUnderruns
        let sessionBefore = p.engine.radioQuality.session
        p.togglePlay()
        let paused = ctx.waitUntil(5) { !p.isPlaying }
        ctx.pump(0.6)
        ctx.check("电台-本地流-按个暂停不算网络差（不记欠载也不换会话）",
                  paused && p.engine.radioQuality.totalUnderruns == underrunBefore
                    && p.engine.radioQuality.session == sessionBefore
                    && p.radioStateText == "未连接",
                  "欠载=\(underrunBefore)→\(p.engine.radioQuality.totalUnderruns) 状态=\(p.radioStateText)")
        p.togglePlay()
        let resumed = ctx.waitUntil(20) {
            p.isPlaying && p.radioStateText == "直播中" && p.engine.radioHasSound
        }
        ctx.check("电台-本地流-恢复就是重连上又出声（同一场收听）",
                  resumed && p.engine.radioQuality.session == sessionBefore,
                  "resumed=\(resumed) 会话=\(p.engine.radioQuality.session)/\(sessionBefore)")

        // ---- 三、慢速：排得没声音快才叫欠载，界面得说出来 ----
        let slow = p.radioBufferedSeconds
        cfg.bytesPerSecond = 1_500
        srv.config = cfg
        _ = p.retryRadio(station() ?? Track(radio: stream))     // 新连接才按新剧本推
        // 重试是「先停再装载」：会话号要等淡出走完、真开新流那一步才翻页，当场读还是上一页
        let pageTurned = ctx.waitUntil(10) { p.engine.radioQuality.session != sessionBefore }
        var stallText = ""
        var stallSummary = ""
        let stalled = ctx.waitUntil(25) {
            guard p.engine.radioQuality.totalUnderruns >= 1, p.engine.radioBufferLow else { return false }
            stallText = p.radioStateText
            stallSummary = p.radioQualityText
            return true
        }
        ctx.check("电台-本地流-手动重试另起一页台账（不是接着上一页刷数字）",
                  pageTurned && p.engine.radioQuality.session > sessionBefore,
                  "会话=\(sessionBefore)→\(p.engine.radioQuality.session)")
        ctx.check("电台-本地流-推得比realtime慢时真会排空（欠载有凭据）",
                  stalled && !stallSummary.isEmpty, "慢速前缓冲=\(slow)s 状态=\(stallText)")
        ctx.check("电台-本地流-慢到排空时界面不说「直播中」而说缓冲不足",
                  stallText == "缓冲不足，正在等数据…"
                    && stallSummary.contains("已经排空"),
                  "状态=\(stallText) 质量=\(stallSummary)")
        cfg.bytesPerSecond = 64_000
        srv.config = cfg
        // 上一场已经攒下至少一笔欠载，这一场翻页后必须从空白页开始记（需求：每场会话正确重置）
        let stallTotal = p.engine.radioQuality.totalUnderruns
        let stallSession = p.engine.radioQuality.session
        _ = p.retryRadio(station() ?? Track(radio: stream))
        var freshTotal = -1
        let repaged = ctx.waitUntil(10) {
            guard p.engine.radioQuality.session != stallSession else { return false }
            freshTotal = p.engine.radioQuality.totalUnderruns
            return true
        }
        let recovered = ctx.waitUntil(20) { p.isPlaying && p.radioStateText == "直播中"
            && p.engine.radioHasSound }
        ctx.check("电台-本地流-翻页后上一场攒的欠载没被带过来",
                  repaged && stallTotal >= 1 && freshTotal == 0,
                  "上一场欠载=\(stallTotal) 新一页=\(freshTotal)")
        ctx.check("电台-本地流-网络跟得上又不卡了（水线以上就不再喊缓冲不足）",
                  recovered && !p.engine.radioBufferLow,
                  "状态=\(p.radioStateText) 缓冲=\(p.radioBufferedSeconds)s")

        // ---- 四、服务器只回 503：按退避重连、记进台账、停止后不作数 ----
        srv.failWith(status: 503)
        let before503 = srv.connections
        _ = p.retryRadio(station() ?? Track(radio: stream))
        var reconnectText = ""
        let backed = ctx.waitUntil(25) {
            if srv.connections - before503 >= 3, p.radioStateText.contains("重连") {
                reconnectText = p.radioStateText
                return true
            }
            return false
        }
        ctx.check("电台-本地流-服务器 503 时按退避一再重连（不是第次就报错）",
                  backed, "连接+\(srv.connections - before503) 状态=\(reconnectText.isEmpty ? p.radioStateText : reconnectText)")
        ctx.check("电台-本地流-重连中的那句写明是第几次", reconnectText.contains("重连中")
                  && reconnectText.contains("次"), reconnectText)
        ctx.check("电台-本地流-自动重连也记进同一场的账（用户看到的是这一次听了几回）",
                  p.engine.radioQuality.totalReconnects >= 2,
                  "重连=\(p.engine.radioQuality.totalReconnects) 质量=\(p.radioQualityText)")
        let frozen = srv.connections
        let frozenSession = p.engine.radioQuality.session
        p.stop()
        ctx.pump(RadioPlayer.retryWait(attempt: RadioPlayer.maxAttempts) * 1.2 + 0.3)
        // ↑ 比最长那档退避还久（自检里那一档已被压到 1/8，出厂仍是 8 s）
        ctx.check("电台-本地流-显式停止后不再自动重连（晚到的退避与回调都不作数）",
                  srv.connections == frozen && p.radioStateText == "未连接" && !p.isPlaying
                    && p.engine.radioQuality.session == frozenSession,
                  "连接次数 \(frozen)→\(srv.connections) 状态=\(p.radioStateText)")

        // ---- 五、403：重连多少次都是一个结果，当场说人话 ----
        let before403 = srv.connections
        srv.failWith(status: 403)
        _ = p.retryRadio(station() ?? Track(radio: stream))
        let refused = ctx.waitUntil(10) { p.radioStateText.contains("账号") }
        // 窗口比头两次退避加起来还长：真走了五次退避，这里一定能数出多余连接
        ctx.pump(RadioPlayer.retryWait(attempt: RadioPlayer.maxAttempts) * 1.2 + 0.3)
        ctx.check("电台-本地流-403 当场说「要账号或密码」而不走五次退避",
                  refused && srv.connections - before403 == 1
                    && p.radioStateText.contains("403"),
                  "状态=\(p.radioStateText) 连接+\(srv.connections - before403)")

        // ---- 六、推一半掉线：自己接上，仍算同一场 ----
        cfg.bytesPerSecond = 64_000
        cfg.metaint = 0
        cfg.closeAfterBytes = 60_000
        srv.config = cfg
        let beforeCut = srv.connections
        _ = p.retryRadio(station() ?? Track(radio: stream))
        let cutSession = p.engine.radioQuality.session
        let cut = ctx.waitUntil(25) { srv.connections - beforeCut >= 2 }
        ctx.check("电台-本地流-服务器中途掉线后自己接上（不用用户动手）",
                  cut && srv.lastDropBy == "self",
                  "连接+\(srv.connections - beforeCut) 掉线由=\(srv.lastDropBy.isEmpty ? "没断" : srv.lastDropBy)")
        ctx.check("电台-本地流-掉线重连算同一场收听（不换页）",
                  p.engine.radioQuality.session == cutSession
                    && p.engine.radioQuality.totalReconnects >= 1,
                  "会话=\(p.engine.radioQuality.session) 重连=\(p.engine.radioQuality.totalReconnects)")
        cfg.closeAfterBytes = nil
        srv.config = cfg
        let steadyPage = p.engine.radioQuality.session
        _ = p.retryRadio(station() ?? Track(radio: stream))
        // 要等真翻页（open 之后）才起算：旧链那一页还在按 60_000 字节一掐，拿它当基线
        // 测不出任何事。翻页后排下去的旧退避定时器应该全部作废
        var steadyScene = ""
        let steadyOnAir = ctx.waitUntil(30) {
            let ok = p.engine.radioQuality.session != steadyPage
                && p.isPlaying && p.radioStateText == "直播中" && p.engine.radioHasSound
            steadyScene = "会话=\(steadyPage)→\(p.engine.radioQuality.session)"
                + " isPlaying=\(p.isPlaying) 状态=\(p.radioStateText)"
                + " 有声=\(p.engine.radioHasSound) 连接=\(srv.connections)"
            return ok
        }
        // 「不再掉线」的凭据是新这一页上线后连接数冻住：`lastDropBy` 说的是
        // 「最近一次掉线是谁掐的」，剧本不掐了它就一直停在上一次，不能当成「现在有没有断」
        let steadyFrom = srv.connections
        let steadyReconnects = p.engine.radioQuality.totalReconnects
        ctx.pump(3)           // 上一档「推够 6 万字节就掐」按 64_000 B/s 推，1 s 不到就该掐一次
        ctx.check("电台-本地流-改回正常剧本后不再掉线（旧退避定时器不会回来掐新流）",
                  steadyOnAir && srv.connections == steadyFrom
                    && p.engine.radioQuality.totalReconnects == steadyReconnects,
                  "\(steadyScene) 连接=\(steadyFrom)→\(srv.connections)"
                    + " 重连=\(steadyReconnects)→\(p.engine.radioQuality.totalReconnects)"
                    + " 掉线由=\(srv.lastDropBy)")

        // ---- 七、入口：改地址时旧连接先停（真流版） ----
        let beforeMove = srv.connections
        let otherAddr = "http://127.0.0.1:\(srv.port)/other"
        let playing = station() ?? Track(radio: stream)
        let moved = view.applyRadioAddress(track: playing, to: otherAddr)
        let movedOn = ctx.waitUntil(20) { p.isPlaying && p.engine.radioHasSound
            && station()?.url.path == "/other" }
        ctx.check("电台-入口-改地址走真入口：旧连接先停、新地址接着听",
                  moved == nil && movedOn && srv.connections > beforeMove
                    && stations.alias(for: otherAddr) == "本地测试台"
                    && stations.alias(for: key) == nil,
                  "note=\(moved ?? "nil") 连接+\(srv.connections - beforeMove) 现址=\(station()?.url.path ?? "nil")")

        finishUp()
        // 停止会像本地文件那样留着「已装载但停住」的电台会话（再按播放就是重连这个台），
        // 所以「擦干净」的凭据是没在播、状态回「未连接」，而不是 isRadio 被抹掉
        ctx.check("电台-本地流-收尾-台与档案都擦干净且没偷偷连着",
                  p.playlist.isEmpty && stations.snapshotAliases.isEmpty && !p.isPlaying
                    && p.radioStateText == "未连接",
                  "list=\(p.playlist.count) 台名=\(stations.snapshotAliases.count)"
                    + " 状态=\(p.radioStateText)")
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
        // 频谱是这条通路的证词：PCM 真过了 EQ/mixer，bars 才会亮（同样走 spectrumEnergy，
        // 单点读数会被窗口可见性与 tap 冷启动带跑）
        let lit = ctx.spectrumEnergy(p) > 0.005
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
