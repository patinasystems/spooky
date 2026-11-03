import AppKit
import Testing
@testable import Ghostty

@MainActor
struct SurfaceSearchOverlayTests {
    @Test func returnNavigatesAndEscapeClosesWithoutChangingTheNeedle() {
        let bar = SurfaceSearchBar()
        bar.update(needle: .init(text: "find me", selection: nil), selected: 0, total: 3)
        var next = 0
        var previous = 0
        var closed = 0
        bar.onNext = { next += 1 }
        bar.onPrevious = { previous += 1 }
        bar.onEscape = { closed += 1 }

        #expect(bar.handleCommand(#selector(NSResponder.insertNewline(_:)), modifiers: []))
        #expect(bar.handleCommand(#selector(NSResponder.insertNewline(_:)), modifiers: .shift))
        #expect(bar.handleCommand(#selector(NSResponder.insertLineBreak(_:)), modifiers: .shift))
        #expect(bar.handleCommand(#selector(NSResponder.cancelOperation(_:)), modifiers: []))
        #expect(!bar.handleCommand(#selector(NSResponder.moveLeft(_:)), modifiers: []))
        #expect(next == 1)
        #expect(previous == 2)
        #expect(closed == 1)
        #expect(bar.field.stringValue == "find me")
    }

    @Test func inputPublishesExactUnicodeNeedleAndUTF16Selection() {
        let bar = SurfaceSearchBar()
        let text = "café 👻"
        var publishedText = ""
        var publishedRange = NSRange()
        bar.onChange = { publishedText = $0; publishedRange = $1 }
        bar.field.stringValue = text

        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.field))

        #expect(publishedText == text)
        #expect(publishedRange == NSRange(location: text.utf16.count, length: 0))
    }

    @Test func inputMethodCommitDoesNotNavigateSearch() {
        let bar = SurfaceSearchBar()
        let editor = NSTextView(frame: .zero)
        editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        var navigated = false
        bar.onNext = { navigated = true }
        #expect(!bar.control(bar.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(!navigated)
    }

    @Test func resultUpdatesPreserveTheActiveUnicodeSelection() throws {
        let bar = SurfaceSearchBar()
        let window = testWindow(content: bar)
        defer { window.close() }
        let text = "café 👻 search"
        let emoji = (text as NSString).range(of: "👻")
        let selected = try #require(Range(emoji, in: text))
        let needle = Ghostty.OSSurfaceView.SearchState.Needle(text: text, selection: selected)
        bar.update(needle: needle, selected: nil, total: nil)
        #expect(window.makeFirstResponder(bar.field))
        bar.selectNeedle()
        let editor = try #require(bar.field.currentEditor() as? NSTextView)
        #expect(editor.selectedRange() == emoji)

        // Streaming match counts must not reselect the original needle or move
        // the insertion point while the user edits inside the field.
        let insertion = NSRange(location: text.utf16.count, length: 0)
        editor.setSelectedRange(insertion)
        bar.update(needle: needle, selected: 2, total: 10)
        #expect(editor.selectedRange() == insertion)
        #expect(bar.count.stringValue == "3/10")
        bar.update(needle: needle, selected: 0, total: nil)
        #expect(bar.count.stringValue == "1/?")
        bar.update(needle: needle, selected: nil, total: 0)
        #expect(bar.count.stringValue == "–/0")
    }

    @Test func focusOwnershipStopsWhenAnotherControlTakesFocus() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 120))
        let bar = SurfaceSearchBar()
        bar.frame = NSRect(x: 0, y: 0, width: 370, height: 42)
        let otherField = NSTextField(frame: NSRect(x: 0, y: 60, width: 200, height: 24))
        container.addSubview(bar)
        container.addSubview(otherField)
        let window = testWindow(content: container)
        defer { window.close() }
        var focusNotifications = 0
        bar.onFocus = { focusNotifications += 1 }

        #expect(window.makeFirstResponder(bar.field))
        #expect(bar.ownsFocus(in: window))
        // Ownership is published on focus, before a first Paste keystroke can
        // be intercepted by the terminal sibling's key-equivalent handler.
        #expect(focusNotifications > 0)
        #expect(window.makeFirstResponder(otherField))
        #expect(!bar.ownsFocus(in: window))
    }

    @Test func nativeEditingShortcutsReplaceUnicodeAndUndoWithinSearch() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let field = SurfaceSearchField(pasteboard: pasteboard)
        field.stringValue = "original"
        let window = testWindow(content: field)
        defer { window.close() }
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(editor.allowsUndo)
        pasteboard.setString("café 👻", forType: .string)

        #expect(field.performKeyEquivalent(with: try shortcut("a")))
        #expect(editor.selectedRange() == NSRange(location: 0, length: "original".utf16.count))
        let undo = try #require(field.undoManager)
        undo.beginUndoGrouping()
        #expect(field.performKeyEquivalent(with: try shortcut("v")))
        undo.endUndoGrouping()
        #expect(editor.string == "café 👻")
        #expect(field.stringValue == "café 👻")
        #expect(field.performKeyEquivalent(with: try shortcut("z")))
        #expect(editor.string == "original")
        #expect(field.performKeyEquivalent(with: try shortcut("z", modifiers: [.command, .shift])))
        #expect(editor.string == "café 👻")

        #expect(field.performKeyEquivalent(with: try shortcut("a")))
        pasteboard.clearContents()
        pasteboard.setString("unrelated clipboard contents", forType: .string)
        #expect(field.performKeyEquivalent(with: try shortcut("c")))
        #expect(pasteboard.string(forType: .string) == "café 👻")
        #expect(editor.selectedRange() == NSRange(location: 0, length: "café 👻".utf16.count))
        #expect(field.performKeyEquivalent(with: try shortcut("x")))
        #expect(editor.string.isEmpty)
        #expect(pasteboard.string(forType: .string) == "café 👻")
        #expect(field.performKeyEquivalent(with: try shortcut("v")))
        #expect(editor.string == "café 👻")
    }

    @Test func inactiveSearchFieldCannotConsumeAnotherFieldsEditingShortcut() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 120))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let field = SurfaceSearchField(pasteboard: pasteboard)
        let other = NSTextField(frame: NSRect(x: 0, y: 60, width: 200, height: 24))
        field.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        container.addSubview(field)
        container.addSubview(other)
        let window = testWindow(content: container)
        defer { window.close() }
        #expect(window.makeFirstResponder(other))
        #expect(!field.performKeyEquivalent(with: try shortcut("v")))
    }

    private func shortcut(_ key: String, modifiers: NSEvent.ModifierFlags = .command) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: 0, windowNumber: 0, context: nil, characters: key,
                                      charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0))
    }

    private func testWindow(content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 120),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        return window
    }
}
