import AppKit

// 显式启动入口：NSApplication.shared + delegate + run
// （相比 @main + NSApplicationMain，此写法在命令行直接启动时也能可靠触发启动回调）

// 打包脚本用这一支无头生成 .icns 素材（图标是代码画的，仓库里不留二进制资源）
// 用法：TTPlayer --export-icon <iconset 目录>
if let idx = CommandLine.arguments.firstIndex(of: "--export-icon") {
    // 需要先实例化 NSApplication 才能取到 shared 来设激活策略
    NSApplication.shared.setActivationPolicy(.prohibited)   // 不抢焦点、不进 Dock
    guard CommandLine.arguments.count > idx + 1,
          AppIcon.exportIconset(to: CommandLine.arguments[idx + 1]) else {
        FileHandle.standardError.write("导出图标失败\n".data(using: .utf8)!)
        exit(1)
    }
    exit(0)
}

// 打包脚本用：把运行时要认的扩展名打出来（同样无头），plist 里就不必手抄一份白名单
// 用法：TTPlayer --dump-formats
if CommandLine.arguments.contains("--dump-formats") {
    print(AudioFormats.documentExtensions.joined(separator: " "))
    exit(0)
}

// 先装好诊断通道：未捕获的 NSException、致命信号、启动流水都会写进
// ~/Library/Logs/TTPlayer/{runtime.log,crash.log}，不依赖 Console / 统一日志
Diagnostics.install()

// 验证诊断通道自身可用时才会触发（TTPLAYER_CRASHTEST=exception|trap|signal）
Diagnostics.runCrashTestIfRequested()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
