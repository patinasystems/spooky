const std = @import("std");
const terminal = @import("../terminal/main.zig");

/// Available cursor styles for drawing that renderers must support.
/// This is a superset of terminal cursor styles since the renderer supports
/// some additional cursor states such as the hollow block.
pub const Style = enum {
    // Typical cursor input styles
    block,
    block_hollow,
    bar,
    underline,

    // Special cursor styles
    lock,

    /// Create a cursor style from the terminal style request.
    pub fn fromTerminal(term: terminal.CursorStyle) Style {
        return switch (term) {
            .bar => .bar,
            .block => .block,
            .block_hollow => .block_hollow,
            .underline => .underline,
        };
    }
};

/// Shared native cursor policy. Shell output has no timed cursor release.
/// Actual terminal typing uses a bar; explicit foreground requests and the
/// alternate screen retain the application's terminal cursor semantics.
pub fn nativePolicy(opts: struct {
    enabled: bool,
    terminal_requested: bool,
    primary: bool,
    prompt: bool,
    suppressed: bool,
    transferring: bool,
    program_requested: bool,
}) struct { suppressed: bool, default_bar: bool } {
    if (!opts.primary or !opts.enabled or opts.terminal_requested)
        return .{ .suppressed = false, .default_bar = false };
    if (opts.prompt) return .{ .suppressed = true, .default_bar = true };
    if (opts.program_requested and !opts.transferring)
        return .{ .suppressed = false, .default_bar = false };
    return .{ .suppressed = opts.suppressed, .default_bar = true };
}

pub const StyleOptions = struct {
    preedit: bool = false,
    focused: bool = false,
    blink_visible: bool = false,
    native_input_suppressed: bool = false,
    native_input_default_bar: bool = false,
};

/// Returns the cursor style to use for the current render state or null
/// if a cursor should not be rendered at all.
pub fn style(
    state: *const terminal.RenderState,
    opts: StyleOptions,
) ?Style {
    // Note the order of conditionals below is important. It represents
    // a priority system of how we determine what state overrides cursor
    // visibility and style.

    // The native command editor owns the caret while its input is visible.
    // This is presentation state, independent of terminal cursor modes, and
    // takes priority even over the preedit and password-input indicators.
    if (opts.native_input_suppressed) return null;

    // The cursor must be visible in the viewport to be rendered.
    if (state.cursor.viewport == null) return null;

    // If we are in preedit, then we always show the block cursor. We do
    // this even if the cursor is explicitly not visible because it shows
    // an important editing state to the user.
    if (opts.preedit) return if (opts.native_input_default_bar) .bar else .block;

    // If we're at a password input its always a lock.
    if (state.cursor.password_input) return .lock;

    // If the cursor is explicitly not visible by terminal mode, we don't render.
    if (!state.cursor.visible) return null;

    // If we're not focused, our cursor is always visible so that
    // we can show the hollow box.
    if (!opts.focused) return if (opts.native_input_default_bar) .bar else .block_hollow;

    // If the cursor is blinking and our blink state is not visible,
    // then we don't show the cursor.
    if (state.cursor.blinking and !opts.blink_visible) return null;

    // Otherwise, we use whatever style the terminal wants.
    return if (opts.native_input_default_bar) .bar else .fromTerminal(state.cursor.visual_style);
}

test "cursor: native input suppression overrides all visual states" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term: terminal.Terminal = try .init(testing.io, alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);
    term.modes.set(.cursor_visible, true);
    term.modes.set(.cursor_blinking, true);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    for ([_]bool{ false, true }) |password_input| {
        term.flags.password_input = password_input;
        try state.update(alloc, &term);
        for ([_]bool{ false, true }) |preedit| {
            for ([_]bool{ false, true }) |focused| {
                for ([_]bool{ false, true }) |blink_visible| {
                    try testing.expect(style(&state, .{
                        .preedit = preedit,
                        .focused = focused,
                        .blink_visible = blink_visible,
                        .native_input_suppressed = true,
                    }) == null);
                }
            }
        }
    }
}

test "cursor: releasing native suppression preserves terminal cursor modes" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term: terminal.Terminal = try .init(testing.io, alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);
    term.screens.active.cursor.cursor_style = .bar;
    term.modes.set(.cursor_visible, true);
    term.modes.set(.cursor_blinking, true);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);
    const suppressed: StyleOptions = .{
        .focused = true,
        .blink_visible = true,
        .native_input_suppressed = true,
    };
    const released: StyleOptions = .{ .focused = true, .blink_visible = true };
    try testing.expect(style(&state, released) == .bar);
    try testing.expect(style(&state, suppressed) == null);
    try testing.expect(term.modes.get(.cursor_visible));
    try testing.expect(term.modes.get(.cursor_blinking));
    try testing.expect(state.cursor.visible);
    try testing.expect(style(&state, released) == .bar);
    try testing.expect(style(&state, .{ .focused = false }) == .block_hollow);

    // An application that hid its own cursor must keep it hidden when native
    // presentation releases ownership. Suppression never rewrites DECTCEM.
    term.modes.set(.cursor_visible, false);
    try state.update(alloc, &term);
    try testing.expect(style(&state, suppressed) == null);
    try testing.expect(style(&state, released) == null);
    try testing.expect(!term.modes.get(.cursor_visible));
}

test "cursor: default uses configured style" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var term: terminal.Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    term.screens.active.cursor.cursor_style = .bar;
    term.modes.set(.cursor_blinking, true);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    try testing.expect(style(&state, .{ .preedit = false, .focused = true, .blink_visible = true }) == .bar);
    try testing.expect(style(&state, .{ .preedit = false, .focused = false, .blink_visible = true }) == .block_hollow);
    try testing.expect(style(&state, .{ .preedit = false, .focused = false, .blink_visible = false }) == .block_hollow);
    try testing.expect(style(&state, .{ .preedit = false, .focused = true, .blink_visible = false }) == null);
}

test "cursor: blinking disabled" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var term = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    term.screens.active.cursor.cursor_style = .bar;
    term.modes.set(.cursor_blinking, false);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    try testing.expect(style(&state, .{ .focused = true, .blink_visible = true }) == .bar);
    try testing.expect(style(&state, .{ .focused = true, .blink_visible = false }) == .bar);
    try testing.expect(style(&state, .{ .focused = false, .blink_visible = true }) == .block_hollow);
    try testing.expect(style(&state, .{ .focused = false, .blink_visible = false }) == .block_hollow);
}

test "cursor: explicitly not visible" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var term = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    term.screens.active.cursor.cursor_style = .bar;
    term.modes.set(.cursor_visible, false);
    term.modes.set(.cursor_blinking, false);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    try testing.expect(style(&state, .{ .focused = true, .blink_visible = true }) == null);
    try testing.expect(style(&state, .{ .focused = true, .blink_visible = false }) == null);
    try testing.expect(style(&state, .{ .focused = false, .blink_visible = true }) == null);
    try testing.expect(style(&state, .{ .focused = false, .blink_visible = false }) == null);
}

test "cursor: always block with preedit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var term = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    // In any bool state
    try testing.expect(style(&state, .{ .preedit = true, .focused = false, .blink_visible = false }) == .block);
    try testing.expect(style(&state, .{ .preedit = true, .focused = true, .blink_visible = false }) == .block);
    try testing.expect(style(&state, .{ .preedit = true, .focused = true, .blink_visible = true }) == .block);
    try testing.expect(style(&state, .{ .preedit = true, .focused = false, .blink_visible = true }) == .block);

    // If we're scrolled though, then we don't show the cursor.
    for (0..100) |_| try term.index();
    term.scrollViewport(.{ .top = {} });
    try state.update(alloc, &term);

    // In any bool state
    try testing.expect(style(&state, .{ .preedit = true, .focused = false, .blink_visible = false }) == null);
    try testing.expect(style(&state, .{ .preedit = true, .focused = true, .blink_visible = false }) == null);
    try testing.expect(style(&state, .{ .preedit = true, .focused = true, .blink_visible = true }) == null);
    try testing.expect(style(&state, .{ .preedit = true, .focused = false, .blink_visible = true }) == null);
}

test "native cursor policy never releases the shell block cursor on elapsed time" {
    const t = std.testing;
    const hidden = nativePolicy(.{ .enabled = true, .terminal_requested = false, .primary = true, .prompt = false, .suppressed = true, .transferring = false, .program_requested = false });
    try t.expect(hidden.suppressed and hidden.default_bar);
    const typing = nativePolicy(.{ .enabled = true, .terminal_requested = false, .primary = true, .prompt = false, .suppressed = false, .transferring = false, .program_requested = false });
    try t.expect(!typing.suppressed and typing.default_bar);
    const program = nativePolicy(.{ .enabled = true, .terminal_requested = false, .primary = true, .prompt = false, .suppressed = true, .transferring = false, .program_requested = true });
    try t.expect(!program.suppressed and !program.default_bar);
    const prompt = nativePolicy(.{ .enabled = true, .terminal_requested = false, .primary = true, .prompt = true, .suppressed = false, .transferring = false, .program_requested = true });
    try t.expect(prompt.suppressed);
    const alternate = nativePolicy(.{ .enabled = true, .terminal_requested = false, .primary = false, .prompt = false, .suppressed = true, .transferring = false, .program_requested = false });
    try t.expect(!alternate.suppressed and !alternate.default_bar);
    const raw = nativePolicy(.{ .enabled = true, .terminal_requested = true, .primary = true, .prompt = true, .suppressed = true, .transferring = true, .program_requested = false });
    try t.expect(!raw.suppressed and !raw.default_bar);
}

test "native default cursor stays a text bar for unfocused and preedit states" {
    const alloc = std.testing.allocator;
    var term: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    term.modes.set(.cursor_visible, true);
    try state.update(alloc, &term);
    for ([_]bool{ false, true }) |focused| {
        for ([_]bool{ false, true }) |preedit| {
            try std.testing.expectEqual(Style.bar, style(&state, .{
                .focused = focused,
                .preedit = preedit,
                .blink_visible = true,
                .native_input_default_bar = true,
            }).?);
        }
    }
    term.modes.set(.cursor_visible, false);
    try state.update(alloc, &term);
    try std.testing.expect(style(&state, .{ .focused = true, .native_input_default_bar = true }) == null);
}
