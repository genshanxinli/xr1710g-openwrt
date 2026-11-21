#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Issue #7: a major compat_version mismatch (UBI layout 1.x vs 2.0) has to be
# non-forceable.  `sysupgrade -T -F` must fail on it, while the checks that are
# only "you are doing something odd" -- a missing signature, an image whose
# metadata does not list this board -- must stay forceable, because that is how
# a vendor firmware or a downgrade gets flashed.
#
# What is exercised: the shipped /usr/libexec/validate_firmware_image and
# /sbin/sysupgrade, copied into a temporary tree and run from there.  The
# copies are byte-identical apart from three sandbox adjustments:
#
#   * absolute paths (/lib, /usr/share/libubox, /tmp) are rewritten to the
#     sandbox prefix, since the scripts open them literally;
#   * the shebang becomes /bin/bash and the one ash-only line of libubox's
#     jshn.sh (`export -n VAR=0`) uses the bash form.  This host has no ash;
#     dash rejects `export -n`, and bash's `export -n` would un-export the
#     JSON_SEQ variable the jshn helper reads back.  Nothing else changes.
#   * one ash-only line of lib/upgrade/fwtool.sh -- `(( [ ... ] ))` for the
#     minor compat test -- is read by bash as arithmetic.  It is evaluated
#     false and returns 0; every case below takes the major-compat branch and
#     returns before reaching it, and no case depends on the minor one.
#
# The validator is called exactly as sysupgrade calls it, and sysupgrade is
# called exactly as flash-gate.sh / the operator calls it.  The image, the
# metadata and the device's uci value are fixtures: /usr/bin/fwtool is a stub
# that hands out the metadata, /usr/bin/uci is a stub that answers the one
# query fwtool.sh makes, and lib/upgrade/platform.sh answers 0 so that only the
# fwtool layer decides.
#
# Cases:
#   1  compat 2.0 image on a compat 2.0 device           -> valid forceable, -T rc 0
#   2  compat 2.0 image on a 1.x device (no uci value)   -> !valid !forceable, -T -F rc 1
#   3  compat 1.0 image on a compat 2.0 device           -> !valid !forceable, -T -F rc 1
#   4  image metadata without compat_version, device 2.0 -> !valid !forceable, -T -F rc 1
#   5  matching compat, signature required but absent     -> !valid forceable, -T -F rc 0
#   6  clean image, stock flags                           -> valid forceable, -T rc 0
#   7  image for another board                            -> !valid forceable, -T -F rc 0
#   8  no compat field on either side (1.0 == 1.0)        -> valid forceable, -T rc 0
#
# Usage: scripts/tests/test_compat_not_forceable.sh
#
#   VFI_UNDER_TEST     validator to test    (default: this tree's copy)
#   FWTOOL_UNDER_TEST  lib/upgrade/fwtool.sh (default: this tree's copy)
#   JSHN_SH / JSHN_BIN libubox shell lib + helper (default: this tree's
#                      staging_dir, else its build_dir)

set -u

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
BASE="$REPO_ROOT/package/base-files/files"
VFI_SRC=${VFI_UNDER_TEST:-$BASE/usr/libexec/validate_firmware_image}
FWTOOL_SRC=${FWTOOL_UNDER_TEST:-$BASE/lib/upgrade/fwtool.sh}

FAILED=0

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	FAILED=1
}

# A built tree is not necessarily this tree: staging_dir lives in the main
# checkout, while this test may run from a linked worktree.
roots() {
	printf '%s\n' "$REPO_ROOT"
	main=$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null |
		sed -n '1s/^worktree //p')
	[ -n "$main" ] && [ "$main" != "$REPO_ROOT" ] && printf '%s\n' "$main"
}

find_jshn() {
	# $1 = which piece: sh | bin
	roots | while IFS= read -r r; do
		if [ "$1" = sh ]; then
			ls "$r"/staging_dir/host/share/libubox/jshn.sh \
				"$r"/build_dir/hostpkg/libubox-*/sh/jshn.sh 2>/dev/null
		else
			ls "$r"/staging_dir/host/bin/jshn \
				"$r"/build_dir/hostpkg/libubox-*/jshn 2>/dev/null
		fi
	done | head -n 1
}

JSHN_SH=$(find_jshn sh)
JSHN_BIN=$(find_jshn bin)

for f in "$VFI_SRC" "$FWTOOL_SRC" "$JSHN_SH" "$JSHN_BIN"; do
	[ -n "$f" ] && [ -f "$f" ] || {
		printf 'FAIL: %s is missing.\n' "${f:-a libubox piece}" >&2
		printf 'This test runs the shipped scripts, so it needs one built tree. Build the\n' >&2
		printf 'host libubox first, or point JSHN_SH and JSHN_BIN at a jshn.sh and jshn.\n' >&2
		exit 1
	}
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
SBX="$WORK/root"

# --- sandbox ----------------------------------------------------------------

rewrite() {
	# The /tmp rule has to run first: $SBX itself starts with /tmp, so any
	# later rule would feed its own output back through it.
	sed \
		-e "s|/tmp/|$SBX/tmp/|g" \
		-e "s|\. /lib/functions.sh|. $SBX/lib/functions.sh|g" \
		-e "s|\. /lib/functions/system.sh|. $SBX/lib/functions/system.sh|g" \
		-e "s|include /lib/upgrade|include $SBX/lib/upgrade|g" \
		-e "s|\. /usr/share/libubox/jshn.sh|. $SBX/usr/share/libubox/jshn.sh|g" \
		-e "s|/usr/libexec/validate_firmware_image|$SBX/usr/libexec/validate_firmware_image|g" \
		-e '1s|^#! */bin/sh$|#!/bin/bash|' \
		"$1"
}

mkdir -p "$SBX/lib/functions" "$SBX/lib/upgrade" "$SBX/usr/share/libubox" \
	"$SBX/usr/libexec" "$SBX/sbin" "$SBX/bin" "$SBX/tmp/sysinfo" "$SBX/etc"

# lib/upgrade/platform.sh is what validate_firmware_image calls after fwtool;
# answer 0 so that the compat decision is the only one under test.
printf 'platform_check_image() {\n\treturn 0\n}\n' >"$SBX/lib/upgrade/platform.sh"

rewrite "$BASE/lib/upgrade/common.sh" >"$SBX/lib/upgrade/common.sh"
rewrite "$BASE/lib/functions.sh" >"$SBX/lib/functions.sh"
rewrite "$BASE/lib/functions/system.sh" >"$SBX/lib/functions/system.sh"
rewrite "$FWTOOL_SRC" >"$SBX/lib/upgrade/fwtool.sh"
rewrite "$VFI_SRC" >"$SBX/usr/libexec/validate_firmware_image"
rewrite "$BASE/sbin/sysupgrade" >"$SBX/sbin/sysupgrade"
# dash rejects `export -n`; bash would un-export JSON_SEQ, which json_dump
# hands to the jshn helper.
sed 's|export -n ${JSON_PREFIX}JSON_SEQ=0|: ${JSON_PREFIX}JSON_SEQ=0|' \
	"$JSHN_SH" >"$SBX/usr/share/libubox/jshn.sh"
cp "$JSHN_BIN" "$SBX/bin/jshn"

# fwtool: -q -i OUTFILE IMAGE hands out the image metadata, -q -s OUTFILE IMAGE
# reports whether the image carries a signature.  No other call is made below.
cat >"$SBX/bin/fwtool" <<'STUB'
#!/bin/sh
out=''; getinfo=0; getsig=0
while [ $# -gt 0 ]; do
	case "$1" in
	-i) getinfo=1; out=$2; shift 2 ;;
	-s) getsig=1; out=$2; shift 2 ;;
	-*) shift ;;
	*) shift ;;
	esac
done
if [ "$getinfo" = 1 ]; then
	[ -n "${FAKE_META:-}" ] && [ -f "$FAKE_META" ] || exit 1
	cp "$FAKE_META" "$out"
	exit 0
fi
[ "$getsig" = 1 ] && exit "${FAKE_SIG_RC:-1}"
exit 1
STUB

# uci: the only query fwtool.sh makes.  An empty or missing fixture is a device
# that never declared a compat_version, i.e. a 1.0-layout box.
cat >"$SBX/bin/uci" <<'STUB'
#!/bin/sh
[ "${1:-}" = -q ] && shift
[ "${1:-}" = get ] && shift
case "${1:-}" in
	system.@system\[0\].compat_version)
		[ -n "${FAKE_DEVICE_COMPAT:-}" ] && cat "$FAKE_DEVICE_COMPAT" 2>/dev/null
		exit 0
		;;
esac
exit 1
STUB

chmod +x "$SBX/bin/jshn" "$SBX/bin/fwtool" "$SBX/bin/uci" \
	"$SBX/usr/libexec/validate_firmware_image" "$SBX/sbin/sysupgrade"

# --- fixtures ---------------------------------------------------------------

# The shape include/image-commands.mk:76-87 emits for DEVICE_COMPAT_VERSION
# 2.0: the device list lives in new_supported_devices, and supported_devices
# carries the human-readable "image version mismatch" line instead of a name.
cat >"$WORK/meta-2.0.json" <<'JSON'
{ "metadata_version": "1.1", "compat_version": "2.0",
  "compat_message": "Partition table has been changed to cooperate with the vendor bootloader with regard to the BMT/BBT partition at the end of flash. A reinstall including corrected chainloader is needed.",
  "new_supported_devices": ["gemtek,xr1710g-ubi"],
  "supported_devices": ["gemtek,xr1710g-ubi - Image version mismatch: image 2.0, device 1.0. Please wipe config during upgrade (force required) or reinstall."],
  "version": { "dist": "OpenWrt", "version": "SNAPSHOT", "revision": "r1",
               "target": "airoha/an7581", "board": "gemtek,xr1710g-ubi" } }
JSON

# A 1.x image: no major bump, so the device list is supported_devices and there
# is no new_supported_devices at all.
cat >"$WORK/meta-1.0.json" <<'JSON'
{ "metadata_version": "1.1", "compat_version": "1.0",
  "supported_devices": ["gemtek,xr1710g-ubi"],
  "version": { "dist": "OpenWrt", "version": "SNAPSHOT", "revision": "r1",
               "target": "airoha/an7581", "board": "gemtek,xr1710g-ubi" } }
JSON

# Same as the 1.x image but with the compat_version key not written at all:
# fwtool.sh defaults the missing value to 1.0, so this is still a 1.x image.
sed 's/ "compat_version": "1.0",//' "$WORK/meta-1.0.json" >"$WORK/meta-nocompat.json"

# Metadata for another board entirely (same shape, other name).
sed 's/gemtek,xr1710g-ubi/gemtek,w1700k-ubi/g' "$WORK/meta-2.0.json" \
	>"$WORK/meta-other-board.json"

printf '2.0\n' >"$WORK/dev-compat-2.0"
: >"$WORK/dev-compat-none"

printf 'gemtek,xr1710g-ubi\n' >"$SBX/tmp/sysinfo/board_name"
: >"$SBX/tmp/sysinfo/oem_name"

# The image itself is only ever opened by fwtool and readlink here; the stub
# supplies the metadata, so four magic bytes are enough.
printf '\320\015\376\355' >"$WORK/image.itb"
head -c 512 /dev/zero >>"$WORK/image.itb"

# --- runner -----------------------------------------------------------------

OUT=''
VAL_OUT=''
RC=0
CASE=''

reset_env() {
	CASE=$1
	FAKE_META=$WORK/meta-2.0.json
	FAKE_DEVICE_COMPAT=$WORK/dev-compat-2.0
	FAKE_SIG_RC=1
	REQUIRE_IMAGE_METADATA=1
	REQUIRE_IMAGE_SIGNATURE=0
}

json_bool() {
	sed -n -e "s/^\t\"$1\": \(true\|false\),$/\1/p" \
		-e "s/^\t\"$1\": \(true\|false\)$/\1/p" "$VAL_OUT" | head -n 1
}

run_validator() {
	PATH="$SBX/bin:$PATH" \
		FAKE_META="$FAKE_META" \
		FAKE_DEVICE_COMPAT="$FAKE_DEVICE_COMPAT" \
		FAKE_SIG_RC="$FAKE_SIG_RC" \
		REQUIRE_IMAGE_METADATA="$REQUIRE_IMAGE_METADATA" \
		REQUIRE_IMAGE_SIGNATURE="$REQUIRE_IMAGE_SIGNATURE" \
		bash "$SBX/usr/libexec/validate_firmware_image" "$WORK/image.itb" \
		>"$WORK/val.out" 2>"$WORK/val.err"
	RC=$?
	VAL_OUT="$WORK/val.out"
	OUT=$(cat "$WORK/val.out" "$WORK/val.err")
}

# sysupgrade, called the way flash-gate.sh and the operator call it.  -T never
# touches flash, so this is safe even on a box.
run_sysupgrade() {
	PATH="$SBX/bin:$PATH" \
		FAKE_META="$FAKE_META" \
		FAKE_DEVICE_COMPAT="$FAKE_DEVICE_COMPAT" \
		FAKE_SIG_RC="$FAKE_SIG_RC" \
		REQUIRE_IMAGE_METADATA="$REQUIRE_IMAGE_METADATA" \
		REQUIRE_IMAGE_SIGNATURE="$REQUIRE_IMAGE_SIGNATURE" \
		bash "$SBX/sbin/sysupgrade" "$@" "$WORK/image.itb" \
		>"$WORK/sys.out" 2>&1
	RC=$?
	OUT=$(cat "$WORK/sys.out")
	ERR="$OUT"
}

expect_rc() {
	[ "$RC" = "$1" ] || fail "$CASE: rc=$RC, wanted $1; output: $OUT"
}

expect_json() {
	v=$(json_bool "$1")
	[ "$v" = "$2" ] || fail "$CASE: $1=$v, wanted $2; validator output: $(cat "$WORK/val.out")"
}

expect_out() {
	printf '%s\n' "$OUT" | grep -q -- "$1" || fail "$CASE: output lacks '$1'; output: $OUT"
}

expect_no_out() {
	if printf '%s\n' "$OUT" | grep -q -- "$1"; then
		fail "$CASE: output should not contain '$1'; output: $OUT"
	fi
}

# --- 1: 2.0 image, 2.0 device ------------------------------------------------

reset_env matches
run_validator
expect_rc 0
expect_json valid true
expect_json forceable true
run_sysupgrade -T
expect_rc 0

# --- 2: 2.0 image, 1.x device: -F must not help ------------------------------

reset_env layout-bump
FAKE_DEVICE_COMPAT=$WORK/dev-compat-none
run_validator
expect_rc 0
expect_json valid false
expect_json forceable false
run_sysupgrade -T -F
expect_rc 1
expect_out 'incompatible for sysupgrade based on the image version (1.0->2.0)'
expect_out 'BMT/BBT partition at the end of flash'
expect_out 'a different flash layout'
expect_out 'Image check failed.'
expect_no_out 'will update anyway'
# ... and it was already refused without -F, for the same reason.
run_sysupgrade -T
expect_rc 1

# --- 3: 1.x image, 2.0 device: the other direction bricks too ----------------

reset_env layout-downgrade
FAKE_META=$WORK/meta-1.0.json
run_validator
expect_rc 0
expect_json valid false
expect_json forceable false
run_sysupgrade -T -F
expect_rc 1
expect_out 'incompatible for sysupgrade based on the image version (2.0->1.0)'
expect_no_out 'will update anyway'

# --- 4: no compat_version in the metadata, 2.0 device ------------------------

reset_env compat-absent
FAKE_META=$WORK/meta-nocompat.json
run_validator
expect_rc 0
expect_json valid false
expect_json forceable false
run_sysupgrade -T -F
expect_rc 1
expect_out 'incompatible for sysupgrade based on the image version (2.0->1.0)'
expect_no_out 'will update anyway'

# --- 5: signature required and absent, compat matches: still forceable -------

reset_env signature-missing
REQUIRE_IMAGE_SIGNATURE=1
FAKE_SIG_RC=1
run_validator
expect_rc 0
expect_json valid false
expect_json forceable true
run_sysupgrade -T -F
expect_rc 0
expect_out 'Image check failed but --force given - will update anyway!'

# --- 6: stock flags, nothing to complain about -------------------------------

reset_env clean
REQUIRE_IMAGE_METADATA=0
REQUIRE_IMAGE_SIGNATURE=0
run_validator
expect_rc 0
expect_json valid true
expect_json forceable true
run_sysupgrade -T
expect_rc 0
expect_no_out 'Image check failed'

# --- 7: image built for another board: forceable, that is the escape hatch ----

reset_env other-board
FAKE_META=$WORK/meta-other-board.json
run_validator
expect_rc 0
expect_json valid false
expect_json forceable true
run_sysupgrade -T -F
expect_rc 0
expect_out 'Device gemtek,xr1710g-ubi not supported by this image'
expect_out 'Image check failed but --force given - will update anyway!'

# --- 8: no compat field on either side: 1.0 == 1.0, nothing to guard ---------

reset_env both-absent
FAKE_META=$WORK/meta-nocompat.json
FAKE_DEVICE_COMPAT=$WORK/dev-compat-none
run_validator
expect_rc 0
expect_json valid true
expect_json forceable true
run_sysupgrade -T
expect_rc 0

[ "$FAILED" = 0 ] || {
	printf 'compat-not-forceable cases failed\n' >&2
	exit 1
}
printf 'all compat-not-forceable cases passed\n'
