import AppKit

// NSWindow's inherited drag implementation also drives native tab reordering
// and detachment. Receive our custom pane payload through its documented
// delegate forwarding, rather than replacing that implementation on the window.
extension TerminalController: NSDraggingDestination {
    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { updateTabDrop(sender) }
    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { updateTabDrop(sender) }
    func draggingExited(_ sender: (any NSDraggingInfo)?) { clearTabDropFeedback() }
    func draggingEnded(_ sender: any NSDraggingInfo) { clearTabDropFeedback() }
    func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { clearTabDropFeedback() }
    func wantsPeriodicDraggingUpdates() -> Bool { false }

    func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard tabDropSource(sender) != nil else { clearTabDropFeedback(); return false }
        return true
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { clearTabDropFeedback() }
        guard let source = tabDropSource(sender) else { return false }
        return receiveTabDrop(source)
    }

    private func tabDropSource(_ sender: any NSDraggingInfo) -> Ghostty.SurfaceView? {
        guard let window, window.styleMask.contains(.titled), sender.draggingSourceOperationMask.contains(.move),
              TerminalTabDropRegion.header(size: window.frame.size, contentLayout: window.contentLayoutRect).contains(sender.draggingLocation),
              let sourceView = sender.draggingSource as? Ghostty.SurfaceDragSourceView,
              let source = sourceView.surfaceView,
              let data = sender.draggingPasteboard.data(forType: TerminalSurfaceDragPayload.type),
              TerminalSurfaceDragPayload.id(from: data) == source.id,
              canReceiveTabDrop(source) else { return nil }
        return source
    }

    private func updateTabDrop(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard tabDropSource(sender) != nil, let window = window as? TerminalWindow, let root = window.contentView?.superview else {
            clearTabDropFeedback()
            return []
        }
        let feedback = window.tabDropFeedback ?? TerminalTabDropFeedback(frame: .zero)
        let rect = TerminalTabDropRegion.header(size: window.frame.size, contentLayout: window.contentLayoutRect)
        feedback.frame = root.convert(rect, from: nil).insetBy(dx: 6, dy: 2)
        if feedback.superview !== root { root.addSubview(feedback, positioned: .above, relativeTo: nil) }
        window.tabDropFeedback = feedback
        return .move
    }

    private func clearTabDropFeedback() {
        guard let window = window as? TerminalWindow else { return }
        window.tabDropFeedback?.removeFromSuperview()
        window.tabDropFeedback = nil
    }
}

extension TerminalController {
    func canReceiveTabDrop(_ source: Ghostty.SurfaceView) -> Bool {
        guard let window, window.tabbingMode != .disallowed, window.attachedSheet == nil,
              !(fullscreenStyle?.isFullscreen == true && fullscreenStyle?.supportsTabs == false),
              let owner = BaseTerminalController.controller(owning: source) as? TerminalController,
              owner.ghostty === ghostty, let sourceWindow = owner.window,
              sourceWindow.attachedSheet == nil,
              !(owner.fullscreenStyle?.isFullscreen == true && owner.fullscreenStyle?.supportsTabs == false)
        else { return false }
        if owner.surfaceTree.isSplit { return true }
        guard sourceWindow !== window else { return false }
        if let group = window.tabGroup, sourceWindow.tabGroup === group { return false }
        return true
    }

    /// Move the live surface, preserving its PTY, scrollback, draft and native UI.
    @discardableResult
    func receiveTabDrop(_ source: Ghostty.SurfaceView) -> Bool {
        guard canReceiveTabDrop(source), let parent = window,
              let owner = BaseTerminalController.controller(owning: source) as? TerminalController,
              let sourceWindow = owner.window else { return false }

        if !owner.surfaceTree.isSplit {
            guard parent.addTabbedWindowSafely(sourceWindow, ordered: .above) else { return false }
            selectDroppedTab(sourceWindow, surface: source)
            return true
        }

        // Attach an empty tab first. A rejected AppKit operation must leave the
        // source tree and session untouched, and must never launch a new shell.
        let created = TerminalController(ghostty, withSurfaceTree: SplitTree<Ghostty.SurfaceView>())
        created.isBackgroundOpaque = isBackgroundOpaque
        guard let tab = created.window else { return false }
        // AppKit may already have grouped a fresh window when the system's
        // tabbing preference is Always. Match the existing new-tab path.
        if let group = parent.tabGroup, group.windows.contains(tab) { group.removeWindow(tab) }
        guard tab.tabbingMode != .disallowed, parent.addTabbedWindowSafely(tab, ordered: .above) else {
            tab.close()
            return false
        }
        guard let node = owner.surfaceTree.root?.node(view: source) else { tab.close(); return false }

        // Controllers share the app undo manager. Undo closes the new tab before
        // restoring the source tree; the existing close action supplies redo.
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        owner.removeSurfaceNode(node)
        created.surfaceTree = .init(view: source)
        created.focusedSurfaceDidChange(to: source)
        undoManager?.registerUndo(withTarget: created, expiresAfter: created.undoExpiration) { target in
            target.closeTabImmediately()
        }
        undoManager?.setActionName("Move Pane to Tab")
        selectDroppedTab(tab, surface: source)
        return true
    }

    private func selectDroppedTab(_ tab: NSWindow, surface: Ghostty.SurfaceView) {
        tab.tabGroup?.selectedWindow = tab
        tab.makeKeyAndOrderFront(nil)
        // Split rehosting finishes on the next main run-loop turn. Never focus
        // the pane's old window, or steal focus after a newer tab selection.
        DispatchQueue.main.async { [weak surface, weak tab] in
            guard let surface, let tab, tab.isKeyWindow,
                  let owner = BaseTerminalController.controller(owning: surface),
                  owner.window === tab, owner.focusedSurface === surface else { return }
            Ghostty.moveFocus(to: surface, from: nil)
            (NSApp.delegate as? AppDelegate)?.nativeTabDragCoordinator.recordTransfer("pane-to-tab-focused")
        }
        relabelTabs()
        (tab.windowController as? TerminalController)?.relabelTabs()
        invalidateRestorableState()
        (tab.windowController as? TerminalController)?.invalidateRestorableState()
        (NSApp.delegate as? AppDelegate)?.nativeTabDragCoordinator.recordTransfer("pane-to-tab")
    }
}

/// Decorative only: native titlebar buttons, tab dragging and window movement
/// keep their normal hit testing. No animation or work after the drag ends.
private final class TerminalTabDropFeedback: NSView {
    private let label = NSTextField(labelWithString: "Add as Tab")
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { return nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 6, y: max(0, (bounds.height - 16) / 2), width: max(0, bounds.width - 12), height: 16)
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        label.textColor = .controlAccentColor
    }
}
