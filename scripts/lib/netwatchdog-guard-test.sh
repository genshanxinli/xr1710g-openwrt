#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Self-tests for scripts/lib/netwatchdog-guard.sh.
#
#   sh scripts/lib/netwatchdog-guard-test.sh
#   SH='busybox sh' sh scripts/lib/netwatchdog-guard-test.sh
#
# A stub netwatchdog is placed first in PATH and all hold/result files live
# under a temporary directory, so the real /tmp/netwatchdog.hold is never
# read or written.  Requires no root and no board.

set -u

LIB=${LIB:-$(dirname -- "$0")/netwatchdog-guard.sh}
SH=${SH:-sh}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/nw-guard-test.XXXXXX") || {
	echo "cannot create a temporary directory" >&2
	exit 1
}
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

pass() {
	PASS=$((PASS + 1))
	printf 'ok %d - %s\n' "$((PASS + FAIL))" "$1"
}

fail() {
	FAIL=$((FAIL + 1))
	printf 'not ok %d - %s\n' "$((PASS + FAIL))" "$1"
}

assert_eq() {
	_label=$1
	_expected=$2
	_actual=$3
	if [ "$_expected" = "$_actual" ]; then
		pass "$_label"
	else
		fail "$_label (expected '$_expected', got '$_actual')"
	fi
}

assert_file() {
	if [ -f "$1" ]; then
		pass "$2"
	else
		fail "$2 (missing $1)"
	fi
}

assert_no_file() {
	if [ ! -e "$1" ]; then
		pass "$2"
	else
		fail "$2 (unexpected $1)"
	fi
}

assert_grep() {
	if grep -q -- "$1" "$2" 2>/dev/null; then
		pass "$3"
	else
		fail "$3 (pattern '$1' not found in $2)"
	fi
}

assert_no_grep() {
	if grep -q -- "$1" "$2" 2>/dev/null; then
		fail "$3 (pattern '$1' found in $2)"
	else
		pass "$3"
	fi
}

assert_json() {
	if ! command -v python3 >/dev/null 2>&1; then
		return 0
	fi
	if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null; then
		pass "$2"
	else
		fail "$2 ($1 is not valid JSON)"
	fi
}

run_shell() {
	# SH may be "busybox sh", hence the deliberate word splitting.
	# shellcheck disable=SC2086
	$SH "$@"
}

STUB=$TMP/bin
mkdir -p "$STUB"
cat >"$STUB/netwatchdog" <<'STUB_EOF'
#!/bin/sh
printf '%s %s\n' "$1" "$2" >>"${NW_STUB_LOG:?}"
case "$1 $2" in
"hold on")
	[ "${NW_STUB_HOLD_FAIL:-0}" = 1 ] && exit 1
	: >"${NW_STUB_HOLD_FILE:?}"
	exit 0
	;;
"hold off")
	[ "${NW_STUB_RELEASE_FAIL:-0}" = 1 ] && exit 1
	rm -f "${NW_STUB_HOLD_FILE:?}"
	exit 0
	;;
esac
exit 2
STUB_EOF
chmod +x "$STUB/netwatchdog"

# The consumer mirrors how an experiment script uses the library: argument
# parsing left the caller in apply or dry-run mode, then it takes the hold and
# performs its destructive work.  $4 selects a clean exit, a nonzero exit, or
# a signal; $5 overrides the netwatchdog command name.
write_consumer() {
	cat >"$1" <<'CONSUMER_EOF'
#!/bin/sh
set -eu
lib=$1
out=$2
mode=$3
case_kind=$4
cmd=${5:-netwatchdog}
. "$lib"
nw_guard_init "--$mode" --result-json "$out/guard.json" \
	--label "selftest" --hold-file "$out/hold" --command "$cmd"
nw_guard_take
printf '%s\n' "$NW_GUARD_ACTION" >"$out/action"
printf '%s\n' "$NW_GUARD_RESULT" >"$out/result"
case $case_kind in
none) ;;
exit*) exit "${case_kind#exit}" ;;
*) kill -"$case_kind" "$$" ; sleep 5 ;;
esac
exit 0
CONSUMER_EOF
}

run_case() {
	_out=$1
	_mode=$2
	_kind=$3
	_cmd=${4:-netwatchdog}
	mkdir -p "$_out"
	write_consumer "$_out/consumer.sh"
	PATH="$STUB:$PATH" NW_STUB_LOG="$_out/calls" NW_STUB_HOLD_FILE="$_out/hold" \
		run_shell "$_out/consumer.sh" "$LIB" "$_out" "$_mode" "$_kind" "$_cmd" \
		>"$_out/stdout" 2>"$_out/stderr"
	RC=$?
}

# --- dry run: no netwatchdog call and no files -----------------------------
run_case "$TMP/dry" dry-run none
assert_eq "dry run exits 0" 0 "$RC"
assert_eq "dry run action" skipped-dry-run "$(cat "$TMP/dry/action" 2>/dev/null)"
assert_no_file "$TMP/dry/calls" "dry run does not invoke netwatchdog"
assert_no_file "$TMP/dry/hold" "dry run does not create the hold file"
assert_no_file "$TMP/dry/guard.json" "dry run writes no result JSON"

# --- apply, normal exit ----------------------------------------------------
run_case "$TMP/apply" apply none
assert_eq "apply exits 0" 0 "$RC"
assert_eq "apply takes the hold" took "$(cat "$TMP/apply/action" 2>/dev/null)"
assert_eq "apply runs hold on once" 1 "$(grep -c '^hold on$' "$TMP/apply/calls" 2>/dev/null)"
assert_eq "apply runs hold off once" 1 "$(grep -c '^hold off$' "$TMP/apply/calls" 2>/dev/null)"
assert_no_file "$TMP/apply/hold" "apply releases the hold on exit"
assert_grep '"action": "took-and-released"' "$TMP/apply/guard.json" "apply records the release"
assert_grep '"hold_at": "20' "$TMP/apply/guard.json" "apply records the hold time"
assert_grep '"resume_at": "20' "$TMP/apply/guard.json" "apply records the resume time"
assert_json "$TMP/apply/guard.json" "apply result JSON is valid"

# --- apply, nonzero exit ---------------------------------------------------
run_case "$TMP/exit42" apply exit42
assert_eq "nonzero exit preserves the status" 42 "$RC"
assert_no_file "$TMP/exit42/hold" "nonzero exit releases the hold"
assert_grep '"action": "took-and-released"' "$TMP/exit42/guard.json" "nonzero exit records the release"

# --- apply, SIGTERM --------------------------------------------------------
run_case "$TMP/term" apply TERM
assert_eq "SIGTERM exits 143" 143 "$RC"
assert_no_file "$TMP/term/hold" "SIGTERM releases the hold"
assert_grep '"action": "took-and-released"' "$TMP/term/guard.json" "SIGTERM records the release"
assert_grep '"resume_at": "20' "$TMP/term/guard.json" "SIGTERM records the resume time"
assert_json "$TMP/term/guard.json" "SIGTERM result JSON is valid"

# --- apply, SIGINT ---------------------------------------------------------
run_case "$TMP/int" apply INT
assert_eq "SIGINT exits 130" 130 "$RC"
assert_no_file "$TMP/int/hold" "SIGINT releases the hold"
assert_grep '"action": "took-and-released"' "$TMP/int/guard.json" "SIGINT records the release"
assert_grep '"signal": "INT"' "$TMP/int/guard.json" "SIGINT records the signal"

# --- apply, SIGHUP ---------------------------------------------------------
run_case "$TMP/hup" apply HUP
assert_eq "SIGHUP exits 129" 129 "$RC"
assert_no_file "$TMP/hup/hold" "SIGHUP releases the hold"
assert_grep '"action": "took-and-released"' "$TMP/hup/guard.json" "SIGHUP records the release"
assert_grep '"signal": "HUP"' "$TMP/hup/guard.json" "SIGHUP records the signal"

# --- missing netwatchdog: warn only ---------------------------------------
run_case "$TMP/missing" apply none netwatchdog-does-not-exist
assert_eq "missing netwatchdog keeps the exit status" 0 "$RC"
assert_eq "missing netwatchdog action" missing "$(cat "$TMP/missing/action" 2>/dev/null)"
assert_eq "missing netwatchdog result" missing-service "$(cat "$TMP/missing/result" 2>/dev/null)"
assert_grep 'not found' "$TMP/missing/stderr" "missing netwatchdog is a warning"
assert_no_file "$TMP/missing/calls" "missing netwatchdog invokes nothing"
assert_no_file "$TMP/missing/hold" "missing netwatchdog creates no hold"
assert_grep '"service_present": false' "$TMP/missing/guard.json" "missing netwatchdog is recorded"

# --- hold on failure: warn only -------------------------------------------
# shellcheck disable=SC2034 # read by the stub netwatchdog
NW_STUB_HOLD_FAIL=1
export NW_STUB_HOLD_FAIL
run_case "$TMP/holdfail" apply none
unset NW_STUB_HOLD_FAIL
assert_eq "hold failure keeps the exit status" 0 "$RC"
assert_eq "hold failure action" take-failed "$(cat "$TMP/holdfail/action" 2>/dev/null)"
assert_eq "hold failure result" hold-failed "$(cat "$TMP/holdfail/result" 2>/dev/null)"
assert_grep 'hold on failed' "$TMP/holdfail/stderr" "hold failure is a warning"
assert_eq "hold failure does not run hold off" 0 "$(grep -c '^hold off$' "$TMP/holdfail/calls" 2>/dev/null)"
assert_grep '"result": "hold-failed"' "$TMP/holdfail/guard.json" "hold failure is recorded"

# --- hold off failure: manual command -------------------------------------
# shellcheck disable=SC2034 # read by the stub netwatchdog
NW_STUB_RELEASE_FAIL=1
export NW_STUB_RELEASE_FAIL
run_case "$TMP/relfail" apply none
unset NW_STUB_RELEASE_FAIL
assert_eq "release failure keeps the exit status" 0 "$RC"
assert_eq "release failure action" took "$(cat "$TMP/relfail/action" 2>/dev/null)"
assert_grep 'release the hold manually' "$TMP/relfail/stderr" "release failure prints the manual instruction"
assert_grep 'netwatchdog hold off' "$TMP/relfail/stderr" "release failure prints the manual command"
assert_grep 'test ! -e .*hold' "$TMP/relfail/stderr" "release failure prints the verification command"
assert_file "$TMP/relfail/hold" "release failure leaves the hold for the manual fix"
assert_grep '"action": "took-release-failed"' "$TMP/relfail/guard.json" "release failure is recorded"
assert_grep '"manual_command": "netwatchdog hold off"' "$TMP/relfail/guard.json" "manual command is recorded"

# --- pre-existing hold: left active ---------------------------------------
mkdir -p "$TMP/prior"
: >"$TMP/prior/hold"
run_case "$TMP/prior" apply none
assert_eq "prior hold keeps the exit status" 0 "$RC"
assert_eq "prior hold action" unchanged "$(cat "$TMP/prior/action" 2>/dev/null)"
assert_no_file "$TMP/prior/calls" "prior hold is not taken again or released"
assert_file "$TMP/prior/hold" "prior hold is left active"
assert_grep '"prior_hold": true' "$TMP/prior/guard.json" "prior hold is recorded"
assert_grep '"hold_at": null' "$TMP/prior/guard.json" "prior hold records no hold time"
assert_grep '"resume_at": null' "$TMP/prior/guard.json" "prior hold records no resume time"

# --- JSON escaping ---------------------------------------------------------
mkdir -p "$TMP/json"
cat >"$TMP/json/consumer.sh" <<'JSON_EOF'
#!/bin/sh
set -eu
lib=$1
out=$2
. "$lib"
nw_guard_init --apply --result-json "$out/guard.json" \
	--label 'quote"back\slash' --hold-file "$out/hold"
nw_guard_take
exit 0
JSON_EOF
PATH="$STUB:$PATH" NW_STUB_LOG="$TMP/json/calls" NW_STUB_HOLD_FILE="$TMP/json/hold" \
	run_shell "$TMP/json/consumer.sh" "$LIB" "$TMP/json" >/dev/null 2>&1
RC=$?
assert_eq "quoted label exits 0" 0 "$RC"
assert_json "$TMP/json/guard.json" "quoted label result JSON is valid"
assert_grep 'quote\\"back\\\\slash' "$TMP/json/guard.json" "quoted label is escaped"

# --- take/release are idempotent ------------------------------------------
mkdir -p "$TMP/twice"
cat >"$TMP/twice/consumer.sh" <<'TWICE_EOF'
#!/bin/sh
set -eu
lib=$1
out=$2
. "$lib"
nw_guard_init --apply --result-json "$out/guard.json" \
	--label selftest --hold-file "$out/hold"
nw_guard_take
nw_guard_take
nw_guard_release
nw_guard_release
exit 0
TWICE_EOF
PATH="$STUB:$PATH" NW_STUB_LOG="$TMP/twice/calls" NW_STUB_HOLD_FILE="$TMP/twice/hold" \
	run_shell "$TMP/twice/consumer.sh" "$LIB" "$TMP/twice" >"$TMP/twice/stdout" 2>"$TMP/twice/stderr"
RC=$?
assert_eq "idempotent calls exit 0" 0 "$RC"
assert_eq "idempotent hold on" 1 "$(grep -c '^hold on$' "$TMP/twice/calls" 2>/dev/null)"
assert_eq "idempotent hold off" 1 "$(grep -c '^hold off$' "$TMP/twice/calls" 2>/dev/null)"
assert_json "$TMP/twice/guard.json" "idempotent result JSON is valid"

# --- summary ---------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
