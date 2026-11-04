# Native input integration measurements

The newest measurements include source-event-to-WindowServer pixels. Older
sections below describe earlier revisions and app/shell-side timings; they do
not establish rendering throughput or stock-Ghostty parity.

## Fresh stock control, indexing, scrolling and submission, 2026-11-04

The 150 ms cold-typing tail did not reproduce in these admitted pixel samples.
This does not identify its historical cause or establish stock-level smoothness.
The measured candidate is the source content committed as `671b36a89`, built
before commit (`0e427-dirty`). The installed `c690f89d9` release adds recovery
when a window becomes visible/on-Space; it was functionally checked, but that
final binary was not re-recorded. Stock is pristine upstream
`0b1729e945978fca4bcd6165d8ac408bf675a7f2` plus passive Swift diagnostics and
separate branding, with no Zig/renderer/parser/shell changes.

All runs used ReleaseFast core/ReleaseLocal macOS builds, 2× backing scale,
800×632-point content windows, and native-scale own-window capture. They ran
sequentially on the user's live Mac; our builds/profilers/analysis were paused.
Bounds use original NSEvents and confirmed native WindowServer pixels, not
callback receipt, app-side completion or physical display scanout. Each bound
uses the frame's actual timestamp; capture cadence varies.

| Typing workload | Glyphs | Median bounds | p95 bounds | Max upper |
| --- | ---: | ---: | ---: | ---: |
| Stock A, plain | 107 | 13.23–21.55 ms | 15.34–23.96 ms | 24.13 ms |
| Spooky cold A, plain | 128 | 6.09–14.65 ms | 13.74–21.45 ms | 29.21 ms |
| Spooky load B, plain | 64 | 6.10–14.50 ms | 11.27–19.19 ms | 21.61 ms |
| Load B, `Applications` with completions | 24 | 14.28–23.05 ms | 22.91–31.96 ms | 48.58 ms |
| Load B, `@spooky` | 14 | 6.63–15.10 ms | 22.76–31.42 ms | 32.67 ms |

Targets are inserted foreground glyphs, not faded suggestions or caret changes.
Stock A excludes 16 clipped characters and five repeated `#` responses that
cannot be distinguished from the preceding draft. Load B also has six `cd /`
seed glyphs (median 20.23–31.76 ms); two spaces have no glyph endpoint.
All 108 nonspace load-B targets qualify. Child-menu pixels are outside capture:
these are editor latencies under completion/picker activity, not result or
placeholder presentation latency. Cold A's later 19 completion/picker targets
are unmeasured after its raw budget expired; narrow-ROI load B repeats them.

Telemetry confirms initial crawl/not-ready throughout both native runs. Cold A's
enclosing 7.52 s scanned 219,117→571,449 entries at 0.987 helper CPU-seconds per
wall second; load B's 30.20 s scanned 226,159→1,271,691 at 0.680. Indexing was
active; unequal loads and sequential runs prevent a causal or ranking claim.
Cold A's handler-return→AppKit-draw median/max was 0.208/0.441 ms. Its worst key
reached the handler at 9.977 ms, finished at 15.688 ms, drew at 15.923–15.963 ms,
and appeared at 21.715–29.209 ms. Load B's worst key reached the handler at
15.591 ms, spent 1.627 ms handling, and finished drawing 3.296 ms after entry;
its 31.87–48.58 ms pixels still leave 14.65–31.36 ms after handler return.

| Scroll run | Movements | Median bounds | Max upper |
| --- | ---: | ---: | ---: |
| Stock B | 21 | 22.00–30.62 ms | 40.19 ms |
| Stock C, repeated control | 21 | 13.94–22.35 ms | 23.35 ms |
| Spooky D | 20 | 5.73–17.44 ms | 28.61 ms |

The fixture uses 300 numbered rows, +600 points, 12 alternating ±36-point wheel
events, then 16 +9-point events. Logs confirm precise deltas, phase/momentum 0:
this is computer-use wheel input, not physical trackpad momentum. Every sampled
output strip matches a visually identified row state. Observed steps are whole
34-pixel rows; no subrow presentation was observed. Spooky's footer reservation,
core row count and editor position remain constant during this sequence.

The differing row counts follow `Surface.accumulateScroll`: upstream discards
overshoot; Spooky preserves signed remainder. At 17-point rows, +600 leaves 5;
+36 emits 2/leaves 7; −36 emits −1/leaves −12. Subsequent reversals move one row.
The next three +9 events retain −3,6,15 before the fourth moves one row. Pixels
match this exactly. Stock reversals move two rows and each second +9 moves one.
Zero-movement fractional inputs stay recorded and are not called latency stalls.

| Six distinct `printf` outputs | Median Return→output | Max upper |
| --- | ---: | ---: |
| Stock B | 23.72–32.00 ms | 39.58 ms |
| Stock C | 27.26–35.49 ms | 39.87 ms |
| Spooky D | 22.24–30.98 ms | 39.05 ms |

Each Return runs `printf '%d\n' $((41000+N))`, N=1…6. Unique output 41001…41006
is matched at every vertical ROI position and visually checked. The narrow
crop cannot identify all committed command text; these are output endpoints,
not separate block-commit timings. Six samples and the variation between stock
runs do not establish throughput, a 10× improvement, or a general speed ranking.

Spooky D and stock C cover 16 blank Returns. Across Spooky's 100 observed frames,
49 host-layout records keep editor y=571/height=29, reservation=12 and core rows=34.
The caret band has zero or two tall bright columns, never a terminal-width block;
visible extents differ only by the antialias edge. Contact sheets show the native
caret toggling during rapid submit while the footer stays fixed. That remaining
visibility behavior is not claimed perfectly smooth. Identical blank headers
prevent 16 individual key latencies. Stock B's blank burst is outside capture.

Idle sampling drops from 28.62 to 3.86 geometry calls/s (**86.5% fewer**) across
selected quiet intervals; bridge reads remain about 4/s and host sync is zero.
Geometry spans were 585.46→45.19 µs/s, but compilation overlapped these traces:
these elapsed spans are not CPU time or a latency/energy improvement claim.

Final aggregates were rerun with full source→endpoint missing-frame checks,
first-present-after-handler causality, visibility and a prospective ±500 ms
transition guard. Bounds and exclusions remain retained; all logs have zero
dropped diagnostic events. Ten analyzer regressions pass. A transition guard
cannot prove compositor recovery. Invalid candidate scroll C (actions after
capture, raw budget exhausted) remains excluded; narrow D has complete pixels.

Build commands, configuration and fixtures are in [pixel-benchmark.md](pixel-benchmark.md).
Ignored `macos/build-spooky/evidence/2026-11-04-benchmark/` retains raw strips,
logs, per-run `*-provenance.json` hashes/Info.plists, `reference-final-archive/`,
and `*-analysis/` confirmed specs, native endpoints, contact sheets and reports.
Run `uv run --script test/native-input/benchmark_window_pixels.py <confirmed-spec.json> --output <report-dir>`
to reproduce glyph reports. Retained `scroll-state-{inventory,analyze}.py`,
`submit-{inventory,analyze}.py` and `blank-submit-analyze.py` reproduce row/output/
footer reports. Recordings and private indexes are not committed; disposable
comparison builds/worktrees/indexes can be removed after archive verification.

## Post-handler trace and upstream control, 2026-11-03

The roughly 150 ms cold post-handler tail did **not reproduce** in a new
143-character native-scale recording while the initial filename index was
being built. This pass adds passive, opt-in diagnostics and better measurement
qualification. It does not claim that a rendering change fixed the old tail.

| Workload | Checked responses | Median event-to-pixel bounds | p95 bounds |
| --- | ---: | ---: | ---: |
| Spooky, eight plain drafts during cold indexing | 128 | 14.97–31.80 ms | 30.74–48.09 ms |
| Spooky, typing with the `@` picker open | 15 | 27.18–44.31 ms | 36.49–57.72 ms |
| Pristine upstream Ghostty, before a Space transition | 48 | 12.81–30.52 ms | 31.83–69.09 ms |

Spooky's 128 plain responses include 126 newly appearing glyphs and two correct
draft replacements where `#` was already present in the selected old draft.
Excluding those two gives the same medians and p95 30.76–48.12 ms. Target glyphs
and replacement states were checked in native before/after frames, rather than
classifying caret blinking as a response. All 143 responses have raw pixels;
none crosses the prospective 500 ms visibility/Space guard. The menu is a child
window, so its own pixels are outside the recording.

For plain typing, handler completion to AppKit drawing was median **0.328 ms**,
maximum **0.574 ms**. Drawing took median 0.069 ms, maximum 0.127 ms. Recorded
dirty/visible bounds cover the full editor line. The longest plain response was
60.60–77.58 ms: 23.49 ms reached the handler, 24.30 ms was inside it, and only
0.57 ms preceded drawing. The longest picker response was 48.57–79.35 ms,
including 15.87 ms before the handler, 19.81 ms inside it, and 3.52 ms before
drawing. These are remaining cold-input costs, not evidence of a 100 ms
post-handler layout or completion stall. The trace does not identify the
internal AppKit/input-method work behind those handler costs.

The filename helper remained in its initial crawl. In the first enclosing
7.51-second telemetry interval it averaged 42.94% of one CPU core; in the second
7.58-second interval it averaged 1.52%. Thus the sample includes busy indexing,
but is not an isolated experiment establishing index causality.

The reference is pristine upstream commit
`0b1729e945978fca4bcd6165d8ac408bf675a7f2`, with only capture/event diagnostics
and separate app branding. Its renderer, parser, shell integration and core
are unchanged. It is neither the native-disabled fork nor the installed signed
Ghostty 1.4.0 binary. The runs are sequential on the user's actively used Mac,
so the overlapping median intervals do not establish population-level parity.
The reference's first-key upper bound of 156.38 ms has a 133.46 ms observation
gap and a 22.93 ms lower bound; it is not proof of a 156 ms typing stall.

The reference also has a separate **post-Space-transition anomaly**. One entire
draft is unobserved across a roughly two-second capture gap. Later, continuously
observed glyphs took 295.12–312.83 ms and 247.71–265.41 ms despite visible/active
Space flags. These remain reported separately, not removed to improve the
comparison. A 500 ms guard flags nearby transitions but cannot prove that the
compositor or capture stream has recovered. This upstream control does not
identify the cause of the old Spooky tail; it shows why steady typing and Space
transition/recovery behavior must be distinguished.

In the earlier v8 recording the two long Spooky glyphs appeared about 285 ms and
20 ms before the fully-occluded notification. Those original bounds remain
valid captured observations, with a substantial transition confound. The new
traces do not justify inserting synchronous draws, transaction flushes, or a
timer change into the production path. AppKit drawing, window updates and
runloop boundaries are CPU milestones; only the independently checked
WindowServer frames supply the pixel endpoint, and neither measures physical
scanout.

The trace retains bounded coalesced input/revision IDs through text layout,
view drawing, window updates, runloop phases and completion panel work.
Disabled diagnostics create no trace state or observers and do not force
drawing. The offline analyzer now reports nearby transition/coverage issues
separately while preserving all original pixel bounds. Its four qualification
regressions pass. Native checks passed 96 distinct tests across the affected
suites, including the final seven trace/coordinate tests; the diagnostic app
and pristine-upstream builds passed.

Candidate executable SHA-256:
`c35cb3d3dc5fa888bd4ac9da25dd541bb433dd71ca5f7c19e0c2c9a30776ac24`.
Upstream diagnostic executable SHA-256:
`dba85479b79c98fa3b503f959af88521ea6786531ae136ac3de1f7639b3a959b`.
Both use the same own-window recorder at native scale/backing 2×. Narrow lossless
strips prevent the earlier recorder's raw-byte budget from expiring; this is a
measurement correction, not a production rendering optimization.

Local evidence is retained under the ignored
`macos/build-spooky/evidence/v9-final/`: per-event bounds, exact native frames,
the latest raw strips, source/configuration provenance, and verification logs.
Older diagnostic builds, indexes, recordings and comparison checkouts are
disposable after that archive is verified. The installed production app and
current release remain the functional `d4e8cd10b` build.

## Final presentation and interaction checks, 2026-11-03

The final diagnostic candidate adds presentation acknowledgement to the existing
Metal IOSurface layer. A bounded native text echo survives parsed C until the
matching command frame is assigned to that layer; keyboard ownership still
changes at C. The echo has a 100 ms fail-open ceiling and skips commands larger
than 16 KiB. It adds no transcript renderer, filesystem work, or history scan to
the draw path. Empty submissions retain the separate coherent-presentation gate.

Native-scale, own-window recordings on the actively used Mac measured:

| Workload | Qualifying sample | Median source-event-to-pixel bounds |
| --- | --- | --- |
| Warm plain typing, all covered observations | 14 of 16 glyphs | 9.63–31.88 ms |
| Warm plain typing, observation gaps at most 50 ms | 11 glyphs | 13.74–31.32 ms |
| Warm `@ghostty` typing | 8 glyphs | 15.25–31.10 ms |
| Numbered-row wheel scrolling | 16 movements | 22.70–39.77 ms |
| Cold-index plain typing, visible subset | 13 of 16 glyphs | 24.88–81.94 ms |

These are last-absent/first-present WindowServer pixel bounds, not physical
scanout or independent population estimates. The complete warm typing sample
retains its wide observation gaps; the tighter subset is not a replacement for
it. Two initial warm glyphs preceded the first observation. The completion menu
is a separate window, so these numbers measure editor text while it is open,
not the menu's own pixels. Other Xcode jobs were running; our builds and offline
decoding were stopped during capture. No controlled stock-parity or 10× claim
follows from these runs.

One warm 200-row `printf` reached visible output in **45.47–62.86 ms**. Frames
620–623 retain the draft (the native caret disappears at 622), then frame 624
shows numbered output. No blank frame or hollow/block terminal cursor was
observed in that top region; the nearby maximum observation gap was 18.13 ms.
This is one fixture, not proof against sub-frame flashes or every TUI handoff.

The numbered scroll sequence has no missing ROI frames or recorded occlusion.
Its largest upper bound was 59.76 ms. The left footer caption/separator was
byte-identical through 141 observations; the caret kept its vertical position
apart from its blink/antialias edge. In the repeated-Return capture, ten uniquely
identifiable movements were exactly 102 physical pixels (three terminal rows),
with no captured one- or two-row intermediate. Later identical headers and a
183 ms observation gap prevent claiming that all 24 Returns were individually
verified. Scrolling still moves in integer terminal rows.

Cold typing has unresolved tails: two visible glyphs took 133.39–151.07 ms and
129.19–143.94 ms. Their handlers finished at 33.95 ms and 15.11 ms; most delay
followed handler completion. Final observation gaps were only 17.69/14.75 ms,
so this cannot be dismissed as missing capture alone. The filename helper was
still crawling and averaged about 4% of one core in the enclosing interval.
AppKit drawing, transaction publication, compositor work, and host scheduling
are not separated by this instrumentation; index causality is unproven. Cold
picker/submit intervals that became occluded or moved off-Space are excluded.
This remains a performance limitation, not a completed stock-smoothness claim.

Live computer-use checks separately verified the combined suggestion/menu,
Tab acceptance, accent-colored submitted commands, Cmd+F from the editor,
return to inline placement after `clear`, and output-path copying with spaces,
Unicode, and historical working directories. Command-click opened the correct
fixture directory in Finder. Final native verification passed 247 test
declarations / 251 executions across 21 suites; the diagnostic build and strict
code-signature verification passed. The final exact-source presentation/accent
core run passed 84 tests and all 104 build steps. Package metadata guards passed
six tests.

Local evidence: `/tmp/spooky-v8-typing-report.md`,
`/tmp/spooky-v8-typing-analysis.json`, `/tmp/spooky-v8-scroll-report.md`, and
`/tmp/spooky-v8-scroll-events.json`. The diagnostic executable SHA-256 is
`c0b8f7d57e095f69c0c2acf92dc4e440aad6b7f9303083f5ac990ab489d7244f`.
Private raw captures, screenshots, and filename indexes are not committed.

## Timestamped window capture, 2026-11-03

The baseline is `07c87e03f1a398cb148fa0333f68fdd0f433e601`, with only the
diagnostic recorder added. The intermediate candidate adds parser-driven
handoff, fractional scroll remainder preservation, synchronous initial editor
measurement, and lower-priority background filename indexing. The reference
uses the baseline's same core with native input disabled. **It is not the
installed stock Ghostty build.** The subsequent footer/focus/startup changes
must be assessed separately from these intermediate measurements.

The opt-in `CommandWindowCapture` records only its own diagnostic NSWindow,
without audio, microphone, mouse cursor, or other applications. ScreenCaptureKit
display timestamps share the uptime clock with original `NSEvent.timestamp`.
Lossless BGRA regions preserve native pixels for glyph checks; the full movie
supports visual context and Framecap inspection. The recorder and its framework
imports are excluded unless `SPOOKY_WINDOW_CAPTURE` is defined at build time;
that diagnostic build additionally requires the explicit enable flag and output
directory. Normal releases contain neither the recorder nor its call site, and
packaging rejects diagnostic capture/profiling metadata. Raw media and file-search
indexes stay local. `SpookyWindowCaptureVideo=false` selects lossless ROI-only
capture, with identical timestamps and visibility records but no H264 writer.

Each result is an interval from the last frame missing a target glyph/output to
the first frame containing it. Target pixels were checked, rather than treating
caret blinking or arbitrary image changes as a response. This measures
WindowServer presentation, **not physical display scanout or photons**. Capture
records source events, callback delays, frame status, missing pixels, and window
visibility; key loss alone is allowed, while hidden/fully occluded/inactive-Space
intervals are rejected. Observation gaps are not automatically dropped frames.
Run the offline analyzer with `uv run --script test/native-input/analyze_window_capture.py --help`; its
candidate matches remain unconfirmed until the target glyph is inspected.

Native-scale warm runs, with no concurrent build/probe workload:

| Workload | Baseline median interval | Intermediate candidate | Same-core native input off |
| --- | ---: | ---: | ---: |
| Plain typing, 16 glyphs | 20.28–44.18 ms | 19.29–36.07 ms | 23.41–40.54 ms |
| Typing `@ghostty`, 8 glyphs | 42.08–64.42 ms | 26.47–43.72 ms | — |
| Wheel event → numbered-row movement | 38.71–60.69 ms | 35.50–56.55 ms | 14.58–32.16 ms |

Plain-typing p95 intervals are 49.61–75.56, 35.36–54.88, and 31.69–49.04 ms,
respectively. Typing intervals overlap; this does not establish a general ranking.
Scrolling remains slower than the reference in this run. Baseline/reference
scroll summaries contain 16 events each; the candidate contains 14, excluding
two wide observation gaps (79.1/67.1 ms) from the tight-interval summary while
retaining them in the raw report. All 48 movements were visually confirmed.
Source-to-handler medians across all 16 scroll events were 16.610/8.845/2.554 ms;
the handlers themselves took median 7.75/9.90/6.56 microseconds. No host layout
or bridge-event burst explained the queue gaps. The loaded filename index was
still replaying filesystem events, at unequal load between runs: "ready" does
not mean idle. This is a comparison confound, not proof of an indexing feedback
loop or a renderer-only cause.

One `printf` submission printing 200 numbered rows reached visible output in
57.38–75.33 ms before and 14.48–31.95 ms in the candidate; the reference was
28.99–42.99 ms. Baseline capture frame 1284 (Framecap 27.173333 s) is blank
between draft and output frame 1285 (27.191667 s). Candidate retains the draft
through frame 1240 (21.006667 s), then shows output in 1241 (21.023333 s).
This supports removing the blank handoff frame for that fixture, not a 10× claim
or a latency percentile. Input queue delays differ between these trials.

Rapid bursts sent 24 Return events per run, not hardware autorepeat. Baseline
accepted 10 over a 530.85 ms source burst; candidate accepted 14 over 231.65 ms.
These are not controlled throughput figures. Frames show two-row output advances
and a later completed-header placement, rather than a captured one-row advance.
That evidence motivated fixing parsed-header ownership and footer accounting;
it does not justify an artificial rendering hold.

Earlier cold-index pilot captures used a slightly resampled canvas and different
load/cadence. Their candidate typing intervals were worse (eligible median
22.90–53.83 ms versus 14.02–32.61 ms), with higher capture callback delays.
They establish neither an improvement nor a clean regression attribution. Do
not omit that pilot or combine it with native-scale warm results.

Local evidence: `/tmp/spooky-warm-v3-glyph-reference.{json,md}`,
`/tmp/spooky-submit-pixel-report.{json,md}`,
`/tmp/spooky-scroll-pixel-report.md`, `/tmp/spooky-scroll-work-audit.json`, and
`/tmp/spooky-key-to-pixel-confirmed.{json,md}`. Native capture directories use
`/tmp/spooky-pixels-{baseline,candidate}-warm-v3-capture` and
`/tmp/spooky-pixels-core-reference-capture`. The per-event reports retain exact
frame IDs, timestamps, exclusions, and source-to-handler delays.

### Shell work and rendering corrections

Parsed primary B/C boundaries now wake the serialized state/geometry observer
after releasing the terminal lock. Eight bounded 1 ms retries handle a busy
snapshot; the ordinary 33 ms observer remains recovery, rather than the primary
handoff clock. Presentation retains the draft's block ID until matching parsed
readiness, including C and the next B arriving together. It does not optimistically
clear input or release terminal cursor ownership.

The adapter skips publishing the old generation's ready state after a native
accept. A paired configured-shell ABBA probe (30 samples per variant) measured
trigger-to-new-ready-and-matching-B median 6.069→5.299 ms, p95 6.761→5.924 ms.
The traced path dropped from 13 to 11 atomic state publications; worker creation
still costs about 2.3 ms. This is a modest shell-only improvement, with normal
user startup and hooks preserved. Evidence: `/tmp/spooky-shell-stage-report.md`.

Precision scrolling now subtracts only emitted whole-cell pixels from its
accumulator, retaining fractional overshoot on both axes and direction changes.
The previous inherited calculation effectively discarded that remainder.
Rendering still advances by terminal rows; this is not fractional-pixel scrolling.
Background names-only index/apply/recovery workers use background QoS; interactive
query/FSEvents work retains its previous priority. This preserves search coverage
and trades some cold-index throughput for foreground responsiveness, without
claiming the priority change alone caused the measured UI differences.

### Follow-up footer, focus, and startup changes

The intermediate recording exposed about 42 extra points between the final
historical block and the docked input: two real prompt rows remained inside the
grid while the same header/editor space was reserved outside it. The follow-up
uses the same compact grid reservation for inline and docked editing, covering
only a validated empty A/B tail with an opaque footer in the existing Metal
command batch. One resolved boundary now governs cells/images, captions, path
hits, selection, page movement, and the scrollbar. Subtracting the same covered
rows from scrollbar total and visible length preserves its maximum offset.
The AppKit scrollbar thumb uses that effective visible fraction.

Validation examines at most two prompt rows and an O(1) Kitty-placement check;
it does not traverse history or perform I/O. Raw, alternate, continuation,
overwritten, stale, or image-bearing tails retain the full reservation.
While editing, background output revokes the core crop immediately; AppKit's
opaque editor can remain until its next geometry update and fallback resize.
During submission, the existing transfer policy retains the composer over ZLE
echo until the shell boundary. An empty submission's pre-B hook output can also
remain behind that composer even when the frame-retention gate fails open;
the gate itself does not guarantee immediate visibility through the native
overlay. Program output after C uses the ordinary terminal path. The core resize now
preserves native-owned prompt cells instead of clearing background bytes as ZLE
input. A separate private-PTY probe confirms that ZLE itself still emits CR and
erase-to-end on SIGWINCH: completed lines survive, but partial output without a
newline can be erased by the shell. The change does not filter those escapes or
replay output. Core preservation is not a same-frame whole-composition guarantee.

Completed header visibility follows the parsed prompt ID, so terminal rows and
their historical captions need not wait for a separate GUI metadata publication.
Native NSTextView focus now counts as focus for its selected active terminal
pane; previously it explicitly marked the core unfocused and lowered renderer
thread priority. Inactive windows, other panes, hidden editors, and modal/search
responders remain excluded. Cursor suppression is independent of focus.

Initial native horizontal/bottom padding is seeded after resolving an actual
interactive zsh command and before PTY initialization. A core regression
reproduces the old startup defect: shrinking columns after ZLE writes its
full-width blank PROMPT_SP line reflows that line and moves B down one row.
Preseeding avoids that native-padding resize. This does not replace upstream's
initial drawable/backing-size negotiation. Editor font measurement is available
synchronously before subsequent reservation calculations; unchanged viewport
presentation skips the new core setter and terminal mutex entirely.

These follow-up changes have source/regression evidence and the separate
captures below; do not attribute the earlier table to this later build.
The final focused core run passed 168 tests (one optimized-only benchmark
skipped), and the native verification runs passed 109 distinct Swift tests.
The combined Swift run initially exposed a fixed-sleep assumption in a
completion test; awaiting its observable request resolved that scheduling
failure, with the complete editor and scroller suites passing on rerun.
The ReleaseFast core and ReleaseLocal diagnostic app both built successfully.
Logs: `/tmp/spooky-viewport-core-tests-final.log`,
`/tmp/spooky-viewport-swift-tests.log`, `/tmp/spooky-viewport-swift-retest.log`,
and `/tmp/spooky-pixels-candidate-v4-build.log`. All 69 shell PTY tests passed
earlier in this pass; the adapter has not changed since that run.

### Follow-up pixel checks and remaining two-step Return

The first v4 attempt became occluded and moved to an inactive Space before
typing. Its stale Metal pixels are excluded, even though accessibility kept
reporting live content. A second, visible v4b capture confirmed that the extra
two-row gap disappeared: the final numbered output row moved 68 native pixels
closer to the unchanged footer. Wheel scrolling and a subsequent real scrollbar
thumb drag kept the editor fixed. The thumb moved from 1 to 0.571428 and back to
1. Native scrollbar coordinates were checked against the visible overlay.

In that v4b run, 16 plain glyphs had median bounds 11.06–27.38 ms, and eight
picker glyphs 14.54–31.04 ms. Sixteen ordered scroll movements had median bounds
28.92–45.72 ms (p95 39.41–56.03 ms). One pair of closely spaced source events
required matching the distinct numbered-row positions instead of assigning a
frame to the nearest event. The nonoverlapping subset of 15 events was
28.85–45.27 ms. Index replay used about 26% of one core, and input cadence also
differed from the earlier runs; these are observations, not a controlled speedup.

The same live test caught a keyboard-routing regression from the focus fix:
Cmd-V reached the terminal instead of NSTextView. Its nonempty submission is
excluded. Pane focus now controls renderer priority while actual first-responder
ownership controls terminal keyboard bindings. An offscreen native-window test
covers multiline paste, Cmd-A, Cmd-F, and restoration of terminal ownership.

The corrected v5 recording verified the command in the native editor before
Return, then traced native acceptance and the matching parser boundary. One
200-row `printf` submission retained the draft until output, with visible-output
bounds 30.03–64.05 ms. Plain typing had median bounds 13.98–30.99 ms. Seven of
eight picker glyphs have wide observation bounds and are excluded from a tight
summary, while retained in the report: observation gaps reached 95.80 and
73.25 ms, and capture callback backlog reached about 165 ms. No capture status
reported missing, idle, or suspended frames. UI processing continued; the first
`@` handler itself took 20.23 ms, so both real cold-popup work and the recorder's
encoding/write queue need separate attention. Index CPU during this interval
was about 0.53% of one core, not a full cold crawl.

Unlike the earlier coarse capture, v5 resolves a real one-row intermediate:
Framecap frame 1415 at 36.873333 s shows row 0186; frame 1416 at 36.890 s shows
0187 without the completed header; frame 1417 at 36.906667 s shows 0188 and the
header. The consecutive source-frame gaps were 15.95/16.85 ms and visibility
remained valid. ZLE's accept-line newline precedes the later tagged A/newline/B
prompt redraw. This is the remaining coherent-presentation defect, not evidence
that the footer itself moved.

The subsequent candidate adds an empty-submit presentation gate immediately
before the native widget trigger. Parsing continues, but the renderer retains
its previously drawn frame while only the old B's blank tail has changed.
The next B or C, visible output, raw/alternate/continuation input, scrolling,
selection, resizing, or other terminal interaction releases it. Inspection is
bounded to the final two command records and eight tail rows. A 100 ms absolute
watchdog is a fail-open ceiling, not a minimum delay; repeated requests cannot
extend it. Split PROMPT_SP writes exposing visible `%` fail open, so the gate
does not hide arbitrary shell-hook output. This leaves custom or fragmented
shell output on the normal render path. Pixel verification is still pending.

The first completion panel is also prepared, hidden, after a 150 ms quiet ready
prompt interval. Typing restarts that timer, and detaching/disabling cancels it.
This moves unavoidable AppKit construction off the first `@` keystroke rather
than reducing total construction work. It neither shows the panel nor starts a
query. A separate construction timing distinguishes this cost from row layout.

Path interaction uses the existing GPU chrome/text batch and font atlas. Active
hover validation reads only its bounded line or cached header. Initial historic
ownership lookup has a shared 256-page-link budget, and unresolved relative
names retain normal selection. Filesystem validation is off the UI actor with
an expiring bounded cache; no renderer/frame callback performs file I/O.

The combined candidate core run passed 125 tests with one intentional benchmark
skip, and the ReleaseFast framework completed all 243 build steps. Nineteen
native suites then passed 225 test declarations / 227 executions including
parameterized cases, with no failures or skips. These cover the new path
resolver/click/drag lifecycle, popup preparation, submit-gate ordering, focus and
keyboard routing, editor behavior, and scroller synchronization. Logs:
`/tmp/spooky-path-gate-core-tests.log`,
`/tmp/spooky-path-gate-releasefast.log`, `/tmp/spooky-v6-native-tests.log`.

Local evidence: `/tmp/spooky-v4b-pixel-report.md`,
`/tmp/spooky-scroll-footer-v4b-report.md`,
`/tmp/spooky-v3-v4b-footer-native.png`, `/tmp/spooky-v5-pixel-report.md`, and
`/tmp/spooky-v5-one-row-intermediate-native.png`. Source captures are
`/tmp/spooky-pixels-candidate-footer-v4b-capture` and
`/tmp/spooky-pixels-candidate-routing-v5-capture`. V5 has no completed scroll
workload because computer use lost the visible window before those events.

### V6 lossless ROI repeat

The v6 warm-index repeat disabled H264 and captured a native 600×250 region.
All 24 typed glyph endpoints remained visible with no visibility exclusions.
The native editor's pasted `printf` value was verified before submission. The
entire typing, picker, submit, 24-Return burst, and 16-wheel-event workload ran
in one computer-use call, avoiding the long inter-action pauses of earlier runs.

| Workload | Median source-event-to-pixel interval |
| --- | ---: |
| Plain typing, 16 glyphs | 11.38–28.95 ms |
| Picker typing, 8 glyphs | 13.04–30.00 ms |
| Scrolling, 15 identifiable movements | 31.56–48.82 ms |

The first `@` handler fell from 20.23 ms in v5 to 4.16 ms; hidden startup
construction took 4.41 ms. Its actual visible interval, however, was
29.64–51.79 ms versus 29.09–48.60 ms in v5, and its input queue wait increased
from 3.37 to 13.87 ms. This demonstrates moving construction off the keystroke,
not an end-to-end speedup. The helper was ready/replaying in compaction, using
about 6.3% of one core over the enclosing sample; two query timings reached
319.5 ms. This was not a fully idle index or a fresh initial crawl.

Thirteen identifiable Return transitions moved directly by two rows, with zero
one-row intermediates across 87 Return-phase observations. Twelve tight empty
Return bounds had median 48.31–66.09 ms. Later identical blank headers and
50.94/66.59 ms observation gaps prevent certifying every accepted Return.
The footer lies outside this ROI. One nonempty submit retained its draft until
output, but its bounds were wide, 43.41–93.59 ms, across a 50.18 ms observation
gap. This is excluded from a tight-latency summary and does not support a
submit-speedup claim.

The final wheel event returned the host to live end but changed no distinguishable
ROI pixels because identical headers repeated there. Its pixel latency is
excluded rather than calling it a dropped event or a no-op. The other 15
movements have nonoverlapping intervals with gaps at most 30.78 ms; p95 bounds
are 49.83–68.24 ms. Raw-only capture still had callback lag near 146 ms and a
105.5 ms gap after the final picker glyph appeared, so H264 was not the sole
source of observation delays. All endpoints remain WindowServer observations,
not physical scanout.

Evidence: `/tmp/spooky-v6-pixel-report.md`,
`/tmp/spooky-v6-glyph-analysis.json`, `/tmp/spooky-v6-submit-analysis.json`,
`/tmp/spooky-v6-return-analysis.json`, and
`/tmp/spooky-scroll-v6-ordered-analysis.json`. Capture:
`/tmp/spooky-pixels-candidate-warm-v6-capture`; source hashes:
`/tmp/spooky-pixels-v6-source.json`. V6 predates the subsequent two-row header
spacing and multiclick fixes; those require separate native/pixel checks.

### V7 cold-index follow-up

A fresh private index was still crawling during the native-scale, raw-only V7
capture (two-row headers, before the presentation acknowledgement fix).
Sixteen plain keys had a median source-to-visible interval of 10.60–26.89 ms
and p95 23.24–39.76 ms. Eight `@ghostty` keys had a median of 11.98–28.65 ms
and p95 40.41–57.77 ms. The keys arrived in short bursts, producing six and
three distinct endpoint frames respectively; these are correlated per-key
bounds, not 24 independent display updates. No target interval had a visibility
exclusion or observation gap over 50 ms. The warm V6 intervals overlap these
results; this is not evidence of a cold-index speedup.

The helper remained in `crawl`, not ready, and used 1.310 CPU seconds across a
1.067-second bracketing interval (about 1.23 cores). This establishes concurrent
indexing, not its causal contribution to any individual keystroke. The first
`@` handler took 5.57 ms. The separate popup window is excluded from this
own-window ROI, so these numbers measure typed glyphs rather than result latency.

The nonempty `printf` fixture reached numbered output in 42.55–59.72 ms.
Frame 1370 retained the draft, frame 1371 at 22.913865 s showed a blank region
under the cwd, and frame 1372 at 22.931038 s first showed output. This is a real
observed blank intermediate outside the empty-submit gate. The shell boundary
and native handoff occurred 12.73 ms after the source event, before these pixels.
This motivated a separate acknowledgement from actual Metal layer assignment,
while retaining immediate shell input ownership at the parsed boundary.

The rapid-Return and scrolling actions occurred after this 35.031-second
recording ended; their CPU logs cannot establish pixel latency or coherence.
A separate footer run exhausted its raw-pixel budget before its first keyboard
input and is also excluded from those claims. Private reports and exact frame
IDs are in `/tmp/spooky-v7-cold-pixel-report.md` and the accompanying glyph,
submit, and workload JSON files. Neither recording qualifies final spacing or
scroll smoothness.

## Automatic completion and folder browsing

The completion controller now owns debouncing, cached matching, popup state,
and inline suggestions separately from native text editing. Candidate tokens
are decoded and Unicode-normalized once per result set. An optimized Swift
microbenchmark alternated the prior and indexed helpers over the same 200
Unicode path candidates and 2,000 queries, after 200 warmups:

| Cached matching helper | Median | p95 |
| --- | ---: | ---: |
| Prior implementation | 260.67 µs | 298.50 µs |
| Pre-normalized index | 16.25 µs | 18.58 µs |

This measures the matching helper only, excluding AppKit, shell execution, and
IPC. Source hashes and raw results are in
`/tmp/spooky-completion-index-benchmark.json`; reproduce through Pat with
`test/native-input/benchmark_completion.py --baseline-ref <prior-commit>`.

Separately, packed shell responses reduce per-candidate file operations. Private
PTY fixtures measured response publication with a 1 ms observation bound and
20 warm samples per query, following one cold request:

| Shell query | Before warm median | Packed response warm median |
| --- | ---: | ---: |
| `git che` | 24.68 ms | 20.81 ms |
| `git ` | 53.79 ms | 28.33 ms |
| `cat ` | 30.50 ms | 10.68 ms |

The packed run's cold Git requests still took approximately 129 ms. These are
synthetic-HOME shell response timings, not inline-suggestion appearance or
Enter-to-screen measurements. Local artifacts are
`/tmp/spooky-completion-latency-before.json` and
`/tmp/spooky-completion-latency-packed.json`. Completion response observation
now uses directory events and a timeout instead of a recurring 20 ms poll.

No renderer pipeline was added: command captions and directory-path hit bounds
use Ghostty's existing renderer. Path hit testing occurs on clicks; an open
folder popover revalidates its anchor only when its layout context changes.
The AppKit tree reuses outline rows and loads expanded folders on a filesystem
actor, with at most 1,000 entries per folder and an explicit truncation row.

Automated validation covers 136 native cases across the combined and final
targeted runs, all 98 selected core tests, and all 50 zsh PTY tests. The combined
native run passed 135 cases; correcting the new AppKit geometry test's
flipped-coordinate assumption left both scrollbar-track tests passing on rerun.
Logs are `/tmp/spooky-final-native-tests-footer.log` and
`/tmp/spooky-final-scroller-track-tests.log`. The native `ReleaseFast` core build
completed 243 steps. All nine directory-popover tests passed, and a live recheck
confirmed that the tree opens above the docked header with readable filenames.
The measurements above do not establish end-to-end UI latency or rendering parity.

## Stable docking and scrollbar synchronization

The current draft now docks once a pane has actual scrollback and remains docked
when the viewport returns to the live bottom. Previously, switching between
inline and docked layouts at that boundary changed the PTY height by three rows,
which could reflow output and move the scrollbar beneath the user. Docking is
now a latched per-pane presentation decision; a new pane still starts inline.
The renderer omits the original current caption while drawing its pinned copy,
so the same command header is not displayed twice.

The native scrollbar track now ends above the complete docked header/editor
using `NSScrollView.scrollerInsets`. Previously the opaque editor could cover
the live-end thumb. This changes only the track geometry, retaining the full
Metal drawable, clip-view dimensions, document range, and PTY size. Identical
insets skip tiling. AppKit regressions check actual track/knob rectangles and
unchanged content geometry, including restoration when the footer disappears.

Scrollbar dragging retains its fractional terminal-row position while new
output, font metrics, or editor reservations alter pixel geometry. Ordinary
core acknowledgments cannot move an active drag. Releasing the drag settles on
the integer row already requested, rather than jumping to a stale core offset.
Regressions cover these docking and drag transitions; they do not measure
scrolling frame times. A live candidate rendered 1,500 Unicode lines; repeated
wheel transitions from the live end into history and back kept the current
header/draft at the same positions, without a duplicate caption. Physical thumb
dragging remains unqualified: automation missed the thumb, and setting its
accessibility value did not dispatch a scroll action.

After release, later core snapshots still apply normally; there is no
sequence-based rejection of an older acknowledgment queued before release.
The shared terminal grid also retains the primary prompt's blank rows above
the footer; this change does not remove or remap those terminal rows.

A sample taken during a computer-use timeout showed the main thread waiting
for application events and the renderer sleeping in `kevent`. Physical footprint
was 94.1 MB at that sample and 320.1 MB peak. No application freeze was observed
in that capture, but it does not explain every automation timeout or establish
performance parity. Evidence: `/tmp/spooky-docking-window-sample.txt`, sampled
from the separate Render Check candidate. Live Cmd+F from the docked editor
found all 1,501 occurrences of `café` in the command plus output, and Escape
returned to the unchanged two-line draft. Tree labels, folder expansion, and
Escape dismissal were also observed. The Mac then locked during another tree
interaction, preventing further physical-thumb qualification.

The normal app was separately built and signature-verified at
`macos/build-spooky/delivery/ReleaseLocal/Spooky.app`; executable SHA-256:
`7724b66d8e7d7dfa6997404ccba51f68155efd49cc254523d32701825c143f19`.
The user's earlier app remains running. The historical checks below concern
earlier candidates and do not certify this new delivery bundle's live behavior.

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

That revision's regular Spooky bundle (SHA-256
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

## November 3: docking, shell and filename-search integration

These measurements used controlled synthetic zsh fixtures on the user's busy
Mac. The before/after command runs were interleaved; they are not idle-machine
or whole-app latency claims. Native submission includes the request-file bridge
and waits for the next ready prompt.

| Operation | Before median | After median | Scope |
| --- | ---: | ---: | --- |
| Native command submission | 40.71 ms | 16.88 ms | Same synthetic repo/compsys, 20 samples per side; p95 47.94 → 21.69 ms |
| Raw builtin prompt round trip | 40.98 ms | 17.10 ms | 40 interleaved samples per side |
| First history snapshot, 100,000 stored events | 440.80 ms | 77.32 ms | Same 1,000 returned entries; byte-identical packed payload |
| First history snapshot, 10,000 stored events | 96.30 ms | 78.54 ms | Same payload |
| Caption lookup, 1,000 headers at history top | 8.153 µs | 0.375 µs | CPU lookup only, 27 pages, paired Fast benchmark |

Small histories showed no reliable gain (1,000 entries: 64.38 → 72.12 ms in a
noisy eight-sample run). Their existing bounded array enumeration is preserved.
Metadata output is unchanged: 483 files / 10,063 bytes over 60 commands.

Ordinary branch captions now read Git reference files directly, without a new
Git process per prompt. Unusual layouts and explicit Git overrides still use
Git. Recent dense history avoids sorting the entire history map; sparse event
IDs retain the exact-order fallback. The completion worker still starts per
prompt because reusing it would make the inherited shell environment stale.

Normal text edits no longer publish a full host presentation. TextKit already
owns the edit and separately reports height changes. Recovery controls still
update. Geometry-only suggestion updates reuse their existing text projection.
Focused tests check these notification and invalidation paths.

Caption lookup now visits only pages intersecting the viewport. It allocates
no additional lookup memory and retains no new state. The savings above are
microseconds, not evidence of a comparable improvement in frame or Enter
latency. Reproduce with `test/native-input/benchmark_command_chrome.py` through
Pat; the script runs Debug regressions and derives a Fast root-module benchmark
because the repository's normal test root is fixed to Debug.

Two live process captures had median CPU estimates of 0.5% and 1.0% of one core.
Their stack captures included mixed input/accessibility activity or idle waits,
and computer-use scrolling lost visibility while the user changed desktops.
They do not establish a matched scrolling or idle comparison. No sustained
renderer CPU bottleneck was established by those captures.

Normal app launch starts one persistent filename-search helper. Its pinned fsearch
patch disables content indexing and keep-warm spinning, bounds search workers
and initial crawl concurrency to two, and lowers background indexing priority.
It uses a private index and exits when its stdin closes. Queries and responses
are bounded, superseded results are discarded, and nonblocking pipe writes fail
and restart the helper instead of blocking cancellation behind a full pipe.
Directory listing is immediate and bounded; nonempty folder searches query the
index rather than filtering an arbitrary prefix of a large directory.

The integrated AppKit build was also exercised through computer use: a fresh
short session stayed inline; 120 output lines docked the editor; repeated scroll
gestures kept it fixed; `clear` returned it inline. The file picker opened on a
typed `@`, navigated into a directory with Down/Tab, searched descendants,
inserted a relative path with Return, and restored the query with one undo.
Cmd-F from the editor opened terminal search; shell completion displayed only
the candidate token in the same shared material surface.

A subsequent ten-second idle capture of that app had median CPU usage of 0.5%
of one core, maximum 3.6%, and stable RSS of about 243 MiB. The app was initially
visible, but desktop activity was uncontrolled. This is a separate observation,
not a matched before/after rendering benchmark. The filename helper is measured
separately; its initial filesystem crawl is not included in the app's CPU figure.

On November 3, the first helper had finished indexing 18,185,776 entries and
2,430,840 directories into a 332.7 MiB name index. There was no content-index
directory. At about eight minutes after helper launch, `ps` still reported
roughly 1.1 GiB RSS, but `sample` reported about 8.1 MiB current physical footprint
and a 1.1 GiB peak. `vmmap` showed 7.3 MiB of live malloc allocations, about
730 MiB of empty/reclaimable malloc pages, and 212 MiB of clean resident mapped
index pages. RSS therefore does not describe the live heap or non-reclaimable
memory cost here; the initial crawl did have a substantial transient peak.

Two five-second stack captures showed stdin and query workers waiting, with
the filesystem updater waiting about 94% and 99% of sampled time. Active updater
stacks performed directory listings and applied FSEvents; no warm-spin thread or
content worker existed. A separate 20.01-second observation accumulated 4.71 CPU
seconds in the helper (23.5% of one core), versus 0.19 seconds in the app (0.95%).
Desktop/filesystem activity was uncontrolled, and these samples are not a steady
idle benchmark. The evidence motivated an experiment batching names-only events
for 250 ms before existing deduplication, rather than changing allocation policy
based on RSS. That experiment was subsequently rejected; the shipped helper
retains upstream's existing event scheduling.

Index startup now happens at app launch, as requested, instead of waiting for a
filename query. The picker asks the engine for actual readiness and displays
“Initial search index is being created…” while loading/building is pending;
status requests do not replace searches. The cached index is reused on later
launches. The first-crawl measurements above predate the eager-start change.

The eager-start candidate with experimental batching was launched before any
editor input. A separate 20.01-second window measured 2.73 helper CPU seconds
(13.64% of one core) and 0.12 app CPU seconds (0.60%). Its helper physical footprint
was 8.8 MiB, live malloc allocations were 9.3 MiB, and RSS was about 1.35 GiB.
This window was about two minutes after launch with uncontrolled filesystem
activity. It is not a matched comparison with the earlier window and does not
establish a steady-idle cost or a CPU improvement.

A bounded paired experiment ran old/new helpers against disposable APFS-cloned
indexes, with the original personal index left unchanged. Both could find the
1,200-entry fixture before the workload. During 346 renames over a 10.50-second
observation, the old helper used 6.49 CPU seconds (61.8% of one core) and the
batching helper used 6.28 seconds (59.8%). The final rename appeared after 212 ms
in the old helper and 1,666 ms in the batching helper; both removed the old name.
Warmup reached visible results after 1.62 seconds plus a one-second pause, which
does not prove cached-index replay and initialization had fully settled. Other
filesystem activity and the app's additional watcher were uncontrolled. These
limits prevent attributing the small CPU difference solely to batching. Because
the observed freshness was worse without a convincing CPU benefit, the 250 ms
batching change and its two tests were reverted before release. Startup/status,
names-only indexing, bounded workers, and cancellation remain.

The paired helper hashes were `abbb0614cd994435ad0476bed8336230104fcfdf14eb407025af94afd251b713`
(old) and `0e19d52ba68fed07e0bd44ef77220d33b542851a60ccc9c23ef974ccb20bdc94`
(rejected batching candidate). The final patch hash is
`f2536ff72b1d34a2eddf3c43fa485744257e6ae0ffa0f1a6318f4cb0db4a8f00`.
The measurements above must not be presented as final-build idle qualification.


## November 3: index worker policy and live compositor capture

The next candidate makes background worker policy explicit: the global index
pool, subtree enumeration, and recovery stat pools use utility QoS and at most
two workers. Previously recovery could create 12 stat workers and subtree scans
four; several pools inherited priority. The separate two-worker filename query
pool and FSEvents delivery retain user-initiated QoS. A process-isolated helper
initializes this policy before any index work. Three focused upstream fixtures
(including actual `pthread_get_qos_class_np` checks) and seven helper fixtures
passed. The measured candidate's pre-signing helper hash was
`b386865d59713ab950014edb44848efbffd97d5bf3a643406bb9db703cac0b54`;
its patch hash was `b22b21be969f36fd91b8552a5c2d849309c6244a0f03cc20daa73fe8941fe831`.
This establishes bounded worker priority/concurrency, not an isolated latency gain.

Opt-in diagnostics distinguish crawl, build, save, prefault, access rescan,
replay/live updates, compaction, relisting, and waiting. A searchable `ready`
index can still be doing background work. The candidate's private fresh index
crawled about 18.2 million names in 151.99 seconds, then built in 2.77 seconds
and saved in 0.20 seconds. This is one loaded-machine observation; filesystem
cache state, other jobs, and the normal app's watcher were uncontrolled.
No personal index was deleted or replaced. See the
[helper diagnostic settings](../../scripts/spooky/fsearch/README.md) for the
opt-in log path and disposable index-directory override. Records contain no
filenames, query text, or file contents.

A 90-second Instruments 27 `Hitches`-only capture targeted the diagnostic app.
The window was explicitly verified visible for the following intervals; earlier
occluded-window observations were excluded. The index was ready throughout,
with normal event updates interspersed with waits. Its helper used 20.38 CPU
seconds over an 89.31-second sampled interval; this was active desktop/filesystem
use, not an idle qualification.

| Visible workload | App-tagged updated-frame records | Hitch intervals | Total hitch duration |
| --- | ---: | ---: | ---: |
| 16 alternating scroll gestures, 10.80 seconds | 531 | 8 | 166.67 ms |
| 20 typed keys and 12 completion-list arrows | 17 | 1 | 16.67 ms |
| Eight separate empty Return presses | — | 0 | 0 ms |

Frame counts use matching swap/surface IDs between `hitches-updates` and
`hitches-frame-lifetimes`, within the recorded action windows plus 200 ms to
include trailing work. They are compositor records, not an FPS result. Their
exported lifetime duration is not a verified input-to-display latency: this
schema provides no explicit first-presentation field. Joining an input to the
next app update is only temporal association, with no causal input-to-swap ID.
One successful empty Return had no qualifying app update within 500 ms, showing
that this join also misses some terminal-only updates. Accordingly, neither the
raw frame lifetime nor the next-frame association is reported as key-to-pixel
latency. CPU input/submit milestones are separate measurements.

The full `Animation Hitches` template was too intrusive here: a 30-second
baseline generated about 17.5 GiB of temporary trace data and took roughly four
minutes to finalize to 1.2 GiB. Its workload and overhead were not matched to the
candidate, so it supports no before/after improvement claim. The minimal
90-second capture saved about 22 MiB. Run bounded captures through Pat, for example:

```sh
pat run --on local --cost heavy --cores 1 -- 'xcrun xctrace record --instrument Hitches --attach <candidate-pid> --time-limit 90s --output /tmp/spooky-hitches.trace --no-prompt'
xcrun xctrace export /tmp/spooky-hitches.trace --toc
```

Export the schemas actually present in the trace; the installed Legacy Hitches
schema names differ from Instruments 27's current names. The full baseline's
`displayed-surfaces-interval` populated `cpu-to-display-latency` for only four
records. Apple's installed display-model rules compute that field only when an
app command-buffer dependency supplies a commit timestamp; merely adding the
Display instrument does not guarantee it, and it still is not a keyboard-event
latency. No GPU-completion timestamp was treated as a display timestamp.

Private artifacts for this capture are `/tmp/spooky-latency-candidate-hitches-90s.trace`,
`/tmp/spooky-candidate-visible90-report.json`, and `/tmp/spooky-visible-captures.json`.
The remaining measurement gap is a causally matched visible-pixel endpoint during
an active initial crawl, with identical instrumentation and workloads on both builds.

### November 3: live native input and prompt handoff

The supplied startup/newline recording was inspected with Framecap's persisted
motion/OCR layers and native source frames. In native extraction
`native-000004400000-000004470000-png`, `f000001.png` at 4.400 s shows the guessed
“local zsh” caption; `f000005.png` at 4.466667 s shows the real directory and a
one-row transcript displacement. The recording has no input-event clock, so it
establishes visible instability, not a key-to-pixel latency number. Private
recordings, screenshots, traces, and filename indexes remain outside Git.

Separate ReleaseLocal baseline and candidate apps used the normal configured
zsh, anonymous event timestamps, private search indexes, and real CUA key/wheel
input. The host remained in use. Native input instrumentation is opt-in and
writes bounded JSONL batches from a utility queue, never from keyDown. The
baseline is source `330d17908` with instrumentation only; the candidate includes
the changes in this commit. The final OS prose-prediction settings and capped
width-measurement optimization were added after these timing captures; the
numbers below do not claim their benefit.

Eight docked empty Returns per version, with a ready index:

| Application milestone from handler entry | Baseline median / max | Candidate median / max |
| --- | ---: | ---: |
| Terminal dimensions ready | 28.014 / 30.928 ms | 0.805 / 1.530 ms |
| Shell receipt observed | 35.041 / 42.404 ms | 5.251 / 11.524 ms |
| Native ownership handoff released | 51.793 / 64.449 ms | 24.890 / 50.427 ms |

Including event queueing, event timestamp to handoff median was 56.092 versus
25.411 ms. These are application milestones, **not display presentation**.
Every baseline trial reserved 46→0→46 points and resized the core 32→34→32 rows.
Every candidate trial retained 46 points and 32 rows throughout. The baseline
restored its final grid 79–105 ms after handler entry. Empty commands now avoid
that reflow entirely. Long-running commands still release native input space
when the parsed command boundary gives ownership to the terminal; a fast command
may also take that path when its next ready prompt is not yet known.

A ready file is no longer sufficient to present a new prompt: a durable matching
primary B marker must have reached the terminal parser. This fixes startup and
empty-command races without requiring an on-screen cursor when drafting while
browsing history. Unknown block metadata is omitted until available rather than
rendering a guessed caption. Initial readiness wakes geometry observation
immediately instead of inheriting a dormant 250 ms polling interval.

Autocomplete measurements:

| Workload | Baseline | Candidate |
| --- | ---: | ---: |
| Five cold-index query letters: median text-change→popup CPU stage | 3.927 ms | 0.087 ms |
| Twenty ready-index edits: median popup CPU stage | 2.625 ms | 0.085 ms |
| Same ready burst: table reloads | 21 | 4 |
| Same ready burst: labels shaped for width | 500 | 120 |
| Same ready burst: total popup CPU work | 59.79 ms | 11.00 ms |

Unchanged initial-index retries previously rebuilt visible rows once per second
(~4.4 ms each); the candidate emits no redundant popup updates during that idle
retry state. New queries clear superseded rows and cannot accept stale results.
Rendered-label equality reuses table presentation without reusing stale insertion
ranges. The candidate did resize its popup four times versus once in that warm
burst; these captures do not establish that pending-state transitions are
visually perfect. Width measurement now stops once its monotonic 420-point cap
is reached, preserving the exact width without shaping the remaining labels.

A 30-second, 5 ms-interval stack sample during repeated typing found 4,837 of
5,123 main-thread samples in the run-loop wait (94.4%). Of 50 sampled native
keyDown stacks, 25 waited in WindowServer's SLSObscureCursor call and 25 used
AppKit's text input context. Width measurement appeared in 39 samples, versus
10 cell constructions; cells already use NSTableView's reuse mechanism.
Sample counts overlap and are not CPU milliseconds. The pointer IPC is evidence
of an OS wait, not proof that all remaining outliers share that cause or that
CUA caused it. NSTextView's normal keyDown/input-method path is preserved.
AppKit prose, inline, and math prediction are disabled for the shell editor;
its own shell/file completions remain, and marked-text handling is unchanged.

CUA screenshots confirmed output, native multiline growth, docked scrolling,
return to inline placement after clear, and raw `cat` input followed by return
to the editor. Screenshot calls serialize behind injected actions: observed
first-change upper bounds were hundreds of milliseconds and cannot resolve the
actual short display latency. The compositor limitations and observed hitches
are recorded above. This work does **not** establish a 100× whole-app speedup or
that every rendering hitch has been eliminated.

Validation for this change: 134 distinct selected macOS test cases passed across
editor, picker, handoff, docking, directory presentation, and file-search service
suites (131 initially, then 56 editor cases including 3 added width tests).
The native core passed 91 targeted prompt/command-block tests; the helper passed
3 upstream policy/phase fixtures and 7 adapter tests. ReleaseFast GhosttyKit and
the normal ReleaseLocal Spooky app built successfully. Production Info.plist
contains no diagnostic defaults or private index overrides, and its signature
has no get-task-allow debugging entitlement.
