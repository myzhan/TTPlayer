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
    /// 歌词行变化，userInfo: ["line": String, "next": String, "start": Double, "end": Double]
    static let ttLyricChanged = NSNotification.Name("TTLyricChanged")
    /// 电台状态或「正在播」变化，userInfo: ["state": String, "title": String]
    static let ttRadioChanged = NSNotification.Name("TTRadioChanged")
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
