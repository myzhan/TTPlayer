import AppKit

/// 本地事件监听器与回归共用的快捷键入口规则。
enum PlayerShortcuts {
    static func accepts(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return !flags.contains(.control) && !(flags.contains(.command) && flags.contains(.option))
    }

    static func opensFolder(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains([.command, .shift])
            && event.charactersIgnoringModifiers?.lowercased() == "o"
    }
}
