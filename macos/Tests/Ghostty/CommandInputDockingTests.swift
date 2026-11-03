import Foundation
import Testing
@testable import Ghostty

struct CommandInputDockingTests {
    private let metrics = CommandInputDocking.Metrics(editorHeight: 26, containerHeight: 600, padding: 4)

    @Test func shortFreshSessionStartsInline() {
        var docking = CommandInputDocking()
        let placement = place(&docking, layout: geometry())
        #expect(!docking.hasDocked)
        #expect(!placement.pinned)
        #expect(placement.origin == CGPoint(x: 0, y: 90))
        #expect(placement.reservedHeight == 8)
        #expect(placement.pinnedOffset == -1)
        #expect(placement.shown)
        var emptyTop = geometry()
        emptyTop.atBottom = false
        #expect(!place(&docking, layout: emptyTop).pinned)
    }

    @Test func realScrollbackDocksEvenBeforeAnyScrollGesture() {
        var docking = CommandInputDocking()
        var layout = geometry()
        layout.hasScrollback = true
        #expect(layout.atBottom)
        let placement = place(&docking, layout: layout)
        #expect(docking.hasDocked)
        #expect(placement.pinned)
        #expect(placement.origin == CGPoint(x: 0, y: 574))
        #expect(placement.reservedHeight == 44)
        #expect(placement.pinnedOffset == 44)
        let headerTop = metrics.containerHeight - placement.pinnedOffset
        #expect(placement.origin.y - headerTop == layout.cellHeight)
    }

    @Test func crossingBottomNeverChangesDockedGeometryOrPTYReservation() {
        var docking = CommandInputDocking()
        var layout = geometry()
        layout.hasScrollback = true
        let docked = place(&docking, layout: layout)
        for atBottom in [false, true, false, true] {
            layout.atBottom = atBottom
            layout.cursorValid = atBottom
            layout.cursorY = atBottom ? 160 : -40
            #expect(place(&docking, layout: layout) == docked)
        }
    }

    @Test func dockingSurvivesResizeHistoryFitAndModeChanges() {
        var docking = CommandInputDocking()
        var layout = geometry()
        layout.atBottom = false
        layout.hasScrollback = true
        let docked = place(&docking, layout: layout)
        layout.atBottom = true
        layout.hasScrollback = false
        layout.rows = 80
        #expect(place(&docking, layout: layout) == docked)
        layout.primary = false
        let terminal = docking.placement(layout: layout, editing: false, recovering: false,
                                         transferring: false, metrics: metrics)
        #expect(!terminal.shown)
        #expect(terminal.reservedHeight == 0)
        #expect(terminal.pinnedOffset == -1)
        layout.primary = true
        #expect(place(&docking, layout: layout) == docked)
    }

    @Test func recoveryPinsWithoutChangingFreshSessionPolicy() {
        var docking = CommandInputDocking()
        var layout = geometry()
        layout.primary = false
        layout.atBottom = false
        layout.hasScrollback = true
        layout.cursorValid = false
        let recovery = docking.placement(layout: layout, editing: true, recovering: true,
                                         transferring: false, metrics: metrics)
        #expect(recovery.pinned && recovery.shown)
        #expect(!docking.hasDocked)
        #expect(!place(&docking, layout: geometry()).pinned)
    }

    @Test func transferReleasesPTYSpaceThenRestoresTheSameDock() {
        var docking = CommandInputDocking()
        var layout = geometry()
        layout.hasScrollback = true
        let before = place(&docking, layout: layout)
        let transfer = docking.placement(layout: layout, editing: true, recovering: false,
                                         transferring: true, metrics: metrics)
        #expect(transfer.reservedHeight == 0)
        #expect(transfer.pinnedOffset == -1)
        #expect(transfer.origin == before.origin)
        #expect(place(&docking, layout: layout) == before)
    }

    private func place(_ docking: inout CommandInputDocking, layout: CommandTerminalLayout) -> CommandInputDocking.Placement {
        docking.placement(layout: layout, editing: true, recovering: false, transferring: false, metrics: metrics)
    }

    private func geometry() -> CommandTerminalLayout {
        var layout = CommandTerminalLayout()
        layout.cursorValid = true
        layout.cellHeight = 18
        layout.paddingLeft = 4
        layout.cursorX = 4
        layout.cursorY = 90
        return layout
    }
}
