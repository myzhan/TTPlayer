import Foundation

/// 一个电台分类（requirements F11）。
///
/// `id` 是分类的稳定身份：改名、台的进出都不动它 —— 左栏那一行、存档里记住的
/// 「上次在看哪一页」指的都是同一个 id（与 `UserPlaylist` 同一套规矩，
/// 拿名字或下标当身份的话用户改个名就把归属全散架）。
struct RadioCategory: Codable, Equatable {
    let id: String
    var name: String

    init(id: String = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }
}

/// 电台档案（F11）：自定义台名 + 分类 + 台的分类归属。
///
/// 三份档案全部以**电台地址**为键（`Track.identityKey` 那套写法里电台就是完整 URL），
/// 所以：
/// - 同一个地址无论从哪儿进来（手输、m3u、上次存档）都共用这一个台名与这一个归属；
/// - 改了地址就是换了身份，得由 `PlayerController.updateRadioAddress` 显式把设置搬过去，
///   不能靠「名字看着像」偷偷认领（那会把两个不同的台并成一个）。
///
/// 台名与流里 ICY StreamTitle 的「正在播放」是两回事：这里存的才是用户起的名字，
/// ICY 那句只进 `radioNowPlaying` 显示，永远不回写这张表。
final class RadioStations {
    static let shared = RadioStations()

    /// 分类名长度上限：左栏那一列只有 110pt 宽，与歌单同一口径
    static let nameLimit = 40
    /// 自定义台名上限：够写「FM97.4 古典音乐」这种带频率的全名，又不至于顶穿标题区
    static let aliasLimit = 60
    /// 未分类的稳定 id：它不是用户建出来的分类，删不掉，左栏永远有这一行（默认入口）
    static let uncategorizedID = "__uncategorized__"

    /// 用户建的分类，按创建顺序（左栏就按这个次序排）
    private(set) var categories: [RadioCategory] = []
    /// 地址 → 自定义台名。没起过名字的台不在这张表里占位（显示时回落到 host/端口）
    private(set) var aliases: [String: String] = [:]
    /// 地址 → 分类 id。未分类的台不占位：归属为空就是未分类，不用另外维护一张「未分类」的表
    private(set) var assigned: [String: String] = [:]

    private init() {}

    // MARK: - 查

    var ids: [String] { categories.map { $0.id } }
    var count: Int { categories.count }
    var isEmpty: Bool { categories.isEmpty }

    func category(id: String) -> RadioCategory? { categories.first { $0.id == id } }
    func contains(id: String) -> Bool { category(id: id) != nil }
    func name(of id: String) -> String? {
        id == Self.uncategorizedID ? "未分类电台" : category(id: id)?.name
    }
    func index(of id: String) -> Int? { categories.firstIndex { $0.id == id } }

    /// 这个台现在归哪一类（nil = 未分类）。已经不存在的分类 id 一律按未分类算，
    /// 不能让存档里一个被删掉的分类把台藏起来
    func categoryID(of key: String) -> String? {
        let id = assigned[key]
        guard let id, id != Self.uncategorizedID, contains(id: id) else { return nil }
        return id
    }

    /// 这一类里有哪些台（未分类 = 没有归属的那些；调用处负责再把它和「列表里实际有什么」求交，
    /// 这里不知道曲库现场）
    func keys(in id: String) -> [String] {
        assigned.keys.sorted().filter { id == Self.uncategorizedID ? categoryID(of: $0) == nil
                                                                : categoryID(of: $0) == id }
    }

    var unassignedCount: Int { assigned.keys.filter { categoryID(of: $0) == nil }.count }

    func alias(for key: String) -> String? { aliases[key] }

    /// 台名到底是谁给的：用户自定义 > 出厂内置 > 按地址。属性面板与「取消自定义」
    /// 那句提示都要说清这一层，否则用户会以为内置台名也是自己存进去的
    enum NameSource { case custom, builtin, address }

    /// 列表与标题该显示什么：自定义台名优先，其次是内置台自带的名字，都没才按地址认出那段
    func displayName(for url: URL) -> String {
        if let name = aliases[url.absoluteString], !name.isEmpty { return name }
        // 出厂台不占 aliases 那张表：用户没起过名字时也有个能看的台名，
        // 而存档里不会因此多出一条「谁也没写过」的别名
        if let preset = RadioPresets.name(for: url) { return preset }
        return RadioURL.displayName(for: url)
    }

    /// 台名是从哪儿来的（枚举只有三个取值，属性面板与自检按它说人话）
    func nameSource(for url: URL) -> NameSource {
        if hasCustomName(for: url) { return .custom }
        return RadioPresets.name(for: url) == nil ? .address : .builtin
    }

    /// 取消自定义之后会落回哪儿：出厂台落回它自己的内置名，其余落回地址
    func fallbackText(for url: URL) -> String {
        switch nameSource(for: url) {
        case .builtin: return "内置台名「\(RadioPresets.name(for: url) ?? "")」"
        case .custom, .address: return "按地址显示"
        }
    }

    /// 台名是不是用户自己起的（属性面板与自检要说清这一点）
    func hasCustomName(for url: URL) -> Bool {
        aliases[url.absoluteString]?.isEmpty == false
    }

    // MARK: - 台名

    /// 起/改自定义台名。空名字不是错误，是「取消自定义」：落回内置台名或地址，并把这一条从表里摘掉
    /// - Returns: nil = 处理好了；否则一句没改成的原因
    @discardableResult
    func setAlias(key: String, raw: String) -> String? {
        let name = String(NameRules.normalized(raw).prefix(Self.aliasLimit))
        if name.isEmpty {
            aliases[key] = nil
            Diagnostics.log("电台取消自定义台名 \(key)")
            return nil
        }
        aliases[key] = name
        Diagnostics.log("电台台名记在地址上 \(key) → \(name)")
        return nil
    }

    // MARK: - 分类建 / 改名 / 删

    /// 新建分类。名字空（或只有空白）时不建，返回 nil；同名自动区分并说明
    /// - Returns: (新分类 ID, 一句说明或 nil)
    func createCategory(named raw: String) -> (id: String, note: String?)? {
        let base = String(NameRules.normalized(raw).prefix(Self.nameLimit))
        guard !base.isEmpty else { return nil }
        let (name, changed) = NameRules.distinct(base, taken: Set(categories.map { $0.name }))
        let made = RadioCategory(name: name)
        categories.append(made)
        let note = changed ? "已经有叫「\(base)」的分类，这个改名为「\(name)」" : nil
        return (made.id, note)
    }

    /// 重命名分类：只改显示名，`id` 一个字都不动，所以台的归属、左栏那一行、
    /// 存档里记住的页面还是同一件事
    /// - Returns: nil = 改好了；否则一句原因
    @discardableResult
    func renameCategory(id: String, to raw: String) -> String? {
        guard id != Self.uncategorizedID else { return "未分类是默认入口，改不了名字" }
        guard let i = index(of: id) else { return "这个分类已经不在了" }
        let base = String(NameRules.normalized(raw).prefix(Self.nameLimit))
        guard !base.isEmpty else { return "分类名不能是空的" }
        var taken = Set(categories.map { $0.name })
        taken.remove(categories[i].name)
        let (name, changed) = NameRules.distinct(base, taken: taken)
        categories[i].name = name
        Diagnostics.log(changed ? "电台分类改名：「\(base)」已被占用，记作「\(name)」"
                                : "电台分类改名 → \(name)")
        return nil
    }

    /// 删除分类：**只丢分类这个壳**，台一条地址都不删 —— 它们落回未分类（需求里写死的规矩）。
    /// 未分类本身删不掉（它是默认入口）。
    /// - Returns: (被删的分类, 落回未分类的台数)。分类不存在时 (nil, 0)
    func deleteCategory(id: String) -> (gone: RadioCategory?, moved: Int) {
        guard id != Self.uncategorizedID, let i = index(of: id) else { return (nil, 0) }
        let gone = categories.remove(at: i)
        // 归属直接摘掉：留在表里指向一个没有的分类，categoryID 也已经把它算成未分类，
        // 但存档里挂个悬空 id 迟早让人看不懂，不如当场清干净
        let dropped = assigned.keys.filter { assigned[$0] == id }
        for key in dropped { assigned[key] = nil }
        Diagnostics.log("删除电台分类「\(gone.name)」：\(dropped.count) 个台回到未分类，地址与台名都不动")
        return (gone, dropped.count)
    }

    /// 把若干台移进某个分类。`id` 为 nil 或「未分类」= 把归属摘掉（不是删除台）。
    /// 目标分类不存在时一个都不动，返回原因 —— 宁可不动，也不能把台塞进一个看不见的分类里
    /// - Returns: nil = 办好了（返回动了几个）；否则一句原因
    @discardableResult
    func move(keys: [String], to id: String?) -> (moved: Int, problem: String?) {
        guard !keys.isEmpty else { return (0, nil) }
        guard let id, id != Self.uncategorizedID else {
            let hit = keys.filter { assigned[$0] != nil }
            for key in hit { assigned[key] = nil }
            Diagnostics.log(hit.isEmpty ? "这些台本来就在未分类"
                                        : "电台移回未分类 \(hit.count) 个（地址与台名不动）")
            return (hit.count, nil)
        }
        guard contains(id: id) else { return (0, "这个分类已经不在了") }
        for key in keys { assigned[key] = id }
        Diagnostics.log("电台移入分类「\(name(of: id) ?? "")」\(keys.count) 个")
        return (keys.count, nil)
    }

    // MARK: - 身份迁移

    /// 地址换了（F11「编辑地址」）：台名与归属跟着搬新家。
    /// 目标地址本来就有设置时**以新地址那份为准**（那是用户给那个台起的名字），
    /// 旧地址那份随即作废，不留悬空条目
    /// - Returns: 实际搬动了几项设置（台名 + 归属合计）
    @discardableResult
    func replaceKeys(_ map: [String: String]) -> Int {
        guard !map.isEmpty else { return 0 }
        var changed = 0
        for (old, new) in map {
            if let name = aliases.removeValue(forKey: old) {
                if aliases[new] == nil { aliases[new] = name }
                changed += 1
            }
            if let id = assigned.removeValue(forKey: old) {
                if assigned[new] == nil { assigned[new] = id }
                changed += 1
            }
        }
        return changed
    }

    // MARK: - 存档

    /// 还原存档（旧档没有这几项 = 谁都没起过名字，属正常迁移）。
    /// 宽容处理：丢空名字、重复 id、指向不存在分类的归属
    func restore(aliases saved: [String: String], categories savedCats: [RadioCategory],
                 assigned savedAssigned: [String: String]) {
        var seenIDs = Set<String>()
        var seenNames = Set<String>()
        var rebuilt: [RadioCategory] = []
        for cat in savedCats {
            let name = String(NameRules.normalized(cat.name).prefix(Self.nameLimit))
            guard !name.isEmpty, !cat.id.isEmpty, cat.id != Self.uncategorizedID,
                  seenIDs.insert(cat.id).inserted else { continue }
            let (finalName, changed) = NameRules.distinct(name, taken: seenNames)
            if changed { Diagnostics.log("电台分类存档里有重名，「\(name)」记作「\(finalName)」") }
            seenNames.insert(finalName)
            rebuilt.append(RadioCategory(id: cat.id, name: finalName))
        }
        categories = rebuilt
        let live = Set(rebuilt.map { $0.id })
        aliases = [:]
        for (key, raw) in saved {
            let name = String(NameRules.normalized(raw).prefix(Self.aliasLimit))
            // 台名与归属都键在地址上：地址写法不对（空、非 http）一律不收
            guard !name.isEmpty, !key.isEmpty else { continue }
            aliases[key] = name
        }
        assigned = [:]
        for (key, id) in savedAssigned where live.contains(id) && !key.isEmpty {
            assigned[key] = id
        }
    }

    /// 写进存档的样子
    var snapshotAliases: [String: String] { aliases }
    var snapshotCategories: [RadioCategory] { categories }
    var snapshotAssigned: [String: String] { assigned }
}

/// 「名字规矩」只有一个来源：歌单名与电台分类名都要去空白（含全角空格）、截上限、同名自动区分。
/// 两处各写一份的话，用户在歌单里能敲进去的东西到分类里就被拒，说不通
enum NameRules {
    /// 去首尾空白：全角空格（U+3000）不在 `whitespacesAndNewlines` 里，
    /// 但中文用户敲出来的「空格」常常就是它
    static func normalized(_ raw: String) -> String {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: "\u{3000}")
        return raw.trimmingCharacters(in: set)
    }

    /// 同名自动区分：已经有「甲」就用「甲 (2)」，还撞就 (3)……
    /// （需求允许「明确提示或自动区分」两种策略，这里选自动区分：不弹窗打断，
    /// 但把实际用的名字回给调用处显示出来，用户不会以为建了两张同名的）
    static func distinct(_ name: String, taken: Set<String>) -> (name: String, changed: Bool) {
        guard taken.contains(name) else { return (name, false) }
        var n = 2
        while taken.contains("\(name) (\(n))") { n += 1 }
        return ("\(name) (\(n))", true)
    }
}
