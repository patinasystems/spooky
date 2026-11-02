import AppKit
import CoreText
import GhosttyKit

struct CommandBlockAnchor: Equatable, Identifiable {
    let id: String
    let flags: UInt32
    let headerY: CGFloat
    let inputY: CGFloat
    let outputY: CGFloat
    let endY: CGFloat
    let complete: Bool

    var hasHeader: Bool { flags & 1 != 0 }
}

struct CommandTerminalLayout: Equatable {
    var primary = true
    var atBottom = true
    var cursorValid = false
    var columns: UInt32 = 0
    var rows: UInt32 = 0
    var cellWidth: CGFloat = 8
    var cellHeight: CGFloat = 18
    var paddingLeft: CGFloat = 0
    var paddingTop: CGFloat = 0
    var cursorX: CGFloat = 0
    var cursorY: CGFloat = 0
    var lastStartedBlockID: String?
    var blocks: [CommandBlockAnchor] = []

    @MainActor
    static func read(from surface: ghostty_surface_t) -> Self {
        var layout = ghostty_command_layout_s()
        var records = Array(repeating: ghostty_command_block_s(), count: 128)
        let count = records.withUnsafeMutableBufferPointer {
            ghostty_surface_command_layout(surface, &layout, $0.baseAddress, UInt($0.count))
        }
        var result = Self()
        result.primary = layout.primary
        result.atBottom = layout.viewport_at_bottom
        result.cursorValid = layout.cursor_valid
        result.columns = layout.columns
        result.rows = layout.rows
        result.cellWidth = max(1, layout.cell_width)
        result.cellHeight = max(1, layout.cell_height)
        result.paddingLeft = layout.padding_left
        result.paddingTop = layout.padding_top
        result.cursorX = layout.cursor_x
        result.cursorY = layout.cursor_y
        result.lastStartedBlockID = withUnsafeBytes(of: layout.last_started_id) { bytes in
            let value = String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
            return value?.isEmpty == false ? value : nil
        }
        result.blocks = records.prefix(Int(count)).compactMap { record in
            let id = withUnsafeBytes(of: record.id) { bytes in
                String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
            }
            guard let id, !id.isEmpty else { return nil }
            return CommandBlockAnchor(id: id, flags: record.flags, headerY: record.header_y,
                                      inputY: record.input_y, outputY: record.output_y,
                                      endY: record.end_y, complete: record.complete)
        }
        return result
    }
}

struct CommandBlockMetadata: Equatable, Sendable {
    let id: String
    let workingDirectory: String
    let branch: String
    let status: String
    let exitStatus: Int?
    /// Prototype wall-clock interval; not a performance measurement.
    let elapsed: Double?

    var completed: Bool { status == "completed" }
}
