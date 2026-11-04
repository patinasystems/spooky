//! Bounded, ordered shell state. Private OSC 133 P reports carry no cells and
//! never change semantic pins. Files remain transport/recovery, not a UI clock.
const std = @import("std");
const Command = @import("osc/parsers/semantic_prompt.zig").Command;
const Blocks = @import("CommandBlocks.zig");
const Self = @This();
pub const Kind = enum(u8) { none, ready, terminal, running, exited };
kind: Kind = .none,
generation: [65]u8 = @splat(0),
block_id: [65]u8 = @splat(0),
accepted_request: [129]u8 = @splat(0),
context_start: bool = false,
/// Explicit cursor shape requested during this foreground command.
program_cursor: bool = false,
revision: u64 = 0,

pub fn apply(self: *Self, cmd: Command, primary: bool, prompt: *const [65]u8) bool {
    if (cmd.action != .prompt_start) return false;
    const value = cmd.readOption(.spooky_state) orelse return false;
    // Consume malformed private reports without treating them as real P pins.
    const kind = std.meta.stringToEnum(Kind, value) orelse return true;
    const id = cmd.readOption(.aid) orelse return true;
    const generation = cmd.readOption(.spooky_generation) orelse return true;
    const context = cmd.readOption(.spooky_context) orelse return true;
    if (!primary or kind == .none or !Blocks.validID(id) or !Blocks.validID(generation) or
        !std.mem.eql(u8, id, std.mem.sliceTo(prompt, 0))) return true;
    // ZLE line-init may publish before its first B redisplay.
    if (kind == .ready and !std.mem.eql(u8, context, "start")) return true;
    var next: Self = .{ .kind = kind, .context_start = std.mem.eql(u8, context, "start"), .revision = self.revision };
    const request = cmd.readOption(.spooky_request) orelse "";
    if (request.len > 128) return true;
    for (request) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-') return true;
    @memcpy(next.accepted_request[0..request.len], request);
    @memcpy(next.block_id[0..id.len], id);
    @memcpy(next.generation[0..generation.len], generation);
    if (!std.meta.eql(self.*, next)) {
        next.revision +%= 1;
        self.* = next;
    }
    return true;
}

pub fn isReady(self: Self, input: *const [65]u8) bool {
    return self.kind == .ready and std.mem.eql(u8, &self.block_id, input);
}

pub fn running(self: *Self) void {
    self.program_cursor = false;
    if (self.kind == .none or self.kind == .running) return;
    self.kind = .running;
    self.revision +%= 1;
}

test "native readiness can precede B but presentation requires its matching primary input" {
    const t = std.testing;
    var prompt: [65]u8 = @splat(0);
    @memcpy(prompt[0..4], "12-1");
    var state: Self = .{};
    const cmd: Command = .{ .action = .prompt_start, .options_unvalidated = "spooky_state=ready;spooky_generation=12-2;spooky_context=start;aid=12-1" };
    try t.expect(state.apply(cmd, false, &prompt));
    try t.expectEqual(Kind.none, state.kind);
    try t.expect(state.apply(cmd, true, &prompt));
    try t.expectEqual(Kind.ready, state.kind);
    try t.expect(!state.isReady(&@as([65]u8, @splat(0))));
    try t.expect(state.apply(cmd, true, &prompt));
    try t.expectEqual(Kind.ready, state.kind);
    try t.expectEqualStrings("12-2", std.mem.sliceTo(&state.generation, 0));
    const revision = state.revision;
    _ = state.apply(cmd, true, &prompt);
    try t.expectEqual(revision, state.revision);
    state.running();
    try t.expectEqual(Kind.running, state.kind);
    try t.expect(state.revision > revision);
}

test "native readiness carries exact accepted request and rejects malformed identities" {
    const t = std.testing;
    var prompt: [65]u8 = @splat(0);
    @memcpy(prompt[0..4], "12-1");
    var state: Self = .{};
    const cmd: Command = .{ .action = .prompt_start, .options_unvalidated = "spooky_state=ready;spooky_generation=12-2;spooky_context=start;aid=12-1;spooky_request=F08C-1234" };
    try t.expect(state.apply(cmd, true, &prompt));
    try t.expectEqualStrings("F08C-1234", std.mem.sliceTo(&state.accepted_request, 0));
    const revision = state.revision;
    const malformed: Command = .{ .action = .prompt_start, .options_unvalidated = "spooky_state=ready;spooky_generation=12-3;spooky_context=start;aid=12-1;spooky_request=wrong/request" };
    try t.expect(state.apply(malformed, true, &prompt));
    try t.expectEqual(revision, state.revision);
    try t.expectEqualStrings("12-2", std.mem.sliceTo(&state.generation, 0));
    const stale: Command = .{ .action = .prompt_start, .options_unvalidated = "spooky_state=ready;spooky_generation=12-4;spooky_context=start;aid=12-0;spooky_request=F08C-1234" };
    try t.expect(state.apply(stale, true, &prompt));
    try t.expectEqual(revision, state.revision);
}
