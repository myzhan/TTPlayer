import Foundation
import AppKit

/// 真实播放链路：添加/元数据/推进/暂停/恢复/拖动/音量/静音/均衡器/模式/切曲/停止/持久化，
/// 以及“整曲播完靠渲染时钟切下一轨”这条容易退化的判定。
/// 断言前的等待全部改成等条件成立，不再堆固定延时。
struct PlaybackSuite: SelfTestSuite {
    func run(_ ctx: SelfTestContext) {
        let p = ctx.player
        guard !ctx.libraryURLs.isEmpty else {
            ctx.emit("[selftest] SKIP 播放链路（测试目录没有可播放文件）")
            return
        }
        // prepare(.library) 已经清空并按同一批文件加过一遍，这里验的是添加链路本身
        ctx.check("添加文件", ctx.libraryAdded > 0, "list=\(p.playlist.count)")

        // 元数据是异步解析的：等首曲时长落地再验，比固定等 1.2 秒快且稳
        _ = ctx.waitUntil(3.0) { (p.playlist.tracks.first?.duration ?? 0) > 0 }
        let t0 = p.playlist.tracks.first
        ctx.check("元数据-时长", (t0?.duration ?? 0) > 0, "dur=\(String(format: "%.2f", t0?.duration ?? 0))")
        ctx.check("元数据-采样率", (t0?.sampleRate ?? 0) > 0, "sr=\(t0?.sampleRate ?? 0)")
        ctx.check("元数据-声道", (t0?.channels ?? 0) > 0, "ch=\(t0?.channels ?? 0)")
        ctx.check("元数据-码率", (t0?.bitRateKbps ?? 0) > 0, "kbps=\(t0?.bitRateKbps ?? 0)")

        p.playRowAt(0)
        _ = ctx.waitUntil(4.0) { p.isPlaying && p.currentTime > 0.3 }
        let ct = p.currentTime
        ctx.check("播放-推进", p.isPlaying && ct > 0.3 && ct < 6.0,
                  "playing=\(p.isPlaying) t=\(String(format: "%.2f", ct))")
        let bars = p.engine.spectrum.bars
        ctx.check("播放-频谱活跃", bars.max() ?? 0 > 0.05,
                  "max=\(String(format: "%.3f", bars.max() ?? 0))")
        // 歌词跟着同名 .lrc 走，而带词的那首未必排在第一行（封面素材会抢位），
        // 所以显式跳到 demo01 再验（loadLyric 是同步的，切完就能读）
        if let lyricRow = p.playlist.tracks.firstIndex(where: {
            $0.url.deletingPathExtension().lastPathComponent == "demo01"
        }) {
            p.playRowAt(lyricRow)
        }
        ctx.check("歌词-加载", p.lyric?.isEmpty == false,
                  "lines=\(p.lyric?.lines.count ?? -1)")

        // 暂停 → 位置冻结
        p.togglePlay()
        let pausedAt = p.currentTime
        ctx.pump(0.8)
        ctx.check("暂停-位置冻结", abs(p.currentTime - pausedAt) < 0.6,
                  "before=\(String(format: "%.2f", pausedAt)) after=\(String(format: "%.2f", p.currentTime))")

        // 恢复 → 继续推进
        p.togglePlay()
        _ = ctx.waitUntil(3.0) { p.currentTime > pausedAt + 0.2 }
        ctx.check("恢复-继续推进", p.currentTime > pausedAt + 0.2,
                  "t=\(String(format: "%.2f", p.currentTime)) vs paused=\(String(format: "%.2f", pausedAt))")

        // Seek
        p.seek(to: 4.0)
        ctx.check("Seek", abs(p.currentTime - 4.0) < 0.8,
                  "t=\(String(format: "%.2f", p.currentTime))")

        // 音量 / 静音 / EQ
        p.setVolume(0.3)
        ctx.check("音量", abs(p.volume - 0.3) < 0.001)
        p.toggleMute()
        ctx.check("静音", p.isMuted)
        p.toggleMute()
        p.setEQGain(band: 2, gain: 6.0)
        ctx.check("均衡器增益", abs(p.engine.eqGain(band: 2) - 6.0) < 0.01)
        ctx.check("均衡器 10 段", p.engine.eq.bands.count == AudioEngine.eqBandCount,
                  "bands=\(p.engine.eq.bands.count)")
        p.setEQEnabled(false)
        ctx.check("均衡器旁路", p.engine.eq.bypass)
        p.setEQEnabled(true)

        // 播放模式切换
        p.setMode(.random)
        ctx.check("模式切换", p.playMode == .random)
        p.setMode(.listLoop)

        // 切下一曲
        let before = p.playlist.currentIndex
        p.next()
        ctx.check("下一曲", p.playlist.currentIndex != before || p.playlist.count == 1,
                  "idx=\(String(describing: p.playlist.currentIndex))")

        p.stop()
        ctx.check("停止", !p.isPlaying && p.currentTime < 0.05,
                  "t=\(String(format: "%.2f", p.currentTime))")

        // 持久化
        p.persistNow()
        let reloaded = LibraryStore.load()
        ctx.check("持久化", reloaded.trackPaths.count == p.playlist.count && reloaded.playMode == 2,
                  "paths=\(reloaded.trackPaths.count) mode=\(reloaded.playMode)")

        // 整曲结束判定：排期数据放完后 playerNode.isPlaying 仍是 true，
        // 只有渲染时钟走到曲尾才算完，所以要等 currentIndex 真的翻篇
        p.clearPlaylist()
        _ = p.addFiles(ctx.libraryURLs)
        guard p.playlist.count >= 2 else {
            ctx.check("整曲播完自动切下一曲", false, "list=\(p.playlist.count)")
            p.stop()
            return
        }
        p.playRowAt(0)
        _ = ctx.waitUntil(4.0) { p.isPlaying && p.currentTime > 0.2 }
        p.seek(to: max(0, p.duration - 0.3))
        _ = ctx.waitUntil(4.0) { p.playlist.currentIndex == 1 }
        ctx.check("整曲播完自动切下一曲",
                  p.playlist.currentIndex == 1 && p.isPlaying,
                  "idx=\(String(describing: p.playlist.currentIndex)) playing=\(p.isPlaying)")
        p.stop()

        checkClearDerivedPreservesMain(ctx)
        checkRemoveCurrentHandsOff(ctx)
    }

    /// 派生组清空不丢 [默认] 现场（bugreport P1#1）
    private func checkClearDerivedPreservesMain(_ ctx: SelfTestContext) {
        let p = ctx.player
        p.clearPlaylist()
        _ = p.addFiles(ctx.libraryURLs)
        guard p.playlist.count >= 2 else {
            ctx.check("清空派生组-不丢 [默认]", false, "list=\(p.playlist.count)"); return
        }
        let mainCount = p.playlist.count
        // 拿两条当前不在收藏里的轨道，确保 toggle 只“加→减”、不会把基线里本来已收藏的条目弄掉
        let picks = p.playlist.tracks.filter { !p.isFavorite($0) }.prefix(2)
        for t in picks { _ = p.toggleFavorite(t) }
        p.switchGroup(.favorites)
        let favBefore = p.playlist.count
        p.clearPlaylist()
        p.switchGroup(.main)
        ctx.check("清空派生组-不丢 [默认]", p.playlist.count == mainCount,
                  "expect=\(mainCount) got=\(p.playlist.count) favBefore=\(favBefore)")
        // 把刚加的收藏重新 toggle 回去，不给基线留尾巴
        for t in picks { _ = p.toggleFavorite(t) }
        p.switchGroup(.main)
    }

    /// 删除正在播放行 → 引擎接手新当前行、不隔空跳过一首（bugreport P2#4）
    private func checkRemoveCurrentHandsOff(_ ctx: SelfTestContext) {
        let p = ctx.player
        p.clearPlaylist()
        _ = p.addFiles(ctx.libraryURLs)
        guard p.playlist.count >= 3 else {
            ctx.check("删除当前行-引擎接手下一首", false, "list=\(p.playlist.count)"); return
        }
        let removed = p.playlist.tracks[1]
        p.setMode(.order)
        p.playRowAt(1)
        _ = ctx.waitUntil(4.0) { p.isPlaying && p.currentTime > 0.2 }
        let expectNext = p.playlist.tracks[2].url.lastPathComponent   // 删 index 1 后 C 顶上来
        p.removeTracks(at: IndexSet(integer: 1))
        ctx.check("删除当前行-列表指向下一首",
                  p.playlist.currentTrack?.url.lastPathComponent == expectNext,
                  "cur=\(p.playlist.currentTrack?.url.lastPathComponent ?? "nil") expect=\(expectNext)")
        let handed = ctx.waitUntil(3.0) { p.isPlaying && p.currentTime > 0.1 }
        ctx.check("删除当前行-引擎接手新当前行", handed,
                  "playing=\(p.isPlaying) t=\(String(format: "%.2f", p.currentTime))")
        p.stop()
        p.setMode(.listLoop)
        // 把删掉的那行加回来，保证 trackPaths 回到基线
        _ = p.addTracks([removed])
    }
}
