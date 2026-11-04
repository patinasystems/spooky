# Maintaining Spooky against Ghostty

Spooky follows Ghostty's `main` branch through reviewed merges. The upstream
terminal, parser, renderer, font system, and platform code remain the foundation;
Spooky's native command editor and shell bridge are a maintained fork patch set.
Do not periodically rebase already-published Spooky history or merge and release
an upstream update without the fork's compatibility checks.

## Check drift

```sh
uv run --no-project scripts/spooky/upstream_status.py --fetch
```

This refreshes only `refs/remotes/upstream/main` from
`https://github.com/ghostty-org/ghostty.git`, then reports exact commit-graph
ahead/behind counts, the common ancestor, and overlapping changed paths.
It does not change branches, working files, tags, or the index. Omit `--fetch`
for an explicitly labeled cached report; use `--json` for machine-readable data.
Shallow clones are rejected rather than reporting misleading counts.

On 2026-11-04, Spooky integrated all 37 incoming commits through Ghostty
`9fc62a98cc765f2c341d317f2ee684ebb9584237`, using merge `9699c552f` and the Swift
compatibility follow-up `754e239ca`. There were no textual conflicts. Upstream's
new default C pointer nullability required explicit nullable annotations for
Spooky's empty block/caption buffers and a non-optional Swift presentation
callback pointer. Existing fork release guards and updater restrictions remain.

Validation at `754e239ca`: 428 selected core tests passed (two skipped), including
native rendering/viewport/submission, path hover, scroll accumulation, and
upstream ASCII/parser regressions; 563 macOS unit tests passed (one benchmark
skipped); all 80 shell tests and 35 release-tool tests passed. The normal arm64
ReleaseLocal app and GhosttyKit built successfully, and the bundle's code
signature verified. An isolated diagnostic app confirmed submission, Tab
completion, and Cmd+F search over 160 output lines. Computer use intermittently
lost access to its window during wheel-scroll attempts, so live scroll smoothness
and key-to-pixel latency were not requalified by this merge. The installed app
and public download were not replaced by this validation.

The **Spooky Upstream Status** Actions workflow runs weekly or manually on one
Ubuntu runner, with a five-minute limit and read-only repository permission.
It checks out only the maintenance scripts plus root files, retaining commit
history for exact counts. It writes a GitHub job summary; it does not build,
merge, open issues or pull requests, post comments, or publish releases. A green
status means the report ran, **not** that Spooky contains the latest upstream.
The [first hosted run](https://github.com/patinasystems/spooky/actions/runs/41774416714)
passed on 2026-11-03.

On 2026-11-03, Spooky `6f5934fda` was **14 commits ahead and 20 behind** upstream
`c7f68a7f4`, based on common ancestor `0b1729e945978fca4bcd6165d8ac408bf675a7f2`.
The fork changed 155 paths. Incoming upstream changes overlapped seven paths:
`include/ghostty.h`, `src/apprt/embedded.zig`, `src/terminal/Screen.zig`,
`src/terminal/Terminal.zig`, `src/termio/stream_handler.zig`,
`macos/Sources/Ghostty/Ghostty.App.swift`, and
`macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`.
These are graph counts including merge commits, not 20 separate features.
[Upstream changes at that snapshot](https://github.com/ghostty-org/ghostty/compare/0b1729e945978fca4bcd6165d8ac408bf675a7f2...c7f68a7f48c6a5b357689eb8c2328bc2dab5d8ed).

## Integrate an update

1. Read the drift report and upstream changes. Prioritize relevant correctness
   and security fixes; use the weekly report to keep ordinary merges small.
2. Create a dedicated `codex/upstream-YYYY-MM-DD` worktree from current Spooky
   main. Keep the released commit and its immutable download available.
3. Run the report with `--fetch`, record the exact upstream SHA, then merge that
   SHA with `git merge --no-ff --no-commit <upstream-sha>`. Resolve each overlap
   against both implementations. Do not use blanket “ours” conflict resolution.
4. Review the patch boundaries below. Read the updated toolchain pins in
   `build.zig.zon` and app dependencies before reusing any previous build output.
5. Run the affected upstream tests plus the fork checks, rebuild GhosttyKit,
   then build the macOS app. Verify a normal release build separately from test
   and capture builds. Record exact source SHA, tests, and known limitations.
6. Commit the reviewed merge and deliver through the repository's approved
   process. Follow the [packaging and publishing guide](../scripts/spooky/README.md)
   only after the app passes installation checks. No automated merge is enabled.

Ghostty's [source build guide](https://ghostty.org/docs/install/build) describes
upstream requirements. Spooky's [build guide](../prototype/native-input/README.md)
owns fork-specific commands, helper packaging, and native input checks.

## Fork patch boundaries and verification

| Boundary | Review after an upstream merge | Required evidence |
| --- | --- | --- |
| Parser and shell lifecycle | `Terminal.zig`, `Screen.zig`, `stream_handler.zig`, `termio/Exec.zig`, shell integration, native startup resources | Relevant upstream parser/scroll tests; native block, prompt ownership and submission-gate tests; `test/native-input/test_zsh_bridge.py` for normal startup, zsh options/history/completion, continuation, foreground `read`/`vared`, and terminal fallback. |
| Native ABI and callback lifetime | `include/ghostty.h`, `apprt/embedded.zig`, `apprt/action.zig`, Swift Ghostty bridge | Rebuild GhosttyKit before Swift; targeted handoff, submission-presentation, focus and bridge tests; exercise splits, tab changes, close, and app backgrounding. Keep C declarations, Zig layouts, and Swift calls in agreement. |
| Metal rendering and viewport | `CommandChrome`, `NativeViewport`, `NativeSubmissionGate`, `NativePresentation`, generic renderer, Metal frame/layer and both shader backends | Core geometry, clipping, semantic input tint, cursor suppression and presentation tests; compile supported renderer paths; visible multiline submit, raw/TUI handoff, selection and bottom/scrollback checks. Parser receipt is not proof of a displayed frame. |
| AppKit input and appearance | `NativeCommandSurfaceHost`, native text/completion/history/file-picker controls, surface view and window controllers | Swift editor/IME/selection/undo, completion/history/file picker/path tests; dark/light appearance, backing scale, system accent, search, clipboard, and key-window focus checks. Preserve upstream keyboard and pointer behavior when native editing is inactive. |
| Release identity and dependencies | Bundle settings, `AppBranding`, updater guards, fsearch pins/license, installer scripts and Actions | Distinct Spooky bundle/app identity, upstream updates disabled, no test/capture/debug residue, exact helper provenance, code signature and release-mode checks, DMG install and anonymous public checksum verification. |

Keep fork-specific code in dedicated files where possible. When upstream gains
an equivalent facility, remove the superseded patch after testing compatibility
instead of maintaining two implementations. Preserve focused commits and tests
around the shared integration points; file-count growth alone is not a reason
to move terminal rendering into a second pipeline.

## Release and automation separation

Upstream release, publishing, vouch, milestone, Snap, and artifact-cleanup jobs
are restricted to exactly `ghostty-org/ghostty`. Their runner labels, secrets,
release hosts, and contributor policy belong to Ghostty. Spooky must not enable
them by substituting its repository name. Ordinary inherited test/path gates
are unchanged. The inherited Test summary job now uses the same repository
guard as its entry job so it cannot wait forever for Ghostty's private runner
after every test was skipped. Upstream-only skipped jobs are **not Spooky test
coverage**; porting the native/core build suite to Spooky-owned CI remains work.

**Spooky Release Tools** runs the mocked release-admission and hermetic Git
tests on Ubuntu/Python 3.12 when those scripts or fsearch provenance inputs
change, or on manual dispatch. It has read-only permissions and a five-minute
limit. Passing these guard tests is not proof of Apple signing or notarization.

Spooky's updater is deliberately disabled in the bundle, updater start/check
entry points, and feed delegate. Ghostty's historical feed URLs and public key
remain upstream implementation details behind those guards. A future updater
requires a Spooky-owned feed, update signing key, and independently verified
release process before any guard is removed. Until then, users update through
the [Spooky download](https://downloads.patinasystems.com/spooky/Spooky.dmg).

Retain the upstream MIT [license and copyright](../LICENSE) and Ghostty
attribution. Preserve separate dependency notices, including the filename-search
helper's pinned source/license. A working preview URL is not evidence of
Developer ID signing or Apple notarization; use the packaging manifest and
installer checks to describe the actual release accurately.

The status workflow uses GitHub's documented
[job summaries](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands#adding-a-job-summary),
[read-only permissions](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#permissions),
and [sparse checkout](https://github.com/actions/checkout#fetch-only-the-root-files-and-github-and-src-folder).
