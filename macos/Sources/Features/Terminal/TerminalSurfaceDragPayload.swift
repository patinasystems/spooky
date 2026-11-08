import AppKit

/// The existing transferable format, loaded eagerly for native drag callbacks.
enum TerminalSurfaceDragPayload {
    static let type = NSPasteboard.PasteboardType("com.mitchellh.ghosttySurfaceId")

    static func data(for id: UUID) -> Data {
        withUnsafeBytes(of: id.uuid) { Data($0) }
    }

    static func id(from data: Data) -> UUID? {
        guard data.count == 16 else { return nil }
        return data.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }

    static func item(for id: UUID) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setData(data(for: id), forType: type)
        return item
    }
}

enum TerminalTabDropRegion {
    /// Window-base coordinates, including native tab/titlebar accessories.
    static func header(size: NSSize, contentLayout: NSRect) -> NSRect {
        let top = min(size.height, max(0, contentLayout.maxY))
        return NSRect(x: 0, y: top, width: max(0, size.width), height: max(0, size.height - top))
    }
}

/// Native tabs are the window's drag control, including an explicitly shown
/// single-tab bar. A pane grip only belongs to a standalone, tab-bar-free window.
enum TerminalDragHandlePolicy {
    static func hasNativeControl(tabCount: Int, tabBarVisible: Bool) -> Bool {
        tabCount > 1 || tabBarVisible
    }
}
