import Foundation
import AVFoundation
import AppKit

/// FFmpeg 解码通路自检：迁移后所有音频（含过去靠自制解码器扛的 DSD / TTA / APE）
/// 都由 FFmpeg 解码。这里拿这三类当代表，验 FFmpeg 通路：
/// ① 认容器、参数（采样率/声道/总帧）对得上；② 随机定位可重复、跳读等于顺序读；
/// ③ 灌进真引擎能推进、频谱有能量；④ 波形没解歪（已知素材是某个纯音）。
/// 不再逐样本比对自制解码器的参考实现——解码正确性现在由 FFmpeg 负责，
/// 标签解析也归 `FFmpegProbe` / `MetadataReader`（在导入/封面套件里覆盖）。
struct DecoderSuite: SelfTestSuite {
    func run(_ ctx: SelfTestContext) {
        checkDSD(ctx)
        checkTTA(ctx)
        checkAPE(ctx)
    }

    // MARK: - 通用结构检查

    /// 随机定位可重复：同一位置读两遍必须逐样本相同（seek 算错就会漂）
    private func seekRepeatable(_ dec: PCMAudioDecoder, _ fmt: AVAudioFormat,
                                at frame: Int64, len: Int) -> Bool {
        guard len > 0,
              let a = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(len)),
              let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(len)) else { return false }
        let g1 = dec.read(into: a, frames: AVAudioFrameCount(len), from: frame)
        let g2 = dec.read(into: b, frames: AVAudioFrameCount(len), from: frame)
        guard g1 > 0, g1 == g2, let da = a.floatChannelData, let db = b.floatChannelData else { return false }
        for i in 0..<Int(g1) where da[0][i] != db[0][i] || da[1][i] != db[1][i] { return false }
        return true
    }

    /// 跳读等于顺序读：从非块边界（sliceFrom）读出来的，要和整段读的那个位置起一模一样
    private func sliceMatchesSequential(_ dec: PCMAudioDecoder, _ fmt: AVAudioFormat,
                                        sliceFrom: Int, sliceLen: Int) -> Bool {
        let wholeLen = sliceFrom + sliceLen
        guard sliceLen > 0,
              let whole = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(wholeLen)),
              let slice = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(sliceLen)) else { return false }
        let gw = dec.read(into: whole, frames: AVAudioFrameCount(wholeLen), from: 0)
        let gs = dec.read(into: slice, frames: AVAudioFrameCount(sliceLen), from: Int64(sliceFrom))
        guard Int(gw) >= wholeLen, Int(gs) == sliceLen,
              let dw = whole.floatChannelData, let ds = slice.floatChannelData else { return false }
        for i in 0..<sliceLen
        where dw[0][i + sliceFrom] != ds[0][i] || dw[1][i + sliceFrom] != ds[1][i] { return false }
        return true
    }

    /// 从头读一段，返回左声道的绝对峰值（0 表示静音/读不出）
    private func decodedPeak(_ dec: PCMAudioDecoder, _ fmt: AVAudioFormat, frames: Int) -> Float {
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)) else { return 0 }
        let got = dec.read(into: buf, frames: AVAudioFrameCount(frames), from: 0)
        guard got > 0, let d = buf.floatChannelData else { return 0 }
        var peak: Float = 0
        for i in 0..<Int(got) { peak = max(peak, abs(d[0][i])) }
        return peak
    }

    /// 打开一个 URL 并跑位置类结构检查（定位/跳读），位置按总帧数自适应
    private func checkPositions(_ ctx: SelfTestContext, _ url: URL, tag: String) {
        guard let dec = PCMDecoders.decoder(for: url),
              let fmt = AVAudioFormat(standardFormatWithSampleRate: dec.sampleRate,
                                      channels: AVAudioChannelCount(dec.channelCount)) else {
            ctx.check("FFmpeg-\(tag) 位置检查", false, "打不开或建不出格式")
            return
        }
        let total = Int(dec.totalFrames)
        let len = min(2048, max(1, total / 2))
        let mid = Int64(max(0, total / 2 - len / 2))
        ctx.check("FFmpeg-\(tag) 随机定位可重复", seekRepeatable(dec, fmt, at: mid, len: len),
                  "total=\(total) at=\(mid) len=\(len)")
        let sliceFrom = max(0, total / 3)
        let sliceLen = min(2048, max(1, total - sliceFrom))
        ctx.check("FFmpeg-\(tag) 跳读等于顺序读",
                  sliceMatchesSequential(dec, fmt, sliceFrom: sliceFrom, sliceLen: sliceLen),
                  "from=\(sliceFrom) len=\(sliceLen)")
    }

    // MARK: - DSD（DSF / DFF）

    private func checkDSD(_ ctx: SelfTestContext) {
        let p = ctx.player
        let fm = ctx.fm
        // FFmpeg 本 build 只带 DSF demuxer，没有 DSDIFF（.dff），故只验 dsf
        ctx.check("FFmpeg-白名单认 dsf",
                  AudioFormats.isPlayable(URL(fileURLWithPath: "/tmp/a.dsf"))
                    && AudioFormats.isScannable(URL(fileURLWithPath: "/tmp/a.dsf")),
                  "dsf=\(AudioFormats.scanExtensions.contains("dsf"))")

        let dsdDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ttplayer-dsd", isDirectory: true)
        try? fm.createDirectory(at: dsdDir, withIntermediateDirectories: true)
        let seconds = 3.0
        let dsfURL = dsdDir.appendingPathComponent("square.dsf")
        let okDSF = ctx.writeDSD(dsfURL, dff: false, seconds: seconds)
        ctx.check("FFmpeg-造出 DSF 样本", okDSF)

        for (url, name) in [(dsfURL, "DSF")] {
            guard let dec = PCMDecoders.decoder(for: url) else {
                ctx.check("FFmpeg-\(name) 能打开", false, "FFmpeg 嗅探没认出来")
                continue
            }
            // DSD 的输出采样率由 FFmpeg 折算（位率 → PCM 等效率），这里不锁死具体值：
            // 只验立体声、时长≈样本秒数、且真的解出了声音（方波有能量）
            let dur = dec.sampleRate > 0 ? Double(dec.totalFrames) / dec.sampleRate : 0
            guard let fmt = AVAudioFormat(standardFormatWithSampleRate: dec.sampleRate,
                                          channels: AVAudioChannelCount(dec.channelCount)) else {
                ctx.check("FFmpeg-\(name) 出得了格式", false, "sr=\(dec.sampleRate) ch=\(dec.channelCount)")
                continue
            }
            let peak = decodedPeak(dec, fmt, frames: 4096)
            ctx.check("FFmpeg-\(name) 参数与声音",
                      dec.channelCount == 2 && abs(dur - seconds) < 0.2 && peak > 0.05,
                      "\(dec.formatName) sr=\(Int(dec.sampleRate)) dur=\(String(format: "%.2f", dur)) peak=\(String(format: "%.3f", peak))")
            checkPositions(ctx, url, tag: name)
        }

        // 真引擎：DSF 灌进列表播一会儿，位置要推进、频谱要有能量（PCM 真的到了混音器）
        let dsdSaved = p.playlist.tracks
        p.clearPlaylist()
        let dsdAdded = p.addFiles([dsfURL])
        ctx.check("FFmpeg-DSF 能入表", dsdAdded == 1 && p.playlist.count == 1,
                  "added=\(dsdAdded) n=\(p.playlist.count)")
        p.setVolume(0.2)
        p.playRowAt(0)
        let dsdEnergy = ctx.spectrumEnergy(p)
        let movedAt = p.currentTime
        ctx.check("FFmpeg-DSF 能播", p.isPlaying && movedAt > 0.2 && movedAt < 2.9,
                  "playing=\(p.isPlaying) t=\(String(format: "%.2f", movedAt))")
        ctx.check("FFmpeg-DSF 有声音", dsdEnergy > 0.05,
                  "max=\(String(format: "%.3f", dsdEnergy))")
        p.seek(to: 2.0)
        _ = ctx.waitUntil(2.0) { p.currentTime > 1.9 }
        ctx.check("FFmpeg-DSF 能拖动", p.currentTime > 1.9 && p.currentTime < 2.9,
                  "t=\(String(format: "%.2f", p.currentTime))")
        p.stop()
        p.setVolume(0.8)
        p.clearPlaylist()
        _ = p.addTracks(dsdSaved)

        // 素材在的话再验一次波形：440Hz 的相关幅度要明显高于旁边的频率
        let toneURL = ctx.dir.appendingPathComponent("demo_dsd.dsf")
        if let dec = PCMDecoders.decoder(for: toneURL) {
            let at440 = ctx.toneAmplitude(dec, freq: 440)
            let at1000 = ctx.toneAmplitude(dec, freq: 1_000)
            ctx.check("FFmpeg-DSD 素材是 440Hz", at440 > 0.25 && at440 > at1000 * 5,
                      "440=\(String(format: "%.3f", at440)) 1000=\(String(format: "%.3f", at1000))")
        } else {
            ctx.emit("[selftest] SKIP FFmpeg-DSD 素材是 440Hz（没有 testlib/demo_dsd.dsf）")
        }
    }

    // MARK: - TTA

    /// 项目不再自带 TTA 编码器，样本不能现场造：改用 testlib 里上游编好的 demo_tta.tta。
    /// 素材不在就 SKIP——参数/定位/波形这三条主干只要有素材就能验住。
    private func checkTTA(_ ctx: SelfTestContext) {
        let p = ctx.player
        ctx.check("FFmpeg-白名单认 tta",
                  AudioFormats.isPlayable(URL(fileURLWithPath: "/tmp/a.tta"))
                    && AudioFormats.isScannable(URL(fileURLWithPath: "/tmp/a.tta")),
                  "scan=\(AudioFormats.scanExtensions.contains("tta"))")

        let ttaURL = ctx.dir.appendingPathComponent("demo_tta.tta")
        guard let dec = PCMDecoders.decoder(for: ttaURL) else {
            ctx.emit("[selftest] SKIP FFmpeg-TTA（没有 testlib/demo_tta.tta）")
            return
        }
        ctx.check("FFmpeg-TTA 参数",
                  abs(dec.sampleRate - 44_100) < 1 && dec.channelCount == 2 && dec.totalFrames > 0,
                  "\(dec.formatName) sr=\(Int(dec.sampleRate)) ch=\(dec.channelCount) n=\(dec.totalFrames)")
        checkPositions(ctx, ttaURL, tag: "TTA")

        // 真引擎播放
        let ttaSaved = p.playlist.tracks
        p.clearPlaylist()
        let ttaAdded = p.addFiles([ttaURL])
        ctx.check("FFmpeg-TTA 能入表", ttaAdded == 1 && p.playlist.count == 1,
                  "added=\(ttaAdded) n=\(p.playlist.count)")
        p.setVolume(0.2)
        p.playRowAt(0)
        let energy = ctx.spectrumEnergy(p)
        let movedAt = p.currentTime
        ctx.check("FFmpeg-TTA 能播", p.isPlaying && movedAt > 0.2,
                  "playing=\(p.isPlaying) t=\(String(format: "%.2f", movedAt))")
        ctx.check("FFmpeg-TTA 有声音", energy > 0.05, "max=\(String(format: "%.3f", energy))")
        p.seek(to: 2.0)
        _ = ctx.waitUntil(2.0) { p.currentTime > 1.9 }
        ctx.check("FFmpeg-TTA 能拖动", p.currentTime > 1.9, "t=\(String(format: "%.2f", p.currentTime))")
        p.stop()
        p.setVolume(0.8)
        p.clearPlaylist()
        _ = p.addTracks(ttaSaved)

        // 波形：左 440Hz
        let at440 = ctx.toneAmplitude(dec, freq: 440)
        let at1000 = ctx.toneAmplitude(dec, freq: 1_000)
        ctx.check("FFmpeg-TTA 素材是 440Hz", at440 > 0.25 && at440 > at1000 * 5,
                  "440=\(String(format: "%.3f", at440)) 1000=\(String(format: "%.3f", at1000))")
    }

    // MARK: - APE（Monkey's Audio）

    /// 样本用官方 mac CLI 编的真码流（base64 内联在 `APEFixtures.swift`）：四份各盖一条
    /// 声道/位深分支。验 FFmpeg 能开、参数对得上、波形没解歪、定位可重复，以及
    /// 中途改坏一字节也不崩（解码健壮性交给 FFmpeg，不再要求逐样本相等）。
    private func checkAPE(_ ctx: SelfTestContext) {
        let fm = ctx.fm
        ctx.check("FFmpeg-白名单认 ape",
                  AudioFormats.isPlayable(URL(fileURLWithPath: "/tmp/a.ape"))
                    && AudioFormats.isScannable(URL(fileURLWithPath: "/tmp/a.ape")),
                  "scan=\(AudioFormats.scanExtensions.contains("ape"))")

        let apeDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ttplayer-ape", isDirectory: true)
        try? fm.createDirectory(at: apeDir, withIntermediateDirectories: true)

        for fx in APEFixtures.all {
            let url = apeDir.appendingPathComponent("\(fx.key).ape")
            do { try fx.data.write(to: url) } catch {
                ctx.check("FFmpeg-APE \(fx.name) 落盘", false, "\(error)")
                continue
            }
            guard let dec = PCMDecoders.decoder(for: url) else {
                ctx.check("FFmpeg-APE \(fx.name) 能打开", false, "FFmpeg 嗅探没认出来")
                continue
            }
            ctx.check("FFmpeg-APE \(fx.name) 参数",
                      abs(dec.sampleRate - Double(fx.sampleRate)) < 1
                        && dec.channelCount == 2
                        && abs(dec.totalFrames - Int64(fx.blocks)) <= 1
                        && dec.formatName.contains("APE"),
                      "\(dec.formatName) sr=\(dec.sampleRate) ch=\(dec.channelCount) n=\(dec.totalFrames)")

            // 波形没解歪：左声道是 leftTone 的正弦，旁边频率上不该有能量
            let atTone = ctx.toneAmplitude(dec, freq: fx.leftTone)
            let off = ctx.toneAmplitude(dec, freq: 1_000)
            ctx.check("FFmpeg-APE \(fx.name) 波形是 \(Int(fx.leftTone))Hz",
                      atTone > 0.5 * fx.toneAmp && off < 0.15 * fx.toneAmp,
                      "\(Int(fx.leftTone))=\(String(format: "%.3f", atTone)) 1000=\(String(format: "%.3f", off))")

            checkPositions(ctx, url, tag: "APE \(fx.name)")

            // 中途改坏一字节：FFmpeg 不许崩，能开就继续（解码错误由它内部吞掉），只验进程存活
            var broken = fx.data
            broken[broken.count / 2] ^= 0xFF
            let badURL = apeDir.appendingPathComponent("\(fx.key)-broken.ape")
            var survived = false
            if (try? broken.write(to: badURL)) != nil,
               let bdec = PCMDecoders.decoder(for: badURL),
               let bfmt = AVAudioFormat(standardFormatWithSampleRate: bdec.sampleRate,
                                        channels: AVAudioChannelCount(bdec.channelCount)),
               let bbuf = AVAudioPCMBuffer(pcmFormat: bfmt, frameCapacity: 4096) {
                _ = bdec.read(into: bbuf, frames: 4096, from: 0)
                survived = true
            }
            ctx.check("FFmpeg-APE \(fx.name) 改坏一字节不崩", survived, "偏移 \(broken.count / 2)")
        }

        checkAPEEngine(ctx)
    }

    /// 真引擎那段要长素材：testlib 里若有上游 mac CLI 编的 demo_ape.ape 就播一段，
    /// 没有就 SKIP——上面四份内联样本已把 FFmpeg 开 APE、参数、波形、定位验住
    private func checkAPEEngine(_ ctx: SelfTestContext) {
        let p = ctx.player
        let url = ctx.dir.appendingPathComponent("demo_ape.ape")
        guard PCMDecoders.decoder(for: url) != nil else {
            ctx.emit("[selftest] SKIP FFmpeg-APE 真引擎播放（没有 testlib/demo_ape.ape）")
            return
        }
        let saved = p.playlist.tracks
        p.clearPlaylist()
        let added = p.addFiles([url])
        ctx.check("FFmpeg-APE 能入表", added == 1 && p.playlist.count == 1,
                  "added=\(added) n=\(p.playlist.count)")
        let track = p.playlist.tracks.first
        if let track { MetadataReader.readSync(track) }
        var noProblem = false
        if let track { noProblem = track.decodeProblem == nil }
        ctx.check("FFmpeg-APE 元数据可读",
                  noProblem && (track?.channels ?? 0) == 2
                    && (track?.formatName ?? "").contains("APE"),
                  "sr=\(track?.sampleRate ?? 0) ch=\(track?.channels ?? 0) "
                    + "name=\(track?.formatName ?? "") problem=\(track?.decodeProblem ?? "nil")")

        p.setVolume(0.2)
        p.playRowAt(0)
        // APE 时长不定（自制时代常见 2～3 分钟），采样窗口拉到 15 次；
        // 能量与“位置推进”共享同一个 pump 循环，不适合抽到 spectrumEnergy，
        // 但同样需要在测量前把 analyzer.setEnabled(true)—— SpectrumView 在自检中
        // 可能因窗口 occlusion 不可见而将 bars 归零。
        let a = p.engine.spectrum
        let wasEnabled = a.isEnabled
        if !wasEnabled { a.setEnabled(true) }
        var energy: Float = 0
        var movedAt = 0.0
        var wasPlaying = false
        for _ in 0..<15 {
            ctx.pump(0.1)
            energy = max(energy, a.bars.max() ?? 0)
            movedAt = max(movedAt, p.currentTime)
            wasPlaying = wasPlaying || p.isPlaying
        }
        if !wasEnabled { a.setEnabled(false) }
        ctx.check("FFmpeg-APE 能播", wasPlaying && movedAt > 0.1,
                  "playing=\(wasPlaying) t=\(String(format: "%.2f", movedAt))")
        ctx.check("FFmpeg-APE 有声音", energy > 0.05, "max=\(String(format: "%.3f", energy))")
        p.stop()
        p.setVolume(0.8)
        p.clearPlaylist()
        _ = p.addTracks(saved)
    }
}
