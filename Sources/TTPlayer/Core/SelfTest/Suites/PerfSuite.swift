import Foundation
import AppKit
import AVFoundation

/// 性能基线：第一支柱（低资源）不能只靠人手测。
/// 频谱单帧绘制是确定性的，可以直接卡；RSS 只能卡到「整块常驻」的精度（下面 run() 里
/// 写了实测抖动）；播放态 CPU 会被“窗口是否可见”左右，所以只报不设阈，
/// 真正的手工门槛走 scripts/measure_cpu.sh。
struct PerfSuite: SelfTestSuite {
    func run(_ ctx: SelfTestContext) {
        let p = ctx.player
        // 先落到「载入曲库不播放」的静置态再量：停止播放、清空列表、重新装好曲库并等首曲时长就位。
        // RSS 是历史峰值口径，跑在前面几套留下的临时高位（解码窗口、封面缓存）会抬高读数；
        // 静置后读到的才是「挂着窗口、曲库就绪、没有在播」这个稳态。
        // 迁移到 FFmpeg 后静置基线从110~120 MB 抬到 140~150 MB（静态链入的 demuxer/decoder
        // 表、swr 上下文、每开一个容器都会分配 AVFormatContext）。
        // 门槛定 190 不是抬一下就好：这条拿住的必须是「有没有多留一整块常驻」而不是 MB 级精度——
        // 同一份 release 二进制连跑三轮实测 167.0 / 179.5 / 183.1 MB（同一进程内五次采样完全
        // 一致，差的 16 MB 全在前面十几套留下的异步元数据/封面缓存落不落地）；v1.0.1（322 项）
        // 同期实测也有 173.8 / 177.6，180 这条线本来就贴在抖动区间上。
        // F05（568 项）之后这条抖动带反而变宽了，但变的不是本仓代码：同一份打包二进制，
        // 在连着构建/连跑的那阵子读到 204.0 / 208.0 / 205.2 / 207.8 MB（越线），机器空下来
        // 连跑四轮是 160.6~172.5 MB。拿「多静置 6 s 复采」验过缓存落地假说：两次只差几 MB 且
        // 不收敛到高值，所以抖的不是异步缓存落没落地，是整机内存压力（AppKit 栅格缓存与
        // FFmpeg 上下文都会跟着压力缩胖）。门槛不动：190 卡的仍是「有没有多留一整块」；
        // 越线时先看是不是刚链完或正在连跑，报数字要么取空闲轮，要么把忙轮一并注明。
        // F01（692 项）后按同样口径重测过：拿无缝预取会不会多留一个解码器这件事做对照，
        // 前 12 套同样跑、只改 gaplessPlay 开关，开/关各两轮 165.9 / 182.4 与 165.7 / 176.4 MB
        // ——预取那一份解码器没有抬高常驻；而连着构建跟跑 all 的忙轮读到 193.8 / 197.0 / 205.7 MB。
        // 注意：本套必须排在开新窗的那几套（queue / ui）之前（见 SuiteID.all 的注释），
        // 它们会把 AppKit 缓存拉满且不归还。
        p.stop()
        p.clearPlaylist()
        _ = p.addFiles(ctx.libraryURLs)
        _ = ctx.waitUntil(3.0) { (p.playlist.tracks.first?.duration ?? 0) > 0 }
        // 静置 2 s 再读：元数据与封面是异步解析的，0.2 s 时有一部分还没落地（实测能差几 MB）
        ctx.pump(2.0)
        let rssMB = ctx.residentMB()
        ctx.check("性能-常驻内存 ≤ 190 MB", rssMB > 0 && rssMB <= 190,
                  String(format: "RSS=%.1f MB", rssMB))
        // debug 构型窗口搭建慢一截，对外数字以 release 为准：release 卡 500 ms（= 2.1 指标里的
        // 0.5 s 目标），debug 留 2 倍余量。F05 这一轮稳态实测：debug 205~248 ms、release 211~395 ms、
        // 打包版 231~310 ms。但刚链完（或刚拷完 bundle）的第一次跑一定偏高：页缓存是冷的，
        // 实测 535 / 574 / 714 ms，直接越线。所以这一条的口径是「热轮」：报数字与过门槛都至少
        // 跑两轮取第二轮，首轮只用来确认没有数量级退化（别顺着这条线去查启动链路）。
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
        // 一万行搜索计时：放最后，前面 RSS/启动/单帧的口径都不被这一万条临时对象污染
        measureSearchScale(ctx)
    }

    /// requirements F05 验收：「记录 10,000 条本地模拟元数据列表的输入与结果更新时间，
    /// 注明机器与数据条件，确认无明显卡顿」。
    ///
    /// 「本地模拟元数据」= 直接在内存里造 Track 并把标题/艺人/专辑写好：不读盘、不走
    /// `MetadataReader`。筛选这一步要扫多少字符跟真实一万行是同一份工作量，省掉的只是 IO。
    /// 门槛只卡用户真能感觉到的两件事：敲字那一下的同步开销（防抖之前）、从敲字到结果上屏；
    /// 纯判定与整趟重画的毫秒数一并打进报告（`[selftest] 参考` 那行，含机器条件），
    /// 换机器先看那行再谈门槛。
    private func measureSearchScale(_ ctx: SelfTestContext) {
        let p = ctx.player
        let main = ctx.main
        let panel = main.playlistPanel
        let view = panel.playlistView
        let total = 10_000
        p.stop()
        p.clearPlaylist()
        panel.collapseSearch()
        view.clearFilter()
        main.setListVisible(true)
        p.switchGroup(.main)

        // 数据构成：每 100 行同一种后缀（就像一张专辑一个格式，四个档各占四分之一），
        // 5% 的标题是中文（非 ASCII 那条判定路），其余是 ASCII 长标题。
        // 后缀按整百块而不按 i%4 发：否则「每 20 行一个中文标题」会与格式同余，
        // 组合筛选直接命中 0 行，量的就不是同一份工作量了
        let exts = ["wav", "flac", "mp3", "m4a"]
        var tracks: [Track] = []
        tracks.reserveCapacity(total)
        for i in 0..<total {
            let path = "/tmp/ttperf/lib_\(String(format: "%05d", i)).\(exts[(i / 100) % exts.count])"
            let t = Track(url: URL(fileURLWithPath: path))
            t.title = i % 20 == 0 ? "第 \(i) 首现场录音" : "Live Session \(String(format: "%05d", i))"
            t.artist = "艺人\(i % 200)"
            t.album = "专辑\(i % 50)"
            tracks.append(t)
        }
        let asciiKW = "Session 007"      // ASCII：字节折叠扫描
        let cjkKW = "现场录音"            // 非 ASCII：contains 兜底
        func manualCount(_ kw: String) -> Int {
            tracks.reduce(0) { $1.title.contains(kw) || $1.artist.contains(kw)
                || $1.album.contains(kw) || $1.fileName.contains(kw) ? $0 + 1 : $0 }
        }

        // 入表本身也要有数：一万个 Track 建对象 + 记账构，不等于一万行重画
        let add0 = Date()
        _ = p.playlist.add(contentsOf: tracks)
        let addMs = Date().timeIntervalSince(add0) * 1000
        NotificationCenter.default.post(name: .ttPlaylistChanged, object: nil)   // 整表重建一次
        ctx.pump(0.3)
        guard view.totalCount == total else {
            ctx.check("性能-一万行前置（列表真到了一万行）", false, "n=\(view.totalCount)"); return
        }
        let expectASCII = manualCount(asciiKW)
        let expectCJK = manualCount(cjkKW)
        ctx.check("性能-一万行入表",
                  addMs >= 0 && expectASCII > 0 && expectCJK > 0
                    && view.visibleRowCount == total && p.playlist.count == total,
                  String(format: "n=\(view.totalCount) 建表=%.1f ms", addMs))

        // 纯判定（不碰表格）：ASCII 与非 ASCII 两条路各扫一遍
        let m0 = Date()
        let rowsASCII = TrackFilter(keyword: asciiKW).visibleRows(in: tracks)
        let asciiMs = Date().timeIntervalSince(m0) * 1000
        let m1 = Date()
        let rowsCJK = TrackFilter(keyword: cjkKW).visibleRows(in: tracks)
        let cjkMs = Date().timeIntervalSince(m1) * 1000
        ctx.check("性能-一万行纯判定与手算一致",
                  rowsASCII.count == expectASCII && rowsCJK.count == expectCJK,
                  String(format: "ascii=%d cjk=%d 应=%d/%d", rowsASCII.count, rowsCJK.count, expectASCII, expectCJK))

        // 整趟重画（建全局索引 + 命中 + 换一整页表格）：走的就是用户那一条入口。
        // 用中文关键字量：这是两条判定路里更慢的那一条，上屏时间就取决于它。
        // F05 之后关键字不再过表格的条件，而是交给控制器做全局搜索，
        // 所以这一趟也得从那里进（面板防抖之后叫的就是同一个方法）
        view.setFilter(TrackFilter.none)
        ctx.pump(0.2)
        let p0 = Date()
        p.applyGlobalSearch(TrackFilter(keyword: cjkKW, formats: []))
        let passMs = Date().timeIntervalSince(p0) * 1000
        let passRows = view.visibleRowCount
        ctx.check("性能-一万行换一次全局搜索结果对",
                  passRows == expectCJK && p.isSearching && p.playlist.count == expectCJK,
                  String(format: "n=%d 应=%d 一趟=%.1f ms", passRows, expectCJK, passMs))

        // 连续敲字：每一下的同步开销取最大值（防抖之前的那一段才是手能感觉到的）
        let keys = ["L", "Li", "Liv", "Live", "Live ", "Live S", "Live Se", "Live Ses"]
        var typeMax: Double = 0
        for kw in keys {
            let t0 = Date(); panel.applySearchText(kw)
            typeMax = max(typeMax, Date().timeIntervalSince(t0) * 1000)
            ctx.pump(0.02)      // 打字间隙：比 120 ms 防抖短，模拟连打
        }
        #if DEBUG
        let typeBudget = 4.0
        let passBudget = 200.0
        let e2eBudget = 500.0
        let flavor = "debug"
        #else
        let typeBudget = 2.0
        let passBudget = 120.0
        let e2eBudget = 400.0
        let flavor = "release"
        #endif
        ctx.check("性能-一万行连打八字不拖手", typeMax > 0 && typeMax <= typeBudget,
                  String(format: "单次最大=%.2f ms ≤ %.1f ms", typeMax, typeBudget))
        ctx.check("性能-一万行最慢一趟重画", passMs > 0 && passMs <= passBudget,
                  String(format: "%.1f ms ≤ %.1f ms", passMs, passBudget))

        // 从敲下最后一个字到结果上屏（含防抖那一小段）
        func waitResult(_ timeout: Double, _ want: Int) -> (ok: Bool, ms: Double) {
            let begin = Date()
            while Date().timeIntervalSince(begin) < timeout {
                if view.visibleRowCount == want { return (true, Date().timeIntervalSince(begin) * 1000) }
                ctx.pump(0.005)
            }
            return (view.visibleRowCount == want, Date().timeIntervalSince(begin) * 1000)
        }
        panel.applySearchText(asciiKW)
        let e2e = waitResult(3.0, expectASCII)
        ctx.check("性能-一万行英文敲完到结果上屏", e2e.ok && e2e.ms <= e2eBudget,
                  String(format: "%.0f ms ≤ %.0f ms（n=%d 应=%d）", e2e.ms, e2eBudget, view.visibleRowCount, expectASCII))
        panel.applySearchText(cjkKW)
        let e2eCJK = waitResult(3.0, expectCJK)
        ctx.check("性能-一万行中文敲完到结果上屏", e2eCJK.ok && e2eCJK.ms <= e2eBudget,
                  String(format: "%.0f ms ≤ %.0f ms（n=%d 应=%d）", e2eCJK.ms, e2eBudget, view.visibleRowCount, expectCJK))

        // 再叠一个格式档：组合条件不该比单条件慢出一个量级。
        // 搜索态里表格装的就是命中表：分母不再是那一万行，比的是命中数
        panel.toggleFormatForTest("FLAC")
        let expectBoth = rowsCJK.filter { tracks[$0].filterFormat == "FLAC" }.count
        let both = waitResult(3.0, expectBoth)
        ctx.check("性能-一万行组合筛选也对",
                  both.ok && view.isFiltering && p.playlist.count == expectBoth,
                  String(format: "n=%d 应=%d 用时=%.0f ms", view.visibleRowCount, expectBoth, both.ms))

        // 机器与数据条件：换人换机跑时先看这行
        var brand = "unknown"
        var nameSize = 256
        let nameBuf = UnsafeMutablePointer<CChar>.allocate(capacity: 256)
        if sysctlbyname("machdep.cpu.brand_string", nameBuf, &nameSize, nil, 0) == 0 {
            brand = String(cString: nameBuf)
        }
        nameBuf.deallocate()
        let info = ProcessInfo.processInfo
        ctx.emit(String(format: "[selftest] 参考 搜索一万行（%@ / %d 核 / %.0f GB / %@ / %@）："
                            + "入表 %.1f ms、单趟重画 %.1f ms、ASCII 判定 %.1f ms、中文判定 %.1f ms、"
                            + "连打峰值 %.2f ms、英文到上屏 %.0f ms、中文到上屏 %.0f ms（数据：模拟元数据，"
                            + "%d 条×4 档，5%% 中文标题）",
                        brand, info.activeProcessorCount, Double(info.physicalMemory) / 1_073_741_824,
                        info.operatingSystemVersionString, flavor,
                        addMs, passMs, asciiMs, cjkMs, typeMax, e2e.ms, e2eCJK.ms, total))

        // 收尾：把一万行与搜索一起清掉（连放大镜一起收回），别留给后面那套
        panel.collapseSearch()
        view.clearFilter()
        p.clearPlaylist()
        ctx.pump(0.2)
    }
}
