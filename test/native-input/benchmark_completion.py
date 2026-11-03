#!/usr/bin/env python3
"""Build a bounded optimized helper benchmark. Run through Pat, not directly.

Compiles immutable copies of the real helper/transport sources and the previous
HEAD helper, so the baseline does not substitute a different matching workload.
"""

import argparse
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iterations", type=int, default=2000)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--baseline-ref", default="HEAD", help="Git revision containing the prior helper")
    arguments = parser.parse_args()
    if not 1 <= arguments.iterations <= 20000:
        parser.error("iterations must be between 1 and 20000")
    root = Path(__file__).resolve().parents[2]
    sources = root / "macos/Sources/Features/Command Input"
    current = (sources / "CommandCompletionContext.swift").read_text()
    legacy = subprocess.check_output([
        "git", "show", f"{arguments.baseline_ref}:macos/Sources/Features/Command Input/CommandCompletionContext.swift"
    ], cwd=root, text=True)
    legacy_hash = hashlib.sha256(legacy.encode()).hexdigest()
    legacy = legacy.replace("CommandCompletionToken", "LegacyCommandCompletionToken")
    legacy = legacy.replace("CommandCompletionFilter", "LegacyCommandCompletionFilter")
    legacy = legacy.replace("CommandCompletionQuery", "LegacyCommandCompletionQuery")
    models = (sources / "CommandCompletionView.swift").read_text().split("/// A child panel", 1)[0]
    models = models.replace("import AppKit", "import Foundation", 1)
    bridge = (sources / "CommandCompletionBridge.swift").read_text()
    offset_helper = bridge[bridge.index("    static func byteOffset"):bridge.index("    static func utf16Offset")]
    with tempfile.TemporaryDirectory(prefix="spooky-completion-benchmark-") as temporary:
        directory = Path(temporary)
        for name, contents in {
            "Context.swift": current,
            "Legacy.swift": legacy,
            "Models.swift": models,
            "Bridge.swift": "import Foundation\nenum CommandCompletionBridge {\n" + offset_helper + "}\n",
            "Benchmark.swift": Path(__file__).with_suffix(".swift").read_text(),
        }.items():
            (directory / name).write_text(contents)
        executable = directory / "benchmark"
        subprocess.run(["/usr/bin/swiftc", "-O", *map(str, directory.glob("*.swift")), "-o", str(executable)], check=True)
        result = json.loads(subprocess.check_output([str(executable), str(arguments.iterations)], text=True))
    result["current_helper_sha256"] = hashlib.sha256(current.encode()).hexdigest()
    result["prior_helper_sha256"] = legacy_hash
    if arguments.output:
        arguments.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
