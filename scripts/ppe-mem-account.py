#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline B3/B6 memory accounting calculator for 10G unidirectional traffic.

This tool only does arithmetic and pass/fail accounting.  It does not
generate traffic, read any hardware counter, or replace a B3 (QDMA DRAM
read) or B6 (transaction amplification) measurement.  Feed it numbers from
a bench run and it makes the account reproducible.

Input JSON (stdin, or --input FILE; --sample prints an example):

  payload_gbps          L2 payload per direction, GB/s (required)
  read_gbps             measured sustained read-path peak, GB/s (required)
  write_gbps            measured sustained write-path peak, GB/s (required)
  bus_util_pct          measured DDR bus utilization, percent
                        (required; null means "not measured")
  transactions_per_byte B6 bus bytes per payload byte (required)
  mtu                   L2 MTU in bytes (required; null skips pps)
  ddr_peak_gbps         combined DDR peak, GB/s (optional, default 8.64)

The read and write percentages compare the per-direction payload with the
matching measured path peak (read_gbps / write_gbps).  The total percentage
compares payload_gbps * 2 with the combined DDR peak.  B6 multiplies the
payload by transactions_per_byte and repeats the same comparisons.

The three 10G payload-rate conventions from the ticket are 9.75, 9.28 and
9.0 Gbit/s: the 1500B framing geometric ceiling, the acceptance line (95.2%
of that ceiling) and the engineering line (92.3%).  Each tier is converted to
GB/s per direction (divide by 8) and the base and B6-amplified accounts are
re-evaluated at that payload rate.

Exit status: 0 on success, 2 on malformed or incomplete input.
"""

import argparse
import json
import math
import sys

DEFAULT_DDR_PEAK_GBPS = 8.64
# 10G payload-rate conventions: (Gbit/s, definition).
TEN_G_PAYLOAD_TIERS = (
    (9.75, "1500B framing geometric ceiling"),
    (9.28, "acceptance line"),
    (9.0, "engineering line"),
)
# Ethernet preamble+SFD (8) + IFG (12) + header (14) + FCS (4).
ETHERNET_OVERHEAD_BYTES = 38
SCHEMA = "ppe-mem-account/v1"

SAMPLE = {
    "payload_gbps": 1.25,
    "read_gbps": 2.32,
    "write_gbps": 4.40,
    "ddr_peak_gbps": DEFAULT_DDR_PEAK_GBPS,
    "bus_util_pct": 48.2,
    "transactions_per_byte": 8.5,
    "mtu": 1500,
}

REQUIRED_FIELDS = (
    "payload_gbps",
    "read_gbps",
    "write_gbps",
    "bus_util_pct",
    "transactions_per_byte",
    "mtu",
)

_MISSING = object()


class InputError(ValueError):
    """Malformed or incomplete input JSON."""


def pct(numerator, denominator):
    """Return numerator/denominator as a percentage."""
    return numerator / denominator * 100.0


def round_pct(value):
    """Round a positive percentage half up, e.g. 53.9 -> 54."""
    return int(value + 0.5)


def _number(data, key, minimum, exclusive=False, default=_MISSING):
    if key not in data:
        if default is _MISSING:
            raise InputError("missing required field: %s" % key)
        return float(default)

    value = data[key]
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise InputError("%s must be a number" % key)
    if not math.isfinite(value):
        raise InputError("%s must be finite" % key)
    if exclusive and value <= minimum:
        raise InputError("%s must be > %g" % (key, minimum))
    if not exclusive and value < minimum:
        raise InputError("%s must be >= %g" % (key, minimum))
    return float(value)


def validate(data):
    """Validate raw input and return a normalized dictionary."""
    if not isinstance(data, dict):
        raise InputError("input must be a JSON object")

    missing = [field for field in REQUIRED_FIELDS if field not in data]
    if missing:
        raise InputError("missing required field(s): %s" % ", ".join(missing))

    normalized = {
        "payload_gbps": _number(data, "payload_gbps", 0.0),
        "read_gbps": _number(data, "read_gbps", 0.0, exclusive=True),
        "write_gbps": _number(data, "write_gbps", 0.0, exclusive=True),
        "ddr_peak_gbps": _number(
            data, "ddr_peak_gbps", 0.0, exclusive=True,
            default=DEFAULT_DDR_PEAK_GBPS,
        ),
        "transactions_per_byte": _number(
            data, "transactions_per_byte", 0.0, exclusive=True,
        ),
    }

    bus_util = data["bus_util_pct"]
    if bus_util is None:
        normalized["bus_util_pct"] = None
    else:
        normalized["bus_util_pct"] = _number(data, "bus_util_pct", 0.0)

    mtu = data["mtu"]
    if mtu is None:
        normalized["mtu"] = None
    else:
        mtu_value = _number(data, "mtu", 0.0, exclusive=True)
        if mtu_value != int(mtu_value):
            raise InputError("mtu must be an integer number of bytes")
        normalized["mtu"] = int(mtu_value)

    return normalized


def compute(inp):
    """Compute the memory account for a normalized input dictionary."""
    payload = inp["payload_gbps"]
    read_path = inp["read_gbps"]
    write_path = inp["write_gbps"]
    peak = inp["ddr_peak_gbps"]
    transactions_per_byte = inp["transactions_per_byte"]

    base_total = payload * 2.0
    read_pct = pct(payload, read_path)
    write_pct = pct(payload, write_path)
    total_pct = pct(base_total, peak)

    b6_read = payload * transactions_per_byte
    b6_write = payload * transactions_per_byte
    b6_total = base_total * transactions_per_byte
    b6_read_pct = pct(b6_read, read_path)
    b6_write_pct = pct(b6_write, write_path)
    b6_total_pct = pct(b6_total, peak)

    tiers = []
    for rate_gbit_s, definition in TEN_G_PAYLOAD_TIERS:
        tier_payload = rate_gbit_s / 8.0
        tier_total = tier_payload * 2.0
        tier_read_pct = pct(tier_payload, read_path)
        tier_write_pct = pct(tier_payload, write_path)
        tier_total_pct = pct(tier_total, peak)
        tier_b6_read = tier_payload * transactions_per_byte
        tier_b6_write = tier_payload * transactions_per_byte
        tier_b6_total = tier_total * transactions_per_byte
        tier_b6_read_pct = pct(tier_b6_read, read_path)
        tier_b6_write_pct = pct(tier_b6_write, write_path)
        tier_b6_total_pct = pct(tier_b6_total, peak)
        tiers.append({
            "payload_rate_gbit_s": rate_gbit_s,
            "share_of_10g_pct": rate_gbit_s / 10.0 * 100.0,
            "definition": definition,
            "payload_gbps_per_direction": tier_payload,
            "read_pct_of_read_path": tier_read_pct,
            "write_pct_of_write_path": tier_write_pct,
            "total_pct_of_ddr_peak": tier_total_pct,
            "base_fits": (
                tier_read_pct <= 100.0
                and tier_write_pct <= 100.0
                and tier_total_pct <= 100.0
            ),
            "b6_read_bus_gbps": tier_b6_read,
            "b6_write_bus_gbps": tier_b6_write,
            "b6_total_bus_gbps": tier_b6_total,
            "b6_read_pct_of_read_path": tier_b6_read_pct,
            "b6_write_pct_of_write_path": tier_b6_write_pct,
            "b6_total_pct_of_ddr_peak": tier_b6_total_pct,
            "b6_fits": (
                tier_b6_read_pct <= 100.0
                and tier_b6_write_pct <= 100.0
                and tier_b6_total_pct <= 100.0
            ),
        })

    bus_util = None
    if inp["bus_util_pct"] is not None:
        observed_total = inp["bus_util_pct"] / 100.0 * peak
        bus_util = {
            "supplied_pct": inp["bus_util_pct"],
            "observed_total_gbps": observed_total,
            "observed_over_base_payload": (
                observed_total / base_total if base_total else None
            ),
            "observed_over_b6_demand": (
                observed_total / b6_total if b6_total else None
            ),
        }

    mtu_info = None
    if inp["mtu"] is not None:
        mtu = inp["mtu"]
        mtu_info = {
            "bytes": mtu,
            "pps_per_direction": payload * 1e9 / mtu,
            "transactions_per_packet": mtu * transactions_per_byte,
            "l2_payload_ceiling_at_10g_gbit_s": (
                10.0 * mtu / (mtu + ETHERNET_OVERHEAD_BYTES)
            ),
        }

    base_fits = (
        read_pct <= 100.0 and write_pct <= 100.0 and total_pct <= 100.0
    )
    b6_fits = (
        b6_read_pct <= 100.0
        and b6_write_pct <= 100.0
        and b6_total_pct <= 100.0
    )
    base_fits_all_tiers = all(item["base_fits"] for item in tiers)
    b6_fits_all_tiers = all(item["b6_fits"] for item in tiers)

    summary = "base account %s" % ("fits" if base_fits else "exceeds a limit")
    summary += "; B6-amplified demand %s" % (
        "fits" if b6_fits else "exceeds a limit"
    )
    summary += "; base account %s at all three 10G payload tiers" % (
        "fits" if base_fits_all_tiers else "does not fit"
    )
    summary += "; B6-amplified demand %s at all three 10G payload tiers" % (
        "fits" if b6_fits_all_tiers else "exceeds"
    )

    return {
        "schema": SCHEMA,
        "disclaimer": "offline arithmetic only; not a B3/B6 measurement",
        "input": inp,
        "payload": {
            "read_gbps": payload,
            "write_gbps": payload,
            "total_gbps": base_total,
        },
        "utilization_pct": {
            "read_of_read_path": read_pct,
            "write_of_write_path": write_pct,
            "read_of_ddr_peak": pct(payload, peak),
            "write_of_ddr_peak": pct(payload, peak),
            "total_of_ddr_peak": total_pct,
        },
        "utilization_pct_rounded": {
            "read": round_pct(read_pct),
            "write": round_pct(write_pct),
            "total": round_pct(total_pct),
        },
        "over_100": {
            "read": read_pct > 100.0,
            "write": write_pct > 100.0,
            "total": total_pct > 100.0,
        },
        "b6": {
            "transactions_per_byte": transactions_per_byte,
            "read_bus_gbps": b6_read,
            "write_bus_gbps": b6_write,
            "total_bus_gbps": b6_total,
            "read_pct_of_read_path": b6_read_pct,
            "write_pct_of_write_path": b6_write_pct,
            "total_pct_of_ddr_peak": b6_total_pct,
            "over_100": {
                "read_path": b6_read_pct > 100.0,
                "write_path": b6_write_pct > 100.0,
                "total_peak": b6_total_pct > 100.0,
            },
        },
        "bus_util": bus_util,
        "mtu": mtu_info,
        "ten_g_payload_tiers": tiers,
        "verdict": {
            "base_fits": base_fits,
            "b6_fits": b6_fits,
            "base_fits_all_ten_g_tiers": base_fits_all_tiers,
            "b6_fits_all_ten_g_tiers": b6_fits_all_tiers,
            "summary": summary,
        },
    }


def format_report(result):
    """Render the human-readable report."""
    payload = result["payload"]
    utilization = result["utilization_pct"]
    rounded = result["utilization_pct_rounded"]
    over = result["over_100"]

    lines = [
        "B3/B6 memory accounting (offline arithmetic only; not a measurement)",
        "",
        "payload: %.3f GB/s read + %.3f GB/s write = %.3f GB/s" % (
            payload["read_gbps"], payload["write_gbps"], payload["total_gbps"],
        ),
        "  read : %.3f GB/s / %.3f GB/s read path  = %.1f%% (rounded %d%%); %.1f%% of DDR peak" % (
            payload["read_gbps"], result["input"]["read_gbps"],
            utilization["read_of_read_path"], rounded["read"],
            utilization["read_of_ddr_peak"],
        ),
        "  write: %.3f GB/s / %.3f GB/s write path = %.1f%% (rounded %d%%); %.1f%% of DDR peak" % (
            payload["write_gbps"], result["input"]["write_gbps"],
            utilization["write_of_write_path"], rounded["write"],
            utilization["write_of_ddr_peak"],
        ),
        "  total: %.3f GB/s / %.3f GB/s DDR peak   = %.1f%% (rounded %d%%)" % (
            payload["total_gbps"], result["input"]["ddr_peak_gbps"],
            utilization["total_of_ddr_peak"], rounded["total"],
        ),
        "  over 100%%: read %s, write %s, total %s" % (
            _yes_no(over["read"]), _yes_no(over["write"]),
            _yes_no(over["total"]),
        ),
        "",
        "B6 transaction amplification (%.2fx):" % (
            result["b6"]["transactions_per_byte"],
        ),
        "  read : %.3f GB/s = %.1f%% of read path" % (
            result["b6"]["read_bus_gbps"],
            result["b6"]["read_pct_of_read_path"],
        ),
        "  write: %.3f GB/s = %.1f%% of write path" % (
            result["b6"]["write_bus_gbps"],
            result["b6"]["write_pct_of_write_path"],
        ),
        "  total: %.3f GB/s = %.1f%% of DDR peak -> %s" % (
            result["b6"]["total_bus_gbps"],
            result["b6"]["total_pct_of_ddr_peak"],
            "EXCEEDS" if result["b6"]["over_100"]["total_peak"] else "fits",
        ),
    ]

    if result["bus_util"] is not None:
        bus = result["bus_util"]
        lines.extend([
            "",
            "measured bus utilization: %.2f%% -> %.3f GB/s observed" % (
                bus["supplied_pct"], bus["observed_total_gbps"],
            ),
            "  observed / base total = %.2fx; observed / B6 total = %.3fx" % (
                bus["observed_over_base_payload"] or 0.0,
                bus["observed_over_b6_demand"] or 0.0,
            ),
        ])

    if result["mtu"] is not None:
        mtu = result["mtu"]
        lines.extend([
            "",
            "MTU %d B: %.0f pps per direction, %.0f bus transactions per packet" % (
                mtu["bytes"], mtu["pps_per_direction"],
                mtu["transactions_per_packet"],
            ),
            "  10G L2 payload ceiling at this MTU: %.3f Gbit/s" % (
                mtu["l2_payload_ceiling_at_10g_gbit_s"],
            ),
        ])

    lines.extend([
        "",
        "10G payload-rate tiers (Gbit/s; the memory account at each):",
    ])
    for item in result["ten_g_payload_tiers"]:
        lines.append(
            "  %.2f Gbit/s (%.1f%% of 10G; %s):" % (
                item["payload_rate_gbit_s"], item["share_of_10g_pct"],
                item["definition"],
            )
        )
        lines.append(
            "    payload %.3f GB/s/dir; read %.1f%% of path, write %.1f%% "
            "of path, total %.1f%% of peak (%s)" % (
                item["payload_gbps_per_direction"],
                item["read_pct_of_read_path"],
                item["write_pct_of_write_path"],
                item["total_pct_of_ddr_peak"],
                "fits" if item["base_fits"] else "exceeds",
            )
        )
        lines.append(
            "    B6 %.3f GB/s total = %.1f%% of peak (%s)" % (
                item["b6_total_bus_gbps"],
                item["b6_total_pct_of_ddr_peak"],
                "fits" if item["b6_fits"] else "exceeds",
            )
        )

    lines.extend(["", "verdict: %s" % result["verdict"]["summary"]])
    return "\n".join(lines) + "\n"


def _yes_no(value):
    return "yes" if value else "no"


def load_input(path):
    """Read JSON from path, or stdin when path is None or '-'."""
    if path is None or path == "-":
        if sys.stdin.isatty():
            raise InputError(
                "no input JSON: pipe it on stdin or use --input FILE "
                "(or --sample)"
            )
        try:
            raw = sys.stdin.read()
        except OSError as exc:
            raise InputError("cannot read stdin: %s" % exc)
        source = "stdin"
    else:
        try:
            with open(path, "r", encoding="utf-8") as handle:
                raw = handle.read()
        except OSError as exc:
            raise InputError("cannot read %s: %s" % (path, exc))
        source = path

    try:
        return json.loads(raw)
    except ValueError as exc:
        raise InputError("invalid JSON from %s: %s" % (source, exc))


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=(
            "Offline B3/B6 memory accounting calculator. It only does "
            "arithmetic; it does not measure B3 or B6."
        ),
        epilog="Use --sample to print an example input JSON.",
    )
    parser.add_argument(
        "--input", metavar="FILE",
        help="read input JSON from FILE instead of stdin; '-' means stdin",
    )
    parser.add_argument(
        "--sample", action="store_true",
        help="print an example input JSON and exit",
    )
    parser.add_argument(
        "--json", action="store_true",
        help="print the machine-readable result JSON",
    )
    args = parser.parse_args(argv)

    if args.sample:
        print(json.dumps(SAMPLE, indent=2))
        return 0

    try:
        result = compute(validate(load_input(args.input)))
    except InputError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        sys.stdout.write(format_report(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
