#!/bin/sh
#
# edca-6g-ab.sh - 6 GHz BE EDCA TXOP 0/63/171 A/B harness.
#
# Context: before #18 the 6 GHz hostapd config carried no
# tx_queue_data2_burst, so the 6 GHz BE TXOP was 0.  #18 gives the 6 GHz band
# the same 2.0 ms (63 EDCA time units) default as 5 GHz, so a rebuilt image
# does emit the line and the hostapd mechanism below can set it; an older
# image emits nothing and that mechanism stops with "hostapd did not emit
# tx_queue_data2_burst".  The mt76 "0019" edca_apply debugfs path applies an
# arbitrary BE TXOP without restarting hostapd, which is why auto prefers it.
# This harness measures the effect of the BE TXOP on AP-to-STA throughput with
# everything else held fixed.
#
# Units: the EDCA TXOP limit is in units of 32 us (the nl80211/ieee80211
# txop unit).  The arms are therefore 0, 2016 us and 5472 us; 171 units is the
# 6 GHz maximum TXOP (5.484 ms).  hostapd's tx_queue_data2_burst is expressed
# in milliseconds with 0.1 ms granularity, so it can encode 63 exactly (2.0 ms)
# but only approximates 171 (5.5 ms is applied as 172 units).  The debugfs
# mechanism writes the raw 32 us value and therefore reaches 171 exactly.
#
# Two set mechanisms, one arm at a time:
#
#   hostapd  uci set wireless.<radio>.tx_burst=<ms>; uci commit; wifi reload.
#            tx_queue_data2_burst is a wifi-device (radio) option, so the whole
#            6 GHz radio is reloaded and the STA must re-associate for every arm.
#            The effective value is read back from the generated hostapd conf.
#
#   debugfs  write the BE TXOP (decimal, 32 us units) to the mt76 edca_apply
#            debugfs file.  No hostapd restart and no re-association: this is
#            the 0019 path.  The original file content is saved before the
#            first write and restored byte-for-byte on exit.
#
# The 6 GHz-only BSS is a precondition, not something this harness builds: the
# no-STA rule requires the STA to be associated before anything is written, so
# the BSS necessarily already exists.  The harness verifies that the AP
# interface is on a 6 GHz channel and that the station is not an MLO link, and
# refuses to run otherwise.  The trap restores the wireless configuration (and
# therefore the hostapd BSS configuration) that the per-arm reloads rewrite;
# no BSS is created, so none is left behind.
#
# Protocol per arm, all arms use exactly the same iperf3 source:
#
#   apply TXOP -> wait for the STA -> settle -> snapshots -> iperf3 -J
#   -> snapshots -> summary
#
# The AP is the iperf3 client and the STA must run "iperf3 -s".  That makes
# the measured direction AP-to-STA for every arm.
#
# Evidence recorded before and after every arm:
#   iw dev <iface> station dump      (tx/rx bitrate, NSS, width, signal, bytes)
#   iw dev <iface> info              (channel and frequency)
#   edca_apply                        (raw content, when the 0019 path exists)
#   hostapd tx_queue_data* lines      (effective hostapd EDCA configuration)
#   uci wireless tx_burst             (requested hostapd value)
#   mt76 token_info and tx_stats      (when the debugfs files exist)
#   /sys/class/net/<iface>/statistics (AP tx bytes/packets)
#
# If no 6G STA is associated the harness prints exactly "SKIP: no 6G STA" and
# exits 0 before creating a result directory or writing any configuration.
# A missing iperf3 is treated the same way ("SKIP: iperf3 not found on the
# AP"), because nothing has been measured and nothing was written; a missing
# measurement tool is not a harness failure.  Both skips record the reason in
# result.json when --result-dir named a directory, and both write a
# wireless-no-client/v1 record (missing "6ghz-eht-client" / "iperf3") that
# scripts/wireless/hw-gap-report.sh merges with the other harnesses.
# --source CMD replaces the iperf3 client in every arm, so a host without
# iperf3 still measures when another generator is named.
#
# No module load/unload, no firmware change, no reboot.  The script only
# changes the single 6 GHz radio's tx_burst UCI option or the edca_apply
# debugfs value, and restores it in an EXIT/INT/TERM/HUP trap.
#
# Exit status: 0 all arms measured and the original configuration restored;
#              1 a runtime failure (arm invalid, reload failed, restore failed);
#              2 invalid arguments (--help documents them).
#
# POSIX sh only, so it runs on the OpenWrt device with busybox ash.  Requires
# root: wifi reload and debugfs access are not available otherwise.
#
# shellcheck shell=dash
# shellcheck disable=SC3043  # POSIX sh still has no `local`; dash/ash do, and
#                            # the harness relies on it for scoped temporaries.
# Test hooks: the EDCA6G_* variables at the top of the environment section
# override the command and path names.  They exist so the harness can be run
# end to end against a mock root without touching a real radio; the defaults
# are the device's normal values.

set -u
LC_ALL=C
export LC_ALL

PROG=${0##*/}

# Shared no-client record: a skip for missing hardware writes a structured
# result.json (scripts/wireless/lib/no-client.sh) instead of a bare SKIP.
NO_CLIENT_LIB=$(dirname "$0")/lib/no-client.sh
# shellcheck source=lib/no-client.sh
[ -r "$NO_CLIENT_LIB" ] && . "$NO_CLIENT_LIB"

# Fixed protocol constants.  These are the arms issue #43 asks for; do not
# make them runtime-configurable, or two runs stop being comparable.
# EDCA6G_ARMS is a test hook, not a flag: the offline self-check uses it to
# run a two-arm A/B sequence against mock commands.  Whatever it holds is
# written to result.json, so such a run is self-describing.
TU_US=32
ARMS=${EDCA6G_ARMS:-'0 63 171'}

# Environment defaults.  Every one can also be set with a flag; the flags
# override the environment (see usage).
TARGET=${TARGET:-}
# Optional replacement for the iperf3 client, run through sh -c per arm.
SOURCE=${SOURCE:-}
IFACE=${IFACE:-}
STATION=${STATION:-}
RADIO=${RADIO:-}
STA_MODEL=${STA_MODEL:-unknown}
DURATION=${DURATION:-20}
PARALLEL=${PARALLEL:-4}
SETTLE=${SETTLE:-2}
ROUNDS=${ROUNDS:-1}
COOLDOWN=${COOLDOWN:-2}
ASSOC_TIMEOUT=${ASSOC_TIMEOUT:-45}
RESULT_DIR=${RESULT_DIR:-}
MECHANISM=${MECHANISM:-auto}
EDCA_APPLY=${EDCA_APPLY:-}
EDCA_APPLY_EXPLICIT=0
[ -n "$EDCA_APPLY" ] && EDCA_APPLY_EXPLICIT=1
DRY_RUN=0

# Commands and paths.  The EDCA6G_* overrides are the mock-test hooks
# documented in the header; real runs use the defaults.
EDCA6G_IW=${EDCA6G_IW:-iw}
EDCA6G_UCI=${EDCA6G_UCI:-uci}
EDCA6G_WIFI=${EDCA6G_WIFI:-wifi}
EDCA6G_IPERF3=${EDCA6G_IPERF3:-iperf3}
EDCA6G_WIRELESS_CONF=${EDCA6G_WIRELESS_CONF:-/etc/config/wireless}
EDCA6G_RUN_DIR=${EDCA6G_RUN_DIR:-/var/run}
EDCA6G_DEBUGFS=${EDCA6G_DEBUGFS:-/sys/kernel/debug/ieee80211}
EDCA6G_SYSFS_NET=${EDCA6G_SYSFS_NET:-/sys/class/net}

usage() {
	cat <<'EOF'
Usage: edca-6g-ab.sh --target IP [options]

A/B the 6 GHz BE EDCA TXOP with three arms: 0, 63 and 171 EDCA time units
(32 us each, so 0 / 2.016 ms / 5.472 ms).  The AP runs the iperf3 client and
the already-associated 6 GHz STA must run "iperf3 -s"; every arm uses the
same iperf3 command.  If no 6G STA is associated the harness prints
"SKIP: no 6G STA" and exits 0 without writing anything.

Required for a real run:
  --target IP             IPv4/IPv6 address of the STA running iperf3 -s

Optional inputs (environment variable or flag):
  --iface NAME           6 GHz AP netdev under test (default: auto-detect)
  --sta MAC              station MAC to use when several are associated
  --radio SECTION        UCI wifi-device section for the 6 GHz radio
                         (default: auto-detect from the AP phy)
  --sta-model MODEL      free-form STA model recorded in result.json and
                         device.txt (default "unknown")
  --duration SEC         iperf3 seconds per arm (default 20)
  --parallel N           iperf3 streams per arm (default 4)
  --source CMD           run CMD instead of iperf3 as the traffic source in
                         every arm; CMD goes through "sh -c" with TARGET,
                         DURATION and PARALLEL in the environment.  Use it
                         when iperf3 is not installed on the AP.
  --settle SEC           wait after the arm is applied (default 2)
  --rounds N             run the whole arm sequence N times (default 1).
                         Every round uses the same arm order, so the
                         round-to-round spread is drift, not an ordering
                         effect.  Per-round values plus the median, min,
                         max and range per arm are printed and recorded.
  --cooldown SEC         sleep between rounds (default 2, the --settle
                         default); the first round has no cool-down
  --assoc-timeout SEC    wait for the STA to re-associate after wifi reload
                         (default 45)
  --result-dir DIR       output directory (default ./edca-6g-ab-<epoch>;
                         refuses to overwrite an existing result.json)
  --mechanism M          auto | hostapd | debugfs (default auto)
  --edca-apply PATH      explicit mt76 edca_apply debugfs file
  --dry-run              print the plan and exit 0; no device access, no
                         command execution, no file or configuration writes
  -h, --help             this text

Mechanisms:
  hostapd   uci set wireless.<radio>.tx_burst=<ms>; uci commit wireless;
            wifi reload.  This is the in-tree #18 path.  tx_burst is a
            wifi-device option and the value is in milliseconds with 0.1 ms
            granularity, so the arms are 0, 2.0 and 5.5 ms.  hostapd
            converts 2.0 ms to 63 units exactly and 5.5 ms to 172 units, i.e.
            the 171 arm is one EDCA unit above the requested value; the
            summary labels the derived value.  The STA is disconnected by the
            reload and must re-associate before the arm starts.
  debugfs   write the decimal BE TXOP in 32 us units to the mt76
            edca_apply file and read it back.  This is the 0019 path: it
            changes the EDCA parameters at runtime, so 171 is applied
            exactly and the STA never re-associates.  The file must be
            readable (the original content is restored on exit) and
            writable; a readback that reports a different value aborts the
            run and restores the original content.  auto prefers this
            mechanism when a readable and writable edca_apply file is
            present; otherwise it uses hostapd.

The 6 GHz-only BSS requirement:
  The station must already be associated to an AP interface whose channel is
  in the 6 GHz band (5950-7125 MHz) and which is not an MLO link.  The
  harness validates this before any write and refuses an MLO station with a
  clear error.  It does not create a BSS: the no-STA rule requires the
  association to exist first, and the trap restores the wireless
  configuration (and hence the hostapd BSS configuration) that the per-arm
  reloads regenerate.  If the BSS was created with
  scripts/wireless/6g-only.sh (issue #46), that helper owns its lifecycle:
  run its --remove after the measurement.  This harness leaves the marked
  6g-only UCI block and the BSS untouched and prints that reminder at the
  end.

Recorded per arm (before and after snapshots, plus result.json):
  iw station dump, iw dev info, the AP netdev tx byte counter, the station's
  tx bytes/retries, edca_apply, the effective hostapd tx_queue_data* lines,
  the UCI tx_burst, mt76 token_info and tx_stats (when present), and the
  iperf3 JSON.

Repeats (drift control):
  --rounds N runs the whole arm sequence N times.  The arms stay 0/63/171
  and the order is the same in every round (A/B/C, A/B/C, ...), so round r
  measures the same sequence as round 1 and the round-to-round spread is
  drift plus noise, not an ordering effect.  --cooldown SEC sleeps between
  rounds (default 2 s, the same value as --settle).  stdout prints the
  throughput of every round and, per arm, the median, minimum, maximum and
  range across rounds; result.json carries "rounds", "cooldown_s", a
  timeline with per-round start/end stamps, and the same aggregate.

Output directory:
  raw.log              chronological command log
  backup/wireless      the /etc/config/wireless copy made before any write
  arms/r<N>/<tu>/before|after/*.txt   raw snapshots
  arms/r<N>/<tu>/iperf3.json          iperf3 -J output
  arms.jsonl           one JSON object per arm measurement
  rounds.jsonl         one object per round (start, end, arms, cooldown)
  result.json          schema edca-6g-ab/v1, arms, aggregate, restore status
  summary.tsv          the per-measurement table (round, arm ...), tab separated

Restore:
  The original EDCA state is restored in a trap on EXIT, INT, TERM and HUP:
  the debugfs file content byte-for-byte, or the wireless configuration file
  plus wifi reload, with the md5 checked and the STA awaited.  A failed
  restore exits 1 even when all arms measured.

Constraints: no module load/unload, no firmware change, no reboot.  The only
writes are the single 6 GHz radio's tx_burst UCI option (with the original
/etc/config/wireless restored) or the edca_apply debugfs value (restored).

Exit status: 0 success or clean skip; 1 runtime/restore failure; 2 bad usage.
EOF
}

usage_error() {
	printf '%s: %s\n' "$PROG" "$*" >&2
	printf 'Try "%s --help".\n' "$PROG" >&2
	exit 2
}

die() {
	printf '%s: error: %s\n' "$PROG" "$*" >&2
	log_line "ERROR: $*"
	exit 1
}

# write_skip_result REASON: the preflight skip record.  Written only when
# --result-dir named a directory: a skip must not create an output tree on
# its own, and the caller's explicit directory is where a wrapper looks for
# it.  Nothing here is a configuration write.
write_skip_result() {
	local _dir _reason
	_dir=$1
	_reason=$2
	mkdir -p "$_dir" || return 0
	{
		printf '{\n'
		printf '  "schema": "edca-6g-ab/v1",\n'
		printf '  "timestamp": %s,\n' "$(json_str "$(now_ts)")"
		printf '  "status": "skip",\n'
		printf '  "skip_reason": %s,\n' "$(json_str "$_reason")"
		printf '  "rounds": %s,\n' "$(json_num "$ROUNDS")"
		printf '  "cooldown_s": %s,\n' "$(json_num "$COOLDOWN")"
		printf '  "arms": [],\n'
		printf '  "restore": null,\n'
		printf '  "ok": true\n'
		printf '}\n'
	} >"$_dir/result.json.tmp" 2>/dev/null &&
		mv "$_dir/result.json.tmp" "$_dir/result.json" 2>/dev/null
	return 0
}

# skip_run REASON: a clean hardware/tool skip.  Prints one SKIP line, records
# the reason next to the results when a directory was named, and exits 0.
# Nothing has been written to the device at this point.
skip_run() {
	say "SKIP: $1"
	log_line "SKIP: $1"
	[ -n "${RESULT_DIR:-}" ] && write_skip_result "$RESULT_DIR" "$1"
	exit 0
}

# skip_no_client REASON: no 6 GHz client, so there is no A/B to run.  Prints
# the same "SKIP:" line but also records the missing hardware (status
# "no-client") and the command to run once it exists, so hw-gap-report.sh can
# merge this harness with the others.
skip_no_client() {
	# No associated STA on an OWE-upgraded open 6 GHz AP is a configuration
	# block, not a missing client (#347).  Prefer --iface, else the first
	# 6 GHz AP the board exposes.
	_owe_if=${IFACE:-}
	if [ -z "$_owe_if" ]; then
		for _owe_cand in $(list_ifaces); do
			[ "$(iface_type "$_owe_cand")" = AP ] || continue
			is_6g_freq "$(iface_freq "$_owe_cand")" || continue
			_owe_if=$_owe_cand
			break
		done
	fi
	if [ -n "$_owe_if" ] && _mm=$(nc_owe_mismatch "$_owe_if"); then
		nc_owe_mismatch_block "${RESULT_DIR:-}" 43 "$_mm"
		exit 2
	fi
	_nc_run='sh scripts/wireless/edca-6g-ab.sh --target <STA_IP> --result-dir <DIR>'
	_rec=$(no_client_record "${RESULT_DIR:-}" 43 6ghz-eht-client "$_nc_run" \
		"${1:-no 6G STA}" \
		"EDCA parameter A/B throughput delta per arm" \
		"tx_burst / airtime restore verification" \
		"per-arm station retries and failed frames" 2>/dev/null)
	say "SKIP: $1"
	say "      missing 6ghz-eht-client; once it is available run: $_nc_run"
	[ -n "$_rec" ] && say "      no-client record: $_rec"
	log_line "SKIP: $1"
	exit 0
}

# skip_no_tool DETAIL: iperf3 is missing on the AP and no --source names
# another generator.  Same skip contract as skip_no_client (rc 0, one SKIP
# line, skip record when --result-dir was given), plus the no-client record
# that hw-gap-report.sh collects.  It lives in a subdirectory so the harness
# keeps its own result.json.
skip_no_tool() {
	_nc_run='sh scripts/wireless/edca-6g-ab.sh --target <STA_IP> --result-dir <DIR>'
	_nc_dir=${RESULT_DIR:-}
	[ -n "$_nc_dir" ] && _nc_dir=$_nc_dir/no-client
	_rec=$(no_client_record "$_nc_dir" 43 iperf3 "$_nc_run" "$1" \
		"EDCA parameter A/B throughput delta per arm" \
		"tx_burst / airtime restore verification" \
		"per-arm station retries and failed frames" 2>/dev/null)
	say "SKIP: $1"
	say "      missing iperf3; install it (opkg install iperf3) or pass --source CMD"
	[ -n "$_rec" ] && say "      no-client record: $_rec"
	log_line "SKIP: $1"
	[ -n "${RESULT_DIR:-}" ] && write_skip_result "$RESULT_DIR" "$1"
	exit 0
}

# The hostapd mechanism commits tx_burst and bounces every radio with "wifi
# reload", so a run holds netwatchdog first.  The library fails closed:
# nw_guard_take returns nonzero when netwatchdog is missing or the hold cannot
# be taken, and the run is refused in that case.  This script owns its own
# EXIT/INT/TERM/HUP trap, so the guard installs none and its cleanup is called
# from the script's own on_exit instead.
NETWATCHDOG_GUARD=$(dirname "$0")/../lib/netwatchdog-guard.sh
[ -r "$NETWATCHDOG_GUARD" ] ||
	die "shared library not found: $NETWATCHDOG_GUARD"
# shellcheck source=../lib/netwatchdog-guard.sh
. "$NETWATCHDOG_GUARD"

# The hostapd arm rewrites the config with "uci set"/"uci commit", so the
# restore point has to cover the pending UCI delta (/tmp/.uci/wireless) and
# not only the config file: a delta left behind is flushed into the config by
# the next unrelated commit, and the file then changes with nobody doing the
# write.  Best effort: an old tree still runs on the $RESULT_DIR backup.
UCI_RESTORE_GUARD=$(dirname "$0")/../lib/uci-restore-guard.sh
if [ -r "$UCI_RESTORE_GUARD" ]; then
	# shellcheck source=../lib/uci-restore-guard.sh
	. "$UCI_RESTORE_GUARD"
else
	printf '%s: warning: shared library not found: %s; the pending UCI delta will not be restored\n' \
		"${0##*/}" "$UCI_RESTORE_GUARD" >&2
fi

note() { printf '%s\n' "$*" >&2; }

say() { printf '%s\n' "$*"; }

now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S; }

# json_escape STRING: the value part of a JSON string.  The harness only
# emits its own fixed keys and device/tool output, so escaping quotes,
# backslashes and control characters is enough.
json_escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' |
		tr -d '\r\n'
}

# json_str STRING: a quoted JSON string.
json_str() { printf '"%s"' "$(json_escape "$1")"; }

# json_num VALUE: a JSON number when VALUE is numeric, otherwise null.
json_num() {
	case $1 in
	''|*[!0-9.eE+-]*) printf 'null' ;;
	*) printf '%s' "$1" ;;
	esac
}

is_uint() {
	case $1 in
	''|*[!0-9]*) return 1 ;;
	0|[1-9]*) return 0 ;;
	esac
	return 1
}

# require_uint NAME VALUE MIN: exit 2 when VALUE is not an unsigned integer
# >= MIN.
require_uint() {
	is_uint "$2" || usage_error "$1 must be an unsigned integer, got '$2'"
	[ "$2" -ge "$3" ] || usage_error "$1 must be >= $3, got '$2'"
}

normalize_mac() {
	printf '%s' "$1" | tr 'A-F' 'a-f'
}

is_6g_freq() {
	[ -n "$1" ] && [ "$1" -ge 5950 ] && [ "$1" -le 7125 ]
}

# ---------------------------------------------------------------------------
# iw helpers

iface_info() { "$EDCA6G_IW" dev "$1" info 2>/dev/null; }

list_ifaces() {
	"$EDCA6G_IW" dev 2>/dev/null |
		sed -n 's/^[[:space:]]*Interface[[:space:]]\{1,\}//p'
}

iface_type() {
	iface_info "$1" | sed -n 's/^[[:space:]]*type[[:space:]]\{1,\}//p' | head -n 1
}

iface_freq() {
	iface_info "$1" |
		sed -n 's/.*(\([0-9]\{1,\}\) MHz).*/\1/p' | head -n 1
}

iface_phy_name() {
	local _wiphy
	# "wiphy 2" -> "phy2" (the debugfs directory name and the UCI phy value).
	_wiphy=$(iface_info "$1" |
		sed -n 's/^[[:space:]]*wiphy[[:space:]]\{1,\}\([0-9]\{1,\}\).*/\1/p' |
		head -n 1)
	[ -n "$_wiphy" ] || return 1
	printf 'phy%s' "$_wiphy"
}

sta_dump() { "$EDCA6G_IW" dev "$1" station dump 2>/dev/null; }

sta_macs() {
	sta_dump "$1" | sed -n 's/^Station[[:space:]]\{1,\}\([0-9a-fA-F:]\{17\}\).*/\1/p'
}

# sta_block DUMP MAC: only the fields of one station.  An AP with several
# clients prints one "Station <mac>" block each; the A/B numbers must come
# from the selected STA, not from whichever block happens to be first.
sta_block() {
	printf '%s\n' "$1" | awk -v mac="$2" '
		$1 == "Station" && $2 == mac { on = 1; print; next }
		on && $0 ~ /^[^[:space:]]/ { on = 0 }
		on { print }
	'
}

# discover_6g_sta: sets DISCOVERED_IFACE and DISCOVERED_STA.  Only reads.
discover_6g_sta() {
	local _candidates _i _f _m
	DISCOVERED_IFACE=
	DISCOVERED_STA=
	_candidates=0
	for _i in $(list_ifaces); do
		[ "$(iface_type "$_i")" = AP ] || continue
		_f=$(iface_freq "$_i")
		is_6g_freq "$_f" || continue
		[ -n "$IFACE" ] && [ "$_i" != "$IFACE" ] && continue
		for _m in $(sta_macs "$_i"); do
			_m=$(normalize_mac "$_m")
			[ -n "$STATION" ] && [ "$_m" != "$STATION" ] && continue
			_candidates=$((_candidates + 1))
			DISCOVERED_IFACE=$_i
			DISCOVERED_STA=$_m
		done
	done

	if [ "$_candidates" -eq 0 ]; then
		return 1
	fi
	if [ "$_candidates" -gt 1 ]; then
		usage_error "several 6G STAs are associated ($_candidates); use --sta or --iface"
	fi
	return 0
}

# validate_6g_only_iface IFACE: the interface must be a 6 GHz AP.
validate_6g_only_iface() {
	local _type _freq _dump
	_type=$(iface_type "$1")
	[ "$_type" = AP ] ||
		die "interface '$1' is not an AP (iw type '$_type')"
	_freq=$(iface_freq "$1")
	is_6g_freq "$_freq" ||
		die "interface '$1' is not on a 6 GHz channel (freq '$_freq')"

	# An MLD station has "MLD address" in its dump; a plain BSS does not.
	_dump=$(sta_block "$(sta_dump "$1")" "$2")
	[ -n "$_dump" ] || die "station $2 is no longer associated on $1"
	if printf '%s\n' "$_dump" | grep -qi 'MLD address'; then
		die 'station is on an MLO link; a 6G-only BSS is required'
	fi
	if printf '%s\n' "$_dump" |
		grep -qi '^[[:space:]]*link[[:space:]][0-9][0-9]*:'; then
		die 'station dump has per-link sections; a 6G-only BSS is required'
	fi
}

# ---------------------------------------------------------------------------
# UCI / hostapd helpers

uci_get() { "$EDCA6G_UCI" -q get "wireless.$1" 2>/dev/null; }

wifi_device_sections() {
	"$EDCA6G_UCI" -q show wireless 2>/dev/null |
		sed -n 's/^wireless\.\([^.=]*\)=wifi-device$/\1/p'
}

wifi_iface_sections() {
	"$EDCA6G_UCI" -q show wireless 2>/dev/null |
		sed -n 's/^wireless\.\([^.=]*\)=wifi-iface$/\1/p'
}

# radio_for_phy PHYNAME: the UCI wifi-device section for a phy.
radio_for_phy() {
	local _phy _found _dev _sec _count
	_phy=$1
	_found=

	# 1. explicit phy= on a wifi-device section
	for _dev in $(wifi_device_sections); do
		[ "$(uci_get "$_dev.phy")" = "$_phy" ] && {
			printf '%s' "$_dev"
			return 0
		}
	done

	# 2. phy= on the iface plus device= (some configs set it there)
	for _sec in $(wifi_iface_sections); do
		[ "$(uci_get "$_sec.phy")" = "$_phy" ] || continue
		_dev=$(uci_get "$_sec.device")
		[ -n "$_dev" ] && {
			printf '%s' "$_dev"
			return 0
		}
	done

	# 3. the only wifi-device with band=6g
	_count=0
	for _dev in $(wifi_device_sections); do
		[ "$(uci_get "$_dev.band")" = 6g ] || continue
		_count=$((_count + 1))
		_found=$_dev
	done
	[ "$_count" -eq 1 ] && {
		printf '%s' "$_found"
		return 0
	}

	return 1
}

# find_hostapd_conf PHYNAME: the generated hostapd conf for the radio.
find_hostapd_conf() {
	local _phy _found _n _f
	_phy=$1
	_found=
	_n=0
	for _f in "$EDCA6G_RUN_DIR"/hostapd-"$_phy"*.conf; do
		[ -f "$_f" ] || continue
		grep -q '^tx_queue_data[0-3]_' "$_f" 2>/dev/null || continue
		_n=$((_n + 1))
		_found=$_f
	done
	[ "$_n" -eq 1 ] && {
		printf '%s' "$_found"
		return 0
	}
	return 1
}

# hostapd_edca_lines CONF: the effective EDCA-related lines, or a note.
# shellcheck disable=SC2329  # called indirectly through run_save
hostapd_edca_lines() {
	if [ -n "$1" ] && [ -f "$1" ]; then
		grep -E '^(tx_queue_data[0-3]_|wmm_ac_)' "$1" 2>/dev/null ||
			printf '# no tx_queue_data*/wmm_ac_ lines in %s\n' "$1"
	else
		printf '# no hostapd configuration file found\n'
	fi
}

hostapd_conf_for_iface() {
	local _f
	[ -n "$IFACE" ] || return 1
	for _f in "$EDCA6G_RUN_DIR"/hostapd-*.conf; do
		[ -f "$_f" ] || continue
		if grep -q "^interface=$IFACE\$" "$_f" 2>/dev/null ||
			grep -q "^bss=$IFACE\$" "$_f" 2>/dev/null; then
			printf '%s' "$_f"
			return 0
		fi
	done
	return 1
}

edca_apply_read() {
	[ -n "$EDCA_APPLY" ] && [ -r "$EDCA_APPLY" ] || return 1
	cat "$EDCA_APPLY" 2>/dev/null
}

# parse_edca_txop TEXT: extract the BE TXOP value (32 us units) from the
# edca_apply readback.  The 0019 file format is owned by the driver patch;
# this accepts a bare value, "be ... <n>", "AC_BE txop <n>", a "queue 0"
# line, or a single "txop <n>" line, and refuses to guess when the text is
# not parseable.
parse_edca_txop() {
	printf '%s\n' "$1" | awk '
		function last_int(s,   t, a, n) {
			t = s
			gsub(/[^0-9]+/, " ", t)
			n = split(t, a, " ")
			return a[n]
		}
		{
			line = tolower($0)
			if (NR == 1 && $0 ~ /^[ \t]*[0-9]+[ \t]*$/) {
				gsub(/[ \t]/, "", $0)
				print $0
				done = 1
				exit
			}
			if (line ~ /txop|tx limit|burst/) {
				if (line ~ /(^|[^a-z0-9])be([^a-z0-9]|$)/ ||
				    line ~ /best effort/ || line ~ /ac_be/ ||
				    line ~ /queue[ \t]*0([^0-9]|$)/) {
					v = last_int(line)
					if (v != "") {
						print v
						done = 1
						exit
					}
				}
				if (fallback == "")
					fallback = last_int(line)
			}
		}
		END {
			if (!done && fallback != "")
				print fallback
		}'
}

# tu_to_burst TU: the hostapd value in milliseconds with one decimal.
tu_to_burst() {
	local _tenths
	[ "$1" = 0 ] && {
		printf '0'
		return 0
	}
	_tenths=$((($1 * TU_US + 50) / 100))
	printf '%d.%d' $((_tenths / 10)) $((_tenths % 10))
}

# burst_to_tu BURST: hostapd's conversion back to 32 us units, matching
# hostapd_config_read_int10() and driver_nl80211: (tenths * 100 + 16) / 32.
burst_to_tu() {
	local _whole _frac _tenths
	case $1 in
	''|*[!0-9.]*) return 1 ;;
	esac
	_whole=${1%%.*}
	case $1 in
	*.*) _frac=${1#*.} ;;
	*) _frac=0 ;;
	esac
	_frac=${_frac%"${_frac#?}"}
	case $_whole in
	''|*[!0-9]*) return 1 ;;
	esac
	case $_frac in
	''|*[!0-9]*) _frac=0 ;;
	esac
	_tenths=$((_whole * 10 + _frac))
	printf '%d' $(((_tenths * 100 + 16) / 32))
}

md5_of() {
	if command -v md5sum >/dev/null 2>&1; then
		md5sum "$1" 2>/dev/null | awk '{print $1}'
	else
		sha256sum "$1" 2>/dev/null | awk '{print $1}'
	fi
}

# ---------------------------------------------------------------------------
# logging and capture

RAW_LOG=
log_line() {
	[ -n "$RAW_LOG" ] || return 0
	printf '%s %s\n' "$(now_ts)" "$*" >>"$RAW_LOG" 2>/dev/null || true
}

log_cmd() { log_line "CMD: $*"; }

# run_save FILE LABEL CMD...: run a command and save stdout+stderr+status.
run_save() {
	local _out _label
	_out=$1
	_label=$2
	shift 2
	log_cmd "$*"
	{
		printf '# %s\n' "$_label"
		printf '# cmd: %s\n' "$*"
		"$@" 2>&1
		printf '# status: %s\n' "$?"
	} >"$_out" 2>/dev/null || true
}

# station dump field: tx bytes, rx bytes, tx retries, ...
sta_field() { # dump key
	local _re
	case $2 in
	'tx bytes') _re='^[[:space:]]*tx bytes:' ;;
	'rx bytes') _re='^[[:space:]]*rx bytes:' ;;
	'tx retries') _re='^[[:space:]]*tx retries:' ;;
	'tx packets') _re='^[[:space:]]*tx packets:' ;;
	*) return 1 ;;
	esac
	printf '%s\n' "$1" |
		sed -n "s/${_re}[[:space:]]*\([0-9]\{1,\}\).*/\1/p" | head -n 1
}

sta_tx_bitrate_line() {
	printf '%s\n' "$1" | grep 'tx bitrate:' 2>/dev/null | tail -n 1
}

sta_link_width() {
	local _line
	_line=$(sta_tx_bitrate_line "$1")
	printf '%s\n' "$_line" |
		sed -n 's/.*[[:space:]]\([0-9]\{1,\}\)MHz.*/\1/p' | tail -n 1
}

sta_link_nss() {
	local _line
	_line=$(sta_tx_bitrate_line "$1")
	printf '%s\n' "$_line" |
		sed -n 's/.*NSS[[:space:]]*\([0-9]\{1,\}\).*/\1/p' | tail -n 1
}

sta_signal() {
	printf '%s\n' "$1" |
		sed -n 's/^[[:space:]]*signal:[[:space:]]*\(-\{0,1\}[0-9]\{1,\}\).*/\1/p' |
		head -n 1
}

counter_get() { # iface counter
	cat "$EDCA6G_SYSFS_NET/$1/statistics/$2" 2>/dev/null
}

# shellcheck disable=SC2329  # called indirectly through run_save
counter_snapshot() {
	local _c _v
	for _c in tx_bytes tx_packets rx_bytes rx_packets; do
		_v=$(counter_get "$IFACE" "$_c")
		printf '%s=%s\n' "$_c" "${_v:-unavailable}"
	done
}

# snapshot DIR: all raw evidence files.
snapshot() {
	local _dir
	_dir=$1
	mkdir -p "$_dir" || die "cannot create snapshot directory $_dir"

	run_save "$_dir/station-dump.txt" \
		"iw dev $IFACE station dump" \
		"$EDCA6G_IW" dev "$IFACE" station dump

	run_save "$_dir/iface-info.txt" \
		"iw dev $IFACE info" \
		"$EDCA6G_IW" dev "$IFACE" info

	run_save "$_dir/ap-counters.txt" \
		"AP netdev counters for $IFACE" \
		counter_snapshot

	if [ -n "$EDCA_APPLY" ]; then
		run_save "$_dir/edca-apply.txt" \
			"edca_apply ($EDCA_APPLY)" cat "$EDCA_APPLY"
	else
		printf '# edca_apply: not present\n' >"$_dir/edca-apply.txt"
	fi

	run_save "$_dir/hostapd-edca.txt" \
		"effective hostapd EDCA lines${HOSTAPD_CONF:+ ($HOSTAPD_CONF)}" \
		hostapd_edca_lines "$HOSTAPD_CONF"

	run_save "$_dir/uci-edca.txt" \
		"uci tx_burst/tx_queue settings" \
		uci_edca_dump

	run_save "$_dir/token-info.txt" \
		"mt76 token_info${TOKEN_INFO:+ ($TOKEN_INFO)}" \
		cat "${TOKEN_INFO:-/nonexistent/token_info}"

	run_save "$_dir/tx-stats.txt" \
		"mt76 tx_stats${TX_STATS:+ ($TX_STATS)}" \
		cat "${TX_STATS:-/nonexistent/tx_stats}"
}

# shellcheck disable=SC2329  # called indirectly through run_save
uci_edca_dump() {
	"$EDCA6G_UCI" -q show wireless 2>/dev/null |
		grep -iE 'tx_burst|tx_queue_data' 2>/dev/null ||
		printf '# no tx_burst/tx_queue_data options in wireless UCI\n'
}

device_info() {
	local _fw
	printf 'hostname: %s\n' "$(uname -n 2>/dev/null || echo unknown)"
	printf 'kernel: %s\n' "$(uname -r 2>/dev/null || echo unknown)"
	printf 'iw: %s\n' "$("$EDCA6G_IW" --version 2>/dev/null | head -n 1)"
	printf 'iperf3: %s\n' "$("$EDCA6G_IPERF3" --version 2>/dev/null | head -n 1)"
	printf 'sta_model: %s\n' "$STA_MODEL"
	if command -v modinfo >/dev/null 2>&1; then
		printf 'mt7996e: %s\n' "$(modinfo -F version mt7996e 2>/dev/null || echo unknown)"
	fi
	for _fw in /lib/firmware/mediatek/mt7996/*.bin; do
		[ -f "$_fw" ] || continue
		printf 'firmware %s md5 %s\n' "${_fw##*/}" "$(md5_of "$_fw")"
	done
}

# ---------------------------------------------------------------------------
# waiting / restore

wait_ap() {
	local _i
	_i=0
	while [ "$_i" -lt "$ASSOC_TIMEOUT" ]; do
		[ "$(iface_type "$IFACE")" = AP ] && is_6g_freq "$(iface_freq "$IFACE")" &&
			return 0
		sleep 1
		_i=$((_i + 1))
	done
	return 1
}

wait_sta() {
	local _i
	_i=0
	while [ "$_i" -lt "$ASSOC_TIMEOUT" ]; do
		case " $(sta_macs "$IFACE" | tr '\n' ' ') " in
		*" $STATION "*)
			return 0
			;;
		esac
		sleep 1
		_i=$((_i + 1))
	done
	return 1
}

# restore_all: idempotent; called from the exit trap and at the normal end.
restore_all() {
	[ "$RESTORED" = 1 ] && return 0
	RESTORED=1
	trap '' INT TERM HUP

	say 'Restore: begin'
	RESTORE_OK=1

	if [ "$EDCA_WRITTEN" = 1 ] && [ -n "$EDCA_APPLY" ] && [ -f "$EDCA_BACKUP" ]; then
		log_cmd "cat $EDCA_BACKUP > $EDCA_APPLY"
		if cat "$EDCA_BACKUP" >"$EDCA_APPLY" 2>/dev/null; then
			if cmp -s "$EDCA_BACKUP" "$EDCA_APPLY"; then
				say "Restore: edca_apply content restored ($EDCA_APPLY)"
				EDCA_RESTORED=true
			else
				note "restore error: edca_apply content differs after restore"
				RESTORE_OK=0
				EDCA_RESTORED=false
			fi
		else
			note "restore error: cannot write $EDCA_APPLY"
			RESTORE_OK=0
			EDCA_RESTORED=false
		fi
	fi

	if [ "$HOSTAPD_CHANGED" = 1 ]; then
		log_cmd "cp $WIRELESS_BACKUP $EDCA6G_WIRELESS_CONF"
		if cmp -s "$WIRELESS_BACKUP" "$EDCA6G_WIRELESS_CONF"; then
			say 'Restore: wireless configuration already matches the backup'
		else
			cp "$WIRELESS_BACKUP" "$EDCA6G_WIRELESS_CONF" ||
				RESTORE_OK=0
		fi
		log_cmd "$EDCA6G_WIFI reload"
		"$EDCA6G_WIFI" reload 2>/dev/null || RESTORE_OK=0
		if wait_ap; then
			say 'Restore: wireless configuration and BSS reloaded'
			HOSTAPD_BURST_AFTER=
			if [ -n "$HOSTAPD_CONF" ] && [ -f "$HOSTAPD_CONF" ]; then
				HOSTAPD_BURST_AFTER=$(sed -n 's/^tx_queue_data2_burst=//p' "$HOSTAPD_CONF" 2>/dev/null |
					tail -n 1)
			fi
			if [ "$HOSTAPD_BURST_AFTER" != "$HOSTAPD_BURST_BEFORE" ]; then
				note "restore error: effective tx_queue_data2_burst changed ('$HOSTAPD_BURST_BEFORE' -> '$HOSTAPD_BURST_AFTER')"
				RESTORE_OK=0
			fi
			if wait_sta; then
				say "Restore: STA $STATION re-associated on $IFACE"
			else
				note "restore warning: STA $STATION did not re-associate within ${ASSOC_TIMEOUT}s"
			fi
		else
			note "restore error: $IFACE did not come back as a 6G AP"
			RESTORE_OK=0
		fi
	fi

	WIRELESS_MD5_AFTER=$(md5_of "$EDCA6G_WIRELESS_CONF")
	if [ "$HOSTAPD_CHANGED" = 1 ] && [ "$WIRELESS_MD5_BEFORE" != "$WIRELESS_MD5_AFTER" ]; then
		note "restore error: $EDCA6G_WIRELESS_CONF md5 changed ($WIRELESS_MD5_BEFORE -> $WIRELESS_MD5_AFTER)"
		RESTORE_OK=0
	fi
	if [ "$HOSTAPD_CHANGED" = 1 ] && command -v urg_restore_delta >/dev/null 2>&1; then
		urg_mark_dirty
		if ! urg_restore_delta; then
			note "restore error: could not restore the pending UCI delta $URG_DELTA"
			RESTORE_OK=0
		fi
	fi
	if [ "$RESTORE_OK" = 1 ]; then
		command -v urg_disarm >/dev/null 2>&1 && urg_disarm
		say 'Restore: ok'
	else
		note 'Restore: FAILED'
	fi
}

# ---------------------------------------------------------------------------
# arms

apply_arm() {
	case $MECHANISM in
	hostapd) apply_arm_hostapd "$1" ;;
	debugfs) apply_arm_debugfs "$1" ;;
	*) die "internal error: mechanism '$MECHANISM'" ;;
	esac
}

apply_arm_hostapd() {
	local _tu _burst _eff _applied
	_tu=$1
	_burst=$(tu_to_burst "$_tu")
	log_line "arm $_tu: hostapd tx_burst=$_burst (radio $RADIO_SECTION)"

	"$EDCA6G_UCI" -q set "wireless.$RADIO_SECTION.tx_burst=$_burst" ||
		die "uci set wireless.$RADIO_SECTION.tx_burst=$_burst failed"
	# Mark the config as dirty before commit: a signal after this point must
	# restore the backup even if the commit or reload does not finish.
	HOSTAPD_CHANGED=1
	"$EDCA6G_UCI" -q commit wireless ||
		die "uci commit wireless failed"

	log_cmd "$EDCA6G_WIFI reload"
	"$EDCA6G_WIFI" reload 2>/dev/null ||
		die "wifi reload failed after setting tx_burst=$_burst"
	wait_ap || die "$IFACE did not come back as a 6G AP after wifi reload"
	wait_sta || die "STA $STATION did not re-associate after wifi reload"
	sleep "$SETTLE"

	_refresh_hostapd_conf
	_eff=$(sed -n 's/^tx_queue_data2_burst=//p' "$HOSTAPD_CONF" 2>/dev/null | tail -n 1)
	case $_eff in
	'')
		# An absent line means hostapd's default burst of 0.  On an image
		# built before #18 the 6 GHz band never emitted the line at all, so
		# this is that image, not a bad value: say so instead of blaming
		# the request.
		[ "$_tu" = 0 ] ||
			die "hostapd did not emit tx_queue_data2_burst for requested $_tu TU; this image predates #18 (6 GHz band default) or the radio is not 6 GHz"
		;;
	*)
		_applied=$(burst_to_tu "$_eff") ||
			die "cannot parse effective tx_queue_data2_burst='$_eff'"
		if [ "$_applied" -ne "$_tu" ] && [ "$_tu" != 171 ]; then
			die "requested $_tu TU but hostapd applied $_applied TU (tx_queue_data2_burst=$_eff)"
		fi
		if [ "$_tu" = 171 ] && [ "$_applied" -ne 172 ]; then
			note "warning: 171 TU requested, hostapd applied $_applied TU (expected 172 with 5.5 ms)"
		fi
		;;
	esac
}

apply_arm_debugfs() {
	local _tu _readback _parsed
	_tu=$1
	[ -n "$EDCA_APPLY" ] || die "no edca_apply debugfs file"
	[ -w "$EDCA_APPLY" ] || die "$EDCA_APPLY is not writable (run as root?)"

	log_line "arm $_tu: writing $_tu to $EDCA_APPLY"
	log_cmd "printf '%s\\n' $_tu > $EDCA_APPLY"
	# Mark dirty before the write so the trap restores even a partial write.
	EDCA_WRITTEN=1
	printf '%s\n' "$_tu" >"$EDCA_APPLY" ||
		die "cannot write $_tu to $EDCA_APPLY"

	sleep "$SETTLE"

	_readback=$(edca_apply_read) ||
		die "cannot read back $EDCA_APPLY (the original value is needed for restore)"
	_parsed=$(parse_edca_txop "$_readback")
	if [ -n "$_parsed" ] && [ "$_parsed" -ne "$_tu" ]; then
		die "edca_apply readback '$_parsed' does not match requested $_tu TU"
	fi
}

# _refresh_hostapd_conf: resolve the generated hostapd conf and MT76 debugfs
# files for the current interface.
_refresh_hostapd_conf() {
	HOSTAPD_CONF=$(hostapd_conf_for_iface) ||
		HOSTAPD_CONF=$(find_hostapd_conf "$PHY_NAME") || true
	[ -n "${HOSTAPD_CONF:-}" ] || die "cannot find the generated hostapd configuration for $IFACE/$PHY_NAME"
}

# run_arm TU ROUND: measure one arm and append its JSON object.
run_arm() {
	local _tu _round _dir _before _after _tx_before _dump_before _sta_before _sta_tx_before _sta_retries_before _t0 _t1 _wall _rc _tx_after _dump _sta_after _sta_tx_after _sta_retries_after _valid _reason _sta_present _bps _bps_sent _retr _isecs _tx_delta _tx_rate _sta_tx_delta _sta_retries_delta _width _nss _signal _freq _edca_tu _raw _burst _applied _applied_source _gbps
	_tu=$1
	_round=${2:-1}
	_dir=$RESULT_DIR/arms/r$_round/$_tu
	_before=$_dir/before
	_after=$_dir/after

	say ''
	if [ "$ROUNDS" -gt 1 ]; then
		say "=== round $_round/$ROUNDS, arm $_tu TU ($((_tu * TU_US)) us BE TXOP) ==="
	else
		say "=== arm $_tu TU ($((_tu * TU_US)) us BE TXOP) ==="
	fi
	apply_arm "$_tu"

	# The STA must be present before we spend the measurement window.
	case " $(sta_macs "$IFACE" | tr '\n' ' ') " in
	*" $STATION "*) ;;
	*) die "STA $STATION is not associated on $IFACE before arm $_tu" ;;
	esac

	snapshot "$_before"

	_tx_before=$(counter_get "$IFACE" tx_bytes)
	_dump_before=$(sta_dump "$IFACE")
	_sta_before=$(sta_block "$_dump_before" "$STATION")
	_sta_tx_before=$(sta_field "$_sta_before" 'tx bytes')
	_sta_retries_before=$(sta_field "$_sta_before" 'tx retries')
	_t0=$(date +%s)

	log_cmd "$SOURCE"
	# Every arm runs the same source string through sh -c, so the default
	# iperf3 client and a --source are shaped the same way.
	TARGET=$TARGET DURATION=$DURATION PARALLEL=$PARALLEL sh -c "$SOURCE" \
		>"$_dir/iperf3.json" 2>"$_dir/iperf3.err"
	_rc=$?
	_t1=$(date +%s)
	_wall=$((_t1 - _t0))
	[ "$_wall" -gt 0 ] || _wall=1

	_tx_after=$(counter_get "$IFACE" tx_bytes)
	_dump=$(sta_dump "$IFACE")
	_sta_after=$(sta_block "$_dump" "$STATION")
	_sta_tx_after=$(sta_field "$_sta_after" 'tx bytes')
	_sta_retries_after=$(sta_field "$_sta_after" 'tx retries')

	snapshot "$_after"

	# ---------------------------------------------------------------- numbers
	_valid=true
	_reason=
	if [ "$_rc" -ne 0 ]; then
		_valid=false
		_reason="source exit $_rc"
	fi
	case " $(sta_macs "$IFACE" | tr '\n' ' ') " in
	*" $STATION "*) _sta_present=true ;;
	*)
		_sta_present=false
		_valid=false
		_reason="${_reason:+$_reason, }station disappeared"
		;;
	esac

	_bps=$(iperf3_field "$_dir/iperf3.json" sum_received bits_per_second)
	_bps_sent=$(iperf3_field "$_dir/iperf3.json" sum_sent bits_per_second)
	_retr=$(iperf3_field "$_dir/iperf3.json" sum_sent retransmits)
	_isecs=$(iperf3_field "$_dir/iperf3.json" sum_received seconds)
	[ -n "$_bps" ] || {
		_valid=false
		_reason="${_reason:+$_reason, }no iperf3 throughput"
	}

	_tx_delta=
	_tx_rate=
	if is_uint "$_tx_before" && is_uint "$_tx_after"; then
		_tx_delta=$((_tx_after - _tx_before))
		_tx_rate=$(awk -v b="$_tx_delta" -v s="$_wall" 'BEGIN { printf "%.3f", (b * 8) / s / 1e9 }')
	fi

	_sta_tx_delta=
	if is_uint "${_sta_tx_before:-}" && is_uint "${_sta_tx_after:-}"; then
		_sta_tx_delta=$((_sta_tx_after - _sta_tx_before))
	fi
	_sta_retries_delta=
	if is_uint "${_sta_retries_before:-}" && is_uint "${_sta_retries_after:-}"; then
		_sta_retries_delta=$((_sta_retries_after - _sta_retries_before))
	fi

	_width=$(sta_link_width "$_sta_after")
	_nss=$(sta_link_nss "$_sta_after")
	_signal=$(sta_signal "$_sta_after")
	_freq=$(iface_freq "$IFACE")

	# EDCA state after the arm.  The edca_apply readback is always recorded
	# as evidence; it is the applied value only for the debugfs mechanism,
	# because the hostapd path does not update that driver file.
	_edca_tu=
	if [ -n "$EDCA_APPLY" ] && [ -r "$EDCA_APPLY" ]; then
		_raw=$(edca_apply_read)
		_edca_tu=$(parse_edca_txop "$_raw")
	fi
	_burst=
	if [ -n "${HOSTAPD_CONF:-}" ] && [ -f "$HOSTAPD_CONF" ]; then
		_burst=$(sed -n 's/^tx_queue_data2_burst=//p' "$HOSTAPD_CONF" 2>/dev/null |
			tail -n 1)
	fi
	_applied=
	_applied_source=
	if [ "$MECHANISM" = debugfs ]; then
		if [ -n "$_edca_tu" ]; then
			_applied=$_edca_tu
			_applied_source=edca_apply
		else
			_applied=$_tu
			_applied_source=requested
		fi
	else
		if [ -n "$_burst" ]; then
			_applied=$(burst_to_tu "$_burst") || _applied=
			[ -n "$_applied" ] && _applied_source='hostapd-derived'
		elif [ "$_tu" = 0 ]; then
			_applied=0
			_applied_source='hostapd-default'
		else
			_applied=$_tu
			_applied_source='requested'
		fi
	fi

	# Fewer streams or a narrower link between arms make the A/B invalid.
	if [ -n "${REF_WIDTH:-}" ] && [ -n "$_width" ] && [ "$_width" != "$REF_WIDTH" ]; then
		_valid=false
		_reason="${_reason:+$_reason, }width changed ${REF_WIDTH}->${_width}MHz"
	fi
	if [ -n "${REF_NSS:-}" ] && [ -n "$_nss" ] && [ "$_nss" != "$REF_NSS" ]; then
		_valid=false
		_reason="${_reason:+$_reason, }NSS changed ${REF_NSS}->${_nss}"
	fi
	if [ "$_valid" = true ]; then
		[ -n "${REF_WIDTH:-}" ] || REF_WIDTH=$_width
		[ -n "${REF_NSS:-}" ] || REF_NSS=$_nss
	fi

	# ----------------------------------------------------------------- output
	_gbps=
	[ -n "$_bps" ] && _gbps=$(awk -v b="$_bps" 'BEGIN { printf "%.3f", b / 1e9 }')

	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$_round" "$_tu" "${_applied:-}" "${_applied_source:-unknown}" "${_burst:-}" \
		"${_tx_delta:-}" "${_gbps:-}" "$_wall" "${_retr:-}" \
		"${_width:-}" "${_nss:-}" "${_signal:-}" \
		"$_valid" "${_reason:-}" >>"$RESULT_DIR/summary.tsv"

	printf '  round %s, arm %s TU, applied %s (%s), hostapd burst %s\n' \
		"$_round" "$_tu" "${_applied:-?}" "${_applied_source:-?}" "${_burst:-absent}"
	printf '  iperf3: %s Gbit/s rx, %s Gbit/s sent, retransmits %s, %s s\n' \
		"${_gbps:-?}" "$(awk -v b="${_bps_sent:-0}" 'BEGIN { printf "%.3f", b / 1e9 }')" \
		"${_retr:-?}" "${_isecs:-$_wall}"
	printf '  AP tx bytes: %s (%s Gbit/s), station tx bytes: %s, retries: %s\n' \
		"${_tx_delta:-?}" "${_tx_rate:-?}" "${_sta_tx_delta:-?}" \
		"${_sta_retries_delta:-?}"
	printf '  link: %s MHz, NSS %s, signal %s dBm, freq %s MHz\n' \
		"${_width:-?}" "${_nss:-?}" "${_signal:-?}" "${_freq:-?}"
	printf '  valid: %s%s\n' "$_valid" "${_reason:+ ($_reason)}"

	append_arm_json "$_tu" "$_dir" "$_valid" "${_reason:-}" "$_applied" \
		"${_applied_source:-}" "$_burst" "$_bps" "$_bps_sent" "$_retr" \
		"${_isecs:-}" "$_gbps" "$_tx_delta" "$_tx_rate" "$_sta_tx_delta" \
		"$_sta_retries_delta" "$_width" "$_nss" "$_signal" "$_freq" \
		"$_sta_present" "$_wall" "$_rc" "${_edca_tu:-}" "$_round"

	[ "$_valid" = true ] || {
		say ''
		say "Arm $_tu is invalid: $_reason"
		say 'Stopping so the remaining arms run under the same conditions.'
		exit 1
	}
}

iperf3_field() { # file object field
	# Split on "}" so one object (which may be on one line or several) is a
	# single awk record; then take the first value of FIELD inside KEY.
	awk -v key="$2" -v field="$3" '
		BEGIN { RS = "}" }
		index($0, "\"" key "\":") {
			re = "\"" field "\"[ \t]*:[ \t]*[-0-9.eE+]+"
			if (match($0, re)) {
				s = substr($0, RSTART, RLENGTH)
				sub(/.*:[ \t]*/, "", s)
				print s
				exit
			}
		}
	' "$1"
}

append_arm_json() {
	local _tu _dir _valid _reason _applied _source _burst _bps _bps_sent _retr _isecs _gbps _tx_delta _tx_rate _sta_tx_delta _sta_retries _width _nss _signal _freq _present _wall _rc _edca_tu _round _rel _present_json _valid_json
	_tu=$1
	_dir=$2
	_valid=$3
	_reason=$4
	_applied=$5
	_source=$6
	_burst=$7
	_bps=$8
	_bps_sent=$9
	_retr=${10}
	_isecs=${11}
	_gbps=${12}
	_tx_delta=${13}
	_tx_rate=${14}
	_sta_tx_delta=${15}
	_sta_retries=${16}
	_width=${17}
	_nss=${18}
	_signal=${19}
	_freq=${20}
	_present=${21}
	_wall=${22}
	_rc=${23}
	_edca_tu=${24:-}
	_round=${25:-1}

	_rel=${_dir#"$RESULT_DIR"/}
	[ "$_present" = true ] && _present_json=true || _present_json=false
	[ "$_valid" = true ] && _valid_json=true || _valid_json=false

	{
		printf '{"arm": %s' "$_tu"
		printf ', "round": %s' "$(json_num "$_round")"
		printf ', "requested_tu": %s' "$_tu"
		printf ', "applied_tu": %s' "$(json_num "$_applied")"
		printf ', "applied_source": %s' "$(json_str "${_source:-unknown}")"
		printf ', "hostapd_tx_burst": %s' "$(json_str "${_burst:-}")"
		printf ', "edca_apply_tu": %s' "$(json_num "$_edca_tu")"
		printf ', "iperf3": {"ok": %s, "exit_status": %s' \
			"$_valid_json" "$_rc"
		printf ', "bits_per_second": %s' "$(json_num "$_bps")"
		printf ', "bits_per_second_sent": %s' "$(json_num "$_bps_sent")"
		printf ', "retransmits": %s' "$(json_num "$_retr")"
		printf ', "seconds": %s' "$(json_num "$_isecs")"
		printf ', "gbps": %s' "$(json_num "$_gbps")"
		printf ', "wall_seconds": %s' "$_wall"
		printf ', "json": %s}' "$(json_str "$_rel/iperf3.json")"
		printf ', "ap": {"tx_bytes": %s' "$(json_num "$_tx_delta")"
		printf ', "tx_gbps": %s' "$(json_num "$_tx_rate")"
		printf ', "station_tx_bytes": %s' "$(json_num "$_sta_tx_delta")"
		printf ', "station_tx_retries": %s}' "$(json_num "$_sta_retries")"
		printf ', "link": {"sta_present": %s' "$_present_json"
		printf ', "freq_mhz": %s' "$(json_num "$_freq")"
		printf ', "width_mhz": %s' "$(json_num "$_width")"
		printf ', "nss": %s' "$(json_num "$_nss")"
		printf ', "signal_dbm": %s}' "$(json_num "$_signal")"
		printf ', "valid": %s' "$_valid_json"
		if [ -n "$_reason" ]; then
			printf ', "invalid_reason": %s' "$(json_str "$_reason")"
		else
			printf ', "invalid_reason": null'
		fi
		printf ', "snapshots": {"before": %s, "after": %s}}' \
			"$(json_str "$_rel/before")" "$(json_str "$_rel/after")"
		printf '\n'
	} >>"$RESULT_DIR/arms.jsonl"
}

# aggregate_arms: per arm, the median, minimum, maximum and range of the
# Gbit/s values measured across the rounds, as tab separated
# "arm median min max range n".  Arms are in first-seen order.  Values are
# already rounded to three decimals by the per-arm record, so they are
# reused as-is: the aggregate never invents precision.  An arm with no
# numeric measurement prints nothing.
aggregate_arms() {
	[ -f "$RESULT_DIR/arms.jsonl" ] || return 0
	awk '
		{
			if (!match($0, /"arm": [0-9]+/))
				next
			arm = substr($0, RSTART + 7, RLENGTH - 7) + 0
			if (!match($0, /"gbps": [-0-9.eE+]+/))
				next
			v = substr($0, RSTART + 8, RLENGTH - 8) + 0
			if (n[arm] == 0)
				order[++seen] = arm
			val[arm, ++n[arm]] = v
		}
		END {
			for (k = 1; k <= seen; k++) {
				arm = order[k]
				m = n[arm]
				for (i = 1; i <= m; i++)
					srt[i] = val[arm, i]
				for (i = 2; i <= m; i++) {
					t = srt[i]
					for (j = i - 1; j >= 1 && srt[j] > t; j--)
						srt[j + 1] = srt[j]
					srt[j + 1] = t
				}
				if (m % 2)
					med = srt[(m + 1) / 2]
				else
					med = (srt[m / 2] + srt[m / 2 + 1]) / 2
				printf "%d\t%.3f\t%.3f\t%.3f\t%.3f\t%d\n",
					arm, med, srt[1], srt[m], srt[m] - srt[1], m
			}
		}
	' "$RESULT_DIR/arms.jsonl"
}

# aggregate_arms_json: the same numbers as ready-made JSON objects, one per
# line, for result.json.
aggregate_arms_json() {
	aggregate_arms | while IFS='	' read -r _a _med _min _max _rng _n; do
		[ -n "$_a" ] || continue
		printf '{"arm": %s, "n": %s, "gbps_median": %s, "gbps_min": %s, "gbps_max": %s, "gbps_range": %s}' \
			"$_a" "$_n" "$_med" "$_min" "$_max" "$_rng"
		printf '\n'
	done
}

# ---------------------------------------------------------------------------
# result files

# shellcheck disable=SC2329  # called from the exit trap
write_result() { # rc
	local _rc _ts _ok _line _first _agg _edca_restored_json
	_rc=$1
	_ts=$(now_ts)
	_ok=false
	[ "$_rc" -eq 0 ] && [ "$RESTORE_OK" = 1 ] && _ok=true

	{
		printf '{\n'
		printf '  "schema": "edca-6g-ab/v1",\n'
		printf '  "timestamp": %s,\n' "$(json_str "$_ts")"
		printf '  "device": {"hostname": %s' "$(json_str "$(uname -n 2>/dev/null || echo unknown)")"
		printf ', "kernel": %s' "$(json_str "$(uname -r 2>/dev/null || echo unknown)")"
		printf ', "iw": %s' "$(json_str "$("$EDCA6G_IW" --version 2>/dev/null | head -n 1)")"
		printf ', "iperf3": %s}' "$(json_str "$("$EDCA6G_IPERF3" --version 2>/dev/null | head -n 1)")"
		printf ',\n  "ap": {"iface": %s' "$(json_str "$IFACE")"
		printf ', "phy": %s' "$(json_str "${PHY_NAME:-}")"
		printf ', "radio": %s' "$(json_str "${RADIO_SECTION:-}")"
		printf ', "hostapd_conf": %s' "$(json_str "${HOSTAPD_CONF:-}")"
		printf ', "freq_mhz": %s}' "$(json_num "$(iface_freq "$IFACE")")"
		printf ',\n  "sta": {"mac": %s' "$(json_str "$STATION")"
		printf ', "model": %s' "$(json_str "$STA_MODEL")"
		printf ', "target": %s}' "$(json_str "$TARGET")"
		printf ',\n  "mechanism": %s' "$(json_str "$MECHANISM")"
		printf ',\n  "arms": [\n'
		_first=1
		if [ -f "$RESULT_DIR/arms.jsonl" ]; then
			while IFS= read -r _line; do
				[ -n "$_line" ] || continue
				if [ "$_first" = 1 ]; then
					_first=0
				else
					printf ',\n'
				fi
				printf '%s' "$_line"
			done <"$RESULT_DIR/arms.jsonl"
		fi
		printf '\n  ],\n'
		printf '  "rounds": %s,\n' "$(json_num "$ROUNDS")"
		printf '  "cooldown_s": %s,\n' "$(json_num "$COOLDOWN")"
		printf '  "rounds_timeline": [\n'
		_first=1
		if [ -f "$RESULT_DIR/rounds.jsonl" ]; then
			while IFS= read -r _line; do
				[ -n "$_line" ] || continue
				if [ "$_first" = 1 ]; then
					_first=0
				else
					printf ',\n'
				fi
				printf '%s' "$_line"
			done <"$RESULT_DIR/rounds.jsonl"
		fi
		printf '\n  ],\n'
		printf '  "aggregate": [\n'
		_first=1
		aggregate_arms_json | while IFS= read -r _agg; do
			[ -n "$_agg" ] || continue
			if [ "$_first" = 1 ]; then
				_first=0
			else
				printf ',\n'
			fi
			printf '%s' "$_agg"
		done
		printf '\n  ],\n'
		printf '  "restore": {"ok": %s' "$([ "$RESTORE_OK" = 1 ] && echo true || echo false)"
		printf ', "wireless_md5_before": %s' "$(json_str "$WIRELESS_MD5_BEFORE")"
		printf ', "wireless_md5_after": %s' "$(json_str "$WIRELESS_MD5_AFTER")"
		printf ', "wireless_changed": %s' "$([ "$HOSTAPD_CHANGED" = 1 ] && echo true || echo false)"
		printf ', "hostapd_tx_burst_before": %s' "$(json_str "$HOSTAPD_BURST_BEFORE")"
		printf ', "hostapd_tx_burst_after": %s' "$(json_str "${HOSTAPD_BURST_AFTER:-}")"
		printf ', "edca_apply": %s' "$(json_str "$EDCA_APPLY")"
		case ${EDCA_RESTORED:-none} in
		true) _edca_restored_json=true ;;
		false) _edca_restored_json=false ;;
		*) _edca_restored_json=null ;;
		esac
		printf ', "edca_apply_restored": %s}' "$_edca_restored_json"
		printf ',\n  "ok": %s\n' "$_ok"
		printf '}\n'
	} >"$RESULT_DIR/result.json.tmp" ||
		die "cannot write $RESULT_DIR/result.json.tmp"

	if command -v jq >/dev/null 2>&1; then
		jq -e . "$RESULT_DIR/result.json.tmp" >/dev/null 2>&1 ||
			note "warning: generated result.json is not valid JSON"
	fi
	mv "$RESULT_DIR/result.json.tmp" "$RESULT_DIR/result.json" ||
		die "cannot move result.json into place"
}

# bss_owner_note: the 6G-only BSS lifecycle belongs to 6g-only.sh (#46).
# shellcheck disable=SC2329  # called from the exit trap
bss_owner_note() {
	[ -f "$EDCA6G_WIRELESS_CONF" ] || return 0
	grep -q '^# >>> 6g-only: BEGIN' "$EDCA6G_WIRELESS_CONF" 2>/dev/null || return 0
	say ''
	say 'Note: the 6G-only BSS from scripts/wireless/6g-only.sh is still in place.'
	say '      Remove it with: scripts/wireless/6g-only.sh --remove'
}

# shellcheck disable=SC2329  # installed with trap
on_exit() {
	local _rc
	_rc=$1
	trap '' INT TERM HUP EXIT
	if [ "$RESTORED" != 1 ]; then
		restore_all
	fi
	bss_owner_note
	[ "$RESTORE_OK" = 1 ] || [ "$_rc" -ne 0 ] || _rc=1
	if [ -n "${RESULT_DIR:-}" ] && [ -d "${RESULT_DIR:-}" ]; then
		if [ -f "$RESULT_DIR/summary.tsv" ]; then
			say ''
			say 'Arm summary:'
			printf '  %-5s %-5s %-8s %-16s %-7s %-10s %-7s %-6s %-6s %-5s %-5s %s\n' \
				round arm applied source burst tx_bytes gbps retr width nss valid reason
			awk -F '\t' '
				NR > 1 { printf "  %-5s %-5s %-8s %-16s %-7s %-10s %-7s %-6s %-6s %-5s %-5s %s\n",
					$1, $2, $3, $4, $5, $6, $7, $9, $10, $11, $13, $14 }' \
				"$RESULT_DIR/summary.tsv"
			if [ "$ROUNDS" -gt 1 ]; then
				say ''
				say "Per-arm aggregate over $ROUNDS rounds:"
				printf '  %-5s %-3s %-8s %-8s %-8s %s\n' \
					arm n median min max range
				aggregate_arms | awk -F '\t' '
					{ printf "  %-5s %-3s %-8s %-8s %-8s %s\n",
						$1, $6, $2, $3, $4, $5 }'
			fi
		fi
		write_result "$_rc" 2>/dev/null || true
		say "Result: $RESULT_DIR/result.json"
	fi
	# Release after the restore reload, so the hold covers the rollback too.
	nw_guard_cleanup
	exit "$_rc"
}

# ---------------------------------------------------------------------------
# dry run

dry_run_plan() {
	cat <<EOF
edca-6g-ab.sh dry run - no command is executed and nothing is written.

Arms (fixed): 0, 63, 171 EDCA time units of 32 us -> 0, 2016, 5472 us.
Each arm uses the same iperf3 source, with the AP as client:

  iperf3 -c ${TARGET:-<required>} -t $DURATION -P $PARALLEL -J

A --source replaces that line in every arm (same sh -c, same environment).

Inputs:
  AP interface   ${IFACE:-<auto-detect 6G AP>}
  STA MAC        ${STATION:-<auto-detect one 6G STA>}
  UCI radio      ${RADIO:-<auto-detect from the AP phy>}
  STA model      $STA_MODEL
  rounds         $ROUNDS (cooldown ${COOLDOWN}s between rounds)
  result dir     ${RESULT_DIR:-./edca-6g-ab-<epoch>}
  mechanism      $MECHANISM
  edca_apply     ${EDCA_APPLY:-<auto-detect /sys/kernel/debug/ieee80211/phy*/mt76/edca_apply>}

Mechanism plan:
  hostapd  uci set wireless.<radio>.tx_burst=<0|2.0|5.5>
           uci commit wireless
           wifi reload
           (the STA re-associates before each arm; 171 TU is applied as 172)
  debugfs  write <0|63|171> to the edca_apply file, read it back
           (exact values, no re-association; used only when the file exists
           or --edca-apply is given)

Per-arm evidence:
  iw dev <iface> station dump, iw dev <iface> info, AP tx bytes,
  edca_apply, hostapd tx_queue_data* lines, uci tx_burst, token_info,
  tx_stats, iperf3 JSON.

Repeats:
  the arm sequence is replayed $ROUNDS time(s) in the same order, $COOLDOWN s
  apart; every round is recorded with its start and end stamp, and the
  median/min/max/range per arm is reported across rounds.

Restore:
  the original /etc/config/wireless (md5 checked, wifi reload) and the
  original edca_apply content, from an EXIT/INT/TERM/HUP trap.

No-STA behaviour: "SKIP: no 6G STA", exit 0, no writes.  A missing iperf3
is the same clean skip once a STA exists: "SKIP: iperf3 not found on the
AP", exit 0.  Both write the reason to result.json when --result-dir was
given.
Exit status: 0 success/skip, 1 runtime failure, 2 bad usage.
EOF
}

# ---------------------------------------------------------------------------
# main

while [ "$#" -gt 0 ]; do
	case $1 in
	-h | --help)
		usage
		exit 0
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--target)
		[ "$#" -ge 2 ] || usage_error '--target requires a value'
		TARGET=$2
		shift 2
		;;
	--target=*)
		TARGET=${1#*=}
		shift
		;;
	--iface)
		[ "$#" -ge 2 ] || usage_error '--iface requires a value'
		IFACE=$2
		shift 2
		;;
	--iface=*)
		IFACE=${1#*=}
		shift
		;;
	--sta)
		[ "$#" -ge 2 ] || usage_error '--sta requires a value'
		STATION=$2
		shift 2
		;;
	--sta=*)
		STATION=${1#*=}
		shift
		;;
	--radio)
		[ "$#" -ge 2 ] || usage_error '--radio requires a value'
		RADIO=$2
		shift 2
		;;
	--radio=*)
		RADIO=${1#*=}
		shift
		;;
	--sta-model)
		[ "$#" -ge 2 ] || usage_error '--sta-model requires a value'
		STA_MODEL=$2
		shift 2
		;;
	--sta-model=*)
		STA_MODEL=${1#*=}
		shift
		;;
	--duration)
		[ "$#" -ge 2 ] || usage_error '--duration requires a value'
		DURATION=$2
		shift 2
		;;
	--duration=*)
		DURATION=${1#*=}
		shift
		;;
	--parallel)
		[ "$#" -ge 2 ] || usage_error '--parallel requires a value'
		PARALLEL=$2
		shift 2
		;;
	--parallel=*)
		PARALLEL=${1#*=}
		shift
		;;
	--source)
		[ "$#" -ge 2 ] || usage_error '--source requires a value'
		SOURCE=$2
		shift 2
		;;
	--source=*)
		SOURCE=${1#*=}
		shift
		;;
	--settle)
		[ "$#" -ge 2 ] || usage_error '--settle requires a value'
		SETTLE=$2
		shift 2
		;;
	--settle=*)
		SETTLE=${1#*=}
		shift
		;;
	--rounds)
		[ "$#" -ge 2 ] || usage_error '--rounds requires a value'
		ROUNDS=$2
		shift 2
		;;
	--rounds=*)
		ROUNDS=${1#*=}
		shift
		;;
	--cooldown)
		[ "$#" -ge 2 ] || usage_error '--cooldown requires a value'
		COOLDOWN=$2
		shift 2
		;;
	--cooldown=*)
		COOLDOWN=${1#*=}
		shift
		;;
	--assoc-timeout)
		[ "$#" -ge 2 ] || usage_error '--assoc-timeout requires a value'
		ASSOC_TIMEOUT=$2
		shift 2
		;;
	--assoc-timeout=*)
		ASSOC_TIMEOUT=${1#*=}
		shift
		;;
	--result-dir)
		[ "$#" -ge 2 ] || usage_error '--result-dir requires a value'
		RESULT_DIR=$2
		shift 2
		;;
	--result-dir=*)
		RESULT_DIR=${1#*=}
		shift
		;;
	--mechanism)
		[ "$#" -ge 2 ] || usage_error '--mechanism requires a value'
		MECHANISM=$2
		shift 2
		;;
	--mechanism=*)
		MECHANISM=${1#*=}
		shift
		;;
	--edca-apply)
		[ "$#" -ge 2 ] || usage_error '--edca-apply requires a value'
		EDCA_APPLY=$2
		EDCA_APPLY_EXPLICIT=1
		shift 2
		;;
	--edca-apply=*)
		EDCA_APPLY=${1#*=}
		EDCA_APPLY_EXPLICIT=1
		shift
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
[ "$#" -eq 0 ] || usage_error "unexpected argument: $1"

require_uint DURATION "$DURATION" 1
require_uint PARALLEL "$PARALLEL" 1
require_uint SETTLE "$SETTLE" 0
require_uint ROUNDS "$ROUNDS" 1
require_uint COOLDOWN "$COOLDOWN" 0
require_uint ASSOC_TIMEOUT "$ASSOC_TIMEOUT" 1
case $MECHANISM in
auto | hostapd | debugfs) ;;
*) usage_error "--mechanism must be auto, hostapd or debugfs, got '$MECHANISM'" ;;
esac
[ -n "$STATION" ] && STATION=$(normalize_mac "$STATION")
if [ -n "$STATION" ] &&
	! printf '%s\n' "$STATION" | grep -Eq '^([0-9a-f][0-9a-f]:){5}[0-9a-f][0-9a-f]$'; then
	usage_error "invalid station MAC '$STATION'"
fi

if [ "$DRY_RUN" = 1 ]; then
	dry_run_plan
	exit 0
fi

# ---------------------------------------------------------------------------
# preflight: reads only, no configuration write until a STA is confirmed.
#
# Order matters: the hardware gate comes first.  A harness with no 6G STA is a
# clean skip, so a missing iperf3 (or any other measurement tool) may not turn
# that skip into a failure before the STA has even been looked for.

command -v "$EDCA6G_IW" >/dev/null 2>&1 ||
	die "'$EDCA6G_IW' not found; install iw"

discover_6g_sta || skip_no_client 'no 6G STA'
IFACE=$DISCOVERED_IFACE
STATION=$DISCOVERED_STA
validate_6g_only_iface "$IFACE" "$STATION"

[ -n "$TARGET" ] || usage_error '--target is required for a real run (the STA must run iperf3 -s)'
[ -n "$IFACE" ] || usage_error 'no 6G AP interface found'

# The measurement tool is checked only now that a STA exists: without a STA
# there is nothing to measure, so its absence is a skip (exit 0), not a
# runtime failure (exit 1).  A --source replaces the iperf3 client, so a host
# without iperf3 still measures when one is given; otherwise the gap is
# recorded for hw-gap-report.sh.
if [ -z "$SOURCE" ] && command -v "$EDCA6G_IPERF3" >/dev/null 2>&1; then
	# shellcheck disable=SC2016  # expands in the per-arm "sh -c"
	SOURCE="$EDCA6G_IPERF3"' -c "$TARGET" -t "$DURATION" -P "$PARALLEL" -J'
fi
[ -n "$SOURCE" ] ||
	skip_no_tool "iperf3 not found on the AP ('$EDCA6G_IPERF3') and no --source was given"

PHY_NAME=$(iface_phy_name "$IFACE") ||
	die "cannot determine the phy of $IFACE"

# Debugfs evidence for the AP phy.  An explicit --edca-apply wins; otherwise
# the 0019 file is looked up under the phy's mt76 directory first.
if [ -n "$EDCA_APPLY" ]; then
	[ -e "$EDCA_APPLY" ] || die "$EDCA_APPLY does not exist"
else
	for _f in "$EDCA6G_DEBUGFS/$PHY_NAME/mt76/edca_apply" \
		"$EDCA6G_DEBUGFS"/phy*/mt76/edca_apply; do
		[ -f "$_f" ] || continue
		EDCA_APPLY=$_f
		break
	done
fi
for _f in "$EDCA6G_DEBUGFS/$PHY_NAME/mt76/token_info" \
	"$EDCA6G_DEBUGFS"/phy*/mt76/token_info; do
	[ -f "$_f" ] && TOKEN_INFO=$_f && break
done
for _f in "$EDCA6G_DEBUGFS/$PHY_NAME/mt76/tx_stats" \
	"$EDCA6G_DEBUGFS"/phy*/mt76/tx_stats; do
	[ -f "$_f" ] && TX_STATS=$_f && break
done

# Choose the set mechanism.  auto uses the 0019 edca_apply path when it is
# present (exact 32 us values, no re-association), otherwise hostapd.
if [ "$MECHANISM" = auto ]; then
	if [ "$EDCA_APPLY_EXPLICIT" = 1 ]; then
		MECHANISM=debugfs
	elif [ -n "$EDCA_APPLY" ] && [ -r "$EDCA_APPLY" ] && [ -w "$EDCA_APPLY" ]; then
		MECHANISM=debugfs
	else
		MECHANISM=hostapd
	fi
fi

# Resolve the UCI radio section for the hostapd mechanism.
if [ "$MECHANISM" = hostapd ]; then
	if [ -n "$RADIO" ]; then
		RADIO_SECTION=$RADIO
		[ -n "$(uci_get "$RADIO_SECTION.device")$(uci_get "$RADIO_SECTION.phy")$(uci_get "$RADIO_SECTION.band")" ] ||
			usage_error "wireless.$RADIO_SECTION is not a wifi-device section"
	else
		RADIO_SECTION=$(radio_for_phy "$PHY_NAME") ||
			usage_error "cannot map $PHY_NAME to a UCI wifi-device section; use --radio"
	fi
fi

case $MECHANISM in
debugfs)
	[ -n "$EDCA_APPLY" ] ||
		die 'no edca_apply debugfs file found and --mechanism debugfs was requested'
	[ -r "$EDCA_APPLY" ] ||
		die "$EDCA_APPLY is not readable; the original value is needed for restore"
	[ -w "$EDCA_APPLY" ] || die "$EDCA_APPLY is not writable (run as root?)"
	;;
hostapd)
	command -v "$EDCA6G_UCI" >/dev/null 2>&1 ||
		die "'$EDCA6G_UCI' not found; install uci"
	command -v "$EDCA6G_WIFI" >/dev/null 2>&1 ||
		die "'$EDCA6G_WIFI' not found; use --mechanism debugfs instead"
	[ -f "$EDCA6G_WIRELESS_CONF" ] ||
		die "$EDCA6G_WIRELESS_CONF not found"
	[ -n "${RADIO_SECTION:-}" ] || die 'no UCI radio section resolved'
	;;
esac

[ -n "$RESULT_DIR" ] || RESULT_DIR=./edca-6g-ab-$(date +%s)
[ -e "$RESULT_DIR/result.json" ] &&
	usage_error "refusing to overwrite $RESULT_DIR/result.json (use a new --result-dir)"

HOSTAPD_CONF=$(hostapd_conf_for_iface) ||
	HOSTAPD_CONF=$(find_hostapd_conf "$PHY_NAME") || HOSTAPD_CONF=
HOSTAPD_BURST_BEFORE=
if [ -n "$HOSTAPD_CONF" ] && [ -f "$HOSTAPD_CONF" ]; then
	HOSTAPD_BURST_BEFORE=$(sed -n 's/^tx_queue_data2_burst=//p' "$HOSTAPD_CONF" 2>/dev/null |
		tail -n 1)
	if grep -q '^mld_ap=1$' "$HOSTAPD_CONF"; then
		die "the AP BSS is an MLD (mld_ap=1); a 6G-only BSS is required"
	fi
fi

# ---------------------------------------------------------------------------
# setup: this is the first write.  Everything above is read-only.

mkdir -p "$RESULT_DIR/backup" "$RESULT_DIR/arms" ||
	die "cannot create $RESULT_DIR"
RAW_LOG=$RESULT_DIR/raw.log
: >"$RAW_LOG" || die "cannot write $RAW_LOG"

RESTORED=0
RESTORE_OK=1
HOSTAPD_CHANGED=0
EDCA_WRITTEN=0
EDCA_RESTORED=none
WIRELESS_MD5_BEFORE=
WIRELESS_MD5_AFTER=
WIRELESS_BACKUP=$RESULT_DIR/backup/wireless
EDCA_BACKUP=$RESULT_DIR/backup/edca_apply
REF_WIDTH=
REF_NSS=

if [ -f "$EDCA6G_WIRELESS_CONF" ]; then
	WIRELESS_MD5_BEFORE=$(md5_of "$EDCA6G_WIRELESS_CONF")
	cp "$EDCA6G_WIRELESS_CONF" "$WIRELESS_BACKUP" ||
		die "cannot back up $EDCA6G_WIRELESS_CONF"
	WIRELESS_MD5_AFTER=$WIRELESS_MD5_BEFORE
fi
if [ -n "$EDCA_APPLY" ] && [ -r "$EDCA_APPLY" ]; then
	cp "$EDCA_APPLY" "$EDCA_BACKUP" ||
		die "cannot back up $EDCA_APPLY"
fi

# Second restore point outside the (tmpfs) result directory, plus the pending
# UCI delta the hostapd arm is about to touch.
if [ -f "$EDCA6G_WIRELESS_CONF" ] && command -v urg_init >/dev/null 2>&1; then
	urg_init edca-6g-ab "$EDCA6G_WIRELESS_CONF" >/dev/null ||
		die "cannot create the restore point for $EDCA6G_WIRELESS_CONF"
fi

trap 'on_exit $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

nw_guard_init --apply --no-trap --label edca-6g-ab \
	--result-json "$RESULT_DIR/netwatchdog.json"
nw_guard_take ||
	die "cannot take the netwatchdog hold; refusing to change EDCA.  Install netwatchdog, or set NWD_ALLOW_NO_SERVICE=1 for a run that expects no protection."

say "6G EDCA A/B: AP $IFACE (phy $PHY_NAME), STA $STATION, target ${TARGET:-?}"
say "Mechanism: $MECHANISM${RADIO_SECTION:+ (radio $RADIO_SECTION)}; arms $ARMS TU"
say "Rounds: $ROUNDS (cooldown ${COOLDOWN}s between rounds)"
say "Result directory: $RESULT_DIR"
log_line "start: iface=$IFACE sta=$STATION target=$TARGET mechanism=$MECHANISM"
log_line "phy=$PHY_NAME radio=${RADIO_SECTION:-} edca_apply=${EDCA_APPLY:-none} hostapd=${HOSTAPD_CONF:-none}"
device_info >"$RESULT_DIR/device.txt" 2>&1 || true

if [ "$(id -u 2>/dev/null || echo unknown)" != 0 ]; then
	note 'warning: not running as root; wifi reload or debugfs writes may fail'
fi

printf 'round\tarm\tapplied\tsource\thostapd_burst\tap_tx_bytes\tgbps\twall_s\tretries\twidth_mhz\tnss\tsignal_dbm\tvalid\treason\n' \
	>"$RESULT_DIR/summary.tsv"

# Baseline evidence, before the first EDCA change.
snapshot "$RESULT_DIR/baseline"

# The arm sequence is repeated unchanged in every round, so round r is a
# replicate of round 1.  A cool-down separates the rounds; there is none
# before the first one.
_round=1
while [ "$_round" -le "$ROUNDS" ]; do
	_round_start=$(now_ts)
	if [ "$ROUNDS" -gt 1 ]; then
		say ''
		say "=== round $_round/$ROUNDS (arms $ARMS) ==="
	fi
	_round_arms=
	for _arm in $ARMS; do
		run_arm "$_arm" "$_round"
		_round_arms="${_round_arms:+$_round_arms, }$_arm"
	done
	_round_end=$(now_ts)
	{
		printf '{"round": %s, "started": %s, "ended": %s' \
			"$_round" "$(json_str "$_round_start")" "$(json_str "$_round_end")"
		printf ', "arms": [%s], "cooldown_s": %s' "$_round_arms" \
			"$(json_num "$COOLDOWN")"
		printf '}\n'
	} >>"$RESULT_DIR/rounds.jsonl"
	log_line "round $_round/$ROUNDS: $_round_start .. $_round_end"
	if [ "$_round" -lt "$ROUNDS" ]; then
		say "Cool-down ${COOLDOWN}s before round $((_round + 1))"
		sleep "$COOLDOWN"
	fi
	_round=$((_round + 1))
done

# Normal end: restore explicitly so the summary can report it.
restore_all
if [ "$RESTORE_OK" != 1 ]; then
	exit 1
fi
exit 0
