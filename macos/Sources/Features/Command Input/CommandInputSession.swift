import AppKit
import Foundation

/// Opt-in, local-zsh prototype. The native draft never travels through a paste API.
/// The shell accepts a generation-bound file from a dedicated ZLE key widget.
@MainActor
final class CommandInputSession {
    private static let maximumBytes = 1_048_576

    let directory: URL
    private let bridge: CommandInputBridge
    private weak var surfaceView: Ghostty.SurfaceView?
    private var pollingTask: Task<Void, Never>?
    private var submissionTask: Task<Void, Never>?
    private var generation: String?
    private var acceptedGeneration: String?
    private var pending: Pending?
    private var terminalRequested = false
    private var recoveryVisible = false
    private var receivedFirstPrompt = false
    private var failed = false
    private var ready = false
    private let launchedAt = Date()
    private var focusSequence: UInt64 = 0

    private(set) var draft = ""
    private(set) var status = "Starting isolated zsh…"
    private(set) var focusRequest: UInt64 = 0
    private(set) var editorVisible = true

    var isEditable: Bool { ready && !terminalRequested && pending == nil && !failed }
    var canReturnToEditor: Bool { ready && pending == nil && !failed }

    private struct Pending {
        let id: String
        let generation: String
        let started: Date
    }

    init() throws {
        guard let script = Bundle.main.url(forResource: "native-input", withExtension: "zsh") else {
            throw BridgeError.unavailable("The native-input.zsh app resource is missing.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("patina-ghostty-input-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        do {
            // The controlled starter shell deliberately does not source the user's .zshrc.
            // Quote the bundle path as data; submitted command text never enters this file.
            let quoted = "'" + script.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let startup = "source \(quoted)\n"
            try Data(startup.utf8).write(to: directory.appendingPathComponent(".zshrc"), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        self.directory = directory
        self.bridge = CommandInputBridge(directory: directory)
    }

    deinit {
        pollingTask?.cancel()
        submissionTask?.cancel()
        // This directory belongs only to this surface. No user shell files are changed.
        try? FileManager.default.removeItem(at: directory)
    }

    func configure(_ configuration: inout Ghostty.SurfaceConfiguration) {
        configuration.command = "/bin/zsh --no-globalrcs -i"
        configuration.initialInput = nil
        configuration.environmentVariables["ZDOTDIR"] = directory.path
        configuration.environmentVariables["PATINA_NATIVE_INPUT_DIR"] = directory.path
    }

    func attach(to surfaceView: Ghostty.SurfaceView) {
        self.surfaceView = surfaceView
        let bridge = self.bridge
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await bridge.snapshot()
                guard !Task.isCancelled else { break }
                self?.receive(snapshot)
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    break
                }
            }
        }
    }

    func setDraft(_ value: String) {
        guard value != draft else { return }
        draft = value
        changed()
    }

    @discardableResult
    func submit(_ text: String) -> Bool {
        guard isEditable, let generation, let surfaceView, !surfaceView.readonly else { return false }
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

        let request = Pending(id: UUID().uuidString, generation: generation, started: Date())
        pending = request
        status = "Submitting…"
        changed()
        submissionTask = Task { [weak self, bridge] in
            do {
                try await bridge.submit(text: text, generation: request.generation, id: request.id)
                guard let self, self.pending?.id == request.id, !Task.isCancelled else { return }
                // This action writes only the dedicated widget trigger, never the command.
                // Its shell widget validates the private file's prompt generation again.
                guard let model = self.surfaceView?.surfaceModel,
                      model.perform(action: "text:\\x1b[99;1~") else {
                    throw BridgeError.unavailable("The terminal rejected the submit trigger.")
                }
                self.focusTerminal()
            } catch {
                guard let self, self.pending?.id == request.id else { return }
                self.pending = nil
                self.failed = true
                self.ready = false
                self.status = "Submission stopped: \(error.localizedDescription) Draft preserved."
                self.changed()
            }
        }
        return true
    }

    func useTerminal() {
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
        status = "Native input · isolated local zsh"
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
        if surfaceView?.childExitedMessage != nil {
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
                recoveryVisible = false
                draft = ""
                editorVisible = false
                focusRequest = 0
                status = "Running · keyboard input goes to the terminal"
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
                    status = "Native input · isolated local zsh"
                    if shouldFocus, let view = surfaceView,
                       view.window?.isKeyWindow == true,
                       view.window?.firstResponder === view {
                        requestEditorFocus()
                    }
                }
                receivedFirstPrompt = true
            } else if !ready && pending == nil && !failed {
                editorVisible = recoveryVisible
                focusRequest = 0
                status = state.context == "cont"
                    ? "Incomplete command · finish or cancel it in the terminal"
                    : "Terminal input · a program or shell editor owns the keyboard"
            }
        } else if receivedFirstPrompt {
            ready = false
            editorVisible = recoveryVisible
            focusRequest = 0
            status = "Shell bridge unavailable · draft preserved"
        } else if Date().timeIntervalSince(launchedAt) > 5 {
            ready = false
            failed = true
            status = "Shell bridge did not start · use terminal input"
        }
        if presentationKey != previous { changed() }
    }

    private struct Presentation: Equatable {
        let status: String
        let editable: Bool
        let visible: Bool
        let focusRequest: UInt64
        let draft: String
    }

    private var presentationKey: Presentation {
        Presentation(status: status, editable: isEditable, visible: editorVisible,
                     focusRequest: focusRequest, draft: draft)
    }

    private func focusTerminal() {
        guard let view = surfaceView, let window = view.window, window.isKeyWindow else { return }
        window.makeFirstResponder(view)
    }

    private func requestEditorFocus() {
        // A fast command can hide and show the editor within one polling turn.
        // The request must differ from the previous view's token even when an
        // intermediate zero was never rendered by SwiftUI.
        focusSequence &+= 1
        focusRequest = focusSequence
    }

    private func changed() {
        surfaceView?.commandInputRevision &+= 1
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
    }

    struct Receipt: Sendable {
        let id: String
        let accepted: Bool
        let reason: String
    }

    struct Snapshot: Sendable {
        let state: State?
        let receipt: Receipt?
    }

    let directory: URL

    init(directory: URL) { self.directory = directory }

    func snapshot() -> Snapshot {
        let stateFields = fields("state")
        let receiptFields = fields("receipt")
        let state: State? = stateFields.count == 3
            ? State(kind: stateFields[0], generation: stateFields[1], context: stateFields[2]) : nil
        let receipt: Receipt? = receiptFields.count >= 2
            ? Receipt(id: receiptFields[1], accepted: receiptFields[0] == "accepted",
                      reason: receiptFields.count > 2 ? receiptFields[2] : "unknown") : nil
        return Snapshot(state: state, receipt: receipt)
    }

    func submit(text: String, generation: String, id: String) throws {
        let state = fields("state")
        guard state == ["ready", generation, "start"] else {
            throw BridgeError.unavailable("The shell is no longer at the same empty prompt.")
        }
        let payload = Data("\(generation)\n\(id)\n\(text)".utf8)
        try payload.write(to: directory.appendingPathComponent("request"), options: .atomic)
    }

    private func fields(_ name: String) -> [String] {
        let url = directory.appendingPathComponent(name)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 4096,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
    }
}
