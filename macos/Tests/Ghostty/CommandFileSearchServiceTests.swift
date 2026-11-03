import Foundation
import Testing
@testable import Ghostty

struct CommandFileSearchServiceTests {
    @Test func diagnosticIndexOverridesAreOptInAndRequireAbsolutePaths() {
        let disabled = CommandFileSearchService.diagnosticConfiguration(
            enabled: false, indexDirectory: "/tmp/private-fixture", outputPath: "/tmp/measure.jsonl")
        #expect(disabled.indexDirectory == nil)
        #expect(disabled.outputPath == nil)
        let enabled = CommandFileSearchService.diagnosticConfiguration(
            enabled: true, indexDirectory: "/tmp/private-fixture", outputPath: "/tmp/measure.jsonl")
        #expect(enabled.indexDirectory?.path == "/tmp/private-fixture")
        #expect(enabled.outputPath == "/tmp/measure.jsonl")
        let invalid = CommandFileSearchService.diagnosticConfiguration(
            enabled: true, indexDirectory: "relative", outputPath: "/tmp/nul\0invalid")
        #expect(invalid.indexDirectory == nil)
        #expect(invalid.outputPath == nil)
    }

    @Test func startupStartsOnceAndReportsReadinessWithoutInventingASearch() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try fakeService(root)
        let first = try await service.indexState()
        #expect(first == .creating)
        try await service.startIndexing()
        try await service.startIndexing()
        #expect(try await service.indexState() == .ready)
        let requests = try String(contentsOf: root.appendingPathComponent("index/requests"), encoding: .utf8)
        #expect(!requests.contains("\"query\""))
        let launches = try String(contentsOf: root.appendingPathComponent("index/launches"), encoding: .utf8)
        #expect(launches == "launch\n")
        let result = try await service.search(query: "first", near: root)
        #expect(result.first?.name == "result-1")
        await service.shutdown()
    }

    @Test func readinessPollDoesNotCancelPendingSearch() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try fakeService(root)
        let search = Task { try await service.search(query: "slow", near: root) }
        try await waitForRequest(in: root)
        #expect(try await service.indexState() == .creating)
        #expect(try await search.value.first?.name == "result-1")
        await service.shutdown()
    }

    @Test func searchDoesNotCancelPendingReadiness() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try fakeService(root, slowStatus: true)
        let readiness = Task { try await service.indexState() }
        try await waitForRequest(in: root)
        let result = try await service.search(query: "first", near: root)
        #expect(try await readiness.value == .creating)
        #expect(result.first?.name == "result-1")
        await service.shutdown()
    }

    @Test func stoppedReaderProducesBackpressureInsteadOfBlockingCancellation() throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        try CommandFileSearchPipe.configure(pipe.fileHandleForWriting)
        let bytes = Data(repeating: 120, count: 16_384)
        var reachedBackpressure = false
        for _ in 0..<256 {
            do { try CommandFileSearchPipe.write(bytes, to: pipe.fileHandleForWriting) } catch {
                reachedBackpressure = true
                break
            }
        }
        #expect(reachedBackpressure)
        // Draining the real kernel pipe demonstrates that it was full, not closed.
        let retained = try pipe.fileHandleForReading.read(upToCount: 16_384)
        #expect(retained?.isEmpty == false)
    }

    @Test func directoryNavigationIsBoundedSortedAndIncludesHiddenFilesAndDirectoryLinks() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data().write(to: root.appendingPathComponent("z.txt"))
        try Data().write(to: root.appendingPathComponent(".hidden"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: directory)
        try Data().write(to: directory.appendingPathComponent("nested.txt"))
        let service = CommandFileSearchService()
        let entries = try await service.children(of: root)
        #expect(entries.map(\.name) == ["folder", "linked", ".hidden", "z.txt"])
        let firstEntriesAreDirectories = entries.prefix(2).allSatisfy { $0.isDirectory }
        #expect(firstEntriesAreDirectories)
        #expect(!entries.contains { $0.name == "nested.txt" })
        #expect(try await service.children(of: root, limit: 2).count == 2)
        #expect(Set(entries.map(\.id)).count == entries.count)
    }

    @Test func emptyQueryListsTheRequestedScopeWithoutLaunchingAHelper() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("local.txt"))
        let service = CommandFileSearchService(executableURL: root.appendingPathComponent("missing"))
        let entries = try await service.search(query: " ", near: URL(fileURLWithPath: "/"), scope: root)
        #expect(entries.map(\.name) == ["local.txt"])
    }

    @Test func invalidQueryFailsBeforeProcessLaunch() async throws {
        let service = CommandFileSearchService(executableURL: URL(fileURLWithPath: "/missing"))
        await #expect(throws: CommandFileSearchService.Failure.invalidRequest) {
            try await service.search(query: String(repeating: "é", count: 513), near: URL(fileURLWithPath: "/tmp"))
        }
        await #expect(throws: CommandFileSearchService.Failure.invalidRequest) {
            try await service.search(query: "name", near: URL(string: "https://example.com")!)
        }
    }

    @Test func protocolRejectsDuplicatePathsAndRelativePaths() throws {
        let id = UUID()
        for entries in [
            [["path": "relative", "name": "relative", "isDirectory": false]],
            [["path": "/a", "name": "a", "isDirectory": false],
             ["path": "/a", "name": "a", "isDirectory": true]]
        ] {
            let data = try JSONSerialization.data(withJSONObject: [
                "id": id.uuidString, "entries": entries, "cancelled": false
            ])
            #expect(throws: CommandFileSearchService.Failure.invalidResponse) {
                try CommandFileSearchService.decodeResponse(data)
            }
        }
    }

    @Test func helperIsReusedAndReceivesLiteralText() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try fakeService(root)
        let first = try await service.search(query: "grep:secret", near: root)
        let second = try await service.search(query: "git:status", near: root)
        #expect(first.first?.name == "result-1")
        #expect(second.first?.name == "result-2")
        let requests = try String(contentsOf: root.appendingPathComponent("index/requests"), encoding: .utf8)
        #expect(requests.contains("grep:secret"))
        #expect(requests.contains("git:status"))
        await service.shutdown()
    }

    @Test func cancelledLateResponseCannotReplaceTheNextRequest() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try fakeService(root)
        let first = Task { try await service.search(query: "slow", near: root) }
        try await waitForRequest(in: root)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        let next = try await service.search(query: "next", near: root)
        #expect(next.first?.name == "result-2")
        await service.shutdown()
    }

    @Test func newSearchSupersedesPendingSearchEvenWithoutCallerCancellation() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try fakeService(root)
        let first = Task { try await service.search(query: "slow", near: root) }
        try await waitForRequest(in: root)
        let next = try await service.search(query: "next", near: root)
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(next.first?.name == "result-2")
        await service.shutdown()
    }

    @Test func timeoutCompletesTheRequest() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try fakeService(root, timeout: .milliseconds(20))
        await #expect(throws: CommandFileSearchService.Failure.timedOut) {
            try await service.search(query: "slow", near: root)
        }
        await service.shutdown()
    }

    @Test func shutdownCancelsPendingWorkAndNextSearchStartsFresh() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try fakeService(root)
        let first = Task { try await service.search(query: "slow", near: root) }
        try await waitForRequest(in: root)
        await service.shutdown()
        await #expect(throws: CancellationError.self) { try await first.value }
        let next = try await service.search(query: "next", near: root)
        #expect(next.first?.name == "result-1")
        await service.shutdown()
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spooky-search-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func fakeService(
        _ root: URL,
        timeout: Duration = .seconds(3),
        slowStatus: Bool = false
    ) throws -> CommandFileSearchService {
        let executable = root.appendingPathComponent("helper")
        let script = #"""
        #!/bin/sh
        count=0
        statuses=0
        printf 'launch\n' >> "$1/launches"
        while IFS= read -r line; do
          case "$line" in *'"op":"cancel"'*) continue;; esac
          printf '%s\n' "$line" >> "$1/requests"
          rest=${line#*\"id\":\"}
          id=${rest%%\"*}
          case "$line" in *'"op":"status"'*)
            STATUS_DELAY
            statuses=$((statuses + 1))
            state=ready
            if [ "$statuses" -eq 1 ]; then state=creating; fi
            printf '{"id":"%s","entries":[],"cancelled":false,"state":"%s"}\n' "$id" "$state"
            continue;;
          esac
          count=$((count + 1))
          case "$line" in *'"query":"slow"'*) /bin/sleep 0.15;; esac
          printf '{"id":"%s","entries":[{"path":"/tmp/result-%s","name":"result-%s","isDirectory":false}],"cancelled":false}\n' "$id" "$count" "$count"
        done
        """#
        let contents = script.replacingOccurrences(of: "STATUS_DELAY", with: slowStatus ? "/bin/sleep 0.15" : ":")
        try contents.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return CommandFileSearchService(executableURL: executable,
                                        indexDirectory: root.appendingPathComponent("index"), timeout: timeout)
    }

    private func waitForRequest(in root: URL) async throws {
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("index/requests").path) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CommandFileSearchService.Failure.timedOut
    }
}
