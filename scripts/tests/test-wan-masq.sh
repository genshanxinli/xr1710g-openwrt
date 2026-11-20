#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Offline behaviour tests for wan-masq:
#
#   target/linux/airoha/an7581/base-files/usr/sbin/wan-masq
#
# The script is a human-invoked switch, so there is no hotplug event to
# replay: every case here is one command line, run exactly as a person would
# run it, with uci/ubus/jsonfilter/the firewall init script replaced by stubs.
# The uci stub keeps a real key/value store, so "run on, then run on again" is
# an actual state machine and not just a log assertion.
#
# Usage: scripts/tests/test-wan-masq.sh
# Exit status is 0 when every case passes, 1 on the first failure.

set -u

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
MASQ="$REPO_ROOT/target/linux/airoha/an7581/base-files/usr/sbin/wan-masq"
BASE_FILES="$REPO_ROOT/target/linux/airoha/an7581/base-files"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

[ -f "$MASQ" ] || fail "$MASQ is missing"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

STUBS="$WORK/stubs"
mkdir -p "$STUBS"

# --- stubs ------------------------------------------------------------------

# uci: a two-column store, "key<TAB>value".  Sections are entries whose value
# is the section type, e.g. "firewall.@zone[1]<TAB>zone", which is what the
# real "uci get <section>" returns.  Every mutating call is appended to
# $FAKE_UCI_WRITE so a case can assert the exact write set.
cat >"$STUBS/uci" <<'STUB'
#!/bin/sh
[ "${1:-}" = -q ] && shift
cmd=${1:-}; shift
store=${FAKE_UCI_STORE:?}
get() {
	awk -v k="$1" 'index($0, k "\t") == 1 { v = substr($0, length(k) + 2); f = 1; exit }
		END { if (!f) exit 1; print v }' "$store"
}
case "$cmd" in
get)
	get "${1:-}"
	;;
set)
	k=${1%%=*}; v=${1#*=}
	printf 'set %s=%s\n' "$k" "$v" >>"$FAKE_UCI_WRITE"
	awk -v k="$k" -v v="$v" 'index($0, k "\t") == 1 { print k "\t" v; d = 1; next }
		{ print } END { if (!d) print k "\t" v }' "$store" >"$store.n" && mv "$store.n" "$store"
	;;
delete)
	printf 'delete %s\n' "${1:-}" >>"$FAKE_UCI_WRITE"
	awk -v k="${1:-}" 'index($0, k "\t") == 1 { next } { print }' "$store" >"$store.n" &&
		mv "$store.n" "$store"
	;;
commit)
	printf 'commit %s\n' "${1:-}" >>"$FAKE_UCI_WRITE"
	;;
*)
	exit 1
	;;
esac
STUB

cat >"$STUBS/ubus" <<'STUB'
#!/bin/sh
[ -n "${FAKE_UBUS_EMPTY:-}" ] && exit 0
printf '{"up":true,"proto":"%s","device":"wan"}\n' "${FAKE_PROTO:-}"
STUB

cat >"$STUBS/jsonfilter" <<'STUB'
#!/bin/sh
expr=""
while [ $# -gt 0 ]; do
	case "$1" in
	-e) expr=$2; shift 2 ;;
	*) shift ;;
	esac
done
exec python3 -c '
import json, sys
expr = sys.argv[1]
data = sys.stdin.read()
if not data.strip():
	sys.exit(0)
try:
	doc = json.loads(data)
except ValueError:
	sys.exit(0)
key = expr
for prefix in ("@.", "@"):
	if key.startswith(prefix):
		key = key[len(prefix):]
		break
value = doc.get(key) if isinstance(doc, dict) else None
if isinstance(value, str):
	print(value)
' "$expr"
STUB

cat >"$STUBS/fw-init" <<'STUB'
#!/bin/sh
printf 'reload %s\n' "$*" >>"$FAKE_LOG"
exit "${FAKE_FW_RELOAD_RC:-0}"
STUB

chmod +x "$STUBS"/*

# --- helpers ----------------------------------------------------------------

# Stock zone layout: lan is @zone[0] with no masq, wan is @zone[1].
stock_store() {
	cat >"$FAKE_UCI_STORE" <<'EOT'
firewall.@zone[0]	zone
firewall.@zone[0].name	lan
firewall.@zone[0].network	lan
firewall.@zone[0].input	ACCEPT
firewall.@zone[1]	zone
firewall.@zone[1].name	wan
firewall.@zone[1].network	wan wan6
firewall.@zone[1].input	REJECT
firewall.@zone[1].masq	1
network.wan	interface
network.wan.proto	pppoe
EOT
}

reset_case() {
	export FAKE_UCI_STORE="$WORK/store"
	export FAKE_UCI_WRITE="$WORK/uci-write"
	export FAKE_LOG="$WORK/log"
	export WM_FW_CONF="$WORK/firewall"
	export WM_LOCK="$WORK/lock/wan-masq.lock"
	export WM_FW_INIT="$STUBS/fw-init"
	: >"$FAKE_UCI_WRITE"
	: >"$FAKE_LOG"
	rm -f "$WM_FW_CONF.bak-wan-masq" "$WM_LOCK"
	stock_store
	printf 'config zone\n\toption name wan\n\toption masq 1\n' >"$WM_FW_CONF"
	cp "$WM_FW_CONF" "$WORK/firewall.orig"
	export PATH="$STUBS:$PATH"
	FAKE_PROTO=""
	FAKE_UBUS_EMPTY=""
	FAKE_FW_RELOAD_RC=0
	export FAKE_PROTO FAKE_UBUS_EMPTY FAKE_FW_RELOAD_RC
}

# run <args...>: captures stdout/stderr and the exit status in RC.
run() {
	WM_RC=0
	WM_OUT=$(sh "$MASQ" "$@" 2>"$WORK/stderr") || WM_RC=$?
	WM_ERR=$(cat "$WORK/stderr")
}

begin() {
	CASE=$1
	printf 'ok   %s\n' "$CASE"
}

expect_rc() {
	[ "$WM_RC" = "$1" ] || fail "$CASE: exit $WM_RC, expected $1 (stderr: $WM_ERR)"
}

expect_out() {
	case "$WM_OUT" in
	*"$1"*) ;;
	*) fail "$CASE: stdout missing '$1'; got: $(printf '%s' "$WM_OUT" | tr '\n' ';')" ;;
	esac
}

expect_err() {
	case "$WM_ERR" in
	*"$1"*) ;;
	*) fail "$CASE: stderr missing '$1'; got: $(printf '%s' "$WM_ERR" | tr '\n' ';')" ;;
	esac
}

expect_writes() {
	[ "$(cat "$FAKE_UCI_WRITE")" = "$1" ] ||
		fail "$CASE: uci writes were '$(tr '\n' ';' <"$FAKE_UCI_WRITE")', expected '$1'"
}

expect_no_writes() {
	[ ! -s "$FAKE_UCI_WRITE" ] ||
		fail "$CASE: unexpected uci write: $(tr '\n' ';' <"$FAKE_UCI_WRITE")"
}

expect_untouched_config() {
	cmp -s "$WM_FW_CONF" "$WORK/firewall.orig" ||
		fail "$CASE: $WM_FW_CONF was rewritten"
	[ ! -e "$WM_FW_CONF.bak-wan-masq" ] || fail "$CASE: a backup was made although nothing changed"
}

# --- status -----------------------------------------------------------------

begin status-stock
reset_case
FAKE_PROTO=dhcp
run status
expect_rc 0
expect_out 'zone:  firewall.@zone[1] (wan)'
expect_out 'proto: dhcp'
expect_out 'masq:  1'
expect_no_writes

begin status-unset
reset_case
sed -i '/firewall.@zone\[1\].masq/d' "$FAKE_UCI_STORE"
FAKE_PROTO=pppoe
run status
expect_rc 0
expect_out 'masq:  unset'
expect_no_writes

begin status-falls-back-to-uci-proto
reset_case
# No ubus status at all (interface not configured): the configured proto is
# still the answer.
FAKE_UBUS_EMPTY=1
run status
expect_rc 0
expect_out 'proto: pppoe'

begin status-no-wan-zone
reset_case
sed -i '/firewall.@zone\[1\]/d' "$FAKE_UCI_STORE"
run status
expect_rc 1
expect_err "no zone named 'wan'"

# --- on ---------------------------------------------------------------------

begin on-pppoe-sets-once
reset_case
sed -i '/firewall.@zone\[1\].masq/d' "$FAKE_UCI_STORE"
FAKE_PROTO=pppoe
run on
expect_rc 0
expect_writes 'set firewall.@zone[1].masq=1
commit firewall'
expect_out 'masq unset -> 1 on zone wan'
[ -f "$WM_FW_CONF.bak-wan-masq" ] || fail "$CASE: no backup was written"
cmp -s "$WM_FW_CONF.bak-wan-masq" "$WORK/firewall.orig" ||
	fail "$CASE: backup is not the pre-change config"

begin on-is-idempotent
reset_case
sed -i '/firewall.@zone\[1\].masq/d' "$FAKE_UCI_STORE"
FAKE_PROTO=pppoe
run on
: >"$FAKE_UCI_WRITE"
FAKE_PROTO=pppoe
run on
expect_rc 0
expect_no_writes
expect_out 'already 1 on zone wan'
# The backup from the first run must not be overwritten by a later write:
# it is the pre-first-touch config, so it still has no "masq 1" line of ours.
cmp -s "$WM_FW_CONF.bak-wan-masq" "$WORK/firewall.orig" ||
	fail "$CASE: the backup was replaced on a no-op run"

begin on-stock-config-is-noop
reset_case
# The shipped firewall.config already carries "option masq 1" for wan
# (package/network/config/firewall/files/firewall.config:23), so on a stock box
# "on" changes nothing at all.
FAKE_PROTO=pppoe
run on
expect_rc 0
expect_no_writes
expect_out 'already 1 on zone wan'
expect_untouched_config

begin on-refuses-dhcp
reset_case
sed -i '/firewall.@zone\[1\].masq/d' "$FAKE_UCI_STORE"
FAKE_PROTO=dhcp
run on
expect_rc 3
expect_no_writes
expect_err "proto is 'dhcp', not pppoe"

begin on-respects-explicit-zero
reset_case
sed -i 's/^firewall\.@zone\[1\]\.masq\t1$/firewall.@zone[1].masq\t0/' "$FAKE_UCI_STORE"
FAKE_PROTO=pppoe
run on
expect_rc 4
expect_no_writes
expect_err 'explicit masq 0; --force to override'

begin on-force-overrides-explicit-zero
reset_case
sed -i 's/^firewall\.@zone\[1\]\.masq\t1$/firewall.@zone[1].masq\t0/' "$FAKE_UCI_STORE"
FAKE_PROTO=pppoe
run on --force
expect_rc 0
expect_writes 'set firewall.@zone[1].masq=1
commit firewall'

begin on-targets-the-zone-by-name
reset_case
# wan is not @zone[1] here.  The zone is found by name, so the write must land
# on @zone[2] and nowhere else - the case that catches index guessing.
cat >"$FAKE_UCI_STORE" <<'EOT'
firewall.@zone[0]	zone
firewall.@zone[0].name	lan
firewall.@zone[1]	zone
firewall.@zone[1].name	guest
firewall.@zone[1].masq	0
firewall.@zone[2]	zone
firewall.@zone[2].name	wan
network.wan.proto	pppoe
EOT
FAKE_PROTO=pppoe
run on
expect_rc 0
expect_writes 'set firewall.@zone[2].masq=1
commit firewall'

# --- off --------------------------------------------------------------------

begin off-deletes-the-option
reset_case
FAKE_PROTO=pppoe
run off
expect_rc 0
expect_writes 'delete firewall.@zone[1].masq
commit firewall'
expect_out 'masq 1 -> deleted on zone wan'
[ -f "$WM_FW_CONF.bak-wan-masq" ] || fail "$CASE: no backup was written"

begin off-is-idempotent
reset_case
sed -i '/firewall.@zone\[1\].masq/d' "$FAKE_UCI_STORE"
FAKE_PROTO=pppoe
run off
expect_rc 0
expect_no_writes
expect_out 'already off on zone wan'
expect_untouched_config

begin off-treats-explicit-zero-as-off
reset_case
sed -i 's/^firewall\.@zone\[1\]\.masq\t1$/firewall.@zone[1].masq\t0/' "$FAKE_UCI_STORE"
FAKE_PROTO=pppoe
run off
expect_rc 0
expect_no_writes

# --- reload -----------------------------------------------------------------

begin reload-ok
reset_case
sed -i '/firewall.@zone\[1\].masq/d' "$FAKE_UCI_STORE"
FAKE_PROTO=pppoe
run on --reload
expect_rc 0
expect_out 'firewall reloaded'
grep -q '^reload reload$' "$FAKE_LOG" || fail "$CASE: the init script was not asked to reload"

begin reload-failure-is-reported
reset_case
sed -i '/firewall.@zone\[1\].masq/d' "$FAKE_UCI_STORE"
FAKE_PROTO=pppoe
FAKE_FW_RELOAD_RC=1
run on --reload
expect_rc 6
expect_err 'reload failed: the uci change is committed but not live'
# The write did happen and is not rolled back - saying so is the point.
expect_writes 'set firewall.@zone[1].masq=1
commit firewall'

begin no-reload-by-default
reset_case
sed -i '/firewall.@zone\[1\].masq/d' "$FAKE_UCI_STORE"
FAKE_PROTO=pppoe
run on
expect_rc 0
[ ! -s "$FAKE_LOG" ] || fail "$CASE: the firewall was reloaded without --reload"

# --- the script has no automatic caller -------------------------------------

begin no-auto-invocation
# The whole design premise: nothing in the boot path, hotplug or uci-defaults
# may call this script, so masquerade can only move when a human moves it.
auto=$(grep -rl 'wan-masq' "$BASE_FILES/etc" \
	"$REPO_ROOT/package/network/config/firewall/files" 2>/dev/null)
[ -z "$auto" ] || fail "$CASE: an automatic caller exists: $auto"

begin usage
reset_case
run
expect_rc 2
expect_err 'usage: wan-masq status'
run bogus
expect_rc 2

printf 'all wan-masq cases passed\n'
