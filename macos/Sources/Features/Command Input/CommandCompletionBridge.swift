import Foundation

/// Completion runs in a prompt-time worker fork of the executing shell. Files
/// carry data only; ZLE never accepts the command. Filesystem work stays off MainActor.
actor CommandCompletionBridge {
    private let directory: URL
    private static let maximumDraftBytes = 1_048_576
    private static let maximumResponseBytes = 8_388_608

    init(directory: URL) { self.directory = directory }

    func prepare(_ request: CommandCompletionRequest, generation: String) throws {
        guard request.text.utf8.count <= Self.maximumDraftBytes,
              !request.text.unicodeScalars.contains(where: {
                  ($0.value < 32 && $0.value != 9 && $0.value != 10) || $0.value == 127
              }), let caret = Self.byteOffset(in: request.text, cursorUTF16: request.cursorUTF16) else {
            throw CompletionError.invalidRequest
        }
        let state = try read(directory.appendingPathComponent("state"), maximum: 4096)
            .trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        guard state.count == 4, Array(state.prefix(3)) == ["ready", generation, "start"] else {
            throw CompletionError.promptChanged
        }
        pruneResponses(except: request.id)
        let payload = "\(generation)\n\(request.id.uuidString)\n\(caret)\n\(request.text)"
        try Data(payload.utf8).write(to: directory.appendingPathComponent("completion-request"), options: .atomic)
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
        var seen: Set<String> = []
        var bytes = 0
        for index in 0..<count {
            let item = root.appendingPathComponent("items/\(index + 1)", isDirectory: true)
            let buffer = try read(item.appendingPathComponent("buffer"), maximum: Self.maximumDraftBytes)
            bytes += buffer.utf8.count
            guard bytes <= Self.maximumResponseBytes,
                  let caret = Int(try field(item, "cursor")),
                  let cursorUTF16 = Self.utf16Offset(in: buffer, byteOffset: caret) else {
                throw CompletionError.invalidResponse
            }
            guard seen.insert(buffer).inserted else { continue }
            items.append(.init(displayText: CommandCompletionToken.label(
                result: buffer, cursorUTF16: cursorUTF16, request: request
            ), detail: "",
                               replacementText: buffer,
                               replacementRange: NSRange(location: 0, length: request.text.utf16.count),
                               cursorUTF16: cursorUTF16))
        }
        return .init(requestID: request.id, revision: request.revision, items: items,
                     message: items.isEmpty ? "No completions" : nil)
    }

    func cancel(_ identifier: UUID) {
        let request = directory.appendingPathComponent("completion-request")
        if let contents = try? read(request, maximum: Self.maximumDraftBytes + 512),
           contents.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).dropFirst().first
            == Substring(identifier.uuidString) {
            try? FileManager.default.removeItem(at: request)
        }
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

    private func read(_ url: URL, maximum: Int) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= maximum,
              let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
            throw CompletionError.invalidResponse
        }
        return text
    }

    enum CompletionError: LocalizedError {
        case invalidRequest, promptChanged, invalidResponse
        var errorDescription: String? {
            switch self {
            case .invalidRequest: return "Completion requires valid UTF-8 text and a valid insertion point."
            case .promptChanged: return "The shell is no longer at the same empty prompt."
            case .invalidResponse: return "The shell returned an invalid completion response."
            }
        }
    }
}
