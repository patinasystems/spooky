import AppKit
import Testing
@testable import Ghostty

@MainActor
struct CommandUIThemeTests {
    @Test func carbonfoxSuppliesNativeChromeAndMetalCommandAccent() throws {
        let config = try TemporaryConfig("")
        let theme = CommandUITheme.resolve(config)
        let appearance = try #require(NSAppearance(named: .darkAqua))
        #expect(CommandInputAccent.resolve(theme.accent, appearance: appearance)
                == CommandInputAccent(red: 120, green: 169, blue: 255))
        #expect(CommandInputAccent.resolve(theme.selectionBackground, appearance: appearance)
                == CommandInputAccent(red: 42, green: 42, blue: 42))
        #expect(CommandInputAccent.resolve(theme.background, appearance: appearance)
                == CommandInputAccent(red: 22, green: 22, blue: 22))
    }

    @Test func paletteOverridesAndSymbolicColorsShareTheResolvedConfig() throws {
        let config = try TemporaryConfig("""
        background = #fefefe
        foreground = #121212
        palette = 4=#cc3344
        selection-background = cell-foreground
        selection-foreground = cell-background
        cursor-color = #445566
        """)
        let theme = CommandUITheme.resolve(config)
        let appearance = try #require(NSAppearance(named: .aqua))
        #expect(CommandInputAccent.resolve(theme.accent, appearance: appearance)
                == CommandInputAccent(red: 204, green: 51, blue: 68))
        #expect(theme.selectionBackground == theme.foreground)
        #expect(theme.selectionForeground == theme.background)
        #expect(CommandInputAccent.resolve(theme.cursor, appearance: appearance)
                == CommandInputAccent(red: 68, green: 85, blue: 102))
        let bar = SurfaceSearchBar()
        bar.applyTheme(theme)
        #expect(bar.field.textColor == theme.foreground)
        let editor = CommandTextView(frame: .zero, textContainer: nil)
        editor.applyTheme(theme)
        #expect(editor.insertionPointColor == theme.cursor)
        #expect(editor.selectedTextAttributes[.backgroundColor] as? NSColor == theme.selectionBackground)
    }

    @Test func updatingAPopupThemeDoesNotReloadCandidateRows() throws {
        let table = ThemeTableProbe()
        let popup = CommandCompletionView(table: table)
        let theme = CommandUITheme.resolve(try TemporaryConfig("palette = 4=#cc3344"))
        let count = table.reloads
        popup.applyTheme(theme)
        popup.applyTheme(theme)
        #expect(popup.theme == theme)
        #expect(table.reloads == count)
    }
}

@MainActor
private final class ThemeTableProbe: NSTableView {
    var reloads = 0
    override func reloadData() { reloads += 1; super.reloadData() }
}
