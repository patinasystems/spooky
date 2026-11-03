import Testing
@testable import Ghostty

struct CommandSubmissionGateTests {
    @Test func emptySubmissionBeginsImmediatelyBeforeTriggerAndKeepsGateOnSuccess() {
        var calls: [String] = []
        #expect(CommandSubmissionGate.dispatch(text: "", begin: { calls.append("begin"); return true },
            cancel: { calls.append("cancel") }, trigger: { calls.append("trigger"); return true }))
        #expect(calls == ["begin", "trigger"])
    }

    @Test func declinedAdmissionAndNonemptyCommandsStillSubmitNormally() {
        for text in ["", " ", "echo hello", "\n"] {
            var calls: [String] = []
            #expect(CommandSubmissionGate.dispatch(text: text, begin: { calls.append("begin"); return false },
                cancel: { calls.append("cancel") }, trigger: { calls.append("trigger"); return true }))
            #expect(calls == (text.isEmpty ? ["begin", "trigger"] : ["trigger"]))
        }
    }

    @Test func failedTriggerCancelsThePresentationGate() {
        var calls: [String] = []
        #expect(!CommandSubmissionGate.dispatch(text: "", begin: { calls.append("begin"); return true },
            cancel: { calls.append("cancel") }, trigger: { calls.append("trigger"); return false }))
        #expect(calls == ["begin", "trigger", "cancel"])
    }
}
