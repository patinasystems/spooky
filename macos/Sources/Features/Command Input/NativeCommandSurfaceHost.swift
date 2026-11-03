import AppKit
import GhosttyKit

/// AppKit input layout around one full-size Metal surface. Ghostty renders
/// command chrome and output together; TextKit owns native editing.
@MainActor
final class NativeCommandSurfaceHost: NSView {
    private let surfaceView: Ghostty.SurfaceView
    private let terminalView: SurfaceScrollView
    private let session: CommandInputSession
    private let editor = CommandInputView(frame: .zero)
    private var chromePresentation: CommandChromePresentation?
    private struct CursorPresentation: Equatable {
        let enabled: Bool
        let terminalRequested: Bool
        let suppressed: Bool
    }
    private var cursorPresentation: CursorPresentation?
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let editButton = NSButton(title: "Edit Command", target: nil, action: nil)
    private let terminalButton = NSButton(title: "Use Terminal", target: nil, action: nil)
    private let draftButton = NSButton(title: "View Draft", target: nil, action: nil)
    private var measuredHeight: CGFloat = 0
    private var synchronizing = false
    private var background = NSColor.black
    private var docking = CommandInputDocking()
    private let directoryPopover = CommandDirectoryPopover()
    private struct DirectoryAnchor: Equatable {
        let id: String
        let directory: URL
        let rect: NSRect
    }
    private struct DirectoryContext: Equatable {
        let layout: CommandTerminalLayout
        let chrome: CommandChromePresentation
        let bounds: NSRect
    }
    private var directoryAnchor: DirectoryAnchor?
    private var directoryContext: DirectoryContext?

    override var isFlipped: Bool { true }

    init(size: CGSize, surfaceView: Ghostty.SurfaceView, session: CommandInputSession) {
        self.surfaceView = surfaceView
        self.session = session
        terminalView = SurfaceScrollView(contentSize: size, surfaceView: surfaceView)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        clipsToBounds = true
        [terminalView, editor, notice, editButton, terminalButton, draftButton]
            .forEach { addSubview($0) }
        notice.font = .systemFont(ofSize: 11)
        notice.isSelectable = true
        for button in [editButton, terminalButton, draftButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
        }
        editButton.action = #selector(editCommand)
        terminalButton.action = #selector(useTerminal)
        draftButton.action = #selector(viewDraft)
        editor.onTextChanged = { [weak session] in session?.setDraft($0) }
        editor.onSubmit = { [weak session] in session?.submit($0) ?? false }
        editor.onUseTerminal = { [weak session] in session?.useTerminal() }
        editor.onFind = { [weak self] in
            guard let self, self.surfaceView.surface != nil else { return false }
            self.surfaceView.find(nil)
            return true
        }
        editor.onRequestCompletion = { [weak session] in session?.requestCompletion($0) }
        editor.onCancelCompletion = { [weak session] in session?.cancelCompletion() }
        session.onCompletion = { [weak self] in self?.editor.receiveCompletions($0) }
        editor.canRequestFocus = { [weak self] in self?.canFocusEditor ?? false }
        editor.onFocusChanged = { [weak self] focused in
            guard focused, let self else { return }
            self.surfaceView.focusDidChange(false)
            self.surfaceView.setCursorVisibility(true)
            if let controller = self.window?.windowController as? BaseTerminalController,
               controller.focusedSurface !== self.surfaceView {
                controller.focusedSurfaceDidChange(to: self.surfaceView)
            }
        }
        editor.onContentHeightChanged = { [weak self] height in
            guard let self, abs(self.measuredHeight - height) > 0.25 else { return }
            self.measuredHeight = height
            self.synchronize()
        }
        session.onChange = { [weak self] in self?.synchronize() }
        synchronize()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        synchronize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        dismissDirectory()
        synchronize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        dismissDirectory()
        // Let the child surface publish its new core scale first. Logical
        // bounds may be unchanged when moving between 1x and 2x displays.
        DispatchQueue.main.async { [weak self] in
            self?.chromePresentation = nil
            self?.synchronize()
        }
    }

    private var canFocusEditor: Bool {
        guard let window, window.isKeyWindow else { return false }
        if let controller = window.windowController as? BaseTerminalController,
           let focused = controller.focusedSurface { return focused === surfaceView }
        return window.firstResponder === surfaceView || window.firstResponder === editor.textView
    }

    private func synchronize() {
        guard !synchronizing, bounds.width > 0, bounds.height > 0 else { return }
        let measurement = CommandInputDiagnostics.begin(.hostSynchronize)
        defer { CommandInputDiagnostics.end(measurement) }
        synchronizing = true
        defer { synchronizing = false }
        let geometry = session.layout
        let line = max(1, geometry.cellHeight)
        let padding = CommandInputView.padding
        let minimumHeight = line + padding * 2
        let height = min(max(minimumHeight, measuredHeight),
                         max(minimumHeight, min(line * 12 + padding * 2, bounds.height * 0.45)))
        let recovering = session.editorVisible && session.isRecoveringDraft
        let transferring = session.isTransferringSubmission
        let editing = recovering || (session.editorVisible && geometry.primary && session.currentBlockID != nil)
        let placement = docking.placement(layout: geometry, editing: editing, recovering: recovering,
                                           transferring: transferring,
                                           metrics: .init(editorHeight: height, containerHeight: bounds.height, padding: padding))
        let shown = placement.shown

        // Set before resizing/focusing: an unfocused terminal otherwise draws
        // a hollow caret that can move beyond the editor during PTY expansion.
        if let surface = surfaceView.surface {
            let cursor = CursorPresentation(enabled: session.hasNativeIntegration,
                                            terminalRequested: !session.prefersNativeInput,
                                            suppressed: session.prefersNativeInput && ((shown && !recovering) || transferring))
            if cursor != cursorPresentation {
                ghostty_surface_set_native_input_cursor(surface, cursor.enabled, cursor.terminalRequested, cursor.suppressed)
                cursorPresentation = cursor
            }
            let integrated = session.hasNativeIntegration
            ghostty_surface_set_native_input_padding(surface, integrated ? padding : 0,
                                                     integrated ? placement.reservedHeight + padding : 0)
        }

        background = configColor("background", fallback: .black)
        let foreground = configColor("foreground", fallback: .textColor)
        layer?.backgroundColor = background.cgColor
        let terminalFrame = bounds
        if terminalView.frame != terminalFrame {
            terminalView.frame = terminalFrame
            terminalView.needsLayout = true
        }
        // This must finish before submit returns: only then can the session
        // compare applied terminal dimensions with the requested surface size.
        terminalView.layoutSubtreeIfNeeded()

        let chrome = CommandChromePresentation(
            layout: geometry, metadata: session.blockMetadata, currentID: session.currentBlockID,
            pinnedOffset: placement.pinnedOffset,
            recovering: recovering,
            backingScale: surfaceView.convertToBacking(NSSize(width: 1, height: 1)).height)
        if chrome != chromePresentation, let surface = surfaceView.surface {
            chrome.publish(to: surface)
            chromePresentation = chrome
        }
        validateDirectoryAnchor(chrome: chrome)

        if !shown && window?.firstResponder === editor.textView {
            window?.makeFirstResponder(surfaceView)
        }
        editor.isHidden = !shown
        editor.setAccessibilityHidden(!shown)
        // Keep the submitted draft over the old prompt while the PTY expands
        // behind it. Following the terminal cursor here would expose its block
        // caret before ZLE has redisplayed/accepted the submitted buffer.
        let editorFrame = transferring && !editor.frame.isEmpty ? editor.frame
            : NSRect(x: placement.origin.x, y: placement.origin.y,
                     width: max(1, bounds.width - placement.origin.x - max(0, geometry.paddingLeft - padding)), height: height)
        if editor.frame != editorFrame {
            if editor.frame.width != editorFrame.width { editor.dismissCompletions() }
            editor.frame = editorFrame
            editor.needsLayout = true
        }
        // The scroll view retains its full drawable. Only its track ends above
        // the dock, so the live-end thumb cannot hide behind native controls.
        let footerHeight = shown && placement.pinned
            ? max(placement.pinnedOffset, bounds.maxY - editorFrame.minY) : 0
        terminalView.setNativeFooterHeight(footerHeight)
        editor.configureAppearance(font: session.editorFont, textColor: foreground,
                                   backgroundColor: background, minimumLineHeight: line)
        editor.setDraft(session.draft)
        editor.setEditable(session.isEditable && shown && !recovering && !surfaceView.readonly)
        editor.requestFocus(token: shown && canFocusEditor ? session.focusRequest : 0)
        editor.layoutSubtreeIfNeeded()
        layoutNotice(foreground: foreground)
    }

    // Intercept only a real directory-label click on the terminal itself.
    // Scrollbars, branch/status captions, native controls, and terminal text
    // retain their existing event handling. Geometry is resolved at the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        guard target === surfaceView, let event = NSApp.currentEvent,
              event.type == .leftMouseDown, event.window === window,
              directory(at: convert(event.locationInWindow, from: nil)) != nil else { return target }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let anchor = directory(at: convert(event.locationInWindow, from: nil)) else { return }
        directoryAnchor = anchor
        if let chrome = chromePresentation {
            directoryContext = DirectoryContext(layout: session.layout, chrome: chrome, bounds: bounds)
        }
        directoryPopover.show(directory: anchor.directory, anchorRect: anchor.rect, in: self)
    }

    private func directory(at point: NSPoint) -> DirectoryAnchor? {
        guard bounds.contains(point), let surface = surfaceView.surface else { return nil }
        var hit = ghostty_command_path_hit_s()
        guard ghostty_surface_command_path_at(surface, point.x, point.y, &hit) else { return nil }
        let id = withUnsafeBytes(of: hit.id) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) }
        guard let id, let path = session.blockMetadata[id]?.workingDirectory,
              path.hasPrefix("/") else { return nil }
        return DirectoryAnchor(id: id, directory: URL(fileURLWithPath: path, isDirectory: true),
                               rect: NSRect(x: hit.x, y: hit.y, width: hit.width, height: hit.height))
    }

    private func validateDirectoryAnchor(chrome: CommandChromePresentation) {
        guard directoryPopover.isShown, let anchor = directoryAnchor else { return }
        let context = DirectoryContext(layout: session.layout, chrome: chrome, bounds: bounds)
        guard context != directoryContext else { return }
        let center = NSPoint(x: anchor.rect.midX, y: anchor.rect.midY)
        guard directory(at: center) == anchor else {
            dismissDirectory()
            return
        }
        directoryContext = context
    }

    private func dismissDirectory() {
        directoryPopover.dismiss()
        directoryAnchor = nil
        directoryContext = nil
    }

    private func layoutNotice(foreground: NSColor) {
        let message = session.notice
        notice.isHidden = message == nil
        terminalButton.isHidden = message == nil
        draftButton.isHidden = message == nil || session.draft.isEmpty
        editButton.isHidden = message != nil || session.editorVisible || !session.canReturnToEditor
        notice.stringValue = message ?? ""
        notice.textColor = foreground
        notice.backgroundColor = background
        notice.drawsBackground = true
        let width = max(1, min(420, bounds.width - 16))
        let noticeBottom = session.isRecoveringDraft
            ? max(76, editor.frame.minY - session.layout.cellHeight - 8) : bounds.height
        notice.frame = NSRect(x: max(8, bounds.width - width - 8), y: max(0, noticeBottom - 76), width: width, height: 42)
        terminalButton.frame = NSRect(x: max(8, bounds.width - 222), y: max(0, noticeBottom - 30), width: 110, height: 24)
        draftButton.frame = NSRect(x: max(8, bounds.width - 108), y: max(0, noticeBottom - 30), width: 100, height: 24)
        editButton.frame = NSRect(x: max(8, bounds.width - 120), y: max(0, bounds.height - 30), width: 112, height: 24)
    }

    private func configColor(_ key: String, fallback: NSColor) -> NSColor {
        guard let config = (NSApp.delegate as? AppDelegate)?.ghostty.config.config else { return fallback }
        var value = ghostty_config_color_s()
        guard ghostty_config_get(config, &value, key, UInt(key.utf8.count)) else { return fallback }
        return NSColor(srgbRed: CGFloat(value.r) / 255, green: CGFloat(value.g) / 255,
                       blue: CGFloat(value.b) / 255, alpha: 1)
    }

    @objc private func editCommand() { session.useEditor() }
    @objc private func useTerminal() { session.useTerminal() }
    @objc private func viewDraft() { session.showRecoveryDraft() }
}
