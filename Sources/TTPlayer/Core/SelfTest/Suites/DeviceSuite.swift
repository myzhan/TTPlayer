import AVFoundation
import AppKit
import CoreAudio
import Foundation

/// F07 输出设备选择与设备变更跟随。
///
/// 这套断言的凭据是**真设备上的真链路**：`OutputDevices.currentDeviceID(in:)` 读回来的是
/// AUHAL 自己说「我正往这台出声」，不是界面记的那个字符串；出声与否拿 playerNode 上采到的
/// PCM 判。设备不够用的场合（本机只有一台输出设备、造不出聚合设备）一律标 SKIP 并说明，
/// 不拿假设备凑断言。
///
/// 「拔出/接回」用 CoreAudio 公开 API 现场造一台聚合设备再销毁来验：它有真 UID、真声道数，
/// 销毁后 UID 从清单消失、AUHAL 被系统挪回默认——和真拔一个 USB DAC 在 CoreAudio 层留下的
/// 痕迹是同一种。「系统默认换了」也是真改系统默认（测完立即还原），不改的话这一档只能靠推演。
final class DeviceSuite: SelfTestSuite {
    /// 自检虚拟设备（聚合设备）的 UID：销毁重造也不换号，正好当「按 UID 存、不按临时句柄存」的凭据
    private static let virtualUID = "com.ttplayer.selftest.aggregate"
    private static let virtualName = "TTPlayer 自检虚拟设备"
    /// 三档采样率各配一个音高：只断言「有声音」证不了放的是这一档，音高才是内容凭据
    private static let tones: [(rate: Int, freq: Double)] = [(44_100, 440), (48_000, 660), (96_000, 880)]
    /// 采到的电平低于这个数就当「没出声」（0.2 幅度正弦的实测 RMS 是 0.0125 量级）
    private static let silentRMS = 0.0005

    /// 输出变更广播的计数钩子：`.ttOutputChanged` 是控制层唯一的对外说法，
    /// 「设备变了界面得刷新」只能靠它证明真广播过
    private final class OutputWatch {
        private(set) var broadcasts = 0
        private(set) var lastSummary = ""
        private var token: NSObjectProtocol?

        func start() {
            guard token == nil else { return }
            token = NotificationCenter.default.addObserver(forName: .ttOutputChanged, object: nil, queue: nil) {
                [weak self] note in
                self?.broadcasts += 1
                self?.lastSummary = (note.userInfo?["summary"] as? String) ?? ""
            }
        }

        func stop() {
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
        }

        func reset() { broadcasts = 0; lastSummary = "" }
    }

    /// 跑之前把现场记下来，跑完原样还回去（设备与系统默认都是全局状态，不能留在自检的样子上）
    private struct Snapshot {
        let outputDeviceUID: String
        let systemDefaultID: AudioDeviceID
        let volume: Float
        let muted: Bool
        let eqEnabled: Bool
        let eqGains: [Float]
        let playMode: PlayMode
    }

    func run(_ ctx: SelfTestContext) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ttplayer-device", isDirectory: true)
        // 上一轮（或崩掉没收尾）留下的素材和聚合设备都先清：旧设备会扮成「这一轮造出来了」
        destroyStaleVirtual(ctx)
        try? ctx.fm.removeItem(at: root)
        try? ctx.fm.createDirectory(at: root, withIntermediateDirectories: true)

        let watch = OutputWatch()
        watch.start()
        let keep = snap(ctx)
        let files = makeMaterial(ctx, root: root)
        let devices = OutputDevices.available()
        // UID 也一并抄进报告：CoreAudio 偶尔会塞进来一台按进程编号的内部聚合设备
        // （CADefaultDeviceAggregate-<pid>-<n>），它当不了系统默认，出问题时得一眼认出是它
        ctx.emit("[selftest] 本机输出设备：" + devices.map {
            "\($0.name)[\($0.uid)](\($0.channels)声道/\(OutputDevices.ratesSummary($0)))"
        }.joined(separator: "、"))

        checkEnumeration(ctx, devices)
        checkMenuAndReasons(ctx, watch: watch, devices: devices)
        checkRealSwitch(ctx, watch: watch, devices: devices, files: files)
        checkDefaultChange(ctx, watch: watch, devices: devices, files: files)
        checkVirtualLifecycle(ctx, watch: watch, files: files)
        checkRates(ctx, devices: devices, files: files)
        checkStateRoundTrip(ctx)
        restore(ctx, keep: keep)
        watch.stop()
        try? ctx.fm.removeItem(at: root)
    }

    // MARK: - 素材与测量

    /// 三档采样率的素材（2 声道 16 bit，3 秒，左声道恒频）
    private func makeMaterial(_ ctx: SelfTestContext, root: URL) -> [(rate: Int, freq: Double, url: URL)] {
        var out: [(rate: Int, freq: Double, url: URL)] = []
        for tone in Self.tones {
            let url = root.appendingPathComponent("rate\(tone.rate).wav")
            if ctx.writeWave(url, sampleRate: tone.rate, channels: 2, bits: 16,
                             freqs: [tone.freq, 0], seconds: 3) {
                out.append((tone.rate, tone.freq, url))
            } else {
                ctx.emit("[selftest] SKIP 输出设备-\(tone.rate) Hz 素材（写不出来）")
            }
        }
        return out
    }

    /// 起播一份素材并等到真在放
    @discardableResult
    private func startPlay(_ ctx: SelfTestContext, _ url: URL) -> Bool {
        let p = ctx.player
        p.stop()
        p.clearPlaylist()
        p.setMode(.listLoop)
        guard p.addFiles([url]) >= 1 else { return false }
        p.playRowAt(0)
        return ctx.waitUntil(5) { p.isPlaying && p.currentTrack != nil }
    }

    /// 采一小段正在放的 PCM，报「有没有声」与「是不是这个音高」
    private func measure(_ ctx: SelfTestContext, freq: Double, seconds: Double = 0.8) -> (level: Double, tone: Double) {
        let cap = ctx.captureLeftChannel(ctx.player, seconds: seconds)
        guard cap.sampleRate > 0, !cap.samples.isEmpty else { return (0, 0) }
        // 丢掉管线起步那一段（预排窗口 ~0.7 s，见 F02 同口径）
        let n = min(cap.samples.count, Int(cap.sampleRate * 0.4))
        let tail = Array(cap.samples.suffix(n))
        return (DeviceSuite.rms(tail), ctx.toneEnergy(tail, sampleRate: cap.sampleRate, freq: freq))
    }

    /// 刚换完设备 / 重建过输出链 / 拔插之后那一窗不能单采：窗口里混着旧缓冲尾巴与
    /// 重排期的咔哒，音高被摊薄（全量跑里实测偶发 RMS 0.36249 / 音高能量 0.008，
    /// 单跑复现不出来——前面几十个套件把管线闹热了才撞得上）。
    /// 这里连着采几窗、取音高最强的一窗，拿到干净的一窗就走，不白等；
    /// 验的仍然是「那台设备上真在放这个音高」，不是把失败平均掉
    private func measureSettled(_ ctx: SelfTestContext, freq: Double,
                                windows: Int = 4) -> (level: Double, tone: Double, tries: Int) {
        var best = (level: 0.0, tone: 0.0, tries: 0)
        for i in 1...windows {
            let m = measure(ctx, freq: freq)
            if m.tone > best.tone { best = (m.level, m.tone, i) }
            if m.tone > 0.1 { best.tries = i; break }
            if i < windows { ctx.pump(0.3) }
        }
        return best
    }

    private static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for v in samples { sum += Double(v) * Double(v) }
        return (sum / Double(samples.count)).squareRoot()
    }

    private func snap(_ ctx: SelfTestContext) -> Snapshot {
        let p = ctx.player
        return Snapshot(outputDeviceUID: p.outputDeviceUID,
                        systemDefaultID: DeviceSuite.readSystemDefault(),
                        volume: p.volume, muted: p.isMuted, eqEnabled: p.eqEnabled,
                        eqGains: (0..<AudioEngine.eqBandCount).map { p.engine.eqGain(band: $0) },
                        playMode: p.playMode)
    }

    private func restore(_ ctx: SelfTestContext, keep: Snapshot) {
        let p = ctx.player
        p.stop()
        // 系统默认先还原：设备还固定着的话，改默认会触发一次对账，那一次对账得看到真现场
        let now = DeviceSuite.readSystemDefault()
        if now != keep.systemDefaultID, !DeviceSuite.setSystemDefault(keep.systemDefaultID) {
            ctx.emit("[selftest] 输出设备-系统默认没能还原（id=\(keep.systemDefaultID)），请手动确认")
        }
        if p.outputDeviceUID != keep.outputDeviceUID { _ = p.setOutputDevice(uid: keep.outputDeviceUID) }
        destroyVirtual(ctx)
        p.setVolume(keep.volume)
        if p.isMuted != keep.muted { p.toggleMute() }
        p.setEQEnabled(keep.eqEnabled)
        for (i, g) in keep.eqGains.enumerated() { p.engine.setEQGain(band: i, gain: g) }
        p.setMode(keep.playMode)
        // 现场还原得能说出口：不然下一套跑的时候根本不知道音量是不是被上一段改了
        ctx.emit(String(format: "[selftest] 输出设备段现场还原：音量 %.2f 静音=%@ EQ=%@",
                        p.volume, p.isMuted ? "开" : "关", p.eqEnabled ? "开" : "关"))
    }

    // MARK: - CoreAudio 现场操作（只有自检需要，生产代码不碰系统默认、也不造设备）

    private static func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
    }

    static func readSystemDefault() -> AudioDeviceID {
        var addr = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    /// 改系统默认输出（真改，测完还原）：不真改就验不出「默认换了会不会抢走固定档的输出」
    static func setSystemDefault(_ id: AudioDeviceID) -> Bool {
        var addr = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var device = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &device) == noErr
    }

    /// 造一台挂在 baseUID 上的聚合设备（真 UID、真声道，等同插上一台外部设备）
    private func makeVirtual(_ ctx: SelfTestContext, baseUID: String) -> AudioDeviceID? {
        let props: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: Self.virtualUID,
            kAudioAggregateDeviceNameKey as String: Self.virtualName,
            // 子设备要写成「字典数组」：直接把 UID 数组放外面，造出来的设备 0 声道、切不过去
            kAudioAggregateDeviceSubDeviceListKey as String: [[kAudioSubDeviceUIDKey as String: baseUID]],
            kAudioAggregateDeviceMainSubDeviceKey as String: baseUID,
            kAudioAggregateDeviceIsPrivateKey as String: false,
        ]
        var created = AudioDeviceID(0)
        let st = AudioHardwareCreateAggregateDevice(props as CFDictionary, &created)
        guard st == noErr, created != 0 else {
            ctx.emit("[selftest] SKIP 输出设备-拔出接回（造聚合设备失败 CoreAudio \(st)，本机不允许）")
            return nil
        }
        // 设备进清单是异步的：不等一下就断言，量到的是「还没出现」
        _ = ctx.waitUntil(5) { OutputDevices.exists(uid: Self.virtualUID) }
        return created
    }

    private func destroyVirtual(_ ctx: SelfTestContext) {
        guard let id = OutputDevices.resolve(Self.virtualUID)?.id else { return }
        // 销毁必须离开主线程：设备正被本进程的 IO 用着时，在主线程上调它永远不返回
        // （实测：卡在那一行 20 分钟，主线程一挂连看门狗定时器都发不出来）。
        // 真拔 USB 也是「别处在拆」，不是我们主线程的活，放后台反而更像现场
        DispatchQueue.global(qos: .userInitiated).async {
            _ = AudioHardwareDestroyAggregateDevice(id)
        }
        // 销毁同样是异步的（实测半秒后才从清单消失）：等它真没了，不然「拔出」是假的
        _ = ctx.waitUntil(6) { !OutputDevices.exists(uid: Self.virtualUID) }
    }

    private func destroyStaleVirtual(_ ctx: SelfTestContext) {
        guard OutputDevices.exists(uid: Self.virtualUID) else { return }
        ctx.emit("[selftest] 输出设备-先清掉上一轮遗留的自检虚拟设备")
        destroyVirtual(ctx)
    }

    // MARK: - 断言

    /// 枚举与筛选：麦克风一类没有输出声道，出现在列表里就是给用户一个点了没声的选项
    private func checkEnumeration(_ ctx: SelfTestContext, _ devices: [OutputDevices.Device]) {
        ctx.check("输出设备-能列出可用输出设备", !devices.isEmpty,
                  "枚举结果空（本机没有可用的输出设备？）")
        ctx.check("输出设备-每台都有 UID", devices.allSatisfy { !$0.uid.isEmpty },
                  devices.map(\.uid).joined(separator: ","))
        ctx.check("输出设备-UID 不重复", Set(devices.map(\.uid)).count == devices.count)
        ctx.check("输出设备-筛掉了没有输出声道的设备", devices.allSatisfy { $0.channels > 0 },
                  devices.map { "\($0.name):\($0.channels)声道" }.joined(separator: " "))
        // CoreAudio 会替正在放音的客户端造一台 `CADefaultDeviceAggregate-<pid>-<n>`：
        // 它当不了系统默认（设上去系统不认、也不广播），拿它当「另一台设备」会把
        // 「跟随默认」那一档测成假失败（实测：先跑睡眠套件再跑这一套就是这样）。已开播的
        // 那一套会在后面凭空多出这台来，所以这一条得钉住清单里不能它有
        ctx.check("输出设备-不列 CoreAudio 自家的透明聚合设备",
                  devices.allSatisfy { !OutputDevices.isTransparentInternal($0) },
                  devices.map(\.name).joined(separator: "、"))
        let phantom = OutputDevices.Device(uid: "CADefaultDeviceAggregate-66957-0",
                                           name: "CADefaultDeviceAggregate-66957-0",
                                           channels: 2, rates: [], id: 0)
        ctx.check("输出设备-透明聚合那一档只认那个形状",
                  OutputDevices.isTransparentInternal(phantom)
                    && !OutputDevices.isTransparentInternal(
                        OutputDevices.Device(uid: Self.virtualUID, name: Self.virtualName,
                                             channels: 2, rates: [], id: 0))
                    && !OutputDevices.isTransparentInternal(
                        OutputDevices.Device(uid: "com.apple.audio.myaggregate",
                                             name: "我的聚合设备", channels: 2, rates: [], id: 0)),
                  "不能把用户自己造的聚合设备一起筛掉")
        if let dflt = OutputDevices.systemDefault() {
            if OutputDevices.isTransparentInternal(dflt) {
                // 默认那台本身就是 CoreAudio 临时造的那种：清单里没有它，「排首位」无从谈起
                ctx.emit("[selftest] SKIP 输出设备-默认设备排序（当前系统默认是 CoreAudio 内部的 \(dflt.name)）")
            } else {
                ctx.check("输出设备-系统默认那台排在清单首位", devices.first?.uid == dflt.uid,
                          "首位=\(devices.first?.name ?? "空")，默认=\(dflt.name)")
            }
            ctx.check("输出设备-按 UID 找回的设备句柄与枚举一致",
                      OutputDevices.resolve(dflt.uid)?.id == dflt.id)
            ctx.check("输出设备-报得出设备自己认的采样率", !OutputDevices.ratesSummary(dflt).isEmpty,
                      OutputDevices.ratesSummary(dflt))
        }
        ctx.check("输出设备-不存在的 UID 说「此刻不可用」",
                  OutputDevices.resolve("com.ttplayer.selftest.nosuch") == nil
                      && !OutputDevices.exists(uid: "com.ttplayer.selftest.nosuch"))
    }

    /// 菜单入口与失败说法：内部接口都得有用户入口，反过来用户看到的勾得跟设置一致
    private func checkMenuAndReasons(_ ctx: SelfTestContext, watch: OutputWatch,
                                     devices: [OutputDevices.Device]) {
        let p = ctx.player
        guard let item = ctx.main.buildOutputDeviceItem().submenu else {
            ctx.check("输出设备-菜单里有输出设备子菜单", false, "submenu 为 nil"); return
        }
        ctx.check("输出设备-菜单里有输出设备子菜单", true)
        ctx.check("输出设备-菜单第一行报出当前实际输出",
                  item.items.first?.title == "当前实际输出：\(p.outputDeviceNameText)",
                  item.items.first?.title ?? "空")
        let selectable = item.items.filter { $0.action == #selector(MainWindowController.selectOutputDevice(_:)) }
        ctx.check("输出设备-菜单有「跟随系统默认」这一档",
                  selectable.contains { $0.title == "跟随系统默认" },
                  selectable.map(\.title).joined(separator: "/"))
        ctx.check("输出设备-菜单列出的设备数与枚举一致",
                  selectable.count - 1 == devices.count || devices.isEmpty,
                  "菜单 \(selectable.count - 1) 台 / 枚举 \(devices.count) 台")
        ctx.check("输出设备-菜单项带的是 UID",
                  selectable.allSatisfy { $0.representedObject == nil || ($0.representedObject as? String) != nil },
                  selectable.compactMap { $0.representedObject }.map { String(describing: type(of: $0)) }.joined(separator: ","))
        let checked = selectable.filter { $0.state == .on }
        ctx.check("输出设备-勾只有一个且与设置一致", checked.count == 1
                  && (checked.first?.representedObject as? String ?? "") == p.outputDeviceUID,
                  "勾了 \(checked.count) 项，设置=\(p.outputDeviceUID.isEmpty ? "跟随" : p.outputDeviceUID)")
        ctx.check("输出设备-跟随档的说明说得出实际设备",
                  p.outputDeviceUID.isEmpty ? p.outputDeviceSummary.contains("跟随系统默认") : true,
                  p.outputDeviceSummary)
        // 切不动的时候要说人话，而且什么都不许改
        watch.reset()
        let beforeUID = p.outputDeviceUID
        let reason = p.setOutputDevice(uid: "com.ttplayer.selftest.nosuch")
        ctx.check("输出设备-切到不在的设备给出原因", reason?.contains("不可用") == true, reason ?? "没返回原因")
        ctx.check("输出设备-切换失败不改设置", p.outputDeviceUID == beforeUID,
                  "\(beforeUID) → \(p.outputDeviceUID)")
        ctx.check("输出设备-切换失败会广播出来让界面刷新", watch.broadcasts > 0, "广播 \(watch.broadcasts) 次")
        ctx.check("输出设备-失败原因进得了属性面板那一行",
                  p.outputDeviceSummary.contains("不可用"), p.outputDeviceSummary)
        // 「一台输出设备都没有」的空状态本机造不出来（系统总有一台），只能标注
        ctx.emit("[selftest] SKIP 输出设备-空状态文案（本机拿不到「零输出设备」环境，未实测）")
        _ = p.setOutputDevice(uid: beforeUID.isEmpty ? "" : beforeUID)
    }

    /// 两台真实设备之间的切换：曲序、进度、EQ、音量、静音都得原样留着，而且得真在新设备上出声
    private func checkRealSwitch(_ ctx: SelfTestContext, watch: OutputWatch,
                                 devices: [OutputDevices.Device],
                                 files: [(rate: Int, freq: Double, url: URL)]) {
        guard devices.count >= 2 else {
            ctx.emit("[selftest] SKIP 输出设备-真设备切换（本机只有 \(devices.count) 台可输出设备，未实测）")
            return
        }
        guard let first = files.first else { return }
        let a = devices[0], b = devices[1]
        let ratesBefore = [a, b].map { OutputDevices.nominalRate(uid: $0.uid) }
        let p = ctx.player
        guard startPlay(ctx, first.url) else {
            ctx.check("输出设备-真设备切换（起播失败）", false); return
        }
        // 换设备前把 EQ/音量/静音调成「不是默认值」，还原不到位就会立刻露出来。
        // 顺序得先音量再静音：`setVolume` 推到大于 0 会自动退静音（既有行为），
        // 循环里再改音量会把「静音能不能留住」这一条测成假失败
        p.setVolume(0.45)
        p.setEQEnabled(true)
        p.engine.setEQGain(band: 3, gain: 4)
        if !p.isMuted { p.toggleMute() }
        let base = measure(ctx, freq: first.freq)
        ctx.check("输出设备-切换前在原设备上有声", base.level > Self.silentRMS, "RMS \(base.level)")

        for (round, target) in [a, b, a].enumerated() {
            watch.reset()
            let ready = ctx.waitUntil(3) { p.isPlaying }
            guard ready else { continue }
            let before = p.currentTime
            let startedAt = Date()
            let reason = p.setOutputDevice(uid: target.uid)
            ctx.check("输出设备-第 \(round + 1) 次切到「\(target.name)」成功", reason == nil, reason ?? "")
            ctx.check("输出设备-第 \(round + 1) 次切完 AUHAL 真在那台", p.engine.outputDeviceUID == target.uid,
                      "实际=\(p.engine.outputDeviceUID)")
            ctx.check("输出设备-切完还在播（曲目没换）", p.isPlaying
                      && p.currentTrack?.url == first.url,
                      "isPlaying=\(p.isPlaying) 曲目=\(p.currentTrack?.url.lastPathComponent ?? "nil")")
            // 进度得跟着真实时间往前走，不能回退也不能整段重来
            let drift = p.currentTime - (before + Date().timeIntervalSince(startedAt))
            ctx.check("输出设备-切完进度接着走", abs(drift) < 1.0,
                      String(format: "切换前 %.2f s，切完 %.2f s，走了 %.2f s", before, p.currentTime,
                             Date().timeIntervalSince(startedAt)))
            ctx.check("输出设备-切完队列还在", p.playlist.tracks.count >= 1)
            ctx.check("输出设备-切完 EQ 没被抹平", p.engine.eqGain(band: 3) == 4,
                      "band3=\(p.engine.eqGain(band: 3))")
            ctx.check("输出设备-切完音量与静音没被改", abs(p.volume - 0.45) < 0.001 && p.isMuted,
                      "音量=\(p.volume) 静音=\(p.isMuted)")
            ctx.check("输出设备-切完引擎重新跑起来", p.engine.audioEngineRunning)
            let after = measureSettled(ctx, freq: first.freq)
            ctx.check("输出设备-切完真在新设备上出声", after.level > Self.silentRMS && after.tone > 0.1,
                      String(format: "RMS %.5f 音高能量 %.3f（第 %d 窗）", after.level, after.tone, after.tries))
            ctx.check("输出设备-切完会广播刷新", watch.broadcasts > 0, "广播 \(watch.broadcasts) 次")
        }
        p.toggleMute()   // 静音留着会影响后面几段对电平的判断
        let ratesAfter = [a, b].map { OutputDevices.nominalRate(uid: $0.uid) }
        ctx.check("输出设备-没有擅自改硬件采样率", ratesBefore == ratesAfter,
                  "\(ratesBefore) → \(ratesAfter)")
        _ = p.setOutputDevice(uid: "")
        ctx.check("输出设备-「跟随系统默认」切得回去", p.engine.outputDeviceUID == a.uid,
                  "实际=\(p.engine.outputDeviceUID)，默认=\(a.uid)")
    }

    /// 系统默认换了：固定档不许被抢走，跟随档得跟过去（真改系统默认，测完还原）
    private func checkDefaultChange(_ ctx: SelfTestContext, watch: OutputWatch,
                                    devices: [OutputDevices.Device],
                                    files: [(rate: Int, freq: Double, url: URL)]) {
        guard devices.count >= 2, let first = files.first else {
            ctx.emit("[selftest] SKIP 输出设备-默认设备变化（本机凑不出「默认 + 另一台」的组合，未实测）")
            return
        }
        let originalID = DeviceSuite.readSystemDefault()
        guard let pinned = devices.first(where: { $0.id == originalID }),
              let other = devices.first(where: { $0.id != originalID }) else {
            ctx.emit("[selftest] SKIP 输出设备-默认设备变化（默认那台不在可输出清单里）")
            return
        }
        let p = ctx.player
        guard startPlay(ctx, first.url) else {
            ctx.check("输出设备-默认变化段起播", false); return
        }
        // 先固定到当时默认那台，再把系统默认换到另一台：这一档要拦的是「静悄悄跟着默认跑」
        guard p.setOutputDevice(uid: pinned.uid) == nil else {
            ctx.emit("[selftest] SKIP 输出设备-默认设备变化（固定到「\(pinned.name)」没成功）")
            return
        }
        guard DeviceSuite.setSystemDefault(other.id) else {
            ctx.emit("[selftest] SKIP 输出设备-默认设备变化（本机不允许改系统默认，未实测）")
            _ = p.setOutputDevice(uid: "")
            return
        }
        // 设上去不等于真改了：有些设备（CoreAudio 自家的透明聚合就是）接不接受当默认
        // 全看系统心情。当场读回来对一次账，对不上就 SKIP —— 不然会把「本机凑不出组合」
        // 报成「应用没跟着默认变」，那是测错了而不是测出问题
        if DeviceSuite.readSystemDefault() != other.id {
            ctx.emit("[selftest] SKIP 输出设备-默认设备变化（系统不肯把默认换到「\(other.name)」，未实测）")
            _ = p.setOutputDevice(uid: "")
            _ = DeviceSuite.setSystemDefault(originalID)
            return
        }
        watch.reset()
        let seen = ctx.waitUntil(8) { watch.broadcasts > 0 }
        ctx.check("输出设备-默认换了能收到通知", seen, "广播 \(watch.broadcasts) 次")
        ctx.check("输出设备-固定档不被系统默认抢走", p.engine.outputDeviceUID == pinned.uid,
                  "实际=\(p.engine.outputDeviceUID)，新默认=\(other.uid)")
        ctx.check("输出设备-默认换了没把播放折腾停",
                  p.isPlaying && p.engine.audioEngineRunning,
                  "isPlaying=\(p.isPlaying) engine=\(p.engine.audioEngineRunning)")
        ctx.check("输出设备-固定档的说明写「已固定」", p.outputDeviceSummary.contains("已固定"),
                  p.outputDeviceSummary)
        let on = measureSettled(ctx, freq: first.freq)
        ctx.check("输出设备-默认换了仍从固定那台出声",
                  on.level > Self.silentRMS && on.tone > 0.1,
                  String(format: "RMS %.5f 音高能量 %.3f", on.level, on.tone))
        // 改回跟随：得立刻按新的系统默认出声
        guard p.setOutputDevice(uid: "") == nil else {
            ctx.check("输出设备-切回跟随档", false, p.outputProblem ?? ""); return
        }
        ctx.check("输出设备-跟随档按新默认出声", p.engine.outputDeviceUID == other.uid,
                  "实际=\(p.engine.outputDeviceUID)")
        // 系统默认换回去：跟随档自己跟回来（靠监听，不是手动对账）
        watch.reset()
        _ = DeviceSuite.setSystemDefault(originalID)
        let back = ctx.waitUntil(8) { p.engine.outputDeviceUID == pinned.uid }
        ctx.check("输出设备-跟随档跟着系统默认回来", back,
                  "实际=\(p.engine.outputDeviceUID)，默认=\(pinned.uid)，广播 \(watch.broadcasts) 次")
        p.stop()
    }

    /// 用自检聚合设备走一遍「固定 → 异采样率 → 拔出 → 接回 → 唤醒对账 → 另选一台」
    private func checkVirtualLifecycle(_ ctx: SelfTestContext, watch: OutputWatch,
                                       files: [(rate: Int, freq: Double, url: URL)]) {
        guard let base = OutputDevices.systemDefault(), let first = files.first else {
            ctx.emit("[selftest] SKIP 输出设备-拔出接回（本机没有可当子设备的输出设备）")
            return
        }
        let p = ctx.player
        guard makeVirtual(ctx, baseUID: base.uid) != nil else { return }   // SKIP 已在里面说
        guard let virt = OutputDevices.resolve(Self.virtualUID) else {
            ctx.emit("[selftest] SKIP 输出设备-拔出接回（聚合设备没进清单）")
            return
        }
        let oldID = virt.id
        let virtNominal = OutputDevices.nominalRate(uid: Self.virtualUID)
        ctx.check("输出设备-自检虚拟设备有输出声道", virt.channels > 0, "\(virt.channels) 声道")
        // ① 固定到它：设置、引擎、存档三处得同时指过去
        let reason = p.setOutputDevice(uid: Self.virtualUID)
        ctx.check("输出设备-能固定到虚拟设备", reason == nil, reason ?? "")
        guard reason == nil else { destroyVirtual(ctx); return }
        ctx.check("输出设备-设置与实际都指向虚拟设备",
                  p.outputDeviceUID == Self.virtualUID && p.engine.outputDeviceUID == Self.virtualUID,
                  "设置=\(p.outputDeviceUID) 实际=\(p.engine.outputDeviceUID)")
        ctx.check("输出设备-落盘按 UID 记设备", savedUID(ctx) == Self.virtualUID, savedUID(ctx) ?? "nil")
        ctx.check("输出设备-落盘里没有临时设备句柄", !savedHasDeviceIDKey(ctx),
                  savedState(ctx)?.keys.filter { $0.hasPrefix("output") }.joined(separator: ",") ?? "")
        guard startPlay(ctx, first.url) else {
            ctx.check("输出设备-虚拟设备段起播", false)
            _ = p.setOutputDevice(uid: ""); destroyVirtual(ctx); return
        }
        let on = measure(ctx, freq: first.freq)
        ctx.check("输出设备-虚拟设备上真出声",
                  on.level > Self.silentRMS && on.tone > 0.1,
                  String(format: "RMS %.5f 音高能量 %.3f", on.level, on.tone))
        // 聚合设备只继承子设备那几档采样率：96 kHz 源在上面出声就是「安全重采样」而不是「抢不响」
        if let hi = files.first(where: { $0.rate >= 88_200 }), startPlay(ctx, hi.url) {
            let h = measure(ctx, freq: hi.freq)
            ctx.check("输出设备-虚拟设备上放 \(hi.rate) Hz 也有声",
                      h.level > Self.silentRMS && h.tone > 0.1,
                      String(format: "RMS %.5f 音高能量 %.3f", h.level, h.tone))
            let after = OutputDevices.nominalRate(uid: Self.virtualUID)
            ctx.check("输出设备-高采样率源没改设备硬件采样率", abs(after - virtNominal) < 1,
                      "\(Int(virtNominal)) → \(Int(after))")
            // 下面几段（拔出/接回/另选）量的都是 first 那一档的音高，先把曲换回去；
            // 不换回去就会拿 440 Hz 去量 880 Hz 的源，音高能量永远算不出峰
            _ = startPlay(ctx, first.url)
        }
        // ② 拔出
        watch.reset()
        destroyVirtual(ctx)
        let paused = ctx.waitUntil(10) { p.outputProblem != nil && !p.isPlaying }
        ctx.check("输出设备-拔出后暂停并报错",
                  paused, "问题=\(p.outputProblem ?? "无") isPlaying=\(p.isPlaying)")
        ctx.check("输出设备-拔出的说法能说出是哪台",
                  p.outputProblem.map { $0.contains("虚拟设备") && $0.contains("不可用") } ?? false,
                  p.outputProblem ?? "")
        let silent = measure(ctx, freq: first.freq)
        ctx.check("输出设备-拔出后没突然从扬声器出声", silent.level < Self.silentRMS,
                  String(format: "RMS %.6f", silent.level))
        ctx.check("输出设备-拔出会广播界面刷新", watch.broadcasts > 0, "广播 \(watch.broadcasts) 次")
        // ③ 接回（同一个 UID、新的临时句柄）
        watch.reset()
        guard makeVirtual(ctx, baseUID: base.uid) != nil else {
            ctx.emit("[selftest] SKIP 输出设备-接回（重造聚合设备没成功）")
            return
        }
        let plugged = ctx.waitUntil(10) { p.outputProblem == nil }
        ctx.check("输出设备-接回后故障提示消掉", plugged, p.outputProblem ?? "")
        let again = OutputDevices.resolve(Self.virtualUID)
        ctx.check("输出设备-重插后 UID 不变而临时句柄变了",
                  again != nil && again!.id != oldID, "旧 id=\(oldID) 新 id=\(again?.id ?? 0)")
        ctx.check("输出设备-接回后仍保持暂停（不自己开声）", !p.isPlaying,
                  "isPlaying=\(p.isPlaying)")
        ctx.check("输出设备-接回后把输出扳回那台", p.engine.outputDeviceUID == Self.virtualUID,
                  "实际=\(p.engine.outputDeviceUID)")
        p.togglePlay()
        let resumed = ctx.waitUntil(5) { p.isPlaying }
        let back = measureSettled(ctx, freq: first.freq)
        ctx.check("输出设备-接回后由用户恢复才出声",
                  resumed && back.level > Self.silentRMS && back.tone > 0.1,
                  String(format: "isPlaying=\(p.isPlaying) RMS %.5f 音高能量 %.3f（第 %d 窗）",
                          back.level, back.tone, back.tries))
        // ④ 唤醒：真投递一次 didWake（真睡眠不能为了验证把机器睡掉）
        let chain = p.engine.restartOutputChain()
        let afterChain = measureSettled(ctx, freq: first.freq)
        ctx.check("输出设备-输出链能重建并续播（唤醒后引擎停了那一档）",
                  chain.contains("续播") && p.isPlaying && afterChain.level > Self.silentRMS, chain)
        watch.reset()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        let woke = ctx.waitUntil(8) { watch.broadcasts > 0 }
        ctx.check("输出设备-唤醒回调挂了并会做一次对账", woke, "广播 \(watch.broadcasts) 次")
        ctx.check("输出设备-对账没把现场折腾坏",
                  p.engine.outputDeviceUID == Self.virtualUID && p.isPlaying && p.outputProblem == nil,
                  "实际=\(p.engine.outputDeviceUID) isPlaying=\(p.isPlaying)")
        ctx.emit("[selftest] 输出设备-真休眠（合盖/系统睡眠）未实测：自检不能为了验证把机器睡掉，"
                 + "上面验的是唤醒入口挂了、对账会扳回设备并重建输出链")
        // ⑤ 再拔一次：这时用户得能另选一台（需求：显示不可用并允许选择其他设备）
        destroyVirtual(ctx)
        _ = ctx.waitUntil(10) { p.outputProblem != nil }
        let switchReason = p.setOutputDevice(uid: base.uid)
        ctx.check("输出设备-拔出时允许另选一台", switchReason == nil, switchReason ?? "")
        // 另选只把声音指到新设备，不替用户按播放（需求：接回/换设备后由用户恢复）：
        // 想验「从新设备真出声」就得先模拟那一次恢复
        p.togglePlay()
        _ = ctx.waitUntil(5) { p.isPlaying }
        let fallback = measureSettled(ctx, freq: first.freq)
        ctx.check("输出设备-另选后故障清掉并从新设备出声",
                  p.outputProblem == nil && fallback.level > Self.silentRMS && fallback.tone > 0.1,
                  String(format: "问题=\(p.outputProblem ?? "无") RMS %.5f 音高能量 %.3f（第 %d 窗）",
                          fallback.level, fallback.tone, fallback.tries))
        _ = p.setOutputDevice(uid: "")
        p.stop()
    }

    /// 44.1 / 48 / 96 kHz 三档：要验的不是「能响」而是「响的是这一档的内容」
    private func checkRates(_ ctx: SelfTestContext, devices: [OutputDevices.Device],
                            files: [(rate: Int, freq: Double, url: URL)]) {
        let p = ctx.player
        for file in files {
            guard startPlay(ctx, file.url) else {
                ctx.check("输出设备-\(file.rate) Hz 起播", false); continue
            }
            let got = measure(ctx, freq: file.freq)
            ctx.check("输出设备-\(file.rate) Hz 真放出对应的音高",
                      got.level > Self.silentRMS && got.tone > 0.2,
                      String(format: "RMS %.5f 音高能量 %.3f", got.level, got.tone))
            ctx.check("输出设备-\(file.rate) Hz 时长与进度说得对",
                      p.duration > 2.5 && p.duration < 3.6 && p.currentTime > 0.1,
                      String(format: "时长 %.2f s 进度 %.2f s", p.duration, p.currentTime))
            ctx.check("输出设备-\(file.rate) Hz 没有播放故障说法",
                      p.playbackProblem == nil, p.playbackProblem ?? "")
        }
        // 高采样率播到一半换设备：重谈格式与重采样得一起成
        guard devices.count >= 2, let hi = files.last, startPlay(ctx, hi.url) else { return }
        let other = devices[1]
        let nominal = OutputDevices.nominalRate(uid: other.uid)
        guard p.setOutputDevice(uid: other.uid) == nil else {
            ctx.check("输出设备-高采样率播放中换设备", false, p.outputProblem ?? "")
            return
        }
        let got = measureSettled(ctx, freq: hi.freq)
        ctx.check("输出设备-换到另一台后 \(hi.rate) Hz 仍有声",
                  got.level > Self.silentRMS && got.tone > 0.1,
                  String(format: "RMS %.5f 音高能量 %.3f（第 %d 窗）", got.level, got.tone, got.tries))
        let after = OutputDevices.nominalRate(uid: other.uid)
        ctx.check("输出设备-换设备没改那台的硬件采样率", abs(after - nominal) < 1,
                  "\(Int(nominal)) → \(Int(after))")
        _ = p.setOutputDevice(uid: "")
        p.stop()
    }

    /// 存档这一层：新档写 UID、旧档缺字段要能升到「跟随系统默认」
    private func checkStateRoundTrip(_ ctx: SelfTestContext) {
        let legacy = #"{"trackPaths":[],"volume":0.5,"eqGains":[0,0,0,0,0,0,0,0,0,0]}"#
        guard let old = try? JSONDecoder().decode(AppState.self, from: Data(legacy.utf8)) else {
            ctx.check("输出设备-旧版存档能解码", false); return
        }
        ctx.check("输出设备-旧版存档缺 F07 字段时回到跟随系统默认",
                  old.outputDeviceUID.isEmpty && old.outputDeviceName.isEmpty && old.volume == 0.5,
                  "uid=\(old.outputDeviceUID) name=\(old.outputDeviceName)")
        var fresh = AppState()
        fresh.outputDeviceUID = "BuiltInSpeakerDevice"
        fresh.outputDeviceName = "MacBook Pro扬声器"
        guard let data = try? JSONEncoder().encode(fresh),
              let back = try? JSONDecoder().decode(AppState.self, from: data),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            ctx.check("输出设备-存档能写能读", false); return
        }
        ctx.check("输出设备-存档往返保住 UID 与名字",
                  back.outputDeviceUID == fresh.outputDeviceUID
                      && back.outputDeviceName == fresh.outputDeviceName)
        ctx.check("输出设备-存档字段只写 UID", dict["outputDeviceUID"] as? String != nil
                  && !dict.keys.contains { $0.contains("DeviceID") },
                  dict.keys.filter { $0.hasPrefix("output") }.joined(separator: ","))
    }

    // MARK: - 落盘检查（「按 UID 存」只能看字节）

    private func savedState(_ ctx: SelfTestContext) -> [String: Any]? {
        guard let data = try? Data(contentsOf: LibraryStore.selfTestStateURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return obj
    }

    private func savedUID(_ ctx: SelfTestContext) -> String? {
        savedState(ctx)?["outputDeviceUID"] as? String
    }

    private func savedHasDeviceIDKey(_ ctx: SelfTestContext) -> Bool {
        guard let keys = savedState(ctx)?.keys else { return false }
        return keys.contains { $0.contains("DeviceID") }
    }
}
