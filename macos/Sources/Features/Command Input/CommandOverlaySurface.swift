import AppKit
import QuartzCore

/// The one chrome primitive shared by completion, the `@` file picker, and
/// terminal search: a mostly opaque popover material, a hairline border, the
/// shared corner radius, and an optional subtle layer shadow. Clients add
/// their controls to `contentView`. Nothing here animates.
@MainActor
final class CommandOverlaySurface: NSView {
    /// Clipped to the rounded shape; add overlay content here.
    let contentView = NSView()
    private let clip = NSView()
    private let material = NSVisualEffectView()
    private let tint = NSView()
    private let castsShadow: Bool
    private var theme = CommandUITheme.fallback
    private var shadowSize: CGSize = .zero
    private var reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency

    /// - Parameters:
    ///   - blending: `.behindWindow` for child panels, `.withinWindow` for
    ///     overlays inside the terminal window.
    ///   - castsShadow: in-window overlays draw a layer shadow. Panels use
    ///     their window shadow instead, which follows the rounded alpha.
    init(blending: NSVisualEffectView.BlendingMode, castsShadow: Bool) {
        self.castsShadow = castsShadow
        super.init(frame: .zero)
        wantsLayer = true
        clip.wantsLayer = true
        tint.wantsLayer = true
        contentView.wantsLayer = true
        material.material = .popover
        material.blendingMode = blending
        material.state = .active
        material.maskImage = Self.mask
        addSubview(clip)
        clip.addSubview(material)
        clip.addSubview(tint)
        clip.addSubview(contentView)
        if castsShadow, let layer {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.14
            layer.shadowRadius = 6
            layer.shadowOffset = CGSize(width: 0, height: -2)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        updateChrome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyTheme(_ theme: CommandUITheme) {
        guard self.theme != theme else { return }
        self.theme = theme
        updateChrome()
    }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    override var isFlipped: Bool { true }

    override func layout() {
        let diagnostic = CommandInputDiagnostics.begin(.overlayLayout)
        defer { CommandInputDiagnostics.end(diagnostic) }
        super.layout()
        CommandOverlayStyle.withoutAnimation {
            if clip.frame != bounds { clip.frame = bounds }
            if material.frame != clip.bounds { material.frame = clip.bounds }
            if tint.frame != clip.bounds { tint.frame = clip.bounds }
            if contentView.frame != clip.bounds { contentView.frame = clip.bounds }
            // Rebuild the shadow path only when the size changes, never per key.
            if castsShadow, bounds.size != shadowSize, let layer,
               bounds.width >= CommandOverlayStyle.cornerRadius * 2,
               bounds.height >= CommandOverlayStyle.cornerRadius * 2 {
                shadowSize = bounds.size
                layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: CommandOverlayStyle.cornerRadius,
                                          cornerHeight: CommandOverlayStyle.cornerRadius, transform: nil)
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateChrome()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateChrome()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateChrome()
    }

    @objc private func accessibilityDisplayOptionsChanged() {
        reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        updateChrome()
    }

    private func updateChrome() {
        CommandInputDiagnostics.record(.overlayChromeUpdate)
        guard let clipLayer = clip.layer, let tintLayer = tint.layer else { return }
        let opaque = reduceTransparency
        CommandOverlayStyle.withoutAnimation {
            material.isHidden = opaque
            effectiveAppearance.performAsCurrentDrawingAppearance {
                tintLayer.backgroundColor = theme.popupBackground
                    .withAlphaComponent(opaque ? 1 : CommandOverlayStyle.materialTintAlpha).cgColor
                clipLayer.borderColor = theme.border.cgColor
            }
            clipLayer.cornerRadius = CommandOverlayStyle.cornerRadius
            clipLayer.masksToBounds = true
            clipLayer.borderWidth = CommandOverlayStyle.borderWidth(backingScale: window?.backingScaleFactor ?? 2)
        }
    }

    /// Resizable rounded mask; built once and stretched by cap insets.
    private static let mask: NSImage = {
        let radius = CommandOverlayStyle.cornerRadius
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }()
}
