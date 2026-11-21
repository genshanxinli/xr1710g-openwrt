#!/usr/bin/env python3
"""Gate on the published feed index: it must describe the .apk files it ships.

The incident this exists for: ``build-distfeeds.sh`` ran while ``make -j12`` was
still writing ``bin/``, so the copied tree held

    bin/targets/airoha/an7581/packages/index.json   base-files 1722~23751e1da6
    bin/targets/airoha/an7581/packages/*.apk        base-files-1722~1226d64f38.apk

The release tarball then installed nothing, and no gate went red:
``fail_on_unmatched_files`` only asks whether the tarball exists, ``test -s``
only asks whether it is non-empty.  ``packages.adb`` cannot be the carrier of
this check either, it is ``ADBd`` + raw deflate and this tree does not re-encode
an apk index.  ``index.json`` is the readable side of the same claim, so the
gate compares it against the directory.

Both cases run the real script against a synthetic ``bin/`` (nothing is built)
and assert the exit code and stderr:

  (a) index and disk agree          -> rc 0
  (b) index names 1722~old, disk    -> rc != 0, stderr names "stale-index"
      holds 1722~new                   and "base-files"
  (c) an apk in bin/ carries an mtime from the future, i.e. bin/ moved while
      the script ran               -> rc != 0, "bin/ changed while this ran"

Red half of the proof: run the same suite with
``BUILD_DISTFEEDS_UNDER_TEST=<pre-fix build-distfeeds.sh>``; (b) and (c) fail
there because the old script publishes the stale tree with rc 0.

    python3 -m unittest scripts.tests.test_distfeeds_index
"""

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SCRIPT = Path(
    os.environ.get("BUILD_DISTFEEDS_UNDER_TEST", REPO_ROOT / "scripts" / "build-distfeeds.sh")
)

# Fixture files are written before the script starts; an mtime in the past keeps
# them from looking like a build that was still running.
PAST = 946684800  # 2000-01-01
FUTURE_SLACK = 3600


def make_tree(root, packages, apks):
    """A TOPDIR whose only feed declares ``packages`` and holds ``apks``."""
    feed = root / "bin" / "targets" / "board" / "sub" / "packages"
    feed.mkdir(parents=True)
    (feed / "packages.adb").write_bytes(b"ADBd")
    (feed / "index.json").write_text(
        json.dumps(
            {
                "version": 2,
                "architecture": "aarch64_cortex-a53",
                "packages": packages,
            }
        )
    )
    for apk in apks:
        (feed / ("%s.apk" % apk)).write_bytes(b"")
    for path in feed.iterdir():
        os.utime(path, (PAST, PAST))
    return feed


def run(root, out):
    env = dict(os.environ, TOPDIR=str(root))
    return subprocess.run(
        ["sh", str(SCRIPT), str(out)],
        env=env,
        capture_output=True,
        text=True,
    )


class DistfeedsIndexTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def test_consistent_index_publishes(self):
        root = self.tmp / "tree"
        make_tree(
            root,
            {"base-files": "1722~abc", "kernel": "7.4-r1", "kmod-fake": "7.4-r1"},
            ["base-files-1722~abc", "kernel-7.4-r1", "kmod-fake-7.4-r1"],
        )
        r = run(root, self.tmp / "out")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("total: 3 packages", r.stdout)
        self.assertNotIn("stale-index", r.stderr)

    def test_stale_index_is_refused(self):
        root = self.tmp / "tree"
        make_tree(
            root,
            {"base-files": "1722~old", "kernel": "7.4-r1", "kmod-fake": "7.4-r1"},
            ["base-files-1722~new", "kernel-7.4-r1", "kmod-fake-7.4-r1"],
        )
        r = run(root, self.tmp / "out")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("stale-index", r.stderr)
        self.assertIn("base-files", r.stderr)
        self.assertIn("1722~old", r.stderr)

    def test_bin_touched_during_run_is_refused(self):
        root = self.tmp / "tree"
        feed = make_tree(
            root,
            {"base-files": "1722~abc", "kernel": "7.4-r1", "kmod-fake": "7.4-r1"},
            ["base-files-1722~abc", "kernel-7.4-r1", "kmod-fake-7.4-r1"],
        )
        touched = feed / "base-files-1722~abc.apk"
        later = time.time() + FUTURE_SLACK
        os.utime(touched, (later, later))
        r = run(root, self.tmp / "out")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("bin/ changed while this ran", r.stderr)
        self.assertIn("base-files-1722~abc.apk", r.stderr)


if __name__ == "__main__":
    sys.exit(unittest.main())
