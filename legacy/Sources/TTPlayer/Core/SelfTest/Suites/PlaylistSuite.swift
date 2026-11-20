import Foundation

/// 浏览列表（纯逻辑，冒烟档也跑它）：选中行的语义、删除后的指向、按稳定身份找行、排序。
/// 「接下来播谁」不在这里 —— 那是 `PlayQueue` 的职责，断言见队列套件（F03）。
struct PlaylistSuite: SelfTestSuite {
    func run(_ ctx: SelfTestContext) {
        let pl = Playlist()
        let mk = Track(url: URL(fileURLWithPath: "/tmp/a.mp3"))
        let mk2 = Track(url: URL(fileURLWithPath: "/tmp/b.mp3"))
        let mk3 = Track(url: URL(fileURLWithPath: "/tmp/c.mp3"))
        pl.add(contentsOf: [mk, mk2, mk3])

        // 选中就是一行高亮：可以选中、可以取消，越界不动它
        ctx.check("选中越界无效", pl.select(9) == nil && pl.currentIndex == nil)
        ctx.check("选中生效", pl.select(1)?.url.lastPathComponent == "b.mp3" && pl.currentIndex == 1)
        pl.clearSelection()
        ctx.check("取消选中后无高亮行", pl.currentIndex == nil && pl.currentTrack == nil)

        // 按稳定身份找行：派生组还原出来的不是同一个对象，但 identityKey 相同
        ctx.check("按身份找行命中", pl.index(ofKey: mk2.identityKey) == 1)
        ctx.check("按身份找行不误命中", pl.index(ofKey: "/tmp/nope.mp3") == nil)

        // 删行：删掉选中行时高亮落到顶上来那一行（这是表格行为，跟正在播的是谁无关）
        _ = pl.select(0)
        pl.remove(at: IndexSet(integer: 0))
        ctx.check("删除选中行后指向后一行", pl.count == 2 && pl.currentTrack?.url.lastPathComponent == "b.mp3",
                  "cur=\(String(describing: pl.currentTrack?.url.lastPathComponent))")
        // 删后面的行不该把选中行挪走
        pl.remove(at: IndexSet(integer: 1))
        ctx.check("删除非选中行不动高亮", pl.count == 1 && pl.currentTrack?.url.lastPathComponent == "b.mp3",
                  "n=\(pl.count) cur=\(String(describing: pl.currentTrack?.url.lastPathComponent))")
        pl.removeAll()
        ctx.check("清空列表", pl.isEmpty && pl.currentIndex == nil)

        checkFind(ctx)
        checkSort(ctx)
    }

    /// 快捷查找：环形、大小写不敏感、空关键字不跳
    private func checkFind(_ ctx: SelfTestContext) {
        let pl = Playlist()
        let alpha = Track(url: URL(fileURLWithPath: "/tmp/Alpha.mp3")); alpha.title = "Alpha"
        let mike = Track(url: URL(fileURLWithPath: "/tmp/Mike.mp3")); mike.title = "Mike"
        pl.add(contentsOf: [alpha, mike])
        ctx.check("查找-空关键字不跳", pl.indexOfNext(matching: "", after: nil) == nil)
        ctx.check("查找-大小写不敏感", pl.indexOfNext(matching: "MIKE", after: nil) == 1)
        ctx.check("查找-环形回到开头", pl.indexOfNext(matching: "al", after: 1) == 0,
                  "hit=\(String(describing: pl.indexOfNext(matching: "al", after: 1)))")
        ctx.check("查找-无匹配", pl.indexOfNext(matching: "zzz", after: nil) == nil)
    }

    /// 排序：无选中行时也能生效；有选中行时排序后仍指向同一个 Track（bugreport P2#5）
    private func checkSort(_ ctx: SelfTestContext) {
        let pl = Playlist()
        let zebra = Track(url: URL(fileURLWithPath: "/tmp/z.bin")); zebra.title = "Zebra"
        let alpha = Track(url: URL(fileURLWithPath: "/tmp/a.bin")); alpha.title = "Alpha"
        let mike  = Track(url: URL(fileURLWithPath: "/tmp/m.bin")); mike.title  = "Mike"
        pl.add(contentsOf: [zebra, alpha, mike])
        pl.sort(by: .title, ascending: true)
        ctx.check("排序-无选中行也生效",
                  pl.tracks.map { $0.title } == ["Alpha", "Mike", "Zebra"],
                  "titles=\(pl.tracks.map { $0.title })")
        _ = pl.select(1)               // Mike
        let cur = pl.currentTrack
        pl.sort(by: .title, ascending: false)
        ctx.check("排序-有选中行仍指向同一 Track",
                  pl.currentTrack === cur && pl.tracks.map { $0.title } == ["Zebra", "Mike", "Alpha"],
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
