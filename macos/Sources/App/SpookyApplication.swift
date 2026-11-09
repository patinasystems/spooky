import AppKit

/// Wrap native tracking at the application boundary, including AppKit's
/// detached fullscreen titlebar windows. Always leave event delivery to AppKit.
@objc(SpookyApplication)
final class SpookyApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        let drag = (delegate as? AppDelegate)?.nativeTabDragCoordinator
        drag?.willDispatch(event)
        defer { drag?.didDispatch(event) }
        super.sendEvent(event)
    }
}
