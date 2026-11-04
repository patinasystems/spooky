import AppKit

@MainActor
final class CommandPathTooltip {
    private let panel = PathFeedbackPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
    private let surface = CommandOverlaySurface(blending: .behindWindow, castsShadow: false)
    private let label = NSTextField(labelWithString: "Copied to clipboard")
    private var dismissal: Task<Void, Never>?

    func applyTheme(_ theme: CommandUITheme) {
        surface.applyTheme(theme)
        label.textColor = theme.foreground
    }

    init() {
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.animationBehavior = .none
        label.font = .systemFont(ofSize: 12)
        label.textColor = CommandUITheme.fallback.foreground
        surface.contentView.addSubview(label)
        panel.contentView = surface
    }

    func show(anchor: NSRect, in view: NSView) {
        guard let parent = view.window, parent.isKeyWindow, parent.isVisible,
              let screen = parent.screen else { return }
        dismissal?.cancel()
        let inset = CommandOverlayStyle.inset
        let size = NSSize(width: ceil(label.intrinsicContentSize.width) + inset * 4,
                          height: ceil(label.intrinsicContentSize.height) + inset * 2)
        let rect = parent.convertToScreen(view.convert(anchor, to: nil))
        let available = screen.visibleFrame.insetBy(dx: inset, dy: inset)
        let y = rect.maxY + inset + size.height <= available.maxY
            ? rect.maxY + inset : max(available.minY, rect.minY - inset - size.height)
        let x = min(max(available.minX, rect.midX - size.width / 2), available.maxX - size.width)
        panel.appearance = view.effectiveAppearance
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true, animate: false)
        surface.layoutSubtreeIfNeeded()
        label.frame = surface.contentView.bounds.insetBy(dx: inset * 2, dy: inset)
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

@MainActor
private final class PathFeedbackPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
