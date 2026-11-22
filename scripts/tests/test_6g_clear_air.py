#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Behaviour tests for scripts/wireless/6g-clear-air.sh.

The defects this harness had on the board (issue #68):

  1. The "loaded" arm only added the script's own 6 GHz traffic, so it
     loaded nothing: it differed from the clear arm only in which 5G/2.4A
     SSIDs were enabled.  The loaded arm must now run a real interferer on
     another band, and a run without one is INVALID (NO_INTERFERER) instead
     of "ok".
  2. verify_clear_arm() inferred "clean air" from its own counters without
     ever scanning.  It now scans the measured channel and counts the
     same-channel BSS; a scan without records is UNKNOWN, and any
     same-channel BSS is INVALID (CO_CHANNEL_BSS).
  3. There was no way to repeat the pair: --rounds N runs A/B/A/B and tags
     every row with its round.
  4. refresh_live() dropped the "width:" field, so a clear arm that came
     back at a narrower channel width could not be detected.

Everything runs offline against stub iw/wifi/iperf3 binaries in a temporary
directory; no radio, no config write outside the temporary directory.

    python3 scripts/tests/test_6g_clear_air.py
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
# SIXG_CLEAR_AIR_UNDER_TEST points the tests at another copy of the script so a
# red proof can run them against the pre-fix version (repo convention).
SCRIPT = Path(
    os.environ.get("SIXG_CLEAR_AIR_UNDER_TEST")
    or REPO_ROOT / "scripts/wireless/6g-clear-air.sh"
)

CONFIG = """config wifi-device 'radio0'
\toption type 'mac80211'
\toption band '2g'
\toption channel '6'

config wifi-device 'radio1'
\toption type 'mac80211'
\toption band '5g'
\toption channel '36'

config wifi-device 'radio2'
\toption type 'mac80211'
\toption band '6g'
\toption channel '37'

config wifi-iface 'ap24'
\toption device 'radio0'
\toption mode 'ap'
\toption ssid 'home-24'

config wifi-iface 'ap5g'
\toption device 'radio1'
\toption mode 'ap'
\toption ssid 'home-5g'

config wifi-iface 'ap6g'
\toption device 'radio2'
\toption mode 'ap'
\toption ssid '6g-clear-air'
"""

# A stub iw that plays back a live state derived from the config the script
# edits: the 5G/2.4 GHz AP records disappear when their SSIDs are disabled,
# exactly as a real reload would.  "scan" reports our own associated BSS
# plus one non-associated neighbour on another 6 GHz channel.
STUB_IW = """#!/bin/sh
disabled() {
\tawk -v want="$1" '
\t\tfunction unq(v) { gsub(/["\\047]/, "", v); return v }
\t\t$1 == "config" { cur = ($2 == "wifi-iface") ? unq($3) : ""; next }
\t\tcur == want && $1 == "option" && $2 == "disabled" { print unq($3) }
\t' "$STUB_CFG" | grep -q 1
}
case "$*" in
"dev")
\tprintf 'phy#2\\n\\tInterface phy2-ap0\\n\\t\\tssid 6g-clear-air\\n\\t\\ttype AP\\n\\t\\tchannel 37 (6135 MHz), width: 320 MHz, center1: 6265 MHz\\n'
\tif ! disabled ap5g; then
\t\tprintf 'phy#1\\n\\tInterface phy1-ap0\\n\\t\\tssid home-5g\\n\\t\\ttype AP\\n\\t\\tchannel 36 (5180 MHz), width: 160 MHz, center1: 5250 MHz\\n'
\tfi
\tif ! disabled ap24; then
\t\tprintf 'phy#0\\n\\tInterface phy0-ap0\\n\\t\\tssid home-24\\n\\t\\ttype AP\\n\\t\\tchannel 6 (2437 MHz), width: 20 MHz\\n'
\tfi
\t;;
"dev phy2-ap0 station dump")
\tprintf 'Station 11:22:33:44:55:66 (on phy2-ap0)\\n\\t\\ttx bytes:\\t%s\\n\\t\\trx bytes:\\t%s\\n\\t\\ttx retries:\\t0\\n\\t\\ttx failed:\\t0\\n\\t\\tsignal:\\t-45 dBm\\n' "$(cat "$STUB_ROOT/state/sta_tx")" "$(cat "$STUB_ROOT/state/sta_tx")"
\t;;
"dev phy1-ap0 station dump")
\tif [ -z "${NOS5G:-}" ]; then
\t\tprintf 'Station aa:bb:cc:dd:ee:ff (on phy1-ap0)\\n\\t\\ttx bytes:\\t%s\\n\\t\\trx bytes:\\t%s\\n' "$(cat "$STUB_ROOT/state/sta5_tx")" "$(cat "$STUB_ROOT/state/sta5_tx")"
\tfi
\t;;
"dev phy2-ap0 scan")
\tcat <<'SCAN'
BSS aa:bb:cc:00:00:01(on phy2-ap0) -- associated
\tfreq: 6135
\tSSID: 6g-clear-air
BSS aa:bb:cc:00:00:09(on phy2-ap0)
\tfreq: 6480
\tSSID: neighbour-6g
SCAN
\t;;
*) ;;
esac
"""

# A generator that is not iperf3: it moves the same counters and prints a
# different throughput, so a --source run is distinguishable from the default.
STUB_ALT_SOURCE = """#!/bin/sh
bump() {
	v=$(cat "$1")
	printf '%s\\n' $((v + 400000)) >"$1"
}
bump "$STUB_ROOT/state/sta_tx"
bump "$STUB_ROOT/net/phy2-ap0/statistics/tx_bytes"
cat <<'JSON'
{
	"alternate-source": "udpblast3",
	"end": {
		"sum_sent": { "bytes": 40000000, "bits_per_second": 1234000000.0, "retransmits": 0 },
		"sum_received": { "bytes": 40000000, "bits_per_second": 1234000000.0 }
	}
}
JSON
exit 0
"""

# One direction of the 6 GHz source, or the interferer source.  The counters
# move so the harness can verify that the flow really used the radio.
STUB_IPERF3 = """#!/bin/sh
ip=
while [ $# -gt 0 ]; do
\tcase $1 in
\t-c) ip=$2; shift ;;
\t-t | -p | -P | -b) shift ;;
\t*) ;;
\tesac
\tshift
done
bump() {
\t[ -n "${NOBUMP:-}" ] && return 0
\tv=$(cat "$1")
\tprintf '%s\\n' $((v + 200000)) >"$1"
}
if [ "$ip" = "192.168.1.51" ]; then
\t[ -z "${NOINTBUMP:-}" ] || exit 0
\tbump "$STUB_ROOT/net/phy1-ap0/statistics/tx_bytes"
\tbump "$STUB_ROOT/state/sta5_tx"
\ti=0
\twhile [ $i -lt 20 ]; do
\t\ti=$((i + 1))
\t\tsleep 0.1
\t\tbump "$STUB_ROOT/net/phy1-ap0/statistics/tx_bytes"
\t\tbump "$STUB_ROOT/state/sta5_tx"
\tdone
\texit 0
fi
bump "$STUB_ROOT/state/sta_tx"
bump "$STUB_ROOT/net/phy2-ap0/statistics/tx_bytes"
cat <<'JSON'
{
\t"start": { "test_start": { "protocol": "TCP" } },
\t"intervals": [],
\t"end": {
\t\t"sum_sent": { "bytes": 20000000, "bits_per_second": 900000000.0, "retransmits": 0 },
\t\t"sum_received": { "bytes": 20000000, "bits_per_second": 900000000.0 }
\t},
\t"error": null
}
JSON
exit 0
"""


class Fixture:
    """A temporary radio, config and counter tree for one offline run."""

    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.cfg = self.root / "wireless.conf"
        self.cfg.write_text(CONFIG)
        self.original = CONFIG
        (self.root / "bin" / "wifi").parent.mkdir(parents=True)
        for name, body in (
            ("iw", STUB_IW),
            ("iperf3", STUB_IPERF3),
            ("udpblast", STUB_ALT_SOURCE),
        ):
            path = self.root / "bin" / name
            path.write_text(body)
            path.chmod(0o755)
        (self.root / "bin" / "wifi").write_text("#!/bin/sh\nexit 0\n")
        (self.root / "bin" / "wifi").chmod(0o755)
        for iface, tx, rx in (("phy1-ap0", 1000000, 500000), ("phy2-ap0", 0, 0)):
            stats = self.root / "net" / iface / "statistics"
            stats.mkdir(parents=True)
            (stats / "tx_bytes").write_text(f"{tx}\n")
            (stats / "rx_bytes").write_text(f"{rx}\n")
            (stats / "tx_packets").write_text("0\n")
        state = self.root / "state"
        state.mkdir()
        (state / "sta_tx").write_text("1000000\n")
        (state / "sta5_tx").write_text("1000000\n")
        (self.root / "dbg").mkdir()
        self.out = self.root / "out"

    def cleanup(self):
        self.tmp.cleanup()

    def env(self, **extra):
        base = {
            "NWD_ALLOW_NO_SERVICE": "1",
            "STUB_ROOT": str(self.root),
            "STUB_CFG": str(self.cfg),
            "IW": str(self.root / "bin" / "iw"),
            "WIFI": str(self.root / "bin" / "wifi"),
            "IPERF3": str(self.root / "bin" / "iperf3"),
            "SYSFS_NET": str(self.root / "net"),
            "DEBUGFS": str(self.root / "dbg"),
        }
        base.update(extra)
        return {k: str(v) for k, v in base.items()}

    def run(self, extra_args, **env):
        full = os.environ.copy()
        full.update(self.env(**env))
        return subprocess.run(
            [
                "sh", str(SCRIPT),
                "--config", str(self.cfg),
                "--target", "192.168.1.50",
                "--duration", "1",
                "--settle", "0",
                "--wait-sta", "3",
                "--wait-bss", "3",
                "--out", str(self.out),
                *extra_args,
            ],
            capture_output=True,
            text=True,
            env=full,
            check=False,
        )

    def arms(self):
        rows = []
        for line in (self.out / "arms.tsv").read_text().splitlines():
            fields = line.split("|")
            if len(fields) >= 17:
                rows.append((int(fields[16]), fields[0], fields[1]))
        return rows


class NoInterferer(unittest.TestCase):
    """A loaded arm without a real interferer cannot be called ok."""

    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.cleanup)

    def test_no_station_on_the_interferer_band_is_invalid(self):
        out = self.fixture.run(["--interferer", "5g:36:tcp:100:192.168.1.51"], NOS5G="1")
        combined = out.stdout + out.stderr
        self.assertNotEqual(out.returncode, 0, combined)
        self.assertIn("NO_INTERFERER", combined)
        self.assertIn("verdict: INVALID", combined)
        self.assertNotIn("verdict: ok", combined)
        self.assertEqual(
            (self.fixture.out / "verdict").read_text().strip(), "INVALID"
        )
        # Nothing was measured, so no arm rows were invented.
        self.assertFalse((self.fixture.out / "arms.tsv").exists())
        # The config was still restored.
        self.assertEqual(self.fixture.cfg.read_text(), self.fixture.original)

    def test_generator_that_moves_no_bytes_is_invalid(self):
        out = self.fixture.run(
            ["--interferer", "5g:36:tcp:100:192.168.1.51"], NOINTBUMP="1"
        )
        combined = out.stdout + out.stderr
        self.assertNotEqual(out.returncode, 0, combined)
        self.assertIn("NO_INTERFERER_EVIDENCE", combined)
        self.assertIn("verdict: INVALID", combined)


class Rounds(unittest.TestCase):
    """--rounds N runs A/B/A/B and tags every row."""

    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.cleanup)

    def test_two_rounds_produce_four_arm_runs(self):
        out = self.fixture.run(
            ["--rounds", "2", "--interferer", "5g:36:tcp:100:192.168.1.51"]
        )
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn("=== round 2/2 (A/B) ===", out.stdout)
        self.assertIn("verdict: ok", out.stdout)
        runs = [(round_no, arm) for round_no, arm, _dir in self.fixture.arms()]
        # Two directions per arm: A/B/A/B with the same order each round.
        self.assertEqual(
            sorted(set(runs)),
            [(1, "clear"), (1, "loaded"), (2, "clear"), (2, "loaded")],
        )
        self.assertEqual(len(runs), 8, self.fixture.arms())
        self.assertEqual(
            runs, [(1, "clear"), (1, "clear"), (1, "loaded"), (1, "loaded"),
                   (2, "clear"), (2, "clear"), (2, "loaded"), (2, "loaded")],
        )
        header = (self.fixture.out / "summary.csv").read_text().splitlines()[0]
        self.assertTrue(header.startswith("round,arm,direction,"), header)
        self.assertIn("delta AP->STA mean over 2 rounds", out.stdout)
        self.assertEqual(
            [line for line in out.stdout.splitlines() if "interferer" in line and "carried" in line],
            [line for line in out.stdout.splitlines() if "carried" in line],
        )

    def test_loaded_arm_records_real_interferer_bytes(self):
        out = self.fixture.run(["--interferer", "5g:36:tcp:100:192.168.1.51"])
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn("check: PASS loaded arm: interferer", out.stdout)
        record = (self.fixture.out / "interferer-round1.txt").read_text()
        self.assertIn("ap_tx_bytes=", record)
        self.assertIn("sta_tx_bytes=", record)


class Scan(unittest.TestCase):
    """The clear arm's channel is scanned, not inferred."""

    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.cleanup)

    def test_scan_counts_are_recorded(self):
        out = self.fixture.run(["--interferer", "5g:36:tcp:100:192.168.1.51"])
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn("check: PASS clear arm: scan sees 1 BSS", out.stdout)
        line = (self.fixture.out / "scan.txt").read_text().strip()
        self.assertIn("same_channel=0", line)
        self.assertIn("own=1", line)


class RefreshLive(unittest.TestCase):
    """refresh_live keeps the negotiated width."""

    def test_width_survives_refresh(self):
        lines = SCRIPT.read_text().splitlines()
        start = lines.index("refresh_live() {")
        end = next(i for i in range(start + 1, len(lines)) if lines[i] == "}")
        body = "\n".join(lines[start:end + 1]) + "\n"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            iw = root / "iw"
            iw.write_text(
                "#!/bin/sh\n"
                "printf 'phy#2\\n\\tInterface phy2-ap0\\n\\t\\tssid 6g\\n\\t\\ttype AP\\n"
                "\\t\\tchannel 37 (6135 MHz), width: 320 MHz, center1: 6265 MHz\\n'\n"
            )
            iw.chmod(0o755)
            script = root / "run.sh"
            script.write_text(
                body
                + f'TMP_IW={root}/iw.out\nTMP_LIVE={root}/live.out\n'
                + f'IW={iw}\n: >"$TMP_IW"\nrefresh_live\ncat "$TMP_LIVE"\n'
            )
            out = subprocess.run(
                ["sh", str(script)], capture_output=True, text=True, check=False
            )
            self.assertEqual(out.returncode, 0, out.stderr)
            fields = out.stdout.strip().split("|")
            self.assertEqual(len(fields), 7, out.stdout)
            self.assertEqual(fields[0], "phy2-ap0")
            self.assertEqual(fields[2], "6135")
            self.assertEqual(fields[6], "320")


class MissingTool(unittest.TestCase):
    """A missing tool is recorded as a gap (exit 2), not a crashed run (#68)."""

    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.cleanup)

    def test_missing_iperf3_records_the_gap_and_exits_2(self):
        out = self.fixture.run(
            [], IPERF3=str(self.fixture.root / "bin" / "no-iperf3-here")
        )
        combined = out.stdout + out.stderr
        self.assertEqual(out.returncode, 2, combined)
        self.assertIn("SKIP", out.stdout)
        self.assertIn("missing iperf3", out.stdout)
        record = self.fixture.out / "result.json"
        self.assertTrue(record.exists(), combined)
        data = json.loads(record.read_text())
        self.assertEqual(data["schema"], "wireless-no-client/v1")
        self.assertEqual(data["status"], "no-client")
        self.assertEqual(str(data["ticket"]), "68")
        self.assertEqual(data["missing"], "iperf3")
        # The config was restored by the run's own trap.
        self.assertEqual(self.fixture.cfg.read_text(), self.fixture.original)


class SourceSlot(unittest.TestCase):
    """--source replaces the iperf3 client in the measured arms."""

    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.cleanup)

    def source(self):
        return "sh %s" % (self.fixture.root / "bin" / "udpblast")

    def test_source_runs_the_measured_arms(self):
        out = self.fixture.run(
            ["--source", self.source(), "--interferer", "5g:36:tcp:100:192.168.1.51"]
        )
        combined = out.stdout + out.stderr
        self.assertEqual(out.returncode, 0, combined)
        self.assertIn("verdict: ok", combined)
        arms = (self.fixture.out / "arms.tsv").read_text()
        self.assertIn("1234", arms)
        commands = (self.fixture.out / "source-commands.txt").read_text()
        self.assertIn("udpblast", commands)

    def test_source_lets_a_host_without_iperf3_measure_the_clear_arm(self):
        # No iperf3 anywhere: the clear arm still runs through --source, then
        # the interferer load (which really is iperf3) is recorded as missing.
        out = self.fixture.run(
            ["--source", self.source(), "--interferer", "5g:36:tcp:100:192.168.1.51"],
            IPERF3=str(self.fixture.root / "bin" / "no-iperf3-here"),
        )
        combined = out.stdout + out.stderr
        self.assertEqual(out.returncode, 2, combined)
        arms = (self.fixture.out / "arms.tsv").read_text()
        self.assertIn("1234", arms)
        self.assertIn("SKIP", out.stdout)
        self.assertIn("interferer", out.stdout)
        data = json.loads((self.fixture.out / "result.json").read_text())
        self.assertEqual(data["missing"], "iperf3")
        self.assertEqual(self.fixture.cfg.read_text(), self.fixture.original)


if __name__ == "__main__":
    unittest.main(verbosity=2)
