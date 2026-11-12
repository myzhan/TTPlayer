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
    /// 看门狗：异步链路卡住时不能一直挂着。这是整轮的总时长闸门，不是单套的——
    /// 衔接类断言只认从输出链路上抄下来的 PCM，必须跑真实时钟（gapless 一套就要 48 s、
    /// radio 46 s、gain 88 s），debug 全量实测约 291 s；机器忙时会飘，所以给三倍余量。
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
                 + "+ smoke（冒烟）/ all（全量）")
            finished = true
            exit(2)
        }

        emit("[selftest] 测试目录: \(dir.path)")
        emit("[selftest] 套件: \(selection.map { $0.rawValue }.joined(separator: ","))")

        let ctx = SelfTestContext(main: main, dir: dir, shotDir: shotDir)
        let started = Date()
        for id in selection {
            let before = ctx.total
            let suiteStarted = Date()
            emit("[selftest] ==== 套件 \(id.rawValue) · \(id.title) ====")
            // 每套一个自动释放池：拆分后所有套件同步跑在同一个 runloop 回合里，
            // 池子不排空的话前面套件产生的临时对象会一直留到退出（实测 RSS 多 20+ MB）
            autoreleasepool {
                // 前置由 runner 统一备好：套件单跑也不会缺曲目/窗口/CUE 素材
                ctx.prepare(id.needs)
                id.makeSuite().run(ctx)
            }
            // 用时也写出来：全量总时长顶到看门狗时，靠这几行就能定位是哪套变慢了
            emit(String(format: "[selftest] ==== 套件 %@ 结束：%d 项 / %.1f s，RSS %.1f MB ====",
                        id.rawValue, ctx.total - before,
                        Date().timeIntervalSince(suiteStarted), ctx.residentMB()))
        }
        emit(String(format: "[selftest] 合计 %d 项 / %d 失败 / 用时 %.1f s",
                    ctx.total, ctx.failures.count, Date().timeIntervalSince(started)))
        finish(ctx.failures)
    }

    /// 解析 `TTPLAYER_SUITE`：不设或 all = 全量，smoke = 冒烟，其余按逗号分隔的套件名。
    /// 有任何一个名字不认识就返回 nil（宁可报错，也不静默少跑几套）
    private static func selection(from env: [String: String]) -> [SuiteID]? {
        let raw = (env["TTPLAYER_SUITE"] ?? "all")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw.isEmpty || raw == "all" { return SuiteID.all }
        if raw == "smoke" { return SuiteID.smoke }
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
