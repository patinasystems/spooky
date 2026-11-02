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

    @Test func nativeEditorAppearanceMatchesItsTerminalBackground() {
        let editor = CommandInputView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        let parent = NSView(frame: editor.frame)
        parent.appearance = NSAppearance(named: .aqua)
        parent.addSubview(editor)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        editor.configureAppearance(font: font, textColor: .white, backgroundColor: .black, minimumLineHeight: 24)

        #expect(editor.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        #expect(editor.textView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        #expect(editor.scrollView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)

        editor.configureAppearance(font: font, textColor: .black, backgroundColor: .white, minimumLineHeight: 24)
        #expect(editor.textView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
    }

    @Test func unchangedAppearanceAndViewportHeightDoNotRemeasureText() async {
        let view = makeSizedEditor(width: 400)
        await drainMainQueue()
        var reports = 0
        view.onContentHeightChanged = { _ in reports += 1 }
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        view.configureAppearance(font: font, textColor: .textColor,
                                 backgroundColor: .textBackgroundColor, minimumLineHeight: 24)
        view.configureAppearance(font: font, textColor: .white, backgroundColor: .black, minimumLineHeight: 24)
        view.setFrameSize(NSSize(width: 400, height: 100))
        await drainMainQueue()
        #expect(reports == 0)

        // Changing line metrics still updates the host, even with no draft.
        view.configureAppearance(font: font, textColor: .white, backgroundColor: .black, minimumLineHeight: 28)
        #expect(reports == 1)
        #expect(view.measuredContentHeight == 28)
    }

    @Test func pointerRestorationBelongsOnlyToTheVisibleHitTarget() throws {
        let view = makeSizedEditor(width: 400)
        let window = makeFocusWindow(containing: view)
        defer { window.close() }
        let event = try mouseMoveEvent(in: window, point: NSPoint(x: 20, y: 10))
        #expect(view.ownsPointerEvent(event))

        let overlay = NSView(frame: view.frame)
        window.contentView?.addSubview(overlay)
        #expect(!view.ownsPointerEvent(event))
        overlay.removeFromSuperview()

        window.simulatedKey = false
        #expect(!view.ownsPointerEvent(event))
        window.simulatedKey = true
        view.isHidden = true
        #expect(!view.ownsPointerEvent(event))
        view.isHidden = false
        #expect(!view.ownsPointerEvent(try mouseMoveEvent(in: window, point: NSPoint(x: 20, y: 80))))
    }

    @Test func pointerTrackingFollowsTheVisibleEditorWithoutAccumulatingAreas() {
        let view = makeSizedEditor(width: 400)
        view.updateTrackingAreas()
        let count = view.trackingAreas.count
        #expect(view.trackingAreas.contains { area in
            area.options.contains([.mouseMoved, .cursorUpdate, .mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow])
        })

        view.updateTrackingAreas()

        #expect(view.trackingAreas.count == count)
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

    @Test func tabRequestsTheExactMultilineDraftAndUTF16Cursor() throws {
        let (view, window) = makeCompletionEditor(draft: "echo 👋\ngit ch --quiet")
        defer { window.close() }
        let cursor = (view.string as NSString).range(of: " --quiet").location
        view.setSelectedRange(NSRange(location: cursor, length: 0))

        let request = try requestCompletion(from: view)

        #expect(request.text == "echo 👋\ngit ch --quiet")
        #expect(request.cursorUTF16 == cursor)
        #expect(view.string == request.text)
    }

    @Test func uniqueShellCompletionIsUndoableAndPreservesItsReturnedCursor() throws {
        let (view, window) = makeCompletionEditor(draft: "git ch --quiet")
        defer { window.close() }
        view.setSelectedRange(NSRange(location: 6, length: 0))
        let request = try requestCompletion(from: view)
        let manager = try #require(view.undoManager)
        var submissions = 0
        view.onSubmit = { _ in submissions += 1; return true }
        manager.beginUndoGrouping()

        view.receiveCompletions(CommandCompletionResponse(
            requestID: request.id, revision: request.revision,
            items: [CommandCompletionCandidate(displayText: "checkout", detail: "Switch branches",
                replacementText: "git checkout --quiet", replacementRange: NSRange(location: 0, length: 14),
                cursorUTF16: 12)]
        ))
        manager.endUndoGrouping()

        #expect(view.string == "git checkout --quiet")
        #expect(view.selectedRange() == NSRange(location: 12, length: 0))
        #expect(submissions == 0)
        manager.undo()
        #expect(view.string == "git ch --quiet")
    }

    @Test func completionMenuCyclesAndReturnAcceptsBeforeItCanSubmit() throws {
        let (view, window) = makeCompletionEditor(draft: "git ch")
        defer { window.close() }
        let request = try requestCompletion(from: view)
        var submitted: [String] = []
        view.onSubmit = { submitted.append($0); return true }
        view.receiveCompletions(completionResponse(to: request))
        #expect(view.completionItems.count == 2)

        view.keyDown(with: try keyEvent(code: 48, characters: "\t"))
        #expect(view.selectedCompletionIndex == 1)
        view.keyDown(with: try keyEvent(code: 48, characters: "\t", modifiers: .shift))
        #expect(view.selectedCompletionIndex == 0)
        view.keyDown(with: try keyEvent(code: 125, characters: ""))
        #expect(view.selectedCompletionIndex == 1)
        view.keyDown(with: try returnEvent())

        #expect(view.string == "git cherry-pick")
        #expect(view.completionItems.isEmpty)
        #expect(submitted.isEmpty)
        view.keyDown(with: try returnEvent())
        #expect(submitted == ["git cherry-pick"])
    }

    @Test func escapeDismissesCompletionBeforeReturningToTerminalInput() throws {
        let (view, window) = makeCompletionEditor(draft: "git ch")
        defer { window.close() }
        let request = try requestCompletion(from: view)
        var terminalRequests = 0
        view.onUseTerminal = { terminalRequests += 1 }
        view.receiveCompletions(completionResponse(to: request))

        view.keyDown(with: try keyEvent(code: 53, characters: "\u{1b}"))
        #expect(view.completionItems.isEmpty)
        #expect(terminalRequests == 0)
        view.keyDown(with: try keyEvent(code: 53, characters: "\u{1b}"))
        #expect(terminalRequests == 1)
    }

    @Test func staleCompletionCannotReplaceNewTextOrANewCursorPosition() throws {
        let (view, window) = makeCompletionEditor(draft: "git ch")
        defer { window.close() }
        let first = try requestCompletion(from: view)
        view.insertText("e", replacementRange: view.selectedRange())
        view.receiveCompletions(completionResponse(to: first))
        #expect(view.string == "git che")
        #expect(view.completionItems.isEmpty)

        let second = try requestCompletion(from: view)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.receiveCompletions(completionResponse(to: second))
        #expect(view.string == "git che")
        #expect(view.completionItems.isEmpty)
    }

    @Test func completionRejectsInvalidUTF16ReplacementRanges() throws {
        let (view, window) = makeCompletionEditor(draft: "echo 👋")
        defer { window.close() }
        let request = try requestCompletion(from: view)

        view.receiveCompletions(CommandCompletionResponse(
            requestID: request.id, revision: request.revision,
            items: [CommandCompletionCandidate(displayText: "broken", detail: "",
                replacementText: "x", replacementRange: NSRange(location: 6, length: 1))]
        ))

        #expect(view.string == "echo 👋")
        #expect(view.completionItems.isEmpty)
    }

    @Test func completionResponseDoesNotFollowFocusIntoAnotherEditor() throws {
        let (view, window) = makeCompletionEditor(draft: "git ch")
        defer { window.close() }
        let request = try requestCompletion(from: view)
        let other = makeSizedEditor(width: 400)
        window.contentView?.addSubview(other)
        #expect(window.makeFirstResponder(other))

        view.receiveCompletions(completionResponse(to: request))

        #expect(window.firstResponder === other)
        #expect(view.string == "git ch")
        #expect(view.completionItems.isEmpty)
    }

    @Test func optionTabInsertsLiteralTextWithoutRequestingCompletion() throws {
        let (view, window) = makeCompletionEditor(draft: "echo")
        defer { window.close() }
        var requests = 0
        view.onRequestCompletion = { _ in requests += 1 }

        view.keyDown(with: try keyEvent(code: 48, characters: "\t", modifiers: .option))

        #expect(view.string == "echo\t")
        #expect(requests == 0)
    }

    @Test func selectionCancellationNotifiesTheHostOnceAndOldRepliesCannotCancelANewRequest() async throws {
        let editor = CommandInputView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        editor.setDraft("git ch")
        let window = makeFocusWindow(containing: editor)
        defer { window.close() }
        #expect(window.makeFirstResponder(editor.textView))
        var cancellations = 0
        editor.onCancelCompletion = { cancellations += 1 }
        let old = try requestCompletion(from: editor.textView)

        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        await drainMainQueue()
        #expect(cancellations == 1)
        editor.dismissCompletions()
        #expect(cancellations == 1)

        let current = try requestCompletion(from: editor.textView)
        editor.receiveCompletions(completionResponse(to: old))
        #expect(cancellations == 1)
        editor.receiveCompletions(completionResponse(to: current))
        #expect(editor.textView.completionItems.count == 2)
    }

    @Test func inactiveWindowResponseClearsThePendingRequestSoTabCanRetry() throws {
        let (view, window) = makeCompletionEditor(draft: "git ch")
        defer { window.close() }
        let old = try requestCompletion(from: view)
        var cancellations = 0
        view.onCancelCompletion = { cancellations += 1 }
        window.simulatedKey = false

        view.receiveCompletions(completionResponse(to: old))

        #expect(view.completionItems.isEmpty)
        #expect(cancellations == 1)
        window.simulatedKey = true
        let current = try requestCompletion(from: view)
        #expect(current.id != old.id)
    }

    @Test func escapeCancelsPendingCompletionBeforeSwitchingToTerminal() throws {
        let (view, window) = makeCompletionEditor(draft: "git ch")
        defer { window.close() }
        _ = try requestCompletion(from: view)
        var cancellations = 0
        var terminalRequests = 0
        view.onCancelCompletion = { cancellations += 1 }
        view.onUseTerminal = { terminalRequests += 1 }

        view.keyDown(with: try keyEvent(code: 53, characters: "\u{1b}"))
        #expect(cancellations == 1)
        #expect(terminalRequests == 0)
        view.keyDown(with: try keyEvent(code: 53, characters: "\u{1b}"))
        #expect(terminalRequests == 1)
    }

    private func makeCompletionEditor(draft: String) -> (CommandTextView, CommandFocusTestWindow) {
        let view = makeSizedEditor(width: 400)
        view.string = draft
        view.setSelectedRange(NSRange(location: (draft as NSString).length, length: 0))
        let window = makeFocusWindow(containing: view)
        #expect(window.makeFirstResponder(view))
        return (view, window)
    }

    private func requestCompletion(from view: CommandTextView) throws -> CommandCompletionRequest {
        var request: CommandCompletionRequest?
        view.onRequestCompletion = { request = $0 }
        view.keyDown(with: try keyEvent(code: 48, characters: "\t"))
        return try #require(request)
    }

    private func completionResponse(to request: CommandCompletionRequest) -> CommandCompletionResponse {
        CommandCompletionResponse(requestID: request.id, revision: request.revision, items: [
            CommandCompletionCandidate(displayText: "checkout", detail: "Switch branches",
                replacementText: "git checkout", replacementRange: NSRange(location: 0, length: (request.text as NSString).length)),
            CommandCompletionCandidate(displayText: "cherry-pick", detail: "Apply commits",
                replacementText: "git cherry-pick", replacementRange: NSRange(location: 0, length: (request.text as NSString).length))
        ])
    }

    private func makeFocusWindow(containing view: NSView) -> CommandFocusTestWindow {
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
        try keyEvent(code: 36, characters: "\r", modifiers: modifiers)
    }

    private func keyEvent(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        ))
    }

    private func mouseMoveEvent(in window: NSWindow, point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))
    }
}

@MainActor
private final class CommandFocusTestWindow: NSWindow {
    var simulatedKey = true
    override var isKeyWindow: Bool { simulatedKey }
}
