// 探针：销毁一台「正被本进程音频 IO 用着」的聚合设备会不会卡住调用线程
//   swift scripts/probe_destroy_inuse.swift
// 背景：自检要验「播放中把设备拔掉」。实测在自检里直接从主线程调
// `AudioHardwareDestroyAggregateDevice` 会永远不返回（主线程一挂，看门狗定时器也发不出来），
// 所以要弄清楚：是「主线程调」的问题，还是「设备在用」的问题。
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
func uint32Property(_ selector: AudioObjectPropertySelector, _ id: AudioObjectID) -> UInt32 {
    var a = addr(selector)
    var v = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    _ = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v)
    return v
}
func allDevices() -> [AudioDeviceID] {
    var a = addr(kAudioHardwarePropertyDevices)
    var size = UInt32(0)
    let sys = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr,
          size >= UInt32(MemoryLayout<AudioDeviceID>.size) else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    _ = AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids)
    return ids
}
func uidOf(_ id: AudioObjectID) -> String { stringProperty(kAudioDevicePropertyDeviceUID, id) }
func idFor(uid target: String) -> AudioDeviceID? { allDevices().first { uidOf($0) == target } }

let aggUID = "com.ttplayer.probe.inuse"
let sys = AudioObjectID(kAudioObjectSystemObject)
var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
var base = AudioDeviceID(0)
var size = UInt32(MemoryLayout<AudioDeviceID>.size)
_ = AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &base)
print("默认输出 id=\(base) uid=\(uidOf(base))")
if let stale = idFor(uid: aggUID) { _ = AudioHardwareDestroyAggregateDevice(stale) }

let props: [String: Any] = [
    kAudioAggregateDeviceUIDKey as String: aggUID,
    kAudioAggregateDeviceNameKey as String: "TTPlayer 拔出探针",
    kAudioAggregateDeviceSubDeviceListKey as String: [[kAudioSubDeviceUIDKey as String: uidOf(base)]],
    kAudioAggregateDeviceMainSubDeviceKey as String: uidOf(base),
    kAudioAggregateDeviceIsPrivateKey as String: false,
]
var created = AudioDeviceID(0)
let st = AudioHardwareCreateAggregateDevice(props as CFDictionary, &created)
print("造设备 status=\(st) id=\(created)")
guard st == noErr, created != 0 else { exit(0) }

// 起一条真出声链路：engine 跑起来、playerNode 一直在往聚合设备排块
let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
engine.attach(player)
guard let unit = engine.outputNode.audioUnit else { exit(0) }
var device = created
print("initialize status=\(AudioUnitInitialize(unit)) 切到聚合 status=\(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)))")
let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
engine.connect(player, to: engine.mainMixerNode, format: fmt)
engine.mainMixerNode.outputVolume = 0
var ticks = 0
player.installTap(onBus: 0, bufferSize: 4_096, format: fmt) { _, _ in ticks += 1 }
try! engine.start()
player.play()
let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44_100)!
buf.frameLength = 44_100
for ch in 0..<2 { for i in 0..<44_100 { buf.floatChannelData![ch][i] = 0.2 } }
for _ in 0..<8 { player.scheduleBuffer(buf, completionHandler: nil) }
Thread.sleep(forTimeInterval: 1.0)
print("播着：isRunning=\(engine.isRunning) tap 回调=\(ticks)")
var cur = AudioDeviceID(0)
var csize = UInt32(MemoryLayout<AudioDeviceID>.size)
let rd = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &cur, &csize)
print("起引擎后 CurrentDevice status=\(rd) id=\(cur)（要的是 \(created)）")

/// 在指定线程发起销毁，报「调用什么时候返回」与「设备什么时候从清单消失」
func tryDestroy(onMain: Bool) {
    let done = DispatchSemaphore(value: 0)
    var status: OSStatus = -1
    func work() {
        status = AudioHardwareDestroyAggregateDevice(created)
        done.signal()
    }
    if onMain { work() } else { DispatchQueue.global(qos: .userInitiated).async(execute: work) }
    var waited = 0.0
    var gone = false
    while waited < 12 {
        if onMain { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
        else { Thread.sleep(forTimeInterval: 0.1) }
        waited += 0.1
        if idFor(uid: aggUID) == nil { gone = true; break }
    }
    let returned = done.wait(timeout: .now() + 0.2) == .success
    print("主线程发起=\(onMain) 调用返回=\(returned) status=\(status) "
          + "清单里消失=\(gone)（等了 \(String(format: "%.1f", waited)) s）"
          + " 引擎 isRunning=\(engine.isRunning) tap 回调=\(ticks)")
}

print("---- 第一轮：后台线程发起销毁 ----")
tryDestroy(onMain: false)
print("销毁后 CurrentDevice id=\(uint32Property(kAudioOutputUnitProperty_CurrentDevice, 0))")
if let again = idFor(uid: aggUID) { _ = AudioHardwareDestroyAggregateDevice(again) }
print("探针结束")
