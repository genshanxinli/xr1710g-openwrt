#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# 6g-clear-air.sh - 6 GHz clear-air vs 5G/2.4 GHz loaded A/B harness.
#
# Why this exists: the community report "5G loading halves 6G" cannot be
# tested from the 6G side alone.  The next discriminator after the empty
# 6G-only BSS test is to run exactly the same 6G traffic twice: once with
# the 5 GHz and 2.4 GHz SSIDs disabled (the clear arm), and once with the
# normal multi-band configuration restored (the loaded arm).
#
# Protocol (fixed so the two arms are comparable):
#
#   1. Look up one 6 GHz AP BSS that already has a station associated and
#      select that station.  If no station is associated on any 6 GHz AP
#      BSS, print exactly "SKIP: no 6G STA" and exit 0 before writing any
#      configuration.
#   2. Save /etc/config/wireless (whole file, md5 and the radio0/radio1/
#      radio2 sections) and the live iw state.
#   3. Clear arm: disable every AP wifi-iface on radio0 and radio1 by
#      setting option disabled '1'.  The wifi-device sections are not
#      touched, so the radios stay configured; only their SSIDs go away.
#      The 6 GHz BSS that carries the STA remains, so the selected SSID is
#      now served only on 6 GHz.  wifi reload, wait for the STA to
#      re-associate, then measure.
#   4. Loaded arm: copy the saved pre-clear configuration back (all SSIDs
#      enabled again), wifi reload, wait for the same STA, measure.
#   5. Print one row per arm and the clear -> loaded delta, restore the
#      original /etc/config/wireless from the backup in the trap, verify
#      the md5 is byte-identical, and verify the radio sections did not
#      change.
#
# The 6G-only BSS:
#
#   A measured run always looks the BSS up, because a 6G STA cannot be
#   associated without one.  It prefers the SSID passed with --ssid (the
#   default is the dedicated 6g-clear-air BSS), then any BSS that is
#   already 6 GHz-only, then the BSS that carries the station.
#
#   --create-bss is the bootstrap path for the case where no 6G STA is
#   associated yet: it appends a marked 6 GHz-only BSS (SAE, PMF, same
#   radio/channel as the 6G radio), reloads Wi-Fi, prints the SSID and key
#   and waits for the STA to associate.  The block is removed again by the
#   trap.  This mode writes configuration before the STA check, so it is
#   explicit; without it a no-STA run never touches the config.
#
# The same source is used in both arms, in both directions:
#
#   AP -> STA: iperf3 -c STA_IP -t DURATION -p PORT -P PARALLEL -J
#   STA -> AP: iperf3 -c STA_IP -t DURATION -p PORT -P PARALLEL -J -R
#
#   The AP is always the iperf3 client.  The 6G STA must run
#   "iperf3 -s -p PORT" (the default port is 5201) and must be reachable
#   at --target.  The commands are constructed once and logged; the clear
#   and loaded arms use the identical arguments.
#
# Recorded for every direction of every arm:
#
#   iw dev <iface> station dump       raw before/after, plus deltas of
#                                     tx/rx bytes, tx/rx packets, tx
#                                     retries, tx failed, rx drop misc,
#                                     signal, tx/rx bitrate and connected
#                                     time
#   AP netdev counters                /sys/class/net/<iface>/statistics/
#                                     tx_bytes, rx_bytes, tx_packets,
#                                     rx_packets, tx_errors, rx_errors,
#                                     tx_dropped, rx_dropped (deltas)
#   mt76 token_info                   raw before/after and the token_count,
#                                     wed_token_count, rx_token_size and
#                                     npu_rx0/npu_rx1 queued values
#   iperf3 -J                         bits_per_second, seconds, bytes and
#                                     TCP retransmits for both directions
#
# A direction whose 6G station byte delta is zero aborts the arm: the
# iperf3 flow then did not use the selected 6G STA, so the number would not
# be a 6G result.  A missing counter is a warning and is reported as n/a.
#
# "tx retries" is the AP-side station counter, i.e. frames the AP
# retransmitted to the STA.  For the STA->AP direction the TCP sender's
# retransmits are in iperf_retr; the raw station dump and iperf3 JSON are
# both retained.  AP netdev counters are per interface and include
# beacons/background, so use the station delta for the per-STA flow.
#
# The output has the clear arm rows, the loaded arm rows and one delta line
# per direction: "loaded is X% vs clear".  result.txt, summary.csv,
# checks.txt and md5.txt in the artifact directory contain the same data for a PR or a bug report.
#
# Safety:
#
#   - No module load/unload, no firmware change and no reboot.
#   - Only wifi-iface options are changed in the clear arm; the
#     wifi-device (radio) sections are saved and compared before/after.
#   - /etc/config/wireless is backed up with its md5 before the first
#     write; the backup is restored from the EXIT/INT/TERM/HUP trap and
#     the restore is md5-checked.  A second copy is kept at
#     /root/.6g-clear-air.backup, so a SIGKILL or power cut can still be
#     rolled back by hand; it is removed after a verified restore.
#   - The script edits the config file directly instead of using
#     "uci set/commit", because a commit rewrites the whole file and would
#     hide whether the radios or unrelated sections changed.  A pending
#     /tmp/.uci/wireless delta would shadow the edits, so a real run refuses
#     to start while one exists.
#   - wifi reload bounces every radio: manage the board over a wired link,
#     not over the Wi-Fi being tested.
#
# Limits:
#   - The 6 GHz BSS is selected from the live iw state.  A hidden SSID is
#     usable through --iface, but --ssid lookup and the 6G-only check need
#     a visible SSID.
#   - If the only 6 GHz BSS that carries the STA also serves its SSID on
#     5/2.4 GHz, the loaded arm restores those copies and the client may
#     move bands.  The run waits for the same STA on the same 6G BSS and
#     fails if it moves; use --create-bss (or an existing dedicated
#     6G-only BSS) for a strict single-band test.  The clear arm is always
#     6G-only because the other copies are disabled.
#   - The source is TCP iperf3.  An AP CPU or source-limited clear arm also
#     shows a low loaded arm; read the retries, token and AP tx/rx deltas
#     before attributing a drop to 5G/2.4 GHz loading.
#
# Usage:
#   ./scripts/wireless/6g-clear-air.sh --target 192.168.1.50
#   ./scripts/wireless/6g-clear-air.sh --target 192.168.1.50 \
#       --iface phy0.2-ap0 --sta aa:bb:cc:dd:ee:ff --duration 30
#   ./scripts/wireless/6g-clear-air.sh --create-bss --target 192.168.1.50
#   ./scripts/wireless/6g-clear-air.sh --dry-run
#
# Exit status: 0 both arms measured and the original config restored, or a
# clean SKIP; 1 a runtime/measurement/restore failure; 2 invalid arguments.
#
# POSIX sh only (busybox ash on the device), requires root on the device.
# The IW/WIFI/IPERF3/WIRELESS_CONFIG/DEBUGFS/SYSFS_NET environment
# variables are offline test hooks; the defaults are the device values.

set -u
set -f
LC_ALL=C
export LC_ALL
umask 077

PROG=${0##*/}

# --- fixed protocol constants ----------------------------------------

DEFAULT_CONFIG=/etc/config/wireless
DEFAULT_DEBUGFS=/sys/kernel/debug
DEFAULT_SYSFS_NET=/sys/class/net
UCI_DELTA=/tmp/.uci/wireless

SIXG_FREQ_MIN=5925
SIXG_FREQ_MAX=7125

MARK_BEGIN='# >>> 6g-clear-air: BEGIN'
MARK_END='# <<< 6g-clear-air: END'
BSS_SECTION=sixg_clear_air

# --- options and environment -----------------------------------------

CONFIG=${WIRELESS_CONFIG:-$DEFAULT_CONFIG}
DEBUGFS=${DEBUGFS:-$DEFAULT_DEBUGFS}
SYSFS_NET=${SYSFS_NET:-$DEFAULT_SYSFS_NET}
IW=${IW:-iw}
WIFI=${WIFI:-wifi}
IPERF3=${IPERF3:-iperf3}

TARGET=
STA_OPT=
IFACE_OPT=
RADIO_OPT=
SSID=6g-clear-air
KEY=6g-clear-air
DURATION=20
PARALLEL=4
PORT=5201
SETTLE=3
WAIT_STA=60
WAIT_BSS=30
CREATE_BSS=0
DRY_RUN=0
OUT_OPT=
CMDLINE=

# --- runtime state ----------------------------------------------------

TMP_DIR=
OUT=
LOG=
BACKUP=
WORK=
ORIG_MD5=
CLEAR_MD5=
LOADED_MD5=
WORK_MD5=

SEL_IFACE=
SEL_PHY=
SEL_FREQ=
SEL_WIDTH=
SEL_SSID=
SEL_MAC=
SEL_6G_ONLY=
TOKEN_PATH=
RADIO=

CONFIG_DIRTY=0
RELOADED=0
CREATED_SSID=
NEWLY_DISABLED_SECTIONS=
NEWLY_DISABLED_IFACES=
SAFETY_BACKUP=
SAFETY_BACKUP_OWNED=0
CLEANUP_DONE=0
FAILED=0
IPERF_PID=

# --- small helpers ----------------------------------------------------

usage_error() {
	printf '%s: %s\n' "$PROG" "$1" >&2
	printf "Try '%s --help' for usage.\n" "$PROG" >&2
	exit 2
}

die() {
	printf '%s: error: %s\n' "$PROG" "$1" >&2
	exit 1
}

# A run rewrites the wireless config and bounces every radio with "wifi
# reload", so it holds netwatchdog first.  The library fails closed:
# nw_guard_take returns nonzero when netwatchdog is missing or the hold cannot
# be taken, and the run is refused in that case.  This script owns its own
# EXIT/INT/TERM/HUP trap, so the guard installs none and its cleanup is called
# from the script's own cleanup instead.
NETWATCHDOG_GUARD=$(dirname "$0")/../lib/netwatchdog-guard.sh
[ -r "$NETWATCHDOG_GUARD" ] ||
	die "shared library not found: $NETWATCHDOG_GUARD"
# shellcheck source=../lib/netwatchdog-guard.sh
. "$NETWATCHDOG_GUARD"

warn() {
	printf '%s: warning: %s\n' "$PROG" "$1" >&2
}

say() {
	printf '%s\n' "$*"
	[ -n "$LOG" ] && printf '%s\n' "$*" >>"$LOG"
}

emit() {
	printf '%s\n' "$*"
	[ -n "$OUT" ] && printf '%s\n' "$*" >>"$OUT/result.txt"
}

log_cmd() {
	[ -n "$LOG" ] && printf '+ %s\n' "$*" >>"$LOG"
}

is_uint() {
	case ${1:-} in
	'' | *[!0-9]*) return 1 ;;
	*) return 0 ;;
	esac
}

now_s() {
	date +%s
}

md5_of() {
	[ -f "$1" ] || return 1
	md5sum "$1" 2>/dev/null | awk '{ print $1 }'
}

is_sixg_freq() {
	is_uint "${1:-}" && [ "$1" -ge "$SIXG_FREQ_MIN" ] && [ "$1" -le "$SIXG_FREQ_MAX" ]
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || [ -x "$1" ] ||
		die "required command not found: $1"
}

skip_no_sta() {
	[ -n "${1:-}" ] && warn "$1"
	printf 'SKIP: no 6G STA\n'
	exit 0
}

usage() {
	cat <<'EOF'
Usage: 6g-clear-air.sh --target IP [options]
      6g-clear-air.sh --create-bss --target IP [options]
      6g-clear-air.sh --dry-run [options]

Run the same 6 GHz AP<->STA iperf3 source twice: first with every 5 GHz
and 2.4 GHz AP SSID disabled (the clear arm), then with the normal
multi-band configuration restored (the loaded arm).  The 6 GHz BSS that
carries the selected STA stays up in both arms; the wifi-device (radio)
sections are never edited.  The output has both arms and the clear ->
loaded delta.  The original /etc/config/wireless is restored in a trap
and verified by md5.

Required for a real run:
  --target IP        IPv4/IPv6 address of the 6 GHz STA.  The STA must run
                     "iperf3 -s -p PORT" (TCP); the AP is the iperf3 client
                     in both directions.

Station and BSS selection:
  --sta MAC          6 GHz station to select (required if more than one
                     station is associated on 6 GHz)
  --iface NAME       6 GHz AP interface to use (default: auto-detect)
  --ssid SSID        dedicated 6 GHz-only SSID to prefer (default:
                     6g-clear-air); also the SSID created by --create-bss
  --key KEY          SAE key for --create-bss (default: 6g-clear-air)
  --create-bss       if no 6G STA is associated yet, create a marked,
                     6 GHz-only BSS on the 6G radio, print its SSID/key and
                     wait --wait-sta seconds for the station.  The trap
                     removes it.  Without this option a no-STA run writes
                     no configuration at all.
  --radio SECTION    UCI wifi-device section for 6 GHz (default: the
                     wifi-device with band '6g', else radio2)

Traffic:
  --duration SEC     iperf3 seconds per direction per arm (default 20)
  --parallel N       iperf3 streams per direction (default 4)
  --port PORT        iperf3 server port on the STA (default 5201)

Timing:
  --settle SEC       wait after the STA re-associates before each arm
                     (default 3)
  --wait-sta SEC     how long to wait for the STA after a reload and for
                     --create-bss (default 60)
  --wait-bss SEC     how long to wait for an AP BSS after a reload
                     (default 30)

Output:
  --out DIR          artifact directory (default:
                     /tmp/6g-clear-air.YYYYmmdd-HHMMSS; must not exist)
  --dry-run          print every read-only check and the plan; write
                     nothing, send no traffic, need no root and exit 0
  -h, --help         show this help

Device paths (defaults are the XR1710G values):
  --config FILE      /etc/config/wireless
  --debugfs DIR      /sys/kernel/debug
  --sysfs-net DIR    /sys/class/net

Environment test hooks (same meaning as the flags): WIRELESS_CONFIG,
DEBUGFS, SYSFS_NET, IW, WIFI, IPERF3.

What is recorded per direction and arm: iw station dump (raw and deltas),
AP tx/rx netdev counters, tx retries / tx failed / rx drop misc, the mt76
token_info values and the iperf3 JSON.  See scripts/wireless/6g-clear-air.sh
header for the exact counter names.

The output prints "SKIP: no 6G STA" and exits 0 when no station is
associated on any 6 GHz AP BSS; without --create-bss that path writes no
configuration.  A run needs root and bounces every radio with wifi reload,
so manage the board over a wired link.

Exit status: 0 measured and restored, or clean SKIP; 1 runtime,
measurement or restore failure; 2 invalid arguments.
EOF
}

parse_args() {
	while [ $# -gt 0 ]; do
		case $1 in
		--target)
			need_value "$1" $# "${2:-}"
			TARGET=$2
			shift 2
			;;
		--sta)
			need_value "$1" $# "${2:-}"
			STA_OPT=$2
			shift 2
			;;
		--iface)
			need_value "$1" $# "${2:-}"
			IFACE_OPT=$2
			shift 2
			;;
		--radio)
			need_value "$1" $# "${2:-}"
			RADIO_OPT=$2
			shift 2
			;;
		--ssid)
			need_value "$1" $# "${2:-}"
			SSID=$2
			shift 2
			;;
		--key)
			need_value "$1" $# "${2:-}"
			KEY=$2
			shift 2
			;;
		--duration)
			need_value "$1" $# "${2:-}"
			DURATION=$2
			shift 2
			;;
		--parallel)
			need_value "$1" $# "${2:-}"
			PARALLEL=$2
			shift 2
			;;
		--port)
			need_value "$1" $# "${2:-}"
			PORT=$2
			shift 2
			;;
		--settle)
			need_value "$1" $# "${2:-}"
			SETTLE=$2
			shift 2
			;;
		--wait-sta)
			need_value "$1" $# "${2:-}"
			WAIT_STA=$2
			shift 2
			;;
		--wait-bss)
			need_value "$1" $# "${2:-}"
			WAIT_BSS=$2
			shift 2
			;;
		--out)
			need_value "$1" $# "${2:-}"
			OUT_OPT=$2
			shift 2
			;;
		--config)
			need_value "$1" $# "${2:-}"
			CONFIG=$2
			shift 2
			;;
		--debugfs)
			need_value "$1" $# "${2:-}"
			DEBUGFS=$2
			shift 2
			;;
		--sysfs-net)
			need_value "$1" $# "${2:-}"
			SYSFS_NET=$2
			shift 2
			;;
		--create-bss)
			CREATE_BSS=1
			shift
			;;
		--dry-run)
			DRY_RUN=1
			shift
			;;
		-h | --help)
			usage
			exit 0
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

	check_uint DURATION 1 3600 "duration"
	check_uint PARALLEL 1 64 "parallel"
	check_uint PORT 1 65535 "port"
	check_uint SETTLE 0 3600 "settle"
	check_uint WAIT_STA 0 3600 "wait-sta"
	check_uint WAIT_BSS 1 3600 "wait-bss"

	[ -n "$SSID" ] || usage_error "--ssid must not be empty"
	[ "${#SSID}" -le 32 ] || usage_error "--ssid is longer than 32 bytes"
	[ -n "$KEY" ] || usage_error "--key must not be empty"
	[ "${#KEY}" -ge 8 ] && [ "${#KEY}" -le 63 ] ||
		usage_error "--key must be 8..63 bytes for SAE"
	case $SSID in
	*"'"* | *'
'*) usage_error "--ssid must not contain quotes or newlines" ;;
	esac
	case $KEY in
	*"'"* | *'
'*) usage_error "--key must not contain single quotes or newlines" ;;
	esac
	if [ -n "$TARGET" ]; then
		case $TARGET in
		-*) usage_error "--target must not start with '-'" ;;
		*[!A-Za-z0-9.:%_-]*) usage_error "--target contains unsupported characters" ;;
		esac
	fi
}

need_value() {
	[ "$2" -ge 2 ] || usage_error "$1 needs a value"
}

check_uint() {
	# $1 variable name (without $), $2 min, $3 max, $4 user-visible name.
	_val=$(eval "printf '%s' \"\${$1:-}\"")
	is_uint "$_val" || usage_error "--$4 must be a positive integer"
	while [ "${_val#0}" != "$_val" ]; do
		_val=${_val#0}
	done
	[ -n "$_val" ] || _val=0
	[ "$_val" -ge "$2" ] && [ "$_val" -le "$3" ] ||
		usage_error "--$4 must be in $2..$3"
	eval "$1=$_val"
}

# --- UCI config parsing ----------------------------------------------

cfg_records() {
	[ -r "$CONFIG" ] || return 1
	awk '
		function unquote(v,   q) {
			sub(/^[ \t]+/, "", v)
			sub(/[ \t]+$/, "", v)
			q = substr(v, 1, 1)
			if ((q == "\047" || q == "\"") && substr(v, length(v), 1) == q)
				v = substr(v, 2, length(v) - 2)
			return v
		}
		/^[ \t]*config[ \t]+/ {
			if (type == "wifi-iface")
				printf "%s|%s|%s|%s|%s|%d\n", name, device, ssid, mode, disabled, idx
			idx++
			type = $2
			name = unquote($3)
			device = ""; ssid = ""; mode = ""; disabled = ""
			next
		}
		type == "wifi-iface" && $1 == "option" {
			opt = $2
			val = $0
			sub(/^[ \t]*option[ \t]+[^ \t]+[ \t]*/, "", val)
			val = unquote(val)
			if (opt == "device") device = val
			else if (opt == "ssid") ssid = val
			else if (opt == "mode") mode = val
			else if (opt == "disabled") disabled = val
		}
		END {
			if (type == "wifi-iface")
				printf "%s|%s|%s|%s|%s|%d\n", name, device, ssid, mode, disabled, idx
		}
	' "$CONFIG"
}

cfg_get_option() {
	# $1 section name, $2 option name
	[ -r "$CONFIG" ] || return 1
	awk -v want="$1" -v opt="$2" '
		function unquote(v,   q) {
			sub(/^[ \t]+/, "", v)
			sub(/[ \t]+$/, "", v)
			q = substr(v, 1, 1)
			if ((q == "\047" || q == "\"") && substr(v, length(v), 1) == q)
				v = substr(v, 2, length(v) - 2)
			return v
		}
		/^[ \t]*config[ \t]+/ {
			on = 0
			if ($2 ~ /^wifi-/ && $3 != "") {
				name = unquote($3)
				on = (name == want)
			}
			next
		}
		on && $1 == "option" && $2 == opt {
			val = $0
			sub(/^[ \t]*option[ \t]+[^ \t]+[ \t]*/, "", val)
			print unquote(val)
			exit
		}
	' "$CONFIG"
}

cfg_has_device() {
	[ -r "$CONFIG" ] && awk -v want="$1" '
		/^[ \t]*config[ \t]+wifi-device[ \t]+/ {
			name = $3
			gsub(/[\047"]/, "", name)
			if (name == want)
				found = 1
		}
		END { exit !found }
	' "$CONFIG"
}

cfg_radio_sections() {
	[ -r "$CONFIG" ] || return 0
	awk '
		/^[ \t]*config[ \t]/ {
			on = 0
			if ($2 == "wifi-device") {
				name = $3
				gsub(/[\047"]/, "", name)
				if (name == "radio0" || name == "radio1" || name == "radio2")
					on = 1
			}
		}
		on { print }
	' "$CONFIG"
}

cfg_set_245_disabled() {
	# Set option disabled '1' on every AP wifi-iface whose device is
	# radio0 or radio1.  Returns 0 when at least one section was changed,
	# 1 when there was nothing to change.
	_tmp=$CONFIG.6gca.$$
	awk '
		function unquote(v,   q) {
			sub(/^[ \t]+/, "", v)
			sub(/[ \t]+$/, "", v)
			q = substr(v, 1, 1)
			if ((q == "\047" || q == "\"") && substr(v, length(v), 1) == q)
				v = substr(v, 2, length(v) - 2)
			return v
		}
		function flush(   i, last) {
			target = (is_iface && (dev == "radio0" || dev == "radio1") &&
				  (mode == "" || mode == "ap"))
			if (target) {
				last = 0
				have = 0
				for (i = 1; i <= n; i++) {
					if (buf[i] ~ /^[ \t]*option[ \t]/)
						last = i
					if (buf[i] ~ /^[ \t]*option[ \t]+disabled([ \t]|$)/)
						have = 1
				}
				if (have) {
					for (i = 1; i <= n; i++)
						if (buf[i] ~ /^[ \t]*option[ \t]+disabled([ \t]|$)/)
							buf[i] = "\toption disabled \0471\047"
				} else {
					if (last == 0)
						last = 1
					for (i = n; i > last; i--)
						buf[i + 1] = buf[i]
					buf[last + 1] = "\toption disabled \0471\047"
					n++
				}
				changed++
			}
			for (i = 1; i <= n; i++)
				print buf[i]
			sec = 0; is_iface = 0; n = 0
			dev = ""; mode = ""; have = 0
		}
		/^[ \t]*config[ \t]/ {
			flush()
			sec = 1
			is_iface = ($2 == "wifi-iface")
			n = 0
			buf[++n] = $0
			dev = ""; mode = ""; have = 0
			next
		}
		sec {
			buf[++n] = $0
			if ($1 == "option") {
				opt = $2
				val = $0
				sub(/^[ \t]*option[ \t]+[^ \t]+[ \t]*/, "", val)
				val = unquote(val)
				if (opt == "device") dev = val
				else if (opt == "mode") mode = val
			}
			next
		}
		{ print }
		END {
			flush()
			exit (changed ? 0 : 1)
		}
	' "$CONFIG" >"$_tmp"
	_rc=$?
	cat "$_tmp" >"$CONFIG" || { rm -f "$_tmp"; return 2; }
	rm -f "$_tmp"
	return "$_rc"
}

cfg_remove_marker() {
	# Remove every marked block.  Returns 0 when a block was removed.
	_tmp=$CONFIG.6gca.$$
	awk -v begin="$MARK_BEGIN" -v end="$MARK_END" '
		index($0, begin) > 0 { skip = 1; found = 1; next }
		index($0, end) > 0 { skip = 0; next }
		!skip { print }
		END { exit !found }
	' "$CONFIG" >"$_tmp"
	_rc=$?
	cat "$_tmp" >"$CONFIG" || { rm -f "$_tmp"; return 2; }
	rm -f "$_tmp"
	return "$_rc"
}

cfg_append_marker() {
	[ -r "$CONFIG" ] || return 1
	# A UCI section name is only cosmetic, but a stale section with the
	# same name would be confusing; refuse to append over one.
	if awk -v name="$BSS_SECTION" '
		/^[ \t]*config[ \t]+wifi-iface[ \t]+/ {
			n = $3
			gsub(/[\047"]/, "", n)
			if (n == name)
				found = 1
		}
		END { exit !found }
	' "$CONFIG"; then
		return 2
	fi
	if [ -s "$CONFIG" ] && [ "$(tail -c 1 "$CONFIG" 2>/dev/null | wc -l)" -eq 0 ]; then
		printf '\n' >>"$CONFIG" || return 1
	fi
	{
		printf '\n%s\n' "$MARK_BEGIN"
		printf "config wifi-iface '%s'\n" "$BSS_SECTION"
		printf "\toption device '%s'\n" "$RADIO"
		printf "\toption mode 'ap'\n"
		printf "\toption network 'lan'\n"
		printf "\toption ssid '%s'\n" "$SSID"
		printf "\toption encryption 'sae'\n"
		printf "\toption key '%s'\n" "$KEY"
		printf "\toption ieee80211w '2'\n"
		printf "\toption sae_pwe '2'\n"
		printf "\toption disabled '0'\n"
		printf '%s\n' "$MARK_END"
	} >>"$CONFIG" || return 1
	return 0
}

cfg_ssid_exists() {
	[ -r "$CONFIG" ] || return 1
	awk -v want="$1" '
		function unquote(v,   q) {
			sub(/^[ \t]+/, "", v)
			sub(/[ \t]+$/, "", v)
			q = substr(v, 1, 1)
			if ((q == "\047" || q == "\"") && substr(v, length(v), 1) == q)
				v = substr(v, 2, length(v) - 2)
			return v
		}
		/^[ \t]*config[ \t]+wifi-iface[ \t]/ { on = 1; next }
		/^[ \t]*config[ \t]/ { on = 0; next }
		on && $1 == "option" && $2 == "ssid" {
			v = $0
			sub(/^[ \t]*option[ \t]+[^ \t]+[ \t]*/, "", v)
			if (unquote(v) == want)
				found = 1
		}
		END { exit !found }
	' "$CONFIG"
}

cfg_245_ap_records() {
	# "name|device|ssid|disabled" for AP wifi-iface sections on radio0/1.
	cfg_records | awk -F'|' '
		($2 == "radio0" || $2 == "radio1") && ($4 == "" || $4 == "ap") {
			printf "%s|%s|%s|%s\n", $1, $2, $3, $5
		}
	'
}

cfg_iface_disabled() {
	# $1 section name; prints the disabled value, or nothing when unset.
	cfg_records | awk -F'|' -v want="$1" '$1 == want { print $5; exit }'
}

# --- live iw state ----------------------------------------------------

refresh_live() {
	: >"$TMP_IW"
	"$IW" dev >"$TMP_IW" 2>/dev/null || true
	awk '
		function flush() {
			if (iface != "")
				printf "%s|%s|%s|%s|%s|%s|%s\n", iface, phy, freq, ssid, type, addr, width
			iface = ""; ssid = ""; type = ""; freq = ""; addr = ""; width = ""
		}
		/^phy#/ {
			flush()
			phy = substr($0, 5)
			next
		}
		{
			line = $0
			sub(/^[ \t]+/, "", line)
			if (line ~ /^Interface /) {
				flush()
				iface = substr(line, 11)
				next
			}
			if (line ~ /^ssid /) { ssid = substr(line, 6); next }
			if (line ~ /^type /) { type = substr(line, 6); next }
			if (line ~ /^channel /) {
				n = split(line, a, /[ ()]+/)
				freq = a[3]
				# "width: 320 MHz" is the negotiated width (iw prints the
				# colon); without it a clear arm that silently dropped to
				# 160 MHz compared a different airtime against the loaded
				# arm.
				for (i = 1; i < n; i++)
					if (a[i] == "width" || a[i] == "width:") {
						width = a[i + 1]
						break
					}
				next
			}
			if (line ~ /^addr /) { addr = substr(line, 6); next }
		}
		END { flush() }
	' "$TMP_IW" >"$TMP_LIVE"
}

live_has_iface() {
	[ -s "$TMP_LIVE" ] || return 1
	awk -F'|' -v want="$1" '$1 == want { found = 1 } END { exit !found }' "$TMP_LIVE"
}

live_6g_ap_by_ssid() {
	[ -n "${1:-}" ] && [ -s "$TMP_LIVE" ] || return 1
	awk -F'|' -v want="$1" '
		$5 == "AP" && $4 == want && ($3 + 0) >= 5925 && ($3 + 0) <= 7125 {
			print
			exit
		}
	' "$TMP_LIVE"
}

live_iface_record() {
	[ -s "$TMP_LIVE" ] || return 1
	awk -F'|' -v want="$1" '$1 == want { print; exit }' "$TMP_LIVE"
}

station_macs() {
	"$IW" dev "$1" station dump 2>/dev/null |
		awk '/^Station / { print $2 }'
}

station_has_mac() {
	# $1 iface, $2 MAC
	[ -n "${2:-}" ] || return 1
	station_macs "$1" | awk -v want="$2" '
		tolower($0) == tolower(want) { found = 1 }
		END { exit !found }
	'
}

wait_for_sta() {
	# $1 iface, $2 MAC (empty = any), $3 timeout seconds
	_deadline=$(( $(now_s) + $3 ))
	while :; do
		if [ -n "${2:-}" ]; then
			if station_has_mac "$1" "$2"; then
				return 0
			fi
		else
			_macs=$(station_macs "$1" | awk 'NF { print; exit }')
			[ -n "$_macs" ] && return 0
		fi
		[ "$(now_s)" -ge "$_deadline" ] && return 1
		sleep 1
	done
}

wait_for_live_ssid() {
	# $1 SSID, $2 timeout; updates SEL_* on success.
	_deadline=$(( $(now_s) + $2 ))
	while :; do
		refresh_live
		_rec=$(live_6g_ap_by_ssid "$1" || true)
		if [ -n "$_rec" ]; then
			set_sel_from_record "$_rec"
			return 0
		fi
		[ "$(now_s)" -ge "$_deadline" ] && return 1
		sleep 1
	done
}

wait_for_iface_name() {
	# $1 iface name, $2 timeout
	_deadline=$(( $(now_s) + $2 ))
	while :; do
		refresh_live
		if live_has_iface "$1"; then
			return 0
		fi
		[ "$(now_s)" -ge "$_deadline" ] && return 1
		sleep 1
	done
}

wait_for_ssid_gone() {
	# $1 SSID, $2 timeout
	_deadline=$(( $(now_s) + $2 ))
	while :; do
		refresh_live
		_rec=$(live_6g_ap_by_ssid "$1" || true)
		[ -z "$_rec" ] && return 0
		[ "$(now_s)" -ge "$_deadline" ] && return 1
		sleep 1
	done
}

set_sel_from_record() {
	# $1 iface|phy|freq|ssid|... (a live record or a candidate row),
	# $2 optional 6G-only status.  The width is taken from the live record
	# of the selected interface, because a candidate row has no width field.
	SEL_IFACE=$(printf '%s' "$1" | cut -d'|' -f1)
	SEL_PHY=$(printf '%s' "$1" | cut -d'|' -f2)
	SEL_FREQ=$(printf '%s' "$1" | cut -d'|' -f3)
	SEL_SSID=$(printf '%s' "$1" | cut -d'|' -f4)
	SEL_WIDTH=$(live_iface_record "$SEL_IFACE" 2>/dev/null | cut -d'|' -f7)
	[ -n "${2:-}" ] && SEL_6G_ONLY=$2
	TOKEN_PATH=$(find_token_path "$SEL_PHY" || true)
}

find_token_path() {
	# $1 phy index
	for _p in "$DEBUGFS/ieee80211/phy$1/mt76/token_info" \
		"$DEBUGFS/ieee80211/phy0/mt76/token_info"; do
		if [ -r "$_p" ]; then
			printf '%s' "$_p"
			return 0
		fi
	done
	return 1
}

detect_6g_radio() {
	if [ -n "$RADIO_OPT" ]; then
		RADIO=$RADIO_OPT
		cfg_has_device "$RADIO" ||
			die "wireless.$RADIO is not a wifi-device in $CONFIG"
		_band=$(cfg_get_option "$RADIO" band 2>/dev/null || true)
		if [ "$_band" != "6g" ] && [ "$RADIO" != "radio2" ]; then
			die "wireless.$RADIO is not the 6G radio (band '${_band:-unset}')"
		fi
		return 0
	fi
	for _r in radio0 radio1 radio2; do
		if [ "$(cfg_get_option "$_r" band 2>/dev/null || true)" = "6g" ]; then
			RADIO=$_r
			return 0
		fi
	done
	if cfg_has_device radio2; then
		RADIO=radio2
		return 0
	fi
	RADIO=
	return 1
}

# --- station and BSS selection ---------------------------------------

select_ap_and_sta() {
	# Fills SEL_* and returns:
	#   0 a 6G AP BSS with a station was selected
	#   1 no usable 6G AP BSS/station (the caller may create one)
	#   2 exactly one 6G AP BSS exists but has no station (SEL_* is set)
	refresh_live
	cfg_records >"$TMP_CFG" 2>/dev/null || : >"$TMP_CFG"

	awk -F'|' '
		($2 == "radio0" || $2 == "radio1") &&
		($4 == "" || $4 == "ap") && $5 != "1" && $3 != "" { print $3 }
	' "$TMP_CFG" | sort -u >"$TMP_OFF6G"

	: >"$TMP_CANDS"
	while IFS='|' read -r _if _phy _freq _ssid _type _addr; do
		[ "$_type" = "AP" ] || continue
		is_sixg_freq "$_freq" || continue
		if [ -n "$IFACE_OPT" ] && [ "$_if" != "$IFACE_OPT" ]; then
			continue
		fi
		_stas=$(station_macs "$_if")
		_n=$(printf '%s\n' "$_stas" | awk 'NF { n++ } END { print n + 0 }')
		_first=$(printf '%s\n' "$_stas" | awk 'NF { print tolower($0); exit }')
		if [ -n "$STA_OPT" ] && ! printf '%s\n' "$_stas" |
			awk -v want="$STA_OPT" '
				tolower($0) == tolower(want) { found = 1 }
				END { exit !found }
			'; then
			continue
		fi
		_sixg=unknown
		if [ -n "$_ssid" ]; then
			if grep -Fxq -e "$_ssid" "$TMP_OFF6G"; then
				_sixg=no
			else
				_sixg=yes
			fi
		fi
		printf '%s|%s|%s|%s|%s|%s|%s\n' \
			"$_if" "$_phy" "$_freq" "$_ssid" "$_n" "$_first" "$_sixg" \
			>>"$TMP_CANDS"
	done <"$TMP_LIVE"

	_cand_n=$(awk 'END { print NR + 0 }' "$TMP_CANDS")
	if [ -n "$IFACE_OPT" ]; then
		if [ "$_cand_n" -eq 0 ]; then
			_rec=$(live_iface_record "$IFACE_OPT" || true)
			[ -n "$_rec" ] ||
				usage_error "interface $IFACE_OPT not found in iw dev"
			_freq=$(printf '%s' "$_rec" | cut -d'|' -f3)
			_type=$(printf '%s' "$_rec" | cut -d'|' -f5)
			[ "$_type" = "AP" ] ||
				usage_error "interface $IFACE_OPT is not an AP interface"
			is_sixg_freq "$_freq" ||
				usage_error "interface $IFACE_OPT is not on a 6 GHz channel"
			usage_error "interface $IFACE_OPT has no usable 6 GHz AP record"
		fi
	fi
	if [ -n "$STA_OPT" ] && [ "$_cand_n" -eq 0 ]; then
		usage_error "station $STA_OPT is not associated on a 6 GHz AP BSS"
	fi

	if [ -n "$IFACE_OPT" ]; then
		_rec=$(awk -F'|' '$1 == "'"$IFACE_OPT"'" { print; exit }' "$TMP_CANDS")
		_n=$(printf '%s' "$_rec" | cut -d'|' -f5)
		if [ "${_n:-0}" -eq 0 ]; then
			_sixg=$(printf '%s' "$_rec" | cut -d'|' -f7)
			set_sel_from_record "$_rec" "$_sixg"
			SEL_MAC=
			return 2
		fi
		_mac=$(printf '%s' "$_rec" | cut -d'|' -f6)
		_sixg=$(printf '%s' "$_rec" | cut -d'|' -f7)
		set_sel_from_record "$_rec" "$_sixg"
		SEL_MAC=$_mac
		return 0
	fi

	_with_sta="$TMP_WITH_STA"
	awk -F'|' '$5 > 0' "$TMP_CANDS" >"$_with_sta"
	_nsta=$(awk 'END { print NR + 0 }' "$_with_sta")
	if [ "$_nsta" -eq 0 ]; then
		if [ "$_cand_n" -eq 1 ]; then
			_rec=$(cat "$TMP_CANDS")
			_sixg=$(printf '%s' "$_rec" | cut -d'|' -f7)
			set_sel_from_record "$_rec" "$_sixg"
			SEL_MAC=
			return 2
		fi
		return 1
	fi
	if [ -n "$STA_OPT" ]; then
		if [ "$_nsta" -gt 1 ]; then
			usage_error "station $STA_OPT is on more than one 6 GHz BSS; pass --iface"
		fi
		_rec=$(cat "$_with_sta")
		_mac=$(printf '%s' "$_rec" | cut -d'|' -f6)
		_sixg=$(printf '%s' "$_rec" | cut -d'|' -f7)
		set_sel_from_record "$_rec" "$_sixg"
		SEL_MAC=$_mac
		return 0
	fi

	# Prefer the dedicated --ssid BSS, then an already 6 GHz-only BSS,
	# then the only station-carrying BSS.
	_pref=$(awk -F'|' -v want="$SSID" '$4 == want { print; exit }' "$_with_sta")
	if [ -z "$_pref" ]; then
		_pref=$(awk -F'|' '$7 == "yes" { print; exit }' "$_with_sta")
	fi
	if [ -z "$_pref" ]; then
		if [ "$_nsta" -gt 1 ]; then
			usage_error "more than one 6G BSS has a station; pass --iface or --sta"
		fi
		_pref=$(cat "$_with_sta")
	fi
	_mac=$(printf '%s' "$_pref" | cut -d'|' -f6)
	_sixg=$(printf '%s' "$_pref" | cut -d'|' -f7)
	set_sel_from_record "$_pref" "$_sixg"
	SEL_MAC=$_mac
	return 0
}

pick_sta_after_wait() {
	# Sets SEL_MAC from the selected iface.  With --sta the MAC is fixed.
	[ -n "$SEL_IFACE" ] || return 1
	if [ -n "$STA_OPT" ]; then
		SEL_MAC=$STA_OPT
		station_has_mac "$SEL_IFACE" "$SEL_MAC"
		return
	fi
	_stas=$(station_macs "$SEL_IFACE")
	_n=$(printf '%s\n' "$_stas" | awk 'NF { n++ } END { print n + 0 }')
	case $_n in
	0) return 1 ;;
	1)
		SEL_MAC=$(printf '%s\n' "$_stas" | awk 'NF { print tolower($0); exit }')
		return 0
		;;
	*)
		usage_error "more than one station is associated on $SEL_IFACE; pass --sta"
		;;
	esac
}

# --- create/lookup the temporary 6G-only BSS -------------------------

create_marked_bss() {
	[ -r "$CONFIG" ] || die "wireless config not found: $CONFIG"

	refresh_live
	_rec=$(live_6g_ap_by_ssid "$SSID" || true)
	if [ -n "$_rec" ]; then
		set_sel_from_record "$_rec" yes
		say "lookup: 6G-only BSS '$SSID' already live on $SEL_IFACE"
		return 0
	fi

	detect_6g_radio || die "no wifi-device with band '6g' in $CONFIG"
	[ "$(cfg_get_option "$RADIO" disabled 2>/dev/null || true)" != "1" ] ||
		die "wireless.$RADIO is disabled; enable the 6G radio first"

	# Remove a stale block before checking for a foreign section with the
	# same SSID, so a previous interrupted run does not trip the check.
	cfg_remove_marker "$CONFIG"
	case $? in
	0) CONFIG_DIRTY=1 ;;
	2) die "could not edit $CONFIG" ;;
	esac

	if cfg_ssid_exists "$SSID"; then
		die "SSID '$SSID' is already configured outside the marked block; pass --ssid with a free name"
	fi
	if awk -v name="$BSS_SECTION" '
		/^[ \t]*config[ \t]+wifi-iface[ \t]+/ {
			n = $3
			gsub(/[\047"]/, "", n)
			if (n == name)
				found = 1
		}
		END { exit !found }
	' "$CONFIG"; then
		die "section '$BSS_SECTION' already exists in $CONFIG; remove it first"
	fi

	cfg_append_marker "$CONFIG"
	case $? in
	0) ;;
	2) die "section '$BSS_SECTION' already exists in $CONFIG; remove it first" ;;
	*) die "could not append the 6G-only BSS to $CONFIG" ;;
	esac
	CONFIG_DIRTY=1
	CREATED_SSID=$SSID
	SEL_6G_ONLY=yes

	say "create: temporary 6G-only BSS '$SSID' (SAE key '$KEY') on $RADIO"
	say "create: restore is automatic; connect the 6G STA to this SSID now"
	reload_wifi
	wait_for_live_ssid "$SSID" "$WAIT_BSS" ||
		die "6G-only BSS '$SSID' did not appear within ${WAIT_BSS}s"
	say "created: $SEL_IFACE on $SEL_FREQ MHz (SSID '$SSID')"
}

# --- config backup, arms and restore ---------------------------------

prepare_run() {
	if [ "$CONFIG" = "$DEFAULT_CONFIG" ]; then
		[ "$(id -u 2>/dev/null || echo 0)" = "0" ] ||
			die "a real run needs root (writing $CONFIG and wifi reload)"
	fi
	[ -r "$CONFIG" ] || die "wireless config not found: $CONFIG"
	if grep -Fq "$MARK_BEGIN" "$CONFIG"; then
		die "$CONFIG still contains a $MARK_BEGIN block from an interrupted run; restore the pre-run config (for a device run: cp -p /root/.6g-clear-air.backup $CONFIG && wifi reload) before running"
	fi
	detect_6g_radio || true
	[ -s "$UCI_DELTA" ] && [ "$CONFIG" = "$DEFAULT_CONFIG" ] &&
		die "pending UCI changes in $UCI_DELTA; commit or revert them first"

	OUT=${OUT_OPT:-/tmp/6g-clear-air.$(date +%Y%m%d-%H%M%S)}
	[ -e "$OUT" ] && die "output path already exists: $OUT"
	mkdir -p "$OUT" 2>/dev/null || die "cannot create output directory $OUT"
	LOG=$OUT/run.log
	: >"$LOG" || die "cannot write $LOG"
	BACKUP=$OUT/wireless.backup
	WORK=$OUT/wireless.work

	ORIG_MD5=$(md5_of "$CONFIG")
	[ -n "$ORIG_MD5" ] || die "cannot compute the md5 of $CONFIG"
	cp -p "$CONFIG" "$BACKUP" 2>/dev/null || cp "$CONFIG" "$BACKUP" ||
		die "cannot back up $CONFIG"
	[ "$(md5_of "$BACKUP")" = "$ORIG_MD5" ] ||
		die "backup of $CONFIG does not match the original md5"

	# A second copy outside the (often tmpfs) artifact directory survives
	# a SIGKILL or a power cut; a successful trap restore removes it.  If a
	# previous run left one and the current config differs, refuse to treat
	# the modified config as the baseline: the operator must restore it.
	if [ "$CONFIG" = "$DEFAULT_CONFIG" ]; then
		SAFETY_BACKUP=/root/.6g-clear-air.backup
		if [ -f "$SAFETY_BACKUP" ]; then
			_safe_md5=$(md5_of "$SAFETY_BACKUP")
			if [ -n "$_safe_md5" ] && [ "$_safe_md5" != "$ORIG_MD5" ]; then
				die "a previous run left the pre-run config at $SAFETY_BACKUP (md5 $_safe_md5, now $ORIG_MD5); restore it first: cp -p $SAFETY_BACKUP $CONFIG && wifi reload"
			fi
		fi
		cp -p "$BACKUP" "$SAFETY_BACKUP" 2>/dev/null ||
			warn "could not write the safety backup $SAFETY_BACKUP"
		SAFETY_BACKUP_OWNED=1
	fi

	cfg_radio_sections >"$OUT/radio-sections.before"
	cp -p "$CONFIG" "$OUT/wireless.before" 2>/dev/null || cp "$CONFIG" "$OUT/wireless.before"
	printf '%s\n' "$ORIG_MD5" >"$OUT/wireless.md5.before"
	{
		printf 'original %s\n' "$ORIG_MD5"
	} >"$OUT/md5.txt"
	"$IW" dev >"$OUT/iw-dev.before.txt" 2>/dev/null || true
	if command -v uci >/dev/null 2>&1; then
		uci -q show wireless >"$OUT/uci-wireless.before.txt" 2>/dev/null || true
	fi
	printf 'command: %s\n' "$CMDLINE" >"$OUT/cmdline" 2>/dev/null || true

	trap 'cleanup $?' EXIT
	trap 'cleanup 130' INT
	trap 'cleanup 143' TERM
	trap 'cleanup 129' HUP

	nw_guard_init --apply --no-trap --label 6g-clear-air \
		--result-json "$OUT/netwatchdog.json"
	nw_guard_take ||
		die "cannot take the netwatchdog hold; refusing to rewrite $CONFIG.  Install netwatchdog, or set NWD_ALLOW_NO_SERVICE=1 for a run that expects no protection."

	say "output: $OUT"
	say "config: $CONFIG (md5 $ORIG_MD5)"
	printf 'manual restore: cp -p %s %s && wifi reload\n' "$BACKUP" "$CONFIG"
	printf 'manual restore: cp -p %s %s && wifi reload\n' "$BACKUP" "$CONFIG" >>"$LOG"
	if [ -n "$SAFETY_BACKUP" ]; then
		printf 'manual restore (survives SIGKILL): cp -p %s %s && wifi reload\n' \
			"$SAFETY_BACKUP" "$CONFIG"
		printf 'manual restore (survives SIGKILL): cp -p %s %s && wifi reload\n' \
			"$SAFETY_BACKUP" "$CONFIG" >>"$LOG"
	fi
}

save_work() {
	cp -p "$CONFIG" "$WORK" 2>/dev/null || cp "$CONFIG" "$WORK" ||
		die "cannot save the working config"
	WORK_MD5=$(md5_of "$WORK")
	[ -n "$WORK_MD5" ] || die "cannot compute the md5 of $WORK"
}

reload_wifi() {
	RELOADED=1
	say "  wifi reload"
	log_cmd "$WIFI reload"
	if ! "$WIFI" reload >>"$LOG" 2>&1; then
		warn "wifi reload returned non-zero; checking the live state anyway"
	fi
}

reacquire_bss() {
	# After a reload the iface may have a new name; use the SSID when
	# possible, otherwise wait for the old name.
	if [ -n "$CREATED_SSID" ]; then
		wait_for_live_ssid "$CREATED_SSID" "$WAIT_BSS" && return 0
	elif [ -n "$SEL_SSID" ]; then
		wait_for_live_ssid "$SEL_SSID" "$WAIT_BSS" && return 0
	fi
	wait_for_iface_name "$SEL_IFACE" "$WAIT_BSS"
}

reload_and_wait() {
	reload_wifi
	reacquire_bss || die "the 6G AP BSS did not come back after wifi reload"
	if [ -z "$SEL_MAC" ]; then
		pick_sta_after_wait || die "no 6G STA after wifi reload"
	fi
	say "  waiting for STA $SEL_MAC on $SEL_IFACE (up to ${WAIT_STA}s)"
	wait_for_sta "$SEL_IFACE" "$SEL_MAC" "$WAIT_STA" ||
		die "6G STA $SEL_MAC did not re-associate within ${WAIT_STA}s"
}

disable_245_ssids() {
	_all=$(cfg_245_ap_records)
	_enabled=$(printf '%s\n' "$_all" | awk -F'|' 'NF == 4 && $4 != "1"')
	NEWLY_DISABLED_IFACES=
	if [ -z "$_enabled" ]; then
		say "clear arm: no enabled 5G/2.4G AP SSIDs to disable (already clear)"
		CLEAR_MD5=$ORIG_MD5
		printf 'clear %s\n' "$CLEAR_MD5" >>"$OUT/md5.txt"
		cfg_radio_sections >"$OUT/radio-sections.clear"
		return 0
	fi
	_names=$(printf '%s\n' "$_enabled" | awk -F'|' '{ printf "%s%s", sep, ($1 != "" ? $1 : $2); sep = " " }')
	printf '%s\n' "$_enabled" | awk -F'|' '$3 != "" { print $3 }' | sort -u >"$TMP_DISABLED_SSIDS"
	_ssids=$(tr '\n' ' ' <"$TMP_DISABLED_SSIDS")
	_ssids=${_ssids% }
	say "clear arm: disabling 5G/2.4G AP SSIDs: $_names"
	say "clear arm: SSIDs: ${_ssids:- (hidden)}"
	NEWLY_DISABLED_SECTIONS=$(printf '%s\n' "$_enabled" | awk -F'|' '{ printf "%s ", $1 }')
	NEWLY_DISABLED_SECTIONS=${NEWLY_DISABLED_SECTIONS% }

	# Record the live non-6G ifaces that serve these SSIDs, so the loaded
	# arm can verify they come back.
	refresh_live
	while IFS='|' read -r _if _phy _freq _ssid _type _addr; do
		[ "$_type" = "AP" ] || continue
		is_sixg_freq "$_freq" && continue
		[ -n "$_ssid" ] || continue
		if grep -Fxq -e "$_ssid" "$TMP_OFF6G" 2>/dev/null; then
			NEWLY_DISABLED_IFACES="$NEWLY_DISABLED_IFACES $_if"
		fi
	done <"$TMP_LIVE"
	NEWLY_DISABLED_IFACES=${NEWLY_DISABLED_IFACES# }

	cfg_set_245_disabled
	case $? in
	0) ;;
	1) warn "no 5G/2.4G AP SSID section was changed" ;;
	*) die "failed to edit $CONFIG" ;;
	esac
	CONFIG_DIRTY=1
	CLEAR_MD5=$(md5_of "$CONFIG")
	printf 'clear %s\n' "$CLEAR_MD5" >>"$OUT/md5.txt"
	cp -p "$CONFIG" "$OUT/wireless.clear" 2>/dev/null || cp "$CONFIG" "$OUT/wireless.clear"
	cfg_radio_sections >"$OUT/radio-sections.clear"
	if ! cmp -s "$OUT/radio-sections.before" "$OUT/radio-sections.clear"; then
		die "the wifi-device (radio) sections changed; refusing to continue"
	fi

	_remaining=$(cfg_245_ap_records | awk -F'|' 'NF == 4 && $4 != "1"')
	if [ -n "$_remaining" ]; then
		die "some 5G/2.4G AP SSIDs are still enabled after the edit: $_remaining"
	fi
	if [ -n "$RADIO" ]; then
		_6g_up=$(cfg_records | awk -F'|' -v r="$RADIO" '
			$2 == r && ($4 == "" || $4 == "ap") && $5 != "1" { n++ }
			END { print n + 0 }
		')
		[ "$_6g_up" -gt 0 ] ||
			die "no enabled AP SSID remains on the 6G radio $RADIO"
	else
		warn "no 6G wifi-device section was detected; relying on the live $SEL_IFACE BSS"
	fi
	check PASS "clear arm: only 5G/2.4G SSIDs disabled; radio sections unchanged"
}

restore_loaded_ssids() {
	[ -f "$WORK" ] || die "working config $WORK is missing"
	cp -p "$WORK" "$CONFIG" 2>/dev/null || cp "$WORK" "$CONFIG" ||
		die "cannot restore the working config"
	CONFIG_DIRTY=1
	LOADED_MD5=$(md5_of "$CONFIG")
	[ "$LOADED_MD5" = "$WORK_MD5" ] ||
		die "restored config md5 $LOADED_MD5 does not match the working copy $WORK_MD5"
	printf 'loaded %s\n' "$LOADED_MD5" >>"$OUT/md5.txt"
	cp -p "$CONFIG" "$OUT/wireless.loaded" 2>/dev/null || cp "$CONFIG" "$OUT/wireless.loaded"
	say "loaded arm: restored all 5G/2.4G SSIDs (md5 $LOADED_MD5)"
	reload_and_wait
	_bad=
	for _s in $NEWLY_DISABLED_SECTIONS; do
		[ "$(cfg_iface_disabled "$_s")" = "1" ] && _bad="$_bad $_s"
	done
	[ -z "$_bad" ] ||
		die "these 5G/2.4G SSIDs are still disabled after the loaded-arm restore:$_bad"
	_missing=
	for _if in $NEWLY_DISABLED_IFACES; do
		if ! wait_for_iface_name "$_if" "$WAIT_BSS"; then
			_missing="$_missing $_if"
		fi
	done
	if [ -n "$_missing" ]; then
		warn "5G/2.4G AP interfaces did not return:$_missing"
		check WARN "loaded arm: SSIDs enabled in UCI but these ifaces were not seen:$_missing"
	else
		check PASS "loaded arm: all previously disabled SSIDs are enabled again"
	fi
}

# --- snapshots and counters ------------------------------------------

snap_station() {
	"$IW" dev "$SEL_IFACE" station dump >"$1" 2>/dev/null || : >"$1"
}

snap_sysfs() {
	: >"$1"
	for _c in tx_bytes rx_bytes tx_packets rx_packets tx_errors rx_errors \
		tx_dropped rx_dropped; do
		_v=$(cat "$SYSFS_NET/$SEL_IFACE/statistics/$_c" 2>/dev/null || true)
		printf '%s=%s\n' "$_c" "${_v:-n/a}" >>"$1"
	done
}

snap_token() {
	if [ -n "$TOKEN_PATH" ] && [ -r "$TOKEN_PATH" ]; then
		cat "$TOKEN_PATH" >"$1" 2>/dev/null || : >"$1"
	else
		printf 'token_info: unavailable\n' >"$1"
	fi
}

station_value() {
	# $1 dump file, $2 MAC, $3 field
	[ -r "$1" ] || return 1
	awk -v mac="$2" -v field="$3" '
		function low(s) { return tolower(s) }
		$1 == "Station" { on = (low($2) == low(mac)); next }
		!on { next }
		field == "tx_bytes"      && $1 == "tx" && $2 == "bytes:"          { print $3; exit }
		field == "rx_bytes"      && $1 == "rx" && $2 == "bytes:"          { print $3; exit }
		field == "tx_packets"    && $1 == "tx" && $2 == "packets:"        { print $3; exit }
		field == "rx_packets"    && $1 == "rx" && $2 == "packets:"        { print $3; exit }
		field == "tx_retries"    && $1 == "tx" && $2 == "retries:"        { print $3; exit }
		field == "tx_failed"     && $1 == "tx" && $2 == "failed:"         { print $3; exit }
		field == "rx_drop_misc"  && $1 == "rx" && $2 == "drop" && $3 == "misc:" { print $4; exit }
		field == "signal"        && $1 == "signal:"                        { print $2; exit }
		field == "signal_avg"    && $1 == "signal" && $2 == "avg:"         { print $3; exit }
		field == "connected_time" && $1 == "connected" && $2 == "time:"   { print $3; exit }
		field == "tx_bitrate"    && $1 == "tx" && $2 == "bitrate:" {
			line = $0
			sub(/^[ \t]*tx bitrate:[ \t]*/, "", line)
			print line
			exit
		}
		field == "rx_bitrate"    && $1 == "rx" && $2 == "bitrate:" {
			line = $0
			sub(/^[ \t]*rx bitrate:[ \t]*/, "", line)
			print line
			exit
		}
	' "$1"
}

sysfs_value() {
	# $1 snapshot file, $2 counter
	awk -F= -v k="$2" '$1 == k { print $2; exit }' "$1" 2>/dev/null
}

token_values() {
	# Prints sw|wed|rxsize|npu0_queue|npu1_queue from a token_info file.
	[ -r "$1" ] || { printf '||||\n'; return 0; }
	awk '
		$1 == "token_count:"     { sw = $2 }
		$1 == "wed_token_count:" { wed = $2 }
		$1 == "rx_token_size:"   { rx = $2 }
		$1 == "npu_rx0"          { q0 = $5 }
		$1 == "npu_rx1"          { q1 = $5 }
		END { printf "%s|%s|%s|%s|%s\n", sw, wed, rx, q0, q1 }
	' "$1"
}

token_field() {
	# $1 token_values string, $2 1..5
	printf '%s\n' "$1" | cut -d'|' -f"$2"
}

num_delta() {
	# $1 before, $2 after; prints the delta or "n/a"
	if is_uint "${1:-}" && is_uint "${2:-}"; then
		printf '%s' $(( $2 - $1 ))
	else
		printf 'n/a'
	fi
}

iperf_sum_field() {
	# $1 iperf3 JSON, $2 sum_sent|sum_received, $3 field
	[ -r "$1" ] || return 1
	awk -v sum="$2" -v key="$3" '
		BEGIN { inblock = 0 }
		{
			if (!inblock && index($0, "\"" sum "\":") > 0) {
				inblock = 1
				next
			}
			if (inblock && $0 ~ /^[ \t]*\}[,]?[ \t]*$/)
				exit
			if (inblock && index($0, "\"" key "\":") > 0) {
				v = $0
				sub(/^.*:[ \t]*/, "", v)
				sub(/[ \t]*[,]?[ \t]*$/, "", v)
				gsub(/"/, "", v)
				print v
				exit
			}
		}
	' "$1"
}

iperf_error() {
	[ -r "$1" ] || return 1
	awk '
		{
			p = index($0, "\"error\":")
			if (!p)
				next
			v = substr($0, p + 8)
			sub(/^[ \t]*/, "", v)
			if (substr(v, 1, 1) != "\"")
				next
			v = substr(v, 2)
			sub(/".*$/, "", v)
			print v
			exit
		}
	' "$1"
}

# --- the iperf3 source ------------------------------------------------

iperf_command() {
	# $1 direction (ap2sta|sta2ap)
	_cmd="$IPERF3 -c ${TARGET:-<STA_IP>} -t $DURATION -p $PORT -P $PARALLEL -J"
	if [ "$1" = "sta2ap" ]; then
		_cmd="$_cmd -R"
	fi
	printf '%s' "$_cmd"
}

run_iperf() {
	# $1 direction, $2 output JSON, $3 stderr
	_cmd=$(iperf_command "$1")
	say "  source: $_cmd"
	printf '%s %s\n' "$1" "$_cmd" >>"$OUT/source-commands.txt"
	log_cmd "$_cmd"
	# The command is intentionally word-split; set -f is on globally.
	# shellcheck disable=SC2086
	$_cmd >"$2" 2>"$3" &
	IPERF_PID=$!
	wait "$IPERF_PID"
	_rc=$?
	IPERF_PID=
	if [ "$_rc" -ne 0 ]; then
		_msg=$(cat "$3" 2>/dev/null | tail -n 3 | tr '\n' ' ')
		die "iperf3 $1 failed (exit $_rc): ${_msg:-see $3}"
	fi
	_err=$(iperf_error "$2" || true)
	if [ -n "$_err" ]; then
		die "iperf3 $1 reported: $_err"
	fi
}

# --- one arm ----------------------------------------------------------

measure_arm() {
	_arm=$1
	if [ "$_arm" = "clear" ]; then
		_desc="6G-only: 5G/2.4G SSIDs disabled"
	else
		_desc="loaded: 5G/2.4G SSIDs enabled"
	fi
	say ""
	say "=== arm $_arm ($_desc) ==="
	[ "$SETTLE" -gt 0 ] && sleep "$SETTLE"
	wait_for_sta "$SEL_IFACE" "$SEL_MAC" 1 ||
		die "6G STA $SEL_MAC left $SEL_IFACE before the $_arm arm"

	for _dir in ap2sta sta2ap; do
		if [ "$_dir" = "ap2sta" ]; then
			_display="AP->STA"
		else
			_display="STA->AP"
		fi
		_tag="arm-$_arm-$_dir"
		say "  $_display"
		snap_station "$OUT/$_tag-station-before.txt"
		snap_sysfs "$OUT/$_tag-ap-before.txt"
		snap_token "$OUT/$_tag-token-before.txt"
		run_iperf "$_dir" "$OUT/$_tag-iperf.json" "$OUT/$_tag-iperf.err"
		snap_station "$OUT/$_tag-station-after.txt"
		snap_sysfs "$OUT/$_tag-ap-after.txt"
		snap_token "$OUT/$_tag-token-after.txt"

		_mbps=$(iperf_sum_field "$OUT/$_tag-iperf.json" sum_received bits_per_second || true)
		[ -n "$_mbps" ] ||
			_mbps=$(iperf_sum_field "$OUT/$_tag-iperf.json" sum_sent bits_per_second || true)
		[ -n "$_mbps" ] || die "iperf3 $_display JSON has no bits_per_second"
		_ipf_bytes=$(iperf_sum_field "$OUT/$_tag-iperf.json" sum_received bytes || true)
		_ipf_retr=$(iperf_sum_field "$OUT/$_tag-iperf.json" sum_sent retransmits || true)

		_st_tx_b=$(station_value "$OUT/$_tag-station-before.txt" "$SEL_MAC" tx_bytes || true)
		_st_tx_a=$(station_value "$OUT/$_tag-station-after.txt" "$SEL_MAC" tx_bytes || true)
		_st_rx_b=$(station_value "$OUT/$_tag-station-before.txt" "$SEL_MAC" rx_bytes || true)
		_st_rx_a=$(station_value "$OUT/$_tag-station-after.txt" "$SEL_MAC" rx_bytes || true)
		_st_retr_b=$(station_value "$OUT/$_tag-station-before.txt" "$SEL_MAC" tx_retries || true)
		_st_retr_a=$(station_value "$OUT/$_tag-station-after.txt" "$SEL_MAC" tx_retries || true)
		_st_fail_b=$(station_value "$OUT/$_tag-station-before.txt" "$SEL_MAC" tx_failed || true)
		_st_fail_a=$(station_value "$OUT/$_tag-station-after.txt" "$SEL_MAC" tx_failed || true)
		_st_rdrop_b=$(station_value "$OUT/$_tag-station-before.txt" "$SEL_MAC" rx_drop_misc || true)
		_st_rdrop_a=$(station_value "$OUT/$_tag-station-after.txt" "$SEL_MAC" rx_drop_misc || true)
		_st_sig=$(station_value "$OUT/$_tag-station-before.txt" "$SEL_MAC" signal_avg || true)
		_st_tx_rate=$(station_value "$OUT/$_tag-station-before.txt" "$SEL_MAC" tx_bitrate || true)
		_st_rx_rate=$(station_value "$OUT/$_tag-station-before.txt" "$SEL_MAC" rx_bitrate || true)

		_st_tx_d=$(num_delta "$_st_tx_b" "$_st_tx_a")
		_st_rx_d=$(num_delta "$_st_rx_b" "$_st_rx_a")
		_st_retr_d=$(num_delta "$_st_retr_b" "$_st_retr_a")
		_st_fail_d=$(num_delta "$_st_fail_b" "$_st_fail_a")
		_st_rdrop_d=$(num_delta "$_st_rdrop_b" "$_st_rdrop_a")

		# A measured direction must be visible on the selected 6G STA;
		# otherwise the iperf3 flow took another path (or the station
		# counter is missing) and the result is not a 6G result.
		if [ "$_dir" = "ap2sta" ]; then
			_flow_d=$_st_tx_d
			_flow_name="station tx bytes"
		else
			_flow_d=$_st_rx_d
			_flow_name="station rx bytes"
		fi
		case $_flow_d in
		n/a | '')
			warn "$_dir: $_flow_name delta is unavailable; the 6G attribution is unverified"
			;;
		*)
			if [ "$_flow_d" -le 0 ]; then
				die "$_dir: $_flow_name delta is $_flow_d; the iperf3 flow did not use the 6G STA $SEL_MAC"
			fi
			;;
		esac

		_ap_tx_b=$(sysfs_value "$OUT/$_tag-ap-before.txt" tx_bytes || true)
		_ap_tx_a=$(sysfs_value "$OUT/$_tag-ap-after.txt" tx_bytes || true)
		_ap_rx_b=$(sysfs_value "$OUT/$_tag-ap-before.txt" rx_bytes || true)
		_ap_rx_a=$(sysfs_value "$OUT/$_tag-ap-after.txt" rx_bytes || true)
		_ap_tx_d=$(num_delta "$_ap_tx_b" "$_ap_tx_a")
		_ap_rx_d=$(num_delta "$_ap_rx_b" "$_ap_rx_a")

		_tok_a=$(token_values "$OUT/$_tag-token-after.txt")
		_tok_sw=$(token_field "$_tok_a" 1)
		_tok_wed=$(token_field "$_tok_a" 2)
		_tok_npu0=$(token_field "$_tok_a" 4)
		_tok_npu1=$(token_field "$_tok_a" 5)

		_mbps_m=$(awk -v v="$_mbps" 'BEGIN { if (v == "") print "n/a"; else printf "%.1f", v / 1000000 }')
		_st_tx_m=$(awk -v v="$_st_tx_d" 'BEGIN { if (v == "n/a" || v == "") print "n/a"; else printf "%.2f", v / 1048576 }')
		_st_rx_m=$(awk -v v="$_st_rx_d" 'BEGIN { if (v == "n/a" || v == "") print "n/a"; else printf "%.2f", v / 1048576 }')
		_ap_tx_m=$(awk -v v="$_ap_tx_d" 'BEGIN { if (v == "n/a" || v == "") print "n/a"; else printf "%.2f", v / 1048576 }')
		_ap_rx_m=$(awk -v v="$_ap_rx_d" 'BEGIN { if (v == "n/a" || v == "") print "n/a"; else printf "%.2f", v / 1048576 }')

		printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
			"$_arm" "$_dir" "$_mbps_m" "$_st_tx_m" "$_st_rx_m" \
			"$_st_retr_d" "$_st_fail_d" "$_st_rdrop_d" "$_ap_tx_m" "$_ap_rx_m" \
			"$_tok_sw" "$_tok_npu0" "$_tok_npu1" "$_ipf_retr" "$_st_sig" "${_ipf_bytes:-n/a}" \
			>>"$OUT/arms.tsv"
		say "  $_display: ${_mbps_m} Mbit/s; station tx/rx ${_st_tx_m}/${_st_rx_m} MiB, retries ${_st_retr_d}, failed ${_st_fail_d}; AP tx/rx ${_ap_tx_m}/${_ap_rx_m} MiB; token ${_tok_sw}/${_tok_wed:-n/a}, npu_rx ${_tok_npu0:-n/a}/${_tok_npu1:-n/a}"
		say "  link: tx ${_st_tx_rate:-n/a} | rx ${_st_rx_rate:-n/a} | signal ${_st_sig:-n/a} dBm"
	done
}

# --- results ----------------------------------------------------------

arm_mbps() {
	# $1 arm, $2 direction; prints the measured Mbit/s or nothing.
	[ -f "$OUT/arms.tsv" ] || return 1
	awk -F'|' -v a="$1" -v d="$2" '$1 == a && $2 == d { print $3; exit }' "$OUT/arms.tsv"
}

check() {
	# $1 PASS|WARN|FAIL, $2 detail
	case $1 in
	PASS) printf '  check: PASS %s\n' "$2" ;;
	WARN) printf '  check: WARN %s\n' "$2" ;;
	*)
		printf '  check: FAIL %s\n' "$2"
		FAILED=1
		;;
	esac
	[ -n "$OUT" ] && printf '%s|%s\n' "$1" "$2" >>"$OUT/checks.txt"
}

require_check() {
	# A FAIL aborts the measurement, but the trap still restores the config.
	check "$1" "$2"
	[ "$1" = PASS ] || die "$2"
}

print_results() {
	[ -f "$OUT/arms.tsv" ] || die "no arm results in $OUT/arms.tsv"
	: >"$OUT/summary.csv"
	printf 'arm,direction,mbps,station_tx_mib,station_rx_mib,tx_retries,tx_failed,rx_drop_misc,ap_tx_mib,ap_rx_mib,token_sw,npu_rx0_q,npu_rx1_q,iperf_retransmits,signal_dbm,iperf_bytes\n' >>"$OUT/summary.csv"
	awk -F'|' '{
		printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
			$1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16
	}' "$OUT/arms.tsv" >>"$OUT/summary.csv"

	emit ""
	emit "=== 6G clear-air A/B result ==="
	emit "iface: $SEL_IFACE ($SEL_FREQ MHz)  STA: $SEL_MAC  SSID: ${SEL_SSID:-(hidden)}"
	if [ "$SEL_6G_ONLY" = "yes" ]; then
		emit "BSS: the selected SSID was already served only on 6 GHz"
	elif [ "$SEL_6G_ONLY" = "no" ]; then
		emit "BSS: the selected SSID was also served on 5/2.4 GHz before the clear arm; the clear arm disabled those copies, and the loaded arm restores them"
	else
		emit "BSS: SSID not visible in iw dev; --iface selects the 6G BSS"
	fi
	emit ""
	emit "arm    direction  Mbit/s   st_tx_MiB st_rx_MiB  retr  fail  drop  AP_tx_MiB AP_rx_MiB  token_sw npu0 npu1 ip_retr"
	awk -F'|' '{
		printf "%-6s %-9s %8s  %9s %9s  %4s  %4s  %4s  %9s %9s  %8s %4s %4s %7s\n",
			$1, ($2 == "ap2sta" ? "AP->STA" : "STA->AP"), $3, $4, $5,
			$6, $7, $8, $9, $10, $11, $12, $13, $14
	}' "$OUT/arms.tsv" | while IFS= read -r _line; do
		emit "$_line"
	done
	emit ""
	for _dir in ap2sta sta2ap; do
		if [ "$_dir" = "ap2sta" ]; then
			_display="AP->STA"
		else
			_display="STA->AP"
		fi
		_c=$(arm_mbps clear "$_dir" || true)
		_l=$(arm_mbps loaded "$_dir" || true)
		if [ -z "$_c" ] || [ -z "$_l" ]; then
			emit "delta $_display: n/a (clear=$_c loaded=$_l)"
			continue
		fi
		_diff=$(awk -v c="$_c" -v l="$_l" 'BEGIN { printf "%.1f", l - c }')
		_pct=$(awk -v c="$_c" -v l="$_l" 'BEGIN {
			if (c > 0) printf "%.1f", (l - c) / c * 100
			else print "n/a"
		}')
		emit "delta $_display: clear $_c -> loaded $_l Mbit/s; loaded is ${_pct}% vs clear (absolute ${_diff} Mbit/s)"
	done
	emit ""
	_clear_md5=$(grep '^clear ' "$OUT/md5.txt" 2>/dev/null | awk '{ print $2 }')
	_loaded_md5=$(grep '^loaded ' "$OUT/md5.txt" 2>/dev/null | awk '{ print $2 }')
	emit "config: original $ORIG_MD5, clear arm $_clear_md5, loaded arm $_loaded_md5"
}

# --- cleanup and trap -------------------------------------------------

cleanup() {
	_status=${1:-0}
	if [ "$CLEANUP_DONE" = 1 ]; then
		exit "$_status"
	fi
	CLEANUP_DONE=1
	trap - EXIT INT TERM HUP

	if [ -n "$IPERF_PID" ]; then
		kill "$IPERF_PID" 2>/dev/null || true
		wait "$IPERF_PID" 2>/dev/null || true
		IPERF_PID=
	fi

	if [ -n "$OUT" ] && [ -f "$BACKUP" ] && [ -f "$CONFIG" ]; then
		_now=$(md5_of "$CONFIG")
		if [ "$_now" != "$ORIG_MD5" ]; then
			say "restore: $CONFIG <- $BACKUP"
			if cp -p "$BACKUP" "$CONFIG" 2>/dev/null || cp "$BACKUP" "$CONFIG"; then
				if [ "$RELOADED" = 1 ]; then
					say "restore: wifi reload"
					"$WIFI" reload >>"$LOG" 2>&1 || warn "wifi reload after restore returned non-zero"
				fi
			else
				warn "could not restore $CONFIG; the backup is $BACKUP"
				_status=1
			fi
			if [ -n "$CREATED_SSID" ] && [ "$RELOADED" = 1 ]; then
				wait_for_ssid_gone "$CREATED_SSID" "$WAIT_BSS" ||
					warn "the created BSS '$CREATED_SSID' may still be live"
			fi
		fi

		cfg_radio_sections >"$OUT/radio-sections.after"
		cp -p "$CONFIG" "$OUT/wireless.after" 2>/dev/null || cp "$CONFIG" "$OUT/wireless.after"
		_final=$(md5_of "$CONFIG")
		printf 'restored %s\n' "$_final" >>"$OUT/md5.txt"
		if [ "$_final" = "$ORIG_MD5" ]; then
			say "restore: md5 $ORIG_MD5 OK (byte-identical to the pre-run config)"
			printf 'restore: md5 %s OK (byte-identical to the pre-run config)\n' "$ORIG_MD5" >>"$OUT/result.txt"
			check PASS "restore: md5 $ORIG_MD5 matches the pre-run config"
			[ "$SAFETY_BACKUP_OWNED" = 1 ] && rm -f "$SAFETY_BACKUP"
		else
			say "restore: FAIL md5 $_final, expected $ORIG_MD5; backup kept at $BACKUP"
			check FAIL "restore: md5 $_final, expected $ORIG_MD5"
			_status=1
		fi
		if cmp -s "$OUT/radio-sections.before" "$OUT/radio-sections.after"; then
			check PASS "restore: radio0/radio1/radio2 sections unchanged"
		else
			check FAIL "restore: radio0/radio1/radio2 sections changed"
			_status=1
		fi
		if grep -Fq "$MARK_BEGIN" "$CONFIG"; then
			check FAIL "restore: the 6g-clear-air marker is still in $CONFIG"
			_status=1
		else
			check PASS "restore: no 6g-clear-air marker left in $CONFIG"
		fi
		if [ -s "$OUT/checks.txt" ]; then
			:
		fi
	else
		if [ "$CONFIG_DIRTY" = 1 ]; then
			warn "the run was interrupted before the backup/restore was set up"
			_status=1
		fi
	fi

	[ "$FAILED" = 1 ] && _status=1
	[ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
	if [ -n "$OUT" ]; then
		printf 'artifacts: %s\n' "$OUT"
	fi
	# Release after the restore reload, so the hold covers the whole
	# disruptive window including the rollback.
	nw_guard_cleanup
	exit "$_status"
}

# --- dry run ----------------------------------------------------------

dry_run() {
	printf '6g-clear-air dry run\n'
	printf '  config: %s\n' "$CONFIG"
	printf '  output: %s (not created)\n' "${OUT_OPT:-/tmp/6g-clear-air.<timestamp>}"
	if ! command -v "$IW" >/dev/null 2>&1 && [ ! -x "$IW" ]; then
		printf '  iw: %s not found; a real run would print "SKIP: no 6G STA"\n' "$IW"
		printf 'dry run: no configuration write, no traffic\n'
		return 0
	fi
	refresh_live
	detect_6g_radio || true
	if [ -n "$RADIO" ]; then
		printf '  6G radio: %s (band %s)\n' "$RADIO" \
			"$(cfg_get_option "$RADIO" band 2>/dev/null || echo unset)"
	fi
	_recs=$(awk -F'|' '$5 == "AP" && ($3 + 0) >= 5925 && ($3 + 0) <= 7125' "$TMP_LIVE")
	if [ -n "$_recs" ]; then
		printf '  live 6G AP BSSes:\n'
		printf '%s\n' "$_recs" | while IFS='|' read -r _if _phy _freq _ssid _type _addr; do
			_n=$(station_macs "$_if" | awk 'NF { n++ } END { print n + 0 }')
			printf '    %s  phy %s  %s MHz  SSID "%s"  stations %s\n' \
				"$_if" "$_phy" "$_freq" "${_ssid:-(hidden)}" "$_n"
		done
	else
		printf '  live 6G AP BSSes: none\n'
	fi
	select_ap_and_sta
	_sel=$?
	case $_sel in
	0)
		printf '  selected: %s  STA %s  SSID "%s"\n' \
			"$SEL_IFACE" "$SEL_MAC" "${SEL_SSID:-(hidden)}"
		_plan=$(cfg_245_ap_records | awk -F'|' 'NF == 4 && $4 != "1" { printf "%s%s", sep, ($1 != "" ? $1 : $2); sep = " " }')
		printf '  clear arm: disable 5G/2.4G AP SSIDs%s, keep the 6G BSS and radios\n' \
			"${_plan:+ (${_plan})}"
		printf '  loaded arm: restore the pre-clear configuration\n'
		printf '  source AP->STA: %s\n' "$(iperf_command ap2sta)"
		printf '  source STA->AP: %s\n' "$(iperf_command sta2ap)"
		;;
	2)
		printf '  selected: %s (no station yet)\n' "$SEL_IFACE"
		if [ "$CREATE_BSS" = 1 ] && [ -z "$IFACE_OPT" ]; then
			if [ -n "$(live_6g_ap_by_ssid "$SSID" || true)" ]; then
				printf '  --create-bss: use the existing 6G-only BSS "%s" and wait up to %ss for the STA\n' \
					"$SSID" "$WAIT_STA"
			else
				printf '  --create-bss would append the marked 6G-only BSS "%s" on %s, then wait up to %ss for the STA\n' \
					"$SSID" "${RADIO:-the 6G radio}" "$WAIT_STA"
			fi
		elif [ "$CREATE_BSS" = 1 ]; then
			printf '  --create-bss: wait for a station up to %ss on this BSS\n' "$WAIT_STA"
		else
			printf '  a real run would print "SKIP: no 6G STA"\n'
		fi
		;;
	*)
		printf '  no 6G station is visible\n'
		if [ "$CREATE_BSS" = 1 ]; then
			if [ -n "$(live_6g_ap_by_ssid "$SSID" || true)" ]; then
				printf '  --create-bss: use the existing 6G-only BSS "%s" and wait up to %ss for the STA\n' \
					"$SSID" "$WAIT_STA"
			else
				printf '  --create-bss would append:\n'
				printf '    %s\n' "$MARK_BEGIN"
				printf '    config wifi-iface %s (device %s, ssid %s, SAE)\n' \
					"$BSS_SECTION" "${RADIO:-radio2}" "$SSID"
				printf '    %s\n' "$MARK_END"
				printf '  then wait up to %ss for the STA\n' "$WAIT_STA"
			fi
		else
			printf '  a real run would print "SKIP: no 6G STA"\n'
		fi
		;;
	esac
	printf '  config: no write in dry run; 5G/2.4G SSIDs are only disabled in a real clear arm\n'
	printf 'dry run: no configuration write, no traffic\n'
	return 0
}

# --- main -------------------------------------------------------------

main() {
	CMDLINE=$*
	parse_args "$@"

	if [ "$DRY_RUN" = 1 ]; then
		dry_run
		exit 0
	fi

	if ! command -v "$IW" >/dev/null 2>&1 && [ ! -x "$IW" ]; then
		skip_no_sta "iw ($IW) is not available"
	fi
	if ! "$IW" dev >/dev/null 2>&1; then
		skip_no_sta "iw dev returned an error"
	fi

	select_ap_and_sta
	_sel=$?
	if [ "$_sel" -eq 0 ]; then
		[ -n "$TARGET" ] ||
			usage_error "--target is required when a 6G STA is associated"
		need_cmd "$IPERF3"
		need_cmd md5sum
		prepare_run
	elif [ "$_sel" -eq 2 ] && [ "$CREATE_BSS" = 1 ]; then
		[ -n "$TARGET" ] ||
			usage_error "--target is required with --create-bss"
		need_cmd "$IPERF3"
		need_cmd md5sum
		prepare_run
		if [ -z "$IFACE_OPT" ]; then
			# No station yet: create/look up the dedicated 6G-only BSS
			# rather than waiting on whichever BSS happened to be first.
			create_marked_bss
		fi
		say "waiting for a 6G STA on $SEL_IFACE (up to ${WAIT_STA}s)"
		wait_for_sta "$SEL_IFACE" "$STA_OPT" "$WAIT_STA" ||
			skip_no_sta "no station associated on $SEL_IFACE"
		pick_sta_after_wait || skip_no_sta "no station associated on $SEL_IFACE"
	elif [ "$CREATE_BSS" = 1 ]; then
		[ -n "$TARGET" ] ||
			usage_error "--target is required with --create-bss"
		need_cmd "$IPERF3"
		need_cmd md5sum
		prepare_run
		create_marked_bss
		say "waiting for a 6G STA on $SEL_IFACE (up to ${WAIT_STA}s)"
		wait_for_sta "$SEL_IFACE" "$STA_OPT" "$WAIT_STA" ||
			skip_no_sta "no station associated on the created 6G-only BSS"
		pick_sta_after_wait || skip_no_sta "no station associated on the created 6G-only BSS"
	else
		skip_no_sta "no station is associated on a 6 GHz AP BSS"
	fi

	[ -n "$SEL_MAC" ] || pick_sta_after_wait ||
		die "could not select a 6G STA"
	if [ -z "$TOKEN_PATH" ]; then
		warn "mt76 token_info not found under $DEBUGFS; token evidence will be n/a"
	fi
	save_work
	if [ "$SEL_6G_ONLY" = "no" ]; then
		warn "the selected SSID is also served on 5/2.4 GHz; the loaded arm restores those copies. Use a dedicated 6G-only BSS (--create-bss) if the client may roam off 6 GHz."
	fi
	say "STA: $SEL_MAC  BSS: $SEL_IFACE ($SEL_FREQ MHz, SSID ${SEL_SSID:-(hidden)})"
	say "STA must run: iperf3 -s -p $PORT"
	say "device under test: $CONFIG"

	disable_245_ssids
	reload_and_wait
	verify_clear_arm
	measure_arm clear
	restore_loaded_ssids
	verify_loaded_arm
	measure_arm loaded
	print_results
	cleanup 0
}

verify_clear_arm() {
	refresh_live
	_rec=$(live_iface_record "$SEL_IFACE" || true)
	if [ -n "$_rec" ]; then
		require_check PASS "clear arm: 6G AP $SEL_IFACE is live"
	else
		require_check FAIL "clear arm: 6G AP $SEL_IFACE is not live"
	fi
	wait_for_sta "$SEL_IFACE" "$SEL_MAC" 1 ||
		require_check FAIL "clear arm: STA $SEL_MAC is not associated"

	# The 6G BSS must keep the width it had before the reload.  A clear arm
	# that quietly came back at 160 MHz measures a different airtime than
	# the loaded arm, so the whole comparison would be void.
	_livew=$(printf '%s' "$_rec" | cut -d'|' -f7)
	if [ -z "$_livew" ] || [ "$_livew" = 0 ]; then
		require_check FAIL "clear arm: 6G AP $SEL_IFACE reports no channel width"
	elif [ -n "$SEL_WIDTH" ] && [ "$_livew" != "$SEL_WIDTH" ]; then
		require_check FAIL "clear arm: 6G AP $SEL_IFACE width ${SEL_WIDTH} MHz -> ${_livew} MHz after the reload"
	else
		require_check PASS "clear arm: 6G AP $SEL_IFACE keeps ${_livew} MHz"
	fi

	# Scan every live AP record, not only the sections this script disabled:
	# an SSID that was already off in the config, or one on a band the
	# disable pass did not cover, still breaks the "clear air" claim.
	_left=$(awk -F'|' '
		$5 == "AP" && ($3 + 0) > 0 && ($3 + 0) < 5925 { printf "%s(%s MHz) ", $1, $3 }
	' "$TMP_LIVE")
	if [ -n "$_left" ]; then
		require_check FAIL "clear arm: these AP BSS are still up below 6 GHz: ${_left% }"
	else
		require_check PASS "clear arm: no AP BSS is up on a 5/2.4 GHz channel"
	fi

	_6g_ssid_live=$(live_6g_ap_by_ssid "$SEL_SSID" || true)
	if [ -n "$SEL_SSID" ]; then
		if [ -n "$_6g_ssid_live" ]; then
			require_check PASS "clear arm: SSID '$SEL_SSID' is still served on 6 GHz"
		else
			require_check FAIL "clear arm: SSID '$SEL_SSID' is not served on 6 GHz"
		fi
	fi
}

verify_loaded_arm() {
	refresh_live
	_rec=$(live_iface_record "$SEL_IFACE" || true)
	if [ -n "$_rec" ]; then
		require_check PASS "loaded arm: 6G AP $SEL_IFACE is live"
	else
		require_check FAIL "loaded arm: 6G AP $SEL_IFACE is not live"
	fi
	wait_for_sta "$SEL_IFACE" "$SEL_MAC" 1 ||
		require_check FAIL "loaded arm: STA $SEL_MAC is not associated"
	if [ "$(md5_of "$CONFIG")" = "$WORK_MD5" ]; then
		require_check PASS "loaded arm: config restored to the pre-clear md5 $WORK_MD5"
	else
		require_check FAIL "loaded arm: config md5 does not match the pre-clear copy"
	fi
	_bad=
	for _s in $NEWLY_DISABLED_SECTIONS; do
		[ "$(cfg_iface_disabled "$_s")" = "1" ] && _bad="$_bad $_s"
	done
	[ -z "$_bad" ] ||
		require_check FAIL "loaded arm: these restored SSIDs are still disabled:$_bad"
}

# --- entry point ------------------------------------------------------

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/6g-clear-air.XXXXXX" 2>/dev/null || true)
if [ -z "$TMP_DIR" ]; then
	TMP_DIR=${TMPDIR:-/tmp}/6g-clear-air.$$
	mkdir -p "$TMP_DIR" || die "cannot create temporary directory $TMP_DIR"
fi
TMP_IW=$TMP_DIR/iw-dev.txt
TMP_LIVE=$TMP_DIR/live.txt
TMP_CFG=$TMP_DIR/config.records
TMP_OFF6G=$TMP_DIR/off6g-ssids.txt
TMP_CANDS=$TMP_DIR/candidates.txt
TMP_WITH_STA=$TMP_DIR/with-sta.txt
TMP_DISABLED_SSIDS=$TMP_DIR/disabled-ssids.txt
: >"$TMP_IW"
: >"$TMP_LIVE"
: >"$TMP_CFG"
: >"$TMP_OFF6G"
: >"$TMP_CANDS"
: >"$TMP_WITH_STA"
: >"$TMP_DISABLED_SSIDS"

trap 'rm -rf "$TMP_DIR"' EXIT
main "$@"
