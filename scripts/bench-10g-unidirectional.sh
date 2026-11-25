#!/bin/sh
#
# bench-10g-unidirectional.sh - reproducible unidirectional 10G bench harness.
#
# Problem this solves: a 10G throughput run used to be assembled by hand -
# one iperf3 invocation, nft/tc counters, /proc/stat and /proc/interrupts
# reads, the airoha PPE debugfs files, and a note of whether the flow bound
# in the PPE.  Nothing recorded the protocol, so two builds could not be
# compared.
#
# Protocol (fixed, so runs stay comparable):
#   1. TX: snapshot, then "iperf3 -c TARGET -t DURATION -P PARALLEL -J",
#      then snapshot.
#   2. RX: snapshot, then the same command plus -R, then snapshot.
#   TX and RX are separate runs; the script never starts both directions
#   at the same time.
#
# The snapshots hold /proc/stat, /proc/interrupts, interface counters,
# ethtool -S, nft list ruleset, tc counters and the airoha PPE debugfs
# files, so the CPU-idle, IRQ and PPE deltas in result.json can be
# recomputed from the raw files.
#
# result.json is written with jq-parseable JSON only; jq is not needed at
# run time.  The output directory also keeps raw.log, a chronological log
# of every command the harness ran.
#
# --baseline adds the part a number needs to be citable: a label, a
# free-form environment note, one static snapshot of the link (speed,
# duplex, driver), the offload features, the flowtable stanza and the
# kernel, plus CPU busy seconds per direction.  The citable record is
# result.json itself (schema bench-10g-unidirectional/v1): --baseline only
# widens it with an "environment" section, and prints a paste-ready
# claims.yaml entry whose source is that file.  The entry states the
# measured link speed, so a 1G run can never be quoted as a 10G baseline.
# No document is written: this repo keeps measurements in result.json.
#
# --peer-connects makes the box under test the passive end: it runs
# "iperf3 -s -1 -J" and the peer drives the traffic.  The box under test
# always has the snapshots in every mode, because the numbers that
# matter (CPU, PPE, interface counters) live on this box.
#
# POSIX sh only, so it runs on the OpenWrt device with busybox ash.
#
# Exit status: 0 both directions ran, 1 an iperf3 run failed or setup was
# impossible, 2 invalid arguments or a missing traffic tool (iperf3, recorded
# so scripts/wireless/hw-gap-report.sh can name it; --help documents them).

set -u
set -f
LC_ALL=C
export LC_ALL

PROG=${0##*/}
case $0 in
*/*) SCRIPT_DIR=${0%/*} ;;
*) SCRIPT_DIR=. ;;
esac
SCRIPT_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR" 2>/dev/null && pwd) || SCRIPT_DIR=.
# The script lives in <repo>/scripts, so the parent directory is <repo>.
REPO_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd) || REPO_DIR=

TARGET=${TARGET:-}
IFACE=${IFACE:-}
DURATION=${DURATION:-60}
PARALLEL=${PARALLEL:-4}
RESULT_DIR=${RESULT_DIR:-}
DUMP_FOE=${DUMP_FOE:-0}
PORT=${PORT:-5201}
BASELINE=${BASELINE:-0}
LABEL=${LABEL:-unlabelled}
ENV_NOTE=${ENV_NOTE:-}
PEER=${PEER:-client}
PEER_WAIT=${PEER_WAIT:-120}
# Where the stale-listener sweep looks, and what it kills it with.  Both are
# env seams so the test can point at a fixture /proc and a logging stub.
SWEEP_PROC=${BENCH_SWEEP_PROC:-/proc}
KILL_BIN=${BENCH_KILL:-kill}
DRY_RUN=0

# Snapshot file names are part of the on-disk format; keep them stable so
# two result directories can be diffed with the same path names.
S_PROC_STAT=proc-stat.txt
S_INTERRUPTS=proc-interrupts.txt
S_ETHTOOL=ethtool-stats.txt
S_NFT=nft-ruleset.txt
S_TC_QDISC=tc-qdisc.txt
S_TC_FILTER=tc-filter.txt
S_PPE_USAGE=ppe-usage.txt
S_PPE_ENTRIES=ppe-entries.txt
S_IFACE_COUNTERS=iface-counters.txt
S_UPTIME=uptime.txt
# --baseline only, written once per run into snapshots/env/.
S_LINK=ethtool-iface.txt
S_DRIVER=ethtool-driver.txt
S_FEATURES=ethtool-features.txt
S_SYSFS_LINK=sysfs-link.txt
S_FLOWTABLE=nft-flowtable.txt
S_NFT_FULL=nft-ruleset-full.txt
S_PORTS=link-ports.txt
S_KERNEL=kernel.txt
S_CPU=cpuinfo.txt
S_TOPOLOGY=topology.txt

usage() {
	cat <<'EOF'
Usage: bench-10g-unidirectional.sh [options]

A reproducible unidirectional 10G throughput bench.  TX and RX are two
separate iperf3 runs, never concurrent; each direction gets a full set
of before/after snapshots and its own entry in result.json.

Required inputs for a real run (environment variable or flag):
  TARGET / --target IP        peer running "iperf3 -s" (client role only;
                              --peer-connects does not need it)
  IFACE  / --iface NAME       local network interface under test
                              --dry-run accepts unset values and prints
                              them as <required> placeholders; a real run
                              refuses to start without both.

Optional inputs:
  DURATION / --duration SEC   seconds per direction (default 60)
  PARALLEL / --parallel N     iperf3 streams per direction (default 4)
  PORT / --port N             iperf3 port (default 5201, iperf3's own
                              default; both ends use the same port)
  RESULT_DIR / --result-dir DIR
                              output directory (default ./bench-10g-<epoch>)
  DUMP_FOE / --dump-foe       set to 1 to also snapshot the full FOE table,
                              /sys/kernel/debug/ppe/entries (about 32768
                              lines per snapshot; off by default)
  PEER_WAIT / --peer-wait SEC --peer-connects only: how long to wait for
                              the peer's test to arrive per direction
                              (default 120; must exceed DURATION + 10)
  LABEL / --label TEXT        --baseline only: the name this run is
                              quoted under (default: unlabelled)
  ENV_NOTE / --env-note TEXT   --baseline only: free-form description of
                              the peer, the path and anything between the
                              two ends (NAT, switch, cable, virtual link)

Options:
  --baseline                  also record the environment (link speed,
                              duplex, driver, offload features, flowtable
                              stanza, kernel, CPU count) in snapshots/env/
                              and in the "environment" section of
                              result.json, then print a paste-ready
                              claims.yaml entry whose source is
                              result.json:1 and which names the measured
                              link speed.  Needed before a number may be
                              quoted as a result.  Nothing is written
                              besides result.json and its captures.
  --peer-connects             the box under test is the passive end: it
                              runs "iperf3 -s -1 -J -p PORT" twice (once
                              per direction) and the peer runs
                              "iperf3 -c <box> -p PORT -t D -P P [-R]".
                              Use it when the box cannot open a
                              connection towards the peer (no default
                              route, or the peer only accepts inbound).
                              The harness prints the exact peer command
                              and waits up to PEER_WAIT seconds for it.
                              All snapshots still come from this box.
  --dry-run                   print the commands and every snapshot path,
                              then exit 0.  No directory is created, no
                              command is run, no peer is contacted and the
                              live interface is not validated.  Unset
                              TARGET/IFACE values appear as <required>.
  -h, --help                  this text

Real runs also refuse to start when TARGET or IFACE is empty, when the
interface does not exist or has no IPv4/IPv6 address, when iperf3 or the
ip command is not installed, or when RESULT_DIR/result.json already
exists (a previous run is never overwritten).  In client role the peer
must have "iperf3 -s" listening; it is not started by this harness.

Protocol, in this order:
  1. TX snapshots before  -> iperf3 -c TARGET -t DURATION -P PARALLEL -J
                          -> TX snapshots after
  2. RX snapshots before  -> iperf3 -c TARGET -t DURATION -P PARALLEL -R -J
                          -> RX snapshots after

With --peer-connects the same two windows use the passive form instead:
  1. TX: iperf3 -s -1 -J -p PORT (peer sends and passes -R), snapshots
  2. RX: iperf3 -s -1 -J -p PORT (peer sends, no -R), snapshots
So "TX" is always traffic from this box to the peer and "RX" always
traffic from the peer to this box, whichever end opens the connection.
TX and RX are still separate runs, never concurrent.

Each snapshot directory contains:
  proc-stat.txt          /proc/stat (all CPU lines)
  proc-interrupts.txt    /proc/interrupts
  ethtool-stats.txt      ethtool -S IFACE            (when ethtool exists)
  nft-ruleset.txt        nft list ruleset            (when nft exists)
  tc-qdisc.txt           tc -s qdisc show dev IFACE
  tc-filter.txt          tc -s filter show dev IFACE
  ppe-usage.txt          /sys/kernel/debug/ppe/usage  (when present)
  ppe-entries.txt        /sys/kernel/debug/ppe/entries (only DUMP_FOE=1)
  iface-counters.txt     sysfs rx/tx packet and byte counters, key value
  uptime.txt             /proc/uptime, bounds the pps measurement window

With --baseline, snapshots/env/ is written once, before the first
direction, because none of it changes during the run:
  ethtool-iface.txt      ethtool IFACE (speed, duplex, autoneg)
  ethtool-driver.txt     ethtool -i IFACE (driver and version)
  ethtool-features.txt   ethtool -k IFACE (offload on/off)
  sysfs-link.txt         /sys/class/net/IFACE/{speed,duplex,carrier,...}
  nft-flowtable.txt      the flowtable stanzas extracted from the ruleset
  link-ports.txt         speed/duplex and the key offload flags of every
                         link that reports a positive speed; a bridge
                         hides its members, so the members are listed
  kernel.txt             uname -a, /proc/version, /proc/cmdline
  cpuinfo.txt            CPU count and model from /proc/cpuinfo
  topology.txt           ip addr, ip route, per-port link map

Output directory:
  raw.log                chronological command log
  result.json            machine-readable result (schema
                         bench-10g-unidirectional/v1); the citable record
  iperf3-tx.json         raw iperf3 JSON for the TX run
  iperf3-rx.json         raw iperf3 JSON for the RX run
  snapshots/{tx,rx}-{before,after}/
  snapshots/env/         --baseline only, as above

result.json records the timestamp, git describe, kernel release, MTU,
iperf3 reported bits/s and derived Gbit/s per direction, interface-counter
pps, CPU idle tick deltas, per-IRQ deltas, and the airoha PPE bound / l2b
/ l2_flows_sw counts before and after each direction.  pps comes from the
interface packet counters over the iperf3 window; on interfaces with TSO
the TX counter counts skbs, not wire packets, so pps is a stack-side
measurement, not a line-rate measurement.

Examples:
  IFACE=wan TARGET=192.168.1.2 ./scripts/bench-10g-unidirectional.sh
  ./scripts/bench-10g-unidirectional.sh --target 192.168.1.2 --iface wan \
      --duration 30 --parallel 4 --result-dir /tmp/bench-run
  # citable baseline, box under test as the passive end:
  ./scripts/bench-10g-unidirectional.sh --baseline --peer-connects \
      --iface br-lan --label lan4-1g-2026-11-20 \
      --env-note "peer=host behind NAT, lan4 1000Mb/s" \
      --duration 5 --parallel 4 --result-dir /tmp/bench-baseline
  ./scripts/bench-10g-unidirectional.sh --help
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

# Shared "no client" record (scripts/wireless/lib/no-client.sh).  Best effort:
# the harness must still report the gap when the record cannot be written and
# the library is absent.
NO_CLIENT_LIB=$(dirname "$0")/wireless/lib/no-client.sh
# shellcheck source=wireless/lib/no-client.sh
[ -r "$NO_CLIENT_LIB" ] && . "$NO_CLIENT_LIB"

missing_iperf3() {
	# DETAIL: why iperf3 is required on this box.  There is no source slot:
	# with --peer-connects the box under test runs "iperf3 -s -1" and the peer
	# drives, and the JSON parser reads iperf3's own schema.  Record the gap in
	# a subdirectory so a result.json from an earlier run is never clobbered,
	# then exit 2 (recorded prerequisite, not a failed run).
	_cmd='IFACE=<IFACE> TARGET=<PEER_IP> scripts/bench-10g-unidirectional.sh --peer-connects'
	_rec=$(no_client_record "$RESULT_DIR/no-client" 13 iperf3 "$_cmd" "$1" \
		"both directions run and result.json carries bits/s, pps and PPE deltas" \
		"the flow binds in the PPE (ppe/usage bound entries grow)" 2>/dev/null)
	printf '%s: error: %s\n' "$PROG" "$1" >&2
	[ -n "$_rec" ] && printf '%s: no-client record: %s\n' "$PROG" "$_rec" >&2
	printf 'BLOCKED: missing iperf3\n'
	exit 2
}

require_positive_int() {
	case $2 in
	''|*[!0-9]*) usage_error "$1 must be a positive integer, got '$2'" ;;
	esac
	if [ "$2" -lt 1 ]; then
		usage_error "$1 must be greater than zero"
	fi
}

now_ts() {
	# UTC ISO 8601, with a local-time fallback for old date implementations.
	_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || _ts=
	if [ -z "$_ts" ]; then
		_ts=$(date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null) || _ts=unknown
	fi
	printf '%s' "$_ts"
}

json_escape() {
	printf '%s' "$1" | tr '\n\r\t' '   ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
		-e 's/[[:cntrl:]]/ /g'
}

# Yields "null" when a value is unavailable; otherwise a JSON number.
json_num() {
	case $1 in
	''|null) printf 'null' ;;
	*) printf '%s' "$1" ;;
	esac
}

# Bit/s -> Gbit/s, three decimals.
gbit() {
	awk -v b="$1" 'BEGIN { printf "%.3f", b / 1000000000.0 }'
}

# Integer delta for two counter values, or "null" if either is missing.
int_delta() {
	case $1 in ''|null) printf 'null'; return ;; esac
	case $2 in ''|null) printf 'null'; return ;; esac
	awk -v a="$1" -v b="$2" 'BEGIN { printf "%d", a - b }'
}

log_note() {
	printf '%s %s\n' "$(now_ts)" "$*" >>"$RAW_LOG"
}

log_cmd() {
	printf '%s + %s\n' "$(now_ts)" "$*" >>"$RAW_LOG"
}

# Write a snapshot file by running the given command, merging stdout and
# stderr.  A failing optional command is recorded in the file and in the
# raw log but does not abort the bench: an unreadable nft ruleset or PPE
# file must not invalidate the throughput measurement.
capture() {
	_out=$1
	shift
	log_cmd "$* > $_out"
	if "$@" >"$_out" 2>&1; then
		return 0
	else
		_st=$?
	fi
	printf '\n[command exited %s]\n' "$_st" >>"$_out"
	log_note "command failed (exit $_st): $*"
	return 0
}

note_file() {
	printf '%s\n' "$2" >"$1"
	log_note "$2"
}

snapshot_dir() {
	printf '%s/snapshots/%s' "$RESULT_DIR" "$1"
}

capture_iface_counters() {
	_out=$1
	{
		for _k in rx_packets tx_packets rx_bytes tx_bytes rx_errors tx_errors \
			rx_dropped tx_dropped; do
			_v=$(cat "/sys/class/net/$IFACE/statistics/$_k" 2>/dev/null) || _v=
			if [ -n "$_v" ]; then
				printf '%s %s\n' "$_k" "$_v"
			fi
		done
	} >"$_out" 2>&1
	log_cmd "read /sys/class/net/$IFACE/statistics/{rx_packets,tx_packets,rx_bytes,tx_bytes,rx_errors,tx_errors,rx_dropped,tx_dropped} > $_out"
}

# Everything except iface counters and /proc/{uptime,stat,interrupts}, which
# are taken adjacent to the iperf3 window so their deltas cover only the run.
snapshot_extra() {
	_dir=$1
	if command -v ethtool >/dev/null 2>&1; then
		capture "$_dir/$S_ETHTOOL" ethtool -S "$IFACE"
	else
		note_file "$_dir/$S_ETHTOOL" "ethtool not installed"
	fi
	if command -v nft >/dev/null 2>&1; then
		capture "$_dir/$S_NFT" nft list ruleset
	else
		note_file "$_dir/$S_NFT" "nft not installed"
	fi
	if command -v tc >/dev/null 2>&1; then
		capture "$_dir/$S_TC_QDISC" tc -s qdisc show dev "$IFACE"
		capture "$_dir/$S_TC_FILTER" tc -s filter show dev "$IFACE"
	else
		note_file "$_dir/$S_TC_QDISC" "tc not installed"
		note_file "$_dir/$S_TC_FILTER" "tc not installed"
	fi
	if [ -r /sys/kernel/debug/ppe/usage ]; then
		capture "$_dir/$S_PPE_USAGE" cat /sys/kernel/debug/ppe/usage
	else
		note_file "$_dir/$S_PPE_USAGE" "not readable: /sys/kernel/debug/ppe/usage"
	fi
	if [ "$DUMP_FOE" = 1 ]; then
		if [ -r /sys/kernel/debug/ppe/entries ]; then
			capture "$_dir/$S_PPE_ENTRIES" cat /sys/kernel/debug/ppe/entries
		else
			note_file "$_dir/$S_PPE_ENTRIES" "not readable: /sys/kernel/debug/ppe/entries"
		fi
	fi
}

snapshot_before() {
	_dir=$(snapshot_dir "$1-before")
	log_note "snapshot before $1: $_dir"
	snapshot_extra "$_dir"
	capture_iface_counters "$_dir/$S_IFACE_COUNTERS"
	capture "$_dir/$S_UPTIME" cat /proc/uptime
	capture "$_dir/$S_PROC_STAT" cat /proc/stat
	capture "$_dir/$S_INTERRUPTS" cat /proc/interrupts
}

snapshot_after() {
	_dir=$(snapshot_dir "$1-after")
	log_note "snapshot after $1: $_dir"
	capture_iface_counters "$_dir/$S_IFACE_COUNTERS"
	capture "$_dir/$S_PROC_STAT" cat /proc/stat
	capture "$_dir/$S_INTERRUPTS" cat /proc/interrupts
	capture "$_dir/$S_UPTIME" cat /proc/uptime
	snapshot_extra "$_dir"
}

# The offload flags of one link, as "tso gro gso hw-tc-offload"; "?" when
# ethtool is missing or the kernel does not report the feature.
port_flags() {
	if ! command -v ethtool >/dev/null 2>&1; then
		printf '? ? ? ?'
		return
	fi
	ethtool -k "$1" 2>/dev/null | awk '
		$1 ~ /:$/ {
			k = $1
			sub(/:/, "", k)
			if (k == "tcp-segmentation-offload") tso = $2
			else if (k == "generic-receive-offload") gro = $2
			else if (k == "generic-segmentation-offload") gso = $2
			else if (k == "hw-tc-offload") hw = $2
		}
		END {
			printf "%s %s %s %s", \
				(tso == "" ? "?" : tso), (gro == "" ? "?" : gro), \
				(gso == "" ? "?" : gso), (hw == "" ? "?" : hw)
		}'
}

# --baseline: the environment a number is only valid inside.  Taken once,
# before the first direction, because none of it changes while the bench
# runs.  Every file is a raw capture, not a summary.
snapshot_env() {
	_dir=$(snapshot_dir env)
	log_note "snapshot env: $_dir"
	mkdir -p "$_dir" || die "cannot create $_dir"

	if command -v ethtool >/dev/null 2>&1; then
		capture "$_dir/$S_LINK" ethtool "$IFACE"
		capture "$_dir/$S_DRIVER" ethtool -i "$IFACE"
		capture "$_dir/$S_FEATURES" ethtool -k "$IFACE"
	else
		note_file "$_dir/$S_LINK" "ethtool not installed"
		note_file "$_dir/$S_DRIVER" "ethtool not installed"
		note_file "$_dir/$S_FEATURES" "ethtool not installed"
	fi

	{
		for _k in speed duplex carrier operstate mtu; do
			_v=$(cat "/sys/class/net/$IFACE/$_k" 2>/dev/null) || _v=
			if [ -n "$_v" ]; then
				printf '%s %s\n' "$_k" "$_v"
			fi
		done
	} >"$_dir/$S_SYSFS_LINK" 2>&1
	log_cmd "read /sys/class/net/$IFACE/{speed,duplex,carrier,operstate,mtu} > $_dir/$S_SYSFS_LINK"

	# The flowtable stanza is what decides whether the PPE sees flows at
	# all; the full ruleset stays next to it so the stanza can be checked
	# in context.
	if command -v nft >/dev/null 2>&1; then
		capture "$_dir/$S_NFT_FULL" nft list ruleset
		{
			printf 'extracted from %s; blank means no flowtable stanza\n' \
				"$S_NFT_FULL"
			awk '/^[ \t]*flowtable /{ f = 1 }
			     f { print }
			     f && /^[ \t]*}/{ f = 0 }' "$_dir/$S_NFT_FULL"
		} >"$_dir/$S_FLOWTABLE" 2>&1
	else
		note_file "$_dir/$S_NFT_FULL" "nft not installed"
		note_file "$_dir/$S_FLOWTABLE" "nft not installed"
	fi

	# A bridge hides its members, so the members are listed one by one:
	# only links with a positive speed are real candidates for traffic.
	{
		printf 'port speed_mbps duplex carrier operstate tso gro gso hw-tc-offload\n'
		# shellcheck disable=SC2045  # /sys/class/net names hold no blanks
		for _p in $(ls /sys/class/net 2>/dev/null); do
			_s=$(cat "/sys/class/net/$_p/speed" 2>/dev/null) || _s=
			case $_s in
			''|*[!0-9]*) continue ;;
			esac
			[ "$_s" -gt 0 ] 2>/dev/null || continue
			# shellcheck disable=SC2046  # four flags, split on purpose
			printf '%s %s %s %s %s %s\n' "$_p" "$_s" \
				"$(cat "/sys/class/net/$_p/duplex" 2>/dev/null)" \
				"$(cat "/sys/class/net/$_p/carrier" 2>/dev/null)" \
				"$(cat "/sys/class/net/$_p/operstate" 2>/dev/null)" \
				"$(port_flags "$_p")"
		done
	} >"$_dir/$S_PORTS" 2>&1
	log_cmd "speed/duplex/flags of every link with a positive speed > $_dir/$S_PORTS"

	{
		uname -a
		printf '\n/proc/version:\n'
		cat /proc/version
		printf '\n/proc/cmdline:\n'
		cat /proc/cmdline
	} >"$_dir/$S_KERNEL" 2>&1
	log_cmd "uname -a, /proc/version, /proc/cmdline > $_dir/$S_KERNEL"

	{
		awk -F: '
			/^processor/ { n++ }
			/^model name|^CPU part|^Processor|^cpu model/ { m = $0; sub(/^[^:]*:[ \t]*/, "", m) }
			END {
				printf "processors: %d\n", n
				printf "model: %s\n", (m == "" ? "unknown" : m)
			}' /proc/cpuinfo
		printf '\n--- /proc/cpuinfo ---\n'
		cat /proc/cpuinfo
	} >"$_dir/$S_CPU" 2>&1
	log_cmd "processor count and model from /proc/cpuinfo > $_dir/$S_CPU"

	{
		printf -- '--- ip addr ---\n'
		ip addr 2>&1
		printf -- '--- ip route ---\n'
		ip route 2>&1
		printf -- '--- links ---\n'
		cat "$_dir/$S_PORTS" 2>/dev/null
	} >"$_dir/$S_TOPOLOGY" 2>&1
	log_cmd "ip addr, ip route and link map > $_dir/$S_TOPOLOGY"
}

iperf_cmd_string() {
	if [ "$PEER" = server ]; then
		printf 'iperf3 -s -1 -J -p %s' "$PORT"
	elif [ "$1" = rx ]; then
		printf 'iperf3 -c %s -t %s -P %s -R -J -p %s' \
			"$TARGET" "$DURATION" "$PARALLEL" "$PORT"
	else
		printf 'iperf3 -c %s -t %s -P %s -J -p %s' \
			"$TARGET" "$DURATION" "$PARALLEL" "$PORT"
	fi
}

# The address the peer has to connect to, taken from IFACE (the passive
# role cannot rely on a default route, and the peer is not given an
# address out of thin air).
box_ip() {
	if [ "${_box_ip:-}" != "" ]; then
		printf '%s' "$_box_ip"
		return
	fi
	_w=$(ip -o addr show dev "$IFACE" 2>/dev/null |
		awk '$3 == "inet" { print $4; exit }')
	printf '%s' "${_w%%/*}"
}

# The command the peer has to run, printed by --peer-connects so the two
# ends cannot disagree about direction or port.
peer_cmd_string() {
	_ip=$(box_ip)
	[ -n "$_ip" ] || _ip='<box-ip>'
	if [ "$1" = tx ]; then
		printf 'iperf3 -c %s -t %s -P %s -R -p %s' \
			"$_ip" "$DURATION" "$PARALLEL" "$PORT"
	else
		printf 'iperf3 -c %s -t %s -P %s -p %s' \
			"$_ip" "$DURATION" "$PARALLEL" "$PORT"
	fi
}

# True (return 0) when PID has exited, including un-reaped zombie/dead states.
pid_exited() {
	if ! kill -0 "$1" 2>/dev/null; then
		return 0
	fi
	case $(awk '/^State:/ { print $2; exit }' "/proc/$1/status" 2>/dev/null) in
	Z|X) return 0 ;;
	esac
	return 1
}

# Passive role: this box listens and the peer drives the traffic.  iperf3
# -1 serves exactly one test and then exits, so polling the listener PID
# detects completion (or early failure) immediately and preserves the real
# wait exit status.  The wait is bounded by PEER_WAIT so an absent peer
# fails the direction instead of hanging.
serve_iperf() {
	_dir=$1
	_out=$2
	_err=$3
	log_cmd "$(iperf_cmd_string "$_dir") > $_out"
	: >"$_out"
	sweep_stale_listeners
	# Backgrounded with its pid kept, so a timeout stops this listener and
	# never another iperf3 that happens to run on the same box.
	iperf3 -s -1 -J -p "$PORT" >"$_out" 2>"$_err" </dev/null &
	_lpid=$!
	printf 'peer now, for %s: %s\n' "$_dir" "$(peer_cmd_string "$_dir")"
	_w=0
	_timed_out=1
	while [ "$_w" -lt "$PEER_WAIT" ]; do
		if pid_exited "$_lpid"; then
			_timed_out=0
			break
		fi
		sleep 1
		_w=$((_w + 1))
	done
	if [ "$_timed_out" -ne 0 ] && pid_exited "$_lpid"; then
		_timed_out=0
	fi
	if [ "$_timed_out" -ne 0 ]; then
		log_note "no peer test arrived within ${PEER_WAIT}s for $_dir"
		# -1 keeps the listener alive until one test arrives; stop it,
		# and only it.
		kill "$_lpid" 2>/dev/null || :
		wait "$_lpid" 2>/dev/null || :
		_st=124
	else
		wait "$_lpid" 2>/dev/null
		_st=$?
	fi
	if [ "$_st" -eq 0 ] && ! iperf_json_check "$_dir" "$_out"; then
		_st=1
	fi
	if [ -s "$_err" ]; then
		log_note "iperf3 $_dir stderr:"
		cat "$_err" >>"$RAW_LOG"
	else
		rm -f "$_err"
	fi
	log_note "iperf3 $_dir exit=$_st"
	return "$_st"
}

# A harness killed mid-run leaves `iperf3 -s -1 -p PORT` behind: -1 keeps it
# alive until one test arrives, and nothing else ever stops it.  The next
# passive run then either cannot listen, or the peer's test lands on that
# foreign server and the number is measured by a process nobody controls;
# its data ports (PORT+1..PORT+N) stay bound as well.  BusyBox has no pkill,
# and "set -f" above disables globbing, so /proc is walked by ls.  Only the
# server role on this port is swept: a client-role run talks to a peer server
# that is supposed to exist.
sweep_stale_listeners() {
	_swept=0
	for _pid in $(ls "$SWEEP_PROC" 2>/dev/null); do
		case $_pid in
		'' | *[!0-9]*) continue ;;
		esac
		_cmd=$SWEEP_PROC/$_pid/cmdline
		[ -r "$_cmd" ] || continue
		if tr '\000' '\n' <"$_cmd" 2>/dev/null | awk -v p="$PORT" '
			BEGIN { prev = "" }
			{
				n = split($0, w, "/")
				if (w[n] == "iperf3") bin = 1
				if ($0 == "-s") srv = 1
				if (prev == "-p" && $0 == p) port = 1
				prev = $0
			}
			END { exit !(bin && srv && port) }
		'; then
			"$KILL_BIN" "$_pid" 2>/dev/null || :
			_swept=$((_swept + 1))
		fi
	done
	if [ "$_swept" -gt 0 ] && [ "${DRY_RUN:-0}" -eq 0 ]; then
		log_note "swept $_swept stale iperf3 listener(s) on port $PORT"
	fi
	return 0
}

# Runs one direction only.  The caller decides when the next direction
# starts; there is deliberately no background job here.
run_iperf() {
	if [ "$PEER" = server ]; then
		serve_iperf "$@"
		return $?
	fi
	_dir=$1
	_out=$2
	_err=$3
	log_cmd "$(iperf_cmd_string "$_dir") > $_out"
	if [ "$_dir" = rx ]; then
		iperf3 -c "$TARGET" -t "$DURATION" -P "$PARALLEL" -R -J -p "$PORT" \
			>"$_out" 2>"$_err"
	else
		iperf3 -c "$TARGET" -t "$DURATION" -P "$PARALLEL" -J -p "$PORT" \
			>"$_out" 2>"$_err"
	fi
	_st=$?
	if [ "$_st" -eq 0 ] && ! iperf_json_check "$_dir" "$_out"; then
		_st=1
	fi
	if [ -s "$_err" ]; then
		log_note "iperf3 $_dir stderr:"
		cat "$_err" >>"$RAW_LOG"
	else
		rm -f "$_err"
	fi
	log_note "iperf3 $_dir exit=$_st"
	return "$_st"
}

# Extract the eight numbers the result needs from iperf3's pretty-printed
# JSON: sum_sent and sum_received bit/s, bytes, seconds and retransmits.
# Missing values stay "null"; a failed connection still yields JSON.
iperf_summary() {
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

# iperf3 writes its own error message into the JSON on a failed run.
iperf_error() {
	awk '
	match($0, /"error":[[:space:]]*"[^"]*"/) {
		v = substr($0, RSTART, RLENGTH)
		sub(/^"error":[[:space:]]*"/, "", v)
		sub(/"$/, "", v)
		print v
		exit
	}
	' "$1"
}

# Verify an iperf3 JSON capture succeeded: no "error" field and a positive
# numeric (non-null) bits_per_second for the measured direction.
iperf_json_check() {
	_jc_dir=$1
	_jc_out=$2
	if [ ! -r "$_jc_out" ] || [ ! -s "$_jc_out" ]; then
		log_note "iperf3 $_jc_dir produced no JSON output"
		return 1
	fi
	_jc_err=$(iperf_error "$_jc_out")
	if [ -n "$_jc_err" ]; then
		log_note "iperf3 $_jc_dir reported JSON error: $_jc_err"
		return 1
	fi
	_jc_line=$(iperf_summary "$_jc_out")
	_jc_bps=null
	if [ -n "$_jc_line" ]; then
		# shellcheck disable=SC2086
		set -- $_jc_line
		if [ "$#" -ge 8 ]; then
			if [ "$_jc_dir" = rx ]; then _jc_bps=$5; else _jc_bps=$1; fi
		fi
	fi
	if ! awk -v b="$_jc_bps" 'BEGIN {
		exit !(b ~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/ && (b + 0) > 0)
	}'; then
		log_note "iperf3 $_jc_dir produced null or non-positive bits_per_second ($_jc_bps)"
		return 1
	fi
	return 0
}

# Delta of two counter snapshots, each "key value" per line.
counter_delta() {
	case $1 in '') printf 'null'; return ;; esac
	if [ ! -r "$1" ] || [ ! -r "$2" ]; then
		printf 'null'
		return
	fi
	awk -v k="$3" '
	FNR == NR { if ($1 == k) { b = $2; bs = 1 } next }
	$1 == k { a = $2; as = 1 }
	END { if (bs && as) printf "%d", a - b; else printf "null" }
	' "$1" "$2"
}

# Delta of /proc/uptime snapshots in seconds; bounds the pps window.
uptime_delta() {
	if [ ! -r "$1" ] || [ ! -r "$2" ]; then
		printf 'null'
		return
	fi
	awk '
	FNR == NR { b = $1; next }
	{ printf "%.3f", $1 - b }
	' "$1" "$2"
}

# Compute wire pps (null when TSO/GSO/GRO coalescing is detected), skb_per_sec,
# avg_bytes_per_pkt, coalesced (true|false), and window_skew_pct.  Divides rate
# by iperf3.seconds when positive numeric, falling back to /proc/uptime delta.
pkt_rate_metrics() {
	awk -v pkts="$1" -v bytes="$2" -v isec="$3" -v el="$4" -v mtu="$5" '
	function is_pos_num(v) {
		return (v ~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/ && (v + 0) > 0)
	}
	function is_nonneg_num(v) {
		return (v ~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/ && (v + 0) >= 0)
	}
	BEGIN {
		pps = "null"
		skb = "null"
		avg = "null"
		coal = "false"
		skew = "null"

		has_isec = is_pos_num(isec)
		has_el = is_pos_num(el)
		if (has_isec && has_el) {
			skew = sprintf("%.2f", ((el + 0) - (isec + 0)) * 100.0 / (isec + 0))
		}

		denom = 0
		if (has_isec) denom = isec + 0
		else if (has_el) denom = el + 0

		if (is_nonneg_num(pkts) && denom > 0) {
			rate = (pkts + 0) / denom
			skb = sprintf("%.1f", rate)
			pps = skb
		}

		if (is_pos_num(pkts) && is_nonneg_num(bytes)) {
			av = (bytes + 0) / (pkts + 0)
			avg = sprintf("%.1f", av)
			if (is_pos_num(mtu) && av > (mtu + 18)) {
				coal = "true"
				pps = "null"
			}
		}

		printf "%s %s %s %s %s\n", pps, skb, avg, coal, skew
	}'
}

# CPU idle deltas from /proc/stat.  Idle excludes iowait; idle_pct uses
# idle+iowait over total, which is the usual definition of "idle".
cpu_json() {
	if [ ! -r "$1" ] || [ ! -r "$2" ]; then
		printf 'null\n'
		return
	fi
	awk '
	FNR == NR {
		if ($1 ~ /^cpu[0-9]*$/) {
			bidle[$1] = $5
			bwait[$1] = $6
			btot[$1] = $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9
			order[++n] = $1
		}
		next
	}
	$1 ~ /^cpu[0-9]*$/ {
		if ($1 in bidle) {
			aidle[$1] = $5
			await[$1] = $6
			atot[$1] = $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9
			seen[$1] = 1
		}
	}
	END {
		if (!seen["cpu"]) { print "null"; exit }
		idle = aidle["cpu"] - bidle["cpu"]
		wait = await["cpu"] - bwait["cpu"]
		total = atot["cpu"] - btot["cpu"]
		pct = total > 0 ? (idle + wait) * 100 / total : 0
		printf "{\"idle_ticks_delta\":%d,\"iowait_ticks_delta\":%d,", idle, wait
		printf "\"total_ticks_delta\":%d,\"idle_pct\":%.2f,\"per_cpu\":[", total, pct
		first = 1
		for (i = 1; i <= n; i++) {
			k = order[i]
			if (k == "cpu" || !seen[k]) continue
			ci = aidle[k] - bidle[k]
			cw = await[k] - bwait[k]
			ct = atot[k] - btot[k]
			cpct = ct > 0 ? (ci + cw) * 100 / ct : 0
			if (!first) printf ","
			first = 0
			printf "{\"cpu\":\"%s\",\"idle_ticks_delta\":%d,\"iowait_ticks_delta\":%d,\"total_ticks_delta\":%d,\"idle_pct\":%.2f}", k, ci, cw, ct, cpct
		}
		printf "]}\n"
	}
	' "$1" "$2"
}

# /proc/stat ticks are exported in USER_HZ (sysconf(_SC_CLK_TCK), 100 on Linux),
# never kernel CONFIG_HZ (e.g. 250).  BENCH_CLK_TCK overrides for tests.
clk_tck() {
	_hz=${BENCH_CLK_TCK:-$(getconf CLK_TCK 2>/dev/null || echo 100)}
	case $_hz in
	''|*[!0-9]*) _hz=100 ;;
	esac
	if [ "$_hz" -le 0 ]; then
		_hz=100
	fi
	printf '%s\n' "$_hz"
}

# CPU time spent inside one direction, in CPU-seconds.  Same /proc/stat
# fields as cpu_json, scaled by clk_tck() (USER_HZ=100, never CONFIG_HZ=250);
# idle_pct counts iowait as idle.
cpu_seconds() {
	if [ ! -r "$1" ] || [ ! -r "$2" ]; then
		printf 'null null null\n'
		return
	fi
	awk -v hz="$(clk_tck)" '
	FNR == NR {
		if ($1 == "cpu") {
			bt = $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9
			bi = $5 + $6
		}
		next
	}
	$1 == "cpu" {
		at = $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9
		ai = $5 + $6
	}
	END {
		if (bt == "" || at == "") { print "null null null"; exit }
		dt = at - bt
		di = ai - bi
		if (dt <= 0) { print "null null null"; exit }
		printf "%.2f %.2f %.2f\n", (dt - di) / hz, dt / hz, di * 100 / dt
	}
	' "$1" "$2"
}

# Per-IRQ deltas from /proc/interrupts.  Named pseudo-interrupts (NMI,
# LOC, ...) are skipped; hardware IRQs always have numeric lines.
irq_json() {
	if [ ! -r "$1" ] || [ ! -r "$2" ]; then
		printf 'null\n'
		return
	fi
	awk '
	FNR == NR {
		if ($1 ~ /^[0-9]+:$/) {
			irq = $1
			sub(/:/, "", irq)
			sum = 0
			j = 2
			while (j <= NF && $j ~ /^[0-9]+$/) { sum += $j; j++ }
			bidx[irq] = sum
			order[++n] = irq
		}
		next
	}
	$1 ~ /^[0-9]+:$/ {
		irq = $1
		sub(/:/, "", irq)
		sum = 0
		j = 2
		while (j <= NF && $j ~ /^[0-9]+$/) { sum += $j; j++ }
		aidx[irq] = sum
		desc = ""
		for (k = j; k <= NF; k++) desc = desc (k == j ? "" : " ") $k
		adesc[irq] = desc
		seen[irq] = 1
	}
	END {
		for (i = 1; i <= n; i++) {
			irq = order[i]
			if (!seen[irq]) continue
			d = aidx[irq] - bidx[irq]
			delta[irq] = d
			total += d
		}
		printf "{\"total_delta\":%d,\"per_irq\":[", total
		first = 1
		for (i = 1; i <= n; i++) {
			irq = order[i]
			if (!seen[irq] || delta[irq] == 0) continue
			d = adesc[irq]
			gsub(/["\\]/, "_", d)
			if (!first) printf ","
			first = 0
			printf "{\"irq\":%s,\"desc\":\"%s\",\"delta\":%d}", irq, d, delta[irq]
		}
		printf "]}\n"
	}
	' "$1" "$2"
}

# airoha PPE usage (see target/linux/airoha/patches-7.4/205): eight values,
# "null" per value when the file does not parse.
ppe_fields() {
	if [ ! -r "$1" ]; then
		printf 'null null null null null null null null\n'
		return
	fi
	awk '
	function num(x) { gsub(/[^0-9]/, "", x); return x }
	$1 == "entries" { e = $2; s = num($4); d = num($6) }
	$1 == "bound" { b = $2; p = num($3); u = num($5) }
	$1 == "l2b_bound" { l = $2; f = num($4) }
	END {
		printf "%s %s %s %s %s %s %s %s\n", \
			(e == "" ? "null" : e), (s == "" ? "null" : s), \
			(d == "" ? "null" : d), (b == "" ? "null" : b), \
			(p == "" ? "null" : p), (u == "" ? "null" : u), \
			(l == "" ? "null" : l), (f == "" ? "null" : f)
	}
	' "$1"
}

emit_direction() {
	_dn=$1
	_ist=$2
	_ijson=$3
	_bdir=$4
	_adir=$5

	_sbps=null; _sbytes=null; _ssecs=null; _sretr=null
	_rbps=null; _rbytes=null; _rsecs=null; _rretr=null
	if [ -r "$_ijson" ]; then
		_iline=$(iperf_summary "$_ijson")
		if [ -n "$_iline" ]; then
			# shellcheck disable=SC2086  # deliberate word splitting of numbers
			set -- $_iline
			if [ "$#" -ge 8 ]; then
				_sbps=$1; _sbytes=$2; _ssecs=$3; _sretr=$4
				_rbps=$5; _rbytes=$6; _rsecs=$7; _rretr=$8
			fi
		fi
	fi

	if [ "$_dn" = rx ]; then
		_bps=$_rbps
		_bytes=$_rbytes
		_secs=$_rsecs
		_peer=$_sbps
		_tsrc=iperf3.sum_received.bits_per_second
		_pktkey=rx_packets
	else
		_bps=$_sbps
		_bytes=$_sbytes
		_secs=$_ssecs
		_peer=$_rbps
		_tsrc=iperf3.sum_sent.bits_per_second
		_pktkey=tx_packets
	fi
	_retr=$_sretr

	_imsg=
	if [ -r "$_ijson" ]; then
		_imsg=$(iperf_error "$_ijson")
	fi
	_ok=false
	if [ "$_ist" -eq 0 ] && [ "$_bps" != null ] && [ -z "$_imsg" ]; then
		_ok=true
	fi

	if [ "$_bps" = null ]; then
		_gbps=null
		_pgbps=null
	else
		_gbps=$(gbit "$_bps")
		if [ "$_peer" = null ]; then
			_pgbps=null
		else
			_pgbps=$(gbit "$_peer")
		fi
	fi

	_err=null
	if [ "$_ok" != true ]; then
		if [ -n "$_imsg" ]; then
			_err="\"$(json_escape "$_imsg")\""
		elif [ "$_ist" -ne 0 ]; then
			_err="\"$(json_escape "iperf3 exited $_ist")\""
		else
			_err="\"null bits_per_second\""
		fi
	fi

	_el=$(uptime_delta "$_bdir/$S_UPTIME" "$_adir/$S_UPTIME")
	_txp=$(counter_delta "$_bdir/$S_IFACE_COUNTERS" "$_adir/$S_IFACE_COUNTERS" tx_packets)
	_rxp=$(counter_delta "$_bdir/$S_IFACE_COUNTERS" "$_adir/$S_IFACE_COUNTERS" rx_packets)
	_txb=$(counter_delta "$_bdir/$S_IFACE_COUNTERS" "$_adir/$S_IFACE_COUNTERS" tx_bytes)
	_rxb=$(counter_delta "$_bdir/$S_IFACE_COUNTERS" "$_adir/$S_IFACE_COUNTERS" rx_bytes)
	_txe=$(counter_delta "$_bdir/$S_IFACE_COUNTERS" "$_adir/$S_IFACE_COUNTERS" tx_errors)
	_rxe=$(counter_delta "$_bdir/$S_IFACE_COUNTERS" "$_adir/$S_IFACE_COUNTERS" rx_errors)

	if [ "$_dn" = rx ]; then
		_pktdelta=$_rxp
		_bytedelta=$_rxb
	else
		_pktdelta=$_txp
		_bytedelta=$_txb
	fi
	# shellcheck disable=SC2046
	set -- $(pkt_rate_metrics "$_pktdelta" "$_bytedelta" "$_secs" "$_el" "${_mtu:-0}")
	_pps=$1; _skb_s=$2; _avg_b=$3; _coal=$4; _skew=$5

	_cpu=$(cpu_json "$_bdir/$S_PROC_STAT" "$_adir/$S_PROC_STAT")
	_irq=$(irq_json "$_bdir/$S_INTERRUPTS" "$_adir/$S_INTERRUPTS")

	# shellcheck disable=SC2046,SC2086  # deliberate splitting of eight fields
	set -- $(ppe_fields "$_bdir/$S_PPE_USAGE")
	_bb_e=$1; _bb_s=$2; _bb_d=$3; _bb_b=$4; _bb_p=$5; _bb_u=$6; _bb_l=$7; _bb_f=$8
	# shellcheck disable=SC2046,SC2086
	set -- $(ppe_fields "$_adir/$S_PPE_USAGE")
	_ab_e=$1; _ab_s=$2; _ab_d=$3; _ab_b=$4; _ab_p=$5; _ab_u=$6; _ab_l=$7; _ab_f=$8

	_ppe_ok=false
	if [ "$_bb_e" != null ] && [ "$_ab_e" != null ]; then
		_ppe_ok=true
	fi
	if [ "$_ppe_ok" = true ]; then
		_b_ppe="{\"entries\":$_bb_e,\"sram\":$_bb_s,\"dram\":$_bb_d,\"bound\":$_bb_b,\"bound_pct\":$_bb_p,\"unbound\":$_bb_u,\"l2b_bound\":$_bb_l,\"l2_flows_sw\":$_bb_f}"
		_a_ppe="{\"entries\":$_ab_e,\"sram\":$_ab_s,\"dram\":$_ab_d,\"bound\":$_ab_b,\"bound_pct\":$_ab_p,\"unbound\":$_ab_u,\"l2b_bound\":$_ab_l,\"l2_flows_sw\":$_ab_f}"
		_b_delta=$(int_delta "$_ab_b" "$_bb_b")
		_l_delta=$(int_delta "$_ab_l" "$_bb_l")
		_f_delta=$(int_delta "$_ab_f" "$_bb_f")
	else
		_b_ppe=null
		_a_ppe=null
		_b_delta=null
		_l_delta=null
		_f_delta=null
	fi

	_cmd=$(iperf_cmd_string "$_dn")
	printf '{"direction":"%s","ok":%s,"exit_status":%s,' \
		"$_dn" "$_ok" "$_ist"
	printf '"iperf3":{"command":"%s","bits_per_second":%s,"gbps":%s,' \
		"$(json_escape "$_cmd")" "$(json_num "$_bps")" "$_gbps"
	printf '"bytes":%s,"seconds":%s,"retransmits":%s,' \
		"$(json_num "$_bytes")" "$(json_num "$_secs")" "$(json_num "$_retr")"
	printf '"peer_bits_per_second":%s,"peer_gbps":%s,"throughput_source":"%s"},' \
		"$(json_num "$_peer")" "$_pgbps" "$_tsrc"
	printf '"pps":%s,"pps_source":"iface:%s",' \
		"$_pps" "$_pktkey"
	printf '"skb_per_sec":%s,"avg_bytes_per_pkt":%s,"coalesced":%s,"window_skew_pct":%s,' \
		"$_skb_s" "$_avg_b" "$_coal" "$_skew"
	printf '"iface_counters":{"elapsed_s":%s,"tx_packets_delta":%s,' "$_el" "$_txp"
	printf '"rx_packets_delta":%s,"tx_bytes_delta":%s,' "$_rxp" "$_txb"
	printf '"rx_bytes_delta":%s,"tx_errors_delta":%s,"rx_errors_delta":%s},' \
		"$_rxb" "$_txe" "$_rxe"
	printf '"cpu_idle":%s,' "$_cpu"
	printf '"irq":%s,' "$_irq"
	printf '"ppe":{"available":%s,"usage_path":"/sys/kernel/debug/ppe/usage",' \
		"$_ppe_ok"
	printf '"before":%s,"after":%s,"bound_delta":%s,' "$_b_ppe" "$_a_ppe" "$_b_delta"
	printf '"l2b_bound_delta":%s,"l2_flows_sw_delta":%s},' "$_l_delta" "$_f_delta"
	printf '"snapshots":{"before":"snapshots/%s-before","after":"snapshots/%s-after",' \
		"$_dn" "$_dn"
	printf '"iperf3":"iperf3-%s.json"},' "$_dn"
	printf '"error":%s}\n' "$_err"
}

# --baseline: the citable record, printed to stdout on top of result.json.
# Every number here is read back out of the capture files of this run
# (never from the terminal), and every line that qualifies a number is
# printed next to it, so a reader can tell a 1G measurement from a 10G one
# without asking.  Nothing is written to a file: result.json is the record,
# because this repo keeps measurements as data, not as prose documents.
emit_baseline_summary() {
	_tx_st=$1
	_rx_st=$2
	_edir=$(snapshot_dir env)
	_ts=$(now_ts)

	_speed=$(cat "/sys/class/net/$IFACE/speed" 2>/dev/null) || _speed=
	case $_speed in
	''|*[!0-9]*) _speed= ;;
	esac
	if [ -z "$_speed" ] || [ "$_speed" -le 0 ]; then
		_speed=$(awk '
			/^[ \t]*Speed:/ {
				v = $2
				gsub(/[^0-9]/, "", v)
				if (v != "") { print v; exit }
			}' "$_edir/$S_LINK" 2>/dev/null)
	fi
	[ -n "$_speed" ] || _speed=unknown

	_duplex=$(cat "/sys/class/net/$IFACE/duplex" 2>/dev/null) || _duplex=
	if [ -z "$_duplex" ]; then
		# a bridge has no duplex of its own; the members carry it
		_duplex=$(awk '
			/^[ \t]*Duplex:/ {
				v = $2
				if (v != "") { print tolower(v); exit }
			}' "$_edir/$S_LINK" 2>/dev/null)
	fi
	[ -n "$_duplex" ] || _duplex=unknown

	# the bridge itself reports no duplex, so the members are named: a
	# reader has to know which physical link the number ran over.
	_links=$(awk '
		NR == 1 { next }
		{ printf "%s%s %s/%s %s", (n++ ? "; " : ""), $1, $2, $3, $5 }
		END { if (n == 0) print "none captured" }
		' "$_edir/$S_PORTS" 2>/dev/null)
	[ -n "$_links" ] || _links="none captured"
	_mtu=$(cat "/sys/class/net/$IFACE/mtu" 2>/dev/null) || _mtu=
	_driver=$(awk '/^driver:/ { print $2; exit }' "$_edir/$S_DRIVER" 2>/dev/null)
	_drvver=$(awk '/^version:/ { print $2; exit }' "$_edir/$S_DRIVER" 2>/dev/null)
	[ -n "$_driver" ] || _driver=unknown
	[ -n "$_drvver" ] || _drvver=unknown
	_ncpu=$(awk -F: '/^processors:/ { gsub(/ /, "", $2); print $2 }' "$_edir/$S_CPU" 2>/dev/null)
	[ -n "$_ncpu" ] || _ncpu=unknown
	_cpu_model=$(awk -F: '/^model:/ { sub(/^ /, "", $2); print $2 }' "$_edir/$S_CPU" 2>/dev/null)
	[ -n "$_cpu_model" ] || _cpu_model=unknown

	# the capture starts with one note line; the stanza itself keeps its
	# own line breaks so the record shows what nft actually printed
	_ft_def=$(awk 'NR > 1' "$_edir/$S_FLOWTABLE" 2>/dev/null)
	[ -n "$_ft_def" ] || _ft_def="no flowtable stanza captured"
	_ft_dev=$(awk '
		/devices = / {
			i = index($0, "devices = ")
			s = substr($0, i + 11)
			gsub(/[{}"]/, "", s)
			gsub(/^[ \t]+|[ \t]+$/, "", s)
			print s
			exit
		}' "$_edir/$S_FLOWTABLE" 2>/dev/null)
	[ -n "$_ft_dev" ] || _ft_dev=none
	if printf '%s' "$_ft_def" | grep -q 'flags offload'; then
		_ft_hw=on
	else
		_ft_hw=off
	fi
	_feat=$(awk '
		$1 ~ /:$/ {
			k = $1
			sub(/:/, "", k)
			if (k == "tcp-segmentation-offload") tso = $2
			else if (k == "generic-receive-offload") gro = $2
			else if (k == "generic-segmentation-offload") gso = $2
			else if (k == "rx-checksumming") rxc = $2
			else if (k == "tx-checksumming") txc = $2
		}
		END {
			printf "tso=%s gro=%s gso=%s rx-csum=%s tx-csum=%s", \
				(tso == "" ? "?" : tso), (gro == "" ? "?" : gro), \
				(gso == "" ? "?" : gso), (rxc == "" ? "?" : rxc), \
				(txc == "" ? "?" : txc)
		}' "$_edir/$S_FEATURES" 2>/dev/null)
	[ -n "$_feat" ] || _feat=unknown

	_label_esc=$(json_escape "$LABEL")
	_id=$(printf '%s' "$LABEL" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9._-]/-/g')
	printf 'baseline %s\n\n' "$_label_esc"
	printf 'Recorded by scripts/bench-10g-unidirectional.sh --baseline on %s.\n' "$_ts"
	printf 'result.json in this directory is the citable record: every number\n'
	printf 'below was read back out of the capture files of this run, and every\n'
	printf 'qualifier next to it comes from the same capture.\n\n'
	printf '| field | value |\n| --- | --- |\n'
	printf '| label | %s |\n' "$_label_esc"
	printf '| recorded at (UTC) | %s |\n' "$_ts"
	printf '| role | %s |\n' "$PEER"
	printf '| interface under test | %s (MTU %s) |\n' "$IFACE" "${_mtu:-unknown}"
	printf '| link speed | %s Mb/s |\n' "$_speed"
	printf '| duplex (as %s reports it) | %s |\n' "$IFACE" "$_duplex"
	printf '| links with a positive speed | %s |\n' "$_links"
	printf '| driver | %s %s |\n' "$_driver" "$_drvver"
	printf '| kernel | %s |\n' "$_krel"
	printf '| kernel build | %s |\n' "$(awk '/^Linux version/ { print; exit }' "$_edir/$S_KERNEL" 2>/dev/null)"
	printf '| CPUs | %s (%s) |\n' "$_ncpu" "$_cpu_model"
	printf '| iperf3 | %s |\n' "$_iperf_ver"
	printf '| duration / streams | %s s / %s |\n' "$DURATION" "$PARALLEL"
	printf '| flowtable devices | %s |\n' "$_ft_dev"
	printf '| flowtable hw offload flag | %s |\n' "$_ft_hw"
	printf '| iface offload state | %s |\n' "$_feat"
	printf '| git | %s |\n' "$_git_desc"
	if [ -n "$ENV_NOTE" ]; then
		printf '| environment | %s |\n' "$(json_escape "$ENV_NOTE")"
	fi
	printf '\n'
	printf 'Flowtable stanza as captured:\n\n```\n%s\n```\n\n' "$_ft_def"

	printf '## throughput and cost per direction\n\n'
	printf 'TX = traffic from this box to the peer, RX = traffic from the peer\n'
	printf 'to this box; the two are separate runs, never concurrent.\n\n'
	if [ "$PEER" = server ]; then
		printf 'In passive role the peer-side counters are not in this\n'
		printf 'record: this box holds only its own iperf3 JSON, so the peer\n'
		printf 'column is "-" rather than a number the harness did not see.\n\n'
	fi
	printf '| direction | Gbit/s | peer Gbit/s (passive: -) | pps | retransmits | CPU busy s | CPU busy %% of capacity | idle %% |\n'
	printf '| --- | --- | --- | --- | --- | --- | --- | --- |\n'

	_gbps_tx=-
	_gbps_rx=-
	_tx_real_ok=0
	_rx_real_ok=0

	for _dn in tx rx; do
		case $_dn in
		tx) _st=$_tx_st ;;
		rx) _st=$_rx_st ;;
		esac
		_ijson=$RESULT_DIR/iperf3-$_dn.json
		_bdir=$(snapshot_dir "$_dn-before")
		_adir=$(snapshot_dir "$_dn-after")

		_sbps=null; _rbps=null; _ssecs=null; _rsecs=null; _retr=null
		if [ -r "$_ijson" ]; then
			_iline=$(iperf_summary "$_ijson")
			if [ -n "$_iline" ]; then
				# shellcheck disable=SC2086
				set -- $_iline
				if [ "$#" -ge 8 ]; then
					_sbps=$1
					_ssecs=$3
					_retr=$4
					_rbps=$5
					_rsecs=$7
				fi
			fi
		fi
		if [ "$_dn" = rx ]; then
			_bps=$_rbps
			_secs=$_rsecs
			_peer=$_sbps
		else
			_bps=$_sbps
			_secs=$_ssecs
			_peer=$_rbps
		fi

		_gbps=-
		_pgbps=-
		_dir_real=0
		if [ "$_st" -eq 0 ] && awk -v b="$_bps" 'BEGIN {
			exit !(b ~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/ && (b + 0) > 0)
		}'; then
			_gbps=$(gbit "$_bps")
			_dir_real=1
		elif [ "$_bps" != null ] && awk -v b="$_bps" 'BEGIN {
			exit !(b ~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/)
		}'; then
			_gbps=$(gbit "$_bps")
		fi
		if [ "$_peer" != null ]; then
			_pgbps=$(gbit "$_peer")
			# in passive role our own JSON carries the box's counters,
			# and a zero here means "not measured from this end", not
			# "the peer saw nothing".
			case $_pgbps in
			0.000) _pgbps=- ;;
			esac
		fi
		case $_dn in
		tx)
			_gbps_tx=$_gbps
			_tx_real_ok=$_dir_real
			;;
		rx)
			_gbps_rx=$_gbps
			_rx_real_ok=$_dir_real
			;;
		esac

		_el=$(uptime_delta "$_bdir/$S_UPTIME" "$_adir/$S_UPTIME")
		if [ "$_dn" = rx ]; then
			_pk=$(counter_delta "$_bdir/$S_IFACE_COUNTERS" \
				"$_adir/$S_IFACE_COUNTERS" rx_packets)
			_by=$(counter_delta "$_bdir/$S_IFACE_COUNTERS" \
				"$_adir/$S_IFACE_COUNTERS" rx_bytes)
		else
			_pk=$(counter_delta "$_bdir/$S_IFACE_COUNTERS" \
				"$_adir/$S_IFACE_COUNTERS" tx_packets)
			_by=$(counter_delta "$_bdir/$S_IFACE_COUNTERS" \
				"$_adir/$S_IFACE_COUNTERS" tx_bytes)
		fi
		# shellcheck disable=SC2046
		set -- $(pkt_rate_metrics "$_pk" "$_by" "$_secs" "$_el" "${_mtu:-0}")
		_mpps=$1; _mskb=$2; _mcoal=$4
		_pps=-
		if [ "$_mcoal" = true ]; then
			_pps="- (coalesced)"
		elif [ "$_mpps" != null ] && [ -n "$_mpps" ]; then
			_pps=$(awk -v r="$_mpps" 'BEGIN { printf "%.0f", r }')
		fi
		_retrs=-
		if [ "$_retr" != null ] && [ -n "$_retr" ]; then
			_retrs=$_retr
		fi

		# shellcheck disable=SC2046
		set -- $(cpu_seconds "$_bdir/$S_PROC_STAT" "$_adir/$S_PROC_STAT")
		_busy=$1
		_wall=$2
		_idle=$3
		_busypct=-
		if [ "$_busy" != null ] && [ "$_wall" != null ]; then
			_busypct=$(awk -v b="$_busy" -v w="$_wall" -v s="$_st" \
				'BEGIN {
					if (w <= 0) { print "-"; exit }
					printf "%.1f", b * 100 / w
				}')
		fi
		if [ "$_st" -ne 0 ]; then
			printf '| %s | **failed (exit %s)** | - | - | - | - | - | - |\n' \
				"$_dn" "$_st"
		else
			printf '| %s | %s | %s | %s | %s | %s | %s | %s |\n' \
				"$_dn" "$_gbps" "$_pgbps" "$_pps" "$_retrs" \
				"${_busy:--}" "${_busypct}" "${_idle:--}"
		fi
	done

	printf '\n## what this record does and does not establish\n\n'
	printf 'The link under test reports **%s Mb/s**, so %s Mb/s is this run''s\n' \
		"$_speed" "$_speed"
	printf 'hard ceiling and no number here can describe a 10G path.\n'
	case $_speed in
	10000|25000|40000|50000|100000)
		printf 'The link is fast enough to be quoted as a 10G-class baseline.\n' ;;
	*)
		printf '\nA stock-firmware side is **not** part of this record: this script\n'
		printf 'measures the firmware it is run on, and no stock unit was attached.\n'
		printf 'A stock-vs-OpenWrt comparison needs the same harness run on the\n'
		printf 'stock firmware over the same link, and stays unmeasured until that\n'
		printf 'exists.\n' ;;
	esac

	printf '\n## captures behind this record\n\n'
	for _f in "$S_LINK" "$S_DRIVER" "$S_FEATURES" "$S_SYSFS_LINK" "$S_FLOWTABLE" \
		"$S_NFT_FULL" "$S_PORTS" "$S_KERNEL" "$S_CPU" "$S_TOPOLOGY"; do
		printf -- '- `snapshots/env/%s`\n' "$_f"
	done
	printf -- '- `iperf3-tx.json`, `iperf3-rx.json` (raw iperf3 JSON)\n'
	printf -- '- `result.json` (the record, schema bench-10g-unidirectional/v1)\n'
	printf -- '- `raw.log` (every command, in order)\n'

	printf '\n## paste-ready claims.yaml entry\n\n'
	if [ "$_tx_st" -eq 0 ] && [ "$_rx_st" -eq 0 ] && [ "$_tx_real_ok" -eq 1 ] && [ "$_rx_real_ok" -eq 1 ]; then
		printf 'Copy the directory under scripts/perf-baselines/%s/ as is, so the\n' \
			"$_label_esc"
		printf 'source line below resolves in a checkout.  result.json is the record:\n'
		printf 'no summary document is written, and none should be added.\n\n'
		printf '```yaml\n'
		printf '  - id: baseline-%s\n' "$_id"
		printf '    claim: "在本仓库 iperf3 基线上（%s Mb/s 链路，%s 驱动，flowtable\n' \
			"$_speed" "$_driver"
		printf '      硬件 offload %s），本移植单向吞吐为 TX %s Gbit/s、RX %s Gbit/s，\n' \
			"$_ft_hw" "$_gbps_tx" "$_gbps_rx"
		printf '      对应 CPU busy 见记录。"\n'
		printf '    source:\n'
		printf '      - "scripts/perf-baselines/%s/result.json:1"\n' "$_label_esc"
		printf '    evidence: 实测\n'
		printf '    date: "%s"\n' "$(date -u +%Y-%m-%d)"
		printf '    status: supported\n'
		printf '    notes: "单机、单次、%s 链路，不代表 10G 能力，也不能与 stock 固件\n' \
			"$_speed"
		printf '      的数字并列当作对比；stock 侧仍无测量。"\n'
		printf '```\n'
	else
		printf 'Not emitted: both TX and RX must succeed with real numeric Gbit/s\n'
		printf 'before a baseline may be cited in claims.yaml (tx_exit=%s tx_gbps=%s,\n' \
			"$_tx_st" "$_gbps_tx"
		printf 'rx_exit=%s rx_gbps=%s).  No summary document is written.\n' \
			"$_rx_st" "$_gbps_rx"
	fi
}

# Print the planned protocol without touching the system.  Every path and
# command below is exactly what a real run uses.
dry_run_plan() {
	_target=${TARGET:-<required>}
	_iface=${IFACE:-<required>}
	printf '%s: dry run; nothing will be created or executed\n' "$PROG"
	if { [ "$PEER" = client ] && [ -z "$TARGET" ]; } || [ -z "$IFACE" ]; then
		printf '  note: an unset TARGET (client role) or IFACE is shown as <required>;\n'
		printf '        a real run refuses to start without both.\n'
	fi
	printf '  TARGET=%s\n' "$_target"
	printf '  IFACE=%s\n' "$_iface"
	printf '  DURATION=%s PARALLEL=%s DUMP_FOE=%s\n' "$DURATION" "$PARALLEL" "$DUMP_FOE"
	printf '  PORT=%s ROLE=%s PEER_WAIT=%s\n' "$PORT" "$PEER" "$PEER_WAIT"
	printf '  BASELINE=%s LABEL=%s\n' "$BASELINE" "$LABEL"
	if [ -n "$ENV_NOTE" ]; then
		printf '  ENV_NOTE=%s\n' "$ENV_NOTE"
	fi
	printf '  RESULT_DIR=%s\n' "$RESULT_DIR"
	printf '\nprotocol commands, in order:\n'
	printf '  1. TX snapshots before: %s/snapshots/tx-before\n' "$RESULT_DIR"
	if [ "$PEER" = server ]; then
		printf '     iperf3 -s -1 -J -p %s > %s/iperf3-tx.json\n' \
			"$PORT" "$RESULT_DIR"
		printf '     peer runs: iperf3 -c <box-ip> -t %s -P %s -R -p %s\n' \
			"$DURATION" "$PARALLEL" "$PORT"
	else
		printf '     iperf3 -c %s -t %s -P %s -J -p %s > %s/iperf3-tx.json\n' \
			"$_target" "$DURATION" "$PARALLEL" "$PORT" "$RESULT_DIR"
	fi
	printf '  2. TX snapshots after:  %s/snapshots/tx-after\n' "$RESULT_DIR"
	printf '  3. RX snapshots before: %s/snapshots/rx-before\n' "$RESULT_DIR"
	if [ "$PEER" = server ]; then
		printf '     iperf3 -s -1 -J -p %s > %s/iperf3-rx.json\n' \
			"$PORT" "$RESULT_DIR"
		printf '     peer runs: iperf3 -c <box-ip> -t %s -P %s -p %s\n' \
			"$DURATION" "$PARALLEL" "$PORT"
	else
		printf '     iperf3 -c %s -t %s -P %s -R -J -p %s > %s/iperf3-rx.json\n' \
			"$_target" "$DURATION" "$PARALLEL" "$PORT" "$RESULT_DIR"
	fi
	printf '  4. RX snapshots after:  %s/snapshots/rx-after\n' "$RESULT_DIR"
	printf '\nreal-run preconditions (not checked by --dry-run):\n'
	printf '  ip -o addr show dev %s   # must contain inet or inet6\n' "$_iface"
	printf '  command -v iperf3         # must exist\n'
	printf '  test -e %s/result.json    # must not exist\n' "$RESULT_DIR"
	for _phase in tx-before tx-after rx-before rx-after; do
		_dir=$RESULT_DIR/snapshots/$_phase
		printf '\n[%s], exact snapshot commands and paths:\n' "$_dir"
		case $_phase in
		*-after)
			# after phase: iface counters + /proc first, matching snapshot_after()
			printf '  read /sys/class/net/%s/statistics/{rx_packets,tx_packets,rx_bytes,tx_bytes,rx_errors,tx_errors,rx_dropped,tx_dropped} > %s/%s\n' \
				"$_iface" "$_dir" "$S_IFACE_COUNTERS"
			printf '  cat /proc/stat > %s/%s\n' "$_dir" "$S_PROC_STAT"
			printf '  cat /proc/interrupts > %s/%s\n' "$_dir" "$S_INTERRUPTS"
			printf '  cat /proc/uptime > %s/%s\n' "$_dir" "$S_UPTIME"
			printf '  ethtool -S %s > %s/%s        # if ethtool is installed\n' \
				"$_iface" "$_dir" "$S_ETHTOOL"
			printf '  nft list ruleset > %s/%s    # if nft is installed\n' \
				"$_dir" "$S_NFT"
			printf '  tc -s qdisc show dev %s > %s/%s\n' \
				"$_iface" "$_dir" "$S_TC_QDISC"
			printf '  tc -s filter show dev %s > %s/%s\n' \
				"$_iface" "$_dir" "$S_TC_FILTER"
			printf '  cat /sys/kernel/debug/ppe/usage > %s/%s   # if readable\n' \
				"$_dir" "$S_PPE_USAGE"
			if [ "$DUMP_FOE" = 1 ]; then
				printf '  cat /sys/kernel/debug/ppe/entries > %s/%s   # DUMP_FOE=1\n' \
					"$_dir" "$S_PPE_ENTRIES"
			fi
			;;
		*)
			printf '  ethtool -S %s > %s/%s        # if ethtool is installed\n' \
				"$_iface" "$_dir" "$S_ETHTOOL"
			printf '  nft list ruleset > %s/%s    # if nft is installed\n' \
				"$_dir" "$S_NFT"
			printf '  tc -s qdisc show dev %s > %s/%s\n' \
				"$_iface" "$_dir" "$S_TC_QDISC"
			printf '  tc -s filter show dev %s > %s/%s\n' \
				"$_iface" "$_dir" "$S_TC_FILTER"
			printf '  cat /sys/kernel/debug/ppe/usage > %s/%s   # if readable\n' \
				"$_dir" "$S_PPE_USAGE"
			if [ "$DUMP_FOE" = 1 ]; then
				printf '  cat /sys/kernel/debug/ppe/entries > %s/%s   # DUMP_FOE=1\n' \
					"$_dir" "$S_PPE_ENTRIES"
			fi
			printf '  read /sys/class/net/%s/statistics/{rx_packets,tx_packets,rx_bytes,tx_bytes,rx_errors,tx_errors,rx_dropped,tx_dropped} > %s/%s\n' \
				"$_iface" "$_dir" "$S_IFACE_COUNTERS"
			printf '  cat /proc/uptime > %s/%s\n' "$_dir" "$S_UPTIME"
			printf '  cat /proc/stat > %s/%s\n' "$_dir" "$S_PROC_STAT"
			printf '  cat /proc/interrupts > %s/%s\n' "$_dir" "$S_INTERRUPTS"
			;;
		esac
	done
	if [ "$BASELINE" = 1 ]; then
		_dir=$RESULT_DIR/snapshots/env
		printf '\n[%s], exact environment snapshot commands and paths:\n' "$_dir"
		printf '  ethtool %s > %s/%s\n' "$_iface" "$_dir" "$S_LINK"
		printf '  ethtool -i %s > %s/%s\n' "$_iface" "$_dir" "$S_DRIVER"
		printf '  ethtool -k %s > %s/%s\n' "$_iface" "$_dir" "$S_FEATURES"
		printf '  read /sys/class/net/%s/{speed,duplex,carrier,operstate,mtu} > %s/%s\n' \
			"$_iface" "$_dir" "$S_SYSFS_LINK"
		printf '  nft list ruleset > %s/%s\n' "$_dir" "$S_NFT_FULL"
		printf '  flowtable stanzas extracted from %s > %s/%s\n' \
			"$S_NFT_FULL" "$_dir" "$S_FLOWTABLE"
		printf '  positive-speed links with tso/gro/gso/hw-tc-offload > %s/%s\n' \
			"$_dir" "$S_PORTS"
		printf '  uname -a, /proc/version, /proc/cmdline > %s/%s\n' \
			"$_dir" "$S_KERNEL"
		printf '  /proc/cpuinfo (count and model) > %s/%s\n' "$_dir" "$S_CPU"
		printf '  ip addr, ip route, link map > %s/%s\n' "$_dir" "$S_TOPOLOGY"
	fi
	printf '\nresults:\n'
	printf '  %s/result.json\n' "$RESULT_DIR"
	printf '  %s/raw.log\n' "$RESULT_DIR"
	if [ "$BASELINE" = 1 ]; then
		printf '  %s/result.json  # citable record: schema, environment, per-direction\n' \
			"$RESULT_DIR"
		printf '  (no other record file is written; the claims.yaml entry is printed)\n'
	fi
}

# ---------------------------------------------------------------------
# arguments

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
	--dump-foe)
		DUMP_FOE=1
		shift
		;;
	--dump-foe=*)
		DUMP_FOE=${1#--dump-foe=}
		shift
		;;
	--target)
		[ "$#" -ge 2 ] || usage_error "--target requires a value"
		TARGET=$2
		shift 2
		;;
	--target=*)
		TARGET=${1#--target=}
		shift
		;;
	--iface)
		[ "$#" -ge 2 ] || usage_error "--iface requires a value"
		IFACE=$2
		shift 2
		;;
	--iface=*)
		IFACE=${1#--iface=}
		shift
		;;
	--duration)
		[ "$#" -ge 2 ] || usage_error "--duration requires a value"
		DURATION=$2
		shift 2
		;;
	--duration=*)
		DURATION=${1#--duration=}
		shift
		;;
	--parallel)
		[ "$#" -ge 2 ] || usage_error "--parallel requires a value"
		PARALLEL=$2
		shift 2
		;;
	--parallel=*)
		PARALLEL=${1#--parallel=}
		shift
		;;
	--result-dir)
		[ "$#" -ge 2 ] || usage_error "--result-dir requires a value"
		RESULT_DIR=$2
		shift 2
		;;
	--result-dir=*)
		RESULT_DIR=${1#--result-dir=}
		shift
		;;
	--baseline)
		BASELINE=1
		shift
		;;
	--peer-connects)
		case $PEER in
		server) ;;
		client) PEER=server ;;
		esac
		shift
		;;
	--label)
		[ "$#" -ge 2 ] || usage_error "--label requires a value"
		LABEL=$2
		shift 2
		;;
	--label=*)
		LABEL=${1#--label=}
		shift
		;;
	--env-note)
		[ "$#" -ge 2 ] || usage_error "--env-note requires a value"
		ENV_NOTE=$2
		shift 2
		;;
	--env-note=*)
		ENV_NOTE=${1#--env-note=}
		shift
		;;
	--port)
		[ "$#" -ge 2 ] || usage_error "--port requires a value"
		PORT=$2
		shift 2
		;;
	--port=*)
		PORT=${1#--port=}
		shift
		;;
	--peer-wait)
		[ "$#" -ge 2 ] || usage_error "--peer-wait requires a value"
		PEER_WAIT=$2
		shift 2
		;;
	--peer-wait=*)
		PEER_WAIT=${1#--peer-wait=}
		shift
		;;
	-*)
		usage_error "unknown option: $1"
		;;
	*)
		usage_error "unexpected argument: $1"
		;;
	esac
done

require_positive_int DURATION "$DURATION"
require_positive_int PARALLEL "$PARALLEL"
require_positive_int PORT "$PORT"
require_positive_int PEER_WAIT "$PEER_WAIT"

case $PEER in
client | server) ;;
*) usage_error "PEER must be client or server, got '$PEER'" ;;
esac

case $BASELINE in
0 | 1) ;;
*) usage_error "BASELINE must be 1 or 0, got '$BASELINE'" ;;
esac

if [ "$PEER" = server ] && [ "$PEER_WAIT" -lt $((DURATION + 10)) ]; then
	usage_error "PEER_WAIT=${PEER_WAIT}s is shorter than DURATION+10s=$((DURATION + 10))s; the peer test would be cut off"
fi

case $DUMP_FOE in
0) ;;
1) ;;
*) usage_error "DUMP_FOE must be 1 or 0, got '$DUMP_FOE'" ;;
esac

if [ -z "$RESULT_DIR" ]; then
	RESULT_DIR=./bench-10g-$(date +%s)
fi

if [ "$DRY_RUN" = 1 ]; then
	dry_run_plan
	exit 0
fi

# ---------------------------------------------------------------------
# real run

if [ "$PEER" = client ]; then
	[ -n "$TARGET" ] || usage_error "TARGET is required in client role (peer running iperf3 -s)"
fi
[ -n "$IFACE" ] || usage_error "IFACE is required (local network interface)"

command -v iperf3 >/dev/null 2>&1 ||
	missing_iperf3 "iperf3 not found in PATH (install it on the host under test)"

if ! command -v ip >/dev/null 2>&1; then
	die "the 'ip' command is required to verify that IFACE has an IPv4/IPv6 address"
fi
_addrs=$(ip -o addr show dev "$IFACE" 2>/dev/null) || _addrs=
case $_addrs in
*" inet "*|*" inet6 "*) ;;
*) die "interface '$IFACE' does not exist or has no IPv4/IPv6 address" ;;
esac

_mtu=$(cat "/sys/class/net/$IFACE/mtu" 2>/dev/null) || _mtu=
case $_mtu in
''|*[!0-9]*) die "could not read the MTU of interface '$IFACE'" ;;
esac

if [ -e "$RESULT_DIR/result.json" ]; then
	die "refusing to overwrite $RESULT_DIR/result.json (use a new RESULT_DIR)"
fi

mkdir -p "$RESULT_DIR" \
	"$RESULT_DIR/snapshots/tx-before" \
	"$RESULT_DIR/snapshots/tx-after" \
	"$RESULT_DIR/snapshots/rx-before" \
	"$RESULT_DIR/snapshots/rx-after" ||
	die "cannot create output directories under $RESULT_DIR"
TMPDIR_RUN=$(mktemp -d "$RESULT_DIR/.tmp.XXXXXX") ||
	die "cannot create a temporary directory under $RESULT_DIR"

RAW_LOG=$RESULT_DIR/raw.log
: >"$RAW_LOG" || die "cannot write $RAW_LOG"

if [ "$BASELINE" = 1 ]; then
	# taken before the first direction, so the link state, the flowtable
	# and the kernel are captured exactly as the traffic will see them.
	snapshot_env
fi

_git_desc=unknown
if [ -n "$REPO_DIR" ] && command -v git >/dev/null 2>&1; then
	_git_desc=$(git -C "$REPO_DIR" describe --tags --always --dirty 2>/dev/null) ||
		_git_desc=unknown
fi
_krel=$(uname -r 2>/dev/null) || _krel=unknown
_hostname=$(uname -n 2>/dev/null) || _hostname=unknown
_iperf_ver=$(iperf3 --version 2>/dev/null | awk 'NR == 1 { print; exit }') ||
	_iperf_ver=
[ -n "$_iperf_ver" ] || _iperf_ver=unknown

log_note "start $PROG"
if [ "$PEER" = server ]; then
	log_note "role=server (passive; the peer dials this box) box_ip=$(box_ip) port=$PORT peer_wait=${PEER_WAIT}s"
else
	log_note "target=$TARGET iface=$IFACE role=client port=$PORT"
fi
log_note "iface=$IFACE duration=$DURATION parallel=$PARALLEL dump_foe=$DUMP_FOE baseline=$BASELINE label=$LABEL"
log_note "git_describe=$_git_desc kernel_release=$_krel mtu=$_mtu"
if [ -n "${USER:-}" ]; then
	log_note "user=$USER"
fi
_uid=$(id -u 2>/dev/null) || _uid=
case $_uid in
''|0) ;;
*) log_note "warning: not running as root (uid $_uid); nft, tc and PPE snapshots may be unavailable" ;;
esac

printf 'TX: snapshots before...\n'
snapshot_before tx
printf 'TX: iperf3 %s s, %s streams...\n' "$DURATION" "$PARALLEL"
run_iperf tx "$RESULT_DIR/iperf3-tx.json" "$RESULT_DIR/iperf3-tx.err"
tx_status=$?
printf 'TX: iperf3 exit %s; snapshots after...\n' "$tx_status"
snapshot_after tx

printf 'RX: snapshots before...\n'
snapshot_before rx
printf 'RX: iperf3 %s s, %s streams, reverse...\n' "$DURATION" "$PARALLEL"
run_iperf rx "$RESULT_DIR/iperf3-rx.json" "$RESULT_DIR/iperf3-rx.err"
rx_status=$?
printf 'RX: iperf3 exit %s; snapshots after...\n' "$rx_status"
snapshot_after rx

emit_direction tx "$tx_status" "$RESULT_DIR/iperf3-tx.json" \
	"$RESULT_DIR/snapshots/tx-before" "$RESULT_DIR/snapshots/tx-after" \
	>"$TMPDIR_RUN/tx.json"
emit_direction rx "$rx_status" "$RESULT_DIR/iperf3-rx.json" \
	"$RESULT_DIR/snapshots/rx-before" "$RESULT_DIR/snapshots/rx-after" \
	>"$TMPDIR_RUN/rx.json"

_json_ts=$(now_ts)

_base_json=false
_env_json=null
if [ "$BASELINE" = 1 ]; then
	_base_json=true
	_b_speed=$(cat "/sys/class/net/$IFACE/speed" 2>/dev/null) || _b_speed=
	case $_b_speed in
	''|*[!0-9]*) _b_speed=null ;;
	esac
	_b_duplex=$(cat "/sys/class/net/$IFACE/duplex" 2>/dev/null) || _b_duplex=
	_b_driver=$(awk '/^driver:/ { print $2; exit }' \
		"$RESULT_DIR/snapshots/env/$S_DRIVER" 2>/dev/null)
	_b_ft=$(grep -c 'flags offload' \
		"$RESULT_DIR/snapshots/env/$S_FLOWTABLE" 2>/dev/null) || _b_ft=0
	_b_ft_off=false
	[ "${_b_ft:-0}" -gt 0 ] && _b_ft_off=true
	_env_json="{\"link_speed_mbps\":$_b_speed,\"duplex\":\"$(json_escape "${_b_duplex:-unknown}")\",\"driver\":\"$(json_escape "${_b_driver:-unknown}")\",\"flowtable_hw_offload\":$_b_ft_off,\"captures\":\"snapshots/env\"}"
fi
{
	printf '{\n'
	printf '  "schema": "bench-10g-unidirectional/v1",\n'
	printf '  "timestamp": "%s",\n' "$_json_ts"
	printf '  "git_describe": "%s",\n' "$(json_escape "$_git_desc")"
	printf '  "kernel_release": "%s",\n' "$(json_escape "$_krel")"
	printf '  "hostname": "%s",\n' "$(json_escape "$_hostname")"
	printf '  "iperf3_version": "%s",\n' "$(json_escape "$_iperf_ver")"
	printf '  "iface": "%s",\n' "$(json_escape "$IFACE")"
	printf '  "target": "%s",\n' "$(json_escape "$TARGET")"
	printf '  "role": "%s",\n' "$PEER"
	printf '  "port": %s,\n' "$PORT"
	printf '  "baseline": %s,\n' "$_base_json"
	printf '  "label": "%s",\n' "$(json_escape "$LABEL")"
	printf '  "env_note": "%s",\n' "$(json_escape "$ENV_NOTE")"
	printf '  "mtu": %s,\n' "$_mtu"
	printf '  "duration_s": %s,\n' "$DURATION"
	printf '  "parallel": %s,\n' "$PARALLEL"
	if [ "$DUMP_FOE" = 1 ]; then
		printf '  "dump_foe": true,\n'
	else
		printf '  "dump_foe": false,\n'
	fi
	printf '  "environment": %s,\n' "$_env_json"
	printf '  "raw_log": "raw.log",\n'
	printf '  "directions": {\n    "tx": '
	cat "$TMPDIR_RUN/tx.json"
	printf ',\n    "rx": '
	cat "$TMPDIR_RUN/rx.json"
	printf '\n  }\n}\n'
} >"$RESULT_DIR/result.json.tmp" || die "cannot write $RESULT_DIR/result.json.tmp"

if command -v jq >/dev/null 2>&1; then
	if ! jq -e . "$RESULT_DIR/result.json.tmp" >/dev/null 2>&1; then
		die "generated result.json is not valid JSON; kept as $RESULT_DIR/result.json.tmp"
	fi
fi
mv "$RESULT_DIR/result.json.tmp" "$RESULT_DIR/result.json" ||
	die "cannot move result.json into place"
rm -rf "$TMPDIR_RUN"

printf '\nTX: exit %s, result: %s\n' "$tx_status" "$RESULT_DIR/result.json"
printf 'RX: exit %s, raw log: %s\n' "$rx_status" "$RAW_LOG"
if [ "$BASELINE" = 1 ]; then
	# printed last, so the summary can only ever describe a run whose
	# result.json already exists; nothing extra is written to disk.
	printf '\n'
	emit_baseline_summary "$tx_status" "$rx_status"
	printf '\nbaseline record: %s/result.json (no other file is written)\n' \
		"$RESULT_DIR"
fi

_rc=0
[ "$tx_status" -eq 0 ] || _rc=1
[ "$rx_status" -eq 0 ] || _rc=1
if [ "$_rc" -ne 0 ]; then
	printf 'one or more iperf3 runs failed; result.json records the failure\n'
fi
exit "$_rc"
