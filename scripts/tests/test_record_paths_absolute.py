#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Records must land on absolute, per-run paths, never a shared /tmp file.

Two defects, both reproduced on the board before this test existed:

  * ``6g320-matrix.sh`` wrote its records with
    ``dirname "${RESULT_JSON:-/tmp/x}"``.  With no --result-json that is
    ``/tmp``, so the skipped run and the OWE-blocked run both wrote the
    literal ``/tmp/result.json``.  Two matrix runs overwrote one record, and
    ``hw-gap-report.sh`` (which scans /tmp by default) mixed in whatever
    result.json was already there.
  * ``6g-rx.sh`` defaulted ``OUT`` to ``./6g-rx-<epoch>``, so wireless.backup,
    raw.log and result.json followed the caller's working directory and the
    printed "restore after a hard kill" path did too; a run started from / tried
    to write /6g-rx-<epoch>.

What is asserted, offline and without a radio:

  * 6g320-matrix.sh with no --result-json: the no-client record path and the
    blocked record path are absolute, are not the literal /tmp/result.json,
    and two runs of the same command use different directories.
  * 6g-rx.sh with no --out: the run directory is absolute and lives under
    /tmp; an explicit --out is still honoured verbatim.
  * 6g-rx.sh no-BSS skip: the no-client record path is absolute.

Red half: run this file against a copy of a script with the old default put
back and it fails on the first assertion that matters.  The copies are read
through the same variables the other harness tests use, plus one for the
matrix script:

    SIXG320_MATRIX_UNDER_TEST=/tmp/copy/6g320-matrix.sh \\
    SIXG_RX_UNDER_TEST=/tmp/copy/6g-rx.sh \\
        python3 -m unittest scripts.tests.test_record_paths_absolute

The record path is printed by the script under test, so it is untrusted
input: CleanupGuardProof feeds the cleanup the exact string the old code
printed (/tmp/result.json) and requires that no deletion is registered, which
is what keeps a red-half run from deleting /tmp.

Run from the repository root:

    python3 scripts/tests/test_record_paths_absolute.py
"""

import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT320 = Path(
    os.environ.get(
        "SIXG320_MATRIX_UNDER_TEST", REPO_ROOT / "scripts/wireless/6g320-matrix.sh"
    )
).resolve()
SCRIPTRX = Path(
    os.environ.get(
        "SIXG_RX_UNDER_TEST", REPO_ROOT / "scripts/wireless/6g-rx.sh"
    )
).resolve()
SH = shutil.which("sh") or "/bin/sh"

NO_CLIENT_RECORD = re.compile(r"no-client record: (\S+)")
BLOCKED_RECORD = re.compile(r"blocked record: (\S+)")
OUT_LINE = re.compile(r"^\s*out=(.*)$", re.MULTILINE)

# A 6 GHz 320 MHz AP BSS with one station whose rate width is 160 MHz: no 320
# client, so the matrix reaches its skip path without measuring anything.
IW_160_MOCK = """#!/bin/sh
case "$*" in
"dev")
	printf '\\tInterface phy1-ap0\\n'
	;;
"dev phy1-ap0 info")
	printf '\\tInterface phy1-ap0\\n\\ttype AP\\n'
	printf '\\tchannel 37 (6115 MHz), width: 320 MHz, center1: 6105 MHz\\n'
	;;
"dev phy1-ap0 station dump")
	printf 'Station aa:bb:cc:dd:ee:ff (on phy1-ap0)\\n'
	printf '\\trx bitrate:\\t1200.0 MBit/s 160MHz 2SS MCS 11\\n'
	printf '\\ttx bitrate:\\t1200.0 MBit/s 160MHz 2SS MCS 11\\n'
	;;
esac
exit 0
"""

# The on-air side of an OWE-upgraded open 6 GHz profile.
IWINFO_MOCK = """#!/bin/sh
printf '          Encryption: OWE (CCMP)\\n'
exit 0
"""

# The UCI side: band=6g AP profile still stored as encryption=none.
UCI_MOCK = """#!/bin/sh
cat <<'EOF'
wireless.radio2=wifi-device
wireless.radio2.band='6g'
wireless.default_6g=wifi-iface
wireless.default_6g.device='radio2'
wireless.default_6g.mode='ap'
wireless.default_6g.encryption='none'
EOF
exit 0
"""

# A PATH whose only iw is a stub that finds no BSS at all (6g-rx skip path).
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


def install(bindir: Path, name: str, body: str) -> None:
    path = bindir / name
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


def assert_absolute_record(test: unittest.TestCase, path: Path) -> None:
    text = str(path)
    test.assertTrue(text.startswith("/"), "record path is not absolute: %s" % text)
    test.assertNotEqual(text, "/tmp/result.json", "record fell back to shared /tmp")
    test.assertNotIn("/tmp/result.json", text)


# The run directory one of the two scripts makes when it falls back to a
# no-client record: no_client_default_dir gives <script>-no-client.<stamp>.<pid>.
NO_CLIENT_RUN_DIR = re.compile(r"6g(?:320-matrix|g-rx)-no-client\.[0-9]{8}T[0-9]{6}\.[0-9]+")


def add_run_dir_cleanup(test, record: Path, started: float = None) -> None:
    """Remove the per-run directory a record sits in, and nothing else.

    The path is printed by the script under test, so it is untrusted input: a
    pre-fix script prints /tmp/result.json, whose "record directory" by the
    naive parents[1] rule is /tmp, and an unguarded rmtree there is an rmtree
    of /tmp.  A directory qualifies only when it is a direct child of /tmp,
    carries the no-client run-directory name, and is not older than the test
    that found it; otherwise nothing is registered and the directory stays.
    """
    parents = list(record.parents)
    run_dir = parents[1] if len(parents) > 1 else None
    if run_dir is None or run_dir.parent != Path("/tmp"):
        return
    if not NO_CLIENT_RUN_DIR.fullmatch(run_dir.name):
        return
    if started is not None:
        try:
            if run_dir.stat().st_ctime < started - 1:
                return
        except OSError:
            return
    test.addCleanup(shutil.rmtree, run_dir, ignore_errors=True)


class _CleanupRecorder:
    """Just enough of a TestCase to see whether addCleanup was called."""

    def __init__(self):
        self.registered = []

    def addCleanup(self, fn, *args, **kwargs):
        self.registered.append((fn, args, kwargs))


class CleanupGuardProof(unittest.TestCase):
    """Proof that the cleanup refuses a path the script printed as /tmp.

    The record path comes from the script under test, so the guard is what
    stands between a red-half run and an rmtree of /tmp.  This feeds the guard
    the exact string the old code produced -- /tmp/result.json -- and requires
    that nothing is registered.  The bad copy below writes that shared file on
    purpose; it is removed again unless it was already there.
    """

    def test_shared_tmp_record_registers_no_deletion(self):
        tmp = Path(tempfile.mkdtemp(prefix="dirfix-guard."))
        self.addCleanup(shutil.rmtree, tmp, True)
        scripts = tmp / "scripts"
        shutil.copytree(REPO_ROOT / "scripts" / "wireless", scripts / "wireless")
        (scripts / "lib").symlink_to(REPO_ROOT / "scripts" / "lib")
        bad_copy = scripts / "wireless" / "6g320-matrix.sh"
        src = bad_copy.read_text()
        old = '$(dirname "${RESULT_JSON:-/tmp/x}")'
        bad = src.replace("$(record_dir blocked)", old).replace(
            "$(record_dir no-client)", old)
        self.assertNotEqual(bad, src, "the old default is gone: update this copy")
        bad_copy.write_text(bad)

        bin_dir = tmp / "bin"
        bin_dir.mkdir()
        install(bin_dir, "iw", "#!/bin/sh\nexit 0\n")
        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}{os.pathsep}{env.get('PATH', '/usr/bin:/bin')}"

        shared = Path("/tmp/result.json")
        if not shared.exists():
            self.addCleanup(lambda: shared.exists() and shared.unlink())

        started = time.time()
        proc = subprocess.run(
            [SH, str(bad_copy)], capture_output=True, text=True, timeout=120,
            env=env, cwd=str(tmp))
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        printed = NO_CLIENT_RECORD.search(proc.stdout)
        self.assertIsNotNone(printed, proc.stdout + proc.stderr)
        record = Path(printed.group(1))
        self.assertEqual(str(record), "/tmp/result.json",
                         "the bad copy no longer reproduces the shared path")

        recorder = _CleanupRecorder()
        add_run_dir_cleanup(recorder, record, started)
        self.assertEqual(recorder.registered, [],
                         "cleanup armed a deletion for a shared /tmp path")
        self.assertTrue(Path("/tmp").is_dir(), "/tmp is gone")


class MatrixRecordPaths(unittest.TestCase):
    """6g320-matrix.sh records: no --result-json must not mean /tmp."""

    def setUp(self):
        self.started = time.time()
        self.tmp = Path(tempfile.mkdtemp(prefix="6g320-record-paths."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()

    def run_matrix(self, *args):
        env = os.environ.copy()
        env["PATH"] = f"{self.bin}{os.pathsep}{env.get('PATH', '/usr/bin:/bin')}"
        return subprocess.run(
            [SH, str(SCRIPT320), *map(str, args)],
            capture_output=True,
            text=True,
            timeout=120,
            env=env,
            cwd=str(self.tmp),
        )

    def record(self, proc, pattern, label):
        match = pattern.search(proc.stdout)
        self.assertIsNotNone(
            match, "no %s record was printed\n%s%s" % (label, proc.stdout, proc.stderr)
        )
        path = Path(match.group(1))
        add_run_dir_cleanup(self, path, self.started)
        return path

    def test_no_client_record_is_absolute_and_per_run(self):
        install(self.bin, "iw", "#!/bin/sh\nexit 0\n")
        first = self.run_matrix()
        second = self.run_matrix()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertIn("SKIP: no 320 client", first.stdout)
        one = self.record(first, NO_CLIENT_RECORD, "no-client")
        two = self.record(second, NO_CLIENT_RECORD, "no-client")
        assert_absolute_record(self, one)
        assert_absolute_record(self, two)
        self.assertNotEqual(one.parent, two.parent, "two runs shared one record dir")
        self.assertEqual(one.parent.name, "no-client")
        self.assertEqual(one.parent.parent.parent, Path("/tmp"))
        data = json.loads(one.read_text())
        self.assertEqual(data["status"], "no-client")
        self.assertEqual(data["ticket"], "47")

    def test_blocked_record_is_absolute_and_per_run(self):
        install(self.bin, "iw", IW_160_MOCK)
        install(self.bin, "iwinfo", IWINFO_MOCK)
        install(self.bin, "uci", UCI_MOCK)
        first = self.run_matrix()
        second = self.run_matrix()
        self.assertEqual(first.returncode, 2, first.stdout + first.stderr)
        self.assertIn("BLOCKED:", first.stdout)
        one = self.record(first, BLOCKED_RECORD, "blocked")
        two = self.record(second, BLOCKED_RECORD, "blocked")
        assert_absolute_record(self, one)
        assert_absolute_record(self, two)
        self.assertNotEqual(one.parent, two.parent, "two runs shared one record dir")
        self.assertEqual(one.parent.name, "blocked")
        self.assertEqual(one.parent.parent.parent, Path("/tmp"))
        data = json.loads(one.read_text())
        self.assertEqual(data["status"], "blocked")
        self.assertEqual(data["ticket"], "47")
        self.assertEqual(data["missing"], "6ghz-owe-mismatch")

    def test_both_records_survive_in_separate_directories(self):
        """Both trigger inputs: blocked and no-client must not share a file.

        The old code fed both branches the same ``dirname`` argument, so the
        second record of a run could only land on top of the first.
        """
        install(self.bin, "iwinfo", IWINFO_MOCK)
        install(self.bin, "uci", UCI_MOCK)
        install(self.bin, "iw", IW_160_MOCK)
        blocked = self.run_matrix()
        install(self.bin, "iw", "#!/bin/sh\nexit 0\n")
        no_client = self.run_matrix()
        one = self.record(blocked, BLOCKED_RECORD, "blocked")
        two = self.record(no_client, NO_CLIENT_RECORD, "no-client")
        assert_absolute_record(self, one)
        assert_absolute_record(self, two)
        self.assertTrue(one.is_file(), "%s was overwritten" % one)
        self.assertTrue(two.is_file(), "%s was overwritten" % two)
        self.assertNotEqual(one.parent, two.parent, "one directory holds both records")
        missing = {
            json.loads(one.read_text())["missing"],
            json.loads(two.read_text())["missing"],
        }
        self.assertEqual(missing, {"6ghz-owe-mismatch", "6ghz-320mhz-ap-bss"})


class RxOutDefault(unittest.TestCase):
    """6g-rx.sh default OUT must be absolute; explicit --out is respected."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="6g-rx-record-paths."))
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def dry_run(self, *args, cwd=None):
        env = os.environ.copy()
        return subprocess.run(
            [SH, str(SCRIPTRX), "--dry-run", *map(str, args)],
            capture_output=True,
            text=True,
            timeout=120,
            env=env,
            cwd=str(cwd or self.tmp),
        )

    def test_default_out_is_absolute_under_tmp(self):
        first = self.dry_run()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        one = Path(OUT_LINE.search(first.stdout).group(1))
        time.sleep(1.1)
        second = self.dry_run()
        two = Path(OUT_LINE.search(second.stdout).group(1))
        assert_absolute_record(self, one)
        assert_absolute_record(self, two)
        self.assertEqual(one.parent, Path("/tmp"))
        self.assertTrue(one.name.startswith("6g-rx-"), one)
        self.assertNotEqual(one, two, "two runs shared one output directory")

    def test_explicit_out_is_kept_verbatim(self):
        proc = self.dry_run("--out", "./6g-rx-explicit")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(OUT_LINE.search(proc.stdout).group(1), "./6g-rx-explicit")


class RxSkipRecord(unittest.TestCase):
    """A 6g-rx no-BSS skip record path is absolute too."""

    def setUp(self):
        self.started = time.time()
        self.tmp = Path(tempfile.mkdtemp(prefix="6g-rx-skip-paths."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        install(self.bin, "iw", "#!/bin/sh\nexit 0\n")
        for tool in HOST_TOOLS:
            found = shutil.which(tool)
            if found is not None:
                (self.bin / tool).symlink_to(found)

    def run_harness(self):
        env = os.environ.copy()
        env.update(
            {
                "PATH": str(self.bin),
                "DEBUGFS": str(self.tmp / "debugfs"),
                "NWD_ALLOW_NO_SERVICE": "1",
                "NW_GUARD_HOLD_FILE": str(self.tmp / "netwatchdog.hold"),
            }
        )
        return subprocess.run(
            [SH, str(SCRIPTRX)],
            capture_output=True,
            text=True,
            timeout=180,
            env=env,
            cwd=str(REPO_ROOT),
        )

    def test_skip_record_is_absolute_and_per_run(self):
        first = self.run_harness()
        second = self.run_harness()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        match = NO_CLIENT_RECORD.search(first.stdout)
        self.assertIsNotNone(match, first.stdout + first.stderr)
        one = Path(match.group(1))
        two = Path(NO_CLIENT_RECORD.search(second.stdout).group(1))
        add_run_dir_cleanup(self, one, self.started)
        add_run_dir_cleanup(self, two, self.started)
        assert_absolute_record(self, one)
        assert_absolute_record(self, two)
        self.assertEqual(one.parent.parent, Path("/tmp"))
        self.assertNotEqual(one.parent, two.parent)


if __name__ == "__main__":
    unittest.main(verbosity=2)
