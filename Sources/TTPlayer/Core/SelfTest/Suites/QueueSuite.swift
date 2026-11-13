import Foundation
import AppKit
import MediaPlayer

/// 待播队列（requirements F03）：条目身份、插队/稍后/重排/移除、四种模式、
/// 随机回退、删除正在播条目、切组/排序/选中不动声音、队列面板交互，
/// 以及整条队列都放不起来时收手。
/// 前两段是纯逻辑，后三段走真实控制器与皮肤窗，所以整个套件需要曲库就位。
struct QueueSuite: SelfTestSuite {
    func run(_ ctx: SelfTestContext) {
        checkQueueIdentity(ctx)
        checkQueueModes(ctx)
        checkControllerQueue(ctx)
        checkPlayingSurvivesListEdits(ctx)
        checkQueuePanelUI(ctx)
        checkAllFail(ctx)
    }

    /// 造几条只有路径的曲目（纯逻辑段不需要文件真存在）
    private func tracks(_ names: [String]) -> [Track] {
        names.map { Track(url: URL(fileURLWithPath: "/tmp/\($0)")) }
    }

    private func paths(_ q: PlayQueue) -> [String] {
        q.pending.map { $0.track.url.lastPathComponent }
    }

    private func paths(_ items: [QueueItem]) -> [String] {
        items.map { $0.track.url.lastPathComponent }
    }

    // MARK: - 条目身份与排队动作

    private func checkQueueIdentity(_ ctx: SelfTestContext) {
        let a = tracks(["a.mp3", "b.mp3", "c.mp3"])
        let q = PlayQueue()
        ctx.check("未建立上下文时队列为空", q.current == nil && q.pendingCount == 0 && q.currentTrack == nil)

        q.begin(a, current: 0)
        ctx.check("双击建立上下文-当前条目", q.currentTrack?.url.lastPathComponent == "a.mp3")
        ctx.check("双击建立上下文-待播是其后两条", paths(q) == ["b.mp3", "c.mp3"], "pending=\(paths(q))")

        // 插队：按传入顺序落在当前曲之后、其他待播之前
        q.insertNext(tracks(["d.mp3", "e.mp3"]))
        ctx.check("下一首播放按显示顺序插到最前", paths(q) == ["d.mp3", "e.mp3", "b.mp3", "c.mp3"],
                  "pending=\(paths(q))")
        // 稍后：追加队尾
        q.appendLater(tracks(["f.mp3"]))
        ctx.check("稍后播放追加队尾", paths(q).last == "f.mp3", "pending=\(paths(q))")

        // 同一首歌重复排队 = 两个条目，身份不同
        let dup = q.pending.first!.track
        q.insertNext([dup])
        let dupIDs = Set(q.pending.filter { $0.track.identityKey == dup.identityKey }.map { $0.id })
        ctx.check("同曲重复排队是两个条目", dupIDs.count == 2, "ids=\(dupIDs.count)")

        // 移除待播：正在播那条形列外
        let curID = q.current!.id
        let pendingIDs = q.pending.map { $0.id }
        q.remove(ids: Set([curID] + Array(pendingIDs[0...1])))
        ctx.check("待播移除不影响正在播条目", q.current?.id == curID)
        ctx.check("待播按身份精确移除",
                  q.pending.map { $0.id } == Array(pendingIDs.dropFirst(2)), "pending=\(paths(q))")

        // 重排：单条拖动落点夹在待播区间；整体重排要求是全排列
        let left = q.pending.map { $0.id }
        let lastSlot = left.count - 1
        ctx.check("待播拖动落点越界就夹住",
                  q.movePending(id: left[0], to: 99) && q.pending.map { $0.id }[lastSlot] == left[0],
                  "pending=\(paths(q))")
        let order = q.pending.map { $0.id }
        ctx.check("整体重排拒绝非全排列", !q.reorderPending(to: Array(order.dropLast())))
        let reversed = Array(order.reversed())
        ctx.check("整体重排按给定顺序生效",
                  q.reorderPending(to: reversed) && q.pending.map { $0.id } == reversed,
                  "pending=\(paths(q))")

        // 清空待播：当前条目保留，播完就收手
        q.clearPending()
        ctx.check("清空待播只留当前条目", q.pendingCount == 0 && q.current?.id == curID && q.count == 1,
                  "count=\(q.count)")

        // 浏览列表删行：同 identityKey 的其他条目一并摘掉，正在播那条形列外
        let x = tracks(["x.mp3"])[0]
        let q2 = PlayQueue()
        q2.begin([x] + tracks(["y.mp3", "z.mp3"]), current: 0)
        q2.appendLater([x])                       // 同一首又排了一次
        let keep = q2.current!.id
        ctx.check("重复排队时条目总数大于曲目数", q2.count == 4, "count=\(q2.count)")
        q2.dropTracks(keys: [x.identityKey])
        ctx.check("删掉正在播那首歌不摘掉当前条目", q2.current?.id == keep
                    && q2.currentTrack?.identityKey == x.identityKey,
                  "cur=\(String(describing: q2.currentTrack?.url.lastPathComponent))")
        ctx.check("删掉正在播那首歌会摘掉重复排队条目",
                  q2.count == 3 && paths(q2) == ["y.mp3", "z.mp3"], "pending=\(paths(q2))")
        ctx.check("删行后游标仍指向原条目", q2.currentIndex == 0)

        q2.reset()
        ctx.check("reset 清空上下文", q2.isEmpty && q2.current == nil && q2.currentIndex == nil)
    }

    // MARK: - 四种播放模式（含显式排队优先级与随机回退）

    private func checkQueueModes(_ ctx: SelfTestContext) {
        let t = tracks(["m1.mp3", "m2.mp3", "m3.mp3"])
        func fresh() -> PlayQueue {
            let q = PlayQueue()
            q.begin(t, current: 0)
            return q
        }

        // 顺序：走到末尾之后收手（手动与自然都一样）
        let order = fresh()
        _ = order.advanceOnFinish(mode: .order)
        _ = order.advanceOnFinish(mode: .order)
        ctx.check("顺序播放-播完列表停止",
                  order.advanceOnFinish(mode: .order) == nil && order.advanceByUser(mode: .order) == nil,
                  "cur=\(String(describing: order.currentTrack?.url.lastPathComponent))")

        // 列表循环：末尾之后回队首，「上一首」在队首环绕到末尾
        let loop = fresh()
        _ = loop.advanceByUser(mode: .listLoop)
        _ = loop.advanceByUser(mode: .listLoop)
        ctx.check("列表循环-末尾回队首",
                  loop.advanceByUser(mode: .listLoop)?.track.url.lastPathComponent == "m1.mp3")
        ctx.check("列表循环-队首往前环绕到末尾",
                  loop.retreat(mode: .listLoop)?.track.url.lastPathComponent == "m3.mp3")

        // 单曲循环：自然播完重播当前曲，手动下一首仍然往前走
        let single = fresh()
        ctx.check("单曲循环-播完重播当前曲",
                  single.advanceOnFinish(mode: .singleLoop)?.track.url.lastPathComponent == "m1.mp3")
        ctx.check("单曲循环-手动下一首可跳过",
                  single.advanceByUser(mode: .singleLoop)?.track.url.lastPathComponent == "m2.mp3")
        _ = single.advanceByUser(mode: .singleLoop)
        ctx.check("单曲循环-末尾手动回到队首",
                  single.advanceByUser(mode: .singleLoop)?.track.url.lastPathComponent == "m1.mp3",
                  "cur=\(String(describing: single.currentTrack?.url.lastPathComponent))")

        // 显式排队优先于模式：「下一首播放」插进来的那条，单曲循环也先轮到它
        let prio = fresh()
        prio.insertNext(tracks(["queued.mp3"]))
        ctx.check("「下一首播放」优先于单曲循环",
                  prio.advanceOnFinish(mode: .singleLoop)?.track.url.lastPathComponent == "queued.mp3",
                  "cur=\(String(describing: prio.currentTrack?.url.lastPathComponent))")
        // 手动「下一首」同样先轮插队那一条
        let prio2 = fresh()
        prio2.insertNext(tracks(["queued.mp3"]))
        ctx.check("手动下一首也先轮插队条目",
                  prio2.advanceByUser(mode: .listLoop)?.track.url.lastPathComponent == "queued.mp3")

        // 「稍后播放」是队尾的一员，不是插队：它前面的基础条目一条都不能被跨过
        // （旧写法拿 explicit 往整个尾部扫，稍后播放会把未播的 m2、m3 永久吞掉）
        let later = fresh()
        later.appendLater(tracks(["queued.mp3"]))
        ctx.check("稍后播放不越过未播的基础条目",
                  paths(later) == ["m2.mp3", "m3.mp3", "queued.mp3"], "pending=\(paths(later))")
        var walked: [String] = []
        while walked.count < 6,
              let n = later.advanceOnFinish(mode: .order) {
            walked.append(n.track.url.lastPathComponent)
        }
        ctx.check("顺序播完不把未播条目吞掉",
                  walked == ["m2.mp3", "m3.mp3", "queued.mp3"]
                    && later.advanceOnFinish(mode: .order) == nil,
                  "walked=\(walked)")
        let later2 = fresh()
        later2.appendLater(tracks(["queued.mp3"]))
        ctx.check("手动下一首按待播显示次序走而不是跳到队尾",
                  later2.advanceByUser(mode: .order)?.track.url.lastPathComponent == "m2.mp3",
                  "cur=\(String(describing: later2.currentTrack?.url.lastPathComponent))")

        // 多曲插队 + 队尾追加混着排：推进次序必须等于面板显示次序
        let mix = fresh()
        mix.insertNext(tracks(["q1.mp3", "q2.mp3"]))
        mix.appendLater(tracks(["tail.mp3"]))
        ctx.check("插队与稍后各按位置生效",
                  paths(mix) == ["q1.mp3", "q2.mp3", "m2.mp3", "m3.mp3", "tail.mp3"],
                  "pending=\(paths(mix))")
        var seq: [String] = []
        while seq.count < 6, let n = mix.advanceOnFinish(mode: .listLoop) {
            seq.append(n.track.url.lastPathComponent)
        }
        ctx.check("列表循环把每一条都播到不落地",
                  seq == ["q1.mp3", "q2.mp3", "m2.mp3", "m3.mp3", "tail.mp3", "m1.mp3"],
                  "seq=\(seq)")
        // 单曲循环只为「插到最前面」的那条破例：追加到队尾的该让当前曲接着循环
        let sl = fresh()
        sl.appendLater(tracks(["queued.mp3"]))
        ctx.check("单曲循环不因稍后播放中断",
                  sl.advanceOnFinish(mode: .singleLoop)?.track.url.lastPathComponent == "m1.mp3",
                  "cur=\(String(describing: sl.currentTrack?.url.lastPathComponent))")
        // 上一例里稍后项落在队尾（m2、m3 还在它前面）；拿共用布尔值判的写法在
        // 「下一位就是它」时两者分不开，这两例把那个重叠面钉死
        let onlyOne = PlayQueue()
        onlyOne.begin(tracks(["only.mp3"]), current: 0)
        onlyOne.appendLater(tracks(["queued.mp3"]))
        ctx.check("单曲循环-上下文只剩一条时稍后播放不打断循环",
                  onlyOne.advanceOnFinish(mode: .singleLoop)?.track.url.lastPathComponent == "only.mp3",
                  "cur=\(String(describing: onlyOne.currentTrack?.url.lastPathComponent)) "
                    + "来路=\(onlyOne.items.map { "\($0.track.url.lastPathComponent):\($0.source)" })")
        let atBaseEnd = PlayQueue()
        atBaseEnd.begin(t, current: 2)                 // 当前曲就在基础序列末尾
        atBaseEnd.appendLater(tracks(["queued.mp3"]))
        ctx.check("单曲循环-基础序列末尾稍后播放不打断循环",
                  atBaseEnd.advanceOnFinish(mode: .singleLoop)?.track.url.lastPathComponent == "m3.mp3",
                  "cur=\(String(describing: atBaseEnd.currentTrack?.url.lastPathComponent))")
        // 拖到待播第一位也只改显示次序，不伪造一次「下一首播放」
        let dragLater = fresh()
        dragLater.appendLater(tracks(["tail.mp3"]))
        let tailID = dragLater.items.last?.id
        let draggedUp = tailID.map { dragLater.movePending(id: $0, to: 1) } == true
        ctx.check("拖到最前面的稍后条目不冒充插队",
                  draggedUp && paths(dragLater) == ["tail.mp3", "m2.mp3", "m3.mp3"]
                    && dragLater.advanceOnFinish(mode: .singleLoop)?.track.url.lastPathComponent == "m1.mp3",
                  "pending=\(paths(dragLater)) 移动成功=\(draggedUp)")
        // 反过来：「下一首播放」那条被拖到队尾就不再是插队（位置 + 来路缺一不可），
        // 但在顺序/列表循环里照常轮到它
        let dragNext = fresh()
        dragNext.insertNext(tracks(["queued.mp3"]))
        let qID = dragNext.items.first(where: { $0.playNext })?.id
        let draggedDown = qID.map { dragNext.movePending(id: $0, to: 99) } == true
        ctx.check("插队那条被拖到队尾后不再打断单曲循环",
                  draggedDown && paths(dragNext) == ["m2.mp3", "m3.mp3", "queued.mp3"]
                    && dragNext.advanceOnFinish(mode: .singleLoop)?.track.url.lastPathComponent == "m1.mp3"
                    && dragNext.advanceOnFinish(mode: .listLoop)?.track.url.lastPathComponent == "m2.mp3",
                  "pending=\(paths(dragNext)) 移动成功=\(draggedDown)")

        // 随机：会换曲子，且「上一首」沿实际播放历史回退
        let rnd = fresh()
        var last = rnd.currentTrack?.url.lastPathComponent ?? ""
        var moved = false
        for _ in 0..<8 {
            let nextName = rnd.advanceOnFinish(mode: .random)?.track.url.lastPathComponent ?? ""
            if nextName != last { moved = true }
            last = nextName
        }
        ctx.check("随机播放-会换曲子", moved, "last=\(last)")

        // 「会换曲子」顺序遍历也能过，所以拿可注入的随机源单独证一次：
        // 摇到 2 就必须是 m3，而不是游标后面的 m2
        let rnd2 = fresh()
        rnd2.randomIndex = { _, _ in 2 }
        ctx.check("随机播放按随机源选曲而不是顺序遍历",
                  rnd2.advanceOnFinish(mode: .random)?.track.url.lastPathComponent == "m3.mp3",
                  "cur=\(String(describing: rnd2.currentTrack?.url.lastPathComponent))")
        // 预取问一次、交接再走一次：同一个随机源必须给同一个答案
        let rnd3 = fresh()
        rnd3.randomIndex = { count, cur in (cur + 2) % count }
        let peeked = rnd3.peekOnFinish(mode: .random)?.track.url.lastPathComponent ?? "nil"
        let taken = rnd3.advanceOnFinish(mode: .random)?.track.url.lastPathComponent ?? "nil"
        ctx.check("随机预取候选与真实交接是同一首",
                  peeked == "m3.mp3" && taken == peeked, "peek=\(peeked) take=\(taken)")
        // 队尾那条「稍后播放」在随机里不当插队使：随机源指哪儿就是哪儿
        let rnd4 = fresh()
        rnd4.appendLater(tracks(["queued.mp3"]))
        rnd4.randomIndex = { _, _ in 1 }
        ctx.check("随机模式不把稍后播放当插队",
                  rnd4.advanceOnFinish(mode: .random)?.track.url.lastPathComponent == "m2.mp3",
                  "cur=\(String(describing: rnd4.currentTrack?.url.lastPathComponent))")
        // 整个上下文只有一条时，随机只能重播它（不越界也不返回 nil）
        let solo = PlayQueue()
        solo.begin(tracks(["only.mp3"]), current: 0)
        ctx.check("随机-单条目上下文只能重播它",
                  solo.advanceOnFinish(mode: .random)?.track.url.lastPathComponent == "only.mp3")

        // 手动「下一首」在随机模式下也照随机源摇：旧写法先无条件吃待播第一位，
        // 实测 30/30 次从 m1 走到 m2，用户听来就是「随机没随机」
        let rUser = fresh()
        rUser.randomIndex = { _, _ in 2 }
        ctx.check("随机-手动下一首照随机源选曲",
                  rUser.advanceByUser(mode: .random)?.track.url.lastPathComponent == "m3.mp3",
                  "cur=\(String(describing: rUser.currentTrack?.url.lastPathComponent))")
        // 但插队那一条仍然优先于随机源（用户点过名）
        let rPrio = fresh()
        rPrio.insertNext(tracks(["queued.mp3"]))
        rPrio.randomIndex = { _, _ in 2 }
        ctx.check("随机-手动下一首先吃插队那条",
                  rPrio.advanceByUser(mode: .random)?.track.url.lastPathComponent == "queued.mp3",
                  "cur=\(String(describing: rPrio.currentTrack?.url.lastPathComponent))")
        // 跳完一步先定选必须作废重算：拿上一游标摇出来的旧答案当预取，
        // 接上的就不是显示的那一曲
        let rPick = fresh()
        rPick.randomIndex = { count, cur in (cur + 1) % count }
        let peekBefore = rPick.peekOnFinish(mode: .random)?.track.url.lastPathComponent ?? "nil"
        let jumpedTo = rPick.advanceByUser(mode: .random)?.track.url.lastPathComponent ?? "nil"
        let peekAfter = rPick.peekOnFinish(mode: .random)?.track.url.lastPathComponent ?? "nil"
        ctx.check("随机-手动下一首之后预取重算",
                  peekBefore == "m2.mp3" && jumpedTo == "m2.mp3" && peekAfter == "m3.mp3",
                  "先定=\(peekBefore) 跳到=\(jumpedTo) 重算=\(peekAfter)")
        // 手动随机跳过去的那一条也算听过：「上一首」能沿历史回到原曲
        let rHist = fresh()
        rHist.markPlayed(rHist.current!)                 // 真播过 m1
        rHist.randomIndex = { _, _ in 2 }
        guard let landed = rHist.advanceByUser(mode: .random) else {
            ctx.check("随机-手动下一首能落地", false); return
        }
        rHist.markPlayed(landed)
        ctx.check("随机-手动跳完上一首回到原曲",
                  landed.track.url.lastPathComponent == "m3.mp3"
                    && rHist.history.count == 2
                    && rHist.retreat(mode: .random)?.track.url.lastPathComponent == "m1.mp3"
                    && rHist.history.count == 1,
                  "hist=\(rHist.history.count) cur=\(String(describing: rHist.currentTrack?.url.lastPathComponent))")

        let hist = fresh()
        hist.markPlayed(hist.current!)                 // 真播过 m1
        _ = hist.advanceOnFinish(mode: .random)
        guard let second = hist.current else {
            ctx.check("随机历史-能推进", false, "nil"); return
        }
        hist.markPlayed(second)                        // 真播过第二条
        ctx.check("随机历史-记了两条", hist.history.count == 2, "n=\(hist.history.count)")
        // 预取不算听过：推进游标但不 markPlayed，历史不该增长
        _ = hist.advanceOnFinish(mode: .random)
        ctx.check("随机历史-未开播不记录", hist.history.count == 2, "n=\(hist.history.count)")
        let back = hist.retreat(mode: .random)
        ctx.check("随机上一首沿历史回退",
                  hist.history.count == 1 && back?.id != second.id,
                  "back=\(String(describing: back?.track.url.lastPathComponent))")
        ctx.check("随机回退到底就停住",
                  hist.retreat(mode: .random)?.track.url.lastPathComponent == "m1.mp3"
                    && hist.history.count == 1)
    }

    // MARK: - 控制器：排队入口与推进

    private func checkControllerQueue(_ ctx: SelfTestContext) {
        let p = ctx.player
        guard p.playlist.count >= 4 else {
            ctx.check("控制器队列-曲库就位", false, "list=\(p.playlist.count)"); return
        }
        ctx.resetLibrary()
        p.setMode(.order)
        let t0 = p.playlist.tracks[0], t1 = p.playlist.tracks[1]
        let t2 = p.playlist.tracks[2], t3 = p.playlist.tracks[3]
        p.play(track: t0)
        _ = ctx.waitUntil(4.0) { p.isPlaying && p.currentTrack != nil }
        ctx.check("起播后队列以列表顺序为上下文",
                  p.queue.count == p.playlist.count && p.queue.currentTrack === t0,
                  "count=\(p.queue.count) list=\(p.playlist.count)")

        // 插队两条，再看「下一首」的去处
        let n = p.playNext([t2, t1])
        ctx.check("playNext 报回排队条数", n == 2 && p.queue.pending.count >= 2,
                  "pending=\(p.queue.pending.count)")
        ctx.check("插队不改变正在播的曲子", p.currentTrack === t0)
        p.next()
        ctx.check("下一首先轮到显式排队的条目", p.currentTrack === t2,
                  "cur=\(p.currentTrack?.fileName ?? "nil")")
        p.next()
        ctx.check("插队第二条接着播（按显示次序）", p.currentTrack === t1,
                  "cur=\(p.currentTrack?.fileName ?? "nil")")

        // 稍后播放追加队尾，不打断当前
        let beforeCur = p.currentTrack
        _ = p.playLater([t3])
        ctx.check("稍后播放不改变当前曲", p.currentTrack === beforeCur)
        ctx.check("稍后播落在队尾", p.queue.pending.last?.track.identityKey == t3.identityKey,
                  "tail=\(p.queue.pending.last?.track.fileName ?? "nil")")

        // 移除待播一条 / 清空待播（都不停止当前曲）
        let leftBefore = p.queue.pending.count
        if let victim = p.queue.pending.first {
            p.removeQueued(ids: [victim.id])
            ctx.check("移除待播少一条", p.queue.pending.count == leftBefore - 1,
                      "pending=\(p.queue.pending.count)")
        }
        p.clearPendingQueue()
        ctx.check("清空待播不停止当前曲", p.queue.pending.isEmpty && p.currentTrack != nil)

        // 队列面板重排走的也是同一个入口
        _ = p.playNext([t3, t2])
        let ids = p.queue.pending.prefix(2).map { $0.id }
        let swapped = [ids[1], ids[0]]
        ctx.check("整体重排经由控制器生效",
                  p.reorderQueued(to: swapped)
                    && p.queue.pending.prefix(2).map { $0.id } == swapped,
                  "pending=\(paths(Array(p.queue.pending.prefix(2))))")
        p.clearPendingQueue()
    }

    // MARK: - 切组、排序、选中、删行都不许动声音

    private func checkPlayingSurvivesListEdits(_ ctx: SelfTestContext) {
        let p = ctx.player
        guard p.playlist.count >= 3 else {
            ctx.check("编辑不影响播放-曲库就位", false, "list=\(p.playlist.count)"); return
        }
        let target = p.playlist.tracks[1]
        p.play(track: target)
        guard ctx.waitUntil(4.0, { p.isPlaying && p.currentTime > 0.1 }) else {
            ctx.check("编辑前真的在播", false, "playing=\(p.isPlaying)"); return
        }
        let expectedPending = p.queue.pending.map { $0.id }
        let startedAt = p.currentTime
        let expectNext = p.queue.pending.first?.track.identityKey

        // 切组：浏览列表整个换掉，声音与队列次序都不动
        p.switchGroup(.favorites)
        ctx.check("切组不改变当前曲", p.currentTrack === target && p.queue.currentTrack === target,
                  "cur=\(p.currentTrack?.fileName ?? "nil")")
        ctx.check("切组不改变待播次序", p.queue.pending.map { $0.id } == expectedPending)
        // 高亮行只是「浏览位置」：这一组里有正在播那首就标它那一行，没有就一行都不标，
        // 唯独不能标到别的行上（那会被读成「现在播的是这首」）。收藏品不固定，
        // 所以只断言「要么没高亮、要么高亮的就是它」，不断言这一组里必然没有它
        let groupSel = p.playlist.currentTrack
        ctx.check("切组后表格不冒充当前曲",
                  groupSel == nil || groupSel?.identityKey == target.identityKey,
                  "sel=\(String(describing: p.playlist.currentIndex)) "
                    + "row=\(groupSel?.fileName ?? "nil")")
        p.switchGroup(.main)

        // 排序：只动浏览列表
        p.playlist.sort(by: .title, ascending: false)
        NotificationCenter.default.post(name: .ttPlaylistChanged, object: nil)
        ctx.pump(0.1)
        ctx.check("排序不改变当前曲", p.currentTrack === target)
        ctx.check("排序不改变待播次序", p.queue.pending.map { $0.id } == expectedPending)

        // 选中另一行（查找/点选）：高亮不等于正在播
        let other = p.playlist.count - 1
        _ = p.playlist.select(other)
        ctx.check("选中别的行不改变当前曲", p.currentTrack === target && p.playlist.currentIndex == other,
                  "cur=\(p.currentTrack?.fileName ?? "nil") row=\(other)")

        // 删掉正在播那一行：继续播完这一曲，不跳曲、不把别的行当成当前曲
        let rowIndex = p.playlist.index(ofKey: target.identityKey) ?? -1
        p.removeTracks(at: IndexSet(integer: rowIndex))
        ctx.pump(0.3)
        ctx.check("删除正在播那行后仍播同一曲", p.currentTrack === target && p.isPlaying,
                  "cur=\(p.currentTrack?.fileName ?? "nil") playing=\(p.isPlaying)")
        ctx.check("删除正在播那行不丢进度", p.currentTime >= startedAt,
                  "t=\(String(format: "%.2f", p.currentTime)) start=\(String(format: "%.2f", startedAt))")
        ctx.check("删除正在播那行后不误标别的行", p.playlist.index(ofKey: target.identityKey) == nil
                    && p.playlist.currentIndex == nil,
                  "sel=\(String(describing: p.playlist.currentIndex))")
        ctx.check("删除正在播那行不跳过下一曲",
                  p.queue.pending.first?.track.identityKey == expectNext,
                  "next=\(p.queue.pending.first?.track.fileName ?? "nil")")

        // 歌词、历史与 Now Playing 都跟着真在播的那首
        ctx.check("歌词以实际播放曲为准",
                  (p.lyric == nil) == !Lyric.exists(for: target.url),
                  "lyric=\(p.lyric == nil ? "nil" : "有") exists=\(Lyric.exists(for: target.url))")
        let npTitle = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
        let wantTitle = target.title.isEmpty ? target.fileName : target.title
        ctx.check("系统 Now Playing 与实际播放同一首", npTitle == nil || npTitle == wantTitle,
                  "np=\(npTitle ?? "nil") want=\(wantTitle)")
        ctx.check("最近播放记的是实际播放曲",
                  p.groups.entries(for: .recent).first == target.identityKey,
                  "recent=\(p.groups.entries(for: .recent).prefix(3))")

        // 「下一首」仍按原上下文轮下去
        p.next()
        _ = ctx.waitUntil(4.0) { p.isPlaying && p.currentTrack !== target }
        ctx.check("删行后下一曲照旧轮到原下一条", p.currentTrack?.identityKey == expectNext,
                  "cur=\(p.currentTrack?.fileName ?? "nil")")
        p.switchGroup(.main)
    }

    // MARK: - 队列面板（可见入口 + 当前曲 + 待播展示 + 拖动/移除/清空/双击）

    private func checkQueuePanelUI(_ ctx: SelfTestContext) {
        let p = ctx.player
        let main = ctx.main
        ctx.resetLibrary()
        guard p.playlist.count >= 5 else {
            ctx.check("队列面板-曲库就位", false, "list=\(p.playlist.count)"); return
        }
        // 入口一：列表面板工具条第九键「队列」
        ctx.check("列表工具条九键齐全（含队列）", main.playlistPanel.toolbarButtonCount == 9,
                  "count=\(main.playlistPanel.toolbarButtonCount)")
        let first = p.playlist.tracks[0]
        p.setMode(.order)
        p.play(track: first)
        _ = ctx.waitUntil(4.0) { p.isPlaying }
        let queued = Array(p.playlist.tracks[3...4])
        _ = p.playNext(queued)
        let pending = p.queue.pending
        // 待播 = 当前曲之后的全部自动上下文 + 显式排进来的那几条（允许与上下文重复）
        ctx.check("排队后面板规模等于剩余上下文",
                  pending.count == p.playlist.count - 1 + queued.count,
                  "pending=\(pending.count) list=\(p.playlist.count) queued=\(queued.count)")
        ctx.check("显式排队条目排在自动序列之前",
                  pending[0].track.identityKey == queued[0].identityKey
                    && pending[1].track.identityKey == queued[1].identityKey,
                  "pending=\(paths(pending).prefix(2))")

        main.toggleQueuePanel()
        ctx.pump(0.15)
        guard let panel = main.queuePanel else {
            ctx.check("队列面板能打开", false, "nil"); return
        }
        ctx.check("队列面板打开", panel.panelVisible && main.queueVisible)
        let wantCaption = first.title.isEmpty ? first.fileName : first.title
        ctx.check("队列面板写出正在播的那首", panel.currentText.contains(wantCaption),
                  "text=\(panel.currentText)")
        ctx.check("队列面板列出全部待播", panel.pendingRowCount == pending.count,
                  "rows=\(panel.pendingRowCount) expect=\(pending.count)")
        ctx.check("待播首行带序号与曲名",
                  panel.firstCellText.hasPrefix("1. ") && !panel.firstCellText.isEmpty,
                  "cell=\(panel.firstCellText)")

        // 拖动重排：把第 3 行拖到第 1 行的位置，其余次序顺移
        let before = pending.map { $0.track.identityKey }
        let expect = [before[2]] + Array(before[0...1]) + Array(before.dropFirst(3))
        ctx.check("面板拖动重排待播",
                  panel.reorderThroughUI(fromRow: 2, toRow: 0)
                    && p.queue.pending.map { $0.track.identityKey } == expect,
                  "order=\(paths(Array(p.queue.pending)).prefix(3))")

        // 双击待播某行 = 从它开始播，且它后面的次序不变
        let tail = Array(p.queue.pending.dropFirst(2)).map { $0.track.identityKey }
        let pick = p.queue.pending[1].track
        panel.playRowThroughUI(1)
        _ = ctx.waitUntil(4.0) { p.currentTrack === pick }
        ctx.check("面板双击待播条目直接播它", p.currentTrack === pick,
                  "cur=\(p.currentTrack?.fileName ?? "nil")")
        ctx.check("面板起播后剩余次序不变",
                  p.queue.pending.map { $0.track.identityKey } == tail,
                  "pending=\(paths(Array(p.queue.pending)).prefix(3))")
        ctx.check("面板起播会同步表格高亮",
                  p.playlist.index(ofKey: pick.identityKey) == p.playlist.currentIndex,
                  "cur=\(String(describing: p.currentTrack?.fileName)) sel=\(String(describing: p.playlist.currentIndex))")

        // 移除选中项 / 清空待播（都不停止当前曲）
        let curBefore = p.currentTrack
        let rowsBefore = p.queue.pending.count
        panel.removeSelectionThroughUI(rows: IndexSet(integer: 0))
        ctx.check("面板移除待播少一条", p.queue.pending.count == rowsBefore - 1
                    && p.currentTrack === curBefore,
                  "pending=\(p.queue.pending.count) cur=\(p.currentTrack?.fileName ?? "nil")")
        panel.clearThroughUI()
        ctx.check("面板清空待播", p.queue.pending.isEmpty && p.currentTrack === curBefore
                    && panel.pendingRowCount == 0 && panel.showsEmptyHint,
                  "pending=\(p.queue.pending.count) hint=\(panel.showsEmptyHint)")
        ctx.check("面板统计文字回到零", panel.infoText.contains("0"), "info=\(panel.infoText)")

        // 入口二：主面板「菜单」里的同名项 —— 关一次再开，验证复用同一块面板
        main.toggleQueuePanel()
        ctx.check("队列面板可以关掉", !panel.panelVisible && !main.queueVisible)
        main.toggleQueuePanel()
        ctx.pump(0.1)
        ctx.check("队列面板再次打开仍是同一块", main.queuePanel === panel && panel.panelVisible)
        main.toggleQueuePanel()
    }

    // MARK: - 整条队列都放不起来

    private func checkAllFail(_ ctx: SelfTestContext) {
        let p = ctx.player
        let fm = ctx.fm
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ttplayer-queue-fail", isDirectory: true)
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var bad: [Track] = []
        for i in 0..<3 {
            let url = dir.appendingPathComponent("bogus\(i).mp3")
            try? "这不是音频".data(using: .utf8)!.write(to: url)
            bad.append(Track(url: url))
        }
        let saved = p.playlist.tracks
        p.clearPlaylist()
        _ = p.addTracks(bad)
        p.setMode(.listLoop)
        p.playRowAt(0)
        ctx.check("全失败队列会收手不再绕圈", !p.isPlaying && p.queue.count == 3,
                  "playing=\(p.isPlaying) count=\(p.queue.count)")
        ctx.check("全失败每条都留有原因",
                  p.playlist.tracks.allSatisfy { $0.decodeProblem != nil },
                  "problems=\(p.playlist.tracks.map { $0.decodeProblem ?? "nil" }.prefix(3))")

        // 同三条再排一次：队列规模比列表行数多，上界也必须算得完
        _ = p.playLater(bad)
        p.next()
        ctx.check("队列比列表长时也照样收手", !p.isPlaying && p.queue.count == 6,
                  "playing=\(p.isPlaying) count=\(p.queue.count)")

        // 用户再手动播一次要能重新尝试（上一次攒下的失败计数不能把这次也拦在外面）
        p.playRowAt(0)
        ctx.check("手动重播重新给一次尝试", p.currentTrack != nil && !p.isPlaying,
                  "cur=\(p.currentTrack?.fileName ?? "nil")")

        p.clearPlaylist()
        p.setMode(.listLoop)
        _ = p.addTracks(saved)
        ctx.check("失败队列测完把曲库恢复回去", p.playlist.count == saved.count, "n=\(p.playlist.count)")
    }
}
