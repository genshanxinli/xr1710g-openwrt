#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# shellcheck disable=SC2329
#
# mlo-3link.sh - one-shot, gated 3-link MLO negative test.
#
# This is a NEGATIVE test, not a bring-up harness and not a tuning tool.  It
# appends exactly one marked wifi-iface with three device entries on 2.4 + 5 +
# 6 GHz, reloads the wireless stack once, waits once for an AP MLD with
# links=3, waits once for a station on the test SSID, runs exactly one short
# traffic window, records the evidence, and restores /etc/config/wireless from
# a backup in an EXIT/INT/TERM/HUP trap.  It never loops and never retries
# after a black-hole.
#
# Why the gates are hard:
#   3-link MLO is a known community per-station unicast black-hole / cold
#   reboot risk.  netwatchdog would reboot the box when the test takes the
#   network away; a cold reboot is the worst case, because the marked block in
#   /etc/config/wireless is persistent and the watchdog hold in /tmp is not.
#   A USB-TTL console is then the only recovery path.  The script refuses to
#   write any config unless ALL of these hold:
#
#     1. netwatchdog reports an active hold (/tmp/netwatchdog.hold);
#     2. --i-understand-risk was passed;
#     3. --serial names a usable USB serial console, or --no-serial is
#        explicitly acknowledged.
#
# One-shot rules:
#   - exactly one add -> reload -> association -> traffic -> restore cycle;
#   - a missing link, a missing station, a disconnected station or a
#     black-hole stops the run and restores; nothing is retried;
#   - the marked block is never left active on purpose;
#   - the backup and the evidence live on the overlay (/root/mlo-3link), not
#     in /tmp, so a cold-rebooted box can still be recovered over serial;
#   - after a verified restore the raw backup is removed; only the md5 and a
#     redacted snapshot remain in the run directory.
#
# Traffic window:
#   --traffic auto prefers iperf3 and falls back to ping.  The AP MLD is not
#   bridged (it must not disturb the production bridge), so --local-ip adds a
#   private address to the test MLD for the window and removes it on exit.
#   --peer is the 3-link client's address on that private network.
#
# Serial fallback (keep this open before the run):
#   adapter   3.3 V USB-TTL on the XR1710G debug UART, GND first
#   terminal  picocom -b 115200 /dev/ttyUSB0, 8N1, no flow control
#   if the box stops answering or cold-reboots:
#     cp /root/mlo-3link/wireless.bak /etc/config/wireless
#     wifi reload
#   or remove only the marked block:
#     uci -q delete wireless.mlo3link; uci commit wireless; wifi reload
#   if userspace never comes up, boot the initramfs recovery image from the
#   U-Boot recovery console; do not reflash unless the bootloader is wedged.
#
# Exit status:
#   0    one-shot completed, no black-hole symptom, config restored
#   1    safety failure: restore failed or a required command timed out
#   2    usage error, missing gate or unsupported environment (no config write)
#   3    black-hole symptom observed (test completed and config restored)
#   4    one-shot inconclusive: links != 3, no 3-link station, no traffic tool
#   129/130/143  interrupted by HUP/INT/TERM; the trap restored the config
#
# The script is POSIX sh and runs with busybox ash, so it runs on the device.

set -u
set -f
LC_ALL=C
export LC_ALL

PROG=${0##*/}
MAIN_PID=$$
MARKER=mlo-3link
SECTION=mlo3link

# Defaults.  Every knob is also an MLO3_* environment variable; a flag wins.
SSID=${MLO3_SSID:-MLO-3LINK-NEG}
KEY=${MLO3_KEY:-mlo3linktest}
CONFIG=${MLO3_CONFIG:-/etc/config/wireless}
STATE_DIR=${MLO3_STATE_DIR:-/root/mlo-3link}
PEER=${MLO3_PEER:-}
LOCAL_IP=${MLO3_LOCAL_IP:-}
STA=${MLO3_STA:-}
IFNAME=${MLO3_IFNAME:-}
SERIAL=${MLO3_SERIAL:-}
DURATION=${MLO3_DURATION:-10}
PARALLEL=${MLO3_PARALLEL:-1}
ASSOC_TIMEOUT=${MLO3_ASSOC_TIMEOUT:-180}
STATION_TIMEOUT=${MLO3_STATION_TIMEOUT:-90}
HARD_TIMEOUT=${MLO3_HARD_TIMEOUT:-600}
CMD_TIMEOUT=${MLO3_CMD_TIMEOUT:-15}
TRAFFIC=${MLO3_TRAFFIC:-auto}

MODE=run
DRY_RUN=0
RISK=0
NO_SERIAL=0
VERBOSE=0

# Runtime state.
CFG_DIR=
BAK=
BAK_MD5=
POST_MD5=
STATE_META=
CAPTURE=
LOG_FILE=
CONFIG_MODIFIED=0
RELOADED=0
IP_ADDED=0
MLD=
STATION=
STATION_LINKS=
TRAFFIC_TOOL=
TRAFFIC_OK=0
TRAFFIC_TIMEOUT=0
TRAFFIC_BITS=
TRAFFIC_LOSS=
TRAFFIC_TX=
TRAFFIC_RX=
RESULT=
STOP=
LINKS_AT_STOP=
RESTORE_VERIFIED=0
RESTORE_OK=1
BACKUP_PURGED=0
DONE=0
LOCKED=0
LOCK_DIR=
WATCHDOG_PID=
DMESG_BASE=0
HOSTAPD_BASE=0
BOOT_ID=
GATE_RISK=0
GATE_HOLD=0
GATE_SERIAL=0
GATE_RISK_MSG=
GATE_HOLD_MSG=
GATE_SERIAL_MSG=
NW_WHY=
SERIAL_WHY=
PICKED=
PICKED_DISABLED=0
DEV24=
DEV5=
DEV6=
LINK_MAP=

say() {
	printf '%s\n' "$*"
	if [ -n "$LOG_FILE" ]; then
		printf '%s\n' "$*" >>"$LOG_FILE" 2>/dev/null || :
	fi
}

warn() {
	printf '%s: warning: %s\n' "$PROG" "$*" >&2
	if [ -n "$LOG_FILE" ]; then
		printf 'warning: %s\n' "$*" >>"$LOG_FILE" 2>/dev/null || :
	fi
}

die_usage() {
	printf '%s: %s\n' "$PROG" "$*" >&2
	printf 'Try %s --help.\n' "$PROG" >&2
	exit 2
}

die() {
	printf '%s: error: %s\n' "$PROG" "$*" >&2
	if [ -n "$LOG_FILE" ]; then
		printf 'error: %s\n' "$*" >>"$LOG_FILE" 2>/dev/null || :
	fi
	[ -n "$RESULT" ] || RESULT=error
	exit 1
}

have() {
	command -v "$1" >/dev/null 2>&1
}

need_cmd() {
	have "$1" || die "required command not found: $1"
}

md5_of() {
	md5sum "$1" 2>/dev/null | awk '{print $1}'
}

uci_get() {
	uci -q -c "$CFG_DIR" get "$1" 2>/dev/null || :
}

list_sections() {
	uci -q -c "$CFG_DIR" show wireless 2>/dev/null |
		sed -n "s/^wireless\.\([^.=]*\)=wifi-$1\$/\1/p"
}

radio_band() {
	case "$(uci_get "wireless.$1.band")" in
	2g|2.4g|2.4|bg) printf '2.4\n' ;;
	5g) printf '5g\n' ;;
	6g) printf '6g\n' ;;
	*) printf '\n' ;;
	esac
}

radio_is_disabled() {
	case "$(uci_get "wireless.$1.disabled")" in
	1|true|yes) return 0 ;;
	*) return 1 ;;
	esac
}

radio_index() {
	uci_get "wireless.$1.radio"
}

find_radio() {
	# find_radio BAND -> sets PICKED to the first wifi-device of that band.
	PICKED=
	PICKED_DISABLED=0
	for _sec in $(list_sections device); do
		[ -n "$_sec" ] || continue
		[ "$(radio_band "$_sec")" = "$1" ] || continue
		PICKED=$_sec
		radio_is_disabled "$_sec" && PICKED_DISABLED=1
		return 0
	done
	return 1
}

select_radios() {
	DEV24=
	DEV5=
	DEV6=
	LINK_MAP=

	find_radio 2.4 || die "no 2.4 GHz wifi-device in $CONFIG"
	DEV24=$PICKED
	[ "$PICKED_DISABLED" = 0 ] ||
		die "wireless.$DEV24 (2.4 GHz) is disabled; enable it for the experiment first: uci set wireless.$DEV24.disabled=0; uci commit wireless; wifi reload"

	find_radio 5g || die "no 5 GHz wifi-device in $CONFIG"
	DEV5=$PICKED
	[ "$PICKED_DISABLED" = 0 ] ||
		die "wireless.$DEV5 (5 GHz) is disabled; enable it for the experiment first: uci set wireless.$DEV5.disabled=0; uci commit wireless; wifi reload"

	find_radio 6g || die "no 6 GHz wifi-device in $CONFIG"
	DEV6=$PICKED
	[ "$PICKED_DISABLED" = 0 ] ||
		die "wireless.$DEV6 (6 GHz) is disabled; enable it for the experiment first: uci set wireless.$DEV6.disabled=0; uci commit wireless; wifi reload"

	[ "$DEV24" != "$DEV5" ] && [ "$DEV24" != "$DEV6" ] && [ "$DEV5" != "$DEV6" ] ||
		die "the 2.4/5/6 GHz bands do not resolve to three distinct wifi-device sections"

	_r24=$(radio_index "$DEV24")
	_r5=$(radio_index "$DEV5")
	_r6=$(radio_index "$DEV6")
	case "$_r24" in ''|*[!0-9]*) die "wireless.$DEV24 has no numeric radio index" ;; esac
	case "$_r5" in ''|*[!0-9]*) die "wireless.$DEV5 has no numeric radio index" ;; esac
	case "$_r6" in ''|*[!0-9]*) die "wireless.$DEV6 has no numeric radio index" ;; esac
	[ "$_r24" != "$_r5" ] && [ "$_r24" != "$_r6" ] && [ "$_r5" != "$_r6" ] ||
		die "the 2.4/5/6 GHz radios share a radio index; a 3-link MLD needs three distinct link IDs"

	LINK_MAP="$_r24:2.4 $_r5:5g $_r6:6g"
	return 0
}

plan_radios() {
	# Read-only radio selection for --dry-run.  Missing or disabled radios are
	# reported, not fatal; the generated block still shows the intended shape.
	DEV24=
	DEV5=
	DEV6=
	LINK_MAP=
	find_radio 2.4 && DEV24=$PICKED
	[ -n "$DEV24" ] && [ "$PICKED_DISABLED" = 1 ] && say "dry-run: wireless.$DEV24 (2.4 GHz) is disabled; a real run would refuse"
	find_radio 5g && DEV5=$PICKED
	[ -n "$DEV5" ] && [ "$PICKED_DISABLED" = 1 ] && say "dry-run: wireless.$DEV5 (5 GHz) is disabled; a real run would refuse"
	find_radio 6g && DEV6=$PICKED
	[ -n "$DEV6" ] && [ "$PICKED_DISABLED" = 1 ] && say "dry-run: wireless.$DEV6 (6 GHz) is disabled; a real run would refuse"
	[ -n "$DEV24" ] || DEV24=radio24
	[ -n "$DEV5" ] || DEV5=radio5
	[ -n "$DEV6" ] || DEV6=radio6
	_r24=$(radio_index "$DEV24")
	_r5=$(radio_index "$DEV5")
	_r6=$(radio_index "$DEV6")
	case "$_r24" in ''|*[!0-9]*) _r24=0 ;; esac
	case "$_r5" in ''|*[!0-9]*) _r5=1 ;; esac
	case "$_r6" in ''|*[!0-9]*) _r6=2 ;; esac
	LINK_MAP="$_r24:2.4 $_r5:5g $_r6:6g"
}

config_has_block() {
	[ -f "$CONFIG" ] && grep -q "^# >>> $MARKER: BEGIN" "$CONFIG" 2>/dev/null
}

section_exists() {
	uci -q -c "$CFG_DIR" show "wireless.$1" >/dev/null 2>&1
}

check_existing() {
	config_has_block &&
		die "a marked $MARKER block is already present in $CONFIG; run --restore first"

	section_exists "$SECTION" &&
		die "wireless.$SECTION already exists without the marker; run --restore first"

	for _sec in $(list_sections iface); do
		[ -n "$_sec" ] || continue
		[ "$_sec" = "$SECTION" ] && continue
		if [ "$(uci_get "wireless.$_sec.ssid")" = "$SSID" ]; then
			die "another wifi-iface ($_sec) already uses SSID $SSID; refusing to duplicate it"
		fi
		[ "$(uci_get "wireless.$_sec.mlo")" = 1 ] || continue
		_devs=" $(uci_get "wireless.$_sec.device") "
		for _dev in "$DEV24" "$DEV5" "$DEV6"; do
			case "$_devs" in
			*" $_dev "*)
				die "existing MLO iface $_sec already uses $_dev; refusing to build a second MLD on it"
				;;
			esac
		done
	done
}

block_text() {
	cat <<EOF
# >>> $MARKER: BEGIN (one-shot 3-link MLO negative test; removed by the script's trap)
config wifi-iface '$SECTION'
	list device '$DEV24'
	list device '$DEV5'
	list device '$DEV6'
	option mlo '1'
	option mode 'ap'
	option ssid '$SSID'
	option encryption 'sae'
	option key '$KEY'
	option ieee80211w '2'
	option disabled '0'
# <<< $MARKER: END
EOF
}

write_meta() {
	[ -n "${STATE_META:-}" ] || return 0
	{
		printf 'active=%s\n' "$1"
		printf 'config=%s\n' "$CONFIG"
		printf 'ssid=%s\n' "$SSID"
		printf 'band1=%s\n' "$DEV24"
		printf 'band2=%s\n' "$DEV5"
		printf 'band3=%s\n' "$DEV6"
		printf 'link_map=%s\n' "$LINK_MAP"
		printf 'serial=%s\n' "$([ -n "$SERIAL" ] && printf '%s' "$SERIAL" || printf 'none')"
		printf 'ts=%s\n' "$(date +%s)"
	} >"$STATE_META" 2>/dev/null || {
		warn "cannot write $STATE_META"
		return 1
	}
	chmod 600 "$STATE_META" 2>/dev/null || :
	return 0
}

acquire_lock() {
	LOCK_DIR="/tmp/mlo-3link.lock"
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		printf '%s\n' "$$" >"$LOCK_DIR/pid" 2>/dev/null || :
		LOCKED=1
		return 0
	fi
	_old=
	[ -f "$LOCK_DIR/pid" ] && _old=$(cat "$LOCK_DIR/pid" 2>/dev/null)
	case "$_old" in ''|*[!0-9]*) _old= ;; esac
	if [ -n "$_old" ] && kill -0 "$_old" 2>/dev/null; then
		die "another mlo-3link run is active (pid $_old)"
	fi
	rm -rf "$LOCK_DIR" 2>/dev/null || die "cannot remove the stale lock $LOCK_DIR"
	mkdir "$LOCK_DIR" 2>/dev/null || die "cannot lock $LOCK_DIR"
	printf '%s\n' "$$" >"$LOCK_DIR/pid" 2>/dev/null || :
	LOCKED=1
}

release_lock() {
	[ "$LOCKED" = 1 ] || return 0
	rm -rf "$LOCK_DIR" 2>/dev/null || :
	LOCKED=0
}

setup_capture() {
	mkdir -p "$STATE_DIR" 2>/dev/null || die "cannot create $STATE_DIR"
	chmod 700 "$STATE_DIR" 2>/dev/null || :
	CAPTURE="$STATE_DIR/runs/$(date +%Y%m%d-%H%M%S)-$$"
	mkdir -p "$CAPTURE" 2>/dev/null || die "cannot create $CAPTURE"
	chmod 700 "$CAPTURE" 2>/dev/null || :
	LOG_FILE="$CAPTURE/run.log"
	: >>"$LOG_FILE" 2>/dev/null || :
}

start_watchdog() {
	[ "$HARD_TIMEOUT" -gt 0 ] || return 0
	(
		_i=0
		while [ "$_i" -lt "$HARD_TIMEOUT" ]; do
			sleep 1
			_i=$((_i + 1))
		done
		printf 'watchdog: hard deadline %ss expired; terminating the run\n' "$HARD_TIMEOUT" \
			>>"$CAPTURE/watchdog.log" 2>/dev/null || :
		kill -TERM "$MAIN_PID" 2>/dev/null || :
	) &
	WATCHDOG_PID=$!
}

stop_watchdog() {
	[ -n "$WATCHDOG_PID" ] || return 0
	kill "$WATCHDOG_PID" 2>/dev/null || :
	wait "$WATCHDOG_PID" 2>/dev/null || :
	WATCHDOG_PID=
}

run_limited() {
	# run_limited SECONDS COMMAND... ; returns the command status, or 124 (and
	# 143 when busybox timeout kills with TERM) when the limit expired.
	_limit=$1
	shift
	if [ "$_limit" -le 0 ]; then
		"$@"
		return $?
	fi
	if have timeout; then
		timeout "$_limit" "$@"
		return $?
	fi
	"$@" &
	_cmd_pid=$!
	(
		_i=0
		while [ "$_i" -lt "$_limit" ]; do
			sleep 1
			_i=$((_i + 1))
		done
		kill -TERM "$_cmd_pid" 2>/dev/null || :
	) &
	_killer_pid=$!
	wait "$_cmd_pid"
	_cmd_rc=$?
	kill "$_killer_pid" 2>/dev/null || :
	wait "$_killer_pid" 2>/dev/null || :
	[ "$_cmd_rc" -eq 143 ] && return 124
	return "$_cmd_rc"
}

fatal_timeout() {
	RESULT=command-timeout
	STOP=$1
	printf '%s: error: %s\n' "$PROG" "$1" >&2
	# This can be called from a command-substitution subshell.  A plain
	# "exit" would only leave that subshell, so signal the main shell: its
	# TERM trap runs in the parent and the EXIT trap restores the config.
	[ -n "$CAPTURE" ] && printf '%s\n' "$1" >"$CAPTURE/command-timeout.txt" 2>/dev/null || :
	kill -TERM "$MAIN_PID" 2>/dev/null || :
	exit 1
}

iw_read() {
	# iw_read OUTPUT_FILE IW-ARGS... ; a hung iw is fatal so the trap restores.
	_out=$1
	shift
	run_limited "$CMD_TIMEOUT" iw "$@" >"$_out" 2>"$_out.err"
	_rc=$?
	case "$_rc" in
	124|143)
		rm -f "$_out.err"
		fatal_timeout "iw $* timed out after ${CMD_TIMEOUT}s"
		;;
	esac
	rm -f "$_out.err"
	return "$_rc"
}

iw_capture() {
	# Best-effort iw read for the evidence and for cleanup; never fatal.
	_out=$1
	shift
	run_limited "$CMD_TIMEOUT" iw "$@" >"$_out" 2>&1 || :
}

dmesg_capture() {
	# dmesg_capture OUTPUT_FILE ; fatal only in the main flow.
	_out=$1
	run_limited "$CMD_TIMEOUT" dmesg >"$_out" 2>/dev/null
	_rc=$?
	case "$_rc" in
	124|143) fatal_timeout "dmesg timed out after ${CMD_TIMEOUT}s" ;;
	esac
	return 0
}

dmesg_capture_quiet() {
	_out=$1
	run_limited "$CMD_TIMEOUT" dmesg >"$_out" 2>/dev/null || :
}

logread_capture() {
	# logread_capture OUTPUT_FILE ; best effort, bounded.
	_out=$1
	run_limited "$CMD_TIMEOUT" logread >"$_out" 2>/dev/null || :
}

backup_config() {
	[ -f "$CONFIG" ] || die "missing $CONFIG"
	[ -w "$CONFIG" ] || die "$CONFIG is not writable"
	mkdir -p "$STATE_DIR" 2>/dev/null || die "cannot create $STATE_DIR"
	chmod 700 "$STATE_DIR" 2>/dev/null || :
	BAK="$STATE_DIR/wireless.bak"
	BAK_MD5="$STATE_DIR/wireless.bak.md5"
	POST_MD5="$STATE_DIR/wireless.post.md5"
	STATE_META="$STATE_DIR/state"
	cp -p "$CONFIG" "$BAK" 2>/dev/null || cp "$CONFIG" "$BAK" ||
		die "cannot back up $CONFIG to $BAK"
	chmod 600 "$BAK" 2>/dev/null || :
	_md5=$(md5_of "$BAK")
	[ -n "$_md5" ] || die "cannot compute the md5 of $BAK"
	printf '%s\n' "$_md5" >"$BAK_MD5" || die "cannot write $BAK_MD5"
	write_meta 0
}

append_block() {
	_tmp="${CONFIG}.mlo3link.$$"
	_tdir="${STATE_DIR}/uci-check.$$"
	rm -rf "$_tdir"
	mkdir -p "$_tdir" 2>/dev/null || die "cannot create $_tdir"

	cp -p "$CONFIG" "$_tmp" 2>/dev/null || cp "$CONFIG" "$_tmp" ||
		die "cannot stage $CONFIG"
	if [ -s "$_tmp" ] && [ -n "$(tail -c 1 "$_tmp" 2>/dev/null)" ]; then
		printf '\n' >>"$_tmp" || { rm -f "$_tmp"; rm -rf "$_tdir"; die "cannot append a separator"; }
	fi
	block_text >>"$_tmp" || { rm -f "$_tmp"; rm -rf "$_tdir"; die "cannot write the block"; }

	cp "$_tmp" "$_tdir/wireless" 2>/dev/null || {
		rm -f "$_tmp"
		rm -rf "$_tdir"
		die "cannot stage the generated config"
	}
	if ! uci -q -c "$_tdir" show wireless >/dev/null 2>&1; then
		rm -f "$_tmp"
		rm -rf "$_tdir"
		die "the generated wireless config does not parse"
	fi
	rm -rf "$_tdir"

	_bak_md5=$(cat "$BAK_MD5" 2>/dev/null)
	_cur_md5=$(md5_of "$CONFIG")
	if [ -n "$_bak_md5" ] && [ "$_cur_md5" != "$_bak_md5" ]; then
		rm -f "$_tmp"
		die "$CONFIG changed after the backup; refusing to append"
	fi

	CONFIG_MODIFIED=1
	if ! cat "$_tmp" >"$CONFIG" 2>/dev/null; then
		rm -f "$_tmp"
		die "cannot replace $CONFIG"
	fi
	rm -f "$_tmp"
	_post_md5=$(md5_of "$CONFIG")
	[ -n "$_post_md5" ] || die "cannot compute the md5 of the generated config"
	printf '%s\n' "$_post_md5" >"$POST_MD5" || die "cannot write $POST_MD5"
	write_meta 1
}

strip_block() {
	[ -f "$CONFIG" ] || return 1
	_out="${CONFIG}.strip.$$"
	awk -v begin="^# >>> $MARKER: BEGIN" -v end="^# <<< $MARKER: END" '
		$0 ~ begin { skip = 1; next }
		$0 ~ end   { skip = 0; next }
		!skip      { print }
	' "$CONFIG" >"$_out" 2>/dev/null || {
		rm -f "$_out"
		return 1
	}
	if ! cat "$_out" >"$CONFIG" 2>/dev/null; then
		rm -f "$_out"
		return 1
	fi
	rm -f "$_out"
	return 0
}

remove_section() {
	section_exists "$SECTION" || return 1
	uci -q -c "$CFG_DIR" delete "wireless.$SECTION" >/dev/null 2>&1 || return 1
	uci -q -c "$CFG_DIR" commit wireless >/dev/null 2>&1 || return 1
	return 0
}

reload_wireless() {
	# reload_wireless [quiet] ; a hung reload is bounded.  A timeout is fatal
	# during the main flow and ignored during cleanup.
	_quiet=${1:-}
	RELOADED=1
	if have wifi; then
		run_limited 60 wifi reload >/dev/null 2>&1
		_rc=$?
	elif have ubus; then
		run_limited 60 ubus call network reload >/dev/null 2>&1
		_rc=$?
	else
		[ "$_quiet" = quiet ] || die "neither wifi nor ubus is available"
		return 1
	fi
	case "$_rc" in
	124|143)
		[ "$_quiet" = quiet ] || fatal_timeout "wifi reload timed out after 60s"
		;;
	esac
	return "$_rc"
}

wait_for_mld_gone() {
	_i=0
	while [ "$_i" -lt 20 ]; do
		_found=0
		for _if in $(run_limited 5 iw dev 2>/dev/null | awk '/^[ \t]*Interface / { print $2 }'); do
			_ssid=$(run_limited 5 iw dev "$_if" info 2>/dev/null |
				sed -n 's/^[ \t]*ssid //p' | head -n 1)
			if [ "$_ssid" = "$SSID" ]; then
				_found=1
				break
			fi
		done
		[ "$_found" = 0 ] && return 0
		sleep 1
		_i=$((_i + 1))
	done
	return 1
}

find_mld() {
	# Print the test MLD interface.  Uses iw_read, so a hung iw is fatal.
	if [ -n "$IFNAME" ]; then
		[ -d "/sys/class/net/$IFNAME" ] || return 1
		printf '%s\n' "$IFNAME"
		return 0
	fi
	_dev="${STATE_DIR}/.iw-dev.$$"
	_info="${STATE_DIR}/.iw-info.$$"
	_ifs="${STATE_DIR}/.iw-ifs.$$"
	iw_read "$_dev" dev || { rm -f "$_dev" "$_info" "$_ifs"; return 1; }
	awk '/^[ \t]*Interface / { print $2 }' "$_dev" >"$_ifs" 2>/dev/null || :
	_found=
	while IFS= read -r _if; do
		[ -n "$_if" ] || continue
		iw_read "$_info" dev "$_if" info 2>/dev/null || continue
		_ssid=$(sed -n 's/^[ \t]*ssid //p' "$_info" 2>/dev/null | head -n 1)
		[ "$_ssid" = "$SSID" ] || continue
		_n=$(awk '/^[ \t]*- link ID/ { n++ } END { print n + 0 }' "$_info" 2>/dev/null)
		if [ "$_n" -gt 0 ]; then
			_found=$_if
			break
		fi
	done <"$_ifs"
	rm -f "$_dev" "$_info" "$_ifs"
	[ -n "$_found" ] || return 1
	printf '%s\n' "$_found"
	return 0
}

link_count() {
	[ -n "$1" ] || { printf '0\n'; return 0; }
	_f="${STATE_DIR}/.iw-links.$$"
	iw_read "$_f" dev "$1" info 2>/dev/null || { rm -f "$_f"; return 1; }
	_n=$(awk '/^[ \t]*- link ID/ { n++ } END { print n + 0 }' "$_f" 2>/dev/null)
	rm -f "$_f"
	printf '%s\n' "${_n:-0}"
}

print_links() {
	[ -n "$1" ] || return 1
	_f="${STATE_DIR}/.iw-links.$$"
	iw_read "$_f" dev "$1" info 2>/dev/null || { rm -f "$_f"; return 1; }
	say "links: $(awk '/^[ \t]*- link ID/ { n++ } END { print n + 0 }' "$_f")"
	awk '
		/MLD with links:/ { inmlo = 1; next }
		inmlo && /^[ \t]*- link ID/ {
			if (cur != "")
				print cur
			line = $0
			sub(/^[ \t]*- /, "", line)
			cur = "  " line
			next
		}
		inmlo && cur != "" && /^[ \t]+channel / {
			line = $0
			sub(/^[ \t]+/, "", line)
			cur = cur "; " line
			next
		}
		inmlo && cur != "" && /^[ \t]+txpower / {
			line = $0
			sub(/^[ \t]+/, "", line)
			cur = cur "; " line
			next
		}
		END { if (cur != "") print cur }
	' "$_f"
	rm -f "$_f"
}

station_fields() {
	# station_fields DUMP_FILE [MAC] -> kind<TAB>link<TAB>field<TAB>value
	awk -v want="$2" '
		/^Station / {
			if (want != "" && $2 != want) {
				skip = 1
				next
			}
			skip = 0
			inlink = ""
			next
		}
		skip { next }
		/^\tLink [0-9]+:/ {
			inlink = $2
			sub(/:$/, "", inlink)
			next
		}
		substr($0, 1, 2) == "\t\t" {
			if (inlink == "")
				next
			line = $0
			sub(/^\t\t/, "", line)
			n = index(line, ":")
			if (!n)
				next
			key = substr(line, 1, n - 1)
			val = substr(line, n + 1)
			sub(/^[ \t]+/, "", val)
			sub(/[ \t]+$/, "", val)
			gsub(/ /, "_", key)
			print "link\t" inlink "\t" key "\t" val
			next
		}
		substr($0, 1, 1) == "\t" {
			if (inlink != "")
				next
			line = $0
			sub(/^\t/, "", line)
			n = index(line, ":")
			if (!n)
				next
			key = substr(line, 1, n - 1)
			val = substr(line, n + 1)
			sub(/^[ \t]+/, "", val)
			sub(/[ \t]+$/, "", val)
			gsub(/ /, "_", key)
			print "agg\t\t" key "\t" val
		}
	' "$1" 2>/dev/null
}

station_link_count() {
	station_fields "$1" "$2" |
		awk -F '\t' '$1 == "link" { seen[$2] = 1 } END { n = 0; for (l in seen) n++; print n + 0 }'
}

print_station_rates() {
	# Print the per-link station rate view.  Returns 1 when per-link data is
	# unavailable, which is not the same as a station with no rate.
	_in="${STATE_DIR}/.station-fields.$$"
	station_fields "$1" "$2" >"$_in" 2>/dev/null || return 1
	awk -F '\t' '
		$1 == "agg" && $3 == "tx_bitrate" { agg_tx = $4 }
		$1 == "agg" && $3 == "rx_bitrate" { agg_rx = $4 }
		$1 == "link" && $3 == "address" { addr[$2] = $4; have = 1 }
		$1 == "link" && $3 == "tx_bitrate" { tx[$2] = $4 }
		$1 == "link" && $3 == "rx_bitrate" { rx[$2] = $4 }
		$1 == "link" && $3 == "signal" { sig[$2] = $4 }
		END {
			if (!have) {
				if (agg_tx != "" || agg_rx != "")
					printf "  aggregate station rate: tx %s, rx %s\n", (agg_tx != "" ? agg_tx : "n/a"), (agg_rx != "" ? agg_rx : "n/a")
				exit 1
			}
			for (i = 0; i < 16; i++) {
				if (!(i in addr))
					continue
				printf "  link %d: addr %s\n", i, addr[i]
				printf "    tx bitrate: %s\n", (i in tx ? tx[i] : "n/a")
				printf "    rx bitrate: %s\n", (i in rx ? rx[i] : "n/a")
				printf "    signal: %s\n", (i in sig ? sig[i] : "n/a")
			}
			if (agg_tx != "" || agg_rx != "")
				printf "  aggregate station rate: tx %s, rx %s\n", (agg_tx != "" ? agg_tx : "n/a"), (agg_rx != "" ? agg_rx : "n/a")
		}
	' "$_in"
	_rc=$?
	rm -f "$_in"
	return "$_rc"
}

list_stations() {
	[ -n "$1" ] || return 0
	_f="${STATE_DIR}/.station-list.$$"
	run_limited "$CMD_TIMEOUT" iw dev "$1" station dump >"$_f" 2>/dev/null
	_rc=$?
	case "$_rc" in
	124|143)
		rm -f "$_f"
		fatal_timeout "iw dev $1 station dump timed out after ${CMD_TIMEOUT}s"
		;;
	esac
	awk '/^Station / { print $2 }' "$_f" 2>/dev/null
	rm -f "$_f"
}

station_dump_to() {
	# station_dump_to OUTPUT_FILE ; a timeout is fatal, a vanished MLD is not.
	run_limited "$CMD_TIMEOUT" iw dev "$MLD" station dump >"$1" 2>/dev/null
	_rc=$?
	case "$_rc" in
	124|143) fatal_timeout "iw dev $MLD station dump timed out after ${CMD_TIMEOUT}s" ;;
	esac
	return 0
}

station_present() {
	[ -n "$STATION" ] || return 1
	_f="${STATE_DIR}/.station-check.$$"
	station_dump_to "$_f"
	station_fields "$_f" "$STATION" | awk -F '\t' 'NR > 0 { found = 1 } END { exit(found ? 0 : 1) }'
	_rc=$?
	rm -f "$_f"
	return "$_rc"
}

wait_for_station() {
	_deadline=$(($(date +%s) + STATION_TIMEOUT))
	_last_count=
	while :; do
		_stas=$(list_stations "$MLD")
		_count=$(printf '%s\n' "$_stas" | awk 'NF { n++ } END { print n + 0 }')
		if [ -n "$STA" ]; then
			if [ "$_count" -gt 0 ] && station_present; then
				STATION=$STA
				return 0
			fi
		else
			if [ "$_count" -gt 1 ]; then
				warn "more than one station on $MLD; choose one with --sta"
				printf '%s\n' "$_stas" | sed 's/^/  station: /' >&2
				return 2
			fi
			if [ "$_count" -eq 1 ]; then
				STATION=$(printf '%s\n' "$_stas" | head -n 1)
				return 0
			fi
		fi
		if [ "$VERBOSE" = 1 ] || [ "$_count" != "$_last_count" ]; then
			say "waiting for the 3-link station: $_count associated"
		fi
		_last_count=$_count
		[ "$(date +%s)" -ge "$_deadline" ] && return 1
		sleep 2
	done
}

wait_for_links() {
	_deadline=$(($(date +%s) + ASSOC_TIMEOUT))
	_last=0
	MLD=
	LINKS_AT_STOP=0
	while :; do
		MLD=$(find_mld 2>/dev/null) || MLD=
		if [ -n "$MLD" ]; then
			LINKS_AT_STOP=$(link_count "$MLD")
			case "$LINKS_AT_STOP" in ''|*[!0-9]*) LINKS_AT_STOP=0 ;; esac
			if [ "$LINKS_AT_STOP" -eq 3 ]; then
				say "links=3 on $MLD"
				return 0
			fi
			if [ "$LINKS_AT_STOP" -gt 3 ]; then
				say "links=$LINKS_AT_STOP on $MLD (refusing more than three)"
				return 2
			fi
			if [ "$VERBOSE" = 1 ] || [ "$LINKS_AT_STOP" != "$_last" ]; then
				say "waiting for the third link: links=$LINKS_AT_STOP on $MLD"
			fi
			_last=$LINKS_AT_STOP
		elif [ "$VERBOSE" = 1 ]; then
			say "waiting for the test MLD to appear"
		fi
		if [ "$(date +%s)" -ge "$_deadline" ]; then
			return 1
		fi
		sleep 2
	done
}

redact_config() {
	awk '
		/^[[:space:]]*option[[:space:]]+/ {
			name = $2
			if (tolower(name) ~ /key/ || tolower(name) ~ /pass/ ||
			    tolower(name) ~ /secret/ || tolower(name) ~ /psk/) {
				print $1 " " name " <redacted>"
				next
			}
		}
		{ print }
	' "$CONFIG" 2>/dev/null || printf '<config unavailable>\n'
}

capture_before() {
	dmesg_capture "$CAPTURE/dmesg-before.txt"
	DMESG_BASE=$(wc -l <"$CAPTURE/dmesg-before.txt" 2>/dev/null || printf '0')
	case "$DMESG_BASE" in ''|*[!0-9]*) DMESG_BASE=0 ;; esac
	logread_capture "$CAPTURE/logread-before.txt"
	HOSTAPD_BASE=$(wc -l <"$CAPTURE/logread-before.txt" 2>/dev/null || printf '0')
	case "$HOSTAPD_BASE" in ''|*[!0-9]*) HOSTAPD_BASE=0 ;; esac
	iw_capture "$CAPTURE/iw-dev-before.txt" dev
	[ -n "$MLD" ] && iw_capture "$CAPTURE/mld-info-before.txt" dev "$MLD" info
	[ -n "$MLD" ] && station_dump_to "$CAPTURE/station-before.txt"
	BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || :)
	{
		printf 'date=%s\n' "$(date 2>/dev/null || :)"
		printf 'uname=%s\n' "$(uname -a 2>/dev/null || :)"
		printf 'uptime=%s\n' "$(cat /proc/uptime 2>/dev/null || :)"
		printf 'boot_id=%s\n' "$BOOT_ID"
	} >"$CAPTURE/system-before.txt" 2>/dev/null || :
	redact_config >"$CAPTURE/wireless.redacted" 2>/dev/null || :
}

capture_after() {
	[ -n "$CAPTURE" ] || return 0
	mkdir -p "$CAPTURE" 2>/dev/null || return 0
	iw_capture "$CAPTURE/iw-dev-after.txt" dev
	[ -n "$MLD" ] && iw_capture "$CAPTURE/mld-info-after.txt" dev "$MLD" info
	if [ -n "$MLD" ]; then
		run_limited "$CMD_TIMEOUT" iw dev "$MLD" station dump \
			>"$CAPTURE/station-after.txt" 2>/dev/null || :
	fi
	dmesg_capture_quiet "$CAPTURE/dmesg-after.txt"
	_now=$(wc -l <"$CAPTURE/dmesg-after.txt" 2>/dev/null || printf '0')
	case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
	if [ "$_now" -ge "$DMESG_BASE" ]; then
		tail -n "+$((DMESG_BASE + 1))" "$CAPTURE/dmesg-after.txt" \
			>"$CAPTURE/dmesg-new.txt" 2>/dev/null || :
	else
		cp "$CAPTURE/dmesg-after.txt" "$CAPTURE/dmesg-new.txt" 2>/dev/null || :
		warn "dmesg lost lines during the run (buffer wrapped)"
	fi
	logread_capture "$CAPTURE/logread-after.txt"
	_now=$(wc -l <"$CAPTURE/logread-after.txt" 2>/dev/null || printf '0')
	case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
	if [ "$_now" -ge "$HOSTAPD_BASE" ]; then
		tail -n "+$((HOSTAPD_BASE + 1))" "$CAPTURE/logread-after.txt" \
			>"$CAPTURE/logread-new.txt" 2>/dev/null || :
	else
		cp "$CAPTURE/logread-after.txt" "$CAPTURE/logread-new.txt" 2>/dev/null || :
	fi
	grep -Ei 'mlo|mt7996|blackhole|black-hole|unicast|tx timeout|reset|recovery|ser|failed to' \
		"$CAPTURE/dmesg-new.txt" >"$CAPTURE/dmesg-interesting.txt" 2>/dev/null || :
	grep -Eic 'mlo|mt7996|blackhole|black-hole|unicast|tx timeout|reset|recovery|ser|failed to' \
		"$CAPTURE/dmesg-new.txt" >"$CAPTURE/dmesg-interesting.count" 2>/dev/null || printf '0\n' \
		>"$CAPTURE/dmesg-interesting.count"
}

add_local_ip() {
	[ -n "$LOCAL_IP" ] || return 0
	[ -n "$MLD" ] || die "no MLD to add $LOCAL_IP to"
	need_cmd ip
	case "$LOCAL_IP" in
	*:*)
		die "IPv6 is not supported by the one-shot traffic window; use an IPv4 --local-ip"
		;;
	esac
	if run_limited "$CMD_TIMEOUT" ip addr show dev "$MLD" 2>/dev/null |
		grep -q "inet ${LOCAL_IP%/*}/"; then
		return 0
	fi
	run_limited "$CMD_TIMEOUT" ip addr add "$LOCAL_IP" dev "$MLD" >/dev/null 2>&1 ||
		die "cannot add $LOCAL_IP to $MLD"
	IP_ADDED=1
	run_limited "$CMD_TIMEOUT" ip link set "$MLD" up >/dev/null 2>&1 ||
		warn "could not bring $MLD up"
}

del_local_ip() {
	[ "$IP_ADDED" = 1 ] || return 0
	[ -n "$LOCAL_IP" ] && [ -n "$MLD" ] || return 0
	run_limited 5 ip addr del "$LOCAL_IP" dev "$MLD" >/dev/null 2>&1 || :
	IP_ADDED=0
}

resolve_traffic_tool() {
	for_plan=${1:-}
	case "$TRAFFIC" in
	ping)
		if have ping; then TRAFFIC_TOOL=ping; else
			[ "$for_plan" = plan ] && { TRAFFIC_TOOL=ping; return 0; }
			die "ping is required for --traffic ping but was not found"
		fi
		;;
	iperf3)
		if have iperf3; then TRAFFIC_TOOL=iperf3; else
			[ "$for_plan" = plan ] && { TRAFFIC_TOOL=iperf3; return 0; }
			die "iperf3 is required for --traffic iperf3 but was not found"
		fi
		;;
	auto)
		if have iperf3; then
			TRAFFIC_TOOL=iperf3
		elif have ping; then
			TRAFFIC_TOOL=ping
		elif [ "$for_plan" = plan ]; then
			TRAFFIC_TOOL=none
			return 0
		else
			die "neither iperf3 nor ping is available for the traffic window"
		fi
		;;
	*)
		die_usage "--traffic must be auto, iperf3 or ping"
		;;
	esac
	return 0
}

traffic_window() {
	TRAFFIC_OK=0
	TRAFFIC_TIMEOUT=0
	TRAFFIC_BITS=
	TRAFFIC_LOSS=
	TRAFFIC_TX=
	TRAFFIC_RX=
	add_local_ip

	# Exactly one traffic command.  The result is evidence; a timeout or a
	# total loss is a symptom, not a reason to retry.
	if [ "$TRAFFIC_TOOL" = iperf3 ]; then
		say "traffic window: one iperf3 run, ${DURATION}s, -P $PARALLEL, peer $PEER from ${LOCAL_IP%/*}"
		run_limited "$((DURATION + 60))" iperf3 -B "${LOCAL_IP%/*}" -c "$PEER" \
			-t "$DURATION" -P "$PARALLEL" -J \
			>"$CAPTURE/iperf3.json" 2>"$CAPTURE/iperf3.err"
		_rc=$?
		case "$_rc" in
		124|143) TRAFFIC_TIMEOUT=1 ;;
		esac
		_flat=$(tr '\n\r\t' '   ' <"$CAPTURE/iperf3.json" 2>/dev/null)
		_block=$(printf '%s' "$_flat" |
			sed -n 's/.*"sum_sent":[[:space:]]*{\([^}]*\)}.*/\1/p' | head -n 1)
		TRAFFIC_BITS=$(printf '%s' "$_block" |
			sed -n 's/.*"bits_per_second":[[:space:]]*\([0-9.]*\).*/\1/p' | head -n 1)
		if [ "$_rc" -eq 0 ] && [ -n "$TRAFFIC_BITS" ] &&
			awk -v b="$TRAFFIC_BITS" 'BEGIN { exit(b > 0 ? 0 : 1) }'; then
			TRAFFIC_OK=1
		fi
		[ "$TRAFFIC_OK" = 1 ] || warn "iperf3 did not deliver a positive result (see $CAPTURE/iperf3.err)"
	else
		say "traffic window: one ping burst, ${DURATION} packets, peer $PEER from ${LOCAL_IP%/*}"
		run_limited "$((DURATION + 30))" ping -I "${LOCAL_IP%/*}" -c "$DURATION" -W 1 -i 1 "$PEER" \
			>"$CAPTURE/ping.txt" 2>&1
		_rc=$?
		case "$_rc" in
		124|143) TRAFFIC_TIMEOUT=1 ;;
		esac
		TRAFFIC_TX=$(sed -n 's/.* \([0-9][0-9]*\) packets transmitted.*/\1/p' "$CAPTURE/ping.txt" 2>/dev/null | tail -n 1)
		TRAFFIC_RX=$(sed -n 's/.* \([0-9][0-9]*\) packets received.*/\1/p' "$CAPTURE/ping.txt" 2>/dev/null | tail -n 1)
		TRAFFIC_LOSS=$(sed -n 's/.* \([0-9][0-9]*\)% packet loss.*/\1/p' "$CAPTURE/ping.txt" 2>/dev/null | tail -n 1)
		[ -n "$TRAFFIC_LOSS" ] || TRAFFIC_LOSS=100
		[ -n "$TRAFFIC_TX" ] || TRAFFIC_TX=$DURATION
		[ -n "$TRAFFIC_RX" ] || TRAFFIC_RX=0
		if [ "$_rc" -eq 0 ] && [ "$TRAFFIC_LOSS" -lt 100 ] && [ "$TRAFFIC_RX" -gt 0 ]; then
			TRAFFIC_OK=1
		fi
	fi
	return 0
}

per_link_deltas() {
	# per_link_deltas BEFORE AFTER SECONDS ; print measured per-link rates and
	# byte deltas.  Returns 1 when per-link counters are unavailable.
	_before=$1
	_after=$2
	_secs=$3
	station_fields "$_before" "$STATION" >"${STATE_DIR}/.fields-before.$$" 2>/dev/null || :
	station_fields "$_after" "$STATION" >"${STATE_DIR}/.fields-after.$$" 2>/dev/null || :
	awk -F '\t' -v secs="$_secs" '
		NR == FNR { b[$1 SUBSEP $2 SUBSEP $3] = $4; next }
		$1 == "link" && ($3 == "tx_bytes" || $3 == "rx_bytes") {
			key = $1 SUBSEP $2 SUBSEP $3
			if (key in b) {
				d = $4 - b[key]
				if (d < 0) d = 0
				rate[$2, $3] = d * 8 / secs / 1000000
				seen[$2] = 1
			}
		}
		END {
			n = 0
			for (l in seen) n++
			if (!n) exit 1
			sum_tx = 0
			sum_rx = 0
			for (l = 0; l < 16; l++) {
				if (!(l in seen)) continue
				printf "  link %d over %ss: tx %.2f Mbit/s, rx %.2f Mbit/s\n", l, secs, rate[l, "tx_bytes"] + 0, rate[l, "rx_bytes"] + 0
				sum_tx += rate[l, "tx_bytes"]
				sum_rx += rate[l, "rx_bytes"]
			}
			printf "  per-link sum over %ss: tx %.2f Mbit/s, rx %.2f Mbit/s\n", secs, sum_tx, sum_rx
		}
	' "${STATE_DIR}/.fields-before.$$" "${STATE_DIR}/.fields-after.$$"
	_rc=$?
	rm -f "${STATE_DIR}/.fields-before.$$" "${STATE_DIR}/.fields-after.$$"
	return "$_rc"
}

classify_result() {
	# Sets RESULT and STOP.  No retry is possible after this point.
	_links_now=0
	MLD=$(find_mld 2>/dev/null) || MLD=
	[ -n "$MLD" ] && _links_now=$(link_count "$MLD")
	case "$_links_now" in ''|*[!0-9]*) _links_now=0 ;; esac

	if [ "$TRAFFIC_OK" = 1 ]; then
		RESULT=traffic-ok
		STOP="the single traffic window completed; no black-hole symptom"
		return 0
	fi

	_present=0
	station_present && _present=1
	if [ -n "$MLD" ] && [ "$_links_now" -eq 3 ] && [ "$_present" = 1 ]; then
		RESULT=blackhole
		if [ "$TRAFFIC_TOOL" = ping ]; then
			STOP="unicast traffic did not pass (${TRAFFIC_LOSS}% loss) while the AP MLD kept 3 links and the station stayed associated"
		else
			STOP="iperf3 did not deliver traffic while the AP MLD kept 3 links and the station stayed associated"
		fi
		[ "$TRAFFIC_TIMEOUT" = 1 ] && STOP="$STOP; the traffic command hit its time limit"
		return 0
	fi

	if [ -n "$MLD" ] && [ "$_links_now" -ne 3 ]; then
		RESULT=link-lost
		STOP="the AP MLD dropped to ${_links_now} link(s) during the traffic window"
	elif [ "$_present" = 0 ]; then
		RESULT=station-lost
		STOP="the station disappeared during the traffic window"
	elif [ "$TRAFFIC_TIMEOUT" = 1 ]; then
		RESULT=traffic-timeout
		STOP="the traffic command hit its time limit and the control plane did not match a clean black-hole"
	else
		RESULT=traffic-failed
		STOP="the traffic window failed without a clean black-hole signature"
	fi
	return 0
}

gates_evaluate() {
	GATE_RISK=0
	GATE_HOLD=0
	GATE_SERIAL=0

	if [ "$RISK" = 1 ]; then
		GATE_RISK=1
		GATE_RISK_MSG="--i-understand-risk passed"
	else
		GATE_RISK_MSG="--i-understand-risk was not passed"
	fi

	if nw_hold_active; then
		GATE_HOLD=1
		GATE_HOLD_MSG=$NW_WHY
	else
		GATE_HOLD_MSG=$NW_WHY
	fi

	if [ "$NO_SERIAL" = 1 ]; then
		GATE_SERIAL=1
		GATE_SERIAL_MSG="--no-serial acknowledged; no console was verified"
	elif serial_usable; then
		GATE_SERIAL=1
		GATE_SERIAL_MSG=$SERIAL_WHY
	else
		GATE_SERIAL_MSG=$SERIAL_WHY
	fi
}

gates_report() {
	_report() {
		if [ "$1" = 1 ]; then
			printf '  %-7s PASS  %s\n' "$2" "$3"
		else
			printf '  %-7s FAIL  %s\n' "$2" "$3"
		fi
	}
	printf 'gates:\n'
	_report "$GATE_RISK" risk "$GATE_RISK_MSG"
	_report "$GATE_HOLD" hold "$GATE_HOLD_MSG"
	_report "$GATE_SERIAL" serial "$GATE_SERIAL_MSG"
}

gates_require() {
	gates_evaluate
	if [ "$GATE_RISK" = 1 ] && [ "$GATE_HOLD" = 1 ] && [ "$GATE_SERIAL" = 1 ]; then
		return 0
	fi
	printf '%s: refusing before any config write:\n' "$PROG" >&2
	gates_report >&2
	exit 2
}

nw_hold_active() {
	NW_WHY=
	if ! have netwatchdog; then
		NW_WHY="netwatchdog is not installed"
		return 1
	fi
	if [ ! -e /tmp/netwatchdog.hold ]; then
		NW_WHY="/tmp/netwatchdog.hold is missing; run netwatchdog hold on first"
		return 1
	fi
	_st=$(run_limited 10 netwatchdog status 2>/dev/null) || {
		NW_WHY="netwatchdog status failed"
		return 1
	}
	if ! printf '%s\n' "$_st" | grep -q 'hold:.*ACTIVE'; then
		NW_WHY="netwatchdog status does not report an active hold"
		return 1
	fi
	NW_WHY="netwatchdog hold is ACTIVE (/tmp/netwatchdog.hold)"
	return 0
}

serial_usable() {
	SERIAL_WHY=
	if [ -z "$SERIAL" ]; then
		SERIAL_WHY="no --serial and no --no-serial"
		return 1
	fi
	if [ ! -c "$SERIAL" ]; then
		SERIAL_WHY="$SERIAL is not a character device"
		return 1
	fi
	if [ ! -r "$SERIAL" ] || [ ! -w "$SERIAL" ]; then
		SERIAL_WHY="$SERIAL is not readable and writable"
		return 1
	fi
	_name=${SERIAL##*/}
	case "$_name" in
	ttyUSB[0-9]*|ttyACM[0-9]*) : ;;
	*)
		SERIAL_WHY="$SERIAL is not a ttyUSB/ttyACM USB serial node"
		return 1
		;;
	esac
	if [ -e "/sys/class/tty/$_name/device" ]; then
		_path=$(readlink -f "/sys/class/tty/$_name/device" 2>/dev/null || :)
		case "$_path" in
		*usb*) : ;;
		*)
			SERIAL_WHY="$SERIAL is not backed by a USB device"
			return 1
			;;
		esac
	fi
	SERIAL_WHY="$SERIAL is a usable USB serial console"
	return 0
}

validate_args() {
	case "$SSID" in
	'') die_usage "--ssid must not be empty" ;;
	*"'"*|*\\*) die_usage "--ssid contains a quote or backslash" ;;
	esac
	[ "$(printf '%s' "$SSID" | wc -c)" -eq "$(printf '%s' "$SSID" | tr -d '\n' | wc -c)" ] ||
		die_usage "--ssid must not contain a newline"
	[ "$(printf '%s' "$SSID" | wc -c)" -le 32 ] ||
		die_usage "--ssid must be at most 32 bytes"
	case "$KEY" in
	'') die_usage "--key must not be empty" ;;
	*"'"*|*\\*) die_usage "--key contains a quote or backslash" ;;
	esac
	[ "$(printf '%s' "$KEY" | wc -c)" -eq "$(printf '%s' "$KEY" | tr -d '\n' | wc -c)" ] ||
		die_usage "--key must not contain a newline"
	[ "$(printf '%s' "$KEY" | wc -c)" -ge 8 ] ||
		die_usage "--key must be at least 8 characters"
	[ "$(printf '%s' "$KEY" | wc -c)" -le 63 ] ||
		die_usage "--key must be at most 63 characters"

	for _v in DURATION PARALLEL ASSOC_TIMEOUT STATION_TIMEOUT HARD_TIMEOUT CMD_TIMEOUT; do
		eval "_n=\$$_v"
		case "$_n" in
		''|*[!0-9]*) die_usage "--$(printf '%s' "$_v" | tr 'A-Z_' 'a-z-') must be a positive integer" ;;
		esac
		[ "$_n" -ge 1 ] || die_usage "--$(printf '%s' "$_v" | tr 'A-Z_' 'a-z-') must be at least 1"
	done
	[ "$DURATION" -le 120 ] || die_usage "--duration is capped at 120s for a one-shot negative test"
	[ "$PARALLEL" -le 8 ] || die_usage "--parallel is capped at 8"
	[ "$ASSOC_TIMEOUT" -le 600 ] || die_usage "--assoc-timeout is capped at 600s"
	[ "$STATION_TIMEOUT" -le 600 ] || die_usage "--station-timeout is capped at 600s"
	[ "$HARD_TIMEOUT" -gt "$ASSOC_TIMEOUT" ] ||
		die_usage "--hard-timeout must be greater than --assoc-timeout"
	[ -z "$LOCAL_IP" ] || case "$LOCAL_IP" in
	*:*) die_usage "an IPv6 --local-ip is not supported by this one-shot traffic window" ;;
	*/*) ;;
	*) die_usage "--local-ip needs an IPv4 address with a prefix, e.g. 192.168.250.1/24" ;;
	esac
	case "$PEER" in
	*:*) die_usage "an IPv6 --peer is not supported by this one-shot traffic window" ;;
	esac
	case "$TRAFFIC" in auto|iperf3|ping) : ;; *) die_usage "--traffic must be auto, iperf3 or ping" ;; esac
	[ "$NO_SERIAL" = 1 ] && [ -n "$SERIAL" ] &&
		die_usage "--serial and --no-serial are mutually exclusive"
	[ "${CONFIG##*/}" = wireless ] ||
		die_usage "--config must name a file called wireless (uci -c reads <dir>/wireless)"
	if [ "$MODE" = restore ]; then
		[ -z "$PEER" ] || warn "--peer is ignored in --restore mode"
		[ -z "$LOCAL_IP" ] || warn "--local-ip is ignored in --restore mode"
	fi
}

preflight_run() {
	[ "$DRY_RUN" = 1 ] && return 0
	[ "$(id -u 2>/dev/null)" = 0 ] || die "a real run needs root"
	[ -f "$CONFIG" ] || die "missing $CONFIG"
	need_cmd uci
	need_cmd iw
	need_cmd md5sum
	need_cmd awk
	need_cmd sed
	need_cmd grep
	need_cmd cp
	need_cmd date
	need_cmd sleep
	need_cmd ip
	have wifi || have ubus || die "neither wifi nor ubus is available"
	if [ -z "$PEER" ]; then
		die_usage "a real run needs --peer (the 3-link client's private address)"
	fi
	if [ -z "$LOCAL_IP" ]; then
		die_usage "a real run needs --local-ip (an address for the test MLD, e.g. 192.168.250.1/24)"
	fi
	resolve_traffic_tool
	case "$TRAFFIC_TOOL" in
	ping) need_cmd ping ;;
	iperf3) need_cmd iperf3 ;;
	esac
}

print_plan() {
	say "MLO 3-link negative test (dry run; no config write, no reload, no traffic)"
	say "mode: $MODE"
	say "config: $CONFIG (not changed)"
	say "state: $STATE_DIR (not created)"
	say "radios: $DEV24 (2.4) + $DEV5 (5g) + $DEV6 (6g); link map $LINK_MAP"
	say "ssid: $SSID"
	say "section: $SECTION, mlo=1, exactly three device entries, not bridged"
	say "backup: $STATE_DIR/wireless.bak + md5 (on the overlay, survives a cold reboot)"
	say "association: up to ${ASSOC_TIMEOUT}s for links=3"
	say "station: up to ${STATION_TIMEOUT}s for one station on the test SSID"
	gates_evaluate
	gates_report
	resolve_traffic_tool plan
	case "$TRAFFIC_TOOL" in
	none) say "traffic: no iperf3/ping available; a real run would refuse" ;;
	*)
		if [ -n "$PEER" ] && [ -n "$LOCAL_IP" ]; then
			if [ "$TRAFFIC_TOOL" = iperf3 ]; then
				say "traffic: one iperf3 run, ${DURATION}s, -P $PARALLEL, $PEER from ${LOCAL_IP%/*}"
			else
				say "traffic: one ping burst, ${DURATION} packets, $PEER from ${LOCAL_IP%/*}"
			fi
		else
			say "traffic: skipped in this plan (a real run needs --peer and --local-ip)"
		fi
		;;
	esac
	say "restore: EXIT/INT/TERM/HUP trap, then md5 verify against the backup"
	say "limits: hard ${HARD_TIMEOUT}s, per-command ${CMD_TIMEOUT}s"
	say ""
	say "serial fallback if the box stops answering:"
	say "  cp $STATE_DIR/wireless.bak $CONFIG && wifi reload"
	say ""
	say "--- generated block ---"
	block_text
	if [ "$MODE" = run ] && { [ "$GATE_RISK" = 0 ] || [ "$GATE_HOLD" = 0 ] || [ "$GATE_SERIAL" = 0 ]; }; then
		say "a real run would be refused while any gate above is FAIL"
	fi
}

manual_recovery() {
	printf '%s: manual recovery:\n' "$PROG" >&2
	printf '  cp %s %s && wifi reload\n' "$BAK" "$CONFIG" >&2
	printf '  # or remove only the marked block:\n' >&2
	printf '  uci -q delete wireless.%s; uci commit wireless; wifi reload\n' "$SECTION" >&2
	printf '  # USB-TTL console: 115200 8N1, GND first; see the PR body\n' >&2
}

restore_config() {
	[ "$CONFIG_MODIFIED" = 1 ] || {
		say "restore: the config was never modified"
		return 0
	}
	[ -f "$BAK" ] || {
		warn "no backup at $BAK; the original config cannot be restored"
		RESTORE_OK=0
		return 1
	}
	_bak_md5=$(md5_of "$BAK")
	_stored=$(cat "$BAK_MD5" 2>/dev/null || :)
	if [ -n "$_stored" ] && [ "$_bak_md5" != "$_stored" ]; then
		warn "the backup md5 $_bak_md5 does not match the recorded $_stored; refusing a corrupted backup"
		RESTORE_OK=0
		return 1
	fi
	_cur_md5=$(md5_of "$CONFIG")
	_post_md5=$(cat "$POST_MD5" 2>/dev/null || :)

	if [ -n "$_bak_md5" ] && [ "$_cur_md5" = "$_bak_md5" ]; then
		say "restore: the config already matches the backup (md5 $_bak_md5)"
	elif [ -n "$_post_md5" ] && [ "$_cur_md5" = "$_post_md5" ]; then
		if ! cat "$BAK" >"$CONFIG" 2>/dev/null; then
			warn "could not restore $CONFIG from $BAK"
			RESTORE_OK=0
			return 1
		fi
		say "restore: restored the backup"
	else
		warn "the wireless config changed while the test was active; removing only the marked block"
		if config_has_block; then
			if ! strip_block; then
				warn "could not strip the marked block"
				RESTORE_OK=0
				return 1
			fi
			say "restore: removed the marked block from the externally edited config"
		elif section_exists "$SECTION"; then
			warn "the marker comments are gone; removing wireless.$SECTION by name"
			if ! remove_section; then
				warn "could not remove wireless.$SECTION"
				RESTORE_OK=0
				return 1
			fi
			say "restore: removed wireless.$SECTION from the externally edited config"
		else
			warn "no $MARKER block or section found; the original file cannot be restored without clobbering external edits"
			RESTORE_OK=0
			return 1
		fi
	fi

	if [ "$RELOADED" = 1 ]; then
		reload_wireless quiet || warn "the restore reload returned non-zero"
		wait_for_mld_gone || warn "the test MLD is still visible after the restore reload"
	fi

	if config_has_block || section_exists "$SECTION"; then
		warn "the $MARKER block is still present after the restore"
		RESTORE_OK=0
		return 1
	fi

	_new_md5=$(md5_of "$CONFIG")
	if [ -n "$_bak_md5" ] && [ "$_new_md5" = "$_bak_md5" ]; then
		RESTORE_VERIFIED=1
		say "restore: PASS md5=$_new_md5 matches the original"
		rm -f "$BAK" "$STATE_DIR/wireless.post" 2>/dev/null || :
		BACKUP_PURGED=1
		say "restore: raw backup removed after the verified restore"
	else
		warn "restore: md5 $_new_md5 does not match the original ${_bak_md5:-unknown} (external edit?)"
	fi
	CONFIG_MODIFIED=0
	write_meta 0 2>/dev/null || :
	return 0
}

write_result() {
	_rc=$1
	[ -n "$CAPTURE" ] || return 0
	_json_str() {
		printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\r\t' '   '
	}
	_dmesg_matches=0
	if [ -f "$CAPTURE/dmesg-interesting.count" ]; then
		_dmesg_matches=$(cat "$CAPTURE/dmesg-interesting.count" 2>/dev/null || :)
		case "$_dmesg_matches" in ''|*[!0-9]*) _dmesg_matches=0 ;; esac
	fi
	_serial=$([ "$NO_SERIAL" = 1 ] && printf 'none (--no-serial acknowledged)' || printf '%s' "${SERIAL:-none}")
	{
		printf '{\n'
		printf '  "tool": "mlo-3link.sh",\n'
		printf '  "one_shot": true,\n'
		printf '  "result": "%s",\n' "$(_json_str "${RESULT:-unknown}")"
		printf '  "exit_code": %s,\n' "$_rc"
		printf '  "stop_reason": "%s",\n' "$(_json_str "${STOP:-}")"
		printf '  "ts": %s,\n' "$(date +%s 2>/dev/null || printf '0')"
		printf '  "config": "%s",\n' "$(_json_str "$CONFIG")"
		printf '  "md5_original": "%s",\n' "$(_json_str "$(cat "$BAK_MD5" 2>/dev/null || :)")"
		printf '  "md5_final": "%s",\n' "$(_json_str "$(md5_of "$CONFIG")")"
		printf '  "restored": %s,\n' "$([ "$RESTORE_OK" = 1 ] && printf true || printf false)"
		printf '  "restore_verified": %s,\n' "$([ "$RESTORE_VERIFIED" = 1 ] && printf true || printf false)"
		printf '  "backup_purged": %s,\n' "$([ "$BACKUP_PURGED" = 1 ] && printf true || printf false)"
		printf '  "links": %s,\n' "${LINKS_AT_STOP:-0}"
		printf '  "station": "%s",\n' "$(_json_str "${STATION:-}")"
		printf '  "station_links": %s,\n' "${STATION_LINKS:-0}"
		printf '  "traffic_tool": "%s",\n' "$(_json_str "${TRAFFIC_TOOL:-none}")"
		printf '  "traffic_ok": %s,\n' "$([ "$TRAFFIC_OK" = 1 ] && printf true || printf false)"
		printf '  "traffic_timeout": %s,\n' "$([ "$TRAFFIC_TIMEOUT" = 1 ] && printf true || printf false)"
		printf '  "traffic_loss_pct": "%s",\n' "$(_json_str "${TRAFFIC_LOSS:-}")"
		printf '  "traffic_goodput_mbps": "%s",\n' "$(_json_str "${TRAFFIC_BITS:-}")"
		printf '  "blackhole_symptom": %s,\n' "$([ "$RESULT" = blackhole ] && printf true || printf false)"
		printf '  "dmesg_new_matches": %s,\n' "$_dmesg_matches"
		printf '  "boot_id": "%s",\n' "$(_json_str "${BOOT_ID:-}")"
		printf '  "serial": "%s",\n' "$(_json_str "$_serial")"
		printf '  "gates": {"risk": %s, "hold": %s, "serial": %s},\n' "$GATE_RISK" "$GATE_HOLD" "$GATE_SERIAL"
		printf '  "evidence": "%s"\n' "$(_json_str "$CAPTURE")"
		printf '}\n'
	} >"$CAPTURE/result.json" 2>/dev/null || warn "cannot write $CAPTURE/result.json"
}

write_summary() {
	[ -n "$CAPTURE" ] || return 0
	{
		printf 'mlo-3link: %s\n' "${RESULT:-unknown}"
		printf '  stop: %s\n' "${STOP:-no detail}"
		printf '  config: %s\n' "$CONFIG"
		printf '  md5 original: %s\n' "$(cat "$BAK_MD5" 2>/dev/null || printf 'unknown')"
		printf '  md5 final:    %s\n' "$(md5_of "$CONFIG")"
		if [ "$RESTORE_VERIFIED" = 1 ]; then
			printf '  restore: PASS (md5 matches the original; raw backup removed)\n'
		elif [ "$RESTORE_OK" = 1 ]; then
			printf '  restore: block removed (external edit; md5 differs by design)\n'
		else
			printf '  restore: FAILED; keep the USB-TTL console open and run the manual recovery\n'
		fi
		printf '  links: %s\n' "${LINKS_AT_STOP:-0}"
		printf '  station: %s (links: %s)\n' "${STATION:-none}" "${STATION_LINKS:-0}"
		printf '  traffic: %s ok=%s timeout=%s loss=%s goodput_bps=%s\n' \
			"${TRAFFIC_TOOL:-none}" "$TRAFFIC_OK" "$TRAFFIC_TIMEOUT" \
			"${TRAFFIC_LOSS:-n/a}" "${TRAFFIC_BITS:-n/a}"
		printf '  serial: %s\n' "$([ "$NO_SERIAL" = 1 ] && printf 'none (--no-serial acknowledged)' || printf '%s' "${SERIAL:-none}")"
		printf '  evidence: %s\n' "$CAPTURE"
	} >"$CAPTURE/summary.txt" 2>/dev/null || :
	cat "$CAPTURE/summary.txt" 2>/dev/null || :
	printf 'RESULT: %s\n' "${RESULT:-unknown}"
	if [ -n "$STOP" ]; then
		printf '  %s\n' "$STOP"
	fi
	if [ "$RESTORE_VERIFIED" = 1 ]; then
		printf '  config restored: md5 matches the original\n'
	elif [ "$RESTORE_OK" = 1 ]; then
		printf '  config restored: block removed; md5 may differ without a verified backup\n'
	else
		printf '  CONFIG RESTORE FAILED: keep the USB-TTL console open\n'
		manual_recovery
	fi
	printf '  evidence: %s\n' "$CAPTURE"
}

cleanup() {
	# Save the status first: restore_config and its helpers also use global
	# scratch variables such as _rc, and must not change the run's exit code.
	_final_rc=$?
	[ "$DONE" = 1 ] && return 0
	DONE=1
	trap - EXIT INT TERM HUP
	stop_watchdog

	if [ -n "$CAPTURE" ]; then
		capture_after 2>/dev/null || :
	fi
	del_local_ip 2>/dev/null || :

	if [ "$CONFIG_MODIFIED" = 1 ]; then
		restore_config || :
	fi

	[ -n "$RESULT" ] || RESULT=interrupted

	# A failed restore is a safety failure and outranks the test observation
	# in the exit status; adjust it before the JSON summary is written.
	if [ "$CONFIG_MODIFIED" = 1 ] || [ "$RESTORE_OK" != 1 ]; then
		_final_rc=1
	fi

	write_result "$_final_rc"
	write_summary
	release_lock
	exit "$_final_rc"
}

on_int() {
	printf '\n%s: SIGINT; restoring the config\n' "$PROG" >&2
	RESULT=interrupted
	STOP="SIGINT"
	exit 130
}

on_term() {
	if [ -n "$CAPTURE" ] && [ -f "$CAPTURE/command-timeout.txt" ]; then
		RESULT=command-timeout
		STOP=$(cat "$CAPTURE/command-timeout.txt" 2>/dev/null || printf 'a required command timed out')
		printf '\n%s: %s; restoring the config\n' "$PROG" "$STOP" >&2
		exit 1
	fi
	RESULT=interrupted
	STOP="SIGTERM"
	printf '\n%s: SIGTERM; restoring the config\n' "$PROG" >&2
	exit 143
}

on_hup() {
	printf '\n%s: SIGHUP; restoring the config\n' "$PROG" >&2
	RESULT=interrupted
	STOP="SIGHUP"
	exit 129
}

do_run() {
	CFG_DIR=$(dirname "$CONFIG")

	if [ "$DRY_RUN" = 1 ]; then
		plan_radios
		print_plan
		return 0
	fi

	# The three safety gates come first: they are the only refusal reason that
	# is allowed to mention a config write at all.
	gates_require
	preflight_run
	select_radios
	check_existing

	say "mlo-3link: one-shot 3-link MLO negative test"
	say "  config: $CONFIG"
	say "  radios: $DEV24 (2.4) + $DEV5 (5g) + $DEV6 (6g)"
	say "  ssid:   $SSID"
	say "  peer:   $PEER; local-ip: $LOCAL_IP; traffic: $TRAFFIC_TOOL"
	say "  backup: $STATE_DIR/wireless.bak (overlay; survives a cold reboot)"
	say "  serial fallback: cp $STATE_DIR/wireless.bak $CONFIG && wifi reload"

	setup_capture
	acquire_lock
	trap cleanup EXIT
	trap on_int INT
	trap on_term TERM
	trap on_hup HUP
	start_watchdog

	backup_config
	capture_before
	append_block
	say "block: added wireless.$SECTION (3 links); reloading once"
	reload_wireless

	wait_for_links
	_lrc=$?
	if [ "$_lrc" -eq 2 ]; then
		RESULT=links-unexpected
		STOP="the AP MLD reported ${LINKS_AT_STOP:-more than 3} links, not 3"
		say "result: $STOP; no retry"
		exit 4
	fi
	if [ "$_lrc" -ne 0 ]; then
		RESULT=links-timeout
		STOP="the AP MLD did not reach links=3 within ${ASSOC_TIMEOUT}s (last count: ${LINKS_AT_STOP:-0})"
		say "result: $STOP; no retry"
		exit 4
	fi
	if [ "$LINKS_AT_STOP" != 3 ]; then
		RESULT=links-unexpected
		STOP="the AP MLD reported ${LINKS_AT_STOP} links, not 3"
		say "result: $STOP; no retry"
		exit 4
	fi

	print_links "$MLD"
	capture_after
	iw_capture "$CAPTURE/mld-info.txt" dev "$MLD" info

	wait_for_station
	_wrc=$?
	if [ "$_wrc" -eq 2 ]; then
		RESULT=station-ambiguous
		STOP="more than one station is on the test MLD; use --sta"
		say "result: $STOP; no traffic window and no retry"
		exit 4
	fi
	if [ "$_wrc" -ne 0 ]; then
		RESULT=no-station
		STOP="no station associated to $SSID within ${STATION_TIMEOUT}s"
		say "result: $STOP; no traffic window and no retry"
		exit 4
	fi

	station_dump_to "$CAPTURE/station-before-traffic.txt"
	STATION_LINKS=$(station_link_count "$CAPTURE/station-before-traffic.txt" "$STATION")
	case "$STATION_LINKS" in ''|*[!0-9]*) STATION_LINKS=0 ;; esac
	say "station: $STATION; per-link data: ${STATION_LINKS} link(s)"
	if [ "$STATION_LINKS" -eq 1 ] || [ "$STATION_LINKS" -eq 2 ]; then
		RESULT=station-not-3link
		STOP="the station reports ${STATION_LINKS} link(s); a 3-link station is required for this negative test"
		say "result: $STOP; no traffic window and no retry"
		exit 4
	fi
	if ! print_station_rates "$CAPTURE/station-before-traffic.txt" "$STATION"; then
		warn "per-link station rates are unavailable in iw station dump"
	fi

	traffic_window
	capture_after
	station_dump_to "$CAPTURE/station-after-traffic.txt"

	if per_link_deltas "$CAPTURE/station-before-traffic.txt" \
		"$CAPTURE/station-after-traffic.txt" "$DURATION"; then
		:
	else
		say "per-link traffic rates: unavailable (iw station dump has no per-link counters)"
	fi

	classify_result
	case "$RESULT" in
	blackhole)
		say "BLACK-HOLE SYMPTOM: $STOP"
		say "the run stops here; there is no retry"
		exit 3
		;;
	traffic-ok)
		say "traffic completed without a black-hole symptom"
		exit 0
		;;
	*)
		say "inconclusive: $STOP"
		exit 4
		;;
	esac
}

do_restore() {
	CFG_DIR=$(dirname "$CONFIG")
	BAK="$STATE_DIR/wireless.bak"
	BAK_MD5="$STATE_DIR/wireless.bak.md5"
	POST_MD5="$STATE_DIR/wireless.post.md5"
	STATE_META="$STATE_DIR/state"

	if [ "$DRY_RUN" = 1 ]; then
		say "MLO 3-link restore (dry run)"
		say "config: $CONFIG (not changed)"
		if [ -f "$BAK" ]; then
			say "restore: $BAK -> $CONFIG (md5 checked), then wifi reload"
		elif config_has_block; then
			say "strip the marked $MARKER block from $CONFIG, then wifi reload"
		elif section_exists "$SECTION"; then
			say "remove wireless.$SECTION by name, then wifi reload"
		else
			say "nothing to restore"
		fi
		return 0
	fi

	[ "$(id -u 2>/dev/null)" = 0 ] || die "a real restore needs root"
	[ -f "$CONFIG" ] || die "missing $CONFIG"
	need_cmd uci
	need_cmd md5sum
	have wifi || have ubus || die "neither wifi nor ubus is available"

	if [ ! -f "$BAK" ]; then
		if config_has_block || section_exists "$SECTION"; then
			say "no backup; removing only the marked block"
			setup_capture
			acquire_lock
			trap cleanup EXIT
			trap on_int INT
			trap on_term TERM
			trap on_hup HUP
			CONFIG_MODIFIED=1
			RELOADED=1
			RESULT=restored
			if config_has_block; then
				strip_block || die "could not strip the marked block"
			else
				remove_section || die "could not remove wireless.$SECTION"
			fi
			CONFIG_MODIFIED=0
			reload_wireless
			wait_for_mld_gone || warn "the test MLD is still visible after the reload"
			say "restore: block removed; md5=$(md5_of "$CONFIG") (the original md5 is not known without a backup)"
			exit 0
		fi
		say "restore: nothing to restore"
		exit 0
	fi

	setup_capture
	acquire_lock
	trap cleanup EXIT
	trap on_int INT
	trap on_term TERM
	trap on_hup HUP
	start_watchdog
	CONFIG_MODIFIED=1
	RELOADED=1
	RESULT=restored
	restore_config || exit 1
	exit 0
}

usage() {
	cat <<EOF
Usage: $PROG [options]

One-shot, gated 3-link MLO negative test.  It adds exactly one marked
wifi-iface with three links on 2.4 + 5 + 6 GHz, reloads once, waits once for
links=3, waits once for a station, runs exactly one short traffic window,
captures links/per-link rates/dmesg and a black-hole symptom, then restores
the original /etc/config/wireless in a trap.  It never loops and never retries
after a black-hole.

This is a negative test, not a production configuration.  Do not run it on a
production box.  An active netwatchdog hold, --i-understand-risk and either a
usable USB-TTL console or --no-serial are required before any config write.

Modes:
  (default)              run the one-shot negative test
  --restore, --remove    restore the backup (or strip the marked block) from
                         an earlier run, for example after a crash or reboot
  --dry-run              print the plan, gates and generated block; change
                         nothing

Safety gates (all are required for a real run; --dry-run only reports them):
  --i-understand-risk    acknowledge the known 3-link black-hole / cold-reboot
                         risk
  --serial DEV           a usable USB serial console (ttyUSB*/ttyACM* character
                         device, readable and writable, USB-backed when sysfs
                         knows the tty)
  --no-serial            explicitly acknowledge that no USB-TTL console is
                         available to this script; the run is then much harder
                         to recover if the box cold-reboots

Traffic:
  --peer ADDR            the 3-link client's private IPv4 address (required
                         for a real run)
  --local-ip ADDR/PFX    address to add to the test MLD for the traffic window
                         and remove on exit, e.g. 192.168.250.1/24 (required for
                         a real run)
  --traffic MODE         auto (default; iperf3 if present, else ping), iperf3 or
                         ping.  One traffic command only.
  --duration SEC         traffic window length (default $DURATION; max 120)
  --parallel N           iperf3 streams (default $PARALLEL; max 8)
  --sta MAC              station to measure; by default the only station on the
                         test MLD is used, and more than one is refused

Test shape:
  --ssid NAME            test SSID (default $SSID)
  --key KEY              SAE key, 8..63 characters (default is a fixed test
                         key; never reuse it for anything real)
  --ifname NAME          inspect this MLD instead of finding the test SSID
  --assoc-timeout SEC    seconds to wait for links=3 (default $ASSOC_TIMEOUT)
  --station-timeout SEC  seconds to wait for a station (default $STATION_TIMEOUT)
  --hard-timeout SEC     overall deadline backstop (default $HARD_TIMEOUT)
  --cmd-timeout SEC      per-command limit (default $CMD_TIMEOUT); a hung iw,
                         dmesg or reload is killed and the trap restores
  --config FILE          wireless config to use (default $CONFIG; the file
                         must be named wireless because uci -c reads
                         <dir>/wireless; keep the default on a real device)
  --state-dir DIR        backup and evidence directory (default $STATE_DIR;
                         this is on the overlay so a cold reboot keeps the
                         backup)
  --verbose              print each poll and extra detail
  -h, --help             show this help

Exit status:
  0    one-shot completed, no black-hole symptom, config restored
  1    safety failure: restore failed or a required command timed out
  2    usage error, missing gate or unsupported environment (no config write)
  3    black-hole symptom observed (test completed and config restored)
  4    one-shot inconclusive: links != 3, no 3-link station, traffic tool
  129/130/143  interrupted by HUP/INT/TERM; the trap restored the config

Serial fallback (keep this open before the run):
  adapter   3.3 V USB-TTL on the XR1710G debug UART, GND first
  terminal  picocom -b 115200 /dev/ttyUSB0, 8N1, no flow control
  if the box stops answering or cold-reboots:
    cp $STATE_DIR/wireless.bak $CONFIG
    wifi reload
  or remove only the marked block:
    uci -q delete wireless.$SECTION; uci commit wireless; wifi reload
  if userspace never comes up, boot the initramfs recovery image from the
  U-Boot recovery console; do not reflash unless the bootloader is wedged.

Environment:
  MLO3_SSID, MLO3_KEY, MLO3_CONFIG, MLO3_STATE_DIR, MLO3_PEER, MLO3_LOCAL_IP,
  MLO3_STA, MLO3_IFNAME, MLO3_SERIAL, MLO3_DURATION, MLO3_PARALLEL,
  MLO3_ASSOC_TIMEOUT, MLO3_STATION_TIMEOUT, MLO3_HARD_TIMEOUT, MLO3_CMD_TIMEOUT,
  MLO3_TRAFFIC.  Flags override the environment.
EOF
}

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
		--ssid) [ $# -ge 2 ] || die_usage "--ssid needs a value"; SSID=$2; shift ;;
		--key) [ $# -ge 2 ] || die_usage "--key needs a value"; KEY=$2; shift ;;
		--peer) [ $# -ge 2 ] || die_usage "--peer needs a value"; PEER=$2; shift ;;
		--local-ip) [ $# -ge 2 ] || die_usage "--local-ip needs a value"; LOCAL_IP=$2; shift ;;
		--sta) [ $# -ge 2 ] || die_usage "--sta needs a value"; STA=$2; shift ;;
		--ifname) [ $# -ge 2 ] || die_usage "--ifname needs a value"; IFNAME=$2; shift ;;
		--serial) [ $# -ge 2 ] || die_usage "--serial needs a value"; SERIAL=$2; shift ;;
		--no-serial) NO_SERIAL=1 ;;
		--i-understand-risk) RISK=1 ;;
		--duration) [ $# -ge 2 ] || die_usage "--duration needs a value"; DURATION=$2; shift ;;
		--parallel) [ $# -ge 2 ] || die_usage "--parallel needs a value"; PARALLEL=$2; shift ;;
		--assoc-timeout) [ $# -ge 2 ] || die_usage "--assoc-timeout needs a value"; ASSOC_TIMEOUT=$2; shift ;;
		--station-timeout) [ $# -ge 2 ] || die_usage "--station-timeout needs a value"; STATION_TIMEOUT=$2; shift ;;
		--hard-timeout) [ $# -ge 2 ] || die_usage "--hard-timeout needs a value"; HARD_TIMEOUT=$2; shift ;;
		--cmd-timeout) [ $# -ge 2 ] || die_usage "--cmd-timeout needs a value"; CMD_TIMEOUT=$2; shift ;;
		--traffic) [ $# -ge 2 ] || die_usage "--traffic needs a value"; TRAFFIC=$2; shift ;;
		--config) [ $# -ge 2 ] || die_usage "--config needs a value"; CONFIG=$2; shift ;;
		--state-dir) [ $# -ge 2 ] || die_usage "--state-dir needs a value"; STATE_DIR=$2; shift ;;
		--restore|--remove) MODE=restore ;;
		--dry-run) DRY_RUN=1 ;;
		--verbose) VERBOSE=1 ;;
		-h|--help) usage; exit 0 ;;
		--) shift; break ;;
		*) die_usage "unknown option: $1" ;;
		esac
		shift
	done
	[ $# -eq 0 ] || die_usage "unexpected argument: $1"
}

main() {
	parse_args "$@"
	validate_args
	case "$MODE" in
	run) do_run ;;
	restore) do_restore ;;
	*) die "unknown mode: $MODE" ;;
	esac
}

main "$@"
