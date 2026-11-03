import AppKit
import QuartzCore

/// Shared native chrome for completion and terminal search.
@MainActor
enum CommandOverlayStyle {
    static let cornerRadius: CGFloat = 10
    static let rowHeight: CGFloat = 30
    static let inset: CGFloat = 6

    static let popupBackground = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1)
        }
        return NSColor(srgbRed: 0.985, green: 0.985, blue: 0.99, alpha: 1)
    }
    static let selectionBackground = NSColor.controlAccentColor.withAlphaComponent(0.16)
    static let border = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.12)
    }
    static let primaryText = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor

    static func borderWidth(backingScale: CGFloat) -> CGFloat { 1 / max(1, backingScale) }

    static func apply(to view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        withoutAnimation {
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                layer.backgroundColor = popupBackground.cgColor
                layer.borderColor = border.cgColor
            }
            layer.cornerRadius = cornerRadius
            layer.borderWidth = borderWidth(backingScale: view.window?.backingScaleFactor ?? 2)
        }
    }

    static func withoutAnimation(_ updates: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updates()
            CATransaction.commit()
        }
    }
}
