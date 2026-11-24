#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# shellcheck disable=SC3010,SC3011,SC3014,SC3028,SC3030,SC3040,SC3043,SC3044,SC3050,SC3054
# The body below is bash (declare -A, arrays), so the shebang says bash: it
# used to say `#!/bin/sh`, which made `sh -n` fail at the first bash-only line
# in every syntax-checking tool that trusted the label (issue #70).  `sh
# <script>` still works - the guard below re-execs under bash before the
# parser reaches those lines - so both callers keep working.
if [ -z "${BASH_VERSION:-}" ]; then
	command -v bash >/dev/null 2>&1 || {
		printf 'BLOCKED: this script needs bash, run: bash %s\n' "$0" >&2
		exit 2
	}
	exec bash "$0" "$@"
fi
#
# pppoe-decap-hw-bench.sh - reproducible PPPoE hardware-decap validation.
#
# The question is narrow: does the airoha PPE encode IB1.BIND_TUNNEL_DECAP
# (bit23) on a *bound* PPPoE ingress entry at >=2.5G, and does the per-wire
# softirq cost fall when it does?  IB1 bit23 is the field the PPE driver sets
# for FLOW_ACTION_PPPOE_POP; the 1G experiment (three arms, three repeats)
# showed it is the switch between software and hardware decap.  The 1G link
# already runs at ~937 Mbit/s on the software path and is deliberately not
# admitted here: the gate below refuses anything slower than 2.5G.
#
# Topology this harness expects (it measures, it does not build the bed):
#
#   bench host (this script)                       router (--device)
#   +------------------------+   PPPoE, >=2.5G   +----------------------+
#   | PPP interface          |<------------------>| WAN Ethernet         |
#   | (session is up)        |                    | (--wan-if, PPPoE)    |
#   +------------------------+                    |   decap + forward    |
#                                                 +----------+-----------+
#                                                            | LAN
#                                                 +----------v-----------+
#                                                 | iperf3 -s (--peer)   |
#                                                 +----------------------+
#
# One direction only: the bench host sends from its PPP interface through the
# router, the router decaps the PPPoE ingress and forwards to the LAN peer.
# That forward entry is the one IB1.BIND_TUNNEL_DECAP describes.  Running both
# directions would mix the PPPoE push side (bit22) with the decap side.
#
# For each arm the script records sender/receiver Mbit/s from iperf3, the
# device's softirq tick delta and softirq microseconds per wire packet, and
# the matching ppe/entries rows: state (BND/UNB), ib1, and bit23.  The three
# arms are ppe/pppoe_decap=0/1/2; the original value is restored from an EXIT
# trap, including on failure or interrupt.
#
# What this script never does:
#   - it never writes an nft rule, changes a flowtable, or adds the PPP
#     interface to a flowtable's devices (ppp0 is not an Ethernet ingress;
#     adding it to a flowtable would be wrong, not an optimization);
#   - it never creates or tears down the PPPoE session, adds a host route,
#     or touches the peer's iperf3 server;
#   - it never uses CGNAT space for temporary addressing (it adds none).
#
# The only temporary state is /sys/kernel/debug/ppe/pppoe_decap.  Everything
# else is read-only sampling.
#
# Exit status:
#   0  all three arms ran and the decap=1 (or decap=2) arm shows a BND entry
#      with ib1 bit23 set
#   1  a precondition passed but an arm or the validation itself failed
#   2  usage error, or a precondition is missing (BLOCKED)
#
set -u
set -o pipefail
LC_ALL=C
export LC_ALL

PROG=${0##*/}

DEVICE=${DEVICE:-root@192.168.1.1}
WAN_IF=${WAN_IF:-lan10g}
PEER=${PEER:-}
DURATION=${DURATION:-15}
PORT=${PORT:-5201}
OUT=${OUT:-}
DRY_RUN=0
MIN_PEER_MBPS=${MIN_PEER_MBPS:-2000}
SSH_OPTS=${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3}

PPE_DIR=/sys/kernel/debug/ppe
KNOB=$PPE_DIR/pppoe_decap
ENTRIES=$PPE_DIR/entries
USAGE=$PPE_DIR/usage
BIND_RATE_FILE=$PPE_DIR/bind_rate

PROBE_DURATION=3
# /proc/stat counts in USER_HZ = CLK_TCK, which is 100 on most arm64 builds
# but not on every one of them; converting ticks with a hardcoded 100 puts a
# silent factor on the only number this bench exists to report.
BENCH_HZ=$(getconf CLK_TCK 2>/dev/null) || BENCH_HZ=100
case $BENCH_HZ in
'' | *[!0-9]* | 0) BENCH_HZ=100 ;;
esac
TIMEOUT_BIN=
TMPDIR_RUN=
RAW_LOG=
CMDLINE=
KNOB_ORIG=
KNOB_SAVED=0
CLEANED=0
DEV_LINK=
HOST_LINK=
DEV_SESSION_ID=
DEV_SESSION_DEV=
HOST_SESSION_ID=
HOST_SESSION_DEV=
DEV_PPP=
DEV_LOCAL=
DEV_PEER_ADDR=
HOST_PPP=
HOST_LOCAL=
HOST_PEER_ADDR=
BIND_RATE=
PROBE_SUMMARY=
CPORT_BASE=
PROBE_CPORT=

# Per-arm results, used by the verdict.
declare -A ARM_N=() ARM_BND=() ARM_BIT23=() ARM_BND23=() ARM_STATUS=()

usage() {
	cat <<'EOF'
Usage: pppoe-decap-hw-bench.sh [options]

Validate IB1.BIND_TUNNEL_DECAP (bit23) on a PPPoE WAN at >=2.5G with three
knob arms (ppe/pppoe_decap=0/1/2).  The script runs on the bench host,
reaches the router over SSH, and measures one direction: bench-host PPP ->
router PPPoE decap -> LAN-side iperf3 peer.

Required for a real run:
  --device USER@ADDR   SSH target of the router (default root@192.168.1.1)
  --wan-if NAME        router WAN Ethernet carrying the PPPoE session
                       (default lan10g; accepted: lan3 lan10g wan wan10g)
  --peer IPV4          LAN-side iperf3 server reached through the router

Options:
  --duration SEC       seconds per arm (default 15)
  --port N             peer iperf3 server port (default 5201)
  --out FILE           TSV result file
                       (default pppoe-decap-hw-bench-<timestamp>.tsv)
  --dry-run            print the plan and the three-arm matrix, run nothing
  -h, --help           this text

Environment:
  SSH_OPTS             ssh options (BatchMode=yes and a 5 s timeout by default)
  MIN_PEER_MBPS        probe throughput floor (default 2000)

The bed must already exist:
  - a PPPoE session is up on the router's WAN Ethernet, and the bench host
    owns the access-concentrator side of the same session; /proc/net/pppoe
    on both sides must show it.  This script does not dial or start pppd;
  - iperf3 -s -p PORT is listening on the LAN-side peer, and the peer is
    reachable through the router (it is not the bench host's own address);
  - the bench host's route to --peer egresses its PPP interface, and the
    router's route to --peer egresses a LAN interface.  The script does not
    add routes; a missing route is reported, not worked around;
  - /sys/kernel/debug/ppe/{pppoe_decap,entries,usage} exists on the router
    (a firmware carrying the ppe/pppoe_decap knob).

Gates (a failure prints BLOCKED and exits 2, without numbers):
  - the router WAN Ethernet and the bench host PPPoE NIC must both report
    >=2500 Mb/s from ethtool or /sys/class/net/*/speed.  A 1G link is the
    software path and is not admitted; 1G results are not in scope here;
  - the probe must deliver at least MIN_PEER_MBPS, otherwise the bed is a
    <2.5G peer, not a 2.5G/10G peer;
  - the probe must produce a matching ppe/entries row, otherwise the
    flowtable/PPE is not offloading this WAN port and no BND/bit23 number
    would be valid.

Per arm (three arms, run sequentially, one iperf3 stream):
  1. write ppe/pppoe_decap=0, 1 or 2 and read it back;
  2. sample /proc/stat, the WAN counter and ppe/usage;
  3. iperf3 -c --peer -p PORT -t DURATION -P 1 --cport <unique> -J;
  4. sample the same counters and the matching ppe/entries rows
     (ib1, state BND/UNB, bit23, bnd_bit23);
  5. write the next arm.
  The original knob value is restored by the EXIT trap, including on
  failure or SIGINT/SIGTERM/SIGHUP.

Safety:
  - no nft rule is written, no flowtable is changed, and the PPP interface
    is never added to a flowtable's devices (ppp0 is not an Ethernet
    ingress);
  - no route, address, zone or firewall setting is changed;
  - the only written state is ppe/pppoe_decap, restored in the trap.

Exit status: 0 pass, 1 arm/validation failure, 2 usage or BLOCKED.

Examples:
  ./scripts/pppoe-decap-hw-bench.sh --dry-run
  ./scripts/pppoe-decap-hw-bench.sh --device root@192.168.1.1 \
      --wan-if lan10g --peer 192.168.1.50 --duration 15
EOF
}

usage_error() {
	printf '%s: %s\n' "$PROG" "$1" >&2
	printf 'Try "%s --help" for usage.\n' "$PROG" >&2
	exit 2
}

blocked() {
	printf 'BLOCKED: %s\n' "$*"
	exit 2
}

die() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

note() {
	printf '%s: %s\n' "$PROG" "$*" >&2
}

say() {
	printf '%s\n' "$*"
	if [ -n "${RAW_LOG:-}" ] && [ -w "$RAW_LOG" ]; then
		printf '%s\n' "$*" >>"$RAW_LOG"
	fi
}

log() {
	if [ -n "${RAW_LOG:-}" ] && [ -w "$RAW_LOG" ]; then
		printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$RAW_LOG"
	fi
}

is_uint() {
	case ${1-} in
	''|*[!0-9]*) return 1 ;;
	*) return 0 ;;
	esac
}

is_ipv4() {
	local ip=${1-}
	printf '%s\n' "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
	awk -F. '{ for (i = 1; i <= 4; i++) if ($i > 255) exit 1 }' <<EOF
$ip
EOF
}

is_ifname() {
	case ${1-} in
	''|-*|*[!a-zA-Z0-9_.:@-]*) return 1 ;;
	*) return 0 ;;
	esac
}

is_device() {
	case ${1-} in
	''|-*|*[!a-zA-Z0-9_.@:-]*) return 1 ;;
	*) return 0 ;;
	esac
}

dev() {
	# SSH_OPTS is intentionally word-split, and the remote text is expanded
	# here on purpose because it is the remote command.
	# shellcheck disable=SC2086,SC2029
	ssh $SSH_OPTS "$DEVICE" "$@"
}

dev_capture() {
	local label=$1 cmd=$2 out rc
	out=$(dev "$cmd" 2>&1)
	rc=$?
	if [ -n "${RAW_LOG:-}" ] && [ -w "$RAW_LOG" ]; then
		{
			printf '### %s (ssh rc=%s)\n' "$label" "$rc"
			printf '%s\n' "$out"
		} >>"$RAW_LOG"
	fi
	printf '%s' "$out"
	return "$rc"
}

speed_of_text() {
	local text=$1 speed
	speed=$(printf '%s\n' "$text" | awk -F: '
		/Speed/ {
			gsub(/[^0-9]/, "", $2)
			if ($2 != "") {
				print $2
				exit
			}
		}
	')
	if [ -n "$speed" ]; then
		printf '%s' "$speed"
		return 0
	fi
	printf '%s\n' "$text" | tr -d '[:space:]' | grep -E '^[0-9]+$' || true
}

host_speed() {
	local iface=$1 out=
	if command -v ethtool >/dev/null 2>&1; then
		out=$(ethtool "$iface" 2>/dev/null) || out=
	fi
	if [ -z "$out" ] && [ -r "/sys/class/net/$iface/speed" ]; then
		out=$(cat "/sys/class/net/$iface/speed" 2>/dev/null) || out=
	fi
	speed_of_text "$out"
}

host_phy_speed() {
	local iface=$1 speed=
	speed=$(host_speed "$iface")
	if [ -z "$speed" ] && [[ "$iface" == *.* ]]; then
		speed=$(host_speed "${iface%%.*}")
	fi
	printf '%s' "$speed"
}

dev_speed() {
	local iface=$1 out=
	out=$(dev "ethtool $iface 2>/dev/null") || out=
	if [ -z "$out" ]; then
		out=$(dev "cat /sys/class/net/$iface/speed 2>/dev/null") || out=
	fi
	speed_of_text "$out"
}

parse_ppp_addr_lines() {
	awk '
		{
			name = $2
			sub(/:$/, "", name)
			loc = ""
			peer = ""
			for (i = 1; i <= NF; i++) {
				if ($i == "inet") {
					loc = $(i + 1)
					if ($(i + 2) == "peer")
						peer = $(i + 3)
				}
			}
			if (loc == "")
				next
			sub(/\/[0-9]+$/, "", loc)
			sub(/\/[0-9]+$/, "", peer)
			printf "%s %s %s\n", name, loc, peer
		}
	'
}

session_lines() {
	awk '$1 == "Id" { next } NF >= 3 { print $1, $3 }'
}

route_dev_from_text() {
	awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

route_src_from_text() {
	awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }'
}

parse_snapshot() {
	awk '
		/^cpu / {
			total = $2 + $3 + $4 + $5 + $6 + $7 + $8
			soft = $8
			have = 1
			next
		}
		/^[0-9]+$/ && !wseen {
			wire = $1
			wseen = 1
			next
		}
		$1 == "bound" {
			bound = $2
		}
		END {
			printf "%s %s %s %s\n", \
				(have ? total : "null"), (have ? soft : "null"), \
				(wseen ? wire : "null"), (bound != "" ? bound : "null")
		}
	'
}

parse_entries() {
	awk '
		function pad8(s) {
			while (length(s) < 8)
				s = "0" s
			return s
		}
		/ib1=/ {
			n++
			state = $2
			if (state == "BND")
				bnd++
			else if (state == "UNB")
				unb++
			for (i = 1; i <= NF; i++) {
				if ($i !~ /^ib1=/)
					continue
				h = pad8(substr($i, 5))
				hex[h] = 1
				if (index("89ABCDEFabcdef", substr(h, 3, 1)) > 0) {
					bit23++
					if (state == "BND")
						bnd23++
				}
			}
		}
		END {
			s = ""
			c = 0
			for (h in hex) {
				c++
				if (c <= 4)
					s = (s == "" ? "0x" h : s ",0x" h)
			}
			if (c > 4)
				s = s ",..."
			printf "%d %d %d %d %d %s\n", n + 0, bnd + 0, unb + 0, \
				bit23 + 0, bnd23 + 0, (s == "" ? "n/a" : s)
		}
	'
}

iperf_summary() {
	awk '
	BEGIN {
		cur = ""
		sbps = "null"; ssecs = "null"; sretr = "null"; rbps = "null"
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
		} else if (index(line, "\"seconds\":") == 1) {
			v = line
			sub(/^"seconds":[[:space:]]*/, "", v)
			if (cur == "s") ssecs = v
		} else if (index(line, "\"retransmits\":") == 1) {
			v = line
			sub(/^"retransmits":[[:space:]]*/, "", v)
			if (cur == "s") sretr = v
		}
	}
	END {
		printf "%s %s %s %s\n", sbps, ssecs, sretr, rbps
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

mbps() {
	case ${1-} in
	''|null|*[!0-9.eE+-]*) printf 'n/a' ;;
	*) awk -v b="$1" 'BEGIN { printf "%.3f", b / 1000000 }' ;;
	esac
}

or_na() {
	case ${1-} in
	''|null) printf 'n/a' ;;
	*) printf '%s' "$1" ;;
	esac
}

parse_args() {
	local key val

	while [ "$#" -gt 0 ]; do
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
		--*=*)
			key=${1%%=*}
			val=${1#*=}
			shift
			;;
		--*)
			key=$1
			if [ "$#" -lt 2 ]; then
				usage_error "$key needs a value"
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
		--wan-if) WAN_IF=$val ;;
		--peer) PEER=$val ;;
		--duration) DURATION=$val ;;
		--port) PORT=$val ;;
		--out) OUT=$val ;;
		*) usage_error "unknown option: $key" ;;
		esac
	done

	is_uint "$DURATION" || usage_error "--duration must be an integer"
	[ "$DURATION" -ge 1 ] && [ "$DURATION" -le 3600 ] ||
		usage_error "--duration must be 1..3600"
	is_uint "$PORT" || usage_error "--port must be an integer"
	[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] ||
		usage_error "--port must be 1..65535"
	is_uint "$MIN_PEER_MBPS" || usage_error "MIN_PEER_MBPS must be an integer"
	[ "$MIN_PEER_MBPS" -ge 1 ] || usage_error "MIN_PEER_MBPS must be positive"
	is_device "$DEVICE" || usage_error "--device must be USER@ADDR (no spaces)"
	is_ifname "$WAN_IF" || usage_error "--wan-if must be an interface name"
	if [ -n "$PEER" ] && ! is_ipv4 "$PEER"; then
		usage_error "--peer must be an IPv4 address"
	fi
}

dry_run() {
	local peer_display=${PEER:-<required>}

	printf '%s: dry run; nothing is executed (no SSH, no iperf3, no file)\n' "$PROG"
	printf '  device    %s\n' "$DEVICE"
	printf '  wan_if    %s\n' "$WAN_IF"
	printf '  peer      %s\n' "$peer_display"
	printf '  duration  %s s per arm\n' "$DURATION"
	printf '  port      %s\n' "$PORT"
	printf '  out       %s\n' "$OUT"
	printf '\n'
	printf 'gates (a failure prints BLOCKED and exits 2):\n'
	printf '  device WAN Ethernet and host PPPoE NIC speed < 2500 Mb/s -> BLOCKED;\n'
	printf '    1G is the software path and is not admitted by this bench.\n'
	printf '  /proc/net/pppoe on the router and on the host must show the session\n'
	printf '    on the WAN Ethernet (or a VLAN/bridge child of it) -> else BLOCKED.\n'
	printf '  the peer probe must deliver >= %s Mbit/s (a 1G peer -> BLOCKED).\n' \
		"$MIN_PEER_MBPS"
	printf '  the probe must produce a matching ppe/entries row -> else BLOCKED.\n'
	printf '  the original ppe/pppoe_decap value is restored from the EXIT trap.\n'
	printf '\n'
	printf 'three arms: ppe/pppoe_decap=0/1/2 (run sequentially, one at a time)\n'
	printf '  arm ppe/pppoe_decap=0: iperf3 -c %s -p %s -t %s -P 1 --cport <cport0> -J\n' \
		"$peer_display" "$PORT" "$DURATION"
	printf '  arm ppe/pppoe_decap=1: iperf3 -c %s -p %s -t %s -P 1 --cport <cport1> -J\n' \
		"$peer_display" "$PORT" "$DURATION"
	printf '  arm ppe/pppoe_decap=2: iperf3 -c %s -p %s -t %s -P 1 --cport <cport2> -J\n' \
		"$peer_display" "$PORT" "$DURATION"
	printf '\n'
	printf 'commands the real run would execute (in order):\n'
	printf '  ssh %s %s "id -u; cat /sys/class/net/%s/speed; cat /proc/net/pppoe"\n' \
		"$SSH_OPTS" "$DEVICE" "$WAN_IF"
	printf '  ip route get %s                    # host: must be dev <host-ppp>\n' \
		"$peer_display"
	printf '  ssh %s %s "ip route get %s; ip route get <host-ppp-ip>"\n' \
		"$SSH_OPTS" "$DEVICE" "$peer_display"
	printf '  ssh %s %s "cat %s; cat %s; cat %s"\n' \
		"$SSH_OPTS" "$DEVICE" "$KNOB" "$ENTRIES" "$USAGE"
	printf '  iperf3 -c %s -p %s -t %d -P 1 --cport <probe-cport> -J   # probe\n' \
		"$peer_display" "$PORT" "$PROBE_DURATION"
	printf '  ssh %s %s "grep -F <cport>->%s %s"   # ib1, BND/UNB, bit23\n' \
		"$SSH_OPTS" "$DEVICE" "$peer_display" "$ENTRIES"
	printf '  ssh %s %s "grep %s /proc/stat"      # softirq ticks\n' \
		"$SSH_OPTS" "$DEVICE" "'^cpu '"
	printf '  ssh %s %s "cat /sys/class/net/%s/statistics/rx_packets"\n' \
		"$SSH_OPTS" "$DEVICE" "$WAN_IF"
	printf '\n'
	printf 'samples per arm: sender_mbps, receiver_mbps, retr, softirq ticks,\n'
	printf '  softirq us per wire packet, ppe/entries ib1, state BND/UNB, bit23,\n'
	printf '  and the bnd_bit23 count (the decisive number).\n'
	printf '\n'
	printf 'cleanup (trap): write the saved original value back to\n'
	printf '  %s and read it back.\n' "$KNOB"
	printf 'no nft/flowtable change is made; the PPP interface is never added to a\n'
	printf 'flowtable device list (ppp0 is not an Ethernet ingress).\n'
	printf '\n'
	printf 'result: %s (TSV) and %s.raw.log\n' "$OUT" "$OUT"
}

preflight_local() {
	local c
	for c in ssh iperf3 ip awk grep tr mktemp; do
		command -v "$c" >/dev/null 2>&1 ||
			blocked "missing local command: $c"
	done
	if ! iperf3 --help 2>&1 | grep -q -- '--cport'; then
		blocked "local iperf3 has no --cport; cannot isolate the three arms"
	fi
	TIMEOUT_BIN=$(command -v timeout 2>/dev/null || true)
}

preflight_device() {
	dev true >/dev/null 2>&1 ||
		blocked "cannot SSH to $DEVICE (set --device or SSH_OPTS)"
	[ "$(dev 'id -u' 2>/dev/null)" = "0" ] ||
		blocked "$DEVICE does not give root; debugfs needs root"

	dev "test -e $KNOB" >/dev/null 2>&1 ||
		blocked "device is missing $KNOB (PPPoE-decap firmware not installed?)"
	dev "test -w $KNOB" >/dev/null 2>&1 ||
		blocked "device $KNOB is not writable"
	dev "test -r $ENTRIES" >/dev/null 2>&1 ||
		blocked "device is missing readable $ENTRIES"
	dev "test -r $USAGE" >/dev/null 2>&1 ||
		blocked "device is missing readable $USAGE"

	dev "test -e /sys/class/net/$WAN_IF" >/dev/null 2>&1 ||
		blocked "device has no interface $WAN_IF"
	case $WAN_IF in
	lan3|lan10g|wan|wan10g)
		;;
	ppp*|br-*|lo)
		blocked "--wan-if '$WAN_IF' is not a WAN Ethernet port; ppp0 must never be added to a flowtable"
		;;
	*)
		blocked "--wan-if '$WAN_IF' is not a WAN Ethernet port (accepts lan3, lan10g, wan, wan10g)"
		;;
	esac

	DEV_LINK=$(dev_speed "$WAN_IF")
	case $DEV_LINK in
	''|*[!0-9]*)
		blocked "cannot read the link speed of device $WAN_IF (link down?)"
		;;
	esac
	if [ "$DEV_LINK" -lt 2500 ]; then
		blocked "device $WAN_IF link is ${DEV_LINK} Mb/s < 2500; 1G is the software path and this bench does not admit it"
	fi

	DEV_SESSION_ID=
	DEV_SESSION_DEV=
	local sessions raw sid sdev count=0
	sessions=$(dev "cat /proc/net/pppoe 2>/dev/null") || sessions=
	raw=$(printf '%s\n' "$sessions" | session_lines)
	while read -r sid sdev; do
		[ -n "$sdev" ] || continue
		case $sdev in
		"$WAN_IF"|"$WAN_IF".*)
			;;
		br-*)
			dev "test -e /sys/class/net/$sdev/brif/$WAN_IF" \
				>/dev/null 2>&1 || continue
			;;
		*)
			continue
			;;
		esac
		count=$((count + 1))
		DEV_SESSION_ID=$sid
		DEV_SESSION_DEV=$sdev
	done <<EOF
$raw
EOF
	if [ "$count" -eq 0 ]; then
		blocked "no PPPoE session on device $WAN_IF; this harness does not create one"
	fi
	if [ "$count" -gt 1 ]; then
		blocked "multiple PPPoE sessions on device $WAN_IF; refusing an ambiguous bed"
	fi
}

preflight_host() {
	HOST_SESSION_ID=
	HOST_SESSION_DEV=
	local sessions raw sid sdev count=0
	sessions=$(cat /proc/net/pppoe 2>/dev/null) || sessions=
	raw=$(printf '%s\n' "$sessions" | session_lines)
	while read -r sid sdev; do
		[ -n "$sdev" ] || continue
		count=$((count + 1))
		HOST_SESSION_ID=$sid
		HOST_SESSION_DEV=$sdev
	done <<EOF
$raw
EOF
	if [ "$count" -eq 0 ]; then
		blocked "no PPPoE session in this namespace; run inside the access-concentrator netns that owns the session"
	fi
	if [ "$count" -gt 1 ]; then
		blocked "multiple PPPoE sessions in this namespace; refusing an ambiguous bed"
	fi
	case $HOST_SESSION_DEV in
	br-*)
		blocked "host PPPoE session is on bridge $HOST_SESSION_DEV; use the physical/VLAN access-concentrator interface"
		;;
	esac

	HOST_LINK=$(host_phy_speed "$HOST_SESSION_DEV")
	case $HOST_LINK in
	''|*[!0-9]*)
		blocked "cannot read the link speed of host PPPoE interface $HOST_SESSION_DEV"
		;;
	esac
	if [ "$HOST_LINK" -lt 2500 ]; then
		blocked "host PPPoE interface $HOST_SESSION_DEV link is ${HOST_LINK} Mb/s < 2500; the peer side must also be >=2.5G"
	fi

	local host_raw host_lines dev_raw dev_lines
	host_raw=$(for d in /sys/class/net/*; do
		i=${d##*/}
		[ "$(cat "$d/type" 2>/dev/null)" = "512" ] || continue
		ip -4 -o addr show dev "$i" 2>/dev/null
	done)
	host_lines=$(printf '%s\n' "$host_raw" | parse_ppp_addr_lines)
	[ -n "$host_lines" ] ||
		blocked "no IPv4 PPP interface on the host"

	# shellcheck disable=SC2016  # the loop must expand on the device, not here
	dev_raw=$(dev 'for d in /sys/class/net/*; do i=${d##*/}; [ "$(cat "$d/type" 2>/dev/null)" = 512 ] || continue; ip -4 -o addr show dev "$i" 2>/dev/null; done') ||
		dev_raw=
	dev_lines=$(printf '%s\n' "$dev_raw" | parse_ppp_addr_lines)
	[ -n "$dev_lines" ] ||
		blocked "no IPv4 PPP interface on the device"

	local match='' hif hloc hpeer dif dloc dpeer
	while read -r hif hloc hpeer; do
		[ -n "$hif" ] || continue
		while read -r dif dloc dpeer; do
			[ -n "$dif" ] || continue
			if [ "$hloc" = "$dpeer" ] && [ "$hpeer" = "$dloc" ]; then
				[ -z "$match" ] ||
					blocked "multiple host/device PPP peer pairs match; refusing an ambiguous bed"
				match="$hif $hloc $hpeer $dif $dloc $dpeer"
			fi
		done <<EOF
$dev_lines
EOF
	done <<EOF
$host_lines
EOF
	[ -n "$match" ] ||
		blocked "host PPP peer does not mirror the device PPP session; --wan-if is probably not the session this host serves"

	# Intentional word splitting of the six fields collected above.
	# shellcheck disable=SC2086
	set -- $match
	HOST_PPP=$1
	HOST_LOCAL=$2
	HOST_PEER_ADDR=$3
	DEV_PPP=$4
	DEV_LOCAL=$5
	DEV_PEER_ADDR=$6
}

preflight_routes() {
	local route rdev rsrc
	route=$(ip route get "$PEER" 2>/dev/null) || route=
	rdev=$(printf '%s\n' "$route" | route_dev_from_text)
	rsrc=$(printf '%s\n' "$route" | route_src_from_text)
	[ -n "$rdev" ] ||
		blocked "host has no route to peer $PEER"
	[ "$rdev" = "$HOST_PPP" ] ||
		blocked "host route to $PEER uses $rdev, not the PPPoE interface $HOST_PPP; the peer must be reached through the device"
	if [ -n "$rsrc" ] && [ "$rsrc" != "$HOST_LOCAL" ]; then
		blocked "host route to $PEER uses source $rsrc, not the PPP address $HOST_LOCAL"
	fi

	local dev_route dev_rdev
	dev_route=$(dev "ip route get $PEER 2>/dev/null") || dev_route=
	dev_rdev=$(printf '%s\n' "$dev_route" | route_dev_from_text)
	[ -n "$dev_rdev" ] ||
		blocked "device has no route to peer $PEER"
	case $dev_rdev in
	"$DEV_PPP"|ppp*)
		blocked "device route to $PEER egresses PPP interface $dev_rdev; the peer must be on the LAN side"
		;;
	"$WAN_IF"|"$WAN_IF".*)
		blocked "device route to $PEER egresses WAN Ethernet $dev_rdev; the peer must be on the LAN side"
		;;
	esac

	local back_route back_dev
	back_route=$(dev "ip route get $HOST_LOCAL 2>/dev/null") || back_route=
	back_dev=$(printf '%s\n' "$back_route" | route_dev_from_text)
	[ "$back_dev" = "$DEV_PPP" ] ||
		blocked "device return route to $HOST_LOCAL uses ${back_dev:-none}, not $DEV_PPP; the PPPoE return path is not usable"
}

preflight_ppe() {
	local knob ipf flowtables
	knob=$(dev "cat $KNOB 2>/dev/null" | tr -d '[:space:]') || knob=
	case $knob in
	0|1|2) ;;
	*) blocked "unexpected $KNOB value '${knob:-unreadable}'" ;;
	esac
	KNOB_ORIG=$knob
	KNOB_SAVED=1

	ipf=$(dev "cat /proc/sys/net/ipv4/ip_forward 2>/dev/null" | tr -d '[:space:]') || ipf=
	[ "$ipf" = "1" ] ||
		blocked "device ip_forward=${ipf:-unknown}; the peer flow must be forwarded, not terminated on the router"

	BIND_RATE=$(dev "cat $BIND_RATE_FILE 2>/dev/null" | head -n 1) || BIND_RATE=
	flowtables=$(dev "nft list flowtables 2>/dev/null") || flowtables=
	if [ -n "$flowtables" ] && ! printf '%s\n' "$flowtables" | grep -q 'flags offload'; then
		note "warning: no nft flowtable with 'flags offload' was found; the probe will decide whether PPE sees the flow"
	fi
}

write_knob() {
	local want=$1 got
	dev "printf '%s\n' '$want' > $KNOB" >/dev/null 2>&1 ||
		die "cannot write $KNOB"
	got=$(dev "cat $KNOB 2>/dev/null" | tr -d '[:space:]') || got=
	[ "$got" = "$want" ] ||
		die "knob readback '$got' != '$want'"
	log "knob=$want readback=$got"
}

restore_knob() {
	local got
	[ "$KNOB_SAVED" = "1" ] || return 0
	if ! dev "printf '%s\n' '$KNOB_ORIG' > $KNOB" >/dev/null 2>&1; then
		say "!! could not write $KNOB back to $KNOB_ORIG"
		return 1
	fi
	got=$(dev "cat $KNOB 2>/dev/null" | tr -d '[:space:]') || got=
	if [ "$got" != "$KNOB_ORIG" ]; then
		say "!! restore readback '$got' != '$KNOB_ORIG'"
		return 1
	fi
	KNOB_SAVED=0
	say "restored ppe/pppoe_decap=$KNOB_ORIG"
	return 0
}

# shellcheck disable=SC2329  # invoked through the EXIT/INT/TERM/HUP traps
cleanup() {
	[ "$CLEANED" = "0" ] || return 0
	CLEANED=1
	if [ "$KNOB_SAVED" = "1" ]; then
		restore_knob || true
	fi
	if [ -n "${TMPDIR_RUN:-}" ] && [ -d "$TMPDIR_RUN" ]; then
		rm -rf -- "$TMPDIR_RUN"
	fi
	return 0
}

run_iperf() {
	local cport=$1 dur=$2 json=$3 st
	log "iperf3 -c $PEER -p $PORT -t $dur -P 1 --cport $cport"
	if [ -n "${TIMEOUT_BIN:-}" ]; then
		"$TIMEOUT_BIN" $((dur + 30)) iperf3 -c "$PEER" -p "$PORT" \
			-t "$dur" -P 1 --cport "$cport" -J --connect-timeout 5000 \
			>"$json" 2>"$json.err"
	else
		iperf3 -c "$PEER" -p "$PORT" -t "$dur" -P 1 --cport "$cport" \
			-J --connect-timeout 5000 >"$json" 2>"$json.err"
	fi
	st=$?
	log "iperf3 exit=$st"
	return "$st"
}

# us of softirq per wire packet, from the softirq tick delta alone.
#
# The aggregate `cpu ` line is a sum over every core, so scaling it by the
# wall clock divides the answer by ncpu: a 4-core board reports a quarter of
# the real cost.  Ticks / HZ is seconds of softirq, and seconds / packets is
# the per-packet cost, with no core count in it at all.
softirq_us_per_wire() {
	local soft_ticks=$1 wire_pkts=$2 hz=${3:-}
	case $hz in
	'' | *[!0-9]* | 0) hz=100 ;;
	esac
	case $soft_ticks in
	'' | *[!0-9]*) return 1 ;;
	esac
	case $wire_pkts in
	'' | *[!0-9]* | 0) return 1 ;;
	esac
	awk -v s="$soft_ticks" -v w="$wire_pkts" -v hz="$hz" \
		'BEGIN { printf "%.2f", s * 1000000 / (hz * w) }'
}

probe_peer() {
	local json="$TMPDIR_RUN/probe.json"
	local st sbps ssecs sret rbps
	local receiver entries pn pbnd punb pbit23 pbnd23 pib1

	write_knob 1
	run_iperf "$PROBE_CPORT" "$PROBE_DURATION" "$json"
	st=$?
	read -r sbps ssecs sret rbps <<EOF
$(iperf_summary "$json")
EOF
	receiver=$(mbps "$rbps")
	if [ "$receiver" = "n/a" ]; then
		local err
		err=$(iperf_error "$json" 2>/dev/null) || err=
		blocked "peer iperf3 probe failed (exit $st): ${err:-no usable sum_received}"
	fi
	if ! awk -v m="$receiver" -v min="$MIN_PEER_MBPS" \
		'BEGIN { exit !(m + 0 >= min + 0) }'; then
		blocked "peer probe delivered ${receiver} Mbit/s < ${MIN_PEER_MBPS} Mbit/s; need a >=2.5G peer"
	fi

	entries=$(dev_capture "probe-entries" \
		"grep -F ':$PROBE_CPORT->$PEER' $ENTRIES 2>/dev/null") || entries=
	read -r pn pbnd punb pbit23 pbnd23 pib1 <<EOF
$(parse_entries <<< "$entries")
EOF
	if [ "${pn:-0}" -eq 0 ]; then
		blocked "no PPE entry for the probe flow; flowtable/PPE is not offloading $WAN_IF (no BND/bit23 number would be valid)"
	fi
	PROBE_SUMMARY="decap=1 ${receiver} Mbit/s, entries=${pn} BND=${pbnd:-0} UNB=${punb:-0} bit23=${pbit23:-0} bnd_bit23=${pbnd23:-0} ib1=${pib1:-n/a}"
	say "probe: $PROBE_SUMMARY"
}

setup_output() {
	local out_dir
	out_dir=$(dirname -- "$OUT")
	mkdir -p -- "$out_dir" || die "cannot create output directory $out_dir"
	: >"$OUT" || die "cannot write $OUT"
	RAW_LOG="${OUT}.raw.log"
	: >"$RAW_LOG" || die "cannot write $RAW_LOG"

	{
		printf '# pppoe-decap-hw-bench v1\n'
		printf '# date %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf '# cmdline %s\n' "$CMDLINE"
		printf '# device %s wan_if %s link_mbps %s\n' \
			"$DEVICE" "$WAN_IF" "$DEV_LINK"
		printf '# host_pppoe_dev %s session %s link_mbps %s ppp %s local %s peer %s\n' \
			"$HOST_SESSION_DEV" "$HOST_SESSION_ID" "$HOST_LINK" "$HOST_PPP" \
			"$HOST_LOCAL" "$HOST_PEER_ADDR"
		printf '# device_pppoe_dev %s session %s ppp %s local %s peer %s\n' \
			"$DEV_SESSION_DEV" "$DEV_SESSION_ID" "$DEV_PPP" \
			"$DEV_LOCAL" "$DEV_PEER_ADDR"
		printf '# peer %s port %s duration_s %s min_peer_mbps %s\n' \
			"$PEER" "$PORT" "$DURATION" "$MIN_PEER_MBPS"
		printf '# ppe_pppoe_decap_original %s bind_rate %s\n' \
			"$KNOB_ORIG" "$(or_na "$BIND_RATE")"
		printf '# probe %s\n' "$PROBE_SUMMARY"
		printf '# 1G links are refused (<2500 Mb/s); no nft/flowtable change; knob restored in trap\n'
		printf 'arm\tdecap\tsender_mbps\treceiver_mbps\tretr\tseconds\tsoftirq_ticks\tsoftirq_share\tsoftirq_us_per_wire\twire_pkts\tppe_entries\tBND\tUNB\tbit23\tbnd_bit23\tib1\tstatus\n'
	} >>"$OUT"

	{
		printf '== pppoe-decap-hw-bench ==\n'
		printf 'cmdline %s\n' "$CMDLINE"
		printf 'date %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf 'device %s wan_if %s link_mbps %s\n' \
			"$DEVICE" "$WAN_IF" "$DEV_LINK"
		printf 'host_pppoe_dev %s session %s link_mbps %s ppp %s local %s peer %s\n' \
			"$HOST_SESSION_DEV" "$HOST_SESSION_ID" "$HOST_LINK" "$HOST_PPP" \
			"$HOST_LOCAL" "$HOST_PEER_ADDR"
		printf 'device_pppoe_dev %s session %s ppp %s local %s peer %s\n' \
			"$DEV_SESSION_DEV" "$DEV_SESSION_ID" "$DEV_PPP" \
			"$DEV_LOCAL" "$DEV_PEER_ADDR"
		printf 'peer %s port %s duration_s %s min_peer_mbps %s\n' \
			"$PEER" "$PORT" "$DURATION" "$MIN_PEER_MBPS"
		printf 'ppe_pppoe_decap_original %s bind_rate %s\n' \
			"$KNOB_ORIG" "$(or_na "$BIND_RATE")"
		printf 'probe %s\n' "$PROBE_SUMMARY"
	} >>"$RAW_LOG"
	say "result: $OUT"
	say "raw: $RAW_LOG"
}

run_arm() {
	local k=$1 cport=$2
	local before after json entries st
	local b_total b_soft b_wire b_bound a_total a_soft a_wire a_bound
	local sbps ssecs sret rbps
	local sender receiver retr secs total_ticks soft_ticks wire_pkts
	local share us cost bound_delta n bnd unb bit23 bnd23 ib1s status

	json="$TMPDIR_RUN/arm$k.json"
	write_knob "$k"
	before=$(dev_capture "arm$k-before" \
		"grep '^cpu ' /proc/stat; cat /sys/class/net/$WAN_IF/statistics/rx_packets; cat $USAGE") || before=
	run_iperf "$cport" "$DURATION" "$json"
	st=$?
	after=$(dev_capture "arm$k-after" \
		"grep '^cpu ' /proc/stat; cat /sys/class/net/$WAN_IF/statistics/rx_packets; cat $USAGE") || after=
	entries=$(dev_capture "arm$k-entries" \
		"grep -F ':$cport->$PEER' $ENTRIES 2>/dev/null") || entries=

	b_total=null b_soft=null b_wire=null b_bound=null
	read -r b_total b_soft b_wire b_bound <<EOF
$(parse_snapshot <<< "$before")
EOF
	a_total=null a_soft=null a_wire=null a_bound=null
	read -r a_total a_soft a_wire a_bound <<EOF
$(parse_snapshot <<< "$after")
EOF

	n=0 bnd=0 unb=0 bit23=0 bnd23=0 ib1s=n/a
	read -r n bnd unb bit23 bnd23 ib1s <<EOF
$(parse_entries <<< "$entries")
EOF

	sbps=null ssecs=null sret=null rbps=null
	read -r sbps ssecs sret rbps <<EOF
$(iperf_summary "$json")
EOF
	sender=$(mbps "$sbps")
	receiver=$(mbps "$rbps")
	retr=$(or_na "$sret")
	secs=$(or_na "$ssecs")
	case $secs in
	''|n/a|*[!0-9.]*) secs=0 ;;
	esac

	total_ticks=null soft_ticks=null wire_pkts=null bound_delta=null
	if [ "$b_total" != "null" ] && [ "$a_total" != "null" ]; then
		total_ticks=$((a_total - b_total))
		soft_ticks=$((a_soft - b_soft))
	fi
	if [ "$b_wire" != "null" ] && [ "$a_wire" != "null" ]; then
		wire_pkts=$((a_wire - b_wire))
	fi
	if [ "$b_bound" != "null" ] && [ "$a_bound" != "null" ]; then
		bound_delta=$((a_bound - b_bound))
	fi

	# share is the aggregate softirq share of all CPUs; it is reported for
	# context only and is not a per-core number.
	share=n/a
	us=n/a
	if [ "$total_ticks" != "null" ] && [ "$total_ticks" -gt 0 ] &&
	   [ "$soft_ticks" != "null" ] && [ "$soft_ticks" -ge 0 ]; then
		share=$(awk -v s="$soft_ticks" -v t="$total_ticks" \
			'BEGIN { printf "%.4f", s / t }')
		if cost=$(softirq_us_per_wire "$soft_ticks" "$wire_pkts" "$BENCH_HZ"); then
			us=$cost
		fi
	fi

	status=ok
	if [ "$st" -ne 0 ] || [ "$receiver" = "n/a" ]; then
		status=failed
	elif [ "$n" -eq 0 ]; then
		status=no-entry
	elif [ "$total_ticks" = "null" ] || [ "$total_ticks" -le 0 ] ||
	     [ "$soft_ticks" = "null" ] || [ "$soft_ticks" -lt 0 ]; then
		status=invalid
	fi

	{
		printf '### arm decap=%s iperf_rc=%s cport=%s\n' "$k" "$st" "$cport"
		printf 'iperf sender=%s receiver=%s retr=%s seconds=%s\n' \
			"$sender" "$receiver" "$retr" "$secs"
		if [ "$st" -ne 0 ]; then
			local ierr
			ierr=$(iperf_error "$json" 2>/dev/null) || ierr=
			printf 'iperf error: %s\n' "${ierr:-exit $st}"
		fi
		printf 'softirq total_ticks=%s soft_ticks=%s share=%s wire_pkts=%s us_per_wire=%s bound_delta=%s\n' \
			"$total_ticks" "$soft_ticks" "$share" "$wire_pkts" "$us" "$bound_delta"
		printf 'ppe entries=%s BND=%s UNB=%s bit23=%s bnd_bit23=%s ib1=%s\n' \
			"$n" "$bnd" "$unb" "$bit23" "$bnd23" "$ib1s"
		printf 'raw entries:\n%s\n' "$entries"
	} >>"$RAW_LOG"

	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$k" "$k" "$sender" "$receiver" "$retr" "$secs" \
		"$total_ticks" "$share" "$us" "$wire_pkts" "$n" "$bnd" "$unb" \
		"$bit23" "$bnd23" "$ib1s" "$status" >>"$OUT"

	say "arm decap=$k sender=${sender}M receiver=${receiver}M retr=${retr} softirq_ticks=${total_ticks}/${soft_ticks} softirq_us_per_wire=${us} ppe_entries=${n} BND=${bnd} UNB=${unb} bit23=${bit23} bnd_bit23=${bnd23} ib1=${ib1s} status=${status}"

	ARM_N[$k]=$n
	ARM_BND[$k]=$bnd
	ARM_BIT23[$k]=$bit23
	ARM_BND23[$k]=$bnd23
	ARM_STATUS[$k]=$status
}

# $1 is main's failure accumulator (restore_knob and run_arm both feed it).
# This function used to keep its own rc, so a failed knob restore still wrote
# "# verdict PASS" into the TSV while main exited 1: the artifact and the exit
# code disagreed and only the exit code was right.  Taking rc alone was not
# enough either: the say() line below still printed PASS whenever the arms
# looked good, so the TSV said FAIL while the log said PASS.
verdict() {
	local rc=${1:-0} primary=
	[ "$rc" -eq 0 ] || rc=1
	if [ "${ARM_STATUS[1]:-missing}" = "ok" ] && [ "${ARM_BND23[1]:-0}" -gt 0 ]; then
		primary=1
	elif [ "${ARM_STATUS[2]:-missing}" = "ok" ] && [ "${ARM_BND23[2]:-0}" -gt 0 ]; then
		primary=2
	fi

	if [ -n "$primary" ]; then
		# The arms looking right is not enough: main's accumulator also covers
		# a failed restore_knob, and the log is the artifact an operator reads.
		if [ "$rc" -eq 0 ]; then
			say "verdict: PASS - decap=${primary} produced ${ARM_BND23[$primary]} BND entries with ib1 bit23 set (of ${ARM_N[$primary]} matching entries)"
		else
			say "verdict: FAIL - decap=${primary} produced ${ARM_BND23[$primary]} BND entries with ib1 bit23 set, but the run failed elsewhere (see the restore/arm notes above)"
		fi
		if [ "${ARM_STATUS[1]:-missing}" != "ok" ]; then
			say "verdict: note - the decap=1 arm status is ${ARM_STATUS[1]:-missing}; the verdict rests on decap=${primary}"
		fi
	elif [ "${ARM_STATUS[1]:-missing}" != "ok" ]; then
		say "verdict: FAIL - the decap=1 arm did not complete (status=${ARM_STATUS[1]:-missing})"
		rc=1
	elif [ "${ARM_N[1]:-0}" -eq 0 ]; then
		say "verdict: FAIL - the decap=1 arm produced no ppe/entries row for the flow"
		rc=1
	elif [ "${ARM_BIT23[1]:-0}" -gt 0 ]; then
		say "verdict: PARTIAL - ib1 bit23 is set on ${ARM_BIT23[1]} decap=1 entries but only ${ARM_BND[1]:-0} are BND; the entry did not bind"
		rc=1
	else
		say "verdict: FAIL - ${ARM_BND[1]:-0} BND decap=1 entries, but ib1 bit23 is clear on all of them"
		rc=1
	fi

	if [ "${ARM_BIT23[0]:-0}" -gt 0 ]; then
		say "warning: the decap=0 control also shows ib1 bit23; the control is contaminated or the knob did not affect new entries"
	fi
	if [ "${ARM_STATUS[0]:-missing}" != "ok" ]; then
		say "note: the decap=0 control did not complete (status=${ARM_STATUS[0]:-missing}); its arm is recorded, not used for the verdict"
	fi

	printf '# verdict %s\n' "$([ "$rc" -eq 0 ] && echo PASS || echo FAIL)" >>"$OUT"
	return "$rc"
}

main() {
	CMDLINE=$(printf '%q ' "$0" "$@")
	parse_args "$@"
	if [ -z "$OUT" ]; then
		OUT="pppoe-decap-hw-bench-$(date +%Y%m%d-%H%M%S).tsv"
	fi
	if [ "$DRY_RUN" = "1" ]; then
		dry_run
		exit 0
	fi
	[ -n "$PEER" ] || usage_error "--peer is required for a real run"
	if [ -e "$OUT" ]; then
		blocked "refusing to overwrite existing $OUT"
	fi

	trap 'cleanup' EXIT
	trap 'exit 130' INT TERM HUP

	preflight_local
	preflight_device
	preflight_host
	preflight_routes
	preflight_ppe

	TMPDIR_RUN=$(mktemp -d "${TMPDIR:-/tmp}/pppoe-decap-hw-bench.XXXXXX") ||
		die "cannot create a temporary directory"
	CPORT_BASE=$((20000 + RANDOM % 20000))
	PROBE_CPORT=$((CPORT_BASE + 3))

	probe_peer
	setup_output

	local k rc=0
	for k in 0 1 2; do
		run_arm "$k" "$((CPORT_BASE + k))"
	done

	restore_knob || rc=1
	verdict "$rc" || rc=1
	say "result: $OUT"
	say "raw: $RAW_LOG"
	exit "$rc"
}

main "$@"
