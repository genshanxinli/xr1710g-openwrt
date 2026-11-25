#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# f2-wifi-npu.sh - the D5/F2 Wi-Fi-to-NPU experiment card.
#
# What is measured
# ----------------
# The host pings the AP address through the board, with the board's Wi-Fi
# STA interface bridged into the same bridge as lan4:
#
#   host --(host uplink)--> lan4 -- br-lan -- <sta> ==air==> AP
#   host <--(host uplink)-- lan4 -- br-lan -- <sta> <==air==  AP
#
# The echo replies are the Wi-Fi STA ingress direction.  The F2 question is
# whether the NPU/PPE hardware forwards that ingress to the lan4 side, or
# whether it goes to the host (CPU) path instead.  The counters live in the
# NPU counter block (npu_rv32.h, TCSUPPORT_WLAN_INODE):
#
#   idx12 TO_HOSTAPD_COUNT   NPU -> host (CPU/hostapd path)
#   idx21 TO_QDMA_COUNT      NPU -> QDMA (the hardware egress to ethernet)
#   idx96 PPE_RX_SEND_COUNT  NPU -> PPE (the hardware forwarding path)
#
# Criteria (D5/F2):
#   P2  d(idx96) > 0   main criterion
#   P3  d(idx21) > 0   supporting: the NPU sent it on to the QDMA
#   P4  a BND ppe/entries row whose ib2 PSE_PORT is 1 (GDM1, the lan4/DSA
#       conduit) is side evidence
#   P1  d(idx12) > 0   is only the host path; idx12 moving alone is *not*
#       a positive F2 result
#
# Counter windows (fixed, never guessed)
# --------------------------------------
# The counters are read with the regio debugfs module:
#
#   band0 (2.4 GHz) base 0x1e8776e0, 112 words
#   band1 (5 GHz)   base 0x1e877ae0, 112 words
#   band2 (6 GHz)   base 0x1e86f640, a 28-word util block with no idx12,
#                   idx21 or idx96; the card refuses a 6 GHz STA instead of
#                   reading a window that cannot answer the question.
#
# The active band is taken from the STA's current frequency; both band0 and
# band1 are dumped so the cross-check is in the raw evidence, and the
# verdict uses the active band.
#
# Safety
# ------
# * The A53 must never read 0x1e900000-0x1ebfffff: a direct read hangs the
#   whole board.  The only MMIO spans this card can construct are the two
#   fixed 112-word windows above, both inside the documented regio read
#   window 0x1e860000-0x1e88ffff.  guard_window() additionally refuses a
#   span outside that window, a span that intersects the A53 no-read range,
#   and a regio read_ranges that itself exposes the no-read range.
# * The card never writes a register, never loads a module, never calls
#   iw/uci/ip in write mode and never changes a device configuration.  It
#   reads debugfs/sysfs, runs iw link/station dump, and runs ping on the
#   host.
# * A refusal exits non-zero and writes no data.  It does not try another
#   address or another window.
#
# Topology prerequisites (checked, not changed)
# ---------------------------------------------
# * <sta> exists, is up, is connected to an AP and is a bridge port of the
#   same bridge as lan4.
# * The host has an address in the target's subnet on the device's LAN
#   interface (the D5 card used 192.168.234.45/24 on the lan4-side NIC),
#   and its route to 192.168.234.1 goes through that interface rather than
#   the Meta TUN.  The card asserts this and never adds an address or a
#   route:  ip addr add 192.168.234.45/24 dev <lan4-side NIC>  is a
#   separate, documented host step.
# * The route to the target must use the same interface as the device's
#   management address, must not be a Meta/TUN/TAP/WireGuard device, and
#   the target must not be an address owned by the board (local
#   termination).
# * The board has iw, ip and the regio module with the documented read
#   window.  The ssh user must be root (or otherwise allowed to write the
#   regio command node); the host ping needs root/CAP_NET_RAW for -i below
#   0.2 s.
# * The documented D5 topology keeps the wired WAN (lan3) down so the
#   traffic has to use the air path.  The card does not change lan3; the
#   bridge members are recorded in result.json so a surprising path is
#   visible after the fact.
#
# Usage
# -----
#   scripts/f2-wifi-npu.sh --device root@192.168.1.1
#   scripts/f2-wifi-npu.sh --device root@192.168.1.1 --duration 30 \
#       --sta phy0.1-sta0 --result-dir ./f2-run
#   scripts/f2-wifi-npu.sh --dry-run
#
# The ping goes out from the host, not from the board: the reply direction
# is the Wi-Fi STA ingress and its egress is lan4, which is exactly the F2
# path.  A ping started on the board would never touch lan4.
#
# Exit status: 0 the measurement ran (a negative F2 verdict is still a
# valid result); 1 an execution/measurement failure after the checks;
# 2 invalid arguments; 3 a refused precondition (no device/route/regio/
# STA/window).  The criteria and the code that produces them are fixed in
# the card; nothing is concluded when a refusal fires.
#
# POSIX sh on the host; the commands run on the board are POSIX/busybox sh.
# Tested with shellcheck -s sh.

set -u
umask 077
LC_ALL=C
export LC_ALL

PROG=${0##*/}

# --- fixed constants --------------------------------------------------

# NPU counter bases (v0.8 firmware, measured) and the documented safe regio
# window.  These are the only MMIO addresses the card can construct.
BAND0_BASE=1e8776e0
BAND1_BASE=1e877ae0
BAND2_BASE=1e86f640
COUNTER_WORDS=112
SAFE_LO=1e860000
SAFE_HI=1e88ffff
NEVER_LO=1e900000
NEVER_HI=1ebfffff

# The ping parameters from the D5 card.  count = duration / interval.
PING_INTERVAL=0.002
PING_SIZE=1400
PING_INTERVAL_COUNT=500

# --- defaults ---------------------------------------------------------

DEVICE=
STA=sta0
TARGET=192.168.234.1
DURATION=10
RESULT_DIR=
DRY_RUN=0
EGRESS_IF=lan4

# --- runtime state ----------------------------------------------------

BAND=
BASE=
FREQ=
STA_MASTER=
LAN4_MASTER=
HOST_IF=
HOST_SRC=
HOST_MAC=
DEV_IP=
BND_BEFORE_TOTAL=0
BND_BEFORE_P1=0
BND_BEFORE_F2=0
BND_BEFORE_F2P1=0
BND_AFTER_TOTAL=0
BND_AFTER_P1=0
BND_AFTER_F2=0
BND_AFTER_F2P1=0
PING_SENT=0
PING_RECV=0
PING_LOSS=
PING_STATUS=1

usage() {
	cat <<EOF
Usage: $PROG --device [user@]host [options]

Run the D5/F2 Wi-Fi STA ingress -> NPU/PPE -> lan4 measurement.  The card
is read-only on the board: it reads the NPU counters with regio, reads
ppe/entries and iw, and runs ping on the host.

Options:
  --device TARGET     ssh target, e.g. root@192.168.1.1 or root@xr1710g
                      (required unless --dry-run)
  --sta NAME          the board's station netdev (default: sta0)
  --target ADDR       IPv4 address to ping through the board
                      (default: 192.168.234.1)
  --duration SECONDS  traffic window in seconds (default: 10; 1..600)
  --result-dir DIR    evidence directory; the directory must not exist or
                      must be empty (default: ./f2-wifi-npu-<UTC stamp>)
  --dry-run           print every command and path that a real run would
                      use, then exit 0.  No device, route or file is
                      touched.
  -h, --help          this text

Measured counters (active band):
  idx12 TO_HOSTAPD_COUNT    NPU -> host (CPU path)
  idx21 TO_QDMA_COUNT       NPU -> QDMA (hardware egress)
  idx96 PPE_RX_SEND_COUNT   NPU -> PPE (hardware path)

Verdict (from the deltas):
  P2_P3_NPU_QDMA        d(idx96) > 0 and d(idx21) > 0: the main criterion
                        and the supporting QDMA evidence both moved
  P2_PPE_ONLY           d(idx96) > 0 but d(idx21) == 0: stops at the PPE
  P1_HOST_ONLY          only d(idx12) > 0: the host path, not F2
  NO_COUNTER_MOVEMENT   none of idx12/idx21/idx96 moved
  IDX21_WITHOUT_IDX96   d(idx21) > 0 without d(idx96) (unexpected)

The BND/PSE_PORT=1 evidence (P4) and the f2-flow match are reported next
to the verdict; they do not replace the counter criteria.  idx12 moving
alone is never a positive.

Refusals (exit 3, no data):
  * the STA is missing, down, not connected, not bridged, or on 6 GHz
  * the target route does not point at the device, or is a Meta/TUN/TAP/
    WireGuard route
  * the target is an address owned by the board (local termination)
  * regio is not loaded, its read range does not contain the 112-word
    windows, or it exposes 0x1e900000-0x1ebfffff
The card never guesses another address or window.

Exit status: 0 the measurement ran (a negative verdict is a valid
result); 1 execution/measurement failure (ssh, regio read, ping with no
reply, band change, counter decrease); 2 usage error; 3 refused
precondition.
EOF
}

usage_error() {
	printf '%s: %s\n' "$PROG" "$1" >&2
	printf 'Try "%s --help" for usage.\n' "$PROG" >&2
	exit 2
}

refuse() {
	printf 'REFUSE: %s\n' "$*" >&2
	exit 3
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

warn() {
	printf 'WARNING: %s\n' "$*" >&2
}

need_value() {
	[ "$2" -ge 2 ] || usage_error "$1 requires a value"
}

is_uint() {
	case ${1:-} in
	''|*[!0-9]*) return 1 ;;
	0) return 0 ;;
	0*) return 1 ;;
	*) return 0 ;;
	esac
}

is_ipv4() {
	case ${1:-} in
	''|*[!0-9.]*|.*|*.) return 1 ;;
	esac
	_old_ifs=$IFS
	IFS=.
	# shellcheck disable=SC2086
	set -- $1
	IFS=$_old_ifs
	[ "$#" -eq 4 ] || return 1
	for _octet in "$@"; do
		[ -n "$_octet" ] || return 1
		[ "$_octet" -ge 0 ] 2>/dev/null && [ "$_octet" -le 255 ] || return 1
	done
	return 0
}

check_name() {
	# $1 option name, $2 value
	case ${2:-} in
	''|*[!A-Za-z0-9_.:@-]*) usage_error "invalid $1 '$2'" ;;
	esac
}

# --- argument parsing -------------------------------------------------

while [ "$#" -gt 0 ]; do
	case $1 in
	-h|--help)
		usage
		exit 0
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--device)
		need_value "$1" "$#"
		DEVICE=$2
		shift 2
		;;
	--device=*)
		DEVICE=${1#*=}
		shift
		;;
	--sta)
		need_value "$1" "$#"
		STA=$2
		shift 2
		;;
	--sta=*)
		STA=${1#*=}
		shift
		;;
	--target)
		need_value "$1" "$#"
		TARGET=$2
		shift 2
		;;
	--target=*)
		TARGET=${1#*=}
		shift
		;;
	--duration)
		need_value "$1" "$#"
		DURATION=$2
		shift 2
		;;
	--duration=*)
		DURATION=${1#*=}
		shift
		;;
	--result-dir)
		need_value "$1" "$#"
		RESULT_DIR=$2
		shift 2
		;;
	--result-dir=*)
		RESULT_DIR=${1#*=}
		shift
		;;
	--)
		shift
		[ "$#" -eq 0 ] || usage_error "unexpected argument '$1'"
		;;
	-*)
		usage_error "unknown option '$1'"
		;;
	*)
		usage_error "unexpected argument '$1'"
		;;
	esac
done

[ -n "$DEVICE" ] || [ "$DRY_RUN" -eq 1 ] ||
	usage_error "--device is required (or use --dry-run)"
is_ipv4 "$TARGET" || usage_error "--target must be an IPv4 address, got '$TARGET'"
is_uint "$DURATION" || usage_error "--duration must be an unsigned integer, got '$DURATION'"
[ "$DURATION" -ge 1 ] && [ "$DURATION" -le 600 ] ||
	usage_error "--duration must be between 1 and 600 seconds"
check_name --sta "$STA"
if [ -n "$DEVICE" ]; then
	check_name --device "$DEVICE"
	case $DEVICE in *@*) _dev_host=${DEVICE#*@} ;; *) _dev_host=$DEVICE ;; esac
	[ -n "$_dev_host" ] || usage_error "--device must name a host"
	# The route check needs an address, not a command line.
	case $_dev_host in
	-*|*' '*|*'|'*|*'&'*|*';'*|*'*'*|*'$'*|*'`'*|*'('*|*')'*)
		usage_error "--device must be [user@]host, got '$DEVICE'"
		;;
	esac
fi

PING_COUNT=$((DURATION * PING_INTERVAL_COUNT))

# guard_window: $1 base hex, $2 words, $3 read_ranges.  Returns 0 when the
# span is inside the documented safe window and inside one configured
# range, and the configured ranges do not expose the A53 no-read range.
guard_window() {
	awk -v ranges="$3" -v base="$1" -v words="$2" \
		-v safe_lo="$SAFE_LO" -v safe_hi="$SAFE_HI" \
		-v never_lo="$NEVER_LO" -v never_hi="$NEVER_HI" '
	function h2d(s,   i, c, v) {
		v = 0
		s = tolower(s)
		sub(/^0x/, "", s)
		for (i = 1; i <= length(s); i++) {
			c = substr(s, i, 1)
			v = v * 16 + index("0123456789abcdef", c) - 1
		}
		return v
	}
	BEGIN {
		lo = h2d(base)
		hi = lo + (words - 1) * 4
		sl = h2d(safe_lo); sh = h2d(safe_hi)
		nl = h2d(never_lo); nh = h2d(never_hi)
		if (lo < sl || hi > sh) {
			printf "window 0x%s+%d words (0x%08x..0x%08x) is outside the documented safe window 0x%s..0x%s\n", base, words, lo, hi, safe_lo, safe_hi
			exit 1
		}
		if (lo <= nh && hi >= nl) {
			printf "window 0x%s+%d words intersects the A53 no-read range 0x%s..0x%s\n", base, words, never_lo, never_hi
			exit 1
		}
		n = split(ranges, r, ",")
		inside = 0
		for (i = 1; i <= n; i++) {
			s = r[i]
			gsub(/[ \t\r\n]/, "", s)
			if (s == "") continue
			split(s, p, "-")
			rlo = h2d(p[1])
			if (p[2] == "") {
				rhi = rlo
			} else {
				rhi = h2d(p[2])
			}
			if (rhi < rlo) {
				t = rlo; rlo = rhi; rhi = t
			}
			if (rlo <= nh && rhi >= nl) {
				printf "regio read_ranges exposes the A53 no-read range 0x%s..0x%s (%s); reload regio with the documented window before running\n", never_lo, never_hi, s
				exit 1
			}
			if (lo >= rlo && hi <= rhi) inside = 1
		}
		if (!inside) {
			printf "window 0x%s+%d words (0x%08x..0x%08x) is not inside regio read_ranges '%s'\n", base, words, lo, hi, ranges
			exit 1
		}
		exit 0
	}'
}

# --- dry run ----------------------------------------------------------

dry_run_plan() {
	_plan_device=${DEVICE:-root@192.168.1.1}
	_plan_result=${RESULT_DIR:-./f2-wifi-npu-<UTC stamp>}
	cat <<EOF
$PROG: dry run; nothing will be executed and no file will be created

Measurements:
  device:      $_plan_device
  sta:         $STA
  target:      $TARGET (ping goes out from the host)
  duration:    ${DURATION}s, ping -i $PING_INTERVAL -s $PING_SIZE -c $PING_COUNT
  result dir:  $_plan_result

Host route assertion (refuses a Meta/TUN route):
  ip route get $TARGET
  ip route get <the device's management address>
  the two routes must use the same interface, the device route must be
  on-link, and the target route must be on-link or via the device

Device preconditions (read-only):
  ssh $_plan_device test -e /sys/class/net/$STA
  ssh $_plan_device iw dev $STA link
  ssh $_plan_device readlink /sys/class/net/$STA/master
  ssh $_plan_device readlink /sys/class/net/$EGRESS_IF/master
  ssh $_plan_device cat /sys/module/regio/parameters/read_ranges
  ssh $_plan_device test -e /sys/kernel/debug/regio
  ssh $_plan_device test -e /sys/class/net/$EGRESS_IF
  ssh $_plan_device ip -4 -o addr show

NPU counter windows (inside the regio read range 0x1e860000-0x1e88ffff):
  ssh $_plan_device 'd $BAND0_BASE $COUNTER_WORDS' > $_plan_result/raw/regio-band0-<tag>.txt
  ssh $_plan_device 'd $BAND1_BASE $COUNTER_WORDS' > $_plan_result/raw/regio-band1-<tag>.txt
  a 6 GHz STA (band2 $BAND2_BASE, 28 words) is refused: no idx12/21/96

Snapshot before and after (<tag> is before/after):
  $_plan_result/raw/ppe-<tag>.txt      cat /sys/kernel/debug/ppe/entries
  $_plan_result/raw/iw-<tag>.txt       iw dev $STA link; iw dev $STA station dump
  $_plan_result/raw/$EGRESS_IF-<tag>.txt       tx/rx bytes and packets
  $_plan_result/raw/uptime-<tag>.txt   cat /proc/uptime

Traffic window:
  ping -i $PING_INTERVAL -s $PING_SIZE -c $PING_COUNT $TARGET
  $_plan_result/raw/ping.txt

Result:
  $_plan_result/result.json  idx12/idx21/idx96 before/after/delta, the
                             active band, BND rows, lan4 tx_byte delta,
                             ping and the F2 verdict
  $_plan_result/f2.txt       human-readable summary

Measured counters:
  idx12 TO_HOSTAPD_COUNT, idx21 TO_QDMA_COUNT, idx96 PPE_RX_SEND_COUNT
Verdict: P2_P3_NPU_QDMA, P2_PPE_ONLY, P1_HOST_ONLY, NO_COUNTER_MOVEMENT
         or IDX21_WITHOUT_IDX96; BND PSE_PORT=1 is side evidence only.

Host side (not changed by the card): an address in the target's subnet
on the lan4-side NIC (the D5 card used 192.168.234.45/24), and a route to
$TARGET through that NIC.  The route assertion above is what refuses the
Meta TUN.

Real-run preconditions not checked by --dry-run: ssh reachability, the
board's iw/ip/regio, root for regio and ping -i below 0.2 s, the link
between host and lan4, the STA association, the target address not being
owned by the board, and the documented D5 topology (sta in br-lan, lan3
down).  The card changes none of them.
EOF
}

if [ "$DRY_RUN" -eq 1 ]; then
	# Exercise the same window guard offline: both fixed windows must sit
	# inside the documented read range, and a range that exposes the A53
	# no-read range must be refused.  This catches a bad constant or a
	# broken guard without a device.
	for _base in "$BAND0_BASE" "$BAND1_BASE"; do
		if ! _msg=$(guard_window "$_base" "$COUNTER_WORDS" "0x1e860000-0x1e88ffff"); then
			printf 'ERROR: offline window guard failed: %s\n' "$_msg" >&2
			exit 1
		fi
	done
	if guard_window "$BAND0_BASE" "$COUNTER_WORDS" "0x1e900000-0x1ebfffff" >/dev/null 2>&1; then
		printf 'ERROR: the A53 no-read guard is broken\n' >&2
		exit 1
	fi
	dry_run_plan
	printf '\nWindow guard (offline): 0x%s+%d and 0x%s+%d PASS inside\n' \
		"$BAND0_BASE" "$COUNTER_WORDS" "$BAND1_BASE" "$COUNTER_WORDS"
	printf '  0x%s..0x%s; a span touching 0x%s..0x%s is REFUSED.\n' \
		"$SAFE_LO" "$SAFE_HI" "$NEVER_LO" "$NEVER_HI"
	exit 0
fi

# --- host-side helpers ------------------------------------------------

need_host_tool() {
	command -v "$1" >/dev/null 2>&1 || die "required host command not found: $1"
}

for _cmd in ssh ip ping getent awk sed tr cut head mkdir date cat mv tee id ls uname; do
	need_host_tool "$_cmd"
done

# Resolve the ssh target to the address the host actually routes to.  An
# ssh_config alias is honoured, so --device root@xr1710g works when ssh
# knows xr1710g; a target that cannot be resolved cannot be checked.
resolve_device_ip() {
	_ssh_host=$(ssh -G "$1" 2>/dev/null | awk '$1 == "hostname" { print $2; exit }')
	[ -n "$_ssh_host" ] || return 1
	case $_ssh_host in
	*:*) return 1 ;;
	esac
	_ip=$(getent ahostsv4 "$_ssh_host" 2>/dev/null | awk 'NR == 1 { print $1; exit }')
	if [ -z "$_ip" ]; then
		_ip=$(getent hosts "$_ssh_host" 2>/dev/null |
			awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $1; exit }')
	fi
	[ -n "$_ip" ] || return 1
	printf '%s\n' "$_ip"
}

route_field() {
	# $1 route line, $2 keyword (dev/via/src)
	printf '%s\n' "$1" |
		awk -v key="$2" '{ for (i = 1; i < NF; i++) if ($i == key) { print $(i + 1); exit } }'
}

is_hijack_dev() {
	case $(printf '%s' "$1" | tr 'A-Z' 'a-z') in
	meta|meta[0-9]*|tun|tun[0-9]*|tap|tap[0-9]*|wg|wg[0-9]*|tailscale[0-9]*|utun[0-9]*)
		return 0
		;;
	esac
	return 1
}

# --- route assertion --------------------------------------------------

DEV_IP=$(resolve_device_ip "$DEVICE") ||
	refuse "cannot resolve the device address from '$DEVICE'; the route to the device cannot be checked (use [user@]host or an ssh alias with a hostname)"

DEV_ROUTE=$(ip route get "$DEV_IP" 2>&1) ||
	refuse "ip route get $DEV_IP failed: $DEV_ROUTE"
case $DEV_ROUTE in
*unreachable*|*prohibit*|*blackhole*|*throw*|*Error*|*RTNETLINK*)
	refuse "the device $DEV_IP is not reachable by a host route: $DEV_ROUTE"
	;;
esac
DEV_DEV=$(route_field "$DEV_ROUTE" dev)
DEV_VIA=$(route_field "$DEV_ROUTE" via)
[ -n "$DEV_DEV" ] || refuse "cannot parse the device route: $DEV_ROUTE"
is_hijack_dev "$DEV_DEV" &&
	refuse "the device route uses $DEV_DEV, a Meta/TUN/TAP/WireGuard device: $DEV_ROUTE"

TARGET_ROUTE=$(ip route get "$TARGET" 2>&1) ||
	refuse "ip route get $TARGET failed: $TARGET_ROUTE"
case $TARGET_ROUTE in
*unreachable*|*prohibit*|*blackhole*|*throw*|*Error*|*RTNETLINK*)
	refuse "the target $TARGET is not reachable by a host route: $TARGET_ROUTE"
	;;
esac
TARGET_DEV=$(route_field "$TARGET_ROUTE" dev)
TARGET_VIA=$(route_field "$TARGET_ROUTE" via)
HOST_SRC=$(route_field "$TARGET_ROUTE" src)
[ -n "$TARGET_DEV" ] || refuse "cannot parse the target route: $TARGET_ROUTE"
is_hijack_dev "$TARGET_DEV" &&
	refuse "the target route uses $TARGET_DEV (the Meta TUN hijack): $TARGET_ROUTE"
[ "$TARGET_DEV" = "$DEV_DEV" ] ||
	refuse "the target route uses $TARGET_DEV but the device $DEV_IP uses $DEV_DEV; the target would not go through the device"
[ -z "$DEV_VIA" ] ||
	refuse "the device $DEV_IP is behind gateway $DEV_VIA on $DEV_DEV, not on the host's local link; F2 needs the host on the device's LAN link"
if [ -n "$TARGET_VIA" ] && [ "$TARGET_VIA" != "$DEV_IP" ]; then
	refuse "the target $TARGET is routed via $TARGET_VIA, not via the device $DEV_IP"
fi
[ -n "$HOST_SRC" ] || refuse "the target route has no source address: $TARGET_ROUTE"

HOST_IF=$TARGET_DEV
HOST_MAC=$(cat "/sys/class/net/$HOST_IF/address" 2>/dev/null) || HOST_MAC=
[ -n "$HOST_MAC" ] || warn "cannot read the MAC address of $HOST_IF; the F2-flow match will be skipped"

# ping -i below 0.2 s needs CAP_NET_RAW; probe it instead of failing after
# the snapshots and leaving a half-written run.
if [ "$(id -u 2>/dev/null)" != 0 ]; then
	ping -c 1 -i "$PING_INTERVAL" -W 1 127.0.0.1 >/dev/null 2>&1 ||
		refuse "ping -i $PING_INTERVAL needs root or CAP_NET_RAW; rerun as root"
fi

# --- device helpers ---------------------------------------------------

# ssh_run runs one short read-only command on the board.  BatchMode keeps
# the card non-interactive; a password prompt would hang a test run.
ssh_run() {
	ssh -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR \
		"$DEVICE" "$1"
}

# ssh_alive is a separate first contact so a missing key or an unreachable
# board refuses before any counter is read.
ssh_alive=$(ssh_run 'echo f2-alive' 2>&1) ||
	refuse "cannot ssh to $DEVICE: $ssh_alive"
[ "$ssh_alive" = f2-alive ] ||
	refuse "unexpected ssh response from $DEVICE: $ssh_alive"

# --- device preconditions --------------------------------------------

STA_EXISTS=$(ssh_run "test -e /sys/class/net/$STA && echo yes || echo no") ||
	refuse "cannot query the board: $STA_EXISTS"
[ "$STA_EXISTS" = yes ] ||
	refuse "station interface $STA does not exist on $DEVICE"

STA_STATE=$(ssh_run "cat /sys/class/net/$STA/operstate 2>/dev/null") ||
	STA_STATE=
case $STA_STATE in
down|lowerlayerdown|notpresent)
	refuse "$STA is $STA_STATE; bring the STA up and connect it to the AP first"
	;;
esac

IW_LINK=$(ssh_run "iw dev $STA link 2>&1") ||
	refuse "iw dev $STA link failed: $IW_LINK"
case $IW_LINK in
*"Connected to"*) : ;;
*) refuse "$STA is not connected to an AP: $IW_LINK" ;;
esac

FREQ=$(printf '%s\n' "$IW_LINK" | awk '
	/^[[:space:]]*freq:/ {
		v = $0
		sub(/^[^:]*:[[:space:]]*/, "", v)
		sub(/[^0-9].*$/, "", v)
		print v
		exit
	}')
if [ -z "$FREQ" ]; then
	IW_INFO=$(ssh_run "iw dev $STA info 2>&1") || IW_INFO=
	FREQ=$(printf '%s\n' "$IW_INFO" | awk '
		/\([0-9]+ MHz\)/ {
			v = $0
			sub(/.*\(/, "", v)
			sub(/ MHz\).*/, "", v)
			print v
			exit
		}')
fi
[ -n "$FREQ" ] || refuse "cannot determine the frequency of $STA from iw"

if [ "$FREQ" -ge 2400 ] && [ "$FREQ" -le 2500 ]; then
	BAND=band0
	BASE=$BAND0_BASE
elif [ "$FREQ" -ge 4900 ] && [ "$FREQ" -le 5895 ]; then
	BAND=band1
	BASE=$BAND1_BASE
elif [ "$FREQ" -ge 5925 ] && [ "$FREQ" -le 7125 ]; then
	refuse "$STA is on $FREQ MHz (6 GHz): its counter block $BAND2_BASE is a 28-word util block with no idx12/idx21/idx96; F2 cannot be answered on 6 GHz and the card will not guess a window"
else
	refuse "unexpected STA frequency ${FREQ} MHz; refusing to guess a counter window"
fi

EGRESS_EXISTS=$(ssh_run "test -e /sys/class/net/$EGRESS_IF && echo yes || echo no") ||
	refuse "cannot query $EGRESS_IF on the board"
[ "$EGRESS_EXISTS" = yes ] ||
	refuse "$EGRESS_IF does not exist on $DEVICE; the F2 egress counter cannot be read"

STA_MASTER=$(ssh_run "readlink /sys/class/net/$STA/master 2>/dev/null") ||
	STA_MASTER=
STA_MASTER=${STA_MASTER##*/}
[ -n "$STA_MASTER" ] ||
	refuse "$STA is not a bridge port; F2 needs $STA bridged into the same bridge as $EGRESS_IF"
LAN4_MASTER=$(ssh_run "readlink /sys/class/net/$EGRESS_IF/master 2>/dev/null") ||
	LAN4_MASTER=
LAN4_MASTER=${LAN4_MASTER##*/}
[ -n "$LAN4_MASTER" ] ||
	refuse "$EGRESS_IF is not a bridge port; F2 needs $EGRESS_IF bridged with $STA"
[ "$STA_MASTER" = "$LAN4_MASTER" ] ||
	refuse "$STA is in bridge $STA_MASTER but $EGRESS_IF is in bridge $LAN4_MASTER; put both in the same bridge"

REGIO_EXISTS=$(ssh_run "test -e /sys/kernel/debug/regio && echo yes || echo no") ||
	refuse "cannot query the regio debugfs node"
[ "$REGIO_EXISTS" = yes ] ||
	refuse "regio is not available at /sys/kernel/debug/regio; load regio.ko with the documented read window and retry"

REGIO_WRITABLE=$(ssh_run "test -w /sys/kernel/debug/regio && echo yes || echo no") ||
	refuse "cannot query the regio command node"
[ "$REGIO_WRITABLE" = yes ] ||
	refuse "regio is not writable by the ssh user; the dump command needs root (or the matching permission)"

REGIO_RANGES=$(ssh_run "cat /sys/module/regio/parameters/read_ranges 2>/dev/null") ||
	REGIO_RANGES=
[ -n "$REGIO_RANGES" ] ||
	refuse "regio did not expose read_ranges; the read window cannot be verified"

for _base in "$BAND0_BASE" "$BAND1_BASE"; do
	if ! _msg=$(guard_window "$_base" "$COUNTER_WORDS" "$REGIO_RANGES"); then
		refuse "$_msg"
	fi
done

# The target must not be an address the board itself owns: that would be
# local termination, not the Wi-Fi ingress -> lan4 path.
DEV_ADDRS=$(ssh_run "ip -4 -o addr show 2>/dev/null") ||
	DEV_ADDRS=
if printf '%s\n' "$DEV_ADDRS" |
	awk -v t="$TARGET" '{ for (i = 1; i <= NF; i++) { a = $i; sub(/\/.*/, "", a); if (a == t) found = 1 } } END { exit(found ? 0 : 1) }'
then
	refuse "$TARGET is an address owned by the board; that is local termination, not the F2 Wi-Fi ingress -> lan4 path"
fi

BRIDGE_MEMBERS=$(ssh_run "ls /sys/class/net/$STA_MASTER/brif 2>/dev/null | sort | tr '\n' ' '") ||
	BRIDGE_MEMBERS=

# --- result directory -------------------------------------------------

if [ -z "$RESULT_DIR" ]; then
	RESULT_DIR=./f2-wifi-npu-$(date -u +%Y%m%dT%H%M%SZ)
fi
if [ -d "$RESULT_DIR" ] && [ -n "$(ls -A "$RESULT_DIR" 2>/dev/null)" ]; then
	refuse "result directory $RESULT_DIR is not empty; choose a new --result-dir"
fi
mkdir -p "$RESULT_DIR/raw" || die "cannot create $RESULT_DIR/raw"
RAW=$RESULT_DIR/raw

# Record the identity and preconditions that made this run reproducible.
{
	printf '@@ host\n'
	uname -srm
	printf '@@ device\n'
	ssh_run 'uname -a' || true
	ssh_run 'cat /etc/openwrt_release 2>/dev/null' || true
	printf '@@ route\n'
	printf 'device %s\n%s\n' "$DEV_IP" "$DEV_ROUTE"
	printf 'target %s\n%s\n' "$TARGET" "$TARGET_ROUTE"
	printf '@@ sta\n'
	printf 'name %s\nfreq %s\nband %s\nbase %s\nmaster %s\n' "$STA" "$FREQ" "$BAND" "$BASE" "$STA_MASTER"
	printf 'bridge %s\nmembers %s\n' "$STA_MASTER" "$BRIDGE_MEMBERS"
	printf '@@ regio\nread_ranges %s\n' "$REGIO_RANGES"
	printf '@@ ping\n' 
} >"$RAW/pre.txt" 2>&1

# --- snapshots --------------------------------------------------------

# regio_dump reads one fixed 112-word window with the retried two-step
# debugfs protocol.  A read can come back as "ERR empty command" (roughly
# one in two) or as the previous buffer; the address and the line count
# are both validated before the dump is accepted.  No other address can be
# passed in: the callers only pass the two constants.
regio_dump() {
	_regio_base=$1
	ssh -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR \
		"$DEVICE" sh -s "$_regio_base" "$COUNTER_WORDS" <<'EOF'
base=$1
want=$2
rd=/sys/kernel/debug/regio
i=0
while [ "$i" -lt 15 ]; do
	printf 'd %s %s\n' "$base" "$want" >"$rd" 2>/dev/null
	out=$(cat "$rd" 2>/dev/null)
	n=$(printf '%s\n' "$out" | grep -c ' = ')
	case $out in
	*"$base = "*)
		if [ "$n" -eq "$want" ]; then
			printf '%s\n' "$out"
			exit 0
		fi
		;;
	esac
	i=$((i + 1))
	sleep 1
done
printf 'regio dump %s %s failed after %s attempts\n' "$base" "$want" "$i" >&2
exit 4
EOF
}

snapshot() {
	_tag=$1
	regio_dump "$BAND0_BASE" >"$RAW/regio-band0-$_tag.txt" ||
		die "regio dump of band0 failed; see $RAW/regio-band0-$_tag.txt"
	regio_dump "$BAND1_BASE" >"$RAW/regio-band1-$_tag.txt" ||
		die "regio dump of band1 failed; see $RAW/regio-band1-$_tag.txt"
	ssh_run "cat /sys/kernel/debug/ppe/entries" >"$RAW/ppe-$_tag.txt" ||
		die "cannot read ppe/entries"
	ssh_run "iw dev $STA link; printf '\n--- station dump ---\n'; iw dev $STA station dump 2>&1 || true" \
		>"$RAW/iw-$_tag.txt" || die "cannot read iw for $STA"
	ssh_run "printf 'tx_bytes '; cat /sys/class/net/$EGRESS_IF/statistics/tx_bytes; printf 'tx_packets '; cat /sys/class/net/$EGRESS_IF/statistics/tx_packets; printf 'rx_bytes '; cat /sys/class/net/$EGRESS_IF/statistics/rx_bytes; printf 'rx_packets '; cat /sys/class/net/$EGRESS_IF/statistics/rx_packets" \
		>"$RAW/$EGRESS_IF-$_tag.txt" || die "cannot read $EGRESS_IF statistics"
	ssh_run "cat /proc/uptime" >"$RAW/uptime-$_tag.txt" || true
}

snapshot before || die "before snapshot failed"

# --- traffic window ---------------------------------------------------

printf 'ping %s: %s packets at %ss interval (%ss)\n' \
	"$TARGET" "$PING_COUNT" "$PING_INTERVAL" "$DURATION"
if ping -i "$PING_INTERVAL" -s "$PING_SIZE" -c "$PING_COUNT" -W 1 "$TARGET" \
	>"$RAW/ping.txt" 2>&1; then
	PING_STATUS=0
else
	PING_STATUS=1
fi
PING_VALUES=$(awk '
	/packets transmitted/ {
		sent = $1
		for (i = 1; i <= NF; i++) {
			if ($i == "received" || $i == "received,") recv = $(i - 1)
			if ($i ~ /%/) loss = $i
		}
	}
	END { printf "%d %d %s\n", sent + 0, recv + 0, loss }
' "$RAW/ping.txt")
read -r PING_SENT PING_RECV PING_LOSS <<EOF
$PING_VALUES
EOF
[ -n "${PING_LOSS:-}" ] || PING_LOSS=n/a

snapshot after || die "after snapshot failed"

# --- parsing ----------------------------------------------------------

# read_window $1 file, $2 base, $3 label: sets WIN12/WIN21/WIN96 in the
# current shell (not a command substitution, so die can abort the run).
read_window() {
	_window_file=$1
	_window_base=$2
	_window_label=$3
	_window_values=$(awk -v base="$_window_base" -v words="$COUNTER_WORDS" '
	function h2d(s,   i, c, v) {
		v = 0
		s = tolower(s)
		sub(/^0x/, "", s)
		for (i = 1; i <= length(s); i++) {
			c = substr(s, i, 1)
			v = v * 16 + index("0123456789abcdef", c) - 1
		}
		return v
	}
	BEGIN { b = h2d(base); n = 0; i12 = -1; i21 = -1; i96 = -1; bad = 0 }
	$2 == "=" {
		n++
		if (length($1) != 8 || $1 !~ /^[0-9a-fA-F]+$/ ||
		    length($3) != 8 || $3 !~ /^[0-9a-fA-F]+$/) { bad = 1; next }
		off = (h2d($1) - b) / 4
		if (off < 0 || off >= words) { bad = 1; next }
		if (off == 12) i12 = h2d($3)
		if (off == 21) i21 = h2d($3)
		if (off == 96) i96 = h2d($3)
	}
	END {
		if (bad || n != words || i12 < 0 || i21 < 0 || i96 < 0) {
			print "invalid"
			exit 1
		}
		printf "%d %d %d\n", i12, i21, i96
	}' "$_window_file")
	read -r WIN12 WIN21 WIN96 <<EOF
$_window_values
EOF
	[ -n "${WIN12:-}" ] && [ -n "${WIN21:-}" ] && [ -n "${WIN96:-}" ] ||
		die "$_window_label: the 112-word window at 0x$_window_base is not a valid dump; see $_window_file"
}

# The active band drives the verdict; it was set from the STA frequency.
read_window "$RAW/regio-$BAND-before.txt" "$BASE" "active band before"
IDX12_BEFORE=$WIN12
IDX21_BEFORE=$WIN21
IDX96_BEFORE=$WIN96
read_window "$RAW/regio-$BAND-after.txt" "$BASE" "active band after"
IDX12_AFTER=$WIN12
IDX21_AFTER=$WIN21
IDX96_AFTER=$WIN96

# Both bands are recorded so the cross-check and the raw evidence are
# complete; only the active band is used by the criteria above.
read_window "$RAW/regio-band0-before.txt" "$BAND0_BASE" "band0 before"
B0_IDX12_BEFORE=$WIN12
B0_IDX21_BEFORE=$WIN21
B0_IDX96_BEFORE=$WIN96
read_window "$RAW/regio-band0-after.txt" "$BAND0_BASE" "band0 after"
B0_IDX12_AFTER=$WIN12
B0_IDX21_AFTER=$WIN21
B0_IDX96_AFTER=$WIN96
read_window "$RAW/regio-band1-before.txt" "$BAND1_BASE" "band1 before"
B1_IDX12_BEFORE=$WIN12
B1_IDX21_BEFORE=$WIN21
B1_IDX96_BEFORE=$WIN96
read_window "$RAW/regio-band1-after.txt" "$BAND1_BASE" "band1 after"
B1_IDX12_AFTER=$WIN12
B1_IDX21_AFTER=$WIN21
B1_IDX96_AFTER=$WIN96

IDX12_DELTA=$((IDX12_AFTER - IDX12_BEFORE))
IDX21_DELTA=$((IDX21_AFTER - IDX21_BEFORE))
IDX96_DELTA=$((IDX96_AFTER - IDX96_BEFORE))

read_lan4() {
	# $1 file, $2 prefix (BEFORE/AFTER); sets LAN4_TXB/TXP/RXB/RXP
	_lan_values=$(awk '
		$1 == "tx_bytes"   { txb = $2 }
		$1 == "tx_packets" { txp = $2 }
		$1 == "rx_bytes"   { rxb = $2 }
		$1 == "rx_packets" { rxp = $2 }
		END { printf "%s %s %s %s\n", txb, txp, rxb, rxp }
	' "$1")
	read -r LAN4_TXB LAN4_TXP LAN4_RXB LAN4_RXP <<EOF
$_lan_values
EOF
	for _v in "${LAN4_TXB:-}" "${LAN4_TXP:-}" "${LAN4_RXB:-}" "${LAN4_RXP:-}"; do
		is_uint "$_v" || die "$2: invalid $EGRESS_IF counter '$_v' in $1"
	done
}

read_lan4 "$RAW/$EGRESS_IF-before.txt" before
LAN4_TXB_BEFORE=$LAN4_TXB
LAN4_TXP_BEFORE=$LAN4_TXP
LAN4_RXB_BEFORE=$LAN4_RXB
LAN4_RXP_BEFORE=$LAN4_RXP
read_lan4 "$RAW/$EGRESS_IF-after.txt" after
LAN4_TXB_AFTER=$LAN4_TXB
LAN4_TXP_AFTER=$LAN4_TXP
LAN4_RXB_AFTER=$LAN4_RXB
LAN4_RXP_AFTER=$LAN4_RXP
LAN4_TXB_DELTA=$((LAN4_TXB_AFTER - LAN4_TXB_BEFORE))
LAN4_TXP_DELTA=$((LAN4_TXP_AFTER - LAN4_TXP_BEFORE))
LAN4_RXB_DELTA=$((LAN4_RXB_AFTER - LAN4_RXB_BEFORE))
LAN4_RXP_DELTA=$((LAN4_RXP_AFTER - LAN4_RXP_BEFORE))

# ppe_tsv turns a ppe/entries snapshot into a TSV of BND rows.  pse1 is
# PSE_PORT=1 (GDM1, the lan4/DSA conduit); f2 marks a row that carries the
# host's MAC or source address.
ppe_tsv() {
	awk -v mac="$HOST_MAC" -v src="$HOST_SRC" '
	function h2d(s,   i, c, v) {
		v = 0
		s = tolower(s)
		sub(/^0x/, "", s)
		for (i = 1; i <= length(s); i++) {
			c = substr(s, i, 1)
			v = v * 16 + index("0123456789abcdef", c) - 1
		}
		return v
	}
	$2 == "BND" {
		ib1 = ""; ib2 = ""; etype = ""
		for (i = 4; i <= NF; i++) {
			if ($i ~ /^ib1=/) { ib1 = $i; sub(/^ib1=/, "", ib1) }
			if ($i ~ /^ib2=/) { ib2 = $i; sub(/^ib2=/, "", ib2) }
			if ($i ~ /^etype=/) { etype = $i; sub(/^etype=/, "", etype) }
		}
		if (ib2 == "") next
		pp = int(h2d(ib2) / 32) % 16
		type = $3
		if ($3 == "IPv4" || $3 == "IPv6") type = $3 " " $4
		is_f2 = 0
		low = tolower($0)
		if (mac != "" && index(low, tolower(mac)) > 0) is_f2 = 1
		if (!is_f2 && src != "" && index($0, src) > 0) is_f2 = 1
		line = $0
		gsub(/\t/, " ", line)
		printf "%s\t%s\t%d\t%s\t%s\t%s\t%d\t%s\n", $1, type, pp, ib1, ib2, etype, is_f2, line
	}' "$1" >"$1.tsv"
}

ppe_counts() {
	# $1 the ppe/entries .tsv; prints "total pse1 f2 f2pse1"
	awk -F'\t' '
		{ total++; if ($3 == 1) p1++; if ($7 == 1) f2++; if ($7 == 1 && $3 == 1) f2p1++ }
		END { printf "%d %d %d %d\n", total + 0, p1 + 0, f2 + 0, f2p1 + 0 }
	' "$1"
}

ppe_tsv "$RAW/ppe-before.txt"
BND_BEFORE_VALUES=$(ppe_counts "$RAW/ppe-before.txt.tsv")
read -r BND_BEFORE_TOTAL BND_BEFORE_P1 BND_BEFORE_F2 BND_BEFORE_F2P1 <<EOF
$BND_BEFORE_VALUES
EOF
ppe_tsv "$RAW/ppe-after.txt"
BND_AFTER_VALUES=$(ppe_counts "$RAW/ppe-after.txt.tsv")
read -r BND_AFTER_TOTAL BND_AFTER_P1 BND_AFTER_F2 BND_AFTER_F2P1 <<EOF
$BND_AFTER_VALUES
EOF

BND_TOTAL_DELTA=$((BND_AFTER_TOTAL - BND_BEFORE_TOTAL))
BND_P1_DELTA=$((BND_AFTER_P1 - BND_BEFORE_P1))

# --- verdict ----------------------------------------------------------

P2=0; P3=0; P1=0
[ "$IDX96_DELTA" -gt 0 ] && P2=1
[ "$IDX21_DELTA" -gt 0 ] && P3=1
[ "$IDX12_DELTA" -gt 0 ] && P1=1
P4_BND=0; [ "$BND_AFTER_P1" -gt 0 ] && P4_BND=1
P4_F2=0; [ "$BND_AFTER_F2" -gt 0 ] && P4_F2=1
P4_F2P1=0; [ "$BND_AFTER_F2P1" -gt 0 ] && P4_F2P1=1

if [ "$PING_RECV" -le 0 ]; then
	VERDICT=PING_LOST
	VERDICT_DETAIL="no echo reply: the target was not reached through the board"
elif [ "$IDX96_DELTA" -lt 0 ] || [ "$IDX21_DELTA" -lt 0 ] || [ "$IDX12_DELTA" -lt 0 ]; then
	VERDICT=COUNTER_WRAPPED
	VERDICT_DETAIL="a counter decreased; the window is not valid (no modulo correction)"
elif [ "$P2" -eq 1 ] && [ "$P3" -eq 1 ]; then
	VERDICT=P2_P3_NPU_QDMA
	VERDICT_DETAIL="d(idx96) > 0 and d(idx21) > 0: the NPU forwarded the Wi-Fi ingress to the PPE and on to the QDMA"
elif [ "$P2" -eq 1 ]; then
	VERDICT=P2_PPE_ONLY
	VERDICT_DETAIL="d(idx96) > 0 but d(idx21) == 0: the ingress reached the PPE and stopped there"
elif [ "$P3" -eq 1 ]; then
	VERDICT=IDX21_WITHOUT_IDX96
	VERDICT_DETAIL="d(idx21) > 0 without d(idx96) > 0: unexpected; inspect the raw dumps"
elif [ "$P1" -eq 1 ]; then
	VERDICT=P1_HOST_ONLY
	VERDICT_DETAIL="only d(idx12) > 0: this is the host/CPU path, not F2"
else
	VERDICT=NO_COUNTER_MOVEMENT
	VERDICT_DETAIL="idx12, idx21 and idx96 did not move in this window"
fi

# A band change during the window makes the active-band delta meaningless.
AFTER_FREQ=$(awk '
	/^[[:space:]]*freq:/ {
		v = $0
		sub(/^[^:]*:[[:space:]]*/, "", v)
		sub(/[^0-9].*$/, "", v)
		print v
		exit
	}' "$RAW/iw-after.txt")
if [ -n "$AFTER_FREQ" ] && [ "$AFTER_FREQ" != "$FREQ" ]; then
	VERDICT=BAND_CHANGED
	VERDICT_DETAIL="the STA frequency changed from $FREQ to $AFTER_FREQ MHz during the window"
fi

# --- JSON -------------------------------------------------------------

json_str() {
	printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' -e 's/\r/\\r/g')"
}

json_bool() {
	if [ "$1" -ne 0 ]; then printf 'true'; else printf 'false'; fi
}

bnd_json() {
	# $1 TSV file; outputs a JSON array of the BND rows
	awk -F'\t' '
	function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
	BEGIN { printf "["; first = 1 }
	{
		if (!first) printf ","
		printf "\n    {\"slot\": \"%s\", \"type\": \"%s\", \"pse_port\": %s, \"ib1\": \"%s\", \"ib2\": \"%s\", \"etype\": \"%s\", \"f2_flow\": %s, \"line\": \"%s\"}",
			esc($1), esc($2), $3, esc($4), esc($5), esc($6), ($7 == 1 ? "true" : "false"), esc($8)
		first = 0
	}
	END { printf "\n  ]" }
	' "$1"
}

GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HOST_NAME=$(uname -n 2>/dev/null || printf 'unknown')
HOST_KERNEL=$(uname -sr 2>/dev/null || printf 'unknown')

RESULT_JSON=$RESULT_DIR/result.json
TMP_JSON=$RESULT_DIR/result.json.tmp
BND_BEFORE_JSON=$(bnd_json "$RAW/ppe-before.txt.tsv")
BND_AFTER_JSON=$(bnd_json "$RAW/ppe-after.txt.tsv")

{
	printf '{\n'
	printf '  "schema": "f2-wifi-npu/1",\n'
	printf '  "generated_at": %s,\n' "$(json_str "$GENERATED_AT")"
	printf '  "host": {"name": %s, "kernel": %s},\n' "$(json_str "$HOST_NAME")" "$(json_str "$HOST_KERNEL")"
	printf '  "device": %s,\n' "$(json_str "$DEVICE")"
	printf '  "topology": {\n'
	printf '    "host_if": %s,\n' "$(json_str "$HOST_IF")"
	printf '    "host_src": %s,\n' "$(json_str "$HOST_SRC")"
	printf '    "host_mac": %s,\n' "$(json_str "$HOST_MAC")"
	printf '    "device_mgmt_ip": %s,\n' "$(json_str "$DEV_IP")"
	printf '    "device_egress_if": %s,\n' "$(json_str "$EGRESS_IF")"
	printf '    "sta": %s,\n' "$(json_str "$STA")"
	printf '    "sta_master": %s,\n' "$(json_str "$STA_MASTER")"
	printf '    "bridge_members": %s,\n' "$(json_str "$BRIDGE_MEMBERS")"
	printf '    "sta_freq_mhz": %s,\n' "$FREQ"
	printf '    "band": %s,\n' "$(json_str "$BAND")"
	printf '    "counter_base": "0x%s",\n' "$BASE"
	printf '    "target": %s\n' "$(json_str "$TARGET")"
	printf '  },\n'
	printf '  "ping": {"count": %s, "interval_s": %s, "size": %s, "sent": %s, "received": %s, "loss": %s, "status": %s},\n' \
		"$PING_COUNT" "$PING_INTERVAL" "$PING_SIZE" "$PING_SENT" "$PING_RECV" "$(json_str "$PING_LOSS")" "$PING_STATUS"
	printf '  "counters": {\n'
	printf '    "band": %s,\n' "$(json_str "$BAND")"
	printf '    "counter_base": "0x%s",\n' "$BASE"
	printf '    "idx12": {"name": "TO_HOSTAPD_COUNT", "before": %s, "after": %s, "delta": %s},\n' \
		"$IDX12_BEFORE" "$IDX12_AFTER" "$IDX12_DELTA"
	printf '    "idx21": {"name": "TO_QDMA_COUNT", "before": %s, "after": %s, "delta": %s},\n' \
		"$IDX21_BEFORE" "$IDX21_AFTER" "$IDX21_DELTA"
	printf '    "idx96": {"name": "PPE_RX_SEND_COUNT", "before": %s, "after": %s, "delta": %s},\n' \
		"$IDX96_BEFORE" "$IDX96_AFTER" "$IDX96_DELTA"
	printf '    "lan4_tx_bytes": {"before": %s, "after": %s, "delta": %s},\n' \
		"$LAN4_TXB_BEFORE" "$LAN4_TXB_AFTER" "$LAN4_TXB_DELTA"
	printf '    "lan4_tx_packets": {"before": %s, "after": %s, "delta": %s},\n' \
		"$LAN4_TXP_BEFORE" "$LAN4_TXP_AFTER" "$LAN4_TXP_DELTA"
	printf '    "lan4_rx_bytes": {"before": %s, "after": %s, "delta": %s},\n' \
		"$LAN4_RXB_BEFORE" "$LAN4_RXB_AFTER" "$LAN4_RXB_DELTA"
	printf '    "lan4_rx_packets": {"before": %s, "after": %s, "delta": %s}\n' \
		"$LAN4_RXP_BEFORE" "$LAN4_RXP_AFTER" "$LAN4_RXP_DELTA"
	printf '  },\n'
	printf '  "bands": {\n'
	printf '    "band0": {"counter_base": "0x%s", "idx12": {"before": %s, "after": %s, "delta": %s}, "idx21": {"before": %s, "after": %s, "delta": %s}, "idx96": {"before": %s, "after": %s, "delta": %s}},\n' \
		"$BAND0_BASE" "$B0_IDX12_BEFORE" "$B0_IDX12_AFTER" "$((B0_IDX12_AFTER - B0_IDX12_BEFORE))" \
		"$B0_IDX21_BEFORE" "$B0_IDX21_AFTER" "$((B0_IDX21_AFTER - B0_IDX21_BEFORE))" \
		"$B0_IDX96_BEFORE" "$B0_IDX96_AFTER" "$((B0_IDX96_AFTER - B0_IDX96_BEFORE))"
	printf '    "band1": {"counter_base": "0x%s", "idx12": {"before": %s, "after": %s, "delta": %s}, "idx21": {"before": %s, "after": %s, "delta": %s}, "idx96": {"before": %s, "after": %s, "delta": %s}}\n' \
		"$BAND1_BASE" "$B1_IDX12_BEFORE" "$B1_IDX12_AFTER" "$((B1_IDX12_AFTER - B1_IDX12_BEFORE))" \
		"$B1_IDX21_BEFORE" "$B1_IDX21_AFTER" "$((B1_IDX21_AFTER - B1_IDX21_BEFORE))" \
		"$B1_IDX96_BEFORE" "$B1_IDX96_AFTER" "$((B1_IDX96_AFTER - B1_IDX96_BEFORE))"
	printf '  },\n'
	printf '  "ppe": {\n'
	printf '    "before": {"bnd_total": %s, "bnd_pse_port1": %s, "f2_flow": %s, "f2_flow_pse_port1": %s, "lines": %s},\n' \
		"$BND_BEFORE_TOTAL" "$BND_BEFORE_P1" "$(json_bool "$BND_BEFORE_F2")" "$BND_BEFORE_F2P1" "$BND_BEFORE_JSON"
	printf '    "after": {"bnd_total": %s, "bnd_pse_port1": %s, "f2_flow": %s, "f2_flow_pse_port1": %s, "lines": %s},\n' \
		"$BND_AFTER_TOTAL" "$BND_AFTER_P1" "$(json_bool "$BND_AFTER_F2")" "$BND_AFTER_F2P1" "$BND_AFTER_JSON"
	printf '    "delta": {"bnd_total": %s, "bnd_pse_port1": %s}\n' "$BND_TOTAL_DELTA" "$BND_P1_DELTA"
	printf '  },\n'
	printf '  "verdict": {\n'
	printf '    "p1_idx12_gt0": %s,\n' "$(json_bool "$P1")"
	printf '    "p2_idx96_gt0": %s,\n' "$(json_bool "$P2")"
	printf '    "p3_idx21_gt0": %s,\n' "$(json_bool "$P3")"
	printf '    "p4_bnd_pse_port1_after": %s,\n' "$(json_bool "$P4_BND")"
	printf '    "p4_bnd_f2_flow_pse_port1": %s,\n' "$(json_bool "$P4_F2P1")"
	printf '    "p4_f2_flow_seen": %s,\n' "$(json_bool "$P4_F2")"
	printf '    "result": %s,\n' "$(json_str "$VERDICT")"
	printf '    "detail": %s\n' "$(json_str "$VERDICT_DETAIL")"
	printf '  },\n'
	printf '  "raw": {"dir": %s, "files": ["pre.txt", "ping.txt", "regio-band0-before.txt", "regio-band1-before.txt", "regio-band0-after.txt", "regio-band1-after.txt", "ppe-before.txt", "ppe-after.txt", "iw-before.txt", "iw-after.txt", "%s-before.txt", "%s-after.txt", "uptime-before.txt", "uptime-after.txt"]}\n' \
		"$(json_str "$RAW")" "$EGRESS_IF" "$EGRESS_IF"
	printf '}\n'
} >"$TMP_JSON" || die "cannot write $TMP_JSON"
mv "$TMP_JSON" "$RESULT_JSON" || die "cannot rename $RESULT_JSON"

# Validate the JSON if jq is available; a broken card must not ship a
# result that looks machine-readable but is not.
if command -v jq >/dev/null 2>&1; then
	jq -e . "$RESULT_JSON" >/dev/null 2>&1 ||
		die "result.json is not valid JSON"
fi

# --- human summary ----------------------------------------------------

SUMMARY=$(cat <<EOF
F2 Wi-Fi-to-NPU card
  device:  $DEVICE
  host:    $HOST_NAME ($HOST_IF, src $HOST_SRC)
  sta:     $STA ($BAND, $FREQ MHz, base 0x$BASE, bridge $STA_MASTER)
  bridge:  $BRIDGE_MEMBERS
  target:  $TARGET
  ping:    $PING_SENT sent, $PING_RECV received, loss ${PING_LOSS} (rc $PING_STATUS)
  route:   target dev $TARGET_DEV; device $DEV_IP dev $DEV_DEV${TARGET_VIA:+ via $TARGET_VIA}
  counters ($BAND):
    idx12 TO_HOSTAPD_COUNT     before $IDX12_BEFORE after $IDX12_AFTER delta $IDX12_DELTA
    idx21 TO_QDMA_COUNT        before $IDX21_BEFORE after $IDX21_AFTER delta $IDX21_DELTA
    idx96 PPE_RX_SEND_COUNT    before $IDX96_BEFORE after $IDX96_AFTER delta $IDX96_DELTA
  $EGRESS_IF:  tx_bytes $LAN4_TXB_BEFORE -> $LAN4_TXB_AFTER (delta $LAN4_TXB_DELTA)
           tx_packets $LAN4_TXP_BEFORE -> $LAN4_TXP_AFTER (delta $LAN4_TXP_DELTA)
  ppe BND: before $BND_BEFORE_TOTAL (PSE_PORT=1 $BND_BEFORE_P1), after $BND_AFTER_TOTAL (PSE_PORT=1 $BND_AFTER_P1)
  ppe F2 flow seen: before $BND_BEFORE_F2, after $BND_AFTER_F2
  result:  $VERDICT
  detail:  $VERDICT_DETAIL
  evidence: $RESULT_JSON and $RAW/
EOF
)
printf '%s\n' "$SUMMARY"
printf '%s\n' "$SUMMARY" >"$RESULT_DIR/f2.txt" || warn "cannot write $RESULT_DIR/f2.txt"

if [ "$PING_RECV" -le 0 ]; then
	die "ping received no reply; the measurement did not run (evidence kept in $RESULT_DIR)"
fi
if [ "$VERDICT" = BAND_CHANGED ]; then
	die "the STA changed band during the window; the delta is not valid (evidence kept in $RESULT_DIR)"
fi
if [ "$VERDICT" = COUNTER_WRAPPED ]; then
	die "a counter decreased during the window; the delta is not valid (evidence kept in $RESULT_DIR)"
fi

exit 0
