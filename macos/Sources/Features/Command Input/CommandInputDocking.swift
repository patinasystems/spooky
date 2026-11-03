import Foundation

/// Docking follows the prompt's fit in the prospective inline grid. Retained
/// history alone is not overflow: resizing can preserve history above a mostly
/// empty active screen. Browsing history holds the dock until the live end.
struct CommandInputDocking {
    private(set) var hasDocked = false

    struct Placement: Equatable {
        let pinned: Bool
        let reservedHeight: CGFloat
        let origin: CGPoint
        let shown: Bool
        let pinnedOffset: CGFloat
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
        // Retain the editor's grid reservation until the shell has actually
        // yielded ownership. Releasing it on Return expands/reflows the PTY,
        // then immediately shrinks it again for empty and fast commands.
        let reserved = editing
            ? (pinned ? editorHeight + line : max(0, editorHeight - line)) : 0
        let x = max(0, (pinned ? layout.paddingLeft : layout.cursorX) - padding)
        let y = pinned ? max(0, containerHeight - editorHeight)
            : min(max(layout.paddingTop, layout.cursorY), max(0, containerHeight - editorHeight))
        return Placement(pinned: pinned, reservedHeight: reserved, origin: CGPoint(x: x, y: y),
                         shown: editing && (layout.cursorValid || pinned),
                         pinnedOffset: editing && pinned ? editorHeight + line : -1)
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
