//! Acknowledges the immutable terminal snapshot actually assigned to a layer.
//! All tracking is presentation-thread local; no terminal lock or history walk.
const std = @import("std");

pub const Snapshot = extern struct {
    serial: u64 = 0,
    block_id: [65]u8 = @splat(0),
    acknowledge: bool = false,
    prompt_id: [65]u8 = @splat(0),
    generation: [65]u8 = @splat(0),
    defer_prompt: bool = false,
    awaiting_native_layout: bool = false,
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

    /// A new native boundary needs an AppKit callback outside the draw lock.
    pub fn needsNotification(self: *const Tracker, snapshot: Snapshot) bool {
        return (snapshot.acknowledge and snapshot.block_id[0] != 0 and
            !std.mem.eql(u8, &snapshot.block_id, &self.notified_id)) or
            !std.mem.eql(u8, &snapshot.generation, &self.notified_generation);
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
