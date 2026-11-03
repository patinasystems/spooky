//! Render-only command captions. Anchors come from the real terminal; text is
//! bounded metadata, never inserted into the PTY, scrollback, or selections.
const CommandChrome = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../terminal/main.zig");
const Blocks = @import("../terminal/CommandBlocks.zig");
const unicode = @import("../unicode/main.zig");
const Size = @import("size.zig").Size;

pub const capacity = 1024;
pub const batch_capacity = 128;
pub const Input = struct {
    id: []const u8,
    label: []const u8,
    suffix: []const u8,
    /// UTF-8 prefix of label occupied by the displayed directory, zero if none.
    path_len: usize = 0,
    current: bool = false,
    pinned: bool = false,
};
pub const Metadata = struct {
    label: [512]u8 = @splat(0),
    label_len: u16 = 0,
    path_len: u16 = 0,
    suffix: [128]u8 = @splat(0),
    suffix_len: u8 = 0,
};
pub const Header = struct {
    id: [65]u8,
    row: u16,
    rows: u2 = 1,
    above_viewport: bool = false,
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
        var path: [512]u8 = undefined;
        metadata.path_len = @intCast(copyText(&path, input.label[0..@min(input.path_len, input.label.len)]));
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
    const viewport_top = screen.pages.getTopLeft(.viewport);
    const pinned_metadata = if (self.pinned_offset_from_bottom >= 0 and self.pinned_id[0] != 0)
        self.entries.get(self.pinned_id)
    else
        null;
    for (screen.command_blocks.blocks.items) |block| {
        // The current command has one caption while its editor is docked.
        // Its real A/B pins remain unchanged for submission and history.
        if (pinned_metadata != null and std.mem.eql(u8, &block.id, &self.pinned_id)) continue;
        const pin = block.header orelse continue;
        if (pin.garbage) continue;
        const rows = headerRows(block);
        const second = if (rows == 2) pin.down(1) else null;
        // A two-row caption can remain partly visible after its first row
        // scrolls above the viewport. The shader clips it to the VT viewport.
        const visible_row = viewportRow(viewport_top, screen.pages.rows, pin.*);
        const above = visible_row == null;
        const row = visible_row orelse row: {
            const next = second orelse continue;
            const next_row = viewportRow(viewport_top, screen.pages.rows, next) orelse continue;
            if (next_row != 0) continue;
            break :row 0;
        };
        if (row >= screen.pages.rows) continue;
        if (headerHasVisibleOutput(pin.*)) continue;
        if (second) |next| if (headerHasVisibleOutput(next)) continue;
        try headers.append(alloc, .{
            .id = block.id,
            .row = @intCast(row),
            .rows = rows,
            .above_viewport = above,
            .metadata = self.entries.get(block.id) orelse .{},
            .current = std.mem.eql(u8, &block.id, &self.current_id),
        });
    }
    if (pinned_metadata) |metadata| {
        // The dock reserves one caption row regardless of how many rows an
        // older in-grid prompt reserved. Historical VT anchors stay intact.
        try headers.append(alloc, .{ .id = self.pinned_id, .row = 0, .rows = 1, .metadata = metadata, .current = true, .pinned = true });
        result.pinned_offset_from_bottom = self.pinned_offset_from_bottom;
    }
    result.headers = try headers.toOwnedSlice(alloc);
    return result;
}

/// Header visibility only needs the viewport's pages. pointFromPin(.viewport)
/// also searches every page below it, even when an old pin lies above the
/// viewport. Bound each lookup by visible rows instead of retained history.
/// This must not replace command-region endpoint lookup: a region can extend
/// below the viewport while its output still intersects the visible screen.
fn viewportRow(top: terminal.Pin, rows: usize, pin: terminal.Pin) ?usize {
    var node = top.node;
    var first_row: usize = top.y;
    var offset: usize = 0;
    while (offset < rows) {
        const count = @min(rows - offset, node.rows() - first_row);
        if (node == pin.node) {
            if (pin.y < first_row or pin.y - first_row >= count) return null;
            return offset + pin.y - first_row;
        }
        offset += count;
        node = node.next orelse return null;
        first_row = 0;
    }
    return null;
}

test "command chrome bounded viewport rows match clipped page coordinates across history" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{
        .cols = 80,
        .rows = 40,
        .max_scrollback_bytes = null,
    });
    defer term.deinit(t.allocator);
    for (0..2_000) |_| try term.linefeed();
    const pages = &term.screens.active.pages;
    const total = pages.scrollbar().total;
    for ([_]usize{ 0, total / 2, total - pages.rows }) |offset| {
        pages.scroll(.{ .row = offset });
        const top = pages.getTopLeft(.viewport);
        for (0..total) |row| {
            // Horizontal position cannot affect caption-row visibility.
            const pin = pages.pin(.{ .screen = .{ .x = 79, .y = @intCast(row) } }).?;
            const point = pages.pointFromPin(.viewport, pin);
            const expected: ?usize = if (point) |p|
                if (p.viewport.y < pages.rows) p.viewport.y else null
            else
                null;
            try t.expectEqual(expected, viewportRow(top, pages.rows, pin));
        }
        try t.expectEqual(@as(?usize, 0), viewportRow(top, pages.rows, top));
        try t.expectEqual(@as(?usize, pages.rows - 1), viewportRow(top, pages.rows, top.down(pages.rows - 1).?));
        if (top.up(1)) |above| try t.expectEqual(null, viewportRow(top, pages.rows, above));
        if (top.down(pages.rows)) |below| try t.expectEqual(null, viewportRow(top, pages.rows, below));
    }
}

// An explicit ReleaseFast test benchmark keeps fixture construction outside
// timing and alternates A/B order. This measures lookup only, not frames or
// the shell. Both lookups allocate no memory and retain no additional state.
// test/native-input/benchmark_command_chrome.py runs the optimized test root;
// the normal build.zig test target deliberately remains Debug.
test "command chrome viewport lookup benchmark" {
    if (@import("builtin").mode != .fast) return error.SkipZigTest;
    const t = std.testing;
    const samples = 21;
    const repetitions = 16;
    for ([_]usize{ 10, 100, 1_000 }) |count| {
        var term = try terminal.Terminal.init(t.io, t.allocator, .{
            .cols = 80,
            .rows = 40,
            .max_scrollback_bytes = null,
        });
        defer term.deinit(t.allocator);
        for (0..count * 16) |_| try term.linefeed();
        const pages = &term.screens.active.pages;
        const pins = try t.allocator.alloc(terminal.Pin, count);
        defer t.allocator.free(pins);
        for (pins, 0..) |*pin, index| pin.* = pages.pin(.{ .screen = .{ .y = @intCast(index * 16) } }).?;
        var page_count: usize = 0;
        var node = pages.pages.first;
        while (node) |current| : (node = current.next) page_count += 1;
        const total = pages.scrollbar().total;
        for ([_]usize{ 0, total / 2, total - pages.rows }, 0..) |offset, position| {
            pages.scroll(.{ .row = offset });
            var before: [samples]u64 = undefined;
            var after: [samples]u64 = undefined;
            for (0..3) |_| {
                _ = benchmarkViewportLookup(false, pages, pins, repetitions);
                _ = benchmarkViewportLookup(true, pages, pins, repetitions);
            }
            for (0..samples) |sample| {
                const first = if (sample % 2 == 0)
                    benchmarkViewportLookup(false, pages, pins, repetitions)
                else
                    benchmarkViewportLookup(true, pages, pins, repetitions);
                const second = if (sample % 2 == 0)
                    benchmarkViewportLookup(true, pages, pins, repetitions)
                else
                    benchmarkViewportLookup(false, pages, pins, repetitions);
                try t.expectEqual(first.checksum, second.checksum);
                before[sample] = (if (sample % 2 == 0) first.ns else second.ns) / repetitions;
                after[sample] = (if (sample % 2 == 0) second.ns else first.ns) / repetitions;
            }
            std.mem.sort(u64, &before, {}, std.sort.asc(u64));
            std.mem.sort(u64, &after, {}, std.sort.asc(u64));
            std.debug.print(
                "\n{{\"benchmark\":\"command-header-lookup\",\"headers\":{d},\"pages\":{d},\"position\":{d}," ++
                    "\"samples\":{d},\"before_median_ns\":{d},\"after_median_ns\":{d}," ++
                    "\"before_p95_ns\":{d},\"after_p95_ns\":{d},\"additional_retained_bytes\":0}}\n",
                .{ count, page_count, position, samples, before[samples / 2], after[samples / 2], before[19], after[19] },
            );
        }
    }
}

fn benchmarkViewportLookup(
    comptime bounded: bool,
    pages: *const terminal.PageList,
    pins: []const terminal.Pin,
    repetitions: usize,
) struct { ns: u64, checksum: usize } {
    const start = std.Io.Timestamp.now(std.testing.io, .awake);
    var checksum: usize = 0;
    for (0..repetitions) |_| {
        const top = pages.getTopLeft(.viewport);
        for (pins) |pin| {
            const row: ?usize = if (bounded)
                viewportRow(top, pages.rows, pin)
            else if (pages.pointFromPin(.viewport, pin)) |point|
                if (point.viewport.y < pages.rows) point.viewport.y else null
            else
                null;
            checksum +%= if (row) |y| y + 1 else 0;
        }
        std.mem.doNotOptimizeAway(&checksum);
    }
    const end = std.Io.Timestamp.now(std.testing.io, .awake);
    return .{ .ns = @intCast(start.durationTo(end).nanoseconds), .checksum = checksum };
}

/// Only claim an extra chrome row when the first input anchor proves there
/// is room. Older two-row prompts retain their original scrollback geometry.
fn headerRows(block: Blocks.Block) u2 {
    const header = block.header orelse return 1;
    const input = block.input orelse return 1;
    if (header.garbage or input.garbage) return 1;
    var limit = header.down(2) orelse return 1;
    limit.x = 0;
    return if (!input.before(limit)) 2 else 1;
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

pub const CaptionLayout = struct { gap: u32, scale: f32, columns: u16 };

/// Keep captions at least 87.5% of the terminal font within their existing row.
/// Block padding can be larger: only the caption's internal top gap is capped.
/// Historical two-row headers retain a second gap; terminal row positions and
/// selection coordinates never change. Rendering and path hit bounds share this.
pub fn captionLayout(columns: u16, cell_height: u32, requested_gap: u32) CaptionLayout {
    const gap = @min(requested_gap, cell_height / 8);
    const scale = if (cell_height == 0) 1 else @as(f32, @floatFromInt(cell_height - gap)) / @as(f32, @floatFromInt(cell_height));
    const virtual_columns: u16 = @intFromFloat(@min(
        @as(f32, @floatFromInt(std.math.maxInt(u16))),
        @max(1, @floor(@as(f32, @floatFromInt(columns)) / scale)),
    ));
    return .{ .gap = gap, .scale = scale, .columns = virtual_columns };
}

pub const PathHit = struct {
    id: [65]u8,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

/// Use the same grapheme widths and truncation budget as writeCaption. A path
/// clipped in its middle includes its ellipsis; branch/status cells never do.
fn pathColumns(metadata: *const Metadata, columns: u16) usize {
    if (metadata.path_len == 0) return 0;
    const label = Text.init(metadata.label[0..metadata.label_len]);
    const path = Text.init(metadata.label[0..@min(metadata.path_len, metadata.label_len)]);
    const suffix = Text.init(metadata.suffix[0..metadata.suffix_len]);
    const suffix_width = @min(suffix.width, columns / 2);
    const budget = if (suffix_width > 0) columns -| (suffix_width + 2) else columns;
    if (label.width <= budget or path.width <= budget -| 1) return @min(path.width, budget);
    var used: usize = 0;
    var i: usize = 0;
    while (i < path.len) {
        const cluster = unicode.graphemeWidth(u21, path.cps[i..path.len]);
        if (used + cluster.width > budget -| 1) break;
        used += cluster.width;
        i += cluster.len;
    }
    return used + @intFromBool(budget > 0);
}

/// Physical-pixel cell bounds of only the visible path. Keep this geometry
/// paired with the command cell shader: scaled x, per-span y gap, and clipping.
pub fn pathRect(header: Header, size: Size, columns: u16, rows: u16, pinned_offset: f32) ?PathHit {
    const layout = captionLayout(columns, size.cell.height, size.command_padding);
    const width = @as(f32, @floatFromInt(pathColumns(&header.metadata, layout.columns))) *
        @as(f32, @floatFromInt(size.cell.width)) * layout.scale;
    if (width <= 0) return null;
    const cell_height: f32 = @floatFromInt(size.cell.height);
    const top: f32 = @floatFromInt(size.padding.top);
    const origin = if (header.pinned)
        @max(0, @as(f32, @floatFromInt(size.screen.height)) - pinned_offset)
    else
        top + (@as(f32, @floatFromInt(header.row)) - @as(f32, @floatFromInt(@intFromBool(header.above_viewport)))) * cell_height;
    const y = origin + @as(f32, @floatFromInt(layout.gap)) * (if (header.rows == 2) @as(f32, 2) else 1);
    const lower = if (header.pinned) 0 else top;
    const upper = if (header.pinned) @as(f32, @floatFromInt(size.screen.height)) else top + @as(f32, @floatFromInt(rows)) * cell_height;
    const visible_top = @max(y, lower);
    const visible_bottom = @min(y + cell_height * layout.scale, upper);
    if (visible_bottom <= visible_top) return null;
    return .{
        .id = header.id,
        .x = @floatFromInt(size.padding.left),
        .y = visible_top,
        .width = @min(width, @as(f32, @floatFromInt(size.screen.width -| size.padding.left))),
        .height = visible_bottom - visible_top,
    };
}

/// Click-only, under the terminal lock. Snapshot validates current anchors and
/// erased/overwritten rows, so stale GUI layout never opens a different block.
pub fn pathAt(self: *const CommandChrome, alloc: Allocator, term: *terminal.Terminal, size: Size, x: f32, y: f32) Allocator.Error!?PathHit {
    const value = try self.snapshot(alloc, term);
    defer alloc.free(value.headers);
    var i = value.headers.len;
    while (i > 0) {
        i -= 1; // Pinned chrome is drawn last, and wins overlapping hits.
        const rect = pathRect(value.headers[i], size, term.cols, term.rows, value.pinned_offset_from_bottom) orelse continue;
        if (x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height) return rect;
    }
    return null;
}

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
        try t.expectEqual(@as(usize, 1), s.headers.len);
        try t.expectEqual(@as(u16, 0), s.headers[0].row);
        try t.expect(s.headers[0].pinned);
        try t.expectEqual(@as(u2, 1), s.headers[0].rows);
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
        try t.expectEqual(@as(u2, 1), s.headers[0].rows);
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

test "command chrome padding scales captions within the existing header row" {
    const t = std.testing;
    const normal = captionLayout(80, 16, 6);
    const retina = captionLayout(80, 32, 12);
    try t.expectEqual(@as(u32, 2), normal.gap);
    try t.expectEqual(@as(u32, 4), retina.gap);
    try t.expectEqual(@as(f32, 0.875), normal.scale);
    try t.expectEqual(normal.scale, retina.scale);
    try t.expectEqual(normal.columns, retina.columns);
    try t.expectEqual(@as(f32, 16), @as(f32, @floatFromInt(normal.gap)) + 16 * normal.scale);
    try t.expect(@as(f32, @floatFromInt(normal.columns)) * normal.scale <= 80);
    const tiny = captionLayout(80, 3, 4);
    try t.expectEqual(@as(f32, 1), tiny.scale);
    try t.expectEqual(@as(u32, 0), tiny.gap);
    try t.expectEqual(@as(u16, std.math.maxInt(u16)), captionLayout(std.math.maxInt(u16), 10, 9).columns);
}

test "command chrome large block gaps preserve readable one-row caption bounds" {
    const t = std.testing;
    for ([_]u32{ 1, 3, 16, 17, 32, 34, 64 }) |height| {
        for ([_]u32{ 0, 1, 6, 12, 96 }) |padding| {
            const layout = captionLayout(80, height, padding);
            const row_height: f32 = @floatFromInt(height);
            try t.expect(layout.scale >= 0.875 and layout.scale <= 1);
            try t.expect(layout.gap <= padding);
            // Font growth consumes only the internal gap, never the input row.
            try t.expectApproxEqAbs(row_height, @as(f32, @floatFromInt(layout.gap)) + row_height * layout.scale, 0.0001);
        }
    }
    const zero = captionLayout(80, 0, 6);
    try t.expectEqual(@as(u32, 0), zero.gap);
    try t.expectEqual(@as(f32, 1), zero.scale);
}

test "command chrome derives one or two reserved rows from input anchors" {
    const t = std.testing;
    for (1..3) |rows| {
        var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 10, .rows = 5 });
        defer term.deinit(t.allocator);
        var chrome: CommandChrome = .{};
        defer chrome.deinit(t.allocator);
        _ = try chrome.update(t.allocator, true, -1, &.{.{ .id = "a", .label = "cwd", .suffix = "" }});
        try term.semanticPrompt(.{ .action = .fresh_line_new_prompt, .options_unvalidated = "aid=a" });
        for (0..rows) |_| try term.linefeed();
        try term.semanticPrompt(.{ .action = .end_prompt_start_input, .options_unvalidated = "aid=a" });
        try term.print('x');
        const before = try term.plainString(t.allocator);
        defer t.allocator.free(before);
        const snapshot_value = try chrome.snapshot(t.allocator, &term);
        defer t.allocator.free(snapshot_value.headers);
        try t.expectEqual(@as(usize, 1), snapshot_value.headers.len);
        try t.expectEqual(@as(u2, @intCast(rows)), snapshot_value.headers[0].rows);
        const after = try term.plainString(t.allocator);
        defer t.allocator.free(after);
        try t.expectEqualStrings(before, after);
        try term.resize(t.allocator, .{ .cols = 6, .rows = 5 });
        const resized = try chrome.snapshot(t.allocator, &term);
        defer t.allocator.free(resized.headers);
        try t.expectEqual(@as(usize, 1), resized.headers.len);
        try t.expectEqual(@as(u2, @intCast(rows)), resized.headers[0].rows);
    }
}

test "command chrome validates both reserved rows and clips partial viewport" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 10, .rows = 4 });
    defer term.deinit(t.allocator);
    var chrome: CommandChrome = .{};
    defer chrome.deinit(t.allocator);
    _ = try chrome.update(t.allocator, true, -1, &.{.{ .id = "a", .label = "cwd", .suffix = "" }});
    try term.semanticPrompt(.{ .action = .fresh_line_new_prompt, .options_unvalidated = "aid=a" });
    try term.linefeed();
    try term.linefeed();
    try term.semanticPrompt(.{ .action = .end_prompt_start_input, .options_unvalidated = "aid=a" });
    // Ink in the second row must not be covered even if A's row is blank.
    term.setCursorPos(2, 1);
    try term.print('x');
    {
        const s = try chrome.snapshot(t.allocator, &term);
        defer t.allocator.free(s.headers);
        try t.expectEqual(@as(usize, 0), s.headers.len);
    }
    term.setCursorPos(2, 1);
    try term.print(' ');
    term.setCursorPos(3, 1);
    for (0..6) |_| {
        try term.print('x');
        try term.linefeed();
    }
    term.scrollViewport(.top);
    term.scrollViewport(.{ .delta = 1 });
    {
        const s = try chrome.snapshot(t.allocator, &term);
        defer t.allocator.free(s.headers);
        try t.expectEqual(@as(usize, 1), s.headers.len);
        try t.expectEqual(@as(u2, 2), s.headers[0].rows);
        try t.expectEqual(@as(u16, 0), s.headers[0].row);
        try t.expect(s.headers[0].above_viewport);
    }
    term.scrollViewport(.{ .delta = 1 });
    const hidden = try chrome.snapshot(t.allocator, &term);
    defer t.allocator.free(hidden.headers);
    try t.expectEqual(@as(usize, 0), hidden.headers.len);
}

test "command chrome path hits exclude branch status gaps and overwritten rows" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 20, .rows = 6 });
    defer term.deinit(t.allocator);
    var chrome: CommandChrome = .{};
    defer chrome.deinit(t.allocator);
    _ = try chrome.update(t.allocator, true, -1, &.{.{ .id = "a", .label = "/tmp  branch", .path_len = 4, .suffix = "ok" }});
    try term.semanticPrompt(.{ .action = .fresh_line_new_prompt, .options_unvalidated = "aid=a" });
    try term.linefeed();
    try term.linefeed();
    try term.semanticPrompt(.{ .action = .end_prompt_start_input, .options_unvalidated = "aid=a" });
    const size: Size = .{ .screen = .{ .width = 168, .height = 100 }, .cell = .{ .width = 8, .height = 16 }, .padding = .{ .left = 4, .right = 4, .bottom = 4 }, .command_padding = 4 };
    const hit = (try chrome.pathAt(t.allocator, &term, size, 5, 9)).?;
    try t.expectEqualStrings("a", std.mem.sliceTo(&hit.id, 0));
    try t.expectEqual(@as(f32, 4), hit.x);
    try t.expectEqual(@as(f32, 4), hit.y);
    try t.expectEqual(@as(f32, 28), hit.width);
    try t.expectEqual(@as(f32, 14), hit.height);
    try t.expectEqual(null, try chrome.pathAt(t.allocator, &term, size, 5, 2)); // Separator/top gap.
    try t.expectEqual(null, try chrome.pathAt(t.allocator, &term, size, 33, 9)); // After path, before branch.
    try t.expectEqual(null, try chrome.pathAt(t.allocator, &term, size, 150, 9)); // Status cells.
    term.setCursorPos(2, 1);
    try term.print('x');
    try t.expectEqual(null, try chrome.pathAt(t.allocator, &term, size, 5, 9));
    _ = try term.switchScreen(.alternate);
    try t.expectEqual(null, try chrome.pathAt(t.allocator, &term, size, 5, 9));
}

test "command chrome path bounds preserve unicode truncation scale and partial clipping" {
    const t = std.testing;
    var chrome: CommandChrome = .{};
    defer chrome.deinit(t.allocator);
    _ = try chrome.update(t.allocator, true, -1, &.{.{ .id = "a", .label = "/界/👩‍💻/path  branch", .path_len = "/界/👩‍💻/path".len, .suffix = "" }});
    const metadata = chrome.entries.values()[0];
    try t.expectEqual(@as(usize, 7), pathColumns(&metadata, 7));
    try t.expectEqual(@as(usize, 2), pathColumns(&metadata, 3)); // Slash, then ellipsis (wide cluster doesn't fit).
    var header: Header = .{ .id = @splat(0), .row = 0, .rows = 2, .metadata = metadata };
    var size: Size = .{ .screen = .{ .width = 168, .height = 100 }, .cell = .{ .width = 8, .height = 16 }, .padding = .{ .left = 4, .right = 4, .bottom = 4 }, .command_padding = 4 };
    const normal = pathRect(header, size, 20, 6, -1).?;
    size.screen = .{ .width = 336, .height = 200 };
    size.cell = .{ .width = 16, .height = 32 };
    size.padding = .{ .left = 8, .right = 8, .bottom = 8 };
    size.command_padding = 8;
    const retina = pathRect(header, size, 20, 6, -1).?;
    try t.expectEqual(normal.x * 2, retina.x);
    try t.expectEqual(normal.y * 2, retina.y);
    try t.expectEqual(normal.width * 2, retina.width);
    try t.expectEqual(normal.height * 2, retina.height);
    header.above_viewport = true;
    const clipped = pathRect(header, size, 20, 6, -1).?;
    try t.expectEqual(@as(f32, 0), clipped.y);
    try t.expectEqual(@as(f32, 4), clipped.height);
    header.pinned = true;
    const pinned = pathRect(header, size, 20, 6, 80).?;
    try t.expectEqual(@as(f32, 128), pinned.y);
}

test "command chrome pinned current header replaces only its visible grid copy" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 20, .rows = 8 });
    defer term.deinit(t.allocator);
    var chrome: CommandChrome = .{};
    defer chrome.deinit(t.allocator);
    for ([_][]const u8{ "aid=previous", "aid=current" }) |id| {
        try term.semanticPrompt(.{ .action = .fresh_line_new_prompt, .options_unvalidated = id });
        try term.linefeed();
        try term.linefeed();
        try term.semanticPrompt(.{ .action = .end_prompt_start_input, .options_unvalidated = id });
        try term.linefeed();
    }
    _ = try chrome.update(t.allocator, true, 60, &.{
        .{ .id = "previous", .label = "/before", .suffix = "ok" },
        .{ .id = "current", .label = "/now", .path_len = 4, .suffix = "", .current = true, .pinned = true },
    });
    const before = try term.plainString(t.allocator);
    defer t.allocator.free(before);
    {
        const s = try chrome.snapshot(t.allocator, &term);
        defer t.allocator.free(s.headers);
        try t.expectEqual(@as(usize, 2), s.headers.len);
        try t.expectEqualStrings("previous", std.mem.sliceTo(&s.headers[0].id, 0));
        try t.expect(!s.headers[0].pinned);
        try t.expectEqualStrings("current", std.mem.sliceTo(&s.headers[1].id, 0));
        try t.expect(s.headers[1].pinned);
        try t.expectEqual(@as(u2, 2), s.headers[0].rows);
        try t.expectEqual(@as(u2, 1), s.headers[1].rows);
        // Even an older two-row prompt fits the one-row dock. Its click
        // target ends exactly where the native editor begins, not below it.
        const size: Size = .{ .screen = .{ .width = 168, .height = 160 }, .cell = .{ .width = 8, .height = 16 }, .padding = .{ .left = 4, .right = 4, .bottom = 4 }, .command_padding = 4 };
        const rect = pathRect(s.headers[1], size, 20, 8, s.pinned_offset_from_bottom).?;
        try t.expectEqual(@as(f32, 116), rect.y + rect.height);
    }
    _ = try chrome.update(t.allocator, true, -1, &.{.{ .id = "current", .label = "/now", .suffix = "", .current = true }});
    const s = try chrome.snapshot(t.allocator, &term);
    defer t.allocator.free(s.headers);
    try t.expectEqual(@as(usize, 2), s.headers.len);
    try t.expect(!s.headers[0].pinned and !s.headers[1].pinned);
    try t.expectEqual(@as(u2, 2), s.headers[1].rows);
    try t.expectEqual(@as(u16, 3), s.headers[1].row);
    const after = try term.plainString(t.allocator);
    defer t.allocator.free(after);
    try t.expectEqualStrings(before, after);
}
