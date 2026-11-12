import Foundation
import AppKit

/// 播放现场恢复（requirements F06）：现场编解码与稳定身份、默认恢复为暂停、「启动后自动
/// 继续播放」的两条件、队列次序/重复条目/显式标记/历史/浏览组、CUE 段内时基、归档条目 URL、
/// 电台只恢复地址不伪造进度、失效条目不擅自换曲、时长变化夹紧、旧档兼容、节流落盘不重写整库。
///
/// 位置类断言不拿 `engine.currentTime` 单独作证：那个数是从渲染时钟外推的，排错了内容
/// 也能报出一个好看秒数。素材用「每秒换一个音」的分段单音（第 i 秒 = 200+100i Hz），
/// 采实际输出链路的 PCM 再问「放出来的到底是哪一秒」（见 captureLeftChannel / toneEnergy）。
struct SceneSuite: SelfTestSuite {
    func run(_ ctx: SelfTestContext) {
        let root = tempRoot(ctx)
        checkSceneCodable(ctx)
        checkGroupCodable(ctx)
        checkSnapshotShape(ctx)
        checkResumeIsRealAudio(ctx, root: root)
        checkAutoResumeBranches(ctx, root: root)
        checkQueueOrderAndGroup(ctx)
        checkCueSegmentTimeBase(ctx, root: root)
        checkArchiveEntry(ctx, root: root)
        checkRadioScene(ctx, root: root)
        checkInvalidEntries(ctx, root: root)
        checkLegacyScene(ctx)
        checkFlushDiscipline(ctx)
        checkUserEntry(ctx)
        // 收尾：开关回到默认关，现场文件落在 testlib（自检把存档目录重定向过去），不留给下一轮
        ctx.player.setAutoResumePlay(false)
        ctx.player.stop()
        try? ctx.fm.removeItem(at: root)
        try? ctx.fm.removeItem(at: LibraryStore.selfTestResumeURL)
    }

    // MARK: - 素材与工具

    /// 素材一律造在临时目录，不进 testlib（AGENTS 坑 #7：别把造出来的东西留在曲库里）
    private func tempRoot(_ ctx: SelfTestContext) -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ttplayer-scene", isDirectory: true)
        try? ctx.fm.removeItem(at: root)
        try? ctx.fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func trackNamed(_ ctx: SelfTestContext, _ name: String) -> Track? {
        ctx.player.playlist.tracks.first { $0.url.lastPathComponent == name }
    }

    /// 只装两份 testlib 样本：队列断言要的是「次序」，整库那种七八条会把期望值搅成一长串
    private func installPair(_ ctx: SelfTestContext, _ names: [String]) -> [Track] {
        let p = ctx.player
        p.clearPlaylist()
        let urls = names.map { ctx.dir.appendingPathComponent($0) }
        _ = p.addFiles(urls)
        return p.playlist.tracks
    }

    private func mtime(_ url: URL) -> TimeInterval {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
    }

    private func sizeOf(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    }

    /// 第 i 段那一块的频率：拿它判「真放出来的是哪一段」
    private func freq(ofBlock i: Int) -> Double { 200 + 100 * Double(i) }

    /// 采到的 PCM 到底落在哪一段：逐段算音高能量，取最强的一段与次强一段。
    /// 只取最强不够，还要它把次强拉开至少 3 倍：跨段边界的一小段会同时像两段，那种时候
    /// 判「就是这一段」是给不出结论的
    private func blockGuess(_ ctx: SelfTestContext, _ samples: [Float], rate: Double,
                            blocks: Int) -> (block: Int, best: Double, runner: Double) {
        let energies = (0..<blocks).map { ctx.toneEnergy(samples, sampleRate: rate,
                                                          freq: freq(ofBlock: $0)) }
        let sorted = energies.enumerated().sorted { $0.element > $1.element }
        guard let top = sorted.first else { return (-1, 0, 0) }
        return (top.offset, top.element, sorted.count > 1 ? sorted[1].element : 0)
    }

    // MARK: - 现场数据面（纯逻辑）

    private func checkSceneCodable(_ ctx: SelfTestContext) {
        var s = ResumeScene()
        s.trackKey = "/tmp/a.wav"
        s.position = 3.25
        s.wasPlaying = true
        s.queueKeys = ["/tmp/a.wav", "/tmp/b.wav", "/tmp/a.wav"]
        s.queueExplicit = [false, true, true]
        s.queueIndex = 2
        s.historyIndexes = [0, 2]
        s.group = "favorites"
        let data = (try? JSONEncoder().encode(s)) ?? Data()
        let back = try? JSONDecoder().decode(ResumeScene.self, from: data)
        ctx.check("现场-全字段往返",
                  back?.trackKey == s.trackKey && back?.position == 3.25
                    && back?.wasPlaying == true && back?.queueKeys == s.queueKeys
                    && back?.queueExplicit == s.queueExplicit && back?.queueIndex == 2
                    && back?.historyIndexes == [0, 2] && back?.group == "favorites",
                  "bytes=\(data.count)")

        // 旧版现场：只有当时存在的那几笔，新增字段必须缺省可用（不能整档解不开）
        let legacyJSON = "{\"trackKey\":\"/tmp/a.wav\",\"position\":2}"
        let legacy = try? JSONDecoder().decode(ResumeScene.self, from: Data(legacyJSON.utf8))
        ctx.check("现场-旧版写法缺字段也能解",
                  legacy?.trackKey == "/tmp/a.wav" && legacy?.position == 2
                    && legacy?.queueKeys.isEmpty == true && legacy?.wasPlaying == false
                    && legacy?.group == "",
                  "group=\(String(describing: legacy?.group))")

        // 进程被强杀时可能只写了一半、或者被手改过：矛盾字段要夹回合法范围
        var bad = ResumeScene()
        bad.queueKeys = ["k0", "k1"]
        bad.queueIndex = 7
        bad.position = -3
        bad.historyIndexes = [-1, 0, 5]
        bad.queueExplicit = [true]
        let fixed = bad.sanitized
        ctx.check("现场-矛盾字段夹回合法范围",
                  fixed.queueIndex == 1 && fixed.position == 0
                    && fixed.historyIndexes == [0] && fixed.queueExplicit == [false, false],
                  "idx=\(fixed.queueIndex) pos=\(fixed.position) hist=\(fixed.historyIndexes) "
                    + "flags=\(fixed.queueExplicit)")
        var nan = ResumeScene()
        nan.position = .nan
        ctx.check("现场-非法进度归零", nan.sanitized.position == 0)
        ctx.check("现场-什么都没有算空现场", ResumeScene().isEmpty)
        var only = ResumeScene()
        only.trackKey = "/tmp/a.wav"
        ctx.check("现场-只有当前曲不算空", !only.isEmpty)
        let halfWritten = (try? JSONDecoder().decode(ResumeScene.self,
                                                    from: Data("{\"trackKey\": [".utf8))) != nil
        ctx.check("现场-半截 JSON 解不开", !halfWritten)

        let bare = try? JSONDecoder().decode(AppState.self, from: Data("{}".utf8))
        ctx.check("现场-整档新增字段缺省为关",
                  bare?.autoResumePlay == false && bare?.volume == 0.8,
                  "autoResume=\(String(describing: bare?.autoResumePlay))")
    }

    private func checkGroupCodable(_ ctx: SelfTestContext) {
        let kinds: [GroupKind] = [.main, .radio, .recentRadio, .recent, .favorites, .playlist("lst-1")]
        let back = kinds.map { GroupKind(archiveValue: $0.archiveValue) }
        ctx.check("现场-浏览组写法往返", back == kinds,
                  "写=\(kinds.map { $0.archiveValue }.joined(separator: ","))")
        ctx.check("现场-认不出的浏览组回默认",
                  GroupKind(archiveValue: "") == nil && GroupKind(archiveValue: "favorites2") == nil)
        ctx.check("现场-歌单页存 ID 不存名字",
                  GroupKind(archiveValue: "playlist:lst-1") == .playlist("lst-1"))
    }

    // MARK: - 快照内容

    private func checkSnapshotShape(_ ctx: SelfTestContext) {
        let p = ctx.player
        ctx.resetLibrary()
        guard let a = trackNamed(ctx, "demo01.wav"), let b = trackNamed(ctx, "demo02.wav") else {
            ctx.emit("[selftest] SKIP 播放现场（testlib 缺 demo01/demo02.wav）")
            return
        }
        _ = installPair(ctx, ["demo01.wav", "demo02.wav"])
        p.play(track: a)
        _ = ctx.waitUntil(3) { p.isPlaying }
        ctx.pump(0.6)
        p.playNext([b])
        p.playLater([a])              // 同一首歌再排一次：必须是两个条目而不是并成一条
        let s = p.snapshotScene()
        let names = s.queueKeys.map { ($0 as NSString).lastPathComponent }
        // 双击建立的上下文是 [a, b]，「下一首播放」再塞一条 b、「稍后播放」再塞一条 a
        ctx.check("现场-队列次序含重复曲目",
                  s.queueKeys == [a.identityKey, b.identityKey, b.identityKey, a.identityKey],
                  "keys=\(names.joined(separator: ","))")
        ctx.check("现场-显式排队标记逐条对应", s.queueExplicit == [false, true, false, true],
                  "flags=\(s.queueExplicit)")
        ctx.check("现场-当前位置与当前曲",
                  s.queueIndex == 0 && s.trackKey == a.identityKey,
                  "idx=\(s.queueIndex) key=\(s.trackKey)")
        ctx.check("现场-退出前在播记为真", s.wasPlaying)
        let dur = p.engine.duration
        ctx.check("现场-进度落在本曲区间内", s.position > 0.2 && s.position < dur,
                  String(format: "pos=%.2f dur=%.2f", s.position, dur))

        p.next()
        let s2 = p.snapshotScene()
        ctx.check("现场-历史写下标序列", s2.historyIndexes == [0, 1], "hist=\(s2.historyIndexes)")
        ctx.check("现场-当前曲跟着队列走", s2.queueIndex == 1 && s2.trackKey == b.identityKey)
        p.stop()
        let s3 = p.snapshotScene()
        ctx.check("现场-停止后不再自动开播", !s3.wasPlaying)
        ctx.check("现场-停止后进度归零", s3.position < 0.05, String(format: "pos=%.2f", s3.position))
    }

    // MARK: - 真实 PCM 取证

    /// 恢复位置不是计时器上的数：接着放，采实际输出链路的 PCM，看是不是那一段的声音
    private func checkResumeIsRealAudio(_ ctx: SelfTestContext, root: URL) {
        let p = ctx.player
        let wave = root.appendingPathComponent("step.wav")
        // 半秒一段、逐段上 100 Hz：位置能钉在半秒以内
        guard ctx.writeStepWave(wave, seconds: 6, blockSeconds: 0.5) else {
            ctx.check("现场-分段单音素材造得出来", false); return
        }
        p.clearPlaylist()
        guard p.addFiles([wave]) == 1, let t = p.playlist.tracks.first else {
            ctx.check("现场-分段单音素材能入表", false); return
        }
        p.play(track: t)
        _ = ctx.waitUntil(3) { p.isPlaying }
        // 落在半秒一段的这一段正中间（4.0–4.5）：取数时差、调度提前量都跳不出这一段
        p.seek(to: 4.25)
        p.flushScene()
        let saved = LibraryStore.loadResume()
        ctx.check("现场-落盘的能原样读回",
                  saved.trackKey == t.identityKey && abs(saved.position - 4.25) < 0.4
                    && saved.wasPlaying,
                  String(format: "pos=%.2f playing=%d", saved.position, saved.wasPlaying ? 1 : 0))

        p.resetPlaybackContextForRestore()
        ctx.check("现场-模拟重启后引擎空载",
                  p.queue.isEmpty && p.engine.duration == 0 && !p.isPlaying,
                  "n=\(p.queue.count) dur=\(p.engine.duration)")
        p.restorePlaybackScene(saved)
        ctx.check("现场-默认恢复为暂停",
                  !p.isPlaying && p.currentTrack?.identityKey == t.identityKey)
        ctx.check("现场-恢复后不落「上次在播」", !LibraryStore.loadResume().wasPlaying,
                  "否则下次启动会多一次自动开播")
        let clock = p.engine.currentTime
        ctx.check("现场-计时接回原处", clock > 4.0 && clock < 4.5, String(format: "%.2f s", clock))

        p.togglePlay()
        _ = ctx.waitUntil(2) { p.isPlaying }
        // 只分析前 0.1 s：采得越久越可能跨过换段的那条边界，跨了就判不出唯一解
        let cap = ctx.captureLeftChannel(p, seconds: 0.2)
        let rate = cap.sampleRate
        let frames = min(cap.samples.count, Int(0.1 * rate))
        guard frames > 2_000 else {
            ctx.check("现场-采到实际输出链路 PCM", false, "n=\(cap.samples.count)"); return
        }
        let seg = Array(cap.samples[0..<frames])
        let guess = blockGuess(ctx, seg, rate: rate, blocks: 12)
        // 波形比对拿「对的位置」与「错开 1.5 s」对比：音频图重采样会拉低绝对相关度，
        // 只卡一个绝对阈值会把好实现在机器之间跑飘
        let probe = Int(0.06 * rate)
        let sim = ctx.bestSimilarity(seg, url: wave, center: clock, frames: probe)
        let far = ctx.bestSimilarity(seg, url: wave, center: clock + 1.5, frames: probe)
        ctx.check("现场-放出来的是那一段的真实 PCM",
                  guess.block == Int(saved.position / 0.5) && guess.best > 0.3
                    && guess.best > 3 * guess.runner && sim > 0.6 && far < 0.4,
                  String(format: "第 %d 段 best=%.2f 次强=%.2f sim=%.2f 错开=%.2f n=%d",
                         guess.block, guess.best, guess.runner, sim, far, frames))
        p.stop()
    }

    // MARK: - 「启动后自动继续播放」的两条件

    private func checkAutoResumeBranches(_ ctx: SelfTestContext, root: URL) {
        let p = ctx.player
        let wave = root.appendingPathComponent("step.wav")
        guard ctx.writeStepWave(wave, seconds: 6) else {
            ctx.check("现场-自动开播分支素材", false); return
        }
        p.clearPlaylist()
        guard p.addFiles([wave]) == 1, let t = p.playlist.tracks.first else {
            ctx.check("现场-自动开播分支能入表", false); return
        }
        var scene = ResumeScene()
        scene.trackKey = t.identityKey
        scene.queueKeys = [t.identityKey]
        scene.queueExplicit = [false]
        scene.queueIndex = 0
        scene.position = 2.0
        scene.wasPlaying = true

        // 1) 开关关着：上次在播也只到暂停（默认就是这个口径）
        p.setAutoResumePlay(false)
        p.resetPlaybackContextForRestore()
        p.restorePlaybackScene(scene)
        let paused = p.engine.currentTime
        ctx.check("现场-开关关时不自已开声",
                  !p.isPlaying && paused > 1.4 && paused < 2.6, String(format: "%.2f s", paused))

        // 2) 开关开着、但上次是手动停止的：还是不播（用户明确说过「停」）
        p.stop()
        var stopped = scene
        stopped.wasPlaying = false
        p.setAutoResumePlay(true)
        p.resetPlaybackContextForRestore()
        p.restorePlaybackScene(stopped)
        ctx.check("现场-手动停止过就不自动开播", !p.isPlaying)

        // 3) 开关开着 + 上次确实在播：自动接上，接的还是原来那一首
        p.resetPlaybackContextForRestore()
        p.restorePlaybackScene(scene)
        let auto = p.engine.currentTime
        ctx.check("现场-开关开着就自动接上",
                  p.isPlaying && p.currentTrack?.identityKey == t.identityKey
                    && auto > 1.4 && auto < 3.2, String(format: "%.2f s", auto))
        p.stop()

        // 4) 时长变短（文件被重新编码过）：夹紧恢复位置，不拿越界秒数去 seek
        p.setAutoResumePlay(false)
        let dur = p.engine.duration
        var huge = scene
        huge.position = dur * 20
        p.resetPlaybackContextForRestore()
        p.restorePlaybackScene(huge)
        let clamped = p.engine.currentTime
        ctx.check("现场-时长变短就夹紧位置",
                  clamped <= p.engine.duration + 0.05 && clamped > p.engine.duration - 0.6,
                  String(format: "at=%.2f dur=%.2f", clamped, p.engine.duration))

        // 5) 停在结尾附近又自动开播：回到开头，不能一开声就「本曲播完 → 下一首」
        p.setAutoResumePlay(true)
        var tail = scene
        tail.position = dur
        p.resetPlaybackContextForRestore()
        p.restorePlaybackScene(tail)
        ctx.check("现场-停在结尾就从头播不跳曲",
                  p.isPlaying && p.engine.currentTime < 0.8 && p.queue.currentIndex == 0,
                  String(format: "at=%.2f idx=%@", p.engine.currentTime,
                         p.queue.currentIndex.map(String.init) ?? "nil"))
        p.stop()
        p.setAutoResumePlay(false)
    }

    // MARK: - 队列次序、重复条目、历史与浏览组

    private func checkQueueOrderAndGroup(_ ctx: SelfTestContext) {
        let p = ctx.player
        ctx.resetLibrary()
        guard let a = trackNamed(ctx, "demo01.wav"), let b = trackNamed(ctx, "demo02.wav") else {
            ctx.check("现场-队列次序素材", false); return
        }
        _ = installPair(ctx, ["demo01.wav", "demo02.wav"])
        p.play(track: a)
        _ = ctx.waitUntil(3) { p.isPlaying }
        p.playNext([b])
        p.playLater([a])
        p.next()                       // 轮到 b：历史就成了 [0, 1]
        _ = ctx.waitUntil(3) { p.currentTrack?.identityKey == b.identityKey }
        p.toggleFavorite(b)
        p.switchGroup(.favorites)      // 上次退出时正看着「我的收藏」
        let s = p.snapshotScene()
        ctx.check("现场-记住当前浏览组", s.group == GroupKind.favorites.archiveValue,
                  "group=\(s.group)")
        ctx.check("现场-历史含显式排队条目", s.historyIndexes == [0, 1],
                  "hist=\(s.historyIndexes)")

        // 「上一进程」的痕迹全清，连浏览列表也清掉：条目只能从存档写法重建
        p.stop()
        p.switchGroup(.main)
        p.clearPlaylist()
        p.resetPlaybackContextForRestore()
        p.restorePlaybackScene(s)
        ctx.check("现场-队列次序与重复条目原样回来",
                  p.queue.items.map { $0.track.identityKey } == s.queueKeys,
                  "n=\(p.queue.count) keys=\(p.queue.items.map { $0.track.fileName })")
        ctx.check("现场-显式排队标记回来", p.queue.items.map { $0.explicit } == s.queueExplicit,
                  "flags=\(p.queue.items.map { $0.explicit })")
        ctx.check("现场-当前位置回来",
                  p.queue.currentIndex == s.queueIndex
                    && p.currentTrack?.identityKey == b.identityKey,
                  "idx=\(String(describing: p.queue.currentIndex))")
        let ids = p.queue.items.map { $0.id }
        let hist = p.queue.history.compactMap { ids.firstIndex(of: $0) }
        ctx.check("现场-播放历史跟着条目走", hist == s.historyIndexes,
                  "hist=\(hist) 期望=\(s.historyIndexes)")
        ctx.check("现场-浏览组回来", p.activeGroup == .favorites, p.activeGroup.name)
        ctx.check("现场-恢复后仍是暂停", !p.isPlaying)
        p.switchGroup(.main)
        p.stop()
    }

    // MARK: - CUE 段内时基

    private func checkCueSegmentTimeBase(_ ctx: SelfTestContext, root: URL) {
        let p = ctx.player
        let wave = root.appendingPathComponent("step.wav")
        // 与上面同一张镜像：半秒一段，段内位置才能反推到镜像上的哪半秒
        guard ctx.writeStepWave(wave, seconds: 6, blockSeconds: 0.5) else {
            ctx.check("现场-CUE 素材", false); return
        }
        let cue = root.appendingPathComponent("album.cue")
        let text = """
        TITLE "SceneAlbum"
        FILE "step.wav" WAVE
          TRACK 01 AUDIO
            TITLE "One"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Two"
            INDEX 01 00:04:00
        """
        do {
            try text.write(to: cue, atomically: true, encoding: .utf8)
        } catch {
            ctx.check("现场-CUE 素材写得出来", false, "\(error)"); return
        }
        let tracks = LibraryStore.tracks(in: [cue])
        guard tracks.count == 2 else {
            ctx.check("现场-CUE 分轨展开两条", false, "n=\(tracks.count)"); return
        }
        let seg = tracks[1]
        ctx.check("现场-CUE 身份含轨号", seg.identityKey == "\(cue.path)#track=2", seg.identityKey)
        p.clearPlaylist()
        _ = p.addTracks(tracks)
        p.play(track: seg)
        _ = ctx.waitUntil(3) { p.isPlaying }
        p.seek(to: 1.2)               // 段内 1.2 s = 镜像 5.2 s（落在 5.0–5.5 这一段正中）
        let s = p.snapshotScene()
        ctx.check("现场-CUE 进度是分轨内位置",
                  s.position > 1.1 && s.position < 1.5 && s.queueIndex == 1,
                  String(format: "pos=%.2f idx=%d", s.position, s.queueIndex))

        p.stop()
        p.clearPlaylist()             // 列表也空掉：恢复要重解分轨表，不能靠内存里的对象
        p.resetPlaybackContextForRestore()
        p.restorePlaybackScene(s)
        ctx.check("现场-CUE 条目身份回来", p.currentTrack?.identityKey == seg.identityKey)
        ctx.check("现场-CUE 时长按本段算", abs(p.engine.duration - 2.0) < 0.25,
                  String(format: "dur=%.2f", p.engine.duration))
        let at = p.engine.currentTime
        ctx.check("现场-CUE 段内进度接回", at > 1.1 && at < 1.5, String(format: "%.2f s", at))
        p.togglePlay()
        _ = ctx.waitUntil(2) { p.isPlaying }
        let cap = ctx.captureLeftChannel(p, seconds: 0.2)
        let frames = min(cap.samples.count, Int(0.1 * cap.sampleRate))
        guard frames > 2_000 else {
            ctx.check("现场-CUE 采到 PCM", false, "n=\(cap.samples.count)"); return
        }
        let segPcm = Array(cap.samples[0..<frames])
        // 段内那一秒就是镜像 4.0 + 1.2 = 5.2 s（第 10 段 = 1200 Hz）。若错拿镜像绝对时间当段内，
        // 会去放镜像第 1.2 秒（第 2 段 = 400 Hz），两者一听就能分开
        let guess = blockGuess(ctx, segPcm, rate: cap.sampleRate, blocks: 12)
        let image = seg.playStart + at
        let probe = Int(0.06 * cap.sampleRate)
        let sim = ctx.bestSimilarity(segPcm, url: wave, center: image, frames: probe)
        let far = ctx.bestSimilarity(segPcm, url: wave, center: max(0, image - 1.5), frames: probe)
        ctx.check("现场-CUE 放出来的是本段的声音",
                  guess.block == Int(image / 0.5) && guess.best > 0.3
                    && guess.best > 3 * guess.runner && sim > 0.6 && far < 0.4,
                  String(format: "镜像第 %d 段 best=%.2f 次强=%.2f sim=%.2f 错开=%.2f",
                         guess.block, guess.best, guess.runner, sim, far))
        p.stop()
    }

    // MARK: - 归档条目

    private func checkArchiveEntry(_ ctx: SelfTestContext, root: URL) {
        let p = ctx.player
        let stage = root.appendingPathComponent("stage", isDirectory: true)
        try? ctx.fm.createDirectory(at: stage, withIntermediateDirectories: true)
        let names = ["01 - alpha.wav", "02 - beta.wav"]
        do {
            for (src, name) in zip(["demo01.wav", "demo02.wav"], names) {
                let dst = stage.appendingPathComponent(name)
                try? ctx.fm.removeItem(at: dst)
                try ctx.fm.copyItem(at: ctx.dir.appendingPathComponent(src), to: dst)
            }
        } catch {
            ctx.emit("[selftest] SKIP 现场-归档条目（拷不进素材：\(error)）")
            return
        }
        let zipURL = root.appendingPathComponent("scene.zip")
        try? ctx.fm.removeItem(at: zipURL)
        guard ctx.runTool("/usr/bin/zip",
                          ["-q", "-j", zipURL.path] + names, cwd: stage) else {
            ctx.emit("[selftest] SKIP 现场-归档条目（本机没有 zip）")
            return
        }
        p.clearPlaylist()
        guard p.addFiles([zipURL]) == 2, let second = p.playlist.tracks.last else {
            ctx.check("现场-归档条目能入表", false); return
        }
        p.play(track: second)
        _ = ctx.waitUntil(3) { p.isPlaying }
        p.seek(to: 3.0)
        ctx.pump(0.3)
        let s = p.snapshotScene()
        ctx.check("现场-归档条目写完整条目 URL",
                  s.trackKey.contains("#archive-entry=")
                    && s.queueKeys.filter { $0.contains("#archive-entry=") }.count == 2,
                  "keys=\(s.queueKeys.count)")

        p.stop()
        p.clearPlaylist()             // 归档条目也得从写法重建（不靠内存对象）
        p.resetPlaybackContextForRestore()
        p.restorePlaybackScene(s)
        ctx.check("现场-归档条目身份与次序回来",
                  p.queue.items.map { $0.track.identityKey } == s.queueKeys
                    && p.currentTrack?.identityKey == s.trackKey,
                  "n=\(p.queue.count)")
        ctx.check("现场-归档条目仍指向条目而非外层",
                  p.currentTrack?.url.fragment?.hasPrefix("archive-entry=") == true,
                  p.currentTrack?.url.absoluteString ?? "nil")
        let at = p.engine.currentTime
        ctx.check("现场-归档条目进度接回",
                  p.engine.duration > 8 && at > 2.4 && at < 3.7,
                  String(format: "at=%.2f dur=%.2f", at, p.engine.duration))
        p.stop()
    }

    // MARK: - 电台

    private func checkRadioScene(_ ctx: SelfTestContext, root: URL) {
        let p = ctx.player
        // 先让引擎里装着本地曲，再看恢复电台时会不会把上一首的时长报成电台的时长
        let wave = root.appendingPathComponent("step.wav")
        guard ctx.writeStepWave(wave, seconds: 6) else {
            ctx.check("现场-电台段素材", false); return
        }
        p.clearPlaylist()
        guard p.addFiles([wave]) == 1, let local = p.playlist.tracks.first else {
            ctx.check("现场-电台段本地装载", false); return
        }
        p.play(track: local)
        _ = ctx.waitUntil(3) { p.isPlaying }
        ctx.check("现场-本地装载后有时长", p.engine.duration > 1,
                  String(format: "dur=%.2f", p.engine.duration))
        p.stop()

        // 回环地址 + 没人监听的小端口：真去连就会立刻失败，不出网、不拿别人的台做实验
        guard let addr = URL(string: "http://127.0.0.1:1/ttplayer-selftest/live") else {
            ctx.check("现场-电台地址构造", false); return
        }
        let key = Track(radio: addr).identityKey
        var s = ResumeScene()
        s.trackKey = key
        s.queueKeys = [key]
        s.queueExplicit = [false]
        s.queueIndex = 0
        s.position = 7          // 故意写一笔：直播没有「接着第 7 秒」可言，恢复必须忽略它
        s.wasPlaying = false
        p.resetPlaybackContextForRestore()
        p.restorePlaybackScene(s)
        ctx.check("现场-电台只恢复地址不重连", !p.engine.isRadio && !p.isPlaying,
                  "isRadio=\(p.engine.isRadio)")
        ctx.check("现场-电台不伪造进度与时长",
                  p.engine.currentTime == 0 && p.engine.duration == 0,
                  String(format: "at=%.2f dur=%.2f", p.engine.currentTime, p.engine.duration))
        ctx.check("现场-电台条目身份是完整地址",
                  p.currentTrack?.isRadio == true && p.currentTrack?.identityKey == key,
                  p.currentTrack?.identityKey ?? "nil")
        ctx.check("现场-电台恢复不报错", p.playbackProblem == nil, p.playbackProblem ?? "")
        p.togglePlay()
        ctx.check("现场-按播放才真去连直播", p.engine.isRadio)
        p.stop()
    }

    // MARK: - 失效条目

    private func checkInvalidEntries(_ ctx: SelfTestContext, root: URL) {
        let p = ctx.player
        let f1 = root.appendingPathComponent("one.wav")
        let f2 = root.appendingPathComponent("two.wav")
        try? ctx.fm.removeItem(at: f1)
        try? ctx.fm.removeItem(at: f2)
        do {
            try ctx.fm.copyItem(at: ctx.dir.appendingPathComponent("demo01.wav"), to: f1)
            try ctx.fm.copyItem(at: ctx.dir.appendingPathComponent("demo02.wav"), to: f2)
        } catch {
            ctx.check("现场-失效条目素材", false, "\(error)"); return
        }
        p.clearPlaylist()
        guard p.addFiles([f1, f2]) == 2 else {
            ctx.check("现场-失效条目素材能入表", false); return
        }
        let keys = p.playlist.tracks.map { $0.identityKey }
        let ghost = "file:///no/such/dir/ghost.zip#archive-entry=ghost.wav"
        var s = ResumeScene()
        s.queueKeys = keys + [ghost]
        s.queueExplicit = [false, false, true]
        s.queueIndex = 1
        s.historyIndexes = [1]
        s.trackKey = keys[1]
        s.position = 1.0
        // 当前曲还在，第一条文件没了、末条外层归档没了
        try? ctx.fm.removeItem(at: f1)
        p.stop()
        p.clearPlaylist()
        p.resetPlaybackContextForRestore()
        p.restorePlaybackScene(s)
        let back = p.queue.items.map { $0.track.identityKey }
        ctx.check("现场-失效条目留占位不顶歪次序",
                  p.queue.count == 3 && back == s.queueKeys && p.queue.currentIndex == 1,
                  "n=\(p.queue.count) idx=\(String(describing: p.queue.currentIndex))")
        let flags = p.queue.items.prefix(3).map { $0.track.missingOnDisk }
        ctx.check("现场-解不开的写法标失效", flags == [true, false, true], "flags=\(flags)")
        let at = p.engine.currentTime
        ctx.check("现场-有效条目照常恢复", p.engine.duration > 8 && at > 0.6 && at < 1.6,
                  String(format: "at=%.2f dur=%.2f", at, p.engine.duration))

        // 当前曲本身就没了：说清原因、保留其余条目、不擅自播另一首
        try? ctx.fm.removeItem(at: f2)
        p.stop()
        p.resetPlaybackContextForRestore()
        p.restorePlaybackScene(s)
        let note = p.playbackProblem ?? ""
        ctx.check("现场-当前曲缺失要说清原因", note.contains("已不在磁盘上"), note)
        ctx.check("现场-缺失时不擅自换一首",
                  p.currentTrack?.identityKey == s.trackKey && !p.isPlaying
                    && p.engine.duration == 0)
        ctx.check("现场-缺失时其余队列保留",
                  p.queue.count == 3 && p.queue.currentIndex == 1, "n=\(p.queue.count)")
        p.stop()
    }

    // MARK: - 旧版存档

    private func checkLegacyScene(_ ctx: SelfTestContext) {
        let p = ctx.player
        let url = LibraryStore.selfTestResumeURL
        let path = ctx.dir.appendingPathComponent("demo01.wav").path
        guard let data = "{\"trackKey\":\"\(path)\",\"position\":2}".data(using: .utf8) else {
            ctx.check("现场-旧版现场编码", false); return
        }
        try? data.write(to: url)
        let s = LibraryStore.loadResume()
        ctx.check("现场-旧版现场只两笔也能解",
                  s.trackKey == path && s.position == 2 && s.queueKeys.isEmpty && s.group.isEmpty,
                  "group=\(s.group)")
        p.stop()
        p.clearPlaylist()
        p.resetPlaybackContextForRestore()
        p.restorePlaybackScene(s)
        let at = p.engine.currentTime
        ctx.check("现场-旧版现场补一段单条目上下文",
                  p.queue.count == 1 && p.currentTrack?.url.path == path && !p.isPlaying
                    && at > 1.5 && at < 2.6, String(format: "n=%d at=%.2f", p.queue.count, at))

        // 半截文件（进程被强杀在写的中途）：当没有现场处理，正常启动，不报错也不开播
        try? Data("{\"trackKey\": [".utf8).write(to: url)
        ctx.check("现场-半截现场文件当没有", LibraryStore.loadResume().isEmpty)
        let before = p.queue.count
        p.restorePlaybackScene(LibraryStore.loadResume())
        ctx.check("现场-空现场不动已有上下文",
                  p.queue.count == before && p.currentTrack?.url.path == path && !p.isPlaying)
        // 根本没有这个文件（首次运行）也是同一条路
        try? ctx.fm.removeItem(at: url)
        ctx.check("现场-没有现场文件就是空", LibraryStore.loadResume().isEmpty)
    }

    // MARK: - 落盘纪律

    private func checkFlushDiscipline(_ ctx: SelfTestContext) {
        let p = ctx.player
        let resume = LibraryStore.selfTestResumeURL
        let state = LibraryStore.selfTestStateURL
        ctx.resetLibrary()
        guard let a = trackNamed(ctx, "demo01.wav"), let b = trackNamed(ctx, "demo02.wav") else {
            ctx.check("现场-落盘纪律素材", false); return
        }
        p.play(track: a)
        _ = ctx.waitUntil(3) { p.isPlaying }
        p.stop()                  // 停止当场落一笔，从这里起算节流窗口
        let m0 = mtime(resume)
        let stateBytes = sizeOf(state)
        let stateMtime = mtime(state)
        ctx.check("现场-停止当场落盘", m0 > 0, "mtime=\(m0)")
        // 20 次队列改动：节流期内既不该一笔一笔写现场，更不该顺手重写整库
        for _ in 0..<20 {
            p.playNext([b])
            p.clearPendingQueue()
        }
        ctx.pump(0.4)
        ctx.check("现场-频繁改队列不逐次落盘", mtime(resume) == m0,
                  "m0=\(m0) m1=\(mtime(resume))")
        ctx.check("现场-落现场不重写整库",
                  sizeOf(state) == stateBytes && mtime(state) == stateMtime,
                  "state bytes=\(stateBytes)→\(sizeOf(state))")
        let wrote = ctx.waitUntil(PlayerController.sceneFlushInterval + 2) {
            mtime(resume) != m0
        }
        ctx.check("现场-到点补一笔进度", wrote,
                  "间隔=\(PlayerController.sceneFlushInterval)s")
        p.flushScene()
        let bytes = sizeOf(resume)
        ctx.check("现场-现场文件是小文件", bytes > 0 && bytes < 8_192, "bytes=\(bytes)")
        ctx.check("现场-现场文件里就是现场字段",
                  (try? String(contentsOf: resume, encoding: .utf8))?.contains("\"position\"") == true)
        p.stop()
    }

    // MARK: - 用户入口

    private func checkUserEntry(_ ctx: SelfTestContext) {
        let p = ctx.player
        let title = "启动后自动继续播放"
        let item = ctx.main.buildPopupMenu().items.first { $0.title == title }
        ctx.check("现场-设置里有这个开关",
                  item != nil && item?.state == .off && !p.autoResumePlay,
                  "state=\(String(describing: item?.state.rawValue))")
        guard let item, let action = item.action else { return }
        ctx.check("现场-开关可点", NSApp.sendAction(action, to: item.target, from: item))
        ctx.check("现场-点一次就打开", p.autoResumePlay && LibraryStore.load().autoResumePlay)
        ctx.check("现场-菜单按当前值打勾",
                  ctx.main.buildPopupMenu().items.first { $0.title == title }?.state == .on)
        _ = NSApp.sendAction(action, to: item.target, from: item)
        ctx.check("现场-再点一次关掉", !p.autoResumePlay && !LibraryStore.load().autoResumePlay)
    }
}
