import AppKit
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
        #expect(placement.origin == CGPoint(x: 0, y: 84))
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
        #expect(placement.origin.y == 12)
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
        #expect(placement.reservedHeight == 12)
        #expect(placement.pinnedOffset == 60)
        let headerTop = metrics.containerHeight - placement.pinnedOffset
        #expect(placement.origin.y - headerTop == 30)
    }

    @Test func ownFooterReservationDoesNotCreateAnInlineDockFeedbackLoop() {
        var docking = CommandInputDocking()
        let docked = place(&docking, layout: fullInlineGrid())
        // A two-row header plus the input row moves the same prompt three
        // rows up in a full-reservation fallback, retaining them as history.
        let applied = dockedGrid(history: 3)
        for _ in 0..<5 { #expect(place(&docking, layout: applied) == docked) }
    }

    @Test func crossingBottomNeverChangesOverflowedDockGeometry() {
        var docking = CommandInputDocking()
        let docked = place(&docking, layout: fullInlineGrid())
        var layout = dockedGrid(history: 50)
        for atBottom in [false, true, false, true] {
            layout.atBottom = atBottom
            layout.cursorValid = atBottom
            layout.cursorY = atBottom ? 504 : -40
            #expect(place(&docking, layout: layout) == docked)
        }
    }

    @Test func browsingRetainedHistoryDoesNotDockAShortPrompt() {
        var docking = CommandInputDocking()
        var layout = geometry()
        layout.scrollbackRows = 2
        layout.hasScrollback = true
        layout.atBottom = false
        layout.cursorValid = false
        let browsing = place(&docking, layout: layout)
        #expect(!browsing.pinned && !browsing.shown)
        #expect(!docking.hasDocked)
        layout.atBottom = true
        layout.cursorValid = true
        let restored = place(&docking, layout: layout)
        #expect(!restored.pinned)
        #expect(restored.origin.y == 84)
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
        #expect(inline.origin.y == 588)
        #expect(inline.reservedHeight == 12)
    }

    @Test func projectedGrowthUsesExactHistoryCountInsteadOfAnyHistoryFlag() {
        var docking = CommandInputDocking()
        _ = place(&docking, layout: fullInlineGrid())
        // Only one retained row can be pulled into three newly available rows.
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
        cleared.atBottom = false
        cleared.cursorValid = true
        cleared.cursorY = 72
        let scrolled = place(&docking, layout: cleared)
        #expect(!scrolled.pinned && scrolled.shown)
        #expect(scrolled.origin.y == 66)
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
        #expect(place(&docking, layout: dockedGrid(history: 3)) == docked)
    }

    @MainActor @Test func emptyPromptAfterForegroundProgramUsesOnlyOneLine() {
        let editor = CommandInputView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        editor.configureAppearance(font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                                   textColor: .white, backgroundColor: .black, minimumLineHeight: 18)
        editor.setDraft("claude")
        editor.layout()
        var docking = CommandInputDocking()
        _ = place(&docking, layout: fullInlineGrid())
        var program = fullInlineGrid()
        program.primary = false
        _ = docking.placement(layout: program, editing: false, recovering: false,
                              transferring: false, metrics: metrics)
        editor.setDraft("")
        editor.layout()
        // Cover both a short restored primary screen and a genuinely full one.
        // Neither may turn the previous editor frame into content height.
        for layout in [geometry(), fullInlineGrid()] {
            let provisional = place(&docking, layout: layout)
            let height = CommandInputView.viewportHeight(content: editor.contentHeight, line: 18,
                                                         terminal: 600, pinned: provisional.pinned)
            #expect(height == 30)
            let values = CommandInputDocking.Metrics(editorHeight: height, containerHeight: 600,
                                                     padding: 6, inlineRows: 32, geometryIsSettled: true)
            let placement = place(&docking, layout: layout, metrics: values)
            #expect(placement.reservedHeight == 12)
            editor.setFrameSize(NSSize(width: 400, height: height))
            editor.layout()
            #expect(editor.frame.height == 30)
            #expect(editor.scrollView.overflow == 0)
        }
    }

    @Test func transferPreservesPTYSpaceAndPinnedHeaderWithoutReevaluatingTheDock() {
        var docking = CommandInputDocking()
        let before = place(&docking, layout: fullInlineGrid())
        let transfer = docking.placement(layout: geometry(), editing: true, recovering: false,
                                         transferring: true, metrics: metrics)
        #expect(transfer.reservedHeight == before.reservedHeight)
        #expect(transfer.pinnedOffset == before.pinnedOffset)
        #expect(transfer.origin == before.origin)
        #expect(place(&docking, layout: dockedGrid(history: 3)) == before)
    }

    @Test func inlineTransferDoesNotResizeThePTY() {
        var docking = CommandInputDocking()
        let before = place(&docking, layout: geometry())
        let transfer = docking.placement(layout: geometry(), editing: true, recovering: false,
                                         transferring: true, metrics: metrics)
        #expect(transfer == before)
    }

    @Test func yieldingToTerminalReleasesReservationEvenWithPendingSubmission() {
        var docking = CommandInputDocking()
        _ = place(&docking, layout: fullInlineGrid())
        for transferring in [true, false] {
            let terminal = docking.placement(layout: geometry(), editing: false, recovering: false,
                                             transferring: transferring, metrics: metrics)
            #expect(!terminal.shown)
            #expect(terminal.reservedHeight == 0)
            #expect(terminal.pinnedOffset == -1)
        }
    }

    @Test func compactDockKeepsInlineReservationAcrossHistoryAndLiveEnd() {
        var docking = CommandInputDocking()
        let inline = place(&docking, layout: geometry())
        var layout = fullInlineGrid()
        layout.scrollbackRows = 200
        for bottom in [true, false, true, false] {
            layout.atBottom = bottom
            let dock = place(&docking, layout: layout)
            #expect(dock.pinned)
            #expect(dock.coveredRows == 3)
            #expect(dock.reservedHeight == inline.reservedHeight)
        }
    }

    @Test func overwrittenPromptTailRestoresFullReservationWithoutChangingDockPosition() {
        var docking = CommandInputDocking()
        var layout = fullInlineGrid()
        let compact = place(&docking, layout: layout)
        layout.compactPromptRows = 0
        let fallback = place(&docking, layout: layout)
        #expect(fallback.pinned && fallback.coveredRows == 0)
        #expect(fallback.reservedHeight == compact.reservedHeight + 3 * layout.cellHeight - metrics.padding)
        #expect(fallback.origin == compact.origin)
        #expect(fallback.pinnedOffset == compact.pinnedOffset)
        layout.compactPromptRows = 3
        #expect(place(&docking, layout: layout) == compact)
    }

    @Test func legacyTwoRowTailCannotHideAnExtraOutputRowUnderTheTallerFooter() {
        var docking = CommandInputDocking()
        var layout = fullInlineGrid()
        layout.compactPromptRows = 2
        let legacy = place(&docking, layout: layout)
        #expect(legacy.pinned)
        #expect(legacy.coveredRows == 0)
        #expect(legacy.reservedHeight == metrics.editorHeight + 2 * layout.cellHeight - metrics.padding)
        #expect(legacy.pinnedOffset == legacy.reservedHeight)
        layout.compactPromptRows = 3
        let current = place(&docking, layout: layout)
        #expect(current.coveredRows == 3)
        #expect(current.reservedHeight == metrics.editorHeight - layout.cellHeight)
        #expect(current.origin == legacy.origin)
        #expect(current.pinnedOffset == legacy.pinnedOffset)
    }

    @MainActor
    @Test func actualEditorInsetsShareOneCaptionGapInlineAndPinned() {
        for line: CGFloat in [17, 18] {
            for draft in ["", "first\n"] {
                let editor = CommandInputView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
                editor.configureAppearance(font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                                           textColor: .white, backgroundColor: .black, minimumLineHeight: line)
                editor.setDraft(draft)
                let height = max(line + 12, editor.contentHeight)
                editor.frame.size.height = height
                editor.needsLayout = true
                editor.layoutSubtreeIfNeeded()
                let contentOrigin = editor.convert(editor.textView.bounds.origin, from: editor.textView).y
                let contentTop = editor.isFlipped ? contentOrigin - editor.bounds.minY : editor.bounds.maxY - contentOrigin
                #expect(contentTop == 6)
                #expect(editor.bounds.maxY - editor.scrollView.frame.maxY == 6)

                for pinned in [false, true] {
                    var docking = CommandInputDocking()
                    var layout = geometry()
                    layout.cellHeight = line
                    layout.activeCursorRow = pinned ? 31 : 2
                    layout.cursorY = CGFloat(layout.activeCursorRow) * line
                    layout.compactPromptRows = pinned ? 3 : 0
                    let values = CommandInputDocking.Metrics(editorHeight: height, containerHeight: 600, padding: 6,
                                                            inlineRows: 32, geometryIsSettled: true)
                    let placement = place(&docking, layout: layout, metrics: values)
                    let captionBottom = pinned
                        ? values.containerHeight - placement.pinnedOffset + 2 * line - 6
                        : layout.cursorY - 6
                    let nativeTextTop = placement.origin.y + contentTop
                    for scale: CGFloat in [1, 2] {
                        #expect((nativeTextTop - captionBottom) * scale == 6 * scale)
                    }
                    #expect(placement.pinned == pinned)
                    #expect(placement.reservedHeight == height - line)
                    #expect(placement.coveredRows == (pinned ? 3 : 0))
                    if !pinned { #expect(nativeTextTop == layout.cursorY) }
                }
            }
        }
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
        layout.compactPromptRows = 3
        layout.cursorY = 558
        return layout
    }

    private func dockedGrid(history: UInt64) -> CommandTerminalLayout {
        var layout = geometry()
        layout.rows = 29
        layout.compactPromptRows = 3
        layout.activeCursorRow = 28
        layout.cursorY = 504
        layout.scrollbackRows = history
        layout.hasScrollback = history > 0
        return layout
    }
}
