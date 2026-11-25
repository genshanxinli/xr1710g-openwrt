#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# shellcheck disable=SC3043
#
# 2.5g-wired.sh - bidirectional 2.5G wired test for lan10g/wan10g.
#
# Runs on the bench host.  Each XR1710G 10G RJ45 port under test is cabled
# to its own bench-host 2.5G NIC; SSH management stays on lan3.  For every
# port the script measures host->device and device->host with TCP and UDP,
# one run at a time, never both directions and never both ports at once.
#
# Topology this harness assumes:
#
#   bench host 2.5G NIC A ==== lan10g (RTL8261BE, 2500BASE-T)
#   bench host 2.5G NIC B ==== wan10g (RTL8261BE, 2500BASE-T)
#   bench host management ---- lan3   (1G, SSH only)
#
# Both data cables are direct (no switch in between).  There is no
# lan10g <-> wan10g cable, no bridge and no firewall change.
# The only state is one temporary /32 address and one /32 peer route per
# side per port, removed by the EXIT trap together with any iperf3 stream.
# The device opens every iperf3 connection, so host->device is a reverse
# (-R) run and device->host is a normal run; the unbridged lab ports then
# need no input firewall rule.  The bench host must accept the two
# temporary data addresses on its data NICs: this script changes no host
# firewall, and a blocking host firewall makes an arm fail rather than
# silently measure zero.
#
# The device port is auto-detected: the first physical netdev that
# advertises 2500baseT, preferring lan2 then wan.  Pass --dev-lan10g-if /
# --dev-wan10g-if to override.
#
# A host NIC that is absent or below 2500 Mb/s, or a detected device port
# whose link is below 2500 Mb/s, is a clean skip (a faster link is accepted);
# nothing was measured, so the v2 contract (scripts/wireless/lib/no-client.sh)
# records missing-hardware and exits 3:
#
#   SKIP: no 2.5G link
#
# A missing precondition, rather than a slow link, is reported the same way
# (nothing measured, nothing failed) but with its own greppable first word
# and the v2 exit code of its cause:
#
#   BLOCKED: no device port advertises 2500baseT   (config-block, exit 2)
#   BLOCKED: lan2 is in br-lan                     (config-block, exit 2)
#   BLOCKED: <other precondition>                  (precondition-mismatch, exit 4)
#
# An unreachable device is not one of those: port detection has no evidence
# at all, so it stops with exit 2 (environment) instead of claiming the port
# is missing:
#
#   BLOCKED: cannot reach <USER@DEVICE> (<first ssh error line>)
#
# The second one is the common case on a base tree: lan2 is a br-lan member
# by default, and a bridged port is not a usable 2.5G data port.  Without
# --detach-port this script edits no bridge, no UCI file and no firewall: it
# prints the exact commands an operator has to run, and --detach-from-bridge
# prints that plan without attempting the measurement.  --detach-port is the
# one opt-in that changes device state: it runs the same two "ip link set"
# commands itself, keeps the port out of the bridge only for that port's
# arms, and puts it back from the EXIT trap (see lib/port-detach.sh).

set -u

PROG=2.5g-wired

SSH_OPTS=${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3}

DEVICE=${DEVICE:-root@192.168.1.1}
DEVICE_IP=
# Empty means "auto-detect on the device": the selected port is the first
# physical netdev that advertises 2500baseT, preferring lan2 then wan
# (the base-tree names of the two 10G RJ45 ports).  lan10g/wan10g are
# lab-image names and do not exist on a stock/base tree.
DEV_LAN_IF=${DEV_LAN_IF:-}
DEV_WAN_IF=${DEV_WAN_IF:-}
DEV_CANDIDATES=
# Device-side sysfs root.  /sys on a real unit; an offline test (or an
# image mounted for inspection) can point it elsewhere.  Read only.
DEV_SYSFS=${DEV_SYSFS:-/sys}
DETACH_FROM_BRIDGE=0
# 1 = run the detach/restore ourselves (lib/port-detach.sh); 0 keeps the
# printed-only plan that this script has always used.
DETACH_PORT=0
DETACH_PENDING=
BRIDGE_RESTORE_FAILED=0
PORTS=both
SEL_PORTS=
HOST_LAN_IF=
HOST_WAN_IF=
HOST_LAN_SPEED=
HOST_WAN_SPEED=
HOST_LAN_DRIVER=
HOST_WAN_DRIVER=
HOST_MGMT_IF=
HOST_DEFAULT_IF=
DEV_LAN_SPEED=
DEV_WAN_SPEED=
DEV_LAN_DUPLEX=
DEV_WAN_DUPLEX=
DEV_LAN_DRIVER=
DEV_WAN_DRIVER=

PROTO=both
PROTO_LIST=
DURATION=10
PARALLEL=4
UDP_RATE=2500
IPERF_PORT=5201
WARMUP=1
TAIL=1
OUT_DIR_OPT=
DRY_RUN=0

LAN_DEV_IP=10.99.20.1
LAN_HOST_IP=10.99.20.2
WAN_DEV_IP=10.99.21.1
WAN_HOST_IP=10.99.21.2

LAN_HOST_ADDR_ADDED=0
LAN_HOST_ROUTE_ADDED=0
LAN_DEV_ADDR_ADDED=0
LAN_DEV_ROUTE_ADDED=0
WAN_HOST_ADDR_ADDED=0
WAN_HOST_ROUTE_ADDED=0
WAN_DEV_ADDR_ADDED=0
WAN_DEV_ROUTE_ADDED=0

DEV_HAVE_TIMEOUT=0
DEV_HAVE_PING=0
DEV_IPERF_CONNECT_TIMEOUT=0
RUN_ID=
OUT_DIR=
CLEANED=0
SERVER_PID=
SSH_PID=
REMOTE_PIDFILE=

ARMS_TOTAL=0
ARMS_OK=0
ARMS_FAILED=0

usage() {
	cat <<'EOF'
Usage: 2.5g-wired.sh [options]

Bidirectional 2.5G wired test for the XR1710G lan10g and wan10g ports.
The script runs on the bench host, reaches the device over lan3/SSH for
control, and uses a dedicated host 2.5G NIC per device port for data.

  bench host 2.5G NIC ==== lan10g (RTL8261BE) ==== XR1710G
  bench host 2.5G NIC ==== wan10g (RTL8261BE) ==== XR1710G
  bench host management --- lan3 (SSH only) ------ XR1710G
  never lan10g ---- wan10g

Both data links are direct cables: no switch between the host NIC and the
device port, and never a cable between lan10g and wan10g.

Every arm is sequential.  The device is the iperf3 client, so a
host->device arm uses -R (the host sends) and a device->host arm uses the
normal direction; no firewall rule is added or changed.

Device selection:
  --device USER@IPV4         SSH target on the management network (lan3
                             by convention; default: root@192.168.1.1,
                             env DEVICE)
  --dev-lan10g-if NAME       device netdev for the 10G LAN port.  Omitted
                             means auto-detected: the first physical netdev
                             whose ethtool link modes include 2500baseT,
                             preferring lan2.  The base tree names this port
                             lan2 and keeps it in br-lan, which is a
                             precondition, not a failure; see
                             --detach-from-bridge below.
  --dev-wan10g-if NAME       device netdev for the 10G WAN port (default:
                             auto-detected, wan preferred).
  --ports both|lan10g|wan10g ports to test (default: both).  The labels are
                             historical: lan10g/wan10g mean the LAN and the
                             WAN 2.5G RJ45 port, whatever the netdev is
                             really called.
  --detach-from-bridge       do not measure.  Print the exact commands that
                             move the detected port out of br-lan, and the
                             ones that put it back, then exit 0.  This
                             script never runs them.
  --detach-port              let this script run those commands itself.  The
                             port's current master is read from sysfs (not
                             assumed to be br-lan), the port is taken out
                             with "ip link set <port> nomaster" only for
                             that port's arms, and the EXIT/INT/TERM/HUP
                             path puts it back into the recorded master.  A
                             restore that cannot be verified is an error
                             (exit 1), never a silent detach.  Refused when
                             the SSH session is the port being detached.
                             Without this flag nothing on the device changes.

Bench-host NICs (one per selected device port):
  --host-lan10g-if NAME      host 2.5G NIC cabled to lan10g
  --host-wan10g-if NAME      host 2.5G NIC cabled to wan10g
                             Omit only when exactly one dedicated 2.5G NIC
                             can be found for the selected port; --ports
                             both needs an explicit NIC for each port
                             because the cable mapping cannot be guessed.

Measurement:
  --proto tcp|udp|both       transports per arm (default: both)
  --duration SEC             iperf3 seconds per protocol run (default: 10)
  --parallel N               iperf3 streams per run (default: 4)
  --udp-rate MBPS            aggregate UDP offered rate, divided over the
                             streams (default: 2500)
  --iperf-port N             iperf3 control/data port (default: 5201)
  --warmup SEC               settle time after the server starts
                             (default: 1)
  --tail SEC                 settle time before the after snapshot
                             (default: 1)

Temporary addressing (one /32 per side per port, removed by the EXIT trap):
  --lan10g-dev-ip IP         device lan10g /32 (default: 10.99.20.1)
  --lan10g-host-ip IP        bench host lan10g NIC /32 (default: .2)
  --wan10g-dev-ip IP         device wan10g /32 (default: 10.99.21.1)
  --wan10g-host-ip IP        bench host wan10g NIC /32 (default: .2)

Output and safety:
  --out-dir DIR              artifact directory (default:
                             /tmp/2.5g-wired.YYYYmmdd-HHMMSS)
  --dry-run                  print the selected-arm plan and exact commands;
                             no SSH, no traffic, no address/route change,
                             no directory created.  With --detach-port it
                             also prints the detach and the restore
                             "ip link set" lines and runs neither.  Does
                             not require 2.5G hardware.
  -h, --help                 this text

A real run requires at least 2500 Mb/s on the device port and on the host
NIC cabled to it: 2500 is the floor, not the exact rate.  A 10G host NIC
negotiating 2500 against the device is fine, and so is a faster link; the
host must never be the bottleneck.  Otherwise it prints exactly:

  SKIP: no 2.5G link

and exits 3 (missing-hardware): 0 is reserved for a run that measured.

A missing precondition is not a slow link and is reported separately.  It is
also not measured, so it never exits 0; its cause picks the code:

  BLOCKED: no device port advertises 2500baseT   exits 2 (config-block)
  BLOCKED: <port> is in br-lan                   exits 2 (config-block)
  BLOCKED: <other precondition>                  exits 4 (precondition-mismatch)

An unreachable device is an environment problem, not a hardware verdict:
auto-detection cannot read ethtool, so the script stops with exit 2 instead
of reporting a missing port:

  BLOCKED: cannot reach <USER@DEVICE> (<first ssh error line>)

The "<port> is in br-lan" line prints the commands that clear it; without
--detach-port this script changes no bridge, no UCI and no firewall, so the
operator runs them (or asks for the plan with --detach-from-bridge).  With
--detach-port the script runs the detach and the restore itself and still
touches no UCI file, so a reboot or "ifup <netif>" returns the port to the
bridge even if the restore could not be verified.

Missing ssh, ethtool, ip or awk is an error, not a skip; iperf3 is
required once a 2.5G link is present.  The bench host must accept inbound
traffic to the temporary /32 addresses on its data NICs; no host or
device firewall is changed.  The script never installs packages and
never changes a firewall, UCI, module or firmware image, and the only
bridge change it can make is the opt-in --detach-port detach plus its
restore.  The EXIT trap removes both temporary addresses and peer routes
on both sides, stops the iperf3 streams and puts a detached port back.

What is recorded:
  link speed and duplex on both ends, the device-side ethtool -S and
  ip -s link snapshots before and after each protocol run, the deltas in
  RX/TX errors and drops and in ethtool error/drop counters, offered and
  arrived Gbit/s from the iperf3 JSON, TCP retransmits, and UDP loss.
  The last line is "status: ok" or "status: failed"; raw evidence stays
  in --out-dir.

Examples:
  # Show the plan for both ports without touching hardware.
  ./scripts/wireless/2.5g-wired.sh --dry-run

  # Both ports cabled to two dedicated 2.5G host NICs.
  sudo ./scripts/wireless/2.5g-wired.sh --device root@192.168.1.1 \
      --host-lan10g-if enp9s0 --host-wan10g-if enp10s0

  # One 2.5G host NIC, cable moved to lan10g for this invocation.
  sudo ./scripts/wireless/2.5g-wired.sh --device root@192.168.1.1 \
      --ports lan10g --host-lan10g-if enp9s0 --proto tcp

  # Base-tree names: wan is usable as-is; lan2 is inside br-lan.  Ask what
  # it would take to use lan2, then run the printed commands yourself.
  ./scripts/wireless/2.5g-wired.sh --ports lan10g --host-lan10g-if enp9s0 \
      --detach-from-bridge
  sudo ./scripts/wireless/2.5g-wired.sh --ports wan10g \
      --dev-wan10g-if wan --host-wan10g-if enp10s0
EOF
}

usage_error() {
	printf '%s: %s\n' "$PROG" "$1" >&2
	printf 'Try "%s --help" for usage.\n' "$PROG" >&2
	exit 2
}

die() {
	printf '%s: error: %s\n' "$PROG" "$1" >&2
	exit 1
}

note() {
	printf '%s: %s\n' "$PROG" "$1" >&2
}

# Shared "no client" record (scripts/wireless/lib/no-client.sh).  Best effort:
# a harness must still report its skip with the cause's exit code when the
# record cannot be written.
NO_CLIENT_LIB=$(dirname "$0")/lib/no-client.sh
# shellcheck source=lib/no-client.sh
[ -r "$NO_CLIENT_LIB" ] && . "$NO_CLIENT_LIB"
if ! command -v nc_cause_exit >/dev/null 2>&1; then
	nc_cause_exit() {
		case ${1:-} in
		missing-hardware) printf '3\n' ;;
		missing-tool | config-block | permission | environment | output-collision)
			printf '2\n' ;;
		precondition-mismatch) printf '4\n' ;;
		interrupted) printf '130\n' ;;
		*) printf '1\n' ;;
		esac
	}
fi

# Opt-in bridge detach/restore (scripts/wireless/lib/port-detach.sh).  Every
# read and write goes through ssh_dev, so the library edits the device, not
# the bench host; the netns test points PD_EXEC at a local runner instead.
PORT_DETACH_LIB=$(dirname "$0")/lib/port-detach.sh
if [ -r "$PORT_DETACH_LIB" ]; then
	# Read by the library, not here: same file, different call site.
	# shellcheck disable=SC2034
	PD_EXEC=ssh_dev
	# shellcheck disable=SC2034
	PD_SYSFS=$DEV_SYSFS
	# shellcheck source=lib/port-detach.sh
	. "$PORT_DETACH_LIB"
else
	no_port_detach_lib() {
		die "shared library not found: $PORT_DETACH_LIB (needed by --detach-port)"
	}
fi

# The one command that measures both 2.5G ports once the peer hardware exists.
NC_2G5_RUN='sudo sh scripts/wireless/2.5g-wired.sh --device <USER@DEVICE_IP> --ports both --host-lan10g-if <HOST_LAN_IF> --host-wan10g-if <HOST_WAN_IF>'

skip_no_link() {
	# Keep this line exact: the issue and callers grep it.  The record and the
	# two hints go to stderr so stdout stays the single SKIP line.
	[ $# -eq 0 ] || note "$1"
	# No 2.5G peer (or only a 1G link) is missing hardware, not a failed
	# measurement, so it is recorded instead of printed and forgotten: the
	# record is what puts this gap in hw-gap-report.sh (issue #70).
	_rec=$(NC_RECORD_CAUSE=missing-hardware \
		no_client_record "${OUT_DIR_OPT:-}" 70 2.5g-peer "$NC_2G5_RUN" \
		"${1:-no 2.5G link}" \
		"both ends report >= 2500 Mb/s (ethtool) and are link-up (/sys/class/net/*/carrier)" \
		"iperf3 TCP both directions >= 2.2 Gbit/s at --parallel 4 --duration 10" \
		"UDP arm loses < 0.1% at the offered 2500 Mbit/s" \
		"ppe/usage bound entries grow across the arm (the 2.5G path is offloaded)" 2>/dev/null)
	printf 'SKIP: no 2.5G link\n'
	if [ -n "$_rec" ]; then
		note "missing 2.5g-peer #70; once it is available run: $NC_2G5_RUN"
		note "no-client record: $_rec"
	fi
	exit "$(nc_cause_exit missing-hardware)"
}

missing_tool() {
	# missing_tool NAME DETAIL: iperf3 is required on both ends of every arm
	# and there is no source slot here (the host plays iperf3 server for the
	# device client and client for the device server), so a host or device
	# without it cannot measure at all.  Record the gap and exit 2: a
	# recorded prerequisite, not a failed run (1) and not a clean skip (0).
	_rec=$(NC_RECORD_CAUSE=missing-tool \
		no_client_record "${OUT_DIR_OPT:-}" 70 "$1" "$NC_2G5_RUN" "$2" \
		"both ends report >= 2500 Mb/s (ethtool) and are link-up (/sys/class/net/*/carrier)" \
		"iperf3 TCP both directions >= 2.2 Gbit/s at --parallel 4 --duration 10" \
		"UDP arm loses < 0.1% at the offered 2500 Mbit/s" 2>/dev/null)
	note "missing $1; on the device: opkg install iperf3 (or apk add iperf3)"
	[ -n "$_rec" ] && note "no-client record: $_rec"
	printf 'BLOCKED: missing %s\n' "$1"
	exit "$(nc_cause_exit missing-tool)"
}

blocked_cause() {
	case ${1:-} in
	2.5g-peer | port-in-bridge) printf 'config-block\n' ;;
	*) printf 'precondition-mismatch\n' ;;
	esac
}

blocked_record() {
	# blocked_record MISSING REASON: best effort "blocked" record (issue #70).
	# MISSING is the gap hw-gap-report.sh groups by, and it also picks the v2
	# cause through blocked_cause(), so the record and blocked()'s exit code
	# can never disagree:
	#
	#   2.5g-peer        config-block, deliberately.  The gap itself is missing
	#                    hardware, but this harness reaches the block only
	#                    after the board answered ethtool and no port
	#                    advertises 2500baseT: filing it as config-block keeps
	#                    the v1 status "blocked", exit 2, and hw-gap-report.sh's
	#                    HARDWARE_KEYS row (Class=hardware) that issue #70 and
	#                    test_2g5_blocked_record.py pin.  The report therefore
	#                    prints Class=hardware beside Cause=config-block; that
	#                    contrast is the tradeoff, not an accident.  Switching
	#                    to missing-hardware would mean exit 3 and a no-client
	#                    status, so it is left for a contract change, not a
	#                    comment fix.
	#   port-in-bridge   config-block: the port is still in a bridge.
	#   anything else    precondition-mismatch.
	# note() writes to stderr, so the caller's stdout stays the BLOCKED line.
	_cause=$(blocked_cause "$1")
	case $1 in
	2.5g-peer)
		_cmd=$NC_2G5_RUN
		_crit='both ends report >= 2500 Mb/s (ethtool) and are link-up (/sys/class/net/*/carrier); iperf3 TCP both directions >= 2.2 Gbit/s at --parallel 4 --duration 10'
		;;
	port-in-bridge)
		_cmd='ip link set <DEV_IF> down; ip link set <DEV_IF> nomaster; ip link set <DEV_IF> up'
		_crit='the selected device port has no master in /sys/class/net/*/master'
		;;
	*)
		_cmd=
		_crit=
		;;
	esac
	_rec=$(NC_RECORD_STATUS=blocked NC_RECORD_CAUSE=$_cause \
			no_client_record "${OUT_DIR_OPT:-}" 70 \
			"$1" "$_cmd" "${2:-blocked}" "$_crit" 2>/dev/null)
	[ -z "$_rec" ] || note "blocked record: $_rec"
}

blocked() {
	# blocked MESSAGE [DETAIL] [MISSING]
	# A precondition that is missing, rather than a link that is slow.
	# Nothing was measured, so nothing failed, but the v2 contract still
	# refuses 0 (only a measured run may use it): port-in-bridge and
	# 2.5g-peer are config-block and exit 2; any other precondition is
	# precondition-mismatch and exits 4.  The cause comes from the same
	# blocked_cause() helper blocked_record() uses, so the record and the
	# exit code match.
	# MISSING names the gap for hw-gap-report.sh: without it a block left no
	# record at all, so the 2.5G gap never appeared in that table.
	[ -z "${3:-}" ] || blocked_record "$3" "${2:-$1}"
	[ $# -lt 2 ] || note "$2"
	printf 'BLOCKED: %s\n' "$1"
	_cause=$(blocked_cause "${3:-}")
	exit "$(nc_cause_exit "$_cause")"
}

is_uint() {
	case ${1-} in
	''|*[!0-9]*) return 1 ;;
	*) return 0 ;;
	esac
}

is_ipv4() {
	case ${1-} in
	''|*[!0-9.]*|.*|*.) return 1 ;;
	esac
	printf '%s\n' "$1" | awk -F. '
		NF == 4 {
			for (i = 1; i <= 4; i++)
				if ($i == "" || $i !~ /^[0-9]+$/ ||
				    $i + 0 > 255)
					exit 1
			exit 0
		}
		{ exit 1 }
	'
}

is_ifname() {
	case ${1-} in
	''|*[!a-zA-Z0-9_.:@-]*) return 1 ;;
	*) return 0 ;;
	esac
}

link_speed() {
	# Numeric Mb/s from ethtool, or empty when the link is down/unknown.
	ethtool "$1" 2>/dev/null | awk -F: '
		{
			k = $1
			sub(/^[ \t]+/, "", k)
			if (k == "Speed") {
				v = $2
				gsub(/[^0-9]/, "", v)
				if (v != "")
					print v
				exit
			}
		}
	'
}

# The gate is "at least 2.5G", not "exactly 2.5G".  A 10G bench-host NIC on a
# 2.5G line is not a slow link: the host cannot become the bottleneck, and on
# this board lan2 is the only port that can skip_sw offload, so rejecting a
# 10G host NIC excludes the only clean bench this hardware has.  A speed above
# 2500 is accepted and noted, so the artifact still records what it negotiated.
require_2g5_speed() {
	# require_2g5_speed SIDE IFACE SPEED
	local side=$1 iface=$2 speed=${3-}

	case $speed in
	''|*[!0-9]*) return 1 ;;
	esac
	[ "$speed" -ge 2500 ] || return 1
	[ "$speed" -eq 2500 ] ||
		note "$side $iface link is $speed Mb/s (>= 2500, accepted)"
}

iface_driver() {
	ethtool -i "$1" 2>/dev/null | awk -F: '
		{
			k = $1
			sub(/^[ \t]+/, "", k)
			if (k == "driver") {
				v = $2
				sub(/^[ \t]+/, "", v)
				print v
				exit
			}
		}
	'
}

iface_exists() {
	ip -o link show dev "$1" >/dev/null 2>&1
}

iface_list() {
	ip -o link show 2>/dev/null | sed 's/^[0-9][0-9]*: //' |
		cut -d: -f1 | cut -d@ -f1
}

parse_route_dev() {
	awk '
		{
			for (i = 1; i <= NF; i++)
				if ($i == "dev") {
					print $(i + 1)
					exit
				}
		}
	'
}

route_dev() {
	ip route get "$1" 2>/dev/null | parse_route_dev
}

default_route_dev() {
	ip route show default 2>/dev/null | parse_route_dev
}

ssh_dev() {
	# SSH_OPTS is intentionally split into options, and the command
	# arguments are expanded here because they are remote command text.
	# shellcheck disable=SC2086,SC2029
	ssh $SSH_OPTS "$DEVICE" "$@"
}

dev_have() {
	ssh_dev "command -v $1 >/dev/null 2>&1"
}

dev_iface_exists() {
	ssh_dev "test -e $DEV_SYSFS/class/net/$1"
}

dev_master() {
	# -L as well as -e: kernel sysfs always has a resolvable target, but an
	# offline fake tree or a mounted image may hold the symlink alone.
	ssh_dev "if [ -L $DEV_SYSFS/class/net/$1/master ] || [ -e $DEV_SYSFS/class/net/$1/master ]; then readlink $DEV_SYSFS/class/net/$1/master 2>/dev/null || printf 'bridge\n'; fi" |
		sed 's#.*/##'
}

dev_phys_ports() {
	# Physical device netdevs whose ethtool link modes mention 2500baseT,
	# in preference order: lan2, then wan, then the rest.  One SSH round
	# trip, ethtool and grep only: no bridge, UCI or firewall is touched.
	# Every $-name below belongs to the remote shell, not to this one, and
	# DEV_SYSFS is expanded here on purpose so an offline test can point it
	# at a fake tree.
	# shellcheck disable=SC2029
	ssh_dev "for d in $DEV_SYSFS/class/net/*; do
		i=\${d##*/}
		# An unmatched glob leaves the literal '*'.  Without the first arm
		# it passed the filters below and reached the host side, where
		# 'for c in \$DEV_CANDIDATES' expanded it against the current
		# directory: a run with a bad DEV_SYSFS then picked BSDmakefile as
		# the device port and reported that interface absent.
		case \$i in
		''|'*')
			continue
			;;
		lo|br-*|wl*|wlan*|phy*|veth*|docker*|virbr*|tun*|tap*|wg*|tailscale*|ppp*|ifb*|bond*|sit*|ip6tnl*|nss*)
			continue
			;;
		esac
		ethtool \"\$i\" 2>/dev/null | grep -q 2500baseT || continue
		printf '%s\n' \"\$i\"
	done" | awk '
		{ if ($0 == "lan2") pre = $0; else if ($0 == "wan") wan = $0
		  else rest = rest " " $0 }
		END {
			if (pre != "") print pre
			if (wan != "") print wan
			n = split(rest, r, " ")
			for (i = 1; i <= n; i++)
				if (r[i] != "") print r[i]
		}'
}

dev_speed() {
	local out

	out=$(ssh_dev "ethtool $1 2>/dev/null") || return 1
	printf '%s\n' "$out" | awk -F: '
		{
			k = $1
			sub(/^[ \t]+/, "", k)
			if (k == "Speed") {
				v = $2
				gsub(/[^0-9]/, "", v)
				if (v != "")
					print v
				exit
			}
		}
	'
}

dev_duplex() {
	ssh_dev "ethtool $1 2>/dev/null" | awk -F: '
		{
			k = $1
			sub(/^[ \t]+/, "", k)
			if (k == "Duplex") {
				v = $2
				sub(/^[ \t]+/, "", v)
				sub(/[ \t]+$/, "", v)
				print v
				exit
			}
		}
	'
}

dev_driver() {
	ssh_dev "ethtool -i $1 2>/dev/null" | awk -F: '
		{
			k = $1
			sub(/^[ \t]+/, "", k)
			if (k == "driver") {
				v = $2
				sub(/^[ \t]+/, "", v)
				print v
				exit
			}
		}
	'
}

check_tools() {
	local mode="$1" c missing=

	shift
	for c in "$@"; do
		command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
	done
	[ -n "$missing" ] || return 0
	if [ "$mode" = "dry-run" ]; then
		note "missing local command(s):$missing (dry-run continues)"
		return 0
	fi
	die "missing local command(s):$missing"
}

# Two phases, link first: what it takes to read a link, then what it takes to
# move bytes over it.  A bench host without iperf3 must still be told that its
# NIC is not at 2.5G instead of that a tool is missing (issue #70).
check_link_tools() {
	check_tools "$1" ip awk sed grep tr cut date
}

check_traffic_tools() {
	# iperf3 is checked on its own: its absence is a recorded tool gap
	# (exit 2), not a generic "missing local command" die (issue #70).
	check_tools "$1" ssh ethtool
	command -v iperf3 >/dev/null 2>&1 && return 0
	if [ "$1" = "dry-run" ]; then
		note "missing local command(s): iperf3 (dry-run continues)"
		return 0
	fi
	missing_tool iperf3 "iperf3 is missing on the bench host"
}

host_2_5g_candidates() {
	# host_2_5g_candidates MGMT_IF DEFAULT_IF EXCLUDE_IF
	# Prints each dedicated 2.5G NIC with carrier, one per line.
	local mgmt="$1" default="$2" exclude="$3" c

	for c in $(iface_list); do
		case $c in
		lo|Meta|wl*|wwan*|ppp*|veth*|br-*|docker*|virbr*|tun*|tap*|wg*|tailscale*|wt*)
			continue
			;;
		esac
		[ -n "$mgmt" ] && [ "$c" = "$mgmt" ] && continue
		[ -n "$default" ] && [ "$c" = "$default" ] && continue
		[ -n "$exclude" ] && [ "$c" = "$exclude" ] && continue
		require_2g5_speed candidate "$c" "$(link_speed "$c")" >/dev/null 2>&1 || continue
		printf '%s\n' "$c"
	done
}

label_host_if() {
	case $1 in
	lan10g) printf '%s' "$HOST_LAN_IF" ;;
	wan10g) printf '%s' "$HOST_WAN_IF" ;;
	esac
}

label_host_option() {
	case $1 in
	lan10g) printf '%s' '--host-lan10g-if' ;;
	wan10g) printf '%s' '--host-wan10g-if' ;;
	esac
}

store_host_if() {
	# store_host_if LABEL IFACE SPEED DRIVER
	case $1 in
	lan10g)
		HOST_LAN_IF=$2
		HOST_LAN_SPEED=$3
		HOST_LAN_DRIVER=$4
		;;
	wan10g)
		HOST_WAN_IF=$2
		HOST_WAN_SPEED=$3
		HOST_WAN_DRIVER=$4
		;;
	esac
}

validate_host_if() {
	# validate_host_if LABEL IFACE
	local label="$1" iface="$2" speed

	iface_exists "$iface" ||
		skip_no_link "host interface $iface is absent"
	if [ -n "$HOST_MGMT_IF" ] && [ "$iface" = "$HOST_MGMT_IF" ]; then
		die "host NIC $iface carries the route to $DEVICE_IP; keep SSH on lan3/management"
	fi
	if [ -n "$HOST_DEFAULT_IF" ] && [ "$iface" = "$HOST_DEFAULT_IF" ]; then
		die "host NIC $iface carries the default route; use a dedicated data NIC"
	fi
	if [ -e "/sys/class/net/$iface/master" ]; then
		die "host NIC $iface is enslaved to a bridge; use a dedicated NIC"
	fi
	speed=$(link_speed "$iface")
	require_2g5_speed host "$iface" "$speed" ||
		skip_no_link "host $iface link is '${speed:-unknown}' Mb/s, need >= 2500"
	store_host_if "$label" "$iface" "$speed" "$(iface_driver "$iface")"
}

resolve_host_nics() {
	local label iface other candidates count opt

	HOST_MGMT_IF=$(route_dev "$DEVICE_IP")
	HOST_DEFAULT_IF=$(default_route_dev)

	for label in $SEL_PORTS; do
		iface=$(label_host_if "$label")
		if [ -n "$iface" ]; then
			validate_host_if "$label" "$iface"
		fi
	done

	for label in $SEL_PORTS; do
		[ -n "$(label_host_if "$label")" ] && continue
		opt=$(label_host_option "$label")
		case $label in
		lan10g) other=$HOST_WAN_IF ;;
		wan10g) other=$HOST_LAN_IF ;;
		esac
		candidates=$(host_2_5g_candidates "$HOST_MGMT_IF" \
			"$HOST_DEFAULT_IF" "$other")
		count=$(printf '%s\n' "$candidates" | grep -c .)
		case $count in
		0)
			skip_no_link "no dedicated 2.5G host NIC with carrier for $label (management=${HOST_MGMT_IF:-none} default=${HOST_DEFAULT_IF:-none})"
			;;
		1)
			validate_host_if "$label" "$candidates"
			;;
		*)
			usage_error "multiple 2.5G host NICs ($(printf '%s' "$candidates" | tr '\n' ' ')) for $label; pass $opt"
			;;
		esac
	done

	if [ "$PORTS" = "both" ] && [ "$HOST_LAN_IF" = "$HOST_WAN_IF" ]; then
		usage_error "lan10g and wan10g need two distinct host NICs"
	fi
}

dev_link_field() {
	# dev_link_field LABEL FIELD
	case "$1:$2" in
	lan10g:speed) printf '%s' "$DEV_LAN_SPEED" ;;
	lan10g:duplex) printf '%s' "$DEV_LAN_DUPLEX" ;;
	lan10g:driver) printf '%s' "$DEV_LAN_DRIVER" ;;
	wan10g:speed) printf '%s' "$DEV_WAN_SPEED" ;;
	wan10g:duplex) printf '%s' "$DEV_WAN_DUPLEX" ;;
	wan10g:driver) printf '%s' "$DEV_WAN_DRIVER" ;;
	esac
}

store_dev_link() {
	# store_dev_link LABEL SPEED DUPLEX DRIVER
	case $1 in
	lan10g)
		DEV_LAN_SPEED=$2
		DEV_LAN_DUPLEX=$3
		DEV_LAN_DRIVER=$4
		;;
	wan10g)
		DEV_WAN_SPEED=$2
		DEV_WAN_DUPLEX=$3
		DEV_WAN_DRIVER=$4
		;;
	esac
}

label_dev_if() {
	case $1 in
	lan10g) printf '%s' "$DEV_LAN_IF" ;;
	wan10g) printf '%s' "$DEV_WAN_IF" ;;
	esac
}

set_dev_if() {
	# set_dev_if LABEL IFACE
	case $1 in
	lan10g) DEV_LAN_IF=$2 ;;
	wan10g) DEV_WAN_IF=$2 ;;
	esac
}

detach_plan() {
	local label dev_if master dev_ip host_ip cleared=0

	printf 'DETACH PLAN: what a 2.5G run needs before it can measure\n'
	printf 'device: %s; nothing is executed here, no bridge is changed\n' \
		"$DEVICE"
	for label in $SEL_PORTS; do
		dev_if=$(label_dev_if "$label")
		case $label in
		lan10g) dev_ip=$LAN_DEV_IP; host_ip=$LAN_HOST_IP ;;
		wan10g) dev_ip=$WAN_DEV_IP; host_ip=$WAN_HOST_IP ;;
		esac
		printf '\n'
		printf 'port %s: dev_iface=%s dev_ip=%s host_ip=%s\n' \
			"$label" "$dev_if" "$dev_ip" "$host_ip"
		if [ -z "$dev_if" ]; then
			printf 'port %s: <not resolved: pass --dev-%s-if>\n' "$label" "$label"
			continue
		fi
		master=$(dev_master "$dev_if")
		if [ -z "$master" ]; then
			printf 'port %s: %s is not in a bridge; no detach needed\n' \
				"$label" "$dev_if"
			continue
		fi
		cleared=1
		print_bridge_plan "$dev_if" "$master"
	done

	if [ "$cleared" -eq 0 ]; then
		printf 'nothing to detach for the selected port(s)\n'
	fi
	exit 0
}

print_bridge_plan() {
	# print_bridge_plan DEV_IF BRIDGE
	# Printed by --detach-from-bridge and by the default bridged-port block.
	# Without --detach-port this script edits no bridge, UCI file or firewall,
	# so the operator runs these; --detach-port runs the library's own
	# nomaster/master pair instead (carrier and speed are kept, see
	# lib/port-detach.sh).
	local dev_if="$1" bridge="$2" netif

	netif=${bridge#br-}
	printf 'precondition: %s is a member of %s; a bridged port cannot be a 2.5G data port\n' \
		"$dev_if" "$bridge"
	printf 'this script changes no bridge, no UCI and no firewall; run these yourself:\n'
	printf '  # detach; not persistent: a reboot or "ifup %s" re-attaches it\n' "$netif"
	printf '  ip link set %s down\n' "$dev_if"
	printf '  ip link set %s nomaster\n' "$dev_if"
	printf '  ip link set %s up\n' "$dev_if"
	printf '  # re-attach when the measurement is done\n'
	printf '  ip link set %s down\n' "$dev_if"
	printf '  ip link set %s master %s\n' "$dev_if" "$bridge"
	printf '  ip link set %s up\n' "$dev_if"
	printf 'check first that the SSH session does not ride %s:\n' "$dev_if"
	printf '  ssh ... "ip neigh show <bench host> dev %s"   # get <MAC>\n' "$bridge"
	printf '  ssh ... "bridge fdb show br %s | grep -i <MAC>"   # must not print "dev %s"\n' "$bridge" "$dev_if"
}

resolve_device_ports() {
	# Fill DEV_LAN_IF/DEV_WAN_IF when the caller named neither or only one.
	# A port is a candidate when its ethtool link modes mention 2500baseT;
	# that is the only claim made here, the link itself is checked later.
	local label other c err first no_port=''

	if [ -n "$DEV_LAN_IF" ] && [ -n "$DEV_WAN_IF" ]; then
		return 0
	fi

	# Port detection reads ethtool on the device, so a first contact that
	# fails is an environment problem, not evidence about the hardware.  It
	# used to be folded into the empty candidate list and reported as "no
	# device port advertises 2500baseT" with exit 0 (issue #70).  Stop here
	# instead, with the environment cause, exit 2 and the ssh error that
	# caused it.
	err=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$DEVICE" true \
		2>&1 >/dev/null) || {
		first=$(printf '%s\n' "$err" | sed -n '1p')
		printf 'BLOCKED: cannot reach %s (%s)\n' "$DEVICE" \
			"${first:-ssh failed}"
		NC_RECORD_CAUSE=environment no_client_record "${OUT_DIR_OPT:-}" 70 \
			ssh "ssh -o BatchMode=yes $DEVICE true" \
			"${first:-ssh failed}" \
			"the device answers an ssh BatchMode probe" >/dev/null 2>&1 || :
		exit "$(nc_cause_exit environment)"
	}

	DEV_CANDIDATES=$(dev_phys_ports)
	for label in $SEL_PORTS; do
		[ -n "$(label_dev_if "$label")" ] && continue
		case $label in
		lan10g) other=$DEV_WAN_IF ;;
		wan10g) other=$DEV_LAN_IF ;;
		esac
		# shellcheck disable=SC2086
		for c in $DEV_CANDIDATES; do
			[ "$c" = "$other" ] && continue
			set_dev_if "$label" "$c"
			break
		done
	done

	for label in $SEL_PORTS; do
		[ -n "$(label_dev_if "$label")" ] || no_port="$no_port $label"
	done
	[ -z "$no_port" ] || blocked "no device port advertises 2500baseT" \
		"nothing on $DEVICE reports 2500baseT in its ethtool link modes (candidates:${DEV_CANDIDATES:+ $(printf '%s' "$DEV_CANDIDATES" | tr '\n' ' ')}); pass --dev-lan10g-if/--dev-wan10g-if for port(s)$no_port" \
		2.5g-peer
}

refuse_detach_if_ssh_ingress() {
	# refuse_detach_if_ssh_ingress DEV_IF BRIDGE: --detach-port changes the
	# port the SSH session may be riding, so prove it does not first
	# (pd_ssh_ingress_port reads the bridge fdb through ssh_dev).
	local dev_if=$1 master=$2 ingress
	ingress=$(pd_ssh_ingress_port "$master")
	if [ -n "$ingress" ] && [ "$ingress" = "$dev_if" ]; then
		die "SSH arrives on $dev_if ($master fdb says so); detaching it would cut the management path - move the SSH cable to lan3 and retry"
	fi
	if [ -z "$ingress" ]; then
		note "cannot resolve which $master port carries SSH (no mac in ip neigh, or no bridge tool on the device); --detach-port was asked for, so detaching anyway - if this session drops, a reboot or 'ifup ${master#br-}' re-attaches the port"
	fi
}

detach_pending_port() {
	# detach_pending_port LABEL: detach the port check_device queued for this
	# label, then re-read its link.  carrier and speed are kept, so a speed
	# below 2500 here means the port really is not a 2.5G data port.
	local label=$1 entry rest dev_if master speed
	for entry in $DETACH_PENDING; do
		case $entry in
		"$label":*) ;;
		*) continue ;;
		esac
		rest=${entry#*:}
		dev_if=${rest%%:*}
		master=${rest#*:}
		pd_detach "$dev_if" ||
			die "could not detach $dev_if from $master; see the message above - the port is not measured on while it is still bridged"
		speed=$(dev_speed "$dev_if") ||
			die "cannot run ethtool on $DEVICE:$dev_if after detaching it from $master"
		require_2g5_speed device "$dev_if" "$speed" ||
			skip_no_link "device $dev_if link is '${speed:-unknown}' Mb/s after leaving $master, need >= 2500"
		store_dev_link "$label" "$speed" "$(dev_duplex "$dev_if")" \
			"$(dev_driver "$dev_if")"
	done
	return 0
}

restore_bridge() {
	# Last step of every cleanup path, and never skipped because an earlier
	# step failed: the port must go back into its recorded master.
	if pd_restore; then
		return 0
	fi
	BRIDGE_RESTORE_FAILED=1
	note "cleanup: bridge restore failed; $PD_PORT is still out of $PD_MASTER"
	return 1
}

check_device() {
	local label dev_if speed duplex master ssh_client_ip mgmt_dev

	ssh_dev true >/dev/null 2>&1 ||
		die "cannot SSH to $DEVICE (set --device or SSH_OPTS)"
	[ "$(ssh_dev 'id -u' 2>/dev/null)" = "0" ] ||
		die "$DEVICE does not give root; the temporary addressing needs root"

	dev_have ethtool || die "ethtool is missing on $DEVICE"
	dev_have ip || die "ip is missing on $DEVICE"

	for label in $SEL_PORTS; do
		dev_if=$(label_dev_if "$label")
		dev_iface_exists "$dev_if" ||
			skip_no_link "device interface $dev_if is absent"
		master=$(dev_master "$dev_if")
		if [ -n "$master" ] && [ "$DETACH_PORT" -eq 0 ]; then
			print_bridge_plan "$dev_if" "$master"
			blocked "$dev_if is in $master" \
				"$dev_if is a member of $master; detach it first (see the commands above), then run this test again" \
				port-in-bridge
		fi
		if [ -n "$master" ]; then
			# --detach-port: the detach itself waits until main() has armed
			# the EXIT trap (see detach_pending_port), so an interrupt at
			# any later point can still put the port back.
			refuse_detach_if_ssh_ingress "$dev_if" "$master"
			DETACH_PENDING="$DETACH_PENDING $label:$dev_if:$master"
			note "port $dev_if is a member of $master; --detach-port will detach it for this port's arms and restore it on exit"
		fi
		speed=$(dev_speed "$dev_if") ||
			die "cannot run ethtool on $DEVICE:$dev_if"
		require_2g5_speed device "$dev_if" "$speed" ||
			skip_no_link "device $dev_if link is '${speed:-unknown}' Mb/s, need >= 2500"
		duplex=$(dev_duplex "$dev_if")
		store_dev_link "$label" "$speed" "$duplex" \
			"$(dev_driver "$dev_if")"
	done

	# Only require iperf3 after the link checks: an absent or 1G link is
	# a clean skip, even on a device that has no iperf3 package.
	dev_have iperf3 ||
		missing_tool iperf3 "iperf3 is missing on $DEVICE"
	dev_have timeout >/dev/null 2>&1 && DEV_HAVE_TIMEOUT=1
	dev_have ping >/dev/null 2>&1 && DEV_HAVE_PING=1
	if ssh_dev "iperf3 --help 2>&1 | grep -q -- '--connect-timeout'"; then
		DEV_IPERF_CONNECT_TIMEOUT=1
	fi

	if [ "$PORTS" = "both" ] && [ "$DEV_LAN_IF" = "$DEV_WAN_IF" ]; then
		die "device lan10g and wan10g must be different interfaces"
	fi

	# Refuse to touch a data port that also carries the SSH session.
	# The single quotes are deliberate: SSH_CLIENT expands on the device.
	# shellcheck disable=SC2016
	ssh_client_ip=$(ssh_dev 'printf "%s" "${SSH_CLIENT%% *}"' 2>/dev/null) ||
		ssh_client_ip=
	if is_ipv4 "$ssh_client_ip"; then
		mgmt_dev=$(ssh_dev "ip route get $ssh_client_ip 2>/dev/null" |
			parse_route_dev)
		for label in $SEL_PORTS; do
			dev_if=$(label_dev_if "$label")
			if [ "$mgmt_dev" = "$dev_if" ]; then
				die "SSH arrives on $dev_if; reconnect over lan3/management before touching that data port"
			fi
		done
	fi
}

set_pair_flags() {
	# set_pair_flags LABEL HOST_ADDR HOST_ROUTE DEV_ADDR DEV_ROUTE
	case $1 in
	lan10g)
		LAN_HOST_ADDR_ADDED=$2
		LAN_HOST_ROUTE_ADDED=$3
		LAN_DEV_ADDR_ADDED=$4
		LAN_DEV_ROUTE_ADDED=$5
		;;
	wan10g)
		WAN_HOST_ADDR_ADDED=$2
		WAN_HOST_ROUTE_ADDED=$3
		WAN_DEV_ADDR_ADDED=$4
		WAN_DEV_ROUTE_ADDED=$5
		;;
	esac
}

setup_pair() {
	# setup_pair LABEL DEV_IF HOST_IF DEV_IP HOST_IP
	local label="$1" dev_if="$2" host_if="$3" dev_ip="$4" host_ip="$5"
	local host_addr=0 host_route=0 dev_addr=0 dev_route=0 route

	if ip -o -4 addr show 2>/dev/null |
	   grep -Eq "[[:space:]]$host_ip/"; then
		ip -o -4 addr show dev "$host_if" 2>/dev/null |
			grep -Eq "[[:space:]]$host_ip/" ||
			die "$host_ip already exists on another host interface"
	else
		ip addr add "$host_ip/32" dev "$host_if" ||
			die "cannot add $host_ip/32 to $host_if"
		host_addr=1
	fi
	set_pair_flags "$label" "$host_addr" "$host_route" \
		"$dev_addr" "$dev_route"

	route=$(ip route show "$dev_ip/32" 2>/dev/null)
	if [ -n "$route" ]; then
		printf '%s\n' "$route" |
			grep -Eq "dev $host_if([[:space:]]|$)" ||
			die "$dev_ip/32 already routes away from $host_if"
	else
		ip route add "$dev_ip/32" dev "$host_if" ||
			die "cannot add $dev_ip/32 route via $host_if"
		host_route=1
	fi
	set_pair_flags "$label" "$host_addr" "$host_route" \
		"$dev_addr" "$dev_route"

	if ssh_dev "ip -o -4 addr show 2>/dev/null | grep -Eq '[[:space:]]$dev_ip/'"; then
		ssh_dev "ip -o -4 addr show dev $dev_if 2>/dev/null | grep -Eq '[[:space:]]$dev_ip/'" ||
			die "$dev_ip already exists on another device interface"
	else
		ssh_dev "ip addr add $dev_ip/32 dev $dev_if" ||
			die "cannot add $dev_ip/32 to $dev_if on $DEVICE"
		dev_addr=1
	fi
	set_pair_flags "$label" "$host_addr" "$host_route" \
		"$dev_addr" "$dev_route"

	if [ -n "$(ssh_dev "ip route show $host_ip/32 2>/dev/null")" ]; then
		ssh_dev "ip route show $host_ip/32 2>/dev/null | grep -Eq 'dev $dev_if([[:space:]]|\$)'" ||
			die "$host_ip/32 already routes away from $dev_if on $DEVICE"
	else
		ssh_dev "ip route add $host_ip/32 dev $dev_if" ||
			die "cannot add $host_ip/32 route via $dev_if on $DEVICE"
		dev_route=1
	fi
	set_pair_flags "$label" "$host_addr" "$host_route" \
		"$dev_addr" "$dev_route"

	# The device->host direction must work first; the host->device
	# direction may be blocked by a bench-host firewall and is not
	# required for this check.  Report, do not fail: the arms are the
	# measurement.
	if [ "$DEV_HAVE_PING" = "1" ]; then
		ssh_dev "ping -c 1 -W 2 -I $dev_if $host_ip >/dev/null 2>&1" ||
			note "device cannot ping $host_ip over $dev_if; continuing to the arms"
	fi
}

cleanup_pair() {
	# cleanup_pair LABEL
	local label="$1" dev_if="" host_if="" dev_ip="" host_ip=""
	local h_addr=0 h_route=0 d_addr=0 d_route=0

	case $label in
	lan10g)
		dev_if=$DEV_LAN_IF
		host_if=$HOST_LAN_IF
		dev_ip=$LAN_DEV_IP
		host_ip=$LAN_HOST_IP
		h_addr=$LAN_HOST_ADDR_ADDED
		h_route=$LAN_HOST_ROUTE_ADDED
		d_addr=$LAN_DEV_ADDR_ADDED
		d_route=$LAN_DEV_ROUTE_ADDED
		;;
	wan10g)
		dev_if=$DEV_WAN_IF
		host_if=$HOST_WAN_IF
		dev_ip=$WAN_DEV_IP
		host_ip=$WAN_HOST_IP
		h_addr=$WAN_HOST_ADDR_ADDED
		h_route=$WAN_HOST_ROUTE_ADDED
		d_addr=$WAN_DEV_ADDR_ADDED
		d_route=$WAN_DEV_ROUTE_ADDED
		;;
	esac

	[ -n "$dev_if" ] && [ -n "$host_if" ] || return 0

	if [ "$d_route" = "1" ]; then
		ssh_dev "ip route del $host_ip/32 dev $dev_if" >/dev/null 2>&1 ||
			note "cleanup: could not remove device route $host_ip/32"
	fi
	if [ "$d_addr" = "1" ]; then
		ssh_dev "ip addr del $dev_ip/32 dev $dev_if" >/dev/null 2>&1 ||
			note "cleanup: could not remove device address $dev_ip/32"
	fi
	if [ "$h_route" = "1" ]; then
		ip route del "$dev_ip/32" dev "$host_if" >/dev/null 2>&1 ||
			note "cleanup: could not remove host route $dev_ip/32"
	fi
	if [ "$h_addr" = "1" ]; then
		ip addr del "$host_ip/32" dev "$host_if" >/dev/null 2>&1 ||
			note "cleanup: could not remove host address $host_ip/32"
	fi
	set_pair_flags "$label" 0 0 0 0
}

stop_streams() {
	if [ -n "${SSH_PID:-}" ]; then
		kill -TERM "$SSH_PID" 2>/dev/null || :
		wait "$SSH_PID" 2>/dev/null || :
		SSH_PID=
	fi
	if [ -n "${SERVER_PID:-}" ]; then
		kill -TERM "$SERVER_PID" 2>/dev/null || :
		wait "$SERVER_PID" 2>/dev/null || :
		SERVER_PID=
	fi
	if [ -n "${REMOTE_PIDFILE:-}" ]; then
		ssh_dev "if [ -s $REMOTE_PIDFILE ]; then kill \$(cat $REMOTE_PIDFILE) 2>/dev/null; fi; rm -f $REMOTE_PIDFILE" \
			>/dev/null 2>&1 || :
		REMOTE_PIDFILE=
	fi
}

cleanup_all() {
	[ "${CLEANED:-0}" = "1" ] && return 0
	CLEANED=1
	stop_streams
	cleanup_pair lan10g
	cleanup_pair wan10g
	# Order is deliberate: the traffic and the temporary addressing go first
	# (so the port rejoins the bridge with nothing of ours on it), and every
	# step above is non-fatal, so a failed address removal cannot skip this.
	restore_bridge || :
	note "cleanup: streams stopped, temporary addresses/routes removed"
}

on_exit() {
	# EXIT trap: cleanup_all already ran on the normal path, and a restore
	# that could not be verified must still decide the exit status here,
	# because the failure happens after main() picked one.
	cleanup_all
	if [ "$BRIDGE_RESTORE_FAILED" = "1" ]; then
		exit 1
	fi
}

ipp_stats() {
	# ipp_stats FILE -> "rx_err rx_drop tx_err tx_drop"
	awk '
		/^[ \t]*RX:/ { mode = "rx"; next }
		/^[ \t]*TX:/ { mode = "tx"; next }
		mode != "" && $1 ~ /^[0-9]+$/ {
			if (mode == "rx") {
				rxe = $3; rxd = $4
			} else {
				txe = $3; txd = $4
			}
			mode = ""
		}
		END { printf "%d %d %d %d\n", rxe + 0, rxd + 0, txe + 0, txd + 0 }
	' "$1"
}

ethtool_bad() {
	# Sum of ethtool -S counters whose names mention errors/drops.
	awk -F: '
		{
			k = $1
			gsub(/^[ \t]+|[ \t]+$/, "", k)
			v = $2
			gsub(/[^0-9]/, "", v)
			if (v != "" && tolower(k) ~ /(err|drop|crc|over|fail|discard|miss)/)
				sum += v
		}
		END { printf "%d\n", sum + 0 }
	' "$1"
}

delta() {
	if [ "$2" -ge "$1" ]; then
		printf '%s' "$(( $2 - $1 ))"
	else
		printf '0'
	fi
}

iperf_summary() {
	# Offered/arrived from a pretty-printed iperf3 -J file:
	# sum_sent bits,bytes,retransmits then sum_received and loss.
	awk '
	BEGIN {
		cur = ""
		sbps = "null"; sbytes = "null"; sretr = "null"
		rbps = "null"; rbytes = "null"; rlost = "null"
	}
	{
		line = $0
		sub(/^[[:space:]]+/, "", line)
		if (index(line, "\"sum_sent\":") == 1) { cur = "s"; next }
		if (index(line, "\"sum_received\":") == 1) { cur = "r"; next }
		if (cur != "" && (line == "}," || line == "}")) { cur = ""; next }
		if (cur == "") next
		sub(/,$/, "", line)
		if (index(line, "\"bits_per_second\":") == 1) {
			v = line
			sub(/^"bits_per_second":[[:space:]]*/, "", v)
			if (cur == "s") sbps = v; else rbps = v
		} else if (index(line, "\"bytes\":") == 1) {
			v = line
			sub(/^"bytes":[[:space:]]*/, "", v)
			if (cur == "s") sbytes = v; else rbytes = v
		} else if (index(line, "\"retransmits\":") == 1) {
			v = line
			sub(/^"retransmits":[[:space:]]*/, "", v)
			if (cur == "s") sretr = v
		} else if (index(line, "\"lost_percent\":") == 1) {
			v = line
			sub(/^"lost_percent":[[:space:]]*/, "", v)
			rlost = v
		}
	}
	END {
		printf "%s %s %s %s %s %s\n", \
			sbps, sbytes, sretr, rbps, rbytes, rlost
	}
	' "$1"
}

iperf_error() {
	awk '
	{
		line = $0
		sub(/^[[:space:]]+/, "", line)
		if (index(line, "\"error\":") == 1) {
			v = line
			sub(/^"error":[[:space:]]*/, "", v)
			sub(/,$/, "", v)
			gsub(/^"|"$/, "", v)
			print v
			exit
		}
	}
	' "$1"
}

gbps() {
	# bits/s -> Gbit/s with three decimals; empty for missing values.
	case ${1-} in
	''|null|*[!0-9.]*) printf '' ;;
	*) awk -v b="$1" 'BEGIN { printf "%.3f", b / 1000000000.0 }' ;;
	esac
}

loss_percent() {
	# loss_percent SENT_BYTES RECEIVED_BYTES
	case ${1-}:${2-} in
	*[!0-9:]*|:|*:) printf '' ;;
	*)
		awk -v s="$1" -v r="$2" 'BEGIN {
			if (s + 0 > 0)
				printf "%.2f", (s - r) * 100.0 / s
		}'
		;;
	esac
}

run_one() {
	# run_one ARM_DIR PROTO DIRECTION LABEL DEV_IF HOST_IF DEV_IP HOST_IP
	local armdir="$1" proto="$2" direction="$3" label="$4"
	local dev_if="$5" host_if="$6" dev_ip="$7" host_ip="$8"
	local status args per_stream timeout_prefix summary
	local sbps sbytes sret rbps rbytes rlost
	local stats b_rxe b_rxd b_txe b_txd a_rxe a_rxd a_txe a_txd
	local b_dev_bad a_dev_bad b_host_bad a_host_bad

	R_ERR=
	R_OFFERED=
	R_ARRIVED=
	R_RETR=
	R_LOSS=
	R_DEV_IP_ERR=0
	R_DEV_IP_DROP=0
	R_HOST_IP_ERR=0
	R_HOST_IP_DROP=0
	R_DEV_BAD=0
	R_HOST_BAD=0

	ssh_dev "ethtool -S $dev_if 2>/dev/null" \
		>"$armdir/$proto.ethtool.dev.before" 2>/dev/null || :
	ssh_dev "ip -s link show $dev_if 2>/dev/null" \
		>"$armdir/$proto.ip.dev.before" 2>/dev/null || :
	ethtool -S "$host_if" \
		>"$armdir/$proto.ethtool.host.before" 2>/dev/null || :
	ip -s link show "$host_if" \
		>"$armdir/$proto.ip.host.before" 2>/dev/null || :

	iperf3 -s -1 -B "$host_ip" -p "$IPERF_PORT" \
		>"$armdir/$proto.server.log" 2>&1 &
	SERVER_PID=$!
	sleep "$WARMUP"
	if ! kill -0 "$SERVER_PID" 2>/dev/null; then
		R_ERR="iperf3 server failed: $(sed -n '1p' "$armdir/$proto.server.log" 2>/dev/null)"
		SERVER_PID=
		return 1
	fi

	args="-c $host_ip -B $dev_ip -p $IPERF_PORT -t $DURATION -P $PARALLEL"
	[ "$DEV_IPERF_CONNECT_TIMEOUT" = "1" ] && args="$args --connect-timeout 5"
	[ "$direction" = "host-to-device" ] && args="$args -R"
	if [ "$proto" = "udp" ]; then
		per_stream=$(awk -v r="$UDP_RATE" -v p="$PARALLEL" \
			'BEGIN { printf "%.3f", r / p }')
		args="$args -u -b ${per_stream}M"
	fi
	args="$args -J"

	timeout_prefix=
	[ "$DEV_HAVE_TIMEOUT" = "1" ] &&
		timeout_prefix="timeout $((DURATION + 30))"

	REMOTE_PIDFILE="/tmp/2.5g-wired.$RUN_ID.$label.$direction.$proto.pid"
	# shellcheck disable=SC2086,SC2029
	ssh $SSH_OPTS "$DEVICE" \
		"sh -c 'echo \$\$ > $REMOTE_PIDFILE; exec $timeout_prefix iperf3 $args'" \
		>"$armdir/$proto.json" 2>"$armdir/$proto.err" &
	SSH_PID=$!
	wait "$SSH_PID"
	status=$?
	SSH_PID=
	ssh_dev "rm -f $REMOTE_PIDFILE" >/dev/null 2>&1 || :
	REMOTE_PIDFILE=

	sleep "$TAIL"

	if [ -n "${SERVER_PID:-}" ]; then
		kill -TERM "$SERVER_PID" 2>/dev/null || :
		wait "$SERVER_PID" 2>/dev/null || :
		SERVER_PID=
	fi

	ssh_dev "ethtool -S $dev_if 2>/dev/null" \
		>"$armdir/$proto.ethtool.dev.after" 2>/dev/null || :
	ssh_dev "ip -s link show $dev_if 2>/dev/null" \
		>"$armdir/$proto.ip.dev.after" 2>/dev/null || :
	ethtool -S "$host_if" \
		>"$armdir/$proto.ethtool.host.after" 2>/dev/null || :
	ip -s link show "$host_if" \
		>"$armdir/$proto.ip.host.after" 2>/dev/null || :

	b_rxe=0 b_rxd=0 b_txe=0 b_txd=0
	stats=$(ipp_stats "$armdir/$proto.ip.dev.before")
	read -r b_rxe b_rxd b_txe b_txd <<EOF
$stats
EOF
	a_rxe=0 a_rxd=0 a_txe=0 a_txd=0
	stats=$(ipp_stats "$armdir/$proto.ip.dev.after")
	read -r a_rxe a_rxd a_txe a_txd <<EOF
$stats
EOF
	R_DEV_IP_ERR=$(( $(delta "$b_rxe" "$a_rxe") + \
		$(delta "$b_txe" "$a_txe") ))
	R_DEV_IP_DROP=$(( $(delta "$b_rxd" "$a_rxd") + \
		$(delta "$b_txd" "$a_txd") ))

	b_rxe=0 b_rxd=0 b_txe=0 b_txd=0
	stats=$(ipp_stats "$armdir/$proto.ip.host.before")
	read -r b_rxe b_rxd b_txe b_txd <<EOF
$stats
EOF
	a_rxe=0 a_rxd=0 a_txe=0 a_txd=0
	stats=$(ipp_stats "$armdir/$proto.ip.host.after")
	read -r a_rxe a_rxd a_txe a_txd <<EOF
$stats
EOF
	R_HOST_IP_ERR=$(( $(delta "$b_rxe" "$a_rxe") + \
		$(delta "$b_txe" "$a_txe") ))
	R_HOST_IP_DROP=$(( $(delta "$b_rxd" "$a_rxd") + \
		$(delta "$b_txd" "$a_txd") ))

	b_dev_bad=$(ethtool_bad "$armdir/$proto.ethtool.dev.before")
	a_dev_bad=$(ethtool_bad "$armdir/$proto.ethtool.dev.after")
	R_DEV_BAD=$(delta "$b_dev_bad" "$a_dev_bad")
	b_host_bad=$(ethtool_bad "$armdir/$proto.ethtool.host.before")
	a_host_bad=$(ethtool_bad "$armdir/$proto.ethtool.host.after")
	R_HOST_BAD=$(delta "$b_host_bad" "$a_host_bad")

	if [ "$status" -ne 0 ]; then
		R_ERR=$(iperf_error "$armdir/$proto.json")
		[ -n "$R_ERR" ] || R_ERR="iperf3 client exited $status"
		return 1
	fi
	if [ ! -s "$armdir/$proto.json" ]; then
		R_ERR="no iperf3 JSON"
		return 1
	fi

	sbps=null sbytes=null sret=null rbps=null rbytes=null rlost=null
	summary=$(iperf_summary "$armdir/$proto.json")
	read -r sbps sbytes sret rbps rbytes rlost <<EOF
$summary
EOF

	R_ERR=$(iperf_error "$armdir/$proto.json")
	[ -z "$R_ERR" ] || return 1

	R_OFFERED=$(gbps "$sbps")
	R_ARRIVED=$(gbps "$rbps")
	if [ -z "$R_OFFERED" ] || [ -z "$R_ARRIVED" ]; then
		R_ERR="no usable iperf3 sum_sent/sum_received"
		return 1
	fi
	case $sret in
	''|null) ;;
	*) R_RETR=$sret ;;
	esac
	if [ "$proto" = "udp" ]; then
		case $rlost in
		''|null)
			R_LOSS=$(loss_percent "$sbytes" "$rbytes")
			;;
		*) R_LOSS=$(awk -v l="$rlost" 'BEGIN { printf "%.2f", l }') ;;
		esac
	fi
	return 0
}

report_arm() {
	# report_arm LABEL DIR_LABEL DEV_SPEED HOST_SPEED
	local label="$1" dir_label="$2" dev_speed="$3" host_speed="$4" line

	line="arm $label $dir_label: link=$dev_speed/${host_speed}Mb/s"
	if [ "$ARM_TCP_RAN" = "1" ]; then
		if [ "$ARM_TCP_OK" = "1" ]; then
			line="$line tcp=$ARM_TCP_OFFERED/${ARM_TCP_ARRIVED}Gbit/s"
			[ -n "$ARM_TCP_RETR" ] && line="$line retr=$ARM_TCP_RETR"
		else
			line="$line tcp=FAILED"
		fi
	fi
	if [ "$ARM_UDP_RAN" = "1" ]; then
		if [ "$ARM_UDP_OK" = "1" ]; then
			line="$line udp=$ARM_UDP_OFFERED/${ARM_UDP_ARRIVED}Gbit/s"
			[ -n "$ARM_UDP_LOSS" ] && line="$line loss=$ARM_UDP_LOSS%"
		else
			line="$line udp=FAILED"
		fi
	fi
	line="$line dev_ip_errors=$ARM_DEV_IP_ERR dev_ip_drops=$ARM_DEV_IP_DROP"
	line="$line host_ip_errors=$ARM_HOST_IP_ERR host_ip_drops=$ARM_HOST_IP_DROP"
	line="$line dev_ethtool_bad=$ARM_DEV_BAD host_ethtool_bad=$ARM_HOST_BAD"
	printf '%s\n' "$line"
}

run_arm() {
	# run_arm LABEL DIRECTION DEV_IF HOST_IF DEV_IP HOST_IP DEV_SPEED HOST_SPEED
	local label="$1" direction="$2" dev_if="$3" host_if="$4"
	local dev_ip="$5" host_ip="$6" dev_speed="$7" host_speed="$8"
	local dir_label proto armdir

	case $direction in
	host-to-device) dir_label='host->device' ;;
	device-to-host) dir_label='device->host' ;;
	esac

	armdir="$OUT_DIR/$label/$direction"
	mkdir -p "$armdir" || die "cannot create $armdir"

	ARM_TCP_RAN=0
	ARM_TCP_OK=0
	ARM_TCP_OFFERED=
	ARM_TCP_ARRIVED=
	ARM_TCP_RETR=
	ARM_UDP_RAN=0
	ARM_UDP_OK=0
	ARM_UDP_OFFERED=
	ARM_UDP_ARRIVED=
	ARM_UDP_LOSS=
	ARM_DEV_IP_ERR=0
	ARM_DEV_IP_DROP=0
	ARM_HOST_IP_ERR=0
	ARM_HOST_IP_DROP=0
	ARM_DEV_BAD=0
	ARM_HOST_BAD=0

	for proto in $PROTO_LIST; do
		case $proto in
		tcp) ARM_TCP_RAN=1 ;;
		udp) ARM_UDP_RAN=1 ;;
		esac
		if run_one "$armdir" "$proto" "$direction" "$label" \
			"$dev_if" "$host_if" "$dev_ip" "$host_ip"; then
			case $proto in
			tcp)
				ARM_TCP_OK=1
				ARM_TCP_OFFERED=$R_OFFERED
				ARM_TCP_ARRIVED=$R_ARRIVED
				ARM_TCP_RETR=$R_RETR
				;;
			udp)
				ARM_UDP_OK=1
				ARM_UDP_OFFERED=$R_OFFERED
				ARM_UDP_ARRIVED=$R_ARRIVED
				ARM_UDP_LOSS=$R_LOSS
				;;
			esac
		else
			note "arm $label $dir_label $proto failed: $R_ERR"
		fi
		ARM_DEV_IP_ERR=$((ARM_DEV_IP_ERR + R_DEV_IP_ERR))
		ARM_DEV_IP_DROP=$((ARM_DEV_IP_DROP + R_DEV_IP_DROP))
		ARM_HOST_IP_ERR=$((ARM_HOST_IP_ERR + R_HOST_IP_ERR))
		ARM_HOST_IP_DROP=$((ARM_HOST_IP_DROP + R_HOST_IP_DROP))
		ARM_DEV_BAD=$((ARM_DEV_BAD + R_DEV_BAD))
		ARM_HOST_BAD=$((ARM_HOST_BAD + R_HOST_BAD))
	done

	report_arm "$label" "$dir_label" "$dev_speed" "$host_speed"

	ARMS_TOTAL=$((ARMS_TOTAL + 1))
	if [ "$ARM_TCP_RAN" = "1" ] && [ "$ARM_TCP_OK" != "1" ]; then
		ARMS_FAILED=$((ARMS_FAILED + 1))
		return 1
	fi
	if [ "$ARM_UDP_RAN" = "1" ] && [ "$ARM_UDP_OK" != "1" ]; then
		ARMS_FAILED=$((ARMS_FAILED + 1))
		return 1
	fi
	ARMS_OK=$((ARMS_OK + 1))
	return 0
}

run_port() {
	# run_port LABEL DEV_IF HOST_IF DEV_IP HOST_IP DEV_SPEED HOST_SPEED
	local label="$1" dev_if="$2" host_if="$3" dev_ip="$4" host_ip="$5"
	local dev_speed="$6" host_speed="$7" after_dev after_host

	note "port $label: $dev_if <-> $host_if, device=$dev_speed Mb/s host=$host_speed Mb/s"
	setup_pair "$label" "$dev_if" "$host_if" "$dev_ip" "$host_ip"

	run_arm "$label" host-to-device "$dev_if" "$host_if" \
		"$dev_ip" "$host_ip" "$dev_speed" "$host_speed"
	run_arm "$label" device-to-host "$dev_if" "$host_if" \
		"$dev_ip" "$host_ip" "$dev_speed" "$host_speed"

	after_dev=$(dev_speed "$dev_if")
	after_host=$(link_speed "$host_if")
	if [ "$after_dev" != "$dev_speed" ] || [ "$after_host" != "$host_speed" ]; then
		note "port $label link changed during the run: device=${after_dev:-unknown} host=${after_host:-unknown} Mb/s"
	fi

	cleanup_pair "$label"
}

print_header() {
	local label dev_if host_if host_driver dev_speed host_speed

	printf '== 2.5G bidirectional wired test ==\n'
	printf 'device: %s (SSH management, never a data port)\n' "$DEVICE"
	printf 'topology: host 2.5G NIC <-> lan10g; host 2.5G NIC <-> wan10g; no lan10g<->wan10g cable\n'
	printf 'safety: temporary /32 addresses/routes only; no bridge, firewall or UCI change\n'
	for label in $SEL_PORTS; do
		case $label in
		lan10g)
			dev_if=$DEV_LAN_IF
			host_if=$HOST_LAN_IF
			host_driver=$HOST_LAN_DRIVER
			dev_speed=$DEV_LAN_SPEED
			host_speed=$HOST_LAN_SPEED
			;;
		wan10g)
			dev_if=$DEV_WAN_IF
			host_if=$HOST_WAN_IF
			host_driver=$HOST_WAN_DRIVER
			dev_speed=$DEV_WAN_SPEED
			host_speed=$HOST_WAN_SPEED
			;;
		esac
		printf '%s: dev_iface=%s host_iface=%s dev_link=%sMb/s host_link=%sMb/s dev_duplex=%s dev_driver=%s host_driver=%s\n' \
			"$label" "$dev_if" "$host_if" "$dev_speed" \
			"$host_speed" "$(dev_link_field "$label" duplex)" \
			"$(dev_link_field "$label" driver)" "$host_driver"
	done
	printf 'protocols: %s; duration=%ss parallel=%s udp_rate=%sM\n' \
		"$PROTO" "$DURATION" "$PARALLEL" "$UDP_RATE"
}

dry_run() {
	local label host_if speed driver dev_if dev_ip host_ip plan_proto

	case $PROTO in
	both) plan_proto="tcp,udp" ;;
	*) plan_proto=$PROTO ;;
	esac

	check_link_tools dry-run
	check_traffic_tools dry-run
	HOST_MGMT_IF=$(route_dev "$DEVICE_IP")
	HOST_DEFAULT_IF=$(default_route_dev)

	printf 'DRY-RUN: 2.5G bidirectional wired test plan\n'
	printf 'device: %s (SSH checked at run time; the port must be >= 2500Mb/s)\n' \
		"$DEVICE"
	printf 'safety: no SSH, no traffic, no address/route change, no directory created\n'
	if [ "$DETACH_PORT" -eq 1 ]; then
		printf 'detach: --detach-port is planned, not run; its two "ip link set" lines are printed below\n'
	fi
	printf 'topology: host 2.5G NIC <-> LAN 2.5G port; host 2.5G NIC <-> WAN 2.5G port; SSH on lan3/management; no port<->port cable\n'
	printf 'skip: a real run prints exactly "SKIP: no 2.5G link" and exits 3 unless both ends are >= 2500Mb/s\n'
	printf 'blocked: BLOCKED: no device port advertises 2500baseT, or BLOCKED: <port> is in br-lan\n'
	printf 'blocked: both mean nothing was measured and nothing failed; config-block exits 2, any other precondition exits 4\n'
	printf 'unreachable: BLOCKED: cannot reach <host> (<ssh error>) exits 2 (environment); port detection had no evidence\n'
	printf 'protocols: %s; duration=%ss parallel=%s udp_rate=%sM iperf_port=%s\n' \
		"$PROTO" "$DURATION" "$PARALLEL" "$UDP_RATE" "$IPERF_PORT"

	for label in $SEL_PORTS; do
		host_if=$(label_host_if "$label")
		if [ -z "$host_if" ]; then
			host_if=$(host_2_5g_candidates "$HOST_MGMT_IF" \
				"$HOST_DEFAULT_IF" "" | sed -n '1p')
		fi
		if [ -n "$host_if" ]; then
			speed=$(link_speed "$host_if")
			driver=$(iface_driver "$host_if")
			host_if="$host_if (link=${speed:-unknown}Mb/s driver=${driver:-unknown})"
		else
			host_if="<auto: pass --host-${label}-if>"
		fi
		case $label in
		lan10g) dev_if=$DEV_LAN_IF; dev_ip=$LAN_DEV_IP; host_ip=$LAN_HOST_IP ;;
		wan10g) dev_if=$DEV_WAN_IF; dev_ip=$WAN_DEV_IP; host_ip=$WAN_HOST_IP ;;
		esac
		[ -n "$dev_if" ] ||
			dev_if="<auto: first physical port advertising 2500baseT, lan2 first>"
		printf 'port %s: dev_iface=%s dev_ip=%s host_ip=%s host_iface=%s\n' \
			"$label" "$dev_if" "$dev_ip" "$host_ip" "$host_if"
	done

	for label in $SEL_PORTS; do
		case $label in
		lan10g) dev_ip=$LAN_DEV_IP; host_ip=$LAN_HOST_IP ;;
		wan10g) dev_ip=$WAN_DEV_IP; host_ip=$WAN_HOST_IP ;;
		esac
		printf 'arm %s host->device: proto=%s iperf3=-R dev_ip=%s host_ip=%s\n' \
			"$label" "$plan_proto" "$dev_ip" "$host_ip"
		printf 'arm %s device->host: proto=%s iperf3=normal dev_ip=%s host_ip=%s\n' \
			"$label" "$plan_proto" "$dev_ip" "$host_ip"
	done

	printf 'commands (per selected port, run time):\n'
	printf '  ssh ... "ethtool DEV_IF"          # require Speed: >= 2500Mb/s\n'
	if [ "$DETACH_PORT" -eq 1 ]; then
		# Printed, not run: --dry-run does no SSH, so the recorded master is
		# whichever one the device reports; the two lines are the whole
		# device-state change this flag makes.
		for label in $SEL_PORTS; do
			dev_if=$(label_dev_if "$label")
			[ -n "$dev_if" ] || dev_if=DEV_IF
			printf '  ssh ... "ip link set %s nomaster"        # only for its arms\n' \
				"$dev_if"
			printf '  ssh ... "ip link set %s master ORIG_MASTER"   # restore, from the EXIT trap\n' \
				"$dev_if"
		done
		printf '  # ORIG_MASTER is read from %s/class/net/DEV_IF/master before the detach\n' \
			"$DEV_SYSFS"
	fi
	printf '  ip addr add HOST_IP/32 dev HOST_IF\n'
	printf '  ip route add DEV_IP/32 dev HOST_IF\n'
	printf '  ssh ... "ip addr add DEV_IP/32 dev DEV_IF"\n'
	printf '  ssh ... "ip route add HOST_IP/32 dev DEV_IF"\n'
	printf '  iperf3 -s -1 -B HOST_IP -p %s &\n' "$IPERF_PORT"
	printf '  ssh ... "iperf3 -c HOST_IP -B DEV_IP -p %s -t %s -P %s [-R] [-u -b PER_STREAM] -J"\n' \
		"$IPERF_PORT" "$DURATION" "$PARALLEL"
	printf '  ssh ... "ip route del HOST_IP/32; ip addr del DEV_IP/32"\n'
	printf '  ip route del DEV_IP/32; ip addr del HOST_IP/32\n'
	printf 'result: one arm per selected port and direction (four for --ports both), each with link speed, Gbit/s and error/drop deltas\n'
	exit 0
}

parse_args() {
	local key val

	while [ $# -gt 0 ]; do
		case $1 in
		-h|--help)
			usage
			exit 0
			;;
		--dry-run)
			DRY_RUN=1
			shift
			continue
			;;
		--detach-from-bridge)
			DETACH_FROM_BRIDGE=1
			shift
			continue
			;;
		--detach-port)
			DETACH_PORT=1
			shift
			continue
			;;
		--)
			shift
			break
			;;
		--*=*)
			key=${1%%=*}
			val=${1#*=}
			shift
			;;
		--*)
			key=$1
			shift
			[ $# -gt 0 ] || usage_error "$key needs a value"
			val=$1
			shift
			;;
		-*)
			usage_error "unknown option: $1"
			;;
		*)
			usage_error "unexpected argument: $1"
			;;
		esac

		case $key in
		--device) DEVICE=$val ;;
		--dev-lan10g-if) DEV_LAN_IF=$val ;;
		--dev-wan10g-if) DEV_WAN_IF=$val ;;
		--ports) PORTS=$val ;;
		--host-lan10g-if) HOST_LAN_IF=$val ;;
		--host-wan10g-if) HOST_WAN_IF=$val ;;
		--proto) PROTO=$val ;;
		--duration) DURATION=$val ;;
		--parallel) PARALLEL=$val ;;
		--udp-rate) UDP_RATE=$val ;;
		--iperf-port) IPERF_PORT=$val ;;
		--warmup) WARMUP=$val ;;
		--tail) TAIL=$val ;;
		--lan10g-dev-ip) LAN_DEV_IP=$val ;;
		--lan10g-host-ip) LAN_HOST_IP=$val ;;
		--wan10g-dev-ip) WAN_DEV_IP=$val ;;
		--wan10g-host-ip) WAN_HOST_IP=$val ;;
		--out-dir) OUT_DIR_OPT=$val ;;
		*)
			case $key in
			--dry-run)
				usage_error "--dry-run takes no value"
				;;
			*)
				usage_error "unknown option: $key"
				;;
			esac
			;;
		esac
	done
	[ $# -eq 0 ] || usage_error "unexpected argument: $1"

	if [ "$DETACH_PORT" -eq 1 ] && [ "$DETACH_FROM_BRIDGE" -eq 1 ]; then
		usage_error "--detach-port and --detach-from-bridge both want the bridge: one acts, one prints"
	fi
	if [ "$DETACH_PORT" -eq 1 ] && ! command -v pd_detach >/dev/null 2>&1; then
		no_port_detach_lib
	fi

	case $PORTS in
	both) SEL_PORTS="lan10g wan10g" ;;
	lan10g|wan10g) SEL_PORTS=$PORTS ;;
	*) usage_error "--ports must be both, lan10g or wan10g" ;;
	esac
	case $PROTO in
	tcp|udp) PROTO_LIST=$PROTO ;;
	both) PROTO_LIST="tcp udp" ;;
	*) usage_error "--proto must be tcp, udp or both" ;;
	esac

	is_uint "$DURATION" || usage_error "--duration must be an integer"
	[ "$DURATION" -ge 1 ] && [ "$DURATION" -le 3600 ] ||
		usage_error "--duration must be 1..3600"
	is_uint "$PARALLEL" || usage_error "--parallel must be an integer"
	[ "$PARALLEL" -ge 1 ] && [ "$PARALLEL" -le 64 ] ||
		usage_error "--parallel must be 1..64"
	is_uint "$UDP_RATE" || usage_error "--udp-rate must be an integer Mbit/s"
	[ "$UDP_RATE" -ge 1 ] || usage_error "--udp-rate must be at least 1"
	is_uint "$IPERF_PORT" || usage_error "--iperf-port must be an integer"
	[ "$IPERF_PORT" -ge 1 ] && [ "$IPERF_PORT" -le 65535 ] ||
		usage_error "--iperf-port must be 1..65535"
	is_uint "$WARMUP" || usage_error "--warmup must be an integer"
	[ "$WARMUP" -le 60 ] || usage_error "--warmup must be 0..60"
	is_uint "$TAIL" || usage_error "--tail must be an integer"
	[ "$TAIL" -le 60 ] || usage_error "--tail must be 0..60"

	# An empty --dev-* is legal: the port is auto-detected on the device.
	if [ -n "$DEV_LAN_IF" ]; then
		is_ifname "$DEV_LAN_IF" ||
			usage_error "--dev-lan10g-if must be an interface name"
	fi
	if [ -n "$DEV_WAN_IF" ]; then
		is_ifname "$DEV_WAN_IF" ||
			usage_error "--dev-wan10g-if must be an interface name"
	fi
	if [ -n "$DEV_LAN_IF" ] && [ -n "$DEV_WAN_IF" ]; then
		[ "$DEV_LAN_IF" != "$DEV_WAN_IF" ] ||
			usage_error "device lan10g and wan10g must be different interfaces"
	fi
	case ${DEV_LAN_IF:-}:${DEV_WAN_IF:-} in
	lan3:*|*:lan3|br-lan:*|*:br-lan)
		usage_error "lan3/br-lan is management and cannot be a data port"
		;;
	esac
	if [ -n "$HOST_LAN_IF" ]; then
		is_ifname "$HOST_LAN_IF" ||
			usage_error "--host-lan10g-if must be an interface name"
	fi
	if [ -n "$HOST_WAN_IF" ]; then
		is_ifname "$HOST_WAN_IF" ||
			usage_error "--host-wan10g-if must be an interface name"
	fi
	if [ -n "$HOST_LAN_IF" ] && [ -n "$HOST_WAN_IF" ] &&
	   [ "$HOST_LAN_IF" = "$HOST_WAN_IF" ]; then
		usage_error "--host-lan10g-if and --host-wan10g-if must differ"
	fi

	case $DEVICE in
	*@*) DEVICE_IP=${DEVICE#*@} ;;
	*) usage_error "--device must be USER@IPv4" ;;
	esac
	is_ipv4 "$DEVICE_IP" ||
		usage_error "--device must be USER@IPv4 (IPv4 only; got '$DEVICE_IP')"

	is_ipv4 "$LAN_DEV_IP" || usage_error "--lan10g-dev-ip must be IPv4"
	is_ipv4 "$LAN_HOST_IP" || usage_error "--lan10g-host-ip must be IPv4"
	is_ipv4 "$WAN_DEV_IP" || usage_error "--wan10g-dev-ip must be IPv4"
	is_ipv4 "$WAN_HOST_IP" || usage_error "--wan10g-host-ip must be IPv4"
	[ "$LAN_DEV_IP" != "$LAN_HOST_IP" ] ||
		usage_error "lan10g device/host addresses must differ"
	[ "$WAN_DEV_IP" != "$WAN_HOST_IP" ] ||
		usage_error "wan10g device/host addresses must differ"
	[ "$LAN_DEV_IP" != "$WAN_DEV_IP" ] &&
	[ "$LAN_DEV_IP" != "$WAN_HOST_IP" ] &&
	[ "$LAN_HOST_IP" != "$WAN_DEV_IP" ] &&
	[ "$LAN_HOST_IP" != "$WAN_HOST_IP" ] ||
		usage_error "lan10g and wan10g temporary addresses must all differ"
}

main() {
	local label dev_if host_if dev_ip host_ip dev_speed host_speed

	parse_args "$@"

	[ "$DRY_RUN" -eq 1 ] && dry_run

	# Check order matters here: the link tools have to be present before
	# anything can be read, the device port is resolved before the host NICs
	# ("no 2.5G data port on the device" is a precondition no host NIC can
	# fix), and the traffic tools are demanded only after the link verdict so
	# an absent 2.5G NIC still prints "SKIP: no 2.5G link" on a host without
	# iperf3 (issue #70).  A bridged device port is reported, not fatal.
	check_link_tools run
	resolve_device_ports
	[ "$DETACH_FROM_BRIDGE" -eq 1 ] && detach_plan

	[ "$(id -u 2>/dev/null || printf '1')" = "0" ] ||
		die "run as root on the bench host: temporary ip addr/route need CAP_NET_ADMIN"

	check_traffic_tools run
	check_device
	resolve_host_nics

	if [ -n "$OUT_DIR_OPT" ]; then
		OUT_DIR=$OUT_DIR_OPT
	else
		OUT_DIR=/tmp/2.5g-wired.$(date +%Y%m%d-%H%M%S)
	fi
	mkdir -p "$OUT_DIR" || die "cannot create $OUT_DIR"
	RUN_ID=$(date +%s)-$$

	# EXIT runs cleanup_all, which restores the bridge; the detach itself
	# only ever happens below, i.e. after these two traps exist.  INT/TERM/HUP
	# turn into exit 130, which fires the same EXIT trap.
	trap 'on_exit' EXIT
	trap 'exit 130' INT TERM HUP

	printf '%s\n' "$PROG: device=$DEVICE ports=$PORTS proto=$PROTO" \
		>"$OUT_DIR/cmdline.txt"

	print_header

	for label in $SEL_PORTS; do
		case $label in
		lan10g)
			dev_if=$DEV_LAN_IF
			host_if=$HOST_LAN_IF
			dev_ip=$LAN_DEV_IP
			host_ip=$LAN_HOST_IP
			dev_speed=$DEV_LAN_SPEED
			host_speed=$HOST_LAN_SPEED
			;;
		wan10g)
			dev_if=$DEV_WAN_IF
			host_if=$HOST_WAN_IF
			dev_ip=$WAN_DEV_IP
			host_ip=$WAN_HOST_IP
			dev_speed=$DEV_WAN_SPEED
			host_speed=$HOST_WAN_SPEED
			;;
		esac
		detach_pending_port "$label"
		run_port "$label" "$dev_if" "$host_if" "$dev_ip" "$host_ip" \
			"$dev_speed" "$host_speed"
		if ! pd_restore; then
			# Do not measure on the other port while this one is out of its
			# bridge: stop here and let the EXIT trap report the status.
			BRIDGE_RESTORE_FAILED=1
			printf 'status: blocked\n'
			exit 1
		fi
	done

	cleanup_all

	printf 'result: arms=%s ok=%s failed=%s artifacts=%s\n' \
		"$ARMS_TOTAL" "$ARMS_OK" "$ARMS_FAILED" "$OUT_DIR"
	if [ "$ARMS_FAILED" -eq 0 ]; then
		printf 'status: ok\n'
		exit 0
	fi
	printf 'status: failed\n'
	exit 1
}

# Sourced by scripts/tests/test_2g5_speed_gate.py to exercise the speed gate
# (require_2g5_speed) without a NIC, a device or traffic.
[ "${G25_WIRED_LIB_ONLY:-0}" = 1 ] && return 0

main "$@"
