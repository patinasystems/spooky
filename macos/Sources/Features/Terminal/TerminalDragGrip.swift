import AppKit

/// Flat, horizontal header grip. Idle dots stay visible; interaction adds
/// a quiet highlight without changing layout or animating.
@MainActor
enum TerminalDragGrip {
    static let size = CGSize(width: 32, height: 20)
    enum State { case idle, hovered, pressed }

    static func draw(in bounds: CGRect, foreground: NSColor, accent: NSColor, state: State) {
        let fill: NSColor?
        let dots: NSColor
        switch state {
        case .idle:
            fill = nil
            dots = foreground.withAlphaComponent(0.6)
        case .hovered:
            fill = foreground.withAlphaComponent(0.09)
            dots = foreground.withAlphaComponent(0.95)
        case .pressed:
            fill = accent.withAlphaComponent(0.18)
            dots = accent
        }
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 4, yRadius: 4).fill()
        }

        let pattern = NSBezierPath()
        for x: CGFloat in [-5, 0, 5] {
            for y: CGFloat in [-2.5, 2.5] {
                pattern.appendOval(in: CGRect(x: bounds.midX + x - 1, y: bounds.midY + y - 1, width: 2, height: 2))
            }
        }
        dots.setFill()
        pattern.fill()
    }
}
