#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline contract tests for luci-app-airoha-fancontrol /etc/init.d/fan (#380).

Covers the four boot-time failure modes behind issue #380:

  * Boot ordering: ``START=98`` so ``S98fan`` runs before ``S99airoha_fan``
    instead of racing at ``START=99``.
  * Dynamic + bounded-retry hwmon discovery: ``HWMON`` is resolved inside
    ``apply_settings()`` (never frozen at source time) with a bounded retry
    loop so a late-probed NCT7802 still gets programmed without hanging when
    the chip is absent.
  * Empty-curve guard: if the configured preset has missing/empty curve points,
    ``apply_settings()`` refuses to switch ``pwm1_enable`` to ``2`` (auto) and
    logs why.
  * Readback logging: every applied auto or manual configuration reads back
    ``pwm1`` and ``pwm1_enable`` and records
    ``applied mode=... preset=... pwm1=... pwm1_enable=...`` via
    ``logger -t fan``.

Red-green proof:
  * Set ``FAN_INIT_UNDER_TEST`` to the pre-fix ``/etc/init.d/fan`` script to
    reproduce the red run across all four defects.
  * Run with the default path against the fixed script for the green run.

Run from the repository root:

    python3 -m unittest scripts/tests/test_fan_init.py
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

TESTS_DIR = Path(__file__).resolve().parent
if str(TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(TESTS_DIR))

from _cleanup import safe_rmtree  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
FAN_INIT = Path(
    os.environ.get(
        "FAN_INIT_UNDER_TEST",
        REPO_ROOT / "package/luci-app-airoha-fancontrol/root/etc/init.d/fan",
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
printf '%s %s\n' "$tag" "$*" >> "$MOCK_LOGGER_LOG"
"""

MOCK_UCI = r"""#!/usr/bin/env python3
import json, os, sys

with open(os.environ["MOCK_UCI_JSON"]) as fh:
    data = json.load(fh)

argv = sys.argv[1:]
if argv[:1] == ["-q"]:
    argv = argv[1:]
if len(argv) == 2 and argv[0] == "get":
    val = data.get(argv[1])
    if val is not None:
        print(val)
        sys.exit(0)
sys.exit(1)
"""

MOCK_SLEEP = r"""#!/bin/sh
n=0
[ -f "$MOCK_SLEEP_COUNT" ] && read -r n < "$MOCK_SLEEP_COUNT"
n=$((n + 1))
echo "$n" > "$MOCK_SLEEP_COUNT"
if [ -n "${MOCK_LATE_HWMON_AT:-}" ] && [ "$n" -eq "$MOCK_LATE_HWMON_AT" ]; then
	dev="$MOCK_HWMON_ROOT/hwmon0"
	mkdir -p "$dev"
	echo "nct7802" > "$dev/name"
	echo "1" > "$dev/pwm1_enable"
	echo "54" > "$dev/pwm1"
	for i in 1 2 3 4 5; do
		echo "0" > "$dev/pwm1_auto_point${i}_temp"
		echo "0" > "$dev/pwm1_auto_point${i}_pwm"
	done
fi
exit 0
"""

BALANCED_UCI = {
    "fan.settings.mode": "auto",
    "fan.settings.curve_preset": "balanced",
    "fan.settings.manual_pwm": "127",
    "fan.balanced.point1_temp": "40",
    "fan.balanced.point1_pwm": "54",
    "fan.balanced.point2_temp": "50",
    "fan.balanced.point2_pwm": "69",
    "fan.balanced.point3_temp": "60",
    "fan.balanced.point3_pwm": "95",
    "fan.balanced.point4_temp": "70",
    "fan.balanced.point4_pwm": "199",
    "fan.balanced.point5_temp": "80",
    "fan.balanced.point5_pwm": "255",
}


def write_exec(path: Path, text: str) -> None:
    path.write_text(text)
    path.chmod(0o755)


class FanInitHarness:
    def __init__(self) -> None:
        # Prefix matches _cleanup.RECORD_DIR_NAME under /tmp so safe_rmtree
        # owns teardown cleanly with zero raw shutil.rmtree calls.
        self.tmp = Path(
            tempfile.mkdtemp(prefix="fan-init-no-client.run", dir="/tmp")
        )
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        write_exec(self.bin / "logger", MOCK_LOGGER)
        write_exec(self.bin / "uci", MOCK_UCI)
        write_exec(self.bin / "sleep", MOCK_SLEEP)

        self.log = self.tmp / "logger.log"
        self.log.write_text("")
        self.uci_json = self.tmp / "uci.json"
        self.set_uci(BALANCED_UCI)
        self.sleep_count = self.tmp / "sleep.count"
        self.hwmon_root = self.tmp / "hwmon"
        self.hwmon_root.mkdir()

        self.script = self.tmp / "fan"
        source = FAN_INIT.read_text().replace(
            "/sys/class/hwmon", str(self.hwmon_root)
        )
        self.script.write_text(source)

    def cleanup(self) -> None:
        safe_rmtree(self.tmp)

    def set_uci(self, mapping: dict[str, str]) -> None:
        self.uci_json.write_text(json.dumps(mapping))

    def add_hwmon(self, pwm_enable: str = "1", pwm: str = "54") -> Path:
        dev = self.hwmon_root / "hwmon0"
        dev.mkdir(exist_ok=True)
        (dev / "name").write_text("nct7802\n")
        (dev / "pwm1_enable").write_text(pwm_enable + "\n")
        (dev / "pwm1").write_text(pwm + "\n")
        for i in range(1, 6):
            (dev / f"pwm1_auto_point{i}_temp").write_text("0\n")
            (dev / f"pwm1_auto_point{i}_pwm").write_text("0\n")
        return dev

    def run_shell(
        self, snippet: str, extra_env: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess:
        env = dict(os.environ)
        env.update(
            {
                "PATH": f"{self.bin}:{os.environ.get('PATH', '/usr/bin:/bin')}",
                "MOCK_LOGGER_LOG": str(self.log),
                "MOCK_UCI_JSON": str(self.uci_json),
                "MOCK_SLEEP_COUNT": str(self.sleep_count),
                "MOCK_HWMON_ROOT": str(self.hwmon_root),
            }
        )
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [SH, "-c", snippet],
            env=env,
            text=True,
            capture_output=True,
        )

    def logs(self) -> list[str]:
        return [line for line in self.log.read_text().splitlines() if line]


class FanInitTest(unittest.TestCase):
    def setUp(self) -> None:
        self.h = FanInitHarness()
        self.addCleanup(self.h.cleanup)

    def test_start_priority_is_98(self) -> None:
        text = FAN_INIT.read_text()
        self.assertRegex(
            text,
            r"(?m)^START=98$",
            "fan init script must declare START=98 to run before S99airoha_fan",
        )

    def test_hwmon_resolved_inside_apply_settings_not_source_time(self) -> None:
        # Source the init script BEFORE hwmon0 exists, then bind hwmon0 and
        # invoke apply_settings: source-time HWMON caching fails here.
        snippet = f"""
        . "{self.h.script}"
        dev="{self.h.hwmon_root}/hwmon0"
        mkdir -p "$dev"
        echo nct7802 > "$dev/name"
        echo 1 > "$dev/pwm1_enable"
        echo 54 > "$dev/pwm1"
        for i in 1 2 3 4 5; do
            echo 0 > "$dev/pwm1_auto_point${{i}}_temp"
            echo 0 > "$dev/pwm1_auto_point${{i}}_pwm"
        done
        start_service
        """
        proc = self.h.run_shell(snippet)
        self.assertEqual(proc.returncode, 0, proc.stderr + "\n".join(self.h.logs()))
        dev = self.h.hwmon_root / "hwmon0"
        self.assertEqual((dev / "pwm1_enable").read_text().strip(), "2")
        self.assertEqual((dev / "pwm1_auto_point1_temp").read_text().strip(), "40000")
        self.assertEqual((dev / "pwm1_auto_point4_pwm").read_text().strip(), "199")

    def test_late_hwmon_binding_succeeds_within_bounded_retry(self) -> None:
        # hwmon0 appears only on the second retry sleep inside apply_settings().
        proc = self.h.run_shell(
            f'. "{self.h.script}" && start_service',
            extra_env={"MOCK_LATE_HWMON_AT": "2"},
        )
        self.assertEqual(proc.returncode, 0, proc.stderr + "\n".join(self.h.logs()))
        dev = self.h.hwmon_root / "hwmon0"
        self.assertTrue(dev.is_dir(), "mock late hwmon0 was never triggered by retries")
        self.assertEqual((dev / "pwm1_enable").read_text().strip(), "2")
        self.assertEqual((dev / "pwm1_auto_point5_temp").read_text().strip(), "80000")
        sleeps = int(self.h.sleep_count.read_text().strip())
        self.assertEqual(sleeps, 2)

    def test_missing_hwmon_gives_up_after_bounded_retries(self) -> None:
        proc = self.h.run_shell(f'. "{self.h.script}" && start_service')
        self.assertNotEqual(proc.returncode, 0)
        self.assertTrue(
            any("nct7802 not found" in line for line in self.h.logs()),
            self.h.logs(),
        )
        self.assertTrue(self.h.sleep_count.exists(), "expected bounded retries")
        sleeps = int(self.h.sleep_count.read_text().strip())
        self.assertGreaterEqual(sleeps, 1)
        self.assertLessEqual(sleeps, 10)

    def test_empty_curve_guard_refuses_auto_mode(self) -> None:
        dev = self.h.add_hwmon(pwm_enable="1", pwm="127")
        self.h.set_uci(
            {
                "fan.settings.mode": "auto",
                "fan.settings.curve_preset": "balanced",
            }
        )
        proc = self.h.run_shell(f'. "{self.h.script}" && start_service')
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(
            (dev / "pwm1_enable").read_text().strip(),
            "1",
            "must not switch pwm1_enable=2 when curve points are empty",
        )
        self.assertTrue(self.h.logs(), "expected warning log when curve is empty")

    def test_readback_logging_auto_and_manual(self) -> None:
        dev = self.h.add_hwmon(pwm_enable="1", pwm="69")
        proc = self.h.run_shell(f'. "{self.h.script}" && start_service')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        auto_logs = self.h.logs()
        self.assertTrue(
            any(
                re.search(
                    r"^fan applied mode=auto preset=balanced pwm1=69 pwm1_enable=2$",
                    line,
                )
                for line in auto_logs
            ),
            f"missing auto readback log in {auto_logs}",
        )

        self.h.log.write_text("")
        self.h.set_uci(
            {
                "fan.settings.mode": "manual",
                "fan.settings.curve_preset": "balanced",
                "fan.settings.manual_pwm": "180",
            }
        )
        proc = self.h.run_shell(f'. "{self.h.script}" && reload_service')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual((dev / "pwm1_enable").read_text().strip(), "1")
        self.assertEqual((dev / "pwm1").read_text().strip(), "180")
        manual_logs = self.h.logs()
        self.assertTrue(
            any(
                re.search(
                    r"^fan applied mode=manual preset=balanced pwm1=180 pwm1_enable=1$",
                    line,
                )
                for line in manual_logs
            ),
            f"missing manual readback log in {manual_logs}",
        )

    def test_leading_zero_curve_temp_rejected(self) -> None:
        dev = self.h.add_hwmon(pwm_enable="1", pwm="127")
        bad = dict(BALANCED_UCI)
        bad["fan.balanced.point1_temp"] = "08"
        self.h.set_uci(bad)
        proc = self.h.run_shell(f'. "{self.h.script}" && start_service')
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(
            (dev / "pwm1_enable").read_text().strip(),
            "1",
            "leading-zero '08' temp must be rejected before switching to auto",
        )
        self.assertEqual(proc.stderr, "")
        self.assertTrue(self.h.logs(), "expected warning log for leading-zero temp")

    def test_invalid_manual_pwm_refuses_manual_mode(self) -> None:
        for bad_pwm in ("08", "256", "abc", ""):
            with self.subTest(manual_pwm=bad_pwm):
                dev = self.h.add_hwmon(pwm_enable="2", pwm="69")
                self.h.log.write_text("")
                cfg = {
                    "fan.settings.mode": "manual",
                    "fan.settings.curve_preset": "balanced",
                }
                if bad_pwm:
                    cfg["fan.settings.manual_pwm"] = bad_pwm
                self.h.set_uci(cfg)
                proc = self.h.run_shell(f'. "{self.h.script}" && start_service')
                self.assertNotEqual(proc.returncode, 0)
                self.assertEqual(
                    (dev / "pwm1_enable").read_text().strip(),
                    "2",
                    f"invalid manual_pwm={bad_pwm!r} must not clobber pwm1_enable",
                )
                self.assertEqual((dev / "pwm1").read_text().strip(), "69")
                self.assertTrue(self.h.logs())


if __name__ == "__main__":
    unittest.main()
