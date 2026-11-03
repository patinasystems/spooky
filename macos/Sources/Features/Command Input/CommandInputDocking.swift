import Foundation

/// Docking is a per-pane presentation decision, not the terminal's scroll
/// position. Once history overflows, scrolling cannot resize the PTY or move
/// the input between its prompt and the footer. A new pane starts inline.
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
    }

    mutating func placement(layout: CommandTerminalLayout, editing: Bool, recovering: Bool,
                            transferring: Bool, metrics: Metrics) -> Placement {
        let editorHeight = metrics.editorHeight
        let containerHeight = metrics.containerHeight
        let padding = metrics.padding
        if editing && !recovering && layout.primary && layout.hasScrollback { hasDocked = true }
        let pinned = recovering || hasDocked
        let line = max(1, layout.cellHeight)
        let reserved = editing && !transferring
            ? (pinned ? editorHeight + line * 2 : max(0, editorHeight - line)) : 0
        let x = max(0, (pinned ? layout.paddingLeft : layout.cursorX) - padding)
        let y = pinned ? max(0, containerHeight - editorHeight)
            : min(max(layout.paddingTop, layout.cursorY), max(0, containerHeight - editorHeight))
        return Placement(pinned: pinned, reservedHeight: reserved, origin: CGPoint(x: x, y: y),
                         shown: editing && (layout.cursorValid || pinned),
                         pinnedOffset: editing && pinned && !transferring ? editorHeight + line * 2 : -1)
    }
}
