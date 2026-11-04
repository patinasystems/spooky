import Foundation

/// Synchronous file primitives called from the independent shell bridge actors.
/// Sharing parsing does not serialize completion and history behind one worker.
enum CommandShellBridgeFiles {
    static func isReady(_ state: String, generation: String) -> Bool {
        let fields = state.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        return !generation.isEmpty && !generation.contains("\n") && fields.count == 4
            && fields[0] == "ready" && fields[1] == generation && fields[2] == "start"
    }

    static func readUTF8(_ url: URL, maximum: Int, invalidResponse: any Error) throws -> String {
        guard maximum >= 0, maximum < Int.max else { throw invalidResponse }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        // Cap the actual read, not a preceding stat: the file can grow between
        // those operations. One extra byte distinguishes exactly-at-limit data.
        let data = try file.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum, let text = String(data: data, encoding: .utf8) else { throw invalidResponse }
        return text
    }

    static func removeRequest(_ url: URL, matching identifier: UUID, maximum: Int) {
        guard let contents = try? readUTF8(url, maximum: maximum,
                                          invalidResponse: CocoaError(.fileReadCorruptFile)),
              contents.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).dropFirst().first
                == Substring(identifier.uuidString) else { return }
        // The owning actor serializes preparation and cancellation. An older
        // cancelled request must never remove the next request's publication.
        try? FileManager.default.removeItem(at: url)
    }
}
