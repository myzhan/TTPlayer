import Foundation

/// 全局事件（基于 NotificationCenter，统一命名）
extension NSNotification.Name {
    /// userInfo: ["track": Track?]  当前曲目发生变化（含 nil，表示停止）
    static let ttTrackChanged = NSNotification.Name("TTTrackChanged")
    /// userInfo: ["isPlaying": Bool]
    static let ttPlaybackStateChanged = NSNotification.Name("TTPlaybackStateChanged")
    /// userInfo: ["time": Double, "duration": Double]
    static let ttTimeUpdated = NSNotification.Name("TTTimeUpdated")
    /// 用户拖动进度条，object: Double 秒
    static let ttSeekRequested = NSNotification.Name("TTSeekRequested")
    /// userInfo: ["mode": PlayMode.rawValue]
    static let ttPlayModeChanged = NSNotification.Name("TTPlayModeChanged")
    /// userInfo: ["volume": Float, "muted": Bool]
    static let ttVolumeChanged = NSNotification.Name("TTVolumeChanged")
    /// 播放列表内容发生变化
    static let ttPlaylistChanged = NSNotification.Name("TTPlaylistChanged")
    /// 待播队列发生变化（排队、移除、重排、清空、当前条目前进）
    static let ttQueueChanged = NSNotification.Name("TTQueueChanged")
    /// 自建歌单变了（新建/改名/删除，或某一张的条目与次序）：左栏那一列与存档要跟上
    static let ttUserListsChanged = NSNotification.Name("TTUserListsChanged")
    /// 歌词行变化，userInfo: ["line": String, "next": String, "start": Double, "end": Double]
    static let ttLyricChanged = NSNotification.Name("TTLyricChanged")
    /// 电台状态或「正在播」变化，userInfo: ["state": String, "title": String]
    static let ttRadioChanged = NSNotification.Name("TTRadioChanged")
    /// 输出设备变化（用户切换、设备拔出/接回、系统默认换了），userInfo: ["summary": String]
    static let ttOutputChanged = NSNotification.Name("TTOutputChanged")
    /// 媒体库扫描状态变化（开始/进度/完成/取消），userInfo: ["note": String] 给界面的一句话
    static let ttLibraryChanged = NSNotification.Name("TTLibraryChanged")
    /// 媒体库条目变了（新增/修改/失效/恢复/摘掉），userInfo: ["changed": [String], "removed": [String]]
    /// 只说库，不说列表：歌单与待播队列要不要跟着变由各自的档案决定
    static let ttLibraryEntriesChanged = NSNotification.Name("TTLibraryEntriesChanged")
    /// 睡眠定时器状态变了（设档/取消/心跳走了一格/到点停止），userInfo: ["summary": String]
    static let ttSleepChanged = NSNotification.Name("TTSleepChanged")
    /// 电台台名/分类/归属变了（起改名、建/改/删分类、移入分类、改地址）：
    /// 电台那几页都是 [默认] 里地址的投影，左栏那一列与当前页要跟着重排（F11）
    static let ttRadioStationsChanged = NSNotification.Name("TTRadioStationsChanged")
}

enum TimeFormat {
    /// 0:00:00 / mm:ss 风格
    static func clock(_ seconds: Double) -> String {
        if !seconds.isFinite || seconds < 0 { return "00:00" }
        let total = Int(seconds.rounded(.towardZero))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
