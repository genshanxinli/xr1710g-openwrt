#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Exit-code contract for scripts/flash-gate.sh (issue #88, G0 gate).
#
# test_flash_gate.sh proves that each guard *works*; this case proves that the
# guards form a closed, machine-checkable table.  The table has three faces that
# must agree:
#
#   1. the EXIT_* constants in the script
#   2. the "Exit status:" block in --help (what an operator is told)
#   3. the exit status measured by running one scenario per code
#
# A refactor that adds EXIT_WAN, renumbers a code, or drops a code from the help
# text breaks this case, which is the point: the recovery gate is the last
# defence before an unflashable board, so its "no" must be an enumerable value
# and not a sentence.
#
# Every scenario below is a minimal input that reaches one guard and stops
# there.  Nothing here flashes: the gate refuses before sysupgrade runs for
# real, and sysupgrade itself is a stub.
#
# Usage: scripts/tests/test_flash_gate_exitcodes.sh

set -u

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
GATE="${FLASH_GATE_UNDER_TEST:-$REPO_ROOT/scripts/flash-gate.sh}"

FAILED=0

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	FAILED=1
}

[ -f "$GATE" ] || {
	fail "$GATE is missing"
	printf 'flash-gate exit-code cases failed\n' >&2
	exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

STUBS="$WORK/stubs"
mkdir -p "$STUBS"

cat >"$STUBS/dd" <<'STUB'
#!/bin/sh
in='' out='' bs=512 count=0
for arg in "$@"; do
	case "$arg" in
	if=*) in=${arg#if=} ;;
	of=*) out=${arg#of=} ;;
	bs=*) bs=${arg#bs=} ;;
	count=*) count=${arg#count=} ;;
	esac
done
[ "${FAKE_DD_FAIL:-0}" = 1 ] && { echo "dd: I/O error" >&2; exit 1; }
[ -n "$in" ] && [ -n "$out" ] || exit 1
head -c $((bs * count)) "$in" >"$out" || exit 1
STUB

# fwtool always fails here, so the metadata path is the FIT trailer: one code
# path for every compat scenario instead of a host-dependent one.
cat >"$STUBS/fwtool" <<'STUB'
#!/bin/sh
exit 1
STUB

cat >"$STUBS/dumpimage" <<'STUB'
#!/bin/sh
exit 1
STUB

cat >"$STUBS/sysupgrade" <<'STUB'
#!/bin/sh
[ "${1:-}" = -T ] || exit 1
[ "${FAKE_SYS_RC:-0}" = 0 ] || exit "${FAKE_SYS_RC}"
exit 0
STUB

chmod +x "$STUBS/dd" "$STUBS/fwtool" "$STUBS/dumpimage" "$STUBS/sysupgrade"

# --- the table, as the script declares it ------------------------------------

CONST_CODES=$(awk -F= '/^EXIT_[A-Z_]*=/ { print $2 }' "$GATE")
HELP_CODES=$(sh "$GATE" --help 2>/dev/null |
	awk '/^Exit status:/ { inside = 1; next } /^Environment/ { inside = 0 }
	     inside { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) print $i }' | sort -n)

TABLE_CONST=$(printf '0\n%s\n' "$CONST_CODES" | sort -n | tr '\n' ' ')
TABLE_HELP=$(printf '%s\n' "$HELP_CODES" | tr '\n' ' ')

printf 'table constants: %s\n' "$TABLE_CONST"
printf 'table --help:    %s\n' "$TABLE_HELP"

[ "$TABLE_CONST" = "$TABLE_HELP" ] ||
	fail "the EXIT_* constants ($TABLE_CONST) and the --help table ($TABLE_HELP) disagree"

# --- fixtures ----------------------------------------------------------------

cat >"$WORK/mtd.txt" <<'MTD'
dev:    size   erasesize  name
mtd0: 00600000 00020000 "vendor"
mtd1: 00100000 00020000 "chainloader"
mtd2: 1b700000 00020000 "ubi"
mtd3: 04200000 00020000 "reserved_bmt"
MTD
sed 's/^mtd2: 1b700000/mtd2: 1a000000/' "$WORK/mtd.txt" >"$WORK/mtd-drift.txt"

DEV="$WORK/dev"
mkdir -p "$DEV"
head -c 262144 /dev/zero >"$DEV/mtd0ro"
head -c 262144 /dev/zero >"$DEV/mtd1ro"
{ head -c 1024 /dev/zero; printf 'ubi-partition-head'; head -c 261102 /dev/zero; } >"$DEV/mtd2ro"
head -c 262144 /dev/zero >"$DEV/mtd3ro"

IMAGE="$WORK/image.itb"
printf '\320\015\376\355' >"$IMAGE"
head -c 4096 /dev/zero >>"$IMAGE"
printf '{"supported_devices":["gemtek,xr1710g-ubi"]}' >>"$IMAGE"
# The digest the gate compares against: the file the build writes beside every
# image, in the same shape (digest, star, basename).
( cd "$WORK" && sha256sum image.itb >sha256sums )

UBICLASS="$WORK/ubi"
mkdir -p "$UBICLASS/ubi0" "$UBICLASS/ubi0_0"
printf '2\n' >"$UBICLASS/ubi0/mtd_num"

# --- scenarios ---------------------------------------------------------------

CASE_NO=0
OUT=''
RC=0

scenario() {
	name=$1
	code=$2
	shift 2
	CASE_NO=$((CASE_NO + 1))
	BK="$WORK/backup-$CASE_NO"
	set -- "$@" --backup-dir "$BK"
	OUT=$(PATH="$STUBS:$PATH" \
		FG_PROC_MTD="${S_MTD:-$WORK/mtd.txt}" \
		FG_MTD_DEV_DIR="${S_DEV:-$DEV}" \
		FG_UBI_DIR="$UBICLASS" \
		FG_BOARD_NAME="${S_BOARD:-gemtek,xr1710g-ubi}" \
		FAKE_DD_FAIL="${S_DD_FAIL:-0}" \
		FAKE_SYS_RC="${S_SYS_RC:-0}" \
		sh "$GATE" "$@" 2>&1)
	RC=$?
	printf '%-18s code=%s rc=%s %s\n' "$name" "$code" "$RC" \
		"$(printf '%s\n' "$OUT" | tail -n 1)"
	[ "$RC" = "$code" ] || fail "$name: rc=$RC, table says $code; output: $OUT"
	S_MTD='' S_DEV='' S_BOARD='' S_DD_FAIL='' S_SYS_RC=''
}

# 0 -- gate passed
scenario pass 0 --image "$IMAGE"
printf '%s\n' "$OUT" | grep -q 'GATE PASS' || fail "pass: no GATE PASS line"

# 2 -- usage
scenario usage 2 --bogus

# 3 -- -F without --i-know
scenario force-no-know 3 -F --image "$IMAGE"

# 4 -- layout mismatch (the box is not the board this image was built for)
S_MTD="$WORK/mtd-drift.txt" scenario layout-drift 4 --image "$IMAGE"
printf '%s\n' "$OUT" | grep -q 'mtd.ubi.size' ||
	fail "layout-drift: the drifted partition is not the row that refused"

# 5 -- backup failed
S_DD_FAIL=1 scenario backup-failed 5 --image "$IMAGE"
printf '%s\n' "$OUT" | grep -q 'GATE REFUSED' ||
	fail "backup-failed: no GATE REFUSED line"

# 6 -- sysupgrade -T rejected the image
S_SYS_RC=1 scenario image-rejected 6 --image "$IMAGE"
printf '%s\n' "$OUT" | grep -q 'sysupgrade.T' ||
	fail "image-rejected: sysupgrade.T is not the row that refused"

# --- closure check -----------------------------------------------------------

# Every documented code must have a scenario above.  Keep this list in sync by
# hand: it is the assertion that a new code cannot be added without a scenario.
printf '0 2 3 4 5 6\n' >"$WORK/scenarios.txt"
DOCUMENTED="$TABLE_CONST"
SCENARIOS=$(tr ' ' '\n' <"$WORK/scenarios.txt" | sort -n | tr '\n' ' ')
[ "$SCENARIOS" = "$DOCUMENTED" ] ||
	fail "scenarios ($SCENARIOS) do not cover the documented table ($DOCUMENTED)"

[ "$FAILED" = 0 ] || {
	printf 'flash-gate exit-code cases failed\n' >&2
	exit 1
}
printf 'all flash-gate exit-code cases passed\n'
