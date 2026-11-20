#!/bin/sh
#
# multi-client.sh - 2-3 client concurrent aggregation harness (A and B paths).
#
# What this answers: the single-client A path tops out at 1.33-1.34 Gbit/s.
# The open question is whether two or three clients aggregate, and where the
# aggregation wall is (client, air, AP CPU, NPU token/queue, wired feeder).
# This harness runs one fixed window with all requested clients active at the
# same time and reports per-client and aggregate AP-side throughput.
#
# Topology
#
#   A path:  AP (this script)  --- Wi-Fi --->  client 1, client 2, ...
#            each client's SOURCE command runs locally on the AP.
#
#   B path:  feeder host  --- wired --->  AP (this script)  --- Wi-Fi --->  clients
#            each client's SOURCE command runs on the feeder host over a
#            non-interactive ssh; the AP forwards/bridges the feeder traffic to
#            the clients.  A 2.5G feeder on lan10g is the intended B path.
#
# The AP is always the machine that runs this script: the counters that make
# the aggregation number (iw station dump and mt76 token/queue debugfs) are
# local and read without ssh.  Only the B-path source commands are remote.
#
# Protocol (fixed, so runs stay comparable)
#   1. Resolve the requested MACs to AP interfaces (a client may be on 5 GHz
#      or 6 GHz; each client is looked up on every AP interface).
#   2. Refuse to run unless at least two requested clients are associated.
#      Otherwise print "SKIP: ..." and exit 0 without sending traffic.
#   3. Per arm: snapshot station dump, token_info and hw-queues; start one
#      per-client source (PROCS copies) for all clients concurrently.
#   4. Warm up WARMUP seconds, then take the expected NSS from the last
#      warm-up sample.
#   5. Measure one window of about WINDOW seconds (the exact seconds are
#      recorded and used for Gbit/s): read each client's tx/rx bytes, retries
#      and signal from "iw dev IFACE station dump", plus token_info every
#      INTERVAL.
#   6. After the window, compute the per-client deltas and the aggregate:
#      aggregate Gbit/s is total bytes * 8 / measured seconds, not the sum of
#      rounded per-client rates.
#   7. Abort the arm (and stop the run) if a client disconnects, its NSS goes
#      missing or changes, or a source process exits before the window ends.
#
# The per-client source
#   --source 'COMMAND' is a shell command.  It is run once per requested client
#   (and PROCS times per client) with these variables exported:
#
#     CLIENT        the client MAC (lowercase, colon separated)
#     CLIENT_IP     the client address found in ARP/neigh, or --client-ip
#     IFACE         the AP interface the client is associated on
#     ARM           a or b
#     WINDOW        the measured window in seconds
#     WARMUP        the warm-up in seconds
#     SOURCE_SECS   WARMUP + WINDOW + 5: the command must keep sending at
#                   least this long; the harness kills it after the window
#     PROCS         number of copies of this source for the client
#     CLIENT_INDEX  1, 2 or 3
#     FEEDER        ssh target for the B arm (empty for A)
#     FEEDER_IF     --feeder-if (empty when unset)
#     FEEDER_IP     IPv4 on FEEDER_IF detected on the feeder (B arm only)
#     OUT           the arm directory (A arm only; a local AP path)
#
#   --source may be repeated: the Nth source belongs to the Nth client.  One
#   --source is shared by every client; if there are fewer sources than
#   clients, the last source is reused.  Without --source the default is one
#   "iperf3 -c $CLIENT_IP -t $SOURCE_SECS -f m" per client, which needs iperf3
#   on the AP and an iperf3 server on every client.  The lab board may not have
#   iperf3; the intended local source is /tmp/ringblast, e.g.
#
#     --source '/tmp/ringblast "$IFACE" "$CLIENT" "$CLIENT_IP" "$SOURCE_SECS"'
#
#   The source is executed by "sh -c" as the invoking user.  It is a lab
#   command, not input to be taken from an untrusted party.  Keep the source
#   in the foreground and let it run for at least SOURCE_SECS: a command that
#   daemonizes and returns is treated as a dead source.  After the window the
#   harness kills the source pid and every descendant it can see in /proc; a
#   remote B-arm process behind ssh can outlive the ssh client on the feeder,
#   so a B-arm source must still terminate itself within SOURCE_SECS (iperf3
#   -t does).
#
# A and B arms
#   --arm a     local source on the AP (default).
#   --arm b     source commands run on --feeder over ssh.  The feeder must be
#               reachable with BatchMode=yes and must have a route to the
#               clients through the feeder NIC.  When --feeder-if is given, the
#               script reads its speed and the route to each client with
#               read-only commands and records them; a speed below 2500 Mb/s is
#               recorded as "feeder-limited", not hidden.
#   --arm both  run A then B with the same client set and window.
#
# The B arm does not start an iperf3 server anywhere and does not configure the
# feeder; it only runs the source commands the user supplies.  A feeder flow
# must be addressed to the client (the AP is a bridge/forwarder), so a B-arm
# source is normally "iperf3 -c $CLIENT_IP" (or ringblast-style raw frames) run
# on the feeder.
#
# What is sampled (all read-only)
#   iw dev IFACE station dump
#       associated, tx/rx bytes, tx retries, tx failed, signal/signal avg, and
#       the TX/RX bitrate line (NSS and width)
#   /sys/kernel/debug/ieee80211/*/mt76/token_info
#       SW token count / pool size, NPU RX queue depths, per-band TX queue
#       depth and npu/dma type
#   /sys/kernel/debug/ieee80211/*/mt76/hw-queues
#   /sys/kernel/debug/ieee80211/*/netdev:*/stations/<mac>/hw-queues
#       raw PLE/PSE and per-STA queue state, before and after each arm
#
# Interpretation limits
#   * tx/rx bytes are mac80211 L2 counters: they include retransmissions and
#     are not airtime.  A raw-frame source can produce a number above the
#     reported PHY rate; read the retries and the source log.
#   * token_info's npu_rx queued fields idle near ndesc-1 (the ring is kept
#     full); token_count (in-flight), the TX band queues and hw-queues are the
#     congestion indicators, not the raw npu_rx queued value.
#   * an MLO client can expose more than one bitrate line; the parser keeps the
#     last TX bitrate line, so use single-link clients for aggregation runs.
#
# Safety: no UCI read/write, no wifi reload, no module load/unload, no firmware
# or flash write, no reboot, no sysfs/debugfs write.  The only writes are the
# output directory and the source logs inside it.  Real traffic is sent only
# when the script is run without --dry-run and with two or more associated
# clients.
#
# Output
#   $OUT/meta.txt                 run identity and requested clients
#   $OUT/result.tsv               per-client and aggregate rows, all arms
#   $OUT/arm-<a|b>/result.tsv     the arm's rows
#   $OUT/arm-<a|b>/samples.tsv    per-interval station samples
#   $OUT/arm-<a|b>/npu.tsv        per-interval token_info samples
#   $OUT/arm-<a|b>/station-<before|after>.txt
#   $OUT/arm-<a|b>/token-info-<before|after>.txt
#   $OUT/arm-<a|b>/hw-queues-<before|after>.txt
#   $OUT/arm-<a|b>/sta-hw-queues-<before|after>.txt
#   $OUT/arm-<a|b>/source-<index>-<copy>.log
#   $OUT/run.log                  chronological harness log
#
# Exit status
#   0  all requested arms valid, or a clean SKIP (fewer than two clients)
#   1  setup/run failure (no iw, no AP interface, feeder ssh, output exists)
#   2  invalid arguments
#   3  measured, but an arm was aborted (NSS/disconnect/source death)
#
# POSIX sh only (busybox ash on the board).  Tested with sh -n, --help,
# --dry-run, a board dry run, the board's clean-skip path, and a deterministic
# iw/ssh/token_info stub run covering A, B, both, 2 and 3 clients, per-client
# sources, PROCS>1, NSS drop, disconnect and source death.  No live 2+ client
# aggregation was measured: the lab board had no stations associated.
#
# Examples
#   # read-only plan; no clients are needed and nothing is executed
#   ./scripts/wireless/multi-client.sh --dry-run
#
#   # A arm, 2 clients, the lab raw-frame source on the AP
#   ./scripts/wireless/multi-client.sh \
#       --client f8:fe:5e:a1:6f:a8 --client 9c:2f:9d:11:22:33 \
#       --source '/tmp/ringblast "$IFACE" "$CLIENT" "$CLIENT_IP" "$SOURCE_SECS"' \
#       --arm a --window 10
#
#   # B arm, same two clients, sources on the 2.5G feeder
#   ./scripts/wireless/multi-client.sh \
#       --client f8:fe:5e:a1:6f:a8 --client 9c:2f:9d:11:22:33 \
#       --source 'iperf3 -c "$CLIENT_IP" -t "$SOURCE_SECS" -f m' \
#       --arm b --feeder root@192.168.1.50 --feeder-if enp1s0 --window 10
#
#   # both arms, one shared source, explicit addresses
#   ./scripts/wireless/multi-client.sh \
#       --client f8:fe:5e:a1:6f:a8 --client 9c:2f:9d:11:22:33 \
#       --client 3c:22:fb:aa:bb:cc \
#       --client-ip f8:fe:5e:a1:6f:a8=192.168.1.236 \
#       --arm both --feeder root@192.168.1.50 --window 15
#
# Test hook: DEBUGFS_ROOT overrides the /sys/kernel/debug prefix so the
# parser can be exercised against a fake tree.  It is not needed on a board.
#
set -u

PROG=${0##*/}
SCHEMA=multi-client-aggregation/v1

CLIENT_COUNT=0
CLIENT1='' CLIENT2='' CLIENT3=''
SOURCE_COUNT=0
SOURCE1='' SOURCE2='' SOURCE3=''
IP_OVERRIDE_COUNT=0
IP_OVERRIDE_MAC1='' IP_OVERRIDE_ADDR1=''
IP_OVERRIDE_MAC2='' IP_OVERRIDE_ADDR2=''
IP_OVERRIDE_MAC3='' IP_OVERRIDE_ADDR3=''

ARM=${ARM:-a}
FEEDER=${FEEDER:-}
FEEDER_IF=${FEEDER_IF:-}
WINDOW=${WINDOW:-10}
WARMUP=${WARMUP:-5}
INTERVAL=${INTERVAL:-1}
PROCS=${PROCS:-1}
OUT=${OUT:-}
DRY_RUN=0
DEBUGFS_ROOT=${DEBUGFS_ROOT:-/sys/kernel/debug}

# shellcheck disable=SC2016  # expanded by the per-client shell, not here
DEFAULT_SOURCE='iperf3 -c "$CLIENT_IP" -t "$SOURCE_SECS" -f m'

# Client state filled by resolve_clients.
C_ACTIVE1=0 C_ACTIVE2=0 C_ACTIVE3=0
C_IFACE1='' C_IFACE2='' C_IFACE3=''
C_IP1='' C_IP2='' C_IP3=''
ACTIVE_IDX_LIST=
ACTIVE_COUNT=0
AP_IFACES=

# Arm state.
ARM_DIR=
SAMPLES=
NPU_SAMPLES=
ARM_STATUS=
ARM_REASON=
SRC_PIDS=
SRC_EXPECTED=0
EXPECTED_NSS_FILE=
SAMPLE_ERROR=
LOG=


usage() {
	cat <<'EOF'
Usage: multi-client.sh [options] MAC MAC [MAC]

2-3 client concurrent aggregation harness for the A path (source on the AP)
and the B path (source on a wired feeder host).  All clients run at the same
time for one fixed window; throughput comes from AP-side iw station dump
tx/rx byte deltas, and token_info/hw-queues are sampled around the window.

A real run needs 2 or 3 associated clients.  With fewer than two it prints a
clean "SKIP:" and exits 0 without sending traffic or creating output.

Options:
  --client MAC          add a client (2-3 required for a real run; a MAC may
                        also be given as a positional argument)
  --source CMD          per-client source command; repeat once per client, or
                        once to share.  See the header for exported variables.
                        Default: iperf3 -c $CLIENT_IP (needs iperf3 on the AP)
  --client-ip MAC=IP    explicit client address, overriding the ARP/neigh
                        lookup; repeat for more clients (IPv4 or IPv6)
  --arm a|b|both        arm to run (default a)
  --feeder USER@HOST    ssh target that runs the B-arm sources; ssh must work
                        non-interactively (BatchMode=yes)
  --feeder-if IFACE     feeder NIC used for the B-path; records its speed and
                        the route to each client, and exports FEEDER_IP
  --window SEC          measured window (default 10)
  --warmup SEC          warm-up before the window (default 5)
  --interval SEC        station/NPU sample interval (default 1, <= window)
  --procs N             copies of each client's source (default 1)
  --out DIR             output directory (default /tmp/multi-client-<UTC>);
                        an existing directory is never reused
  --dry-run             print the plan and every command; do not send traffic,
                        do not ssh, do not read the device, do not write files
  -h, --help            this text

The A arm runs each source on the AP.  The B arm runs the same source on
--feeder over ssh; the feeder must route to the clients through the wired
uplink.  When --feeder-if is given, a link below 2500 Mb/s is recorded as
feeder-limited; it is not hidden or promoted to a Wi-Fi result.

Per-client output: arm, MAC, AP interface, channel, width, NSS, signal,
tx/rx bytes, seconds, tx/rx Gbit/s, retries, status.  The aggregate row uses
total bytes / measured seconds, not the sum of rounded per-client rates.

An arm is aborted if a client disconnects, its NSS disappears or changes, or
a source process exits before the window ends.  A clean skip (fewer than two
associated clients) is not an error.

Safety: this script never writes UCI, never reloads Wi-Fi, never loads a
module, never writes firmware/flash, never reboots and never writes
sysfs/debugfs.  It writes only the output directory and the source logs.

Exit status: 0 valid run or clean SKIP, 1 setup/run failure, 2 bad arguments,
3 measured but aborted.

Examples:
  ./scripts/wireless/multi-client.sh --dry-run
  ./scripts/wireless/multi-client.sh \
      --client f8:fe:5e:a1:6f:a8 --client 9c:2f:9d:11:22:33 \
      --source '/tmp/ringblast "$IFACE" "$CLIENT" "$CLIENT_IP" "$SOURCE_SECS"' \
      --arm a --window 10
  ./scripts/wireless/multi-client.sh \
      --client f8:fe:5e:a1:6f:a8 --client 9c:2f:9d:11:22:33 \
      --source 'iperf3 -c "$CLIENT_IP" -t "$SOURCE_SECS" -f m' \
      --arm b --feeder root@192.168.1.50 --feeder-if enp1s0
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

warn() {
	printf '%s: warning: %s\n' "$PROG" "$1" >&2
}

say() {
	printf '%s\n' "$*"
	if [ -n "${LOG:-}" ]; then
		printf '%s %s\n' "$(now_iso)" "$*" >>"$LOG" 2>/dev/null
	fi
}

log_cmd() {
	if [ -n "${LOG:-}" ]; then
		printf '%s + %s\n' "$(now_iso)" "$1" >>"$LOG" 2>/dev/null
	fi
}

have() {
	command -v "$1" >/dev/null 2>&1
}

now_iso() {
	_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || _ts=unknown
	printf '%s' "$_ts"
}

now_compact() {
	_ts=$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null) || _ts=
	[ -n "$_ts" ] || _ts=$(awk '{ printf "uptime-%d", $1 }' /proc/uptime 2>/dev/null)
	printf '%s' "$_ts"
}

uptime_float() {
	awk '{ print $1 }' /proc/uptime 2>/dev/null
}

is_uint() {
	case $1 in
	''|*[!0-9]*) return 1 ;;
	esac
	return 0
}

normalize_mac() {
	printf '%s' "$1" | tr 'A-F-' 'a-f:'
}

valid_mac() {
	case $1 in
	[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f])
		return 0
		;;
	esac
	return 1
}

valid_iface() {
	case $1 in
	''|*[!A-Za-z0-9_.:@+-]*) return 1 ;;
	esac
	return 0
}

valid_ip() {
	case $1 in
	''|*[!0-9A-Fa-f:.]*) return 1 ;;
	esac
	case $1 in
	*:*)
		# Not a full IPv6 grammar check; enough to reject a typo that
		# would otherwise be passed to iperf3 as a hostname.
		_n=$(printf '%s' "$1" | tr -cd ':' | wc -c)
		[ "$_n" -ge 2 ]
		return
		;;
	esac
	_n=$(printf '%s' "$1" | awk -F. '
		NF == 4 {
			n = 0
			for (i = 1; i <= 4; i++)
				if ($i ~ /^[0-9]+$/ && $i >= 0 && $i <= 255) n++
			print n
		}')
	[ "$_n" = 4 ]
}

# Single-quote a string for a remote POSIX shell.
shq() {
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

tsv_field() {
	printf '%s\n' "$1" | cut -f"$2"
}

add_client() {
	case $CLIENT_COUNT in
	0) CLIENT1=$1 ;;
	1) CLIENT2=$1 ;;
	2) CLIENT3=$1 ;;
	*) usage_error "at most 3 clients are supported" ;;
	esac
	CLIENT_COUNT=$((CLIENT_COUNT + 1))
}

add_source() {
	[ -n "$1" ] || usage_error "--source must not be empty"
	case $1 in
	*'
'*) usage_error "--source must not contain a newline" ;;
	esac
	case $SOURCE_COUNT in
	0) SOURCE1=$1 ;;
	1) SOURCE2=$1 ;;
	2) SOURCE3=$1 ;;
	*) usage_error "at most 3 sources are supported" ;;
	esac
	SOURCE_COUNT=$((SOURCE_COUNT + 1))
}

add_ip_override() {
	valid_ip "$2" || usage_error "invalid --client-ip address: $2"
	case $IP_OVERRIDE_COUNT in
	0) IP_OVERRIDE_MAC1=$1; IP_OVERRIDE_ADDR1=$2 ;;
	1) IP_OVERRIDE_MAC2=$1; IP_OVERRIDE_ADDR2=$2 ;;
	2) IP_OVERRIDE_MAC3=$1; IP_OVERRIDE_ADDR3=$2 ;;
	*) usage_error "at most 3 --client-ip values are supported" ;;
	esac
	IP_OVERRIDE_COUNT=$((IP_OVERRIDE_COUNT + 1))
}

get_client() {
	case $1 in
	1) printf '%s' "$CLIENT1" ;;
	2) printf '%s' "$CLIENT2" ;;
	3) printf '%s' "$CLIENT3" ;;
	esac
}

get_iface() {
	case $1 in
	1) printf '%s' "$C_IFACE1" ;;
	2) printf '%s' "$C_IFACE2" ;;
	3) printf '%s' "$C_IFACE3" ;;
	esac
}

get_ip() {
	case $1 in
	1) printf '%s' "$C_IP1" ;;
	2) printf '%s' "$C_IP2" ;;
	3) printf '%s' "$C_IP3" ;;
	esac
}

set_active() {
	case $1 in
	1) C_ACTIVE1=$2 ;;
	2) C_ACTIVE2=$2 ;;
	3) C_ACTIVE3=$2 ;;
	esac
}

set_iface() {
	case $1 in
	1) C_IFACE1=$2 ;;
	2) C_IFACE2=$2 ;;
	3) C_IFACE3=$2 ;;
	esac
}

set_ip() {
	case $1 in
	1) C_IP1=$2 ;;
	2) C_IP2=$2 ;;
	3) C_IP3=$2 ;;
	esac
}

active_word() {
	case $1 in
	1) if [ "$C_ACTIVE1" = 1 ]; then printf yes; else printf no; fi ;;
	2) if [ "$C_ACTIVE2" = 1 ]; then printf yes; else printf no; fi ;;
	3) if [ "$C_ACTIVE3" = 1 ]; then printf yes; else printf no; fi ;;
	esac
}

get_source() {
	if [ "$SOURCE_COUNT" -eq 0 ]; then
		printf '%s' "$DEFAULT_SOURCE"
		return
	fi
	if [ "$SOURCE_COUNT" -eq 1 ]; then
		printf '%s' "$SOURCE1"
		return
	fi
	case $1 in
	1) printf '%s' "$SOURCE1" ;;
	2) printf '%s' "$SOURCE2" ;;
	3)
		if [ "$SOURCE_COUNT" -ge 3 ]; then
			printf '%s' "$SOURCE3"
		else
			printf '%s' "$SOURCE2"
		fi
		;;
	esac
}

ip_override_for() {
	_mac=$1
	_i=1
	while [ "$_i" -le "$IP_OVERRIDE_COUNT" ]; do
		case $_i in
		1) _m=$IP_OVERRIDE_MAC1; _a=$IP_OVERRIDE_ADDR1 ;;
		2) _m=$IP_OVERRIDE_MAC2; _a=$IP_OVERRIDE_ADDR2 ;;
		3) _m=$IP_OVERRIDE_MAC3; _a=$IP_OVERRIDE_ADDR3 ;;
		esac
		if [ "$_m" = "$_mac" ]; then
			printf '%s' "$_a"
			return 0
		fi
		_i=$((_i + 1))
	done
	return 1
}

# shellcheck disable=SC2329  # invoked by the EXIT/INT/TERM/HUP trap
cleanup() {
	_st=$?
	trap - EXIT INT TERM HUP
	if command -v kill_sources >/dev/null 2>&1; then
		kill_sources
	fi
	exit "$_st"
}

trap cleanup EXIT INT TERM HUP

# ---------------------------------------------------------------------------
# arguments

while [ "$#" -gt 0 ]; do
	case $1 in
	--client)
		[ "$#" -ge 2 ] || usage_error "--client needs a MAC"
		add_client "$(normalize_mac "$2")"
		shift 2
		;;
	--client=*)
		add_client "$(normalize_mac "${1#*=}")"
		shift
		;;
	--source)
		[ "$#" -ge 2 ] || usage_error "--source needs a command"
		add_source "$2"
		shift 2
		;;
	--source=*)
		add_source "${1#*=}"
		shift
		;;
	--client-ip)
		[ "$#" -ge 2 ] || usage_error "--client-ip needs MAC=IP"
		_m=${2%%=*}
		[ "$_m" != "$2" ] || usage_error "--client-ip needs MAC=IP, got '$2'"
		add_ip_override "$(normalize_mac "$_m")" "${2#*=}"
		shift 2
		;;
	--client-ip=*)
		_m=${1#*=}
		_v=${_m#*=}
		[ "$_v" != "$_m" ] || usage_error "--client-ip needs MAC=IP"
		add_ip_override "$(normalize_mac "${_m%%=*}")" "$_v"
		shift
		;;
	--arm)
		[ "$#" -ge 2 ] || usage_error "--arm needs a, b or both"
		ARM=$2
		shift 2
		;;
	--arm=*)
		ARM=${1#*=}
		shift
		;;
	--feeder)
		[ "$#" -ge 2 ] || usage_error "--feeder needs USER@HOST"
		FEEDER=$2
		shift 2
		;;
	--feeder=*)
		FEEDER=${1#*=}
		shift
		;;
	--feeder-if)
		[ "$#" -ge 2 ] || usage_error "--feeder-if needs an interface name"
		FEEDER_IF=$2
		shift 2
		;;
	--feeder-if=*)
		FEEDER_IF=${1#*=}
		shift
		;;
	--window)
		[ "$#" -ge 2 ] || usage_error "--window needs seconds"
		WINDOW=$2
		shift 2
		;;
	--window=*)
		WINDOW=${1#*=}
		shift
		;;
	--warmup)
		[ "$#" -ge 2 ] || usage_error "--warmup needs seconds"
		WARMUP=$2
		shift 2
		;;
	--warmup=*)
		WARMUP=${1#*=}
		shift
		;;
	--interval)
		[ "$#" -ge 2 ] || usage_error "--interval needs seconds"
		INTERVAL=$2
		shift 2
		;;
	--interval=*)
		INTERVAL=${1#*=}
		shift
		;;
	--procs)
		[ "$#" -ge 2 ] || usage_error "--procs needs a count"
		PROCS=$2
		shift 2
		;;
	--procs=*)
		PROCS=${1#*=}
		shift
		;;
	--out)
		[ "$#" -ge 2 ] || usage_error "--out needs a directory"
		OUT=$2
		shift 2
		;;
	--out=*)
		OUT=${1#*=}
		shift
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--help|-h)
		usage
		exit 0
		;;
	--)
		shift
		[ "$#" -eq 0 ] || usage_error "unexpected argument: $1"
		;;
	-*)
		usage_error "unknown option: $1"
		;;
	*)
		add_client "$(normalize_mac "$1")"
		shift
		;;
	esac
done

is_uint "$WINDOW" || usage_error "--window must be a positive integer"
[ "$WINDOW" -ge 1 ] || usage_error "--window must be greater than zero"
is_uint "$WARMUP" || usage_error "--warmup must be an integer"
is_uint "$INTERVAL" || usage_error "--interval must be a positive integer"
[ "$INTERVAL" -ge 1 ] || usage_error "--interval must be greater than zero"
[ "$INTERVAL" -le "$WINDOW" ] || usage_error "--interval must not exceed --window"
is_uint "$PROCS" || usage_error "--procs must be a positive integer"
[ "$PROCS" -ge 1 ] || usage_error "--procs must be greater than zero"
[ "$PROCS" -le 64 ] || usage_error "--procs must not exceed 64"

case $ARM in
a|b|both) ;;
*) usage_error "--arm must be a, b or both, got '$ARM'" ;;
esac

if [ -n "$FEEDER" ]; then
	case $FEEDER in
	-*) usage_error "--feeder must not start with '-'" ;;
	*[[:space:]]*) usage_error "--feeder must not contain whitespace" ;;
	esac
fi
if [ -n "$FEEDER_IF" ]; then
	valid_iface "$FEEDER_IF" || usage_error "invalid --feeder-if: $FEEDER_IF"
fi

# Client list.  The dry run may omit clients so it can be used as a generic
# plan; a real run needs 2-3.
if [ "$DRY_RUN" = 1 ]; then
	[ "$CLIENT_COUNT" -le 3 ] || usage_error "at most 3 clients are supported"
else
	if [ "$CLIENT_COUNT" -lt 2 ] || [ "$CLIENT_COUNT" -gt 3 ]; then
		usage_error "a real run needs 2 or 3 --client MACs (got $CLIENT_COUNT)"
	fi
fi

_i=1
while [ "$_i" -le "$CLIENT_COUNT" ]; do
	_m=$(get_client "$_i")
	valid_mac "$_m" || usage_error "invalid client MAC: $_m"
	_j=1
	while [ "$_j" -lt "$_i" ]; do
		[ "$(get_client "$_j")" != "$_m" ] ||
			usage_error "duplicate client MAC: $_m"
		_j=$((_j + 1))
	done
	_i=$((_i + 1))
done

if [ "$CLIENT_COUNT" -gt 0 ] && [ "$SOURCE_COUNT" -gt "$CLIENT_COUNT" ]; then
	usage_error "there are $SOURCE_COUNT --source values but only $CLIENT_COUNT clients"
fi

# Every --client-ip MAC must belong to the requested client list; a typo would
# otherwise be silently ignored and the address lookup would fall back to ARP.
_i=1
while [ "$_i" -le "$IP_OVERRIDE_COUNT" ]; do
	case $_i in
	1) _m=$IP_OVERRIDE_MAC1 ;;
	2) _m=$IP_OVERRIDE_MAC2 ;;
	3) _m=$IP_OVERRIDE_MAC3 ;;
	esac
	_found=0
	_j=1
	while [ "$_j" -le "$CLIENT_COUNT" ]; do
		[ "$(get_client "$_j")" = "$_m" ] && _found=1
		_j=$((_j + 1))
	done
	[ "$_found" = 1 ] || usage_error "--client-ip MAC $_m is not a requested client"
	_i=$((_i + 1))
done

if [ -z "$OUT" ]; then
	OUT=/tmp/multi-client-$(now_compact)
fi

case $OUT in
/|'') usage_error "--out must be a directory below /" ;;
esac

# ---------------------------------------------------------------------------
# B-path prerequisite: the feeder must answer a non-interactive ssh.  The
# check is read-only; it is done before the output directory or any traffic.

FEEDER_INFO=
FEEDER_SPEED=
FEEDER_IP=
FEEDER_ROUTES=

feeder_ssh() {
	ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR \
		"$FEEDER" "export PATH=/usr/sbin:/usr/bin:/sbin:/bin:\$PATH; $1"
}

check_feeder() {
	[ -n "$FEEDER" ] || die "--arm $ARM needs --feeder USER@HOST"
	_feeder_id=$(feeder_ssh 'uname -srm 2>/dev/null') ||
		die "cannot ssh to feeder '$FEEDER' non-interactively (BatchMode=yes required)"
	[ -n "$_feeder_id" ] || die "feeder '$FEEDER' returned no uname output"
	FEEDER_INFO=$_feeder_id
	log_cmd "ssh $FEEDER 'uname -srm' -> $_feeder_id"

	if [ "$SOURCE_COUNT" -eq 0 ] &&
		! feeder_ssh 'command -v iperf3 >/dev/null 2>&1'; then
		die "the default B-arm source needs iperf3 on feeder '$FEEDER'; pass --source"
	fi

	if [ -z "$FEEDER_IF" ]; then
		FEEDER_SPEED=unknown
		return 0
	fi

	FEEDER_SPEED=$(feeder_ssh "cat /sys/class/net/$FEEDER_IF/speed 2>/dev/null" 2>/dev/null | tr -dc '0-9')
	if [ -z "$FEEDER_SPEED" ]; then
		FEEDER_SPEED=$(feeder_ssh "ethtool $FEEDER_IF 2>/dev/null" 2>/dev/null |
			awk '/Speed:/ { for (i = 1; i <= NF; i++) if ($i == "Speed:") { print $(i + 1); exit } }' |
			tr -dc '0-9')
	fi
	[ -n "$FEEDER_SPEED" ] || FEEDER_SPEED=unknown

	_feeder_addr=$(feeder_ssh "ip -4 -o addr show dev $FEEDER_IF 2>/dev/null" 2>/dev/null)
	FEEDER_IP=$(printf '%s\n' "$_feeder_addr" | awk '
		{
			for (i = 1; i <= NF; i++)
				if ($i == "inet") { print $(i + 1); exit }
		}' | cut -d/ -f1)

	FEEDER_ROUTES=
	for _idx in $ACTIVE_IDX_LIST; do
		_mac=$(get_client "$_idx")
		_ip=$(get_ip "$_idx")
		[ -n "$_ip" ] || continue
		_route=$(feeder_ssh "ip route get $_ip 2>/dev/null" 2>/dev/null | head -n 1)
		_dev=$(printf '%s\n' "$_route" | awk '
			{
				for (i = 1; i <= NF; i++)
					if ($i == "dev") { print $(i + 1); exit }
			}')
		FEEDER_ROUTES="$FEEDER_ROUTES$_mac=$_dev "
	done
}

# ---------------------------------------------------------------------------
# client discovery

find_ap_ifaces() {
	AP_IFACES=
	for _i in $(iw dev 2>/dev/null | awk '$1 == "Interface" { print $2 }'); do
		_type=$(iw dev "$_i" info 2>/dev/null | awk '$1 == "type" { print $2; exit }')
		[ "$_type" = AP ] || continue
		AP_IFACES="$AP_IFACES $_i"
	done
	AP_IFACES=${AP_IFACES# }
	[ -n "$AP_IFACES" ]
}

iface_info() {
	iw dev "$1" info 2>/dev/null | awk '
		$1 == "channel" { ch = $2 }
		{
			for (i = 1; i <= NF; i++)
				if ($i == "width:") { w = $(i + 1); sub(/MHz/, "", w) }
		}
		/\([0-9]+ MHz\)/ {
			match($0, /\([0-9]+ MHz\)/)
			f = substr($0, RSTART + 1, RLENGTH - 2)
			sub(/ MHz/, "", f)
		}
		END { printf "%s|%s|%s", ch, w, f }
	'
}

band_of_freq() {
	case $1 in
	'') printf '?' ;;
	*)
		awk -v f="$1" 'BEGIN {
			if (f < 3000) print "2.4G"
			else if (f <= 5925) print "5G"
			else print "6G"
		}'
		;;
	esac
}

find_client_iface() {
	_mac=$1
	for _i in $AP_IFACES; do
		if iw dev "$_i" station dump 2>/dev/null | grep -q "^Station $_mac "; then
			printf '%s' "$_i"
			return 0
		fi
	done
	return 1
}

arp_lookup() {
	_mac=$1
	_ip=$(awk -v m="$_mac" '
		tolower($4) == m && $3 != "0x0" { print $1; exit }
	' /proc/net/arp 2>/dev/null)
	[ -n "$_ip" ] || _ip=$(ip neigh show 2>/dev/null | awk -v m="$_mac" '
		{
			for (i = 1; i <= NF; i++)
				if ($i == "lladdr" && tolower($(i + 1)) == m) { print $1; exit }
		}')
	[ -n "$_ip" ] || return 1
	printf '%s' "$_ip"
}

# Fill the C_* client state from AP station dumps.  Returns the number of
# associated requested clients in ACTIVE_COUNT.
resolve_clients() {
	ACTIVE_COUNT=0
	ACTIVE_IDX_LIST=
	_i=1
	while [ "$_i" -le "$CLIENT_COUNT" ]; do
		_mac=$(get_client "$_i")
		if _if=$(find_client_iface "$_mac"); then
			set_active "$_i" 1
			set_iface "$_i" "$_if"
			ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
			ACTIVE_IDX_LIST="$ACTIVE_IDX_LIST $_i"
		else
			set_active "$_i" 0
			set_iface "$_i" ""
		fi
		if _ip=$(ip_override_for "$_mac"); then
			set_ip "$_i" "$_ip"
		elif [ "$(get_iface "$_i")" != "" ]; then
			if _ip=$(arp_lookup "$_mac"); then
				set_ip "$_i" "$_ip"
			else
				set_ip "$_i" ""
			fi
		else
			set_ip "$_i" ""
		fi
		_i=$((_i + 1))
	done
	ACTIVE_IDX_LIST=${ACTIVE_IDX_LIST# }
}

# Refresh the interface for each active client immediately before an arm, so a
# client that roamed between arms is caught rather than measured on a stale
# interface.
verify_clients() {
	for _idx in $ACTIVE_IDX_LIST; do
		_mac=$(get_client "$_idx")
		_old=$(get_iface "$_idx")
		if ! _new=$(find_client_iface "$_mac"); then
			return 1
		fi
		if [ "$_new" != "$_old" ]; then
			set_iface "$_idx" "$_new"
			warn "client $_mac moved from $_old to $_new between arms"
			return 1
		fi
	done
	return 0
}

# ---------------------------------------------------------------------------
# samples

# One station as "associated|nss|width|signal|tx_bytes|rx_bytes|retries|failed".
sample_station_from_dump() {
	printf '%s\n' "$1" | awk -v mac="$2" '
		/^Station / {
			on = ($2 == mac)
			if (on) found = 1
			next
		}
		on {
			if ($1 == "associated:") assoc = $2
			if ($1 == "signal:" && $2 ~ /^-?[0-9]+$/) sig = $2
			if ($1 == "signal" && $2 == "avg:") sig = $3
			if ($1 == "tx" && $2 == "bytes:") txb = $3
			if ($1 == "rx" && $2 == "bytes:") rxb = $3
			if ($1 == "tx" && $2 == "retries:") retr = $3
			if ($1 == "tx" && $2 == "failed:") fail = $3
			if ($1 == "tx" && $2 == "bitrate:") {
				l = $0
				if (match(l, /[0-9]+MHz/)) {
					tw = substr(l, RSTART, RLENGTH)
					sub(/MHz/, "", tw)
				} else if (match(l, /[0-9]+ MHz/)) {
					tw = substr(l, RSTART, RLENGTH)
					sub(/ MHz/, "", tw)
				}
				if (match(l, /NSS [0-9]+/)) {
					tn = substr(l, RSTART, RLENGTH)
					sub(/NSS /, "", tn)
				}
			}
			if ($1 == "rx" && $2 == "bitrate:") {
				l = $0
				if (match(l, /[0-9]+MHz/)) {
					rw = substr(l, RSTART, RLENGTH)
					sub(/MHz/, "", rw)
				} else if (match(l, /[0-9]+ MHz/)) {
					rw = substr(l, RSTART, RLENGTH)
					sub(/ MHz/, "", rw)
				}
				if (match(l, /NSS [0-9]+/)) {
					rn = substr(l, RSTART, RLENGTH)
					sub(/NSS /, "", rn)
				}
			}
		}
		END {
			if (!found) { printf "no|||||||\n"; exit }
			if (assoc == "") assoc = "yes"
			n = (tn != "") ? tn : rn
			w = (tw != "") ? tw : rw
			gsub(/[^0-9-]/, "", sig)
			printf "%s|%s|%s|%s|%s|%s|%s|%s\n", assoc, n, w, sig, txb, rxb, retr, fail
		}
	'
}

# Append one row per active client for this instant, plus one NPU row.
# Returns non-zero (and sets SAMPLE_ERROR) if a station dump fails.
sample_clients() {
	_phase=$1
	_now=$(uptime_float)
	_seen=
	for _idx in $ACTIVE_IDX_LIST; do
		_if=$(get_iface "$_idx")
		case " $_seen " in
		*" $_if "*) continue ;;
		esac
		_seen="$_seen $_if"
		if ! _dump=$(iw dev "$_if" station dump 2>&1); then
			SAMPLE_ERROR="iw dev $_if station dump failed"
			return 1
		fi
		for _jdx in $ACTIVE_IDX_LIST; do
			[ "$(get_iface "$_jdx")" = "$_if" ] || continue
			_mac=$(get_client "$_jdx")
			_line=$(sample_station_from_dump "$_dump" "$_mac")
			_assoc=$(printf '%s\n' "$_line" | cut -d'|' -f1)
			_nss=$(printf '%s\n' "$_line" | cut -d'|' -f2)
			_width=$(printf '%s\n' "$_line" | cut -d'|' -f3)
			_sig=$(printf '%s\n' "$_line" | cut -d'|' -f4)
			_txb=$(printf '%s\n' "$_line" | cut -d'|' -f5)
			_rxb=$(printf '%s\n' "$_line" | cut -d'|' -f6)
			_retr=$(printf '%s\n' "$_line" | cut -d'|' -f7)
			_fail=$(printf '%s\n' "$_line" | cut -d'|' -f8)
			printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
				"$_phase" "$_now" "$ARM" "$_jdx" "$_mac" "$_if" \
				"$_assoc" "$_nss" "$_width" "$_sig" \
				"$_txb" "$_rxb" "$_retr" "$_fail" >>"$SAMPLES"
		done
	done
	sample_npu "$_phase"
	return 0
}

# Parse one token_info file into "count|size|free|npu_queued|band0|band1|band2".
parse_token_info() {
	awk '
		/^[ \t]*token_count:/ {
			l = $0
			sub(/.*token_count:[ \t]*/, "", l)
			split(l, p, /[ \t]*\/[ \t]*/)
			count = p[1]
			sub(/[^0-9].*/, "", count)
			size = p[2]
			sub(/[^0-9].*/, "", size)
		}
		/^[ \t]*npu_rx[0-9]+[ \t]*\|/ {
			n = split($0, q, "|")
			if (n >= 3) {
				v = q[3]
				gsub(/[^0-9]/, "", v)
				if (v != "") npuq += v + 0
			}
		}
		/band [0-9]+[ \t]*\|/ {
			n = split($0, q, "|")
			if (n >= 4) {
				b = q[1]
				sub(/.*band[ \t]*/, "", b)
				sub(/[^0-9].*/, "", b)
				v = q[4]
				gsub(/[^0-9]/, "", v)
				if (b != "" && v != "") band[b] += v + 0
			}
		}
		END {
			free = (count != "" && size != "") ? size - count : ""
			printf "%s|%s|%s|%s|%s|%s|%s\n", \
				count, size, free, npuq, band[0], band[1], band[2]
		}
	' "$1"
}

sample_npu() {
	_phase=$1
	_wrote=0
	for _f in "$DEBUGFS_ROOT"/ieee80211/*/mt76/token_info; do
		[ -r "$_f" ] || continue
		_parsed=$(parse_token_info "$_f")
		_c=$(printf '%s\n' "$_parsed" | cut -d'|' -f1)
		_s=$(printf '%s\n' "$_parsed" | cut -d'|' -f2)
		_fr=$(printf '%s\n' "$_parsed" | cut -d'|' -f3)
		_q=$(printf '%s\n' "$_parsed" | cut -d'|' -f4)
		_b0=$(printf '%s\n' "$_parsed" | cut -d'|' -f5)
		_b1=$(printf '%s\n' "$_parsed" | cut -d'|' -f6)
		_b2=$(printf '%s\n' "$_parsed" | cut -d'|' -f7)
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$_phase" "$(uptime_float)" "$_f" "$_c" "$_s" "$_fr" \
			"$_q" "$_b0" "$_b1" "$_b2" >>"$NPU_SAMPLES"
		_wrote=1
	done
	if [ "$_wrote" = 0 ] && [ ! -e "$ARM_DIR/npu-unavailable" ]; then
		: >"$ARM_DIR/npu-unavailable"
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$_phase" "$(uptime_float)" "unavailable" "" "" "" "" "" "" "" \
			>>"$NPU_SAMPLES"
	fi
}

# Raw pre/post snapshots.  Every command is read-only; failures are recorded
# in the file and never abort a run.
capture_stations() {
	_tag=$1
	_file=$ARM_DIR/station-$_tag.txt
	: >"$_file"
	for _if in $AP_IFACES; do
		printf '### %s\n' "$_if" >>"$_file"
		iw dev "$_if" station dump >>"$_file" 2>&1 || printf '[dump failed]\n' >>"$_file"
	done
	log_cmd "iw dev <ap-ifaces> station dump > $_file"
}

capture_debugfs() {
	_tag=$1
	_file=$ARM_DIR/token-info-$_tag.txt
	{
		for _f in "$DEBUGFS_ROOT"/ieee80211/*/mt76/token_info; do
			[ -r "$_f" ] || continue
			printf '### %s\n' "$_f"
			cat "$_f" 2>&1
		done
	} | awk -v tag="$_tag" '
		BEGIN { print "# token_info (" tag ")" }
		{ print }' >"$_file.tmp" && mv "$_file.tmp" "$_file"

	_file=$ARM_DIR/hw-queues-$_tag.txt
	{
		for _f in "$DEBUGFS_ROOT"/ieee80211/*/mt76/hw-queues; do
			[ -r "$_f" ] || continue
			printf '### %s\n' "$_f"
			cat "$_f" 2>&1
		done
	} >"$_file.tmp" && mv "$_file.tmp" "$_file"

	_file=$ARM_DIR/sta-hw-queues-$_tag.txt
	{
		for _idx in $ACTIVE_IDX_LIST; do
			_mac=$(get_client "$_idx")
			printf '### %s\n' "$_mac"
			_found=0
			for _f in "$DEBUGFS_ROOT"/ieee80211/*/netdev:*/stations/"$_mac"/hw-queues \
				"$DEBUGFS_ROOT"/ieee80211/*/*/stations/"$_mac"/hw-queues; do
				[ -r "$_f" ] || continue
				_found=1
				printf '## %s\n' "$_f"
				cat "$_f" 2>&1
			done
			[ "$_found" = 1 ] || printf '# no per-STA hw-queues\n'
		done
	} >"$_file.tmp" && mv "$_file.tmp" "$_file"
	log_cmd "read token_info, hw-queues and per-STA hw-queues ($_tag) into $ARM_DIR"
}

# ---------------------------------------------------------------------------
# sources

sources_alive() {
	_n=0
	for _p in ${SRC_PIDS:-}; do
		[ -r "/proc/$_p/stat" ] || continue
		_state=$(awk '{ print $3 }' "/proc/$_p/stat" 2>/dev/null)
		case $_state in
		Z|'') ;;
		*) _n=$((_n + 1)) ;;
		esac
	done
	printf '%s' "$_n"
}

start_sources() {
	_src_secs=$((WARMUP + WINDOW + 5))
	SRC_PIDS=
	for _idx in $ACTIVE_IDX_LIST; do
		_mac=$(get_client "$_idx")
		_ip=$(get_ip "$_idx")
		_if=$(get_iface "$_idx")
		_src=$(get_source "$_idx")
		_n=1
		while [ "$_n" -le "$PROCS" ]; do
			_log=$ARM_DIR/source-$_idx-$_n.log
			log_cmd "start source for $_mac (copy $_n/$PROCS): $_src"
			if [ "$ARM" = b ]; then
				ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR \
					"$FEEDER" \
					"env IFACE=$(shq "$_if") CLIENT=$(shq "$_mac") CLIENT_IP=$(shq "$_ip") ARM=$(shq "$ARM") WINDOW=$(shq "$WINDOW") WARMUP=$(shq "$WARMUP") SOURCE_SECS=$(shq "$_src_secs") PROCS=$(shq "$PROCS") CLIENT_INDEX=$(shq "$_idx") FEEDER=$(shq "$FEEDER") FEEDER_IF=$(shq "$FEEDER_IF") FEEDER_IP=$(shq "$FEEDER_IP") sh -c $(shq "$_src")" \
					>"$_log" 2>&1 &
			else
				IFACE="$_if" CLIENT="$_mac" CLIENT_IP="$_ip" ARM="$ARM" \
					WINDOW="$WINDOW" WARMUP="$WARMUP" SOURCE_SECS="$_src_secs" \
					PROCS="$PROCS" CLIENT_INDEX="$_idx" FEEDER="$FEEDER" \
					FEEDER_IF="$FEEDER_IF" FEEDER_IP="$FEEDER_IP" OUT="$ARM_DIR" \
					sh -c "$_src" >"$_log" 2>&1 &
			fi
			SRC_PIDS="$SRC_PIDS $!"
			_n=$((_n + 1))
		done
	done
	SRC_EXPECTED=$((ACTIVE_COUNT * PROCS))
}

# Descendant pids of $1 from one /proc scan.  A source is "sh -c <cmd>", so
# the process that actually sends is a grandchild or deeper (iperf3 behind
# ssh, ringblast): killing only the recorded pid left them running, and the
# next arm then measured the previous arm's traffic.
tree_pids() {
	_root=$1
	# One awk over every /proc/<pid>/stat: the first field after the
	# "pid (comm) " prefix is the state, the second is the ppid.
	_map=$(awk '
		FNR == 1 {
			p = FILENAME
			sub(/^.*\/proc\//, "", p)
			sub(/\/stat$/, "", p)
			s = $0
			sub(/.*\) /, "", s)
			split(s, a, " ")
			print p, a[2]
		}' /proc/[0-9]*/stat 2>/dev/null)
	_front=$_root
	_out=
	while [ -n "$_front" ]; do
		_next=
		for _f in $_front; do
			_next="$_next $(printf '%s\n' "$_map" | awk -v p="$_f" '$2 == p { printf "%s ", $1 }')"
		done
		_front=${_next# }
		_out="$_out $_front"
	done
	printf '%s' "${_out# }"
	unset _map
}

kill_sources() {
	[ -n "${SRC_PIDS:-}" ] || return 0
	_todo=
	for _p in $SRC_PIDS; do
		_todo="$_todo $_p $(tree_pids "$_p")"
	done
	for _p in $_todo; do
		kill "$_p" 2>/dev/null
	done
	for _p in $SRC_PIDS; do
		wait "$_p" 2>/dev/null
	done
	# Anything that ignored TERM, children included, goes now.  The pid list
	# was taken above; Linux hands out pids in ascending order and only wraps
	# at pid_max, so none of these can have been recycled in between.
	for _p in $_todo; do
		kill -9 "$_p" 2>/dev/null
	done
	SRC_PIDS=
}

check_sources() {
	_alive=$(sources_alive)
	if [ "$_alive" -lt "$SRC_EXPECTED" ]; then
		ARM_STATUS=abort
		ARM_REASON="only $_alive of $SRC_EXPECTED source process(es) still running"
		return 1
	fi
	return 0
}

check_connected() {
	_phase=$1
	for _idx in $ACTIVE_IDX_LIST; do
		_row=$(latest_row "$_idx")
		_mac=$(get_client "$_idx")
		_assoc=$(tsv_field "$_row" 7)
		_if=$(tsv_field "$_row" 6)
		_nss=$(tsv_field "$_row" 8)
		if [ "$_assoc" != yes ]; then
			ARM_STATUS=abort
			ARM_REASON="client $_mac disconnected during $_phase"
			return 1
		fi
		if [ "$_if" != "$(get_iface "$_idx")" ]; then
			ARM_STATUS=abort
			ARM_REASON="client $_mac changed AP interface during $_phase"
			return 1
		fi
		_want=$(expected_value "$_idx" 2)
		if [ -n "$_want" ] && [ -z "$_nss" ]; then
			ARM_STATUS=abort
			ARM_REASON="client $_mac has no NSS during $_phase (is the source sending?)"
			return 1
		fi
		if [ -n "$_want" ] && [ "$_nss" != "$_want" ]; then
			ARM_STATUS=abort
			ARM_REASON="client $_mac NSS changed $_want -> $_nss during $_phase"
			return 1
		fi
	done
	return 0
}

latest_row() {
	awk -F'\t' -v i="$1" '
		$4 == i { line = $0 }
		END { if (line != "") print line }
	' "$SAMPLES"
}

expected_value() {
	awk -F'\t' -v i="$1" -v f="$2" '
		$1 == i { print $f; exit }
	' "$EXPECTED_NSS_FILE" 2>/dev/null
}

record_expected() {
	: >"$EXPECTED_NSS_FILE"
	for _idx in $ACTIVE_IDX_LIST; do
		_row=$(latest_row "$_idx")
		_mac=$(get_client "$_idx")
		_nss=$(tsv_field "$_row" 8)
		_width=$(tsv_field "$_row" 9)
		if [ -z "$_nss" ]; then
			ARM_STATUS=abort
			ARM_REASON="client $_mac has no NSS after ${WARMUP}s warm-up (is the source sending?)"
			return 1
		fi
		printf '%s\t%s\t%s\t%s\n' "$_idx" "$_nss" "$_width" "$_mac" >>"$EXPECTED_NSS_FILE"
	done
	return 0
}

# ---------------------------------------------------------------------------
# result computation

# One TSV row: arm, client, iface, channel, width, nss, signal, tx_bytes,
# rx_bytes, seconds, tx_gbit, rx_gbit, retries, failed, status.
compute_client_row() {
	_idx=$1
	_mac=$(get_client "$_idx")
	_if=$(get_iface "$_idx")
	_meta=$(iface_info "$_if")
	_ch=$(printf '%s\n' "$_meta" | cut -d'|' -f1)
	_cw=$(printf '%s\n' "$_meta" | cut -d'|' -f2)
	awk -F'\t' -v arm="$ARM" -v mac="$_mac" -v iface="$_if" \
		-v ch="$_ch" -v cw="$_cw" -v secs="$WINDOW_SECS" -v i="$_idx" '
		$1 == "window-start" && $4 == i {
			btx = $11; brx = $12; bret = $13; bfail = $14
			bnss = $8; bw = $9; bsig = $10
		}
		$1 == "window-end" && $4 == i {
			atx = $11; arx = $12; aret = $13; afail = $14
			anss = $8; aw = $9; asig = $10
		}
		END {
			status = "ok"
			if (btx == "" || atx == "" || brx == "" || arx == "") status = "invalid"
			tx = (btx != "" && atx != "") ? atx - btx : ""
			rx = (brx != "" && arx != "") ? arx - brx : ""
			retr = (bret != "" && aret != "") ? aret - bret : ""
			fail = (bfail != "" && afail != "") ? afail - bfail : ""
			txg = ""; rxg = ""
			if (tx != "" && secs > 0) txg = sprintf("%.3f", tx * 8 / 1000000000 / secs)
			if (rx != "" && secs > 0) rxg = sprintf("%.3f", rx * 8 / 1000000000 / secs)
			nss = (anss != "") ? anss : bnss
			width = (aw != "") ? aw : bw
			sig = (asig != "") ? asig : bsig
			if (nss == "") status = "invalid"
			# A client that moved no byte in the window is not a data
			# point: it printed "0.000 ok" and the aggregate counted an
			# idle client as a success.  Any traffic at all is accepted;
			# the arm-level gate is the signed target, not a per-client
			# floor, so nothing here is a throughput threshold.
			if (status == "ok" && tx == 0 && rx == 0) status = "idle"
			if (width == "") width = cw
			if (ch == "") ch = "?"
			if (nss == "") nss = "?"
			if (sig == "") sig = "?"
			if (tx == "") tx = "?"
			if (rx == "") rx = "?"
			if (retr == "") retr = "?"
			if (fail == "") fail = "?"
			if (txg == "") txg = "?"
			if (rxg == "") rxg = "?"
			printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%.3f\t%s\t%s\t%s\t%s\t%s\n", \
				arm, mac, iface, ch, width, nss, sig, tx, rx, secs, txg, rxg, retr, fail, status
		}
	' "$SAMPLES"
}

compute_results() {
	: >"$ARM_DIR/result.tsv"
	for _idx in $ACTIVE_IDX_LIST; do
		compute_client_row "$_idx" >>"$ARM_DIR/result.tsv"
	done
}

print_arm_table() {
	printf '%-3s %-17s %-12s %-4s %-5s %-3s %-7s %12s %12s %7s %8s %8s %8s %s\n' \
		ARM CLIENT IFACE CH WIDTH NSS SIGNAL TX_BYTES RX_BYTES SECS TX_GBIT RX_GBIT RETRIES STATUS
	while IFS= read -r _row; do
		[ -n "$_row" ] || continue
		printf '%-3s %-17s %-12s %-4s %-5s %-3s %-7s %12s %12s %7s %8s %8s %8s %s\n' \
			"$(tsv_field "$_row" 1)" "$(tsv_field "$_row" 2)" \
			"$(tsv_field "$_row" 3)" "$(tsv_field "$_row" 4)" \
			"$(tsv_field "$_row" 5)" "$(tsv_field "$_row" 6)" \
			"$(tsv_field "$_row" 7)" "$(tsv_field "$_row" 8)" \
			"$(tsv_field "$_row" 9)" "$(tsv_field "$_row" 10)" \
			"$(tsv_field "$_row" 11)" "$(tsv_field "$_row" 12)" \
			"$(tsv_field "$_row" 13)" "$(tsv_field "$_row" 15)"
	done <"$ARM_DIR/result.tsv"

	_agg=$(awk -F'\t' '{
		tx += ($8 == "?") ? 0 : $8
		rx += ($9 == "?") ? 0 : $9
		retr += ($13 == "?") ? 0 : $13
	} END { printf "%d\t%d\t%d", tx, rx, retr }' "$ARM_DIR/result.tsv")
	_atx=$(printf '%s\n' "$_agg" | cut -f1)
	_arx=$(printf '%s\n' "$_agg" | cut -f2)
	_aret=$(printf '%s\n' "$_agg" | cut -f3)
	_atxg=$(awk -v b="$_atx" -v s="$WINDOW_SECS" 'BEGIN {
		if (s > 0) printf "%.3f", b * 8 / 1000000000 / s
	}')
	_arxg=$(awk -v b="$_arx" -v s="$WINDOW_SECS" 'BEGIN {
		if (s > 0) printf "%.3f", b * 8 / 1000000000 / s
	}')
	printf '%-3s %-17s %-12s %-4s %-5s %-3s %-7s %12s %12s %7s %8s %8s %8s %s\n' \
		"$ARM" "AGGREGATE(${ACTIVE_COUNT})" "-" "-" "-" "-" "-" \
		"$_atx" "$_arx" "$WINDOW_SECS" "$_atxg" "$_arxg" "$_aret" \
		"$ARM_STATUS"
	printf '%s\tAGGREGATE(%s)\t-\t-\t-\t-\t-\t%s\t%s\t%s\t%s\t%s\t%s\t-\t%s\n' \
		"$ARM" "$ACTIVE_COUNT" "$_atx" "$_arx" "$WINDOW_SECS" \
		"$_atxg" "$_arxg" "$_aret" "$ARM_STATUS" >>"$ARM_DIR/result.tsv"
}

print_npu_summary() {
	awk -F'\t' -v arm="$ARM" '
		NR > 1 && $4 != "" {
			n++
			if (minfree == "" || $6 < minfree) minfree = $6
			if (maxcount == "" || $4 > maxcount) maxcount = $4
			if (size == "") size = $5
			if ($7 != "" && $7 + 0 > maxq) maxq = $7 + 0
			if ($8 != "" && $8 + 0 > b0) b0 = $8 + 0
			if ($9 != "" && $9 + 0 > b1) b1 = $9 + 0
			if ($10 != "" && $10 + 0 > b2) b2 = $10 + 0
		}
		END {
			if (n == 0) {
				printf "NPU %s: token_info unavailable; no queue sample\n", arm
				exit
			}
			printf "NPU %s: token in-flight max %s / pool %s (free min %s), npu_rx queued max %d (ring occupancy, not congestion), tx-band queued max %d/%d/%d\n", \
				arm, maxcount, size, minfree, maxq, b0, b1, b2
		}
	' "$NPU_SAMPLES"
}

print_feeder_summary() {
	[ "$ARM" = b ] || return 0
	_speed=${FEEDER_SPEED:-unknown}
	_line="B-PATH feeder $FEEDER ($FEEDER_INFO): feeder-if ${FEEDER_IF:-unset} speed ${_speed} Mb/s"
	case $_speed in
	unknown) _line="$_line (unknown; not a verified 2.5G feed)" ;;
	*)
		if [ "$_speed" -lt 2500 ] 2>/dev/null; then
			_line="$_line (feeder-limited; B >=1.5G is not reachable through it)"
		fi
		;;
	esac
	say "$_line"
	[ -z "$FEEDER_ROUTES" ] || say "B-PATH routes: ${FEEDER_ROUTES% }"

}

# ---------------------------------------------------------------------------
# arms

run_arm() {
	ARM_LABEL=$1
	ARM=$ARM_LABEL
	ARM_DIR=$OUT/arm-$ARM_LABEL
	SAMPLES=$ARM_DIR/samples.tsv
	NPU_SAMPLES=$ARM_DIR/npu.tsv
	EXPECTED_NSS_FILE=$ARM_DIR/expected.tsv
	ARM_STATUS=ok
	ARM_REASON=
	WINDOW_SECS=0
	SAMPLE_ERROR=
	SRC_PIDS=
	SRC_EXPECTED=0

	mkdir -p "$ARM_DIR" || die "cannot create $ARM_DIR"
	printf 'phase\tt\tarm\tidx\tmac\tiface\tassoc\tnss\twidth\tsignal\ttx_bytes\trx_bytes\tretries\tfailed\n' >"$SAMPLES"
	printf 'phase\tt\tfile\tcount\tsize\tfree\tnpu_queued\tband0\tband1\tband2\n' >"$NPU_SAMPLES"

	say ""
	say "ARM $ARM_LABEL: $ACTIVE_COUNT client(s), window ${WINDOW}s, warm-up ${WARMUP}s, sample ${INTERVAL}s"

	if ! verify_clients; then
		ARM_STATUS=abort
		ARM_REASON="a client is no longer associated on the expected AP interface"
		say "ARM $ARM_LABEL ABORTED: $ARM_REASON"
		return 1
	fi

	if [ "$ARM_LABEL" = b ]; then
		print_feeder_summary
	fi

	capture_stations before
	capture_debugfs before

	start_sources "$ARM_LABEL"
	if ! check_sources; then
		kill_sources
		say "ARM $ARM_LABEL ABORTED: $ARM_REASON"
		return 1
	fi

	_warm_start=$(uptime_float)
	while :; do
		sleep "$INTERVAL"
		if ! sample_clients warmup; then
			ARM_STATUS=abort
			ARM_REASON=$SAMPLE_ERROR
			break
		fi
		if ! check_sources; then
			break
		fi
		if ! check_connected warmup; then
			break
		fi
		_el=$(awk -v now="$(uptime_float)" -v start="$_warm_start" \
			'BEGIN { printf "%.3f", now - start }')
		_done=$(awk -v e="$_el" -v w="$WARMUP" 'BEGIN { print (e >= w) ? 1 : 0 }')
		[ "$_done" = 1 ] && break
	done

	if [ "$ARM_STATUS" = ok ]; then
		if ! sample_clients warmup; then
			ARM_STATUS=abort
			ARM_REASON=$SAMPLE_ERROR
		elif ! record_expected; then
			:
		fi
	fi

	_t0=
	_t1=
	if [ "$ARM_STATUS" = ok ]; then
		if ! sample_clients window-start; then
			ARM_STATUS=abort
			ARM_REASON=$SAMPLE_ERROR
		fi
	fi
	if [ "$ARM_STATUS" = ok ]; then
		_t0=$(uptime_float)
		while :; do
			sleep "$INTERVAL"
			if ! sample_clients window; then
				ARM_STATUS=abort
				ARM_REASON=$SAMPLE_ERROR
				break
			fi
			if ! check_sources; then
				break
			fi
			if ! check_connected window; then
				break
			fi
			_el=$(awk -v now="$(uptime_float)" -v start="$_t0" \
				'BEGIN { printf "%.3f", now - start }')
			_done=$(awk -v e="$_el" -v w="$WINDOW" 'BEGIN { print (e >= w) ? 1 : 0 }')
			[ "$_done" = 1 ] && break
		done
	fi
	if [ "$ARM_STATUS" = ok ]; then
		if ! sample_clients window-end; then
			ARM_STATUS=abort
			ARM_REASON=$SAMPLE_ERROR
		fi
		_t1=$(uptime_float)
		if ! check_sources; then
			:
		fi
		if [ "$ARM_STATUS" = ok ] && ! check_connected window-end; then
			:
		fi
	fi

	if [ -n "$_t1" ] && [ -n "$_t0" ]; then
		WINDOW_SECS=$(awk -v a="$_t0" -v b="$_t1" 'BEGIN {
			if (b > a) printf "%.3f", b - a; else print "0.000"
		}')
	elif [ -n "$_t0" ]; then
		WINDOW_SECS=$(awk -v a="$_t0" -v b="$(uptime_float)" 'BEGIN {
			if (b > a) printf "%.3f", b - a; else print "0.000"
		}')
	else
		WINDOW_SECS=0
	fi

	capture_stations after
	capture_debugfs after
	kill_sources

	if [ "$ARM_STATUS" != ok ]; then
		say "ARM $ARM_LABEL ABORTED after ${WINDOW_SECS}s: $ARM_REASON"
		printf '%s\tABORTED\t-\t-\t-\t-\t-\t-\t-\t%s\t-\t-\t-\t-\taborted: %s\n' \
			"$ARM" "$WINDOW_SECS" "$ARM_REASON" >>"$ARM_DIR/result.tsv"
		cat "$ARM_DIR/result.tsv" >>"$OUT/result.tsv"
		print_npu_summary
		return 1
	fi

	compute_results
	if ! awk -F'\t' '$15 != "ok" { exit 1 }' "$ARM_DIR/result.tsv"; then
		ARM_STATUS=abort
		ARM_REASON="a client row failed validation (missing NSS/counter, or no traffic)"
		say "ARM $ARM_LABEL ABORTED: $ARM_REASON"
		# Print the offending row: the operator needs to see which client
		# was idle, not just that one was.
		print_arm_table
		printf '%s\tABORTED\t-\t-\t-\t-\t-\t-\t-\t%s\t-\t-\t-\t-\taborted: %s\n' \
			"$ARM" "$WINDOW_SECS" "$ARM_REASON" >>"$ARM_DIR/result.tsv"
		cat "$ARM_DIR/result.tsv" >>"$OUT/result.tsv"
		print_npu_summary
		return 1
	fi
	say "ARM $ARM_LABEL result over ${WINDOW_SECS}s:"
	print_arm_table
	print_npu_summary
	cat "$ARM_DIR/result.tsv" >>"$OUT/result.tsv"
	return 0
}

# ---------------------------------------------------------------------------
# dry run

dry_run_plan() {
	_armtext=$ARM
	_clients=$CLIENT_COUNT
	if [ "$_clients" -eq 0 ]; then
		printf '%s: dry run; no traffic, no ssh, no device read, no file written\n' "$PROG"
		printf '  clients: <none given; a real run needs 2 or 3>\n'
	else
		printf '%s: dry run; no traffic, no ssh, no device read, no file written\n' "$PROG"
		printf '  clients: %s requested\n' "$_clients"
		_i=1
		while [ "$_i" -le "$_clients" ]; do
			_mac=$(get_client "$_i")
			_ip=$(ip_override_for "$_mac" || true)
			[ -n "$_ip" ] || _ip="<ARP/neigh lookup at run time>"
			_src=$(get_source "$_i")
			printf '    %s  ip=%s\n' "$_mac" "$_ip"
			printf '      source: %s\n' "$_src"
			_i=$((_i + 1))
		done
	fi
	printf '  arm=%s window=%ss warmup=%ss interval=%ss procs=%s\n' \
		"$_armtext" "$WINDOW" "$WARMUP" "$INTERVAL" "$PROCS"
	printf '  output: %s\n' "$OUT"
	printf '  source window: SOURCE_SECS = %s (warm-up + window + 5)\n' \
		"$((WARMUP + WINDOW + 5))"
	printf '\nprotocol (executed only for a real run):\n'
	printf '  1. iw dev <ap-ifaces> station dump; map each MAC to its AP interface\n'
	printf '     and band (5G/6G); resolve each address from ARP/neigh or --client-ip\n'
	printf '  2. if fewer than 2 requested clients are associated: print SKIP and\n'
	printf '     exit 0; no traffic, no output directory, no config change\n'
	printf '  3. per arm: snapshot station dump, token_info and hw-queues\n'
	printf '  4. start the per-client source(s):\n'
	if [ "$_armtext" = a ] || [ "$_armtext" = both ]; then
		printf '       A: IFACE=... CLIENT=... sh -c <source> (on the AP)\n'
	fi
	if [ "$_armtext" = b ] || [ "$_armtext" = both ]; then
		printf '       B: ssh %s "env CLIENT=... sh -c <source>" (one per client/proc)\n' \
			"${FEEDER:-<feeder>}"
	fi
	printf '  5. warm up %ss, take the expected NSS from the last warm-up sample\n' "$WARMUP"
	printf '  6. measure %ss: every %ss run "iw dev IFACE station dump" and read\n' \
		"$WINDOW" "$INTERVAL"
	printf '     /sys/kernel/debug/ieee80211/*/mt76/token_info (+ hw-queues)\n'
	printf '  7. abort if a client disconnects, NSS is missing or changes, or a\n'
	printf '     source process exits; otherwise compute per-client and aggregate\n'
	printf '     tx/rx Gbit/s from the byte deltas over the measured seconds\n'
	if [ "$_armtext" = b ] || [ "$_armtext" = both ]; then
		printf '\nB-path feeder checks (read-only):\n'
		printf '  ssh %s true\n' "${FEEDER:-<feeder>}"
		printf '  ssh %s "cat /sys/class/net/%s/speed"\n' \
			"${FEEDER:-<feeder>}" "${FEEDER_IF:-<feeder-if>}"
		printf '  ssh %s "ip route get <client-ip>"   # route must leave via the feeder NIC\n' \
			"${FEEDER:-<feeder>}"
	fi
	printf '\noutput when run for real:\n'
	printf '  %s/result.tsv                 per-client + aggregate rows\n' "$OUT"
	printf '  %s/arm-a/... and %s/arm-b/... when both arms run\n' "$OUT" "$OUT"
	printf '  %s/arm-<a|b>/{samples,npu,result}.tsv; station/token/hw-queues dumps\n' "$OUT"
	printf '  %s/run.log\n' "$OUT"
	printf '\nnot run by --dry-run: no ssh, no iperf3/source, no iw read, no file write.\n'
}

if [ "$DRY_RUN" = 1 ]; then
	dry_run_plan
	exit 0
fi

# ---------------------------------------------------------------------------
# real run

have iw || die "iw is required (install iw or iw-full)"
have awk || die "awk is required"
have sed || die "sed is required"
[ -r /proc/uptime ] || die "/proc/uptime is required"

log_cmd "multi-client.sh $SCHEMA starting"
find_ap_ifaces || die "no Wi-Fi AP interface found (is the wireless stack up?)"

resolve_clients

say "clients: $CLIENT_COUNT requested, $ACTIVE_COUNT associated"
_i=1
while [ "$_i" -le "$CLIENT_COUNT" ]; do
	_mac=$(get_client "$_i")
	_if=$(get_iface "$_i")
	_ip=$(get_ip "$_i")
	if [ "$(get_iface "$_i")" = "" ]; then
		say "  $_mac: NOT associated (skipped)"
	else
		_meta=$(iface_info "$_if")
		_ch=$(printf '%s\n' "$_meta" | cut -d'|' -f1)
		_cw=$(printf '%s\n' "$_meta" | cut -d'|' -f2)
		_freq=$(printf '%s\n' "$_meta" | cut -d'|' -f3)
		say "  $_mac: iface=$_if band=$(band_of_freq "$_freq") channel=${_ch:-?} width=${_cw:-?} MHz ip=${_ip:-none}"
	fi
	_i=$((_i + 1))
done

if [ "$ACTIVE_COUNT" -lt 2 ]; then
	say "SKIP: only $ACTIVE_COUNT of $CLIENT_COUNT requested client(s) associated; need at least 2"
	say "      no traffic was sent and no config was changed"
	exit 0
fi

if [ "$SOURCE_COUNT" -eq 0 ]; then
	for _idx in $ACTIVE_IDX_LIST; do
		_ip=$(get_ip "$_idx")
		[ -n "$_ip" ] ||
			die "no address for client $(get_client "$_idx"); pass --client-ip MAC=IP (the default iperf3 source needs it)"
	done
else
	for _idx in $ACTIVE_IDX_LIST; do
		[ -n "$(get_ip "$_idx")" ] ||
			warn "no address for client $(get_client "$_idx"); CLIENT_IP will be empty in its source"
	done
fi

if [ "$SOURCE_COUNT" -eq 0 ]; then
	case $ARM in
	a|both)
		have iperf3 ||
			die "the default source needs iperf3 on the AP; pass --source with the lab source (e.g. /tmp/ringblast)"
		;;
	esac
fi

[ -n "$FEEDER" ] || [ "$ARM" = a ] || die "--arm $ARM needs --feeder USER@HOST"

if [ -e "$OUT" ]; then
	die "output directory already exists: $OUT (refusing to overwrite a previous run)"
fi
mkdir -p "$OUT" || die "cannot create output directory $OUT"
LOG=$OUT/run.log

{
	printf 'schema=%s\n' "$SCHEMA"
	printf 'timestamp=%s\n' "$(now_iso)"
	printf 'host=%s\n' "$(uname -n 2>/dev/null)"
	printf 'kernel=%s\n' "$(uname -srm 2>/dev/null)"
	printf 'arm=%s\n' "$ARM"
	printf 'window=%s\nwarmup=%s\ninterval=%s\nprocs=%s\n' "$WINDOW" "$WARMUP" "$INTERVAL" "$PROCS"
	printf 'requested_clients=%s\n' "$CLIENT_COUNT"
	_i=1
	while [ "$_i" -le "$CLIENT_COUNT" ]; do
		printf 'client_%s=%s associated=%s iface=%s ip=%s\n' \
			"$_i" "$(get_client "$_i")" "$(active_word "$_i")" \
			"$(get_iface "$_i")" "$(get_ip "$_i")"
		printf 'client_%s_source=%s\n' "$_i" "$(get_source "$_i")"
		_i=$((_i + 1))
	done
	printf 'source=%s\n' "$(get_source 1)"
} >"$OUT/meta.txt"
printf 'arm\tclient\tiface\tchannel\twidth\tnss\tsignal\ttx_bytes\trx_bytes\tseconds\ttx_gbit\trx_gbit\tretries\tfailed\tstatus\n' >"$OUT/result.tsv"

if [ "$ARM" = b ] || [ "$ARM" = both ]; then
	check_feeder
fi

EXIT_CODE=0
case $ARM in
a)
	run_arm a || EXIT_CODE=3
	;;
b)
	run_arm b || EXIT_CODE=3
	;;
both)
	if run_arm a; then
		run_arm b || EXIT_CODE=3
	else
		EXIT_CODE=3
	fi
	;;
esac

if [ "$EXIT_CODE" -eq 0 ]; then
	say ""
	say "SUMMARY: all requested arms valid"
	if [ -f "$OUT/arm-a/result.tsv" ]; then
		_agg=$(awk -F'\t' '$2 ~ /^AGGREGATE/ { printf "tx %s Gbit/s, rx %s Gbit/s, %s retries over %s s", $11, $12, $13, $10 }' "$OUT/arm-a/result.tsv")
		say "  A: ${_agg:-no aggregate row}"
	fi
	if [ -f "$OUT/arm-b/result.tsv" ]; then
		_agg=$(awk -F'\t' '$2 ~ /^AGGREGATE/ { printf "tx %s Gbit/s, rx %s Gbit/s, %s retries over %s s", $11, $12, $13, $10 }' "$OUT/arm-b/result.tsv")
		say "  B: ${_agg:-no aggregate row}"
	fi
fi

exit "$EXIT_CODE"
