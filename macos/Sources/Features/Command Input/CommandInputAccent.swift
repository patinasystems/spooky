import AppKit

/// Convert the resolved pane theme's accent to the renderer's opaque sRGB
/// bytes. Ordinary editor updates reuse the last published value.
struct CommandInputAccent: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    @MainActor
    static func resolve(_ color: NSColor, appearance: NSAppearance) -> Self? {
        var result: Self?
        appearance.performAsCurrentDrawingAppearance {
            guard let rgb = color.usingColorSpace(.sRGB) else { return }
            func byte(_ value: CGFloat) -> UInt8 {
                UInt8((min(1, max(0, value)) * 255).rounded())
            }
            result = Self(red: byte(rgb.redComponent), green: byte(rgb.greenComponent), blue: byte(rgb.blueComponent))
        }
        return result
    }
}
