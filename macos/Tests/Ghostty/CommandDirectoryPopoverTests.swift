import AppKit
import Testing
@testable import Ghostty

struct CommandDirectoryPopoverTests {
    @MainActor @Test func popoverOpensTowardThePaneCenterForInlineAndDockedHeaders() {
        let pane = NSRect(x: 0, y: 100, width: 800, height: 600)
        let inline = NSRect(x: 20, y: 120, width: 200, height: 20)
        let docked = NSRect(x: 20, y: 660, width: 200, height: 20)
        #expect(CommandDirectoryPopover.preferredEdge(for: inline, within: pane) == .maxY)
        #expect(CommandDirectoryPopover.preferredEdge(for: docked, within: pane) == .minY)
    }

    @Test func readerListsOneLevelWithFoldersFirstAndDoesNotFollowSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("file.txt"))
        try Data().write(to: root.appendingPathComponent(".hidden"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)

        let listing = try await CommandDirectoryReader().children(of: root)
        let entries = listing.entries

        #expect(entries.first?.name == "Folder")
        #expect(Set(entries.map(\.name)) == ["Folder", "file.txt", ".hidden", "loop"])
        #expect(entries.first(where: { $0.name == "loop" })?.isSymbolicLink == true)
        #expect(!listing.truncated)
        await #expect(throws: (any Error).self) {
            try await CommandDirectoryReader().children(of: root.appendingPathComponent("missing"))
        }
    }

    @Test func readerBoundsEachDirectoryWithoutRecursingIntoItsChildren() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0...CommandDirectoryReader.maximumEntries {
            try Data().write(to: root.appendingPathComponent("item-\(index)"))
        }
        let listing = try await CommandDirectoryReader().children(of: root)
        #expect(listing.entries.count == CommandDirectoryReader.maximumEntries)
        #expect(listing.truncated)
    }

    @MainActor @Test func switchingDirectoriesRejectsThePreviousLoad() async throws {
        let reader = ControlledDirectoryReader()
        let popover = CommandDirectoryPopover(reader: reader)
        defer { popover.dismiss() }
        let old = URL(fileURLWithPath: "/old-folder")
        let current = URL(fileURLWithPath: "/current-folder")
        popover.prepare(directory: old)
        await reader.waitForRequest(old)
        popover.prepare(directory: current)
        await reader.waitForRequest(current)

        await reader.resolve(old, entries: [entry("stale", under: old)])
        await drainMainQueue()
        #expect(rootTitles(popover) == ["Loading…"])
        await reader.resolve(current, entries: [entry("current.txt", under: current)])
        await drainMainQueue()
        #expect(popover.directory == current)
        #expect(rootTitles(popover) == ["current.txt"])
    }

    @MainActor @Test func collapsingALoadingFolderCancelsItsResultAndCanRetry() async throws {
        let reader = ControlledDirectoryReader()
        let popover = CommandDirectoryPopover(reader: reader)
        defer { popover.dismiss() }
        let root = URL(fileURLWithPath: "/root")
        let folder = entry("folder", under: root, directory: true)
        popover.prepare(directory: root)
        await reader.waitForRequest(root)
        await reader.resolve(root, entries: [folder])
        await drainMainQueue()
        let node = try #require(popover.outlineView.item(atRow: 0) as? CommandDirectoryNode)
        #expect(popover.outlineView(popover.outlineView, shouldExpandItem: node))
        await reader.waitForRequest(folder.url)
        #expect(popover.outlineView(popover.outlineView, shouldCollapseItem: node))
        await reader.resolve(folder.url, entries: [entry("stale", under: folder.url)])
        await drainMainQueue()
        #expect(!node.loaded)
        #expect(!node.loading)

        #expect(popover.outlineView(popover.outlineView, shouldExpandItem: node))
        await reader.waitForRequest(folder.url, count: 2)
        await reader.resolve(folder.url, entries: [entry("fresh.txt", under: folder.url)])
        await drainMainQueue()
        #expect(node.children.map(\.title) == ["fresh.txt"])
    }

    @MainActor @Test func unreadableFolderShowsAPlainErrorAndCopyUsesTheRootPath() async throws {
        let reader = ControlledDirectoryReader()
        let popover = CommandDirectoryPopover(reader: reader)
        defer { popover.dismiss() }
        let root = URL(fileURLWithPath: "/folder with spaces")
        popover.prepare(directory: root)
        await reader.waitForRequest(root)
        await reader.fail(root, error: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError))
        await drainMainQueue()
        #expect(rootTitles(popover) == ["Permission denied"])

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        popover.copyPath(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == root.path)
    }

    @MainActor @Test func dismissingRejectsPendingResultsWithoutOpeningAWindow() async throws {
        let reader = ControlledDirectoryReader()
        let popover = CommandDirectoryPopover(reader: reader)
        let root = URL(fileURLWithPath: "/root")
        popover.prepare(directory: root)
        await reader.waitForRequest(root)
        popover.dismiss()
        await reader.resolve(root, entries: [entry("late.txt", under: root)])
        await drainMainQueue()
        #expect(rootTitles(popover) == ["Loading…"])
    }

    @MainActor @Test func filenamesHaveVisibleWidthInitiallyAfterExpansionAndAfterResize() async throws {
        let reader = ControlledDirectoryReader()
        let popover = CommandDirectoryPopover(reader: reader)
        defer { popover.dismiss() }
        let root = URL(fileURLWithPath: "/root")
        let folder = entry("folder", under: root, directory: true)
        popover.prepare(directory: root)
        await reader.waitForRequest(root)
        await reader.resolve(root, entries: [folder, entry("visible-root-file.txt", under: root)])
        await drainMainQueue()

        let scrollView = try #require(popover.outlineView.enclosingScrollView)
        let content = try #require(scrollView.superview)
        content.layoutSubtreeIfNeeded()
        #expect(popover.outlineView.frame.width == scrollView.contentView.bounds.width)
        #expect(popover.outlineView.tableColumns.first?.width == popover.outlineView.frame.width)
        try expectVisibleFilename("visible-root-file.txt", row: 1, in: popover.outlineView)

        let node = try #require(popover.outlineView.item(atRow: 0) as? CommandDirectoryNode)
        #expect(popover.outlineView(popover.outlineView, shouldExpandItem: node))
        popover.outlineView.expandItem(node)
        await reader.waitForRequest(folder.url)
        await reader.resolve(folder.url, entries: [entry("visible-nested-file.txt", under: folder.url)])
        await drainMainQueue()
        try expectVisibleFilename("visible-nested-file.txt", row: 1, in: popover.outlineView)

        content.setFrameSize(NSSize(width: 260, height: 300))
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        #expect(popover.outlineView.frame.width == scrollView.contentView.bounds.width)
        try expectVisibleFilename("visible-nested-file.txt", row: 1, in: popover.outlineView)
    }

    @MainActor @Test func escapeInTheTreeDismissesAndCancelsItsPendingLoad() async throws {
        let reader = ControlledDirectoryReader()
        let popover = CommandDirectoryPopover(reader: reader)
        let root = URL(fileURLWithPath: "/root")
        popover.prepare(directory: root)
        await reader.waitForRequest(root)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        popover.outlineView.keyDown(with: event)
        await reader.resolve(root, entries: [entry("late.txt", under: root)])
        await drainMainQueue()
        #expect(rootTitles(popover) == ["Loading…"])
    }

    @MainActor private func expectVisibleFilename(_ title: String, row: Int, in outlineView: NSOutlineView) throws {
        outlineView.layoutSubtreeIfNeeded()
        let cell = try #require(outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
        cell.layoutSubtreeIfNeeded()
        let label = try #require(cell.textField)
        #expect(label.stringValue == title)
        #expect(cell.bounds.width > 140)
        #expect(label.frame.width > 100)
        #expect(label.frame.height > 0)
        #expect(cell.bounds.intersection(label.frame).width > 100)
    }

    private func entry(_ name: String, under directory: URL, directory isDirectory: Bool = false) -> CommandDirectoryEntry {
        .init(url: directory.appendingPathComponent(name), name: name,
              isDirectory: isDirectory, isSymbolicLink: false)
    }

    @MainActor private func rootTitles(_ popover: CommandDirectoryPopover) -> [String] {
        (0..<popover.outlineView.numberOfRows).compactMap {
            (popover.outlineView.item(atRow: $0) as? CommandDirectoryNode)?.title
        }
    }

    @MainActor private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

private actor ControlledDirectoryReader: CommandDirectoryReading {
    private var pending: [URL: [CheckedContinuation<CommandDirectoryListing, any Error>]] = [:]
    private var counts: [URL: Int] = [:]
    private var waiters: [(URL, Int, CheckedContinuation<Void, Never>)] = []

    func children(of directory: URL) async throws -> CommandDirectoryListing {
        try await withCheckedThrowingContinuation { continuation in
            pending[directory, default: []].append(continuation)
            counts[directory, default: 0] += 1
            let ready = waiters.filter { counts[$0.0, default: 0] >= $0.1 }
            waiters.removeAll { counts[$0.0, default: 0] >= $0.1 }
            for waiter in ready { waiter.2.resume() }
        }
    }

    func waitForRequest(_ directory: URL, count: Int = 1) async {
        if counts[directory, default: 0] >= count { return }
        await withCheckedContinuation { waiters.append((directory, count, $0)) }
    }

    func resolve(_ directory: URL, entries: [CommandDirectoryEntry]) {
        pending[directory]?.removeFirst().resume(returning: .init(entries: entries))
    }

    func fail(_ directory: URL, error: any Error) {
        pending[directory]?.removeFirst().resume(throwing: error)
    }
}
