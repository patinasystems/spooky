#!/usr/bin/env python3
"""Read-only process diagnostics for the Blocks prototype. Never drives the UI.

No command text, terminal contents, clipboard, or environment is collected.
Output is local JSON plus optional stack samples. Use Pat for profiling runs.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import plistlib
import re
import statistics
import subprocess
import tempfile


DEFAULT_BUNDLE_ID = "com.patinasystems.ghostty.blocks"


def run(*args: str, timeout: float = 15) -> str:
    return subprocess.run(
        args, check=True, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, timeout=timeout,
    ).stdout


def matching_processes(bundle_id: str) -> dict[int, Path]:
    matches = {}
    for line in run("ps", "-axo", "pid=,comm=").splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) != 2:
            continue
        executable = Path(fields[1])
        if not str(executable).endswith(".app/Contents/MacOS/ghostty"):
            continue
        try:
            with (executable.parent.parent / "Info.plist").open("rb") as file:
                info = plistlib.load(file)
            if info.get("CFBundleIdentifier") == bundle_id:
                matches[int(fields[0])] = executable
        except (OSError, ValueError, plistlib.InvalidFileException):
            continue
    return matches


def process_snapshot(pid: int) -> dict:
    # ps %cpu is a recent/lifetime estimate, not our interval measurement.
    fields = run("ps", "-p", str(pid), "-o", "pid=,pcpu=,rss=,vsz=,etime=,time=").split()
    return {
        "pid": int(fields[0]), "ps_cpu_percent_estimate": float(fields[1]),
        "rss_kib": int(fields[2]), "virtual_kib": int(fields[3]),
        "elapsed": fields[4], "cpu_time": fields[5],
        "threads": max(0, len(run("ps", "-M", "-p", str(pid)).splitlines()) - 1),
    }


def descendants(pid: int) -> list[dict]:
    processes = []
    for line in run("ps", "-axo", "ppid=,pid=,pcpu=,rss=,comm=").splitlines():
        fields = line.strip().split(maxsplit=4)
        if len(fields) != 5:
            continue
        processes.append({
            "ppid": int(fields[0]), "pid": int(fields[1]),
            "ps_cpu_percent_estimate": float(fields[2]),
            "rss_kib": int(fields[3]), "executable_name": Path(fields[4]).name,
        })
    selected = {pid}
    while True:
        expanded = selected | {p["pid"] for p in processes if p["ppid"] in selected}
        if expanded == selected:
            break
        selected = expanded
    return [p for p in processes if p["pid"] in selected and p["pid"] != pid]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, help="Required when multiple Blocks apps are running")
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID, help="Exact expected application bundle identifier")
    parser.add_argument("--seconds", type=int, default=10, help="Top interval capture duration, 1–60")
    parser.add_argument("--sample-seconds", type=int, default=0, help="Optional stack sample duration, 0–10")
    parser.add_argument("--phase", default="uncontrolled-live-session")
    parser.add_argument("--visibility", choices=["active-visible", "inactive-visible", "occluded", "unknown"], default="unknown")
    parser.add_argument("--output", type=Path, help="New local output directory; defaults to private temporary directory")
    args = parser.parse_args()
    if not 1 <= args.seconds <= 60 or not 0 <= args.sample_seconds <= 10:
        parser.error("seconds must be 1–60; sample-seconds must be 0–10")
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", args.bundle_id):
        parser.error("bundle-id must be a dotted application identifier")
    matches = matching_processes(args.bundle_id)
    if args.pid is not None:
        if args.pid not in matches:
            parser.error("PID does not belong to a running Blocks bundle")
        pid = args.pid
    elif len(matches) == 1:
        pid = next(iter(matches))
    else:
        parser.error(f"expected one Blocks process, found {list(matches)}; use --pid")

    if args.output:
        output = args.output.resolve()
        output.mkdir(mode=0o700, parents=True, exist_ok=False)
    else:
        output = Path(tempfile.mkdtemp(prefix="ghostty-blocks-diagnostics-"))
    os.chmod(output, 0o700)
    repository = Path(__file__).resolve().parents[2]
    result = {
        "schema": 1,
        "started_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "pid": pid, "bundle_id": args.bundle_id, "executable": str(matches[pid]),
        "phase": args.phase, "visibility_observer_label": args.visibility,
        "visibility_verified_by_script": False,
        "source_commit": run("git", "-C", str(repository), "rev-parse", "HEAD").strip(),
        "source_dirty": bool(run("git", "-C", str(repository), "status", "--porcelain")),
        "source_commit_is_not_proof_of_running_binary_revision": True,
        "host": {
            "os": run("sw_vers").strip(), "uptime": run("uptime").strip(),
            "cpu": run("sysctl", "-n", "machdep.cpu.brand_string").strip(),
            "logical_cores": int(run("sysctl", "-n", "hw.ncpu")),
            "physical_memory_bytes": int(run("sysctl", "-n", "hw.memsize")),
            "memory_pressure_query": run("memory_pressure", "-Q").strip(),
        },
        "before": process_snapshot(pid),
        "descendants_before": descendants(pid),
    }
    top = run(
        "top", "-l", str(args.seconds + 1), "-s", "1", "-pid", str(pid),
        "-stats", "pid,command,cpu,mem,threads,state,time", timeout=args.seconds + 15,
    )
    (output / "top.txt").write_text(top)
    samples = []
    for line in top.splitlines():
        fields = line.split()
        if len(fields) >= 7 and fields[0] == str(pid):
            samples.append({
                "cpu_percent": float(fields[2]), "top_mem_display": fields[3],
                "threads_display": fields[4], "state": fields[5], "cpu_time": fields[6],
            })
    # top's first %CPU sample has no preceding interval and is normally zero.
    intervals = samples[1:]
    result["top_interval_samples"] = intervals
    cpus = [s["cpu_percent"] for s in intervals]
    result["cpu_interval_summary"] = {
        "count": len(cpus),
        "median_percent_of_one_core": statistics.median(cpus) if cpus else None,
        "max_percent_of_one_core": max(cpus) if cpus else None,
    }
    result["after"] = process_snapshot(pid)
    result["descendants_after"] = descendants(pid)
    if args.sample_seconds:
        # Recheck identity to avoid sampling an unrelated recycled PID.
        if matching_processes(args.bundle_id).get(pid) != matches[pid]:
            raise SystemExit("Blocks process changed; refusing stack sample")
        sample_path = output / "stacks.txt"
        run("sample", str(pid), str(args.sample_seconds), "-file", str(sample_path), timeout=args.sample_seconds + 30)
        sample = sample_path.read_text()
        result["stack_sample"] = {"seconds": args.sample_seconds, "path": str(sample_path)}
        for label, key in [("Physical footprint", "physical_footprint_display"), ("Physical footprint (peak)", "peak_physical_footprint_display")]:
            found = re.search(rf"^{re.escape(label)}:\s+(.+)$", sample, re.MULTILINE)
            if found:
                result["stack_sample"][key] = found.group(1)
    result["finished_utc"] = dt.datetime.now(dt.timezone.utc).isoformat()
    (output / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    print(output / "summary.json")
    print(json.dumps(result["cpu_interval_summary"]))


if __name__ == "__main__":
    main()
