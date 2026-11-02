# Native command input and blocks

This fork adds an AppKit command editor and command/output grouping to Ghostty.
The current implementation targets a controlled local zsh on macOS. The
[prototype guide](../prototype/native-input/README.md) contains build commands,
current verification status, and operating limits.

Repository: [patinasystems/ghostty](https://github.com/patinasystems/ghostty).
The initial source inspection used upstream
[`0b1729e945978fca4bcd6165d8ac408bf675a7f2`](https://github.com/ghostty-org/ghostty/commit/0b1729e945978fca4bcd6165d8ac408bf675a7f2).
The fork now extends both the native app and terminal core.

## Editing and placement

A real `NSTextView` owns the unsubmitted text, selection, undo, and IME
composition. Click/drag selection, multiline replacement, macOS word/line
selection, and clipboard operations are native text operations. Return submits;
Shift/Option/Control+Return inserts a newline. Confirming an IME candidate must
not also submit. Paste inserts plain text without execution. Smart quotes,
smart dashes, and automatic substitutions are disabled.

The composer starts at one terminal line and grows with hard and soft wraps.
It is capped at the smaller of 12 terminal lines or 45% of the pane; larger drafts
scroll within the editor. At the live prompt it aligns with the terminal's input
position. While the user browses previous output, the current command header and
composer remain pinned to the bottom. Layout reserves space so the growing draft
does not cover terminal output.

The new editor, header views, and layout use AppKit and explicit callbacks.
Ghostty's upstream SwiftUI application shell is retained. This feature does not
introduce Lookout or Observation frameworks. TextKit owns ordinary edits; host
updates only replace text for an actual external change, such as acceptance or
recovery, so presentation updates do not destroy selection and undo.

Selection highlighting and shell syntax coloring are separate capabilities.
Native selection and a zsh-backed AppKit completion menu are implemented;
syntax coloring remains future work. Warp's [editor documentation](https://docs.warp.dev/terminal/editor/)
is the behavior reference, not a dependency on Warp's application stack.

## One terminal transcript, grouped into blocks

Each primary prompt has a stable block ID. The shell reserves one blank terminal
row for its AppKit header, then marks the input position. ZLE renders the accepted
command through its normal display/acceptance path. The native editor does not
print a second command copy.

Command output stays in the same Ghostty terminal model and PTY. ANSI styles,
hyperlinks, cursor movement, scrollback, and selection remain terminal behavior.
There is no stdout pipe, second text renderer, screenshot reconstruction, or
plaintext replay. Headers show metadata from the command's original context,
rather than reusing the current directory for older commands.

The core tracks tagged OSC 133 boundaries with pins that follow terminal cells.
The embedded API exposes their geometry, terminal cell size, cursor position,
primary-screen state, and whether the viewport is at the live bottom. The native
host uses those values for block chrome and editor positioning.

These are groups within a **shared, mutable grid**, not immutable terminal
instances per command. Erase/reset and scrollback eviction can invalidate
anchors. Background writers share the PTY and can interleave with a foreground
command. Alternate-screen applications retain the normal full terminal path.
Do not infer exact per-process output ownership from a block boundary.

## Source ownership

| Component | Responsibility |
| --- | --- |
| [`CommandTextView.swift`](../macos/Sources/Features/Command%20Input/CommandTextView.swift) | Native editing, submit/newline/IME handling, independent undo, and text measurement. |
| [`CommandInputView.swift`](../macos/Sources/Features/Command%20Input/CommandInputView.swift) | AppKit editor/scroll-view ownership and explicit callbacks. |
| [`NativeCommandSurfaceHost.swift`](../macos/Sources/Features/Command%20Input/NativeCommandSurfaceHost.swift) | AppKit block/header presentation and inline or pinned editor placement. |
| [`CommandBlockLayout.swift`](../macos/Sources/Features/Command%20Input/CommandBlockLayout.swift) | Snapshot of core geometry and immutable block metadata. |
| [`CommandInputSession.swift`](../macos/Sources/Features/Command%20Input/CommandInputSession.swift) | Per-pane draft, acknowledgement, focus, recovery, and off-main bridge I/O. |
| [`native-input.zsh`](../macos/Sources/Features/Command%20Input/native-input.zsh) | Isolated shell bootstrap, ZLE submission, block markers, and metadata publication. |
| [`CommandBlocks.zig`](../src/terminal/CommandBlocks.zig) | ID-associated tracked pins and block lifetime within the terminal screen. |
| [`embedded.zig`](../src/apprt/embedded.zig), [`ghostty.h`](../include/ghostty.h) | `ghostty_surface_command_layout` geometry boundary between core and host. |

AppKit and session presentation state remain on `MainActor`. Recurring file I/O
runs in a separate actor. Immutable snapshots cross that boundary; the transport
never shares live `NSTextStorage` with a worker.

## Submission and ownership

Each pane creates a private temporary directory and launches `/bin/zsh
--no-globalrcs -i` with its own `ZDOTDIR`. The starter shell does not source the
user's `.zshrc`. The Blocks launcher disables upstream automatic shell integration
so there is one owner of the block markers. The adapter removes its bootstrap
environment variable before commands or nested shells can inherit it.

The app atomically publishes a request containing:

```text
<prompt generation> LF
<request UUID> LF
<raw UTF-8 draft>
```

It then sends only `ESC [ 99 ; 1 ~` through Ghostty to invoke a dedicated ZLE key
widget. The widget consumes the file once, validates the live generation,
primary context, request ID, and empty shell buffer, assigns `BUFFER`/`CURSOR`,
publishes an acceptance receipt, and invokes normal `.accept-line`. Commands are
not split into lines, wrapped in `eval`, or run in a new `zsh -c` process.

The same interactive shell retains working-directory changes, exports,
functions, and job control. Running programs and terminal editing use Ghostty's
ordinary keyboard path. Native input is available only at an empty primary
prompt. Incomplete syntax yields to a terminal continuation; its block ID remains
stable while each new ZLE invocation advances the validation generation.

Acceptance means the shell owns the draft, not that it has executed successfully.
The app retains the draft until that receipt, prevents duplicate submission, and
does not replay an unknown outcome. A ready state from the accepted generation
cannot re-enable editing. Recovery remains copyable after a failure or shell
exit. Unfocused panes must not claim first responder when a new prompt arrives.

The state record has four tab-separated fields:

```text
<kind> TAB <generation> TAB <context> TAB <block ID>
```

Kinds include `ready`, `terminal`, `running`, and `exited`. Readiness comes from
the private adapter state; arbitrary printed OSC markers do not authorize input.
The receipt retains the request UUID and either acceptance or a rejection reason.

## Block lifecycle and metadata

Block IDs are numeric PID/counter pairs. A new primary prompt allocates a new ID;
continuation prompts retain it. The protocol emits:

| Marker | Meaning |
| --- | --- |
| `OSC 133;A;aid=<id>` | Start of the reserved header row, followed by one newline. |
| `OSC 133;B;aid=<id>` | Input position, also emitted on ZLE redisplay. Repeated B markers do not create new blocks. |
| `OSC 133;C;aid=<id>` | `preexec` has started command execution. |
| `OSC 133;D;<status>;aid=<id>` | Completion, emitted before the next primary block or during normal shell exit. |

Metadata under `blocks/<id>/` is published with same-directory atomic renames:

| File | Contents |
| --- | --- |
| `cwd` | Raw working-directory path captured when the primary prompt is created. |
| `branch` | Optional Git branch captured once for that context. |
| `input` | Exact first accepted buffer, without added or stripped newlines. |
| `executed-input` | Optional full typed command reported by `preexec`, including terminal-entered continuation text. |
| `status` | `editing`, `accepted`, `running`, or `completed`. |
| `exit-status` | Foreground shell status, captured before any completion-hook work. |
| `started-wall`, `finished-wall` | Shell wall-clock timestamps used for a display interval, not a benchmark. |

Completion publishes `exit-status` and `finished-wall` before `status=completed`,
so the host can cache finished metadata. Files carry context and lifecycle;
markers parsed in the PTY stream establish ordering relative to terminal output.
Polling files alone would not provide reliable output boundaries.

An empty command, syntax error, or cancelled continuation can finish without
`preexec`, so D can occur without C. Normal `exit` finalizes its block; shell
replacement through `exec` may not run an exit hook. Child-exit handling and
terminal fallback remain necessary. Original submitted text and executed text
are deliberately separate when continuation or shell expansion changes them.

## Limits and next work

Native Tab completion now uses a private zsh worker forked from the live shell
at each primary prompt. The worker preserves shell context and produces exact
quoted buffer/cursor edits; AppKit checks the draft revision and caret before
applying them. It keeps temporary ZLE display out of the visible transcript.
See [native completion](native-completion.md) for supported contexts and bounds.
History navigation still uses terminal input. Reading a history file or asking
a fresh background shell does not reproduce the live shell's state. User prompt plugins,
arbitrary ZLE widgets, SSH/tmux/nested sessions, Fish/Bash, and Linux each require
separate adapters and qualification.

The file bridge uses directory notifications plus a two-second recovery
watchdog and caps drafts at 1 MiB. It rejects
NUL and unsupported control characters rather than silently changing them.
There remains a readiness-to-trigger race: a foreground change can cause the
widget key sequence to reach a program. Generation validation rejects the stale
request when ZLE resumes, but does not make delivery of those trigger bytes
atomic with ownership. A production transport needs stronger synchronization.

A disposable investigation found that `zle -F -w` can modify `BUFFER`, but calling
`accept-line` from that FD callback did not wake macOS zsh 5.9 without PTY input.
The normal key-widget implementation is tested; a side-channel-only production
replacement is still a proposal. The
[Zsh line-editor documentation](https://zsh.sourceforge.io/Doc/Release/Zsh-Line-Editor.html)
and [hook documentation](https://zsh.sourceforge.io/Doc/Release/Functions.html#Hook-Functions)
define the underlying shell primitives.

The separate **Ghostty Patina Blocks** app uses
`com.patinasystems.ghostty.blocks` and `macos/build-blocks/`. It preserves the
original `macos/build/` prototype. The native arm64 build, strict/deep signature
verification, 30 AppKit editor tests, ten bridge/watch tests, and interactive block/editing/focus checks have
passed. See the prototype guide for the exact build, launch flags, test coverage,
and remaining physical IME/VoiceOver qualification.
