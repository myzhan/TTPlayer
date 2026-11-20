// 输出设备能力探针（F07 开工前先摸清这台机器与这套 API 能给什么）：
//   swift scripts/probe_devices.swift
// 只看事实，不改任何系统设置：列设备、看默认输出、试拿 AVAudioEngine 输出节点的 AUHAL、
// 试在它上面切 CurrentDevice，再看引擎能否在新设备上跑起来。
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

func stringProperty(_ selector: AudioObjectPropertySelector, _ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: selector,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let got = value else { return "" }
    return got.takeRetainedValue() as String
}

func deviceName(_ id: AudioDeviceID) -> String {
    stringProperty(kAudioDevicePropertyDeviceNameCFString, id)
}

func deviceUID(_ id: AudioDeviceID) -> String {
    stringProperty(kAudioDevicePropertyDeviceUID, id)
}

/// 输出声道数（0 = 这不是个输出设备）
func outputChannels(_ id: AudioDeviceID) -> Int {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                          mScope: kAudioObjectPropertyScopeOutput,
                                          mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr,
          size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
    let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { ptr.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(ptr.assumingMemoryBound(to: AudioBufferList.self))
    var channels = 0
    for i in 0..<list.count { channels += Int(list[i].mNumberChannels) }
    return channels
}

/// 设备支持的采样率清单（走 NamedData 的合法套路：先问大小，再取数组）
func sampleRates(_ id: AudioDeviceID) -> [Double] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    let n = Int(size) / MemoryLayout<AudioValueRange>.size
    let ptr = UnsafeMutablePointer<AudioValueRange>.allocate(capacity: n)
    defer { ptr.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr) == noErr else { return [] }
    var out: [Double] = []
    for i in 0..<n {
        let r = ptr[i]
        var v = r.mMinimum
        while v <= r.mMaximum + 1 { out.append(v); if v == r.mMaximum { break }; v += 1 }
        if v > r.mMaximum { out.append(r.mMaximum) }
    }
    return Array(Set(out)).sorted()
}

func nominalSampleRate(_ id: AudioDeviceID) -> Double {
    var sr = Float64(0)
    var size = UInt32(MemoryLayout<Float64>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &sr) == noErr else { return 0 }
    return sr
}

func fourCC(_ v: UInt32) -> String {
    let chars: [UInt8] = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                          UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    return String(bytes: chars, encoding: .ascii) ?? "?"
}

func listed(_ ids: [AudioDeviceID], _ defaultID: AudioDeviceID) {
    print("系统默认输出 = \(defaultID) 「\(deviceName(defaultID))」")
    for id in ids {
        print("设备 id=\(id) 名=「\(deviceName(id))」 uid=\(deviceUID(id))"
              + " 输出声道=\(outputChannels(id)) 标称率=\(Int(nominalSampleRate(id)))"
              + " 支持率=\(sampleRates(id).map { String(Int($0)) }.joined(separator: ","))"
              + (id == defaultID ? "  ←默认" : ""))
    }
}

var size = UInt32(0)
var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                      mScope: kAudioObjectPropertyScopeGlobal,
                                      mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else {
    print("拿不到设备列表大小"); exit(1)
}
let count = Int(size) / MemoryLayout<AudioDeviceID>.size
var ids = [AudioDeviceID](repeating: 0, count: count)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)

var defaultID = AudioDeviceID(0)
size = UInt32(MemoryLayout<AudioDeviceID>.size)
addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                  mScope: kAudioObjectPropertyScopeGlobal,
                                  mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &defaultID)
listed(ids, defaultID)

// AVAudioEngine 的输出节点能不能拿到 AUHAL（F07 的实现路线全靠这一步）
let engine = AVAudioEngine()
print("outputNode = \(type(of: engine.outputNode))")
guard let unit = engine.outputNode.audioUnit else {
    print("outputNode.audioUnit = nil → AUHAL 这条路线走不通")
    exit(0)
}
print("outputNode.audioUnit = \(type(of: unit))")
let raw = unit
var asize = UInt32(MemoryLayout<AudioDeviceID>.size)
var st = OSStatus(kAudioHardwareUnspecifiedError)
// 当前 AUHAL 挂在哪个设备上（用于「明确显示当前实际输出设备」）
var cur = AudioDeviceID(0)
st = AudioUnitGetProperty(raw, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &cur, &asize)
print("读 CurrentDevice status=\(st) 设备=\(st == noErr ? "「\(deviceName(cur))」" : "-")")
// 能不能设置 CurrentDevice（AUHAL 的公开属性）
if let target = ids.first(where: { $0 != defaultID && outputChannels($0) > 0 }) {
    var device = target
    st = AudioUnitSetProperty(raw, kAudioOutputUnitProperty_CurrentDevice,
                              kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
    print("在 AUHAL 上切到「\(deviceName(target))」status=\(st)")
    if st == noErr {
        asize = UInt32(MemoryLayout<AudioDeviceID>.size)
        cur = 0
        _ = AudioUnitGetProperty(raw, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &cur, &asize)
        print("切完读回 CurrentDevice = 「\(deviceName(cur))」")
        engine.mainMixerNode.outputVolume = 0        // 探针不出声
        do {
            // 装个 tap 数回调：start() 返回成功不代表真在渲染，回调来了才算
            var ticks = 0
            let fmt = engine.outputNode.outputFormat(forBus: 0)
            print("输出节点格式 率=\(fmt.sampleRate) 声道=\(fmt.channelCount)")
            if fmt.sampleRate > 0 {
                engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { _, _ in
                    ticks += 1
                }
            }
            try engine.start()
            Thread.sleep(forTimeInterval: 0.5)
            print("切设备后引擎 isRunning=\(engine.isRunning) 50ms 渲染回调数=\(ticks)")
            engine.mainMixerNode.removeTap(onBus: 0)
            engine.stop()
        } catch {
            print("切设备后引擎起不来：\(error.localizedDescription)")
        }
    }
} else {
    print("这台机器没有第二个可用输出设备 → 设备切换只能标未实测或造虚拟设备")
}
