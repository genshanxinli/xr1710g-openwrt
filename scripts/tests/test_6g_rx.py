#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline tests for scripts/wireless/6g-rx.sh (issue #48).

The harness is exercised three ways, none of them needs a radio:

  * No 6G station on the board: a clean SKIP (rc=0, a "SKIP:" line), and the
    missing iperf3 does not surface at all.  The old preflight checked iperf3
    before it looked for a station, so such a board exited 1 with "required
    command not found: iperf3".
  * A station but no iperf3 on the host: the run has nothing to send with, so
    it is a clean SKIP that says so, not a fatal error.  Before the fix the
    same required-command loop died here.
  * mt76 band_bytes is optional in the kernel.  When the debugfs tree has no
    band_bytes, the per-band A-MPDU measurement is UNKNOWN and the run is
    PARTIAL: result.json says "band_bytes_unavailable": true, status is
    "partial", and the exit code is 3.  An optional counter must not turn a
    real measurement into "unknown", and it must not exit 0 either.
  * The verdict decides the exit code.  A positive station RX delta with an
    undetermined IRQ attribution, or a zero A-MPDU byte delta, is invalid: no
    result that could not be attributed may exit 0.
  * The direction is not inverted.  The listen arm keeps the AP as the
    iperf3 server and prints a STA client command with no -R; the reverse
    arm runs "iperf3 -c <sta-ip> -R" on the AP.

Fake iw/ethtool/iperf3 executables and a throw-away DEBUGFS tree stand in
for the device; nothing here touches /sys, /etc/config or the network.

Run from the repository root:

    python3 scripts/tests/test_6g_rx.py
"""

import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
# SIXG_RX_UNDER_TEST points the tests at another copy of the script so a red
# proof can run them against the pre-fix version (repo convention).
SCRIPT = Path(
    os.environ.get("SIXG_RX_UNDER_TEST") or REPO_ROOT / "scripts/wireless/6g-rx.sh"
)
IFACE = "phy1-ap0"
STA_MAC = "aa:bb:cc:dd:ee:ff"
AP_IP = "192.0.2.1"  # TEST-NET-1, never routed
STA_IP = "198.51.100.7"  # TEST-NET-2, never routed
# The harness is invoked with this interpreter directly, because the
# missing-iperf3 case runs it with a PATH that holds no host tools at all.
SH = shutil.which("sh") or "/bin/sh"

# Fake iw: one 6 GHz AP whose station dump grows by 1000 rx bytes per call,
# so the before/after snapshots always differ.
IW_MOCK = """#!/bin/sh
if [ "$1" = dev ] && [ "$2" = "$IFACE" ] && [ "$3" = station ] && [ "$4" = dump ]; then
	_n=$(cat "$IW_COUNTER" 2>/dev/null || printf 0)
	_n=$((_n + 1))
	printf '%s\\n' "$_n" >"$IW_COUNTER"
	printf 'Station %s (on %s)\\n' "$STA_MAC" "$IFACE"
	printf '\\tinactive time:\\t100 ms\\n'
	printf '\\ttx bytes:\\t%d\\n' "$((_n * 100))"
	printf '\\trx bytes:\\t%d\\n' "$((_n * 1000))"
	printf '\\trx packets:\\t%d\\n' "$((_n * 10))"
	printf '\\tsignal:\\t-52 [-55, -58] dBm\\n'
	printf '\\trx bitrate:\\t5762.5 MBit/s 320MHz 2SS MCS 13\\n'
	printf '\\ttx bitrate:\\t5762.5 MBit/s 320MHz 2SS MCS 13\\n'
	printf '\\tconnected time:\\t%d seconds\\n' "$((_n * 10))"
	exit 0
fi
if [ "$1" = dev ]; then
	printf 'phy#1\\n'
	printf '\\tInterface %s\\n' "$IFACE"
	printf '\\tifindex 12\\n'
	printf '\\twdev 0x1\\n'
	printf '\\taddr 02:00:00:00:00:01\\n'
	printf '\\tssid 6g-test\\n'
	printf '\\ttype AP\\n'
	printf '\\tchannel 37 (6115 MHz), width: 320 MHz, center1: 6105 MHz\\n'
	exit 0
fi
exit 0
"""

# Fake ethtool: the A-MPDU byte counter climbs by 1000 per call, so the
# required ethtool delta is never empty.
ETHTOOL_MOCK = """#!/bin/sh
if [ "$1" = -S ] && [ -n "${ETHTOOL_STATIC:-}" ]; then
	# A counter that does not move: the A-MPDU delta is +0, which used to
	# pass the presence-only gate.
	printf 'rx_ampdu_bytes_cnt: 4000\n'
	printf 'rx_ampdu_cnt: 40\n'
	printf 'rx_mpdu_cnt: 400\n'
	printf 'rx_ba_cnt: 8\n'
	exit 0
fi
if [ "$1" = -S ]; then
	_n=$(cat "$ETHTOOL_COUNTER" 2>/dev/null || printf 0)
	_n=$((_n + 1))
	printf '%s\\n' "$_n" >"$ETHTOOL_COUNTER"
	printf 'rx_ampdu_bytes_cnt: %d\\n' "$((_n * 1000))"
	printf 'rx_ampdu_cnt: %d\\n' "$((_n * 10))"
	printf 'rx_mpdu_cnt: %d\\n' "$((_n * 100))"
	printf 'rx_ba_cnt: %d\\n' "$((_n * 2))"
	exit 0
fi
exit 0
"""

# Fake iperf3: write one valid JSON result and exit.  The listen arm starts
# "iperf3 -s -1" and treats an already-exited server that left JSON as a
# connected source, so the run finishes without a real STA; the reverse arm
# sees the client exit 0.  No direction state is invented here: the harness
# records the commands it ran.
IPERF3_MOCK = """#!/bin/sh
printf '{"end":{"sum_received":{"start":0,"seconds":1.0001,"bytes":125000,'
printf '"bits_per_second":999999.9,"retransmits":0},'
printf '"sum_sent":{"bits_per_second":1000000.0,"retransmits":0}}}\\n'
exit 0
"""

INTERRUPTS = """           CPU0       CPU1
  30:       10       10     PCIe0 status
  31:        5        5     hif2 status
"""

BAND_BYTES = """Phy band 0
rx_ampdu_bytes: 100
Phy band 2
rx_ampdu_bytes: 5000
"""

# A cat that grows the PCIe0 counter on every read of the interrupts file.
# The harness reads it before and after the source, so a static file could
# only ever produce two equal snapshots - and an IRQ delta of zero means the
# verdict is undetermined, not PCIe0.  Every other file goes to the real cat.
CAT_TICK = """#!/bin/sh
if [ "$1" = "${PROC_INTERRUPTS:-}" ]; then
	_n=$(${REAL_CAT:?} "$INTERRUPTS_COUNTER" 2>/dev/null || printf 0)
	_n=$((_n + 1))
	printf '%s\\n' "$_n" >"$INTERRUPTS_COUNTER"
	printf '           CPU0       CPU1\\n'
	printf '  30:  %8d %8d     PCIe0 status\\n' "$((10 * _n))" "$((10 * _n))"
	printf '  31:         5         5     hif2 status\\n'
	exit 0
fi
exec "${REAL_CAT:?}" "$@"
"""

# Host tools the harness and the guard library need in a PATH that holds
# only this test's bin directory (used for the missing-iperf3 case, where
# the host's own iperf3 must stay out of reach).
HOST_TOOLS = (
    "awk",
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
    "ss",
    "tr",
    "wc",
)

def make_path(root):
    """A PATH with the text tools and a stub iw that sees no BSS.

    This is the no-station case: every command the discovery path needs is
    present, iperf3 and ethtool are not, and iw reports nothing.
    """
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



class HarnessTest(unittest.TestCase):
    """Runs the real script against fake tools in a throw-away tree."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="6g-rx-test."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.isolated_bin = self.tmp / "bin-no-iperf3"
        self.isolated_bin.mkdir()
        self.debugfs = self.tmp / "debugfs"
        (self.debugfs / "ieee80211" / "phy1" / "mt76").mkdir(parents=True)
        self.interrupts = self.tmp / "interrupts"
        self.interrupts.write_text(INTERRUPTS)
        self.out = self.tmp / "out"
        self.iw_counter = self.tmp / "iw.counter"
        self.ethtool_counter = self.tmp / "ethtool.counter"
        for where in (self.bin, self.isolated_bin):
            self.write_mock(where, "iw", IW_MOCK)
            self.write_mock(where, "ethtool", ETHTOOL_MOCK)
            for name in HOST_TOOLS:
                src = shutil.which(name)
                if src is not None:
                    (where / name).symlink_to(src)
        self.write_mock(self.bin, "iperf3", IPERF3_MOCK)
        # Replace the cat symlink: a static interrupts file can never show an
        # IRQ delta, and the verdict needs one to be attributable.
        cat_mock = self.bin / "cat"
        cat_mock.unlink()
        self.interrupts_counter = self.tmp / "interrupts.counter"
        self.write_mock(self.bin, "cat", CAT_TICK)
        # isolated_bin holds the same tools but no iperf3: a PATH on which
        # "command -v iperf3" must fail.

    def write_mock(self, where, name, body):
        path = where / name
        path.write_text(body)
        path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    def write_band_bytes(self):
        path = self.debugfs / "ieee80211" / "phy1" / "mt76" / "band_bytes"
        path.write_text(BAND_BYTES)
        return path

    def env(self, isolated=False):
        env = os.environ.copy()
        env.update(
            {
                "PATH": str(self.isolated_bin if isolated else self.bin),
                # Values the mocks print; the harness selects them by name.
                "IFACE": IFACE,
                "STA_MAC": STA_MAC,
                "IW_COUNTER": str(self.iw_counter),
                "ETHTOOL_COUNTER": str(self.ethtool_counter),
                "DEBUGFS": str(self.debugfs),
                "PROC_INTERRUPTS": str(self.interrupts),
                "INTERRUPTS_COUNTER": str(self.interrupts_counter),
                "REAL_CAT": shutil.which("cat") or "/bin/cat",
                # netwatchdog is not part of this test.
                "NWD_ALLOW_NO_SERVICE": "1",
                "NW_GUARD_HOLD_FILE": str(self.tmp / "netwatchdog.hold"),
            }
        )
        return env

    def run_harness(self, *args, isolated=False):
        return subprocess.run(
            [SH, str(SCRIPT), *map(str, args)],
            env=self.env(isolated=isolated),
            capture_output=True,
            text=True,
            timeout=180,
        )

    def common_args(self):
        return [
            "--iface", IFACE,
            "--sta", STA_MAC,
            "--ap-ip", AP_IP,
            "--baseline", "0",
            "--seconds", "1",
            "--parallel", "1",
            "--source-wait", "0",
            "--out", self.out,
        ]

    def result_json(self):
        return json.loads((self.out / "result.json").read_text())

    def test_missing_iperf3_is_a_clean_skip(self):
        res = self.run_harness(*self.common_args(), isolated=True)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn("SKIP", res.stdout)
        self.assertIn("iperf3", res.stdout)

    def test_help_documents_the_partial_exit_code(self):
        # --help is what an operator reads before a run: it must state the
        # partial contract (optional band_bytes -> exit 3), not the old
        # "a counter the kernel does not expose" -> exit 1 text.
        res = self.run_harness("--help")
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn("3 the measurement ran and the verdict", res.stdout)
        self.assertIn('band_bytes counter is absent (status\n"partial")', res.stdout)
        self.assertIn("undetermined", res.stdout)
        self.assertNotIn("a counter the kernel does not expose", res.stdout)

    def test_absent_band_bytes_is_partial_and_keeps_the_verdict(self):
        # band_bytes is optional: its absence makes the run partial (rc 3)
        # instead of poisoning the real RX-delta verdict into "unknown".
        res = self.run_harness(*self.common_args())
        self.assertEqual(res.returncode, 3, res.stdout + res.stderr)
        self.assertIn("PARTIAL", res.stderr)
        self.assertNotIn("status=ok", res.stdout)
        result = self.result_json()
        self.assertIs(result["band_bytes_unavailable"], True)
        self.assertIs(result["ok"], False)
        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["counters"]["band_ampdu_status"], "UNKNOWN")
        self.assertEqual(result["exit_rc"], 3)
        self.assertEqual(result["verdict"], "PCIe0")

    def test_undetermined_verdict_is_invalid_not_ok(self):
        # A positive RX delta with no attributable IRQ group is not a
        # measurement.  This run uses the static interrupts fixture, so the
        # IRQ delta is zero and the verdict is undetermined.
        static_cat = self.tmp / "bin-static"
        static_cat.mkdir()
        for name in HOST_TOOLS:
            src = shutil.which(name)
            if src is not None:
                (static_cat / name).symlink_to(src)
        for name, body in (("iw", IW_MOCK), ("ethtool", ETHTOOL_MOCK)):
            self.write_mock(static_cat, name, body)
        self.write_mock(static_cat, "iperf3", IPERF3_MOCK)
        self.write_band_bytes()
        env = self.env()
        env["PATH"] = str(static_cat)
        res = subprocess.run(
            [SH, str(SCRIPT), *map(str, self.common_args())],
            env=env,
            capture_output=True,
            text=True,
            timeout=180,
        )
        self.assertEqual(res.returncode, 1, res.stdout + res.stderr)
        self.assertIn("verdict undetermined", res.stderr)
        self.assertNotIn("status=ok", res.stdout)
        result = self.result_json()
        self.assertEqual(result["status"], "invalid")
        self.assertIs(result["ok"], False)
        self.assertEqual(result["verdict"], "undetermined")
        self.assertEqual(result["counters"]["band_ampdu_status"], "measured")

    def test_zero_ampdu_delta_is_invalid_not_ok(self):
        # A-MPDU presence is not evidence: a +0 delta proves no 802.11 byte
        # was counted, so the run is invalid even with a positive RX delta.
        self.write_band_bytes()
        env = os.environ.copy()
        env.update(self.env())
        env["ETHTOOL_STATIC"] = "1"
        res = subprocess.run(
            [SH, str(SCRIPT), *map(str, self.common_args())],
            env=env,
            capture_output=True,
            text=True,
            timeout=180,
        )
        self.assertEqual(res.returncode, 1, res.stdout + res.stderr)
        self.assertIn("positive A-MPDU byte delta is required", res.stderr)
        self.assertNotIn("status=ok", res.stdout)
        result = self.result_json()
        self.assertEqual(result["status"], "invalid")
        self.assertIs(result["ok"], False)

    def assert_ok(self, mode):
        self.write_band_bytes()
        args = self.common_args()
        if mode == "reverse":
            args += ["--sta-ip", STA_IP]
        res = self.run_harness(*args)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        result = self.result_json()
        self.assertEqual(result["status"], "ok")
        self.assertIs(result["ok"], True)
        self.assertIs(result["band_bytes_unavailable"], False)
        self.assertEqual(result["direction"]["mode"], mode)
        if mode == "listen":
            # AP is the server; the STA client command must not ask for -R.
            self.assertIn("iperf3 -s", result["direction"]["ap_command"])
            self.assertIn("iperf3 -c", result["direction"]["sta_command"])
            self.assertNotIn("-R", result["direction"]["sta_command"])
        else:
            # AP is the client and reverses; the STA is the server.
            self.assertIn("iperf3 -c", result["direction"]["ap_command"])
            self.assertIn("-R", result["direction"]["ap_command"])
            self.assertIn("iperf3 -s", result["direction"]["sta_command"])

    def test_listen_arm_is_ok_and_not_reversed(self):
        self.assert_ok("listen")

    def test_reverse_arm_is_ok_and_reversed(self):
        self.assert_ok("reverse")


class NoStaPreflight(unittest.TestCase):
    """No 6G station: a clean SKIP, and iperf3 is never named."""

    def test_missing_iperf3_still_skips_when_no_sta(self):
        tmp = Path(tempfile.mkdtemp(prefix="6g-rx-nosta."))
        self.addCleanup(shutil.rmtree, tmp, True)
        bindir = make_path(tmp)
        env = os.environ.copy()
        env["PATH"] = str(bindir)
        env["DEBUGFS"] = str(tmp / "debugfs")
        env["NWD_ALLOW_NO_SERVICE"] = "1"
        env["NW_GUARD_HOLD_FILE"] = str(tmp / "netwatchdog.hold")
        res = subprocess.run(
            [SH, str(SCRIPT)], env=env, capture_output=True, text=True, timeout=180
        )
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn("SKIP:", res.stdout)
        # The run must skip for the missing station, not for a missing tool.
        self.assertNotIn("iperf3", res.stdout.lower())
        self.assertNotIn("iperf3", res.stderr.lower())


if __name__ == "__main__":
    unittest.main(verbosity=2)
