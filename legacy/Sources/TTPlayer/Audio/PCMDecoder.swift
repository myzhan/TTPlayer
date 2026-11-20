import Foundation
import AVFoundation

/// 自带解码器的统一出口：所有音频一律交给 FFmpeg 解码，产出 Float32 非交织立体声 PCM，
/// 由 AudioEngine 的 playerNode 直接消费。
///
/// 三条硬约束（写实现时不许破）：
/// 1. **不许整曲进内存**：只暴露「从第 N 帧读 M 帧」，按需读盘；
/// 2. **不许在音频线程做重活**：实现里只做算术与定长读盘，不分配大对象、不打日志；
/// 3. **必须能随机定位**：进度条拖动、CUE 分轨跳转都依赖它。
protocol PCMAudioDecoder: AnyObject {
    /// 静态声明自己认哪些扩展名（进白名单用，与系统查询结果取并集）
    static var fileExtensions: Set<String> { get }
    /// 按文件头判断认不认（扩展名可以改，内容不会骗人）
    static func sniff(_ url: URL) -> Bool

    init(url: URL) throws

    /// 解码后的 PCM 参数（不是 DSD 的 2.8224 MHz，而是降采样后的采样率）
    var sampleRate: Double { get }
    var channelCount: Int { get }
    /// 整份文件能出多少帧 PCM
    var totalFrames: Int64 { get }
    /// 显示用的格式名，如「DSD64 2.8224MHz」
    var formatName: String { get }

    /// 从 frame 起读 frames 帧进 buffer（buffer 的格式必须与 sampleRate/channelCount 一致）；
    /// 文件尾返回实际读到的帧数，0 表示读完了
    func read(into buffer: AVAudioPCMBuffer, frames: AVAudioFrameCount, from frame: Int64) -> AVAudioFrameCount
}

enum PCMDecoders {
    /// 自带解码器认的扩展名：白名单要把它并进系统查询结果
    static var extensions: Set<String> {
        var all = Set<String>()
        for type in allTypes { all.formUnion(type.fileExtensions) }
        return all
    }

    /// 解码清单：所有音频解码都由 FFmpegDecoder 承担（取代过去的 DSD/TTA/APE 自制解码器）
    private static var allTypes: [PCMAudioDecoder.Type] { [FFmpegDecoder.self] }

    /// 取一个能打开这个文件的解码器（先按内容嗅探，不靠扩展名）
    static func decoder(for url: URL) -> PCMAudioDecoder? {
        for type in allTypes where type.sniff(url) {
            if let d = try? type.init(url: url) { return d }
        }
        return nil
    }

    /// 这个扩展名是否由自带解码器负责（错误文案要据此分开说）
    static func owns(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}
