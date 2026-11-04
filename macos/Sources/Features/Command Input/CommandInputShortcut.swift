import AppKit

/// Deliberately return from shell editing without making ordinary terminal keys
/// change input modes. Ghostty's configured bindings take precedence at the caller.
@MainActor
enum CommandInputShortcut {
    static func returnsToEditor(_ event: NSEvent, promptIsEditable: Bool, windowIsKey: Bool,
                                terminalOwnsKeyboard: Bool, hasMarkedText: Bool) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        return promptIsEditable && windowIsKey && terminalOwnsKeyboard && !hasMarkedText
            && event.type == .keyDown && !event.isARepeat && (event.keyCode == 36 || event.keyCode == 76)
            && modifiers == [.command, .option]
    }
}
