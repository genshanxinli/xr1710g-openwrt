#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# flash-gate.sh -- pre-flash gate for the Gemtek XR1710G (OpenWrt U-Boot layout).
#
# Issue #88 (G0).  The gate is a script, not a checklist, because a checklist
# cannot refuse.  It answers one question -- "may this image be flashed on this
# box right now?" -- and the answer is a process exit status.
#
# What the gate knows that the stock code path does not:
#
#   * sysupgrade -T runs the image through validate_firmware_image() ->
#     platform_check_image().  A plain FIT whose metadata does not match the
#     board comes back "Image check failed." (rc=1) and *-F* turns that into
#     "Image check failed but --force given - will update anyway!" and the flash
#     proceeds (package/base-files/files/sbin/sysupgrade:407-414).  The two
#     ok returns in platform_check_image() -- missing dumpimage and an FDT
#     description for another board -- are 74 (notify_firmware_broken) and
#     forceable=0, so -F cannot bypass those
#     (target/linux/airoha/an7581/base-files/lib/upgrade/platform.sh:48-62).
#     A major compat_version mismatch is 74 as well (lib/upgrade/fwtool.sh),
#     which is what makes issue #7 a real gate rather than a suggestion.
#     Everything else can be forced.  This gate therefore treats -F as a
#     separate, explicit decision: it is refused unless --i-know is also given,
#     and it is still refused when the backup did not succeed.
#
#   * the box has no nanddump (checked on the running image: /usr/bin has
#     sha256sum and /bin/dd, no nanddump), so the backup is dd + sha256sum over
#     the read-only char devices.  Nothing here needs scp, nohup or a second
#     host: the manifest is written next to the images and verified in place.
#
#   * the image is built for one flash layout.  /proc/mtd names and sizes are
#     what the FIT's UBI offsets assume, so a box whose partition table drifted
#     (vendor bootloader rewrite, BMT relocation, a foreign chainloader) is
#     refused before anything is written.  The expected table below is the one
#     target/linux/airoha/dts/an7581-xr1710g-ubi.dts describes and the one
#     measured on the bench box:
#
#       mtd0 00600000 00020000 "vendor"
#       mtd1 00100000 00020000 "chainloader"
#       mtd2 1b700000 00020000 "ubi"
#       mtd3 04200000 00020000 "reserved_bmt"
#
# Usage:
#   flash-gate.sh --image IMAGE [options]        full gate, then print/exec
#   flash-gate.sh --probe                        read-only: layout + dd + sha256,
#                                                writes nothing, needs no image
#
# Options:
#   -i, --image PATH      sysupgrade image to verify
#   -F, --force           pass -F to sysupgrade (requires --i-know, and a backup
#                         that verified; code 74 still blocks at sysupgrade level)
#       --i-know          acknowledge that a forced flash can soft-brick the box
#   -d, --backup-dir DIR  where to write backup/<timestamp>/ (default
#                         $FLASH_GATE_BACKUP_DIR, else /tmp/flash-gate)
#   -n, --head-kb N       kilobytes read from each partition (default 256)
#       --no-backup       skip the backup (the gate then never passes with -F)
#       --no-sysupgrade   do not run "sysupgrade -T"
#       --no-layout       do not compare /proc/mtd against the board table
#       --run             exec sysupgrade once the gate has passed
#   -h, --help            this text
#
# Exit status:
#   0  gate passed                 3  -F without --i-know
#   2  usage / image missing       4  image or layout mismatch, unverifiable
#   5  backup failed               6  sysupgrade -T rejected the image
#
# Environment overrides exist for the self-test only (scripts/tests/
# test_flash_gate.sh): FG_BOARD_NAME, FG_PROC_MTD, FG_MTD_DEV_DIR, FG_UBI_DIR,
# FG_BACKUP_DIR.  On the box none of them are set and the defaults are used.

set -u

EXIT_USAGE=2
EXIT_FORCE=3
EXIT_COMPAT=4
EXIT_BACKUP=5
EXIT_IMAGE=6

IMAGE=''
FORCE=0
IKNOW=0
PROBE=0
DO_BACKUP=1
DO_SYSUPGRADE=1
DO_LAYOUT=1
RUN=0
BACKUP_ROOT=${FG_BACKUP_DIR:-/tmp/flash-gate}
HEAD_KB=256
BOARD_NAME=${FG_BOARD_NAME:-}
PROC_MTD=${FG_PROC_MTD:-/proc/mtd}
MTD_DEV_DIR=${FG_MTD_DEV_DIR:-/dev}
UBI_DIR=${FG_UBI_DIR:-/sys/class/ubi}

WORK=''

cleanup() {
	[ -n "$WORK" ] && rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

usage() {
	sed -n '/^# Usage:/,/^# Environment overrides/p' "$0" | sed 's/^# \{0,1\}//'
}

say() {
	printf '%s\n' "$*"
}

err() {
	printf '%s\n' "$*" >&2
}

# row KEY EXPECTED ACTUAL VERDICT -- one line per assertion, so the CI log and
# the issue comment can be diffed instead of read.
row() {
	printf '%-30s expected=%-22s actual=%-26s %s\n' "$1" "$2" "$3" "$4"
}

die() {
	code=$1
	shift
	err "GATE REFUSED: $*"
	exit "$code"
}

# ---------------------------------------------------------------- arguments

while [ $# -gt 0 ]; do
	case "$1" in
	-h|--help)
		usage
		exit 0
		;;
	-i|--image)
		[ $# -ge 2 ] || die "$EXIT_USAGE" "$1 needs a value"
		IMAGE=$2
		shift 2
		;;
	-F|--force)
		FORCE=1
		shift
		;;
	--i-know)
		IKNOW=1
		shift
		;;
	--probe)
		PROBE=1
		DO_BACKUP=0
		DO_SYSUPGRADE=0
		DO_LAYOUT=1
		shift
		;;
	-d|--backup-dir)
		[ $# -ge 2 ] || die "$EXIT_USAGE" "$1 needs a value"
		BACKUP_ROOT=$2
		shift 2
		;;
	-n|--head-kb)
		[ $# -ge 2 ] || die "$EXIT_USAGE" "$1 needs a value"
		HEAD_KB=$2
		shift 2
		;;
	--no-backup)
		DO_BACKUP=0
		shift
		;;
	--no-sysupgrade)
		DO_SYSUPGRADE=0
		shift
		;;
	--no-layout)
		DO_LAYOUT=0
		shift
		;;
	--run)
		RUN=1
		shift
		;;
	--)
		shift
		break
		;;
	-*)
		err "unknown option: $1"
		usage >&2
		exit "$EXIT_USAGE"
		;;
	*)
		[ -z "$IMAGE" ] || die "$EXIT_USAGE" "only one image may be given"
		IMAGE=$1
		shift
		;;
	esac
done
[ $# -eq 0 ] || [ -n "$IMAGE" ] || die "$EXIT_USAGE" "unexpected argument: $1"

case "$HEAD_KB" in
''|*[!0-9]*) die "$EXIT_USAGE" "--head-kb needs a number, got '$HEAD_KB'" ;;
esac
[ "$HEAD_KB" -gt 0 ] || die "$EXIT_USAGE" "--head-kb must be > 0"

[ -n "$BOARD_NAME" ] || BOARD_NAME=$(cat /tmp/sysinfo/board_name 2>/dev/null || true)
WORK=$(mktemp -d 2>/dev/null) || die "$EXIT_BACKUP" "cannot create a work directory"

say "flash-gate: board=${BOARD_NAME:-unknown} image=${IMAGE:-none} force=$FORCE i-know=$IKNOW"
printf '%-30s %-29s %-34s %s\n' key expected actual verdict

# --------------------------------------------------- 1. forced-flash consent
# Checked before anything touches flash: -F on this box means "ignore the
# image check", which is exactly the case that produced the soft-brick in #88.
if [ "$FORCE" = 1 ] && [ "$IKNOW" != 1 ]; then
	row force.consent --i-know missing FAIL
	die "$EXIT_FORCE" "-F/--force needs --i-know; a forced flash skips the image check that code 74 does not cover"
fi
if [ "$FORCE" = 1 ]; then
	row force.consent --i-know given PASS
else
	row force.consent plain-flash plain-flash PASS
fi

# ----------------------------------------------------------- 2. flash layout
# Expected layout per board.  Sizes are the /proc/mtd 8-hex form, lowercase.
layout_for() {
	case "$1" in
	gemtek,xr1710g-ubi)
		cat <<'LAYOUT'
vendor 00600000
chainloader 00100000
ubi 1b700000
reserved_bmt 04200000
LAYOUT
		;;
	esac
}

norm_hex() {
	printf '%s' "$1" | tr 'A-F' 'a-f' | sed 's/^0*//'
}

LAYOUT_FAILED=0
UBI_MTD_NUM=''

if [ "$DO_LAYOUT" = 1 ]; then
	EXPECTED=$(layout_for "$BOARD_NAME")
	[ -n "$EXPECTED" ] || {
		row board.table "$BOARD_NAME" "no layout table" FAIL
		die "$EXIT_COMPAT" "no flash-layout table for board '$BOARD_NAME'; refusing an unverifiable image"
	}
	[ -r "$PROC_MTD" ] || {
		row mtd.table "$PROC_MTD" "unreadable" FAIL
		die "$EXIT_COMPAT" "$PROC_MTD is unreadable; cannot verify the flash layout"
	}

	awk '$1 !~ /^mtd[0-9]+:$/ { next }
	     { n = $1; sub(/:$/, "", n); size = $2; erase = $3; name = $0
	       sub(/^[^"]*"/, "", name); sub(/".*$/, "", name)
	       printf "%s %s %s %s\n", n, size, erase, name }' "$PROC_MTD" > "$WORK/parts"

	while read -r pnum psize perase pname; do
		want=$(awk -v n="$pname" '$1 == n { print $2; exit }' <<EOF
$EXPECTED
EOF
)
		if [ -z "$want" ]; then
			row "mtd.${pname}" "not in board table" "$psize" FAIL
			LAYOUT_FAILED=1
			continue
		fi
		if [ "$(norm_hex "$want")" = "$(norm_hex "$psize")" ]; then
			row "mtd.${pname}.size" "$want" "$psize" PASS
		else
			row "mtd.${pname}.size" "$want" "$psize" FAIL
			LAYOUT_FAILED=1
		fi
		if [ "$(norm_hex "$perase")" = '20000' ]; then
			row "mtd.${pname}.erasesize" 00020000 "$perase" PASS
		else
			row "mtd.${pname}.erasesize" 00020000 "$perase" FAIL
			LAYOUT_FAILED=1
		fi
		[ "$pname" = ubi ] && UBI_MTD_NUM=$(printf '%s' "$pnum" | sed 's/^mtd//')

		# Every name in the board table must exist; a short /proc/mtd is what
		# a half-rewritten vendor bootloader looks like.
	done < "$WORK/parts"

	for want_name in $(printf '%s\n' "$EXPECTED" | awk '{ print $1 }'); do
		if ! awk -v n="$want_name" '$4 == n { found = 1 } END { exit !found }' "$WORK/parts"; then
			row "mtd.${want_name}.present" present missing FAIL
			LAYOUT_FAILED=1
		fi
	done

	if [ -n "$UBI_MTD_NUM" ] && [ -d "$UBI_DIR" ]; then
		if [ -r "$UBI_DIR/ubi0/mtd_num" ] &&
		   [ "$(cat "$UBI_DIR/ubi0/mtd_num")" = "$UBI_MTD_NUM" ]; then
			row ubi0.attached "mtd$UBI_MTD_NUM" "ubi0 -> mtd$UBI_MTD_NUM" PASS
		else
			row ubi0.attached "mtd$UBI_MTD_NUM" "not attached" FAIL
			LAYOUT_FAILED=1
		fi
		# The image writes volume 0 (cmdline: ubi.block=0,fit).
		if [ -d "$UBI_DIR/ubi0_0" ]; then
			row ubi0_0.present present present PASS
		else
			row ubi0_0.present present missing FAIL
			LAYOUT_FAILED=1
		fi
	fi

	[ "$LAYOUT_FAILED" = 0 ] || die "$EXIT_COMPAT" "flash layout does not match the image's assumptions"
fi

# --------------------------------------------------------- 3. image compat
extract_metadata() {
	# $1 = image.  fwtool is the real extractor; without it the metadata JSON
	# sits in the appended trailer, so the last 8 KiB carries it verbatim.
	if command -v fwtool >/dev/null 2>&1; then
		if fwtool -q -i "$WORK/meta.json" "$1" 2>/dev/null && [ -s "$WORK/meta.json" ]; then
			cat "$WORK/meta.json"
			return 0
		fi
	fi
	tail -c 8192 "$1" 2>/dev/null | tr -d '\000'
}

if [ "$PROBE" = 0 ]; then
	[ -n "$IMAGE" ] || die "$EXIT_USAGE" "no image given (use --image PATH, or --probe for a read-only layout check)"
	[ -f "$IMAGE" ] || die "$EXIT_USAGE" "image not found: $IMAGE"

	MAGIC=$(head -c 4 "$IMAGE" | od -An -tx1 | tr -d ' \n')
	if [ "$MAGIC" = d00dfeed ]; then
		row image.fit d00dfeed "$MAGIC" PASS
	else
		row image.fit d00dfeed "${MAGIC:-empty}" FAIL
		die "$EXIT_COMPAT" "$IMAGE is not a FIT image"
	fi

	META=$(extract_metadata "$IMAGE")
	# supported_devices entries can carry a " - <reason>" suffix: that is how
	# fwtool spells a compat_version mismatch inside the list (the bench image
	# has exactly that, plus a clean new_supported_devices list), so compare the
	# part before the separator.  Anchored on the list itself rather than on the
	# whole line, because the trailer is not a line of JSON once binary follows.
	SDEV=$(printf '%s' "$META" |
		grep -ao 'supported_devices": *\[[^]]*\]' | head -n 1 |
		sed 's/^[^[]*\[//; s/\]$//; s/", *"/\n/g; s/"//g; s/ - .*$//')
	if [ -n "$SDEV" ]; then
		# One device per line: board names contain a comma, so split on the
		# quoted separator, not on ','.
		if printf '%s' "$SDEV" | sed 's/", *"/\n/g; s/"//g' | grep -qx "$BOARD_NAME"; then
			row image.device "$BOARD_NAME" "supported_devices lists it" PASS
		else
			row image.device "$BOARD_NAME" "$(printf '%s' "$SDEV" | tr -d '"')" FAIL
			die "$EXIT_COMPAT" "image is built for another board; -F must not cross-flash it"
		fi
	elif printf '%s\n' "$META" | grep -q "\"$BOARD_NAME\""; then
		row image.device "$BOARD_NAME" "device field matches" PASS
	else
		# No metadata at all: fall back to the FDT description the platform
		# check itself uses, and refuse when that is inconclusive too.
		DESC=''
		if command -v dumpimage >/dev/null 2>&1; then
			DESC=$(dumpimage -l "$IMAGE" 2>/dev/null |
				sed -n 's/^ *Description: .* OpenWrt \(.*\) device tree blob$/\1/p' | head -n 1)
		fi
		if [ -n "$DESC" ] && [ "$DESC" = "$(printf '%s' "$BOARD_NAME" | tr ',' '_')" ]; then
			row image.device "$BOARD_NAME" "FDT description $DESC" PASS
		else
			row image.device "$BOARD_NAME" "${DESC:-no metadata, no dumpimage}" FAIL
			die "$EXIT_COMPAT" "cannot verify that $IMAGE is built for $BOARD_NAME"
		fi
	fi

	# The stock validator, run exactly as sysupgrade runs it.  This is the same
	# check -F bypasses, so its verdict is reported separately from the gate's
	# own one.
	if [ "$DO_SYSUPGRADE" = 1 ]; then
		if command -v sysupgrade >/dev/null 2>&1; then
			sysupgrade -T "$IMAGE" >"$WORK/sysupgrade-T.log" 2>&1
			SRC=$?
			# Never assume that a rejected image is forceable: with --force,
			# ask the validator again with -F and let it decide.  A major
			# compat version mismatch (UBI layout 1.x vs 2.0) is reported as
			# notify_firmware_broken, so `-T -F` still exits 1 there and this
			# row fails (issue #7).  -T never writes to flash.
			SRC_FORCED=1
			[ "$FORCE" = 1 ] && {
				sysupgrade -T -F "$IMAGE" >"$WORK/sysupgrade-TF.log" 2>&1
				SRC_FORCED=$?
			}
			if [ "$SRC" = 0 ]; then
				row sysupgrade.T 0 "$SRC" PASS
			elif [ "$FORCE" = 1 ] && [ "$SRC_FORCED" = 0 ]; then
				# forceable=1 (missing signature, unknown board): -F lets it
				# through, but only with --i-know, which the consent row above
				# already required.
				row sysupgrade.T 0 "$SRC (forceable)" PASS
				err "note: sysupgrade -T rejected the image, proceeding because --force --i-know was given"
			else
				row sysupgrade.T 0 "$SRC" FAIL
				sed 's/^/    /' "$WORK/sysupgrade-T.log" >&2
				[ "$FORCE" = 1 ] && sed 's/^/    /' "$WORK/sysupgrade-TF.log" >&2
				die "$EXIT_IMAGE" "sysupgrade -T rejected the image and -F cannot override this rejection"
			fi
		else
			row sysupgrade.T 0 "sysupgrade missing" SKIP
		fi
	fi
fi

# ------------------------------------------------------------- 4. the backup
# dd from the read-only char device, sha256 per partition, manifest verified by
# re-reading the files.  In --probe mode nothing is written: the same dd read
# is piped into sha256sum, so the gate still proves the flash is readable.
EMPTY_SHA=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855

if [ "$DO_BACKUP" = 1 ] || [ "$PROBE" = 1 ]; then
	[ -r "$WORK/parts" ] || die "$EXIT_BACKUP" "no partition table to back up"
	TS=$(date +%Y%m%d-%H%M%S)
	if [ "$PROBE" = 1 ]; then
		BKDIR=''
	else
		BKDIR="$BACKUP_ROOT/$TS"
		mkdir -p "$BKDIR" || die "$EXIT_BACKUP" "cannot create $BKDIR"
		cp "$PROC_MTD" "$BKDIR/mtd.txt" || die "$EXIT_BACKUP" "cannot copy $PROC_MTD"
	fi

	BACKUP_FAILED=''
	while read -r pnum psize perase pname; do
		DEV="$MTD_DEV_DIR/${pnum}ro"
		[ -e "$DEV" ] || DEV="$MTD_DEV_DIR/$pnum"
		if [ ! -e "$DEV" ]; then
			row "backup.${pname}" readable "no $DEV" FAIL
			BACKUP_FAILED="$BACKUP_FAILED $pname"
			continue
		fi

		# Whole partition when it is smaller than HEAD_KB, else HEAD_KB.
		CAP=$((HEAD_KB * 1024))
		SIZE=$((0x$psize))
		[ "$SIZE" -gt 0 ] || SIZE=0
		[ "$CAP" -le "$SIZE" ] || CAP=$SIZE
		CNT=$(( (CAP + 4095) / 4096 ))
		[ "$CNT" -gt 0 ] || CNT=1
		WANT=$((CNT * 4096))
		[ "$WANT" -le "$SIZE" ] || WANT=$SIZE

		if [ "$PROBE" = 1 ]; then
			SHA=$(dd if="$DEV" bs=4096 count="$CNT" 2>/dev/null | sha256sum | awk '{ print $1 }')
			if [ -n "$SHA" ] && [ "$SHA" != "$EMPTY_SHA" ]; then
				row "dd.${pname}" "sha256 of ${CNT}x4KiB" "$SHA" PASS
			else
				row "dd.${pname}" "sha256 of ${CNT}x4KiB" "read failed" FAIL
				BACKUP_FAILED="$BACKUP_FAILED $pname"
			fi
			continue
		fi

		OUT="$BKDIR/${pname}.head"
		if ! dd if="$DEV" of="$OUT" bs=4096 count="$CNT" 2>"$BKDIR/dd-${pname}.err"; then
			row "backup.${pname}" "dd ok" "dd failed" FAIL
			BACKUP_FAILED="$BACKUP_FAILED $pname"
			continue
		fi
		GOT=$(wc -c < "$OUT" | tr -d ' ')
		if [ "$GOT" != "$WANT" ]; then
			row "backup.${pname}" "$WANT bytes" "$GOT bytes" FAIL
			BACKUP_FAILED="$BACKUP_FAILED $pname"
			continue
		fi
		row "backup.${pname}" "$WANT bytes" "$GOT bytes" PASS
	done < "$WORK/parts"

	if [ -n "$BACKUP_FAILED" ]; then
		die "$EXIT_BACKUP" "backup failed for:$BACKUP_FAILED -- refusing to flash without one"
	fi

	if [ "$PROBE" = 0 ]; then
		# The manifest is the point: a backup nobody verified is not a backup.
		if ( cd "$BKDIR" && sha256sum *.head mtd.txt > manifest.sha256 2>/dev/null &&
		     sha256sum -c manifest.sha256 >/dev/null 2>&1 ); then
			row backup.verify "sha256 -c" "manifest ok" PASS
		else
			row backup.verify "sha256 -c" "manifest mismatch" FAIL
			die "$EXIT_BACKUP" "the backup does not verify against its own manifest"
		fi
		{
			printf 'board %s\n' "$BOARD_NAME"
			printf 'date %s\n' "$(date -u 2>/dev/null || date)"
			printf 'kernel %s\n' "$(uname -r 2>/dev/null || echo unknown)"
			printf 'head_kb %s\n' "$HEAD_KB"
			if [ -n "$IMAGE" ]; then
				printf 'image %s\n' "$IMAGE"
				printf 'image_sha256 %s\n' "$(sha256sum "$IMAGE" | awk '{ print $1 }')"
			fi
			printf 'force %s\n' "$FORCE"
		} > "$BKDIR/meta.txt"
		say "backup: $BKDIR"
	fi
	# -F with --i-know but no verified backup is the one combination that must
	# never reach the flasher.
elif [ "$FORCE" = 1 ]; then
	row backup.required "verified backup" "--no-backup" FAIL
	die "$EXIT_BACKUP" "-F/--force requires a verified backup; --no-backup cannot be combined with it"
fi

say "GATE PASS"
if [ "$PROBE" = 1 ]; then
	say "probe only: layout and dd reads verified, nothing written"
	exit 0
fi

if [ "$FORCE" = 1 ]; then
	say "next: sysupgrade -F $IMAGE"
	say "      (code 74 -- missing dumpimage, foreign FDT -- still blocks at sysupgrade level)"
else
	say "next: sysupgrade $IMAGE"
fi
if [ "$RUN" = 1 ]; then
	if [ "$FORCE" = 1 ]; then
		exec sysupgrade -F "$IMAGE"
	fi
	exec sysupgrade "$IMAGE"
fi
exit 0
