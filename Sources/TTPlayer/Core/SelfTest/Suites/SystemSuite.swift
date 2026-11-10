import Foundation
import AppKit
import MediaPlayer

/// 系统集成：控制中心「正在播放」的字段映射，以及菜单栏状态项的两态切换。
/// 两边都只验纯函数与自绘数据面——自检不去改用户机器的控制中心状态，
/// 也不模拟真实鼠标（做不干净）。
struct SystemSuite: SelfTestSuite {
    func run(_ ctx: SelfTestContext) {
        checkNowPlaying(ctx)
        checkStatusItem(ctx)
    }

    // MARK: - 控制中心字段映射（FR-SYS-07）

    /// 只调 `NowPlaying.info` 这个纯函数，不往 MPNowPlayingInfoCenter 里写
    private func checkNowPlaying(_ ctx: SelfTestContext) {
        let track = Track(url: ctx.dir.appendingPathComponent("demo01.wav"))
        track.title = "测试曲目"
        track.artist = "测试艺人"
        track.album = "测试专辑"
        track.duration = 200
        let playing = NowPlaying.info(for: track, isPlaying: true, elapsed: 30)
        ctx.check("正在播放-标题/艺人/专辑",
                  playing[MPMediaItemPropertyTitle] as? String == "测试曲目"
                    && playing[MPMediaItemPropertyArtist] as? String == "测试艺人"
                    && playing[MPMediaItemPropertyAlbumTitle] as? String == "测试专辑", "")
        ctx.check("正在播放-时长与进度",
                  playing[MPMediaItemPropertyPlaybackDuration] as? Double == 200
                    && playing[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 30, "")
        let paused = NowPlaying.info(for: track, isPlaying: false, elapsed: 30)
        ctx.check("正在播放-暂停时速率为 0",
                  (paused[MPNowPlayingInfoPropertyPlaybackRate] as? Double) == 0
                    && paused[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 30, "")
        // 进度不能越过总时长，否则控制中心会画成 3:20/2:00
        let over = NowPlaying.info(for: track, isPlaying: true, elapsed: 400)
        ctx.check("正在播放-进度封顶在总时长",
                  over[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 200, "")
        // 无标签时用文件名兜底，且不写空字符串字段
        let bare = Track(url: ctx.dir.appendingPathComponent("demo02.wav"))
        let bareInfo = NowPlaying.info(for: bare, isPlaying: true, elapsed: 0)
        ctx.check("正在播放-无标签回落文件名",
                  bareInfo[MPMediaItemPropertyTitle] as? String == bare.fileName
                    && bareInfo[MPMediaItemPropertyArtist] == nil,
                  "title=\(bareInfo[MPMediaItemPropertyTitle] ?? "nil")")
    }

    // MARK: - 菜单栏状态项（FR-UI-01 的状态栏部分）

    /// 常态文字 / 悬停切按钮 / 宽度不同抖动。
    /// 悬停本身的入口就是 `setHovered`，和 strip 的回调是同一条。
    private func checkStatusItem(_ ctx: SelfTestContext) {
        let player = ctx.player
        ctx.check("菜单栏-歌名与艺人用间隔点相连",
                  StatusItemController.label(title: "TestSong", artist: "TestArtist", fileName: "a.wav") == "TestSong · TestArtist",
                  StatusItemController.label(title: "TestSong", artist: "TestArtist", fileName: "a.wav"))
        ctx.check("菜单栏-无标签回落文件名",
                  StatusItemController.label(title: "", artist: "", fileName: "demo01") == "demo01", "")
        // 占位艺人（无标签文件必得）不占菜单栏那点宽度
        ctx.check("菜单栏-占位艺人不占位置",
                  StatusItemController.label(title: "TestSong", artist: MetadataReader.unknownArtist,
                                             fileName: "a.wav") == "TestSong", "")
        let font = NSFont.menuBarFont(ofSize: 0)
        let long = String(repeating: "很长的歌名", count: 10)
        let cut = StatusItemController.truncated(long, font: font, maxWidth: 150)
        let cutWidth = (cut as NSString).size(withAttributes: [.font: font]).width
        ctx.check("菜单栏-超长歌名截断后不超宽",
                  cut.count < long.count && cut.hasSuffix("…") && cutWidth <= 150,
                  String(format: "长=%d 截=%d 宽=%.0f", long.count, cut.count, cutWidth))
        ctx.check("菜单栏-短歌名原样返回",
                  StatusItemController.truncated("TestSong", font: font, maxWidth: 150) == "TestSong", "")

        // 悬停态是自绘的：三个键的笔画要分别落在左中右三段里（数“实心”像素）
        // 门槛取 0.5：`labelColor` 本身就是带透明度（实测 alpha≈0.7）的墨色，淡底只有 0.12
        func inkThirds(_ shot: (rep: NSBitmapImageRep, points: CGFloat)?) -> [Int] {
            guard let shot else { return [] }
            var thirds = [0, 0, 0]
            for x in 0..<shot.rep.pixelsWide {
                for y in 0..<shot.rep.pixelsHigh
                where (shot.rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                    thirds[min(2, x * 3 / shot.rep.pixelsWide)] += 1
                }
            }
            return thirds
        }

        // 常态：显示当前曲名（自检素材没有标签，应当回落成文件名）
        player.clearPlaylist()
        _ = player.addFiles([ctx.dir.appendingPathComponent("demo01.wav")])
        player.playRowAt(0)
        _ = ctx.waitUntil(3.0) { player.isPlaying }
        guard let app = NSApp.delegate as? AppDelegate else {
            ctx.check("菜单栏-状态项就位", false, "拿不到 AppDelegate")
            return
        }
        // 真实鼠标可能正好停在菜单栏上（那时已经是悬停态），先归到常态再验
        app.statusBarHover(false)
        ctx.pump(0.15)
        guard let idle = app.statusBarSnapshot else {
            ctx.check("菜单栏-状态项就位", false, "拿不到状态栏")
            return
        }
        ctx.check("菜单栏-常态显示正在播的歌名",
                  idle.title == "demo01" && idle.length > 40 && !idle.expanded,
                  "title=\(idle.title) 宽=\(Int(idle.length))")
        // 图标口径：状态项上那颗必须是 `AppIcon` 画的耳机（模板图），而不是又退回系统音符符号。
        // 只查 `isTemplate` 辨不出两者（符号也是模板图），所以拿尺寸对一下基准
        let want = AppIcon.menuBarImage().size
        let icon = app.statusBarIconSnapshot
        ctx.check("菜单栏-常态图标是自绘耳机（模板图）",
                  icon?.template == true
                    && abs((icon?.width ?? 0) - want.width) < 0.01
                    && abs((icon?.height ?? 0) - want.height) < 0.01,
                  icon.map { "\(String(format: "%.1f", $0.width))×\(String(format: "%.1f", $0.height)) "
                        + "模板=\($0.template)" } ?? "nil"
                    + " 基准=\(String(format: "%.1f×%.1f", want.width, want.height))")
        // 悬停靠 strip 上的 tracking area 驱动，装不上就永远进不了悬停态
        ctx.check("菜单栏-悬停监听已经装上", app.statusBarHoverTrackingReady, "")
        // 菜单首行：委托没接上就会一直停在「未在播放」
        ctx.check("菜单栏-菜单首行是当前曲目",
                  app.statusBarMenuHeader?.hasPrefix("正在播放：demo01") == true,
                  app.statusBarMenuHeader ?? "nil")
        // 悬停：歌名让位给三个键，宽度不能缩到比常态还窄（否则鼠标会掉出去来回闪）
        app.statusBarHover(true)
        let hover = app.statusBarSnapshot
        ctx.check("菜单栏-悬停变成控制键",
                  hover?.expanded == true && hover?.title == "" && (hover?.length ?? 0) >= (idle.length),
                  "expanded=\(hover?.expanded ?? false) 宽=\(Int(hover?.length ?? 0)) ≥ 常态 \(Int(idle.length))")

        let pausedShot = app.statusBarHoverShot(playing: false)
        let paused = inkThirds(pausedShot)
        let running = inkThirds(app.statusBarHoverShot(playing: true))
        ctx.check("菜单栏-三个键都画出来了", paused.count == 3 && paused.allSatisfy { $0 > 4 },
                  "三段墨点=\(paused) 图=\(pausedShot.map { "\($0.rep.pixelsWide)x\($0.rep.pixelsHigh)" } ?? "nil")"
                    + " 点宽=\(Int(pausedShot?.points ?? 0))")
        ctx.check("菜单栏-播放中与暂停画法不同",
                  paused.count == 3 && paused[1] != running[1],
                  "中键 暂停=\(paused.count == 3 ? paused[1] : -1) 播放中=\(running.isEmpty ? -1 : running[1])")
        // 离开后有 80 ms 的宽限，等它过完再验歌名回来了
        app.statusBarHover(false)
        ctx.pump(0.25)
        let back = app.statusBarSnapshot
        ctx.check("菜单栏-移开后歌名回来",
                  back?.expanded == false && back?.title == "demo01",
                  "title=\(back?.title ?? "nil") expanded=\(back?.expanded ?? false)")
        player.stop()
    }
}
