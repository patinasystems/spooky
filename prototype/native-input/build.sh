#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
zig_bin=${GHOSTTY_ZIG:-zig}

if ! command -v "$zig_bin" >/dev/null 2>&1 || ! command -v nu >/dev/null 2>&1; then
    echo "Install Zig 0.17.x and Nushell. GHOSTTY_ZIG may point to the Zig binary." >&2
    exit 1
fi

cd "$repo_root"
"$zig_bin" build -Demit-macos-app=false -Doptimize=ReleaseFast -Dxcframework-target=native -j4
nu macos/build.nu \
    --configuration ReleaseLocal \
    --arch "$(uname -m)" \
    --build-dir "$repo_root/macos/build-spooky" \
    --xcconfig "$repo_root/prototype/native-input/spooky.xcconfig"
