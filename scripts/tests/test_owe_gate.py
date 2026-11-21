#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""A 6 GHz AP forced to OWE must not be filed as a missing client (#347).

The incident: on the XR1710G the 6 GHz AP is configured open

    uci show wireless.default_radio2.encryption
    wireless.default_radio2.encryption='none'

but hostapd upgrades every band=6g BSS to OWE + PMF(2):

    iwinfo phy0.2-ap0 info | grep Encryption
              Encryption: OWE (CCMP)

An open-only client can therefore never associate, and seven harnesses
(#43 #47 #48 #50 #66 #68 #89) reported the failed association as
"no client" - a purchase, not a setting.  Every one of those tickets was
blocked on the same wrong conclusion.

What is asserted here, with no device and no radio:

  * the live encryption is read (iwinfo, else ubus) and an OWE AP paired
    with an open band=6g wifi-iface raises the mismatch;
  * an SAE AP, or an OWE AP whose profile is already owe, does not;
  * the mismatch writes a ``status: blocked`` record with
    ``missing: 6ghz-owe-mismatch`` and one BLOCKED line carrying the exact
    uci fix, so a configuration block can never look like a measured skip;
  * hw-gap-report.sh lists 6ghz-owe-mismatch as its own row with
    Class=configuration, separate from the hardware rows;
  * the temporary 6 GHz BSS of the T-type harnesses stays OWE/SAE + PMF.

Red halves of the proof (both reproduced in the PR body):

  a) ``sed 's/encryption=owe/encryption=none/'`` into a copy of 6g-rx.sh and

         SIXG_RX_UNDER_TEST=<copy> python3 -m unittest scripts.tests.test_owe_gate

     fails on the temporary-BSS assertion;

  b) delete the body of ``nc_live_encryption`` in a copy of the shared
     library and

         NO_CLIENT_LIB_UNDER_TEST=<copy> python3 -m unittest scripts.tests.test_owe_gate

     fails because the mismatch is never seen.

Run from the repository root:

    python3 scripts/tests/test_owe_gate.py
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
LIB = Path(
    os.environ.get(
        "NO_CLIENT_LIB_UNDER_TEST",
        REPO_ROOT / "scripts/wireless/lib/no-client.sh",
    )
).resolve()
SIXG_RX = Path(
    os.environ.get(
        "SIXG_RX_UNDER_TEST", REPO_ROOT / "scripts/wireless/6g-rx.sh"
    )
).resolve()
GAP = REPO_ROOT / "scripts/wireless/hw-gap-report.sh"
WIRELESS = REPO_ROOT / "scripts/wireless"
SH = shutil.which("sh") or "/bin/sh"

OPEN_6G_UCI = """\
wireless.radio0=wifi-device
wireless.radio0.band='2g'
wireless.radio2=wifi-device
wireless.radio2.band='6g'
wireless.default_radio0=wifi-iface
wireless.default_radio0.device='radio0'
wireless.default_radio0.mode='ap'
wireless.default_radio0.encryption='psk2'
wireless.default_radio2=wifi-iface
wireless.default_radio2.device='radio2'
wireless.default_radio2.mode='ap'
wireless.default_radio2.ssid='open-6g'
wireless.default_radio2.encryption='none'
wireless.default_radio2.disabled='0'
"""

OWE_6G_UCI = OPEN_6G_UCI.replace(
    "wireless.default_radio2.encryption='none'",
    "wireless.default_radio2.encryption='owe'",
)

# The harnesses that file a no-client record, and must gate it on the live
# encryption first.  mlo-3link.sh is deliberately absent: its own 6 GHz BSS
# is SAE + PMF(2), so it never faces an OWE downgrade.
GATED = {
    "6g-rx.sh": "48",
    "6g-clear-air.sh": "68",
    "6g320-matrix.sh": "47",
    "edca-6g-ab.sh": "43",
    "multi-client.sh": "50",
    "irq-napi-ab.sh": "66",
}


def make_bindir(root: Path, encryption: str | None) -> Path:
    """A PATH whose iwinfo/uci answer from the environment, not the device."""
    bindir = root / "bin"
    bindir.mkdir()
    iwinfo = bindir / "iwinfo"
    iwinfo.write_text(
        "#!/bin/sh\n"
        '[ -n "${FAKE_ENCRYPTION:-}" ] || exit 1\n'
        'printf "\\tEncryption: %s\\n" "$FAKE_ENCRYPTION"\n'
    )
    iwinfo.chmod(0o755)
    uci = bindir / "uci"
    uci.write_text(
        "#!/bin/sh\n"
        '[ -n "${FAKE_UCI:-}" ] || exit 1\n'
        'cat "$FAKE_UCI"\n'
    )
    uci.chmod(0o755)
    for tool in ("awk", "basename", "cat", "date", "head", "mkdir", "mv",
                 "sed", "sh", "tr"):
        found = shutil.which(tool)
        if found is not None:
            (bindir / tool).symlink_to(found)
    return bindir


class LibHelperTest(unittest.TestCase):
    """The three new helpers, driven only by a fake iwinfo/uci."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="owe-gate."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bindir = make_bindir(self.tmp, "OWE (CCMP)")
        self.uci_file = self.tmp / "wireless"
        self.uci_file.write_text(OPEN_6G_UCI)

    def run_lib(self, snippet, encryption="OWE (CCMP)", uci=OPEN_6G_UCI):
        self.uci_file.write_text(uci)
        env = dict(os.environ)
        env["PATH"] = "%s:%s" % (self.bindir, env.get("PATH", ""))
        if encryption is None:
            env.pop("FAKE_ENCRYPTION", None)
        else:
            env["FAKE_ENCRYPTION"] = encryption
        env["FAKE_UCI"] = str(self.uci_file)
        env["LIB"] = str(LIB)
        proc = subprocess.run(
            [SH, "-c", '. "$LIB"\n' + snippet],
            env=env, capture_output=True, text=True, timeout=60,
        )
        return proc

    def test_live_encryption_is_read_from_iwinfo(self):
        proc = self.run_lib('nc_live_encryption phy0.2-ap0')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "OWE (CCMP)")

    def test_open_6ghz_section_is_found(self):
        proc = self.run_lib("nc_6ghz_open_sections")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.split(), ["default_radio2"],
                         "only the open band=6g AP counts")

    def test_owe_ap_with_open_profile_is_a_mismatch(self):
        proc = self.run_lib('nc_owe_mismatch phy0.2-ap0')
        self.assertEqual(proc.returncode, 0, "mismatch must be detectable")
        self.assertIn("live Encryption OWE (CCMP)", proc.stdout)
        self.assertIn("wireless.default_radio2.encryption is open", proc.stdout)
        self.assertIn("forces OWE + PMF(2)", proc.stdout)

    def test_sae_ap_is_not_a_mismatch(self):
        proc = self.run_lib('nc_owe_mismatch phy0.2-ap0',
                            encryption="SAE (CCMP)")
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertEqual(proc.stdout.strip(), "")

    def test_owe_profile_is_not_a_mismatch(self):
        proc = self.run_lib('nc_owe_mismatch phy0.2-ap0', uci=OWE_6G_UCI)
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertEqual(proc.stdout.strip(), "")

    def test_blocked_record_carries_the_uci_fix(self):
        out = self.tmp / "out"
        proc = self.run_lib(
            'nc_owe_mismatch_block "%s" 48 "$(nc_owe_mismatch phy0.2-ap0)"'
            % out
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("BLOCKED: phy0.2-ap0: live Encryption OWE", proc.stdout)
        self.assertIn("uci set wireless.default_radio2.encryption=owe",
                      proc.stdout)
        self.assertIn("uci set wireless.default_radio2.ieee80211w=2",
                      proc.stdout)
        record = json.loads((out / "result.json").read_text())
        self.assertEqual(record["status"], "blocked")
        self.assertEqual(record["missing"], "6ghz-owe-mismatch")
        self.assertEqual(record["ticket"], "48")
        self.assertEqual(record["schema"], "wireless-no-client/v1")
        self.assertIn("encryption=owe", record["command"])


class ScriptWiringTest(unittest.TestCase):
    """Every harness that can report a missing client checks OWE first."""

    def test_each_no_client_harness_reads_the_live_encryption(self):
        for name, ticket in GATED.items():
            path = WIRELESS / name
            text = path.read_text()
            with self.subTest(script=name):
                self.assertIn("nc_owe_mismatch", text,
                              "%s must read the live encryption (#%s)"
                              % (name, ticket))
                self.assertIn("nc_owe_mismatch_block", text,
                              "%s must report a blocked record (#%s)"
                              % (name, ticket))

    def test_temp_6ghz_bss_keeps_owe_and_pmf(self):
        """The T-type harness's own BSS must not fall back to open."""
        text = SIXG_RX.read_text()
        self.assertIn('uci set "wireless.$_sec.encryption=owe"', text,
                      "6g-rx.sh --add-bss must create an OWE BSS")
        self.assertIn('uci set "wireless.$_sec.ieee80211w=2"', text,
                      "6g-rx.sh --add-bss must pin PMF(2)")

    def test_temp_sae_bsses_keep_pmf(self):
        for name in ("6g-clear-air.sh", "mlo-3link.sh"):
            text = (WIRELESS / name).read_text()
            with self.subTest(script=name):
                self.assertIn("option encryption 'sae'", text)
                self.assertIn("option ieee80211w '2'", text)


class GapReportClassTest(unittest.TestCase):
    """A configuration block gets its own row, not the hardware row."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="owe-gap-report."))
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def write(self, sub, data):
        d = self.tmp / sub
        d.mkdir(parents=True)
        (d / "result.json").write_text(json.dumps(data))

    def run_report(self):
        proc = subprocess.run(
            [SH, str(GAP), "--dir", str(self.tmp)],
            capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout

    def rows(self, text):
        lines = text.splitlines()
        start = lines.index(
            "| Missing hardware | Tickets | Harnesses | "
            "Command once acquired | Class |")
        out = []
        for line in lines[start + 2:]:
            if not line.startswith("|"):
                break
            cells = [c.strip() for c in line.strip("|").split("|")]
            out.append(cells)
        return out

    def test_owe_mismatch_is_its_own_configuration_row(self):
        self.write("rx", {
            "schema": "wireless-no-client/v1", "script": "6g-rx.sh",
            "ticket": "48", "status": "no-client",
            "missing": "6ghz-eht-client", "command": "run it",
            "reason": "no 6G STA", "criteria": [],
        })
        self.write("owe", {
            "schema": "wireless-no-client/v1", "script": "6g-rx.sh",
            "ticket": "48", "status": "blocked",
            "missing": "6ghz-owe-mismatch",
            "command": "uci set wireless.default_radio2.encryption=owe; "
                       "uci set wireless.default_radio2.ieee80211w=2",
            "reason": "live Encryption OWE (CCMP)", "criteria": [],
        })
        text = self.run_report()
        rows = self.rows(text)
        by_missing = {r[0].strip("`"): r for r in rows}
        self.assertIn("6ghz-owe-mismatch", by_missing, text)
        self.assertEqual(by_missing["6ghz-owe-mismatch"][4], "configuration")
        self.assertEqual(by_missing["6ghz-eht-client"][4], "hardware")
        self.assertIn("ieee80211w=2", by_missing["6ghz-owe-mismatch"][3],
                      "the config row must carry the uci fix")
        self.assertNotIn("ieee80211w", by_missing["6ghz-eht-client"][3],
                         "the hardware row must not carry a uci fix")
        self.assertIn("configuration blocks, not missing hardware", text)
        self.assertIn("## `6ghz-owe-mismatch` (configuration)", text)

    def test_no_client_records_stay_hardware(self):
        self.write("a", {
            "schema": "wireless-no-client/v1", "script": "6g-rx.sh",
            "ticket": "48", "status": "no-client",
            "missing": "6ghz-eht-client", "command": "run it",
            "reason": "no 6G STA", "criteria": [],
        })
        text = self.run_report()
        rows = self.rows(text)
        self.assertEqual(rows[0][4], "hardware")
        self.assertNotIn("configuration blocks, not missing hardware", text)


if __name__ == "__main__":
    unittest.main()
