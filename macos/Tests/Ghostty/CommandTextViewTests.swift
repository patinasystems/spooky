import AppKit
import Testing
@testable import Ghostty

@MainActor
struct CommandTextViewTests {
    @Test func nativeSelectionReplacesTextAcrossLines() {
        let view = CommandTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100), textContainer: nil)
        view.string = "echo 👋\nprintf café\npwd"
        let selection = (view.string as NSString).range(of: "👋\nprintf café")
        view.setSelectedRange(selection)

        view.insertText("hello", replacementRange: view.selectedRange())

        #expect(view.string == "echo hello\npwd")
        #expect(view.selectedRange().length == 0)
    }

    @Test func modifiedReturnInsertsNewlineWithoutSubmitting() throws {
        let view = CommandTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100), textContainer: nil)
        view.string = "echo firstecho second"
        view.setSelectedRange(NSRange(location: 10, length: 0))
        var submissions: [String] = []
        view.onSubmit = { submissions.append($0); return true }

        view.keyDown(with: try returnEvent(modifiers: .shift))

        #expect(view.string == "echo first\necho second")
        #expect(submissions.isEmpty)
    }

    @Test func acceptedSubmissionRetainsDraftUntilShellAcknowledges() throws {
        let view = CommandTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100), textContainer: nil)
        view.string = "echo first\necho second"
        var submitted: String?
        view.onSubmit = { submitted = $0; return true }

        view.keyDown(with: try returnEvent())

        #expect(submitted == "echo first\necho second")
        #expect(view.string == submitted)
    }

    @Test func disabledEditorCannotSubmitAgain() throws {
        let view = CommandTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100), textContainer: nil)
        view.string = "echo pending"
        view.isEditable = false
        var submitted = false
        view.onSubmit = { _ in submitted = true; return true }

        view.keyDown(with: try returnEvent())

        #expect(!submitted)
        #expect(view.string == "echo pending")
    }

    @Test func inputMethodReturnDoesNotSubmitTheCommand() throws {
        let view = CommandTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100), textContainer: nil)
        view.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(view.hasMarkedText())
        var submitted = false
        view.onSubmit = { _ in submitted = true; return true }

        view.keyDown(with: try returnEvent())

        #expect(!submitted)
    }

    @Test func draftUndoManagersAreIndependent() throws {
        let first = CommandTextView(frame: .zero, textContainer: nil)
        let second = CommandTextView(frame: .zero, textContainer: nil)
        let firstManager = try #require(first.undoManager)
        let secondManager = try #require(second.undoManager)
        #expect(firstManager !== secondManager)

        // Acknowledging one pane must not clear another pane's edit history.
        secondManager.beginUndoGrouping()
        secondManager.registerUndo(withTarget: second) { $0.string = "restored" }
        secondManager.endUndoGrouping()
        firstManager.removeAllActions()
        secondManager.undo()

        #expect(second.string == "restored")
    }

    @Test func clearedEditorStillFillsAndReceivesClicksInItsViewport() {
        let scrollView = CommandEditorScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
        let view = CommandTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 24), textContainer: nil)
        scrollView.documentView = view
        scrollView.tile()

        view.string = "echo first\necho second"
        view.sizeToFit()
        view.string = ""
        view.sizeToFit()
        scrollView.tile()

        #expect(view.minSize.height == scrollView.contentView.bounds.height)
        #expect(view.frame.height >= scrollView.contentView.bounds.height)
        // A click well below the first line must still reach NSTextView after
        // an acknowledged command has cleared the draft.
        let point = NSPoint(x: 20, y: scrollView.contentView.frame.midY)
        #expect(scrollView.hitTest(point) === view)
    }

    @Test func emptyEditorMeasuresOneLineWithoutReservedBlankSpace() {
        let view = makeSizedEditor(width: 400)
        // A taller viewport must not become the content's desired height.
        view.minSize.height = 180
        view.setFrameSize(NSSize(width: 400, height: 180))

        #expect(view.measuredContentHeight == 24)
        #expect(view.textContainerInset == .zero)
        #expect(view.textContainer?.lineFragmentPadding == 0)
    }

    @Test func trailingNewlineReservesTheEmptyInsertionLine() {
        let view = makeSizedEditor(width: 400)
        view.string = "echo hello"
        let oneLine = view.measuredContentHeight

        view.string = "echo hello\n"

        #expect(oneLine == 24)
        #expect(view.measuredContentHeight >= oneLine * 2)
    }

    @Test func softWrappedInputGrowsAndShrinksWithAvailableWidth() {
        let view = makeSizedEditor(width: 400)
        view.string = String(repeating: "word ", count: 24)
        let wideHeight = view.measuredContentHeight

        view.setFrameSize(NSSize(width: 100, height: 24))
        let narrowHeight = view.measuredContentHeight
        #expect(narrowHeight > wideHeight)

        view.setFrameSize(NSSize(width: 400, height: 24))
        #expect(view.measuredContentHeight == wideHeight)
    }

    @Test func nativeContainerDistinguishesUserEditsFromAcknowledgement() {
        let editor = CommandInputView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        var edits: [String] = []
        editor.onTextChanged = { edits.append($0) }
        editor.setDraft("echo one")
        #expect(edits.isEmpty)

        let range = (editor.textView.string as NSString).range(of: "one")
        editor.textView.setSelectedRange(range)
        editor.textView.insertText("two", replacementRange: range)
        #expect(edits == ["echo two"])

        let selection = editor.textView.selectedRange()
        editor.setDraft("echo two")
        #expect(editor.textView.selectedRange() == selection)
        editor.setDraft("")
        #expect(editor.textView.string.isEmpty)
        #expect(editor.textView.undoManager?.canUndo == false)
        #expect(edits == ["echo two"])
    }

    @Test func validDeferredFocusRequestFocusesTheNativeEditor() async {
        let view = makeSizedEditor(width: 400)
        let window = makeFocusWindow(containing: view)
        defer { window.close() }
        view.focusRequested = true

        await drainMainQueue()

        #expect(window.firstResponder === view)
        #expect(!view.focusRequested)
    }

    @Test func deferredFocusRequestCancelsWhenTheWindowBecomesInactive() async {
        let view = makeSizedEditor(width: 400)
        let window = makeFocusWindow(containing: view)
        defer { window.close() }
        view.focusRequested = true
        window.simulatedKey = false

        await drainMainQueue()

        #expect(window.firstResponder !== view)
        #expect(!view.focusRequested)
        window.simulatedKey = true
        view.applyFocusRequest()
        await drainMainQueue()
        #expect(window.firstResponder !== view)
    }

    @Test func deferredFocusRequestRechecksTheOwningPane() async {
        let view = makeSizedEditor(width: 400)
        let window = makeFocusWindow(containing: view)
        defer { window.close() }
        var ownsFocus = true
        view.canRequestFocus = { ownsFocus }
        view.focusRequested = true
        ownsFocus = false

        await drainMainQueue()

        #expect(window.firstResponder !== view)
        #expect(!view.focusRequested)
    }

    @Test func deferredFocusRequestCannotReplaceANewerResponder() async {
        let view = makeSizedEditor(width: 400)
        let other = makeSizedEditor(width: 400)
        let window = makeFocusWindow(containing: view)
        defer { window.close() }
        window.contentView?.addSubview(other)
        view.focusRequested = true
        #expect(window.makeFirstResponder(other))

        await drainMainQueue()

        #expect(window.firstResponder === other)
        #expect(!view.focusRequested)
    }

    private func makeFocusWindow(containing view: CommandTextView) -> CommandFocusTestWindow {
        // These windows are never ordered onscreen or made key. Override only
        // the queried state so focus races can be tested without using the UI.
        let window = CommandFocusTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView?.addSubview(view)
        return window
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func makeSizedEditor(width: CGFloat) -> CommandTextView {
        let view = CommandTextView(frame: NSRect(x: 0, y: 0, width: width, height: 24), textContainer: nil)
        view.configureAppearance(
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            textColor: .textColor,
            backgroundColor: .textBackgroundColor,
            minimumLineHeight: 24
        )
        return view
    }

    private func returnEvent(modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
    }
}

@MainActor
private final class CommandFocusTestWindow: NSWindow {
    var simulatedKey = true
    override var isKeyWindow: Bool { simulatedKey }
}
