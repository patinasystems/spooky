//! Render-only command captions. Anchors come from the real terminal; text is
//! bounded metadata, never inserted into the PTY, scrollback, or selections.
const CommandChrome = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../terminal/main.zig");
const Blocks = @import("../terminal/CommandBlocks.zig");
const unicode = @import("../unicode/main.zig");

pub const capacity = 1024;
pub const batch_capacity = 128;
pub const Input = struct {
    id: []const u8,
    label: []const u8,
    suffix: []const u8,
    current: bool = false,
    pinned: bool = false,
};
pub const Metadata = struct {
    label: [512]u8 = @splat(0),
    label_len: u16 = 0,
    suffix: [128]u8 = @splat(0),
    suffix_len: u8 = 0,
};
pub const Header = struct {
    id: [65]u8,
    row: u16,
    metadata: Metadata,
    current: bool = false,
    pinned: bool = false,
};
pub const Snapshot = struct {
    headers: []const Header = &.{},
    pinned_offset_from_bottom: f32 = -1,
    revision: u64 = 0,
};

enabled: bool = false,
pinned_offset_from_bottom: f32 = -1,
revision: u64 = 0,
current_id: [65]u8 = @splat(0),
pinned_id: [65]u8 = @splat(0),
entries: std.AutoArrayHashMapUnmanaged([65]u8, Metadata) = .{},

pub fn deinit(self: *CommandChrome, alloc: Allocator) void {
    self.entries.deinit(alloc);
    self.* = .{};
}

/// Called under renderer.State.mutex. Merge changed IDs so fast scrolling does
/// not depend on the GUI polling each newly visible row. All text is owned here.
pub fn update(
    self: *CommandChrome,
    alloc: Allocator,
    enabled: bool,
    pinned_offset_from_bottom: f32,
    inputs: []const Input,
) Allocator.Error!bool {
    const offset = if (std.math.isFinite(pinned_offset_from_bottom) and pinned_offset_from_bottom >= 0)
        pinned_offset_from_bottom
    else
        -1;
    var current_id: [65]u8 = @splat(0);
    var pinned_id: [65]u8 = @splat(0);
    var changed = self.enabled != enabled or self.pinned_offset_from_bottom != offset;
    // Reserve first: after this succeeds every update is infallible, so a
    // partial merge can never fail to publish its revision to the renderer.
    try self.entries.ensureTotalCapacity(alloc, @min(capacity, self.entries.count() + @min(inputs.len, batch_capacity)));
    self.enabled = enabled;
    self.pinned_offset_from_bottom = offset;
    for (inputs[0..@min(inputs.len, batch_capacity)]) |input| {
        if (!Blocks.validID(input.id)) continue;
        var id: [65]u8 = @splat(0);
        @memcpy(id[0..input.id.len], input.id);
        if (input.current) current_id = id;
        if (input.pinned) pinned_id = id;
        var metadata: Metadata = .{};
        metadata.label_len = @intCast(copyText(&metadata.label, input.label));
        metadata.suffix_len = @intCast(copyText(&metadata.suffix, input.suffix));
        if (self.entries.getPtr(id)) |old| {
            if (!std.meta.eql(old.*, metadata)) {
                old.* = metadata;
                changed = true;
            }
        } else {
            if (self.entries.count() == capacity) _ = self.entries.orderedRemove(self.entries.keys()[0]);
            self.entries.putAssumeCapacity(id, metadata);
            changed = true;
        }
    }
    if (!std.mem.eql(u8, &self.current_id, &current_id) or !std.mem.eql(u8, &self.pinned_id, &pinned_id)) changed = true;
    self.current_id = current_id;
    self.pinned_id = pinned_id;
    if (changed) self.revision +%= 1;
    return changed;
}

/// Snapshot only visible header rows while the real terminal is locked. The
/// returned metadata values are copied into the frame arena; shaping is later.
pub fn snapshot(self: *const CommandChrome, alloc: Allocator, term: *terminal.Terminal) Allocator.Error!Snapshot {
    var result: Snapshot = .{ .revision = self.revision };
    if (!self.enabled or term.screens.active_key != .primary) return result;
    var headers: std.ArrayList(Header) = .empty;
    errdefer headers.deinit(alloc);
    const screen = term.screens.active;
    for (screen.command_blocks.blocks.items) |block| {
        const pin = block.header orelse continue;
        if (pin.garbage) continue;
        const point = screen.pages.pointFromPin(.viewport, pin.*) orelse continue;
        if (point.viewport.y >= screen.pages.rows) continue;
        // A program can overwrite cells without erasing them first. Never
        // cover real output with chrome just because a tracked pin survived.
        if (headerHasVisibleOutput(pin.*)) continue;
        try headers.append(alloc, .{
            .id = block.id,
            .row = @intCast(point.viewport.y),
            .metadata = self.entries.get(block.id) orelse .{},
            .current = std.mem.eql(u8, &block.id, &self.current_id),
        });
    }
    if (self.pinned_offset_from_bottom >= 0 and self.pinned_id[0] != 0) {
        if (self.entries.get(self.pinned_id)) |metadata| {
            try headers.append(alloc, .{ .id = self.pinned_id, .row = 0, .metadata = metadata, .current = true, .pinned = true });
            result.pinned_offset_from_bottom = self.pinned_offset_from_bottom;
        }
    }
    result.headers = try headers.toOwnedSlice(alloc);
    return result;
}

/// ZLE can pad a reserved prompt row with literal ASCII spaces. Those cells
/// count as terminal text but have no visible ink. Preserve decorated spaces,
/// background colors, and combining clusters just like printable output.
fn headerHasVisibleOutput(pin: terminal.Pin) bool {
    if (pin.rowAndCell().row.blank) return false;
    const page = pin.node.page();
    for (pin.cells(.all)) |cell| {
        if (cell.content_tag != .codepoint) return true;
        const cp = cell.codepoint();
        if (cp != 0 and cp != ' ') return true;
        if (cell.wide != .narrow or cell.hyperlink) return true;
        if (cell.style_id != 0) {
            const style = page.styles.get(page.memory, cell.style_id).*;
            if (style.bg_color.tag != .none or style.flags.inverse or
                style.flags.underline != .none or style.flags.strikethrough or
                style.flags.overline) return true;
        }
    }
    return false;
}

/// Truncate only at valid UTF-8 boundaries. Control bytes are rendered as
/// spaces: labels such as a directory name can never become VT instructions.
fn copyText(output: []u8, input: []const u8) usize {
    var len: usize = 0;
    var index: usize = 0;
    while (index < input.len) {
        const count = std.unicode.utf8ByteSequenceLength(input[index]) catch break;
        if (input.len - index < count) break;
        const bytes = input[index..][0..count];
        const cp = std.unicode.utf8Decode(bytes) catch break;
        index += count;
        if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) {
            if (len == output.len) break;
            output[len] = ' ';
            len += 1;
        } else {
            if (len + bytes.len > output.len) break;
            @memcpy(output[len..][0..bytes.len], bytes);
            len += bytes.len;
        }
    }
    return len;
}

const Text = struct {
    cps: [512]u21 = @splat(0),
    len: usize = 0,
    width: usize = 0,

    fn init(bytes: []const u8) Text {
        var result: Text = .{};
        var view = std.unicode.Utf8View.init(bytes) catch return result;
        var iter = view.iterator();
        while (iter.nextCodepoint()) |cp| {
            if (result.len == result.cps.len) break;
            result.cps[result.len] = cp;
            result.len += 1;
        }
        var i: usize = 0;
        while (i < result.len) {
            const cluster = unicode.graphemeWidth(u21, result.cps[i..result.len]);
            result.width += cluster.width;
            i += cluster.len;
        }
        return result;
    }

    fn write(self: *const Text, term: *terminal.Terminal, width: usize) !void {
        const truncated = self.width > width;
        const available = width -| @intFromBool(truncated);
        var used: usize = 0;
        var i: usize = 0;
        while (i < self.len) {
            const cluster = unicode.graphemeWidth(u21, self.cps[i..self.len]);
            if (used + cluster.width > available) break;
            for (self.cps[i..][0..cluster.len]) |cp| try term.print(cp);
            used += cluster.width;
            i += cluster.len;
        }
        if (truncated and width > 0) try term.print(0x2026);
    }
};

/// Fill a reusable scratch row solely for the existing font shaper. It has no
/// PTY or escape parser and never changes the real terminal or its selections.
pub fn writeCaption(term: *terminal.Terminal, metadata: *const Metadata) !void {
    term.fullReset();
    term.modes.set(.wraparound, false);
    term.modes.set(.grapheme_cluster, true);
    const cols: usize = term.cols;
    if (cols == 0) return;
    const label = Text.init(metadata.label[0..metadata.label_len]);
    const suffix = Text.init(metadata.suffix[0..metadata.suffix_len]);
    const suffix_width = @min(suffix.width, cols / 2);
    const label_width = if (suffix_width > 0) cols -| (suffix_width + 2) else cols;
    try label.write(term, label_width);
    if (suffix_width > 0) {
        term.setCursorPos(1, cols - suffix_width + 1);
        try suffix.write(term, suffix_width);
    }
}

test "command chrome metadata merge preserves offscreen labels and detects no-op" {
    const t = std.testing;
    var chrome: CommandChrome = .{};
    defer chrome.deinit(t.allocator);
    const first: Input = .{ .id = "1-1", .label = "/one", .suffix = "ok" };
    try t.expect(try chrome.update(t.allocator, true, -1, &.{first}));
    try t.expect(!try chrome.update(t.allocator, true, -1, &.{first}));
    const revision = chrome.revision;
    try t.expect(try chrome.update(t.allocator, true, 50, &.{.{ .id = "1-2", .label = "/two", .suffix = "", .current = true, .pinned = true }}));
    try t.expectEqual(@as(usize, 2), chrome.entries.count());
    try t.expect(chrome.revision != revision);
    try t.expectEqualStrings("1-2", std.mem.sliceTo(&chrome.pinned_id, 0));
}

test "command chrome sanitizes text and bounds its cache" {
    const t = std.testing;
    var chrome: CommandChrome = .{};
    defer chrome.deinit(t.allocator);
    var long: [513]u8 = @splat('a');
    long[511] = 0xc3;
    long[512] = 0xa9;
    _ = try chrome.update(t.allocator, true, -1, &.{.{ .id = "safe", .label = &long, .suffix = "a\x1b\nb" }});
    var emoji_tail: [512]u8 = @splat('a');
    @memcpy(emoji_tail[509..], "\xf0\x9f\x91");
    var prefix: [512]u8 = @splat(0);
    try t.expectEqual(@as(usize, 509), copyText(&prefix, &emoji_tail));
    try t.expectEqual(@as(usize, 511), copyText(&prefix, long[0..512]));
    const metadata = chrome.entries.values()[0];
    try t.expectEqual(@as(u16, 511), metadata.label_len);
    try t.expectEqualStrings("a  b", metadata.suffix[0..metadata.suffix_len]);
    for (0..capacity + 5) |i| {
        var buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&buf, "block-{d}", .{i});
        _ = try chrome.update(t.allocator, true, -1, &.{.{ .id = id, .label = "", .suffix = "" }});
    }
    try t.expectEqual(@as(usize, capacity), chrome.entries.count());
}

test "command chrome snapshots follow viewport and exclude erased and alternate headers" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 10, .rows = 3 });
    defer term.deinit(t.allocator);
    var chrome: CommandChrome = .{};
    defer chrome.deinit(t.allocator);
    _ = try chrome.update(t.allocator, true, 40, &.{.{ .id = "a", .label = "here", .suffix = "", .pinned = true }});
    try term.semanticPrompt(.{ .action = .fresh_line_new_prompt, .options_unvalidated = "aid=a" });
    try term.linefeed();
    {
        const s = try chrome.snapshot(t.allocator, &term);
        defer t.allocator.free(s.headers);
        try t.expectEqual(@as(usize, 2), s.headers.len);
        try t.expectEqual(@as(u16, 0), s.headers[0].row);
        try t.expect(s.headers[1].pinned);
    }
    term.setCursorPos(1, 1);
    try term.print('x');
    {
        const overwritten = try chrome.snapshot(t.allocator, &term);
        defer t.allocator.free(overwritten.headers);
        try t.expectEqual(@as(usize, 1), overwritten.headers.len);
        try t.expect(overwritten.headers[0].pinned);
    }
    term.screens.active.reset();
    {
        const s = try chrome.snapshot(t.allocator, &term);
        defer t.allocator.free(s.headers);
        try t.expectEqual(@as(usize, 1), s.headers.len);
        try t.expect(s.headers[0].pinned);
    }
    _ = try term.switchScreen(.alternate);
    const s = try chrome.snapshot(t.allocator, &term);
    defer t.allocator.free(s.headers);
    try t.expectEqual(@as(usize, 0), s.headers.len);
}

test "command chrome caption truncates whole graphemes and right aligns suffix" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 12, .rows = 1 });
    defer term.deinit(t.allocator);
    var metadata: Metadata = .{};
    metadata.label_len = @intCast(copyText(&metadata.label, "abcdefghi 👩‍💻"));
    metadata.suffix_len = @intCast(copyText(&metadata.suffix, "✓"));
    try writeCaption(&term, &metadata);
    const text = try term.plainString(t.allocator);
    defer t.allocator.free(text);
    try t.expectEqualStrings("abcdefgh…  ✓", text);
}

test "command chrome keeps space-padded headers but preserves visible output" {
    const t = std.testing;
    const Case = enum { spaces, colored_spaces, underline, background, combining, printable };
    for (std.enums.values(Case)) |case| {
        var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 10, .rows = 4 });
        defer term.deinit(t.allocator);
        var chrome: CommandChrome = .{};
        defer chrome.deinit(t.allocator);
        _ = try chrome.update(t.allocator, true, -1, &.{.{ .id = "history", .label = "label", .suffix = "ok" }});
        try term.semanticPrompt(.{ .action = .fresh_line_new_prompt, .options_unvalidated = "aid=history" });
        switch (case) {
            .colored_spaces => try term.setAttribute(.{ .direct_color_fg = .{ .r = 255, .g = 0, .b = 0 } }),
            .underline => try term.setAttribute(.{ .underline = .single }),
            .background => try term.setAttribute(.{ .direct_color_bg = .{ .r = 255, .g = 0, .b = 0 } }),
            else => {},
        }
        for (0..10) |_| try term.print(' ');
        if (case == .combining) try term.print(0x0301);
        if (case == .printable) {
            term.setCursorPos(1, 1);
            try term.print('x');
        }
        try term.setAttribute(.unset);
        term.setCursorPos(2, 1);
        try term.semanticPrompt(.{ .action = .end_command, .options_unvalidated = "0;aid=history" });
        const snapshot_value = try chrome.snapshot(t.allocator, &term);
        defer t.allocator.free(snapshot_value.headers);
        const expected: usize = if (case == .spaces or case == .colored_spaces) 1 else 0;
        try t.expectEqual(expected, snapshot_value.headers.len);
        if (expected == 1) {
            try t.expectEqual(@as(u16, 0), snapshot_value.headers[0].row);
            try t.expectEqualStrings("label", snapshot_value.headers[0].metadata.label[0..5]);
        }
    }
}
