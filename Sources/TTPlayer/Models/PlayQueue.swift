import Foundation

/// 队列条目。
///
/// 同一首歌允许重复排队，所以身份必须挂在**条目**身上：数组下标会随增删漂移，
/// `Track` 对象地址跨不了进程（也不允许拿它当持久化身份），只有 `id` 能稳定指代「这一条」。
/// 曲目本身的身份仍然走 `Track.identityKey`（普通文件 / CUE 分轨 / 归档条目 / 电台各有一套写法）。
/// 条目是怎么进到这段播放上下文里的 —— 三种来路在推进时不等价，所以必须留痕。
/// 不能只拿「是不是用户排的队」这一个共用布尔值再加位置去猜：「稍后播放」追加的那条
/// 一旦恰好坐在当前曲后面（上下文只剩一条、或当前曲就在基础序列末尾），
/// 就与「下一首播放」分不开了
enum QueueSource {
    /// 双击建立上下文时按当时的列表顺序带进来的基础条目
    case basic
    /// 右键「稍后播放」：追加队尾，前面还有未播的曲子就轮到它们后面
    case later
    /// 右键「下一首播放」：用户点名要它接在当前曲之后，
    /// 唯一能打断单曲循环与随机选曲的排法
    case next
}

final class QueueItem {
    let id = UUID()
    /// 曲目对象。`private(set)` 只开一个口子给重新定位用（`reattach`）：
    /// 条目身份是 `id`，换掉这首歌不影响游标与历史
    private(set) var track: Track
    /// 这一条的来路（不可变：拖动重排只改次序，不改「当初是怎么排进来的」）
    let source: QueueSource
    /// true = 用户显式排进来的（「下一首播放」/「稍后播放」），存档与界面按这个讲「排队」
    var explicit: Bool { source != .basic }
    /// true = 「下一首播放」那一条：只有它坐在待播第一位时有权打断当前模式的自动选曲
    var playNext: Bool { source == .next }

    init(track: Track, source: QueueSource) {
        self.track = track
        self.source = source
    }

    /// 重新定位（F08）：条目还是这一条，只是它指的歌曲换了个位置。
    /// 游标、历史、先定选认的都是条目 id，所以这里不能重发新条目
    func reattach(_ newTrack: Track) { track = newTrack }
}

/// 待播队列：与浏览列表相互独立的播放上下文（requirements F03）。
///
/// 三条规矩撑起整个功能：
/// 1. 切组、筛选、排序只动浏览列表，绝不重建这里 —— 声音不能因为用户在看别的列表就变了；
/// 2. 「下一首播放」能打断自动选曲（位置 + 来路两个条件都得上：它就坐在待播第一位，
///    并且确实是 `insertNext` 排进来的），而「稍后播放」只是队尾的一员 —— 拿共用的
///    `explicit` 布尔值加位置判会两种误伤：往尾部扫会把未播的条目跨过去、让它们永久消失，
///    只看下一位会让刚追加的那条打断单曲循环；
///    手动「下一首」可以跳过单曲循环，随机模式下它同样照随机源摇，不退回顺序遍历；
/// 3. 从浏览列表里删掉一行不等于停播：正在播的那条形列外，继续播到结束，下一曲也不跳。
final class PlayQueue {
    private(set) var items: [QueueItem] = []
    /// 正在播的条目下标（nil = 还没建立播放上下文）
    private(set) var cursor: Int?
    /// 真开播过的条目身份，最近的在末尾：随机模式的「上一首」沿这条历史回退。
    /// 预取与失败跳过都不往这里写，所以它记的是「用户听到的顺序」而不是「被选中的顺序」。
    private(set) var history: [UUID] = []
    /// 无缝衔接（F01）先定下来的那一首。随机模式每问一次都会摇一个新结果，
    /// 而「预取的那一曲」与「播完轮到的那一曲」必须是同一首，否则接上的不是显示的、
    /// 显示的不是听见的。所以先定选一次存下来，队列有任何变动就 `invalidatePick()` 重算
    private var prePicked: UUID?

    var current: QueueItem? {
        guard let i = cursor, items.indices.contains(i) else { return nil }
        return items[i]
    }
    var currentTrack: Track? { current?.track }

    /// 待播条目：当前条目之后的那一段。显示、重排、移除都只针对它
    var pending: [QueueItem] {
        guard let c = cursor else { return items }
        return c + 1 < items.count ? Array(items[(c + 1)...]) : []
    }
    var pendingCount: Int { pending.count }
    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    func item(at index: Int) -> QueueItem? { items.indices.contains(index) ? items[index] : nil }
    func index(of id: UUID) -> Int? { items.firstIndex { $0.id == id } }
    /// 正在播的条目在队列里的位置（队列面板要标出「当前」）
    var currentIndex: Int? { cursor }

    // MARK: - 建立与选择

    /// 双击曲目 = 开一段新的播放上下文：以当时的列表顺序作基础序列，旧的待播随之作废
    func begin(_ tracks: [Track], current index: Int) {
        invalidatePick()
        items = tracks.map { QueueItem(track: $0, source: .basic) }
        cursor = items.indices.contains(index) ? index : nil
        history = cursor.map { [items[$0].id] } ?? []
    }

    /// 清空整个上下文（列表被清空时）
    func reset() {
        invalidatePick()
        items.removeAll()
        cursor = nil
        history.removeAll()
    }

    /// 恢复播放现场（F06）：条目次序、当前游标、播放历史照单收下。
    ///
    /// 条目 UUID 只在本进程有意义，所以存档写的是「曲目身份 + 在下标序列里的位置」，
    /// 这里按同一份次序重新发号 —— 同一首歌重复排队的两条因此不会被并成一条。
    /// 越界下标直接夹掉（存档可能被半写、被手改），不拿它去数组外面取条目
    func restoreScene(items newItems: [QueueItem], cursor index: Int?, history indexes: [Int]) {
        invalidatePick()
        items = newItems
        cursor = index.flatMap { $0 >= 0 && $0 < items.count ? $0 : nil }
        guard let cur = cursor else { history = []; return }
        // 历史里指向不存在条目的下标丢掉；重复下标留着（同一首歌听过两次就是听过两次）
        history = indexes.filter { items.indices.contains($0) }.map { items[$0].id }
        // 当前条目必须在历史里（它是「最近听过的那一条」），否则随机「上一首」会少一步
        if history.last != items[cur].id { history.append(items[cur].id) }
    }

    /// 把游标落到某一条（队列面板里直接点某条播）
    @discardableResult
    func focus(id: UUID) -> QueueItem? {
        guard let i = index(of: id) else { return nil }
        invalidatePick()
        cursor = i
        return items[i]
    }

    /// 只查不动：按 id 拿那一条。`focus(id:)` 会挪游标，只想知道「下一候选是哪首」
    /// 之类的场合必须走这一条，不然「看一眼」就把播放上下文换掉了
    func item(id: UUID) -> QueueItem? {
        guard let i = index(of: id) else { return nil }
        return items[i]
    }

    /// 真开播了才记一笔，供随机回退
    func markPlayed(_ item: QueueItem) {
        if history.last != item.id { history.append(item.id) }
    }

    // MARK: - 排队与改队列（都不停止当前曲）

    /// 「下一首播放」：按传入的显示顺序插到当前条目之后、其他待播条目之前
    func insertNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        invalidatePick()
        let newItems = tracks.map { QueueItem(track: $0, source: .next) }
        // 还没建立上下文（没播任何东西）时，插到最前面就是「接下来第一首」
        items.insert(contentsOf: newItems, at: (cursor ?? -1) + 1)
    }

    /// 「稍后播放」：追加队尾
    func appendLater(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        invalidatePick()
        items.append(contentsOf: tracks.map { QueueItem(track: $0, source: .later) })
    }

    /// 按条目身份移除（队列面板的「移除待播」）。
    /// 正在播的那一条删不掉：它不属于待播，删它等于擅自停播
    func remove(ids: Set<UUID>) {
        invalidatePick()
        guard let curID = current?.id else {
            items.removeAll { ids.contains($0.id) }
            return
        }
        items.removeAll { $0.id != curID && ids.contains($0.id) }
        cursor = index(of: curID)
        history.removeAll { id in
            !items.contains { $0.id == id }
        }
    }

    /// 清空待播：只留下已经播过的那一段与正在播的这一条
    func clearPending() {
        invalidatePick()
        guard let c = cursor, items.indices.contains(c) else {
            reset()
            return
        }
        if c + 1 < items.count { items = Array(items[0...c]) }
    }

    /// 拖动调整待播顺序。落点夹在待播区间内：当前条目之前是已播历史，不接受插进去。
    /// 拖动只改显示次序，不改条目的来路：把「稍后播放」那条拖到最前面不会
    /// 伪造出一次「下一首播放」（单曲循环不该因此被打断）
    /// 参数名不能叫 `index`，否则会遮蔽掉同名的 `index(of:)` 方法
    @discardableResult
    func movePending(id: UUID, to position: Int) -> Bool {
        guard let from = index(of: id), let c = cursor, from > c, from < items.count else { return false }
        let clamped = max(c + 1, min(position, items.count - 1))
        guard clamped != from else { return true }
        invalidatePick()
        let item = items.remove(at: from)
        items.insert(item, at: clamped)
        return true
    }

    /// 按给定顺序整体重排待播段。只在传入的 ID 正好覆盖当前待播条目时才生效，
    /// 这样队列面板可以先把行拖成新顺序、再一次性提交，中途条目增删也不会写坏次序
    @discardableResult
    func reorderPending(to order: [UUID]) -> Bool {
        guard let c = cursor, order.count == items.count - c - 1 else { return false }
        let tail = Array(items[(c + 1)...])
        var rebuilt: [QueueItem] = []
        rebuilt.reserveCapacity(order.count)
        for id in order {
            guard let i = tail.firstIndex(where: { $0.id == id }) else { return false }
            rebuilt.append(tail[i])
        }
        invalidatePick()
        items.replaceSubrange((c + 1)..<items.count, with: rebuilt)
        return true
    }

    /// 浏览列表删行：队列里同一首歌的条目一并摘掉，但**正在播的那条形列外**
    /// （继续播到结束，播完再往下走），也不因为少了一条而跳掉下一首。
    /// 按 `identityKey` 匹配：用户在列表里删的是那首歌，重复排队的几条一起走。
    func dropTracks(keys: Set<String>) {
        guard !keys.isEmpty else { return }
        invalidatePick()
        let curID = current?.id
        let curKey = current?.track.identityKey
        items.removeAll {
            keys.contains($0.track.identityKey) && !($0.id == curID && $0.track.identityKey == curKey)
        }
        if let curID { cursor = index(of: curID) }
        history.removeAll { id in !items.contains { $0.id == id } }
    }

    /// 重新定位（F08）：把命中这些键的条目换成新位置的曲目对象。
    /// 只换曲目不换条目：正在播的那一条不会因为「文件找到了」就被归到队列末尾，
    /// 同一首歌重复排队的几条也各自对上号
    /// - Parameters:
    ///   - map: 旧键 → 新键
    ///   - resolve: 新键 → 曲目对象（解不开也要返回一条失效占位，不能让条目消失）
    /// - Returns: 换掉了几条
    @discardableResult
    func replaceTracks(_ map: [String: String], resolve: (String) -> Track) -> Int {
        guard !map.isEmpty else { return 0 }
        invalidatePick()
        var n = 0
        for item in items {
            guard let newKey = map[item.track.identityKey] else { continue }
            item.reattach(resolve(newKey))
            n += 1
        }
        return n
    }

    // MARK: - 接下来播谁

    /// 手动「下一首」：无论如何往前走一步，所以单曲循环也能被跳过去。
    /// 排在待播第一位的是「下一首播放」插进来的那条时先吃它（用户点过名）；
    /// 随机模式下这一跳也照随机源摇——点了「下一首」还按显示次序走，
    /// 在用户听来就是「随机根本没随机」；其余情形吃待播显示次序的第一条
    func advanceByUser(mode: PlayMode) -> QueueItem? {
        defer { invalidatePick() }
        if let next = nextPendingItem(), next.playNext { return focus(item: next) }
        if mode == .random, let pick = randomPeek() { return focus(item: pick) }
        if let next = nextPendingItem() { return focus(item: next) }
        // 到了末尾：单曲循环也不能把手动「下一首」变成原地重播（那等于按了没反应），
        // 回到队首接着走；整个上下文只有一条时才只能重播它
        if mode == .singleLoop, items.count > 1, let first = items.first { return focus(item: first) }
        return tailItem(mode: mode)
    }

    /// 一整曲播完后的自然推进。
    /// 排在待播第一位、且是「下一首播放」插进来的那条优先于自动选曲；
    /// 单曲循环只在有人插到最前面时才破例，否则原地重播。
    /// 先定好的那一首（`peekOnFinish` 存下的）算数：预取到节点里的就是它，
    /// 这里再算一次会接上另一首（随机模式尤其明显）
    func advanceOnFinish(mode: PlayMode) -> QueueItem? {
        let picked: QueueItem?
        if let id = prePicked, let item = item(whereID: id) {
            picked = item
        } else {
            picked = nextOnFinish(mode: mode)
        }
        prePicked = nil
        guard let item = picked else { return nil }
        return focus(item: item)
    }

    /// 「假如现在就自然播完，接下来轮到哪一条」：只算不动游标、不记历史（F01 预取用）。
    /// 算出来就存下，让「预取的那一曲」与「播完轮到的那一曲」是同一个答案
    func peekOnFinish(mode: PlayMode) -> QueueItem? {
        if let id = prePicked, let item = item(whereID: id) { return item }
        let item = nextOnFinish(mode: mode)
        prePicked = item?.id
        return item
    }

    /// 作废先定选的那一首（队列、模式、游标任一处变了都要叫）
    func invalidatePick() { prePicked = nil }

    /// 无缝交接落地：把游标移到已经出声的那一条。同一条歌重复排队时取待播里的第一条
    /// （预取拿的就是它）；找不到就算了，由控制层退回硬切
    @discardableResult
    func confirmHandover(forKey key: String) -> QueueItem? {
        guard let item = items.dropFirst((cursor ?? -1) + 1).first(where: { $0.track.identityKey == key })
            ?? items.first(where: { $0.track.identityKey == key }) else { return nil }
        prePicked = nil
        return focus(item: item)
    }

    /// 纯算「播完之后轮到谁」，不碰游标也不记历史：预取与推进共用这一套规矩，
    /// 免得两条路算出两个答案。
    /// 坐在待播第一位、且确实是「下一首播放」插进来的那条先吃（位置 + 来路缺一不可）；
    /// 「稍后播放」追加到队尾的那条只能等前面的播完 —— 不能拿 `explicit` 往尾部扫，
    /// 否则被跨过的中间条目会永久消失；也不能只看下一位，
    /// 否则上下文只剩一条时刚追加的那条会把单曲循环打断。
    /// 随机模式不看位置，只认摇出来的结果（否则「随机」实际变成顺序遍历）
    private func nextOnFinish(mode: PlayMode) -> QueueItem? {
        if let next = nextPendingItem(), next.playNext { return next }
        switch mode {
        case .random:
            return randomPeek()
        case .singleLoop:
            return current
        case .order:
            return nextPendingItem()
        case .listLoop:
            return nextPendingItem() ?? items.first
        }
    }

    /// 待播段里的下一条：游标之后的第一条（还没建立上下文时就是队首）。
    /// 「下一首播放」插进来的那条就坐在这个位置 —— 位置即优先级
    private func nextPendingItem() -> QueueItem? {
        if let c = cursor { return items.indices.contains(c + 1) ? items[c + 1] : nil }
        return items.first
    }

    /// 「上一首」：随机模式沿实际播放历史回退，其余按队列次序
    func retreat(mode: PlayMode) -> QueueItem? {
        defer { invalidatePick() }
        if mode == .random, history.count >= 2 {
            history.removeLast()
            if let prev = history.last, let item = item(whereID: prev) {
                cursor = index(of: prev)
                return item
            }
        }
        if let c = cursor, c > 0 { return focus(item: items[c - 1]) }
        if mode == .listLoop, let last = items.last { return focus(item: last) }
        return current
    }

    private func item(whereID id: UUID) -> QueueItem? { items.first(where: { $0.id == id }) }

    @discardableResult
    private func focus(item: QueueItem) -> QueueItem? {
        guard let i = index(of: item.id) else { return nil }
        cursor = i
        return items[i]
    }

    /// 走到队列末尾之后该怎么办：手动「下一首」那一路照旧（它不适用先定选），
    /// 随机那一路复用 `randomPeek`，免得两处摇出两个结果
    private func tailItem(mode: PlayMode) -> QueueItem? {
        switch mode {
        case .order: return nil
        case .listLoop:
            guard let first = items.first else { return nil }
            return focus(item: first)
        case .singleLoop: return current
        case .random:
            guard let item = randomPeek() else { return nil }
            return focus(item: item)
        }
    }

    /// 随机数的来源。自检把它换成固定答案，好断言「随机真的走随机而不是顺序遍历」；
    /// 默认实现尽量避免连着抽到同一首（试 16 次仍撞上就接受，随机本来就有这一天）
    var randomIndex: (_ count: Int, _ cursor: Int) -> Int = { count, cur in
        var pick = Int.random(in: 0..<count)
        var tries = 0
        while pick == cur && tries < 16 {
            pick = Int.random(in: 0..<count)
            tries += 1
        }
        return pick
    }

    /// 随机挑一条（不移动游标）：整个上下文只有一条时只能重播它
    private func randomPeek() -> QueueItem? {
        guard !items.isEmpty else { return nil }
        guard items.count > 1 else { return items[0] }
        let pick = randomIndex(items.count, cursor ?? -1)
        return items.indices.contains(pick) ? items[pick] : items[0]
    }
}
