#!/bin/sh
#
# ab-80-160.sh - same-client, same-source, same-process-count 5 GHz 80/160 A/B.
#
# Problem this solves: the two 5 GHz width results on record were not
# comparable.  One 160 MHz arm ran at NSS1 while its 80 MHz arm ran at NSS2,
# and one 6-parallel-stream 160 MHz arm had no 80 MHz arm at the same process
# count.  The radio width cannot be attributed unless the client, the traffic
# source, the process count and the window are the same in both arms.
#
# Protocol (fixed so runs stay comparable):
#   1. Read and save wireless.radio1.channel/htmode, /etc/config/wireless and
#      the live iw state.  Real runs need --run; without it this is a dry run.
#   2. Arm 80:  uci set radio1.channel=<ch80>; radio1.htmode=<...>80; commit;
#      wifi reload; wait for the AP and the same client; run PROCS copies of
#      SOURCE, wait through a short warm-up for the client's TX rate to reach
#      that width, then measure the WINDOW.  The warm-up traffic is not
#      included in the TX-byte delta.
#   3. Arm 160: the same on channel 36 with the 160 MHz htmode.
#   4. Restore the saved UCI (file and uncommitted delta) and wifi reload in a
#      trap.  The restored file is md5-checked and the live state is read back.
#   5. Emit one table row per arm plus a VERDICT.  An arm is rejected when its
#      station TX rate is not at the expected width or has no NSS.  The pair is
#      rejected when the two arms have a different NSS or a different signal
#      class (medians more than SIGNAL_TOL dB apart).
#
# The traffic source always runs on the AP (the A-path local source) and is
# started identically for both arms.  SOURCE is a shell command string; the
# harness exports IFACE, CLIENT, CLIENT_IP, WINDOW, WARMUP, SOURCE_SECS, PROCS,
# ARM and OUT to it.  The command should keep sending for at least SOURCE_SECS
# (WARMUP + WINDOW + 3); the harness kills it after the measured window.
# Without --source the default is one
# "iperf3 -c $CLIENT_IP -t $SOURCE_SECS" per process, which needs iperf3
# installed and an iperf3 server on the client.
#
# Config safety:
#   * --dry-run performs every read-only prerequisite check and exits 0
#     without writing UCI, reloading Wi-Fi, starting a stream or creating the
#     output directory.
#   * a real run needs --run, backs up /etc/config/wireless and the uncommitted
#     /tmp/.uci/wireless delta, and restores both from the EXIT/INT/TERM/HUP
#     trap.  No module, firmware, reboot or persistent config is needed.
#   * wifi reload bounces every radio briefly; manage the board over a wired
#     uplink, not over the Wi-Fi being tested, and do not run this while
#     another experiment is using the same board.
#
# The Gbit/s column is the station TX-byte delta over the window, as the task
# asks (tx_bytes * 8 / seconds).  mac80211 counts L2 bytes and retransmits,
# not airtime; a raw-injection source can make the number exceed the reported
# PHY rate.  Read the retries column and the source's own log before treating
# it as an air-throughput result.
#
# Exit status:
#   0  both arms valid and comparable, or a clean SKIP (no client associated)
#   1  setup/run/rollback failure (the trap has still tried to restore UCI)
#   2  invalid arguments
#   3  measured, but an arm or the pair was rejected
#
# POSIX sh only (busybox ash).  Tested with "sh -n", --help and --dry-run.
#
# Examples:
#   # inspect only; never changes anything, exits 0 even on a host without uci
#   ./scripts/wireless/ab-80-160.sh --dry-run --client f8:fe:5e:a1:6f:a8
#
#   # real A/B: 4 parallel local sources, 10 s window, same primary channel
#   ./scripts/wireless/ab-80-160.sh --run --client f8:fe:5e:a1:6f:a8 \
#       --ch80 36 --procs 4 --window 10 \
#       --source '/tmp/ringblast "$IFACE" "$CLIENT" "$CLIENT_IP" "$SOURCE_SECS"'
#
#   # same protocol with iperf3 (needs "iperf3 -s" on the client)
#   ./scripts/wireless/ab-80-160.sh --run --client f8:fe:5e:a1:6f:a8 \
#       --client-ip 192.168.1.236 --procs 4 --window 10

set -u
set -f

PROG=${0##*/}

# Defaults; every value can also be set from the environment.
CLIENT=${CLIENT:-}
CLIENT_IP=${CLIENT_IP:-}
IFACE=${IFACE:-}
CH80=${CH80:-auto}
CH160=${CH160:-36}
HTMODE80=${HTMODE80:-}
HTMODE160=${HTMODE160:-}
PROCS=${PROCS:-4}
WINDOW=${WINDOW:-10}
SOURCE=${SOURCE:-}
OUT=${OUT:-}
ASSOC_TIMEOUT=${ASSOC_TIMEOUT:-180}
SETTLE=${SETTLE:-5}
WARMUP=${WARMUP:-10}
SIGNAL_TOL=${SIGNAL_TOL:-5}
DRY_RUN=${DRY_RUN:-0}
RUN=${RUN:-0}

# Constants that describe the board, not a preference.
WIRELESS_CONFIG=/etc/config/wireless
UCI_DELTA=/tmp/.uci/wireless

usage() {
	cat <<'EOF'
Usage: ab-80-160.sh [options]

Same-client, same-source, same-process-count 5 GHz 80 MHz vs 160 MHz A/B
harness.  Both arms use one client MAC, one SOURCE command, PROCS copies and
one WINDOW; the only intended difference is the width.  The 160 MHz arm is on
channel 36.  The 80 MHz arm defaults to the current channel when that channel
supports 80 MHz, otherwise channel 36; pass --ch80 36 for a width-only
comparison on the same primary channel.

A real run changes wireless.radio1.channel/htmode through UCI, reloads Wi-Fi,
runs the traffic, and restores the original UCI from a trap.  Without --run
the script only performs read-only checks and prints this plan (--dry-run is
an explicit alias).  Run the board over a wired uplink: wifi reload bounces
every radio.

Required for a real run:
  --client MAC          the one 5 GHz client compared in both arms

Traffic source (one of):
  --source 'COMMAND'    shell command run PROCS times per arm; WINDOW,
                        WARMUP, SOURCE_SECS (WARMUP+WINDOW+3), PROCS, IFACE,
                        CLIENT, CLIENT_IP, ARM and OUT are exported to it
  --client-ip IP        if --source is unset, one default
                        "iperf3 -c IP -t SOURCE_SECS" process per --procs
                        (iperf3 must be installed; the client must run
                        "iperf3 -s").  The IP is also auto-resolved from
                        /proc/net/arp by --client.

Optional:
  --iface NAME          the 5 GHz AP interface; default: the 5 GHz AP that
                        has --client associated, else the first 5 GHz AP
  --ch80 CH|auto        channel or auto (default auto): current channel if it is an
                        80 MHz-capable 5 GHz channel, else 36
  --ch160 CH            channel (default 36; the only legal CN 160 MHz block is
                        the 36-64 one, so leave it at 36)
  --htmode80 MODE       e.g. EHT80 (default: the current PHY prefix + 80)
  --htmode160 MODE      e.g. EHT160 (default: the current PHY prefix + 160)
  --procs N             parallel source processes (default 4)
  --window SEC          measurement window (default 10)
  --out DIR             output directory (default /tmp/ab-80-160-<timestamp>)
  --assoc-timeout SEC   AP/client readiness timeout (default 180; 160 MHz on
                        ch36 spans DFS, so a fresh CAC can take 60-120 s)
  --settle SEC          quiet time after association before the source is
                        started (default 5)
  --warmup SEC          traffic warm-up before the measured window; the window
                        starts only after the station's TX rate reaches the
                        arm width (default 10, then the window runs anyway)
  --signal-tol DB       allowed signal-class difference between arms
                        (default 5 dB)
  --run                 really change the radio; without it a dry run
  --dry-run             explicit read-only plan; exits 0
  -h, --help            this text

Output:
  arm, channel, width, NSS, signal, TX bytes, seconds, Gbit/s, retries and a
  status per arm, then a VERDICT.  The requested table columns are the first
  six plus TX bytes/seconds/Gbit/s/retries.  Width/NSS/signal come from
  "iw dev IFACE station dump" (TX rate and signal average); TX bytes and
  TX retries are deltas over the window.  Gbit/s = tx_bytes * 8 / seconds,
  which is an L2/stack-side number and can exceed the PHY rate with a
  raw-injection source; check retries and the source's own log.  The output
  directory also keeps
  wireless.bak, iw-before.txt, iw-after.txt, arm-<n>.samples.tsv,
  arm-<n>-source-*.log, result.tsv, rollback.txt and run.log.

Rejection rules:
  * an arm is rejected if the station TX rate is not at the arm's width, NSS is
    missing or changes during the window, the station is not associated before
    or after the window, or a source process died before the window ended;
  * the pair is rejected if the two arms show a different NSS, a different
    width, or signal medians more than --signal-tol dB apart;
  * a rejected run still prints both rows and restores the radio.

Exit status:
  0 comparable, or clean SKIP (no client associated; nothing was changed)
  1 setup/run/rollback failure
  2 invalid arguments
  3 measured but rejected
EOF
}

usage_error() {
	printf '%s: %s\n' "$PROG" "$1" >&2
	printf 'Try "%s --help" for usage.\n' "$PROG" >&2
	exit 2
}

die() {
	warn "$1"
	exit 1
}

# Each arm commits a new channel/width and bounces every radio with "wifi
# reload", so the A/B holds netwatchdog for the whole run.  The library fails
# closed: nw_guard_take returns nonzero when netwatchdog is missing or the hold
# cannot be taken, and the run is refused in that case.  This script owns its
# own EXIT/INT/TERM/HUP trap, so the guard installs none and its cleanup is
# called from the script's own cleanup instead.
NETWATCHDOG_GUARD=$(dirname "$0")/../lib/netwatchdog-guard.sh
[ -r "$NETWATCHDOG_GUARD" ] ||
	die "shared library not found: $NETWATCHDOG_GUARD"
# shellcheck source=../lib/netwatchdog-guard.sh
. "$NETWATCHDOG_GUARD"

warn() {
	printf '%s: %s\n' "$PROG" "$1" >&2
}

say() {
	printf '%s\n' "$*"
	if [ -n "${LOG:-}" ]; then
		printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)" "$*" >>"$LOG" 2>/dev/null
	fi
}

log_cmd() {
	if [ -n "${LOG:-}" ]; then
		printf '%s + %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)" "$1" >>"$LOG" 2>/dev/null
	fi
}

have() {
	command -v "$1" >/dev/null 2>&1
}

is_uint() {
	case $1 in
	''|*[!0-9]*) return 1 ;;
	esac
	return 0
}

uptime_float() {
	cut -d' ' -f1 /proc/uptime 2>/dev/null
}

uptime_int() {
	uptime_float | cut -d. -f1
}

# Trailing width digits of a htmode, e.g. EHT160 -> 160, HE80 -> 80.
width_of_htmode() {
	_h=$1
	_w=${_h##*[!0-9]}
	printf '%s' "$_w"
}

# 5 GHz primary channels that can carry an 80 MHz PPDU.  These are the four
# 20 MHz channels of each 80 MHz block; 80 MHz centres are 42/58/106/122/138/155.
is_80mhz_channel() {
	case $1 in
	36|40|44|48|52|56|60|64|100|104|108|112|116|120|124|128|132|136|140|144|149|153|157|161)
		return 0
		;;
	esac
	return 1
}

# 5 GHz 160 MHz blocks are centred on 50 (36-64) and 114 (100-128).
is_160mhz_channel() {
	case $1 in
	36|100) return 0 ;;
	esac
	return 1
}

norm_mac() {
	printf '%s' "$1" | tr 'A-F' 'a-f' | tr '-' ':'
}

valid_mac() {
	case $1 in
	[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f])
		return 0
		;;
	esac
	return 1
}

uci_get() {
	uci -q get "$1" 2>/dev/null
}

iface_info() {
	iw dev "$IFACE" info 2>/dev/null
}

iface_channel() {
	iface_info | awk '/channel/ { print $2; exit }'
}

iface_width() {
	iface_info | awk '
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

iface_freq() {
	iface_info | awk '
		/channel/ {
			if (match($0, /\([0-9]+ MHz\)/)) {
				f = substr($0, RSTART, RLENGTH)
				gsub(/[^0-9]/, "", f)
				print f
				exit
			}
		}'
}

station_has() {
	iw dev "$1" station dump 2>/dev/null | grep -q "^Station $2 "
}

# Find the 5 GHz AP.  Prefer the interface that has --client associated; fall
# back to the first 5 GHz AP so --dry-run can still report the topology.
detect_iface() {
	_first=
	_pref=
	for _d in $(iw dev 2>/dev/null | awk '$1 == "Interface" { print $2 }'); do
		_info=$(iw dev "$_d" info 2>/dev/null)
		_type=$(printf '%s\n' "$_info" | awk '$1 == "type" { print $2; exit }')
		[ "$_type" = AP ] || continue
		_f=$(printf '%s\n' "$_info" | awk '
			/channel/ {
				if (match($0, /\([0-9]+ MHz\)/)) {
					f = substr($0, RSTART, RLENGTH)
					gsub(/[^0-9]/, "", f)
					print f
					exit
				}
			}')
		[ -n "$_f" ] || continue
		if [ "$_f" -ge 5000 ] 2>/dev/null && [ "$_f" -le 5925 ] 2>/dev/null; then
			[ -z "$_first" ] && _first=$_d
			if [ -n "$CLIENT" ] && station_has "$_d" "$CLIENT"; then
				_pref=$_d
				break
			fi
		fi
	done
	if [ -n "$_pref" ]; then
		printf '%s' "$_pref"
		return 0
	fi
	if [ -n "$_first" ]; then
		printf '%s' "$_first"
		return 0
	fi
	return 1
}

# One station sample as "tx_bytes|tx_retries|signal|nss|width|associated".
# Empty fields mean the field or the station is missing.  signal prefers
# "signal avg" because it is the smoothed value iw itself prints for the link.
sample_station() {
	iw dev "$IFACE" station dump 2>/dev/null | awk -v mac="$CLIENT" '
		/^Station / { on = ($2 == mac); next }
		on && $1 == "associated:" { assoc = $2 }
		on && $1 == "signal:" { sig = $2 }
		on && $1 == "signal" && $2 == "avg:" { sig = $3 }
		on && $1 == "tx" && $2 == "bytes:" { txb = $3 }
		on && $1 == "tx" && $2 == "retries:" { retr = $3 }
		on && $1 == "tx" && $2 == "bitrate:" {
			line = $0
			if (match(line, /[0-9]+MHz/)) {
				w = substr(line, RSTART, RLENGTH)
				sub(/MHz/, "", w)
			}
			if (match(line, /NSS [0-9]+/)) {
				n = substr(line, RSTART, RLENGTH)
				sub(/NSS /, "", n)
			}
		}
		END { printf "%s|%s|%s|%s|%s|%s\n", txb, retr, sig, n, w, assoc }
	'
}

sample_field() {
	printf '%s\n' "$1" | cut -d'|' -f"$2"
}

# Median of the non-empty signal column of a samples file.
median_signal() {
	awk -F'|' '
		$3 != "" { v[++n] = $3 }
		END {
			if (n == 0) exit
			for (i = 2; i <= n; i++) {
				x = v[i]
				j = i - 1
				while (j > 0 && v[j] > x) {
					v[j + 1] = v[j]
					j--
				}
				v[j + 1] = x
			}
			if (n % 2)
				m = v[(n + 1) / 2]
			else
				m = (v[n / 2] + v[n / 2 + 1]) / 2
			printf "%.0f", m
		}
	' "$1"
}

# Empty string when every sample is usable; otherwise the first reason.
validate_samples() {
	awk -F'|' -v want="$2" '
		{
			rows++
			if (NR == 1) {
				fassoc = $6; fwidth = $5; fnss = $4
			}
			lassoc = $6; lwidth = $5; lnss = $4
			if ($6 == "yes") {
				if ($5 == "") missing_width++
				else if ($5 != want) badwidth[$5] = 1
				if ($4 == "") missing_nss++
				else allnss[$4] = 1
				if ($3 != "") sigs++
			}
		}
		END {
			reason = ""
			if (rows < 2)
				reason = "no station samples"
			else if (fassoc != "yes")
				reason = "station not associated at window start"
			else if (fwidth != want)
				reason = "width " fwidth " MHz at window start, want " want
			else if (fnss == "")
				reason = "no NSS at window start"
			else if (lassoc != "yes")
				reason = "station not associated after the window"
			else if (lwidth != want)
				reason = "width " lwidth " MHz after the window, want " want
			else if (lnss == "")
				reason = "no NSS after the window"
			else if (missing_width > 0)
				reason = missing_width " sample(s) had no TX width"
			else if (missing_nss > 0)
				reason = missing_nss " sample(s) had no NSS"
			else if (sigs == 0)
				reason = "no signal samples"
			else {
				for (w in badwidth) {
					reason = "width changed to " w " MHz during the window"
					break
				}
				if (reason == "") {
					n = 0
					for (x in allnss) {
						n++
						if (n > 1) break
					}
					if (n > 1)
						reason = "NSS changed during the window"
				}
			}
			print reason
		}
	' "$1"
}

# A source process that finished (or died) is no longer running.  /proc/<pid>
# catches both a reaped child and a zombie, which "kill -0" would both report
# differently depending on whether the shell has reaped it yet.
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
	SOURCES_PIDS=
	_i=1
	while [ "$_i" -le "$PROCS" ]; do
		IFACE="$IFACE" CLIENT="$CLIENT" CLIENT_IP="$CLIENT_IP" \
		WINDOW="$WINDOW" WARMUP="$WARMUP" SOURCE_SECS="$SOURCE_SECS" PROCS="$PROCS" \
		ARM="$1" OUT="$OUT" \
		sh -c "$SOURCE" >"$OUT/arm-$1-source-$_i.log" 2>&1 &
		SOURCES_PIDS="$SOURCES_PIDS $!"
		_i=$((_i + 1))
	done
}

kill_sources() {
	[ -n "${SOURCES_PIDS:-}" ] || return 0
	for _p in $SOURCES_PIDS; do
		kill -0 "$_p" 2>/dev/null && kill "$_p" 2>/dev/null
	done
	for _p in $SOURCES_PIDS; do
		wait "$_p" 2>/dev/null
	done
	SOURCES_PIDS=
}

# Wait for the AP itself to be up on the wanted channel/width.  This is all a
# rollback needs to prove: the client reconnects on its own.
WAIT_REASON=
wait_ap() {
	_want_ch=$1
	_want_w=$2
	_start=$(uptime_int)
	_last_note=-1
	WAIT_REASON=
	while :; do
		_now=$(uptime_int)
		_el=$((_now - _start))
		_ch=$(iface_channel)
		_w=$(iface_width)
		if [ "$_ch" = "$_want_ch" ] && [ "$_w" = "$_want_w" ]; then
			say "  AP ready: channel $_ch, width ${_w} MHz (${_el}s)"
			return 0
		fi
		if [ "$_el" -ge "$ASSOC_TIMEOUT" ]; then
			WAIT_REASON="AP ch=${_ch:-?} width=${_w:-?} MHz after ${_el}s, want channel $_want_ch width ${_want_w} MHz"
			return 1
		fi
		if [ $((_el % 15)) -eq 0 ] && [ "$_el" != "$_last_note" ]; then
			_last_note=$_el
			say "  waiting ${_el}s: AP ch=${_ch:-?} width=${_w:-?} MHz"
		fi
		sleep 2
	done
}

# Wait for the AP and the same client to be associated.  The client's TX
# width is deliberately not required here: right after association it can
# still report an old or legacy rate.  The caller starts the source first and
# only then waits for the rate to reach the arm width (the warm-up).
wait_ready() {
	_want_ch=$1
	_want_w=$2
	_start=$(uptime_int)
	_ap_ok=0
	_last_note=-1
	WAIT_REASON=
	while :; do
		_now=$(uptime_int)
		_el=$((_now - _start))
		_probe=$(sample_station)
		_assoc=$(sample_field "$_probe" 6)
		_swidth=$(sample_field "$_probe" 5)
		_snss=$(sample_field "$_probe" 4)
		_ssig=$(sample_field "$_probe" 3)
		_ch=$(iface_channel)
		_w=$(iface_width)
		if [ "$_ch" = "$_want_ch" ] && [ "$_w" = "$_want_w" ]; then
			if [ "$_ap_ok" = 0 ]; then
				_ap_ok=1
				say "  AP ready: channel $_ch, width ${_w} MHz (${_el}s)"
			fi
		fi
		if [ "$_ap_ok" = 1 ] && [ "$_assoc" = yes ]; then
			say "  STA $CLIENT associated (${_el}s)"
			return 0
		fi
		if [ "$_el" -ge "$ASSOC_TIMEOUT" ]; then
			WAIT_REASON="AP ch=${_ch:-?} width=${_w:-?} MHz, station assoc=${_assoc:-no} width=${_swidth:-?} MHz after ${_el}s"
			return 1
		fi
		if [ $((_el % 15)) -eq 0 ] && [ "$_el" != "$_last_note" ]; then
			_last_note=$_el
			say "  waiting ${_el}s: AP ch=${_ch:-?} width=${_w:-?} MHz, station assoc=${_assoc:-no} width=${_swidth:-?} MHz"
		fi
		sleep 2
	done
}

# Apply one arm and fill the ARM_* globals.  ARM_OK=1 means the sample set is
# valid for this width; the pair verdict is computed by the caller.
ARM_NAME=
ARM_CH=
ARM_WIDTH=
ARM_NSS=
ARM_SIG=
ARM_TXB=
ARM_SECS=
ARM_GBIT=
ARM_RETR=
ARM_RAW_STATUS=
ARM_STATUS=
ARM_OK=0

run_arm() {
	_arm=$1
	_arm_ch=$2
	_arm_hm=$3
	_arm_w=$4
	_arm_samples="$OUT/arm-$_arm.samples.tsv"

	ARM_NAME=$_arm
	ARM_CH=$_arm_ch
	ARM_WIDTH=
	ARM_NSS=
	ARM_SIG=
	ARM_TXB=
	ARM_SECS=
	ARM_GBIT=
	ARM_RETR=
	ARM_RAW_STATUS=
	ARM_STATUS=
	ARM_OK=0

	say "arm $_arm: channel=$_arm_ch htmode=$_arm_hm (expected ${_arm_w} MHz)"
	log_cmd "uci set wireless.radio1.channel=$_arm_ch; uci set wireless.radio1.htmode=$_arm_hm; uci commit wireless; wifi reload"

	if ! uci set wireless.radio1.channel="$_arm_ch" >>"$LOG" 2>&1; then
		ARM_RAW_STATUS="uci set channel failed"
		ARM_STATUS="reject: $ARM_RAW_STATUS"
		return 1
	fi
	if ! uci set wireless.radio1.htmode="$_arm_hm" >>"$LOG" 2>&1; then
		ARM_RAW_STATUS="uci set htmode failed"
		ARM_STATUS="reject: $ARM_RAW_STATUS"
		return 1
	fi
	if ! uci commit wireless >>"$LOG" 2>&1; then
		ARM_RAW_STATUS="uci commit wireless failed"
		ARM_STATUS="reject: $ARM_RAW_STATUS"
		return 1
	fi
	log_cmd "wifi reload"
	if ! wifi reload >>"$LOG" 2>&1; then
		ARM_RAW_STATUS="wifi reload failed"
		ARM_STATUS="reject: $ARM_RAW_STATUS"
		return 1
	fi

	if ! wait_ready "$_arm_ch" "$_arm_w"; then
		ARM_RAW_STATUS="$WAIT_REASON"
		ARM_STATUS="reject: $ARM_RAW_STATUS"
		return 1
	fi
	if [ "$SETTLE" -gt 0 ]; then
		say "  settle ${SETTLE}s"
		sleep "$SETTLE"
	fi

	# Start the source before the window and use it as a warm-up: the AP's
	# reported TX rate can still be an old/legacy rate right after
	# association, and with no traffic the rate controller may not update it.
	# The window only starts once the station's TX rate is at the arm width;
	# if it never gets there, the window still runs and the validation
	# rejects the arm with the measured width.
	start_sources "$_arm"
	_warm_start=$(uptime_int)
	_warm_ok=0
	_warm_el=0
	while :; do
		_probe=$(sample_station)
		_now=$(uptime_int)
		_warm_el=$((_now - _warm_start))
		if [ "$(sample_field "$_probe" 6)" = yes ] &&
			[ "$(sample_field "$_probe" 5)" = "$_arm_w" ] &&
			[ -n "$(sample_field "$_probe" 4)" ]; then
			_warm_ok=1
			break
		fi
		[ "$_warm_el" -ge "$WARMUP" ] && break
		sleep 1
	done
	if [ "$_warm_ok" = 1 ]; then
		say "  warm-up: TX rate at ${_arm_w} MHz, NSS $(sample_field "$_probe" 4) (${_warm_el}s)"
	else
		say "  warm-up did not reach ${_arm_w} MHz in ${WARMUP}s; the window will record the actual width"
	fi

	iw dev "$IFACE" station dump >"$OUT/arm-$_arm.station-before.txt" 2>&1
	_before=$(sample_station)
	printf '%s\n' "$_before" >"$_arm_samples"

	_t0=$(uptime_float)
	_deadline=$(awk -v a="$_t0" -v w="$WINDOW" 'BEGIN { printf "%.3f", a + w }')
	while :; do
		_now=$(uptime_float)
		_done=$(awk -v n="$_now" -v d="$_deadline" 'BEGIN { print (n >= d) ? 1 : 0 }')
		[ "$_done" = 1 ] && break
		sleep 1
		printf '%s\n' "$(sample_station)" >>"$_arm_samples"
	done
	_t1=$(uptime_float)
	_after=$(sample_station)
	printf '%s\n' "$_after" >>"$_arm_samples"
	_alive=$(alive_sources)
	kill_sources
	iw dev "$IFACE" station dump >"$OUT/arm-$_arm.station-after.txt" 2>&1

	ARM_TXB=$(awk -F'|' 'NR == 1 { b = $1 } { a = $1 } END { if (a == "" || b == "") print ""; else printf "%.0f", a - b }' "$_arm_samples")
	ARM_RETR=$(awk -F'|' 'NR == 1 { b = $2 } { a = $2 } END { if (a == "" || b == "") print ""; else printf "%.0f", a - b }' "$_arm_samples")
	ARM_NSS=$(awk -F'|' 'END { print $4 }' "$_arm_samples")
	ARM_WIDTH=$(awk -F'|' 'END { print $5 }' "$_arm_samples")
	ARM_SIG=$(median_signal "$_arm_samples")
	ARM_SECS=$(awk -v a="$_t0" -v b="$_t1" 'BEGIN { if (b > a) printf "%.2f", b - a; else print "" }')
	if [ -n "$ARM_TXB" ] && [ -n "$ARM_SECS" ]; then
		ARM_GBIT=$(awk -v b="$ARM_TXB" -v s="$ARM_SECS" \
			'BEGIN { if (s > 0) printf "%.3f", b * 8 / s / 1000000000; else print "" }')
	fi

	_reason=$(validate_samples "$_arm_samples" "$_arm_w")
	if [ "$_alive" -lt "$PROCS" ]; then
		_reason="source exited early (${_alive}/${PROCS} alive at window end)"
	fi
	if [ -n "$_reason" ]; then
		ARM_RAW_STATUS=$_reason
		ARM_STATUS="reject: $_reason"
		ARM_OK=0
		return 1
	fi
	ARM_OK=1
	ARM_STATUS=ok
	return 0
}

# Restore the saved UCI file and delta, reload, and read the result back.
RESTORED=0
ROLLBACK_OK=0
restore_config() {
	[ "$RESTORED" = 1 ] && return 0
	RESTORED=1
	kill_sources

	_ok=1
	say "[rollback] restore wireless.radio1.channel=$ORIG_CHANNEL htmode=$ORIG_HTMODE"
	log_cmd "cp $OUT/wireless.bak $WIRELESS_CONFIG; restore uci delta; wifi reload"

	rm -f "$UCI_DELTA" 2>/dev/null
	if cp -p "$OUT/wireless.bak" "$WIRELESS_CONFIG" 2>>"$LOG"; then
		:
	else
		_ok=0
	fi
	if [ "$HAD_DELTA" = 1 ] && [ -f "$OUT/wireless.uci-delta.bak" ]; then
		mkdir -p /tmp/.uci 2>/dev/null
		if cp -p "$OUT/wireless.uci-delta.bak" "$UCI_DELTA" 2>>"$LOG"; then
			:
		else
			_ok=0
		fi
	fi

	_ch=$(uci_get wireless.radio1.channel)
	_hm=$(uci_get wireless.radio1.htmode)
	_want_w=$(width_of_htmode "$ORIG_HTMODE")
	if wifi reload >>"$LOG" 2>&1; then
		:
	else
		_ok=0
	fi
	if wait_ap "$ORIG_CHANNEL" "$_want_w"; then
		_ap=up
	else
		_ap="not-up: $WAIT_REASON"
	fi
	_md5=$(md5sum "$WIRELESS_CONFIG" 2>/dev/null | awk '{print $1}')
	{
		iw dev
		iw dev "$IFACE" info
		iw dev "$IFACE" station dump
		iw reg get
	} >"$OUT/iw-after.txt" 2>&1

	if [ "$_md5" = "$MD5_BEFORE" ] && [ "$_ch" = "$ORIG_CHANNEL" ] &&
		[ "$_hm" = "$ORIG_HTMODE" ] && [ "$_ap" = up ]; then
		ROLLBACK_OK=1
	else
		ROLLBACK_OK=0
	fi
	if [ "$_ok" != 1 ]; then
		ROLLBACK_OK=0
	fi

	{
		printf 'rollback_at=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)"
		printf 'config=%s\n' "$WIRELESS_CONFIG"
		printf 'md5_before=%s\n' "$MD5_BEFORE"
		printf 'md5_after=%s\n' "$_md5"
		printf 'channel=%s expected_channel=%s\n' "$_ch" "$ORIG_CHANNEL"
		printf 'htmode=%s expected_htmode=%s\n' "$_hm" "$ORIG_HTMODE"
		printf 'uci_delta_restored=%s\n' "$HAD_DELTA"
		printf 'ap=%s\n' "$_ap"
		printf 'result=%s\n' "$([ "$ROLLBACK_OK" = 1 ] && echo OK || echo FAILED)"
	} >"$OUT/rollback.txt" 2>/dev/null

	if [ "$ROLLBACK_OK" = 1 ]; then
		say "[rollback] md5 $_md5 (matches before), channel=$_ch htmode=$_hm, AP=$_ap"
		say "[rollback] ROLLBACK: OK"
	else
		warn "[rollback] md5 $_md5 (before $MD5_BEFORE), channel=$_ch htmode=$_hm, AP=$_ap"
		warn "[rollback] ROLLBACK: FAILED - inspect $OUT/rollback.txt and /etc/config/wireless"
	fi
	return 0
}

# Invoked from the EXIT trap below; shellcheck cannot see indirect calls.
# shellcheck disable=SC2329
cleanup() {
	_st=$?
	trap - 0 1 2 15
	trap '' 1 2 15
	kill_sources
	if [ "$RUN" = 1 ] && [ "$RESTORED" = 0 ] && [ -n "${OUT:-}" ]; then
		restore_config || true
	fi
	if [ "$RUN" = 1 ] && [ "$ROLLBACK_OK" != 1 ]; then
		_st=1
	fi
	# Release after the rollback reload, so the hold covers the restore too.
	nw_guard_cleanup
	exit "$_st"
}

print_table_header() {
	printf '%-5s %-7s %-5s %-4s %-7s %-12s %-8s %-7s %-8s %s\n' \
		arm channel width NSS signal tx_bytes seconds Gbit/s retries status
}

print_row() {
	_ch=${1:--}
	_w=${2:--}
	_nss=${3:--}
	_sig=${4:--}
	_txb=${5:--}
	_sec=${6:--}
	_gbit=${7:--}
	_retr=${8:--}
	_st=${9:-}
	printf '%-5s %-7s %-5s %-4s %-7s %-12s %-8s %-7s %-8s %s\n' \
		"$ARM_NAME" "$_ch" "$_w" "$_nss" "$_sig" "$_txb" "$_sec" "$_gbit" "$_retr" "$_st"
}

dry_run_plan() {
	printf '%s: dry run; nothing will be written, reloaded or started\n' "$PROG"
	for _c in uci iw wifi; do
		if have "$_c"; then
			printf '  %-6s %s\n' "$_c" "$(command -v "$_c")"
		else
			printf '  %-6s MISSING\n' "$_c"
		fi
	done
	if [ -n "${ORIG_CHANNEL:-}" ] || [ -n "${ORIG_HTMODE:-}" ]; then
		printf '  wireless.radio1.channel=%s htmode=%s band=%s country=%s\n' \
			"${ORIG_CHANNEL:-<unset>}" "${ORIG_HTMODE:-<unset>}" \
			"$(uci_get wireless.radio1.band)" "$(uci_get wireless.radio1.country)"
	else
		printf '  wireless.radio1.channel/htmode: <not readable>\n'
	fi
	if [ -n "${IFACE:-}" ] && have iw; then
		printf '  5 GHz AP: %s channel=%s width=%s MHz\n' \
			"$IFACE" "$(iface_channel)" "$(iface_width)"
	else
		printf '  5 GHz AP: <not found>\n'
	fi
	if [ -z "$CLIENT" ]; then
		printf '  client: <not specified; --client is required for --run>\n'
	elif [ -z "${IFACE:-}" ] || ! have iw; then
		printf '  client %s: cannot check without a 5 GHz AP interface\n' "$CLIENT"
	else
		_probe=$(sample_station)
		if [ "$(sample_field "$_probe" 6)" = yes ]; then
			printf '  client %s: associated=yes width=%s MHz NSS=%s signal=%s dBm\n' \
				"$CLIENT" "$(sample_field "$_probe" 5)" "$(sample_field "$_probe" 4)" \
				"$(sample_field "$_probe" 3)"
		else
			printf '  client %s: NOT associated on %s\n' "$CLIENT" "$IFACE"
		fi
	fi
	printf '  arm 80:  channel=%s htmode=%s expected=80 MHz\n' "$CH80" "$HTMODE80"
	printf '  arm 160: channel=%s htmode=%s expected=160 MHz\n' "$CH160" "$HTMODE160"
	if [ "$CH80" != "$CH160" ]; then
		printf '  note: the 80 and 160 arms use different primary channels; the A/B mixes width and channel\n'
	else
		printf '  note: both arms use primary channel %s; only the width changes\n' "$CH80"
	fi
	if [ -n "$SOURCE" ]; then
		printf '  source: %s%s\n' "$SOURCE" "$([ "$SOURCE_DEFAULT" = 1 ] && echo '  (default)')"
		printf '          procs=%s warmup=%ss window=%ss (source runs for %ss before it is killed)\n' \
			"$PROCS" "$WARMUP" "$WINDOW" "$SOURCE_SECS"
	else
		printf '  source: <not configured; pass --source or --client-ip with iperf3>\n'
	fi
	printf '  iw state: per-arm station dumps would be saved under %s\n' \
		"${OUT:-/tmp/ab-80-160-<timestamp>}"
	printf '  a real run needs --run; it backs up /etc/config/wireless and restores it from a trap\n'
}

# ----- options -----------------------------------------------------------

while [ $# -gt 0 ]; do
	case $1 in
	-h|--help)
		usage
		exit 0
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--run)
		RUN=1
		shift
		;;
	--client|--client-mac)
		[ $# -ge 2 ] || usage_error "$1 needs a value"
		CLIENT=$2
		shift 2
		;;
	--client-ip)
		[ $# -ge 2 ] || usage_error "$1 needs a value"
		CLIENT_IP=$2
		shift 2
		;;
	--iface)
		[ $# -ge 2 ] || usage_error "$1 needs a value"
		IFACE=$2
		shift 2
		;;
	--ch80)
		[ $# -ge 2 ] || usage_error "$1 needs a value"
		CH80=$2
		shift 2
		;;
	--ch160)
		[ $# -ge 2 ] || usage_error "$1 needs a value"
		CH160=$2
		shift 2
		;;
	--htmode80)
		[ $# -ge 2 ] || usage_error "$1 needs a value"
		HTMODE80=$2
		shift 2
		;;
	--htmode160)
		[ $# -ge 2 ] || usage_error "$1 needs a value"
		HTMODE160=$2
		shift 2
		;;
	--procs)
		[ $# -ge 2 ] || usage_error "$1 needs a value"
		PROCS=$2
		shift 2
		;;
	--window)
		[ $# -ge 2 ] || usage_error "$1 needs a value"
		WINDOW=$2
		shift 2
		;;
	--source)
		[ $# -ge 2 ] || usage_error "$1 needs a value"
		SOURCE=$2
		shift 2
		;;
	--out)
		[ $# -ge 2 ] || usage_error "$1 needs a value"
		OUT=$2
		shift 2
		;;
	--assoc-timeout)
		[ $# -ge 2 ] || usage_error "$1 needs a value"
		ASSOC_TIMEOUT=$2
		shift 2
		;;
	--settle)
		[ $# -ge 2 ] || usage_error "$1 needs a value"
		SETTLE=$2
		shift 2
		;;
	--warmup)
		[ $# -ge 2 ] || usage_error "$1 needs a value"
		WARMUP=$2
		shift 2
		;;
	--signal-tol)
		[ $# -ge 2 ] || usage_error "$1 needs a value"
		SIGNAL_TOL=$2
		shift 2
		;;
	--)
		shift
		break
		;;
	-*)
		usage_error "unknown option: $1"
		;;
	*)
		usage_error "unexpected argument: $1"
		;;
	esac
done
[ $# -eq 0 ] || usage_error "unexpected argument: $1"

[ "$RUN" = 1 ] && [ "$DRY_RUN" = 1 ] && usage_error "--run and --dry-run are mutually exclusive"
is_uint "$PROCS" || usage_error "--procs must be a positive integer"
[ "$PROCS" -ge 1 ] || usage_error "--procs must be greater than zero"
is_uint "$WINDOW" || usage_error "--window must be a positive integer"
[ "$WINDOW" -ge 2 ] || usage_error "--window must be at least 2 seconds"
is_uint "$ASSOC_TIMEOUT" || usage_error "--assoc-timeout must be an integer"
[ "$ASSOC_TIMEOUT" -ge 10 ] || usage_error "--assoc-timeout must be at least 10 seconds"
is_uint "$SETTLE" || [ "$SETTLE" = 0 ] || usage_error "--settle must be an integer"
is_uint "$WARMUP" || usage_error "--warmup must be a positive integer"
[ "$WARMUP" -ge 1 ] || usage_error "--warmup must be greater than zero"
is_uint "$SIGNAL_TOL" || [ "$SIGNAL_TOL" = 0 ] || usage_error "--signal-tol must be an integer"

if [ -n "$CLIENT" ]; then
	CLIENT=$(norm_mac "$CLIENT")
	valid_mac "$CLIENT" || usage_error "--client must be a MAC address, got '$CLIENT'"
fi

if [ "$RUN" = 0 ]; then
	# An implicit dry run is the safe default: never change the radio unless
	# the operator asked for it.
	DRY_RUN=1
fi

SOURCE_SECS=$((WARMUP + WINDOW + 3))

# ----- prerequisites -----------------------------------------------------

if [ -n "$CLIENT_IP" ]; then
	case $CLIENT_IP in
	*[!0-9a-fA-F:.]*) usage_error "--client-ip is not an IP address: '$CLIENT_IP'" ;;
	esac
fi

# Read the current radio1 state.  These are also the rollback values.
ORIG_CHANNEL=
ORIG_HTMODE=
if have uci; then
	ORIG_CHANNEL=$(uci_get wireless.radio1.channel)
	ORIG_HTMODE=$(uci_get wireless.radio1.htmode)
fi

# Derive the missing htmode from the current PHY prefix (EHT/HE/VHT).
_hm_prefix=${ORIG_HTMODE%%[0-9]*}
case $_hm_prefix in
HT|VHT|HE|EHT) ;;
*) _hm_prefix=EHT ;;
esac
if [ -z "$HTMODE80" ] && [ -z "$HTMODE160" ]; then
	HTMODE80="${_hm_prefix}80"
	HTMODE160="${_hm_prefix}160"
elif [ -z "$HTMODE80" ]; then
	HTMODE80="${HTMODE160%%[0-9]*}80"
elif [ -z "$HTMODE160" ]; then
	HTMODE160="${HTMODE80%%[0-9]*}160"
fi
case $HTMODE80 in
*80) ;;
*) usage_error "--htmode80 must name an 80 MHz mode (e.g. EHT80), got '$HTMODE80'" ;;
esac
case $HTMODE160 in
*160) ;;
*) usage_error "--htmode160 must name a 160 MHz mode (e.g. EHT160), got '$HTMODE160'" ;;
esac

if [ "$CH80" = auto ]; then
	if [ -n "$ORIG_CHANNEL" ] && is_80mhz_channel "$ORIG_CHANNEL"; then
		CH80=$ORIG_CHANNEL
	else
		CH80=36
	fi
else
	is_uint "$CH80" || usage_error "--ch80 must be an integer or 'auto'"
	is_80mhz_channel "$CH80" || usage_error "--ch80 $CH80 is not an 80 MHz-capable 5 GHz channel"
fi
is_uint "$CH160" || usage_error "--ch160 must be an integer"
is_160mhz_channel "$CH160" || usage_error "--ch160 $CH160 is not a 160 MHz-capable 5 GHz channel (36 or 100)"

# Find the 5 GHz AP.  A dry run must not die here: it reports what is missing.
if have iw; then
	if [ -n "$IFACE" ]; then
		_requested=$IFACE
		_f=$(iface_freq)
		if [ -z "$_f" ]; then
			IFACE=
			if [ "$RUN" = 1 ]; then
				die "interface '$_requested' does not exist or has no channel"
			fi
		elif [ "$_f" -lt 5000 ] || [ "$_f" -gt 5925 ]; then
			IFACE=
			if [ "$RUN" = 1 ]; then
				die "interface '$_requested' is not on the 5 GHz band"
			fi
		fi
	fi
	if [ -z "$IFACE" ]; then
		IFACE=$(detect_iface) || IFACE=
	fi
fi
if [ -n "$CLIENT_IP" ] && [ -n "$CLIENT" ]; then
	:
elif [ -n "$CLIENT" ] && [ -r /proc/net/arp ]; then
	CLIENT_IP=$(awk -v mac="$CLIENT" 'tolower($4) == mac { print $1; exit }' /proc/net/arp 2>/dev/null)
fi

# Default source: one iperf3 process per --procs, aimed at CLIENT_IP.
if [ -z "$SOURCE" ] && [ -n "$CLIENT_IP" ] && have iperf3; then
	# Single-quoted on purpose: the per-process "sh -c" expands the
	# placeholders with the exported CLIENT_IP and SOURCE_SECS.
	# shellcheck disable=SC2016
	SOURCE='iperf3 -c "$CLIENT_IP" -t "$SOURCE_SECS"'
	SOURCE_DEFAULT=1
else
	SOURCE_DEFAULT=0
fi

if [ "$DRY_RUN" = 1 ]; then
	dry_run_plan
	exit 0
fi

# ----- real run ----------------------------------------------------------

for _c in uci iw wifi awk sed grep cut tr md5sum; do
	have "$_c" || die "required command missing: $_c"
done
[ -n "$IFACE" ] || die "no 5 GHz AP interface found (pass --iface)"
[ -n "$ORIG_CHANNEL" ] || die "wireless.radio1.channel is unset; cannot guarantee rollback"
[ -n "$ORIG_HTMODE" ] || die "wireless.radio1.htmode is unset; cannot guarantee rollback"
[ -n "$CLIENT" ] || usage_error "--client is required for a real run"
[ -w "$WIRELESS_CONFIG" ] || die "cannot write $WIRELESS_CONFIG (run as root)"

if [ -z "$SOURCE" ]; then
	die "no traffic source: pass --source, or --client-ip with iperf3 installed (client must run 'iperf3 -s')"
fi

if ! station_has "$IFACE" "$CLIENT"; then
	say "SKIP: no 5 GHz STA $CLIENT associated on $IFACE; nothing changed"
	exit 0
fi

LOG=
if [ -z "$OUT" ]; then
	OUT=/tmp/ab-80-160-$(date '+%Y%m%d-%H%M%S' 2>/dev/null)
fi
[ -n "$OUT" ] || die "cannot create an output directory name"
if [ -e "$OUT/result.tsv" ]; then
	die "output directory already contains a result: $OUT"
fi
mkdir -p "$OUT" 2>/dev/null || die "cannot create output directory: $OUT"
LOG=$OUT/run.log
: >"$LOG" 2>/dev/null || true

MD5_BEFORE=$(md5sum "$WIRELESS_CONFIG" 2>/dev/null | awk '{print $1}')
[ -n "$MD5_BEFORE" ] || die "cannot read $WIRELESS_CONFIG"
HAD_DELTA=0
if [ -f "$UCI_DELTA" ]; then
	HAD_DELTA=1
	cp -p "$UCI_DELTA" "$OUT/wireless.uci-delta.bak" 2>/dev/null || die "cannot back up $UCI_DELTA"
fi
cp -p "$WIRELESS_CONFIG" "$OUT/wireless.bak" 2>/dev/null || die "cannot back up $WIRELESS_CONFIG"

{
	printf 'captured_at=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)"
	printf 'channel=%s\n' "$ORIG_CHANNEL"
	printf 'htmode=%s\n' "$ORIG_HTMODE"
	printf 'band=%s\n' "$(uci_get wireless.radio1.band)"
	printf 'country=%s\n' "$(uci_get wireless.radio1.country)"
	printf 'iface=%s\n' "$IFACE"
	printf 'client=%s\n' "$CLIENT"
	printf 'client_ip=%s\n' "${CLIENT_IP:-}"
	printf 'md5_before=%s\n' "$MD5_BEFORE"
	printf 'uci_delta_present=%s\n' "$HAD_DELTA"
	uci show wireless.radio1 2>/dev/null
} >"$OUT/orig-radio1.txt"

{
	printf '=== iw dev\n'
	iw dev 2>&1
	printf '=== iw dev %s info\n' "$IFACE"
	iw dev "$IFACE" info 2>&1
	printf '=== iw dev %s station dump\n' "$IFACE"
	iw dev "$IFACE" station dump 2>&1
	printf '=== iw reg get\n'
	iw reg get 2>&1
} >"$OUT/iw-before.txt"

trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 143' 15
trap cleanup 0

nw_guard_init --apply --no-trap --label ab-80-160 \
	--result-json "$OUT/netwatchdog.json"
nw_guard_take ||
	die "cannot take the netwatchdog hold; refusing to retune radio1.  Install netwatchdog, or set NWD_ALLOW_NO_SERVICE=1 for a run that expects no protection."

say "A/B 5 GHz 80 vs 160: client=$CLIENT iface=$IFACE procs=$PROCS window=${WINDOW}s"
say "source: ${SOURCE}$([ "$SOURCE_DEFAULT" = 1 ] && echo ' (default iperf3)')"
say "original: channel=$ORIG_CHANNEL htmode=$ORIG_HTMODE md5=$MD5_BEFORE out=$OUT"

run_arm 80 "$CH80" "$HTMODE80" 80
ROW80_NSS=$ARM_NSS
ROW80_SIG=$ARM_SIG
ROW80_OK=$ARM_OK
ROW80_STATUS=$ARM_STATUS
ROW80_CH=$ARM_CH
ROW80_WIDTH=$ARM_WIDTH
ROW80_TXB=$ARM_TXB
ROW80_SECS=$ARM_SECS
ROW80_GBIT=$ARM_GBIT
ROW80_RETR=$ARM_RETR

run_arm 160 "$CH160" "$HTMODE160" 160
ROW160_NSS=$ARM_NSS
ROW160_SIG=$ARM_SIG
ROW160_OK=$ARM_OK
ROW160_STATUS=$ARM_STATUS
ROW160_CH=$ARM_CH
ROW160_WIDTH=$ARM_WIDTH
ROW160_TXB=$ARM_TXB
ROW160_SECS=$ARM_SECS
ROW160_GBIT=$ARM_GBIT
ROW160_RETR=$ARM_RETR

# Restore before printing so the table and the rollback proof are the last
# things an operator sees, and so result files never depend on a reboot.
restore_config

# Pair-level rejection.  An arm that is individually valid but differs from
# the other arm is marked rejected in its row, because neither arm can be
# attributed to width if NSS or the signal class moved.
VERDICT_OBS=
if [ "$ROW80_OK" != 1 ]; then
	VERDICT_OBS="arm 80 rejected: $ROW80_STATUS"
elif [ "$ROW160_OK" != 1 ]; then
	VERDICT_OBS="arm 160 rejected: $ROW160_STATUS"
elif [ "$ROW80_NSS" != "$ROW160_NSS" ]; then
	VERDICT_OBS="NSS mismatch: 80 MHz NSS $ROW80_NSS vs 160 MHz NSS $ROW160_NSS"
	ROW160_STATUS="reject: NSS $ROW160_NSS differs from arm 80 NSS $ROW80_NSS"
	ROW160_OK=0
elif [ "$ROW80_WIDTH" != 80 ] || [ "$ROW160_WIDTH" != 160 ]; then
	VERDICT_OBS="width mismatch: measured $ROW80_WIDTH/$ROW160_WIDTH MHz, want 80/160"
	[ "$ROW80_WIDTH" != 80 ] && ROW80_STATUS="reject: width $ROW80_WIDTH MHz, want 80"
	[ "$ROW160_WIDTH" != 160 ] && ROW160_STATUS="reject: width $ROW160_WIDTH MHz, want 160"
else
	_sig_delta=$(awk -v a="$ROW80_SIG" -v b="$ROW160_SIG" 'BEGIN { d = a - b; if (d < 0) d = -d; printf "%.0f", d }')
	if [ "$_sig_delta" -gt "$SIGNAL_TOL" ]; then
		VERDICT_OBS="signal class mismatch: median $ROW80_SIG vs $ROW160_SIG dBm (> ${SIGNAL_TOL} dB)"
		ROW160_STATUS="reject: signal $ROW160_SIG dBm differs from arm 80 $ROW80_SIG dBm (> ${SIGNAL_TOL} dB)"
		ROW160_OK=0
	fi
fi

print_table_header
ARM_NAME=80
print_row "$ROW80_CH" "$ROW80_WIDTH" "$ROW80_NSS" "$ROW80_SIG" "$ROW80_TXB" \
	"$ROW80_SECS" "$ROW80_GBIT" "$ROW80_RETR" "$ROW80_STATUS"
ARM_NAME=160
print_row "$ROW160_CH" "$ROW160_WIDTH" "$ROW160_NSS" "$ROW160_SIG" "$ROW160_TXB" \
	"$ROW160_SECS" "$ROW160_GBIT" "$ROW160_RETR" "$ROW160_STATUS"

{
	printf 'arm\tchannel\twidth\tNSS\tsignal\ttx_bytes\tseconds\tGbit/s\tretries\tstatus\n'
	printf '80\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$ROW80_CH" "$ROW80_WIDTH" "$ROW80_NSS" "$ROW80_SIG" "$ROW80_TXB" \
		"$ROW80_SECS" "$ROW80_GBIT" "$ROW80_RETR" "$ROW80_STATUS"
	printf '160\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$ROW160_CH" "$ROW160_WIDTH" "$ROW160_NSS" "$ROW160_SIG" "$ROW160_TXB" \
		"$ROW160_SECS" "$ROW160_GBIT" "$ROW160_RETR" "$ROW160_STATUS"
} >"$OUT/result.tsv"

if [ -n "$VERDICT_OBS" ]; then
	say "VERDICT: REJECT ($VERDICT_OBS)"
	_st=3
else
	say "VERDICT: COMPARABLE (both arms ${ROW80_WIDTH}/${ROW160_WIDTH} MHz, NSS $ROW80_NSS, signal $ROW80_SIG/$ROW160_SIG dBm)"
	_st=0
fi
if [ "$ROLLBACK_OK" != 1 ]; then
	say "VERDICT: rollback failed; treat this run as invalid"
	_st=1
fi
say "results: $OUT/result.tsv, $OUT/rollback.txt"
exit "$_st"
