import Foundation

/// 播放器内的显示名称覆盖；不改写用户媒体文件。
struct TrackEdit: Codable {
    var title: String
    var artist: String
}

enum TrackEdits {
    private static let lock = NSLock()
    private static var edits: [String: TrackEdit] = [:]
    static var snapshot: [String: TrackEdit] {
        lock.lock(); defer { lock.unlock() }
        return edits
    }
    static func restore(_ values: [String: TrackEdit]) {
        lock.lock(); edits = values; lock.unlock()
    }
    static func set(_ edit: TrackEdit, for key: String) {
        lock.lock(); edits[key] = edit; lock.unlock()
    }
    static func apply(to track: Track) {
        lock.lock(); let edit = edits[track.identityKey]; lock.unlock()
        guard let edit else { return }
        track.title = edit.title
        track.artist = edit.artist
    }
    static func replaceKeys(_ mapping: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        let before = edits
        for old in mapping.keys { edits.removeValue(forKey: old) }
        for (old, new) in mapping { if let edit = before[old] { edits[new] = edit } }
    }
}
