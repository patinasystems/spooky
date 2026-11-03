#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["dmgbuild==1.6.7"]
# ///
"""Assemble a non-notarized arm64 preview without modifying its source app.

Run with `uv run scripts/spooky/package.py --help`, or with the Python from
an existing dmgbuild 1.6.7 environment. Building, installing, uploading, and
notarization are separate operations. No Finder automation is used.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile


BUNDLE_ID = "com.patinasystems.spooky"
MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}


def run(*args: str | Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(arg) for arg in args], check=True, text=True, capture_output=True)


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def read_bundle(app: Path) -> dict:
    app = app.resolve(strict=True)
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if app.name != "Spooky.app" or info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise ValueError("Expected the normal Spooky.app (com.patinasystems.spooky), not a test candidate")
    if info.get("CFBundleDisplayName") != "Spooky":
        raise ValueError("Bundle display name must be Spooky")
    if info.get("SpookyNativeInputEnabled") is not True:
        raise ValueError("Native command input must be enabled in the packaged app")
    if info.get("SpookyDisableUpstreamUpdates") is not True or info.get("SUEnableAutomaticChecks") is not False:
        raise ValueError("Preview must keep upstream Ghostty updates disabled")
    if info.get("SUFeedURL"):
        raise ValueError("Preview must not advertise an update feed")
    version = info.get("CFBundleShortVersionString", "")
    if not isinstance(version, str) or not re.fullmatch(r"[0-9][A-Za-z0-9.-]{0,63}", version):
        raise ValueError("Bundle has an invalid release version")
    executable = info.get("CFBundleExecutable", "")
    if not executable or Path(executable).name != executable or executable in {".", ".."}:
        raise ValueError("Bundle executable must be a single filename")
    for entry in app.rglob("*"):
        if entry.suffix in {".xctest", ".dSYM"}:
            raise ValueError(f"Test/debug residue in source app: {entry.relative_to(app)}; use a clean build directory")
        if entry.is_symlink() and not entry.resolve().is_relative_to(app):
            raise ValueError(f"App contains an external symlink: {entry.relative_to(app)}")
    return info


def signing_details(path: Path) -> dict:
    details = run("/usr/bin/codesign", "--display", "--verbose=2", path).stderr
    return {
        "authorities": [line.partition("=")[2] for line in details.splitlines() if line.startswith("Authority=")],
        "team_identifier": next((line.partition("=")[2] for line in details.splitlines() if line.startswith("TeamIdentifier=")), None),
        "ad_hoc": "Signature=adhoc" in details,
    }


def macho_files(app: Path) -> list[Path]:
    result = []
    for path in app.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open("rb") as stream:
            if stream.read(4) in MACHO_MAGICS:
                result.append(path)
    return sorted(result, key=lambda path: len(path.parts), reverse=True)


def sign_app(app: Path, identity: str) -> None:
    # Sign every executable, then enclosing bundles inside-out. Preserve each
    # component's entitlements, but regenerate its designated requirement for
    # the selected identity. Do not use --deep for signing.
    bundles = [path for path in app.rglob("*") if path.is_dir() and not path.is_symlink()
               and path.suffix in {".app", ".xpc", ".framework", ".plugin"}]
    targets = macho_files(app) + sorted(bundles, key=lambda path: len(path.parts), reverse=True) + [app]
    for target in targets:
        run("/usr/bin/codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp",
            "--preserve-metadata=entitlements", target)


def package(args: argparse.Namespace) -> dict:
    if sys.platform != "darwin":
        raise ValueError("DMG assembly and signing require macOS")
    if importlib.metadata.version("dmgbuild") != "1.6.7":
        raise ValueError("Use dmgbuild 1.6.7 (uv run installs the pinned dependency)")
    import dmgbuild

    app = args.app.resolve(strict=True)
    output = args.output_dir.resolve()
    if output == app or output.is_relative_to(app):
        raise ValueError("Output directory must be outside the source app")
    if not re.fullmatch(r"[0-9a-fA-F]{7,40}", args.source_commit):
        raise ValueError("--source-commit must identify the commit actually used to build this app")
    info = read_bundle(app)
    executable = Path("Contents/MacOS") / info["CFBundleExecutable"]
    architectures = run("/usr/bin/lipo", "-archs", app / executable).stdout.split()
    if architectures != ["arm64"]:
        raise ValueError(f"This preview is explicitly arm64; got architectures: {architectures}")
    run("/usr/bin/codesign", "--verify", "--strict", "--deep", app)
    entitlements = run("/usr/bin/codesign", "--display", "--entitlements", ":-", app).stdout
    if entitlements and plistlib.loads(entitlements.encode()).get("com.apple.security.get-task-allow"):
        raise ValueError("Do not package a debugger-enabled app")

    stem = f"Spooky-{info['CFBundleShortVersionString']}-{args.source_commit[:9]}-arm64"
    names = [f"{stem}.dmg", "Spooky.dmg", f"{stem}.json", "SHA256SUMS"]
    if not args.overwrite and any((output / name).exists() for name in names):
        raise ValueError("Output artifacts already exist; choose a new directory or explicitly pass --overwrite")
    output.mkdir(parents=True, exist_ok=True)
    source_sha = sha256(app / executable)
    source_signing = signing_details(app)
    with tempfile.TemporaryDirectory(prefix=".spooky-package-", dir=output) as temporary:
        work = Path(temporary)
        staged = work / "Spooky.app"
        run("/usr/bin/ditto", app, staged)
        if args.identity:
            sign_app(staged, args.identity)
        run("/usr/bin/codesign", "--verify", "--strict", "--deep", staged)
        packaged_sha = sha256(staged / executable)
        dmg = work / names[0]
        dmgbuild.build_dmg(str(dmg), "Spooky Preview", settings_file=str(Path(__file__).with_name("dmg-settings.py")),
                          defines={"app": str(staged)})
        if args.identity:
            run("/usr/bin/codesign", "--sign", args.identity, "--timestamp", dmg)
            run("/usr/bin/codesign", "--verify", "--strict", dmg)
        run("/usr/bin/hdiutil", "verify", dmg)
        manifest = {
            "product": "Spooky", "release_kind": "preview", "notarized": False,
            "bundle_identifier": BUNDLE_ID, "version": info["CFBundleShortVersionString"],
            "build_number": str(info.get("CFBundleVersion", "")), "minimum_macos": info.get("LSMinimumSystemVersion"),
            "architecture": "arm64", "source_commit": args.source_commit,
            "source_executable_sha256": source_sha, "packaged_executable_sha256": packaged_sha,
            "source_signing": source_signing, "packaged_signing": signing_details(staged),
            "upstream_updates_disabled": True, "native_input_enabled": True,
            "dmg": {"file": names[0], "sha256": sha256(dmg), "bytes": dmg.stat().st_size},
        }
        (work / names[2]).write_text(json.dumps(manifest, indent=2) + "\n")
        shutil.copy2(dmg, work / names[1])
        (work / names[3]).write_text("".join(f"{sha256(work / name)}  {name}\n" for name in names[:3]))
        for name in names:
            os.replace(work / name, output / name)
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path, help="Clean normal Spooky.app; source remains unchanged")
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--source-commit", required=True, help="Commit actually compiled into the source app")
    parser.add_argument("--identity", help="Optional local signing identity; signs the staging copy and DMG")
    parser.add_argument("--overwrite", action="store_true", help="Replace existing output artifacts")
    try:
        print(json.dumps(package(parser.parse_args()), indent=2))
    except (ValueError, OSError, subprocess.CalledProcessError, importlib.metadata.PackageNotFoundError) as error:
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr, file=sys.stderr)
        parser.exit(1, f"Packaging failed: {error}\n")


if __name__ == "__main__":
    main()
