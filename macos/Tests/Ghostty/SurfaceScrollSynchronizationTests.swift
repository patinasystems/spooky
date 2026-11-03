import Foundation
import Testing
@testable import Ghostty

struct SurfaceScrollSynchronizationTests {
    @Test func terminalRowsIncludeViewportPaddingAndClampBothEdges() throws {
        let geometry = try #require(geometry(visibleRows: 27))
        #expect(geometry.documentHeight == 20_060)
        #expect(geometry.origin(for: 960) == 260)
        #expect(geometry.row(at: 260) == 960)
        #expect(geometry.integerRow(geometry.row(at: -100)) == 973)
        #expect(geometry.integerRow(geometry.row(at: 30_000)) == 0)
        #expect(geometry.origin(for: 10_000) == 0)
        #expect(geometry.origin(for: -10) == 19_460)
    }

    @Test func changingEditorReservationPreservesLiveLogicalRow() throws {
        var state = SurfaceScrollSynchronization()
        let before = try #require(geometry())
        let after = try #require(geometry(visibleRows: 27))
        #expect(state.synchronize(geometry: before, coreRow: 960) == 200)
        state.begin(originY: 200)

        // Reserving three additional rows changes the document height by 60px.
        // Leaving its old clip origin would incorrectly scroll from 960 to 963.
        #expect(after.row(at: 200) == 963)
        #expect(state.synchronize(geometry: after, coreRow: 960) == 260)
        #expect(state.scroll(originY: 260) == 960)
    }

    @Test func outputAndFontResizePreserveFractionalDragPosition() throws {
        var state = SurfaceScrollSynchronization()
        let before = try #require(geometry())
        _ = state.synchronize(geometry: before, coreRow: 900)
        state.begin(originY: before.origin(for: 900))
        #expect(state.scroll(originY: before.origin(for: 924.25)) == 924)

        let after = try #require(geometry(total: 1_010, visibleRows: 25, cellHeight: 18, viewportHeight: 500))
        let updatedOrigin = state.synchronize(geometry: after, coreRow: 900)
        let origin = try #require(updatedOrigin)
        #expect(origin == after.origin(for: 924.25))
        #expect(after.row(at: origin) == 924.25)
        #expect(state.scroll(originY: origin) == 924)
    }

    @Test func liveAcknowledgmentsDoNotMoveDragAndReleaseReconcilesLatestCoreRow() throws {
        var state = SurfaceScrollSynchronization()
        let geometry = try #require(geometry())
        _ = state.synchronize(geometry: geometry, coreRow: 100)
        state.begin(originY: geometry.origin(for: 100))
        #expect(state.scroll(originY: geometry.origin(for: 125.5)) == 125)
        #expect(state.synchronize(geometry: geometry, coreRow: 110) == nil)
        #expect(state.synchronize(geometry: geometry, coreRow: 125) == nil)

        _ = state.end()
        #expect(!state.isLiveScrolling)
        #expect(state.synchronize(geometry: geometry, coreRow: 125) == geometry.origin(for: 125))
        #expect(state.scroll(originY: 0) == nil)
    }

    @Test func releaseRoundsFinalRequestedRowWithoutReapplyingLaggingAcknowledgment() throws {
        var state = SurfaceScrollSynchronization()
        let geometry = try #require(geometry())
        _ = state.synchronize(geometry: geometry, coreRow: 125)
        state.begin(originY: geometry.origin(for: 125))
        #expect(state.scroll(originY: geometry.origin(for: 130.75)) == 130)
        #expect(state.synchronize(geometry: geometry, coreRow: 125) == nil)

        let finalRow = state.end()
        #expect(finalRow == 130)
        let releaseOrigin = state.synchronize(geometry: geometry, coreRow: finalRow ?? 125)
        #expect(releaseOrigin == geometry.origin(for: 130))
        // Release has no pending-target state: later authoritative snapshots
        // still apply, including an independent terminal scroll or new input.
        #expect(state.synchronize(geometry: geometry, coreRow: 140) == geometry.origin(for: 140))
    }

    @Test func shrinkingHistoryClampsLiveRowToNewBottom() throws {
        var state = SurfaceScrollSynchronization()
        let before = try #require(geometry())
        _ = state.synchronize(geometry: before, coreRow: 960)
        state.begin(originY: before.origin(for: 960))
        let after = try #require(geometry(total: 100))
        #expect(state.synchronize(geometry: after, coreRow: 960) == 0)
        #expect(state.scroll(originY: -20) == 70)
    }

    @Test func invalidSnapshotsAndPixelValuesCannotUnderflowOrOverflow() throws {
        let empty = try #require(geometry(total: 2, visibleRows: 30))
        #expect(empty.maximumRow == 0)
        #expect(empty.documentHeight == 600)
        #expect(empty.origin(for: CGFloat(UInt64.max)) == 0)
        #expect(empty.integerRow(.nan) == 0)
        let enormous = try #require(geometry(total: UInt64.max, visibleRows: 0))
        #expect(enormous.integerRow(CGFloat(UInt64.max)) == UInt64.max)
        #expect(geometry(cellHeight: 0) == nil)
        #expect(geometry(cellHeight: .infinity) == nil)
        #expect(geometry(viewportHeight: .nan) == nil)
    }

    @Test func occludedPromptTailKeepsScrollRangeButUsesOnlyVisibleRowsForThumb() throws {
        let raw = try #require(geometry(total: 234, visibleRows: 34, cellHeight: 17))
        let visible = try #require(geometry(total: 232, visibleRows: 32, cellHeight: 17))
        #expect(visible.maximumRow == raw.maximumRow)
        #expect(visible.documentHeight == raw.documentHeight)
        #expect(visible.origin(for: 197) == raw.origin(for: 197))
        #expect(visible.knobProportion == CGFloat(32) / 232)
        #expect(visible.knobProportion < raw.knobProportion)
    }

    private func geometry(
        total: UInt64 = 1_000,
        visibleRows: UInt64 = 30,
        cellHeight: CGFloat = 20,
        viewportHeight: CGFloat = 600
    ) -> SurfaceScrollSynchronization.Geometry? {
        .init(total: total, visibleRows: visibleRows, cellHeight: cellHeight, viewportHeight: viewportHeight)
    }
}
