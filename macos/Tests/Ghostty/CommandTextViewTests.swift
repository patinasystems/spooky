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

    @Test func editorPaddingSurroundsTheViewportWithoutChangingTextMetrics() {
        let editor = CommandInputView(frame: NSRect(x: 0, y: 0, width: 400, height: 36))
        editor.configureAppearance(font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                                   textColor: .white, backgroundColor: .black, minimumLineHeight: 24)
        editor.layout()
        #expect(editor.scrollView.frame == NSRect(x: 6, y: 6, width: 388, height: 24))
        #expect(editor.textView.measuredContentHeight == 24)

        editor.setFrameSize(NSSize(width: 400, height: 108))
        editor.layout()
        #expect(editor.scrollView.frame == NSRect(x: 6, y: 6, width: 388, height: 96))
        #expect(editor.textView.frame.height >= editor.scrollView.contentView.bounds.height)
        #expect(editor.textView.measuredContentHeight == 24)
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
        #expect(view.string == "git ch --quiet")
        view.keyDown(with: try keyEvent(code: 48, characters: "\t"))
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

        view.keyDown(with: try keyEvent(code: 125, characters: ""))
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

        editor.textView.setSelectedRange(NSRange(location: 6, length: 0))
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

    @Test func typingFiltersCachedCompletionsAndAcceptsTheCurrentTokenRange() throws {
        let (view, window) = makeCompletionEditor(draft: "git ch")
        defer { window.close() }
        let request = try requestCompletion(from: view)
        view.receiveCompletions(completionResponse(to: request))
        var submissions = 0
        view.onSubmit = { _ in submissions += 1; return true }

        view.insertText("p", replacementRange: view.selectedRange())

        #expect(view.string == "git chp")
        #expect(view.completionItems.map(\.displayText) == ["cherry-pick"])
        #expect(view.completionItems.first?.replacementRange == NSRange(location: 4, length: 3))
        view.keyDown(with: try returnEvent())
        #expect(view.string == "git cherry-pick")
        #expect(submissions == 0)
    }

    @Test func nativeSelectionDelegateKeepsTheMenuDuringAnEditButCancelsACaretMove() throws {
        let editor = CommandInputView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        editor.setDraft("git ch")
        let window = makeFocusWindow(containing: editor)
        defer { window.close() }
        #expect(window.makeFirstResponder(editor.textView))
        let request = try requestCompletion(from: editor.textView)
        editor.receiveCompletions(completionResponse(to: request))
        editor.textView.insertText("p", replacementRange: editor.textView.selectedRange())
        #expect(editor.textView.completionItems.map(\.displayText) == ["cherry-pick"])
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(editor.textView.completionItems.isEmpty)
    }

    @Test func filteredCompletionPreservesUnicodePrefixAndCommandSuffix() throws {
        let prefix = "echo 👋\ncat "
        let suffix = " --quiet"
        let (view, window) = makeCompletionEditor(draft: prefix + "ca" + suffix)
        defer { window.close() }
        view.setSelectedRange(NSRange(location: prefix.utf16.count + 2, length: 0))
        let request = try requestCompletion(from: view)
        let items = ["café\\ folder/", "catalog/"].map { option in
            CommandCompletionCandidate(displayText: CommandCompletionToken.unquoted(option), detail: "",
                replacementText: prefix + option + suffix,
                replacementRange: NSRange(location: 0, length: request.text.utf16.count),
                cursorUTF16: prefix.utf16.count + option.utf16.count)
        }
        view.receiveCompletions(.init(requestID: request.id, revision: request.revision, items: items))
        view.insertText("fé", replacementRange: view.selectedRange())

        #expect(view.completionItems.count == 1)
        #expect(view.completionItems.first?.replacementRange == NSRange(location: prefix.utf16.count, length: 4))
        view.receiveCompletions(completionResponse(to: request)) // An old result cannot replace the live filter.
        view.keyDown(with: try returnEvent())
        #expect(view.string == prefix + "café\\ folder/" + suffix)
        #expect(view.selectedRange().location == prefix.utf16.count + "café\\ folder/".utf16.count)
    }

    @Test func deletingAQueryRestoresCachedMatchesAndCrossingItsBoundaryDismisses() throws {
        let (view, window) = makeCompletionEditor(draft: "git ch")
        defer { window.close() }
        let request = try requestCompletion(from: view)
        view.receiveCompletions(completionResponse(to: request))
        view.insertText("zz", replacementRange: view.selectedRange())
        #expect(view.completionItems.isEmpty)
        view.insertText("", replacementRange: NSRange(location: 6, length: 2))
        #expect(view.completionItems.count == 2)
        view.insertText(" ", replacementRange: view.selectedRange())
        #expect(view.completionItems.isEmpty)
        view.keyDown(with: try keyEvent(code: 126, characters: ""))
        #expect(view.string == "git ch ")
    }

    @Test func commandFindPreservesDraftAndDismissesCompletions() throws {
        let (view, window) = makeCompletionEditor(draft: "git ch")
        defer { window.close() }
        let request = try requestCompletion(from: view)
        view.receiveCompletions(completionResponse(to: request))
        var finds = 0
        view.onFind = { finds += 1; return true }
        #expect(view.performKeyEquivalent(with: try keyEvent(code: 3, characters: "f", modifiers: .command)))
        #expect(finds == 1)
        #expect(view.string == "git ch")
        #expect(view.completionItems.isEmpty)
        view.performFindPanelAction(nil)
        #expect(finds == 2)
        #expect(view.string == "git ch")
    }

    @Test func completionSelectionScrollsOnlyEnoughToRevealTheRow() {
        let viewport = NSRect(x: 0, y: 60, width: 300, height: 90)
        #expect(CommandCompletionView.scrollOrigin(for: NSRect(x: 0, y: 90, width: 300, height: 30),
            viewport: viewport, documentHeight: 600).y == 60)
        #expect(CommandCompletionView.scrollOrigin(for: NSRect(x: 0, y: 150, width: 300, height: 30),
            viewport: viewport, documentHeight: 600).y == 90)
        #expect(CommandCompletionView.scrollOrigin(for: NSRect(x: 0, y: 0, width: 300, height: 30),
            viewport: viewport, documentHeight: 600).y == 0)
    }

    @Test func automaticSuggestionNeverMutatesDraftAndRightAcceptsIt() throws {
        let (view, window) = makeCompletionEditor(draft: "git ch")
        defer { window.close() }
        var request: CommandCompletionRequest?
        view.onRequestCompletion = { request = $0 }
        view.completions.requestAutomaticNow()
        let automatic = try #require(request)
        #expect(automatic.automatic)
        #expect(automatic.shellText == "git ")
        view.receiveCompletions(completionResponse(to: automatic))
        #expect(view.string == "git ch")
        #expect(view.completions.inlineSuggestion == "eckout")
        #expect(!view.completions.listVisible)
        view.keyDown(with: try keyEvent(code: 124, characters: ""))
        #expect(view.string == "git checkout")
        #expect(view.completions.inlineSuggestion == nil)
    }

    @Test func nativeEditsStoreDraftAndReportHeightWithoutRebuildingHostPresentation() async throws {
        let session = try CommandInputSession()
        session.receive(.init(state: .init(kind: "ready", generation: "prompt-1", context: "start", blockID: "123-1"),
                              receipt: nil, metadata: [:]))
        let editor = CommandInputView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        editor.configureAppearance(font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                                   textColor: .textColor, backgroundColor: .textBackgroundColor, minimumLineHeight: 24)
        let window = makeFocusWindow(containing: editor)
        defer { window.close() }
        editor.layoutSubtreeIfNeeded()
        #expect(window.makeFirstResponder(editor.textView))
        editor.onTextChanged = { session.setDraft($0) }
        var presentations = 0
        var heights: [CGFloat] = []
        session.onChange = { presentations += 1 }
        editor.onContentHeightChanged = { heights.append($0) }
        await drainMainQueue()
        await drainMainQueue()
        let oneLine = editor.textView.measuredContentHeight + CommandInputView.padding * 2
        heights.removeAll()

        editor.textView.insertText("echo first", replacementRange: editor.textView.selectedRange())
        await drainMainQueue()
        #expect(session.draft == "echo first")
        #expect(editor.textView.string == session.draft)
        #expect(presentations == 0)
        #expect(heights.isEmpty)

        editor.textView.insertText("\n", replacementRange: editor.textView.selectedRange())
        await drainMainQueue()
        #expect(session.draft == "echo first\n")
        #expect(presentations == 0)
        #expect(try #require(heights.last) > oneLine)

        // Width-dependent wrapping also reaches the host through its height
        // callback, independently of session presentation notifications.
        editor.textView.insertText(String(repeating: "word ", count: 60),
                                   replacementRange: editor.textView.selectedRange())
        await drainMainQueue()
        #expect(session.draft == editor.textView.string)
        #expect(presentations == 0)
        #expect(try #require(heights.last) > oneLine * 2)
    }

    @Test func inlineGeometryAndAppearanceChangesPreserveSuggestionAndAcceptance() throws {
        let (view, window) = makeCompletionEditor(draft: "git ch")
        defer { window.close() }
        var requests: [CommandCompletionRequest] = []
        view.onRequestCompletion = { requests.append($0) }
        view.completions.requestAutomaticNow()
        view.receiveCompletions(completionResponse(to: try #require(requests.first)))
        #expect(view.completions.inlineSuggestion == "eckout")

        view.setFrameSize(NSSize(width: 280, height: 48))
        view.configureAppearance(font: .monospacedSystemFont(ofSize: 16, weight: .regular),
                                 textColor: .white, backgroundColor: .black, minimumLineHeight: 28)
        view.updateCompletionPosition()
        // A window may lose key status without changing its first responder.
        // Position updates hide the annotation without losing its valid draft.
        window.simulatedKey = false
        view.updateCompletionPosition()
        window.simulatedKey = true
        view.updateCompletionPosition()

        #expect(requests.count == 1)
        #expect(view.string == "git ch")
        #expect(view.completions.inlineSuggestion == "eckout")
        #expect(view.selectedRange() == NSRange(location: 6, length: 0))
        view.keyDown(with: try keyEvent(code: 124, characters: ""))
        #expect(view.string == "git checkout")
        #expect(view.completions.inlineSuggestion == nil)
    }

    @Test func movingAPreviewDoesNotPreventItsInvalidationAfterEditingOrSelection() throws {
        let editor = CommandInputView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        editor.setDraft("git ch")
        let window = makeFocusWindow(containing: editor)
        defer { window.close() }
        editor.layoutSubtreeIfNeeded()
        #expect(window.makeFirstResponder(editor.textView))
        var request: CommandCompletionRequest?
        editor.onRequestCompletion = { request = $0 }
        editor.textView.completions.requestAutomaticNow()
        editor.receiveCompletions(completionResponse(to: try #require(request)))
        editor.textView.updateCompletionPosition()

        editor.textView.insertText("p", replacementRange: editor.textView.selectedRange())
        #expect(editor.textView.completions.inlineSuggestion == " → cherry-pick")
        editor.textView.updateCompletionPosition()
        #expect(editor.textView.completions.inlineSuggestion == " → cherry-pick")
        editor.textView.setSelectedRange(NSRange(location: 0, length: 3))
        editor.textView.updateCompletionPosition()
        #expect(editor.textView.completions.inlineSuggestion == nil)
        #expect(editor.textView.completionItems.isEmpty)
        #expect(editor.textView.string == "git chp")
    }

    @Test func tabRevealsInlineOptionsAndSecondTabAcceptsTheSelectedOption() throws {
        let (view, window) = makeCompletionEditor(draft: "git ch")
        defer { window.close() }
        var request: CommandCompletionRequest?
        view.onRequestCompletion = { request = $0 }
        view.completions.requestAutomaticNow()
        view.receiveCompletions(completionResponse(to: try #require(request)))
        view.keyDown(with: try keyEvent(code: 48, characters: "\t"))
        #expect(view.completions.listVisible)
        #expect(view.string == "git ch")
        view.keyDown(with: try keyEvent(code: 125, characters: ""))
        view.keyDown(with: try keyEvent(code: 48, characters: "\t"))
        #expect(view.string == "git cherry-pick")
    }

    @Test func downRevealsBestInlineOptionWithoutSkippingItAndEscapeDismisses() throws {
        let (view, window) = makeCompletionEditor(draft: "git ch")
        defer { window.close() }
        var request: CommandCompletionRequest?
        var terminal = false
        view.onUseTerminal = { terminal = true }
        view.onRequestCompletion = { request = $0 }
        view.completions.requestAutomaticNow()
        view.receiveCompletions(completionResponse(to: try #require(request)))
        view.keyDown(with: try keyEvent(code: 125, characters: ""))
        #expect(view.completions.listVisible)
        #expect(view.selectedCompletionIndex == 0)
        view.keyDown(with: try keyEvent(code: 53, characters: "\u{1b}"))
        #expect(view.string == "git ch")
        #expect(!terminal)
        #expect(view.completionItems.isEmpty)
    }

    @Test func returnWithOnlyInlinePredictionSubmitsOnlyTypedText() throws {
        let (view, window) = makeCompletionEditor(draft: "git ch")
        defer { window.close() }
        var request: CommandCompletionRequest?
        var submitted: String?
        view.onRequestCompletion = { request = $0 }
        view.onSubmit = { submitted = $0; return true }
        view.completions.requestAutomaticNow()
        view.receiveCompletions(completionResponse(to: try #require(request)))
        view.keyDown(with: try returnEvent())
        #expect(submitted == "git ch")
        #expect(view.completionItems.isEmpty)
    }

    @Test func realTextChangesDebounceAutomaticRequestsAndReuseCachedMatches() async throws {
        let editor = CommandInputView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        let window = makeFocusWindow(containing: editor)
        defer { window.close() }
        #expect(window.makeFirstResponder(editor.textView))
        editor.layoutSubtreeIfNeeded()
        await drainMainQueue()
        var requests: [CommandCompletionRequest] = []
        editor.onRequestCompletion = { requests.append($0) }
        editor.textView.insertText("git ", replacementRange: editor.textView.selectedRange())
        editor.textView.insertText("c", replacementRange: editor.textView.selectedRange())
        editor.textView.insertText("h", replacementRange: editor.textView.selectedRange())
        #expect(requests.isEmpty)
        editor.setFrameSize(NSSize(width: 360, height: 40))
        editor.layoutSubtreeIfNeeded()
        // Other UI suites share MainActor. Wait for the event rather than
        // assuming its task started sleeping at the same instant as this test.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while requests.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.text == "git ch")
        editor.receiveCompletions(completionResponse(to: request))
        editor.textView.insertText("p", replacementRange: editor.textView.selectedRange())
        #expect(editor.textView.completionItems.map(\.displayText) == ["cherry-pick"])
        #expect(editor.textView.completions.inlineSuggestion == " → cherry-pick")
        try await Task.sleep(for: .milliseconds(100))
        #expect(requests.count == 1)
    }

    @Test func completionCannotRewriteArgumentsOutsideTheActiveToken() throws {
        let (view, window) = makeCompletionEditor(draft: "git ch --help")
        defer { window.close() }
        view.setSelectedRange(NSRange(location: 6, length: 0))
        let request = try requestCompletion(from: view)
        view.receiveCompletions(.init(requestID: request.id, revision: request.revision, items: [
            .init(displayText: "checkout", detail: "", replacementText: "git checkout --other",
                  replacementRange: NSRange(location: 0, length: view.string.utf16.count))
        ]))
        #expect(view.completionItems.isEmpty)
        view.keyDown(with: try returnEvent())
        #expect(view.string == "git ch --help")
    }

    @Test func inlinePreviewDoesNotCoverLaterArgumentsOrLeakIntoSelection() throws {
        let candidate = CommandCompletionCandidate(displayText: "café", detail: "",
            replacementText: "café", replacementRange: NSRange(location: 4, length: 2))
        #expect(CommandCompletionController.preview(candidate, text: "cat ca --quiet", cursor: 6) == nil)
        #expect(CommandCompletionController.preview(candidate, text: "cat ca", cursor: 6) == "fé")
        let (view, window) = makeCompletionEditor(draft: "git ch")
        defer { window.close() }
        var request: CommandCompletionRequest?
        view.onRequestCompletion = { request = $0 }
        view.completions.requestAutomaticNow()
        view.receiveCompletions(completionResponse(to: try #require(request)))
        view.setSelectedRange(NSRange(location: 0, length: 3))
        view.completionSelectionDidChange()
        #expect(view.completions.inlineSuggestion == nil)
        #expect(view.string == "git ch")
    }

    @Test func escapeCancelsDebouncedWorkAndMarkedTextCannotRequestPredictions() async throws {
        let (view, window) = makeCompletionEditor(draft: "git ")
        defer { window.close() }
        var requests = 0
        var terminalRequests = 0
        view.onRequestCompletion = { _ in requests += 1 }
        view.onUseTerminal = { terminalRequests += 1 }
        view.insertText("ch", replacementRange: view.selectedRange())
        view.keyDown(with: try keyEvent(code: 53, characters: "\u{1b}"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(requests == 0)
        #expect(terminalRequests == 0)
        #expect(view.string == "git ch")
        view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.completions.requestAutomaticNow()
        #expect(requests == 0)
    }

    @Test func broadResultMissFallsBackToAnExactShellQueryOnce() async throws {
        let (view, window) = makeCompletionEditor(draft: "cat zz")
        defer { window.close() }
        var requests: [CommandCompletionRequest] = []
        view.onRequestCompletion = { requests.append($0) }
        view.completions.requestAutomaticNow()
        let broad = try #require(requests.first)
        #expect(broad.shellText == "cat ")
        view.receiveCompletions(.init(requestID: broad.id, revision: broad.revision, items: [
            .init(displayText: "alpha", detail: "", replacementText: "cat alpha",
                  replacementRange: NSRange(location: 0, length: broad.text.utf16.count))
        ]))
        try await Task.sleep(for: .milliseconds(120))
        #expect(requests.count == 2)
        let exact = try #require(requests.last)
        #expect(exact.shellText == "cat zz")
        #expect(exact.queryText == nil)
        view.receiveCompletions(.init(requestID: exact.id, revision: exact.revision, items: []))
        try await Task.sleep(for: .milliseconds(100))
        #expect(requests.count == 2)
    }

    @Test func tabDuringBroadMissStartsExactLookupWithoutWaitingForDebounce() throws {
        let (view, window) = makeCompletionEditor(draft: "cat zz")
        defer { window.close() }
        var requests: [CommandCompletionRequest] = []
        view.onRequestCompletion = { requests.append($0) }
        view.completions.requestAutomaticNow()
        let broad = try #require(requests.first)
        view.receiveCompletions(.init(requestID: broad.id, revision: broad.revision, items: []))
        view.keyDown(with: try keyEvent(code: 48, characters: "\t"))
        #expect(requests.count == 2)
        #expect(requests.last?.queryText == nil)
        #expect(view.completions.listVisible)
        // A second key while that query is running must not launch another worker request.
        view.keyDown(with: try keyEvent(code: 48, characters: "\t"))
        #expect(requests.count == 2)
    }

    @Test func downWithoutAVisibleSuggestionRemainsNativeMultilineNavigation() throws {
        let (view, window) = makeCompletionEditor(draft: "echo first\necho second")
        defer { window.close() }
        view.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(!view.completions.handleKey(try keyEvent(code: 125, characters: "")))
        view.setSelectedRange(NSRange(location: 0, length: 4))
        #expect(!view.completions.handleKey(try keyEvent(code: 125, characters: "")))
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
