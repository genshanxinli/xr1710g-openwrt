#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# 6g-only.sh - bring up a marked, temporary 6 GHz-only BSS for association
# tests, and roll it back again.
#
# The 6 GHz association tests on the XR1710G used to be run by hand: a
# temporary phy0.2-ap1 BSS was added to /etc/config/wireless, left running
# for 600 s and removed again.  That is easy to leave behind, and nothing
# checked that the 6 GHz radio was actually on channel 37 at EHT320.
#
# This helper:
#
#   - saves /etc/config/wireless and its md5 in /root/.6g-only-backup,
#   - forces radio2 (6 GHz on this board) to band=6g, channel=37,
#     htmode=EHT320 and enabled, without touching radio0 or radio1,
#   - appends one marked wifi-iface section with a clear SAE SSID,
#   - runs `wifi reload` and waits for the BSS in `iw dev`,
#   - prints the exact `iw dev` and `iw phy` readback,
#   - restores the backup and reloads with --remove, and also on
#     INT/TERM/HUP while --add is still running.
#
# The backup is kept until a successful --remove, so a run that is killed
# with SIGKILL (or loses power) can still be rolled back afterwards.
# --remove restores the whole file: do not edit /etc/config/wireless while
# the test BSS is up, or those edits are lost too.
#
# Usage:
#   scripts/wireless/6g-only.sh --add [--wait SECONDS]
#   scripts/wireless/6g-only.sh --remove
#   scripts/wireless/6g-only.sh --dry-run [--add|--remove]
#
# The helper edits the config file directly instead of using `uci set`, so
# nothing outside the marked block and radio2 is rewritten: `uci commit`
# would normalise the whole file and make the "no 5G/2.4G diff" check
# meaningless.

set -u

PROG=${0##*/}
DEFAULT_CONFIG=/etc/config/wireless
DEFAULT_BACKUP_DIR=/root/.6g-only-backup

RADIO=radio2
IFACE=sixg_only
SSID=6g-only-bringup
KEY=6g-only-bringup
WAIT=30

CFG=$DEFAULT_CONFIG
BACKUP_DIR=
TMPFILE=
ACTION=
DRY_RUN=0
CONFIG_GIVEN=0

ORIG_MD5=
DIRTY=0
KEEP=0

usage() {
	cat <<EOF
Usage: $PROG --add [--wait SECONDS]
       $PROG --remove
       $PROG --dry-run [--add|--remove]

Bring up a temporary 6 GHz-only AP BSS on radio2, or roll it back.

Options:
  --add             back up the config, force radio2 to 6g/channel 37/
                    EHT320, append the marked $IFACE BSS, reload wifi,
                    wait for the BSS and print the iw readback
  --remove          restore the backup taken by --add and reload wifi
  --dry-run         print what would be changed; writes nothing and
                    works without a wireless device
  --wait SECONDS    how long --add waits for the BSS to appear and
                    --remove waits for it to disappear (default: $WAIT)
  -h, --help        show this help

Testing options:
  --config FILE     operate on FILE instead of $DEFAULT_CONFIG
  --backup-dir DIR  store the backup in DIR; defaults to
                    $DEFAULT_BACKUP_DIR, or .6g-only-backup next
                    to a --config file

Environment: WIRELESS_CONFIG and SIXG_ONLY_BACKUP_DIR do the same as
--config and --backup-dir.

--add leaves the BSS running until --remove.  On INT, TERM or HUP while
--add is running, the original config is restored automatically.
Exit status: 0 success or dry run, 1 failure, 2 usage error.
EOF
}

die() {
	printf '%s: %s\n' "$PROG" "$*" >&2
	exit 1
}

usage_error() {
	printf '%s: %s\n' "$PROG" "$*" >&2
	printf "Try '%s --help'.\n" "$PROG" >&2
	exit 2
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

md5_of() {
	md5sum "$1" 2>/dev/null | awk '{ print $1 }'
}

cfg_has_section() {
	_want=$1
	awk -v want="$_want" '
		function name(line,   t) {
			t = line
			sub(/^[ \t]*config[ \t]+[^ \t]+[ \t]*/, "", t)
			sub(/[ \t]+#.*$/, "", t)
			gsub(/[\047"]/, "", t)
			sub(/[ \t]+$/, "", t)
			return t
		}
		/^[ \t]*config[ \t]/ {
			if (name($0) == want)
				found = 1
		}
		END { exit !found }
	' "$CFG"
}

# cfg_get <section> <option> - print the value, or nothing when unset.
cfg_get() {
	_want_section=$1
	_want_option=$2
	awk -v want_section="$_want_section" -v want_option="$_want_option" '
		function name(line,   t) {
			t = line
			sub(/^[ \t]*config[ \t]+[^ \t]+[ \t]*/, "", t)
			sub(/[ \t]+#.*$/, "", t)
			gsub(/[\047"]/, "", t)
			sub(/[ \t]+$/, "", t)
			return t
		}
		/^[ \t]*config[ \t]/ {
			found = (name($0) == want_section)
			next
		}
		found && $1 == "option" && $2 == want_option {
			value = $0
			sub(/^[ \t]*option[ \t]+[^ \t]+[ \t]*/, "", value)
			sub(/[ \t]+$/, "", value)
			if (value ~ /^\047.*\047$/ || value ~ /^".*"$/)
				value = substr(value, 2, length(value) - 2)
			print value
			exit
		}
	' "$CFG"
}

# cfg_set <section> <option> <value> - replace or add one option without
# touching anything else in the file.
cfg_set() {
	_set_section=$1
	_set_option=$2
	_set_value=$3
	TMPFILE=$(dirname "$CFG")/.6g-only.$$
	_tmp=$TMPFILE

	awk -v want_section="$_set_section" -v want_option="$_set_option" -v value="$_set_value" '
		function name(line,   t) {
			t = line
			sub(/^[ \t]*config[ \t]+[^ \t]+[ \t]*/, "", t)
			sub(/[ \t]+#.*$/, "", t)
			gsub(/[\047"]/, "", t)
			sub(/[ \t]+$/, "", t)
			return t
		}
		BEGIN { in_section = 0; done = 0 }
		/^[ \t]*config[ \t]/ {
			if (in_section && !done) {
				print "\toption " want_option " \"" value "\""
				done = 1
			}
			in_section = (name($0) == want_section)
			print
			next
		}
		in_section && $1 == "option" && $2 == want_option {
			if (!done) {
				print "\toption " want_option " \"" value "\""
				done = 1
			}
			next
		}
		{ print }
		END {
			if (in_section && !done)
				print "\toption " want_option " \"" value "\""
		}
	' "$CFG" > "$_tmp" || {
		rm -f "$_tmp"
		return 1
	}

	cat "$_tmp" > "$CFG" || {
		rm -f "$_tmp"
		TMPFILE=
		return 1
	}
	rm -f "$_tmp"
	TMPFILE=
}

# cfg_ensure <section> <option> <value> - only rewrite when it differs, so
# an already-correct radio2 keeps its exact text.
cfg_ensure() {
	_cur=$(cfg_get "$1" "$2")
	[ "$_cur" = "$3" ] && return 0
	printf '%s: %s.%s: %s -> %s\n' "$PROG" "$1" "$2" "${_cur:-<unset>}" "$3"
	cfg_set "$1" "$2" "$3"
}

backup_config() {
	if [ -e "$BAK" ]; then
		die "backup already exists at $BAK; run '$PROG --remove' first"
	fi

	mkdir -p "$BACKUP_DIR" || die "cannot create $BACKUP_DIR"
	chmod 700 "$BACKUP_DIR" 2>/dev/null || true
	cp -p "$CFG" "$BAK" || {
		rm -f "$BAK" "$BAK_MD5"
		die "cannot copy $CFG to $BAK"
	}
	ORIG_MD5=$(md5_of "$CFG")
	[ -n "$ORIG_MD5" ] || {
		rm -f "$BAK" "$BAK_MD5"
		die "cannot checksum $CFG"
	}
	printf '%s\n' "$ORIG_MD5" > "$BAK_MD5" || {
		rm -f "$BAK" "$BAK_MD5"
		die "cannot write $BAK_MD5"
	}

	[ "$(md5_of "$BAK")" = "$ORIG_MD5" ] || {
		rm -f "$BAK" "$BAK_MD5"
		die "backup verification failed"
	}
	chmod 600 "$BAK" "$BAK_MD5" 2>/dev/null || true
	printf '%s: saved %s to %s (md5 %s)\n' "$PROG" "$CFG" "$BAK" "$ORIG_MD5"
}

iface_block() {
	cat <<EOF

# >>> 6g-only: BEGIN (added by scripts/wireless/6g-only.sh; remove with --remove)
config wifi-iface '$IFACE'
	option device '$RADIO'
	option mode 'ap'
	option network 'lan'
	option ssid '$SSID'
	option encryption 'sae'
	option key '$KEY'
	option ieee80211w '2'
	option sae_pwe '2'
	option disabled '0'
# <<< 6g-only: END
EOF
}

append_iface() {
	# Never glue the marker onto a config file that lacks a final newline.
	[ -n "$(tail -c 1 "$CFG" 2>/dev/null)" ] && printf '\n' >> "$CFG"
	iface_block >> "$CFG"
}

reload_wifi() {
	wifi reload
}

bss_present() {
	iw dev 2>/dev/null | awk -v ssid="$SSID" '
		$1 == "ssid" && $2 == ssid { found = 1 }
		END { exit !found }
	'
}

wait_for_bss_gone() {
	_left=$WAIT
	printf '%s: waiting up to %ss for BSS "%s" to disappear ... ' "$PROG" "$WAIT" "$SSID"
	while [ "$_left" -gt 0 ]; do
		if ! bss_present; then
			printf 'gone\n'
			return 0
		fi
		sleep 1
		_left=$((_left - 1))
	done
	if ! bss_present; then
		printf 'gone\n'
		return 0
	fi
	printf 'still up\n'
	return 1
}

wait_for_bss() {
	_left=$WAIT
	printf '%s: waiting up to %ss for BSS "%s" ... ' "$PROG" "$WAIT" "$SSID"
	while [ "$_left" -gt 0 ]; do
		if bss_present; then
			printf 'up\n'
			return 0
		fi
		sleep 1
		_left=$((_left - 1))
	done
	if bss_present; then
		printf 'up\n'
		return 0
	fi
	printf 'not found\n'
	return 1
}

print_readback() {
	printf '\n=== iw dev (exact output) ===\n'
	iw dev
	printf '\n=== iw phy (exact output) ===\n'
	iw phy
}

restore_config() {
	[ -f "$BAK" ] || return 1

	# The device's busybox tr does not implement [:space:] and deletes the
	# letters a, c, e, s, p, ... instead, so do not use it to trim the hash.
	_want=
	if [ -f "$BAK_MD5" ]; then
		_want=$(cat "$BAK_MD5")
	fi
	if [ -n "$_want" ] && [ "$(md5_of "$BAK")" != "$_want" ]; then
		printf '%s: backup %s does not match saved md5 %s; not touching %s\n' \
			"$PROG" "$BAK" "$_want" "$CFG" >&2
		return 1
	fi
	cat "$BAK" > "$CFG" || return 1
	_got=$(md5_of "$CFG")
	[ -n "$_got" ] || return 1
	if [ -n "$_want" ] && [ "$_want" != "$_got" ]; then
		printf '%s: restored config md5 %s does not match backup md5 %s\n' \
			"$PROG" "$_got" "$_want" >&2
		return 1
	fi
	RESTORED_MD5=$_got
	return 0
}

drop_backup() {
	rm -f "$BAK" "$BAK_MD5"
	rmdir "$BACKUP_DIR" 2>/dev/null || true
}

cleanup() {
	_status=$?
	trap - EXIT INT TERM HUP
	[ -n "$TMPFILE" ] && rm -f "$TMPFILE"
	if [ "$KEEP" -eq 0 ] && [ "$DIRTY" -eq 1 ]; then
		printf '\n%s: rolling %s back to %s\n' "$PROG" "$CFG" "$BAK" >&2
		if restore_config; then
			DIRTY=0
			if reload_wifi; then
				drop_backup
				printf '%s: restored md5 %s\n' "$PROG" "$RESTORED_MD5" >&2
			else
				printf '%s: config restored but wifi reload failed; backup kept, run '\''%s --remove'\''\n' \
					"$PROG" "$PROG" >&2
			fi
		else
			printf '%s: rollback FAILED; original config is at %s\n' \
				"$PROG" "$BAK" >&2
		fi
	fi
	exit "$_status"
}

add_bss() {
	[ -f "$CFG" ] || die "no $CFG (is this an OpenWrt device?)"
	need_cmd awk
	need_cmd md5sum
	need_cmd wifi
	need_cmd iw
	need_cmd sleep

	if [ -e "$BAK" ]; then
		die "backup already exists at $BAK; run '$PROG --remove' first"
	fi
	cfg_has_section "$RADIO" || die "wireless.$RADIO not found in $CFG; cannot add a 6 GHz BSS"
	if cfg_has_section "$IFACE"; then
		die "wireless.$IFACE already exists in $CFG; remove it manually first"
	fi

	backup_config
	DIRTY=1

	cfg_ensure "$RADIO" band 6g || die "cannot set wireless.$RADIO.band"
	cfg_ensure "$RADIO" channel 37 || die "cannot set wireless.$RADIO.channel"
	cfg_ensure "$RADIO" htmode EHT320 || die "cannot set wireless.$RADIO.htmode"
	# An unset disabled option means enabled; only override an explicit 1.
	if [ "$(cfg_get "$RADIO" disabled)" = 1 ]; then
		cfg_ensure "$RADIO" disabled 0 || die "cannot enable wireless.$RADIO"
	fi

	append_iface || die "cannot append the 6g-only block"

	reload_wifi || die "wifi reload failed"
	if ! wait_for_bss; then
		printf '%s: BSS "%s" did not appear; last iw dev output:\n' "$PROG" "$SSID" >&2
		iw dev >&2
		exit 1
	fi

	printf '%s: active config md5 %s (original %s)\n' \
		"$PROG" "$(md5_of "$CFG")" "$ORIG_MD5"
	printf '%s: SSID "%s" key "%s" on %s (band 6g, channel 37, EHT320)\n' \
		"$PROG" "$SSID" "$KEY" "$RADIO"
	printf '%s: roll back with '\''%s --remove'\''\n' "$PROG" "$PROG"

	print_readback

	KEEP=1
	exit 0
}

remove_bss() {
	if [ ! -f "$BAK" ]; then
		if grep -q '^# >>> 6g-only: BEGIN' "$CFG" 2>/dev/null; then
			die "the 6g-only block is present but $BAK is missing; cannot restore the original config automatically"
		fi
		printf '%s: no backup at %s, nothing to remove\n' "$PROG" "$BAK"
		exit 0
	fi

	need_cmd awk
	need_cmd iw
	need_cmd md5sum

	DIRTY=1
	restore_config || die "cannot restore $CFG from $BAK"
	# The file is back to the saved bytes; do not let a failure below make
	# the EXIT trap restore (and delete) the kept backup a second time.
	DIRTY=0
	if ! command -v wifi >/dev/null 2>&1; then
		drop_backup
		printf '%s: restored %s to md5 %s, but wifi is missing; run "wifi reload" manually\n' \
			"$PROG" "$CFG" "$RESTORED_MD5" >&2
		exit 1
	fi
	if ! reload_wifi; then
		printf '%s: config restored to md5 %s but wifi reload failed; backup kept, run '\''%s --remove'\'' again\n' \
			"$PROG" "$RESTORED_MD5" "$PROG" >&2
		exit 1
	fi
	if ! wait_for_bss_gone; then
		printf '%s: config restored to md5 %s but BSS "%s" is still present; backup kept, run '\''%s --remove'\'' again\n' \
			"$PROG" "$RESTORED_MD5" "$SSID" "$PROG" >&2
		exit 1
	fi
	drop_backup

	printf '%s: restored %s from %s (md5 %s)\n' \
		"$PROG" "$CFG" "$BAK" "$RESTORED_MD5"
	exit 0
}

dry_run() {
	printf '%s: dry run, no changes will be made\n' "$PROG"

	if [ -f "$CFG" ]; then
		printf '%s: config %s (current md5 %s)\n' "$PROG" "$CFG" "$(md5_of "$CFG")"
	else
		printf '%s: config %s is not present (no device here)\n' "$PROG" "$CFG"
	fi

	if [ "$ACTION" = remove ]; then
		if [ -e "$BAK" ]; then
			printf '%s: would restore %s from %s\n' "$PROG" "$CFG" "$BAK"
			if [ -f "$BAK_MD5" ]; then
				printf '%s: would expect md5 %s\n' "$PROG" "$(cat "$BAK_MD5")"
			fi
			printf '%s: would run: wifi reload\n' "$PROG"
		else
			printf '%s: no backup at %s, --remove would do nothing\n' "$PROG" "$BAK"
		fi
		exit 0
	fi

	if [ -f "$CFG" ] && ! cfg_has_section "$RADIO"; then
		printf '%s: warning: wireless.%s is missing, --add would abort\n' "$PROG" "$RADIO"
	fi

	for _pair in band:6g channel:37 htmode:EHT320 disabled:0; do
		_option=${_pair%%:*}
		_value=${_pair#*:}
		if [ -f "$CFG" ]; then
			_current=$(cfg_get "$RADIO" "$_option")
		else
			_current=
		fi
		if [ "$_option" = disabled ] && [ "$_current" != 1 ]; then
			printf '%s: wireless.%s.disabled is not set to 1, radio2 is enabled\n' \
				"$PROG" "$RADIO"
		elif [ "$_current" = "$_value" ]; then
			printf '%s: wireless.%s.%s already %s\n' "$PROG" "$RADIO" "$_option" "$_value"
		else
			printf '%s: would set wireless.%s.%s=%s (now: %s)\n' \
				"$PROG" "$RADIO" "$_option" "$_value" "${_current:-<unset>}"
		fi
	done

	if [ -e "$BAK" ]; then
		printf '%s: warning: a backup already exists at %s; --add would abort\n' "$PROG" "$BAK"
	else
		printf '%s: would save %s and its md5 under %s\n' "$PROG" "$CFG" "$BACKUP_DIR"
	fi

	printf '%s: would append this marked block to %s:\n' "$PROG" "$CFG"
	iface_block
	printf '%s: would run: wifi reload, then wait %ss for BSS "%s"\n' "$PROG" "$WAIT" "$SSID"
	exit 0
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--add)
		[ -n "$ACTION" ] && usage_error "only one of --add and --remove may be given"
		ACTION=add
		;;
	--remove)
		[ -n "$ACTION" ] && usage_error "only one of --add and --remove may be given"
		ACTION=remove
		;;
	--dry-run)
		DRY_RUN=1
		;;
	--wait)
		[ "$#" -ge 2 ] || usage_error "--wait needs a value"
		WAIT=$2
		case "$WAIT" in
		''|*[!0-9]*) usage_error "--wait needs a non-negative number" ;;
		esac
		shift
		;;
	--config)
		[ "$#" -ge 2 ] || usage_error "--config needs a value"
		CFG=$2
		CONFIG_GIVEN=1
		shift
		;;
	--backup-dir)
		[ "$#" -ge 2 ] || usage_error "--backup-dir needs a value"
		BACKUP_DIR=$2
		shift
		;;
	-h|--help)
		usage
		exit 0
		;;
	*)
		usage_error "unknown argument: $1"
		;;
	esac
	shift
done

# Environment overrides are accepted as well so a test bench can export
# them once.  Command-line options win.
if [ "$CONFIG_GIVEN" -eq 0 ] && [ -n "${WIRELESS_CONFIG:-}" ]; then
	CFG=$WIRELESS_CONFIG
	CONFIG_GIVEN=1
fi
if [ -z "$BACKUP_DIR" ]; then
	if [ -n "${SIXG_ONLY_BACKUP_DIR:-}" ]; then
		BACKUP_DIR=$SIXG_ONLY_BACKUP_DIR
	elif [ "$CONFIG_GIVEN" -eq 1 ]; then
		BACKUP_DIR=$(dirname "$CFG")/.6g-only-backup
	else
		BACKUP_DIR=$DEFAULT_BACKUP_DIR
	fi
fi
BAK=$BACKUP_DIR/wireless
BAK_MD5=$BACKUP_DIR/wireless.md5

[ "$DRY_RUN" -eq 1 ] && dry_run

[ -n "$ACTION" ] || usage_error "one of --add, --remove or --dry-run is required"

# Only the real /etc/config/wireless needs root: a staged config is a test
# bench, and the fake wifi/iw there run as the invoking user.
if [ "$CONFIG_GIVEN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
	die "must be run as root (or use --dry-run)"
fi

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

case "$ACTION" in
add)
	add_bss
	;;
remove)
	remove_bss
	;;
esac
