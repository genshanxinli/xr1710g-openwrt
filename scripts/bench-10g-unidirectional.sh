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
# POSIX sh only, so it runs on the OpenWrt device with busybox ash.
#
# Exit status: 0 both directions ran, 1 an iperf3 run failed or setup was
# impossible, 2 invalid arguments (--help documents them).

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

usage() {
	cat <<'EOF'
Usage: bench-10g-unidirectional.sh [options]

A reproducible unidirectional 10G throughput bench.  TX and RX are two
separate iperf3 runs, never concurrent; each direction gets a full set
of before/after snapshots and its own entry in result.json.

Required inputs for a real run (environment variable or flag):
  TARGET / --target IP        peer running "iperf3 -s"
  IFACE  / --iface NAME       local network interface under test
                              --dry-run accepts unset values and prints
                              them as <required> placeholders; a real run
                              refuses to start without both.

Optional inputs:
  DURATION / --duration SEC   seconds per direction (default 60)
  PARALLEL / --parallel N     iperf3 streams per direction (default 4)
  RESULT_DIR / --result-dir DIR
                              output directory (default ./bench-10g-<epoch>)
  DUMP_FOE / --dump-foe       set to 1 to also snapshot the full FOE table,
                              /sys/kernel/debug/ppe/entries (about 32768
                              lines per snapshot; off by default)

Options:
  --dry-run                   print the commands and every snapshot path,
                              then exit 0.  No directory is created, no
                              command is run, no peer is contacted and the
                              live interface is not validated.  Unset
                              TARGET/IFACE values appear as <required>.
  -h, --help                  this text

Real runs also refuse to start when TARGET or IFACE is empty, when the
interface does not exist or has no IPv4/IPv6 address, when iperf3 or the
ip command is not installed, or when RESULT_DIR/result.json already
exists (a previous run is never overwritten).  The peer must have
"iperf3 -s" listening; it is not started by this harness.

Protocol, in this order:
  1. TX snapshots before  -> iperf3 -c TARGET -t DURATION -P PARALLEL -J
                          -> TX snapshots after
  2. RX snapshots before  -> iperf3 -c TARGET -t DURATION -P PARALLEL -R -J
                          -> RX snapshots after

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

Output directory:
  raw.log                chronological command log
  result.json            machine-readable result (schema
                         bench-10g-unidirectional/v1)
  iperf3-tx.json         raw iperf3 JSON for the TX run
  iperf3-rx.json         raw iperf3 JSON for the RX run
  snapshots/{tx,rx}-{before,after}/

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

# Everything except /proc/stat and /proc/interrupts, which are taken last
# before the run and first after it so their deltas cover only the iperf3
# window.
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
	capture_iface_counters "$_dir/$S_IFACE_COUNTERS"
}

snapshot_before() {
	_dir=$(snapshot_dir "$1-before")
	log_note "snapshot before $1: $_dir"
	snapshot_extra "$_dir"
	capture "$_dir/$S_UPTIME" cat /proc/uptime
	capture "$_dir/$S_PROC_STAT" cat /proc/stat
	capture "$_dir/$S_INTERRUPTS" cat /proc/interrupts
}

snapshot_after() {
	_dir=$(snapshot_dir "$1-after")
	log_note "snapshot after $1: $_dir"
	capture "$_dir/$S_PROC_STAT" cat /proc/stat
	capture "$_dir/$S_INTERRUPTS" cat /proc/interrupts
	capture "$_dir/$S_UPTIME" cat /proc/uptime
	snapshot_extra "$_dir"
}

iperf_cmd_string() {
	if [ "$1" = rx ]; then
		printf 'iperf3 -c %s -t %s -P %s -R -J' "$TARGET" "$DURATION" "$PARALLEL"
	else
		printf 'iperf3 -c %s -t %s -P %s -J' "$TARGET" "$DURATION" "$PARALLEL"
	fi
}

# Runs one direction only.  The caller decides when the next direction
# starts; there is deliberately no background job here.
run_iperf() {
	_dir=$1
	_out=$2
	_err=$3
	log_cmd "$(iperf_cmd_string "$_dir") > $_out"
	if [ "$_dir" = rx ]; then
		iperf3 -c "$TARGET" -t "$DURATION" -P "$PARALLEL" -R -J \
			>"$_out" 2>"$_err"
	else
		iperf3 -c "$TARGET" -t "$DURATION" -P "$PARALLEL" -J \
			>"$_out" 2>"$_err"
	fi
	_st=$?
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

# airoha PPE usage (see target/linux/airoha/patches-7.3/205): eight values,
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

	_ok=false
	if [ "$_ist" -eq 0 ] && [ "$_bps" != null ]; then
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
	if [ "$_ist" -ne 0 ]; then
		_imsg=$(iperf_error "$_ijson")
		[ -n "$_imsg" ] || _imsg="iperf3 exited $_ist"
		_err="\"$(json_escape "$_imsg")\""
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
	else
		_pktdelta=$_txp
	fi
	_pps=null
	if [ "$_pktdelta" != null ] && [ "$_el" != null ]; then
		_pps=$(awk -v d="$_pktdelta" -v t="$_el" 'BEGIN {
			if (t > 0) printf "%.1f", d / t; else print "null"
		}')
	fi

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

# Print the planned protocol without touching the system.  Every path and
# command below is exactly what a real run uses.
dry_run_plan() {
	_target=${TARGET:-<required>}
	_iface=${IFACE:-<required>}
	printf '%s: dry run; nothing will be created or executed\n' "$PROG"
	if [ -z "$TARGET" ] || [ -z "$IFACE" ]; then
		printf '  note: an unset TARGET or IFACE is shown as <required>;\n'
		printf '        a real run refuses to start without both.\n'
	fi
	printf '  TARGET=%s\n' "$_target"
	printf '  IFACE=%s\n' "$_iface"
	printf '  DURATION=%s PARALLEL=%s DUMP_FOE=%s\n' "$DURATION" "$PARALLEL" "$DUMP_FOE"
	printf '  RESULT_DIR=%s\n' "$RESULT_DIR"
	printf '\nprotocol commands, in order:\n'
	printf '  1. TX snapshots before: %s/snapshots/tx-before\n' "$RESULT_DIR"
	printf '     iperf3 -c %s -t %s -P %s -J > %s/iperf3-tx.json\n' \
		"$_target" "$DURATION" "$PARALLEL" "$RESULT_DIR"
	printf '  2. TX snapshots after:  %s/snapshots/tx-after\n' "$RESULT_DIR"
	printf '  3. RX snapshots before: %s/snapshots/rx-before\n' "$RESULT_DIR"
	printf '     iperf3 -c %s -t %s -P %s -R -J > %s/iperf3-rx.json\n' \
		"$_target" "$DURATION" "$PARALLEL" "$RESULT_DIR"
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
			# after phase: /proc first, matching snapshot_after()
			printf '  cat /proc/stat > %s/%s\n' "$_dir" "$S_PROC_STAT"
			printf '  cat /proc/interrupts > %s/%s\n' "$_dir" "$S_INTERRUPTS"
			printf '  cat /proc/uptime > %s/%s\n' "$_dir" "$S_UPTIME"
			;;
		*)
			printf '  cat /proc/uptime > %s/%s\n' "$_dir" "$S_UPTIME"
			printf '  cat /proc/stat > %s/%s\n' "$_dir" "$S_PROC_STAT"
			printf '  cat /proc/interrupts > %s/%s\n' "$_dir" "$S_INTERRUPTS"
			;;
		esac
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
	done
	printf '\nresults:\n'
	printf '  %s/result.json\n' "$RESULT_DIR"
	printf '  %s/raw.log\n' "$RESULT_DIR"
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

[ -n "$TARGET" ] || usage_error "TARGET is required (peer running iperf3 -s)"
[ -n "$IFACE" ] || usage_error "IFACE is required (local network interface)"

command -v iperf3 >/dev/null 2>&1 ||
	die "iperf3 not found in PATH (install it on the host under test)"

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
log_note "target=$TARGET iface=$IFACE duration=$DURATION parallel=$PARALLEL dump_foe=$DUMP_FOE"
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
	printf '  "mtu": %s,\n' "$_mtu"
	printf '  "duration_s": %s,\n' "$DURATION"
	printf '  "parallel": %s,\n' "$PARALLEL"
	if [ "$DUMP_FOE" = 1 ]; then
		printf '  "dump_foe": true,\n'
	else
		printf '  "dump_foe": false,\n'
	fi
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

_rc=0
[ "$tx_status" -eq 0 ] || _rc=1
[ "$rx_status" -eq 0 ] || _rc=1
if [ "$_rc" -ne 0 ]; then
	printf 'one or more iperf3 runs failed; result.json records the failure\n'
fi
exit "$_rc"
