import Foundation
import Testing
@testable import Ghostty

struct CommandDirectoryPresentationTests {
    @Test func pathDisplayAbbreviatesOnlyTheActualHomePrefix() {
        #expect(CommandChromePresentation.displayPath("/home/person", home: "/home/person") == "~")
        #expect(CommandChromePresentation.displayPath("/home/person/界\nproject", home: "/home/person") == "~/界↵project")
        #expect(CommandChromePresentation.displayPath("/home/person-other", home: "/home/person") == "/home/person-other")
    }

    @Test func clickablePrefixUsesDisplayedUTF8WithoutBranchOrStatus() throws {
        let path = FileManager.default.homeDirectoryForCurrentUser.path + "/界\nproject"
        let metadata = CommandBlockMetadata(id: "a", workingDirectory: path, branch: "feature",
                                            status: "completed", exitStatus: 0, elapsed: 0.1)
        let presentation = makePresentation(metadata: ["a": metadata])
        let row = try #require(presentation.rows.first)
        #expect(row.pathByteCount == "~/界↵project".utf8.count)
        #expect(String(bytes: row.label.utf8.prefix(row.pathByteCount), encoding: .utf8) == "~/界↵project")
        #expect(row.label.hasSuffix("  ⎇ feature"))
        #expect(row.pathByteCount < row.label.utf8.count)
        #expect(!row.suffix.isEmpty)
    }

    @Test func recoveryAndUnknownOrRelativeDirectoriesAreNotClickable() throws {
        let metadata = CommandBlockMetadata(id: "a", workingDirectory: "/fixture", branch: "",
                                            status: "editing", exitStatus: nil, elapsed: nil)
        #expect(try #require(makePresentation(metadata: ["a": metadata], recovering: true).rows.first).pathByteCount == 0)
        #expect(makePresentation(metadata: [:]).rows.isEmpty)
        let relative = CommandBlockMetadata(id: "a", workingDirectory: "relative", branch: "",
                                            status: "editing", exitStatus: nil, elapsed: nil)
        #expect(try #require(makePresentation(metadata: ["a": relative]).rows.first).pathByteCount == 0)
    }

    private func makePresentation(metadata: [String: CommandBlockMetadata], recovering: Bool = false) -> CommandChromePresentation {
        CommandChromePresentation(layout: CommandTerminalLayout(), metadata: metadata, currentID: "a",
                                  pinnedOffset: -1, recovering: recovering)
    }
}
