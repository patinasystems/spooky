//! One-shot recovery for Claude Code's classic-screen dialog contraction.
//! Terminal coordinates, scrollback and PTY dimensions are never rewritten.
const Self = @This();
const std = @import("std");
const builtin = @import("builtin");
const terminal = @import("../terminal/main.zig");
const CellCount = terminal.size.CellCountInt;

/// Hint for input-side cancellation; every other field requires the terminal mutex.
active: std.atomic.Value(bool) = .init(false),
phase: enum { idle, armed, requested } = .idle,
epoch: u64 = 0,
pid: u64 = 0,
deadline_ms: i64 = 0,
rows: CellCount = 0,
columns: CellCount = 0,
initial_tail: CellCount = 0,
erase_min: CellCount = std.math.maxInt(CellCount),
erase_max: CellCount = 0,

pub const Request = struct { epoch: u64, pid: u64 };

test "classic TUI recovery has bounded per-surface state" {
    try std.testing.expect(@sizeOf(Self) <= 48);
}

pub fn cancel(self: *Self) void {
    self.phase = .idle;
    self.active.store(false, .release);
}

/// The caller has verified the actual foreground executable, not its OSC title.
pub fn arm(self: *Self, term: *const terminal.Terminal, pid: u64, now_ms: i64) void {
    self.cancel();
    if (pid == 0 or !eligible(term)) return;
    const tail = blankTail(term);
    // A short initial conversation naturally has unused space. Only repair a
    // dialog which occupied the bottom before the user's Escape.
    if (tail > 2) return;
    self.epoch +%= 1;
    self.pid = pid;
    self.deadline_ms = now_ms + 500;
    self.rows = std.math.cast(CellCount, term.rows) orelse return;
    self.columns = std.math.cast(CellCount, term.cols) orelse return;
    self.initial_tail = @intCast(tail);
    self.erase_min = std.math.maxInt(CellCount);
    self.erase_max = 0;
    self.phase = .armed;
    self.active.store(true, .release);
}

pub fn erasedLine(self: *Self, term: *const terminal.Terminal) void {
    if (self.phase != .armed or !term.modes.get(.synchronized_output)) return;
    const row = term.screens.active.cursor.y;
    self.erase_min = @min(self.erase_min, row);
    self.erase_max = @max(self.erase_max, row);
}

/// Called only at ESU, never while a synchronized frame is half parsed.
pub fn finishFrame(self: *Self, term: *const terminal.Terminal, now_ms: i64) ?Request {
    if (self.phase != .armed) return null;
    if (!self.valid(term, now_ms)) {
        self.cancel();
        return null;
    }
    if (!term.modes.get(.cursor_visible) or self.erase_min == std.math.maxInt(CellCount) or
        self.erase_max - self.erase_min < 3) return null;
    const tail = blankTail(term);
    if (tail < self.initial_tail + 4) return null;
    // Consume the attempt before queuing a redraw. Its response cannot recurse.
    self.phase = .requested;
    return .{ .epoch = self.epoch, .pid = self.pid };
}

/// Revalidate on the writing thread. A new key, resize, program exit, alternate
/// screen or foreground job change invalidates the queued request.
pub fn take(self: *Self, request: Request, term: *const terminal.Terminal, pid: u64, now_ms: i64) bool {
    if (self.phase != .requested or self.epoch != request.epoch) return false;
    defer self.cancel();
    return request.pid == self.pid and pid == self.pid and self.valid(term, now_ms);
}

fn valid(self: *const Self, term: *const terminal.Terminal, now_ms: i64) bool {
    return now_ms <= self.deadline_ms and term.rows == self.rows and term.cols == self.columns and eligible(term);
}

fn eligible(term: *const terminal.Terminal) bool {
    return term.screens.active_key == .primary and !term.native_prompt_active and
        term.screens.active.pages.viewport == .active and term.flags.mouse_event == .none and
        term.rows >= 10;
}

/// Erased rows carry a blank bit. This is O(viewport rows), not O(cells) or
/// O(scrollback); decorated whitespace and graphics fail closed.
fn blankTail(term: *const terminal.Terminal) usize {
    const screen = term.screens.active;
    if (comptime terminal.options.kitty_graphics) {
        if (screen.kitty_images.placements.count() != 0) return 0;
    }
    var pin = screen.pages.getBottomRight(.screen) orelse return 0;
    var count: usize = 0;
    while (count < term.rows and pin.rowAndCell().row.blank) : (count += 1) {
        pin = pin.up(1) orelse return count + 1;
    }
    return count;
}

/// Native Claude installations use either a `claude` executable or the
/// versioned native installer directory. Node, shells, ssh and tmux do not
/// qualify. No argv, user text or executable title is trusted as identity.
pub fn isClaudeExecutable(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    if (std.mem.eql(u8, std.fs.path.basename(path), "claude")) return true;
    const versions = std.fs.path.dirname(path) orelse return false;
    const owner = std.fs.path.dirname(versions) orelse return false;
    if (!std.mem.eql(u8, std.fs.path.basename(versions), "versions") or
        !std.mem.eql(u8, std.fs.path.basename(owner), "claude")) return false;
    const version = std.fs.path.basename(path);
    _ = std.SemanticVersion.parse(version) catch return false;
    return true;
}

pub fn isClaudeProcess(pid: u64) bool {
    if (comptime !builtin.target.os.tag.isDarwin()) return false;
    const native_pid = std.math.cast(c_int, pid) orelse return false;
    if (native_pid <= 0) return false;
    var buffer: [4096]u8 = undefined;
    const len = proc_pidpath(native_pid, &buffer, buffer.len);
    if (len <= 0 or len >= buffer.len) return false;
    return isClaudeExecutable(std.mem.sliceTo(buffer[0..@intCast(len)], 0));
}

extern "c" fn proc_pidpath(c_int, *anyopaque, u32) c_int;

test "classic TUI recovery trusts native executable paths rather than titles or node" {
    const t = std.testing;
    try t.expect(isClaudeExecutable("/opt/homebrew/bin/claude"));
    try t.expect(isClaudeExecutable("/Users/example/.local/share/claude/versions/2.1.319"));
    for ([_][]const u8{ "claude", "/usr/bin/ssh", "/opt/homebrew/bin/node", "/tmp/versions/2.1.319", "/tmp/claude/versions/not-a-version" }) |path|
        try t.expect(!isClaudeExecutable(path));
}

fn fixture() !terminal.Terminal {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 80, .rows = 34 });
    for (0..34) |row| {
        term.setCursorPos(@intCast(row + 1), 1);
        try term.printString("dialog row");
    }
    return term;
}

fn collapse(recovery: *Self, term: *terminal.Terminal) void {
    term.modes.set(.synchronized_output, true);
    for (10..34) |row| {
        term.setCursorPos(@intCast(row + 1), 1);
        recovery.erasedLine(term);
        term.eraseLine(.complete, false);
    }
    term.setCursorPos(7, 3);
    term.modes.set(.synchronized_output, false);
}

test "classic TUI recovery requests one redraw after synchronized dialog contraction" {
    const t = std.testing;
    var term = try fixture();
    defer term.deinit(t.allocator);
    var recovery: Self = .{};
    recovery.arm(&term, 42, 100);
    collapse(&recovery, &term);
    const request = recovery.finishFrame(&term, 120).?;
    try t.expectEqual(@as(usize, 24), blankTail(&term));
    try t.expectEqual(@as(usize, 34), term.rows);
    try t.expect(recovery.finishFrame(&term, 121) == null);
    try t.expect(recovery.take(request, &term, 42, 122));
    try t.expect(!recovery.take(request, &term, 42, 123));
    try t.expect(!recovery.active.load(.acquire));
}

test "classic TUI recovery cancels for input expiry resize prompt alternate screen and job changes" {
    const t = std.testing;
    const Case = enum { input, expired, resized, prompt, alternate, job, old_request };
    for (std.enums.values(Case)) |case| {
        var term = try fixture();
        defer term.deinit(t.allocator);
        var recovery: Self = .{};
        recovery.arm(&term, 42, 100);
        collapse(&recovery, &term);
        const request = recovery.finishFrame(&term, 120).?;
        switch (case) {
            .input => recovery.cancel(),
            .expired => {},
            .resized => try term.resize(t.allocator, .{ .cols = 79, .rows = 34 }),
            .prompt => term.native_prompt_active = true,
            .alternate => try term.switchScreenMode(.@"1049", true),
            .job => {},
            .old_request => {
                recovery.cancel();
                term.setCursorPos(34, 1);
                try term.printString("new dialog");
                recovery.arm(&term, 42, 125);
            },
        }
        try t.expect(!recovery.take(request, &term, if (case == .job) 43 else 42, if (case == .expired) 601 else 130));
    }
}

test "classic TUI recovery ignores normal input short conversations and unsynchronized erasure" {
    const t = std.testing;
    var term = try fixture();
    defer term.deinit(t.allocator);
    var recovery: Self = .{};
    recovery.arm(&term, 42, 100);
    try t.expect(recovery.finishFrame(&term, 110) == null);
    for (10..34) |row| {
        term.setCursorPos(@intCast(row + 1), 1);
        recovery.erasedLine(&term);
        term.eraseLine(.complete, false);
    }
    try t.expect(recovery.finishFrame(&term, 120) == null);
    recovery.arm(&term, 42, 130);
    try t.expect(!recovery.active.load(.acquire));
}
