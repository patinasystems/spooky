import AppKit

struct CommandHistoryRequest: Sendable {
    let id: UUID
    let revision: UInt64
    let text: String
    let cursorUTF16: Int
}

struct CommandHistoryResponse: Sendable {
    let requestID: UUID
    let revision: UInt64
    /// Most recent first, with each command preserved verbatim.
    let entries: [String]
    var message: String?
}

/// Browses one bounded shell snapshot without giving the shell ownership of
/// native editing. Moving back to the present restores the exact saved draft.
@MainActor
final class CommandHistoryController {
    private weak var textView: CommandTextView?
    private var context: String?
    private var revision: UInt64 = 0
    private var request: CommandHistoryRequest?
    private struct Browse {
        let draft: String
        let selection: NSRange
        var entries: [String]?
        var position = 0
        var displayedText: String
    }
    private var browse: Browse?
    private(set) var applying = false
    var isBrowsing: Bool { (browse?.position ?? -1) >= 0 }

    init(textView: CommandTextView) { self.textView = textView }

    func setContext(_ value: String?) {
        guard value != context else { return }
        context = value
        reset()
    }

    func reset() {
        let pending = request != nil
        revision &+= 1
        request = nil
        browse = nil
        if pending { textView?.onCancelHistory() }
    }

    func willEdit() {
        if !applying { reset() }
    }

    func selectionChanged() {
        guard !applying, let request, let textView else { return }
        if textView.selectedRange() != NSRange(location: request.cursorUTF16, length: 0) { reset() }
    }

    func cancelPending() {
        if request != nil { reset() }
    }

    private var canBrowse: Bool {
        guard context != nil, let textView else { return false }
        let selection = textView.selectedRange()
        return textView.isEditable && !textView.hasMarkedText()
            && selection.length == 0 && selection.location != NSNotFound
            && selection.location <= textView.string.utf16.count
            && textView.window?.firstResponder === textView && textView.window?.isKeyWindow == true
            && textView.canRequestFocus()
            && !textView.isHiddenOrHasHiddenAncestor
    }

    /// Returns false when ordinary TextKit visual-line movement should win.
    func navigate(older: Bool) -> Bool {
        guard canBrowse, let textView, atVisualBoundary(older: older) else { return false }
        if let browse, browse.displayedText != textView.string { reset() }
        guard older || isBrowsing else { return false }
        textView.dismissCompletions()
        guard var value = browse else {
            let selection = textView.selectedRange()
            browse = Browse(draft: textView.string, selection: selection, displayedText: textView.string)
            let request = CommandHistoryRequest(id: UUID(), revision: revision, text: textView.string,
                                                cursorUTF16: selection.location)
            self.request = request
            textView.onRequestHistory(request)
            return true
        }
        if older {
            let last = value.entries.map { $0.count - 1 } ?? 999
            let next = min(last, value.position + 1)
            guard next != value.position else { return true }
            value.position = next
        } else {
            value.position -= 1
        }
        browse = value
        if request != nil {
            if value.position < 0 { reset() }
        } else {
            applyPosition()
        }
        return true
    }

    func receive(_ response: CommandHistoryResponse) {
        guard let request, response.requestID == request.id, response.revision == request.revision else { return }
        guard canBrowse, let textView, textView.string == request.text,
              textView.selectedRange() == NSRange(location: request.cursorUTF16, length: 0), var value = browse else {
            reset()
            return
        }
        self.request = nil
        var bytes = 0
        let entries = response.entries.prefix(1_000).prefix { entry in
            let count = entry.utf8.count
            guard count <= 1_048_576 - bytes else { return false }
            bytes += count
            return true
        }
        guard !entries.isEmpty else { browse = nil; return }
        value.entries = Array(entries)
        value.position = min(value.position, entries.count - 1)
        browse = value
        applyPosition()
    }

    private func applyPosition() {
        guard let textView, var value = browse, let entries = value.entries else { return }
        let text = value.position < 0 ? value.draft : entries[value.position]
        let selection = value.position < 0 ? value.selection : NSRange(location: text.utf16.count, length: 0)
        value.displayedText = text
        browse = value
        applying = true
        defer { applying = false }
        textView.dismissCompletions()
        textView.breakUndoCoalescing()
        textView.insertText(text, replacementRange: NSRange(location: 0, length: textView.string.utf16.count))
        textView.setSelectedRange(selection)
        textView.breakUndoCoalescing()
        textView.scrollRangeToVisible(selection)
    }

    /// Use laid-out fragments, not newline counting: a soft wrap is also a
    /// native text line, and a trailing newline has an extra insertion fragment.
    func atVisualBoundary(older: Bool) -> Bool {
        guard let textView, let manager = textView.layoutManager, let container = textView.textContainer else { return false }
        let selection = textView.selectedRange()
        let length = textView.string.utf16.count
        guard selection.length == 0, selection.location <= length else { return false }
        guard length > 0 else { return true }
        manager.ensureLayout(for: container)
        guard manager.numberOfGlyphs > 0 else { return true }
        let first = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let hasExtra = manager.extraLineFragmentTextContainer === container
        let last = hasExtra ? manager.extraLineFragmentRect
            : manager.lineFragmentRect(forGlyphAt: manager.numberOfGlyphs - 1, effectiveRange: nil)
        let current: NSRect
        if selection.location == length && hasExtra {
            current = manager.extraLineFragmentRect
        } else {
            var character = min(selection.location, length - 1)
            if selection.location > 0 && selection.location < length && textView.selectionAffinity == .upstream {
                let preceding = (textView.string as NSString).character(at: selection.location - 1)
                if preceding != 10 && preceding != 13 { character -= 1 }
            }
            let glyph = manager.glyphIndexForCharacter(at: character)
            current = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        return older ? current.minY <= first.minY : current.minY >= last.minY
    }
}
