import AppKit
import Darwin

// MARK: - 自带的诊断通道（不依赖统一日志 / Console）
//
// 三类输出全部写进 ~/Library/Logs/TTPlayer/：
//   runtime.log —— 启动、窗口、播放错误等流水（普通信息）
//   crash.log  —— 未捕获的 NSException 与致命信号（Swift trap / SIGSEGV 等）
// 设置了 TTPLAYER_PROBE 时，同一份内容额外镜像到该目录，方便命令行自检直接读。

/// 崩溃日志路径的可执行缓冲区：信号处理函数里不能走 Foundation/String 分配
private var ttCrashPathBuffer = [Int8](repeating: 0, count: 1024)
/// 崩溃日志的描述符：[0] 主日志，[1] TTPLAYER_PROBE 镜像；都在 install() 里预先打开
private var ttCrashFds: [Int32] = [-1, -1]

/// 无分配地写十进制整数（信号处理函数里不能用字符串插值）
private func tt_writeUInt(_ fd: Int32, _ value: UInt64) {
    var buf = [UInt8](repeating: 0, count: 24)
    var v = value
    var i = buf.count - 1
    repeat {
        buf[i] = UInt8(48 + v % 10)
        v /= 10
        i -= 1
    } while v > 0
    buf.withUnsafeBufferPointer { p in
        _ = write(fd, p.baseAddress! + i + 1, buf.count - i - 1)
    }
}

private func tt_writeStr(_ fd: Int32, _ s: StaticString) {
    s.withUTF8Buffer { p in _ = write(fd, p.baseAddress, p.count) }
}

/// 未捕获异常入口（写成全局函数，才能当作 C 函数指针传给 NSSetUncaughtExceptionHandler）
func tt_uncaughtExceptionHandler(_ exception: NSException) {
    var text = "==== 未捕获异常 \(Diagnostics.timestamp()) ====\n"
    text += "name  : \(exception.name.rawValue)\n"
    text += "reason: \(exception.reason ?? "<nil>")\n"
    text += "user  : \(exception.userInfo.map { String(describing: $0) } ?? "<nil>")\n"
    text += "栈:\n" + exception.callStackSymbols.joined(separator: "\n") + "\n\n"
    Diagnostics.writeCrash(text)
}

/// 致命信号处理：只做 async-signal-safe 的事（write/backtrace_symbols_fd）
func tt_fatalSignalHandler(_ sig: Int32) {
    for i in ttCrashFds.indices {
        // 主日志兜底：install() 万一没打开成功，现场再 open 一次（镜像目录不做兜底）
        let fd = ttCrashFds[i] >= 0 ? ttCrashFds[i]
            : (i == 0 ? open(&ttCrashPathBuffer, O_WRONLY | O_APPEND | O_CREAT, 0o644) : -1)
        guard fd >= 0 else { continue }
        tt_writeStr(fd, "---- fatal signal ----\nsignal=")
        tt_writeUInt(fd, UInt64(sig))
        tt_writeStr(fd, " pid=")
        tt_writeUInt(fd, UInt64(getpid()))
        tt_writeStr(fd, " epoch=")
        tt_writeUInt(fd, UInt64(time(nil)))
        tt_writeStr(fd, "\n栈:\n")
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let depth = backtrace(&frames, 64)
        backtrace_symbols_fd(&frames, Int32(depth), fd)
        tt_writeStr(fd, "\n")
    }
    // 恢复默认处置并重新抛出，让系统照常生成 .ips 报告
    signal(sig, SIG_DFL)
    raise(sig)
}

enum Diagnostics {
    /// 日志根目录（首次访问时创建）
    static let logDir: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/TTPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 设置了 TTPLAYER_PROBE 时的镜像目录（自检模式）
    static let mirrorDir: String? = ProcessInfo.processInfo.environment["TTPLAYER_PROBE"]

    static let startDate = Date()

    /// 启动耗时（毫秒）：从本类型初始化（main 一开始就 install）到窗口与状态栏就绪。
    /// 自检拿它当第一支柱的基线之一；与 runtime.log 里那行 "+0.4s 启动完成" 同源
    private(set) static var readyMs: Double = 0
    static func markReady() {
        readyMs = Date().timeIntervalSince(startDate) * 1000
    }
    private static let queue = DispatchQueue(label: "tt.diagnostics.io", qos: .utility)
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    private static var installed = false

    static func timestamp() -> String { formatter.string(from: Date()) }

    /// 安装异常与信号处理，并打一条启动日志。应在 NSApplication 创建之前调用。
    static func install() {
        guard !installed else { return }
        installed = true

        let crashPath = logDir.appendingPathComponent("crash.log").path
        ttCrashFds[0] = open(crashPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        if let dir = mirrorDir {
            ttCrashFds[1] = open("\(dir)/crash.log", O_WRONLY | O_APPEND | O_CREAT, 0o644)
        }
        _ = crashPath.withCString { src in
            strlcpy(&ttCrashPathBuffer, src, ttCrashPathBuffer.count)
        }

        // AppKit 在布局/绘制阶段抛出的 NSException 会被吞掉或转成崩溃，这里先把原因与栈落盘
        NSSetUncaughtExceptionHandler(tt_uncaughtExceptionHandler)
        for sig in [SIGABRT, SIGILL, SIGTRAP, SIGSEGV, SIGBUS, SIGFPE] {
            _ = signal(sig, tt_fatalSignalHandler)
        }

        let env = ProcessInfo.processInfo.environment
        log("启动 pid=\(getpid()) app=\(ProcessInfo.processInfo.processName) "
            + "selftest=\(env["TTPLAYER_SELFTEST"] ?? "nil") testdir=\(env["TTPLAYER_TESTDIR"] ?? "nil") "
            + "日志目录=\(logDir.path)")
    }

    /// 普通流水日志（异步写，不阻塞主线程）
    static func log(_ text: String) {
        let line = "\(timestamp()) +\(String(format: "%.2f", Date().timeIntervalSince(startDate)))s "
            + "[t\(Thread.isMainThread ? "main" : "bg")] \(text)\n"
        queue.async {
            append(line, to: logDir.appendingPathComponent("runtime.log"))
            if let dir = mirrorDir { append(line, to: URL(fileURLWithPath: dir).appendingPathComponent("runtime.log")) }
            rotateIfNeeded(logDir.appendingPathComponent("runtime.log"))
        }
    }

    /// 错误级日志：同时进入 runtime.log 与 crash.log（进程还可能活着，只是链路失败）
    static func error(_ text: String) {
        log("ERROR \(text)")
        writeCrash("\(timestamp()) [error] \(text)\n")
    }

    /// 立即同步写崩溃日志（异常处理里可能没有时间走异步队列）
    static func writeCrash(_ text: String) {
        queue.sync {
            append(text, to: logDir.appendingPathComponent("crash.log"))
            if let dir = mirrorDir {
                append(text, to: URL(fileURLWithPath: dir).appendingPathComponent("crash.log"))
            }
        }
    }

    /// 自检/验证用：TTPLAYER_CRASHTEST=exception|trap|signal 主动制造一次崩溃，
    /// 用来确认上面的异常/信号通道真的在写日志（不影响正常使用）
    static func runCrashTestIfRequested() {
        guard let mode = ProcessInfo.processInfo.environment["TTPLAYER_CRASHTEST"] else { return }
        log("崩溃自检模式=\(mode)（故意崩溃，请看 crash.log）")
        queue.sync { }            // 把前面的日志先落盘
        switch mode {
        case "exception":
            NSException(name: .init("TTPlayerCrashTest"),
                        reason: "故意的未捕获异常", userInfo: nil).raise()
        case "trap":
            _ = [Int](repeating: 0, count: 3)[7]        // Swift 运行时 trap
        case "signal":
            raise(SIGSEGV)
        default:
            break
        }
    }

    private static func append(_ text: String, to url: URL) {
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
            return
        }
        try? Data(text.utf8).write(to: url)   // 文件还不存在时创建
    }

    /// runtime.log 超过 512KB 时保留后半段，避免无限增长
    private static func rotateIfNeeded(_ url: URL) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 512 * 1024, let data = try? Data(contentsOf: url) else { return }
        let keep = data.suffix(256 * 1024)
        let text = "\n---- 日志滚动，截去较早的部分 ----\n" + String(decoding: keep, as: UTF8.self)
        try? Data(text.utf8).write(to: url)
    }
}
