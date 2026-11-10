import Foundation
import AppKit

/// 格式能力：白名单向系统现场要、编码名从容器里的真实数据格式读、放不了的要给人话原因；
/// 再加现场转码矩阵、m3u 展开与往返、hi-res（96k/24bit）与 5.1 多声道降混。
/// 样本一律落在临时目录，不污染曲库。
struct FormatSuite: SelfTestSuite {
    func run(_ ctx: SelfTestContext) {
        checkWhitelist(ctx)
        checkTranscodeMatrix(ctx)
        checkM3U(ctx)
        checkHiRes(ctx)
    }

    // MARK: - 白名单与拒收原因

    private func checkWhitelist(_ ctx: SelfTestContext) {
        let ffmpeg = AudioFormats.systemExtensions
        ctx.check("格式-白名单来自 FFmpeg 枚举（不是兜底那 9 个）",
                  ffmpeg.count > AudioFormats.floorExtensions.count
                    && AudioFormats.floorExtensions.isSubset(of: AudioFormats.playableExtensions),
                  "ffmpeg=\(ffmpeg.count) scan=\(AudioFormats.scanExtensions.count)")
        // FFmpeg 认得、过去靠自制解码器扛的格式，现在都进了白名单
        ctx.check("格式-FFmpeg 认得的扩展名进了白名单",
                  AudioFormats.isPlayable(URL(fileURLWithPath: "/tmp/x/y.ape"))
                    && AudioFormats.isPlayable(URL(fileURLWithPath: "/tmp/x/y.mac"))
                    && AudioFormats.isPlayable(URL(fileURLWithPath: "/tmp/x/y.tta"))
                    && AudioFormats.isPlayable(URL(fileURLWithPath: "/tmp/x/y.mkv"))
                    && AudioFormats.isPlayable(URL(fileURLWithPath: "/tmp/x/y.dsf")))
        let mov = URL(fileURLWithPath: "/tmp/x/y.mov")
        ctx.check("格式-视频容器只在拖单文件时试",
                  AudioFormats.isPlayable(mov) && !AudioFormats.isScannable(mov))
        // FFmpeg 未编入解码器（或解复用器没声明该扩展名）的：不在白名单
        ctx.check("格式-FFmpeg 解不了的不在白名单",
                  !AudioFormats.isPlayable(URL(fileURLWithPath: "/tmp/x/y.wma"))
                    && !AudioFormats.isPlayable(URL(fileURLWithPath: "/tmp/x/y.tak"))
                    && !AudioFormats.isPlayable(URL(fileURLWithPath: "/tmp/x/y.mpc"))
                    && !AudioFormats.isPlayable(URL(fileURLWithPath: "/tmp/x/y.mid")))
        for (ext, needle) in [("tak", "TAK"), ("mpc", "Musepack"),
                              ("shn", "Shorten"), ("mid", "MIDI")] {
            let reason = AudioFormats.rejectionReason(for: URL(fileURLWithPath: "/tmp/x/s.\(ext)"))
            ctx.check("格式-\(ext) 说清为什么放不了",
                      reason.contains(needle), "reason=\(reason)")
        }
        ctx.check("格式-没见过的扩展名也有兜底",
                  AudioFormats.rejectionReason(for: URL(fileURLWithPath: "/tmp/s.xyz")).contains(".xyz"))
    }

    // MARK: - 现场转码矩阵

    private func checkTranscodeMatrix(_ ctx: SelfTestContext) {
        guard let source = ctx.libraryURLs.first else {
            ctx.check("格式-转码矩阵可用", false, "曲库里没文件可当转码源")
            return
        }
        // (输出名, 容器, 编码, 应当显示的名字)
        // IMA ADPCM 放在 AIFC 不放 CAF：afconvert 写 CAF 时 pakt 行在 data 前且 num_packets=0，
        // FFmpeg n9.0 cafdec 会因 data_size 未知直接报 INVALIDDATA（非本项目层可修）；
        // 同一编码在 AIFC 里 demuxer 能直接拿到帧包信息，通路完整。
        let matrix: [(String, String, String, String)] = [
            ("fmt.flac", "flac", "flac", "FLAC"),
            ("fmt_alac.m4a", "m4af", "alac", "ALAC"),        // 容器是 M4A，编码是 ALAC
            ("fmt_he.aac", "adts", "aach", "HE-AAC"),
            ("fmt_ima4.aifc", "AIFC", "ima4", "IMA ADPCM"),
            ("fmt_alaw.wav", "WAVE", "alaw", "A-law"),
            ("fmt_ulaw.aifc", "AIFC", "ulaw", "μ-law"),
            ("fmt.au", "NeXT", "BEI16", "AU 16bit"),
            ("fmt.w64", "W64f", "LEI16", "Wave64 16bit"),
        ]
        let fmtDir = formatDir(ctx)
        var done = 0
        var missed: [String] = []
        for (name, fileFmt, dataFmt, expect) in matrix {
            let out = fmtDir.appendingPathComponent(name)
            try? ctx.fm.removeItem(at: out)
            guard ctx.convert(source: source, fileFmt: fileFmt, dataFmt: dataFmt, to: out) else {
                missed.append("\(fileFmt)/\(dataFmt)")     // 本机没这个编码器，不算项目的问题
                continue
            }
            done += 1
            let track = Track(url: out)
            MetadataReader.readSync(track)
            let frames = ctx.decodedFrames(out)
            ctx.check("格式-\(name) 真实编码名",
                      track.formatName == expect && track.decodeProblem == nil,
                      "got=\(track.formatName) expect=\(expect)")
            ctx.check("格式-\(name) 能解出完整帧", frames > 0 && track.duration > 0.5,
                      "frames=\(frames) dur=\(String(format: "%.2f", track.duration))")
        }
        ctx.check("格式-转码矩阵可用", done >= 6, "done=\(done)/\(matrix.count) 跳过=\(missed)")
    }

    // MARK: - m3u

    private func checkM3U(_ ctx: SelfTestContext) {
        let fmtDir = formatDir(ctx)
        let dirURL = ctx.dir
        let m3uURL = fmtDir.appendingPathComponent("order.m3u")
        let cueInList = dirURL.appendingPathComponent("cuealbum.cue")
        let m3uText = """
        #EXTM3U
        #EXTINF:-1,第一首
        \(dirURL.appendingPathComponent("demo02.wav").path)
        fmt.flac
        \(cueInList.path)
        \(fmtDir.appendingPathComponent("missing.mp3").path)
        """
        guard (try? m3uText.write(to: m3uURL, atomically: true, encoding: .utf8)) != nil else {
            ctx.check("m3u-展开且保序", false, "m3u 写不出去")
            return
        }
        let fromList = LibraryStore.importURLs([m3uURL])
        let names = fromList.tracks.map { $0.url.lastPathComponent }
        ctx.check("m3u-展开且保序",
                  fromList.tracks.count == 5 && names.first == "demo02.wav"
                    && names[1] == "fmt.flac"
                    && fromList.tracks[2].isCueSegment,
                  "n=\(fromList.tracks.count) names=\(names)")
        ctx.check("m3u-缺文件不报拒收", fromList.skipped.isEmpty,
                  fromList.skipNote ?? "\(fromList.skipped.count) 项")

        // m3u 往返（FR-LIB-08）：导出 → 再导入，曲目数与顺序必须原样回来。
        // 光验“能导”不够：导出格式写成相对路径、少写 #EXTM3U、
        // 或把 CUE 的每轨都写一行，都要靠往返才看得出来。
        let rtList = Playlist()
        for u in [dirURL.appendingPathComponent("demo02.wav"),
                  fmtDir.appendingPathComponent("fmt.flac")] {
            let t = Track(url: u)
            MetadataReader.readSync(t)
            rtList.add(t)
        }
        let rtURL = fmtDir.appendingPathComponent("roundtrip.m3u")
        let rtBefore = rtList.tracks.map { $0.url.path }
        let rtExported = rtList.exportAsM3U(to: rtURL)
        let rtAfter = rtExported ? LibraryStore.importURLs([rtURL]).tracks.map { $0.url.path } : []
        ctx.check("m3u-往返-曲目与顺序不变", rtExported && rtAfter == rtBefore,
                  "before=\(rtBefore.count) after=\(rtAfter.count) exported=\(rtExported)")
        // CUE 分轨导出只写一行 .cue（导入时重新展开），往返后轨次不能丢
        let cueList = Playlist()
        cueList.add(contentsOf: LibraryStore.importURLs([cueInList]).tracks)
        let cueM3U = fmtDir.appendingPathComponent("roundtrip_cue.m3u")
        _ = cueList.exportAsM3U(to: cueM3U)
        let cueText = (try? String(contentsOf: cueM3U, encoding: .utf8)) ?? ""
        let cueHits = cueText.components(separatedBy: "cuealbum.cue").count - 1
        let cueBack = LibraryStore.importURLs([cueM3U]).tracks
        ctx.check("m3u-往返-CUE 只写一行镜像", cueHits == 1, "行数=\(cueHits) 轨数=\(cueList.count)")
        ctx.check("m3u-往返-CUE 轨次不丢", cueBack.count == cueList.count,
                  "before=\(cueList.count) after=\(cueBack.count)")
    }

    // MARK: - hi-res 与多声道

    /// 素材现场造，不求外部文件。以前只敢说“系统支持”，没验过我们自己的链路：
    /// 6 声道直连 EQ 会让引擎以 -10868 起不来（AUNBandEQ 只吃 ≤2 声道），
    /// 现在多声道先过 channelMixer 降混到立体声再进 EQ。
    private func checkHiRes(_ ctx: SelfTestContext) {
        let p = ctx.player
        let mediaDir = formatDir(ctx)
        let hiresURL = mediaDir.appendingPathComponent("hires_96k24.wav")
        let surroundURL = mediaDir.appendingPathComponent("surround_51.wav")
        let hiresOK = ctx.writeWave(hiresURL, sampleRate: 96_000, channels: 2,
                                    bits: 24, freqs: [440, 660])
        let surroundOK = ctx.writeWave(surroundURL, sampleRate: 48_000, channels: 6,
                                       bits: 16, freqs: [440, 550, 660, 770, 880, 990],
                                       mask: 0x3F)
        ctx.check("hi-res-素材写得出来", hiresOK && surroundOK,
                  "hires=\(hiresOK) 5.1=\(surroundOK)")
        let hires = Track(url: hiresURL)
        MetadataReader.readSync(hires)
        ctx.check("hi-res-96k24 参数",
                  hires.sampleRate == 96_000 && hires.channels == 2
                    && hires.formatName.contains("24bit"),
                  "sr=\(Int(hires.sampleRate)) ch=\(hires.channels) fmt=\(hires.formatName)")
        ctx.check("hi-res-96k24 时长", abs(hires.duration - 2) < 0.05,
                  String(format: "dur=%.2f", hires.duration))
        let hiresFrames = ctx.decodedFrames(hiresURL)
        ctx.check("hi-res-96k24 能解出完整帧", hiresFrames == 192_000,
                  "frames=\(hiresFrames) 应=192000")
        let s51 = Track(url: surroundURL)
        MetadataReader.readSync(s51)
        ctx.check("多声道-5.1 参数", s51.channels == 6 && s51.sampleRate == 48_000,
                  "ch=\(s51.channels) sr=\(Int(s51.sampleRate))")
        let frames51 = ctx.decodedFrames(surroundURL)
        ctx.check("多声道-5.1 能解出完整帧", frames51 == 96_000,
                  "frames=\(frames51) 应=96000")
        p.clearPlaylist()
        _ = p.addFiles([surroundURL])
        p.playRowAt(0)
        _ = ctx.waitUntil(3.0) { p.isPlaying && p.currentTime > 0.2 }
        ctx.check("多声道-5.1 引擎起得来且位置在走",
                  p.isPlaying && p.currentTime > 0.2,
                  "playing=\(p.isPlaying) t=\(String(format: "%.2f", p.currentTime))")
        // 频谱采样走 ctx.spectrumEnergy（采 12 次 pump(0.1) 取 max，测量期间强制
        // enable analyzer）。单点读 max 会同时撞两个假象：tap 冷启动那一帧拿不到
        // 数据； SpectrumView 在窗口 occlusion 不可见时会 setEnabled(false) 将 bars 归零。
        let s51Energy = ctx.spectrumEnergy(p)
        ctx.check("多声道-5.1 降混后频谱有信号", s51Energy > 0.05,
                  "max=\(String(format: "%.3f", s51Energy))")
        p.stop()
    }

    /// 转码样本统一落在这里（不污染曲库），已存在就用
    private func formatDir(_ ctx: SelfTestContext) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ttplayer-formats", isDirectory: true)
        try? ctx.fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
