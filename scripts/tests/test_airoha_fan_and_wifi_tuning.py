#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The XR1710G fan tachometer check and the 6 GHz radio2 promotion.

Two defects, both observed on the board:

  * ``airoha_fan`` returned quietly whenever ``/etc/init.d/fan`` (the LuCI
    app) was installed, and also whenever the NCT7802 hwmon device was not
    bound yet.  The live board then read ``temp1_input=51 C`` with
    ``fan1_input=0`` while an earlier revision of the same hardware read
    826-830 rpm, and the only thing reacting to a stopped fan was the 120 C
    critical trip.  Nothing in ``logread`` said why.
  * ``51_wireless-tuning`` promoted ``radio2`` to channel 37 / EHT320 and
    ``radio1`` to channel 149 without asking whether that radio has the
    band: a config where ``radio2`` is not a 6 GHz radio (or a phy whose
    band list lacks 37) gets a channel hostapd refuses.

What is asserted, offline and without hardware:

  * ``boot()`` logs the tachometer, ``pwm1`` and ``pwm1_enable`` line, logs a
    missing hwmon once, and leaves the curve alone when the LuCI app is
    installed;
  * the monitor confirms a single ``fan1_input=0`` with a re-read before it
    counts as a stall: with ``FAILSAFE_SAMPLES=1`` and a tach that answers
    0 once and 900 on the re-read, nothing is forced; three confirmed hot
    samples still pin ``pwm1_enable=1`` + ``pwm1=255``, log exactly once per
    stall with ``pwm1``/``pwm1_enable``, and one or two confirmed samples
    write nothing at all;
  * a hot manual ``pwm1=0`` is the stopped fan #380 measured, so the monitor
    forces 255 once, but only after the supervision slot has had its sample;
    a cool manual 0 is still "0 = Off" and left alone;
  * one shot after two samples the monitor re-applies the stock curve when
    the selected mode is not manual and ``pwm1_enable`` is not 2 (or ``pwm1``
    is 0), reads the mode back and logs it; manual mode is never touched, and
    an auto-selected curve that never landed (``pwm1_enable=1``, ``pwm1=0``,
    hot) is healed instead of being misread as a manual zero;
  * both force paths read ``pwm1`` back: a force whose write did not land
    (read-only attributes) logs the mismatch, does not latch the episode,
    and tries again on the next sample;
  * the monitor reports a missing hwmon once, not on every sample;
  * ``51_wireless-tuning`` promotes radio2 only when the section exists, its
    ``band`` is ``6g`` (or unset) and ``iw phy`` lists 6135 MHz; promotes
    radio1 to 149 only on a 5 GHz radio; with ``iw`` absent the UCI band is
    the only evidence and unset still promotes.

Red half: the fixed scripts are read through ``AIROHA_FAN_UNDER_TEST`` and
``WIRELESS_DEFAULTS_UNDER_TEST``.  Run this file against copies with the old
bodies (``git show HEAD:<path> > /tmp/airoha_fan``, then
``AIROHA_FAN_UNDER_TEST=/tmp/airoha_fan``) and it fails on the first
assertion that matters: no ``pwm1`` in the boot log, no
hot manual-zero force, no stock-curve re-apply and read-back (so a hot
``pwm1_enable=1 pwm1=0`` stays manual instead of healing), a lone 0 forced
when ``FAILSAFE_SAMPLES=1``, and radio2 promoted on a 2.4 GHz radio.

Run from the repository root:

    python3 -m unittest scripts.tests.test_airoha_fan_and_wifi_tuning
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
FAN = Path(
    os.environ.get("AIROHA_FAN_UNDER_TEST", REPO_ROOT / "target/linux/airoha/an7581/base-files/etc/init.d/airoha_fan")
).resolve()
TUNING = Path(
    os.environ.get(
        "WIRELESS_DEFAULTS_UNDER_TEST",
        REPO_ROOT / "target/linux/airoha/an7581/base-files/etc/uci-defaults/51_wireless-tuning",
    )
).resolve()

BOARD = "gemtek,xr1710g-ubi"

# Absolute shell path: the wireless harness runs the script with a PATH of its
# own, and resolving "sh" through that PATH would find nothing.
SH = shutil.which("sh") or "/bin/sh"

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

MOCK_UCI_MODE = r'''#!/bin/sh
[ "$1" = "-q" ] && shift
[ "$1" = "get" ] && [ "$2" = "fan.settings.mode" ] || exit 1
cat "$MOCK_FAN_MODE"
'''

# Makes every first read of fan1_input return 0 and the confirmation read
# return 900, so a lone 0 sample is distinguishable from a confirmed stall.
MOCK_CAT = r'''#!/bin/sh
case "$1" in
*/fan1_input)
	n=0
	[ -f "$MOCK_TACH_COUNTER" ] && read -r n < "$MOCK_TACH_COUNTER"
	n=${n:-0}
	n=$((n + 1))
	echo "$n" > "$MOCK_TACH_COUNTER"
	if [ $((n % 2)) -eq 1 ]; then
		echo 0
	else
		echo 900
	fi
	;;
*)
	exec @REAL_CAT@ "$@"
	;;
esac
'''

MOCK_UCI = r'''#!/usr/bin/env python3
import json, sys

state_path = __import__("os").environ["MOCK_UCI_STATE"]


def main(argv):
    if argv[:1] == ["-q"]:
        argv = argv[1:]
    if not argv:
        return 1
    with open(state_path) as handle:
        state = json.load(handle)
    if argv[0] == "get" and len(argv) == 2:
        parts = argv[1].split(".")
        if parts[0] != "wireless" or len(parts) not in (2, 3):
            return 1
        section = state["sections"].get(parts[1])
        if section is None:
            return 1
        if len(parts) == 2:
            print(section["type"])
            return 0
        value = section["options"].get(parts[2])
        if value is None:
            return 1
        print(value)
        return 0
    if argv[0] == "set" and len(argv) == 2:
        target, _, value = argv[1].partition("=")
        parts = target.split(".")
        if len(parts) != 3:
            return 1
        section = state["sections"].setdefault(
            parts[1], {"type": "wifi-device", "options": {}})
        section["options"][parts[2]] = value
        with open(state_path, "w") as handle:
            json.dump(state, handle, indent=1, sort_keys=True)
        return 0
    return 1


sys.exit(main(sys.argv[1:]))
'''

MOCK_IW = r'''#!/bin/sh
[ "$1" = "phy" ] || exit 1
cat "$MOCK_IW_PHY"
'''

LIB_FUNCTIONS = r'''board_name() {
	cat "$BOARD_NAME_FILE"
}
'''

PHY_6G = """\
\tBand 1:
\t\t* 2412 MHz [1]
\tBand 2:
\t\t* 5745 MHz [149]
\tBand 4:
\t\t* 6135 MHz [37] (disabled)
"""

PHY_NO_6G = """\
\tBand 1:
\t\t* 2412 MHz [1]
\tBand 2:
\t\t* 5745 MHz [149]
"""


def write_exec(path, text, mode=0o755):
    path.write_text(text)
    path.chmod(mode)


class FanHarness:
    def __init__(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="airoha-fan."))
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        write_exec(self.bin / "logger", MOCK_LOGGER)
        write_exec(self.bin / "uci", MOCK_UCI_MODE)
        self.log = self.tmp / "logger.log"
        self.log.write_text("")
        self.mode_file = self.tmp / "fan.mode"
        self.tach_counter = self.tmp / "tach.counter"
        self.hwmon_root = self.tmp / "hwmon"
        self.hwmon_root.mkdir()
        self.luci_init = self.tmp / "fan"
        self.script = self.tmp / "airoha_fan"
        self.pidfile = self.tmp / "airoha_fan.pid"
        source = FAN.read_text()
        source = source.replace("/sys/class/hwmon", str(self.hwmon_root))
        source = source.replace("/etc/init.d/fan", str(self.luci_init))
        source = source.replace("/var/run/airoha_fan.pid", str(self.pidfile))
        self.script.write_text(source)

    def add_hwmon(self, temp="51000", fan="0", pwm_enable="2", pwm="54"):
        device = self.hwmon_root / "hwmon0"
        device.mkdir(exist_ok=True)
        (device / "name").write_text("nct7802\n")
        for attr, value in (("temp1_input", temp), ("fan1_input", fan),
                            ("pwm1_enable", pwm_enable), ("pwm1", pwm)):
            (device / attr).write_text(value + "\n")
        for index in range(1, 6):
            (device / ("pwm1_auto_point%d_temp" % index)).write_text("0\n")
            (device / ("pwm1_auto_point%d_pwm" % index)).write_text("0\n")
        return device

    def install_luci(self, body="#!/bin/sh\n"):
        write_exec(self.luci_init, body)

    def set_mode(self, mode):
        self.mode_file.write_text(mode + "\n")

    def set_alternating_tach(self):
        real_cat = shutil.which("cat") or "/bin/cat"
        write_exec(self.bin / "cat", MOCK_CAT.replace("@REAL_CAT@", real_cat))

    def run(self, action, samples=0, failsafe_samples=3, zero_confirm_sleep=0):
        env = dict(os.environ)
        env.update({
            "PATH": "%s:%s" % (self.bin, os.environ.get("PATH", "/usr/bin:/bin")),
            "MOCK_LOGGER_LOG": str(self.log),
            "MOCK_FAN_MODE": str(self.mode_file),
            "MOCK_TACH_COUNTER": str(self.tach_counter),
            "AIROHA_FAN_HWMON_ROOT": str(self.hwmon_root),
            "AIROHA_FAN_LUCI_INIT": str(self.luci_init),
            "AIROHA_FAN_MONITOR_MAX_SAMPLES": str(samples),
            "AIROHA_FAN_FAILSAFE_SAMPLES": str(failsafe_samples),
            "AIROHA_FAN_FAILSAFE_INTERVAL": "0",
            "AIROHA_FAN_FAILSAFE_TEMP": "45000",
            "AIROHA_FAN_ZERO_CONFIRM_SLEEP": str(zero_confirm_sleep),
        })
        program = "board_name() { echo %s; }; . \"%s\"; %s" % (BOARD, self.script, action)
        return subprocess.run(
            ["sh", "-c", program], env=env, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, universal_newlines=True)

    def log_lines(self):
        return [line for line in self.log.read_text().splitlines() if line]

    def cleanup(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


class FanTest(unittest.TestCase):
    def setUp(self):
        self.fan = FanHarness()
        self.addCleanup(self.fan.cleanup)

    def test_boot_logs_tachometer_and_mode(self):
        device = self.fan.add_hwmon(temp="51000", fan="0", pwm_enable="2")
        result = self.fan.run("boot", samples=0)
        self.assertEqual(result.returncode, 0, result.stderr)
        logs = "\n".join(self.fan.log_lines())
        self.assertIn("temp1_input=51000", logs)
        self.assertIn("fan1_input=0", logs)
        self.assertIn("pwm1=54", logs)
        self.assertIn("pwm1_enable=2", logs)
        self.assertEqual((device / "pwm1_enable").read_text().strip(), "2")
        self.assertEqual((device / "pwm1_auto_point1_temp").read_text().strip(),
                         "40000")
        self.assertEqual((device / "pwm1_auto_point4_pwm").read_text().strip(),
                         "199")

    def test_boot_leaves_the_curve_to_the_luci_app(self):
        device = self.fan.add_hwmon(temp="30000", fan="826", pwm_enable="1",
                                    pwm="120")
        self.fan.install_luci()
        result = self.fan.run("boot", samples=0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("fan1_input=826", "\n".join(self.fan.log_lines()))
        self.assertEqual((device / "pwm1_enable").read_text().strip(), "1")
        self.assertEqual((device / "pwm1_auto_point1_temp").read_text().strip(),
                         "0")

    def test_boot_logs_a_missing_hwmon_instead_of_returning_quietly(self):
        result = self.fan.run("boot", samples=0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("nct7802 not found, leaving the fan unmanaged",
                      "\n".join(self.fan.log_lines()))

    def test_monitor_forces_full_pwm_once_when_hot_and_stalled(self):
        device = self.fan.add_hwmon(temp="52000", fan="0", pwm_enable="2",
                                    pwm="54")
        result = self.fan.run("monitor_fan 0", samples=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((device / "pwm1_enable").read_text().strip(), "1")
        self.assertEqual((device / "pwm1").read_text().strip(), "255")
        forcing = [line for line in self.fan.log_lines()
                   if "forcing pwm1=255" in line]
        self.assertEqual(len(forcing), 1, self.fan.log_lines())
        self.assertIn("pwm1_enable=2", forcing[0])
        self.assertIn("pwm1=54", forcing[0])
        self.assertEqual(len(self.fan.log_lines()), 1, "one line per stall")

    def test_monitor_waits_for_several_samples_before_forcing(self):
        # Probe B: one or two confirmed hot samples are not a stall yet.  The
        # once-per-episode test above would stay green if the monitor went
        # back to forcing on the first sample; this one pins the timing.
        device = self.fan.add_hwmon(temp="52000", fan="0", pwm_enable="2",
                                    pwm="54")
        for samples in (1, 2):
            self.fan.run("monitor_fan 0", samples=samples)
            self.assertEqual((device / "pwm1").read_text().strip(), "54",
                             "forced after %d sample(s)" % samples)
            self.assertEqual(self.fan.log_lines(), [],
                             "logged after %d sample(s)" % samples)

    def test_monitor_leaves_a_cool_stalled_fan_alone(self):
        device = self.fan.add_hwmon(temp="30000", fan="0", pwm_enable="2",
                                    pwm="54")
        self.fan.run("monitor_fan 0", samples=10)
        self.assertEqual((device / "pwm1_enable").read_text().strip(), "2")
        self.assertEqual((device / "pwm1").read_text().strip(), "54")
        self.assertEqual(self.fan.log_lines(), [])

    def test_monitor_leaves_a_spinning_fan_alone(self):
        device = self.fan.add_hwmon(temp="52000", fan="826", pwm_enable="2",
                                    pwm="54")
        self.fan.run("monitor_fan 0", samples=10)
        self.assertEqual((device / "pwm1_enable").read_text().strip(), "2")
        self.assertEqual((device / "pwm1").read_text().strip(), "54")
        self.assertEqual(self.fan.log_lines(), [])

    def test_monitor_reports_a_missing_hwmon_once(self):
        self.fan.run("monitor_fan 1", samples=3)
        self.assertEqual(self.fan.log_lines(), [])
        self.fan.run("monitor_fan 0", samples=3)
        self.assertEqual(len(self.fan.log_lines()), 1, self.fan.log_lines())

    def test_monitor_forces_a_hot_manual_zero_once(self):
        # LuCI's manual_pwm=0 ("0 = Off") is a commanded stop at a cool
        # board, but above 45 C a commanded 0 is exactly the stopped fan
        # #380 captured: force 255 once, never once per sample.
        self.fan.set_mode("manual")
        device = self.fan.add_hwmon(temp="46000", fan="0", pwm_enable="1",
                                    pwm="0")
        result = self.fan.run("monitor_fan 0", samples=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((device / "pwm1_enable").read_text().strip(), "1")
        self.assertEqual((device / "pwm1").read_text().strip(), "255")
        forcing = [line for line in self.fan.log_lines()
                   if "manual zero" in line]
        self.assertEqual(len(forcing), 1, self.fan.log_lines())
        self.assertIn("pwm1_enable=1", forcing[0])
        self.assertIn("pwm1=0", forcing[0])
        self.assertIn("forcing pwm1=255", forcing[0])
        self.assertEqual(len(self.fan.log_lines()), 1, self.fan.log_lines())

    def test_monitor_defers_the_manual_zero_force_to_the_second_sample(self):
        # A manual zero on the first sample is also what an auto curve that
        # never landed looks like, and at boot it may be the pre-S99fan
        # transient.  The force waits for the supervision slot, then fires.
        self.fan.set_mode("manual")
        device = self.fan.add_hwmon(temp="46000", fan="0", pwm_enable="1",
                                    pwm="0")
        self.fan.run("monitor_fan 0", samples=1)
        self.assertEqual((device / "pwm1").read_text().strip(), "0",
                         "forced on the first sample")
        self.assertEqual(self.fan.log_lines(), [])
        self.fan.run("monitor_fan 0", samples=2)
        self.assertEqual((device / "pwm1").read_text().strip(), "255")
        self.assertEqual(
            len([line for line in self.fan.log_lines()
                 if "manual zero" in line]), 1, self.fan.log_lines())

    def test_monitor_retries_when_the_force_write_does_not_land(self):
        # Probe D: read-only pwm1_enable/pwm1 turn both echoes into no-ops.
        # The force must neither claim success nor latch the episode: every
        # later sample reports the mismatch and tries again.
        if os.geteuid() == 0:
            self.skipTest("0444 does not stop root from writing")
        self.fan.set_mode("manual")
        device = self.fan.add_hwmon(temp="46000", fan="0", pwm_enable="1",
                                    pwm="0")
        (device / "pwm1_enable").chmod(0o444)
        (device / "pwm1").chmod(0o444)
        result = self.fan.run("monitor_fan 0", samples=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((device / "pwm1").read_text().strip(), "0")
        retried = [line for line in self.fan.log_lines()
                   if "force write did not land" in line]
        self.assertGreaterEqual(len(retried), 2, self.fan.log_lines())
        for line in retried:
            self.assertIn("will retry", line)
            self.assertIn("pwm1=0", line)
        self.assertNotIn("forcing pwm1=255", "\n".join(self.fan.log_lines()))

    def test_monitor_leaves_a_cool_manual_zero_alone(self):
        self.fan.set_mode("manual")
        device = self.fan.add_hwmon(temp="30000", fan="0", pwm_enable="1",
                                    pwm="0")
        self.fan.run("monitor_fan 0", samples=10)
        self.assertEqual((device / "pwm1_enable").read_text().strip(), "1")
        self.assertEqual((device / "pwm1").read_text().strip(), "0")
        self.assertEqual(self.fan.log_lines(), [])

    def test_monitor_reapplies_the_stock_curve_when_auto_never_landed(self):
        # LuCI writes enable=2 at its own S99; if that write did not land the
        # controller stays in manual.  Once the board warms above FAILSAFE_TEMP
        # and after a couple of samples, the monitor re-applies the stock curve
        # (when /etc/init.d/fan is absent) and reads the mode back.
        self.fan.set_mode("auto")
        device = self.fan.add_hwmon(temp="48000", fan="826", pwm_enable="1",
                                    pwm="0")
        result = self.fan.run("monitor_fan 0", samples=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((device / "pwm1_enable").read_text().strip(), "2")
        self.assertEqual((device / "pwm1_auto_point1_temp").read_text().strip(),
                         "40000")
        self.assertEqual((device / "pwm1_auto_point4_pwm").read_text().strip(),
                         "199")
        reapply = [line for line in self.fan.log_lines()
                   if "re-applying the stock curve" in line]
        self.assertEqual(len(reapply), 1, self.fan.log_lines())
        self.assertIn("pwm1_enable=1", reapply[0])
        self.assertIn("pwm1=0", reapply[0])
        readback = [line for line in self.fan.log_lines()
                    if "stock curve re-applied" in line]
        self.assertEqual(len(readback), 1, self.fan.log_lines())
        self.assertIn("pwm1_enable=2", readback[0])

    def test_monitor_preserves_cool_quiet_curve_with_zero_pwm(self):
        # Cold boot or quiet curves legitimately command pwm1=0 below
        # FAILSAFE_TEMP (45 C).  Supervision must wait until temp > FAILSAFE_TEMP
        # so it never clobbers a cool curve with the stock curve.
        self.fan.set_mode("auto")
        device = self.fan.add_hwmon(temp="38000", fan="0", pwm_enable="2",
                                    pwm="0")
        (device / "pwm1_auto_point1_temp").write_text("42000\n")
        result = self.fan.run("monitor_fan 0", samples=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((device / "pwm1_auto_point1_temp").read_text().strip(),
                         "42000", "cool quiet curve was overwritten")
        self.assertEqual((device / "pwm1_enable").read_text().strip(), "2")
        self.assertEqual(self.fan.log_lines(), [])

    def test_monitor_supervision_prefers_luci_fan_reload_before_stock_curve(self):
        # When /etc/init.d/fan is executable, supervision must try its reload
        # first so the user's configured UCI curve wins over the stock curve.
        self.fan.set_mode("auto")
        device = self.fan.add_hwmon(temp="50000", fan="826", pwm_enable="1",
                                    pwm="0")
        reload_log = self.fan.tmp / "luci-reload.log"
        self.fan.install_luci(
            "#!/bin/sh\n"
            f'echo "$1" >> "{reload_log}"\n'
            f'echo 42000 > "{device}/pwm1_auto_point1_temp"\n'
            f'echo 69 > "{device}/pwm1"\n'
            f'echo 2 > "{device}/pwm1_enable"\n'
        )
        result = self.fan.run("monitor_fan 0", samples=4)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(reload_log.exists(), "/etc/init.d/fan reload was not called")
        self.assertEqual(reload_log.read_text().strip(), "reload")
        self.assertEqual((device / "pwm1_enable").read_text().strip(), "2")
        self.assertEqual((device / "pwm1_auto_point1_temp").read_text().strip(),
                         "42000", "stock curve clobbered LuCI curve after successful reload")
        self.assertNotIn("stock curve re-applied", "\n".join(self.fan.log_lines()))

    def test_monitor_supervision_falls_back_to_stock_curve_when_luci_reload_fails(self):
        # If /etc/init.d/fan reload fails or does not restore auto mode,
        # supervision falls back to apply_stock_curve.
        self.fan.set_mode("auto")
        device = self.fan.add_hwmon(temp="50000", fan="826", pwm_enable="1",
                                    pwm="0")
        reload_log = self.fan.tmp / "luci-reload-fail.log"
        self.fan.install_luci(
            "#!/bin/sh\n"
            f'echo "$1" >> "{reload_log}"\n'
            "exit 1\n"
        )
        result = self.fan.run("monitor_fan 0", samples=4)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(reload_log.exists(), "/etc/init.d/fan reload was not called")
        self.assertEqual(reload_log.read_text().strip(), "reload")
        self.assertEqual((device / "pwm1_enable").read_text().strip(), "2")
        self.assertEqual((device / "pwm1_auto_point1_temp").read_text().strip(),
                         "40000")
        self.assertIn("stock curve re-applied", "\n".join(self.fan.log_lines()))

    def test_monitor_applies_stock_curve_on_late_bound_nct7802(self):
        # Minimal image (no /etc/init.d/fan): if nct7802 was absent during
        # boot() (reported_missing=1) and binds later while cool, monitor_fan
        # must apply the stock curve immediately on the first sample it appears
        # instead of leaving the chip unconfigured.
        device = self.fan.add_hwmon(temp="35000", fan="800", pwm_enable="1",
                                    pwm="0")
        result = self.fan.run("monitor_fan 1", samples=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((device / "pwm1_enable").read_text().strip(), "2")
        self.assertEqual((device / "pwm1_auto_point1_temp").read_text().strip(),
                         "40000")
        self.assertEqual((device / "pwm1_auto_point4_pwm").read_text().strip(),
                         "199")

    def test_monitor_late_bind_runs_luci_reload_when_installed(self):
        # With /etc/init.d/fan executable, late-bound nct7802 must invoke
        # `/etc/init.d/fan reload` first (preserving LuCI curve) and mark
        # healed=1 so supervision does not overwrite it on the same sample.
        device = self.fan.add_hwmon(temp="50000", fan="800", pwm_enable="1",
                                    pwm="0")
        reload_log = self.fan.tmp / "late-luci.log"
        self.fan.install_luci(
            "#!/bin/sh\n"
            f'echo "$1" >> "{reload_log}"\n'
            f'echo 43000 > "{device}/pwm1_auto_point1_temp"\n'
            f'echo 60 > "{device}/pwm1"\n'
            f'echo 2 > "{device}/pwm1_enable"\n'
        )
        result = self.fan.run("monitor_fan 1", samples=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(reload_log.exists(), "late-bind did not call /etc/init.d/fan reload")
        self.assertEqual(reload_log.read_text().strip(), "reload")
        self.assertEqual((device / "pwm1_enable").read_text().strip(), "2")
        self.assertEqual((device / "pwm1_auto_point1_temp").read_text().strip(),
                         "43000")

    def test_monitor_late_bind_falls_back_to_stock_when_luci_reload_fails(self):
        device = self.fan.add_hwmon(temp="35000", fan="800", pwm_enable="1",
                                    pwm="0")
        reload_log = self.fan.tmp / "late-luci-fail.log"
        self.fan.install_luci(
            "#!/bin/sh\n"
            f'echo "$1" >> "{reload_log}"\n'
            "exit 1\n"
        )
        result = self.fan.run("monitor_fan 1", samples=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(reload_log.exists(), "late-bind did not try /etc/init.d/fan reload")
        self.assertEqual((device / "pwm1_enable").read_text().strip(), "2")
        self.assertEqual((device / "pwm1_auto_point1_temp").read_text().strip(),
                         "40000")

    def test_monitor_forces_full_pwm_when_hot_auto_stays_zero_pwm_and_zero_rpm(self):
        # Minimal image (no LuCI): if temp > FAILSAFE_TEMP in auto mode and
        # pwm1 stays 0 alongside fan1_input=0 even after supervision, the
        # failsafe must NOT skip the stall check because pwm1=0.
        device = self.fan.add_hwmon(temp="52000", fan="0", pwm_enable="2",
                                    pwm="0")
        result = self.fan.run("monitor_fan 0", samples=6, failsafe_samples=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((device / "pwm1_enable").read_text().strip(), "1")
        self.assertEqual((device / "pwm1").read_text().strip(), "255")
        self.assertIn("forcing pwm1=255", "\n".join(self.fan.log_lines()))

    def test_monitor_heals_a_hot_auto_zero_without_a_manual_force(self):
        # Probe A: the exact #380 shape at boot -- pwm1_enable=1, pwm1=0 and
        # the selected mode is auto.  The first sample cannot tell this from
        # a manual zero, so the force waits; the second sample heals the
        # curve, and no "manual zero" line is ever written.
        self.fan.set_mode("auto")
        device = self.fan.add_hwmon(temp="52000", fan="0", pwm_enable="1",
                                    pwm="0")
        result = self.fan.run("monitor_fan 0", samples=4)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((device / "pwm1_enable").read_text().strip(), "2")
        self.assertEqual((device / "pwm1_auto_point1_temp").read_text().strip(),
                         "40000")
        self.assertEqual((device / "pwm1_auto_point4_pwm").read_text().strip(),
                         "199")
        logs = "\n".join(self.fan.log_lines())
        self.assertIn("stock curve re-applied", logs)
        self.assertNotIn("manual zero", logs)
        self.assertNotIn("forcing pwm1=255", logs)

    def test_monitor_does_not_touch_the_curve_in_manual_mode(self):
        self.fan.set_mode("manual")
        device = self.fan.add_hwmon(temp="30000", fan="900", pwm_enable="1",
                                    pwm="60")
        self.fan.run("monitor_fan 0", samples=10)
        self.assertEqual((device / "pwm1_enable").read_text().strip(), "1")
        self.assertEqual((device / "pwm1").read_text().strip(), "60")
        self.assertEqual(self.fan.log_lines(), [])

    def test_read_tach_confirms_a_lone_zero_with_a_reread(self):
        # fan1_input alternates 0/900 on successive reads: the first read of
        # fan1_input is 0 and the confirmation read is 900, so read_tach must
        # report 900.  A lone 0 sample is not a stall.
        self.fan.set_alternating_tach()
        device = self.fan.add_hwmon(temp="52000", fan="0", pwm_enable="2",
                                    pwm="54")
        result = self.fan.run('read_tach "%s"' % device, samples=0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "900")
        self.assertEqual(result.stderr, "")

    def test_read_tach_keeps_a_confirmed_zero(self):
        self.fan.add_hwmon(temp="52000", fan="0", pwm_enable="2", pwm="54")
        result = self.fan.run('read_tach "%s/hwmon0"' % self.fan.hwmon_root,
                              samples=0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "0")

    def test_monitor_does_not_count_a_lone_zero_as_a_stall(self):
        # The tach answers 0 on the first read and 900 on the confirmation
        # read, so every sample is healthy.  FAILSAFE_SAMPLES=1 makes a
        # single unconfirmed zero enough to force, which is exactly what the
        # pre-fix body does; the fixed monitor sees 900 and touches nothing.
        self.fan.set_alternating_tach()
        device = self.fan.add_hwmon(temp="52000", fan="0", pwm_enable="2",
                                    pwm="54")
        result = self.fan.run("monitor_fan 0", samples=4, failsafe_samples=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((device / "pwm1_enable").read_text().strip(), "2")
        self.assertEqual((device / "pwm1").read_text().strip(), "54")
        self.assertEqual(self.fan.log_lines(), [])

    def test_read_tach_sleeps_between_zero_confirm_reads(self):
        # Without a pause between re-reads, nct7802 returns the same cached 0
        # sample.  read_tach must sleep ZERO_CONFIRM_SLEEP (default 1 s) before
        # each confirmation read.
        self.assertIn("AIROHA_FAN_ZERO_CONFIRM_SLEEP:-1", FAN.read_text())
        sleep_log = self.fan.tmp / "sleep.log"
        write_exec(
            self.fan.bin / "sleep",
            f'#!/bin/sh\necho "$*" >> "{sleep_log}"\n',
        )
        self.fan.add_hwmon(temp="52000", fan="0", pwm_enable="2", pwm="54")
        result = self.fan.run(
            'read_tach "%s/hwmon0"' % self.fan.hwmon_root,
            samples=0,
            zero_confirm_sleep=1,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "0")
        self.assertTrue(sleep_log.exists(), "read_tach did not sleep between zero confirm reads")
        self.assertEqual(sleep_log.read_text().splitlines(), ["1", "1"])

    def test_boot_starts_only_one_monitor(self):
        spawn_log = self.fan.tmp / "spawn.log"
        sleeper = subprocess.Popen(
            ["python3", "-c", "import time; time.sleep(10)", "airoha_fan"]
        )
        self.addCleanup(sleeper.wait)
        self.addCleanup(sleeper.terminate)
        self.fan.pidfile.write_text("%d\n" % sleeper.pid)
        self.fan.add_hwmon()
        result = self.fan.run(
            'monitor_fan() { echo spawned >> "%s"; }; boot; wait' % spawn_log,
            samples=0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(spawn_log.exists(), "a second loop was started")

    def test_boot_restarts_monitor_when_pidfile_reused_by_unrelated_process(self):
        # A live PID whose /proc/<pid>/cmdline is NOT airoha_fan means the
        # kernel recycled the PID after a crash; boot() must start a fresh monitor.
        spawn_log = self.fan.tmp / "spawn.log"
        unrelated = subprocess.Popen(["sleep", "10"])
        self.addCleanup(unrelated.wait)
        self.addCleanup(unrelated.terminate)
        self.fan.pidfile.write_text("%d\n" % unrelated.pid)
        self.fan.add_hwmon()
        result = self.fan.run(
            'monitor_fan() { echo spawned >> "%s"; }; boot; wait' % spawn_log,
            samples=0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(
            spawn_log.exists() and spawn_log.read_text().count("spawned") == 1,
            "boot() treated a recycled unrelated PID as a live airoha_fan monitor",
        )

    def test_boot_restarts_the_monitor_when_the_pidfile_is_stale(self):
        spawn_log = self.fan.tmp / "spawn.log"
        self.fan.pidfile.write_text("999999\n")
        self.fan.add_hwmon()
        result = self.fan.run(
            'monitor_fan() { echo spawned >> "%s"; }; boot; wait' % spawn_log,
            samples=0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(spawn_log.read_text().count("spawned"), 1)

    def test_start_runs_the_boot_path(self):
        self.fan.add_hwmon(temp="30000", fan="826", pwm_enable="2")
        result = self.fan.run("start", samples=0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("fan1_input=826", "\n".join(self.fan.log_lines()))
        self.assertTrue(self.fan.pidfile.exists())

    def test_stop_kills_the_monitor_and_removes_the_pidfile(self):
        action = 'python3 -c "import time; time.sleep(10)" airoha_fan & p=$!; ' \
                 'echo $p > "%s"; stop; wait $p; ' \
                 'echo "rc=$?"; [ -f "%s" ] && echo pidfile=present || ' \
                 'echo pidfile=removed' % (self.fan.pidfile, self.fan.pidfile)
        result = self.fan.run(action, samples=0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("rc=143", result.stdout)  # 128 + SIGTERM
        self.assertIn("pidfile=removed", result.stdout)

    def test_stop_without_a_pidfile_is_a_noop(self):
        result = self.fan.run('stop; echo "rc=$?"', samples=0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("rc=0", result.stdout)

    def test_stop_rejects_zero_negative_and_unrelated_pids(self):
        # A corrupted pidfile containing 0 or -1 must never pass pid_is_monitor
        # (where `kill 0` kills the process group and `kill -1` kills all
        # processes); a live PID belonging to another command must also be
        # spared while the stale pidfile is removed.
        for bad_pid in ("0", "-1", "00", "abc"):
            with self.subTest(bad_pid=bad_pid):
                kill_log = self.fan.tmp / f"kill-{bad_pid}.log"
                self.fan.pidfile.write_text(f"{bad_pid}\n")
                action = (
                    f'kill() {{ echo "$*" >> "{kill_log}"; return 0; }}; '
                    f'if pid_is_monitor "{bad_pid}"; then echo match=yes; else echo match=no; fi; '
                    'stop'
                )
                result = self.fan.run(action, samples=0)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("match=no", result.stdout,
                              f"pid_is_monitor accepted invalid pid {bad_pid!r}")
                self.assertFalse(
                    kill_log.exists(),
                    f"kill was invoked for invalid pid {bad_pid!r}: "
                    f"{kill_log.read_text() if kill_log.exists() else ''}",
                )
                self.assertFalse(self.fan.pidfile.exists())

        unrelated = subprocess.Popen(["sleep", "10"])
        self.addCleanup(unrelated.wait)
        self.addCleanup(unrelated.terminate)
        self.fan.pidfile.write_text(f"{unrelated.pid}\n")
        result = self.fan.run("stop", samples=0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(
            unrelated.poll(),
            "stop() killed an unrelated live process whose PID was in the pidfile",
        )
        self.assertFalse(self.fan.pidfile.exists())


class WirelessHarness:
    def __init__(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="wireless-tuning."))
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.lib = self.tmp / "lib"
        self.lib.mkdir()
        write_exec(self.bin / "uci", MOCK_UCI)
        write_exec(self.bin / "logger", MOCK_LOGGER)
        # PATH is this mock bin and nothing else, so whether `iw` exists is
        # decided here instead of by the machine running the tests: on a host
        # with iw installed (and no phy of its own) phy_has() would answer
        # "channel absent" and the promotion tests would flip.  Only the
        # tools the script really shells out to are linked in (env/python3
        # are for the mock uci's shebang).
        for tool in ("cat", "grep", "env", "python3"):
            host_tool = shutil.which(tool)
            if host_tool:
                (self.bin / tool).symlink_to(host_tool)
        (self.lib / "functions.sh").write_text(LIB_FUNCTIONS)
        self.board = self.tmp / "board"
        self.board.write_text(BOARD + "\n")
        self.state = self.tmp / "uci.json"
        self.log = self.tmp / "logger.log"
        self.log.write_text("")
        self.config = self.tmp / "wireless"
        self.config.write_text("")
        self.script = self.tmp / "51_wireless-tuning"
        source = TUNING.read_text()
        source = source.replace(". /lib/functions.sh",
                                '. "%s/functions.sh"' % self.lib)
        source = source.replace("/etc/config/wireless", str(self.config))
        self.script.write_text(source)

    def add_iw(self, phy_text):
        fixture = self.tmp / "phy.txt"
        fixture.write_text(phy_text)
        write_exec(self.bin / "iw", MOCK_IW)
        self._phy = fixture

    def add_iw_status(self, rc=0, stdout=""):
        write_exec(
            self.bin / "iw",
            f"#!/bin/sh\nprintf '%s' '{stdout}'\nexit {rc}\n",
        )
        self._phy = ""

    def config_sections(self, sections):
        self.state.write_text(json.dumps({"sections": {
            name: {"type": body.get("type", "wifi-device"),
                   "options": dict(body.get("options", {}))}
            for name, body in sections.items()
        }}))

    def run(self):
        env = dict(os.environ)
        env.update({
            "PATH": str(self.bin),
            "MOCK_UCI_STATE": str(self.state),
            "MOCK_LOGGER_LOG": str(self.log),
            "BOARD_NAME_FILE": str(self.board),
            "MOCK_IW_PHY": str(getattr(self, "_phy", "")),
        })
        self.log.write_text("")
        result = subprocess.run(
            [SH, str(self.script)], env=env, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, universal_newlines=True)
        return result

    def options(self, section):
        return json.loads(self.state.read_text())["sections"][section]["options"]

    def log_lines(self):
        return [line for line in self.log.read_text().splitlines() if line]

    def cleanup(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


BASE_SECTIONS = {
    "radio0": {"options": {"channel": "1", "htmode": "EHT20"}},
    "radio1": {"options": {"channel": "36", "htmode": "EHT80"}},
    "radio2": {"options": {"channel": "auto", "htmode": "EHT80"}},
    "default_radio0": {"type": "wifi-iface", "options": {}},
    "default_radio1": {"type": "wifi-iface", "options": {}},
    "default_radio2": {"type": "wifi-iface", "options": {}},
}


def sections(**overrides):
    merged = {name: {"type": body["type"] if "type" in body else "wifi-device",
                     "options": dict(body["options"])}
              for name, body in BASE_SECTIONS.items()}
    for key, value in overrides.items():
        name, option = key.split("__")
        if value is None:
            merged[name]["options"].pop(option, None)
        else:
            merged[name]["options"][option] = value
    return merged


class WirelessTuningTest(unittest.TestCase):
    def setUp(self):
        self.wifi = WirelessHarness()
        self.addCleanup(self.wifi.cleanup)

    def run_tuning(self):
        result = self.wifi.run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")

    def test_radio2_promoted_when_band_is_6g_and_phy_has_37(self):
        self.wifi.add_iw(PHY_6G)
        self.wifi.config_sections(sections(radio2__band="6g"))
        self.run_tuning()
        options = self.wifi.options("radio2")
        self.assertEqual(options["channel"], "37")
        self.assertEqual(options["htmode"], "EHT320")

    def test_radio2_left_alone_when_band_is_not_6g(self):
        self.wifi.add_iw(PHY_6G)
        self.wifi.config_sections(sections(radio2__band="2g"))
        self.run_tuning()
        options = self.wifi.options("radio2")
        self.assertEqual(options["channel"], "auto")
        self.assertEqual(options["htmode"], "EHT80")
        self.assertIn("radio2 has no usable 6 GHz channel 37",
                      "\n".join(self.wifi.log_lines()))

    def test_radio2_left_alone_when_the_phy_lacks_37(self):
        self.wifi.add_iw(PHY_NO_6G)
        self.wifi.config_sections(sections(radio2__channel="auto",
                                           radio2__htmode="EHT80"))
        self.run_tuning()
        options = self.wifi.options("radio2")
        self.assertEqual(options["channel"], "auto")
        self.assertEqual(options["htmode"], "EHT80")

    def test_radio2_promoted_when_iw_is_absent_and_band_unset(self):
        self.wifi.config_sections(sections(radio2__band=None))
        self.run_tuning()
        options = self.wifi.options("radio2")
        self.assertEqual(options["channel"], "37")
        self.assertEqual(options["htmode"], "EHT320")

    def test_radio2_section_missing_is_not_given_a_channel(self):
        config = sections()
        del config["radio2"]
        del config["default_radio2"]
        self.wifi.config_sections(config)
        self.run_tuning()
        options = self.wifi.options("radio2")
        self.assertNotIn("channel", options)
        self.assertNotIn("htmode", options)

    def test_radio1_promoted_to_149_on_a_5g_radio(self):
        self.wifi.add_iw(PHY_6G)
        self.wifi.config_sections(sections(radio1__channel="36",
                                           radio1__band="5g"))
        self.run_tuning()
        self.assertEqual(self.wifi.options("radio1")["channel"], "149")

    def test_radio1_not_promoted_to_149_on_a_2g_radio(self):
        self.wifi.add_iw(PHY_6G)
        self.wifi.config_sections(sections(radio1__channel="36",
                                           radio1__band="2g"))
        self.run_tuning()
        self.assertEqual(self.wifi.options("radio1")["channel"], "36")
        self.assertIn("radio1 has no usable 5 GHz channel 149",
                      "\n".join(self.wifi.log_lines()))

    def test_radio1_promoted_when_iw_is_absent_and_band_unset(self):
        self.wifi.config_sections(sections(radio1__channel="36",
                                           radio1__band=None))
        self.run_tuning()
        self.assertEqual(self.wifi.options("radio1")["channel"], "149")

    def test_radios_promoted_when_iw_phy_exits_nonzero(self):
        # If `iw phy` fails (e.g. nl80211 not ready at S10 boot), phy_has()
        # must return 2 ("iw unavailable") rather than collapsing into grep's
        # exit 1 ("channel absent") and skipping 5/6 GHz tuning permanently.
        self.wifi.add_iw_status(rc=1, stdout="")
        self.wifi.config_sections(sections(radio1__channel="36",
                                           radio1__band="5g",
                                           radio2__band="6g"))
        self.run_tuning()
        self.assertEqual(self.wifi.options("radio1")["channel"], "149")
        self.assertEqual(self.wifi.options("radio2")["channel"], "37")
        self.assertEqual(self.wifi.options("radio2")["htmode"], "EHT320")

    def test_radios_promoted_when_iw_phy_output_is_empty(self):
        # Empty `iw phy` output (rc=0, no wiphy registered yet on first boot)
        # is also inconclusive and must return 2 rather than "channel absent".
        self.wifi.add_iw_status(rc=0, stdout="")
        self.wifi.config_sections(sections(radio1__channel="36",
                                           radio1__band="5g",
                                           radio2__band="6g"))
        self.run_tuning()
        self.assertEqual(self.wifi.options("radio1")["channel"], "149")
        self.assertEqual(self.wifi.options("radio2")["channel"], "37")
        self.assertEqual(self.wifi.options("radio2")["htmode"], "EHT320")


if __name__ == "__main__":
    unittest.main()
