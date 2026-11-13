import Foundation
import AppKit

/// 自建歌单（requirements F04）：名字规矩与稳定身份、多张歌单共享曲目、组内去重、
/// 删除/清空只动这一张、左栏入口与拖动排序、m3u 四类行文的往返与循环防护、
/// 缺失引用标记、存档迁移。
/// 前两段是仓库与控制器逻辑，第三段走真实皮肤窗（左栏那一列与表格右键），
/// 后两段读写真文件与真存档，所以整个套件需要窗口 + 曲库 + 分轨表就位。
struct UserListSuite: SelfTestSuite {
    func run(_ ctx: SelfTestContext) {
        checkNameRules(ctx)
        checkListEditing(ctx)
        checkPanelEntries(ctx)
        checkM3U(ctx)
        checkPersistence(ctx)
        cleanup(ctx)
    }

    /// 套尾把自建歌单全删掉：后面的套件（性能、队列、界面）不该看到本套件留下的歌单页
    private func cleanup(_ ctx: SelfTestContext) {
        let p = ctx.player
        p.switchGroup(.main)
        for id in p.userLists.ids { _ = p.deleteList(id: id) }
        ctx.check("歌单-收尾清空自建歌单", p.userLists.isEmpty && p.groupLayout.count == GroupKind.alwaysPages.count,
                  "n=\(p.userLists.count)")
    }

    // MARK: - 名字与仓库规矩

    private func checkNameRules(_ ctx: SelfTestContext) {
        let p = ctx.player
        let lists = p.userLists

        ctx.check("歌单-空白名字建不出来", p.createList(named: "   ") == nil)
        ctx.check("歌单-全角空格与制表也算空名字", p.createList(named: "\u{3000} \t\n") == nil)

        guard let first = p.createList(named: "  通勤  ") else {
            ctx.check("歌单-去首尾空白后能建", false, "create 返回 nil"); return
        }
        ctx.check("歌单-去首尾空白后能建", lists.name(of: first.id) == "通勤" && first.note == nil,
                  "name=\(lists.name(of: first.id) ?? "nil")")

        let again = p.createList(named: "通勤")
        ctx.check("歌单-同名自动区分并说明", again?.note != nil && lists.name(of: again?.id ?? "") == "通勤 (2)",
                  "name=\(lists.name(of: again?.id ?? "") ?? "nil") note=\(again?.note ?? "nil")")
        let longName = p.createList(named: String(repeating: "长", count: UserPlaylists.nameLimit + 20))
        ctx.check("歌单-名字截到左栏放得下的长度",
                  longName.flatMap { (lists.name(of: $0.id) ?? "").count } == UserPlaylists.nameLimit)

        // 组内去重、跨组互不影响
        let base = lists.keys(of: first.id)
        ctx.check("歌单-空歌单没有条目", base.isEmpty)
        ctx.check("歌单-组内重复键只留一行",
                  lists.add(keys: ["k1", "k1", "k2"], to: first.id) == 2
                    && lists.keys(of: first.id) == ["k1", "k2"])
        ctx.check("歌单-同一首能进另一张", lists.add(keys: ["k1", "k2"], to: again!.id) == 2)
        ctx.check("歌单-从一张删引用不动另一张",
                  lists.remove(keys: ["k1"], from: first.id) == 1
                    && lists.keys(of: first.id) == ["k2"] && lists.keys(of: again!.id).count == 2)
        ctx.check("歌单-清空只清这一张",
                  { lists.clear(id: first.id); return lists.keys(of: first.id).isEmpty && lists.keys(of: again!.id).count == 2 }())

        // 拖动排序的落点口径（NSTableView：「放到第 to 行之前」）
        lists.clear(id: first.id)
        _ = lists.add(keys: ["a", "b", "c", "d"], to: first.id)
        ctx.check("歌单-拖动挪到某行之前",
                  lists.move(id: first.id, from: IndexSet(integer: 0), to: 3)
                    && lists.keys(of: first.id) == ["b", "c", "a", "d"],
                  "keys=\(lists.keys(of: first.id))")
        ctx.check("歌单-落点越界夹到末尾",
                  lists.move(id: first.id, from: IndexSet(integer: 0), to: 99)
                    && lists.keys(of: first.id).last == "b", "keys=\(lists.keys(of: first.id))")
        let four = lists.keys(of: first.id)
        ctx.check("歌单-整体重排拒绝非全排列",
                  !lists.reorder(id: first.id, to: Array(four.dropLast())) && lists.keys(of: first.id) == four)
        let flipped = Array(four.reversed())
        ctx.check("歌单-整体重排按给定次序生效",
                  lists.reorder(id: first.id, to: flipped) && lists.keys(of: first.id) == flipped)

        // 存档宽容度：空名字、重复 ID、重名、组内重复键都要能被兜住
        lists.restore([UserPlaylist(id: "x1", name: "  旧甲  ", keys: ["p", "p", "q"]),
                       UserPlaylist(id: "x1", name: "重复ID", keys: []),
                       UserPlaylist(id: "x2", name: "   ", keys: ["z"]),
                       UserPlaylist(id: "x3", name: "旧甲", keys: ["r"])])
        let restored = lists.items
        ctx.check("歌单-脏存档里空名与重复ID被丢掉", restored.count == 2,
                  "n=\(restored.count) names=\(restored.map { $0.name })")
        ctx.check("歌单-脏存档里重名自动区分",
                  restored.map { $0.name } == ["旧甲", "旧甲 (2)"], "names=\(restored.map { $0.name })")
        ctx.check("歌单-脏存档里组内键去重", restored.first?.keys == ["p", "q"],
                  "keys=\(restored.first?.keys ?? [])")
        lists.restore([])
        ctx.check("歌单-旧档没有这一项就是空表", lists.isEmpty)
    }

    // MARK: - 控制器层的增删改与影响范围

    private func checkListEditing(_ ctx: SelfTestContext) {
        let p = ctx.player
        p.switchGroup(.main)
        let lib = p.playlist.tracks
        let mainN = lib.count
        guard lib.count >= 3, let madeA = p.createList(named: "甲") else {
            ctx.check("歌单-曲库与建表前置", false, "lib=\(lib.count)"); return
        }
        let a = madeA.id
        ctx.check("歌单-建完就停在它那一页", p.activeGroup == .playlist(a))
        guard let b = p.createList(named: "乙") else {
            ctx.check("歌单-能接连建两张", false); return
        }

        let picked = Array(lib.prefix(3))
        ctx.check("歌单-按显示顺序加入三首", p.addTracks(picked, toList: a) == 3)
        ctx.check("歌单-重复加入不再增行",
                  p.addTracks(picked, toList: a) == 0 && p.userLists.keys(of: a).count == 3)
        ctx.check("歌单-同一首能进两张且各算一份引用", p.addTracks(picked, toList: b.id) == 3)
        ctx.check("歌单-两张的键互不干扰",
                  p.userLists.keys(of: a) == p.userLists.keys(of: b.id) && p.userLists.keys(of: b.id).count == 3)

        // 在歌单页删行 = 只从这张拿掉引用：默认列表、别的歌单、待播队列都不动
        p.switchGroup(.playlist(a))
        p.playLater([picked[2]])
        let pendingBefore = p.queue.pendingCount
        p.removeTracks(at: IndexSet(integer: 0))
        ctx.check("歌单-删行只从这张拿掉引用",
                  p.userLists.keys(of: a).count == 2 && p.userLists.keys(of: b.id).count == 3,
                  "a=\(p.userLists.keys(of: a).count) b=\(p.userLists.keys(of: b.id).count)")
        p.switchGroup(.main)
        ctx.check("歌单-删行不动默认列表", p.playlist.count == mainN, "n=\(p.playlist.count)")
        ctx.check("歌单-删行动不了待播队列", p.queue.pendingCount == pendingBefore,
                  "pending=\(p.queue.pendingCount)")

        // 清空与删除这张：正在播的、收藏、默认列表、别的歌单都不该受影响
        p.switchGroup(.playlist(a))
        if !p.isFavorite(picked[1]) { p.toggleFavorite(picked[1]) }
        p.play(track: picked[1])
        ctx.pump(0.2)
        let curKey = p.currentTrack?.identityKey
        ctx.check("歌单-先有一首在播（前置）", curKey == picked[1].identityKey,
                  "cur=\(p.currentTrack?.title ?? "nil")")
        let cleared = p.clearList(id: a)
        ctx.check("歌单-清空报出影响条数", cleared == 2 && p.userLists.keys(of: a).isEmpty,
                  "n=\(cleared)")
        ctx.check("歌单-清空只让这一张变空",
                  p.playlist.isEmpty && p.userLists.keys(of: a).isEmpty)
        ctx.check("歌单-清空不动正在播与待播",
                  p.currentTrack?.identityKey == curKey && p.queue.pendingCount == pendingBefore,
                  "cur=\(p.currentTrack?.title ?? "nil") pending=\(p.queue.pendingCount)")
        p.switchGroup(.main)
        ctx.check("歌单-清空不动收藏与默认列表",
                  p.groups.isFavorite(picked[1]) && p.playlist.count == mainN,
                  "n=\(p.playlist.count) main=\(mainN)")
        p.stop()

        // 改名与还原都要在看这一页时验：上面刚切回 [默认] 确认过默认列表没动
        p.switchGroup(.playlist(a))
        p.addTracks(picked, toList: a)
        let keysBefore = p.userLists.keys(of: a)
        ctx.check("歌单-改名不动身份与条目",
                  p.renameList(id: a, to: "  通勤金曲  ") == nil
                    && p.userLists.keys(of: a) == keysBefore
                    && p.userLists.name(of: a) == "通勤金曲")
        ctx.check("歌单-改名不弹页", p.activeGroup == .playlist(a) && p.playlist.count == keysBefore.count)
        ctx.check("歌单-改名后空名不改任何东西",
                  p.renameList(id: a, to: "  \u{3000} ") != nil && p.userLists.name(of: a) == "通勤金曲")

        // 派生页还原出来的就是同一批曲目对象（元数据已解析，不重读）
        let sameObject = p.playlist.tracks.first?.identityKey == keysBefore.first
            && p.playlist.tracks.allSatisfy { $0.duration > 0 || $0.isRadio }
        ctx.check("歌单-这一页还原的是已知曲目对象", sameObject,
                  "keys=\(keysBefore.count) 首时长=\(p.playlist.tracks.first?.duration ?? 0)")

        // 删除整张：正在看这一页要先有页可看，回 [默认] 不能停在「歌单已不存在」
        p.switchGroup(.main)
        let mainAfter = p.playlist.count
        let gone = p.deleteList(id: a)
        ctx.check("歌单-删除返回被删的那张", gone?.name == "通勤金曲" && gone?.keys.count == 3,
                  "name=\(gone?.name ?? "nil") n=\(gone?.keys.count ?? -1)")
        ctx.check("歌单-删除不动默认列表与别的歌单",
                  p.playlist.count == mainAfter && p.userLists.keys(of: b.id).count == 3)
        ctx.check("歌单-删除后这张查无此键",
                  p.userLists.name(of: a) == nil && p.userLists.keys(of: a).isEmpty)
    }

    // MARK: - 界面入口（左栏那一列与表格右键）

    private func checkPanelEntries(_ ctx: SelfTestContext) {
        let p = ctx.player
        let panel = ctx.main.playlistPanel
        let view = panel.playlistView
        p.switchGroup(.main)
        // 前面两段留下的歌单先清干：本段要对左栏的行数与次序下硬断言，必须从一张都没有开始
        for id in p.userLists.ids { _ = p.deleteList(id: id) }
        let lib = p.playlist.tracks
        guard lib.count >= 3 else { ctx.check("歌单-曲库前置", false, "n=\(lib.count)"); return }

        guard let big = p.createList(named: "通勤金曲"), let solo = p.createList(named: "单曲一张") else { return }
        _ = p.addTracks(Array(lib.prefix(4)), toList: big.id)
        _ = p.addTracks([lib[0]], toList: solo.id)

        // 左栏：一定有的页（固定六页 + 未分类电台）在前，歌单页按创建顺序跟在后面
        let titles = panel.groupTitles
        let always = GroupKind.alwaysPages.map { $0.name }
        ctx.check("歌单-左栏固定页在前歌单页在后",
                  Array(titles.prefix(always.count)) == always
                    && titles.count == always.count + 2
                    && Array(titles.suffix(2)) == ["通勤金曲", "单曲一张"],
                  "titles=\(titles)")
        ctx.check("歌单-点左栏能切到歌单页", {
            panel.clickGroup(.playlist(big.id))
            return panel.selectedGroup == .playlist(big.id) && p.playlist.count == 4
        }())
        // 目视用：左栏多了一列歌单页、表格只列这一张的四首
        ctx.snapshot(panel.window, named: "shot_group_playlist")
        ctx.check("歌单-切回默认页也不丢歌单", {
            panel.clickGroup(.main)
            return panel.selectedGroup == .main && p.playlist.count == lib.count
        }())

        // 右键菜单：形状稳定，能做的事按页面置灰
        let fixedMenu = panel.makeGroupMenu(for: .main)
        let bigMenu = panel.makeGroupMenu(for: .playlist(big.id))
        let emptyMenu = panel.makeGroupMenu(for: .playlist(solo.id))
        ctx.check("歌单-固定页只给两个可用入口", fixedMenu.items.filter { $0.isEnabled }.count == 2,
                  "n=\(fixedMenu.items.filter { $0.isEnabled }.count)")
        ctx.check("歌单-歌单页六个入口都可用", bigMenu.items.filter { $0.isEnabled }.count == 6,
                  "titles=\(bigMenu.items.map { $0.title })")
        _ = p.clearList(id: solo.id)
        let emptyMenu2 = panel.makeGroupMenu(for: .playlist(solo.id))
        ctx.check("歌单-空歌单的导出与清空置灰",
                  emptyMenu2.items.filter { $0.isEnabled }.count == emptyMenu.items.filter { $0.isEnabled }.count - 2,
                  "n=\(emptyMenu2.items.filter { $0.isEnabled }.count)")
        ctx.check("歌单-菜单标题写清是哪一张",
                  bigMenu.items.contains { $0.title.contains("重命名「通勤金曲」") }
                    && bigMenu.items.contains { $0.title.contains("清空「通勤金曲」的 4 条引用") },
                  "titles=\(bigMenu.items.map { $0.title })")

        // 歌单页右键的「清空歌单「X」」与「加入歌单」子菜单
        panel.clickGroup(.playlist(big.id))
        view.refreshContextMenus()
        ctx.check("歌单-表格清空项带上歌单名", view.clearItemTitle == "清空歌单「通勤金曲」",
                  "title=\(view.clearItemTitle ?? "nil")")
        panel.clickGroup(.main)
        view.table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)
        view.refreshContextMenus()
        ctx.check("歌单-子菜单列出全部歌单",
                  view.addToListTitles == ["通勤金曲", "单曲一张"] && view.canAddToList,
                  "titles=\(view.addToListTitles)")
        let before = p.userLists.keys(of: solo.id).count
        view.addRowsToListThroughUI(IndexSet(integersIn: 0..<2), list: solo.id)
        ctx.check("歌单-点子菜单某张就加进那张",
                  p.userLists.keys(of: solo.id).count == before + 2
                    && p.userLists.keys(of: big.id).count == 4,
                  "solo=\(p.userLists.keys(of: solo.id).count)")

        // 名字取到上限那么长时：右上角那行统计只能截断，不许压到工具条那排键上
        let tallName = String(repeating: "通", count: UserPlaylists.nameLimit)
        guard let tall = p.createList(named: tallName) else {
            ctx.check("歌单-长名字前置建表", false); return
        }
        _ = p.addTracks(Array(lib.prefix(3)), toList: tall.id)
        panel.clickGroup(.playlist(tall.id))
        ctx.check("歌单-长名字的统计文字不压工具条", panel.infoTextClearOfToolbar,
                  "info=\(panel.infoText)")
        _ = p.deleteList(id: tall.id)

        // 行内拖动排序：与真拖放同一段换算
        panel.clickGroup(.playlist(solo.id))
        let order = p.userLists.keys(of: solo.id)
        ctx.check("歌单-拖动把首行挪到末行前",
                  order.count > 1 && view.reorderListRowThroughUI(fromRow: 0, toRow: order.count)
                    && p.userLists.keys(of: solo.id) == Array(order.dropFirst()) + [order[0]],
                  "keys=\(p.userLists.keys(of: solo.id).count)")
        let after = p.userLists.keys(of: solo.id)
        ctx.check("歌单-不属于这张的键不落进来",
                  !view.applyListReorder(movedKeys: ["/ nowhere/ghost.wav"], toRow: 1)
                    && p.userLists.keys(of: solo.id) == after)

        // 歌单多起来：面板不长高，滚下去能看到最下面那张，滚上来固定页又全露出来
        var extra: [String] = []
        for i in 0..<8 { _ = p.createList(named: "追加\(i)").map { extra.append($0.id) } }
        let lastID = extra.last ?? ""
        ctx.check("歌单-歌单多了左栏能滚到最后一张", {
            panel.scrollGroupIntoView(.playlist(lastID))
            return panel.groupColumnScrolls && panel.groupVisible(.playlist(lastID))
        }(), "rows=\(panel.groupItemCount) scrolls=\(panel.groupColumnScrolls)")
        ctx.check("歌单-滚回顶部时固定页一行都没被裁", {
            panel.scrollGroupsToTop()
            return panel.fixedGroupsFitInWell
        }(), "rows=\(panel.groupItemCount)")
        for id in extra { _ = p.deleteList(id: id) }
        ctx.check("歌单-删掉后固定页没被裁", panel.fixedGroupsFitInWell,
                  "rows=\(panel.groupItemCount)")

        // 一张歌单都没有时，子菜单只给一句去处，不能让人点了没反应
        p.switchGroup(.main)
        view.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        for id in p.userLists.ids { _ = p.deleteList(id: id) }
        view.refreshContextMenus()
        ctx.check("歌单-没有歌单时子菜单给一句去处",
                  view.addToListTitles.count == 1 && view.addToListTitles[0].contains("新建歌单")
                    && !view.canAddToList, "titles=\(view.addToListTitles)")
    }

    // MARK: - m3u 导入导出（四类行文、特殊字符、循环防护）

    private func checkM3U(_ ctx: SelfTestContext) {
        let p = ctx.player
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ttplayer-lists", isDirectory: true)
        try? ctx.fm.removeItem(at: root)
        try? ctx.fm.createDirectory(at: root, withIntermediateDirectories: true)

        let plain = root.appendingPathComponent("demo a.wav")
        let tricky = root.appendingPathComponent("带 空格「引号」.wav")
        _ = ctx.writeWave(plain, sampleRate: 44_100, channels: 2, bits: 16, freqs: [440, 660], seconds: 1)
        _ = ctx.writeWave(tricky, sampleRate: 44_100, channels: 2, bits: 16, freqs: [550, 660], seconds: 1)
        let gone = root.appendingPathComponent("已经不在了.wav").path

        // 四类来路各一条：普通文件、精确选中的一轨 CUE、电台、（能造的话）归档里的一个条目
        var sources: [Track] = [Track(url: plain), Track(url: tricky)]
        let cue = ctx.cueAlbumTracks()
        if cue.count >= 2 { sources.append(cue[1]) }
        sources.append(Track(radio: URL(string: "http://live.example.com:8000/电台")!))
        if let entry = archiveEntryTrack(ctx, root: root) {
            sources.append(entry)
        } else {
            ctx.emit("[selftest] SKIP 歌单-归档条目写法（本机造不出 zip fixture）")
        }
        let expected = sources.map { $0.identityKey }
        let made = p.createList(named: "四类写法")
        guard let id = made?.id else { ctx.check("歌单-导出前置建表", false); return }
        _ = p.addTracks(sources, toList: id)
        // 盘上没有的那条直接放键进去（模拟一份从别处拷来的歌单引用）
        _ = p.userLists.add(keys: [gone], to: id)

        let out = root.appendingPathComponent("四类写法.m3u")
        ctx.check("歌单-导出写成功", p.exportList(id: id, to: out))
        let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        ctx.check("歌单-导出带扩展标记与兼容说明",
                  text.contains(PlaylistM3U.marker) && text.contains(PlaylistM3U.compatibilityNote))
        ctx.check("歌单-四类行文各占一行",
                  text.contains("\(plain.path)\n") && text.contains("\(gone)\n")
                    && text.contains("http://live.example.com:8000")
                    && (cue.count < 2 || text.contains("#track=2"))
                    && (!text.contains("#track=1") && !text.contains("#track=3")),
                  "len=\(text.count)")

        guard let back = p.importList(from: out, named: "读回来") else {
            ctx.check("歌单-导出能读回来", false, "import 返回 nil"); return
        }
        ctx.check("歌单-导入后键与导出逐字符相同",
                  p.userLists.keys(of: back.id) == expected + [gone],
                  "got=\(p.userLists.keys(of: back.id)) want=\(expected + [gone])")
        ctx.check("歌单-精确选中的轨与条目没被展开",
                  p.userLists.keys(of: back.id).filter { $0.contains("#track=") }.count == (cue.count >= 2 ? 1 : 0)
                    && p.userLists.keys(of: back.id).filter { $0.contains("#archive-entry=") }.count
                        == (text.contains("#archive-entry=") ? 1 : 0),
                  "keys=\(p.userLists.keys(of: back.id))")
        ctx.check("歌单-导入时按名字带上说明", back.note.contains("条入歌单") || back.note.contains("缺失"),
                  "note=\(back.note)")

        // 缺失引用要留在表里、标得出来、并且删得掉（身份必须与存档写法一致）
        p.switchGroup(.playlist(back.id))
        let rows = p.playlist.tracks
        ctx.check("歌单-还原出来的每行身份都等于存档写法",
                  rows.map { $0.identityKey } == p.userLists.keys(of: back.id),
                  "rows=\(rows.map { $0.identityKey })")
        let goneRow = rows.firstIndex { $0.identityKey == gone } ?? -1
        ctx.check("歌单-盘上没有了的引用还在表里并标失效",
                  goneRow >= 0 && rows[goneRow].missingOnDisk
                    && !rows[goneRow].isRadio && rows.filter { $0.missingOnDisk }.count == 1,
                  "row=\(goneRow)")
        ctx.check("歌单-缺失行的时长列写「缺失」",
                  goneRow >= 0 && ctx.main.playlistPanel.playlistView.durationText(row: goneRow) == "缺失",
                  "text=\(ctx.main.playlistPanel.playlistView.durationText(row: goneRow) ?? "nil")")
        ctx.check("歌单-缺失条目属性里说得清楚",
                  rows.first(where: { $0.identityKey == gone })?.propertyLines
                      .contains { $0.0 == "文件状态" && $0.1.contains("已不在磁盘上") } == true)
        p.switchGroup(.main)
        let mainBefore = p.playlist.count
        p.switchGroup(.playlist(back.id))
        p.removeTracks(at: IndexSet(integer: goneRow))
        ctx.check("歌单-失效引用可以单独删掉",
                  !p.userLists.keys(of: back.id).contains(gone) && p.playlist.count == rows.count - 1)
        p.switchGroup(.main)
        ctx.check("歌单-删失效引用不动默认列表", p.playlist.count == mainBefore)

        // 第三方写法：相对路径按文件所在目录解析；非音频行计入「读不懂」
        let third = root.appendingPathComponent("第三方.m3u")
        try? "#EXTM3U\n#EXTINF:120,某首\n\(plain.lastPathComponent)\n说明.txt\n\(gone)\n"
            .write(to: third, atomically: true, encoding: .utf8)
        let imported = PlaylistM3U.import(third)
        ctx.check("歌单-第三方相对路径解析成绝对",
                  imported?.keys.first == plain.path, "keys=\(imported?.keys ?? [])")
        ctx.check("歌单-读不懂的行数会说明", imported?.unreadable == 1 && imported?.missing == [gone],
                  "unreadable=\(imported?.unreadable ?? -1) missing=\(imported?.missing ?? [])")

        // 嵌套与循环：a 引 b、b 又引 a，必须终止且每首只出现一次
        let cycleA = root.appendingPathComponent("循环a.m3u")
        let cycleB = root.appendingPathComponent("循环b.m3u")
        try? "#EXTM3U\n循环b.m3u\n\(tricky.lastPathComponent)\n".write(to: cycleA, atomically: true, encoding: .utf8)
        try? "#EXTM3U\n循环a.m3u\n\(plain.lastPathComponent)\n".write(to: cycleB, atomically: true, encoding: .utf8)
        let cyc = PlaylistM3U.import(cycleA)
        ctx.check("歌单-循环引用的歌单能读完且不重复",
                  cyc?.keys.count == 2 && Set(cyc?.keys ?? []) == Set([plain.path, tricky.path]),
                  "keys=\(cyc?.keys ?? [])")

        // 整张分轨表 / 整个归档这类「用户没精确选」的行仍然按原规则展开
        let whole = root.appendingPathComponent("整盘.m3u")
        try? "\(ctx.cueAlbumURL().path)\n".write(to: whole, atomically: true, encoding: .utf8)
        let expanded = PlaylistM3U.import(whole)
        ctx.check("歌单-整张分轨表的行展开成整盘的轨",
                  expanded?.keys.count == cue.count
                    && expanded?.keys.first == cue.first?.identityKey,
                  "n=\(expanded?.keys.count ?? -1) cue=\(cue.count)")

        for list in p.userLists.items where list.name != "通勤金曲" && list.name != "单曲一张" {
            _ = p.deleteList(id: list.id)
        }
    }

    /// 现场造一个只含一首的 zip，取它展开后的那一条曲目（拿真实 identityKey）；
    /// 本机没有 zip CLI 时返回 nil，由调用方标 SKIP
    private func archiveEntryTrack(_ ctx: SelfTestContext, root: URL) -> Track? {
        let stage = root.appendingPathComponent("stage", isDirectory: true)
        let src = ctx.dir.appendingPathComponent("demo02.wav")
        guard ctx.fm.fileExists(atPath: src.path) else { return nil }
        try? ctx.fm.createDirectory(at: stage, withIntermediateDirectories: true)
        let song = stage.appendingPathComponent("01 - beta.wav")
        try? ctx.fm.removeItem(at: song)
        try? ctx.fm.copyItem(at: src, to: song)
        let zip = root.appendingPathComponent("album.zip")
        try? ctx.fm.removeItem(at: zip)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.arguments = ["-q", "-j", zip.path, "01 - beta.wav"]
        task.currentDirectoryURL = stage
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0, ctx.fm.fileExists(atPath: zip.path) else { return nil }
        } catch { return nil }
        return LibraryStore.tracks(in: [zip]).first
    }

    // MARK: - 存档迁移

    private func checkPersistence(_ ctx: SelfTestContext) {
        let p = ctx.player
        let panel = ctx.main.playlistPanel
        p.switchGroup(.main)
        // 上一段收尾时把歌单全删干了：本段自己先建一张再谈存档往返
        if let made = p.createList(named: "存档往返") {
            _ = p.addTracks(Array(p.playlist.tracks.prefix(2)), toList: made.id)
        }
        guard !p.userLists.isEmpty else { ctx.check("歌单-存档前置有歌单", false); return }
        let snap = p.userLists.snapshot
        p.persistNow()
        let saved = LibraryStore.load()
        ctx.check("歌单-存档写入张数与键", saved.userLists == snap,
                  "n=\(saved.userLists.count)")

        p.userLists.restore([])
        ctx.check("歌单-内存清空后左栏只剩一定有的那几页",
                  p.groupLayout.count == GroupKind.alwaysPages.count,
                  "n=\(p.groupLayout.count)")
        p.userLists.restore(saved.userLists)
        ctx.check("歌单-重启后名字与条目都回来",
                  p.userLists.snapshot == snap
                    && p.userLists.items.map { $0.name } == snap.map { $0.name },
                  "names=\(p.userLists.items.map { $0.name })")
        // 切组凭稳定 ID：与 ID 一起存进存档的那个页面还能打开
        let id = snap.first?.id ?? ""
        p.switchGroup(.playlist(id))
        ctx.check("歌单-重启后仍能按 ID 打开那张",
                  p.activeGroup == .playlist(id) && p.playlist.count == p.userLists.keys(of: id).count,
                  "n=\(p.playlist.count)")

        // 退出时停在的那一页也是用户的现场：下次启动还回到这一张。
        // 存的是稳定 ID，所以中间改了名也找得回来（这就是 ID 与名字分开的全部意义）
        ctx.check("歌单-改名不影响按 ID 找回", p.renameList(id: id, to: "重启还在这") == nil)
        p.switchGroup(.playlist(id))
        p.persistNow()
        ctx.check("歌单-存档记下在看的这张", LibraryStore.load().viewListID == id,
                  "id=\(LibraryStore.load().viewListID)")
        p.switchGroup(.main)
        // 把内存里的现场抹干但不写盘：盘上仍是「6 条 [默认] + 停在歌单页」，这才是冷启动的样子
        // （不抹的话上一段留下的可见列表会把旧次序的毛病掩住，测不出真命题）
        p.playlist.removeAll()
        p.restoreFromState()
        ctx.check("歌单-重启后回到在看的这一页",
                  p.activeGroup == .playlist(id) && p.userLists.name(of: id) == "重启还在这",
                  "group=\(p.activeGroup) name=\(p.userLists.name(of: id) ?? "nil")")
        // 停在歌单页重启：存档写的就是 [默认] 那一页的内容，切回去得一条不少。
        // 旧次序先切页再装存档：切页那一刻可见列表还是空的，mainSnapshot 就被当成
        // 「这一页没歌」带走，下一次 persistNow 会把曲库写空（A/B 实测：旧次序回来 0 条）
        let archived = LibraryStore.load().trackPaths
        p.switchGroup(.main)
        let back = Set(p.playlist.tracks.map { $0.identityKey })
        ctx.check("歌单-停在歌单页重启也不冲掉 [默认] 那一页",
                  !archived.isEmpty && archived.allSatisfy { back.contains($0) },
                  "存档 \(archived.count) 条，回来 \(p.playlist.count) 条")
        p.switchGroup(.playlist(id))

        // 存档里那张已经被删掉了：启动只能回 [默认]，不能开出一张无主的空页
        var dangling = LibraryStore.load()
        dangling.viewListID = "已经不存在的ID"
        LibraryStore.save(dangling)
        p.restoreFromState()
        ctx.check("歌单-存档指向已删掉的那张时启动回默认页", p.activeGroup == .main,
                  "group=\(p.activeGroup)")

        // 旧版 state.json 里根本没有这一项：整档要能解开，歌单当空表处理
        let legacyJSON = "{\"trackPaths\":[],\"volume\":0.42}"
        let legacy = try? JSONDecoder().decode(AppState.self, from: Data(legacyJSON.utf8))
        ctx.check("歌单-旧存档缺这一项也能整档解开",
                  legacy?.volume == 0.42 && legacy?.userLists.isEmpty == true
                    && legacy?.viewListID.isEmpty == true,
                  "volume=\(legacy?.volume ?? -1) lists=\(legacy?.userLists.count ?? -1)")

        // 存档/界面指向一张已经被删掉的歌单：回到 [默认]，左栏也不许出现空名字条目
        p.switchGroup(.playlist("已经不存在的ID"))
        ctx.check("歌单-切到不存在的歌单会回默认页", p.activeGroup == .main,
                  "group=\(p.activeGroup)")
        ctx.check("歌单-左栏不出现「歌单已不存在」的空页",
                  panel.groupTitles.allSatisfy { !$0.contains("已不存在") },
                  "titles=\(panel.groupTitles)")
    }
}
