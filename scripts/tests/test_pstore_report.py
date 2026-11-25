#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline behaviour tests for etc/init.d/pstore-report (#383).

At boot (START=15, aligned with logd), ``pstore-report`` waits briefly for
``/dev/log`` if needed, verifies the ramoops reservation in ``/proc/iomem`` by
physical address (``^86ff0000-``, never ``grep ramoops``), logs the live
``/sys/module/ramoops/parameters/{mem_address,mem_size,console_size}`` values,
verifies ``/sys/fs/pstore`` is mounted via ``/proc/mounts`` (warning rather
than claiming a clean boot when unmounted), skips binary/compressed ``*.enc.z``
bodies, and sanitizes/bounds text tails before logging via ``logger -t pstore``
without deleting any records.

Inject an alternative copy via ``PSTORE_REPORT_UNDER_TEST`` for the red half:

    PSTORE_REPORT_UNDER_TEST=/path/to/old python3 -m unittest \
        scripts.tests.test_pstore_report -v

Run from the repository root:

    python3 -m unittest scripts.tests.test_pstore_report -v
"""

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get(
        "PSTORE_REPORT_UNDER_TEST",
        REPO_ROOT / "target/linux/airoha/an7581/base-files/etc/init.d/pstore-report",
    )
).resolve()

SH = shutil.which("sh") or "/bin/sh"

MOCK_LOGGER = r"""#!/bin/sh
tag=-
while [ $# -gt 1 ]; do
	case "$1" in
	-t) tag=$2; shift 2 ;;
	*) break ;;
	esac
done
printf '%s: %s\n' "$tag" "$*" >> "$MOCK_LOGGER_LOG"
"""


class PstoreReportTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="pstore-report."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        logger = self.bin / "logger"
        logger.write_text(MOCK_LOGGER, encoding="utf-8")
        logger.chmod(0o755)
        self.log = self.tmp / "logger.log"
        self.log.write_text("", encoding="utf-8")
        self.pstore = self.tmp / "pstore"
        self.pstore.mkdir()
        self.iomem = self.tmp / "iomem"
        self.mounts = self.tmp / "mounts"
        self.mounts.write_text(
            f"pstore {self.pstore} pstore rw,relatime 0 0\n",
            encoding="utf-8",
        )
        self.params = self.tmp / "ramoops_params"
        self.params.mkdir()

    def write_ramoops_params(self, mem_address="2264858624", mem_size="65536", console_size="16384"):
        (self.params / "mem_address").write_text(mem_address + "\n", encoding="utf-8")
        (self.params / "mem_size").write_text(mem_size + "\n", encoding="utf-8")
        (self.params / "console_size").write_text(console_size + "\n", encoding="utf-8")

    def run_boot(self, pstore_dir=None, mounts_file=None, log_sock=None, log_wait=0):
        env = dict(os.environ)
        env.update(
            {
                "PATH": f"{self.bin}{os.pathsep}{os.environ.get('PATH', '/usr/bin:/bin')}",
                "MOCK_LOGGER_LOG": str(self.log),
                "PSTORE_REPORT_DIR": str(pstore_dir if pstore_dir is not None else self.pstore),
                "PSTORE_REPORT_IOMEM": str(self.iomem),
                "PSTORE_REPORT_MOUNTS": str(mounts_file if mounts_file is not None else self.mounts),
                "PSTORE_REPORT_RAMOOPS_PARAMS": str(self.params),
                "PSTORE_REPORT_LOG_WAIT": str(log_wait),
            }
        )
        if log_sock is not None:
            env["PSTORE_REPORT_LOG_SOCK"] = str(log_sock)
        self.log.write_text("", encoding="utf-8")
        return subprocess.run(
            [SH, "-c", '. "$1"; boot', "sh", str(SCRIPT)],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_script_metadata_and_no_grep_ramoops(self):
        self.assertTrue(SCRIPT.is_file(), f"{SCRIPT} does not exist")
        mode = stat.S_IMODE(SCRIPT.stat().st_mode)
        self.assertEqual(mode & 0o111, 0o111, f"{SCRIPT} must be executable (0755)")
        text = SCRIPT.read_text(encoding="utf-8")
        first_line = text.splitlines()[0]
        self.assertEqual(first_line, "#!/bin/sh /etc/rc.common")
        self.assertIn("START=15", text)
        self.assertIn("^86ff0000-", text)
        self.assertNotRegex(
            text,
            r"\bgrep\b[^\n]*ramoops",
            "must check ^86ff0000- in /proc/iomem, never grep ramoops",
        )

    def test_clean_boot_logs_ramoops_health_and_empty_pstore(self):
        self.iomem.write_text(
            "80000000-801fffff : System RAM\n"
            "86ff0000-86ffffff : reserved\n",
            encoding="utf-8",
        )
        self.write_ramoops_params()
        proc = self.run_boot()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        log = self.log.read_text(encoding="utf-8")
        self.assertIn("pstore:", log)
        self.assertIn("86ff0000", log)
        self.assertIn("present", log)
        self.assertIn("mem_address=2264858624", log)
        self.assertIn("mem_size=65536", log)
        self.assertIn("console_size=16384", log)
        self.assertIn("no surviving", log)

    def test_unmounted_pstore_warns_instead_of_claiming_clean_boot(self):
        self.iomem.write_text("86ff0000-86ffffff : reserved\n", encoding="utf-8")
        self.write_ramoops_params()
        self.mounts.write_text("proc /proc proc rw 0 0\n", encoding="utf-8")
        proc = self.run_boot()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        log = self.log.read_text(encoding="utf-8")
        self.assertIn("not mounted", log)
        self.assertNotIn("clean boot", log)

    def test_surviving_records_logged_with_name_size_and_tail_and_preserved(self):
        self.iomem.write_text("86ff0000-86ffffff : reserved\n", encoding="utf-8")
        self.write_ramoops_params()
        console_text = (
            "[  101.000] Kernel panic - not syncing: hardlockup\n"
            "[  101.001] CPU: 0 PID: 0 Comm: swapper/0\n"
            "[  101.002] Rebooting in 3 seconds..\n"
        )
        dmesg_text = "Panic#1 Part1\n<0>Call trace:\n<0> airoha_wdt_ping+0x14\n"
        cfile = self.pstore / "console-ramoops-0"
        dfile = self.pstore / "dmesg-ramoops-0"
        cfile.write_text(console_text, encoding="utf-8")
        dfile.write_text(dmesg_text, encoding="utf-8")

        proc = self.run_boot()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        log = self.log.read_text(encoding="utf-8")
        self.assertIn(f"console-ramoops-0 ({len(console_text)} bytes)", log)
        self.assertIn(f"dmesg-ramoops-0 ({len(dmesg_text)} bytes)", log)
        self.assertIn("Kernel panic - not syncing: hardlockup", log)
        self.assertIn("airoha_wdt_ping+0x14", log)
        self.assertIn("2 surviving", log)
        # Read-only reporter: records remain intact in /sys/fs/pstore.
        self.assertTrue(cfile.exists())
        self.assertTrue(dfile.exists())

    def test_compressed_enc_z_logs_metadata_only_and_skips_body_tail(self):
        self.iomem.write_text("86ff0000-86ffffff : reserved\n", encoding="utf-8")
        self.write_ramoops_params()
        payload = b"\x78\x9cBINARY_ZLIB_MARKER_DO_NOT_TAIL\x00\xff\n"
        zfile = self.pstore / "dmesg-ramoops-0.enc.z"
        zfile.write_bytes(payload)

        proc = self.run_boot()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        log = self.log.read_text(encoding="utf-8")
        self.assertIn(f"dmesg-ramoops-0.enc.z ({len(payload)} bytes)", log)
        self.assertNotIn("BINARY_ZLIB_MARKER_DO_NOT_TAIL", log)
        self.assertIn("1 surviving", log)
        self.assertTrue(zfile.exists())

    def test_text_tail_sanitizes_control_chars_truncates_long_lines_and_keeps_unterminated_last_line(self):
        self.iomem.write_text("86ff0000-86ffffff : reserved\n", encoding="utf-8")
        self.write_ramoops_params()
        long_line = "A" * 300
        # Includes NUL, ESC, BEL, non-ASCII byte, a 300-char line, and a final
        # line with NO trailing newline.
        raw = (
            b"line1\x00\x1b[31m\x07\x80clean\n"
            + long_line.encode("ascii")
            + b"\nLAST_LINE_NO_NEWLINE"
        )
        cfile = self.pstore / "console-ramoops-0"
        cfile.write_bytes(raw)

        proc = self.run_boot()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        log = self.log.read_text(encoding="utf-8")
        self.assertNotIn("\x00", log)
        self.assertNotIn("\x1b", log)
        self.assertNotIn("\x07", log)
        self.assertIn("line1[31mclean", log)
        self.assertIn("LAST_LINE_NO_NEWLINE", log)
        # Body of each logged tail line must be capped at 240 chars.
        tail_lines = [
            line.split("console-ramoops-0: ", 1)[1]
            for line in log.splitlines()
            if "console-ramoops-0: " in line
        ]
        self.assertTrue(any(len(body) == 240 for body in tail_lines), tail_lines)
        for body in tail_lines:
            self.assertLessEqual(len(body), 240, body)

    def test_bounded_dev_log_wait(self):
        self.iomem.write_text("86ff0000-86ffffff : reserved\n", encoding="utf-8")
        self.write_ramoops_params()
        sleep_log = self.tmp / "sleep.log"
        mock_sleep = self.bin / "sleep"
        mock_sleep.write_text(f'#!/bin/sh\necho "$*" >> "{sleep_log}"\n', encoding="utf-8")
        mock_sleep.chmod(0o755)
        proc = self.run_boot(log_sock=self.tmp / "missing-dev-log", log_wait=2)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(sleep_log.exists(), "boot() did not wait for log socket")
        self.assertEqual(sleep_log.read_text(encoding="utf-8").splitlines(), ["1", "1"])

    def test_iomem_missing_86ff0000_is_not_fooled_by_ramoops_word(self):
        # Even if another line mentions "ramoops", absence of ^86ff0000- must
        # report missing rather than present.
        self.iomem.write_text(
            "80000000-86feffff : System RAM\n"
            "90000000-9000ffff : ramoops\n",
            encoding="utf-8",
        )
        self.write_ramoops_params(console_size="0")
        proc = self.run_boot()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        log = self.log.read_text(encoding="utf-8")
        self.assertIn("iomem_86ff0000=missing", log)
        self.assertIn("console_size=0", log)

    def test_missing_pstore_dir_exits_cleanly(self):
        self.iomem.write_text("86ff0000-86ffffff : reserved\n", encoding="utf-8")
        self.write_ramoops_params()
        proc = self.run_boot(pstore_dir=self.tmp / "nonexistent-pstore")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        log = self.log.read_text(encoding="utf-8")
        self.assertIn("pstore:", log)
        self.assertNotIn("clean boot", log)


if __name__ == "__main__":
    unittest.main()
