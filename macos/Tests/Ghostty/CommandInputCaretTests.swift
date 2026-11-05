import AppKit
import Testing
@testable import Ghostty

@MainActor
struct CommandInputCaretTests {
    @Test func presentedPromptRecoversWindowResponderInTheSameTurn() throws {
        // Simulate AppKit's fallback after disabling the old text view without
        // ordering a window or taking the user's actual keyboard focus.
        let window = CaretKeyWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 200),
                                    styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = CommandInputView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = editor
        #expect(window.makeFirstResponder(window))
        editor.requestFocus(token: 1)
        editor.layoutSubtreeIfNeeded()
        editor.completePresentedInput()
        #expect(window.firstResponder === editor.textView)
        #expect(CommandInputCaret.frame(textView: editor.textView, in: editor) != nil)

        // A search field or another pane still owns its own responder.
        let search = NSTextView()
        editor.addSubview(search)
        #expect(window.makeFirstResponder(search))
        editor.canRequestFocus = { false }
        editor.requestFocus(token: 2)
        editor.completePresentedInput()
        #expect(window.firstResponder === search)
    }

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

    @Test func caretLayerTracksScrollingAndHidesOutsideTheViewport() throws {
        // Model a visible editor without ordering a window on the user's desktop.
        let window = VisibleCaretKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = CommandInputView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = editor
        editor.configureAppearance(font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                                   textColor: .white, backgroundColor: .black, minimumLineHeight: 18)
        editor.setDraft(String(repeating: "line\n", count: 80))
        editor.layout()
        #expect(window.makeFirstResponder(editor.textView))
        editor.textView.setSelectedRange(NSRange(location: 40, length: 0))
        let clip = editor.scrollView.contentView
        let origin = editor.textView.frame.minY
        clip.scroll(to: NSPoint(x: 0, y: origin))
        let caret = try #require(editor.layer?.sublayers?.first { $0.zPosition == 1 })
        let initial = caret.frame
        #expect(!caret.isHidden)

        clip.scroll(to: NSPoint(x: 0, y: origin + 18))
        let expected = try #require(CommandInputCaret.frame(textView: editor.textView, in: editor))
        #expect(caret.frame == expected)
        #expect(abs(caret.frame.minY - initial.minY - 18) < 0.5)
        #expect(!caret.isHidden)
        clip.scroll(to: NSPoint(x: 0, y: origin + editor.scrollView.overflow))
        #expect(caret.isHidden)
        clip.scroll(to: NSPoint(x: 0, y: origin))
        #expect(!caret.isHidden)
        #expect(caret.frame == initial)
    }
}

@MainActor
private final class CaretKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor
private final class VisibleCaretKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var occlusionState: NSWindow.OcclusionState { [.visible] }
}
