import Testing
import AppKit
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

    @Test func fastCommandWaitsForItsNewPrimaryPromptToParse() {
        var layout = parsedPrompt("pane-2")
        layout.lastStartedBlockID = "pane-2"
        #expect(!handoff.canFinish(layout: layout, readyGeneration: "prompt-3",
                                  readyBlockID: "pane-3", context: "start"))
        layout.lastPrimaryInputBlockID = "pane-3"
        // Readiness is durable even with no drawable block anchors.
        #expect(layout.blocks.isEmpty)
        #expect(handoff.canFinish(layout: layout, readyGeneration: "prompt-3",
                                 readyBlockID: "pane-3", context: "start"))
    }

    @Test func sameBatchOutputAndNextPromptWaitForTheReadyFile() {
        var layout = parsedPrompt("pane-2")
        layout.lastStartedBlockID = "pane-2"
        // C alone must still give read/vared and foreground programs input.
        #expect(handoff.canFinish(layout: layout, readyGeneration: nil, context: "start"))
        layout.lastPrimaryInputBlockID = "pane-3"
        #expect(!handoff.canFinish(layout: layout, readyGeneration: nil, context: "start"))
        #expect(!handoff.canFinish(layout: layout, readyGeneration: "prompt-2",
                                  readyBlockID: "pane-2", context: "start"))
        #expect(handoff.canFinish(layout: layout, readyGeneration: "prompt-3",
                                 readyBlockID: "pane-3", context: "start"))
        #expect(handoff.canFinish(layout: layout, readyGeneration: nil, context: "cont"))
        layout.primary = false
        #expect(handoff.canFinish(layout: layout, readyGeneration: nil, context: "start"))
    }

    @Test func parsedPrimaryPromptNeedsGridDimensionsButAllowsScrollback() {
        var layout = parsedPrompt("pane-3")
        #expect(layout.hasParsedPrimaryInput("pane-3"))
        #expect(!layout.hasParsedPrimaryInput("pane-2"))
        layout.cursorValid = false
        layout.atBottom = false
        #expect(layout.hasParsedPrimaryInput("pane-3"))
        layout.rows = 0
        #expect(!layout.hasParsedPrimaryInput("pane-3"))
    }

    @MainActor
    @Test func startupAndLaterReadyWaitForTheirOwnParsedPrompt() throws {
        let session = try CommandInputSession()
        func ready(_ id: String) -> CommandInputBridge.Snapshot {
            .init(state: .init(kind: "ready", generation: id, context: "start", blockID: id),
                  receipt: nil, metadata: [:])
        }
        session.receive(ready("123-1"))
        #expect(session.presentedBlockID == nil)
        #expect(!session.editorVisible)
        #expect(!session.isEditable)
        session.receiveLayout(parsedPrompt("123-1"))
        #expect(session.presentedBlockID == "123-1")
        #expect(session.editorVisible)
        #expect(session.isEditable)
        var scrolled = parsedPrompt("123-1")
        scrolled.cursorValid = false
        scrolled.atBottom = false
        session.receiveLayout(scrolled)
        #expect(session.editorVisible)
        #expect(session.isEditable)
        session.receive(ready("123-2"))
        #expect(session.currentBlockID == "123-2")
        #expect(session.presentedBlockID == "123-1")
        #expect(!session.editorVisible)
        #expect(!session.isEditable)
        session.receiveLayout(parsedPrompt("123-2"))
        #expect(session.presentedBlockID == "123-2")
        #expect(session.editorVisible)
        #expect(session.isEditable)
    }

    @MainActor
    @Test func explicitEditorReturnPresentsTheLatestParsedPrompt() throws {
        let session = try CommandInputSession()
        func ready(_ id: String) -> CommandInputBridge.Snapshot {
            .init(state: .init(kind: "ready", generation: id, context: "start", blockID: id),
                  receipt: nil, metadata: [:])
        }
        session.receiveLayout(parsedPrompt("123-1"))
        session.receive(ready("123-1"))
        session.useTerminal()
        session.receive(ready("123-2"))
        session.receiveLayout(parsedPrompt("123-2"))
        #expect(session.presentedBlockID == "123-1")
        #expect(!session.editorVisible)
        session.useEditor()
        #expect(session.presentedBlockID == "123-2")
        #expect(session.editorVisible)
        #expect(session.isEditable)
    }

    private func parsedPrompt(_ id: String) -> CommandTerminalLayout {
        var layout = CommandTerminalLayout()
        layout.cursorValid = true
        layout.columns = 80
        layout.rows = 24
        layout.lastPrimaryInputBlockID = id
        return layout
    }

    @MainActor @Test func scrollingOwnedPromptOnlyPublishesPresentedGeometry() throws {
        let session = try CommandInputSession()
        var layout = parsedPrompt("block")
        layout.nativeBlockID = "block"
        layout.nativeGeneration = "prompt"
        session.receiveLayout(layout)
        session.receive(.init(state: .init(kind: "ready", generation: "prompt", context: "start", blockID: "block"),
                              receipt: nil, metadata: [:]))
        session.nativeInputPresented(blockID: nil, serial: 1, promptID: "block", generation: "prompt")
        #expect(session.isEditable)
        var geometryUpdates = 0
        var stateUpdates = 0
        var focusUpdates = 0
        session.onGeometryPresented = { geometryUpdates += 1 }
        session.onChange = { stateUpdates += 1 }
        session.onPromptPresented = { focusUpdates += 1 }
        for serial in 2...121 {
            let geometry = CommandPromptGeometry(generation: "prompt", cursorValid: true,
                cursor: CGPoint(x: 12, y: 500 - serial), viewport: CGSize(width: 800, height: 600), columns: 80, rows: 24)
            session.nativeInputPresented(blockID: nil, serial: UInt64(serial), promptID: "block", generation: "prompt",
                                         geometry: geometry)
            #expect(session.presentedGeometry == geometry)
        }
        #expect(geometryUpdates == 120)
        #expect(stateUpdates == 0)
        #expect(focusUpdates == 0)
        #expect(session.isEditable)
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
        session.receiveLayout(parsedPrompt("123-1"))
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

    @Test func newMarkerWaitsForItsOwnMetadataWithoutInventingACaption() {
        var layout = CommandTerminalLayout()
        layout.blocks = [block("previous", flags: 15, complete: true), block("next", flags: 3)]
        var metadata = ["previous": self.metadata("previous", directory: "/fixture/previous", status: "completed")]
        let pending = CommandChromePresentation(layout: layout, metadata: metadata, currentID: "next",
                                               pinnedOffset: 54, recovering: false)
        #expect(pending.rows.map(\.id) == ["previous"])
        #expect(pending.rows.first?.label == "/fixture/previous")
        #expect(!pending.rows.contains { $0.pinned })
        metadata["next"] = self.metadata("next", directory: "/fixture/new-directory", status: "editing")
        let available = CommandChromePresentation(layout: layout, metadata: metadata, currentID: "next",
                                                 pinnedOffset: 54, recovering: false)
        #expect(available.rows.first == pending.rows.first)
        #expect(available.rows.last?.label == "/fixture/new-directory")
        #expect(available.rows.last?.pinned == true)
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
        let metadata = Dictionary(uniqueKeysWithValues: (0..<200).map { index in
            let id = "block-\(index)"
            return (id, self.metadata(id, directory: "/fixture/\(index)", status: "editing"))
        })
        let presentation = CommandChromePresentation(layout: layout, metadata: metadata, currentID: "block-199",
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

@MainActor
struct OrderedNativePromptTests {
    private func prompt(_ id: String, generation: String, revision: UInt64) -> CommandTerminalLayout {
        var layout = CommandTerminalLayout()
        layout.columns = 80
        layout.rows = 24
        layout.cursorValid = true
        layout.lastPrimaryInputBlockID = id
        layout.nativeStateRevision = revision
        layout.nativeState = .ready
        layout.nativeBlockID = id
        layout.nativeGeneration = generation
        layout.nativeContextStart = true
        layout.nativeWorkingDirectory = "/tmp"
        return layout
    }

    @Test func orderedReadyNeedsItsActualFrameAndIgnoresStaleFiles() throws {
        let session = try CommandInputSession()
        let first = prompt("12-1", generation: "12-3", revision: 1)
        session.receiveLayout(first)
        #expect(!session.isEditable)
        #expect(!session.editorVisible)
        #expect(session.canPrepareNativePrompt)
        session.nativeInputPresented(blockID: nil, serial: 1, promptID: "12-1", generation: "12-3")
        #expect(session.isEditable)
        #expect(session.editorVisible)
        #expect(session.blockMetadata["12-1"]?.workingDirectory == "/tmp")
        session.receive(.init(state: .init(kind: "ready", generation: "12-0", context: "start", blockID: "12-0"),
                              receipt: nil, metadata: [:]))
        #expect(session.currentBlockID == "12-1")
        #expect(session.isEditable)
        let next = prompt("12-2", generation: "12-4", revision: 2)
        session.receiveLayout(next)
        #expect(!session.isEditable)
        #expect(!session.editorVisible)
        #expect(session.canPrepareNativePrompt)
        session.nativeInputPresented(blockID: "12-1", serial: 2, promptID: "12-1", generation: "12-3")
        #expect(!session.isEditable)
        session.nativeInputPresented(blockID: "12-1", serial: 3, promptID: "12-2", generation: "12-4")
        #expect(session.isEditable)
        #expect(session.presentedBlockID == "12-2")
    }

    @Test func typeAheadWaitsForMatchingFrameAndInterruptCancelsIt() throws {
        let session = try CommandInputSession()
        var first = prompt("12-1", generation: "12-3", revision: 1)
        first.lastPrimaryInputBlockID = nil
        session.receiveLayout(first)
        #expect(!session.canPrepareNativePrompt)
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                              timestamp: 1, windowNumber: 0, context: nil,
                                              characters: "a", charactersIgnoringModifiers: "a",
                                              isARepeat: false, keyCode: 0))
        var replayed: [String] = []
        session.onReplayPromptKey = { event, _ in replayed.append(event.characters ?? "") }
        #expect(session.deferPromptKey(key))
        first.lastPrimaryInputBlockID = "12-1"
        session.receiveLayout(first)
        #expect(session.canPrepareNativePrompt)
        session.nativeInputPresented(blockID: nil, serial: 1, promptID: "12-0", generation: "12-2")
        #expect(replayed.isEmpty)
        session.nativeInputPresented(blockID: nil, serial: 2, promptID: "12-1", generation: "12-3")
        #expect(replayed == ["a"])
        #expect(!session.deferPromptKey(key))
        session.receiveLayout(prompt("12-2", generation: "12-4", revision: 2))
        #expect(session.deferPromptKey(key))
        let interrupt = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
                                                    timestamp: 2, windowNumber: 0, context: nil,
                                                    characters: "\u{3}", charactersIgnoringModifiers: "c",
                                                    isARepeat: false, keyCode: 8))
        #expect(!session.deferPromptKey(interrupt))
        session.nativeInputPresented(blockID: nil, serial: 3, promptID: "12-2", generation: "12-4")
        #expect(replayed == ["a"])
        session.receiveLayout(prompt("12-3", generation: "12-5", revision: 3))
        #expect(session.deferPromptKey(key))
        session.useTerminal()
        #expect(replayed == ["a", "a"])
    }

    @Test func runningStateCannotBeRevivedByAnOlderReadyFile() throws {
        let session = try CommandInputSession()
        var layout = prompt("12-1", generation: "12-3", revision: 1)
        session.receiveLayout(layout)
        session.nativeInputPresented(blockID: nil, serial: 1, promptID: "12-1", generation: "12-3")
        layout.nativeState = .running
        layout.nativeStateRevision = 2
        session.receiveLayout(layout)
        session.receive(.init(state: .init(kind: "ready", generation: "12-3", context: "start", blockID: "12-1"),
                              receipt: nil, metadata: [:]))
        #expect(!session.isEditable)
        #expect(!session.editorVisible)
    }
}
