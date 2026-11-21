#!/usr/bin/env python3
"""Offline checks for scripts/track-upstream.sh --verdict / --list-hot.

The drift report answers "are we behind".  It answers it the same way for
three commits and for nine hundred, so a weekly run cannot say when being
behind stops being normal.  ``--verdict`` adds that answer as an exit code,
which is the whole point: a scheduler can act on 0/1/2 and ignore the prose.

These tests build throwaway repositories in a temp directory with synthetic
upstream refs -- no network, no real upstream, no build tree.

The red case is test_red_proof_drift_report_cannot_triage: the default mode
exits 1 for behind=3 and behind=120 alike and prints the same "verdict:
drift", which is exactly what makes a periodic run useless without the new
tri-state.  Every threshold assertion after it proves the tri-state reads the
threshold it was given rather than a hardcoded number.

Run from the repository root:

    python3 -m unittest scripts.tests.test_track_upstream
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "track-upstream.sh"


class SynthRepo:
    """A repo with synthetic refs/remotes/upstream/{kernel73,kernel74}."""

    def __init__(self, root, behind=0, behind73=None, files=0, hot=0, patchver=None):
        self.root = Path(root)
        self.env = dict(
            os.environ,
            HOME=str(self.root),
            GIT_CONFIG_NOSYSTEM="1",
            GIT_AUTHOR_NAME="t",
            GIT_AUTHOR_EMAIL="t@example.com",
            GIT_COMMITTER_NAME="t",
            GIT_COMMITTER_EMAIL="t@example.com",
        )
        self.git("init", "-q", "-b", "main")
        (self.root / "README.md").write_text("base\n")
        if patchver:
            mk = self.root / "target/linux/airoha/an7581/target.mk"
            mk.parent.mkdir(parents=True)
            mk.write_text("KERNEL_PATCHVER:=%s\n" % patchver)
        self.git("add", "-A")
        self.git("commit", "-qm", "base")
        self.base = self.git("rev-parse", "HEAD").strip()

        self.git("checkout", "-q", "-b", "up74")
        for i in range(behind):
            self.git("commit", "-q", "--allow-empty", "-m", "up %d" % i)
        for i in range(files):
            (self.root / ("f%d.txt" % i)).write_text("x\n")
            self.git("add", "-A")
            self.git("commit", "-qm", "file %d" % i)
        for i in range(hot):
            p = self.root / ("target/linux/airoha/hot%d.txt" % i)
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("x\n")
            self.git("add", "-A")
            self.git("commit", "-qm", "hot %d" % i)
        k74 = self.git("rev-parse", "HEAD").strip()

        if behind73 is None:
            k73 = k74
        else:
            self.git("checkout", "-q", "-b", "up73", self.base)
            for i in range(behind73):
                self.git("commit", "-q", "--allow-empty", "-m", "up73 %d" % i)
            k73 = self.git("rev-parse", "HEAD").strip()

        self.git("update-ref", "refs/remotes/upstream/kernel74", k74)
        self.git("update-ref", "refs/remotes/upstream/kernel73", k73)
        self.git("update-ref", "refs/remotes/origin/kernel73", k73)
        self.git("checkout", "-q", "main")
        self.git("reset", "-q", "--hard", self.base)

    def git(self, *args):
        return subprocess.run(
            ("git",) + args,
            cwd=self.root,
            env=self.env,
            capture_output=True,
            text=True,
            check=True,
        ).stdout

    def run(self, *args):
        return subprocess.run(
            ("sh", str(SCRIPT)) + args,
            cwd=self.root,
            env=self.env,
            capture_output=True,
            text=True,
        )


def verdict_line(proc):
    for line in proc.stdout.splitlines():
        if line.startswith("verdict:"):
            return line
    return ""


class TrackUpstreamVerdict(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def repo(self, **kw):
        return SynthRepo(tempfile.mkdtemp(dir=self.tmp.name), **kw)

    def test_ok_when_behind_is_small(self):
        p = self.repo(behind=3).run("--quiet", "--verdict")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("verdict: ok", verdict_line(p))

    def test_review_when_past_the_behind_threshold(self):
        p = self.repo(behind=120).run("--quiet", "--verdict")
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn("verdict: review", verdict_line(p))
        self.assertIn("behind=120", verdict_line(p))

    def test_thresholds_are_the_input_not_a_constant(self):
        # Same repo, three threshold settings, three verdicts: proves the
        # decision is computed from the flags rather than from a baked number.
        repo = self.repo(behind=120)
        must = repo.run("--quiet", "--verdict", "--review-behind", "50", "--act-behind", "100")
        self.assertEqual(must.returncode, 2, must.stdout + must.stderr)
        self.assertIn("verdict: must-act", verdict_line(must))

        ok = repo.run("--quiet", "--verdict", "--review-behind", "500", "--act-behind", "900")
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        self.assertIn("verdict: ok", verdict_line(ok))

    def test_files_axis_hatches_on_its_own(self):
        repo = self.repo(behind=0, files=5)
        review = repo.run(
            "--quiet", "--verdict", "--review-files", "3", "--act-files", "999",
            "--review-behind", "9999", "--act-behind", "9999",
        )
        self.assertEqual(review.returncode, 1, review.stdout + review.stderr)
        self.assertIn("files=5", verdict_line(review))

    def test_hot_axis_counts_commits_touching_built_paths(self):
        # Only the hot-path commits count here; the plain behind count is 0.
        repo = self.repo(behind=0, hot=3)
        p = repo.run(
            "--quiet", "--verdict", "--review-hot", "2", "--act-hot", "9",
            "--review-behind", "9999", "--act-behind", "9999",
            "--review-files", "9999", "--act-files", "9999",
        )
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn("hot=3", verdict_line(p))

    def test_gate_branch_follows_the_target_kernel_pin(self):
        # an7581 pins 7.4 while the record still names kernel73; the verdict
        # must follow the pin, or it measures the branch the device no longer
        # builds.
        repo = self.repo(behind=50, behind73=1, patchver="7.4")
        p = repo.run("--quiet", "--verdict", "--review-behind", "20")
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        line = verdict_line(p)
        self.assertIn("branch=kernel74", line)
        self.assertIn("behind=50", line)

        forced = repo.run("--quiet", "--verdict", "--gate-branch", "kernel73",
                          "--review-behind", "20")
        self.assertEqual(forced.returncode, 0, forced.stdout + forced.stderr)
        self.assertIn("branch=kernel73", verdict_line(forced))
        self.assertIn("behind=1", verdict_line(forced))

    def test_unknown_when_the_gate_ref_is_missing(self):
        repo = self.repo(behind=3)
        repo.git("update-ref", "-d", "refs/remotes/upstream/kernel74")
        p = repo.run("--quiet", "--verdict", "--gate-branch", "kernel74")
        self.assertEqual(p.returncode, 3, p.stdout + p.stderr)
        self.assertIn("verdict: unknown", verdict_line(p))

    def test_list_hot_prints_only_hot_commits(self):
        repo = self.repo(behind=2, files=2, hot=2)
        p = repo.run("--list-hot")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        lines = [l for l in p.stdout.splitlines() if l.strip()]
        self.assertEqual(len(lines), 2, p.stdout)
        self.assertTrue(all("hot " in l for l in lines), p.stdout)

    def test_red_proof_drift_report_cannot_triage(self):
        # Red: before --verdict, 3 commits behind and 120 commits behind were
        # the same observation (exit 1, "verdict: drift"), so a weekly run
        # could not tell routine churn from a missed absorption window.
        small = self.repo(behind=3).run()
        self.assertEqual(small.returncode, 1, small.stdout)
        self.assertIn("verdict: drift", verdict_line(small))

        big = self.repo(behind=120).run()
        self.assertEqual(big.returncode, 1, big.stdout)
        self.assertEqual(verdict_line(small), verdict_line(big))

        # Green: the same two repos now diverge on the exit code alone.
        self.assertEqual(self.repo(behind=3).run("--quiet", "--verdict").returncode, 0)
        self.assertEqual(self.repo(behind=120).run("--quiet", "--verdict").returncode, 1)


if __name__ == "__main__":
    unittest.main()
