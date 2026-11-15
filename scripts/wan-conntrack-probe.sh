#!/bin/sh
#
# SPDX-License-Identifier: GPL-2.0-only
#
# wan-conntrack-probe.sh - port-scoped [HW_OFFLOAD] probe plus a clear that
# cannot silently no-op.
#
# Corroborating tool only, no offload-rate conclusion:
#   [HW_OFFLOAD] in /proc/net/nf_conntrack is the one independent,
#   port-scoped corroboration that a flow is offloaded.  It is a time-domain
#   quantity: a line either carries the marker or it does not at the instant
#   it is read, so neither ct_lines nor with_offload says anything about an
#   offload *rate*.  Do not turn this output into an offload-rate claim
#   (docs/wan-limit-2026-11-14/01-claim-audit.md C12).
#
# Why the clear is fail-loud:
#   docs/wan-limit-2026-11-14/06-reproducibility.md F4/D4: this image is
#   built without the conntrack applet (CONFIG_PACKAGE_conntrack is not
#   set), so the old clear discarded conntrack -F's output and error text
#   and was a silent no-op: "clear before every round" never actually
#   happened, and a whole batch of measurement arms was invalidated by it.
#   This script therefore never suppresses a clear failure: a missing
#   conntrack applet prints CLEAR_METHOD=ABSENT and exits 7, and the
#   flowtable state is read back after every attempted clear.
#
# Probe (read-only, /proc/net/nf_conntrack only):
#   For each sport/dport pair, count the /proc/net/nf_conntrack lines that
#   carry sport=<sport> and dport=<dport> in one tuple.  A two-way flow is
#   listed with both tuple directions, so a spec written as the reply
#   direction (dport/sport) matches the same flow; a side may be "*" (any
#   port).  Of the matched lines, count those containing "[HW_OFFLOAD]".
#   One TSV row per pair:
#
#       arm<TAB>ports<TAB>ct_lines<TAB>with_offload
#
#   An unreadable /proc/net/nf_conntrack prints PROBE=unavailable and exits
#   3; it is never reported as a row of zeroes.  The probe does not run nft
#   and writes nothing except the optional --out TSV.
#
# Clear (fail-loud):
#   --clear resolves the applet with "command -v conntrack".  If it is
#   absent, print CLEAR_METHOD=ABSENT and exit 7; nothing is written.
#   Otherwise run "conntrack -F" with its output and error text visible,
#   then read back "nft list flowtables" and /sys/kernel/debug/ppe/usage.
#   The flowtable-side fallback "nft flush flowtable inet fw4 ft" runs only
#   when conntrack -F fails; a failed conntrack -F makes the clear fail even
#   when the fallback itself works, because conntrack entries can remain
#   behind.  A failed flush or readback is reported as a failure, not a
#   warning.
#
#   nftables 1.1.7, the version this tree ships, has no "flush flowtable"
#   command (its "flow table" is the legacy name of the meter object), so
#   the fallback is a fail-loud path (FLOWTABLE_FLUSH=failed,
#   CLEAR_STATUS=failed, exit 8) rather than an alternative clear.  The
#   primary conntrack path and the readbacks are unaffected; an arm whose
#   clear failed must not be treated as clear.
#
# Usage:
#   ./scripts/wan-conntrack-probe.sh --ports 5201/5201 --arm baseline \
#       --out /tmp/nf-conntrack.tsv
#   ./scripts/wan-conntrack-probe.sh --ports '5201/5201,*/5201' --dry-run
#   ./scripts/wan-conntrack-probe.sh --clear
#   ./scripts/wan-conntrack-probe.sh --clear --ports 5201/5201 --arm after-clear
#
#   --ports is a comma- or space-separated list of sport/dport pairs.  A
#   side may be "*" (any port); "*/*" is rejected.
#   --out appends TSV rows (and a header when the file is empty); without
#   --out the TSV goes to stdout.
#   --dry-run prints the plan, exits 0, reads neither /proc nor an --out
#   file, and performs no write.
#   --clear clears only; with --ports it clears first and then probes.
#
#   CONNTRACK_FILE and PPE_USAGE are offline test hooks; the defaults are
#   the device paths /proc/net/nf_conntrack and
#   /sys/kernel/debug/ppe/usage.
#
# Exit status:
#   0  probe/clear finished; 2  invalid arguments; 3  probe file
#   unavailable; 7  --clear aborted because conntrack is absent;
#   8  --clear failed (flush or readback); 1  --out could not be written.
#
# POSIX sh only (busybox ash on the device).  The probe changes nothing;
# --clear writes only kernel state through conntrack/nft.  Nothing here
# connects over ssh or edits device configuration.

set -u
set -f
LC_ALL=C
export LC_ALL
umask 077

PROG=${0##*/}
CONNTRACK_FILE=${CONNTRACK_FILE:-/proc/net/nf_conntrack}
PPE_USAGE=${PPE_USAGE:-/sys/kernel/debug/ppe/usage}

ARM=unlabeled
OUT_FILE=
PORTS_RAW=
CLEAR_MODE=0
DRY_RUN=0

usage() {
	cat <<EOF
Usage: $PROG --ports <sport/dport list> [--arm <name>] [--out <tsv>] [--dry-run]
       $PROG --clear [--ports <sport/dport list>] [--arm <name>] [--out <tsv>] [--dry-run]

Read-only port probe of /proc/net/nf_conntrack and a fail-loud flowtable
clear.  [HW_OFFLOAD] is a time-domain marker, not an offload rate.

  --ports <list>  comma/space-separated sport/dport pairs; a side may be
                  '*' for any port.  Required for a probe; with --clear
                  the script clears first and then probes.
  --arm <name>    arm label written to the TSV (default: unlabeled).
  --out <tsv>     append TSV rows to <tsv>, with a header when the file is
                  empty; default stdout.
  --clear         clear conntrack and the fw4 flowtable; a missing
                  conntrack applet is CLEAR_METHOD=ABSENT and exit 7.
  --dry-run       print the probe/clear plan; read and write nothing.
  --help          print this help.

Exit status: 0 ok, 2 invalid arguments, 3 probe file unavailable,
7 clear method absent, 8 clear failure, 1 --out write failure.
CONNTRACK_FILE and PPE_USAGE are offline test hooks for the probe file and
the PPE usage readback.
EOF
}

need_value() {
	if [ "$#" -lt 2 ]; then
		printf '%s: %s needs a value\n' "$PROG" "$1" >&2
		usage >&2
		exit 2
	fi
}

out_fail() {
	printf '%s: cannot write %s\n' "$PROG" "$OUT_FILE" >&2
	exit 1
}

probe_header() {
	if [ -n "$OUT_FILE" ]; then
		if [ ! -s "$OUT_FILE" ]; then
			printf 'arm\tports\tct_lines\twith_offload\n' >>"$OUT_FILE" || out_fail
		fi
	else
		printf 'arm\tports\tct_lines\twith_offload\n'
	fi
}

probe_row() {
	if [ -n "$OUT_FILE" ]; then
		printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$OUT_FILE" || out_fail
	else
		printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"
	fi
}

print_clear_plan() {
	CT_BIN=$(command -v conntrack)
	NFT_BIN=$(command -v nft)
	printf 'CLEAR_DRY_RUN=1\n'
	printf 'CLEAR_PLAN_BEGIN\n'
	if [ -z "$CT_BIN" ]; then
		printf '# conntrack: absent; a real --clear prints CLEAR_METHOD=ABSENT and exits 7\n'
	else
		printf '# conntrack: %s\n' "$CT_BIN"
	fi
	if [ -z "$NFT_BIN" ]; then
		printf '# nft: absent; a real --clear would exit 8 without flushing\n'
	else
		printf '# nft: %s\n' "$NFT_BIN"
	fi
	printf 'conntrack -F\n'
	printf '# only when conntrack -F fails, the flowtable-side fallback:\n'
	printf 'nft flush flowtable inet fw4 ft\n'
	printf 'nft list flowtables\n'
	printf 'cat %s\n' "$PPE_USAGE"
	printf 'CLEAR_PLAN_END\n'
}

print_probe_plan() {
	printf 'PROBE_DRY_RUN=1\n'
	printf 'PROBE_PLAN_BEGIN\n'
	printf 'PROBE_FILE=%s\n' "$CONNTRACK_FILE"
	printf 'PROBE_MATCH=one tuple carries sport=<sport> and dport=<dport>; the reply direction matches too\n'
	printf 'PROBE_COUNT=matched lines that contain [HW_OFFLOAD]\n'
	if [ -n "$OUT_FILE" ]; then
		printf 'PROBE_OUT=%s (append)\n' "$OUT_FILE"
	else
		printf 'PROBE_OUT=stdout\n'
	fi
	for SPEC in "$@"; do
		printf 'PROBE_SPEC=%s\n' "$SPEC"
	done
	printf 'PROBE_PLAN_END\n'
}

clear_conntrack() {
	CT_BIN=$(command -v conntrack)
	NFT_BIN=$(command -v nft)
	if [ -z "$CT_BIN" ]; then
		printf 'CLEAR_METHOD=ABSENT\n'
		printf '%s: conntrack applet not found; refusing to claim a clear\n' "$PROG" >&2
		return 7
	fi
	if [ -z "$NFT_BIN" ]; then
		printf 'CLEAR_METHOD=nft-absent\n'
		printf '%s: nft not found; cannot flush or read back the flowtable\n' "$PROG" >&2
		return 8
	fi

	printf 'CLEAR_METHOD=conntrack\n'
	CLEAR_RC=0
	if "$CT_BIN" -F; then
		printf 'CONNTRACK_FLUSH=ok\n'
	else
		printf 'CONNTRACK_FLUSH=failed\n'
		printf '%s: conntrack -F failed; conntrack entries can remain\n' "$PROG" >&2
		CLEAR_RC=8
		if "$NFT_BIN" flush flowtable inet fw4 ft; then
			printf 'FLOWTABLE_FLUSH=ok\n'
		else
			printf 'FLOWTABLE_FLUSH=failed\n'
			printf '%s: the nft flowtable fallback did not flush; treat this arm as uncleared\n' "$PROG" >&2
			CLEAR_RC=8
		fi
	fi
	if FLOWTABLES=$("$NFT_BIN" list flowtables); then
		printf 'FLOWTABLES_BEGIN\n%s\nFLOWTABLES_END\n' "$FLOWTABLES"
	else
		printf 'FLOWTABLE_READBACK=failed\n'
		printf '%s: nft list flowtables failed\n' "$PROG" >&2
		CLEAR_RC=8
	fi
	if PPE_TEXT=$(cat "$PPE_USAGE"); then
		printf 'PPE_USAGE_BEGIN\n%s\nPPE_USAGE_END\n' "$PPE_TEXT"
	else
		printf 'PPE_USAGE_READBACK=failed\n'
		printf '%s: cannot read %s\n' "$PROG" "$PPE_USAGE" >&2
		CLEAR_RC=8
	fi
	if [ "$CLEAR_RC" -eq 0 ]; then
		printf 'CLEAR_STATUS=ok\n'
		return 0
	fi
	printf 'CLEAR_STATUS=failed\n'
	printf '%s: clear incomplete\n' "$PROG" >&2
	return "$CLEAR_RC"
}

probe() {
	if [ ! -r "$CONNTRACK_FILE" ]; then
		printf 'PROBE=unavailable\n'
		printf '%s: %s is not readable\n' "$PROG" "$CONNTRACK_FILE" >&2
		exit 3
	fi

	probe_header
	for SPEC in "$@"; do
		SPORT=${SPEC%%/*}
		DPORT=${SPEC#*/}
		if ! COUNTS=$(awk -v ws="$SPORT" -v wd="$DPORT" '
		{
			matched = 0
			cs = ""
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^sport=/) {
					cs = substr($i, 7)
				} else if ($i ~ /^dport=/) {
					cd = substr($i, 7)
					if ((ws == "*" || cs == ws) &&
					    (wd == "*" || cd == wd)) {
						matched = 1
					}
				}
			}
			if (matched) {
				lines++
				if (index($0, "[HW_OFFLOAD]") > 0) {
					with_offload++
				}
			}
		}
		END {
			printf "%d %d\n", lines + 0, with_offload + 0
		}' "$CONNTRACK_FILE"); then
			printf 'PROBE=unavailable\n'
			printf '%s: cannot read %s\n' "$PROG" "$CONNTRACK_FILE" >&2
			exit 3
		fi
		CT_LINES=${COUNTS%% *}
		WITH_OFFLOAD=${COUNTS#* }
		probe_row "$ARM" "$SPEC" "$CT_LINES" "$WITH_OFFLOAD"
	done
}

while [ "$#" -gt 0 ]; do
	case $1 in
	--help|-h)
		usage
		exit 0
		;;
	--ports)
		need_value "$@"
		PORTS_RAW=$2
		shift 2
		;;
	--arm)
		need_value "$@"
		ARM=$2
		shift 2
		;;
	--out)
		need_value "$@"
		OUT_FILE=$2
		shift 2
		;;
	--clear)
		CLEAR_MODE=1
		shift
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	-*)
		printf '%s: unrecognized option: %s\n' "$PROG" "$1" >&2
		usage >&2
		exit 2
		;;
	*)
		printf '%s: unexpected argument: %s\n' "$PROG" "$1" >&2
		usage >&2
		exit 2
		;;
	esac
done

ARM_CLEAN=$(printf '%s' "$ARM" | tr -d '\t\n')
if [ "$ARM" != "$ARM_CLEAN" ]; then
	printf '%s: --arm must not contain tab or newline characters\n' "$PROG" >&2
	exit 2
fi

if [ "$CLEAR_MODE" -eq 0 ] && [ -z "$PORTS_RAW" ]; then
	printf '%s: --ports is required unless --clear is given\n' "$PROG" >&2
	usage >&2
	exit 2
fi

PORTS_NORM=
if [ -n "$PORTS_RAW" ]; then
	if ! PORTS_NORM=$(printf '%s\n' "$PORTS_RAW" | awk -F'[ \t,]+' '
	{
		for (i = 1; i <= NF; i++) {
			if ($i == "")
				continue
			n = split($i, side, "/")
			if (n != 2)
				exit 2
			for (j = 1; j <= 2; j++) {
				if (side[j] != "*" &&
				    (side[j] !~ /^[0-9]+$/ ||
				     side[j] + 0 < 1 ||
				     side[j] + 0 > 65535))
					exit 2
			}
			if (side[1] == "*" && side[2] == "*")
				exit 2
			sp = side[1]
			dp = side[2]
			if (sp != "*")
				sp = sp + 0
			if (dp != "*")
				dp = dp + 0
			printf "%s/%s\n", sp, dp
		}
	}'); then
		printf '%s: invalid --ports value: %s\n' "$PROG" "$PORTS_RAW" >&2
		printf '%s: expected sport/dport pairs, each side a port 1-65535 or *\n' "$PROG" >&2
		exit 2
	fi
	if [ -z "$PORTS_NORM" ]; then
		printf '%s: --ports does not contain a sport/dport pair\n' "$PROG" >&2
		exit 2
	fi
	# Intentional word splitting of the validated newline-separated list;
	# set -f above keeps a "*" port wildcard from globbing.
	# shellcheck disable=SC2086
	set -- $PORTS_NORM
fi

if [ "$DRY_RUN" -eq 1 ]; then
	if [ "$CLEAR_MODE" -eq 1 ]; then
		print_clear_plan
	fi
	if [ -n "$PORTS_NORM" ]; then
		print_probe_plan "$@"
	fi
	exit 0
fi

if [ "$CLEAR_MODE" -eq 1 ]; then
	clear_conntrack
	clear_status=$?
	if [ "$clear_status" -ne 0 ]; then
		exit "$clear_status"
	fi
fi

if [ -n "$PORTS_NORM" ]; then
	probe "$@"
fi

exit 0
