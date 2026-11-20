// 聚合设备探针第二轮（第一轮事实：能造出来，但 AUHAL 切过去 status=-10851、销毁后仍在新列表里）
//   swift scripts/probe_aggregate.swift
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

func addr(_ selector: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                               mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
}

func stringProperty(_ selector: AudioObjectPropertySelector, _ id: AudioObjectID) -> String {
    var a = addr(selector)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, let got = value else { return "" }
    return got.takeRetainedValue() as String
}

func uid(_ id: AudioObjectID) -> String { stringProperty(kAudioDevicePropertyDeviceUID, id) }
func name(_ id: AudioObjectID) -> String { stringProperty(kAudioDevicePropertyDeviceNameCFString, id) }

func allDevices() -> [AudioDeviceID] {
    var a = addr(kAudioHardwarePropertyDevices)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr
    else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr
    else { return [] }
    return ids
}
func deviceID(forUID target: String) -> AudioDeviceID? { allDevices().first { uid($0) == target } }

func float64Property(_ selector: AudioObjectPropertySelector, _ id: AudioObjectID) -> Double {
    var a = addr(selector)
    var v = Float64(0)
    var size = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return -1 }
    return v
}
func uint32Property(_ selector: AudioObjectPropertySelector, _ id: AudioObjectID,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Int {
    var a = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                       mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
    var v = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return -1 }
    return Int(v)
}
func outChannels(_ id: AudioObjectID) -> Int {
    var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
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
func fourCC(_ code: OSStatus) -> String {
    let v = UInt32(bitPattern: code)
    let chars: [UInt8] = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                          UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    return String(bytes: chars, encoding: .ascii) ?? "?"
}
func dump(_ tag: String) {
    print("\(tag)：" + allDevices().map { "id=\($0)「\(name($0))」输\(outChannels($0))率\(Int(float64Property(kAudioDevicePropertyNominalSampleRate, $0)))活\(uint32Property(kAudioDevicePropertyDeviceIsAlive, $0))" }.joined(separator: " | "))
}

let base = AudioObjectID(uint32Property(kAudioHardwarePropertyDefaultOutputDevice,
                                        AudioObjectID(kAudioObjectSystemObject)))
print("默认输出 id=\(base) uid=\(uid(base)) 名=「\(name(base))」")
dump("开局清单")

let aggUID = "com.ttplayer.selftest.aggregate"
if let stale = deviceID(forUID: aggUID) {
    print("上一轮遗留的聚合设备 id=\(stale) → 先销毁 status=\(AudioHardwareDestroyAggregateDevice(stale))")
    dump("销毁遗留后")
}

let props: [String: Any] = [
    kAudioAggregateDeviceUIDKey as String: aggUID,
    kAudioAggregateDeviceNameKey as String: "TTPlayer 探针设备",
    // 子设备清单：数组里每一项是一个「描述子设备的小字典」，UID 写在 kAudioSubDeviceUIDKey 下
    // （直接把 UID 数组放外面，造出来的设备 0 声道、标称率 0，切不过去）
    kAudioAggregateDeviceSubDeviceListKey as String: [
        [kAudioSubDeviceUIDKey as String: uid(base)],
    ],
    kAudioAggregateDeviceMainSubDeviceKey as String: uid(base),
    kAudioAggregateDeviceIsPrivateKey as String: false,
]
var created = AudioDeviceID(0)
var st = AudioHardwareCreateAggregateDevice(props as CFDictionary, &created)
print("CreateAggregateDevice status=\(st) id=\(created) uid=\(uid(created)) 名=「\(name(created))」"
      + " 输出声道=\(outChannels(created)) 标称率=\(Int(float64Property(kAudioDevicePropertyNominalSampleRate, created)))"
      + " IsAlive=\(uint32Property(kAudioDevicePropertyDeviceIsAlive, created))")
guard st == noErr, created != 0 else { exit(0) }
dump("造好之后")

// 切设备：AUHAL 先 initialize 再切（第一轮没 initialize 直接切得到 -10851）
let engine = AVAudioEngine()
engine.mainMixerNode.outputVolume = 0
guard let unit = engine.outputNode.audioUnit else { print("拿不到 AUHAL"); exit(0) }
var device = created
let initSt = AudioUnitInitialize(unit)
st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                          &device, UInt32(MemoryLayout<AudioDeviceID>.size))
print("initialize status=\(initSt) 切到聚合 status=\(st) (\(fourCC(st)))")
if st != noErr {
    // 未初始化时能切成功（第一轮对内置设备成立），对聚合设备成立与否也要报出来
    AudioUnitUninitialize(unit)
    st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                              &device, UInt32(MemoryLayout<AudioDeviceID>.size))
    print("uninitialize 后再切 status=\(st) (\(fourCC(st)))")
}
var asize = UInt32(MemoryLayout<AudioDeviceID>.size)
var cur = AudioDeviceID(0)
let readSt = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                  &cur, &asize)
print("读回 CurrentDevice status=\(readSt) id=\(cur) 名=「\(readSt == noErr ? name(cur) : "-")」")
let fmt = engine.outputNode.inputFormat(forBus: 0)
print("输出节点输入格式 率=\(fmt.sampleRate) 声道=\(fmt.channelCount)")
var ticks = 0
if fmt.sampleRate > 0 {
    engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { _, _ in ticks += 1 }
}
do {
    try engine.start()
    Thread.sleep(forTimeInterval: 0.3)
    print("引擎 isRunning=\(engine.isRunning) 渲染回调=\(ticks)")
    engine.stop()
} catch {
    print("引擎起不来：\(error)")
}
engine.mainMixerNode.removeTap(onBus: 0)

// 拔出：销毁正被引用的聚合设备，看列表与 AUHAL 各自怎么说
let destroy = AudioHardwareDestroyAggregateDevice(created)
print("销毁 status=\(destroy) uid 还在列表=\(deviceID(forUID: aggUID) != nil)")
// 销毁可能是异步的：等半秒再看列表，才知道「拔出」什么时候能被观测到
Thread.sleep(forTimeInterval: 0.5)
print("等 0.5 s 后 uid 还在列表=\(deviceID(forUID: aggUID) != nil)")
dump("销毁之后")
asize = UInt32(MemoryLayout<AudioDeviceID>.size)
cur = 0
let after = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &cur, &asize)
print("销毁后读 CurrentDevice status=\(after) id=\(cur) 名=「\(after == noErr ? name(cur) : "-")」")
