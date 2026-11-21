#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Verdict tests for scripts/wireless/mlo-3link.sh (issue #89).

The harness decides whether a 3-link MLO negative test passed.  Four verdicts
used to be printed without being decided, so a run that proved nothing could
still end as traffic-ok:

  1. a ping burst with 90% packet loss counted as traffic.  The bound is now
     TRAFFIC_MAX_LOSS and lives in traffic_loss_ok();
  2. per-link counters that read 0 byte still counted as traffic.  They are
     not: classify_result() drops traffic-ok when PER_LINK_NOBYTES is set,
     and per_link_deltas() returns 2;
  3. a station dump with no per-link data walked on into the traffic window
     because the gate rejected only 1 and 2 links.  0 links is a refusal now
     (station_gate() -> exit 4, RESULT=station-no-perlink);
  4. a 6 GHz band whose wifi-device is enabled but whose only wifi-iface is
     disabled was accepted as a usable link.  radio_off_reason() names the
     wifi-iface, because that is what has to be enabled.

The functions under test are copied out of the script, not re-implemented, so
a change in the script is exercised.  Run from the repository root:

    python3 scripts/tests/test_mlo_3link_verdicts.py
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts/wireless/mlo-3link.sh"

# Minimal uci stub: the store is flat key=value lines; `show wireless` turns
# wireless.<sec>.type=wifi-<kind> into the "wireless.<sec>=wifi-<kind>" line
# list_sections() greps.
UCI_STUB = """#!/bin/sh
store=$UCI_STORE
[ "$1" = "-q" ] && shift
[ "$1" = "-c" ] && shift 2
cmd=$1
shift || true
case "$cmd" in
get)
	val=$(grep -F -- "$1=" "$store" | tail -n 1 | cut -d= -f2-)
	[ -n "$val" ] || exit 1
	printf '%s\\n' "$val"
	;;
show)
	# only "show wireless" is used
	sed -n 's/^\\(wireless\\.[^.]*\\)\\.type=\\(wifi-[a-z]*\\)$/\\1=\\2/p' "$store"
	;;
*)
	exit 1
	;;
esac
"""

STATION_DUMP = """Station aa:bb:cc:dd:ee:ff (on phy0.2-ap0)
\tLink 0:
\t\ttx_bytes: %d
\t\trx_bytes: %d
"""


def extract_function(name):
    """Copy one top-level shell function out of the script."""
    lines = SCRIPT.read_text().splitlines()
    start = lines.index(f"{name}() {{")
    for end in range(start + 1, len(lines)):
        if lines[end] == "}":
            return "\n".join(lines[start:end + 1]) + "\n"
    raise AssertionError(f"{name}() is not closed")


def functions(*names):
    return "\n".join(extract_function(name) for name in names)


def run_sh(body, env=None):
    full_env = {"PATH": os.environ["PATH"]}
    if env:
        full_env.update(env)
    return subprocess.run(
        ["sh", "-c", body], capture_output=True, text=True, env=full_env,
        check=False,
    )


class TrafficLossTest(unittest.TestCase):
    """Leak 1: a 90%-loss burst is not traffic."""

    def setUp(self):
        self.body = functions("traffic_loss_ok")

    def verdict(self, rc, loss, rx):
        body = ("TRAFFIC_MAX_LOSS=10\n" + self.body +
                "traffic_loss_ok %s %s %s\n" % (rc, loss, rx))
        return run_sh(body).returncode

    def test_ninety_percent_loss_is_not_a_pass(self):
        self.assertNotEqual(self.verdict(0, 90, 1), 0)

    def test_ten_percent_loss_is_a_pass(self):
        self.assertEqual(self.verdict(0, 10, 10), 0)

    def test_zero_received_packets_is_not_a_pass(self):
        self.assertNotEqual(self.verdict(0, 0, 0), 0)

    def test_a_failed_command_is_not_a_pass(self):
        self.assertNotEqual(self.verdict(1, 0, 10), 0)


class PerLinkCountersTest(unittest.TestCase):
    """Leak 2: counters that moved no byte are not traffic."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="mlo-deltas-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.body = functions("station_fields", "per_link_deltas")
        self.env = {"STATION": "aa:bb:cc:dd:ee:ff", "STATE_DIR": str(self.tmp)}

    def deltas(self, before, after, secs=2):
        first = self.tmp / "before.txt"
        second = self.tmp / "after.txt"
        first.write_text(before)
        second.write_text(after)
        result = run_sh(self.body + 'per_link_deltas "%s" "%s" %d\n'
                        % (first, second, secs), env=self.env)
        return result

    def test_unchanged_counters_report_no_data(self):
        dump = STATION_DUMP % (1000, 500)
        result = self.deltas(dump, dump)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("0.00 Mbit/s", result.stdout)

    def test_moving_counters_report_a_rate(self):
        result = self.deltas(STATION_DUMP % (1000, 500),
                             STATION_DUMP % (1000 + 250000, 500 + 250000))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("link 0 over 2s", result.stdout)


class StationGateTest(unittest.TestCase):
    """Leak 3: a dump with zero per-link entries is a refusal."""

    def setUp(self):
        self.body = functions("station_gate")

    def gate(self, links):
        result = run_sh(self.body +
                        'STATION=aa:bb:cc:dd:ee:ff\nSTATION_LINKS=%s\n'
                        "station_gate\n"
                        'printf "rc=%%s result=%%s\\n" "$?" "$RESULT"\n' % links)
        return result

    def test_zero_links_refuses(self):
        result = self.gate(0)
        self.assertIn("rc=4 result=station-no-perlink", result.stdout)

    def test_two_links_refuses(self):
        result = self.gate(2)
        self.assertIn("rc=4 result=station-not-3link", result.stdout)

    def test_three_links_pass(self):
        result = self.gate(3)
        self.assertIn("rc=0 result=", result.stdout)


class ClassifyResultTest(unittest.TestCase):
    """Leak 2, second half: a traffic-ok is withdrawn."""

    def setUp(self):
        self.body = functions("classify_result")
        self.stubs = """find_mld() { printf '%s\\n' mld0; }
link_count() { printf '3\\n'; }
station_present() { return 0; }
"""

    def classify(self, **globals_):
        lines = ["%s=%s" % (key, value) for key, value in globals_.items()]
        body = (self.stubs + self.body + "\n".join(lines) + "\n"
                "classify_result\n"
                'printf "result=%s stop=%s\\n" "$RESULT" "$STOP"\n')
        return run_sh(body)

    def test_traffic_ok_is_withdrawn_when_no_byte_moved(self):
        result = self.classify(
            TRAFFIC_OK=1, PER_LINK_NOBYTES=1, TRAFFIC_TIMEOUT=0,
            TRAFFIC_TOOL="ping", TRAFFIC_LOSS=10, STATION="aa:bb:cc:dd:ee:ff",
        )
        # With the AP still holding 3 links and the station still associated,
        # zero per-link bytes is the black-hole signature, not a pass.
        self.assertNotIn("result=traffic-ok", result.stdout)
        self.assertIn("result=blackhole", result.stdout)

    def test_traffic_ok_survives_when_counters_moved(self):
        result = self.classify(
            TRAFFIC_OK=1, PER_LINK_NOBYTES=0, TRAFFIC_TIMEOUT=0,
            TRAFFIC_TOOL="ping", TRAFFIC_LOSS=10, STATION="aa:bb:cc:dd:ee:ff",
        )
        self.assertIn("result=traffic-ok", result.stdout)


class RadioOffReasonTest(unittest.TestCase):
    """Leak 4: a disabled VAP is not a disabled wifi-device."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="mlo-uci-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        stub = bin_dir / "uci"
        stub.write_text(UCI_STUB)
        stub.chmod(0o755)
        self.store = self.tmp / "store"
        self.env = {
            "PATH": "%s:%s" % (bin_dir, os.environ["PATH"]),
            "UCI_STORE": str(self.store),
            "CFG_DIR": str(self.tmp),
        }
        self.body = functions("uci_get", "list_sections", "radio_band",
                              "radio_is_disabled", "radio_off_reason")

    def set_uci(self, lines):
        self.store.write_text("\n".join(lines) + "\n")

    def reason(self, section, band):
        body = (self.body +
                'radio_off_reason %s %s\n' % (section, band) +
                'printf "rc=%s\\n" "$?"\n')
        return run_sh(body, env=self.env).stdout

    def test_a_band_whose_vaps_are_all_disabled_names_the_vap(self):
        self.set_uci([
            "wireless.radio2.type=wifi-device",
            "wireless.radio2.band=6g",
            "wireless.radio2.disabled=0",
            "wireless.default_radio2.type=wifi-iface",
            "wireless.default_radio2.device=radio2",
            "wireless.default_radio2.disabled=1",
        ])
        out = self.reason("radio2", "6g")
        self.assertIn("wifi-iface", out)
        self.assertNotIn("wireless.radio2 (6g) is disabled", out)
        self.assertIn("wireless.default_radio2.disabled=0", out)
        self.assertIn("rc=0", out)

    def test_a_band_with_one_enabled_vap_is_usable(self):
        self.set_uci([
            "wireless.radio1.type=wifi-device",
            "wireless.radio1.band=5g",
            "wireless.radio1.disabled=0",
            "wireless.ap5.type=wifi-iface",
            "wireless.ap5.device=radio1",
            "wireless.ap5.disabled=0",
            "wireless.sta5.type=wifi-iface",
            "wireless.sta5.device=radio1",
            "wireless.sta5.disabled=1",
        ])
        out = self.reason("radio1", "5g")
        self.assertIn("rc=1", out)

    def test_a_disabled_wifi_device_is_still_named(self):
        self.set_uci([
            "wireless.radio0.type=wifi-device",
            "wireless.radio0.band=2g",
            "wireless.radio0.disabled=1",
        ])
        out = self.reason("radio0", "2.4")
        self.assertIn("wireless.radio0 (2.4) is disabled", out)


if __name__ == "__main__":
    unittest.main()
