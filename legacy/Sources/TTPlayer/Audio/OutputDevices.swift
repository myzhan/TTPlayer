import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// CoreAudio 输出设备：枚举、按 UID 解析、变更监听，以及在 AUHAL 上读写「当前输出设备」
/// （F07）。
///
/// 只认 UID：`AudioDeviceID` 是本进程内的临时句柄，设备重插一次就换个号，把它存进档案
/// 迟早指到别的设备上去。需求里「按设备 UID 保存、不持久化临时 AudioDeviceID」就是这一条。
///
/// 换设备走 `kAudioOutputUnitProperty_CurrentDevice`（AUHAL 的公开属性）：只改本进程往
/// 哪台设备出声，不改系统默认、不进独占模式、也不动硬件采样率（实测：切完之后设备的
/// `kAudioDevicePropertyNominalSampleRate` 保持原值，采样率不同的源由混音链重采样）。
enum OutputDevices {
    /// 一台可用的输出设备。`id` 只在本次枚举里有效，`uid` 才是能落盘的身份证
    struct Device {
        let uid: String
        let name: String
        let channels: Int
        /// 设备自己报的标称采样率清单（拿不到就是空表，不替用户猜）
        let rates: [Double]
        let id: AudioDeviceID
    }

    /// 系统层面发生了什么变化（对应 CoreAudio 那两个全局属性）
    enum Change {
        /// 设备清单变了：插上新设备、拔掉旧设备、聚合设备增删都算
        case devicesChanged
        /// 系统默认输出换了
        case defaultChanged
    }

    // MARK: - 属性读写（CoreAudio 那套「先问大小再取值」的写法全收在这里）

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, on id: AudioObjectID) -> String {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let got = value else { return "" }
        return got.takeRetainedValue() as String
    }

    private static func uint32Property(_ selector: AudioObjectPropertySelector, on id: AudioObjectID,
                                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> UInt32 {
        var addr = address(selector, scope)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func float64Property(_ selector: AudioObjectPropertySelector, on id: AudioObjectID) -> Double {
        var addr = address(selector)
        var value = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return Double(value)
    }

    /// 全部设备句柄（含输入设备，靠声道数筛）
    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size = UInt32(0)
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioDeviceID>.size) else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// 输出声道数（0 = 这不是个能出声的设备，麦克风一类靠它筛掉）
    private static func outputChannels(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
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

    /// 设备支持的标称采样率（升序去重；问不到就空表）
    private static func availableRates(_ id: AudioDeviceID) -> [Double] {
        var addr = address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioValueRange>.size) else { return [] }
        let n = Int(size) / MemoryLayout<AudioValueRange>.size
        let ptr = UnsafeMutablePointer<AudioValueRange>.allocate(capacity: n)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr) == noErr else { return [] }
        var rates = Set<Double>()
        for i in 0..<n {
            let r = ptr[i]
            // 定长区间就取两端，连续区间（USB DAC 常见 mMinimum == mMaximum）取一个就够
            rates.insert(r.mMinimum)
            rates.insert(r.mMaximum)
        }
        return rates.sorted()
    }

    /// 把一个句柄说成设备（不是输出设备、或已经不应答时返回 nil）
    static func device(_ id: AudioDeviceID) -> Device? {
        let uid = stringProperty(kAudioDevicePropertyDeviceUID, on: id)
        guard !uid.isEmpty, outputChannels(id) > 0 else { return nil }
        // 设备还在清单里但已经不应答（拔的一半）：不能算它「可用」
        guard uint32Property(kAudioDevicePropertyDeviceIsAlive, on: id) != 0 else { return nil }
        return Device(uid: uid,
                      name: stringProperty(kAudioDevicePropertyDeviceNameCFString, on: id),
                      channels: outputChannels(id),
                      rates: availableRates(id),
                      id: id)
    }

    // MARK: - 对外查询

    /// 能出声的设备清单（顺序稳定：系统默认那台排最前，其余按名字）。
    /// CoreAudio 给自己用的那几台透明聚合设备不列进来，理由见 `isTransparentInternal`
    static func available() -> [Device] {
        let defaultID = systemDefaultID()
        let list = allDeviceIDs().compactMap(device).filter { !isTransparentInternal($0) }
        return list.sorted { a, b in
            if (a.id == defaultID) != (b.id == defaultID) { return a.id == defaultID }
            return a.name < b.name
        }
    }

    /// 是不是 CoreAudio 为本进程临时造的「透明聚合设备」：名字与 UID 同形，
    /// `CADefaultDeviceAggregate-<客户端 pid>-<序号>`。它有三个要命的地方：
    /// 用户听不懂那是一台什么设备、当不了系统默认（设上去系统不认）、
    /// 造它的那个进程一退就没了。所以设备菜单与自检都把它当不存在，
    /// 但 `resolve`/`exists` 仍然认它 —— 已固定的设备哪天变成这样也得说得出「还在不在」
    static func isTransparentInternal(_ device: Device) -> Bool {
        device.uid.hasPrefix(transparentPrefix) || device.name.hasPrefix(transparentPrefix)
    }

    private static let transparentPrefix = "CADefaultDeviceAggregate-"

    private static func systemDefaultID() -> AudioDeviceID {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &id) == noErr else { return 0 }
        return id
    }

    /// 当前系统默认输出（跟随档实际用的就是它）
    static func systemDefault() -> Device? {
        let id = systemDefaultID()
        guard id != 0 else { return nil }
        return device(id)
    }

    /// 按 UID 找回设备。拿不到就是「此刻不可用」（拔掉了、或换过一台同名不同 UID 的）
    static func resolve(_ uid: String) -> Device? {
        guard !uid.isEmpty else { return nil }
        return allDeviceIDs().first { stringProperty(kAudioDevicePropertyDeviceUID, on: $0) == uid }
            .flatMap(device)
    }

    /// 设备此刻在不在（只问在不在，不构造整个 Device，属性监听里用得着）
    static func exists(uid: String) -> Bool { resolve(uid) != nil }

    /// 设备当前标称采样率：切换前后各读一次，用来证明「没改硬件采样率」
    static func nominalRate(uid: String) -> Double {
        guard let d = resolve(uid) else { return 0 }
        return float64Property(kAudioDevicePropertyNominalSampleRate, on: d.id)
    }

    // MARK: - AUHAL 上的当前输出设备

    /// 读本 AUHAL 正往哪台设备出声（返回 nil = 拿不到，例如这不是个 AUHAL 输出单元）
    static func currentDeviceID(in unit: AudioUnit) -> AudioDeviceID? {
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var id = AudioDeviceID(0)
        let st = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0, &id, &size)
        guard st == noErr, id != 0 else { return nil }
        return id
    }

    /// 把本进程的输出接到指定设备上。返回 noErr 才算切成功
    static func setCurrentDevice(_ id: AudioDeviceID, in unit: AudioUnit) -> OSStatus {
        var device = id
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                    kAudioUnitScope_Global, 0, &device,
                                    UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    /// 当前实际出声设备的 UID（自检与界面都靠它回答「现在真在往哪台设备出声」）
    static func currentUID(in unit: AudioUnit) -> String? {
        guard let id = currentDeviceID(in: unit) else { return nil }
        let uid = stringProperty(kAudioDevicePropertyDeviceUID, on: id)
        return uid.isEmpty ? nil : uid
    }

    // MARK: - 变更监听

    private static var listener: AudioObjectPropertyListenerBlock?
    private static let listenerQueue = DispatchQueue(label: "ttplayer.outputdevices")

    /// 挂上全局监听（进程范围内一次就够）。回调在专用队列上，接的人要自己转主线程
    static func startWatching(_ handler: @escaping (Change) -> Void) {
        guard listener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { count, addresses in
            // 两个属性各自注册一个监听，正常一次只报一条；按个数走一遍最稳
            for i in 0..<Int(count) {
                switch addresses[i].mSelector {
                case kAudioHardwarePropertyDevices: handler(.devicesChanged)
                case kAudioHardwarePropertyDefaultOutputDevice: handler(.defaultChanged)
                default: break
                }
            }
        }
        listener = block
        var devicesAddr = address(kAudioHardwarePropertyDevices)
        var defaultAddr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let sys = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectAddPropertyListenerBlock(sys, &devicesAddr, listenerQueue, block)
        AudioObjectAddPropertyListenerBlock(sys, &defaultAddr, listenerQueue, block)
    }

    static func stopWatching() {
        guard let block = listener else { return }
        listener = nil
        var devicesAddr = address(kAudioHardwarePropertyDevices)
        var defaultAddr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let sys = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectRemovePropertyListenerBlock(sys, &devicesAddr, listenerQueue, block)
        AudioObjectRemovePropertyListenerBlock(sys, &defaultAddr, listenerQueue, block)
    }

    // MARK: - 显示用的小工具

    /// 「44.1k/48k/96k」这类一行设备说明（拿不到清单就返回空串，不写「未知」占位）
    static func ratesSummary(_ device: Device) -> String {
        guard !device.rates.isEmpty else { return "" }
        return device.rates.map { rate in
            rate >= 1_000 ? String(format: "%gk", rate / 1_000) : String(Int(rate))
        }.joined(separator: "/")
    }
}
