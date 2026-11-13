import Foundation
import CoreServices

struct CommandFileSearchEntry: Sendable, Equatable, Identifiable, Codable {
    let path: String
    let name: String
    let isDirectory: Bool

    var id: String { path }
}

/// On-demand queries of macOS's existing index. Spooky owns no indexer, watcher,
/// helper process, periodic refresh, or content scan. Filesystem I/O stays off MainActor.
actor CommandFileSearchService {
    static let shared = CommandFileSearchService()

    enum Failure: Error, LocalizedError, Sendable, Equatable {
        case unavailable(String)
        case invalidRequest
        case timedOut

        var errorDescription: String? {
            switch self {
            case .unavailable(let message): return message
            case .invalidRequest: return "Use an absolute folder and a filename query of at most 1,024 bytes."
            case .timedOut: return "Spotlight search is taking too long. Try a more specific filename."
            }
        }
    }

    struct MetadataRequest: Sendable, Equatable {
        let predicate: String
        let scope: String?
        let limit: Int
    }

    typealias MetadataSearch = @Sendable (MetadataRequest) async throws -> [CommandFileSearchEntry]
    static let maximumCandidates = 2_048
    private let metadataSearch: MetadataSearch
    private let timeout: Duration
    private var activeSearch: Task<[CommandFileSearchEntry], Error>?
    private var generation: UUID?

    init(
        metadataSearch: @escaping MetadataSearch = { try await CommandMetadataQuery(request: $0).run() },
        timeout: Duration = .seconds(3)
    ) {
        self.metadataSearch = metadataSearch
        self.timeout = timeout
    }

    func search(
        query: String,
        near: URL,
        scope: URL? = nil,
        limit: Int = 100
    ) async throws -> [CommandFileSearchEntry] {
        try Task.checkCancellation()
        guard query.utf8.count <= 1_024, !query.contains("\0"), Self.validDirectory(near),
              scope.map(Self.validDirectory) ?? true else { throw Failure.invalidRequest }
        let limit = min(max(limit, 1), 200)
        activeSearch?.cancel()
        generation = nil
        activeSearch = nil
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try children(of: scope ?? near, limit: limit)
        }
        let identifier = UUID()
        let operation = Task { [metadataSearch, timeout] in
            try Task.checkCancellation()
            // A small, nonrecursive listing keeps nearby/unindexed paths usable and
            // prevents exact local matches disappearing behind Spotlight's result cap.
            let local = (try? Self.directoryEntries(of: scope ?? near, limit: 500)) ?? []
            let localResults = Self.ranked(local, query: query, near: near.standardized.path,
                                           scope: scope?.standardized.path, limit: limit)
            if localResults.count >= limit { return localResults }
            do {
                let candidates = try await withThrowingTaskGroup(of: [CommandFileSearchEntry].self) { group in
                    group.addTask {
                        let budget = Self.maximumCandidates - local.count
                        let request = MetadataRequest(predicate: Self.metadataPredicate(for: query),
                            scope: scope?.standardized.path, limit: budget)
                        let indexed = try await metadataSearch(request)
                        return local + (try Self.normalized(Array(indexed.prefix(budget)),
                                                            preferredDirectory: scope ?? near))
                    }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        throw Failure.timedOut
                    }
                    defer { group.cancelAll() }
                    return try await group.next() ?? []
                }
                try Task.checkCancellation()
                return Self.ranked(candidates, query: query, near: near.standardized.path,
                                   scope: scope?.standardized.path, limit: limit)
            } catch {
                try Task.checkCancellation()
                if !localResults.isEmpty { return localResults }
                throw error
            }
        }
        generation = identifier
        activeSearch = operation
        defer {
            if generation == identifier {
                activeSearch = nil
                generation = nil
            }
        }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    /// Bounded one-level navigation works even where Spotlight indexing is disabled.
    func children(of directory: URL, limit: Int = 500) throws -> [CommandFileSearchEntry] {
        try Self.directoryEntries(of: directory, limit: limit)
    }

    private static func directoryEntries(of directory: URL, limit: Int) throws -> [CommandFileSearchEntry] {
        try Task.checkCancellation()
        guard Self.validDirectory(directory) else { throw Failure.invalidRequest }
        let limit = min(max(limit, 1), 1_000)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else { throw Failure.unavailable("This folder could not be read.") }
        var entries: [CommandFileSearchEntry] = []
        entries.reserveCapacity(limit)
        while entries.count < limit, let item = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try item.resourceValues(forKeys: Set(keys))
            var isDirectory = values.isDirectory == true
            if values.isSymbolicLink == true {
                var isDir: ObjCBool = false
                isDirectory = FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir) && isDir.boolValue
            }
            // Enumeration may return /private/var or a symlink's target. Preserve
            // the requested directory spelling for picker scope checks and insertion.
            let path = directory.standardizedFileURL.appendingPathComponent(item.lastPathComponent).path
            entries.append(CommandFileSearchEntry(path: path, name: item.lastPathComponent, isDirectory: isDirectory))
        }
        if let enumerationError { throw enumerationError }
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
    }

    func shutdown() {
        activeSearch?.cancel()
        activeSearch = nil
        generation = nil
    }

    /// Spotlight's documented query language is filename globbing, not shell syntax.
    /// Quote/backslash escaping prevents expression injection. User wildcard characters
    /// broaden the prefilter and are matched literally by ranked(), avoiding
    /// undocumented wildcard-escape behavior in Spotlight's parser.
    static func predicate(for query: String, fuzzy: Bool = true) -> String {
        let words = query.split(whereSeparator: \.isWhitespace)
        return words.map { word in
            let characters = word.map { character -> String in
                switch character {
                case "*", "?": return "*"
                case "\\": return "\\\\"
                case "\"": return "\\\""
                default: return String(character)
                }
            }
            return "kMDItemFSName == \"*" + characters.joined(separator: fuzzy ? "*" : "") + "*\"cd"
        }.joined(separator: " && ")
    }

    /// One bounded gather includes literal/contiguous filenames as well as fuzzy
    /// subsequences. Spotlight tokenization can reject a wildcard between filename
    /// punctuation and letters, so the contiguous form must also be present.
    static func metadataPredicate(for query: String) -> String {
        let contiguous = predicate(for: query, fuzzy: false)
        let fuzzy = predicate(for: query)
        return contiguous == fuzzy ? contiguous : "(\(contiguous)) || (\(fuzzy))"
    }

    /// Spotlight can return APFS backing paths (/System/Volumes/Data/...) or
    /// resolved symlink targets. Normalize each distinct parent once, then restore
    /// the user's scoped/cwd alias so filtering and relative insertion agree.
    /// Resolve only parents: resolving a symlink result itself changes its identity.
    static func normalized(_ entries: [CommandFileSearchEntry], preferredDirectory: URL) throws
        -> [CommandFileSearchEntry] {
        let preferred = preferredDirectory.standardizedFileURL.path
        let resolved = preferredDirectory.resolvingSymlinksInPath().path
        let prefix = resolved == "/" ? "/" : resolved + "/"
        var parents: [String: String] = [:]
        return try entries.prefix(maximumCandidates).compactMap { entry in
            try Task.checkCancellation()
            guard validEntry(entry) else { return nil }
            let parent = (entry.path as NSString).deletingLastPathComponent
            let normalizedParent: String
            if let cached = parents[parent] {
                normalizedParent = cached
            } else {
                normalizedParent = URL(fileURLWithPath: parent).resolvingSymlinksInPath().path
                parents[parent] = normalizedParent
            }
            var path = URL(fileURLWithPath: normalizedParent)
                .appendingPathComponent((entry.path as NSString).lastPathComponent).path
            if path.hasPrefix(prefix) {
                let relative = path.dropFirst(prefix.count)
                path = (preferred == "/" ? "/" : preferred + "/") + relative
            }
            return CommandFileSearchEntry(path: path, name: entry.name, isDirectory: entry.isDirectory)
        }
    }

    private static func validEntry(_ entry: CommandFileSearchEntry) -> Bool {
        entry.path.hasPrefix("/") && !entry.path.contains("\0") && entry.path.utf8.count <= 4_096
            && !entry.name.isEmpty && !entry.name.contains("/") && !entry.name.contains("\0")
    }

    static func ranked(_ candidates: [CommandFileSearchEntry], query: String, near: String,
                       scope: String?, limit: Int) -> [CommandFileSearchEntry] {
        let words = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
        let nearParts = near.split(separator: "/")
        var seen = Set<String>()
        let ranked = candidates.prefix(maximumCandidates).compactMap { entry -> (CommandFileSearchEntry, Int, Int)? in
            guard validEntry(entry),
                  scope.map({ entry.path.hasPrefix($0 == "/" ? "/" : $0 + "/") }) ?? true,
                  seen.insert(entry.path).inserted else { return nil }
            let name = fold(entry.name)
            var total = 0
            for word in words {
                guard let score = score(word, in: name) else { return nil }
                total += score
            }
            let proximity = zip(entry.path.split(separator: "/"), nearParts).prefix { $0 == $1 }.count
            return (entry, total, proximity)
        }
        return ranked.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if $0.2 != $1.2 { return $0.2 > $1.2 }
            if $0.0.name.count != $1.0.name.count { return $0.0.name.count < $1.0.name.count }
            return $0.0.path < $1.0.path
        }.prefix(min(max(limit, 1), 200)).map(\.0)
    }

    private static func fold(_ text: String) -> [UInt32] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.map(\.value)
    }

    private static func score(_ word: [UInt32], in name: [UInt32]) -> Int? {
        guard !word.isEmpty else { return 0 }
        guard word.count <= name.count else { return nil }
        if word == name { return 0 }
        if name.starts(with: word) { return 1 }
        if word.count < name.count {
            for index in 1...(name.count - word.count) where name[index..<index + word.count].elementsEqual(word) {
                return 10 + index
            }
        }
        var index = 0
        var gaps = 0
        for character in word {
            while index < name.count, name[index] != character { index += 1; gaps += 1 }
            guard index < name.count else { return nil }
            index += 1
        }
        return 1_000 + gaps
    }

    private static func validDirectory(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix("/") && !url.path.contains("\0") && url.path.utf8.count <= 4_096
    }
}

/// All mutable state and MDQuery access are confined to `queue`. The retained
/// async invocation keeps this object alive until its continuation completes.
/// Queries are asynchronous/static: no blocked worker and no live index updates.
private final class CommandMetadataQuery: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "com.patinasystems.spooky.filename-query", qos: .utility)
    private let request: CommandFileSearchService.MetadataRequest
    private var query: MDQuery?
    private var continuation: CheckedContinuation<[CommandFileSearchEntry], Error>?
    private var result: Result<[CommandFileSearchEntry], Error>?
    private var entries: [CommandFileSearchEntry] = []
    private var nextResult = 0
    private var resultCount = 0
    private var updatesDisabled = false

    init(request: CommandFileSearchService.MetadataRequest) { self.request = request }

    func run() async throws -> [CommandFileSearchEntry] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Self.queue.async { self.start(continuation) }
            }
        } onCancel: {
            Self.queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    private func start(_ continuation: CheckedContinuation<[CommandFileSearchEntry], Error>) {
        dispatchPrecondition(condition: .onQueue(Self.queue))
        if let result { continuation.resume(with: result); return }
        self.continuation = continuation
        guard let query = MDQueryCreate(kCFAllocatorDefault, request.predicate as CFString, nil, nil) else {
            finish(.failure(CommandFileSearchService.Failure.unavailable("Spotlight could not create this filename query.")))
            return
        }
        self.query = query
        let scopes: [String] = [request.scope ?? (kMDQueryScopeComputerIndexed as String)]
        MDQuerySetSearchScope(query, scopes as CFArray, 0)
        MDQuerySetMaxCount(query, request.limit)
        MDQuerySetDispatchQueue(query, Self.queue)
        CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<CommandMetadataQuery>.fromOpaque(observer).takeUnretainedValue().completed()
            }, kMDQueryDidFinishNotification, Unmanaged.passUnretained(query).toOpaque(), .deliverImmediately)
        // Neither kMDQuerySynchronous nor kMDQueryWantsUpdates: return after one gather.
        if !MDQueryExecute(query, 0) {
            finish(.failure(CommandFileSearchService.Failure.unavailable("Spotlight filename search is unavailable.")))
        }
    }

    private func completed() {
        dispatchPrecondition(condition: .onQueue(Self.queue))
        guard let query, result == nil, !updatesDisabled else { return }
        MDQueryDisableUpdates(query)
        updatesDisabled = true
        resultCount = min(MDQueryGetResultCount(query), request.limit)
        entries.reserveCapacity(resultCount)
        readChunk()
    }

    private func readChunk() {
        dispatchPrecondition(condition: .onQueue(Self.queue))
        guard let query, result == nil else { return }
        // Yield the serial queue between small batches so cancellation and the
        // newest query never wait behind metadata materialization of 2,048 rows.
        let end = min(nextResult + 32, resultCount)
        for index in nextResult..<end {
            guard let pointer = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(pointer).takeUnretainedValue()
            let attributes = MDItemCopyAttributes(item,
                [kMDItemPath, kMDItemFSName, kMDItemContentTypeTree] as CFArray) as? [String: Any] ?? [:]
            guard let path = attributes[kMDItemPath as String] as? String,
                  let name = attributes[kMDItemFSName as String] as? String else { continue }
            let types = attributes[kMDItemContentTypeTree as String] as? [String] ?? []
            entries.append(CommandFileSearchEntry(path: path, name: name,
                isDirectory: types.contains("public.folder") || types.contains("public.directory")))
        }
        nextResult = end
        if nextResult < resultCount {
            Self.queue.async { self.readChunk() }
        } else {
            finish(.success(entries))
        }
    }

    private func finish(_ result: Result<[CommandFileSearchEntry], Error>) {
        dispatchPrecondition(condition: .onQueue(Self.queue))
        guard self.result == nil else { return }
        self.result = result
        if let query {
            // Remove the observer first: Stop can synchronously post final notifications.
            CFNotificationCenterRemoveObserver(CFNotificationCenterGetLocalCenter(),
                Unmanaged.passUnretained(self).toOpaque(), CFNotificationName(kMDQueryDidFinishNotification),
                Unmanaged.passUnretained(query).toOpaque())
            if updatesDisabled { MDQueryEnableUpdates(query) }
            MDQueryStop(query)
            self.query = nil
        }
        continuation?.resume(with: result)
        continuation = nil
    }
}
