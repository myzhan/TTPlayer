import Foundation
import AppKit
import AVFoundation

/// 自检上下文：断言登记、等待、套件前置、截图与素材工具。
/// 套件只读这个对象，不各自持有状态，所以单跑与全量跑行为一致。
final class SelfTestContext {
    let main: MainWindowController
    let dir: URL
    let shotDir: String?
    let fm = FileManager.default

    private(set) var failures: [String] = []
    private(set) var total = 0

    var player: PlayerController { PlayerController.shared }

    /// testlib 下全部支持的音频（按文件名自然序）
    private(set) var libraryURLs: [URL] = []
    /// testlib 目录里的文件名（原始顺序，供 CUE 找镜像）
    private(set) var libraryNames: [String] = []
    /// 最近一次 resetLibrary() 里 addFiles 的返回值（验证添加链路用）
    private(set) var libraryAdded = 0

    private var cueTracks: [Track]?

    init(main: MainWindowController, dir: URL, shotDir: String?) {
        self.main = main
        self.dir = dir
        self.shotDir = shotDir
        scanLibrary()
    }

    // MARK: - 断言与输出

    func emit(_ s: String) {
        SelfTest.emit(s)
    }

    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        total += 1
        emit("[selftest] \(ok ? "PASS" : "FAIL") \(name) \(detail)")
        if !ok { failures.append(name) }
    }

    // MARK: - 套件前置

    func prepare(_ needs: Set<SuiteNeed>) {
        if needs.contains(.windows) {
            main.window.contentView?.layoutSubtreeIfNeeded()
            main.dock.window(for: .playlist)?.contentView?.layoutSubtreeIfNeeded()
            pump(0.05)
        }
        if needs.contains(.library) { resetLibrary() }
        if needs.contains(.cueAlbum) { _ = cueAlbumURL() }
    }

    func scanLibrary() {
        guard libraryURLs.isEmpty else { return }
        libraryNames = (try? fm.contentsOfDirectory(atPath: dir.path))?.sorted() ?? []
        libraryURLs = libraryNames.compactMap { name -> URL? in
            let url = dir.appendingPathComponent(name)
            return LibraryStore.supportedExtensions.contains(url.pathExtension.lowercased()) ? url : nil
        }
    }

    /// 把列表置回「testlib 全部曲目」这个已知起点：套件单跑时列表不能是上一套留下的样子
    @discardableResult
    func resetLibrary() -> Int {
        scanLibrary()
        player.setMode(.listLoop)
        // 音量与静音也回到默认：套件单跑不能接着上一套的 0.2 音量或静音状态
        player.setVolume(0.8)
        if player.isMuted { player.toggleMute() }
        player.clearPlaylist()
        libraryAdded = player.addFiles(libraryURLs)
        // 元数据是异步读的，等一下让它落地（拿不到也不阻断，断言自己会报）
        _ = waitUntil(3.0) { (self.player.playlist.tracks.first?.duration ?? 0) > 0 }
        return libraryAdded
    }

    // MARK: - CUE 素材

    /// 现场造一张 GBK 存盘的整盘分轨表（国内抓轨常见编码）；已存在就复用
    func cueAlbumURL() -> URL {
        let url = dir.appendingPathComponent("cuealbum.cue")
        if fm.fileExists(atPath: url.path) { return url }
        let image = libraryNames.first { $0.lowercased().hasSuffix(".wav") } ?? "demo01.wav"
        let text = """
        REM GENRE POP
        REM COMMENT "ExactAudioCopy"
        PERFORMER "TestArtist"
        TITLE "TestAlbum"
        FILE "\(image)" WAVE
          TRACK 01 AUDIO
            TITLE "Track One"
            PERFORMER "TestArtist"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Track Two"
            INDEX 00 00:02:00
            INDEX 01 00:04:00
          TRACK 03 AUDIO
            TITLE "Track Three"
            INDEX 01 00:08:30
        """
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let data = text.data(using: gb) ?? text.data(using: .utf8) {
            try? data.write(to: url)
        }
        return url
    }

    /// 分轨表展开后的曲目（解析一次就缓存）
    func cueAlbumTracks() -> [Track] {
        if let cueTracks { return cueTracks }
        let tracks = LibraryStore.tracks(in: [cueAlbumURL()])
        cueTracks = tracks
        return tracks
    }

    // MARK: - 时间与等待

    /// 同步等一小段：跑 RunLoop 让定时器和渲染时钟真的走，比 asyncAfter 好接顺序断言
    func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
    }

    /// 等一个条件成立（最多 timeout 秒），比固定延时更快也更稳；超时返回 false
    @discardableResult
    func waitUntil(_ timeout: Double, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump(0.05)
        }
        return condition()
    }

    /// 采 ticks 次 pump 的频谱能量最大值。
    /// `engine.spectrum` 的 enabled 是由 SpectrumView 按窗口 occlusion 驱动的（不可见就
    /// setEnabled(false) 将 bars 归零），自检可能在窗口未上报可见时跑，那时即使引擎
    /// 推了 PCM 、tap 回调也进入了 FFT，bars 也会被丢弃。自检想验的是“解码→混音→
    /// tap→分析”整条链路真的能通，不是 UI 可见性，因此测量期间强制 enable，测完还原。
    /// 单点读 max 会撞冷启动时序假象（上一帧 tap 未排上），多抽几次取 max 才稳。
    func spectrumEnergy(_ p: PlayerController, ticks: Int = 12, interval: TimeInterval = 0.1) -> Float {
        let a = p.engine.spectrum
        let was = a.isEnabled
        if !was { a.setEnabled(true) }
        defer { if !was { a.setEnabled(false) } }
        var e: Float = 0
        for _ in 0..<ticks {
            pump(interval)
            e = max(e, a.bars.max() ?? 0)
        }
        return e
    }

    // MARK: - 截图

    /// 把窗口画成 PNG（TTPLAYER_SHOTDIR 不设就不做）。
    /// 用 cacheDisplay 而不是 screencapture：画的是自己的视图树，不需要录屏权限，
    /// 而 screencapture 没权限时只会报 “could not create image from window”
    func snapshot(_ window: NSWindow?, named name: String) {
        guard let shotDir, let window, window.isVisible,
              let content = window.contentView else { return }
        let rect = content.bounds
        guard rect.width > 1, rect.height > 1,
              let rep = content.bitmapImageRepForCachingDisplay(in: rect) else { return }
        content.cacheDisplay(in: rect, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let out = URL(fileURLWithPath: shotDir).appendingPathComponent("\(name).png")
        try? data.write(to: out)
        emit("[selftest] 截图 \(name) \(Int(rect.width))×\(Int(rect.height)) -> \(out.path)")
    }

    // MARK: - 性能与像素工具

    /// 当前进程常驻内存（MB）：task_info 拿的是真实 RSS，不是 malloc 记账。
    /// 读之前先把已经 free 但还被 malloc 攒着的页还给系统（malloc 压力释放），
    /// 否则读到的是历史峰值而不是当前占用：同一份代码两次运行能差 20 MB，阈值就成了骰子
    func residentMB() -> Double {
        _ = malloc_zone_pressure_relief(nil, 0)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size
            / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), raw, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_048_576
    }

    /// 进程累计 CPU 秒（user + sys）：两次取值的差 / 窗口 = 那段窗口的平均单核占用
    func cpuSeconds() -> Double {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1_000_000
            + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1_000_000
    }

    /// 一段确定性正弦缓冲（频谱断言与性能基线共用）
    func toneBuffer(_ freq: Double, _ frames: Int) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                channels: 2, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<2 {
            for i in 0..<frames {
                buf.floatChannelData![ch][i] = Float(sin(2 * Double.pi * freq * Double(i) / 44_100))
            }
        }
        return buf
    }

    /// 一张图各档位图的长边（从大到小）：封面降采样就拿它判定
    func bitmapSides(_ image: NSImage?) -> [Int] {
        (image?.representations.map { max($0.pixelsWide, $0.pixelsHigh) } ?? [])
            .sorted(by: >)
    }

    func maxBitmapSide(_ image: NSImage?) -> Int { bitmapSides(image).first ?? 0 }

    /// 把一块玻璃壳画到已知底色上，返回中心像素。
    /// 必要性：只断言 `bodyAlpha == 0.9` 证明不了“真的透出桌面”——属性对了但底色仍按
    /// 不透明画的情况太多了。这里用红底做对照，看混出来的像素是不是 0.9×壳色 + 0.1×红。
    func glassPixel(over backdrop: NSColor, enabled: Bool) -> NSColor? {
        let size = NSSize(width: 40, height: 20)
        let view = GradientView(frame: NSRect(origin: .zero, size: size))
        view.colors = [Theme.windowTop, Theme.windowTop]
        view.glassBody = true
        let was = GlassStyle.enabled
        GlassStyle.setEnabled(enabled)
        defer { GlassStyle.setEnabled(was) }

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        backdrop.setFill()
        NSRect(origin: .zero, size: size).fill()
        view.draw(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.colorAt(x: 20, y: 10)?.usingColorSpace(.deviceRGB)
    }

    // MARK: - 素材生成与解码探针

    /// 造 hi-res / 多声道 WAV（FR-FMT-09 的素材）：位深、声道数、声道掩码按需要给。
    /// 不走 afconvert：它转不出 6 声道 PCM，而“多声道能不能播”正是要验的东西。
    /// 24 bit 写小端低 3 字节；6 声道用 WAVE_FORMAT_EXTENSIBLE + 声道掩码（5.1 = 0x3F）
    func writeWave(_ url: URL, sampleRate: Int, channels: Int, bits: Int,
                   freqs: [Double], mask: UInt32? = nil,
                   seconds: Double = 2) -> Bool {
        func u16(_ v: UInt16) -> Data { var x = v.littleEndian; return withUnsafeBytes(of: &x) { Data($0) } }
        func u32(_ v: UInt32) -> Data { var x = v.littleEndian; return withUnsafeBytes(of: &x) { Data($0) } }
        let frames = Int(Double(sampleRate) * seconds)
        let blockAlign = channels * bits / 8
        var audio = Data(capacity: frames * blockAlign)
        for i in 0..<frames {
            let t = Double(i) / Double(sampleRate)
            for c in 0..<channels {
                let s = max(-1.0, min(1.0, 0.6 * sin(2 * Double.pi * freqs[c] * t)))
                if bits == 24 {
                    var v = Int32(s * 8_388_607).littleEndian
                    audio.append(contentsOf: withUnsafeBytes(of: &v) { Data($0.prefix(3)) })
                } else {
                    var v = Int16(s * 32_767).littleEndian
                    audio.append(contentsOf: withUnsafeBytes(of: &v) { Data($0) })
                }
            }
        }
        var fmt: Data
        if let mask {
            var guid = u32(1) + u16(0) + u16(0x0010)                  // PCM 子格式 GUID
            guid.append(contentsOf: [0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
            fmt = u16(0xFFFE) + u16(UInt16(channels)) + u32(UInt32(sampleRate))
                + u32(UInt32(sampleRate * blockAlign)) + u16(UInt16(blockAlign)) + u16(UInt16(bits))
                + u16(22) + u16(UInt16(bits)) + u32(mask) + guid
        } else {
            fmt = u16(1) + u16(UInt16(channels)) + u32(UInt32(sampleRate))
                + u32(UInt32(sampleRate * blockAlign)) + u16(UInt16(blockAlign)) + u16(UInt16(bits))
        }
        var body = Data("WAVE".utf8)
        body.append(Data("fmt ".utf8)); body.append(u32(UInt32(fmt.count))); body.append(fmt)
        body.append(Data("data".utf8)); body.append(u32(UInt32(audio.count))); body.append(audio)
        let out = Data("RIFF".utf8) + u32(UInt32(body.count)) + body
        return (try? out.write(to: url)) != nil
    }

    /// 解出来的信号里某个频率的幅度（0…1）：DSD 残留噪声会让过零计数虚高，正交相关才是真凭据
    func toneAmplitude(_ decoder: PCMAudioDecoder, freq: Double) -> Double {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: decoder.sampleRate,
                                      channels: AVAudioChannelCount(decoder.channelCount)),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4096) else { return 0 }
        var re = 0.0
        var im = 0.0
        var n = 0
        var pos: Int64 = 0
        let limit = Int64(decoder.sampleRate)
        while pos < limit {
            let got = decoder.read(into: buf, frames: 4096, from: pos)
            if got == 0 { break }
            guard let data = buf.floatChannelData else { break }
            for i in 0..<Int(got) {
                let phase = 2 * Double.pi * freq * Double(pos + Int64(i)) / decoder.sampleRate
                let v = Double(data[0][i])
                re += v * cos(phase)
                im += v * sin(phase)
                n += 1
            }
            pos += Int64(got)
        }
        guard n > 0 else { return 0 }
        return 2 * (re * re + im * im).squareRoot() / Double(n)
    }

    /// 造一个小 DSD 样本（自带解码器的测试素材）：
    /// 左声道 1378Hz 方波（每 128 字节在 0xFF/0x00 之间翻），右声道恒 0。
    /// 1bit 常量不需要 sigma-delta 调制，写完就是已知答案：左 ±0.9 摆动、右恒 -0.9，
    /// 位序反了或声道交错反了都会立刻失败
    func writeDSD(_ url: URL, dff: Bool, seconds: Double) -> Bool {
        let rate = 2_822_400.0
        let bits = Int64(rate * seconds)
        let bytes = Int((bits + 7) / 8)
        let block = 4096
        func left(_ i: Int) -> UInt8 { (i / 128) % 2 == 0 ? 0xFF : 0x00 }
        func u32(_ v: UInt32, _ little: Bool) -> Data {
            var x = little ? v.littleEndian : v.bigEndian
            return withUnsafeBytes(of: &x) { Data($0) }
        }
        func u64(_ v: UInt64, _ little: Bool) -> Data {
            var x = little ? v.littleEndian : v.bigEndian
            return withUnsafeBytes(of: &x) { Data($0) }
        }

        var out = Data()
        if dff {
            var body = Data()
            for i in 0..<bytes {
                body.append(left(i))
                body.append(0)
            }
            var channelCount = UInt16(2).bigEndian
            var chnlBody = withUnsafeBytes(of: &channelCount) { Data($0) }
            chnlBody.append(Data("SLFT".utf8))
            chnlBody.append(Data("SRGT".utf8))
            let fver = Data("FVER".utf8) + u64(4, false) + u32(0x0105_0000, false)
            let fs = Data("FS  ".utf8) + u64(4, false) + u32(UInt32(rate), false)
            let chnl = Data("CHNL".utf8) + u64(UInt64(12 + chnlBody.count), false) + chnlBody
            let propBody = Data("SND ".utf8) + fs + chnl
            let prop = Data("PROP".utf8) + u64(UInt64(propBody.count), false) + propBody
            let data = Data("DSD ".utf8) + u64(UInt64(body.count), false) + body
            let form = Data("DSD ".utf8) + fver + prop + data
            out = Data("FRM8".utf8) + u64(UInt64(form.count), false) + form
        } else {
            var body = Data()
            var offset = 0
            while offset < bytes {
                let n = min(block, bytes - offset)
                for i in offset..<(offset + n) { body.append(left(i)) }
                for _ in 0..<(block - n) { body.append(0) }      // 末块补满
                for _ in 0..<block { body.append(0) }            // 右声道恒 0
                offset += n
            }
            var fmt = Data()
            fmt.append(u32(1, true))                // 版本
            fmt.append(u32(0, true))                // 格式：原始 DSD
            fmt.append(u32(2, true))                // 声道类型：立体声
            fmt.append(u32(2, true))                // 声道数
            fmt.append(u32(UInt32(rate), true))     // 采样率
            fmt.append(u32(1, true))                // 位深
            fmt.append(u64(UInt64(bits), true))     // 每声道位数
            fmt.append(u32(UInt32(block), true))    // 每声道块大小
            fmt.append(u32(0, true))                // 保留
            let fmtChunk = Data("fmt ".utf8) + u64(UInt64(12 + fmt.count), true) + fmt
            let dataChunk = Data("data".utf8) + u64(UInt64(12 + body.count), true) + body
            out = Data("DSD ".utf8) + u64(28, true)
            out.append(u64(UInt64(28 + fmtChunk.count + dataChunk.count), true))
            out.append(u64(0, true))                // 无元数据
            out.append(fmtChunk)
            out.append(dataChunk)
        }
        return (try? out.write(to: url)) != nil
    }

    /// 用系统自带的 afconvert 现场转一个样本（指定容器与编码）。
    /// 转不成功返回 false：那是本机没有这个编码器，不是本项目的错，由调用方计入“跳过”
    func convert(source: URL, fileFmt: String, dataFmt: String, to out: URL) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        task.arguments = ["-f", fileFmt, "-d", dataFmt, source.path, out.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let size = (try? out.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return task.terminationStatus == 0 && size > 0
        } catch {
            return false
        }
    }

    /// 把全部帧读出来（只开文件头不能证明解码器真的可用）；解不动返回 -1。
    /// 走项目真实解码链路（FFmpeg）：迁移后系统解码栈不在通路上，再拿 `AVAudioFile`
    /// 当参照会把「FFmpeg 能不能解」问错对象。FFmpegDecoder 统一出立体声，按帧数计数即可。
    func decodedFrames(_ url: URL) -> Int {
        guard let dec = PCMDecoders.decoder(for: url),
              let fmt = AVAudioFormat(standardFormatWithSampleRate: dec.sampleRate,
                                      channels: AVAudioChannelCount(dec.channelCount)),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4096) else { return -1 }
        var total = 0
        var pos: Int64 = 0
        // ADTS 这类裸流 st.duration/nb_frames 都缺，totalFrames 会算成 0；
        // 不能拿 0 当上限（一上来就退出，帧数永远为 0）——没上限就直读到 read() 返回 0。
        let limit = dec.totalFrames
        while limit <= 0 || pos < limit {
            buf.frameLength = 0
            let got = dec.read(into: buf, frames: 4096, from: pos)
            if got == 0 { break }
            total += Int(got)
            pos += Int64(got)
        }
        return total
    }
}
