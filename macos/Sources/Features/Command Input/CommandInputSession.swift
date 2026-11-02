import AppKit
import Foundation
import CoreText
import GhosttyKit

/// Native editing for the user's zsh. The draft never travels through a paste API.
/// The shell accepts a generation-bound file from a dedicated ZLE key widget.
@MainActor
final class CommandInputSession {
    private static let maximumBytes = 1_048_576

    var onChange: (() -> Void)?
    var onCompletion: ((CommandCompletionResponse) -> Void)?
    private var hasEditorFont = false

    let directory: URL
    private let bridge: CommandInputBridge
    private let completionBridge: CommandCompletionBridge
    private var completionTask: Task<Void, Never>?
    private weak var surfaceView: Ghostty.SurfaceView?
    private var pollingTask: Task<Void, Never>?
    private var fileEvents: CommandInputFileEvents?
    private var deadlineTask: Task<Void, Never>?
    private var geometryTask: Task<Void, Never>?
    private var submissionTask: Task<Void, Never>?
    private var generation: String?
    private var acceptedGeneration: String?
    private var pending: Pending?
    private var handoff: CommandInputHandoff?
    private var shellContext = "start"
    private var terminalRequested = false
    private var recoveryVisible = false
    private var receivedFirstPrompt = false
    private var failed = false
    private var ready = false
    private let launchedAt = Date()
    private var focusSequence: UInt64 = 0

    private(set) var draft = ""
    private(set) var status = "Starting shell…"
    private(set) var focusRequest: UInt64 = 0
    private(set) var editorVisible = false
    private(set) var layout = CommandTerminalLayout()
    private(set) var blockMetadata: [String: CommandBlockMetadata] = [:]
    private(set) var currentBlockID: String?
    private(set) var editorFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    var notice: String? {
        if failed || (!ready && pending == nil && handoff == nil && !draft.isEmpty)
            || status.hasPrefix("Command exceeds") || status.hasPrefix("Remove control") {
            return status
        }
        return nil
    }

    var isEditable: Bool { ready && !terminalRequested && pending == nil && handoff == nil && !failed }
    var canReturnToEditor: Bool { ready && pending == nil && handoff == nil && !failed }
    var isRecoveringDraft: Bool { recoveryVisible }
    var isTransferringSubmission: Bool { !failed && (pending != nil || handoff != nil) }

    private struct Pending {
        let id: String
        let generation: String
        let blockID: String
        let started: Date
    }

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("patina-ghostty-input-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        do {
            try CommandShellStartup.prepare(in: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        self.directory = directory
        self.bridge = CommandInputBridge(directory: directory)
        self.completionBridge = CommandCompletionBridge(directory: directory)
    }

    deinit {
        pollingTask?.cancel()
        deadlineTask?.cancel()
        geometryTask?.cancel()
        submissionTask?.cancel()
        completionTask?.cancel()
        // This directory belongs only to this surface. No user shell files are changed.
        try? FileManager.default.removeItem(at: directory)
    }

    func configure(_ configuration: inout Ghostty.SurfaceConfiguration) {
        // Core shell detection attaches our bootstrap after environment
        // overrides. Preserve the user's command, initial input and ZDOTDIR.
        configuration.environmentVariables["PATINA_NATIVE_INPUT_DIR"] = directory.path
    }

    func attach(to surfaceView: Ghostty.SurfaceView) {
        self.surfaceView = surfaceView
        let bridge = self.bridge
        let fileEvents = CommandInputFileEvents(directory: directory)
        self.fileEvents = fileEvents
        let events = fileEvents.events
        pollingTask = Task { [weak self] in
            for await _ in events {
                guard !Task.isCancelled else { break }
                let ids = self?.layout.blocks.map(\.id) ?? []
                let snapshot = await bridge.snapshot(visibleBlockIDs: ids)
                guard !Task.isCancelled else { break }
                self?.receive(snapshot)
                self?.fileEvents?.updateLiveBlock(snapshot.state?.blockID)
            }
        }
        scheduleDeadline(after: max(0.05, 5.05 - Date().timeIntervalSince(launchedAt)))
        geometryTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshGeometry()
                do {
                    try await Task.sleep(for: .milliseconds(33))
                } catch {
                    break
                }
            }
        }
    }

    func setDraft(_ value: String) {
        guard value != draft else { return }
        draft = value
        completionTask?.cancel()
        changed()
    }

    func requestCompletion(_ request: CommandCompletionRequest) {
        completionTask?.cancel()
        guard isEditable, let generation, request.text == draft, surfaceView?.readonly != true else {
            onCompletion?(.init(requestID: request.id, revision: request.revision, items: [],
                                message: "Completion is available at an empty shell prompt."))
            return
        }
        completionTask = Task { [weak self, completionBridge] in
            do {
                try await completionBridge.prepare(request, generation: generation)
                try Task.checkCancellation()
                guard let self, self.generation == generation, self.isEditable,
                      self.draft == request.text, let surfaceView = self.surfaceView,
                      let window = surfaceView.window, window.isKeyWindow,
                      let editor = window.firstResponder as? CommandTextView,
                      editor.string == request.text,
                      editor.selectedRange() == NSRange(location: request.cursorUTF16, length: 0),
                      (window.windowController as? BaseTerminalController)?.focusedSurface === surfaceView else {
                    await completionBridge.cancel(request.id)
                    self?.onCompletion?(.init(requestID: request.id, revision: request.revision, items: [],
                                             message: "Completion cancelled. Press Tab to try again."))
                    return
                }
                guard surfaceView.surfaceModel?.perform(action: "text:\\x1b[99;2~") == true else {
                    throw BridgeError.unavailable("The terminal rejected the completion request.")
                }
                for _ in 0..<150 {
                    try Task.checkCancellation()
                    if let response = try await completionBridge.response(to: request, generation: generation) {
                        guard !Task.isCancelled, self.isEditable,
                              self.generation == generation, self.draft == request.text else { return }
                        self.onCompletion?(response)
                        return
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                throw BridgeError.unavailable("Completion timed out. Press Tab to try again.")
            } catch {
                await completionBridge.cancel(request.id)
                guard !Task.isCancelled, let self, self.draft == request.text else { return }
                self.onCompletion?(.init(requestID: request.id, revision: request.revision,
                                         items: [], message: error.localizedDescription))
            }
        }
    }

    func cancelCompletion() {
        completionTask?.cancel()
    }

    @discardableResult
    func submit(_ text: String) -> Bool {
        guard isEditable, let generation, let blockID = currentBlockID,
              let surfaceView, !surfaceView.readonly else { return false }
        completionTask?.cancel()
        guard text.utf8.count <= Self.maximumBytes else {
            status = "Command exceeds the prototype's 1 MiB limit. Draft preserved."
            changed()
            return false
        }
        guard !text.unicodeScalars.contains(where: {
            ($0.value < 32 && $0.value != 9 && $0.value != 10) || $0.value == 127
        }) else {
            status = "Remove control characters before submitting. Tabs and newlines are supported."
            changed()
            return false
        }

        let request = Pending(id: UUID().uuidString, generation: generation, blockID: blockID, started: Date())
        pending = request
        scheduleDeadline(after: 5.05)
        status = "Submitting…"
        // Restore the PTY viewport behind the retained native draft. Keyboard
        // focus stays native until acceptance reaches the terminal transcript.
        changed()
        submissionTask = Task { [weak self, bridge] in
            do {
                // Return to the live prompt deliberately, then wait until the
                // terminal thread has applied the editor-driven viewport resize.
                _ = self?.surfaceView?.surfaceModel?.perform(action: "scroll_to_bottom")
                var applied = false
                for _ in 0..<50 {
                    guard let self, !Task.isCancelled else { return }
                    self.refreshGeometry()
                    if self.layoutMatchesSurfaceSize {
                        applied = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard applied else {
                    throw BridgeError.unavailable("The terminal is still resizing; submission was not sent.")
                }
                try await bridge.submit(text: text, generation: request.generation, id: request.id)
                guard let self, self.pending?.id == request.id, !Task.isCancelled else { return }
                // This action writes only the dedicated widget trigger, never the command.
                // Its shell widget validates the private file's prompt generation again.
                guard let model = self.surfaceView?.surfaceModel,
                      model.perform(action: "text:\\x1b[99;1~") else {
                    throw BridgeError.unavailable("The terminal rejected the submit trigger.")
                }
            } catch {
                guard let self, self.pending?.id == request.id else { return }
                self.pending = nil
                self.deadlineTask?.cancel()
                self.failed = true
                self.ready = false
                self.status = "Submission stopped: \(error.localizedDescription) Draft preserved."
                self.changed()
            }
        }
        return true
    }

    func useTerminal() {
        completionTask?.cancel()
        terminalRequested = true
        recoveryVisible = false
        editorVisible = false
        focusRequest = 0
        status = pending == nil ? "Terminal input · use the shell's history and completion here" : "Awaiting submission receipt…"
        focusTerminal()
        changed()
    }

    func useEditor() {
        guard canReturnToEditor, surfaceView?.readonly != true else { return }
        terminalRequested = false
        recoveryVisible = false
        editorVisible = true
        status = "Native input · zsh"
        _ = surfaceView?.surfaceModel?.perform(action: "scroll_to_bottom")
        requestEditorFocus()
        changed()
    }

    func showRecoveryDraft() {
        recoveryVisible = true
        editorVisible = true
        changed()
    }

    func focusEditorIfActive() -> Bool {
        guard editorVisible, isEditable else { return false }
        requestEditorFocus()
        changed()
        return true
    }

    private func receive(_ snapshot: CommandInputBridge.Snapshot) {
        let previous = presentationKey
        if blockMetadata != snapshot.metadata {
            blockMetadata = snapshot.metadata
            changed()
        }
        if surfaceView?.childExitedMessage != nil {
            handoff = nil
            ready = false
            editorVisible = recoveryVisible
            focusRequest = 0
            status = "Shell exited · draft preserved"
            if presentationKey != previous { changed() }
            return
        }
        if let pending, let receipt = snapshot.receipt, receipt.id == pending.id {
            self.pending = nil
            if receipt.accepted {
                acceptedGeneration = pending.generation
                handoff = CommandInputHandoff(blockID: pending.blockID, generation: pending.generation)
                recoveryVisible = false
                status = "Submitting…"
            } else {
                failed = true
                status = "Shell rejected submission (\(receipt.reason)). Draft preserved; use terminal input."
            }
        } else if let pending, Date().timeIntervalSince(pending.started) > 5 {
            // Unknown outcome: never replay. Keep the request identity so a late receipt
            // can still be recognized, but disable further native submissions.
            failed = true
            editorVisible = recoveryVisible
            focusRequest = 0
            status = "No submission receipt. Draft preserved; terminal input remains available."
        }

        if let state = snapshot.state {
            shellContext = state.context
            currentBlockID = state.blockID
            let newGeneration = generation != state.generation
            generation = state.generation
            // State and receipt are independent atomic files: a snapshot can
            // contain the old ready record and a new acceptance receipt. Never
            // reactivate that prompt; wait for a distinct ZLE generation.
            ready = state.kind == "ready" && state.context == "start"
                && state.generation != acceptedGeneration
            if ready && pending == nil && !failed {
                if !terminalRequested {
                    let shouldFocus = !receivedFirstPrompt || newGeneration
                    editorVisible = true
                    status = "Native input · zsh"
                    if shouldFocus, let view = surfaceView,
                       view.window?.isKeyWindow == true,
                       view.window?.firstResponder === view {
                        requestEditorFocus()
                    }
                }
                receivedFirstPrompt = true
            } else if !ready && pending == nil && !failed {
                editorVisible = recoveryVisible || (handoff != nil && !terminalRequested)
                if handoff == nil { focusRequest = 0 }
                status = state.context == "cont"
                    ? "Incomplete command · finish or cancel it in the terminal"
                    : "Terminal input · a program or shell editor owns the keyboard"
            }
        } else if receivedFirstPrompt {
            handoff = nil
            ready = false
            editorVisible = recoveryVisible
            focusRequest = 0
            status = "Shell bridge unavailable · draft preserved"
        } else if Date().timeIntervalSince(launchedAt) > 5 {
            ready = false
            // Other configured shells/commands use ordinary terminal input.
            // Slow user startup files can still attach when their prompt arrives.
            status = "Terminal input"
        }
        finishHandoffIfReady()
        if presentationKey != previous { changed() }
        if receivedFirstPrompt && pending == nil {
            deadlineTask?.cancel()
            deadlineTask = nil
        }
    }

    private struct Presentation: Equatable {
        let status: String
        let editable: Bool
        let visible: Bool
        let focusRequest: UInt64
        let draft: String
        let currentBlockID: String?
        let transferring: Bool
    }

    private var presentationKey: Presentation {
        Presentation(status: status, editable: isEditable, visible: editorVisible,
                     focusRequest: focusRequest, draft: draft, currentBlockID: currentBlockID,
                     transferring: isTransferringSubmission)
    }

    private func focusTerminal() {
        guard let view = surfaceView, let window = view.window, window.isKeyWindow else { return }
        if let controller = window.windowController as? BaseTerminalController,
           let focused = controller.focusedSurface, focused !== view { return }
        window.makeFirstResponder(view)
    }

    private func requestEditorFocus() {
        // A fast command can hide and show the editor within one polling turn.
        // The request must differ from the previous view's token even when an
        // intermediate zero was never observed by the editor.
        focusSequence &+= 1
        focusRequest = focusSequence
    }

    private func finishHandoffIfReady() {
        guard let handoff, handoff.canFinish(layout: layout, readyGeneration: ready ? generation : nil,
                                             context: shellContext) else { return }
        self.handoff = nil
        draft = ""
        editorVisible = ready && !terminalRequested
        if ready {
            status = "Native input · zsh"
        } else {
            status = shellContext == "cont" ? "Incomplete command · finish or cancel it in the terminal"
                : "Running · keyboard input goes to the terminal"
        }
        if editorVisible { requestEditorFocus() } else { focusRequest = 0 }
    }

    /// Timeouts do not wait for the slower recovery watchdog. Keep the existing
    /// five-second behavior even when the shell publishes no further events.
    private func scheduleDeadline(after seconds: TimeInterval) {
        deadlineTask?.cancel()
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.fileEvents?.requestRefresh()
        }
    }

    private var layoutMatchesSurfaceSize: Bool {
        guard let surface = surfaceView?.surface, layout.primary else { return false }
        let desired = ghostty_surface_size(surface)
        return layout.rows > 0 && layout.rows == desired.rows && layout.columns == desired.columns
    }

    private func refreshGeometry() {
        guard let surface = surfaceView?.surface else { return }
        let diagnostic = CommandInputDiagnostics.begin(.geometrySnapshot)
        defer { CommandInputDiagnostics.end(diagnostic) }
        let updated = CommandTerminalLayout.read(from: surface)
        guard updated != layout || !hasEditorFont else { return }
        CommandInputDiagnostics.record(.geometryChanged)
        if updated.blocks.map(\.id) != layout.blocks.map(\.id) {
            fileEvents?.requestRefresh()
        }
        if !hasEditorFont || updated.cellHeight != layout.cellHeight || updated.cellWidth != layout.cellWidth {
            if let raw = ghostty_surface_quicklook_font(surface) {
                let font = Unmanaged<CTFont>.fromOpaque(raw).takeRetainedValue()
                editorFont = font as NSFont
                hasEditorFont = true
            }
        }
        layout = updated
        finishHandoffIfReady()
        changed()
    }

    private func changed() {
        onChange?()
    }
}

/// A receipt precedes ZLE redisplay. Keep native presentation until the terminal
/// has parsed this command's output boundary, a continuation, or the next prompt.
struct CommandInputHandoff {
    let blockID: String
    let generation: String

    func canFinish(layout: CommandTerminalLayout, readyGeneration: String?, context: String) -> Bool {
        if !layout.primary || context == "cont" { return true }
        if let readyGeneration, readyGeneration != generation { return true }
        return layout.lastStartedBlockID == blockID
    }
}

private enum BridgeError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        }
    }
}

/// All recurring file I/O is off MainActor. Same-directory atomic renames publish
/// complete records. The directory is private and unique to one launched shell.
private actor CommandInputBridge {
    struct State: Sendable {
        let kind: String
        let generation: String
        let context: String
        let blockID: String
    }

    struct Receipt: Sendable {
        let id: String
        let accepted: Bool
        let reason: String
    }

    struct Snapshot: Sendable {
        let state: State?
        let receipt: Receipt?
        let metadata: [String: CommandBlockMetadata]
    }

    let directory: URL
    private var metadataCache: [String: CommandBlockMetadata] = [:]

    init(directory: URL) { self.directory = directory }

    func snapshot(visibleBlockIDs: [String]) -> Snapshot {
        let diagnostic = CommandInputDiagnostics.begin(.bridgeSnapshot)
        defer { CommandInputDiagnostics.end(diagnostic) }
        CommandInputDiagnostics.record(.bridgeSnapshotRequested)
        let stateFields = fields("state")
        let receiptFields = fields("receipt")
        let state: State? = stateFields.count == 4
            ? State(kind: stateFields[0], generation: stateFields[1], context: stateFields[2], blockID: stateFields[3]) : nil
        let receipt: Receipt? = receiptFields.count >= 2
            ? Receipt(id: receiptFields[1], accepted: receiptFields[0] == "accepted",
                      reason: receiptFields.count > 2 ? receiptFields[2] : "unknown") : nil
        var visibleMetadata: [String: CommandBlockMetadata] = [:]
        let ids = Set(visibleBlockIDs + [state?.blockID].compactMap { $0 })
        for id in ids where Self.validID(id) {
            if let cached = metadataCache[id], cached.completed {
                CommandInputDiagnostics.record(.bridgeCacheHit)
                visibleMetadata[id] = cached
                continue
            }
            let block = directory.appendingPathComponent("blocks").appendingPathComponent(id)
            guard let cwd = text(at: block.appendingPathComponent("cwd"), maximum: 16384) else { continue }
            let status = text(at: block.appendingPathComponent("status"))?.trimmingCharacters(in: .newlines) ?? "editing"
            let exitStatus = text(at: block.appendingPathComponent("exit-status"))
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let start = text(at: block.appendingPathComponent("started-wall"))
                .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let end = text(at: block.appendingPathComponent("finished-wall"))
                .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let elapsed: Double? = if let start, let end { max(0, end - start) } else { nil }
            let metadata = CommandBlockMetadata(
                id: id, workingDirectory: cwd,
                branch: text(at: block.appendingPathComponent("branch"))?.trimmingCharacters(in: .newlines) ?? "",
                status: status, exitStatus: exitStatus, elapsed: elapsed)
            metadataCache[id] = metadata
            visibleMetadata[id] = metadata
        }
        if metadataCache.count > 1024 {
            metadataCache = metadataCache.filter { ids.contains($0.key) }
        }
        return Snapshot(state: state, receipt: receipt, metadata: visibleMetadata)
    }

    func submit(text: String, generation: String, id: String) throws {
        let state = fields("state")
        guard state.count == 4, Array(state.prefix(3)) == ["ready", generation, "start"] else {
            throw BridgeError.unavailable("The shell is no longer at the same empty prompt.")
        }
        let payload = Data("\(generation)\n\(id)\n\(text)".utf8)
        try payload.write(to: directory.appendingPathComponent("request"), options: .atomic)
    }

    private func fields(_ name: String) -> [String] {
        let url = directory.appendingPathComponent(name)
        guard let text = text(at: url) else { return [] }
        return text.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64
            && id.utf8.allSatisfy { (48...57).contains($0) || $0 == 45 }
    }

    private func text(at url: URL, maximum: Int = 4096) -> String? {
        CommandInputDiagnostics.record(.bridgeFileRead)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= maximum,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        CommandInputDiagnostics.record(.bridgeFileBytes, amount: data.count)
        return text
    }
}
