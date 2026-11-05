//! A native footer covers only validated prompt rows, never arbitrary output.
//! PTY dimensions and scroll offsets stay independent of the visible crop.
const NativeViewport = @This();
const std = @import("std");
const terminal = @import("../terminal/main.zig");
const Chrome = @import("CommandChrome.zig");
const Size = @import("size.zig").Size;

footer_height: u32 = 0,
covered_rows: u2 = 0,
transferring: bool = false,

pub const Resolved = struct {
    rows: usize,
    clip_bottom: ?u32 = null,
    footer_top: ?u32 = null,
    scroll_offset_y: f32 = 0,

    pub fn hitRows(self: Resolved, size: Size) usize {
        if (size.cell.height == 0) return self.rows;
        const pixels = @as(f32, @floatFromInt(self.contentBottom(size) -| size.padding.top)) + self.scroll_offset_y;
        return @intFromFloat(@ceil(pixels / @as(f32, @floatFromInt(size.cell.height))));
    }

    /// Edge coordinates and fade lengths, in physical pixels. No history walk,
    /// layer mask, intermediate texture, or independent animation clock.
    pub fn fadeBounds(self: Resolved, size: Size, bar: terminal.Scrollbar, enabled: bool) [4]f32 {
        if (!enabled or size.cell.height == 0) return @splat(0);
        const top: f32 = @floatFromInt(size.padding.top);
        const bottom: f32 = @floatFromInt(self.contentBottom(size));
        const height: f32 = @floatFromInt(size.cell.height);
        const maximum = bar.total -| bar.len;
        const length = @min(height * 0.75, @max(0, (bottom - top) * 0.5));
        const above = @as(f32, @floatFromInt(bar.offset)) * height + self.scroll_offset_y;
        const below = @as(f32, @floatFromInt(maximum -| bar.offset)) * height - self.scroll_offset_y;
        return .{ top, bottom, std.math.clamp(above, 0, length), std.math.clamp(below, 0, length) };
    }

    pub fn sameGeometry(self: Resolved, other: Resolved) bool {
        return self.rows == other.rows and self.clip_bottom == other.clip_bottom and self.footer_top == other.footer_top;
    }

    pub fn contentBottom(self: Resolved, size: Size) u32 {
        return self.clip_bottom orelse @intCast(@min(size.screen.height, @as(u64, size.padding.top) + @as(u64, self.rows) * size.cell.height));
    }

    pub fn scrollbar(self: Resolved, value: terminal.Scrollbar) terminal.Scrollbar {
        const hidden = value.len -| self.rows;
        // Subtract the same tail from total and len: maximum offset is stable.
        return .{ .total = value.total -| hidden, .len = value.len -| hidden, .offset = value.offset };
    }
};

pub fn resolve(self: NativeViewport, term: *const terminal.Terminal, size: Size) Resolved {
    const plain: Resolved = .{ .rows = term.rows };
    if (self.footer_height == 0 or term.screens.active_key != .primary or
        !term.native_prompt_active or size.cell.height == 0) return plain;
    if (self.covered_rows > 0 and !self.transferring and promptTailRows(term) != self.covered_rows)
        return plain;
    const top = size.screen.height -| self.footer_height;
    const available = (top -| size.padding.top) / size.cell.height;
    // A full-reservation fallback cannot cover output during its queued resize.
    if (self.covered_rows == 0 and available < term.rows) return plain;
    const rows = @min(available, term.rows -| @as(usize, self.covered_rows));
    if (rows == 0) return plain;
    // The dock always paints a two-row caption. Its separator is inset from
    // the layout origin: content must reach that painted edge, including the
    // partial last row. Row count still owns the unchanged scroll range.
    const caption = Chrome.captionLayout(term.cols, size.cell.height, size.command_padding, 2);
    const edge = @min(size.screen.height, top + @as(u32, @intFromFloat(caption.separator_y)));
    return .{ .rows = rows, .clip_bottom = edge, .footer_top = top };
}

/// O(at most three prompt rows), independent of scrollback and viewport. The
/// current A/B must describe the empty final two (legacy) or three screen rows.
/// Background output, erase, continuation, C, or a different ID fail open.
pub fn promptTailRows(term: *const terminal.Terminal) u2 {
    if (term.screens.active_key != .primary or !term.native_prompt_active) return 0;
    const screen = term.screens.active;
    // Image placements can paint cells which are textually blank. Avoid a scan
    // through all placements: retain the full footer reservation in that case.
    if (comptime @import("terminal_options").kitty_graphics) {
        if (screen.kitty_images.placements.count() != 0) return 0;
    }
    const items = screen.command_blocks.blocks.items;
    if (items.len == 0 or screen.cursor.x != 0 or screen.cursor.pending_wrap) return 0;
    const block = items[items.len - 1];
    if (block.complete or !std.mem.eql(u8, &block.id, &term.native_prompt_id) or
        !std.mem.eql(u8, &block.id, &term.last_primary_input_id)) return 0;
    const header = block.header orelse return 0;
    const input = block.input orelse return 0;
    if (header.garbage or input.garbage) return 0;
    const after_header = header.down(1) orelse return 0;
    const legacy = after_header.node == input.node and after_header.y == input.y;
    const middle = if (legacy) null else after_header;
    const expected_input = if (legacy) after_header else after_header.down(1) orelse return 0;
    const bottom = screen.pages.getBottomRight(.screen) orelse return 0;
    if (expected_input.node != input.node or expected_input.y != input.y or
        bottom.node != input.node or bottom.y != input.y or
        screen.cursor.page_pin.node != input.node or screen.cursor.page_pin.y != input.y) return 0;
    if (Chrome.headerHasVisibleOutput(header.*) or Chrome.headerHasVisibleOutput(input.*)) return 0;
    if (middle) |pin| if (Chrome.headerHasVisibleOutput(pin)) return 0;
    return if (legacy) 2 else 3;
}

const test_size: Size = .{ .screen = .{ .width = 800, .height = 600 }, .cell = .{ .width = 8, .height = 17 }, .padding = .{ .top = 2, .bottom = 20 }, .command_padding = 6 };
const test_footer: NativeViewport = .{ .footer_height = 46, .covered_rows = 2 };

test "native viewport pixel crop does not move the footer or change scroll range" {
    const t = std.testing;
    const plain: Resolved = .{ .rows = 10, .clip_bottom = 160, .footer_top = 166 };
    var fractional = plain;
    fractional.scroll_offset_y = 7;
    try t.expect(plain.sameGeometry(fractional));
    try t.expectEqual(@as(usize, 11), fractional.hitRows(.{ .screen = .{ .width = 800, .height = 600 }, .cell = .{ .width = 8, .height = 16 }, .padding = .{} }));
    const bar: terminal.Scrollbar = .{ .total = 100, .len = 12, .offset = 20 };
    try t.expectEqualDeep(plain.scrollbar(bar), fractional.scrollbar(bar));
}

fn testPrompt() !terminal.Terminal {
    return testPromptRows(1);
}

fn testPromptRows(header_rows: u2) !terminal.Terminal {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 80, .rows = 34 });
    errdefer term.deinit(t.allocator);
    for (0..40) |_| try term.linefeed();
    try term.semanticPrompt(.{ .action = .fresh_line_new_prompt, .options_unvalidated = "aid=footer" });
    for (0..header_rows) |_| try term.linefeed();
    try term.semanticPrompt(.{ .action = .end_prompt_start_input, .options_unvalidated = "aid=footer" });
    return term;
}

test "native viewport compact tail preserves scroll range at live end and history" {
    const t = std.testing;
    var term = try testPrompt();
    defer term.deinit(t.allocator);
    for ([_]bool{ true, false, true }) |bottom| {
        term.scrollViewport(if (bottom) .bottom else .top);
        try t.expectEqual(@as(u2, 2), promptTailRows(&term));
        const view = test_footer.resolve(&term, test_size);
        try t.expectEqual(@as(usize, 32), view.rows);
        try t.expectEqual(@as(?u32, 558), view.clip_bottom);
        try t.expectEqual(@as(?u32, 554), view.footer_top);
        const raw = term.screens.active.pages.scrollbar();
        const visible = view.scrollbar(raw);
        try t.expectEqual(raw.total - raw.len, visible.total - visible.len);
        try t.expectEqual(raw.offset, visible.offset);
        try t.expectEqual(@as(usize, 34), term.rows);
        // Exactly the two reserved prompt rows are behind the footer. The last
        // completed line remains above the crop, and coordinate offsets stay 0.
        const first = term.screens.active.pages.getTopLeft(.viewport);
        const last = first.down(view.rows - 1).?;
        try t.expectEqual(@as(usize, 31), term.screens.active.pages.pointFromPin(.viewport, last).?.viewport.y);
    }
}

test "native viewport two-row caption validates all three tail rows and rejects legacy crop" {
    const t = std.testing;
    var term = try testPromptRows(2);
    defer term.deinit(t.allocator);
    const footer: NativeViewport = .{ .footer_height = 63, .covered_rows = 3 };
    try t.expectEqual(@as(u2, 3), promptTailRows(&term));
    for ([_]bool{ true, false }) |bottom| {
        term.scrollViewport(if (bottom) .bottom else .top);
        const view = footer.resolve(&term, test_size);
        try t.expectEqual(@as(usize, 31), view.rows);
        const raw = term.screens.active.pages.scrollbar();
        const visible = view.scrollbar(raw);
        try t.expectEqual(raw.total - raw.len, visible.total - visible.len);
    }
    // Output in the newly reserved middle row must revoke the crop, too.
    term.setCursorPos(33, 1);
    try term.print('x');
    term.setCursorPos(34, 1);
    try t.expectEqual(@as(u2, 0), promptTailRows(&term));
    try t.expectEqual(null, footer.resolve(&term, test_size).clip_bottom);

    var legacy = try testPrompt();
    defer legacy.deinit(t.allocator);
    try t.expectEqual(@as(u2, 2), promptTailRows(&legacy));
    try t.expectEqual(null, footer.resolve(&legacy, test_size).clip_bottom);
}

test "native viewport background output without C revokes crop before fallback resize" {
    const t = std.testing;
    var term = try testPrompt();
    defer term.deinit(t.allocator);
    try term.printString("background output");
    try t.expect(term.native_prompt_active);
    try t.expectEqual(@as(u2, 0), promptTailRows(&term));
    const unmasked = test_footer.resolve(&term, test_size);
    try t.expectEqual(@as(usize, 34), unmasked.rows);
    try t.expectEqual(null, unmasked.clip_bottom);
    var fallback = test_footer;
    fallback.covered_rows = 0;
    try t.expectEqual(null, fallback.resolve(&term, test_size).footer_top);
    // The core preserves bytes during the smaller real grid resize; only then
    // may the footer occupy separate padding. This does not model a later
    // user shell SIGWINCH redraw, which can independently erase its own input.
    var mutex: std.Io.Mutex = .init;
    const state: @import("State.zig") = .{ .mutex = &mutex, .terminal = &term, .native_input_enabled = true };
    try term.resize(t.allocator, .{ .cols = 80, .rows = 32, .preserve_prompt = state.preservesNativePrompt() });
    const settled = fallback.resolve(&term, test_size);
    try t.expectEqual(@as(usize, 32), settled.rows);
    try t.expectEqual(@as(?u32, 558), settled.clip_bottom);
    const text = try term.plainString(t.allocator);
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "background output") != null);
}

test "native viewport validates prompt identity blank cells and terminal ownership" {
    const t = std.testing;
    const Case = enum { spaces, decorated, overwritten_header, stale_id, secondary, output, alternate, reset };
    for (std.enums.values(Case)) |case| {
        var term = try testPrompt();
        defer term.deinit(t.allocator);
        switch (case) {
            .spaces => {
                try term.printString("  ");
                term.carriageReturn();
            },
            .decorated => {
                try term.setAttribute(.{ .direct_color_bg = .{ .r = 255, .g = 0, .b = 0 } });
                try term.print(' ');
                term.carriageReturn();
            },
            .overwritten_header => {
                term.setCursorPos(33, 1);
                try term.print('x');
                term.setCursorPos(34, 1);
            },
            .stale_id => term.last_primary_input_id[0] = 'x',
            .secondary => try term.semanticPrompt(.{ .action = .prompt_start, .options_unvalidated = "k=s" }),
            .output => try term.semanticPrompt(.{ .action = .end_input_start_output, .options_unvalidated = "aid=footer" }),
            .alternate => {
                _ = try term.switchScreen(.alternate);
            },
            .reset => term.fullReset(),
        }
        try t.expectEqual(@as(u2, if (case == .spaces) 2 else 0), promptTailRows(&term));
        const view = test_footer.resolve(&term, test_size);
        try t.expectEqual(case == .spaces, view.clip_bottom != null);
    }
}

test "native viewport accepted echo stays covered only until parsed ownership boundary" {
    const t = std.testing;
    var term = try testPrompt();
    defer term.deinit(t.allocator);
    var transfer = test_footer;
    transfer.transferring = true;
    try term.printString("read value");
    try t.expect(transfer.resolve(&term, test_size).clip_bottom != null);
    try term.semanticPrompt(.{ .action = .end_input_start_output, .options_unvalidated = "aid=footer" });
    try t.expectEqual(null, transfer.resolve(&term, test_size).clip_bottom);
    try t.expectEqual(@as(usize, 34), transfer.resolve(&term, test_size).rows);
}

test "native viewport image output on blank prompt tail refuses compaction" {
    if (comptime !@import("terminal_options").kitty_graphics) return error.SkipZigTest;
    const t = std.testing;
    var term = try testPrompt();
    defer term.deinit(t.allocator);
    const screen = term.screens.active;
    try screen.kitty_images.addImage(t.io, t.allocator, screen, .{ .id = 1, .width = 1, .height = 1 });
    const pin = try screen.pages.trackPin(screen.cursor.page_pin.*);
    try screen.kitty_images.addPlacement(t.io, t.allocator, screen, 1, 1, .{
        .location = .{ .pin = pin },
        .columns = 1,
        .rows = 1,
    });
    try t.expect(!Chrome.headerHasVisibleOutput(screen.cursor.page_pin.*));
    try t.expectEqual(@as(u2, 0), promptTailRows(&term));
    try t.expectEqual(null, test_footer.resolve(&term, test_size).clip_bottom);
}

test "native viewport fills the fractional row up to the sticky footer" {
    const t = std.testing;
    var term = try testPrompt();
    defer term.deinit(t.allocator);
    term.scrollViewport(.top);
    var view = test_footer.resolve(&term, test_size);
    try t.expectEqual(view.footer_top.? + 4, view.clip_bottom.?);
    try t.expectEqual(@as(usize, 33), view.hitRows(test_size));
    view.scroll_offset_y = 16;
    try t.expectEqual(@as(usize, 34), view.hitRows(test_size));
    try t.expectEqual(@as(u32, 558), view.contentBottom(test_size));
}

test "native viewport fades only the edges with overflow and disables for programs" {
    const t = std.testing;
    var viewport: Resolved = .{ .rows = 32, .clip_bottom = 554 };
    var bar: terminal.Scrollbar = .{ .total = 100, .len = 34, .offset = 0 };
    try t.expectEqual([4]f32{ 2, 554, 0, 12.75 }, viewport.fadeBounds(test_size, bar, true));
    bar.offset = 66;
    try t.expectEqual([4]f32{ 2, 554, 12.75, 0 }, viewport.fadeBounds(test_size, bar, true));
    bar.offset = 65;
    viewport.scroll_offset_y = 16;
    try t.expectEqual([4]f32{ 2, 554, 12.75, 1 }, viewport.fadeBounds(test_size, bar, true));
    try t.expectEqual(@as([4]f32, @splat(0)), viewport.fadeBounds(test_size, bar, false));
    bar = .{ .total = 34, .len = 34, .offset = 0 };
    viewport.scroll_offset_y = 0;
    try t.expectEqual([4]f32{ 2, 554, 0, 0 }, viewport.fadeBounds(test_size, bar, true));
}
