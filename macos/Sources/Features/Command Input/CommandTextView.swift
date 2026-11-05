import AppKit

/// A command is ordinary editable text until the shell accepts its submission.
/// AppKit owns selections, marked text, cursor movement, and the undo stack.
@MainActor
final class CommandTextView: NSTextView {
    /// Submission ownership is independent of TextKit's caret lifecycle.
    var managesInsertionPoint = false
    var onCaretChanged: () -> Void = {}
    override var shouldDrawInsertionPoint: Bool { managesInsertionPoint ? false : super.shouldDrawInsertionPoint }

    var acceptsCommandEdits = true
    var onSubmit: (String) -> Bool = { _ in false }
    var onUseTerminal: () -> Void = {}
    var onDeferredPromptKey: (NSEvent) -> Bool = { _ in false }
    var onTerminalKey: (NSEvent) -> Void = { _ in }
    var onFocusChanged: (Bool) -> Void = { _ in }
    var onContentHeightChanged: (CGFloat) -> Void = { _ in }
    var onRequestCompletion: (CommandCompletionRequest) -> Void = { _ in }
    var onCancelCompletion: () -> Void = {}
    var onRequestHistory: (CommandHistoryRequest) -> Void = { _ in }
    var onCancelHistory: () -> Void = {}
    var onFind: () -> Bool = { false }
    var canRequestFocus: () -> Bool = { true }
    /// Absolute cwd of the active prompt. The `@` file picker stays disabled
    /// until the host knows it; it is never guessed.
    var fileSearchDirectory: String?
    private var focusRequestScheduled = false
    private var focusRequestRevision: UInt64 = 0
    private var heightReportScheduled = false
    private var pointerTrackingArea: NSTrackingArea?
    private var editorTrace: CommandEditorTrace?
    private let commandUndoManager = UndoManager()
    // NSTextStorage owns its layout manager; retain the root of the text system
    // for editors whose caller did not supply an existing text container.
    private let ownedTextStorage: NSTextStorage?
    private(set) var minimumLineHeight: CGFloat = 0
    private(set) lazy var completions = CommandCompletionController(textView: self)
    private(set) lazy var history = CommandHistoryController(textView: self)
    var completionItems: [CommandCompletionCandidate] { completions.items }
    var selectedCompletionIndex: Int { completions.selectedIndex }

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
        // Shell completion owns suggestions; AppKit still owns marked-text
        // composition and the input method's candidate selection.
        isAutomaticTextCompletionEnabled = false
        if #available(macOS 14.0, *) { inlinePredictionType = .no }
        if #available(macOS 15.0, *) { mathExpressionCompletionType = .no }
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
        setAccessibilityHelp("Edit a command. Right or Tab accepts a suggestion; Up/Down selects options. "
                             + "Return accepts after menu navigation; otherwise it runs the typed command. "
                             + "Up on the first visual line recalls shell history; Down on the last returns to your draft. "
                             + "Shift Return adds a line. Type @ to insert a file path. "
                             + "Escape dismisses suggestions. Option-Escape explicitly uses terminal input.")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func keyDown(with event: NSEvent) {
        let input = CommandInputDiagnostics.currentInputID == nil
            ? CommandInputDiagnostics.beginInput(timestamp: event.timestamp) : nil
        let diagnostic = CommandInputDiagnostics.begin(.nativeKeyDown)
        defer {
            onCaretChanged()
            CommandInputDiagnostics.end(diagnostic)
            CommandInputDiagnostics.endInput(input)
        }
        guard acceptsCommandEdits else {
            if !onDeferredPromptKey(event) { onTerminalKey(event) }
            return
        }
        // Let the input method consume Return/Escape while composing. A Return
        // that commits an IME candidate must never also execute the command.
        guard !hasMarkedText() else {
            history.reset()
            dismissCompletions()
            interpretKeyEvents([event])
            return
        }
        // The `@` picker owns Command-Up and its list keys before native
        // modified-arrow handling; everything else falls through unchanged.
        if completions.filePickerActive, completions.handleKey(event) { return }
        completions.pendingFileTrigger = event.characters == "@"
            && event.modifierFlags.isDisjoint(with: [.command, .control])
        defer { completions.pendingFileTrigger = false }

        let arrow = event.keyCode == 125 || event.keyCode == 126
        let modified = !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
        if arrow {
            // Modified arrows belong entirely to native selection/navigation.
            if modified { interpretKeyEvents([event]); return }
            if completions.listVisible {
                _ = completions.handleKey(event)
                return
            }
            if history.isBrowsing {
                if !history.navigate(older: event.keyCode == 126) { interpretKeyEvents([event]) }
                return
            }
        }
        if completions.handleKey(event) { return }
        if arrow && history.navigate(older: event.keyCode == 126) { return }

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
            // Dismissing a menu twice must not silently give ZLE the draft or
            // re-enable the terminal cursor beneath an apparently native prompt.
            if event.modifierFlags.contains(.option) { onUseTerminal() }

        default:
            // Keep AppKit's input context, IME, and key bindings. NSTextView's
            // keyDown wrapper also synchronously hides the mouse through
            // WindowServer on every key. Pointer tracking owns our cursor;
            // interpreting directly avoids that unrelated round trip.
            interpretKeyEvents([event])
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

    private(set) var commandTheme: CommandUITheme?

    func applyTheme(_ theme: CommandUITheme) {
        guard commandTheme != theme else { return }
        commandTheme = theme
        selectedTextAttributes = [.backgroundColor: theme.selectionBackground,
                                  .foregroundColor: theme.selectionForeground]
        insertionPointColor = theme.cursor
        completions.applyTheme(theme)
    }

    func configureAppearance(
        font: NSFont,
        textColor: NSColor,
        backgroundColor: NSColor,
        minimumLineHeight: CGFloat
    ) {
        var metricsChanged = false
        var foregroundChanged = false
        if self.font != font {
            self.font = font
            metricsChanged = true
        }
        if self.textColor != textColor {
            self.textColor = textColor
            foregroundChanged = true
        }
        let cursor = commandTheme?.cursor ?? textColor
        if insertionPointColor != cursor { insertionPointColor = cursor }
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
        if metricsChanged || foregroundChanged { completions.updatePosition() }
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
        history.cancelPending()
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
        let input = CommandInputDiagnostics.beginInput(timestamp: event.timestamp)
        defer { CommandInputDiagnostics.endInput(input) }

        // Ghostty has no Cut menu item, and its configurable terminal shortcuts
        // need not match standard text editing. Keep native editing shortcuts
        // available whenever this text view, rather than the PTY, owns focus.
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f" where modifiers == .command:
            dismissCompletions()
            return onFind()
        case "a" where modifiers == .command:
            selectAll(nil)
        case "c" where modifiers == .command:
            copy(nil)
        case "x" where modifiers == .command:
            if isEditable && acceptsCommandEdits { cut(nil) }
        case "v" where modifiers == .command:
            if isEditable && acceptsCommandEdits { pasteAsPlainText(nil) }
        case "z":
            if isEditable && acceptsCommandEdits {
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

    override func performFindPanelAction(_ sender: Any?) {
        dismissCompletions()
        if !onFind() { super.performFindPanelAction(sender) }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChanged(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            history.reset()
            dismissCompletions()
            onFocusChanged(false)
        }
        return accepted
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        editorTrace = nil
        if CommandInputDiagnostics.isEnabled, let window { editorTrace = CommandEditorTrace(window: window) }
        if window == nil {
            completions.setPopupPreparationEnabled(false)
            history.reset()
            dismissCompletions()
        }
        applyFocusRequest()
    }

    override func layout() {
        guard let editorTrace else { super.layout(); return }
        let revisions = editorTrace.begin(.editorLayoutBegin)
        let timing = CommandInputDiagnostics.begin(.editorLayout)
        defer {
            CommandInputDiagnostics.end(timing)
            editorTrace.end(.editorLayoutEnd, revisions: revisions)
        }
        super.layout()
    }

    override func viewWillDraw() {
        _ = editorTrace?.begin(.editorWillDraw)
        super.viewWillDraw()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let editorTrace else { super.draw(dirtyRect); return }
        let draw = editorTrace.beginDraw(dirtyRect, in: self)
        let timing = CommandInputDiagnostics.begin(.editorDraw)
        defer {
            CommandInputDiagnostics.end(timing)
            editorTrace.endDraw(draw)
        }
        super.draw(dirtyRect)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        // TextKit can resize its view while laying out. Avoid entering its
        // layout manager recursively from that frame change.
        guard widthChanged, !heightReportScheduled else { return }
        heightReportScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.heightReportScheduled = false
            self.reportContentHeight()
            // Resizing changes annotation geometry, not the draft or its
            // caret. Preserve valid suggestions and pending debounced work.
            self.updateCompletionPosition()
        }
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard acceptsCommandEdits else { return false }
        let allowed = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if allowed {
            history.willEdit()
            if !history.applying { completions.willEdit() }
        }
        return allowed
    }

    override func didChangeText() {
        editorTrace?.edit(inputID: CommandInputDiagnostics.currentInputID)
        super.didChangeText()
        CommandInputDiagnostics.mark(.textDidChange, id: CommandInputDiagnostics.currentInputID)
        if history.applying {
            completions.externalEdit()
        } else {
            history.willEdit()
            completions.didEdit()
        }
        reportContentHeight()
    }

    func draftWillChangeExternally() { editorTrace?.reset(); history.reset(); completions.externalEdit() }
    func completionSelectionDidChange() { history.selectionChanged(); completions.selectionChanged() }
    func receiveCompletions(_ response: CommandCompletionResponse) { completions.receive(response) }
    func dismissCompletions() { completions.dismiss() }
    func updateCompletionPosition() { completions.updatePosition() }

    var measuredContentHeight: CGFloat {
        let diagnostic = CommandInputDiagnostics.begin(.textMeasurement)
        let revisions = editorTrace?.begin(.editorTextLayoutBegin)
        defer {
            CommandInputDiagnostics.end(diagnostic)
            if let revisions { editorTrace?.end(.editorTextLayoutEnd, revisions: revisions) }
        }
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

    /// Called after the host's layout, in the IOSurface assignment transaction.
    /// Ordinary layout callers keep the deferred path to avoid reentrancy.
    func completePresentedFocusRequest() {
        guard isEditable, let window, window.isKeyWindow,
              !isHiddenOrHasHiddenAncestor, canRequestFocus() else { return }
        if focusRequested, window.makeFirstResponder(self) { focusRequested = false }
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
