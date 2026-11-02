import AppKit
import GhosttyKit

/// AppKit layout around one real terminal surface. Headers occupy shell-reserved
/// rows; output, ANSI handling, selection, and alternate screens stay in Ghostty.
@MainActor
final class NativeCommandSurfaceHost: NSView {
    private let surfaceView: Ghostty.SurfaceView
    private let terminalView: SurfaceScrollView
    private let session: CommandInputSession
    private let editor = CommandInputView(frame: .zero)
    private let headers = CommandHeaderOverlay(frame: .zero)
    private let pinnedHeader = CommandHeaderOverlay(frame: .zero)
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let editButton = NSButton(title: "Edit Command", target: nil, action: nil)
    private let terminalButton = NSButton(title: "Use Terminal", target: nil, action: nil)
    private let draftButton = NSButton(title: "View Draft", target: nil, action: nil)
    private var measuredHeight: CGFloat = 0
    private var synchronizing = false
    private var background = NSColor.black

    override var isFlipped: Bool { true }

    init(size: CGSize, surfaceView: Ghostty.SurfaceView, session: CommandInputSession) {
        self.surfaceView = surfaceView
        self.session = session
        terminalView = SurfaceScrollView(contentSize: size, surfaceView: surfaceView)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        clipsToBounds = true
        [terminalView, pinnedHeader, editor, notice, editButton, terminalButton, draftButton]
            .forEach { addSubview($0) }
        terminalView.installViewportOverlay(headers)
        notice.font = .systemFont(ofSize: 11)
        notice.isSelectable = true
        for button in [editButton, terminalButton, draftButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
        }
        editButton.action = #selector(editCommand)
        terminalButton.action = #selector(useTerminal)
        draftButton.action = #selector(viewDraft)
        editor.onTextChanged = { [weak session] in session?.setDraft($0) }
        editor.onSubmit = { [weak session] in session?.submit($0) ?? false }
        editor.onUseTerminal = { [weak session] in session?.useTerminal() }
        editor.onRequestCompletion = { [weak session] in session?.requestCompletion($0) }
        editor.onCancelCompletion = { [weak session] in session?.cancelCompletion() }
        session.onCompletion = { [weak self] in self?.editor.receiveCompletions($0) }
        editor.canRequestFocus = { [weak self] in self?.canFocusEditor ?? false }
        editor.onFocusChanged = { [weak self] focused in
            guard focused, let self else { return }
            self.surfaceView.focusDidChange(false)
            self.surfaceView.setCursorVisibility(true)
            if let controller = self.window?.windowController as? BaseTerminalController,
               controller.focusedSurface !== self.surfaceView {
                controller.focusedSurfaceDidChange(to: self.surfaceView)
            }
        }
        editor.onContentHeightChanged = { [weak self] height in
            guard let self, abs(self.measuredHeight - height) > 0.25 else { return }
            self.measuredHeight = height
            self.synchronize()
        }
        session.onChange = { [weak self] in self?.synchronize() }
        synchronize()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        synchronize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        synchronize()
    }

    private var canFocusEditor: Bool {
        guard let window, window.isKeyWindow else { return false }
        if let controller = window.windowController as? BaseTerminalController,
           let focused = controller.focusedSurface { return focused === surfaceView }
        return window.firstResponder === surfaceView || window.firstResponder === editor.textView
    }

    private func synchronize() {
        guard !synchronizing, bounds.width > 0, bounds.height > 0 else { return }
        let measurement = CommandInputDiagnostics.begin(.hostSynchronize)
        defer { CommandInputDiagnostics.end(measurement) }
        synchronizing = true
        defer { synchronizing = false }
        let geometry = session.layout
        let line = max(1, geometry.cellHeight)
        let height = min(max(line, measuredHeight), max(line, min(line * 12, bounds.height * 0.45)))
        let recovering = session.editorVisible && session.isRecoveringDraft
        let transferring = session.isTransferringSubmission
        let editing = recovering || (session.editorVisible && geometry.primary && session.currentBlockID != nil)
        // Recovery must remain selectable even when no primary prompt exists.
        let browsing = recovering || (editing && !geometry.atBottom)
        let reserved = editing && !transferring ? (browsing ? height + line : max(0, height - line)) : 0
        let terminalHeight = max(line * 2, bounds.height - reserved)
        let x = browsing ? geometry.paddingLeft : geometry.cursorX
        let y = browsing ? max(0, bounds.height - height)
            : min(max(geometry.paddingTop, geometry.cursorY), max(0, bounds.height - height))
        let shown = editing && (geometry.cursorValid || browsing)

        background = configColor("background", fallback: .black)
        let foreground = configColor("foreground", fallback: .textColor)
        layer?.backgroundColor = background.cgColor
        let terminalFrame = NSRect(x: 0, y: 0, width: bounds.width, height: terminalHeight)
        if terminalView.frame != terminalFrame {
            terminalView.frame = terminalFrame
            terminalView.needsLayout = true
        }
        // This must finish before submit returns: only then can the session
        // compare applied terminal dimensions with the requested surface size.
        terminalView.layoutSubtreeIfNeeded()

        headers.frame = NSRect(x: 0, y: 0, width: bounds.width, height: terminalHeight)
        headers.rows = geometry.primary ? geometry.blocks.filter(\.hasHeader).map {
            CommandHeaderOverlay.Row(y: $0.headerY, metadata: session.blockMetadata[$0.id],
                                     current: $0.id == session.currentBlockID)
        } : []
        headers.configure(line: line, padding: geometry.paddingLeft, foreground: foreground, background: background)
        pinnedHeader.frame = NSRect(x: 0, y: max(0, y - line), width: bounds.width, height: line)
        pinnedHeader.isHidden = !browsing
        pinnedHeader.rows = [.init(y: 0, metadata: session.currentBlockID.flatMap { session.blockMetadata[$0] },
                                  current: true, title: recovering ? "Retained draft (read only)" : nil)]
        pinnedHeader.configure(line: line, padding: geometry.paddingLeft, foreground: foreground, background: background)

        if !shown && window?.firstResponder === editor.textView {
            window?.makeFirstResponder(surfaceView)
        }
        editor.isHidden = !shown
        editor.setAccessibilityHidden(!shown)
        // Keep the submitted draft over the old prompt while the PTY expands
        // behind it. Following the terminal cursor here would expose its block
        // caret before ZLE has redisplayed/accepted the submitted buffer.
        let editorFrame = transferring && !editor.frame.isEmpty ? editor.frame
            : NSRect(x: x, y: y, width: max(1, bounds.width - x - geometry.paddingLeft), height: height)
        if editor.frame != editorFrame {
            editor.dismissCompletions()
            editor.frame = editorFrame
            editor.needsLayout = true
        }
        editor.configureAppearance(font: session.editorFont, textColor: foreground,
                                   backgroundColor: background, minimumLineHeight: line)
        editor.setDraft(session.draft)
        editor.setEditable(session.isEditable && shown && !recovering && !surfaceView.readonly)
        editor.requestFocus(token: shown && canFocusEditor ? session.focusRequest : 0)
        editor.layoutSubtreeIfNeeded()
        layoutNotice(foreground: foreground)
    }

    private func layoutNotice(foreground: NSColor) {
        let message = session.notice
        notice.isHidden = message == nil
        terminalButton.isHidden = message == nil
        draftButton.isHidden = message == nil || session.draft.isEmpty
        editButton.isHidden = message != nil || session.editorVisible || !session.canReturnToEditor
        notice.stringValue = message ?? ""
        notice.textColor = foreground
        notice.backgroundColor = background
        notice.drawsBackground = true
        let width = max(1, min(420, bounds.width - 16))
        let noticeBottom = session.isRecoveringDraft
            ? max(76, editor.frame.minY - session.layout.cellHeight - 8) : bounds.height
        notice.frame = NSRect(x: max(8, bounds.width - width - 8), y: max(0, noticeBottom - 76), width: width, height: 42)
        terminalButton.frame = NSRect(x: max(8, bounds.width - 222), y: max(0, noticeBottom - 30), width: 110, height: 24)
        draftButton.frame = NSRect(x: max(8, bounds.width - 108), y: max(0, noticeBottom - 30), width: 100, height: 24)
        editButton.frame = NSRect(x: max(8, bounds.width - 120), y: max(0, bounds.height - 30), width: 112, height: 24)
    }

    private func configColor(_ key: String, fallback: NSColor) -> NSColor {
        guard let config = (NSApp.delegate as? AppDelegate)?.ghostty.config.config else { return fallback }
        var value = ghostty_config_color_s()
        guard ghostty_config_get(config, &value, key, UInt(key.utf8.count)) else { return fallback }
        return NSColor(srgbRed: CGFloat(value.r) / 255, green: CGFloat(value.g) / 255,
                       blue: CGFloat(value.b) / 255, alpha: 1)
    }

    @objc private func editCommand() { session.useEditor() }
    @objc private func useTerminal() { session.useTerminal() }
    @objc private func viewDraft() { session.showRecoveryDraft() }
}

/// Non-interactive paint over the deliberately blank prompt-header rows. Mouse
/// gestures continue to the underlying terminal, including output selection.
@MainActor
private final class CommandHeaderOverlay: NSView {
    struct Row: Equatable {
        let y: CGFloat
        let metadata: CommandBlockMetadata?
        let current: Bool
        var title: String?
    }
    var rows: [Row] = []
    private var renderedRows: [Row] = []
    private var renderedSize: CGSize = .zero
    private var line: CGFloat = 18
    private var padding: CGFloat = 0
    private var foreground = NSColor.textColor
    private var background = NSColor.black
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(line: CGFloat, padding: CGFloat, foreground: NSColor, background: NSColor) {
        guard rows != renderedRows || bounds.size != renderedSize || self.line != line
            || self.padding != padding || self.foreground != foreground || self.background != background else { return }
        renderedRows = rows
        renderedSize = bounds.size
        self.line = line
        self.padding = padding
        self.foreground = foreground
        self.background = background
        CommandInputDiagnostics.record(.headerInvalidation)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let measurement = CommandInputDiagnostics.begin(.headerDraw)
        defer { CommandInputDiagnostics.end(measurement) }
        for row in rows where row.y + line > 0 && row.y < bounds.height {
            // The background and separator are full bleed. Only text reserves
            // padding and scrollbar space; the scroll view draws its scroller
            // above this overlay so the thumb remains uninterrupted.
            let rightInset = max(padding, NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay))
            let rect = NSRect(x: padding, y: row.y,
                              width: max(0, bounds.width - padding - rightInset), height: line)
            background.setFill()
            NSRect(x: 0, y: row.y, width: bounds.width, height: line).fill()
            foreground.withAlphaComponent(0.16).setFill()
            NSRect(x: 0, y: row.y, width: bounds.width, height: 0.5).fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingMiddle
            let font = NSFont.monospacedSystemFont(ofSize: max(9, line * 0.66), weight: .regular)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: foreground.withAlphaComponent(row.current ? 0.7 : 0.5),
                .paragraphStyle: paragraph
            ]
            var suffix = ""
            if let status = row.metadata?.exitStatus { suffix += status == 0 ? "✓" : "exit \(status)" }
            if let elapsed = row.metadata?.elapsed {
                suffix += String(format: "  %.3fs", elapsed)
            } else if row.metadata?.status == "running" { suffix = "running" }
            let rightWidth = (suffix as NSString).size(withAttributes: attributes).width
            let textY = rect.minY + max(1, (line - font.ascender + font.descender) / 2)
            (suffix as NSString).draw(at: NSPoint(x: rect.maxX - rightWidth - 2, y: textY), withAttributes: attributes)
            var label = row.title ?? directoryLabel(row.metadata?.workingDirectory)
            if let branch = row.metadata?.branch, !branch.isEmpty { label += "  ⎇ \(branch)" }
            (label as NSString).draw(in: NSRect(x: rect.minX + 2, y: textY,
                                               width: max(0, rect.width - rightWidth - 14), height: line),
                                    withAttributes: attributes)
        }
    }

    private func directoryLabel(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "local zsh" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let display = cwd == home ? "~" : (cwd.hasPrefix(home + "/") ? "~" + cwd.dropFirst(home.count) : cwd)
        return display.replacingOccurrences(of: "\n", with: "↵")
    }
}
