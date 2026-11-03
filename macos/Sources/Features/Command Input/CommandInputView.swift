import AppKit

/// AppKit owns the editor and its viewport. The surface host positions this
/// view at the prompt and supplies the available height; text reports its own
/// content height independently of that viewport.
@MainActor
final class CommandInputView: NSView, NSTextViewDelegate {
    static let padding: CGFloat = 6
    let textView: CommandTextView
    let scrollView: CommandEditorScrollView

    var onTextChanged: (String) -> Void = { _ in }
    var onSubmit: (String) -> Bool = { _ in false }
    var onUseTerminal: () -> Void = {}
    var onFind: () -> Bool = { false }
    var onFocusChanged: (Bool) -> Void = { _ in }
    var onContentHeightChanged: (CGFloat) -> Void = { _ in }
    var onRequestCompletion: (CommandCompletionRequest) -> Void = { _ in }
    var onCancelCompletion: () -> Void = {}
    var onRequestHistory: (CommandHistoryRequest) -> Void = { _ in }
    var onCancelHistory: () -> Void = {}
    /// The host checks that this pane still owns the requested activation.
    var canRequestFocus: () -> Bool = { true }

    private var lastFocusRequest: UInt64 = 0
    private var latestHeight: CGFloat = 0
    private var heightReportScheduled = false
    private var configuredBackgroundColor: NSColor?

    override init(frame frameRect: NSRect) {
        let contentFrame = NSRect(origin: .zero, size: frameRect.size)
        textView = CommandTextView(frame: contentFrame, textContainer: nil)
        scrollView = CommandEditorScrollView(frame: contentFrame)
        super.init(frame: frameRect)

        wantsLayer = true
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = textView
        addSubview(scrollView)

        textView.delegate = self
        textView.onSubmit = { [weak self] text in self?.onSubmit(text) ?? false }
        textView.onUseTerminal = { [weak self] in self?.onUseTerminal() }
        textView.onFind = { [weak self] in self?.onFind() ?? false }
        textView.onFocusChanged = { [weak self] focused in self?.onFocusChanged(focused) }
        textView.onContentHeightChanged = { [weak self] height in self?.contentHeightChanged(height) }
        textView.onRequestCompletion = { [weak self] in self?.onRequestCompletion($0) }
        textView.onCancelCompletion = { [weak self] in self?.onCancelCompletion() }
        textView.onRequestHistory = { [weak self] in self?.onRequestHistory($0) }
        textView.onCancelHistory = { [weak self] in self?.onCancelHistory() }
        textView.canRequestFocus = { [weak self] in self?.canRequestFocus() ?? false }
        toolTip = "Right accepts a suggestion. Tab or Down opens options; Tab or Return accepts. "
            + "Up on the first visual line recalls history; Down on the last restores your draft. "
            + "Option Tab inserts a tab. Shift Return adds a line. Type @ for files."
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        scrollView.frame = NSRect(x: Self.padding, y: Self.padding,
                                  width: max(1, bounds.width - Self.padding * 2),
                                  height: max(1, bounds.height - Self.padding * 2))
        scrollView.tile()
        textView.updateCompletionPosition()
    }

    /// Acknowledgement and history loading are explicit external edits. Normal
    /// keystrokes stay in NSTextView so their selection and undo groups survive.
    func setDraft(_ text: String) {
        guard textView.string != text else { return }
        textView.draftWillChangeExternally()
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        if text.isEmpty { textView.undoManager?.removeAllActions() }
        textView.reportContentHeight()
    }

    func setEditable(_ editable: Bool) {
        if !editable { textView.history.reset(); textView.dismissCompletions() }
        if textView.isEditable != editable { textView.isEditable = editable }
        if !textView.isSelectable { textView.isSelectable = true }
        textView.applyFocusRequest()
    }

    func receiveCompletions(_ response: CommandCompletionResponse) { textView.receiveCompletions(response) }
    func receiveHistory(_ response: CommandHistoryResponse) { textView.history.receive(response) }
    func setHistoryContext(_ promptID: String?) { textView.history.setContext(promptID) }

    func dismissCompletions() { textView.dismissCompletions() }

    /// Zero cancels a pending request. Nonzero tokens must be monotonically
    /// increasing per surface; unchanged tokens never steal focus back.
    func requestFocus(token: UInt64) {
        guard token != lastFocusRequest else { return }
        lastFocusRequest = token
        textView.focusRequested = token != 0
    }

    func configureAppearance(
        font: NSFont,
        textColor: NSColor,
        backgroundColor: NSColor,
        minimumLineHeight: CGFloat
    ) {
        if configuredBackgroundColor != backgroundColor {
            configuredBackgroundColor = backgroundColor
            layer?.backgroundColor = backgroundColor.cgColor
            // The editor is a sibling of the terminal's scroll view, so it
            // does not inherit that view's background-matched appearance.
            // Native pointers, selections, and scrollers need the same match.
            let name: NSAppearance.Name = backgroundColor.isLightColor ? .aqua : .darkAqua
            if appearance?.name != name { appearance = NSAppearance(named: name) }
        }
        textView.configureAppearance(
            font: font, textColor: textColor,
            backgroundColor: backgroundColor,
            minimumLineHeight: minimumLineHeight
        )
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? CommandTextView === textView else { return }
        onTextChanged(textView.string)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard notification.object as? CommandTextView === textView else { return }
        textView.completionSelectionDidChange()
    }

    private func contentHeightChanged(_ height: CGFloat) {
        guard latestHeight != height else { return }
        latestHeight = height
        guard !heightReportScheduled else { return }
        heightReportScheduled = true
        // TextKit may be laying out while the host changes the editor frame.
        // Deliver one coalesced measurement after the current layout completes.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.heightReportScheduled = false
            self.onContentHeightChanged(self.latestHeight + Self.padding * 2)
        }
    }
}

/// Keep the document covering the viewport even when TextKit lays out an empty
/// string. Otherwise clicking below its only line hits NSClipView, not the editor.
@MainActor
final class CommandEditorScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let textView = documentView as? CommandTextView else { return }
        let viewportHeight = contentView.bounds.height
        guard viewportHeight > 0 else { return }
        if textView.minSize.height != viewportHeight {
            textView.minSize = NSSize(width: 0, height: viewportHeight)
        }
        if textView.frame.height < viewportHeight {
            textView.setFrameSize(NSSize(width: textView.frame.width, height: viewportHeight))
        }
    }
}
