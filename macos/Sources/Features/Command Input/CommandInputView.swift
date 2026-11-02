import AppKit

/// AppKit owns the editor and its viewport. The surface host positions this
/// view at the prompt and supplies the available height; text reports its own
/// content height independently of that viewport.
@MainActor
final class CommandInputView: NSView, NSTextViewDelegate {
    let textView: CommandTextView
    let scrollView: CommandEditorScrollView

    var onTextChanged: (String) -> Void = { _ in }
    var onSubmit: (String) -> Bool = { _ in false }
    var onUseTerminal: () -> Void = {}
    var onFocusChanged: (Bool) -> Void = { _ in }
    var onContentHeightChanged: (CGFloat) -> Void = { _ in }
    /// The host checks that this pane still owns the requested activation.
    var canRequestFocus: () -> Bool = { true }

    private var lastFocusRequest: UInt64 = 0
    private var latestHeight: CGFloat = 0
    private var heightReportScheduled = false

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
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = textView
        addSubview(scrollView)

        textView.delegate = self
        textView.onSubmit = { [weak self] text in self?.onSubmit(text) ?? false }
        textView.onUseTerminal = { [weak self] in self?.onUseTerminal() }
        textView.onFocusChanged = { [weak self] focused in self?.onFocusChanged(focused) }
        textView.onContentHeightChanged = { [weak self] height in self?.contentHeightChanged(height) }
        textView.canRequestFocus = { [weak self] in self?.canRequestFocus() ?? false }
        toolTip = "Return runs the command. Shift Return adds a line. Escape returns to terminal input."
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        scrollView.tile()
    }

    /// Acknowledgement and history loading are explicit external edits. Normal
    /// keystrokes stay in NSTextView so their selection and undo groups survive.
    func setDraft(_ text: String) {
        guard textView.string != text else { return }
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        if text.isEmpty { textView.undoManager?.removeAllActions() }
        textView.reportContentHeight()
    }

    func setEditable(_ editable: Bool) {
        textView.isEditable = editable
        textView.isSelectable = true
        textView.applyFocusRequest()
    }

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
        layer?.backgroundColor = backgroundColor.cgColor
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
            self.onContentHeightChanged(self.latestHeight)
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
