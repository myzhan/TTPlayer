import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainController: MainWindowController!
    private var launched = false
    /// 冷启动带文件时，AppKit 会在 didFinishLaunching 之前送来 open 事件，
    /// 此时窗口还没建好（拿 mainController 会强解包 nil 而 trap），先挂起等启动完成
    private var pendingOpenURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.log("didFinishLaunching pid=\(getpid())")
        NSApp.setActivationPolicy(.regular)
        // Dock 图标：打包后的 .app 带 AppIcon.icns（各档分辨率齐全），直接用系统的；
        // 直接跑 swift build 出来的二进制没有 bundle 图标，用同一份绘制代码兜住。
        // 注意：必须显式赋值——LaunchServices 对重建的同路径 bundle 会缓存旧图标，
        // 不覆盖时 Dock 会给出一块“无图标”的占位方格
        NSApp.applicationIconImage = Self.applicationIcon()
        setupMainMenu()

        // 自检每次从干净存档起跑：上一轮留下的面板开关、窗口位置会让首批可见性断言时灵时不灵
        LibraryStore.resetSelfTestStateIfRequested()
        mainController = MainWindowController()
        installKeyMonitor()
        PlayerController.shared.restoreFromState()
        mainController.showWindow()
        setupStatusItem()
        // 控制中心 / 媒体键：打包后的 .app 才接管（裸二进制不碰用户机器的系统状态）
        NowPlaying.install()
        NowPlaying.update(track: PlayerController.shared.currentTrack,
                          isPlaying: PlayerController.shared.isPlaying,
                          elapsed: PlayerController.shared.currentTime)
        Diagnostics.markReady()
        Diagnostics.log("启动完成，状态栏已就绪（\(Int(Diagnostics.readyMs.rounded())) ms）")
        launched = true
        if !pendingOpenURLs.isEmpty {
            let urls = pendingOpenURLs
            pendingOpenURLs = []
            handleOpen(urls)
        }
        SelfTest.run_ifRequested(main: mainController)
    }

    /// 无边框窗口的键盘事件：拦截功能键与 Cmd 快捷键
    /// （窗口代理留给 MainWindowController，几何记忆需要 windowDidResize/Move 等回调）
    private func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Cmd 组合（非输入框场景）与功能键交给播放器
            if flags.contains(.command), flags.subtracting([.command, .shift]).isEmpty,
               self.mainController.handleKey(event) {
                return nil
            }
            if flags.isDisjoint(with: [.command, .option, .control]),
               self.mainController.handleKey(event) {
                return nil
            }
            return event
        }
    }

    // MARK: - 菜单栏（保证 Cmd+Q / 编辑菜单可用）

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = mainMenu.addItem(withTitle: "千千静听", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于千千静听",
                        action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出千千静听",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = mainMenu.addItem(withTitle: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu()
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    /// bundle 里的 AppIcon.icns 优先（多分辨率），取不到就现场画一张
    static func applicationIcon() -> NSImage {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url), !img.representations.isEmpty {
            return img
        }
        return AppIcon.image(side: 256)
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.icon = Self.applicationIcon()
        alert.messageText = "千千静听 复刻版"
        alert.informativeText = """
        使用 Swift + AppKit 原生实现的音乐播放器。
        致敬经典桌面播放器 TTPlayer（千千静听）。

        空格 播放/暂停 · ←/→ 切歌 · F1~F4 播放方式
        M 静音 · L 歌词窗口 · E 均衡器 · ⌘O 添加文件
        """
        alert.runModal()
    }

    // MARK: - 状态栏（关闭主窗口后仍可控制播放）

    /// 常态显示正在播的歌名，鼠标悬停后原地变成上一首 / 播放暂停 / 下一首
    private var statusBar: StatusItemController?

    private func setupStatusItem() {
        let bar = StatusItemController()
        bar.onShowMain = { [weak self] in self?.mainController.showWindow() }
        statusBar = bar
    }

    /// 自检用：状态栏现在显示什么（不参与正常逻辑）
    var statusBarSnapshot: (length: CGFloat, title: String, expanded: Bool)? { statusBar?.snapshot() }
    /// 自检用：常态那颗图标（只能在非悬停态读，悬停时图标会让位给三个键）
    var statusBarIconSnapshot: (width: CGFloat, height: CGFloat, template: Bool)? { statusBar?.iconSnapshot }
    /// 自检用：悬停监听（tracking area）是否已装好
    var statusBarHoverTrackingReady: Bool { statusBar?.hoverTrackingReady ?? false }
    /// 自检用：菜单首行「正在播放：…」
    var statusBarMenuHeader: String? { statusBar?.menuHeaderTitle }
    /// 自检用：模拟鼠标进入/离开状态项
    func statusBarHover(_ inside: Bool) { statusBar?.setHovered(inside) }
    /// 自检用：把悬停条离屏画一张（数像素验证三个键真的画出来了）
    func statusBarHoverShot(playing: Bool) -> (rep: NSBitmapImageRep, points: CGFloat)? {
        statusBar?.hoverShot(playing: playing)
    }

    // MARK: - NSApplicationDelegate

    /// 从 Finder 双击、拖到 Dock 图标或用 `open -a` 送来的音频/分轨表：加入播放列表
    /// （.cue 会按分轨表展开成多首，镜像整盘不会再重复入表）
    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else {
            pendingOpenURLs.append(contentsOf: urls)
            Diagnostics.log("启动前收到 \(urls.count) 个打开请求，等窗口就绪后处理")
            return
        }
        handleOpen(urls)
    }

    private func handleOpen(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let controller = PlayerController.shared
        let added = controller.addFiles(urls, playNow: controller.currentTrack == nil)
        Diagnostics.log("打开 \(urls.count) 个条目，新增 \(added) 首："
            + urls.map { $0.lastPathComponent }.joined(separator: ", "))
        mainController.showWindow()
        if added > 0 {
            if !mainController.listVisible { mainController.setListVisible(true) }
            mainController.playlistView.scrollToCurrent()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && launched { mainController.showWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        PlayerController.shared.persistNow()
        mainController?.persistWindowLayout()
        NowPlaying.clear()
        Diagnostics.log("退出，已持久化播放列表与窗口布局")
    }

    // 主窗口关闭 = 隐藏（由 MainWindowController 的 windowShouldClose 处理）
}
