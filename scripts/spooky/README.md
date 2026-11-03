# Spooky macOS downloads

The public Apple Silicon preview is
<https://downloads.patinasystems.com/spooky/Spooky.dmg>.
Open the image, drag Spooky to Applications, then launch it there.
The app installs alongside Ghostty and uses the existing Ghostty configuration.

This preview is Apple Development signed, not Developer ID signed or notarized.
macOS may require explicit approval in Privacy & Security on first launch.
Do not claim the normal notarized Ghostty first-launch experience until a
Developer ID Application certificate and notarization credentials are available.
No Gatekeeper settings are changed by these scripts.

## Build and package

Use a dedicated output directory so test plug-ins cannot enter the download.
The release configuration disables Xcode's injected debugging entitlement and
Swift/Clang coverage instrumentation. The preview keeps upstream Ghostty updates
disabled. A future updater needs Spooky's own feed, signing key, and release flow.

Build the current native GhosttyKit core first using the repository's documented
Zig workflow, then run these commands from the repository root. On Patina Macs,
run build/package commands through `pat run` as required by the host's work queue.

```sh
./macos/build.nu --configuration ReleaseLocal --arch arm64 \
  --xcconfig scripts/spooky/release.xcconfig \
  --build-dir macos/build-spooky/download

uv run scripts/spooky/package.py \
  --app macos/build-spooky/download/ReleaseLocal/Spooky.app \
  --output-dir macos/build-spooky/distribution/current \
  --source-commit <full-commit-actually-built> \
  --identity 'Apple Development: <your available signing identity>'
```

The packager stages a copy and signs nested code before its enclosing bundles.
It verifies the signature, identity, architecture, disabled upstream updates,
absence of test/debug residue, and absence of the debugging entitlement.
It then uses pinned `dmgbuild` 1.6.7 to write an APFS/UDZO image and its Finder
layout directly, without AppleScript. The image contains `Spooky.app` and a
shortcut to `/Applications`.

Outputs include a version/source-commit-named DMG, identical `Spooky.dmg`, a JSON
manifest with executable and DMG hashes, and `SHA256SUMS`. Source app contents
are never changed. Existing output requires an explicit `--overwrite`.
The optional signing identity does not perform notarization; metadata always
identifies this packaging workflow as a non-notarized preview.

## Publish

Lipboard's existing `lipboard-downloads` R2 bucket is served directly through
`downloads.patinasystems.com`. Spooky owns only its `spooky/` prefix. Lipboard's
temporary upload Worker exists to handle larger multipart uploads; this DMG is
small enough for direct Wrangler uploads. No Worker or DNS deployment is needed.

```sh
bun install --cwd scripts/spooky --frozen-lockfile
bun run --cwd scripts/spooky wrangler whoami

uv run scripts/spooky/publish.py \
  macos/build-spooky/distribution/current/Spooky-<version>-<commit9>-arm64.json \
  --dry-run

uv run scripts/spooky/publish.py \
  macos/build-spooky/distribution/current/Spooky-<version>-<commit9>-arm64.json
```

Wrangler 4.156.0 is pinned locally. Authentication uses the existing Wrangler
profile; no credentials are stored here or passed as command arguments.
The publisher targets Patina's account explicitly, validates artifact hashes,
and refuses to replace a versioned object with different bytes. It uploads the
versioned DMG/manifest before refreshing `Spooky.dmg`, `latest.json`, and
`SHA256SUMS`. Versioned files cache immutably; stable links use `no-store` because
the shared host can extend short browser TTLs to four hours for cacheable DMGs.
Fresh anonymous reads verify every uploaded object's SHA-256 through the public
host. Verification uses unique query strings to avoid caching missing-object
preflight responses or reading an older cached stable alias.

## Verification

```sh
uv run scripts/spooky/test_package.py
hdiutil verify <Spooky.dmg>
codesign --verify --strict --deep /Applications/Spooky.app
/Applications/Spooky.app/Contents/MacOS/ghostty --version
```

The clean source app, signed image, installed application, and public downloads
are verified separately. Local installation is a normal application-bundle copy;
it does not replace a running development session or modify shell configuration.
