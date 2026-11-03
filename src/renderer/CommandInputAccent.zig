//! Presentation only: semantic input keeps the shell's original cells/styles.
//! The current unsubmitted B region is excluded with viewport-bounded lookups.
const CommandInputAccent = @This();
const std = @import("std");
const terminal = @import("../terminal/main.zig");
const Chrome = @import("CommandChrome.zig");

color: ?terminal.color.RGB = null,
pending: ?struct { x: usize, y: usize } = null,

/// Caller holds the terminal mutex. No allocation, retained pins, or history
/// walk: only the final block and at most two screen-height page ranges.
pub fn snapshot(term: *const terminal.Terminal, color: ?terminal.color.RGB) CommandInputAccent {
    if (color == null or term.screens.active_key != .primary) return .{};
    var result: CommandInputAccent = .{ .color = color };
    const screen = term.screens.active;
    const blocks = screen.command_blocks.blocks.items;
    if (blocks.len == 0) return result;
    const block = blocks[blocks.len - 1];
    if (block.complete or block.output != null) return result;
    const input = block.input orelse return result;
    if (input.garbage) return .{};
    if (Chrome.viewportRow(screen.pages.getTopLeft(.viewport), term.rows, input.*)) |y| {
        result.pending = .{ .x = input.x, .y = y };
        return result;
    }
    // A pending B in the active screen but outside this viewport is below
    // visible history. Historical input remains tinted even when block metadata
    // has been pruned. A very long raw draft may move B above the active screen;
    // without a bounded proof of order, keep default colors until it commits.
    if (Chrome.viewportRow(screen.pages.getTopLeft(.active), term.rows, input.*) == null)
        return .{};
    return result;
}

/// Selection/search, explicit ANSI colors, inverse text, and configured bold
/// colors retain their existing precedence. Output and prompts never tint.
pub fn foreground(
    self: CommandInputAccent,
    cell: *const terminal.Cell,
    style: terminal.Style,
    highlighted: bool,
    bold_color: ?terminal.Style.BoldColor,
    x: usize,
    y: usize,
) ?terminal.color.RGB {
    if (self.color == null or highlighted or cell.semantic_content != .input or
        style.fg_color.tag != .none or style.flags.inverse) return null;
    if (style.flags.bold) if (bold_color) |bold| switch (bold) {
        .color => return null,
        .bright => {},
    };
    if (self.pending) |p| {
        if (y > p.y or (y == p.y and x >= p.x)) return null;
    }
    return self.color;
}

const accent: terminal.color.RGB = .{ .r = 12, .g = 100, .b = 210 };

test "command input accent preserves output prompt explicit colors and highlights" {
    const t = std.testing;
    const value: CommandInputAccent = .{ .color = accent };
    var cell: terminal.Cell = .{ .semantic_content = .input };
    try t.expectEqual(accent, value.foreground(&cell, .{}, false, null, 0, 0).?);
    try t.expectEqual(null, value.foreground(&cell, .{}, true, null, 0, 0));
    try t.expectEqual(null, value.foreground(&cell, .{ .fg_color = .palette(2) }, false, null, 0, 0));
    try t.expectEqual(null, value.foreground(&cell, .{ .fg_color = .rgb(accent) }, false, null, 0, 0));
    try t.expectEqual(null, value.foreground(&cell, .{ .flags = .{ .inverse = true } }, false, null, 0, 0));
    try t.expectEqual(null, value.foreground(&cell, .{ .flags = .{ .bold = true } }, false, .{ .color = accent }, 0, 0));
    try t.expectEqual(accent, value.foreground(&cell, .{ .flags = .{ .bold = true } }, false, .bright, 0, 0).?);
    cell.semantic_content = .output;
    try t.expectEqual(null, value.foreground(&cell, .{}, false, null, 0, 0));
    cell.semantic_content = .prompt;
    try t.expectEqual(null, value.foreground(&cell, .{}, false, null, 0, 0));
}

test "command input accent starts at C and leaves terminal semantic cells unchanged" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 20, .rows = 5 });
    defer term.deinit(t.allocator);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b]133;A;aid=one\x07> \x1b]133;B;aid=one\x07echo hi");
    const input = term.screens.active.pages.pin(.{ .active = .{ .x = 2, .y = 0 } }).?.rowAndCell().cell;
    const original = input.*;
    const pending = snapshot(&term, accent);
    try t.expectEqual(null, pending.foreground(input, .{}, false, null, 2, 0));
    stream.nextSlice("\r\n\x1b]133;C;aid=one\x07hi");
    const committed = snapshot(&term, accent);
    try t.expectEqual(accent, committed.foreground(input, .{}, false, null, 2, 0).?);
    try t.expectEqual(original, input.*);
    try t.expectEqual(terminal.Cell.SemanticContent.output, term.screens.active.cursor.semantic_content);
    try t.expectEqual(null, snapshot(&term, null).color);
    _ = try term.switchScreen(.alternate);
    try t.expectEqual(null, snapshot(&term, accent).color);
}

test "command input accent retains historical semantics with pending draft below viewport and pruned metadata" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 20, .rows = 5 });
    defer term.deinit(t.allocator);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b]133;A;aid=old\x07\x1b]133;B;aid=old\x07old\r\n\x1b]133;C;aid=old\x07");
    for (0..20) |_| try term.linefeed();
    stream.nextSlice("\x1b]133;D;0;aid=old\x07\x1b]133;A;aid=new\x07\x1b]133;B;aid=new\x07draft");
    term.screens.active.pages.scroll(.{ .row = 0 });
    const historical = snapshot(&term, accent);
    try t.expectEqual(accent, historical.color.?);
    try t.expectEqual(null, historical.pending);
    const old_cell = term.screens.active.pages.getTopLeft(.viewport).rowAndCell().cell;
    try t.expectEqual(accent, historical.foreground(old_cell, .{}, false, null, 0, 0).?);
    term.screens.active.command_blocks.deinit(t.allocator, &term.screens.active.pages);
    term.screens.active.command_blocks = .{};
    try t.expectEqual(accent, snapshot(&term, accent).foreground(old_cell, .{}, false, null, 0, 0).?);
}

test "command input accent handles multiline pending input and fails closed when its start is outside active rows" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 8, .rows = 3 });
    defer term.deinit(t.allocator);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b]133;A;aid=long\x07> \x1b]133;B;aid=long\x07abcdefghijk");
    const cell: terminal.Cell = .{ .semantic_content = .input };
    const pending = snapshot(&term, accent);
    try t.expectEqual(null, pending.foreground(&cell, .{}, false, null, 0, 1));
    for (0..8) |_| stream.nextSlice("abcdefgh");
    try t.expectEqual(null, snapshot(&term, accent).color);
    stream.nextSlice("\x1b]133;C;aid=long\x07");
    try t.expectEqual(accent, snapshot(&term, accent).color.?);
    try term.resize(t.allocator, .{ .cols = 4, .rows = 3 });
    const reflowed = term.screens.active.pages.getTopLeft(.active).rowAndCell().cell;
    try t.expectEqual(accent, snapshot(&term, accent).foreground(reflowed, .{}, false, null, 0, 0).?);
}
