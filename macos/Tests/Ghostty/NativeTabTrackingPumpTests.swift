import AppKit
import Testing
@testable import Ghostty

@MainActor
private final class NativeTabTrackingSamples {
    var modes: [String] = []
    var commonTimerFires = 0
}

@MainActor
private final class NativeTabButtonFixture: NSView {
    let target: NSWindow
    init(target: NSWindow) { self.target = target; super.init(frame: .zero) }
    required init?(coder: NSCoder) { return nil }
    @objc func associatedWindow() -> NSWindow { target }
}

struct NativeTabTrackingPumpTests {
    @Test @MainActor func nativeWindowIdentityWinsOverAnAnimatingVisualIndex() {
        let window = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let button = NativeTabButtonFixture(target: window)
        #expect(window.tabWindow(for: button, fallbackIndex: 99) === window)
        #expect(window.tabWindow(for: NSView(frame: .zero), fallbackIndex: 99) == nil)
    }

    @Test @MainActor func applicationWrapsNativeEventsAtTheApplicationBoundary() {
        #expect(NSApp is SpookyApplication)
    }

    @Test @MainActor func deliveryFollowsForeignTrackingModesAndStopsWithoutStaleCallbacks() {
        let samples = NativeTabTrackingSamples()
        let pump = NativeTabTrackingPump()
        let commonTimer = Timer(timeInterval: 0.008, repeats: true) { _ in
            MainActor.assumeIsolated { samples.commonTimerFires += 1 }
        }
        RunLoop.main.add(commonTimer, forMode: .common)
        defer { commonTimer.invalidate(); pump.stop() }
        pump.start { samples.modes.append(RunLoop.main.currentMode?.rawValue ?? "none") }

        for name in ["SpookyNativeTabTrackingTestA", "SpookyNativeTabTrackingTestB"] {
            let mode = RunLoop.Mode(name)
            let keepAlive = Timer(timeInterval: 60, repeats: false) { _ in }
            RunLoop.main.add(keepAlive, forMode: mode)
            defer { keepAlive.invalidate() }
            let oldCommon = samples.commonTimerFires
            CFRunLoopRunInMode(CFRunLoopMode(rawValue: name as CFString), 0.2, false)
            // Reproduce why the previous .common timer missed native loops.
            #expect(samples.commonTimerFires == oldCommon)
            #expect(samples.modes.filter { $0 == name }.count >= 2)
        }
        pump.stop()
        let count = samples.modes.count
        let mode = RunLoop.Mode("SpookyNativeTabTrackingTestA")
        let keepAlive = Timer(timeInterval: 60, repeats: false) { _ in }
        RunLoop.main.add(keepAlive, forMode: mode)
        defer { keepAlive.invalidate() }
        CFRunLoopRunInMode(CFRunLoopMode(rawValue: mode.rawValue as CFString), 0.05, false)
        #expect(samples.modes.count == count)
        let restarted = NativeTabTrackingSamples()
        pump.start { restarted.modes.append(RunLoop.main.currentMode?.rawValue ?? "none") }
        CFRunLoopRunInMode(CFRunLoopMode(rawValue: mode.rawValue as CFString), 0.1, false)
        #expect(samples.modes.count == count)
        #expect(restarted.modes.count >= 2)
    }

    @Test @MainActor func nativeCaptionLabelsRemainDraggableButCloseAndRenameControlsDoNot() {
        let tab = NSView(frame: .zero)
        let label = NSTextField(labelWithString: "native caption")
        label.isEditable = true
        tab.addSubview(label)
        #expect(NativeTabHitPolicy.allows(label, in: tab))
        let close = NSButton(title: "close", target: nil, action: nil)
        tab.addSubview(close)
        #expect(!NativeTabHitPolicy.allows(close, in: tab))
        let editor = NSTextField(frame: .zero)
        editor.identifier = TabTitleEditor.inlineEditorIdentifier
        tab.addSubview(editor)
        #expect(!NativeTabHitPolicy.allows(editor, in: tab))
        #expect(!NativeTabHitPolicy.allows(NSView(frame: .zero), in: tab))
    }
}
