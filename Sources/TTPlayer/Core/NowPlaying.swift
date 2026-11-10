import AppKit
import Foundation
import MediaPlayer

/// 系统级「正在播放」桥（FR-SYS-07）：控制中心 / 锁屏那一栏，以及键盘媒体键
///
/// 两条通路各管一头：
/// 1. 我们 → 系统：把曲目与播放状态写进 `MPNowPlayingInfoCenter`
/// 2. 系统 → 我们：`MPRemoteCommandCenter` 的播放/暂停/上一首/下一首/拖动，转成对 PlayerController 的调用
///
/// 只在打包成 .app 后生效：媒体键路由挂在 bundle 上，直接跑 `swift build` 出来的裸二进制
/// 既没有 bundleIdentifier 也不该去改用户机器的控制中心（自检就是这种情形）。
///
/// 字段映射写成纯函数 `info(for:isPlaying:elapsed:)`，自检不去碰系统 API 也能验它。
enum NowPlaying {
    /// 媒体键/控制中心是否可用（裸二进制没有 bundleIdentifier，一律不接管）
    private static var available: Bool {
        Bundle.main.bundleIdentifier != nil
            && ProcessInfo.processInfo.environment["TTPLAYER_SELFTEST"] == nil
    }

    /// 字段映射：曲目 + 播放状态 + 当前进度 → 系统那套键值
    ///
    /// 进度只在这里给「快照 + 速率」，往前推由系统自己做（不按 0.25s 重写，
    /// 那是每秒四次无意义的跨进程写）；所以 seek / 切歌 / 播停时都必须再调一次。
    static func info(for track: Track, isPlaying: Bool, elapsed: Double) -> [String: Any] {
        let duration = max(0, track.duration)
        var info: [String: Any] = [
            // 没有标签的曲子显示文件名，不能给个空标题
            MPMediaItemPropertyTitle: track.title.isEmpty ? track.fileName : track.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: min(max(0, elapsed), duration),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        // 空串不写：控制中心会把空字段画成一条空白，比不写更难看
        if !track.artist.isEmpty { info[MPMediaItemPropertyArtist] = track.artist }
        if !track.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = track.album }
        return info
    }

    // MARK: - 我们 → 系统

    /// 上一次推送的键（曲目 + 播/停）：只为了不重复写日志，不参与逻辑
    private static var lastPushed = ""

    /// 把当前曲目/状态推给系统；没有曲目时清空那一栏
    static func update(track: Track?, isPlaying: Bool, elapsed: Double) {
        guard available else { return }
        let center = MPNowPlayingInfoCenter.default()
        guard let track else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info = info(for: track, isPlaying: isPlaying, elapsed: elapsed)
        if let cover = track.cover {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: cover.size) { _ in cover }
        }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
        // 留一行足迹：出问题时能判断“到底推没推给系统”（拖动进度条不算状态变化，不重复写）
        let key = "\(track.url.path)|\(isPlaying)"
        if key != lastPushed {
            lastPushed = key
            Diagnostics.log("控制中心 ↦ \(isPlaying ? "播放" : "暂停") \(info[MPMediaItemPropertyTitle] ?? "")")
        }
    }

    // MARK: - 系统 → 我们

    private static var installed = false

    /// 接管媒体键与控制中心按钮。重复调用无副作用
    static func install() {
        guard available, !installed else { return }
        installed = true
        Diagnostics.log("控制中心已接管：播放/暂停/上下一首/拖动进度")
        let center = MPRemoteCommandCenter.shared()

        // 事件可能从非主线程送来，统一转回主线程：播放链路只认主线程
        func handle(_ action: @escaping (PlayerController) -> Void) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
            { _ in
                DispatchQueue.main.async { action(PlayerController.shared) }
                return .success
            }
        }

        center.playCommand.addTarget(handler: handle { $0.togglePlay() })
        center.pauseCommand.addTarget(handler: handle {
            if $0.isPlaying { $0.togglePlay() }
        })
        center.togglePlayPauseCommand.addTarget(handler: handle { $0.togglePlay() })
        center.nextTrackCommand.addTarget(handler: handle { $0.next() })
        center.previousTrackCommand.addTarget(handler: handle { $0.previous() })
        center.changePlaybackPositionCommand.addTarget { event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            DispatchQueue.main.async { PlayerController.shared.seek(to: e.positionTime) }
            return .success
        }
    }

    /// 退出前清掉，免得控制中心留着一首早就不放的歌
    static func clear() {
        guard available else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}
