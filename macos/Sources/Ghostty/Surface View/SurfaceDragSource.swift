import AppKit
import SwiftUI

extension Ghostty {
    /// A preference key that propagates the ID of the SurfaceView currently being dragged,
    /// or nil if no surface is being dragged.
    struct DraggingSurfaceKey: PreferenceKey {
        static var defaultValue: SurfaceView.ID?

        static func reduce(value: inout SurfaceView.ID?, nextValue: () -> SurfaceView.ID?) {
            value = nextValue() ?? value
        }
    }

    /// A SwiftUI view that provides drag source functionality for terminal surfaces.
    ///
    /// This view wraps an AppKit-based drag source to enable drag-and-drop reordering
    /// of terminal surfaces within split views. When the user drags this view, it initiates
    /// an `NSDraggingSession` with the surface's UUID encoded in the pasteboard, allowing
    /// drop targets to identify which surface is being moved.
    ///
    /// The view also publishes the dragging state via `DraggingSurfaceKey` preference,
    /// enabling parent views to react to ongoing drag operations.
    struct SurfaceDragSource: View {
        /// The surface view that will be dragged.
        let surfaceView: SurfaceView
        let isSplit: Bool
        let dragHandle: Ghostty.Config.DragHandle
        @State private var isDragging = false

        var body: some View {
            SurfaceDragSourceViewRepresentable(
                surfaceView: surfaceView,
                isSplit: isSplit,
                enabled: dragHandle != .never,
                isDragging: $isDragging)
            .preference(key: DraggingSurfaceKey.self, value: isDragging ? surfaceView.id : nil)
        }
    }

    /// An NSViewRepresentable that provides AppKit-based drag source functionality.
    /// This gives us control over the drag lifecycle, particularly detecting drag start.
    fileprivate struct SurfaceDragSourceViewRepresentable: NSViewRepresentable {
        let surfaceView: SurfaceView
        let isSplit: Bool
        let enabled: Bool
        @Binding var isDragging: Bool

        func makeNSView(context: Context) -> SurfaceDragOverlay {
            let overlay = SurfaceDragOverlay(frame: .zero)
            let view = overlay.grip
            view.surfaceView = surfaceView
            view.isSplit = isSplit
            view.enabled = enabled
            view.onDragStateChanged = { dragging in
                isDragging = dragging
            }
            return overlay
        }

        func updateNSView(_ overlay: SurfaceDragOverlay, context: Context) {
            let nsView = overlay.grip
            nsView.surfaceView = surfaceView
            nsView.isSplit = isSplit
            nsView.enabled = enabled
            nsView.onDragStateChanged = { dragging in
                isDragging = dragging
            }
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: SurfaceDragOverlay, context: Context) -> CGSize? {
            guard let width = proposal.width, let height = proposal.height else { return nil }
            return CGSize(width: width, height: height)
        }
    }

    /// Native placement and hit testing. The full-pane mounting view passes
    /// clicks through everywhere except the visible grip itself.
    fileprivate final class SurfaceDragOverlay: NSView {
        let grip = SurfaceDragSourceView(frame: .zero)

        override init(frame: NSRect) {
            super.init(frame: frame)
            addSubview(grip)
        }
        required init?(coder: NSCoder) { return nil }

        override func layout() {
            super.layout()
            grip.frame = CGRect(x: max(bounds.minX, bounds.maxX - TerminalDragGrip.size.width - 6),
                                y: max(bounds.minY, bounds.maxY - TerminalDragGrip.size.height - 6),
                                width: TerminalDragGrip.size.width, height: TerminalDragGrip.size.height)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            guard bounds.contains(local), !grip.isHidden else { return nil }
            return grip.hitTest(local)
        }
    }

    /// The underlying NSView that handles drag operations.
    ///
    /// This view manages mouse tracking and drag initiation for surface reordering.
    /// It uses a local event loop to detect drag gestures and initiates an
    /// `NSDraggingSession` when the user drags beyond the threshold distance.
    class SurfaceDragSourceView: NSView, NSDraggingSource {
        /// Scale factor applied to the surface snapshot for the drag preview image.
        private static let previewScale: CGFloat = 0.2

        /// The surface view that will be dragged. Its UUID is encoded into the
        /// pasteboard for drop targets to identify which surface is being moved.
        var surfaceView: SurfaceView? {
            didSet { if surfaceView !== oldValue { bindTheme() } }
        }
        var enabled = true {
            didSet { if enabled != oldValue { syncVisibility() } }
        }
        var isSplit = false {
            didSet { if isSplit != oldValue { syncVisibility() } }
        }
        private var topologyObserver: NSObjectProtocol?
        private var themeObserver: NSObjectProtocol?
        private var isHovered = false
        private var isPressed = false

        /// Callback invoked when the drag state changes. Called with `true` when
        /// a drag session begins, and `false` when it ends (completed or cancelled).
        var onDragStateChanged: ((Bool) -> Void)?

        /// Whether we are currently in a mouse tracking loop (between mouseDown
        /// and either mouseUp or drag initiation). Used to determine cursor state.
        private var isTracking: Bool = false

        /// Local event monitor to detect escape key presses during drag.
        private var escapeMonitor: Any?

        /// Whether the current drag was cancelled by pressing escape.
        private var dragCancelledByEscape: Bool = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true)
            setAccessibilityRole(.handle)
            setAccessibilityLabel("Drag terminal")
            setAccessibilityHelp("Drag onto a window header to add a tab, or onto a terminal to split.")
            updateGrip()
            topologyObserver = NotificationCenter.default.addObserver(
                forName: TerminalWindowTopology.didChange, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.syncVisibility() } }
            syncVisibility()
        }

        required init?(coder: NSCoder) { return nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            syncVisibility()
        }

        private func syncVisibility() {
            guard let window else { isHidden = true; return }
            let count = (NSApp.delegate as? AppDelegate)?.terminalWindowTopology.windowCount ?? 0
            isHidden = !enabled || !TerminalWindowTopology.showsGrip(
                isSplit: isSplit, hasNativeTabs: TerminalWindowTopology.hasNativeTabs(window), windowCount: count)
        }

        private func bindTheme() {
            if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
            themeObserver = nil
            if let surfaceView {
                themeObserver = NotificationCenter.default.addObserver(
                    forName: .spookyCommandThemeDidChange, object: surfaceView, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.needsDisplay = true } }
            }
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let theme = surfaceView?.derivedConfig.commandUITheme ?? .fallback
            let state: TerminalDragGrip.State = isPressed || isTracking ? .pressed : (isHovered ? .hovered : .idle)
            TerminalDragGrip.draw(in: bounds, background: theme.background, foreground: theme.foreground,
                                  accent: theme.accent, state: state, scale: window?.backingScaleFactor ?? 2)
        }

        private func updateGrip() {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }

        deinit {
            if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
            if let topologyObserver { NotificationCenter.default.removeObserver(topologyObserver) }
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
            }
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            // Ensure this view gets the mouse event before window dragging handlers
            return true
        }

        override func mouseDown(with event: NSEvent) {
            // Consume the mouseDown event to prevent it from propagating to the
            // window's drag handler. This fixes issue #10110 where grab handles
            // would drag the window instead of initiating pane drags.
            // Don't call super - the drag will be initiated in mouseDragged.
            isPressed = true
            updateGrip()
            NSCursor.closedHand.set()
        }

        override func mouseUp(with event: NSEvent) {
            isPressed = false
            updateGrip()
            if isHovered { NSCursor.openHand.set() }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            // To update our tracking area we just recreate it all.
            trackingAreas.forEach { removeTrackingArea($0) }

            // Add our tracking area for mouse events
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp],
                owner: self,
                userInfo: nil
            ))
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: isTracking || isPressed ? .closedHand : .openHand)
        }

        override func mouseEntered(with event: NSEvent) {
            isHovered = true
            updateGrip()
        }

        override func mouseExited(with event: NSEvent) {
            isHovered = false
            updateGrip()
        }

        override func mouseDragged(with event: NSEvent) {
            guard !isTracking, let surfaceView = surfaceView else { return }

            // Create our dragging item from our transferable
            // Native titlebar drops read this synchronously. Avoid the generic
            // Transferable bridge's blocking wait for a 16-byte local UUID.
            let pasteboardItem = TerminalSurfaceDragPayload.item(for: surfaceView.id)
            let item = NSDraggingItem(pasteboardWriter: pasteboardItem)

            // Create a scaled preview image from the surface snapshot
            if let snapshot = surfaceView.asImage {
                let imageSize = NSSize(
                    width: snapshot.size.width * Self.previewScale,
                    height: snapshot.size.height * Self.previewScale
                )
                let scaledImage = NSImage(size: imageSize)
                scaledImage.lockFocus()
                snapshot.draw(
                    in: NSRect(origin: .zero, size: imageSize),
                    from: NSRect(origin: .zero, size: snapshot.size),
                    operation: .copy,
                    fraction: 1.0
                )
                scaledImage.unlockFocus()

                // Position the drag image so the mouse is at the center of the image.
                // I personally like the top middle or top left corner best but
                // this matches macOS native tab dragging behavior (at least, as of
                // macOS 26.2 on Dec 29, 2025).
                let mouseLocation = convert(event.locationInWindow, from: nil)
                let origin = NSPoint(
                    x: mouseLocation.x - imageSize.width / 2,
                    y: mouseLocation.y - imageSize.height / 2
                )
                item.setDraggingFrame(
                    NSRect(origin: origin, size: imageSize),
                    contents: scaledImage
                )
            }

            onDragStateChanged?(true)
            let session = beginDraggingSession(with: [item], event: event, source: self)

            // We need to disable this so that endedAt happens immediately for our
            // drags outside of any targets.
            session.animatesToStartingPositionsOnCancelOrFail = false
        }

        // MARK: NSDraggingSource

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            return context == .withinApplication ? .move : []
        }

        func draggingSession(
            _ session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint
        ) {
            isTracking = true
            updateGrip()

            // Reset our escape tracking
            dragCancelledByEscape = false
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { // Escape key
                    self?.dragCancelledByEscape = true
                }
                return event
            }
        }

        func draggingSession(
            _ session: NSDraggingSession,
            movedTo screenPoint: NSPoint
        ) {
            NSCursor.closedHand.set()
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
                self.escapeMonitor = nil
            }

            if operation == [] && !dragCancelledByEscape {
                let endsInWindow = NSApplication.shared.windows.contains { window in
                    window.isVisible && window.frame.contains(screenPoint)
                }
                if !endsInWindow {
                    NotificationCenter.default.post(
                        name: .ghosttySurfaceDragEndedNoTarget,
                        object: surfaceView,
                        userInfo: [Foundation.Notification.Name.ghosttySurfaceDragEndedNoTargetPointKey: screenPoint]
                    )
                }
            }

            isTracking = false
            isPressed = false
            updateGrip()
            onDragStateChanged?(false)
        }
    }
}

extension Notification.Name {
    /// Posted when a surface drag session ends with no operation (the drag was
    /// released outside a valid drop target) and was not cancelled by the user
    /// pressing escape. The notification's object is the SurfaceView that was dragged.
    static let ghosttySurfaceDragEndedNoTarget = Notification.Name("ghosttySurfaceDragEndedNoTarget")

    /// Key for the screen point where the drag ended in the userInfo dictionary.
    static let ghosttySurfaceDragEndedNoTargetPointKey = "endedAtPoint"
}
