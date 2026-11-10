import Foundation
import AppKit
import AVFoundation

/// 性能基线：第一支柱（低资源）不能只靠人手测。
/// RSS 与“频谱单帧绘制”是确定性的，可以设阈值；播放态 CPU 会被“窗口是否可见”左右，
/// 所以只报不设阈，真正的手工门槛走 scripts/measure_cpu.sh。
struct PerfSuite: SelfTestSuite {
    func run(_ ctx: SelfTestContext) {
        let p = ctx.player
        // 先落到「载入曲库不播放」的静置态再量：停止播放、清空列表、重新装好曲库并等首曲时长就位。
        // RSS 是历史峰值口径，跑在前面几套留下的临时高位（解码窗口、封面缓存）会抬高读数；
        // 静置后读到的才是「挂着窗口、曲库就绪、没有在播」这个稳态。
        // 迁移到 FFmpeg 后静置基线从110~120 MB 抬到 140~150 MB（静态链入的 demuxer/decoder
        // 表、swr 上下文、每开一个容器都会分配 AVFormatContext）；门槛从 150 抬到 180，
        // 与 docs 里的第一支柱指标保持同步。
        // 注意：本套必须排在 ui 之前（见 SuiteID.all 的注释），界面套件会把 AppKit 缓存拉满且不归还。
        p.stop()
        p.clearPlaylist()
        _ = p.addFiles(ctx.libraryURLs)
        _ = ctx.waitUntil(3.0) { (p.playlist.tracks.first?.duration ?? 0) > 0 }
        ctx.pump(0.2)
        let rssMB = ctx.residentMB()
        ctx.check("性能-常驻内存 ≤ 180 MB", rssMB > 0 && rssMB <= 180,
                  String(format: "RSS=%.1f MB", rssMB))
        // debug 构型窗口搭建慢一截（实测 0.27~0.31 s vs release 0.27~0.29 s），
        // 对外数字以 release 为准：release 卡 500 ms（= 2.1 指标里的 0.5 s 目标），
        // debug 留 2 倍余量。注意 release 首次跑（刚链完、页缓存冷）会偏高，
        // 连跑第二轮才是稳态——报数字时至少跑两次。
        #if DEBUG
        let launchBudget = 600.0
        let frameBudget = 6.0
        #else
        let launchBudget = 500.0
        let frameBudget = 2.0
        #endif
        ctx.check("性能-启动到窗口就绪",
                  Diagnostics.readyMs > 0 && Diagnostics.readyMs <= launchBudget,
                  String(format: "%.0f ms ≤ %.0f ms",
                         Diagnostics.readyMs, launchBudget))

        // 单帧绘制耗时：离屏 cacheDisplay 跑 20 帧取均值。这条能拿住
        // “64 根柱子各画一条渐变”这类退化（1.30 ms → 0.40 ms 是这次的主要收益），
        // 而整机 CPU% 看不见它。
        let analyzer = SpectrumAnalyzer()
        analyzer.setSampleRate(44_100)
        for _ in 0..<8 { analyzer.process(buffer: ctx.toneBuffer(440, 4_410)) }
        let specProbe = SpectrumView(analyzer: analyzer)
        specProbe.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
        var frameMs: Double = 0
        if let rep = specProbe.bitmapImageRepForCachingDisplay(in: specProbe.bounds) {
            specProbe.cacheDisplay(in: specProbe.bounds, to: rep)   // 预热：首次要建上下文
            let rounds = 20
            let t0 = Date()
            for _ in 0..<rounds {
                specProbe.cacheDisplay(in: specProbe.bounds, to: rep)
            }
            frameMs = Date().timeIntervalSince(t0) * 1000 / Double(rounds)
        }
        ctx.check("性能-频谱单帧绘制", frameMs > 0 && frameMs <= frameBudget,
                  String(format: "%.2f ms/帧 ≤ %.1f ms", frameMs, frameBudget))
        analyzer.reset()

        // 播放态 CPU：整机口径、只做记录（可见/遮挡是两个值）
        p.clearPlaylist()
        if let first = ctx.libraryURLs.first {
            _ = p.addFiles([first])
            p.playRowAt(0)
            let cpu0 = ctx.cpuSeconds()
            ctx.pump(1.5)
            let cpu1 = ctx.cpuSeconds()
            ctx.emit(String(format: "[selftest] 参考 播放态 CPU %.1f %% 单核（窗口可见口径；门槛看 measure_cpu.sh）",
                            (cpu1 - cpu0) / 1.5 * 100))
            p.stop()
        }
    }
}
