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

    @MainActor
    @Test(arguments: ["start", "vared"])
    func occludedTransferKeepsPollingUntilItsTerminalBoundary(context: String) {
        var layout = CommandTerminalLayout()
        layout.lastStartedBlockID = "pane-1"
        // Pending submission and an accepted receipt both retain native input.
        // A hidden window must still poll until its own C marker is parsed.
        #expect(CommandInputSession.requiresGeometryUpdates(
            receivedFirstPrompt: true, transferring: true, windowVisible: false))
        #expect(!handoff.canFinish(layout: layout, readyGeneration: nil, context: context))

        layout.lastStartedBlockID = "pane-2"
        let completed = handoff.canFinish(layout: layout, readyGeneration: nil, context: context)
        #expect(completed)
        #expect(!CommandInputSession.requiresGeometryUpdates(
            receivedFirstPrompt: true, transferring: !completed, windowVisible: false))
        #expect(CommandInputSession.requiresGeometryUpdates(
            receivedFirstPrompt: true, transferring: !completed, windowVisible: true))
    }

    @MainActor
    @Test func geometryPollingStaysDormantBeforeStartupAndAfterOccludedTransfer() {
        #expect(!CommandInputSession.requiresGeometryUpdates(
            receivedFirstPrompt: false, transferring: false, windowVisible: true))
        #expect(!CommandInputSession.requiresGeometryUpdates(
            receivedFirstPrompt: true, transferring: false, windowVisible: false))
        var alternate = CommandTerminalLayout()
        alternate.primary = false
        let completed = handoff.canFinish(layout: alternate, readyGeneration: nil, context: "start")
        #expect(completed)
        #expect(!CommandInputSession.requiresGeometryUpdates(
            receivedFirstPrompt: true, transferring: !completed, windowVisible: false))
    }

    @MainActor
    @Test func primaryShellOwnershipChangesPublishRendererPolicy() throws {
        // No surface is attached: this exercises snapshot publication without
        // starting polling, launching a shell, or manipulating a live window.
        let session = try CommandInputSession()
        let context = "start"
        var notifications = 0
        session.onChange = { notifications += 1 }
        func snapshot(_ kind: String, context: String) -> CommandInputBridge.Snapshot {
            .init(state: .init(kind: kind, generation: "prompt-1", context: context, blockID: "123-1"),
                  receipt: nil, metadata: [:])
        }
        session.receive(snapshot("ready", context: "start"))
        #expect(session.hasNativeIntegration)
        #expect(session.prefersNativeInput)
        session.receive(snapshot("terminal", context: context))
        #expect(!session.prefersNativeInput)
        let terminalStatus = session.status
        let terminalVisibility = session.editorVisible
        notifications = 0

        // Finishing a shell-owned line can leave every visible label and frame
        // unchanged. The renderer must still re-arm prompt cursor suppression
        // before D/A arrives while the shell performs its next precmd hooks.
        session.receive(snapshot("running", context: context))
        #expect(session.status == terminalStatus)
        #expect(session.editorVisible == terminalVisibility)
        #expect(session.prefersNativeInput)
        #expect(!session.isEditable)
        #expect(notifications == 1)

        session.receive(snapshot("running", context: context))
        #expect(notifications == 1)
    }

    @MainActor
    @Test func draftChangesStillPublishRecoveryNoticeAndRetainedText() throws {
        let session = try CommandInputSession()
        session.receive(.init(state: .init(kind: "ready", generation: "prompt-1", context: "start", blockID: "123-1"),
                              receipt: nil, metadata: [:]))
        session.setDraft("retained draft")
        session.receive(.init(state: nil, receipt: nil, metadata: [:]))
        #expect(!session.isEditable)
        #expect(session.notice != nil)
        var notifications = 0
        session.onChange = { notifications += 1 }

        // An empty draft removes the unavailable-bridge notice and its View
        // Draft action. Restoring text must make recovery available again.
        session.setDraft("")
        #expect(session.notice == nil)
        #expect(notifications == 1)
        session.setDraft("recover this")
        #expect(session.notice != nil)
        #expect(notifications == 2)

        session.showRecoveryDraft()
        #expect(session.isRecoveringDraft)
        notifications = 0
        session.setDraft("updated retained draft")
        #expect(session.draft == "updated retained draft")
        #expect(notifications == 1)
        session.setDraft("updated retained draft")
        #expect(notifications == 1)
    }

    @MainActor
    @Test(arguments: ["cont", "vared"])
    func secondaryShellOwnershipLeavesCursorTransitionsToTheParser(context: String) throws {
        let session = try CommandInputSession()
        func snapshot(_ kind: String, generation: String, context: String) -> CommandInputBridge.Snapshot {
            .init(state: .init(kind: kind, generation: generation, context: context, blockID: "123-1"),
                  receipt: nil, metadata: [:])
        }
        session.receive(snapshot("ready", generation: "prompt-1", context: "start"))
        session.receive(snapshot("terminal", generation: "prompt-2", context: context))
        #expect(!session.editorVisible)
        #expect(!session.isEditable)
        // C or P already gives the secondary editor its real terminal caret.
        // Keep automatic native ownership armed so D/A takes it back even if
        // filesystem events coalesce and omit the intermediate running state.
        #expect(session.prefersNativeInput)
        session.receive(snapshot("ready", generation: "prompt-3", context: "start"))
        #expect(session.editorVisible)
        #expect(session.isEditable)
        #expect(session.prefersNativeInput)

        // Explicit terminal mode is a separate, persistent user preference.
        session.useTerminal()
        session.receive(snapshot("terminal", generation: "prompt-4", context: context))
        #expect(!session.prefersNativeInput)
        session.receive(snapshot("ready", generation: "prompt-5", context: "start"))
        #expect(!session.prefersNativeInput)
        #expect(!session.editorVisible)
        #expect(session.canReturnToEditor)
    }

    @Test func chromeKeepsCommandMetadataWithItsIdentity() throws {
        var layout = CommandTerminalLayout()
        layout.blocks = [block("second", flags: 3), block("first", flags: 15, complete: true)]
        let metadata = [
            "first": self.metadata("first", directory: "/fixture/first", status: "completed", exitStatus: 2),
            "second": self.metadata("second", directory: "/fixture/second", status: "running")
        ]
        let presentation = CommandChromePresentation(layout: layout, metadata: metadata, currentID: "second",
                                                     pinnedOffset: -1, recovering: false)
        let first = try #require(presentation.rows.first { $0.id == "first" })
        let second = try #require(presentation.rows.first { $0.id == "second" })
        #expect(first.label == "/fixture/first")
        #expect(first.suffix == "exit 2")
        #expect(!first.current)
        #expect(second.label == "/fixture/second")
        #expect(second.suffix == "running")
        #expect(second.current)
    }

    @Test func scrollingAndReflowDoNotChangeChromeCaptions() throws {
        var layout = CommandTerminalLayout()
        layout.blocks = [block("first", flags: 3)]
        var metadata = ["first": self.metadata("first", directory: "/fixture/project", status: "running")]
        let before = CommandChromePresentation(layout: layout, metadata: metadata, currentID: "first",
                                              pinnedOffset: -1, recovering: false)
        // The renderer owns placement. Scrolling, wrapping, and cell geometry
        // alone must not resend identical text through the GUI boundary.
        layout.atBottom = false
        layout.columns = 40
        layout.rows = 18
        layout.cellHeight = 24
        layout.cursorY = 360
        layout.blocks = [CommandBlockAnchor(id: "first", flags: 7, headerY: -48, inputY: -24,
                                           outputY: 0, endY: 384, complete: false)]
        let moved = CommandChromePresentation(layout: layout, metadata: metadata, currentID: "first",
                                             pinnedOffset: -1, recovering: false)
        #expect(moved == before)
        let scaled = CommandChromePresentation(layout: layout, metadata: metadata, currentID: "first",
                                              pinnedOffset: -1, recovering: false, backingScale: 2)
        #expect(scaled != moved)
        #expect(scaled.rows == moved.rows)

        metadata["first"] = self.metadata("first", directory: "/fixture/project", status: "completed", exitStatus: 0)
        let finished = CommandChromePresentation(layout: layout, metadata: metadata, currentID: "first",
                                                pinnedOffset: -1, recovering: false)
        #expect(finished != moved)
        #expect(try #require(finished.rows.first).label == before.rows.first?.label)
        #expect(try #require(finished.rows.first).suffix == "✓")
    }

    @Test func boundedChromeBatchRetainsTheCurrentPrompt() {
        var layout = CommandTerminalLayout()
        layout.blocks = (0..<200).map { block("block-\($0)", flags: 3) }
        let presentation = CommandChromePresentation(layout: layout, metadata: [:], currentID: "block-199",
                                                     pinnedOffset: 54, recovering: false)
        #expect(presentation.rows.count <= 128)
        #expect(Set(presentation.rows.map(\.id)).count == presentation.rows.count)
        #expect(presentation.rows.filter(\.current).map(\.id) == ["block-199"])
        #expect(presentation.rows.filter(\.pinned).map(\.id) == ["block-199"])
    }

    @Test func pinningAndRecoveryAffectOnlyTheCurrentDraft() throws {
        var layout = CommandTerminalLayout()
        layout.blocks = [block("previous", flags: 15, complete: true)]
        let metadata = [
            "previous": self.metadata("previous", directory: "/fixture/previous", status: "completed", exitStatus: 0),
            "current": self.metadata("current", directory: "/fixture/current", status: "editing")
        ]
        // The current block may be offscreen while its draft remains pinned.
        let pinned = CommandChromePresentation(layout: layout, metadata: metadata, currentID: "current",
                                              pinnedOffset: 54, recovering: false)
        #expect(pinned.rows.filter(\.pinned).map(\.id) == ["current"])
        let inline = CommandChromePresentation(layout: layout, metadata: metadata, currentID: "current",
                                              pinnedOffset: -1, recovering: false)
        #expect(!inline.rows.contains { $0.pinned })
        let recovering = CommandChromePresentation(layout: layout, metadata: metadata, currentID: "current",
                                                  pinnedOffset: 54, recovering: true)
        #expect(try #require(recovering.rows.first { $0.id == "current" }).label == "Retained draft (read only)")
        #expect(recovering.rows.first { $0.id == "previous" } == pinned.rows.first { $0.id == "previous" })
        #expect(metadata["current"]?.workingDirectory == "/fixture/current")
        layout.primary = false
        let alternate = CommandChromePresentation(layout: layout, metadata: metadata, currentID: "current",
                                                 pinnedOffset: -1, recovering: false)
        #expect(!alternate.enabled)
    }

    private func metadata(_ id: String, directory: String, status: String, exitStatus: Int? = nil) -> CommandBlockMetadata {
        CommandBlockMetadata(id: id, workingDirectory: directory, branch: "", status: status,
                             exitStatus: exitStatus, elapsed: nil)
    }

    private func block(_ id: String, flags: UInt32, complete: Bool = false) -> CommandBlockAnchor {
        CommandBlockAnchor(id: id, flags: flags, headerY: 0, inputY: 18,
                           outputY: 36, endY: 54, complete: complete)
    }
}
