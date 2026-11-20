// 生成 DSD 样本（.dsf / .dff），用于验证自带解码器。
//
// 做法：对 440Hz 正弦做二阶 sigma-delta 调制，得到 1bit/2.8224MHz 的 DSD 流；
// 解码端做块平均应该还原出同一条正弦。两个文件的信号完全一样，只有容器与位序不同：
//   DSF：每声道一整块（4096 字节）后再换声道，位序 LSB 在前
//   DFF：按字节逐声道交错，位序 MSB 在前
import Foundation

let dsdRate = 2_822_400.0
let channels = 2
let blockSize = 4096
let freq = 440.0

func arg(_ i: Int, _ fallback: Double) -> Double {
    CommandLine.arguments.count > i ? (Double(CommandLine.arguments[i]) ?? fallback) : fallback
}

let seconds = arg(2, 6.0)

/// 二阶 sigma-delta：把连续信号变成 ±1 的 1bit 流
func modulate(_ x: Double, _ state: inout (e1: Double, e2: Double, y: Double)) -> Bool {
    state.e1 += x - state.y
    state.e2 += state.e1 - state.y
    let y = state.e2 >= 0 ? 1.0 : -1.0
    state.y = y
    return y > 0
}

/// 每个声道一位一位地生成（包络淡入淡出，避免首尾爆音）
func makeBits(reference freq: Double) -> [[UInt8]] {
    var perChannel = [[UInt8]](repeating: [], count: channels)
    var states = [(e1: 0.0, e2: 0.0, y: 0.0), (e1: 0.0, e2: 0.0, y: 0.0)]
    let totalBits = Int(dsdRate * seconds)
    for i in 0..<totalBits {
        let bytesPerBit = i / 8
        if bytesPerBit >= perChannel[0].count {
            for c in 0..<channels { perChannel[c].append(0) }
        }
        let t = Double(i) / dsdRate
        let env = min(1.0, t * 2.0) * min(1.0, (seconds - t) * 2.0)
        for c in 0..<channels {
            let f = c == 0 ? freq : freq * 1.01
            let x = 0.5 * env * sin(2 * Double.pi * f * t)
            if modulate(x, &states[c]) {
                perChannel[c][bytesPerBit] |= UInt8(1 << (i % 8))
            }
        }
    }
    return perChannel
}

let bits = makeBits(reference: freq)
let bitsPerChannel = Int64(dsdRate * seconds)
let bytesPerChannel = bits[0].count

func u32le(_ v: UInt32) -> Data { var x = v.littleEndian; return withUnsafeBytes(of: &x) { Data($0) } }
func u64le(_ v: UInt64) -> Data { var x = v.littleEndian; return withUnsafeBytes(of: &x) { Data($0) } }
func u32be(_ v: UInt32) -> Data { var x = v.bigEndian; return withUnsafeBytes(of: &x) { Data($0) } }
func u64be(_ v: UInt64) -> Data { var x = v.bigEndian; return withUnsafeBytes(of: &x) { Data($0) } }
func ascii(_ s: String) -> Data { Data(s.utf8) }

// MARK: - DSF

func writeDSF(path: String) {
    // 数据区：每个 4096 字节块按声道依次排列
    var data = Data()
    var offset = 0
    while offset < bytesPerChannel {
        let n = min(blockSize, bytesPerChannel - offset)
        for c in 0..<channels {
            var block = bits[c][offset..<(offset + n)]
            if n < blockSize { block.append(contentsOf: [UInt8](repeating: 0, count: blockSize - n)) }
            data.append(contentsOf: block)
        }
        offset += n
    }

    // fmt 体 40 字节（+12 头 = 52）：版本/格式/声道类型/声道数/采样率/位深/位数/块大小/保留
    var fmtBody = Data()
    fmtBody.append(u32le(1))
    fmtBody.append(u32le(0))
    fmtBody.append(u32le(2))
    fmtBody.append(u32le(UInt32(channels)))
    fmtBody.append(u32le(UInt32(dsdRate)))
    fmtBody.append(u32le(1))
    fmtBody.append(u64le(UInt64(bitsPerChannel)))
    fmtBody.append(u32le(UInt32(blockSize)))
    fmtBody.append(u32le(0))
    let dataChunk = ascii("data") + u64le(UInt64(12 + data.count)) + data
    let fmtChunk = ascii("fmt ") + u64le(UInt64(12 + fmtBody.count)) + fmtBody
    let total = 28 + fmtChunk.count + dataChunk.count

    var out = Data()
    out.append(ascii("DSD "))
    out.append(u64le(28))
    out.append(u64le(UInt64(total)))
    out.append(u64le(0))                               // 无元数据
    out.append(fmtChunk)
    out.append(dataChunk)
    try! out.write(to: URL(fileURLWithPath: path))
    print("written \(path) \(out.count) bytes")
}

// MARK: - DFF

func writeDFF(path: String) {
    // 逐声道取 DSD 原始字节，再按字节交错；同时把 LSB-first 翻成 MSB-first
    func flipped(_ c: Int) -> [UInt8] {
        bits[c].map { b -> UInt8 in
            var v: UInt8 = 0
            for i in 0..<8 where (b >> UInt8(i)) & 1 == 1 { v |= UInt8(1 << (7 - i)) }
            return v
        }
    }
    let chBytes = (0..<channels).map(flipped)
    var data = Data(capacity: chBytes[0].count * channels)
    for i in 0..<chBytes[0].count {
        for c in 0..<channels { data.append(chBytes[c][i]) }
    }

    let fver = ascii("FVER") + u64be(4) + u32be(0x0105_0000)
    let fs = ascii("FS  ") + u64be(4) + u32be(UInt32(dsdRate))
    let chnlBody = UInt16(channels).bigEndian
    var chnl = ascii("CHNL") + u64be(UInt64(12 + 2 + channels * 4)) + withUnsafeBytes(of: chnlBody) { Data($0) }
    for name in ["SLFT", "SRGT"] { chnl.append(ascii(name)) }
    let propBody = ascii("SND ") + fs + chnl
    let prop = ascii("PROP") + u64be(UInt64(propBody.count)) + propBody
    let dsdata = ascii("DSD ") + u64be(UInt64(data.count)) + data
    let body = ascii("DSD ") + fver + prop + dsdata

    var out = ascii("FRM8") + u64be(UInt64(body.count)) + body
    if out.count % 2 == 1 { out.append(0) }
    try! out.write(to: URL(fileURLWithPath: path))
    print("written \(path) \(out.count) bytes")
}

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
writeDSF(path: dir + "/demo_dsd.dsf")
writeDFF(path: dir + "/demo_dsd.dff")
