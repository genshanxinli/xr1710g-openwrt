#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Offline cases for scripts/flash-gate.sh.
#
# Every case runs the gate exactly as an operator would, with the box's own
# binaries replaced by stubs injected through PATH, and with /proc/mtd pointed
# at a fixture file.  The gate reads flash through dd, so the dd stub is a
# byte-accurate copy of the fixture partition files: a backup that does not
# match its manifest fails for the real reason, not because the stub lied.
#
# Cases:
#   1  matching image, matching layout        -> rc 0, manifest verifies
#   2  image built for another board          -> rc 4, nothing backed up
#   3  -F without --i-know                    -> rc 3, backup never started
#   4  dd fails mid-backup                    -> rc 5, no GATE PASS
#   5  /proc/mtd drifted (ubi size)           -> rc 4, refused before backup
#   6  no metadata and a foreign FDT desc     -> rc 4
#   7  sysupgrade -T rc=1 without -F          -> rc 6
#   8  --help                                 -> rc 0
#
# Usage: scripts/tests/test_flash_gate.sh

set -u

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
GATE="${FLASH_GATE_UNDER_TEST:-$REPO_ROOT/scripts/flash-gate.sh}"

FAILED=0

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	FAILED=1
}

[ -f "$GATE" ] || fail "$GATE is missing"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

STUBS="$WORK/stubs"
mkdir -p "$STUBS"

# --- stubs ------------------------------------------------------------------

cat >"$STUBS/dd" <<'STUB'
#!/bin/sh
# dd with only the subset flash-gate.sh uses: if= of= bs= count=.
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
[ -n "$in" ] || { echo "dd: no if=" >&2; exit 1; }
[ -n "$out" ] || { echo "dd: no of=" >&2; exit 1; }
head -c $((bs * count)) "$in" >"$out" || exit 1
STUB

cat >"$STUBS/fwtool" <<'STUB'
#!/bin/sh
# fwtool -q -i OUTFILE IMAGE -> copy the fixture metadata to OUTFILE.
out='' img=''
while [ $# -gt 0 ]; do
	case "$1" in
	-i) out=$2; shift 2 ;;
	-q) shift ;;
	-*) shift ;;
	*) img=$1; shift ;;
	esac
done
[ -n "$out" ] && [ -n "$img" ] || exit 1
[ -n "${FAKE_META:-}" ] || exit 1
cp "$FAKE_META" "$out"
STUB

cat >"$STUBS/dumpimage" <<'STUB'
#!/bin/sh
printf 'FIT description: ARM64 OpenWrt FIT (Flattened Image Tree)\n'
printf ' Description:  ARM64 OpenWrt %s device tree blob\n' "${FAKE_DESC:-gemtek_xr1710g_ubi}"
printf ' Created:      Thu Nov 20 10:00:00 2026\n'
STUB

cat >"$STUBS/sysupgrade" <<'STUB'
#!/bin/sh
# Only "sysupgrade -T IMAGE" is exercised.
[ "${1:-}" = -T ] || exit 1
[ "${FAKE_SYS_RC:-0}" = 0 ] || { echo "Image check failed." >&2; exit "${FAKE_SYS_RC}"; }
exit 0
STUB

chmod +x "$STUBS/dd" "$STUBS/fwtool" "$STUBS/dumpimage" "$STUBS/sysupgrade"

# --- fixtures ---------------------------------------------------------------

# Measured on the bench box 2026-11-20 (issue #88).
cat >"$WORK/mtd.txt" <<'MTD'
dev:    size   erasesize  name
mtd0: 00600000 00020000 "vendor"
mtd1: 00100000 00020000 "chainloader"
mtd2: 1b700000 00020000 "ubi"
mtd3: 04200000 00020000 "reserved_bmt"
MTD

# Same table with the UBI partition resized, i.e. a box whose layout drifted.
sed 's/^mtd2: 1b700000/mtd2: 1a000000/' "$WORK/mtd.txt" >"$WORK/mtd-drift.txt"

DEV="$WORK/dev"
mkdir -p "$DEV"
# Sparse stand-ins: dd only reads the first 256 KiB of each.
head -c 262144 /dev/zero >"$DEV/mtd0ro"
head -c 262144 /dev/zero >"$DEV/mtd1ro"
{ head -c 1024 /dev/zero; printf 'ubi-partition-head'; head -c 261102 /dev/zero; } >"$DEV/mtd2ro"
head -c 262144 /dev/zero >"$DEV/mtd3ro"
for n in 0 1 2 3; do :; done

printf '{"metadata_version":1,"device":"gemtek,xr1710g-ubi","supported_devices":["gemtek,xr1710g-ubi"]}\n' \
	>"$WORK/meta-ok.json"
printf '{"metadata_version":1,"device":"gemtek,w1700k-ubi","supported_devices":["gemtek,w1700k-ubi"]}\n' \
	>"$WORK/meta-other.json"

IMAGE="$WORK/image.itb"
printf '\320\015\376\355' >"$IMAGE"
head -c 4096 /dev/zero >>"$IMAGE"
# The trailer the real extractor finds when fwtool is missing.
printf '{"supported_devices":["gemtek,xr1710g-ubi"]}' >>"$IMAGE"

FAKE_IMAGE_OTHER="$WORK/image-other.itb"
printf '\320\015\376\355' >"$FAKE_IMAGE_OTHER"
head -c 4096 /dev/zero >>"$FAKE_IMAGE_OTHER"

UBICLASS="$WORK/ubi"
mkdir -p "$UBICLASS/ubi0" "$UBICLASS/ubi0_0"
printf '2\n' >"$UBICLASS/ubi0/mtd_num"

# --- runner -----------------------------------------------------------------

OUT=''
RC=0
CASE_NO=0

run_gate() {
	CASE=$1
	shift
	OUT=$(PATH="$STUBS:$PATH" \
		FG_PROC_MTD="${FG_PROC_MTD:-$WORK/mtd.txt}" \
		FG_MTD_DEV_DIR="$DEV" \
		FG_UBI_DIR="$UBICLASS" \
		FG_BOARD_NAME="${FG_BOARD_NAME:-gemtek,xr1710g-ubi}" \
		FAKE_META="${FAKE_META:-$WORK/meta-ok.json}" \
		FAKE_DESC="${FAKE_DESC:-gemtek_xr1710g_ubi}" \
		FAKE_DD_FAIL="${FAKE_DD_FAIL:-0}" \
		FAKE_SYS_RC="${FAKE_SYS_RC:-0}" \
		sh "$GATE" "$@" 2>&1)
	RC=$?
}

reset_env() {
	FG_PROC_MTD="$WORK/mtd.txt"
	FG_BOARD_NAME=gemtek,xr1710g-ubi
	FAKE_META="$WORK/meta-ok.json"
	FAKE_DESC=gemtek_xr1710g_ubi
	FAKE_DD_FAIL=0
	FAKE_SYS_RC=0
	CASE_NO=$((CASE_NO + 1))
	BK="$WORK/backup-$CASE_NO"
}

expect_rc() {
	[ "$RC" = "$1" ] || fail "$CASE: rc=$RC, wanted $1; output: $OUT"
}

expect_out() {
	printf '%s\n' "$OUT" | grep -q -- "$1" || fail "$CASE: output lacks '$1'; output: $OUT"
}

expect_no_out() {
	if printf '%s\n' "$OUT" | grep -q -- "$1"; then
		fail "$CASE: output should not contain '$1'; output: $OUT"
	fi
}

# --- 1: everything matches --------------------------------------------------

reset_env
run_gate match --image "$IMAGE" --backup-dir "$BK"
expect_rc 0
expect_out 'GATE PASS'
expect_out 'image.device'
expect_out 'sysupgrade.T'
n=$(ls "$BK"/*/manifest.sha256 2>/dev/null | wc -l)
[ "$n" = 1 ] || fail "$CASE: no manifest written"
if [ "$n" = 1 ]; then
	bkdir=$(dirname "$(ls "$BK"/*/manifest.sha256)")
	lines=$(wc -l <"$bkdir/manifest.sha256" | tr -d ' ')
	[ "$lines" = 5 ] || fail "$CASE: manifest has $lines entries, wanted 5 (4 partitions + mtd.txt)"
	( cd "$bkdir" && sha256sum -c manifest.sha256 >/dev/null 2>&1 ) ||
		fail "$CASE: manifest does not verify"
	grep -q '^head_kb 256$' "$bkdir/meta.txt" || fail "$CASE: meta.txt lacks head_kb"
	grep -q "^board gemtek,xr1710g-ubi$" "$bkdir/meta.txt" || fail "$CASE: meta.txt lacks the board"
fi

# --- 2: image for another board ---------------------------------------------

reset_env
FAKE_META="$WORK/meta-other.json"
run_gate other-board --image "$FAKE_IMAGE_OTHER" --backup-dir "$BK"
expect_rc 4
expect_out 'GATE REFUSED'
expect_out 'another board'
[ ! -d "$BK" ] || fail "$CASE: a backup was started for a mismatched image"

# --- 3: -F without --i-know -------------------------------------------------

reset_env
run_gate force-no-know --image "$IMAGE" -F --backup-dir "$BK"
expect_rc 3
expect_out '--i-know'
[ ! -d "$BK" ] || fail "$CASE: the backup ran before the consent check"

# --- 4: dd fails ------------------------------------------------------------

reset_env
FAKE_DD_FAIL=1
run_gate dd-fail --image "$IMAGE" --backup-dir "$BK"
expect_rc 5
expect_out 'GATE REFUSED'
expect_out 'backup failed'
expect_no_out 'GATE PASS'

# --- 5: layout drifted ------------------------------------------------------

reset_env
FG_PROC_MTD="$WORK/mtd-drift.txt"
run_gate layout-drift --image "$IMAGE" --backup-dir "$BK"
expect_rc 4
expect_out 'mtd.ubi.size'
expect_no_out 'GATE PASS'
[ ! -d "$BK" ] || fail "$CASE: a backup was started on a drifted layout"

# --- 6: no metadata, foreign FDT description --------------------------------

reset_env
cp "$FAKE_IMAGE_OTHER" "$WORK/image-nometa.itb"
FAKE_META="$WORK/does-not-exist.json"
FAKE_DESC=gemtek_w1700k_ubi
run_gate no-metadata --image "$WORK/image-nometa.itb" --backup-dir "$BK"
expect_rc 4
expect_out 'cannot verify'

# --- 7: sysupgrade -T rejects, no -F ---------------------------------------

reset_env
FAKE_SYS_RC=1
run_gate syscheck-reject --image "$IMAGE" --backup-dir "$BK"
expect_rc 6
expect_out 'sysupgrade.T'
expect_no_out 'GATE PASS'

# --- 8: --help --------------------------------------------------------------

reset_env
run_gate help --help
expect_rc 0
expect_out 'flash-gate.sh --image'

[ "$FAILED" = 0 ] || {
	printf 'flash-gate cases failed\n' >&2
	exit 1
}
printf 'all flash-gate cases passed\n'
