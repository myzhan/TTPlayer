import AppKit
import AVFoundation
import Foundation

/// F09 睡眠定时器（15/30/60/自定义分钟 + 播完当前曲 + 到点淡出）。
///
/// 时间这一侧全部走**注入的假表**：`SleepTimer.clock` 换成套件自己推进的读数，
/// 「过了一小时」「合上盖子睡到明天」这类前提几毫秒就能摆出来，不必真等，也不会因为
/// 机器卡顿飘成偶发失败。声音那一侧仍是真实链路：淡出落在 fadeNode，
/// 只能从这一层取流才量得到衰减（`captureLeftChannel` 那个 tap 在 playerNode，是淡出上游）。
///
/// 「播完当前曲」与无缝预取的冲突是这套的核心风险：下一曲早就排进流里了，
/// 到点/播完那一刻引擎会自己接上，用户听到的就是「说好了停止怎么还有歌」。
/// 所以每条停止路径都先撤预取，并且拿 `nextPreparedKey` 当场对账。
final class SleepSuite: SelfTestSuite {
    /// 假表当前读数（秒）：套件推进它，被测对象只认这一把表
    private var fakeNow = 0.0
    /// 采到的电平高于这个数才算「真出声了」
    private static let audibleRMS = 0.0005
    /// 淡出档位：还剩几秒 → 期望增益。12 秒那档在窗口外（不动音量），0.4 秒那档已接近无声
    private static let fadeSteps: [(left: Double, want: Float)] = [(12, 1), (5, 0.5), (2, 0.2), (0.4, 0.04)]

    /// 跑之前记下全局状态，跑完原样还回去：计划、音量、模式、列表都不能留在自检的样子上
    private struct Snapshot {
        let volume: Float
        let muted: Bool
        let playMode: PlayMode
        let gapless: Bool
        let fadeEnabled: Bool
        let fadeSeconds: Double
    }

    // MARK: - 入口

    func run(_ ctx: SelfTestContext) {
        let p = ctx.player
        let keep = Snapshot(volume: p.volume, muted: p.isMuted, playMode: p.playMode,
                            gapless: p.gaplessPlay, fadeEnabled: p.sleepFadeEnabled,
                            fadeSeconds: p.sleepTimer.fadeSeconds)
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ttplayer-sleep", isDirectory: true)
        try? ctx.fm.removeItem(at: root)
        try? ctx.fm.createDirectory(at: root, withIntermediateDirectories: true)
        guard let files = makeMaterial(ctx, root: root) else {
            ctx.check("定时-素材能造出来", false, "写 WAV 失败：\(root.path)")
            return
        }
        checkPlan(ctx)
        checkClockChoice(ctx, p: p)
        checkMenu(ctx, p: p)
        checkAfterTrack(ctx, p: p, files: files)
        checkCountdown(ctx, p: p, files: files)
        checkFadeChain(ctx, p: p, files: files)
        checkRadioAndArchive(ctx, p: p)
        cleanup(ctx, p: p, keep: keep, root: root)
    }

    /// 三种素材：两秒（够验「播完就停」又不用等）、二十秒（够摆预取与取消）、
    /// 四十秒恒幅正弦（淡出要一段稳定的声音量比值：阶梯音每换一频都有一个台阶，会污染 RMS）
    private func makeMaterial(_ ctx: SelfTestContext, root: URL) -> (short: URL, mid: URL, long: URL)? {
        let short = root.appendingPathComponent("sleep_short.wav")
        let mid = root.appendingPathComponent("sleep_mid.wav")
        let long = root.appendingPathComponent("sleep_long.wav")
        // stepFreq 0 + blockSeconds 60：全程一个音高一个幅度，RMS 只可能被淡出改掉
        guard ctx.writeStepWave(short, seconds: 2, baseFreq: 440, stepFreq: 0, blockSeconds: 60),
              ctx.writeStepWave(mid, seconds: 20, baseFreq: 440, stepFreq: 0, blockSeconds: 60),
              ctx.writeStepWave(long, seconds: 40, baseFreq: 440, stepFreq: 0, blockSeconds: 60)
        else { return nil }
        return (short, mid, long)
    }

    // MARK: - 纯逻辑：档位、校验、淡出曲线

    private func checkPlan(_ ctx: SelfTestContext) {
        let t = SleepTimer()
        var now = 1_000.0
        t.clock = { now }
        ctx.check("定时-初始没设档", !t.isArmed && t.remaining == nil && !t.due
                          && t.fadeGain == 1 && t.statusText(trackTitle: "x").isEmpty)
        ctx.check("定时-0 分钟被拒", t.arm(minutes: 0) != nil && !t.isArmed)
        ctx.check("定时-负数分钟被拒", t.arm(minutes: -5) != nil && !t.isArmed)
        ctx.check("定时-超上限被拒并给出一句人话",
                  (t.arm(minutes: SleepTimer.maxMinutes + 1) ?? "").contains("天") && !t.isArmed)
        ctx.check("定时-上限本身采纳",
                  t.arm(minutes: SleepTimer.maxMinutes) == nil && t.minutes == SleepTimer.maxMinutes)
        _ = t.arm(minutes: 15)
        ctx.check("定时-15 分钟就是 900 秒", t.minutes == 15 && t.remaining == 900,
                  "left=\(t.remaining ?? -1)")
        now += 600
        ctx.check("定时-只认注入的时钟", abs((t.remaining ?? 0) - 300) < 0.001,
                  "left=\(t.remaining ?? 0)")
        ctx.check("定时-没到点不算 due", !t.due)
        let end: Double = 1_000 + 15 * 60        // 上面那一档的终点（1900）
        now = end - 11
        ctx.check("定时-窗口外不淡出", !t.inFadeWindow && t.fadeGain == 1)
        now = end - 10
        ctx.check("定时-进窗口那一点就开始淡", t.inFadeWindow && t.fadeGain == 1, "g=\(t.fadeGain)")
        now = end - 5
        ctx.check("定时-半程增益一半", abs(t.fadeGain - 0.5) < 1e-6, "g=\(t.fadeGain)")
        now = end - 1
        ctx.check("定时-末秒接近无声但还没到", t.fadeGain > 0 && t.fadeGain < 0.12 && !t.due,
                  "g=\(t.fadeGain)")
        now = end + 30
        ctx.check("定时-早就过点：直接无声不补淡", t.due && t.fadeGain == 0)
        t.fadeSeconds = 0
        now = end - 1
        ctx.check("定时-关掉淡出后不预降音量", !t.inFadeWindow && t.fadeGain == 1)
        t.fadeSeconds = 10
        now = 1_000
        _ = t.arm(minutes: 15)
        let line = t.statusText(trackTitle: "测试曲")
        ctx.check("定时-状态句报分钟与剩余", line.contains("15 分钟") && line.contains("15:00"), line)
        now += 1
        ctx.check("定时-状态句跟着表走", t.statusText(trackTitle: "测试曲").contains("14:59"),
                  t.statusText(trackTitle: "测试曲"))
        t.armTrack(item: UUID())
        ctx.check("定时-等播完那档没有剩余秒数",
                  t.waitingTrack && t.remaining == nil && !t.due && t.fadeGain == 1)
        ctx.check("定时-等播完要说出是哪一首", t.statusText(trackTitle: "深夜电台").contains("深夜电台"),
                  t.statusText(trackTitle: "深夜电台"))
        ctx.check("定时-曲名太长要剪短",
                  t.statusText(trackTitle: String(repeating: "长", count: 30)).contains("…"),
                  t.statusText(trackTitle: String(repeating: "长", count: 30)))
        ctx.check("定时-没有当前曲目也说得出在等什么", t.statusText(trackTitle: nil).contains("当前这曲"),
                  t.statusText(trackTitle: nil))
        t.cancel()
        ctx.check("定时-取消后一切归零", !t.isArmed && !t.waitingTrack && t.minutes == nil)
        // 设一档会顶掉另一档：不能同时既等播完又按分钟倒数
        t.armTrack(item: UUID())
        _ = t.arm(minutes: 30)
        ctx.check("定时-两档计划互斥", t.minutes == 30 && !t.waitingTrack)
        t.cancel()
    }

    // MARK: - 时钟口径：按真实经过时间、不看日历

    private func checkClockChoice(_ ctx: SelfTestContext, p: PlayerController) {
        let a = MonotonicClock.seconds
        ctx.check("定时-时钟单调不减", MonotonicClock.seconds >= a, "a=\(a) b=\(MonotonicClock.seconds)")
        // 墙上时钟是纪元秒（十七亿量级），这把表是开机以来的秒数（机器开上千天也够不着）：
        // 差一个数量级以上就说明没拿 Date() 计时，用户改系统时间动不了倒计时
        let wall = Date().timeIntervalSince1970
        ctx.check("定时-不用墙上时钟（改表不延长）", a > 0 && a * 20 < wall,
                  "mono=\(Int(a)) wall=\(Int(wall))")
        // 跨休眠必须计入，否则醒来会继续补播。`CLOCK_UPTIME_RAW` 与它是同一把表减去休眠时长，
        // 真表只能 ≥ 它（本机今天没法真睡一小时，这里钉的是「用的不是那把不计休眠的表」）
        var raw = timespec()
        clock_gettime(CLOCK_UPTIME_RAW, &raw)
        let up = Double(raw.tv_sec) + Double(raw.tv_nsec) / 1_000_000_000
        ctx.check("定时-这把表计入了休眠时间", a >= up - 0.5,
                  "monotonic=\(Int(a)) uptime_raw=\(Int(up)) 差=\(String(format: "%.1f", a - up))s")
        ctx.check("定时-控制层默认接的就是这把真表", abs(p.sleepTimer.now - a) < 5,
                  "注入=\(p.sleepTimer.now) 真表=\(a)")
    }

    // MARK: - 菜单与状态行

    private func checkMenu(_ ctx: SelfTestContext, p: PlayerController) {
        func sub() -> NSMenu { ctx.main.buildSleepTimerItem().submenu! }
        func row(_ prefix: String) -> NSMenuItem? { sub().items.first { $0.title.hasPrefix(prefix) } }
        func preset(_ m: Int) -> NSMenuItem? { row("\(m) 分钟后停止") }

        p.cancelSleepTimer()
        let item = ctx.main.buildSleepTimerItem()
        ctx.check("定时-菜单里有这一支", item.title == "睡眠定时器" && item.submenu != nil)
        ctx.check("定时-未设档时状态行说未设置", sub().items.first?.title == "未设置定时",
                  "first=\(sub().items.first?.title ?? "nil")")
        ctx.check("定时-三档预设都在", SleepTimer.presets.allSatisfy { preset($0) != nil })
        ctx.check("定时-未设档时取消不可点", row("取消定时")?.isEnabled == false)
        ctx.check("定时-未设档时三档都没打勾",
                  SleepTimer.presets.allSatisfy { preset($0)?.state == .off })
        ctx.check("定时-淡出行的勾跟着设置",
                  row("到点前")?.state == (p.sleepFadeEnabled ? NSControl.StateValue.on : .off))
        // 走一遍真实入口：菜单项自己校验、自己打勾
        let tap = NSMenuItem(title: "15 分钟后停止", action: nil, keyEquivalent: "")
        tap.tag = 15
        ctx.main.selectSleepMinutes(tap)
        ctx.check("定时-点菜单项就设上了", p.sleepTimer.minutes == 15,
                  "min=\(p.sleepTimer.minutes ?? -1)")
        ctx.check("定时-设上的那一档打勾",
                  preset(15)?.state == .on && preset(30)?.state == .off)
        ctx.check("定时-设完就能取消", row("取消定时")?.isEnabled == true)
        let statusRow = sub().items.first { $0.title.contains("定时中") }
        // 具体剩几秒取决于菜单是设完多久后建的，只钉那句固定的开头
        ctx.check("定时-状态行报出分钟与剩余",
                  statusRow?.title.contains("15 分钟定时中，还剩") == true, statusRow?.title ?? "nil")
        ctx.check("定时-状态行后缀跟上", ctx.main.displayPanel.statusText.contains("剩 "),
                  ctx.main.displayPanel.statusText)
        // 自定义那一步的判据（弹框只负责收字符串，规则在这一条路上）
        ctx.check("定时-自定义挡下字母", (p.applyCustomSleepMinutes("abc") ?? "").contains("正整数"))
        ctx.check("定时-自定义挡下 0", (p.applyCustomSleepMinutes("0") ?? "").contains("正整数"))
        ctx.check("定时-自定义挡下负数", (p.applyCustomSleepMinutes("-3") ?? "").contains("正整数"))
        ctx.check("定时-自定义挡下小数", (p.applyCustomSleepMinutes("1.5") ?? "").contains("正整数"))
        ctx.check("定时-自定义挡下空白", (p.applyCustomSleepMinutes("   ") ?? "").contains("不能为空"))
        ctx.check("定时-自定义收下 45（带空白也算）",
                  p.applyCustomSleepMinutes(" 45 ") == nil && p.sleepTimer.minutes == 45,
                  "min=\(p.sleepTimer.minutes ?? -1)")
        // 淡出开关翻面再翻回来：0 秒就是不淡出
        ctx.main.toggleSleepFade()
        ctx.check("定时-关掉淡出后系数为 0", p.sleepTimer.fadeSeconds == 0 && !p.sleepFadeEnabled)
        ctx.main.toggleSleepFade()
        ctx.check("定时-淡出开关能翻回默认",
                  p.sleepFadeEnabled && p.sleepTimer.fadeSeconds == PlayerController.sleepFadeSeconds)
        ctx.check("定时-默认淡出十秒", PlayerController.sleepFadeSeconds == 10)
        ctx.main.cancelSleepTimer()
        ctx.check("定时-点取消就收摊", !p.sleepTimer.isArmed
                          && (p.sleepNote ?? "").contains("取消"), p.sleepNote ?? "nil")
        ctx.check("定时-取消后状态行不再缀剩余", !ctx.main.displayPanel.statusText.contains("剩 "),
                  ctx.main.displayPanel.statusText)
        ctx.check("定时-取消过的那一轮在菜单里留一句话",
                  sub().items.contains { $0.title.contains("上一次：") },
                  sub().items.map(\.title).joined(separator: "|"))
    }

    // MARK: - 播完当前曲

    private func checkAfterTrack(_ ctx: SelfTestContext, p: PlayerController,
                                 files: (short: URL, mid: URL, long: URL)) {
        let wasGapless = p.gaplessPlay
        p.setGaplessPlay(true)      // 这一组验的就是「预取排在流里也要停得住」
        p.setMode(.listLoop)

        // ① 设上就该把排好的下一曲撤掉，取消后要补回来
        play(ctx, p, [files.mid, files.long], at: 0)
        let prepared = ctx.waitUntil(8) { !p.nextPreparedKey.isEmpty }
        ctx.check("定时-下一曲真的排进了流里", prepared, "key=\(p.nextPreparedKey)")
        ctx.check("定时-播完当前曲被采纳", p.setSleepAfterCurrentTrack() == nil)
        ctx.check("定时-设上当场撤预取", p.nextPreparedKey.isEmpty && p.engine.nextPreparedKey.isEmpty,
                  "key=\(p.engine.nextPreparedKey)")
        ctx.check("定时-状态句说在等哪一首", p.sleepStatusText.contains("播完就停止"), p.sleepStatusText)
        ctx.check("定时-等播完这一档不缀剩余秒数", ctx.main.displayPanel.statusText.contains("播完停"),
                  ctx.main.displayPanel.statusText)
        p.cancelSleepTimer()
        ctx.check("定时-取消后预取补回来", ctx.waitUntil(8) { !p.nextPreparedKey.isEmpty },
                  "key=\(p.nextPreparedKey)")
        p.stop()

        // ② 绑定的那一条播完就停，且不推进到下一曲
        play(ctx, p, [files.short, files.long], at: 0)
        let bound = p.queue.current?.id
        _ = p.setSleepAfterCurrentTrack()
        let stopped = ctx.waitUntil(12) { !p.isPlaying }
        ctx.check("定时-播完就停（真停了）", stopped && p.queue.current?.id == bound,
                  "playing=\(p.isPlaying)")
        ctx.check("定时-收场原因写的是等的那一曲", (p.sleepNote ?? "").contains("播完"),
                  p.sleepNote ?? "nil")
        ctx.check("定时-停下后队列没往前走", p.currentTrack?.url == files.short,
                  "now=\(p.currentTrack?.url.lastPathComponent ?? "nil")")
        ctx.check("定时-停下后没有残值留在链路上",
                  p.engine.sleepFadeVolume == 1 && p.engine.fadeNodeVolume == 1,
                  "sleep=\(p.engine.sleepFadeVolume) fade=\(p.engine.fadeNodeVolume)")

        // ③ 单曲循环：也在本轮结束停，不能循环到地老天荒
        p.setMode(.singleLoop)
        play(ctx, p, [files.short, files.long], at: 0)
        _ = p.setSleepAfterCurrentTrack()
        let stoppedLoop = ctx.waitUntil(12) { !p.isPlaying }
        ctx.check("定时-单曲循环也在本轮停", stoppedLoop)
        ctx.pump(1.5)
        ctx.check("定时-停下之后不会自己又响", !p.isPlaying, "playing=\(p.isPlaying)")
        p.setMode(.listLoop)

        // ④ 手动跳离：计划作废（不是「改等下一曲播完」）
        play(ctx, p, [files.mid, files.long], at: 0)
        _ = p.setSleepAfterCurrentTrack()
        let armed = p.queue.current?.id
        ctx.check("定时-跳曲前确实绑着", p.sleepTimer.waitingTrack)
        p.next()
        ctx.check("定时-手动跳曲即取消计划", ctx.waitUntil(3) { !p.sleepTimer.isArmed },
                  "armed=\(p.sleepTimer.isArmed)")
        ctx.check("定时-取消时说清楚为什么", (p.sleepNote ?? "").contains("离开"), p.sleepNote ?? "nil")
        ctx.check("定时-换过去的那一条不是原绑定项", p.queue.current?.id != armed)
        p.stop()

        // ⑤ 手动停止：那一曲不会「播完」了，计划跟着作废
        play(ctx, p, [files.mid, files.long], at: 0)
        _ = p.setSleepAfterCurrentTrack()
        p.stop()
        ctx.check("定时-停止即取消等播完", !p.sleepTimer.isArmed
                          && (p.sleepNote ?? "").contains("停止"), p.sleepNote ?? "nil")
        // ⑥ 队列里什么都没有时不接这一档（停止不算：条目还在，接着播就是它）
        p.clearPlaylist()
        ctx.check("定时-空场是真的没有当前条目", p.queue.current == nil
                          && p.currentTrack == nil, "cur=\(String(describing: p.queue.current?.id))")
        ctx.check("定时-空场时挡下并说明", (p.setSleepAfterCurrentTrack() ?? "").contains("先播一首"),
                  p.sleepNote ?? "nil")
        ctx.check("定时-被挡下时没有偷偷设上", !p.sleepTimer.isArmed)
        p.setGaplessPlay(wasGapless)
    }

    // MARK: - 按分钟到点

    private func checkCountdown(_ ctx: SelfTestContext, p: PlayerController,
                                files: (short: URL, mid: URL, long: URL)) {
        let wasGapless = p.gaplessPlay
        p.setGaplessPlay(true)
        play(ctx, p, [files.long, files.mid], at: 0)
        fakeNow = MonotonicClock.seconds
        p.sleepTimer.clock = { [weak self] in self?.fakeNow ?? MonotonicClock.seconds }
        // 音量与静音设成一个可辨认的值：淡出与到点都不许动它们
        p.setVolume(0.5)
        if !p.isMuted { p.toggleMute() }
        ctx.check("定时-按分钟采纳", p.setSleepMinutes(1) == nil && p.sleepTimer.minutes == 1)
        let deadline = fakeNow + 60
        // 预取是后台排起来的，得等一下才有「窗口一进就撤掉」可言
        ctx.check("定时-窗口外还留着预取",
                  ctx.waitUntil(8) { !p.engine.nextPreparedKey.isEmpty },
                  "key=\(p.engine.nextPreparedKey)")
        // 进淡出窗口就该把下一曲的预取退掉（否则到点那一刻会漏出半首）
        fakeNow = deadline - 9
        ctx.check("定时-窗口内撤掉预取", ctx.waitUntil(3) { p.engine.nextPreparedKey.isEmpty },
                  "key=\(p.engine.nextPreparedKey)")
        ctx.check("定时-窗口内还在播", p.isPlaying)
        // 暂停不算豁免：按了暂停、合上盖子，时间照样走
        p.pause()
        ctx.check("定时-暂停时仍在计时", (p.sleepTimer.remaining ?? 60) < 60,
                  "left=\(p.sleepTimer.remaining ?? -1)")
        fakeNow = deadline + 30        // 醒来时早已过点
        ctx.check("定时-过点醒来即停止不补播",
                  ctx.waitUntil(3) { !p.sleepTimer.isArmed && !p.isPlaying })
        ctx.check("定时-到点后不再有倒计时", !p.sleepTimer.isArmed && p.sleepTimer.remaining == nil)
        ctx.check("定时-到点原因说得出", (p.sleepNote ?? "").contains("到点"), p.sleepNote ?? "nil")
        ctx.check("定时-到点不动用户音量与静音", abs(p.volume - 0.5) < 0.001 && p.isMuted,
                  "vol=\(p.volume) mute=\(p.isMuted)")
        ctx.check("定时-到点后链路上的淡出清干净",
                  p.engine.sleepFadeVolume == 1 && p.engine.fadeNodeVolume == 1,
                  "sleep=\(p.engine.sleepFadeVolume) fade=\(p.engine.fadeNodeVolume)")
        // 到点之后用户又按播放：正常出声，不再背着一层衰减
        p.togglePlay()
        ctx.check("定时-到点后能重新播", ctx.waitUntil(6) { p.isPlaying }, "playing=\(p.isPlaying)")
        let rms = ctx.fadeRMS(p, seconds: 0.6)
        ctx.check("定时-重新播放是全增益", rms > Self.audibleRMS && p.engine.fadeNodeVolume == 1,
                  "rms=\(rms) fade=\(p.engine.fadeNodeVolume)")
        p.pause()
        // 淡出中途取消：增益立刻回来
        fakeNow = MonotonicClock.seconds
        _ = p.setSleepMinutes(1)
        fakeNow += 57     // 还剩 3 秒
        ctx.check("定时-中途进淡出窗", ctx.waitUntil(3) { p.engine.sleepFadeVolume < 1 },
                  "sleep=\(p.engine.sleepFadeVolume)")
        p.cancelSleepTimer()
        ctx.check("定时-取消即恢复正常增益", p.engine.sleepFadeVolume == 1 && p.engine.fadeNodeVolume == 1,
                  "fade=\(p.engine.fadeNodeVolume)")
        ctx.check("定时-取消也不动用户音量", abs(p.volume - 0.5) < 0.001 && p.isMuted)
        p.stop()
        if p.isMuted { p.toggleMute() }
        p.setVolume(0.8)
        p.sleepTimer.clock = { MonotonicClock.seconds }
        p.setGaplessPlay(wasGapless)
    }

    // MARK: - 淡出实测（真实输出链）

    private func checkFadeChain(_ ctx: SelfTestContext, p: PlayerController,
                                files: (short: URL, mid: URL, long: URL)) {
        // 队列里放两条：淡出这一路上「不把下一曲漏出来」和「自己降下来」得一起验
        play(ctx, p, [files.long, files.mid], at: 0)
        let baseRMS = ctx.fadeRMS(p, seconds: 0.6)
        ctx.check("定时-淡出前本来有声音", baseRMS > Self.audibleRMS, "rms=\(baseRMS)")
        fakeNow = MonotonicClock.seconds
        p.sleepTimer.clock = { [weak self] in self?.fakeNow ?? MonotonicClock.seconds }
        _ = p.setSleepMinutes(1)
        let deadline = fakeNow + 60
        var measured: [(left: Double, want: Float, rms: Double)] = []
        for step in Self.fadeSteps {
            fakeNow = deadline - step.left
            // 等心跳把这一档的增益写进链路再量：不等的话量到的是上一档
            let settled = ctx.waitUntil(2) { abs(p.engine.sleepFadeVolume - step.want) < 0.01 }
            measured.append((step.left, step.want, settled ? ctx.fadeRMS(p, seconds: 0.8) : -1))
        }
        for m in measured {
            let got = m.rms > 0 ? m.rms / baseRMS : -1
            let tol = Double(m.want) * 0.15 + 0.02
            ctx.check("定时-淡出量到实际输出链路（还剩 \(trim(m.left)) 秒）",
                      got > 0 && abs(got - Double(m.want)) <= tol,
                      String(format: "实测比值 %.3f 期望 %.2f 容差 %.2f rms=%.5f 基线=%.5f",
                             got, Double(m.want), tol, m.rms, baseRMS))
        }
        ctx.check("定时-淡出曲线一路下行",
                  measured.allSatisfy { $0.rms > 0 }
                    && zip(measured, measured.dropFirst()).allSatisfy { $0.rms >= $1.rms - 1e-9 },
                  measured.map { String(format: "%.3f", $0.rms / baseRMS) }.joined(separator: " "))
        ctx.check("定时-淡出全程都还在播", p.isPlaying, "playing=\(p.isPlaying)")
        // 到点：预取早被撤了、最后一格已经贴地，停手时链路也擦干净
        fakeNow = deadline + 1
        ctx.check("定时-淡出走完才收场", ctx.waitUntil(3) { !p.isPlaying }, "playing=\(p.isPlaying)")
        ctx.check("定时-收场时链路无残留",
                  p.engine.fadeNodeVolume == 1 && p.engine.nextPreparedKey.isEmpty,
                  "fade=\(p.engine.fadeNodeVolume) key=\(p.engine.nextPreparedKey)")
        p.sleepTimer.clock = { MonotonicClock.seconds }
        p.stop()
    }

    /// 档位进断言名：0.4 这种小数直接写会拖出一长串 0
    private func trim(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    // MARK: - 电台与存档边界

    private func checkRadioAndArchive(_ ctx: SelfTestContext, p: PlayerController) {
        // 电台是无限流：没有「播完」这一说，要挡下来并说明，而不是默默退化成按分钟
        p.play(track: Track(radio: URL(string: "http://127.0.0.1:9/stream")!))
        ctx.check("定时-电台能进来（下面的判断才成立）", ctx.waitUntil(6) { p.isRadio },
                  "isRadio=\(p.isRadio)")
        let reason = p.setSleepAfterCurrentTrack() ?? ""
        ctx.check("定时-电台挡下「播完当前曲」", reason.contains("无限流"), reason)
        ctx.check("定时-挡下时没留下半截计划", !p.sleepTimer.isArmed)
        let tip = ctx.main.buildSleepTimerItem().submenu?.items
            .first { $0.title == "播完当前曲后停止" }?.toolTip ?? ""
        ctx.check("定时-菜单里那句解释跟着电台变", tip.contains("无限流"), tip)
        ctx.check("定时-电台仍能按分钟定时（直播也要能到点停）",
                  p.setSleepMinutes(15) == nil && p.sleepTimer.minutes == 15)
        p.cancelSleepTimer()
        p.stop()
        ctx.waitUntil(6) { !p.isRadio }

        // 退出即取消：只有淡出开关进档，倒计时本身一个字都不落盘
        p.setSleepFadeEnabled(true)
        _ = p.setSleepMinutes(60)
        p.persistNow()
        var sleepKeys: [String] = []
        var fadeStored: Bool?
        if let data = try? Data(contentsOf: ctx.dir.appendingPathComponent("state.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            sleepKeys = obj.keys.filter { $0.hasPrefix("sleep") }.sorted()
            fadeStored = obj["sleepFade"] as? Bool
        }
        ctx.check("定时-档里只有一个睡眠相关字段", sleepKeys == ["sleepFade"],
                  sleepKeys.joined(separator: ","))
        ctx.check("定时-淡出开关确实落了盘", fadeStored == p.sleepFadeEnabled,
                  "state.json=\(String(describing: fadeStored))")
        ctx.check("定时-读档回来还是同一个开关", LibraryStore.load().sleepFade == p.sleepFadeEnabled)
        // 旧档没这一项：要按需求默认开，而不是当成关掉
        let legacy = try? JSONDecoder().decode(AppState.self, from: Data("{\"trackPaths\":[]}".utf8))
        ctx.check("定时-旧档缺这一项按默认开", legacy?.sleepFade == true)
        p.cancelSleepTimer()
    }

    // MARK: - 收尾

    private func cleanup(_ ctx: SelfTestContext, p: PlayerController,
                         keep: Snapshot, root: URL) {
        p.cancelSleepTimer()
        // 先把真表接回去再推增益：拿假表推会算出一个与用户无关的系数
        p.sleepTimer.clock = { MonotonicClock.seconds }
        p.setSleepFadeEnabled(keep.fadeEnabled)
        p.sleepTimer.fadeSeconds = keep.fadeSeconds
        p.applySleepFade()
        p.stop()
        if p.isMuted != keep.muted { p.toggleMute() }
        if abs(p.volume - keep.volume) > 0.001 { p.setVolume(keep.volume) }
        p.setMode(keep.playMode)
        p.setGaplessPlay(keep.gapless)
        ctx.check("定时-收摊后没有留计划", !p.sleepTimer.isArmed
                          && !ctx.main.displayPanel.statusText.contains("剩 "),
                  ctx.main.displayPanel.statusText)
        ctx.check("定时-收摊后链路与音量回到用户手上",
                  p.engine.fadeNodeVolume == 1 && abs(p.volume - keep.volume) < 0.001,
                  "fade=\(p.engine.fadeNodeVolume) vol=\(p.volume)")
        try? ctx.fm.removeItem(at: root)
        ctx.resetLibrary()
    }

    // MARK: - 小工具

    /// 用给定的曲目重开一段播放上下文（列表只留这几条，推进到哪一条才好断言）
    private func play(_ ctx: SelfTestContext, _ p: PlayerController, _ urls: [URL], at: Int) {
        p.cancelSleepTimer()
        p.stop()
        p.clearPlaylist()
        _ = p.addTracks(urls.map { Track(url: $0) })
        p.playRowAt(at)
        let up = ctx.waitUntil(8) { p.isPlaying && p.engine.currentTime > 0.1 }
        if !up {
            ctx.check("定时-素材能播起来", false, "url=\(urls[at].lastPathComponent)")
        }
    }
}
