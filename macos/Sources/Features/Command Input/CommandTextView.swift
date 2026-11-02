import AppKit

/// A command is ordinary editable text until the shell accepts its submission.
/// AppKit owns selections, marked text, cursor movement, and the undo stack.
@MainActor
final class CommandTextView: NSTextView {
    var onSubmit: (String) -> Bool = { _ in false }
    var onUseTerminal: () -> Void = {}
    var onFocusChanged: (Bool) -> Void = { _ in }
    var onContentHeightChanged: (CGFloat) -> Void = { _ in }
    var onRequestCompletion: (CommandCompletionRequest) -> Void = { _ in }
    var onCancelCompletion: () -> Void = {}
    var canRequestFocus: () -> Bool = { true }
    private var focusRequestScheduled = false
    private var focusRequestRevision: UInt64 = 0
    private var heightReportScheduled = false
    private var pointerTrackingArea: NSTrackingArea?
    private let commandUndoManager = UndoManager()
    // NSTextStorage owns its layout manager; retain the root of the text system
    // for editors whose caller did not supply an existing text container.
    private let ownedTextStorage: NSTextStorage?
    private(set) var minimumLineHeight: CGFloat = 0
    private var completionRevision: UInt64 = 0
    private var completionRequest: CommandCompletionRequest?
    private var completionPopup: CommandCompletionView?
    private(set) var completionItems: [CommandCompletionCandidate] = []
    private(set) var selectedCompletionIndex = 0
    private var completionMessage: String?

    // Ghostty's window undo manager also owns closing/reopening tabs and panes.
    // Editing or clearing one draft must never undo or erase those operations.
    override var undoManager: UndoManager? { commandUndoManager }

    /// Focus is requested by token so a host layout update cannot steal focus back
    /// from output selection or another pane. Defer until a window is attached.
    var focusRequested = false {
        didSet {
            focusRequestRevision &+= 1
            applyFocusRequest()
        }
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        let resolvedContainer: NSTextContainer
        if let container {
            ownedTextStorage = nil
            resolvedContainer = container
        } else {
            let storage = NSTextStorage()
            let layoutManager = NSLayoutManager()
            resolvedContainer = NSTextContainer(containerSize: NSSize(
                width: frameRect.width,
                height: CGFloat.greatestFiniteMagnitude
            ))
            storage.addLayoutManager(layoutManager)
            layoutManager.addTextContainer(resolvedContainer)
            ownedTextStorage = storage
        }
        super.init(frame: frameRect, textContainer: resolvedContainer)
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textColor = .textColor
        insertionPointColor = .textColor
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = true
        isHorizontallyResizable = false
        // The empty editor must remain a clickable text view after submission.
        // The enclosing scroll view keeps this minimum matched to its viewport.
        minSize = NSSize(width: 0, height: frameRect.height)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
        textContainer?.heightTracksTextView = false
        textContainer?.lineFragmentPadding = 0
        textContainer?.containerSize = NSSize(
            width: frameRect.width,
            height: .greatestFiniteMagnitude
        )
        setAccessibilityLabel("Command input")
        setAccessibilityHelp("Edit a command. Return submits; Shift Return adds a line. Escape returns to the terminal.")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func keyDown(with event: NSEvent) {
        // Let the input method consume Return/Escape while composing. A Return
        // that commits an IME candidate must never also execute the command.
        guard !hasMarkedText() else {
            dismissCompletions()
            super.keyDown(with: event)
            return
        }

        if handleCompletionKey(event) { return }

        switch event.keyCode {
        case 36, 76: // Return and keypad Enter
            guard isEditable else { return }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !modifiers.isDisjoint(with: [.shift, .control, .option]) {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                // Keep the draft until an explicit shell receipt clears it via
                // the binding. Queuing a submission is not an acknowledgement.
                _ = onSubmit(string)
            }

        case 53: // Escape
            onUseTerminal()

        default:
            super.keyDown(with: event)
        }
    }

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let action = #selector(useTerminalFromMenu(_:))
        if !menu.items.contains(where: { $0.action == action }) {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let item = menu.addItem(withTitle: "Use Terminal", action: action, keyEquivalent: "")
            item.target = self
        }
        return menu
    }

    @objc private func useTerminalFromMenu(_ sender: NSMenuItem) {
        onUseTerminal()
    }

    func configureAppearance(
        font: NSFont,
        textColor: NSColor,
        backgroundColor: NSColor,
        minimumLineHeight: CGFloat
    ) {
        var metricsChanged = false
        if self.font != font {
            self.font = font
            metricsChanged = true
        }
        if self.textColor != textColor { self.textColor = textColor }
        if insertionPointColor != textColor { insertionPointColor = textColor }
        if self.backgroundColor != backgroundColor { self.backgroundColor = backgroundColor }
        let lineHeight = max(0, minimumLineHeight)
        if self.minimumLineHeight != lineHeight {
            metricsChanged = true
            self.minimumLineHeight = lineHeight
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = lineHeight
            defaultParagraphStyle = paragraph
            typingAttributes[.paragraphStyle] = paragraph
            if let textStorage, textStorage.length > 0 {
                textStorage.addAttribute(
                    .paragraphStyle, value: paragraph,
                    range: NSRange(location: 0, length: textStorage.length)
                )
            }
        }
        if metricsChanged { reportContentHeight() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .inVisibleRect, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        pointerTrackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        restorePointer(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        restorePointer(for: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        super.cursorUpdate(with: event)
        restorePointer(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        restorePointer(for: event)
        super.mouseDown(with: event)
    }

    /// Tracking areas can overlap terminal output or another AppKit overlay.
    /// Only the actual hit target may change the application's mouse pointer.
    func ownsPointerEvent(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.isKeyWindow,
              !isHiddenOrHasHiddenAncestor, let contentView = window.contentView else { return false }
        let point = contentView.convert(event.locationInWindow, from: nil)
        return contentView.hitTest(point) === self
    }

    private func restorePointer(for event: NSEvent) {
        guard ownsPointerEvent(event) else { return }
        // NSTextView and the terminal can both hide until mouse movement. A
        // pointer crossing their boundary must release that shared hide state.
        // NSCursor.unhide() is not the inverse of setHiddenUntilMouseMoves.
        NSCursor.setHiddenUntilMouseMoves(false)
        effectiveAppearance.performAsCurrentDrawingAppearance { NSCursor.iBeam.set() }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, !hasMarkedText() else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers == .command || modifiers == [.command, .shift] else {
            return super.performKeyEquivalent(with: event)
        }

        // Ghostty has no Cut menu item, and its configurable terminal shortcuts
        // need not match standard text editing. Keep native editing shortcuts
        // available whenever this text view, rather than the PTY, owns focus.
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a" where modifiers == .command:
            selectAll(nil)
        case "c" where modifiers == .command:
            copy(nil)
        case "x" where modifiers == .command:
            if isEditable { cut(nil) }
        case "v" where modifiers == .command:
            if isEditable { pasteAsPlainText(nil) }
        case "z":
            if isEditable {
                if modifiers.contains(.shift) {
                    commandUndoManager.redo()
                } else {
                    commandUndoManager.undo()
                }
            }
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChanged(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            dismissCompletions()
            onFocusChanged(false)
        }
        return accepted
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { dismissCompletions() }
        applyFocusRequest()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        if newSize != frame.size { dismissCompletions() }
        super.setFrameSize(newSize)
        // TextKit can resize its view while laying out. Avoid entering its
        // layout manager recursively from that frame change.
        guard widthChanged, !heightReportScheduled else { return }
        heightReportScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.heightReportScheduled = false
            self.reportContentHeight()
        }
    }

    override func didChangeText() {
        completionRevision &+= 1
        dismissCompletions()
        super.didChangeText()
        reportContentHeight()
    }

    /// Programmatic acknowledgement/history changes do not call didChangeText.
    func draftWillChangeExternally() {
        completionRevision &+= 1
        dismissCompletions()
    }

    func completionSelectionDidChange() {
        if let request = completionRequest, !completionIsCurrent(request) { dismissCompletions() }
    }

    func receiveCompletions(_ response: CommandCompletionResponse) {
        guard let request = completionRequest,
              response.requestID == request.id, response.revision == request.revision else { return }
        guard completionIsCurrent(request), isEditable, !hasMarkedText(),
              window?.isKeyWindow == true, window?.firstResponder === self,
              !isHiddenOrHasHiddenAncestor else {
            dismissCompletions()
            return
        }
        completionItems = response.items.filter { validCompletion($0, in: request.text) }
        selectedCompletionIndex = 0
        if completionItems.count == 1 {
            acceptCompletion(at: 0)
            return
        }
        completionMessage = completionItems.isEmpty ? (response.message ?? "No completions") : nil
        showCompletionPopup()
    }

    func dismissCompletions() {
        let hadCompletion = completionRequest != nil || !completionItems.isEmpty || completionMessage != nil
        completionRequest = nil
        completionItems = []
        completionMessage = nil
        completionPopup?.dismiss()
        if hadCompletion { onCancelCompletion() }
    }

    func updateCompletionPosition() {
        guard !completionItems.isEmpty || completionMessage != nil else { return }
        completionPopup?.updatePosition(for: self)
    }

    private func handleCompletionKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let menuOpen = !completionItems.isEmpty || completionMessage != nil
        if event.keyCode == 53, menuOpen || completionRequest != nil {
            dismissCompletions()
            return true
        }
        guard isEditable else { return false }
        if event.keyCode == 48, modifiers == .option {
            dismissCompletions()
            insertText("\t", replacementRange: selectedRange())
            return true
        }
        guard modifiers.isSubset(of: [.shift]) else { return false }
        switch event.keyCode {
        case 48: // Tab and Shift Tab
            if !completionItems.isEmpty {
                moveCompletionSelection(by: modifiers.contains(.shift) ? -1 : 1)
            } else if completionMessage != nil || completionRequest == nil {
                requestCompletions()
            }
            return true
        case 125, 126: // Down and Up
            guard menuOpen, !completionItems.isEmpty else { return false }
            moveCompletionSelection(by: event.keyCode == 125 ? 1 : -1)
            return true
        case 36, 76:
            guard !completionItems.isEmpty, modifiers.isEmpty else { return false }
            acceptCompletion(at: selectedCompletionIndex)
            return true
        default:
            return false
        }
    }

    private func requestCompletions() {
        dismissCompletions()
        let selection = selectedRange()
        guard selection.length == 0, selection.location != NSNotFound,
              window?.firstResponder === self else { return }
        let request = CommandCompletionRequest(
            id: UUID(), revision: completionRevision, text: string, cursorUTF16: selection.location
        )
        completionRequest = request
        onRequestCompletion(request)
    }

    private func completionIsCurrent(_ request: CommandCompletionRequest) -> Bool {
        request.revision == completionRevision && request.text == string
            && selectedRange() == NSRange(location: request.cursorUTF16, length: 0)
    }

    private func validCompletion(_ candidate: CommandCompletionCandidate, in text: String) -> Bool {
        let length = (text as NSString).length
        let range = candidate.replacementRange
        guard range.location >= 0, range.length >= 0,
              range.location <= length, range.length <= length - range.location,
              validUTF16Offset(range.location, in: text),
              validUTF16Offset(range.location + range.length, in: text) else { return false }
        if let cursor = candidate.cursorUTF16 {
            let result = (text as NSString).replacingCharacters(in: range, with: candidate.replacementText)
            guard validUTF16Offset(cursor, in: result) else { return false }
        }
        return true
    }

    private func validUTF16Offset(_ offset: Int, in text: String) -> Bool {
        guard offset >= 0, offset <= text.utf16.count else { return false }
        let index = text.utf16.index(text.utf16.startIndex, offsetBy: offset)
        // Range(NSRange, in:) can preserve an offset inside a surrogate pair.
        // Require an index representable by the original Swift string instead.
        return String.Index(index, within: text) != nil
    }

    private func moveCompletionSelection(by amount: Int) {
        guard !completionItems.isEmpty else { return }
        selectedCompletionIndex = (selectedCompletionIndex + amount + completionItems.count) % completionItems.count
        completionPopup?.select(index: selectedCompletionIndex)
        completionPopup?.updatePosition(for: self)
    }

    private func acceptCompletion(at index: Int) {
        guard let request = completionRequest, completionIsCurrent(request),
              completionItems.indices.contains(index), isEditable else {
            dismissCompletions()
            return
        }
        let candidate = completionItems[index]
        guard validCompletion(candidate, in: string) else { dismissCompletions(); return }
        dismissCompletions()
        breakUndoCoalescing()
        insertText(candidate.replacementText, replacementRange: candidate.replacementRange)
        if let cursor = candidate.cursorUTF16 { setSelectedRange(NSRange(location: cursor, length: 0)) }
        breakUndoCoalescing()
        scrollRangeToVisible(selectedRange())
    }

    private func showCompletionPopup() {
        // Unit tests use unshown windows; creating their result state must not
        // order a window over the user's desktop.
        guard window?.isVisible == true else { return }
        if completionPopup == nil {
            completionPopup = CommandCompletionView()
            completionPopup?.onAccept = { [weak self] in self?.acceptCompletion(at: $0) }
        }
        completionPopup?.show(items: completionItems, message: completionMessage,
                              selected: selectedCompletionIndex, for: self)
    }

    var measuredContentHeight: CGFloat {
        let diagnostic = CommandInputDiagnostics.begin(.textMeasurement)
        defer { CommandInputDiagnostics.end(diagnostic) }
        guard let layoutManager, let textContainer else { return max(1, minimumLineHeight) }
        layoutManager.ensureLayout(for: textContainer)
        let oneLine = max(minimumLineHeight, layoutManager.defaultLineHeight(
            for: font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        ))
        let usedHeight = layoutManager.usedRect(for: textContainer).maxY
        // TextKit keeps the insertion line after a trailing newline outside its
        // used glyph rect. Include that fragment so Shift Return grows at once.
        let extraHeight = layoutManager.extraLineFragmentTextContainer === textContainer
            ? layoutManager.extraLineFragmentRect.maxY : 0
        return ceil(max(oneLine, max(usedHeight, extraHeight)) + textContainerInset.height * 2)
    }

    func reportContentHeight() {
        onContentHeightChanged(measuredContentHeight)
    }

    func applyFocusRequest() {
        guard focusRequested, isEditable, let window, !focusRequestScheduled else { return }
        guard window.isKeyWindow, !isHiddenOrHasHiddenAncestor, canRequestFocus() else {
            focusRequested = false
            return
        }
        let previousResponder = window.firstResponder
        let revision = focusRequestRevision
        focusRequestScheduled = true
        // First-responder callbacks may relayout the surface host. Resolve the
        // request after the current layout operation has completed.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusRequestScheduled = false
            guard revision == self.focusRequestRevision else {
                self.applyFocusRequest()
                return
            }
            guard self.focusRequested, self.isEditable, let window = self.window else { return }
            guard window.isKeyWindow, !self.isHiddenOrHasHiddenAncestor, self.canRequestFocus(),
                  window.firstResponder === previousResponder || window.firstResponder === self else {
                // The user may have switched panes/windows after this request
                // was queued. A later layout must not resurrect that request.
                self.focusRequested = false
                return
            }
            if window.makeFirstResponder(self) {
                self.focusRequested = false
            }
        }
    }
}
