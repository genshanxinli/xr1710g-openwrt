#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Offline refusal cases for scripts/flash-gate.sh: the "no" of every guard,
# driven end to end with no board, no /dev/mtd*, no ttyUSB, no real sysupgrade.
#
# test_flash_gate.sh proves the guards cooperate on a matching box;
# test_flash_gate_exitcodes.sh proves the codes form a closed table.  This case
# is the third face: it takes the images and the box that a flash must never
# happen on, one per failure mode, and asserts the exact exit status *and* the
# stderr sentence for each.  A gate whose refusal has never been observed is not
# a gate, it is a promise (issue #88, harness matrix: flash-gate-noimage was the
# highest-risk case that had never run off-hardware).
#
# Every fixture is synthetic and lives in one temporary directory:
#
#   image.good.itb      d00dfeed, FIT totalsize 4096, 4 KiB body + metadata
#   image.trunc.itb     same header, totalsize 40960, only 4 KiB on disk
#   image.edited.itb    byte-for-byte image.good.itb with one byte flipped
#   sha256sums          the digest list the build writes beside the images
#   mtd.txt             the bench table: vendor, chainloader, ubi, reserved_bmt
#   mtd-two.txt         the same box after a bootloader rewrite: 2 partitions
#   dev/                byte-accurate stand-ins for the /dev/mtd*ro char devs
#
# Usage: scripts/tests/test_flash_gate_offline.sh
#        FLASH_GATE_UNDER_TEST=/path/to/copy sh scripts/tests/...   (red runs)

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
	printf 'flash-gate offline cases failed\n' >&2
	exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

STUBS="$WORK/stubs"
mkdir -p "$STUBS"

# --- stubs ------------------------------------------------------------------
# Only the three host tools the gate shells out to, and a sysupgrade that
# records its argv: the gate must never reach a real one from this test.

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
[ -n "$in" ] || exit 1
[ -n "$out" ] || out=/dev/stdout
head -c $((bs * count)) "$in" >"$out" || exit 1
STUB

cat >"$STUBS/fwtool" <<'STUB'
#!/bin/sh
# -q -i OUTFILE IMAGE: hand back the fixture metadata, nothing else.
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
printf ' Description:  ARM64 OpenWrt %s device tree blob\n' "${FAKE_DESC:-gemtek_xr1710g_ubi}"
STUB

cat >"$STUBS/sysupgrade" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${FAKE_SYS_LOG:-/dev/null}"
[ "${1:-}" = -T ] || exit 1
[ "${FAKE_SYS_RC:-0}" = 0 ] || { echo "Image check failed." >&2; exit "${FAKE_SYS_RC}"; }
exit 0
STUB

chmod +x "$STUBS/dd" "$STUBS/fwtool" "$STUBS/dumpimage" "$STUBS/sysupgrade"

# BusyBox applets on the device take a leading "--" as a NAME, not as an
# option terminator: "dirname -- /x/img" prints "." there.  The gate must not
# rely on GNU dirname/basename, so every run below sees this stub first.  On a
# GNU host the real tools would hide the bug entirely (issue A08-F9).
DIRNAME_STUBS="$WORK/dirname-stubs"
mkdir -p "$DIRNAME_STUBS"
REAL_DIRNAME=$(command -v dirname)
REAL_BASENAME=$(command -v basename)
cat >"$DIRNAME_STUBS/dirname" <<STUB
#!/bin/sh
[ "\${1:-}" = "--" ] && exit 1
exec "$REAL_DIRNAME" "\$@"
STUB
cat >"$DIRNAME_STUBS/basename" <<STUB
#!/bin/sh
[ "\${1:-}" = "--" ] && exit 1
exec "$REAL_BASENAME" "\$@"
STUB
chmod +x "$DIRNAME_STUBS/dirname" "$DIRNAME_STUBS/basename"

# --- fixtures ---------------------------------------------------------------

cat >"$WORK/mtd.txt" <<'MTD'
dev:    size   erasesize  name
mtd0: 00600000 00020000 "vendor"
mtd1: 00100000 00020000 "chainloader"
mtd2: 1b700000 00020000 "ubi"
mtd3: 04200000 00020000 "reserved_bmt"
MTD

# A half-rewritten vendor bootloader: chainloader and reserved_bmt are gone.
cat >"$WORK/mtd-two.txt" <<'MTD'
dev:    size   erasesize  name
mtd0: 00600000 00020000 "vendor"
mtd1: 1b700000 00020000 "ubi"
MTD

DEV="$WORK/dev"
mkdir -p "$DEV"
head -c 262144 /dev/zero >"$DEV/mtd0ro"
head -c 262144 /dev/zero >"$DEV/mtd1ro"
{ head -c 1024 /dev/zero; printf 'ubi-partition-head'; head -c 261102 /dev/zero; } >"$DEV/mtd2ro"
head -c 262144 /dev/zero >"$DEV/mtd3ro"

UBICLASS="$WORK/ubi"
mkdir -p "$UBICLASS/ubi0" "$UBICLASS/ubi0_0"
printf '2\n' >"$UBICLASS/ubi0/mtd_num"

printf '{"metadata_version":1,"device":"gemtek,xr1710g-ubi","supported_devices":["gemtek,xr1710g-ubi"]}\n' \
	>"$WORK/meta-ok.json"
printf '{"metadata_version":1,"device":"gemtek,w1700k-ubi","supported_devices":["gemtek,w1700k-ubi"]}\n' \
	>"$WORK/meta-other.json"

# A 4 KiB FIT tree, exactly like the bench itb (header totalsize 4096, payload
# appended past it) but with the payload replaced by the metadata trailer.
make_image() {
	out=$1
	total=$2
	{
		printf '\320\015\376\355'
		printf "\\$(printf '%03o' $(( (total >> 24) & 255 )))"
		printf "\\$(printf '%03o' $(( (total >> 16) & 255 )))"
		printf "\\$(printf '%03o' $(( (total >> 8) & 255 )))"
		printf "\\$(printf '%03o' $(( total & 255 )))"
		head -c 4096 /dev/zero
		printf '{"supported_devices":["gemtek,xr1710g-ubi"]}'
	} >"$out"
}

IMAGE="$WORK/image.good.itb"
make_image "$IMAGE" 4096
TRUNC="$WORK/image.trunc.itb"
make_image "$TRUNC" 40960
cp "$IMAGE" "$WORK/image.edited.itb"
# One byte, well inside the FIT tree, as a bad copy would have it.
printf 'X' | dd of="$WORK/image.edited.itb" bs=1 seek=2048 conv=notrunc 2>/dev/null ||
	fail "could not build the edited image"

# The list is what the build would have written for the *good* file: the edited
# copy is listed under the good digest, which is exactly what a file that was
# changed after the digest was taken looks like.
(
	cd "$WORK" || exit 1
	sha256sum image.good.itb >sha256sums
	sha256sum image.good.itb | sed 's/ image\.good\.itb$/ image.edited.itb/' >>sha256sums
)

# --- runner -----------------------------------------------------------------

OUT=''
ERR=''
RC=0
CASE_NO=0
CASES=0

run_gate() {
	name=$1
	want_rc=$2
	want_err=$3
	shift 3
	CASE_NO=$((CASE_NO + 1))
	CASES=$((CASES + 1))
	OUT="$WORK/out-$CASE_NO"
	ERR="$WORK/err-$CASE_NO"
	PATH="$DIRNAME_STUBS:$STUBS:$PATH" \
		FG_PROC_MTD="${FG_PROC_MTD:-$WORK/mtd.txt}" \
		FG_MTD_DEV_DIR="$DEV" \
		FG_UBI_DIR="$UBICLASS" \
		FG_BOARD_NAME="${FG_BOARD_NAME:-gemtek,xr1710g-ubi}" \
		FAKE_META="${FAKE_META:-$WORK/meta-ok.json}" \
		FAKE_DESC="${FAKE_DESC:-gemtek_xr1710g_ubi}" \
		FAKE_SYS_RC="${FAKE_SYS_RC:-0}" \
		FAKE_SYS_LOG="$WORK/sysupgrade-$CASE_NO.log" \
		sh "$GATE" "$@" 2>"$ERR" >"$OUT"
	RC=$?
	got_err=$(tr '\n' ' ' <"$ERR" | sed 's/ *$//')
	verdict=ok
	if [ "$RC" != "$want_rc" ]; then
		verdict=BAD-RC
	elif [ -n "$want_err" ] && ! grep -q -- "$want_err" "$ERR"; then
		verdict=BAD-STDERR
	fi
	printf '%-16s expect_rc=%-2s rc=%-2s stderr_keyword=%-22s %s\n' \
		"$name" "$want_rc" "$RC" "${want_err:--}" "$verdict"
	# MEANS says what a wrong verdict lets through, in words: a red run has to
	# read as "a bad image was accepted", not as "0 is not 4".
	[ "$verdict" = ok ] ||
		fail "$name: ${MEANS:+$MEANS -- }rc=$RC (wanted $want_rc), stderr=[$got_err]"
	# No case may leave a lie: a refusal must never print GATE PASS.
	if [ "$want_rc" != 0 ] && grep -q 'GATE PASS' "$OUT"; then
		fail "$name: ${MEANS:+$MEANS -- }printed GATE PASS while rc=$RC"
	fi
	MEANS=''
	FG_PROC_MTD='' FG_BOARD_NAME='' FAKE_META='' FAKE_DESC='' FAKE_SYS_RC=''
}

# --- 1: image missing -------------------------------------------------------
# The operator typed a path that is not there.  Refused as usage (2), before
# any row is evaluated: nothing may be read from the flash for a missing file.

run_gate no-image 2 'image not found' --image "$WORK/does-not-exist.itb"

# --- 2: truncated image -----------------------------------------------------
# The header survives the cut, so d00dfeed still passes; the FIT totalsize does
# not fit in the file.

run_gate truncated 4 'is truncated' --image "$TRUNC"

# --- 3: one byte changed, size intact ---------------------------------------
# This is the case that matters: same length, valid FIT header, metadata still
# names this board, sysupgrade -T says fine.  Only the digest can see it.

MEANS='a rewritten image was waved through (一个坏镜像被放过了)'
run_gate sha-mismatch 4 'sha256 mismatch' --image "$WORK/image.edited.itb"

# --- 4: no digest to compare against ----------------------------------------
# Copy the image where no sha256sums follows it: the gate must refuse rather
# than accept an image whose bytes cannot be accounted for.

mkdir -p "$WORK/bare"
cp "$IMAGE" "$WORK/bare/image.itb"
MEANS='an image nobody can account for was waved through'
run_gate no-digest 4 'no expected sha256' --image "$WORK/bare/image.itb"

# --- 5: image built for another board ---------------------------------------
# Digest matches (the file is untouched), so this proves the device row is an
# independent refusal and not a side effect of the digest row.

mkdir -p "$WORK/other"
cp "$IMAGE" "$WORK/other/image.itb"
( cd "$WORK/other" && sha256sum image.itb >sha256sums )
FAKE_META="$WORK/meta-other.json" run_gate other-board 4 'another board' \
	--image "$WORK/other/image.itb"

# --- 6: the partition table is not the one the image assumes ----------------
# 4 partitions on the board table, 2 on the box.

FG_PROC_MTD="$WORK/mtd-two.txt" run_gate layout-two-parts 4 'flash layout does not match' \
	--image "$IMAGE"

# --- 7: no writable place for the backup ------------------------------------
# $WORK/notadir is a regular file, so the backup root cannot be created.
# A chmod-based read-only case is deliberately not used: the suite must give the
# same verdict under a root runner, where mode bits do not deny writes.

: >"$WORK/notadir"
run_gate backup-no-dir 5 'cannot create' --image "$IMAGE" --backup-dir "$WORK/notadir/sub"

# --- 8: -F without --i-know -------------------------------------------------
# The dangerous flag alone: refused as 3, and the backup never starts.

run_gate force-no-know 3 '--i-know' --image "$IMAGE" -F --backup-dir "$WORK/backup-force"
[ -d "$WORK/backup-force" ] && fail "force-no-know: a backup ran after the consent refusal"

# --- 9: -F --i-know but no verified backup ----------------------------------
# Consent is not enough: a forced flash without a backup is exactly the
# combination that must never reach the flasher.

run_gate force-no-backup 5 'requires a verified backup' --image "$IMAGE" -F --i-know --no-backup

# --- 10: sysupgrade -T rejects the image ------------------------------------
# The stock validator is a refusal in its own right (code 6), not something the
# gate papers over.

FAKE_SYS_RC=1 run_gate syscheck-reject 6 'sysupgrade -T rejected' --image "$IMAGE"

# --- 11: everything matches -------------------------------------------------
# The happy path, with the digest row present and the backup verified: 0, no
# stderr, manifest on disk, and sysupgrade still not executed (no --run).

run_gate happy 0 '' --image "$IMAGE" --backup-dir "$WORK/backup-happy"
grep -q 'image.sha256' "$OUT" || fail "happy: the digest row is missing from the table"
grep -q 'GATE PASS' "$OUT" || fail "happy: no GATE PASS"
[ -s "$ERR" ] && fail "happy: stderr is not empty: $(tr '\n' ' ' <"$ERR")"
n=$(ls "$WORK/backup-happy"/*/manifest.sha256 2>/dev/null | wc -l | tr -d ' ')
[ "$n" = 1 ] || fail "happy: no manifest written"
if [ "$n" = 1 ]; then
	( cd "$(dirname "$(ls "$WORK/backup-happy"/*/manifest.sha256)")" &&
		sha256sum -c manifest.sha256 >/dev/null 2>&1 ) ||
		fail "happy: the manifest does not verify"
fi
grep -q -- '-F' "$WORK/sysupgrade-11.log" 2>/dev/null &&
	fail "happy: -F reached the stub without --force"

printf '%s\n' "cases: $CASES"
[ "$FAILED" = 0 ] || {
	printf 'flash-gate offline cases failed\n' >&2
	exit 1
}
printf 'all flash-gate offline cases passed\n'
