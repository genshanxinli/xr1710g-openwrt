#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# recovery-boot-dryrun.sh -- can the initramfs recovery image be booted on this
# XR1710G without a serial console, and what does that cost?
#
# Issue #12.  The recovery ITB has never run on hardware.  The two paths a
# bench-side test would normally use are both closed on this box:
#
#   * U-Boot console -> tftpboot.  Needs a serial console.  /dev/ttyUSB* is
#     absent on the analysis host and the CH340 is not enumerated, and the
#     YMODEM fallback was measured at 8.56 kB/s (28.1 min for 14.4 MB) and died
#     at 43% with "Retry 0: Timeout on sector ACK".
#   * kexec into the ITB.  No an7581 config has CONFIG_KEXEC and the device has
#     no kexec binary, so there is nothing to hand 14 MiB of kernel to.
#
# What is left is the slot itself: on this layout `sysupgrade` writes a FIT into
# the UBI volume named "fit", and U-Boot boots exactly that volume
# (boot_production = ubi read ${loadaddr} fit && bootm ${loadaddr}#${bootconf}).
# Writing the recovery ITB there turns "boot the recovery image" into "boot the
# box", which needs no console at all.  The cost is one-way: that volume is
# removed and recreated at the recovery image's size
# (nand_upgrade_prepare_ubi, package/base-files/files/lib/upgrade/nand.sh:183-235),
# so the production image must be restored from a copy taken beforehand.
#
# This script is not clever about that.  Default mode only reads: it checks the
# image, the FIT shape, the device's slot layout and boot variables, prints the
# plan it would run, and exits.  --execute is the human's decision and starts by
# writing a verified byte copy of the current "fit" volume plus its metadata to
# a directory that is not tmpfs.
#
# What it does not claim: that a rescue is guaranteed.  If the recovery image
# fails to boot, the flashed U-Boot runs `bootcmd=run boot_ubi || http_recovery`
# and falls back to its own lwIP web recovery at http://192.168.0.1/ ("XR1710G
# HTTP recovery: ..." strings of the mtd1 chainloader payload), which accepts
# /upload/firmware -- that is where the restore copy goes.  That fallback has
# never been exercised either.
#
# Usage:
#   scripts/recovery-boot-dryrun.sh                 # read-only plan
#   scripts/recovery-boot-dryrun.sh --execute -d DIR
#   scripts/recovery-boot-dryrun.sh --self-test     # parser checks, no device
#
# Options:
#   -i, --image PATH   recovery ITB (default: newest bin/targets/airoha/an7581/
#                      *-initramfs-recovery.itb)
#   -H, --host HOST    ssh target (default root@192.168.1.1)
#   -d, --dir DIR      restore-point directory (default
#                      /home/l1n/projects/.scratch/recovery/<timestamp>)
#       --execute      write the restore point, then flash (refuses on FAIL)
#       --self-test    exercise the parsers with fixtures, touch nothing
#   -h, --help         this text
#
# Exit status:
#   0  plan ready / execute finished      4  a check FAILed (nothing written)
#   2  usage                              5  restore point did not verify
#   6  image push or on-device digest mismatch

set -u

EXIT_USAGE=2
EXIT_CHECK=4
EXIT_RESTORE=5
EXIT_IMAGE=6

TOP=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=''
HOST=root@192.168.1.1
DIR=''
EXECUTE=0
SELFTEST=0
BOARD_COMPAT=gemtek,xr1710g-ubi
BOARD_DESC=gemtek_xr1710g-ubi
VOL=fit
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

CHECK_FAILED=0

say() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

# row NAME EXPECTED ACTUAL PASS|FAIL|SKIP -- one assertion per line, the same
# shape as scripts/flash-gate.sh so the two logs can be diffed.
row() {
	printf '%-30s expected=%-24s actual=%-28s %s\n' "$1" "$2" "$3" "$4"
	[ "$4" = FAIL ] && CHECK_FAILED=$((CHECK_FAILED + 1))
	return 0
}

usage() {
	sed -n '/^# Usage:/,/^# Exit status:/p' "$0" | sed 's/^# \{0,1\}//'
}

# ------------------------------------------------------------- pure functions

# fit_field FILE LABEL -- the value after LABEL in `dumpimage -l` output.
fit_field() {
	awk -v want="$2" 'index($0, want) { sub(/^[^:]*: */, ""); print; exit }' "$1"
}

# sums_digest SUMSFILE BASENAME -- digest of that image from the sha256sums.
sums_digest() {
	awk -v want="$2" '$2 == want || $2 == "*" want { print $1; exit }' "$1"
}

# ubi_volume_bytes UBINFO VOLNAME -- "Size: 132 LEBs (16760832 bytes" -> 16760832
ubi_volume_bytes() {
	awk -v want="$2" '
		/^Size:/ && /LEBs \(/ {
			sz = $0; sub(/.*\(/, "", sz); sub(/ bytes.*/, "", sz)
		}
		$1 == "Name:" && $2 == want { print sz; exit }' "$1"
}

# ubi_volume_id UBINFO VOLNAME -- the volume number inside /dev/ubi0_<id>.
# ubinfo -a prints one block per volume, "Volume ID:   2 (on ubi0)" closed by
# "Name:        fit"; the board layout is ubootenv(0), ubootenv2(1), fit(2),
# factory(3), so "the first volume" is the 128 KiB U-Boot environment, never
# the FIT.  Prints nothing when the name is absent; callers must not build a
# /dev/ubi0_ path from an empty answer.
ubi_volume_id() {
	awk -v want="$2" '
		/^Volume ID:/ { id = $3 }
		$1 == "Name:" && $2 == want { print id; exit }' "$1"
}

# need_lebs BYTES LEB_BYTES -- logical eraseblocks a FIT of that size takes.
need_lebs() {
	[ "$2" -gt 0 ] || { echo 0; return; }
	echo $(( ($1 + $2 - 1) / $2 ))
}

# phandle_name ID PAIRS -- "E" over a "E fit / W factory" list -> fit.
phandle_name() {
	printf '%s\n' "$2" | awk -v want="$1" '$1 == want { print $2; exit }'
}

# ---------------------------------------------------------------- arguments

while [ $# -gt 0 ]; do
	case "$1" in
	-h|--help) usage; exit 0 ;;
	-i|--image) [ $# -ge 2 ] || { err "--image needs a value"; exit $EXIT_USAGE; }; IMAGE=$2; shift 2 ;;
	-H|--host) [ $# -ge 2 ] || { err "--host needs a value"; exit $EXIT_USAGE; }; HOST=$2; shift 2 ;;
	-d|--dir) [ $# -ge 2 ] || { err "--dir needs a value"; exit $EXIT_USAGE; }; DIR=$2; shift 2 ;;
	--execute) EXECUTE=1; shift ;;
	--self-test) SELFTEST=1; shift ;;
	*) err "unknown option: $1"; usage; exit $EXIT_USAGE ;;
	esac
done

# ---------------------------------------------------------------- self-test

if [ "$SELFTEST" = 1 ]; then
	cat > "$WORK/ubinfo" <<'EOF'
Volume ID:   0 (on ubi0)
Alignment:   1
Size:        32 LEBs (4063232 bytes, 3.9 MiB)
State:       OK
Name:        ubootenv
Volume ID:   1 (on ubi0)
Alignment:   1
Size:        32 LEBs (4063232 bytes, 3.9 MiB)
State:       OK
Name:        ubootenv2
Volume ID:   2 (on ubi0)
Alignment:   1
Size:        132 LEBs (16760832 bytes, 15.9 MiB)
State:       OK
Name:        fit
Volume ID:   3 (on ubi0)
Alignment:   1
Size:        8 LEBs (1015808 bytes, 992.0 KiB)
State:       OK
Name:        factory
Volume ID:   4 (on ubi0)
Size:        3267 LEBs (414830592 bytes, 395.6 MiB)
Name:        rootfs_data
EOF
	[ "$(ubi_volume_bytes "$WORK/ubinfo" fit)" = 16760832 ] || { err "self-test: ubi_volume_bytes"; exit 1; }
	[ "$(ubi_volume_bytes "$WORK/ubinfo" rootfs_data)" = 414830592 ] || { err "self-test: ubi_volume_bytes second volume"; exit 1; }
	[ "$(ubi_volume_bytes "$WORK/ubinfo" provisioning)" = "" ] || { err "self-test: ubi_volume_bytes false match"; exit 1; }
	# The fixture mirrors target/linux/airoha/dts/an7581-xr1710g-ubi.dts
	# (ubootenv 0, ubootenv2 1, fit 2, factory 3).  A parser that hands out
	# volume 0 for "fit" used to pass here and then hash the U-Boot env.
	[ "$(ubi_volume_id "$WORK/ubinfo" fit)" = 2 ] || { err "self-test: ubi_volume_id fit"; exit 1; }
	[ "$(ubi_volume_id "$WORK/ubinfo" ubootenv)" = 0 ] || { err "self-test: ubi_volume_id first volume"; exit 1; }
	[ "$(ubi_volume_id "$WORK/ubinfo" factory)" = 3 ] || { err "self-test: ubi_volume_id factory"; exit 1; }
	[ "$(ubi_volume_id "$WORK/ubinfo" rootfs_data)" = 4 ] || { err "self-test: ubi_volume_id last volume"; exit 1; }
	[ "$(ubi_volume_id "$WORK/ubinfo" provisioning)" = "" ] || { err "self-test: ubi_volume_id false match"; exit 1; }
	[ "$(need_lebs 14417920 126976)" = 114 ] || { err "self-test: need_lebs 14417920"; exit 1; }
	[ "$(need_lebs 0 126976)" = 0 ] || { err "self-test: need_lebs 0"; exit 1; }
	cat > "$WORK/dumpimage" <<'EOF'
 Image 0 (kernel-1)
  Description:  ARM64 OpenWrt Linux-7.4-rc3
  Compression:  lzma compressed
  Data Size:    14273370 Bytes = 13938.84 KiB = 13.61 MiB
  Load Address: 0x80200000
 Image 1 (fdt-1)
  Description:  ARM64 OpenWrt gemtek_xr1710g-ubi device tree blob
 Default Configuration: 'config-1'
EOF
	[ "$(fit_field "$WORK/dumpimage" 'Compression:')" = "lzma compressed" ] || { err "self-test: fit_field compression"; exit 1; }
	[ "$(fit_field "$WORK/dumpimage" 'Load Address:')" = 0x80200000 ] || { err "self-test: fit_field loadaddr"; exit 1; }
	[ "$(fit_field "$WORK/dumpimage" 'Default Configuration:')" = "'config-1'" ] || { err "self-test: fit_field config"; exit 1; }
	[ "$(phandle_name E "E fit
W factory")" = fit ] || { err "self-test: phandle_name"; exit 1; }
	[ "$(phandle_name 9 "E fit")" = "" ] || { err "self-test: phandle_name miss"; exit 1; }
	cat > "$WORK/sums" <<'EOF'
cca43cfe0d0dfa5c2dba49665995aabb94e454d915945974b708b95aa6294e49 *openwrt-airoha-an7581-gemtek_xr1710g-ubi-initramfs-recovery.itb
d87f88b716104ba8d97730bfe32430abbd61f61fa698f607d8d77647543f519d *openwrt-airoha-an7581-gemtek_xr1710g-ubi-squashfs-sysupgrade.itb
EOF
	[ "$(sums_digest "$WORK/sums" openwrt-airoha-an7581-gemtek_xr1710g-ubi-initramfs-recovery.itb)" = \
	  cca43cfe0d0dfa5c2dba49665995aabb94e454d915945974b708b95aa6294e49 ] || { err "self-test: sums_digest"; exit 1; }
	[ "$(sums_digest "$WORK/sums" nope.itb)" = "" ] || { err "self-test: sums_digest miss"; exit 1; }
	say "self-test: 17 parser checks OK"
	exit 0
fi

# ------------------------------------------------------------- 1. the image

if [ -z "$IMAGE" ]; then
	IMAGE=$(ls -t "$TOP"/bin/targets/airoha/an7581/*-initramfs-recovery.itb 2>/dev/null | head -1)
fi
[ -n "$IMAGE" ] && [ -f "$IMAGE" ] || { err "no recovery ITB: pass --image PATH"; exit $EXIT_CHECK; }
IMG_DIR=$(cd "$(dirname "$IMAGE")" && pwd)
IMG_NAME=$(basename "$IMAGE")
IMG_BYTES=$(wc -c < "$IMAGE" | awk '{ print $1 }')
NAME=$(echo "$IMG_NAME" | sed 's/.*gemtek_xr1710g-ubi-//')
say "image: $IMG_DIR/$IMG_NAME ($IMG_BYTES bytes)"

WANT=$(sums_digest "$IMG_DIR/sha256sums" "$IMG_NAME")
GOT=$(sha256sum "$IMAGE" | awk '{ print $1 }')
row image.sha256 "${WANT:-none in sha256sums}" "${GOT:-unreadable}" \
	$([ -n "$WANT" ] && [ "$WANT" = "$GOT" ] && echo PASS || echo FAIL)

DUMPIMAGE=$(command -v dumpimage || true)
if [ -n "$DUMPIMAGE" ]; then
	$DUMPIMAGE -T flat_dt -l "$IMAGE" > "$WORK/fit.txt" 2>&1 || true
	COMP=$(fit_field "$WORK/fit.txt" 'Compression:')
	LOAD=$(fit_field "$WORK/fit.txt" 'Load Address:')
	FDTSD=$(fit_field "$WORK/fit.txt" 'Description:  ARM64 OpenWrt gemtek')
	DEFCFG=$(fit_field "$WORK/fit.txt" 'Default Configuration:')
	row fit.kernel.comp "lzma compressed" "$COMP" $([ "$COMP" = "lzma compressed" ] && echo PASS || echo FAIL)
	row fit.kernel.load 0x80200000 "$LOAD" $([ "$LOAD" = 0x80200000 ] && echo PASS || echo FAIL)
	row fit.fdt.desc "$BOARD_DESC" "${FDTSD##*OpenWrt }" \
		$([ "$FDTSD" = "ARM64 OpenWrt $BOARD_DESC device tree blob" ] && echo PASS || echo FAIL)
	DEFCFG_NAME=$(printf '%s' "$DEFCFG" | tr -d "'")
	row fit.config config-1 "$DEFCFG_NAME" $([ "$DEFCFG_NAME" = config-1 ] && echo PASS || echo FAIL)
else
	row fit.structure "dumpimage on this host" "not installed" SKIP
fi

# `append-metadata` ends a sysupgrade FIT in a fwtool trailer; KERNEL_INITRAMFS
# ends this image in pad-to 0x00, so fwtool_check_image says "Image metadata
# not present".  The trailer is where compat_version lives, so what that costs
# depends on the board:
#
#   * REQUIRE_IMAGE_METADATA=1 (target/linux/airoha/an7581/base-files/lib/
#     upgrade/platform.sh:3, the board this script flashes) returns 74
#     (fwtool.sh:39-42), validate_firmware_image:55-60 maps 74 to
#     notify_firmware_broken -> forceable=false (:19-22, :89), and
#     sysupgrade:407-414 then prints "Image check failed." and exits 1
#     before any write.  -F does not override 74, so "no trailer" is not
#     "needs -F": it is "this image will not flash".
#   * a board that does not require metadata keeps the upstream forceable
#     path (fwtool.sh:43-46): the image is checkable, just not acceptable,
#     and `-F` is what lets it through.
#
# fwtool writes fwimage_trailer.magic with cpu_to_be32 (fwtool.c:192,
# fwimage.h:18), so a metadata-bearing image ends in a 16-byte trailer whose
# first four bytes are the big-endian bytes 46 57 78 30 ("FWx0").  Compare
# that position exactly: the literal "FWx0" may also occur inside the FIT
# payload and is not a trailer there.
#
# hexdump, not od: the XR1710G image ships BusyBox with CONFIG_HEXDUMP=y and no
# od applet at all (busybox.links has /usr/bin/hexdump, no /bin/od), and the
# live run printed "recovery-boot-dryrun.sh: line 279: od: not found" (the probe
# was line 279 before this edit), leaving
# TRAILER_MAGIC empty so every image read as "no trailer".  `-v -e
# '1/1 "%02x"'` is the same output on GNU/BSD hexdump and BusyBox 1.38
# (util-linux/hexdump.c usage: "[-bcdoxCv] [-e FMT] [-f FMT_FILE] [-n LEN]").
REQUIRE_METADATA=$(awk -F= '$1 == "REQUIRE_IMAGE_METADATA" { print $2; exit }' \
	"$TOP/target/linux/airoha/an7581/base-files/lib/upgrade/platform.sh" 2>/dev/null)
[ -n "${REQUIRE_METADATA:-}" ] || REQUIRE_METADATA=0
TRAILER_MAGIC=$(tail -c 16 "$IMAGE" 2>/dev/null | head -c 4 | hexdump -v -e '1/1 "%02x"')
# -F on the plan's sysupgrade lines, set whenever the image carries no
# trailer: harmless on a valid image (FORCE only widens the image-check gate,
# sysupgrade:409) and the only way past "checkable, not acceptable".
FORCE_FLAG=''
METADATA_REFUSED=0
if [ "$TRAILER_MAGIC" = 46577830 ]; then
	row image.metadata "append-metadata trailer" "trailer present" PASS
elif [ "$REQUIRE_METADATA" = 1 ]; then
	row image.metadata "append-metadata trailer" "absent (rc 74, not forceable)" FAIL
	METADATA_REFUSED=1
	FORCE_FLAG=-F
	err "this image has no fwtool trailer and REQUIRE_IMAGE_METADATA=1: the fwtool.sh in"
	err "this tree rejects it with rc 74 before any write, and -F cannot override 74"
	err "(forceable=0).  -F only helps if the box's own validator disagrees, which is"
	err "what --execute asks with sysupgrade -T and -T -F.  Otherwise add 'append-metadata'."
else
	row image.metadata "no trailer (board accepts -F)" "tail is 0x00" PASS
	FORCE_FLAG=-F
fi

# ------------------------------------------------------------- 2. the device

PROBE=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" '
cat /tmp/sysinfo/board_name
echo "--- cmdline"; cat /proc/cmdline
echo "--- mtd"; cat /proc/mtd
echo "--- ubiinfo"; ubinfo /dev/ubi0 -a
echo "--- env"; fw_printenv bootargs bootcmd loadaddr 2>&1
echo "--- fitblk"
strings -n 1 /sys/firmware/devicetree/base/chosen/rootdisk 2>/dev/null | head -1
for d in /sys/class/mtd/mtd*/of_node/volumes/*/; do
	printf "%s %s\n" "$(strings -n 1 "$d/phandle" 2>/dev/null | head -1)" "$(cat "$d/volname" 2>/dev/null)"
done
echo "--- slot"
fit_id=
for n in /sys/class/ubi/ubi0_*/name; do
	vol=$(cat "$n" 2>/dev/null) || continue
	[ "$vol" = fit ] || continue
	fit_id=$(basename "$(dirname "$n")"); fit_id=${fit_id#ubi0_}
done
echo "fit_id ${fit_id:-missing}"
if [ -n "$fit_id" ]; then
	sha256sum "/dev/ubi0_$fit_id"
	dd if="/dev/ubi0_$fit_id" bs=1M 2>/dev/null | wc -c
fi
echo "--- kexec"
command -v kexec || echo none
' 2> "$WORK/ssh.err") || { err "cannot ssh $HOST"; head -3 "$WORK/ssh.err" >&2; exit $EXIT_CHECK; }
printf '%s\n' "$PROBE" > "$WORK/probe.txt"

BOARD_NOW=$(sed -n '1p' "$WORK/probe.txt")
IS_UBI=$(awk '$4 == "\"ubi\"" { n++ } END { print n + 0 }' "$WORK/probe.txt")
row device.board "$BOARD_COMPAT" "${BOARD_NOW:-none}" $([ "$BOARD_NOW" = "$BOARD_COMPAT" ] && echo PASS || echo FAIL)
row device.ubi-partition "one mtd device named ubi" "$IS_UBI" $([ "$IS_UBI" = 1 ] && echo PASS || echo FAIL)

sed -n '/^--- ubiinfo$/,/^--- env$/p' "$WORK/probe.txt" | sed '1d;$d' > "$WORK/ubinfo.txt"
VOL_BYTES=$(ubi_volume_bytes "$WORK/ubinfo.txt" "$VOL")
LEB_BYTES=$(awk '/Logical eraseblock size:/ { print $4; exit }' "$WORK/ubinfo.txt")
AVAIL_LEB=$(awk '/Amount of available logical eraseblocks:/ { print $6; exit }' "$WORK/ubinfo.txt")
VOL_LEBS=$(awk -v b="$VOL_BYTES" -v l="$LEB_BYTES" 'BEGIN { print (l > 0 ? int(b / l) : 0) }')
NEED_LEB=$(need_lebs "$IMG_BYTES" "${LEB_BYTES:-0}")
row slot.volume "$VOL exists" "${VOL_BYTES:-missing} bytes" $([ -n "$VOL_BYTES" ] && echo PASS || echo FAIL)
row slot.image.fits "$IMG_BYTES bytes" "${VOL_BYTES:-0} bytes" \
	$([ -n "$VOL_BYTES" ] && [ "$IMG_BYTES" -le "$VOL_BYTES" ] && echo PASS || echo FAIL)
row slot.lebs "$NEED_LEB LEBs of $VOL_LEBS" "$NEED_LEB" $([ "$NEED_LEB" -le "${VOL_LEBS:-0}" ] && echo PASS || echo FAIL)
row slot.avail-lebs "0 (rootfs_data holds the rest)" "${AVAIL_LEB:-?}" SKIP

ROOTDISK=$(sed -n '/^--- fitblk$/{n;p;q;}' "$WORK/probe.txt")
PAIRS=$(sed -n '/^--- fitblk$/,/^--- slot$/p' "$WORK/probe.txt" | sed '1d;$d' | sed '1d' | grep .)
RESOLVED=$(phandle_name "$ROOTDISK" "$PAIRS")
row fitblk.volume "$VOL" "${RESOLVED:-unresolved}" $([ "$RESOLVED" = "$VOL" ] && echo PASS || echo FAIL)
row fitblk.method ubi "$([ "$RESOLVED" = "$VOL" ] && echo ubi)" $([ "$RESOLVED" = "$VOL" ] && echo PASS || echo FAIL)

sed -n '/^--- env$/,/^--- fitblk$/p' "$WORK/probe.txt" | sed '1d;$d' > "$WORK/env.txt"
row bootenv.crc "a valid env to read from Linux" \
	"$(grep -q 'Bad CRC' "$WORK/env.txt" && echo 'Bad CRC, using default environment' || echo 'CRC ok; bootargs readable')" SKIP
row kexec.binary "absent (kexec path closed)" "$(sed -n '/^--- kexec$/,$p' "$WORK/probe.txt" | sed '1d')" SKIP

# loadaddr is where boot_production puts the fit volume and where bootm
# decompresses the kernel out of it.  The recovery kernel-1 is 42,663,936 B
# (arm64 header image_size 0x28b0000) and loads at 0x80200000, so it expands to
# 0x82ab0000; a FIT copy below that ends in "new format image overwritten -
# must RESET the board to recover" (boot/bootm.c).  The production kernel ends
# at 0x81166808, which is why the old 0x81800000 env booted production happily.
# Read this back from the board, not from the tree: a box flashed before this
# fix still carries the old env, and that is the box this plan would flash.
BOOT_LOADADDR=$(awk '/^loadaddr=/ { print substr($0, 10); exit }' "$WORK/env.txt")
RECOVERY_KERNEL_END=0x82ab0000
LOADADDR_OK=0
[ -n "$BOOT_LOADADDR" ] && [ "$((BOOT_LOADADDR + 0))" -ge "$((RECOVERY_KERNEL_END + 0))" ] && LOADADDR_OK=1
row bootenv.loadaddr ">= 0x82ab0000 (recovery kernel end)" "${BOOT_LOADADDR:-unreadable}" \
	$([ "$LOADADDR_OK" = 1 ] && echo PASS || echo FAIL)

# The slot to hash is the volume named fit, and its id is 2 on this layout
# (ubootenv 0, ubootenv2 1, fit 2, factory 3), never 0.  The probe derives the
# id from /sys/class/ubi/ubi0_*/name; an empty answer means the read-only probe
# could not find the volume, so no /dev path is built from it.
FIT_ID=$(sed -n '/^--- slot$/{n;s/^fit_id //;p;q;}' "$WORK/probe.txt")
[ "$FIT_ID" = missing ] && FIT_ID=
row slot.fit.id "a UBI volume named fit" "ubi0_${FIT_ID:-absent}" $([ -n "$FIT_ID" ] && echo PASS || echo FAIL)
SLOT_SHA=$(sed -n '/^--- slot$/{n;n;p;q;}' "$WORK/probe.txt" | awk '{ print $1 }')
SLOT_LEN=$(sed -n '/^--- slot$/{n;n;n;p;q;}' "$WORK/probe.txt" | awk '{ print $1 }')
[ "$SLOT_SHA" = "" ] && SLOT_SHA=
row rollback.source "current fit volume ($VOL), hashed" "${SLOT_SHA:-unreadable} (${SLOT_LEN:-?} bytes)" \
	$([ -n "$SLOT_SHA" ] && [ -n "$FIT_ID" ] && echo PASS || echo FAIL)

# --------------------------------------------------------------- 3. the plan

DIR=${DIR:-/home/l1n/projects/.scratch/recovery/recovery-boot-$(date +%Y%m%d-%H%M%S)}
say ''
if [ "$CHECK_FAILED" = 0 ]; then
	say 'verdict: all preconditions hold, the plan below is runnable'
elif [ "$EXECUTE" = 1 ] && [ "$METADATA_REFUSED" = 1 ] && [ "$CHECK_FAILED" -le 1 ]; then
	# The only FAIL above is a prediction about the firmware this tree ships.
	# --execute is about to ask the box itself (sysupgrade -T, then -T -F on
	# the pushed copy), so the prediction loses to the device: clear it and
	# let that probe stop the run.  A second FAILed row (slot, env, digest)
	# still aborts here.
	err 'verdict: this tree refuses the image (no fwtool trailer, rc 74); --execute will ask the device'
	CHECK_FAILED=0
else
	err 'verdict: the plan cannot run as-is (a row above FAILed)'; exit $EXIT_CHECK
fi
say ''
say 'plan (each step is the exact command --execute would run):'
say ' 0. restore point on this host, not tmpfs:'
say "      mkdir -p $DIR"
say "      ssh $HOST 'dd if=/dev/ubi0_${FIT_ID} bs=1M' > $DIR/fit-slot.bin   # sha256 $SLOT_SHA, $SLOT_LEN bytes"
say "      ssh $HOST 'cat /proc/cmdline; cat /proc/mtd; ubinfo /dev/ubi0 -a; fw_printenv bootargs bootcmd' > $DIR/device.txt"
say ' 1. push the image (device /tmp is tmpfs; 14 MiB fits; the box has no sftp-server):'
say "      ssh $HOST 'rm -f /tmp/$IMG_NAME /tmp/$NAME'   # a killed push leaves a half file under the original name"
say "      tar -C $IMG_DIR -cf - $IMG_NAME | ssh $HOST 'tar -C /tmp -xf - && mv -f /tmp/$IMG_NAME /tmp/$NAME'"
say " 2. prove the pushed bytes: sha256sum /tmp/$NAME == $WANT"
say " 3. sysupgrade's own verdict, on the device, writing nothing:"
if [ "$METADATA_REFUSED" = 1 ]; then
	say "      ssh $HOST 'sysupgrade -T /tmp/$NAME'   # expect 'Image check failed.'; rc 74 if the box runs this tree, and -F does not help"
elif [ "$FORCE_FLAG" = -F ]; then
	say "      ssh $HOST 'sysupgrade -T /tmp/$NAME'   # expect 'Image check failed.'; -F is honoured (forceable=1)"
else
	say "      ssh $HOST 'sysupgrade -T /tmp/$NAME'   # expect no 'Image check failed.'; nothing to force"
fi
say ' 4. write it into the boot slot and reboot (the human decides):'
say "      ssh $HOST 'sysupgrade${FORCE_FLAG:+ $FORCE_FLAG} -n /tmp/$NAME'"
say ' 5. after the reboot the box is the recovery image, running from RAM.'
say ''
say 'risk and rollback (read before step 4):'
say '  * nand_upgrade_prepare_ubi removes the fit volume (rootfs_data too) and recreates'
say '    it at the recovery image size (nand.sh:183-235); -n keeps no config, and the'
say '    recovery FIT boots because boot_production reads exactly that volume:'
say '    ubi read ${loadaddr} fit && bootm ${loadaddr}#${bootconf}.'
say "  * if that boot fails, the flashed U-Boot (not this tree's) runs"
say '    bootcmd=run boot_ubi || http_recovery and its lwIP server takes over at'
say '    http://192.168.0.1/ (PC 192.168.0.10/24 or DHCP 192.168.0.2-50); upload the'
say '    restore copy through /upload/firmware.  This is the only automatic fallback'
say '    and it has never been exercised either.'
say '  * if neither the boot nor the web recovery comes up, recovery is serial only:'
say '    the chainloader prompt (ECNT>, U-Boot 2014.04-rc1 AXON 1.6) and loady at'
say '    8.56 kB/s = 28.1 min for 14.4 MB, measured, failed at 43% with'
say '    "Retry 0: Timeout on sector ACK".  Do not plan on it under a console window.'
say '  * restoring inside the recovery shell needs the volume recreated first:'
say "    ubirmvol /dev/ubi0 -N rootfs_data; ubirmvol /dev/ubi0 -N fit; ubimkvol /dev/ubi0 -N fit -s $VOL_BYTES;"
say "    ubimkvol /dev/ubi0 -N rootfs_data -m; ubiupdatevol /dev/ubi0_${FIT_ID} < fit-slot.bin"
say '  * this proves the image boots on the bootloader this box already has; the path'
say '    issue #12 describes (tftpboot from the third-party console) stays untested,'
say '    and so does the case where flash itself is the problem.'

[ "$EXECUTE" = 1 ] || { say ''; say 'read-only run: nothing was written anywhere'; exit 0; }

# ----------------------------------------------------------------- 4. execute

say ''
say "execute: writing the restore point to $DIR first"
mkdir -p "$DIR" || exit $EXIT_RESTORE
( cd "$DIR" && ssh "$HOST" "dd if=/dev/ubi0_${FIT_ID} bs=1M" > fit-slot.bin ) || exit $EXIT_RESTORE
HAVE=$(sha256sum "$DIR/fit-slot.bin" | awk '{ print $1 }')
GOT_BYTES=$(wc -c < "$DIR/fit-slot.bin" | awk '{ print $1 }')
ssh "$HOST" 'cat /proc/cmdline; cat /proc/mtd; ubinfo /dev/ubi0 -a; fw_printenv bootargs bootcmd' > "$DIR/device.txt" 2>&1 || true
if [ "$HAVE" = "$SLOT_SHA" ] && [ "$GOT_BYTES" = "$SLOT_LEN" ]; then
	row restore.point "$SLOT_SHA ($SLOT_LEN bytes)" "$HAVE ($GOT_BYTES bytes)" PASS
else
	row restore.point "$SLOT_SHA ($SLOT_LEN bytes)" "$HAVE ($GOT_BYTES bytes)" FAIL
	err "restore point does not verify -- the slot is untouched; metadata kept in $DIR"
	exit $EXIT_RESTORE
fi
say "restore point: $DIR/fit-slot.bin + device.txt"

# The device runs dropbear and has no /usr/libexec/sftp-server, so OpenSSH's
# default scp mode dies at "subsystem request failed"; `scp -O` falls back to
# the legacy protocol, which needs an `scp` binary on the device that busybox
# does not ship either.  busybox tar does exist, so the image goes through ssh:
# nothing has to be installed on either side.  The name sysupgrade will read is
# only created by the `mv` after the remote tar exits 0, so a broken session
# cannot leave half an image there; the digest below decides, and a mismatch
# removes both names.
#
# The pre-mv name is a different story: a session that dies mid-tar leaves a
# partial /tmp/<image> behind (measured on the board: 2999488, 999488 and
# 2780600 bytes), and `mv` never gets to touch it.  Device /tmp is tmpfs, so a
# retry over that residue eats space next to #89's /tmp no-client/result.json.
# Every attempt therefore clears both names first and refuses to continue if it
# cannot: a pre-clean that silently fails would let the next `mv` overwrite the
# residue and hide the problem.
push_image() {
	ssh "$HOST" "rm -f /tmp/$IMG_NAME /tmp/$NAME" || {
		echo "cannot clear a stale /tmp/$IMG_NAME or /tmp/$NAME on $HOST" >&2
		return $EXIT_IMAGE
	}
	tar -C "$IMG_DIR" -cf - "$IMG_NAME" |
		ssh "$HOST" "tar -C /tmp -xf - && mv -f /tmp/$IMG_NAME /tmp/$NAME"
}

push_image || {
	ssh "$HOST" "rm -f /tmp/$IMG_NAME /tmp/$NAME" 2>/dev/null || true
	row push.image "tar|ssh ok" "transfer failed" FAIL
	exit $EXIT_IMAGE
}
GOT_REMOTE=$(ssh "$HOST" "sha256sum /tmp/$NAME" 2>/dev/null | awk '{ print $1 }')
row pushed.sha256 "$WANT" "${GOT_REMOTE:-missing}" $([ "$GOT_REMOTE" = "$WANT" ] && echo PASS || echo FAIL)
if [ "$CHECK_FAILED" != 0 ]; then
	ssh "$HOST" "rm -f /tmp/$NAME" 2>/dev/null || true
	exit $EXIT_IMAGE
fi

say ''
say 'image check: sysupgrade -T on the pushed copy (-T writes nothing), and -T -F when -T rejects it'
ssh "$HOST" "sysupgrade -T /tmp/$NAME" > "$WORK/sysupgrade-T.log" 2>&1
TEST_RC=$?
FORCED_RC=1
if [ "$TEST_RC" != 0 ] && [ "$FORCE_FLAG" = -F ]; then
	ssh "$HOST" "sysupgrade -T -F /tmp/$NAME" > "$WORK/sysupgrade-TF.log" 2>&1
	FORCED_RC=$?
fi
if [ "$TEST_RC" = 0 ]; then
	row sysupgrade.T 0 "$TEST_RC" PASS
elif [ "$FORCE_FLAG" = -F ] && [ "$FORCED_RC" = 0 ]; then
	row sysupgrade.T 0 "$TEST_RC (forceable: -F 0)" PASS
else
	row sysupgrade.T 0 "$TEST_RC" FAIL
	ssh "$HOST" "rm -f /tmp/$NAME" 2>/dev/null || true
	sed 's/^/    /' "$WORK/sysupgrade-T.log" >&2
	[ -f "$WORK/sysupgrade-TF.log" ] && sed 's/^/    /' "$WORK/sysupgrade-TF.log" >&2
	err 'sysupgrade rejected the pushed image and -F cannot override it; the slot is untouched'
	exit $EXIT_IMAGE
fi

say ''
say "flashing: sysupgrade${FORCE_FLAG:+ $FORCE_FLAG} -n (the box reboots into the recovery image)"
ssh "$HOST" "sysupgrade${FORCE_FLAG:+ $FORCE_FLAG} -n /tmp/$NAME" || row sysupgrade "reboot issued" "command failed" FAIL
say "if the box does not come back at 192.168.1.1: try http://192.168.0.1/ (web recovery,"
say "PC 192.168.0.10/24) and upload $DIR/fit-slot.bin through /upload/firmware."
exit 0
