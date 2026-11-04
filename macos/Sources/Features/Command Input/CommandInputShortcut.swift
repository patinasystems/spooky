import AppKit

/// Deliberately return from shell editing without making ordinary terminal keys
/// change input modes. Ghostty's configured bindings take precedence at the caller.
@MainActor
enum CommandInputShortcut {
    /// Clicking transcript text may focus its terminal view. The next ordinary
    /// editing key belongs to the still-active native prompt, not ZLE.
    static func routesToEditor(_ event: NSEvent, promptIsEditable: Bool, windowIsKey: Bool,
                               terminalOwnsKeyboard: Bool, hasMarkedText: Bool) -> Bool {
        guard promptIsEditable, windowIsKey, terminalOwnsKeyboard, !hasMarkedText,
              event.type == .keyDown, event.modifierFlags.isDisjoint(with: [.command, .control]) else { return false }
        if [UInt16(36), 48, 51, 53, 76, 115, 117, 119, 123, 124, 125, 126].contains(event.keyCode) { return true }
        return event.characters?.unicodeScalars.contains { $0.value >= 32 && !(0xF700...0xF8FF).contains($0.value) } == true
    }

    static func returnsToEditor(_ event: NSEvent, promptIsEditable: Bool, windowIsKey: Bool,
                                terminalOwnsKeyboard: Bool, hasMarkedText: Bool) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        return promptIsEditable && windowIsKey && terminalOwnsKeyboard && !hasMarkedText
            && event.type == .keyDown && !event.isARepeat && (event.keyCode == 36 || event.keyCode == 76)
            && modifiers == [.command, .option]
    }
}
