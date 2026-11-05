import Testing
@testable import Ghostty

struct CommandSubmissionPresentationTests {
    @Test func nonemptySubmissionWaitsForItsOwnAttachedCommandFrame() {
        var state = CommandSubmissionPresentation()
        state.begin(blockID: "1-1", empty: false)
        #expect(!state.presented(blockID: nil, serial: 1, readyPromptID: nil))
        #expect(!state.presented(blockID: "older", serial: 2, readyPromptID: nil))
        #expect(state.blockID == "1-1")
        #expect(state.presented(blockID: "1-1", serial: 3, readyPromptID: nil))
        #expect(state.blockID == nil)
    }

    @Test func emptySubmissionKeepsItsCaretUntilTheNextReadyPromptFrame() {
        var state = CommandSubmissionPresentation()
        state.begin(blockID: "1-1", empty: true)
        #expect(!state.presented(blockID: "1-1", serial: 1, readyPromptID: nil))
        #expect(!state.presented(blockID: "1-1", serial: 2, readyPromptID: "1-1"))
        #expect(state.blockID == "1-1")
        #expect(state.presented(blockID: nil, serial: 3, readyPromptID: "1-2"))
        #expect(state.blockID == nil)
    }

    @Test func aFastNextPromptCanCommitWithoutAnIntermediateCFrame() {
        var state = CommandSubmissionPresentation()
        state.begin(blockID: "1-1", empty: false)
        #expect(state.presented(blockID: "1-1", serial: 5, readyPromptID: "1-2"))
        state.begin(blockID: "1-2", empty: false)
        #expect(!state.presented(blockID: "1-2", serial: 4, readyPromptID: "1-3"))
        #expect(state.blockID == "1-2")
        #expect(state.presented(blockID: "1-2", serial: 6, readyPromptID: nil))
    }

    @Test func cancellationCannotReleaseAReplacementSubmission() {
        var state = CommandSubmissionPresentation()
        state.begin(blockID: "1-1", empty: false)
        #expect(state.cancel())
        #expect(!state.cancel())
        state.begin(blockID: "1-2", empty: false)
        #expect(!state.presented(blockID: "1-1", serial: 10, readyPromptID: nil))
        #expect(state.blockID == "1-2")
    }
}
