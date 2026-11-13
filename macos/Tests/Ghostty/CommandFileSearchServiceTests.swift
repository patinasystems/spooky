import CoreServices
import Foundation
import Testing
@testable import Ghostty

struct CommandFileSearchServiceTests {
    @Test func initializationAndDirectoryNavigationNeverQuerySpotlight() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = MetadataProbe()
        let service = CommandFileSearchService(metadataSearch: { try await probe.search($0) })
        try Data().write(to: root.appendingPathComponent("local.txt"))
        let children = try await service.search(query: " ", near: root)
        #expect(children.map(\.name) == ["local.txt"])
        #expect(await probe.requests.isEmpty)
        await service.shutdown()
        #expect(await probe.requests.isEmpty)
    }

    @Test func directoryNavigationIsBoundedSortedAndIncludesHiddenFilesAndDirectoryLinks() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data().write(to: folder.appendingPathComponent("nested.txt"))
        try Data().write(to: root.appendingPathComponent("z.txt"))
        try Data().write(to: root.appendingPathComponent(".hidden"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: folder)
        let service = CommandFileSearchService()
        let children = try await service.children(of: root)
        #expect(children.map(\.name) == ["alias", "folder", ".hidden", "z.txt"])
        let firstEntriesAreDirectories = children.prefix(2).allSatisfy(\.isDirectory)
        #expect(firstEntriesAreDirectories)
        #expect(!children.contains { $0.name == "nested.txt" })
        #expect(try await service.children(of: root, limit: 2).count == 2)
    }

    @Test func emptyQueryUsesExplicitFolderWithoutAProvider() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("scoped.txt"))
        let service = CommandFileSearchService(metadataSearch: { _ in
            Issue.record("Directory navigation must not request the system index")
            return []
        })
        let results = try await service.search(query: "", near: URL(fileURLWithPath: "/"), scope: root)
        #expect(results.map(\.name) == ["scoped.txt"])
    }

    @Test func invalidQueriesFailBeforeCallingTheProvider() async {
        let probe = MetadataProbe()
        let service = CommandFileSearchService(metadataSearch: { try await probe.search($0) })
        for query in [String(repeating: "x", count: 1_025), "a\0b"] {
            await #expect(throws: CommandFileSearchService.Failure.invalidRequest) {
                try await service.search(query: query, near: URL(fileURLWithPath: "/tmp"))
            }
        }
        await #expect(throws: CommandFileSearchService.Failure.invalidRequest) {
            try await service.search(query: "x", near: URL(string: "https://example.com")!)
        }
        #expect(await probe.requests.isEmpty)
    }

    @Test func predicateQuotesExpressionsAndDoesNotTreatPunctuationAsQuerySyntax() {
        #expect(CommandFileSearchService.predicate(for: "foo bar") ==
                "kMDItemFSName == \"*f*o*o*\"cd && kMDItemFSName == \"*b*a*r*\"cd")
        #expect(CommandFileSearchService.predicate(for: "a\"b\\c*?") ==
                #"kMDItemFSName == "*a*\"*b*\\*c*****"cd"#)
        for literal in ["report", "café", "grep:secret", "a\"||kMDItemTextContent==\"*", "star*?.txt", "back\\slash"] {
            let predicate = CommandFileSearchService.predicate(for: literal)
            #expect(MDQueryCreate(kCFAllocatorDefault, predicate as CFString, nil, nil) != nil)
        }
    }

    @Test func wildcardCharactersAreMatchedLiterallyAfterTheMetadataPrefilter() {
        let candidates = [entry("/w/report.txt"), entry("/w/report*.txt"), entry("/w/report?.txt")]
        #expect(CommandFileSearchService.ranked(candidates, query: "*", near: "/w", scope: nil, limit: 100)
            .map(\.name) == ["report*.txt"])
        #expect(CommandFileSearchService.ranked(candidates, query: "?", near: "/w", scope: nil, limit: 100)
            .map(\.name) == ["report?.txt"])
    }

    @Test func rankingPrefersExactThenPrefixSubstringAndFuzzyWithCwdTieBreaks() {
        let candidates = [entry("/elsewhere/kitchen"), entry("/w/kitchen"), entry("/w/kitchen-tests"),
                          entry("/w/my-kitchen"), entry("/w/k_i_t_c_h_e_n"), entry("/w/unrelated")]
        #expect(CommandFileSearchService.ranked(candidates, query: "kitchen", near: "/w", scope: nil, limit: 100)
            .map(\.path) == ["/w/kitchen", "/elsewhere/kitchen", "/w/kitchen-tests", "/w/my-kitchen", "/w/k_i_t_c_h_e_n"])
        #expect(CommandFileSearchService.ranked([entry("/w/CaféMenu")], query: "cafe", near: "/w", scope: nil, limit: 100)
            .count == 1)
    }

    @Test func rankingFiltersMalformedDuplicatesAndOutOfScopeCandidates() {
        let candidates = [entry("/workspace/a.txt"), entry("/workspace/a.txt"), entry("/workspace-other/a.txt"),
                          entry("relative/a.txt"), entry("/workspace/b.txt"),
                          CommandFileSearchEntry(path: "/workspace/a", name: "a/b", isDirectory: false)]
        #expect(CommandFileSearchService.ranked(candidates, query: "a", near: "/", scope: "/workspace", limit: 100)
            .map(\.path) == ["/workspace/a.txt"])
    }

    @Test func searchBoundsCandidatesAndReturnedRows() async throws {
        let probe = MetadataProbe()
        let service = CommandFileSearchService(metadataSearch: { request in
            _ = try await probe.search(request)
            return (0..<3_000).map { entry("/w/file-\($0)") }
        })
        let results = try await service.search(query: "file", near: URL(fileURLWithPath: "/w"),
                                               scope: URL(fileURLWithPath: "/w"), limit: 999)
        #expect(results.count == 200)
        let request = try #require(await probe.requests.first)
        #expect(request.limit == 2_048)
        #expect(request.scope == "/w")
        let bounded = CommandFileSearchService.ranked((0..<2_048).map { entry("/w/unrelated-\($0)") }
            + [entry("/w/exact")], query: "exact", near: "/w", scope: nil, limit: 100)
        #expect(bounded.isEmpty)
    }

    @Test func searchSupersedesAndCancelsItsPreviousMetadataQuery() async throws {
        let probe = MetadataProbe()
        let service = CommandFileSearchService(metadataSearch: { try await probe.search($0) })
        let first = Task { try await service.search(query: "slow", near: URL(fileURLWithPath: "/w")) }
        try await waitForQuery(probe)
        let next = try await service.search(query: "fast", near: URL(fileURLWithPath: "/w"))
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(next.map(\.name) == ["fast.txt"])
        #expect(await probe.cancelled == 1)
    }

    @Test func callerCancellationStopsTheUnderlyingMetadataQuery() async throws {
        let probe = MetadataProbe()
        let service = CommandFileSearchService(metadataSearch: { try await probe.search($0) })
        let request = Task { try await service.search(query: "slow", near: URL(fileURLWithPath: "/w")) }
        try await waitForQuery(probe)
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(await probe.cancelled == 1)
    }

    @Test func timeoutCancelsTheUnderlyingMetadataQuery() async throws {
        let probe = MetadataProbe()
        let service = CommandFileSearchService(metadataSearch: { try await probe.search($0) }, timeout: .milliseconds(20))
        await #expect(throws: CommandFileSearchService.Failure.timedOut) {
            try await service.search(query: "slow", near: URL(fileURLWithPath: "/w"))
        }
        #expect(await probe.cancelled == 1)
    }

    @Test func shutdownCancelsSearchAndTheNextRequestStillWorks() async throws {
        let probe = MetadataProbe()
        let service = CommandFileSearchService(metadataSearch: { try await probe.search($0) })
        let request = Task { try await service.search(query: "slow", near: URL(fileURLWithPath: "/w")) }
        try await waitForQuery(probe)
        await service.shutdown()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(await probe.cancelled == 1)
        #expect(try await service.search(query: "fast", near: URL(fileURLWithPath: "/w")).map(\.name) == ["fast.txt"])
    }

    @Test func directoryNavigationSupersedesAnIndexedSearch() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = MetadataProbe()
        let service = CommandFileSearchService(metadataSearch: { try await probe.search($0) })
        let request = Task { try await service.search(query: "slow", near: root) }
        try await waitForQuery(probe)
        #expect(try await service.search(query: "", near: root).isEmpty)
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(await probe.cancelled == 1)
    }

    @Test func typedFilenameFindsUnindexedImmediateChildren() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("report-final.txt"))
        let service = CommandFileSearchService(metadataSearch: { _ in [] })
        let results = try await service.search(query: "rptfnl", near: root, scope: root)
        #expect(results.map(\.name) == ["report-final.txt"])
    }

    @Test func scopedSearchPreservesASymlinkDirectoryAlias() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        try Data().write(to: target.appendingPathComponent("report.txt"))
        let indexed = entry(target.resolvingSymlinksInPath().appendingPathComponent("report.txt").path)
        let service = CommandFileSearchService(metadataSearch: { _ in [indexed] })
        let results = try await service.search(query: "report", near: root, scope: alias)
        #expect(results.map(\.path) == [alias.appendingPathComponent("report.txt").path])
    }

    @Test func metadataParentAliasesNormalizeWithoutResolvingTheResultSymlink() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.txt")
        let link = root.appendingPathComponent("link.txt")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let parentAlias = root.appendingPathComponent("parent-alias")
        try FileManager.default.createSymbolicLink(at: parentAlias, withDestinationURL: root)
        let normalized = try CommandFileSearchService.normalized([entry(parentAlias.appendingPathComponent("link.txt").path)],
                                                                preferredDirectory: root)
        #expect(normalized.map(\.path) == [link.path])
        #expect(normalized.first?.name == "link.txt")
    }

    @Test func unavailableSpotlightDoesNotHideMatchingLocalFiles() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("report.txt"))
        let service = CommandFileSearchService(metadataSearch: { _ in
            throw CommandFileSearchService.Failure.unavailable("Indexing disabled")
        })
        #expect(try await service.search(query: "report", near: root).map(\.name) == ["report.txt"])
    }

    @Test func contiguousAndFuzzyPatternsUseASingleBoundedNativeQuery() async throws {
        let probe = MetadataProbe()
        let service = CommandFileSearchService(metadataSearch: { try await probe.search($0) })
        #expect(try await service.search(query: "fast", near: URL(fileURLWithPath: "/w")).count == 1)
        #expect(await probe.requests.count == 1)
        #expect(await probe.requests.first?.predicate ==
                #"(kMDItemFSName == "*fast*"cd) || (kMDItemFSName == "*f*a*s*t*"cd)"#)
        #expect(CommandFileSearchService.metadataPredicate(for: "a") == #"kMDItemFSName == "*a*"cd"#)
    }

    /// Opt-in because CI and developer volumes may disable Spotlight. Point this
    /// to an existing, indexed file (e.g. /Applications/Spooky.app) to validate the
    /// actual query dialect and MDItem extraction, without triggering indexing.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOOKY_SPOTLIGHT_FIXTURE_PATH"] != nil))
    func nativeMetadataQueryFindsAnExistingIndexedFilename() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SPOOKY_SPOTLIGHT_FIXTURE_PATH"])
        let file = URL(fileURLWithPath: path)
        let service = CommandFileSearchService()
        // Deliberately list a missing folder: a local directory fallback must not
        // make this integration check pass if the native metadata query is broken.
        let results = try await service.search(query: file.lastPathComponent,
            near: URL(fileURLWithPath: "/spooky-no-local-fixture-\(UUID())"))
        #expect(results.contains { $0.path == path })
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spooky-search-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func waitForQuery(_ probe: MetadataProbe) async throws {
        for _ in 0..<500 {
            if await !probe.requests.isEmpty { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw CommandFileSearchService.Failure.timedOut
    }
}

private func entry(_ path: String) -> CommandFileSearchEntry {
    CommandFileSearchEntry(path: path, name: (path as NSString).lastPathComponent, isDirectory: false)
}

private actor MetadataProbe {
    private(set) var requests: [CommandFileSearchService.MetadataRequest] = []
    private(set) var cancelled = 0

    func search(_ request: CommandFileSearchService.MetadataRequest) async throws -> [CommandFileSearchEntry] {
        requests.append(request)
        if request.predicate.contains("s*l*o*w") || request.predicate.contains("*slow*") {
            do { try await Task.sleep(for: .seconds(60)) } catch {
                cancelled += 1
                throw error
            }
        }
        return [entry("/w/fast.txt")]
    }
}
