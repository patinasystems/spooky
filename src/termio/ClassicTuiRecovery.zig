//! One-shot recovery for Claude Code's classic-screen dialog contraction.
//! Terminal coordinates, scrollback and PTY dimensions are never rewritten.
const Self = @This();
const std = @import("std");
const builtin = @import("builtin");
const terminal = @import("../terminal/main.zig");
const CellCount = terminal.size.CellCountInt;
pub const input_capacity = 512;

/// Hint for input-side cancellation; every other field requires the terminal mutex.
active: std.atomic.Value(bool) = .init(false),
phase: enum { idle, armed, requested, redrawing, flushing } = .idle,
epoch: u64 = 0,
pid: u64 = 0,
deadline_ms: i64 = 0,
rows: CellCount = 0,
columns: CellCount = 0,
initial_tail: CellCount = 0,
erase_min: CellCount = std.math.maxInt(CellCount),
erase_max: CellCount = 0,
flush_queued: bool = false,
input: [input_capacity]u8 = undefined,
input_len: u16 = 0,

pub const Request = struct { epoch: u64, pid: u64 };

/// Ctrl-L preserves Claude's draft. Do not lose recovery when the next
/// printable key overtakes its dismissal frame; submission/navigation/control
/// actions still cancel before they can change the meaning of the request.
pub fn cancelsOnKey(event: @import("../input.zig").KeyEvent) bool {
    if (event.action == .release or event.key.modifier()) return false;
    const mods = event.effectiveMods();
    if (mods.ctrl or mods.alt or mods.super) return true;
    switch (event.key) {
        .enter, .numpad_enter, .tab, .escape => return true,
        .backspace, .delete, .numpad_backspace, .numpad_delete => return false,
        else => {},
    }
    return !(event.key.printable() or (event.utf8.len > 0 and !cancelsForText(event.utf8)));
}

pub fn cancelsForText(bytes: []const u8) bool {
    for (bytes) |byte| if (byte < 0x20 or byte == 0x7f) return true;
    return false;
}

test "classic TUI recovery has bounded per-surface state" {
    try std.testing.expect(@sizeOf(Self) <= input_capacity + 64);
}

pub fn bufferInput(self: *Self, bytes: []const u8) bool {
    if (self.phase == .idle or bytes.len > self.input.len - self.input_len) return false;
    @memcpy(self.input[self.input_len..][0..bytes.len], bytes);
    self.input_len += @intCast(bytes.len);
    return true;
}

pub fn drain(self: *Self, output: *[input_capacity]u8) usize {
    const len = self.input_len;
    @memcpy(output[0..len], self.input[0..len]);
    self.input_len = 0;
    return len;
}

pub fn flushRequest(self: *Self) ?u64 {
    if (self.phase != .flushing or self.flush_queued) return null;
    self.flush_queued = true;
    return self.epoch;
}

pub fn erasedDisplay(self: *Self) void {
    if (self.phase != .redrawing) return;
    self.erase_min = 0;
    self.erase_max = self.rows - 1;
}

test "classic TUI recovery preserves immediate draft edits but cancels submission and navigation" {
    const t = std.testing;
    try t.expect(!cancelsOnKey(.{ .key = .key_a, .utf8 = "a" }));
    try t.expect(!cancelsOnKey(.{ .key = .key_a, .utf8 = "A", .mods = .{ .shift = true } }));
    try t.expect(!cancelsOnKey(.{ .utf8 = "文" }));
    try t.expect(!cancelsOnKey(.{ .key = .backspace }));
    try t.expect(!cancelsOnKey(.{ .key = .escape, .action = .release }));
    try t.expect(cancelsOnKey(.{ .key = .enter, .utf8 = "\r" }));
    try t.expect(cancelsOnKey(.{ .key = .arrow_down }));
    try t.expect(cancelsOnKey(.{ .key = .key_c, .mods = .{ .ctrl = true } }));
    try t.expect(cancelsForText("pasted\ncommand"));
    try t.expect(!cancelsForText("pasted draft 文"));
    var term = try fixture();
    defer term.deinit(t.allocator);
    var recovery: Self = .{};
    recovery.arm(&term, 42, 100);
    collapse(&recovery, &term);
    const request = recovery.finishFrame(&term, 120).?;
    try term.printString("draft-check");
    try t.expect(recovery.take(request, &term, 42, 130));
}

test "classic TUI recovery queues input until the full redraw and drains exactly once" {
    const t = std.testing;
    var term = try fixture();
    defer term.deinit(t.allocator);
    var recovery: Self = .{};
    recovery.arm(&term, 42, 100);
    try t.expect(recovery.bufferInput("draft-"));
    collapse(&recovery, &term);
    const request = recovery.finishFrame(&term, 110).?;
    try t.expect(recovery.take(request, &term, 42, 120));
    try t.expect(recovery.bufferInput("check"));
    // An unrelated synchronized caret/progress update is not the redraw reply.
    try t.expect(recovery.finishFrame(&term, 125) == null);
    try t.expect(recovery.flushRequest() == null);
    recovery.erasedDisplay();
    try t.expect(recovery.finishFrame(&term, 130) == null);
    try t.expectEqual(request.epoch, recovery.flushRequest().?);
    var bytes: [input_capacity]u8 = undefined;
    const count = recovery.drain(&bytes);
    try t.expectEqualStrings("draft-check", bytes[0..count]);
    try t.expectEqual(@as(usize, 0), recovery.drain(&bytes));
    recovery.cancel();
    try t.expect(!recovery.bufferInput("late"));
}

test "classic TUI recovery preserves saved bytes on cancellation timeout and overflow" {
    const t = std.testing;
    var term = try fixture();
    defer term.deinit(t.allocator);
    for (0..3) |case| {
        var recovery: Self = .{};
        term.modes.set(.cursor_visible, false);
        recovery.arm(&term, 42, 100);
        try t.expect(recovery.bufferInput("prefix"));
        switch (case) {
            0 => recovery.cancel(),
            1 => {
                _ = recovery.finishFrame(&term, 601);
            },
            2 => try t.expect(!recovery.bufferInput(&@as([input_capacity]u8, @splat('x')))),
            else => unreachable,
        }
        var bytes: [input_capacity]u8 = undefined;
        const count = recovery.drain(&bytes);
        try t.expectEqualStrings("prefix", bytes[0..count]);
    }
    term.modes.set(.cursor_visible, true); // ordinary chat Escape never gates typing
    var recovery: Self = .{};
    recovery.arm(&term, 42, 100);
    try t.expect(!recovery.bufferInput("ordinary typing"));
}

pub fn cancel(self: *Self) void {
    self.phase = .idle;
    self.active.store(false, .release);
}

/// The caller has verified the actual foreground executable, not its OSC title.
pub fn arm(self: *Self, term: *const terminal.Terminal, pid: u64, now_ms: i64) void {
    self.cancel();
    if (pid == 0 or !eligible(term) or term.modes.get(.cursor_visible) or
        term.modes.get(.synchronized_output)) return;
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
    self.flush_queued = false;
    self.phase = .armed;
    self.active.store(true, .release);
}

pub fn erasedLine(self: *Self, term: *const terminal.Terminal) void {
    if ((self.phase != .armed and self.phase != .redrawing) or !term.modes.get(.synchronized_output)) return;
    const row = term.screens.active.cursor.y;
    self.erase_min = @min(self.erase_min, row);
    self.erase_max = @max(self.erase_max, row);
}

/// Called only at ESU, never while a synchronized frame is half parsed.
pub fn finishFrame(self: *Self, term: *const terminal.Terminal, now_ms: i64) ?Request {
    if (self.phase != .armed and self.phase != .redrawing) return null;
    if (!self.valid(term, now_ms)) {
        self.phase = .flushing;
        return null;
    }
    if (self.phase == .redrawing) {
        // A normal progress/caret frame cannot acknowledge Ctrl-L. Its reply
        // clears the entire viewport before rebuilding the visible transcript.
        if (term.modes.get(.cursor_visible) and self.erase_min == 0 and self.erase_max >= self.rows - 2)
            self.phase = .flushing;
        return null;
    }
    // Background usage refreshes still have a hidden cursor. They are not
    // acknowledgement that Escape returned keyboard ownership to the chat.
    if (!term.modes.get(.cursor_visible)) return null;
    const tail = blankTail(term);
    if (self.erase_min == std.math.maxInt(CellCount) or
        self.erase_max - self.erase_min < 3 or tail < self.initial_tail + 4)
    {
        self.phase = .flushing;
        return null;
    }
    // Consume the attempt before queuing a redraw. Its response cannot recurse.
    self.phase = .requested;
    return .{ .epoch = self.epoch, .pid = self.pid };
}

/// Revalidate on the writing thread. Control input, resize, program exit, alternate
/// screen or foreground job change invalidates the queued request.
pub fn take(self: *Self, request: Request, term: *const terminal.Terminal, pid: u64, now_ms: i64) bool {
    if (self.phase != .requested or self.epoch != request.epoch) return false;
    const admitted = request.pid == self.pid and pid == self.pid and self.valid(term, now_ms);
    self.phase = if (admitted) .redrawing else .flushing;
    self.erase_min = std.math.maxInt(CellCount);
    self.erase_max = 0;
    return admitted;
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

/// Check the foreground process's own config directory, including cuse and
/// CLAUDE_CONFIG_DIR. Only those two environment fields are interpreted; the
/// temporary buffer is wiped and never logged. No credential file is opened.
/// A custom keymap could rebind Ctrl-L to
/// another action, so the conservative compatibility path opts out entirely.
/// This runs on the writing thread only after a detected contraction.
pub fn canRedrawProcess(pid: u64) bool {
    if (comptime !builtin.target.os.tag.isDarwin()) return false;
    if (!isClaudeProcess(pid)) return false;
    // macOS sys/sysctl.h: CTL_KERN / KERN_PROCARGS2. An unusually large or
    // unreadable environment fails closed, without heap allocation.
    var mib = [_]c_int{ 1, 49, @intCast(pid) };
    var args: [65_536]u8 = undefined;
    defer std.crypto.secureZero(u8, &args);
    var len: usize = args.len;
    if (sysctl(&mib, mib.len, &args, &len, null, 0) != 0 or len > args.len) return false;
    var path: [4096]u8 = undefined;
    const keymap = keymapPath(args[0..len], &path) orelse return false;
    return std.posix.errno(access(keymap, 0)) == .NOENT;
}

fn keymapPath(args: []const u8, output: []u8) ?[:0]const u8 {
    if (args.len < 4) return null;
    const argc = std.mem.readInt(i32, args[0..4], builtin.target.cpu.arch.endian());
    if (argc <= 0 or argc > 4096) return null;
    var offset: usize = 4;
    _ = cString(args, &offset) orelse return null; // executable path
    while (offset < args.len and args[offset] == 0) : (offset += 1) {}
    for (0..@intCast(argc)) |_| _ = cString(args, &offset) orelse return null;
    var home: ?[]const u8 = null;
    var config: ?[]const u8 = null;
    while (cString(args, &offset)) |entry| {
        if (entry.len == 0) break;
        if (std.mem.startsWith(u8, entry, "CLAUDE_CONFIG_DIR=")) config = entry[18..];
        if (std.mem.startsWith(u8, entry, "HOME=")) home = entry[5..];
    }
    const directory = config orelse home orelse return null;
    if (directory.len == 0 or directory[0] != '/') return null;
    if (output.len == 0) return null;
    const written = std.fmt.bufPrint(output[0 .. output.len - 1], "{s}{s}/keybindings.json", .{
        directory, if (config == null) "/.claude" else "",
    }) catch return null;
    output[written.len] = 0;
    return output[0..written.len :0];
}

fn cString(bytes: []const u8, offset: *usize) ?[]const u8 {
    if (offset.* >= bytes.len) return null;
    const end = std.mem.indexOfScalarPos(u8, bytes, offset.*, 0) orelse return null;
    const result = bytes[offset.*..end];
    offset.* = end + 1;
    return result;
}

extern "c" fn sysctl([*]c_int, c_uint, ?*anyopaque, *usize, ?*anyopaque, usize) c_int;
extern "c" fn access([*:0]const u8, c_int) c_int;

test "classic TUI recovery locates native Claude keymaps and fails closed on unknown config" {
    const t = std.testing;
    try t.expect(!canRedrawProcess(0));
    var output: [4096]u8 = undefined;
    const prefix = "\x02\x00\x00\x00/usr/bin/claude\x00\x00claude\x00--safe-mode\x00";
    try t.expectEqualStrings("/Users/test/.claude/keybindings.json", keymapPath(prefix ++ "HOME=/Users/test\x00OTHER=ignored\x00\x00", &output).?);
    try t.expectEqualStrings("/tmp/account/keybindings.json", keymapPath(prefix ++ "HOME=/Users/test\x00CLAUDE_CONFIG_DIR=/tmp/account\x00\x00", &output).?);
    try t.expect(keymapPath(prefix ++ "CLAUDE_CONFIG_DIR=relative\x00\x00", &output) == null);
    try t.expect(keymapPath(prefix ++ "CLAUDE_CONFIG_DIR=\x00\x00", &output) == null);
    try t.expect(keymapPath(prefix ++ "OTHER=ignored\x00\x00", &output) == null);
    try t.expect(keymapPath("incomplete", &output) == null);
}

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
    term.modes.set(.cursor_visible, false);
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
    term.modes.set(.cursor_visible, true);
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
    try t.expect(recovery.active.load(.acquire));
    recovery.erasedDisplay();
    try t.expect(recovery.finishFrame(&term, 124) == null);
    try t.expectEqual(request.epoch, recovery.flushRequest().?);
    try t.expect(recovery.flushRequest() == null);
    recovery.cancel();
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
    recovery.arm(&term, 42, 111);
    for (10..34) |row| {
        term.setCursorPos(@intCast(row + 1), 1);
        recovery.erasedLine(&term);
        term.eraseLine(.complete, false);
    }
    try t.expect(recovery.finishFrame(&term, 120) == null);
    recovery.arm(&term, 42, 130);
    try t.expect(!recovery.active.load(.acquire));
}
