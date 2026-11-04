# Spooky

A macOS Ghostty fork with an inline AppKit command editor and grouped
command/output history. One real Ghostty terminal grid renders the transcript;
Ghostty's Metal renderer draws block headers from core-tracked positions, and
AppKit hosts the native editor. Output is not captured through pipes or replayed
as plain text.

The editor starts at one line, grows with hard and soft wraps, and stops growing
at the smaller of 12 terminal lines or 45% of the pane. Longer drafts scroll
inside the editor. Short sessions start inline at the terminal input position.
The current header and draft dock when the prompt fills the available inline
grid. They stay fixed while browsing history and return inline at the live end
when a resize, clear, or shorter draft leaves room. Editor and block padding is
six logical points.

Type `@` at an argument boundary to open the native file picker. Up/Down select,
Tab enters a folder, Command-Up goes to its parent, and Return inserts the
selected path with shell quoting. Escape leaves the draft unchanged. The picker,
shell completions, and terminal search share AppKit popover chrome with a mostly
opaque macOS material and a Reduce Transparency fallback. Shell-specific
completion still comes from the live zsh environment.

Native input integrates with your normal local zsh startup and configuration. See the
[design and implementation notes](../../docs/native-command-input.md) for the
protocol, fidelity limits, and remaining work.

## Build and launch

Use Xcode and its Metal toolchain, Zig 0.17.x, and Nushell. The checked-out
`build.zig.zon` and `src/build/zig.zig` own the Zig requirement; see
[HACKING.md](../../HACKING.md) for other upstream dependencies.

```sh
GHOSTTY_ZIG=/path/to/zig ./prototype/native-input/build.sh
./prototype/native-input/launch.sh
```

The build helper compiles native-architecture GhosttyKit, then invokes
`macos/build.nu` with `ReleaseLocal`, the separate
[`spooky.xcconfig`](spooky.xcconfig), and an absolute output directory:

```text
macos/build-spooky/ReleaseLocal/Spooky.app
```

The app displays as **Spooky**, with bundle ID `com.patinasystems.spooky`.
It opens normally from Finder or the launcher. Native input is enabled by default;
`GHOSTTY_NATIVE_INPUT=0` disables it when launching the executable directly.
Existing Blocks and Diagnostics development apps remain separate.

The launcher uses normal user Ghostty configuration, shell selection, and window
restoration. The fork disables upstream updates so they cannot replace Spooky.
When working from Kitchen, follow its `pat run` compute-routing rules; use the
local executor when this separate checkout is only on this Mac.

Spooky defaults to the bundled **Carbonfox** theme, with a neutral `#161616`
background, and the black CRT app icon. App theme defaults load before user
configuration. Press Command-comma to open the usual Ghostty configuration,
set `theme = <name>`, and press Command-Shift-comma to reload. List bundled
themes with `ghostty +list-themes` (or the executable inside Spooky.app).
An explicit theme, color override, or empty `theme =` in user configuration
takes precedence; personal configuration files are not rewritten.

## Try it

1. Type or paste into the one-line native input. Add lines with Shift+Return and
   resize the pane to check growth on soft wraps. Option/Control+Return also add
   a newline. Pasting inserts text without executing it.
2. Drag a selection across lines, replace it, and use ordinary macOS clipboard,
   word/line selection, undo, and redo. Return submits the entire draft.
3. The accepted command appears in the terminal transcript under its block
   header, using the macOS accent color where no explicit shell color applies.
   Its output retains Ghostty's colors, cursor behavior, and selection.
   Headers show the command's original directory, optional Git branch, and
   completion metadata.
4. Scroll upward through previous commands. The current header and editor stay
   at the bottom while the transcript scrolls independently.
5. Typing shows the best zsh-backed completion as faint text together with a
   compact option list. Tab accepts the selected option immediately; Right
   accepts its inline preview. Acceptance immediately opens suggestions for the
   new cursor context, including the next directory level. Arrows navigate without animation, and typing
   filters the list with fuzzy matching. Return executes exactly the typed draft
   until you explicitly navigate/request the list, when it accepts the selection.
   Escape dismisses suggestions; Option+Tab inserts a literal tab.
6. Hover a block's directory or an existing file/path in output to highlight it.
   Click to copy the absolute path with a brief confirmation. Command-click or
   Control-click opens the directory or reveals the file in Finder; holding the
   modifier adds an underline and arrow. Dragging still selects text.
7. Up on the first visual line recalls shell history; Down on the last line
   moves forward and restores your unfinished draft. Within multiline commands,
   arrows move the caret; an open completion list keeps its arrow navigation.
   Use the terminal-input control or Escape (with no suggestions pending) for
   custom shell widgets and unsupported completion contexts. Native editing can resume
   at an empty primary prompt; clear or run any partially edited shell line.
8. Try `read answer; print -r -- "$answer"` or a terminal application. Running
   programs receive ordinary terminal input. Incomplete input such as
   `if true; then` uses the terminal continuation prompt; finish it there or
   cancel with Ctrl+C.

For a multiline example:

```sh
export PATINA_DEMO='hello from the native editor'
printf '%s\n' "$PATINA_DEMO"
cat <<'END'
Multiline input with quoted text,
emoji 👩🏽‍💻, and 日本語.
END
```

Submit `printf '%s\n' "$PATINA_DEMO"` separately afterward. The same interactive
shell retains exports and working-directory changes between commands.

## What the prototype does

- Block backgrounds, separators, and captions use Ghostty's existing Metal
  render pass and font atlas. Native editing and controls use AppKit callbacks.
  The upstream application's existing SwiftUI shell remains in place; this
  feature adds no Lookout or Observation framework dependency.
- A real `NSTextView` owns text, selection, marked input, and its own undo manager.
  Ordinary edits do not replace its text storage on every presentation update.
- The configured/default shell launches normally. For zsh, a temporary bootstrap
  restores your effective `ZDOTDIR` and loads normal startup files, including
  `.zshrc`. Personal files are not modified. PATH, aliases, history settings,
  plugins, custom completions, options, and keymaps remain available.
- Atomic request/state/receipt files transfer the draft to a dedicated ZLE key
  widget. The widget checks the prompt generation, request ID, and empty input
  buffer before invoking normal `.accept-line` in the existing shell.
- Completion uses your loaded zsh definitions in a private `zpty` worker forked from
  the current shell at each primary prompt. It inherits cwd, variables, aliases,
  and functions without sourcing a different startup configuration. The worker
  returns zsh's exact quoted buffer and cursor; AppKit applies a normal undoable
  edit only if the draft, caret, revision, and prompt are still current. See
  [native completion](../../docs/native-completion.md) for the protocol and limits.
- Drafts remain through acceptance until the terminal confirms the ownership
  handoff. Uncertain submissions are never replayed, and a recovery view retains
  the draft after an error.
- Tagged OSC 133 markers identify each primary command block. Core-tracked pins
  keep its header and input/output boundaries associated with terminal cells
  across scrolling and reflow. A continuation keeps the same block ID.
- Private per-block metadata stores the original directory and accepted input,
  optional branch, lifecycle, and exit status. Displayed elapsed time currently
  uses shell wall-clock timestamps; it is not a performance measurement.

## Limits

Blocks group a **shared, mutable terminal transcript**. They are not independent,
immutable terminal grids. Erasing or evicting terminal cells can invalidate a
block's anchors. Background output can interleave with foreground output on the
same PTY. Alternate-screen applications use the normal live terminal, rather
than a reconstructed block transcript.

Native editing and completion are supported at the empty primary prompt only.
Native Up/Down navigation recalls live shell history at the first/last visual
line and restores the unsent draft. Native completion rejects dynamic expansion
contexts such as command/process substitutions; use terminal input for those.
Completion functions can perform their ordinary I/O, but the draft is never
accepted or executed by the completion widget. Each pane has one private idle
completion worker at its primary prompt. Responses are bounded to 200 items and
8 MiB. Syntax coloring and native remote/nested-shell, fish, and Linux adapters are
not implemented. User startup/plugins load normally, but not every custom ZLE
widget or asynchronous prompt theme is compatible with native editing. Selection highlighting remains
AppKit's native text selection.

The editor accepts up to 1 MiB of UTF-8 and rejects control characters other than
tabs and newlines. It does not silently remove unsupported bytes.

Directory notifications refresh bridge state, with a two-second recovery
watchdog and explicit submission deadlines. A dedicated terminal key sequence
wakes its submit or completion widget. Generation checks prevent a stale request from executing
at a later prompt, but an unexpected foreground change between the readiness check
and that key sequence can deliver trigger bytes to the foreground program. This
controlled prototype does not establish a general-purpose ownership protocol.

Closing a pane removes its private directory and block metadata. A crash can leave
a `patina-ghostty-input-*` directory in the system temporary directory. These
files include accepted commands and are not a permanent history service.

## Verification status

As of 2026-11-02:

- All 50 PTY tests pass on system zsh 5.9. They cover exact multiline and Unicode
  transfer, retained shell state, ownership, stale/duplicate rejection, block
  markers, stable continuation IDs, completion metadata, and exit/cancellation.
  Startup fixtures exercise normal interactive/login startup order, custom
  ZDOTDIR, aliases/PATH/history, existing completions/fpath/styles, hooks,
  keymaps, options, prompt restoration, and ordinary-terminal fallback when
  required hook support is unavailable.
- All 98 selected core tests pass. Coverage includes native cursor ownership,
  command markers, caption geometry and hit bounds, header deduplication, and
  terminal padding. The native `ReleaseFast` core build completed all 243 steps.
- Native validation covers 136 cases across the combined and final targeted
  runs. The combined run passed 135 cases; after correcting the new geometry
  test's flipped-coordinate assumption, both scrollbar-track tests passed.
  Coverage includes native editing
  and IME-Return, automatic completion and keyboard acceptance, Unicode/current-token
  replacement, filesystem response observation, search, bounded directory-tree
  loading and visible filename layout, startup, handoff, stable docking, and
  fractional scrollbar synchronization, and actual track/knob geometry with an
  unchanged terminal content area. Logs are
  `/tmp/spooky-final-native-tests-footer.log` and
  `/tmp/spooky-final-scroller-track-tests.log`.
- A separate normal arm64 `ReleaseLocal` app was built at
  `macos/build-spooky/delivery/ReleaseLocal/Spooky.app` and its signature verified.
  Its executable SHA-256 is
  `7724b66d8e7d7dfa6997404ccba51f68155efd49cc254523d32701825c143f19`.
  The user's earlier running app was preserved; building this bundle did not
  replace that process.
- A live candidate rendered 1,500 Unicode lines. Repeated wheel scrolling into
  history and back kept the draft/current header fixed, with no duplicate
  caption observed. This did not qualify physical scrollbar-thumb dragging:
  automation missed the thumb, and setting its accessibility value did not
  dispatch the scroll action.
- Live checks confirmed readable tree labels, expansion, Escape dismissal,
  placement above the docked input, and Cmd+F Unicode search with the draft
  preserved. The Mac locked before the final physical thumb-drag recheck;
  the footer track correction has AppKit geometry coverage. Automated results
  do not establish end-to-end latency, physical IME support, or rendering
  parity with stock Ghostty.

### Earlier interactive observations

These checks describe preceding builds. They are retained as historical evidence,
not as a completed live qualification of the new delivery bundle.

- Computer-use stress on the first Metal candidate exercised 12,000 colored,
  wrapped Unicode output lines, 20 separate native submissions, and large
  scrollback movements with a pinned draft. Foreground changes interrupted
  sustained wheel-scroll attempts; these are not frame-time benchmarks. See
  [the measurement notes](performance.md) for the exact scope and limitations.
- An earlier Spooky build was opened normally through Finder. Its live shell
  reported login and interactive mode, configured history, and loaded user
  aliases and completions. Unique-path Tab completion, multiline submission,
  and fresh-editor focus passed. A command that erased the screen before `read`
  received terminal input and returned to native editing. Full-width separators
  were confirmed visually. The handoff tests cover when native presentation can
  be released; no high-speed frame recording was taken.
- Interactive checks pass for multiline paste and Cmd+A selection, full-buffer
  submission, a single visible command/output block, fresh-prompt recovery, and
  independent metadata on successive blocks.
- Filled-scrollback checks pass: the current header/editor stay pinned while
  browsing history, and submission returns the viewport to the live bottom.
- Foreground `read` and a controlled alternate-screen/read fixture receive
  keyboard input and restore native editing afterward. Escape/return-to-editor,
  soft-wrap/Shift+Return growth, and terminal Cmd+A output selection also pass.
- Multiple-pane checks pass: background completion preserves the other pane's
  draft focus, and Cmd+] explicitly moves focus to the native editor in the
  selected pane.
- Native shell-completion checks pass for unique paths and undo, multiple-match
  keyboard acceptance, git arguments, changed cwd, live aliases and variables,
  multiline drafts, and preserving trailing text at a middle caret. Accepting a
  menu result does not execute it; a subsequent Return submits normally.
- Copying terminal output into the native editor retains editing focus. Pointer
  ownership and background-matched appearance are covered by native tests;
  physical mouse movement still needs a manual check. The automation's
  main-window capture omits the separate completion panel, so its visual
  placement also remains a manual check.

Physical IME sessions and VoiceOver have not been qualified. The synthetic
IME-Return test checks that marked input does not also submit; it does not replace
testing a complete input-method or assistive-technology session.

Run the shell suite without building Ghostty:

```sh
uv run --no-project --python python3 test/native-input/test_zsh_bridge.py
```

Native tests live in
[`CommandTextViewTests.swift`](../../macos/Tests/Ghostty/CommandTextViewTests.swift).
Use `macos/build.nu --action test --only-testing GhosttyTests/CommandTextViewTests`
with a testable configuration, the Spooky xcconfig, an isolated build directory,
and the architecture used for GhosttyKit. `build.nu` skips UI automation tests.
Repeat the interactive checks when changing layout, focus, or terminal ownership;
physical IME/VoiceOver and broader terminal-application qualification remain
separate work.

The editor/shell diagnostic measurements are recorded in
[`performance.md`](performance.md). Instrumentation is opt-in via
`GHOSTTY_NATIVE_INPUT_DIAGNOSTICS=1` and logs aggregate counts/timings only.
The migration inventory for removing upstream SwiftUI is in
[`appkit-migration.md`](../../docs/appkit-migration.md).
