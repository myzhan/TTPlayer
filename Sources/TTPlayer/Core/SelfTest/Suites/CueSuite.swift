import Foundation

/// CUE 分轨：GBK 存盘的整盘分轨表（国内抓轨常见）解析、只给分轨表也能展开成多首、
/// 存档往返、扫目录时不把整盘镜像再算一遍，以及“只播本段、段尾切到下一轨”这条播放语义。
struct CueSuite: SelfTestSuite {
    func run(_ ctx: SelfTestContext) {
        let p = ctx.player
        let dirURL = ctx.dir
        let cueURL = ctx.cueAlbumURL()
        let image = ctx.libraryNames.first { $0.lowercased().hasSuffix(".wav") } ?? "demo01.wav"

        let sheet = CueSheet.parse(url: cueURL)
        ctx.check("CUE 解析-轨数", (sheet?.tracks.count ?? 0) == 3, "n=\(sheet?.tracks.count ?? -1)")
        guard let sheet, sheet.tracks.count == 3 else { return }
        let t = sheet.tracks
        ctx.check("CUE 解析-GBK 中文标题", t[0].title == "Track One", "t=\(t[0].title)")
        ctx.check("CUE 解析-专辑信息",
                  sheet.albumPerformer == "TestArtist" && sheet.albumTitle == "TestAlbum",
                  "\(sheet.albumPerformer)/\(sheet.albumTitle)")
        // INDEX 01 才是本轨起点（INDEX 00 是隐藏前隙，不能当起点）
        ctx.check("CUE 解析-起点取 INDEX 01",
                  abs(t[1].start - 4.0) < 0.01 && abs(t[2].start - 8.4) < 0.01,
                  "t2=\(String(format: "%.2f", t[1].start)) t3=\(String(format: "%.2f", t[2].start))")
        ctx.check("CUE 解析-末轨放到盘尾",
                  t[2].nextStart == nil && (t[0].duration ?? -1) > 3.9,
                  "d1=\(t[0].duration ?? -1) lastEnd=\(String(describing: t[2].nextStart))")

        let cueTracks = ctx.cueAlbumTracks()
        ctx.check("CUE 只给分轨表也展开成多首",
                  cueTracks.count == 3 && cueTracks.allSatisfy { $0.isCueSegment }
                    && cueTracks.allSatisfy { $0.url.lastPathComponent == image },
                  "n=\(cueTracks.count)")
        ctx.check("CUE 分轨元数据直接就位",
                  cueTracks.count == 3 && cueTracks[1].title == "Track Two"
                    && cueTracks[1].artist == "TestArtist" && cueTracks[1].duration > 4.3,
                  cueTracks.count == 3 ? "\(cueTracks[1].title)/\(cueTracks[1].artist)" : "空")
        let entries = cueTracks.map { $0.identityKey }
        let restored = LibraryStore.tracks(fromArchiveEntries: entries)
        ctx.check("CUE 存档往返回到同一张盘",
                  restored.count == 3 && restored.map { $0.identityKey } == entries
                    && restored.allSatisfy { $0.cue != nil },
                  "n=\(restored.count) key=\(entries.first ?? "")")
        let scanned = LibraryStore.tracks(in: [dirURL])
        let fromImage = scanned.filter { $0.url.lastPathComponent == image }
        ctx.check("CUE 扫目录不重复入整盘镜像",
                  fromImage.count == 3 && fromImage.allSatisfy { $0.isCueSegment }
                    && scanned.contains { $0.url.lastPathComponent == "demo02.wav" },
                  "total=\(scanned.count) imageTracks=\(fromImage.count)")

        guard cueTracks.count == 3 else { return }

        // 播放语义：只播镜像里属于本轨的那一段，段尾自动切轨
        p.clearPlaylist()
        ctx.check("空列表时提示拖入文件",
                  ctx.main.displayPanel.noteText == "拖入文件开始播放",
                  "note=\(ctx.main.displayPanel.noteText)")
        // 前面的用例可能把模式切成随机，这里要确定性的“下一曲”
        p.setMode(.listLoop)
        _ = p.addTracks(cueTracks)
        // 从存档恢复出曲目但还没播放时，不能还写着“拖入文件”
        ctx.check("未播放时显示区报出列表规模",
                  ctx.main.displayPanel.noteText == "已载入 \(p.playlist.count) 首",
                  "note=\(ctx.main.displayPanel.noteText)")
        p.playRowAt(1)          // 第二轨：镜像内 4.00s 起，长 4.40s
        ctx.check("CUE 播放-时长取本段而非整盘",
                  abs(p.duration - 4.4) < 0.1,
                  "dur=\(String(format: "%.2f", p.duration))")
        ctx.check("CUE 播放-位置从本段起算", p.currentTime < 0.5,
                  "t=\(String(format: "%.2f", p.currentTime))")
        _ = ctx.waitUntil(3.0) { p.currentTime > 0.6 }
        ctx.check("CUE 播放-段内推进",
                  p.currentTime > 0.6 && p.currentTime < 2.5,
                  "t=\(String(format: "%.2f", p.currentTime))")
        // 跳到本段最后 0.3s：播完应切到下一轨，而不是继续播到镜像尾部
        p.seek(to: max(0, p.duration - 0.3))
        _ = ctx.waitUntil(4.0) { p.playlist.currentIndex == 2 }
        ctx.check("CUE 播放-段尾自动切轨",
                  p.playlist.currentIndex == 2
                    && p.playlist.currentTrack?.title == "Track Three",
                  "idx=\(String(describing: p.playlist.currentIndex)) "
                    + "t=\(String(format: "%.2f", p.currentTime))")
        p.stop()
    }
}
