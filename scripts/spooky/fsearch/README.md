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
