#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline tests for the XR1710G regulatory-domain arbitration script.

The uci-defaults script normally runs on the router, against /lib/functions.sh
and the real /sbin/uci.  Here it runs against a throwaway fixture root:

  * lib/functions.sh is a copy of package/base-files/files/lib/functions.sh
    with board_name() overridden to the XR1710G board id (the real one reads
    /tmp/sysinfo/board_name);
  * `uci` and `logger` are shell stubs injected through PATH; uci keeps its
    state in a flat key=value file, so get/set/commit behave like the real
    thing for the keys this script touches.

Every run starts from a clean environment.  IPKG_INSTROOT is absent unless a
test exports it.  That absence is the regression guarded here: the script runs
under `set -u` and lib/functions.sh expands $IPKG_INSTROOT while being sourced,
so an unset IPKG_INSTROOT used to kill the script before arbitration with
"IPKG_INSTROOT: parameter not set".

Run from the repository root:

    python3 -m unittest scripts/tests/test_reg_arbitrate.py
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = (REPO_ROOT / "target/linux/airoha/an7581/base-files/etc/uci-defaults"
          / "60_xr1710g-reg-arbitrate")
FUNCTIONS = REPO_ROOT / "package/base-files/files/lib/functions.sh"

UCI_STUB = """#!/bin/sh
# Minimal uci stub: state lives in $UCI_STORE as flat key=value lines.
store=$UCI_STORE
[ "$1" = "-q" ] && shift
cmd=$1
shift || true
case "$cmd" in
get)
	key=$1
	val=$(grep -F -- "$key=" "$store" | cut -d= -f2- | tail -n 1)
	if [ -n "$val" ]; then
		printf '%s\\n' "$val"
		exit 0
	fi
	# A section counts as present when any option hangs off it.
	grep -qF -- "$key." "$store" && exit 0
	exit 1
	;;
set)
	pair=$1
	key=${pair%%=*}
	val=${pair#*=}
	grep -vF -- "$key=" "$store" > "$store.tmp"
	printf '%s=%s\\n' "$key" "$val" >> "$store.tmp"
	mv "$store.tmp" "$store"
	exit 0
	;;
commit)
	exit 0
	;;
*)
	exit 1
	;;
esac
"""

LOGGER_STUB = """#!/bin/sh
# logger stub: drop the -t tag and append the message to $LOG_FILE.
[ "$1" = "-t" ] && shift 2
printf '%s\\n' "$1" >> "$LOG_FILE"
"""

# BusyBox v1.38.0 on the XR1710G (r37994) does not implement [:lower:]/[:upper:]
# in tr: it copies those classes through, so `echo cn | tr '[:lower:]'
# '[:upper:]'` prints `cn` on the device.  The stub reproduces that, so a
# regression back to the class form fails here on any host, GNU tr or not.
TR_STUB = """#!/bin/sh
if [ "$1" = "a-z" ] && [ "$2" = "A-Z" ]; then
	exec /usr/bin/tr 'a-z' 'A-Z'
fi
cat
"""


class Fixture:
    """One throwaway root with a rewritten copy of the script under test."""

    def __init__(self, tmpdir):
        self.root = Path(tmpdir)
        self.etc = self.root / "etc"
        self.bin = self.root / "bin"
        self.lib = self.root / "lib"
        for directory in (self.etc, self.bin, self.lib):
            directory.mkdir()

        self.functions = self.lib / "functions.sh"
        self.functions.write_text(FUNCTIONS.read_text())
        with self.functions.open("a") as handle:
            handle.write("\nboard_name() { echo gemtek,xr1710g-ubi; }\n")

        self.store = self.root / "uci-store"
        self.store.write_text("")
        self.log = self.root / "log"
        self.log.write_text("")
        self.wireless = self.etc / "config" / "wireless"
        self.wireless.parent.mkdir()
        self.wireless.write_text("config wifi-device radio1\n")

        for name, body in (("uci", UCI_STUB), ("logger", LOGGER_STUB),
                           ("tr", TR_STUB)):
            path = self.bin / name
            path.write_text(body)
            path.chmod(0o755)

        self.script = self.root / "reg-arbitrate"
        self.script.write_text(
            SCRIPT.read_text()
            .replace(". /lib/functions.sh", ". %s" % self.functions)
            .replace("/etc/config/wireless", str(self.wireless)))

    def set_uci(self, key, value):
        lines = [line for line in self.store.read_text().splitlines()
                 if not line.startswith("%s=" % key)]
        lines.append("%s=%s" % (key, value))
        self.store.write_text("\n".join(lines) + "\n")

    def run(self, *args, **kwargs):
        env = {
            "PATH": "%s:/usr/bin:/bin" % self.bin,
            "UCI_STORE": str(self.store),
            "LOG_FILE": str(self.log),
            "HOME": str(self.root),
        }
        if kwargs.get("prefer") is not None:
            env["REG_PREFER"] = kwargs["prefer"]
        if kwargs.get("ipkg_instroot") is not None:
            env["IPKG_INSTROOT"] = kwargs["ipkg_instroot"]
        self.log.write_text("")
        return subprocess.run(
            ["sh", str(self.script)] + list(args),
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True)

    def logged(self):
        return self.log.read_text().splitlines()


class RegArbitrateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="reg-arbitrate-")
        self.fx = Fixture(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def assert_run(self, result, logs=1):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "", "script wrote to stderr")
        self.assertEqual(len(self.fx.logged()), logs, self.fx.logged())

    def test_radio1_only(self):
        self.fx.set_uci("wireless.radio1.country", "US")
        self.fx.set_uci("wireless.radio1.channel", "149")
        self.fx.set_uci("wireless.radio1.htmode", "EHT80")
        before = self.fx.store.read_text()
        result = self.fx.run()
        self.assert_run(result)
        self.assertIn("reg=US (radio1 only)", self.fx.logged()[0])
        self.assertEqual(self.fx.store.read_text(), before)

    def test_radio2_only(self):
        self.fx.set_uci("wireless.radio2.country", "CN")
        self.fx.set_uci("wireless.radio2.channel", "37")
        self.fx.set_uci("wireless.radio2.htmode", "EHT320")
        before = self.fx.store.read_text()
        result = self.fx.run()
        self.assert_run(result)
        self.assertIn("reg=CN (radio2 only)", self.fx.logged()[0])
        self.assertEqual(self.fx.store.read_text(), before)

    def test_no_radio_section_is_silent(self):
        result = self.fx.run()
        self.assert_run(result)
        self.assertIn("nothing to arbitrate", self.fx.logged()[0])

    def test_both_differ_default_is_warn_only(self):
        self.fx.set_uci("wireless.radio1.country", "CN")
        self.fx.set_uci("wireless.radio2.country", "US")
        before = self.fx.store.read_text()
        result = self.fx.run()
        self.assert_run(result)
        self.assertIn("reg=CN/US conflict", self.fx.logged()[0])
        self.assertIn("no change", self.fx.logged()[0])
        self.assertEqual(self.fx.store.read_text(), before)

    def test_both_same_is_case_insensitive(self):
        self.fx.set_uci("wireless.radio1.country", "US")
        self.fx.set_uci("wireless.radio2.country", "us")
        before = self.fx.store.read_text()
        result = self.fx.run()
        self.assert_run(result)
        self.assertEqual(self.fx.logged()[0].split(",")[0], "reg=US")
        self.assertEqual(self.fx.store.read_text(), before)

    def test_prefer_arbitrates_and_is_idempotent(self):
        self.fx.set_uci("wireless.radio1.country", "CN")
        self.fx.set_uci("wireless.radio2.country", "US")
        result = self.fx.run(prefer="us")
        self.assert_run(result)
        self.assertEqual(result.stdout, "")
        self.assertIn("kept radio2", self.fx.logged()[0])
        after_first = self.fx.store.read_text()
        self.assertIn("wireless.radio1.country=US\n", after_first)
        self.assertIn("wireless.radio2.country=US\n", after_first)
        self.assertEqual(after_first.count("wireless.radio1.country="), 1)

        result = self.fx.run(prefer="us")
        self.assert_run(result)
        self.assertEqual(result.stdout, "")
        self.assertIn("reg=US,", self.fx.logged()[0])
        self.assertEqual(self.fx.store.read_text(), after_first)

    def test_prefer_matching_neither_radio_changes_nothing(self):
        self.fx.set_uci("wireless.radio1.country", "CN")
        self.fx.set_uci("wireless.radio2.country", "JP")
        before = self.fx.store.read_text()
        result = self.fx.run(prefer="us")
        self.assert_run(result)
        self.assertIn("matches neither radio", self.fx.logged()[0])
        self.assertEqual(self.fx.store.read_text(), before)

    def test_dry_run_writes_nothing(self):
        self.fx.set_uci("wireless.radio1.country", "CN")
        self.fx.set_uci("wireless.radio2.country", "US")
        before = self.fx.store.read_text()
        result = self.fx.run("--dry-run", prefer="cn")
        self.assert_run(result, logs=0)
        self.assertIn("would set wireless.radio2.country=CN", result.stdout)
        self.assertIn("would log: reg=CN", result.stdout)
        self.assertEqual(self.fx.store.read_text(), before)

    def test_four_state_matrix_changes_nothing(self):
        """The four non-conflict uci states: log only, never write.

        This is the truth table enforced by the script, rows 1-4.
        Every row must leave the uci store byte-identical and log exactly one
        line: the switch must not "helpfully" fill in a country.
        """
        cases = [
            # (country1, country2, expected log prefix)
            ("", "", "reg=00 (no usable radio country)"),
            ("US", "", "reg=US (radio1 only)"),
            ("", "CN", "reg=CN (radio2 only)"),
            ("CN", "cn", "reg=CN,"),
        ]
        for country1, country2, expected in cases:
            with self.subTest(country1=country1, country2=country2):
                self.fx.set_uci("wireless.radio1.country", country1)
                self.fx.set_uci("wireless.radio2.country", country2)
                self.fx.set_uci("wireless.radio1.channel", "149")
                self.fx.set_uci("wireless.radio2.channel", "37")
                before = self.fx.store.read_text()
                result = self.fx.run()
                self.assert_run(result)
                self.assertTrue(self.fx.logged()[0].startswith(expected),
                                self.fx.logged()[0])
                self.assertEqual(self.fx.store.read_text(), before)

    def test_placeholder_00_is_treated_as_no_country(self):
        # '00' is what netifd/cfg80211 leave behind for "world domain"; it must
        # not be mistaken for a real two-letter country and arbitrated.
        self.fx.set_uci("wireless.radio1.country", "00")
        self.fx.set_uci("wireless.radio2.country", "US")
        before = self.fx.store.read_text()
        result = self.fx.run(prefer="us")
        self.assert_run(result)
        self.assertIn("reg=US (radio2 only)", self.fx.logged()[0])
        self.assertEqual(self.fx.store.read_text(), before)

    def test_prefer_cn_keeps_radio1(self):
        # Mirror of test_prefer_arbitrates_and_is_idempotent: the CN arm must
        # keep the radio that already holds CN and move the other one.
        self.fx.set_uci("wireless.radio1.country", "CN")
        self.fx.set_uci("wireless.radio2.country", "US")
        result = self.fx.run(prefer="cn")
        self.assert_run(result)
        self.assertIn("kept radio1", self.fx.logged()[0])
        self.assertIn("reg=CN,", self.fx.logged()[0])
        after = self.fx.store.read_text()
        self.assertIn("wireless.radio2.country=CN\n", after)
        self.assertEqual(after.count("wireless.radio2.country="), 1)

    def test_invalid_prefer_is_reported_then_warn_only_on_conflict(self):
        self.fx.set_uci("wireless.radio1.country", "CN")
        self.fx.set_uci("wireless.radio2.country", "US")
        before = self.fx.store.read_text()
        result = self.fx.run(prefer="jp")
        self.assert_run(result, logs=2)
        self.assertIn("ignoring REG_PREFER='jp'", self.fx.logged()[0])
        self.assertIn("no change", self.fx.logged()[1])
        self.assertEqual(self.fx.store.read_text(), before)

    def test_prefer_on_agreeing_radios_is_ignored(self):
        self.fx.set_uci("wireless.radio1.country", "US")
        self.fx.set_uci("wireless.radio2.country", "US")
        before = self.fx.store.read_text()
        result = self.fx.run(prefer="cn")
        self.assert_run(result)
        self.assertIn("REG_PREFER=CN ignored: radios already agree",
                      self.fx.logged()[0])
        self.assertEqual(self.fx.store.read_text(), before)

    def test_exported_ipkg_instroot_is_harmless(self):
        self.fx.set_uci("wireless.radio1.country", "US")
        self.fx.set_uci("wireless.radio2.country", "US")
        result = self.fx.run(ipkg_instroot="/tmp/fakeroot")
        self.assert_run(result)
        self.assertIn("reg=US", self.fx.logged()[0])


if __name__ == "__main__":
    unittest.main()
