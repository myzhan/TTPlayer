// 列出某个进程当前在屏的窗口 id 与几何，供截图验证用：
//   swift scripts/probe_windows.swift <pid>
//   screencapture -x -o -l<窗口id> main.png
// （screencapture 只能按窗口 id 截单个窗，所以先要知道 id）
import CoreGraphics
import Foundation

guard CommandLine.arguments.count > 1, let target = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write("用法：swift scripts/probe_windows.swift <pid>\n".data(using: .utf8)!)
    exit(1)
}
let options: CGWindowListOption = [.optionOnScreenOnly]
guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    print("拿不到窗口列表")
    exit(1)
}
for window in info {
    guard (window[kCGWindowOwnerPID as String] as? Int32) == target else { continue }
    let number = window[kCGWindowNumber as String] as? Int ?? 0
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let name = window[kCGWindowName as String] as? String ?? ""
    print("id=\(number) \(bounds["X"] ?? 0),\(bounds["Y"] ?? 0) "
        + "\(bounds["Width"] ?? 0)x\(bounds["Height"] ?? 0) \(name)")
}
