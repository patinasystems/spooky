//! Owned values crossing Spooky's native command-editor boundary.
const std = @import("std");
const renderer = @import("../renderer.zig");

pub const CommandBlock = extern struct {
    id: [65]u8,
    flags: u32,
    header_y: f64,
    input_y: f64,
    output_y: f64,
    end_y: f64,
    complete: bool,
};

pub const CommandLayout = extern struct {
    snapshot_valid: bool,
    primary: bool,
    viewport_at_bottom: bool,
    has_scrollback: bool,
    cursor_valid: bool,
    columns: u32,
    rows: u32,
    scrollback_rows: u64,
    active_cursor_row: u32,
    compact_prompt_rows: u32,
    unreserved_grid_height: f64,
    cell_width: f64,
    cell_height: f64,
    padding_left: f64,
    padding_top: f64,
    cursor_x: f64,
    cursor_y: f64,
    last_started_id: [65]u8,
    last_primary_input_id: [65]u8,
    native_state_revision: u64,
    native_generation: [65]u8,
    native_accepted_request: [129]u8,
    presented_generation: [65]u8,
    native_block_id: [65]u8,
    native_cwd: [1025]u8,
    native_state: u8,
    native_context_start: bool,
};

pub const CommandChrome = extern struct {
    id: [65]u8,
    label: ?[*]const u8,
    label_len: usize,
    path_len: usize,
    suffix: ?[*]const u8,
    suffix_len: usize,
    current: bool,
    pinned: bool,
};

pub const PathRect = extern struct { x: f64, y: f64, width: f64, height: f64 };
pub const PathRects = extern struct { count: u32, rects: [8]PathRect };

test "native command ABI matches C field sizes alignment and offsets" {
    const c = @import("ghostty.h");
    inline for (.{
        .{ CommandBlock, c.ghostty_command_block_s },
        .{ CommandLayout, c.ghostty_command_layout_s },
        .{ CommandChrome, c.ghostty_command_chrome_s },
        .{ renderer.PathHover.Probe, c.ghostty_path_probe_s },
        .{ PathRect, c.ghostty_path_rect_s },
        .{ PathRects, c.ghostty_path_rects_s },
    }) |pair| {
        const zig = pair[0];
        const header = pair[1];
        try std.testing.expectEqual(@sizeOf(header), @sizeOf(zig));
        try std.testing.expectEqual(@alignOf(header), @alignOf(zig));
        const fields = @typeInfo(zig).@"struct".field_names;
        try std.testing.expectEqual(@typeInfo(header).@"struct".field_names.len, fields.len);
        inline for (fields) |name| {
            try std.testing.expectEqual(@offsetOf(header, name), @offsetOf(zig, name));
            try std.testing.expectEqual(@sizeOf(@FieldType(header, name)), @sizeOf(@FieldType(zig, name)));
        }
    }
    try @import("../lib/enum.zig").checkGhosttyHEnum(renderer.PathHover.Kind, "GHOSTTY_PATH_KIND_");
}
