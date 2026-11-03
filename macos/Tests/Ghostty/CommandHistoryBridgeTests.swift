import Foundation
import Testing
@testable import Ghostty

struct CommandHistoryBridgeTests {
    @Test func requestContainsOnlyPromptAndIdentityWithoutSendingTheDraftToTheShell() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("ready\t123-1\tstart\t123-1\n", to: directory.appendingPathComponent("state"))
        let bridge = CommandHistoryBridge(directory: directory)
        let request = request(text: "printf 'café 👻'\ncat \"a file\"", revision: 7)

        try await bridge.prepare(request, generation: "123-1")

        let payload = try String(contentsOf: directory.appendingPathComponent("history-request"), encoding: .utf8)
        #expect(payload == "123-1\n\(request.id.uuidString)\n")
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("histories").path))
    }

    @Test func changedGenerationOrNonPrimaryPromptCannotReceiveHistoryRequest() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = CommandHistoryBridge(directory: directory)
        let request = request()
        for state in ["ready\t123-2\tstart\t123-2\n", "ready\t123-1\tcontinuation\t123-1\n",
                      "running\t123-1\tstart\t123-1\n"] {
            try write(state, to: directory.appendingPathComponent("state"))
            await #expect(throws: CommandHistoryBridge.HistoryError.promptChanged) {
                try await bridge.prepare(request, generation: "123-1")
            }
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("history-request").path))
        }
    }

    @Test func responsePreservesRecentFirstOrderDuplicatesAndExactCommandText() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = request(text: "unfinished 👻 draft", revision: 42)
        let entries = ["printf 'café 👻'\n\tcat \"a file\"  \n", "git status", "git status", "  echo oldest  "]
        let root = try responseDirectory(directory, request: request, entries: entries)

        let response = try #require(try await CommandHistoryBridge(directory: directory)
            .response(to: request, generation: "123-1"))

        #expect(response.requestID == request.id)
        #expect(response.revision == 42)
        #expect(response.entries == entries)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func absentResponseRemainsPendingAndEmptyHistoryIsACompleteResponse() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = CommandHistoryBridge(directory: directory)
        let request = request()
        #expect(try await bridge.response(to: request, generation: "123-1")?.requestID == nil)
        _ = try responseDirectory(directory, request: request, entries: [])

        let response = try #require(try await bridge.response(to: request, generation: "123-1"))

        #expect(response.requestID == request.id)
        #expect(response.entries.isEmpty)
    }

    @Test func responseRejectsMismatchedGenerationAndIdentifier() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = CommandHistoryBridge(directory: directory)
        let request = request()
        for (name, value) in [("generation", "123-2"), ("identifier", UUID().uuidString)] {
            let root = try responseDirectory(directory, request: request, entries: ["echo old prompt"])
            try write(value, to: root.appendingPathComponent(name))
            await #expect(throws: CommandHistoryBridge.HistoryError.invalidResponse) {
                try await bridge.response(to: request, generation: "123-1")
            }
            #expect(!FileManager.default.fileExists(atPath: root.path))
        }
    }

    @Test func rejectedHistoryReturnsAnExplanationWithoutExposingPayload() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = request()
        let root = try responseDirectory(directory, request: request, entries: ["must not be offered"])
        try write("rejected", to: root.appendingPathComponent("status"))
        try write("stale-generation", to: root.appendingPathComponent("reason"))

        let response = try #require(try await CommandHistoryBridge(directory: directory)
            .response(to: request, generation: "123-1"))

        #expect(response.entries.isEmpty)
        #expect(response.message?.isEmpty == false)
        #expect(response.requestID == request.id)
        #expect(response.revision == request.revision)
    }

    @Test func packedHistoryRejectsInvalidFramingUTF8AndTerminalControlCharacters() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = CommandHistoryBridge(directory: directory)
        let request = request()
        let malformed = [
            Data("echo unterminated".utf8), Data("echo one\0echo extra\0".utf8),
            Data("echo one\0trailing".utf8), Data([0xFF, 0]),
            Data("echo \u{1B}[31m\0".utf8), Data("echo \u{07}\0".utf8),
            Data("echo \r\0".utf8), Data("echo \u{7F}\0".utf8)
        ]
        for payload in malformed {
            let root = try responseDirectory(directory, request: request, entries: ["placeholder"])
            try payload.write(to: root.appendingPathComponent("items-v1"))
            await #expect(throws: CommandHistoryBridge.HistoryError.invalidResponse) {
                try await bridge.response(to: request, generation: "123-1")
            }
        }
        let root = try responseDirectory(directory, request: request, entries: [])
        try write("unexpected\0", to: root.appendingPathComponent("items-v1"))
        await #expect(throws: CommandHistoryBridge.HistoryError.invalidResponse) {
            try await bridge.response(to: request, generation: "123-1")
        }
    }

    @Test func responseValidatesBoundedMetadataAndAcceptsAnExplicitlyTruncatedSnapshot() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = CommandHistoryBridge(directory: directory)
        let request = request()
        let root = try responseDirectory(directory, request: request, entries: ["echo newest"])
        try write("1", to: root.appendingPathComponent("truncated"))
        let truncated = try #require(try await bridge.response(to: request, generation: "123-1"))
        #expect(truncated.entries == ["echo newest"])

        for (name, value) in [("truncated", "2"), ("truncated", ""), ("status", "unknown"),
                              ("identifier", String(repeating: "x", count: 4097))] {
            let root = try responseDirectory(directory, request: request, entries: ["echo newest"])
            try write(value, to: root.appendingPathComponent(name))
            await #expect(throws: CommandHistoryBridge.HistoryError.invalidResponse) {
                try await bridge.response(to: request, generation: "123-1")
            }
        }
    }

    @Test func historyBoundsAcceptTheLimitAndRejectExcessCountOrPayload() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = CommandHistoryBridge(directory: directory)
        let request = request()
        let entries = (0..<1_000).map { "echo \($0)" }
        _ = try responseDirectory(directory, request: request, entries: entries)
        let bounded = try #require(try await bridge.response(to: request, generation: "123-1"))
        #expect(bounded.entries == entries)

        let largest = String(repeating: "x", count: 1_048_575)
        _ = try responseDirectory(directory, request: request, entries: [largest])
        let fullPayload = try #require(try await bridge.response(to: request, generation: "123-1"))
        #expect(fullPayload.entries == [largest])

        for count in ["-1", "1001", "not-a-number"] {
            let root = try responseDirectory(directory, request: request, entries: [])
            try write(count, to: root.appendingPathComponent("count"))
            await #expect(throws: CommandHistoryBridge.HistoryError.invalidResponse) {
                try await bridge.response(to: request, generation: "123-1")
            }
        }
        _ = try responseDirectory(directory, request: request, entries: [largest + "x"])
        await #expect(throws: CommandHistoryBridge.HistoryError.invalidResponse) {
            try await bridge.response(to: request, generation: "123-1")
        }
    }

    @Test func directoryPublicationWakesHistoryWaitAndPreservesAnUnrelatedResponse() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = CommandHistoryBridge(directory: directory)
        let request = request(revision: 8)
        let entries = ["echo 👻", "printf 'line one\nline two'"]
        let final = try responseDirectory(directory, request: request, entries: entries)
        let staging = final.deletingLastPathComponent().appendingPathComponent(".pending-\(request.id.uuidString)")
        try FileManager.default.moveItem(at: final, to: staging)
        let unrelated = try responseDirectory(directory, request: self.request(), entries: ["other pane request"])
        let waiting = Task { try await bridge.waitForResponse(to: request, generation: "123-1") }
        defer { waiting.cancel() }
        try await Task.sleep(for: .milliseconds(20))

        try FileManager.default.moveItem(at: staging, to: final)
        let response = try await waiting.value

        #expect(response.requestID == request.id)
        #expect(response.revision == 8)
        #expect(response.entries == entries)
        #expect(!FileManager.default.fileExists(atPath: final.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func cancellingAnOldWaitCannotRemoveTheNewRequestOrResponse() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("ready\t123-1\tstart\t123-1\n", to: directory.appendingPathComponent("state"))
        let bridge = CommandHistoryBridge(directory: directory)
        let old = request(text: "old", revision: 1)
        try await bridge.prepare(old, generation: "123-1")
        let waiting = Task { try await bridge.waitForResponse(to: old, generation: "123-1") }
        try await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        let next = request(text: "new draft", revision: 2)
        try await bridge.prepare(next, generation: "123-1")
        let root = try responseDirectory(directory, request: next, entries: ["echo newest"])
        let late = try responseDirectory(directory, request: old, entries: ["echo stale"])

        await bridge.cancel(old.id)

        let payload = try String(contentsOf: directory.appendingPathComponent("history-request"), encoding: .utf8)
        #expect(payload == "123-1\n\(next.id.uuidString)\n")
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(!FileManager.default.fileExists(atPath: late.path))
        let response = try await bridge.waitForResponse(to: next, generation: "123-1")
        #expect(response.requestID == next.id)
        #expect(response.entries == ["echo newest"])
    }

    @Test func cancelledPreparationCannotOverwriteTheNewestHistoryRequest() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("ready\t123-1\tstart\t123-1\n", to: directory.appendingPathComponent("state"))
        let bridge = CommandHistoryBridge(directory: directory)
        let old = request(text: "old", revision: 1)
        let next = request(text: "new", revision: 2)
        try await bridge.prepare(next, generation: "123-1")
        let gate = AsyncStream<Void>.makeStream()
        let obsolete = Task {
            for await _ in gate.stream { break }
            try await bridge.prepare(old, generation: "123-1")
        }
        obsolete.cancel()
        gate.continuation.finish()

        await #expect(throws: CancellationError.self) { try await obsolete.value }

        let payload = try String(contentsOf: directory.appendingPathComponent("history-request"), encoding: .utf8)
        #expect(payload == "123-1\n\(next.id.uuidString)\n")
    }

    @Test func historyWaitHasABoundedDeadline() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = CommandHistoryBridge(directory: directory)
        let request = request()
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("histories"),
                                                withIntermediateDirectories: true)

        await #expect(throws: CommandHistoryBridge.HistoryError.timedOut) {
            try await bridge.waitForResponse(to: request, generation: "123-1", timeout: .milliseconds(20))
        }
    }

    private func request(text: String = "", revision: UInt64 = 1) -> CommandHistoryRequest {
        .init(id: UUID(), revision: revision, text: text, cursorUTF16: text.utf16.count)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func responseDirectory(_ directory: URL, request: CommandHistoryRequest,
                                   entries: [String]) throws -> URL {
        let root = directory.appendingPathComponent("histories/\(request.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, value) in [("generation", "123-1"), ("identifier", request.id.uuidString),
                              ("status", "ok"), ("count", String(entries.count)), ("truncated", "0")] {
            try write(value, to: root.appendingPathComponent(name))
        }
        let packed = entries.map { $0 + "\0" }.joined()
        try write(packed, to: root.appendingPathComponent("items-v1"))
        return root
    }

    private func write(_ value: String, to url: URL) throws {
        try Data(value.utf8).write(to: url)
    }
}
