import AppKit

/// AppKit owns the tab gesture. Latch its source before dispatch, track the
/// actual native run-loop mode, and transfer only after native dispatch returns.
@MainActor
final class TerminalTabDragCoordinator {
    private var enabled = false
    private weak var source: TerminalController?
    private var origin = NSPoint.zero
    private var initialEventNumber = 0
    private var dispatchingPress = false
    private var releasePoint: NSPoint?
    private var ownedWindows: [Int] = []
    private var generation: UInt64 = 0
    private var endScheduled = false
    private let pump = NativeTabTrackingPump()
    private let preview = TerminalTabSplitPreview(frame: .zero)
    private let traceURL = ProcessInfo.processInfo.environment["SPOOKY_NATIVE_TAB_TRACE"].map { URL(fileURLWithPath: $0) }
    private let traceQueue = DispatchQueue(label: "com.patinasystems.spooky.native-tab-trace", qos: .utility)
    private var tickCount = 0
    private var modes: [String] = []
    private var visited: [String] = []

    func start() { enabled = true }
    func stop() { enabled = false; end(reason: "stopped") }

    func willDispatch(_ event: NSEvent) {
        guard enabled else { return }
        if event.type == .leftMouseDown {
            begin(event)
        } else if source != nil {
            if event.type == .keyDown, event.keyCode == 53 { end(reason: "escape") }
            if event.type == .leftMouseUp, let window = event.window {
                releasePoint = window.convertPoint(toScreen: event.locationInWindow)
            }
        }
    }

    func didDispatch(_ event: NSEvent) {
        guard source != nil else { return }
        if event.type == .leftMouseDown, event.eventNumber == initialEventNumber { dispatchingPress = false }
        // Hardware may already reflect the next press under load. A mouse-up
        // in this event stream remains authoritative for the current gesture.
        guard !dispatchingPress, releasePoint != nil || NSEvent.pressedMouseButtons & 1 == 0 else { return }
        finish(at: releasePoint ?? NSEvent.mouseLocation)
    }

    private func begin(_ event: NSEvent) {
        end(reason: "new-press")
        guard let eventWindow = event.window else { return }
        let host: TerminalWindow?
        if let terminal = eventWindow as? TerminalWindow {
            host = terminal
        } else {
            host = NSApp.windows.compactMap { $0 as? TerminalWindow }.first {
                $0.styleMask.contains(.fullScreen) && $0.tabBarView?.window === eventWindow
            }
        }
        let point = eventWindow.convertPoint(toScreen: event.locationInWindow)
        guard let host else { return }
        let hit = host.tabButtonHit(atScreenPoint: point)
        if traceURL != nil, hit != nil || event.locationInWindow.y >= host.contentLayoutRect.maxY {
            writeTrace(["phase": "press", "application": NSStringFromClass(type(of: NSApp!)),
                        "eventWindow": NSStringFromClass(type(of: eventWindow)), "hit": hit != nil], reason: "native-tab-hit")
        }
        guard let hit, let tab = host.tabWindow(for: hit.tabButton, fallbackIndex: hit.index),
              let controller = tab.windowController as? TerminalController,
              tab.attachedSheet == nil, !controller.surfaceTree.isEmpty,
              let barWindow = hit.tabButton.window, let parent = hit.tabButton.superview,
              let view = hit.tabButton.hitTest(parent.convert(barWindow.convertPoint(fromScreen: point), from: nil))
        else { return }
        let allowed = NativeTabHitPolicy.allows(view, in: hit.tabButton)
        if traceURL != nil {
            writeTrace(["phase": "hit-policy", "view": NSStringFromClass(type(of: view)), "allowed": allowed], reason: "native-tab-hit")
        }
        guard allowed else { return }
        source = controller
        origin = point
        initialEventNumber = event.eventNumber
        dispatchingPress = true
        ownedWindows = NSApp.windows.map(\.windowNumber)
        pump.start { [weak self] in self?.tick() }
    }

    private func tick() {
        guard let source, !source.surfaceTree.isEmpty else { end(reason: "source-closed"); return }
        if traceURL != nil {
            tickCount += 1
            let mode = RunLoop.main.currentMode?.rawValue ?? "none"
            if !modes.contains(mode) { modes.append(mode) }
        }
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            releasePoint = releasePoint ?? NSEvent.mouseLocation
            pump.stop()
            // The app-level dispatch hook is authoritative while AppKit is
            // tracking the initial press. Otherwise finish on the outer loop.
            guard !dispatchingPress, !endScheduled else { return }
            endScheduled = true
            let token = generation
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == token, let point = self.releasePoint else { return }
                    self.finish(at: point)
                }
            }
            return
        }
        let point = NSEvent.mouseLocation
        guard hypot(point.x - origin.x, point.y - origin.y) >= 6,
              let target = target(at: point, excluding: source) else {
            preview.removeFromSuperview()
            return
        }
        if traceURL != nil {
            let value = "\(target.controller.window?.windowNumber ?? 0):\(target.zone.rawValue)"
            if visited.last != value, visited.count < 64 { visited.append(value) }
        }
        // Re-evaluate even with a stationary pointer: native detachment can
        // expose a destination underneath it without another mouse movement.
        preview.show(in: target.host, zone: target.zone)
    }

    private struct Target {
        let controller: BaseTerminalController
        let surface: Ghostty.SurfaceView
        let host: NSView
        let zone: TerminalSplitDropZone
    }

    /// Preview and commit use this same WindowServer order, including other
    /// apps. Do not let the moving source or a native drag-image window block it.
    private func frontWindow(at point: NSPoint, excluding source: TerminalController) -> NSWindow? {
        var below = 0
        for _ in 0..<16 {
            let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: below)
            guard number > 0 else { return nil }
            let window = NSApp.window(withWindowNumber: number)
            let transient: Bool
            if let window {
                transient = window.ignoresMouseEvents ||
                    (!ownedWindows.contains(number) && window.windowController == nil && !window.canBecomeKey)
            } else if !ownedWindows.contains(number),
                      let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]],
                      let pid = info.first?[kCGWindowOwnerPID as String] as? Int {
                transient = pid == Int(ProcessInfo.processInfo.processIdentifier)
            } else {
                transient = false
            }
            if window?.windowController === source || transient { below = number; continue }
            return window
        }
        return nil
    }

    private func target(at point: NSPoint, excluding source: TerminalController) -> Target? {
        guard let window = frontWindow(at: point, excluding: source),
              let controller = window.windowController as? BaseTerminalController,
              controller !== source, controller.ghostty === source.ghostty,
              window.attachedSheet == nil else { return nil }
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

    private func finish(at point: NSPoint) {
        guard !dispatchingPress, releasePoint != nil || NSEvent.pressedMouseButtons & 1 == 0 else { return }
        guard let source else { end(reason: "source-gone"); return }
        guard hypot(point.x - origin.x, point.y - origin.y) >= 6,
              let destination = target(at: point, excluding: source) else { end(reason: "no-split-target"); return }
        // Capture the accepted destination before resetting gesture state. No
        // inference from asynchronously changing native tab-group/frame state.
        let trace = traceSnapshot()
        reset()
        let accepted = destination.controller.receiveTabSplit(from: source, at: destination.surface, zone: destination.zone)
        writeTrace(trace, reason: accepted ? "split-accepted" : "split-rejected")
    }

    private func traceSnapshot() -> [String: Any]? {
        guard traceURL != nil, let source else { return nil }
        return ["time": Date().timeIntervalSince1970, "source": source.window?.windowNumber ?? 0,
                "ticks": tickCount, "modes": modes, "targets": visited]
    }

    private func writeTrace(_ entry: [String: Any]?, reason: String) {
        guard let traceURL, var entry else { return }
        entry["reason"] = reason
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        data.append(10)
        let record = data
        traceQueue.async {
            if !FileManager.default.fileExists(atPath: traceURL.path) { FileManager.default.createFile(atPath: traceURL.path, contents: nil) }
            if let file = try? FileHandle(forWritingTo: traceURL) {
                defer { try? file.close() }
                _ = try? file.seekToEnd()
                try? file.write(contentsOf: record)
            }
        }
    }

    private func end(reason: String) {
        let trace = traceSnapshot()
        reset()
        writeTrace(trace, reason: reason)
    }

    private func reset() {
        pump.stop()
        generation &+= 1
        source = nil
        dispatchingPress = false
        releasePoint = nil
        endScheduled = false
        ownedWindows.removeAll(keepingCapacity: true)
        tickCount = 0
        modes.removeAll(keepingCapacity: true)
        visited.removeAll(keepingCapacity: true)
        preview.removeFromSuperview()
    }
}

/// Native title labels may report editable even when AppKit owns their clicks.
/// Only the close/accessory buttons and our actual inline editor exclude a drag.
@MainActor
enum NativeTabHitPolicy {
    static func allows(_ view: NSView, in tab: NSView) -> Bool {
        var descendant: NSView? = view
        while let child = descendant, child !== tab {
            if child is NSButton || child is NSTextView || child.identifier == TabTitleEditor.inlineEditorIdentifier { return false }
            descendant = child.superview
        }
        return descendant === tab
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
