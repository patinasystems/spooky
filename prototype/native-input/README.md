# Native input prototype

This is an opt-in macOS Ghostty build with a real AppKit multiline command editor.
It runs a controlled local zsh session and uses Ghostty's existing renderer and
PTY. It is the first implementation slice of the
[longer-term design](../../docs/native-command-input.md), not full Warp parity.

## Build and launch

Use Xcode and its Metal toolchain, Zig 0.17.x, and Nushell. See
[HACKING.md](../../HACKING.md) for upstream dependencies. The helper builds a
native-architecture GhosttyKit and the `ReleaseLocal` app:

```sh
GHOSTTY_ZIG=/path/to/zig ./prototype/native-input/build.sh
./prototype/native-input/launch.sh
```

When working from Kitchen, route that build through `pat run --on local --cost
heavy -- '<build command>'`, because this separate repository is local to this
Mac. The app appears as **Ghostty Patina** and uses bundle ID
`com.patinasystems.ghostty.prototype`. The launcher disables upstream updates,
default user Ghostty configuration, automatic shell integration, and window
restoration for this controlled test. It does not replace an installed Ghostty.

The launcher enables `GHOSTTY_NATIVE_INPUT=1`. Running the app without that
environment variable retains the ordinary terminal UI. Only the `ReleaseLocal`
app identity is changed; do not distribute other build configurations as the
Patina prototype without reviewing their identities and update behavior.

## Try it

1. Click the bottom editor and type or paste a multiline command. Drag to select
   across lines; replace the selection, undo, and use normal macOS word/line
   selection. Paste only inserts text.
2. Shift+Return inserts a newline. Return submits the whole draft to the same
   interactive zsh. Option/Control+Return also insert a newline.
3. After submission, the terminal receives input until the shell returns to a
   fresh prompt. Try `read answer; print -r -- "$answer"` or a terminal program.
4. Use **Use Terminal** or Escape for ordinary shell editing, history, and Tab
   completion. At an empty top-level prompt, **Edit Command** restores native
   editing. A partially typed shell line must be cleared or run first.
5. Incomplete syntax, such as `if true; then`, yields to the terminal continuation
   prompt. Finish it there or cancel with Ctrl+C.

For example, paste this entire buffer, select text across its lines, then submit:

```sh
export PATINA_DEMO='hello from the native editor'
printf '%s\n' "$PATINA_DEMO"
cat <<'END'
Multiline input with quoted text,
emoji 👩🏽‍💻, and 日本語.
END
```

Then submit `printf '%s\n' "$PATINA_DEMO"` separately to verify that the shell's
environment persists. `cd` persists as well.

## Implemented boundary

- A real `NSTextView` owns selection, text, marked input, and a per-editor undo
  manager. Native copy/cut/paste/select-all/undo/redo stay in the editor.
- Drafts remain present until the shell acknowledges acceptance. Failed or
  uncertain submissions are not replayed. **View Draft** exposes a retained draft
  when native submission has stopped.
- Each pane gets a private temporary directory and isolated `ZDOTDIR`. The
  starter shell does not load personal startup files or persist user history.
  It still inherits the launched terminal environment and working directory.
- The shell adapter validates the current prompt generation and request ID,
  loads the complete draft into `BUFFER`, and invokes ZLE's normal `.accept-line`.
  It does not send command text through a paste API or create a new shell for
  each command.
- Running programs, nonempty shell input, and continuation prompts retain the
  normal terminal input path. Nested processes do not inherit the bridge
  capability.
- The editor accepts UTF-8 text up to 1 MiB. It explicitly rejects control
  characters other than tabs and newlines; it does not silently remove them.

## Known limits

History and completion are available through **Use Terminal**, not inside the
native editor. Syntax coloring, imported user shell configuration, remote and
nested-shell integration, native completion menus, and Linux are not implemented.
Selection highlighting is native AppKit selection.

This prototype uses atomic request/state/receipt files and polls small state
records every 100 ms. A dedicated terminal key sequence wakes the ZLE submit
widget. Generation checks reject stale requests when ZLE resumes, but an
unexpected foreground change between readiness checking and sending that key
sequence can deliver trigger bytes to the foreground program. General-purpose
deployment needs a stronger ownership/transport protocol; the isolated starter
shell is the explicitly limited test environment.

The 100 ms polling and file protocol are feasibility choices, not performance
claims or the intended final transport. Closing a pane removes its private
directory; an app crash can leave a `patina-ghostty-input-*` directory in the
system temporary directory. No personal shell startup files are edited.

## Verification

Validated on 2026-11-02 on Apple Silicon with Zig 0.17.0, Xcode 27, Swift 6.4,
and system zsh 5.9:

- Native GhosttyKit and the `ReleaseLocal` arm64 app build successfully.
- The 11 PTY integration tests pass.
- All seven `CommandTextViewTests` pass, including multiline Unicode replacement,
  newline versus submission, retained drafts, disabled resubmission, IME Return,
  independent undo managers, and empty-editor sizing/hit testing.
- Interactive checks confirm selection across lines, replacement and undo,
  Shift+Return, full-buffer execution, persistent environment, and handoff to and
  from an interactive `read` command.
- New Swift files pass strict SwiftLint; shell syntax and diff whitespace checks
  pass. These checks do not establish full Warp parity or production readiness.

The shell integration suite launches fresh PTYs and temporary shell environments:

```sh
uv run --no-project --python python3 test/native-input/test_zsh_bridge.py
```

It tests persistent state, exact multiline/Unicode/heredoc/trailing-newline
transfer, continuation fallback, stale/duplicate rejection, nonempty-buffer
preservation, `read` and raw-mode input, invalid payloads, and nested-process
isolation.

Native editor tests live in
[`CommandTextViewTests.swift`](../../macos/Tests/Ghostty/CommandTextViewTests.swift).
Run them through `macos/build.nu --action test --only-testing
GhosttyTests/CommandTextViewTests`; choose a configuration with testability enabled
and an architecture matching the built GhosttyKit. The helper skips UI tests,
so this is not a substitute for interactive validation of focus, IME, VoiceOver,
multiple panes, or terminal programs.
