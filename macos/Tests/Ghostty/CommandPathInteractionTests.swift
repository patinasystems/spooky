import AppKit
import Testing
@testable import Ghostty

@MainActor
struct CommandPathInteractionTests {
    @Test func coldOutputClickCopiesAfterValidationWithoutASecondPressOrFocusTransfer() async throws {
        let fixture = PathInteractionFixture()
        defer { fixture.window.close() }
        let editor = NSTextView(frame: fixture.view.bounds)
        fixture.view.addSubview(editor)
        #expect(fixture.window.makeFirstResponder(editor))
        fixture.probe = fixture.makeProbe(id: 1, kind: .output)
        let gate = PathValidationGate()
        let controller = fixture.controller(resolve: { await gate.resolve($0) })
        #expect(controller.claimsClick(at: NSPoint(x: 10, y: 20), modifiers: []))
        controller.mouseDown(with: try fixture.event(.leftMouseDown))
        controller.mouseUp(with: try fixture.event(.leftMouseUp))
        await gate.waitForRequest(1)
        #expect(fixture.copies.isEmpty && fixture.forwards.isEmpty)
        await gate.finish(1)
        await fixture.waitUntil { !fixture.copies.isEmpty }
        #expect(fixture.copies == ["/historic/cwd"])
        #expect(fixture.forwards.isEmpty)
        #expect(fixture.window.firstResponder === editor)
        #expect(await gate.requests == 1)
    }

    @Test func failedColdOutputClickReplaysBothRealSelectionEvents() async throws {
        let fixture = PathInteractionFixture()
        defer { fixture.window.close() }
        fixture.probe = fixture.makeProbe(id: 1, kind: .output)
        let gate = PathValidationGate()
        let controller = fixture.controller(resolve: { await gate.resolve($0) })
        controller.mouseDown(with: try fixture.event(.leftMouseDown))
        controller.mouseUp(with: try fixture.event(.leftMouseUp))
        await gate.waitForRequest(1)
        await gate.finish(1, succeeds: false)
        await fixture.waitUntil { fixture.forwards.count == 2 }
        #expect(fixture.forwards == [.leftMouseDown, .leftMouseUp])
        #expect(fixture.copies.isEmpty && fixture.opens.isEmpty)
    }

    @Test func coldClickResolvesItsOwnTokenWhenAnotherTokenInTheSameLineIsPending() async throws {
        let fixture = PathInteractionFixture()
        defer { fixture.window.close() }
        let gate = PathByteValidationGate()
        let controller = fixture.controller(resolve: { await gate.resolve($0) })
        fixture.probe = CommandPathProbe(id: 1, kind: .output, text: "one two", hoverByte: 1,
                                         uri: "", workingDirectory: "/historic")
        controller.update(at: NSPoint(x: 10, y: 20), modifiers: [])
        await gate.waitForRequest(1)
        fixture.probe = CommandPathProbe(id: 1, kind: .output, text: "one two", hoverByte: 5,
                                         uri: "", workingDirectory: "/historic")
        controller.mouseDown(with: try fixture.event(.leftMouseDown, x: 20))
        controller.mouseUp(with: try fixture.event(.leftMouseUp, x: 20))
        await gate.waitForRequest(5)
        await gate.finish(5, path: "/historic/two", start: 4)
        await fixture.waitUntil { !fixture.copies.isEmpty }
        await gate.finish(1, path: "/historic/one", start: 0)
        await Task.yield()
        #expect(fixture.copies == ["/historic/two"])
        #expect(fixture.forwards.isEmpty)
    }

    @Test func dragDuringColdValidationCannotCopyAfterSelectionStarts() async throws {
        let fixture = PathInteractionFixture()
        defer { fixture.window.close() }
        fixture.probe = fixture.makeProbe(id: 1, kind: .output)
        let gate = PathValidationGate()
        let controller = fixture.controller(resolve: { await gate.resolve($0) })
        controller.mouseDown(with: try fixture.event(.leftMouseDown))
        await gate.waitForRequest(1)
        controller.mouseDragged(with: try fixture.event(.leftMouseDragged, x: 30))
        controller.mouseUp(with: try fixture.event(.leftMouseUp, x: 30))
        await gate.finish(1)
        await Task.yield()
        #expect(fixture.forwards == [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
        #expect(fixture.copies.isEmpty && fixture.opens.isEmpty)
    }

    @Test func secondPressCancelsAnUnresolvedFirstCopyAndKeepsWordSelectionCount() async throws {
        let fixture = PathInteractionFixture()
        defer { fixture.window.close() }
        fixture.probe = fixture.makeProbe(id: 1, kind: .output)
        let gate = PathValidationGate()
        let controller = fixture.controller(resolve: { await gate.resolve($0) })
        controller.mouseDown(with: try fixture.event(.leftMouseDown))
        controller.mouseUp(with: try fixture.event(.leftMouseUp))
        await gate.waitForRequest(1)
        #expect(!controller.claimsClick(at: NSPoint(x: 10, y: 20), modifiers: [], clickCount: 2))
        #expect(controller.selectionClickCount(for: try fixture.event(.leftMouseDown, clickCount: 2)) == 2)
        await gate.finish(1)
        await Task.yield()
        #expect(fixture.copies.isEmpty && fixture.forwards.isEmpty)
    }

    @Test func slowFilesystemFailsOpenAndLateResolutionCannotCopy() async throws {
        let fixture = PathInteractionFixture()
        defer { fixture.window.close() }
        fixture.probe = fixture.makeProbe(id: 1, kind: .output)
        let gate = PathValidationGate()
        let controller = fixture.controller(resolve: { await gate.resolve($0) })
        controller.mouseDown(with: try fixture.event(.leftMouseDown))
        controller.mouseUp(with: try fixture.event(.leftMouseUp))
        await gate.waitForRequest(1)
        await fixture.waitUntil { fixture.forwards.count == 2 }
        #expect(fixture.forwards == [.leftMouseDown, .leftMouseUp])
        await gate.finish(1)
        await Task.yield()
        #expect(fixture.copies.isEmpty && fixture.opens.isEmpty)
    }

    @Test func completedClickCopiesAndModifierClickOpensWithoutTakingEditorFocus() throws {
        let fixture = PathInteractionFixture()
        defer { fixture.window.close() }
        let editor = NSTextView(frame: fixture.view.bounds)
        fixture.view.addSubview(editor)
        #expect(fixture.window.makeFirstResponder(editor))
        let controller = fixture.controller()
        controller.mouseDown(with: try fixture.event(.leftMouseDown))
        #expect(fixture.copies.isEmpty)
        controller.mouseUp(with: try fixture.event(.leftMouseUp))
        #expect(fixture.copies == ["/historic/cwd"])
        #expect(fixture.forwards.isEmpty)
        #expect(fixture.window.firstResponder === editor)
        for modifiers: NSEvent.ModifierFlags in [.command, .control] {
            controller.mouseDown(with: try fixture.event(.leftMouseDown, modifiers: modifiers))
            controller.mouseUp(with: try fixture.event(.leftMouseUp, modifiers: modifiers))
        }
        #expect(fixture.opens.count == 2)
        #expect(fixture.copies.count == 1)
        #expect(fixture.window.firstResponder === editor)
    }

    @Test func draggingReplaysThePressAndPreservesTerminalSelectionInsteadOfCopying() throws {
        let fixture = PathInteractionFixture()
        defer { fixture.window.close() }
        let controller = fixture.controller()
        controller.mouseDown(with: try fixture.event(.leftMouseDown))
        controller.mouseDragged(with: try fixture.event(.leftMouseDragged, x: 12))
        #expect(fixture.forwards.isEmpty)
        controller.mouseDragged(with: try fixture.event(.leftMouseDragged, x: 30))
        controller.mouseUp(with: try fixture.event(.leftMouseUp, x: 30))
        #expect(fixture.forwards == [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
        #expect(fixture.copies.isEmpty)
        #expect(fixture.opens.isEmpty)
    }

    @Test func changedOutputBetweenMouseDownAndMouseUpCannotCopyTheOldPath() throws {
        let fixture = PathInteractionFixture()
        defer { fixture.window.close() }
        let controller = fixture.controller()
        controller.mouseDown(with: try fixture.event(.leftMouseDown))
        fixture.probe = fixture.makeProbe(id: 2)
        controller.mouseUp(with: try fixture.event(.leftMouseUp))
        #expect(fixture.copies.isEmpty)
        #expect(fixture.opens.isEmpty)
    }

    @Test func changedWorkingDirectoryCannotReuseAnOldRelativePathValidation() throws {
        let fixture = PathInteractionFixture()
        defer { fixture.window.close() }
        let controller = fixture.controller()
        controller.mouseDown(with: try fixture.event(.leftMouseDown))
        fixture.probe = CommandPathProbe(id: 1, kind: .header, text: "cwd", hoverByte: 1,
                                         uri: "", workingDirectory: "/different/cwd")
        controller.mouseUp(with: try fixture.event(.leftMouseUp))
        #expect(fixture.copies.isEmpty && fixture.opens.isEmpty)
    }

    @Test func consumedPathPressHandsRealRepeatedClickCountsToTerminalSelection() throws {
        let fixture = PathInteractionFixture()
        defer { fixture.window.close() }
        let controller = fixture.controller()
        for count in 1...3 {
            #expect(controller.selectionClickCount(for: try fixture.event(.leftMouseDown, clickCount: count)) == nil)
        }

        controller.mouseDown(with: try fixture.event(.leftMouseDown))
        controller.mouseUp(with: try fixture.event(.leftMouseUp))
        #expect(fixture.copies == ["/historic/cwd"])
        for count in 2...3 {
            #expect(!controller.claimsClick(at: NSPoint(x: 10, y: 20), modifiers: [], clickCount: count))
            #expect(controller.selectionClickCount(for: try fixture.event(.leftMouseDown, clickCount: count))
                == UInt32(count))
        }
        #expect(fixture.forwards.isEmpty) // The actual second/third event reaches SurfaceView directly.
        #expect(fixture.copies.count == 1)
        #expect(controller.selectionClickCount(for: try fixture.event(.leftMouseDown)) == nil)
        #expect(controller.selectionClickCount(for: try fixture.event(.leftMouseDown, clickCount: 2)) == nil)
    }

    @Test func staleValidationCannotPublishAfterPointerMovesAndModifiersDoNotRepeatIO() async {
        let fixture = PathInteractionFixture()
        defer { fixture.window.close() }
        let gate = PathValidationGate()
        let controller = fixture.controller(resolve: { await gate.resolve($0) })
        fixture.probe = fixture.makeProbe(id: 1, kind: .output)
        controller.update(at: NSPoint(x: 10, y: 20), modifiers: [])
        await gate.waitForRequest(1)
        fixture.probe = fixture.makeProbe(id: 2, kind: .output)
        controller.update(at: NSPoint(x: 11, y: 20), modifiers: [])
        await gate.waitForRequest(2)
        await withCheckedContinuation { continuation in
            fixture.onPublish = { id in if id == 2 { continuation.resume(); fixture.onPublish = nil } }
            Task { await gate.finish(2) }
        }
        await gate.finish(1)
        await Task.yield()
        #expect(fixture.publishedIDs == [2])
        controller.update(at: NSPoint(x: 11, y: 20), modifiers: .command)
        #expect(fixture.openModes == [false, true])
        #expect(await gate.requests == 2)
        controller.pointerExited()
        #expect(!controller.isHovering)
    }

    @Test func movingFromPublishedHeaderToAsyncOutputPreservesTheNewCoreProbe() async throws {
        let fixture = PathInteractionFixture()
        defer { fixture.window.close() }
        let gate = PathValidationGate()
        let controller = fixture.controller(resolve: { await gate.resolve($0) })
        #expect(controller.claimsClick(at: NSPoint(x: 10, y: 20), modifiers: []))
        #expect(controller.isHovering)
        fixture.probe = fixture.makeProbe(id: 2, kind: .output)
        controller.update(at: NSPoint(x: 20, y: 20), modifiers: [])
        await gate.waitForRequest(2)
        #expect(!fixture.probeInvalidated)
        await withCheckedContinuation { continuation in
            fixture.onPublish = { id in if id == 2 { continuation.resume(); fixture.onPublish = nil } }
            Task { await gate.finish(2) }
        }
        #expect(controller.isHovering)
        controller.mouseDown(with: try fixture.event(.leftMouseDown, x: 20))
        controller.mouseUp(with: try fixture.event(.leftMouseUp, x: 20))
        #expect(fixture.copies == ["/historic/cwd"])
        controller.pointerExited()
        #expect(fixture.probeInvalidated)
    }

    @Test(arguments: [NSEvent.EventType.leftMouseDragged, .rightMouseDragged, .otherMouseDragged])
    func rawSelectionDragCancelsPendingHoverUntilOrdinaryMouseMovement(type: NSEvent.EventType) async throws {
        let fixture = PathInteractionFixture()
        defer { fixture.window.close() }
        let gate = PathValidationGate()
        let controller = fixture.controller(resolve: { await gate.resolve($0) })
        fixture.probe = fixture.makeProbe(id: 1, kind: .output)
        controller.update(at: NSPoint(x: 10, y: 20), modifiers: [])
        await gate.waitForRequest(1)

        controller.pointerMoved(with: try fixture.event(type, x: 30))
        #expect(fixture.probeInvalidated)
        await gate.finish(1)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        controller.refresh()
        #expect(fixture.publishedIDs.isEmpty)
        #expect(!controller.isHovering)
        #expect(await gate.requests == 1)
        #expect(fixture.copies.isEmpty)
        #expect(fixture.forwards.isEmpty) // The terminal already owns this drag.

        let movement = try fixture.event(.mouseMoved, x: 30)
        try #require(movement.window === fixture.window)
        controller.pointerMoved(with: movement)
        await gate.waitForRequest(2)
        await withCheckedContinuation { continuation in
            fixture.onPublish = { id in if id == 2 { continuation.resume(); fixture.onPublish = nil } }
            Task { await gate.finish(2) }
        }
        #expect(fixture.publishedIDs == [2])
        #expect(controller.isHovering)
    }
}

@MainActor
private final class PathInteractionFixture {
    let window = PathInteractionWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                                       styleMask: .borderless, backing: .buffered, defer: false)
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    var probe: CommandPathProbe?
    var probeInvalidated = false
    var copies: [String] = []
    var opens: [CommandResolvedPath] = []
    var forwards: [NSEvent.EventType] = []
    var publishedIDs: [UInt64] = []
    var openModes: [Bool] = []
    var onPublish: ((UInt64) -> Void)?

    init() {
        window.isReleasedWhenClosed = false
        window.contentView = view
        probe = makeProbe(id: 1)
    }

    func makeProbe(id: UInt64, kind: CommandPathProbe.Kind = .header) -> CommandPathProbe {
        CommandPathProbe(id: id, kind: kind, text: "cwd", hoverByte: 1, uri: "", workingDirectory: "/historic/cwd")
    }

    func controller(resolve: @escaping @Sendable (CommandPathProbe) async -> CommandPathMatch? = { _ in nil })
        -> CommandPathInteractionController {
        CommandPathInteractionController(view: view, callbacks: .init(
            probe: { [weak self] _ in
                guard let self, let probe = self.probe else { return .none }
                if self.probeInvalidated {
                    self.probe = CommandPathProbe(id: probe.id + 1, kind: probe.kind, text: probe.text,
                                                  hoverByte: probe.hoverByte, uri: probe.uri,
                                                  workingDirectory: probe.workingDirectory)
                    self.probeInvalidated = false
                }
                return self.probe.map { .hit($0) } ?? .none
            },
            publish: { [weak self] id, _, open in
                guard let self, !self.probeInvalidated, id == self.probe?.id else { return nil }
                self.publishedIDs.append(id)
                self.openModes.append(open)
                self.onPublish?(id)
                return [NSRect(x: 0, y: 0, width: 100, height: 40)]
            }, clear: { [weak self] in self?.probeInvalidated = true }, pointer: { _ in },
            forward: { [weak self] in self?.forwards.append($0.type) },
            copy: { [weak self] in self?.copies.append($0) }, open: { [weak self] in self?.opens.append($0) }
        ), resolve: resolve)
    }

    func event(_ type: NSEvent.EventType, x: CGFloat = 10, modifiers: NSEvent.ModifierFlags = [],
               clickCount: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 20), modifierFlags: modifiers,
                                       timestamp: 1, windowNumber: window.windowNumber, context: nil,
                                       eventNumber: 1, clickCount: clickCount, pressure: 0))
    }

    func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

@MainActor
private final class PathInteractionWindow: NSWindow {
    // Test eligibility without ordering or activating a real window.
    override var isKeyWindow: Bool { true }
    override var isOnActiveSpace: Bool { true }
}

private actor PathValidationGate {
    private var pending: [UInt64: CheckedContinuation<CommandPathMatch?, Never>] = [:]
    private var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private(set) var requests = 0

    func resolve(_ probe: CommandPathProbe) async -> CommandPathMatch? {
        requests += 1
        return await withCheckedContinuation { continuation in
            pending[probe.id] = continuation
            waiters.removeValue(forKey: probe.id)?.resume()
        }
    }

    func waitForRequest(_ id: UInt64) async {
        if pending[id] != nil { return }
        await withCheckedContinuation { waiters[id] = $0 }
    }

    func finish(_ id: UInt64, succeeds: Bool = true) {
        pending.removeValue(forKey: id)?.resume(returning: succeeds ? CommandPathMatch(
            path: CommandResolvedPath(path: "/historic/cwd", kind: .directory), start: 0, length: 3) : nil)
    }
}

private actor PathByteValidationGate {
    private var pending: [Int: CheckedContinuation<CommandPathMatch?, Never>] = [:]
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func resolve(_ probe: CommandPathProbe) async -> CommandPathMatch? {
        await withCheckedContinuation { continuation in
            pending[probe.hoverByte] = continuation
            waiters.removeValue(forKey: probe.hoverByte)?.resume()
        }
    }

    func waitForRequest(_ byte: Int) async {
        if pending[byte] != nil { return }
        await withCheckedContinuation { waiters[byte] = $0 }
    }

    func finish(_ byte: Int, path: String, start: Int) {
        pending.removeValue(forKey: byte)?.resume(returning: CommandPathMatch(
            path: CommandResolvedPath(path: path, kind: .file), start: start, length: 3))
    }
}
