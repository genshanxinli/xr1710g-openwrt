#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# uci-restore-guard.sh - durable restore point for scripts that rewrite
# /etc/config/wireless through "uci set" / "uci commit".
#
# Why this exists: restoring only the config *file* does not undo a pending
# UCI delta.  "uci set" writes /tmp/.uci/wireless first and "uci commit"
# folds it into /etc/config/wireless, so a run that dies between the two (or
# a cleanup that only copies the file back) leaves the delta behind, and the
# next unrelated "uci commit wireless" - any script, any person - flushes the
# stale section into /etc/config/wireless.  The file then changes with nobody
# running anything that admits the write, and the live radios keep the old
# state until the next reload.  That is a drift, not a change.
#
# The restore point is kept outside /tmp as well, because a wiped tmpfs
# (logd clear, "rm -rf /tmp/*", a reboot) takes an $OUT/wireless.backup with
# it and leaves the board running a config nobody saved.
#
# Usage (the caller owns argument parsing and the writes):
#
#   . "$(dirname "$0")/../lib/uci-restore-guard.sh"
#
#   urg_init 6g-rx-add-bss                       # snapshot file + delta + md5
#   urg_arm                                      # EXIT/INT/TERM/HUP -> restore
#   urg_mark_dirty                               # first write is about to happen
#   ... uci set ...; uci commit wireless; wifi reload ...
#   urg_disarm                                   # clean end: drop the snapshot
#
# On the trap path urg_restore copies the config back, puts the delta back
# (or removes one that did not exist before), reloads Wi-Fi and checks the
# md5.  A failed restore keeps the snapshot and prints the exact manual
# command; it never deletes its own evidence.
#
# Environment:
#   URG_DIR        snapshot directory (default /root/.uci-restore/<label>,
#                  falling back to $TMPDIR when /root is not writable)
#   URG_DELTA      pending UCI delta (default /tmp/.uci/wireless)
#   URG_NO_RELOAD  1: do not run "wifi reload" from the restore path
#   URG_WIFI       wifi command (default: wifi from PATH)

URG_LABEL=
URG_CFG=
# Keep the environment in charge: a bare "URG_DIR=" here would silently
# replace the caller's value (and a test pointed at a staged bench would
# restore the real board's config path instead).
URG_DIR=${URG_DIR:-}
URG_DELTA=${URG_DELTA:-/tmp/.uci/wireless}
URG_WIFI=${URG_WIFI:-wifi}
URG_MD5=
URG_SNAPSHOT=0
URG_DIRTY=0
URG_RESTORED=0

urg_die() {
	printf 'uci-restore-guard: %s\n' "$*" >&2
	return 1
}

urg_md5_of() {
	if command -v md5sum >/dev/null 2>&1; then
		md5sum "$1" 2>/dev/null | awk '{print $1}'
		return 0
	fi
	if command -v md5 >/dev/null 2>&1; then
		md5 -q "$1" 2>/dev/null
		return 0
	fi
	return 1
}

# urg_init <label> [config]
urg_init() {
	URG_LABEL=$1
	URG_CFG=${2:-/etc/config/wireless}

	[ -n "$URG_LABEL" ] || { urg_die 'urg_init needs a label'; return 1; }
	[ -f "$URG_CFG" ] || { urg_die "no config at $URG_CFG"; return 1; }

	if [ -z "$URG_DIR" ]; then
		if [ "$(id -u 2>/dev/null || echo 0)" = 0 ] && [ -d /root ] && [ -w /root ]; then
			URG_DIR=/root/.uci-restore/$URG_LABEL
		else
			URG_DIR=${TMPDIR:-/tmp}/uci-restore/$URG_LABEL
		fi
	fi
	# Build the next snapshot beside the current one and rename it into
	# place.  $URG_DIR is the evidence a crashed run left behind, so it must
	# survive until a complete replacement exists: the old code ran
	# "rm -rf $URG_DIR" first, and an ENOSPC in the cp then left neither.
	#
	# A SIGKILL between the two renames below still leaves one of the two
	# temporaries behind.  The next urg_init only sweeps its own pid's names,
	# so it does not adopt them: they stay as *.new.<pid> / *.old.<pid>
	# beside $URG_DIR.  They are inert (urg_restore reads $URG_DIR only) and
	# the window is a single rename, so this is recorded rather than
	# reclaimed - a sweep would have to guess whether another live run owns
	# the directory it is deleting.
	_build=$URG_DIR.new.$$
	_old=$URG_DIR.old.$$
	rm -rf "$_build" "$_old"
	mkdir -p "$_build" || { urg_die "cannot create $_build"; return 1; }

	cp -p "$URG_CFG" "$_build/wireless.bak" || {
		rm -rf "$_build"
		urg_die "cannot snapshot $URG_CFG"
		return 1
	}
	URG_MD5=$(urg_md5_of "$_build/wireless.bak") ||
		URG_MD5=$(urg_md5_of "$URG_CFG")
	if [ -z "$URG_MD5" ]; then
		rm -rf "$_build"
		urg_die 'cannot checksum the snapshot'
		return 1
	fi
	printf '%s\n' "$URG_MD5" >"$_build/wireless.md5"

	if [ -f "$URG_DELTA" ]; then
		cp -p "$URG_DELTA" "$_build/delta.bak" || {
			rm -rf "$_build"
			urg_die "cannot snapshot $URG_DELTA"
			return 1
		}
		: >"$_build/delta.present"
	else
		: >"$_build/delta.absent"
	fi

	if [ -e "$URG_DIR" ]; then
		mv "$URG_DIR" "$_old" || {
			rm -rf "$_build"
			urg_die "cannot move the previous restore point $URG_DIR aside"
			return 1
		}
	fi
	if ! mv "$_build" "$URG_DIR"; then
		if [ -e "$_old" ]; then
			mv "$_old" "$URG_DIR" || true
		fi
		rm -rf "$_build"
		urg_die "cannot install the restore point at $URG_DIR"
		return 1
	fi
	rm -rf "$_old"

	URG_SNAPSHOT=1
	printf 'restore point: %s (md5 %s)\n' "$URG_DIR" "$URG_MD5"
	printf 'manual restore: cp -p %s %s; rm -f %s; wifi reload\n' \
		"$URG_DIR/wireless.bak" "$URG_CFG" "$URG_DELTA"
	return 0
}

urg_mark_dirty() {
	URG_DIRTY=1
}

urg_arm() {
	trap 'urg_on_exit $?' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	trap 'exit 129' HUP
}

urg_on_exit() {
	_status=$?
	trap - EXIT INT TERM HUP
	urg_restore || _status=1
	exit "$_status"
}

# urg_restore_delta: put the pending UCI delta back the way it was found.
urg_restore_delta() {
	[ "$URG_SNAPSHOT" = 1 ] || return 0
	if [ -f "$URG_DIR/delta.present" ]; then
		cmp -s "$URG_DIR/delta.bak" "$URG_DELTA" 2>/dev/null && return 0
		cp -p "$URG_DIR/delta.bak" "$URG_DELTA" 2>/dev/null ||
			cat "$URG_DIR/delta.bak" >"$URG_DELTA" 2>/dev/null ||
			return 1
	elif [ -f "$URG_DIR/delta.absent" ]; then
		# The run created a delta; leaving it would let any later commit
		# flush this run's sections into the config file.
		rm -f "$URG_DELTA" || return 1
	fi
	return 0
}

urg_restore() {
	[ "$URG_RESTORED" = 1 ] && return 0
	URG_RESTORED=1
	[ "$URG_SNAPSHOT" = 1 ] || return 0
	[ "$URG_DIRTY" = 1 ] || return 0

	_rc=0
	if ! cmp -s "$URG_DIR/wireless.bak" "$URG_CFG" 2>/dev/null; then
		printf 'restore: %s <- %s\n' "$URG_CFG" "$URG_DIR/wireless.bak"
		cp -p "$URG_DIR/wireless.bak" "$URG_CFG" 2>/dev/null ||
			cat "$URG_DIR/wireless.bak" >"$URG_CFG" 2>/dev/null ||
			_rc=1
	fi
	urg_restore_delta || _rc=1
	if [ "$_rc" = 0 ] && [ "${URG_NO_RELOAD:-0}" != 1 ] &&
		command -v "$URG_WIFI" >/dev/null 2>&1; then
		"$URG_WIFI" reload >/dev/null 2>&1 || _rc=1
	fi

	_got=$(urg_md5_of "$URG_CFG")
	if [ "$_rc" = 0 ] && [ -n "$_got" ] && [ "$_got" = "$URG_MD5" ]; then
		printf 'restore: config restored (md5 %s), delta cleared\n' "$_got"
		rm -rf "$URG_DIR"
		return 0
	fi
	printf 'restore: FAILED (expected md5 %s, now %s)\n' \
		"$URG_MD5" "${_got:-unreadable}" >&2
	printf 'restore: snapshot kept; manual restore: cp -p %s %s; rm -f %s; wifi reload\n' \
		"$URG_DIR/wireless.bak" "$URG_CFG" "$URG_DELTA" >&2
	return 1
}

# urg_disarm: the run ended clean and the config is meant to stay written.
# It never touches the caller's traps: a caller that disarms from inside its
# own EXIT trap would otherwise clear the trap it is running in.
urg_disarm() {
	URG_DIRTY=0
	if [ "$URG_SNAPSHOT" = 1 ]; then
		rm -rf "$URG_DIR"
		URG_SNAPSHOT=0
	fi
	return 0
}
