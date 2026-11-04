import AppKit
import Testing
@testable import Ghostty

@MainActor
struct NativeCommandFocusTests {
    @Test func recoveryLeavesSearchAndOtherPaneRespondersAlone() {
        let window = NSWindow()
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let surface = NSView()
        let editor = NSTextView()
        let responders: [NSResponder?] = [nil, window, surface, editor]
        for responder in responders {
            #expect(NativeCommandFocus.canRestoreEditor(firstResponder: responder,
                window: window, surface: surface, editor: editor))
        }
        #expect(!NativeCommandFocus.canRestoreEditor(firstResponder: NSTextView(),
            window: window, surface: surface, editor: editor))
        #expect(!NativeCommandFocus.canRestoreEditor(firstResponder: NSButton(),
            window: window, surface: surface, editor: editor))
    }

    @Test func nativeEditorOwnsItsSelectedActivePane() {
        let surface = NSView()
        let editor = NSTextView()
        #expect(NativeCommandFocus.isFocused(windowIsKey: true, paneIsSelected: true,
            firstResponder: editor, surface: surface, editor: editor))
        #expect(NativeCommandFocus.isFocused(windowIsKey: true, paneIsSelected: true,
            firstResponder: surface, surface: surface, editor: editor))
    }

    @Test func otherPanesInactiveWindowsAndModalRespondersDoNotOwnPaneFocus() {
        let surface = NSView()
        let editor = NSTextView()
        let searchFieldEditor = NSTextView()
        for (key, selected, responder) in [(false, true, editor), (true, false, editor),
                                           (true, true, searchFieldEditor)] {
            #expect(!NativeCommandFocus.isFocused(windowIsKey: key, paneIsSelected: selected,
                firstResponder: responder, surface: surface, editor: editor))
        }
        let hiddenParent = NSView()
        hiddenParent.addSubview(editor)
        hiddenParent.isHidden = true
        #expect(!NativeCommandFocus.isFocused(windowIsKey: true, paneIsSelected: true,
            firstResponder: editor, surface: surface, editor: editor))
    }

    @Test func nativeShortcutDispatchDoesNotEnterTheFocusedTerminalSibling() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = content
        let terminal = TerminalKeyboardProbe(frame: content.bounds)
        let editor = CommandTextView(frame: content.bounds, textContainer: nil)
        // Match the host's order: AppKit can offer the terminal sibling first.
        content.addSubview(terminal)
        content.addSubview(editor)
        #expect(window.makeFirstResponder(editor))
        #expect(NativeCommandFocus.isFocused(windowIsKey: true, paneIsSelected: true,
            firstResponder: window.firstResponder, surface: terminal, editor: editor))

        var findCount = 0
        var submitCount = 0
        editor.onFind = { findCount += 1; return true }
        editor.onSubmit = { _ in submitCount += 1; return true }
        let text = "# first\n# second\n# third"
        let pasteboard = NSPasteboard.general
        // Synchronous MainActor scope restores every available clipboard type.
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer { pasteboard.clearContents(); pasteboard.writeObjects(saved) }
        pasteboard.clearContents()
        #expect(pasteboard.setString(text, forType: .string))

        for (characters, code) in [("v", UInt16(9)), ("a", UInt16(0)), ("f", UInt16(3))] {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 1, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code))
            #expect(content.performKeyEquivalent(with: event))
        }
        #expect(editor.string == text)
        #expect(editor.selectedRange() == NSRange(location: 0, length: (text as NSString).length))
        #expect(findCount == 1)
        #expect(submitCount == 0)
        #expect(terminal.offered == 3)
        #expect(terminal.consumed == 0)
        #expect(window.firstResponder === editor)

        #expect(!NativeCommandFocus.ownsTerminalKeyboard(
            paneIsFocused: true, firstResponder: window.firstResponder, surface: terminal))
        #expect(window.makeFirstResponder(terminal))
        #expect(NativeCommandFocus.ownsTerminalKeyboard(
            paneIsFocused: true, firstResponder: window.firstResponder, surface: terminal))
        #expect(!NativeCommandFocus.ownsTerminalKeyboard(
            paneIsFocused: false, firstResponder: window.firstResponder, surface: terminal))
    }
}

@MainActor
private final class TerminalKeyboardProbe: NSView {
    var offered = 0
    var consumed = 0
    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        offered += 1
        // This is the production gate used before terminal binding lookup and
        // command-key release forwarding. The pane intentionally stays focused.
        guard NativeCommandFocus.ownsTerminalKeyboard(
            paneIsFocused: true, firstResponder: window?.firstResponder, surface: self
        ) else { return false }
        consumed += 1
        return true
    }
}
