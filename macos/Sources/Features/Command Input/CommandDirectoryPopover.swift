import AppKit

struct CommandDirectoryEntry: Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
}

protocol CommandDirectoryReading: Sendable {
    func children(of directory: URL) async throws -> CommandDirectoryListing
}

struct CommandDirectoryListing: Sendable {
    let entries: [CommandDirectoryEntry]
    var truncated = false
}

/// Filesystem traversal runs on its own actor; views never enumerate directories.
actor CommandDirectoryReader: CommandDirectoryReading {
    static let maximumEntries = 1_000

    func children(of directory: URL) async throws -> CommandDirectoryListing {
        try enumerate(directory)
    }

    private func enumerate(_ directory: URL) throws -> CommandDirectoryListing {
        try Task.checkCancellation()
        let attributes = try directory.resourceValues(forKeys: [.isDirectoryKey])
        guard attributes.isDirectory == true else { throw CocoaError(.fileReadUnsupportedScheme) }
        var enumerationError: (any Error)?
        guard let urls = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants], errorHandler: { _, error in
                enumerationError = error
                return false
            }) else { throw CocoaError(.fileReadUnknown) }
        var entries: [CommandDirectoryEntry] = []
        entries.reserveCapacity(Self.maximumEntries)
        var truncated = false
        for case let url as URL in urls {
            try Task.checkCancellation()
            if entries.count == Self.maximumEntries { truncated = true; break }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            entries.append(.init(url: url, name: url.lastPathComponent,
                                 isDirectory: values?.isDirectory == true,
                                 isSymbolicLink: values?.isSymbolicLink == true))
        }
        if let enumerationError { throw enumerationError }
        entries.sort { lhs, rhs in
            let leftFolder = lhs.isDirectory && !lhs.isSymbolicLink
            let rightFolder = rhs.isDirectory && !rhs.isSymbolicLink
            if leftFolder != rightFolder { return leftFolder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return .init(entries: entries, truncated: truncated)
    }
}

@MainActor
final class CommandDirectoryNode: NSObject {
    let id = UUID()
    let entry: CommandDirectoryEntry?
    let title: String
    var children: [CommandDirectoryNode]
    var loaded = false
    var loading = false
    var canExpand: Bool { entry?.isDirectory == true && entry?.isSymbolicLink != true }

    init(entry: CommandDirectoryEntry) {
        self.entry = entry
        title = entry.name
        children = entry.isDirectory && !entry.isSymbolicLink ? [CommandDirectoryNode(message: "Loading…")] : []
    }

    init(message: String) {
        entry = nil
        title = message
        children = []
        loaded = true
    }
}

/// A read-only, lazy file tree. The terminal keeps ownership of all commands.
@MainActor
final class CommandDirectoryPopover: NSObject, NSPopoverDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let popover = NSPopover()
    private let content = CommandDirectoryContentView(frame: NSRect(x: 0, y: 0, width: 380, height: 360))
    private let reader: any CommandDirectoryReading
    private var root: CommandDirectoryNode?
    private var generation: UInt64 = 0
    private var loads: [UUID: Task<Void, Never>] = [:]
    private(set) var directory: URL?
    var outlineView: NSOutlineView { content.outlineView }
    var isShown: Bool { popover.isShown }

    init(reader: any CommandDirectoryReading = CommandDirectoryReader()) {
        self.reader = reader
        super.init()
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.contentSize = content.frame.size
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        outlineView.dataSource = self
        outlineView.delegate = self
        content.copyButton.target = self
        content.copyButton.action = #selector(copyPathClicked(_:))
        content.onCancel = { [weak self] in self?.dismiss() }
    }

    func show(directory: URL, anchorRect: NSRect, in view: NSView) {
        guard directory.isFileURL, view.window?.isVisible == true, !view.isHiddenOrHasHiddenAncestor else { return }
        if popover.isShown { popover.close() }
        prepare(directory: directory)
        popover.appearance = view.effectiveAppearance
        popover.show(relativeTo: anchorRect, of: view, preferredEdge: Self.preferredEdge(for: anchorRect, within: view.bounds))
    }

    static func preferredEdge(for anchor: NSRect, within bounds: NSRect) -> NSRectEdge {
        // Open toward the pane's center. In the flipped terminal host, .minY
        // places a docked footer's tree above the input instead of below it.
        anchor.midY >= bounds.midY ? .minY : .maxY
    }

    func dismiss() {
        popover.close()
        cancelLoads()
    }

    func popoverDidClose(_ notification: Notification) { cancelLoads() }

    /// Preparing state separately also lets a newly opened tree immediately
    /// display its loading row without waiting for the filesystem.
    func prepare(directory: URL) {
        cancelLoads()
        self.directory = directory.standardizedFileURL
        content.pathLabel.stringValue = directory.path
        content.pathLabel.toolTip = directory.path
        content.copyButton.isEnabled = directory.isFileURL
        let root = CommandDirectoryNode(entry: .init(url: directory, name: directory.lastPathComponent,
                                                     isDirectory: true, isSymbolicLink: false))
        self.root = root
        outlineView.reloadData()
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        load(root)
    }

    func copyPath(to pasteboard: NSPasteboard = .general) {
        guard let directory, directory.isFileURL else { return }
        pasteboard.clearContents()
        pasteboard.setString(directory.path, forType: .string)
    }

    @objc private func copyPathClicked(_ sender: Any?) { copyPath() }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? CommandDirectoryNode) ?? root)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? CommandDirectoryNode) ?? root)!.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? CommandDirectoryNode)?.canExpand == true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? CommandDirectoryNode, node.canExpand else { return false }
        load(node)
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        if let node = item as? CommandDirectoryNode { cancelBranch(node) }
        return true
    }

    func outlineViewItemDidExpand(_ notification: Notification) { content.synchronizeOutlineSize() }
    func outlineViewItemDidCollapse(_ notification: Notification) { content.synchronizeOutlineSize() }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? CommandDirectoryNode)?.entry != nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? CommandDirectoryNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("command-directory-entry")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? CommandDirectoryCell
            ?? CommandDirectoryCell(frame: .zero)
        cell.identifier = identifier
        cell.configure(node)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        CommandDirectoryRow()
    }

    private func load(_ node: CommandDirectoryNode) {
        guard node.canExpand, !node.loaded, !node.loading, let url = node.entry?.url else { return }
        node.loading = true
        let generation = generation
        loads[node.id] = Task { [weak self, weak node, reader] in
            let children: [CommandDirectoryNode]
            do {
                let listing = try await reader.children(of: url)
                try Task.checkCancellation()
                var nodes = listing.entries.map(CommandDirectoryNode.init(entry:))
                if listing.truncated {
                    nodes.append(CommandDirectoryNode(message: "Showing first \(listing.entries.count.formatted()) items"))
                }
                children = nodes.isEmpty ? [CommandDirectoryNode(message: "Empty folder")] : nodes
            } catch is CancellationError {
                return
            } catch {
                children = [CommandDirectoryNode(message: Self.errorMessage(error))]
            }
            guard let self, let node, !Task.isCancelled, self.generation == generation, node.loading else { return }
            self.loads[node.id] = nil
            node.loading = false
            node.loaded = true
            node.children = children
            self.outlineView.reloadItem(node === self.root ? nil : node, reloadChildren: true)
            self.content.synchronizeOutlineSize()
        }
    }

    private func cancelLoads() {
        generation &+= 1
        for task in loads.values { task.cancel() }
        loads.removeAll()
    }

    private func cancelBranch(_ node: CommandDirectoryNode) {
        loads.removeValue(forKey: node.id)?.cancel()
        node.loading = false
        for child in node.children { cancelBranch(child) }
    }

    private static func errorMessage(_ error: Error) -> String {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            if error.code == NSFileReadNoPermissionError { return "Permission denied" }
            if error.code == NSFileReadNoSuchFileError { return "Folder no longer exists" }
        }
        return "Unable to read folder"
    }
}

@MainActor
private final class CommandDirectoryContentView: NSView {
    let pathLabel = NSTextField(labelWithString: "")
    let copyButton = NSButton(title: "Copy Path", target: nil, action: nil)
    let outlineView = CommandDirectoryOutlineView()
    var onCancel: () -> Void = {}
    private let scrollView = NSScrollView()
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        pathLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        pathLabel.textColor = CommandOverlayStyle.primaryText
        pathLabel.lineBreakMode = .byTruncatingMiddle
        copyButton.bezelStyle = .inline
        copyButton.controlSize = .small
        copyButton.setAccessibilityLabel("Copy folder path")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = CommandOverlayStyle.rowHeight
        outlineView.indentationPerLevel = 14
        outlineView.intercellSpacing = .zero
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outlineView.autoresizingMask = [.width]
        outlineView.style = .plain
        outlineView.backgroundColor = .clear
        outlineView.focusRingType = .none
        outlineView.setAccessibilityLabel("Folder contents")
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        outlineView.onCancel = { [weak self] in self?.onCancel() }
        addSubview(pathLabel)
        addSubview(copyButton)
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        pathLabel.frame = NSRect(x: 12, y: 13, width: max(0, bounds.width - 104), height: 20)
        copyButton.frame = NSRect(x: bounds.width - 88, y: 10, width: 76, height: 24)
        scrollView.frame = NSRect(x: CommandOverlayStyle.inset, y: 44,
                                 width: bounds.width - CommandOverlayStyle.inset * 2,
                                 height: max(0, bounds.height - 44 - CommandOverlayStyle.inset))
        synchronizeOutlineSize()
    }

    func synchronizeOutlineSize() {
        // NSScrollView does not establish a document's width for us. A zero
        // width document can shrink its auto-sized column to just disclosure
        // controls, even though every accessible row still has a filename.
        scrollView.tile()
        let viewport = scrollView.contentView.bounds.size
        guard viewport.width > 0 else { return }
        let size = NSSize(width: viewport.width,
                          height: max(viewport.height, CGFloat(outlineView.numberOfRows) * outlineView.rowHeight))
        if outlineView.frame.size != size { outlineView.setFrameSize(size) }
        if outlineView.tableColumns.first?.width != size.width { outlineView.tableColumns.first?.width = size.width }
        outlineView.needsLayout = true
    }

    override func cancelOperation(_ sender: Any?) { onCancel() }

    override func updateLayer() { CommandOverlayStyle.apply(to: self) }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class CommandDirectoryOutlineView: NSOutlineView {
    var onCancel: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onCancel() }
}

@MainActor
private final class CommandDirectoryCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 12.5)
        label.lineBreakMode = .byTruncatingMiddle
        textField = label
        imageView = icon
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ node: CommandDirectoryNode) {
        label.stringValue = node.title
        label.textColor = node.entry == nil ? CommandOverlayStyle.secondaryText : CommandOverlayStyle.primaryText
        let symbol = node.entry?.isSymbolicLink == true ? "link" : node.canExpand ? "folder" : "doc"
        icon.image = node.entry == nil ? nil : NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = node.canExpand ? .controlAccentColor : CommandOverlayStyle.secondaryText
        toolTip = node.entry?.url.path
        needsLayout = true
    }
}

@MainActor
private final class CommandDirectoryRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        CommandOverlayStyle.selectionBackground.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}
