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
#   9  BusyBox PATH without od                -> rc 0, GATE PASS
#  10  multi-line supported_devices with " - " -> rc 0, GATE PASS
#  11  compat_version major mismatch + -F --run -> rc 4, sysupgrade never called
#  12  missing compat_version + -F --run      -> rc 4, sysupgrade never called
#  13  --no-sysupgrade with --run or -F       -> rc 2, sysupgrade never called
#
# Usage: scripts/tests/test_flash_gate.sh

set -u
unset FG_DEVICE_COMPAT FG_SYSTEM_CONFIG

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
printf '%s\n' "$*" >>"${FAKE_SYS_LOG:-/dev/null}"
if [ "${1:-}" = -T ]; then
	[ "${FAKE_SYS_RC:-0}" = 0 ] || { echo "Image check failed." >&2; exit "${FAKE_SYS_RC}"; }
	exit 0
fi
exit 0
STUB

chmod +x "$STUBS/dd" "$STUBS/fwtool" "$STUBS/dumpimage" "$STUBS/sysupgrade"

NO_OD_STUBS="$WORK/no-od-stubs"
mkdir -p "$NO_OD_STUBS"
cat >"$NO_OD_STUBS/od" <<'STUB'
#!/bin/sh
echo "od: not found" >&2
exit 127
STUB
chmod +x "$NO_OD_STUBS/od"

UCI_STUBS="$WORK/uci-stubs"
mkdir -p "$UCI_STUBS"
cat >"$UCI_STUBS/uci" <<'STUB'
#!/bin/sh
[ "${1:-}" = -q ] && shift
[ "${1:-}" = get ] && shift
if [ "${1:-}" = 'system.@system[0].compat_version' ]; then
	[ -n "${FAKE_UCI_COMPAT:-}" ] && printf '%s\n' "$FAKE_UCI_COMPAT"
	exit 0
fi
exit 1
STUB
chmod +x "$UCI_STUBS/uci"
printf 'config system\n' >"$WORK/system.cfg"

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

printf '{"metadata_version":1,"compat_version":"2.0","device":"gemtek,xr1710g-ubi","supported_devices":["gemtek,xr1710g-ubi"]}\n' \
	>"$WORK/meta-ok.json"
printf '{"metadata_version":1,"compat_version":"2.0","device":"gemtek,w1700k-ubi","supported_devices":["gemtek,w1700k-ubi"]}\n' \
	>"$WORK/meta-other.json"
printf '{"metadata_version":1,"compat_version":"1.0","device":"gemtek,xr1710g-ubi","supported_devices":["gemtek,xr1710g-ubi"]}\n' \
	>"$WORK/meta-compat1.json"
printf '{"metadata_version":1,"device":"gemtek,xr1710g-ubi","supported_devices":["gemtek,xr1710g-ubi"]}\n' \
	>"$WORK/meta-nocompat.json"
printf '{"metadata_version":1,"compat_version":"2.0","supported_devices":["other,board - Image version mismatch: image 2.0, device 1.0","gemtek,xr1710g-ubi - Image version mismatch: image 2.0, device 1.0"]}\n' \
	>"$WORK/meta-multiline.json"
cat >"$WORK/meta-pretty.json" <<'JSON'
{
  "metadata_version": "1.1",
  "compat_version": "2.0",
  "new_supported_devices": [],
  "supported_devices": [
    "other,board - Image version mismatch: image 2.0, device 1.0",
    "gemtek,xr1710g-ubi - Image version mismatch: image 2.0, device 1.0"
  ]
}
JSON

IMAGE="$WORK/image.itb"
printf '\320\015\376\355' >"$IMAGE"
head -c 4096 /dev/zero >>"$IMAGE"
# The trailer the real extractor finds when fwtool is missing.
printf '{"compat_version":"2.0","supported_devices":["gemtek,xr1710g-ubi"]}' >>"$IMAGE"

SHORT4="$WORK/image-short4.itb"
printf '\320\015\376\355' >"$SHORT4"

FAKE_IMAGE_OTHER="$WORK/image-other.itb"
printf '\320\015\376\355' >"$FAKE_IMAGE_OTHER"
head -c 4096 /dev/zero >>"$FAKE_IMAGE_OTHER"

# Same bytes, no metadata trailer: case 6 needs an image the device row cannot
# settle from JSON.
cp "$FAKE_IMAGE_OTHER" "$WORK/image-nometa.itb"

# The expected digests, in the shape bin/targets/.../sha256sums has.
( cd "$WORK" && sha256sum image.itb image-short4.itb image-other.itb image-nometa.itb >sha256sums )

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
	OUT=$(PATH="${EXTRA_PATH:-}$STUBS:$PATH" \
		FG_PROC_MTD="${FG_PROC_MTD:-$WORK/mtd.txt}" \
		FG_MTD_DEV_DIR="$DEV" \
		FG_UBI_DIR="$UBICLASS" \
		FG_BOARD_NAME="${FG_BOARD_NAME:-gemtek,xr1710g-ubi}" \
		FG_DEVICE_COMPAT="${FG_DEVICE_COMPAT_VAL:-}" \
		FG_SYSTEM_CONFIG="${FG_SYSTEM_CONFIG_VAL:-$WORK/no-such-system-cfg}" \
		FG_SYSUPGRADE="${FG_SYSUPGRADE_VAL:-sysupgrade}" \
		FAKE_UCI_COMPAT="${FAKE_UCI_COMPAT_VAL:-}" \
		FAKE_META="${FAKE_META:-$WORK/meta-ok.json}" \
		FAKE_DESC="${FAKE_DESC:-gemtek_xr1710g_ubi}" \
		FAKE_DD_FAIL="${FAKE_DD_FAIL:-0}" \
		FAKE_SYS_RC="${FAKE_SYS_RC:-0}" \
		FAKE_SYS_LOG="${FAKE_SYS_LOG:-$WORK/sys-$CASE_NO.log}" \
		sh "$GATE" "$@" 2>&1)
	RC=$?
}

reset_env() {
	EXTRA_PATH=''
	FG_PROC_MTD="$WORK/mtd.txt"
	FG_BOARD_NAME=gemtek,xr1710g-ubi
	FG_DEVICE_COMPAT_VAL=''
	FG_SYSTEM_CONFIG_VAL="$WORK/no-such-system-cfg"
	FG_SYSUPGRADE_VAL=sysupgrade
	FAKE_UCI_COMPAT_VAL=''
	FAKE_META="$WORK/meta-ok.json"
	FAKE_DESC=gemtek_xr1710g_ubi
	FAKE_DD_FAIL=0
	FAKE_SYS_RC=0
	CASE_NO=$((CASE_NO + 1))
	BK="$WORK/backup-$CASE_NO"
	FAKE_SYS_LOG="$WORK/sys-$CASE_NO.log"
	rm -f "$FAKE_SYS_LOG"
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

# --- 9: BusyBox PATH without od ---------------------------------------------

reset_env
EXTRA_PATH="$NO_OD_STUBS:"
run_gate no-od --image "$IMAGE" --backup-dir "$BK"
expect_rc 0
expect_out 'GATE PASS'
expect_no_out 'od: not found'

# --- 10: multi-line supported_devices with " - " suffixes -------------------

reset_env
FAKE_META="$WORK/meta-multiline.json"
run_gate multiline-sdev --image "$IMAGE" --backup-dir "$BK"
expect_rc 0
expect_out 'image.device'
expect_out 'GATE PASS'

# --- 11: compat_version major mismatch cannot be forced ---------------------

reset_env
FAKE_META="$WORK/meta-compat1.json"
run_gate compat-mismatch --image "$IMAGE" --force --i-know --run --backup-dir "$BK"
expect_rc 4
expect_out 'GATE REFUSED'
expect_out 'compat_version'
expect_no_out 'GATE PASS'
[ ! -s "$FAKE_SYS_LOG" ] || fail "$CASE: sysupgrade was invoked across a compat_version mismatch: $(cat "$FAKE_SYS_LOG")"

# --- 12: missing compat_version cannot be forced ----------------------------

reset_env
FAKE_META="$WORK/meta-nocompat.json"
run_gate compat-missing --image "$IMAGE" --force --i-know --run --backup-dir "$BK"
expect_rc 4
expect_out 'GATE REFUSED'
expect_out 'compat_version'
expect_no_out 'GATE PASS'
[ ! -s "$FAKE_SYS_LOG" ] || fail "$CASE: sysupgrade was invoked without compat_version: $(cat "$FAKE_SYS_LOG")"

# --- 13: --no-sysupgrade forbidden with --run and --force -------------------

reset_env
run_gate no-sysupgrade-run --image "$IMAGE" --no-sysupgrade --run --backup-dir "$BK"
expect_rc 2
expect_out 'GATE REFUSED'
expect_out '--no-sysupgrade'
expect_no_out 'GATE PASS'
[ ! -s "$FAKE_SYS_LOG" ] || fail "$CASE: sysupgrade was invoked with --no-sysupgrade --run: $(cat "$FAKE_SYS_LOG")"

reset_env
run_gate no-sysupgrade-force --image "$IMAGE" --no-sysupgrade --force --i-know --backup-dir "$BK"
expect_rc 2
expect_out 'GATE REFUSED'
expect_out '--no-sysupgrade'
expect_no_out 'GATE PASS'
[ ! -s "$FAKE_SYS_LOG" ] || fail "$CASE: sysupgrade was invoked with --no-sysupgrade --force: $(cat "$FAKE_SYS_LOG")"

# --- 14: pretty-printed multi-line JSON + empty new_supported_devices -------

reset_env
FAKE_META="$WORK/meta-pretty.json"
run_gate pretty-json --image "$IMAGE" --backup-dir "$BK"
expect_rc 0
expect_out 'image.device'
expect_out 'GATE PASS'

# --- 15: 4-byte FIT header truncated before totalsize -----------------------

reset_env
run_gate short4 --image "$SHORT4" --backup-dir "$BK"
expect_rc 4
expect_out 'image.size'
expect_out 'is truncated'

# --- 16: host with uci on PATH but no /etc/config/system stays on board 2.0 -

reset_env
EXTRA_PATH="$UCI_STUBS:"
FAKE_UCI_COMPAT_VAL=''
run_gate host-uci-no-system-cfg --image "$IMAGE" --backup-dir "$BK"
expect_rc 0
expect_out 'GATE PASS'

# --- 17: device uci lookup (1.0 refused, 2.0 accepted) + FG_DEVICE_COMPAT ---

reset_env
EXTRA_PATH="$UCI_STUBS:"
FG_SYSTEM_CONFIG_VAL="$WORK/system.cfg"
FAKE_UCI_COMPAT_VAL=''
run_gate device-uci-1.0-refuses-2.0 --image "$IMAGE" --backup-dir "$BK"
expect_rc 4
expect_out 'compat_version'
expect_out 'device is 1.0'

reset_env
EXTRA_PATH="$UCI_STUBS:"
FG_SYSTEM_CONFIG_VAL="$WORK/system.cfg"
FAKE_UCI_COMPAT_VAL='2.0'
run_gate device-uci-2.0-accepts-2.0 --image "$IMAGE" --backup-dir "$BK"
expect_rc 0
expect_out 'GATE PASS'

reset_env
FG_DEVICE_COMPAT_VAL='1.0'
run_gate env-device-compat-1.0 --image "$IMAGE" --backup-dir "$BK"
expect_rc 4
expect_out 'compat_version'
expect_out 'device is 1.0'

# --- 18: missing sysupgrade fails closed with --run and --force -------------

reset_env
FG_SYSUPGRADE_VAL="$WORK/no-such-sysupgrade"
run_gate missing-sysupgrade-run --image "$IMAGE" --run --backup-dir "$BK"
expect_rc 6
expect_out 'sysupgrade is missing'
expect_no_out 'GATE PASS'

reset_env
FG_SYSUPGRADE_VAL="$WORK/no-such-sysupgrade"
run_gate missing-sysupgrade-force --image "$IMAGE" --force --i-know --backup-dir "$BK"
expect_rc 6
expect_out 'sysupgrade is missing'
expect_no_out 'GATE PASS'

[ "$FAILED" = 0 ] || {
	printf 'flash-gate cases failed\n' >&2
	exit 1
}
printf 'all flash-gate cases passed\n'
