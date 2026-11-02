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
        let view = CommandTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 76), textContainer: nil)
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
