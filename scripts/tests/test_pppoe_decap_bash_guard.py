#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Guards for scripts/pppoe-decap-hw-bench.sh (issue #70 and its verdict math).

Three things are pinned here, all offline:

  * `sh <script>` must reach bash, not the parser.  The body is bash
    (declare -A, arrays); called through `sh` it used to die at the first
    bash-only line with

        syntax error: unexpected "("

    before any guard could run.  The script now says `#!/usr/bin/env bash`
    (it was a `#!/bin/sh` label on a bash body, which every `sh -n` sweep
    reported as a syntax error) and still re-execs under bash, so a
    `sh <script>` call has to print normal usage instead.
  * `verdict` must fold in the caller's failure accumulator.  It used to keep
    its own `rc`, so a failed `restore_knob` still wrote `# verdict PASS` into
    the TSV the diff consumes while the process exited 1.  Folding `rc` into
    the TSV alone left the say() line printing `verdict: PASS`, so a log with
    a failed restore told the operator the opposite of the TSV.
  * `softirq_us_per_wire` must not divide by the core count.  The old
    `share * secs * 1e6 / wire` used the *aggregate* `cpu ` line, so it
    algebraically equalled `soft_ticks * 1e6 / (ncpu * HZ * wire)`: a 4-core
    board under-reported 4x, and USER_HZ=100 was assumed.

Run from the repository root:

    python3 scripts/tests/test_pppoe_decap_bash_guard.py
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get(
        "PPPOE_BENCH_UNDER_TEST",
        REPO_ROOT / "scripts/pppoe-decap-hw-bench.sh",
    )
)


def extract_function(text, name):
    """Return the body of `name() { ... }` from text, or None."""
    lines = text.splitlines()
    for start, line in enumerate(lines):
        if line.startswith("%s() {" % name):
            break
    else:
        return None
    depth = 0
    body = []
    for line in lines[start:]:
        body.append(line)
        depth += line.count("{") - line.count("}")
        if depth == 0 and len(body) > 1:
            return "\n".join(body)
    return None


def run_bash(source):
    with tempfile.TemporaryDirectory(prefix="pppoe-bench-guard-") as tmp:
        path = Path(tmp) / "harness.sh"
        path.write_text(source)
        return subprocess.run(
            ["bash", str(path)],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )


class BashGuardTest(unittest.TestCase):
    def test_sh_call_prints_usage_instead_of_a_syntax_error(self):
        sh = shutil.which("sh")
        if sh is None or shutil.which("bash") is None:
            self.skipTest("sh and bash are required")
        result = subprocess.run(
            [sh, str(SCRIPT), "--help"],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Usage: pppoe-decap-hw-bench.sh", result.stdout)
        self.assertNotIn("syntax error", result.stderr)


class VerdictTest(unittest.TestCase):
    """A failed knob restore must not leave `# verdict PASS` in the TSV."""

    def harness(self, verdict_call, tsv_path):
        text = SCRIPT.read_text(encoding="utf-8")
        body = extract_function(text, "verdict")
        self.assertIsNotNone(body, "verdict() is missing from the script")
        return (
            "say() { printf '%s\\n' \"$*\"; }\n"
            "declare -A ARM_N=() ARM_BND=() ARM_BIT23=() ARM_BND23=() ARM_STATUS=()\n"
            'OUT="' + str(tsv_path) + '"\n'
            ': >"$OUT"\n'
            "ARM_N[1]=10; ARM_BND[1]=10; ARM_BIT23[1]=0; ARM_BND23[1]=10;"
            " ARM_STATUS[1]=ok\n"
            + body + "\n"
            + verdict_call + "\n"
            'printf \'verdict_rc=%s\\n\' "$?"\n'
        )

    def run_verdict(self, verdict_call):
        with tempfile.TemporaryDirectory(prefix="pppoe-verdict-") as tmp:
            tsv = Path(tmp) / "out.tsv"
            result = run_bash(self.harness(verdict_call, tsv))
            self.assertEqual(result.returncode, 0, result.stderr)
            written = tsv.read_text(encoding="utf-8") if tsv.exists() else ""
            return result, written

    def test_a_clean_arm_still_reports_pass(self):
        result, written = self.run_verdict("verdict 0")
        self.assertIn("verdict_rc=0", result.stdout)
        self.assertIn("verdict: PASS", result.stdout)
        self.assertIn("# verdict PASS", written)

    def test_a_failed_restore_turns_the_verdict_into_fail(self):
        # `restore_knob || rc=1` in main is exactly this input.
        result, written = self.run_verdict("verdict 1")
        self.assertIn("verdict_rc=1", result.stdout,
                      "verdict() returned success after a failed restore")
        self.assertNotIn("# verdict PASS", written,
                         "the TSV still records PASS while the run failed")
        self.assertIn("# verdict FAIL", written)
        # The log is the artifact the operator reads; it must not contradict
        # the TSV just because the arms themselves looked good.
        self.assertNotIn("verdict: PASS", result.stdout,
                         "the human-readable line still says PASS on a failed run")
        self.assertIn("verdict: FAIL - decap=1", result.stdout)

    def test_main_passes_its_accumulator_to_verdict(self):
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertTrue('verdict "$rc" || rc=1' in text,
                        "main still calls verdict() without its rc")


class SoftirqCostTest(unittest.TestCase):
    """us per wire packet must come from the softirq delta, not ncpu."""

    def test_function_exists_and_matches_the_algebra(self):
        text = SCRIPT.read_text(encoding="utf-8")
        body = extract_function(text, "softirq_us_per_wire")
        self.assertIsNotNone(
            body,
            "softirq_us_per_wire() is missing: us still derives from the "
            "aggregate cpu share and is divided by ncpu",
        )
        result = run_bash(body + """
printf '%s\\n' "$(softirq_us_per_wire 10000 1000 100)"
printf '%s\\n' "$(softirq_us_per_wire 10000 1000 1000)"
softirq_us_per_wire 10000 0 100 || printf 'zero-wire-refused\\n'
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.split()
        # 10000 ticks / 100 Hz = 100 s of softirq over 1000 packets = 100000 us.
        self.assertEqual(lines[0], "100000.00")
        self.assertEqual(lines[1], "10000.00")
        self.assertEqual(lines[2], "zero-wire-refused")

    def test_run_arm_uses_the_function_and_the_clock_tick(self):
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertTrue(
            'softirq_us_per_wire "$soft_ticks" "$wire_pkts" "$BENCH_HZ"' in text,
            "run_arm still scales the cpu share")
        self.assertTrue("sh * sec * 1000000 / w" not in text,
                        "the aggregate-share formula is still there")
        self.assertTrue("CLK_TCK" in text, "USER_HZ is still assumed to be 100")


if __name__ == "__main__":
    unittest.main()
