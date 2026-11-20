// 生成「内嵌封面 + 标签」的测试素材，供自检验证显示区能不能贴出封面图。
//
//   swift scripts/gen_cover.swift <测试目录> [<源 wav>]
//
// 产出：
//   cover.m4a —— iTunes 风格 ilst（covr + ©nam/©ART/©alb）。这类条目的
//                AVMetadataItem.key 是 nil，只有 identifier("itsk/©nam")，
//                是最容易读不到封面/标签的一条路。
//   cover.flac —— FLAC PICTURE 块（AVFoundation 以 METADATA_BLOCK_PICTURE 暴露）。
//   art/single.wav + art/single.png —— 没有内嵌图、但目录里一张超大（1200×1200）
//                同名封面的路子：验证同名优先，也验证降采样真的把 1200 压到了上限内。
//   art/coverless.wav + art/cover.jpg —— 靠目录通用名 cover.jpg 回落到封面的路子。
//
// 不用第三方工具：m4a 由 AVAssetExportSession 转出，封面与 ilst/PICTURE 块手工写入。
import Foundation
import AVFoundation
import AppKit

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "testlib"
let srcWav: String = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : (dir as NSString).appendingPathComponent("demo01.wav")
let srcURL = URL(fileURLWithPath: srcWav)
guard FileManager.default.fileExists(atPath: srcURL.path) else {
    FileHandle.standardError.write("找不到源 wav：\(srcURL.path)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - 画一张封面（300x300 JPEG，够大到不会被“>100 字节”的噪声阈值挡掉）

func coverJPEG() -> Data {
    let size = NSSize(width: 300, height: 300)
    let image = NSImage(size: size, flipped: false) { rect in
        NSColor(calibratedRed: 0.22, green: 0.45, blue: 0.82, alpha: 1).setFill()
        rect.fill()
        NSColor.white.setFill()
        let text = "TT COVER" as NSString
        text.draw(in: rect.insetBy(dx: 24, dy: 128), withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: 34),
        ])
        return true
    }
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75])!
}

/// 外部封面素材用的大图：1200×1200 PNG。挑纯色 + 大字，压完也就几十 KB，
/// 但解出来的位图足够大，正好用来验证「界面上不留整张原图」这条底线
func bigPNG(side: Int) -> Data {
    let size = NSSize(width: side, height: side)
    let image = NSImage(size: size, flipped: false) { rect in
        NSColor(calibratedRed: 0.18, green: 0.62, blue: 0.35, alpha: 1).setFill()
        rect.fill()
        NSColor.white.setFill()
        let text = "TT SINGLE \(side)" as NSString
        text.draw(in: rect.insetBy(dx: 40, dy: CGFloat(side / 2 - 40)), withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: CGFloat(side) / 16),
        ])
        return true
    }
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let jpeg = coverJPEG()

// MARK: - MP4 原子小工具

func be32(_ v: UInt32) -> Data {
    var x = v.bigEndian
    return withUnsafeBytes(of: &x) { Data($0) }
}
func atom(_ type: String, _ payload: Data) -> Data {
    be32(UInt32(8 + payload.count)) + Data(type.utf8) + payload
}
/// 四字符码：iTunes 标签名里的 © 是 macRoman 单字节 0xA9，不是 UTF-8 的两字节
func cc(_ s: String) -> Data {
    var d = Data()
    for scalar in s.unicodeScalars {
        d.append(scalar.value == 0xA9 ? 0xA9 : UInt8(scalar.value & 0x7f))
    }
    return d
}
func atom(_ type: Data, _ payload: Data) -> Data {
    be32(UInt32(8 + payload.count)) + type + payload
}
/// 按大端读 4/8 字节（不拿 Data 切片的指针直接 load，那样容易不对齐而崩）
func readU32(_ d: Data, _ i: Int) -> UInt32 {
    var v: UInt32 = 0
    for k in 0..<4 { v = (v << 8) | UInt32(d[d.startIndex + i + k]) }
    return v
}
func readU64(_ d: Data, _ i: Int) -> UInt64 {
    var v: UInt64 = 0
    for k in 0..<8 { v = (v << 8) | UInt64(d[d.startIndex + i + k]) }
    return v
}
/// 读出一层原子：size==1 走 64 位 largesize，size==0 表示到文件尾
func atoms(_ data: Data, _ base: Int, _ end: Int) -> [(type: String, start: Int, size: Int, head: Int)] {
    var out: [(String, Int, Int, Int)] = []
    var i = base
    while i + 8 <= end {
        let size32 = readU32(data, i)
        let type = String(data: data.subdata(in: (data.startIndex + i + 4)..<(data.startIndex + i + 8)),
                          encoding: .isoLatin1) ?? "?"
        var size = Int(size32)
        var head = 8
        if size32 == 1 {
            guard i + 16 <= end else { break }
            size = Int(readU64(data, i + 8))
            head = 16
        } else if size32 == 0 {
            size = end - i
        }
        if size < 8 { break }
        out.append((type, i, size, head))
        i += size
    }
    return out
}
/// iTunes 风格条目：name/data 里 version+flags 的低 24 位是类型（1=UTF-8 文本，13=JPEG）
func itunesItem(_ name: Data, flags: UInt32, payload: Data) -> Data {
    atom(name, atom(Data("data".utf8), be32(flags) + be32(0) + payload))
}

func textPayload(_ s: String) -> Data { Data(s.utf8) }

func writeCoveredM4A(to path: String) {
    guard let session = AVAssetExportSession(asset: AVURLAsset(url: srcURL),
                                             presetName: AVAssetExportPresetAppleM4A) else {
        FileHandle.standardError.write("无法创建导出会话\n".data(using: .utf8)!)
        return
    }
    let outURL = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: outURL)
    session.outputURL = outURL
    session.outputFileType = .m4a
    let sem = DispatchSemaphore(value: 0)
    session.exportAsynchronously { sem.signal() }
    sem.wait()

    // 转出文件里自带的 meta 是 Apple「mdta」风格（放不下 iTunes covr），整块换掉
    var items = Data()
    items += itunesItem(cc("covr"), flags: 0x0D, payload: jpeg)
    items += itunesItem(cc("\u{00A9}nam"), flags: 1, payload: textPayload("封面测试曲"))
    items += itunesItem(cc("\u{00A9}ART"), flags: 1, payload: textPayload("测试歌手"))
    items += itunesItem(cc("\u{00A9}alb"), flags: 1, payload: textPayload("测试专辑"))
    items += itunesItem(cc("aART"), flags: 1, payload: textPayload("测试专辑歌手"))
    let hdlr = atom("hdlr", be32(0) + be32(0) + Data("mdir".utf8) + Data([UInt8](repeating: 0, count: 12))
                    + Data("Apple iTunes Media Handler".utf8) + Data([0]))
    let ilst = atom("ilst", items)
    let meta = be32(UInt32(8 + 4 + hdlr.count + ilst.count)) + Data("meta".utf8) + be32(0) + hdlr + ilst

    var data = try! Data(contentsOf: outURL)
    guard let moov = atoms(data, 0, data.count).first(where: { $0.type == "moov" }) else {
        FileHandle.standardError.write("转出文件里没有 moov，跳过封面写入\n".data(using: .utf8)!)
        return
    }
    var content = data.subdata(in: (moov.start + moov.head)..<(moov.start + moov.size))
    if let old = atoms(content, 0, content.count).first(where: { $0.type == "udta" }) {
        let body = content.subdata(in: (old.start + old.head)..<(old.start + old.size))
        var keep = Data()
        for a in atoms(body, 0, body.count) where a.type != "meta" {
            keep += body.subdata(in: a.start..<(a.start + a.size))
        }
        keep += meta
        let newUdta = be32(UInt32(8 + keep.count)) + Data("udta".utf8) + keep
        content = content.subdata(in: 0..<old.start) + newUdta
            + content.subdata(in: (old.start + old.size)..<content.count)
    } else {
        content += atom("udta", meta)
    }
    let newMoov = be32(UInt32(moov.head + (content.count))) + Data("moov".utf8) + content
    data = data.subdata(in: 0..<moov.start) + newMoov + data.subdata(in: (moov.start + moov.size)..<data.count)
    try! data.write(to: outURL)
    print("written \(path) \(data.count) bytes（封面 \(jpeg.count) 字节）")
}

// MARK: - FLAC：在元数据块链里插一个 PICTURE 块

func writeCoveredFLAC(to path: String) {
    let tmp = path + ".raw"
    let conv = Process()
    conv.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
    conv.arguments = ["-f", "flac", "-d", "flac", srcURL.path, tmp]
    conv.standardError = FileHandle.standardError
    try? conv.run()
    conv.waitUntilExit()
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    guard conv.terminationStatus == 0, var flac = try? Data(contentsOf: URL(fileURLWithPath: tmp)) else {
        print("跳过 FLAC 素材：afconvert 转出失败")
        return
    }
    guard String(data: flac.subdata(in: flac.startIndex..<flac.startIndex + 4), encoding: .ascii) == "fLaC" else {
        print("跳过 FLAC 素材：不是 FLAC 文件")
        return
    }
    // 元数据块：1 字节（最高位=最后一块，低 7 位=类型）+ 3 字节长度 + 内容
    var i = 4
    var lastHeader = -1
    var lastBlockEnd = -1
    while i + 4 <= flac.count {
        let flag = flac[i]
        let len = Int(flac[i + 1]) << 16 | Int(flac[i + 2]) << 8 | Int(flac[i + 3])
        lastHeader = i
        lastBlockEnd = i + 4 + len
        i = lastBlockEnd
        if flag & 0x80 != 0 { break }
    }
    guard lastHeader >= 0 else { return }
    // PICTURE 块（类型 6）体：picture type(4) + mime 长度+内容 + 描述长度
    //                       + 宽/高/位深/色数(各 4) + 图像长度+图像
    let mime = "image/jpeg"
    var body = Data()
    body += be32(3)                                            // 3 = 前面封面
    body += be32(UInt32(mime.count)) + Data(mime.utf8)
    body += be32(0)                                            // 无描述
    body += be32(300) + be32(300) + be32(24) + be32(0)          // 宽/高/位深/调色板色数
    body += be32(UInt32(jpeg.count)) + jpeg
    // 原最后一块的 last 标志改给新插的 PICTURE（它排在链尾）
    var mutated = flac
    mutated[lastHeader] &= 0x7f
    let header = Data([UInt8(0x80 | 0x06),                      // last + type 6
                       UInt8(body.count >> 16), UInt8(body.count >> 8 & 0xff),
                       UInt8(body.count & 0xff)])
    let inserted = mutated.subdata(in: 0..<lastBlockEnd) + header + body
        + mutated.subdata(in: lastBlockEnd..<mutated.count)
    try? inserted.write(to: URL(fileURLWithPath: path))
    print("written \(path) \(inserted.count) bytes")
}

writeCoveredM4A(to: dir + "/cover.m4a")
writeCoveredFLAC(to: dir + "/cover.flac")

// MARK: - 外部封面文件（没有内嵌图的那一路）

func writeExternalCoverArt() {
    let fm = FileManager.default
    let art = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("art", isDirectory: true)
    try? fm.createDirectory(at: art, withIntermediateDirectories: true)
    // 音频本身不带图：直接拷一份 demo wav，WAV 没有可用的内嵌图位，正好当“无内嵌”样本
    let tracks = ["single.wav", "coverless.wav"]
    for name in tracks {
        let to = art.appendingPathComponent(name)
        try? fm.removeItem(at: to)
        try? fm.copyItem(at: srcURL, to: to)
    }
    let big = bigPNG(side: 1200)
    try? big.write(to: art.appendingPathComponent("single.png"))
    try? jpeg.write(to: art.appendingPathComponent("cover.jpg"))
    print("written \(art.path)/ （single.png \(big.count)B、cover.jpg \(jpeg.count)B）")
}

writeExternalCoverArt()

// 读回来确认 AVFoundation 真能认出这些标签（自检之外的一层保险）
for name in ["cover.m4a", "cover.flac"] {
    let url = URL(fileURLWithPath: dir + "/" + name)
    guard FileManager.default.fileExists(atPath: url.path) else { continue }
    let asset = AVURLAsset(url: url)
    let dumped = asset.metadata.map { item -> String in
        let id = item.identifier?.rawValue as String? ?? "nil"
        let key = (item.key as? String) ?? "nil"
        let bytes = item.dataValue?.count ?? 0
        return "\(id)|key=\(key)|\(bytes)B"
    }
    print("  \(name): \(dumped.joined(separator: "  "))")
}
