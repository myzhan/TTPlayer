import Foundation

/// 列表：播放模式前进/后退、循环、随机、删除当前曲后的指向（纯逻辑，冒烟档也跑它）
struct PlaylistSuite: SelfTestSuite {
    func run(_ ctx: SelfTestContext) {
        let pl = Playlist()
        let mk = Track(url: URL(fileURLWithPath: "/tmp/a.mp3"))
        let mk2 = Track(url: URL(fileURLWithPath: "/tmp/b.mp3"))
        let mk3 = Track(url: URL(fileURLWithPath: "/tmp/c.mp3"))
        pl.add(contentsOf: [mk, mk2, mk3])
        _ = pl.select(0)
        ctx.check("顺序播放", pl.advance(for: .order)?.url.lastPathComponent == "b.mp3")
        _ = pl.select(2)
        ctx.check("顺序播放-到末尾停止", pl.advance(for: .order) == nil)
        ctx.check("列表循环", pl.advance(for: .listLoop)?.url.lastPathComponent == "a.mp3")
        _ = pl.retreat(for: .listLoop)
        ctx.check("上一曲-环绕", pl.currentTrack?.url.lastPathComponent == "c.mp3")
        _ = pl.select(0)
        ctx.check("单曲循环", pl.advance(for: .singleLoop)?.url.lastPathComponent == "a.mp3")
        pl.modeIsRandom = true
        ctx.check("随机播放", pl.advance(for: .random) != nil)
        pl.modeIsRandom = false
        _ = pl.select(0)
        pl.remove(at: IndexSet(integer: 0))
        ctx.check("删除当前曲后指向下一首", pl.count == 2 && pl.currentTrack?.url.lastPathComponent == "b.mp3",
                  "cur=\(String(describing: pl.currentTrack?.url.lastPathComponent))")
        checkSort(ctx)
    }

    /// 排序：无当前曲目时也能生效；有当前曲目时排序后仍指向同一个 Track（bugreport P2#5）
    private func checkSort(_ ctx: SelfTestContext) {
        let pl = Playlist()
        let zebra = Track(url: URL(fileURLWithPath: "/tmp/z.bin")); zebra.title = "Zebra"
        let alpha = Track(url: URL(fileURLWithPath: "/tmp/a.bin")); alpha.title = "Alpha"
        let mike  = Track(url: URL(fileURLWithPath: "/tmp/m.bin")); mike.title  = "Mike"
        pl.add(contentsOf: [zebra, alpha, mike])
        pl.sort(by: .title, ascending: true)
        ctx.check("排序-无当前曲目也生效",
                  pl.tracks.map { $0.title } == ["Alpha", "Mike", "Zebra"] && pl.currentTrack == nil,
                  "titles=\(pl.tracks.map { $0.title })")
        _ = pl.select(1)               // Mike
        let cur = pl.currentTrack
        pl.sort(by: .title, ascending: false)
        ctx.check("排序-有当前曲目仍指向同一 Track",
                  pl.currentTrack === cur
                    && pl.tracks.map { $0.title } == ["Zebra", "Mike", "Alpha"],
                  "cur=\(pl.currentTrack?.title ?? "nil") titles=\(pl.tracks.map { $0.title })")
        // 单曲列表不报错，不改变指向
        let solo = Playlist()
        solo.add(Track(url: URL(fileURLWithPath: "/tmp/s.bin")))
        _ = solo.select(0)
        solo.sort(by: .title, ascending: true)
        ctx.check("排序-单曲列表无操作", solo.count == 1 && solo.currentTrack?.url.lastPathComponent == "s.bin",
                  "n=\(solo.count)")
    }
}
