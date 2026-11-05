import Foundation
import Testing
@testable import Ghostty

struct CommandShellBridgeFilesTests {
    private enum Invalid: Error, Equatable { case response }

    @Test func readySnapshotRequiresTheSameEmptyPrimaryPrompt() {
        #expect(CommandShellBridgeFiles.isReady("ready\t123-1\tstart\t123-1\n", generation: "123-1"))
        for state in ["ready\t123-2\tstart\t123-2\n", "ready\t123-1\tcontinuation\t123-1\n",
                      "running\t123-1\tstart\t123-1\n", "ready\t123-1\tstart\n",
                      "ready\t123-1\tstart\t123-1\textra\n"] {
            #expect(!CommandShellBridgeFiles.isReady(state, generation: "123-1"))
        }
        #expect(!CommandShellBridgeFiles.isReady("ready\t\tstart\tid\n", generation: ""))
        #expect(!CommandShellBridgeFiles.isReady("ready\tbad\nvalue\tstart\tid\n", generation: "bad\nvalue"))
    }

    @Test(arguments: ["running\t123-1\tstart\tblock-1\n", "ready\t123-1\tstart\tblock-1\n", ""])
    func submissionUsesParsedGenerationWhileStateFileLags(_ state: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        if !state.isEmpty { try Data(state.utf8).write(to: directory.appendingPathComponent("state")) }
        let bridge = CommandInputBridge(directory: directory)
        let identifier = UUID().uuidString
        try await bridge.submit(text: "printf 'next\\n'", generation: "123-2", id: identifier)
        let request = try String(contentsOf: directory.appendingPathComponent("request"), encoding: .utf8)
        #expect(request == "123-2\n\(identifier)\nprintf 'next\\n'")
        if !state.isEmpty {
            #expect(try String(contentsOf: directory.appendingPathComponent("state"), encoding: .utf8) == state)
        }
    }

    @Test func boundedReadPreservesExactUTF8AndRejectsOversizeOrInvalidBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let value = "\t👻\n  "
        try Data(value.utf8).write(to: url)
        #expect(try CommandShellBridgeFiles.readUTF8(url, maximum: value.utf8.count,
                                                   invalidResponse: Invalid.response) == value)
        #expect(throws: Invalid.response) {
            try CommandShellBridgeFiles.readUTF8(url, maximum: value.utf8.count - 1, invalidResponse: Invalid.response)
        }
        try Data([0xff]).write(to: url)
        #expect(throws: Invalid.response) {
            try CommandShellBridgeFiles.readUTF8(url, maximum: 1, invalidResponse: Invalid.response)
        }
        try Data().write(to: url)
        #expect(try CommandShellBridgeFiles.readUTF8(url, maximum: 0, invalidResponse: Invalid.response).isEmpty)
        try FileManager.default.removeItem(at: url)
        #expect(throws: CocoaError.self) {
            try CommandShellBridgeFiles.readUTF8(url, maximum: 1, invalidResponse: Invalid.response)
        }
    }

    @Test func cancellationLeavesNewerOrMalformedRequestsUntouched() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let old = UUID()
        let current = UUID()
        let payload = "123-1\n\(current.uuidString)\n0\nexact draft\n"
        try Data(payload.utf8).write(to: url)
        CommandShellBridgeFiles.removeRequest(url, matching: old, maximum: 512)
        #expect(try String(contentsOf: url, encoding: .utf8) == payload)
        CommandShellBridgeFiles.removeRequest(url, matching: current, maximum: 4)
        #expect(FileManager.default.fileExists(atPath: url.path))
        CommandShellBridgeFiles.removeRequest(url, matching: current, maximum: 512)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
