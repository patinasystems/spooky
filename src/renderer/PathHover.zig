//! One bounded local-path hover. The host alone resolves filesystem paths.
//! Byte/cell mapping and stale-hit rejection remain in the terminal owner.
const PathHover = @This();
const std = @import("std");
const terminal = @import("../terminal/main.zig");
const Chrome = @import("CommandChrome.zig");
const Size = @import("size.zig").Size;
const Viewport = @import("NativeViewport.zig").Resolved;

pub const text_capacity = 4096;
pub const rect_capacity = 8;
pub const Kind = enum(c_int) { header, output, local_osc8 };
pub const Probe = extern struct {
    hit_id: u64 = 0,
    kind: Kind = .output,
    block_id: [65]u8 = @splat(0),
    text_len: u32 = 0,
    hover_byte: u32 = 0,
    uri_len: u32 = 0,
    text: [text_capacity]u8 = @splat(0),
    uri: [text_capacity]u8 = @splat(0),
};
pub const Rect = struct { x: f32 = 0, y: f32 = 0, width: f32 = 0, height: f32 = 0 };
pub const Snapshot = struct {
    count: u8 = 0,
    rects: [rect_capacity]Rect = @splat(.{}),
    open: bool = false,
    pinned: bool = false,
    /// Arrow occupies only a following blank cell, never adjacent output.
    arrow: ?Rect = null,
};
const Cell = struct { x: u16 = 0, y: u16 = 0, width: u2 = 0 };
const Identity = struct {
    top_node: usize,
    top_serial: u64,
    top_y: u16,
    size: Size,
    boundary_stamp: u64,
    chrome_revision: u64,
    viewport: Viewport,
};
const Capture = struct {
    probe: Probe = .{},
    identity: Identity,
    cells: [text_capacity]Cell = @splat(.{}),
    header: ?Chrome.PathHeader = null,
    source_row: u32 = 0,
};
const HeaderLookup = union(enum) { discover, skip, known: Chrome.PathHeader };
const Owner = struct {
    identity: Identity,
    id: [65]u8,
    first_row: u32,
    end_row: u32,
};

next_id: u64 = 0,
probe: ?Probe = null,
identity: ?Identity = null,
x: f32 = 0,
y: f32 = 0,
start: u32 = 0,
length: u32 = 0,
open: bool = false,
published: bool = false,
owner: ?Owner = null,
source_row: u32 = 0,
header: ?Chrome.PathHeader = null,
/// Clearing from the GUI never waits behind a busy PTY parser. All other
/// members remain protected by renderer.State.mutex.
clear_requested: std.atomic.Value(bool) = .init(false),

pub fn requestClear(self: *PathHover) void {
    self.clear_requested.store(true, .release);
}

fn consumeClear(self: *PathHover) void {
    if (self.clear_requested.swap(false, .acquire)) self.clear();
}

pub fn clear(self: *PathHover) void {
    self.probe = null;
    self.identity = null;
    self.published = false;
}

/// Called only on host pointer queries. No filesystem access or allocations.
pub fn probeAt(self: *PathHover, term: *terminal.Terminal, chrome: *const Chrome, size: Size, viewport: Viewport, x: f32, y: f32) ?Probe {
    self.consumeClear();
    // Retained target validation never rediscovers headers or owners.
    const retained: ?Capture = retained: {
        const old = self.probe orelse break :retained null;
        if (!std.meta.eql(identityFor(term, chrome, size, viewport), self.identity.?)) break :retained null;
        const lookup: HeaderLookup = if (self.header) |header| .{ .known = header } else .skip;
        var value = captureAt(term, chrome, size, viewport, x, y, lookup) orelse break :retained null;
        if (value.header == null) value.probe.block_id = old.block_id;
        if (value.source_row != self.source_row or !sameText(old, value.probe)) break :retained null;
        break :retained value;
    };
    var capture = retained orelse captureAt(term, chrome, size, viewport, x, y, .discover) orelse {
        self.clear();
        return null;
    };
    if (retained == null and capture.header == null) capture.probe.block_id = self.ownerAt(term, capture.identity, &capture.probe, &capture.cells);
    const same = if (self.probe) |old| self.identity != null and
        std.meta.eql(self.identity.?, capture.identity) and self.source_row == capture.source_row and sameText(old, capture.probe) else false;
    if (same) {
        capture.probe.hit_id = self.probe.?.hit_id;
    } else {
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        capture.probe.hit_id = self.next_id;
        self.published = false;
    }
    self.x = x;
    self.y = y;
    self.identity = capture.identity;
    self.source_row = capture.source_row;
    self.header = capture.header;
    self.probe = capture.probe;
    // Moving outside the accepted byte range immediately removes old paint.
    if (self.published and (capture.probe.hover_byte < self.start or
        capture.probe.hover_byte >= self.start + self.length)) self.published = false;
    return capture.probe;
}

/// Publish only a host-validated literal path. This also revalidates a click.
pub fn publish(self: *PathHover, term: *terminal.Terminal, chrome: *const Chrome, size: Size, viewport: Viewport, id: u64, start: u32, length: u32, open: bool) ?Snapshot {
    self.consumeClear();
    const probe = self.probe orelse return null;
    if (id != probe.hit_id or length == 0 or start >= probe.text_len or length > probe.text_len - start) return null;
    if (probe.hover_byte < start or probe.hover_byte >= start + length) return null;
    var capture = self.validate(term, chrome, size, viewport) orelse return null;
    if (capture.header == null) {
        // A UTF-8/grapheme cluster must remain a single visual selection.
        if (start > 0 and std.meta.eql(capture.cells[start - 1], capture.cells[start])) return null;
        const end = start + length;
        if (end < probe.text_len and std.meta.eql(capture.cells[end - 1], capture.cells[end])) return null;
    } else if (start != 0 or length != probe.text_len) return null;
    self.start = start;
    self.length = length;
    self.open = open;
    const result = self.rectangles(term, size, viewport, &capture) orelse return null;
    self.published = true;
    return result;
}

/// Per-frame validation touches only the active bounded text and command
/// anchors. It never repeats owner lookup or traverses terminal history.
pub fn snapshot(self: *PathHover, term: *terminal.Terminal, chrome: *const Chrome, size: Size, viewport: Viewport) Snapshot {
    self.consumeClear();
    if (!self.published) return .{};
    var capture = self.validate(term, chrome, size, viewport) orelse return .{};
    return self.rectangles(term, size, viewport, &capture) orelse .{};
}

fn validate(self: *PathHover, term: *terminal.Terminal, chrome: *const Chrome, size: Size, viewport: Viewport) ?Capture {
    const old = self.probe orelse return null;
    // Reject structural changes before consulting the cached header index.
    if (!std.meta.eql(identityFor(term, chrome, size, viewport), self.identity.?)) {
        self.clear();
        return null;
    }
    const lookup: HeaderLookup = if (self.header) |header| .{ .known = header } else .skip;
    var capture = captureAt(term, chrome, size, viewport, self.x, self.y, lookup) orelse {
        self.clear();
        return null;
    };
    // The stamp changes when a boundary is replaced/erased. Text comparison
    // also catches overwrites within the same page (page serial alone cannot).
    if (capture.header == null) capture.probe.block_id = old.block_id;
    if (!std.meta.eql(capture.identity, self.identity.?) or self.source_row != capture.source_row or !sameText(old, capture.probe)) {
        self.clear();
        return null;
    }
    return capture;
}

fn sameText(a: Probe, b: Probe) bool {
    return a.kind == b.kind and std.mem.eql(u8, &a.block_id, &b.block_id) and
        a.text_len == b.text_len and a.uri_len == b.uri_len and
        std.mem.eql(u8, a.text[0..a.text_len], b.text[0..b.text_len]) and
        std.mem.eql(u8, a.uri[0..a.uri_len], b.uri[0..b.uri_len]);
}

fn rectangles(self: *const PathHover, term: *terminal.Terminal, size: Size, viewport: Viewport, capture: *const Capture) ?Snapshot {
    var result: Snapshot = .{ .open = self.open };
    if (capture.header) |header| {
        const rect = header.rect;
        result.rects[0] = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
        result.count = 1;
        result.pinned = header.pinned;
        // Header metadata has a separating gap before branch/status text.
        const right = rect.x + rect.width;
        if (right + @as(f32, @floatFromInt(size.cell.width)) < @as(f32, @floatFromInt(size.screen.width -| size.padding.right)))
            result.arrow = .{ .x = right, .y = rect.y, .width = @floatFromInt(size.cell.width), .height = rect.height };
        return result;
    }
    const end = self.start + self.length;
    var index: usize = self.start;
    while (index < end) {
        const cell = capture.cells[index];
        const raw_y = @as(f32, @floatFromInt(size.padding.top + @as(u32, cell.y) * size.cell.height)) - viewport.scroll_offset_y;
        const y = @max(@as(f32, @floatFromInt(size.padding.top)), raw_y);
        const bottom: f32 = @floatFromInt(viewport.contentBottom(size));
        const rect: Rect = .{
            .x = @floatFromInt(size.padding.left + @as(u32, cell.x) * size.cell.width),
            .y = y,
            .width = @floatFromInt(@as(u32, cell.width) * size.cell.width),
            .height = @max(0, @min(raw_y + @as(f32, @floatFromInt(size.cell.height)), bottom) - y),
        };
        if (rect.height <= 0) return null;
        if (result.count > 0 and result.rects[result.count - 1].y == y) {
            const previous = &result.rects[result.count - 1];
            previous.width = @max(previous.width, rect.x + rect.width - previous.x);
        } else {
            if (result.count == rect_capacity) return null;
            result.rects[result.count] = rect;
            result.count += 1;
        }
        index += 1;
        while (index < end and std.meta.eql(cell, capture.cells[index])) index += 1;
    }
    const last = capture.cells[end - 1];
    const next_x = @as(u32, last.x) + last.width;
    if (next_x < term.cols) {
        const next = term.screens.active.pages.pin(.{ .viewport = .{ .x = @intCast(next_x), .y = last.y } }).?;
        const cp = next.rowAndCell().cell.codepoint();
        if (cp == 0 or cp == ' ') {
            const rect = result.rects[result.count - 1];
            result.arrow = .{ .x = rect.x + rect.width, .y = rect.y, .width = @floatFromInt(size.cell.width), .height = rect.height };
        }
    }
    return if (result.count > 0) result else null;
}

fn uriAt(pin: terminal.Pin) ?[]const u8 {
    const page = pin.node.page();
    const id = page.lookupHyperlink(pin.rowAndCell().cell) orelse return null;
    return page.hyperlink_set.get(page.memory, id).uri.slice(page.memory);
}

fn localURI(uri: []const u8) bool {
    if (!std.ascii.startsWithIgnoreCase(uri, "file://")) return false;
    const rest = uri[7..];
    return std.mem.startsWith(u8, rest, "/") or std.ascii.startsWithIgnoreCase(rest, "localhost/");
}

fn boundaryStamp(term: *terminal.Terminal) u64 {
    return term.screens.active.command_blocks.revision;
}

fn identityFor(term: *terminal.Terminal, chrome: *const Chrome, size: Size, viewport: Viewport) Identity {
    const top = term.screens.active.pages.getTopLeft(.viewport);
    return .{ .top_node = @intFromPtr(top.node), .top_serial = top.node.serial, .top_y = top.y, .size = size, .boundary_stamp = boundaryStamp(term), .chrome_revision = chrome.revision, .viewport = viewport };
}

fn captureAt(term: *terminal.Terminal, chrome: *const Chrome, size: Size, viewport: Viewport, x: f32, y: f32, lookup: HeaderLookup) ?Capture {
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or term.screens.active_key != .primary or
        term.flags.mouse_event != .none or size.cell.width == 0 or size.cell.height == 0 or
        size.grid().columns != term.cols or size.grid().rows != term.rows) return null;
    const screen = term.screens.active;
    var result: Capture = .{ .identity = identityFor(term, chrome, size, viewport) };
    const path_header = switch (lookup) {
        .discover => chrome.pathHeaderAt(term, size, x, y, viewport),
        .skip => null,
        .known => |known| chrome.pathHeaderKnown(term, size, viewport, known) orelse return null,
    };
    if (path_header) |header| {
        const rect = header.rect;
        if (x < rect.x or x >= rect.x + rect.width or y < rect.y or y >= rect.y + rect.height) return null;
        result.header = header;
        result.probe.kind = .header;
        result.probe.block_id = header.rect.id;
        result.probe.text_len = header.metadata.path_len;
        @memcpy(result.probe.text[0..result.probe.text_len], header.metadata.label[0..header.metadata.path_len]);
        return if (result.probe.text_len > 0) result else null;
    }
    const px = x - @as(f32, @floatFromInt(size.padding.left));
    const py = y - @as(f32, @floatFromInt(size.padding.top)) + viewport.scroll_offset_y;
    if (px < 0 or py < 0 or x >= @as(f32, @floatFromInt(size.screen.width)) or
        y >= @as(f32, @floatFromInt(viewport.contentBottom(size)))) return null;
    const hover_x: u32 = @intFromFloat(px / @as(f32, @floatFromInt(size.cell.width)));
    const hover_y: u32 = @intFromFloat(py / @as(f32, @floatFromInt(size.cell.height)));
    if (hover_x >= term.cols or hover_y >= viewport.hitRows()) return null;
    var hovered = screen.pages.pin(.{ .viewport = .{ .x = @intCast(hover_x), .y = hover_y } }) orelse return null;
    if (hovered.rowAndCell().cell.wide == .spacer_tail and hovered.x > 0) hovered.x -= 1;
    if (hovered.rowAndCell().cell.semantic_content != .output) return null;
    const uri = uriAt(hovered);
    if (uri) |value| {
        // Web/remote OSC8 retains its upstream behavior. No implicit scheme.
        if (!localURI(value) or value.len > text_capacity) return null;
        result.probe.kind = .local_osc8;
        result.probe.uri_len = @intCast(value.len);
        @memcpy(result.probe.uri[0..value.len], value);
    }
    var first = hovered;
    var first_y = hover_y;
    var rows: usize = 1;
    // Include at most eight visible soft-wrapped rows. Do not guess partial
    // filenames when their logical line exceeds the fixed context budget.
    while (first.rowAndCell().row.wrap_continuation and first_y > 0) {
        if (rows == rect_capacity) return null;
        first = first.up(1) orelse break;
        first_y -= 1;
        rows += 1;
    }
    if (uri == null and first.rowAndCell().row.wrap_continuation) return null;
    first.x = 0;
    result.source_row = first_y;
    var row_pin = first;
    var row_y = first_y;
    var found_hover = false;
    rows = 0;
    scan: while (row_y < viewport.hitRows() and rows < rect_capacity) : ({
        row_y += 1;
        rows += 1;
    }) {
        const row = row_pin.rowAndCell().row;
        const cells = row_pin.cells(.all);
        for (cells, 0..) |*cell, column| {
            if (cell.wide == .spacer_tail or cell.wide == .spacer_head) continue;
            var pin = row_pin;
            pin.x = @intCast(column);
            const included = cell.semantic_content == .output and if (uri) |value|
                if (uriAt(pin)) |other| std.mem.eql(u8, value, other) else false
            else
                !cell.hyperlink;
            if (!included) {
                if (found_hover) break :scan;
                result.probe.text_len = 0;
                continue;
            }
            const point: Cell = .{ .x = @intCast(column), .y = @intCast(row_y), .width = cell.gridWidth() };
            if (pin.eql(hovered)) {
                found_hover = true;
                result.probe.hover_byte = result.probe.text_len;
            }
            if (!appendCodepoint(&result, point, if (cell.codepoint() == 0) ' ' else cell.codepoint())) return null;
            if (pin.grapheme(cell)) |extra| for (extra) |cp| {
                if (!appendCodepoint(&result, point, cp)) return null;
            };
        }
        if (!row.wrap) break;
        if (rows + 1 == rect_capacity) return null;
        if (uri == null and row_y + 1 >= viewport.hitRows()) return null;
        row_pin = row_pin.down(1) orelse break;
    }
    while (result.probe.text_len > 0 and result.probe.text[result.probe.text_len - 1] == ' ') result.probe.text_len -= 1;
    if (!found_hover or result.probe.hover_byte >= result.probe.text_len) return null;
    return result;
}

fn appendCodepoint(result: *Capture, cell: Cell, cp: u21) bool {
    var bytes: [4]u8 = undefined;
    const count = std.unicode.utf8Encode(cp, &bytes) catch return false;
    const offset = result.probe.text_len;
    if (count > text_capacity - offset) return false;
    @memcpy(result.probe.text[offset..][0..count], bytes[0..count]);
    @memset(result.cells[offset..][0..count], cell);
    result.probe.text_len += count;
    return true;
}

/// Resolve ownership once per viewport interval, not per frame or character.
/// The whole lookup shares a budget of 256 page links (including comparisons),
/// rather than calling Pin.before, which can traverse all history. Success is
/// cached for that command's visible interval; unknown ownership is cached for
/// the hovered row. Without an owner, absolute/local OSC8 paths still work and
/// the host must decline relative paths instead of guessing today's cwd.
fn ownerAt(self: *PathHover, term: *terminal.Terminal, identity: Identity, probe: *const Probe, cells: *const [text_capacity]Cell) [65]u8 {
    const point = cells[probe.hover_byte];
    if (self.owner) |owner| if (std.meta.eql(owner.identity, identity) and
        point.y >= owner.first_row and point.y < owner.end_row) return owner.id;
    const screen = term.screens.active;
    const hovered = screen.pages.pin(.{ .viewport = .{ .x = point.x, .y = point.y } }).?;
    // Record the conservative fallback before any budget-limited early return.
    self.owner = .{ .identity = identity, .id = @splat(0), .first_row = point.y, .end_row = @as(u32, point.y) + 1 };
    var page_budget: usize = 256;
    const Anchor = struct { pin: terminal.Pin, index: usize };
    var anchors: [1024]Anchor = undefined;
    var count: usize = 0;
    for (screen.command_blocks.blocks.items, 0..) |block, index| {
        const pin = block.output orelse block.input orelse block.header orelse continue;
        if (pin.garbage) continue;
        anchors[count] = .{ .pin = pin.*, .index = index };
        count += 1;
    }
    var lo: usize = 0;
    var hi = count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const order = comparePins(hovered, anchors[mid].pin, &page_budget) orelse return @splat(0);
        if (order == .lt) hi = mid else lo = mid + 1;
    }
    if (lo == 0) return @splat(0);
    const anchor = anchors[lo - 1];
    const block = screen.command_blocks.blocks.items[anchor.index];
    // Only command output owns relative output paths. Missing/erased C does
    // not authorize guessing with a newer shell's current directory.
    const output = block.output orelse return @splat(0);
    if (output.garbage) return @splat(0);
    if ((comparePins(hovered, output.*, &page_budget) orelse return @splat(0)) == .lt) return @splat(0);
    if (block.end) |end| if (!end.garbage) {
        const order = comparePins(hovered, end.*, &page_budget) orelse return @splat(0);
        if (order == .gt or (!block.end_inclusive and order == .eq)) return @splat(0);
    };
    const top = screen.pages.getTopLeft(.viewport);
    const first_row = if (visibleRow(top, term.rows, output.*)) |row| row + @intFromBool(output.x != 0) else 0;
    var end_row: u32 = term.rows;
    if (block.end) |end| if (!end.garbage) {
        // The boundary row can contain a partial last line. Recheck its exact
        // pin instead of caching all columns as belonging to this command.
        if (visibleRow(top, term.rows, end.*)) |row| end_row = row;
    };
    if (lo < count) {
        if (visibleRow(top, term.rows, anchors[lo].pin)) |row| end_row = @min(end_row, row);
    }
    self.owner = .{ .identity = identity, .id = block.id, .first_row = first_row, .end_row = end_row };
    return block.id;
}

fn comparePins(a: terminal.Pin, b: terminal.Pin, budget: *usize) ?std.math.Order {
    if (a.node == b.node) {
        const row = std.math.order(a.y, b.y);
        return if (row == .eq) std.math.order(a.x, b.x) else row;
    }
    var next = a.node.next;
    var previous = a.node.prev;
    while (budget.* > 0 and (next != null or previous != null)) {
        if (next) |node| {
            budget.* -= 1;
            if (node == b.node) return .lt;
            next = node.next;
        }
        if (budget.* == 0) break;
        if (previous) |node| {
            budget.* -= 1;
            if (node == b.node) return .gt;
            previous = node.prev;
        }
    }
    return null;
}

fn visibleRow(top: terminal.Pin, rows: usize, pin: terminal.Pin) ?u32 {
    var node = top.node;
    var first: usize = top.y;
    var offset: usize = 0;
    while (offset < rows) {
        const count = @min(rows - offset, node.rows() - first);
        if (node == pin.node) return if (pin.y >= first and pin.y < first + count) @intCast(offset + pin.y - first) else null;
        offset += count;
        node = node.next orelse return null;
        first = 0;
    }
    return null;
}

fn testSize(cols: u16, rows: u16) Size {
    return .{ .screen = .{ .width = @as(u32, cols) * 8 + 12, .height = @as(u32, rows) * 16 + 8 }, .cell = .{ .width = 8, .height = 16 }, .padding = .{ .left = 6, .right = 6, .top = 4, .bottom = 4 } };
}

fn testOutput(term: *terminal.Terminal, text: []const u8) !void {
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b]133;A;aid=old\x07\r\n\x1b]133;B;aid=old\x07ls\r\n\x1b]133;C;aid=old\x07");
    try term.printString(text);
}

test "path hover requires publication and reuses one same-line identity" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 40, .rows = 8 });
    defer term.deinit(t.allocator);
    try testOutput(&term, "README.md  other.txt");
    const size = testSize(40, 8);
    const viewport: Viewport = .{ .rows = 8 };
    const chrome: Chrome = .{};
    var hover: PathHover = .{};
    const first = hover.probeAt(&term, &chrome, size, viewport, 10, 37).?;
    try t.expectEqualStrings("README.md  other.txt", first.text[0..first.text_len]);
    try t.expectEqualStrings("old", std.mem.sliceTo(&first.block_id, 0));
    try t.expectEqual(@as(u8, 0), hover.snapshot(&term, &chrome, size, viewport).count);
    const moved = hover.probeAt(&term, &chrome, size, viewport, 34, 37).?;
    try t.expectEqual(first.hit_id, moved.hit_id);
    const selected = hover.publish(&term, &chrome, size, viewport, moved.hit_id, 0, 9, false).?;
    try t.expectEqual(@as(u8, 1), selected.count);
    try t.expectEqual(@as(f32, 72), selected.rects[0].width);
    try t.expect(selected.arrow != null);
    _ = hover.probeAt(&term, &chrome, size, viewport, 6 + 13 * 8, 37).?;
    try t.expectEqual(@as(u8, 0), hover.snapshot(&term, &chrome, size, viewport).count);
    try t.expect(hover.publish(&term, &chrome, size, viewport, moved.hit_id, 0, 9, false) == null);
}

test "path hover pixel crop resolves and clips the partially visible bottom row" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 40, .rows = 8 });
    defer term.deinit(t.allocator);
    try testOutput(&term, "README.md");
    const size = testSize(40, 8);
    const chrome: Chrome = .{};
    var hover: PathHover = .{};
    const viewport: Viewport = .{ .rows = 2, .clip_bottom = 36, .footer_top = 40, .scroll_offset_y = 5 };
    const probe = hover.probeAt(&term, &chrome, size, viewport, 10, 32).?;
    try t.expectEqualStrings("README.md", probe.text[0..probe.text_len]);
    const selected = hover.publish(&term, &chrome, size, viewport, probe.hit_id, 0, 9, false).?;
    try t.expectEqual(@as(f32, 31), selected.rects[0].y);
    try t.expectEqual(@as(f32, 5), selected.rects[0].height);
    var moved = viewport;
    moved.scroll_offset_y = 6;
    try t.expectEqual(@as(u8, 0), hover.snapshot(&term, &chrome, size, moved).count);
}

test "path hover maps UTF8 graphemes wide cells and soft wraps without byte splits" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 8, .rows = 8 });
    defer term.deinit(t.allocator);
    term.modes.set(.grapheme_cluster, true);
    const path = "abe\u{301}cd👻z.txt";
    try testOutput(&term, path);
    const size = testSize(8, 8);
    const viewport: Viewport = .{ .rows = 8 };
    const chrome: Chrome = .{};
    var hover: PathHover = .{};
    const probe = hover.probeAt(&term, &chrome, size, viewport, 6 + 2 * 8, 37).?;
    try t.expectEqualStrings(path, probe.text[0..probe.text_len]);
    try t.expect(hover.publish(&term, &chrome, size, viewport, probe.hit_id, 0, 3, false) == null);
    const painted = hover.publish(&term, &chrome, size, viewport, probe.hit_id, 0, probe.text_len, true).?;
    try t.expectEqual(@as(u8, 2), painted.count);
    try t.expectEqual(@as(f32, 64), painted.rects[0].width);
    try t.expect(painted.open);
    const second_row = hover.probeAt(&term, &chrome, size, viewport, 10, 53).?;
    try t.expectEqual(probe.hit_id, second_row.hit_id);
}

test "path hover rejects late validation after same-page overwrite and clearing" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 30, .rows = 8 });
    defer term.deinit(t.allocator);
    try testOutput(&term, "old.txt");
    const size = testSize(30, 8);
    const viewport: Viewport = .{ .rows = 8 };
    const chrome: Chrome = .{};
    var hover: PathHover = .{};
    const probe = hover.probeAt(&term, &chrome, size, viewport, 10, 37).?;
    _ = hover.publish(&term, &chrome, size, viewport, probe.hit_id, 0, 7, false).?;
    term.setCursorPos(3, 1);
    try term.printString("new.txt");
    try t.expect(hover.publish(&term, &chrome, size, viewport, probe.hit_id, 0, 7, true) == null);
    try t.expectEqual(@as(u8, 0), hover.snapshot(&term, &chrome, size, viewport).count);
    const next = hover.probeAt(&term, &chrome, size, viewport, 10, 37).?;
    try t.expect(next.hit_id != probe.hit_id);
    hover.requestClear();
    try t.expect(hover.publish(&term, &chrome, size, viewport, next.hit_id, 0, 7, false) == null);
}

test "path hover rejects stale viewport resize alternate screen and mouse capture" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 30, .rows = 8 });
    defer term.deinit(t.allocator);
    try testOutput(&term, "README\n");
    for (0..20) |_| try term.printString("README\n");
    term.scrollViewport(.top);
    const size = testSize(30, 8);
    const viewport: Viewport = .{ .rows = 8 };
    const chrome: Chrome = .{};
    var hover: PathHover = .{};
    const probe = hover.probeAt(&term, &chrome, size, viewport, 10, 37).?;
    term.scrollViewport(.bottom);
    try t.expect(hover.publish(&term, &chrome, size, viewport, probe.hit_id, 0, 6, false) == null);
    const bottom = hover.probeAt(&term, &chrome, size, viewport, 10, 5).?;
    try t.expect(hover.publish(&term, &chrome, testSize(29, 8), viewport, bottom.hit_id, 0, 6, false) == null);
    _ = try term.switchScreen(.alternate);
    try t.expect(hover.probeAt(&term, &chrome, size, viewport, 10, 5) == null);
    _ = try term.switchScreen(.primary);
    term.flags.mouse_event = .normal;
    try t.expect(hover.probeAt(&term, &chrome, size, viewport, 10, 5) == null);
}

test "path hover keeps historical block ownership across newer cwd and long output" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 30, .rows = 8, .max_scrollback_bytes = null });
    defer term.deinit(t.allocator);
    try testOutput(&term, "README\n");
    for (0..2000) |_| try term.printString("README\n");
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b]133;D;0;aid=old\x07\x1b]133;A;aid=new\x07\r\n\x1b]133;B;aid=new\x07ls\r\n\x1b]133;C;aid=new\x07README");
    term.screens.active.pages.scroll(.{ .row = 1000 });
    const size = testSize(30, 8);
    const viewport: Viewport = .{ .rows = 8 };
    const chrome: Chrome = .{};
    var hover: PathHover = .{};
    const old = hover.probeAt(&term, &chrome, size, viewport, 10, 5).?;
    try t.expectEqualStrings("old", std.mem.sliceTo(&old.block_id, 0));
    const next_row = hover.probeAt(&term, &chrome, size, viewport, 10, 21).?;
    try t.expectEqualStrings("old", std.mem.sliceTo(&next_row.block_id, 0));
    try t.expectEqualStrings("old", std.mem.sliceTo(&hover.owner.?.id, 0));
    term.scrollViewport(.bottom);
    const new = hover.probeAt(&term, &chrome, size, viewport, 10, 4 + 7 * 16).?;
    try t.expectEqualStrings("new", std.mem.sliceTo(&new.block_id, 0));
}

test "path hover local OSC8 is exact and web or remote links stay upstream" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 50, .rows = 8 });
    defer term.deinit(t.allocator);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b]8;;file:///tmp/caf%C3%A9%20x\x07label\x1b]8;;\x07 web ");
    const size = testSize(50, 8);
    const viewport: Viewport = .{ .rows = 8 };
    const chrome: Chrome = .{};
    var hover: PathHover = .{};
    const local = hover.probeAt(&term, &chrome, size, viewport, 10, 5).?;
    try t.expectEqual(Kind.local_osc8, local.kind);
    try t.expectEqualStrings("label", local.text[0..local.text_len]);
    try t.expectEqualStrings("file:///tmp/caf%C3%A9%20x", local.uri[0..local.uri_len]);
    term.setCursorPos(1, 1);
    stream.nextSlice("\x1b]8;;https://example.com/\x07label\x1b]8;;\x07");
    try t.expect(hover.probeAt(&term, &chrome, size, viewport, 10, 5) == null);
    term.setCursorPos(1, 1);
    stream.nextSlice("\x1b]8;;file://remote/tmp/path\x07label\x1b]8;;\x07");
    try t.expect(hover.probeAt(&term, &chrome, size, viewport, 10, 5) == null);
}

test "path hover bounds context and excludes covered footer output" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 10, .rows = 12 });
    defer term.deinit(t.allocator);
    const text: [90]u8 = @splat('a');
    try testOutput(&term, &text);
    const size = testSize(10, 12);
    const chrome: Chrome = .{};
    var hover: PathHover = .{};
    try t.expect(hover.probeAt(&term, &chrome, size, .{ .rows = 12 }, 10, 37) == null);
    try t.expect(hover.probeAt(&term, &chrome, size, .{ .rows = 2, .clip_bottom = 36 }, 10, 37) == null);
}

test "path hover header uses exact path portion and rejects replaced metadata identity" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 50, .rows = 8 });
    defer term.deinit(t.allocator);
    try term.semanticPrompt(.{ .action = .fresh_line_new_prompt, .options_unvalidated = "aid=header" });
    try term.linefeed();
    try term.semanticPrompt(.{ .action = .end_prompt_start_input, .options_unvalidated = "aid=header" });
    var chrome: Chrome = .{};
    defer chrome.deinit(t.allocator);
    _ = try chrome.update(t.allocator, true, -1, &.{.{ .id = "header", .label = "~/folder  branch", .path_len = 8, .suffix = "ok" }});
    const size = testSize(50, 8);
    const viewport: Viewport = .{ .rows = 8 };
    var hover: PathHover = .{};
    const probe = hover.probeAt(&term, &chrome, size, viewport, 10, 5).?;
    try t.expectEqual(Kind.header, probe.kind);
    try t.expectEqualStrings("~/folder", probe.text[0..probe.text_len]);
    const painted = hover.publish(&term, &chrome, size, viewport, probe.hit_id, 0, probe.text_len, true).?;
    try t.expectEqual(@as(u8, 1), painted.count);
    try t.expectEqual(@as(f32, 64), painted.rects[0].width);
    _ = try chrome.update(t.allocator, true, -1, &.{.{ .id = "header", .label = "~/other", .path_len = 7, .suffix = "ok" }});
    try t.expect(hover.publish(&term, &chrome, size, viewport, probe.hit_id, 0, probe.text_len, true) == null);
}

test "path hover new boundary invalidates even identical output bytes" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 30, .rows = 8 });
    defer term.deinit(t.allocator);
    try testOutput(&term, "README");
    const size = testSize(30, 8);
    const viewport: Viewport = .{ .rows = 8 };
    const chrome: Chrome = .{};
    var hover: PathHover = .{};
    const probe = hover.probeAt(&term, &chrome, size, viewport, 10, 37).?;
    _ = hover.publish(&term, &chrome, size, viewport, probe.hit_id, 0, 6, false).?;
    try term.semanticPrompt(.{ .action = .end_command, .options_unvalidated = "0;aid=old" });
    try t.expectEqual(@as(u8, 0), hover.snapshot(&term, &chrome, size, viewport).count);
    try t.expect(hover.publish(&term, &chrome, size, viewport, probe.hit_id, 0, 6, false) == null);
}

test "path hover page comparison obeys one shared budget" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 80, .rows = 8, .max_scrollback_bytes = null });
    defer term.deinit(t.allocator);
    for (0..2000) |_| try term.linefeed();
    const pages = &term.screens.active.pages;
    const first = pages.getTopLeft(.screen);
    const last = pages.getBottomRight(.screen).?;
    try t.expect(first.node != last.node);
    var budget: usize = 0;
    try t.expectEqual(null, comparePins(first, last, &budget));
    try t.expectEqual(std.math.Order.eq, comparePins(first, first, &budget).?);
    budget = 1;
    _ = comparePins(first, last, &budget);
    try t.expectEqual(@as(usize, 0), budget);
    budget = 256;
    try t.expectEqual(std.math.Order.lt, comparePins(first, last, &budget).?);
    try t.expect(budget < 256);
}

test "path hover footer change invalidates same-size published output" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 30, .rows = 8 });
    defer term.deinit(t.allocator);
    try testOutput(&term, "README");
    const size = testSize(30, 8);
    const chrome: Chrome = .{};
    var hover: PathHover = .{};
    const probe = hover.probeAt(&term, &chrome, size, .{ .rows = 8 }, 10, 37).?;
    _ = hover.publish(&term, &chrome, size, .{ .rows = 8 }, probe.hit_id, 0, 6, false).?;
    try t.expectEqual(@as(u8, 0), hover.snapshot(&term, &chrome, size, .{ .rows = 2, .clip_bottom = 36, .footer_top = 40 }).count);
    try t.expect(hover.publish(&term, &chrome, size, .{ .rows = 8 }, probe.hit_id, 0, 6, false) == null);
}
