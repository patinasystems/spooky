import AppKit

/// A command is ordinary editable text until the shell accepts its submission.
/// AppKit owns selections, marked text, cursor movement, and the undo stack.
@MainActor
final class CommandTextView: NSTextView {
    var onSubmit: (String) -> Bool = { _ in false }
    var onUseTerminal: () -> Void = {}
    var onFocusChanged: (Bool) -> Void = { _ in }
    var onContentHeightChanged: (CGFloat) -> Void = { _ in }
    private var focusRequestScheduled = false
    private var heightReportScheduled = false
    private let commandUndoManager = UndoManager()
    // NSTextStorage owns its layout manager; retain the root of the text system
    // for editors whose caller did not supply an existing text container.
    private let ownedTextStorage: NSTextStorage?

    // Ghostty's window undo manager also owns closing/reopening tabs and panes.
    // Editing or clearing one draft must never undo or erase those operations.
    override var undoManager: UndoManager? { commandUndoManager }

    /// Focus is requested by token so a SwiftUI update cannot steal focus back
    /// from output selection or another pane. Defer until a window is attached.
    var focusRequested = false {
        didSet { applyFocusRequest() }
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
        textContainerInset = NSSize(width: 8, height: 8)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        // The empty editor must remain a clickable text view after submission.
        // The enclosing scroll view keeps this minimum matched to its viewport.
        minSize = NSSize(width: 0, height: frameRect.height)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
        textContainer?.heightTracksTextView = false
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

    func reportContentHeight() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let height = layoutManager.usedRect(for: textContainer).height
        onContentHeightChanged(ceil(height + textContainerInset.height * 2))
    }

    func applyFocusRequest() {
        guard focusRequested, isEditable, window != nil, !focusRequestScheduled else { return }
        focusRequestScheduled = true
        // First-responder callbacks update the owning SwiftUI state. Request
        // focus outside updateNSView rather than mutating state during it.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusRequestScheduled = false
            guard self.focusRequested, self.isEditable, let window = self.window else { return }
            if window.makeFirstResponder(self) {
                self.focusRequested = false
            }
        }
    }
}
