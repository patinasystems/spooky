import Foundation

/// Reads a bounded snapshot from the live shell only when history is requested.
/// History files stay in the private per-pane bridge and never enter the PTY.
actor CommandHistoryBridge {
    private let directory: URL
    private static let maximumBytes = 1_048_576
    private static let maximumEntries = 1_000

    init(directory: URL) { self.directory = directory }

    func prepare(_ request: CommandHistoryRequest, generation: String) throws {
        try Task.checkCancellation()
        let state = try read(directory.appendingPathComponent("state"), maximum: 4096)
            .trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        guard !generation.isEmpty, !generation.contains("\n"), state.count == 4,
              Array(state.prefix(3)) == ["ready", generation, "start"] else { throw HistoryError.promptChanged }
        let responses = directory.appendingPathComponent("histories", isDirectory: true)
        try FileManager.default.createDirectory(at: responses, withIntermediateDirectories: true)
        for url in try FileManager.default.contentsOfDirectory(at: responses, includingPropertiesForKeys: nil) {
            guard let identifier = UUID(uuidString: url.lastPathComponent), identifier != request.id else { continue }
            try? FileManager.default.removeItem(at: url)
        }
        try Task.checkCancellation()
        try Data("\(generation)\n\(request.id.uuidString)\n".utf8)
            .write(to: directory.appendingPathComponent("history-request"), options: .atomic)
    }

    func waitForResponse(to request: CommandHistoryRequest, generation: String,
                         timeout: Duration = .seconds(3)) async throws -> CommandHistoryResponse {
        try Task.checkCancellation()
        if let response = try response(to: request, generation: generation) { return response }
        let events = CommandInputFileEvents(directory: directory.appendingPathComponent("histories", isDirectory: true))
        return try await withThrowingTaskGroup(of: CommandHistoryResponse.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                for await _ in events.events {
                    try Task.checkCancellation()
                    if let response = try await self.response(to: request, generation: generation) { return response }
                }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw HistoryError.timedOut
            }
            guard let response = try await group.next() else { throw CancellationError() }
            return response
        }
    }

    func response(to request: CommandHistoryRequest, generation: String) throws -> CommandHistoryResponse? {
        let root = responseDirectory(request.id)
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        defer { try? FileManager.default.removeItem(at: root) }
        guard try field(root, "identifier") == request.id.uuidString,
              try field(root, "generation") == generation else { throw HistoryError.invalidResponse }
        let status = try field(root, "status")
        if status == "rejected" {
            return .init(requestID: request.id, revision: request.revision, entries: [],
                         message: "Shell history is unavailable at this prompt. Try Up again.")
        }
        let truncated = try field(root, "truncated")
        guard status == "ok", truncated == "0" || truncated == "1", let count = Int(try field(root, "count")),
              (0...Self.maximumEntries).contains(count) else { throw HistoryError.invalidResponse }
        let payload = try read(root.appendingPathComponent("items-v1"), maximum: Self.maximumBytes)
        let fields = payload.split(separator: "\0", maxSplits: count, omittingEmptySubsequences: false)
        guard fields.count == count + 1, fields.last?.isEmpty == true else { throw HistoryError.invalidResponse }
        let entries = try fields.dropLast().map { field in
            guard !field.isEmpty, !field.unicodeScalars.contains(where: {
                ($0.value < 32 && $0.value != 9 && $0.value != 10) || $0.value == 127
            }) else { throw HistoryError.invalidResponse }
            return String(field)
        }
        return .init(requestID: request.id, revision: request.revision, entries: entries)
    }

    func cancel(_ identifier: UUID) {
        let request = directory.appendingPathComponent("history-request")
        if let contents = try? read(request, maximum: 512),
           contents.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().first
            == Substring(identifier.uuidString) {
            try? FileManager.default.removeItem(at: request)
        }
        try? FileManager.default.removeItem(at: responseDirectory(identifier))
    }

    private func responseDirectory(_ identifier: UUID) -> URL {
        directory.appendingPathComponent("histories/\(identifier.uuidString)", isDirectory: true)
    }

    private func field(_ root: URL, _ name: String) throws -> String {
        try read(root.appendingPathComponent(name), maximum: 4096).trimmingCharacters(in: .newlines)
    }

    private func read(_ url: URL, maximum: Int) throws -> String {
        // A capped read also bounds allocation if a file changes after opening.
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum, let text = String(data: data, encoding: .utf8) else {
            throw HistoryError.invalidResponse
        }
        return text
    }

    enum HistoryError: LocalizedError, Equatable {
        case promptChanged, invalidResponse, timedOut

        var errorDescription: String? {
            switch self {
            case .promptChanged: return "The shell is no longer at the same empty prompt."
            case .invalidResponse: return "The shell returned an invalid history response."
            case .timedOut: return "History timed out. Press Up to try again."
            }
        }
    }
}
