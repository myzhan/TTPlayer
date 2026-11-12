import AppKit
import Foundation

/// F08 媒体库：目录收录、首次与手动扫描、目录监控、离线恢复、重新定位与批量换前缀。
///
/// 这套断言的凭据是**真盘上的真目录**：素材造在 `$TMPDIR/ttplayer-library`，扫描走真实的
/// 递归收集与导入规则（`LibraryStore.Importer`），监控挂的是真 FSEvents（本机探针实测首条
/// 事件 0.2 s 量级、改名/删除/子目录都会回话），重新定位改的也是真键。
///
/// 需求里「绝不删除/移动/改写原始文件」是硬约束，所以每段都对照盘面记账：
/// 套件只改自己指定的那几个文件，收尾会重新列一遍曲库目录（testlib）确认一个字都没变。
final class LibrarySuite: SelfTestSuite {
    private let fm = FileManager.default
    private var root: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("ttplayer-library", isDirectory: true)
    /// 跑之前 testlib 的文件名清单，跑完必须一模一样（素材不落进曲库）
    private var testlibSnapshot: [String] = []

    // MARK: - 素材位置

    private var music: URL { root.appendingPathComponent("music", isDirectory: true) }
    private var albumA: URL { music.appendingPathComponent("AlbumA", isDirectory: true) }
    private var albumB: URL { music.appendingPathComponent("AlbumB", isDirectory: true) }
    private var albumC: URL { music.appendingPathComponent("AlbumC", isDirectory: true) }
    private var archiveBox: URL { music.appendingPathComponent("Archive", isDirectory: true) }
    private var other: URL { root.appendingPathComponent("other", isDirectory: true) }
    private var backup: URL { root.appendingPathComponent("backup", isDirectory: true) }
    private var disk2: URL { root.appendingPathComponent("disk2", isDirectory: true) }
    private var disk2Gone: URL { root.appendingPathComponent("disk2-offline", isDirectory: true) }
    private var big: URL { root.appendingPathComponent("big", isDirectory: true) }
    /// 「重新定位」搬走的那几个文件的落点（⑧ 用）
    private var moved: URL { root.appendingPathComponent("moved", isDirectory: true) }
    /// 整片目录改名后的新位置（⑨ 用）：与 `music` 同级，换前缀前后的目录表都指得清
    private var movedMusic: URL { root.appendingPathComponent("music-new", isDirectory: true) }
    /// 同一棵树的第二种写法（多经过一层符号链接）：重复添加必须认出来
    private var viewsMusic: URL { root.appendingPathComponent("views").appendingPathComponent("music") }

    private func path(_ url: URL) -> String { url.path }
    private var alphaPath: String { path(albumA.appendingPathComponent("01 - alpha.wav")) }
    private var betaPath: String { path(albumA.appendingPathComponent("02 - beta.wav")) }
    private var c1Path: String { path(albumC.appendingPathComponent("c1.wav")) }
    private var c2Path: String { path(albumC.appendingPathComponent("c2.wav")) }
    private var cuePath: String { path(albumB.appendingPathComponent("album.cue")) }
    private var zipURL: URL { archiveBox.appendingPathComponent("songs.zip") }
    private func cueKey(_ n: Int) -> String { "\(cuePath)#track=\(n)" }

    /// 一趟扫描该收到什么：普通文件按路径、CUE 按轨号、归档按条目表。
    /// 归档条目的键不自己拼字符串（百分号转义只此一处规矩），拿 `Archive` 的构造器算
    private func expectedMusicKeys() -> [String] {
        var out = [alphaPath, betaPath, cueKey(1), cueKey(2), cueKey(3), c1Path, c2Path]
        out.append(contentsOf: archiveKeys(of: zipURL))
        return out
    }

    private func archiveKeys(of url: URL) -> [String] {
        (Archive.list(url: url) ?? []).compactMap { e in
            guard !e.path.hasSuffix("/") else { return nil }
            return Archive.makeEntryURL(archive: url, entry: e.path)?.absoluteString
        }
    }

    // MARK: - 入口

    func run(_ ctx: SelfTestContext) {
        testlibSnapshot = (try? fm.contentsOfDirectory(atPath: ctx.dir.path))?.sorted() ?? []
        guard buildFixtures(ctx) else {
            ctx.check("媒体库-素材树搭建", false, "root=\(root.path)")
            return
        }
        resetArchives(ctx.player)

        checkFolderRules(ctx)
        checkFirstScan(ctx)
        checkChanges(ctx)
        checkOffline(ctx)
        checkWatcher(ctx)
        checkCancelAndCost(ctx)
        checkRelocatePure(ctx)
        checkRelocateThroughUI(ctx)
        checkPrefixReplace(ctx)
        checkUserEntries(ctx)
        checkPersistence(ctx)
        cleanup(ctx)
    }

    // MARK: - 素材树

    /// 每次重建一整棵树：要看差量就得先知道起点，段与段之间不能互相牵连。
    /// `full = false` 只重铺盘面（music / other / backup / disk2），大目录 big 留原样
    private func buildFixtures(_ ctx: SelfTestContext, full: Bool = true) -> Bool {
        if full {
            try? fm.removeItem(at: root)
        } else {
            for name in ["music", "music-new", "other", "backup", "disk2", "disk2-offline",
                         "views", "moved"] {
                try? fm.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
            }
        }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        func mk(_ rel: String) -> URL {
            let u = root.appendingPathComponent(rel, isDirectory: true)
            try? fm.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }
        func wav(_ dir: URL, _ name: String, _ freq: Double = 300, _ seconds: Double = 0.2) {
            _ = ctx.writeWave(dir.appendingPathComponent(name), sampleRate: 8_000, channels: 2,
                              bits: 16, freqs: [freq, freq * 1.5], seconds: seconds)
        }
        let a = mk("music/AlbumA"), b = mk("music/AlbumB"), c = mk("music/AlbumC")
        let z = mk("music/Archive")
        _ = mk("other"); _ = mk("backup"); _ = mk("disk2"); _ = mk("moved")
        wav(a, "01 - alpha.wav"); wav(a, "02 - beta.wav", 400)
        wav(a, ".hidden.wav", 500)
        try? Data("封面不是音乐".utf8).write(to: a.appendingPathComponent("cover.jpg"))
        try? Data("说明文件也不收".utf8).write(to: a.appendingPathComponent("notes.txt"))
        // 两个链接指向同一个文件：第二个应当算重复，不能多出一条引用
        try? fm.createSymbolicLink(at: a.appendingPathComponent("first.wav"),
                                   withDestinationURL: a.appendingPathComponent("01 - alpha.wav"))
        try? fm.createSymbolicLink(at: a.appendingPathComponent("second.wav"),
                                   withDestinationURL: a.appendingPathComponent("01 - alpha.wav"))
        // 目录链接指回自己：递归必须在这一刻断掉，不然扫描自己绕死
        // （用 `.` 而不是 `..`：后者在「只扫 AlbumA 这一片」时会把整个 music 绕进来）
        try? fm.createSymbolicLink(atPath: a.appendingPathComponent("loop").path,
                                   withDestinationPath: ".")
        try? fm.createSymbolicLink(at: root.appendingPathComponent("views"), withDestinationURL: root)
        // CUE 的镜像给足 6 秒：三轨各占两秒，轨次才对得上
        wav(b, "album.wav", 300, 6)
        let cueText = """
        REM GENRE POP
        PERFORMER "LibraryTester"
        TITLE "LibraryAlbum"
        FILE "album.wav" WAVE
          TRACK 01 AUDIO
            TITLE "Cue One"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Cue Two"
            INDEX 01 00:02:00
          TRACK 03 AUDIO
            TITLE "Cue Three"
            INDEX 01 00:04:00
        """
        try? cueText.write(to: b.appendingPathComponent("album.cue"), atomically: true, encoding: .utf8)
        wav(c, "c1.wav", 500); wav(c, "c2.wav", 600)
        try? "#EXTM3U\nc1.wav\nc2.wav\n".write(to: c.appendingPathComponent("list.m3u"),
                                               atomically: true, encoding: .utf8)
        wav(z, "one.wav", 700); wav(z, "two.wav", 800)
        guard ctx.runTool("/usr/bin/zip", ["-q", "songs.zip", "one.wav", "two.wav"], cwd: z),
              fm.fileExists(atPath: z.appendingPathComponent("songs.zip").path) else { return false }
        // 归档里的两份散装副本要收掉：留着它们，「归档条目」与「散装文件」就会混进同一趟账
        try? fm.removeItem(at: z.appendingPathComponent("one.wav"))
        try? fm.removeItem(at: z.appendingPathComponent("two.wav"))
        wav(other, "c1.wav", 900)
        wav(backup, "c1.wav", 1_000)        // 同名不同内容：定位时绝不替用户挑
        wav(disk2, "portable.wav", 1_100); wav(disk2, "live.wav", 1_200)
        // 批量扫描的规模：先写一份模板再复制，铺 2000 个文件只要零点几秒
        if full {
            try? fm.createDirectory(at: big, withIntermediateDirectories: true)
            wav(big, "proto.wav", 300, 0.02)
            guard let blob = try? Data(contentsOf: big.appendingPathComponent("proto.wav")) else {
                return false
            }
            try? fm.removeItem(at: big.appendingPathComponent("proto.wav"))
            for i in 0..<Self.bigCount {
                try? blob.write(to: big.appendingPathComponent(String(format: "b%04d.wav", i)))
            }
        }
        return fm.fileExists(atPath: alphaPath) && archiveKeys(of: zipURL).count == 2
    }

    /// 批量段的规模：2000 个文件够把「一趟扫描的耗时与内存」量出来，又不至于拖垮看门狗
    private static let bigCount = 2_000

    // MARK: - 工具

    /// 等异步那趟扫完（并顺手把监控摘掉）：同步差量断言不能和后台扫描交叉
    private func settle(_ ctx: SelfTestContext, _ tail: TimeInterval = 0.25) {
        _ = ctx.waitUntil(30) { !ctx.player.isLibraryScanning }
        ctx.pump(tail)
    }

    private func stopWatching() { MediaLibrary.shared.stopWatching() }

    /// 建一个只有键、不读元数据的曲目对象：加收藏 / 进队列 / 进歌单都要真 Track
    private func track(_ key: String) -> Track {
        if let url = URL(string: key), key.hasPrefix("file://"), Archive.parseEntryURL(url) != nil {
            return Track(url: url)
        }
        if let marker = key.range(of: LibraryStore.cueArchiveMarker),
           let number = Int(key[marker.upperBound...]),
           let sheet = CueSheet.parse(url: URL(fileURLWithPath: String(key[..<marker.lowerBound]))),
           let info = sheet.tracks.first(where: { $0.number == number }) {
            return Track(cueTrack: info, sheet: sheet)
        }
        return Track(url: URL(fileURLWithPath: key))
    }

    // MARK: - ① 目录规矩

    private func checkFolderRules(_ ctx: SelfTestContext) {
        let p = ctx.player
        p.clearLibrary()
        ctx.check("媒体库-空库那句话要说清去向",
                  p.libraryStatusText == "媒体库：还没有音乐目录", "text=\(p.libraryStatusText)")
        let ghost = root.appendingPathComponent("没插上的盘", isDirectory: true).path
        let n1 = p.addLibraryFolder(ghost)
        ctx.check("媒体库-目录不在就说现在不在", n1?.contains("现在不在") == true,
                  "note=\(n1 ?? "nil")")
        ctx.check("媒体库-失败原因留在库页上", p.libraryProblem == n1,
                  "problem=\(p.libraryProblem ?? "nil")")
        let n2 = p.addLibraryFolder(alphaPath)
        ctx.check("媒体库-选中的是文件要说不是目录", n2?.contains("不是目录") == true,
                  "note=\(n2 ?? "nil")")
        let n3 = p.addLibraryFolder(path(music))
        settle(ctx)
        ctx.check("媒体库-添加目录本身不报错", n3 == nil && p.libraryProblem == nil,
                  "note=\(n3 ?? "nil") problem=\(p.libraryProblem ?? "nil")")
        ctx.check("媒体库-目录按添加顺序存着", p.libraryFolders == [path(music)],
                  "folders=\(p.libraryFolders)")
        let n4 = p.addLibraryFolder(path(music) + "/")
        ctx.check("媒体库-尾部斜杠是同一种写法", n4?.contains("已经在库了") == true,
                  "note=\(n4 ?? "nil")")
        let n5 = p.addLibraryFolder(path(viewsMusic))
        ctx.check("媒体库-绕一层符号链接也是同一个目录", n5?.contains("已经在库了") == true,
                  "note=\(n5 ?? "nil") detail=\(path(viewsMusic))")
        let n6 = p.addLibraryFolder(path(albumA))
        ctx.check("媒体库-上层盖住就不收下层", n6?.contains("整个覆盖") == true,
                  "note=\(n6 ?? "nil")")
        _ = p.removeLibraryFolder(path(music))
        settle(ctx)
        let n7 = p.addLibraryFolder(path(albumA))
        settle(ctx)
        ctx.check("媒体库-移除上层后下层可以单独收", n7 == nil && p.libraryFolders == [path(albumA)],
                  "note=\(n7 ?? "nil") folders=\(p.libraryFolders)")
        // 只扫这一片：库里的引用应该只有 AlbumA 那两条（链接与说明文件都不算）
        let keys = Set(p.libraryKeys)
        ctx.check("媒体库-只扫一片就只收这一片",
                  keys == Set([alphaPath, betaPath]), "keys=\(keys.sorted())")
        ctx.check("媒体库-链接文件不多出一条",
                  !keys.contains(path(albumA.appendingPathComponent("first.wav")))
                    && !keys.contains(path(albumA.appendingPathComponent("second.wav"))),
                  "keys=\(keys.sorted())")
        let note = p.removeLibraryFolder(path(albumA))
        ctx.check("媒体库-移除目录报出少了几个", note.contains("少了 2 条"), "note=\(note)")
        ctx.check("媒体库-移除目录不动盘上的文件",
                  fm.fileExists(atPath: alphaPath) && fm.fileExists(atPath: betaPath))
        stopWatching()
    }

    // MARK: - ② 首次扫描

    private func checkFirstScan(_ ctx: SelfTestContext) {
        let p = ctx.player
        let listCount = p.playlist.count          // [默认] 里是 testlib 的曲目
        p.clearLibrary()
        _ = p.addLibraryFolder(path(music))
        settle(ctx)
        // 异步那趟只负责把进度报上去；差量断言用同步这一趟，账才对得齐
        _ = p.scanLibraryFolders([path(music)])
        let keys = p.libraryKeys
        let expect = expectedMusicKeys()
        ctx.check("媒体库-首次扫描收到 9 条引用", Set(keys) == Set(expect),
                  "got=\(keys.count) want=\(expect.count) 差集=\(Set(keys).symmetricDifference(Set(expect)).sorted())")
        let stats = p.libraryStats
        ctx.check("媒体库-扫描账目对得上",
                  stats.filesScanned == 10 && stats.entries == expect.count
                    && stats.skippedDuplicates >= 3 && !stats.cancelled,
                  "files=\(stats.filesScanned) entries=\(stats.entries)"
                    + " dup=\(stats.skippedDuplicates) cancelled=\(stats.cancelled)")
        ctx.check("媒体库-隐藏文件与说明文件不入表",
                  !keys.contains(where: { $0.hasSuffix(".hidden.wav") })
                    && !keys.contains(where: { $0.hasSuffix(".jpg") })
                    && !keys.contains(where: { $0.hasSuffix(".txt") }),
                  "keys=\(keys.filter { !$0.contains("#") }.sorted())")
        ctx.check("媒体库-CUE 整盘展开成三轨",
                  keys.filter { $0.hasPrefix("\(cuePath)#track=") }.count == 3,
                  "cueKeys=\(keys.filter { $0.contains("#track=") })")
        ctx.check("媒体库-展开过的镜像不再整盘入表",
                  !keys.contains(path(albumB.appendingPathComponent("album.wav"))),
                  "keys=\(keys.filter { $0.contains("AlbumB") })")
        ctx.check("媒体库-同一张盘的三轨在库里连成一片", {
            guard let first = keys.firstIndex(of: cueKey(1)) else { return false }
            return keys[first...].prefix(3).map { $0 } == [cueKey(1), cueKey(2), cueKey(3)]
        }(), "keys=\(keys)")
        ctx.check("媒体库-m3u 展开与直接扫到不重复",
                  keys.filter { $0 == c1Path || $0 == c2Path }.count == 2
                    && !keys.contains(path(albumC.appendingPathComponent("list.m3u"))),
                  "keys=\(keys.filter { $0.contains("AlbumC") })")
        ctx.check("媒体库-归档条目扁平入表",
                  keys.filter { $0.contains(Archive.entryFragmentMarker) }.count == 2,
                  "n=\(keys.filter { $0.contains(Archive.entryFragmentMarker) }.count)")
        ctx.check("媒体库-扫描不动播放列表",
                  p.playlist.count == listCount && p.activeGroup == .main,
                  "list=\(p.playlist.count) want=\(listCount) group=\(p.activeGroup)")
        ctx.check("媒体库-发现新歌不会自己响起来",
                  p.currentTrack == nil && !p.isPlaying && p.queue.items.isEmpty)
        ctx.check("媒体库-扫完不再显示扫描中",
                  !p.isLibraryScanning && p.libraryScanNote.isEmpty
                    && !p.libraryStatusText.contains("扫描中"),
                  "note=\(p.libraryScanNote) status=\(p.libraryStatusText)")
        // 媒体库那一页直接读库，不另存一份
        p.switchGroup(.library)
        ctx.check("媒体库-媒体库页列的就是库里那些",
                  p.playlist.count == keys.count
                    && Set(p.playlist.tracks.map { $0.identityKey }) == Set(keys),
                  "rows=\(p.playlist.count) keys=\(keys.count)")
        ctx.check("媒体库-库页每行都能对上盘上的东西",
                  p.playlist.tracks.allSatisfy { !$0.missingOnDisk },
                  "missing=\(p.playlist.tracks.filter { $0.missingOnDisk }.count)")
        p.switchGroup(.main)
        stopWatching()
    }

    // MARK: - ③ 内容修改 / 移动 / 删除

    private func checkChanges(_ ctx: SelfTestContext) {
        let p = ctx.player
        p.clearLibrary()
        _ = p.addLibraryFolder(path(music))
        settle(ctx)
        _ = p.scanLibraryFolders([path(music)])
        // 引用先进歌单与收藏：文件走了这些档案该留住（F04 + F08 共同要求）
        guard let made = p.createList(named: "待修的一张") else {
            ctx.check("媒体库-歌单前置", false); return
        }
        let listID = made.id
        _ = p.addTracks([track(betaPath)], toList: listID)
        p.groups.toggleFavorite(track(betaPath))
        p.groups.recordPlay(track(betaPath))
        // 内容改了：改动时间往前推一格，下一趟就该报「修改」而不是「没了又长回来」
        let later = Date().addingTimeInterval(30)
        try? fm.setAttributes([.modificationDate: later], ofItemAtPath: betaPath)
        _ = ctx.writeWave(URL(fileURLWithPath: betaPath), sampleRate: 8_000, channels: 2,
                          bits: 16, freqs: [440, 660], seconds: 0.3)
        let d1 = p.scanLibraryFolders([path(music)])
        ctx.check("媒体库-内容改动报修改不报增删",
                  d1.modified == [betaPath] && d1.added.isEmpty && d1.removed.isEmpty,
                  "modified=\(d1.modified) added=\(d1.added) removed=\(d1.removed)")
        let moved = albumC.appendingPathComponent("beta-moved.wav")
        try? fm.moveItem(atPath: betaPath, toPath: moved.path)
        let d2 = p.scanLibraryFolders([path(music)])
        ctx.check("媒体库-目录内移动算一删一增",
                  d2.removed == [betaPath] && d2.added == [path(moved)],
                  "removed=\(d2.removed) added=\(d2.added)")
        var expect = Set(expectedMusicKeys())
        expect.remove(betaPath)
        expect.insert(path(moved))
        ctx.check("媒体库-移动后库里条数不变", Set(p.libraryKeys) == expect,
                  "keys=\(p.libraryKeys.sorted()) 差集=\(Set(p.libraryKeys).symmetricDifference(expect).sorted())")
        try? fm.removeItem(at: moved)
        let d3 = p.scanLibraryFolders([path(music)])
        ctx.check("媒体库-目录在线而文件没了才摘掉",
                  d3.removed == [path(moved)] && p.offlineLibraryFolders.isEmpty,
                  "removed=\(d3.removed) offline=\(p.offlineLibraryFolders)")
        ctx.check("媒体库-摘掉的是库引用不牵连歌单",
                  !p.libraryKeys.contains(betaPath)
                    && p.userLists.keys(of: listID) == [betaPath],
                  "list=\(p.userLists.keys(of: listID))")
        ctx.check("媒体库-收藏与历史也留住这条引用",
                  p.groups.favoriteKeys.contains(betaPath) && p.groups.recentKeys.contains(betaPath),
                  "fav=\(p.groups.favoriteKeys) recent=\(p.groups.recentKeys)")
        p.switchGroup(.playlist(listID))
        ctx.check("媒体库-失效行留在歌单页等用户决定",
                  p.playlist.count == 1 && p.playlist.tracks.first?.missingOnDisk == true,
                  "rows=\(p.playlist.count) missing=\(p.playlist.tracks.first?.missingOnDisk ?? false)")
        p.switchGroup(.main)
        // 归档多了条目：下一趟就该多一条引用，旧的不少
        wav3(ctx)
        let d4 = p.scanLibraryFolders([path(music)])
        let zipKeys = Set(archiveKeys(of: zipURL))
        ctx.check("媒体库-归档加条目后库跟着长",
                  zipKeys.count == 3 && Set(p.libraryKeys).isSuperset(of: zipKeys)
                    && !d4.removed.contains(where: { $0.contains(Archive.entryFragmentMarker) }),
                  "zip=\(zipKeys.count) removed=\(d4.removed)")
        ctx.check("媒体库-归档新条目只多这一条",
                  zipKeys.isSubset(of: Set(d4.added + p.libraryKeys))
                    && d4.added.filter { $0.contains(Archive.entryFragmentMarker) }.count == 1,
                  "added=\(d4.added)")
        stopWatching()
    }

    /// 往归档里再塞一个条目（散装文件放在别的目录，免得多出散装引用）
    private func wav3(_ ctx: SelfTestContext) {
        let src = other.appendingPathComponent("three.wav")
        _ = ctx.writeWave(src, sampleRate: 8_000, channels: 2, bits: 16, freqs: [700, 900], seconds: 0.2)
        _ = ctx.runTool("/usr/bin/zip", ["-q", zipURL.path, "other/three.wav"], cwd: root)
    }

    // MARK: - ④ 磁盘离线与插回

    private func checkOffline(_ ctx: SelfTestContext) {
        let p = ctx.player
        p.clearLibrary()
        _ = p.addLibraryFolder(path(music))
        _ = p.addLibraryFolder(path(disk2))
        settle(ctx)
        _ = p.scanLibraryFolders([path(music), path(disk2)])
        let diskKeys = [path(disk2.appendingPathComponent("portable.wav")),
                        path(disk2.appendingPathComponent("live.wav"))]
        ctx.check("媒体库-第二块盘的东西也入表", Set(p.libraryKeys).isSuperset(of: Set(diskKeys)),
                  "keys=\(p.libraryKeys.filter { $0.contains("disk2") })")
        // 模拟拔盘：整片目录的路径没了（外置盘拔走、网络盘断开都是这个样子）
        try? fm.moveItem(at: disk2, to: disk2Gone)
        let before = p.libraryKeys.count
        let d = p.scanLibraryFolders([path(music), path(disk2)])
        ctx.check("媒体库-整片不在线只标失效不摘掉",
                  Set(d.invalid) == Set(diskKeys) && d.removed.isEmpty,
                  "invalid=\(d.invalid) removed=\(d.removed)")
        ctx.check("媒体库-离线目录进不在线清单", p.offlineLibraryFolders == [path(disk2)],
                  "offline=\(p.offlineLibraryFolders)")
        ctx.check("媒体库-离线期间一条都不少", p.libraryKeys.count == before,
                  "before=\(before) now=\(p.libraryKeys.count)")
        ctx.check("媒体库-离线条数算得出来", p.libraryMissingCount >= diskKeys.count,
                  "missing=\(p.libraryMissingCount)")
        let status = p.libraryStatusText
        ctx.check("媒体库-状态句说出几个目录不在线",
                  status.contains("1 个目录当前不在线") && status.contains("条引用"),
                  "status=\(status)")
        ctx.check("媒体库-离线文件其实还在改名后的位置",
                  fm.fileExists(atPath: path(disk2Gone.appendingPathComponent("portable.wav"))))
        // 插回来：引用不用重新扫就有声，失效标记自动摘
        try? fm.moveItem(at: disk2Gone, to: disk2)
        let d2 = p.scanLibraryFolders([path(music), path(disk2)])
        ctx.check("媒体库-盘插回来自动恢复引用",
                  Set(d2.restored) == Set(diskKeys) && d2.added.isEmpty && d2.invalid.isEmpty,
                  "restored=\(d2.restored) added=\(d2.added)")
        ctx.check("媒体库-恢复后不再说不在线",
                  p.offlineLibraryFolders.isEmpty && !statusNow(ctx).contains("不在线"),
                  "status=\(statusNow(ctx))")
        ctx.check("媒体库-恢复后这几条又能解开",
                  diskKeys.allSatisfy { LibraryStore.entryExists($0) } && p.libraryMissingCount == 0,
                  "missing=\(p.libraryMissingCount)")
        stopWatching()
    }

    private func statusNow(_ ctx: SelfTestContext) -> String { ctx.player.libraryStatusText }

    /// 只数「这一趟真的走完了」那几句广播：监控与合并窗到底生没生效，只能从这里看
    private final class ScanRounds {
        private(set) var finishRounds = 0
        /// 最后那一句的头（用来区分「扫描完成」与「已停止扫描」）
        private(set) var lastHead = ""
        private var token: NSObjectProtocol?

        func start() {
            guard token == nil else { return }
            token = NotificationCenter.default.addObserver(forName: .ttLibraryChanged,
                                                          object: nil, queue: nil) { [weak self] note in
                let text = (note.userInfo?["note"] as? String) ?? ""
                guard text.hasPrefix("扫描完成") || text.hasPrefix("已停止扫描") else { return }
                self?.finishRounds += 1
                self?.lastHead = text
            }
        }

        func stop() {
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
        }

        func reset() { finishRounds = 0; lastHead = "" }
    }

    // MARK: - ⑤ 目录监控（真 FSEvents）

    private func checkWatcher(_ ctx: SelfTestContext) {
        let p = ctx.player
        guard buildFixtures(ctx, full: false) else {
            ctx.check("媒体库-监控素材重铺", false); return
        }
        p.clearLibrary()
        let listCount = p.playlist.count
        // 监控这条路要真挂上去：只测同步扫描就等于没测 FSEvents
        p.setupLibrary(folders: [path(music)], keys: [])
        settle(ctx)
        ctx.check("媒体库-启动核对只并差不重建列表",
                  Set(p.libraryKeys) == Set(expectedMusicKeys()) && p.playlist.count == listCount,
                  "keys=\(p.libraryKeys.count) list=\(p.playlist.count)")
        checkEventPathSpelling(ctx)
        // 新增：往监控中的目录里拷一首（拖进来就是这个动作）
        let fresh = albumA.appendingPathComponent("03 - gamma.wav")
        _ = ctx.writeWave(fresh, sampleRate: 8_000, channels: 2, bits: 16, freqs: [300, 450],
                          seconds: 0.2)
        let sawNew = ctx.waitUntil(15) { p.libraryKeys.contains(path(fresh)) }
        ctx.check("媒体库-监控能发现新拷进来的文件", sawNew,
                  "keys=\(p.libraryKeys.filter { $0.contains("gamma") })")
        // 改名：旧键摘掉、新键进来，一趟扫描就办完
        let renamed = albumA.appendingPathComponent("03 - delta.wav")
        try? fm.moveItem(at: fresh, to: renamed)
        let sawRename = ctx.waitUntil(15) {
            p.libraryKeys.contains(path(renamed)) && !p.libraryKeys.contains(path(fresh))
        }
        ctx.check("媒体库-监控认得出改名", sawRename,
                  "fresh在=\(p.libraryKeys.contains(path(fresh))) 新名在=\(p.libraryKeys.contains(path(renamed)))")
        // 删除：盘上没了就摘，别留着让人以为还在
        try? fm.removeItem(at: renamed)
        let sawGone = ctx.waitUntil(15) { !p.libraryKeys.contains(path(renamed)) }
        ctx.check("媒体库-监控能发现文件被删掉", sawGone, "keys=\(p.libraryKeys.count)")
        // 一次拷进来五个不该扫五趟（事件只当「这一片该重扫」的触发器）
        let rounds = ScanRounds()
        rounds.start()
        var burst: [URL] = []
        for i in 0..<5 {
            let url = albumA.appendingPathComponent(String(format: "burst%02d.wav", i))
            _ = ctx.writeWave(url, sampleRate: 8_000, channels: 2, bits: 16, freqs: [500, 700],
                              seconds: 0.05)
            burst.append(url)
        }
        let paths = burst.map { path($0) }
        let allIn = ctx.waitUntil(25) { p.libraryKeys.filter { paths.contains($0) }.count == 5 }
        ctx.check("媒体库-批量拷入合并成一趟扫描",
                  allIn && rounds.finishRounds <= 3,
                  "rounds=\(rounds.finishRounds) 到齐=\(allIn)")
        ctx.check("媒体库-监控期间不会自己开播",
                  p.currentTrack == nil && !p.isPlaying && p.playlist.count == listCount,
                  "list=\(p.playlist.count)")
        rounds.stop()
        for url in burst { try? fm.removeItem(at: url) }
        stopWatching()
        p.clearLibrary()
    }

    /// FSEvents 报回来的路径是它自己解析过的写法（`/var/…` 变成 `/private/var/…`），
    /// 与用户当初选中的那条对不上号。这一条只能拿真写法验：本机没有第二种写法就标跳过
    private func checkEventPathSpelling(_ ctx: SelfTestContext) {
        let eventStyle = "/private" + path(music) + "/AlbumA/x.wav"
        guard fm.fileExists(atPath: eventStyle) else {
            ctx.check("媒体库-事件路径写法不同也认得（本机没这种写法）", true,
                      "event=\(eventStyle) 不存在")
            return
        }
        ctx.check("媒体库-事件路径写法不同也认得",
                  MediaLibrary.folder(path(music), holdsEventPath: eventStyle),
                  "event=\(eventStyle) folder=\(path(music))")
        // 反方向也要站得住：不相干的目录不能被当成自己人
        ctx.check("媒体库-不相干的事件不会被领进来",
                  !MediaLibrary.folder(path(albumC), holdsEventPath: eventStyle))
    }

    // MARK: - ⑥ 取消扫描与批量账目

    private func checkCancelAndCost(_ ctx: SelfTestContext) {
        let p = ctx.player
        p.clearLibrary()
        // 直接用模型层加目录：这一节要自己掌握扫描时机，不能被添加那一步的异步扫描插一脚
        _ = MediaLibrary.shared.addFolder(path(music))
        _ = MediaLibrary.shared.addFolder(path(big))
        let first = p.scanLibraryFolders([path(music), path(big)])
        let settled = Set(p.libraryKeys)
        ctx.check("媒体库-大目录一并入表",
                  settled.count == expectedMusicKeys().count + Self.bigCount && first.removed.isEmpty,
                  "n=\(settled.count)")
        let rounds = ScanRounds()
        rounds.start()
        // 后台刚起步就喊停：被取消的那一片不算看完，不能拿半截清单改账
        p.rescanLibrary()
        p.cancelLibraryScan()
        settle(ctx)
        ctx.check("媒体库-取消扫描认账", p.libraryStats.cancelled,
                  "cancelled=\(p.libraryStats.cancelled)")
        ctx.check("媒体库-取消后界面回到不扫", !p.isLibraryScanning && p.libraryScanNote.isEmpty,
                  "note=\(p.libraryScanNote)")
        ctx.check("媒体库-停下的那句不说「完成」", rounds.lastHead.hasPrefix("已停止扫描"),
                  "note=\(rounds.lastHead)")
        rounds.stop()
        ctx.check("媒体库-半截清单不当全清单用", Set(p.libraryKeys) == settled,
                  "少了 \(settled.subtracting(p.libraryKeys).count) 条")
        // 耗时与内存峰值（需求点名要记）：从空库开始扫 2000 个文件
        p.clearLibrary()
        _ = MediaLibrary.shared.addFolder(path(big))
        let rss0 = ctx.residentMB()
        let t0 = Date()
        let d = p.scanLibraryFolders([path(big)])
        let secs = Date().timeIntervalSince(t0)
        let rss1 = ctx.residentMB()
        ctx.emit(String(format: "[selftest] 批量扫描 %d 个文件：%.2f s，RSS %.1f → %.1f MB（+%.1f）",
                        Self.bigCount, secs, rss0, rss1, rss1 - rss0))
        ctx.check("媒体库-批量扫描耗时可接受",
                  d.added.count == Self.bigCount && secs < 20,
                  "n=\(d.added.count) t=\(String(format: "%.2f", secs))s")
        ctx.check("媒体库-批量扫描内存增幅可控", rss1 - rss0 < 30,
                  "+\(String(format: "%.1f", rss1 - rss0)) MB")
        p.clearLibrary()
    }

    // MARK: - ⑦ 重新定位的写法规矩（纯函数）

    private func checkRelocatePure(_ ctx: SelfTestContext) {
        let src = "/Music/Old"
        let dst = "/Music/New"
        let plainKey = "\(src)/song.wav"
        let cueKey = "\(src)/album.cue#track=7"
        let zipKey = URL(fileURLWithPath: "\(src)/songs.zip").absoluteString
            + "#archive-entry=" + "one.wav"
        let radioKey = "http://example.com/live"
        ctx.check("媒体库-换前缀只动容器路径",
                  MediaLibrary.rewrite(key: plainKey, prefix: src, to: dst) == "\(dst)/song.wav",
                  "got=\(MediaLibrary.rewrite(key: plainKey, prefix: src, to: dst) ?? "nil")")
        ctx.check("媒体库-CUE 换目录轨号一个字不动",
                  MediaLibrary.rewrite(key: cueKey, prefix: src, to: dst) == "\(dst)/album.cue#track=7")
        ctx.check("媒体库-归档条目换目录条目名不动",
                  MediaLibrary.rewrite(key: zipKey, prefix: src, to: dst)
                      == URL(fileURLWithPath: "\(dst)/songs.zip").absoluteString + "#archive-entry=one.wav")
        ctx.check("媒体库-前缀对不上就不硬改",
                  MediaLibrary.rewrite(key: plainKey, prefix: "/Elsewhere", to: dst) == nil)
        ctx.check("媒体库-电台不参与换前缀",
                  MediaLibrary.rewrite(key: radioKey, prefix: src, to: dst) == nil)
        ctx.check("媒体库-CUE 只能定位到分轨表",
                  MediaLibrary.relabel(key: cueKey, to: "/x/y.cue") == "/x/y.cue#track=7"
                      && MediaLibrary.relabel(key: cueKey, to: "/x/y.wav") == nil)
        ctx.check("媒体库-归档条目只能定位到归档",
                  MediaLibrary.relabel(key: zipKey, to: "/x/y.zip")
                      == URL(fileURLWithPath: "/x/y.zip").absoluteString + "#archive-entry=one.wav"
                      && MediaLibrary.relabel(key: zipKey, to: "/x/y.wav") == nil)
        ctx.check("媒体库-电台没有盘上文件可言",
                  MediaLibrary.relabel(key: radioKey, to: "/x/y.wav") == nil)
        ctx.check("媒体库-普通文件定位就是换个位置",
                  MediaLibrary.relabel(key: plainKey, to: "/x/y.wav") == "/x/y.wav")
        // 歧义两种分开挡：两条旧位置并到同一条，与目标位置本来就被引用着
        let clash = ["a.wav": "same.wav", "b.wav": "same.wav"]
        ctx.check("媒体库-两条来源撞一条算歧义",
                  MediaLibrary.collisions(in: clash)["same.wav"]?.count == 2
                      && MediaLibrary.hasCollision(in: clash, held: []),
                  "collisions=\(MediaLibrary.collisions(in: clash))")
        ctx.check("媒体库-目标本来就在库里也算歧义",
                  MediaLibrary.hasCollision(in: ["a.wav": "b.wav"], held: ["b.wav"])
                      && MediaLibrary.targetsAlreadyInLibrary(["a.wav": "b.wav"], keys: ["b.wav"]) == ["b.wav"])
        ctx.check("媒体库-一对一换位置不算歧义",
                  !MediaLibrary.hasCollision(in: ["a.wav": "c.wav"], held: ["b.wav"]))
    }

    // MARK: - ⑧ 重新定位走完全程

    private func checkRelocateThroughUI(_ ctx: SelfTestContext) {
        let p = ctx.player
        guard buildFixtures(ctx, full: false) else {
            ctx.check("媒体库-定位素材重铺", false); return
        }
        resetArchives(p)
        _ = p.addLibraryFolder(path(music))
        settle(ctx)
        _ = p.scanLibraryFolders([path(music)])
        guard let made = p.createList(named: "搬走的一张") else {
            ctx.check("媒体库-歌单前置", false); return
        }
        let listID = made.id
        let zipKey = archiveKeys(of: zipURL).first ?? ""
        let armed = [c1Path, cueKey(2), zipKey]
        _ = p.addTracks(armed.map { track($0) }, toList: listID)
        p.groups.toggleFavorite(track(c1Path))
        p.groups.recordPlay(track(c1Path))
        _ = p.playLater([track(cueKey(2))])
        let queueKey = p.queue.items.first?.track.identityKey ?? ""
        ctx.check("媒体库-队列里也拿着旧位置", queueKey == cueKey(2), "queue=\(queueKey)")
        // 盘上真搬走（整盘镜像连同分轨表一起搬）：库该摘掉，其他档案得留住
        let movedPlain = path(moved.appendingPathComponent("c1.wav"))
        let movedCue = path(moved.appendingPathComponent("album.cue"))
        let movedZip = moved.appendingPathComponent("songs.zip")
        try? fm.moveItem(atPath: c1Path, toPath: movedPlain)
        try? fm.moveItem(atPath: cuePath, toPath: movedCue)
        try? fm.moveItem(at: albumB.appendingPathComponent("album.wav"),
                         to: moved.appendingPathComponent("album.wav"))
        try? fm.moveItem(at: zipURL, to: movedZip)
        let d = p.scanLibraryFolders([path(music)])
        ctx.check("媒体库-搬走的不只摘库这一份",
                  d.removed.contains(c1Path) && !p.libraryKeys.contains(c1Path)
                      && p.userLists.keys(of: listID) == armed,
                  "removed=\(d.removed) list=\(p.userLists.keys(of: listID))")
        // 候选：库里同名文件都给出来，一个都不替他挑
        _ = p.addLibraryFolder(path(other))
        _ = p.addLibraryFolder(path(backup))
        settle(ctx)
        _ = p.scanLibraryFolders([path(other), path(backup)])
        let hits = p.relocateCandidates(for: c1Path)
        ctx.check("媒体库-同名候选都给不替用户担",
                  hits == [path(backup.appendingPathComponent("c1.wav")),
                           path(other.appendingPathComponent("c1.wav"))],
                  "hits=\(hits)")
        // 目标位置已经被库里另一条占着：不猜哪一条算数，一条都不改
        let taken = path(other.appendingPathComponent("c1.wav"))
        let n1 = p.relocate(key: c1Path, to: taken)
        ctx.check("媒体库-目标已存在时不猜哪一条算数",
                  n1?.contains("目标位置已经有这一条") == true
                      && p.userLists.keys(of: listID) == armed && p.libraryKeys.contains(taken),
                  "note=\(n1 ?? "nil")")
        // 界面那一条：选中失效行后看到两个候选 + 「其他位置…」
        let panel = ctx.main.playlistPanel
        let view = panel.playlistView
        p.switchGroup(.playlist(listID))
        view.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        view.refreshContextMenus()
        let titles = view.relocateTitles
        ctx.check("媒体库-失效行才开放重新定位", view.canRelocateRow)
        // 两个候选 + 一条分隔线 + 「其他位置…」：分隔线也要数进去，菜单项数说得很死
        ctx.check("媒体库-候选菜单把两个都列出来",
                  titles.count == 4 && titles[2].isEmpty && titles.last == "其他位置…"
                      && titles[0] != titles[1] && titles[0].contains("c1.wav"),
                  "titles=\(titles)")
        // 电台那一行不在盘上，菜单不能给一个按得动的假入口
        let radio = Track(radio: URL(string: "http://127.0.0.1:18099/live.mp3")!)
        _ = p.addTracks([radio], toList: listID)
        p.switchGroup(.main)
        p.switchGroup(.playlist(listID))
        view.table.selectRowIndexes(IndexSet(integer: p.playlist.count - 1), byExtendingSelection: false)
        view.refreshContextMenus()
        ctx.check("媒体库-电台行不给重新定位", !view.canRelocateRow, "row=\(p.playlist.count - 1)")
        // 改到位：三个档案一起跟，条目身份保留
        let beforeFiles = countFiles(root)
        let uiNote = view.relocateRowThroughUI(0, to: movedPlain)
        ctx.check("媒体库-界面那一条也能改到位", uiNote == nil, "note=\(uiNote ?? "nil")")
        let n2 = p.relocate(key: cueKey(2), to: movedCue)
        let n3 = p.relocate(key: zipKey, to: path(movedZip))
        ctx.check("媒体库-三种引用都定位成功", n2 == nil && n3 == nil,
                  "cue=\(n2 ?? "nil") zip=\(n3 ?? "nil")")
        let listNow = p.userLists.keys(of: listID)
        ctx.check("媒体库-CUE 定位后还是那一轨",
                  listNow.contains("\(movedCue)#track=2"), "list=\(listNow)")
        ctx.check("媒体库-归档定位后条目身份不变",
                  listNow.contains(Archive.makeEntryURL(archive: movedZip, entry: "one.wav")?
                                       .absoluteString ?? "∅"), "list=\(listNow)")
        ctx.check("媒体库-收藏与历史跟着走",
                  p.groups.favoriteKeys.contains(movedPlain)
                      && p.groups.recentKeys.contains(movedPlain)
                      && !p.groups.favoriteKeys.contains(c1Path),
                  "fav=\(p.groups.favoriteKeys) recent=\(p.groups.recentKeys)")
        ctx.check("媒体库-待播队列也跟着走",
                  p.queue.items.first?.track.identityKey == "\(movedCue)#track=2",
                  "queue=\(p.queue.items.map { $0.track.identityKey })")
        ctx.check("媒体库-定位后这些引用都能解开",
                  listNow.prefix(3).allSatisfy { LibraryStore.entryExists($0) },
                  "list=\(listNow)")
        ctx.check("媒体库-定位不搬盘上的东西", countFiles(root) == beforeFiles,
                  "before=\(beforeFiles) after=\(countFiles(root))")
        // 两种不能改的：目标是个目录、类型对不上
        let n4 = p.relocate(key: movedPlain, to: path(moved))
        ctx.check("媒体库-定位目标必须是文件", n4?.contains("不是一个文件") == true,
                  "note=\(n4 ?? "nil")")
        let n5 = p.relocate(key: "\(movedCue)#track=1", to: path(moved.appendingPathComponent("album.wav")))
        ctx.check("媒体库-拿镜像顶 CUE 轨要拦住", n5?.contains("不能这么定位") == true,
                  "note=\(n5 ?? "nil")")
        p.switchGroup(.main)
        stopWatching()
        resetArchives(p)
    }

    /// 目录树里有多少个文件（定位与替换都不许动盘上的东西，拿总数当账）
    private func countFiles(_ dir: URL) -> Int {
        guard let it = fm.enumerator(at: dir, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else { return -1 }
        var n = 0
        for case let url as URL in it where !url.hasDirectoryPath {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue { n += 1 }
        }
        return n
    }

    /// 目录树里的文件清单（相对路径、排好序）：只比总数看不出「少了两个又多出两个」
    private func fileList(_ dir: URL) -> [String] {
        guard let it = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        for case let url as URL in it {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }
            out.append(String(url.path.dropFirst(dir.path.count)))
        }
        return out.sorted()
    }

    /// 把档案清回「什么都没有」：段与段的期望值才能写死，不必担心上一段留了什么
    private func resetArchives(_ p: PlayerController) {
        p.clearLibrary()
        for id in p.userLists.ids { _ = p.deleteList(id: id) }
        p.groups.clear(.favorites)
        p.groups.clear(.recent)
        p.queue.reset()
        p.switchGroup(.main)
    }

    // MARK: - ⑨ 目录整个改名的批量换前缀

    private func checkPrefixReplace(_ ctx: SelfTestContext) {
        let p = ctx.player
        guard buildFixtures(ctx, full: false) else {
            ctx.check("媒体库-替换素材重铺", false); return
        }
        resetArchives(p)
        _ = p.addLibraryFolder(path(music))
        settle(ctx)
        _ = p.scanLibraryFolders([path(music)])
        guard let made = p.createList(named: "整片搬走的一张") else {
            ctx.check("媒体库-歌单前置", false); return
        }
        let listID = made.id
        let zipKey = archiveKeys(of: zipURL).first ?? ""
        let entry = URL(string: zipKey).flatMap { Archive.parseEntryURL($0) }?.entry
        ctx.check("媒体库-归档条目身份拿得出来", entry != nil, "key=\(zipKey)")
        guard let entry else { return }
        let armed = [alphaPath, cueKey(2), zipKey, c2Path]
        _ = p.addTracks(armed.map { track($0) }, toList: listID)
        p.groups.toggleFavorite(track(cueKey(2)))
        p.groups.recordPlay(track(alphaPath))
        _ = p.playLater([track(zipKey), track(cueKey(2))])
        // 期望值要在搬走之前算：`expectedMusicKeys()` 要读归档条目表，目录搬走后它就读不出来了
        let want = expectedMusicKeys()
        let beforeFiles = fileList(root)
        // 整片改名（外置盘重插、目录改名都是这个样子）：盘上文件数量不能变
        try? fm.moveItem(at: music, to: movedMusic)
        let d = p.scanLibraryFolders([path(music)])
        ctx.check("媒体库-整片没了先按不在线留住",
                  d.invalid.count == want.count && d.removed.isEmpty
                      && p.libraryKeys.count == want.count,
                  "invalid=\(d.invalid.count) removed=\(d.removed.count) keys=\(p.libraryKeys.count)")
        // 三种不能改的：新位置现在不在、旧位置下根本没引用、新位置本来就在库里
        let ghost = path(root.appendingPathComponent("还没到位的新目录", isDirectory: true))
        let n1 = p.replaceLibraryPrefix(old: path(music), new: ghost)
        ctx.check("媒体库-新目录不在时一条都不改",
                  n1?.contains("新目录现在不在") == true && p.libraryFolders == [path(music)],
                  "note=\(n1 ?? "nil") folders=\(p.libraryFolders)")
        let n2 = p.replaceLibraryPrefix(old: path(root.appendingPathComponent("库里没这一片")),
                                        new: path(movedMusic))
        ctx.check("媒体库-没引用落在下面就说没什么要改的",
                  n2?.contains("没什么要改的") == true, "note=\(n2 ?? "nil")")
        let n3 = p.replaceLibraryPrefix(old: path(music), new: path(movedMusic))
        settle(ctx)
        ctx.check("媒体库-整片换前缀一次改到位", n3 == nil, "note=\(n3 ?? "nil")")
        let newAlpha = path(movedMusic.appendingPathComponent("AlbumA/01 - alpha.wav"))
        let newC2 = path(movedMusic.appendingPathComponent("AlbumC/c2.wav"))
        let newCueKey = path(movedMusic.appendingPathComponent("AlbumB/album.cue")) + "#track=2"
        let newZipKey = Archive.makeEntryURL(
            archive: movedMusic.appendingPathComponent("Archive/songs.zip"),
            entry: entry)?.absoluteString ?? ""
        ctx.check("媒体库-歌单四条引用一起跟到新位置",
                  p.userLists.keys(of: listID) == [newAlpha, newCueKey, newZipKey, newC2],
                  "list=\(p.userLists.keys(of: listID))")
        ctx.check("媒体库-CUE 换目录轨号不变",
                  armed[1] != newCueKey && newCueKey.hasSuffix("#track=2"),
                  "new=\(newCueKey)")
        ctx.check("媒体库-归档换目录条目名不变", newZipKey.hasSuffix(zipKey[zipKey.firstIndex(of: "#")!...]),
                  "old=\(zipKey) new=\(newZipKey)")
        ctx.check("媒体库-收藏、历史、队列一起跟上",
                  p.groups.favoriteKeys == [newCueKey] && p.groups.recentKeys == [newAlpha]
                      && Set(p.queue.items.map { $0.track.identityKey }) == Set([newZipKey, newCueKey]),
                  "fav=\(p.groups.favoriteKeys) recent=\(p.groups.recentKeys)" +
                      " queue=\(p.queue.items.map { $0.track.identityKey })")
        ctx.check("媒体库-换完库里一条旧位置都不留",
                  !p.libraryKeys.contains { MediaLibrary.key($0, liesUnder: path(music)) }
                      && p.libraryKeys.allSatisfy { MediaLibrary.key($0, liesUnder: path(movedMusic)) },
                  "旧位置=\(p.libraryKeys.filter { MediaLibrary.key($0, liesUnder: path(music)) })")
        ctx.check("媒体库-目录表跟着换成新位置", p.libraryFolders == [path(movedMusic)],
                  "folders=\(p.libraryFolders)")
        ctx.check("媒体库-换完每条都解得开",
                  p.libraryKeys.allSatisfy { LibraryStore.entryExists($0) } && p.libraryMissingCount == 0,
                  "missing=\(p.libraryMissingCount)")
        ctx.check("媒体库-批量替换不搬盘上的东西", fileList(root).count == beforeFiles.count,
                  "少了=\(Set(beforeFiles).subtracting(Set(fileList(root))).sorted()) "
                      + "多了=\(Set(fileList(root)).subtracting(Set(beforeFiles)).sorted())")
        // 目标位置本来就在库里（两片盘上有同一批文件）：不猜哪一条算数
        _ = p.addLibraryFolder(path(other))
        settle(ctx)
        _ = p.scanLibraryFolders([path(other)])
        let movedC1 = path(movedMusic.appendingPathComponent("AlbumC/c1.wav"))
        let n4 = p.replaceLibraryPrefix(old: path(movedMusic.appendingPathComponent("AlbumC")),
                                       new: path(other))
        ctx.check("媒体库-两片有同一批文件时不猜哪条算数",
                  n4?.contains("本来就在库里") == true && n4?.contains("c1.wav") == true
                      && p.libraryKeys.contains(path(other.appendingPathComponent("c1.wav")))
                      && p.libraryKeys.contains(movedC1),
                  "note=\(n4 ?? "nil")")
        resetArchives(p)
    }

    // MARK: - ⑩ 用户入口（左栏、菜单、右键）

    /// 内部接口必须有用户入口：这一节全部走菜单与面板的真入口，
    /// 不走面板（NSOpenPanel.runModal 会把主线程扣住）的那几步只断言菜单项本身
    private func checkUserEntries(_ ctx: SelfTestContext) {
        let p = ctx.player
        let panel = ctx.main.playlistPanel
        let view = panel.playlistView
        guard buildFixtures(ctx, full: false) else {
            ctx.check("媒体库-入口素材重铺", false); return
        }
        resetArchives(p)
        ctx.check("媒体库-左栏第二页就是媒体库",
                  panel.groupTitles.count > 1 && panel.groupTitles[1] == "媒体库"
                      && panel.groupVisible(.library),
                  "titles=\(panel.groupTitles)")
        // 空库：中央那句话要指得出去哪儿加目录
        panel.clickGroup(.library)
        ctx.check("媒体库-点左栏就切到库页",
                  p.activeGroup == .library && panel.selectedGroup == .library,
                  "group=\(p.activeGroup)")
        ctx.check("媒体库-空库页说出加目录的路",
                  panel.showsEmptyHint && panel.emptyHintText.contains("添加音乐目录")
                      && panel.infoText.contains("为空"),
                  "hint=\(panel.emptyHintText) info=\(panel.infoText)")
        _ = p.addLibraryFolder(path(music))
        settle(ctx)
        _ = p.scanLibraryFolders([path(music)])
        let n = p.libraryKeys.count
        panel.clickGroup(.main)
        panel.clickGroup(.library)
        ctx.check("媒体库-库页统计按「条」说",
                  panel.infoText.contains("\(n) 条") && !panel.infoText.contains("首"),
                  "info=\(panel.infoText)")
        ctx.check("媒体库-库页行数与库一致", p.playlist.count == n, "rows=\(p.playlist.count)")
        // 这一页删行没意义：话要说清去哪儿改
        view.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        view.refreshContextMenus()
        ctx.check("媒体库-库页不给删行", !view.canRemoveRows, "row=0")
        p.removeTracks(at: IndexSet(integer: 0))
        ctx.check("媒体库-硬要删也只给一句话",
                  p.libraryKeys.count == n && p.libraryProblem?.contains("媒体库列的是盘上有什么") == true,
                  "problem=\(p.libraryProblem ?? "nil")")
        panel.clickGroup(.main)
        view.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        view.refreshContextMenus()
        ctx.check("媒体库-别的页照旧能删行", view.canRemoveRows)
        // 菜单那一路（真入口，不是只给自检留的暗门）
        panel.clickGroup(.library)
        guard let sub = ctx.main.buildLibraryItem().submenu else {
            ctx.check("媒体库-菜单挂了子菜单", false); return
        }
        let titles = sub.items.map { $0.title }
        ctx.check("媒体库-菜单第一行就是库的现状",
                  !sub.items[0].isEnabled && sub.items[0].title == p.libraryStatusText,
                  "row=\(sub.items[0].title)")
        ctx.check("媒体库-菜单四个动作都在",
                  titles.contains("添加音乐目录…") && titles.contains("重新扫描")
                      && titles.contains("停止扫描") && titles.contains("打开媒体库列表"),
                  "titles=\(titles)")
        func row(_ title: String) -> NSMenuItem? { sub.items.first { $0.title == title } }
        ctx.check("媒体库-不扫的时候「停止扫描」按不动",
                  row("停止扫描")?.isEnabled == false && row("重新扫描")?.isEnabled == true,
                  "cancel=\(row("停止扫描")?.isEnabled ?? false)")
        // 逐目录那一行：整条路径在 tooltip 里，三项动作都指着这个目录
        let folderRow = sub.items.first { $0.toolTip == path(music) }
        ctx.check("媒体库-菜单逐目录列出库里的目录", folderRow?.title == "music",
                  "row=\(folderRow?.title ?? "nil")")
        let fsub = folderRow?.submenu?.items ?? []
        ctx.check("媒体库-逐目录三项动作齐",
                  fsub.count == 3 && fsub.allSatisfy { $0.representedObject as? String == path(music) }
                      && fsub[0].title.contains("批量换前缀") && fsub[1].title == "只重扫此目录"
                      && fsub[2].title == "从媒体库移除",
                  "items=\(fsub.map { $0.title })")
        // 失败原因留在菜单里，用户回头还查得到
        _ = p.addLibraryFolder(path(albumA))
        let withProblem = ctx.main.buildLibraryItem().submenu?.items.map { $0.title } ?? []
        ctx.check("媒体库-失败原因留在菜单里",
                  withProblem.contains { $0.hasPrefix("上一次没成：") && $0.contains("整个覆盖") },
                  "titles=\(withProblem)")
        // 扫与不扫两个开关反过来：只能有一个按得动
        p.rescanLibrary()
        let busy = ctx.main.buildLibraryItem().submenu?.items ?? []
        ctx.check("媒体库-扫描中两个开关反过来",
                  busy.first { $0.title == "停止扫描" }?.isEnabled == true
                      && busy.first { $0.title == "重新扫描" }?.isEnabled == false,
                  "enabled=\(busy.map { "\($0.title):\($0.isEnabled)" })")
        p.cancelLibraryScan()
        settle(ctx)
        // 不在线的目录在菜单与库页都说得出名字
        _ = p.addLibraryFolder(path(disk2))
        settle(ctx)
        _ = p.scanLibraryFolders([path(disk2)])
        try? fm.moveItem(at: disk2, to: disk2Gone)
        _ = p.scanLibraryFolders([path(disk2)])
        let offRow = (ctx.main.buildLibraryItem().submenu?.items ?? []).first {
            $0.toolTip == path(disk2)
        }
        ctx.check("媒体库-不在线的目录标题上就写着", offRow?.title == "disk2（当前不在线）",
                  "title=\(offRow?.title ?? "nil")")
        // 库页那句统计必须自己就跟上：没有人手动刷新，只靠扫描报的那一声
        //（整片盘拔走时 added/removed 都是空，漏播 invalid 的话这一句会停在拔盘之前）
        ctx.check("媒体库-库页统计说出几个目录不在线、几条找不到",
                  panel.infoText.contains("1 个目录当前不在线")
                      && panel.infoText.contains("2 条文件找不到"),
                  "info=\(panel.infoText)")
        try? fm.moveItem(at: disk2Gone, to: disk2)
        let scanItem = NSMenuItem()
        scanItem.representedObject = path(disk2)
        ctx.main.libraryFolderRescan(scanItem)
        settle(ctx)
        ctx.check("媒体库-菜单「只重扫此目录」把盘接回来了",
                  p.offlineLibraryFolders.isEmpty
                      && p.libraryKeys.contains(path(disk2.appendingPathComponent("portable.wav"))),
                  "offline=\(p.offlineLibraryFolders) keys=\(p.libraryKeys.count)")
        let dropItem = NSMenuItem()
        dropItem.representedObject = path(disk2)
        ctx.main.libraryFolderRemove(dropItem)
        ctx.check("媒体库-菜单「从媒体库移除」只摘这一片",
                  !p.libraryFolders.contains(path(disk2)) && p.libraryKeys.count == n
                      && !p.libraryKeys.contains(path(disk2.appendingPathComponent("portable.wav"))),
                  "folders=\(p.libraryFolders) keys=\(p.libraryKeys.count)")
        ctx.check("媒体库-菜单入口也不动盘上的文件", fm.fileExists(atPath: path(music)))
        resetArchives(p)
    }

    // MARK: - ⑪ 存档往返与重启恢复

    private func checkPersistence(_ ctx: SelfTestContext) {
        let p = ctx.player
        guard buildFixtures(ctx, full: false) else {
            ctx.check("媒体库-存档素材重铺", false); return
        }
        resetArchives(p)
        _ = p.addLibraryFolder(path(music))
        settle(ctx)
        _ = p.scanLibraryFolders([path(music)])
        stopWatching()
        p.persistNow()
        let state = LibraryStore.load()
        ctx.check("媒体库-存档里的目录表与内存一致", state.libraryFolders == p.libraryFolders,
                  "saved=\(state.libraryFolders)")
        ctx.check("媒体库-存档里的条目引用与内存一致", state.libraryKeys == p.libraryKeys,
                  "saved=\(state.libraryKeys.count) now=\(p.libraryKeys.count)")
        // 旧版档缺这两项：整档要解得开，别的字段不能跟着丢（不然一升级列表就空了）
        if let data = try? Data(contentsOf: LibraryStore.selfTestStateURL),
           var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj["libraryFolders"] = nil
            obj["libraryKeys"] = nil
            if let out = try? JSONSerialization.data(withJSONObject: obj) {
                try? out.write(to: LibraryStore.selfTestStateURL)
                let legacy = LibraryStore.load()
                ctx.check("媒体库-旧档缺这两项也整档解得开",
                          legacy.trackPaths == state.trackPaths && !legacy.trackPaths.isEmpty
                              && legacy.libraryFolders.isEmpty && legacy.libraryKeys.isEmpty,
                          "trackPaths=\(legacy.trackPaths.count) want=\(state.trackPaths.count)")
                p.persistNow()    // 把档写回去，后面的套件用的还是完整档
            }
        } else {
            ctx.check("媒体库-旧档缺这两项也整档解得开", false, "state.json 读不出来")
        }
        // 应用关着的这段时间里盘被拔走：重启恢复只能标失效，一条都不能摘
        let diskKeys = [path(disk2.appendingPathComponent("portable.wav")),
                        path(disk2.appendingPathComponent("live.wav"))]
        try? fm.moveItem(at: disk2, to: disk2Gone)
        p.setupLibrary(folders: [path(music), path(disk2)], keys: state.libraryKeys + diskKeys)
        settle(ctx)
        stopWatching()
        // 库页那一行得看得到才能断言行数：切过去走的就是启动后用户自己会走的那一步
        ctx.main.playlistPanel.clickGroup(.library)
        ctx.check("媒体库-带着离线目录恢复只标失效",
                  p.libraryKeys.count == state.libraryKeys.count + diskKeys.count
                      && p.offlineLibraryFolders == [path(disk2)]
                      && p.libraryMissingCount == diskKeys.count,
                  "keys=\(p.libraryKeys.count) offline=\(p.offlineLibraryFolders)" +
                      " missing=\(p.libraryMissingCount)")
        ctx.check("媒体库-恢复时一条不摘也一条不加",
                  diskKeys.allSatisfy { p.libraryKeys.contains($0) }
                      && p.playlist.count == p.libraryKeys.count,
                  "rows=\(p.playlist.count) keys=\(p.libraryKeys.count)")
        try? fm.moveItem(at: disk2Gone, to: disk2)
        let d = p.scanLibraryFolders([path(disk2)])
        ctx.check("媒体库-盘插回后失效自己摘掉",
                  Set(d.restored) == Set(diskKeys) && p.offlineLibraryFolders.isEmpty
                      && p.libraryMissingCount == 0,
                  "restored=\(d.restored) missing=\(p.libraryMissingCount)")
        resetArchives(p)
    }

    // MARK: - 收摊

    /// 套件只动自己指定的那几个目录：曲库（testlib）一个字节都不能变
    private func cleanup(_ ctx: SelfTestContext) {
        let p = ctx.player
        stopWatching()
        // 收摊不留异步尾巴：元数据解析用的是共用的工人线程（最多 2 并发），大库页那几段
        // 排下去的探测若还挂在队列里，会把下一套的「入表后标签已解析」挤到超时
        let drained = ctx.waitUntil(20) { MetadataReader.pendingCount == 0 }
        ctx.check("媒体库-收摊时元数据队列已排空", drained, "pending=\(MetadataReader.pendingCount)")
        resetArchives(p)
        p.persistNow()
        try? fm.removeItem(at: root)
        // 存档（state.json / resume.json）就落在 testlib 下，本来就是应用自己在写的，
        // 只有素材算痕迹
        func names(_ list: [String]) -> [String] {
            list.filter { ($0 as NSString).pathExtension != "json" }
        }
        let after = names((try? fm.contentsOfDirectory(atPath: ctx.dir.path))?.sorted() ?? [])
        ctx.check("媒体库-素材根目录已删掉", !fm.fileExists(atPath: root.path), "root=\(root.path)")
        ctx.check("媒体库-曲库目录没留下套件的痕迹",
                  after == names(testlibSnapshot),
                  "before=\(testlibSnapshot.count) after=\(after.count)" +
                      " 差集=\(Set(after).symmetricDifference(Set(names(testlibSnapshot))).sorted())")
    }
}
