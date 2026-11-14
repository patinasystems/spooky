//! Acknowledges the immutable terminal snapshot actually assigned to a layer.
//! All tracking is presentation-thread local; no terminal lock or history walk.
const std = @import("std");
const terminal = @import("../terminal/main.zig");
const Size = @import("size.zig").Size;

/// Physical-pixel coordinates captured under the same lock as the rendered
/// terminal snapshot. Native views must follow these pixels, not a newer live
/// viewport read performed when an older GPU frame reaches the main thread.
pub const PromptGeometry = extern struct {
    cursor_valid: bool = false,
    cursor_x: f64 = 0,
    cursor_y: f64 = 0,
    viewport_width: u32 = 0,
    viewport_height: u32 = 0,
    columns: u32 = 0,
    rows: u32 = 0,

    pub fn capture(term: *const terminal.Terminal, size: Size, bar: terminal.Scrollbar, scroll_offset_y: f32) PromptGeometry {
        const screen = term.screens.active;
        var result: PromptGeometry = .{
            .viewport_width = size.screen.width,
            .viewport_height = size.screen.height,
            .columns = screen.pages.cols,
            .rows = screen.pages.rows,
        };
        if (term.screens.active_key != .primary) return result;
        // The cursor belongs to the active screen. Use the already-captured
        // scrollbar to project it in O(1), even far back in large scrollback.
        // pointFromPin would walk pages from the viewport to the live cursor.
        const row = (bar.total -| bar.len -| bar.offset) +| screen.cursor.y;
        if (screen.pages.rows == 0 or row > screen.pages.rows or screen.cursor.x >= screen.pages.cols) return result;
        // Pixel scrolling exposes one row below the integer viewport. Preserve
        // the native editor while any of that same overscan row is visible.
        if (row == screen.pages.rows and
            (scroll_offset_y <= 0 or bar.offset >= bar.total -| bar.len)) return result;
        result.cursor_valid = true;
        result.cursor_x = @as(f64, @floatFromInt(size.padding.left)) +
            @as(f64, @floatFromInt(screen.cursor.x)) * @as(f64, @floatFromInt(size.cell.width));
        result.cursor_y = rowY(size, @intCast(row), scroll_offset_y);
        return result;
    }

    pub fn eql(self: PromptGeometry, other: PromptGeometry) bool {
        return self.cursor_valid == other.cursor_valid and self.cursor_x == other.cursor_x and
            self.cursor_y == other.cursor_y and self.viewport_width == other.viewport_width and
            self.viewport_height == other.viewport_height and self.columns == other.columns and self.rows == other.rows;
    }
};

/// Shared row-to-pixel mapping for advisory API geometry and presented prompts.
/// Signed rows also cover block anchors above the top of the viewport.
pub fn rowY(size: Size, row: i64, scroll_offset_y: f32) f64 {
    return @as(f64, @floatFromInt(size.padding.top)) +
        @as(f64, @floatFromInt(row)) * @as(f64, @floatFromInt(size.cell.height)) - scroll_offset_y;
}

pub const Snapshot = extern struct {
    serial: u64 = 0,
    block_id: [65]u8 = @splat(0),
    acknowledge: bool = false,
    prompt_id: [65]u8 = @splat(0),
    generation: [65]u8 = @splat(0),
    defer_prompt: bool = false,
    awaiting_native_layout: bool = false,
    prompt_geometry: PromptGeometry = .{},
};

/// A newly presentable command or prompt is an input response. Submit its GPU
/// work immediately instead of spending another refresh interval waiting for
/// the display link. Layer admission still owns the atomic AppKit handoff.
pub fn needsImmediateDraw(before: Snapshot, after: Snapshot) bool {
    if (after.awaiting_native_layout or after.defer_prompt) return false;
    return (after.acknowledge and after.block_id[0] != 0 and
        (!before.acknowledge or !std.mem.eql(u8, &before.block_id, &after.block_id))) or
        (after.generation[0] != 0 and
            (before.awaiting_native_layout or !std.mem.eql(u8, &before.generation, &after.generation)));
}

pub const Tracker = struct {
    latest_serial: u64 = 0,
    notified_id: [65]u8 = @splat(0),
    notified_generation: [65]u8 = @splat(0),
    notified_geometry: PromptGeometry = .{},

    /// A new native boundary needs an AppKit callback outside the draw lock.
    pub fn needsNotification(self: *const Tracker, snapshot: Snapshot) bool {
        return (snapshot.acknowledge and snapshot.block_id[0] != 0 and
            !std.mem.eql(u8, &snapshot.block_id, &self.notified_id)) or
            !std.mem.eql(u8, &snapshot.generation, &self.notified_generation) or
            (snapshot.generation[0] != 0 and !snapshot.prompt_geometry.eql(self.notified_geometry));
    }

    /// Run only after size validation. Synchronous resize draws establish the
    /// ordering barrier but cannot reenter the app while the draw lock is held.
    pub fn admit(self: *Tracker, snapshot: Snapshot, notify: bool) struct { present: bool, notify: bool } {
        if (snapshot.serial < self.latest_serial) return .{ .present = false, .notify = false };
        self.latest_serial = snapshot.serial;
        // A parsed B can precede the UI's preparation of its footer. Such a
        // frame is an ordering barrier, not a presentable prompt. The prepared
        // chrome revision wakes a fresh draw; running/alternate output never
        // enters this gate and does not wait for native UI.
        if (snapshot.awaiting_native_layout) return .{ .present = false, .notify = false };
        if (!notify) return .{ .present = true, .notify = false };
        const command_changed = snapshot.acknowledge and snapshot.block_id[0] != 0 and
            !std.mem.eql(u8, &snapshot.block_id, &self.notified_id);
        if (!self.needsNotification(snapshot)) return .{ .present = true, .notify = false };
        if (command_changed) self.notified_id = snapshot.block_id;
        self.notified_generation = snapshot.generation;
        self.notified_geometry = snapshot.prompt_geometry;
        return .{ .present = true, .notify = true };
    }
};

test "native presentation never exposes ready pixels built before native footer preparation" {
    const t = std.testing;
    var tracker: Tracker = .{};
    var ready: Snapshot = .{ .serial = 5, .awaiting_native_layout = true, .acknowledge = true };
    @memcpy(ready.block_id[0..3], "cmd");
    @memcpy(ready.generation[0..3], "new");
    for ([_]bool{ false, true }) |notify| {
        const withheld = tracker.admit(ready, notify);
        try t.expect(!withheld.present and !withheld.notify);
    }
    // Neither a queued older image nor a synchronous resize may bypass it.
    try t.expect(!tracker.admit(.{ .serial = 4 }, true).present);
    ready.serial = 6;
    ready.awaiting_native_layout = false;
    const prepared = tracker.admit(ready, true);
    try t.expect(prepared.present and prepared.notify);
    try t.expect(!tracker.admit(ready, true).notify);
}

test "native presentation draws command and prepared prompt boundaries without a vsync wait" {
    const t = std.testing;
    var command: Snapshot = .{ .acknowledge = true };
    @memcpy(command.block_id[0..3], "cmd");
    try t.expect(needsImmediateDraw(.{}, command));
    try t.expect(!needsImmediateDraw(command, command));
    var unproven = command;
    unproven.acknowledge = false;
    try t.expect(needsImmediateDraw(unproven, command));

    var ready = command;
    @memcpy(ready.generation[0..3], "new");
    ready.awaiting_native_layout = true;
    try t.expect(!needsImmediateDraw(command, ready));
    const unprepared = ready;
    ready.awaiting_native_layout = false;
    try t.expect(needsImmediateDraw(unprepared, ready));
    try t.expect(!needsImmediateDraw(ready, ready));
    var erased = command;
    erased.defer_prompt = true;
    try t.expect(!needsImmediateDraw(.{}, erased));
    try t.expect(!needsImmediateDraw(ready, .{}));
}

test "native presentation acknowledges new IDs once and rejects older queued frames" {
    const t = std.testing;
    var tracker: Tracker = .{};
    var first: Snapshot = .{ .serial = 1, .acknowledge = true };
    @memcpy(first.block_id[0..3], "one");
    const accepted = tracker.admit(first, true);
    try t.expect(accepted.present and accepted.notify);
    try t.expect(!tracker.admit(first, true).notify);
    var second: Snapshot = .{ .serial = 3, .acknowledge = true };
    @memcpy(second.block_id[0..3], "two");
    try t.expect(tracker.admit(second, true).notify);
    first.serial = 2;
    try t.expect(!tracker.admit(first, true).present);
    try t.expectEqualStrings("two", tracker.notified_id[0..3]);
    // Raw/alternate/initial frames establish ordering but do not acknowledge a
    // submitted command. A delayed pre-C frame must never retire its echo.
    try t.expect(!tracker.admit(.{ .serial = 4 }, true).notify);
    try t.expect(!tracker.admit(second, true).present);
}

test "native presentation synchronous draw defers app callback without losing acknowledgement" {
    const t = std.testing;
    var tracker: Tracker = .{};
    var value: Snapshot = .{ .serial = 8, .acknowledge = true };
    @memcpy(value.block_id[0..3], "cmd");
    try t.expect(tracker.needsNotification(value));
    const sync = tracker.admit(value, false);
    try t.expect(sync.present and !sync.notify);
    try t.expect(tracker.needsNotification(value));
    try t.expect(!tracker.admit(.{ .serial = 7 }, true).present);
    try t.expect(tracker.admit(value, true).notify);
    try t.expect(!tracker.needsNotification(value));
    value.serial = 9;
    try t.expect(!tracker.admit(value, true).notify);
}

test "native presentation unproven cropped C waits for a complete snapshot" {
    const t = std.testing;
    var tracker: Tracker = .{};
    var value: Snapshot = .{ .serial = 1 };
    @memcpy(value.block_id[0..3], "cmd");
    try t.expect(!tracker.admit(value, true).notify);
    value.serial = 2;
    value.acknowledge = true;
    try t.expect(tracker.admit(value, true).notify);
}

test "native presentation binds ready generation to actual layer assignment independently of C" {
    const t = std.testing;
    var tracker: Tracker = .{};
    var snapshot: Snapshot = .{ .serial = 1 };
    @memcpy(snapshot.prompt_id[0..4], "12-1");
    @memcpy(snapshot.generation[0..4], "12-3");
    try t.expect(tracker.admit(snapshot, true).notify);
    snapshot.serial = 2;
    try t.expect(!tracker.admit(snapshot, true).notify);
    snapshot.serial = 3;
    snapshot.generation = @splat(0);
    try t.expect(tracker.admit(snapshot, true).notify);
    @memcpy(snapshot.generation[0..4], "12-4");
    snapshot.serial = 4;
    try t.expect(tracker.admit(snapshot, true).notify);
    snapshot.serial = 3;
    try t.expect(!tracker.admit(snapshot, true).present);
}

test "native presentation moves a ready prompt with each assigned pixel scroll frame" {
    const t = std.testing;
    var tracker: Tracker = .{};
    var frame: Snapshot = .{
        .serial = 1,
        .prompt_geometry = .{ .cursor_valid = true, .cursor_x = 12, .cursor_y = 100, .viewport_width = 800, .viewport_height = 600, .columns = 80, .rows = 30 },
    };
    @memcpy(frame.generation[0..5], "ready");
    try t.expect(tracker.admit(frame, true).notify);
    // Even sub-row movement needs a callback, but an unchanged frame does not.
    frame.serial = 2;
    frame.prompt_geometry.cursor_y = 99;
    try t.expect(tracker.needsNotification(frame));
    try t.expect(tracker.admit(frame, true).notify);
    try t.expect(!tracker.admit(frame, true).notify);
    const older = frame;
    frame.serial = 3;
    frame.prompt_geometry.cursor_y = 98;
    // A synchronous resize cannot reenter AppKit while holding the draw lock.
    try t.expect(!tracker.admit(frame, false).notify);
    try t.expect(tracker.needsNotification(frame));
    try t.expect(tracker.admit(frame, true).notify);
    try t.expect(!tracker.admit(older, true).present);
    // Leaving the viewport must hide an inline editor in the assigned frame.
    frame.serial = 4;
    frame.prompt_geometry.cursor_valid = false;
    try t.expect(tracker.admit(frame, true).notify);
    frame.serial = 5;
    frame.prompt_geometry.viewport_width = 900;
    frame.prompt_geometry.columns = 90;
    try t.expect(tracker.admit(frame, true).notify);
    // Running output does not incur native layout work on ordinary frames.
    frame.serial = 6;
    frame.generation = @splat(0);
    try t.expect(tracker.admit(frame, true).notify);
    frame.serial = 7;
    frame.prompt_geometry.cursor_y = 200;
    try t.expect(!tracker.admit(frame, true).notify);
}

test "native presentation prompt coordinates follow pixel scroll through row crossings" {
    const t = std.testing;
    const ViewportScroll = @import("ViewportScroll.zig");
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 80, .rows = 10 });
    defer term.deinit(t.allocator);
    for (0..30) |_| try term.linefeed();
    term.setCursorPos(2, 3);
    const size: Size = .{
        .screen = .{ .width = 800, .height = 400 },
        .cell = .{ .width = 8, .height = 34 },
        .padding = .{ .left = 12, .top = 12 },
    };
    const initial = PromptGeometry.capture(&term, size, term.screens.active.pages.scrollbar(), 0);
    try t.expect(initial.cursor_valid);
    try t.expectEqual(@as(f64, 28), initial.cursor_x);
    try t.expectEqual(@as(f64, 46), initial.cursor_y);
    var scroll: ViewportScroll = .{};
    var pixels: f64 = 0;
    for ([_]f64{ 1, 0.25, 0.5, 8, 4, 2, 35, -34, -5 }) |delta| {
        const rows = scroll.scroll(term.screens.active.pages.scrollbar(), size.cell.height, delta);
        term.scrollViewport(.{ .delta = rows });
        const crop = scroll.currentOffset(term.screens.active.pages.scrollbar(), size.cell.height, true);
        const geometry = PromptGeometry.capture(&term, size, term.screens.active.pages.scrollbar(), crop);
        pixels += delta;
        try t.expect(geometry.cursor_valid);
        // The renderer rounds to physical pixels. AppKit's point conversion
        // must preserve this same half-pixel placement on a 2x display.
        try t.expectApproxEqAbs(initial.cursor_y + pixels, geometry.cursor_y, 0.5);
        try t.expectApproxEqAbs((initial.cursor_y + pixels) / 2, geometry.cursor_y / 2, 0.25);
        try t.expectEqual(initial.viewport_width, geometry.viewport_width);
        try t.expectEqual(initial.viewport_height, geometry.viewport_height);
    }
    term.scrollViewport(.top);
    try t.expect(!PromptGeometry.capture(&term, size, term.screens.active.pages.scrollbar(), 0).cursor_valid);
    term.scrollViewport(.bottom);
    const crop = scroll.currentOffset(term.screens.active.pages.scrollbar(), size.cell.height, true);
    try t.expectEqualDeep(initial, PromptGeometry.capture(&term, size, term.screens.active.pages.scrollbar(), crop));
    try t.expectEqual(@as(f64, -25), rowY(size, -1, 3));
}

test "native presentation keeps partially visible prompt in bottom overscan" {
    const t = std.testing;
    const ViewportScroll = @import("ViewportScroll.zig");
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 80, .rows = 10 });
    defer term.deinit(t.allocator);
    for (0..30) |_| try term.linefeed();
    term.setCursorPos(9, 1);
    const size: Size = .{
        .screen = .{ .width = 800, .height = 400 },
        .cell = .{ .width = 8, .height = 34 },
        .padding = .{ .left = 12, .top = 12 },
    };
    var scroll: ViewportScroll = .{};
    // Starting two rows above the bottom, 35 pixels of earlier history puts
    // the cursor in row 10 with a 33-pixel crop: most of it remains visible.
    for ([_]struct { delta: f64, valid: bool, y: f64 }{
        .{ .delta = 35, .valid = true, .y = 319 },
        .{ .delta = 32, .valid = true, .y = 351 },
        .{ .delta = 1, .valid = false, .y = 0 },
        .{ .delta = -1, .valid = true, .y = 351 },
    }) |step| {
        const delta = scroll.scroll(term.screens.active.pages.scrollbar(), size.cell.height, step.delta);
        term.scrollViewport(.{ .delta = delta });
        const bar = term.screens.active.pages.scrollbar();
        const crop = scroll.currentOffset(bar, size.cell.height, true);
        const geometry = PromptGeometry.capture(&term, size, bar, crop);
        try t.expectEqual(step.valid, geometry.cursor_valid);
        try t.expectEqual(step.y, geometry.cursor_y);
    }
}
