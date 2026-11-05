import Testing
@testable import Ghostty

struct CommandSubmissionPresentationTests {
    @Test func nonemptySubmissionWaitsForItsOwnAttachedCommandFrame() {
        var state = CommandSubmissionPresentation()
        state.begin(blockID: "1-1", empty: false)
        let outcome1 = state.presented(blockID: nil, serial: 1, readyPromptID: nil)
        #expect(!outcome1)
        let outcome2 = state.presented(blockID: "older", serial: 2, readyPromptID: nil)
        #expect(!outcome2)
        #expect(state.blockID == "1-1")
        let outcome3 = state.presented(blockID: "1-1", serial: 3, readyPromptID: nil)
        #expect(outcome3)
        #expect(state.blockID == nil)
    }

    @Test func emptySubmissionKeepsItsCaretUntilTheNextReadyPromptFrame() {
        var state = CommandSubmissionPresentation()
        state.begin(blockID: "1-1", empty: true)
        let outcome4 = state.presented(blockID: "1-1", serial: 1, readyPromptID: nil)
        #expect(!outcome4)
        let outcome5 = state.presented(blockID: "1-1", serial: 2, readyPromptID: "1-1")
        #expect(!outcome5)
        #expect(state.blockID == "1-1")
        let outcome6 = state.presented(blockID: nil, serial: 3, readyPromptID: "1-2")
        #expect(outcome6)
        #expect(state.blockID == nil)
    }

    @Test func aFastNextPromptCanCommitWithoutAnIntermediateCFrame() {
        var state = CommandSubmissionPresentation()
        state.begin(blockID: "1-1", empty: false)
        let outcome7 = state.presented(blockID: "1-1", serial: 5, readyPromptID: "1-2")
        #expect(outcome7)
        state.begin(blockID: "1-2", empty: false)
        let outcome8 = state.presented(blockID: "1-2", serial: 4, readyPromptID: "1-3")
        #expect(!outcome8)
        #expect(state.blockID == "1-2")
        let outcome9 = state.presented(blockID: "1-2", serial: 6, readyPromptID: nil)
        #expect(outcome9)
    }

    @Test func cancellationCannotReleaseAReplacementSubmission() {
        var state = CommandSubmissionPresentation()
        state.begin(blockID: "1-1", empty: false)
        let outcome10 = state.cancel()
        #expect(outcome10)
        let outcome11 = state.cancel()
        #expect(!outcome11)
        state.begin(blockID: "1-2", empty: false)
        let outcome12 = state.presented(blockID: "1-1", serial: 10, readyPromptID: nil)
        #expect(!outcome12)
        #expect(state.blockID == "1-2")
    }
}
