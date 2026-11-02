import Testing
@testable import Ghostty

struct CommandInputHandoffTests {
    private let handoff = CommandInputHandoff(blockID: "pane-2", generation: "prompt-2")

    @Test func acceptanceWaitsForThisCommandsTerminalBoundary() {
        var layout = CommandTerminalLayout()
        layout.blocks = [block("pane-1", flags: 15, complete: true), block("pane-2", flags: 3)]
        layout.lastStartedBlockID = "pane-1"
        #expect(!handoff.canFinish(layout: layout, readyGeneration: "prompt-2", context: "start"))

        layout.lastStartedBlockID = "pane-2"
        // A command can clear every drawable anchor before the next UI poll.
        layout.blocks = []
        #expect(handoff.canFinish(layout: layout, readyGeneration: nil, context: "start"))
    }

    @Test func fastCommandReturnsDirectlyToNativePrompt() {
        #expect(handoff.canFinish(layout: CommandTerminalLayout(), readyGeneration: "prompt-3", context: "start"))
    }

    @Test func continuationAndAlternateScreenReceiveTerminalInput() {
        #expect(handoff.canFinish(layout: CommandTerminalLayout(), readyGeneration: nil, context: "cont"))
        var layout = CommandTerminalLayout()
        layout.primary = false
        #expect(handoff.canFinish(layout: layout, readyGeneration: nil, context: "start"))
    }

    private func block(_ id: String, flags: UInt32, complete: Bool = false) -> CommandBlockAnchor {
        CommandBlockAnchor(id: id, flags: flags, headerY: 0, inputY: 18,
                           outputY: 36, endY: 54, complete: complete)
    }
}
