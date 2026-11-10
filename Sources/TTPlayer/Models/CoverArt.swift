import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// 曲目封面的唯一出入口：解码、降采样、找回落文件、按需放大都在这里，界面只管画
///
/// 这个文件守三条低资源底线：
/// 1) 界面里绝不留整张原图。内嵌封面常见 1400×1400（解出来 ≈ 7.8 MB 位图），
///    列表几十首就是几十 MB。所以走 ImageIO 的缩略图通道 —— 压缩数据里直接解出
///    小图，整张原图根本不曾进过内存。
/// 2) 一张封面只解一次。整张专辑十几首曲目共用同一张封面（内嵌图字节一样、
///    外部图是同一个文件），位图按内容/来源共用一个实例（见 Ref），
///    同专辑 N 首曲目只占一份。
/// 3) 曲目上只常驻小档（112px ≈ 50 KB），大档（256px ≈ 262 KB）留给封面大图窗，
///    打开时才按需再解一次。每首曲目各留一张 256 位图，正是「曲库一大就上百 MB」
///    的来源（实测 300 首带封面曲目有 79 MB 花在这上面）。
enum CoverArt {
    /// 大图窗那一档：窗口 240pt，256 已经够清晰
    static let maxPixel: CGFloat = 256
    /// 曲目常驻的小档：显示区 56pt、大图窗以外的界面都用它。
    /// 像素按 2x 解（112px），Retina 下正好 1:1，不用每帧再把大图缩一遍
    static let wellPixel: CGFloat = 56

    /// 目录里认作封面的常用名字（按优先级，与主流抓轨工具一致）
    private static let preferredNames = ["cover", "folder", "front", "album", "show", "thumb"]
    /// 没找到封面时的下一步提示（属性面板与自检共用，避免两处各写一份）
    static let absentHint = "无（在同目录放一张 cover.jpg，或与音频同名的 .png）"
    private static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "webp"]

    /// 一张封面：给界面用的小档图 + 原图像素尺寸（属性面板要说「内嵌 1400×1400」）。
    /// 用引用类型是为了让共享缓存能持弱引用：有曲目拿着它就活着，曲目释放了就跟着走
    final class Art {
        /// 共享键：内嵌图按图片字节摘要、外部文件按路径+大小+修改时间。
        /// 同键 == 同一张封面，位图实例也共用
        let key: String
        let image: NSImage
        let pixelWide: Int
        let pixelHigh: Int
        init(key: String, image: NSImage, pixelWide: Int, pixelHigh: Int) {
            self.key = key
            self.image = image
            self.pixelWide = pixelWide
            self.pixelHigh = pixelHigh
        }
        var pixelLabel: String { pixelWide > 0 ? "\(pixelWide)×\(pixelHigh)" : "尺寸未知" }
    }

    /// 曲目记下的封面：共享位图 + 来路。曲目拿着 art 不放，共享表只存弱引用——
    /// 同封面多首曲目共用一份，曲目出表就跟着释放，不需要另设预算去赶
    struct Ref {
        let key: String
        let art: Art
        let origin: Origin
        enum Origin {
            /// 目录里的封面文件
            case file(URL)
            /// 音频文件自己内嵌的图（APE 读文件尾，其余走 AVFoundation）
            case embedded(URL)
        }
    }

    // MARK: - 解码（曲目常驻的小档）

    static func fromData(_ data: Data) -> Art? {
        // 摘要当键：同一张专辑里每首的内嵌图字节完全相同，摘要相同就共用一份位图
        let key = "d:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return art(key: key) { CGImageSourceCreateWithData(data as CFData, nil) }
    }

    static func fromFile(_ url: URL) -> Art? {
        art(key: fileKey(url)) { CGImageSourceCreateWithURL(url as CFURL, nil) }
    }

    /// 外部封面文件的键：路径 + 大小 + 修改时间。同目录换了一张同名的图
    /// （大小或时间变了）就必须当成新封面，否则列表会一直贴旧图
    private static func fileKey(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let stamp = Int((values?.contentModificationDate ?? .distantPast).timeIntervalSince1970)
        return "f:\(url.path)|\(size)|\(stamp)"
    }

    private static func art(key: String, open: () -> CGImageSource?) -> Art? {
        lock.lock()
        let hit = smalls.object(forKey: key as NSString)
        lock.unlock()
        if let hit { return hit }
        guard let source = open(),
              let image = thumbnail(source, max: wellPixel * 2) else { return nil }
        let size = pixelSize(of: source)
        let art = Art(key: key, image: image, pixelWide: size.0, pixelHigh: size.1)
        lock.lock()
        smalls.setObject(art, forKey: key as NSString)
        lock.unlock()
        return art
    }

    /// ImageIO 的缩略图通道：压缩数据里直接解出小图，整张原图不进内存
    private static func thumbnail(_ source: CGImageSource, max: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            // 按 EXIF 方向转正，手机拍封面存进去也不会歪
            kCGImageSourceCreateThumbnailWithTransform: true,
            // 有些 PNG 没有内嵌缩略图，强制从原图缩出来
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        // 不走 NSImage(cgImage:size:)：2x 屏上它会把源图当成 1x 再按 2 倍备一份，
        // 内存直接乘四。自己摆位图表示，尺寸就是真正占的那点内存
        let image = NSImage(size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
        image.addRepresentation(NSBitmapImageRep(cgImage: cg))
        return image
    }

    private static func pixelSize(of source: CGImageSource) -> (Int, Int) {
        guard let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = info[kCGImagePropertyPixelWidth] as? Int,
              let h = info[kCGImagePropertyPixelHeight] as? Int else { return (0, 0) }
        return (w, h)
    }

    // MARK: - 大档（只有封面大图窗要）

    /// 按需解一档 256 的图。曲目自己不持有它——这是「每首只留小档」的关键。
    /// 解出来进一个有上限的槽位，同一张图反复开关窗口不重复解
    static func large(fromData data: Data, key: String) -> NSImage? {
        large(key: key) { CGImageSourceCreateWithData(data as CFData, nil) }
    }

    static func large(fromFile url: URL, key: String) -> NSImage? {
        large(key: key) { CGImageSourceCreateWithURL(url as CFURL, nil) }
    }

    private static func large(key: String, open: () -> CGImageSource?) -> NSImage? {
        lock.lock()
        if let hit = largeHit(key) {
            lock.unlock()
            return hit
        }
        lock.unlock()
        guard let source = open(), let image = thumbnail(source, max: maxPixel) else { return nil }
        lock.lock()
        storeLarge(key, image)
        lock.unlock()
        return image
    }

    /// 供自检：大档槽位里现在存了几张（改预算逻辑时看它有没有失控）
    static func largeCachedCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return larges.count
    }

    // MARK: - 共享缓存

    /// 一把锁管所有静态表：小档共享表、大档槽位、目录索引。都不在持锁时解码，
    /// 所以后台解析线程并发进来也不会互相等太久
    private static let lock = NSLock()

    /// 小档共享表：值是弱引用。位图活着是因为有曲目（或界面）拿着它，
    /// 曲目出表了就自然释放——不必再为「清空列表后缓存还占着几十 MB」操心。
    /// 键是字符串，弱值用 NSMapTable 的 strongToWeakObjects
    private static let smalls = NSMapTable<NSString, Art>.strongToWeakObjects()

    /// 大档槽位：按最近使用排序，超预算就丢最旧的。8 MB ≈ 30 张 256 的图，
    /// 只服务封面大图窗，和「每首曲目各留一张 256」不是一个量级
    private static var larges: [String: NSImage] = [:]
    private static var largeOrder: [String] = []
    private static var largeBytes = 0
    private static let largeBudget = 8 << 20

    private static func largeHit(_ key: String) -> NSImage? {
        guard let hit = larges[key] else { return nil }
        if let i = largeOrder.firstIndex(of: key) {
            largeOrder.remove(at: i)
            largeOrder.append(key)
        }
        return hit
    }

    private static func storeLarge(_ key: String, _ image: NSImage) {
        larges[key] = image
        largeOrder.removeAll { $0 == key }
        largeOrder.append(key)
        largeBytes += bitmapBytes(image)
        while largeBytes > largeBudget, largeOrder.count > 1 {
            let oldest = largeOrder.removeFirst()
            if let gone = larges.removeValue(forKey: oldest) { largeBytes -= bitmapBytes(gone) }
        }
    }

    /// 位图实际占的字节：按 RGBA 每像素 4 字节估（NSBitmapImageRep 就是这么摆的）
    private static func bitmapBytes(_ image: NSImage) -> Int {
        image.representations.reduce(0) { $0 + $1.pixelsWide * $1.pixelsHigh * 4 }
    }

    // MARK: - 外部封面文件

    /// 目录 →（小写文件名 → 图片地址）。缓存有上限，曲库极大时整体丢掉重来，
    /// 宁可偶尔重列一次目录，也不让这份索引无限膨胀
    private static var index: [String: [String: URL]] = [:]
    private static var scans: [String: Int] = [:]

    /// 供自检：某个目录被真列过几次（同目录的第二首曲目不该再来一次）。
    /// 按目录计数而不是算总数，这样并发解析其他目录时不会弄脏读数
    static func scans(of dir: URL) -> Int {
        lock.lock(); defer { lock.unlock() }
        return scans[dir.path] ?? 0
    }

    /// 找一张代表这首曲目的外部封面：同名图片优先，其次 cover/folder 等常用名。
    /// CUE 分轨要按分轨表所在目录找（镜像和封面在一起，不在 cue 那一侧）
    static func external(for track: Track) -> (url: URL, art: Art)? {
        let dir = (track.cue?.sheetURL ?? track.url).deletingLastPathComponent()
        let files = entries(of: dir)
        let order = [track.fileName.lowercased()] + preferredNames
        for name in order {
            guard let url = files[name] else { continue }
            // 同一个文件在多首曲目上走到这里，键相同 → 拿到同一份位图，不会再解一次
            if let art = fromFile(url) { return (url, art) }
        }
        return nil
    }

    private static func entries(of dir: URL) -> [String: URL] {
        lock.lock(); defer { lock.unlock() }
        let key = dir.path
        if let hit = index[key] { return hit }
        scans[key, default: 0] += 1
        var map: [String: URL] = [:]
        if let names = try? FileManager.default.contentsOfDirectory(atPath: key) {
            for name in names {
                let url = dir.appendingPathComponent(name)
                guard imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let base = url.deletingPathExtension().lastPathComponent.lowercased()
                if map[base] == nil { map[base] = url }
            }
        }
        if index.count >= 512 {
            index.removeAll()
            scans.removeAll()
        }
        index[key] = map
        return map
    }
}
