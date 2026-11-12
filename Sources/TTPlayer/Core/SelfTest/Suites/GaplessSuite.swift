import Foundation
import AVFoundation

/// F01 无缝播放（Gapless）。
///
/// 这套断言只认从**实际输出链路**上抄下来的 PCM：衔接处少了帧、多了帧、插了一段静音，
/// 在帧计数与音高序列上都藏不住。播放计时一直涨、界面切歌切得对，都证不了无缝。
///
/// 素材全部现造在临时目录（音频不入库）：每 0.5 秒换一个音高的阶梯信号，切成前后两半
/// （前半块序 0-3，后半接着排 4-7），再各自转成 wav / flac / mp3 / m4a。
///
/// 取证靠两件事：
/// 1. **帧级标记**——每半都在本段 0.9 s 处埋一个满幅短促（7833 Hz、512 样本）。采集流里
///    两个标记的下标差就是「前半的真实长度」，缺帧/重帧/插静音都会直接落在差值上。
///    只用阶梯音的话，粒度是半秒，测不出 1105 样本（25 ms）这一级的错。
/// 2. **段序读数**——每个 0.5 s 块的中心问一次「这段声音是哪个音高」，跳号就是漏段、
///    重复就是重播。
///
/// **实际支持边界**（本机 FFmpeg 9 + AVAudioEngine 实测，不是推演）：
/// - 接得住：同采样率、同声道、同输出格式的本地文件（wav / flac / mp3 / m4a 都验过），
///   以及同一个镜像里的相邻 CUE 分轨（复用已开的解码器，不重开文件）。
/// - 回退硬切（听得多一下停顿，不崩不重播不串曲）：下一曲采样率或声道数不同（接上要重
///   连音频图，重连必停节点）、下一曲文件打不开、电台（无限流，没有下一曲可排）。
///   每一种都把原因写进 `gaplessNote`，属性面板与自检都读得到。
/// - 编码延迟一份都不重复裁：FFmpeg 9 对 lame 的 mp3 已在解码器内部丢完 priming（并把
///   pts 跟着抬 1105），aac 的 1024 只是容器记账。可听基准只认「真正交出来的第一帧的 pts」
///   （见 `FFmpegDecoder.GaplessInfo` 与 `primeAudibleBase`）。
struct GaplessSuite: SelfTestSuite {
    /// 素材的几何参数只有一份，在 `SelfTestContext.seam*`（生成器和这里都要用，两处各写
    /// 各的改一处就会悄悄对不上）。下面这些是别名，不是第二份定义。
    private static let block = SelfTestContext.seamBlock
    private static let baseFreq = SelfTestContext.seamBaseFreq
    private static let stepFreq = SelfTestContext.seamStepFreq
    /// 标记在本段内的位置（秒）：必须晚于引擎的预排窗口（0.7 s），否则采集接不上第一次标记
    private static let clickAt = SelfTestContext.seamClickAt
    /// 半曲长度（秒）：故意等于标记周期 —— 每一半正好落一个标记，4 个音高块够验段序，
    /// 也不把全量自检拖长
    private static let half = SelfTestContext.seamClickEvery
    /// 采多少秒：前半 2.0 s + 后半到第二个标记（0.9 s）后再留一点
    private static let capture = 3.6

    func run(_ ctx: SelfTestContext) {
        let root = tempRoot(ctx)
        let mat = Material(ctx: ctx, root: root)
        checkFFmpegAccounting(ctx, mat: mat)
        checkSeam(ctx, mat: mat)
        checkHardCutWhenOff(ctx, mat: mat)
        checkSampleRateFallback(ctx, mat: mat)
        checkBrokenFallback(ctx, mat: mat)
        checkSingleLoop(ctx, mat: mat)
        checkCueAdjacent(ctx, mat: mat)
        checkPrefetchLifecycle(ctx, mat: mat)
        checkSwitchEntry(ctx, mat: mat)
        try? ctx.fm.removeItem(at: root)
    }

    // MARK: - 素材

    /// 一次造好全套素材，缺什么就 SKIP 哪一段
    private struct Material {
        let dir: URL
        /// 前半 / 后半的源 wav（同一条阶梯音切两半，块序号 0-3 与 4-7）
        let wavA: URL
        let wavB: URL
        var flacA: URL?
        var flacB: URL?
        var mp3A: URL?
        var mp3B: URL?
        var m4aA: URL?
        var m4aB: URL?
        /// 48 kHz 的后半：验「采样率变化时安全回退」
        var wav48B: URL?
        /// 坏文件：验预取失败不崩、不无限等待
        var broken: URL?
        /// 带标记的整盘镜像 + 三轨分轨表：验 CUE 相邻分轨
        var cueImage: URL?
        var cueFile: URL?

        init(ctx: SelfTestContext, root: URL) {
            let matDir = root.appendingPathComponent("mat", isDirectory: true)
            dir = matDir
            try? ctx.fm.createDirectory(at: matDir, withIntermediateDirectories: true)
            wavA = matDir.appendingPathComponent("part_a.wav")
            wavB = matDir.appendingPathComponent("part_b.wav")
            // 后半的块序从 4 接着排：整条流接起来才是「连续信号拆两段」
            let ok = ctx.writeClickLadder(wavA, seconds: GaplessSuite.half, baseBlock: 0)
                && ctx.writeClickLadder(wavB, seconds: GaplessSuite.half, baseBlock: 4)
            guard ok else { return }

            // 输出名全部写死：按「源文件名 + 扩展名」推的话 48 kHz 那一份正好写回
            // `part_b.wav` 自己——ffmpeg 读写同一文件会当场失败，素材还会被损坏
            let conv: (URL, String, [String]) -> URL? = { src, outName, extra in
                let out = matDir.appendingPathComponent(outName)
                guard let ff = ctx.locateTool("ffmpeg") else { return nil }
                var args = ["-hide_banner", "-loglevel", "error", "-i", src.path]
                args.append(contentsOf: extra)
                args.append("-y"); args.append(out.path)
                return ctx.runTool(ff, args) ? out : nil
            }
            flacA = conv(wavA, "part_a.flac", ["-c:a", "flac"])
            flacB = conv(wavB, "part_b.flac", ["-c:a", "flac"])
            m4aA = conv(wavA, "part_a.m4a", ["-c:a", "aac", "-b:a", "192k"])
            m4aB = conv(wavB, "part_b.m4a", ["-c:a", "aac", "-b:a", "192k"])
            wav48B = conv(wavB, "part_b_48k.wav", ["-ar", "48000"])
            if let lame = ctx.locateTool("lame") {
                var out = matDir.appendingPathComponent("part_a.mp3")
                // 不手拧 `-v`：那是 lame 的另一个选项，拿它传 0 会被当多余位置参数报错。
                // `-q 2` 就够：要紧的是它会在尾页写 LAME Tag（无缝信息就住在那里）
                if ctx.runTool(lame, ["-q", "2", "--silent", wavA.path, out.path]) { mp3A = out }
                out = matDir.appendingPathComponent("part_b.mp3")
                if ctx.runTool(lame, ["-q", "2", "--silent", wavB.path, out.path]) { mp3B = out }
            }
            // 坏文件：扩展名骗得过嗅探，但开不出来（有内容的垃圾字节，不是空文件）
            let bad = matDir.appendingPathComponent("broken.flac")
            var junk = Data([0x66, 0x4C, 0x61, 0x43])          // "fLaC"
            junk.append(contentsOf: (0..<200).map { UInt8($0) })
            if (try? junk.write(to: bad)) != nil { broken = bad }

            // CUE：6 s 镜像（块序 0-11，标记在 0.9 / 2.9 / 4.9 s）+ 每 2 s 一轨
            let img = matDir.appendingPathComponent("album_image.wav")
            if ctx.writeClickLadder(img, seconds: 6.0, baseBlock: 0) {
                cueImage = img
                let cue = matDir.appendingPathComponent("album.cue")
                let text = """
                PERFORMER "TestArtist"
                TITLE "SeamAlbum"
                FILE "\(img.lastPathComponent)" WAVE
                  TRACK 01 AUDIO
                    TITLE "Seam One"
                    INDEX 01 00:00:00
                  TRACK 02 AUDIO
                    TITLE "Seam Two"
                    INDEX 01 00:02:00
                  TRACK 03 AUDIO
                    TITLE "Seam Three"
                    INDEX 01 00:04:00
                """
                if (try? text.data(using: .utf8)?.write(to: cue)) != nil { cueFile = cue }
            }
        }

        /// 前后两半同格式的成对素材
        func pair(_ ext: String) -> (URL, URL)? {
            switch ext {
            case "wav": return (wavA, wavB)
            case "flac": return flat(flacA, flacB)
            case "mp3": return flat(mp3A, mp3B)
            case "m4a": return flat(m4aA, m4aB)
            default: return nil
            }
        }

        private func flat(_ a: URL?, _ b: URL?) -> (URL, URL)? {
            guard let a, let b, FileManager.default.fileExists(atPath: a.path),
                  FileManager.default.fileExists(atPath: b.path) else { return nil }
            return (a, b)
        }
    }

    private func tempRoot(_ ctx: SelfTestContext) -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ttplayer-gapless", isDirectory: true)
        try? ctx.fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - 一次「真实输出链路」的采集结果

    private struct Play {
        let samples: [Float]
        let rate: Double
        /// 这一趟里引擎走过的无缝交接次数
        let handovers: Int
        let note: String
        /// 采集流里每个标记的起点下标
        let edges: [Int]

        /// 标记之间的间隔（帧）：少于两个标记时没有意义
        var seamGap: Int? { edges.count >= 2 ? edges[1] - edges[0] : nil }
        /// 采集流里「可听第 0 帧」的下标（拿第一个标记反推，比拿采集起点的时钟准）
        var anchor: Int? { edges.isEmpty ? nil : edges[0] - Int(GaplessSuite.clickAt * rate) }
    }

    /// 排好曲目、开播，并从引擎真排给音频图的链路上采一段 PCM。`seekTo` 是在出声之后、
    /// 采集之前拖一次位置（预取作废与重排只能在听感上验，不能拿内部计数的时序赌）
    private func play(_ ctx: SelfTestContext, urls: [URL], row: Int = 0, mode: PlayMode,
                      gapless: Bool, seconds: Double = Self.capture,
                      seekTo: Double? = nil) -> Play? {
        let p = ctx.player
        p.stop()
        p.setGaplessPlay(gapless)
        p.setMode(mode)
        p.clearPlaylist()
        guard p.addFiles(urls) >= urls.count else { return nil }
        _ = ctx.waitUntil(4) { p.playlist.tracks.count >= urls.count
            && (p.playlist.tracks.first?.duration ?? 0) > 0 }
        let before = p.gaplessHandovers
        p.playRowAt(row)
        _ = ctx.waitUntil(5) { p.isPlaying }
        if let at = seekTo { p.seek(to: at) }
        let cap = ctx.captureLeftChannel(p, seconds: seconds)
        return Play(samples: cap.samples, rate: cap.sampleRate,
                    handovers: p.gaplessHandovers - before, note: p.gaplessNote,
                    edges: clickEdges(cap.samples, rate: cap.sampleRate))
    }

    /// 采集流里所有标记的起点下标：64 样本 RMS 越过 0.45 的上升沿。
    /// 阶梯音的 RMS 是 0.21，满幅短促是 0.67，中间留了一倍余量；每次越过之间要求
    /// 先掉回 0.30 以下，避免一次标记被数成两次
    private func clickEdges(_ s: [Float], rate: Double) -> [Int] {
        guard s.count > 4_096 else { return [] }
        let win = 64
        var out: [Int] = []
        var armed = true
        var i = 0
        while i + win <= s.count {
            var sum = 0.0
            for k in 0..<win { let v = Double(s[i + k]); sum += v * v }
            let rms = (sum / Double(win)).squareRoot()
            if armed, rms > 0.45 {
                out.append(i)
                armed = false
            } else if !armed, rms < 0.30 {
                armed = true
            }
            i += 1
        }
        return out
    }

    /// `[from, to)` 里最长的近静音游程（秒）。阶梯音全程有声，所以任何一截静音
    /// 都是我们自己插进去的 —— 这就是「不删源文件有意保留的静音」与「不插空白」的分界
    private func longestQuiet(_ s: [Float], rate: Double, from: Int, to: Int) -> Double {
        guard !s.isEmpty else { return 0 }
        let lo = max(0, from), hi = min(s.count, to)
        let win = max(1, Int(0.005 * rate))
        var run = 0, best = 0
        var i = lo
        while i + win <= hi {
            var sum = 0.0
            for k in 0..<win { let v = Double(s[i + k]); sum += v * v }
            if (sum / Double(win)).squareRoot() < 0.03 {
                run += win
                best = max(best, run)
            } else {
                run = 0
            }
            i += win
        }
        return Double(best) / rate
    }

    /// 第 k 个音高块的中心频率（相对 `anchor`）：拿它与候选音高比，读回「这一段到底是哪一块」
    private func blockFreq(_ ctx: SelfTestContext, _ pl: Play, index: Int) -> Double {
        guard let a = pl.anchor else { return -1 }
        let w = Int(0.1 * pl.rate)
        let at = a + Int((Double(index) + 0.5) * Self.block * pl.rate) - w / 2
        guard at >= 0, at + w <= pl.samples.count else { return -1 }
        let seg = Array(pl.samples[at..<at + w])
        var bestF = -1.0, bestE = 0.0
        for k in 0..<14 {
            let f = Self.baseFreq + Self.stepFreq * Double(k)
            let e = ctx.toneEnergy(seg, sampleRate: pl.rate, freq: f)
            if e > bestE { bestE = e; bestF = f }
        }
        return bestE > 0.05 ? bestF : -1
    }

    /// 块序读数：从第 0 块到第 n-1 块，每块换算成「第几块」（读不出音高记 -1）
    private func blockSequence(_ ctx: SelfTestContext, _ pl: Play, blocks: Int) -> [Int] {
        (0..<blocks).map { i in
            let f = blockFreq(ctx, pl, index: i)
            return f < 0 ? -1 : Int(((f - Self.baseFreq) / Self.stepFreq).rounded())
        }
    }

    // MARK: - FFmpeg 的无缝信息

    /// 「编码延迟 / skip samples / 尾部 padding」这份账到底该怎么用，不看文档看数字：
    /// 报上来的延迟如果已被解码器丢掉，我们就一处都不能再减（减两次就是缺帧）。
    /// 数字每次跑都写进日志（`参考` 行），支持边界也据此记录。
    private func checkFFmpegAccounting(_ ctx: SelfTestContext, mat: Material) {
        for ext in ["wav", "flac", "mp3", "m4a"] {
            guard let (a, _) = mat.pair(ext) else {
                ctx.emit("[selftest] SKIP 无缝-FFmpeg 无缝信息（\(ext) 素材造不出来，缺 CLI）")
                continue
            }
            guard let dec = try? FFmpegDecoder(url: a) else {
                ctx.check("无缝-FFmpeg 无缝信息（\(ext) 开得出）", false, "path=\(a.lastPathComponent)")
                continue
            }
            let produced = dec.countProducedFrames()
            let g = dec.gapless
            ctx.emit(String(format:
                "[selftest] 参考 \(ext)：duration=%lld 产出=%lld 差=%lld｜解码器报的延迟=%d trailing=%d"
                + "｜流参数报的延迟=%d｜首帧 pts=%lld 可听基准=%lld",
                dec.totalFrames, produced, produced - dec.totalFrames,
                g.encoderDelay, g.trailingPadding, g.streamDelay, g.firstOutPTS, dec.audibleBase))
            // 可听终点必须与真实产出**逐帧相等**：多一帧就是「排了但解不出来」的空档
            // （接下一曲时缺帧），少一帧等于我们自己多裁了一次
            ctx.check("无缝-产出逐帧等于可听长度（\(ext)）", produced == dec.totalFrames,
                      "duration=\(dec.totalFrames) produced=\(produced)")
            // 头部与 ffmpeg CLI 的解码结果逐样比对：CLI 是「FFmpeg 认为的可听第 0 帧」的参照，
            // 我们少丢一次 priming（或多裁一次）就会在这里错开
            if let ref = referenceHead(ctx, a, frames: 22_050) {
                let got = ctx.referenceLeftChannel(a, from: 0, frames: 22_050)
                var worst: Float = 0
                for i in 0..<min(ref.count, got.count) { worst = max(worst, abs(ref[i] - got[i])) }
                ctx.check("无缝-头部与参考解码逐样一致（\(ext)）",
                          ref.count == got.count && worst < 1e-3,
                          "n=\(got.count)/\(ref.count) 最大偏差=\(worst)")
            } else {
                ctx.emit("[selftest] SKIP 无缝-头部与参考解码逐样一致（\(ext) 缺 ffmpeg CLI）")
            }
        }
    }

    /// 拿 ffmpeg CLI 把文件转成裸 PCM（立体声 float，取左声道）当参考解码结果
    private func referenceHead(_ ctx: SelfTestContext, _ url: URL, frames: Int) -> [Float]? {
        guard let ff = ctx.locateTool("ffmpeg") else { return nil }
        let raw = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tt-gapless-ref-\(frames).f32")
        let seconds = String(format: "%.6f", Double(frames) / 44_100)
        guard ctx.runTool(ff, ["-hide_banner", "-loglevel", "error", "-i", url.path,
                               "-t", seconds, "-ac", "2", "-ar", "44100",
                               "-f", "f32le", "-y", raw.path]),
              let data = try? Data(contentsOf: raw) else { return nil }
        try? ctx.fm.removeItem(at: raw)
        let all = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard all.count >= frames * 2 else { return nil }
        var left: [Float] = []
        left.reserveCapacity(frames)
        for i in 0..<frames { left.append(all[i * 2]) }
        return left
    }

    // MARK: - 衔接本体

    /// 「连续信号拆两段」的主证据：两首连播，标记间隔必须等于前半长度，衔接处不许有空白，
    /// 块序必须一路排下去，且必须真的走无缝交接（不是硬切后碰巧接上）
    private func checkSeam(_ ctx: SelfTestContext, mat: Material) {
        for ext in ["wav", "flac", "mp3", "m4a"] {
            guard let (a, b) = mat.pair(ext) else {
                ctx.emit("[selftest] SKIP 无缝-两半衔接（\(ext) 素材造不出来，缺 CLI）")
                continue
            }
            guard let pl = play(ctx, urls: [a, b], mode: .order, gapless: true) else {
                ctx.check("无缝-两半衔接（\(ext) 排得起来）", false, "addFiles 失败"); continue
            }
            let expect = Int(Self.half * pl.rate)
            ctx.emit(String(format: "[selftest] 衔接 \(ext)：rate=%.0f 采到=%d 标记=%@ 间隔=%@ 交接=%d",
                            pl.rate, pl.samples.count, pl.edges.description,
                            pl.seamGap.map { String($0) } ?? "nil", pl.handovers))
            guard pl.edges.count >= 2 else {
                ctx.check("无缝-两半都采到标记（\(ext)）", false,
                          "edges=\(pl.edges.description) n=\(pl.samples.count)"); continue
            }
            // 有损编码把一个瞬态抹开几十毫秒是正常的，容差给到两个包；无损只容 128 帧
            let tol = ext == "wav" || ext == "flac" ? 128 : 2 * (ext == "mp3" ? 1_152 : 1_024)
            let gap = pl.seamGap ?? -1
            ctx.check("无缝-衔接帧数不差（\(ext)）", abs(gap - expect) <= tol,
                      "间隔=\(gap) 期望=\(expect) 容差=\(tol)")
            // 衔接窗口（第一个标记之后到第二个标记之前）里不许有超过 30 ms 的近静音
            let q = longestQuiet(pl.samples, rate: pl.rate,
                                 from: pl.edges[0] + Int(0.3 * pl.rate),
                                 to: pl.edges[1] - Int(0.3 * pl.rate))
            ctx.check("无缝-衔接处不插空白（\(ext)）", q < 0.03,
                      String(format: "最长静音 %.3f s", q))
            let want = Array(0..<7)
            let seq = blockSequence(ctx, pl, blocks: 7)
            ctx.check("无缝-段序不跳不重（\(ext)）", seq == want, "读到=\(seq.description) 期望=\(want)")
            ctx.check("无缝-交接恰好一次（\(ext)）", pl.handovers == 1,
                      "n=\(pl.handovers) note=\(pl.note)")
        }
    }

    /// 关掉开关就必须退回硬切：拿同一对素材测出「有空白」，上面那条断言才不是自说自话
    private func checkHardCutWhenOff(_ ctx: SelfTestContext, mat: Material) {
        guard let (a, b) = mat.pair("wav") else { return }
        guard let pl = play(ctx, urls: [a, b], mode: .order, gapless: false) else {
            ctx.check("无缝-关掉开关（排得起来）", false); return
        }
        let q = longestQuiet(pl.samples, rate: pl.rate,
                             from: Int(1.0 * pl.rate), to: min(pl.samples.count, Int(3.2 * pl.rate)))
        let gap = pl.seamGap ?? -1
        let expect = Int(Self.half * pl.rate)
        ctx.emit(String(format: "[selftest] 硬切对照：标记=%@ 间隔=%d 期望=%d 最长静音=%.3f s",
                        pl.edges.description, gap, expect, q))
        // 对照组要证的是「关掉后确实回到硬切」。空白时长不从绝对毫秒来（硬切后多久
        // 重新出声取决于缓冲），拿无缝档的容差当尺子：实测硬切差 1763 帧（≈ 40 ms），
        // 而无缝档只差 2 帧——两边差得开，上面那条「帧数不差」才不是自说自话
        ctx.check("无缝-关掉开关能测到空白", q > 0.02, String(format: "最长静音 %.3f s", q))
        ctx.check("无缝-关掉开关接不上帧", gap - expect > 4 * 128, "间隔=\(gap) 期望=\(expect)")
        ctx.check("无缝-关掉开关不走无缝交接", pl.handovers == 0, "n=\(pl.handovers)")
        ctx.player.setGaplessPlay(true)
    }

    // MARK: - 允许安全回退的几类

    /// 采样率变了就不能接（接上要重连输出链）：允许退回硬切，但必须说清原因、不许崩、不许漏播
    private func checkSampleRateFallback(_ ctx: SelfTestContext, mat: Material) {
        guard let (a, _) = mat.pair("wav"), let b48 = mat.wav48B else {
            ctx.emit("[selftest] SKIP 无缝-异采样率回退（缺 48 kHz 素材）"); return
        }
        let p = ctx.player
        guard let pl = play(ctx, urls: [a, b48], mode: .order, gapless: true, seconds: 3.2) else {
            ctx.check("无缝-异采样率回退（排得起来）", false); return
        }
        // 后半是 48 kHz：交接不该发生，而且要留下能看懂的原因
        let explained = !pl.note.isEmpty
        ctx.check("无缝-异采样率退回硬切不接排", pl.handovers == 0,
                  "n=\(pl.handovers) note=\(pl.note)")
        ctx.check("无缝-异采样率写明回退原因", explained, "note=\(pl.note)")
        // 回退原因不能只留在引擎内部：属性面板读的那句必须与它是同一份，
        // 否则用户看到的永远是「已开」，出问题时无从查起
        ctx.check("无缝-回退原因能从播放状态行读到", p.gaplessStatusText == pl.note,
                  "status=\(p.gaplessStatusText) note=\(pl.note)")
        // 回退不等于漏播：这一趟跑完当前曲目必须是后半
        ctx.check("无缝-异采样率不丢下一曲",
                  p.currentTrack?.url.lastPathComponent == b48.lastPathComponent,
                  "current=\(p.currentTrack?.url.lastPathComponent ?? "nil")")
    }

    /// 下一曲开不出来（预取阶段就知道）：不许崩、不许无限等待，也不许把当前曲重播一遍
    private func checkBrokenFallback(_ ctx: SelfTestContext, mat: Material) {
        guard let (a, _) = mat.pair("wav"), let bad = mat.broken else {
            ctx.emit("[selftest] SKIP 无缝-坏文件回退（缺坏文件）"); return
        }
        let p = ctx.player
        p.stop(); p.setGaplessPlay(true); p.setMode(.order); p.clearPlaylist()
        _ = p.addFiles([a, bad])
        _ = ctx.waitUntil(4) { (p.playlist.tracks.first?.duration ?? 0) > 0 }
        let before = p.gaplessHandovers
        p.playRowAt(0)
        _ = ctx.waitUntil(5) { p.isPlaying }
        // 前半 2 s 播完 + 后半开不出来：要在有限时间内 settle（要么停下、要么跳到别的行），
        // 不能挂在「一直在重播前半」或「等一个永远不来的交接」上
        let settled = ctx.waitUntil(8) { !p.isPlaying
            || p.currentTrack?.url.path != bad.path && p.currentTrack?.url.path != a.path }
            || !p.isPlaying
        ctx.check("无缝-坏文件不引起无限等待", settled,
                  "playing=\(p.isPlaying) current=\(p.currentTrack?.url.lastPathComponent ?? "nil")")
        ctx.check("无缝-坏文件不冒充无缝交接", p.gaplessHandovers - before == 0,
                  "n=\(p.gaplessHandovers - before) note=\(p.gaplessNote)")
        p.stop()
    }

    /// 单曲循环的边界：同一首接自己，标记间隔同样必须等于整曲长度（不许重帧也不许缺帧）
    private func checkSingleLoop(_ ctx: SelfTestContext, mat: Material) {
        guard let (a, _) = mat.pair("wav") else { return }
        guard let pl = play(ctx, urls: [a], mode: .singleLoop, gapless: true) else {
            ctx.check("无缝-单曲循环（排得起来）", false); return
        }
        let expect = Int(Self.half * pl.rate)
        let gap = pl.seamGap ?? -1
        ctx.check("无缝-单曲循环边界正确", pl.edges.count >= 2 && abs(gap - expect) <= 128,
                  "标记=\(pl.edges.description) 间隔=\(gap) 期望=\(expect)")
        let q = longestQuiet(pl.samples, rate: pl.rate,
                             from: pl.edges.first.map { $0 + Int(0.3 * pl.rate) } ?? 0,
                             to: pl.edges.count >= 2 ? pl.edges[1] - Int(0.3 * pl.rate) : pl.samples.count)
        ctx.check("无缝-单曲循环不插空白", q < 0.03, String(format: "最长静音 %.3f s", q))
        ctx.check("无缝-单曲循环接了一次", pl.handovers == 1, "n=\(pl.handovers) note=\(pl.note)")
    }

    /// 同镜像相邻分轨：三轨各 2 s，轨内 0.9 s 处各有一个标记。
    /// 播穿（多放下一段的头）会表现为间隔变大，漏段会表现为块序跳号
    private func checkCueAdjacent(_ ctx: SelfTestContext, mat: Material) {
        guard let cue = mat.cueFile else {
            ctx.emit("[selftest] SKIP 无缝-CUE 相邻分轨（缺分轨表素材）"); return
        }
        let p = ctx.player
        p.stop(); p.setGaplessPlay(true); p.setMode(.order); p.clearPlaylist()
        guard p.addFiles([cue]) >= 1 else {
            ctx.check("无缝-CUE 相邻分轨（分轨表进得来）", false); return
        }
        _ = ctx.waitUntil(4) { p.playlist.tracks.count >= 3
            && (p.playlist.tracks.first?.duration ?? 0) > 0 }
        let tracks = p.playlist.tracks
        guard tracks.count >= 3 else {
            ctx.check("无缝-CUE 展开三轨", false, "n=\(tracks.count)"); return
        }
        let before = p.gaplessHandovers
        p.playRowAt(0)
        _ = ctx.waitUntil(5) { p.isPlaying }
        let cap = ctx.captureLeftChannel(p, seconds: 5.4)
        let pl = Play(samples: cap.samples, rate: cap.sampleRate,
                      handovers: p.gaplessHandovers - before, note: p.gaplessNote,
                      edges: clickEdges(cap.samples, rate: cap.sampleRate))
        ctx.emit(String(format: "[selftest] CUE：轨长=%@ 标记=%@",
                        tracks.prefix(3).map { String(format: "%.2f", $0.duration) }.description,
                        pl.edges.description))
        let expect = Int(2.0 * pl.rate)
        let gaps = pl.edges.count >= 3
            ? [pl.edges[1] - pl.edges[0], pl.edges[2] - pl.edges[1]] : []
        ctx.check("无缝-CUE 相邻分轨不播穿不漏段",
                  gaps.count == 2 && gaps.allSatisfy { abs($0 - expect) <= 128 },
                  "间隔=\(gaps.description) 期望=\(expect)")
        let want = Array(0..<10)
        let seq = blockSequence(ctx, pl, blocks: 10)
        ctx.check("无缝-CUE 块序跨轨连续", seq == want, "读到=\(seq.description) 期望=\(want)")
        ctx.check("无缝-CUE 同镜像相邻走无缝", pl.handovers >= 2,
                  "n=\(pl.handovers) note=\(pl.note)")
        p.stop()
    }

    // MARK: - 预取的时机

    /// 预取只能「先想好下一首」，不能提前记历史、不能提前切显示；队列一改就得作废重排
    private func checkPrefetchLifecycle(_ ctx: SelfTestContext, mat: Material) {
        guard let (a, b) = mat.pair("wav") else { return }
        // C 就用 A 的副本换个名：三段素材不必再造，身份按 URL 区分就够
        let c = mat.dir.appendingPathComponent("part_c.wav")
        try? ctx.fm.removeItem(at: c)
        guard (try? ctx.fm.copyItem(at: a, to: c)) != nil else {
            ctx.emit("[selftest] SKIP 无缝-预取时机（造不出第三个文件）"); return
        }
        let p = ctx.player
        p.stop(); p.setGaplessPlay(true); p.setMode(.listLoop); p.clearPlaylist()
        _ = p.addFiles([a, b, c])
        _ = ctx.waitUntil(4) { p.playlist.tracks.count >= 3
            && (p.playlist.tracks.first?.duration ?? 0) > 0 }
        let keys = p.playlist.tracks.prefix(3).map { $0.identityKey }
        p.playRowAt(0)
        // 预取要真的把下一曲开出来（prepareNext 是异步的，等条件而不是等固定时长）
        let armed = ctx.waitUntil(4) { p.nextPreparedKey == keys[1] }
        ctx.check("无缝-预取先定选下一曲", armed, "prepared=\(p.nextPreparedKey) want=\(keys[1])")
        ctx.check("无缝-预取不提前切显示", p.currentTrack?.identityKey == keys[0],
                  "current=\(p.currentTrack?.identityKey ?? "nil")")
        // 队列改动：把 C 插到下一曲，候选必须立刻换成 C
        _ = p.playNext([p.playlist.tracks[2]])
        let swapped = ctx.waitUntil(4) { p.nextPreparedKey == keys[2] }
        ctx.check("无缝-队列改动作废旧候选", swapped,
                  "prepared=\(p.nextPreparedKey) want=\(keys[2])")
        // 拖动当前位置：旧预取必须作废并按新位置重排。只盯 `nextPreparedKey` 的瞬时值
        // 不算证据（作废与重排在同一次刷新里做完，重排是异步的，刚返回时读到空还是读到
        // 新候选取决于两核赛跑）。所以拿输出链路作证：两个标记都在文件里同一位置，
        // 拖到哪里都不改变它们的间距；一旦接了过期位置或多停一下，间距就会对不上
        if let pl = play(ctx, urls: [a, b], mode: .order, gapless: true, seekTo: 0.2),
           let gap = pl.seamGap {
            let expect = Int(Self.half * pl.rate)
            ctx.emit(String(format: "[selftest] seek 后衔接：标记=%@ 间隔=%d 期望=%d 交接=%d",
                            pl.edges.description, gap, expect, pl.handovers))
            ctx.check("无缝-seek 后仍无缝接上下曲", abs(gap - expect) <= 128 && pl.handovers == 1,
                      "间隔=\(gap) 期望=\(expect) 交接=\(pl.handovers) note=\(pl.note)")
            let q = longestQuiet(pl.samples, rate: pl.rate,
                                 from: pl.edges[0] + Int(0.3 * pl.rate),
                                 to: pl.edges[1] - Int(0.3 * pl.rate))
            ctx.check("无缝-seek 后衔接不插空白", q < 0.03, String(format: "最长静音 %.3f s", q))
        } else {
            ctx.check("无缝-seek 后仍无缝接上下曲", false, "没采到两个标记")
        }
        p.stop()
    }

    // MARK: - 用户入口与设置

    /// 内部能力必须有菜单入口，而且开关状态要能存住（默认开：升级后不能又跳出空白）
    private func checkSwitchEntry(_ ctx: SelfTestContext, mat: Material) {
        let p = ctx.player
        p.stop()
        let item = ctx.main.buildPopupMenu().items.first { $0.title.contains("无缝") }
        ctx.check("无缝-菜单里有开关入口", item != nil, "title=\(item?.title ?? "无")")
        let wasOn = p.gaplessPlay
        if item?.action != nil { ctx.main.toggleGapless() }
        ctx.check("无缝-菜单能翻开关", p.gaplessPlay != wasOn, "现在=\(p.gaplessPlay)")
        // 关掉之后界面要说清「现在是硬切」，不能让用户猜
        ctx.check("无缝-关闭状态说给人话", p.gaplessStatusText.contains("已关闭"),
                  "status=\(p.gaplessStatusText)")
        var saved = LibraryStore.load().gaplessPlay
        ctx.check("无缝-开关落盘", saved == p.gaplessPlay, "state.json=\(saved) 内存=\(p.gaplessPlay)")
        ctx.main.toggleGapless()          // 翻回去，别把默认值留在关掉的状态
        saved = LibraryStore.load().gaplessPlay
        ctx.check("无缝-开关能翻回默认", p.gaplessPlay == wasOn && saved == wasOn, "现在=\(p.gaplessPlay)")
        ctx.check("无缝-打开状态说给人话", p.gaplessStatusText.hasPrefix("已开"),
                  "status=\(p.gaplessStatusText)")
        // 属性面板那几行的数据源：只认这一条通路，面板本身不另拼字符串
        let cur = p.currentTrack
        let extra = cur.map { p.propertyExtraLines(for: $0) } ?? []
        ctx.check("无缝-播放状态行进属性面板",
                  extra.contains { $0.0 == "无缝衔接" && $0.1 == p.gaplessStatusText },
                  "lines=\(extra.map { $0.0 }.description)")
    }
}
