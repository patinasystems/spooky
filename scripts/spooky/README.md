# Spooky macOS downloads

The public Apple Silicon preview is
<https://downloads.patinasystems.com/spooky/Spooky.dmg>.
Open the image, drag Spooky to Applications, then launch it there.
The app installs alongside Ghostty and uses the existing Ghostty configuration.

The currently published preview is **Apple Development signed, not Developer ID
signed or notarized**. macOS may require explicit approval in Privacy & Security
on first launch. Preparing the notarization workflow below does not change that
existing download. These scripts never disable Gatekeeper or remove quarantine.

## What remains for normal first launch

A release needs a usable **Developer ID Application** certificate/private-key pair
for Patina and an explicitly configured `notarytool` Keychain profile. Apple
Development and Apple Distribution identities are different certificate types
and cannot substitute. The certificate can be created by the team's Account
Holder; cloud-managed Developer ID access has separate role requirements.
See [Apple's certificate instructions](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).

After the certificate is available locally, choose a Keychain profile name and
configure it interactively. `spooky-notary` below is an example, not an existing
or assumed credential. Do not put passwords, API private keys, or signing-key
exports in this repository or a chat message.

```sh
security find-identity -v -p codesigning
xcrun notarytool store-credentials spooky-notary
python3 scripts/spooky/notarization.py \
  --identity 'Developer ID Application: <exact available certificate name>' \
  --notary-profile spooky-notary --check-credentials
```

Preflight resolves an exact certificate name or SHA-1, checks tool availability,
and optionally authenticates read-only with Apple. It does not sign, upload,
install, or show account history. A missing identity/profile fails with an
explicit setup instruction. A locked Keychain may need to be unlocked locally.
The signing identity and the notary credentials must belong to the intended
Apple Developer team; Apple still decides whether each submission is accepted.

## Build and package

Use a dedicated output directory so test plug-ins cannot enter the download.
`release.xcconfig` disables Xcode's injected debugging entitlement and coverage
instrumentation. Upstream Ghostty updates remain disabled: a future updater needs
Spooky's own feed, signing key, version ordering, and release flow. See the
[upstream maintenance guide](../../docs/upstream-maintenance.md).

Build the native GhosttyKit core using the documented Zig workflow, then run from
the repository root. Use the host's build queue unless the user has explicitly
overridden it. Cargo/Rust and the requested macOS target must be installed.
`build.nu` builds the pinned filename-search helper before Xcode; its copy-only
phase embeds and signs the helper. With no `--arch`, both target the host
architecture. Direct Xcode builds must first run
`python3 scripts/spooky/fsearch/build.py --architectures arm64 --output-dir macos/build-spooky/fsearch`.
The public packaging path currently supports **arm64 only**, macOS 13 or later;
an Intel download requires a separately built and tested artifact.

```sh
./macos/build.nu --configuration ReleaseLocal --arch arm64 \
  --xcconfig scripts/spooky/release.xcconfig \
  --build-dir macos/build-spooky/download

uv run scripts/spooky/package.py \
  --app macos/build-spooky/download/ReleaseLocal/Spooky.app \
  --output-dir macos/build-spooky/distribution/<new-release> \
  --source-commit <full-commit-actually-built> \
  --identity 'Developer ID Application: <exact available certificate name>' \
  --notary-profile spooky-notary
```

`package.py --preflight --identity ... --notary-profile ...` performs just the
release credential check, without requiring an app or output directory.
Full packaging stages a copy and performs these checks before writing release
artifacts:

1. Admit only the normal Spooky bundle with native input enabled, upstream
   updates disabled, no capture/profiling settings, no test/debug residue, and
   matching arm64 app/helper provenance and licenses.
2. Reject the debugging entitlement throughout nested code. Sign Mach-O files
   and bundles inside-out with the selected Developer ID identity, Hardened
   Runtime, and secure timestamps, preserving required component entitlements.
   Verify the same signing team, runtime, timestamp, and absence of debugging
   entitlement on every signed target.
3. Submit a ZIP of the app to Apple, require `Accepted`, save the submission
   receipt and notary log, then staple and validate the app's ticket and run
   Gatekeeper assessment. This puts an offline ticket inside the final DMG.
4. Build the APFS/UDZO image with pinned `dmgbuild` 1.6.7 and the app plus an
   `/Applications` shortcut. Sign, submit, staple, and validate the image too.
   No Finder/AppleScript automation is used.
5. Hash the **final stapled image**, then emit its version/commit-named DMG,
   identical `Spooky.dmg`, manifest, and `SHA256SUMS`. The source app is unchanged.

The manifest says `notarized: true` only after both accepted submissions,
staples, and Gatekeeper checks succeed. Receipts/logs remain under the output's
`notarization/` directory, including unsuccessful submissions. A timeout may
leave Apple processing the submission; inspect its saved ID with `notarytool
info` or `wait` before deciding to resubmit. Unexpected tool failure never
emits a new successful release manifest.

Use a new release directory and a new version/source commit when bytes change.
Existing local output needs explicit `--overwrite`; immutable public object
names cannot be reused for different bytes. The exact built commit matters:
changing only the manifest's commit does not rebuild the app.

## Explicit unnotarized preview

Until Developer ID and notary credentials are available, the existing preview
flow remains supported. Omit `--notary-profile`; optionally sign the staging copy
with an available Apple Development identity. This always emits
`release_kind: preview` and `notarized: false`. Neither packaging nor publishing
can turn that preview into a normal Gatekeeper-approved release by changing a
label. Users must continue to receive the preview warning.

```sh
uv run scripts/spooky/package.py \
  --app macos/build-spooky/download/ReleaseLocal/Spooky.app \
  --output-dir macos/build-spooky/distribution/<new-preview> \
  --source-commit <full-commit-actually-built> \
  --identity 'Apple Development: <exact available certificate name>'
```

## Publish

Lipboard's existing `lipboard-downloads` R2 bucket is served through
`downloads.patinasystems.com`. Spooky owns only its `spooky/` prefix. This DMG is
small enough for direct Wrangler uploads; no Worker or DNS deployment is needed.

```sh
bun install --cwd scripts/spooky --frozen-lockfile
bun run --cwd scripts/spooky wrangler whoami

uv run scripts/spooky/publish.py \
  macos/build-spooky/distribution/<new-release>/Spooky-<version>-<commit9>-arm64.json \
  --dry-run

uv run scripts/spooky/publish.py \
  macos/build-spooky/distribution/<new-release>/Spooky-<version>-<commit9>-arm64.json
```

The normal path rejects unnotarized artifacts before network activity or upload.
A deliberate preview publish requires `--allow-unnotarized-preview` on **both**
the dry run and actual command. That flag cannot bypass validation of an artifact
claiming to be notarized.

The publisher verifies hashes, accepted receipts, the actual Developer ID DMG
signature, ticket, and Gatekeeper policy. It then mounts the image read-only,
without browsing or launching, and independently checks its actual Spooky app:
bundle flags, version, main/helper hashes and architecture, helper provenance,
every nested signing target/team/runtime/debug entitlement, and the app's own
stapled ticket and Gatekeeper assessment. It detaches in `finally`. If detach
fails it leaves the read-only mount intact with an actionable path, refuses to
publish, and does not recursively delete the mounted tree.

Wrangler 4.156.0 is pinned locally. Authentication uses the existing Wrangler
profile; no credentials are committed or passed as command arguments. Publishing
targets Patina's account explicitly and refuses to replace immutable objects
with different bytes. It uploads versioned DMG/manifest objects before updating
`Spooky.dmg`, `latest.json`, and `SHA256SUMS`. Versioned files cache immutably;
stable links use `no-store` because the shared host can extend short browser TTLs
to four hours. Fresh anonymous downloads verify all five uploaded SHA-256 hashes,
using unique query strings to avoid stale/negative cache entries.

## Verification and limits

```sh
python3 -m unittest discover -s scripts/spooky -p 'test_*.py' -v
hdiutil verify <Spooky.dmg>
xcrun stapler validate <Spooky.dmg>
codesign --verify --strict --deep /Applications/Spooky.app
xcrun stapler validate /Applications/Spooky.app
spctl --assess --type execute --verbose=2 /Applications/Spooky.app
```

Unit tests mock signing/notary/network operations; they verify failure gates and
ordering, not Apple's acceptance of a real binary. A real Developer ID release
must pass the complete pipeline and a fresh downloaded, quarantined install on
a clean user account or Mac before claiming a painless first-launch experience.
Normal macOS downloaded-app confirmation or legitimate privacy prompts may
still appear. The current Apple Development preview is expected to fail ticket
validation. No app is launched automatically by these tools.

Apple documents the prerequisites in
[Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
the command-line/ticket flow in
[Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow),
and certificate/runtime/debugging failures in
[Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues).
