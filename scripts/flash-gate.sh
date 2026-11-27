#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Pre-flash safety gate for Gemtek XR1710G (4-part UBI layout; never -F, mtd0/1/3 strictly RO).
set -u

EXIT_USAGE=2; EXIT_FORCE=3; EXIT_COMPAT=4; EXIT_BACKUP=5; EXIT_IMAGE=6
BOARD_EXPECTED='gemtek,xr1710g-ubi'
EMPTY_SHA='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'

IMAGE=''; SUMS_ARG=''; PROBE=0; CHECK_ONLY=0; RUN=0; HEAD_KB=256; WORK=''
BACKUP_ROOT=${FG_BACKUP_DIR:-/tmp/flash-gate}

cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

usage() {
	cat <<'EOF'
Usage:
  flash-gate.sh -i IMAGE [options]   verify layout, image, sysupgrade -T, and mtd0/mtd1 backup
  flash-gate.sh --probe              read-only layout, UBI, and mtd0/mtd1 read check

Options:
  -i, --image PATH       sysupgrade FIT image to verify
  -s, --sha256sums PATH  sha256sums file to verify image digest against
  -d, --backup-dir DIR   backup root (default: /tmp/flash-gate)
  -n, --head-kb N        KiB to back up from mtd0/mtd1 (default: 256)
      --dry-run          verify all gates read-only without backup writes or flashing
      --check-only       alias for --dry-run
      --run              exec plain sysupgrade after all checks and verified backup pass
  -h, --help             show this help

Hard rules: -F/--force is unconditionally refused; mtd0/mtd1/mtd3 are strictly read-only.
Exit codes: 0 pass, 2 usage, 3 -F refused, 4 layout/image compat, 5 backup fail, 6 sysupgrade -T fail.
EOF
}

say() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }
row() { printf '%-28s expected=%-20s actual=%-24s %s\n' "$1" "$2" "$3" "$4"; }
die() { code=$1; shift; err "GATE REFUSED: $*"; exit "$code"; }
norm_hex() { printf '%s' "$1" | tr 'A-F' 'a-f' | sed 's/^0*//'; }

while [ $# -gt 0 ]; do
	case "$1" in
	-h|--help) usage; exit 0 ;;
	-i|--image) [ $# -ge 2 ] || die "$EXIT_USAGE" "$1 needs a value"; IMAGE=$2; shift 2 ;;
	-s|--sha256sums) [ $# -ge 2 ] || die "$EXIT_USAGE" "$1 needs a value"; SUMS_ARG=$2; shift 2 ;;
	-d|--backup-dir) [ $# -ge 2 ] || die "$EXIT_USAGE" "$1 needs a value"; BACKUP_ROOT=$2; shift 2 ;;
	-n|--head-kb) [ $# -ge 2 ] || die "$EXIT_USAGE" "$1 needs a value"; HEAD_KB=$2; shift 2 ;;
	--probe) PROBE=1; CHECK_ONLY=1; shift ;;
	--dry-run|--check-only) CHECK_ONLY=1; shift ;;
	--run) RUN=1; shift ;;
	-F|--force)
		row force.policy plain-sysupgrade "$1" FAIL
		die "$EXIT_FORCE" "-F/--force is unconditionally refused; never force-flash XR1710G" ;;
	--)
		shift
		while [ $# -gt 0 ]; do
			[ -z "$IMAGE" ] || die "$EXIT_USAGE" "only one image may be given"
			IMAGE=$1; shift
		done
		break ;;
	-*) err "unknown option: $1"; usage >&2; exit "$EXIT_USAGE" ;;
	*) [ -z "$IMAGE" ] || die "$EXIT_USAGE" "only one image may be given"; IMAGE=$1; shift ;;
	esac
done
case "$IMAGE" in -*) IMAGE="./$IMAGE" ;; esac
[ "$RUN" = 1 ] && [ "$CHECK_ONLY" = 1 ] && die "$EXIT_USAGE" "--run conflicts with --probe/--dry-run/--check-only"
case "$HEAD_KB" in ''|*[!0-9]*) die "$EXIT_USAGE" "--head-kb must be a positive integer" ;; esac
[ "$HEAD_KB" -gt 0 ] || die "$EXIT_USAGE" "--head-kb must be > 0"

if [ "$RUN" = 1 ]; then
	for _v in FG_BOARD_NAME FG_PROC_MTD FG_MTD_DEV_DIR FG_UBI_DIR FG_IMAGE_SHA256 FG_SYSUPGRADE FG_DEVICE_COMPAT FG_SYSTEM_CONFIG; do
		eval "_val=\${$_v:-}"
		[ -z "$_val" ] || { row env.override 'unset in --run' "$_v" FAIL; die "$EXIT_COMPAT" "$_v override is forbidden with --run"; }
	done
fi

BOARD_NAME=${FG_BOARD_NAME:-}
PROC_MTD=${FG_PROC_MTD:-/proc/mtd}
MTD_DEV_DIR=${FG_MTD_DEV_DIR:-/dev}
UBI_DIR=${FG_UBI_DIR:-/sys/class/ubi}
ENV_DIGEST=${FG_IMAGE_SHA256:-}
SYSUPGRADE=${FG_SYSUPGRADE:-sysupgrade}
[ "$RUN" = 1 ] && SYSUPGRADE='sysupgrade'
DEVICE_COMPAT=${FG_DEVICE_COMPAT:-}
SYSTEM_CFG=${FG_SYSTEM_CONFIG:-/etc/config/system}

[ -n "$BOARD_NAME" ] || BOARD_NAME=$(cat /tmp/sysinfo/board_name 2>/dev/null || true)
WORK=$(mktemp -d 2>/dev/null) || die "$EXIT_BACKUP" "cannot create temp dir"
say "flash-gate: board=${BOARD_NAME:-unknown} image=${IMAGE:-none}"
printf '%-28s %-29s %-31s %s\n' key expected actual verdict
row force.policy plain-sysupgrade plain-sysupgrade PASS

[ "$BOARD_NAME" = "$BOARD_EXPECTED" ] || { row board.name "$BOARD_EXPECTED" "${BOARD_NAME:-unknown}" FAIL; die "$EXIT_COMPAT" "unsupported board '${BOARD_NAME:-unknown}'"; }
row board.name "$BOARD_EXPECTED" "$BOARD_NAME" PASS

[ -r "$PROC_MTD" ] || { row mtd.table "$PROC_MTD" unreadable FAIL; die "$EXIT_COMPAT" "$PROC_MTD unreadable"; }
awk '$1 !~ /^mtd[0-9]+:$/ { next }
     { n=$1; sub(/:$/, "", n); name=$0; sub(/^[^"]*"/, "", name); sub(/".*$/, "", name)
       printf "%s %s %s %s\n", n, $2, $3, name }' "$PROC_MTD" > "$WORK/parts"

LAYOUT_FAIL=0; PART_COUNT=0
while read -r pnum psize perase pname; do
	PART_COUNT=$((PART_COUNT + 1))
	case "$pnum:$pname" in
	mtd0:vendor) want='00600000' ;;
	mtd1:chainloader) want='00100000' ;;
	mtd2:ubi) want='1b700000' ;;
	mtd3:reserved_bmt) want='04200000' ;;
	*) row "mtd.${pnum}" '4-part layout' "${pnum}:${pname}:${psize}" FAIL; LAYOUT_FAIL=1; continue ;;
	esac
	if [ "$(norm_hex "$psize")" = "$(norm_hex "$want")" ]; then row "mtd.${pname}.size" "$want" "$psize" PASS
	else row "mtd.${pname}.size" "$want" "$psize" FAIL; LAYOUT_FAIL=1; fi
	if [ "$(norm_hex "$perase")" = '20000' ]; then row "mtd.${pname}.erase" 00020000 "$perase" PASS
	else row "mtd.${pname}.erase" 00020000 "$perase" FAIL; LAYOUT_FAIL=1; fi
done < "$WORK/parts"

if [ "$PART_COUNT" -ne 4 ]; then
	row mtd.count 4 "$PART_COUNT" FAIL; LAYOUT_FAIL=1
else
	for req in 'mtd0 vendor' 'mtd1 chainloader' 'mtd2 ubi' 'mtd3 reserved_bmt'; do
		set -- $req
		awk -v d="$1" -v n="$2" '$1==d && $4==n { f=1 } END { exit !f }' "$WORK/parts" || {
			row "mtd.$2" "$1:$2" missing FAIL; LAYOUT_FAIL=1
		}
	done
fi

if [ -r "$UBI_DIR/ubi0/mtd_num" ] && [ "$(cat "$UBI_DIR/ubi0/mtd_num" 2>/dev/null)" = '2' ]; then
	row ubi0.attached mtd2 'ubi0->mtd2' PASS
else
	row ubi0.attached mtd2 'missing/wrong' FAIL; LAYOUT_FAIL=1
fi
if [ -d "$UBI_DIR/ubi0_0" ]; then row ubi0_0.present present present PASS
else row ubi0_0.present present missing FAIL; LAYOUT_FAIL=1; fi
[ "$LAYOUT_FAIL" = 0 ] || die "$EXIT_COMPAT" "flash/UBI layout mismatch"

extract_meta() {
	if command -v fwtool >/dev/null 2>&1; then
		fwtool -q -i "$WORK/meta.json" "$1" 2>/dev/null && [ -s "$WORK/meta.json" ] || return 1
		cat "$WORK/meta.json"; return 0
	fi
	[ "$RUN" = 0 ] || return 1
	tail -c 8192 "$1" 2>/dev/null | LC_ALL=C tr -cd '\011\012\015\040-\176'
}

extract_json_list() {
	printf '%s' "$1" | grep -o "\"$2\"[ 	]*:[ 	]*\[[^]]*\]" | head -n 1 |
		sed 's/^[^[]*\[//; s/\]$//; s/"[ 	]*,[ 	]*"/\
/g' | sed 's/^[ 	]*"//; s/"[ 	]*$//; s/ - .*$//; s/^[ 	]*//; s/[ 	]*$//' | sed '/^$/d'
}

if [ "$PROBE" = 0 ]; then
	[ -n "$IMAGE" ] || die "$EXIT_USAGE" "no image given (use -i PATH or --probe)"
	[ -f "$IMAGE" ] && [ -r "$IMAGE" ] || die "$EXIT_USAGE" "image not readable: $IMAGE"

	MAGIC=$(hexdump -v -n 4 -e '4/1 "%02x"' "$IMAGE" 2>/dev/null | tr -d ' \n')
	[ "$MAGIC" = d00dfeed ] || { row image.fit d00dfeed "${MAGIC:-empty}" FAIL; die "$EXIT_COMPAT" "$IMAGE is not a FIT image"; }
	row image.fit d00dfeed "$MAGIC" PASS

	FSIZE=$(wc -c < "$IMAGE" | tr -d ' ')
	FIT_TOTAL=$(hexdump -v -s 4 -n 4 -e '4/1 "%u "' "$IMAGE" 2>/dev/null |
		awk 'NF==4 { printf "%d", ($1*16777216)+($2*65536)+($3*256)+$4 }')
	if [ "$FSIZE" -lt 16 ] || [ -z "$FIT_TOTAL" ] || [ "$FIT_TOTAL" -le 0 ] || [ "$FSIZE" -lt "$FIT_TOTAL" ]; then
		row image.size ">=FIT(${FIT_TOTAL:-?})" "$FSIZE" FAIL; die "$EXIT_COMPAT" "$IMAGE is truncated ($FSIZE B)"
	fi
	row image.size ">=FIT($FIT_TOTAL)" "$FSIZE" PASS

	ACTUAL=$FSIZE
	[ "$FIT_TOTAL" -gt "$ACTUAL" ] && ACTUAL=$FIT_TOTAL
	EFF=$(( ((ACTUAL + 126975) / 126976) * 126976 ))
	if [ "$EFF" -gt 33488896 ]; then
		row image.ramoops '<=33488896' "${EFF}B(raw=${ACTUAL}B)" FAIL
		die "$EXIT_COMPAT" "$IMAGE UBI-aligned size (${EFF} B, raw ${ACTUAL} B) exceeds 33488896 B ramoops ceiling"
	fi
	row image.ramoops '<=33488896' "${EFF}B" PASS

	case "$IMAGE" in */*) _dir=${IMAGE%/*} ;; *) _dir=. ;; esac
	_name=${IMAGE##*/}
	DIGEST=''
	if [ -n "$SUMS_ARG" ]; then
		[ -r "$SUMS_ARG" ] || { row image.sha256 readable "$SUMS_ARG" FAIL; die "$EXIT_COMPAT" "cannot read $SUMS_ARG"; }
		DIGEST=$(awk -v n="$_name" '($2==n || $2=="*"n){print $1; exit}' "$SUMS_ARG")
		[ -n "$DIGEST" ] || { row image.sha256 "$_name" missing FAIL; die "$EXIT_COMPAT" "$_name absent in $SUMS_ARG"; }
	elif [ -r "$_dir/sha256sums" ]; then
		DIGEST=$(awk -v n="$_name" '($2==n || $2=="*"n){print $1; exit}' "$_dir/sha256sums")
		[ -n "$DIGEST" ] || { row image.sha256 "$_name" missing FAIL; die "$EXIT_COMPAT" "$_name absent in $_dir/sha256sums"; }
	elif [ "$CHECK_ONLY" = 1 ] && [ -n "$ENV_DIGEST" ]; then
		DIGEST=$ENV_DIGEST
	else
		row image.sha256 sha256sums missing FAIL
		die "$EXIT_COMPAT" "no sha256sums file for $IMAGE; refusing unverified image"
	fi
	DIGEST=$(printf '%s' "$DIGEST" | tr 'A-F' 'a-f')
	GOT_SHA=$(sha256sum "$IMAGE" | awk '{print $1}' | tr 'A-F' 'a-f')
	[ "$GOT_SHA" = "$DIGEST" ] || { row image.sha256 "$DIGEST" "$GOT_SHA" FAIL; die "$EXIT_COMPAT" "sha256 mismatch for $IMAGE"; }
	row image.sha256 "$DIGEST" "$GOT_SHA" PASS

	TAIL_MAGIC=$(hexdump -v -s $((FSIZE - 16)) -n 4 -e '4/1 "%02x"' "$IMAGE" 2>/dev/null | tr -d ' \n')
	TAIL_TP=$(hexdump -v -s $((FSIZE - 8)) -n 4 -e '4/1 "%02x"' "$IMAGE" 2>/dev/null | tr -d ' \n')
	if [ "$TAIL_MAGIC" != '46577830' ] || { [ "$TAIL_TP" != '00000000' ] && [ "$TAIL_TP" != '01000000' ]; }; then
		row image.fwx0 46577830 "${TAIL_MAGIC:-none}:${TAIL_TP:-?}" FAIL
		die "$EXIT_COMPAT" "$IMAGE lacks valid 16-byte FWx0 trailer"
	fi
	row image.fwx0 46577830 "$TAIL_MAGIC" PASS

	META=$(extract_meta "$IMAGE") || {
		row image.meta 'valid fwtool meta' 'extract failed' FAIL
		die "$EXIT_COMPAT" "failed to extract verified metadata from $IMAGE"
	}
	META_FLAT=$(printf '%s' "$META" | tr '\r\n' '  ')
	if printf '%s' "$META_FLAT" | tr 'A-Z' 'a-z' | grep -Fq 'w1700k'; then
		row image.crossflash 'no w1700k' 'w1700k found' FAIL; die "$EXIT_COMPAT" "refusing W1700K cross-flash image"
	fi

	if [ -z "$DEVICE_COMPAT" ]; then
		[ -r "$SYSTEM_CFG" ] || { row device.compat "readable $SYSTEM_CFG" unreadable FAIL; die "$EXIT_COMPAT" "$SYSTEM_CFG is unreadable"; }
		if command -v uci >/dev/null 2>&1; then
			case "$SYSTEM_CFG" in */*) _cfgdir=${SYSTEM_CFG%/*} ;; *) _cfgdir=. ;; esac
			_cfgpkg=${SYSTEM_CFG##*/}
			DEVICE_COMPAT=$(uci -c "$_cfgdir" -q get "${_cfgpkg}.@system[0].compat_version" 2>/dev/null || true)
			[ -n "$DEVICE_COMPAT" ] || DEVICE_COMPAT='1.0'
		else
			row device.compat 'uci tool' missing FAIL
			die "$EXIT_COMPAT" "uci not found; cannot verify device compat_version"
		fi
	fi
	case "$DEVICE_COMPAT" in ''|*[!0-9.]*|.*|*.|*.*.*) die "$EXIT_COMPAT" "invalid device compat_version '$DEVICE_COMPAT'" ;; esac
	IMG_COMPAT=$(printf '%s' "$META_FLAT" | grep -o '"compat_version"[ 	]*:[ 	]*"[^"]*"' | head -n 1 | sed 's/^[^:]*:[ 	]*"//; s/"$//')
	case "$IMG_COMPAT" in ''|*[!0-9.]*|.*|*.|*.*.*) row image.compat '2.x' "${IMG_COMPAT:-missing}" FAIL; die "$EXIT_COMPAT" "missing/invalid image compat_version" ;; esac
	if [ "${DEVICE_COMPAT%%.*}" != '2' ] || [ "${IMG_COMPAT%%.*}" != '2' ]; then
		row image.compat 'dev=2.x img=2.x' "dev=$DEVICE_COMPAT img=$IMG_COMPAT" FAIL
		die "$EXIT_COMPAT" "compat_version mismatch (device=$DEVICE_COMPAT, image=$IMG_COMPAT); 2.x required"
	fi
	row image.compat '2.x' "dev=$DEVICE_COMPAT img=$IMG_COMPAT" PASS

	SDEV=$(extract_json_list "$META_FLAT" new_supported_devices)
	if [ -n "$SDEV" ] && printf '%s\n' "$SDEV" | grep -F -qx -- "$BOARD_EXPECTED"; then
		row image.device "$BOARD_EXPECTED" matched PASS
	else
		row image.device "$BOARD_EXPECTED" "${SDEV:-missing}" FAIL; die "$EXIT_COMPAT" "new_supported_devices missing $BOARD_EXPECTED"
	fi

	if command -v dumpimage >/dev/null 2>&1; then
		if DLIST=$(dumpimage -l "$IMAGE" 2>&1); then
			if printf '%s' "$DLIST" | tr 'A-Z' 'a-z' | grep -Fq 'w1700k'; then
				row image.fdt gemtek_xr1710g-ubi 'w1700k found' FAIL; die "$EXIT_COMPAT" "FIT FDT references W1700K"
			elif printf '%s' "$DLIST" | grep -Fq 'OpenWrt gemtek_xr1710g-ubi device tree blob'; then
				row image.fdt gemtek_xr1710g-ubi matched PASS
			else
				row image.fdt gemtek_xr1710g-ubi mismatch FAIL; die "$EXIT_COMPAT" "FIT FDT does not match gemtek_xr1710g-ubi"
			fi
		else
			DRC=$?
			row image.fdt 'dumpimage rc=0' "rc=$DRC" FAIL
			die "$EXIT_COMPAT" "dumpimage -l failed (rc=$DRC)"
		fi
	elif [ "$RUN" = 1 ]; then
		row image.fdt gemtek_xr1710g-ubi missing FAIL
		die "$EXIT_COMPAT" "dumpimage not found; refusing --run without FIT FDT verification"
	else
		row image.fdt gemtek_xr1710g-ubi 'not installed' SKIP
	fi

	SUP=$(command -v "$SYSUPGRADE" 2>/dev/null || true)
	if [ -n "$SUP" ]; then
		if "$SUP" -T "$IMAGE" >"$WORK/sysupgrade-T.log" 2>&1; then row sysupgrade.T 0 0 PASS
		else SRC=$?; row sysupgrade.T 0 "$SRC" FAIL; sed 's/^/  /' "$WORK/sysupgrade-T.log" >&2; die "$EXIT_IMAGE" "sysupgrade -T failed (rc=$SRC)"; fi
	elif [ "$RUN" = 1 ]; then
		row sysupgrade.T 0 missing FAIL; die "$EXIT_IMAGE" "sysupgrade binary not found"
	else
		row sysupgrade.T 0 'not installed' SKIP
	fi
fi

# Strictly read-only mtd0 (vendor) and mtd1 (chainloader) header check/backup.
BKDIR=''
if [ "$CHECK_ONLY" = 0 ]; then
	while [ "$BACKUP_ROOT" != "/" ]; do
		case "$BACKUP_ROOT" in
		*/) BACKUP_ROOT="${BACKUP_ROOT%/}" ;;
		*) break ;;
		esac
	done
	[ -L "$BACKUP_ROOT" ] && die "$EXIT_BACKUP" "backup root '$BACKUP_ROOT' must not be a symlink"
	mkdir -p -m 0700 "$BACKUP_ROOT" && [ ! -L "$BACKUP_ROOT" ] && [ -d "$BACKUP_ROOT" ] && chmod 0700 "$BACKUP_ROOT" ||
		die "$EXIT_BACKUP" "cannot prepare backup root $BACKUP_ROOT"
	BKDIR=$(mktemp -d "$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S).XXXXXX") ||
		die "$EXIT_BACKUP" "cannot create backup dir in $BACKUP_ROOT"
	chmod 0700 "$BKDIR" && cp "$PROC_MTD" "$BKDIR/mtd.txt" ||
		die "$EXIT_BACKUP" "cannot initialize backup in $BKDIR"
fi

BK_FAIL=''
while read -r pnum psize perase pname; do
	case "$pnum:$pname" in mtd0:vendor|mtd1:chainloader) ;; *) continue ;; esac
	DEV="$MTD_DEV_DIR/${pnum}ro"; [ -e "$DEV" ] || DEV="$MTD_DEV_DIR/$pnum"
	[ -r "$DEV" ] || { row "backup.${pname}" readable "missing $DEV" FAIL; BK_FAIL="$BK_FAIL $pname"; continue; }
	SIZE=$((0x$psize)); CAP=$((HEAD_KB * 1024)); [ "$CAP" -le "$SIZE" ] || CAP=$SIZE
	CNT=$(( (CAP + 4095) / 4096 )); WANT=$((CNT * 4096)); [ "$WANT" -le "$SIZE" ] || WANT=$SIZE
	if [ "$CHECK_ONLY" = 1 ]; then
		TMP="$WORK/head.tmp"
		rm -f "$TMP"
		if dd if="$DEV" of="$TMP" bs=4096 count="$CNT" 2>/dev/null; then
			GOT=$(wc -c < "$TMP" | tr -d ' ')
			if [ "$GOT" = "$WANT" ]; then
				SHA=$(sha256sum "$TMP" | awk '{print $1}')
				if [ -n "$SHA" ] && [ "$SHA" != "$EMPTY_SHA" ]; then
					row "ro-read.${pname}" "${WANT}B" "$SHA" PASS
				else
					row "ro-read.${pname}" "${WANT}B" 'sha256 failed' FAIL; BK_FAIL="$BK_FAIL $pname"
				fi
			else
				row "ro-read.${pname}" "${WANT}B" "short-read(${GOT}B)" FAIL; BK_FAIL="$BK_FAIL $pname"
			fi
		else
			row "ro-read.${pname}" "${WANT}B" 'dd failed' FAIL; BK_FAIL="$BK_FAIL $pname"
		fi
		rm -f "$TMP"
	else
		OUT="$BKDIR/${pname}.head"
		if dd if="$DEV" of="$OUT" bs=4096 count="$CNT" 2>/dev/null && [ "$(wc -c < "$OUT" | tr -d ' ')" = "$WANT" ]; then
			row "backup.${pname}" "${WANT}B" "${WANT}B" PASS
		else
			row "backup.${pname}" "${WANT}B" failed FAIL; BK_FAIL="$BK_FAIL $pname"
		fi
	fi
done < "$WORK/parts"
[ -z "$BK_FAIL" ] || die "$EXIT_BACKUP" "read-only header backup failed for:$BK_FAIL"

if [ "$CHECK_ONLY" = 0 ]; then
	( cd "$BKDIR" && sha256sum vendor.head chainloader.head mtd.txt > manifest.sha256 && sha256sum -c manifest.sha256 >/dev/null 2>&1 ) || {
		row backup.verify 'sha256sum -c' mismatch FAIL; die "$EXIT_BACKUP" "backup manifest verification failed"
	}
	row backup.verify 'sha256sum -c' ok PASS
	say "backup: $BKDIR"
	if [ "$RUN" = 1 ]; then
		case "$BACKUP_ROOT" in
		/tmp|/tmp/*)
			err "WARN: backup dir '$BKDIR' is on /tmp (tmpfs) and will not survive sysupgrade reboot; use -d <persistent-dir> or copy off-device first" ;;
		esac
	fi
fi

say "GATE PASS"
[ "$CHECK_ONLY" = 1 ] && exit 0
say "next: sysupgrade $IMAGE"
[ "$RUN" = 1 ] && exec sysupgrade "$IMAGE"
exit 0
