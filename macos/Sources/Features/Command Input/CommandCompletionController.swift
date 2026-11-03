import AppKit

/// Owns suggestion lifetime independently of TextKit's document/selection state.
/// A suggestion never enters the document until the user explicitly accepts it.
@MainActor
final class CommandCompletionController {
    private weak var textView: CommandTextView?
    private var revision: UInt64 = 0
    private var request: CommandCompletionRequest?
    private var awaitingResponse = false
    private var filter: CommandCompletionFilter?
    private var popup: CommandCompletionView?
    private let ghost = CommandInlineSuggestionView()
    private var automaticTask: Task<Void, Never>?
    private var automaticSelection: NSRange?
    private var editing = false
    private var accepting = false
    private var message: String?
    private(set) var items: [CommandCompletionCandidate] = []
    private(set) var selectedIndex = 0
    private(set) var listVisible = false
    private(set) var inlineSuggestion: String?
    /// The `@` file picker shares this popup but never zsh's request state.
    private(set) var filePicker = CommandFilePicker()
    /// Set by `CommandTextView.keyDown` only for a typed `@` keystroke, so
    /// paste, IME commits, history, and undo can never open the picker.
    var pendingFileTrigger = false
    var filePickerActive: Bool { filePicker.isActive }

    init(textView: CommandTextView) {
        self.textView = textView
        filePicker.onChange = { [weak self] in self?.filePickerDidChange() }
    }

    /// Test and integration seam; replaces any active picker session.
    func installFilePicker(_ picker: CommandFilePicker) {
        filePicker.end()
        filePicker = picker
        picker.onChange = { [weak self] in self?.filePickerDidChange() }
    }

    deinit { automaticTask?.cancel() }

    func willEdit() { editing = true }

    func didEdit() {
        revision &+= 1
        defer { editing = false }
        let typedAt = pendingFileTrigger
        pendingFileTrigger = false
        guard !accepting else { return }
        cancelAutomatic()
        guard let textView, !textView.string.isEmpty else { dismiss(); return }
        if filePicker.isActive {
            if canSuggest, filePicker.refresh(text: textView.string, cursor: textView.selectedRange().location) {
                presentFilePicker()
                return
            }
            // The `@query` ended (whitespace, deletion, caret moved): leave
            // its text as typed and resume ordinary completion behavior.
            dismiss()
        }
        if typedAt, beginFilePicker() { return }
        if let filter, let request, canSuggest,
           let matches = filter.items(in: textView.string, cursorUTF16: textView.selectedRange().location) {
            self.request = .init(id: request.id, revision: revision, text: textView.string,
                                 cursorUTF16: textView.selectedRange().location, automatic: request.automatic)
            items = matches
            selectedIndex = 0
            message = matches.isEmpty ? "No matching completions" : nil
            present()
            // Refresh a miss after a short pause. A shell's bounded initial
            // result set may not include the newly typed prefix.
            if matches.isEmpty { scheduleAutomatic() }
            return
        }
        dismiss()
        scheduleAutomatic()
    }

    func externalEdit() {
        revision &+= 1
        dismiss()
    }

    func selectionChanged() {
        guard !editing, !accepting else { return }
        if filePicker.isActive {
            guard let textView, textView.selectedRange().length == 0,
                  filePicker.activeRange(in: textView.string, cursor: textView.selectedRange().location) != nil else {
                dismiss()
                return
            }
            return
        }
        if let request, !isCurrent(request) { dismiss() }
        // A selection/caret move also cancels a debounced request whose result
        // has not arrived yet. It does not start unsolicited shell work.
        if let automaticSelection, automaticSelection != textView?.selectedRange() { cancelAutomatic() }
    }

    private var canSuggest: Bool {
        guard let textView else { return false }
        return textView.isEditable && !textView.hasMarkedText()
            && textView.selectedRange().length == 0 && textView.selectedRange().location != NSNotFound
            && textView.window?.firstResponder === textView && textView.window?.isKeyWindow == true
            && !textView.isHiddenOrHasHiddenAncestor
    }

    private func scheduleAutomatic() {
        guard canSuggest, let textView, !textView.string.isEmpty, textView.string.utf8.count <= 16_384 else { return }
        let expected = revision
        automaticSelection = textView.selectedRange()
        automaticTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            guard !Task.isCancelled, let self, self.revision == expected else { return }
            self.automaticTask = nil
            self.automaticSelection = nil
            self.requestAutomaticNow()
        }
    }

    /// Shared by the debouncer and deterministic tests; never accepts a result.
    func requestAutomaticNow() {
        guard canSuggest, let textView, !textView.string.isEmpty, textView.string.utf8.count <= 16_384 else { return }
        requestCompletions(showList: listVisible, automatic: true, broaden: request == nil || !items.isEmpty)
    }

    private func requestCompletions(showList: Bool, automatic: Bool, broaden: Bool = true) {
        dismiss()
        guard canSuggest, let textView else { return }
        let selection = textView.selectedRange()
        let query = broaden ? CommandCompletionQuery.broadened(text: textView.string, cursorUTF16: selection.location) : nil
        let value = CommandCompletionRequest(id: UUID(), revision: revision, text: textView.string,
                                             cursorUTF16: selection.location, automatic: automatic,
                                             queryText: query?.text, queryCursorUTF16: query?.cursorUTF16)
        request = value
        awaitingResponse = true
        listVisible = showList
        if showList { present() }
        textView.onRequestCompletion(value)
    }

    func receive(_ response: CommandCompletionResponse) {
        guard let request, response.requestID == request.id, response.revision == request.revision else { return }
        guard isCurrent(request), canSuggest else { dismiss(); return }
        awaitingResponse = false
        let valid = response.items.filter { Self.valid($0, in: request.text) }
        filter = CommandCompletionFilter(request: request, items: valid)
        // A provider may return whole buffers, but native acceptance only owns
        // the active token. Never admit a rewrite of its surrounding command.
        items = filter?.items(in: request.text, cursorUTF16: request.cursorUTF16) ?? []
        selectedIndex = 0
        message = items.isEmpty ? (response.message ?? "No matching completions") : nil
        present()
        // A broad shell query is capped at 200 options. If the initial result
        // omitted this prefix, ask once for the exact token instead of getting
        // stuck on the same truncated universe. Never loop on an exact miss.
        if items.isEmpty, request.queryText != nil, request.shellText != request.text { scheduleAutomatic() }
    }

    func dismiss() {
        let hadRequest = request != nil || (!items.isEmpty && !filePicker.isActive) || message != nil
        if filePicker.isActive { filePicker.end() }
        cancelAutomatic()
        request = nil
        awaitingResponse = false
        filter = nil
        items = []
        message = nil
        listVisible = false
        inlineSuggestion = nil
        ghost.removeFromSuperview()
        popup?.dismiss()
        if hadRequest { textView?.onCancelCompletion() }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        if filePicker.isActive { return handleFilePickerKey(event) }
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if event.keyCode == 53, request != nil || automaticTask != nil || listVisible {
            dismiss()
            return true
        }
        guard let textView, textView.isEditable else { return false }
        if event.keyCode == 48, modifiers == .option {
            dismiss()
            accepting = true
            textView.insertText("\t", replacementRange: textView.selectedRange())
            accepting = false
            return true
        }
        guard modifiers.isSubset(of: [.shift]) else { return false }
        switch event.keyCode {
        case 48: // Tab reveals; a second Tab accepts. Shift Tab navigates back.
            if listVisible, !items.isEmpty {
                if modifiers.contains(.shift) { moveSelection(-1) } else { accept(at: selectedIndex) }
            } else { revealList() }
            return true
        case 125: // Down reveals without skipping the best match.
            guard listVisible || inlineSuggestion != nil else { return false }
            if listVisible, !items.isEmpty { moveSelection(1) } else { revealList() }
            return true
        case 126:
            guard listVisible, !items.isEmpty else { return false }
            moveSelection(-1)
            return true
        case 124: // Right accepts only an actually available inline preview.
            guard modifiers.isEmpty, !listVisible, inlineSuggestion != nil else { return false }
            accept(at: selectedIndex)
            return true
        case 36, 76:
            guard modifiers.isEmpty else { dismiss(); return false }
            if listVisible {
                if !items.isEmpty { accept(at: selectedIndex) }
                return true
            }
            // Inline predictions are not command text. Return runs the draft.
            dismiss()
            return false
        default:
            return false
        }
    }

    private func revealList() {
        let retryExact = request != nil && !awaitingResponse && items.isEmpty
        cancelAutomatic()
        if retryExact {
            requestCompletions(showList: true, automatic: false, broaden: false)
        } else if request != nil {
            listVisible = true
            present()
        } else {
            requestCompletions(showList: true, automatic: false)
        }
    }

    private func cancelAutomatic() {
        automaticTask?.cancel()
        automaticTask = nil
        automaticSelection = nil
    }

    private func isCurrent(_ request: CommandCompletionRequest) -> Bool {
        guard let textView else { return false }
        return request.revision == revision && request.text == textView.string
            && textView.selectedRange() == NSRange(location: request.cursorUTF16, length: 0)
    }

    private func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + items.count) % items.count
        popup?.select(index: selectedIndex)
    }

    private func accept(at index: Int) {
        if filePicker.isActive { acceptFile(at: index); return }
        guard let textView, let request, isCurrent(request), items.indices.contains(index), textView.isEditable else {
            dismiss()
            return
        }
        let candidate = items[index]
        guard Self.valid(candidate, in: textView.string) else { dismiss(); return }
        dismiss()
        accepting = true
        defer { accepting = false }
        textView.breakUndoCoalescing()
        textView.insertText(candidate.replacementText, replacementRange: candidate.replacementRange)
        if let cursor = candidate.cursorUTF16 { textView.setSelectedRange(NSRange(location: cursor, length: 0)) }
        textView.breakUndoCoalescing()
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    private func present() {
        if filePicker.isActive { presentFilePicker(); return }
        guard let textView else { return }
        if listVisible {
            inlineSuggestion = nil
            ghost.removeFromSuperview()
            guard textView.window?.isVisible == true else { return }
            if popup == nil {
                popup = CommandCompletionView()
                popup?.onAccept = { [weak self] in self?.accept(at: $0) }
            }
            popup?.show(items: items, message: awaitingResponse ? "Finding completions…" : message,
                        selected: selectedIndex, for: textView)
        } else {
            popup?.dismiss()
            updateInlineSuggestion()
        }
    }

    func updatePosition() {
        guard let textView else { return }
        if listVisible {
            popup?.updatePosition(for: textView)
        } else if canSuggest, let inlineSuggestion {
            // Draft/candidate edits compute this projection in present();
            // selection changes invalidate it. A geometry or appearance
            // update must not rebuild and validate the command again.
            ghost.show(inlineSuggestion, in: textView)
        } else {
            // Losing key-window status can be temporary without changing the
            // draft. Keep its projection available for the next valid layout.
            ghost.removeFromSuperview()
        }
    }

    private func updateInlineSuggestion() {
        guard canSuggest, !listVisible, let textView, let candidate = items.first,
              let preview = Self.preview(candidate, text: textView.string, cursor: textView.selectedRange().location) else {
            inlineSuggestion = nil
            ghost.removeFromSuperview()
            return
        }
        inlineSuggestion = preview
        ghost.show(preview, in: textView)
    }

    static func preview(_ candidate: CommandCompletionCandidate, text: String, cursor: Int) -> String? {
        guard valid(candidate, in: text), let token = CommandCompletionToken.range(in: text, cursorUTF16: cursor),
              NSMaxRange(token) == cursor else { return nil }
        let source = text as NSString
        // Never paint over existing command arguments on the same line.
        let remainder = source.substring(from: cursor).prefix { $0 != "\n" }
        guard remainder.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let result = source.replacingCharacters(in: candidate.replacementRange, with: candidate.replacementText)
        guard let replacement = CommandCompletionToken.replacement(in: result, original: text, range: token) else { return nil }
        let typed = source.substring(with: token)
        guard replacement != typed else { return nil }
        let preview = replacement.hasPrefix(typed) ? String(replacement.dropFirst(typed.count)) : " → " + candidate.displayText
        guard !preview.trimmingCharacters(in: .whitespaces).isEmpty,
              !preview.contains("\n"), !preview.contains("\r") else { return nil }
        return preview
    }

    private static func valid(_ candidate: CommandCompletionCandidate, in text: String) -> Bool {
        let range = candidate.replacementRange
        let length = text.utf16.count
        guard range.location >= 0, range.length >= 0, range.location <= length,
              range.length <= length - range.location,
              CommandCompletionBridge.byteOffset(in: text, cursorUTF16: range.location) != nil,
              CommandCompletionBridge.byteOffset(in: text, cursorUTF16: NSMaxRange(range)) != nil else { return false }
        if let cursor = candidate.cursorUTF16 {
            let result = (text as NSString).replacingCharacters(in: range, with: candidate.replacementText)
            return CommandCompletionBridge.byteOffset(in: result, cursorUTF16: cursor) != nil
        }
        return true
    }
}

// MARK: - `@` file picker

extension CommandCompletionController {
    private func beginFilePicker() -> Bool {
        guard canSuggest, let textView, let cwd = textView.fileSearchDirectory else { return false }
        let cursor = textView.selectedRange().location
        guard cursor > 0, CommandFilePicking.triggers(in: textView.string, at: cursor - 1) else { return false }
        dismiss()
        filePicker.begin(anchor: cursor - 1, cwd: cwd)
        guard filePicker.refresh(text: textView.string, cursor: cursor) else {
            filePicker.end()
            return false
        }
        presentFilePicker()
        return true
    }

    private func filePickerDidChange() {
        guard filePicker.isActive else { return }
        guard canSuggest else { dismiss(); return }
        presentFilePicker()
    }

    private func presentFilePicker() {
        guard let textView, let session = filePicker.session else { return }
        listVisible = true
        inlineSuggestion = nil
        ghost.removeFromSuperview()
        items = filePicker.candidates()
        selectedIndex = filePicker.selectedIndex
        guard textView.window?.isVisible == true else { return }
        let popup = popup ?? {
            let view = CommandCompletionView()
            view.onAccept = { [weak self] in self?.accept(at: $0) }
            self.popup = view
            return view
        }()
        popup.show(items: items, message: filePicker.message, selected: selectedIndex,
                   header: filePicker.header, anchor: session.anchor, for: textView)
    }

    /// Tab drills into a folder or accepts a file; Return accepts either;
    /// Up/Down and Control-N/P select; Command-Up browses the parent; Escape
    /// closes with the text unchanged. Other keys stay native editing.
    private func handleFilePickerKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        switch event.keyCode {
        case 53:
            dismiss()
            return true
        case 48 where modifiers.isEmpty:
            if let entry = filePicker.selectedEntry {
                if entry.isDirectory { browseFilePicker(into: entry.path) } else { acceptFile(at: filePicker.selectedIndex) }
            }
            return true
        case 48 where modifiers == .shift:
            moveFileSelection(-1)
            return true
        case 48:
            dismiss()
            return handleKey(event)
        case 36, 76:
            guard modifiers.isEmpty else { dismiss(); return false }
            acceptFile(at: filePicker.selectedIndex)
            return true
        case 125 where modifiers.isEmpty, 45 where modifiers == .control:
            moveFileSelection(1)
            return true
        case 126 where modifiers.isEmpty, 35 where modifiers == .control:
            moveFileSelection(-1)
            return true
        case 126 where modifiers == .command:
            browseFilePicker(into: nil)
            return true
        default:
            return false
        }
    }

    private func moveFileSelection(_ delta: Int) {
        filePicker.move(delta)
        selectedIndex = filePicker.selectedIndex
        popup?.select(index: selectedIndex)
    }

    /// Scope changes are picker state only; the query text is reset to `@`
    /// so folder names with spaces never enter the draft unquoted.
    private func browseFilePicker(into directory: String?) {
        guard let textView, textView.isEditable,
              let range = filePicker.activeRange(in: textView.string, cursor: textView.selectedRange().location) else {
            dismiss()
            return
        }
        if let directory { filePicker.enter(directory: directory) } else { filePicker.enterParent() }
        if range.length > 1 {
            accepting = true
            textView.breakUndoCoalescing()
            textView.insertText("", replacementRange: NSRange(location: range.location + 1, length: range.length - 1))
            textView.breakUndoCoalescing()
            accepting = false
        }
        guard filePicker.refresh(text: textView.string, cursor: textView.selectedRange().location) else {
            dismiss()
            return
        }
        presentFilePicker()
    }

    /// Accepts only results computed for the current query generation; a
    /// stale list shown while a newer lookup is pending is never inserted.
    private func acceptFile(at index: Int) {
        guard let textView, textView.isEditable,
              let result = filePicker.acceptance(at: index, text: textView.string,
                                                 cursor: textView.selectedRange().location) else { return }
        dismiss()
        accepting = true
        defer { accepting = false }
        textView.breakUndoCoalescing()
        textView.insertText(result.text, replacementRange: result.range)
        textView.breakUndoCoalescing()
        textView.scrollRangeToVisible(textView.selectedRange())
    }
}

/// A clipped, noninteractive annotation. It never alters TextKit storage,
/// selections, undo groups, command bytes, or the editor's measured height.
@MainActor
private final class CommandInlineSuggestionView: NSView {
    private var content = NSAttributedString(string: "")
    private var configuredFont: NSFont?
    private var configuredColor: NSColor?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String, in editor: CommandTextView) {
        guard let window = editor.window else { return }
        let caret = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
        let local = editor.convert(window.convertFromScreen(caret), from: nil)
        if content.string != text || configuredFont != editor.font || configuredColor != editor.textColor {
            configuredFont = editor.font
            configuredColor = editor.textColor
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byClipping
            content = NSAttributedString(string: text, attributes: [
                .font: editor.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: (editor.textColor ?? .labelColor).withAlphaComponent(0.38),
                .paragraphStyle: paragraph
            ])
            needsDisplay = true
        }
        frame = NSRect(x: local.minX, y: local.minY, width: max(0, editor.bounds.maxX - local.minX),
                       height: max(local.height, content.size().height))
        setAccessibilityHidden(true)
        if superview !== editor { editor.addSubview(self) }
    }

    override func draw(_ dirtyRect: NSRect) { content.draw(in: bounds) }
}
