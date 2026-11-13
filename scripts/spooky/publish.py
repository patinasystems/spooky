#!/usr/bin/env python3
"""Publish a verified, notarized release to Patina's public download bucket.

Unnotarized previews require the explicit --allow-unnotarized-preview override.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import notarization
import package as packager

ACCOUNT = "18ec6d33bace40aeb49062a30ee143d5"
BUCKET = "lipboard-downloads"
BASE_URL = "https://downloads.patinasystems.com/spooky/"
TOOLS = Path(__file__).resolve().parent


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def remote_digest(name: str) -> str | None:
    try:
        # Do not populate a negative CDN cache entry when checking a new key,
        # or compare a freshly published alias against a previous cached build.
        request = Request(BASE_URL + name + "?verify=" + uuid.uuid4().hex,
                          headers={"User-Agent": "Spooky-Release/0.1"})
        with urlopen(request, timeout=60) as response:
            result = hashlib.sha256()
            while chunk := response.read(1024 * 1024):
                result.update(chunk)
            return result.hexdigest()
    except HTTPError as error:
        if error.code == 404:
            return None
        raise


def verify_contained_app(dmg: Path, manifest: dict, team: str) -> None:
    with notarization.mounted_image(dmg) as mounted:
        app = mounted / 'Spooky.app'
        if app.is_symlink() or not app.is_dir() or not app.resolve().is_relative_to(mounted.resolve()):
            raise ValueError('Disk image must contain a real Spooky.app at its root')
        applications = mounted / 'Applications'
        if not applications.is_symlink() or os.readlink(applications) != '/Applications':
            raise ValueError('Disk image must contain an Applications shortcut pointing exactly to /Applications')
        info = packager.read_bundle(app)
        file_search = packager.read_file_search(app)
        if (info.get('CFBundleShortVersionString') != manifest['version']
                or str(info.get('CFBundleVersion', '')) != manifest.get('build_number')
                or info.get('LSMinimumSystemVersion') != manifest.get('minimum_macos')):
            raise ValueError('Contained app version/build/platform metadata does not match the manifest')
        main = app / 'Contents/MacOS' / info['CFBundleExecutable']
        if (digest(main) != manifest.get('packaged_executable_sha256')
                or file_search != manifest.get('file_search')):
            raise ValueError('Contained app does not match the packaged manifest hashes/backend')
        if packager.run('/usr/bin/lipo', '-archs', main).stdout.split() != ['arm64']:
            raise ValueError('Contained app is not the claimed arm64 build')
        for target in packager.signing_targets(app):
            notarization.verify_developer_signature(target, team=team)
        notarization.verify_ticket(app)


def artifacts(manifest_path: Path, *, allow_unnotarized_preview: bool = False) -> list[tuple[Path, str, str, bool]]:
    manifest = json.loads(manifest_path.read_text())
    if (manifest.get("product") != "Spooky"
            or manifest.get("bundle_identifier") != "com.patinasystems.spooky"
            or manifest.get("architecture") != "arm64"
            or manifest.get("upstream_updates_disabled") is not True):
        raise ValueError("Expected a Spooky arm64 release manifest with upstream updates disabled")
    if manifest.get("file_search") != packager.FILE_SEARCH:
        raise ValueError("Expected native Spotlight file search without an app-owned index")
    if (not isinstance(manifest.get("source_commit"), str)
            or not re.fullmatch(r"[0-9a-fA-F]{7,40}", manifest["source_commit"])
            or not isinstance(manifest.get("version"), str)
            or not re.fullmatch(r"[0-9][A-Za-z0-9.-]{0,63}", manifest["version"])):
        raise ValueError("Manifest has an invalid source commit or version")
    if manifest.get("notarized") is not True:
        if (not allow_unnotarized_preview or manifest.get("notarized") is not False
                or manifest.get("release_kind") != "preview"):
            raise ValueError("Public releases must be notarized. An explicitly labeled preview requires "
                             "--allow-unnotarized-preview; this does not bypass Gatekeeper.")
    elif manifest.get("release_kind") != "release":
        raise ValueError("A notarized artifact must use release_kind=release")
    filename = manifest["dmg"]["file"]
    expected_name = f"Spooky-{manifest['version']}-{manifest['source_commit'][:9]}-arm64.dmg"
    if filename != expected_name or Path(filename).name != filename:
        raise ValueError("Manifest DMG filename does not match its version")
    dmg = manifest_path.parent / filename
    if digest(dmg) != manifest["dmg"]["sha256"] or dmg.stat().st_size != manifest["dmg"]["bytes"]:
        raise ValueError("DMG does not match its manifest")
    if manifest.get("notarized") is True:
        receipts = manifest.get("notarization", {})
        if not isinstance(receipts, dict):
            raise ValueError("Missing valid notarization receipts")
        for component in ("app", "dmg"):
            receipt = receipts.get(component, {})
            try:
                uuid.UUID(receipt.get("id", ""))
            except (ValueError, AttributeError, TypeError) as error:
                raise ValueError(f"Missing valid {component} notarization receipt") from error
            if (receipt.get("status") != "Accepted" or receipt.get("stapled") is not True
                    or receipt.get("gatekeeper_accepted") is not True):
                raise ValueError(f"Missing accepted/stapled {component} notarization evidence")
        # Never trust a hand-edited manifest's notarized=true flag alone.
        team = notarization.verify_developer_signature(dmg, runtime=False)
        notarization.verify_ticket(dmg, disk_image=True)
        verify_contained_app(dmg, manifest, team)
    if dmg.stat().st_size >= 300 * 1024 * 1024:
        raise ValueError("Use a multipart uploader for artifacts of 300 MiB or more")
    if manifest_path.name != dmg.with_suffix(".json").name:
        raise ValueError("Manifest filename must match the versioned DMG")
    sums = manifest_path.parent / "SHA256SUMS"
    expected = {filename: digest(dmg), "Spooky.dmg": digest(dmg), manifest_path.name: digest(manifest_path)}
    actual = dict((name, checksum) for checksum, name in (line.split() for line in sums.read_text().splitlines()))
    if actual != expected:
        raise ValueError("SHA256SUMS does not match the release artifacts")
    return [
        (dmg, filename, "application/x-apple-diskimage", True),
        (manifest_path, manifest_path.name, "application/json", True),
        (dmg, "Spooky.dmg", "application/x-apple-diskimage", False),
        (manifest_path, "latest.json", "application/json", False),
        (sums, "SHA256SUMS", "text/plain; charset=utf-8", False),
    ]


def publish(manifest: Path, dry_run: bool, *, allow_unnotarized_preview: bool = False) -> None:
    files = artifacts(manifest, allow_unnotarized_preview=allow_unnotarized_preview)
    existing = {}
    for path, name, _, immutable in files:
        if immutable:
            existing[name] = remote_digest(name)
            if existing[name] not in (None, digest(path)):
                raise ValueError(f"Refusing to replace immutable release {name}; build a new version")
    print(f"Account {ACCOUNT}; bucket {BUCKET}; public prefix spooky/", flush=True)
    environment = dict(os.environ, CLOUDFLARE_ACCOUNT_ID=ACCOUNT, WRANGLER_SEND_METRICS="false")
    for path, name, content_type, immutable in files:
        print(f"{'Check' if dry_run else 'Publish'} {BASE_URL + name}", flush=True)
        if dry_run or (immutable and existing.get(name) == digest(path)):
            continue
        # The shared host can extend a short browser TTL to four hours for
        # cacheable DMGs. Keep mutable aliases fresh without changing its rules.
        cache = "public, max-age=31536000, immutable" if immutable else "no-store"
        subprocess.run([
            "bun", "run", "wrangler", "r2", "object", "put", f"{BUCKET}/spooky/{name}",
            "--remote", "--file", str(path), "--content-type", content_type, "--cache-control", cache,
        ], cwd=TOOLS, env=environment, check=True)
    if not dry_run:
        # Validate anonymous downloads through the real public host, not only
        # upload receipts. Versioned and stable DMGs must have identical bytes.
        for path, name, _, _ in files:
            if remote_digest(name) != digest(path):
                raise ValueError(f"Public download verification failed: {BASE_URL + name}")
        print("Fresh public reads of all five objects match their local SHA-256 checksums.", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--dry-run", action="store_true", help="Validate artifacts and destination without uploading")
    parser.add_argument("--allow-unnotarized-preview", action="store_true",
                        help="Explicitly publish a labeled preview that still requires Gatekeeper approval")
    args = parser.parse_args()
    try:
        publish(args.manifest.resolve(strict=True), args.dry_run,
                allow_unnotarized_preview=args.allow_unnotarized_preview)
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Publish failed: {error}\n")


if __name__ == "__main__":
    main()
