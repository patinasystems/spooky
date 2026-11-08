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
    enum NativeState: UInt8 { case none, ready, terminal, running, exited }
    var nativeState: NativeState = .none
    var nativeStateRevision: UInt64 = 0
    var nativeGeneration: String?
    var nativeAcceptedRequest: String?
    var presentedNativeGeneration: String?
    var nativeBlockID: String?
    var nativeWorkingDirectory: String?
    var nativeContextStart = false
    var primary = true
    var atBottom = true
    var hasScrollback = false
    var cursorValid = false
    var columns: UInt32 = 0
    var rows: UInt32 = 0
    var scrollbackRows: UInt64 = 0
    var activeCursorRow: UInt32 = 0
    var compactPromptRows: UInt32 = 0
    var unreservedGridHeight: CGFloat = 0
    var cellWidth: CGFloat = 8
    var cellHeight: CGFloat = 18
    var paddingLeft: CGFloat = 0
    var paddingTop: CGFloat = 0
    var cursorX: CGFloat = 0
    var cursorY: CGFloat = 0
    var lastStartedBlockID: String?
    var lastPrimaryInputBlockID: String?
    var blocks: [CommandBlockAnchor] = []

    /// A file-ready prompt is not presentable until its own B has parsed.
    /// Visible block records may be clipped, erased, or outside their capacity.
    /// The cursor can be outside the viewport while a pinned draft stays editable.
    func hasParsedPrimaryInput(_ id: String?) -> Bool {
        guard let id else { return false }
        return primary && rows > 0 && columns > 0 && lastPrimaryInputBlockID == id
    }

    @MainActor
    static func read(from surface: ghostty_surface_t, records: inout [ghostty_command_block_s]) -> Self? {
        var layout = ghostty_command_layout_s()
        let count = records.withUnsafeMutableBufferPointer {
            ghostty_surface_command_layout(surface, &layout, $0.baseAddress, UInt($0.count))
        }
        guard layout.snapshot_valid else { return nil }
        var result = Self()
        result.nativeState = NativeState(rawValue: layout.native_state) ?? .none
        result.nativeStateRevision = layout.native_state_revision
        result.nativeContextStart = layout.native_context_start
        func string<T>(_ bytes: T) -> String? {
            withUnsafeBytes(of: bytes) { raw in
                let value = String(bytes: raw.prefix { $0 != 0 }, encoding: .utf8)
                return value?.isEmpty == false ? value : nil
            }
        }
        result.nativeGeneration = string(layout.native_generation)
        result.nativeAcceptedRequest = string(layout.native_accepted_request)
        result.presentedNativeGeneration = string(layout.presented_generation)
        result.nativeBlockID = string(layout.native_block_id)
        result.nativeWorkingDirectory = string(layout.native_cwd)
        result.primary = layout.primary
        result.atBottom = layout.viewport_at_bottom
        result.hasScrollback = layout.has_scrollback
        result.cursorValid = layout.cursor_valid
        result.columns = layout.columns
        result.rows = layout.rows
        result.scrollbackRows = layout.scrollback_rows
        result.activeCursorRow = layout.active_cursor_row
        result.compactPromptRows = layout.compact_prompt_rows
        result.unreservedGridHeight = layout.unreserved_grid_height
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
        result.lastPrimaryInputBlockID = withUnsafeBytes(of: layout.last_primary_input_id) { bytes in
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
    /// Localized on the bridge actor when completion metadata is first read.
    /// Retain display text so scrolling never formats dates on the UI thread.
    let completionTime: String?

    init(id: String, workingDirectory: String, branch: String, status: String,
         exitStatus: Int?, elapsed: Double?, completionTime: String? = nil) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.branch = branch
        self.status = status
        self.exitStatus = exitStatus
        self.elapsed = elapsed
        self.completionTime = completionTime
    }

    var completed: Bool { status == "completed" }

    static func localizedCompletionTime(_ wallTime: Double, locale: Locale = .autoupdatingCurrent,
                                        timeZone: TimeZone = .autoupdatingCurrent) -> String? {
        guard wallTime.isFinite else { return nil }
        let format = Date.FormatStyle(locale: locale, timeZone: timeZone)
            .hour().minute().second().secondFraction(.fractional(3))
        return Date(timeIntervalSince1970: wallTime).formatted(format)
    }
}

/// Captions cross into Ghostty only when their contents change. The renderer
/// resolves block positions from its own terminal snapshot, not GUI geometry.
struct CommandChromePresentation: Equatable {
    struct Row: Equatable {
        let id: String
        let label: String
        let pathByteCount: Int
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
        rows = ids.compactMap { id in
            // PTY markers and private metadata arrive independently. An unknown
            // block has no truthful caption yet; never flash a guessed directory.
            guard let block = metadata[id] else { return nil }
            let current = id == currentID
            let cwd = block.workingDirectory
            var label = Self.displayPath(cwd)
            let pathByteCount = cwd.hasPrefix("/") && !(recovering && current) ? label.utf8.count : 0
            if !block.branch.isEmpty { label += "  ⎇ \(block.branch)" }
            if recovering && current { label = "Retained draft (read only)" }
            var suffix = ""
            if let status = block.exitStatus { suffix = status == 0 ? "✓" : "exit \(status)" }
            if let elapsed = block.elapsed {
                suffix += String(format: suffix.isEmpty ? "%.3fs" : " %.3fs", elapsed)
            } else if block.status == "running" { suffix = "running" }
            if block.completed, let time = block.completionTime { suffix += suffix.isEmpty ? time : " · \(time)" }
            return Row(id: id, label: label, pathByteCount: pathByteCount, suffix: suffix, current: current,
                       pinned: current && pinnedOffset >= 0)
        }
    }

    static func displayPath(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        let label = path == home ? "~" : (path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
        return label.replacingOccurrences(of: "\n", with: "↵")
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
                record.path_len = UInt(row.pathByteCount)
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
