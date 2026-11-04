import AppKit
import Testing
@testable import Ghostty

@MainActor
struct CommandEditorTraceTests {
    @Test func oneDrawKeepsEveryCoalescedInputIdentity() {
        var state = CommandEditorTrace.State()
        state.edit(inputID: 10, now: 1)
        state.edit(inputID: 11, now: 1.01)
        let drawn = state.pending
        #expect(drawn.map(\.inputID) == [10, 11])
        state.drew(through: drawn.last!.revision)
        let waiting = state.beforeWaiting()
        #expect(waiting == drawn)
        #expect(state.pending.isEmpty)
        let waking = state.afterWaiting()
        #expect(waking == drawn)
        let subsequentWake = state.afterWaiting()
        #expect(subsequentWake.isEmpty)
    }

    @Test func laterEditCannotBeRetiredByAnEarlierDraw() {
        var state = CommandEditorTrace.State()
        state.edit(inputID: 1, now: 1)
        let earlierRevision = state.latestRevision
        state.edit(inputID: 2, now: 1.01)
        state.drew(through: earlierRevision)
        let waiting = state.beforeWaiting()
        #expect(waiting.map(\.inputID) == [1, 2])
        #expect(state.pending.map(\.inputID) == [2])
        let waking = state.afterWaiting()
        #expect(waking.map(\.inputID) == [1, 2])
    }

    @Test func multipleEditsInOneInputKeepTheNewestRevision() {
        var state = CommandEditorTrace.State()
        state.edit(inputID: 1, now: 1)
        let earlierRevision = state.latestRevision
        state.edit(inputID: 1, now: 1.01)
        #expect(state.pending.count == 1)
        #expect(state.pending[0].revision > earlierRevision)
        state.drew(through: earlierRevision)
        _ = state.beforeWaiting()
        #expect(state.pending.count == 1)
    }

    @Test func missingDrawExpiresAndResetDoesNotReuseRevisionIDs() {
        var state = CommandEditorTrace.State()
        state.edit(inputID: 1, now: 1)
        state.expire(now: 1.49)
        #expect(state.pending.count == 1)
        state.expire(now: 1.51)
        #expect(state.pending.isEmpty)
        let earlierRevision = state.latestRevision
        state.edit(inputID: 2, now: 2)
        #expect(state.pending[0].revision > earlierRevision)
        state.reset()
        #expect(state.pending.isEmpty)
        let waking = state.afterWaiting()
        #expect(waking.isEmpty)
    }

    @Test func aStalledRunLoopCannotAccumulateUnboundedInputIDs() {
        var state = CommandEditorTrace.State()
        for id in 1...100 { state.edit(inputID: UInt64(id), now: 1) }
        #expect(state.pending.count == CommandEditorTrace.State.capacity)
        #expect(state.pending.last?.inputID == 100)
        #expect(state.pending.first?.inputID == 69)
    }

    @Test func observersDoNotRetainADetachedTrace() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        weak var detached: CommandEditorTrace?
        autoreleasepool {
            let trace = CommandEditorTrace(window: window)
            detached = trace
            trace.edit(inputID: 1)
        }
        #expect(detached == nil)
    }

    @Test func drawBoundsPreserveScrolledViewCoordinatesAndMapToWindowTopLeft() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = FlippedTraceView(frame: NSRect(x: 10, y: 50, width: 300, height: 200))
        // Generic NSViews can draw beyond their bounds on newer AppKit. Match
        // the editor's clipped viewport so visibleRect is the intended region.
        view.clipsToBounds = true
        window.contentView?.addSubview(view)
        view.bounds.origin.y = 120
        let metrics = CommandEditorTrace.drawMetrics(NSRect(x: 12, y: 126, width: 30, height: 18), in: view)
        #expect(metrics["dirty_x"] == 12)
        #expect(metrics["dirty_y"] == 126)
        #expect(metrics["bounds_y"] == 120)
        #expect(metrics["visible_y"] == 120)
        #expect(metrics["dirty_window_x"] == 22)
        #expect(metrics["dirty_window_y"] == 356)
        #expect(metrics["dirty_window_width"] == 30)
        #expect(metrics["dirty_window_height"] == 18)
        #expect(metrics["visible_window_y"] == 350)
        #expect(metrics["view_flipped"] == 1)
        #expect(metrics["backing_scale"] == Double(window.backingScaleFactor))
    }
}

@MainActor
private final class FlippedTraceView: NSView {
    override var isFlipped: Bool { true }
}
