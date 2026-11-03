# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=11"]
# ///
"""Inspect local diagnostic captures without recording or controlling any UI.

Run with uv run --script test/native-input/analyze_window_capture.py --help.
ROI changes are candidates, never automatically classified as typed glyphs.
"""
from __future__ import annotations

import argparse
import collections
import json
import math
from pathlib import Path
import statistics

from PIL import Image, ImageDraw

STATUSES = {0: "complete", 1: "idle", 2: "blank", 3: "suspended", 4: "started", 5: "stopped"}


def records(path: Path):
    with path.open() as source:
        for number, line in enumerate(source, 1):
            if not line.strip():
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(f"{path}:{number}: incomplete or invalid JSON; analyze a finished capture") from error


def finite(value):
    return isinstance(value, (float, int)) and math.isfinite(value)


def event_rows(path: Path, pid):
    result = []
    ignored_pid = 0
    for row in records(path):
        if row.get("pid") not in (None, pid):
            ignored_pid += 1
            continue
        for event in row.get("events", [row] if row.get("stage") else []):
            if event.get("stage") != "inputReceived":
                continue
            value = event.get("event_uptime_s")
            result.append({
                "id": event.get("id"), "kind": event.get("input_kind"),
                "source_uptime_s": value if finite(value) and value > 0 else None,
                "handler_uptime_s": event.get("uptime_s"),
            })
    return result, ignored_pid


class Capture:
    def __init__(self, directory: Path):
        self.directory = directory
        rows = list(records(directory / "frames.jsonl"))
        self.header = next(row for row in rows if row.get("kind") == "header")
        self.summary = next((row for row in reversed(rows) if row.get("kind") == "summary"), None)
        self.errors = [row for row in rows if row.get("kind") == "error"]
        self.window_states = sorted((row for row in rows if row.get("kind") == "window_state"
                                     and finite(row.get("uptime_s"))), key=lambda row: row["uptime_s"])
        self.frames = [row for row in rows if row.get("kind") == "frame"]
        self.by_id = {row["i"]: row for row in self.frames}
        self.region = self.header.get("raw_roi", [])
        self.raw_size = (directory / "roi.bgra").stat().st_size
        if len(self.region) == 4:
            self.width, self.height = map(int, self.region[2:])
            if self.width <= 0 or self.height <= 0 or self.width * self.height > 2_097_152:
                raise ValueError("Invalid or oversized raw ROI")
            self.frame_bytes = self.width * self.height * 4
        else:
            self.width = self.height = self.frame_bytes = 0
        self.valid_time_frames = [row for row in self.frames if self.has_time(row)]
        self.observations = [row for row in self.valid_time_frames if self.has_pixels(row)]
        self.valid_time_frames.sort(key=lambda row: row["display_uptime_s"])
        self.observations.sort(key=lambda row: row["display_uptime_s"])

    @staticmethod
    def has_time(frame):
        timestamp = frame.get("display_uptime_s")
        return finite(timestamp) and timestamp > 0 and frame.get("display_time_ticks", 0) > 0

    def has_pixels(self, frame):
        offset = frame.get("roi_offset")
        length = frame.get("roi_bytes")
        return (frame.get("status") == 0 and self.frame_bytes > 0 and
                isinstance(offset, int) and offset >= 0 and length == self.frame_bytes and
                offset + length <= self.raw_size and not frame.get("roi_unavailable"))

    def native_image(self, frame):
        if not self.has_pixels(frame):
            raise ValueError(f"Frame {frame['i']} does not contain available ROI pixels")
        with (self.directory / "roi.bgra").open("rb") as source:
            source.seek(frame["roi_offset"])
            data = source.read(self.frame_bytes)
        return Image.frombytes("RGBA", (self.width, self.height), data, "raw", "BGRA")

    def visibility_issues(self, start, end):
        before = [row for row in self.window_states if row["uptime_s"] <= start]
        if not before:
            return ["window visibility was not recorded at interval start"]
        relevant = [before[-1]] + [row for row in self.window_states if start < row["uptime_s"] <= end]
        issues = set()
        for row in relevant:
            metrics = row.get("metrics", {})
            for key, invalid, message in [
                ("visible", 0, "window hidden"), ("active_space", 0, "window outside active Space"),
                ("occlusion_visible", 0, "window fully occluded"),
                ("miniaturized", 1, "window minimized"), ("application_hidden", 1, "application hidden")
            ]:
                if metrics.get(key) == invalid:
                    issues.add(message)
        return sorted(issues)

    def stats(self):
        complete = [row for row in self.valid_time_frames if row.get("status") == 0]
        gaps = [1000 * (right["display_uptime_s"] - left["display_uptime_s"])
                for left, right in zip(complete, complete[1:])]
        gaps = [value for value in gaps if value > 0]
        return {
            "header": self.header, "finished": self.summary is not None, "summary": self.summary,
            "window_state_markers": len(self.window_states),
            "visibility_caveat": "Window-level visibility is not proof that the selected ROI is unobstructed. "
                                 "Key loss alone is allowed; hidden, fully occluded, inactive-Space intervals are rejected.",
            "errors": self.errors, "statuses": dict(collections.Counter(
                STATUSES.get(row.get("status"), "unknown") for row in self.frames)),
            "invalid_or_missing_display_time": len(self.frames) - len(self.valid_time_frames),
            "complete_frames_without_roi": sum(not self.has_pixels(row) for row in complete),
            "video_enabled": self.header.get("video_enabled", True),
            "complete_frames_without_video": sum(not row.get("video_written", False) for row in complete)
                if self.header.get("video_enabled", True) else None,
            "recorded_roi_observations": len(self.observations),
            "roi_unavailable_reasons": dict(collections.Counter(
                row["roi_unavailable"] for row in self.frames if row.get("roi_unavailable"))),
            "complete_observation_gap_ms": {"minimum": min(gaps), "median": statistics.median(gaps),
                                              "maximum": max(gaps)} if gaps else None,
            "gap_caveat": "Variable updates and idle displays can produce long gaps; gaps alone do not prove drops.",
        }


def candidate_changes(capture: Capture, event, events, before_ms, after_ms):
    timestamp = event["source_uptime_s"]
    result = dict(event, classification="unconfirmed pixel candidates; requires target-glyph inspection", candidates=[])
    if timestamp is None:
        result["unavailable"] = "missing source-event timestamp"
        return result
    result["source_to_handler_ms"] = (event["handler_uptime_s"] - timestamp) * 1000
    nearby = [row for row in capture.valid_time_frames
              if timestamp - before_ms / 1000 <= row["display_uptime_s"] <= timestamp + after_ms / 1000]
    result["nearby_statuses"] = dict(collections.Counter(STATUSES.get(row["status"], "unknown") for row in nearby))
    result["nearby_invalid_time_frame_ids"] = [row["i"] for row in capture.frames
        if not capture.has_time(row) and finite(row.get("callback_uptime_s"))
        and timestamp - before_ms / 1000 <= row["callback_uptime_s"] <= timestamp + after_ms / 1000]
    result["overlapping_input_ids"] = [other["id"] for other in events
        if other is not event and other["source_uptime_s"] is not None
        and timestamp <= other["source_uptime_s"] <= timestamp + after_ms / 1000]
    before = [row for row in capture.observations if row["display_uptime_s"] <= timestamp]
    previous = before[-1] if before else None
    result["pre_input_observation"] = previous["i"] if previous else None
    result["post_input_complete_frames"] = sum(row["status"] == 0 and row["display_uptime_s"] >= timestamp
                                               for row in nearby)
    for current in capture.observations:
        shown = current["display_uptime_s"]
        if not timestamp < shown <= timestamp + after_ms / 1000:
            continue
        if previous is None:
            result["first_available_frame_without_preceding_pixels"] = current["i"]
            previous = current
            continue
        if current["roi_offset"] != previous["roi_offset"]:
            intervening = [row for row in capture.frames if previous["i"] < row["i"] < current["i"]]
            unavailable = [row["i"] for row in intervening
                           if row.get("status") not in (0, 1)
                           or (row.get("status") == 0 and not capture.has_pixels(row))
                           or not capture.has_time(row)]
            result["candidates"].append({
                "previous_frame": previous["i"], "changed_frame": current["i"],
                "candidate_interval_ms": [max(0, 1000 * (previous["display_uptime_s"] - timestamp)),
                                          1000 * (shown - timestamp)],
                "observation_gap_ms": 1000 * (shown - previous["display_uptime_s"]),
                "source_video_pts_s": current.get("video_pts_s"),
                "video_written": current.get("video_written", False),
                "intervening_idle_frames": sum(row.get("status") == 1 for row in intervening),
                "intervening_unavailable_frame_ids": unavailable,
                "visibility_exclusions": capture.visibility_issues(
                    min(timestamp, previous["display_uptime_s"]), shown),
                "confirmation_required": "Verify the previous frame lacks, and changed frame contains, the target glyph.",
            })
        previous = current
    if not result["post_input_complete_frames"]:
        result["unavailable"] = "No complete frame observed in the requested interval; this is not zero latency."
    return result


def write_images(capture, analyses, output, maximum_frames, per_event):
    native = output / "native-roi"
    native.mkdir(parents=True, exist_ok=True)
    sheets = output / "contact-sheets"
    sheets.mkdir(exist_ok=True)
    exported = set()
    for event in analyses:
        chosen = []
        if event.get("pre_input_observation") is not None:
            chosen.append(event["pre_input_observation"])
        for change in event["candidates"]:
            for identifier in (change["previous_frame"], change["changed_frame"]):
                if identifier not in chosen:
                    chosen.append(identifier)
        chosen = chosen[:per_event]
        thumbnails = []
        for identifier in chosen:
            if identifier not in exported and len(exported) >= maximum_frames:
                event["image_export_truncated"] = True
                break
            frame = capture.by_id[identifier]
            image = capture.native_image(frame)
            if identifier not in exported:
                image.save(native / f"frame-{identifier:06d}.png")
                exported.add(identifier)
            preview = image.convert("RGB")
            preview.thumbnail((512, 256), Image.Resampling.LANCZOS)
            delta = 1000 * (frame["display_uptime_s"] - event["source_uptime_s"])
            label = f"frame {identifier} | event {event['id']} {delta:+.3f} ms | video {frame.get('video_pts_s', 0):.6f}s"
            thumbnails.append((preview, label))
        if not thumbnails:
            continue
        cell_width = max(image.width for image, _ in thumbnails) + 12
        cell_height = max(image.height for image, _ in thumbnails) + 40
        columns = min(3, len(thumbnails))
        sheet = Image.new("RGB", (columns * cell_width, math.ceil(len(thumbnails) / columns) * cell_height), "#202124")
        draw = ImageDraw.Draw(sheet)
        for index, (preview, label) in enumerate(thumbnails):
            x, y = index % columns * cell_width, index // columns * cell_height
            sheet.paste(preview, (x + 6, y + 30))
            draw.text((x + 6, y + 8), label, fill="white")
        path = sheets / f"event-{event['id']}.png"
        sheet.save(path)
        event["contact_sheet"] = str(path)
    return len(exported)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--events", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--input-id", action="append", type=int, default=[])
    parser.add_argument("--before-ms", type=float, default=50)
    parser.add_argument("--after-ms", type=float, default=250)
    parser.add_argument("--max-events", type=int, default=64)
    parser.add_argument("--max-native-frames", type=int, default=128)
    parser.add_argument("--frames-per-event", type=int, default=12)
    args = parser.parse_args()
    if not 0 <= args.before_ms <= 2000 or not 0 < args.after_ms <= 2000:
        parser.error("Intervals must be bounded to 0–2000ms, with after-ms positive")
    if not 1 <= args.max_events <= 256 or not 1 <= args.max_native_frames <= 512 or not 1 <= args.frames_per_event <= 32:
        parser.error("Bounded export: 1–256 events, 1–512 native frames, 1–32 frames/event")
    capture = Capture(args.capture)
    events, ignored = event_rows(args.events, capture.header.get("pid"))
    selected = [row for row in events if not args.input_id or row["id"] in args.input_id][:args.max_events]
    analyses = [candidate_changes(capture, event, events, args.before_ms, args.after_ms) for event in selected]
    args.output.mkdir(parents=True, exist_ok=True)
    exported = write_images(capture, analyses, args.output, args.max_native_frames, args.frames_per_event)
    report = {"schema": 1, "capture": str(args.capture), "diagnostics": str(args.events),
        "scope": "Source input to observed WindowServer ROI pixels; not physical scanout or a causal automatic classifier.",
        "clock": "Frame mach ticks converted by recorder timebase; input is original NSEvent.timestamp, not handler entry.",
        "inspection": "Native ROI PNGs are exact. Contact sheets are resampled navigation aids. Confirm target glyph manually.",
        "capture_summary": capture.stats(), "ignored_foreign_pid_log_rows": ignored,
        "input_count": len(events), "analyzed_input_count": len(analyses), "exported_native_frames": exported,
        "events": analyses}
    path = args.output / "analysis.json"
    path.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"report": str(path), "events": len(analyses), "native_frames": exported,
                      "confirmed_latency_samples": 0}))


if __name__ == "__main__":
    main()
