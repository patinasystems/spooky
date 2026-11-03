# Spooky filename search helper

This app-owned JSON-lines process embeds [fsearch](https://github.com/noahdunnagan/fsearch)
at the exact MIT-licensed revision in `upstream.json`. It does not install or connect to
a login daemon. Closing the app's stdin terminates the process and its indexing threads.

The checked patch adds `Engine::start_names_only` and `Query::literal_names`. Upstream's
normal API keeps its content-indexing behavior. Spooky's engine never opens content
segments, starts content workers, queues content rescans, or permits `grep`. Filename
queries do not use the fsearch DSL; punctuation such as `grep:`, `git:`, `!`, and `*`
stays literal fuzzy text. Up to eight whitespace-separated fuzzy words are supported,
matching the upstream searcher's token-mask bound. No `keep_warm` calls are made.

Build inside the existing Pat job:

```sh
uv run scripts/spooky/fsearch/build.py --architectures arm64 --test --output-dir macos/build-spooky/fsearch
```

Python uses only the standard library. Cargo dependencies are locked; the source revision
and exact patch are checked before every build. For a universal helper, pass
`--architectures arm64 x86_64` after installing both Rust target standard libraries.
The build uses four cargo jobs and macOS 13 as its deployment target. The outputs are
`spooky-fsearch`, `LICENSE.fsearch`, `LICENSE.dependencies`, and `fsearch-provenance.json`; the app build copies
the helper into `Contents/Helpers`, includes the attribution/provenance in Resources,
and signs the nested executable before signing the app. The provenance's executable
hash is the pre-signing hash; release packaging records the shipped helper's hash.
`LICENSE.dependencies` includes the locked crates' complete shipped license/notice files,
including the Unicode notice. The build verifies it against Cargo's locked sources;
after dependency updates, regenerate with `build.py --update-licenses` and review the diff.

The app starts one process during normal app launch and uses a private
`~/Library/Application Support/Spooky/fsearch-names-v1` index. The helper indexes names
in the background using upstream filesystem watching and permission-aware skips.
Its index/apply workers use explicit background QoS, including subtree scans and recovery
stat passes; worker pools remain capped at two threads. Background QoS requests lower
CPU and disk I/O priority together. A separate thread-scoped `IOPOL_THROTTLE` is deliberately
not combined with QoS: macOS removes the thread's QoS when that legacy policy is set.
On-demand scoped scans retain utility QoS, while filename queries use a separate
two-thread user-initiated pool; event delivery keeps user-initiated QoS to avoid dropped
filesystem events. These limits prioritize interactive work; they do not reduce the
amount of filesystem metadata that the initial index must read. Background scheduling
can make a cold crawl slower in exchange for prioritizing interactive work. I/O throttling
is not a CPU cap: cached directory enumeration and large build-event bursts can still
consume CPU without issuing disk I/O. This policy has no measured latency improvement
claim until the matched capture is repeated.
`startIndexing()` is idempotent; `indexState()` reports `creating` until the engine has
published the loaded or newly built name index, then `ready`. The helper answers status
outside its query queue, so polling cannot cancel or wait behind a search. The picker
shows “Initial search index is being created…” while initial work is pending. Scoped
queries can use upstream's early folder index; empty queries and direct-child navigation
enumerate only the requested folder in the actor, independently of index readiness.

Requests are bounded to 1,024 query bytes, 200 search results, and a 16 KiB input line.
Navigation returns at most 1,000 immediate entries. One active request and one newest
queued request are retained; cancellation drops stale responses. An already-running
upstream search cannot be interrupted mid-call, but obsolete queued searches never run.
Ranking keeps fsearch score first, then prefers paths near the shell's current directory
within a bounded candidate window. No content is read and no shell commands are run.

Tests use pure query/queue fixtures and temporary directory/fake-process fixtures; they
do not trigger a whole-machine index. Actual first-index cost depends on the local disk.

For controlled latency measurements, a diagnostic build can set the Info.plist Boolean
`SpookyPerformanceDiagnostics` and absolute paths `SpookyFileSearchDiagnosticsPath`
and `SpookyFileSearchDiagnosticIndexDirectory`. The latter is optional; use a private
empty directory for a first-index trial or an APFS-cloned index for a cached-index trial.
Normal builds ignore both overrides. Environment equivalents are
`GHOSTTY_NATIVE_INPUT_DIAGNOSTICS=1`, `SPOOKY_FSEARCH_DIAGNOSTICS_PATH`, and
`SPOOKY_FSEARCH_INDEX_DIRECTORY`; diagnostics value `0` explicitly disables the probes.

The helper emits one aggregate JSON record per second on a utility thread. Records
contain monotonic uptime and wall-clock anchors, process CPU, bounded query counters,
and lock-free index-worker phase/counter snapshots. They contain no filenames, folder
paths, or query text. Phases distinguish crawl, build, save, prefault, access rescan,
replayed/live updates, compaction, relisting, and waiting. `ready` means a searchable
index was published; it does not mean prefaulting or replay work has finished. Phase
snapshots are observational and can straddle a transition; use cumulative phase times
and CPU deltas across several records. This instrumentation changes no indexing policy.
