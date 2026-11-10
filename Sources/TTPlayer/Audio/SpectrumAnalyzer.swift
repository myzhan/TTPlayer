import Foundation
import AVFoundation
import Accelerate

/// 频谱 + 电平分析器。
/// 音频线程调用 `process(buffer:)` 灌入数据；UI 线程定时读取 `bars` / `levels`。
final class SpectrumAnalyzer {
    static let barCount = 64

    private let lock = NSLock()
    private var storedBars: [Float] = Array(repeating: 0, count: SpectrumAnalyzer.barCount)
    private var storedLevels: (left: Float, right: Float) = (0, 0)
    private var sampleRate: Double = 44_100
    private var enabled = true

    /// UI 一次只拿一份很小的快照，避免分别读取频谱/电平时与音频线程数据竞争。
    var bars: [Float] {
        lock.lock(); defer { lock.unlock() }
        return storedBars
    }

    var levels: (left: Float, right: Float) {
        lock.lock(); defer { lock.unlock() }
        return storedLevels
    }

    /// 当前是否处于分析态；自检在测音频链路时需要临时打开后再还原，避免影响 UI 侧的可见性判定。
    var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    // MARK: 采集参数
    private let fftSize = 2048
    private var ring = [Float](repeating: 0, count: 2048)
    private var ringPos = 0
    private var ringCount = 0
    private var samplesSinceFFT = 0
    private var hann: [Float]
    private var scratchRe: [Float]
    private var scratchIm: [Float]
    private var nextBars: [Float]
    private let fftLog2: vDSP_Length
    private let fftSetup: FFTSetup

    // 频段边界（对数分布 30Hz ~ 16kHz）
    private let bandEdges: [Float]

    init() {
        fftLog2 = vDSP_Length(log2(Float(fftSize)))
        guard let setup = vDSP_create_fftsetup(fftLog2, FFTRadix(kFFTRadix2)) else {
            fatalError("无法创建频谱 FFT")
        }
        fftSetup = setup
        hann = [Float](repeating: 0, count: fftSize)
        for i in 0..<fftSize {
            hann[i] = 0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(fftSize - 1))
        }
        scratchRe = [Float](repeating: 0, count: fftSize)
        scratchIm = [Float](repeating: 0, count: fftSize)
        nextBars = [Float](repeating: 0, count: SpectrumAnalyzer.barCount)

        var edges = [Float](repeating: 0, count: SpectrumAnalyzer.barCount + 1)
        let fMin: Float = 30, fMax: Float = 16_000
        for i in 0...SpectrumAnalyzer.barCount {
            edges[i] = fMin * powf(fMax / fMin, Float(i) / Float(SpectrumAnalyzer.barCount))
        }
        bandEdges = edges
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    func setSampleRate(_ sr: Double) {
        lock.lock(); sampleRate = sr; lock.unlock()
    }

    /// 窗口不可见或没有播放时完全跳过采样与 FFT。tap 仍留在音频图中，避免播放/暂停时
    /// 反复修改实时音频图；回调只做一次加锁读取后就返回。
    func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        if !value {
            for i in storedBars.indices { storedBars[i] = 0 }
            storedLevels = (0, 0)
        }
        lock.unlock()
    }

    /// 音频线程入口：从 buffer 取前两个声道计算电平，混成单声道喂给 FFT
    func process(buffer: AVAudioPCMBuffer) {
        guard let f = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        lock.lock()
        let active = enabled
        let sr = sampleRate
        lock.unlock()
        guard active else { return }
        let ch0 = f[0]
        let ch1 = Int(buffer.format.channelCount) > 1 ? f[1] : nil

        var peakL: Float = 0, peakR: Float = 0
        let decay: Float = 0.92
        // 频谱只画到 16 kHz，高采样率素材无需把 88.2/96/176.4/192 kHz 的每个样本
        // 都送进 FFT。先做整数抽取，把分析采样率压到约 48 kHz；电平仍逐样本取峰值。
        let spectrumStride = max(1, Int((sr / 48_000).rounded()))
        let spectrumSampleRate = sr / Double(spectrumStride)
        let fftHop = max(fftSize, Int(spectrumSampleRate / 18))

        if spectrumStride == 1 {
            for i in 0..<frameCount {
                let l = ch0[i]
                let r = ch1?[i] ?? l
                if abs(l) > peakL { peakL = abs(l) }
                if abs(r) > peakR { peakR = abs(r) }
                ring[ringPos] = (l + r) * 0.5
                ringPos += 1
                if ringPos == fftSize { ringPos = 0 }
                ringCount = min(fftSize, ringCount + 1)
                samplesSinceFFT += 1
                if ringCount == fftSize, samplesSinceFFT >= fftHop {
                    samplesSinceFFT = 0
                    computeSpectrum(sampleRate: spectrumSampleRate)
                }
            }
        } else {
            // 高采样率时电平仍逐样本取峰值；频谱另走抽取后的稀疏循环。
            for i in 0..<frameCount {
                let l = ch0[i]
                let r = ch1?[i] ?? l
                if abs(l) > peakL { peakL = abs(l) }
                if abs(r) > peakR { peakR = abs(r) }
            }
            var i = 0
            while i < frameCount {
                let l = ch0[i]
                let r = ch1?[i] ?? l
                appendSpectrumSample((l + r) * 0.5, sampleRate: spectrumSampleRate,
                                     fftHop: fftHop)
                i += spectrumStride
            }
        }
        lock.lock()
        if enabled {
            storedLevels = (max(peakL, storedLevels.0 * decay),
                            max(peakR, storedLevels.1 * decay))
        }
        lock.unlock()
    }

    /// 停止时清空显示
    func reset() {
        lock.lock()
        for i in storedBars.indices { storedBars[i] = 0 }
        storedLevels = (0, 0)
        for i in ring.indices { ring[i] = 0 }
        ringPos = 0
        ringCount = 0
        samplesSinceFFT = 0
        lock.unlock()
    }

    // MARK: - FFT（仅音频线程调用；ring 已满 2048 样本）

    @inline(__always)
    private func appendSpectrumSample(_ sample: Float, sampleRate: Double, fftHop: Int) {
        ring[ringPos] = sample
        ringPos += 1
        if ringPos == fftSize { ringPos = 0 }
        ringCount = min(fftSize, ringCount + 1)
        samplesSinceFFT += 1
        if ringCount == fftSize, samplesSinceFFT >= fftHop {
            samplesSinceFFT = 0
            computeSpectrum(sampleRate: sampleRate)
        }
    }

    private func computeSpectrum(sampleRate sr: Double) {
        // ringPos 指向最旧样本：分两段摊平成时间正序，同时乘 Hann 窗。
        let tail = fftSize - ringPos
        for i in 0..<tail {
            scratchRe[i] = ring[ringPos + i] * hann[i]
        }
        if ringPos > 0 {
            for i in 0..<ringPos {
                scratchRe[tail + i] = ring[i] * hann[tail + i]
            }
        }
        for i in scratchIm.indices { scratchIm[i] = 0 }
        scratchRe.withUnsafeMutableBufferPointer { re in
            scratchIm.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                vDSP_fft_zip(fftSetup, &split, 1, fftLog2, FFTDirection(FFT_FORWARD))
            }
        }

        let binHz = Float(sr / Double(fftSize))
        for b in 0..<SpectrumAnalyzer.barCount {
            let lo = max(1, Int(bandEdges[b] / binHz))
            let hi = min(fftSize / 2, max(lo + 1, Int(bandEdges[b + 1] / binHz)))
            var sum: Float = 0
            for i in lo..<hi {
                sum += hypotf(scratchRe[i], scratchIm[i]) / Float(fftSize)
            }
            let avg = sum / Float(hi - lo)
            // 对数刻度：约 -80dB ~ 0dB 映射到 0...1
            let db = 20 * log10(max(avg, 1e-7))
            let v = max(0, min(1, (db + 80) / 80))
            nextBars[b] = powf(v, 1.4) // 抬亮中低段，视觉上更接近千千静听
        }
        lock.lock()
        if enabled { swap(&storedBars, &nextBars) }
        lock.unlock()
    }
}
