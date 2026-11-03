import AppKit
import Testing
@testable import Ghostty

@MainActor
struct CommandInputAccentTests {
    @Test func convertsToOpaqueSRGBBytesWithoutPremultiplyingAlpha() throws {
        let appearance = try #require(NSAppearance(named: .aqua))
        let value = CommandInputAccent.resolve(NSColor(srgbRed: 0.5, green: 0.25, blue: 1, alpha: 0.2),
                                              appearance: appearance)
        #expect(value == CommandInputAccent(red: 128, green: 64, blue: 255))
    }

    @Test func dynamicColorsResolveAgainstTheOwningViewsAppearance() throws {
        let color = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
                : NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        }
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        #expect(CommandInputAccent.resolve(color, appearance: light) == CommandInputAccent(red: 255, green: 0, blue: 0))
        #expect(CommandInputAccent.resolve(color, appearance: dark) == CommandInputAccent(red: 0, green: 0, blue: 255))
    }
}
