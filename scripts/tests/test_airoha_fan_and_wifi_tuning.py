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

  * ``boot()`` logs the tachometer/mode line, logs a missing hwmon once, and
    leaves the curve alone when the LuCI app is installed;
  * the monitor pins ``pwm1_enable=1`` + ``pwm1=255`` after three hot
    samples with a stalled tach, logs exactly once per stall, and touches
    nothing when the board is cool or the fan is spinning;
  * the monitor reports a missing hwmon once, not on every sample;
  * ``51_wireless-tuning`` promotes radio2 only when the section exists, its
    ``band`` is ``6g`` (or unset) and ``iw phy`` lists 6135 MHz; promotes
    radio1 to 149 only on a 5 GHz radio; with ``iw`` absent the UCI band is
    the only evidence and unset still promotes.

Red half: the fixed scripts are read through ``AIROHA_FAN_UNDER_TEST`` and
``WIRELESS_DEFAULTS_UNDER_TEST``.  Run this file against copies with the old
bodies (``git show HEAD:...``) and it fails on the first assertion that
matters: no hwmon log line, no 0-rpm fail-safe, and radio2 promoted on a
2.4 GHz radio.

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
        self.log = self.tmp / "logger.log"
        self.log.write_text("")
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

    def install_luci(self):
        write_exec(self.luci_init, "#!/bin/sh\n")

    def run(self, action, samples=0):
        env = dict(os.environ)
        env.update({
            "PATH": "%s:%s" % (self.bin, os.environ.get("PATH", "/usr/bin:/bin")),
            "MOCK_LOGGER_LOG": str(self.log),
            "AIROHA_FAN_HWMON_ROOT": str(self.hwmon_root),
            "AIROHA_FAN_LUCI_INIT": str(self.luci_init),
            "AIROHA_FAN_MONITOR_MAX_SAMPLES": str(samples),
            "AIROHA_FAN_FAILSAFE_SAMPLES": "3",
            "AIROHA_FAN_FAILSAFE_INTERVAL": "0",
            "AIROHA_FAN_FAILSAFE_TEMP": "45000",
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
        self.assertEqual(len(self.fan.log_lines()), 1, "one line per stall")

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

    def test_monitor_leaves_a_commanded_zero_pwm_alone(self):
        # LuCI's manual_pwm=0 ("0 = Off") is a commanded stop: a 0 tach above
        # 45 C must not be read as a stall and latched to full PWM.
        device = self.fan.add_hwmon(temp="46000", fan="0", pwm_enable="1",
                                    pwm="0")
        result = self.fan.run("monitor_fan 0", samples=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((device / "pwm1_enable").read_text().strip(), "1")
        self.assertEqual((device / "pwm1").read_text().strip(), "0")
        self.assertEqual(self.fan.log_lines(), [])

    def test_boot_starts_only_one_monitor(self):
        spawn_log = self.fan.tmp / "spawn.log"
        sleeper = subprocess.Popen(["sleep", "10"])
        self.addCleanup(sleeper.wait)
        self.addCleanup(sleeper.terminate)
        self.fan.pidfile.write_text("%d\n" % sleeper.pid)
        self.fan.add_hwmon()
        result = self.fan.run(
            'monitor_fan() { echo spawned >> "%s"; }; boot; wait' % spawn_log,
            samples=0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(spawn_log.exists(), "a second loop was started")

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
        action = 'sleep 10 & p=$!; echo $p > "%s"; stop; wait $p; ' \
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


if __name__ == "__main__":
    unittest.main()
