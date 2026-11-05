import AppKit

struct CommandCompletionRequest: Sendable {
    let id: UUID
    let revision: UInt64
    let text: String
    let cursorUTF16: Int
    var automatic = false
    var queryText: String?
    var queryCursorUTF16: Int?

    var shellText: String { queryText ?? text }
    var shellCursorUTF16: Int { queryCursorUTF16 ?? cursorUTF16 }
}

struct CommandCompletionCandidate: Sendable {
    let displayText: String
    let detail: String
    let replacementText: String
    let replacementRange: NSRange
    var cursorUTF16: Int?
}

/// Optional scope line above the list (the `@` picker's folder and status).
struct CommandCompletionHeader: Equatable {
    var title: String
    var status: String
}

struct CommandCompletionResponse: Sendable {
    let requestID: UUID
    let revision: UInt64
    let items: [CommandCompletionCandidate]
    var message: String?
}

/// The overlay shares the terminal window's layer transaction. Submission can
/// dismiss it atomically with the committed Metal frame, without a separate
/// WindowServer window-ordering RPC. The native editor retains first responder.
@MainActor
final class CommandCompletionView: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let table: NSTableView
    private let scrollView = NSScrollView()
    private let surface = CommandOverlaySurface(blending: .withinWindow, castsShadow: true)
    private let headerTitle = NSTextField(labelWithString: "")
    private let headerStatus = NSTextField(labelWithString: "")
    private var header: CommandCompletionHeader?
    private var items: [CommandCompletionCandidate] = []
    private var message: String?
    private var font = CommandCompletionView.fallbackFont
    private(set) var theme = CommandUITheme.fallback
    private var contentWidth = CommandOverlayStyle.minimumPopupWidth
    private var anchorLocation: Int?
    var onAccept: (Int) -> Void = { _ in }
    var isVisible: Bool { surface.superview != nil && !surface.isHiddenOrHasHiddenAncestor }

    override convenience init() {
        self.init(table: CommandCompletionTable())
    }

    /// An injected native table lets regressions observe actual reloads without
    /// showing a window. Production uses the non-focusable completion table.
    init(table: NSTableView) {
        self.table = table
        super.init()
        surface.isHidden = true
        surface.layer?.zPosition = 1_000

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight(for: font)
        table.intercellSpacing = .zero
        table.autoresizingMask = [.width]
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = .clear
        table.style = .plain
        table.focusRingType = .none
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(acceptClickedRow)
        table.setAccessibilityLabel("Command completions")
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        for label in [headerTitle, headerStatus] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = CommandUITheme.fallback.secondary
            label.isHidden = true
            surface.contentView.addSubview(label)
        }
        headerTitle.lineBreakMode = .byTruncatingHead
        headerStatus.alignment = .right
        surface.contentView.addSubview(scrollView)
    }

    func applyTheme(_ theme: CommandUITheme) {
        guard self.theme != theme else { return }
        self.theme = theme
        surface.applyTheme(theme)
        headerTitle.textColor = theme.secondary
        headerStatus.textColor = theme.secondary
        refreshVisibleColors()
    }

    private func refreshVisibleColors() {
        let visible = table.rows(in: table.visibleRect)
        guard visible.location != NSNotFound else { return }
        for row in visible.location..<NSMaxRange(visible) {
            (table.rowView(atRow: row, makeIfNecessary: false) as? CommandCompletionRow)?.theme = theme
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? CommandCompletionCell)?
                .applyTheme(theme, selected: row == table.selectedRow)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { refreshVisibleColors() }

    func show(items: [CommandCompletionCandidate], message: String?, selected: Int,
              header: CommandCompletionHeader? = nil, anchor: Int? = nil, for textView: NSTextView,
              diagnosticInputID: UInt64? = nil) {
        let diagnostic = CommandInputDiagnostics.beginTimeline(
            .completionShow, id: diagnosticInputID, begin: .completionShowBegin, end: .completionShowEnd)
        defer { CommandInputDiagnostics.end(diagnostic) }
        applyTheme((textView as? CommandTextView)?.commandTheme ?? .fallback)
        let editorFont = textView.font ?? font
        let fontChanged = editorFont != font
        let headerChanged = self.header != header
        let rowsChanged = fontChanged || self.items.count != items.count
            || zip(self.items, items).contains { previous, current in
                previous.displayText != current.displayText || previous.detail != current.detail
            }
            || (items.isEmpty && self.message != message)
        // Replacement text/ranges still update even when their rendered labels
        // are identical. This is presentation reuse, never acceptance reuse.
        self.items = items
        self.message = message
        if headerChanged {
            self.header = header
            headerTitle.stringValue = header?.title ?? ""
            headerStatus.stringValue = header?.status ?? ""
            headerTitle.isHidden = header == nil
            headerStatus.isHidden = header?.status.isEmpty ?? true
            table.setAccessibilityLabel(header.map { "Files in \($0.title)" } ?? "Command completions")
        }
        // Match the editor's face so labels read as a continuation of the
        // typed token rather than a separate UI font.
        if fontChanged { font = editorFont }
        anchorLocation = anchor ?? Self.anchorLocation(for: items, in: textView)
        if rowsChanged || headerChanged {
            contentWidth = header.map { Self.width(for: $0, contentWidth: measuredWidth()) } ?? measuredWidth()
        }
        if rowsChanged {
            let rowHeight = Self.rowHeight(for: font)
            if table.rowHeight != rowHeight { table.rowHeight = rowHeight }
            CommandInputDiagnostics.record(.completionReload)
            table.reloadData()
        }
        updatePosition(for: textView, diagnosticInputID: diagnosticInputID)
        select(index: selected)
    }

    func select(index: Int) {
        let diagnostic = CommandInputDiagnostics.begin(.completionSelection)
        defer { CommandInputDiagnostics.end(diagnostic) }
        guard items.indices.contains(index) else { return }
        CommandOverlayStyle.withoutAnimation {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            let clip = scrollView.contentView
            let origin = Self.scrollOrigin(for: table.rect(ofRow: index), viewport: clip.bounds,
                                           documentHeight: table.bounds.height)
            if clip.bounds.origin != origin {
                clip.scroll(to: origin)
                scrollView.reflectScrolledClipView(clip)
            }
        }
    }

    static func scrollOrigin(for row: NSRect, viewport: NSRect, documentHeight: CGFloat) -> NSPoint {
        var y = viewport.minY
        if row.minY < viewport.minY { y = row.minY } else if row.maxY > viewport.maxY { y = row.maxY - viewport.height }
        return NSPoint(x: viewport.minX, y: max(0, min(y, documentHeight - viewport.height)))
    }

    private static let fallbackFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    private static let detailFont = NSFont.systemFont(ofSize: 11)
    /// Bounded so very large result sets cannot stall a keystroke.
    private static let measuredItemLimit = 200
    /// Enough for a legible abbreviated folder path; it truncates at the head.
    private static let headerMinimumWidth: CGFloat = 260
    /// NSTextField label cells draw glyphs 2pt inside their frame.
    private static let labelPadding: CGFloat = 2

    /// Reserve the whole status and a short scope label, while keeping the
    /// same bounded popup width as ordinary completion results.
    static func width(for header: CommandCompletionHeader, contentWidth: CGFloat) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: detailFont]
        let statusWidth = ceil((header.status as NSString).size(withAttributes: attributes).width)
        let titleWidth = min(96, ceil((header.title as NSString).size(withAttributes: attributes).width))
        let headerWidth = statusWidth + titleWidth + CommandOverlayStyle.inset * 5
        return min(CommandOverlayStyle.maximumPopupWidth, max(headerMinimumWidth, max(contentWidth, headerWidth)))
    }

    /// Compact rows keep 3pt above/below the editor font and grow for large faces.
    static func rowHeight(for font: NSFont) -> CGFloat {
        let line = font.ascender - font.descender + font.leading
        return max(24, ceil(line + 6))
    }

    /// Fits the panel on whichever side of the caret has room, trimming the
    /// visible row count (never below one) instead of leaving the screen.
    static func panelGeometry(rows: Int, rowHeight: CGFloat, caret: NSRect,
                              available: NSRect, extra: CGFloat = 0) -> (y: CGFloat, height: CGFloat) {
        let inset = CommandOverlayStyle.inset
        let spaceBelow = caret.minY - inset - available.minY
        let spaceAbove = available.maxY - caret.maxY - inset
        let wanted = CGFloat(min(8, max(1, rows))) * rowHeight + inset * 2 + extra
        let placeBelow = wanted <= spaceBelow || spaceBelow >= spaceAbove
        let space = max(0, min(placeBelow ? spaceBelow : spaceAbove, available.height))
        let fitting = max(1, Int(floor((space - inset * 2 - extra) / rowHeight)))
        let height = min(wanted, CGFloat(fitting) * rowHeight + inset * 2 + extra)
        let y = placeBelow ? caret.minY - inset - height : caret.maxY + inset
        return (min(max(y, available.minY), available.maxY - height), height)
    }

    /// Shared start of the replaced token, so labels line up under it.
    private static func anchorLocation(for items: [CommandCompletionCandidate], in textView: NSTextView) -> Int? {
        guard let range = items.first?.replacementRange, range.location != NSNotFound else { return nil }
        let cursor = textView.selectedRange().location
        guard range.location <= cursor, cursor <= (textView.string as NSString).length,
              items.allSatisfy({ $0.replacementRange.location == range.location }) else { return nil }
        let token = (textView.string as NSString).substring(with: NSRange(location: range.location,
                                                                         length: cursor - range.location))
        return token.contains("\n") ? nil : range.location
    }

    private func measuredWidth() -> CGFloat {
        let diagnostic = CommandInputDiagnostics.begin(.completionMeasureWidth)
        defer { CommandInputDiagnostics.end(diagnostic) }
        let result = Self.measureContent(items: items, font: font, message: message)
        CommandInputDiagnostics.record(.completionWidthMeasuredRows, amount: result.rows)
        return result.width
    }

    static func measureContent(items: [CommandCompletionCandidate], font: NSFont,
                               message: String?) -> (width: CGFloat, rows: Int) {
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: font]
        let detailAttributes: [NSAttributedString.Key: Any] = [.font: Self.detailFont]
        let chrome = CommandOverlayStyle.inset * 4 + Self.labelPadding * 4
        var titleWidth: CGFloat = 0
        var detailWidth: CGFloat = 0
        var rows = 0
        if items.isEmpty {
            titleWidth = ((message ?? "No completions") as NSString).size(withAttributes: titleAttributes).width
        }
        for item in items.prefix(Self.measuredItemLimit) {
            rows += 1
            titleWidth = max(titleWidth, (item.displayText as NSString).size(withAttributes: titleAttributes).width)
            if !item.detail.isEmpty {
                detailWidth = max(detailWidth, (item.detail as NSString).size(withAttributes: detailAttributes).width)
            }
            // Both maxima and the optional gap only grow. Once the panel is
            // capped, later glyph measurements cannot change its width.
            let gap = detailWidth > 0 ? CommandOverlayStyle.inset * 3 : 0
            if ceil(titleWidth + gap + detailWidth + chrome) >= CommandOverlayStyle.maximumPopupWidth {
                return (CommandOverlayStyle.maximumPopupWidth, rows)
            }
        }
        let gap = detailWidth > 0 ? CommandOverlayStyle.inset * 3 : 0
        return (min(CommandOverlayStyle.maximumPopupWidth,
                    max(CommandOverlayStyle.minimumPopupWidth, ceil(titleWidth + gap + detailWidth + chrome))), rows)
    }

    func updatePosition(for textView: NSTextView, diagnosticInputID: UInt64? = nil) {
        let diagnostic = CommandInputDiagnostics.beginTimeline(
            .completionPosition, id: diagnosticInputID, begin: .completionPositionBegin, end: .completionPositionEnd)
        defer { CommandInputDiagnostics.end(diagnostic) }
        guard let parent = textView.window, parent.isVisible, parent.isKeyWindow,
              !textView.isHiddenOrHasHiddenAncestor,
              let root = parent.contentView, let screen = parent.screen ?? NSScreen.main else {
            dismiss()
            return
        }
        let caret = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        let length = (textView.string as NSString).length
        let tokenX = anchorLocation.flatMap { location -> CGFloat? in
            guard location <= length else { return nil }
            return textView.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil).minX
        } ?? caret.minX
        let inset = CommandOverlayStyle.inset
        // Keep the overlay in the same drawable as the terminal. Convert via
        // window/screen coordinates so flipped hosting views work identically.
        let contentOnScreen = parent.convertToScreen(root.convert(root.bounds, to: nil))
        let available = screen.visibleFrame.intersection(contentOnScreen).insetBy(dx: inset, dy: inset)
        let width = min(contentWidth, available.width)
        let headerExtra = header == nil ? 0 : CommandOverlayStyle.headerHeight
        let geometry = Self.panelGeometry(rows: numberOfRows(in: table), rowHeight: table.rowHeight,
                                          caret: caret, available: available, extra: headerExtra)
        // Panel inset plus label leading puts label glyphs under the token.
        let x = min(max(tokenX - inset * 2 - Self.labelPadding, available.minX), available.maxX - width)
        if surface.appearance?.name != textView.effectiveAppearance.name { surface.appearance = textView.effectiveAppearance }
        let screenFrame = NSRect(x: x, y: geometry.y, width: width, height: geometry.height)
        let frame = root.convert(parent.convertFromScreen(screenFrame), from: nil)
        if surface.frame != frame {
            let resized = surface.frame.size != frame.size
            CommandInputDiagnostics.record(resized ? .completionPopupResize : .completionPopupMove)
            let frameTiming = CommandInputDiagnostics.beginTimeline(
                .completionSetFrame, id: diagnosticInputID,
                begin: .completionSetFrameBegin, end: .completionSetFrameEnd)
            surface.frame = frame
            surface.needsLayout = true
            CommandInputDiagnostics.end(frameTiming)
        }
        let layoutTiming = CommandInputDiagnostics.beginTimeline(
            .completionPanelLayout, id: diagnosticInputID,
            begin: .completionPanelLayoutBegin, end: .completionPanelLayoutEnd)
        surface.layoutSubtreeIfNeeded()
        CommandInputDiagnostics.end(layoutTiming)
        let content = surface.contentView.bounds
        if header != nil {
            // Non-flipped content: the header occupies the top band.
            let band = NSRect(x: inset * 2, y: content.maxY - inset - CommandOverlayStyle.headerHeight,
                              width: content.width - inset * 4, height: CommandOverlayStyle.headerHeight)
            let statusWidth = headerStatus.isHidden ? 0 : min(band.width, ceil(headerStatus.intrinsicContentSize.width))
            let labelHeight = ceil(headerTitle.intrinsicContentSize.height)
            let y = floor(band.midY - labelHeight / 2)
            headerStatus.frame = NSRect(x: band.maxX - statusWidth, y: y, width: statusWidth, height: labelHeight)
            headerTitle.frame = NSRect(x: band.minX, y: y, width: max(0, band.width - statusWidth - (statusWidth > 0 ? inset : 0)),
                                       height: labelHeight)
        }
        scrollView.frame = NSRect(x: inset, y: inset, width: max(0, content.width - inset * 2),
                                  height: max(0, content.height - inset * 2 - headerExtra))
        let tableSize = NSSize(width: scrollView.contentSize.width, height: CGFloat(table.numberOfRows) * table.rowHeight)
        if table.frame.size != tableSize { table.setFrameSize(tableSize) }
        if table.tableColumns.first?.width != tableSize.width { table.tableColumns.first?.width = tableSize.width }
        let orderTiming = CommandInputDiagnostics.beginTimeline(
            .completionOrder, id: diagnosticInputID, begin: .completionOrderBegin, end: .completionOrderEnd)
        if surface.superview !== root { root.addSubview(surface, positioned: .above, relativeTo: nil) }
        surface.isHidden = false
        CommandInputDiagnostics.end(orderTiming)
    }

    func dismiss() {
        guard surface.superview != nil else { return }
        let timing = CommandInputDiagnostics.beginTimeline(
            .completionDismiss, id: CommandInputDiagnostics.currentInputID,
            begin: .completionDismissBegin, end: .completionDismissEnd)
        defer { CommandInputDiagnostics.end(timing) }
        surface.isHidden = true
        surface.removeFromSuperview()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { max(items.count, message == nil ? 0 : 1) }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { items.indices.contains(row) }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = CommandCompletionRow()
        view.theme = theme
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("completion-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? CommandCompletionCell
            ?? CommandCompletionCell()
        cell.identifier = identifier
        if items.indices.contains(row) {
            cell.configure(title: items[row].displayText, detail: items[row].detail, font: font)
        } else {
            cell.configure(title: message ?? "No completions", detail: "", font: font, muted: true)
        }
        cell.applyTheme(theme, selected: row == tableView.selectedRow)
        return cell
    }

    @objc private func acceptClickedRow() {
        guard items.indices.contains(table.clickedRow) else { return }
        onAccept(table.clickedRow)
    }
}

@MainActor
private final class CommandCompletionTable: NSTableView {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class CommandCompletionRow: NSTableRowView {
    var theme = CommandUITheme.fallback { didSet { needsDisplay = true } }
    // The tinted selection is light; keep label colors instead of AppKit's
    // emphasized white-on-accent text, which is unreadable in light mode.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        theme.selectionBackground.setFill()
        let radius = CommandOverlayStyle.selectionRadius
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

@MainActor
private final class CommandCompletionCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var muted = false

    func applyTheme(_ theme: CommandUITheme, selected: Bool) {
        let foreground = selected ? theme.selectionForeground : theme.foreground
        title.textColor = muted ? theme.secondary : foreground
        detail.textColor = foreground.withAlphaComponent(0.65)
    }

    init() {
        super.init(frame: .zero)
        title.textColor = CommandUITheme.fallback.foreground
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = CommandUITheme.fallback.secondary
        detail.lineBreakMode = .byTruncatingHead
        textField = title
        addSubview(title)
        addSubview(detail)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, detail: String, font: NSFont, muted: Bool = false) {
        self.muted = muted
        CommandInputDiagnostics.record(.completionRowsConfigured)
        if self.title.font != font { self.title.font = font }
        self.title.textColor = muted ? CommandUITheme.fallback.secondary : CommandUITheme.fallback.foreground
        self.title.stringValue = title.replacingOccurrences(of: "\n", with: "↵")
        self.detail.stringValue = detail.replacingOccurrences(of: "\n", with: " ")
        toolTip = detail.isEmpty ? nil : title + "\n" + detail
        setAccessibilityHelp(detail.isEmpty ? nil : detail)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad = CommandOverlayStyle.inset
        let gap = detail.stringValue.isEmpty ? 0 : pad * 3
        // A truncating NSTextField's intrinsic width can reflect its previous
        // constrained frame. Measure the token independently and allow its
        // native text-cell margins before assigning space to the description.
        let tokenWidth = ceil((title.stringValue as NSString).size(withAttributes: [
            .font: title.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        ]).width) + 4
        let titleWidth = min(tokenWidth, bounds.width * 0.55)
        let detailWidth = detail.stringValue.isEmpty ? 0 : min(detail.intrinsicContentSize.width,
            max(0, bounds.width - titleWidth - gap - pad * 2))
        let titleHeight = ceil(title.intrinsicContentSize.height)
        let detailHeight = ceil(detail.intrinsicContentSize.height)
        title.frame = NSRect(x: pad, y: floor((bounds.height - titleHeight) / 2),
                             width: max(0, bounds.width - detailWidth - gap - pad * 2), height: titleHeight)
        detail.frame = NSRect(x: bounds.width - detailWidth - pad, y: floor((bounds.height - detailHeight) / 2),
                              width: detailWidth, height: detailHeight)
    }
}
