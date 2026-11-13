import Foundation
import AppKit

/// 皮肤、面板与交互：三窗停靠几何、玻璃质感与像素对照、传输键、面板开关与联动、
/// 歌词秀窗口、窗口级拖放、进度槽、列表列宽与列表组。
/// 界面断言分五小节跑，任何一节单拎出来都能自己站住。
struct UISuite: SelfTestSuite {
    func run(_ ctx: SelfTestContext) {
        let p = ctx.player
        let main = ctx.main
        // 界面断言要看“正在播”的样子：先把首曲放起来，标题栏字幕与进度槽都靠它
        if !p.isPlaying { p.playRowAt(0) }
        _ = ctx.waitUntil(4.0) { p.isPlaying && p.currentTime > 0.3 }
        // 定态起点：列表展开、均衡器收起（单跑时不去猜上一套留下的开关）
        main.setListVisible(true)
        main.setEQVisible(false)

        // 每段一个自动释放池：旧版每段是一个 asyncAfter 回调，天然各带一个池子；
        // 改成同步后不还这个债，界面素材（位图、布局临时对象）会堆到整段跑完才排空，
        // 实测单套 RSS 峰值高十几 MB，会把「性能-常驻内存」那条挤到阈值边上
        autoreleasepool { checkShell(ctx) }
        autoreleasepool { checkPanels(ctx) }
        autoreleasepool { checkHiddenGroup(ctx) }
        autoreleasepool { checkLyricWindow(ctx) }
        autoreleasepool { checkDropAndKeys(ctx) }
        autoreleasepool { checkListAndGroups(ctx) }
        p.setMode(.listLoop)
        p.stop()
    }

    // MARK: - 一、外壳与传输键

    private func checkHiddenGroup(_ ctx: SelfTestContext) {
        let dock = SkinDock(width: 480, originTopLeft: NSPoint(x: 100, y: 800))
        let panels: [SkinPanel] = [.main, .playlist, .equalizer]
        let windows = panels.map { SkinPanelWindow(width: 480, height: 200, title: "隐藏回归 \($0)") }
        for (i, panel) in panels.enumerated() { dock.register(panel, windows[i], height: 200) }
        var stayedHidden = 0
        var restored = 0
        for i in 0..<30 {
            dock.showGroup()
            windows[i % windows.count].makeKeyAndOrderFront(nil)
            dock.hideGroup()
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: windows[i % windows.count])
            dock.layout()
            dock.setVisible(false, for: .equalizer)
            dock.setVisible(true, for: .equalizer)
            if windows.allSatisfy({ !$0.isVisible }) { stayedHidden += 1 }
            dock.showGroup()
            if windows.allSatisfy({ $0.isVisible }) { restored += 1 }
        }
        ctx.check("最小化-激活焦点布局与面板变更不弹回", stayedHidden == 30, "\(stayedHidden)/30")
        ctx.check("最小化-明确恢复仍能显示整组", restored == 30, "\(restored)/30")
        dock.hideGroup()
        ctx.main.showWindow()
    }

    private func checkShell(_ ctx: SelfTestContext) {
        let p = ctx.player
        let main = ctx.main
        let w = main.window
        w.contentView?.layoutSubtreeIfNeeded()
        ctx.check("主面板可见", w.isVisible && w.contentView != nil)
        ctx.check("无边框可缩放",
                  w.styleMask.contains(.borderless) && w.isMovable && w.isResizable
                    && w.contentMinSize.width >= MainWindowController.minWidth - 1,
                  "minW=\(Int(w.contentMinSize.width))")
        // 皮肤层级不挂在 contentView 上，否则窗口宽度会被约束的拟合尺寸压掉
        let root = main.skinRoot
        ctx.check("皮肤圆角描边",
                  (root.layer?.cornerRadius ?? 0) >= 6 && (root.layer?.borderWidth ?? 0) >= 1
                    && root !== w.contentView,
                  "radius=\(root.layer?.cornerRadius ?? 0) border=\(root.layer?.borderWidth ?? 0)")
        ctx.check("显示区/控制条紧凑分层",
                  abs(main.displayPanel.frame.height - MainWindowController.displayH) < 1.5
                    && abs(main.controlBar.frame.height - MainWindowController.controlH) < 1.5,
                  "display=\(main.displayPanel.frame.height) control=\(main.controlBar.frame.height)")
        // 玻璃质感：壳层全透明（v1.22 默认 bodyAlpha=0.15）。v1.20 试过 vibrancy 毛玻璃“完全没透”，
        // v1.21 回到 shell alpha 直透，v1.22 用户反馈“不要蓝色底”，壳与内嵌槽一起拉到接近全透明。
        let glassOn = GlassStyle.enabled
        ctx.check("玻璃-壳层接近全透明",
                  root.glassBody && root.bodyAlpha > 0.05 && root.bodyAlpha < 0.30
                    && (w.isOpaque == false),
                  "body=\(String(format: "%.2f", root.bodyAlpha)) opaque=\(w.isOpaque)")
        let vib = w.contentView?.subviews.first { $0 is NSVisualEffectView }
        ctx.check("玻璃-vibrancy 层默认隐藏（不插中间层）",
                  vib != nil && (vib?.isHidden ?? false),
                  "vib present=\(vib != nil) hidden=\(vib?.isHidden ?? false)")
        GlassStyle.setEnabled(false)
        let glassOff = root.bodyAlpha
        GlassStyle.setEnabled(glassOn)
        ctx.check("玻璃-关掉后壳回到不透明",
                  glassOff == 1 && abs(root.bodyAlpha - GlassStyle.bodyAlpha) < 0.001,
                  "off=\(glassOff) on=\(String(format: "%.2f", root.bodyAlpha))")
        // 真的把底板混进去了吗：0.15 × 壳色 + 0.85 × 红底
        if let onRed = ctx.glassPixel(over: .red, enabled: true),
           let offRed = ctx.glassPixel(over: .red, enabled: false) {
            let shell = Theme.windowTop.usingColorSpace(.deviceRGB) ?? Theme.windowTop
            let a = GlassStyle.bodyAlpha
            let wantR = (a * shell.redComponent + (1 - a)) * 255
            let gotR = onRed.redComponent * 255
            let offR = offRed.redComponent * 255
            ctx.check("玻璃-确实透出了背景",
                      abs(gotR - wantR) < 2 && abs(offR - shell.redComponent * 255) < 2
                        && abs(onRed.greenComponent * 255 - a * shell.greenComponent * 255) < 2,
                      "红底上 R=\(String(format: "%.1f", gotR)) 应=\(String(format: "%.1f", wantR)) "
                        + "关了=\(String(format: "%.1f", offR))")
        } else {
            ctx.check("玻璃-确实透出了背景", false, "画不出离屏位图")
        }
        // 传输键已上移：和音量共一行，仍收成一小组靠左
        let keys = main.displayPanel.transportKeys
        let strip = main.displayPanel.transportStrip
        let mute = main.displayPanel.muteView
        let rowW = strip.superview?.frame.width ?? 0
        let seams = zip(keys, keys.dropFirst())
            .map { abs($0.frame.maxX - $1.frame.minX) }
        ctx.check("传输键与音量同一行",
                  keys.count == 5 && strip.superview != nil
                    && strip.superview === mute.superview
                    && abs(strip.frame.midY - mute.frame.midY) < 1.5
                    && main.controlBar.subviews.allSatisfy { !($0 is TTButton) },
                  "midY=\(Int(strip.frame.midY))/\(Int(mute.frame.midY)) row=\(Int(rowW))")
        // 时间读数已去掉：传输带应紧跟静音键（中间原本夹着 50+42 两个 LED）
        ctx.check("底部不再显示时间读数",
                  strip.frame.minX - mute.frame.maxX < 10,
                  "gap=\(Int(strip.frame.minX - mute.frame.maxX))")
        ctx.check("传输键紧凑不铺满整行",
                  strip.frame.width < rowW * 0.45
                    && abs(strip.frame.height - MainWindowController.transportH) < 1,
                  "strip=\(Int(strip.frame.width))/\(Int(rowW)) "
                    + "h=\(Int(strip.frame.height))")
        // 五键贴在一起共用一条玻璃带：相邻无缝，底面由容器统一画
        ctx.check("传输键贴成一条玻璃带",
                  keys.allSatisfy { $0.superview === strip }
                    && strip is SegmentedGlassBar
                    && keys.allSatisfy { $0.face == .none }
                    && seams.allSatisfy { $0 < 0.6 },
                  "seams=\(seams.map { String(format: "%.1f", $0) })")
        // 模式键（最右一格）用常规图标，不用「循」这类文字
        var modeIsSymbol = false
        if case .symbol(let name) = keys.last?.content ?? .title("") {
            modeIsSymbol = !name.isEmpty
        }
        ctx.check("循环模式键用图标不用文字", modeIsSymbol,
                  "mode=\(p.playMode.displayName)")
        // 玻璃带里的键真能点（重排后 target/action 仍接得上）
        let modeBefore = p.playMode
        keys.last?.performClick(nil)
        let modeAfter = p.playMode
        ctx.check("模式键点击切换生效", modeBefore != modeAfter && modeAfter != .order,
                  "\(modeBefore.displayName)→\(modeAfter.displayName)")
        p.setMode(.listLoop)
        ctx.check("标题栏歌名字幕", main.marquee.text.count > 4,
                  "len=\(main.marquee.text.count)")
        // 菜单锚点：要贴着被点的键，不能锚到整条标题条的左端（旧版毛病）
        if let menuBtn = main.titleMenuButton,
           let content = w.contentView,
           let pop = NSMenu.popPoint(under: menuBtn) {
            let popInWindow = content.convert(pop, to: nil)
            let btn = menuBtn.convert(menuBtn.bounds, to: nil)
            ctx.check("菜单开在被点的键下方",
                      abs(popInWindow.x - btn.minX) < 1.5
                        && abs(popInWindow.y - btn.minY) < 1.5
                        && btn.minX > content.bounds.width * 0.6,
                      "pop=\(Int(popInWindow.x)),\(Int(popInWindow.y)) "
                        + "btn=\(Int(btn.minX)),\(Int(btn.minY)) w=\(Int(content.bounds.width))")
        } else {
            ctx.check("菜单开在被点的键下方", false, "拿不到菜单键或点位")
        }
        // 皮肤尺寸：宽度不小于一档默认值，列表行不能是蚂蚁字
        ctx.check("皮肤已放大到可读尺寸",
                  w.frame.width >= MainWindowController.compactWidth - 1
                    && w.frame.height >= MainWindowController.mainPanelH - 2
                    && main.playlistView.rowHeight >= 22,
                  "win=\(Int(w.frame.width))×\(Int(w.frame.height)) row=\(main.playlistView.rowHeight)")
        ctx.check("旧存档宽度已按新皮肤重置",
                  abs(w.frame.width - MainWindowController.compactWidth) < 2,
                  "w=\(Int(w.frame.width)) default=\(Int(MainWindowController.compactWidth))")
        // 应用图标：Dock / Finder 的图都出自同一份绘制代码，不能缺
        let hasIcns = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") != nil
        let dockIcon = NSApp.applicationIconImage
        ctx.check("应用图标已就绪",
                  (dockIcon?.representations.isEmpty == false)
                    && (dockIcon?.size.width ?? 0) > 0,
                  "src=\(hasIcns ? "bundle icns" : "现场绘制") "
                    + "size=\(Int(dockIcon?.size.width ?? 0)) reps=\(dockIcon?.representations.count ?? 0)")
        if let png = AppIcon.pngData(pixelSide: 32),
           let img = NSImage(data: png) {
            ctx.check("图标导出为合法 PNG", png.count > 200 && img.size.width == 32,
                      "bytes=\(png.count) size=\(Int(img.size.width))")
        } else {
            ctx.check("图标导出为合法 PNG", false, "拿不到数据")
        }
    }

    // MARK: - 二、面板：折叠、高度与横向约束

    private func checkPanels(_ ctx: SelfTestContext) {
        let p = ctx.player
        let main = ctx.main
        let w = main.window
        let dock = main.dock
        // 列表面板：独立窗 + 工具条 9 个按钮（第九键是待播队列）
        let listWin = dock.window(for: .playlist)
        ctx.check("播放列表独立面板",
                  main.listVisible && listWin != nil && listWin!.isVisible
                    && abs(listWin!.frame.width - w.frame.width) < 1.5,
                  "list=\(listWin.map { "\(Int($0.frame.width))×\(Int($0.frame.height))" } ?? "nil")")
        ctx.check("列表工具条齐全", main.playlistPanel.toolbarButtonCount == 9,
                  "count=\(main.playlistPanel.toolbarButtonCount)")
        // 启动时的 lit 要跟存档里的面板显隐一致（owner 是建完窗口才接上的）
        let dpStart = main.displayPanel
        ctx.check("启动时面板键点亮跟存档一致",
                  dpStart.listButton.lit == main.listVisible
                    && dpStart.eqButton.lit == main.eqVisible
                    && dpStart.lyricButton.lit == main.lyricVisible,
                  "list=\(main.listVisible)/\(dpStart.listButton.lit) "
                    + "eq=\(main.eqVisible)/\(dpStart.eqButton.lit)")
        // 目视验证：去掉标题条后工具条要真顶到上沿、不能被裁掉
        ctx.snapshot(listWin, named: "shot_list_panel")

        // 折叠：主面板高度不变，整组高度少一块
        let hExpanded = dock.totalHeight
        let mainHExpanded = w.frame.height
        main.setListVisible(false)
        let hCompact = dock.totalHeight
        ctx.check("列表折叠只收起列表面板",
                  hCompact < hExpanded - 100 && abs(w.frame.height - mainHExpanded) < 2
                    && !(listWin?.isVisible ?? true),
                  "group=\(Int(hExpanded))→\(Int(hCompact)) main=\(Int(w.frame.height))")
        main.setListVisible(true)
        ctx.check("列表重新展开恢复组高",
                  abs(dock.totalHeight - hExpanded) < 2 && (listWin?.isVisible ?? false),
                  "group=\(Int(dock.totalHeight))")

        // 均衡器面板：停靠后与主面板同宽，10 段推子 + 2 个旋钮
        main.setEQVisible(true)
        let eqWin = dock.window(for: .equalizer)
        ctx.check("均衡器独立面板",
                  (eqWin?.isVisible ?? false)
                    && abs(eqWin!.frame.width - w.frame.width) < 1.5
                    && main.eqPanel.faderCount == AudioEngine.eqBandCount
                    && AudioEngine.eqBandCount == 10,
                  "eq=\(eqWin.map { "\(Int($0.frame.width))×\(Int($0.frame.height))" } ?? "nil") "
                    + "bands=\(main.eqPanel.faderCount)")
        // 目视验证：三小键迁到左栏旋钮下方，不能和推子区撞上
        ctx.snapshot(eqWin, named: "shot_eq_panel")
        // 三窗的实际高度必须等于停靠组登记的高度，否则约束与布局会相互拉扯
        let hMain = w.frame.height, hList = listWin?.frame.height ?? 0
        let hEQ = eqWin?.frame.height ?? 0
        ctx.check("面板高度与停靠组一致",
                  abs(hMain - MainWindowController.mainPanelH) < 1.5
                    && abs(hList - MainWindowController.playlistPanelH) < 1.5
                    && abs(hEQ - MainWindowController.eqPanelH) < 1.5,
                  "main=\(Int(hMain))/\(Int(MainWindowController.mainPanelH)) "
                    + "list=\(Int(hList)) eq=\(Int(hEQ))")
        main.setEQGainThroughUI(band: 3, gain: 4.5)
        ctx.check("均衡器推子生效", abs(p.engine.eqGain(band: 3) - 4.5) < 0.05,
                  "g=\(p.engine.eqGain(band: 3))")
        // 列表/均衡器也不再有顶部标题条：工具条与主体直接顶到窗口上沿
        // （skinRoot 是翻转坐标，minY 才是顶部）
        listWin?.contentView?.layoutSubtreeIfNeeded()
        eqWin?.contentView?.layoutSubtreeIfNeeded()
        let plGap = main.playlistPanel.toolbarView.frame.minY
        let eqGap = main.eqPanel.bodyView.frame.minY
        ctx.check("列表/均衡器顶部没有标题条", plGap <= 8 && eqGap <= 8,
                  "list=\(Int(plGap)) eq=\(Int(eqGap))")
        main.setEQVisible(false)

        // 横向拉宽：三窗宽度一起跟上新值，不被约束的拟合尺寸压回去
        let back = w.frame
        var wide = w.frame
        wide.size.width = 900
        w.setFrame(wide, display: true)
        w.contentView?.layoutSubtreeIfNeeded()
        let pinned = w.skinWidthConstraint?.constant ?? 0
        let listW = dock.window(for: .playlist)?.frame.width ?? 0
        ctx.check("拉宽时三窗同宽",
                  abs(w.frame.width - 900) < 2 && abs(pinned - 900) < 2
                    && abs(listW - 900) < 2 && abs(dock.width - 900) < 2,
                  "w=\(Int(w.frame.width)) pin=\(Int(pinned)) list=\(Int(listW)) dock=\(Int(dock.width))")
        w.setFrame(back, display: true)

        // 收窄到下限：底部一行不能挤爆（音量滑条先缩短，传输带仍完整）
        var thin = w.frame
        thin.size.width = MainWindowController.minWidth
        w.setFrame(thin, display: true)
        w.contentView?.layoutSubtreeIfNeeded()
        main.displayPanel.layoutSubtreeIfNeeded()
        let stripRight = main.displayPanel.transportStrip.frame.maxX
        let listLeft = main.displayPanel.listButton.frame.minX
        let volW = main.displayPanel.volumeView.frame.width
        let rowW2 = main.displayPanel.transportStrip.superview?.frame.width ?? 0
        ctx.check("收窄到底部一行不重叠",
                  abs(w.frame.width - MainWindowController.minWidth) < 2
                    && stripRight <= listLeft - 4
                    && volW >= 55.5 && volW < 131.5,
                  "w=\(Int(w.frame.width)) dock=\(Int(dock.width)) row=\(Int(rowW2)) "
                    + "stripMaxX=\(Int(stripRight)) listX=\(Int(listLeft)) volW=\(Int(volW))")
        w.setFrame(back, display: true)
        w.contentView?.layoutSubtreeIfNeeded()
    }

    // MARK: - 三、歌词秀窗口

    private func checkLyricWindow(_ ctx: SelfTestContext) {
        let main = ctx.main
        let w = main.window
        let dock = main.dock
        let back = w.frame
        // 歌词秀：无边框皮肤窗，顶部同样没有标题条（开关在三个面板键上）
        main.toggleLyricWindow()
        let lyricWin = main.lyricWindow?.window
        guard let lyricWin, let lyric = main.lyricWindow else {
            ctx.check("歌词秀皮肤窗", false, "拿不到歌词窗")
            return
        }
        lyricWin.contentView?.layoutSubtreeIfNeeded()
        let gap = lyric.contentView.frame.minY
        // 底下现在让给了校准行（F10）：只要求歌词视图把除那一行以外的地方都占满
        let rowH = LyricWindow.controlsRowHeight
        ctx.check("歌词秀皮肤窗",
                  lyricWin.styleMask.contains(.borderless) && lyricWin.isVisible
                    && lyric.contentView.frame.height > lyricWin.frame.height - rowH - 20
                    && gap <= 8,
                  "lyric=\(Int(lyricWin.frame.width))×\(Int(lyricWin.frame.height)) "
                    + "viewH=\(Int(lyric.contentView.frame.height)) gap=\(Int(gap)) 校准行=\(Int(rowH))")
        ctx.snapshot(lyricWin, named: "shot_lyric_panel")
        // 同宽才好在主面板下面上下叠放：左右边缘必须对齐
        ctx.check("歌词窗与停靠组等宽",
                  abs(lyricWin.frame.width - dock.width) < 1.5
                    && abs(lyricWin.frame.width - w.frame.width) < 1.5,
                  "lyric=\(Int(lyricWin.frame.width)) dock=\(Int(dock.width)) "
                    + "main=\(Int(w.frame.width))")
        // 拉宽/收窄主面板，歌词窗宽度跟着走（仍是同宽）
        var wideLyric = w.frame
        wideLyric.size.width = 760
        w.setFrame(wideLyric, display: true)
        w.contentView?.layoutSubtreeIfNeeded()
        let lyricWide = main.lyricWindow?.window.frame.width ?? 0
        w.setFrame(back, display: true)
        w.contentView?.layoutSubtreeIfNeeded()
        let lyricBack = main.lyricWindow?.window.frame.width ?? 0
        ctx.check("歌词窗宽度跟随停靠组",
                  abs(lyricWide - 760) < 2
                    && abs(lyricBack - back.width) < 2
                    && abs(lyricBack - dock.width) < 1.5,
                  "wide=\(Int(lyricWide))/760 back=\(Int(lyricBack))/\(Int(back.width)) "
                    + "dock=\(Int(dock.width))")
        // 没有存档时的默认位置：贴在停靠组正下方，同宽左对齐、上下留一条缝
        lyric.placeBelow(groupLeft: dock.originTopLeft.x,
                         groupBottom: dock.originTopLeft.y - dock.totalHeight)
        let placed = lyricWin.frame
        let groupBottom = dock.originTopLeft.y - dock.totalHeight
        ctx.check("歌词窗默认贴在停靠组正下方",
                  abs(placed.minX - dock.originTopLeft.x) < 1.5
                    && abs(placed.width - dock.width) < 1.5
                    && abs(placed.maxY - (groupBottom - SkinDock.gap)) < 1.5,
                  "left=\(Int(placed.minX)) top=\(Int(placed.maxY)) "
                    + "w=\(Int(placed.width)) 组左=\(Int(dock.originTopLeft.x)) "
                    + "组底=\(Int(groupBottom)) 缝=\(Int(groupBottom - placed.maxY))")
        // 横向拉边不再放开（否则手动拉一下就不再等宽了），高度仍可拉伸
        ctx.check("歌词窗宽度锁死在组宽",
                  abs(lyricWin.contentMinSize.width - dock.width) < 1.5
                    && abs(lyricWin.contentMaxSize.width - dock.width) < 1.5,
                  "min=\(Int(lyricWin.contentMinSize.width)) "
                    + "max=\(Int(lyricWin.contentMaxSize.width)) dock=\(Int(dock.width))")
        main.toggleLyricWindow()
    }

    // MARK: - 四、拖放接线与面板键

    private func checkDropAndKeys(_ ctx: SelfTestContext) {
        let p = ctx.player
        let main = ctx.main
        let w = main.window
        let dock = main.dock
        let listWin = dock.window(for: .playlist)
        let eqWin = dock.window(for: .equalizer)
        // 拖放接线：列表必须实现系统认的 acceptDrop:row:dropOperation:
        // （原来写成了自定义的 acceptDrag:，NSTableView 从不调用，拖进去没反应）
        let dataSource = main.playlistView.table.dataSource
        let acceptDrop = NSSelectorFromString("tableView:acceptDrop:row:dropOperation:")
        let oldName = NSSelectorFromString("tableView:acceptDrag:")
        ctx.check("列表拖放接在系统方法上",
                  dataSource?.responds(to: acceptDrop) == true
                    && dataSource?.responds(to: oldName) != true,
                  "acceptDrop=\(dataSource?.responds(to: acceptDrop) == true) "
                    + "acceptDrag=\(dataSource?.responds(to: oldName) == true)")
        // 三块皮肤窗（主/列表/均衡器）与歌词窗都接了窗口级拖放：
        // 拖到任意一块窗上都能加，不必对准列表那一行
        let dropWins = [w, listWin, eqWin, main.lyricWindow?.window].compactMap { $0 }
        ctx.check("面板窗都接得住拖放",
                  dropWins.count == 4 && dropWins.allSatisfy { $0.onFileDrop != nil },
                  "wins=\(dropWins.count) hooks=\(dropWins.filter { $0.onFileDrop != nil }.count)")
        // 窗口拿到拖放后真的走导入链路（拿一个不支持的文件试：不入表，但会留下原因）
        let dropProbe = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ttplayer-drop.wma")
        try? Data([0x41, 0x53, 0x46] as [UInt8]).write(to: dropProbe)
        let countBeforeDrop = p.playlist.count
        _ = w.onFileDrop?([dropProbe])
        ctx.check("面板窗拖放直接走导入链路",
                  p.playlist.count == countBeforeDrop
                    && (p.lastImportProblem ?? "").contains("WMA"),
                  "n=\(p.playlist.count)/\(countBeforeDrop) note=\(p.lastImportProblem ?? "nil")")

        // 三个面板键：以前只给了 action 没给 target，点了等于没点；
        // 现在要真的开关对应面板，并在键上点亮
        let dp = main.displayPanel
        ctx.check("列表/均衡器/歌词键接上了动作",
                  [dp.listButton, dp.eqButton, dp.lyricButton].allSatisfy {
                      $0.target != nil && $0.action != nil
                  },
                  "target=\(dp.listButton.target != nil) "
                    + "actions=\([dp.listButton, dp.eqButton, dp.lyricButton].map { $0.action != nil })")
        dp.listButton.performClick(nil)
        ctx.check("列表键点击-折叠并熄灭",
                  !main.listVisible && !dp.listButton.lit,
                  "visible=\(main.listVisible) lit=\(dp.listButton.lit)")
        dp.listButton.performClick(nil)
        ctx.check("列表键点击-再展开并点亮",
                  main.listVisible && dp.listButton.lit,
                  "visible=\(main.listVisible) lit=\(dp.listButton.lit)")
        let dspBefore = p.eqEnabled
        dp.eqButton.performClick(nil)
        ctx.check("均衡器键点击-展开并点亮",
                  main.eqVisible && dp.eqButton.lit && p.eqEnabled == dspBefore,
                  "visible=\(main.eqVisible) lit=\(dp.eqButton.lit) dsp=\(p.eqEnabled)")
        dp.eqButton.performClick(nil)
        ctx.check("均衡器键点击-再折叠并熄灭",
                  !main.eqVisible && !dp.eqButton.lit,
                  "visible=\(main.eqVisible) lit=\(dp.eqButton.lit)")
        dp.lyricButton.performClick(nil)
        ctx.check("歌词键点击-开窗并点亮",
                  main.lyricVisible && dp.lyricButton.lit,
                  "visible=\(main.lyricVisible) lit=\(dp.lyricButton.lit)")
        dp.lyricButton.performClick(nil)
        ctx.check("歌词键点击-再关窗并熄灭",
                  !main.lyricVisible && !dp.lyricButton.lit,
                  "visible=\(main.lyricVisible) lit=\(dp.lyricButton.lit)")
    }

    // MARK: - 五、进度槽、列表列宽与列表组

    private func checkListAndGroups(_ ctx: SelfTestContext) {
        let p = ctx.player
        let main = ctx.main
        let pv = main.playlistView

        // 进度槽需真实播放一会儿后才能采样（时间已不在面板上单独显示）
        if !p.isPlaying { p.playRowAt(0) }
        _ = ctx.waitUntil(4.0) { main.controlBar.progressValue > 0.02 }
        ctx.check("进度槽随播放更新", main.controlBar.progressValue > 0.02,
                  "progress=\(main.controlBar.progressValue)")

        // 只播镜像里属于本轨的那一段时，列表也要显示本段时长
        let cueTracks = ctx.cueAlbumTracks()
        if cueTracks.count == 3 {
            p.clearPlaylist()
            p.setMode(.listLoop)
            _ = p.addTracks(cueTracks)
            p.playRowAt(1)
            // 列表面板左边有“播放列表”组，表格可视宽度比两列固有宽度之和小，
            // 时长列必须自己算列宽才不会被裁掉
            pv.refresh()
            pv.layoutSubtreeIfNeeded()
            ctx.check("列表-时长列不被面板裁掉", pv.columnsFitInViewport,
                      "view=\(Int(pv.viewportWidth)) bounds=\(Int(pv.bounds.width))")
            ctx.check("列表-分轨行显示本段时长",
                      pv.durationText(row: 1) == TimeFormat.clock(4.4),
                      "text=\(pv.durationText(row: 1) ?? "nil") expect=\(TimeFormat.clock(4.4))")
            // 行数多到需要滚动条时，实体滚动条会占掉一条宽度，
            // 时长列必须跟着裁剪视图重新适配（专辑 9 首正好卡在边界上）
            let filler = (1...24).map {
                Track(url: URL(fileURLWithPath: "/tmp/tt_filler_\($0).mp3"))
            }
            _ = p.addTracks(filler)
            // 滚动条是 tile 阶段才插进来的（晚于本视图 layout），所以要等一轮布局跑完
            _ = ctx.waitUntil(2.0) { pv.durationCellFullyVisible(row: 0) }
            let cellFit = pv.durationCellFullyVisible(row: 0)
            let cols = pv.columnWidths.map { Int($0) }
            let why = pv.durationCellProbeReport
            ctx.check("列表-出滚动条后时长列仍完整",
                      pv.columnsFitInViewport && cellFit,
                      "rows=\(pv.numberOfRows) cols=\(cols) \(why)")
            p.removeTracks(at: IndexSet(integersIn: p.playlist.count - filler.count..<p.playlist.count))
            p.stop()
        }

        // 列表组：点名字得真的换内容（这之前点了只重画一下，什么都不发生）
        p.clearPlaylist()
        _ = p.addFiles(ctx.libraryURLs)
        p.playRowAt(0)
        _ = ctx.waitUntil(4.0) { p.isPlaying && p.currentTime > 0.2 }
        let defaultCount = p.playlist.count
        let current = p.playlist.currentTrack
        ctx.check("列表组-开播就进最近播放",
                  current != nil
                    && p.groups.recentKeys.first == current?.identityKey,
                  "recent=\(p.groups.recentKeys.count) 首")
        // 空组也要点得动：切过去得在表中央给一句“这里会有什么”。
        // 上一轮自检会把收藏写进 testlib/state.json 并在启动时还原，
        // 所以这里先清空，不依赖上一轮留下的状态
        p.groups.clear(.favorites)
        main.playlistPanel.clickGroup(.favorites)
        ctx.check("列表组-空的收藏页给提示",
                  p.playlist.isEmpty && main.playlistPanel.showsEmptyHint,
                  "empty=\(main.playlistPanel.showsEmptyHint) list=\(p.playlist.count) "
                    + "fav=\(p.groups.favoriteKeys.count)")
        ctx.snapshot(main.playlistPanel.window, named: "shot_group_empty")
        main.playlistPanel.clickGroup(.main)
        if let current { p.toggleFavorite(current) }
        // 走真实点击链路：mouseDown → onClick → 面板 selectGroup
        main.playlistPanel.clickGroup(.favorites)
        ctx.check("列表组-单击我的收藏就切过去",
                  p.activeGroup == .favorites
                    && main.playlistPanel.selectedGroup == .favorites,
                  "group=\(p.activeGroup) list=\(p.playlist.count)")
        ctx.check("列表组-我的收藏显示出收藏曲",
                  p.playlist.count == 1
                    && p.playlist.currentTrack?.identityKey == current?.identityKey,
                  "list=\(p.playlist.count) fav=\(p.groups.favoriteKeys.count) "
                    + "key=\(current?.identityKey ?? "nil")")
        ctx.snapshot(main.playlistPanel.window, named: "shot_group_favorites")
        main.playlistPanel.clickGroup(.recent)
        ctx.check("列表组-单击最近播放就切过去",
                  p.activeGroup == .recent
                    && p.playlist.currentTrack?.identityKey == current?.identityKey,
                  "group=\(p.activeGroup) list=\(p.playlist.count)")
        // 派生组里删除 = 移出收藏/历史，不能顺手把 [默认] 的列表删了
        main.playlistPanel.clickGroup(.favorites)
        p.removeTracks(at: IndexSet(integer: 0))
        ctx.check("列表组-收藏里删除只动收藏",
                  p.groups.favoriteKeys.isEmpty && p.playlist.isEmpty,
                  "fav=\(p.groups.favoriteKeys.count) list=\(p.playlist.count)")
        main.playlistPanel.clickGroup(.main)
        ctx.check("列表组-切回默认内容不丢",
                  p.activeGroup == .main && p.playlist.count == defaultCount,
                  "list=\(p.playlist.count) 应=\(defaultCount)")
        // 停在派生组时存档不能拿派生组的内容覆盖 [默认] 列表
        if let current { p.toggleFavorite(current) }
        main.playlistPanel.clickGroup(.favorites)
        p.persistNow()
        let saved = LibraryStore.load()
        ctx.check("列表组-存档只写默认组",
                  saved.trackPaths.count == defaultCount
                    && saved.favoriteKeys.count == 1
                    && !saved.recentKeys.isEmpty,
                  "paths=\(saved.trackPaths.count) 应=\(defaultCount) "
                    + "fav=\(saved.favoriteKeys.count) recent=\(saved.recentKeys.count)")
        main.playlistPanel.clickGroup(.main)
        ctx.check("列表组-回到默认后右键收藏还在",
                  p.groups.favoriteKeys.count == 1)
    }
}
