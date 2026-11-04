import Foundation
import Testing
@testable import Ghostty

struct CommandCompletionBridgeTests {
    @Test func evaluatedOptionSpecsProvideDescriptionsAndExpectedValues() {
        let request = CommandCompletionRequest(id: UUID(), revision: 1, text: "tool --fo", cursorUTF16: 9)
        let specs = ["(--old)*--format=[output format]:format:(json yaml)", "-a[all entries]", "-l[long format]",
                     "--file=[read \\[input\\]]:input file:_files", "--broken[unfinished"]
        let metadata = CommandCompletionMetadata(specs: specs, request: request)
        #expect(metadata.detail(for: "--format=") == "⟨format: json | yaml⟩  output format")
        #expect(metadata.detail(for: "-al") == "long format")
        #expect(metadata.detail(for: "--file=") == "⟨input file⟩  read [input]")
        #expect(metadata.detail(for: "--broken") == "")
        let values = CommandCompletionMetadata(specs: specs, request:
            .init(id: UUID(), revision: 2, text: "tool --format j", cursorUTF16: 15))
        #expect(values.detail(for: "json") == "⟨format: json | yaml⟩")
    }

    @Test func responseCarriesMetadataWithoutChangingShellReplacement() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = CommandCompletionRequest(id: UUID(), revision: 1, text: "tool --fo", cursorUTF16: 9)
        let root = try responseDirectory(directory, request: request, generation: "123-1")
        try write("1", to: root.appendingPathComponent("count"))
        try write("14\0tool --format=\0", to: root.appendingPathComponent("items-v1"))
        try write("--format=[output format]:format:(json yaml)\0", to: root.appendingPathComponent("specs-v1"))
        let bridge = CommandCompletionBridge(directory: directory)
        let response = try await bridge.response(to: request, generation: "123-1")
        let item = try #require(response?.items.first)
        #expect(item.detail == "⟨format: json | yaml⟩  output format")
        #expect(item.replacementText == "tool --format=")
        #expect(item.cursorUTF16 == 14)
    }

    @Test func malformedMetadataDoesNotDiscardValidCompletionBytes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = CommandCompletionRequest(id: UUID(), revision: 1, text: "tool --fo", cursorUTF16: 9)
        let root = try responseDirectory(directory, request: request, generation: "123-1")
        try write("1", to: root.appendingPathComponent("count"))
        try write("14\0tool --format=\0", to: root.appendingPathComponent("items-v1"))
        try write(String(repeating: "x", count: 131_073), to: root.appendingPathComponent("specs-v1"))
        let bridge = CommandCompletionBridge(directory: directory)
        let response = try await bridge.response(to: request, generation: "123-1")
        #expect(response?.items.first?.replacementText == "tool --format=")
        #expect(response?.items.first?.detail == "")
    }

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

    @Test func broadenedQueryUsesItsOwnCaretButReplacesTheOriginalDraft() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("ready\t123-1\tstart\t123-1\n", to: directory.appendingPathComponent("state"))
        let bridge = CommandCompletionBridge(directory: directory)
        let draft = "echo café\ngit ckout --help"
        let query = "echo café\ngit  --help"
        let queryPrefix = "echo café\ngit "
        let request = CommandCompletionRequest(
            id: UUID(), revision: 8, text: draft, cursorUTF16: "echo café\ngit ckout".utf16.count,
            automatic: true, queryText: query, queryCursorUTF16: queryPrefix.utf16.count)
        try await bridge.prepare(request, generation: "123-1")
        let payload = try String(contentsOf: directory.appendingPathComponent("completion-request"), encoding: .utf8)
        #expect(payload == "123-1\n\(request.id.uuidString)\n\(queryPrefix.utf8.count)\n\(query)")
        let root = try responseDirectory(directory, request: request, generation: "123-1")
        try write("1", to: root.appendingPathComponent("count"))
        let result = "echo café\ngit checkout --help"
        try write(result, to: root.appendingPathComponent("items/1/buffer"))
        try write("\("echo café\ngit checkout".utf8.count)", to: root.appendingPathComponent("items/1/cursor"))
        let response = try await bridge.waitForResponse(to: request, generation: "123-1")
        let candidate = try #require(response.items.first)
        #expect(candidate.replacementText == result)
        #expect(candidate.replacementRange == NSRange(location: 0, length: draft.utf16.count))
        #expect(candidate.displayText == "checkout")
        #expect(response.revision == request.revision)
    }

    @Test func directoryPublicationWakesCompletionWaitWithoutPolling() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = CommandCompletionBridge(directory: directory)
        let request = CommandCompletionRequest(id: UUID(), revision: 1, text: "git ", cursorUTF16: 4)
        let final = try responseDirectory(directory, request: request, generation: "123-1")
        try write("0", to: final.appendingPathComponent("count"))
        let staging = final.deletingLastPathComponent().appendingPathComponent(".pending-\(request.id.uuidString)")
        try FileManager.default.moveItem(at: final, to: staging)
        let waiting = Task { try await bridge.waitForResponse(to: request, generation: "123-1") }
        try await Task.sleep(for: .milliseconds(20))
        try FileManager.default.moveItem(at: staging, to: final)
        let response = try await waiting.value
        #expect(response.requestID == request.id)
        #expect(response.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: final.path))
    }

    @Test func broadenedQueryCannotBypassTextOrCaretValidation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("ready\t123-1\tstart\t123-1\n", to: directory.appendingPathComponent("state"))
        let bridge = CommandCompletionBridge(directory: directory)
        for (query, caret) in [("cat \0", 4), ("cat 👋", 5)] {
            let request = CommandCompletionRequest(id: UUID(), revision: 1, text: "cat a", cursorUTF16: 5,
                                                   automatic: true, queryText: query, queryCursorUTF16: caret)
            await #expect(throws: CommandCompletionBridge.CompletionError.self) {
                try await bridge.prepare(request, generation: "123-1")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("completion-request").path))
    }

    @Test func cancellingAWaitCannotRemoveTheNextRequestOrResponse() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("ready\t123-1\tstart\t123-1\n", to: directory.appendingPathComponent("state"))
        let bridge = CommandCompletionBridge(directory: directory)
        let first = CommandCompletionRequest(id: UUID(), revision: 1, text: "git c", cursorUTF16: 5)
        try await bridge.prepare(first, generation: "123-1")
        let waiting = Task { try await bridge.waitForResponse(to: first, generation: "123-1") }
        try await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        let next = CommandCompletionRequest(id: UUID(), revision: 2, text: "git ch", cursorUTF16: 6)
        try await bridge.prepare(next, generation: "123-1")
        let root = try responseDirectory(directory, request: next, generation: "123-1")
        try write("0", to: root.appendingPathComponent("count"))
        await bridge.cancel(first.id)
        let payload = try String(contentsOf: directory.appendingPathComponent("completion-request"), encoding: .utf8)
        #expect(payload.contains(next.id.uuidString))
        #expect(try await bridge.waitForResponse(to: next, generation: "123-1").requestID == next.id)
    }

    @Test func aCancelledPreparationCannotOverwriteTheNewestRequest() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("ready\t123-1\tstart\t123-1\n", to: directory.appendingPathComponent("state"))
        let bridge = CommandCompletionBridge(directory: directory)
        let old = CommandCompletionRequest(id: UUID(), revision: 1, text: "git c", cursorUTF16: 5)
        let next = CommandCompletionRequest(id: UUID(), revision: 2, text: "git ch", cursorUTF16: 6)
        try await bridge.prepare(next, generation: "123-1")
        let gate = AsyncStream<Void>.makeStream()
        let obsolete = Task {
            for await _ in gate.stream { break }
            try await bridge.prepare(old, generation: "123-1")
        }
        obsolete.cancel()
        gate.continuation.finish()
        await #expect(throws: CancellationError.self) { try await obsolete.value }
        let payload = try String(contentsOf: directory.appendingPathComponent("completion-request"), encoding: .utf8)
        #expect(payload.contains(next.id.uuidString))
    }

    @Test func completionWaitHasABoundedDeadline() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = CommandCompletionBridge(directory: directory)
        let request = CommandCompletionRequest(id: UUID(), revision: 1, text: "git ", cursorUTF16: 4)
        await #expect(throws: CommandCompletionBridge.CompletionError.timedOut) {
            try await bridge.waitForResponse(to: request, generation: "123-1", timeout: .milliseconds(20))
        }
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
        #expect(candidate.displayText == "café folder/")
        #expect(candidate.detail.isEmpty)
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

    @Test func packedResponsePreservesUnicodeMultilineAndTrailingWhitespace() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = CommandCompletionRequest(id: UUID(), revision: 9, text: "cat ca", cursorUTF16: 6)
        let root = try responseDirectory(directory, request: request, generation: "123-1")
        let first = "cat café\\ folder/  \n"
        let second = "echo 👻\ncat café\\ folder/ tail"
        let cursor = "echo 👻\ncat café\\ folder/".utf8.count
        try write("2", to: root.appendingPathComponent("count"))
        try write("\(first.utf8.count)\0\(first)\0\(cursor)\0\(second)\0", to: root.appendingPathComponent("items-v1"))
        let response = try #require(try await CommandCompletionBridge(directory: directory)
            .response(to: request, generation: "123-1"))
        #expect(response.items.map(\.replacementText) == [first, second])
        #expect(response.items[0].cursorUTF16 == first.utf16.count)
        #expect(response.items[1].cursorUTF16 == "echo 👻\ncat café\\ folder/".utf16.count)
        #expect(response.items.allSatisfy { $0.replacementRange == NSRange(location: 0, length: request.text.utf16.count) })
    }

    @Test func packedResponseRejectsMalformedFramingAndEncoding() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = CommandCompletionRequest(id: UUID(), revision: 1, text: "cat ", cursorUTF16: 4)
        let malformed = [
            Data("0\0cat ".utf8), Data("0\0cat \0extra".utf8), Data("-1\0cat \0".utf8),
            Data("0\0cat \00\0second\0".utf8), Data("5\0cat 👋\0".utf8), Data([48, 0, 255, 0])
        ]
        let bridge = CommandCompletionBridge(directory: directory)
        for bytes in malformed {
            let root = try responseDirectory(directory, request: request, generation: "123-1")
            try write("1", to: root.appendingPathComponent("count"))
            try bytes.write(to: root.appendingPathComponent("items-v1"))
            await #expect(throws: CommandCompletionBridge.CompletionError.self) {
                try await bridge.response(to: request, generation: "123-1")
            }
        }
    }

    @Test func packedResponseBoundsIndividualAndAggregateBuffers() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = CommandCompletionRequest(id: UUID(), revision: 1, text: "cat ", cursorUTF16: 4)
        let megabyte = String(repeating: "x", count: 1_048_576)
        let bridge = CommandCompletionBridge(directory: directory)
        let examples = [(1, "0\0\(megabyte)x\0"), (9, String(repeating: "0\0\(megabyte)\0", count: 8) + "0\0x\0")]
        for (count, payload) in examples {
            let root = try responseDirectory(directory, request: request, generation: "123-1")
            try write("\(count)", to: root.appendingPathComponent("count"))
            try write(payload, to: root.appendingPathComponent("items-v1"))
            await #expect(throws: CommandCompletionBridge.CompletionError.self) {
                try await bridge.response(to: request, generation: "123-1")
            }
        }
    }

    @Test func displayShowsOnlyTheCompletedOptionAcrossShellContexts() {
        struct Example {
            let draft: String
            let cursor: Int
            let result: String
            let resultCursor: Int
            let expected: String
        }
        let examples = [
            Example(draft: "git ch", cursor: 6, result: "git checkout ", resultCursor: 13, expected: "checkout"),
            Example(draft: "echo 👋\ncd do --quiet", cursor: 13, result: "echo 👋\ncd documents/ --quiet",
                    resultCursor: 21, expected: "documents/"),
            Example(draft: "cat 'ca' tail", cursor: 7, result: "cat 'café folder' tail",
                    resultCursor: 15, expected: "café folder"),
            Example(draft: "echo a;git ch", cursor: 13, result: "echo a;git cherry-pick",
                    resultCursor: 22, expected: "cherry-pick")
        ]
        for example in examples {
            let request = CommandCompletionRequest(id: UUID(), revision: 1, text: example.draft, cursorUTF16: example.cursor)
            #expect(CommandCompletionToken.label(result: example.result, cursorUTF16: example.resultCursor,
                                                 request: request) == example.expected)
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
