#!/usr/bin/env python3
"""Hermetic graph fixtures for the maintenance report; no network or app build."""

from pathlib import Path
import subprocess
import tempfile
import unittest

import upstream_status


class UpstreamStatusTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.repo = Path(self.directory.name) / "repo"
        self.repo.mkdir()
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.commit("shared.txt", "base")
        self.base = self.git("rev-parse", "HEAD")
        self.git("branch", "upstream-fixture")

    def git(self, *args):
        return upstream_status.git(self.repo, *args)

    def commit(self, path, value):
        (self.repo / path).write_text(value)
        self.git("add", path)
        self.git("commit", "-m", value)

    def diverge(self):
        self.commit("shared.txt", "fork")
        self.commit("native.txt", "native")
        self.git("checkout", "upstream-fixture")
        self.commit("shared.txt", "upstream")
        self.git("update-ref", upstream_status.UPSTREAM_REF, "HEAD")
        self.git("checkout", "main")

    def test_counts_and_overlap_follow_actual_graph_without_changing_checkout(self):
        self.diverge()
        head = self.git("rev-parse", "HEAD")
        result = upstream_status.inspect(self.repo)
        self.assertEqual((result["ahead"], result["behind"]), (2, 1))
        self.assertEqual(result["merge_base"], self.base)
        self.assertEqual(result["overlapping_files"], ["shared.txt"])
        self.assertEqual(result["fork_files"], 2)
        self.assertEqual(self.git("rev-parse", "HEAD"), head)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_integrated_history_reports_no_missing_upstream_commits(self):
        self.diverge()
        self.git("merge", "--no-edit", "-s", "ours", "upstream-fixture")
        result = upstream_status.inspect(self.repo)
        self.assertEqual((result["ahead"], result["behind"]), (3, 0))
        self.assertEqual(result["upstream_files"], 0)
        self.assertEqual(result["overlapping_files"], [])

    def test_shallow_clone_fails_instead_of_reporting_incorrect_counts(self):
        clone = Path(self.directory.name) / "shallow"
        subprocess.run(["git", "clone", "--depth=1", self.repo.as_uri(), str(clone)],
                       check=True, capture_output=True)
        with self.assertRaisesRegex(ValueError, "Full commit history"):
            upstream_status.inspect(clone)


if __name__ == "__main__":
    unittest.main()
