import AppKit
import Testing
@testable import Ghostty

@MainActor
struct CommandFilePickerTests {
    // MARK: Pure rules

    @Test func triggerRequiresATypedArgumentBoundary() {
        func at(_ text: String) -> Bool {
            CommandFilePicking.triggers(in: text, at: (text as NSString).length - 1)
        }
        #expect(at("@"))
        #expect(at("cat @"))
        #expect(at("cp a\n@"))
        #expect(at("tool --file=@"))
        #expect(at("sort <@"))
        #expect(at("echo hi >@"))
        #expect(at("cat <<EOF x @"))
        #expect(at("echo 'done' @"))
        #expect(!at("mail me@"))
        #expect(!at("echo $@"))
        #expect(!at("echo ${a[@"))
        #expect(!at("ls *(@"))
        #expect(!at("echo \\@"))
        #expect(!at("echo '@"))
        #expect(!at("echo 'a @"))
        #expect(!at("echo \"a @"))
        #expect(!at("echo $'a @"))
        #expect(!at("echo a # see @"))
        #expect(!at("cat <<EOF\nbody @"))
        #expect(!at("cat <<@"))
        // An escaped boundary keeps the `@` inside the preceding word.
        #expect(!at("echo foo\\ @"))
        #expect(!at("echo foo\\=@"))
        #expect(!at("echo foo\\\n@"))
        #expect(at("echo foo\\\\ @"))
    }

    @Test func activeRangeCoversOnlyTheQueryRun() {
        let text = "cp @src/ma dest"
        #expect(CommandFilePicking.activeRange(in: text, anchor: 3, cursor: 10) == NSRange(location: 3, length: 7))
        #expect(CommandFilePicking.activeRange(in: text, anchor: 3, cursor: 4) == NSRange(location: 3, length: 7))
        #expect(CommandFilePicking.activeRange(in: text, anchor: 3, cursor: 3) == nil)
        #expect(CommandFilePicking.activeRange(in: text, anchor: 3, cursor: 12) == nil)
        #expect(CommandFilePicking.activeRange(in: "cp xsrc", anchor: 3, cursor: 5) == nil)
    }

    @Test func activeRangeStopsAtShellDelimiters() {
        for suffix in [";printf kept", "|wc", ">out", "<in", "&", ")", "`x`", "'q'", "\"q\"", "$(x)", "\\ y"] {
            let text = "cat @x" + suffix
            #expect(CommandFilePicking.activeRange(in: text, anchor: 4, cursor: 6) == NSRange(location: 4, length: 2))
            // Typing the delimiter itself moves the caret past the query and ends it.
            #expect(CommandFilePicking.activeRange(in: text, anchor: 4, cursor: 7) == nil)
        }
    }

    @Test func acceptancePreservesFollowingShellSyntax() async throws {
        let picker = CommandFilePicker(provider: provider(search: { _ in [entry("/w/x;y z.txt")] }), debounce: .zero)
        picker.begin(anchor: 4, cwd: "/w")
        let text = "cat @x;printf kept"
        #expect(picker.refresh(text: text, cursor: 6))
        await settle(picker)
        let result = try #require(picker.acceptance(at: 0, text: text, cursor: 6))
        #expect(result.range == NSRange(location: 4, length: 2))
        let edited = (text as NSString).replacingCharacters(in: result.range, with: result.text)
        #expect(edited == "cat 'x;y z.txt' ;printf kept")
        #expect(!picker.refresh(text: "cat @x;", cursor: 7))
    }

    @Test func indexingRetriesTheSameQueryWithoutAnotherKeystroke() async {
        let calls = CallCounter()
        let picker = CommandFilePicker(provider: CommandFileSearchProvider(
            search: { query, _, _, _ in
                if calls.next() <= 2 { throw CommandFileSearchService.Failure.indexing("Indexing files") }
                return [entry("/w/\(query).txt")]
            },
            children: { _, _ in [] }), debounce: .zero, retryInitial: .milliseconds(1), retryMaximum: .milliseconds(2))
        picker.begin(anchor: 0, cwd: "/w")
        picker.refresh(text: "@ma", cursor: 3)
        for _ in 0..<500 where picker.header?.status != CommandFilePicker.initialIndexMessage && !picker.resultsAreCurrent {
            try? await Task.sleep(for: .milliseconds(1))
        }
        if !picker.resultsAreCurrent {
            #expect(picker.header?.status == CommandFilePicker.initialIndexMessage)
            #expect(picker.selectedEntry == nil)
            #expect(picker.acceptance(at: 0, text: "@ma", cursor: 3) == nil)
        }
        await settle(picker)
        #expect(calls.count == 3)
        #expect(picker.entries.map(\.name) == ["ma.txt"])
        #expect(picker.header?.status == "")
        #expect(picker.acceptance(at: 0, text: "@ma", cursor: 3)?.text == "ma.txt ")
    }

    @Test func dismissingCancelsIndexingRetries() async {
        let calls = CallCounter()
        let picker = CommandFilePicker(provider: CommandFileSearchProvider(
            search: { _, _, _, _ in
                _ = calls.next()
                throw CommandFileSearchService.Failure.indexing("Indexing files")
            },
            children: { _, _ in [] }), debounce: .zero, retryInitial: .milliseconds(1), retryMaximum: .milliseconds(1))
        picker.begin(anchor: 0, cwd: "/w")
        picker.refresh(text: "@ma", cursor: 3)
        for _ in 0..<500 where calls.count < 2 { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(picker.header?.status == CommandFilePicker.initialIndexMessage)
        #expect(picker.message == CommandFilePicker.initialIndexMessage)
        picker.end()
        let stopped = calls.count
        try? await Task.sleep(for: .milliseconds(30))
        #expect(calls.count == stopped)
        #expect(!picker.isActive)
    }

    @Test func otherSearchErrorsStillShowTheirMessage() async {
        let picker = CommandFilePicker(provider: CommandFileSearchProvider(
            search: { _, _, _, _ in throw CommandFileSearchService.Failure.unavailable("Search helper missing") },
            children: { _, _ in [] }), debounce: .zero)
        picker.begin(anchor: 0, cwd: "/w")
        picker.refresh(text: "@ma", cursor: 3)
        await settle(picker)
        #expect(picker.message == "Search helper missing")
        #expect(picker.entries.isEmpty)
    }

    @Test func emptyPickerShowsInitialIndexBeforeChildrenAndClearsWithoutTyping() async {
        let children = PickerResponseGate<[CommandFileSearchEntry]>()
        let status = PickerIndexState()
        let picker = CommandFilePicker(provider: CommandFileSearchProvider(
            search: { _, _, _, _ in [] }, children: { _, _ in await children.wait() },
            indexState: { await status.read() }), indexPollInterval: .milliseconds(1))
        defer { picker.end() }
        picker.begin(anchor: 0, cwd: "/w")
        picker.refresh(text: "@", cursor: 1)
        for _ in 0..<500 where picker.header?.status != CommandFilePicker.initialIndexMessage {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(picker.header?.status == "Initial search index is being created…")
        #expect(picker.message == "Initial search index is being created…")
        #expect(!picker.resultsAreCurrent)

        await children.release([entry("/w/local.txt")])
        await settle(picker)
        #expect(picker.selectedEntry?.name == "local.txt")
        #expect(picker.acceptance(at: 0, text: "@", cursor: 1)?.text == "local.txt ")
        #expect(picker.header?.status == CommandFilePicker.initialIndexMessage)
        let generation = picker.generation
        await status.set(.ready)
        for _ in 0..<500 where picker.header?.status != "" {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(picker.header?.status == "")
        #expect(picker.message == nil)
        #expect(picker.generation == generation)
        #expect(picker.selectedEntry?.name == "local.txt")
    }

    @Test func cachedChildrenCannotEraseIndexStatusOrStartAnotherObserver() async {
        let reads = CallCounter()
        let listings = CallCounter()
        let picker = CommandFilePicker(provider: CommandFileSearchProvider(
            search: { _, _, _, _ in [] },
            children: { _, _ in _ = listings.next(); return [entry("/w/local.txt")] },
            indexState: { _ = reads.next(); return .creating }), indexPollInterval: .seconds(60))
        defer { picker.end() }
        picker.begin(anchor: 0, cwd: "/w")
        picker.refresh(text: "@", cursor: 1)
        await settle(picker)
        for _ in 0..<500 where picker.header?.status != CommandFilePicker.initialIndexMessage {
            try? await Task.sleep(for: .milliseconds(1))
        }
        picker.refresh(text: "@", cursor: 1)
        #expect(picker.resultsAreCurrent)
        #expect(picker.header?.status == CommandFilePicker.initialIndexMessage)
        #expect(picker.selectedEntry?.name == "local.txt")
        #expect(listings.count == 1)
        #expect(reads.count == 1)
    }

    @Test func oldIndexStatusCannotChangeAReopenedPicker() async {
        let first = PickerResponseGate<CommandFileSearchIndexState>()
        let reads = CallCounter()
        let picker = CommandFilePicker(provider: CommandFileSearchProvider(
            search: { query, _, _, _ in [entry("/w/\(query).txt")] }, children: { _, _ in [] },
            indexState: { if reads.next() == 1 { return await first.wait() }; return .ready }), debounce: .zero)
        defer { picker.end() }
        picker.begin(anchor: 0, cwd: "/w")
        picker.refresh(text: "@old", cursor: 4)
        for _ in 0..<500 where reads.count == 0 { try? await Task.sleep(for: .milliseconds(1)) }
        picker.end()
        picker.begin(anchor: 0, cwd: "/w")
        picker.refresh(text: "@new", cursor: 4)
        await settle(picker)
        for _ in 0..<500 where reads.count < 2 { try? await Task.sleep(for: .milliseconds(1)) }
        await first.release(.creating)
        for _ in 0..<5 { await Task.yield() }
        #expect(picker.header?.status == "")
        #expect(picker.entries.map(\.name) == ["new.txt"])
        #expect(picker.acceptance(at: 0, text: "@new", cursor: 4)?.text == "new.txt ")
    }

    @Test func indexStatusFailureDoesNotClaimTheIndexIsBeingCreated() async {
        let picker = CommandFilePicker(provider: CommandFileSearchProvider(
            search: { _, _, _, _ in [] }, children: { _, _ in [] },
            indexState: { throw CommandFileSearchService.Failure.unavailable("Filename helper is unavailable") }))
        defer { picker.end() }
        picker.begin(anchor: 0, cwd: "/w")
        picker.refresh(text: "@", cursor: 1)
        await settle(picker)
        for _ in 0..<500 where picker.message != "Filename helper is unavailable" {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(picker.header?.status == "Filename helper is unavailable")
        #expect(picker.message == "Filename helper is unavailable")
    }

    @Test func directoryFailureIsNotMaskedByIndexCreation() async {
        let picker = CommandFilePicker(provider: CommandFileSearchProvider(
            search: { _, _, _, _ in [] },
            children: { _, _ in throw CommandFileSearchService.Failure.unavailable("Folder cannot be read") },
            indexState: { .creating }))
        defer { picker.end() }
        picker.begin(anchor: 0, cwd: "/w")
        picker.refresh(text: "@", cursor: 1)
        await settle(picker)
        #expect(picker.message == "Folder cannot be read")
        #expect(picker.header?.status == "")
    }

    @Test func dismissingStopsIndexStatusPolling() async {
        let reads = CallCounter()
        let picker = CommandFilePicker(provider: CommandFileSearchProvider(
            search: { _, _, _, _ in [] }, children: { _, _ in [] },
            indexState: { _ = reads.next(); return .creating }), indexPollInterval: .milliseconds(1))
        picker.begin(anchor: 0, cwd: "/w")
        picker.refresh(text: "@", cursor: 1)
        for _ in 0..<500 where reads.count < 2 { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(reads.count >= 2)
        picker.end()
        let stopped = reads.count
        try? await Task.sleep(for: .milliseconds(20))
        #expect(reads.count == stopped)
        #expect(picker.header == nil)
    }

    @Test func initialIndexHeaderFitsAlongsideAShortScopeLabel() {
        let status = CommandFilePicker.initialIndexMessage
        let font = NSFont.systemFont(ofSize: 11)
        let statusWidth = ceil((status as NSString).size(withAttributes: [.font: font]).width)
        let header = CommandCompletionHeader(title: "/Users/example/projects/spooky", status: status)
        let width = CommandCompletionView.width(for: header, contentWidth: 160)
        #expect(width >= statusWidth + 96 + CommandOverlayStyle.inset * 5)
        #expect(width <= CommandOverlayStyle.maximumPopupWidth)
    }

    @Test func shellQuotingKeepsMetacharactersLiteral() {
        #expect(CommandFilePicking.shellQuoted("src/main.zig") == "src/main.zig")
        #expect(CommandFilePicking.shellQuoted("a b.txt") == "'a b.txt'")
        #expect(CommandFilePicking.shellQuoted("it's") == "'it'\\''s'")
        #expect(CommandFilePicking.shellQuoted("$HOME*?[x]!") == "'$HOME*?[x]!'")
        #expect(CommandFilePicking.shellQuoted("~user") == "'~user'")
        #expect(CommandFilePicking.shellQuoted("=ls") == "'=ls'")
        #expect(CommandFilePicking.shellQuoted("#note") == "'#note'")
        #expect(CommandFilePicking.shellQuoted("👻 ghost") == "'👻 ghost'")
        #expect(CommandFilePicking.shellQuoted("line\nbreak") == "'line\nbreak'")
        #expect(CommandFilePicking.shellQuoted("a;b|c&d`e`") == "'a;b|c&d`e`'")
    }

    @Test func insertionIsRelativeUnderCwdAndAbsoluteOtherwise() {
        let cwd = "/w"
        #expect(CommandFilePicking.insertion(for: entry("/w/src/a.zig"), cwd: cwd, followedBy: nil) == "src/a.zig ")
        #expect(CommandFilePicking.insertion(for: entry("/w/-rf"), cwd: cwd, followedBy: nil) == "./-rf ")
        #expect(CommandFilePicking.insertion(for: entry("/w/My Folder", dir: true), cwd: cwd, followedBy: nil)
            == "'My Folder/'")
        #expect(CommandFilePicking.insertion(for: entry("/etc/hosts"), cwd: cwd, followedBy: 32) == "/etc/hosts")
        #expect(CommandFilePicking.insertion(for: entry("/wx/a"), cwd: cwd, followedBy: nil) == "/wx/a ")
    }

    @Test func childrenHideDotfilesUnlessTheFilterStartsWithADot() {
        let children = [entry("/w/.gitignore"), entry("/w/b"), entry("/w/A", dir: true), entry("/w/.git", dir: true)]
        #expect(CommandFilePicking.filterChildren(children, filter: "").map(\.name) == ["A", "b"])
        #expect(CommandFilePicking.filterChildren(children, filter: ".giti").map(\.name) == [".gitignore"])
        #expect(!CommandFilePicking.visible(entry("/w/.git/config"), relativeTo: "/w", includeHidden: false))
        #expect(CommandFilePicking.visible(entry("/w/.gitignore"), relativeTo: "/w", includeHidden: true))
    }

    @Test func queryPlanning() {
        #expect(CommandFilePicking.plan(query: "", scope: "/w", cwd: "/w", browsed: false)
            == .list(directory: "/w"))
        #expect(CommandFilePicking.plan(query: "", scope: "/w/s", cwd: "/w", browsed: true)
            == .list(directory: "/w/s"))
        #expect(CommandFilePicking.plan(query: "ma", scope: "/w", cwd: "/w", browsed: false)
            == .search(text: "ma", near: "/w", scope: nil))
        // Nonempty queries inside a folder search the full index, scoped.
        #expect(CommandFilePicking.plan(query: "ma", scope: "/w/s", cwd: "/w", browsed: true)
            == .search(text: "ma", near: "/w", scope: "/w/s"))
        #expect(CommandFilePicking.plan(query: "src/../lib/x", scope: "/w", cwd: "/w", browsed: false)
            == .search(text: "x", near: "/w", scope: "/w/lib"))
        #expect(CommandFilePicking.plan(query: "src/", scope: "/w", cwd: "/w", browsed: false)
            == .list(directory: "/w/src"))
        #expect(CommandFilePicking.plan(query: "~/D", scope: "/w", cwd: "/w", browsed: false, home: "/h")
            == .search(text: "D", near: "/w", scope: "/h"))
        #expect(CommandFilePicking.plan(query: "/", scope: "/w", cwd: "/w", browsed: false)
            == .list(directory: "/"))
    }

    // MARK: Picker generations

    @Test func staleResultsAreShownButNeverAccepted() async {
        let picker = CommandFilePicker(provider: provider(search: { query in [entry("/w/\(query).txt")] }),
                                       debounce: .zero)
        picker.begin(anchor: 4, cwd: "/w")
        #expect(picker.refresh(text: "cat @ma", cursor: 7))
        // A newer query supersedes the pending one before either completes.
        #expect(picker.refresh(text: "cat @mai", cursor: 8))
        await settle(picker)
        #expect(picker.entries.map(\.name) == ["mai.txt"])
        #expect(picker.acceptance(at: 0, text: "cat @mai", cursor: 8)?.text == "mai.txt ")

        #expect(picker.refresh(text: "cat @main", cursor: 9))
        #expect(picker.entries.map(\.name) == ["mai.txt"])
        #expect(picker.acceptance(at: 0, text: "cat @main", cursor: 9) == nil)
        #expect(picker.selectedEntry == nil)
        await settle(picker)
        #expect(picker.acceptance(at: 0, text: "cat @main", cursor: 9)?.text == "main.txt ")
    }

    @Test func selectionStaysOnTheSamePathAcrossCompletedResults() async {
        let names = ["alpha", "alpine", "beta"]
        let picker = CommandFilePicker(provider: provider(search: { query in
            names.filter { $0.hasPrefix(query) }.map { entry("/w/\($0)") }
        }), debounce: .zero)
        picker.begin(anchor: 0, cwd: "/w")
        picker.refresh(text: "@a", cursor: 2)
        await settle(picker)
        picker.move(1)
        #expect(picker.selectedEntry?.name == "alpine")
        // A narrower completed query keeps the user's pick by path.
        picker.refresh(text: "@al", cursor: 3)
        await settle(picker)
        #expect(picker.selectedEntry?.name == "alpine")
    }

    @Test func folderQueriesSearchTheFullIndexWithinTheScope() async throws {
        let scopes = ScopeRecorder()
        // The bounded children listing omits the target entirely.
        let crowded = (0..<CommandFilePicking.childrenLimit).map { entry("/w/Big Dir/file\($0)") }
        let picker = CommandFilePicker(provider: CommandFileSearchProvider(
            search: { query, near, scope, limit in
                scopes.record(query: query, near: near.path, scope: scope?.path, limit: limit)
                return [entry("/w/Big Dir/zz-target.txt"), entry("/w/Big Dir/sub/zz-deep.txt"),
                        entry("/w/elsewhere/zz-outside.txt"), entry("/w/Big Dir/.hidden/zz-h")]
            },
            children: { _, _ in crowded }), debounce: .zero)
        picker.begin(anchor: 4, cwd: "/w")
        picker.refresh(text: "cat @", cursor: 5)
        await settle(picker)
        picker.enter(directory: "/w/Big Dir")
        picker.refresh(text: "cat @", cursor: 5)
        await settle(picker)
        #expect(picker.entries.count == CommandFilePicking.childrenLimit)
        #expect(!picker.entries.contains { $0.name == "zz-target.txt" })

        picker.refresh(text: "cat @zz", cursor: 7)
        await settle(picker)
        let call = try #require(scopes.last)
        #expect(call.query == "zz")
        #expect(call.near == "/w")
        #expect(call.scope == "/w/Big Dir")
        #expect(call.limit == CommandFilePicking.searchLimit)
        // Descendants are kept with a parent detail; out-of-scope and hidden
        // results are dropped. The header still names the searched folder.
        #expect(picker.entries.map(\.name) == ["zz-target.txt", "zz-deep.txt"])
        #expect(picker.candidates().map(\.detail) == ["", "sub"])
        #expect(picker.header?.title == "/w/Big Dir")
        #expect(picker.acceptance(at: 0, text: "cat @zz", cursor: 7)?.text == "'Big Dir/zz-target.txt' ")
        #expect(picker.acceptance(at: 1, text: "cat @zz", cursor: 7)?.text == "'Big Dir/sub/zz-deep.txt' ")
    }

    // MARK: Editor integration

    @Test func typedAtBrowsesFoldersWithSpacesAndInsertsAQuotedPath() async throws {
        let (view, window) = makeEditor(draft: "cat ")
        defer { window.close() }
        let picker = install(in: view, children: [
            "/w": [entry("/w/My Folder", dir: true), entry("/w/notes.md")],
            "/w/My Folder": [entry("/w/My Folder/z 1.txt")]
        ])
        let manager = try #require(view.undoManager)
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        typeAt(view)
        manager.endUndoGrouping()
        #expect(view.completions.filePickerActive)
        await settle(picker)
        #expect(picker.selectedEntry?.name == "My Folder")

        view.keyDown(with: try key(48, "\t"))
        #expect(view.string == "cat @")
        #expect(picker.session?.scope == "/w/My Folder")
        #expect(picker.header?.title == "/w/My Folder")
        await settle(picker)
        #expect(picker.selectedEntry?.name == "z 1.txt")

        manager.beginUndoGrouping()
        view.keyDown(with: try key(36, "\r"))
        manager.endUndoGrouping()
        #expect(view.string == "cat 'My Folder/z 1.txt' ")
        #expect(!view.completions.filePickerActive)
        manager.undo()
        #expect(view.string == "cat @")
        #expect(!view.completions.filePickerActive)
    }

    @Test func commandUpBrowsesTheParentAndReturnAcceptsAFolder() async throws {
        let (view, window) = makeEditor(draft: "cd ")
        defer { window.close() }
        let picker = install(in: view, cwd: "/w/My Folder", children: [
            "/w/My Folder": [entry("/w/My Folder/a")],
            "/w": [entry("/w/Ant", dir: true), entry("/w/My Folder", dir: true)]
        ])
        typeAt(view)
        await settle(picker)
        view.keyDown(with: try key(126, "", .command))
        await settle(picker)
        #expect(picker.session?.scope == "/w")
        #expect(picker.selectedEntry?.name == "My Folder")
        view.keyDown(with: try key(126, ""))
        #expect(picker.selectedEntry?.name == "Ant")
        view.keyDown(with: try key(36, "\r"))
        // Outside cwd, the folder is absolute with a trailing slash.
        #expect(view.string == "cd /w/Ant/")
    }

    @Test func escapeLeavesTheQueryByteIdentical() async throws {
        let (view, window) = makeEditor(draft: "ls ")
        defer { window.close() }
        let picker = install(in: view, children: ["/w": [entry("/w/src", dir: true)]])
        typeAt(view)
        view.insertText("sr", replacementRange: view.selectedRange())
        await settle(picker)
        #expect(view.completions.filePickerActive)
        view.keyDown(with: try key(53, "\u{1b}"))
        #expect(view.string == "ls @sr")
        #expect(!view.completions.filePickerActive)
        // Further typing never reopens an escaped query.
        view.insertText("c", replacementRange: view.selectedRange())
        #expect(!view.completions.filePickerActive)
    }

    @Test func pastedOrMidWordAtNeverOpensThePicker() {
        let (view, window) = makeEditor(draft: "mail me")
        defer { window.close() }
        _ = install(in: view, children: [:])
        typeAt(view)
        #expect(!view.completions.filePickerActive)
        view.insertText(" @", replacementRange: view.selectedRange())
        #expect(!view.completions.filePickerActive)
    }

    @Test func pickerStaysOffWithoutAKnownCwd() {
        let (view, window) = makeEditor(draft: "cat ")
        defer { window.close() }
        typeAt(view)
        #expect(!view.completions.filePickerActive)
    }

    @Test func whitespaceEndsThePickerAndNormalCompletionStillWorks() async throws {
        let (view, window) = makeEditor(draft: "cat ")
        defer { window.close() }
        let picker = install(in: view, children: ["/w": []])
        typeAt(view)
        await settle(picker)
        view.insertText(" ", replacementRange: view.selectedRange())
        #expect(!view.completions.filePickerActive)
        #expect(view.string == "cat @ ")

        view.string = "git ch"
        view.setSelectedRange(NSRange(location: 6, length: 0))
        var request: CommandCompletionRequest?
        view.onRequestCompletion = { request = $0 }
        view.keyDown(with: try key(48, "\t"))
        #expect(request?.text == "git ch")
        #expect(!view.completions.filePickerActive)
    }

    // MARK: Shared overlay material

    @Test func overlaySurfaceCachesItsShadowPathPerSize() throws {
        let surface = CommandOverlaySurface(blending: .withinWindow, castsShadow: true)
        surface.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        surface.layout()
        let first = try #require(surface.layer?.shadowPath)
        surface.layout()
        #expect(surface.layer?.shadowPath === first)
        surface.frame.size.width = 240
        surface.layout()
        #expect(surface.layer?.shadowPath !== first)
        #expect(surface.contentView.frame == surface.bounds)
    }

    // MARK: Helpers

    private func provider(
        children: [String: [CommandFileSearchEntry]] = [:],
        search: @escaping @Sendable (String) -> [CommandFileSearchEntry] = { _ in [] }
    ) -> CommandFileSearchProvider {
        CommandFileSearchProvider(
            search: { query, _, _, _ in search(query) },
            children: { directory, _ in children[directory.path] ?? [] })
    }

    @discardableResult
    private func install(in view: CommandTextView, cwd: String = "/w",
                         children: [String: [CommandFileSearchEntry]]) -> CommandFilePicker {
        let picker = CommandFilePicker(provider: provider(children: children), debounce: .zero)
        view.fileSearchDirectory = cwd
        view.completions.installFilePicker(picker)
        return picker
    }

    /// Mirrors `keyDown` for a typed `@` without needing an input context.
    private func typeAt(_ view: CommandTextView) {
        view.completions.pendingFileTrigger = true
        view.insertText("@", replacementRange: view.selectedRange())
        view.completions.pendingFileTrigger = false
    }

    private func settle(_ picker: CommandFilePicker) async {
        for _ in 0..<500 where !picker.resultsAreCurrent {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private func makeEditor(draft: String) -> (CommandTextView, CommandFilePickerTestWindow) {
        let view = CommandTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 24), textContainer: nil)
        view.string = draft
        view.setSelectedRange(NSRange(location: (draft as NSString).length, length: 0))
        let window = CommandFilePickerTestWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                                                 styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView?.addSubview(view)
        _ = window.makeFirstResponder(view)
        return (view, window)
    }

    private func key(_ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code))
    }
}

private func entry(_ path: String, dir: Bool = false) -> CommandFileSearchEntry {
    CommandFileSearchEntry(path: path, name: (path as NSString).lastPathComponent, isDirectory: dir)
}

private actor PickerIndexState {
    private var value = CommandFileSearchIndexState.creating
    func read() -> CommandFileSearchIndexState { value }
    func set(_ state: CommandFileSearchIndexState) { value = state }
}

/// Deliberately ignores cancellation to exercise stale service replies.
private actor PickerResponseGate<Value: Sendable> {
    private var response: Value?
    private var continuation: CheckedContinuation<Value, Never>?

    func wait() async -> Value {
        if let response { return response }
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(_ value: Value) {
        response = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}

private final class ScopeRecorder: @unchecked Sendable {
    struct Call { let query: String; let near: String; let scope: String?; let limit: Int }
    private let lock = NSLock()
    private var calls: [Call] = []
    var last: Call? {
        lock.lock()
        defer { lock.unlock() }
        return calls.last
    }
    func record(query: String, near: String, scope: String?, limit: Int) {
        lock.lock()
        defer { lock.unlock() }
        calls.append(Call(query: query, near: near, scope: scope, limit: limit))
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

@MainActor
private final class CommandFilePickerTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
