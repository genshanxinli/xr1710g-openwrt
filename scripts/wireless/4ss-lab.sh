#!/bin/sh
#
# 4ss-lab.sh - 4 spatial stream lab plan and measurement harness for the
# XR1710G (MT7996AV BE19000) AP.
#
# The AP can run 4x4 on 5 GHz and 4T5R on 6 GHz, but no 4SS client has ever
# been measured, so 4SS is still only the absolute PHY ceiling.  This script
# records the lab plan, validates that the client really has 4 spatial
# streams from "iw station dump", then measures the local-source AP->STA and
# STA->AP arms together with the PCIe0, NPU token, CPU, memory and thermal
# evidence needed to decide whether a shortfall is radio/air-side or
# SoC-side.  It changes no wireless configuration and never touches the
# bootloader, firmware or UBI.
#
# BEGIN LAB PLAN
# 4SS lab plan (offline, non-production)
#
# Goal
#   Measure whether the XR1710G reaches the 4SS PHY ceiling in both
#   directions, and decide whether a shortfall is radio/air-side or
#   SoC-side (PCIe0, NPU tokens, CPU, memory, thermal).  The AP is an
#   MT7996AV BE19000: MT7976GN 2.4 GHz 4x4, MT7977BN 5 GHz 4x4 and
#   MT7977AN 6 GHz 4T5R.  The two ceiling targets are:
#
#     5G160 4SS >= 3.5 Gbit/s
#     6G320 4SS >= 6.0 Gbit/s
#
# Current evidence
#   No 4SS client exists in the lab: every measured client is 2SS, so the
#   4SS ceiling has never been reached.  The AP is a closed embedded board:
#   PCIe0 carries the MT7996 (0000:01:00.0, mt7996e) and there is no free
#   PCIe slot, so the 4SS endpoint cannot be added to the AP.  A separate
#   4SS client is required.  The existing test host has no free PCIe slot
#   either, so Option A needs its own host/adapter; Option B needs a second
#   complete board.
#
# Option A: external QCN9274/QCN6274 4x4 module on a dedicated host
#   module        5-7.125 GHz 4x4 802.11be, QCN9274 (industrial) or
#                 QCN6274 (commercial), M.2 A+E key or mini-PCIe,
#                 PCIe 3.0 x2, 4x U.FL.  Examples: 8devices Noni 56M2-4x4
#                 (3.3 V, ~8-9 W) or Wallys DR9274-6G (5 V, ~8.5 W).  A
#                 5 GHz-only module such as a Compex WLW7000E5 (4x4,
#                 5.765 Gbit/s PHY) covers only the 5G160 target; 6G320
#                 needs a 5-7 GHz module.
#   antennas      4x U.FL-to-SMA pigtails and 4x dual-band 5/6 GHz
#                 antennas, >= 3 dBi (4-6 dBi preferred), at least 10 cm
#                 apart, same polarisation, 1-3 m line of sight.
#   power         module rail from the host/adapter: 3.3 V (Noni) or 5 V
#                 (Wallys), ~9 W typical, <= 15 W budget; dedicated 2 A
#                 supply, never the AP's supply.
#   cooling       module heatsink + 40 mm fan or directed bench air,
#                 ambient <= 25 C; the FEMs are the hot part at 320 MHz.
#   host interface PCIe 3.0 x2 through M.2 A+E or mini-PCIe on an
#                 x86-64/ARM host with a free slot and Linux ath12k; a
#                 10GbE/2.5GbE lab link carries the traffic.
#   why           independent silicon and driver (ath12k vs mt76), so a
#                 shortfall can be attributed across two stacks.
#
# Option B: second MT7996 board as the 4SS station
#   module        MT7996AV BE19000 with MT7976GN / MT7977BN / MT7977AN,
#                 2.4/5/6 GHz 4x4 (6 GHz 4T5R); e.g. a second XR1710G or
#                 W1700K running the same OpenWrt tree.
#   antennas      the board's stock antenna array (XR1710G: 10 internal
#                 antennas, 4+4+4+2); keep the same orientation as the AP
#                 and place the boards 3-5 m apart.
#   power         12 V/5 A barrel jack, 60 W supply, separate from the AP.
#   cooling       stock heatsink + PWM fan on an open bench; do not
#                 enclose it during the 320 MHz run.
#   host interface the board's 2x10GbE + 2x1GbE wired ports: one 10GbE
#                 link to the lab host for the traffic source and SSH
#                 control; the STA association itself is over the air.
#   why           fastest to stand up and same known-good firmware, but
#                 both ends then share mt76; verify STA-mode 6 GHz EHT320
#                 4SS in station dump before trusting a result.
#
# Bench and safety
#   * Offline, non-production lab exercise.  6 GHz 320 MHz is a lab
#     configuration, not a product setting; do not leave the 4SS client
#     associated or radiating outside the bench.
#   * This harness never buys, downloads, flashes, writes UBI or reboots
#     anything, and never changes wireless/UCI config.  Set the target
#     band and width up yourself, verify it, then run this.
#   * Keep the AP and client on separate supplies and a wired management
#     path; the AP fan must be working and the bench at <= 25 C.
#   * Run one band per invocation.  Disable MLO for the ceiling run: a
#     2-link MLO association can split the streams and is not a single
#     4SS link.
#   * Expected order: Option B if a second board is on hand; Option A
#     when a driver-independent client is required.  Both is better than
#     either for attribution, but do not mix them in one comparison.
#   * Traffic source: install iperf3 on the AP and run "iperf3 -s" on the
#     4SS client (the default arms), or pass --tx-source/--rx-source
#     (for example the lab's raw AP-side source, or an ssh command that
#     starts the source on the client).  Without one of these a run
#     refuses instead of inventing a source.
# END LAB PLAN
#
# Protocol
#   1. Read the AP (band, frequency, width) and the client from
#      "iw dev IFACE station dump".  No interface changes are made.
#   2. A client is a 4SS client only when its station dump rate reports
#      EHT-NSS/HE-NSS 4 (or a 4SS rate in one direction while the other is
#      still settling).  With no such client the script prints
#      "SKIP: no 4SS client" and exits 0 without sending traffic.
#   3. A run refuses a station dump that already reports a 2SS rate before
#      sending traffic (exit 3); a dry run reports it and exits 0.  A
#      station dump with no rate yet is probed by the warm-up; if the
#      relevant direction never reaches NSS 4 at the expected width within
#      --warmup seconds, the arm is refused and no measured window is taken.
#      The dump is a current-rate field, not an association capability: a
#      4SS client that idled down shows fewer streams here, and the harness
#      refuses it rather than probing, so drive a short local source by
#      hand (for example "iperf3 -c CLIENT_IP -t 10") and re-check the dump
#      before invoking this with --run.  A dump with no rate at all is
#      probed by the --warmup window.
#   4. Each arm starts one local source on the AP: AP->STA uses the AP's
#      own source (default: iperf3 -c CLIENT_IP -P PROCS); STA->AP uses
#      iperf3 reverse mode (default: iperf3 -c CLIENT_IP -R -P PROCS), so
#      the client's iperf3 server is the data source and the AP only
#      controls and receives.  --tx-source/--rx-source replace either
#      command; they run PROCS copies on the AP and must stay in the
#      foreground for SOURCE_SECS.
#   5. A window starts only after the relevant station-dump direction
#      reports NSS 4 at the expected width.  The window records the
#      station TX/RX byte delta, retries, PCIe0 IRQ delta, mt76 token
#      pool, CPU busy, MemAvailable and the thermal peak.
#   6. Print one TSV row per arm, then a verdict that separates
#      radio-reachable from SoC-reachable.  The script exits 0 for a
#      completed measurement and for a clean skip, 3 for a refusal or an
#      invalid arm, and 1 for a setup/run failure.
#
# Output schema
#   result.tsv has one header line and one row per completed arm:
#
#     arm nss width_mhz mcs signal_dbm seconds gbit_s tx_mbit rx_mbit
#     retries pcie0_irq_delta npu_token npu_token_max cpu_busy_pct
#     mem_avail_kb thermal_c status
#
#   arm            AP->STA or STA->AP
#   nss            EHT-NSS/HE-NSS of the arm's station-dump direction
#   width_mhz      channel width from the same rate line (160 or 320)
#   mcs, signal_dbm, tx_mbit, rx_mbit
#                  station-dump rate fields at the end of the window
#   seconds        /proc/uptime delta of the measured window
#   gbit_s         measured direction bytes * 8 / seconds / 1e9
#   retries        station-dump tx retries delta over the window
#   pcie0_irq_delta
#                  MT7996 PCIe0 (0000:01:00.0, 1fc00000.pcie) IRQ count
#                  delta over the window, all CPUs; n/a when not found
#   npu_token      peak mt76 token_info token_count during the window
#   npu_token_max  mt76 token_info token pool size
#   cpu_busy_pct   /proc/stat non-idle delta over the window
#   mem_avail_kb   minimum MemAvailable during the window
#   thermal_c      maximum thermal-zone/MT7996-hwmon temperature during
#                  the window (the fan controller's open temp channel is
#                  excluded); n/a when no sensor exists
#   status         ok or the rejection reason
#
#   gbit_s is an L2/stack-side number: iw counts L2 bytes and retries, not
#   airtime, so a raw-injection source can exceed the reported PHY rate.
#   Read retries and the source log before calling it air throughput.
#
# Exit status
#   0  both arms measured, or clean SKIP (no 4SS client; nothing sent)
#   1  setup/run failure (missing iw/iperf3, wrong AP width, source died)
#   2  invalid arguments
#   3  refused (2SS association/rate) or an invalid arm (NSS/width change,
#      disassociation, short byte counters)
#
# POSIX sh only (busybox ash).  Tested with "sh -n", --help, --plan,
# --dry-run, shellcheck -s sh and stubbed end-to-end runs.
#
# Examples:
#   # read-only preflight on any host; exits 0 with a clean SKIP
#   ./scripts/wireless/4ss-lab.sh --dry-run
#
#   # print the full lab plan from this header
#   ./scripts/wireless/4ss-lab.sh --plan
#
#   # real 6G320 run, iperf3 server on the 4SS client
#   ./scripts/wireless/4ss-lab.sh --run --band 6g \
#       --client f8:fe:5e:a1:6f:a8 --client-ip 192.168.1.50 \
#       --window 10 --warmup 15 --procs 4
#
#   # same with the lab's raw AP-side source for AP->STA and a client-side
#   # source started over ssh for STA->AP
#   ./scripts/wireless/4ss-lab.sh --run --band 6g \
#       --client f8:fe:5e:a1:6f:a8 --client-ip 192.168.1.50 \
#       --tx-source '/tmp/ringblast "$IFACE" "$CLIENT" "$CLIENT_IP" "$SOURCE_SECS"' \
#       --rx-source 'ssh root@192.168.1.50 "iperf3 -c $AP_IP -t $SOURCE_SECS"'

set -u

PROG=${0##*/}
SELF=$0

CLIENT=${CLIENT:-}
CLIENT_SET=0
CLIENT_IP=${CLIENT_IP:-}
AP_IP=${AP_IP:-}
IFACE=${IFACE:-}
BAND=${BAND:-auto}
WINDOW=${WINDOW:-10}
WARMUP=${WARMUP:-15}
PROCS=${PROCS:-4}
TX_SOURCE=${TX_SOURCE:-}
RX_SOURCE=${RX_SOURCE:-}
OUT=${OUT:-}
TARGET_GBPS=${TARGET_GBPS:-}
CPU_THRESHOLD=${CPU_THRESHOLD:-85}
THERMAL_THRESHOLD=${THERMAL_THRESHOLD:-85}
MEM_THRESHOLD_KB=${MEM_THRESHOLD_KB:-65536}
NPU_THRESHOLD=${NPU_THRESHOLD:-90}
PCIE_IRQ_RATE=${PCIE_IRQ_RATE:-0}
RUN=0
LOG=

T_IFACE=
T_BAND=
T_FREQ=
T_AP_WIDTH=
T_CLIENT=
T_STATE=
T_EXPECTED_WIDTH=
T_TARGET=

HEADER_PRINTED=0
SOURCES_PIDS=
OUT_CREATED=0
AP_ROW=
STA_ROW=
VERDICT=

# Resolve an absolute script path so --plan and messages work from any cwd
# and after the script was copied to /tmp on the board.
case $SELF in
/*) ;;
*/*)
	SELF=$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)/$(basename "$SELF")
	;;
*)
	_resolved=$(command -v "$SELF" 2>/dev/null)
	[ -n "$_resolved" ] && SELF=$_resolved
	;;
esac

warn() {
	printf '%s: %s\n' "$PROG" "$1" >&2
}

say() {
	printf '%s\n' "$*"
	if [ -n "$LOG" ]; then
		printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)" "$*" >>"$LOG" 2>/dev/null
	fi
}

die() {
	warn "$1"
	exit 1
}

usage_error() {
	warn "$1"
	printf 'Try "%s --help" for usage.\n' "$PROG" >&2
	exit 2
}

have() {
	command -v "$1" >/dev/null 2>&1
}

is_uint() {
	case ${1:-} in
	''|*[!0-9]*) return 1 ;;
	esac
	return 0
}

is_positive_number() {
	awk -v v="$1" 'BEGIN { exit !(v ~ /^[0-9]+([.][0-9]+)?$/ && v + 0 > 0) }'
}

valid_mac() {
	case ${1:-} in
	[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f])
		return 0
		;;
	esac
	return 1
}

norm_mac() {
	printf '%s' "$1" | tr 'A-F' 'a-f' | tr '-' ':'
}

uptime_float() {
	cut -d' ' -f1 /proc/uptime 2>/dev/null
}

uptime_int() {
	uptime_float | cut -d. -f1
}

station_has() {
	iw dev "$1" station dump 2>/dev/null | grep -q "^Station $2 "
}

iface_info() {
	iw dev "$1" info 2>/dev/null
}

iface_type() {
	iface_info "$1" | awk '$1 == "type" { print $2; exit }'
}

iface_freq() {
	iface_info "$1" | awk '
		/channel/ {
			if (match($0, /\([0-9]+ MHz\)/)) {
				f = substr($0, RSTART, RLENGTH)
				gsub(/[^0-9]/, "", f)
				print f
				exit
			}
		}'
}

iface_width() {
	iface_info "$1" | awk '
		{
			for (i = 1; i <= NF; i++)
				if ($i == "width:") {
					w = $(i + 1)
					sub(/MHz/, "", w)
					print w
					exit
				}
		}'
}

band_of_freq() {
	if [ "$1" -ge 5925 ] 2>/dev/null; then
		printf '6g'
	elif [ "$1" -ge 4900 ] 2>/dev/null; then
		printf '5g'
	else
		printf 'other'
	fi
}

# AP rows as iface|band|freq|width, one per 5/6 GHz AP interface that has a
# readable channel.  An interface that is down has no channel and is left
# out: its band cannot be validated.
ap_ifaces() {
	_names=$(iw dev 2>/dev/null | awk '$1 == "Interface" { print $2 }')
	while IFS= read -r _d; do
		[ -n "$_d" ] || continue
		[ "$(iface_type "$_d")" = AP ] || continue
		_f=$(iface_freq "$_d")
		[ -n "$_f" ] || continue
		_b=$(band_of_freq "$_f")
		case $_b in
		5g|6g) printf '%s|%s|%s|%s\n' "$_d" "$_b" "$_f" "$(iface_width "$_d")" ;;
		esac
	done <<EOF
$_names
EOF
}

# One station sample as a pipe-delimited record:
#   assoc|signal|tx_bytes|rx_bytes|tx_retries|tx_failed|tx_nss|tx_width|
#   tx_mcs|tx_bitrate|rx_nss|rx_width|rx_mcs|rx_bitrate
# Empty fields are missing fields, not zero.  The client may be given by its
# link address; for an MLD client use the link address printed in the dump.
station_state() {
	iw dev "$1" station dump 2>/dev/null | awk -v want="$2" '
		function nss_of(line,   i, n, a) {
			n = split(line, a, " ")
			for (i = 1; i <= n; i++) {
				if (a[i] ~ /NSS$/ && a[i + 1] ~ /^[0-9]+$/)
					return a[i + 1]
				if (a[i] ~ /NSS:[0-9]+$/) {
					sub(/.*:/, "", a[i])
					return a[i]
				}
			}
			return ""
		}
		function mcs_of(line,   i, n, a) {
			n = split(line, a, " ")
			for (i = 1; i <= n; i++) {
				if (a[i] ~ /MCS$/ && a[i + 1] ~ /^[0-9]+$/)
					return a[i + 1]
				if (a[i] ~ /MCS:[0-9]+$/) {
					sub(/.*:/, "", a[i])
					return a[i]
				}
			}
			return ""
		}
		function width_of(line,   i, n, a, w) {
			n = split(line, a, " ")
			for (i = 1; i <= n; i++) {
				w = a[i]
				if (w ~ /MHz$/) {
					sub(/MHz$/, "", w)
					if (w ~ /^[0-9]+$/)
						return w
				}
				if (w ~ /^[0-9]+$/ && a[i + 1] == "MHz")
					return w
			}
			return ""
		}
		/^Station / {
			on = (tolower($2) == tolower(want))
			if (on)
				found = 1
			next
		}
		on && $1 == "signal:" { sig = $2 }
		on && $1 == "signal" && $2 == "avg:" { sigavg = $3 }
		on && $1 == "tx" && $2 == "bytes:" { txb = $3 }
		on && $1 == "rx" && $2 == "bytes:" { rxb = $3 }
		on && $1 == "tx" && $2 == "retries:" { retr = $3 }
		on && $1 == "tx" && $2 == "failed:" { fail = $3 }
		on && $1 == "tx" && $2 == "bitrate:" {
			txn = nss_of($0)
			txw = width_of($0)
			txm = mcs_of($0)
			txr = $3
		}
		on && $1 == "rx" && $2 == "bitrate:" {
			rxn = nss_of($0)
			rxw = width_of($0)
			rxm = mcs_of($0)
			rxr = $3
		}
		END {
			if (sig == "" && sigavg != "")
				sig = sigavg
			printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n",
				(found ? "yes" : "no"), sig, txb, rxb, retr, fail,
				txn, txw, txm, txr, rxn, rxw, rxm, rxr
		}
	'
}

field() {
	printf '%s\n' "$1" | cut -d'|' -f"$2"
}

station_macs() {
	iw dev "$1" station dump 2>/dev/null | awk '/^Station / { print $2 }'
}

# Numeric NSS of one direction, or empty when the dump has no such rate.
arm_nss() {
	case $1 in
	AP-STA) field "$2" 7 ;;
	STA-AP) field "$2" 11 ;;
	esac
}

arm_width() {
	case $1 in
	AP-STA) field "$2" 8 ;;
	STA-AP) field "$2" 12 ;;
	esac
}

arm_mcs() {
	case $1 in
	AP-STA) field "$2" 9 ;;
	STA-AP) field "$2" 13 ;;
	esac
}


# Direction byte counter used for the measured Gbit/s.
arm_bytes() {
	case $1 in
	AP-STA) field "$2" 3 ;;
	STA-AP) field "$2" 4 ;;
	esac
}

# Find a client for one band.  With --client, find the AP that has it
# associated.  Without it, pick the first station that already reports an
# NSS 4 rate in either direction (a 4SS association), preferring the first
# AP row.  Sets T_* and returns 0 on success.
find_target_in_band() {
	_want_band=$1
	_rows=$(ap_ifaces | awk -F'|' -v b="$_want_band" '$2 == b')
	while IFS='|' read -r _d _b _f _w; do
		[ -n "$_d" ] || continue
		if [ "$CLIENT_SET" = 1 ]; then
			if station_has "$_d" "$CLIENT"; then
				T_IFACE=$_d
				T_BAND=$_b
				T_FREQ=$_f
				T_AP_WIDTH=$_w
				T_CLIENT=$CLIENT
				return 0
			fi
		else
			_macs=$(station_macs "$_d")
			while IFS= read -r _m; do
				[ -n "$_m" ] || continue
				_st=$(station_state "$_d" "$_m")
				_txn=$(field "$_st" 7)
				_rxn=$(field "$_st" 11)
				if [ "$_txn" = 4 ] || [ "$_rxn" = 4 ]; then
					T_IFACE=$_d
					T_BAND=$_b
					T_FREQ=$_f
					T_AP_WIDTH=$_w
					T_CLIENT=$_m
					T_STATE=$_st
					return 0
				fi
			done <<EOF
$_macs
EOF
		fi
	done <<EOF
$_rows
EOF
	return 1
}

# Shared "no client" record (scripts/wireless/lib/no-client.sh).  Best effort:
# a harness must still skip, and still exit 0, when the record cannot be
# written.
NO_CLIENT_LIB=$(dirname "$0")/lib/no-client.sh
# shellcheck source=lib/no-client.sh
[ -r "$NO_CLIENT_LIB" ] && . "$NO_CLIENT_LIB"

# The one command that runs the two arms once a 4SS client exists.
NC_4SS_RUN='sudo sh scripts/wireless/4ss-lab.sh --run --band <5g|6g> --client <STA_MAC> --client-ip <STA_IP> --window 10 --warmup 15 --procs 4'

skip_no_client() {
	# A board with no 4SS client has nothing to measure, so the skip is
	# recorded instead of dropped: hw-gap-report.sh merges it under #4.  The
	# stdout lines stay the documented contract; the hints go to stderr.
	_rec=$(no_client_record "${OUT:-}" 4 4ss-client "$NC_4SS_RUN" \
		"$1" \
		"iw station dump reports tx/rx NSS 4 for one station on the 5/6 GHz AP" \
		"result.tsv holds both arm rows with gbit_s, retries and status ok" \
		"no arm is refused for a 2SS association or a mid-run width/NSS change" \
		"cpu_busy_pct, npu token peak and PCIe0 IRQ delta recorded for both arms" 2>/dev/null)
	say "SKIP: no 4SS client ($1)"
	say "  nothing was sent and no traffic was generated"
	if [ -n "$_rec" ]; then
		warn "missing 4ss-client #4; once it is available run: $NC_4SS_RUN"
		warn "no-client record: $_rec"
	fi
	exit 0
}

refuse_association() {
	say "REFUSE: $1"
	say "  the 4SS lab does not run on a 2SS association; no traffic was sent"
	exit 3
}

set_expected() {
	case $T_BAND in
	6g) T_EXPECTED_WIDTH=320; T_TARGET=6.0 ;;
	*) T_EXPECTED_WIDTH=160; T_TARGET=3.5 ;;
	esac
	if [ -n "$TARGET_GBPS" ]; then
		T_TARGET=$TARGET_GBPS
	fi
}

usage() {
	cat <<EOF
Usage: $PROG [--run] [options]

4 spatial stream lab plan and harness for the XR1710G.  The default mode is
a read-only dry run: it prints the topology and the preconditions, sends no
traffic and writes nothing.  --run starts the local sources and measures
the AP->STA and STA->AP arms.  The full offline lab plan is in --plan and
in the header of this file.

Modes:
  --run                 really run the two measured arms
  --dry-run             explicit read-only plan (the default)
  --plan                print the full lab plan from the header and exit
  -h, --help            this text

Lab plan summary (full detail: --plan):
  module        Option A: QCN9274/QCN6274 5-7 GHz 4x4 802.11be module,
                M.2 A+E/mini-PCIe, PCIe 3.0 x2, 4x U.FL.
                Option B: second MT7996AV BE19000 board (MT7976GN/
                MT7977BN/MT7977AN, 2.4/5/6 GHz 4x4, 6 GHz 4T5R).
  antennas      Option A: 4x U.FL-to-SMA + 4x 5/6 GHz dual-band, >= 3 dBi,
                >= 10 cm apart.  Option B: the board's stock array.
  power         Option A: 3.3 V or 5 V module rail, ~9 W, <= 15 W budget.
                Option B: 12 V/5 A barrel jack, 60 W supply.
  cooling       Option A: module heatsink + 40 mm fan.  Option B: stock
                heatsink + PWM fan, open bench.  Ambient <= 25 C.
  host interface Option A: PCIe 3.0 x2 via M.2 A+E/mini-PCIe on a host
                with a free slot (the existing host has none) + 10GbE.
                Option B: the second board's 2x10GbE/2x1GbE wired ports
                for traffic and SSH; the 4SS association is over the air.
  The AP is offline/non-production; this script never buys, flashes,
  writes UBI or changes the wireless config.

Target options:
  --client MAC          station address (default: the first station that
                        reports NSS 4 on a 5/6 GHz AP)
  --client-ip IP        client IPv4 for the default iperf3 sources (also
                        resolved from /proc/net/arp when possible)
  --ap-ip IP            AP IPv4 exported to a client-side source (default:
                        the br-lan address when one exists)
  --iface NAME          AP interface (default: the AP with the client or
                        the 4SS station)
  --band 5g|6g|auto     band (default auto); 5g expects 160 MHz and the
                        3.5 Gbit/s ceiling, 6g expects 320 MHz and the
                        6.0 Gbit/s ceiling
  --window SEC          measured window (default 10)
  --warmup SEC          rate warm-up before the window (default 15)
  --procs N             iperf3 parallel streams / custom-source copies
                        (default 4)
  --tx-source CMD       AP->STA source command, run PROCS times on the AP;
                        the default is "iperf3 -c IP -P PROCS -t SECS"
  --rx-source CMD       STA->AP source command, run PROCS times on the AP;
                        the default is the same with -R, so the client's
                        iperf3 server is the data source
  --out DIR             output directory (default /tmp/4ss-lab-<time>)
  --target-gbps G       ceiling target (default 3.5 for 160 MHz, 6.0 for
                        320 MHz)
  --cpu-threshold PCT   CPU busy evidence threshold (default 85)
  --thermal-threshold C thermal evidence threshold (default 85)
  --mem-threshold-kb KB MemAvailable evidence threshold (default 65536)
  --npu-threshold PCT   NPU token pool usage evidence threshold (default 90)
  --pcie-irq-rate N     PCIe0 IRQ/s evidence threshold (default 0 = off)

The custom source runs on the AP and is exported ARM, IFACE, CLIENT,
CLIENT_IP, AP_IP, WINDOW, WARMUP, SOURCE_SECS, PROCS and OUT.  It must stay
in the foreground for SOURCE_SECS.  For a source that really runs on the 4SS
client, pass an ssh command as --rx-source (the AP is 192.168.1.1 in the
example below).

A true run needs iperf3 on the AP and "iperf3 -s" on the 4SS client unless
both sources are overridden.  The script never changes the AP radio; bring
the target band/width up first and verify it in "iw dev".  A dry run reports
a 2SS station dump but exits 0; a run refuses it before traffic.  The dump is
the current rate, so a 4SS client that idled down is refused too: drive a
short local source by hand (for example "iperf3 -c CLIENT_IP -t 10") and
re-check the dump before a run.  A dump with no rate at all is probed by the
--warmup window.

Output: one TSV row per arm (NSS, width, Gbit/s, PCIe0 IRQ, NPU token, CPU,
memory, thermal and status), then one of:
  VERDICT: radio-reachable   both arms reached the 4SS ceiling target
  VERDICT: SoC-reachable     a target was missed with SoC-side saturation
  VERDICT: inconclusive      a target was missed with no SoC-side evidence
  VERDICT: rejected          an arm was invalid or refused
Exit status: 0 measured/skip, 1 setup failure, 2 usage, 3 refused/invalid.

Examples:
  $PROG --plan
  $PROG --dry-run
  $PROG --run --band 6g --client f8:fe:5e:a1:6f:a8 --client-ip 192.168.1.50
  $PROG --run --band 5g --client f8:fe:5e:a1:6f:a8 --client-ip 192.168.1.50 \\
      --tx-source '/tmp/ringblast "\$IFACE" "\$CLIENT" "\$CLIENT_IP" "\$SOURCE_SECS"' \\
      --rx-source 'ssh root@192.168.1.50 "iperf3 -c \$AP_IP -t \$SOURCE_SECS"'
EOF
}

print_plan() {
	if [ -r "$SELF" ]; then
		sed -n '/^# BEGIN LAB PLAN$/,/^# END LAB PLAN$/p' "$SELF" |
			sed '1d;$d;s/^# \{0,1\}//'
	else
		warn "cannot read $SELF for the lab plan"
		exit 1
	fi
}

while [ $# -gt 0 ]; do
	case $1 in
	-h|--help)
		usage
		exit 0
		;;
	--plan)
		print_plan
		exit 0
		;;
	--run)
		RUN=1
		;;
	--dry-run)
		RUN=0
		;;
	--client)
		[ $# -ge 2 ] || usage_error "--client needs a MAC address"
		CLIENT=$(norm_mac "$2")
		CLIENT_SET=1
		shift
		;;
	--client-ip)
		[ $# -ge 2 ] || usage_error "--client-ip needs an IPv4 address"
		CLIENT_IP=$2
		shift
		;;
	--ap-ip)
		[ $# -ge 2 ] || usage_error "--ap-ip needs an IPv4 address"
		AP_IP=$2
		shift
		;;
	--iface)
		[ $# -ge 2 ] || usage_error "--iface needs an interface name"
		IFACE=$2
		shift
		;;
	--band)
		[ $# -ge 2 ] || usage_error "--band needs 5g, 6g or auto"
		BAND=$2
		shift
		;;
	--window)
		[ $# -ge 2 ] || usage_error "--window needs seconds"
		WINDOW=$2
		shift
		;;
	--warmup)
		[ $# -ge 2 ] || usage_error "--warmup needs seconds"
		WARMUP=$2
		shift
		;;
	--procs)
		[ $# -ge 2 ] || usage_error "--procs needs a count"
		PROCS=$2
		shift
		;;
	--tx-source)
		[ $# -ge 2 ] || usage_error "--tx-source needs a command"
		TX_SOURCE=$2
		shift
		;;
	--rx-source)
		[ $# -ge 2 ] || usage_error "--rx-source needs a command"
		RX_SOURCE=$2
		shift
		;;
	--out)
		[ $# -ge 2 ] || usage_error "--out needs a directory"
		OUT=$2
		shift
		;;
	--target-gbps)
		[ $# -ge 2 ] || usage_error "--target-gbps needs a number"
		TARGET_GBPS=$2
		shift
		;;
	--cpu-threshold)
		[ $# -ge 2 ] || usage_error "--cpu-threshold needs percent"
		CPU_THRESHOLD=$2
		shift
		;;
	--thermal-threshold)
		[ $# -ge 2 ] || usage_error "--thermal-threshold needs Celsius"
		THERMAL_THRESHOLD=$2
		shift
		;;
	--mem-threshold-kb)
		[ $# -ge 2 ] || usage_error "--mem-threshold-kb needs KiB"
		MEM_THRESHOLD_KB=$2
		shift
		;;
	--npu-threshold)
		[ $# -ge 2 ] || usage_error "--npu-threshold needs percent"
		NPU_THRESHOLD=$2
		shift
		;;
	--pcie-irq-rate)
		[ $# -ge 2 ] || usage_error "--pcie-irq-rate needs IRQ/s"
		PCIE_IRQ_RATE=$2
		shift
		;;
	--)
		shift
		break
		;;
	*)
		usage_error "unknown option: $1"
		;;
	esac
	shift
done

case $BAND in
auto|5g|6g) ;;
*) usage_error "--band must be 5g, 6g or auto" ;;
esac

case $CLIENT_SET in
1)
	valid_mac "$CLIENT" || usage_error "--client must be a MAC address"
	;;
esac

[ -n "$CLIENT_IP" ] && ! printf '%s' "$CLIENT_IP" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' &&
	usage_error "--client-ip must be an IPv4 address"
[ -n "$AP_IP" ] && ! printf '%s' "$AP_IP" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' &&
	usage_error "--ap-ip must be an IPv4 address"

is_uint "$WINDOW" || usage_error "--window must be a positive integer"
is_uint "$WARMUP" || usage_error "--warmup must be a positive integer"
is_uint "$PROCS" || usage_error "--procs must be a positive integer"
[ "$WINDOW" -ge 2 ] || usage_error "--window must be at least 2 seconds"
[ "$WARMUP" -ge 2 ] || usage_error "--warmup must be at least 2 seconds"
[ "$PROCS" -ge 1 ] && [ "$PROCS" -le 64 ] || usage_error "--procs must be 1..64"
[ -n "$TARGET_GBPS" ] && ! is_positive_number "$TARGET_GBPS" &&
	usage_error "--target-gbps must be a positive number"
is_positive_number "$CPU_THRESHOLD" || usage_error "--cpu-threshold must be a positive number"
is_positive_number "$THERMAL_THRESHOLD" || usage_error "--thermal-threshold must be a positive number"
is_uint "$MEM_THRESHOLD_KB" || usage_error "--mem-threshold-kb must be a positive integer"
is_positive_number "$NPU_THRESHOLD" || usage_error "--npu-threshold must be a positive number"
is_uint "$PCIE_IRQ_RATE" || usage_error "--pcie-irq-rate must be a non-negative integer"


# A real run needs iw; a dry run can still explain the skip on a host.
if ! have iw; then
	if [ "$RUN" = 1 ]; then
		die "iw not found; run this on the AP"
	fi
	skip_no_client "iw not found on this host"
fi

if [ -n "$IFACE" ]; then
	_info=$(iface_info "$IFACE")
	[ -n "$_info" ] || usage_error "--iface $IFACE does not exist"
	[ "$(iface_type "$IFACE")" = AP ] || usage_error "--iface $IFACE is not an AP interface"
	_f=$(iface_freq "$IFACE")
	[ -n "$_f" ] || skip_no_client "AP $IFACE has no channel (down?)"
	_b=$(band_of_freq "$_f")
	case $_b in
	5g|6g) ;;
	*) usage_error "--iface $IFACE is not a 5/6 GHz AP" ;;
	esac
	if [ "$BAND" != auto ] && [ "$BAND" != "$_b" ]; then
		usage_error "--iface $IFACE is $_b, but --band is $BAND"
	fi
	T_IFACE=$IFACE
	T_BAND=$_b
	T_FREQ=$_f
	T_AP_WIDTH=$(iface_width "$IFACE")
	if [ "$CLIENT_SET" = 1 ]; then
		station_has "$IFACE" "$CLIENT" ||
			skip_no_client "client $CLIENT is not associated on $IFACE"
		T_CLIENT=$CLIENT
		T_STATE=$(station_state "$IFACE" "$CLIENT")
	else
		_found=
		_macs=$(station_macs "$IFACE")
		while IFS= read -r _m; do
			[ -n "$_m" ] || continue
			_st=$(station_state "$IFACE" "$_m")
			if [ "$(field "$_st" 7)" = 4 ] || [ "$(field "$_st" 11)" = 4 ]; then
				T_CLIENT=$_m
				T_STATE=$_st
				_found=1
				break
			fi
		done <<EOF
$_macs
EOF
		[ -n "$_found" ] ||
			skip_no_client "no station on $IFACE reports NSS 4"
	fi
else
	if [ "$BAND" = auto ]; then
		find_target_in_band 6g || find_target_in_band 5g ||
			skip_no_client "no station on a 5/6 GHz AP reports NSS 4"
	else
		find_target_in_band "$BAND" ||
			skip_no_client "no station reports NSS 4 on the $BAND band"
	fi
	case $T_BAND in
	6g)
		[ -n "$T_CLIENT" ] || skip_no_client "no 6 GHz 4SS station found"
		;;
	5g)
		[ -n "$T_CLIENT" ] || skip_no_client "no 5 GHz 4SS station found"
		;;
	esac
	[ -n "$T_STATE" ] || T_STATE=$(station_state "$T_IFACE" "$T_CLIENT")
fi

BAND=$T_BAND
set_expected

# The AP width is a manual precondition: this harness never changes it.
if [ -n "$T_AP_WIDTH" ] && [ "$T_AP_WIDTH" != "$T_EXPECTED_WIDTH" ]; then
	if [ "$RUN" = 1 ]; then
		die "AP $T_IFACE is ${T_AP_WIDTH} MHz, but the $BAND 4SS ceiling arm needs ${T_EXPECTED_WIDTH} MHz; set the radio up before running (this harness does not change it)"
	fi
	say "precondition: AP $T_IFACE is ${T_AP_WIDTH} MHz; the $BAND arm needs ${T_EXPECTED_WIDTH} MHz (a run would refuse)"
elif [ -z "$T_AP_WIDTH" ]; then
	if [ "$RUN" = 1 ]; then
		die "cannot read the width of AP $T_IFACE; bring the interface up and verify it"
	fi
	say "precondition: AP $T_IFACE width is not readable (down?); a run would refuse"
fi

_txn=$(field "$T_STATE" 7)
_rxn=$(field "$T_STATE" 11)
_evidence=
if [ "$_txn" = 4 ] || [ "$_rxn" = 4 ]; then
	_evidence=4ss
elif is_uint "$_txn" || is_uint "$_rxn"; then
	_best=${_txn:-0}
	[ "$_rxn" -gt "$_best" ] 2>/dev/null && _best=$_rxn
	_evidence=low
else
	_evidence=unknown
fi

_precheck_low=
if [ "$_evidence" = low ]; then
	if [ "$RUN" = 1 ]; then
		refuse_association "$T_CLIENT on $T_IFACE reports NSS ${_best:-?} (tx=${_txn:-none} rx=${_rxn:-none}); 4 spatial streams are required"
	fi
	_precheck_low="  precheck: the station dump reports NSS ${_best:-?}; a run would REFUSE the 2SS association"
fi

# Resolve the client IPv4 from the ARP table when it was not given.  This is
# only needed for the default iperf3 sources.
if [ -z "$CLIENT_IP" ]; then
	CLIENT_IP=$(awk -v mac="$T_CLIENT" 'tolower($4) == mac { print $1; exit }' /proc/net/arp 2>/dev/null)
fi

if [ -z "$AP_IP" ] && have ip; then
	AP_IP=$(ip -4 -o addr show 2>/dev/null |
		awk '$2 == "br-lan" && $3 == "inet" { sub(/\/.*/, "", $4); print $4; exit }')
	[ -n "$AP_IP" ] || AP_IP=$(ip -4 -o addr show 2>/dev/null |
		awk '$2 != "lo" && $3 == "inet" { sub(/\/.*/, "", $4); print $4; exit }')
fi

say "$PROG: $([ "$RUN" = 1 ] && echo 'run' || echo 'dry run'); no wireless configuration is changed"
say "  ap:     $T_IFACE band=$BAND freq=$T_FREQ MHz width=${T_AP_WIDTH:-?} MHz"
say "  client: $T_CLIENT station-dump tx_nss=${_txn:-unknown} tx_width=$(field "$T_STATE" 8) rx_nss=${_rxn:-unknown} rx_width=$(field "$T_STATE" 12)"
say "  target: $T_TARGET Gbit/s at ${T_EXPECTED_WIDTH} MHz 4SS"
say "  telemetry: PCIe0 IRQ, mt76 token_info, /proc/stat, /proc/meminfo, thermal"
if [ -n "$_precheck_low" ]; then
	say "$_precheck_low"
fi
if [ "$_evidence" = unknown ]; then
	say "  precheck: the station dump has no NSS rate yet; a run uses the --warmup probe and refuses if it stays below 4SS"
fi

if [ "$RUN" = 0 ]; then
	if [ -n "$TX_SOURCE" ]; then
		say "  tx source: custom command (AP->STA, $PROCS copies)"
	elif have iperf3; then
		say "  tx source: iperf3 -c ${CLIENT_IP:-<client-ip>} -P $PROCS -t $((WARMUP + WINDOW + 5)) (AP->STA)"
	else
		say "  tx source: iperf3 not installed; a run needs --tx-source or iperf3"
	fi
	if [ -n "$RX_SOURCE" ]; then
		say "  rx source: custom command (STA->AP, $PROCS copies)"
	elif have iperf3; then
		say "  rx source: iperf3 -c ${CLIENT_IP:-<client-ip>} -R -P $PROCS -t $((WARMUP + WINDOW + 5)) (STA->AP)"
	else
		say "  rx source: iperf3 not installed; a run needs --rx-source or iperf3"
	fi
	say "  a real run needs --run; it starts only the local sources and stops them on exit"
	say "  full lab plan: $PROG --plan"
	exit 0
fi

# ---------------------------------------------------------------------------
# Real run
# ---------------------------------------------------------------------------

if [ -z "$TX_SOURCE" ] || [ -z "$RX_SOURCE" ]; then
	have iperf3 || die "iperf3 not found; install it or pass --tx-source/--rx-source"
fi
if { [ -z "$TX_SOURCE" ] || [ -z "$RX_SOURCE" ]; } && [ -z "$CLIENT_IP" ]; then
	die "no client IPv4 for the default iperf3 sources; pass --client-ip"
fi

[ -n "$OUT" ] || OUT=/tmp/4ss-lab-$(date '+%Y%m%d-%H%M%S' 2>/dev/null)
mkdir -p "$OUT" || die "cannot create output directory $OUT"
OUT_CREATED=1
LOG=$OUT/run.log
printf 'arm\tnss\twidth_mhz\tmcs\tsignal_dbm\tseconds\tgbit_s\ttx_mbit\trx_mbit\tretries\tpcie0_irq_delta\tnpu_token\tnpu_token_max\tcpu_busy_pct\tmem_avail_kb\tthermal_c\tstatus\n' >"$OUT/result.tsv" ||
	die "cannot write $OUT/result.tsv"

SOURCE_SECS=$((WARMUP + WINDOW + 5))
say "output: $OUT"
if [ -n "$TX_SOURCE" ]; then
	_src_ap=custom
else
	_src_ap=iperf3
fi
if [ -n "$RX_SOURCE" ]; then
	_src_sta=custom
else
	_src_sta="iperf3 -R"
fi
say "  sources: AP->STA $_src_ap; STA->AP $_src_sta"
say "  timing: warm-up ${WARMUP}s, window ${WINDOW}s, source life ${SOURCE_SECS}s"

# Read one MT7996 PCIe0 IRQ number.  PCIe0 is the 1fc00000.pcie controller
# on this SoC; fall back to the mt7996e (not mt7996e-hif) interrupt label.
pcie0_irq_number() {
	for _d in /sys/bus/pci/devices/*; do
		[ -r "$_d/vendor" ] || continue
		[ "$(cat "$_d/vendor" 2>/dev/null)" = "0x14c3" ] || continue
		case $(cat "$_d/device" 2>/dev/null) in
		0x7990|0x7991) ;;
		*) continue ;;
		esac
		_real=$(readlink -f "$_d" 2>/dev/null)
		case $_real in
		*1fc00000.pcie*)
			cat "$_d/irq" 2>/dev/null
			return 0
			;;
		esac
	done
	awk '$NF == "mt7996e" { sub(/:/, "", $1); print $1; exit }' /proc/interrupts 2>/dev/null
}

PCIE0_IRQ=$(pcie0_irq_number)

pcie0_irq_sum() {
	[ -n "$PCIE0_IRQ" ] || return 0
	awk -v irq="$PCIE0_IRQ" '
		$1 == irq ":" {
			for (i = 2; i <= NF; i++) {
				if ($i !~ /^[0-9]+$/)
					break
				sum += $i
			}
			print sum
			exit
		}
	' /proc/interrupts 2>/dev/null
}

token_file() {
	for _f in /sys/kernel/debug/ieee80211/*/mt76/token_info; do
		[ -r "$_f" ] && {
			printf '%s' "$_f"
			return 0
		}
	done
	return 1
}

TOKEN_FILE=$(token_file)

# token_current|token_max|wed_current
read_token() {
	[ -n "$TOKEN_FILE" ] || return 0
	awk '
		$1 == "token_count:" { cur = $2; max = $4 }
		$1 == "wed_token_count:" { wed = $2 }
		END { printf "%s|%s|%s\n", cur, max, wed }
	' "$TOKEN_FILE" 2>/dev/null
}

# cpu_total|cpu_idle
read_cpu() {
	awk '/^cpu / {
		total = 0
		for (i = 2; i <= NF; i++)
			total += $i
		printf "%s|%s\n", total, $5 + $6
		exit
	}' /proc/stat 2>/dev/null
}

# available_kb|free_kb
read_mem() {
	awk '
		/MemAvailable:/ { avail = $2 }
		/MemFree:/ { free = $2 }
		END { printf "%s|%s\n", avail, free }
	' /proc/meminfo 2>/dev/null
}

# Coldest-to-hottest millidegrees, max over /sys/class/thermal and the
# MT7996 hwmon channels.  The NCT7802 fan controller's second channel can
# read 127.875 C when no diode is attached, so only the SoC thermal zone
# and the mt7996* hwmon channels are used for the threshold.
read_thermal_mc() {
	_max=
	for _f in /sys/class/thermal/thermal_zone*/temp; do
		[ -r "$_f" ] || continue
		_v=$(cat "$_f" 2>/dev/null)
		is_uint "$_v" || continue
		if [ -z "$_max" ] || [ "$_v" -gt "$_max" ]; then
			_max=$_v
		fi
	done
	for _h in /sys/class/hwmon/hwmon*; do
		[ -r "$_h/name" ] || continue
		case $(cat "$_h/name" 2>/dev/null) in
		mt7996*) ;;
		*) continue ;;
		esac
		for _f in "$_h"/temp*_input; do
			[ -r "$_f" ] || continue
			_v=$(cat "$_f" 2>/dev/null)
			is_uint "$_v" || continue
			if [ -z "$_max" ] || [ "$_v" -gt "$_max" ]; then
				_max=$_v
			fi
		done
	done
	printf '%s' "$_max"
}

# One sample line for the measured window:
# uptime|cpu_total|cpu_idle|mem_avail|thermal_mc|token|pcie_irq
sample_line() {
	_c=$(read_cpu)
	_m=$(read_mem)
	_t=$(read_token)
	_i=$(pcie0_irq_sum)
	printf '%s|%s|%s|%s|%s|%s|%s\n' \
		"$(uptime_float)" "$(field "$_c" 1)" "$(field "$_c" 2)" \
		"$(field "$_m" 1)" "$(read_thermal_mc)" "$(field "$_t" 1)" "${_i:-}"
}

alive_sources() {
	_n=0
	for _p in ${SOURCES_PIDS:-}; do
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
	_arm=$1
	_sh=$2
	_copies=1
	[ -n "$_sh" ] || return 1
	case $_arm in
	AP-STA) [ -n "$TX_SOURCE" ] && _copies=$PROCS ;;
	STA-AP) [ -n "$RX_SOURCE" ] && _copies=$PROCS ;;
	esac
	_i=1
	while [ "$_i" -le "$_copies" ]; do
		IFACE="$T_IFACE" CLIENT="$T_CLIENT" CLIENT_IP="$CLIENT_IP" \
		AP_IP="$AP_IP" WINDOW="$WINDOW" WARMUP="$WARMUP" \
		SOURCE_SECS="$SOURCE_SECS" PROCS="$PROCS" ARM="$_arm" OUT="$OUT" \
			sh -c "$_sh" >"$OUT/arm-$_arm-source-$_i.log" 2>&1 &
		SOURCES_PIDS="$SOURCES_PIDS $!"
		_i=$((_i + 1))
	done
	return 0
}

stop_sources() {
	[ -n "${SOURCES_PIDS:-}" ] || return 0
	for _p in $SOURCES_PIDS; do
		kill -0 "$_p" 2>/dev/null && kill "$_p" 2>/dev/null
	done
	for _p in $SOURCES_PIDS; do
		wait "$_p" 2>/dev/null
	done
	SOURCES_PIDS=
}

# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
	_rc=$?
	trap - EXIT INT TERM HUP
	stop_sources
	if [ "$_rc" -ne 0 ] && [ "$OUT_CREATED" = 1 ]; then
		warn "run ended with status $_rc; evidence kept in $OUT"
	fi
	exit "$_rc"
}

# shellcheck disable=SC2329  # invoked by the INT/TERM/HUP trap
on_signal() {
	warn "interrupted; stopping source processes"
	stop_sources
	exit 130
}

trap cleanup EXIT
trap on_signal INT TERM HUP

# Wait up to WARMUP seconds for the arm's station-dump direction to report
# NSS 4 at the expected width.  Sets WAIT_REASON and returns non-zero when
# the rate never arrives, the source dies, or the station drops.
WAIT_REASON=
wait_rate() {
	_arm=$1
	_start=$(uptime_int)
	_why=
	_last=
	while :; do
		_st=$(station_state "$T_IFACE" "$T_CLIENT")
		_n=$(arm_nss "$_arm" "$_st")
		_w=$(arm_width "$_arm" "$_st")
		_last="NSS ${_n:-unknown} at ${_w:-unknown} MHz"
		if [ "$_n" = 4 ] && [ "$_w" = "$T_EXPECTED_WIDTH" ]; then
			if [ "$(alive_sources)" -eq 0 ]; then
				_why="source exited before the measured window"
				break
			fi
			say "  warm-up: NSS 4 at ${_w} MHz ($(( $(uptime_int) - _start ))s)"
			return 0
		fi
		_el=$(( $(uptime_int) - _start ))
		if [ "$_el" -ge "$WARMUP" ]; then
			if [ "$_n" = 4 ]; then
				_why="NSS 4 at ${_w:-unknown} MHz after ${WARMUP}s, want ${T_EXPECTED_WIDTH} MHz"
			elif is_uint "$_n"; then
				_why="NSS ${_n} at ${_w:-unknown} MHz after ${WARMUP}s, want 4 at ${T_EXPECTED_WIDTH} MHz"
			else
				_why="no station rate after ${WARMUP}s"
			fi
			break
		fi
		if [ "$(alive_sources)" -eq 0 ]; then
			_why="all source processes exited during warm-up"
			break
		fi
		sleep 1
	done
	WAIT_REASON=$_why
	return 1
}

# Run one measured arm.  Sets A_* values; returns 0 when the arm is valid,
# 1 on a setup/source failure and 2 on an invalid/refused rate.
A_NSS=
A_WIDTH=
A_MCS=
A_SIGNAL=
A_SECONDS=
A_GBIT=
A_TX_MBIT=
A_RX_MBIT=
A_RETRIES=
A_PCIE0=
A_TOKEN=
A_TOKEN_MAX=
A_CPU=
A_MEM=
A_THERMAL=
A_STATUS=

measure_arm() {
	_arm=$1
	_cmd=
	A_NSS=
	A_WIDTH=
	A_MCS=
	A_SIGNAL=
	A_SECONDS=
	A_GBIT=
	A_TX_MBIT=
	A_RX_MBIT=
	A_RETRIES=
	A_PCIE0=
	A_TOKEN=
	A_TOKEN_MAX=
	A_CPU=
	A_MEM=
	A_THERMAL=
	A_STATUS=

	case $_arm in
	AP-STA)
		if [ -n "$TX_SOURCE" ]; then
			_cmd=$TX_SOURCE
		else
			_cmd="iperf3 -c $CLIENT_IP -P $PROCS -t $SOURCE_SECS"
		fi
		;;
	STA-AP)
		if [ -n "$RX_SOURCE" ]; then
			_cmd=$RX_SOURCE
		else
			_cmd="iperf3 -c $CLIENT_IP -R -P $PROCS -t $SOURCE_SECS"
		fi
		;;
	esac

	say "[arm $_arm] source: $_cmd"
	SOURCES_PIDS=
	start_sources "$_arm" "$_cmd" || {
		A_STATUS="source not started"
		return 1
	}
	if ! wait_rate "$_arm"; then
		_last=$(station_state "$T_IFACE" "$T_CLIENT")
		_last_nss=$(arm_nss "$_arm" "$_last")
		_last_width=$(arm_width "$_arm" "$_last")
		if [ "$(alive_sources)" -eq 0 ]; then
			say "REJECT: $_arm source exited during warm-up (log: $OUT/arm-$_arm-source-1.log)"
			stop_sources
			A_STATUS="source exited during warm-up"
			return 1
		fi
		if is_uint "$_last_nss" && [ "$_last_nss" -lt 4 ]; then
			say "REFUSE: $_arm station rate is ${_last_nss}SS at ${_last_width:-?} MHz after ${WARMUP}s"
			say "  the 4SS lab does not measure a 2SS association; stopping the source"
			stop_sources
			A_STATUS="refused: station rate NSS $_last_nss"
			return 2
		fi
		say "REJECT: $_arm $WAIT_REASON"
		stop_sources
		A_STATUS="$WAIT_REASON"
		return 2
	fi

	# Window boundary sample.  The station dumps, telemetry snapshots and
	# per-second samples all use the same direction.
	_st_before=$(station_state "$T_IFACE" "$T_CLIENT")
	printf '%s\n' "$_st_before" >"$OUT/arm-$_arm-station-before.txt"
	_cpu_before=$(read_cpu)
	_mem_before=$(read_mem)
	_token_before=$(read_token)
	_irq_before=$(pcie0_irq_sum)
	_win_start=$(uptime_float)
	: >"$OUT/arm-$_arm.samples.tsv"
	_s=0
	while [ "$_s" -lt "$WINDOW" ]; do
		sample_line >>"$OUT/arm-$_arm.samples.tsv"
		[ "$(alive_sources)" -gt 0 ] || break
		sleep 1
		_s=$((_s + 1))
	done
	_alive=$(alive_sources)
	_win_end=$(uptime_float)
	_st_after=$(station_state "$T_IFACE" "$T_CLIENT")
	printf '%s\n' "$_st_after" >"$OUT/arm-$_arm-station-after.txt"
	_cpu_after=$(read_cpu)
	_mem_after=$(read_mem)
	_token_after=$(read_token)
	_irq_after=$(pcie0_irq_sum)
	stop_sources

	A_NSS=$(arm_nss "$_arm" "$_st_after")
	A_WIDTH=$(arm_width "$_arm" "$_st_after")
	A_MCS=$(arm_mcs "$_arm" "$_st_after")
	A_SIGNAL=$(field "$_st_after" 2)
	A_TX_MBIT=$(field "$_st_after" 10)
	A_RX_MBIT=$(field "$_st_after" 14)
	_b=$(arm_bytes "$_arm" "$_st_after")
	_b0=$(arm_bytes "$_arm" "$_st_before")
	_retr=$(field "$_st_after" 5)
	_retr0=$(field "$_st_before" 5)
	_secs=$(awk -v a="$_win_start" -v b="$_win_end" 'BEGIN { printf "%.3f", b - a }')
	A_SECONDS=$_secs
	A_RETRIES=
	if is_uint "$_retr" && is_uint "$_retr0" && [ "$_retr" -ge "$_retr0" ]; then
		A_RETRIES=$((_retr - _retr0))
	fi
	_delta=
	if is_uint "$_b" && is_uint "$_b0" && [ "$_b" -ge "$_b0" ]; then
		_delta=$((_b - _b0))
	fi
	A_GBIT=$(awk -v d="${_delta:-0}" -v s="${_secs:-0}" 'BEGIN { if (s + 0 > 0) printf "%.3f", (d * 8) / (s * 1000000000); else print "0.000" }')
	A_PCIE0=
	if [ -n "$_irq_before" ] && [ -n "$_irq_after" ] && [ "$_irq_after" -ge "$_irq_before" ] 2>/dev/null; then
		A_PCIE0=$((_irq_after - _irq_before))
	fi
	A_TOKEN=$(field "$_token_after" 1)
	A_TOKEN_MAX=$(field "$_token_after" 2)
	A_CPU=$(awk -v t0="$(field "$_cpu_before" 1)" -v i0="$(field "$_cpu_before" 2)" \
		-v t1="$(field "$_cpu_after" 1)" -v i1="$(field "$_cpu_after" 2)" '
		BEGIN {
			dt = t1 - t0; di = i1 - i0
			if (dt > 0) printf "%.1f", 100 * (1 - di / dt); else print "n/a"
		}')
	# Minimum MemAvailable and maximum thermal/token across the samples.
	A_MEM=$(awk -F'|' '$4 != "" { if (m == "" || $4 + 0 < m + 0) m = $4 } END { print m }' "$OUT/arm-$_arm.samples.tsv")
	[ -n "$A_MEM" ] || A_MEM=$(field "$_mem_after" 1)
	A_THERMAL_MC=$(awk -F'|' '$5 != "" { if (m == "" || $5 + 0 > m + 0) m = $5 } END { print m }' "$OUT/arm-$_arm.samples.tsv")
	A_THERMAL=$(awk -v m="$A_THERMAL_MC" 'BEGIN { if (m == "") print "n/a"; else printf "%.1f", m / 1000 }')
	_token_peak=$(awk -F'|' '$6 != "" { if (m == "" || $6 + 0 > m + 0) m = $6 } END { print m }' "$OUT/arm-$_arm.samples.tsv")
	[ -n "$_token_peak" ] && A_TOKEN=$_token_peak

	A_STATUS=ok
	_reason=
	if [ "$(field "$_st_before" 1)" != yes ] || [ "$(field "$_st_after" 1)" != yes ]; then
		_reason="station not associated before or after the window"
	elif ! is_uint "$A_NSS" || [ "$A_NSS" -ne 4 ]; then
		_reason="NSS ${A_NSS:-missing} at window end, want 4"
	elif [ "$A_WIDTH" != "$T_EXPECTED_WIDTH" ]; then
		_reason="width ${A_WIDTH:-missing} MHz at window end, want $T_EXPECTED_WIDTH"
	elif [ -z "$_delta" ]; then
		_reason="counter reset or missing ${_arm} bytes"
	elif awk -v s="$A_SECONDS" 'BEGIN { exit !(s + 0 > 0) }'; then
		:
	else
		_reason="window duration is zero"
	fi
	if [ "$_alive" -eq 0 ]; then
		A_STATUS="source ended before the window finished"
		say "  $_arm: SOURCE FAILURE ($A_STATUS)"
		return 1
	fi
	if [ -n "$_reason" ]; then
		A_STATUS=$_reason
		say "  $_arm: INVALID ($_reason)"
		return 2
	fi
	say "  $_arm: NSS $A_NSS width $A_WIDTH MHz $A_MCS MCS signal ${A_SIGNAL:-?} dBm ${A_GBIT} Gbit/s (${A_SECONDS}s)"
	return 0
}

arm_row() {
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
		"$1" "${A_NSS:-n/a}" "${A_WIDTH:-n/a}" "${A_MCS:-n/a}" \
		"${A_SIGNAL:-n/a}" "${A_SECONDS:-n/a}" "${A_GBIT:-n/a}" \
		"${A_TX_MBIT:-n/a}" "${A_RX_MBIT:-n/a}" "${A_RETRIES:-n/a}" \
		"${A_PCIE0:-n/a}" "${A_TOKEN:-n/a}" "${A_TOKEN_MAX:-n/a}" \
		"${A_CPU:-n/a}" "${A_MEM:-n/a}" "${A_THERMAL:-n/a}" "${A_STATUS:-n/a}"
}

print_results_header() {
	if [ "$HEADER_PRINTED" = 0 ]; then
		say "$(printf 'arm\tnss\twidth_mhz\tmcs\tsignal_dbm\tseconds\tgbit_s\ttx_mbit\trx_mbit\tretries\tpcie0_irq_delta\tnpu_token\tnpu_token_max\tcpu_busy_pct\tmem_avail_kb\tthermal_c\tstatus')"
		HEADER_PRINTED=1
	fi
}

# $1 = exit status, $2 = reason
reject_run() {
	VERDICT="rejected"
	printf 'VERDICT: %s\n' "$VERDICT" >"$OUT/verdict.txt"
	printf 'reason: %s\n' "$2" >>"$OUT/verdict.txt"
	say "VERDICT: rejected ($2)"
	exit "$1"
}

RC=0
measure_arm AP-STA || RC=$?
AP_ROW=$(arm_row 'AP->STA')
printf '%s\n' "$AP_ROW" >>"$OUT/result.tsv"
if [ "$RC" -ne 0 ]; then
	print_results_header
	say "$AP_ROW"
	if [ "$RC" -eq 1 ]; then
		reject_run 1 "AP->STA source/setup failure; evidence kept in $OUT"
	fi
	reject_run 3 "AP->STA arm was refused or invalid; see $OUT/result.tsv"
fi

say "  settle: 2s between arms"
sleep 2

RC=0
measure_arm STA-AP || RC=$?
STA_ROW=$(arm_row 'STA->AP')
printf '%s\n' "$STA_ROW" >>"$OUT/result.tsv"
print_results_header
say "$AP_ROW"
say "$STA_ROW"
if [ "$RC" -ne 0 ]; then
	if [ "$RC" -eq 1 ]; then
		reject_run 1 "STA->AP source/setup failure; evidence kept in $OUT"
	fi
	reject_run 3 "STA->AP arm was refused or invalid; see $OUT/result.tsv"
fi

# Read the two measured Gbit/s values back from the tab-separated rows.
_ap_g=$(printf '%s' "$AP_ROW" | cut -f7)
_sta_g=$(printf '%s' "$STA_ROW" | cut -f7)
_min=$(awk -v a="$_ap_g" -v b="$_sta_g" 'BEGIN { m = (a + 0 < b + 0) ? a : b; printf "%.3f", m }')
if awk -v m="$_min" -v t="$T_TARGET" 'BEGIN { exit !(m + 0 >= t + 0) }'; then
	_target_met=yes
else
	_target_met=no
fi

# SoC-side evidence from both arms.
_evidence=
_ap_cpu=$(printf '%s' "$AP_ROW" | cut -f14)
_sta_cpu=$(printf '%s' "$STA_ROW" | cut -f14)
_ap_th=$(printf '%s' "$AP_ROW" | cut -f16)
_sta_th=$(printf '%s' "$STA_ROW" | cut -f16)
_ap_mem=$(printf '%s' "$AP_ROW" | cut -f15)
_sta_mem=$(printf '%s' "$STA_ROW" | cut -f15)
_ap_tok=$(printf '%s' "$AP_ROW" | cut -f12)
_sta_tok=$(printf '%s' "$STA_ROW" | cut -f12)
_ap_tok_max=$(printf '%s' "$AP_ROW" | cut -f13)
_sta_tok_max=$(printf '%s' "$STA_ROW" | cut -f13)
_ap_irq=$(printf '%s' "$AP_ROW" | cut -f11)
_sta_irq=$(printf '%s' "$STA_ROW" | cut -f11)
_ap_irq_sec=$(printf '%s' "$AP_ROW" | cut -f6)
_sta_irq_sec=$(printf '%s' "$STA_ROW" | cut -f6)

if awk -v a="$_ap_cpu" -v b="$_sta_cpu" -v t="$CPU_THRESHOLD" 'BEGIN { exit !((a == "n/a" || a + 0 < t) && (b == "n/a" || b + 0 < t)) }'; then
	:
else
	_evidence="$_evidence CPU busy >= ${CPU_THRESHOLD}%"
fi
if awk -v a="$_ap_th" -v b="$_sta_th" -v t="$THERMAL_THRESHOLD" 'BEGIN { exit !((a == "n/a" || a + 0 < t) && (b == "n/a" || b + 0 < t)) }'; then
	:
else
	_evidence="$_evidence thermal >= ${THERMAL_THRESHOLD}C"
fi
if awk -v a="$_ap_mem" -v b="$_sta_mem" -v t="$MEM_THRESHOLD_KB" 'BEGIN { exit !((a == "n/a" || a + 0 > t) && (b == "n/a" || b + 0 > t)) }'; then
	:
else
	_evidence="$_evidence MemAvailable <= ${MEM_THRESHOLD_KB}kB"
fi
if awk -v a="$_ap_tok" -v am="$_ap_tok_max" -v b="$_sta_tok" -v bm="$_sta_tok_max" -v t="$NPU_THRESHOLD" 'BEGIN {
	ap = (am != "n/a" && am + 0 > 0) ? 100 * a / am : 0
	sta = (bm != "n/a" && bm + 0 > 0) ? 100 * b / bm : 0
	exit !(ap < t && sta < t)
}'; then
	:
else
	_evidence="$_evidence NPU token >= ${NPU_THRESHOLD}%"
fi
if [ "$PCIE_IRQ_RATE" -gt 0 ]; then
	_ap_irq_rate=$(awk -v i="$_ap_irq" -v s="$_ap_irq_sec" 'BEGIN { if (s + 0 > 0 && i != "n/a") printf "%.0f", i / s; else print 0 }')
	_sta_irq_rate=$(awk -v i="$_sta_irq" -v s="$_sta_irq_sec" 'BEGIN { if (s + 0 > 0 && i != "n/a") printf "%.0f", i / s; else print 0 }')
	if [ "$_ap_irq_rate" -ge "$PCIE_IRQ_RATE" ] 2>/dev/null || [ "$_sta_irq_rate" -ge "$PCIE_IRQ_RATE" ] 2>/dev/null; then
		_evidence="$_evidence PCIe0 IRQ/s >= $PCIE_IRQ_RATE"
	fi
fi

_evidence_text="AP->STA $_ap_g Gbit/s, STA->AP $_sta_g Gbit/s, target $T_TARGET; CPU ${_ap_cpu}/${_sta_cpu}%, thermal ${_ap_th}/${_sta_th}C, NPU ${_ap_tok}/${_ap_tok_max} and ${_sta_tok}/${_sta_tok_max}, MemAvailable ${_ap_mem}/${_sta_mem}kB"
if [ "$_target_met" = yes ]; then
	VERDICT="radio-reachable"
	printf 'VERDICT: %s\n' "$VERDICT" >"$OUT/verdict.txt"
	printf 'reachability: radio-reachable=yes SoC-reachable=no\n' >>"$OUT/verdict.txt"
	printf 'evidence: %s\n' "$_evidence_text" >>"$OUT/verdict.txt"
	say "VERDICT: radio-reachable (both arms reached the $T_TARGET Gbit/s 4SS ceiling target)"
	say "reachability: radio-reachable=yes SoC-reachable=no"
elif [ -n "$_evidence" ]; then
	VERDICT="SoC-reachable"
	printf 'VERDICT: %s\n' "$VERDICT" >"$OUT/verdict.txt"
	printf 'reachability: radio-reachable=no SoC-reachable=yes\n' >>"$OUT/verdict.txt"
	printf 'evidence: %s; SoC signals:%s\n' "$_evidence_text" "$_evidence" >>"$OUT/verdict.txt"
	say "VERDICT: SoC-reachable (missed $T_TARGET Gbit/s with SoC-side saturation:$_evidence)"
	say "reachability: radio-reachable=no SoC-reachable=yes"
else
	VERDICT="inconclusive"
	printf 'VERDICT: %s\n' "$VERDICT" >"$OUT/verdict.txt"
	printf 'reachability: radio-reachable=no SoC-reachable=no\n' >>"$OUT/verdict.txt"
	printf 'evidence: %s; no SoC threshold crossed\n' "$_evidence_text" >>"$OUT/verdict.txt"
	say "VERDICT: inconclusive (missed $T_TARGET Gbit/s without SoC saturation; check air, client, regulatory and rate control)"
	say "reachability: radio-reachable=no SoC-reachable=no"
fi
say "evidence: $_evidence_text"
exit 0
