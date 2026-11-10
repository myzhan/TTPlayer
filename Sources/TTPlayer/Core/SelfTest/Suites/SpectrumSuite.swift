import Foundation
import AppKit
import AVFoundation

/// 频谱：分析器的确定性输入、FFT 定位，以及柱体的像素级绘制回归。
/// 全部离屏完成，不开窗、不碰音频设备，所以冒烟档也跑它。
struct SpectrumSuite: SelfTestSuite {
    func run(_ ctx: SelfTestContext) {
        let analyzer = SpectrumAnalyzer()
        analyzer.setSampleRate(44_100)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                channels: 2, interleaved: false)!
        if let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4410) {
            buf.frameLength = 4410
            for ch in 0..<2 {
                for i in 0..<4410 {
                    buf.floatChannelData![ch][i] = Float(sin(2 * Double.pi * 440 * Double(i) / 44_100))
                }
            }
            for _ in 0..<8 { analyzer.process(buffer: buf) }
            let bars = analyzer.bars
            let maxBar = bars.max() ?? 0
            let peakIndex = bars.enumerated().max { $0.element < $1.element }?.offset ?? -1
            // 440Hz 在对数频段上的柱子：floor(log(440/30)/log(16000/30)*64) = 27
            let expected = Int((logf(440.0 / 30.0) / logf(16_000.0 / 30.0)) * Float(SpectrumAnalyzer.barCount))
            let farEnergy = bars[45...].max() ?? 0
            ctx.check("频谱-有信号", maxBar > 0.3, "max=\(String(format: "%.3f", maxBar))")
            ctx.check("频谱-440Hz定位", peakIndex == expected, "peak=\(peakIndex) expect=\(expected)")
            ctx.check("频谱-旁波束衰减", maxBar > farEnergy + 0.3,
                      "peak=\(String(format: "%.3f", maxBar)) far(45+)=\(String(format: "%.3f", farEnergy))\n"
                        + "           bars=\(bars.map { String(format: "%.2f", $0) })")
            ctx.check("频谱-电平", analyzer.levels.left > 0.5,
                      "L=\(String(format: "%.3f", analyzer.levels.left))")
            // 绘制回归：柱体必须是一条“底暗尖亮”的渐变（批量裁剪画法最容易退化成一块纯色），
            // 而且柱尖要有高光。用像素采样判断，不靠人眼看截图。
            let specView = SpectrumView(analyzer: analyzer)
            specView.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
            // 同一个稳定输入不应让峰值帽在“下降 / 抬回”之间反复提交图层。
            specView.tick()
            specView.needsDisplay = false
            specView.tick()
            ctx.check("频谱-稳定信号不重复重绘", !specView.needsDisplay)
            if let rep = specView.bitmapImageRepForCachingDisplay(in: specView.bounds) {
                specView.cacheDisplay(in: specView.bounds, to: rep)
                let scale = CGFloat(rep.pixelsWide) / specView.bounds.width
                let meterWidth = min(150.0, specView.bounds.width * 0.26)
                let barW = (specView.bounds.width - meterWidth - 7 - CGFloat(SpectrumAnalyzer.barCount - 1))
                    / CGFloat(SpectrumAnalyzer.barCount)
                let barX = 3 + CGFloat(expected) * (barW + 1) + barW / 2
                let column = min(rep.pixelsWide - 1, max(0, Int(barX * scale)))
                var minL: CGFloat = 1, maxL: CGFloat = 0, sampled = 0
                for y in Int(3 * scale)..<Int((specView.bounds.height - 3) * scale) {
                    guard let c = rep.colorAt(x: column, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let l = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
                    minL = min(minL, l); maxL = max(maxL, l); sampled += 1
                }
                ctx.check("频谱-柱体是渐变不是纯色", sampled > 20 && maxL - minL > 0.25,
                          String(format: "min=%.2f max=%.2f 采样=%d", minL, maxL, sampled))
                ctx.check("频谱-柱尖有高光", maxL > 0.80, String(format: "max=%.2f", maxL))
            } else {
                ctx.check("频谱-柱体是渐变不是纯色", false, "位图创建失败")
                ctx.check("频谱-柱尖有高光", false, "位图创建失败")
            }
            analyzer.reset()
            ctx.check("频谱-reset", analyzer.bars.allSatisfy { $0 == 0 })
            analyzer.setEnabled(false)
            analyzer.process(buffer: buf)
            ctx.check("频谱-停画时不分析", analyzer.bars.allSatisfy { $0 == 0 }
                        && analyzer.levels.left == 0 && analyzer.levels.right == 0)
            analyzer.setEnabled(true)
        } else {
            ctx.check("频谱-buffer创建", false)
        }

        // FFT 正确性：已知信号能量峰值应在对应 bin
        let n = 1024
        var re = [Float](repeating: 0, count: n)
        var im: [Float]? = nil
        let k = 64 // 第 64 个 bin
        for i in 0..<n {
            re[i] = cos(2 * Float.pi * Float(k) * Float(i) / Float(n))
        }
        FFT.transform(real: &re, imag: &im)
        let mags = FFT.magnitudes(real: re, imag: im ?? [Float](repeating: 0, count: n))
        let peak = mags.enumerated().max { $0.element < $1.element }?.offset ?? -1
        ctx.check("FFT-频率定位", peak == k, "peak=\(peak) expect=\(k)")
    }
}
