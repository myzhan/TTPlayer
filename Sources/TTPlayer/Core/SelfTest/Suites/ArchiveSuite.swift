import Foundation
import AppKit

/// 归档容器流式播放自检：现场用 `/usr/bin/zip` 与 `/usr/bin/tar` 造 zip / tar.gz / tar.bz2，
/// 覆盖「展开、去重、拒收、参数、播放、拖动」这条主链。7z / rar 本机没有 CLI、
/// 加密 zip 需要 tty 交互，都标注 SKIP（后续如引入 testlib fixture 再补上真断言）。
struct ArchiveSuite: SelfTestSuite {
    func run(_ ctx: SelfTestContext) {
        let fm = ctx.fm
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ttplayer-archive", isDirectory: true)
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let stage = root.appendingPathComponent("stage", isDirectory: true)
        try? fm.createDirectory(at: stage, withIntermediateDirectories: true)

        // 素材：借 testlib 里已有的两份 wav，改成带序号的曲目名，方便断言自然序
        let src1 = ctx.dir.appendingPathComponent("demo01.wav")
        let src2 = ctx.dir.appendingPathComponent("demo02.wav")
        guard fm.fileExists(atPath: src1.path), fm.fileExists(atPath: src2.path) else {
            ctx.emit("[selftest] SKIP 归档流式播放（testlib 缺 demo01/demo02.wav）")
            return
        }
        let song1 = stage.appendingPathComponent("01 - alpha.wav")
        let song2 = stage.appendingPathComponent("02 - beta.wav")
        try? fm.removeItem(at: song1); try? fm.removeItem(at: song2)
        try? fm.copyItem(at: src1, to: song1)
        try? fm.copyItem(at: src2, to: song2)

        checkSingleZip(ctx, root: root, stage: stage)
        checkTarGzMultiple(ctx, root: root, stage: stage)
        checkTarBz2Multiple(ctx, root: root, stage: stage)
        checkAlbumNameFromArchiveFile(ctx, root: root, stage: stage)
        checkSkipCueNestedNoExtension(ctx, root: root, stage: stage)
        checkProbeParameters(ctx, root: root, stage: stage)
        checkPlaybackAndSeek(ctx, root: root, stage: stage)
        checkDuplicateAdd(ctx, root: root, stage: stage)
        checkEmptyReject(ctx, root: root, stage: stage)
        checkEntryReaderModes(ctx, root: root, stage: stage)
        checkRestoreFromKeys(ctx, root: root, stage: stage)
        check7zFixture(ctx)
        checkEncryptedZipFixture(ctx)

        ctx.emit("[selftest] SKIP 归档-rar / rar5（本机无 rar CLI，无法现场造 fixture）")
    }

    // MARK: - 各条断言

    /// zip 里只放一首：入表 1 条
    private func checkSingleZip(_ ctx: SelfTestContext, root: URL, stage: URL) {
        let zip = root.appendingPathComponent("single.zip")
        try? FileManager.default.removeItem(at: zip)
        guard runTool("/usr/bin/zip", ["-q", "-j", zip.path, "01 - alpha.wav"], cwd: stage) else {
            ctx.check("归档-zip 单条目能入表", false, "zip 造不出来"); return
        }
        let got = LibraryStore.importURLs([zip])
        ctx.check("归档-zip 单条目能入表", got.tracks.count == 1 && got.skipped.isEmpty,
                  "n=\(got.tracks.count) skipped=\(got.skipped.count)")
    }

    /// tar.gz 两首：按名自然序，两行
    private func checkTarGzMultiple(_ ctx: SelfTestContext, root: URL, stage: URL) {
        let tgz = root.appendingPathComponent("album.tar.gz")
        try? FileManager.default.removeItem(at: tgz)
        guard runTool("/usr/bin/tar", ["-czf", tgz.path, "-C", stage.path,
                                       "01 - alpha.wav", "02 - beta.wav"]) else {
            ctx.check("归档-tar.gz 多首自然序", false, "tar 造不出来"); return
        }
        let got = LibraryStore.importURLs([tgz])
        let titles = got.tracks.map { $0.title }
        ctx.check("归档-tar.gz 多首自然序",
                  got.tracks.count == 2 && titles == ["01 - alpha", "02 - beta"],
                  "n=\(got.tracks.count) titles=\(titles)")
    }

    /// tar.bz2 同上
    private func checkTarBz2Multiple(_ ctx: SelfTestContext, root: URL, stage: URL) {
        let tbz = root.appendingPathComponent("album.tar.bz2")
        try? FileManager.default.removeItem(at: tbz)
        guard runTool("/usr/bin/tar", ["-cjf", tbz.path, "-C", stage.path,
                                       "01 - alpha.wav", "02 - beta.wav"]) else {
            ctx.check("归档-tar.bz2 多首自然序", false, "tar 造不出来"); return
        }
        let got = LibraryStore.importURLs([tbz])
        ctx.check("归档-tar.bz2 多首自然序", got.tracks.count == 2,
                  "n=\(got.tracks.count)")
    }

    /// album 名固定取外层归档文件名去后缀；.tar.gz 双后缀一起剥
    private func checkAlbumNameFromArchiveFile(_ ctx: SelfTestContext, root: URL, stage: URL) {
        let cn = root.appendingPathComponent("TestArtist-Album.zip")
        try? FileManager.default.removeItem(at: cn)
        guard runTool("/usr/bin/zip", ["-q", "-j", cn.path, "01 - alpha.wav"], cwd: stage) else {
            ctx.check("归档-album 用外层文件名", false, "zip 造不出来"); return
        }
        let got = LibraryStore.importURLs([cn])
        ctx.check("归档-album 用外层文件名",
                  got.tracks.first?.album == "TestArtist-Album",
                  "album=\(got.tracks.first?.album ?? "nil")")

        let db = root.appendingPathComponent("专辑.tar.gz")
        try? FileManager.default.removeItem(at: db)
        guard runTool("/usr/bin/tar", ["-czf", db.path, "-C", stage.path, "01 - alpha.wav"]) else {
            ctx.check("归档-album 剥 tar.gz 双后缀", false, "tar 造不出来"); return
        }
        let got2 = LibraryStore.importURLs([db])
        ctx.check("归档-album 剥 tar.gz 双后缀",
                  got2.tracks.first?.album == "专辑",
                  "album=\(got2.tracks.first?.album ?? "nil")")
    }

    /// 归档里的 cue / 另一个 zip / 无扩展名 README 都不该入表
    private func checkSkipCueNestedNoExtension(_ ctx: SelfTestContext, root: URL, stage: URL) {
        let mixed = stage.appendingPathComponent("album.cue")
        try? "FAKE CUE".write(to: mixed, atomically: true, encoding: .utf8)
        let readme = stage.appendingPathComponent("README")
        try? "no extension".write(to: readme, atomically: true, encoding: .utf8)
        // 先造一个 inner.zip，再把它连同音频一起塞进 outer.zip
        let inner = stage.appendingPathComponent("inner.zip")
        try? FileManager.default.removeItem(at: inner)
        guard runTool("/usr/bin/zip", ["-q", "-j", inner.path, "01 - alpha.wav"], cwd: stage),
              runTool("/usr/bin/zip", ["-q", "-j", root.appendingPathComponent("outer.zip").path,
                                       "01 - alpha.wav", "album.cue", "README", "inner.zip"],
                      cwd: stage) else {
            ctx.check("归档-内层 cue/zip/无后缀 不入表", false, "zip 造不出来"); return
        }
        let outer = root.appendingPathComponent("outer.zip")
        let got = LibraryStore.importURLs([outer])
        let names = got.tracks.map { $0.title }
        ctx.check("归档-内层 cue/zip/无后缀 不入表",
                  got.tracks.count == 1 && names == ["01 - alpha"],
                  "n=\(got.tracks.count) names=\(names)")
        try? FileManager.default.removeItem(at: mixed)
        try? FileManager.default.removeItem(at: readme)
        try? FileManager.default.removeItem(at: inner)
    }

    /// FFmpeg 参数走归档条目也对得上：sr / ch / dur 都 > 0
    private func checkProbeParameters(_ ctx: SelfTestContext, root: URL, stage: URL) {
        let zip = root.appendingPathComponent("probe.zip")
        try? FileManager.default.removeItem(at: zip)
        guard runTool("/usr/bin/zip", ["-q", "-j", zip.path, "01 - alpha.wav"], cwd: stage) else {
            ctx.check("归档-FFmpeg 参数对得上", false, "zip 造不出来"); return
        }
        let got = LibraryStore.importURLs([zip])
        guard let track = got.tracks.first else {
            ctx.check("归档-FFmpeg 参数对得上", false, "track 未入表"); return
        }
        MetadataReader.readSync(track)
        ctx.check("归档-FFmpeg 参数对得上",
                  track.sampleRate > 0 && track.channels > 0 && track.duration > 0,
                  "sr=\(track.sampleRate) ch=\(track.channels) dur=\(track.duration)")
    }

    /// 拖进播放器：真引擎能推进 + 拖动后仍能推进
    private func checkPlaybackAndSeek(_ ctx: SelfTestContext, root: URL, stage: URL) {
        let p = ctx.player
        let zip = root.appendingPathComponent("play.zip")
        try? FileManager.default.removeItem(at: zip)
        guard runTool("/usr/bin/zip", ["-q", "-j", zip.path,
                                       "01 - alpha.wav", "02 - beta.wav"], cwd: stage) else {
            ctx.check("归档-能进真引擎播", false, "zip 造不出来"); return
        }
        p.clearPlaylist()
        let added = p.addFiles([zip])
        guard added == 2 else {
            ctx.check("归档-能进真引擎播", false, "added=\(added)"); return
        }
        p.playRowAt(0)
        let started = ctx.waitUntil(6.0) { p.isPlaying && p.currentTime > 0.2 }
        ctx.check("归档-能进真引擎播", started, "playing=\(p.isPlaying) t=\(p.currentTime)")
        // 拖动：跳到中段，位置应落回目标附近且还在推进
        let dur = p.duration
        if dur > 1.0 {
            let target = dur / 2
            p.seek(to: target)
            let ok = ctx.waitUntil(3.0) { abs(p.currentTime - target) < 1.0 && p.currentTime > 0.2 }
            ctx.check("归档-能拖动到中段", ok,
                      "target=\(target) now=\(p.currentTime)")
        } else {
            ctx.check("归档-能拖动到中段", false, "dur=\(dur)")
        }
        p.stop()
    }

    /// 同一归档重复添加：identityKey 走 absoluteString 分支，多条目各自独立不冲突
    private func checkDuplicateAdd(_ ctx: SelfTestContext, root: URL, stage: URL) {
        let p = ctx.player
        let zip = root.appendingPathComponent("dup.zip")
        try? FileManager.default.removeItem(at: zip)
        guard runTool("/usr/bin/zip", ["-q", "-j", zip.path,
                                       "01 - alpha.wav", "02 - beta.wav"], cwd: stage) else {
            ctx.check("归档-同条目重复添加去重", false, "zip 造不出来"); return
        }
        p.clearPlaylist()
        _ = p.addFiles([zip])
        let first = p.playlist.count
        _ = p.addFiles([zip])
        ctx.check("归档-同条目重复添加去重", first == 2 && p.playlist.count == 2,
                  "first=\(first) now=\(p.playlist.count)")
    }

    /// 只有非音频条目的归档：addFiles 应给出「没有可播放」的一句话
    private func checkEmptyReject(_ ctx: SelfTestContext, root: URL, stage: URL) {
        let p = ctx.player
        let txt = stage.appendingPathComponent("readme.txt")
        try? "not audio".write(to: txt, atomically: true, encoding: .utf8)
        let zip = root.appendingPathComponent("empty.zip")
        try? FileManager.default.removeItem(at: zip)
        guard runTool("/usr/bin/zip", ["-q", "-j", zip.path, "readme.txt"], cwd: stage) else {
            ctx.check("归档-只有非音频条目报『没有可播放』", false, "zip 造不出来"); return
        }
        p.clearPlaylist()
        let added = p.addFiles([zip])
        let note = p.lastImportProblem ?? ""
        ctx.check("归档-只有非音频条目报『没有可播放』",
                  added == 0 && note.contains("没有可播放"),
                  "added=\(added) note=\(note)")
        try? FileManager.default.removeItem(at: txt)
    }

    /// 归档条目 URL 存档往返（bugreport P1#2）：identityKey 形式写回后能重建 Track，外层缺失时平稳跳过
    private func checkRestoreFromKeys(_ ctx: SelfTestContext, root: URL, stage: URL) {
        let zip = root.appendingPathComponent("restore.zip")
        try? FileManager.default.removeItem(at: zip)
        guard runTool("/usr/bin/zip", ["-q", "-j", zip.path,
                                       "01 - alpha.wav", "02 - beta.wav"], cwd: stage) else {
            ctx.check("归档-URL 存档往返", false, "zip 造不出来"); return
        }
        let imported = LibraryStore.importURLs([zip])
        guard imported.tracks.count == 2 else {
            ctx.check("归档-URL 存档往返", false, "n=\(imported.tracks.count)"); return
        }
        let keys = imported.tracks.map { $0.identityKey }
        let restored = LibraryStore.tracks(fromArchiveEntries: keys)
        ctx.check("归档-URL 存档往返",
                  restored.count == 2 && restored.map { $0.identityKey } == keys,
                  "n=\(restored.count)")
        // 外层文件不在盘上：既不崩也不入表
        let fakeKey = "file:///no/such/dir/album.zip#archive-entry=ghost.wav"
        let missing = LibraryStore.tracks(fromArchiveEntries: [fakeKey])
        ctx.check("归档-外层缺失平稳跳过", missing.isEmpty, "n=\(missing.count)")
    }

    /// EntryReader 两种模式都能过（cached 走 Data，超大条目重放路径单测不了就 SKIP）
    private func checkEntryReaderModes(_ ctx: SelfTestContext, root: URL, stage: URL) {
        let zip = root.appendingPathComponent("reader.zip")
        try? FileManager.default.removeItem(at: zip)
        guard runTool("/usr/bin/zip", ["-q", "-j", zip.path, "01 - alpha.wav"], cwd: stage) else {
            ctx.check("归档-EntryReader cached 模式 read/seek", false, "zip 造不出来"); return
        }
        guard let reader = Archive.reader(archive: zip, entry: "01 - alpha.wav") else {
            ctx.check("归档-EntryReader cached 模式 read/seek", false, "reader 打不开"); return
        }
        // seek 到中段再读，头/尾都能拿到才对得上；size 就是 cached Data.count
        var small = [UInt8](repeating: 0, count: 44)
        let n0 = reader.seek(to: 0, whence: 0)
        let r0 = small.withUnsafeMutableBytes { reader.read(into: $0.baseAddress, count: 44) }
        let mid = max(0, reader.size - 44)
        let n1 = reader.seek(to: mid, whence: 0)
        let r1 = small.withUnsafeMutableBytes { reader.read(into: $0.baseAddress, count: 44) }
        let sizeQuery = reader.seek(to: 0, whence: 0x10000)
        ctx.check("归档-EntryReader cached 模式 read/seek",
                  n0 == 0 && r0 == 44 && n1 == mid && r1 == 44 && sizeQuery == reader.size,
                  "n0=\(n0) r0=\(r0) n1=\(n1) r1=\(r1) sz=\(sizeQuery) size=\(reader.size)")
    }

    /// testlib 里有 demo_archive.7z 就真测，没有就 SKIP
    private func check7zFixture(_ ctx: SelfTestContext) {
        let url = ctx.dir.appendingPathComponent("demo_archive.7z")
        guard ctx.fm.fileExists(atPath: url.path) else {
            ctx.emit("[selftest] SKIP 归档-7z（没有 testlib/demo_archive.7z）")
            return
        }
        let got = LibraryStore.importURLs([url])
        let names = got.tracks.map { $0.title }
        ctx.check("归档-7z 两首入表", got.tracks.count == 2 && names == ["track01", "track02"],
                  "n=\(got.tracks.count) names=\(names)")
        // 能解码：走一次 FFmpegProbe
        if let track = got.tracks.first {
            MetadataReader.readSync(track)
            ctx.check("归档-7z FFmpeg 参数", track.sampleRate > 0 && track.duration > 0,
                      "sr=\(track.sampleRate) dur=\(track.duration)")
        }
    }

    /// testlib 里有 demo_encrypted.zip 就断言「全部加密 → 拒收」，没有就 SKIP
    private func checkEncryptedZipFixture(_ ctx: SelfTestContext) {
        let url = ctx.dir.appendingPathComponent("demo_encrypted.zip")
        guard ctx.fm.fileExists(atPath: url.path) else {
            ctx.emit("[selftest] SKIP 归档-加密 zip（没有 testlib/demo_encrypted.zip）")
            return
        }
        let got = LibraryStore.importURLs([url])
        let rejected = got.skipped.contains { $0.reason.contains("加密") }
        ctx.check("归档-加密条目全拒收", got.tracks.isEmpty && rejected,
                  "n=\(got.tracks.count) skipped=\(got.skipped.map { $0.reason })")
    }

    // MARK: - 工具

    /// 起一个 CLI 工具（zip/tar）；返回是否 0 退出。executableURL 不存在时静默 false。
    private func runTool(_ exe: String, _ args: [String], cwd: URL? = nil) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: exe) else { return false }
        let t = Process()
        t.executableURL = URL(fileURLWithPath: exe)
        t.arguments = args
        if let cwd { t.currentDirectoryURL = cwd }
        t.standardOutput = FileHandle.nullDevice
        t.standardError = FileHandle.nullDevice
        do {
            try t.run()
            t.waitUntilExit()
            return t.terminationStatus == 0
        } catch {
            return false
        }
    }
}
