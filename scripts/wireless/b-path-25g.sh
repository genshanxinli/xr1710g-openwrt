#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# shellcheck disable=SC3043
#
# b-path-25g.sh - B-path (2.5G wired feeder -> Wi-Fi) harness.
#
# Runs on the bench host that owns the 2.5G USB feeder and reaches the AP
# over a management link (lan3 by convention).  The data port, lan10g, is
# used only for one temporary /32 address and one /32 route per side; both
# are removed by the EXIT trap.  The script never touches the firewall, UCI,
# a module or a firmware image, and the bridge only with --detach-port: that
# flag takes the data port out of whatever bridge holds it for that port's
# arms and puts it back from the EXIT trap (lib/port-detach.sh).  Without it
# the script behaves exactly as before and does not look at the bridge at all.
#
# Topology this harness assumes:
#
#   bench host 2.5G USB NIC  ------------  XR1710G lan10g (RTL8261BE, 2.5G)
#   bench host management NIC -----------  XR1710G lan3  (SSH only)
#   XR1710G phy0.x-ap0  ~~~~~ Wi-Fi ~~~~  STA (iperf3 -s -p PORT)
#
# Two sequential arms, never concurrent:
#
#   1. feeder: host iperf3 server  <-- reverse iperf3 client on the AP
#      Data flows host -> AP over lan10g, so the arm measures the 2.5G
#      ingress.  The AP opens the TCP/UDP connection, which keeps the
#      unbridged lab port usable without an input firewall rule.
#
#   2. sta:    AP iperf3 client -> iperf3 server on the Wi-Fi STA
#      Data flows AP -> STA over Wi-Fi.  This is the arm that carries the
#      1.5-2G NPU-wall question, so token_info, hw-queues, AP tx bytes and
#      the per-station tx/retry counters are sampled while it runs.
#
# Both arms report offered (sender) and arrived (receiver) from the iperf3
# JSON, plus the AP/lan10g counter deltas over the same window.
#
# The 2.5G USB feeder is not assumed to be present.  A missing or 1G local
# feeder NIC, or a missing/1G lan10g link, is a clean skip:
#
#   SKIP: no 2.5G feeder

set -u

PROG=b-path-25g

SSH_OPTS=${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3}

DEVICE=${DEVICE:-root@192.168.1.1}
DEV_IFACE=lan10g
FEEDER_IFACE_OPT=${FEEDER_IFACE:-}
CLIENT_ARG=
CLIENT_IP_OPT=
CLIENT_MAC_OPT=
AP_IFACE_OPT=
DURATION=20
PARALLEL=4
PROTO=tcp
RATE=2500
PORT=5201
WARMUP=2
TAIL=2
SAMPLER_INTERVAL=1
DEV_IP=10.99.0.1
FEEDER_IP=10.99.0.2
OUT_DIR_OPT=
DRY_RUN=0
RUN_EXPLICIT=0
# 1 = detach the data port from its bridge for the arms and restore it on
# exit (lib/port-detach.sh).  Off by default: this harness never used to
# look at the bridge, and a bridged lan10g is a configuration problem the
# operator may prefer to fix himself.
DETACH_PORT=0
DETACH_PENDING=
BRIDGE_RESTORE_FAILED=0

# Set by the checks below; initialised so `set -u` reports a real bug
# instead of every unset field.  FEEDER_IFACE_OPT keeps an env override.
FEEDER_IFACE=
FEEDER_SPEED=
FEEDER_DRIVER=
DEV_SPEED=
DEV_DUPLEX=
DEV_DRIVER=
CLIENT_IP=
CLIENT_MAC=
AP_IFACE=
TOKEN_PATH=
HWQ_PATH=
ARM_STATUS=0

usage() {
	cat <<'EOF'
Usage: b-path-25g.sh --client ADDR [options]

Run the B-path measurement on the bench host: a 2.5G wired feeder into the
AP's lan10g port, then AP -> STA traffic over Wi-Fi.  The AP must be
reachable over SSH for sampling and for the AP-side iperf3 client.

Required for a real run:
  --client ADDR           associated STA IPv4 address or MAC.  The STA must
                          run an iperf3 server (`iperf3 -s -p PORT`); the AP
                          is the client in arm 2.

Device and link selection:
  --device USER@IPV4      SSH target of the AP (default: root@192.168.1.1,
                          env DEVICE).  Keep this on lan3 / management.
  --device-iface NAME     data port under test (default: lan10g).  lan3,
                          wan and br-lan are refused: they are management or
                          the production bridge.
  --feeder-iface NAME     local 2.5G feeder NIC (default: auto-detect,
                          env FEEDER_IFACE).  Auto-detection ignores the
                          management and default-route interfaces.
  --detach-port           take the data port out of whichever bridge holds
                          it for the two arms and put it back on exit.  The
                          master is read from sysfs, not assumed to be
                          br-lan; the detach and the restore are the only
                          bridge changes this script can make, and a restore
                          that cannot be verified exits 1.  Refused when the
                          SSH session is the port being detached.  Without
                          this flag the bridge is not touched or probed.

Measurement options:
  --client-ip ADDR        explicit STA IPv4 when --client is a MAC
  --client-mac MAC        explicit STA MAC when --client is an IPv4
  --ap-iface NAME         AP netdev (default: the one with the client)
  --duration SEC          seconds per arm (default 20)
  --parallel N            iperf3 streams per arm (default 4)
  --proto tcp|udp         transport (default tcp)
  --rate MBPS             aggregate UDP offered rate (default 2500;
                          divided over --parallel, because iperf3 -b is
                          per stream)
  --port N                iperf3 control/data port (default 5201)
  --warmup SEC            settle time before an arm (default 2)
  --tail SEC              sample time after an arm (default 2)
  --interval SEC          sampler period during an arm (default 1)

Temporary addressing (both sides, removed by the EXIT trap):
  --device-ip IP          AP lan10g /32 (default 10.99.0.1)
  --feeder-ip IP          bench feeder /32 (default 10.99.0.2)

Output and safety:
  --out-dir DIR           artifact directory (default
                          /tmp/b-path-25g.YYYYmmdd-HHMMSS)
  --run                   run the measurement (this is the default)
  --dry-run               print the plan and commands, then exit 0.  No SSH,
                          no iperf3, no address or route change, no
                          directory creation.  Missing local prerequisites
                          are reported as SKIP.
  -h, --help              this text

Skip and failure:
  A missing or non-2500 feeder NIC, a missing or non-2500 lan10g link, or
  an absent link exits 0 with exactly `SKIP: no 2.5G feeder`.  Missing ssh,
  iperf3, ethtool, ip or awk is a hard error, not a skip.

What is sampled while each arm runs:
  - AP per-station tx bytes/retries/failed and the AP netdev tx_bytes,
  - /sys/kernel/debug/ieee80211/phy*/mt76/token_info (token pool, NPU RX
    and per-band TX queues),
  - /sys/kernel/debug/ieee80211/phy*/mt76/hw-queues (PLE pages, HIF
    used/reserved),
  - ethtool -S and ip -s link counters on lan10g.

Output fields: link speed, offered, arrived, token count and queue depth
appear on stdout; raw samples and iperf3 JSON stay in --out-dir.  The last
line is a one-line NPU-wall verdict.

Limits:
  - token_info exposes the SW token pool and NPU queue depth, not the
    firmware's 13312 tx-token counter.  The verdict therefore separates
    "queue/token pool exhausted" from "1.5-2G band reached with headroom";
    it does not claim a token cause that the file does not expose.
  - The two arms are sequential, not an end-to-end forwarded flow: lan10g
    is deliberately left out of br-lan, so forwarding across it would need
    a bridge/firewall change that this harness forbids.
  - token_info/hw-queues/AP counters are snapshotted once per --interval
    (default 1 s); a sub-second queue peak can be missed.  Lower
    --interval if that matters.

Examples:
  # Preview only.  No SSH and no traffic.
  ./scripts/wireless/b-path-25g.sh --client 192.168.1.50 \
      --feeder-iface enp9s0 --dry-run

  # TCP run; SSH stays on lan3 / management.
  sudo ./scripts/wireless/b-path-25g.sh --device root@192.168.234.145 \
      --client 192.168.1.50 --feeder-iface enp9s0 --run

  # UDP run at a 2.5 Gbit/s aggregate offered rate.
  sudo ./scripts/wireless/b-path-25g.sh --device root@192.168.234.145 \
      --client 192.168.1.50 --feeder-iface enp9s0 \
      --proto udp --rate 2500 --run
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
# a harness must still skip, and still exit 0, when the record cannot be
# written.
NO_CLIENT_LIB=$(dirname "$0")/lib/no-client.sh
# shellcheck source=lib/no-client.sh
[ -r "$NO_CLIENT_LIB" ] && . "$NO_CLIENT_LIB"

# Opt-in bridge detach/restore (scripts/wireless/lib/port-detach.sh).  Every
# read and write goes through ssh_dev, so the library edits the AP, not the
# bench host; the netns test points PD_EXEC at a local runner instead.
PORT_DETACH_LIB=$(dirname "$0")/lib/port-detach.sh
if [ -r "$PORT_DETACH_LIB" ]; then
	# Read by the library, not here: same file, different call site.
	# shellcheck disable=SC2034
	PD_EXEC=ssh_dev
	# shellcheck disable=SC2034
	PD_SYSFS=/sys
	# shellcheck source=lib/port-detach.sh
	. "$PORT_DETACH_LIB"
else
	no_port_detach_lib() {
		die "shared library not found: $PORT_DETACH_LIB (needed by --detach-port)"
	}
fi

# The one command that measures the B path once the 2.5G feeder exists.
NC_2G5_RUN='sudo sh scripts/wireless/b-path-25g.sh --device <USER@DEVICE_IP> --client <STA_IP> --feeder-iface <HOST_FEEDER_IF> --run'

skip_no_feeder() {
	# Keep this line exact: callers and the issue acceptance grep it.  The
	# record and the two hints go to stderr so stdout stays the single SKIP
	# line (scripts/tests/test_2g5_preflight_order.py asserts it exactly).
	printf 'SKIP: no 2.5G feeder\n'
	# Same missing hardware and the same "2.5g-peer" key as 2.5g-wired.sh, so
	# hw-gap-report.sh merges both harnesses into one row for issue #70.
	_rec=$(no_client_record "${OUT_DIR_OPT:-}" 70 2.5g-peer "$NC_2G5_RUN" \
		'no 2.5G feeder' \
		"feeder NIC reports 2500 Mb/s and the AP data port reports 2500baseT/Full" \
		"feeder arm arrived >= 2.2 Gbit/s over 20 s at --parallel 4" \
		"token_info peak stays below the pool and hw-queues PLE pages do not pin" \
		"ppe/usage bound entries grow across the arm (the 2.5G ingress is offloaded)" 2>/dev/null)
	if [ -n "$_rec" ]; then
		note "missing 2.5g-peer #70; once it is available run: $NC_2G5_RUN"
		note "no-client record: $_rec"
	fi
	exit 0
}

missing_tool() {
	# missing_tool NAME DETAIL: iperf3 has to exist on both ends (the feeder
	# host acts as server for one arm and client for the other) and there is no
	# source slot here.  Record the gap and exit 2: a recorded prerequisite,
	# not a failed run (1) and not a clean skip (0).
	_rec=$(no_client_record "${OUT_DIR_OPT:-}" 70 "$1" "$NC_2G5_RUN" "$2" \
		"feeder NIC reports 2500 Mb/s and the AP data port reports 2500baseT/Full" \
		"feeder arm arrived >= 2.2 Gbit/s over 20 s at --parallel 4" \
		"token_info peak stays below the pool and hw-queues PLE pages do not pin" 2>/dev/null)
	note "missing $1; on the device: opkg install iperf3 (or apk add iperf3)"
	[ -n "$_rec" ] && note "no-client record: $_rec"
	printf 'BLOCKED: missing %s\n' "$1"
	exit 2
}

is_uint() {
	case ${1-} in
	''|*[!0-9]*) return 1 ;;
	*) return 0 ;;
	esac
}

is_mac() {
	printf '%s\n' "${1-}" |
		grep -Eq '^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$'
}

is_ipv4() {
	printf '%s\n' "${1-}" |
		grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

is_ifname() {
	case ${1-} in
	''|*[!a-zA-Z0-9_.:@-]*) return 1 ;;
	*) return 0 ;;
	esac
}

lower() {
	printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]'
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

route_dev() {
	# Interface for one destination, or empty.
	ip route get "$1" 2>/dev/null | awk '
		{
			for (i = 1; i <= NF; i++)
				if ($i == "dev") {
					print $(i + 1)
					exit
				}
		}
	'
}

default_route_dev() {
	ip route show default 2>/dev/null | awk '
		{
			for (i = 1; i <= NF; i++)
				if ($i == "dev") {
					print $(i + 1)
					exit
				}
		}
	'
}

local_tx_bytes() {
	# TX bytes from `ip -s link show`.
	ip -s link show "$1" 2>/dev/null | awk '
		/^[ \t]*TX:/ { tx = 1; next }
		tx && $1 ~ /^[0-9]+$/ { print $1; exit }
	'
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

dev_speed() {
	local out

	out=$(ssh_dev "ethtool $DEV_IFACE 2>/dev/null") || return 1
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
	ssh_dev "ethtool $DEV_IFACE 2>/dev/null" | awk -F: '
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


parse_args() {
	local key val

	while [ $# -gt 0 ]; do
		case $1 in
		-h|--help)
			usage
			exit 0
			;;
		--run)
			RUN_EXPLICIT=1
			shift
			continue
			;;
		--dry-run)
			DRY_RUN=1
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
			if [ $# -lt 2 ]; then
				case $key in
				--device|--device-iface|--feeder-iface|--client)
					usage_error "$key needs a value" ;;
				--client-ip|--client-mac|--ap-iface|--duration)
					usage_error "$key needs a value" ;;
				--parallel|--proto|--rate|--port|--warmup|--tail)
					usage_error "$key needs a value" ;;
				--interval|--device-ip|--feeder-ip|--out-dir)
					usage_error "$key needs a value" ;;
				*)
					usage_error "unknown option: $key" ;;
				esac
			fi
			val=$2
			shift 2
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
		--device-iface) DEV_IFACE=$val ;;
		--feeder-iface) FEEDER_IFACE_OPT=$val ;;
		--client) CLIENT_ARG=$val ;;
		--client-ip) CLIENT_IP_OPT=$val ;;
		--client-mac) CLIENT_MAC_OPT=$val ;;
		--ap-iface) AP_IFACE_OPT=$val ;;
		--duration) DURATION=$val ;;
		--parallel) PARALLEL=$val ;;
		--proto) PROTO=$val ;;
		--rate) RATE=$val ;;
		--port) PORT=$val ;;
		--warmup) WARMUP=$val ;;
		--tail) TAIL=$val ;;
		--interval) SAMPLER_INTERVAL=$val ;;
		--device-ip) DEV_IP=$val ;;
		--feeder-ip) FEEDER_IP=$val ;;
		--out-dir) OUT_DIR_OPT=$val ;;
		*) usage_error "unknown option: $key" ;;
		esac
	done
	[ $# -eq 0 ] || usage_error "unexpected argument: $1"

	if [ "$DRY_RUN" -eq 1 ] && [ "$RUN_EXPLICIT" -eq 1 ]; then
		usage_error "--run and --dry-run are mutually exclusive"
	fi
	if [ "$DETACH_PORT" -eq 1 ] && ! command -v pd_detach >/dev/null 2>&1; then
		no_port_detach_lib
	fi

	is_uint "$DURATION" || usage_error "--duration must be an integer"
	[ "$DURATION" -ge 1 ] && [ "$DURATION" -le 3600 ] ||
		usage_error "--duration must be 1..3600"
	is_uint "$PARALLEL" || usage_error "--parallel must be an integer"
	[ "$PARALLEL" -ge 1 ] && [ "$PARALLEL" -le 32 ] ||
		usage_error "--parallel must be 1..32"
	is_uint "$PORT" || usage_error "--port must be an integer"
	[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] ||
		usage_error "--port must be 1..65535"
	is_uint "$RATE" || usage_error "--rate must be an integer Mbit/s"
	[ "$RATE" -ge 1 ] || usage_error "--rate must be at least 1"
	is_uint "$WARMUP" || usage_error "--warmup must be an integer"
	[ "$WARMUP" -le 60 ] || usage_error "--warmup must be 0..60"
	is_uint "$TAIL" || usage_error "--tail must be an integer"
	[ "$TAIL" -le 60 ] || usage_error "--tail must be 0..60"
	is_uint "$SAMPLER_INTERVAL" || usage_error "--interval must be an integer"
	[ "$SAMPLER_INTERVAL" -ge 1 ] && [ "$SAMPLER_INTERVAL" -le 60 ] ||
		usage_error "--interval must be 1..60"
	case $PROTO in
	tcp|udp) ;;
	*) usage_error "--proto must be tcp or udp" ;;
	esac
	is_ipv4 "$DEV_IP" || usage_error "--device-ip must be IPv4"
	is_ipv4 "$FEEDER_IP" || usage_error "--feeder-ip must be IPv4"
	[ "$DEV_IP" != "$FEEDER_IP" ] ||
		usage_error "--device-ip and --feeder-ip must differ"

	is_ifname "$DEV_IFACE" ||
		usage_error "--device-iface must be an interface name"
	case $DEV_IFACE in
	lan3|wan|wan3|br-lan)
		usage_error "--device-iface $DEV_IFACE is a management/production port"
		;;
	esac
	if [ -n "$FEEDER_IFACE_OPT" ]; then
		is_ifname "$FEEDER_IFACE_OPT" ||
			usage_error "--feeder-iface must be an interface name"
	fi
	if [ -n "$AP_IFACE_OPT" ]; then
		is_ifname "$AP_IFACE_OPT" ||
			usage_error "--ap-iface must be an interface name"
	fi

	DEVICE_IP=${DEVICE#*@}
	if ! is_ipv4 "$DEVICE_IP"; then
		usage_error "--device must be USER@IPv4 (IPv4 only; got '$DEVICE_IP')"
	fi

	if [ -n "$CLIENT_MAC_OPT" ] && ! is_mac "$CLIENT_MAC_OPT"; then
		usage_error "--client-mac must be a MAC address"
	fi
	if [ -n "$CLIENT_IP_OPT" ] && ! is_ipv4 "$CLIENT_IP_OPT"; then
		usage_error "--client-ip must be IPv4"
	fi
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
# move bytes over it.  A bench host without iperf3 must still get the "SKIP: no
# 2.5G feeder" verdict instead of a tool error (issue #70).
check_link_tools() {
	check_tools "$1" ip awk sed grep tr cut
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
	missing_tool iperf3 "iperf3 is missing on the feeder host"
}

resolve_feeder_iface() {
	local candidates c mgmt default

	mgmt=$(route_dev "$DEVICE_IP")
	default=$(default_route_dev)

	if [ -n "$FEEDER_IFACE_OPT" ]; then
		FEEDER_IFACE=$FEEDER_IFACE_OPT
		if ! iface_exists "$FEEDER_IFACE"; then
			note "feeder interface $FEEDER_IFACE is absent"
			skip_no_feeder
		fi
		FEEDER_SPEED=$(link_speed "$FEEDER_IFACE")
		if [ "$FEEDER_SPEED" != "2500" ]; then
			note "feeder interface $FEEDER_IFACE link is '${FEEDER_SPEED:-unknown}' Mb/s, need 2500"
			skip_no_feeder
		fi
		FEEDER_DRIVER=$(iface_driver "$FEEDER_IFACE")
		return 0
	fi

	candidates=
	for c in $(iface_list); do
		case $c in
		lo|Meta|tailscale*|wt*|wg*|tun*|tap*|br-*|docker*|veth*|virbr*)
			continue
			;;
		esac
		[ "$c" = "$mgmt" ] && continue
		[ "$c" = "$default" ] && continue
		[ "$(link_speed "$c")" = "2500" ] || continue
		candidates="$candidates $c"
	done
	# shellcheck disable=SC2086
	set -- $candidates
	if [ "$#" -gt 1 ]; then
		die "multiple 2.5G candidate NICs ($*); pass --feeder-iface"
	fi
	if [ "$#" -eq 1 ]; then
		FEEDER_IFACE=$1
		FEEDER_SPEED=2500
		FEEDER_DRIVER=$(iface_driver "$FEEDER_IFACE")
		return 0
	fi

	# No candidate.  Distinguish "the only 2.5G NIC is management" from
	# "there is no 2.5G NIC", because the first needs a human decision.
	for c in $(iface_list); do
		case $c in
		lo|Meta|tailscale*|wt*|wg*|tun*|tap*|br-*|docker*|veth*|virbr*)
			continue
			;;
		esac
		if { [ "$c" = "$mgmt" ] || [ "$c" = "$default" ]; } &&
		   [ "$(link_speed "$c")" = "2500" ]; then
			die "$c is the only 2.5G NIC but it carries management; pass --feeder-iface"
		fi
	done

	note "no local 2.5G NIC with carrier (management=$mgmt default=$default)"
	skip_no_feeder
}

check_device() {
	# Check SSH and the AP tools before looking at the data link, so a
	# broken management path is an error rather than a misleading skip.
	ssh_dev true >/dev/null 2>&1 ||
		die "cannot SSH to $DEVICE (set --device or SSH_OPTS)"
	[ "$(ssh_dev 'id -u' 2>/dev/null)" = "0" ] ||
		die "$DEVICE does not give root; lan10g setup and debugfs need root"
	dev_have ethtool || die "ethtool is missing on $DEVICE"

	if ! ssh_dev "test -e /sys/class/net/$DEV_IFACE"; then
		note "device interface $DEV_IFACE is absent"
		skip_no_feeder
	fi

	# A bridged data port cannot be a 2.5G feeder port, but this harness has
	# never looked at the bridge and the default must stay that way.  With
	# --detach-port the master is read here and acted on after main() has
	# armed the EXIT trap (see detach_data_port).
	if [ "$DETACH_PORT" -eq 1 ]; then
		_dp_master=$(pd_field master "$(pd_probe "$DEV_IFACE")")
		if [ -n "$_dp_master" ]; then
			_dp_ingress=$(pd_ssh_ingress_port "$_dp_master")
			if [ -n "$_dp_ingress" ] && [ "$_dp_ingress" = "$DEV_IFACE" ]; then
				die "SSH arrives on $DEV_IFACE ($_dp_master fdb says so); detaching it would cut the management path - move the SSH cable to lan3 and retry"
			fi
			[ -n "$_dp_ingress" ] ||
				note "cannot resolve which $_dp_master port carries SSH (no mac in ip neigh, or no bridge tool on the AP); --detach-port was asked for, so detaching anyway - if this session drops, a reboot or 'ifup ${_dp_master#br-}' re-attaches the port"
			DETACH_PENDING=$DEV_IFACE:$_dp_master
			note "$DEV_IFACE is a member of $_dp_master; --detach-port will detach it for the two arms and restore it on exit"
		fi
	fi

	if ! DEV_SPEED=$(dev_speed); then
		die "cannot run ethtool on $DEVICE:$DEV_IFACE"
	fi
	if [ "$DEV_SPEED" != "2500" ]; then
		note "device $DEV_IFACE link is '${DEV_SPEED:-unknown}' Mb/s, need 2500"
		skip_no_feeder
	fi
	DEV_DUPLEX=$(dev_duplex)
	DEV_DRIVER=$(ssh_dev "ethtool -i $DEV_IFACE 2>/dev/null" | awk -F: '
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
	')

	dev_have iperf3 ||
		missing_tool iperf3 "iperf3 is missing on $DEVICE"
	dev_have iw || die "iw is missing on $DEVICE; it is needed for station/AP iface sampling"
	dev_have ping || die "ping is missing on $DEVICE"

	# Refuse to run if the SSH session itself arrives on the data port:
	# adding the /32 there could cut the only management path.
	# The single quotes are deliberate: SSH_CLIENT must expand on the AP.
	# shellcheck disable=SC2016
	SSH_CLIENT_IP=$(ssh_dev 'printf "%s" "${SSH_CLIENT%% *}"' 2>/dev/null)
	if is_ipv4 "$SSH_CLIENT_IP"; then
		SSH_MGMT_DEV=$(ssh_dev "ip route get $SSH_CLIENT_IP 2>/dev/null" | awk '
			{
				for (i = 1; i <= NF; i++)
					if ($i == "dev") {
						print $(i + 1)
						exit
					}
			}
		')
		if [ -n "$SSH_MGMT_DEV" ] && [ "$SSH_MGMT_DEV" = "$DEV_IFACE" ]; then
			die "SSH arrives on $DEV_IFACE; reconnect over lan3/management before touching the data port"
		fi
	fi
}

resolve_client() {
	local ip mac iface block

	if [ -n "$CLIENT_IP_OPT" ]; then
		CLIENT_IP=$CLIENT_IP_OPT
	fi
	if [ -n "$CLIENT_MAC_OPT" ]; then
		CLIENT_MAC=$(lower "$CLIENT_MAC_OPT")
	fi

	if [ -z "$CLIENT_ARG" ] && { [ -z "$CLIENT_IP" ] || [ -z "$CLIENT_MAC" ]; }; then
		usage_error "--client ADDR is required for a real run"
	fi

	if [ -n "$CLIENT_ARG" ]; then
		if is_mac "$CLIENT_ARG"; then
			[ -n "$CLIENT_MAC" ] || CLIENT_MAC=$(lower "$CLIENT_ARG")
		elif is_ipv4 "$CLIENT_ARG"; then
			[ -n "$CLIENT_IP" ] || CLIENT_IP=$CLIENT_ARG
		else
			usage_error "--client must be an IPv4 address or a MAC"
		fi
	fi

	if [ -n "$CLIENT_MAC" ] && [ -z "$CLIENT_IP" ]; then
		ip=$(ssh_dev "ip neigh show 2>/dev/null" | awk -v m="$CLIENT_MAC" '
			{
				for (i = 1; i <= NF; i++)
					if ($i == "lladdr" &&
					    tolower($(i + 1)) == m) {
						print $1
						exit
					}
			}
		')
		if [ -z "$ip" ] || ! is_ipv4 "$ip"; then
			die "no IPv4 neighbor for client MAC $CLIENT_MAC; pass --client-ip"
		fi
		CLIENT_IP=$ip
	fi

	if [ -z "$CLIENT_MAC" ] && [ -n "$CLIENT_IP" ]; then
		mac=$(ssh_dev "ip neigh show 2>/dev/null" | awk -v ip="$CLIENT_IP" '
			$1 == ip {
				for (i = 1; i <= NF; i++)
					if ($i == "lladdr") {
						print $(i + 1)
						exit
					}
			}
		')
		if [ -z "$mac" ]; then
			# Provoke an ARP entry, then retry once.
			ssh_dev "ping -c 1 -W 1 $CLIENT_IP >/dev/null 2>&1" || :
			mac=$(ssh_dev "ip neigh show 2>/dev/null" | awk -v ip="$CLIENT_IP" '
				$1 == ip {
					for (i = 1; i <= NF; i++)
						if ($i == "lladdr") {
							print $(i + 1)
							exit
						}
				}
			')
		fi
		if [ -z "$mac" ] || ! is_mac "$mac"; then
			die "no neighbor MAC for client $CLIENT_IP; pass --client-mac"
		fi
		CLIENT_MAC=$(lower "$mac")
	fi

	if [ -n "$AP_IFACE_OPT" ]; then
		AP_IFACE=$AP_IFACE_OPT
		block=$(ssh_dev "iw dev $AP_IFACE station dump 2>/dev/null") ||
			die "cannot read station dump on $AP_IFACE"
		printf '%s\n' "$block" | grep -qi "^Station $CLIENT_MAC " ||
			die "client $CLIENT_MAC is not associated on $AP_IFACE"
		return 0
	fi

	for iface in $(ssh_dev "iw dev 2>/dev/null" | awk '/Interface/ { print $2 }'); do
		block=$(ssh_dev "iw dev $iface station dump 2>/dev/null") || continue
		if printf '%s\n' "$block" | grep -qi "^Station $CLIENT_MAC "; then
			AP_IFACE=$iface
			return 0
		fi
	done

	die "client $CLIENT_MAC is not associated on any AP interface"
}

resolve_mt76_paths() {
	local out

	out=$(ssh_dev "AP='$AP_IFACE' sh -s" <<'REMOTE'
w=$(iw dev "$AP" info 2>/dev/null | awk '$1 == "wiphy" { print $2; exit }')
base=
if [ -n "$w" ]; then
	base=/sys/kernel/debug/ieee80211/phy$w/mt76
fi
if [ -z "$base" ] || [ ! -r "$base/token_info" ]; then
	base=$(ls -d /sys/kernel/debug/ieee80211/phy*/mt76 2>/dev/null | head -n 1)
fi
[ -n "$base" ] || exit 0
[ -r "$base/token_info" ] && printf 'TOKEN=%s\n' "$base/token_info"
[ -r "$base/hw-queues" ] && printf 'HWQ=%s\n' "$base/hw-queues"
REMOTE
	) || out=

	TOKEN_PATH=
	HWQ_PATH=
	while IFS='=' read -r k v; do
		case $k in
		TOKEN) TOKEN_PATH=$v ;;
		HWQ) HWQ_PATH=$v ;;
		esac
	done <<EOF
$out
EOF

	if [ -n "$TOKEN_PATH" ]; then
		note "token_info: $TOKEN_PATH"
	else
		note "token_info unavailable; token count/queue depth will be 'unavailable'"
	fi
	if [ -n "$HWQ_PATH" ]; then
		note "hw-queues: $HWQ_PATH"
	else
		note "hw-queues unavailable; PLE/HIF pages will be 'unavailable'"
	fi
}

ensure_host_addr() {
	if ip -o -4 addr show 2>/dev/null | grep -Eq "[[:space:]]$FEEDER_IP/"; then
		ip -o -4 addr show dev "$FEEDER_IFACE" 2>/dev/null |
			grep -Eq "[[:space:]]$FEEDER_IP/" ||
			die "$FEEDER_IP exists on another local interface; refusing to move it"
		return 0
	fi
	ip addr add "$FEEDER_IP/32" dev "$FEEDER_IFACE" ||
		die "cannot add $FEEDER_IP/32 to $FEEDER_IFACE"
	HOST_ADDR_ADDED=1
}

ensure_host_route() {
	local route

	route=$(ip route show "$DEV_IP/32" 2>/dev/null)
	if [ -n "$route" ]; then
		printf '%s\n' "$route" | grep -Eq "dev $FEEDER_IFACE([[:space:]]|$)" ||
			die "$DEV_IP/32 already routes elsewhere; refusing to change routing"
		return 0
	fi
	ip route add "$DEV_IP/32" dev "$FEEDER_IFACE" ||
		die "cannot add $DEV_IP/32 route via $FEEDER_IFACE"
	HOST_ROUTE_ADDED=1
}

ensure_dev_addr() {
	if ssh_dev "ip -o -4 addr show 2>/dev/null | grep -Eq '[[:space:]]$DEV_IP/'"; then
		ssh_dev "ip -o -4 addr show dev $DEV_IFACE 2>/dev/null | grep -Eq '[[:space:]]$DEV_IP/'" ||
			die "$DEV_IP exists on another interface on $DEVICE"
		return 0
	fi
	ssh_dev "ip addr add $DEV_IP/32 dev $DEV_IFACE" ||
		die "cannot add $DEV_IP/32 to $DEV_IFACE on $DEVICE"
	DEV_ADDR_ADDED=1
}

ensure_dev_route() {
	if [ -n "$(ssh_dev "ip route show $FEEDER_IP/32 2>/dev/null")" ]; then
		ssh_dev "ip route show $FEEDER_IP/32 2>/dev/null | grep -Eq 'dev $DEV_IFACE([[:space:]]|\$)'" ||
			die "$FEEDER_IP/32 already routes elsewhere on $DEVICE"
		return 0
	fi
	ssh_dev "ip route add $FEEDER_IP/32 dev $DEV_IFACE" ||
		die "cannot add $FEEDER_IP/32 route via $DEV_IFACE on $DEVICE"
	DEV_ROUTE_ADDED=1
}

setup_addressing() {
	ensure_host_addr
	ensure_host_route
	ensure_dev_addr
	ensure_dev_route

	# The AP must be able to reach the feeder host.  The reverse check
	# (host -> AP) is deliberately not required: the lab port is not in a
	# firewall zone, and the reverse iperf3 client is what keeps the test
	# free of input rules.
	if ! ssh_dev "ping -c 1 -W 2 -I $DEV_IFACE $FEEDER_IP >/dev/null 2>&1"; then
		# The AP -> host direction is the one that must work; the reverse
		# direction can be firewalled on the bench host.  Keep this a
		# warning and let arm 1 produce the real verdict.
		note "AP cannot ping $FEEDER_IP over $DEV_IFACE; continuing to arm 1"
	fi
}

detach_data_port() {
	# Runs after main() armed the EXIT trap, never before: an interrupt at
	# any point from here on puts the port back.  detaching keeps carrier and
	# speed, so a speed below 2500 after the detach means the port really is
	# not a 2.5G data port and the run skips (which restores it through the
	# trap).
	local master=${DETACH_PENDING#*:}

	[ -n "$DETACH_PENDING" ] || return 0
	pd_detach "$DEV_IFACE" ||
		die "could not detach $DEV_IFACE from $master; see the message above"
	if ! DEV_SPEED=$(dev_speed); then
		die "cannot run ethtool on $DEVICE:$DEV_IFACE after detaching it from $master"
	fi
	if [ "$DEV_SPEED" != "2500" ]; then
		note "device $DEV_IFACE link is '${DEV_SPEED:-unknown}' Mb/s after leaving $master, need 2500"
		skip_no_feeder
	fi
	DEV_DUPLEX=$(dev_duplex)
	return 0
}

cleanup() {
	if [ "${CLEANED-0}" = "1" ]; then
		return 0
	fi
	CLEANED=1

	stop_sampler || :

	if [ -n "${FEEDER_SERVER_PID-}" ]; then
		kill -TERM "$FEEDER_SERVER_PID" 2>/dev/null || :
		wait "$FEEDER_SERVER_PID" 2>/dev/null || :
		FEEDER_SERVER_PID=
	fi

	if [ -n "${ARM_SSH_PID-}" ]; then
		kill -TERM "$ARM_SSH_PID" 2>/dev/null || :
		wait "$ARM_SSH_PID" 2>/dev/null || :
		ARM_SSH_PID=
	fi

	if [ -n "${REMOTE_PIDFILE-}" ]; then
		ssh_dev "if [ -s $REMOTE_PIDFILE ]; then kill \$(cat $REMOTE_PIDFILE) 2>/dev/null; fi; rm -f $REMOTE_PIDFILE" \
			>/dev/null 2>&1 || :
		REMOTE_PIDFILE=
	fi

	if [ "${DEV_ROUTE_ADDED-0}" = "1" ]; then
		ssh_dev "ip route del $FEEDER_IP/32 dev $DEV_IFACE" >/dev/null 2>&1 ||
			note "cleanup: could not remove AP route $FEEDER_IP/32"
		DEV_ROUTE_ADDED=0
	fi
	if [ "${DEV_ADDR_ADDED-0}" = "1" ]; then
		ssh_dev "ip addr del $DEV_IP/32 dev $DEV_IFACE" >/dev/null 2>&1 ||
			note "cleanup: could not remove AP address $DEV_IP/32"
		DEV_ADDR_ADDED=0
	fi
	if [ "${HOST_ROUTE_ADDED-0}" = "1" ]; then
		ip route del "$DEV_IP/32" dev "$FEEDER_IFACE" >/dev/null 2>&1 ||
			note "cleanup: could not remove host route $DEV_IP/32"
		HOST_ROUTE_ADDED=0
	fi
	if [ "${HOST_ADDR_ADDED-0}" = "1" ]; then
		ip addr del "$FEEDER_IP/32" dev "$FEEDER_IFACE" >/dev/null 2>&1 ||
			note "cleanup: could not remove host address $FEEDER_IP/32"
		HOST_ADDR_ADDED=0
	fi

	# Last, and never skipped because a step above failed (they all use
	# "|| note"): the data port goes back into the bridge it came from.
	if ! pd_restore; then
		BRIDGE_RESTORE_FAILED=1
		note "cleanup: bridge restore failed; $PD_PORT is still out of $PD_MASTER"
	fi

	note "cleanup: streams stopped, temporary address/route removed"
}

on_exit() {
	# EXIT trap: a restore that could not be verified decides the status here,
	# because it fails after main() picked one.
	cleanup
	if [ "${BRIDGE_RESTORE_FAILED-0}" = "1" ]; then
		exit 1
	fi
}

start_sampler() {
	local arm="$1" count="$2"

	# shellcheck disable=SC2086
	ssh_dev "COUNT='$count' INTERVAL='$SAMPLER_INTERVAL' LAN='$DEV_IFACE' AP='$AP_IFACE' TOKEN='$TOKEN_PATH' HWQ='$HWQ_PATH' sh -s" \
		>"$OUT_DIR/samples.$arm.tsv" 2>"$OUT_DIR/sampler.$arm.err" <<'REMOTE' &
i=0
while [ "$i" -lt "$COUNT" ]; do
	printf '###SAMPLE %s\n' "$(date +%s)"
	printf '###LINK\n'
	ip -s link show "$LAN" 2>/dev/null
	printf '###ETHTOOL\n'
	ethtool -S "$LAN" 2>/dev/null
	printf '###APSTATS\n'
	cat "/sys/class/net/$AP/statistics/tx_bytes" 2>/dev/null
	printf '\n###STATION\n'
	iw dev "$AP" station dump 2>/dev/null
	if [ -n "$TOKEN" ]; then
		printf '###TOKEN\n'
		cat "$TOKEN" 2>/dev/null
	fi
	if [ -n "$HWQ" ]; then
		printf '###HWQ\n'
		cat "$HWQ" 2>/dev/null
	fi
	i=$((i + 1))
	if [ "$i" -lt "$COUNT" ]; then
		sleep "$INTERVAL"
	fi
done
REMOTE
	SAMPLER_PID=$!
}

stop_sampler() {
	if [ -n "${SAMPLER_PID-}" ]; then
		kill -TERM "$SAMPLER_PID" 2>/dev/null || :
		wait "$SAMPLER_PID" 2>/dev/null || :
		SAMPLER_PID=
	fi
}

sampler_count() {
	local total

	# The sampler starts immediately before traffic and is stopped after
	# the tail, so WARMUP is not part of its window.
	total=$((DURATION + TAIL))
	printf '%s' "$(((total + SAMPLER_INTERVAL - 1) / SAMPLER_INTERVAL + 3))"
}

run_remote_client() {
	local out="$1" label="$2" args="$3"
	local pidfile="/tmp/b-path-25g.$RUN_ID.$label.pid"
	local timeout_cmd=

	if dev_have timeout; then
		timeout_cmd="timeout $((DURATION + 45))"
	fi

	REMOTE_PIDFILE=$pidfile
	# shellcheck disable=SC2086
	ssh_dev "sh -c 'echo \$\$ > $pidfile; exec $timeout_cmd iperf3 $args'" \
		>"$out" 2>"$out.err" &
	ARM_SSH_PID=$!
	wait "$ARM_SSH_PID"
	ARM_STATUS=$?
	ARM_SSH_PID=
	ssh_dev "rm -f $pidfile" >/dev/null 2>&1 || :
	REMOTE_PIDFILE=
	return "$ARM_STATUS"
}

udp_args() {
	if [ "$PROTO" = "udp" ]; then
		local per

		per=$(awk -v r="$RATE" -v p="$PARALLEL" \
			'BEGIN { printf "%.3f", r / p }')
		printf '%s' "-u -b ${per}M"
	else
		printf '%s' ""
	fi
}

iperf_summary() {
	# Offered/arrived numbers from a pretty-printed iperf3 -J file:
	# sum_sent bits,bytes,seconds,retransmits then sum_received, then loss.
	awk '
	BEGIN {
		cur = ""
		sbps = "null"; sbytes = "null"; ssecs = "null"; sretr = "null"
		rbps = "null"; rbytes = "null"; rsecs = "null"; rretr = "null"
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
		} else if (index(line, "\"seconds\":") == 1) {
			v = line
			sub(/^"seconds":[[:space:]]*/, "", v)
			if (cur == "s") ssecs = v; else rsecs = v
		} else if (index(line, "\"retransmits\":") == 1) {
			v = line
			sub(/^"retransmits":[[:space:]]*/, "", v)
			if (cur == "s") sretr = v; else rretr = v
		}
	}
	END {
		printf "%s %s %s %s %s %s %s %s\n", \
			sbps, sbytes, ssecs, sretr, rbps, rbytes, rsecs, rretr
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
			sub(/^"error":[[:space:]]*"/, "", v)
			sub(/"$/, "", v)
			print v
			exit
		}
	}
	' "$1"
}

num_mbps() {
	# bits_per_second -> Mbit/s with three decimals; null -> empty.
	case ${1-} in
	''|null|*[!0-9.]*) printf '' ;;
	*) awk -v b="$1" 'BEGIN { printf "%.3f", b / 1000000.0 }' ;;
	esac
}


bytes_mbps() {
	# bytes over seconds -> Mbit/s; seconds may be fractional.
	case ${1-} in ''|*[!0-9]*) printf ''; return ;; esac
	awk -v b="$1" -v s="${2:-0}" 'BEGIN {
		if (s + 0 > 0)
			printf "%.3f", b * 8.0 / s / 1000000.0
	}'
}

or_unavailable() {
	if [ -n "${1-}" ]; then
		printf '%s' "$1"
	else
		printf 'unavailable'
	fi
}

parse_samples() {
	# One line per sample; fields are separated by "|" so empty values
	# stay distinguishable.
	awk -v mac="$(lower "${CLIENT_MAC-}")" '
	function reset() {
		ts = ""
		mode = ""
		lmode = ""
		token = ""; pool = ""
		txq = ""; txband = ""; txnd = ""
		npuq = ""; npund = ""
		sta_tx = ""; sta_ret = ""; sta_fail = ""
		ap_tx = ""
		lan_rx = ""; lan_tx = ""
		lan_rxe = ""; lan_txe = ""; lan_rxd = ""; lan_txd = ""
		ple = ""; hif = ""
		bad = 0
	}
	function emit() {
		if (ts == "")
			return
		printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n", \
			ts, token, pool, txq, txband, txnd, npuq, npund, \
			sta_tx, sta_ret, sta_fail, ap_tx, \
			lan_rx, lan_tx, lan_rxe, lan_txe, lan_rxd, lan_txd, \
			ple, hif, bad
	}
	BEGIN { reset() }
	/^###SAMPLE / {
		emit()
		reset()
		ts = $2
		mode = ""
		next
	}
	/^###/ {
		mode = substr($0, 4)
		next
	}
	mode == "LINK" {
		line = $0
		if (line ~ /^[ \t]*RX:/) { lmode = "rx"; next }
		if (line ~ /^[ \t]*TX:/) { lmode = "tx"; next }
		if (lmode != "" && $1 ~ /^[0-9]+$/) {
			if (lmode == "rx") {
				lan_rx = $1; lan_rxe = $3; lan_rxd = $4
			} else {
				lan_tx = $1; lan_txe = $3; lan_txd = $4
			}
			lmode = ""
		}
		next
	}
	mode == "ETHTOOL" {
		idx = index($0, ":")
		if (idx > 0) {
			k = substr($0, 1, idx - 1)
			v = substr($0, idx + 1)
			gsub(/[ \t]/, "", k)
			gsub(/[ \t,]/, "", v)
			if (v ~ /^[0-9]+$/ &&
			    tolower(k) ~ /(err|drop|crc|over|fail)/)
				bad += v
		}
		next
	}
	mode == "APSTATS" {
		if ($0 ~ /^[0-9]+$/)
			ap_tx = $0
		next
	}
	mode == "STATION" {
		if ($0 ~ /^Station /) {
			insta = (tolower($2) == mac)
			next
		}
		if (!insta)
			next
		if ($0 ~ /^[ \t]*tx bytes:/) { sta_tx = $3; next }
		if ($0 ~ /^[ \t]*tx retries:/) { sta_ret = $3; next }
		if ($0 ~ /^[ \t]*tx failed:/) { sta_fail = $3; next }
		next
	}
	mode == "TOKEN" {
		line = $0
		if (line ~ /token_count:/) {
			sub(/^[ \t]+/, "", line)
			split(line, a, /[ \t]+/)
			token = a[2]
			pool = a[4]
			next
		}
		if (line ~ /^[ \t]*band[ \t]/) {
			gsub(/\|/, " ", line)
			sub(/^[ \t]+/, "", line)
			split(line, a, /[ \t]+/)
			q = a[5] + 0
			n = a[4] + 0
			if (txq == "" || q > txq + 0) {
				txq = q
				txband = a[2]
				txnd = n
			}
			next
		}
		if (line ~ /^[ \t]*npu_rx/) {
			gsub(/\|/, " ", line)
			sub(/^[ \t]+/, "", line)
			split(line, a, /[ \t]+/)
			q = a[3] + 0
			n = a[2] + 0
			if (npuq == "" || q > npuq + 0) {
				npuq = q
				npund = n
			}
			next
		}
		next
	}
	mode == "HWQ" {
		if ($0 ~ /free pages/) {
			ple = $3
			gsub(/,/, "", ple)
		}
		if ($0 ~ /HIF group/) {
			for (i = 1; i <= NF; i++) {
				if ($i == "used/reserved") {
					split($(i + 1), h, "/")
					hif = h[1]
					break
				}
			}
		}
		next
	}
	END { emit() }
	' "$1"
}

collect_metrics() {
	# collect_metrics ARM PARSED
	local arm="$1" parsed="$2"
	local line key val

	MET_TOKEN_PEAK=
	MET_TOKEN_POOL=
	MET_TXQ_PEAK=
	MET_TXQ_BAND=
	MET_TXQ_ND=
	MET_NPUQ_PEAK=
	MET_NPUQ_ND=
	MET_STA_TX=
	MET_STA_RET=
	MET_STA_FAIL=
	MET_AP_TX=
	MET_LAN_RX=
	MET_LAN_TX=
	MET_LAN_RXE=
	MET_LAN_TXE=
	MET_LAN_RXD=
	MET_LAN_TXD=
	MET_PLE=
	MET_HIF=
	MET_BAD=
	MET_ELAPSED=

	line=$(awk -F'|' '
		NR == 1 {
			for (i = 1; i <= NF; i++)
				first[i] = $i
			first_ts = $1
		}
		{
			last_ts = $1
			for (i = 1; i <= NF; i++)
				last[i] = $i
			if ($2 != "" && $2 + 0 > token) token = $2 + 0
			if ($3 != "") pool = $3
			if ($4 != "" && $4 + 0 > txq) { txq = $4 + 0; txband = $5; txnd = $6 }
			if ($7 != "" && $7 + 0 > npuq) { npuq = $7 + 0; npund = $8 }
			if ($19 != "") ple = $19
			if ($20 != "") hif = $20
		}
		END {
			if (NR == 0) exit 0
			elapsed = last_ts - first_ts
			if (elapsed < 0) elapsed = 0
			print "token_peak=" token
			print "token_pool=" pool
			print "txq_peak=" txq
			print "txq_band=" txband
			print "txq_nd=" txnd
			print "npuq_peak=" npuq
			print "npuq_nd=" npund
			print "sta_tx_delta=" (last[9] - first[9])
			print "sta_ret_delta=" (last[10] - first[10])
			print "sta_fail_delta=" (last[11] - first[11])
			print "ap_tx_delta=" (last[12] - first[12])
			print "lan_rx_delta=" (last[13] - first[13])
			print "lan_tx_delta=" (last[14] - first[14])
			print "lan_rxe_delta=" (last[15] - first[15])
			print "lan_txe_delta=" (last[16] - first[16])
			print "lan_rxd_delta=" (last[17] - first[17])
			print "lan_txd_delta=" (last[18] - first[18])
			print "ple=" ple
			print "hif=" hif
			print "bad=" (last[21] - first[21])
			print "elapsed=" elapsed
		}
	' "$parsed")

	while IFS='=' read -r key val; do
		case $key in
		token_peak) MET_TOKEN_PEAK=$val ;;
		token_pool) MET_TOKEN_POOL=$val ;;
		txq_peak) MET_TXQ_PEAK=$val ;;
		txq_band) MET_TXQ_BAND=$val ;;
		txq_nd) MET_TXQ_ND=$val ;;
		npuq_peak) MET_NPUQ_PEAK=$val ;;
		npuq_nd) MET_NPUQ_ND=$val ;;
		sta_tx_delta) MET_STA_TX=$val ;;
		sta_ret_delta) MET_STA_RET=$val ;;
		sta_fail_delta) MET_STA_FAIL=$val ;;
		ap_tx_delta) MET_AP_TX=$val ;;
		lan_rx_delta) MET_LAN_RX=$val ;;
		lan_tx_delta) MET_LAN_TX=$val ;;
		lan_rxe_delta) MET_LAN_RXE=$val ;;
		lan_txe_delta) MET_LAN_TXE=$val ;;
		lan_rxd_delta) MET_LAN_RXD=$val ;;
		lan_txd_delta) MET_LAN_TXD=$val ;;
		ple) MET_PLE=$val ;;
		hif) MET_HIF=$val ;;
		bad) MET_BAD=$val ;;
		elapsed) MET_ELAPSED=$val ;;
		esac
	done <<EOF
$line
EOF
}

collect_json() {
	# collect_json ARM -> sets J_OFFERED, J_ARRIVED, J_RETR, J_LOST, J_ERR
	local arm="$1" file="$OUT_DIR/$1.json" summary
	local sbps sbytes ssecs sret rbps rbytes _lost

	J_OFFERED=
	J_ARRIVED=
	J_RETR=
	J_SECONDS=
	J_LOST=n/a
	J_ERR=

	if [ ! -s "$file" ]; then
		J_ERR="no iperf3 JSON"
		return 1
	fi

	summary=$(iperf_summary "$file")
	# shellcheck disable=SC2086
	set -- $summary
	sbps=$1
	sbytes=$2
	ssecs=$3
	sret=$4
	rbps=$5
	rbytes=$6

	J_ERR=$(iperf_error "$file")
	J_OFFERED=$(num_mbps "$sbps")
	J_ARRIVED=$(num_mbps "$rbps")
	case $sret in
	null|'') J_RETR= ;;
	*) J_RETR=$sret ;;
	esac
	case $ssecs in
	''|null|*[!0-9.]*) J_SECONDS= ;;
	*) J_SECONDS=$ssecs ;;
	esac
	if [ "$PROTO" = "udp" ]; then
		_lost=$(awk -v s="$sbytes" -v r="$rbytes" 'BEGIN {
			if (s ~ /^[0-9]+$/ && r ~ /^[0-9]+$/ && s > 0)
				printf "%.2f", (s - r) * 100.0 / s
		}')
		[ -n "$_lost" ] && J_LOST="${_lost}%"
	fi

	if [ -n "$J_ERR" ]; then
		return 1
	fi
	[ -n "$J_OFFERED" ] && [ -n "$J_ARRIVED" ] || {
		J_ERR="no usable iperf3 sum_sent/sum_received"
		return 1
	}
	return 0
}

run_feeder_arm() {
	local host_before host_after count udp
	local elapsed

	note "arm feeder: host $FEEDER_IP -> AP $DEV_IP over $DEV_IFACE (proto=$PROTO)"
	ARM1_OK=0
	ARM1_OFFERED=
	ARM1_ARRIVED=
	ARM1_RETR=
	ARM1_LOST=
	ARM1_ERR=
	ARM1_HOST_TX=
	ARM1_LAN_RX=
	ARM1_LAN_TX=
	ARM1_LAN_ERRORS=0
	ARM1_LAN_DROPS=0

	udp=$(udp_args)
	count=$(sampler_count)
	host_before=$(local_tx_bytes "$FEEDER_IFACE")

	# Host iperf3 server.  In reverse mode it is the sender; the AP
	# client only receives.
	iperf3 -s -1 -B "$FEEDER_IP" -p "$PORT" \
		>"$OUT_DIR/feeder-server.log" 2>&1 &
	FEEDER_SERVER_PID=$!
	sleep 1

	sleep "$WARMUP"
	start_sampler feeder "$count"
	# Let the first sample land before traffic so the baseline counters are
	# not already carrying the arm.
	sleep 1

	# shellcheck disable=SC2086
	run_remote_client "$OUT_DIR/feeder.json" feeder \
		"-c $FEEDER_IP -B $DEV_IP -p $PORT -t $DURATION -P $PARALLEL -R $udp -J"
	ARM_STATUS=$?

	sleep "$TAIL"
	stop_sampler

	kill -TERM "$FEEDER_SERVER_PID" 2>/dev/null || :
	wait "$FEEDER_SERVER_PID" 2>/dev/null || :
	FEEDER_SERVER_PID=

	host_after=$(local_tx_bytes "$FEEDER_IFACE")
	parse_samples "$OUT_DIR/samples.feeder.tsv" >"$OUT_DIR/samples.feeder.parsed"
	collect_metrics feeder "$OUT_DIR/samples.feeder.parsed"

	if collect_json feeder; then
		ARM1_OK=1
		ARM1_OFFERED=$J_OFFERED
		ARM1_ARRIVED=$J_ARRIVED
		ARM1_RETR=$J_RETR
		ARM1_LOST=$J_LOST
	else
		ARM1_ERR=${J_ERR:-arm failed}
		ARM1_OFFERED=$J_OFFERED
		ARM1_ARRIVED=$J_ARRIVED
	fi

	# The host counters cover the iperf3 transfer; the sampler counters
	# cover traffic plus the tail.
	elapsed=${J_SECONDS:-$DURATION}
	if [ -n "$host_before" ] && [ -n "$host_after" ] &&
	   [ "$host_after" -ge "$host_before" ]; then
		ARM1_HOST_TX=$(bytes_mbps "$((host_after - host_before))" "$elapsed")
	fi
	elapsed=$MET_ELAPSED
	[ -n "$elapsed" ] && [ "$elapsed" -gt 0 ] || elapsed=$DURATION
	ARM1_LAN_RX=$(bytes_mbps "$MET_LAN_RX" "$elapsed")
	ARM1_LAN_TX=$(bytes_mbps "$MET_LAN_TX" "$elapsed")
	ARM1_LAN_ERRORS=$(( ${MET_LAN_RXE:-0} + ${MET_LAN_TXE:-0} ))
	ARM1_LAN_DROPS=$(( ${MET_LAN_RXD:-0} + ${MET_LAN_TXD:-0} ))
	if [ "$ARM_STATUS" -ne 0 ] && [ -n "$ARM1_ERR" ]; then
		note "feeder arm failed: $ARM1_ERR"
	fi
}

run_sta_arm() {
	local count udp elapsed

	note "arm sta: AP -> STA $CLIENT_IP/$CLIENT_MAC ($AP_IFACE, proto=$PROTO)"
	ARM2_OK=0
	ARM2_OFFERED=
	ARM2_ARRIVED=
	ARM2_RETR=
	ARM2_LOST=
	ARM2_ERR=
	ARM2_AP_TX=
	ARM2_STA_TX=
	ARM2_STA_RET=
	ARM2_STA_FAIL=
	ARM2_LAN_RX=
	ARM2_LAN_ERRORS=0
	ARM2_LAN_DROPS=0

	udp=$(udp_args)
	count=$(sampler_count)

	sleep "$WARMUP"
	start_sampler sta "$count"
	sleep 1

	# shellcheck disable=SC2086
	run_remote_client "$OUT_DIR/sta.json" sta \
		"-c $CLIENT_IP -p $PORT -t $DURATION -P $PARALLEL $udp -J"
	ARM_STATUS=$?

	sleep "$TAIL"
	stop_sampler

	parse_samples "$OUT_DIR/samples.sta.tsv" >"$OUT_DIR/samples.sta.parsed"
	collect_metrics sta "$OUT_DIR/samples.sta.parsed"

	if collect_json sta; then
		ARM2_OK=1
		ARM2_OFFERED=$J_OFFERED
		ARM2_ARRIVED=$J_ARRIVED
		ARM2_RETR=$J_RETR
		ARM2_LOST=$J_LOST
	else
		ARM2_ERR=${J_ERR:-arm failed}
		ARM2_OFFERED=$J_OFFERED
		ARM2_ARRIVED=$J_ARRIVED
	fi

	elapsed=$MET_ELAPSED
	[ -n "$elapsed" ] && [ "$elapsed" -gt 0 ] || elapsed=$DURATION
	ARM2_AP_TX=$(bytes_mbps "$MET_AP_TX" "$elapsed")
	ARM2_STA_TX=$(bytes_mbps "$MET_STA_TX" "$elapsed")
	ARM2_STA_RET=$MET_STA_RET
	ARM2_STA_FAIL=$MET_STA_FAIL
	ARM2_LAN_RX=$(bytes_mbps "$MET_LAN_RX" "$elapsed")
	ARM2_LAN_ERRORS=$(( ${MET_LAN_RXE:-0} + ${MET_LAN_TXE:-0} ))
	ARM2_LAN_DROPS=$(( ${MET_LAN_RXD:-0} + ${MET_LAN_TXD:-0} ))
	if [ "$ARM_STATUS" -ne 0 ] && [ -n "$ARM2_ERR" ]; then
		note "sta arm failed: $ARM2_ERR"
	fi
}

arm_peak_metrics() {
	# Keep the feeder-arm peaks separate from the STA-arm ones.
	ARM1_TOKEN_PEAK=$MET_TOKEN_PEAK
	ARM1_TOKEN_POOL=$MET_TOKEN_POOL
	ARM1_TXQ_PEAK=$MET_TXQ_PEAK
	ARM1_TXQ_BAND=$MET_TXQ_BAND
	ARM1_TXQ_ND=$MET_TXQ_ND
	ARM1_BAD=$MET_BAD
}

save_sta_peaks() {
	ARM2_TOKEN_PEAK=$MET_TOKEN_PEAK
	ARM2_TOKEN_POOL=$MET_TOKEN_POOL
	ARM2_TXQ_PEAK=$MET_TXQ_PEAK
	ARM2_TXQ_BAND=$MET_TXQ_BAND
	ARM2_TXQ_ND=$MET_TXQ_ND
	ARM2_NPUQ_PEAK=$MET_NPUQ_PEAK
	ARM2_NPUQ_ND=$MET_NPUQ_ND
	ARM2_PLE=$MET_PLE
	ARM2_HIF=$MET_HIF
	ARM2_BAD=$MET_BAD
}

verdict_line() {
	local arrived_gbps verdict exhaustion feeder_note

	if [ "${ARM2_OK-0}" -ne 1 ]; then
		printf 'NPU-WALL: not measured (device->STA arm failed: %s)\n' \
			"$(or_unavailable "${ARM2_ERR-}")"
		return 0
	fi

	arrived_gbps=$(awk -v m="$ARM2_ARRIVED" 'BEGIN { printf "%.3f", m / 1000.0 }')
	if awk -v a="$ARM2_ARRIVED" 'BEGIN { exit !(a >= 2200) }'; then
		verdict="not-observed (>=2.2G)"
	elif awk -v a="$ARM2_ARRIVED" 'BEGIN { exit !(a >= 1500) }'; then
		verdict="present (1.5-2.2G band)"
	elif awk -v a="$ARM2_ARRIVED" 'BEGIN { exit !(a >= 1000) }'; then
		verdict="below-band (1.0-1.5G)"
	else
		verdict="far-below-band (<1.0G)"
	fi

	exhaustion="token/queue headroom"
	if [ -n "${ARM2_TOKEN_POOL-}" ] && [ -n "${ARM2_TOKEN_PEAK-}" ] &&
	   [ "$ARM2_TOKEN_PEAK" -ge "$ARM2_TOKEN_POOL" ]; then
		exhaustion="SW token pool saturated ($ARM2_TOKEN_PEAK/$ARM2_TOKEN_POOL)"
	elif [ -n "${ARM2_TXQ_ND-}" ] && [ -n "${ARM2_TXQ_PEAK-}" ] &&
	     [ "$ARM2_TXQ_ND" -gt 0 ] &&
	     [ $((ARM2_TXQ_PEAK * 100)) -ge $((ARM2_TXQ_ND * 90)) ]; then
		exhaustion="TX queue >=90% ($ARM2_TXQ_PEAK/$ARM2_TXQ_ND)"
	fi

	feeder_note="feeder_arrived=$(or_unavailable "${ARM1_ARRIVED}")M"
	if [ "${ARM1_OK-0}" -ne 1 ]; then
		feeder_note="feeder_failed"
	elif [ -n "${ARM1_ARRIVED-}" ] && awk -v a="$ARM1_ARRIVED" 'BEGIN { exit !(a < 2200) }'; then
		feeder_note="feeder_ceiling=$(ARM1_ARRIVED)M"
	fi

	printf 'NPU-WALL: sta_arrived=%sG wall=%s tokens=%s/%s txq=%s/%s(band %s) %s; %s\n' \
		"$arrived_gbps" "$verdict" \
		"$(or_unavailable "${ARM2_TOKEN_PEAK-}")" \
		"$(or_unavailable "${ARM2_TOKEN_POOL-}")" \
		"$(or_unavailable "${ARM2_TXQ_PEAK-}")" \
		"$(or_unavailable "${ARM2_TXQ_ND-}")" \
		"$(or_unavailable "${ARM2_TXQ_BAND-}")" \
		"$exhaustion" "$feeder_note"
}

print_summary() {
	local status="$1"

	printf '== B-path 2.5G wired feeder -> Wi-Fi ==\n'
	printf 'device: %s data_iface=%s link=%sMb/s duplex=%s driver=%s\n' \
		"$DEVICE" "$DEV_IFACE" "$(or_unavailable "${DEV_SPEED-}")" \
		"$(or_unavailable "${DEV_DUPLEX-}")" "$(or_unavailable "${DEV_DRIVER-}")"
	printf 'feeder: %s link=%sMb/s driver=%s\n' \
		"$(or_unavailable "${FEEDER_IFACE-}")" \
		"$(or_unavailable "${FEEDER_SPEED-}")" \
		"$(or_unavailable "${FEEDER_DRIVER-}")"
	printf 'client: %s mac=%s ap_iface=%s proto=%s duration=%ss parallel=%s\n' \
		"$(or_unavailable "${CLIENT_IP-}")" \
		"$(or_unavailable "${CLIENT_MAC-}")" \
		"$(or_unavailable "${AP_IFACE-}")" "$PROTO" "$DURATION" "$PARALLEL"
	printf 'link speed: device=%sMb/s feeder=%sMb/s\n' \
		"$(or_unavailable "${DEV_SPEED-}")" \
		"$(or_unavailable "${FEEDER_SPEED-}")"

	printf 'arm feeder: offered=%sM arrived=%sM retr=%s lost=%s host_tx=%sM lan10g_rx=%sM lan10g_tx=%sM errors=%s drops=%s token_peak=%s/%s txq_peak=%s/%s(band %s) bad_counters_delta=%s\n' \
		"$(or_unavailable "${ARM1_OFFERED-}")" \
		"$(or_unavailable "${ARM1_ARRIVED-}")" \
		"$(or_unavailable "${ARM1_RETR-}")" \
		"$(or_unavailable "${ARM1_LOST-}")" \
		"$(or_unavailable "${ARM1_HOST_TX-}")" \
		"$(or_unavailable "${ARM1_LAN_RX-}")" \
		"$(or_unavailable "${ARM1_LAN_TX-}")" \
		"${ARM1_LAN_ERRORS-0}" "${ARM1_LAN_DROPS-0}" \
		"$(or_unavailable "${ARM1_TOKEN_PEAK-}")" \
		"$(or_unavailable "${ARM1_TOKEN_POOL-}")" \
		"$(or_unavailable "${ARM1_TXQ_PEAK-}")" \
		"$(or_unavailable "${ARM1_TXQ_ND-}")" \
		"$(or_unavailable "${ARM1_TXQ_BAND-}")" \
		"$(or_unavailable "${ARM1_BAD-}")"

	printf 'arm sta: offered=%sM arrived=%sM retr=%s lost=%s ap_tx=%sM station_tx=%sM retries=%s failed=%s lan10g_rx=%sM errors=%s drops=%s bad_counters_delta=%s\n' \
		"$(or_unavailable "${ARM2_OFFERED-}")" \
		"$(or_unavailable "${ARM2_ARRIVED-}")" \
		"$(or_unavailable "${ARM2_RETR-}")" \
		"$(or_unavailable "${ARM2_LOST-}")" \
		"$(or_unavailable "${ARM2_AP_TX-}")" \
		"$(or_unavailable "${ARM2_STA_TX-}")" \
		"$(or_unavailable "${ARM2_STA_RET-}")" \
		"$(or_unavailable "${ARM2_STA_FAIL-}")" \
		"$(or_unavailable "${ARM2_LAN_RX-}")" \
		"${ARM2_LAN_ERRORS-0}" "${ARM2_LAN_DROPS-0}" \
		"$(or_unavailable "${ARM2_BAD-}")"

	printf 'token count: peak %s / %s\n' \
		"$(or_unavailable "${ARM2_TOKEN_PEAK-}")" \
		"$(or_unavailable "${ARM2_TOKEN_POOL-}")"
	printf 'queue depth: tx peak %s / %s (band %s), npu_rx ring %s / %s\n' \
		"$(or_unavailable "${ARM2_TXQ_PEAK-}")" \
		"$(or_unavailable "${ARM2_TXQ_ND-}")" \
		"$(or_unavailable "${ARM2_TXQ_BAND-}")" \
		"$(or_unavailable "${ARM2_NPUQ_PEAK-}")" \
		"$(or_unavailable "${ARM2_NPUQ_ND-}")"
	printf 'hw-queues: ple_free=%s hif_used=%s\n' \
		"$(or_unavailable "${ARM2_PLE-}")" \
		"$(or_unavailable "${ARM2_HIF-}")"
	printf 'status: %s artifacts=%s\n' "$status" "$OUT_DIR"
	verdict_line
}

dry_run() {
	local count udp

	note "dry-run: no SSH, no traffic, no address/route change, no directory created"
	[ "$DETACH_PORT" -eq 1 ] &&
		note "dry-run: --detach-port is planned, not run"
	check_link_tools dry-run
	check_traffic_tools dry-run

	# Resolve and validate the local side only; the AP side is unchecked
	# by design in a dry run.  This is what turns an absent or 1G feeder
	# into the clean skip instead of a plan that could not run.
	resolve_feeder_iface

	udp=$(udp_args)
	count=$(sampler_count)

	printf 'DRY-RUN: B-path 2.5G feeder -> Wi-Fi plan\n'
	printf 'device: %s iface=%s (SSH checked at run time; lan10g must be 2500Mb/s)\n' \
		"$DEVICE" "$DEV_IFACE"
	printf 'feeder: %s link=%sMb/s driver=%s\n' \
		"$FEEDER_IFACE" "$(or_unavailable "$FEEDER_SPEED")" \
		"$(or_unavailable "$FEEDER_DRIVER")"
	printf 'client: %s mac=%s ap_iface=%s (checked at run time)\n' \
		"$(or_unavailable "${CLIENT_IP:-$CLIENT_ARG}")" \
		"$(or_unavailable "${CLIENT_MAC:-$CLIENT_MAC_OPT}")" \
		"$(or_unavailable "${AP_IFACE_OPT:-auto}")"
	printf 'sampler: interval=%ss count=%s per arm; arms run sequentially, never at once\n' \
		"$SAMPLER_INTERVAL" "$count"

	printf 'commands (run time):\n'
	printf '  ssh %s %s true\n' "$SSH_OPTS" "$DEVICE"
	printf '  ssh %s %s "ethtool %s  # require Speed: 2500Mb/s"\n' \
		"$SSH_OPTS" "$DEVICE" "$DEV_IFACE"
	if [ "$DETACH_PORT" -eq 1 ]; then
		# Printed, not run: a dry run does no SSH, so the master is whatever
		# the AP reports at run time.  These two lines are the whole
		# device-state change --detach-port makes.
		printf '  ssh %s %s "ip link set %s nomaster"        # only for the two arms\n' \
			"$SSH_OPTS" "$DEVICE" "$DEV_IFACE"
		printf '  ssh %s %s "ip link set %s master ORIG_MASTER"   # restore, from the EXIT trap\n' \
			"$SSH_OPTS" "$DEVICE" "$DEV_IFACE"
		printf '  # ORIG_MASTER is read from /sys/class/net/%s/master before the detach\n' \
			"$DEV_IFACE"
	fi
	printf '  ip addr add %s/32 dev %s\n' "$FEEDER_IP" "$FEEDER_IFACE"
	printf '  ip route add %s/32 dev %s\n' "$DEV_IP" "$FEEDER_IFACE"
	printf '  ssh %s %s "ip addr add %s/32 dev %s"\n' \
		"$SSH_OPTS" "$DEVICE" "$DEV_IP" "$DEV_IFACE"
	printf '  ssh %s %s "ip route add %s/32 dev %s"\n' \
		"$SSH_OPTS" "$DEVICE" "$FEEDER_IP" "$DEV_IFACE"
	printf '  ssh %s %s "ping -I %s -c 1 %s"\n' \
		"$SSH_OPTS" "$DEVICE" "$DEV_IFACE" "$FEEDER_IP"
	printf '  iperf3 -s -1 -B %s -p %s &\n' "$FEEDER_IP" "$PORT"
	printf '  ssh %s %s "iperf3 -c %s -B %s -p %s -t %s -P %s -R %s -J"\n' \
		"$SSH_OPTS" "$DEVICE" "$FEEDER_IP" "$DEV_IP" "$PORT" \
		"$DURATION" "$PARALLEL" "$udp"
	printf '  ssh %s %s "iperf3 -c %s -p %s -t %s -P %s %s -J"\n' \
		"$SSH_OPTS" "$DEVICE" \
		"$(or_unavailable "${CLIENT_IP:-$CLIENT_ARG}")" "$PORT" \
		"$DURATION" "$PARALLEL" "$udp"
	printf '  ssh %s %s "cat /sys/kernel/debug/ieee80211/phy*/mt76/token_info"\n' \
		"$SSH_OPTS" "$DEVICE"
	printf '  ssh %s %s "cat /sys/kernel/debug/ieee80211/phy*/mt76/hw-queues"\n' \
		"$SSH_OPTS" "$DEVICE"
	printf '  cleanup: kill iperf3, ip route del, ip addr del on both sides%s\n' \
		"$( [ "$DETACH_PORT" -eq 1 ] && printf ', bridge restore' )"
	printf 'result: link speed, offered, arrived, token count, queue depth, NPU-WALL verdict\n'
	exit 0
}

main() {
	parse_args "$@"

	[ "$DRY_RUN" -eq 1 ] && dry_run

	# The feeder verdict comes first: on a host without iperf3 an absent (or
	# 1G) feeder must still print "SKIP: no 2.5G feeder", so the traffic tools
	# are only demanded once a 2.5G feeder exists (issue #70).
	check_link_tools run
	resolve_feeder_iface
	check_traffic_tools run
	check_device
	if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
		die "run as root on the feeder host: temporary ip addr/route need CAP_NET_ADMIN"
	fi
	resolve_client
	resolve_mt76_paths

	if [ -n "$OUT_DIR_OPT" ]; then
		OUT_DIR=$OUT_DIR_OPT
	else
		OUT_DIR=/tmp/b-path-25g.$(date +%Y%m%d-%H%M%S)
	fi
	mkdir -p "$OUT_DIR" || die "cannot create $OUT_DIR"
	RUN_ID=$(date +%s)-$$
	HOST_ADDR_ADDED=0
	HOST_ROUTE_ADDED=0
	DEV_ADDR_ADDED=0
	DEV_ROUTE_ADDED=0
	FEEDER_SERVER_PID=
	SAMPLER_PID=
	ARM_SSH_PID=
	REMOTE_PIDFILE=
	CLEANED=0
	ARM1_OK=0
	ARM2_OK=0

	# EXIT runs cleanup, which restores the bridge; the detach only happens
	# after these traps exist.  INT/TERM/HUP exit 130, which fires the same
	# EXIT trap.
	trap 'on_exit' EXIT
	trap 'exit 130' INT TERM HUP

	printf '%s\n' "$PROG: device=$DEVICE iface=$DEV_IFACE speed=${DEV_SPEED}Mb/s feeder=$FEEDER_IFACE speed=${FEEDER_SPEED}Mb/s client=$CLIENT_IP/$CLIENT_MAC" \
		>"$OUT_DIR/cmdline.txt"

	detach_data_port

	setup_addressing
	run_feeder_arm
	arm_peak_metrics
	run_sta_arm
	save_sta_peaks

	if [ "$ARM1_OK" -eq 1 ] && [ "$ARM2_OK" -eq 1 ]; then
		status=ok
	else
		status=partial
	fi
	print_summary "$status" >"$OUT_DIR/summary.txt"
	cat "$OUT_DIR/summary.txt"

	cleanup
	if [ "$BRIDGE_RESTORE_FAILED" = "1" ]; then
		printf 'status: blocked\n'
		exit 1
	fi
	if [ "$status" = "ok" ]; then
		exit 0
	fi
	exit 1
}

# Sourced by scripts/tests/test_2g5_missing_tool.py to exercise the missing
# tool record without a NIC, a device or traffic.
[ "${G25_BPATH_LIB_ONLY:-0}" = 1 ] && return 0

main "$@"
