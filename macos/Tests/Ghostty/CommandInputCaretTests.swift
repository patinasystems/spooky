import AppKit
import Testing
@testable import Ghostty

@MainActor
struct CommandInputCaretTests {
    @Test func managedCaretDisablesOnlyTheSystemIndicator() {
        let editor = CommandInputView(frame: NSRect(x: 0, y: 0, width: 640, height: 200))
        #expect(editor.textView.managesInsertionPoint)
        #expect(!editor.textView.shouldDrawInsertionPoint)
        #expect(editor.textView.isSelectable)
        #expect(editor.textView.acceptsCommandEdits)
        // An unattached/inactive editor must not animate or display a caret.
        let caret = CommandInputCaret(editor: editor)
        caret.update(restart: true)
        #expect(caret.layer.isHidden)
    }

    @Test func nativeCaretGeometryTracksMultilineSelectionAndClipping() throws {
        // Never order this fixture on screen or take the user's focus.
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 160),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let editor = CommandInputView(frame: NSRect(x: 0, y: 0, width: 400, height: 160))
        window.contentView = editor
        editor.setDraft("abc\n界\txyz")
        editor.layoutSubtreeIfNeeded()
        let text = editor.textView
        text.layoutManager?.ensureLayout(for: try #require(text.textContainer))
        text.setSelectedRange(NSRange(location: 0, length: 0))
        let first = try #require(CommandInputCaret.frame(textView: text, in: editor))
        text.setSelectedRange(NSRange(location: 4, length: 0))
        let second = try #require(CommandInputCaret.frame(textView: text, in: editor))
        #expect(first.width == 1)
        #expect(second.width == 1)
        #expect(first.height > 0 && second.height > 0)
        #expect(second.minY < first.minY) // The container is not flipped.
        text.setSelectedRange(NSRange(location: 5, length: 0))
        let unicode = try #require(CommandInputCaret.frame(textView: text, in: editor))
        #expect(unicode.minX > second.minX)
        text.setSelectedRange(NSRange(location: 0, length: 3))
        #expect(CommandInputCaret.frame(textView: text, in: editor) == nil)
    }
}
