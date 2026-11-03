import Foundation
import Darwin

struct CommandFileSearchEntry: Sendable, Equatable, Identifiable, Codable {
    let path: String
    let name: String
    let isDirectory: Bool

    var id: String { path }
}

enum CommandFileSearchIndexState: String, Codable, Sendable {
    case creating
    case ready
}

/// One app-owned filename indexer. Disk access and process I/O stay off MainActor.
actor CommandFileSearchService {
    static let shared = CommandFileSearchService()

    enum Failure: Error, LocalizedError, Sendable, Equatable {
        case unavailable(String)
        case indexing(String)
        case invalidRequest
        case invalidResponse
        case timedOut

        var errorDescription: String? {
            switch self {
            case .unavailable(let message), .indexing(let message): return message
            case .invalidRequest: return "Use an absolute folder and a filename query of at most 1,024 bytes."
            case .invalidResponse: return "The filename search helper returned an invalid response."
            case .timedOut: return "Filename search is taking too long. Try again after indexing finishes."
            }
        }
    }

    private struct Request: Encodable {
        let id: UUID
        let op: String
        var query: String?
        var near: String?
        var scope: String?
        var limit: Int?
    }

    struct Response: Decodable, Sendable {
        let id: UUID
        let entries: [CommandFileSearchEntry]
        let error: String?
        let cancelled: Bool
        let state: CommandFileSearchIndexState?
    }

    private struct Pending {
        let continuation: CheckedContinuation<Response, Error>
        let timeout: Task<Void, Never>
        let isSearch: Bool
    }

    private let executableURL: URL
    private let indexDirectory: URL
    private let diagnosticPath: String?
    private let timeout: Duration
    private var process: Process?
    private var input: FileHandle?
    private var outputReader: CommandFileSearchReader?
    private var reader: Task<Void, Never>?
    private var streamContinuation: AsyncStream<Data>.Continuation?
    private var generation: UUID?
    private var buffer = Data()
    private var pending: [UUID: Pending] = [:]

    init(
        executableURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/spooky-fsearch"),
        indexDirectory: URL? = nil,
        timeout: Duration = .seconds(10)
    ) {
        self.executableURL = executableURL
        let environment = ProcessInfo.processInfo.environment
        let configuration = Self.diagnosticConfiguration(
            enabled: CommandInputDiagnostics.isEnabled,
            indexDirectory: environment["SPOOKY_FSEARCH_INDEX_DIRECTORY"]
                ?? Bundle.main.object(forInfoDictionaryKey: "SpookyFileSearchDiagnosticIndexDirectory") as? String,
            outputPath: environment["SPOOKY_FSEARCH_DIAGNOSTICS_PATH"]
                ?? Bundle.main.object(forInfoDictionaryKey: "SpookyFileSearchDiagnosticsPath") as? String
        )
        self.indexDirectory = indexDirectory ?? configuration.indexDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Spooky/fsearch-names-v1", isDirectory: true)
        diagnosticPath = configuration.outputPath
        self.timeout = timeout
    }

    struct DiagnosticConfiguration: Sendable, Equatable {
        let indexDirectory: URL?
        let outputPath: String?
    }

    /// Candidate-only overrides are inert unless diagnostics are explicitly enabled.
    static func diagnosticConfiguration(
        enabled: Bool,
        indexDirectory: String?,
        outputPath: String?
    ) -> DiagnosticConfiguration {
        func absolutePath(_ path: String?) -> String? {
            guard let path, path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4_096 else { return nil }
            return path
        }
        guard enabled else { return DiagnosticConfiguration(indexDirectory: nil, outputPath: nil) }
        return DiagnosticConfiguration(
            indexDirectory: absolutePath(indexDirectory).map { URL(fileURLWithPath: $0, isDirectory: true) },
            outputPath: absolutePath(outputPath)
        )
    }

    /// Called at app launch. Starting again reuses the same engine/process.
    func startIndexing() async throws {
        _ = try await indexState()
    }

    /// The engine publishes ready after a saved index loads or the first crawl completes.
    /// Status requests never replace or queue behind a filename query in the helper.
    func indexState() async throws -> CommandFileSearchIndexState {
        let response = try await perform(Request(id: UUID(), op: "status"))
        guard let state = response.state else { throw Failure.invalidResponse }
        return state
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
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try children(of: scope ?? near, limit: limit)
        }
        return try await perform(Request(id: UUID(), op: "search", query: query, near: near.path,
                                         scope: scope?.path, limit: limit)).entries
    }

    private func perform(_ request: Request) async throws -> Response {
        let id = request.id
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try startIfNeeded()
            // Search supersession must not cancel app startup or readiness polling.
            if request.op == "search" {
                for previous in pending.filter({ $0.value.isSearch }).map(\.key) { cancel(previous) }
            }
            guard pending.count < 16 else {
                throw Failure.unavailable("Too many pending filename search requests. Try again.")
            }
            return try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.expire(id)
                }
                pending[id] = Pending(continuation: continuation, timeout: timeout, isSearch: request.op == "search")
                do {
                    try send(request)
                } catch {
                    finish(id, result: .failure(error))
                    stop()
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// Bounded one-level navigation, including hidden files, without waiting for a global index.
    func children(of directory: URL, limit: Int = 500) throws -> [CommandFileSearchEntry] {
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
            entries.append(CommandFileSearchEntry(path: item.path, name: item.lastPathComponent, isDirectory: isDirectory))
        }
        if let enumerationError { throw enumerationError }
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
    }

    func shutdown() { stop() }

    private static func validDirectory(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix("/") && !url.path.contains("\0") && url.path.utf8.count <= 4_096
    }

    private func startIfNeeded() throws {
        if process?.isRunning == true { return }
        stop()
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw Failure.unavailable("The bundled filename search helper is missing. Rebuild or reinstall Spooky.")
        }
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        try CommandFileSearchPipe.configure(stdin.fileHandleForWriting)
        let outputReader = try CommandFileSearchReader(stdout.fileHandleForReading)
        let generation = UUID()
        process.executableURL = executableURL
        process.arguments = [indexDirectory.path]
        var environment = ProcessInfo.processInfo.environment
        environment["MallocSpaceEfficient"] = "1"
        environment["RAYON_NUM_THREADS"] = "2"
        environment["SPOOKY_FSEARCH_DIAGNOSTICS_PATH"] = diagnosticPath
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(32))
        outputReader.start(continuation)
        process.terminationHandler = { [weak self] _ in
            Task { await self?.terminated(generation) }
        }
        do { try process.run() } catch {
            outputReader.close()
            continuation.finish()
            throw Failure.unavailable("The filename search helper could not start: \(error.localizedDescription)")
        }
        self.process = process
        input = stdin.fileHandleForWriting
        self.outputReader = outputReader
        self.generation = generation
        streamContinuation = continuation
        reader = Task { [weak self] in
            for await bytes in stream {
                guard !Task.isCancelled else { return }
                await self?.receive(bytes, generation: generation)
            }
            await self?.terminated(generation)
        }
    }

    private func send(_ request: Request) throws {
        guard let input else { throw Failure.unavailable("Filename search is not running.") }
        var data = try JSONEncoder().encode(request)
        data.append(10)
        guard data.count <= 16_384 else { throw Failure.invalidRequest }
        try CommandFileSearchPipe.write(data, to: input)
    }

    private func receive(_ bytes: Data, generation: UUID) {
        guard self.generation == generation else { return }
        guard buffer.count + bytes.count <= 1_048_576 else { failAll(Failure.invalidResponse); stop(); return }
        buffer.append(bytes)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            do {
                let response = try Self.decodeResponse(line)
                if response.cancelled {
                    finish(response.id, result: .failure(CancellationError()))
                } else if let error = response.error {
                    let failure: Failure = error.hasPrefix("indexing:") ? .indexing(error) : .unavailable(error)
                    finish(response.id, result: .failure(failure))
                } else {
                    finish(response.id, result: .success(response))
                }
            } catch {
                failAll(Failure.invalidResponse)
                stop()
                return
            }
        }
    }

    static func decodeResponse(_ data: Data) throws -> Response {
        guard data.count <= 1_048_576 else { throw Failure.invalidResponse }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.entries.count <= 200, response.entries.allSatisfy({
            $0.path.hasPrefix("/") && !$0.path.contains("\0") && $0.path.utf8.count <= 4_096 &&
                !$0.name.isEmpty && !$0.name.contains("\0") && !$0.name.contains("/")
        }), Set(response.entries.map(\.path)).count == response.entries.count else { throw Failure.invalidResponse }
        return response
    }

    private func cancel(_ id: UUID) {
        guard pending[id] != nil else { return }
        do { try send(Request(id: id, op: "cancel")) } catch {
            stop()
            return
        }
        finish(id, result: .failure(CancellationError()))
    }

    private func expire(_ id: UUID) {
        guard pending[id] != nil else { return }
        finish(id, result: .failure(Failure.timedOut))
        do { try send(Request(id: id, op: "cancel")) } catch { stop() }
    }

    private func finish(_ id: UUID, result: Result<Response, Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(with: result)
    }

    private func failAll(_ error: Error) {
        for id in Array(pending.keys) { finish(id, result: .failure(error)) }
    }

    private func terminated(_ generation: UUID) {
        guard self.generation == generation else { return }
        failAll(Failure.unavailable("Filename search stopped. Try again to restart it."))
        stop()
    }

    private func stop() {
        generation = nil
        outputReader?.close()
        outputReader = nil
        streamContinuation?.finish()
        streamContinuation = nil
        reader?.cancel()
        reader = nil
        try? input?.close()
        input = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        buffer.removeAll(keepingCapacity: true)
        failAll(CancellationError())
    }
}

/// FileHandle.read(upToCount:) may wait to fill its requested length on a pipe.
/// Read one available chunk instead. The lock owns both reading and closure,
/// so an old readiness callback cannot consume a newly reused file descriptor.
private final class CommandFileSearchReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var closed = false

    init(_ handle: FileHandle) throws {
        self.handle = handle
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw CommandFileSearchService.Failure.unavailable("Could not configure filename search responses.")
        }
    }

    func start(_ continuation: AsyncStream<Data>.Continuation) {
        handle.readabilityHandler = { [weak self] _ in
            guard let self else { continuation.finish(); return }
            self.read(continuation)
        }
    }

    private func read(_ continuation: AsyncStream<Data>.Continuation) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        var bytes = Data(count: 65_536)
        let count = bytes.withUnsafeMutableBytes {
            Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count)
        }
        if count > 0 {
            bytes.count = count
            if case .dropped = continuation.yield(bytes) { continuation.finish() }
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            continuation.finish()
        }
    }

    func close() {
        handle.readabilityHandler = nil
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? handle.close()
    }
}

/// A stopped helper must never block the actor that owns cancellation and timeouts.
/// On any partial write/backpressure the caller retires the process: no later JSON
/// request can accidentally continue the truncated line.
enum CommandFileSearchPipe {
    static func configure(_ handle: FileHandle) throws {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw CommandFileSearchService.Failure.unavailable("Could not configure filename search transport.")
        }
    }

    static func write(_ data: Data, to handle: FileHandle) throws {
        try data.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(handle.fileDescriptor, address.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0 && errno == EINTR { continue }
                throw CommandFileSearchService.Failure.unavailable("Filename search is not responding. Try again to restart it.")
            }
        }
    }
}
