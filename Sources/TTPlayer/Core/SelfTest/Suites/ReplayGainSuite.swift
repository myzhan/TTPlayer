import Foundation
import AVFoundation

/// F02 响度均衡（ReplayGain）。
///
/// 这套断言的凭据是**实际输出链路上采到的 PCM 幅度**：标签解析对了、开关存住了、
/// 界面文案写了 ±6 dB，都证不了音量真的按那个数变了；反过来，只要幅度比值量不到
/// 期望的那一档，就说明某一环（标签、回退、限幅、串曲）没生效。
///
/// 素材全部现造在临时目录（不入库）：同一条 0.2 幅度的 880 Hz 正弦，只换标签写成什么。
/// 幅度基准取 `已关闭` 档的实测 RMS，其余档都跟它比——这样就不依赖「FLAC 应当无损」
/// 这类推演，编解码链上任何一处缩放都会落到比值上。
///
/// **口径边界**（需求要求明说）：峰值防削波只按标签 Peak 限制「标签增益 + 前置增益」的
/// 合成值。它算不到 EQ 某个频段被推高之后的瞬时峰值，所以菜单项的提示里写的是
/// 「抵消不了均衡器引起的削波」，自检也把这条当成期望行为来验（不是当成缺陷）。
struct ReplayGainSuite: SelfTestSuite {
    /// 素材的公共几何：3 s 正弦（前 1 s 留给管线起步，测的是 1.0–2.0 s 这一秒）
    private static let amplitude = 0.2
    private static let freq = 880.0
    private static let seconds = 3.0
    private static let skip = 1.0
    private static let span = 1.0
    /// -6.02 dB 就是线性 0.5000，+6.02 dB 就是 2.0000：取这两个数是为了让
    /// 「比值对不对」一眼能算，不用带一串无理数当容差
    private static let halfDB = -6.02
    private static let doubleDB = 6.02
    private static let plus12DB = 12.0

    func run(_ ctx: SelfTestContext) {
        checkTagParsing(ctx)
        checkDecisionMath(ctx)
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ttplayer-gain", isDirectory: true)
        // 上一轮（或上一次崩掉没收尾）留下的素材先扫干净：旧文件里的标签会扮成「这一轮造对了」
        try? ctx.fm.removeItem(at: root)
        try? ctx.fm.createDirectory(at: root, withIntermediateDirectories: true)
        let mat = makeMaterial(ctx, root: root)
        checkTagsFromContainer(ctx, mat: mat)
        checkTrackModeAmplitude(ctx, mat: mat)
        checkAlbumFallback(ctx, mat: mat)
        checkPeakLimiter(ctx, mat: mat)
        checkIgnoredCases(ctx, mat: mat)
        checkNoBleedToNext(ctx, mat: mat)
        checkGainTableDoesNotMoveCursor(ctx, mat: mat)
        checkIndependentOfVolumeEQ(ctx, mat: mat)
        checkRadioIgnoresGain(ctx, mat: mat)
        checkEntriesAndPersistence(ctx, mat: mat)
        restoreDefaults(ctx)
        try? ctx.fm.removeItem(at: root)
    }

    // MARK: - 素材

    private struct Material {
        let dir: URL
        /// 只有曲目标签（-6.02 dB / peak 0.5）
        var trackOnly: URL?
        /// 专辑与曲目都有（专辑 -3.01、曲目 -6.02）
        var bothTags: URL?
        /// 只有专辑标签（-3.01 / album peak 0.5）
        var albumOnly: URL?
        /// +12 dB 配 peak 0.5：限幅开着应该只推到 ×2，关掉应该到 ×3.98
        var loudPeak: URL?
        /// 标签写坏了（`abc dB`、peak 0）
        var badTag: URL?
        /// 全大写键（vorbis comment 保留原样，正好验大小写兼容）
        var upperKeys: URL?
        /// 完全没有标签的同一条正弦
        var plain: URL?
        /// 与 `plain` 逐样本相同的另一条（换个路径就是另一个身份），验串曲
        var plainCopy: URL?
        /// 带标签的 mp3：电台那段拿它当流的内容推
        var mp3Tagged: URL?

        init(dir: URL) {
            self.dir = dir
        }
    }

    /// 一次性把素材造齐。放一处是为了让「哪份素材没造成」只可能有一个入口，
    /// 不至于出现某个断言偷偷用了上一轮遗留的文件
    private func makeMaterial(_ ctx: SelfTestContext, root: URL) -> Material {
        var m = Material(dir: root)
        m.trackOnly = makeSine(ctx, dir: root, name: "track.flac", ext: "flac",
                               trackGain: "\(Self.halfDB) dB", trackPeak: "0.5")
        m.bothTags = makeSine(ctx, dir: root, name: "both.flac", ext: "flac",
                              trackGain: "\(Self.halfDB) dB", trackPeak: "0.5",
                              albumGain: "-3.01 dB", albumPeak: "0.7")
        m.albumOnly = makeSine(ctx, dir: root, name: "album.flac", ext: "flac",
                               albumGain: "-3.01 dB", albumPeak: "0.5")
        m.loudPeak = makeSine(ctx, dir: root, name: "loud.flac", ext: "flac",
                              trackGain: "\(Self.plus12DB) dB", trackPeak: "0.5")
        m.badTag = makeSine(ctx, dir: root, name: "bad.flac", ext: "flac",
                            trackGain: "abc dB", trackPeak: "0")
        m.upperKeys = makeSine(ctx, dir: root, name: "upper.flac", ext: "flac",
                               trackGain: "\(Self.halfDB) dB", keysUpper: true)
        m.plain = makeSine(ctx, dir: root, name: "plain.flac", ext: "flac")
        m.mp3Tagged = makeSine(ctx, dir: root, name: "tagged.mp3", ext: "mp3",
                               trackGain: "\(Self.halfDB) dB", trackPeak: "0.5")
        // 串曲对照要「内容完全相同、只有标签不同」的两首：拿同一份无标签文件复制一份，
        // 换个路径就是另一个身份（identityKey 按路径算）
        if let plain = m.plain {
            let copy = root.appendingPathComponent("plain_copy.flac")
            if (try? ctx.fm.copyItem(at: plain, to: copy)) != nil { m.plainCopy = copy }
        }
        return m
    }

    /// 现造一条正弦并按给定标签写盘。`keysUpper` = 用全大写键名写（容器会原样存下来）
    private func makeSine(_ ctx: SelfTestContext, dir: URL, name: String, ext: String,
                          trackGain: String? = nil, trackPeak: String? = nil,
                          albumGain: String? = nil, albumPeak: String? = nil,
                          keysUpper: Bool = false) -> URL? {
        guard let ff = ctx.locateTool("ffmpeg") else { return nil }
        let out = dir.appendingPathComponent(name)
        let prefix = keysUpper ? "REPLAYGAIN" : "replaygain"
        var args = ["-hide_banner", "-loglevel", "error",
                    "-f", "lavfi",
                    "-i", "sine=frequency=\(Self.freq):sample_rate=44100:duration=\(Self.seconds),"
                        + "volume=\(Self.amplitude)"]
        func meta(_ key: String, _ v: String?) {
            guard let v else { return }
            args += ["-metadata", "\(prefix)_\(key)=\(v)"]
        }
        meta("track_gain", trackGain)
        meta("track_peak", trackPeak)
        meta("album_gain", albumGain)
        meta("album_peak", albumPeak)
        switch ext {
        case "flac": args += ["-c:a", "flac"]
        case "mp3": args += ["-c:a", "libmp3lame", "-q", "2"]
        default: return nil
        }
        args += ["-y", out.path]
        return ctx.runTool(ff, args) ? out : nil
    }

    private func need(_ ctx: SelfTestContext, _ url: URL?, _ what: String) -> URL? {
        guard url != nil else {
            ctx.emit("[selftest] SKIP 响度均衡-\(what)（素材造不出来，缺 ffmpeg CLI）")
            return nil
        }
        return url
    }

    // MARK: - 幅度取证

    /// 一次测量的条件（模式/前置增益/限幅），跟 `measure` 配套用
    private struct Cond {
        var mode: ReplayGainMode = .off
        var preamp: Float = 0
        var limit = true
        var eqPreGain: Float?
        var muted = false
        var gapless = true
    }

    /// 按条件播 `url`，从实际输出链上采一段左声道并算 RMS。返回 nil 是没播起来。
    /// 起点跳过前 1 s：引擎的预排窗口只有 0.7 s 上下，头一点还可能是上一次装载留下的
    /// 旧增益缓冲，拿它算平均会把好行为测成差几个百分点
    private func measure(_ ctx: SelfTestContext, _ url: URL, _ c: Cond) -> Double? {
        let p = ctx.player
        p.stop()
        p.setGaplessPlay(c.gapless)
        p.setReplayGainMode(c.mode)
        p.setReplayGainPreamp(c.preamp)
        p.setReplayGainPeakLimit(c.limit)
        if let g = c.eqPreGain { p.setPreGain(g) }
        if c.muted && !p.isMuted { p.toggleMute() }
        p.setMode(.order)
        p.clearPlaylist()
        guard p.addFiles([url]) >= 1 else { return nil }
        _ = ctx.waitUntil(4) { (p.playlist.tracks.first?.duration ?? 0) > 0 }
        p.playRowAt(0)
        let live = ctx.waitUntil(5) { p.isPlaying }
        guard live else { return nil }
        ctx.pump(Self.skip)
        let cap = ctx.captureLeftChannel(p, seconds: Self.span)
        guard cap.samples.count > 4_000 else { return nil }
        return ReplayGainSuite.rms(cap.samples)
    }

    /// 两趟测量之比（跳过头 0.05 s 的采集毛刺）
    private static func rms(_ s: [Float]) -> Double {
        var s2 = 0.0
        var n = 0
        for v in s.dropFirst(2_205) { s2 += Double(v) * Double(v); n += 1 }
        return n > 0 ? (s2 / Double(n)).squareRoot() : 0
    }

    /// 比值断言：期望值与实测值差多少个百分点
    private func ratio(_ ctx: SelfTestContext, _ name: String, _ url: URL,
                       baseline: Cond, test: Cond, want: Double, tol: Double = 0.03) {
        guard let base = measure(ctx, url, baseline) else {
            ctx.check(name, false, "基准没播起来"); return
        }
        guard let got = measure(ctx, url, test) else {
            ctx.check(name, false, "对照组没播起来"); return
        }
        let r = base > 0 ? got / base : 0
        ctx.emit(String(format: "[selftest] %@：基准 RMS=%.5f 实测=%.5f 比值=%.4f 期望=%.4f",
                        name, base, got, r, want))
        ctx.check(name, abs(r - want) <= want * tol,
                  String(format: "比值=%.4f 期望=%.4f 容差=%.0f%%", r, want, tol * 100))
    }

    // MARK: - 标签解析（纯逻辑，先把边界钉住）

    private func checkTagParsing(_ ctx: SelfTestContext) {
        func tags(_ kv: [String: String]) -> ReplayGainTags { ReplayGainTags(tags: kv) }
        let t = tags(["REPLAYGAIN_TRACK_GAIN": "-6.02 dB", "replaygain_track_peak": "0.5"])
        ctx.check("响度均衡-全大写键读得出（vorbis 原样保留大小写）",
                  t.trackGain == -6.02 && t.trackPeak == 0.5,
                  "gain=\(String(describing: t.trackGain)) peak=\(String(describing: t.trackPeak))")
        let mix = tags(["Replaygain_Album_Gain": "+3.01dB", "ReplayGain_ALBUM_PEAK": "-6.02 dB"])
        ctx.check("响度均衡-大小写混排与 + 号都认",
                  mix.albumGain == 3.01, "albumGain=\(String(describing: mix.albumGain))")
        ctx.check("响度均衡-Peak 写成 dB 时换算回线性",
                  mix.albumPeak != nil && abs((mix.albumPeak ?? 0) - 0.5) < 0.001,
                  "peak=\(String(describing: mix.albumPeak))")
        let comma = tags(["replaygain_track_gain": "-0,5 dB"])
        ctx.check("响度均衡-逗号小数点也认", comma.trackGain == -0.5,
                  "gain=\(String(describing: comma.trackGain))")

        let garbage: [(String, String)] = [
            ("abc dB", "读不出数字"), ("nan", "非有限"), ("inf", "非有限"),
            ("", "空值"), ("99", "超出 ±30 dB"),
        ]
        var leaked: [String] = []
        for (v, why) in garbage where tags(["replaygain_track_gain": v]).trackGain != nil {
            leaked.append("\(v)（\(why)）")
        }
        ctx.check("响度均衡-非法增益一律当没读到", leaked.isEmpty, leaked.joined(separator: " / "))

        let badPeaks = ["0", "-1", "abc", "nan", "1e9"]
        let peakLeak = badPeaks.filter { tags(["replaygain_track_peak": $0]).trackPeak != nil }
        ctx.check("响度均衡-非法峰值一律当没读到", peakLeak.isEmpty, peakLeak.joined(separator: " / "))
        ctx.check("响度均衡-没有标签时四份都是 nil",
                  tags([:]).isEmpty && tags(["title": "x"]).isEmpty)
        // 「有标签且是 0 dB」与「没标签」必须分得开：回退路径全靠这个差别
        let zero = tags(["replaygain_track_gain": "0 dB"])
        ctx.check("响度均衡-0 dB 是标签不是缺失", zero.trackGain == 0 && !zero.isEmpty)
    }

    // MARK: - 增益决定的算术（纯逻辑）

    /// 幅度取证要文件、要播、要采，一轮好几秒；这几条只管 `decide` 的算术，
    /// 盖的是真实录音不容易凑齐的组合（比如「没有标签却把前置增益推到 +12 dB」）
    private func checkDecisionMath(_ ctx: SelfTestContext) {
        let none = ReplayGainTags(tags: [:])
        let trackOnly = ReplayGainTags(tags: ["replaygain_track_gain": "-6.02 dB"])
        let albumOnly = ReplayGainTags(tags: ["replaygain_album_gain": "-6.02 dB"])
        let peakOnly = ReplayGainTags(tags: ["replaygain_track_peak": "0.5"])
        let bad = ReplayGainTags(tags: ["replaygain_track_gain": "99"])

        func d(_ t: ReplayGainTags?, _ mode: ReplayGainMode, _ pre: Double,
               limit: Bool = true, radio: Bool = false) -> ReplayGainDecision {
            ReplayGainDecision.decide(tags: t, mode: mode, preamp: pre,
                                      peakLimit: limit, isRadio: radio)
        }

        // 没有有效 Gain 就没有「标签 + 前置增益」这一步：preamp 单独加上去等于
        // 拿响度均衡去推一首没测过的曲子，而文案还在说「不动音量」
        let bare = d(none, .track, 12)
        ctx.check("响度均衡决定-无标签时前置增益不掺和",
                  bare.source == .noTag && bare.linear == 1 && bare.totaldB == 0
                      && bare.summaryText.contains("不动音量"),
                  "linear=\(bare.linear) total=\(bare.totaldB) text=\(bare.summaryText)")
        let combos: [(String, ReplayGainDecision)] = [
            ("tags 为 nil", d(nil, .track, 12)),
            ("空标签", d(none, .album, 12)),
            ("非法增益", d(bad, .track, 6)),
            ("只有 Peak", d(peakOnly, .track, 6)),
            ("专辑模式下只有专辑标签、曲目模式里没曲目标签", d(albumOnly, .track, -6)),
        ]
        let pushed = combos.filter { $0.1.linear != 1 || $0.1.source != .noTag }
        ctx.check("响度均衡决定-五类「拿不出可用增益」都是单位增益", pushed.isEmpty,
                  pushed.map { "\($0.0)→linear=\($0.1.linear)/\($0.1.source.rawValue)" }
                      .joined(separator: " / "))
        // 有标签时前置增益照旧与标签相加，正负两个方向都要对
        let cancel = d(trackOnly, .track, 6.02)
        ctx.check("响度均衡决定-有标签时前置增益与标签相加",
                  abs(cancel.linear - 1.0) < 0.001 && abs(cancel.totaldB) < 0.001,
                  "linear=\(cancel.linear) total=\(cancel.totaldB)")
        let push = d(trackOnly, .track, 12, limit: false)
        ctx.check("响度均衡决定-有标签时推得动也压得下",
                  push.linear > 1.9 && push.linear < 2.0
                      && d(trackOnly, .track, -6.02, limit: false).linear > 0.24
                      && d(trackOnly, .track, -6.02, limit: false).linear < 0.26,
                  "push=\(push.linear)")
        // 回退链与限幅这两条老路不能被上面的 guard 改坏
        let fallback = d(trackOnly, .album, 0)
        ctx.check("响度均衡决定-专辑缺失退回曲目仍按曲目标签走",
                  fallback.source == .albumToTrack && abs(fallback.linear - 0.5) < 0.001,
                  "source=\(fallback.source.rawValue) linear=\(fallback.linear)")
        let limited = d(ReplayGainTags(tags: ["replaygain_track_gain": "+12 dB",
                                              "replaygain_track_peak": "0.5"]), .track, 0)
        ctx.check("响度均衡决定-Peak 把过推压到不越满量程",
                  limited.limited && abs(limited.linear - 2.0) < 0.001,
                  "linear=\(limited.linear) limited=\(limited.limited)")
        ctx.check("响度均衡决定-电台与关闭模式连前置增益也不加",
                  d(trackOnly, .track, 12, radio: true).linear == 1
                      && d(trackOnly, .off, 12).linear == 1
                      && d(nil, .track, 12, radio: true).source == .radio,
                  "radio=\(d(trackOnly, .track, 12, radio: true).linear) off=\(d(trackOnly, .off, 12).linear)")
    }

    // MARK: - 标签真从容器里读出来

    private func checkTagsFromContainer(_ ctx: SelfTestContext, mat: Material) {
        guard let a = need(ctx, mat.trackOnly, "容器标签读取") else { return }
        let others = [mat.badTag, mat.upperKeys, mat.plain].compactMap { $0 }
        guard others.count == 3 else {
            ctx.check("响度均衡-容器标签读取（素材造齐）", false, "只造出 \(others.count)/3 份"); return
        }
        let p = ctx.player
        p.setReplayGainMode(.off)
        p.clearPlaylist()
        guard p.addFiles([a] + others) >= 4 else {
            ctx.check("响度均衡-容器标签读取（进得来）", false); return
        }
        // 按文件找回入表后那条 Track（force unwrap 会把「没入表」误报成崩溃）
        func track(_ url: URL?) -> Track? {
            guard let path = url?.path else { return nil }
            return p.playlist.tracks.first { $0.url.path == path }
        }
        let got = ctx.waitUntil(8) { p.playlist.tracks.allSatisfy { $0.replayGainTags != nil } }
        ctx.check("响度均衡-入表后标签已解析", got,
                  "tags=\(p.playlist.tracks.map { $0.replayGainTags == nil ? "nil" : "有" }.description)")
        let t0 = p.playlist.tracks.first
        ctx.check("响度均衡-flac 容器里读到 -6.02 dB",
                  t0?.replayGainTags?.trackGain == Self.halfDB,
                  "gain=\(String(describing: t0?.replayGainTags?.trackGain))")
        let t1 = track(mat.badTag)
        ctx.check("响度均衡-坏标签入表后是「没标签」不是 0",
                  t1?.replayGainTags?.trackGain == nil && t1?.replayGainTags?.trackPeak == nil,
                  "gain=\(String(describing: t1?.replayGainTags?.trackGain))")
        let t2 = track(mat.upperKeys)
        ctx.check("响度均衡-全大写键的真文件也读得出",
                  t2?.replayGainTags?.trackGain == Self.halfDB,
                  "gain=\(String(describing: t2?.replayGainTags?.trackGain))")
        let t3 = track(mat.plain)
        ctx.check("响度均衡-无标签文件标成「读过了但没有」",
                  t3?.replayGainTags != nil && t3?.replayGainTags?.isEmpty == true)
        p.clearPlaylist()
    }

    // MARK: - 幅度：Track 模式

    private func checkTrackModeAmplitude(_ ctx: SelfTestContext, mat: Material) {
        guard let a = need(ctx, mat.trackOnly, "按曲目增益幅度") else { return }
        // -6.02 dB 就是 ×0.5。这一条是整个 F02 的主证据：标签、决定、相乘三环都得上对链路
        ratio(ctx, "响度均衡-按曲目 -6.02 dB 输出减半", a,
              baseline: Cond(), test: Cond(mode: .track), want: 0.5)
        guard let b = need(ctx, mat.bothTags, "有标签也只做一次") else { return }
        ratio(ctx, "响度均衡-按曲目时专辑标签不掺和", b,
              baseline: Cond(), test: Cond(mode: .track), want: 0.5)
    }

    // MARK: - 幅度：Album 模式与回退

    private func checkAlbumFallback(_ ctx: SelfTestContext, mat: Material) {
        guard let both = need(ctx, mat.bothTags, "按专辑优先") else { return }
        // 专辑 -3.01 dB = ×0.7065：专辑标签在场时它必须赢过曲目那份
        ratio(ctx, "响度均衡-按专辑优先用专辑增益", both,
              baseline: Cond(), test: Cond(mode: .album), want: pow(10, -3.01 / 20))
        guard let albumOnly = need(ctx, mat.albumOnly, "只有专辑标签") else { return }
        ratio(ctx, "响度均衡-只有专辑标签时按专辑生效", albumOnly,
              baseline: Cond(), test: Cond(mode: .album), want: pow(10, -3.01 / 20))
        // 按曲目模式下这份文件没曲目标签 → 不该动
        ratio(ctx, "响度均衡-只有专辑标签时按曲目不动", albumOnly,
              baseline: Cond(), test: Cond(mode: .track), want: 1.0)
        guard let trackOnly = need(ctx, mat.trackOnly, "专辑缺失回退曲目") else { return }
        ratio(ctx, "响度均衡-专辑缺失回退曲目", trackOnly,
              baseline: Cond(), test: Cond(mode: .album), want: 0.5)
        guard let plain = need(ctx, mat.plain, "两者都缺回退 0 dB") else { return }
        ratio(ctx, "响度均衡-两者都缺就是 0 dB", plain,
              baseline: Cond(), test: Cond(mode: .album), want: 1.0)
    }

    // MARK: - 前置增益与峰值防削波

    private func checkPeakLimiter(_ ctx: SelfTestContext, mat: Material) {
        guard let loud = need(ctx, mat.loudPeak, "峰值限幅") else { return }
        // +12 dB 想推 ×3.98，Peak=0.5 说「满量程只有它的一半」：限幅该把它压到 ×2.0
        ratio(ctx, "响度均衡-Peak 把过推压到不越满量程", loud,
              baseline: Cond(), test: Cond(mode: .track, limit: true), want: 2.0)
        ratio(ctx, "响度均衡-关掉限幅就照标签推", loud,
              baseline: Cond(), test: Cond(mode: .track, limit: false), want: pow(10, 1.2 / 2))
        // 前置增益独立于标签：-6.02 的曲子 +6.02 恰好回到基准
        guard let a = need(ctx, mat.trackOnly, "前置增益") else { return }
        ratio(ctx, "响度均衡-前置增益与标签相加", a,
              baseline: Cond(), test: Cond(mode: .track, preamp: Float(-Self.halfDB)), want: 1.0)
        ratio(ctx, "响度均衡-关闭模式时前置增益不掺和", a,
              baseline: Cond(), test: Cond(mode: .off, preamp: 6), want: 1.0)
        // 非法 Peak（0）不能当「峰值是 0」把声音压到无声，只能当没有峰值信息
        guard let bad = need(ctx, mat.badTag, "非法峰值") else { return }
        ratio(ctx, "响度均衡-非法峰值不当 0 用", bad,
              baseline: Cond(), test: Cond(mode: .track), want: 1.0)
    }

    // MARK: - 不该动的东西

    private func checkIgnoredCases(_ ctx: SelfTestContext, mat: Material) {
        // 两趟都把前置增益推到 +6 dB：旧写法会把它当成「标签是 0 dB」接着加，
        // 无标签与坏标签的曲子能拿到近 ×2 的推量，与「不动音量」的文案直接矛盾
        guard let bad = need(ctx, mat.badTag, "坏标签不动音量") else { return }
        ratio(ctx, "响度均衡-坏标签文件不动音量（带前置增益也不动）", bad,
              baseline: Cond(), test: Cond(mode: .track, preamp: 6), want: 1.0)
        guard let plain = need(ctx, mat.plain, "无标签文件不动音量") else { return }
        ratio(ctx, "响度均衡-无标签文件不动音量（带前置增益也不动）", plain,
              baseline: Cond(), test: Cond(mode: .album, preamp: 6), want: 1.0)
        // 需求点名「不自动分析」：没有标签的文件不能因为开了模式就被改响
        let p = ctx.player
        let before = p.volume
        let mutedBefore = p.isMuted
        _ = measure(ctx, plain, Cond(mode: .track, preamp: 6))
        ctx.check("响度均衡-不改用户音量与静音", p.volume == before && p.isMuted == mutedBefore,
                  "volume=\(p.volume) muted=\(p.isMuted)")
        // 「不自动分析」要拿这曲子的决定来看：没有标签时它得说「不动音量」，线性是 1
        // （拿带着 +6 dB 前置增益的档位来看，才能证「前置增益没有单独跑起来」）
        let bareTrack = p.playlist.tracks.first { $0.url.path == plain.path }
        let decision = bareTrack.map { p.replayGainDecision(for: $0) }
        ctx.check("响度均衡-不自家分析（无标签就是 nil 增益）",
                  decision?.linear == 1 && decision?.source == .noTag,
                  "decision=\(decision?.summaryText ?? "查不到曲")")
    }

    // MARK: - 增益不串下一首

    /// A 带 -6.02 dB、B 是同一条正弦但没标签：两首连播时衔接处必须「阶梯掉下去又回到原样」。
    /// 比值取 B/A：A 减半、B 不动 → B/A 应为 2.0，反过来排就是 0.5。
    /// 串曲（把 A 的增益带到 B）会直接把这个比值测成 1.0
    private func checkNoBleedToNext(_ ctx: SelfTestContext, mat: Material) {
        guard let a = need(ctx, mat.trackOnly, "增益不串下一首"),
              let b = need(ctx, mat.plainCopy, "增益不串下一首") else { return }
        let r = measurePairRatio(ctx, first: a, second: b)
        ctx.check("响度均衡-标签增益不串到无标签的下一曲",
                  r != nil && abs(r!.ratio - 2.0) <= 0.06,
                  String(format: "前曲电平=%.5f 后曲电平=%.5f 比值=%.4f 期望=2.0",
                         r?.before ?? -1, r?.after ?? -1, r?.ratio ?? -1))
        let rev = measurePairRatio(ctx, first: b, second: a)
        ctx.check("响度均衡-无标签也不把下一曲推回去",
                  rev != nil && abs(rev!.ratio - 0.5) <= 0.03,
                  String(format: "前曲电平=%.5f 后曲电平=%.5f 比值=%.4f 期望=0.5",
                         rev?.before ?? -1, rev?.after ?? -1, rev?.ratio ?? -1))
    }

    /// 排增益表只是「读一眼下一候选」，不能把播放游标挪走（实测踩过：拿了 `focus(id:)`，
    /// 预取一到位就听的还是 A、显示已经跳到 B）。用无缝预取当引信：先把候选排好，
    /// 再改三个设置，看当前曲目动不动
    private func checkGainTableDoesNotMoveCursor(_ ctx: SelfTestContext, mat: Material) {
        guard let a = need(ctx, mat.trackOnly, "排增益表不动游标"),
              let b = need(ctx, mat.plainCopy, "排增益表不动游标") else { return }
        let p = ctx.player
        p.stop(); p.setGaplessPlay(true); p.setMode(.order); p.clearPlaylist()
        guard p.addFiles([a, b]) >= 2 else { return }
        _ = ctx.waitUntil(4) { p.playlist.tracks.count >= 2
            && (p.playlist.tracks.first?.duration ?? 0) > 0 }
        p.playRowAt(0)
        let armed = ctx.waitUntil(4) { !p.nextPreparedKey.isEmpty }
        guard armed, let first = p.currentTrack else {
            ctx.check("响度均衡-改设置不挪播放游标（没能起播）", false,
                      "prepared=\(p.nextPreparedKey)"); return
        }
        p.setReplayGainMode(.album)
        p.setReplayGainPreamp(3)
        p.setReplayGainPeakLimit(false)
        ctx.check("响度均衡-改增益设置不挪播放游标",
                  p.currentTrack?.identityKey == first.identityKey,
                  "本来在 \(first.url.lastPathComponent)，现在=\(p.currentTrack?.url.lastPathComponent ?? "nil")")
        p.setReplayGainMode(.off)
        p.setReplayGainPreamp(0)
        p.setReplayGainPeakLimit(true)
        p.stop()
        p.clearPlaylist()
    }

    /// 无缝开着连播两首，返回「后一首的电平 / 前一首的电平」。
    ///
    /// 一次连续采集跨过衔接点，再在前后各取一段**块电平中位数**：不能拿区间均值，
    /// 均值会把接缝附近混着两首内容的块一起算进去（实测把 2.0 测成 1.5）；
    /// 也不能分两次采集：开播到真出声的延迟不固定（预排窗口 0.7 s 上下），
    /// 分两次就没法保证第二次真的落在后一首里。中位数 + 给足的窗口把这点抖动吃掉
    private func measurePairRatio(_ ctx: SelfTestContext, first: URL,
                                  second: URL) -> (ratio: Double, before: Double, after: Double)? {
        let p = ctx.player
        p.stop()
        p.setGaplessPlay(true)
        p.setReplayGainMode(.track)
        p.setReplayGainPreamp(0)
        p.setReplayGainPeakLimit(true)
        p.setMode(.order)
        p.clearPlaylist()
        guard p.addFiles([first, second]) >= 2 else { return nil }
        _ = ctx.waitUntil(4) { p.playlist.tracks.count >= 2
            && (p.playlist.tracks.first?.duration ?? 0) > 0 }
        p.playRowAt(0)
        let rolling = ctx.waitUntil(5) { p.isPlaying }
        guard rolling else { return nil }
        // 两首各 3 s：采集跨开播后 1.2–5.8 s，前一首取 1.8–2.8 s、后一首取 3.8–5.6 s
        let cap = ctx.captureLeftChannel(p, seconds: 4.6)
        let before = ReplayGainSuite.plateau(cap.samples, from: 0.6, to: 1.6, sampleRate: cap.sampleRate)
        let after = ReplayGainSuite.plateau(cap.samples, from: 2.6, to: 4.4, sampleRate: cap.sampleRate)
        ctx.emit("[selftest] 串曲采集电平（每 0.25 s 一块，自开播后 1.2 s 起）："
                 + ReplayGainSuite.profile(cap.samples, sampleRate: cap.sampleRate, blockSeconds: 0.25))
        p.stop()
        guard before > 0 else { return (0, before, after) }
        return (after / before, before, after)
    }

    /// 一小组样本的 RMS（整段都算，不像 `rms` 那样跳头）
    private static func blockRMS(_ s: ArraySlice<Float>) -> Double {
        guard !s.isEmpty else { return 0 }
        var acc = 0.0
        for v in s { acc += Double(v) * Double(v) }
        return (acc / Double(s.count)).squareRoot()
    }

    /// 窗口里的块电平中位数（块长 1024 样本 ≈ 23 ms）
    private static func plateau(_ s: [Float], from: Double, to: Double, sampleRate: Double) -> Double {
        let lo = max(0, Int(from * sampleRate))
        let hi = min(s.count, Int(to * sampleRate))
        guard hi - lo >= 4096 else { return 0 }
        var levels: [Double] = []
        var i = lo
        while i + 1024 <= hi { levels.append(blockRMS(s[i..<(i + 1024)])); i += 1024 }
        guard !levels.isEmpty else { return 0 }
        levels.sort()
        return levels[levels.count / 2]
    }

    /// 粗电平剖面：每段取块电平最大值，用来看衔接点到底落在采集窗的哪一格（诊断用）
    private static func profile(_ s: [Float], sampleRate: Double, blockSeconds: Double) -> String {
        let step = max(1, Int(blockSeconds * sampleRate))
        var out: [String] = []
        var i = 0
        while i < s.count {
            let seg = s[i..<min(i + step, s.count)]
            var best = 0.0
            var j = seg.startIndex
            while j + 1024 <= seg.endIndex { best = max(best, blockRMS(seg[j..<(j + 1024)])); j += 1024 }
            out.append(String(format: "%.4f", best))
            i += step
        }
        return out.joined(separator: " ")
    }

    // MARK: - 与音量/静音/EQ 各管各的

    private func checkIndependentOfVolumeEQ(_ ctx: SelfTestContext, mat: Material) {
        guard let a = need(ctx, mat.trackOnly, "与静音独立") else { return }
        ratio(ctx, "响度均衡-静音时增益照旧算（两路各管各的）", a,
              baseline: Cond(muted: true), test: Cond(mode: .track, muted: true), want: 0.5)
        let p = ctx.player
        if p.isMuted { p.toggleMute() }
        // EQ 前置 +6 dB 之后，ReplayGain 的比值仍然是 0.5：说明两者是相乘的两级，
        // 不是「谁覆盖了谁」
        guard let b = need(ctx, mat.trackOnly, "与 EQ 各自独立") else { return }
        ratio(ctx, "响度均衡-EQ 抬高地平线时增益比不变", b,
              baseline: Cond(eqPreGain: 6), test: Cond(mode: .track, eqPreGain: 6), want: 0.5)
        _ = measure(ctx, b, Cond(eqPreGain: 0))     // EQ 复位，别把 +6 留给后面的套件
    }

    // MARK: - 电台不做响度均衡

    /// 本地 HTTP 流推同一条带标签的 mp3：电台走的是 `enqueueRadio` 那条路，
    /// 不该被标签与前置增益碰过。凭据是「同一份流内容，设置怎么改 RMS 都不动」
    private func checkRadioIgnoresGain(_ ctx: SelfTestContext, mat: Material) {
        // 接电台之前先播一段本地文件（同是 44.1 kHz 立体声）：把节点连接留在与流相同的
        // 格式上。这一步不是凑数——引擎曾因格式相同时不重连而干脆不给电台开闸，
        // 电台一声不响（实测），这种顺序敏感的场景必须自己摆出来才能钉住
        if let plain = mat.plain { _ = measure(ctx, plain, Cond()) }
        guard let mp3 = need(ctx, mat.mp3Tagged, "电台不应用增益") else { return }
        let srv = LocalRadioStream(file: mp3)
        guard let stream = srv.start() else {
            ctx.emit("[selftest] SKIP 响度均衡-电台不应用增益（本地流起不来）"); return
        }
        defer { srv.stop() }
        let p = ctx.player
        /// 没出声时的现场：光说「流没出声」下轮还是猜，把播放器与服务器两侧的说法一起抄下来
        var whySilent = ""
        func radioRMS(_ c: Cond) -> Double? {
            p.stop()
            p.setReplayGainMode(c.mode)
            p.setReplayGainPreamp(c.preamp)
            p.setReplayGainPeakLimit(c.limit)
            p.clearPlaylist()
            if let note = p.addRadio(stream.absoluteString, playNow: true) {
                whySilent = "加不进来：\(note)"
                return nil
            }
            let sounding = ctx.waitUntil(15) { p.isRadio && p.isPlaying && p.engine.radioHasSound }
            whySilent = "状态=\(p.radioStateText) isRadio=\(p.isRadio) isPlaying=\(p.isPlaying) "
                + "有声=\(p.engine.radioHasSound) 连接次数=\(srv.connections) "
                + "推出字节=\(srv.servedBytes) 掉线由=\(srv.lastDropBy.isEmpty ? "没断" : srv.lastDropBy)"
            guard sounding else { return nil }
            ctx.pump(Self.skip)
            let cap = ctx.captureLeftChannel(p, seconds: Self.span)
            return cap.samples.count > 4_000 ? ReplayGainSuite.rms(cap.samples) : nil
        }
        guard let base = radioRMS(Cond()) else {
            ctx.check("响度均衡-电台不应用增益（流没出声）", false, whySilent); return
        }
        guard let loud = radioRMS(Cond(mode: .track, preamp: 12)) else {
            ctx.check("响度均衡-电台不应用增益（换档后没出声）", false, whySilent); return
        }
        let r = base > 0 ? loud / base : 0
        ctx.emit(String(format: "[selftest] 电台响度：关闭档 RMS=%.5f 按曲目+12 dB 档 RMS=%.5f 比值=%.4f",
                        base, loud, r))
        ctx.check("响度均衡-电台不应用标签增益与前置增益", abs(r - 1) <= 0.08,
                  String(format: "比值=%.4f 期望=1.0", r))
        // 决定本身也要说清「电台这条路不参与」，属性面板读的就是它
        if let t = p.currentTrack {
            let d = p.replayGainDecision(for: t)
            ctx.check("响度均衡-电台的增益决定是「不应用」",
                      d.source == .radio && d.linear == 1, d.summaryText)
        }
        p.stop()
        p.clearPlaylist()
    }

    // MARK: - 入口、状态显示与落盘

    private func checkEntriesAndPersistence(_ ctx: SelfTestContext, mat: Material) {
        let p = ctx.player
        let menu = ctx.main.buildPopupMenu()
        var bad: [String] = []
        for mode in ReplayGainMode.allCases {
            let item = menu.items.first { $0.title == mode.displayName }
            if item?.action != #selector(MainWindowController.selectReplayGainMode(_:)) {
                bad.append("\(mode.displayName) 没有入口")
            }
        }
        let peak = menu.items.first { $0.title.contains("峰值防削波") }
        if peak?.action != #selector(MainWindowController.toggleReplayPeakLimit) {
            bad.append("峰值防削波没有入口")
        }
        let slider = menu.items.first { $0.view is GainSliderView }
        if slider == nil { bad.append("前置增益滑块不在菜单里") }
        ctx.check("响度均衡-设置入口齐全（模式/限幅/滑块）", bad.isEmpty, bad.joined(separator: " / "))
        ctx.check("响度均衡-限幅提示说明管不了 EQ",
                  peak?.toolTip?.contains("均衡器") == true, peak?.toolTip ?? "无")

        // 菜单项点下去要真改状态（不是只有标题）
        p.setReplayGainMode(.off)
        if let item = menu.items.first(where: { $0.title == ReplayGainMode.album.displayName }),
           let action = item.action {
            ctx.main.perform(action, with: item)
        }
        ctx.check("响度均衡-菜单能选按专辑", p.replayGainMode == .album, "现在=\(p.replayGainMode)")
        if let action = peak?.action { ctx.main.perform(action, with: peak) }
        ctx.check("响度均衡-菜单能翻峰值防削波", p.replayGainPeakLimit == false,
                  "现在=\(p.replayGainPeakLimit)")
        if let action = peak?.action { ctx.main.perform(action, with: peak) }

        // 滑块：-12…+12 且越界夹住（需求给的硬边界）
        (slider?.view as? GainSliderView)?.apply(20)
        ctx.check("响度均衡-滑块越界夹到 +12", abs(p.replayGainPreamp - 12) < 0.01,
                  "preamp=\(p.replayGainPreamp)")
        (slider?.view as? GainSliderView)?.apply(-20)
        ctx.check("响度均衡-滑块越界夹到 -12", abs(p.replayGainPreamp + 12) < 0.01,
                  "preamp=\(p.replayGainPreamp)")
        (slider?.view as? GainSliderView)?.apply(6.02)
        ctx.check("响度均衡-滑块值直接进设置", abs(p.replayGainPreamp - 6.02) < 0.01,
                  "preamp=\(p.replayGainPreamp)")

        // 设置要存住：旧档缺这几项时按默认（关 / 0 dB / 限幅开）
        let saved = LibraryStore.load()
        ctx.check("响度均衡-设置落盘", saved.replayGainMode == ReplayGainMode.album.rawValue
                  && saved.replayGainPeakLimit && abs(saved.replayGainPreamp - 6.02) < 0.01,
                  "mode=\(saved.replayGainMode) preamp=\(saved.replayGainPreamp) limit=\(saved.replayGainPeakLimit)")
        let legacy = "{\"trackPaths\":[],\"volume\":0.5}"
        if let data = legacy.data(using: .utf8),
           let st = try? JSONDecoder().decode(AppState.self, from: data) {
            ctx.check("响度均衡-旧档缺字段时按默认关闭",
                      st.replayGainMode == 0 && st.replayGainPreamp == 0 && st.replayGainPeakLimit)
        } else {
            ctx.check("响度均衡-旧档缺字段时按默认关闭", false, "旧档解不开")
        }

        // 属性面板那一行要能回答「加了多少、回退到哪、有没有标签」
        guard let a = mat.trackOnly, let plain = mat.plain else { return }
        p.setReplayGainMode(.track)
        p.setReplayGainPreamp(0)
        p.clearPlaylist()
        guard p.addFiles([a, plain]) >= 2 else { return }
        _ = ctx.waitUntil(8) { p.playlist.tracks.allSatisfy { $0.replayGainTags != nil } }
        let tagged = p.playlist.tracks.first { $0.url.path == a.path }
        let bare = p.playlist.tracks.first { $0.url.path == plain.path }
        let line1 = tagged.map { p.replayGainStatusText(for: $0, applied: false) } ?? ""
        ctx.check("响度均衡-属性行写明按曲目降了多少",
                  line1.contains("-6.0 dB"), line1)
        let line2 = bare.map { p.replayGainStatusText(for: $0, applied: false) } ?? ""
        ctx.check("响度均衡-属性行说清没标签", line2.contains("没有 ReplayGain 标签"), line2)
        let extra = tagged.map { p.propertyExtraLines(for: $0) } ?? []
        ctx.check("响度均衡-属性面板读得到响度行",
                  extra.contains { $0.0 == "响度均衡" }, extra.map { $0.0 }.description)
        p.setReplayGainMode(.album)
        let line3 = tagged.map { p.replayGainStatusText(for: $0, applied: false) } ?? ""
        ctx.check("响度均衡-属性行把回退结果也写出来",
                  line3.contains("退回曲目"), line3)
    }

    /// 收尾把设置还原：默认关闭 + 0 dB + 限幅开，别把 +12 dB 留给后面的套件
    private func restoreDefaults(_ ctx: SelfTestContext) {
        let p = ctx.player
        p.stop()
        p.setReplayGainMode(.off)
        p.setReplayGainPreamp(0)
        p.setReplayGainPeakLimit(true)
        p.setGaplessPlay(true)
        if p.isMuted { p.toggleMute() }
    }
}
