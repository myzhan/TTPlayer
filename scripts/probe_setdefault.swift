// 探针：能不能改「系统默认输出设备」（F07 的「默认设备变化不抢输出」必须真改一次才验得成）
//   swift scripts/probe_setdefault.swift
// 关心的三件事：
//   1. AudioObjectSetPropertyData(kAudioHardwarePropertyDefaultOutputDevice) 要不要权限、status 是几
//   2. 改完之后读回是不是那台、别的 app 会不会跟着换（读默认值即可佐证）
//   3. 把默认指到一台「已经不存在的设备」会怎样（拔出那档的另一种写法，不能卡死）
import AudioToolbox
import CoreAudio
import Foundation

func addr(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
}
func stringProp(_ selector: AudioObjectPropertySelector, _ id: AudioObjectID) -> String {
    var a = addr(selector)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, let got = value else { return "" }
    return got.takeRetainedValue() as String
}
func allDevices() -> [AudioDeviceID] {
    var a = addr(kAudioHardwarePropertyDevices)
    var size = UInt32(0)
    let sys = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr,
          size >= UInt32(MemoryLayout<AudioDeviceID>.size) else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}
func readDefault() -> AudioDeviceID {
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
    return id
}
func setDefault(_ id: AudioDeviceID) -> OSStatus {
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
    var device = id
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil,
                                      UInt32(MemoryLayout<AudioDeviceID>.size), &device)
}

func outChannels(_ id: AudioDeviceID) -> Int {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                       mScope: kAudioObjectPropertyScopeOutput,
                                       mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr,
          size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
    let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { ptr.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, ptr) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(ptr.assumingMemoryBound(to: AudioBufferList.self))
    var c = 0
    for i in 0..<list.count { c += Int(list[i].mNumberChannels) }
    return c
}

let sys = AudioObjectID(kAudioObjectSystemObject)
let original = readDefault()
print("开局默认 id=\(original)「\(stringProp(kAudioDevicePropertyDeviceNameCFString, original))」")
print("清单：" + allDevices().map { "id=\($0)「\(stringProp(kAudioDevicePropertyDeviceNameCFString, $0))」" }
    .joined(separator: " | "))

// 监听一次默认变化，确认「事件真会来」（自检要靠它驱动对账）
final class Box { var fired = 0 }
let box = Box()
let block: AudioObjectPropertyListenerBlock = { _, _ in box.fired += 1 }
var watchAddr = addr(kAudioHardwarePropertyDefaultOutputDevice)
print("挂监听 status=\(AudioObjectAddPropertyListenerBlock(sys, &watchAddr, DispatchQueue.main, block))")

// 只在「真能出声」的设备之间挪默认：把默认指到麦克风会让本机所有应用瞬间没声音，
// 探针不该拿用户当代价
let others = allDevices().filter { $0 != original && outChannels($0) > 0 }
for target in others.prefix(2) {
    let st = setDefault(target)
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
    print("改成 id=\(target)「\(stringProp(kAudioDevicePropertyDeviceNameCFString, target))」 status=\(st)"
        + " 读回=\(readDefault()) 监听触发=\(box.fired)")
}
// 指到一台并不存在的设备：不能崩、也不能把默认改掉
let st = setDefault(99_999)
print("指到不存在的 id status=\(st) 读回=\(readDefault())")

let back = setDefault(original)
RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
print("改回 status=\(back) 读回=\(readDefault()) 应为 \(original)")
AudioObjectRemovePropertyListenerBlock(sys, &watchAddr, DispatchQueue.main, block)
