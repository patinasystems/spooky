# Ghostty Patina Blocks

An opt-in macOS Ghostty fork with an inline AppKit command editor and grouped
command/output history. One real Ghostty terminal grid renders the transcript;
AppKit places block headers and the native editor using positions tracked by the
terminal core. Output is not captured through pipes or replayed as plain text.

The editor starts at one line, grows with hard and soft wraps, and stops growing
at the smaller of 12 terminal lines or 45% of the pane. Longer drafts scroll
inside the editor. While browsing terminal history, the current header and draft
remain pinned at the bottom. At the live prompt, the editor sits inline at the
terminal input position.

This is a controlled local-zsh prototype. See the
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
[`blocks.xcconfig`](blocks.xcconfig), and an absolute output directory:

```text
macos/build-blocks/ReleaseLocal/Ghostty.app
```

The app displays as **Ghostty Patina Blocks**, with bundle ID
`com.patinasystems.ghostty.blocks`. The original prototype in `macos/build/`
remains separate; these helpers neither rebuild that app bundle nor stop its
running process. The launcher checks the Blocks bundle ID before starting it.
An alternate Blocks app path may be supplied as its first argument.

When working from Kitchen, follow its `pat run` compute-routing rules for the
build. Use the local executor when the separate checkout is only on this Mac.

The launcher sets `GHOSTTY_NATIVE_INPUT=1` and disables upstream updates, default
user Ghostty configuration, automatic shell integration, and window restoration.
Only this launch enables the custom UI. The distinct app identity comes from the
Blocks xcconfig; do not distribute another configuration under the same name
without checking its bundle ID and update settings.

## Try it

1. Type or paste into the one-line native input. Add lines with Shift+Return and
   resize the pane to check growth on soft wraps. Option/Control+Return also add
   a newline. Pasting inserts text without executing it.
2. Drag a selection across lines, replace it, and use ordinary macOS clipboard,
   word/line selection, undo, and redo. Return submits the entire draft.
3. The accepted command appears in the terminal transcript under its block
   header. Its output retains Ghostty's colors, cursor behavior, and selection.
   Headers show the command's original directory, optional Git branch, and
   completion metadata.
4. Scroll upward through previous commands. The current header and editor stay
   at the bottom while the transcript scrolls independently.
5. Press Tab for zsh-backed completion in the native input. A unique match is
   inserted directly; multiple matches open an AppKit menu. Tab/Shift+Tab or
   arrows select, Return accepts without executing, and Escape dismisses the
   menu. Option+Tab inserts a literal tab.
6. Use the terminal-input control or Escape (with no completion menu open) for
   shell history and unsupported completion contexts. Native editing can resume
   at an empty primary prompt; clear or run any partially edited shell line.
7. Try `read answer; print -r -- "$answer"` or a terminal application. Running
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

- Custom block headers, layout, and editing use AppKit and explicit callbacks.
  The upstream application's existing SwiftUI shell remains in place; this
  feature adds no Lookout or Observation framework dependency.
- A real `NSTextView` owns text, selection, marked input, and its own undo manager.
  Ordinary edits do not replace its text storage on every presentation update.
- Each pane launches an isolated local zsh with a private temporary `ZDOTDIR`.
  It does not source the user's `.zshrc`; it inherits the terminal environment
  and working directory. Personal shell startup files are not modified.
- Atomic request/state/receipt files transfer the draft to a dedicated ZLE key
  widget. The widget checks the prompt generation, request ID, and empty input
  buffer before invoking normal `.accept-line` in the existing shell.
- Completion uses system zsh definitions in a private `zpty` worker forked from
  the current shell at each primary prompt. It inherits cwd, variables, aliases,
  and functions without sourcing a different startup configuration. The worker
  returns zsh's exact quoted buffer and cursor; AppKit applies a normal undoable
  edit only if the draft, caret, revision, and prompt are still current. See
  [native completion](../../docs/native-completion.md) for the protocol and limits.
- Drafts remain until acceptance. Uncertain submissions are never replayed, and
  a recovery view retains the draft after an error.
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
History still uses terminal input. Native completion rejects dynamic expansion
contexts such as command/process substitutions; use terminal input for those.
Completion functions can perform their ordinary I/O, but the draft is never
accepted or executed by the completion widget. Each pane has one private idle
completion worker at its primary prompt. Responses are bounded to 200 items and
8 MiB. Syntax coloring, imported user configuration/plugins, remote/nested-shell
adapters, fish, and Linux are not implemented. Selection highlighting remains
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

- All 37 PTY tests pass on system zsh 5.9. They cover exact multiline and Unicode
  transfer, retained shell state, ownership, stale/duplicate rejection, block
  markers, stable continuation IDs, completion metadata, and exit/cancellation.
- Six focused command-block core tests and the existing erase regressions pass.
- All 30 AppKit editor tests pass, covering selection/replacement, newline and
  submission behavior, retained drafts, IME-Return handling, independent undo,
  editor sizing, deferred-focus ownership, completion menus, cancellation,
  stale-result rejection, and Unicode edit boundaries.
- Six completion-transport tests and four real filesystem notification tests
  pass. Completion shell tests cover live context, quoting, Unicode/multiline
  carets, unchanged visible input, unsafe contexts, and response bounds.
- The native arm64 `ReleaseLocal` app builds successfully and passes
  strict/deep code-signature verification. This iteration was checked in a
  separate Diagnostics bundle, leaving the running Blocks app untouched.
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
with a testable configuration, the Blocks xcconfig, an isolated build directory,
and the architecture used for GhosttyKit. `build.nu` skips UI automation tests.
Repeat the interactive checks when changing layout, focus, or terminal ownership;
physical IME/VoiceOver and broader terminal-application qualification remain
separate work.

The editor/shell diagnostic measurements are recorded in
[`performance.md`](performance.md). Instrumentation is opt-in via
`GHOSTTY_NATIVE_INPUT_DIAGNOSTICS=1` and logs aggregate counts/timings only.
The migration inventory for removing upstream SwiftUI is in
[`appkit-migration.md`](../../docs/appkit-migration.md).
