#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline tests for scripts/wireless/6g-restore-eht320.sh.

Four behaviours are pinned here, none of them needing a radio or a device:

  * a config whose radio2.htmode drifted off the repository default is
    reported as drift, and the read-only run writes nothing at all;
  * --apply rewrites radio2.htmode to the default and verifies that
    ieee80211be reached the live hostapd config;
  * a failed verification rolls the config file (and the pending UCI delta)
    back to the exact bytes it found, and exits non-zero;
  * a config that is already at the default is left untouched.

The bench is a staged config file, a staged hostapd config, a fake uci that
only knows ``wireless.radio2.htmode`` and writes the staged file, and a fake
wifi that fabricates the post-reload hostapd config.  No device is touched.

Red half of the proof: point the test at a broken copy of the script and it
must fail.

    G6_RESTORE_UNDER_TEST=/tmp/6g-restore-no-rollback.sh \\
        python3 -m unittest scripts.tests.test_6g_restore_eht320

The test prints the path it is exercising before it runs, because a copy that
silently keeps testing the repository file proves nothing.

Run from the repository root:

    python3 -m unittest scripts.tests.test_6g_restore_eht320
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
        "G6_RESTORE_UNDER_TEST",
        REPO_ROOT / "scripts/wireless/6g-restore-eht320.sh",
    )
).resolve()
DEFAULTS = REPO_ROOT / "target/linux/airoha/an7581/base-files/etc/uci-defaults/51_wireless-tuning"
GUARD = REPO_ROOT / "scripts/lib/uci-restore-guard.sh"

print("script under test: %s" % SCRIPT)
print("defaults read from: %s" % DEFAULTS)

CONFIG_HE20 = """\
config wifi-device 'radio2'
\toption type 'mac80211'
\toption band '6g'
\toption channel '37'
\toption htmode 'HE20'
\toption country 'US'
\toption he_bss_color '39'
\toption disabled '0'
"""

CONFIG_EHT320 = CONFIG_HE20.replace("option htmode 'HE20'", "option htmode 'EHT320'")

HOSTAPD_NO_BE = """\
hw_mode=a
channel=37
ieee80211ax=1
"""

HOSTAPD_BE = """\
hw_mode=a
channel=37
ieee80211ax=1
ieee80211be=1
eht_oper_chwidth=9
eht_oper_centr_freq_seg0_idx=31
"""

# A uci that knows exactly one option and rewrites the staged config file:
# "set" is the write and "commit" is the point at which it lands, the same
# split the real uci has (which is why the delta exists at all).
FAKE_UCI = r"""#!/usr/bin/env python3
import os, sys, re

cfg = os.environ["FAKE_UCI_CFG"]
delta = os.environ.get("FAKE_UCI_DELTA", "")
log = os.environ["FAKE_UCI_LOG"]

argv = sys.argv[1:]
quiet = False
if argv[:1] == ["-q"]:
    quiet = True
    argv = argv[1:]

with open(log, "a") as handle:
    handle.write(" ".join(argv) + "\n")

def get(option):
    text = open(cfg).read()
    match = re.search(r"option %s '([^']*)'" % re.escape(option), text)
    if match is None:
        return None
    return match.group(1)

if argv == ["get", "wireless.radio2.htmode"]:
    value = get("htmode")
    if value is None:
        sys.exit(1)
    print(value)
    sys.exit(0)

if len(argv) == 2 and argv[0] == "set" and argv[1].startswith("wireless.radio2.htmode="):
    value = argv[1].split("=", 1)[1]
    text = open(cfg).read()
    new, count = re.subn(r"option htmode '[^']*'", "option htmode '%s'" % value, text)
    if count == 0:
        new = text + "\toption htmode '%s'\n" % value
    # Mirror real uci: the write lands in the delta first.
    if delta:
        open(delta, "w").write(new)
    else:
        open(cfg, "w").write(new)
    sys.exit(0)

if argv == ["commit", "wireless"]:
    if delta and os.path.exists(delta):
        shutil_move = os.environ.get("FAKE_UCI_MOVE")
        if shutil_move:
            os.replace(delta, cfg)
        else:
            data = open(delta).read()
            open(cfg, "w").write(data)
            os.unlink(delta)
    sys.exit(0)

if not quiet:
    sys.stderr.write("fake uci: unsupported %r\n" % (argv,))
sys.exit(1)
"""

# A wifi that stands in for the real reload: when the config now asks for an
# EHT width and FAKE_WIFI_EMIT_BE=1, it writes the post-reload hostapd config
# the way hostapd would; otherwise it leaves the config untouched (the arm
# that proves the verification failure path).
FAKE_WIFI = r"""#!/bin/sh
printf '%s\n' "$*" >> "${FAKE_WIFI_LOG:?}"
[ "${FAKE_WIFI_EMIT_BE:-1}" = "1" ] || exit 0
grep -q "option htmode 'EHT" "$FAKE_UCI_CFG" || exit 0
cat > "$FAKE_HOSTAPD_CFG" <<'EOF'
hw_mode=a
channel=37
ieee80211ax=1
ieee80211be=1
eht_oper_chwidth=9
eht_oper_centr_freq_seg0_idx=31
EOF
"""

# An iw that reports the live width the way the board does: the width is one
# field in a line that continues with the centre frequency ("width: 320 MHz,
# center1: 6105 MHz"), so a parser that trims the line's tail reads
# "320 MHz, center1: 6105".  FAKE_IW_WIDTH=160 is the EHT160 fallback the
# config text cannot show: ieee80211be is still in the hostapd config.
FAKE_IW = r"""#!/bin/sh
if [ -n "${FAKE_IW_LOG:-}" ]; then
	printf '%s\n' "$*" >> "${FAKE_IW_LOG}"
fi
_w="${FAKE_IW_WIDTH:-320}"
if [ -n "${FAKE_IW_SEQ:-}" ] && [ -n "${FAKE_IW_COUNT_FILE:-}" ]; then
	_n=0
	[ -f "$FAKE_IW_COUNT_FILE" ] && _n=$(cat "$FAKE_IW_COUNT_FILE")
	_n=$((_n + 1))
	printf '%s\n' "$_n" > "$FAKE_IW_COUNT_FILE"
	_w=$(printf '%s\n' "$FAKE_IW_SEQ" | awk -F, -v idx="$_n" '{ if (idx <= NF) print $idx; else print $NF }')
fi
case "$_w" in
missing)
	printf 'command failed: No such device (-19)\n' >&2
	exit 237
	;;
empty)
	printf 'phy#0\n\tInterface %s\n\ttype AP\n' "${FAKE_IW_IFACE:-phy0.2-ap0}"
	exit 0
	;;
esac
printf 'phy#0\n\tInterface %s\n\t\tchannel 37 (6135 MHz), width: %s MHz, center1: 6105 MHz\n' \
	"${FAKE_IW_IFACE:-phy0.2-ap0}" "$_w"
"""


def write_exec(path: Path, text: str) -> None:
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class Bench:
    """A throwaway root with the staged config, hostapd, delta and fakes."""

    def __init__(self, config: str, hostapd: str):
        self.tmp = Path(tempfile.mkdtemp(prefix="6g-restore-eht320."))
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.cfg = self.tmp / "wireless"
        self.cfg.write_text(config)
        self.hostapd = self.tmp / "hostapd-phy0.2.conf"
        self.hostapd.write_text(hostapd)
        self.delta = self.tmp / "delta-wireless"
        self.uci_log = self.tmp / "uci.log"
        self.wifi_log = self.tmp / "wifi.log"
        self.iw_log = self.tmp / "iw.log"
        self.iw_count = self.tmp / "iw.count"
        self.urg_dir = self.tmp / "restore"
        self.uci_log.write_text("")
        self.wifi_log.write_text("")
        self.iw_log.write_text("")

        write_exec(self.bin / "uci", FAKE_UCI)
        write_exec(self.bin / "wifi", FAKE_WIFI)
        write_exec(self.bin / "iw", FAKE_IW)
        # The guard's "command -v $URG_WIFI" check only needs a name it can
        # find; the fake above is on PATH under that name.
        self.env = dict(os.environ)
        self.env.update({
            "PATH": "%s:%s" % (self.bin, os.environ.get("PATH", "/usr/bin:/bin")),
            "WIRELESS_CFG": str(self.cfg),
            "HOSTAPD_CONF": str(self.hostapd),
            "G6_DEFAULTS": str(DEFAULTS),
            "G6_IFACE": "phy0.2-ap0",
            "G6_VERIFY_TIMEOUT": "2",
            "URG_LIB": str(GUARD),
            "URG_DIR": str(self.urg_dir),
            "URG_DELTA": str(self.delta),
            "URG_WIFI": "wifi",
            "FAKE_UCI_CFG": str(self.cfg),
            "FAKE_UCI_DELTA": str(self.delta),
            "FAKE_UCI_LOG": str(self.uci_log),
            "FAKE_WIFI_LOG": str(self.wifi_log),
            "FAKE_IW_LOG": str(self.iw_log),
            "FAKE_IW_COUNT_FILE": str(self.iw_count),
            "FAKE_HOSTAPD_CFG": str(self.hostapd),
            "FAKE_UCI_MOVE": "1",
            "FAKE_IW_WIDTH": "320",
        })

    def run(self, *args, emit_be="1", width="320", iw_seq="", timeout="2"):
        env = dict(self.env)
        env["FAKE_WIFI_EMIT_BE"] = emit_be
        env["FAKE_IW_WIDTH"] = width
        env["G6_VERIFY_TIMEOUT"] = str(timeout)
        if iw_seq:
            env["FAKE_IW_SEQ"] = iw_seq
        else:
            env.pop("FAKE_IW_SEQ", None)
        return subprocess.run(
            ["sh", str(SCRIPT), *args],
            env=env,
            text=True,
            capture_output=True,
            timeout=60,
        )

    def uci_calls(self) -> str:
        return self.uci_log.read_text()

    def reloads(self) -> str:
        return self.wifi_log.read_text()

    def iw_calls(self) -> list[str]:
        return [line for line in self.iw_log.read_text().splitlines() if line]

    def close(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


class RestoreTest(unittest.TestCase):
    def setUp(self):
        self.benches = []

    def tearDown(self):
        for bench in self.benches:
            bench.close()

    def bench(self, config: str = CONFIG_HE20, hostapd: str = HOSTAPD_NO_BE):
        b = Bench(config, hostapd)
        self.benches.append(b)
        return b

    def test_drift_is_reported_and_nothing_is_written(self):
        b = self.bench()
        before = b.cfg.read_bytes()
        result = b.run()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("status:   drift", result.stdout)
        self.assertIn("current:  radio2.htmode=HE20", result.stdout)
        self.assertIn("expected: radio2.htmode=EHT320", result.stdout)
        self.assertEqual(b.cfg.read_bytes(), before)
        self.assertEqual(b.uci_calls(), "")
        self.assertEqual(b.reloads(), "")

    def test_apply_writes_the_default_and_verifies(self):
        b = self.bench()
        result = b.run("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("set wireless.radio2.htmode=EHT320", b.uci_calls())
        self.assertEqual(
            b.cfg.read_text(),
            CONFIG_HE20.replace("option htmode 'HE20'", "option htmode 'EHT320'"),
        )
        self.assertIn("reload", b.reloads())
        self.assertIn("verify:   ieee80211be present", result.stdout)
        self.assertIn("verify:   phy0.2-ap0 width: 320 MHz", result.stdout)
        self.assertIn("status:   restored to EHT320 (320 MHz)", result.stdout)
        self.assertFalse(b.delta.exists(), "a committed delta must not be left behind")
        self.assertFalse(b.urg_dir.exists(), "a clean run must disarm its restore point")

    def test_failed_verification_rolls_back(self):
        b = self.bench()
        before = b.cfg.read_bytes()
        result = b.run("--apply", emit_be="0")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("verify:   FAILED", result.stderr)
        self.assertEqual(
            b.cfg.read_bytes(),
            before,
            "the config file must be byte-identical after a rollback",
        )
        self.assertFalse(
            b.delta.exists(),
            "a delta created by the failed run must be removed, not folded in later",
        )

    def test_eht160_fallback_is_a_failed_apply(self):
        # ieee80211be in the hostapd config does not prove 320 MHz: a radio
        # that negotiated 160 MHz still has it.  The apply must fail and roll
        # back rather than report "restored to EHT320".
        b = self.bench()
        before = b.cfg.read_bytes()
        result = b.run("--apply", width="160")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("verify:   width is 160 MHz, expected 320 MHz", result.stderr)
        self.assertIn("status:   failed, EHT320 was written but is not in effect",
                      result.stderr)
        self.assertNotIn("status:   restored", result.stdout)
        self.assertEqual(
            b.cfg.read_bytes(),
            before,
            "a width the radio did not reach must not leave the write behind",
        )
        self.assertFalse(b.delta.exists(), "the failed run's delta must be removed")

    def test_unreadable_width_is_a_failed_apply(self):
        # No iw evidence at all (iw is present but reports no width line):
        # the config text is not enough to call the radio restored.
        b = self.bench()
        result = b.run("--apply", width="unreadable")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("verify:   cannot read the width of phy0.2-ap0", result.stderr)
        self.assertNotIn("status:   restored", result.stdout)
        # The diagnostic is the only width line: no shell error from
        # comparing "unreadable" with -ge first.
        self.assertNotIn("Illegal number", result.stderr)
        self.assertNotIn("integer expected", result.stderr)
        self.assertNotIn("bad number", result.stderr)

    def test_already_at_the_default_is_left_alone(self):
        b = self.bench(config=CONFIG_EHT320, hostapd=HOSTAPD_BE)
        result = b.run("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("status:   default", result.stdout)
        self.assertIn("apply:    already at EHT320, nothing written", result.stdout)
        self.assertEqual(b.uci_calls(), "", "a no-op run must not call uci at all")
        self.assertEqual(b.reloads(), "", "a verified 320 MHz link must not reload wifi")
        self.assertEqual(b.cfg.read_text(), CONFIG_EHT320)

    def test_already_at_default_with_eht160_fallback_does_not_short_circuit_ok(self):
        # Config is EHT320 and hostapd.conf has ieee80211be=1, but live iw
        # width fell back to 160 MHz.  --apply must NOT exit 0 as already-good.
        b = self.bench(config=CONFIG_EHT320, hostapd=HOSTAPD_BE)
        result = b.run("--apply", width="160")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertNotIn("already at EHT320, nothing written", result.stdout)
        self.assertIn("apply:    config already EHT320, reloading to verify", result.stdout)
        self.assertIn("reload", b.reloads())
        self.assertIn("verify:   width is 160 MHz, expected 320 MHz", result.stderr)
        self.assertIn(
            "status:   failed, the config already asked for EHT320; the live radio did not reach it",
            result.stderr,
        )
        self.assertEqual(b.uci_calls(), "")
        self.assertEqual(b.cfg.read_text(), CONFIG_EHT320)

    def test_already_at_default_with_eht160_recovers_after_reload(self):
        # Config is EHT320 and hostapd.conf has ieee80211be=1, live iw is
        # initially 160 MHz, then recovers to 320 MHz after wifi reload.
        b = self.bench(config=CONFIG_EHT320, hostapd=HOSTAPD_BE)
        result = b.run("--apply", iw_seq="160,320")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("already at EHT320, nothing written", result.stdout)
        self.assertIn("apply:    config already EHT320, reloading to verify", result.stdout)
        self.assertIn("reload", b.reloads())
        self.assertIn("status:   restored to EHT320 (320 MHz)", result.stdout)
        self.assertEqual(b.uci_calls(), "")
        self.assertEqual(b.cfg.read_text(), CONFIG_EHT320)

    def test_apply_polls_iw_until_interface_reaches_320(self):
        # hostapd.conf appears before hostapd finishes interface setup: iw
        # initially reports missing device, then empty width, then 320 MHz.
        b = self.bench(config=CONFIG_HE20, hostapd=HOSTAPD_NO_BE)
        result = b.run("--apply", iw_seq="missing,empty,320", timeout="3")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(b.iw_calls()), 3, b.iw_calls())
        self.assertIn("verify:   phy0.2-ap0 width: 320 MHz", result.stdout)
        self.assertIn("status:   restored to EHT320 (320 MHz)", result.stdout)
        self.assertEqual(b.cfg.read_text(), CONFIG_EHT320)
        self.assertFalse(b.delta.exists())
        self.assertFalse(b.urg_dir.exists())


if __name__ == "__main__":
    unittest.main()
