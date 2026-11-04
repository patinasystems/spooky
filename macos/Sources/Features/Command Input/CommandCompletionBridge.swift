import Foundation

/// Completion runs in a prompt-time worker fork of the executing shell. Files
/// carry data only; ZLE never accepts the command. Filesystem work stays off MainActor.
actor CommandCompletionBridge {
    private let directory: URL
    private static let maximumDraftBytes = 1_048_576
    private static let maximumResponseBytes = 8_388_608

    init(directory: URL) { self.directory = directory }

    func prepare(_ request: CommandCompletionRequest, generation: String) throws {
        try Task.checkCancellation()
        guard Self.validText(request.text), Self.validText(request.shellText),
              Self.byteOffset(in: request.text, cursorUTF16: request.cursorUTF16) != nil,
              let caret = Self.byteOffset(in: request.shellText, cursorUTF16: request.shellCursorUTF16) else {
            throw CompletionError.invalidRequest
        }
        let state = try read(directory.appendingPathComponent("state"), maximum: 4096)
        guard CommandShellBridgeFiles.isReady(state, generation: generation) else {
            throw CompletionError.promptChanged
        }
        pruneResponses(except: request.id)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("completions", isDirectory: true), withIntermediateDirectories: true)
        try Task.checkCancellation()
        let payload = "\(generation)\n\(request.id.uuidString)\n\(caret)\n\(request.shellText)"
        try Data(payload.utf8).write(to: directory.appendingPathComponent("completion-request"), options: .atomic)
    }

    /// Directory notifications observe the worker's atomic response rename.
    /// Check immediately as well: completion may finish before the watch is
    /// installed. Cancellation tears down both the watch and deadline task.
    func waitForResponse(to request: CommandCompletionRequest, generation: String,
                         timeout: Duration = .seconds(3)) async throws -> CommandCompletionResponse {
        try Task.checkCancellation()
        if let response = try response(to: request, generation: generation) { return response }
        let events = CommandInputFileEvents(
            directory: directory.appendingPathComponent("completions", isDirectory: true), scope: .response)
        return try await withThrowingTaskGroup(of: CommandCompletionResponse.self) { group in
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
                throw CompletionError.timedOut
            }
            guard let response = try await group.next() else { throw CancellationError() }
            return response
        }
    }

    func response(to request: CommandCompletionRequest, generation: String) throws -> CommandCompletionResponse? {
        let root = responseDirectory(request.id)
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        defer { try? FileManager.default.removeItem(at: root) }
        guard try field(root, "identifier") == request.id.uuidString,
              try field(root, "generation") == generation else { throw CompletionError.invalidResponse }
        let status = try field(root, "status")
        if status == "rejected" {
            let reason = (try? field(root, "reason")) ?? "unavailable"
            return .init(requestID: request.id, revision: request.revision, items: [], message: Self.explanation(reason))
        }
        guard status == "ok", let count = Int(try field(root, "count")), (0...200).contains(count) else {
            throw CompletionError.invalidResponse
        }
        var items: [CommandCompletionCandidate] = []
        // Hints are advisory; malformed/oversized metadata must not discard a
        // valid shell-owned insertion. The read still has a strict byte cap.
        var metadata = CommandCompletionMetadata(specs: (try? specifications(root)) ?? [], request: request)
        var seen: Set<String> = []
        var bytes = 0
        let records = try buffers(root, count: count)
        let labels = records.map { CommandCompletionToken.label(
            result: $0.0, cursorUTF16: Self.utf16Offset(in: $0.0, byteOffset: $0.1) ?? 0, request: request) }
        if metadata.needsGitManual(for: labels),
           let path = try? field(root, "git-manual"), path.hasPrefix("/"), path.hasSuffix(".1"),
           let manual = try? read(URL(fileURLWithPath: path), maximum: 1_048_576) {
            metadata.addGitManual(manual, matching: labels)
        }
        for ((buffer, caret), label) in zip(records, labels) {
            bytes += buffer.utf8.count
            guard buffer.utf8.count <= Self.maximumDraftBytes, bytes <= Self.maximumResponseBytes,
                  let cursorUTF16 = Self.utf16Offset(in: buffer, byteOffset: caret) else {
                throw CompletionError.invalidResponse
            }
            guard seen.insert(buffer).inserted else { continue }
            items.append(.init(displayText: label, detail: metadata.detail(for: label),
                               replacementText: buffer,
                               replacementRange: NSRange(location: 0, length: request.text.utf16.count),
                               cursorUTF16: cursorUTF16))
        }
        return .init(requestID: request.id, revision: request.revision, items: items,
                     message: items.isEmpty ? "No completions" : nil)
    }

    func cancel(_ identifier: UUID) {
        CommandShellBridgeFiles.removeRequest(directory.appendingPathComponent("completion-request"),
                                              matching: identifier, maximum: Self.maximumDraftBytes + 512)
        try? FileManager.default.removeItem(at: responseDirectory(identifier))
    }

    static func byteOffset(in text: String, cursorUTF16: Int) -> Int? {
        guard cursorUTF16 >= 0, cursorUTF16 <= text.utf16.count else { return nil }
        let offset = text.utf16.index(text.utf16.startIndex, offsetBy: cursorUTF16)
        guard let index = String.Index(offset, within: text) else { return nil }
        return text[..<index].utf8.count
    }

    static func utf16Offset(in text: String, byteOffset: Int) -> Int? {
        guard byteOffset >= 0, byteOffset <= text.utf8.count else { return nil }
        let offset = text.utf8.index(text.utf8.startIndex, offsetBy: byteOffset)
        guard let index = String.Index(offset, within: text) else { return nil }
        return text[..<index].utf16.count
    }

    private static func explanation(_ reason: String) -> String {
        if reason.contains("unsafe") || reason.contains("expansion") || reason.contains("dynamic") {
            return "Use terminal completion for command substitutions and dynamic expansions."
        }
        if reason.contains("stale") || reason.contains("ready") {
            return "The shell prompt changed. Press Tab to try again."
        }
        return "Shell completion unavailable (\(reason)). Escape returns to terminal input."
    }

    private func responseDirectory(_ identifier: UUID) -> URL {
        directory.appendingPathComponent("completions/\(identifier.uuidString)", isDirectory: true)
    }

    private func specifications(_ root: URL) throws -> [String] {
        let file = root.appendingPathComponent("specs-v1")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let text = try read(file, maximum: 131_072)
        let parts = text.split(separator: "\0", maxSplits: 1024, omittingEmptySubsequences: false)
        guard parts.count <= 1025, parts.last?.isEmpty == true else { throw CompletionError.invalidResponse }
        return parts.dropLast().map(String.init)
    }

    private func pruneResponses(except identifier: UUID) {
        let root = directory.appendingPathComponent("completions", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for entry in entries {
            // Cancellation may precede the worker's atomic publication. The next
            // request reclaims those late results without touching active staging.
            guard let responseID = UUID(uuidString: entry.lastPathComponent), responseID != identifier,
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private func field(_ root: URL, _ name: String) throws -> String {
        try read(root.appendingPathComponent(name), maximum: 4096).trimmingCharacters(in: .newlines)
    }

    private func buffers(_ root: URL, count: Int) throws -> [(String, Int)] {
        let packed = root.appendingPathComponent("items-v1")
        if FileManager.default.fileExists(atPath: packed.path) {
            // cursor NUL exact UTF-8 buffer NUL, repeated count times. Bound
            // both bytes and split count before allocating individual records.
            let text = try read(packed, maximum: Self.maximumResponseBytes + 200 * 32)
            let fields = text.split(separator: "\0", maxSplits: count * 2, omittingEmptySubsequences: false)
            guard fields.count == count * 2 + 1, fields.last?.isEmpty == true else {
                throw CompletionError.invalidResponse
            }
            return try (0..<count).map { index in
                let cursor = fields[index * 2]
                guard !cursor.isEmpty, cursor.utf8.count <= 7,
                      cursor.utf8.allSatisfy({ (48...57).contains($0) }), let offset = Int(cursor) else {
                    throw CompletionError.invalidResponse
                }
                let buffer = String(fields[index * 2 + 1])
                guard buffer.utf8.count <= Self.maximumDraftBytes else { throw CompletionError.invalidResponse }
                return (buffer, offset)
            }
        }
        // Keep the original representation readable for existing workers and
        // fixtures; new workers publish one bounded payload instead of hundreds
        // of tiny files and directories.
        var bytes = 0
        return try (0..<count).map { index in
            let item = root.appendingPathComponent("items/\(index + 1)", isDirectory: true)
            guard let cursor = Int(try field(item, "cursor")) else { throw CompletionError.invalidResponse }
            let buffer = try read(item.appendingPathComponent("buffer"), maximum: Self.maximumDraftBytes)
            bytes += buffer.utf8.count
            guard bytes <= Self.maximumResponseBytes else { throw CompletionError.invalidResponse }
            return (buffer, cursor)
        }
    }

    private static func validText(_ text: String) -> Bool {
        text.utf8.count <= maximumDraftBytes && !text.unicodeScalars.contains(where: {
            ($0.value < 32 && $0.value != 9 && $0.value != 10) || $0.value == 127
        })
    }

    private func read(_ url: URL, maximum: Int) throws -> String {
        try CommandShellBridgeFiles.readUTF8(url, maximum: maximum, invalidResponse: CompletionError.invalidResponse)
    }

    enum CompletionError: LocalizedError {
        case invalidRequest, promptChanged, invalidResponse, timedOut
        var errorDescription: String? {
            switch self {
            case .invalidRequest: return "Completion requires valid UTF-8 text and a valid insertion point."
            case .promptChanged: return "The shell is no longer at the same empty prompt."
            case .invalidResponse: return "The shell returned an invalid completion response."
            case .timedOut: return "Completion timed out. Press Tab to try again."
            }
        }
    }
}
