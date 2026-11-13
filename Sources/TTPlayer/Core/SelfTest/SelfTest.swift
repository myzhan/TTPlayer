import Foundation
import AppKit

/// 自检模式：`TTPLAYER_SELFTEST=1` 时按套件驱动真实链路，跑完退出。
///
/// 用法（其余环境变量见 AGENTS.md《自检环境变量》）：
/// - `TTPLAYER_SELFTEST=1 TTPLAYER_TESTDIR=./testlib ./TTPlayer`：全量（发布门槛）
/// - 再加 `TTPLAYER_SUITE=smoke`：冒烟档，只跑纯逻辑的几套，几秒出结果
/// - 再加 `TTPLAYER_SUITE=ui,import`：只跑指定套件（逗号或空白分隔，按你给的顺序执行）
final class SelfTest {
    private static var finished = false
    private static var reportPath = ""
    /// 计时榜取前多少条（只占 stderr / 报告文件末尾几行，再长就没人看了）
    private static let timingTop = 25
    /// 看门狗：异步链路卡住时不能一直挂着。这是整轮的总时长闸门，不是单套的——
    /// 衔接类断言只认从输出链路上抄下来的 PCM，必须跑真实时钟（debug 全量实测：
    /// gapless 38 s、gain 54 s、radio 24 s，整轮约 226 s；radio 的退避在自检里按 1/8 压缩，
    /// 见 RadioPlayer.retryScale）；机器忙时会飘，所以给三倍余量。
    /// 真卡住时日志停在哪一套后面一眼就能看出来
    private static let watchdogSeconds: Double = 900

    /// 写 stderr + 报告文件 + 运行日志（GUI 环境下 stderr 可能不可见）
    static func emit(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
        Diagnostics.log(s)
        if !reportPath.isEmpty {
            if let fh = FileHandle(forWritingAtPath: reportPath) {
                fh.seekToEndOfFile()
                fh.write((s + "\n").data(using: .utf8)!)
                fh.closeFile()
            } else {
                try? (s + "\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
            }
        }
    }

    static func run_ifRequested(main: MainWindowController) {
        let env = ProcessInfo.processInfo.environment
        guard env["TTPLAYER_SELFTEST"] != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + watchdogSeconds) {
            if !finished {
                emit("[selftest] ===== 超时退出（链路卡住）=====")
                exit(2)
            }
        }
        let dir = URL(fileURLWithPath: env["TTPLAYER_TESTDIR"]
                        ?? FileManager.default.currentDirectoryPath + "/testlib",
                      isDirectory: true)
        /// 目视验证用的截图目录（不设就不拍）
        let shotDir = env["TTPLAYER_SHOTDIR"]
        reportPath = (env["TTPLAYER_PROBE"] ?? FileManager.default.currentDirectoryPath) + "/tt_selftest.txt"
        try? "--- selftest start ---\n".write(toFile: reportPath, atomically: true, encoding: .utf8)

        guard let selection = selection(from: env) else {
            let wanted = env["TTPLAYER_SUITE"] ?? ""
            emit("[selftest] 不认识的套件：\(wanted)")
            emit("[selftest] 可用套件：\(SuiteID.all.map { $0.rawValue }.joined(separator: " ")) "
                 + "+ smoke（冒烟）/ core（全量去掉取证三套）/ all（全量）")
            finished = true
            exit(2)
        }

        emit("[selftest] 测试目录: \(dir.path)")
        emit("[selftest] 套件: \(selection.map { $0.rawValue }.joined(separator: ","))")

        let ctx = SelfTestContext(main: main, dir: dir, shotDir: shotDir)
        let started = Date()
        var suiteWalls: [String: Double] = [:]
        for id in selection {
            let before = ctx.total
            let suiteStarted = Date()
            emit("[selftest] ==== 套件 \(id.rawValue) · \(id.title) ====")
            // 计时基准在 prepare 之前打好：前置（建窗 / 重灌曲库）本身就是耗时大户，
            // 拿不进任何一条断言的余额会在最后的分套件汇总里显形
            ctx.beginSuite(id.rawValue)
            // 每套一个自动释放池：拆分后所有套件同步跑在同一个 runloop 回合里，
            // 池子不排空的话前面套件产生的临时对象会一直留到退出（实测 RSS 多 20+ MB）
            autoreleasepool {
                // 前置由 runner 统一备好：套件单跑也不会缺曲目/窗口/CUE 素材
                ctx.prepare(id.needs)
                id.makeSuite().run(ctx)
            }
            let secs = Date().timeIntervalSince(suiteStarted)
            suiteWalls[id.rawValue] = secs
            // 用时也写出来：全量总时长顶到看门狗时，靠这几行就能定位是哪套变慢了
            emit(String(format: "[selftest] ==== 套件 %@ 结束：%d 项 / %.1f s，RSS %.1f MB ====",
                        id.rawValue, ctx.total - before, secs, ctx.residentMB()))
        }
        emit(String(format: "[selftest] 合计 %d 项 / %d 失败 / 用时 %.1f s",
                    ctx.total, ctx.failures.count, Date().timeIntervalSince(started)))
        if SelfTestContext.timingEnabled {
            reportTimings(ctx, walls: suiteWalls, total: Date().timeIntervalSince(started))
        }
        finish(ctx.failures)
    }

    /// `TTPLAYER_TIMING=1` 的尾巴：最慢的几条断言 + 分套件余额（前置/收尾没落到断言上的时间）。
    /// 单条耗时是「上一条到这一条」的差值，setup 归给紧跟其后的那条断言，名字对得上现场代码
    private static func reportTimings(_ ctx: SelfTestContext, walls: [String: Double],
                                      total: TimeInterval) {
        let rows = ctx.timings
        guard !rows.isEmpty else { return }
        emit(String(format: "[timing] ===== 计时榜（共 %d 条计入，合计 %.1f s / 整轮 %.1f s）=====",
                    rows.count, rows.reduce(0) { $0 + $1.ms } / 1000, total))
        for row in rows.sorted(by: { $0.ms > $1.ms }).prefix(timingTop) {
            emit(String(format: "[timing] %6.2f s  %@ · %@",
                        row.ms / 1000, row.suite, row.name))
        }
        // 逐套拆成「计入断言的秒数」与「余额」：余额大就得去看 prepare/收尾，不是断言本身慢
        var perSuite: [String: Double] = [:]
        var perCount: [String: Int] = [:]
        for row in rows {
            perSuite[row.suite, default: 0] += row.ms / 1000
            perCount[row.suite, default: 0] += 1
        }
        emit("[timing] ----- 分套件：整套 / 计入 / 余额（余额 = 前置与收尾，不挂在任何断言上）-----")
        for (suite, secs) in walls.sorted(by: { $0.value > $1.value }) {
            let got = perSuite[suite] ?? 0
            emit(String(format: "[timing] %@: %.1f s = 计入 %d 条 %.1f s + 余额 %.1f s",
                        suite, secs, perCount[suite] ?? 0, got, secs - got))
        }
    }

    /// 解析 `TTPLAYER_SUITE`：不设或 all = 全量，smoke = 冒烟，core = 全量去掉取证三套，
    /// 其余按逗号分隔的套件名。有任何一个名字不认识就返回 nil（宁可报错，也不静默少跑几套）
    private static func selection(from env: [String: String]) -> [SuiteID]? {
        let raw = (env["TTPLAYER_SUITE"] ?? "all")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw.isEmpty || raw == "all" { return SuiteID.all }
        if raw == "smoke" { return SuiteID.smoke }
        if raw == "core" { return SuiteID.core }
        var ids: [SuiteID] = []
        var unknown: [String] = []
        // 逗号与空白都当分隔符：`TTPLAYER_SUITE="ui import"` 与 `ui,import` 等价
        for token in raw.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
            let name = String(token)
            guard let id = SuiteID(rawValue: name) else {
                unknown.append(name)
                continue
            }
            if !ids.contains(id) { ids.append(id) }
        }
        guard unknown.isEmpty, !ids.isEmpty else { return nil }
        return ids
    }

    private static func finish(_ failures: [String]) {
        finished = true
        PlayerController.shared.stop()
        if failures.isEmpty {
            emit("[selftest] ===== 全部通过 =====")
        } else {
            emit("[selftest] ===== 失败 \(failures.count) 项: \(failures) =====")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            exit(failures.isEmpty ? 0 : 1)
        }
    }
}
