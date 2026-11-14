# Inline input scrolling

The November 14, 2026 recording (`CleanShot 2026-11-14 at 9.46.38 AM.mp4`,
1502 × 692, 164 frames, 2.883333 seconds) showed two separate defects.

## Native-frame evidence

Frame IDs are one-based decoded frame numbers. Times are source presentation
timestamps; the recording is variable frame rate. Decode with passthrough timing
instead of assigning timestamps from a nominal frame rate.

| Frame | Time | Active separator y | Native input glyph top y |
| --- | --- | --- | --- |
| 17 | 0.275000 s | 361 px | 430 px |
| 18 | 0.300000 s | 349 px | 430 px |
| 19 | 0.316667 s | 337 px | 430 px |
| 20 | 0.333333 s | 327 px | 396 px |
| 21 | 0.350000 s | 311 px | 396 px |
| 22 | 0.366667 s | 301 px | 396 px |
| 23 | 0.383333 s | 289 px | 362 px |

The separator moves 97 times across the recording. The native input moves only
20 times, always by 34 pixels. This is row-quantized placement, not whole-frame
latency: frames 19–20 move the header 10 pixels and the input 34 pixels.

The gray strip first appears in frame 20. At x1498 it spans y0–377 and
y436–691, with a 58-pixel interruption matching the native editor. The editor
is a sibling above the terminal scroll view and covers its scrollbar. A large
native thumb is expected when the scrollable history exceeds the viewport by
only a few rows; breaking that thumb in two is not.

## Fix

- Capture the prompt cursor's physical-pixel position in the same renderer
  snapshot as the Metal image, including its fractional viewport crop.
- Deliver changed ready-prompt geometry in the existing IOSurface assignment
  transaction. Do not derive its position from a newer live terminal snapshot.
- Move an owned inline editor directly, without shell, focus, TextKit measurement,
  or chrome publication work. Reposition an open completion overlay with it.
- Keep inline content attached to its document position at viewport edges;
  clipping must not turn it into an accidental dock.
- Leave the native history scrollbar's hit area uncovered by inline input.
  Its gutter stays stable through hover/fade. Docked input retains full width.

Cursor projection uses existing scrollbar counts and the active cursor row in
constant time. It does not walk scrollback or add a polling/display timer.

## Regression coverage

Zig tests cover pixel increments, row crossings, partial bottom-row visibility,
stale frame rejection, synchronous resize callback deferral, and C ABI layout.
Swift tests cover backing-scale conversion, fractional split dimensions,
generation/resize rejection, inline clipping, position-only callbacks, and the
scrollbar gutter/hit region.

The original recording contains no input timestamps or gesture phases. It proves
the alignment defect but cannot measure key-to-pixel latency, deceleration
quality, or CPU/GPU cost.

## Verification on the rebuilt app

The arm64 ReleaseLocal app passed signature/bundle checks. The targeted suite
passed 135 Swift tests and 87 Zig tests. A separate window, using the normal
Spooky identity, exercised retained history with a short inline prompt and
scroll reversals without disturbing existing sessions.

In its 14-second window-only recording, all 487 decoded frames maintain the
same separator-to-input offset (99 physical pixels for this fixture). Five
observed moves shift the separator and input by identical deltas:
`+284, +190, -228, +152, -398` pixels. These include non-row-sized changes. The
native scrollbar remains continuous across the editor's vertical span.

This confirms frame alignment under the exercised synthetic scroll inputs.
Those inputs are large jumps clustered within 158 ms, so this recording does
not establish natural trackpad deceleration cadence or end-to-end latency.
The fixture's absolute spacing is not a padding comparison with the original
recording. Captures and per-frame measurements remain local, outside Git.
