import AppKit

// MARK: - 应用图标

/// 应用图标：蓝底 + 一副耳机（千千静听那款的意象）。
/// 同样不依赖任何图片资源，Dock 运行时图标与 Finder 的 .icns 都由这一份代码生成
/// （build_app.sh 调 `TTPlayer --export-icon`）
enum AppIcon {
    /// 底色：上浅下深的蓝玻璃
    private static let shellTop = NSColor.hex(0x6FB1EA)
    private static let shellBottom = NSColor.hex(0x1A4A84)
    private static let shellEdge = NSColor.hex(0x0E3159)
    /// 耳机：近白（蓝底上白最跳），下沿压一层浅蓝灰做出体积
    private static let glyphFace = NSColor.hex(0xFDFEFF)
    private static let glyphShade = NSColor.hex(0xA9C6E2)
    private static let glyphShadow = NSColor.hex(0x0A2743)

    /// 画一个 side 边长的图标（所有尺寸按比例推，16px 到 1024px 都不糊）
    static func draw(side: CGFloat) {
        let s = side
        let body = NSRect(x: s * 0.05, y: s * 0.05, width: s * 0.90, height: s * 0.90)
        let radius = s * 0.20
        let hair = max(1, (s * 0.006).rounded())

        // 底：上浅下深的蓝玻璃 + 深描边
        fill(body, radius: radius, top: shellTop, bottom: shellBottom,
             edge: shellEdge, lineWidth: hair)

        // 16px 单独收一版：反光、内沿亮线、投影在这个画布上只会变成噪点，
        // 梁与耳罩反过来要加粗，否则缩进菜单栏/列表就散架
        let tiny = s < 24

        if !tiny {
            NSGraphicsContext.saveGraphicsState()
            rounded(body, radius).addClip()
            // 上半段玻璃反光：下半段留深色，图标才有厚度，不会读成一块塑料片
            NSGradient(starting: NSColor(calibratedWhite: 1, alpha: 0.30),
                       ending: NSColor(calibratedWhite: 1, alpha: 0))?.draw(
                in: NSRect(x: body.minX, y: body.midY,
                           width: body.width, height: body.height * 0.5), angle: -90)
            // 内沿亮线：玻璃边缘的一圈高光
            NSColor(calibratedWhite: 1, alpha: 0.30).setStroke()
            let rim = rounded(body.insetBy(dx: hair * 1.5, dy: hair * 1.5), radius - hair * 1.5)
            rim.lineWidth = hair
            rim.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }

        // 耳机：头梁半径、梁厚、耳罩尺寸全按边长推。
        // 16px 时梁厚约 1.7px，缩到菜单栏/列表尺寸也还认得出是耳机
        let cx = s * 0.5
        let bandY = body.minY + s * 0.45
        let bandR = s * 0.21
        let thick = s * (tiny ? 0.105 : 0.085)
        let cupW = s * (tiny ? 0.23 : 0.20)
        let cupH = s * (tiny ? 0.28 : 0.25)

        // 先垫一层深色投影：蓝底上不加投影，白色耳机像贴纸浮在表面
        if !tiny {
            glyphShadow.withAlphaComponent(0.35).setFill()
            for path in headphone(cx: cx, bandY: bandY - s * 0.012, bandR: bandR,
                                  thick: thick, cupW: cupW, cupH: cupH) {
                path.fill()
            }
        }

        for path in headphone(cx: cx, bandY: bandY, bandR: bandR,
                              thick: thick, cupW: cupW, cupH: cupH) {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            glyphFace.setFill()
            path.fill()
            // 下沿压一层浅蓝灰：纯白压在蓝底上会“发飘”，带一点渐变才有体积
            NSGradient(starting: glyphShade.withAlphaComponent(0),
                       ending: glyphShade.withAlphaComponent(0.55))?
                .draw(in: body, angle: -90)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// 耳机轮廓：头梁是“月牙”（外弧顺画、内弧倒画，首尾用直线封口，合起来是可填充的环），
    /// 两侧各一只胶囊耳罩压在梁端。返回路径数组，本体与投影各按同组参数画一遍即可
    private static func headphone(cx: CGFloat, bandY: CGFloat, bandR: CGFloat,
                                  thick: CGFloat, cupW: CGFloat, cupH: CGFloat) -> [NSBezierPath] {
        let c = NSPoint(x: cx, y: bandY)
        let ring = NSBezierPath()
        ring.appendArc(withCenter: c, radius: bandR + thick / 2, startAngle: 0, endAngle: 180)
        ring.appendArc(withCenter: c, radius: bandR - thick / 2,
                       startAngle: 180, endAngle: 0, clockwise: true)
        ring.close()
        var parts = [ring]
        for dx in [-bandR, bandR] {
            let cup = NSRect(x: cx + dx - cupW / 2, y: bandY - cupH * 0.82,
                             width: cupW, height: cupH)
            parts.append(NSBezierPath(roundedRect: cup, xRadius: cupW / 2, yRadius: cupW / 2))
        }
        return parts
    }

    /// 菜单栏状态项的图标：只画耳机本体（不带蓝底）。
    ///
    /// 菜单栏图标必须是模板图（纯黑 + `isTemplate`）：明暗菜单栏、被系统点亮时的
    /// 反色全交给 AppKit。尺寸给 20 宽，高度按耳机比例算出来（约 15.1），
    /// 与菜单栏里那些系统图标同一个量级；几何与 Dock 图标同一套，只是用 16px 那组加粗比例
    static func menuBarImage(width: CGFloat = 20) -> NSImage {
        let s = width / 0.65                  // 0.65 = 2×(0.21 + 0.23/2)，即耳罩外沿的总宽
        let bandR = s * 0.21
        let thick = s * 0.105
        let cupW = s * 0.23
        let cupH = s * 0.28
        // 耳罩底边正好压在 y=0 上，整幅高度 = 梁顶到耳罩底
        let bandY = cupH * 0.82
        let size = NSSize(width: width, height: bandY + bandR + thick / 2)
        let img = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            for path in headphone(cx: width / 2, bandY: bandY, bandR: bandR,
                                  thick: thick, cupW: cupW, cupH: cupH) {
                path.fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// 运行时给 Dock/应用菜单用的图标
    static func image(side: CGFloat) -> NSImage {
        let size = NSSize(width: side, height: side)
        let img = NSImage(size: size)
        img.lockFocus()
        draw(side: side)
        img.unlockFocus()
        return img
    }

    /// 渲染成 PNG 数据（pixelSide 是最终像素边长）
    static func pngData(pixelSide: Int) -> Data? {
        let side = CGFloat(pixelSide)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelSide,
                                         pixelsHigh: pixelSide, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                         bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(side: side)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// 生成 iconset 目录，供 iconutil 合成 .icns
    static func exportIconset(to dir: String) -> Bool {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: dir, isDirectory: true)
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write("创建 iconset 目录失败: \(error)\n".data(using: .utf8)!)
            return false
        }
        let specs: [(String, Int)] = [
            ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
        ]
        for (name, px) in specs {
            guard let data = pngData(pixelSide: px) else { return false }
            do {
                try data.write(to: base.appendingPathComponent(name))
            } catch {
                FileHandle.standardError.write("写入 \(name) 失败: \(error)\n".data(using: .utf8)!)
                return false
            }
        }
        return true
    }

    // MARK: - 画笔

    private static func rounded(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    }

    /// 竖向渐变填充 + 可选描边（尺寸过小时直接跳过，避免画出一条噪点）
    private static func fill(_ r: NSRect, radius: CGFloat, top: NSColor, bottom: NSColor,
                             edge: NSColor?, lineWidth: CGFloat) {
        guard r.width > 1, r.height > 1 else { return }
        let path = rounded(r, min(radius, r.height / 2, r.width / 2))
        NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: -90)
        if let edge, lineWidth >= 1 {
            edge.setStroke()
            path.lineWidth = lineWidth
            path.stroke()
        }
    }
}
