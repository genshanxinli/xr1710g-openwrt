#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# mlo-2link.sh - a 2-link MLO bring-up and aggregation harness.
#
# This is a test harness, not a production configuration tool.  It writes one
# marked wifi-iface block into /etc/config/wireless, reloads the wireless
# stack, waits for an AP MLD with exactly two links, and optionally measures a
# short iperf3 arm while showing the per-link station counters.
#
# The test interface is deliberately not attached to a network.  It therefore
# never joins br-lan or any other production bridge, and the existing
# wifi-iface sections are not modified.  Reloading the radio does briefly
# restart the AP MLD's phy, so a client of an existing BSS can be disconnected
# for the duration of a 5 GHz DFS CAC (up to 60 s).  That is a property of
# bringing up a new MLD on the same phy, not a bridge change.
#
# Safety properties:
#   - exactly two radios, never three; the selected bands are either 5 GHz +
#     6 GHz or 2.4 GHz + 5 GHz;
#   - /etc/config/wireless is backed up with its md5 before the first write;
#   - the backup is restored on error, SIGINT, SIGTERM and SIGHUP;
#   - --remove restores the backup after a successful run;
#   - the generated block is wrapped in BEGIN/END comments and names the
#     wifi-iface section "mlo2link";
#   - an existing MLO iface on either selected radio makes the harness refuse
#     to run rather than change a production MLD.
#
# Per-link station rates need a two-link client associated to the test SSID and
# a kernel/iw that reports per-link station statistics.  When that data is not
# available the harness still verifies links=2 and prints the per-link channel
# and width, but it reports the measured per-link rates as unavailable instead
# of inventing a number.
#
# The script is POSIX sh and runs with busybox ash, so it works on the device.
#
# Exit status:
#   0  the requested action completed (links=2 verified for setup/check, or
#      the backup was restored for --remove)
#   1  a link, station or measurement check failed, or the restore failed
#   2  invalid arguments or unsupported environment

set -u
set -f
LC_ALL=C
export LC_ALL

PROG=${0##*/}

# Defaults.  Most knobs are also available as environment variables so that a
# caller can keep long invocations short; an explicit flag wins.
SSID=${MLO_SSID:-MLO-2LINK-TEST}
KEY=${MLO_KEY:-mlo2linktest}
BANDS=${MLO_BANDS:-auto}
DURATION=${MLO_DURATION:-10}
PARALLEL=${MLO_PARALLEL:-4}
PEER=${MLO_PEER:-}
LOCAL_IP=${MLO_LOCAL_IP:-}
STA=${MLO_STA:-}
TIMEOUT=${MLO_TIMEOUT:-180}
STATION_TIMEOUT=${MLO_STATION_TIMEOUT:-60}
STATE_DIR=${MLO_STATE_DIR:-/tmp/mlo-2link}
CONFIG=${MLO_CONFIG:-/etc/config/wireless}
IFNAME=${MLO_IFNAME:-}
OUT_DIR=${MLO_OUT_DIR:-}
MODE=setup
DRY_RUN=0
AUTO_REMOVE=0
FORCE=0
REVERSE=0
NO_AGGREGATE=0
VERBOSE=0

# Runtime state.
CFG_DIR=
STATE_META=
BAK=
BAK_MD5=
POST_MD5=
CONFIG_MODIFIED=0
LOCKED=0
LOCK_DIR=
CLEANUP_DONE=0
RELOADED=0
IP_ADDED=0
CAPTURE=
DEV1=
DEV2=
BAND1=
BAND2=
MLD=
LINK_MAP=
LOG_FILE=

usage() {
	cat <<EOF
Usage: $PROG [options]

Bring up a dedicated two-link MLO AP, verify that the AP MLD has exactly two
links, optionally run a short aggregation arm, and restore the original
/etc/config/wireless with --remove.

The new wifi-iface is named "mlo2link" and has mlo=1 and exactly two device
entries.  It is not attached to a network, so it is not added to br-lan or any
other production bridge.  It is also not made the default SSID.

Modes:
  (default)              add the block, reload, verify links=2, and leave the
                         test MLD running until --remove
  --remove               restore the saved /etc/config/wireless and reload
  --check                inspect the running MLD without changing the config
  --dry-run              print the plan and the generated block; change nothing

Options:
  --ssid NAME            test SSID (default $SSID)
  --key KEY              SAE key, at least 8 characters (default is a fixed
                         test key; do not reuse it for anything real)
  --bands LIST           auto (default), 5g+6g, or 2.4+5.  auto tries 5 GHz +
                         6 GHz first, then 2.4 GHz + 5 GHz.  Exactly two
                         radios are used; a three-link run is never attempted.
  --duration SEC         iperf3 duration in seconds (default $DURATION)
  --parallel N           iperf3 streams (default $PARALLEL)
  --peer ADDR            iperf3 server address.  Without --peer the harness
                         verifies links=2 and prints whatever station data is
                         available, but skips the traffic arm.
  --local-ip ADDR[/PFX]  optional address to add to the test MLD for the
                         iperf3 arm, for example 192.168.250.1/24.  The
                         address is removed again on exit.  Without it, the
                         system route decides where iperf3 traffic goes, so
                         the arm may not cross the MLD at all.
  --sta MAC              station MAC to measure.  By default the only station
                         on the test MLD is used; more than one requires this.
  --reverse              run iperf3 in the peer-to-AP direction (-R); the
                         default arm is AP-to-peer
  --no-aggregate         skip the iperf3 arm even when --peer is set
  --timeout SEC          seconds to wait for links=2 after the reload
                         (default $TIMEOUT; 5 GHz DFS CAC can use 60 s)
  --station-timeout SEC  seconds to wait for a station when --peer is set
                         (default $STATION_TIMEOUT)
  --ifname NAME          MLD interface to inspect with --check (default: find
                         the interface whose SSID is the test SSID)
  --cleanup              restore the backup after a successful run as well
  --state-dir DIR        state and capture directory (default $STATE_DIR)
  --out DIR              write the run log and captures to DIR as well
  --force                remove a previous, still-active mlo2link block
                         before adding a new one
  --verbose              print each poll and extra diagnostics
  -h, --help             show this help

Environment:
  MLO_SSID, MLO_KEY, MLO_BANDS, MLO_DURATION, MLO_PARALLEL, MLO_PEER,
  MLO_LOCAL_IP, MLO_STA, MLO_TIMEOUT, MLO_STATION_TIMEOUT, MLO_STATE_DIR,
  MLO_CONFIG, MLO_IFNAME, MLO_OUT_DIR.  Flags override the environment.

Typical use:
  # 1. bring up the AP MLD and leave it running
  ./scripts/wireless/mlo-2link.sh --local-ip 192.168.250.1/24 --peer 192.168.250.2

  # 2. run only the inspection and measurement against the running MLD
  ./scripts/wireless/mlo-2link.sh --check --peer 192.168.250.2

  # 3. restore the original wireless config (md5-checked)
  ./scripts/wireless/mlo-2link.sh --remove

  # A short non-destructive check of the generated configuration:
  ./scripts/wireless/mlo-2link.sh --dry-run

Requirements:
  root, iw, uci, md5sum, and a wifi reload path (wifi or ubus).  iperf3 is
  needed only for an aggregation arm.  A real two-link client is needed for
  per-link station rates; the AP alone can only prove that the AP MLD has two
  links.

Notes:
  - The test SSID is not bridged.  A client that associates to it gets no DHCP
    address from the production network; configure a static address on the
    client, or connect it to the same layer-2 network as a wired peer.
  - A 5 GHz DFS channel makes the phy run a CAC before the second link can
    come up.  The harness waits and reports the transient links=1 state; it
    does not treat it as a failure before --timeout expires.
  - Per-link station rates are parsed from "iw dev <mld> station dump".  When
    the running kernel/iw does not emit the per-link "Link N:" sections, the
    harness prints "per-link station rates: unavailable" and never reports a
    made-up per-link number.
  - The test key defaults to a well-known value for reproducibility.  It is a
    test SSID only; do not use it as a production credential.
EOF
}

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

pick_radio() {
	# pick_radio BAND -> sets PICKED to the first enabled device, or empty.
	PICKED=
	for _sec in $(list_sections device); do
		[ -n "$_sec" ] || continue
		radio_is_disabled "$_sec" && continue
		[ "$(radio_band "$_sec")" = "$1" ] || continue
		PICKED=$_sec
		return 0
	done
	return 1
}

select_radios() {
	DEV1=
	DEV2=
	BAND1=
	BAND2=

	if [ "$BANDS" = auto ]; then
		pick_radio 5g && DEV1=$PICKED && BAND1=5g
		pick_radio 6g && DEV2=$PICKED && BAND2=6g
		if [ -z "$DEV1" ] || [ -z "$DEV2" ]; then
			DEV1=
			DEV2=
			BAND1=
			BAND2=
			pick_radio 2.4 && DEV1=$PICKED && BAND1=2.4
			pick_radio 5g && DEV2=$PICKED && BAND2=5g
		fi
	else
		case "$BANDS" in
		5g+6g)
			pick_radio 5g && DEV1=$PICKED && BAND1=5g
			pick_radio 6g && DEV2=$PICKED && BAND2=6g
			;;
		2.4+5)
			pick_radio 2.4 && DEV1=$PICKED && BAND1=2.4
			pick_radio 5g && DEV2=$PICKED && BAND2=5g
			;;
		esac
	fi

	[ -n "$DEV1" ] && [ -n "$DEV2" ] ||
		return 1
	[ "$DEV1" != "$DEV2" ] ||
		return 1

	# MLO link IDs are the per-radio indices used by hostapd.  A radio
	# section without one cannot form a stable two-link MLD.
	_r1=$(radio_index "$DEV1")
	_r2=$(radio_index "$DEV2")
	case "$_r1" in ''|*[!0-9]*) return 1 ;; esac
	case "$_r2" in ''|*[!0-9]*) return 1 ;; esac
	[ "$_r1" != "$_r2" ] || return 1

	LINK_MAP="$_r1:$BAND1 $_r2:$BAND2"
	return 0
}

section_exists() {
	uci -q -c "$CFG_DIR" show "wireless.$1" >/dev/null 2>&1
}

check_existing_mlo() {
	for _sec in $(list_sections iface); do
		[ -n "$_sec" ] || continue
		[ "$_sec" = mlo2link ] || continue
		die "wireless.$_sec already exists; run --remove before adding a new block"
	done

	for _sec in $(list_sections iface); do
		[ -n "$_sec" ] || continue
		[ "$_sec" = mlo2link ] && continue
		[ "$(uci_get "wireless.$_sec.mlo")" = 1 ] || continue
		radio_is_disabled "$_sec" && continue
		_devs=" $(uci_get "wireless.$_sec.device") "
		case "$_devs" in
		*" $DEV1 "*|*" $DEV2 "*)
			die "existing MLO iface $_sec already uses $DEV1 or $DEV2; refusing to add a second MLD"
			;;
		esac
	done
}

config_has_block() {
	[ -f "$CONFIG" ] && grep -q '^# >>> mlo-2link: BEGIN' "$CONFIG" 2>/dev/null
}

block_text() {
	cat <<EOF
# >>> mlo-2link: BEGIN (added by scripts/wireless/mlo-2link.sh; remove with --remove)
config wifi-iface 'mlo2link'
	list device '$DEV1'
	list device '$DEV2'
	option mlo '1'
	option mode 'ap'
	option ssid '$SSID'
	option encryption 'sae'
	option key '$KEY'
	option ieee80211w '2'
	option disabled '0'
# <<< mlo-2link: END
EOF
}

write_meta() {
	{
		printf 'ACTIVE=%s\n' "$1"
		printf 'BANDS=%s\n' "$BANDS"
		printf 'BAND1=%s\n' "$BAND1"
		printf 'BAND2=%s\n' "$BAND2"
		printf 'DEV1=%s\n' "$DEV1"
		printf 'DEV2=%s\n' "$DEV2"
		printf 'SSID=%s\n' "$SSID"
		printf 'IFNAME=%s\n' "${MLD:-}"
		printf 'LINK_MAP=%s\n' "$LINK_MAP"
		printf 'BAK_MD5=%s\n' "$(cat "$STATE_DIR/wireless.bak.md5" 2>/dev/null || :)"
		printf 'POST_MD5=%s\n' "$(cat "$STATE_DIR/wireless.post.md5" 2>/dev/null || :)"
		printf 'TS=%s\n' "$(date +%s)"
	} >"$STATE_META"
}

state_get() {
	[ -f "$STATE_META" ] || return 1
	sed -n "s/^$1=//p" "$STATE_META" 2>/dev/null | head -n 1
}

state_active() {
	[ -f "$STATE_META" ] && [ "$(state_get ACTIVE)" = 1 ]
}

acquire_lock() {
	LOCK_DIR="${STATE_DIR}.lock"
	[ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null || die "cannot create $STATE_DIR"
	chmod 700 "$STATE_DIR" 2>/dev/null || :

	if mkdir "$LOCK_DIR" 2>/dev/null; then
		printf '%s\n' "$$" >"$LOCK_DIR/pid" 2>/dev/null || :
		LOCKED=1
		return 0
	fi

	_old=
	[ -f "$LOCK_DIR/pid" ] && _old=$(cat "$LOCK_DIR/pid" 2>/dev/null)
	case "$_old" in
	''|*[!0-9]*) _old= ;;
	esac
	if [ -n "$_old" ] && kill -0 "$_old" 2>/dev/null; then
		die "another mlo-2link run is active (pid $_old)"
	fi

	rm -rf "$LOCK_DIR" 2>/dev/null || die "cannot remove stale lock $LOCK_DIR"
	mkdir "$LOCK_DIR" 2>/dev/null || die "cannot lock $LOCK_DIR"
	printf '%s\n' "$$" >"$LOCK_DIR/pid" 2>/dev/null || :
	LOCKED=1
}

release_lock() {
	[ "$LOCKED" = 1 ] || return 0
	rm -rf "$LOCK_DIR" 2>/dev/null || :
	LOCKED=0
}

backup_config() {
	[ -f "$CONFIG" ] || die "missing $CONFIG"
	mkdir -p "$STATE_DIR" 2>/dev/null || die "cannot create $STATE_DIR"
	BAK="$STATE_DIR/wireless.bak"
	BAK_MD5="$STATE_DIR/wireless.bak.md5"
	POST_MD5="$STATE_DIR/wireless.post.md5"
	STATE_META="$STATE_DIR/meta"

	cp -p "$CONFIG" "$BAK" 2>/dev/null || cp "$CONFIG" "$BAK" ||
		die "cannot back up $CONFIG"
	md5_of "$BAK" >"$BAK_MD5" || die "cannot write $BAK_MD5"
	_bak_hash=$(cat "$BAK_MD5" 2>/dev/null)
	[ -n "$_bak_hash" ] || die "empty md5 for backup"
	write_meta 0
}

append_block() {
	_tmp="${CONFIG}.mlo2link.$$"
	_tdir="${STATE_DIR}/uci-check.$$"
	rm -rf "$_tdir"
	mkdir -p "$_tdir" 2>/dev/null || die "cannot create $_tdir"

	{
		cat "$CONFIG"
		if [ -s "$CONFIG" ] && [ -n "$(tail -c 1 "$CONFIG" 2>/dev/null)" ]; then
			printf '\n'
		fi
		block_text
	} >"$_tmp" 2>/dev/null || {
		rm -f "$_tmp"
		rm -rf "$_tdir"
		die "cannot write $_tmp"
	}

	cp "$_tmp" "$_tdir/wireless" 2>/dev/null || {
		rm -f "$_tmp"
		rm -rf "$_tdir"
		die "cannot stage the generated config"
	}
	if ! uci -q -c "$_tdir" show wireless >/dev/null 2>&1; then
		rm -f "$_tmp"
		rm -rf "$_tdir"
		die "generated wireless config does not parse"
	fi
	rm -rf "$_tdir"

	# If something else rewrote the config between the backup and this
	# append, stop rather than silently backing out the other change later.
	_bak_hash=$(cat "$BAK_MD5" 2>/dev/null)
	_cur_hash=$(md5_of "$CONFIG")
	if [ -n "$_bak_hash" ] && [ "$_cur_hash" != "$_bak_hash" ]; then
		rm -f "$_tmp"
		die "$CONFIG changed after the backup; refusing to append"
	fi

	# Keep the original inode and mode; the backup is already on disk.
	CONFIG_MODIFIED=1
	if ! cat "$_tmp" >"$CONFIG" 2>/dev/null; then
		rm -f "$_tmp"
		die "cannot replace $CONFIG"
	fi
	rm -f "$_tmp"
	md5_of "$CONFIG" >"$POST_MD5" || die "cannot write $POST_MD5"
	_post_hash=$(cat "$POST_MD5" 2>/dev/null)
	[ -n "$_post_hash" ] || die "empty md5 for the generated config"
}

strip_block() {
	# Remove only the marked block from the current file.  Used when an
	# external change means restoring the old file would clobber someone
	# else's edit.
	[ -f "$CONFIG" ] || return 1
	_out="${CONFIG}.strip.$$"
	awk '
		/^# >>> mlo-2link: BEGIN/ { skip = 1; next }
		/^# <<< mlo-2link: END/   { skip = 0; next }
		!skip                     { print }
	' "$CONFIG" >"$_out" 2>/dev/null || {
		rm -f "$_out"
		return 1
	}
	# Collapse the blank line that the block's leading separator leaves.
	if ! cat "$_out" >"$CONFIG" 2>/dev/null; then
		rm -f "$_out"
		return 1
	fi
	rm -f "$_out"
	return 0
}

remove_section() {
	# Recovery path for a config that has lost the marker comments (for
	# example because something ran "uci commit"): remove the section by
	# name instead of restoring the whole file.
	section_exists mlo2link || return 1
	uci -q -c "$CFG_DIR" delete wireless.mlo2link >/dev/null 2>&1 || return 1
	uci -q -c "$CFG_DIR" commit wireless >/dev/null 2>&1 || return 1
	return 0
}

wifi_reload() {
	RELOADED=1
	if have wifi; then
		wifi reload >/dev/null 2>&1 || warn "wifi reload returned non-zero"
	elif have ubus; then
		ubus call network reload >/dev/null 2>&1 || warn "ubus network reload returned non-zero"
	else
		die "neither wifi nor ubus is available"
	fi
}

find_mld() {
	if [ -n "$IFNAME" ]; then
		[ -d "/sys/class/net/$IFNAME" ] || return 1
		printf '%s\n' "$IFNAME"
		return 0
	fi
	iw dev 2>/dev/null | awk -v ssid="$SSID" '
		/^[ \t]*Interface / {
			iface = $2
			want = 0
			next
		}
		/^[ \t]*ssid / {
			line = $0
			sub(/^[ \t]*ssid[ \t]+/, "", line)
			if (line == ssid)
				want = 1
			next
		}
		/MLD with links:/ {
			if (want && iface != "") {
				print iface
				exit
			}
		}
	'
}

wait_for_mld_gone() {
	_name=${MLD:-}
	[ -n "$_name" ] || _name=$(state_get IFNAME 2>/dev/null || :)
	_i=0
	while [ "$_i" -lt 20 ]; do
		_alive=0
		if [ -n "$_name" ] && [ -d "/sys/class/net/$_name" ]; then
			_alive=1
		fi
		if [ "$_alive" -eq 0 ]; then
			_m=$(find_mld) || :
			[ -z "$_m" ] && return 0
		fi
		sleep 1
		_i=$((_i + 1))
	done
	return 1
}

link_count() {
	[ -n "$1" ] || {
		printf '0\n'
		return 0
	}
	iw dev "$1" info 2>/dev/null |
		awk '/^[ \t]*- link ID/ { n++ } END { print n + 0 }'
}

print_links() {
	[ -n "$1" ] || return 1
	say "links: $(link_count "$1")"
	iw dev "$1" info 2>/dev/null | awk -v map="$LINK_MAP" '
		BEGIN {
			n = split(map, parts, " ")
			for (i = 1; i <= n; i++) {
				split(parts[i], pair, ":")
				band[pair[1]] = pair[2]
			}
		}
		/MLD with links:/ { inmlo = 1; next }
		inmlo && /^[ \t]*- link ID/ {
			if (cur != "")
				print cur
			label = band[$4] != "" ? " (" band[$4] ")" : ""
			cur = sprintf("  link %s%s: addr %s", $4, label, $7)
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
	'
}

station_fields() {
	# station_fields DUMP_FILE [MAC]
	# Emit tab-separated records: kind<TAB>link<TAB>field<TAB>value
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
	station_fields "$1" "$2" | awk -F '\t' '$1 == "link" { seen[$2] = 1 } END { n = 0; for (l in seen) n++; print n + 0 }'
}

print_station_rates() {
	# Print the per-link station rate view.  Returns 1 when there is no
	# per-link data, which is different from a station with no rate.
	station_fields "$1" "$2" >"${STATE_DIR}/station-fields.$$" 2>/dev/null || return 1
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
	' "${STATE_DIR}/station-fields.$$"
	_rc=$?
	rm -f "${STATE_DIR}/station-fields.$$"
	return "$_rc"
}

list_stations() {
	[ -n "$1" ] || return 0
	iw dev "$1" station dump 2>/dev/null | awk '/^Station / { print $2 }'
}

station_matches() {
	# station_matches DUMP_FILE MAC
	iw_ok=$(station_fields "$1" "$2" | awk -F '\t' 'NR > 0 { found = 1 } END { print found + 0 }')
	[ "$iw_ok" = 1 ]
}

wait_for_station() {
	_deadline=$(($(date +%s) + STATION_TIMEOUT))
	while :; do
		_dump=$(take_station_dump)
		if [ -n "$STA" ]; then
			if station_matches "$_dump" "$STA"; then
				rm -f "$_dump"
				printf '%s\n' "$STA"
				return 0
			fi
		else
			_stas=$(list_stations "$MLD")
			_count=$(printf '%s\n' "$_stas" | awk 'NF { n++ } END { print n + 0 }')
			if [ "$_count" -gt 1 ]; then
				rm -f "$_dump"
				warn "more than one station on $MLD; use --sta to select one"
				printf '%s\n' "$_stas" | sed 's/^/  station: /' >&2
				return 2
			fi
			if [ "$_count" -eq 1 ]; then
				rm -f "$_dump"
				printf '%s\n' "$_stas"
				return 0
			fi
		fi
		rm -f "$_dump"
		[ "$(date +%s)" -ge "$_deadline" ] && return 1
		sleep 2
	done
}

station_dump_file() {
	printf '%s/station-dump.$$.tmp\n' "$STATE_DIR"
}

take_station_dump() {
	_dump=$(station_dump_file)
	iw dev "$MLD" station dump >"$_dump" 2>/dev/null || :
	printf '%s\n' "$_dump"
}

wait_for_links() {
	_deadline=$(($(date +%s) + TIMEOUT))
	_last=0
	while :; do
		MLD=$(find_mld)
		if [ -n "$MLD" ]; then
			_n=$(link_count "$MLD")
			if [ "$_n" -eq 2 ]; then
				say "links=2 on $MLD"
				return 0
			fi
			if [ "$_n" -gt 2 ]; then
				say "links=$_n on $MLD (refusing more than two)"
				return 2
			fi
			if [ "$VERBOSE" = 1 ] || [ "$_n" != "$_last" ]; then
				say "waiting for the second link: links=$_n on $MLD"
			fi
			_last=$_n
		elif [ "$VERBOSE" = 1 ]; then
			say "waiting for the test MLD to appear"
		fi
		if [ "$(date +%s)" -ge "$_deadline" ]; then
			[ -n "$MLD" ] && say "links=$(link_count "$MLD") on $MLD after ${TIMEOUT}s"
			return 1
		fi
		sleep 3
	done
}

redact_config() {
	# Do not copy production Wi-Fi credentials into a capture directory.  A
	# test key in the mlo2link block is not a secret, but the rest of the
	# file may be.
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

collect_diagnostics() {
	mkdir -p "$CAPTURE" 2>/dev/null || return 0
	{
		printf '=== iw dev ===\n'
		iw dev 2>&1 || :
		printf '\n=== hostapd log ===\n'
		logread -e hostapd 2>/dev/null | tail -n 50 || :
		printf '\n=== dmesg (tail) ===\n'
		dmesg 2>/dev/null | tail -n 30 || :
		printf '\n=== wireless config (secrets redacted) ===\n'
		redact_config
	} >"$CAPTURE/failure.txt" 2>&1
}

restore_config() {
	[ "$CONFIG_MODIFIED" = 1 ] || return 0
	if [ ! -f "$BAK" ]; then
		warn "no backup at $BAK; cannot restore $CONFIG"
		return 1
	fi

	_bak_md5=$(md5_of "$BAK")
	_stored_md5=
	[ -f "$BAK_MD5" ] && _stored_md5=$(cat "$BAK_MD5" 2>/dev/null)
	if [ -n "$_stored_md5" ] && [ "$_stored_md5" != "$_bak_md5" ]; then
		warn "backup md5 $_bak_md5 does not match the recorded $_stored_md5; refusing to restore a corrupted backup"
		return 1
	fi
	_cur_md5=$(md5_of "$CONFIG")
	_post_md5=
	[ -f "$POST_MD5" ] && _post_md5=$(cat "$POST_MD5" 2>/dev/null)

	if [ -n "$_bak_md5" ] && [ "$_cur_md5" = "$_bak_md5" ]; then
		say "restore: config already matches the backup (md5 $_bak_md5)"
	elif [ -n "$_post_md5" ] && [ "$_cur_md5" = "$_post_md5" ]; then
		cp -p "$BAK" "$CONFIG" 2>/dev/null || cp "$BAK" "$CONFIG" ||
			{ warn "could not restore $CONFIG"; return 1; }
		say "restore: restored the backup"
	else
		warn "wireless config changed while the MLO block was active; removing only the mlo2link block"
		if config_has_block; then
			strip_block || { warn "could not strip the mlo2link block"; return 1; }
			say "restore: removed the marked block from the current config"
		elif section_exists mlo2link; then
			warn "marker comments are gone; removing wireless.mlo2link by name"
			remove_section || { warn "could not remove wireless.mlo2link"; return 1; }
			say "restore: removed the mlo2link section from the current config"
		else
			warn "no mlo2link block or section found; the original file cannot be restored without clobbering external edits"
		fi
	fi

	if [ "$RELOADED" = 1 ]; then
		wifi_reload
		wait_for_mld_gone || warn "the test MLD is still present after the reload"
	fi
	_new_md5=$(md5_of "$CONFIG")
	if [ -n "$_bak_md5" ] && [ "$_new_md5" = "$_bak_md5" ]; then
		say "restore: PASS md5=$_new_md5 matches the original"
	else
		warn "restore: md5 $_new_md5 does not match the original ${_bak_md5:-unknown} (external edit?)"
	fi
	CONFIG_MODIFIED=0
	write_meta 0
	return 0
}

cleanup() {
	_rc=$?
	if [ "$CLEANUP_DONE" = 1 ]; then
		return 0
	fi
	CLEANUP_DONE=1
	trap - EXIT INT TERM HUP

	if [ "$IP_ADDED" = 1 ] && [ -n "$MLD" ]; then
		ip addr del "$LOCAL_IP" dev "$MLD" 2>/dev/null ||
			warn "could not remove $LOCAL_IP from $MLD"
		IP_ADDED=0
	fi

	_do_restore=0
	if [ "$CONFIG_MODIFIED" = 1 ]; then
		case "$_rc" in
		0) [ "$AUTO_REMOVE" = 1 ] && _do_restore=1 ;;
		*) _do_restore=1 ;;
		esac
	fi

	if [ "$_do_restore" = 1 ]; then
		restore_config || :
	fi

	release_lock
	exit "$_rc"
}

on_int() {
	printf '\n%s: interrupted, restoring\n' "$PROG" >&2
	exit 130
}

on_term() {
	printf '\n%s: terminated, restoring\n' "$PROG" >&2
	exit 143
}

on_hup() {
	printf '\n%s: hangup, restoring\n' "$PROG" >&2
	exit 129
}

setup_capture() {
	mkdir -p "$STATE_DIR" 2>/dev/null || die "cannot create $STATE_DIR"
	CAPTURE="${OUT_DIR:-$STATE_DIR}"
	mkdir -p "$CAPTURE" 2>/dev/null || die "cannot create $CAPTURE"
	if [ "$CAPTURE" = "$STATE_DIR" ]; then
		CAPTURE="$STATE_DIR/capture"
		mkdir -p "$CAPTURE" 2>/dev/null || die "cannot create $CAPTURE"
	fi
	LOG_FILE="$CAPTURE/run.log"
	: >>"$LOG_FILE" 2>/dev/null || :
}

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
		--ssid)
			[ $# -ge 2 ] || die_usage "--ssid needs a value"
			SSID=$2
			shift
			;;
		--key)
			[ $# -ge 2 ] || die_usage "--key needs a value"
			KEY=$2
			shift
			;;
		--bands)
			[ $# -ge 2 ] || die_usage "--bands needs a value"
			BANDS=$2
			shift
			;;
		--duration)
			[ $# -ge 2 ] || die_usage "--duration needs a value"
			DURATION=$2
			shift
			;;
		--parallel)
			[ $# -ge 2 ] || die_usage "--parallel needs a value"
			PARALLEL=$2
			shift
			;;
		--peer)
			[ $# -ge 2 ] || die_usage "--peer needs a value"
			PEER=$2
			shift
			;;
		--local-ip)
			[ $# -ge 2 ] || die_usage "--local-ip needs a value"
			LOCAL_IP=$2
			shift
			;;
		--sta)
			[ $# -ge 2 ] || die_usage "--sta needs a value"
			STA=$2
			shift
			;;
		--timeout)
			[ $# -ge 2 ] || die_usage "--timeout needs a value"
			TIMEOUT=$2
			shift
			;;
		--station-timeout)
			[ $# -ge 2 ] || die_usage "--station-timeout needs a value"
			STATION_TIMEOUT=$2
			shift
			;;
		--ifname)
			[ $# -ge 2 ] || die_usage "--ifname needs a value"
			IFNAME=$2
			shift
			;;
		--state-dir)
			[ $# -ge 2 ] || die_usage "--state-dir needs a value"
			STATE_DIR=$2
			shift
			;;
		--out)
			[ $# -ge 2 ] || die_usage "--out needs a value"
			OUT_DIR=$2
			shift
			;;
		--remove) MODE=remove ;;
		--check) MODE=check ;;
		--dry-run) DRY_RUN=1 ;;
		--cleanup) AUTO_REMOVE=1 ;;
		--force) FORCE=1 ;;
		--reverse) REVERSE=1 ;;
		--no-aggregate) NO_AGGREGATE=1 ;;
		--verbose) VERBOSE=1 ;;
		-h|--help)
			usage
			exit 0
			;;
		--)
			shift
			break
			;;
		*)
			die_usage "unknown option: $1"
			;;
		esac
		shift
	done

	[ $# -eq 0 ] || die_usage "unexpected argument: $1"
}

validate_args() {
	case "$BANDS" in
	auto|5g+6g|2.4+5) ;;
	*) die_usage "--bands must be auto, 5g+6g or 2.4+5" ;;
	esac
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
	case "$DURATION" in
	''|*[!0-9]*) die_usage "--duration must be a positive integer" ;;
	esac
	[ "$DURATION" -ge 1 ] || die_usage "--duration must be at least 1"
	case "$PARALLEL" in
	''|*[!0-9]*) die_usage "--parallel must be a positive integer" ;;
	esac
	[ "$PARALLEL" -ge 1 ] || die_usage "--parallel must be at least 1"
	case "$TIMEOUT" in
	''|*[!0-9]*) die_usage "--timeout must be a positive integer" ;;
	esac
	[ "$TIMEOUT" -ge 1 ] || die_usage "--timeout must be at least 1"
	case "$STATION_TIMEOUT" in
	''|*[!0-9]*) die_usage "--station-timeout must be a positive integer" ;;
	esac
	[ "$STATION_TIMEOUT" -ge 0 ] || die_usage "--station-timeout must be >= 0"
	[ -z "$LOCAL_IP" ] || case "$LOCAL_IP" in
	*/*) ;;
	*) die_usage "--local-ip needs an address with a prefix, e.g. 192.168.250.1/24" ;;
	esac
	[ "$NO_AGGREGATE" = 1 ] && [ -n "$PEER" ] &&
		warn "both --peer and --no-aggregate given; the traffic arm is skipped"
	[ "$MODE" = remove ] && [ "$AUTO_REMOVE" = 1 ] &&
		die_usage "--cleanup cannot be combined with --remove"
	[ "$MODE" = check ] && [ "$FORCE" = 1 ] &&
		die_usage "--force is only meaningful for setup"
}

require_root() {
	[ "$(id -u 2>/dev/null)" = 0 ] || die "this mode needs root"
}

require_config() {
	[ -f "$CONFIG" ] || die "missing $CONFIG"
	[ "$CONFIG" = /etc/config/wireless ] ||
		die "MLO_CONFIG is supported for --dry-run only; a real run must use /etc/config/wireless"
}

interactive_ips() {
	# Add the local address used by the iperf3 arm; the listener address is
	# the address without the prefix length.
	[ -n "$LOCAL_IP" ] || return 0
	have ip || die "ip is required for --local-ip"
	[ -n "$MLD" ] || die "no MLD to add $LOCAL_IP to"
	if ip addr show dev "$MLD" 2>/dev/null | grep -q "inet[6]* ${LOCAL_IP%/*}/"; then
		return 0
	fi
	if ip addr add "$LOCAL_IP" dev "$MLD" 2>/dev/null; then
		IP_ADDED=1
		ip link set "$MLD" up 2>/dev/null || warn "could not bring $MLD up"
	else
		warn "could not add $LOCAL_IP to $MLD"
	fi
}

run_aggregation() {
	# run_aggregation MLD STATION -> 0 measured, 1 not measured
	[ -n "$PEER" ] || return 1
	[ "$NO_AGGREGATE" = 1 ] && return 1
	have iperf3 || {
		warn "iperf3 is not installed; cannot run the aggregation arm"
		return 1
	}
	[ -n "$CAPTURE" ] || die "no capture directory for the aggregation arm"

	interactive_ips
	_before=$(take_station_dump)
	_before_fields="${STATE_DIR}/station-before.$$"
	station_fields "$_before" "$STATION" >"$_before_fields" 2>/dev/null || :

	_src=
	if [ -n "$LOCAL_IP" ]; then
		_src=${LOCAL_IP%/*}
	fi

	say "aggregation arm: iperf3 -c $PEER -t $DURATION -P $PARALLEL$( [ "$REVERSE" = 1 ] && printf ' -R' )"
	if [ -n "$_src" ]; then
		case "$_src" in
		*:*)
			if [ "$REVERSE" = 1 ]; then
				iperf3 -6 -B "$_src" -c "$PEER" -t "$DURATION" -P "$PARALLEL" -R -J \
					>"$CAPTURE/iperf3.json" 2>"$CAPTURE/iperf3.err"
			else
				iperf3 -6 -B "$_src" -c "$PEER" -t "$DURATION" -P "$PARALLEL" -J \
					>"$CAPTURE/iperf3.json" 2>"$CAPTURE/iperf3.err"
			fi
			;;
		*)
			if [ "$REVERSE" = 1 ]; then
				iperf3 -B "$_src" -c "$PEER" -t "$DURATION" -P "$PARALLEL" -R -J \
					>"$CAPTURE/iperf3.json" 2>"$CAPTURE/iperf3.err"
			else
				iperf3 -B "$_src" -c "$PEER" -t "$DURATION" -P "$PARALLEL" -J \
					>"$CAPTURE/iperf3.json" 2>"$CAPTURE/iperf3.err"
			fi
			;;
		esac
	else
		warn "no --local-ip; iperf3 uses the system route, so the arm may not cross the MLD"
		if [ "$REVERSE" = 1 ]; then
			iperf3 -c "$PEER" -t "$DURATION" -P "$PARALLEL" -R -J \
				>"$CAPTURE/iperf3.json" 2>"$CAPTURE/iperf3.err"
		else
			iperf3 -c "$PEER" -t "$DURATION" -P "$PARALLEL" -J \
				>"$CAPTURE/iperf3.json" 2>"$CAPTURE/iperf3.err"
		fi
	fi
	_rc=$?
	if [ "$_rc" -ne 0 ]; then
		warn "iperf3 failed with exit status $_rc; see $CAPTURE/iperf3.err"
		[ -s "$CAPTURE/iperf3.err" ] && sed 's/^/  iperf3: /' "$CAPTURE/iperf3.err" >&2
		rm -f "$_before_fields" "$_before"
		return 1
	fi

	_after=$(take_station_dump)
	_after_fields="${STATE_DIR}/station-after.$$"
	station_fields "$_after" "$STATION" >"$_after_fields" 2>/dev/null || :

	# The client's sum_sent describes AP-to-peer traffic; in reverse mode the
	# client receives, so sum_received is the AP's receive rate.
	if [ "$REVERSE" = 1 ]; then
		_sum=sum_received
	else
		_sum=sum_sent
	fi
	# Flatten the JSON first: iperf3's writer is not guaranteed to keep the
	# sum object on one line, and a pretty-printed object must parse too.
	_flat=$(tr '\n\r\t' '   ' <"$CAPTURE/iperf3.json" 2>/dev/null)
	_block=$(printf '%s' "$_flat" |
		sed -n "s/.*\"$_sum\":[[:space:]]*{\([^}]*\)}.*/\1/p" | head -n 1)
	_bits=$(printf '%s' "$_block" |
		sed -n 's/.*"bits_per_second":[[:space:]]*\([0-9.]*\).*/\1/p' | head -n 1)
	_seconds=$(printf '%s' "$_block" |
		sed -n 's/.*"seconds":[[:space:]]*\([0-9.]*\).*/\1/p' | head -n 1)

	if [ -z "$_bits" ]; then
		warn "could not parse the iperf3 result from $CAPTURE/iperf3.json"
		rm -f "$_before_fields" "$_after_fields" "$_before" "$_after"
		return 1
	fi
	[ -n "$_seconds" ] || _seconds=$DURATION

	say "iperf3: $(awk -v b="$_bits" 'BEGIN { printf "%.1f Mbit/s", b / 1000000 }') over ${_seconds}s"

	_measured=$(awk -F '\t' -v secs="$_seconds" -v bits="$_bits" '
		NR == FNR {
			b[$1 SUBSEP $2 SUBSEP $3] = $4
			next
		}
		$1 == "link" && ($3 == "tx_bytes" || $3 == "rx_bytes") {
			key = $1 SUBSEP $2 SUBSEP $3
			if (key in b) {
				d = $4 - b[key]
				if (d < 0)
					d = 0
				rate[$2, $3] = d * 8 / secs / 1000000
				seen[$2] = 1
			}
		}
		END {
			n = 0
			for (l in seen)
				n++
			if (!n)
				exit 1
			sum_tx = 0
			sum_rx = 0
			for (l = 0; l < 16; l++) {
				if (!(l in seen))
					continue
				printf "  link %d: tx %.1f Mbit/s, rx %.1f Mbit/s\n", l, rate[l, "tx_bytes"] + 0, rate[l, "rx_bytes"] + 0
				sum_tx += rate[l, "tx_bytes"]
				sum_rx += rate[l, "rx_bytes"]
			}
			printf "  per-link sum: tx %.1f Mbit/s, rx %.1f Mbit/s\n", sum_tx, sum_rx
			printf "  aggregate iperf3: %.1f Mbit/s\n", bits / 1000000
		}
	' "$_before_fields" "$_after_fields" 2>/dev/null)
	_mrc=$?

	if [ "$_mrc" -eq 0 ] && [ -n "$_measured" ]; then
		say "per-link throughput across the arm:"
		printf '%s\n' "$_measured"
		_res=0
	else
		say "per-link rates: unavailable (iw station dump did not report per-link counters)"
		say "aggregate iperf3: $(awk -v b="$_bits" 'BEGIN { printf "%.1f Mbit/s", b / 1000000 }')"
		_res=1
	fi

	rm -f "$_before_fields" "$_after_fields" "$_before" "$_after"
	return "$_res"
}

print_station_view() {
	[ -n "$MLD" ] || return 1
	_dump=$(take_station_dump)
	_stas=$(list_stations "$MLD")

	if [ -z "$STA" ]; then
		_count=$(printf '%s\n' "$_stas" | awk 'NF { n++ } END { print n + 0 }')
		case "$_count" in
		0)
			say "station: none on $MLD"
			say "per-link station rates: unavailable (connect a two-link client to $SSID and rerun --check)"
			rm -f "$_dump"
			return 1
			;;
		1)
			STATION=$(printf '%s\n' "$_stas")
			;;
		*)
			warn "more than one station on $MLD; use --sta"
			printf '%s\n' "$_stas" | sed 's/^/  station: /'
			rm -f "$_dump"
			return 1
			;;
		esac
	else
		STATION=$STA
		if ! station_matches "$_dump" "$STATION"; then
			say "station: $STATION is not associated to $MLD"
			rm -f "$_dump"
			return 1
		fi
	fi

	say "station: $STATION"
	_nlinks=$(station_link_count "$_dump" "$STATION")
	if [ "$_nlinks" -gt 0 ]; then
		say "station links: $_nlinks"
	else
		say "station links: unavailable (iw station dump has no per-link data)"
	fi
	print_station_rates "$_dump" "$STATION"
	_rc=$?
	if [ "$_rc" -ne 0 ]; then
		say "per-link station rates: unavailable (no per-link 'Link N:' data in iw station dump)"
	fi
	rm -f "$_dump"
	return 0
}

do_setup() {
	if [ -n "$IFNAME" ]; then
		die_usage "--ifname is only used with --check"
	fi

	if [ "$DRY_RUN" = 1 ]; then
		CFG_DIR=$(dirname "$CONFIG")
		if [ -f "$CONFIG" ]; then
			select_radios || {
				warn "no enabled radio pair for --bands $BANDS; using placeholders for the dry run"
				DEV1=radio5g
				DEV2=radio6g
				BAND1=5g
				BAND2=6g
				LINK_MAP="1:5g 2:6g"
			}
		else
			say "dry-run: $CONFIG does not exist; using placeholder radios"
			DEV1=radio5g
			DEV2=radio6g
			BAND1=5g
			BAND2=6g
			LINK_MAP="1:5g 2:6g"
		fi
		say "MLO 2-link dry run"
		say "mode: setup"
		say "config: $CONFIG (not changed)"
		say "state: $STATE_DIR (not created)"
		say "radios: $DEV1 ($BAND1) + $DEV2 ($BAND2)"
		say "ssid: $SSID"
		say "section: mlo2link, mlo=1, exactly two device entries"
		say "reload: wifi reload (not run)"
		say "backup: cp $CONFIG <state>/wireless.bak and md5"
		say "wait: up to ${TIMEOUT}s for links=2"
		say "remove: $PROG --remove restores the backup"
		if [ -n "$PEER" ] && [ "$NO_AGGREGATE" = 0 ]; then
			say "aggregation: iperf3 -c $PEER -t $DURATION -P $PARALLEL, per-link before/after"
		else
			say "aggregation: skipped (no --peer or --no-aggregate)"
		fi
		say ""
		block_text
		return 0
	fi

	require_root
	require_config
	need_cmd iw
	need_cmd uci
	need_cmd md5sum
	need_cmd awk
	need_cmd sed
	need_cmd grep

	setup_capture
	acquire_lock
	trap cleanup EXIT
	trap on_int INT
	trap on_term TERM
	trap on_hup HUP

	if state_active; then
		if [ "$FORCE" = 1 ]; then
			say "force: restoring the previous run first"
			CFG_DIR=$(dirname "$CONFIG")
			BAK="$STATE_DIR/wireless.bak"
			BAK_MD5="$STATE_DIR/wireless.bak.md5"
			POST_MD5="$STATE_DIR/wireless.post.md5"
			STATE_META="$STATE_DIR/meta"
			CONFIG_MODIFIED=1
			RELOADED=1
			restore_config || die "could not restore the previous run"
		else
			die "a previous mlo2link run is still active; run --remove or --force"
		fi
	fi

	CFG_DIR=$(dirname "$CONFIG")
	select_radios || die "no enabled two-radio pair for --bands $BANDS (need 5g+6g or 2.4+5)"
	check_existing_mlo
	backup_config

	say "MLO 2-link setup"
	say "config: $CONFIG (md5 $(cat "$BAK_MD5" 2>/dev/null) backed up)"
	say "radios: $DEV1 ($BAND1) + $DEV2 ($BAND2)"
	say "ssid: $SSID"
	say "aggregation: ${PEER:-none}"

	append_block
	write_meta 1
	say "block: added section mlo2link and reloaded"
	wifi_reload

	if ! wait_for_links; then
		collect_diagnostics
		die "the AP MLD did not reach links=2 within ${TIMEOUT}s"
	fi
	write_meta 1
	print_links "$MLD"
	collect_diagnostics
	iw dev >"$CAPTURE/iw-dev.txt" 2>&1 || :
	iw dev "$MLD" info >"$CAPTURE/mld-info.txt" 2>&1 || :
	iw dev "$MLD" station dump >"$CAPTURE/station-dump.txt" 2>&1 || :

	if [ -z "$PEER" ] || [ "$NO_AGGREGATE" = 1 ]; then
		print_station_view || :
	else
		STATION=
		if ! _found=$(wait_for_station); then
			collect_diagnostics
			die "no station associated to $SSID within ${STATION_TIMEOUT}s (a 2-link client is required)"
		fi
		STATION=$_found
		say "station: $STATION"
		_dump=$(take_station_dump)
		_iwlinks=$(station_link_count "$_dump" "$STATION")
		if [ "$_iwlinks" -gt 0 ]; then
			say "station links: $_iwlinks"
		else
			say "station links: unavailable (iw station dump has no per-link data)"
		fi
		if [ "$_iwlinks" -eq 1 ]; then
			rm -f "$_dump" "${STATE_DIR}/station-dump.$$.tmp"
			collect_diagnostics
			die "the associated station reports only 1 link; aggregation would not be 2-link"
		fi
		if ! print_station_rates "$_dump" "$STATION"; then
			say "per-link station rates: unavailable (iw station dump has no per-link data)"
		fi
		rm -f "$_dump" "${STATE_DIR}/station-dump.$$.tmp"
		if ! run_aggregation "$MLD" "$STATION"; then
			collect_diagnostics
			die "aggregation arm failed or could not be measured per link"
		fi
	fi

	if [ "$AUTO_REMOVE" = 1 ]; then
		say "cleanup: restoring the original config"
		restore_config || die "cleanup restore failed"
		say "cleanup: done"
	else
		say "MLO left running as section mlo2link; remove it with: $PROG --remove"
	fi
	return 0
}

do_check() {
	[ "$DRY_RUN" = 1 ] && {
		say "MLO 2-link check (dry run)"
		say "inspect: iw dev, iw dev <mld> info, iw dev <mld> station dump"
		say "find MLD: --ifname or the interface whose SSID is $SSID"
		say "no configuration is changed"
		return 0
	}
	need_cmd iw
	CFG_DIR=$(dirname "$CONFIG")
	STATE_META="$STATE_DIR/meta"
	LINK_MAP=$(state_get LINK_MAP 2>/dev/null || :)
	mkdir -p "$STATE_DIR" 2>/dev/null || die "cannot create $STATE_DIR"
	CAPTURE="$STATE_DIR/capture"
	mkdir -p "$CAPTURE" 2>/dev/null || die "cannot create $CAPTURE"
	LOG_FILE="$CAPTURE/run.log"
	trap cleanup EXIT
	trap on_int INT
	trap on_term TERM
	trap on_hup HUP

	MLD=$(find_mld) || die "no MLD found for SSID $SSID (use --ifname or bring it up first)"
	[ -n "$MLD" ] || die "no MLD found for SSID $SSID (use --ifname or bring it up first)"
	print_links "$MLD"
	_n=$(link_count "$MLD")
	if [ "$_n" -ne 2 ]; then
		print_station_view || :
		die "links=$_n, not 2"
	fi
	if ! print_station_view; then
		if [ -n "$PEER" ] && [ "$NO_AGGREGATE" = 0 ]; then
			die "no 2-link station is available for the aggregation arm"
		fi
		[ -z "$STA" ] || die "station $STA is not associated to $MLD"
		return 0
	fi
	_dump=$(take_station_dump)
	_slinks=$(station_link_count "$_dump" "$STATION")
	rm -f "$_dump"
	if [ "$_slinks" -eq 1 ]; then
		die "the associated station has only 1 link, not 2"
	fi
	if [ -n "$PEER" ] && [ "$NO_AGGREGATE" = 0 ]; then
		run_aggregation "$MLD" "$STATION" ||
			die "aggregation arm failed or could not be measured per link"
	fi
	return 0
}

do_remove() {
	CFG_DIR=$(dirname "$CONFIG")

	if [ "$DRY_RUN" = 1 ]; then
		say "MLO 2-link remove (dry run)"
		[ -f "$CONFIG" ] || {
			say "config: $CONFIG does not exist; nothing to do"
			return 0
		}
		if [ -f "$STATE_DIR/wireless.bak" ]; then
			say "restore: $STATE_DIR/wireless.bak -> $CONFIG"
			say "reload: wifi reload"
		elif config_has_block; then
			say "remove: strip the marked mlo-2link block from $CONFIG"
			say "reload: wifi reload"
		else
			say "nothing to remove"
		fi
		return 0
	fi

	require_root
	require_config
	need_cmd md5sum
	setup_capture
	acquire_lock
	trap cleanup EXIT
	trap on_int INT
	trap on_term TERM
	trap on_hup HUP

	BAK="$STATE_DIR/wireless.bak"
	BAK_MD5="$STATE_DIR/wireless.bak.md5"
	POST_MD5="$STATE_DIR/wireless.post.md5"
	STATE_META="$STATE_DIR/meta"
	[ -n "$MLD" ] || MLD=$(state_get IFNAME 2>/dev/null || :)

	if [ -f "$BAK" ]; then
		CONFIG_MODIFIED=1
		RELOADED=1
		restore_config || die "restore failed"
		rm -f "$BAK" "$BAK_MD5" "$POST_MD5"
		write_meta 0
		say "remove: done"
		return 0
	fi

	if config_has_block; then
		strip_block || die "could not remove the marked block from $CONFIG"
		wifi_reload
		say "remove: removed the marked block (no backup was present)"
		return 0
	fi

	if section_exists mlo2link; then
		remove_section || die "could not remove wireless.mlo2link"
		wifi_reload
		say "remove: removed wireless.mlo2link by name (no backup was present)"
		return 0
	fi

	say "remove: no active mlo2link block or backup found"
	return 0
}

main() {
	parse_args "$@"
	validate_args

	case "$MODE" in
	setup) do_setup ;;
	check) do_check ;;
	remove) do_remove ;;
	*) die "unknown mode: $MODE" ;;
	esac
}

main "$@"
