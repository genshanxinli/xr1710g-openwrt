#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline checks for scripts/pcie-single-cut.sh against device evidence.

The switch reasons about one 32-bit register: 0x1fbe3418, i.e. pbus_csr base
0x1fbe3400 + 0x18.  Nothing in this repository states what the field means;
the only hard evidence is what the register reads on the box.  That reading was
captured from debugfs into fixtures/pbus_csr-1fbe3400.registers, and this test
binds the fixture to three independent facts so a drift in any one of them
fails here rather than on the bench:

  * the script's ADDR constant,
  * the pbus_csr reg base in target/linux/airoha/dts/an7581.dtsi,
  * the 0x7 field boundary the script enforces before it writes 0x0.

It then runs the script itself against a stubbed devmem/state file to prove
status/apply/restore work on the measured value, and that a value outside the
documented 0x7 field is refused.  /dev/mem and devmem are rewritten into the
fixture root, exactly like test_reg_arbitrate.py rewrites its paths.

Run from the repository root:

    python3 -m unittest scripts/tests/test_pcie_single_cut.py
"""

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(os.environ.get("PCIE_SINGLE_CUT_UNDER_TEST",
                    REPO_ROOT / "scripts/pcie-single-cut.sh"))
DTSI = REPO_ROOT / "target/linux/airoha/dts/an7581.dtsi"
FIXTURE = REPO_ROOT / "scripts/tests/fixtures/pbus_csr-1fbe3400.registers"

# devmem stub: the value lives in $DEVMEM_STATE as a decimal integer.
DEVMEM_STUB = """#!/bin/sh
# Minimal devmem stub: devmem ADDRESS WIDTH [VALUE]
state=$DEVMEM_STATE
if [ -z "$3" ]; then
	value=$(cat "$state")
	printf '0x%08x\\n' "$value"
	exit 0
fi
printf '%d\\n' "$3" > "$state"
"""


def parse_registers(path):
    """Return {offset: value} from a debugfs regmap registers dump."""
    out = {}
    for line in Path(path).read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        offset, value = line.split(":", 1)
        out[int(offset, 16)] = int(value.strip(), 16)
    return out


def script_constants(path):
    """Return the numeric script constants the switch is built on."""
    text = Path(path).read_text()
    return {name: int(value, 0) for name, value in
            re.findall(r"^(ADDR|CUT_OFF)=(0x[0-9a-fA-F]+|\d+)$", text,
                       re.MULTILINE)}


def dts_pbus_csr_base(path):
    """Return the pbus_csr reg base from the AN7581 dtsi."""
    match = re.search(
        r"pbus_csr:\s+syscon@\w+\s*\{(.*?)\};", Path(path).read_text(),
        re.DOTALL)
    assert match, "pbus_csr node not found in %s" % path
    match = re.search(r"reg\s*=\s*<0x0\s*0x([0-9a-fA-F]+)", match.group(1))
    assert match, "pbus_csr reg property unparsable in %s" % path
    return int(match.group(1), 16)


class DeviceEvidenceTest(unittest.TestCase):
    """The fixture must still match what the DTS and the script assume."""

    def setUp(self):
        self.regs = parse_registers(FIXTURE)
        self.consts = script_constants(SCRIPT)

    def test_fixture_covers_base_window(self):
        # The dtsi declares reg = <0x0 0x1fbe3400 0x0 0xff>, so 0x18 must be
        # inside the dump; a short dump would silently hide a moved register.
        self.assertEqual(min(self.regs), 0x0)
        self.assertGreaterEqual(max(self.regs), 0x18)
        self.assertEqual(len(self.regs), 63)

    def test_offset_18_reads_the_documented_field(self):
        value = self.regs[0x18]
        self.assertEqual(value, 0x7,
                         "device fixture no longer reads 0x7: 0x%x" % value)
        self.assertLessEqual(value, 0x7,
                             "value exceeds the 0x7 field the script allows")
        self.assertEqual(self.consts["CUT_OFF"], 0)

    def test_script_address_is_base_plus_offset(self):
        base = dts_pbus_csr_base(DTSI)
        self.assertEqual(base, 0x1fbe3400)
        self.assertEqual(self.consts["ADDR"], base + 0x18,
                         "script ADDR drifted from pbus_csr + 0x18")

    def test_no_dt_consumer_claims_offset_18(self):
        # Every mediatek,pbus-csr window in the dtsi stays below 0x18, which is
        # why nothing in-tree would save or restore this field: the switch is
        # operating on a register no driver owns.
        windows = re.findall(
            r"mediatek,pbus-csr = <&pbus_csr 0x([0-9a-fA-F]+) 0x([0-9a-fA-F]+)>;",
            DTSI.read_text())
        self.assertEqual(len(windows), 3)
        for low, high in windows:
            self.assertLess(int(high, 16), 0x18,
                            "a pbus_csr window now covers offset 0x18")


class ScriptRunTest(unittest.TestCase):
    """status/apply/restore against the measured value, with a devmem stub."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="pcie-single-cut-"))
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        stub = self.bin / "devmem"
        stub.write_text(DEVMEM_STUB)
        stub.chmod(0o755)

        self.state = self.tmp / "reg"
        self.state.write_text("%d\n" % parse_registers(FIXTURE)[0x18])
        self.mem = self.tmp / "mem"
        self.mem.write_text("")

        self.script = self.tmp / "pcie-single-cut.sh"
        text = SCRIPT.read_text().replace("MEM_DEV=/dev/mem", "MEM_DEV=%s"
                                          % self.mem)
        text, count = re.subn(r"(?m)^BACKUP_DIR=.*$",
                              "BACKUP_DIR=%s" % (self.tmp / "state"), text)
        self.assertEqual(count, 1, "BACKUP_DIR= line not found in the script")
        self.script.write_text(text)
        self.backup = self.tmp / "state" / "backup.txt"

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_script(self, *args):
        env = {"PATH": "%s:/usr/bin:/bin" % self.bin,
               "DEVMEM_STATE": str(self.state)}
        return subprocess.run(["sh", str(self.script)] + list(args), env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              universal_newlines=True)

    def test_status_prints_measured_value_and_writes_nothing(self):
        result = self.run_script("status")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(result.stdout, "0x1fbe3418 = 0x00000007\n")
        self.assertFalse(self.backup.exists())

    def test_apply_then_restore_round_trips_to_0x7(self):
        result = self.run_script("apply", "--confirm")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("verified: pcie_single_cut is off (0x0)", result.stdout)
        self.assertEqual(self.backup.read_text(), "0x00000007\n")
        self.assertEqual(self.state.read_text().strip(), "0")

        result = self.run_script("restore")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("verified: restored 0x00000007", result.stdout)
        self.assertEqual(self.state.read_text().strip(), str(0x7))

    def test_apply_refuses_a_value_outside_the_0x7_field(self):
        self.state.write_text("%d\n" % 0x9)
        result = self.run_script("apply", "--confirm")
        self.assertEqual(result.returncode, 1)
        self.assertIn("outside the documented 0x7", result.stderr)
        self.assertEqual(self.state.read_text().strip(), str(0x9))
        self.assertFalse(self.backup.exists())

    def test_apply_without_confirm_touches_nothing(self):
        before = self.state.read_text()
        result = self.run_script("apply")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.state.read_text(), before)
        self.assertFalse(self.backup.exists())

    def test_restore_without_a_backup_says_the_original_is_not_on_record(self):
        # A reboot (or the hang a bad register write can cause) erases tmpfs.
        # "run apply first" is then wrong advice in the dangerous direction:
        # apply would record the current value as the original.
        result = self.run_script("restore")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no record of the original", result.stderr)
        self.assertNotIn("run 'apply --confirm' first", result.stderr)
        self.assertFalse(self.backup.exists())


class StateDirTest(unittest.TestCase):
    """The saved original must outlive the boot it was taken in."""

    def test_backup_dir_is_persistent_and_private(self):
        text = SCRIPT.read_text()
        match = re.search(r"(?m)^BACKUP_DIR=(.*)$", text)
        self.assertIsNotNone(match, "BACKUP_DIR= line is missing")
        backup_dir = match.group(1)
        self.assertEqual(backup_dir, "/root/.pcie-single-cut",
                         "the saved original still lives on tmpfs: %r"
                         % backup_dir)
        self.assertIn('chmod 700 "$BACKUP_DIR"', text,
                      "the state dir holding the original is not made 0700")

    def test_doc_states_where_the_original_lives(self):
        text = SCRIPT.read_text()
        for needle in ("/root/.pcie-single-cut/backup.txt",
                       "/root/.pcie-single-cut/result.json"):
            self.assertTrue(needle in text,
                            "the header still documents the tmpfs path: "
                            "%s is not in the script" % needle)


if __name__ == "__main__":
    unittest.main()
