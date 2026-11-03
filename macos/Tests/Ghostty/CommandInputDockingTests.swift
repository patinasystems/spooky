import Foundation
import Testing
@testable import Ghostty

struct CommandInputDockingTests {
    private let metrics = CommandInputDocking.Metrics(editorHeight: 30, containerHeight: 600, padding: 6,
                                                       inlineRows: 32, geometryIsSettled: true)

    @Test func shortFreshSessionStartsInline() {
        var docking = CommandInputDocking()
        let placement = place(&docking, layout: geometry())
        #expect(!docking.hasDocked)
        #expect(!placement.pinned)
        #expect(placement.origin == CGPoint(x: 0, y: 90))
        #expect(placement.reservedHeight == 12)
        #expect(placement.pinnedOffset == -1)
        #expect(placement.shown)
    }

    @Test func retainedRowsAboveMostlyEmptyScreenDoNotCauseDocking() {
        var docking = CommandInputDocking()
        var layout = geometry()
        layout.hasScrollback = true
        layout.scrollbackRows = 100
        layout.activeCursorRow = 1
        layout.cursorY = 18
        let placement = place(&docking, layout: layout)
        #expect(!placement.pinned)
        #expect(placement.origin.y == 18)
        // PageList can preserve two history rows while growing 3→10 because
        // its cursor is above the last row; new space appears below it.
        layout.rows = 10
        layout.scrollbackRows = 2
        #expect(!place(&docking, layout: layout).pinned)
    }

    @Test func actualPromptAtBottomDocksEvenWithoutRetainedHistory() {
        var docking = CommandInputDocking()
        let placement = place(&docking, layout: fullInlineGrid())
        #expect(docking.hasDocked)
        #expect(placement.pinned)
        #expect(placement.origin == CGPoint(x: 0, y: 570))
        #expect(placement.reservedHeight == 48)
        #expect(placement.pinnedOffset == 48)
        let headerTop = metrics.containerHeight - placement.pinnedOffset
        #expect(placement.origin.y - headerTop == 18)
    }

    @Test func ownFooterReservationDoesNotCreateAnInlineDockFeedbackLoop() {
        var docking = CommandInputDocking()
        let docked = place(&docking, layout: fullInlineGrid())
        // A one-row header plus the extra input row removed by docking moves
        // the same prompt two rows up and retains those rows as history.
        let applied = dockedGrid(history: 2)
        for _ in 0..<5 { #expect(place(&docking, layout: applied) == docked) }
    }

    @Test func crossingBottomNeverChangesOverflowedDockGeometry() {
        var docking = CommandInputDocking()
        let docked = place(&docking, layout: fullInlineGrid())
        var layout = dockedGrid(history: 50)
        for atBottom in [false, true, false, true] {
            layout.atBottom = atBottom
            layout.cursorValid = atBottom
            layout.cursorY = atBottom ? 522 : -40
            #expect(place(&docking, layout: layout) == docked)
        }
    }

    @Test func browsingRetainedHistoryPinsTemporarilyThenReturnsInline() {
        var docking = CommandInputDocking()
        var layout = geometry()
        layout.scrollbackRows = 2
        layout.hasScrollback = true
        layout.atBottom = false
        layout.cursorValid = false
        #expect(place(&docking, layout: layout).pinned)
        layout.atBottom = true
        layout.cursorValid = true
        let restored = place(&docking, layout: layout)
        #expect(!restored.pinned)
        #expect(restored.origin.y == 90)
    }

    @Test func transientStartupAndResizeSnapshotsCannotLatchOrReleaseDock() {
        var docking = CommandInputDocking()
        var tiny = geometry()
        tiny.rows = 2
        tiny.activeCursorRow = 1
        tiny.scrollbackRows = 2
        let unsettled = CommandInputDocking.Metrics(editorHeight: 30, containerHeight: 600, padding: 6,
                                                    inlineRows: 2, geometryIsSettled: false)
        #expect(!place(&docking, layout: tiny, metrics: unsettled).pinned)
        #expect(!place(&docking, layout: geometry()).pinned)
        let docked = place(&docking, layout: fullInlineGrid())
        #expect(place(&docking, layout: geometry(), metrics: unsettled) == docked)
    }

    @Test func growingPaneReturnsInlineWhenRealHistoryFits() {
        var docking = CommandInputDocking()
        _ = place(&docking, layout: fullInlineGrid())
        var grown = dockedGrid(history: 0)
        grown.rows = 60
        grown.activeCursorRow = 33
        grown.cursorY = 594
        let bigger = CommandInputDocking.Metrics(editorHeight: 30, containerHeight: 1_140, padding: 6,
                                                 inlineRows: 62, geometryIsSettled: true)
        let inline = place(&docking, layout: grown, metrics: bigger)
        #expect(!inline.pinned)
        #expect(inline.origin.y == 594)
        #expect(inline.reservedHeight == 12)
    }

    @Test func projectedGrowthUsesExactHistoryCountInsteadOfAnyHistoryFlag() {
        var docking = CommandInputDocking()
        _ = place(&docking, layout: fullInlineGrid())
        // Only one retained row can be pulled into two newly available rows.
        // There is room below the prompt, so this must return inline.
        #expect(!place(&docking, layout: dockedGrid(history: 1)).pinned)
        #expect(place(&docking, layout: dockedGrid(history: .max)).pinned)
    }

    @Test func clearingToTopReturnsInlineEvenWithOldHistory() {
        var docking = CommandInputDocking()
        _ = place(&docking, layout: fullInlineGrid())
        var cleared = dockedGrid(history: 500)
        cleared.activeCursorRow = 1
        cleared.cursorY = 18
        #expect(!place(&docking, layout: cleared).pinned)
        #expect(!docking.hasDocked)
    }

    @Test func tallDraftMayDockButClearingItRestoresInlineWhenItFits() {
        var docking = CommandInputDocking()
        var layout = geometry()
        layout.activeCursorRow = 28
        layout.cursorY = 504
        #expect(!place(&docking, layout: layout).pinned)
        let tall = CommandInputDocking.Metrics(editorHeight: 210, containerHeight: 600, padding: 6,
                                               inlineRows: 22, geometryIsSettled: true)
        #expect(place(&docking, layout: layout, metrics: tall).pinned)
        // The tall dock left 20 rows; original row 28 is now row 19, with 9
        // rows retained. Expanding to 32 pulls only 9, leaving room below input.
        layout.rows = 20
        layout.activeCursorRow = 19
        layout.cursorY = 342
        layout.scrollbackRows = 9
        layout.hasScrollback = true
        #expect(place(&docking, layout: layout, metrics: tall).pinned)
        #expect(!place(&docking, layout: layout).pinned)
        layout.rows = 32
        layout.activeCursorRow = 28
        layout.cursorY = 504
        layout.scrollbackRows = 0
        layout.hasScrollback = false
        #expect(!place(&docking, layout: layout).pinned)
    }

    @Test func recoveryAndAlternateScreenDoNotChangeLivePromptPolicy() {
        var docking = CommandInputDocking()
        var layout = fullInlineGrid()
        layout.primary = false
        layout.cursorValid = false
        let recovery = docking.placement(layout: layout, editing: true, recovering: true,
                                         transferring: false, metrics: metrics)
        #expect(recovery.pinned && recovery.shown)
        #expect(!docking.hasDocked)
        #expect(!place(&docking, layout: geometry()).pinned)
        let docked = place(&docking, layout: fullInlineGrid())
        let terminal = docking.placement(layout: layout, editing: false, recovering: false,
                                         transferring: false, metrics: metrics)
        #expect(!terminal.shown)
        #expect(terminal.reservedHeight == 0)
        #expect(terminal.pinnedOffset == -1)
        #expect(place(&docking, layout: dockedGrid(history: 2)) == docked)
    }

    @Test func transferReleasesPTYSpaceWithoutReevaluatingTheDock() {
        var docking = CommandInputDocking()
        let before = place(&docking, layout: fullInlineGrid())
        let transfer = docking.placement(layout: geometry(), editing: true, recovering: false,
                                         transferring: true, metrics: metrics)
        #expect(transfer.reservedHeight == 0)
        #expect(transfer.pinnedOffset == -1)
        #expect(transfer.origin == before.origin)
        #expect(place(&docking, layout: dockedGrid(history: 2)) == before)
    }

    private func place(_ docking: inout CommandInputDocking, layout: CommandTerminalLayout,
                       metrics override: CommandInputDocking.Metrics? = nil) -> CommandInputDocking.Placement {
        docking.placement(layout: layout, editing: true, recovering: false,
                          transferring: false, metrics: override ?? metrics)
    }

    private func geometry() -> CommandTerminalLayout {
        var layout = CommandTerminalLayout()
        layout.cursorValid = true
        layout.columns = 80
        layout.rows = 32
        layout.activeCursorRow = 5
        layout.cellHeight = 18
        layout.paddingLeft = 6
        layout.cursorX = 6
        layout.cursorY = 90
        return layout
    }

    private func fullInlineGrid() -> CommandTerminalLayout {
        var layout = geometry()
        layout.activeCursorRow = 31
        layout.cursorY = 558
        return layout
    }

    private func dockedGrid(history: UInt64) -> CommandTerminalLayout {
        var layout = geometry()
        layout.rows = 30
        layout.activeCursorRow = 29
        layout.cursorY = 522
        layout.scrollbackRows = history
        layout.hasScrollback = history > 0
        return layout
    }
}
