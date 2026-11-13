import Foundation

/// 播放现场（requirements F06）：退出后重启要接着听的那一份状态。
///
/// 为什么单独存一个文件而不是塞进 `AppState`：进度每 5 秒就要落一次盘，
/// 而 `state.json` 是一整份曲库（几千条路径 + 收藏 + 歌单），读出来改一个字段
/// 再整体写回 = 每 5 秒重写整库。「避免频繁整库写盘」只能把它拆出去。
///
/// 里面一律写**稳定身份**，不写下标、不写 Track 对象：
/// - 曲目：`Track.identityKey` 那一套写法（普通文件路径 / `cue路径#track=N` /
///   归档条目 URL / 电台完整地址）
/// - 队列：逐条目写曲目身份 + 排队来路，次序就是数组次序（允许同一首歌出现多次）
/// - 播放历史：条目**在队列里的下标**序列。条目 UUID 跨不了进程，下标序列配合
///   上面那份次序就能原样重建
struct ResumeScene: Codable {
    /// 当前曲目的稳定身份（空 = 上次退出时没有正在播/待播的曲目）
    var trackKey: String = ""
    /// 段内进度（秒）：CUE 分轨是本轨内部的位置，不是镜像的绝对时间；电台恒为 0
    var position: Double = 0
    /// 退出前是否处于播放状态。「启动后自动继续播放」只在这一条为 true 时才自动开播
    var wasPlaying: Bool = false
    /// 队列顺序（逐个条目的曲目身份，允许重复）
    var queueKeys: [String] = []
    /// 与 queueKeys 一一对应：true = 用户显式排进来的（「下一首播放」/「稍后播放」）
    var queueExplicit: [Bool] = []
    /// 与 queueKeys 一一对应：true = 「下一首播放」插进来的那一条（能打断单曲循环）。
    /// 旧档没这一项：那些显式排队的条目只能保守地当「稍后播放」重建，
    /// 宁可少打断一次循环，也不拿 `queueExplicit` 猜回两种语义
    var queueNext: [Bool] = []
    /// 队列当前位置（正在播的那一条在 queueKeys 里的下标）
    var queueIndex: Int = 0
    /// 播放历史：听过的条目下标，最近的在末尾（随机「上一首」沿它回退）
    var historyIndexes: [Int] = []
    /// 当前浏览组（`GroupKind.archiveValue`）；空 = 旧档没这一项，回 [默认]
    var group: String = ""

    // MARK: 宽容解码（与 AppState 同一规矩：缺字段用默认值，不能整档失败）
    private enum CodingKeys: String, CodingKey {
        case trackKey, position, wasPlaying, queueKeys, queueExplicit
        case queueNext, queueIndex, historyIndexes, group
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trackKey = try c.decodeIfPresent(String.self, forKey: .trackKey) ?? ""
        position = try c.decodeIfPresent(Double.self, forKey: .position) ?? 0
        wasPlaying = try c.decodeIfPresent(Bool.self, forKey: .wasPlaying) ?? false
        queueKeys = try c.decodeIfPresent([String].self, forKey: .queueKeys) ?? []
        queueExplicit = try c.decodeIfPresent([Bool].self, forKey: .queueExplicit) ?? []
        queueNext = try c.decodeIfPresent([Bool].self, forKey: .queueNext) ?? []
        queueIndex = try c.decodeIfPresent(Int.self, forKey: .queueIndex) ?? 0
        historyIndexes = try c.decodeIfPresent([Int].self, forKey: .historyIndexes) ?? []
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
    }

    /// 现场里有没有东西可恢复（旧档、或首次运行时是空文件/没文件）
    var isEmpty: Bool { trackKey.isEmpty && queueKeys.isEmpty }

    /// 第 i 条条目的来路：两份标记合成。下标越界与旧档（没 `queueNext`）
    /// 都退到保守答案：当「稍后播放」而不是「下一首播放」
    func source(at i: Int) -> QueueSource {
        if queueNext.indices.contains(i), queueNext[i] { return .next }
        return queueExplicit.indices.contains(i) && queueExplicit[i] ? .later : .basic
    }

    /// 存档字段之间可能互相矛盾（进程被强杀时只写了一半、手工改过文件），
    /// 恢复前一律夹到合法范围，别把越界下标带进队列
    var sanitized: ResumeScene {
        var s = self
        s.position = s.position.isFinite ? max(0, s.position) : 0
        if s.queueIndex < 0 || s.queueIndex >= max(1, s.queueKeys.count) {
            s.queueIndex = min(max(0, s.queueIndex), max(0, s.queueKeys.count - 1))
        }
        s.historyIndexes = s.historyIndexes.filter { $0 >= 0 && $0 < s.queueKeys.count }
        if s.queueExplicit.count != s.queueKeys.count {
            // 长度不匹配时按「都是自动带进来的基础条目」处理，不拿半截数组去对齐
            s.queueExplicit = Array(repeating: false, count: s.queueKeys.count)
        }
        if s.queueNext.count != s.queueKeys.count {
            s.queueNext = Array(repeating: false, count: s.queueKeys.count)
        }
        return s
    }
}
