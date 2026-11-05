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
        let surface: ghostty_surface_t
        let enabled: Bool
        let terminalRequested: Bool
        let suppressed: Bool
    }
    private var cursorPresentation: CursorPresentation?
    private struct AccentPresentation: Equatable {
        let surface: ghostty_surface_t
        let enabled: Bool
        let color: CommandInputAccent?
    }
    private var resolvedAccent: CommandInputAccent?
    private var configuredTheme: CommandUITheme?
    private var accentPresentation: AccentPresentation?
    private struct ViewportPresentation: Equatable {
        let surface: ghostty_surface_t
        let height: CGFloat
        let coveredRows: UInt32
        let transferring: Bool
        let backingScale: CGFloat
    }
    private var viewportPresentation: ViewportPresentation?
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let editButton = NSButton(title: "Edit Command", target: nil, action: nil)
    private let terminalButton = NSButton(title: "Use Terminal", target: nil, action: nil)
    private let draftButton = NSButton(title: "View Draft", target: nil, action: nil)
    private var synchronizing = false
    private var observedLayoutSize: NSSize?
    private var background = NSColor.black
    private var docking = CommandInputDocking()
    private var diagnosticLayout: [String: Double]?
    private let pathResolver = CommandPathResolver()
    private lazy var paths = makePathInteraction()
    private let workspaceNotifications = NSWorkspace.shared.notificationCenter

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
        editButton.toolTip = "Return to native input (⌘⌥Return)"
        terminalButton.action = #selector(useTerminal)
        draftButton.action = #selector(viewDraft)
        editor.onTextChanged = { [weak session] in session?.setDraft($0) }
        editor.onSubmit = { [weak session] in session?.submit($0) ?? false }
        editor.onUseTerminal = { [weak session] in session?.useTerminal() }
        editor.scrollView.onTerminalScroll = { [weak surfaceView] in surfaceView?.scrollWheel(with: $0) }
        editor.onFind = { [weak self] in
            guard let self, self.surfaceView.surface != nil else { return false }
            self.surfaceView.find(nil)
            return true
        }
        editor.onRequestCompletion = { [weak session] in session?.requestCompletion($0) }
        editor.onCancelCompletion = { [weak session] in session?.cancelCompletion() }
        session.onCompletion = { [weak self] in self?.editor.receiveCompletions($0) }
        editor.onRequestHistory = { [weak session] in session?.requestHistory($0) }
        editor.onCancelHistory = { [weak session] in session?.cancelHistory() }
        session.onHistory = { [weak self] in self?.editor.receiveHistory($0) }
        editor.canRequestFocus = { [weak self] in self?.canFocusEditor ?? false }
        editor.onFocusChanged = { [weak self] focused in
            guard let self else { return }
            if focused {
                self.surfaceView.setCursorVisibility(true)
                if let controller = self.window?.windowController as? BaseTerminalController,
                   controller.focusedSurface !== self.surfaceView {
                    controller.focusedSurfaceDidChange(to: self.surfaceView)
                }
            }
            // AppKit updates firstResponder after become/resign returns. Read
            // ownership then, including search fields, other panes and windows.
            DispatchQueue.main.async { [weak self] in
                (self?.window?.windowController as? BaseTerminalController)?.syncFocusToSurfaceTree()
            }
        }
        editor.onContentHeightChanged = { [weak self] _ in self?.synchronize() }
        session.onChange = { [weak self] in self?.synchronize() }
        editor.textView.onDeferredPromptKey = { [weak session] in session?.deferPromptKey($0) ?? false }
        editor.textView.onTerminalKey = { [weak self] in self?.surfaceView.keyDown(with: $0) }
        session.onReplayPromptKey = { [weak self] event, inputID in
            guard let self else { return }
            CommandInputDiagnostics.withInputID(inputID) {
                if self.session.isEditable { self.editor.textView.keyDown(with: event) } else {
                    self.surfaceView.keyDown(with: event)
                }
            }
        }
        session.onPromptPresented = { [weak self] in
            guard let self else { return }
            self.editor.completePresentedInput()
        }
        session.onFramePresented = { [weak self] in
            guard let self else { return }
            // Executed inside the IOSurface's explicit transaction. AppKit
            // must publish the retired editor/empty prompt backing stores now,
            // not at a separate display pass after Metal has already changed.
            self.layoutSubtreeIfNeeded()
            self.displayIfNeeded()
        }
        surfaceView.commandPathInteraction = paths
        NotificationCenter.default.addObserver(self, selector: #selector(pathViewportChanged),
                                               name: .ghosttyDidUpdateScrollbar, object: surfaceView)
        NotificationCenter.default.addObserver(self, selector: #selector(systemColorsChanged),
                                               name: .spookyCommandThemeDidChange, object: surfaceView)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didResizeNotification,
                     NSWindow.didChangeScreenNotification, NSWindow.didChangeOcclusionStateNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(submissionWindowChanged(_:)), name: name, object: nil)
        }
        workspaceNotifications.addObserver(self, selector: #selector(submissionSpaceChanged),
                                           name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        refreshAccent()
        synchronize()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        workspaceNotifications.removeObserver(self)
    }

    override func layout() {
        super.layout()
        let sizeChanged = observedLayoutSize != bounds.size
        observedLayoutSize = bounds.size
        synchronize()
        if sizeChanged { session.terminalGeometryChanged() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        session.cancelSubmissionVisualHold()
        paths.pointerExited()
        refreshAccent()
        synchronize()
        if window != nil { session.terminalGeometryChanged() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAccent()
    }

    @objc private func systemColorsChanged() { refreshAccent() }

    private func refreshAccent() {
        let theme = surfaceView.derivedConfig.commandUITheme
        guard theme != configuredTheme else { publishAccent(); return }
        configuredTheme = theme
        resolvedAccent = CommandInputAccent.resolve(theme.accent, appearance: effectiveAppearance)
        editor.textView.applyTheme(theme)
        paths.theme = theme
        [editButton, terminalButton, draftButton].forEach { $0.contentTintColor = theme.accent }
        publishAccent()
        synchronize()
    }

    @objc private func submissionWindowChanged(_ notification: Notification) {
        guard let changed = notification.object as? NSWindow, changed === window else { return }
        session.cancelSubmissionVisualHold()
        if notification.name == NSWindow.didResignKeyNotification {
            editor.dismissCompletions()
            editor.requestFocus(token: 0)
        }
        if notification.name == NSWindow.didBecomeKeyNotification, canFocusEditor {
            _ = session.focusEditorIfActive()
        }
        if notification.name == NSWindow.didChangeOcclusionStateNotification,
           changed.occlusionState.contains(.visible) {
            session.terminalBecameVisible()
        }
    }

    @objc private func submissionSpaceChanged() {
        editor.dismissCompletions()
        session.cancelSubmissionVisualHold()
        if window?.isOnActiveSpace == true { session.terminalBecameVisible() }
    }

    private func publishAccent() {
        guard let surface = surfaceView.surface else { accentPresentation = nil; return }
        let value = AccentPresentation(surface: surface, enabled: session.hasNativeIntegration, color: resolvedAccent)
        guard value != accentPresentation else { return }
        ghostty_surface_set_native_input_accent(surface, value.enabled && value.color != nil,
                                               value.color?.red ?? 0, value.color?.green ?? 0, value.color?.blue ?? 0)
        accentPresentation = value
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        session.cancelSubmissionVisualHold()
        // Let the child surface publish its new core scale first. Logical
        // bounds may be unchanged when moving between 1x and 2x displays.
        DispatchQueue.main.async { [weak self] in
            self?.chromePresentation = nil
            self?.viewportPresentation = nil
            self?.paths.pointerExited()
            self?.synchronize()
            self?.session.terminalGeometryChanged()
        }
    }

    static func focusedEditor(for surface: Ghostty.SurfaceView) -> NSView? {
        var ancestor = surface.superview
        while let view = ancestor {
            if let host = view as? NativeCommandSurfaceHost { return host.editor.textView }
            ancestor = view.superview
        }
        return nil
    }

    private var footerHitTop: CGFloat?

    private var canFocusEditor: Bool {
        guard let window, window.isKeyWindow else { return false }
        if let controller = window.windowController as? BaseTerminalController,
           let focused = controller.focusedSurface, focused !== surfaceView { return false }
        return NativeCommandFocus.canRestoreEditor(firstResponder: window.firstResponder,
                                                  window: window, surface: surfaceView, editor: editor.textView)
    }

    private func synchronize() {
        guard !synchronizing, bounds.width > 0, bounds.height > 0 else { return }
        let measurement = CommandInputDiagnostics.begin(.hostSynchronize)
        defer { CommandInputDiagnostics.end(measurement) }
        synchronizing = true
        defer { synchronizing = false }
        publishAccent()
        let geometry = session.layout
        let line = max(1, geometry.cellHeight)
        let padding = CommandInputView.padding
        let theme = surfaceView.derivedConfig.commandUITheme
        background = theme.background
        let foreground = theme.foreground
        layer?.backgroundColor = background.cgColor
        // Font and draft measurements update immediately; their callbacks stay
        // deferred. Never resize the PTY using a stale default-font height and
        // correct it one run-loop turn later across a terminal-row boundary.
        let holdingPresentation = session.isHoldingSubmissionPresentation
        editor.configureAppearance(font: session.editorFont, textColor: foreground,
                                   backgroundColor: background, minimumLineHeight: line)
        if !holdingPresentation { editor.setDraft(session.draft) }
        let minimumHeight = line + padding * 2
        let preparedHeight = session.canPrepareNativePrompt && holdingPresentation
            ? minimumHeight : editor.contentHeight
        let height = CommandInputView.viewportHeight(content: preparedHeight, line: line, terminal: bounds.height)
        let recovering = session.editorVisible && session.isRecoveringDraft
        let transferring = session.isTransferringSubmission || holdingPresentation
        let preparing = session.canPrepareNativePrompt && !recovering
        let editing = recovering || holdingPresentation || ((session.editorVisible || preparing) && geometry.primary && session.currentBlockID != nil)
        // Evaluate the prospective inline grid, excluding the dock's own
        // reservation. Retained rows alone can come from an earlier resize.
        let inlineReservation = max(0, height - line) + padding
        let availableInset = max(0, geometry.unreservedGridHeight - line * 2)
        let inlineRows = UInt32(max(0, floor((geometry.unreservedGridHeight
            - min(inlineReservation, availableInset)) / line)))
        let requestedSize = surfaceView.surface.map { ghostty_surface_size($0) }
        let geometryIsSettled = terminalView.frame == bounds && !terminalView.needsLayout
            && (requestedSize.map { UInt32($0.rows) == geometry.rows && UInt32($0.columns) == geometry.columns } ?? false)
        let placement = docking.placement(layout: geometry, editing: editing, recovering: recovering,
                                           transferring: transferring && !preparing,
                                           metrics: .init(editorHeight: height, containerHeight: bounds.height,
                                                          padding: padding, inlineRows: inlineRows,
                                                          geometryIsSettled: geometryIsSettled))
        let shown = placement.shown && (session.editorVisible || holdingPresentation)
            && !(transferring && session.submittedEditorRetired)

        // Set before resizing/focusing: an unfocused terminal otherwise draws
        // a hollow caret that can move beyond the editor during PTY expansion.
        if let surface = surfaceView.surface {
            let cursor = CursorPresentation(surface: surface, enabled: session.hasNativeIntegration,
                                            terminalRequested: !session.prefersNativeInput,
                                            suppressed: session.prefersNativeInput
                                                && ((shown && !recovering) || transferring || session.suppressesShellCursor))
            if cursor != cursorPresentation {
                ghostty_surface_set_native_input_cursor(surface, cursor.enabled, cursor.terminalRequested, cursor.suppressed)
                cursorPresentation = cursor
            }
            let integrated = session.hasNativeIntegration
            let viewport = ViewportPresentation(
                surface: surface,
                height: placement.shown && placement.pinned && !recovering ? placement.pinnedOffset : 0,
                coveredRows: placement.coveredRows, transferring: transferring && !preparing,
                backingScale: surfaceView.convertToBacking(NSSize(width: 1, height: 1)).height)
            if viewport != viewportPresentation {
                ghostty_surface_set_native_input_viewport(surface, viewport.height,
                                                         viewport.coveredRows, viewport.transferring)
                viewportPresentation = viewport
            }
            if !(session.isAwaitingInitialNativePrompt && ghostty_surface_native_input_bootstrap(surface)) {
                // A one-line native prompt returns after normal commands.
                // Keep its small reservation through C/D instead of issuing
                // an expand/shrink resize pair for every fast submission.
                let promptReservation = geometry.primary && session.prefersNativeInput
                    ? max(0, minimumHeight - line) : 0
                ghostty_surface_set_native_input_padding(surface, integrated ? padding : 0,
                    integrated ? max(placement.reservedHeight, promptReservation) + padding : 0)
            }
        } else {
            cursorPresentation = nil
            viewportPresentation = nil
        }

        let terminalFrame = bounds
        if terminalView.frame != terminalFrame {
            terminalView.frame = terminalFrame
            terminalView.needsLayout = true
        }
        // This must finish before submit returns: only then can the session
        // compare applied terminal dimensions with the requested surface size.
        terminalView.layoutSubtreeIfNeeded()

        // Protocol readiness can precede parsed B. Keep the caption tied to
        // the draft that is actually on screen until both can advance together.
        let chromeID = preparing ? session.currentBlockID
            : (editing || transferring ? session.presentedBlockID : session.currentBlockID)
        let chrome = CommandChromePresentation(
            layout: geometry, metadata: session.blockMetadata, currentID: chromeID,
            pinnedOffset: placement.pinnedOffset,
            recovering: recovering,
            backingScale: surfaceView.convertToBacking(NSSize(width: 1, height: 1)).height)
        if chrome != chromePresentation, let surface = surfaceView.surface {
            chrome.publish(to: surface)
            chromePresentation = chrome
        }

        if !shown && window?.firstResponder === editor.textView {
            window?.makeFirstResponder(surfaceView)
        }
        editor.isHidden = !shown
        editor.setAccessibilityHidden(!shown)
        // Keep the submitted draft over the old prompt until the terminal
        // parses the ownership boundary. Following an intermediate cursor
        // would move the editor before the shell has accepted the buffer.
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
        footerHitTop = footerHeight > 0 ? bounds.height - footerHeight : nil
        editor.setHistoryContext(session.historyContext)
        // Raw metadata: a valid directory name may itself end in a newline.
        let cwd = session.currentBlockID.flatMap { session.blockMetadata[$0]?.workingDirectory }
        let fileSearchDirectory = cwd.flatMap { $0.hasPrefix("/") ? $0 : nil }
        if editor.textView.fileSearchDirectory != fileSearchDirectory {
            editor.textView.fileSearchDirectory = fileSearchDirectory
        }
        let editable = session.isEditable && shown && !recovering && !surfaceView.readonly
        editor.setEditable(editable, preserveCaret: transferring && session.draft.isEmpty
                           && shown && !recovering && !surfaceView.readonly,
                           preservePresentation: holdingPresentation && shown)
        editor.textView.completions.setPopupPreparationEnabled(editable)
        editor.requestFocus(token: shown && canFocusEditor ? session.focusRequest : 0)
        editor.layoutSubtreeIfNeeded()
        // A geometry snapshot can recover a presentation acknowledgement
        // before its callback arrives. Finish the same owned focus request
        // here too, rather than waiting for another key or layout turn.
        if editable { editor.completePresentedInput(restartCaret: false) }
        layoutNotice(foreground: foreground)
        paths.refresh()
        if CommandInputDiagnostics.isEnabled {
            let values: [String: Double] = [
                "requested_rows": Double(requestedSize?.rows ?? 0), "core_rows": Double(geometry.rows),
                "editing": editing ? 1 : 0, "transferring": transferring ? 1 : 0,
                "pinned": placement.pinned ? 1 : 0, "shown": shown ? 1 : 0,
                "reserved_height": placement.reservedHeight, "pinned_offset": placement.pinnedOffset,
                "editor_y": editorFrame.minY, "editor_height": editorFrame.height,
                "padding_top": geometry.paddingTop, "cursor_y": geometry.cursorY,
                "scrollback_rows": Double(geometry.scrollbackRows), "container_height": bounds.height
            ]
            if values != diagnosticLayout {
                diagnosticLayout = values
                CommandInputDiagnostics.mark(.hostLayout, id: CommandInputDiagnostics.currentInputID, metrics: values)
            }
        }
    }

    // Native controls and scrollbars retain their normal hit targets. A path
    // claims only a validated click; a drag is replayed into terminal selection.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        guard target === surfaceView, let event = NSApp.currentEvent,
              event.window === window else { return target }
        let isClick = event.type == .leftMouseDown ||
            (event.type == .rightMouseDown && event.modifierFlags.contains(.control))
        let location = convert(event.locationInWindow, from: nil)
        if let footerHitTop, location.y >= footerHitTop,
           [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) { return self }
        guard isClick, paths.claimsClick(at: location, modifiers: event.modifierFlags,
                                        clickCount: event.clickCount) else { return target }
        return self
    }

    override func scrollWheel(with event: NSEvent) { surfaceView.scrollWheel(with: event) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount > 1, let footerHitTop,
           convert(event.locationInWindow, from: nil).y >= footerHitTop {
            paths.pointerExited()
            return
        }
        if let surface = surfaceView.surface { ghostty_surface_cancel_native_submission(surface) }
        paths.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) { paths.mouseUp(with: event) }
    override func mouseDragged(with event: NSEvent) { paths.mouseDragged(with: event) }
    override func rightMouseUp(with event: NSEvent) { paths.mouseUp(with: event) }
    override func rightMouseDragged(with event: NSEvent) { paths.mouseDragged(with: event) }

    override func rightMouseDown(with event: NSEvent) {
        // AppKit can deliver Control-click through the contextual-click path.
        guard event.modifierFlags.contains(.control) else {
            super.rightMouseDown(with: event)
            return
        }
        mouseDown(with: event)
    }

    private func makePathInteraction() -> CommandPathInteractionController {
        let resolver = pathResolver
        return CommandPathInteractionController(view: self, callbacks: .init(
            probe: { [weak self] in self?.probePath(at: $0) ?? .none },
            publish: { [weak self] in self?.publishPath(id: $0, match: $1, open: $2) },
            clear: { [weak self] in
                if let surface = self?.surfaceView.surface { ghostty_surface_path_clear(surface) }
            },
            pointer: { [weak surfaceView] in surfaceView?.setCommandPathHovering($0) },
            forward: { [weak surfaceView] in surfaceView?.forwardPathSelectionEvent($0) }
        ), resolve: { await resolver.match($0) })
    }

    private func probePath(at point: NSPoint) -> CommandPathInteractionController.ProbeResult {
        guard bounds.contains(point), let superview,
              let surface = surfaceView.surface else { return .none }
        // Search fields, the native editor, and the scroller must never inherit
        // an output path's hover simply because their rectangles overlap Metal.
        // Call the superclass directly: asking the window to hit-test again
        // during mouseDown would recurse through this host's interception.
        let target = super.hitTest(convert(point, to: superview))
        guard target === surfaceView || target === self else { return .none }
        var probe = ghostty_path_probe_s()
        switch ghostty_surface_path_probe(surface, point.x, point.y, &probe) {
        case GHOSTTY_PATH_PROBE_BUSY: return .busy
        case GHOSTTY_PATH_PROBE_HIT: break
        default: return .none
        }
        let text = withUnsafeBytes(of: probe.text) { String(bytes: $0.prefix(Int(probe.text_len)), encoding: .utf8) }
        let uri = withUnsafeBytes(of: probe.uri) { String(bytes: $0.prefix(Int(probe.uri_len)), encoding: .utf8) }
        let id = withUnsafeBytes(of: probe.block_id) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) }
        guard let text, let uri else { return .none }
        let kind: CommandPathProbe.Kind
        switch probe.kind {
        case GHOSTTY_PATH_KIND_HEADER: kind = .header
        case GHOSTTY_PATH_KIND_LOCAL_OSC8: kind = .localLink
        default: kind = .output
        }
        return .hit(CommandPathProbe(id: probe.hit_id, kind: kind, text: text, hoverByte: Int(probe.hover_byte), uri: uri,
                                     workingDirectory: id.flatMap { session.blockMetadata[$0]?.workingDirectory }))
    }

    private func publishPath(id: UInt64, match: CommandPathMatch, open: Bool) -> [NSRect]? {
        guard let surface = surfaceView.surface else { return nil }
        var result = ghostty_path_rects_s()
        guard ghostty_surface_path_publish(surface, id, UInt32(match.start), UInt32(match.length), open, &result) else {
            return nil
        }
        return withUnsafeBytes(of: result.rects) { bytes in
            bytes.bindMemory(to: ghostty_path_rect_s.self).prefix(min(8, Int(result.count))).map {
                NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            }
        }
    }

    @objc private func pathViewportChanged() {
        paths.geometryWillChange()
        paths.refresh()
        session.terminalGeometryChanged()
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

    @objc private func editCommand() { session.useEditor() }
    @objc private func useTerminal() { session.useTerminal() }
    @objc private func viewDraft() { session.showRecoveryDraft() }
}
