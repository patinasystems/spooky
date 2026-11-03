# Native input integration measurements

These measurements cover the prototype's native input and shell bridge. They do
not establish terminal rendering throughput or a general efficiency claim.

## Submission latency and padded command UI

The submission path now wakes geometry observation immediately on Enter,
checks an in-flight transfer every 8 ms, and responds immediately to its receipt.
The required PTY resize barrier retries at 1–4 ms rather than 20 ms. Directory
events coalesce for 2 ms rather than 10 ms. Normal visible/occluded observation
stays at 33/250 ms. These changes retain the parsed-boundary ownership checks;
they do not clear the draft optimistically or expose the terminal cursor.

The zsh adapter uses the optional `zsh/files` builtins for atomic same-directory
renames, mkdir, and cleanup, with the original external commands as fallback.
This removes process-launch overhead without changing the submission protocol
or user startup. A matched private-PTY run measured 20 builtin `:` submissions
after five warmups per version, using kqueue and monotonic observation timestamps:

| Trigger → observed event | Before median / p95 | After median / p95 |
| --- | ---: | ---: |
| Acceptance receipt | 9.25 / 10.60 ms | 0.99 / 8.01 ms |
| Matching OSC 133 command-start marker | 26.51 / 29.16 ms | 3.09 / 11.21 ms |
| Next ready prompt | 57.07 / 62.36 ms | 19.08 / 28.00 ms |

This is shell-bridge latency, **not Enter-to-screen latency**. The fixture excludes
the app, renderer, user hooks, and repository metadata. Scheduler and filesystem
outliers were retained; this was not an idle-machine benchmark. Request-file
publication is separate (median 0.24/0.25 ms). Adapter SHA-256 before:
`122316cab56dcc619b98be656d05979661f10494339192adad2f9d06b92ed9d8`;
after: `6b8ddcdabe0dbfcd5a5ca6fb0555b7b6f92fa1b6879577c8d98991d7f36d7532`.
Raw local artifacts: `/tmp/spooky-submit-kqueue-before.json` and
`/tmp/spooky-submit-kqueue-after.json`. Reproduce with
`test/native-input/benchmark_latency.py --adapter <snapshot> --output <result>`.
The opt-in app recorder now also aggregates submission-to-dispatch and
submission-to-parsed-boundary time; neither counter measures GPU presentation.

Four logical points of horizontal padding enter the real terminal geometry, so
selection and pointer coordinates retain their normal mapping. A four-point
bottom gap uses space in the existing reserved header row, with a compact
caption below the shifted full-width separator. The AppKit editor has four-point
insets on all sides. Command chrome remains in Ghostty's text/Metal pass.
Completion filtering reuses a bounded shell result set and does not launch a
worker per keystroke; selection scrolling changes the clip origin immediately.

The first padded candidate (`bf06735654cc743506f204ac3e985b8d56d37886984ee5e4cb7c75f109866222`)
was exercised through computer use with 20 consecutive short submissions and
20 alternating two-page wheel gestures while preserving a two-line draft.
The menu was navigated through 31 arrow-key steps, filtered with noncontiguous
characters, taken to zero matches and back, and used to replace a Unicode token
before an unchanged command suffix. Completion acceptance and undo preserved
the surrounding text. Search opened from Cmd+F, found three matches, navigated
in both directions, and returned focus to the preserved draft. This pass also
found global paste shortcut interception in the search field, corrected by native
search key routing and explicit focus ownership. These are correctness
observations, not measured frame times.

Validation passed 93 focused core tests and all 49 zsh PTY tests. The combined
native suite passed 77 cases; after the search shortcut correction, its affected
editor/search suites passed all 53 cases, including two new clipboard/focus
regressions. Strict Swift lint and diff whitespace checks passed. Build/test
logs are `/tmp/spooky-padding-coretests.log`, `/tmp/spooky-padding-corebuild.log`,
`/tmp/spooky-polish-swift-tests.log`, and `/tmp/spooky-search-keys-tests-final.log`.

The final regular Spooky bundle (SHA-256
`311b4d1db4099e5923afb9dedea633ef10861bdd44f8d98a0e98c73c7f38e39f`)
built successfully and passed live Cmd+F → Unicode paste → match navigation →
undo/redo → Escape checks with its native draft preserved. Its completion menu
filtered `cfr` to `café-report.txt`, and a submitted `read` handed physical key
events to the terminal and returned to native editing afterward. The app was
left open at a clean prompt. No high-speed Enter-to-present recording was taken.

## Metal command chrome

The former header views painted in AppKit above Ghostty's Metal surface. Their
equality guard avoided idle and typing redraws, but their positions arrived from
a 33 ms GUI poll, independently of the terminal frame. That could make header
motion lag terminal scrolling. The editor also relied on covering Ghostty's
unfocused hollow cursor; it never disabled that rendered caret.

Command chrome now uses the existing renderer snapshot, text pipeline, and font
atlas. Metadata crosses the API only when captions or presentation change; core
pins determine header positions. Native input reserves bottom padding inside
the same drawable. Explicit native cursor ownership masks both regular cursor
instances and custom-shader visibility, without rewriting terminal modes.

This removes AppKit header painting and independent header positioning. It does
not make custom UI free: caption shaping/cache maintenance, an additional text
batch, native TextKit layout, and shell-bridge I/O remain. No general throughput
or stock-Ghostty parity claim follows from sharing its renderer.

The remaining GUI geometry snapshot uses `tryLock` and retries a busy parser
later, reuses its C record buffer, and skips the fast loop in idle occluded windows
or before native shell integration attaches. An in-flight submission keeps
geometry checks active until the parsed handoff completes, even while hidden.
Visible metadata discovery still
uses bounded block traversal; completed captions are cached by the renderer.

Before this change, the running normal-startup Spooky build (`5e80220c7` sources,
executable SHA-256
`9f8702f5b300a48a7dcc6798386762f80dce4e711a13f0c92a55be030c87cce9`)
was sampled for 15 intervals on the same M4 Max. Median CPU was 0.5% of one core,
maximum 0.8%, RSS 166,416 KiB, and sampled footprint 84.5 MiB. Window visibility
and workload were not controlled; this is context, not a matched benchmark.
Local evidence:
`/var/folders/3b/r63l28p928v2brw79bnfzv9m0000gn/T/ghostty-blocks-diagnostics-f4_twe4j/summary.json`.

### Computer-use stress observations

The first Metal candidate was exercised through its actual native window with
12,000 ANSI-colored, Unicode output lines that wrapped to roughly 24,000 screen
rows, then 20 separate native-editor submissions producing 40 output lines each.
Large wheel-scroll changes preserved a pinned multiline draft. Primary `read`,
alternate-screen input, incomplete syntax, cancellation, and returning to native
editing were also exercised. These are correctness observations, not frame-time
measurements. The user continued using the Mac; unavailable-window errors and
occluded/cached screenshots interrupted attempts at sustained wheel scrolling.
Those interrupted attempts are not counted as completed stress tests.

The sampled candidate executable SHA-256 was
`251680d01ce8e68da95e19579eb84a4057066e08c9d08c5a095f82b3cc551a6c`.
It predates the final Swift ownership-notification corrections discovered during
review. Each completed capture contains 30 CPU intervals; values are percentages
of one CPU core. Foreground visibility and pauses between actions were uncontrolled.

| Capture | CPU median / mean / peak | RSS start → end |
| --- | --- | --- |
| Hidden/activation | 0.7 / 1.81 / 14.2% | 187.9 → 193.9 MiB |
| Quiet interval between actions | 0.2 / 0.147 / 0.4% | 220.0 → 220.0 MiB |
| UI submission/scroll bursts | 0.7 / 2.497 / 12.5% | 235.2 → 229.8 MiB |

Sampled stacks showed no renderer deadlock. These captures do not establish
scrolling throughput, latency percentiles, leak freedom, or stock-Ghostty parity.
Local evidence is under `/tmp/spooky-rendercheck-stress-first`,
`/tmp/spooky-rendercheck-stress-visible`, and `/tmp/spooky-rendercheck-stress-bursts`.
A later idle capture was interrupted by quitting the test app for a rebuild and
is excluded from the table. The original user terminal was preserved throughout.

A subsequent live pass exercised an 80-line native draft, replacement across
three lines, undo, redo, copy/paste, submission, and unique-path Tab completion.
Continuation completion and Ctrl+C cancellation returned to native editing.
It also exposed a real occlusion bug: a submitted `vared` kept its disabled native
draft while background polling waited for visibility before observing the parsed
command boundary. In-flight transfers now continue geometry checks while hidden;
the fast loop becomes dormant again after the handoff. Regression tests cover
the owning command boundary, secondary editors, and alternate-screen handoff.

After that correction, `vared` and alternate-screen input completed without
manual mode switching. A dense run verified 20 additional short command blocks
and completed 40 alternating three-page wheel gestures with a two-line draft
preserved. Its screenshot exposed space-padded history rows being mistaken for
visible output, which hid their headers. Header visibility now accepts plain
spaces while preserving actual glyphs, combining clusters, backgrounds, and
decorations. A terminal-driven core regression covers these distinctions.

The corrected candidate (`c17546f66eae2de443d27d836a6cbc53fb038a1604c1bdce9c3df41b5b66998a`)
then verified 21 fresh command blocks, another 40 alternating three-page wheel
gestures, and successful submission of the preserved multiline draft. Captures
showed the completed headers, metadata, and full-width separators restored.
All 104 targeted core tests and 55 native Swift test cases passed. No high-speed
frame recording or matched stock-Ghostty performance comparison was taken.

## Instrumented bridge baseline

2026-11-02, macOS 27.0.1, Apple M4 Max, 16 CPU cores, 128 GiB RAM. Candidate
`com.patinasystems.ghostty.cursor-performance`, PID 7495, ReleaseLocal arm64,
diagnostics enabled. This candidate already includes the pointer fixes and
editor setter guards; its bridge still used the original 100 ms polling loop.
It is a baseline for the **bridge scheduling change**, not every change in this
iteration. The existing Blocks app remained untouched.
Baseline executable SHA-256:
`cde5c54ee384670d497825908771a5edc75e6c2c892ca98e911ad5e7c0627ad2`.

Root-operated idle captures, after startup: baseline sequences 2–5 from
`/tmp/ghostty-cursor-performance-baseline-runtime.log` (19.991 seconds), versus
after sequences 3–6 from `/tmp/ghostty-native-shell-after-runtime.log` (20.013
seconds, PID 47230). After executable SHA-256:
`154f8addec4cd51d0b8714fed76ed0dbfae2ecaa0638c849655cff8bb94f04bd`.
The later bounded cleanup for cancelled completion responses was added after
this capture; this hash identifies the measured candidate, not the final build.

| Measurement | Baseline | After |
| --- | ---: | ---: |
| Bridge snapshots | 193 (9.654/s) | 10 (0.500/s) |
| Bridge file-read attempts | 1,543 (77.184/s) | 80 (3.997/s) |
| Successful file bytes | 22,967 | 1,210 |
| Bridge snapshot elapsed time | 264.751 ms (13.243 ms/s) | 9.799 ms (0.490 ms/s) |
| Geometry snapshots | 578 (28.913/s) | 576 (28.781/s) |
| Geometry snapshot elapsed time | 9.162 ms | 7.401 ms |
| Host synchronization | 0 | 0 |
| Header drawing | 0 | 0 |
| TextKit measurement | 0 | 0 |

The watcher reduced idle bridge file-read attempts by **94.82%** and measured
bridge elapsed time per second by **96.30%** in these captures. This is not a
claim about CPU utilization or terminal rendering speed. The geometry schedule
was unchanged; its small timing difference is not attributed to an optimization.

Elapsed operation time includes waiting and instrumentation; it is not a CPU
utilization measurement. File-read attempts include missing-file checks. A
five-second aggregation boundary can split the counters belonging to one
snapshot, so compare multi-interval totals. The recorder is disabled unless
`GHOSTTY_NATIVE_INPUT_DIAGNOSTICS=1` is set before launch.

The small measured geometry cost did not justify adding a complex geometry
cache. Geometry polling remains at 33 ms for scrolling responsiveness. The
bridge now uses coalesced directory notifications, watches the current block's
metadata directory separately, and retains a two-second recovery watchdog.
Explicit startup/submission deadline refreshes preserve the five-second timeout
behavior. Completed metadata remains cached, and scrolling to different block
IDs requests metadata immediately.

A separate matched 20-keystroke native editing phase compares baseline sequence
9 with after sequence 12:

| Measurement | Baseline | After |
| --- | ---: | ---: |
| Host synchronizations | 20 (1.942 ms total) | 20 (0.798 ms total) |
| Header invalidations | 40 | 0 |
| Header draws | 12 (2.880 ms total) | 0 |
| TextKit measurements | 20 (0.050 ms total) | 20 (0.034 ms total) |

The header equality guard avoided repainting unchanged headers during ordinary
typing. These short runs do not establish latency percentiles, large-draft or
large-history behavior. Four real filesystem watcher tests and all 40 targeted
native editor/bridge tests passed; shell correctness is covered separately by
the PTY integration tests.

## Earlier live-session observation

The original Blocks PID 52634 was sampled without controlling its activity or
visibility. At 22:28:05–08 UTC, two valid `top` intervals reported 1.7% and 2.4%
CPU (percent of one core), 13–14 threads, and `top MEM` 379M. `ps` RSS was about
223 MiB. The machine was 80–86% CPU idle during those intervals; other apps were
running. These are different memory metrics and are not directly comparable.

A separate three-second stack sample at 22:28:29 UTC reported physical footprint
149.1M, peak 472.7M. Its main thread waited for events in 2,275 of 2,277 samples;
the renderer thread was also waiting. Active worker stacks repeatedly entered
`CommandInputBridge.snapshot`, `fields`, and file-reading helpers. This suggested
investigating recurring bridge I/O; it does not establish foreground rendering
cost. Raw local artifact: `/tmp/ghostty-blocks-baseline-52634.sample.txt`.

## Repeating the process capture

`diagnose.py` validates the running executable's bundle identifier and collects
process CPU intervals, RSS, thread count, host load, and optional stacks. It
does not activate the app, send keys, read terminal content, inspect the
clipboard, or collect process environment variables. Visibility is an explicit
observer label, not verified by the script.

```sh
/Users/tylerangert/dev/patina/active/kitchen/pat run --on local --cost heavy --cores 1 -- \
  'cd /Users/tylerangert/dev/patina/active/ghostty-wt-native-input && python3 prototype/native-input/diagnose.py --bundle-id com.patinasystems.ghostty.cursor-performance --seconds 20 --sample-seconds 3 --phase idle --visibility active-visible'
```

Keep app version, pane count, window dimensions, history, draft, and foreground
state matched when comparing runs. Use the first interval as warm-up. Measure
idle and a fixed native editing sequence separately. For shell interactions,
check submission acknowledgement, continuation handling, and late receipt
recovery as correctness requirements alongside the counters. Do not infer a
typing or scrolling improvement from an idle file-read reduction.
