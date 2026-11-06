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

    @Test func completionTimeAppearsBesideDurationWithoutChangingThePath() throws {
        let metadata = CommandBlockMetadata(id: "a", workingDirectory: "/fixture", branch: "main",
                                            status: "completed", exitStatus: 0, elapsed: 0.018,
                                            completionTime: "9:42:35.123 PM")
        let row = try #require(makePresentation(metadata: ["a": metadata]).rows.first)
        #expect(row.suffix == "✓  0.018s  ·  9:42:35.123 PM")
        #expect(row.label == "/fixture  ⎇ main")
        #expect(row.pathByteCount == "/fixture".utf8.count)
    }

    @Test(arguments: ["editing", "running"])
    func unfinishedBlocksNeverDisplayACompletionTime(_ status: String) throws {
        let metadata = CommandBlockMetadata(id: "a", workingDirectory: "/fixture", branch: "",
                                            status: status, exitStatus: nil, elapsed: nil,
                                            completionTime: "9:42:35.123 PM")
        let row = try #require(makePresentation(metadata: ["a": metadata]).rows.first)
        #expect(row.suffix == (status == "running" ? "running" : ""))
    }

    @Test(arguments: [
        ("en_US", 0, "12:00:00.123 AM"),
        ("en_GB", 0, "00:00:00.123"),
        ("de_DE", 0, "00:00:00,123"),
        ("en_GB", 19_800, "05:30:00.123"),
        ("en_GB", -18_000, "19:00:00.123")
    ])
    func completionTimeUsesLocalHourCycleDecimalSeparatorAndTimeZone(_ locale: String, _ offset: Int,
                                                                     _ expected: String) throws {
        let zone = try #require(TimeZone(secondsFromGMT: offset))
        let value = try #require(CommandBlockMetadata.localizedCompletionTime(
            0.123, locale: Locale(identifier: locale), timeZone: zone))
        // ICU versions may choose either ordinary or narrow no-break spacing.
        #expect(value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") == expected)
        #expect(CommandBlockMetadata.localizedCompletionTime(.nan) == nil)
        #expect(CommandBlockMetadata.localizedCompletionTime(.infinity) == nil)
    }

    private func makePresentation(metadata: [String: CommandBlockMetadata], recovering: Bool = false) -> CommandChromePresentation {
        CommandChromePresentation(layout: CommandTerminalLayout(), metadata: metadata, currentID: "a",
                                  pinnedOffset: -1, recovering: recovering)
    }
}
