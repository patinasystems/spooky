import AppKit

/// Small, opaque AppKit grip. Idle is discoverable; interaction changes only
/// its colors. No hover-driven layout, animation, images or background work.
@MainActor
enum TerminalDragGrip {
    static let size = CGSize(width: 34, height: 24)
    enum State { case idle, hovered, pressed }

    static func draw(in bounds: CGRect, background: NSColor, foreground: NSColor,
                     accent: NSColor, state: State, scale: CGFloat) {
        let fill: NSColor
        let border: NSColor
        let dots: NSColor
        switch state {
        case .idle:
            fill = background.blended(withFraction: 0.06, of: foreground) ?? background
            border = foreground.withAlphaComponent(0.16)
            dots = foreground.withAlphaComponent(0.7)
        case .hovered:
            fill = background.blended(withFraction: 0.11, of: foreground) ?? background
            border = foreground.withAlphaComponent(0.28)
            dots = foreground.withAlphaComponent(0.95)
        case .pressed:
            fill = background.blended(withFraction: 0.2, of: accent) ?? background
            border = accent.withAlphaComponent(0.7)
            dots = accent
        }
        let chip = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
        fill.setFill()
        chip.fill()
        border.setStroke()
        chip.lineWidth = 1 / max(1, scale)
        chip.stroke()

        let pattern = NSBezierPath()
        for x: CGFloat in [-2.5, 2.5] {
            for y: CGFloat in [-4, 0, 4] {
                pattern.appendOval(in: CGRect(x: bounds.midX + x - 1, y: bounds.midY + y - 1, width: 2, height: 2))
            }
        }
        dots.setFill()
        pattern.fill()
    }
}
