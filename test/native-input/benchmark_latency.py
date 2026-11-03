#!/usr/bin/env python3
"""Measure native zsh submission without the app, renderer, or user dotfiles.

Uses the existing private PTY fixture. macOS kqueue wakes on PTY output and
atomic bridge-file publication; timestamps describe observation, not the exact
instant a shell write occurred. Run this through Pat, as other repository work.
"""

import argparse
import hashlib
import json
import math
import os
import select
import statistics
import time
from pathlib import Path

import test_zsh_bridge


def summarize(samples):
    result = {}
    for field in samples[0]:
        values = sorted(sample[field] for sample in samples)
        result[field] = {
            "median": statistics.median(values),
            "mean": statistics.mean(values),
            "p95": values[math.ceil(len(values) * 0.95) - 1],
            "max": max(values),
        }
    return result


def measure(shell, queue, command):
    state = shell.state()
    generation, block = state[1], state[3]
    marker = b"\x1b]133;C;aid=" + block.encode() + b"\x07"
    output_start = len(shell.output)
    started = time.perf_counter_ns()
    identifier = shell.stage(command)
    trigger = time.perf_counter_ns()
    shell.trigger()
    row = {"request_write_ms": (trigger - started) / 1e6}
    deadline = trigger + 5_000_000_000
    while time.perf_counter_ns() < deadline:
        queue.control(None, 32, 1)
        while True:
            try:
                chunk = os.read(shell.terminal, 65536)
            except BlockingIOError:
                break
            if not chunk:
                raise RuntimeError("The shell PTY closed during measurement")
            shell.output.extend(chunk)
            if "terminal_C_ms" not in row and marker in shell.output[output_start:]:
                row["terminal_C_ms"] = (time.perf_counter_ns() - trigger) / 1e6
        if "receipt_ms" not in row and shell.receipt()[:2] == ["accepted", identifier]:
            row["receipt_ms"] = (time.perf_counter_ns() - trigger) / 1e6
        current = shell.state()
        if "next_ready_ms" not in row and current[0] == "ready" and current[1] != generation:
            row["next_ready_ms"] = (time.perf_counter_ns() - trigger) / 1e6
        if all(field in row for field in ("receipt_ms", "terminal_C_ms", "next_ready_ms")):
            row["request_to_receipt_ms"] = row["request_write_ms"] + row["receipt_ms"]
            row["request_to_C_ms"] = row["request_write_ms"] + row["terminal_C_ms"]
            row["request_to_ready_ms"] = row["request_write_ms"] + row["next_ready_ms"]
            return row
    raise RuntimeError(f"Timed out observing submission: {row}; state={shell.state()!r}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iterations", type=int, default=20)
    parser.add_argument("--warmup", type=int, default=5)
    parser.add_argument("--command", default=":")
    parser.add_argument("--label", default="current")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--adapter", type=Path, help="Use an immutable adapter snapshot for before/after comparisons")
    options = parser.parse_args()
    if options.iterations < 1 or options.warmup < 0:
        parser.error("iterations must be positive and warmup must be nonnegative")
    if not hasattr(select, "kqueue"):
        parser.error("This benchmark requires macOS/BSD kqueue")
    if options.adapter:
        test_zsh_bridge.ADAPTER = options.adapter.resolve()
    shell = test_zsh_bridge.Shell()
    queue = select.kqueue()
    directory = os.open(shell.bridge, os.O_RDONLY)
    try:
        queue.control([
            select.kevent(shell.terminal, filter=select.KQ_FILTER_READ,
                          flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE),
            select.kevent(directory, filter=select.KQ_FILTER_VNODE,
                          flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_CLEAR,
                          fflags=select.KQ_NOTE_WRITE),
        ], 0, 0)
        # Hash the immutable fixture copy, even if another agent edits source.
        adapter_hash = hashlib.sha256((shell.bridge / "native-input.zsh").read_bytes()).hexdigest()
        startup_hash = hashlib.sha256((shell.bridge / ".zshenv").read_bytes()).hexdigest()
        samples = []
        for index in range(options.warmup + options.iterations):
            row = measure(shell, queue, options.command)
            if index >= options.warmup:
                samples.append(row)
    finally:
        queue.close()
        os.close(directory)
        shell.close()
    result = {
        "label": options.label,
        "samples": options.iterations,
        "warmup": options.warmup,
        "command": options.command,
        "adapter_sha256": adapter_hash,
        "startup_sha256": startup_hash,
        "clock": "perf_counter_ns",
        "wake": "kqueue: PTY read and bridge directory writes",
        "summary_ms": summarize(samples),
        "samples_ms": samples,
        "scope": "Private synthetic zsh startup and builtin command in temporary directory; app, user hooks, git repository, and renderer excluded.",
        "caveat": "Event observation latency includes scheduler delay and filesystem reads. C is matching OSC 133 bytes observed on the PTY, not a renderer frame.",
    }
    if options.output:
        options.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: result[key] for key in ("label", "samples", "adapter_sha256", "summary_ms")}, indent=2))


if __name__ == "__main__":
    main()
