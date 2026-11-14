#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Unit tests for scripts/ppe-mem-account.py.

Run from the repository root with ``python3 -m unittest``; the package
markers in scripts/ and scripts/tests/ let discovery find this module.
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "ppe-mem-account.py"


def load_calculator():
    spec = importlib.util.spec_from_file_location(
        "ppe_mem_account", str(SCRIPT))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_cli(arguments, stdin_text=None):
    return subprocess.run(
        [sys.executable, str(SCRIPT)] + arguments,
        input=stdin_text,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
    )


class AccountingTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_calculator()

    def setUp(self):
        self.sample = dict(self.mod.SAMPLE)

    def test_normal_sample_matches_expected_account(self):
        result = self.mod.compute(self.mod.validate(self.sample))

        # 1.25 GB/s read + 1.25 GB/s write = 2.50 GB/s, which is
        # 54% of the 2.32 GB/s read path, 28% of the 4.40 GB/s write
        # path, and 29% of the 8.64 GB/s DDR peak.
        self.assertEqual(result["payload"]["total_gbps"], 2.5)
        self.assertAlmostEqual(
            result["utilization_pct"]["read_of_read_path"],
            1.25 / 2.32 * 100.0,
            places=6,
        )
        self.assertAlmostEqual(
            result["utilization_pct"]["write_of_write_path"],
            1.25 / 4.40 * 100.0,
            places=6,
        )
        self.assertAlmostEqual(
            result["utilization_pct"]["total_of_ddr_peak"],
            2.5 / 8.64 * 100.0,
            places=6,
        )
        self.assertEqual(
            result["utilization_pct_rounded"],
            {"read": 54, "write": 28, "total": 29},
        )
        self.assertEqual(
            result["over_100"],
            {"read": False, "write": False, "total": False},
        )

        # B6 at 8.5x: 10.625 GB/s per direction, 21.25 GB/s total.
        self.assertEqual(result["b6"]["read_bus_gbps"], 10.625)
        self.assertEqual(result["b6"]["write_bus_gbps"], 10.625)
        self.assertEqual(result["b6"]["total_bus_gbps"], 21.25)
        self.assertTrue(result["b6"]["over_100"]["read_path"])
        self.assertTrue(result["b6"]["over_100"]["write_path"])
        self.assertTrue(result["b6"]["over_100"]["total_peak"])

        tiers = result["ten_g_payload_tiers"]
        self.assertEqual(
            [item["payload_rate_gbit_s"] for item in tiers],
            [9.75, 9.28, 9.0],
        )
        self.assertTrue(all(item["base_fits"] for item in tiers))
        self.assertFalse(any(item["b6_fits"] for item in tiers))
        self.assertAlmostEqual(
            tiers[0]["payload_gbps_per_direction"], 9.75 / 8.0, places=6)
        self.assertAlmostEqual(
            tiers[0]["b6_total_bus_gbps"],
            2.0 * (9.75 / 8.0) * 8.5,
            places=6,
        )
        self.assertAlmostEqual(
            tiers[2]["b6_total_pct_of_ddr_peak"],
            2.0 * (9.0 / 8.0) * 8.5 / 8.64 * 100.0,
            places=6,
        )
        self.assertTrue(result["verdict"]["base_fits"])
        self.assertFalse(result["verdict"]["b6_fits"])

    def test_over_peak_inputs_are_flagged(self):
        data = dict(self.sample, payload_gbps=5.0)

        result = self.mod.compute(self.mod.validate(data))

        self.assertTrue(result["over_100"]["read"])
        self.assertTrue(result["over_100"]["write"])
        self.assertTrue(result["over_100"]["total"])
        self.assertFalse(result["verdict"]["base_fits"])
        self.assertGreater(
            result["b6"]["total_pct_of_ddr_peak"], 900.0)

    def test_missing_field_is_rejected(self):
        broken = dict(self.sample)
        del broken["read_gbps"]

        with self.assertRaisesRegex(self.mod.InputError, "read_gbps"):
            self.mod.validate(broken)

        proc = run_cli([], json.dumps(broken))
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("read_gbps", proc.stderr)

    def test_sample_json_and_human_output(self):
        sample = run_cli(["--sample"])
        self.assertEqual(sample.returncode, 0, sample.stderr)
        self.assertEqual(json.loads(sample.stdout), self.sample)

        machine = run_cli(["--json"], json.dumps(self.sample))
        self.assertEqual(machine.returncode, 0, machine.stderr)
        result = json.loads(machine.stdout)
        self.assertEqual(
            result["utilization_pct_rounded"],
            {"read": 54, "write": 28, "total": 29},
        )

        human = run_cli([], json.dumps(self.sample))
        self.assertEqual(human.returncode, 0, human.stderr)
        self.assertIn("1.250 GB/s read", human.stdout)
        self.assertIn("2.500 GB/s", human.stdout)
        self.assertIn("54%", human.stdout)
        self.assertIn("28%", human.stdout)
        self.assertIn("29%", human.stdout)
        self.assertIn("9.75 Gbit/s", human.stdout)
        self.assertIn("9.28 Gbit/s", human.stdout)
        self.assertIn("9.00 Gbit/s", human.stdout)
        self.assertIn("245.9% of DDR peak", human.stdout)
        self.assertIn("239.8% of peak", human.stdout)

    def test_input_file(self):
        handle, path = tempfile.mkstemp(prefix="ppe-mem-", suffix=".json")
        try:
            with os.fdopen(handle, "w", encoding="utf-8") as stream:
                json.dump(self.sample, stream)
            proc = run_cli(["--input", path])
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("rounded 29%", proc.stdout)
        finally:
            os.unlink(path)


if __name__ == "__main__":
    unittest.main()
