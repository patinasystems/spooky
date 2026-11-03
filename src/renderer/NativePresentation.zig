//! Acknowledges the immutable terminal snapshot actually assigned to a layer.
//! All tracking is presentation-thread local; no terminal lock or history walk.
const std = @import("std");

pub const Snapshot = extern struct {
    serial: u64 = 0,
    block_id: [65]u8 = @splat(0),
    acknowledge: bool = false,
};

pub const Tracker = struct {
    latest_serial: u64 = 0,
    notified_id: [65]u8 = @splat(0),

    /// Run only after size validation. Synchronous resize draws establish the
    /// ordering barrier but cannot reenter the app while the draw lock is held.
    pub fn admit(self: *Tracker, snapshot: Snapshot, notify: bool) struct { present: bool, notify: bool } {
        if (snapshot.serial < self.latest_serial) return .{ .present = false, .notify = false };
        self.latest_serial = snapshot.serial;
        if (!notify or !snapshot.acknowledge or snapshot.block_id[0] == 0 or
            std.mem.eql(u8, &snapshot.block_id, &self.notified_id))
            return .{ .present = true, .notify = false };
        self.notified_id = snapshot.block_id;
        return .{ .present = true, .notify = true };
    }
};

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
    const sync = tracker.admit(value, false);
    try t.expect(sync.present and !sync.notify);
    try t.expect(!tracker.admit(.{ .serial = 7 }, true).present);
    try t.expect(tracker.admit(value, true).notify);
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
