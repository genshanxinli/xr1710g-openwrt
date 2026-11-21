#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Structural/truth-table check for the tx_queue_data2_burst band gate (#18).

6 GHz must get ``tx_queue_data2_burst=2.0`` exactly like 5 GHz, while
2.4 GHz and 60 GHz must stay unset.  The ucode hostapd generator clears
``ieee80211ac`` for the 6 GHz band, so a gate written as "802.11ac and
hw_mode == 'a'" silently skips 6 GHz.  This test reads the two generator
sources (it does not run hostapd) and checks:

  * the ucode ``set_default`` call is guarded by a predicate that names both
    the 5 GHz and the 6 GHz band and excludes 2.4/60 GHz;
  * the predicate evaluates true/false on the three-arm truth table below;
  * shell fallback keeps its explicit ``band = "6g"`` default and keeps the
    2.4 GHz path out of it.

Run from the repository root:

    python3 scripts/tests/test_tx_burst_band.py

The test is expected to fail before the band-gate fix and pass after it.
"""

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
UCODE = REPO_ROOT / "package/network/config/wifi-scripts/files-ucode/usr/share/ucode/wifi/hostapd.uc"
SHELL = REPO_ROOT / "package/network/config/wifi-scripts/files/lib/netifd/wireless/mac80211.sh"

UCODE_CALL = "set_default(config, 'tx_queue_data2_burst', '2.0')"

# band, ieee80211ac, hw_mode -> burst default expected
TRUTH_TABLE = [
    ("2g", True, "g", False),
    ("5g", True, "a", True),
    ("5g", False, "a", False),  # HT-only 5 GHz kept its old no-burst behaviour
    ("6g", False, "a", True),   # ieee80211ac is cleared for 6 GHz
    ("60g", False, "ad", False),
]


def guards(text, needle):
    """Return the condition text of the nearest enclosing ``if (...)`` per hit."""
    lines = text.splitlines()
    found = []
    for i, line in enumerate(lines):
        if needle not in line:
            continue
        call_indent = len(line) - len(line.lstrip())
        j = i - 1
        while j >= 0:
            candidate = lines[j].strip()
            indent = len(lines[j]) - len(lines[j].lstrip())
            if candidate.startswith("if (") and indent < call_indent:
                cond = candidate
                while cond.rstrip().endswith(("||", "&&")):
                    j += 1
                    cond += " " + lines[j].strip()
                found.append(cond)
                break
            j -= 1
    return found


def eval_ucode_guard(cond, band, ac, hw_mode):
    expr = cond[len("if ("):].strip()
    if expr.endswith("{"):
        expr = expr[:-1].rstrip()
    if expr.endswith(")"):
        expr = expr[:-1]
    expr = expr.replace("config.band", repr(band))
    expr = expr.replace("config.ieee80211ac", str(bool(ac)))
    expr = expr.replace("config.hw_mode", repr(hw_mode))
    expr = expr.replace("&&", " and ").replace("||", " or ")
    return bool(eval(expr, {"__builtins__": {}}, {}))


def main():
    failures = []

    ucode = UCODE.read_text()
    shell = SHELL.read_text()

    ucode_guards = guards(ucode, UCODE_CALL)
    if len(ucode_guards) != 1:
        failures.append(
            f"ucode: expected exactly one guarded {UCODE_CALL!r}, found {len(ucode_guards)}"
        )
    elif ucode_guards:
        cond = ucode_guards[0]
        for label, wanted in [
            ("6 GHz branch", "'6g'"),
            ("5 GHz branch", "'5g'"),
            ("5 GHz keeps the 802.11ac gate", "ieee80211ac"),
        ]:
            if wanted not in cond:
                failures.append(f"ucode: predicate misses {label}: {cond}")
        for excluded in ("'2g'", "'60g'"):
            if excluded in cond:
                failures.append(f"ucode: predicate must exclude {excluded}: {cond}")

        for band, ac, hw_mode, expected in TRUTH_TABLE:
            got = eval_ucode_guard(cond, band, ac, hw_mode)
            if got != expected:
                failures.append(
                    "ucode: band=%s ieee80211ac=%s hw_mode=%s -> %s, want %s"
                    % (band, ac, hw_mode, got, expected)
                )

        if failures:
            print("ucode predicate:", cond)

    # shell fallback: explicit 6 GHz default, ac-gated 5 GHz default, no 2.4/60.
    shell_defaults = [
        line.strip() for line in shell.splitlines() if "set_default tx_burst 2.0" in line
    ]
    six_g = '[ "$band" = "6g" ] && set_default tx_burst 2.0'
    if six_g not in shell_defaults:
        failures.append(f"shell: missing 6 GHz default line: {six_g}")
    if len(shell_defaults) != 2:
        failures.append(
            f"shell: expected 2 tx_burst defaults (6g + 802.11ac), found {shell_defaults}"
        )
    for band in ("2g", "60g"):
        if any(f'"band" = "{band}"' in line for line in shell_defaults):
            failures.append(f"shell: {band} must not get a tx_burst default")

    if failures:
        print("FAIL scripts/tests/test_tx_burst_band.py")
        for failure in failures:
            print("  -", failure)
        return 1

    print("PASS scripts/tests/test_tx_burst_band.py")
    print("  three-arm: 2g=unset, 5g(ac)=2.0, 6g=2.0 (ucode + shell)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
