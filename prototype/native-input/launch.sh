#!/bin/sh
# Launch the normal Spooky app with the user's usual Ghostty configuration.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
app_path=${1:-"$repo_root/macos/build-spooky/ReleaseLocal/Spooky.app"}
binary_path="$app_path/Contents/MacOS/ghostty"

if [ ! -x "$binary_path" ]; then
    echo "Build Spooky first; see prototype/native-input/README.md." >&2
    exit 1
fi

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")
if [ "$bundle_id" != "com.patinasystems.spooky" ]; then
    echo "Expected Spooky; found bundle ID: $bundle_id" >&2
    exit 1
fi

exec /usr/bin/open "$app_path"
