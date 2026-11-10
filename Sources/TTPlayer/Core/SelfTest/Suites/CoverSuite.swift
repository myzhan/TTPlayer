import Foundation

/// 封面与标签：内嵌图（MP4 的 key 是 nil、只有 identifier；FLAC 走 METADATA_BLOCK_PICTURE）、
/// 外部图回落、降采样上限、目录只列一次、大图窗开关与占位光盘。
/// 素材由 `swift scripts/gen_cover.swift <dir>` 生成。
struct CoverSuite: SelfTestSuite {
    func run(_ ctx: SelfTestContext) {
        let p = ctx.player
        let fm = ctx.fm
        let dirURL = ctx.dir
        let m4aURL = dirURL.appendingPathComponent("cover.m4a")
        let flacURL = dirURL.appendingPathComponent("cover.flac")
        let ready = fm.fileExists(atPath: m4aURL.path) && fm.fileExists(atPath: flacURL.path)
        ctx.check("封面-测试素材就位", ready,
                  "缺 cover.m4a/cover.flac：跑 swift scripts/gen_cover.swift \(dirURL.path)")
        if ready {
            let mp4Track = Track(url: m4aURL)
            MetadataReader.readSync(mp4Track)
            ctx.check("封面-MP4 内嵌图可读", mp4Track.cover != nil, "covr（key=nil，靠 identifier）")
            ctx.check("标签-MP4 标题/艺人可读",
                      mp4Track.title == "封面测试曲" && mp4Track.artist == "测试歌手"
                        && mp4Track.album == "测试专辑",
                      "title=\(mp4Track.title) artist=\(mp4Track.artist) album=\(mp4Track.album)")
            let flacTrack = Track(url: flacURL)
            MetadataReader.readSync(flacTrack)
            ctx.check("封面-FLAC PICTURE 可读", flacTrack.cover != nil, "METADATA_BLOCK_PICTURE")
            // 显示区真的把内嵌图贴上去（而不是始终摆占位图标）
            if let inList = p.playlist.tracks.first(where: { $0.url.path == m4aURL.path }) {
                MetadataReader.readSync(inList)
                p.play(track: inList)
                ctx.check("封面-显示区贴出内嵌图", ctx.main.displayPanel.showsTrackCover,
                          "cover=\(inList.cover != nil)")
                // 大图窗：点显示区那一格封面走的就是这个方法
                ctx.main.toggleCoverWindow()
                ctx.check("封面-大图窗贴当前曲封面", ctx.main.coverWindow?.showsCurrentCover == true,
                          "win=\(ctx.main.coverWindow != nil)")
                ctx.check("封面-大图窗打开后可见", ctx.main.coverWindow?.isVisible == true)
                // 目视验证：尺寸断言全绿时封面仍可能贴歪/配色发闷，所以自己拍一张
                ctx.snapshot(ctx.main.window, named: "shot_cover_main")
                ctx.snapshot(ctx.main.coverWindow?.window, named: "shot_cover_window")
                ctx.main.toggleCoverWindow()
                ctx.check("封面-再点一次关掉大图窗", ctx.main.coverWindow?.isVisible == false)
            } else {
                ctx.check("封面-显示区贴出内嵌图", false, "列表里没找到 cover.m4a")
            }
            ctx.check("封面-内嵌图不被外部文件盖掉", mp4Track.coverSource.hasPrefix("内嵌"),
                      "source=\(mp4Track.coverSource)")
            // 低资源底线：300×300 的内嵌图也不能整档留在界面里。曲目上只常驻一档小图
            // （112px ≈ 50 KB），大档留给封面大图窗按需再解
            ctx.check("封面-曲目只留小档",
                      ctx.bitmapSides(mp4Track.cover) == [Int(CoverArt.wellPixel * 2)],
                      "档位=\(ctx.bitmapSides(mp4Track.cover)) 上限=\(Int(CoverArt.wellPixel * 2))")
            // 同一张封面解两次必须拿到同一个实例：一张专辑 N 首曲目只占一份位图
            // （曲库一大就上百 MB，差额全在这一条上）
            let twice = Track(url: m4aURL)
            MetadataReader.readSync(twice)
            ctx.check("封面-同一封面共享一份位图",
                      twice.cover != nil && twice.cover === mp4Track.cover,
                      "同实例=\(twice.cover === mp4Track.cover)")

            // 大档：只有封面窗要。解出来 ≤256，第二次直接命中槽位不重解
            let big = MetadataReader.largeCover(for: mp4Track)
            ctx.check("封面-大档按需再解且进槽位",
                      ctx.maxBitmapSide(big) > Int(CoverArt.wellPixel * 2)
                        && ctx.maxBitmapSide(big) <= Int(CoverArt.maxPixel)
                        && MetadataReader.largeCover(for: mp4Track) === big,
                      "档位=\(ctx.bitmapSides(big)) 槽位=\(CoverArt.largeCachedCount()) 张")
        }

        // 没内嵌图那一路：靠目录里的图片回落（同名优先，其次 cover.jpg），
        // 并且一张专辑的目录只列一次。素材由 gen_cover.swift 落在 art/ 里，
        // 故意用一张 1200×1200 的 png，拿来看降采样是不是真做了
        let artDir = dirURL.appendingPathComponent("art", isDirectory: true)
        let singleURL = artDir.appendingPathComponent("single.wav")
        let coverlessURL = artDir.appendingPathComponent("coverless.wav")
        let artReady = fm.fileExists(atPath: singleURL.path) && fm.fileExists(atPath: coverlessURL.path)
            && fm.fileExists(atPath: artDir.appendingPathComponent("single.png").path)
            && fm.fileExists(atPath: artDir.appendingPathComponent("cover.jpg").path)
        ctx.check("封面-外部素材就位", artReady,
                  "缺 art/ 素材：跑 swift scripts/gen_cover.swift \(dirURL.path)")
        if artReady {
            let single = Track(url: singleURL)
            MetadataReader.readSync(single)
            ctx.check("封面-同名外部图优先", single.coverSource.contains("single.png"),
                      "source=\(single.coverSource)")
            ctx.check("封面-原图尺寸照实标注", single.coverSource.contains("1200×1200"),
                      "source=\(single.coverSource)")
            ctx.check("封面-外部图也只留小档",
                      ctx.maxBitmapSide(single.cover) <= Int(CoverArt.wellPixel * 2),
                      "档位=\(ctx.bitmapSides(single.cover))")
            // 同一个外部文件被多首曲目用到（整张专辑共用一张 cover.jpg），只解一次
            let sameFile = Track(url: singleURL)
            MetadataReader.readSync(sameFile)
            ctx.check("封面-同一外部文件共享一份位图",
                      sameFile.cover != nil && sameFile.cover === single.cover,
                      "同实例=\(sameFile.cover === single.cover)")
            ctx.check("封面-同一个目录只列一次", CoverArt.scans(of: artDir) == 1,
                      "scans=\(CoverArt.scans(of: artDir))")
            let coverless = Track(url: coverlessURL)
            MetadataReader.readSync(coverless)
            ctx.check("封面-目录 cover.jpg 回退", coverless.coverSource.contains("cover.jpg"),
                      "source=\(coverless.coverSource)")
            ctx.check("封面-同目录第二首不再列目录", CoverArt.scans(of: artDir) == 1,
                      "scans=\(CoverArt.scans(of: artDir))")
            // 不做断言（机器快慢不一），只把开销打进报告：改解码链路时能看见回归
            let coverStart = Date()
            let decoded = CoverArt.external(for: Track(url: singleURL))
            let ms = Int(Date().timeIntervalSince(coverStart) * 1000)
            ctx.emit("[selftest] 1200×1200 封面解+降采样 \(ms) ms，"
                     + "档位=\(ctx.bitmapSides(decoded?.art.image))，"
                     + "原图=\(decoded?.art.pixelLabel ?? "?")")
        }
        // 完全没图时属性面板要给下一步，而不是空一行
        let plainURL = dirURL.appendingPathComponent("demo01.wav")
        if fm.fileExists(atPath: plainURL.path) {
            let plain = Track(url: plainURL)
            MetadataReader.readSync(plain)
            let line = plain.propertyLines.first(where: { $0.0 == "封面" })?.1 ?? ""
            ctx.check("封面-没图时属性里给下一步",
                      plain.cover == nil && line == CoverArt.absentHint,
                      "cover=\(plain.cover != nil) line=\(line)")
            // 占位光盘也拍一张：没封面的时候不能是个黑洞
            if plain.cover == nil,
               let inList = p.playlist.tracks.first(where: { $0.url.path == plainURL.path }) {
                p.play(track: inList)
                ctx.snapshot(ctx.main.window, named: "shot_cover_placeholder")
                if let back = p.playlist.tracks.first(where: { $0.url.path == m4aURL.path }) {
                    p.play(track: back)      // 拍完把当前曲还给后面的用例
                }
            }
        }
    }
}
