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
	[ -n "${NW_STUB_HOLD_DELAY:-}" ] && sleep "$NW_STUB_HOLD_DELAY"
	: >"${NW_STUB_HOLD_FILE:?}"
	exit 0
	;;
"hold off")
	[ "${NW_STUB_RELEASE_FAIL:-0}" = 1 ] && exit 1
	[ -n "${NW_STUB_RELEASE_DELAY:-}" ] && sleep "$NW_STUB_RELEASE_DELAY"
	rm -f "${NW_STUB_HOLD_FILE:?}"
	exit 0
	;;
esac
exit 2
STUB_EOF
chmod +x "$STUB/netwatchdog"

# The consumer mirrors how an experiment script uses the library: argument
# parsing left the caller in apply or dry-run mode, then it takes the hold and
# performs its destructive work.  $4 selects a clean exit, a nonzero exit, a
# signal, a slow run (to keep the hold while a second consumer competes), or a
# foreign owner rewrite.  $5 overrides the netwatchdog command name; the rest
# are extra nw_guard_init arguments (--timeout, --stale-minutes).
write_consumer() {
	cat >"$1" <<'CONSUMER_EOF'
#!/bin/sh
set -u
lib=$1
out=$2
mode=$3
case_kind=$4
cmd=$5
shift 5
. "$lib"
holdfile=${NW_CONSUMER_HOLD:-$out/hold}
nw_guard_init "--$mode" --result-json "$out/guard.json" \
	--label "selftest" --hold-file "$holdfile" --command "$cmd" "$@"
nw_guard_take
printf '%s\n' "$?" >"$out/take_rc"
printf '%s\n' "$NW_GUARD_ACTION" >"$out/action"
printf '%s\n' "$NW_GUARD_RESULT" >"$out/result"
case $case_kind in
none) ;;
sleep:*) sleep "${case_kind#sleep:}" ;;
exit*) exit "${case_kind#exit}" ;;
foreign) printf '1 %s\n' "$(date +%s)" >"$out/hold.owner" ;;
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
	if [ "$#" -ge 4 ]; then
		shift 4
	else
		shift 3
	fi
	mkdir -p "$_out"
	write_consumer "$_out/consumer.sh"
	PATH="$STUB:$PATH" NW_STUB_LOG="$_out/calls" NW_STUB_HOLD_FILE="$_out/hold" \
		run_shell "$_out/consumer.sh" "$LIB" "$_out" "$_mode" "$_kind" "$_cmd" "$@" \
		>"$_out/stdout" 2>"$_out/stderr"
	RC=$?
}

take_rc() {
	cat "$1/take_rc" 2>/dev/null
}

call_count() {
	_n=$(grep -c -- "$2" "$1" 2>/dev/null) || _n=0
	printf '%s\n' "${_n:-0}"
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
assert_eq "apply take returns 0" 0 "$(take_rc "$TMP/apply")"
assert_eq "apply runs hold on once" 1 "$(call_count "$TMP/apply/calls" '^hold on$')"
assert_eq "apply runs hold off once" 1 "$(call_count "$TMP/apply/calls" '^hold off$')"
assert_no_file "$TMP/apply/hold" "apply releases the hold on exit"
assert_no_file "$TMP/apply/hold.owner" "apply removes the owner record on release"
assert_grep '"action": "took-and-released"' "$TMP/apply/guard.json" "apply records the release"
assert_grep '"hold_at": "20' "$TMP/apply/guard.json" "apply records the hold time"
assert_grep '"resume_at": "20' "$TMP/apply/guard.json" "apply records the resume time"
assert_grep '"owner_pid": ' "$TMP/apply/guard.json" "apply records the owner PID"
assert_grep '"stale_reclaimed": false' "$TMP/apply/guard.json" "apply records no stale reclaim"
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

# --- missing netwatchdog: fail closed -------------------------------------
run_case "$TMP/missing" apply none netwatchdog-does-not-exist
assert_eq "missing netwatchdog keeps the exit status" 0 "$RC"
assert_eq "missing netwatchdog take fails" 1 "$(take_rc "$TMP/missing")"
assert_eq "missing netwatchdog action" refused "$(cat "$TMP/missing/action" 2>/dev/null)"
assert_eq "missing netwatchdog result" missing-service "$(cat "$TMP/missing/result" 2>/dev/null)"
assert_grep 'refusing the destructive step' "$TMP/missing/stderr" "missing netwatchdog refuses the destructive step"
assert_grep 'NWD_ALLOW_NO_SERVICE=1' "$TMP/missing/stderr" "missing netwatchdog names the override"
assert_no_file "$TMP/missing/calls" "missing netwatchdog invokes nothing"
assert_no_file "$TMP/missing/hold" "missing netwatchdog creates no hold"
assert_grep '"service_present": false' "$TMP/missing/guard.json" "missing netwatchdog is recorded"

# --- missing netwatchdog with the explicit override: warn and continue -----
# shellcheck disable=SC2034 # read by the stub netwatchdog
NWD_ALLOW_NO_SERVICE=1
export NWD_ALLOW_NO_SERVICE
run_case "$TMP/no-service-allowed" apply none netwatchdog-does-not-exist
unset NWD_ALLOW_NO_SERVICE
assert_eq "allowed missing netwatchdog exits 0" 0 "$RC"
assert_eq "allowed missing netwatchdog take passes" 0 "$(take_rc "$TMP/no-service-allowed")"
assert_eq "allowed missing netwatchdog action" missing-allowed "$(cat "$TMP/no-service-allowed/action" 2>/dev/null)"
assert_grep 'NWD_ALLOW_NO_SERVICE=1' "$TMP/no-service-allowed/stderr" "allowed missing netwatchdog warns"
assert_no_file "$TMP/no-service-allowed/hold" "allowed missing netwatchdog creates no hold"

# --- hold on failure: fail closed -----------------------------------------
# shellcheck disable=SC2034 # read by the stub netwatchdog
NW_STUB_HOLD_FAIL=1
export NW_STUB_HOLD_FAIL
run_case "$TMP/holdfail" apply none
unset NW_STUB_HOLD_FAIL
assert_eq "hold failure keeps the exit status" 0 "$RC"
assert_eq "hold failure take fails" 1 "$(take_rc "$TMP/holdfail")"
assert_eq "hold failure action" take-failed "$(cat "$TMP/holdfail/action" 2>/dev/null)"
assert_eq "hold failure result" hold-failed "$(cat "$TMP/holdfail/result" 2>/dev/null)"
assert_grep 'refusing the destructive step' "$TMP/holdfail/stderr" "hold failure refuses the destructive step"
assert_eq "hold failure does not run hold off" 0 "$(call_count "$TMP/holdfail/calls" '^hold off$')"
assert_grep '"result": "hold-failed"' "$TMP/holdfail/guard.json" "hold failure is recorded"

# --- hold on timeout: nonzero, no hold, state untouched --------------------
# shellcheck disable=SC2034 # read by the stub netwatchdog
NW_STUB_HOLD_DELAY=5
export NW_STUB_HOLD_DELAY
run_case "$TMP/take-timeout" apply none netwatchdog --timeout 2
unset NW_STUB_HOLD_DELAY
assert_eq "hold timeout keeps the exit status" 0 "$RC"
assert_eq "hold timeout take fails" 1 "$(take_rc "$TMP/take-timeout")"
assert_eq "hold timeout action" timeout "$(cat "$TMP/take-timeout/action" 2>/dev/null)"
assert_eq "hold timeout result" hold-timeout "$(cat "$TMP/take-timeout/result" 2>/dev/null)"
assert_grep 'hold on timed out after 2s' "$TMP/take-timeout/stderr" "hold timeout is reported"
assert_no_file "$TMP/take-timeout/hold" "hold timeout writes no hold"
assert_no_file "$TMP/take-timeout/hold.owner" "hold timeout writes no owner record"
assert_eq "hold timeout runs hold on once" 1 "$(call_count "$TMP/take-timeout/calls" '^hold on$')"
assert_eq "hold timeout never runs hold off" 0 "$(call_count "$TMP/take-timeout/calls" '^hold off$')"
assert_grep '"result": "hold-timeout"' "$TMP/take-timeout/guard.json" "hold timeout is recorded"

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

# --- hold off timeout: nonzero, hold left in place ------------------------
# shellcheck disable=SC2034 # read by the stub netwatchdog
NW_STUB_RELEASE_DELAY=5
export NW_STUB_RELEASE_DELAY
run_case "$TMP/rel-timeout" apply none netwatchdog --timeout 2
unset NW_STUB_RELEASE_DELAY
assert_eq "release timeout keeps the exit status" 0 "$RC"
assert_file "$TMP/rel-timeout/hold" "release timeout leaves the hold active"
assert_grep 'hold off timed out after 2s' "$TMP/rel-timeout/stderr" "release timeout is reported"
assert_grep '"action": "took-release-timeout"' "$TMP/rel-timeout/guard.json" "release timeout is recorded"
assert_grep '"result": "release-timeout"' "$TMP/rel-timeout/guard.json" "release timeout result is recorded"

# --- pre-existing hold without an owner record: left active ---------------
mkdir -p "$TMP/prior"
: >"$TMP/prior/hold"
run_case "$TMP/prior" apply none
assert_eq "prior hold keeps the exit status" 0 "$RC"
assert_eq "prior hold take passes" 0 "$(take_rc "$TMP/prior")"
assert_eq "prior hold action" unchanged "$(cat "$TMP/prior/action" 2>/dev/null)"
assert_no_file "$TMP/prior/calls" "prior hold is not taken again or released"
assert_file "$TMP/prior/hold" "prior hold is left active"
assert_grep '"prior_hold": true' "$TMP/prior/guard.json" "prior hold is recorded"
assert_grep '"hold_at": null' "$TMP/prior/guard.json" "prior hold records no hold time"
assert_grep '"resume_at": null' "$TMP/prior/guard.json" "prior hold records no resume time"

# --- live foreign holder: busy, never stolen ------------------------------
mkdir -p "$TMP/busy-run"
sleep 60 &
LIVE_PID=$!
printf '%s %s\n' "$LIVE_PID" "$(date +%s)" >"$TMP/busy-run/hold.owner"
: >"$TMP/busy-run/hold"
run_case "$TMP/busy-run" apply none
assert_eq "busy take fails" 1 "$(take_rc "$TMP/busy-run")"
assert_eq "busy action" denied-busy "$(cat "$TMP/busy-run/action" 2>/dev/null)"
assert_eq "busy result" busy "$(cat "$TMP/busy-run/result" 2>/dev/null)"
assert_grep "held by live PID $LIVE_PID" "$TMP/busy-run/stderr" "busy holder is named"
assert_eq "busy never runs hold on" 0 "$(call_count "$TMP/busy-run/calls" '^hold on$')"
assert_file "$TMP/busy-run/hold" "busy leaves the long holder's hold alone"
kill "$LIVE_PID" 2>/dev/null
wait "$LIVE_PID" 2>/dev/null

# --- two concurrent holders: the waiter fails, the holder keeps the lock --
mkdir -p "$TMP/conc"
write_consumer "$TMP/conc/consumer.sh"
PATH="$STUB:$PATH" NW_STUB_LOG="$TMP/conc/calls" NW_STUB_HOLD_FILE="$TMP/conc/hold" \
	run_shell "$TMP/conc/consumer.sh" "$LIB" "$TMP/conc" apply "sleep:5" netwatchdog \
	>"$TMP/conc/stdout" 2>"$TMP/conc/stderr" &
HOLDER=$!
_i=0
while [ ! -f "$TMP/conc/hold" ] && [ "$_i" -lt 50 ]; do
	sleep 0.1
	_i=$((_i + 1))
done
assert_file "$TMP/conc/hold" "first holder took the hold"
mkdir -p "$TMP/conc2"
write_consumer "$TMP/conc2/consumer.sh"
PATH="$STUB:$PATH" NW_STUB_LOG="$TMP/conc2/calls" NW_STUB_HOLD_FILE="$TMP/conc/hold" \
	NW_CONSUMER_HOLD="$TMP/conc/hold" \
	run_shell "$TMP/conc2/consumer.sh" "$LIB" "$TMP/conc2" apply none netwatchdog \
	>"$TMP/conc2/stdout" 2>"$TMP/conc2/stderr"
RC=$?
assert_eq "second holder take fails" 1 "$(take_rc "$TMP/conc2")"
assert_eq "second holder action" denied-busy "$(cat "$TMP/conc2/action" 2>/dev/null)"
assert_file "$TMP/conc/hold" "second holder does not steal the hold"
assert_eq "second holder never runs hold off" 0 "$(call_count "$TMP/conc2/calls" '^hold off$')"
wait "$HOLDER" 2>/dev/null
assert_no_file "$TMP/conc/hold" "the long holder releases its own hold on exit"

# --- stale hold: dead owner PID is reclaimed ------------------------------
mkdir -p "$TMP/stale-dead-run"
sh -c 'exit 0' &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null
printf '%s %s\n' "$DEAD_PID" "$(date +%s)" >"$TMP/stale-dead-run/hold.owner"
: >"$TMP/stale-dead-run/hold"
run_case "$TMP/stale-dead-run" apply none
assert_eq "dead-owner take passes" 0 "$(take_rc "$TMP/stale-dead-run")"
assert_eq "dead-owner action" took "$(cat "$TMP/stale-dead-run/action" 2>/dev/null)"
assert_grep "reclaiming stale netwatchdog hold (owner $DEAD_PID" "$TMP/stale-dead-run/stderr" "dead owner is reported as stale"
assert_grep '"stale_reclaimed": true' "$TMP/stale-dead-run/guard.json" "dead-owner reclaim is recorded"
assert_eq "dead-owner runs hold on once" 1 "$(call_count "$TMP/stale-dead-run/calls" '^hold on$')"

# --- stale hold: live owner older than --stale-minutes is reclaimed -------
mkdir -p "$TMP/stale-old-run"
sleep 60 &
OLD_PID=$!
printf '%s %s\n' "$OLD_PID" "$(( $(date +%s) - 7200 ))" >"$TMP/stale-old-run/hold.owner"
: >"$TMP/stale-old-run/hold"
run_case "$TMP/stale-old-run" apply none netwatchdog --stale-minutes 60
assert_eq "old-owner take passes" 0 "$(take_rc "$TMP/stale-old-run")"
assert_grep "reclaiming stale netwatchdog hold" "$TMP/stale-old-run/stderr" "old owner is reported as stale"
assert_grep '"stale_reclaimed": true' "$TMP/stale-old-run/guard.json" "old-owner reclaim is recorded"
kill "$OLD_PID" 2>/dev/null
wait "$OLD_PID" 2>/dev/null

# --- release refuses a foreign owner record -------------------------------
run_case "$TMP/foreign" apply foreign
assert_eq "foreign-owner exit 0" 0 "$RC"
assert_grep '"action": "kept-foreign-hold"' "$TMP/foreign/guard.json" "foreign owner is not released"
assert_grep '"result": "not-owner"' "$TMP/foreign/guard.json" "foreign owner result is recorded"
assert_file "$TMP/foreign/hold" "foreign-owner hold is left active"
assert_eq "foreign-owner does not run hold off" 0 "$(call_count "$TMP/foreign/calls" '^hold off$')"

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
assert_eq "idempotent hold on" 1 "$(call_count "$TMP/twice/calls" '^hold on$')"
assert_eq "idempotent hold off" 1 "$(call_count "$TMP/twice/calls" '^hold off$')"
assert_json "$TMP/twice/guard.json" "idempotent result JSON is valid"

# --- the adopter contract: a caller that checks the status stops -----------
# The library cannot abort a shell that ignores nw_guard_take, so the contract
# is "check the status and refuse".  This consumer mirrors the seven scripts.
mkdir -p "$TMP/enforce"
cat >"$TMP/enforce/consumer.sh" <<'ENFORCE_EOF'
#!/bin/sh
set -u
lib=$1
out=$2
cmd=$3
# shellcheck source=/dev/null
. "$lib"
nw_guard_init --apply --no-trap --hold-file "$out/hold" --command "$cmd"
nw_guard_take || {
	printf 'refused\n' >"$out/refused"
	exit 1
}
printf 'ran\n' >"$out/ran"
exit 0
ENFORCE_EOF
PATH="$STUB:$PATH" NW_STUB_LOG="$TMP/enforce/calls" NW_STUB_HOLD_FILE="$TMP/enforce/hold" \
	run_shell "$TMP/enforce/consumer.sh" "$LIB" "$TMP/enforce" netwatchdog-does-not-exist \
	>"$TMP/enforce/stdout" 2>"$TMP/enforce/stderr"
RC=$?
assert_eq "adopter refuses when the service is missing" 1 "$RC"
assert_file "$TMP/enforce/refused" "adopter records the refusal"
assert_no_file "$TMP/enforce/ran" "adopter never reaches the destructive step"
assert_no_file "$TMP/enforce/hold" "adopter writes no hold"
assert_grep 'refusing the destructive step' "$TMP/enforce/stderr" \
	"adopter sees why it stopped"

# --- adoption: every destructive experiment script uses the guard ---------
# A guard nobody calls protects nothing.  These are the seven scripts that
# bounce radios, commit wireless config or reboot the board.
TOP=$(cd "$(dirname -- "$0")/.." && pwd) || TOP=
for _adopter in \
	npu-fw-ab.sh 6g-only.sh 6g-clear-air.sh 6g-rx.sh ab-80-160.sh edca-6g-ab.sh mlo-2link.sh
do
	_af=$TOP/wireless/$_adopter
	assert_file "$_af" "$_adopter exists"
	assert_grep 'netwatchdog-guard\.sh' "$_af" "$_adopter sources the guard"
	assert_grep 'nw_guard_take ||' "$_af" "$_adopter checks the take status"
	assert_grep 'nw_guard_cleanup' "$_af" "$_adopter releases the hold from its own trap"
	assert_grep 'no-trap' "$_af" "$_adopter keeps its own trap"
done

# --- summary ---------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
