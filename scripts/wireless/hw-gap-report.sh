#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# hw-gap-report.sh - merge the wireless harnesses' "no-client" records into
# one table, grouped by the hardware each record is missing.
#
# Every harness that cannot measure because the board has no client writes a
# structured result.json (see scripts/wireless/lib/no-client.sh):
#
#   {"status": "no-client", "missing": "6ghz-eht-client",
#    "ticket": "48", "command": "sh scripts/wireless/6g-rx.sh ...",
#    "reason": "...", "criteria": ["..."]}
#
# This report answers the only question that matters while the hardware is
# missing: which single piece of hardware unblocks which tickets, and what
# exactly to run once it arrives.
#
# Read-only: it only reads result.json files, writes nothing to disk.
#
# Usage:
#   sh scripts/wireless/hw-gap-report.sh [--dir DIR]... [DIR...]
#
# With no directory the report scans scripts/perf-baselines/ and /tmp, where
# a skipped harness leaves its record (the fallback directory is
# /tmp/<script>-no-client.<timestamp>.<pid>).
#
# Exit status: 0 report printed (also when nothing was found), 2 bad
# arguments.

set -eu

PROG=${0##*/}

usage() {
	cat <<EOF
Usage: $PROG [--dir DIR]... [DIR...]

Scan DIR trees (default: scripts/perf-baselines /tmp) for result.json files
whose "status" is "no-client" and print one Markdown table grouped by the
"missing" hardware, with the tickets, the harnesses and the command to run
once that hardware is available.

Exit status: 0 report printed (also when nothing matched), 2 bad arguments.
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
for _d in $dirs; do
	set -- "$@" "$_d"
done

exec python3 -c '
import json
import os
import sys

def records_in(dirs):
    for base in dirs:
        if not os.path.isdir(base):
            continue
        for root, _dirs, names in os.walk(base):
            if "result.json" in names:
                path = os.path.join(root, "result.json")
                try:
                    with open(path, encoding="utf-8") as fh:
                        data = json.load(fh)
                except (OSError, ValueError):
                    continue
                if isinstance(data, dict) and data.get("status") == "no-client":
                    data["_path"] = path
                    yield data

def main(dirs):
    records = list(records_in(dirs))
    if not records:
        print("# Wireless hardware gap report")
        print()
        print("No \"no-client\" record found under: %s" % ", ".join(dirs))
        return 0

    by_missing = {}
    for record in records:
        by_missing.setdefault(record.get("missing") or "unknown", []).append(record)

    def tickets(items):
        return sorted({str(r.get("ticket") or "-") for r in items},
                      key=lambda t: (t == "-", t.zfill(8)))

    def harnesses(items):
        return sorted({r.get("script") or "?" for r in items})

    order = sorted(
        by_missing,
        key=lambda m: (-len(tickets(by_missing[m])), -len(by_missing[m]), m),
    )
    all_tickets = {str(r.get("ticket") or "-") for r in records} - {"-"}

    print("# Wireless hardware gap report")
    print()
    print("%d no-client record(s), %d missing hardware item(s), %d ticket(s) "
          "covered." % (len(records), len(order), len(all_tickets)))
    print()
    print("| Missing hardware | Tickets | Harnesses | Command once acquired |")
    print("|---|---|---|---|")
    for missing in order:
        items = by_missing[missing]
        ticket_cell = ", ".join("#" + t for t in tickets(items) if t != "-") or "-"
        commands = sorted({(r.get("command") or "").strip() for r in items
                           if (r.get("command") or "").strip()})
        command_cell = "<br>".join("`%s`" % c for c in commands) or "-"
        print("| `%s` | %s | %s | %s |" % (
            missing, ticket_cell, ", ".join(harnesses(items)), command_cell))
    print()
    for missing in order:
        print("## `%s`" % missing)
        print()
        items = sorted(by_missing[missing],
                       key=lambda r: (str(r.get("ticket") or ""), str(r.get("script") or "")))
        for record in items:
            print("- **#%s %s** - %s" % (
                record.get("ticket") or "-",
                record.get("script") or "?",
                record.get("reason") or "no reason recorded"))
            criteria = record.get("criteria") or []
            if criteria:
                print("  criteria: %s" % "; ".join(str(c) for c in criteria))
            if record.get("command"):
                print("  run: `%s`" % record["command"])
            print("  record: %s" % record["_path"])
        print()
    return 0

sys.exit(main([p for p in sys.argv[1:] if p]))
' "$@"
