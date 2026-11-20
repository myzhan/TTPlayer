import Foundation
import AppKit

/// 导入与拒收：拖目录递归收集（音频与歌词一起认）、拿不准的歌词宁可不配、
/// 空目录给一句人话，以及“拖进来的东西不能播”时把原因落在曲目与显示区上。
struct ImportSuite: SelfTestSuite {
    func run(_ ctx: SelfTestContext) {
        let p = ctx.player
        let fm = ctx.fm

        checkFolderDrop(ctx)
        checkM3UCycle(ctx)

        // 拖进来的东西被挡在门外：不能入表，但要在显示区回答为什么
        let fmtDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ttplayer-formats", isDirectory: true)
        try? fm.createDirectory(at: fmtDir, withIntermediateDirectories: true)
        let savedTracks = p.playlist.tracks
        let wmaURL = fmtDir.appendingPathComponent("song.wma")
        try? Data([0x41, 0x53, 0x46, 0x00]).write(to: wmaURL)
        p.clearPlaylist()
        let refused = p.addFiles([wmaURL])
        ctx.check("导入-不支持的格式不入表", refused == 0 && p.playlist.isEmpty, "added=\(refused)")
        ctx.check("导入-留下未入表原因", (p.lastImportProblem ?? "").contains("WMA"),
                  p.lastImportProblem ?? "nil")
        ctx.check("导入-显示区回答未入表", ctx.main.displayPanel.noteText.hasPrefix("未入表："),
                  "note=\(ctx.main.displayPanel.noteText)")

        // 扩展名在白名单但内容是垃圾：要说人话，而且不能把自动跳过变成死循环
        let bogusURL = fmtDir.appendingPathComponent("bogus.mp3")
        try? "这不是音频".data(using: .utf8)!.write(to: bogusURL)
        p.clearPlaylist()
        _ = p.addFiles([bogusURL])
        p.playRowAt(0)
        let bogusReason = p.currentTrack?.decodeProblem ?? ""
        ctx.check("播放-坏文件把原因落在曲目上",
                  bogusReason.contains("MP3") && bogusReason.contains("解码失败"), bogusReason)
        ctx.check("播放-原因里不塞系统废话",
                  !bogusReason.contains("be completed") && !bogusReason.contains("EngineError"),
                  bogusReason)
        ctx.check("播放-整表都解不开时收手", !p.isPlaying && p.playlist.count == 1,
                  "playing=\(p.isPlaying) list=\(p.playlist.count)")
        ctx.check("播放-显示区回答放不了", ctx.main.displayPanel.noteText.hasPrefix("放不了："),
                  "note=\(ctx.main.displayPanel.noteText)")

        // 后面还要用原列表跑别的套件，这里把曲库恢复回去
        p.clearPlaylist()
        _ = p.addTracks(savedTracks)
        ctx.check("格式-测完把曲库恢复回去", p.playlist.count == savedTracks.count,
                  "n=\(p.playlist.count)")
    }

    /// m3u 循环引用防护（bugreport P1#3）：自引用与 A↔B 互引均不死循环，正常嵌套能展开
    private func checkM3UCycle(_ ctx: SelfTestContext) {
        let fm = ctx.fm
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ttplayer-m3u-cycle", isDirectory: true)
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = ctx.dir.appendingPathComponent("demo01.wav")
        guard fm.fileExists(atPath: audio.path) else {
            ctx.emit("[selftest] SKIP m3u 循环防护（testlib 缺 demo01.wav）")
            return
        }
        try? fm.copyItem(at: audio, to: root.appendingPathComponent("demo01.wav"))

        // 自引用：self.m3u 里写自己
        let selfCyc = root.appendingPathComponent("self.m3u")
        try? "#EXTM3U\nself.m3u\ndemo01.wav\n".write(to: selfCyc, atomically: true, encoding: .utf8)
        let r1 = LibraryStore.importURLs([selfCyc])
        ctx.check("导入-m3u 自引用不死循环",
                  r1.tracks.count == 1 && r1.tracks[0].url.lastPathComponent == "demo01.wav",
                  "n=\(r1.tracks.count)")

        // A↔B 互引
        let a = root.appendingPathComponent("a.m3u")
        let b = root.appendingPathComponent("b.m3u")
        try? "#EXTM3U\nb.m3u\ndemo01.wav\n".write(to: a, atomically: true, encoding: .utf8)
        try? "#EXTM3U\na.m3u\n".write(to: b, atomically: true, encoding: .utf8)
        let r2 = LibraryStore.importURLs([a])
        ctx.check("导入-m3u 互引用不死循环",
                  r2.tracks.count == 1 && r2.tracks[0].url.lastPathComponent == "demo01.wav",
                  "n=\(r2.tracks.count)")

        // 正常嵌套： outer.m3u → inner.m3u → demo01.wav，一层内层多一个同文件仍只一条（seenKeys 去重）
        let inner = root.appendingPathComponent("inner.m3u")
        let outer = root.appendingPathComponent("outer.m3u")
        try? "#EXTM3U\ndemo01.wav\n".write(to: inner, atomically: true, encoding: .utf8)
        try? "#EXTM3U\ninner.m3u\ndemo01.wav\n".write(to: outer, atomically: true, encoding: .utf8)
        let r3 = LibraryStore.importURLs([outer])
        ctx.check("导入-m3u 正常嵌套与去重",
                  r3.tracks.count == 1 && r3.tracks[0].url.lastPathComponent == "demo01.wav",
                  "n=\(r3.tracks.count)")
        try? fm.removeItem(at: root)
    }

    /// 拖文件夹：递归把子目录里的音频都收进来，歌词跟着目录一起认
    private func checkFolderDrop(_ ctx: SelfTestContext) {
        let p = ctx.player
        let fm = ctx.fm
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ttplayer-folder", isDirectory: true)
        let disc1 = root.appendingPathComponent("专辑A", isDirectory: true)
        let disc2 = root.appendingPathComponent("专辑B/CD1", isDirectory: true)
        try? fm.removeItem(at: root)
        for d in [disc1, disc2] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let source = ctx.dir.appendingPathComponent("demo01.wav")
        func copyAudio(_ name: String, into d: URL) -> Bool {
            (try? fm.copyItem(at: source, to: d.appendingPathComponent(name))) != nil
        }
        let lrcText = "[00:01.00]Line1\n[00:02.50]Line2\n"
        let ready = copyAudio("01 - alpha.wav", into: disc1)
            && copyAudio("02 - beta.wav", into: disc1)
            && copyAudio("03 - gamma.wav", into: disc2)
        // 歌词：一份同名、一份带音轨号、一层没有歌词
        try? lrcText.write(to: disc1.appendingPathComponent("alpha.lrc"),
                           atomically: true, encoding: .utf8)
        try? lrcText.write(to: disc1.appendingPathComponent("02 - beta.lrc"),
                           atomically: true, encoding: .utf8)
        // 不该入表的东西：封面、说明、隐藏文件、目录外的歌词
        try? Data([0x00]).write(to: root.appendingPathComponent("cover.jpg"))
        try? "说明".write(to: root.appendingPathComponent("readme.txt"),
                          atomically: true, encoding: .utf8)
        try? Data([0x00]).write(to: root.appendingPathComponent(".hidden.wav"))
        try? lrcText.write(to: root.appendingPathComponent("另一首.lrc"),
                           atomically: true, encoding: .utf8)
        guard ready else {
            ctx.check("拖入目录-递归收集全部音频", false, "造不出测试目录")
            return
        }
        let got = LibraryStore.importURLs([root])
        let names = got.tracks.map { $0.url.lastPathComponent }
        ctx.check("拖入目录-递归收集全部音频",
                  names == ["01 - alpha.wav", "02 - beta.wav", "03 - gamma.wav"],
                  "n=\(got.tracks.count) names=\(names)")
        ctx.check("拖入目录-目录里的垃圾不当拒收",
                  got.tracks.count == 3 && got.skipped.isEmpty,
                  "skipped=\(got.skipped.count) \(got.skipNote ?? "") ")
        let nested = got.tracks.first?.url.deletingLastPathComponent().lastPathComponent ?? ""
        ctx.check("拖入目录-子目录里的歌词也认",
                  nested == "专辑A"
                    && Lyric.load(for: got.tracks[0]) != nil   // 01 - alpha.wav ↔ alpha.lrc
                    && Lyric.load(for: got.tracks[1]) != nil,  // 同名
                  "dir=\(nested) lrc=\(got.tracks.map { Lyric.exists(for: $0.url) })")
        // 同层两份都能和"gamma"对上 = 拿不准，宁可不配
        try? lrcText.write(to: disc2.appendingPathComponent("TestArtist - gamma.lrc"),
                           atomically: true, encoding: .utf8)
        try? lrcText.write(to: disc2.appendingPathComponent("gamma (Live).lrc"),
                           atomically: true, encoding: .utf8)
        ctx.check("歌词-拿不准时宁可不配",
                  Lyric.load(for: got.tracks[2]) == nil,
                  "candidates=\(Lyric.candidateFiles(for: got.tracks[2].url).count)")
        // 空目录/只有垃圾的目录：一首不加，但得回一句人话
        let emptyDir = root.appendingPathComponent("空文件夹", isDirectory: true)
        try? fm.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        let beforeEmpty = p.playlist.count
        let emptyAdded = p.addFiles([emptyDir])
        ctx.check("拖入空目录也给人话",
                  emptyAdded == 0 && p.playlist.count == beforeEmpty
                    && (p.lastImportProblem ?? "").contains("没有可播放"),
                  "added=\(emptyAdded) note=\(p.lastImportProblem ?? "nil")")
    }
}
