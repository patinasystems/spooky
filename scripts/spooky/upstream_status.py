#!/usr/bin/env python3
"""Report Ghostty drift without changing the checkout or merging any commits."""

import argparse
import json
from pathlib import Path
import subprocess
import sys


UPSTREAM_URL = "https://github.com/ghostty-org/ghostty.git"
UPSTREAM_REF = "refs/remotes/upstream/main"


def git(repo, *arguments):
    return subprocess.run(
        ["git", "-C", str(repo), *arguments],
        check=True, capture_output=True, text=True, timeout=120,
    ).stdout.strip()


def inspect(repo):
    if git(repo, "rev-parse", "--is-shallow-repository") == "true":
        raise ValueError("Full commit history is required; shallow counts can be incorrect.")
    head = git(repo, "rev-parse", "HEAD")
    upstream = git(repo, "rev-parse", UPSTREAM_REF)
    base = git(repo, "merge-base", head, upstream)
    behind, ahead = map(int, git(repo, "rev-list", "--left-right", "--count", f"{upstream}...{head}").split())
    # Tree paths suffice. --no-renames avoids reading file blobs in partial clones.
    def paths(revision):
        return set(filter(None, git(repo, "diff", "--no-renames", "--name-only", "-z", base, revision).split("\0")))
    incoming, changed = paths(upstream), paths(head)
    return {
        "head": head, "upstream": upstream, "merge_base": base,
        "ahead": ahead, "behind": behind,
        "fork_files": len(changed), "upstream_files": len(incoming),
        "overlapping_files": sorted(changed & incoming),
        "upstream_commits": git(
            repo, "log", "--first-parent", "-12", "--format=%h %s", f"{base}..{upstream}",
        ).splitlines(),
    }


def markdown(result, fetched):
    lines = [
        "# Spooky upstream status", "",
        f"**{result['ahead']} fork commits ahead; {result['behind']} upstream commits behind.**",
        "Counts include merge commits, not just first-parent changes.", "",
        f"- Fork snapshot: `{result['head']}`",
        f"- Ghostty main: `{result['upstream']}`",
        f"- Common ancestor: `{result['merge_base']}`",
        f"- Reference: {'fetched from the official upstream in this run' if fetched else 'cached local upstream/main; use --fetch to refresh'}.",
        f"- Changed paths: {result['fork_files']} in Spooky, {result['upstream_files']} upstream; "
        f"{len(result['overlapping_files'])} overlap.", "",
        "Path overlap guides review; it does not predict merge conflicts or compatibility.", "",
        "## Overlapping paths", "",
    ]
    lines += [f"- `{path.replace('`', '&#96;')}`" for path in result["overlapping_files"][:80]] or ["None."]
    if len(result["overlapping_files"]) > 80:
        lines.append("Additional paths omitted; use --json for the complete list.")
    lines += ["", "## Latest incoming first-parent commits", ""]
    lines += ["- " + commit for commit in result["upstream_commits"]] or ["None."]
    lines += [
        "", "This report does not merge, build, publish, create issues, or change the working tree.",
        "Follow [the maintenance guide](https://github.com/patinasystems/spooky/blob/main/docs/upstream-maintenance.md) before updating.",
    ]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fetch", action="store_true", help="Refresh only upstream/main from the official repository.")
    parser.add_argument("--json", action="store_true", help="Print machine-readable counts and paths.")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    try:
        if args.fetch:
            git(repo, "fetch", "--no-tags", "--filter=blob:none", "--no-write-fetch-head",
                UPSTREAM_URL, f"+refs/heads/main:{UPSTREAM_REF}")
        result = inspect(repo)
        print(json.dumps(result, indent=2) if args.json else markdown(result, args.fetch), end="\n" if args.json else "")
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError) as error:
        # Do not emit command stderr: credential helpers can include sensitive diagnostics.
        print(f"Upstream status unavailable: {type(error).__name__}. Check full history, upstream access, and the local ref.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
