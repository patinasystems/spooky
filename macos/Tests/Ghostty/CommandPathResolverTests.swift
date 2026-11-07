import Foundation
import Testing
@testable import Ghostty

struct CommandPathResolverTests {
    @Test func literalPathsUseHistoricDirectoryAndPreserveHeaderSpelling() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let filename = "Quarterly report 雪.txt"
        try Data().write(to: root.appendingPathComponent(filename))
        let resolver = CommandPathResolver(home: root.path)
        let text = "other.txt  \(filename)  last.txt"
        let start = try #require(text.range(of: filename)).lowerBound
        let byte = text[..<start].utf8.count + "Quarterly rep".utf8.count
        let probe = CommandPathProbe(id: 1, kind: .output, text: text, hoverByte: byte,
                                     uri: "", workingDirectory: root.path)
        let match = try #require(await resolver.match(probe))
        #expect(match.path.path == root.path + "/" + filename)
        #expect(match.start == text[..<start].utf8.count)
        #expect(match.length == filename.utf8.count)
        #expect(match.path.kind == .file)
        let unknown = CommandPathProbe(id: 2, kind: .output, text: filename, hoverByte: 3,
                                       uri: "", workingDirectory: nil)
        #expect(await resolver.match(unknown) == nil)
        let exact = root.path + "/link/../preserved\npath"
        let header = CommandPathProbe(id: 3, kind: .header, text: "~/…", hoverByte: 0,
                                      uri: "", workingDirectory: exact)
        #expect(await resolver.match(header)?.path.path == exact)
    }

    @Test func quotedEscapedAndDiagnosticPathsKeepOriginalUTF8Ranges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("雪 report.txt"))
        try Data().write(to: root.appendingPathComponent("file.swift"))
        let resolver = CommandPathResolver(home: root.path)
        for (text, hovered, expected) in [
            ("prefix '雪 report.txt' suffix", "report", "雪 report.txt"),
            ("雪\\ report.txt", "report", "雪 report.txt"),
            ("error: file.swift:12:3", "file", "file.swift")
        ] {
            let location = try #require(text.range(of: hovered)).lowerBound
            let probe = CommandPathProbe(id: 1, kind: .output, text: text,
                                         hoverByte: text[..<location].utf8.count, uri: "", workingDirectory: root.path)
            let match = try #require(await resolver.match(probe))
            #expect(match.path.path == root.path + "/" + expected)
            let rangeBytes = Array(text.utf8)[match.start..<(match.start + match.length)]
            #expect(String(bytes: rangeBytes, encoding: .utf8) != nil)
        }
        #expect(CommandPathCandidates.around(String(repeating: "a", count: 4_097), byte: 0).isEmpty)
        #expect(CommandPathCandidates.around("one  two  three  four", byte: 6).count <= 8)
    }

    @Test func localFileLinksRejectRemoteAuthoritiesAndDoNotExpandShellSyntax() async throws {
        let resolver = CommandPathResolver(home: "/home", inspect: { $0 == "/tmp/a b" ? .file : nil })
        let local = CommandPathProbe(id: 1, kind: .localLink, text: "a file", hoverByte: 2,
                                     uri: "file://localhost/tmp/a%20b", workingDirectory: nil)
        #expect(await resolver.match(local)?.path.path == "/tmp/a b")
        let remote = CommandPathProbe(id: 2, kind: .localLink, text: "a file", hoverByte: 2,
                                      uri: "file://server/tmp/a%20b", workingDirectory: nil)
        #expect(await resolver.match(remote) == nil)
        #expect(CommandPathResolver.absolutePath(token: "$(touch marker)", workingDirectory: "/old", home: "/home")
            == "/old/$(touch marker)")
        #expect(CommandPathResolver.absolutePath(token: "~/link/../file", workingDirectory: nil, home: "/home")
            == "/home/link/../file")
    }

    @Test func filesystemCacheIsBoundedAndExpiresPositiveAndNegativeResults() async {
        let fixture = PathStatFixture()
        let resolver = CommandPathResolver(home: "/home", capacity: 2,
                                           now: { fixture.time }, inspect: { fixture.inspect($0) })
        fixture.add("/a")
        _ = await resolver.resolve(token: "/a", workingDirectory: nil)
        _ = await resolver.resolve(token: "/a", workingDirectory: nil)
        #expect(fixture.reads == 1)
        #expect(await resolver.resolve(token: "/b", workingDirectory: nil) == nil)
        fixture.add("/b")
        #expect(await resolver.resolve(token: "/b", workingDirectory: nil) == nil)
        fixture.advance(0.6)
        #expect(await resolver.resolve(token: "/b", workingDirectory: nil) != nil)
        #expect(fixture.reads == 3)
        _ = await resolver.resolve(token: "/c", workingDirectory: nil)
        _ = await resolver.resolve(token: "/a", workingDirectory: nil)
        #expect(fixture.reads == 5) // A was evicted by the third distinct path.
        fixture.advance(3)
        _ = await resolver.resolve(token: "/a", workingDirectory: nil)
        #expect(fixture.reads == 6)
    }

    @Test func relativeLinksUseTheirBlockDirectoryInsteadOfTheAppOrNewPrompt() async throws {
        let resolver = CommandPathResolver(home: "/home", inspect: { _ in .file })
        for (target, expected) in [
            ("src/report%20%E9%9B%AA.txt", "/old/project/src/report 雪.txt"),
            ("./src/report.txt", "/old/project/./src/report.txt"),
            ("../report.txt", "/old/project/../report.txt"),
            ("file:src/report.txt", "/old/project/src/report.txt"),
            ("file:../report.txt", "/old/project/../report.txt"),
            ("src/report.txt#L12", "/old/project/src/report.txt"),
            ("/absolute/report.txt", "/absolute/report.txt"),
            ("file:///absolute/report.txt", "/absolute/report.txt"),
            ("~/report.txt", "/home/report.txt")
        ] {
            let probe = CommandPathProbe(id: 1, kind: .localLink, text: "open report", hoverByte: 2,
                                         uri: target, workingDirectory: "/old/project")
            let match = try #require(await resolver.match(probe))
            #expect(match.path.path == expected)
            #expect(match.start == 0 && match.length == probe.text.utf8.count)
        }
        let unknown = CommandPathProbe(id: 2, kind: .localLink, text: "report", hoverByte: 0,
                                       uri: "src/report.txt", workingDirectory: nil)
        #expect(await resolver.match(unknown) == nil)
        for target in ["https://example.com/file", "//server/file", "file://server/file",
                       "file://user@localhost/tmp/file"] {
            #expect(CommandPathResolver.localLinkPath(target) == nil)
        }
    }

    @Test func listedChildrenUseTheExplicitNearbyParentAndRejectAmbiguity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("shared/playgrounds/demo/qa")
        let video = parent.appendingPathComponent("video/walkthrough.mp4")
        try FileManager.default.createDirectory(at: video.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: video)
        let resolver = CommandPathResolver()
        let context = "Everything is in shared/playgrounds/demo/qa/, which contains the recordings."
        for kind in [CommandPathProbe.Kind.output, .localLink] {
            let text = kind == .output ? "- video/walkthrough.mp4: a recording" : "video/walkthrough.mp4"
            let probe = CommandPathProbe(id: 1, kind: kind, text: text, hoverByte: 7,
                                         uri: root.appendingPathComponent("video/walkthrough.mp4").absoluteString,
                                         workingDirectory: root.path, context: context)
            let match = try #require(await resolver.match(probe))
            #expect(match.path.path == video.path)
            #expect(String(bytes: Array(text.utf8)[match.start..<(match.start + match.length)], encoding: .utf8)
                == "video/walkthrough.mp4")
        }
        // Exact parent hyperlinks also work when a TUI erased its block anchor.
        let linked = CommandPathProbe(id: 2, kind: .output, text: "video/walkthrough.mp4:", hoverByte: 3,
                                      uri: "", workingDirectory: nil, context: parent.absoluteString)
        #expect(await resolver.match(linked)?.path.path == video.path)
        let other = root.appendingPathComponent("other/video")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data().write(to: other.appendingPathComponent("walkthrough.mp4"))
        let ambiguous = CommandPathProbe(id: 3, kind: .output, text: "video/walkthrough.mp4", hoverByte: 3,
                                         uri: "", workingDirectory: root.path,
                                         context: context + "\nAlso other/")
        #expect(await resolver.match(ambiguous) == nil)
        let missingContext = CommandPathProbe(id: 4, kind: .output, text: "video/walkthrough.mp4:", hoverByte: 3,
                                              uri: "", workingDirectory: root.path)
        #expect(await resolver.match(missingContext) == nil)
    }
}

private final class PathStatFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var clock: TimeInterval = 0
    private var count = 0
    private var files: Set<String> = []
    var time: TimeInterval { lock.withLock { clock } }
    var reads: Int { lock.withLock { count } }
    func advance(_ seconds: TimeInterval) { lock.withLock { clock += seconds } }
    func add(_ path: String) { _ = lock.withLock { files.insert(path) } }
    func inspect(_ path: String) -> CommandResolvedPath.Kind? {
        lock.withLock { count += 1; return files.contains(path) ? .file : nil }
    }
}
