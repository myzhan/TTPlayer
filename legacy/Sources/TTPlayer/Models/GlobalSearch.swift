import Foundation

/// 全局搜索的索引与判定（requirements F05：搜索框搜的是整个播放器，不再只是当前那一页）。
///
/// 它只吃「排好页序的曲目列表」，不认识存档、歌单档案、媒体库（那些在 `PlayerController`），
/// 所以「同一个身份出现在好几页时留哪条、命中按什么次序排」这一条规矩能单独被测。
///
/// 三条规矩：
/// 1. **不复制曲目**：索引里存的是各页本来就有的 Track 对象引用。命中表里播它、收藏它、
///    删它，动的都还是原来那一页真的那一条；
/// 2. **只在内容真的变了时重建**：元数据晚到是就地改对象（标题/艺人/专辑都是 `@Atomic`），
///    索引不需要重扫；一万条目录里敲一个字就重建一次索引是能感觉到的卡；
/// 3. **命中次序 = 页序 + 页内序**，同一身份只留第一次出现的那条，但把几页都记下来
///    （列表行末那句「（收藏 · 深夜）」与「删这一行该从哪儿删」都靠它）。
final class GlobalSearch {
    static let shared = GlobalSearch()

    /// 一次给多少条命中：再多不是给人逐行看的，表格重画与「给命中补读标签」也白花钱。
    /// 截断要如实写在标题行里，不能默默少给
    static let resultLimit = 1000

    /// 一条命中：曲目对象 + 这个身份在左栏出现在哪几页（页序，进入搜索的那份次序）
    struct Hit {
        let track: Track
        var pages: [String]
    }

    /// 已按页序去重的索引
    private(set) var rows: [Hit] = []
    /// 索引建过没有（没建过时 `rows` 为空，但那是「还不知道」而不是「什么都没有」）
    private var built = false

    /// 内容变了（加减曲目、改档案、建删歌单、库重扫）：缓存作废，下次搜索前重建
    func invalidate() {
        rows = []
        built = false
    }

    /// 索引建好了没有（自检要确认「搜之前确实把池子建起来了」，而不是拿空表假装搜过）
    var isStale: Bool { !built }

    /// 索引里有多少个不同身份（不是命中数；性能基线用它确认池子就是那批数据）
    var indexedCount: Int { rows.count }

    /// 按页序建索引：同一身份只留第一次出现的那条对象，后面的页只补页名
    func build(_ pages: [(name: String, tracks: [Track])]) {
        var seen: [String: Int] = [:]
        var total = 0
        for page in pages { total += page.tracks.count }
        seen.reserveCapacity(total)
        var out: [Hit] = []
        out.reserveCapacity(total)
        for page in pages {
            for track in page.tracks {
                let key = track.identityKey
                if let i = seen[key] {
                    // 已经记过这个身份：只在页名里补一笔，不再第二条（否则同首歌在
                    // 结果里排两回，用户会以为搜到了两首）
                    if !out[i].pages.contains(page.name) { out[i].pages.append(page.name) }
                    continue
                }
                seen[key] = out.count
                out.append(Hit(track: track, pages: [page.name]))
            }
        }
        rows = out
        built = true
    }

    /// 一次搜索的结果：列得出来的命中、真命中多少条、以及这批命中里有哪些格式档
    struct Found {
        let hits: [Hit]
        let total: Int
        /// 命中里出现过的格式档，**不算格式条件**：搜索态下「格式」菜单得列得出
        /// 换一档以后还能命中的那些 —— 只看已经按档筛过的命中表，永远只剩当前那一档
        let formats: [String]
    }

    /// 搜一遍：命中次序就是索引次序。返回里 `total` 是真命中多少条、`hits` 是
    /// 列得出来的那些（到 `limit` 为止）—— 截断要能如实说出来，就得把全部扫完，
    /// 早停只省下append 那一下，报不出「还有几条没列出」才是真损失
    func matches(_ filter: TrackFilter, limit: Int = GlobalSearch.resultLimit) -> Found {
        // 文本条件单独跑一份判定器：格式档要按「不限格式的全部命中」统计
        let text = TrackFilter(keyword: filter.keywordText, formats: []).matcher()
        // 无条件就不搜：空关键字返回空表，由调用处决定「退出搜索」而不是把全部列出来
        guard !text.isEmpty else { return Found(hits: [], total: 0, formats: []) }
        let onFormats = filter.formats
        var out: [Hit] = []
        var seen = Set<String>()
        var formats: [String] = []
        var total = 0
        for h in rows where text.hit(h.track) {
            if seen.insert(h.track.filterFormat).inserted { formats.append(h.track.filterFormat) }
            guard onFormats.isEmpty || onFormats.contains(h.track.filterFormat) else { continue }
            total += 1
            if out.count < limit { out.append(h) }
        }
        formats.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return Found(hits: out, total: total, formats: formats)
    }

    /// 索引里这个身份都在哪几页（命中表行末的提示用；索引没这条时给空）
    func pages(of key: String) -> [String] {
        rows.first { $0.track.identityKey == key }?.pages ?? []
    }
}
