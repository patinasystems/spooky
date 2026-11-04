import AppKit
import Testing
@testable import Ghostty

@MainActor
struct CommandInputShortcutTests {
    @Test func deliberateReturnDoesNotOverrideOrdinaryTerminalEditingOrGhosttyDefaults() throws {
        for code: UInt16 in [36, 76] {
            #expect(try accepts(event(code: code, modifiers: [.command, .option])))
        }
        for flags: NSEvent.ModifierFlags in [[], .command, .option, [.command, .shift],
                                             [.command, .option, .control], [.command, .option, .shift]] {
            #expect(try !accepts(event(modifiers: flags)))
        }
        #expect(try !accepts(event(code: 0, modifiers: [.command, .option])))
        #expect(try !accepts(event(modifiers: [.command, .option], repeated: true)))
        #expect(try !accepts(event(modifiers: [.command, .option], type: .keyUp)))
    }

    @Test func shortcutCannotReclaimInputFromRunningProgramsIMEOrAnotherResponder() throws {
        let event = try event(modifiers: [.command, .option])
        #expect(!CommandInputShortcut.returnsToEditor(event, promptIsEditable: false,
            windowIsKey: true, terminalOwnsKeyboard: true, hasMarkedText: false))
        #expect(!CommandInputShortcut.returnsToEditor(event, promptIsEditable: true,
            windowIsKey: false, terminalOwnsKeyboard: true, hasMarkedText: false))
        #expect(!CommandInputShortcut.returnsToEditor(event, promptIsEditable: true,
            windowIsKey: true, terminalOwnsKeyboard: false, hasMarkedText: false))
        #expect(!CommandInputShortcut.returnsToEditor(event, promptIsEditable: true,
            windowIsKey: true, terminalOwnsKeyboard: true, hasMarkedText: true))
    }

    private func accepts(_ event: NSEvent) -> Bool {
        CommandInputShortcut.returnsToEditor(event, promptIsEditable: true,
            windowIsKey: true, terminalOwnsKeyboard: true, hasMarkedText: false)
    }

    private func event(code: UInt16 = 36, modifiers: NSEvent.ModifierFlags,
                       repeated: Bool = false, type: NSEvent.EventType = .keyDown) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
            timestamp: 1, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: repeated, keyCode: code))
    }
}
