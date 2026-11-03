import AppKit
import Testing
@testable import Ghostty

@MainActor
struct CommandPopupPreparationTests {
    @Test func quietPreparationRetainsOneHiddenPanelWithoutQueriesOrFocusChanges() async throws {
        let (window, editor) = makeEditor()
        defer { window.close() }
        var requests = 0
        editor.onRequestCompletion = { _ in requests += 1 }
        let controller = editor.completions
        controller.setPopupPreparationEnabled(true, after: .zero)
        #expect(controller.popup == nil) // No synchronous startup construction.
        let deadline = ContinuousClock.now + .seconds(2)
        while controller.popup == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let popup = try #require(controller.popup)
        #expect(!popup.isVisible)
        #expect(window.firstResponder === editor)
        #expect(requests == 0)
        controller.setPopupPreparationEnabled(true, after: .zero)
        await quietTurn()
        #expect(controller.popup === popup)
        #expect(!popup.isVisible)
    }

    @Test func detachingOrDisablingBeforeTheQuietTurnCancelsPreparation() async throws {
        let (window, editor) = makeEditor()
        defer { window.close() }
        editor.completions.setPopupPreparationEnabled(true, after: .zero)
        editor.removeFromSuperview()
        await quietTurn()
        #expect(editor.completions.popup == nil)
        window.contentView?.addSubview(editor)
        editor.completions.setPopupPreparationEnabled(true, after: .zero)
        editor.completions.setPopupPreparationEnabled(false)
        await quietTurn()
        #expect(editor.completions.popup == nil)
    }

    @Test func aPendingQuietTurnDoesNotRetainADestroyedController() {
        let (window, editor) = makeEditor()
        defer { window.close() }
        var controller: CommandCompletionController? = CommandCompletionController(textView: editor)
        weak var retained = controller
        controller?.setPopupPreparationEnabled(true, after: .seconds(1))
        controller = nil
        #expect(retained == nil)
    }

    private func quietTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func makeEditor() -> (NSWindow, CommandTextView) {
        // These windows are never ordered or activated. Only queried eligibility
        // is overridden; the actual panel must remain hidden throughout.
        let window = PopupPreparationWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                                             styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = CommandTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100), textContainer: nil)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView?.addSubview(editor)
        #expect(window.makeFirstResponder(editor))
        return (window, editor)
    }
}

@MainActor
private final class PopupPreparationWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isVisible: Bool { true }
}
