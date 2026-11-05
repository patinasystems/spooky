import AppKit

/// AppKit owns the editor and its viewport. The surface host positions this
/// view at the prompt and supplies the available height; text reports its own
/// content height independently of that viewport.
@MainActor
final class CommandInputView: NSView, NSTextViewDelegate {
    static let padding: CGFloat = 6
    let textView: CommandTextView
    let scrollView: CommandEditorScrollView
    private lazy var caret = CommandInputCaret(editor: self)

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
    private let topFade = CAGradientLayer()
    private let bottomFade = CAGradientLayer()
    private var scrollObserver: NSObjectProtocol?

    static func viewportHeight(content: CGFloat, line: CGFloat, terminal: CGFloat, pinned: Bool = false) -> CGFloat {
        let available = max(1, terminal)
        let minimum = pinned ? max(200, line + padding * 2) : line + padding * 2
        let maximum = pinned ? min(available, max(200, available * 0.5)) : available
        return min(max(minimum, content), maximum)
    }

    /// Updated synchronously by TextKit; the notification stays deferred so a
    /// host can use current font metrics before publishing terminal padding.
    var contentHeight: CGFloat { latestHeight + Self.padding * 2 }

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
        // This interior editor is not the window's titlebar-adjacent scroller.
        // Its padding belongs to this view, not AppKit's window safe area.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.scrollerInsets = NSEdgeInsetsZero
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = textView
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateScrollFades()
                self?.caret.update()
            }
        }
        addSubview(scrollView)
        for fade in [topFade, bottomFade] {
            fade.zPosition = 2
            fade.isHidden = true
            fade.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull(),
                            "colors": NSNull(), "locations": NSNull()]
            fade.startPoint = CGPoint(x: 0.5, y: 0)
            fade.endPoint = CGPoint(x: 0.5, y: 1)
            layer?.addSublayer(fade)
        }

        textView.managesInsertionPoint = true
        textView.setPromptIdentity(CommandPromptIdentity.local)
        // The editor owns an opaque, theme-matched viewport. Transparent
        // TextKit drawing can retain its old backing pixels across hide/show
        // until an ancestor display pass, after the terminal has presented.
        textView.drawsBackground = true
        textView.onCaretChanged = { [weak self] in self?.caret.update(restart: true) }
        textView.delegate = self
        textView.onSubmit = { [weak self] text in self?.onSubmit(text) ?? false }
        textView.onUseTerminal = { [weak self] in self?.onUseTerminal() }
        textView.onFind = { [weak self] in self?.onFind() ?? false }
        textView.onFocusChanged = { [weak self] focused in
            self?.onFocusChanged(focused)
            self?.caret.update(restart: true)
        }
        textView.onContentHeightChanged = { [weak self] height in self?.contentHeightChanged(height) }
        textView.onRequestCompletion = { [weak self] in self?.onRequestCompletion($0) }
        textView.onCancelCompletion = { [weak self] in self?.onCancelCompletion() }
        textView.onRequestHistory = { [weak self] in self?.onRequestHistory($0) }
        textView.onCancelHistory = { [weak self] in self?.onCancelHistory() }
        textView.canRequestFocus = { [weak self] in self?.canRequestFocus() ?? false }
        toolTip = "Right or Tab accepts a suggestion. Up/Down selects options. "
            + "Return accepts after menu navigation; otherwise it runs the typed command. "
            + "Up on the first visual line recalls history; Down on the last restores your draft. "
            + "Option Tab inserts a tab. Shift Return adds a line. Type @ for files."
    }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let viewport = NSRect(x: Self.padding, y: Self.padding,
                              width: max(1, bounds.width - Self.padding * 2),
                              height: max(1, bounds.height - Self.padding * 2))
        let resized = scrollView.frame.size != viewport.size
        scrollView.frame = viewport
        scrollView.tile()
        // TextKit may reveal the caret before the host grows/caps this view.
        // Reconcile only an actual viewport resize; ordinary wheel scrolling
        // must never jump back to the selection.
        if resized, window?.firstResponder === textView {
            textView.scrollRangeToVisible(textView.selectedRange())
        }
        updateScrollFades()
        textView.updateCompletionPosition()
        caret.update()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        caret.attach(to: window)
    }

    func completePresentedInput(restartCaret: Bool = true) {
        layoutSubtreeIfNeeded()
        if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
        textView.completePresentedFocusRequest()
        caret.update(restart: restartCaret)
        textView.displayIfNeeded()
    }

    /// Acknowledgement and history loading are explicit external edits. Normal
    /// keystrokes stay in NSTextView so their selection and undo groups survive.
    func setDraft(_ text: String) {
        guard textView.string != text else { return }
        textView.draftWillChangeExternally()
        textView.string = text
        // External acknowledgements bypass didChangeText. Invalidate the old
        // glyphs explicitly, including the transition to an empty document.
        textView.needsDisplay = true
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        if text.isEmpty { textView.undoManager?.removeAllActions() }
        textView.reportContentHeight()
        caret.update(restart: true)
    }

    func setEditable(_ editable: Bool, preserveCaret: Bool = false, preservePresentation: Bool = false) {
        textView.completions.setSubmissionPresentationHeld(preservePresentation)
        if !editable {
            textView.history.reset()
            if !preservePresentation { textView.dismissCompletions() }
        }
        textView.acceptsCommandEdits = editable
        // Disabling NSTextView removes its insertion point, even when focus
        // and geometry stay unchanged. Empty submissions keep the native text
        // system active while the separate ownership gate rejects edits.
        let textKitEditable = editable || preserveCaret || preservePresentation
        if textView.isEditable != textKitEditable { textView.isEditable = textKitEditable }
        if !textView.isSelectable { textView.isSelectable = true }
        textView.applyFocusRequest()
        caret.update()
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
            // Nine retained stops approximate the terminal's C2 quintic ramp.
            // These narrow overlays composite over the opaque editor; no text
            // mask, offscreen rasterization, or scroll-time bitmap is needed.
            let stops = (0...8).map { CGFloat($0) / 8 }
            let colors = stops.map { t -> CGColor in
                let opacity = t * t * t * (t * (t * 6 - 15) + 10)
                return backgroundColor.withAlphaComponent(opacity).cgColor
            }
            topFade.colors = colors
            bottomFade.colors = Array(colors.reversed())
            topFade.locations = stops.map { NSNumber(value: Double($0)) }
            bottomFade.locations = topFade.locations
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
        caret.update(restart: true)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard notification.object as? CommandTextView === textView else { return }
        textView.completionSelectionDidChange()
        caret.update(restart: true)
    }

    private func updateScrollFades() {
        let timing = CommandInputDiagnostics.begin(.editorScrollFades)
        let clip = scrollView.contentView.bounds
        let overflow = scrollView.overflow
        // NSTextView can retain a nonzero frame origin after AppKit tiles it.
        // Both rectangles are in document-superview coordinates; zero is not
        // necessarily the document's top edge.
        let offset = clip.minY - (scrollView.documentView?.frame.minY ?? 0)
        let band = min(max(1, textView.minimumLineHeight) * 1.5, clip.height * 0.5)
        let top = min(band, max(0, offset))
        let bottom = min(band, max(0, overflow - offset))
        let viewport = convert(scrollView.contentView.bounds, from: scrollView.contentView)
        let topFrame = NSRect(x: viewport.minX, y: viewport.maxY - top, width: viewport.width, height: top)
        let bottomFrame = NSRect(x: viewport.minX, y: viewport.minY, width: viewport.width, height: bottom)
        if topFade.frame != topFrame { topFade.frame = topFrame }
        if bottomFade.frame != bottomFrame { bottomFade.frame = bottomFrame }
        if topFade.isHidden != (top <= 0.5) { topFade.isHidden = top <= 0.5 }
        if bottomFade.isHidden != (bottom <= 0.5) { bottomFade.isHidden = bottom <= 0.5 }
        CommandInputDiagnostics.end(timing)
        if CommandInputDiagnostics.isEnabled {
            CommandInputDiagnostics.mark(.editorScroll, id: CommandInputDiagnostics.currentInputID, metrics: [
                "clip_y": clip.minY, "clip_height": clip.height, "overflow": overflow,
                "top_fade": top, "bottom_fade": bottom,
                "top_y": topFade.frame.minY, "bottom_y": bottomFade.frame.minY,
                "view_flipped": isFlipped ? 1 : 0, "layer_flipped": layer?.isGeometryFlipped == true ? 1 : 0,
                "view_height": bounds.height, "document_height": scrollView.documentView?.frame.height ?? 0,
                "inset_top": scrollView.contentInsets.top, "inset_bottom": scrollView.contentInsets.bottom,
                "document_y": scrollView.documentView?.frame.minY ?? 0
            ])
        }
    }

    private func contentHeightChanged(_ height: CGFloat) {
        guard latestHeight != height else { return }
        latestHeight = height
        scrollView.documentContentHeight = height
        scrollView.needsLayout = true
        updateScrollFades()
        guard !heightReportScheduled else { return }
        heightReportScheduled = true
        // TextKit may be laying out while the host changes the editor frame.
        // Deliver one coalesced measurement after the current layout completes.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.heightReportScheduled = false
            self.onContentHeightChanged(self.contentHeight)
            // Paste/newline selection settles after the synchronous TextKit
            // measurement. Reveal it after the host applies the capped size,
            // once per height change, without fighting ordinary wheel scrolls.
            if self.window?.firstResponder === self.textView {
                self.layoutSubtreeIfNeeded()
                self.textView.scrollRangeToVisible(self.textView.selectedRange())
            }
        }
    }
}

/// Keep the document covering the viewport even when TextKit lays out an empty
/// string. Otherwise clicking below its only line hits NSClipView, not the editor.
@MainActor
final class CommandEditorScrollView: NSScrollView {
    var documentContentHeight: CGFloat = 0
    var onTerminalScroll: ((NSEvent) -> Void)?
    // AppKit may refine NSTextView's frame after a measured resize. The real
    // scroll extent, not the earlier text-height estimate, owns wheel routing
    // and fade visibility at the exact scroll limits.
    var overflow: CGFloat { max(0, (documentView?.frame.height ?? 0) - contentView.bounds.height) }

    override func scrollWheel(with event: NSEvent) {
        guard overflow > 0.5 else { onTerminalScroll?(event); return }
        super.scrollWheel(with: event)
    }

    override func tile() {
        super.tile()
        guard let textView = documentView as? CommandTextView else { return }
        let viewportHeight = contentView.bounds.height
        guard viewportHeight > 0 else { return }
        if textView.minSize.height != viewportHeight {
            textView.minSize = NSSize(width: 0, height: viewportHeight)
        }
        let height = max(viewportHeight, documentContentHeight)
        if textView.frame.height != height {
            textView.setFrameSize(NSSize(width: textView.frame.width, height: height))
        }
        let constrained = contentView.constrainBoundsRect(contentView.bounds)
        if constrained.origin != contentView.bounds.origin { contentView.scroll(to: constrained.origin) }
    }
}
