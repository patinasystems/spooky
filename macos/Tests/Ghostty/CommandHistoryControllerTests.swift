import AppKit
import Testing
@testable import Ghostty

@MainActor
struct CommandHistoryControllerTests {
    @Test func rapidArrowsShareOneRequestAndRestoreOriginalDraftAndCaret() throws {
        let (editor, window) = makeEditor("echo café 👋")
        defer { window.close() }
        editor.textView.setSelectedRange(NSRange(location: 5, length: 0))
        var requests: [CommandHistoryRequest] = []
        editor.onRequestHistory = { requests.append($0) }
        try arrow(editor, older: true)
        try arrow(editor, older: true)
        try arrow(editor, older: true)
        try arrow(editor, older: false)
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.text == "echo café 👋")
        #expect(request.cursorUTF16 == 5)
        editor.receiveHistory(response(request, entries: ["newest", "previous", "oldest"]))
        #expect(editor.textView.string == "previous")
        try arrow(editor, older: false)
        #expect(editor.textView.string == "newest")
        try arrow(editor, older: false)
        #expect(editor.textView.string == "echo café 👋")
        #expect(editor.textView.selectedRange() == NSRange(location: 5, length: 0))
        try arrow(editor, older: true)
        #expect(editor.textView.string == "newest")
        #expect(requests.count == 1)
    }

    @Test func pendingDownCancelsWithoutReplacingTheDraft() throws {
        let (editor, window) = makeEditor("unfinished")
        defer { window.close() }
        var cancellations = 0
        editor.onCancelHistory = { cancellations += 1 }
        let request = try request(editor)
        try arrow(editor, older: false)
        editor.receiveHistory(response(request, entries: ["old command"]))
        #expect(editor.textView.string == "unfinished")
        #expect(cancellations == 1)
        #expect(!editor.textView.history.isBrowsing)
    }

    @Test func emptyOrUnavailableHistoryLeavesDraftAndAllowsRetry() throws {
        let (editor, window) = makeEditor("draft")
        defer { window.close() }
        let first = try request(editor)
        editor.receiveHistory(.init(requestID: first.id, revision: first.revision,
                                    entries: [], message: "History unavailable"))
        #expect(editor.textView.string == "draft")
        let next = try request(editor)
        #expect(next.id != first.id)
        editor.receiveHistory(response(first, entries: ["stale"]))
        #expect(editor.textView.string == "draft")
        editor.receiveHistory(response(next, entries: ["current"]))
        #expect(editor.textView.string == "current")
    }

    @Test func typingInvalidatesPendingHistoryAndRecalledHistory() throws {
        let (editor, window) = makeEditor("draft")
        defer { window.close() }
        let pending = try request(editor)
        editor.textView.insertText("!", replacementRange: editor.textView.selectedRange())
        editor.receiveHistory(response(pending, entries: ["stale"]))
        #expect(editor.textView.string == "draft!")
        let fresh = try request(editor)
        editor.receiveHistory(response(fresh, entries: ["recalled"]))
        editor.textView.insertText(" edit", replacementRange: editor.textView.selectedRange())
        #expect(!editor.textView.history.isBrowsing)
        let edited = try request(editor)
        #expect(edited.text == "recalled edit")
        editor.receiveHistory(response(edited, entries: ["another"]))
        try arrow(editor, older: false)
        #expect(editor.textView.string == "recalled edit")
    }

    @Test func pendingCaretMoveAndPromptChangeRejectLateResponses() throws {
        let (editor, window) = makeEditor("draft")
        defer { window.close() }
        let moved = try request(editor)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.textView.completionSelectionDidChange()
        editor.receiveHistory(response(moved, entries: ["stale caret"]))
        #expect(editor.textView.string == "draft")
        let oldPrompt = try request(editor)
        editor.setHistoryContext("next-prompt")
        editor.receiveHistory(response(oldPrompt, entries: ["stale prompt"]))
        #expect(editor.textView.string == "draft")
        let next = try request(editor)
        editor.receiveHistory(.init(requestID: next.id, revision: next.revision &+ 1, entries: ["wrong revision"]))
        #expect(editor.textView.string == "draft")
        editor.setHistoryContext(nil)
        editor.receiveHistory(response(next, entries: ["not ready"]))
        #expect(editor.textView.string == "draft")
        #expect(!editor.textView.history.navigate(older: true))
    }

    @Test func inactiveWindowAndMarkedTextRejectPendingResults() throws {
        let (editor, window) = makeEditor("draft")
        defer { window.close() }
        let inactive = try request(editor)
        window.simulatedKey = false
        editor.receiveHistory(response(inactive, entries: ["stale window"]))
        #expect(editor.textView.string == "draft")
        window.simulatedKey = true
        let composing = try request(editor)
        editor.textView.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0),
                                      replacementRange: NSRange(location: NSNotFound, length: 0))
        let markedDraft = editor.textView.string
        editor.receiveHistory(response(composing, entries: ["stale composition"]))
        #expect(editor.textView.string == markedDraft)
        #expect(editor.textView.hasMarkedText())
        #expect(!editor.textView.history.navigate(older: true))
    }

    @Test func duplicateEntriesRemainDistinctAndOldestBoundaryIsStable() throws {
        let (editor, window) = makeEditor("draft")
        defer { window.close() }
        editor.receiveHistory(response(try request(editor), entries: ["same", "same", "oldest"]))
        try arrow(editor, older: true)
        #expect(editor.textView.string == "same")
        try arrow(editor, older: true)
        #expect(editor.textView.string == "oldest")
        var edits = 0
        editor.onTextChanged = { _ in edits += 1 }
        try arrow(editor, older: true)
        #expect(editor.textView.string == "oldest")
        #expect(edits == 0)
        try arrow(editor, older: false)
        #expect(editor.textView.string == "same")
        try arrow(editor, older: false)
        #expect(editor.textView.string == "same")
        try arrow(editor, older: false)
        #expect(editor.textView.string == "draft")
    }

    @Test func responseCapsDoNotExposeEntriesBeyondTheBoundedSnapshot() throws {
        let (editor, window) = makeEditor("draft")
        defer { window.close() }
        let pending = try request(editor)
        for _ in 0..<1_100 { #expect(editor.textView.history.navigate(older: true)) }
        editor.receiveHistory(response(pending, entries: (0..<1_001).map { "command \($0)" }))
        #expect(editor.textView.string == "command 999")
        editor.setHistoryContext("next-prompt")
        editor.setDraft("draft")
        let bounded = try request(editor)
        try arrow(editor, older: true)
        editor.receiveHistory(response(bounded, entries: ["fits", String(repeating: "x", count: 1_048_576), "excluded"]))
        #expect(editor.textView.string == "fits")
        try arrow(editor, older: true)
        #expect(editor.textView.string == "fits")
    }

    @Test func multilineHistoryAllowsNativeLineMovementAndRestoresDraft() throws {
        let (editor, window) = makeEditor("present")
        defer { window.close() }
        editor.receiveHistory(response(try request(editor), entries: ["first\nsecond", "older"]))
        #expect(!editor.textView.history.atVisualBoundary(older: true))
        try arrow(editor, older: true)
        #expect(editor.textView.string == "first\nsecond")
        #expect(editor.textView.history.isBrowsing)
        #expect(editor.textView.history.atVisualBoundary(older: true))
        try arrow(editor, older: true)
        #expect(editor.textView.string == "older")
        try arrow(editor, older: false)
        #expect(editor.textView.string == "first\nsecond")
        try arrow(editor, older: false)
        #expect(editor.textView.string == "present")
    }

    @Test func hardAndSoftWrappedLinesUseActualVisualBoundaries() {
        let (editor, window) = makeEditor("first\nsecond\n", width: 120)
        defer { window.close() }
        let view = editor.textView
        #expect(!view.history.atVisualBoundary(older: true))
        #expect(view.history.atVisualBoundary(older: false))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(view.history.atVisualBoundary(older: true))
        #expect(!view.history.atVisualBoundary(older: false))
        editor.setDraft(String(repeating: "word ", count: 20))
        #expect(!view.history.atVisualBoundary(older: true))
        #expect(view.history.atVisualBoundary(older: false))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(view.history.atVisualBoundary(older: true))
        #expect(!view.history.atVisualBoundary(older: false))
        view.setSelectedRange(NSRange(location: 0, length: 4))
        #expect(!view.history.atVisualBoundary(older: true))
    }

    @Test func visibleCompletionListWinsAndModifiedArrowsDoNotBrowse() throws {
        let (editor, window) = makeEditor("git ch")
        defer { window.close() }
        var histories = 0
        editor.onRequestHistory = { _ in histories += 1 }
        try showCompletions(editor)
        try arrow(editor, older: true)
        #expect(histories == 0)
        #expect(editor.textView.selectedCompletionIndex == 1)
        try arrow(editor, older: false)
        #expect(editor.textView.selectedCompletionIndex == 0)
        try arrow(editor, older: true, modifiers: .shift)
        #expect(editor.textView.selectedCompletionIndex == 0)
        #expect(histories == 0)
        editor.dismissCompletions()
        for modifier: NSEvent.ModifierFlags in [.option, .control, .command, .shift] {
            try arrow(editor, older: true, modifiers: modifier)
        }
        #expect(histories == 0)
    }

    @Test func automaticMenuNavigatesOptionsButDoesNotInterruptHistoryBrowsing() throws {
        let (editor, window) = makeEditor("git c")
        defer { window.close() }
        try showCompletions(editor)
        try arrow(editor, older: false)
        #expect(editor.textView.completions.listVisible)
        editor.dismissCompletions()
        editor.receiveHistory(response(try request(editor), entries: ["git ch"]))
        var automaticRequests = 0
        editor.onRequestCompletion = { _ in automaticRequests += 1 }
        editor.textView.completions.requestAutomaticNow()
        #expect(automaticRequests == 0)
        #expect(editor.textView.completions.inlineSuggestion == nil)
        try arrow(editor, older: false)
        #expect(editor.textView.string == "git c")
        #expect(!editor.textView.completions.listVisible)
    }

    @Test func historyReplacementPublishesDraftWithoutRequestingAutomaticCompletion() async throws {
        let (editor, window) = makeEditor("unfinished")
        defer { window.close() }
        var drafts: [String] = []
        var completions = 0
        editor.onTextChanged = { drafts.append($0) }
        editor.onRequestCompletion = { _ in completions += 1 }
        editor.receiveHistory(response(try request(editor), entries: ["echo recalled"]))
        try await Task.sleep(for: .milliseconds(100))
        #expect(drafts == ["echo recalled"])
        #expect(completions == 0)
        try arrow(editor, older: false)
        #expect(drafts == ["echo recalled", "unfinished"])
    }

    private func makeEditor(_ draft: String, width: CGFloat = 400) -> (CommandInputView, CommandHistoryTestWindow) {
        let editor = CommandInputView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        editor.configureAppearance(font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                                   textColor: .white, backgroundColor: .black, minimumLineHeight: 24)
        let window = CommandHistoryTestWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
                                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: window.contentLayoutRect)
        window.contentView?.addSubview(editor)
        editor.layout()
        editor.setHistoryContext("prompt")
        editor.setDraft(draft)
        #expect(window.makeFirstResponder(editor.textView))
        return (editor, window)
    }

    private func request(_ editor: CommandInputView) throws -> CommandHistoryRequest {
        var value: CommandHistoryRequest?
        editor.onRequestHistory = { value = $0 }
        try arrow(editor, older: true)
        return try #require(value)
    }

    private func response(_ request: CommandHistoryRequest, entries: [String]) -> CommandHistoryResponse {
        .init(requestID: request.id, revision: request.revision, entries: entries)
    }

    private func arrow(_ editor: CommandInputView, older: Bool, modifiers: NSEvent.ModifierFlags = []) throws {
        let characters = older ? "\u{f700}" : "\u{f701}"
        editor.textView.keyDown(with: try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: older ? 126 : 125)))
    }

    private func showCompletions(_ editor: CommandInputView) throws {
        var value: CommandCompletionRequest?
        editor.onRequestCompletion = { value = $0 }
        editor.textView.completions.requestAutomaticNow()
        let request = try #require(value)
        editor.receiveCompletions(.init(requestID: request.id, revision: request.revision, items: [
            .init(displayText: "checkout", detail: "", replacementText: "git checkout",
                  replacementRange: NSRange(location: 0, length: request.text.utf16.count)),
            .init(displayText: "cherry-pick", detail: "", replacementText: "git cherry-pick",
                  replacementRange: NSRange(location: 0, length: request.text.utf16.count))
        ]))
    }
}

/// Never order this window onscreen or activate the user's application.
private final class CommandHistoryTestWindow: NSWindow {
    var simulatedKey = true
    override var isKeyWindow: Bool { simulatedKey }
    override var canBecomeKey: Bool { true }
}
