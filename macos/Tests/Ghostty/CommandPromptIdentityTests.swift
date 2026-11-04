import Foundation
import Testing
@testable import Ghostty

struct CommandPromptIdentityTests {
    @Test func identityUsesShortHostnameWithoutLosingUnicode() throws {
        let identity = try #require(CommandPromptIdentity(username: "tyler", hostname: "MacBook-Pro-5.local"))
        #expect(identity.label == "tyler@MacBook-Pro-5")
        #expect(CommandPromptIdentity(username: "界", hostname: "工作站.example.com")?.label == "界@工作站")
        #expect(CommandPromptIdentity(username: "root", hostname: "localhost")?.label == "root@localhost")
    }

    @Test func missingOrControlCharacterIdentityIsOmitted() {
        #expect(CommandPromptIdentity(username: "", hostname: "computer") == nil)
        #expect(CommandPromptIdentity(username: "tyler", hostname: "") == nil)
        #expect(CommandPromptIdentity(username: "tyler", hostname: ".local") == nil)
        #expect(CommandPromptIdentity(username: "tyler\n", hostname: "computer") == nil)
        #expect(CommandPromptIdentity(username: "tyler", hostname: "computer\u{1B}") == nil)
    }

    @Test func editingIdentityPreservesClickablePathAndOtherBlockStatuses() throws {
        let identity = try #require(CommandPromptIdentity(username: "tyler", hostname: "MacBook-Pro-5.local"))
        let cwd = FileManager.default.homeDirectoryForCurrentUser.path + "/界\nproject"
        let metadata = [
            "current": CommandBlockMetadata(id: "current", workingDirectory: cwd, branch: "main",
                                            status: "editing", exitStatus: nil, elapsed: nil),
            "previous": CommandBlockMetadata(id: "previous", workingDirectory: "/previous", branch: "",
                                             status: "completed", exitStatus: 2, elapsed: 0.125)
        ]
        var layout = CommandTerminalLayout()
        layout.blocks = [.init(id: "previous", flags: 15, headerY: 0, inputY: 1,
                               outputY: 2, endY: 3, complete: true)]
        func presentation(recovering: Bool = false) -> CommandChromePresentation {
            CommandChromePresentation(layout: layout, metadata: metadata, currentID: "current", pinnedOffset: -1,
                                      recovering: recovering, promptIdentity: identity)
        }
        let rows = presentation().rows
        let current = try #require(rows.first { $0.id == "current" })
        #expect(current.suffix == "tyler@MacBook-Pro-5")
        #expect(current.label == "~/界↵project  ⎇ main")
        #expect(String(bytes: current.label.utf8.prefix(current.pathByteCount), encoding: .utf8) == "~/界↵project")
        #expect(try #require(rows.first { $0.id == "previous" }).suffix == "exit 2  0.125s")
        #expect(try #require(presentation(recovering: true).rows.first { $0.id == "current" }).suffix.isEmpty)
        let withoutIdentity = CommandChromePresentation(layout: layout, metadata: metadata, currentID: "current",
                                                        pinnedOffset: -1, recovering: false, promptIdentity: nil)
        #expect(try #require(withoutIdentity.rows.first { $0.id == "current" }).suffix.isEmpty)
    }
}
