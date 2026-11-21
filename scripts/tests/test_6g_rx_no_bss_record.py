#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""A board with no 6G-only BSS must still leave a no-client record (#48).

The incident this exists for: on r38203-a0078bf520

    sh scripts/wireless/6g-rx.sh --source-wait 5
    SKIP: no 6G-only BSS; pass --add-bss to create a temporary one
    rc=0
    /tmp/6g-rx*            nothing

That branch called the plain ``skip()``, which writes result.json only when
``make_out()`` already ran, and ``make_out()`` runs *after* BSS selection.
So the "no 6G-only BSS" gap was doubly invisible: no no-client record and no
output directory to hold one.  ``hw-gap-report.sh`` only merges records with
``status == "no-client"``, so the gap never reached the machine-readable
table and issue #48 had to be read by hand.

The fix routes this branch through ``skip_no_client`` with its own missing
key, ``6ghz-only-bss`` - *not* ``6ghz-eht-client``.  The first means "the
board has no 6 GHz-only configuration switch and needs ``--add-bss`` (or a
hand-written 6 GHz-only AP BSS)"; the second means "a 6 GHz client has to be
bought".  Merging them would make the purchase list lie.

What is asserted here, with no device and no 6 GHz radio:

  * rc = 0;
  * exactly one ``SKIP:`` line on stdout (the reason, not a doubled skip);
  * the printed no-client record exists inside ``/tmp`` (the fallback
    directory hw-gap-report.sh scans) and parses as schema
    ``wireless-no-client/v1`` with ``status: no-client``, ``ticket: 48`` and
    ``missing: 6ghz-only-bss``.

Red half of the proof: keep a copy of the fixed script and put the bare
``skip()`` back on that one line, then run

    SIXG_RX_UNDER_TEST=<copy-with-bare-skip> \\
        python3 -m unittest scripts.tests.test_6g_rx_no_bss_record

and it fails with "no 6g-rx no-client record was printed" - the copy leaves
nothing behind, exactly as the board did.

Run from the repository root:

    python3 scripts/tests/test_6g_rx_no_bss_record.py
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _cleanup import safe_rmtree  # noqa: E402  (scripts/tests/_cleanup.py)

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get(
        "SIXG_RX_UNDER_TEST", REPO_ROOT / "scripts/wireless/6g-rx.sh"
    )
).resolve()
SH = shutil.which("sh") or "/bin/sh"

# Everything the discovery path and the record writer touch, and nothing
# that could reach a real radio: iw is a stub that reports no interface.
HOST_TOOLS = (
    "awk",
    "basename",
    "cat",
    "cp",
    "cut",
    "date",
    "dirname",
    "grep",
    "head",
    "id",
    "ip",
    "mkdir",
    "mv",
    "rm",
    "sed",
    "sleep",
    "sh",
    "sort",
    "tr",
    "wc",
)

RECORD_LINE = re.compile(r"no-client record: (\S+)")


def make_path(root: Path) -> Path:
    """A PATH whose only iw is a stub that finds no BSS at all."""
    bindir = root / "bin"
    bindir.mkdir()
    iw = bindir / "iw"
    iw.write_text("#!/bin/sh\nexit 0\n")
    iw.chmod(0o755)
    for tool in HOST_TOOLS:
        found = shutil.which(tool)
        if found is not None:
            (bindir / tool).symlink_to(found)
    return bindir


class NoBssRecordTest(unittest.TestCase):
    """No 6G-only BSS: rc=0, one SKIP line, and a no-client record."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="6g-rx-nobss."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bindir = make_path(self.tmp)
        self.record = None

    def tearDown(self):
        # The fallback directory lives under /tmp, outside self.tmp.
        if self.record is not None:
            safe_rmtree(self.record.parent)

    def run_harness(self):
        env = os.environ.copy()
        env.update(
            {
                "PATH": str(self.bindir),
                "DEBUGFS": str(self.tmp / "debugfs"),
                # netwatchdog is not part of this test.
                "NWD_ALLOW_NO_SERVICE": "1",
                "NW_GUARD_HOLD_FILE": str(self.tmp / "netwatchdog.hold"),
            }
        )
        return subprocess.run(
            [SH, str(SCRIPT)],
            env=env,
            capture_output=True,
            text=True,
            timeout=180,
            cwd=str(REPO_ROOT),
        )

    def test_no_bss_writes_a_no_client_record(self):
        res = self.run_harness()
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertNotIn("Traceback", res.stderr)

        skips = [ln for ln in res.stdout.splitlines() if ln.startswith("SKIP:")]
        self.assertEqual(len(skips), 1, res.stdout)
        self.assertIn("no 6G-only BSS", skips[0])

        match = RECORD_LINE.search(res.stdout)
        self.assertIsNotNone(
            match,
            "no 6g-rx no-client record was printed; the bare skip() path "
            "leaves nothing behind\n%s" % res.stdout,
        )
        self.record = Path(match.group(1))
        self.assertTrue(
            self.record.is_file(), "record %s does not exist" % self.record
        )
        # hw-gap-report.sh scans /tmp by default; a skip must land there.
        self.assertEqual(self.record.parent.parent, Path("/tmp"))

        data = json.loads(self.record.read_text())
        self.assertEqual(data["schema"], "wireless-no-client/v1")
        self.assertEqual(data["script"], SCRIPT.name)
        self.assertEqual(data["status"], "no-client")
        self.assertEqual(data["ticket"], "48")
        self.assertEqual(data["missing"], "6ghz-only-bss")
        self.assertIn("6G-only BSS", data["reason"])
        self.assertTrue(data["criteria"], data)


if __name__ == "__main__":
    unittest.main(verbosity=2)
