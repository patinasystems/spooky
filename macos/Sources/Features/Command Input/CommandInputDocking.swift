import Foundation

/// Docking follows the prompt's fit in the prospective inline grid. Retained
/// history alone is not overflow: resizing can preserve history above a mostly
/// empty active screen. Browsing history holds the dock until the live end.
struct CommandInputDocking {
    /// The shell reserves two real VT rows for readable caption text and the
    /// six-point margins. The following input row completes the compact tail.
    static let headerRows: UInt32 = 2
    private(set) var hasDocked = false
    private var coveredRows: UInt32 = 0

    struct Placement: Equatable {
        let pinned: Bool
        let reservedHeight: CGFloat
        let origin: CGPoint
        let shown: Bool
        let pinnedOffset: CGFloat
        let coveredRows: UInt32
    }

    struct Metrics {
        let editorHeight: CGFloat
        let containerHeight: CGFloat
        let padding: CGFloat
        /// Row capacity with this draft's inline reservation, without a dock.
        let inlineRows: UInt32
        /// The snapshot and surface both describe the current pane dimensions.
        let geometryIsSettled: Bool
    }

    mutating func placement(layout: CommandTerminalLayout, editing: Bool, recovering: Bool,
                            transferring: Bool, metrics: Metrics) -> Placement {
        let editorHeight = metrics.editorHeight
        let containerHeight = metrics.containerHeight
        let padding = metrics.padding
        if editing && !recovering && !transferring && layout.primary && metrics.geometryIsSettled &&
            layout.rows > 0 && metrics.inlineRows > 0 && layout.activeCursorRow < layout.rows {
            if layout.atBottom {
                hasDocked = projectedPromptRow(layout: layout, inlineRows: metrics.inlineRows) >= metrics.inlineRows - 1
            } else if layout.scrollbackRows > 0 {
                // Keep input accessible while browsing even when the retained
                // rows came from a past, smaller window. Recheck at live end.
                hasDocked = true
            }
        }
        let pinned = recovering || hasDocked
        let line = max(1, layout.cellHeight)
        if !editing || recovering {
            coveredRows = 0
        } else if !transferring && metrics.geometryIsSettled {
            // An older one-row header cannot safely cover the taller footer:
            // use the full reservation until a fresh three-row tail exists.
            coveredRows = pinned && layout.compactPromptRows == Self.headerRows + 1
                ? layout.compactPromptRows : 0
        }
        // Retain the editor's grid reservation until the shell has actually
        // yielded ownership. Releasing it on Return expands/reflows the PTY,
        // then immediately shrinks it again for empty and fast commands.
        // A compact dock reuses the real empty A/B tail underneath its opaque
        // footer. Scrolling between inline and pinned no longer resizes the PTY.
        // Overwritten tails retain the full reservation until a fresh prompt.
        // Header bottom padding and editor top padding occupy the same blank
        // band. Their visual gap is six points, not the sum of both insets.
        let footerHeight = editorHeight + CGFloat(Self.headerRows) * line - padding
        let reserved = editing
            ? (pinned && coveredRows == 0 ? footerHeight : max(0, editorHeight - line)) : 0
        let x = max(0, (pinned ? layout.paddingLeft : layout.cursorX) - padding)
        let y = pinned ? max(0, containerHeight - editorHeight)
            : min(max(0, layout.cursorY - padding), max(0, containerHeight - editorHeight))
        return Placement(pinned: pinned, reservedHeight: reserved, origin: CGPoint(x: x, y: y),
                         shown: editing && (layout.cursorValid || pinned),
                         pinnedOffset: editing && pinned ? footerHeight : -1,
                         coveredRows: editing && pinned ? coveredRows : 0)
    }

    /// Mirror PageList's row-resize behavior without walking history. Growth
    /// pulls history only when the old cursor is on the last active row;
    /// otherwise it preserves the cursor and appends blank rows. This removes
    /// the dock's own reservation from the decision, avoiding an inline/dock
    /// feedback loop. Shrink trims blanks before moving the cursor upward.
    private func projectedPromptRow(layout: CommandTerminalLayout, inlineRows: UInt32) -> UInt32 {
        if inlineRows <= layout.rows { return min(layout.activeCursorRow, inlineRows - 1) }
        guard layout.activeCursorRow == layout.rows - 1 else { return layout.activeCursorRow }
        let pulled = min(layout.scrollbackRows, UInt64(inlineRows - layout.rows))
        return layout.activeCursorRow + UInt32(pulled)
    }
}
