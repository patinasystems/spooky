//! Command regions in the real terminal grid. Only explicitly identified
//! OSC 133 markers participate; no text or ANSI output is duplicated here.
const CommandBlocks = @This();
const std = @import("std");
const PageList = @import("PageList.zig");
const Allocator = std.mem.Allocator;
const Pin = PageList.Pin;

pub const capacity = 1024;
pub const Kind = enum { header, input, output, end };
pub const Block = struct {
    id: [65]u8 = @splat(0),
    id_len: u8,
    header: ?*Pin = null,
    input: ?*Pin = null,
    output: ?*Pin = null,
    end: ?*Pin = null,
    complete: bool = false,
    marked: u4 = 1,
    end_inclusive: bool = false,

    fn deinit(self: *Block, pages: *PageList) void {
        inline for (.{ "header", "input", "output", "end" }) |field| {
            if (@field(self, field)) |p| pages.untrackPin(p);
            @field(self, field) = null;
        }
    }

    fn alive(self: Block) bool {
        inline for (.{ "header", "input", "output", "end" }) |field| {
            if (@field(self, field)) |p| if (!p.garbage) return true;
        }
        return false;
    }
};

/// Row coordinates relative to the current viewport, before pixel conversion.
pub const Region = struct {
    flags: u32 = 0,
    header: i64 = 0,
    input: i64 = 0,
    output: i64 = 0,
    end: i64 = 0,
};

blocks: std.ArrayList(Block) = .empty,

pub fn deinit(self: *CommandBlocks, alloc: Allocator, pages: *PageList) void {
    for (self.blocks.items) |*block| block.deinit(pages);
    self.blocks.deinit(alloc);
    self.* = .{};
}

/// Release dead pins promptly, without interpreting their recycled positions.
pub fn prune(self: *CommandBlocks, pages: *PageList) void {
    var i: usize = 0;
    while (i < self.blocks.items.len) {
        const block = &self.blocks.items[i];
        // A long-running command may outlive every start pin in bounded
        // scrollback. Retain its identity until D supplies a live end anchor.
        if (block.complete and !block.alive()) {
            block.deinit(pages);
            _ = self.blocks.orderedRemove(i);
            continue;
        }
        inline for (.{ "header", "input", "output", "end" }) |field| {
            if (@field(block, field)) |p| if (p.garbage) {
                pages.untrackPin(p);
                @field(block, field) = null;
            };
        }
        i += 1;
    }
}

pub fn mark(
    self: *CommandBlocks,
    alloc: Allocator,
    pages: *PageList,
    kind: Kind,
    id: []const u8,
    pin: Pin,
    end_inclusive: bool,
) Allocator.Error!void {
    // The fixed C representation is UTF-8/byte preserving and NUL terminated.
    if (id.len == 0 or id.len > 64) return;
    for (id) |c| if (c < 0x20 or c == 0x7f) return;
    self.prune(pages);

    for (self.blocks.items) |*block| {
        if (!std.mem.eql(u8, block.id[0..block.id_len], id)) continue;
        // Repeated B markers from ZLE redraw/continuation must not move the
        // original input anchor. Completed IDs cannot be reopened by redraw.
        if (block.complete) return;
        const bit = @as(u4, 1) << @backingInt(kind);
        if (block.marked & bit != 0) return;
        switch (kind) {
            inline else => |k| {
                const endpoint = &@field(block, @tagName(k));
                if (endpoint.* == null) endpoint.* = try pages.trackPin(pin);
            },
        }
        block.marked |= bit;
        if (kind == .end) {
            block.complete = true;
            block.end_inclusive = end_inclusive;
        }
        return;
    }

    // A mismatched B/C/D cannot complete or move some unrelated command.
    if (kind != .header) return;
    const tracked = try pages.trackPin(pin);
    errdefer pages.untrackPin(tracked);
    if (self.blocks.items.len == capacity) {
        self.blocks.items[0].deinit(pages);
        _ = self.blocks.orderedRemove(0);
    }
    var block: Block = .{ .id_len = @intCast(id.len), .header = tracked };
    @memcpy(block.id[0..id.len], id);
    try self.blocks.append(alloc, block);
}

/// Clearing cells does not make PageList pins garbage. Explicitly invalidate
/// endpoints on cleared rows so old chrome cannot cover newly written text.
pub fn invalidateRows(self: *CommandBlocks, pages: *PageList, first: Pin, last: Pin) void {
    for (self.blocks.items) |*block| {
        inline for (.{ "header", "input", "output", "end" }) |field| {
            if (@field(block, field)) |p| {
                var row_pin = p.*;
                row_pin.x = 0;
                if (!row_pin.before(first) and !last.before(row_pin)) {
                    pages.untrackPin(p);
                    @field(block, field) = null;
                }
            }
        }
    }
    var i: usize = 0;
    while (i < self.blocks.items.len) {
        const block = &self.blocks.items[i];
        if (!block.alive()) {
            block.deinit(pages);
            _ = self.blocks.orderedRemove(i);
        } else i += 1;
    }
}

/// EL/ECH may redraw input repeatedly. Only a reserved header on the erased
/// row loses its chrome; the first input anchor must survive normal ZLE redraw.
pub fn invalidateHeader(self: *CommandBlocks, pages: *PageList, pin: Pin) void {
    for (self.blocks.items) |*block| {
        if (block.header) |header| {
            if (header.node == pin.node and header.y == pin.y) {
                pages.untrackPin(header);
                block.header = null;
            }
        }
    }
}

fn row(pages: *const PageList, pin: ?*const Pin, viewport_offset: usize) ?i64 {
    const p = pin orelse return null;
    if (p.garbage) return null;
    if (pages.pointFromPin(.viewport, p.*)) |pt| return pt.viewport.y;
    const pt = pages.pointFromPin(.screen, p.*) orelse return null;
    return @as(i64, pt.screen.y) - @as(i64, @intCast(viewport_offset));
}

/// Null means the region is wholly outside the viewport. Missing anchors are
/// clipped to the viewport edge, but never advertised as valid endpoints.
pub fn region(block: Block, pages: *const PageList, viewport_offset: usize, cursor: Pin) ?Region {
    // Most stored commands are above the viewport. This check traverses only
    // pages from the viewport down, rather than scanning all history per pin.
    if (block.end) |end| {
        if (!end.garbage and pages.pointFromPin(.viewport, end.*) == null) return null;
    }
    var result: Region = .{};
    var start: ?i64 = null;
    var lower: ?i64 = null;
    inline for (.{ "header", "input", "output", "end" }, 0..) |field, bit| {
        if (row(pages, @field(block, field), viewport_offset)) |y| {
            result.flags |= @as(u32, 1) << bit;
            @field(result, field) = y;
            if (bit < 3) start = if (start) |v| @min(v, y) else y;
            lower = if (lower) |v| @max(v, y + 1) else y + 1;
        }
    }
    if (result.flags == 0 and block.complete) return null;
    if (result.flags & 8 != 0) {
        // D at column zero names the next unused row. Otherwise its row
        // contains output and belongs in the command's exclusive lower bound.
        result.end += if (block.end_inclusive) @as(i64, 1) else 0;
    } else if (!block.complete) {
        const cursor_row = row(pages, &cursor, viewport_offset) orelse return null;
        result.end = @max(lower orelse 0, cursor_row + 1);
    } else {
        result.end = lower orelse return null;
    }
    if (result.end <= 0 or (start orelse 0) >= pages.rows) return null;
    return result;
}
