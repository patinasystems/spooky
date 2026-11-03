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
    static func read(from surface: ghostty_surface_t, records: inout [ghostty_command_block_s]) -> Self? {
        var layout = ghostty_command_layout_s()
        let count = records.withUnsafeMutableBufferPointer {
            ghostty_surface_command_layout(surface, &layout, $0.baseAddress, UInt($0.count))
        }
        guard layout.snapshot_valid else { return nil }
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

/// Captions cross into Ghostty only when their contents change. The renderer
/// resolves block positions from its own terminal snapshot, not GUI geometry.
struct CommandChromePresentation: Equatable {
    struct Row: Equatable {
        let id: String
        let label: String
        let suffix: String
        let current: Bool
        let pinned: Bool
    }

    let enabled: Bool
    let pinnedOffset: CGFloat
    let backingScale: CGFloat
    let rows: [Row]

    init(layout: CommandTerminalLayout, metadata: [String: CommandBlockMetadata], currentID: String?,
         pinnedOffset: CGFloat, recovering: Bool, backingScale: CGFloat = 1) {
        enabled = layout.primary
        self.pinnedOffset = pinnedOffset
        self.backingScale = backingScale
        var ids = Array(layout.blocks.map(\.id).prefix(127))
        if let currentID, !ids.contains(currentID) { ids.append(currentID) }
        rows = ids.map { id in
            let block = metadata[id]
            let current = id == currentID
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let cwd = block?.workingDirectory ?? "local zsh"
            var label = cwd == home ? "~" : (cwd.hasPrefix(home + "/") ? "~" + cwd.dropFirst(home.count) : cwd)
            label = label.replacingOccurrences(of: "\n", with: "↵")
            if let branch = block?.branch, !branch.isEmpty { label += "  ⎇ \(branch)" }
            if recovering && current { label = "Retained draft (read only)" }
            var suffix = ""
            if let status = block?.exitStatus { suffix = status == 0 ? "✓" : "exit \(status)" }
            if let elapsed = block?.elapsed {
                suffix += String(format: "  %.3fs", elapsed)
            } else if block?.status == "running" { suffix = "running" }
            return Row(id: id, label: label, suffix: suffix, current: current,
                       pinned: current && pinnedOffset >= 0)
        }
    }

    @MainActor
    func publish(to surface: ghostty_surface_t) {
        var bytes: [UInt8] = []
        var ranges: [(label: Range<Int>, suffix: Range<Int>)] = []
        for row in rows {
            let labelStart = bytes.count
            bytes.append(contentsOf: row.label.utf8)
            let labelEnd = bytes.count
            bytes.append(contentsOf: row.suffix.utf8)
            ranges.append((labelStart..<labelEnd, labelEnd..<bytes.count))
        }
        // Keep an address available even when every caption is empty.
        bytes.append(0)
        bytes.withUnsafeBufferPointer { buffer in
            var records = rows.enumerated().map { index, row in
                var record = ghostty_command_chrome_s()
                withUnsafeMutableBytes(of: &record.id) { destination in
                    for (offset, byte) in row.id.utf8.prefix(64).enumerated() { destination[offset] = byte }
                }
                let range = ranges[index]
                record.label = UnsafeRawPointer(buffer.baseAddress!.advanced(by: range.label.lowerBound))
                    .assumingMemoryBound(to: CChar.self)
                record.label_len = UInt(range.label.count)
                record.suffix = UnsafeRawPointer(buffer.baseAddress!.advanced(by: range.suffix.lowerBound))
                    .assumingMemoryBound(to: CChar.self)
                record.suffix_len = UInt(range.suffix.count)
                record.current = row.current
                record.pinned = row.pinned
                return record
            }
            records.withUnsafeMutableBufferPointer {
                ghostty_surface_set_command_chrome(surface, enabled, pinnedOffset, $0.baseAddress, UInt($0.count))
            }
        }
        CommandInputDiagnostics.record(.chromePublication)
    }
}
