import SwiftUI
import Combine

/// Wraps a Ghostty surface view in an NSScrollView to provide native macOS scrollbar support.
///
/// ## Coordinate System
/// AppKit uses a +Y-up coordinate system (origin at bottom-left), while terminals conceptually
/// use +Y-down (row 0 at top). This class handles the inversion when converting between row
/// offsets and pixel positions.
///
/// ## Architecture
/// - `scrollView`: The outermost NSScrollView that manages scrollbar rendering and behavior
/// - `documentView`: A blank NSView whose height represents total scrollback (in pixels)
/// - `surfaceView`: The actual Ghostty renderer, positioned to fill the visible rect
class SurfaceScrollView: NSView {
    private let scrollView: SurfaceNativeScrollView
    private let documentView: NSView
    private let surfaceView: Ghostty.SurfaceView
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var scrollSynchronization = SurfaceScrollSynchronization()
    private var isSynchronizingScrollView = false
    private var nativeFooterHeight: CGFloat = 0

    /// The last row position sent via scroll_to_row action. Used to avoid
    /// sending redundant actions when the user drags the scrollbar but stays
    /// on the same row.
    private var lastSentRow: UInt64?

    init(contentSize: CGSize, surfaceView: Ghostty.SurfaceView) {
        self.surfaceView = surfaceView
        // The scroll view is our outermost view that controls all our scrollbar
        // rendering and behavior.
        scrollView = SurfaceNativeScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.usesPredominantAxisScrolling = true
        // Always use the overlay style. See mouseMoved for how we make
        // it usable without a scroll wheel or gestures.
        scrollView.scrollerStyle = .overlay
        // hide default background to show blur effect properly
        scrollView.drawsBackground = false
        // don't let the content view clip its subviews, to enable the
        // surface to draw the background behind non-overlay scrollers
        // (we currently only use overlay scrollers, but might as well
        // configure the views correctly in case we change our mind)
        scrollView.contentView.clipsToBounds = false

        // The document view is what the scrollview is actually going
        // to be directly scrolling. We set it up to a "blank" NSView
        // with the desired content size.
        documentView = NSView(frame: NSRect(origin: .zero, size: contentSize))
        scrollView.documentView = documentView

        // The document view contains our actual surface as a child.
        // We synchronize the scrolling of the document with this surface
        // so that our primary Ghostty renderer only needs to render the viewport.
        documentView.addSubview(surfaceView)

        super.init(frame: .zero)

        // Our scroll view is our only view
        addSubview(scrollView)

        // Apply initial scrollbar settings
        synchronizeAppearance()

        // We listen for scroll events through bounds notifications on our NSClipView.
        // This is based on: https://christiantietze.de/posts/2018/07/synchronize-nsscrollview/
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] notification in
            self?.handleScrollChange(notification)
        })

        // Listen for scrollbar updates from Ghostty
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: surfaceView,
            queue: .main
        ) { [weak self] notification in
            self?.handleScrollbarUpdate(notification)
        })

        // Listen for live scroll events
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.scrollSynchronization.begin(originY: self.scrollView.contentView.documentVisibleRect.origin.y)
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let finalRow = self.scrollSynchronization.end()
            // Round the drag to the row already requested from the terminal.
            // Its asynchronous renderer acknowledgment may still be behind.
            self.synchronizeScrollView(releaseRow: finalRow)
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.handleLiveScroll()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            // Since this observer is used to immediately override the event
            // that produced the notification, we let it run synchronously on
            // the posting thread.
            queue: nil
        ) { [weak self] _ in
            self?.handleScrollerStyleChange()
        })

        // Listen for frame change events on macOS 26.0. See the docstring for
        // handleFrameChangeForNSScrollPocket for why this is necessary.
        if #unavailable(macOS 26.1) { if #available(macOS 26.0, *) {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: nil,
                // Since this observer is used to immediately override the event
                // that produced the notification, we let it run synchronously on
                // the posting thread.
                queue: nil
            ) { [weak self] notification in
                self?.handleFrameChangeForNSScrollPocket(notification)
            })
        }}

        // Listen for derived config changes to update scrollbar settings live
        surfaceView.$derivedConfig
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.handleConfigChange()
                }
            }
            .store(in: &cancellables)
        surfaceView.$pointerStyle
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newStyle in
                self?.scrollView.documentCursor = newStyle.cursor
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // The entire bounds is a safe area, so we override any default
    // insets. This is necessary for the content view to match the
    // surface view if we have the "hidden" titlebar style.
    override var safeAreaInsets: NSEdgeInsets { return NSEdgeInsetsZero }

    override func layout() {
        super.layout()

        // Fill entire bounds with scroll view
        scrollView.frame = bounds
        surfaceView.frame.size = scrollView.bounds.size

        // We only set the width of the documentView here, as the height depends
        // on the scrollbar state and is updated in synchronizeScrollView
        documentView.frame.size.width = scrollView.bounds.width

        // When our scrollview changes make sure our scroller and surface views are synchronized
        synchronizeScrollView()
        synchronizeSurfaceView()
        synchronizeCoreSurface()
    }

    /// Keep the history scroller above native footer controls without changing
    /// the clip view, Metal drawable, document range, or subprocess dimensions.
    func setNativeFooterHeight(_ height: CGFloat) {
        nativeFooterHeight = height
        if SurfaceScrollerTrack.applyBottomInset(height, to: scrollView) {
            updateTrackingAreas()
            synchronizeScrollView()
        }
    }

    // MARK: Scrolling

    private func synchronizeAppearance() {
        let scrollbarConfig = surfaceView.derivedConfig.scrollbar
        scrollView.hasVerticalScroller = scrollbarConfig != .never
        let hasLightBackground = NSColor(surfaceView.derivedConfig.backgroundColor).isLightColor
        // Make sure the scroller’s appearance matches the surface's background color.
        scrollView.appearance = NSAppearance(named: hasLightBackground ? .aqua : .darkAqua)
        updateTrackingAreas()
    }

    /// Positions the surface view to fill the currently visible rectangle.
    ///
    /// This is called whenever the scroll position changes. The surface view (which does the
    /// actual terminal rendering) always fills exactly the visible portion of the document view,
    /// so the renderer only needs to render what's currently on screen.
    private func synchronizeSurfaceView() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        surfaceView.frame.origin = visibleRect.origin
    }

    /// Inform the actual pty of our size change. This doesn't change the actual view
    /// frame because we do want to render the whole thing, but it will prevent our
    /// rows/cols from going into the non-content area.
    private func synchronizeCoreSurface() {
        // Only update the pty if we have a valid (non-zero) content size. The content size
        // can be zero when this is added early to a view, or to an invisible hierarchy.
        // Practically, this happened in the quick terminal.
        let width = scrollView.contentSize.width
        let height = surfaceView.frame.height
        if width > 0 && height > 0 {
            surfaceView.sizeDidChange(CGSize(width: width, height: height))
        }
    }

    /// Sizes the document view and scrolls the content view according to the scrollbar state
    private func synchronizeScrollView(releaseRow: UInt64? = nil) {
        guard !isSynchronizingScrollView else { return }
        isSynchronizingScrollView = true
        defer { isSynchronizingScrollView = false }

        let geometry = surfaceView.scrollbar.flatMap {
            SurfaceScrollSynchronization.Geometry(
                total: $0.total, visibleRows: $0.len,
                cellHeight: surfaceView.cellSize.height,
                viewportHeight: scrollView.contentSize.height)
        }
        let coreRow = releaseRow ?? surfaceView.scrollbar?.offset ?? 0
        let originY = scrollSynchronization.synchronize(geometry: geometry, coreRow: coreRow)
        // Set before geometry changes, which can make AppKit reflect the clip
        // view synchronously as well as during subsequent live scrolling.
        scrollView.nativeKnobProportion = nativeFooterHeight > 0 ? geometry?.knobProportion : nil

        // Update the document height to give our scroller the correct proportions
        documentView.frame.size.height = geometry?.documentHeight ?? scrollView.contentSize.height

        if let originY {
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: originY))
        }
        if !scrollSynchronization.isLiveScrolling, let geometry {
            lastSentRow = min(coreRow, geometry.maximumRow)
        }

        // Always update our scrolled view with the latest dimensions
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Notifications

    /// Handles bounds changes in the scroll view's clip view, keeping the surface view synchronized.
    private func handleScrollChange(_ notification: Notification) {
        synchronizeSurfaceView()
    }

    /// Handles scrollbar style changes
    private func handleScrollerStyleChange() {
        scrollView.scrollerStyle = .overlay
        synchronizeCoreSurface()
    }

    /// Handles config changes
    private func handleConfigChange() {
        synchronizeAppearance()
        synchronizeCoreSurface()
    }

    /// Handles live scroll events (user actively dragging the scrollbar).
    ///
    /// Converts the current scroll position to a row number and sends a `scroll_to_row` action
    /// to the terminal core. Only sends actions when the row changes to avoid IPC spam.
    private func handleLiveScroll() {
        // Resizing or rebasing the document can synchronously notify AppKit
        // observers. Only an actual drag should send a new terminal scroll.
        guard !isSynchronizingScrollView,
              let row = scrollSynchronization.scroll(
                originY: scrollView.contentView.documentVisibleRect.origin.y) else { return }

        // Only send action if the row changed to avoid action spam
        guard row != lastSentRow else { return }
        lastSentRow = row

        // Use the keybinding action to scroll.
        _ = surfaceView.surfaceModel?.perform(action: "scroll_to_row:\(row)")
    }

    /// Handles scrollbar state updates from the terminal core.
    ///
    /// Updates the document view size to reflect total scrollback and adjusts scroll position
    /// to match the terminal's viewport. During live scrolling, preserves the user's logical
    /// row when the document geometry changes instead of applying renderer acknowledgments.
    ///
    /// ## Scrollbar State
    /// The scrollbar struct contains:
    /// - `total`: Total rows in scrollback + active area
    /// - `offset`: First visible row (0 = top of history)
    /// - `len`: Number of visible rows (viewport height)
    private func handleScrollbarUpdate(_ notification: Notification) {
        guard let scrollbar = notification.userInfo?[SwiftUI.Notification.Name.ScrollbarKey] as? Ghostty.Action.Scrollbar else {
            return
        }
        surfaceView.scrollbar = scrollbar
        synchronizeScrollView()
    }

    /// Handles a change in the frame of NSScrollPocket styling overlays
    ///
    /// NSScrollView instances are set up with a subview hierarchy which, as far
    /// as I can tell, is intended to add a blur effect to any part of a scroll
    /// view that lies under the titlebar, presumably to complement a titlebar
    /// using liquid glass transparency. This doesn't work correctly with our
    /// hidden titlebar style, which does have a titlebar container, albeit
    /// hidden. The styling overlays don't care and size themselves to this
    /// container, creating a blurry, transparent field that clips the top of
    /// the surface view.
    ///
    /// With other titlebar styles, these views always have zero frame size,
    /// presumably because there is no overlap between the scroll view and the
    /// titlebar container.
    ///
    /// In native fullscreen, the titlebar detaches from the window and these
    /// views seem to work a bit differently, taking non-zero sizes for all
    /// styles without creating any problems.
    ///
    /// To handle this in a way that minimizes the difference between how the
    /// hidden titlebar and other window styles behave, we do as follows: If we
    /// have the hidden titlebar style and we're not fullscreen, we listen to
    /// frame changes on NSScrollPocket-related objects in scrollView.subviews,
    /// and reset their frame to zero.
    ///
    /// See also https://developer.apple.com/forums/thread/798392.
    ///
    /// This bug is only present in macOS 26.0.
    @available(macOS, introduced: 26.0, obsoleted: 26.1)
    private func handleFrameChangeForNSScrollPocket(_ notification: Notification) {
        guard let window = window as? HiddenTitlebarTerminalWindow else { return }
        guard !window.styleMask.contains(.fullScreen) else { return }
        guard let view = notification.object as? NSView else { return }
        guard view.className.contains("NSScrollPocket") else { return }
        guard scrollView.subviews.contains(view) else { return }
        // These guards to avoid an infinite loop don't actually seem necessary.
        // The number of times we reach this point during any given event (e.g.,
        // creating a split) is the same either way. We keep them anyway out of
        // an abundance of caution.
        view.postsFrameChangedNotifications = false
        view.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
        view.postsFrameChangedNotifications = true
    }

    // MARK: Mouse events

    override func mouseMoved(with: NSEvent) {
        // When the OS preferred style is .legacy, the user should be able to
        // click and drag the scroller without using scroll wheels or gestures,
        // so we flash it when the mouse is moved over the scrollbar area.
        guard NSScroller.preferredScrollerStyle == .legacy else { return }
        scrollView.flashScrollers()
    }

    override func updateTrackingAreas() {
        // To update our tracking area we just recreate it all.
        trackingAreas.forEach { removeTrackingArea($0) }

        super.updateTrackingAreas()

        // Our tracking area is the scroller frame
        guard let scroller = scrollView.verticalScroller else { return }
        addTrackingArea(NSTrackingArea(
            rect: convert(scroller.bounds, from: scroller),
            options: [
                .mouseMoved,
                .activeInKeyWindow,
            ],
            owner: self,
            userInfo: nil))
    }
}

/// The full-size blank document preserves terminal scroll range, while the
/// native footer reduces visible terminal rows. Keep that row-based thumb size
/// through AppKit's own reflections, including those during a live drag.
class SurfaceNativeScrollView: NSScrollView {
    var nativeKnobProportion: CGFloat?

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        if let nativeKnobProportion {
            verticalScroller?.knobProportion = nativeKnobProportion
        }
    }
}

enum SurfaceScrollerTrack {
    @MainActor
    @discardableResult
    static func applyBottomInset(_ height: CGFloat, to scrollView: NSScrollView) -> Bool {
        let bottom = height.isFinite ? min(max(0, height), max(0, scrollView.bounds.height)) : 0
        var insets = scrollView.scrollerInsets
        guard insets.bottom != bottom else { return false }
        insets.bottom = bottom
        scrollView.scrollerInsets = insets
        scrollView.tile()
        return true
    }
}

/// Keeps a native scrollbar drag in terminal row coordinates while output,
/// font changes, or editor reservations change its document's pixel geometry.
struct SurfaceScrollSynchronization {
    struct Geometry: Equatable {
        let maximumRow: UInt64
        let cellHeight: CGFloat
        let viewportHeight: CGFloat
        let documentHeight: CGFloat
        let knobProportion: CGFloat

        init?(total: UInt64, visibleRows: UInt64, cellHeight: CGFloat, viewportHeight: CGFloat) {
            guard cellHeight.isFinite, cellHeight > 0,
                  viewportHeight.isFinite, viewportHeight >= 0 else { return nil }
            let maximumRow = total > visibleRows ? total - visibleRows : 0
            let documentHeight = CGFloat(maximumRow) * cellHeight + viewportHeight
            guard documentHeight.isFinite else { return nil }
            self.maximumRow = maximumRow
            self.cellHeight = cellHeight
            self.viewportHeight = viewportHeight
            self.documentHeight = documentHeight
            self.knobProportion = total == 0 ? 1 : min(1, CGFloat(visibleRows) / CGFloat(total))
        }

        func clampedRow(_ row: CGFloat) -> CGFloat {
            guard row.isFinite else { return 0 }
            return min(max(row, 0), CGFloat(maximumRow))
        }

        func row(at originY: CGFloat) -> CGFloat {
            clampedRow((documentHeight - viewportHeight - originY) / cellHeight)
        }

        func origin(for row: CGFloat) -> CGFloat {
            (CGFloat(maximumRow) - clampedRow(row)) * cellHeight
        }

        func integerRow(_ row: CGFloat) -> UInt64 {
            let clamped = clampedRow(row)
            // CGFloat rounds UInt64.max upward, so handle the endpoint before
            // converting back to avoid overflow even for an invalid snapshot.
            return clamped >= CGFloat(maximumRow) ? maximumRow : UInt64(clamped)
        }
    }

    private(set) var isLiveScrolling = false
    private var geometry: Geometry?
    private var liveRow: CGFloat?

    mutating func begin(originY: CGFloat) {
        isLiveScrolling = true
        liveRow = geometry?.row(at: originY)
    }

    mutating func end() -> UInt64? {
        let finalRow = liveRow.flatMap { geometry?.integerRow($0) }
        isLiveScrolling = false
        liveRow = nil
        return finalRow
    }

    /// Returns a new clip origin only for a core update outside a drag or a
    /// geometry change during one. Ordinary acknowledgments cannot move a drag.
    mutating func synchronize(geometry: Geometry?, coreRow: UInt64) -> CGFloat? {
        let previous = self.geometry
        self.geometry = geometry
        guard let geometry else { return nil }
        if !isLiveScrolling { return geometry.origin(for: CGFloat(coreRow)) }
        guard previous != geometry else { return nil }
        let row = geometry.clampedRow(liveRow ?? CGFloat(coreRow))
        liveRow = row
        return geometry.origin(for: row)
    }

    mutating func scroll(originY: CGFloat) -> UInt64? {
        guard isLiveScrolling, let geometry else { return nil }
        let row = geometry.row(at: originY)
        liveRow = row
        return geometry.integerRow(row)
    }
}
