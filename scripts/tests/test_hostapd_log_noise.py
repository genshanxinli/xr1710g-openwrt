#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The syslog ring survives an unsolicited Link Measurement Report.

Two defects from the r20 live review, one user-visible symptom:

  * N2: ``hostapd`` logged ``Unexpected Link measurement report, token 1``
    at ``MSG_INFO`` every time a 5 GHz client sent an unsolicited RRM Link
    Measurement Report, i.e. one the AP never requested.  On the board all
    980 hostapd lines in ``logread`` were this one message, at
    ``logger_syslog_level=2`` (MSG_INFO).
  * N9: ``logd -S 128`` plus the stock ``system.@system[0].log_size=128``
    kept nine minutes of boot log; everything before ``19:03:55`` was
    already evicted when the review ran.

The fix is a pair that is only useful together: the hostapd hunk lowers the
message to ``MSG_EXCESSIVE`` (still visible at ``-ddd``), and the
XR1710G uci-defaults script raises the ring to 512 KiB without touching an
operator-chosen size.

What is asserted, offline and without hardware:

  * exactly one patch under ``package/network/services/hostapd/patches/``
    carries the message, it edits ``src/ap/rrm.c``, and the added line calls
    ``wpa_printf(MSG_EXCESSIVE,`` while the removed line called
    ``wpa_printf(MSG_INFO,``;
  * when a hostapd source tree is available (``HOSTAPD_RRM_UNDER_TEST`` or a
    ``build_dir`` checkout), the patch applies to a copy of ``src/ap/rrm.c``
    with ``patch -p1 --fuzz=0`` and the result no longer logs the message at
    MSG_INFO;
  * ``62_xr1710g-log-size`` bumps the stock ``128`` to ``512`` and commits,
    bumps an unset option the same way, leaves ``256`` (operator choice)
    alone without a commit, and does nothing on another an7581 board;
  * the evidence line goes to ``/dev/kmsg`` (visible in ``dmesg``) and not to
    ``logger``: this hook runs at ``START=10``, logd starts at ``START=12``,
    so a ``logger`` line would be written to a /dev/log nobody listens on;
  * the uci-defaults script parses under ``sh -n`` and is executable.

Red half: point ``HOSTAPD_PATCHES_UNDER_TEST`` at the pre-fix patch
directory and ``XR1710G_LOG_UCI_DEFAULTS_UNDER_TEST`` at a pre-fix copy (or
run before either file exists).  The run fails on the first assertion that
matters: no patch lowers the message, and no uci-defaults script raises
``log_size``.

Run from the repository root:

    python3 -m unittest scripts.tests.test_hostapd_log_noise
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PATCH_DIR = Path(
    os.environ.get(
        "HOSTAPD_PATCHES_UNDER_TEST",
        REPO_ROOT / "package/network/services/hostapd/patches",
    )
).resolve()
UCI_DEFAULTS = Path(
    os.environ.get(
        "XR1710G_LOG_UCI_DEFAULTS_UNDER_TEST",
        REPO_ROOT
        / "target/linux/airoha/an7581/base-files/etc/uci-defaults/62_xr1710g-log-size",
    )
).resolve()

BOARD = "gemtek,xr1710g-ubi"
OTHER_BOARD = "gemtek,w1700k-ubi"
MESSAGE = "Unexpected Link measurement report"

SH = shutil.which("sh") or "/bin/sh"
PATCH = shutil.which("patch")

MOCK_UCI = r'''#!/bin/sh
[ "$1" = "-q" ] && shift
case "$1" in
get)
	[ "$2" = "system.@system[0].log_size" ] || exit 1
	[ -f "$MOCK_UCI_VALUE" ] || exit 1
	cat "$MOCK_UCI_VALUE"
	;;
set)
	name=${2%%=*}
	value=${2#*=}
	[ "$name" = "system.@system[0].log_size" ] || exit 1
	printf '%s\n' "$value" > "$MOCK_UCI_VALUE"
	;;
commit)
	printf 'commit %s\n' "$2" >> "$MOCK_UCI_CALLS"
	;;
*)
	exit 1
	;;
esac
'''

MOCK_LOGGER = r'''#!/bin/sh
tag=-
while [ $# -gt 1 ]; do
	case "$1" in
	-t) tag=$2; shift 2 ;;
	*) break ;;
	esac
done
printf '%s %s\n' "$tag" "$*" >> "$MOCK_LOGGER_LOG"
'''

LIB_FUNCTIONS = r'''board_name() {
	cat "$BOARD_NAME_FILE"
}
'''


def write_exec(path, text):
    path.write_text(text)
    path.chmod(0o755)


def find_message_patch():
    """Return the patch that carries the RRM message, or None."""
    for path in sorted(PATCH_DIR.glob("*.patch")):
        if MESSAGE in path.read_text(errors="replace"):
            return path
    return None


def rrm_source():
    """A hostapd src/ap/rrm.c to test, or None when no tree is present."""
    override = os.environ.get("HOSTAPD_RRM_UNDER_TEST")
    if override:
        return Path(override).resolve()
    matches = sorted(REPO_ROOT.glob("build_dir/target-*/hostapd-*/hostapd-*/src/ap/rrm.c"))
    return matches[0] if matches else None


class HostapdPatchTest(unittest.TestCase):
    def test_one_patch_downgrades_the_message(self):
        hits = [
            path for path in sorted(PATCH_DIR.glob("*.patch"))
            if MESSAGE in path.read_text(errors="replace")
        ]
        self.assertEqual(
            1, len(hits),
            "%s carries %r; expected exactly one patch, got %s"
            % (PATCH_DIR, MESSAGE, [path.name for path in hits]),
        )
        patch = hits[0]
        text = patch.read_text()
        removed = [line[1:] for line in text.splitlines() if line.startswith("-") and not line.startswith("---")]
        added = [line[1:] for line in text.splitlines() if line.startswith("+") and not line.startswith("+++")]
        self.assertIn("+++ b/src/ap/rrm.c", text, "%s does not edit src/ap/rrm.c" % patch.name)
        self.assertIn("\t\twpa_printf(MSG_INFO,", removed, "%s keeps MSG_INFO" % patch.name)
        self.assertIn(
            "\t\twpa_printf(MSG_EXCESSIVE,",
            added,
            "%s does not lower the message to MSG_EXCESSIVE" % patch.name,
        )
        self.assertEqual(
            1,
            len([line for line in added if "wpa_printf(" in line]),
            "%s adds more than the one level change" % patch.name,
        )

    def test_patch_applies_with_zero_fuzz_and_lowers_the_level(self):
        if PATCH is None:
            self.skipTest("patch(1) not installed")
        source = rrm_source()
        if source is None or not source.is_file():
            self.skipTest("no hostapd src/ap/rrm.c; set HOSTAPD_RRM_UNDER_TEST")
        patch = find_message_patch()
        self.assertIsNotNone(patch, "no patch to apply")

        tmp = Path(tempfile.mkdtemp(prefix="hostapd-rrm."))
        try:
            ap = tmp / "src" / "ap"
            ap.mkdir(parents=True)
            copy = ap / "rrm.c"
            shutil.copy2(source, copy)

            if "wpa_printf(MSG_EXCESSIVE,\n\t\t\t   \"%s" % MESSAGE in copy.read_text():
                # Build trees already carry the applied patch; reverse it with
                # --fuzz=0 first so the forward --fuzz=0 check is never skipped.
                rev = subprocess.run(
                    [PATCH, "--batch", "-R", "-p1", "--fuzz=0", "--no-backup-if-mismatch",
                     "-i", str(patch)],
                    cwd=str(tmp), stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    universal_newlines=True,
                )
                self.assertEqual(
                    0, rev.returncode,
                    "%s did not reverse-apply with --fuzz=0 on already-patched rrm.c:\n%s%s"
                    % (patch.name, rev.stdout, rev.stderr),
                )
                self.assertIn(
                    "wpa_printf(MSG_INFO,\n\t\t\t   \"%s" % MESSAGE,
                    copy.read_text(),
                    "reverse-applying %s did not restore MSG_INFO" % patch.name,
                )

            result = subprocess.run(
                [PATCH, "--batch", "-p1", "--fuzz=0", "--no-backup-if-mismatch",
                 "-i", str(patch)],
                cwd=str(tmp), stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                universal_newlines=True,
            )
            self.assertEqual(
                0, result.returncode,
                "%s did not apply with --fuzz=0:\n%s%s"
                % (patch.name, result.stdout, result.stderr),
            )

            text = copy.read_text()
            self.assertIn(
                "wpa_printf(MSG_EXCESSIVE,\n\t\t\t   \"%s" % MESSAGE,
                text,
                "patched rrm.c still does not log the message at MSG_EXCESSIVE",
            )
            self.assertNotIn(
                "wpa_printf(MSG_INFO,\n\t\t\t   \"%s" % MESSAGE,
                text,
                "patched rrm.c still logs the message at MSG_INFO",
            )
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class LogSizeDefaultsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="log-size."))
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.lib = self.tmp / "lib"
        self.lib.mkdir()
        write_exec(self.bin / "uci", MOCK_UCI)
        write_exec(self.bin / "logger", MOCK_LOGGER)
        host_cat = shutil.which("cat")
        if host_cat:
            (self.bin / "cat").symlink_to(host_cat)
        (self.lib / "functions.sh").write_text(LIB_FUNCTIONS)
        self.board = self.tmp / "board"
        self.board.write_text(BOARD + "\n")
        self.value = self.tmp / "value"
        self.calls = self.tmp / "calls"
        self.log = self.tmp / "logger.log"
        self.log.write_text("")
        # The hook writes the kernel ring; keep that write inside the sandbox.
        self.kmsg = self.tmp / "kmsg"
        self.kmsg.write_text("")
        self.script = self.tmp / "62_xr1710g-log-size"
        self.source = UCI_DEFAULTS.read_text() if UCI_DEFAULTS.is_file() else None
        if self.source is not None:
            rewritten = self.source.replace(
                ". /lib/functions.sh", '. "%s/functions.sh"' % self.lib)
            self.assertNotEqual(rewritten, self.source,
                                "the script no longer sources /lib/functions.sh")
            rewritten = rewritten.replace("/dev/kmsg", str(self.kmsg))
            self.script.write_text(rewritten)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_script(self, current, board=BOARD):
        if self.source is None:
            self.fail("%s does not exist; the ring is still 128 KiB" % UCI_DEFAULTS)
        self.board.write_text(board + "\n")
        if current is None:
            self.value.unlink(missing_ok=True)
        else:
            self.value.write_text(current + "\n")
        self.calls.unlink(missing_ok=True)
        self.log.write_text("")
        self.kmsg.write_text("")
        env = dict(os.environ)
        env.update({
            "PATH": str(self.bin),
            "MOCK_UCI_VALUE": str(self.value),
            "MOCK_UCI_CALLS": str(self.calls),
            "MOCK_LOGGER_LOG": str(self.log),
            "BOARD_NAME_FILE": str(self.board),
        })
        result = subprocess.run(
            [SH, str(self.script)], env=env, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, universal_newlines=True)
        self.assertEqual(0, result.returncode, result.stderr)
        return result

    def test_stock_128_is_raised_to_512(self):
        self.run_script("128")
        self.assertEqual("512", self.value.read_text().strip())
        self.assertIn("commit system", self.calls.read_text())
        self.assertIn("xr1710g-log-size", self.kmsg.read_text())
        self.assertIn("512", self.kmsg.read_text())
        self.assertFalse(
            self.log.read_text(),
            "logger ran at START=10, before logd listens on /dev/log; use /dev/kmsg",
        )

    def test_unset_option_is_raised_to_512(self):
        self.run_script(None)
        self.assertEqual("512", self.value.read_text().strip())
        self.assertIn("commit system", self.calls.read_text())

    def test_operator_choice_is_left_alone(self):
        self.run_script("256")
        self.assertEqual("256", self.value.read_text().strip())
        self.assertFalse(self.calls.exists(), "committed over an operator choice")

    def test_other_board_is_left_alone(self):
        self.run_script("128", board=OTHER_BOARD)
        self.assertEqual("128", self.value.read_text().strip())
        self.assertFalse(self.calls.exists(), "changed a non-XR1710G board")

    def test_script_parses_and_is_executable(self):
        if self.source is None:
            self.fail("%s does not exist" % UCI_DEFAULTS)
        self.assertTrue(os.access(UCI_DEFAULTS, os.X_OK), "%s is not executable" % UCI_DEFAULTS)
        result = subprocess.run(
            [SH, "-n", str(UCI_DEFAULTS)], stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, universal_newlines=True)
        self.assertEqual(0, result.returncode, result.stderr)


if __name__ == "__main__":
    unittest.main()
