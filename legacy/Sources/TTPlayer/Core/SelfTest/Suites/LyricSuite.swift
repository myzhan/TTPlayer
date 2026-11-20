import Foundation

/// 歌词：纯解析与查找（不碰音频设备，冒烟档也跑它）
struct LyricSuite: SelfTestSuite {
    func run(_ ctx: SelfTestContext) {
        let parsed = Lyric.parse("[00:01.20]aa\n[00:02.00][00:05.00]bb\n[00:10]cc\n[alx]junk")
        ctx.check("歌词解析-行数", parsed.lines.count == 4, "got \(parsed.lines.count)")
        ctx.check("歌词解析-时间", abs((parsed.lines.first?.time ?? 0) - 1.2) < 0.001,
                  "first=\(parsed.lines.first?.time ?? -1)")
        ctx.check("歌词解析-多标签", parsed.lines[1].time == 2.0 && parsed.lines[2].time == 5.0)
        ctx.check("歌词查找", parsed.lineIndex(at: 3.0) == 1, "idx=\(parsed.lineIndex(at: 3.0))")
        ctx.check("歌词查找-首行前", parsed.lineIndex(at: 0.5) == -1)
    }
}
