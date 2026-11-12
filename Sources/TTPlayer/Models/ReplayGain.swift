import Foundation

/// ReplayGain 的启用范围（requirements F02）。默认关闭：响度均衡会把母带之间的相对
/// 响度抹平，这是「改用户听到的内容」的开关，不能像无缝那样默认打开。
enum ReplayGainMode: Int, CaseIterable {
    case off = 0
    case track
    case album

    /// 菜单里那一行的名字（`Int` 直接进 state.json，所以 rawValue 不能改编号）
    var displayName: String {
        switch self {
        case .off: return "响度均衡：关闭"
        case .track: return "响度均衡：按曲目"
        case .album: return "响度均衡：按专辑"
        }
    }

    var toolTip: String {
        switch self {
        case .off: return "不改音量，只听原曲自己的响度"
        case .track: return "按每首自己的 ReplayGain 标签对齐响度；没有标签就不动"
        case .album: return "整张专辑按同一个专辑增益，保留专辑内部的动态；专辑标签缺失退回曲目"
        }
    }
}

/// 一首曲子里读到的 ReplayGain 标签。缺失、写法非法、非有限值一律当没读到（nil），
/// 绝不当成 0 —— 0 dB 是「有标签且不用动」，nil 是「没有标签」，回退路径不一样
struct ReplayGainTags {
    var trackGain: Double?      // dB
    var albumGain: Double?      // dB
    var trackPeak: Double?      // 满量程线性值
    var albumPeak: Double?      // 满量程线性值

    var isEmpty: Bool { trackGain == nil && albumGain == nil && trackPeak == nil && albumPeak == nil }

    /// 标签在容器里的键各家写法不一（vorbis comment 保留大小写、mp3 的 TXXX 常见全大写），
    /// 所以先把键统一成小写再找
    init(tags: [String: String]) {
        var lowered: [String: String] = [:]
        for (k, v) in tags { lowered[k.lowercased()] = v }
        trackGain = Self.decibel(lowered["replaygain_track_gain"])
        albumGain = Self.decibel(lowered["replaygain_album_gain"])
        trackPeak = Self.peak(lowered["replaygain_track_peak"])
        albumPeak = Self.peak(lowered["replaygain_album_peak"])
    }

    /// 增益：`-6.02 dB` / `+5.300dB` / `-0,5 dB`（逗号小数点是部分标签器的写法）都要能读，
    /// 读不出、非有限、超过 ±30 dB 的都算非法（±30 已远超任何合理响度差，
    /// 再大的数只能是标签写坏了，拿它调音量就是把曲子推爆）
    private static func decibel(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let text = raw.lowercased()
            .replacingOccurrences(of: "db", with: "")
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "+", with: "")
        guard let v = Double(text), v.isFinite, abs(v) <= 30 else { return nil }
        return v
    }

    /// 峰值：正常是线性满量程（0..1，偶尔 >1）。少数标签器写成 dB，那就换算回来。
    /// 0、负数、非有限、线性值大到离谱（>10）都算非法
    private static func peak(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let text = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("db") {
            guard let v = decibel(String(text.dropLast(2))) else { return nil }
            let linear = pow(10, v / 20)
            return linear.isFinite && linear > 0 && linear <= 10 ? linear : nil
        }
        guard let v = Double(text.replacingOccurrences(of: ",", with: ".")),
              v.isFinite, v > 0, v <= 10 else { return nil }
        return v
    }
}

/// 一首曲目在当前设置下的增益决定。把「用了哪份标签、回退到哪、有没有被峰值压下来」
/// 一起带出来，属性和设置界面才能回答用户「现在到底加了多少、为什么是这个数」
struct ReplayGainDecision {
    /// 增益的来源与回退结果（同时是给用户看的一句话）
    enum Source: String {
        case off = "已关闭"
        case track = "按曲目"
        case album = "按专辑"
        case albumToTrack = "按专辑（专辑标签缺失，退回曲目）"
        case noTag = "曲子里没有 ReplayGain 标签（不动音量）"
        case radio = "电台不做响度均衡（也不加前置增益）"
    }

    var source: Source
    /// 标签本身的 dB（回退后实际采用的那份；没标签为 0）
    var tagdB: Double
    /// 标签 + 前置增益合成后的 dB
    var totaldB: Double
    /// 真正施加的线性增益（峰值防削波可能已经把它压小）
    var linear: Float
    /// 峰值防削波是否真的动了手
    var limited: Bool
    /// 参与限幅的那份 Peak
    var peak: Double?

    /// 电台：既不应用标签增益，也不应用 preamp（流里没有可信标签，音量该由台方决定）。
    /// 关闭状态连 preamp 也不加：那是「响度均衡」这条链路上的前置增益，
    /// 均衡都关了还把声音推 +12 dB，用户找不到是哪儿改的
    static func decide(tags: ReplayGainTags?, mode: ReplayGainMode, preamp: Double,
                       peakLimit: Bool, isRadio: Bool) -> ReplayGainDecision {
        if isRadio {
            return ReplayGainDecision(source: .radio, tagdB: 0, totaldB: 0,
                                      linear: 1, limited: false, peak: nil)
        }
        let t = tags ?? ReplayGainTags(tags: [:])
        let gain: Double?
        let peak: Double?
        let source: Source
        switch mode {
        case .off:
            return ReplayGainDecision(source: .off, tagdB: 0, totaldB: 0,
                                      linear: 1, limited: false, peak: nil)
        case .track:
            gain = t.trackGain
            peak = t.trackPeak ?? t.albumPeak
            source = t.trackGain == nil ? .noTag : .track
        case .album:
            if t.albumGain != nil {
                gain = t.albumGain
                peak = t.albumPeak ?? t.trackPeak
                source = .album
            } else {
                gain = t.trackGain
                peak = t.trackPeak ?? t.albumPeak
                source = t.trackGain == nil ? .noTag : .albumToTrack
            }
        }
        let tag = gain ?? 0
        let total = tag + preamp
        var linear = Float(pow(10.0, total / 20.0))
        var limited = false
        if peakLimit, let peak, linear > 1 / Float(peak) {
            linear = 1 / Float(peak)
            limited = true
        }
        return ReplayGainDecision(source: source, tagdB: tag, totaldB: total,
                                  linear: linear, limited: limited, peak: peak)
    }

    /// 给用户看的一行字：数值、来源、限幅结果都要在同一句里说清
    var summaryText: String {
        var s = "\(source.rawValue)"
        if source != .off, source != .radio, source != .noTag {
            s += String(format: " %+.1f dB", totaldB)
        }
        if limited {
            s += String(format: "（峰值 %.3f 已把增益压到 %.1f dB）",
                        peak ?? 0, 20 * log10(Double(max(linear, 1e-9))))
        }
        return s
    }
}
