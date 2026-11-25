#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# 6g-restore-eht320.sh - report, and optionally restore, radio2's htmode to
# the repository default.
#
# Why this exists: the 6 GHz radio on this board runs what /etc/config/wireless
# says, and /etc/config/wireless is written over time by whoever runs uci on
# the box.  A board found running

#     uci -q get wireless.radio2.htmode
#     HE20
#     iw dev phy0.2-ap0 info
#     channel 37 (6135 MHz), width: 20 MHz
#     grep -c ieee80211be /var/run/hostapd-phy0.2.conf
#     0

# is not running a repository default: 51_wireless-tuning only writes
# radio2.htmode while it is still stock (unset or the schema's EHT80), so once
# something wrote HE20 the defaults script steps aside and the board keeps it
# forever.  HE20 is also not one of the widths the LuCI wifi7 view offers for
# radio2, so a person cannot get here by clicking through that page.
#
# What it does
#
#   (no args)   read-only: read the config file and the live hostapd config,
#               compare radio2.htmode with the value in 51_wireless-tuning,
#               print one status line per fact.  Writes nothing, reloads
#               nothing.
#   --apply     write radio2.htmode and nothing else, then verify that
#               ieee80211be reached the live hostapd config *and* that the
#               running interface negotiated at least 320 MHz.  A failed
#               verification restores the config file, the pending UCI delta
#               and the live radio, then exits 1.
#
# Exit codes: 0 in sync (read-only) or verified (apply), 1 drift (read-only)
# or a failed apply that was rolled back, 2 the inputs are unusable.
#
# The write goes through scripts/lib/uci-restore-guard.sh, which is the only
# thing that gets the delta right: uci writes /tmp/.uci/wireless first and
# commit folds it into /etc/config/wireless, so a run that dies between the
# two leaves a delta behind and the next unrelated commit flushes it in.
#
#   urg_init <label>   snapshot the config file, the delta, their md5
#   urg_arm            EXIT/INT/TERM/HUP -> restore
#   urg_mark_dirty     the first write is about to happen; without it a run
#                      that dies before writing would "restore" over nothing
#   urg_disarm         clean end: the write is meant to stay, drop the
#                      snapshot
#   urg_restore_delta  put the delta back (or remove one this run created);
#                      the trap calls it, but an explicit rollback needs it
#                      too, and a second call is a no-op
#
# Environment:
#   WIRELESS_CFG    config file (default /etc/config/wireless)
#   HOSTAPD_CONF    live 6 GHz hostapd config (default
#                   /var/run/hostapd-phy0.2.conf)
#   G6_DEFAULTS     51_wireless-tuning to read the expected width from
#   G6_IFACE        interface to report on (default phy0.2-ap0)
#   G6_VERIFY_TIMEOUT  seconds to wait for ieee80211be after a reload (30)
#   URG_*           forwarded to uci-restore-guard.sh (URG_DIR, URG_DELTA,
#                   URG_WIFI, URG_NO_RELOAD)

set -u

APPLY=0

while [ $# -gt 0 ]; do
	case "$1" in
	--apply) APPLY=1 ;;
	-h | --help)
		sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		printf 'usage: %s [--apply]\n' "${0##*/}" >&2
		exit 2
		;;
	esac
	shift
done

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)

WIRELESS_CFG=${WIRELESS_CFG:-/etc/config/wireless}
HOSTAPD_CONF=${HOSTAPD_CONF:-/var/run/hostapd-phy0.2.conf}
G6_DEFAULTS=${G6_DEFAULTS:-$REPO_ROOT/target/linux/airoha/an7581/base-files/etc/uci-defaults/51_wireless-tuning}
G6_IFACE=${G6_IFACE:-phy0.2-ap0}
G6_VERIFY_TIMEOUT=${G6_VERIFY_TIMEOUT:-30}
URG_LIB=${URG_LIB:-$REPO_ROOT/scripts/lib/uci-restore-guard.sh}
WIFI_BIN=${URG_WIFI:-wifi}

die() {
	printf 'g6-restore-eht320: %s\n' "$*" >&2
	exit 2
}

[ -f "$WIRELESS_CFG" ] || die "no config at $WIRELESS_CFG"
[ -f "$G6_DEFAULTS" ] || die "no defaults script at $G6_DEFAULTS"

md5_of() {
	if command -v md5sum >/dev/null 2>&1; then
		md5sum "$1" | awk '{print $1}'
	elif command -v md5 >/dev/null 2>&1; then
		md5 -q "$1"
	else
		cksum "$1" | awk '{print $1"-"$2}'
	fi
}

# read_option <section> <option> [file] - one value out of a UCI config file,
# so the read-only path does not depend on uci being callable.
read_option() {
	awk -v want_section="$1" -v want_option="$2" '
		/^config / { section = $3; gsub(/'\''/, "", section); next }
		section == want_section && $1 == "option" && $2 == want_option {
			value = $3
			gsub(/'\''/, "", value)
			print value
			exit
		}
	' "${3:-$WIRELESS_CFG}"
}

# The expected width is the last argument of
#   uci_set_from radio2 htmode EHT80 EHT320
# in 51_wireless-tuning, not a copy of the literal here: if the default
# changes again this script follows it instead of pinning a second truth.
expected_htmode() {
	awk '
		$1 == "uci_set_from" && $2 == "radio2" && $3 == "htmode" {
			# uci_set_from <section> <option> <stock> <value>
			value = $5
			gsub(/'\''/, "", value)
		}
		END {
			if (value == "") exit 1
			print value
		}
	' "$G6_DEFAULTS"
}

expected=$(expected_htmode) ||
	die "cannot read the radio2 htmode default from $G6_DEFAULTS"

current=$(read_option radio2 htmode)
current=${current:-<unset>}

be_count=0
if [ -f "$HOSTAPD_CONF" ]; then
	be_count=$(grep -c ieee80211be "$HOSTAPD_CONF" 2>/dev/null || true)
fi
be_count=${be_count:-0}

printf 'config:   %s (md5 %s)\n' "$WIRELESS_CFG" "$(md5_of "$WIRELESS_CFG")"
printf 'expected: radio2.htmode=%s (from %s)\n' "$expected" "${G6_DEFAULTS##*/}"
printf 'current:  radio2.htmode=%s\n' "$current"
printf 'live:     %s ieee80211be lines = %s\n' "${HOSTAPD_CONF##*/}" "$be_count"

drift=0
[ "$current" = "$expected" ] || drift=1

if [ "$drift" = 0 ]; then
	printf 'status:   default\n'
else
	printf 'status:   drift (apply needed)\n'
fi

if [ "$APPLY" = 0 ]; then
	exit "$drift"
fi

# read_live_width - read the channel width (MHz) of $G6_IFACE from iw, or empty.
# iw prints "channel 37 (6135 MHz), width: 320 MHz, center1: 6105 MHz" and may
# append center2: only the token after the "width:" label is the width.
read_live_width() {
	command -v iw >/dev/null 2>&1 || return 1
	iw dev "$G6_IFACE" info 2>/dev/null |
		awk '/width:/ { n = split($0, a, " ")
		                for (i = 1; i < n; i++)
		                        if (a[i] == "width" || a[i] == "width:") { print a[i + 1]; found = 1; break }
		              }
		     END { if (!found) exit 1 }'
}

# Numeric check before -ge so a non-numeric reading never prints a shell error.
width_ge_320() {
	case ${1:-} in
	'' | *[!0-9]*) return 1 ;;
	esac
	[ "$1" -ge 320 ]
}

if [ "$drift" = 0 ] && [ "$be_count" != 0 ]; then
	# ieee80211be in hostapd.conf alone does not prove 320 MHz: an EHT160
	# fallback still writes ieee80211be=1.  Check live iw width before
	# short-circuiting as already good.
	_live_width=$(read_live_width) || _live_width=
	if width_ge_320 "$_live_width"; then
		printf 'verify:   %s width: %s MHz\n' "$G6_IFACE" "$_live_width"
		printf 'apply:    already at %s, nothing written\n' "$expected"
		exit 0
	fi
fi

if [ "$drift" = 0 ]; then
	# The file matches but the running hostapd/interface does not (either
	# ieee80211be is absent or live width is below 320 MHz).  Do not touch
	# the config; just reload and verify.
	printf 'apply:    config already %s, reloading to verify\n' "$expected"
else
	[ -f "$URG_LIB" ] || die "no restore guard at $URG_LIB"
	# shellcheck source=../lib/uci-restore-guard.sh
	. "$URG_LIB"

	urg_init 6g-restore-eht320 "$WIRELESS_CFG" || die 'cannot create a restore point'
	urg_arm
	urg_mark_dirty
	printf 'apply:    uci set wireless.radio2.htmode=%s\n' "$expected"
	uci -q set "wireless.radio2.htmode=$expected" || die 'uci set failed'
	uci -q commit wireless || die 'uci commit failed'
fi

printf 'apply:    %s reload\n' "$WIFI_BIN"
"$WIFI_BIN" reload || die 'wifi reload failed'

_elapsed=0
wait_be() {
	while [ "$_elapsed" -lt "$G6_VERIFY_TIMEOUT" ]; do
		if [ -f "$HOSTAPD_CONF" ] &&
			grep -q ieee80211be "$HOSTAPD_CONF" 2>/dev/null; then
			return 0
		fi
		_elapsed=$((_elapsed + 1))
		sleep 1
	done
	if [ -f "$HOSTAPD_CONF" ] &&
		grep -q ieee80211be "$HOSTAPD_CONF" 2>/dev/null; then
		return 0
	fi
	return 1
}

wait_width() {
	_width=
	command -v iw >/dev/null 2>&1 || return 1
	while :; do
		_width=$(read_live_width) || _width=
		if width_ge_320 "$_width"; then
			return 0
		fi
		if [ "$_elapsed" -ge "$G6_VERIFY_TIMEOUT" ]; then
			return 1
		fi
		_elapsed=$((_elapsed + 1))
		sleep 1
	done
}

if wait_be; then
	printf 'verify:   ieee80211be present in %s\n' "${HOSTAPD_CONF##*/}"
	# ieee80211be in the netifd-generated hostapd config only proves that the
	# config text asks for EHT: it does not prove hostapd came up, nor that
	# the radio negotiated the requested width.  An EHT160 fallback - a
	# regulatory constraint, a coex downgrade - still has ieee80211be in that
	# file, and hostapd may still be finishing interface setup right when
	# hostapd.conf appears, so poll iw within G6_VERIFY_TIMEOUT.
	if wait_width; then
		if [ "$drift" != 0 ]; then
			urg_disarm
		fi
		printf 'verify:   %s width: %s MHz\n' "$G6_IFACE" "$_width"
		printf 'status:   restored to %s (%s MHz)\n' "$expected" "$_width"
		exit 0
	fi
	case ${_width:-} in
	'' | *[!0-9]*)
		printf 'verify:   cannot read the width of %s (iw dev %s info); %s is in the config but the radio is unverified\n' \
			"$G6_IFACE" "$G6_IFACE" "$expected" >&2
		;;
	*)
		printf 'verify:   width is %s MHz, expected 320 MHz\n' "$_width" >&2
		;;
	esac
fi

printf 'verify:   FAILED - no verified 320 MHz EHT link on %s after %s s\n' \
	"$G6_IFACE" "$G6_VERIFY_TIMEOUT" >&2
if [ "$drift" = 0 ]; then
	printf 'status:   failed, the config already asked for %s; the live radio did not reach it\n' \
		"$expected" >&2
	exit 1
fi
printf 'status:   failed, %s was written but is not in effect; rolling back\n' \
	"$expected" >&2
# The armed trap restores the config file, the delta and the radio; exit
# non-zero so the caller sees the failure rather than a restored-looking 0.
exit 1
