#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The cleanup guard must refuse everything it did not create itself.

The incident behind it: a test parsed a record path out of the program under
test and cleaned up ``shutil.rmtree(record_path.parent)``.  A broken copy
printed ``/tmp/result.json``, whose parents[1] is ``/``, so the cleanup ran
``shutil.rmtree("/")`` and deleted a build tree outside the repository.

What is asserted here:

  * ``/`` is refused, and a real directory tree survives with the scratch
    root pointed at it (the guard's checks do not depend on /tmp);
  * ``/tmp`` itself is refused;
  * a name outside the repository's run-directory convention is refused,
    and the directory stays;
  * a real ``/tmp/6g-rx-no-client.<n>`` directory is removed.

Red half of the proof: make the whitelist check pass unconditionally -
replace the ``if len(...) or ...`` condition in ``safe_rmtree`` with
``if False:`` - and case 1 deletes the tree, so this file FAILS.

Run from the repository root:

    python3 -m unittest scripts.tests.test_cleanup_guard
"""

import contextlib
import io
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _cleanup  # noqa: E402  (scripts/tests/_cleanup.py)
from _cleanup import safe_rmtree  # noqa: E402


class SafeRmtreeTest(unittest.TestCase):
    def setUp(self):
        # Everything this test removes is created by this test.
        self.sandbox = Path(tempfile.mkdtemp(prefix="cleanup-guard."))
        self.addCleanup(shutil.rmtree, self.sandbox)

    def refuse(self, path):
        """Assert refusal, with the real rmtree replaced by a stub.

        The stub is not politeness: the guard's red half passes everything,
        and this test would otherwise delete / or /tmp for real.
        """
        err = io.StringIO()
        with mock.patch.object(_cleanup.shutil, "rmtree") as rmtree:
            with contextlib.redirect_stderr(err):
                removed = safe_rmtree(path)
        self.assertFalse(removed, "%s must be refused" % path)
        rmtree.assert_not_called()
        self.assertIn(
            "safe_rmtree: refusing to remove %s " % path, err.getvalue()
        )
        return removed

    def test_refuses_root_even_when_the_scratch_root_is_ours(self):
        run = self.sandbox / "6g-rx-no-client.1"
        run.mkdir()
        sentinel = run / "result.json"
        sentinel.write_text("{}")
        with mock.patch.object(_cleanup, "SCRATCH_ROOTS", (self.sandbox,)):
            self.refuse(Path("/"))
            # A directory one level above the run dir is not a run dir.
            self.refuse(self.sandbox)
        self.assertTrue(sentinel.is_file(), "the tree was deleted")

    def test_refuses_tmp_itself(self):
        self.refuse("/tmp")
        self.assertTrue(Path("/tmp").is_dir())

    def test_refuses_a_name_outside_the_run_dir_convention(self):
        d = Path("/tmp/not-a-run-dir")
        if d.exists():
            self.skipTest("%s already exists; not ours to remove" % d)
        d.mkdir()
        # The gate cannot tell whose path 'd' is: it is not a mkdtemp name and
        # not one of its own-name words.  This test made it two lines up and
        # asserts below that the guard left it alone, so the cleanup is ours.
        self.addCleanup(shutil.rmtree, d, True)  # noqa: cleanup-safety created by this test just above
        self.refuse(d)
        self.assertTrue(d.is_dir())

    def test_removes_a_real_run_directory(self):
        d = Path("/tmp/6g-rx-no-client.12345")
        if d.exists():
            self.skipTest("%s already exists; not ours to remove" % d)
        d.mkdir()
        (d / "result.json").write_text("{}")
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertTrue(safe_rmtree(d))
        self.assertFalse(d.exists(), "the run directory was not removed")
        self.assertEqual(err.getvalue(), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
