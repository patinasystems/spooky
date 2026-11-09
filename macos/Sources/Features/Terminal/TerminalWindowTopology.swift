import AppKit

/// Event-driven topology for normal terminal windows in this app process.
/// Settings, popovers, closed sessions and hidden tabs are not separate windows.
@MainActor
final class TerminalWindowTopology {
    static let didChange = Notification.Name("SpookyTerminalWindowTopologyDidChange")
    private(set) var windowCount = 0
    private var entries: [Entry] = []
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var scheduled = false

    struct Entry: Equatable {
        let window: Int
        let group: ObjectIdentifier?
        let hasNativeTabs: Bool
    }

    func start() {
        guard !started else { return }
        started = true
        for name in [NSWindow.didBecomeMainNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, TerminalWindow.terminalDidAwake,
                     NSApplication.didUnhideNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
        refresh()
    }

    func stop() {
        started = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    func scheduleRefresh() {
        guard started, !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            if self.started { self.refresh() }
        }
    }

    private func refresh() {
        let next = TerminalController.all.compactMap { controller -> Entry? in
            guard !controller.surfaceTree.isEmpty, let window = controller.window,
                  window.isVisible || window.isMiniaturized else { return nil }
            return Entry(window: window.windowNumber, group: window.tabGroup.map(ObjectIdentifier.init),
                         hasNativeTabs: Self.hasNativeTabs(window))
        }.sorted { $0.window < $1.window }
        guard next != entries else { return }
        entries = next
        windowCount = Self.countGroups(next)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    static func hasNativeTabs(_ window: NSWindow) -> Bool {
        (window.tabGroup?.windows.count ?? 0) > 1 || window.tabGroup?.isTabBarVisible == true
    }

    static func countGroups(_ entries: [Entry]) -> Int {
        var groups: [ObjectIdentifier] = []
        var count = 0
        for entry in entries {
            if let group = entry.group {
                if groups.contains(group) { continue }
                groups.append(group)
            }
            count += 1
        }
        return count
    }

    static func showsGrip(isSplit: Bool, hasNativeTabs: Bool, windowCount: Int) -> Bool {
        isSplit || (!hasNativeTabs && windowCount > 1)
    }
}
