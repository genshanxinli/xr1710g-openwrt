#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# netwatchdog-guard.sh - shared netwatchdog hold/resume guard for experiment
# scripts that can drop the network or reboot the board.
#
# netwatchdog reboots the board when the network disappears, which corrupts a
# destructive experiment (and can interrupt its own cleanup).  An experiment
# that will disconnect or reboot the board takes a hold first and releases it
# on exit.  This library centralises that hold, its trap and its result record.
#
# Integration (the caller owns argument parsing and the destructive steps):
#
#   . "$(dirname "$0")/../lib/netwatchdog-guard.sh"
#
#   if [ "$APPLY" -eq 1 ]; then
#       nw_guard_init --apply --result-json "$OUT/netwatchdog.json"
#   else
#       nw_guard_init --dry-run
#   fi
#   nw_guard_take || exit 1           # refuse the destructive step
#   ... destructive experiment ...
#   # EXIT/HUP/INT/TERM release the hold and write the JSON record.
#
# Behavior:
#   * --dry-run (the default) never runs netwatchdog, never reads or creates
#     the hold file and writes no JSON.  --apply is the only way to hold.
#   * --apply is fail-closed: a missing netwatchdog or a failing "hold on"
#     makes nw_guard_take return nonzero, so the caller can skip its
#     destructive step.  NWD_ALLOW_NO_SERVICE=1 downgrades the missing-service
#     case to a warning so an audit harness can still run.
#   * A hold that was already active is left active.  The guard records the
#     holder (PID + start epoch) in a sidecar next to the hold file:
#       - a hold owned by another live PID makes nw_guard_take fail (busy)
#         instead of stealing the lock from a long-running holder;
#       - a hold whose owner is gone, or older than --stale-minutes
#         (default 60), is reclaimed with a warning;
#       - nw_guard_release only releases a hold whose owner record is ours.
#   * netwatchdog calls run under --timeout (default 300 s).  A timeout
#     returns nonzero and leaves the hold state untouched; it is never
#     force-cleared.
#   * A hold this guard took is released on EXIT, HUP, INT and TERM.  A release
#     failure prints the exact manual recovery command.
#   * hold_at/resume_at (UTC and epoch) and the action/result are written to
#     the result JSON when one was given and the mode is apply.
#   * netwatchdog itself, its configuration and its timeouts are not touched.
#
# POSIX sh (busybox ash on OpenWrt).  Verified with sh -n, shellcheck -s sh and
# scripts/lib/netwatchdog-guard-test.sh under sh and busybox sh.

NW_GUARD_COMMAND=${NW_GUARD_COMMAND:-netwatchdog}
NW_GUARD_HOLD_FILE=${NW_GUARD_HOLD_FILE:-/tmp/netwatchdog.hold}
NW_GUARD_TIMEOUT=${NW_GUARD_TIMEOUT:-300}
NW_GUARD_STALE_MINUTES=${NW_GUARD_STALE_MINUTES:-60}
NW_GUARD_MODE=dry-run
NW_GUARD_RESULT_JSON=
NW_GUARD_LABEL=
NW_GUARD_ACTION=not-taken
NW_GUARD_RESULT=ok
NW_GUARD_HOLD_AT=
NW_GUARD_HOLD_EPOCH=
NW_GUARD_RESUME_AT=
NW_GUARD_RESUME_EPOCH=
NW_GUARD_PRIOR_HOLD=0
NW_GUARD_SERVICE_PRESENT=0
NW_GUARD_TAKEN=0
NW_GUARD_MANUAL_COMMAND=
NW_GUARD_INSTALL_TRAP=1
NW_GUARD_SIGNAL=
NW_GUARD_INITIALIZED=0
NW_GUARD_CLEANED=0
NW_GUARD_OWNER_FILE=
NW_GUARD_OWNER_PID=
NW_GUARD_STALE_RECLAIMED=0

_nw_guard_warn() {
	printf 'netwatchdog-guard: %s\n' "$*" >&2
}

_nw_guard_usage() {
	cat <<'USAGE'
Usage: . netwatchdog-guard.sh; nw_guard_init [options]

Options:
  --apply             take the netwatchdog hold for the experiment
  --dry-run           touch nothing; this is the default
  --result-json PATH  write the hold/resume timings and outcome to PATH
  --label TEXT        free-form experiment label stored in the JSON
  --command CMD       netwatchdog command (default: netwatchdog)
  --hold-file PATH    hold state file (default: /tmp/netwatchdog.hold)
  --timeout SEC       timeout for "hold on"/"hold off" (default: 300)
  --stale-minutes N   reclaim a hold whose owner is older than N minutes
                      (default: 60); a hold whose owner PID is gone is always
                      stale
  --no-trap           do not install the EXIT/HUP/INT/TERM trap; the caller must
                      call nw_guard_cleanup from its own trap

Environment:
  NWD_ALLOW_NO_SERVICE=1  continue unprotected when netwatchdog is missing
                          (the default is to fail closed)
USAGE
}

_nw_guard_utc() {
	date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown'
}

_nw_guard_epoch() {
	date +%s 2>/dev/null || printf '0'
}

_nw_guard_present() {
	command -v "$NW_GUARD_COMMAND" >/dev/null 2>&1
}

# The hold file itself is owned by netwatchdog; the guard records who took it
# in a sidecar ("<pid> <epoch>") so a foreign holder is never released and a
# dead holder's lock can be reclaimed.
_nw_guard_owner_field() {
	[ -n "$NW_GUARD_OWNER_FILE" ] || return 1
	[ -f "$NW_GUARD_OWNER_FILE" ] || return 1
	awk -v field="$1" 'NR == 1 { print $field; exit }' "$NW_GUARD_OWNER_FILE" 2>/dev/null
}

_nw_guard_pid_alive() {
	case $1 in
	'' | *[!0-9]*) return 1 ;;
	esac
	kill -0 "$1" 2>/dev/null
}

# True when the hold file exists and its recorded owner is gone or too old.
# A hold with no owner record is a manual/pre-guard hold: never stale.
_nw_guard_stale() {
	_nw_guard_stale_pid=$(_nw_guard_owner_field 1)
	_nw_guard_stale_epoch=$(_nw_guard_owner_field 2)
	[ -n "$_nw_guard_stale_pid" ] || return 1
	_nw_guard_pid_alive "$_nw_guard_stale_pid" || return 0
	case $_nw_guard_stale_epoch in
	'' | *[!0-9]*) return 1 ;;
	esac
	_nw_guard_age=$(( $(_nw_guard_epoch) - _nw_guard_stale_epoch ))
	[ "$_nw_guard_age" -ge "$((NW_GUARD_STALE_MINUTES * 60))" ]
}

_nw_guard_write_owner() {
	NW_GUARD_OWNER_PID=$$
	printf '%s %s\n' "$$" "$NW_GUARD_HOLD_EPOCH" >"$NW_GUARD_OWNER_FILE" 2>/dev/null ||
		_nw_guard_warn "warning: cannot record the hold owner in $NW_GUARD_OWNER_FILE"
}

# Run a netwatchdog command under NW_GUARD_TIMEOUT.  Returns 124 on timeout and
# otherwise the command's own status.  Without a timeout binary the call is
# plain (a warning is not worth it: the command is instantaneous in practice).
_nw_guard_run_timed() {
	_nw_guard_timed_secs=$1
	shift
	if command -v timeout >/dev/null 2>&1; then
		timeout "$_nw_guard_timed_secs" "$@"
		return
	fi
	"$@"
}

# Print on|off|missing for the watchdog hold.  Read-only and safe to call in a
# dry run so a script can describe what it would do.
nw_guard_state() {
	if [ -e "$NW_GUARD_HOLD_FILE" ]; then
		printf 'on\n'
	elif _nw_guard_present; then
		printf 'off\n'
	else
		printf 'missing\n'
	fi
}

nw_guard_init() {
	NW_GUARD_MODE=dry-run
	NW_GUARD_RESULT_JSON=
	NW_GUARD_LABEL=
	NW_GUARD_INSTALL_TRAP=1
	while [ "$#" -gt 0 ]; do
		case $1 in
		--apply) NW_GUARD_MODE=apply ;;
		--dry-run) NW_GUARD_MODE=dry-run ;;
		--result-json)
			if [ "$#" -lt 2 ]; then
				_nw_guard_warn "missing value for --result-json"
				return 2
			fi
			NW_GUARD_RESULT_JSON=$2
			shift
			;;
		--label)
			if [ "$#" -lt 2 ]; then
				_nw_guard_warn "missing value for --label"
				return 2
			fi
			NW_GUARD_LABEL=$2
			shift
			;;
		--command)
			if [ "$#" -lt 2 ]; then
				_nw_guard_warn "missing value for --command"
				return 2
			fi
			NW_GUARD_COMMAND=$2
			shift
			;;
		--hold-file)
			if [ "$#" -lt 2 ]; then
				_nw_guard_warn "missing value for --hold-file"
				return 2
			fi
			NW_GUARD_HOLD_FILE=$2
			shift
			;;
		--timeout)
			if [ "$#" -lt 2 ]; then
				_nw_guard_warn "missing value for --timeout"
				return 2
			fi
			case $2 in
			'' | *[!0-9]*)
				_nw_guard_warn "invalid --timeout: $2"
				return 2
				;;
			esac
			NW_GUARD_TIMEOUT=$2
			shift
			;;
		--stale-minutes)
			if [ "$#" -lt 2 ]; then
				_nw_guard_warn "missing value for --stale-minutes"
				return 2
			fi
			case $2 in
			'' | *[!0-9]*)
				_nw_guard_warn "invalid --stale-minutes: $2"
				return 2
				;;
			esac
			NW_GUARD_STALE_MINUTES=$2
			shift
			;;
		--no-trap) NW_GUARD_INSTALL_TRAP=0 ;;
		--help | -h)
			_nw_guard_usage
			return 0
			;;
		*)
			_nw_guard_warn "unknown argument: $1"
			return 2
			;;
		esac
		shift
	done

	NW_GUARD_ACTION=not-taken
	NW_GUARD_RESULT=ok
	NW_GUARD_HOLD_AT=
	NW_GUARD_HOLD_EPOCH=
	NW_GUARD_RESUME_AT=
	NW_GUARD_RESUME_EPOCH=
	NW_GUARD_PRIOR_HOLD=0
	NW_GUARD_SERVICE_PRESENT=0
	NW_GUARD_TAKEN=0
	NW_GUARD_MANUAL_COMMAND=
	NW_GUARD_SIGNAL=
	NW_GUARD_CLEANED=0
	NW_GUARD_OWNER_FILE=$NW_GUARD_HOLD_FILE.owner
	NW_GUARD_OWNER_PID=
	NW_GUARD_STALE_RECLAIMED=0
	NW_GUARD_INITIALIZED=1

	if [ "$NW_GUARD_INSTALL_TRAP" -eq 1 ]; then
		trap '_nw_guard_on_exit' EXIT
		trap '_nw_guard_on_signal HUP' HUP
		trap '_nw_guard_on_signal INT' INT
		trap '_nw_guard_on_signal TERM' TERM
	fi
	return 0
}

# Take the hold.  Fail-closed: a missing netwatchdog, a hold owned by another
# live process, or a failing "hold on" returns nonzero so the caller can skip
# its destructive step.  NWD_ALLOW_NO_SERVICE=1 allows the missing-service
# case for an audit harness.
nw_guard_take() {
	if [ "$NW_GUARD_INITIALIZED" -ne 1 ]; then
		_nw_guard_warn "nw_guard_take called before nw_guard_init; not holding"
		return 0
	fi
	if [ "$NW_GUARD_MODE" = dry-run ]; then
		NW_GUARD_ACTION=skipped-dry-run
		NW_GUARD_RESULT=dry-run
		return 0
	fi
	if [ "$NW_GUARD_TAKEN" -eq 1 ]; then
		return 0
	fi
	if ! _nw_guard_present; then
		if [ "${NWD_ALLOW_NO_SERVICE:-0}" = 1 ]; then
			_nw_guard_warn "warning: $NW_GUARD_COMMAND not found; continuing because NWD_ALLOW_NO_SERVICE=1"
			NW_GUARD_ACTION=missing-allowed
			NW_GUARD_RESULT=missing-service-allowed
			return 0
		fi
		_nw_guard_warn "refusing the destructive step: $NW_GUARD_COMMAND not found"
		_nw_guard_warn "install/enable netwatchdog, or set NWD_ALLOW_NO_SERVICE=1 to run unprotected"
		NW_GUARD_ACTION=refused
		NW_GUARD_RESULT=missing-service
		return 1
	fi
	NW_GUARD_SERVICE_PRESENT=1
	if [ -e "$NW_GUARD_HOLD_FILE" ]; then
		_nw_guard_owner_pid=$(_nw_guard_owner_field 1)
		if [ -z "$_nw_guard_owner_pid" ] || [ "$_nw_guard_owner_pid" = "$$" ]; then
			# No owner record: a manual or pre-guard hold, left untouched as
			# before.  Our own PID: a re-entrant take.
			NW_GUARD_PRIOR_HOLD=1
			NW_GUARD_ACTION=unchanged
			NW_GUARD_RESULT=ok
			return 0
		fi
		if ! _nw_guard_stale; then
			_nw_guard_warn "refusing the destructive step: $NW_GUARD_HOLD_FILE is held by live PID $_nw_guard_owner_pid"
			NW_GUARD_ACTION=denied-busy
			NW_GUARD_RESULT=busy
			return 1
		fi
		_nw_guard_warn "warning: reclaiming stale netwatchdog hold (owner $_nw_guard_owner_pid, since $(_nw_guard_owner_field 2))"
		rm -f "$NW_GUARD_HOLD_FILE" "$NW_GUARD_OWNER_FILE"
		NW_GUARD_STALE_RECLAIMED=1
	fi
	# Set the taken flag before the command: a signal between the hold write
	# and the next line must still lead cleanup to release the hold.
	NW_GUARD_TAKEN=1
	_nw_guard_run_timed "$NW_GUARD_TIMEOUT" "$NW_GUARD_COMMAND" hold on >/dev/null 2>&1
	_nw_guard_rc=$?
	if [ "$_nw_guard_rc" -eq 0 ]; then
		NW_GUARD_HOLD_AT=$(_nw_guard_utc)
		NW_GUARD_HOLD_EPOCH=$(_nw_guard_epoch)
		_nw_guard_write_owner
		NW_GUARD_ACTION=took
		NW_GUARD_RESULT=ok
		return 0
	fi
	if [ -e "$NW_GUARD_HOLD_FILE" ]; then
		# The command failed or timed out but the hold is active; keep it
		# tracked so cleanup releases what was actually written.
		NW_GUARD_HOLD_AT=$(_nw_guard_utc)
		NW_GUARD_HOLD_EPOCH=$(_nw_guard_epoch)
		_nw_guard_write_owner
		NW_GUARD_ACTION=took
		if [ "$_nw_guard_rc" -eq 124 ]; then
			NW_GUARD_RESULT=hold-timeout
			_nw_guard_warn "warning: $NW_GUARD_COMMAND hold on timed out after ${NW_GUARD_TIMEOUT}s; the hold is active and will be released"
			return 1
		fi
		NW_GUARD_RESULT=hold-command-failed
		_nw_guard_warn "warning: $NW_GUARD_COMMAND hold on returned nonzero; the hold is active and will be released"
		return 0
	fi
	NW_GUARD_TAKEN=0
	if [ "$_nw_guard_rc" -eq 124 ]; then
		_nw_guard_warn "warning: $NW_GUARD_COMMAND hold on timed out after ${NW_GUARD_TIMEOUT}s; no hold was written"
		NW_GUARD_ACTION=timeout
		NW_GUARD_RESULT=hold-timeout
		return 1
	fi
	_nw_guard_warn "refusing the destructive step: $NW_GUARD_COMMAND hold on failed"
	NW_GUARD_ACTION=take-failed
	NW_GUARD_RESULT=hold-failed
	return 1
}

# Release a hold this guard took, and only that hold: a sidecar naming another
# live PID is left alone.  Idempotent.  A failure prints the manual command.
nw_guard_release() {
	if [ "$NW_GUARD_INITIALIZED" -ne 1 ]; then
		return 0
	fi
	if [ "$NW_GUARD_MODE" = dry-run ]; then
		return 0
	fi
	if [ "$NW_GUARD_TAKEN" -ne 1 ]; then
		return 0
	fi
	_nw_guard_owner_pid=$(_nw_guard_owner_field 1)
	if [ -n "$_nw_guard_owner_pid" ] && [ "$_nw_guard_owner_pid" != "$$" ]; then
		_nw_guard_warn "not releasing $NW_GUARD_HOLD_FILE: it is held by PID $_nw_guard_owner_pid"
		NW_GUARD_ACTION=kept-foreign-hold
		NW_GUARD_RESULT=not-owner
		return 1
	fi
	_nw_guard_run_timed "$NW_GUARD_TIMEOUT" "$NW_GUARD_COMMAND" hold off >/dev/null 2>&1
	_nw_guard_rc=$?
	if [ "$_nw_guard_rc" -eq 0 ] || { [ "$_nw_guard_rc" -eq 124 ] && [ ! -e "$NW_GUARD_HOLD_FILE" ]; }; then
		# Success, or the timeout killed a release that had already removed
		# the hold; both leave no hold behind.
		rm -f "$NW_GUARD_OWNER_FILE"
		NW_GUARD_TAKEN=0
		NW_GUARD_RESUME_AT=$(_nw_guard_utc)
		NW_GUARD_RESUME_EPOCH=$(_nw_guard_epoch)
		NW_GUARD_ACTION=took-and-released
		NW_GUARD_RESULT=ok
		return 0
	fi
	if [ "$_nw_guard_rc" -eq 124 ]; then
		NW_GUARD_ACTION=took-release-timeout
		NW_GUARD_RESULT=release-timeout
		_nw_guard_warn "warning: $NW_GUARD_COMMAND hold off timed out after ${NW_GUARD_TIMEOUT}s; the hold state was left untouched"
	else
		NW_GUARD_ACTION=took-release-failed
		NW_GUARD_RESULT=release-failed
		_nw_guard_warn "warning: $NW_GUARD_COMMAND hold off failed; release the hold manually:"
	fi
	NW_GUARD_MANUAL_COMMAND="$NW_GUARD_COMMAND hold off"
	printf '  %s\n' "$NW_GUARD_MANUAL_COMMAND" >&2
	printf '  test ! -e %s   # verify it is gone\n' "$NW_GUARD_HOLD_FILE" >&2
	return 1
}

# Release and write the result JSON.  Safe to call more than once and from a
# trap; it never changes the caller's exit status.
nw_guard_cleanup() {
	if [ "$NW_GUARD_INITIALIZED" -ne 1 ]; then
		return 0
	fi
	if [ "$NW_GUARD_CLEANED" -eq 1 ]; then
		return 0
	fi
	NW_GUARD_CLEANED=1
	nw_guard_release
	_nw_guard_write_json
	return 0
}

_nw_guard_json_escape() {
	printf '%s' "$1" | tr '\t\r\n' '   ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

_nw_guard_json_string() {
	if [ -n "$1" ]; then
		printf '"%s"' "$(_nw_guard_json_escape "$1")"
	else
		printf 'null'
	fi
}

_nw_guard_json_bool() {
	if [ "$1" -eq 1 ] 2>/dev/null; then
		printf 'true'
	else
		printf 'false'
	fi
}

_nw_guard_json_num() {
	if [ -n "$1" ]; then
		printf '%s' "$1"
	else
		printf 'null'
	fi
}

_nw_guard_write_json() {
	[ -n "$NW_GUARD_RESULT_JSON" ] || return 0
	[ "$NW_GUARD_MODE" = apply ] || return 0

	_nw_guard_dir=$(dirname "$NW_GUARD_RESULT_JSON")
	if [ ! -d "$_nw_guard_dir" ]; then
		_nw_guard_warn "warning: $(_nw_guard_json_escape "$_nw_guard_dir") is not a directory; not writing $NW_GUARD_RESULT_JSON"
		return 0
	fi
	_nw_guard_tmp="$NW_GUARD_RESULT_JSON.tmp.$$"
	if ! printf '{\n  "service": "netwatchdog",\n  "command": %s,\n  "label": %s,\n  "mode": "apply",\n  "hold_file": %s,\n  "service_present": %s,\n  "prior_hold": %s,\n  "owner_pid": %s,\n  "timeout_seconds": %s,\n  "stale_reclaimed": %s,\n  "hold_at": %s,\n  "hold_epoch": %s,\n  "resume_at": %s,\n  "resume_epoch": %s,\n  "signal": %s,\n  "action": "%s",\n  "result": "%s",\n  "manual_command": %s\n}\n' \
		"$(_nw_guard_json_string "$NW_GUARD_COMMAND")" \
		"$(_nw_guard_json_string "$NW_GUARD_LABEL")" \
		"$(_nw_guard_json_string "$NW_GUARD_HOLD_FILE")" \
		"$(_nw_guard_json_bool "$NW_GUARD_SERVICE_PRESENT")" \
		"$(_nw_guard_json_bool "$NW_GUARD_PRIOR_HOLD")" \
		"$(_nw_guard_json_num "$NW_GUARD_OWNER_PID")" \
		"$(_nw_guard_json_num "$NW_GUARD_TIMEOUT")" \
		"$(_nw_guard_json_bool "$NW_GUARD_STALE_RECLAIMED")" \
		"$(_nw_guard_json_string "$NW_GUARD_HOLD_AT")" \
		"${NW_GUARD_HOLD_EPOCH:-null}" \
		"$(_nw_guard_json_string "$NW_GUARD_RESUME_AT")" \
		"${NW_GUARD_RESUME_EPOCH:-null}" \
		"$(_nw_guard_json_string "$NW_GUARD_SIGNAL")" \
		"$(_nw_guard_json_escape "$NW_GUARD_ACTION")" \
		"$(_nw_guard_json_escape "$NW_GUARD_RESULT")" \
		"$(_nw_guard_json_string "$NW_GUARD_MANUAL_COMMAND")" \
		>"$_nw_guard_tmp" 2>/dev/null; then
		_nw_guard_warn "warning: cannot write $NW_GUARD_RESULT_JSON"
		rm -f "$_nw_guard_tmp" 2>/dev/null
		return 0
	fi
	if ! mv "$_nw_guard_tmp" "$NW_GUARD_RESULT_JSON" 2>/dev/null; then
		_nw_guard_warn "warning: cannot replace $NW_GUARD_RESULT_JSON"
		rm -f "$_nw_guard_tmp" 2>/dev/null
	fi
	return 0
}

_nw_guard_on_exit() {
	nw_guard_cleanup
}

_nw_guard_on_signal() {
	_nw_guard_sig=$1
	NW_GUARD_SIGNAL=$_nw_guard_sig
	trap - 0 HUP INT TERM
	nw_guard_cleanup
	case $_nw_guard_sig in
	HUP) exit 129 ;;
	INT) exit 130 ;;
	TERM) exit 143 ;;
	*) exit 1 ;;
	esac
}
