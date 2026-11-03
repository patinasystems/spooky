#!/usr/bin/env python3
"""Run the paired command-caption viewport lookup benchmark through Pat.

Example (run from the repository through a four-core Pat job):
    uv run --no-project python test/native-input/benchmark_command_chrome.py \
        --zig /absolute/path/to/zig --output /tmp/command-chrome.json

The normal test target deliberately uses Debug for its root module. Derive its
compiler invocation, then optimize that module without editing build.zig. The
same dependencies and fixtures serve both lookup implementations. No application
launch, terminal interaction, frame timing, or GPU measurement is performed.
"""

import argparse
import hashlib
import json
import shlex
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def optimized_command(log, jobs):
    """Extract the real test compile command; never execute log text in a shell."""
    for line in log.splitlines():
        try:
            args = shlex.split(line.removeprefix("failed command: "))
        except ValueError:
            continue
        if len(args) < 2 or args[1] != "test" or "--name" not in args:
            continue
        if args[args.index("--name") + 1] != "ghostty-test":
            continue
        args.remove("--listen=-")
        # This is the root module's option. Dependency module flags stay intact.
        args[args.index("-Odebug")] = "-Ofast"
        # Cached Debug C libraries require the runtime even with a Fast root.
        args[2:2] = [f"-j{jobs}", "-fubsan-rt"]
        return args
    raise RuntimeError("Could not find the ghostty-test compiler command in the verbose build log")


def run_logged(command, log_path):
    with log_path.open("w") as log:
        result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f"Command exited {result.returncode}; see {log_path}")
    return log_path.read_text()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", required=True)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--log-directory", type=Path)
    options = parser.parse_args()
    if not 1 <= options.jobs <= 4:
        parser.error("jobs must be between one and four; run through Pat with the same core budget")
    log_directory = options.log_directory or Path(tempfile.mkdtemp(prefix="command-chrome-benchmark-"))
    log_directory.mkdir(parents=True, exist_ok=True)
    source = ROOT / "src/renderer/CommandChrome.zig"
    source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
    build_log = run_logged([
        options.zig, "build", "test", "-Dtest-filter=command chrome",
        "-Demit-macos-app=false", f"-j{options.jobs}", "--verbose",
    ], log_directory / "regressions.log")
    command = optimized_command(build_log, options.jobs)
    (log_directory / "optimized-argv.json").write_text(json.dumps(command, indent=2) + "\n")
    benchmark_log = run_logged(command, log_directory / "benchmark.log")
    if hashlib.sha256(source.read_bytes()).hexdigest() != source_hash:
        raise RuntimeError("CommandChrome.zig changed during measurement; discard this run")
    samples = [json.loads(line) for line in benchmark_log.splitlines() if line.startswith('{"benchmark":')]
    if len(samples) != 9:
        raise RuntimeError(f"Expected nine measured cases, found {len(samples)}; see {log_directory}")
    report = {
        "source_sha256": source_hash,
        "zig_version": subprocess.check_output([options.zig, "version"], text=True).strip(),
        "root_optimization": "Fast; dependency module flags unchanged",
        "scope": "CPU viewport lookup batch only; fixture construction, caption shaping, frames, shell, and UI excluded",
        "positions": {"0": "history top", "1": "history middle", "2": "live end"},
        "fixture": "80 columns, 40 viewport rows, 16 retained rows per header",
        "method": "21 paired samples, 16 batches per sample, three warmups, alternating A/B order, equal checksums",
        "lookup_allocations": {"before": 0, "after": 0},
        "additional_retained_bytes": 0,
        "cases": samples,
        "logs": str(log_directory),
    }
    if options.output:
        options.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
