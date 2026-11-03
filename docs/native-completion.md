# Native command completion

Assessment dated 2026-11-02. This comparison does not propose changing the
default shell. The first implementation now uses the user’s normal zsh:
an AppKit menu receives full buffer/cursor results from a per-prompt zpty worker
forked from the live shell's state. It reuses the user’s loaded completion definitions and rejects dynamic
expansion syntax; arbitrary custom ZLE-widget parity is not promised. The provider comparisons and effort ranges below describe broader
implementation choices, not measured development time. The current fish documentation identifies
itself as 4.9.3. The source check below pins fish commit
[`5564c2f06b115123318f00ddc874b8d8e9ca4707`](https://github.com/fish-shell/fish-shell/tree/5564c2f06b115123318f00ddc874b8d8e9ca4707).
Fish is not installed in the inspected development shell; no fish runtime or
completion latency measurements were performed.

**Chosen route.** Keep the native multiline AppKit editor and integrate the
chosen shell's mechanics. The current provider uses a snapshot of the existing
normal zsh session rather than a separate command/path implementation. zsh
produces completed buffers and cursor positions, so it owns quoting and token
replacement. The app owns selection, presentation, undo, and acceptance. A fish
session adapter remains an optional future provider; changing the default shell
is not required for this implementation.

**Why changing shells alone did not solve Tab.** Before the completion adapter,
[`CommandTextView`](../macos/Sources/Features/Command%20Input/CommandTextView.swift)
owned keyboard input without a shell completion callback. Its Return/Escape
handling fell back to normal AppKit editing for Tab. The live zsh buffer remains
empty until the
[`submission widget`](../macos/Sources/Features/Command%20Input/native-input.zsh)
accepts the whole draft. Changing the child process to fish would not deliver
Tab or that draft to fish's interactive reader. The controlled zsh bootstrap
originally did not call `compinit` or read the user's `.zshrc`. Spooky now loads normal user startup files and reuses their completion system;
if it is not initialized, the adapter runs compinit using the existing fpath.

The following comparison retains rough planning estimates for future alternatives
or broader qualification. It is not a remaining-work schedule for the current
prototype, and the native-only path is not the chosen implementation.

| Approach | What it buys | Principal work and limit | Planning estimate |
| --- | --- | --- | --- |
| Native command/path provider | Predictable first useful Tab; no completion subprocess for ordinary paths | Shell-aware token boundaries/escaping, live cwd/PATH context, filesystem work, AppKit menu; no general command-specific flags/arguments | 3–5 engineer-days for a tested first version |
| Live zsh completion adapter | Completion appropriate to the executing shell, including its session state | Initialize `compsys`; obtain candidates and insertion semantics without changing live input/output; handle slow/custom completers | 2–3 day feasibility spike, then roughly 1–3 engineer-weeks total for the controlled zsh scope |
| Fish session plus `complete -C` adapter | Existing rich command-specific candidate engine with a simpler query entry point | Fish submission/readiness/block hooks, same-shell state, candidate transport, native UI, quoting and cursor limitations | 1–2 day engine spike, then roughly 1–2 engineer-weeks total for a controlled opt-in fish session |

These are engineering estimates for one engineer familiar with this fork, not
measurements or delivery commitments. Totals include the shared native UI;
they are alternatives, not additive. Arbitrary user startup files, custom
widgets, remote shells, and exact fish/zsh editing parity are separate work and
could add several weeks. A terminal-native fish pane is a smaller alternative,
but then the shell, rather than NSTextView, owns editing.

**Implemented AppKit interface.** NSTextView remains first responder while a
nonactivating child panel renders an `NSTableView` at the insertion rect.
Candidates carry display text, detail, replacement text/range, and an optional
resulting cursor position. The current zsh bridge returns whole-buffer edits;
acceptance still uses NSTextView's normal edit/undo path rather than assigning
its `string` property. While the menu is open, typing and deletion within the
active token filter the cached candidates immediately using case/diacritic-insensitive
fuzzy matching, with prefix matches ranked first. Acceptance replaces the current
UTF-16 token range and preserves surrounding text. Moving the caret, changing
other command text, losing focus, starting IME composition, or changing editor
width cancels the request. Height-only growth repositions the menu. All new UI is AppKit; there is no Lookout or
SwiftUI completion view and no new terminal output renderer.

The rounded menu displays only completion options, uses an accent-tinted selected
row, and scrolls selection without animation. A zero-match query can recover by
backspacing. Filtering uses the bounded result set from the initial Tab request;
it does not discover candidates excluded by the shell's original query. Close
and press Tab again to refresh the shell result set in a different context.
Cmd+F opens terminal search from the editor, preserving the draft. The search
field and result/navigation controls use matching AppKit styling; Escape closes
search and returns focus to the originating editor when its pane still owns focus.

Implemented keyboard contract: Tab requests completion at a collapsed selection;
a unique candidate is
inserted. Multiple candidates open the menu; Tab/Shift-Tab or arrows move the
selection, Return accepts it without executing, and Escape closes the menu
without switching to terminal input. Escape also cancels a pending request before
the menu appears. With no menu or pending request, Return and Escape keep their
existing meanings. Option-Tab inserts a literal tab. Marked IME text always
gets first refusal. Fish's own interaction similarly inserts a unique result,
extends an unambiguous prefix for multiple results, and offers a pager navigable
with Tab/Shift-Tab. Matching every pager behavior is optional scope, not a
requirement for the first native menu.
([fish interactive completion](https://fishshell.com/docs/current/interactive.html#tab-completion))

**Future native-only alternative.** A separate command/path provider could enumerate executable
names from the live shell's PATH and files relative to its current directory;
show directories distinctly and keep `/` when appropriate. Read directories
off MainActor and limit results. The current block metadata supplies cwd, but
does not supply the live PATH, aliases, functions, or shell variables. Add an
explicit context snapshot if those names are offered; the app's launch
environment becomes stale after a shell export. Cache against that context,
not only the typed prefix.

This provider needs a small shell-aware tokenizer, not a full execution engine.
It must distinguish a command position from an argument, quoted whitespace from
a separator, pipelines/newlines from ordinary text, and a token's prefix from
its suffix at an arbitrary cursor position. For the initial scope, decline
contexts such as nested substitutions or heredoc bodies rather than inserting
incorrectly. A multiline editor makes these cases normal; splitting on spaces
or completing only the final line will corrupt valid drafts. Syntax coloring
can later reuse the tokenizer, but coloring alone is not a completion engine.

**The implemented zsh provider uses a prompt-time snapshot.** zsh's `compinit` initializes
its function-based completion system and redefines completion widgets. Its
completion definitions use contexts, tags, and styles, rather than merely
returning filenames. Use the shell’s existing function search path and retain its completion security
checks. Startup files and plugins load before the adapter; it reuses initialized
compdefs instead of replacing them.
([zsh completion system](https://zsh.sourceforge.io/Doc/Release/Completion-System.html))

At each primary prompt, `precmd` forks a private `zpty` worker from the live
shell. It inherits that prompt's cwd, variables, functions, aliases, and loaded
completion definitions without running another `.zshrc`. The worker opens its
own `vared`/ZLE context before the foreground ZLE starts. Lifecycle hooks are
disabled there, its output is drained, and it never borrows or redraws the
foreground editor's buffer. It is stopped before command execution and replaced
at the next primary prompt. Changes after the snapshot within the same prompt are not automatically mirrored.
On the first prompt, all startup files have loaded, but later user precmd hooks
can still run after the initial worker snapshot. On subsequent prompts the
native precmd hook runs after the previously registered user hooks.

The foreground completion widget validates the empty primary prompt and
generation, then forwards the request to that worker. Completion does not call
`.accept-line` or submit the draft. The worker's shell-state mutations do not
propagate back to the parent. This is a forked state snapshot, not direct
completion inside the executing shell's active ZLE, and not a fresh `zsh -c`
process reconstructed from cwd/env. These distinctions matter for custom
completion functions and parent state.
([ZLE interface](https://zsh.sourceforge.io/Doc/Release/Zsh-Line-Editor.html))

zsh exposes `PREFIX`, `SUFFIX`,
`CURRENT`, quoting context, and `compstate`; `compadd -O`/`-A` can collect
matched/generated strings. However, display labels, ignored prefixes, quoting,
matcher rules, removable suffixes, groups, and insertion behavior must survive
the adapter. Capturing only strings from `compadd` is not proof of full zsh
completion parity. The implemented worker runs `_main_complete` through a
completion widget and enumerates `.menu-complete -n 1`, capturing each resulting
`BUFFER` and `LBUFFER` byte count. This retains zsh's quoting/insertion result
without attempting to reconstruct it from display strings. The current popup
extracts the active completed option for display, with no repeated command
prefix or provider label; richer descriptions
and completion groups remain future work.
([zsh completion widgets](https://zsh.sourceforge.io/Doc/Release/Completion-Widgets.html))

**Current file protocol and limits.** All files are inside the pane's private
bridge directory. The app atomically publishes `completion-request` as:

```text
<prompt generation> LF
<request UUID> LF
<UTF-8 caret byte offset> LF
<exact UTF-8 draft>
```

Only the dedicated `ESC [ 99 ; 2 ~` trigger travels through the real PTY. The
foreground widget consumes the request once; the worker claims its own copy by
rename before reading. It publishes `completions/<UUID>/` with one atomic
directory rename. This directory contains `generation`, `identifier`,
`status` (`ok` or `rejected`), `reason`, `count`, `truncated` (`0` or `1`), and
`items/<1..count>/buffer` plus `cursor`. Each item is a complete resulting draft
and its UTF-8 caret byte offset. The app validates identity and bounds, converts
offsets to UTF-16, and removes the consumed response. The in-app request UUID
also binds the result to the draft revision and selection; those UI fields do
not need to be interpreted by zsh.

Drafts and individual resulting buffers are limited to 1 MiB; aggregate
candidate buffers to 8 MiB; results to 200 distinct buffers; enumeration to
400 match steps. The shell publishes truncation, but the current popup does not
yet show a truncation indicator. The app waits approximately three seconds
(150 response checks with 20 ms sleeps, plus I/O time). Cancellation stops app
waiting and removes matching queued/available files; it does not promise to
interrupt an already-running completion function immediately. Worker teardown
at execution/next prompt bounds its lifetime to the prompt session. New requests
prune older finalized responses, and retiring a prompt removes all remaining
response files, including late publications after native cancellation.

The app rejects C0 controls except Tab/LF, and DEL; both sides validate UTF-8
and caret boundaries, and NUL is rejected. The shell conservatively rejects
any draft containing a backtick, `(`, `{`, or `$'`, even quoted/escaped. This
excludes command/process substitution, braced expressions, executable glob
qualifiers, and ANSI-C-quoted forms from native completion. Basic `$NAME`
completion is supported. These are completion limits, not changes to zsh's
submission language; terminal completion remains the fallback. Existing user completion definitions and fpath are preserved. If compsys has
not been initialized by user startup, `compinit -i -D` initializes it without
writing a new completion dump. The adapter does not rerun an existing compinit.

Sources: [shell adapter](../macos/Sources/Features/Command%20Input/native-input.zsh),
[file bridge](../macos/Sources/Features/Command%20Input/CommandCompletionBridge.swift),
[session](../macos/Sources/Features/Command%20Input/CommandInputSession.swift),
[AppKit completion view](../macos/Sources/Features/Command%20Input/CommandCompletionView.swift).

**Future fish provider.** Fish makes the engine easier, not the whole feature automatic.
`complete -C STRING` queries candidates, and `--escape` preserves shell escaping
in the output. Fish provides autoloaded command-specific definitions, optional
descriptions, conditions, and wrapped-command completion. This is a useful
headless entry point; it avoids inventing our own database of CLI options.
([fish complete](https://fishshell.com/docs/current/cmds/complete.html),
[completion definitions](https://fishshell.com/docs/current/completions.html))

There are concrete API limits. The inspected builtin finds the token at the
end of the supplied string, applies each candidate to that token, and prints
the resulting token plus an optional tab-separated description and newline.
It strips an appended space and does not export the full internal insertion
flags or a replacement range. `--escape` is preferable for a bridge, but this
is not a JSON edit protocol. Completing a prefix ending at the native cursor
loses the text after that cursor; quoted middle-of-token cases need explicit
tests and an adapter policy. Unusual descriptions and filenames also need
unambiguous framing before crossing into AppKit.
([pinned builtin implementation](https://github.com/fish-shell/fish-shell/blob/5564c2f06b115123318f00ddc874b8d8e9ca4707/src/builtins/complete.rs#L489-L582))

For an actual fish pane, use the live fish process for queries. Its
`commandline` builtin exposes the buffer, cursor, token/process context, and
selection; `bind` can invoke fish functions or reader actions. The adapter
must preserve the reader buffer and use explicit request/result transport.
Those primitives make a fish bridge plausible, but are not themselves a
native-editor RPC API.
([commandline](https://fishshell.com/docs/current/cmds/commandline.html),
[bind](https://fishshell.com/docs/current/cmds/bind.html))

A persistent helper fish launched beside zsh can offer useful generic
suggestions, but its functions, variables, definitions, and quoting language
are fish's, not the active zsh's. A fresh helper additionally pays startup cost
and misses session changes. Fish is intentionally not POSIX-compatible; it
differs in variable assignment, expansion, and other syntax. Choosing fish as
the default therefore changes which pasted commands mean what, not just which
completion menu appears.
([fish versus other shells](https://fishshell.com/docs/current/fish_for_bash_users.html),
[fish invocation/configuration](https://fishshell.com/docs/current/cmds/fish.html))

Fish abbreviations are a separate reader behavior. They expand on typed space
or Enter and can invoke functions; they do not expand as script syntax.
`complete -C` alone does not bring abbreviation expansion, history suggestions,
or fish's syntax highlighting into NSTextView. If we promise those features,
define additional adapter/UI contracts and show expansions before submission.
([abbreviations](https://fishshell.com/docs/current/cmds/abbr.html),
[autosuggestions](https://fishshell.com/docs/current/interactive.html#autosuggestions))

**Shared provider contract.** Requests capture pane identity, prompt generation,
draft revision, selection/cursor, and the complete draft. Results must match
those identities before an explicit edit is applied. The existing adapter
converts between wire UTF-8 and NSTextView UTF-16 and rejects obsolete results
after edits, selection changes, prompt changes, or focus/ownership loss. Future
providers must preserve those guarantees.

Queries currently start on explicit Tab, with only the newest app request kept.
Filesystem I/O stays off MainActor. Future work should measure cold/warm provider
time, time to visible menu, worst cases, stale-result rejection, and retained
tasks. No completion latency or cancellation-time benchmark is claimed here.

**Completion code is executable code.** Fish definitions explicitly support
command substitutions and shell-command conditions; zsh completers are shell
functions. Generating suggestions may run external programs or inspect project
files even though the draft is not submitted. Preserve the user's trust boundary
for installed completion scripts, keep results off the terminal transcript,
bound output and latency, and do not interpolate/evaluate the draft as shell
source. These are transport requirements, not a reason to add a confirmation
dialog to every Tab press.
([fish completion evaluation](https://fishshell.com/docs/current/completions.html),
[zsh completion functions](https://zsh.sourceforge.io/Doc/Release/Completion-System.html))

**Verification status.** The recorded milestone checks passed 49 PTY tests and
55 targeted Swift test cases. The PTY suite covers normal startup files, user
completion configuration and hooks, history, shell-state inheritance, paths
and quoting, multiline Unicode and middle-caret completion, request identity,
dynamic-syntax rejection, output isolation, bounds, and ordinary submission.
The Swift suite includes 30 native editor tests, six completion bridge tests,
four file-event tests, thirteen submission-handoff/chrome cases, and two startup-resource
tests. It covers undoable acceptance, menu key routing,
Unicode boundaries, stale replies, cancellation, and focus. Live app checks
passed for unique path completion and undo, multiple-candidate keyboard
selection and acceptance without submission, git arguments, changed cwd,
new aliases and variables, multiline input, and completion before trailing
text. A completed variable command submitted normally and printed its value.
Terminal-output copy/paste retained native editing focus. The automation
captures the main window separately from the nonactivating completion panel,
so the popup's visual placement still needs a direct visual check. Fish and arbitrary user-plugin compatibility are not fully qualified.

Test sources: [PTY suite](../test/native-input/test_zsh_bridge.py),
[editor tests](../macos/Tests/Ghostty/CommandTextViewTests.swift),
[bridge tests](../macos/Tests/Ghostty/CommandCompletionBridgeTests.swift).
