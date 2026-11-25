#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Offline behaviour tests for the two WAN iface hotplug scripts:
#
#   target/linux/airoha/an7581/base-files/etc/hotplug.d/iface/52-wan-lro
#   target/linux/airoha/an7581/base-files/etc/hotplug.d/iface/54-pppoe-flowtable
#
# There is no PPPoE session on the bench box and no way to bring one up
# offline, so the netifd status reply, the ethtool feature dump and the nft
# flowtable listing are all replaced by stubs.  Every stub appends its
# invocation to a log file, which is what the assertions look at: the scripts
# are run exactly as hotplug runs them, and only the outside world is faked.
#
# Usage: scripts/tests/test-hotplug-wan-lro-pppoe-flowtable.sh
# Exit status is 0 when every case passes, 1 on the first failure.

set -u

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
HOTPLUG_DIR="$REPO_ROOT/target/linux/airoha/an7581/base-files/etc/hotplug.d/iface"
# Overridable so the suite can be pointed at a pre-fix copy of the scripts and
# has to fail on it; that is the only way a stubbed test can claim it would have
# caught the defect it was written for.
LRO="${WAN_LRO_SCRIPT:-$HOTPLUG_DIR/52-wan-lro}"
PPPFT="${PPPFT_UNDER_TEST:-${PPPFT_SCRIPT:-$HOTPLUG_DIR/54-pppoe-flowtable}}"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

[ -f "$LRO" ] || fail "$LRO is missing"
[ -f "$PPPFT" ] || fail "$PPPFT is missing"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

STUBS="$WORK/stubs"
SYSNET="$WORK/sys"
LOCKS="$WORK/lock"
mkdir -p "$STUBS" "$SYSNET/mac80211" "$LOCKS"

# The real flock, resolved before the stubs shadow it: the stub below has to
# behave like busybox's, which means forwarding the calls it does understand.
REAL_FLOCK=$(command -v flock) || fail "no flock on this host; the lock cases need one"

# --- stubs ------------------------------------------------------------------
#
# Each stub is a tiny script that answers from files whose contents the case
# sets up, and records the call so the assertions can count it.

cat >"$STUBS/ubus" <<'STUB'
#!/bin/sh
# ubus call network.interface.<iface> status
printf 'ubus %s\n' "$*" >>"$FAKE_LOG"
echo "$*" | grep -q '^call network.interface.' || exit 0
if [ -n "${FAKE_STATUS:-}" ]; then
	cat "$FAKE_STATUS"
fi
STUB

cat >"$STUBS/jsonfilter" <<'STUB'
#!/bin/sh
# jsonfilter -e '@.proto' / '@.l3_device'  (reads the JSON on stdin)
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
key = expr.rstrip()
for prefix in ("@.", "@"):
	key = key[len(prefix):] if key.startswith(prefix) else key
value = doc.get(key) if isinstance(doc, dict) else None
if value is None:
	sys.exit(0)
if not isinstance(value, str):
	sys.exit(0)
print(value)
' "$expr"
STUB

cat >"$STUBS/ethtool" <<'STUB'
#!/bin/sh
printf '%s\n' "ethtool $*" >>"$FAKE_LOG"
case "$1" in
-k)
	[ "${2:-}" = "${FAKE_ETHTOOL_DEV:-}" ] && [ -n "${FAKE_ETHTOOL_K:-}" ] && cat "$FAKE_ETHTOOL_K"
	;;
-K)
	# enter/leave around the toggle, with an optional delay in between: two
	# runs that interleave show up as "enter,enter" in $FAKE_SEQ.
	printf 'enter\n' >>"$FAKE_SEQ"
	[ -n "${FAKE_ETHTOOL_SET_DELAY:-}" ] && sleep "$FAKE_ETHTOOL_SET_DELAY"
	printf '%s\n' "${2:-} ${3:-} ${4:-}" >>"$FAKE_ETHTOOL_SET"
	printf 'leave\n' >>"$FAKE_SEQ"
	;;
esac
exit 0
STUB

cat >"$STUBS/nft" <<'STUB'
#!/bin/sh
printf '%s\n' "nft $*" >>"$FAKE_LOG"
if [ "$1" = list ] && [ "${5:-}" = ft ]; then
	[ -n "${FAKE_FLOWTABLE:-}" ] || exit 1
	cat "$FAKE_FLOWTABLE"
	exit 0
fi
if [ "$1" = add ] && [ "${2:-}" = flowtable ]; then
	shift
	printf '%s\n' "$*" >>"$FAKE_NFT_ADD"
	exit "${FAKE_NFT_ADD_RC:-0}"
fi
exit 0
STUB

cat >"$STUBS/logger" <<'STUB'
#!/bin/sh
printf 'logger %s\n' "$*" >>"$FAKE_LOG"
STUB

# busybox's flock, because that is the only flock a stock image has:
# /usr/bin/flock -> ../../bin/busybox, usage "flock [-sxun] FD".  There is no
# -w, and a -w is not a wait that times out - it is an unknown option, so the
# call exits 1 and any "|| give up" guard fires.  Serving that shape here is
# the point of the whole suite: with the host's util-linux flock a script that
# says "flock -w 10 9" looks healthy while doing nothing at all on the board.
cat >"$STUBS/flock" <<STUB
#!/bin/sh
case "\$1" in
-w) printf 'flock: unrecognized option: w\n' >&2; exit 1 ;;
*) exec "$REAL_FLOCK" "\$@" ;;
esac
STUB

chmod +x "$STUBS"/*

# A lock that is never free, and a sleep that does not sleep: together they let
# a case run the whole ten-second give-up path instantly, and count the waits.
FAILSTUBS="$WORK/failstubs"
mkdir -p "$FAILSTUBS"
cat >"$FAILSTUBS/flock" <<'STUB'
#!/bin/sh
exit 1
STUB
cat >"$FAILSTUBS/sleep" <<STUB
#!/bin/sh
printf 'sleep %s\n' "\$*" >>"\$FAKE_LOG"
STUB
chmod +x "$FAILSTUBS"/*

# --- helpers ----------------------------------------------------------------

reset_case() {
	export FAKE_LOG="$WORK/log"
	export FAKE_ETHTOOL_SET="$WORK/ethtool-set"
	export FAKE_NFT_ADD="$WORK/nft-add"
	export FAKE_SEQ="$WORK/seq"
	: >"$FAKE_LOG"
	: >"$FAKE_ETHTOOL_SET"
	: >"$FAKE_NFT_ADD"
	: >"$FAKE_SEQ"
	unset FAKE_STATUS FAKE_ETHTOOL_DEV FAKE_ETHTOOL_K FAKE_FLOWTABLE FAKE_NFT_ADD_RC
	unset FAKE_ETHTOOL_SET_DELAY
	export PATH="$STUBS:$PATH"
	export WAN_LRO_LOCK_DIR="$LOCKS"
	export PF_LOCK_DIR="$LOCKS"
	export PF_SYS_NET="$SYSNET"
	export PF_IFACE=wan
}

run_lro() {
	# $1 action, $2 interface, rest passed as the hotplug environment
	action=$1 iface=$2
	shift 2
	env ACTION="$action" INTERFACE="$iface" "$@" sh "$LRO"
}

run_pppft() {
	action=$1 iface=$2
	shift 2
	env ACTION="$action" INTERFACE="$iface" "$@" sh "$PPPFT"
}

expect_ethtool_set() {
	# $1 expected "dev set value" line
	[ "$(cat "$FAKE_ETHTOOL_SET")" = "$1" ] ||
		fail "${CASE}: expected ethtool -K '$1', got '$(cat "$FAKE_ETHTOOL_SET" | tr '\n' ';')'"
}

expect_ethtool_set_count() {
	[ "$(grep -c . "$FAKE_ETHTOOL_SET")" = "$1" ] ||
		fail "${CASE}: expected $1 ethtool -K calls, got $(grep -c . "$FAKE_ETHTOOL_SET")"
}

expect_nft_add() {
	[ "$(grep -c . "$FAKE_NFT_ADD")" = "$1" ] ||
		fail "${CASE}: expected $1 'nft add flowtable', got $(grep -c . "$FAKE_NFT_ADD")"
}

# --- fixtures ---------------------------------------------------------------
#
# Captured shapes.  The DHCP status is the one the bench box actually returns
# (ubus call network.interface.wan status); the PPPoE ones follow netifd's
# ubus.c: netifd_dump_status() reports main_dev as "device" and the PPP netdev
# as "l3_device", so a PPPoE WAN shows both.
cat >"$WORK/dhcp.json" <<'JSON'
{"up":true,"proto":"dhcp","device":"wan","l3_device":"wan"}
JSON
cat >"$WORK/dhcp-down.json" <<'JSON'
{"up":false,"proto":"dhcp","device":"wan"}
JSON
cat >"$WORK/pppoe.json" <<'JSON'
{"up":true,"proto":"pppoe","device":"wan","l3_device":"pppoe-wan"}
JSON
cat >"$WORK/pppoe-thin.json" <<'JSON'
{"up":true,"proto":"pppoe","device":"wan"}
JSON
cat >"$WORK/pppoe-virtual.json" <<'JSON'
{"up":true,"proto":"pppoe","device":"pppoe-wan","l3_device":"pppoe-wan"}
JSON
cat >"$WORK/pppoe-generic.json" <<'JSON'
{"up":true,"proto":"pppoe","device":"wan","l3_device":"ppp0"}
JSON

cat >"$WORK/lro-fixed-off" <<'K'
Features for wan:
rx-checksumming: on
large-receive-offload: off [fixed]
generic-receive-offload: on
K
cat >"$WORK/lro-flat-off" <<'K'
Features for wan:
rx-checksumming: on
large-receive-offload: off
generic-receive-offload: on
K
cat >"$WORK/lro-on" <<'K'
Features for wan:
rx-checksumming: on
large-receive-offload: on
generic-receive-offload: on
K
cat >"$WORK/lro-empty" <<'K'
K

# The flowtable the bench box reports (nft list flowtable inet fw4 ft), plate
# order and quoting included, and one with no ft at all.
cat >"$WORK/ft-nowan" <<'N'
table inet fw4 {
	flowtable ft {
		hook ingress priority filter
		devices = { "lan2", "lan3", "lan4", "wan" }
		flags offload
		counter
	}
}
N
cat >"$WORK/ft-withppp" <<'N'
table inet fw4 {
	flowtable ft {
		hook ingress priority filter
		devices = { "lan2", "lan3", "lan4", "wan", "pppoe-wan" }
		flags offload
		counter
	}
}
N
cat >"$WORK/ft-noflags" <<'N'
table inet fw4 {
	flowtable ft {
		hook ingress priority filter
		devices = { "lan2", "wan" }
		counter
	}
}
N
cat >"$WORK/ft-withppp-unquoted" <<'N'
table inet fw4 {
	flowtable ft {
		hook ingress priority filter
		devices = { lan2, lan3, lan4, wan, ppp0 }
		flags offload
		counter
	}
}
N
cat >"$WORK/ft-withppp01" <<'N'
table inet fw4 {
	flowtable ft {
		hook ingress priority filter
		devices = { lan2, wan, ppp01 }
		flags offload
		counter
	}
}
N

mkdir -p "$SYSNET/wan" "$SYSNET/pppoe-wan"

# --- 52-wan-lro -------------------------------------------------------------

CASE=lro-ifup-enables
reset_case
export FAKE_STATUS="$WORK/dhcp.json" FAKE_ETHTOOL_DEV=wan FAKE_ETHTOOL_K="$WORK/lro-flat-off"
run_lro ifup wan DEVICE=wan
expect_ethtool_set "wan rx-lro on"
grep -q 'LRO enabled on wan' "$FAKE_LOG" || fail "lro-ifup-enables: no success log line"
grep -q 'giving up' "$FAKE_LOG" &&
	fail "lro-ifup-enables: the lock guard fired; flock is unusable on this image"

CASE=lro-ifupdate-idempotent
reset_case
export FAKE_STATUS="$WORK/dhcp.json" FAKE_ETHTOOL_DEV=wan FAKE_ETHTOOL_K="$WORK/lro-on"
run_lro ifupdate wan DEVICE=wan
expect_ethtool_set_count 0

CASE=lro-ifupdate-no-carrier
reset_case
# Reaching the port with no carrier: ethtool -k prints nothing at all.  The
# toggle must still happen - -K addresses the netdev by name, not the link.
export FAKE_STATUS="$WORK/dhcp.json" FAKE_ETHTOOL_DEV=wan FAKE_ETHTOOL_K="$WORK/lro-empty"
run_lro ifupdate wan DEVICE=wan
expect_ethtool_set "wan rx-lro on"

CASE=lro-ifdown-disables
reset_case
export FAKE_STATUS="$WORK/dhcp-down.json" FAKE_ETHTOOL_DEV=wan FAKE_ETHTOOL_K="$WORK/lro-on"
run_lro ifdown wan DEVICE=wan
expect_ethtool_set "wan rx-lro off"

CASE=lro-ifdown-no-device-env
reset_case
# netifd leaves DEVICE unset on ifdown (interface-event.c sets it only for
# IFEV_UP/IFEV_UPDATE) and the status reply may be thin too; the fallback has
# to name the port anyway, otherwise the LRO state outlives the interface.
export FAKE_STATUS="$WORK/dhcp-down.json" FAKE_ETHTOOL_DEV=wan FAKE_ETHTOOL_K="$WORK/lro-on"
run_lro ifdown wan
expect_ethtool_set "wan rx-lro off"

CASE=lro-refuses-fixed
reset_case
# A virtual device reports LRO as "[fixed]"; that is the guard the script keeps
# so a stacked netdev cannot silently accept an ioctl that changes nothing.
export FAKE_STATUS="$WORK/pppoe-virtual.json" FAKE_ETHTOOL_DEV=pppoe-wan FAKE_ETHTOOL_K="$WORK/lro-fixed-off"
run_lro ifup wan DEVICE=pppoe-wan
expect_ethtool_set_count 0
grep -q 'fixed off' "$FAKE_LOG" || fail "lro-refuses-fixed: no refusal log line"

CASE=lro-ignores-lan
reset_case
export FAKE_STATUS="$WORK/dhcp.json" FAKE_ETHTOOL_DEV=wan FAKE_ETHTOOL_K="$WORK/lro-flat-off"
run_lro ifup lan DEVICE=br-lan
[ ! -s "$FAKE_LOG" ] || fail "lro-ignores-lan: script ran for a non-wan interface"

# --- 54-pppoe-flowtable -----------------------------------------------------

CASE=pppft-ifup-adds
reset_case
export FAKE_STATUS="$WORK/pppoe.json" FAKE_FLOWTABLE="$WORK/ft-nowan" FAKE_NFT_ADD_RC=0
run_pppft ifup wan
expect_nft_add 1
grep -q 'devices = { "pppoe-wan" }' "$FAKE_NFT_ADD" ||
	fail "pppft-ifup-adds: nft add without the pppoe-wan device: $(cat "$FAKE_NFT_ADD")"
grep -q 'flags offload;' "$FAKE_NFT_ADD" ||
	fail "pppft-ifup-adds: hw offload flag not repeated, the update would be rejected"
grep -q 'added pppoe-wan to flowtable ft' "$FAKE_LOG" || fail "pppft-ifup-adds: no success log line"
grep -q 'giving up' "$FAKE_LOG" &&
	fail "pppft-ifup-adds: the lock guard fired; flock is unusable on this image"

CASE=pppft-ifupdate-idempotent
reset_case
export FAKE_STATUS="$WORK/pppoe.json" FAKE_FLOWTABLE="$WORK/ft-withppp"
run_pppft ifupdate wan
expect_nft_add 0

CASE=pppft-ifupdate-noflags
reset_case
# No "flags offload" in the live flowtable: repeating it would flip hw offload
# on and the kernel would reject the update with -EOPNOTSUPP.
export FAKE_STATUS="$WORK/pppoe.json" FAKE_FLOWTABLE="$WORK/ft-noflags" FAKE_NFT_ADD_RC=0
run_pppft ifupdate wan
expect_nft_add 1
grep -q 'flags offload' "$FAKE_NFT_ADD" &&
	fail "pppft-ifupdate-noflags: flag added to a flowtable that has none"

CASE=pppft-thin-status-fallback
reset_case
export FAKE_STATUS="$WORK/pppoe-thin.json" FAKE_FLOWTABLE="$WORK/ft-nowan"
run_pppft ifup wan
expect_nft_add 1
grep -q '"pppoe-wan"' "$FAKE_NFT_ADD" ||
	fail "pppft-thin-status-fallback: fallback did not resolve pppoe-wan"

CASE=pppft-dhcp-wan-untouched
reset_case
export FAKE_STATUS="$WORK/dhcp.json" FAKE_FLOWTABLE="$WORK/ft-nowan"
run_pppft ifup wan
expect_nft_add 0
# Strip the expected ubus proto lookup; nothing else (no nft, no logger) may run.
non_ubus=$(grep -v '^ubus ' "$FAKE_LOG" || true)
[ -n "$non_ubus" ] &&
	fail "pppft-dhcp-wan-untouched: a non-PPPoE WAN reached the flowtable code: $non_ubus"

CASE=pppft-no-flowtable
reset_case
export FAKE_STATUS="$WORK/pppoe.json"
run_pppft ifup wan
expect_nft_add 0
grep -q 'no inet flowtable' "$FAKE_LOG" || fail "pppft-no-flowtable: missing log line"

CASE=pppft-ifdown-noop
reset_case
export FAKE_STATUS="$WORK/pppoe.json" FAKE_FLOWTABLE="$WORK/ft-withppp"
run_pppft ifdown wan
expect_nft_add 0
[ ! -s "$FAKE_LOG" ] || fail "pppft-ifdown-noop: ifdown did work; the unregister path already handles it"

CASE=pppft-generic-ppp0
reset_case
# Where the netdev is called ppp0 rather than pppoe-<iface>: the fallback glob
# has to find it too.
rm -rf "$SYSNET/pppoe-wan" "$SYSNET/ppp0"
mkdir -p "$SYSNET/ppp0"
export FAKE_STATUS="$WORK/pppoe-generic.json" FAKE_FLOWTABLE="$WORK/ft-nowan"
run_pppft ifup wan
expect_nft_add 1
grep -q 'devices = { "ppp0" }' "$FAKE_NFT_ADD" || fail "pppft-generic-ppp0: no ppp0 in the add"

CASE=pppft-ifupdate-idempotent-unquoted-ppp0
reset_case
# nft prints simple alphanumeric device names like ppp0 without quotes; the
# idempotency check must recognise unquoted ppp0 and skip nft add.
export FAKE_STATUS="$WORK/pppoe-generic.json" FAKE_FLOWTABLE="$WORK/ft-withppp-unquoted"
run_pppft ifupdate wan
expect_nft_add 0

CASE=pppft-ifup-ppp0-not-shadowed-by-ppp01
reset_case
# Exact token matching: ppp01 in the flowtable must NOT suppress adding ppp0.
export FAKE_STATUS="$WORK/pppoe-generic.json" FAKE_FLOWTABLE="$WORK/ft-withppp01"
run_pppft ifup wan
expect_nft_add 1
rm -rf "$SYSNET/ppp0"
mkdir -p "$SYSNET/pppoe-wan"

CASE=pppft-add-failure-is-logged
reset_case
export FAKE_STATUS="$WORK/pppoe.json" FAKE_FLOWTABLE="$WORK/ft-nowan" FAKE_NFT_ADD_RC=1
run_pppft ifup wan
grep -q 'could not add pppoe-wan' "$FAKE_LOG" || fail "pppft-add-failure-is-logged: failure was silent"

# --- the lock ---------------------------------------------------------------
#
# The defect these cases exist for: both scripts used "flock -w 10 9".  busybox
# flock, the only flock on the image, has no -w, so that call exited 1, the
# guard logged "giving up", and neither script ever reached ethtool or nft.
# The whole suite already runs under a busybox-shaped flock stub ($STUBS/flock)
# for that reason - a regression back to -w fails every case above too - and
# these cases pin the two things the guard must still do: queue, then give up.

CASE=lock-no-flock-w
# grep -n prints "path:line:text", so a match whose text starts with "# " is the
# note explaining the defect, not the defect.
grep -n 'flock -w' "$LRO" "$PPPFT" | grep -v ':# ' &&
	fail "lock-no-flock-w: a script still calls flock -w, which busybox rejects"

CASE=lro-lock-serialises
reset_case
# ifup and ifdown of one interface released together, with a delay inside the
# toggle so an overlap would be visible: $FAKE_SEQ must read enter,leave twice,
# never enter,enter.  A dropped second caller would leave one toggle, an
# interleaved one would nest them.
export FAKE_STATUS="$WORK/dhcp.json" FAKE_ETHTOOL_DEV=wan FAKE_ETHTOOL_K="$WORK/lro-flat-off"
export FAKE_ETHTOOL_SET_DELAY=1
run_lro ifup wan DEVICE=wan &
lro_p1=$!
run_lro ifdown wan DEVICE=wan &
lro_p2=$!
wait "$lro_p1"
wait "$lro_p2"
expect_ethtool_set_count 2
[ "$(tr '\n' ',' <"$FAKE_SEQ")" = "enter,leave,enter,leave," ] ||
	fail "lro-lock-serialises: toggles interleaved or dropped: $(tr '\n' ',' <"$FAKE_SEQ")"

CASE=lro-lock-giveup-after-ten-tries
reset_case
# A lock that is never free, with no-op sleeps so the bound can be counted
# instead of waited out: ten one-second attempts, then the give-up line, and
# no toggle.
export FAKE_STATUS="$WORK/dhcp.json" FAKE_ETHTOOL_DEV=wan FAKE_ETHTOOL_K="$WORK/lro-flat-off"
export PATH="$FAILSTUBS:$PATH"
run_lro ifup wan DEVICE=wan
expect_ethtool_set_count 0
[ "$(grep -c 'sleep 1' "$FAKE_LOG")" = 10 ] ||
	fail "lro-lock-giveup-after-ten-tries: expected 10 waits, got $(grep -c 'sleep 1' "$FAKE_LOG")"
grep -q 'another LRO change is in progress, giving up' "$FAKE_LOG" ||
	fail "lro-lock-giveup-after-ten-tries: no give-up log line"

CASE=pppft-lock-giveup-after-ten-tries
reset_case
export FAKE_STATUS="$WORK/pppoe.json" FAKE_FLOWTABLE="$WORK/ft-nowan"
export PATH="$FAILSTUBS:$PATH"
run_pppft ifup wan
expect_nft_add 0
[ "$(grep -c 'sleep 1' "$FAKE_LOG")" = 10 ] ||
	fail "pppft-lock-giveup-after-ten-tries: expected 10 waits, got $(grep -c 'sleep 1' "$FAKE_LOG")"
grep -q 'another flowtable change is in progress, giving up' "$FAKE_LOG" ||
	fail "pppft-lock-giveup-after-ten-tries: no give-up log line"

printf 'all hotplug cases passed\n'
