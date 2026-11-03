# Spooky

A macOS Ghostty fork with an inline AppKit command editor and grouped
command/output history. One real Ghostty terminal grid renders the transcript;
Ghostty's Metal renderer draws block headers from core-tracked positions, and
AppKit hosts the native editor. Output is not captured through pipes or replayed
as plain text.

The editor starts at one line, grows with hard and soft wraps, and stops growing
at the smaller of 12 terminal lines or 45% of the pane. Longer drafts scroll
inside the editor. While browsing terminal history, the current header and draft
remain pinned at the bottom. At the live prompt, the editor sits inline at the
terminal input position.

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
History still uses terminal input. Native completion rejects dynamic expansion
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

- All 49 PTY tests pass on system zsh 5.9. They cover exact multiline and Unicode
  transfer, retained shell state, ownership, stale/duplicate rejection, block
  markers, stable continuation IDs, completion metadata, and exit/cancellation.
  Startup fixtures exercise normal interactive/login startup order, custom
  ZDOTDIR, aliases/PATH/history, existing completions/fpath/styles, hooks,
  keymaps, options, prompt restoration, and ordinary-terminal fallback when
  required hook support is unavailable.
- Eight focused command-block core regressions pass, including durable
  submission markers across erase, hard reset, and scrollback eviction. The
  selected-command/startup-environment core test also passes.
- All 30 AppKit editor tests pass, covering selection/replacement, newline and
  submission behavior, retained drafts, IME-Return handling, independent undo,
  editor sizing, deferred-focus ownership, completion menus, cancellation,
  stale-result rejection, and Unicode edit boundaries.
- Six completion-transport tests and four real filesystem notification tests
  pass. Completion shell tests cover live context, quoting, Unicode/multiline
  carets, unchanged visible input, unsafe contexts, and response bounds.
- Thirteen submission-handoff/chrome-presentation test cases and two startup-resource
  tests pass, bringing the targeted native total to 55. Caption identity,
  offscreen pinning, metadata publication, display-scale invalidation, and
  coalesced secondary-shell ownership transitions, and hidden-window submission
  progress are covered.
- The Metal integration passes 104 targeted core tests, including native cursor
  ownership, prompt transitions, caption bounds/Unicode, space-padded and
  overwritten headers, and editor insets. Metal shaders compile as part of the core build. Renderer
  assertions check that suppressed frames retain no terminal cursor glyph.
- Computer-use stress on the first Metal candidate exercised 12,000 colored,
  wrapped Unicode output lines, 20 separate native submissions, and large
  scrollback movements with a pinned draft. Foreground changes interrupted
  sustained wheel-scroll attempts; these are not frame-time benchmarks. See
  [the measurement notes](performance.md) for the exact scope and limitations.
- The native arm64 `ReleaseLocal` app builds successfully and passes
  strict/deep code-signature verification. Spooky uses its own bundle and build
  directory, preserving the earlier development apps.
- The delivered Spooky app was opened normally through Finder. Its live shell
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
