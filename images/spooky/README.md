# Spooky black icon variant

![Black CRT icon](icon-black.png)

An AI-assisted monochrome variant of Ghostty's original CRT/ghost icon:
charcoal bezel, black screen, gray phosphor dots, and white ghost. The reference
is [Ghostty's original icon](https://github.com/ghostty-org/ghostty/blob/0b1729e945978fca4bcd6165d8ac408bf675a7f2/macos/Assets.xcassets/AppIconImage.imageset/macOS-AppIcon-1024px.png).

`icon-black.png` is a 1254 × 1254 PNG with transparency, generated on 2026-11-03.
It is the source artwork for Spooky's default app icon. Regenerate the macOS
appiconset and in-app images with `python3 scripts/spooky/export-icon.py`.
The app selects `Spooky.appiconset`; About and pre-Tahoe Dock tiles use the
matching `AppIconImage` exports. The upstream layered `Ghostty.icon` source is
retained, but is not an input to Spooky's icon compilation. Inspect the built
`Spooky.icns` and small-size exports before signing and publishing.

Original Ghostty artwork and project attribution are retained under the
repository's [license](../../LICENSE). This variant identifies the independent
Spooky fork; it does not imply Ghostty's endorsement.
