import AppKit

@MainActor
final class CommandPathInteractionController: NSObject {
    enum ProbeResult { case none, busy, hit(CommandPathProbe) }
    struct Callbacks {
        var probe: (NSPoint) -> ProbeResult
        var publish: (UInt64, CommandPathMatch, Bool) -> [NSRect]?
        var clear: () -> Void
        var pointer: (Bool) -> Void
        var forward: (NSEvent) -> Void
        var copy: (String) -> Void = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString($0, forType: .string)
        }
        var open: (CommandResolvedPath) -> Void = {
            if $0.kind == .directory {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: $0.path)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0.path)])
            }
        }
    }
    private struct Hover {
        let probe: CommandPathProbe
        let match: CommandPathMatch
        var rects: [NSRect]
        var open: Bool
    }
    private struct Click {
        let event: NSEvent
        let point: NSPoint
        let id: UInt64
        let workingDirectory: String?
        var match: CommandPathMatch?
        var awaitingValidation = false
        var release: NSEvent?
        var forwarding = false
    }
    private weak var view: NSView?
    private let callbacks: Callbacks
    private let resolve: @Sendable (CommandPathProbe) async -> CommandPathMatch?
    private var tooltip: CommandPathTooltip?
    var theme = CommandUITheme.fallback { didSet { tooltip?.applyTheme(theme) } }
    private var task: Task<Void, Never>?
    private var clickDeadline: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var pendingProbe: CommandPathProbe?
    private var hover: Hover?
    private var click: Click?
    private var point: NSPoint?
    private var modifiers: NSEvent.ModifierFlags = []
    private var modifierMonitor: Any?
    var isHovering: Bool { hover != nil }

    init(view: NSView, callbacks: Callbacks,
         resolve: @escaping @Sendable (CommandPathProbe) async -> CommandPathMatch?) {
        self.view = view
        self.callbacks = callbacks
        self.resolve = resolve
        super.init()
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.modifiersChanged(event) }
            return event
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.didMoveNotification,
                     NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: nil)
        }
    }

    deinit {
        task?.cancel()
        clickDeadline?.cancel()
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    func pointerMoved(with event: NSEvent) {
        // SurfaceView routes dragging through mouseMoved for terminal selection.
        // Neither an old lookup nor a later layout refresh may turn that drag
        // into path hover. A genuine mouse move can acquire a new target.
        if [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(event.type) {
            pointerExited()
            return
        }
        guard click == nil, let view, event.window === view.window,
              view.window?.isKeyWindow == true, view.window?.isOnActiveSpace == true else { return }
        update(at: view.convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags)
    }

    /// Also used by the model tests without ordering their NSWindow onscreen.
    func update(at point: NSPoint, modifiers: NSEvent.ModifierFlags, retryBusy: Bool = true) {
        self.point = point
        self.modifiers = modifiers
        switch callbacks.probe(point) {
        case .none: clearHover()
        case .busy:
            clearHover()
            guard retryBusy else { return }
            let current = revision
            task = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let self, self.revision == current, let point = self.point else { return }
                self.update(at: point, modifiers: self.modifiers, retryBusy: false)
            }
        case .hit(let probe):
            if var hover, hover.probe.id == probe.id, hover.match.contains(probe.hoverByte),
               hover.probe.workingDirectory == probe.workingDirectory {
                let open = !modifiers.isDisjoint(with: [.command, .control])
                if open == hover.open { callbacks.pointer(true); return }
                guard let rects = callbacks.publish(probe.id, hover.match, open) else { clearHover(); return }
                hover.rects = rects
                hover.open = open
                self.hover = hover
                callbacks.pointer(true)
                return
            }
            if pendingProbe?.id == probe.id, pendingProbe?.workingDirectory == probe.workingDirectory { return }
            clearHover(invalidateCore: false)
            pendingProbe = probe
            let current = revision
            let resolve = self.resolve
            task = Task { [weak self] in
                guard !Task.isCancelled else { return }
                let result = await resolve(probe)
                guard !Task.isCancelled, let self, self.revision == current else { return }
                self.task = nil
                self.pendingProbe = nil
                if self.click?.id == probe.id, self.click?.awaitingValidation == true {
                    self.click?.awaitingValidation = false
                    self.click?.match = result
                    self.clickDeadline?.cancel()
                    self.clickDeadline = nil
                    if result == nil { self.forwardClick() } else if self.click?.release != nil { self.finishClick() }
                    return
                }
                guard let point = self.point,
                      case .hit(let latest) = self.callbacks.probe(point), latest.id == probe.id else { return }
                guard let result, result.contains(latest.hoverByte) else {
                    if latest.hoverByte != probe.hoverByte { self.update(at: point, modifiers: self.modifiers) }
                    return
                }
                self.install(probe: latest, match: result)
            }
        }
    }

    func refresh() {
        guard click == nil, let point else { return }
        update(at: point, modifiers: modifiers)
    }

    func pointerExited() {
        point = nil
        cancelWaitingClick()
        clearHover()
        tooltip?.dismiss()
    }

    func geometryWillChange() {
        cancelWaitingClick()
        clearHover()
        tooltip?.dismiss()
    }

    func claimsClick(at point: NSPoint, modifiers: NSEvent.ModifierFlags, clickCount: Int = 1) -> Bool {
        // Repeated clicks belong to real terminal word/line selection. The
        // first path click may have been consumed, so SurfaceView supplies the
        // actual AppKit count for that sequence rather than replaying presses.
        guard clickCount == 1 else { pointerExited(); return false }
        guard modifiers.isDisjoint(with: [.shift, .option]) else { return false }
        update(at: point, modifiers: modifiers)
        // Exact cwd metadata needs no filesystem lookup, even on a first click
        // before an asynchronous hover response has returned.
        if hover == nil, case .hit(let probe) = callbacks.probe(point), probe.kind == .header,
           let cwd = probe.workingDirectory, cwd.hasPrefix("/") {
            clearHover(invalidateCore: false)
            install(probe: probe, match: CommandPathMatch(
                path: CommandResolvedPath(path: cwd, kind: .directory), start: 0, length: probe.text.utf8.count))
        }
        // A cold output click must not require a preceding mouse-move/stat.
        // Own only an existing bounded core probe, then validate asynchronously.
        // A failed lookup replays the real events into terminal selection.
        return hover != nil || pendingProbe != nil
    }

    func mouseDown(with event: NSEvent) {
        if CommandInputDiagnostics.isEnabled {
            CommandInputDiagnostics.mark(.selectionIntercept, id: nil,
                                         metrics: ["count": Double(event.clickCount), "timestamp": event.timestamp])
        }
        guard let view else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        if event.type == .leftMouseDown, event.clickCount > 1 {
            // AppKit may keep delivering a repeated press to the first click's
            // view, even when hitTest now declines it. Complete the real
            // terminal gesture instead of swallowing that second/third press.
            pointerExited()
            click = Click(event: event, point: point, id: 0, workingDirectory: nil, forwarding: true)
            callbacks.forward(event)
            return
        }
        guard claimsClick(at: point, modifiers: event.modifierFlags, clickCount: event.clickCount) else { return }
        // Pointer movement shares a pending line lookup, but a real press must
        // validate the exact token under that press rather than an earlier byte.
        if hover == nil, let pendingProbe, case .hit(let latest) = callbacks.probe(point),
           latest.id == pendingProbe.id, latest.hoverByte != pendingProbe.hoverByte {
            clearHover(invalidateCore: false)
            update(at: point, modifiers: event.modifierFlags)
        }
        guard let probe = hover?.probe ?? pendingProbe else { return }
        tooltip?.dismiss()
        clickDeadline?.cancel()
        click = Click(event: event, point: point, id: probe.id, workingDirectory: probe.workingDirectory,
                      match: hover?.match,
                      awaitingValidation: hover == nil)
        if hover == nil {
            clickDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.click?.id == probe.id, self.click?.awaitingValidation == true else { return }
                // A slow/mounted filesystem cannot swallow a terminal press.
                self.forwardClick()
            }
        }
    }

    /// AppKit owns repeated-click recognition. A first press may have moved
    /// focus from the native editor, or been consumed by a path interaction,
    /// before the terminal sees this sequence. Core arrival times cannot
    /// reconstruct it reliably, especially under load.
    func selectionClickCount(for event: NSEvent) -> UInt32? {
        guard event.type == .leftMouseDown, event.clickCount > 1 else { return nil }
        return UInt32(clamping: min(event.clickCount, 3))
    }

    func mouseDragged(with event: NSEvent) {
        guard var click, let view else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        if !click.forwarding, hypot(point.x - click.point.x, point.y - click.point.y) >= 3 {
            click.forwarding = true
            click.awaitingValidation = false
            clickDeadline?.cancel()
            clickDeadline = nil
            self.click = click
            clearHover()
            callbacks.forward(click.event)
        }
        self.click = click
        if click.forwarding { callbacks.forward(event) }
    }

    func mouseUp(with event: NSEvent) {
        guard var click, let view else { return }
        if click.forwarding { self.click = nil; callbacks.forward(event); return }
        let location = view.convert(event.locationInWindow, from: nil)
        guard hypot(location.x - click.point.x, location.y - click.point.y) < 3 else {
            self.click = click
            forwardClick(release: event)
            return
        }
        click.release = event
        self.click = click
        if !click.awaitingValidation { finishClick() }
    }

    private func finishClick() {
        guard let click, let event = click.release, let match = click.match, let view else { return }
        self.click = nil
        clickDeadline?.cancel()
        clickDeadline = nil
        let location = view.convert(event.locationInWindow, from: nil)
        guard case .hit(let latest) = callbacks.probe(location), latest.id == click.id,
              latest.workingDirectory == click.workingDirectory,
              match.contains(latest.hoverByte) else { clearHover(); return }
        let open = !event.modifierFlags.isDisjoint(with: [.command, .control])
        guard let rects = callbacks.publish(click.id, match, open), !rects.isEmpty else { clearHover(); return }
        hover = Hover(probe: latest, match: match, rects: rects, open: open)
        callbacks.pointer(true)
        if open { callbacks.open(match.path) } else {
            callbacks.copy(match.path.path)
            if tooltip == nil { tooltip = CommandPathTooltip() }
            tooltip?.applyTheme(theme)
            tooltip?.show(anchor: rects.first(where: { $0.contains(location) }) ?? rects[0], in: view)
        }
    }

    private func forwardClick(release: NSEvent? = nil) {
        guard var click else { return }
        clickDeadline?.cancel()
        clickDeadline = nil
        click.awaitingValidation = false
        click.forwarding = true
        let up = release ?? click.release
        self.click = click
        clearHover()
        if CommandInputDiagnostics.isEnabled {
            CommandInputDiagnostics.mark(.selectionForward, id: nil,
                                         metrics: ["count": Double(click.event.clickCount), "timestamp": click.event.timestamp])
        }
        callbacks.forward(click.event)
        if let up {
            self.click = nil
            callbacks.forward(up)
        }
    }

    private func cancelWaitingClick() {
        clickDeadline?.cancel()
        clickDeadline = nil
        if click?.forwarding != true { click = nil }
    }

    private func install(probe: CommandPathProbe, match: CommandPathMatch) {
        let open = !modifiers.isDisjoint(with: [.command, .control])
        guard let rects = callbacks.publish(probe.id, match, open), !rects.isEmpty else { return }
        hover = Hover(probe: probe, match: match, rects: rects, open: open)
        callbacks.pointer(true)
    }

    private func clearHover(invalidateCore: Bool = true) {
        let hadProbe = hover != nil || pendingProbe != nil
        revision &+= 1
        task?.cancel()
        task = nil
        pendingProbe = nil
        if invalidateCore, hadProbe { callbacks.clear() }
        if hover != nil { callbacks.pointer(false) }
        hover = nil
    }

    private func modifiersChanged(_ event: NSEvent) {
        guard event.window === view?.window, view?.window?.isKeyWindow == true else { return }
        modifiers = event.modifierFlags
        refresh()
    }

    @objc private func windowChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === view?.window else { return }
        pointerExited()
    }
}
