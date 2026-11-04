# Reproducible own-window pixel benchmark

Measure original `NSEvent.timestamp` to independently identified WindowServer
pixels. App-side timings explain a result; they are not the result. These are
last-absent / first-present bounds, not physical display scanout latency.

## Reference and build ownership

The comparison is pristine upstream `0b1729e945978fca4bcd6165d8ac408bf675a7f2`
plus passive macOS event/capture hooks and a separate diagnostic app identity.
It is neither the native-disabled fork nor the installed Ghostty 1.4.0 binary.
The installed binary is useful as an additional visual control but does not
provide matching event timestamps without instrumentation.

The restored detached reference checkout is
`/Users/tylerangert/dev/patina/active/ghostty-wt-stock-check-20261104`.
Its preparation comes from the archived `evidence/v9-final/worktrees` patch;
the logger is refreshed from the current candidate. No upstream Zig, shader,
parser, terminal, or shell-integration source changes are permitted. Only the
build owner runs these sequential commands from that reference checkout:

```sh
/Users/tylerangert/.local/share/ghostty-prototype-toolchains/zig-aarch64-macos-0.17.0/zig build -Doptimize=ReleaseFast -Demit-macos-app=false -Dxcframework-target=native -j4
nu macos/build.nu --configuration ReleaseLocal --xcconfig /Users/tylerangert/dev/patina/active/ghostty-wt-native-input/macos/build-spooky/evidence/2026-11-04-benchmark/stock-capture.xcconfig
```

Zig uses its normal global cache at `/Users/tylerangert/.cache/zig`; do not copy
another worktree's mutable build products. The reference app is under
`macos/build/ReleaseLocal/Ghostty Stock Check.app`. Candidate builds use
`macos/build.nu`, their own output directory, and the sibling
`candidate-capture.xcconfig`.

For every executable, retain the source commit, uncommitted source diff,
diagnostic source hashes, executable SHA-256, app Info.plist, build command,
compiler version, build configuration, and full app/capture paths. Re-signing
an app can change the executable hash: hash the final configured binary.

## Capture configuration and controls

Use a diagnostic copy with a separate bundle identity. Never configure the
installed production app. The existing recorder accepts these environment
variables or corresponding diagnostic Info.plist keys:

```text
GHOSTTY_NATIVE_INPUT_DIAGNOSTICS=1
GHOSTTY_NATIVE_INPUT_DIAGNOSTICS_PATH=<unique-prefix>-ui.jsonl
SPOOKY_WINDOW_CAPTURE=1
SPOOKY_WINDOW_CAPTURE_DIRECTORY=<unique-prefix>-capture
SPOOKY_WINDOW_CAPTURE_SECONDS=60
SPOOKY_WINDOW_CAPTURE_VIDEO=0
SPOOKY_WINDOW_CAPTURE_ROI=x,y,width,height
SPOOKY_FSEARCH_DIAGNOSTICS_PATH=<unique-prefix>-index.jsonl
SPOOKY_FSEARCH_INDEX_DIRECTORY=<private-benchmark-index-directory>
```

The last two apply only to Spooky. A new private directory produces a genuine
initial crawl; reusing that same completed directory produces the warm case.
Never reset the user's production index. Record the helper's measured crawl /
build / ready state and CPU intervals; “fresh directory” alone does not prove
that a particular key overlapped busy indexing.

ROI coordinates are **native pixels from the full window's top-left**, including
the title bar, not AppKit points. Check the actual capture header and one native
frame before the timed fixture. Prior 2× examples were `(8,164,700,52)` for the
native editor and `(8,100,700,52)` for stock; these are calibration examples,
not guaranteed coordinates. App/window movement, font changes, or initial
layout can invalidate them.

The recorder captures only its own window and excludes child windows, cursor,
audio, microphone, and other apps. Completion menu load is measured through
editor glyphs while the menu is open; these recordings do **not** measure the
menu's own pixel latency. Resizing/backing-scale changes stop the recording.
Do not alter the capture scope to include the desktop.

The raw budget is 128 MiB. A 700×52 typing strip costs 145,600 bytes per changed
frame; a 160×500 scrolling strip costs 320,000. Identical frames reuse their
previous offset. Keep high-motion portions below about six seconds and avoid
large whole-window raw ROIs. Confirm `roi_unavailable` remains empty. Capture
starts at the first eligible key-window activation; wait for actual frames,
finish within 45 seconds, and leave at least one second on both ends.

Only the UI owner drives CUA. No builds, tests, offline decoding, or profiling
run during recording. Existing user jobs are left alone and documented.
The user can continue using their Mac: do not commandeer a Space or repeatedly
raise the test window. Preserve interrupted recordings and label their
visibility / Space transition intervals; retry a short phase when possible.
Record display, refresh rate, scale, window size, font, shell configuration,
pane count, and competing jobs. Match them between stock and candidate.

## Short controlled fixtures

Use separate ≤60-second recordings for these workloads. Retain the exact CUA
sequence and input-ID mapping. Verify the final native/terminal draft after
each burst so a lost key does not silently become a latency sample.

1. **Plain typing, cold and warm.** Type these eight different 16-character
   drafts at 35 ms per key. Reset using Cmd+A/Backspace in the native editor and
   Ctrl+U in stock. Allow about 150 ms for the empty state between drafts.
   This takes about ten seconds. The initial `#` avoids shell completion work.

   ```text
   #mwxgbmwxgbmwxgb
   #bgxwmbgxwmbgxwm
   #xgbmwxgbmwxgbmw
   #wmbgxwmbgxwmbgx
   #gxbwmgxbwmgxbwm
   #mbgxwmbgxwmbgxw
   #xwmbgxwmbgxwmbg
   #bwmxgbwmxgbwmxg
   ```

2. **Completion and indexing load.** In a separate native run, type `cd /`,
   wait 200 ms for automatic suggestions, then type `Applications` at 35 ms per
   key while the menu is open. Reset, then type `@spooky`. Repeat once. Run
   while the fresh index's telemetry reports crawl, and again when ready.
   Capture actual glyphs, not caret changes or the menu appearing. Stock can
   type the same strings as a text-input control; it has no equivalent `@`
   feature, so this is a workload-cost comparison, not identical functionality.

3. **Nonempty submit.** Prefill enough output to dock the native editor, then
   submit six commands `printf '%d\n' $((41000+N))`, with N=1…6 and about 300 ms
   between commands. Commands may be prepared with paste; the measured event
   is Return. Output `41001`, etc. is distinct from the command expression.
   Record two endpoints where identifiable: first committed terminal command /
   block, and first unique output. Do not count disappearance of the native
   echo as either. Use a narrow bottom-region ROI containing output and editor.

4. **Empty-submit handoff.** After a unique numbered output landmark, send a
   short 12–20 Return burst. Track the landmark and separator movement in every
   captured frame, including the footer. Identical blank block headers cannot
   identify each individual Return. Report pixel/row displacement, observed
   blank/flicker frames, coalescing, and missing intervals instead of assigning
   artificial per-key latencies.

5. **Scrolling.** Prepare output with this builtin-only command before the
   timed gestures:

   ```zsh
   for ((i=0; i<300; i++)); do printf 'ROW %04d : mwxgb\n' $i; done
   ```

   Scroll to a middle position, choose a unique visible row label, and perform
   twelve alternating small wheel gestures 180–250 ms apart. Keep that label
   inside the narrow ROI. Then perform a short same-direction gesture burst
   for cadence/coalescing. The new `scrollInput` records original delta_x/y,
   precise-delta flag, phase and momentum phase in both apps. Compare actual
   delivered events; a CUA wheel gesture is not evidence of trackpad-momentum
   behavior. Use a separate bottom-region recording to verify footer stability.

Run an ABBA order when the user/workload permits (stock, candidate, candidate,
stock). Publish every completed attempt and its exclusions. Keep pre-transition
steady typing separate from post-Space recovery; a 500 ms guard cannot prove
the compositor has finished recovering.

## Offline evidence and reporting

First inspect candidates without labeling them automatically:

```sh
uv run --script test/native-input/analyze_window_capture.py /absolute/capture --events /absolute/ui.jsonl --output /absolute/inspection --max-events 128
```

Check exact native before/after PNGs for the target glyph, output token, or
landmark. Contact sheets are navigation aids. A complete frame with changing
ROI bytes is not necessarily the response: caret, selection, echo, and menus
can also change pixels. Preserve source-event IDs and repeated/coalesced stage
lists rather than reducing each stage to one timestamp.

`test/native-input/benchmark_window_pixels.py` consumes a JSON spec:

```json
{
  "capture": "/absolute/capture",
  "events": "/absolute/ui.jsonl",
  "provenance": {"source_commit": "...", "binary_sha256": "...", "case": "cold"},
  "steady_window_margin_ms": 500,
  "groups": [{"name": "plain", "samples": [{
    "input_id": 1, "target": "new m glyph, visually checked",
    "confirmed": true, "last_absent_frame": 100, "first_present_frame": 101
  }]}],
  "scroll_tracks": [{
    "name": "ROW 0170, native template visually checked",
    "confirmed_template": true, "reference_frame": 200,
    "template_rect": [8, 170, 130, 24], "search_rect": [8, 0, 130, 500],
    "start_uptime_s": 1000.0, "end_uptime_s": 1003.0, "row_height_px": 34
  }]
}
```

```sh
uv run --script test/native-input/benchmark_window_pixels.py /absolute/spec.json --output /absolute/report
uv run --script test/native-input/test_window_pixel_benchmark.py
```

Landmarks use exact RGB pixels with no OCR or nearest-match fallback. Missing
or ambiguous matches stay unmeasured. A scroll input followed by another input
before the first visible movement cannot receive an individually confirmed
latency. Capture gaps and hidden/off-Space intervals retain their raw bounds
but are excluded from the qualifying aggregate. Report all qualifying samples
and a separate ≤50 ms observation-gap sensitivity view; never replace the full
sample with only the tighter subset. Count distinct endpoint frames as well as
glyphs, since multiple keys can share a frame.

For scrolling, show input deltas alongside observed pixel steps / row steps,
frame dwell times, ambiguous/missing intervals, and footer geometry. Row-sized
steps alone are not a new fork regression: compare with the same stock path.
Do not claim smoothness from a capture whose raw budget expired mid-gesture.

Archive native strips, metadata, event logs, confirmed endpoints, exact source
patches and binary provenance under ignored `macos/build-spooky/evidence/`.
Do not commit recordings or filename indexes. Remove only the task's disposable
comparison worktree/build/index after its evidence is archived and verified.
