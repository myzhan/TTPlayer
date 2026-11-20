import Foundation

/// 电台连接质量台账（requirements F11）。
///
/// 需求把话说得很死：连接质量只能用**测得出来**的量解释 —— 节点里已排多久音频（缓冲时长）、
/// 排空了几回（欠载）、重连了几次。码率是这一路流本身的属性，它既不代表网速也不代表音质
/// （64 kbps 的语音台可以比 320 kbps 的音乐台稳得多），所以这本账里一个跟码率有关的数都不出现。
///
/// 时间一律由调用处递进来（`now:`），本结构不读时钟：这样自检能拿一串已知时刻把
/// 窗口进退算清楚，而不是靠「等两秒看看」。
struct RadioQuality {
    /// 统计窗口（秒）：界面上那句「近期」说的就是这个数，不能含糊其辞
    static let windowSeconds = 30.0
    /// 缓冲低于这么多秒就算「缓冲不足」：约等于节点里已经排不满一帧半的声音，
    /// 再抖一下就听得出断（这个水线只用来显示，不算质量分数）
    static let lowBufferSeconds = 0.2

    /// 这本账属于哪一次连接会话（`AudioEngine.radioSession`）。0 = 没在播电台
    private(set) var session = 0
    /// 本次会话累计：欠载（排到没声音）与重连（含自动退避那几次）
    private(set) var totalUnderruns = 0
    private(set) var totalReconnects = 0
    /// 最近一次量到的缓冲时长（秒）
    private(set) var bufferedSeconds = 0.0
    /// 此刻是不是已经见底。一次见底只记一笔，避免每排一块都算一次欠载
    private(set) var starved = false
    private var underrunAt: [Double] = []
    private var reconnectAt: [Double] = []

    /// 开一次新会话（装载这台电台）：上一场的账整本翻页重记。
    /// 自动重连、暂停后又按播放都还在同一场里 —— 用户要看的是「这一次听这个台卡了几回」，
    /// 只有一换台/一停止再装载才算新的一页
    mutating func startSession(_ id: Int) {
        session = id
        totalUnderruns = 0
        totalReconnects = 0
        bufferedSeconds = 0
        starved = false
        underrunAt = []
        reconnectAt = []
    }

    /// 记一次「还排着多少秒没播完」。高于水线就把「见底」这个状态摘掉，
    /// 于是下一次再归零又是一笔新的欠载
    mutating func noteBuffer(seconds: Double, now: Double) {
        bufferedSeconds = max(0, seconds)
        trim(now: now)
        if starved, bufferedSeconds >= Self.lowBufferSeconds { starved = false }
    }

    /// 记一次排空（节点里已经没有排好的音频，而用户还想听）。
    /// 还在见底期间反复调用不会重复计数，所以引擎那边只管在归零那一刻报
    mutating func noteUnderrun(now: Double) {
        guard !starved else { return }
        starved = true
        totalUnderruns += 1
        underrunAt.append(now)
        trim(now: now)
    }

    /// 记一次重连尝试（退避重连、证书降级都算）
    mutating func noteReconnect(now: Double) {
        totalReconnects += 1
        reconnectAt.append(now)
        trim(now: now)
    }

    /// 只留窗口内的事件：界面上「近 30 秒」那几个字得真按 30 秒算，不能拿累计值糊过去
    private mutating func trim(now: Double) {
        let from = now - Self.windowSeconds
        // 两列时间戳都是递增着 append 的，所以过老的一定在头上；removeAll 按条件筛
        // 比 firstIndex + removeFirst 直白，也不用担心「全部过期」那一种边界
        underrunAt.removeAll { $0 <= from }
        reconnectAt.removeAll { $0 <= from }
    }

    func windowUnderruns(now: Double) -> Int {
        underrunAt.filter { $0 > now - Self.windowSeconds }.count
    }

    func windowReconnects(now: Double) -> Int {
        reconnectAt.filter { $0 > now - Self.windowSeconds }.count
    }

    /// 「缓冲不足」该不该说出口：已经见底，或者剩的还不够一个水线
    var isBufferLow: Bool { starved || bufferedSeconds < Self.lowBufferSeconds }

    /// 给用户看的一句：窗口、当前缓冲、本会话累计，三样都点名（需求要求说明统计窗口）
    func summary(now: Double) -> String {
        guard session != 0 else { return "没有正在连的电台" }
        var text = "近 \(Int(Self.windowSeconds)) 秒欠载 \(windowUnderruns(now: now)) 次、"
            + "重连 \(windowReconnects(now: now)) 次；当前缓冲 "
            + String(format: "%.1f", bufferedSeconds) + " 秒"
        if starved { text += "（已经排空，正在等数据）" }
        text += "；本次收听累计欠载 \(totalUnderruns) 次、重连 \(totalReconnects) 次"
        return text
    }
}
