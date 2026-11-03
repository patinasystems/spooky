import AppKit

/// Native editing owns its terminal pane without impersonating another pane,
/// a search field, or a responder in an inactive window. Cursor visibility is
/// handled separately in the renderer; PTY focus and secure input use this.
@MainActor
enum NativeCommandFocus {
    /// Pane focus includes native editing for renderer priority and PTY focus.
    /// Only the actual terminal responder may encode keyboard events for the PTY.
    static func ownsTerminalKeyboard(paneIsFocused: Bool, firstResponder: NSResponder?, surface: NSView) -> Bool {
        paneIsFocused && firstResponder === surface
    }

    static func isFocused(windowIsKey: Bool, paneIsSelected: Bool, firstResponder: NSResponder?,
                          surface: NSView, editor: NSView?) -> Bool {
        guard windowIsKey, paneIsSelected, !surface.isHiddenOrHasHiddenAncestor else { return false }
        if firstResponder === surface { return true }
        guard let editor, !editor.isHiddenOrHasHiddenAncestor else { return false }
        return firstResponder === editor
    }
}
