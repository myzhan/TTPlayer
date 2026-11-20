import Foundation

/// 一张自建歌单（requirements F04）。
///
/// `id` 是歌单自己的稳定身份：改名、增删条目、拖动排序都不动它，所以左栏那一行、
/// 存档里记住的当前组、右键「加入歌单」的目标指的都是同一张歌单 —— 拿名字或数组
/// 下标当身份的话，用户改个名就会把引用全散架。
/// 条目只存 `Track.identityKey`（与存档 / 收藏 / 历史同一套写法），曲目对象按需还原。
struct UserPlaylist: Codable, Equatable {
    let id: String
    var name: String
    /// 组内去重，按用户排的次序
    var keys: [String]

    init(id: String = UUID().uuidString, name: String, keys: [String] = []) {
        self.id = id
        self.name = name
        self.keys = Self.dedup(keys)
    }

    /// 组内去重：同一首歌在一张歌单里只占一行（不同歌单之间互不影响）
    static func dedup(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }
}

/// 自建歌单的仓库：可变数量的歌单页，与固定页并列摆在左栏。
/// 这里只管「哪些键属于哪张歌单」，把键还原成曲目是 PlayerController 的事。
final class UserPlaylists {
    static let shared = UserPlaylists()

    /// 名字长度上限：左栏那一列只有 110pt 宽，再长也只是看着像被截断
    static let nameLimit = 40

    private(set) var items: [UserPlaylist] = []

    private init() {}

    // MARK: - 查

    var ids: [String] { items.map { $0.id } }
    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    func item(id: String) -> UserPlaylist? { items.first { $0.id == id } }
    func contains(id: String) -> Bool { item(id: id) != nil }
    func name(of id: String) -> String? { item(id: id)?.name }
    func keys(of id: String) -> [String] { item(id: id)?.keys ?? [] }
    func index(of id: String) -> Int? { items.firstIndex { $0.id == id } }
    func name(at index: Int) -> String? { items.indices.contains(index) ? items[index].name : nil }

    // MARK: - 名字规矩

    // 规矩本体在 `NameRules`：电台分类（F11）与歌单名共用同一份，两处不能各写一套 trim。
    // 这两个转口留着，是因为老代码与自检都按 `UserPlaylists.xxx` 这个名字读它

    /// 见 `NameRules.normalized`
    static func normalized(_ raw: String) -> String { NameRules.normalized(raw) }

    /// 见 `NameRules.distinct`
    static func distinct(_ name: String, taken: Set<String>) -> (name: String, changed: Bool) {
        NameRules.distinct(name, taken: taken)
    }

    // MARK: - 建 / 改名 / 删

    /// 新建歌单。名字空（或只有空白）时不建，返回一句原因；同名自动区分并说明
    /// - Returns: nil = 没建成（附原因）；否则 (歌单 ID, 说明或 nil)
    func create(named raw: String) -> (id: String, note: String?)? {
        let base = String(Self.normalized(raw).prefix(Self.nameLimit))
        guard !base.isEmpty else { return nil }
        let (name, changed) = Self.distinct(base, taken: Set(items.map { $0.name }))
        let list = UserPlaylist(name: name)
        items.append(list)
        let note = changed ? "已经有叫「\(base)」的歌单，这张改名为「\(name)」" : nil
        return (list.id, note)
    }

    /// 重命名：只改显示名，`id` 一个字都不动，所以引用不会散架。
    /// - Returns: nil = 改好了；否则一句原因（空名字）
    /// 同名照样自动区分（把实际用的名字通过日志说清楚）
    @discardableResult
    func rename(id: String, to raw: String) -> String? {
        guard let i = index(of: id) else { return "这张歌单已经不在了" }
        let base = String(Self.normalized(raw).prefix(Self.nameLimit))
        guard !base.isEmpty else { return "歌单名不能是空的" }
        var taken = Set(items.map { $0.name })
        taken.remove(items[i].name)
        let (name, changed) = Self.distinct(base, taken: taken)
        items[i].name = name
        Diagnostics.log(changed ? "歌单改名：「\(base)」已被占用，记作「\(name)」"
                                : "歌单改名 → \(name)")
        return nil
    }

    /// 删除整张歌单：只丢这张歌单的定义与它的键，
    /// 不动 [默认] 列表、收藏、最近播放、待播队列，更不动磁盘上的文件
    @discardableResult
    func delete(id: String) -> UserPlaylist? {
        guard let i = index(of: id) else { return nil }
        return items.remove(at: i)
    }

    // MARK: - 内容

    /// 加入若干键（同一首歌在这一张里只留一行），返回真正新增的条数。
    /// 一次传进来的一批里也可能自带重复（用户框选了两次同一镜像的两条等价引用），
    /// 所以去重要连着这一批一起看，不能只对着旧内容比对
    @discardableResult
    func add(keys newKeys: [String], to id: String) -> Int {
        guard let i = index(of: id) else { return 0 }
        let before = items[i].keys.count
        var seen = Set(items[i].keys)
        for key in newKeys where seen.insert(key).inserted {
            items[i].keys.append(key)
        }
        return items[i].keys.count - before
    }

    /// 按稳定身份移除条目（不影响别的歌单）
    @discardableResult
    func remove(keys gone: Set<String>, from id: String) -> Int {
        guard let i = index(of: id), !gone.isEmpty else { return 0 }
        let before = items[i].keys.count
        items[i].keys.removeAll { gone.contains($0) }
        return before - items[i].keys.count
    }

    /// 清空这一张：只清这一张的条目
    func clear(id: String) {
        guard let i = index(of: id) else { return }
        items[i].keys.removeAll()
    }

    /// 拖动排序：把 `from` 那一段整体挪到「第 `to` 行之前」（NSTableView 的落点口径）
    @discardableResult
    func move(id: String, from: IndexSet, to: Int) -> Bool {
        guard let i = index(of: id) else { return false }
        var keys = items[i].keys
        let moving = from.sorted().compactMap { keys.indices.contains($0) ? keys[$0] : nil }
        guard !moving.isEmpty else { return false }
        keys.removeAll { moving.contains($0) }
        // 摘掉前面的条目后，落点要跟着左移：原来「第 to 行之前」现在少了几行
        let shifted = to - from.filter { $0 < to }.count
        let target = max(0, min(shifted, keys.count))
        keys.insert(contentsOf: moving, at: target)
        items[i].keys = keys
        return true
    }

    /// 整体重排：传入的键序列必须正好覆盖现有条目（不多不少不重），否则什么都不改。
    /// 与队列面板同一套规矩：UI 先按拖完的样子算出新次序，再一次性提交
    @discardableResult
    func reorder(id: String, to order: [String]) -> Bool {
        guard let i = index(of: id) else { return false }
        let current = items[i].keys
        guard order.count == current.count else { return false }
        var pool = current
        var rebuilt: [String] = []
        rebuilt.reserveCapacity(order.count)
        for key in order {
            guard let j = pool.firstIndex(of: key) else { return false }
            rebuilt.append(pool.remove(at: j))
        }
        items[i].keys = rebuilt
        return true
    }

    /// 重新定位（F08）：所有歌单里的旧键换成新键，行次序不动。
    /// 目标位置本来已经在同一张里占了一行（用户把两个目录拼到一起很常见），
    /// 那就并成一行，不能让一张歌单出现两条一模一样的引用
    /// - Returns: 涉及了几张歌单
    @discardableResult
    func replaceKeys(_ map: [String: String]) -> Int {
        guard !map.isEmpty else { return 0 }
        var touched = 0
        for i in items.indices {
            var changed = false
            for j in items[i].keys.indices {
                if let new = map[items[i].keys[j]], new != items[i].keys[j] {
                    items[i].keys[j] = new
                    changed = true
                }
            }
            guard changed else { continue }
            items[i].keys = UserPlaylist.dedup(items[i].keys)
            touched += 1
        }
        return touched
    }

    // MARK: - 存档

    /// 还原存档（旧档没有这一份 = 空表，属正常迁移）。
    /// 宽容处理：丢掉空名字、重复 ID、重复名字（自动区分），组内键去重
    func restore(_ saved: [UserPlaylist]) {
        var seenIDs = Set<String>()
        var seenNames = Set<String>()
        var rebuilt: [UserPlaylist] = []
        for list in saved {
            let name = String(Self.normalized(list.name).prefix(Self.nameLimit))
            guard !name.isEmpty, !list.id.isEmpty, seenIDs.insert(list.id).inserted else { continue }
            let (finalName, changed) = Self.distinct(name, taken: seenNames)
            if changed {
                Diagnostics.log("歌单存档里有重名，「\(name)」记作「\(finalName)」")
            }
            seenNames.insert(finalName)
            rebuilt.append(UserPlaylist(id: list.id, name: finalName, keys: list.keys))
        }
        items = rebuilt
    }

    /// 写进存档的样子
    var snapshot: [UserPlaylist] { items }
}
