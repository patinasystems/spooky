# Filename search CPU investigation

Spooky now uses on-demand native Spotlight queries for `@` search and bounded,
nonrecursive directory listings for navigation. It no longer owns a filesystem
index, helper process, FSEvents watcher, startup crawl, or readiness polling loop.
Shell completion remains independent and still uses the configured shell.

## Why the old integration did background work

The pinned fsearch engine crawled and watched `/`; its `home` option did not
restrict filename indexing to the user's home folder. The saved index on the
development Mac contained 25,288,691 entries and 3,287,133 directories in a
512,876,416-byte index file. Build and cache churn anywhere on the disk could
trigger directory relisting and recursive scans of newly discovered folders.
Recovery after lost event history could stat every indexed directory.

Two background-priority workers reduced scheduling priority, but did not bound
total work. The upstream relisting allowance was per directory, so changes
spread across many directories could keep workers busy. The Swift service had
no tight restart or polling loop, and the adapter did not call `keep_warm`.

## Installed-helper measurements

No Spooky process was running when the investigation began. These are controlled
runs of the installed helper against its existing saved index, with no search
requests, rather than a capture of the user's reported spike.

| Run | Wall time | Process CPU time | Average CPU, one core = 100% |
| --- | ---: | ---: | ---: |
| Quiet machine, including startup | 22.14 s | 0.751 s | 3.39% |
| Temporary build-like file activity | 11.54 s | 1.578 s | 13.67% |

The second run created 12,000 empty files in 300 temporary directories, then
performed three rename waves. The peak one-second CPU sample was 24.71%; the
helper processed 22,106 events and 1,857 directory updates. Other system activity
was not isolated, so these numbers are not an attribution of every event to the
fixture. The fixture and helper were stopped and removed after measurement.

These traces establish unsolicited background work, not the magnitude or exact
cause of the user's larger reported spike. Removing the dedicated indexer
eliminates this source of work rather than masking it with a lower priority.

## Search behavior and limits

Spotlight supplies the existing system metadata index; Spooky does not request
reindexing or content import. Searches are cancellable and have bounded result
counts and a deadline. No live metadata updates continue after a query finishes.
Directory navigation reads one folder only. Spotlight exclusions and indexing
availability affect recursive/global search coverage.

The build removes stale helper files from incremental products, and packaging
rejects any remaining helper or its resource directory. This prevents an older
build product from silently retaining the removed dependency.

## Replacement validation

The release-optimized service was exercised directly against this Mac's actual
Spotlight index, including an existing indexed app, a newly created unindexed
file, fuzzy queries, and literal query escaping. All 50 rapid requests cancelled
successfully. After shutdown it consumed 0.001148 CPU seconds over 10.112 seconds
idle (about 0.011% of one core). This measures the search service, not the entire
terminal or system Spotlight daemon. Global query latency depends on Spotlight;
these checks do not claim lower keystroke-to-pixel latency.

The three app suites passed all 126 tests, including the opt-in real metadata
query check, and the release packaging/publishing tools passed 39 tests. The
native query test deliberately uses a nonexistent nearby folder so direct
directory fallback cannot conceal a broken Spotlight implementation.

To include that check when testing on an indexed development Mac, set
`SPOOKY_SPOTLIGHT_FIXTURE_PATH=/Applications/Spooky.app` before running
`macos/build.nu --action test`. The fixture must already exist in Spotlight;
tests do not import it or trigger indexing. Without the variable, only this
machine-dependent test is skipped.
