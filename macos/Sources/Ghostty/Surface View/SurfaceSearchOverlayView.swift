import AppKit

/// Search stays within its pane. The surrounding view passes clicks through to
/// terminal output; only the small AppKit bar participates in hit testing.
@MainActor
final class SurfaceSearchOverlayView: NSView {
    private weak var surfaceView: Ghostty.SurfaceView?
    private var searchState: Ghostty.OSSurfaceView.SearchState
    private var onClose: () -> Void
    let bar = SurfaceSearchBar()
    private var originWasNative = false
    private var focusScheduled = false
    private var needsInitialFocus = true
    private var pasteboardNeedle: String

    override var isFlipped: Bool { true }

    init(surfaceView: Ghostty.SurfaceView, searchState: Ghostty.OSSurfaceView.SearchState,
         onClose: @escaping () -> Void) {
        self.surfaceView = surfaceView
        self.searchState = searchState
        self.onClose = onClose
        self.pasteboardNeedle = searchState.needle.text
        super.init(frame: .zero)
        addSubview(bar)
        bar.onChange = { [weak self] text, selection in
            guard let self else { return }
            self.pasteboardNeedle = text
            self.searchState.needle = .init(text: text, selection: Range(selection, in: text))
            self.searchState.writePasteboardNeedle()
        }
        bar.onNext = { [weak surfaceView] in _ = surfaceView?.navigateSearchToNext() }
        bar.onPrevious = { [weak surfaceView] in _ = surfaceView?.navigateSearchToPrevious() }
        bar.onFocus = { [weak surfaceView] in surfaceView?.focusDidChange(false) }
        bar.onClose = { [weak self] in self?.close() }
        bar.onEscape = { [weak self] in self?.close() }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(focusSearch(_:)), name: .ghosttySearchFocus, object: surfaceView)
        center.addObserver(self, selector: #selector(applicationActivated),
                           name: NSApplication.didBecomeActiveNotification, object: nil)
        update(searchState: searchState, onClose: onClose)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func layout() {
        super.layout()
        let margin: CGFloat = 8
        let width = max(1, min(370, bounds.width - margin * 2))
        bar.frame = NSRect(x: max(0, bounds.width - width - margin), y: margin,
                           width: width, height: CommandOverlayStyle.rowHeight + CommandOverlayStyle.inset * 2)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && needsInitialFocus {
            needsInitialFocus = false
            requestSearchFocus()
        }
    }

    func update(searchState: Ghostty.OSSurfaceView.SearchState, onClose: @escaping () -> Void) {
        self.searchState = searchState
        self.onClose = onClose
        // Commands such as Search Selection can replace an already-open
        // needle without going through this field's editing delegate.
        if pasteboardNeedle != searchState.needle.text {
            pasteboardNeedle = searchState.needle.text
            searchState.writePasteboardNeedle()
        }
        bar.update(needle: searchState.needle, selected: searchState.selected, total: searchState.total)
    }

    private var ownsPane: Bool {
        guard let window, window.isKeyWindow, let surfaceView, surfaceView.window === window else { return false }
        if let controller = window.windowController as? BaseTerminalController,
           let focused = controller.focusedSurface { return focused === surfaceView }
        return true
    }

    private func requestSearchFocus() {
        guard ownsPane, !focusScheduled, let window else { return }
        if !bar.ownsFocus(in: window) { originWasNative = window.firstResponder is CommandTextView }
        let previous = window.firstResponder
        focusScheduled = true
        DispatchQueue.main.async { [weak self, weak previous] in
            guard let self else { return }
            self.focusScheduled = false
            guard self.ownsPane, self.superview != nil, let window = self.window,
                  window.firstResponder === previous || self.bar.ownsFocus(in: window) else { return }
            if window.makeFirstResponder(self.bar.field) {
                self.surfaceView?.focusDidChange(false)
                self.bar.selectNeedle()
            }
        }
    }

    func restoreOriginFocus() {
        guard ownsPane, let window, bar.ownsFocus(in: window), let surfaceView else { return }
        // Remove focus from the field editor before SwiftUI removes its host.
        // A deferred native focus request then has a stable previous responder.
        window.makeFirstResponder(surfaceView)
        if originWasNative, surfaceView.commandInputSession?.focusEditorIfActive() == true { return }
    }

    private func close() {
        restoreOriginFocus()
        onClose()
    }

    @objc private func focusSearch(_ notification: Notification) { requestSearchFocus() }

    @objc private func applicationActivated() { searchState.readPasteboardNeedle() }
}

/// Plain AppKit controls with callbacks; search parsing and debounce remain in
/// the existing surface search state rather than the presentation layer.
@MainActor
final class SurfaceSearchBar: NSView, NSTextFieldDelegate {
    let field = SurfaceSearchField()
    let count = NSTextField(labelWithString: "")
    var onChange: (String, NSRange) -> Void = { _, _ in }
    var onNext: () -> Void = {}
    var onPrevious: () -> Void = {}
    var onClose: () -> Void = {}
    var onEscape: () -> Void = {}
    var onFocus: () -> Void = {}
    private let icon = NSImageView()
    private let next = NSButton()
    private let previous = NSButton()
    private let closeButton = NSButton()
    private var needle = Ghostty.OSSurfaceView.SearchState.Needle.empty

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CommandOverlayStyle.cornerRadius
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        [icon, field, count, next, previous, closeButton].forEach { addSubview($0) }
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyDown
        field.placeholderString = "Find in terminal"
        field.font = .systemFont(ofSize: 13)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        field.onFocus = { [weak self] in self?.onFocus() }
        field.setAccessibilityLabel("Find in terminal")
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.alignment = .right
        count.setAccessibilityLabel("Search results")
        configure(next, symbol: "chevron.up", label: "Next match", action: #selector(nextMatch))
        configure(previous, symbol: "chevron.down", label: "Previous match", action: #selector(previousMatch))
        configure(closeButton, symbol: "xmark", label: "Close search", action: #selector(closeSearch))
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateColors()
    }

    override func layout() {
        super.layout()
        let inset = CommandOverlayStyle.inset
        let row = CommandOverlayStyle.rowHeight
        icon.frame = NSRect(x: inset + 6, y: inset + 8, width: 14, height: 14)
        closeButton.frame = NSRect(x: bounds.width - inset - row, y: inset, width: row, height: row)
        previous.frame = closeButton.frame.offsetBy(dx: -row, dy: 0)
        next.frame = previous.frame.offsetBy(dx: -row, dy: 0)
        let countWidth = min(64, max(36, count.intrinsicContentSize.width + 4))
        count.frame = NSRect(x: next.frame.minX - countWidth - 4, y: inset + 8, width: countWidth, height: 16)
        field.frame = NSRect(x: inset + 28, y: inset + 6,
                             width: max(1, count.frame.minX - inset - 36), height: 20)
    }

    func update(needle: Ghostty.OSSurfaceView.SearchState.Needle, selected: UInt?, total: UInt?) {
        let needleChanged = self.needle != needle
        self.needle = needle
        if field.stringValue != needle.text { field.stringValue = needle.text }
        if needleChanged, let selection = needle.selection, let editor = field.currentEditor() as? NSTextView {
            editor.setSelectedRange(NSRange(selection, in: needle.text))
        }
        count.stringValue = if let selected {
            "\(selected + 1)/\(total.map(String.init) ?? "?")"
        } else if let total { "–/\(total)" } else { "" }
        next.isEnabled = total != 0
        previous.isEnabled = total != 0
        needsLayout = true
    }

    func ownsFocus(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        return responder === field || responder === field.currentEditor()
            || responder === next || responder === previous || responder === closeButton
    }

    func selectNeedle() {
        if let selection = needle.selection {
            (field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(selection, in: needle.text))
        } else {
            field.selectText(nil)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        let selection = (field.currentEditor() as? NSTextView)?.selectedRange()
            ?? NSRange(location: field.stringValue.utf16.count, length: 0)
        onChange(field.stringValue, selection)
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        // AppKit can deliver key equivalents to the terminal sibling first.
        // Explicit ownership prevents a stale terminal focus flag consuming
        // Paste before this field's native editing handler sees it.
        onFocus()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        return handleCommand(commandSelector, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
    }

    func handleCommand(_ command: Selector, modifiers: NSEvent.ModifierFlags) -> Bool {
        if command == #selector(NSResponder.insertNewline(_:))
            || command == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
            || command == #selector(NSResponder.insertLineBreak(_:)) {
            if modifiers.contains(.shift) { onPrevious() } else { onNext() }
            return true
        }
        if command == #selector(NSResponder.cancelOperation(_:)) {
            onEscape()
            return true
        }
        return false
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .inline
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    private func updateColors() {
        CommandOverlayStyle.apply(to: self)
        field.textColor = CommandOverlayStyle.primaryText
        count.textColor = CommandOverlayStyle.secondaryText
        icon.contentTintColor = CommandOverlayStyle.secondaryText
        [next, previous, closeButton].forEach { $0.contentTintColor = CommandOverlayStyle.secondaryText }
    }

    @objc private func nextMatch() { onNext() }
    @objc private func previousMatch() { onPrevious() }
    @objc private func closeSearch() { onClose() }
}

/// Keep standard editing keys in the active search field editor instead of
/// forwarding them to Ghostty's configurable terminal menu actions.
@MainActor
final class SurfaceSearchField: NSTextField {
    var onFocus: () -> Void = {}
    private let editingPasteboard: NSPasteboard
    private let editingUndoManager = UndoManager()

    override var undoManager: UndoManager? { editingUndoManager }

    init(pasteboard: NSPasteboard = .general) {
        editingPasteboard = pasteboard
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus() }
        return accepted
    }

    // NSTextField is the shared field editor's delegate while it is active.
    // Give search its own undo history, separate from terminal close/reopen.
    @objc(undoManagerForTextView:)
    func undoManagerForFieldEditor(_ editor: NSTextView) -> UndoManager? { editingUndoManager }

    override func textShouldBeginEditing(_ textObject: NSText) -> Bool {
        if let editor = textObject as? NSTextView { editor.allowsUndo = true }
        return super.textShouldBeginEditing(textObject)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let editor = currentEditor() as? NSTextView,
              window?.firstResponder === editor, !editor.hasMarkedText() else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers == .command || modifiers == [.command, .shift] else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a" where modifiers == .command:
            editor.selectAll(nil)
        case "c" where modifiers == .command:
            _ = copySelection(from: editor)
        case "x" where modifiers == .command:
            if isEditable && copySelection(from: editor) {
                editor.insertText("", replacementRange: editor.selectedRange())
            }
        case "v" where modifiers == .command:
            if isEditable { _ = editor.readSelection(from: editingPasteboard, type: .string) }
        case "z":
            if isEditable {
                if modifiers.contains(.shift) { editingUndoManager.redo() } else { editingUndoManager.undo() }
            }
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    private func copySelection(from editor: NSTextView) -> Bool {
        let selection = editor.selectedRange()
        let text = editor.string as NSString
        guard selection.location != NSNotFound, selection.length > 0,
              selection.location <= text.length, selection.length <= text.length - selection.location else { return false }
        // NSTextView's low-level writeSelection expects pasteboard types to
        // have been declared by its caller. Publish the plain search text
        // explicitly, including when another app last owned the pasteboard.
        editingPasteboard.clearContents()
        return editingPasteboard.setString(text.substring(with: selection), forType: .string)
    }
}
