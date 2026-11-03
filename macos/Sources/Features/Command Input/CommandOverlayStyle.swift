import AppKit
import QuartzCore

/// Shared native chrome for completion and terminal search.
@MainActor
enum CommandOverlayStyle {
    static let cornerRadius: CGFloat = 10
    static let rowHeight: CGFloat = 26
    /// Shared 6pt rhythm: panel inset, label leading, and control gaps.
    static let inset: CGFloat = 6
    /// Concentric with the panel corner so selection never looks pinched.
    static let selectionRadius: CGFloat = cornerRadius - inset
    static let minimumPopupWidth: CGFloat = 160
    static let maximumPopupWidth: CGFloat = 420

    static let popupBackground = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1)
        }
        return NSColor(srgbRed: 0.985, green: 0.985, blue: 0.99, alpha: 1)
    }
    static let selectionBackground = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor.controlAccentColor.withAlphaComponent(dark ? 0.24 : 0.16)
    }
    static let border = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.12)
    }
    /// Tint over the popover material: mostly opaque so terminal text behind
    /// never competes with options. Reduce Transparency uses a solid fill.
    static let materialTintAlpha: CGFloat = 0.86
    static let headerHeight: CGFloat = 20
    static let primaryText = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor

    static func borderWidth(backingScale: CGFloat) -> CGFloat { 1 / max(1, backingScale) }

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
