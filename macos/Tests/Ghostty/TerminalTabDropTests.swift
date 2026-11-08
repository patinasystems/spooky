import AppKit
import Testing
@testable import Ghostty

struct TerminalTabDropTests {
    @Test func surfacePayloadKeepsTheExistingUUIDWireFormat() throws {
        let id = try #require(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        let data = TerminalSurfaceDragPayload.data(for: id)
        #expect(Array(data) == [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                                0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        #expect(TerminalSurfaceDragPayload.id(from: data) == id)
        for count in [0, 15, 17, 32] {
            #expect(TerminalSurfaceDragPayload.id(from: Data(repeating: 0, count: count)) == nil)
        }
    }

    @Test @MainActor func surfacePayloadIsImmediatelyAvailableToNativeDestinations() throws {
        let id = UUID()
        let item = TerminalSurfaceDragPayload.item(for: id)
        let data = try #require(item.data(forType: .ghosttySurfaceId))
        #expect(TerminalSurfaceDragPayload.id(from: data) == id)
        #expect(item.types == [.ghosttySurfaceId])
    }

    @Test func headerDropIncludesNativeTabAccessoriesButExcludesTerminalSplits() {
        let size = NSSize(width: 800, height: 600)
        for contentTop in [CGFloat(572), 544, 520] {
            let region = TerminalTabDropRegion.header(size: size, contentLayout: NSRect(x: 0, y: 0, width: 800, height: contentTop))
            #expect(region.contains(NSPoint(x: 400, y: contentTop + 1)))
            #expect(region.contains(NSPoint(x: 400, y: 599)))
            #expect(!region.contains(NSPoint(x: 400, y: contentTop - 1)))
            #expect(!region.contains(NSPoint(x: -1, y: 590)))
            #expect(!region.contains(NSPoint(x: 801, y: 590)))
        }
        #expect(TerminalTabDropRegion.header(size: size, contentLayout: NSRect(origin: .zero, size: size)).isEmpty)
    }
}
