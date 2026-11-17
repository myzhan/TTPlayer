import AppKit
import Foundation

/// 跨入口与异常终态回归，随 system 套件运行。
struct ReviewFixes {
    static func run(_ ctx: SelfTestContext) {
        let root = ctx.fm.temporaryDirectory.appendingPathComponent("ttplayer-review-fixes-" + UUID().uuidString)
        try? ctx.fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? ctx.fm.removeItem(at: root) }
        storage(ctx, root)
        inputs(ctx)
        resources(ctx, root)
        playlists(ctx, root)
        edits(ctx, root)
        radio(ctx, root)
    }

    private static func storage(_ ctx: SelfTestContext, _ root: URL) {
        let user = root.appendingPathComponent("user")
        let fallback = root.appendingPathComponent("isolated")
        var safe = true
        for flag in ["1", "0", ""] {
            for path in [nil, "", user.path] as [String?] {
                var env = ["TTPLAYER_SELFTEST": flag]
                env["TTPLAYER_TESTDIR"] = path
                safe = safe && LibraryStore.storageDirectory(environment: env, userDirectory: user, fallback: fallback) == fallback
            }
        }
        ctx.check("回归-自检缺目录或误指用户目录仍隔离", safe)
        ctx.check("回归-正常启动仍用用户目录",
                  LibraryStore.storageDirectory(environment: [:], userDirectory: user, fallback: fallback) == user)
        let old = try? JSONDecoder().decode(AppState.self, from: Data("{\"trackPaths\":[\"/keep.wav\"]}".utf8))
        ctx.check("回归-旧存档缺显示覆盖仍保留曲库", old?.trackPaths == ["/keep.wav"] && old?.trackEdits.isEmpty == true)
    }

    private static func inputs(_ ctx: SelfTestContext) {
        var options = 0
        var folders = 0
        for _ in 0..<30 {
            let option = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option,
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 123)!
            if PlayerShortcuts.accepts(option) { options += 1 }
            let folder = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                timestamp: 0, windowNumber: 0, context: nil, characters: "O", charactersIgnoringModifiers: "O",
                isARepeat: false, keyCode: 31)!
            if PlayerShortcuts.accepts(folder) && PlayerShortcuts.opensFolder(folder) { folders += 1 }
        }
        ctx.check("回归-Option快捷键通过真实入口规则", options == 30, "\(options)/30")
        ctx.check("回归-CommandShiftO映射添加文件夹", folders == 30, "\(folders)/30")
        ctx.check("回归-系统播放暂停指令幂等",
                  !NowPlaying.shouldToggle(.play, isPlaying: true)
                    && NowPlaying.shouldToggle(.play, isPlaying: false)
                    && !NowPlaying.shouldToggle(.pause, isPlaying: false)
                    && NowPlaying.shouldToggle(.pause, isPlaying: true)
                    && NowPlaying.shouldToggle(.toggle, isPlaying: true))
    }

    private static func resources(_ ctx: SelfTestContext, _ root: URL) {
        var lyrics = 0
        var covers = 0
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<2 { for y in 0..<2 { rep.setColor(.red, atX: x, y: y) } }
        let png = rep.representation(using: .png, properties: [:])!
        for i in 0..<30 {
            let dir = root.appendingPathComponent("assets-\(i)")
            try? ctx.fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let track = Track(url: dir.appendingPathComponent("01 - Song.flac"))
            _ = Lyric.candidateFiles(for: track.url)
            _ = CoverArt.external(for: track)
            try? "[00:01]hello".write(to: dir.appendingPathComponent("Song.lrc"), atomically: true, encoding: .utf8)
            try? png.write(to: dir.appendingPathComponent("cover.png"))
            if !Lyric.candidateFiles(for: track.url).isEmpty { lyrics += 1 }
            if CoverArt.external(for: track) != nil { covers += 1 }
        }
        ctx.check("回归-新增模糊歌词使目录索引失效", lyrics == 30, "\(lyrics)/30")
        ctx.check("回归-新增封面使目录索引失效", covers == 30, "\(covers)/30")
    }

    private static func playlists(_ ctx: SelfTestContext, _ root: URL) {
        let wav = root.appendingPathComponent("mirror.wav")
        try? ctx.fm.copyItem(at: ctx.dir.appendingPathComponent("demo01.wav"), to: wav)
        let cue = root.appendingPathComponent("album.cue")
        try? "FILE \"mirror.wav\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"One\"\n    INDEX 01 00:00:00\n".write(to: cue, atomically: true, encoding: .utf8)
        let archive = root.appendingPathComponent("songs.zip")
        guard ctx.runTool("/usr/bin/zip", ["-q", archive.path, wav.lastPathComponent], cwd: root),
              let entry = Archive.makeEntryURL(archive: archive, entry: wav.lastPathComponent) else {
            ctx.check("回归-精确歌单素材", false); return
        }
        let keys = [cue.path + "#track=1", entry.absoluteString]
        let m3u = root.appendingPathComponent("roundtrip.m3u")
        _ = PlaylistM3U.export(keys: keys, names: [:], durations: [:], to: m3u)
        ctx.check("回归-主列表导入保留精确CUE和归档条目",
                  LibraryStore.importURLs([m3u]).tracks.map { $0.identityKey } == keys)
        ctx.check("回归-两种歌单入口身份与顺序一致", PlaylistM3U.import(m3u)?.keys == keys)

        // 用真实 Reader 验证访问后淘汰顺序，不用 Dictionary 模拟替代。
        for i in 0..<6 { try? ctx.fm.copyItem(at: wav, to: root.appendingPathComponent("\(i).wav")) }
        let lru = root.appendingPathComponent("lru.zip")
        _ = ctx.runTool("/usr/bin/zip", ["-q", lru.path] + (0..<6).map { "\($0).wav" }, cwd: root)
        let first = Archive.reader(archive: lru, entry: "0.wav")
        let oldest = Archive.reader(archive: lru, entry: "1.wav")
        for i in 2..<5 { _ = Archive.reader(archive: lru, entry: "\(i).wav") }
        _ = Archive.reader(archive: lru, entry: "0.wav")
        _ = Archive.reader(archive: lru, entry: "5.wav")
        let kept = Archive.reader(archive: lru, entry: "0.wav")
        let replaced = Archive.reader(archive: lru, entry: "1.wav")
        ctx.check("回归-归档缓存保留最近访问淘汰最旧项", first != nil && oldest != nil && first === kept && oldest !== replaced)
        Archive.invalidate(archive: lru)
        Archive.invalidate(archive: archive)
    }

    private static func edits(_ ctx: SelfTestContext, _ root: URL) {
        let saved = TrackEdits.snapshot
        defer { TrackEdits.restore(saved); ctx.player.persistNow() }
        let track = Track(url: root.appendingPathComponent("edited.wav"))
        let titleBefore = ctx.main.window.title
        ctx.player.editDisplayInfo(track, title: "Saved title", artist: "Saved artist")
        let state = LibraryStore.load()
        TrackEdits.restore(state.trackEdits)
        let restored = Track(url: track.url)
        ctx.check("回归-显示信息保存后重新构造仍保留", restored.title == "Saved title" && restored.artist == "Saved artist")
        MetadataReader.readSync(restored)
        ctx.check("回归-元数据读取不覆盖用户显示信息", restored.title == "Saved title" && restored.artist == "Saved artist")
        ctx.check("回归-编辑非当前曲不伪造切曲通知", ctx.main.window.title == titleBefore)
    }

    private static func radio(_ ctx: SelfTestContext, _ root: URL) {
        let zeros = Data(repeating: 0, count: 6 * 1024 * 1024)
        let extra = Data(repeating: 0, count: 65_536)
        var finished = 0
        for _ in 0..<30 {
            let decoder = RadioStreamDecoder()
            decoder.open()
            decoder.feed(zeros)
            if ctx.waitUntil(3, { decoder.hasFinished }) {
                for _ in 0..<30 { decoder.feed(extra) }
                if decoder.bufferedByteCount == 0 { finished += 1 }
            }
            decoder.close()
        }
        ctx.check("回归-坏流解码退出后拒绝输入且清空缓冲", finished == 30, "\(finished)/30")
        let decoder = RadioStreamDecoder()
        decoder.feed(Data(repeating: 0, count: RadioStreamDecoder.maxBufferedBytes + 1))
        decoder.feed(extra)
        ctx.check("回归-电台输入超过预算后停止累积", decoder.bufferedByteCount == 0)
        let file = root.appendingPathComponent("bad-stream.bin")
        try? zeros.write(to: file)
        let server = LocalRadioStream(file: file)
        var config = LocalRadioStream.Config()
        config.bytesPerSecond = 16 * 1024 * 1024
        server.config = config
        guard let url = server.start() else { ctx.check("回归-坏流HTTP服务", false); return }
        defer { server.stop() }
        let player = RadioPlayer()
        player.open(url)
        let stopped = ctx.waitUntil(12) {
            if case .failed = player.snapshotState() { return true }
            return false
        }
        ctx.check("回归-持续坏流触发重连并在上限后收手", stopped && server.connections > 1
                    && server.connections <= RadioPlayer.maxAttempts + 1, "连接=\(server.connections)")
        player.stop()
    }
}
