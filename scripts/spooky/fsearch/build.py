#!/usr/bin/env python3
"""Build the pinned app-owned filename helper; run inside the caller's Pat slot."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent


def run(*args, cwd=ROOT, **kwargs):
    return subprocess.run(args, cwd=cwd, check=True, **kwargs)


def prepare():
    pin = json.loads((ROOT / "upstream.json").read_text())
    source = ROOT / ".upstream"
    if not source.exists():
        run("git", "clone", "--no-checkout", pin["repository"], str(source))
        run("git", "checkout", "--detach", pin["revision"], cwd=source)
    revision = run("git", "rev-parse", "HEAD", cwd=source, capture_output=True, text=True).stdout.strip()
    if revision != pin["revision"]:
        raise SystemExit(f"Unexpected fsearch checkout: {revision}; expected {pin['revision']}")
    patch = (ROOT / pin["patch"]).read_bytes()
    diff = run("git", "diff", "--binary", cwd=source, capture_output=True).stdout
    if not diff:
        run("git", "apply", str(ROOT / pin["patch"]), cwd=source)
        diff = run("git", "diff", "--binary", cwd=source, capture_output=True).stdout
    if diff != patch:
        raise SystemExit("fsearch checkout has changes other than the checked names-only patch")
    untracked = run("git", "ls-files", "--others", "--exclude-standard", cwd=source, capture_output=True).stdout
    if untracked:
        raise SystemExit("fsearch checkout has unexpected untracked files")
    return pin, patch


def dependency_licenses(cargo):
    metadata = json.loads(run(cargo, "metadata", "--locked", "--format-version", "1",
                              capture_output=True, text=True).stdout)
    sections = ["Spooky filename search — locked Rust dependency notices\n"
                "fsearch's own MIT license is provided separately in LICENSE.fsearch.\n"
                "Cargo.lock SHA256: " + hashlib.sha256((ROOT / "Cargo.lock").read_bytes()).hexdigest() + "\n"]
    for package in sorted(metadata["packages"], key=lambda item: (item["name"], item["version"])):
        if package["source"] is None:
            continue
        directory = Path(package["manifest_path"]).parent
        notices = sorted(path for path in directory.iterdir() if path.is_file()
                         and path.name.upper().startswith(("LICENSE", "NOTICE", "COPYING")))
        if not notices:
            raise SystemExit(f"No dependency license files found for {package['name']}")
        sections.append(f"\n{'=' * 72}\n{package['name']} {package['version']}\n"
                        f"Declared license: {package.get('license') or 'see notice'}\n"
                        f"https://crates.io/crates/{package['name']}/{package['version']}\n")
        for notice in notices:
            sections.append(f"\n--- {notice.name} ---\n{notice.read_text().rstrip()}\n")
    return "".join(sections).encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--architectures", nargs="+", choices=["arm64", "x86_64"], default=["arm64"])
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--update-licenses", action="store_true", help="Regenerate checked notices from Cargo.lock")
    parser.add_argument("--test", action="store_true", help="Run fixture-only helper tests before building")
    args = parser.parse_args()
    pin, patch = prepare()
    if args.prepare_only:
        return
    cargo = shutil.which("cargo") or str(Path.home() / ".cargo/bin/cargo")
    licenses = dependency_licenses(cargo)
    if args.update_licenses:
        (ROOT / "LICENSE.dependencies").write_bytes(licenses)
        return
    if licenses != (ROOT / "LICENSE.dependencies").read_bytes():
        raise SystemExit("Dependency notices changed; run build.py --update-licenses and review them")
    if args.output_dir is None:
        parser.error("--output-dir is required when building")
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    target_dir = output / "target"
    env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET="13.0")
    if args.test:
        run(cargo, "test", "--locked", "--jobs", "4", "--target-dir", str(target_dir), env=env)
    binaries = []
    for architecture in dict.fromkeys(args.architectures):
        target = {"arm64": "aarch64-apple-darwin", "x86_64": "x86_64-apple-darwin"}[architecture]
        run(cargo, "build", "--locked", "--jobs", "4", "--release", "--target", target, "--target-dir", str(target_dir), env=env)
        binaries.append(target_dir / target / "release/spooky-fsearch")
    binary = output / "spooky-fsearch"
    if len(binaries) == 1:
        shutil.copy2(binaries[0], binary)
    else:
        run("/usr/bin/lipo", "-create", *map(str, binaries), "-output", str(binary))
    binary.chmod(0o755)
    shutil.copy2(ROOT / "LICENSE.fsearch", output / "LICENSE.fsearch")
    shutil.copy2(ROOT / "LICENSE.dependencies", output / "LICENSE.dependencies")
    provenance = dict(pin, architectures=list(dict.fromkeys(args.architectures)),
                      patch_sha256=hashlib.sha256(patch).hexdigest(),
                      cargo_lock_sha256=hashlib.sha256((ROOT / "Cargo.lock").read_bytes()).hexdigest(),
                      adapter_source_sha256=hashlib.sha256((ROOT / "Cargo.toml").read_bytes() + b"\0"
                                                          + (ROOT / "src/main.rs").read_bytes()).hexdigest(),
                      dependency_licenses_sha256=hashlib.sha256(licenses).hexdigest(),
                      executable_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                      content_indexing=False, idle_keep_warm=False)
    (output / "fsearch-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print(binary)


if __name__ == "__main__":
    main()
