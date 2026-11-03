import AppKit

/// Product identity belongs to the app bundle; the Ghostty module and terminal
/// core keep their upstream names for source and configuration compatibility.
enum AppBranding {
    static var nativeInputEnabled: Bool {
        let setting = ProcessInfo.processInfo.environment["GHOSTTY_NATIVE_INPUT"]
        let bundleDefault = Bundle.main.object(forInfoDictionaryKey: "SpookyNativeInputEnabled") as? Bool ?? false
        return setting == "1" || (setting != "0" && bundleDefault)
    }

    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Spooky"
    }

    static var upstreamUpdatesDisabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SpookyDisableUpstreamUpdates") as? Bool == true
    }

    @MainActor static func configureMainMenu() {
        guard let item = NSApp.mainMenu?.items.first, let menu = item.submenu else { return }
        item.title = displayName
        menu.title = displayName
        for item in menu.items {
            switch item.action {
            case #selector(AppDelegate.showAbout(_:)):
                item.title = "About \(displayName)"
            case #selector(NSApplication.hide(_:)):
                item.title = "Hide \(displayName)"
            case #selector(NSApplication.terminate(_:)):
                item.title = "Quit \(displayName)"
            case #selector(AppDelegate.setAsDefaultTerminal(_:)):
                item.title = "Make \(displayName) the Default Terminal"
            case #selector(AppDelegate.checkForUpdates(_:)):
                item.isHidden = upstreamUpdatesDisabled
            default:
                break
            }
        }
    }
}
