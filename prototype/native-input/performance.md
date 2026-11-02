# Native input integration measurements

These measurements cover the prototype's native input and shell bridge. They do
not establish terminal rendering throughput or a general efficiency claim.

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
