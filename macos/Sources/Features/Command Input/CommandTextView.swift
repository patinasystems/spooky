import AppKit

/// A command is ordinary editable text until the shell accepts its submission.
/// AppKit owns selections, marked text, cursor movement, and the undo stack.
@MainActor
final class CommandTextView: NSTextView {
    var onSubmit: (String) -> Bool = { _ in false }
    var onUseTerminal: () -> Void = {}
    var onFocusChanged: (Bool) -> Void = { _ in }
    var onContentHeightChanged: (CGFloat) -> Void = { _ in }
    var canRequestFocus: () -> Bool = { true }
    private var focusRequestScheduled = false
    private var focusRequestRevision: UInt64 = 0
    private var heightReportScheduled = false
    private let commandUndoManager = UndoManager()
    // NSTextStorage owns its layout manager; retain the root of the text system
    // for editors whose caller did not supply an existing text container.
    private let ownedTextStorage: NSTextStorage?
    private(set) var minimumLineHeight: CGFloat = 0

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
            super.keyDown(with: event)
            return
        }

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
        if self.font != font { self.font = font }
        if self.textColor != textColor { self.textColor = textColor }
        insertionPointColor = textColor
        self.backgroundColor = backgroundColor
        let lineHeight = max(0, minimumLineHeight)
        if self.minimumLineHeight != lineHeight {
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
        reportContentHeight()
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
        if accepted { onFocusChanged(false) }
        return accepted
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyFocusRequest()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // TextKit can resize its view while laying out. Avoid entering its
        // layout manager recursively from that frame change.
        guard !heightReportScheduled else { return }
        heightReportScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.heightReportScheduled = false
            self.reportContentHeight()
        }
    }

    override func didChangeText() {
        super.didChangeText()
        reportContentHeight()
    }

    var measuredContentHeight: CGFloat {
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
