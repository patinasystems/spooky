# Native command input and blocks

This fork adds an AppKit command editor and command/output grouping to Ghostty.
The native editor integrates with the user’s normal local zsh on macOS. The
[prototype guide](../prototype/native-input/README.md) contains build commands,
current verification status, and operating limits.

Repository: [patinasystems/spooky](https://github.com/patinasystems/spooky).
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
scroll within the editor. Short sessions align it with the terminal's input
position. When the live prompt fills the prospective inline grid, the current header and
composer dock at the bottom. The calculation excludes the dock's own reservation
and uses applied terminal dimensions; retained rows created by resizing are not
enough to force docking. Docking stays stable while browsing scrollback, then
returns inline at the live end when a settled resize, clear, or shorter draft
leaves room. Layout reserves
space so the growing draft does not cover terminal output. The native scrollbar
track ends above the docked header/editor through scroller insets; its thumb
cannot slide behind the editor. Those track insets do not resize the drawable,
clip view, or PTY.

The native editor, controls, and layout use AppKit and explicit callbacks.
Ghostty's upstream SwiftUI application shell is retained. This feature does not
introduce Lookout or Observation frameworks. TextKit owns ordinary edits; host
updates only replace text for an actual external change, such as acceptance or
recovery, so presentation updates do not destroy selection and undo.

Block backgrounds, separators, and metadata captions use Ghostty's existing
Metal text pipeline and font atlas, in the same render pass as the transcript.
There is no AppKit header painting or second Metal layer. The renderer captures
header pins with terminal cells under the same lock, then shapes caption text
outside the lock. Captions are cached by block ID; metadata changes request a
normal renderer update. Full-width chrome sits below the native scrollbar.

The Metal drawable stays full size. An explicit bottom inset reserves grid space
for a growing or pinned editor, with pinned block chrome drawn inside that
padding. The editor and interactive controls remain AppKit objects so native
text input, selection, undo, IME, menus, and accessibility retain their platform
behavior. These changes do not remove the upstream SwiftUI application shell.

Native command panes add six logical points of left/right padding to terminal
geometry and six-point bottom padding. New prompts and the dock reserve two
terminal rows for the header, providing six logical points above and below the
caption at normal font sizes. The separator occupies the preceding block's
bottom margin; terminal-row rounding stays in that margin. Older one-row
scrollback retains its actual geometry instead of overlapping command text.
The separator and caption also use the six-point horizontal inset. Output text keeps its
normal cell size and selection coordinates.
The multiline editor has six-point padding on every side. Its blank top inset
overlaps the header's blank bottom inset, so the visible path-to-input gap is
six points, rather than the sum of two insets. Completion and
terminal search share an AppKit overlay style, and Cmd+F routes from the editor
to the existing terminal search engine. Clicking the printed directory copies
its full absolute path; Command-click or Control-click opens it in Finder.
The click region comes from the renderer's caption geometry; branch/status text
is not a directory target. Directory clicks do not enumerate files or open a popover.

Headers and existing local filenames/paths in command output share one hover
interaction. Hover adds a highlight; holding Command or Control adds an underline
and a right arrow where a free neighboring cell permits it. A completed click
copies the absolute path and briefly shows “Copied to clipboard” above the
target. A modifier-click opens directories or reveals files in Finder. Dragging
still selects terminal text; Shift/Option clicks retain ordinary selection.
An initial click does not require prior hover: its bounded hit is validated
asynchronously, then activated on release. Failed validation or a 250 ms
fail-open deadline replays the original press/release to terminal selection;
dragging forwards immediately. Repeated clicks preserve word/line selection.

The core maps a bounded visible logical line to UTF-8 bytes and terminal cells.
The AppKit controller resolves literal candidates on a filesystem actor, with a
small expiring positive/negative cache. Relative names use the originating
command's directory, not the latest prompt. Quoted/escaped names, spaces,
Unicode, diagnostic line/column suffixes, and local file OSC8 links are handled
without evaluating strings as shell code. Unvalidated words keep their normal
terminal behavior. Context is bounded to 4,096 UTF-8 bytes and eight visible
wrapped rows; clipped or larger tokens are left alone. Alternate screens and
applications with mouse reporting retain their own interactions.
Historic directory ownership also has a 256-page-link lookup budget. If that
cannot establish the originating command, absolute paths still work and relative
names keep ordinary terminal behavior rather than guessing a directory.

Highlight, underline, and arrow cells use the existing Metal text/chrome buffer
and font atlas. No filesystem access occurs under the terminal lock or in the
renderer. Only the current hit is revalidated against output/viewport changes;
there is no per-frame history scan. The copy tooltip uses the same nonactivating
AppKit material and overlay layer as completion, without taking editor focus.

Selection highlighting and shell syntax coloring are separate capabilities.
Native selection and a zsh-backed AppKit completion menu are implemented;
syntax coloring remains future work. Warp's [editor documentation](https://docs.warp.dev/terminal/editor/)
is the behavior reference, not a dependency on Warp's application stack.

## One terminal transcript, grouped into blocks

Each primary prompt has a stable block ID. The shell reserves two blank terminal
rows for its GPU-rendered header, then marks the input position. A docked current
header replaces its in-grid caption instead of drawing a second copy.
ZLE renders the accepted
command through its normal display/acceptance path. The native editor does not
print a second command copy.

Shell acceptance and visual replacement are separate boundaries. A parsed C
immediately gives keyboard ownership to the terminal. For a nonempty submitted
draft up to 16 KiB, one reused, noninteractive native text view can retain its
old appearance until a frame carrying the same C ID is assigned to the Metal
layer. Immutable IDs and serials travel with the encoded frame; older queued
frames cannot acknowledge a newer command. Clearing the retained text happens
in the layer-assignment transaction, without waiting for the GPU on the UI
thread. The existing geometry observer enforces a 100 ms fail-open ceiling;
resize, focus/Space changes, alternate screens, and explicit terminal mode also
cancel it. Larger drafts skip the copy to avoid a second large TextKit layout.
The next prompt uses the real editor independently while this brief visual
handoff finishes. The terminal transcript still contains only the shell echo.

Command output stays in the same Ghostty terminal model and PTY. ANSI styles,
hyperlinks, cursor movement, scrollback, and selection remain terminal behavior.
Submitted command text uses the macOS accent color when its terminal foreground
is otherwise the default. Explicit shell colors, inverse text, selection, and
search highlighting retain precedence; output stays unchanged. AppKit resolves
the accent on appearance/system-color changes, then the ordinary renderer text
pass consumes cached RGB bytes. The current unsubmitted shell draft is excluded
using viewport-bounded input-marker checks. No command-history scan, new glyph
atlas, or additional GPU pass is introduced for tinting.
There is no stdout pipe, second text renderer, screenshot reconstruction, or
plaintext replay. Headers show metadata from the command's original context,
rather than reusing the current directory for older commands.

Completion and history use the typed `ghostty_surface_native_input_request`
transport. It writes only a fixed shell-widget trigger, preserving the transcript
viewport and selection; ordinary Ghostty text actions retain their usual scroll
behavior. Submission explicitly returns to the live prompt before dispatch.

Native geometry refreshes immediately on prompt boundaries, scrollbar updates,
font/cell changes, and host resize/scale/visibility events. Busy or unapplied
resize snapshots receive a bounded asynchronous retry. A 250 ms visible recovery
check handles missed events (2 seconds while inactive); it is not a display clock.
A newly retained submission echo wakes its existing 100 ms deadline immediately.

The core tracks tagged OSC 133 boundaries with pins that follow terminal cells.
The embedded API exposes their geometry, terminal cell size, cursor position,
primary-screen state, actual scrollback presence, and whether the viewport is at the live bottom. The native
host uses those values for editor positioning and cold metadata lookup. Header
positions come directly from the renderer's frame snapshot.

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
| [`CommandCompletionController.swift`](../macos/Sources/Features/Command%20Input/CommandCompletionController.swift) | Debounced predictions, cached filtering, keyboard acceptance, and inline/list lifetime. |
| [`CommandHistoryController.swift`](../macos/Sources/Features/Command%20Input/CommandHistoryController.swift) | Native Up/Down recall, visual-line boundaries, draft restoration, and stale-response rejection. |
| [`CommandHistoryBridge.swift`](../macos/Sources/Features/Command%20Input/CommandHistoryBridge.swift) | On-demand live-shell history snapshot transport with bounded off-main reads. |
| [`CommandInputDocking.swift`](../macos/Sources/Features/Command%20Input/CommandInputDocking.swift) | Stable per-pane inline-to-docked placement and reserved height. |
| [`NativeCommandSurfaceHost.swift`](../macos/Sources/Features/Command%20Input/NativeCommandSurfaceHost.swift) | Inline or pinned native editor placement, cursor ownership, and bottom inset. |
| [`CommandBlockLayout.swift`](../macos/Sources/Features/Command%20Input/CommandBlockLayout.swift) | Snapshot of core geometry and immutable block metadata. |
| [`CommandInputSession.swift`](../macos/Sources/Features/Command%20Input/CommandInputSession.swift) | Per-pane draft, acknowledgement, focus, recovery, and off-main bridge I/O. |
| [`CommandShellStartup.swift`](../macos/Sources/Features/Command%20Input/CommandShellStartup.swift), [`native-input-startup.zsh`](../macos/Sources/Features/Command%20Input/native-input-startup.zsh) | Private bootstrap resources, normal user startup, and deferred attachment. |
| [`native-input.zsh`](../macos/Sources/Features/Command%20Input/native-input.zsh) | ZLE submission, block markers, completion, and metadata publication after normal user startup. |
| [`CommandBlocks.zig`](../src/terminal/CommandBlocks.zig) | ID-associated tracked pins and block lifetime within the terminal screen. |
| [`CommandChrome.zig`](../src/renderer/CommandChrome.zig), [`generic.zig`](../src/renderer/generic.zig) | Bounded caption cache, frame-aligned header positions, atlas glyphs, and same-pass chrome drawing. |
| [`embedded.zig`](../src/apprt/embedded.zig), [`ghostty.h`](../include/ghostty.h) | `ghostty_surface_command_layout` geometry boundary between core and host. |

AppKit and session presentation state remain on `MainActor`. Recurring file I/O
runs in a separate actor. Immutable snapshots cross that boundary; the transport
never shares live `NSTextStorage` with a worker.

## Submission and ownership

Ghostty’s core selects the configured command or default shell, including its
normal login-shell behavior. For interactive zsh, the core saves the effective
`ZDOTDIR` after environment overrides and temporarily redirects it to a private
pane directory. The generated `.zshenv` immediately restores the original value,
sources the real user `.zshenv`, and lets zsh load global/user `.zprofile`,
`.zshrc`, and `.zlogin` normally. Native integration attaches at the first prompt.
User files are never rewritten, and private injection variables are consumed
before nested shells can inherit them. Other shells and explicit scripts or
commands retain the normal terminal path.

The adapter preserves PATH, aliases, functions, history configuration, completion
search paths/definitions, options, and the main keymap. It chains existing ZLE
hooks. Spooky’s block header owns the visible primary prompt; theme hooks still
run and see their own saved prompt values. Arbitrary asynchronous prompt rewrites
and widgets requiring direct ZLE editing need separate compatibility work.

The native adapter also restores the upstream cwd/title announcements that the
private startup path bypasses. OSC 7 reports the logical working directory at
each prompt and through a chained `chpwd` hook, including `cd` inside a running
command. Prompt reporting restores the shell directory after a foreground
program publishes its own cwd. OSC 2 uses upstream-style directory/command
titles only when `GHOSTTY_SHELL_FEATURES` includes `title` (the core derives this
from `shell-integration-features`). These announcements strip control bytes and
print path backslashes literally, as upstream does. Block metadata retains the
original raw cwd. The adapter remains the sole owner of its OSC 133 markers;
it does not load a second copy of upstream prompt integration. Completion
workers retain user directory hooks but omit the adapter's terminal cwd hook,
so a completion function's private `cd` cannot change the real pane's cwd.

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
The app retains the draft through that receipt and keeps its native presentation
until the terminal has parsed this command’s output boundary, entered a
continuation, or reached the next prompt. The viewport expands behind the draft,
preventing the terminal block cursor from flashing before the command arrives.
Native ownership also explicitly suppresses Ghostty's rendered caret, including
the hollow unfocused cursor and custom-shader cursor visibility. This is a
presentation override, not a change to terminal DECTCEM. Tagged completion and
primary-prompt markers suppress the caret before the GUI receives its readiness
notification, including time spent in the next prompt's hooks. Execution and
secondary-prompt markers restore normal cursor policy. Secondary editors leave
this automatic policy armed, so coalesced filesystem events cannot miss the
transition back to native input. Explicit terminal input remains a persistent
override. The parsed boundary survives erased or evicted display anchors. Duplicate
submissions are prevented, and an unknown outcome is never replayed. A ready state from the accepted generation
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
| `OSC 133;A;aid=<id>` | Start of the reserved header band, followed by two newlines. |
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
Native Up/Down history reads the running zsh's in-memory history, including any
previous-session entries loaded by the user's configuration. On the first Up at
the first visual line, a generation-bound `history-request` asks a dedicated ZLE
widget for an atomic snapshot in `histories/<UUID>`. The shell's actual input
buffer and history position stay unchanged. Exact multiline/Unicode commands
are NUL-delimited in `items-v1`; snapshots inspect at most 1,000 recent events
and contain at most 1 MiB. Unsupported control characters are omitted.
Subsequent arrows browse that snapshot locally. Down at the newest entry
restores the unfinished draft and caret. Arrows inside multiline text retain
native movement, and visible completion lists retain their arrow navigation.
Editing, prompt changes, and cancelled pending requests cannot admit stale
history results. This adds no history scan or history-file I/O to submission or
prompt startup; the app never parses the user's `HISTFILE`.

User prompt plugins,
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

The application is **Spooky**, bundle ID `com.patinasystems.spooky`, built as
`macos/build-spooky/ReleaseLocal/Spooky.app`. Native input is enabled by default;
`GHOSTTY_NATIVE_INPUT=0` opts into ordinary terminal editing. The launcher opens
the app normally and does not disable user configuration or window restoration.
Upstream automatic updates are disabled for the fork. Existing Blocks and
Diagnostics development bundles remain separate. See the guide for current
verification and remaining physical IME/VoiceOver qualification.

## Native filename picker

A typed `@` at a shell argument boundary opens the existing completion list in
file-picker mode. It starts with the current directory's children; a filename
query searches the fsearch index, while explicit paths and keyboard navigation
browse a directory. Tab enters a selected directory, Command-Up moves to its
parent, and Return inserts a file or directory. Left/Right retain native caret
movement. Escape cancels without changing the draft. Acceptance replaces only
the active `@query`, quotes shell metacharacters, and is one undo step.

`CommandFileSearchSession` owns query generations and navigation. Its injected
provider calls `CommandFileSearchService`, an actor with bounded requests to one
app-owned JSON-lines helper, started in the background at application launch.
Latest-query cancellation and generation
checks reject stale results; directory listings do not wait for the global
index. Zsh still provides semantic command, option, and argument completions.

The helper links fsearch v0.2.1 at revision
`88e63fdf850cf7749deae8198b187accd21f8ba5`. A checked patch adds a names-only engine
and literal filename queries. The integration does not enable fsearch's query
language, content indexing, socket daemon, login item, or keep-warm spin loop.
It uses Spooky's own index under `~/Library/Application Support/Spooky/` and
exits with the app. Protected directories remain subject to macOS permissions.
While the initial index is unfinished, the picker shows “Initial search index
is being created…” even for the first empty `@`. It keeps the query and updates
automatically when the index becomes ready. Immediate directory browsing remains
available during the crawl. Readiness requests are independent of searches and
cannot cancel them.

`CommandOverlaySurface` supplies the shared AppKit material, tint, border and
shadow for completion, file picking, and terminal search. Reduce Transparency
uses an opaque fill. Navigation and layout changes do not animate. These small
controls remain separate from Ghostty's existing Metal terminal render pass.

The caption remains one line at 87.5% of the terminal font size inside the
two-row header band. At unusually small terminal fonts, insets adapt to the
available space rather than shrinking the caption to unreadable text. Path hit
bounds and the pinned footer use the same layout as the visible glyphs.
