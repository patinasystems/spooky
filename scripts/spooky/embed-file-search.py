#!/usr/bin/env python3
"""Copy the prebuilt filename-search helper before Xcode signs the app.

Cargo and dependency preparation run in build.nu, outside Xcode's script
sandbox. This phase only reads declared inputs and writes bundle outputs.
"""

from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess


def main() -> None:
    source = Path(os.environ["SPOOKY_FSEARCH_HELPER_DIR"])
    provenance = json.loads((source / "fsearch-provenance.json").read_text())
    if hashlib.sha256((source / "spooky-fsearch").read_bytes()).hexdigest() != provenance.get("executable_sha256"):
        raise SystemExit("Filename-search helper does not match its provenance; rebuild with macos/build.nu")
    contents = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["CONTENTS_FOLDER_PATH"]
    resources = contents / "Resources" / "FSearch"
    helper = contents / "Helpers" / "spooky-fsearch"
    helper.parent.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    inputs = {
        "spooky-fsearch": helper,
        "LICENSE.fsearch": resources / "LICENSE.fsearch",
        "LICENSE.dependencies": resources / "LICENSE.dependencies",
        "fsearch-provenance.json": resources / "fsearch-provenance.json",
    }
    for name, destination in inputs.items():
        original = source / name
        if not original.is_file():
            raise SystemExit(f"Missing {original}; build with macos/build.nu to prepare file search")
        shutil.copy2(original, destination)
    helper.chmod(0o755)
    identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"
    if os.environ.get("CODE_SIGNING_ALLOWED") != "NO":
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity,
                        "--options", "runtime", "--timestamp=none", str(helper)], check=True)


if __name__ == "__main__":
    main()
