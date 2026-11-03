import AppKit

struct CommandCompletionRequest: Sendable {
    let id: UUID
    let revision: UInt64
    let text: String
    let cursorUTF16: Int
}

struct CommandCompletionCandidate: Sendable {
    let displayText: String
    let detail: String
    let replacementText: String
    let replacementRange: NSRange
    var cursorUTF16: Int?
}

struct CommandCompletionResponse: Sendable {
    let requestID: UUID
    let revision: UInt64
    let items: [CommandCompletionCandidate]
    var message: String?
}

/// A child panel keeps the native text view as first responder. Shell results
/// remain ordinary text; neither candidate labels nor descriptions are markup.
@MainActor
final class CommandCompletionView: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: CommandCompletionPanel
    private let table = CommandCompletionTable()
    private let scrollView = NSScrollView()
    private let background = CommandCompletionBackground(frame: .zero)
    private var items: [CommandCompletionCandidate] = []
    private var message: String?
    var onAccept: (Int) -> Void = { _ in }

    override init() {
        panel = CommandCompletionPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        super.init()
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.animationBehavior = .none

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = CommandOverlayStyle.rowHeight
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
        background.addSubview(scrollView)
        panel.contentView = background
    }

    func show(items: [CommandCompletionCandidate], message: String?, selected: Int, for textView: NSTextView) {
        self.items = items
        self.message = message
        table.reloadData()
        updatePosition(for: textView)
        select(index: selected)
    }

    func select(index: Int) {
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

    func updatePosition(for textView: NSTextView) {
        guard let parent = textView.window, parent.isVisible, parent.isKeyWindow,
              !textView.isHiddenOrHasHiddenAncestor,
              let screen = parent.screen ?? NSScreen.main else {
            dismiss()
            return
        }
        let anchor = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        let available = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let width = min(420, available.width)
        let height = CGFloat(min(8, max(1, items.count))) * table.rowHeight + CommandOverlayStyle.inset * 2
        let x = min(max(anchor.minX, available.minX), available.maxX - width)
        let below = anchor.minY - height - 3
        let y = below >= available.minY ? below : min(anchor.maxY + 3, available.maxY - height)
        if panel.appearance?.name != textView.effectiveAppearance.name { panel.appearance = textView.effectiveAppearance }
        let frame = NSRect(x: x, y: y, width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true, animate: false) }
        scrollView.frame = background.bounds.insetBy(dx: CommandOverlayStyle.inset, dy: CommandOverlayStyle.inset)
        let tableSize = NSSize(width: scrollView.contentSize.width, height: CGFloat(table.numberOfRows) * table.rowHeight)
        if table.frame.size != tableSize { table.setFrameSize(tableSize) }
        if table.tableColumns.first?.width != tableSize.width { table.tableColumns.first?.width = tableSize.width }
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        if !panel.isVisible { panel.orderFront(nil) }
    }

    func dismiss() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { max(items.count, message == nil ? 0 : 1) }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { items.indices.contains(row) }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CommandCompletionRow()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("completion-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? CommandCompletionCell
            ?? CommandCompletionCell()
        cell.identifier = identifier
        if items.indices.contains(row) {
            cell.configure(title: items[row].displayText, detail: items[row].detail)
        } else {
            cell.configure(title: message ?? "No completions", detail: "")
        }
        return cell
    }

    @objc private func acceptClickedRow() {
        guard items.indices.contains(table.clickedRow) else { return }
        onAccept(table.clickedRow)
    }
}

@MainActor
private final class CommandCompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class CommandCompletionTable: NSTableView {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class CommandCompletionBackground: NSView {
    override var wantsUpdateLayer: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateLayer() { CommandOverlayStyle.apply(to: self) }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class CommandCompletionRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        CommandOverlayStyle.selectionBackground.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

@MainActor
private final class CommandCompletionCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        title.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        title.textColor = CommandOverlayStyle.primaryText
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = CommandOverlayStyle.secondaryText
        detail.lineBreakMode = .byTruncatingTail
        textField = title
        addSubview(title)
        addSubview(detail)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, detail: String) {
        self.title.stringValue = title.replacingOccurrences(of: "\n", with: "↵")
        self.detail.stringValue = detail.replacingOccurrences(of: "\n", with: " ")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let detailWidth = detail.stringValue.isEmpty ? 0 : bounds.width * 0.42
        title.frame = NSRect(x: 8, y: (bounds.height - 18) / 2, width: max(0, bounds.width - detailWidth - 16), height: 18)
        detail.frame = NSRect(x: bounds.width - detailWidth, y: (bounds.height - 16) / 2,
                              width: max(0, detailWidth - 8), height: 16)
    }
}
