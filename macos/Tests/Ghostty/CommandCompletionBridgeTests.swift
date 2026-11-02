import Foundation
import Testing
@testable import Ghostty

struct CommandCompletionBridgeTests {
    @Test func caretOffsetsRespectUnicodeEncodingBoundaries() {
        let text = "echo 👩🏽‍💻 café"
        let prefix = "echo 👩🏽‍💻 "
        #expect(CommandCompletionBridge.byteOffset(in: text, cursorUTF16: prefix.utf16.count) == prefix.utf8.count)
        #expect(CommandCompletionBridge.utf16Offset(in: text, byteOffset: prefix.utf8.count) == prefix.utf16.count)
        #expect(CommandCompletionBridge.byteOffset(in: text, cursorUTF16: 6) == nil)
        #expect(CommandCompletionBridge.utf16Offset(in: text, byteOffset: 6) == nil)
        #expect(CommandCompletionBridge.byteOffset(in: text, cursorUTF16: -1) == nil)
    }

    @Test func requestPreservesMultilineDraftAndUsesByteOffset() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("ready\t123-1\tstart\t123-1\n", to: directory.appendingPathComponent("state"))
        let bridge = CommandCompletionBridge(directory: directory)
        let prefix = "echo café\ncat "
        let request = CommandCompletionRequest(id: UUID(), revision: 7, text: prefix + "do", cursorUTF16: prefix.utf16.count + 2)
        try await bridge.prepare(request, generation: "123-1")
        let payload = try String(contentsOf: directory.appendingPathComponent("completion-request"), encoding: .utf8)
        #expect(payload == "123-1\n\(request.id.uuidString)\n\(request.text.utf8.count)\n\(request.text)")
    }

    @Test func changedPromptCannotReceiveCompletionRequest() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("ready\t123-2\tstart\t123-2\n", to: directory.appendingPathComponent("state"))
        let bridge = CommandCompletionBridge(directory: directory)
        let request = CommandCompletionRequest(id: UUID(), revision: 1, text: "cat do", cursorUTF16: 6)
        await #expect(throws: CommandCompletionBridge.CompletionError.self) {
            try await bridge.prepare(request, generation: "123-1")
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("completion-request").path))
    }

    @Test func nextRequestPrunesLateCancelledResponsesButPreservesCurrentAndStaging() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("ready\t123-1\tstart\t123-1\n", to: directory.appendingPathComponent("state"))
        let bridge = CommandCompletionBridge(directory: directory)
        let cancelled = CommandCompletionRequest(id: UUID(), revision: 1, text: "cat a", cursorUTF16: 5)
        try await bridge.prepare(cancelled, generation: "123-1")
        await bridge.cancel(cancelled.id)
        let late = try responseDirectory(directory, request: cancelled, generation: "123-1")
        let next = CommandCompletionRequest(id: UUID(), revision: 2, text: "cat b", cursorUTF16: 5)
        let current = try responseDirectory(directory, request: next, generation: "123-1")
        let staging = directory.appendingPathComponent("completions/.pending-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)

        try await bridge.prepare(next, generation: "123-1")

        #expect(!FileManager.default.fileExists(atPath: late.path))
        #expect(FileManager.default.fileExists(atPath: current.path))
        #expect(FileManager.default.fileExists(atPath: staging.path))
        let payload = try String(contentsOf: directory.appendingPathComponent("completion-request"), encoding: .utf8)
        #expect(payload.hasPrefix("123-1\n\(next.id.uuidString)\n"))
    }

    @Test func responseKeepsShellQuotingAndMiddleCaret() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = CommandCompletionRequest(id: UUID(), revision: 9, text: "cat ca tail", cursorUTF16: 6)
        let root = try responseDirectory(directory, request: request, generation: "123-1")
        try write("1", to: root.appendingPathComponent("count"))
        let result = "cat café\\ folder/ tail"
        let prefix = "cat café\\ folder/"
        try write(result, to: root.appendingPathComponent("items/1/buffer"))
        try write("\(prefix.utf8.count)", to: root.appendingPathComponent("items/1/cursor"))
        let response = try #require(try await CommandCompletionBridge(directory: directory).response(to: request, generation: "123-1"))
        let candidate = try #require(response.items.first)
        #expect(response.requestID == request.id)
        #expect(response.revision == request.revision)
        #expect(candidate.replacementText == result)
        #expect(candidate.replacementRange == NSRange(location: 0, length: request.text.utf16.count))
        #expect(candidate.cursorUTF16 == prefix.utf16.count)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func responseRejectsMismatchedIdentityAndBadCaret() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = CommandCompletionRequest(id: UUID(), revision: 1, text: "cat ", cursorUTF16: 4)
        let root = try responseDirectory(directory, request: request, generation: "wrong")
        let bridge = CommandCompletionBridge(directory: directory)
        await #expect(throws: CommandCompletionBridge.CompletionError.self) {
            try await bridge.response(to: request, generation: "123-1")
        }
        _ = try responseDirectory(directory, request: request, generation: "123-1")
        try write("1", to: root.appendingPathComponent("count"))
        try write("cat 👋", to: root.appendingPathComponent("items/1/buffer"))
        try write("5", to: root.appendingPathComponent("items/1/cursor"))
        await #expect(throws: CommandCompletionBridge.CompletionError.self) {
            try await bridge.response(to: request, generation: "123-1")
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func responseDirectory(_ directory: URL, request: CommandCompletionRequest, generation: String) throws -> URL {
        let root = directory.appendingPathComponent("completions/\(request.id.uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("items/1"), withIntermediateDirectories: true)
        try write(request.id.uuidString, to: root.appendingPathComponent("identifier"))
        try write(generation, to: root.appendingPathComponent("generation"))
        try write("ok", to: root.appendingPathComponent("status"))
        return root
    }

    private func write(_ value: String, to url: URL) throws {
        try Data(value.utf8).write(to: url)
    }
}
