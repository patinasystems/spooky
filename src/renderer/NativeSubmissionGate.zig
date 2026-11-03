//! Keep an empty native submit's old frame until its next real shell boundary.
//! This never pauses parsing, changes DEC2026, or owns terminal pins. The
//! caller holds the terminal mutex except when calling requestCancel.
const NativeSubmissionGate = @This();
const std = @import("std");
const terminal = @import("../terminal/main.zig");
const Chrome = @import("CommandChrome.zig");
const Size = @import("size.zig").Size;

/// A fail-open ceiling, not a minimum display delay. C, a new primary B,
/// visible output, interaction, and geometry changes release immediately.
pub const watchdog_ms: i64 = 100;
const maximum_tail_rows = 8;

deadline_ms: ?i64 = null,
input_id: [65]u8 = @splat(0),
started_id: [65]u8 = @splat(0),
size: Size = undefined,
rows: terminal.size.CellCountInt = 0,
cols: terminal.size.CellCountInt = 0,
cancel_requested: std.atomic.Value(bool) = .init(false),

/// Called once, before publishing/triggering an accepted empty native draft.
/// Repeated calls for the same B cannot restart or extend a prior deadline.
pub fn begin(self: *NativeSubmissionGate, term: *const terminal.Terminal, size: Size, now_ms: i64) bool {
    if (std.mem.eql(u8, &self.input_id, &term.last_primary_input_id)) {
        return self.shouldHold(term, size, true, false, now_ms);
    }
    self.cancel();
    if (!eligible(term) or term.last_primary_input_id[0] == 0 or
        !std.mem.eql(u8, &term.native_prompt_id, &term.last_primary_input_id)) return false;
    self.input_id = term.last_primary_input_id;
    self.started_id = term.last_started_command_id;
    self.size = size;
    self.rows = term.rows;
    self.cols = term.cols;
    _ = self.cancel_requested.swap(false, .acq_rel);
    if (!self.blankTail(term)) return false;
    self.deadline_ms = now_ms +| watchdog_ms;
    return true;
}

pub fn shouldHold(
    self: *NativeSubmissionGate,
    term: *const terminal.Terminal,
    size: Size,
    native_enabled: bool,
    terminal_requested: bool,
    now_ms: i64,
) bool {
    const deadline = self.deadline_ms orelse return false;
    if (self.cancel_requested.swap(false, .acq_rel) or now_ms >= deadline or
        !native_enabled or terminal_requested or !eligible(term) or
        !std.meta.eql(size, self.size) or term.rows != self.rows or term.cols != self.cols or
        !std.mem.eql(u8, &self.input_id, &term.last_primary_input_id) or
        !std.mem.eql(u8, &self.started_id, &term.last_started_command_id) or
        !self.blankTail(term))
    {
        self.cancel();
        return false;
    }
    return true;
}

pub fn cancel(self: *NativeSubmissionGate) void {
    self.deadline_ms = null;
}

/// Scroll/selection/search may request release without acquiring the frame
/// mutex. The renderer consumes this flag before inspecting any terminal data.
pub fn requestCancel(self: *NativeSubmissionGate) void {
    self.cancel_requested.store(true, .release);
}

fn eligible(term: *const terminal.Terminal) bool {
    if (term.screens.active_key != .primary or !term.native_prompt_active) return false;
    const screen = term.screens.active;
    if (screen.selection != null or screen.pages.viewport != .active or screen.cursor.pending_wrap) return false;
    if (comptime @import("terminal_options").kitty_graphics) {
        if (screen.kitty_images.placements.count() != 0) return false;
    }
    return true;
}

/// Inspect only the old input row through the current cursor, at most eight
/// rows. ZLE's PROMPT_SP can transiently print `%` then erase it in one parse
/// batch; its net blank result is safe. A partial batch with visible `%`, hook
/// output, an error, styled space, or an invalidated pin fails open immediately.
fn blankTail(self: *const NativeSubmissionGate, term: *const terminal.Terminal) bool {
    const screen = term.screens.active;
    const blocks = screen.command_blocks.blocks.items;
    var index = blocks.len;
    // Normally the old B belongs to the final block; after the next A it is
    // second-last. Additional A markers without B are an unknown transition,
    // so fail open rather than searching older history.
    const lower = blocks.len -| 2;
    var input: ?terminal.Pin = null;
    while (index > lower) {
        index -= 1;
        const block = blocks[index];
        if (!std.mem.eql(u8, &block.id, &self.input_id)) continue;
        const pin = block.input orelse return false;
        if (pin.garbage or pin.x != 0) return false;
        input = pin.*;
        break;
    }
    var pin = input orelse return false;
    const cursor = screen.cursor.page_pin;
    for (0..maximum_tail_rows) |_| {
        if (Chrome.headerHasVisibleOutput(pin)) return false;
        if (pin.node == cursor.node and pin.y == cursor.y) return true;
        pin = pin.down(1) orelse return false;
    }
    return false;
}

const test_size: Size = .{
    .screen = .{ .width = 640, .height = 240 },
    .cell = .{ .width = 8, .height = 20 },
    .padding = .{},
};

fn testPrompt() !terminal.Terminal {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 80, .rows = 12 });
    errdefer term.deinit(t.allocator);
    var stream = term.vtStream();
    defer stream.deinit();
    for (0..20) |_| stream.nextSlice("\r\n");
    stream.nextSlice("output\r\n\x1b]133;A;aid=old\x07\r\n\x1b]133;B;aid=old\x07");
    return term;
}

test "native submission gate holds empty newline and A until new B without mutating terminal" {
    const t = std.testing;
    var term = try testPrompt();
    defer term.deinit(t.allocator);
    var gate: NativeSubmissionGate = .{};
    try t.expect(gate.begin(&term, test_size, 1000));
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\r\n");
    try t.expect(gate.shouldHold(&term, test_size, true, false, 1001));
    stream.nextSlice("\x1b]133;D;0;aid=old\x07\x1b]133;A;aid=new\x07\r\n");
    const cursor = term.screens.active.cursor.page_pin.*;
    const modes = term.modes;
    try t.expect(gate.shouldHold(&term, test_size, true, false, 1002));
    try t.expect(std.meta.eql(cursor, term.screens.active.cursor.page_pin.*));
    try t.expect(std.meta.eql(modes, term.modes));
    stream.nextSlice("\x1b]133;B;aid=new\x07");
    try t.expect(!gate.shouldHold(&term, test_size, true, false, 1003));
    try t.expectEqual(null, gate.deadline_ms);
    // A distinct prompt can start a fresh transaction immediately.
    try t.expect(gate.begin(&term, test_size, 1004));
}

test "native submission gate releases foreground continuation alternate reset and foreign C" {
    const t = std.testing;
    for ([_][]const u8{
        "\x1b]133;C;aid=old\x07",
        "\x1b]133;C;aid=foreign\x07",
        "\x1b]133;C;aid=old\x07\x1b]133;D;0;aid=old\x07",
        "\x1b]133;P;k=s\x07",
        "\x1b]133;P;k=c\x07",
        "\x1b[?1049h",
        "\x1bc",
    }) |sequence| {
        var term = try testPrompt();
        defer term.deinit(t.allocator);
        var gate: NativeSubmissionGate = .{};
        try t.expect(gate.begin(&term, test_size, 0));
        var stream = term.vtStream();
        defer stream.deinit();
        stream.nextSlice(sequence);
        try t.expect(!gate.shouldHold(&term, test_size, true, false, 1));
    }
}

test "native submission gate visible text decorated blanks and invalidated input fail open" {
    const t = std.testing;
    for ([_][]const u8{
        "\r\nhook output",
        "\r\n\x1b[41m ",
        "\r\n\x1b[4m ",
        "\r\n\x1b]8;;https://example.com\x07 ",
        "\x1b[2J",
    }) |sequence| {
        var term = try testPrompt();
        defer term.deinit(t.allocator);
        var gate: NativeSubmissionGate = .{};
        try t.expect(gate.begin(&term, test_size, 0));
        var stream = term.vtStream();
        defer stream.deinit();
        stream.nextSlice(sequence);
        try t.expect(!gate.shouldHold(&term, test_size, true, false, 1));
    }
}

test "native submission gate PROMPT_SP accepts only its final blank state" {
    const t = std.testing;
    for ([_]bool{ true, false }) |complete| {
        var term = try testPrompt();
        defer term.deinit(t.allocator);
        var gate: NativeSubmissionGate = .{};
        try t.expect(gate.begin(&term, test_size, 0));
        var stream = term.vtStream();
        defer stream.deinit();
        stream.nextSlice("\r\n\x1b[1m\x1b[7m%\x1b[27m\x1b[1m\x1b[0m");
        if (complete) {
            const spaces: [79]u8 = @splat(' ');
            stream.nextSlice(&spaces);
            stream.nextSlice("\r \r");
        }
        try t.expectEqual(complete, gate.shouldHold(&term, test_size, true, false, 1));
    }
}

test "native submission gate watchdog is absolute and cannot be restarted for the same B" {
    const t = std.testing;
    var term = try testPrompt();
    defer term.deinit(t.allocator);
    var gate: NativeSubmissionGate = .{};
    try t.expect(gate.begin(&term, test_size, 10));
    try t.expect(gate.begin(&term, test_size, 90));
    try t.expectEqual(@as(?i64, 110), gate.deadline_ms);
    try t.expect(gate.shouldHold(&term, test_size, true, false, 109));
    try t.expect(!gate.shouldHold(&term, test_size, true, false, 110));
    try t.expect(!gate.begin(&term, test_size, 111));
}

test "native submission gate interaction ownership and size changes release immediately" {
    const t = std.testing;
    const Case = enum { cancel, atomic_cancel, disabled, terminal_requested, viewport, selection, pixel, font, padding, grid };
    for (std.enums.values(Case)) |case| {
        var term = try testPrompt();
        defer term.deinit(t.allocator);
        var gate: NativeSubmissionGate = .{};
        try t.expect(gate.begin(&term, test_size, 0));
        var size = test_size;
        switch (case) {
            .cancel => gate.cancel(),
            .atomic_cancel => gate.requestCancel(),
            .disabled, .terminal_requested => {},
            .viewport => term.scrollViewport(.top),
            .selection => try term.screens.active.select(terminal.Selection.init(
                term.screens.active.cursor.page_pin.*,
                term.screens.active.cursor.page_pin.*,
                false,
            )),
            .pixel => size.screen.width += 1,
            .font => size.cell.height += 1,
            .padding => size.padding.bottom += 1,
            .grid => try term.resize(t.allocator, .{ .cols = 80, .rows = 11 }),
        }
        try t.expect(!gate.shouldHold(&term, size, case != .disabled, case == .terminal_requested, 1));
    }
}

test "native submission gate tail scan bounded through scrollback and garbage anchors" {
    const t = std.testing;
    for ([_]usize{ 7, 8 }) |rows| {
        var term = try testPrompt();
        defer term.deinit(t.allocator);
        var gate: NativeSubmissionGate = .{};
        try t.expect(gate.begin(&term, test_size, 0));
        for (0..rows) |_| try term.linefeed();
        try t.expectEqual(rows == 7, gate.shouldHold(&term, test_size, true, false, 1));
    }
    var term = try testPrompt();
    defer term.deinit(t.allocator);
    var gate: NativeSubmissionGate = .{};
    try t.expect(gate.begin(&term, test_size, 0));
    const input = term.screens.active.command_blocks.blocks.items[0].input.?;
    input.garbage = true;
    try t.expect(!gate.shouldHold(&term, test_size, true, false, 1));
}

test "native submission gate multiple newer headers without input fail open" {
    const t = std.testing;
    var term = try testPrompt();
    defer term.deinit(t.allocator);
    var gate: NativeSubmissionGate = .{};
    try t.expect(gate.begin(&term, test_size, 0));
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\r\n\x1b]133;A;aid=new\x07\r\n\x1b]133;A;aid=newer\x07");
    try t.expect(!gate.shouldHold(&term, test_size, true, false, 1));
}
