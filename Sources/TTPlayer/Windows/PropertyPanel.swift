import AppKit

/// 曲目“属性”对话框（复刻千千静听的媒体文件信息窗）
enum PropertyPanel {
    static func show(for track: Track, over parent: NSWindow?) {
        let alert = NSAlert()
        // 图标位放当前曲封面（CoverArt 已经降到 ≤256，这里只占 ~64pt，
        // 挑的就是它自带的小档，不会为弹个属性窗再解一次图）
        if let cover = track.cover { alert.icon = cover }
        // 电台没有艺术家：只写台名，别留一个空荡荡的“ - ”
        alert.messageText = track.artist.isEmpty ? track.title : "\(track.artist) - \(track.title)"
        var lines = track.propertyLines
        // 无缝与响度均衡这类「播放期才生效」的状态走控制层那一份，
        // 面板本身不拼字符串（不然自检验了数据源、界面却在说另一套话）
        lines.append(contentsOf: PlayerController.shared.propertyExtraLines(for: track))
        alert.informativeText = lines
            .map { "\($0.0)：\($0.1)" }
            .joined(separator: "\n")
        alert.addButton(withTitle: "好")
        if let parent {
            alert.beginSheetModal(for: parent) { _ in }
        } else {
            alert.runModal()
        }
    }
}
