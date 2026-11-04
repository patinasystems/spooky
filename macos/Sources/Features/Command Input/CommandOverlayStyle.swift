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

    /// Tint over the popover material: mostly opaque so terminal text behind
    /// never competes with options. Reduce Transparency uses a solid fill.
    static let materialTintAlpha: CGFloat = 0.86
    static let headerHeight: CGFloat = 20

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
