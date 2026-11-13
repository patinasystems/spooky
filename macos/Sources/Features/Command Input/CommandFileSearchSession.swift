import Foundation

/// Injected boundary around `CommandFileSearchService` so tests never touch
/// the real index or filesystem. Results are filename metadata only.
struct CommandFileSearchProvider: Sendable {
    var search: @Sendable (_ query: String, _ near: URL, _ scope: URL?, _ limit: Int) async throws
        -> [CommandFileSearchEntry]
    var children: @Sendable (_ directory: URL, _ limit: Int) async throws -> [CommandFileSearchEntry]

    static let live = CommandFileSearchProvider(
        search: { query, near, scope, limit in
            try await CommandFileSearchService.shared.search(query: query, near: near, scope: scope, limit: limit)
        },
        children: { directory, limit in
            try await CommandFileSearchService.shared.children(of: directory, limit: limit)
        })
}

/// Pure `@` picker rules: trigger detection, active range, query planning,
/// filtering, and shell-safe insertion. Nothing here evaluates shell input.
enum CommandFilePicking {
    static let searchLimit = 100
    static let childrenLimit = 500

    enum Plan: Equatable {
        /// Bounded direct entries of `directory` (empty query only).
        case list(directory: String)
        /// Full-index filename search ranked near `near`. With `scope`, it is
        /// search-within-folder: descendants of `scope` at any depth, so a
        /// name beyond the bounded children listing is still found.
        case search(text: String, near: String, scope: String?)
    }

    // MARK: Trigger

    /// True when the `@` at `index` was typed at a shell argument boundary:
    /// not mid-word (emails, `$@`, `*(@)`), not escaped, not quoted, not in a
    /// comment, and not inside a heredoc body.
    static func triggers(in text: String, at index: Int) -> Bool {
        let units = Array(text.utf16)
        guard index >= 0, index < units.count, units[index] == 64 else { return false }
        if index > 0 {
            // Start, whitespace, `=` (`--file=@`), and redirections only.
            guard [9, 10, 13, 32, 61, 60, 62].contains(units[index - 1]) else { return false }
            // `<<@` would be a heredoc delimiter.
            if units[index - 1] == 60, index > 1, units[index - 2] == 60 { return false }
        }
        enum Quote { case single, double, dollarSingle }
        var quote: Quote?
        var escaped = false
        var comment = false
        var heredocPending = false
        var wordStart = true
        // The last unit consumed by a backslash: `foo\ @`, `foo\=@`, and a
        // `\`-newline continuation all keep the `@` inside the same word.
        var escapedAt = -1
        for i in 0..<index {
            let unit = units[i]
            if unit == 10 {
                if escaped { escapedAt = i }
                if quote == nil, !escaped, heredocPending { return false }
                comment = false
                escaped = false
                if quote == nil { wordStart = true }
                continue
            }
            if comment { continue }
            if escaped { escaped = false; escapedAt = i; wordStart = false; continue }
            if let open = quote {
                switch (open, unit) {
                case (.single, 39), (.dollarSingle, 39), (.double, 34): quote = nil
                case (.double, 92), (.dollarSingle, 92): escaped = true
                default: break
                }
                continue
            }
            switch unit {
            case 92: escaped = true
            case 39: quote = i > 0 && units[i - 1] == 36 ? .dollarSingle : .single
            case 34: quote = .double
            case 35 where wordStart: comment = true
            case 60 where i + 1 < index && units[i + 1] == 60
                && !(i + 2 < index && units[i + 2] == 60) && !(i > 0 && units[i - 1] == 60):
                heredocPending = true
            default: break
            }
            wordStart = [9, 32, 38, 40, 59, 124].contains(unit)
        }
        if index > 0, escapedAt == index - 1 { return false }
        return quote == nil && !escaped && !comment
    }

    // MARK: Active range

    /// `@query`: from the anchor up to whitespace or an unquoted shell
    /// delimiter, so acceptance never consumes `;cmd`, `|wc`, `>out`, quotes,
    /// parentheses, or substitutions. Nil once the anchor is gone or the caret
    /// has left the query (typing a delimiter therefore ends the session).
    /// Returned filenames may contain these characters; insertion quotes them.
    static func activeRange(in text: String, anchor: Int, cursor: Int) -> NSRange? {
        let value = text as NSString
        guard anchor >= 0, anchor < value.length, value.character(at: anchor) == 64 else { return nil }
        var end = anchor + 1
        while end < value.length, !endsQuery(value.character(at: end)) { end += 1 }
        guard cursor > anchor, cursor <= end else { return nil }
        return NSRange(location: anchor, length: end - anchor)
    }

    static func isWhitespace(_ unit: unichar) -> Bool { unit == 32 || unit == 9 || unit == 10 || unit == 13 }

    /// Whitespace plus `; | & < > ( ) ` ' " $ \`.
    static func endsQuery(_ unit: unichar) -> Bool {
        isWhitespace(unit) || [59, 124, 38, 60, 62, 40, 41, 96, 39, 34, 36, 92].contains(unit)
    }

    // MARK: Planning

    static func plan(query: String, scope: String, cwd: String, browsed: Bool,
                     home: String = NSHomeDirectory()) -> Plan {
        if let slash = query.lastIndex(of: "/") {
            let directoryPart = String(query[..<slash])
            let filter = String(query[query.index(after: slash)...])
            let directory = resolve(directoryPart, absolute: query.hasPrefix("/"), base: scope, home: home)
            return filter.isEmpty ? .list(directory: directory) : .search(text: filter, near: cwd, scope: directory)
        }
        if query.isEmpty { return .list(directory: scope) }
        return .search(text: query, near: cwd, scope: browsed ? scope : nil)
    }

    static func resolve(_ part: String, absolute: Bool, base: String, home: String) -> String {
        let path: String
        if part.isEmpty { path = absolute ? "/" : base } else if part == "~" { path = home } else if part.hasPrefix("~/") {
            path = home + "/" + part.dropFirst(2)
        } else if part.hasPrefix("/") { path = part } else { path = base + "/" + part }
        return standardized(path)
    }

    static func standardized(_ path: String) -> String {
        let result = URL(fileURLWithPath: path).standardized.path
        return result.isEmpty ? "/" : result
    }

    static func parent(of path: String) -> String {
        path == "/" ? "/" : standardized((path as NSString).deletingLastPathComponent)
    }

    // MARK: Filtering and ranking

    /// Dotfiles and anything under a hidden directory stay out of results
    /// unless the query itself starts with `.` (so `.gitignore` is findable).
    static func visible(_ entry: CommandFileSearchEntry, relativeTo base: String, includeHidden: Bool) -> Bool {
        guard !includeHidden else { return true }
        let path = relativePath(entry.path, to: base) ?? relativePath(entry.path, to: NSHomeDirectory()) ?? entry.path
        return !path.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    static func filterChildren(_ entries: [CommandFileSearchEntry], filter: String) -> [CommandFileSearchEntry] {
        let includeHidden = filter.hasPrefix(".")
        let visible = entries.filter { includeHidden || !$0.name.hasPrefix(".") }
        guard !filter.isEmpty else {
            return visible.sorted { lhs, rhs in
                lhs.isDirectory != rhs.isDirectory ? lhs.isDirectory
                    : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
        let query = fold(filter)
        return visible.compactMap { entry -> (Int, CommandFileSearchEntry)? in
            score(query, in: fold(entry.name)).map { ($0, entry) }
        }.sorted { lhs, rhs in
            lhs.0 != rhs.0 ? lhs.0 < rhs.0 : lhs.1.name.localizedStandardCompare(rhs.1.name) == .orderedAscending
        }.map(\.1)
    }

    static func fold(_ text: String) -> [UInt32] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).unicodeScalars.map(\.value)
    }

    /// Lower is better: prefix, then contiguous substring, then subsequence.
    static func score(_ query: [UInt32], in value: [UInt32]) -> Int? {
        guard !query.isEmpty else { return 0 }
        guard query.count <= value.count else { return nil }
        if value.starts(with: query) { return 0 }
        if value.count > query.count {
            for start in 1...(value.count - query.count) where value[start..<start + query.count].elementsEqual(query) {
                return start
            }
        }
        var next = 0
        var gaps = 0
        for unit in query {
            while next < value.count, value[next] != unit { next += 1; gaps += 1 }
            guard next < value.count else { return nil }
            next += 1
        }
        return 1_000 + gaps
    }

    // MARK: Presentation

    static func relativePath(_ path: String, to base: String) -> String? {
        if base == "/" { return path.hasPrefix("/") ? String(path.dropFirst()) : nil }
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : nil
    }

    static func abbreviated(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if let relative = relativePath(path, to: home) { return "~/" + relative }
        return path
    }

    static func detail(for entry: CommandFileSearchEntry, near: String) -> String {
        let parent = (entry.path as NSString).deletingLastPathComponent
        if parent == near { return "" }
        return relativePath(parent, to: near) ?? abbreviated(parent)
    }

    // MARK: Insertion

    /// Relative to `cwd` when beneath it (with `./` before a leading dash),
    /// otherwise absolute. Folders keep a trailing slash and no space; files
    /// get one space unless whitespace already follows the replaced range.
    static func insertion(for entry: CommandFileSearchEntry, cwd: String, followedBy next: unichar?) -> String {
        var path = relativePath(entry.path, to: cwd) ?? entry.path
        if path.isEmpty { path = entry.path }
        if path.hasPrefix("-") { path = "./" + path }
        if entry.isDirectory, !path.hasSuffix("/") { path += "/" }
        var result = shellQuoted(path)
        if !entry.isDirectory, !(next.map(isWhitespace) ?? false) { result += " " }
        return result
    }

    /// Bare only for plainly safe ASCII; everything else is single-quoted, so
    /// spaces, globs, `$`, `!`, `~`, `=`, `#`, newlines, and emoji are literal.
    static func shellQuoted(_ path: String) -> String {
        let safe = path.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"):
                return true
            default:
                return "_./+,:@-".utf8.contains(byte)
            }
        }
        if safe, !path.isEmpty { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// One `@` session: the anchor, the cwd it started in, and a browsed scope
/// that is bounded UI state only. Navigation never changes the shell's cwd.
struct CommandFileSearchSession: Equatable {
    struct DirectoryAnchor: Equatable {
        let prefix: String
        let path: String
    }
    let anchor: Int
    let cwd: String
    var scope: String
    var browsed = false
    var directoryAnchors: [DirectoryAnchor] = []

    init(anchor: Int, cwd: String) {
        self.anchor = anchor
        self.cwd = CommandFilePicking.standardized(cwd)
        self.scope = self.cwd
    }
}

/// Owns picker state, generations, and async lookups. A new query clears old
/// rows immediately; only results for the current generation can be displayed,
/// accepted, or drilled into.
@MainActor
final class CommandFilePicker {
    private(set) var session: CommandFileSearchSession?
    private(set) var entries: [CommandFileSearchEntry] = []
    private(set) var selectedIndex = 0
    private(set) var message: String?
    private(set) var header: CommandCompletionHeader?
    private(set) var generation: UInt64 = 0
    private var resultsGeneration: UInt64?
    private var near = ""
    /// Global results show their parent folder; a single browsed folder does not.
    private var showsDetail = false
    private var userMovedSelection = false
    private var preferredPath: String?
    private var lastQuery: String?
    private var task: Task<Void, Never>?
    private var childrenCache: [String: [CommandFileSearchEntry]] = [:]
    private let provider: CommandFileSearchProvider
    private let debounce: Duration
    /// Called after an async result or failure changes visible state.
    var onChange: () -> Void = {}

    init(provider: CommandFileSearchProvider = .live, debounce: Duration = .milliseconds(8)) {
        self.provider = provider
        self.debounce = debounce
    }

    deinit { task?.cancel() }

    var isActive: Bool { session != nil }
    var resultsAreCurrent: Bool { resultsGeneration == generation }
    var selectedEntry: CommandFileSearchEntry? {
        resultsAreCurrent && entries.indices.contains(selectedIndex) ? entries[selectedIndex] : nil
    }

    func begin(anchor: Int, cwd: String) {
        end()
        session = CommandFileSearchSession(anchor: anchor, cwd: cwd)
    }

    func end() {
        task?.cancel()
        task = nil
        session = nil
        entries = []
        selectedIndex = 0
        message = nil
        header = nil
        resultsGeneration = nil
        userMovedSelection = false
        preferredPath = nil
        lastQuery = nil
        childrenCache = [:]
        near = ""
        showsDetail = false
        generation &+= 1
    }

    func activeRange(in text: String, cursor: Int) -> NSRange? {
        guard let session else { return nil }
        return CommandFilePicking.activeRange(in: text, anchor: session.anchor, cursor: cursor)
    }

    /// Re-plans for the current `@query`. Returns false when the session no
    /// longer has an active range; the caller then ends it without editing.
    @discardableResult
    func refresh(text: String, cursor: Int) -> Bool {
        guard var session, let range = activeRange(in: text, cursor: cursor) else { return false }
        let query = (text as NSString).substring(with: NSRange(location: range.location + 1,
                                                             length: cursor - range.location - 1))
        session.directoryAnchors.removeAll { !query.hasPrefix($0.prefix) }
        if let lastQuery, query == lastQuery + "/", let entry = selectedEntry, entry.isDirectory,
           let component = lastQuery.split(separator: "/").last,
           ![".", "..", "~"].contains(String(component)), session.directoryAnchors.count < 32 {
            session.directoryAnchors.append(.init(prefix: query, path: entry.path))
        }
        self.session = session
        lastQuery = query
        let anchor = session.directoryAnchors.last
        let remaining = anchor.map { String(query.dropFirst($0.prefix.count)) } ?? query
        let scope = anchor?.path ?? session.scope
        generation &+= 1
        let current = generation
        task?.cancel()
        task = nil
        let plan = CommandFilePicking.plan(query: remaining, scope: scope, cwd: session.cwd,
                                           browsed: session.browsed || anchor != nil)
        switch plan {
        case let .list(directory):
            near = directory
            showsDetail = false
            header = .init(title: CommandFilePicking.abbreviated(directory), status: "")
            if let cached = childrenCache[directory] {
                apply(CommandFilePicking.filterChildren(cached, filter: ""), generation: current,
                      empty: "Empty folder")
                return true
            }
            markPending()
            task = Task { [weak self, provider] in
                do {
                    let children = try await provider.children(URL(fileURLWithPath: directory),
                                                               CommandFilePicking.childrenLimit)
                    guard !Task.isCancelled, let self, self.generation == current else { return }
                    if self.childrenCache.count >= 16 { self.childrenCache.removeAll(keepingCapacity: true) }
                    self.childrenCache[directory] = children
                    self.apply(CommandFilePicking.filterChildren(children, filter: ""), generation: current,
                               empty: "Empty folder")
                } catch {
                    guard !Task.isCancelled, let self, self.generation == current else { return }
                    if (try? await self.redirectFuzzyDirectory(query: query, text: text, cursor: cursor,
                                                              generation: current)) == true { return }
                    guard self.generation == current, !Task.isCancelled else { return }
                    self.fail(error, generation: current)
                }
                self?.onChange()
            }
        case let .search(text, near, scope):
            // Header, details, dotfile visibility, and Cmd-Up use the folder
            // being searched; ranking stays near the session cwd.
            let base = scope ?? near
            self.near = base
            showsDetail = true
            header = .init(title: CommandFilePicking.abbreviated(base), status: "")
            markPending()
            let includeHidden = text.hasPrefix(".")
            task = Task { [weak self, provider, debounce] in
                do {
                    try await Task.sleep(for: debounce)
                    let results = try await provider.search(text, URL(fileURLWithPath: near),
                                                            scope.map { URL(fileURLWithPath: $0) },
                                                            CommandFilePicking.searchLimit)
                    guard !Task.isCancelled, let self, self.generation == current else { return }
                    let visible = results.filter {
                        (scope == nil || CommandFilePicking.relativePath($0.path, to: base) != nil)
                            && CommandFilePicking.visible($0, relativeTo: base, includeHidden: includeHidden)
                    }
                    if visible.isEmpty,
                       try await self.redirectFuzzyDirectory(query: query, text: text, cursor: cursor,
                                                             generation: current) { return }
                    guard self.generation == current, !Task.isCancelled else { return }
                    self.apply(visible, generation: current, empty: "No matches",
                               truncated: results.count >= CommandFilePicking.searchLimit)
                } catch {
                    guard !Task.isCancelled, let self, self.generation == current else { return }
                    self.fail(error, generation: current)
                }
                self?.onChange()
            }
        }
        return true
    }

    /// Resolve a fuzzy directory prefix if slash was typed before its search
    /// response arrived. Literal existing folders win; resolved aliases remain
    /// breadcrumbs so backspacing restores the correct indexed parent.
    private func redirectFuzzyDirectory(query: String, text: String, cursor: Int,
                                        generation current: UInt64) async throws -> Bool {
        guard let session, session.directoryAnchors.count < 32 else { return false }
        let anchor = session.directoryAnchors.last
        let remaining = anchor.map { String(query.dropFirst($0.prefix.count)) } ?? query
        guard !remaining.hasPrefix("/"), !remaining.hasPrefix("~"), !remaining.hasPrefix("."),
              let slash = remaining.lastIndex(of: "/") else { return false }
        var base = anchor?.path ?? session.scope
        var prefix = anchor?.prefix ?? ""
        var global = anchor == nil && !session.browsed
        for component in remaining[..<slash].split(separator: "/").prefix(32) {
            try Task.checkCancellation()
            guard generation == current else { return false }
            let literal = CommandFilePicking.standardized(base + "/" + component)
            prefix += component + "/"
            do {
                _ = try await provider.children(URL(fileURLWithPath: literal), 1)
                base = literal
                global = false
            } catch {
                try Task.checkCancellation()
                guard generation == current else { return false }
                let matches = try await provider.search(String(component), URL(fileURLWithPath: base),
                                                        global ? nil : URL(fileURLWithPath: base),
                                                        CommandFilePicking.searchLimit)
                guard !Task.isCancelled, generation == current,
                      let directory = matches.first(where: { $0.isDirectory && $0.path != literal }),
                      var latest = self.session else { return false }
                latest.directoryAnchors.append(.init(prefix: prefix, path: directory.path))
                self.session = latest
                _ = refresh(text: text, cursor: cursor)
                onChange()
                return true
            }
        }
        return false
    }

    func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + entries.count) % entries.count
        userMovedSelection = true
    }

    /// Browse into a directory. The caller clears the query text to `@`, so
    /// a path containing spaces never enters the draft unquoted.
    func enter(directory: String) {
        guard var session else { return }
        session.scope = CommandFilePicking.standardized(directory)
        session.browsed = true
        session.directoryAnchors = []
        lastQuery = nil
        self.session = session
        userMovedSelection = false
        preferredPath = nil
    }

    /// Cmd-Up: browse the parent and preselect the folder we came from.
    func enterParent() {
        guard let session else { return }
        // The folder actually listed, including one typed as `@dir/`.
        let from = near.isEmpty ? session.scope : near
        enter(directory: CommandFilePicking.parent(of: from))
        preferredPath = from
    }

    /// The exact replacement for accepting `index`, or nil if results are
    /// stale for the current query or the range has gone.
    func acceptance(at index: Int, text: String, cursor: Int) -> (range: NSRange, text: String)? {
        guard let session, resultsAreCurrent, entries.indices.contains(index),
              let range = activeRange(in: text, cursor: cursor) else { return nil }
        let value = text as NSString
        let next = NSMaxRange(range) < value.length ? value.character(at: NSMaxRange(range)) : nil
        return (range, CommandFilePicking.insertion(for: entries[index], cwd: session.cwd, followedBy: next))
    }

    /// Display rows. Replacement fields are placeholders anchored at `@` for
    /// alignment; acceptance always recomputes through `acceptance(at:)`.
    func candidates() -> [CommandCompletionCandidate] {
        guard let session else { return [] }
        let range = NSRange(location: session.anchor, length: 0)
        return entries.map { entry in
            CommandCompletionCandidate(
                displayText: entry.name + (entry.isDirectory ? "/" : ""),
                detail: showsDetail ? CommandFilePicking.detail(for: entry, near: near) : "",
                replacementText: "", replacementRange: range)
        }
    }

    private func markPending() {
        if preferredPath == nil, userMovedSelection, entries.indices.contains(selectedIndex) {
            preferredPath = entries[selectedIndex].path
        }
        entries = []
        selectedIndex = 0
        resultsGeneration = nil
        header?.status = "Searching…"
        message = "Searching…"
    }

    private func apply(_ results: [CommandFileSearchEntry], generation current: UInt64, empty: String,
                       truncated: Bool = false) {
        let keep = userMovedSelection && entries.indices.contains(selectedIndex) ? entries[selectedIndex].path : nil
        let wanted = preferredPath ?? keep
        entries = results
        resultsGeneration = current
        selectedIndex = wanted.flatMap { path in results.firstIndex { $0.path == path } } ?? 0
        if preferredPath != nil {
            preferredPath = nil
            userMovedSelection = userMovedSelection || selectedIndex != 0
        }
        message = results.isEmpty ? empty : nil
        header?.status = truncated ? "\(CommandFilePicking.searchLimit)+" : ""
    }

    private func fail(_ error: Error, generation current: UInt64) {
        entries = []
        resultsGeneration = current
        selectedIndex = 0
        message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        header?.status = ""
    }

}
