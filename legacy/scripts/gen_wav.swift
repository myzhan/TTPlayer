// 生成 44.1kHz 16bit 立体声正弦 WAV，用于自测
import Foundation

func writeWav(path: String, seconds: Double, freq: Double) {
    let sr = 44100.0
    let n = Int(sr * seconds)
    var data = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
    let dataSize = UInt32(n * 2 * 2)
    data.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2)
    u32(UInt32(sr)); u32(UInt32(sr * 4)); u16(4); u16(16)
    data.append(contentsOf: Array("data".utf8)); u32(dataSize)
    for i in 0..<n {
        let t = Double(i) / sr
        // 双音：左右略失谐拍音，带包络
        let env = min(1.0, t * 2.0) * min(1.0, (seconds - t) * 2.0)
        let l = Int16(12000.0 * env * sin(2 * Double.pi * freq * t))
        let r = Int16(10000.0 * env * sin(2 * Double.pi * freq * 1.01 * t))
        u16(UInt16(bitPattern: l)); u16(UInt16(bitPattern: r))
    }
    try! data.write(to: URL(fileURLWithPath: path))
    print("written \(path) \(data.count) bytes")
}

let dir = CommandLine.arguments[1]
// 可选第二参数：额外造一条长样本 bench_long.wav，给播放态 CPU 测量用
// （measure_cpu.sh 要 6 s 预热 + 10 s 采样，demo01/02 的 10~12 s 不够长）
if CommandLine.arguments.count > 2, let long = Double(CommandLine.arguments[2]) {
    writeWav(path: dir + "/bench_long.wav", seconds: long, freq: 220)
}
writeWav(path: dir + "/demo01.wav", seconds: 12, freq: 440)
writeWav(path: dir + "/demo02.wav", seconds: 10, freq: 523.25)
