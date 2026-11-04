import AppKit
import GhosttyKit

extension Notification.Name {
    static let spookyCommandThemeDidChange = Notification.Name("spookyCommandThemeDidChange")
}

/// Resolved once with each pane's configuration. Native controls and Metal's
/// semantic command tint consume this same palette, including user overrides.
struct CommandUITheme: Equatable {
    let background: NSColor
    let foreground: NSColor
    let selectionBackground: NSColor
    let selectionForeground: NSColor
    let cursor: NSColor
    /// ANSI blue (palette 4) is the theme's UI/committed-command accent.
    let accent: NSColor

    var secondary: NSColor { foreground.withAlphaComponent(0.65) }
    var border: NSColor { foreground.withAlphaComponent(0.14) }
    var popupBackground: NSColor { background.blended(withFraction: 0.04, of: foreground) ?? background }

    static let fallback = CommandUITheme(
        background: NSColor(srgbRed: 22 / 255, green: 22 / 255, blue: 22 / 255, alpha: 1),
        foreground: NSColor(srgbRed: 242 / 255, green: 244 / 255, blue: 248 / 255, alpha: 1),
        selectionBackground: NSColor(srgbRed: 42 / 255, green: 42 / 255, blue: 42 / 255, alpha: 1),
        selectionForeground: .white, cursor: .white,
        accent: NSColor(srgbRed: 120 / 255, green: 169 / 255, blue: 1, alpha: 1))

    @MainActor
    static func resolve(_ config: Ghostty.Config) -> Self {
        guard let core = config.config else { return .fallback }
        func color(_ key: String, fallback: NSColor) -> NSColor {
            var value = ghostty_config_color_s()
            guard ghostty_config_get(core, &value, key, UInt(key.utf8.count)) else { return fallback }
            return native(value)
        }
        let background = color("background", fallback: fallback.background)
        let foreground = color("foreground", fallback: fallback.foreground)
        var palette = ghostty_config_palette_s()
        let accent = ghostty_config_get(core, &palette, "palette", 7) ? native(palette.colors.4) : fallback.accent
        return Self(background: background, foreground: foreground,
                    selectionBackground: color("selection-background", fallback: accent.withAlphaComponent(0.25)),
                    selectionForeground: color("selection-foreground", fallback: foreground),
                    cursor: color("cursor-color", fallback: foreground), accent: accent)
    }

    private static func native(_ value: ghostty_config_color_s) -> NSColor {
        NSColor(srgbRed: CGFloat(value.r) / 255, green: CGFloat(value.g) / 255,
                blue: CGFloat(value.b) / 255, alpha: 1)
    }
}
