// F08 前置实测：FSEvents 能不能当目录监控用（延迟、事件粒度、增删改是否都回话），
// 以及 FileManager 的目录枚举遇到符号链接循环会怎样（会不会无限递归）。
// 跑法：swift -O scripts/probe_fsevents.swift
import Foundation
import AppKit
import CoreServices

let base = URL(fileURLWithPath: "/tmp/tt_probe_library", isDirectory: true)
try? FileManager.default.removeItem(at: base)
try FileManager.default.createDirectory(at: base.appendingPathComponent("子目录", isDirectory: true),
                                        withIntermediateDirectories: true)

// ---- ① FSEvents：能不能在 1 s 内把新增/改名/删除都报回来 ----
let got = LockArray<(path: String, flags: FSEventStreamEventFlags)>()
let started = Date()
let queue = DispatchQueue(label: "probe.fsevents")
let paths = [base.path] as CFArray
var context = FSEventStreamContext(version: 0,
                                   info: Unmanaged.passUnretained(got).toOpaque(),
                                   retain: nil, release: nil, copyDescription: nil)
let stream = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, eventPaths, eventFlags, _ in
    guard let info, count > 0 else { return }
    let sink = Unmanaged<LockArray<(String, FSEventStreamEventFlags)>>.fromOpaque(info).takeUnretainedValue()
    // 不开 UseCFTypes：路径数组是 char* 的数组，得自己按条数绑回去
    let names = eventPaths.bindMemory(to: UnsafePointer<CChar>.self, capacity: Int(count))
    let fl = UnsafeBufferPointer(start: eventFlags, count: Int(count))
    for i in 0..<Int(count) {
        sink.append((String(cString: names[i]), fl[i]), at: Date().timeIntervalSince(started))
    }
}, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
   FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents))
guard let stream else { print("FSEventStreamCreate 返回空句柄（本机不能监控目录）"); exit(1) }
FSEventStreamSetDispatchQueue(stream, queue)
FSEventStreamStart(stream)

let probe = base.appendingPathComponent("probe.wav")
FileManager.default.createFile(atPath: probe.path, contents: Data([1, 2, 3]))
Thread.sleep(forTimeInterval: 1.0)
let moved = base.appendingPathComponent("probe2.wav")
try? FileManager.default.moveItem(at: probe, to: moved)
Thread.sleep(forTimeInterval: 1.0)
try? FileManager.default.removeItem(at: moved)
let sub = base.appendingPathComponent("子目录/在里面.wav")
Thread.sleep(forTimeInterval: 1.0)
FileManager.default.createFile(atPath: sub.path, contents: Data([4]))
Thread.sleep(forTimeInterval: 1.5)

print("FSEvents 收到 \(got.items.count) 条，首条延迟 "
      + String(format: "%.2f s", got.firstDelay ?? -1))
for it in got.items {
    print("  \(it.path.replacingOccurrences(of: base.path, with: "…")) flags=0x\(String(it.flags, radix: 16))")
}
FSEventStreamStop(stream)
FSEventStreamInvalidate(stream)
FSEventStreamRelease(stream)
print("流已停")

// 事件标志位含义对照（自检只靠这些位区分增/删/改）
func flagNames(_ f: FSEventStreamEventFlags) -> [String] {
    var out: [String] = []
    if f & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0 { out.append("新建") }
    if f & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0 { out.append("删除") }
    if f & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0 { out.append("改名") }
    if f & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified) != 0 { out.append("修改") }
    if f & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 { out.append("目录") }
    return out
}
print("标志名示例：\(got.items.first.map { flagNames($0.flags) } ?? [])")

// ---- ② 符号链接循环：FileManager 的 URL 枚举会不会自己走回去 ----
let loop = base.appendingPathComponent("循环", isDirectory: true)
try FileManager.default.createDirectory(at: loop, withIntermediateDirectories: true)
FileManager.default.createFile(atPath: loop.appendingPathComponent("song.wav").path, contents: Data([1]))
try? FileManager.default.createSymbolicLink(at: loop.appendingPathComponent("自己"),
                                            withDestinationURL: loop)
try? FileManager.default.createSymbolicLink(at: loop.appendingPathComponent("指回上层"),
                                            withDestinationURL: base)
var counted = 0, dirs = 0
let t0 = Date()
if let en = FileManager.default.enumerator(at: loop, includingPropertiesForKeys: nil,
                                           options: [.skipsHiddenFiles]) {
    for case let u as URL in en {
        counted += 1
        if u.lastPathComponent == "自己" || u.lastPathComponent == "指回上层" { dirs += 1 }
        if counted > 2000 { break }     // 兜底：真无限递归就靠这一行跳出
    }
}
print("符号链接循环：枚举到 \(counted) 项（其中链接本身 \(dirs) 项），耗时 \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
print("realpath 能不能识破：\(loop.resolvingSymlinksInPath().path) == \(loop.path) ?"
      + " \((loop.resolvingSymlinksInPath().path == loop.path))")
var val = stat()
let st = stat(loop.path, &val)
print("stat inode=\(val.st_ino) dev=\(val.st_dev)（链接指回同一目录时应当相同）rc=\(st)")
// 链接项的 URL 与真实目录的 URL 是否同一路径
if let en = FileManager.default.enumerator(at: loop, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileIdentifierKey],
                                           options: [.skipsHiddenFiles]) {
    for case let u as URL in en {
        let r = try? u.resourceValues(forKeys: [.isSymbolicLinkKey, .fileIdentifierKey])
        if r?.isSymbolicLink == true {
            print("链接项 \(u.lastPathComponent)：fileIdentifier=\(String(describing: r?.fileIdentifier)) "
                  + "解析后=\(u.resolvingSymlinksInPath().path.replacingOccurrences(of: base.path, with: "…"))")
        }
        break
    }
}
try? FileManager.default.removeItem(at: base)

/// 带锁的收集器：回调在专用队列，主线程要读
final class LockArray<T> {
    private let lock = NSLock()
    private var _items: [T] = []
    private var _firstDelay: Double?
    var items: [T] { lock.lock(); defer { lock.unlock() }; return _items }
    var firstDelay: Double? { lock.lock(); defer { lock.unlock() }; return _firstDelay }
    func append(_ v: T, at delay: Double) {
        lock.lock()
        _items.append(v)
        if _firstDelay == nil { _firstDelay = delay }
        lock.unlock()
    }
}
