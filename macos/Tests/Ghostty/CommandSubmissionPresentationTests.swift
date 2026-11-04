import AppKit
import Testing
@testable import Ghostty

struct CommandSubmissionPresentationTests {
    @Test func acknowledgementBeforeParsedBoundaryNeedsNoEcho() {
        var state = CommandSubmissionPresentation()
        let outcome1 = !state.presented(blockID: "1-1", serial: 2)
        #expect(outcome1)
        let outcome2 = !state.begin(blockID: "1-1", now: .now)
        #expect(outcome2)
        #expect(state.blockID == nil)
        let outcome3 = !state.presented(blockID: "older", serial: 1)
        #expect(outcome3)
        let outcome4 = !state.begin(blockID: "1-1", now: .now)
        #expect(outcome4)
    }

    @Test func onlyTheMatchingFreshFrameReleasesTheCurrentEcho() {
        var state = CommandSubmissionPresentation()
        let outcome5 = state.begin(blockID: "1-1", now: .now)
        #expect(outcome5)
        let outcome6 = state.presented(blockID: "1-1", serial: 2)
        #expect(outcome6)
        let outcome7 = state.begin(blockID: "1-2", now: .now)
        #expect(outcome7)
        let outcome8 = !state.presented(blockID: "1-1", serial: 1)
        #expect(outcome8)
        #expect(state.blockID == "1-2")
        let outcome9 = state.presented(blockID: "1-2", serial: 3)
        #expect(outcome9)
        #expect(state.blockID == nil)
    }

    @Test func emptyFrameCannotClearEchoOrAdvanceAcknowledgementCache() {
        var state = CommandSubmissionPresentation()
        let outcome10 = state.begin(blockID: "1-1", now: .now)
        #expect(outcome10)
        let outcome11 = !state.presented(blockID: nil, serial: 10)
        #expect(outcome11)
        let outcome12 = !state.presented(blockID: "", serial: 10)
        #expect(outcome12)
        #expect(state.blockID == "1-1")
        let outcome13 = state.presented(blockID: "1-1", serial: 2)
        #expect(outcome13)
    }

    @Test func deadlineAndCancellationFailOpenWithoutAFrame() {
        var state = CommandSubmissionPresentation()
        let start = ContinuousClock.now
        let outcome14 = state.begin(blockID: "1-1", now: start)
        #expect(outcome14)
        #expect(state.nextCheckDelay(maximum: .milliseconds(250), now: start) == .milliseconds(100))
        #expect(state.nextCheckDelay(maximum: .seconds(2), now: start) == .milliseconds(100))
        let outcome15 = !state.expire(now: start + .milliseconds(99))
        #expect(outcome15)
        #expect(state.nextCheckDelay(maximum: .milliseconds(33), now: start + .milliseconds(99)) == .milliseconds(1))
        let outcome16 = state.expire(now: start + .milliseconds(100))
        #expect(outcome16)
        #expect(state.nextCheckDelay(maximum: .milliseconds(33), now: start + .milliseconds(100)) == .milliseconds(33))
        let outcome17 = !state.expire(now: start + .seconds(1))
        #expect(outcome17)
        let outcome18 = state.begin(blockID: "1-2", now: start)
        #expect(outcome18)
        let outcome19 = state.cancel()
        #expect(outcome19)
        let outcome20 = !state.cancel()
        #expect(outcome20)
    }

    @MainActor
    @Test func multilineEchoDoesNotOwnInputOrChangeTheNextEditableDraft() {
        let editor = CommandInputView(frame: NSRect(x: 6, y: 30, width: 400, height: 60))
        editor.configureAppearance(font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                                   textColor: .white, backgroundColor: .black, minimumLineHeight: 17)
        editor.setDraft("printf first\nprintf second")
        editor.needsLayout = true
        editor.layoutSubtreeIfNeeded()
        let echo = CommandSubmittedEchoView()
        echo.retainPresentation(from: editor, background: .black)
        let retainedFrame = echo.frame
        editor.setDraft("next command")
        editor.setEditable(true)
        editor.frame.origin.y += 60
        #expect(echo.displayedText == "printf first\nprintf second")
        #expect(echo.frame == retainedFrame)
        #expect(editor.textView.string == "next command")
        #expect(editor.textView.isEditable)
        #expect(echo.hitTest(NSPoint(x: 20, y: 40)) == nil)
        #expect(echo.accessibilityChildren()?.isEmpty == true)
        #expect(!echo.isHidden)
        echo.clear()
        #expect(echo.isHidden && echo.displayedText.isEmpty)
        editor.setDraft(String(repeating: "x", count: CommandSubmittedEchoView.maximumBytes + 1))
        #expect(!echo.retainPresentation(from: editor, background: .black))
        #expect(echo.isHidden && echo.displayedText.isEmpty)
        #expect(editor.textView.string.utf8.count == CommandSubmittedEchoView.maximumBytes + 1)
    }
}
