import AppKit

/// Flat, horizontal header grip. Idle dots stay visible; interaction adds
/// a quiet highlight without changing layout or animating.
@MainActor
enum TerminalDragGrip {
    static let size = CGSize(width: 32, height: 20)
    nonisolated static let highlightInset: CGFloat = 4
    nonisolated static let minimumCornerRadius: CGFloat = 4
    enum State { case idle, hovered, pressed }

    struct Corners {
        var topLeft: CGFloat = minimumCornerRadius
        var topRight: CGFloat = minimumCornerRadius
        var bottomLeft: CGFloat = minimumCornerRadius
        var bottomRight: CGFloat = minimumCornerRadius
    }

    static func highlightRect(in bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: highlightInset, dy: highlightInset)
    }

    static func draw(in bounds: CGRect, foreground: NSColor, accent: NSColor, state: State,
                     corners: Corners = .init()) {
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
            let rect = highlightRect(in: bounds)
            let limit = max(0, min(rect.width, rect.height) / 2)
            let radius: (CGFloat) -> CGFloat = { min(limit, max(0, $0)) }
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.midX, y: rect.minY))
            path.appendArc(from: NSPoint(x: rect.maxX, y: rect.minY),
                           to: NSPoint(x: rect.maxX, y: rect.maxY), radius: radius(corners.bottomRight))
            path.appendArc(from: NSPoint(x: rect.maxX, y: rect.maxY),
                           to: NSPoint(x: rect.minX, y: rect.maxY), radius: radius(corners.topRight))
            path.appendArc(from: NSPoint(x: rect.minX, y: rect.maxY),
                           to: NSPoint(x: rect.minX, y: rect.minY), radius: radius(corners.topLeft))
            path.appendArc(from: NSPoint(x: rect.minX, y: rect.minY),
                           to: NSPoint(x: rect.maxX, y: rect.minY), radius: radius(corners.bottomLeft))
            path.close()
            path.fill()
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
