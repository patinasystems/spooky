#!/usr/bin/env python3
"""Export the approved black artwork to macOS app and in-app icon assets."""
import json
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[2]
ARTWORK = ROOT / "images/spooky/icon-black.png"
ASSETS = ROOT / "macos/Assets.xcassets"


def export(destination: Path, size: int) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/usr/bin/sips", "-z", str(size), str(size), str(ARTWORK),
                    "--out", str(destination)], check=True, capture_output=True)


def main() -> None:
    appicon = ASSETS / "Spooky.appiconset"
    images = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            name = f"icon_{points}x{points}@{scale}x.png"
            export(appicon / name, points * scale)
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x",
                           "size": f"{points}x{points}"})
    (appicon / "Contents.json").write_text(json.dumps({
        "images": images, "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")
    # About, pre-Tahoe Dock tiles, and other app surfaces share the same artwork.
    for name, size in (("macOS-AppIcon-256px-128pt@2x.png", 256),
                       ("macOS-AppIcon-512px.png", 512), ("macOS-AppIcon-1024px.png", 1024)):
        export(ASSETS / "AppIconImage.imageset" / name, size)


if __name__ == "__main__":
    main()
