import AppKit

/// Observe native tab gestures without replacing AppKit's tracking, reordering
/// or detachment. A released tab over terminal content moves its whole live tree.
@MainActor
final class TerminalTabDragCoordinator {
    private weak var source: TerminalController?
    private var origin = NSPoint.zero
    private var originalFrame = NSRect.zero
    private var originalWindows: [Int] = []
    private var lastPoint: NSPoint?
    private var hasMoved = false
    private var timer: Timer?
    private var eventMonitor: Any?
    private var escapeMonitor: Any?
    private let preview = TerminalTabSplitPreview(frame: .zero)

    func start() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.mouseDown(event) }
            return event
        }
    }

    func stop() {
        cancel()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    func didDispatch(_ event: NSEvent) {
        guard source != nil, event.type == .leftMouseDown || event.type == .leftMouseUp else { return }
        if NSEvent.pressedMouseButtons & 1 == 0 { finish() }
    }

    private func mouseDown(_ event: NSEvent) {
        cancel()
        guard let eventWindow = event.window else { return }
        let host: TerminalWindow?
        if let terminal = eventWindow as? TerminalWindow {
            // The common content-click path does no private tab-view lookup.
            guard event.locationInWindow.y >= terminal.contentLayoutRect.maxY else { return }
            host = terminal
        } else {
            // AppKit hosts fullscreen tabs in a separate toolbar window.
            host = NSApp.windows.compactMap { $0 as? TerminalWindow }.first {
                $0.styleMask.contains(.fullScreen) && $0.tabBarView?.window === eventWindow
            }
        }
        let point = eventWindow.convertPoint(toScreen: event.locationInWindow)
        guard let host, let hit = host.tabButtonHit(atScreenPoint: point),
              let tab = host.tabbedWindows?[safe: hit.index],
              let controller = tab.windowController as? TerminalController,
              controller.window?.attachedSheet == nil, !controller.surfaceTree.isEmpty,
              let barWindow = hit.tabButton.window, let parent = hit.tabButton.superview,
              let view = hit.tabButton.hitTest(parent.convert(barWindow.convertPoint(fromScreen: point), from: nil))
        else { return }
        // Leave close buttons, tab accessories and inline title editors alone.
        var descendant: NSView? = view
        while let child = descendant, child !== hit.tabButton {
            if child is NSButton || child is NSTextView || (child as? NSTextField)?.isEditable == true { return }
            descendant = child.superview
        }
        guard descendant === hit.tabButton else { return }
        source = controller
        origin = point
        originalFrame = tab.frame
        originalWindows = (tab.tabbedWindows ?? [tab]).map(\.windowNumber)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { MainActor.assumeIsolated { self?.cancel() } }
            return event
        }
        // Only an active native-tab press has a timer. The native tracking loop
        // may consume drag/up events before NSApplication's local monitors.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func tick() {
        guard let source, !source.surfaceTree.isEmpty, NSApp.isActive else { cancel(); return }
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            timer?.invalidate()
            timer = nil
            // Finish after AppKit's nested native tracking has unwound.
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                MainActor.assumeIsolated { self?.finish() }
            }
            return
        }
        let point = NSEvent.mouseLocation
        guard point != lastPoint else { return }
        lastPoint = point
        hasMoved = hasMoved || hypot(point.x - origin.x, point.y - origin.y) >= 6
        guard hasMoved, let target = target(at: point, excluding: source) else {
            preview.removeFromSuperview()
            return
        }
        preview.show(in: target.host, zone: target.zone)
    }

    private struct Target {
        let controller: BaseTerminalController
        let surface: Ghostty.SurfaceView
        let host: NSView
        let zone: TerminalSplitDropZone
    }

    private func target(at point: NSPoint, excluding source: TerminalController) -> Target? {
        for window in NSApp.orderedWindows {
            guard window.isVisible, !window.isMiniaturized, window.frame.contains(point),
                  window.windowController !== source else { continue }
            if let group = window.tabGroup, group.selectedWindow !== window { continue }
            if window.ignoresMouseEvents { continue }
            guard let controller = window.windowController as? BaseTerminalController,
                  controller.ghostty === source.ghostty, window.attachedSheet == nil else { return nil }
            let location = window.convertPoint(fromScreen: point)
            guard window.contentLayoutRect.contains(location) else { return nil }
            for surface in controller.surfaceTree {
                let host = paneHost(for: surface)
                guard host.window === window, !host.isHiddenOrHasHiddenAncestor,
                      host.bounds.width > 0, host.bounds.height > 0 else { continue }
                let local = host.convert(location, from: nil)
                guard host.bounds.contains(local) else { continue }
                let topLeft = NSPoint(x: local.x - host.bounds.minX,
                                      y: host.isFlipped ? local.y - host.bounds.minY : host.bounds.maxY - local.y)
                return Target(controller: controller, surface: surface, host: host,
                              zone: .calculate(at: topLeft, in: host.bounds.size))
            }
            return nil
        }
        return nil
    }

    private func paneHost(for surface: Ghostty.SurfaceView) -> NSView {
        var current: NSView? = surface
        var result: NSView = surface
        while let view = current {
            if view is NativeCommandSurfaceHost { return view }
            if view is SurfaceScrollView { result = view }
            current = view.superview
        }
        return result
    }

    private func finish() {
        // A deferred completion from an earlier press must not end a newer drag.
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        guard let source else { cancel(); return }
        let point = NSEvent.mouseLocation
        let moved = hasMoved || hypot(point.x - origin.x, point.y - origin.y) >= 6
        // A displaced pointer alone is not proof that AppKit accepted a tab
        // drag. Require a native reorder/detachment/move before transferring.
        let nativeMoved: Bool
        if let window = source.window {
            nativeMoved = window.frame != originalFrame ||
                (window.tabbedWindows ?? [window]).map(\.windowNumber) != originalWindows
        } else {
            nativeMoved = false
        }
        let destination = moved && nativeMoved ? target(at: point, excluding: source) : nil
        cancel()
        guard let destination, let window = destination.controller.window,
              isUnobscured(window, at: point, ignoring: source.window) else { return }
        destination.controller.receiveTabSplit(from: source, at: destination.surface, zone: destination.zone)
    }

    /// WindowServer occlusion is checked only on release, never on the render or
    /// typing path. Ignore the moving source and noninteractive drag-image windows.
    private func isUnobscured(_ target: NSWindow, at point: NSPoint, ignoring source: NSWindow?) -> Bool {
        var below = 0
        for _ in 0..<16 {
            let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: below)
            if number == target.windowNumber { return true }
            guard number != 0, let window = NSApp.window(withWindowNumber: number),
                  window === source || window.ignoresMouseEvents else { return false }
            below = number
        }
        return false
    }

    private func cancel() {
        timer?.invalidate()
        timer = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        source = nil
        originalWindows.removeAll(keepingCapacity: true)
        hasMoved = false
        lastPoint = nil
        preview.removeFromSuperview()
    }
}

private final class TerminalTabSplitPreview: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { return nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(in host: NSView, zone: TerminalSplitDropZone) {
        var rect = zone.highlightRect(in: host.bounds.size)
        if !host.isFlipped { rect.origin.y = host.bounds.height - rect.maxY }
        rect.origin.x += host.bounds.minX
        rect.origin.y += host.bounds.minY
        let targetFrame = rect.insetBy(dx: 2, dy: 2)
        guard superview !== host || frame != targetFrame else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = targetFrame
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        if superview !== host { host.addSubview(self, positioned: .above, relativeTo: nil) }
        CATransaction.commit()
    }
}

extension BaseTerminalController {
    @discardableResult
    func receiveTabSplit(from source: TerminalController, at destination: Ghostty.SurfaceView,
                         zone: TerminalSplitDropZone) -> Bool {
        guard source !== self, source.ghostty === ghostty,
              window?.attachedSheet == nil, source.window?.attachedSheet == nil,
              surfaceTree.contains(destination), let root = source.surfaceTree.root else { return false }
        let direction: SplitTree<Ghostty.SurfaceView>.NewDirection = switch zone {
        case .top: .up
        case .bottom: .down
        case .left: .left
        case .right: .right
        }
        guard let combined = try? surfaceTree.inserting(node: root, at: destination, direction: direction) else { return false }
        let focus = source.focusedSurface ?? root.leftmostLeaf()
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        source.removeSurfaceNode(root)
        replaceSurfaceTree(combined, moveFocusTo: focus, moveFocusFrom: focusedSurface)
        undoManager?.setActionName("Move Tab to Split")
        window?.makeKeyAndOrderFront(nil)
        return true
    }
}
