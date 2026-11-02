#!/bin/sh
# Launch Blocks beside the original native-input prototype and upstream Ghostty.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
app_path=${1:-"$repo_root/macos/build-blocks/ReleaseLocal/Ghostty.app"}
binary_path="$app_path/Contents/MacOS/ghostty"

if [ ! -x "$binary_path" ]; then
    echo "Build the prototype first; see prototype/native-input/README.md." >&2
    exit 1
fi

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")
if [ "$bundle_id" != "com.patinasystems.ghostty.blocks" ]; then
    echo "Expected the separate Ghostty Patina Blocks app; found bundle ID: $bundle_id" >&2
    exit 1
fi

exec env GHOSTTY_NATIVE_INPUT=1 "$binary_path" \
    --config-default-files=false \
    --auto-update=off \
    --shell-integration=none \
    --window-save-state=never \
    --quit-after-last-window-closed=true \
    --title="Ghostty Patina Blocks"
