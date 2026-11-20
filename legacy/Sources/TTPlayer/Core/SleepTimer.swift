import Foundation

/// 真实经过时间的时钟：`clock_gettime(CLOCK_MONOTONIC)`。
///
/// 为什么是它：睡眠定时器要「从设置起按真实经过时间算」，
/// - 不能用 `Date()`（墙上时钟）：用户改系统时间就能把倒计时拉长或砍短；
/// - 不能用 `DispatchTime.now()` / `CLOCK_UPTIME_RAW`：那把表**不计休眠**，合上盖睡半小时
///   醒来定时器还以为只过了几分钟，会继续补播；
/// - `CLOCK_MONOTONIC` 跨休眠继续累加、也不随系统改表跳变，正是需求那一档。
///
/// 取不到（理论不会）就退回 `systemUptime`：同样不看日历，只是不计休眠。
enum MonotonicClock {
    static var seconds: Double {
        var ts = timespec()
        guard clock_gettime(CLOCK_MONOTONIC, &ts) == 0 else {
            return ProcessInfo.processInfo.systemUptime
        }
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
    }
}

/// 睡眠定时器（F09）：只回答「到没到、还剩多少、此刻该给多少淡出增益」。
/// 什么时候停、要不要作废预取、界面上怎么说，都由 `PlayerController` 决定——
/// 只有它看得见队列与引擎。时钟可注入，短时测试不需要真等十五分钟。
final class SleepTimer {
    enum Plan: Equatable {
        case off
        /// 到点停。`minutes` 是设置时那档分钟数（菜单要勾回同一档、界面要复述）
        case countdown(deadline: Double, minutes: Int)
        /// 播完这一条就停：绑设置那一刻的队列条目 ID，之后队列怎么改都不改主意
        case afterTrack(item: UUID)
    }

    private(set) var plan: Plan = .off
    /// 时钟：自检把它换成一把假表，就能在几毫秒内测完「到期、休眠补算、改表不延长」
    var clock: () -> Double = { MonotonicClock.seconds }
    /// 末尾淡出时长（秒）。0 = 不淡出（用户取消了那个勾选），到点直接停
    var fadeSeconds: Double = 10

    /// 单次定时的上限（分钟）：手滑输入天文数字时给一句人话，而不是存一个走不完的倒计时
    static let maxMinutes = 7 * 24 * 60
    /// 菜单里直接摆出来的三档（需求点名要的那三个），其余走自定义输入
    static let presets = [15, 30, 60]

    var now: Double { clock() }
    var isArmed: Bool { plan != .off }
    /// 是否停在「等当前这曲播完」这一档（电台只能走按时那档）
    var waitingTrack: Bool {
        if case .afterTrack = plan { return true }
        return false
    }
    /// 按分钟那档设置的分钟数（没设或不是按分钟时 nil）
    var minutes: Int? {
        if case .countdown(_, let m) = plan { return m }
        return nil
    }
    /// 还剩几秒。「等播完」那一档没有固定终点，回 nil
    var remaining: Double? {
        guard case .countdown(let deadline, _) = plan else { return nil }
        return max(0, deadline - now)
    }
    /// 到点没有。等播完那一档由「这一条播完了」触发，不看时钟
    var due: Bool {
        guard case .countdown(let deadline, _) = plan else { return false }
        return now >= deadline
    }

    /// 设一档按分钟的定时；返回 nil = 采纳，否则一句不采纳的原因
    func arm(minutes: Int) -> String? {
        guard minutes > 0 else { return "分钟数要是正整数（1 分钟起）" }
        guard minutes <= Self.maxMinutes else {
            return "最长只能定时 \(Self.maxMinutes / 1_440) 天"
        }
        plan = .countdown(deadline: now + Double(minutes) * 60, minutes: minutes)
        return nil
    }

    func armTrack(item: UUID) { plan = .afterTrack(item: item) }

    func cancel() { plan = .off }

    /// 此刻该给输出链路多少增益：1 = 不动音量。
    /// 醒来时早已过点（`left` 为负）就直接给 0——不补播也不补淡，当场停下
    var fadeGain: Float {
        guard case .countdown(let deadline, _) = plan, fadeSeconds > 0 else { return 1 }
        let left = deadline - now
        if left >= fadeSeconds { return 1 }
        return Float(max(0, min(1, left / fadeSeconds)))
    }
    /// 是否已经进了淡出窗口（进去一次就该把下一曲的预取退掉，不必每格都退）
    var inFadeWindow: Bool {
        guard case .countdown(let deadline, _) = plan, fadeSeconds > 0 else { return false }
        return deadline - now <= fadeSeconds
    }

    /// 界面上那一句：`15 分钟定时中，剩余 12:34` / `等「某某」播完就停止` / 空 = 没设
    func statusText(trackTitle: String?) -> String {
        switch plan {
        case .off:
            return ""
        case .countdown(_, let minutes):
            let left = remaining ?? 0
            return "\(minutes) 分钟定时中，还剩 \(TimeFormat.clock(left))"
        case .afterTrack:
            guard let t = trackTitle, !t.isEmpty else { return "等当前这曲播完就停止" }
            return "等「\(Self.clip(t))」播完就停止"
        }
    }

    /// 曲名进句子前剪短：菜单与状态行放不下整段标题
    static func clip(_ s: String, _ cap: Int = 16) -> String {
        s.count <= cap ? s : String(s.prefix(cap)) + "…"
    }
}
