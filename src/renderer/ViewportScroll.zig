//! Pixel remainder for primary-screen history scrolling. Terminal pins remain
//! whole rows; the renderer crops the first row and captures one row below it.
const ViewportScroll = @This();
const std = @import("std");
const terminal = @import("../terminal/main.zig");

row: u64 = 0,
cell_height: u32 = 0,
offset: f64 = 0,

pub fn reset(self: *ViewportScroll) void {
    self.* = .{};
}

/// External jumps, output following, resize and screen changes invalidate a
/// remainder. Never animate a terminal operation or invent momentum: macOS
/// supplies the complete physical trajectory, including its deceleration.
pub fn synchronize(self: *ViewportScroll, bar: terminal.Scrollbar, height: u32, enabled: bool) f32 {
    if (!enabled or self.row != bar.offset or self.cell_height != height or
        bar.offset >= bar.total -| bar.len) self.reset();
    return @floatCast(@round(self.offset));
}

pub fn currentOffset(self: *const ViewportScroll, bar: terminal.Scrollbar, height: u32, enabled: bool) f32 {
    if (!enabled or self.row != bar.offset or self.cell_height != height or
        bar.offset >= bar.total -| bar.len) return 0;
    return @floatCast(@round(self.offset));
}

/// Positive input moves toward earlier history. Return the whole-row change
/// for Terminal.scrollViewport; retain the remaining physical pixel crop.
pub fn scroll(self: *ViewportScroll, bar: terminal.Scrollbar, height: u32, pixels: f64) isize {
    _ = self.synchronize(bar, height, true);
    if (height == 0 or !std.math.isFinite(pixels)) return 0;
    const h: f64 = @floatFromInt(height);
    const maximum = bar.total -| bar.len;
    const position = @as(f64, @floatFromInt(bar.offset)) * h + self.offset - pixels;
    const clamped = std.math.clamp(position, 0, @as(f64, @floatFromInt(maximum)) * h);
    const row_float = @floor(clamped / h);
    const row: u64 = if (row_float >= @as(f64, @floatFromInt(maximum))) maximum else @intFromFloat(row_float);
    self.row = row;
    self.cell_height = height;
    self.offset = if (row == maximum) 0 else clamped - row_float * h;
    return if (row >= bar.offset) @intCast(row - bar.offset) else -@as(isize, @intCast(bar.offset - row));
}

test "pixel viewport consumes decelerating deltas without waiting for a row" {
    const t = std.testing;
    var viewport: ViewportScroll = .{};
    var bar: terminal.Scrollbar = .{ .total = 1000, .len = 40, .offset = 500 };
    var position: f64 = 500 * 34;
    for ([_]f64{ 17, 8, 4, 2, 1, 0.5, 0.25 }) |delta| {
        const rows = viewport.scroll(bar, 34, delta);
        bar.offset = @intCast(@as(i64, @intCast(bar.offset)) + rows);
        position -= delta;
        try t.expectApproxEqAbs(position, @as(f64, @floatFromInt(bar.offset)) * 34 + viewport.offset, 0.0001);
        try t.expect(viewport.offset >= 0 and viewport.offset < 34);
    }
}

test "pixel viewport clamps edges reverses and invalidates external jumps" {
    const t = std.testing;
    var viewport: ViewportScroll = .{};
    var bar: terminal.Scrollbar = .{ .total = 100, .len = 40, .offset = 60 };
    try t.expectEqual(@as(isize, -1), viewport.scroll(bar, 34, 1));
    bar.offset = 59;
    try t.expectEqual(@as(f64, 33), viewport.offset);
    try t.expectEqual(@as(isize, 1), viewport.scroll(bar, 34, -1));
    bar.offset = 60;
    try t.expectEqual(@as(f64, 0), viewport.offset);
    try t.expectEqual(@as(isize, 0), viewport.scroll(bar, 34, -100));
    try t.expectEqual(@as(isize, -60), viewport.scroll(bar, 34, 100_000));
    bar.offset = 0;
    try t.expectEqual(@as(f64, 0), viewport.offset);
    _ = viewport.scroll(bar, 34, -4);
    try t.expectEqual(@as(f32, 0), viewport.synchronize(bar, 34, false));
    _ = viewport.scroll(bar, 34, -4);
    bar.offset = 12;
    try t.expectEqual(@as(f32, 0), viewport.synchronize(bar, 34, true));
    _ = viewport.scroll(bar, 34, -4);
    try t.expectEqual(@as(f32, 0), viewport.synchronize(bar, 40, true));
}

test "pixel viewport keeps the exposed bottom row in terminal overscan" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 12, .rows = 4 });
    defer term.deinit(t.allocator);
    for (0..100) |_| {
        try term.print('x');
        term.carriageReturn();
        try term.linefeed();
    }
    term.scrollViewport(.top);
    var viewport: ViewportScroll = .{};
    const delta = viewport.scroll(term.screens.active.pages.scrollbar(), 34, -5);
    term.scrollViewport(.{ .delta = delta });
    try t.expectEqual(@as(f64, 5), viewport.offset);
    var state: terminal.RenderState = .empty;
    defer state.deinit(t.allocator);
    state.overscan_request = .{ .below = 1 };
    try state.update(t.allocator, &term);
    try t.expectEqual(@as(usize, 1), state.overscan.below);
    try t.expectEqual(@as(usize, 5), state.row_data.len);
    try t.expect(term.screens.active.pages.pin(.{ .viewport = .{ .x = 0, .y = 4 } }) != null);
}
