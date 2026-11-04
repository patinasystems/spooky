# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=11", "numpy>=2"]
# ///
"""Report confirmed own-window pixel endpoints and exact scrolling landmarks.

This offline tool never records, launches, or controls an application. A spec
names the finished capture, matching event log, manually verified endpoint
frames, and optional exact native-pixel scrolling landmarks. CPU milestones
remain separate from WindowServer display-time bounds.
"""
from __future__ import annotations

import argparse
import collections
import json
import math
from pathlib import Path
import statistics

import numpy as np

from analyze_window_capture import Capture, finite, records


def distribution(values):
    if not values:
        return None
    values = sorted(values)
    position = (len(values) - 1) * 0.95
    lower, upper = math.floor(position), math.ceil(position)
    return {"n": len(values), "median": statistics.median(values),
            "p95": values[lower] + (values[upper] - values[lower]) * (position - lower),
            "maximum": values[-1]}


def load_events(path, pid):
    rows = list(records(path))
    own = [row for row in rows if row.get("pid") in (None, pid)]
    stages = sorted((event for row in own for event in row.get("events", [])),
                    key=lambda event: event["uptime_s"])
    inputs = {event["id"]: event for event in stages if event["stage"] == "inputReceived"}
    return stages, inputs, sum(row.get("counters", {}).get("diagnosticEventsDropped", 0) for row in own)


def interval_issues(capture, before, after, source, margin):
    start = min(source, before["display_uptime_s"])
    # A tracker may advance its last-absent frame past an earlier observation
    # gap. Keep qualification over the entire source-to-endpoint interval.
    # Anchor by a preceding timed frame, then use sequence IDs so frames with
    # missing display timestamps cannot silently disappear from this check.
    preceding = [frame for frame in capture.frames if capture.has_time(frame)
                 and frame["display_uptime_s"] <= start and frame["i"] <= after["i"]]
    first = max(preceding, key=lambda frame: frame["display_uptime_s"])["i"] if preceding else 0
    first = min(first, before["i"])
    unavailable = [frame["i"] for frame in capture.frames if first <= frame["i"] < after["i"]
                   and (not capture.has_time(frame) or frame.get("status") not in (0, 1)
                        or (frame.get("status") == 0 and not capture.has_pixels(frame)))]
    return {"intervening_unavailable_frames": unavailable,
            "visibility_exclusions": capture.visibility_issues(start, after["display_uptime_s"]),
            "steady_window_exclusions": capture.steady_window_issues(start, after["display_uptime_s"], margin)}


def sample_report(item, capture, stages, inputs, margin):
    event = inputs[item["input_id"]]
    source = event.get("event_uptime_s")
    result = dict(item, source_uptime_s=source, eligible=False)
    result["timeline"] = [event for event in stages if event.get("id") == item["input_id"]]
    if not finite(source) or source <= 0:
        result["unavailable"] = "Missing original NSEvent timestamp"
        return result
    result["event_to_handler_ms"] = 1000 * (event["uptime_s"] - source)
    result["timeline"] = [dict(event, relative_ms=1000 * (event["uptime_s"] - source))
                          for event in result["timeline"]]
    if item.get("confirmed") is not True or not item.get("target"):
        result["unavailable"] = "Target identity has not been confirmed in native frames"
        return result
    before = capture.by_id[item["last_absent_frame"]]
    after = capture.by_id[item["first_present_frame"]]
    if not capture.has_time(before) or not capture.has_time(after) or not capture.has_pixels(before) or not capture.has_pixels(after):
        result["unavailable"] = "Endpoint lacks original display time or complete raw pixels"
        return result
    lo, hi = before["display_uptime_s"], after["display_uptime_s"]
    if lo >= hi or hi <= source:
        result["unavailable"] = "Endpoints are unordered or the response precedes its input"
        return result
    result.update(interval_issues(capture, before, after, source, margin))
    # An earlier queued update can become visible after this NSEvent's source
    # timestamp but before its handler begins. That frame cannot be this input's
    # response. Retain its raw bounds for investigation, excluding attribution.
    result["causality_exclusions"] = (["Endpoint was displayed before this input's handler began"]
                                       if hi < event["uptime_s"] else [])
    result.update(key_to_pixel_ms=[max(0, 1000 * (lo - source)), 1000 * (hi - source)],
                  observation_gap_ms=1000 * (hi - lo),
                  callback_lag_ms=1000 * (after["callback_uptime_s"] - hi),
                  later_input_ids=[ident for ident, value in inputs.items()
                                   if finite(value.get("event_uptime_s")) and source < value["event_uptime_s"] <= hi])
    result["eligible"] = not any(result[key] for key in
                                 ("intervening_unavailable_frames", "visibility_exclusions", "steady_window_exclusions",
                                  "causality_exclusions"))
    return result


def summarize(samples):
    def stats(selected):
        return {"n": len(selected),
                "distinct_endpoint_frames": len({sample["first_present_frame"] for sample in selected}),
                "lower_ms": distribution([sample["key_to_pixel_ms"][0] for sample in selected]),
                "upper_ms": distribution([sample["key_to_pixel_ms"][1] for sample in selected]),
                "source_to_handler_ms": distribution([sample["event_to_handler_ms"] for sample in selected])}
    eligible = [sample for sample in samples if sample.get("eligible")]
    return {"all_qualifying": stats(eligible),
            "observation_gap_at_most_50ms": stats([sample for sample in eligible if sample["observation_gap_ms"] <= 50]),
            "excluded_input_ids": [sample["input_id"] for sample in samples if not sample.get("eligible")]}


def landmark_positions(image, template, search):
    """Exact BGRA-derived RGB match; no OCR, resizing, or nearest-match fallback."""
    x, y, width, height = search
    th, tw = template.shape[:2]
    if width != tw or min(x, y, width, height) < 0 or x + width > image.shape[1] or y + height > image.shape[0]:
        raise ValueError("Landmark search must be an in-bounds vertical strip the same width as the template")
    return [row for row in range(y, y + height - th + 1)
            if np.array_equal(image[row:row + th, x:x + width], template)]


def track_landmark(spec, capture, stages, inputs, margin, dropped_events=0):
    reference = capture.by_id[spec["reference_frame"]]
    native = np.asarray(capture.native_image(reference).convert("RGB"))
    x, y, width, height = spec["template_rect"]
    if min(x, y) < 0 or min(width, height) <= 0 or x + width > capture.width or y + height > capture.height:
        raise ValueError("Invalid landmark template rectangle")
    template = native[y:y + height, x:x + width].copy()
    if np.max(template) - np.min(template) < 20:
        raise ValueError("A flat background is not an identifiable landmark")
    start, end = spec["start_uptime_s"], spec["end_uptime_s"]
    cache, frames = {}, []
    for frame in capture.observations:
        if not start <= frame["display_uptime_s"] <= end:
            continue
        offset = frame["roi_offset"]
        if offset not in cache:
            pixels = np.asarray(capture.native_image(frame).convert("RGB"))
            cache[offset] = landmark_positions(pixels, template, spec["search_rect"])
        frames.append({"frame": frame["i"], "display_uptime_s": frame["display_uptime_s"],
                       "matching_y": cache[offset]})
    transitions = []
    for frame in frames:
        if len(frame["matching_y"]) != 1:
            continue
        if not transitions or transitions[-1]["matching_y"] != frame["matching_y"]:
            transitions.append(frame)
    steps = [right["matching_y"][0] - left["matching_y"][0]
             for left, right in zip(transitions, transitions[1:])]
    step_evidence = []
    for left, right in zip(transitions, transitions[1:]):
        between = [frame for frame in frames if left["frame"] <= frame["frame"] < right["frame"]]
        prior = between[-1]
        issues = interval_issues(capture, capture.by_id[prior["frame"]], capture.by_id[right["frame"]],
                                 prior["display_uptime_s"], margin)
        step_evidence.append({"from_frame": left["frame"], "previous_observation_frame": prior["frame"],
                              "to_frame": right["frame"],
                              "pixel_step": right["matching_y"][0] - left["matching_y"][0],
                              "first_observed_change_spacing_ms": 1000 * (right["display_uptime_s"] - left["display_uptime_s"]),
                              "movement_observation_gap_ms": 1000 * (right["display_uptime_s"] - prior["display_uptime_s"]),
                              "unmatched_or_ambiguous_between": [frame["frame"] for frame in between if len(frame["matching_y"]) != 1],
                              **issues})
    samples = []
    for ident, event in inputs.items():
        source = event.get("event_uptime_s")
        if event.get("input_kind") != "scroll" or not finite(source) or not start <= source <= end:
            continue
        old = [frame for frame in frames if frame["display_uptime_s"] <= source]
        item = {"input_id": ident, "confirmed": False, "target": spec["name"]}
        if not old or len(old[-1]["matching_y"]) != 1:
            samples.append(dict(item, unavailable="No unique pre-input landmark"))
            continue
        previous = old[-1]
        for frame in frames:
            if frame["display_uptime_s"] <= source:
                continue
            if len(frame["matching_y"]) != 1:
                item["unavailable"] = "Landmark became absent or ambiguous before a unique movement"
                break
            if frame["matching_y"] == old[-1]["matching_y"]:
                previous = frame
                continue
            later = [other for other in inputs.values() if finite(other.get("event_uptime_s"))
                     and source < other["event_uptime_s"] <= frame["display_uptime_s"]]
            item.update(last_absent_frame=previous["frame"], first_present_frame=frame["frame"],
                        confirmed=spec.get("confirmed_template") is True and not later,
                        pixel_step=frame["matching_y"][0] - old[-1]["matching_y"][0],
                        overlapping_later_input_ids=[other["id"] for other in later])
            break
        if "first_present_frame" in item:
            sample = sample_report(item, capture, stages, inputs, margin)
            # Automatic attribution relies on the absence of a later input.
            # A dropped event makes that claim unprovable; retain raw bounds,
            # but do not include the sample in latency distributions.
            sample["input_log_exclusions"] = (["Input diagnostics dropped events; automatic attribution is unqualified"]
                                               if dropped_events else [])
            if dropped_events:
                sample["eligible"] = False
            samples.append(sample)
        else:
            samples.append(dict(item, eligible=False))
    row_height = spec.get("row_height_px")
    return {"name": spec["name"], "method": "Exact native RGB landmark matching; missing or ambiguous matches stay unmeasured",
            "diagnostic_events_dropped": dropped_events,
            "confirmed_template": spec.get("confirmed_template") is True, "frames": frames,
            "transitions": transitions, "pixel_steps": steps, "step_evidence": step_evidence,
            "cadence_caveat": "First-observed change spacing includes event pacing and sampling; gaps or unmatched frames do not prove held pixels.",
            "row_steps": [step / row_height for step in steps] if row_height else None,
            "non_row_multiple_steps": [step for step in steps if step % row_height] if row_height else None,
            "unmatched_or_ambiguous_frame_ids": [frame["frame"] for frame in frames if len(frame["matching_y"]) != 1],
            "samples": samples, "statistics": summarize(samples)}


def report(spec, output):
    capture = Capture(Path(spec["capture"]))
    if capture.summary is None:
        raise ValueError("Finish the capture before analysis")
    stages, inputs, dropped = load_events(Path(spec["events"]), capture.header.get("pid"))
    margin = spec.get("steady_window_margin_ms", 500)
    if not finite(margin) or not 0 <= margin <= 5000:
        raise ValueError("Steady-window guard must be between 0 and 5000ms")
    result = {"schema": 1, "scope": "Original NSEvent to observed WindowServer pixels; not physical scanout",
              "provenance": spec.get("provenance", {}), "capture": capture.stats(),
              "steady_window_margin_ms": margin, "diagnostic_events_dropped": dropped,
              "qualification": "All raw bounds retained. Stable flags do not prove compositor recovery. "
                               "Coalesced glyphs share an endpoint; they are not independent frame samples.",
              "groups": [], "scroll_tracks": []}
    output.mkdir(parents=True, exist_ok=True)
    endpoints = set()
    for group in spec.get("groups", []):
        samples = [sample_report(item, capture, stages, inputs, margin) for item in group["samples"]]
        result["groups"].append({"name": group["name"], "samples": samples, "statistics": summarize(samples)})
        for sample in samples:
            if "key_to_pixel_ms" in sample:
                endpoints.update((sample["last_absent_frame"], sample["first_present_frame"]))
    for track in spec.get("scroll_tracks", []):
        analyzed = track_landmark(track, capture, stages, inputs, margin, dropped_events=dropped)
        result["scroll_tracks"].append(analyzed)
        for sample in analyzed["samples"]:
            if "key_to_pixel_ms" in sample:
                endpoints.update((sample["last_absent_frame"], sample["first_present_frame"]))
    for ident in sorted(endpoints):
        capture.native_image(capture.by_id[ident]).save(output / f"frame-{ident:06d}.png")
    (output / "analysis.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("spec", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = report(json.loads(args.spec.read_text()), args.output)
    print(json.dumps({"report": str(args.output / "analysis.json"),
                      "groups": {group["name"]: group["statistics"] for group in result["groups"]},
                      "scroll": {track["name"]: track["statistics"] for track in result["scroll_tracks"]}}, indent=2))


if __name__ == "__main__":
    main()
