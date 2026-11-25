#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# hw-gap-report.sh - merge the wireless harnesses' "no-client" records into
# one table, grouped by the hardware each record is missing.
#
# Every harness that cannot measure writes a structured record (see
# scripts/wireless/lib/no-client.sh):
#
#   {"status": "no-client", "missing": "6ghz-eht-client",
#    "ticket": "48", "command": "sh scripts/wireless/6g-rx.sh ...",
#    "reason": "...", "criteria": ["..."]}
#
# This report answers the only question that matters while the hardware is
# missing: which single piece of hardware unblocks which tickets, and what
# exactly to run once it arrives.
#
# Two record locations are read:
#
#   <out>/result.json          the v1 record.  Accepted only when it really is
#                             a no-client record (schema wireless-no-client/v1
#                             and a no-client/blocked status); <out>/result.json
#                             is otherwise the measurement result of the run.
#   <out>/no-hardware/         the v2 records: result.json, precondition.json
#                             and arms/<arm>.json.  They carry a "cause" field.
#   <out>/no-client/result.json  the v1 compatibility path; still read, no
#                             longer written by the current harnesses.
#
# "status": "blocked" records are configuration blocks, not missing hardware:
# the board is there, the association cannot work until a setting changes.
# "6ghz-owe-mismatch" is the case that forced the split: hostapd upgrades an
# open band=6g AP to OWE + PMF(2), so the harness saw "no client" while the
# client was fine.
#
# The Cause column names why a run did not measure: missing-hardware,
# missing-tool, config-block, permission, environment, output-collision,
# precondition-mismatch, internal, interrupted.  A v1 record without a cause
# gets one derived from its status and key, so an old tree keeps reporting.
#
# Read-only: it only reads *.json files, writes nothing to disk.
#
# Usage:
#   sh scripts/wireless/hw-gap-report.sh [--strict] [--json] [--dir DIR]... [DIR...]
#
# With no directory the report scans scripts/perf-baselines/ and /tmp, where
# a skipped harness leaves its record (the fallback directory is
# /tmp/<script>-no-client.<timestamp>.<pid>).
#
# Exit status: 0 report printed (also when nothing was found), 1 a contract
# warning under --strict, 2 bad arguments.

set -eu

PROG=${0##*/}
JSON=0
STRICT=0

usage() {
	cat <<EOF
Usage: $PROG [--strict] [--json] [--dir DIR]... [DIR...]

Scan DIR trees (default: scripts/perf-baselines /tmp) for the no-client
records of the wireless harnesses and print one Markdown table grouped by the
"missing" item: tickets, harnesses, the command that unblocks them, a Class
column (hardware, configuration, mismatch, environment, permission, output,
failure) and the Cause that stopped the run.

--json    print the same report as one JSON object (schema hw-gap-report/v2)
--strict  exit 1 when an accepted record breaks the record contract (unknown
          cause, exit code that disagrees with the cause, status that
          disagrees with the legacy mapping, missing schema or cause)

Exit status: 0 report printed (also when nothing matched), 1 --strict found a
contract warning, 2 bad arguments.
EOF
}

case ${1:-} in
-h | --help)
	usage
	exit 0
	;;
esac

dirs=
while [ $# -gt 0 ]; do
	case $1 in
	--json)
		JSON=1
		shift
		;;
	--strict)
		STRICT=1
		shift
		;;
	--dir)
		shift
		[ $# -gt 0 ] || {
			printf '%s: --dir needs a directory\n' "$PROG" >&2
			exit 2
		}
		dirs="$dirs $1"
		shift
		;;
	--dir=*)
		dirs="$dirs ${1#*=}"
		shift
		;;
	-*)
		printf '%s: unknown option %s\n' "$PROG" "$1" >&2
		exit 2
		;;
	*)
		dirs="$dirs $1"
		shift
		;;
	esac
done

[ -n "$dirs" ] || dirs="scripts/perf-baselines /tmp"

command -v python3 >/dev/null 2>&1 || {
	printf '%s: python3 is required to read result.json\n' "$PROG" >&2
	exit 2
}

# One positional argument per directory (directory names may not contain
# whitespace; document that in usage rather than quoting a joined list).
set --
[ "$JSON" -eq 1 ] && set -- "$@" --json
[ "$STRICT" -eq 1 ] && set -- "$@" --strict
for _d in $dirs; do
	set -- "$@" "$_d"
done

exec python3 -c '
import json
import os
import sys

SCHEMA_V1 = "wireless-no-client/v1"
MEASURED_SCHEMAS = {
    "6g-rx/v1",
    "edca-6g-ab/v1",
    "bench-10g-unidirectional/v1",
}
MEASURED_PREFIXES = ("6g320-matrix/", "wireless-")
INTERRUPTED_EXITS = {129, 130, 143}

# cause -> (legacy status, outcome, exit)
CAUSES = {
    "missing-hardware": ("no-client", "not-measured", 3),
    "missing-tool": ("no-client", "not-measured", 2),
    "config-block": ("blocked", "not-measured", 2),
    "permission": ("blocked", "not-measured", 2),
    "environment": ("blocked", "not-measured", 2),
    "output-collision": ("blocked", "not-measured", 2),
    "precondition-mismatch": ("blocked", "not-measured", 4),
    "internal": ("failed", "measured", 1),
    "interrupted": ("interrupted", "not-measured", 130),
}

CONFIG_KEYS = {"6ghz-owe-mismatch", "6ghz-only-bss", "port-in-bridge"}
HARDWARE_KEYS = {"2.5g-peer"}
TOOL_KEYS = {"iperf3"}

CAUSE_CLASS = {
    "missing-hardware": "hardware",
    "missing-tool": "hardware",
    "config-block": "configuration",
    "precondition-mismatch": "mismatch",
    "environment": "environment",
    "permission": "permission",
    "output-collision": "output",
    "internal": "failure",
    "interrupted": "failure",
}
CLASS_ORDER = {
    "hardware": 0,
    "configuration": 1,
    "mismatch": 2,
    "environment": 3,
    "permission": 4,
    "output": 5,
    "failure": 6,
}


def candidates(dirs):
    """Yield (path, kind) for every file that could hold a gap record."""
    for base in dirs:
        if not os.path.isdir(base):
            continue
        for root, dirs_hit, names in os.walk(base):
            in_no_hardware = os.path.basename(root) == "no-hardware"
            in_arms = (os.path.basename(root) == "arms"
                       and os.path.basename(os.path.dirname(root)) == "no-hardware")
            for name in sorted(names):
                if not name.endswith(".json"):
                    continue
                if in_arms or in_no_hardware or name == "result.json":
                    yield os.path.join(root, name), root


def derive_cause(data):
    """The cause of a v1 record, from its status and key."""
    missing = data.get("missing") or ""
    if data.get("status") == "blocked":
        return "config-block"
    if missing in TOOL_KEYS:
        return "missing-tool"
    return "missing-hardware"


def is_measured_schema(schema):
    if not isinstance(schema, str) or not schema or schema == SCHEMA_V1:
        return False
    return schema in MEASURED_SCHEMAS or schema.startswith(MEASURED_PREFIXES)


def accept_v2(data, warnings):
    schema = data.get("schema")
    if not schema:
        warnings.append("missing schema")
    elif schema != SCHEMA_V1:
        warnings.append("unknown schema %r" % schema)
    cause = data.get("cause")
    if not cause:
        warnings.append("missing cause")
        data["cause"] = derive_cause(data)
        data["cause_source"] = "derived"
        return True
    if cause not in CAUSES:
        warnings.append("unknown cause %r" % cause)
    else:
        status, outcome, exit_code = CAUSES[cause]
        if data.get("outcome") is not None and data.get("outcome") != outcome:
            warnings.append("outcome %r for cause %s" % (data["outcome"], cause))
        if data.get("exit") is not None:
            valid_exits = INTERRUPTED_EXITS if cause == "interrupted" else {exit_code}
            if data.get("exit") not in valid_exits:
                warnings.append("exit %r for cause %s" % (data["exit"], cause))
        if data.get("status") is not None and data.get("status") != status:
            warnings.append("status %r for cause %s" % (data["status"], cause))
        data["outcome"] = outcome
        if not (cause == "interrupted" and data.get("exit") in INTERRUPTED_EXITS):
            data["exit"] = exit_code
    data["cause_source"] = "recorded"
    return True


def scan(dirs):
    stats = {"scanned": 0, "records": 0, "measured": 0, "invalid": 0,
             "ignored": 0, "duplicate": 0}
    records = []
    warnings = []
    seen = set()
    for path, root in candidates(dirs):
        stats["scanned"] += 1
        try:
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            stats["invalid"] += 1
            warnings.append("invalid record: %s" % path)
            continue
        if not isinstance(data, dict):
            stats["invalid"] += 1
            warnings.append("invalid record: %s" % path)
            continue

        v2_location = (os.path.basename(root) == "no-hardware"
                       or (os.path.basename(root) == "arms"
                           and os.path.basename(os.path.dirname(root)) == "no-hardware"))
        local_warnings = []
        if v2_location:
            accept = accept_v2(data, local_warnings)
        else:
            is_v1 = (data.get("schema") == SCHEMA_V1
                     and data.get("status") in ("no-client", "blocked"))
            if is_v1:
                data["cause"] = derive_cause(data)
                data["cause_source"] = "derived"
                accept = True
            else:
                # A measurement result, not a gap record: known, counted, and
                # never a warning.  Unknown schemas are only a --strict case.
                accept = False
                schema = data.get("schema")
                if is_measured_schema(schema):
                    stats["measured"] += 1
                elif schema == SCHEMA_V1:
                    if data.get("status") in ("ok", "partial"):
                        stats["measured"] += 1
                    else:
                        stats["invalid"] += 1
                        local_warnings.append("unexpected status %r" % data.get("status"))
                else:
                    stats["ignored"] += 1
                    local_warnings.append("unknown schema %r" % schema)
        if not accept:
            warnings.extend(local_warnings)
            continue

        data["_path"] = path
        key = (str(data.get("script") or ""), str(data.get("arm") or ""),
               os.path.basename(path), str(data.get("timestamp") or ""),
               str(data.get("cause") or ""), str(data.get("missing") or ""))
        if key in seen:
            stats["duplicate"] += 1
            continue
        seen.add(key)
        records.append(data)
        warnings.extend(local_warnings)

    stats["records"] = len(records)
    return records, stats, warnings


def tickets(items):
    return sorted({str(r.get("ticket") or "-") for r in items},
                  key=lambda t: (t == "-", t.zfill(8)))


def harnesses(items):
    return sorted({r.get("script") or "?" for r in items})


def causes(items):
    return sorted({r.get("cause") for r in items if r.get("cause")})


def klass(missing, items):
    if missing in HARDWARE_KEYS:
        return "hardware"
    legacy_blocked = any(
        r.get("cause_source") == "derived" and r.get("status") == "blocked"
        for r in items)
    if missing in CONFIG_KEYS or legacy_blocked:
        return "configuration"
    causes_hit = [CAUSE_CLASS[c] for c in causes(items) if c in CAUSE_CLASS]
    if causes_hit:
        return sorted(causes_hit, key=CLASS_ORDER.get)[0]
    return "hardware"


def build(records, dirs):
    by_missing = {}
    for record in records:
        by_missing.setdefault(record.get("missing") or "unknown", []).append(record)

    order = sorted(
        by_missing,
        key=lambda m: (-len(tickets(by_missing[m])), -len(by_missing[m]), m),
    )
    all_tickets = {str(r.get("ticket") or "-") for r in records} - {"-"}
    groups = []
    for missing in order:
        items = by_missing[missing]
        commands = sorted({(r.get("command") or "").strip() for r in items
                           if (r.get("command") or "").strip()})
        groups.append({
            "missing": missing,
            "class": klass(missing, items),
            "causes": causes(items),
            "tickets": tickets(items),
            "harnesses": harnesses(items),
            "commands": commands,
            "records": items,
        })
    return groups, all_tickets


def print_markdown(records, groups, all_tickets, stats):
    print("# Wireless hardware gap report")
    print()
    print("%d no-client record(s), %d missing hardware item(s), %d ticket(s) "
          "covered." % (len(records), len(groups), len(all_tickets)))
    config_keys = [g["missing"] for g in groups if g["class"] == "configuration"]
    if config_keys:
        print("%d of them are configuration blocks, not missing hardware: %s."
              % (len(config_keys), ", ".join("`%s`" % m for m in config_keys)))
    print()
    print("scanned: %(scanned)d files, %(records)d records, %(measured)d measured, "
          "%(invalid)d invalid, %(ignored)d ignored, %(duplicate)d duplicate"
          % stats)
    counts = {}
    for record in records:
        cause = record.get("cause") or "unknown"
        counts[cause] = counts.get(cause, 0) + 1
    if counts:
        print("not measured: %d (%s)" % (
            sum(counts.values()),
            ", ".join("%s %d" % (k, v) for k, v in
                      sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))),
        ))
    print()
    print("| Missing hardware | Tickets | Harnesses | Command once acquired | "
          "Class | Cause |")
    print("|---|---|---|---|---|---|")
    for group in groups:
        items = group["records"]
        missing = group["missing"]
        ticket_cell = ", ".join("#" + t for t in tickets(items) if t != "-") or "-"
        command_cell = "<br>".join("`%s`" % c for c in group["commands"]) or "-"
        print("| `%s` | %s | %s | %s | %s | %s |" % (
            missing, ticket_cell, ", ".join(harnesses(items)), command_cell,
            group["class"], ", ".join(causes(items))))
    print()
    for group in groups:
        missing = group["missing"]
        print("## `%s` (%s)" % (missing, group["class"]))
        print()
        items = sorted(by_missing_records(missing, records),
                       key=lambda r: (str(r.get("ticket") or ""), str(r.get("script") or "")))
        for record in items:
            print("- **#%s %s** - %s" % (
                record.get("ticket") or "-",
                record.get("script") or "?",
                record.get("reason") or "no reason recorded"))
            criteria = record.get("criteria") or []
            if criteria:
                print("  criteria: %s" % "; ".join(str(c) for c in criteria))
            if record.get("cause"):
                print("  cause: %s (%s)" % (record["cause"],
                                            record.get("cause_source") or "?"))
            if record.get("command"):
                print("  run: `%s`" % record["command"])
            print("  record: %s" % record["_path"])
        print()


def by_missing_records(missing, records):
    return [r for r in records if (r.get("missing") or "unknown") == missing]


def main(argv):
    as_json = "--json" in argv
    strict = "--strict" in argv
    dirs = [a for a in argv if not a.startswith("--")]
    if not dirs:
        dirs = ["scripts/perf-baselines", "/tmp"]

    records, stats, warnings = scan(dirs)
    if not records:
        if as_json:
            print(json.dumps({"schema": "hw-gap-report/v2", "stats": stats,
                              "records": [], "groups": [],
                              "warnings": warnings}, indent=2, sort_keys=False))
        else:
            print("# Wireless hardware gap report")
            print()
            print("No \"no-client\" record found under: %s" % ", ".join(dirs))
        for warning in warnings:
            print("warning: %s" % warning, file=sys.stderr)
        return 1 if (strict and warnings) else 0

    groups, all_tickets = build(records, dirs)
    if as_json:
        for record in records:
            record.pop("_records", None)
        print(json.dumps({
            "schema": "hw-gap-report/v2",
            "stats": stats,
            "records": records,
            "groups": [dict(g, records=[r["_path"] for r in g["records"]])
                       for g in groups],
            "warnings": warnings,
        }, indent=2, sort_keys=False))
    else:
        print_markdown(records, groups, all_tickets, stats)
    for warning in warnings:
        print("warning: %s" % warning, file=sys.stderr)
    return 1 if (strict and warnings) else 0


sys.exit(main(sys.argv[1:]))
' "$@"
