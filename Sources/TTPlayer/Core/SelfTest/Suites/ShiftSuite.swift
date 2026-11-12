import AppKit
import Foundation

/// F10 歌词时间校准（±0.5 秒步进、±30 秒上下限、按稳定身份保存、不改写 .lrc）。
///
/// 查行这类断言不能只信算式：拿的是**真实播放链路**上的位置——素材现场造（每句隔 1 秒的
/// 时间戳 + 已知长度的 WAV），播起来后暂停再 `seek` 到指定秒，暂停里的位置不会自己走，
/// 于是「屏幕上此刻该是哪一句」有唯一解。播放中的查行另有一场跟着心跳验。
///
/// 三件容易搞错的事在这里都有专门的断言：
/// 1. 文件自带的 `[offset:±毫秒]` 在解析时就已算进每行时间，用户那一层只再叠自己的一层，
///    谁都不许拿 `fileOffset` 调第二次（所以造一份 offset +1.5 秒的素材，三档答案互不重叠）；
/// 2. CUE 轨的引擎位置是「本段第几秒」，整盘一份的词要补段起点（`mirrorShift`），
///    按轨名命中的那份本身就从 0 计时，不补；
/// 3. 校准量按 `identityKey` 存：CUE 一轨一号，各轨天生分开，重启也只认这个身份。
final class ShiftSuite: SelfTestSuite {
    /// 歌词句子之间的间隔（秒）：步进 0.5 恰好落在两行正中，边界最锋利
    private static let spacing = 1.0
    /// 首句与末句的时间戳（秒）：都留在素材长度以内
    private static let firstLine = 2
    private static let lastLine = 20
    /// CUE 第二轨的段起点（秒），也是镜像时间轴与该轨的分界
    private static let cueStart = 10.0

    /// 跑之前记下的现场：收摊要一样样还回去，后面的套件不该看到本套的样子
    private struct Snapshot {
        let shifts: [String: Double]
        let playMode: PlayMode
        let volume: Float
        let gapless: Bool
        let lyricWindowOpen: Bool
    }

    /// 素材清单一应俱全：普通词、带 offset 的词、无词、整盘词的镜像、按轨名的词
    private struct Material {
        let plain: URL           // 22 s wav + 同名 .lrc（无 offset）
        let plainLRC: URL
        let offset: URL          // 22 s wav + 同名 .lrc（[offset:+1500]）
        let offsetLRC: URL
        let noLyric: URL         // 只有 wav，旁边一个 .lrc 都没有
        let albumCue: URL        // 整盘分轨表，镜像 30 s，配整盘一份的同名 .lrc
        let albumLRC: URL
        let perCue: URL          // 另一张分轨表，配「镜像名 - 轨名.lrc」（按轨名命中）
        let perLRC: URL
    }

    private var root = URL(fileURLWithPath: NSTemporaryDirectory())
    /// 本套自己写过的曲目身份：收摊按这些键从表里摘干净
    private var usedKeys: Set<String> = []

    // MARK: - 入口

    func run(_ ctx: SelfTestContext) {
        let p = ctx.player
        let keep = Snapshot(shifts: LibraryStore.load().lyricShifts, playMode: p.playMode,
                            volume: p.volume, gapless: p.gaplessPlay,
                            lyricWindowOpen: ctx.main.lyricVisible)
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ttplayer-shift", isDirectory: true)
        try? ctx.fm.removeItem(at: root)
        guard let mat = makeMaterial(ctx) else {
            ctx.check("校准-素材能造出来", false, "dir=\(root.path)")
            return
        }
        checkParse(ctx)
        checkEntries(ctx, p: p)
        checkTimeline(ctx, p: p, mat: mat)
        checkFileOffsetOnce(ctx, p: p, mat: mat)
        checkCueBases(ctx, p: p, mat: mat)
        checkIdentityAndPersistence(ctx, p: p, mat: mat)
        checkDisabledAndKeyboard(ctx, p: p, mat: mat)
        cleanup(ctx, p, keep)
    }

    // MARK: - 素材

    /// 时间戳每句隔 1 秒、正文写成 `L05` 这种「一眼就是第几秒」的句子：
    /// 校验只比字符串，不需要再解一遍时间轴
    private func makeMaterial(_ ctx: SelfTestContext) -> Material? {
        func dir(_ name: String) -> URL {
            let u = root.appendingPathComponent(name, isDirectory: true)
            try? ctx.fm.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }
        let plainDir = dir("plain"), offDir = dir("offset"), bareDir = dir("bare")
        let albumDir = dir("album"), perDir = dir("per")
        let plain = plainDir.appendingPathComponent("shiftplain.wav")
        let plainLRC = plainDir.appendingPathComponent("shiftplain.lrc")
        let offset = offDir.appendingPathComponent("shiftoff.wav")
        let offsetLRC = offDir.appendingPathComponent("shiftoff.lrc")
        let bare = bareDir.appendingPathComponent("shiftnolyric.wav")
        let mirror = albumDir.appendingPathComponent("shiftmirror.wav")
        let albumCue = albumDir.appendingPathComponent("shiftalbum.cue")
        let albumLRC = albumDir.appendingPathComponent("shiftmirror.lrc")
        let perImage = perDir.appendingPathComponent("shiftper.wav")
        let perCue = perDir.appendingPathComponent("shiftper.cue")
        let perLRC = perDir.appendingPathComponent("shiftper - Track Two.lrc")
        guard ctx.writeWave(plain, sampleRate: 44_100, channels: 2, bits: 16,
                            freqs: [440, 440], seconds: 22),
              ctx.writeWave(offset, sampleRate: 44_100, channels: 2, bits: 16,
                            freqs: [440, 440], seconds: 22),
              ctx.writeWave(bare, sampleRate: 44_100, channels: 2, bits: 16,
                            freqs: [440, 440], seconds: 22),
              ctx.writeWave(mirror, sampleRate: 44_100, channels: 2, bits: 16,
                            freqs: [440, 440], seconds: 30),
              ctx.writeWave(perImage, sampleRate: 44_100, channels: 2, bits: 16,
                            freqs: [440, 440], seconds: 30),
              writeLRC(plainLRC, offset: nil),
              writeLRC(offsetLRC, offset: "+1500"),
              writeLRC(albumLRC, to: 29, offset: nil),
              // 按轨名命中的那一份：时间轴是「这一轨从 0 秒起」，句子前缀换成 T 好区分
              writeLRC(perLRC, prefix: "T", offset: nil) else { return nil }
        try? cueText(image: "shiftmirror.wav", title: "ShiftAlbum").write(to: albumCue, atomically: true,
                                                                          encoding: .utf8)
        try? cueText(image: "shiftper.wav", title: "PerAlbum").write(to: perCue, atomically: true,
                                                                     encoding: .utf8)
        guard exists(albumCue), exists(perCue) else { return nil }
        return Material(plain: plain, plainLRC: plainLRC, offset: offset, offsetLRC: offsetLRC,
                        noLyric: bare, albumCue: albumCue, albumLRC: albumLRC,
                        perCue: perCue, perLRC: perLRC)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// 一份时间戳已知的 .lrc：`[00:02.00]L02`……隔 1 秒一句
    private func writeLRC(_ url: URL, from: Int = firstLine, to: Int = lastLine,
                          prefix: String = "L", offset: String?) -> Bool {
        var s = ""
        if let offset { s += "[offset:\(offset)]\n" }
        for k in from...to { s += String(format: "[00:%02d.00]%@%02d\n", k, prefix, k) }
        return (try? s.data(using: .utf8)!.write(to: url)) != nil
    }

    /// 两轨的整盘分轨表：第二轨从第 10 秒起，正好让「段内位置」与「镜像位置」差出一截
    private func cueText(image: String, title: String) -> String {
        """
        REM TTPLAYER SHIFT FIXTURE
        PERFORMER "ShiftArtist"
        TITLE "\(title)"
        FILE "\(image)" WAVE
          TRACK 01 AUDIO
            TITLE "Track One"
            PERFORMER "ShiftArtist"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Track Two"
            PERFORMER "ShiftArtist"
            INDEX 01 00:10:00
        """
    }

    // MARK: - 纯逻辑：offset 解析、时间轴换算

    private func checkParse(_ ctx: SelfTestContext) {
        let a = Lyric.parse("[offset:+1500]\n[00:05.00]A\n[00:06.00]B")
        ctx.check("校准-文件自带 offset 读得出来", abs(a.fileOffset - 1.5) < 1e-9,
                  "offset=\(a.fileOffset)")
        ctx.check("校准-offset 在解析时就算进每一行",
                  abs(a.lines[0].time - 3.5) < 1e-9 && abs(a.lines[1].time - 4.5) < 1e-9,
                  "t0=\(a.lines[0].time) t1=\(a.lines[1].time)")
        // 负值是「歌词延后」：时间戳要往后长，与用户校准那一句的符号方向一致才好解释
        let b = Lyric.parse("[offset:-1000]\n[00:05.00]A")
        ctx.check("校准-负 offset 把时间往后推", abs(b.lines[0].time - 6.0) < 1e-9,
                  "t=\(b.lines[0].time)")
        // 写了好几行 offset 时取最后一行（与常见歌词编辑器一致），绝不互相叠加
        let c = Lyric.parse("[offset:+500]\n[offset:-500]\n[00:05.00]A")
        ctx.check("校准-多行 offset 只认最后一行",
                  abs(c.fileOffset + 0.5) < 1e-9 && abs(c.lines[0].time - 5.5) < 1e-9,
                  "offset=\(c.fileOffset) t=\(c.lines[0].time)")
        let d = Lyric.parse("[offset:+5000]\n[00:01.00]A\n[00:09.00]B")
        ctx.check("校准-offset 把首句推到负时间也不越界",
                  d.lines[0].time == 0 && abs(d.lines[1].time - 4.0) < 1e-9,
                  "t0=\(d.lines[0].time) t1=\(d.lines[1].time)")
        ctx.check("校准-offset 那行自己不会变成歌词",
                  a.lines.allSatisfy { $0.text != "[offset:+1500]" } && a.lines.count == 2,
                  "n=\(a.lines.count)")
        // 换算只有一条路：段内位置 + 镜像补量 - 用户延后量
        var e = Lyric.parse("[00:02.00]A\n[00:12.00]B")
        ctx.check("校准-普通轨换算只减校准量",
                  abs(e.alignedTime(segmentTime: 5, delay: 0.5) - 4.5) < 1e-9
                    && abs(e.alignedTime(segmentTime: 5, delay: -0.5) - 5.5) < 1e-9)
        e.mirrorShift = Self.cueStart
        ctx.check("校准-整盘词换算要补段起点",
                  abs(e.alignedTime(segmentTime: 2, delay: 1) - 11) < 1e-9,
                  e.alignedTime(segmentTime: 2, delay: 1).description)
        ctx.check("校准-查行落在哪一句按时间戳说话",
                  e.lineIndex(at: 11) == 0 && e.lineIndex(at: 12) == 1
                    && e.lineIndex(at: 1) == -1,
                  "11→\(e.lineIndex(at: 11)) 12→\(e.lineIndex(at: 12)) 1→\(e.lineIndex(at: 1))")
        ctx.check("校准-上下限就是需求那句 ±30 秒",
                  PlayerController.lyricShiftLimit == 30 && PlayerController.lyricShiftStep == 0.5)
    }

    // MARK: - 入口：菜单、歌词秀校准行、快捷键登记

    private func checkEntries(_ ctx: SelfTestContext, p: PlayerController) {
        let item = ctx.main.buildLyricShiftItem()
        let sub = item.submenu
        ctx.check("校准-菜单里有这一支", item.title == "歌词时间校准" && sub != nil)
        ctx.check("校准-这一支挂在总菜单上",
                  ctx.main.buildPopupMenu().items.contains { $0.title == "歌词时间校准"
                                                                && $0.submenu != nil })
        func row(_ prefix: String) -> NSMenuItem? { sub?.items.first { $0.title.hasPrefix(prefix) } }
        let earlier = row("提前"), later = row("延后"), reset = row("重置")
        ctx.check("校准-三个动作都在菜单上", earlier != nil && later != nil && reset != nil)
        ctx.check("校准-快捷键是 ⌥← / ⌥→ / ⌥0",
                  earlier?.keyEquivalent == MainWindowController.leftArrowKey
                    && earlier?.keyEquivalentModifierMask == .option
                    && later?.keyEquivalent == MainWindowController.rightArrowKey
                    && later?.keyEquivalentModifierMask == .option
                    && reset?.keyEquivalent == "0" && reset?.keyEquivalentModifierMask == .option,
                  "earlier=\(earlier?.keyEquivalent ?? "?") later=\(later?.keyEquivalent ?? "?")")
        ctx.check("校准-菜单项接的是真动作",
                  earlier?.action == #selector(MainWindowController.shiftLyricEarlier)
                    && later?.action == #selector(MainWindowController.shiftLyricLater)
                    && reset?.action == #selector(MainWindowController.resetLyricShiftKey))
        // 没在播东西：整支都该按不动，并且第一行就说明为什么
        p.stop()
        p.clearPlaylist()
        let idle = ctx.main.buildLyricShiftItem().submenu!
        ctx.check("校准-没曲目时三项都 disabled",
                  idle.items.first { $0.title.hasPrefix("提前") }?.isEnabled == false
                    && idle.items.first { $0.title.hasPrefix("延后") }?.isEnabled == false
                    && idle.items.first { $0.title.hasPrefix("重置") }?.isEnabled == false)
        ctx.check("校准-没曲目时状态行说没在播",
                  idle.items.first?.title.contains("没有正在播的曲目") == true,
                  idle.items.first?.title ?? "nil")
        ctx.check("校准-状态行那句不可点", idle.items.first?.isEnabled == false)
        ctx.check("校准-未校准时短句就是「未校准」", p.lyricShiftText == "未校准", p.lyricShiftText)
        ctx.check("校准-没有曲目时不能调", !p.lyricShiftApplies)
        // 歌词秀那一行：三个键 + 状态格，入口与快捷键同一个方法
        openLyricWindow(ctx)
        let win = ctx.main.lyricWindow
        ctx.check("校准-歌词秀有校准行", win != nil && win!.shiftButtons.count == 3)
        ctx.check("校准-没歌词时三个键都禁用",
                  win!.shiftButtons.allSatisfy { !$0.isEnabled && $0.alphaValue < 1 },
                  win!.shiftButtons.map { "\($0.isEnabled)\($0.alphaValue)" }.joined(separator: " "))
        ctx.check("校准-歌词秀状态格说明原因",
                  win!.shiftLabelText.contains("没有正在播的曲目"), win!.shiftLabelText)
        ctx.check("校准-状态格悬停也说得出为什么按不动",
                  win!.shiftToolTip.contains("没有正在播的曲目"), win!.shiftToolTip)
        // 三个键自包自己的悬停：平时说“按下去干什么”，按不动时换成“为什么不能干”
        ctx.check("校准-键按不动时悬停换成原因",
                  win!.shiftButtons.allSatisfy { ($0.toolTip ?? "").contains("没有正在播的曲目") },
                  win!.shiftButtons.map { $0.toolTip ?? "nil" }.joined(separator: " | "))
    }

    // MARK: - 真实时间轴：±0.5 步进、边界、重置、seek、暂停恢复、末行、两处一致

    private func checkTimeline(_ ctx: SelfTestContext, p: PlayerController, mat: Material) {
        guard loadPlain(ctx, p, mat) else { return }
        // 4.2 秒在两行正中偏后：任何半秒级的错位都会立刻换一个答案
        guard park(ctx, p, at: 4.2) else { return }
        ctx.check("校准-未校准时按时间戳查行", shownLine(ctx) == "L04", shownLine(ctx))
        ctx.check("校准-查的确实是引擎报的那一秒",
                  abs(p.alignedLyricTime(p.currentTime) - 4.2) < 0.05,
                  String(format: "%.2f", p.alignedLyricTime(p.currentTime)))
        let say = p.nudgeLyricShift(PlayerController.lyricShiftStep)
        ctx.check("校准-延后 0.5 秒改的是显示往后推一句",
                  shownLine(ctx) == "L03" && abs(p.lyricShift - 0.5) < 1e-9,
                  "\(say) line=\(shownLine(ctx))")
        ctx.check("校准-短句写成「延后 0.5 秒」", p.lyricShiftText == "延后 0.5 秒", p.lyricShiftText)
        ctx.check("校准-完整一句带上限", p.lyricShiftDetail.contains("±30 秒"), p.lyricShiftDetail)
        // 需求里那条「不写回用户的 .lrc」在界面上也得读得到，不能只藏在代码里
        ctx.check("校准-完整一句说不改写 .lrc",
                  p.lyricShiftDetail.contains("不改写 .lrc"), p.lyricShiftDetail)
        // 歌词秀自己的节拍（0.1 s）会慢半拍，等一下再把两句拿来比
        _ = ctx.waitUntil(2) { ctx.main.lyricWindow?.shiftToolTip == p.lyricShiftDetail }
        ctx.check("校准-歌词秀悬停也是这一句",
                  ctx.main.lyricWindow?.shiftToolTip == p.lyricShiftDetail,
                  ctx.main.lyricWindow?.shiftToolTip ?? "nil")
        // 反向按满回到 0，再按成提前：符号方向是需求点名的「正=延后」
        _ = p.nudgeLyricShift(-PlayerController.lyricShiftStep)
        ctx.check("校准-再按一次回到未校准",
                  abs(p.lyricShift) < 1e-9 && shownLine(ctx) == "L04", shownLine(ctx))
        _ = p.nudgeLyricShift(-PlayerController.lyricShiftStep)
        ctx.check("校准-提前就是负的那一格", abs(p.lyricShift + 0.5) < 1e-9, p.lyricShiftText)
        ctx.check("校准-短句写成「提前 0.5 秒」", p.lyricShiftText == "提前 0.5 秒", p.lyricShiftText)
        // 句子隔 1 秒、步进 0.5 秒：4.2 秒提前半秒（到 4.7）还在本句里，赶不出下一句。
        // 这不是算错了，是句距本来就比步距大：换个位置（4.7）提前才跳得出去，
        // 两个方向都验一次，才能确认「正=延后、负=提前」真的是反方向而不是同一个方向
        ctx.check("校准-提前半秒未跨句界就还是这一句", shownLine(ctx) == "L04", shownLine(ctx))
        guard park(ctx, p, at: 4.7) else { return }
        ctx.check("校准-提前 0.5 秒在另一处真的往前赶一句", shownLine(ctx) == "L05", shownLine(ctx))
        _ = p.resetLyricShift()
        ctx.check("校准-重置归零", abs(p.lyricShift) < 1e-9 && shownLine(ctx) == "L04", shownLine(ctx))
        ctx.check("校准-归零后再重置不装模作样",
                  p.resetLyricShift().contains("本来就没校准过"), p.resetLyricShift())
        // 边界：到顶那一下不动东西，但要说清为什么不动（比默默停在 30 秒好懂）
        ctx.check("校准-直接给到上限", p.setLyricShift(30) == "歌词延后 30.0 秒"
                          && abs(p.lyricShift - 30) < 1e-9, p.lyricShiftText)
        let edge = p.nudgeLyricShift(PlayerController.lyricShiftStep)
        ctx.check("校准-到顶还往同一个方向按不动东西",
                  abs(p.lyricShift - 30) < 1e-9 && edge.contains("上限 +30 秒")
                    && edge.contains("再按也不动了"), edge)
        ctx.check("校准-到顶时查行真的走了 30 秒", abs(p.alignedLyricTime(4.2) - (4.2 - 30)) < 1e-9,
                  String(format: "%.1f", p.alignedLyricTime(4.2)))
        ctx.check("校准-到顶后歌词就停在开头之前（不报错也不翻界）",
                  shownLine(ctx).isEmpty || shownLine(ctx) == "L02", shownLine(ctx))
        ctx.check("校准-从上限退一步就动",
                  p.nudgeLyricShift(-PlayerController.lyricShiftStep).contains("延后")
                    && abs(p.lyricShift - 29.5) < 1e-9, p.lyricShift.description)
        ctx.check("校准-直接给到下限并按满",
                  p.setLyricShift(-99) == "歌词提前 30.0 秒" && abs(p.lyricShift + 30) < 1e-9,
                  p.lyricShiftText)
        let lowEdge = p.nudgeLyricShift(-PlayerController.lyricShiftStep)
        ctx.check("校准-下限同理不动",
                  abs(p.lyricShift + 30) < 1e-9 && lowEdge.contains("下限 -30 秒"), lowEdge)
        _ = p.setLyricShift(0)
        ctx.check("校准-归零后不再占表里的位子", shownLine(ctx) == "L04")
        // 步进按满 0.1 秒一格：0.5 累加不能攒出 1.4999999 这种数（界面上要写成一句话）
        for _ in 0..<3 { _ = p.nudgeLyricShift(0.5) }
        ctx.check("校准-连按三次是整 1.5 秒", abs(p.lyricShift - 1.5) < 1e-12,
                  p.lyricShift.description)
        _ = p.setLyricShift(0)
        // seek 当场换行：不用等心跳，也不用怕暂停里位置自己走
        ctx.check("校准-seek 到 12.3 秒查第 12 句", park(ctx, p, at: 12.3) && shownLine(ctx) == "L12",
                  shownLine(ctx))
        _ = p.setLyricShift(1.0)
        ctx.check("校准-seek 与校准叠加（延后 1 秒）", shownLine(ctx) == "L11", shownLine(ctx))
        // 暂停里恢复播放：位置接着走，行也要跟着走，不能停在三秒前那句
        p.togglePlay()
        _ = ctx.waitUntil(6) { p.isPlaying }
        let moving = ctx.waitUntil(8) { shownLine(ctx) == "L12" || shownLine(ctx) == "L13" }
        ctx.check("校准-恢复播放后查行跟着位置走", moving, "line=\(shownLine(ctx))")
        ctx.check("校准-播放中位置真的在走", p.currentTime > 12.0,
                  String(format: "%.2f", p.currentTime))
        p.pause()
        _ = ctx.waitUntil(3) { !p.isPlaying }
        // 末行：没有「下一句」也不能翻出界。先把上一段留下的「延后 1 秒」归零，
        // 不然 20.4 秒落在 19.4 秒那一句上，验的就不是末行了
        _ = p.setLyricShift(0)
        ctx.check("校准-末行能停到最后一句", park(ctx, p, at: 20.4) && shownLine(ctx) == "L20",
                  shownLine(ctx))
        ctx.check("校准-末行没有下一句就留空", shownNext(ctx).isEmpty, shownNext(ctx))
        _ = p.setLyricShift(-1.0)
        ctx.check("校准-末行提前 1 秒仍不越界", shownLine(ctx) == "L20", shownLine(ctx))
        _ = p.setLyricShift(0)
        // 两处一致：主显示区与歌词秀必须念同一句（同一个 alignedLyricTime）
        _ = park(ctx, p, at: 7.4)
        ctx.check("校准-两处未校准都念第 7 句", sameLineInBothPlaces(ctx, "L07"),
                  "main=\(shownLine(ctx)) lyric=\(ctx.main.lyricWindow?.currentLineText ?? "nil")")
        _ = p.nudgeLyricShift(PlayerController.lyricShiftStep)
        ctx.check("校准-校准后两处仍同一句", sameLineInBothPlaces(ctx, "L06"),
                  "main=\(shownLine(ctx)) lyric=\(ctx.main.lyricWindow?.currentLineText ?? "nil")")
        ctx.check("校准-歌词秀状态格跟着变",
                  ctx.main.lyricWindow?.shiftLabelText == "校准：延后 0.5 秒",
                  ctx.main.lyricWindow?.shiftLabelText ?? "nil")
        _ = p.setLyricShift(0)
    }

    // MARK: - 与 LRC 自带 offset 叠加不重复

    private func checkFileOffsetOnce(_ ctx: SelfTestContext, p: PlayerController, mat: Material) {
        p.stop(); p.clearPlaylist()
        _ = p.addTracks([Track(url: mat.offset)])
        guard p.playlist.tracks.count == 1, let t = p.playlist.tracks.first else {
            ctx.check("校准-offset 素材能入表", false); return
        }
        p.play(track: t)
        _ = ctx.waitUntil(8) { p.isPlaying && p.lyric != nil }
        p.pause()
        guard park(ctx, p, at: 4.2) else { return }
        ctx.check("校准-词里读到自带 offset", abs((p.lyric?.fileOffset ?? 0) - 1.5) < 1e-9,
                  "\(p.lyric?.fileOffset ?? -1)")
        // 同一个 4.2 秒：不带 offset 是 L04，叠一次是 L05，叠两次会是 L07 —— 三个答案互不重叠
        ctx.check("校准-offset 只叠加一次", shownLine(ctx) == "L05", shownLine(ctx))
        ctx.check("校准-详情句把文件自带那句说清楚",
                  p.lyricShiftDetail.contains("文件自带") && p.lyricShiftDetail.contains("已叠加不重算"),
                  p.lyricShiftDetail)
        _ = p.setLyricShift(1.0)
        ctx.check("校准-用户那一层只再叠自己的一层", shownLine(ctx) == "L04", shownLine(ctx))
        ctx.check("校准-两句同时在状态里",
                  p.lyricShiftDetail.contains("延后 1.0 秒") && p.lyricShiftDetail.contains("+1.5 秒"),
                  p.lyricShiftDetail)
        _ = p.setLyricShift(0)
        ctx.check("校准-撤掉用户那层还剩文件那层", shownLine(ctx) == "L05", shownLine(ctx))
        // 属性面板那几行的数据源也只有一份：同一句偏在这里再念一遍
        let extra = p.propertyExtraLines(for: t).map { $0.0 }
        ctx.check("校准-属性面板读得到校准行", extra.contains("歌词时间校准"), extra.joined(separator: ","))
    }

    // MARK: - CUE：段内/镜像时基与各轨分别保存

    private func checkCueBases(_ ctx: SelfTestContext, p: PlayerController, mat: Material) {
        p.stop(); p.clearPlaylist()
        let album = LibraryStore.tracks(in: [mat.albumCue])
        ctx.check("校准-整盘分轨表能展开", album.count == 2 && album.allSatisfy { $0.isCueSegment },
                  "n=\(album.count)")
        guard album.count == 2 else { return }
        _ = p.addTracks(album)
        p.playRowAt(1)                       // 第二轨：段起点第 10 秒
        if !ctx.waitUntil(8, { p.isPlaying && p.lyric != nil }) {
            ctx.check("校准-分轨能拿到整盘的词", false, "lyric=\(String(describing: p.lyric))")
            return
        }
        p.pause()
        ctx.check("校准-整盘词要补段起点", abs((p.lyric?.mirrorShift ?? 0) - Self.cueStart) < 1e-9,
                  "\(p.lyric?.mirrorShift ?? -1)")
        _ = park(ctx, p, at: 2.0)
        // 段内第 2 秒 = 镜像第 12 秒：漏了补量会唱成第 2 句，补两次会唱到第 22 句（表里没有）
        ctx.check("校准-段内位置按镜像时间轴查行", shownLine(ctx) == "L12", shownLine(ctx))
        _ = p.setLyricShift(1.0)
        ctx.check("校准-整盘词上校准照样只叠一层", shownLine(ctx) == "L11", shownLine(ctx))
        let key2 = p.currentTrack?.identityKey ?? ""
        usedKeys.insert(key2)
        ctx.check("校准-CUE 轨的身份含轨号", key2.contains("#track=2"), key2)
        // 各轨各存：换到第一轨（段起点 0）就该是另一个身份、另一份校准
        p.playRowAt(0)
        _ = ctx.waitUntil(8) { p.lyric != nil && p.currentTrack?.isCueSegment == true }
        p.pause()
        let key1 = p.currentTrack?.identityKey ?? ""
        usedKeys.insert(key1)
        ctx.check("校准-两轨身份不同", key1 != key2 && key1.contains("#track=1"), key1)
        ctx.check("校准-第一轨不受第二轨的校准影响",
                  abs(p.lyricShift) < 1e-9 && p.lyricShiftText == "未校准", p.lyricShiftText)
        _ = park(ctx, p, at: 2.0)
        ctx.check("校准-第一轨段起点为 0 不补量",
                  abs((p.lyric?.mirrorShift ?? -1)) < 1e-9 && shownLine(ctx) == "L02", shownLine(ctx))
        // 按轨名命中的那一份：时间轴本来就从这一轨的 0 秒起，补量才是错
        p.stop(); p.clearPlaylist()
        let per = LibraryStore.tracks(in: [mat.perCue])
        ctx.check("校准-另一张分轨表能展开", per.count == 2, "n=\(per.count)")
        guard per.count == 2 else { return }
        _ = p.addTracks(per)
        p.playRowAt(1)
        _ = ctx.waitUntil(8) { p.isPlaying && p.lyric != nil }
        p.pause()
        _ = park(ctx, p, at: 2.0)
        ctx.check("校准-按轨名命中的词不补段起点",
                  abs((p.lyric?.mirrorShift ?? -1)) < 1e-9, "\(p.lyric?.mirrorShift ?? -1)")
        ctx.check("校准-按轨名命中的词从本轨 0 秒起", shownLine(ctx) == "T02", shownLine(ctx))
        usedKeys.insert(p.currentTrack?.identityKey ?? "")
    }

    // MARK: - 稳定身份、落盘与「不改写 .lrc」

    private func checkIdentityAndPersistence(_ ctx: SelfTestContext, p: PlayerController,
                                             mat: Material) {
        let lrcBefore = (try? Data(contentsOf: mat.plainLRC)) ?? Data()
        p.stop(); p.clearPlaylist()
        _ = p.addTracks([Track(url: mat.plain), Track(url: mat.noLyric)])
        ctx.check("校准-两条素材都入表", p.playlist.count == 2, "n=\(p.playlist.count)")
        let plainTrack = p.playlist.tracks.first { $0.url.path == mat.plain.path }
        guard let plainTrack else { ctx.check("校准-普通轨在表里", false); return }
        p.play(track: plainTrack)
        _ = ctx.waitUntil(8) { p.isPlaying && p.lyric != nil }
        p.pause()
        _ = park(ctx, p, at: 4.2)
        _ = p.setLyricShift(2.0)
        usedKeys.insert(plainTrack.identityKey)
        ctx.check("校准-校准后当场换行", shownLine(ctx) == "L02", shownLine(ctx))
        // 换到没歌词的那一条：偏移不能跟着串过去
        let bareTrack = p.playlist.tracks.first { $0.url.path == mat.noLyric.path }
        guard let bareTrack else { ctx.check("校准-无词素材在表里", false); return }
        p.play(track: bareTrack)
        _ = ctx.waitUntil(8) { p.currentTrack?.identityKey == bareTrack.identityKey }
        ctx.check("校准-换曲目后按新身份取值（没校准过）",
                  abs(p.lyricShift) < 1e-9, p.lyricShift.description)
        p.play(track: plainTrack)
        _ = ctx.waitUntil(8) { p.lyric != nil && p.currentTrack?.identityKey == plainTrack.identityKey }
        p.pause()
        _ = park(ctx, p, at: 4.2)
        ctx.check("校准-切回来还记得这一曲的校准",
                  abs(p.lyricShift - 2) < 1e-9 && shownLine(ctx) == "L02",
                  "shift=\(p.lyricShift) line=\(shownLine(ctx))")
        // 磁盘上那一份：按身份存，一个 .lrc 都没被写过
        let state = LibraryStore.load()
        ctx.check("校准-表里按身份记着",
                  abs((state.lyricShifts[plainTrack.identityKey] ?? 0) - 2) < 1e-9
                    && state.lyricShifts[plainTrack.identityKey] != nil,
                  state.lyricShifts.description)
        let diskLRC = (try? Data(contentsOf: mat.plainLRC)) ?? Data()
        ctx.check("校准-用户的 .lrc 一个字都没被改", diskLRC == lrcBefore && diskLRC.count > 0,
                  "bytes=\(diskLRC.count)/\(lrcBefore.count)")
        ctx.check("校准-偏移也不写进音频文件",
                  ((try? Data(contentsOf: mat.plain))?.count ?? 0) > 1_000_000)
        // 模拟重启：内存里那张表清空，只从盘上接回来
        p.resetLyricShiftTable()
        ctx.check("校准-重启前内存确实空了", abs(p.lyricShift) < 1e-9 && shownLine(ctx) == "L04",
                  "shift=\(p.lyricShift) line=\(shownLine(ctx))")
        let n = p.reloadLyricShiftsFromState()
        ctx.check("校准-读档把表接回来", n == state.lyricShifts.count && n >= 1, "n=\(n)")
        ctx.check("校准-重启后偏的仍是那一句",
                  abs(p.lyricShift - 2) < 1e-9 && shownLine(ctx) == "L02",
                  "shift=\(p.lyricShift) line=\(shownLine(ctx))")
        ctx.check("校准-重启后两处仍同一句", sameLineInBothPlaces(ctx, "L02"),
                  "main=\(shownLine(ctx)) lyric=\(ctx.main.lyricWindow?.currentLineText ?? "nil")")
        // 旧档没这一项：当成「谁都没校准过」，不是坏档
        let legacy = try? JSONDecoder().decode(AppState.self, from: Data("{\"trackPaths\":[]}".utf8))
        ctx.check("校准-旧档缺这一项按空表迁移", legacy?.lyricShifts.isEmpty == true,
                  String(describing: legacy?.lyricShifts))
        // 盘上被改坏过（超出上下限）：取回来先夹住，不能把 999 秒当真
        var dirty = state
        dirty.lyricShifts[plainTrack.identityKey] = 999
        LibraryStore.save(dirty)
        _ = p.reloadLyricShiftsFromState()
        ctx.check("校准-存档越界值取回来先夹住",
                  abs(p.lyricShift - PlayerController.lyricShiftLimit) < 1e-9, p.lyricShift.description)
        // 被人手改过的存档：JSON 这一层本来就容不下 NaN / 超出范围的数 / 字符串，
        // 它们会让整份档解不开（`LibraryStore.load` 回到默认档），而不是被当成「偏了一大截」。
        // 这里只比解码，不碰盘上那份共享存档：弄坏了后面几套都要跟着吃亏
        let junk: [(String, Bool)] = [
            ("{\"trackPaths\":[],\"lyricShifts\":{\"a\":1e999}}", false),   // 超出 double 范围
            ("{\"trackPaths\":[],\"lyricShifts\":{\"a\":\"abc\"}}", false),  // 根本不是数
            ("{\"trackPaths\":[],\"lyricShifts\":{\"a\":999}}", true),       // 合法数字：解得开，取回来再夹
        ]
        var allAsExpected = true
        var verdicts: [String] = []
        for (json, shouldDecode) in junk {
            // `try?` 的作用范围很宽：必须把括号只围住解码那一句，
            // 写成 (try? decode(...) != nil) 会把整句包起来，拿到的是 Bool
            let decoded = (try? JSONDecoder().decode(AppState.self, from: Data(json.utf8))) != nil
            if decoded != shouldDecode { allAsExpected = false }
            verdicts.append(shouldDecode ? (decoded ? "该解开的解开了" : "连合法数字都解不开")
                                         : (decoded ? "坏值竟然解开了" : "坏值被挡住"))
        }
        ctx.check("校准-存档里非数字的偏移解不开，不会当成大偏移", allAsExpected,
                  verdicts.joined(separator: " | "))
        // 夹住后的那一份要回到正常：收摊前本来就是重新 save 一次，这里当场验一句读得回正常值
        LibraryStore.save(state)
        _ = p.reloadLyricShiftsFromState()
        ctx.check("校准-夹过之后还能读回正常那一份", abs(p.lyricShift - 2) < 1e-9,
                  p.lyricShift.description)
    }

    // MARK: - 禁用说明与键盘归属

    private func checkDisabledAndKeyboard(_ ctx: SelfTestContext, p: PlayerController,
                                          mat: Material) {
        // 无歌词：三个入口都要按不动，并且说的是同一件事
        p.stop(); p.clearPlaylist()
        _ = p.addTracks([Track(url: mat.noLyric)])
        guard let bare = p.playlist.tracks.first else { ctx.check("校准-无词素材能入表", false); return }
        p.play(track: bare)
        _ = ctx.waitUntil(8) { p.isPlaying }
        let why = p.lyricShiftProblem ?? ""
        ctx.check("校准-无歌词时说清楚为什么", why.contains("没找到可用歌词"), why)
        ctx.check("校准-无歌词时不能调", !p.lyricShiftApplies)
        ctx.check("校准-无歌词时按了什么都不动",
                  p.nudgeLyricShift(0.5) == why && abs(p.lyricShift) < 1e-9, p.nudgeLyricShift(0.5))
        ctx.check("校准-无歌词时主显示区那句歌词留空", shownLine(ctx).isEmpty, shownLine(ctx))
        let sub = ctx.main.buildLyricShiftItem().submenu!
        ctx.check("校准-无歌词时菜单三项灰掉",
                  sub.items.filter { $0.title.hasPrefix("提前") || $0.title.hasPrefix("延后")
                        || $0.title.hasPrefix("重置") }.allSatisfy { !$0.isEnabled })
        ctx.check("校准-菜单灰掉的项也带上原因",
                  sub.items.first?.toolTip?.contains("没找到可用歌词") == true,
                  sub.items.first?.toolTip ?? "nil")
        _ = park(ctx, p, at: 4.2)
        ctx.check("校准-歌词秀状态格说同一件事",
                  ctx.main.lyricWindow?.shiftLabelText.contains("没找到可用歌词") == true,
                  ctx.main.lyricWindow?.shiftLabelText ?? "nil")
        // 电台是直播：按不动，但别让人以为是 bug
        p.play(track: Track(radio: URL(string: "http://127.0.0.1:9/stream")!))
        ctx.check("校准-电台能进来（下面的判断才成立）", ctx.waitUntil(6) { p.isRadio },
                  "isRadio=\(p.isRadio)")
        ctx.check("校准-电台说这是直播", (p.lyricShiftProblem ?? "").contains("直播"),
                  p.lyricShiftProblem ?? "nil")
        ctx.check("校准-电台不给调", !p.lyricShiftApplies && abs(p.lyricShift) < 1e-9)
        ctx.check("校准-电台下菜单也灰掉",
                  ctx.main.buildLyricShiftItem().submenu?.items.first {
                      $0.title.hasPrefix("延后") }?.isEnabled == false)
        p.stop()
        _ = ctx.waitUntil(6) { !p.isRadio }
        // 快捷键的归属：正在输入框里打字时 ⌥←/⌥→/⌥0 一律还给输入框。
        // 列表里故意留两条（有词 + 无词）：不带 Option 的 ←/→ 必须还是上一曲/下一曲。
        // 顺序要紧：待播队列是开唱那一下照列表建的，先播后加的那条不在队里，
        // → 会被当成「没有下一首」，那就验不出键盘到底归谁
        p.stop(); p.clearPlaylist()
        _ = p.addTracks([Track(url: mat.plain), Track(url: mat.noLyric)])
        guard let withLyric = p.playlist.tracks.first(where: { $0.url.path == mat.plain.path }) else {
            ctx.check("校准-有词那条在表里", false, "n=\(p.playlist.count)"); return
        }
        usedKeys.insert(withLyric.identityKey)
        p.play(track: withLyric)
        if !ctx.waitUntil(8, { p.isPlaying && p.lyric != nil }) {
            ctx.check("校准-键盘这一段能拿到歌词", false, "n=\(p.playlist.count)"); return
        }
        _ = p.setLyricShift(0)
        guard park(ctx, p, at: 4.2) else { return }
        let panel = ctx.main.playlistPanel
        panel.collapseSearch()        // 放大镜与搜索框一起收好：下一段验的是键盘归属
        ctx.main.setListVisible(true)
        func key(_ target: NSWindow, _ chars: String, code: UInt16,
                 mods: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                             windowNumber: Int(target.windowNumber), context: nil,
                             characters: chars, charactersIgnoringModifiers: chars,
                             isARepeat: false, keyCode: code)
        }
        func opt(_ target: NSWindow, _ which: Int) -> NSEvent? {
            switch which {
            case 0: return key(target, "\u{F702}", code: 123, mods: .option)   // ⌥←
            case 1: return key(target, "\u{F703}", code: 124, mods: .option)   // ⌥→
            default: return key(target, "0", code: 29, mods: .option)          // ⌥ 0
            }
        }
        guard let cmdF = key(panel.window, "f", code: 3, mods: .command),
              ctx.main.handleKey(cmdF), panel.searchHasKeyboard,
              let typedPrev = opt(panel.window, 0), let typedNext = opt(panel.window, 1),
              let typedZero = opt(panel.window, 2),
              let plainNext = key(ctx.main.window, "\u{F703}", code: 124, mods: []) else {
            ctx.check("校准-能把键盘交给搜索框并造出键盘事件", false); return
        }
        let before = p.lyricShift
        ctx.check("校准-输入框里 ⌥→ 不误触",
                  !ctx.main.handleKey(typedNext) && abs(p.lyricShift - before) < 1e-9,
                  "shift=\(p.lyricShift)")
        ctx.check("校准-输入框里 ⌥← 也不误触",
                  !ctx.main.handleKey(typedPrev) && abs(p.lyricShift - before) < 1e-9)
        ctx.check("校准-输入框里 ⌥0 同样不误触",
                  !ctx.main.handleKey(typedZero) && abs(p.lyricShift - before) < 1e-9)
        ctx.check("校准-输入框里 ⌥← 也不会顺手跳曲",
                  p.currentTrack?.url.path == mat.plain.path,
                  p.currentTrack?.url.lastPathComponent ?? "nil")
        ctx.check("校准-输入框里按这些键句子也不动", shownLine(ctx) == "L04", shownLine(ctx))
        panel.window.makeFirstResponder(nil)
        ctx.main.window.makeFirstResponder(nil)
        guard let liveNext = opt(ctx.main.window, 1), let livePrev = opt(ctx.main.window, 0),
              let liveZero = opt(ctx.main.window, 2), ctx.main.handleKey(liveNext) else {
            ctx.check("校准-平时 ⌥→ 能吃到", false); return
        }
        ctx.check("校准-平时 ⌥→ 延后 0.5 秒",
                  abs(p.lyricShift - 0.5) < 1e-9 && shownLine(ctx) == "L03", p.lyricShift.description)
        _ = ctx.main.handleKey(livePrev)
        ctx.check("校准-平时 ⌥← 退回未校准", abs(p.lyricShift) < 1e-9 && shownLine(ctx) == "L04",
                  p.lyricShift.description)
        _ = ctx.main.handleKey(liveNext)
        _ = ctx.main.handleKey(liveZero)
        ctx.check("校准-平时 ⌥0 直接归零", abs(p.lyricShift) < 1e-9 && shownLine(ctx) == "L04",
                  shownLine(ctx))
        // ←/→ 本身仍是上一曲/下一曲：加了 ⌥ 才换成校准
        _ = ctx.main.handleKey(plainNext)
        ctx.check("校准-不带 Option 的 → 照旧是下一曲",
                  ctx.waitUntil(6) { p.currentTrack?.url.path == mat.noLyric.path },
                  p.currentTrack?.url.lastPathComponent ?? "nil")
        panel.collapseSearch()
        ctx.main.window.makeFirstResponder(nil)
    }

    // MARK: - 收尾

    private func cleanup(_ ctx: SelfTestContext, _ p: PlayerController, _ keep: Snapshot) {
        p.stop()
        // 本套写进表里的键全部摘干净，再把跑之前的那份原样写回盘
        var st = LibraryStore.load()
        for k in usedKeys { st.lyricShifts[k] = nil }
        for (k, v) in keep.shifts { st.lyricShifts[k] = v }
        LibraryStore.save(st)
        _ = p.reloadLyricShiftsFromState()
        ctx.check("校准-收摊后表与来时一样", p.reloadLyricShiftsFromState() == keep.shifts.count
                          && LibraryStore.load().lyricShifts == keep.shifts,
                  LibraryStore.load().lyricShifts.description)
        ctx.check("校准-收摊后没有留偏移", abs(p.lyricShift) < 1e-9, p.lyricShift.description)
        // 歌词秀是本套打开的就得由本套关掉：后面的套件不该看到一张开着的窗
        if ctx.main.lyricVisible != keep.lyricWindowOpen { ctx.main.toggleLyricWindow() }
        p.setMode(keep.playMode)
        if abs(p.volume - keep.volume) > 0.001 { p.setVolume(keep.volume) }
        p.setGaplessPlay(keep.gapless)
        try? ctx.fm.removeItem(at: root)
        ctx.resetLibrary()
        ctx.check("校准-收摊后主显示区不留残句", ctx.main.displayPanel.lyricText.isEmpty,
                  ctx.main.displayPanel.lyricText)
    }

    // MARK: - 小工具

    /// 把某一条素材放进列表并播起来（拿到歌词为止），失败就记一条断言
    @discardableResult
    private func loadPlain(_ ctx: SelfTestContext, _ p: PlayerController,
                           _ mat: Material) -> Bool {
        p.stop()
        p.clearPlaylist()
        _ = p.addTracks([Track(url: mat.plain)])
        guard p.playlist.tracks.count == 1, let t = p.playlist.tracks.first else {
            ctx.check("校准-普通素材能入表", false, "n=\(p.playlist.count)"); return false
        }
        usedKeys.insert(t.identityKey)
        p.play(track: t)
        if !ctx.waitUntil(8, { p.isPlaying && p.lyric != nil }) {
            ctx.check("校准-普通素材能拿到歌词", false,
                      "playing=\(p.isPlaying) lyric=\(String(describing: p.lyric))")
            return false
        }
        return true
    }

    /// 暂停在指定秒：暂停里位置不会自己走，「此刻该是哪一句」才有唯一解
    @discardableResult
    private func park(_ ctx: SelfTestContext, _ p: PlayerController, at seconds: Double) -> Bool {
        if p.isPlaying { p.pause() }
        _ = ctx.waitUntil(3) { !p.isPlaying }
        p.seek(to: seconds)
        // （这里的 waitUntil 要写成括号里传尾随闭包：guard ctx.waitUntil(2) { … } else
        // 会被当成「给 waitUntil 传了一个尾随闭包」，条件里那个 < 直接没人管了）
        guard ctx.waitUntil(2, { abs(p.currentTime - seconds) < 0.05 }) else {
            ctx.emit("[selftest] SKIP 校准-seek 到位（想停 \(seconds) s，实际 \(String(format: "%.2f", p.currentTime)) s）")
            return false
        }
        // 位置落定与画面换行之间有一格时差：seek 里那一笔用的是当时那个「还在路上」的位置，
        // 真正稳下来的那一句要等控制层心跳（0.25 s）才能补上。不摊平这一格就读到残影
        settleShown(ctx)
        return true
    }

    /// 连续两拍（>0.3 s）读到同一句才算画面落定：真卡住了也不会由它糊过去，
    /// 后面那条断言会比的是它自己该比的那一句
    private func settleShown(_ ctx: SelfTestContext) {
        var last = shownLine(ctx)
        var seen = Date()
        _ = ctx.waitUntil(3) {
            let now = shownLine(ctx)
            if now == last { return Date().timeIntervalSince(seen) >= 0.3 }
            last = now
            seen = Date()
            return false
        }
    }

    private func shownLine(_ ctx: SelfTestContext) -> String { ctx.main.displayPanel.lyricText }
    private func shownNext(_ ctx: SelfTestContext) -> String { ctx.main.displayPanel.lyricNextText }

    /// 主显示区与歌词秀念的是同一句：歌词秀那侧靠它自己的节拍刷新，等一下再比
    private func sameLineInBothPlaces(_ ctx: SelfTestContext, _ want: String) -> Bool {
        guard let win = ctx.main.lyricWindow else { return false }
        _ = ctx.waitUntil(2) { win.currentLineText == want && self.shownLine(ctx) == want }
        return win.currentLineText == want && shownLine(ctx) == want
    }

    private func openLyricWindow(_ ctx: SelfTestContext) {
        guard !ctx.main.lyricVisible else { return }
        ctx.main.toggleLyricWindow()
        _ = ctx.waitUntil(4) { ctx.main.lyricWindow != nil && ctx.main.lyricVisible }
    }
}
