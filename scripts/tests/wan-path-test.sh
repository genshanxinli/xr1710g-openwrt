#!/bin/sh
#
# wan-path-test.sh - dry-run self-test for usr/sbin/wan-path.
#
# Builds a throwaway sysfs/procfs/debugfs tree plus fake uci/ubus/ethtool/nft
# commands in a temp dir, runs the script against them, and asserts:
#
#   - the DHCP, PPPoE and WAN-down scenarios produce the expected fields and
#     exit codes;
#   - every command the script ran is in calls.log and none of them mutates
#     state (no uci set/commit, no nft add/delete/flush, no ethtool with a
#     write argument);
#   - the fake sysfs/procfs/debugfs tree is byte-identical before and after,
#     which is the read-only proof.
#
# Usage: scripts/tests/wan-path-test.sh [--verbose]

set -eu

ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT=${WAN_PATH_SCRIPT:-$ROOT/target/linux/airoha/an7581/base-files/usr/sbin/wan-path}
VERBOSE=0
[ "${1:-}" = --verbose ] && VERBOSE=1

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

BIN=$TMP/bin
TREE=$TMP/tree
CALLS=$TMP/calls.log
mkdir -p "$BIN"
: > "$CALLS"
export CALLS

cat > "$BIN/uci" <<'FAKE'
#!/bin/sh
printf 'uci %s\n' "$*" >> "$CALLS"
[ "$1" = "-q" ] && shift
[ "$1" = "get" ] || exit 1
case $2 in
network.wan.proto) printf '%s\n' "${FAKE_PROTO:-}" ;;
network.wan.device) printf '%s\n' "${FAKE_DEVICE:-}" ;;
network.wan.ifname) printf '%s\n' "${FAKE_IFNAME:-}" ;;
*) exit 1 ;;
esac
FAKE

cat > "$BIN/ubus" <<'FAKE'
#!/bin/sh
printf 'ubus %s\n' "$*" >> "$CALLS"
printf '%s\n' "${FAKE_UBUS:-}"
FAKE

cat > "$BIN/ethtool" <<'FAKE'
#!/bin/sh
printf 'ethtool %s\n' "$*" >> "$CALLS"
[ -n "${FAKE_ETHTOOL:-}" ] || exit 1
printf '%s\n' "$FAKE_ETHTOOL"
FAKE

cat > "$BIN/nft" <<'FAKE'
#!/bin/sh
printf 'nft %s\n' "$*" >> "$CALLS"
if [ "$1" = "-j" ]; then
	printf '%s\n' "${FAKE_NFT_JSON:-}"
else
	printf '%s\n' "${FAKE_NFT_TEXT:-}"
fi
FAKE

chmod +x "$BIN/uci" "$BIN/ubus" "$BIN/ethtool" "$BIN/nft"

tree_reset() {
	rm -rf "$TREE"
	mkdir -p "$TREE/sys/class/net" "$TREE/proc/net" "$TREE/debugfs" "$TREE/dt/soc"
	: > "$TREE/proc/net/pppoe"
	: > "$CALLS"
}

add_netdev() {
	mkdir -p "$TREE/sys/class/net/$1"
	printf '%s\n' "$2" > "$TREE/sys/class/net/$1/speed"
	printf '%s\n' "$3" > "$TREE/sys/class/net/$1/duplex"
	printf '%s\n' "$4" > "$TREE/sys/class/net/$1/carrier"
}

# Wire the netdev's device/of_node to a DT node the same way the platform
# device appears under /sys/devices on AN7581.
add_dt_node() {
	dev=$TREE/sys/devices/platform/soc/1fb50000.ethernet
	mkdir -p "$dev"
	printf 'DRIVER=airoha_eth\nOF_COMPATIBLE_0=airoha,en7581-eth\n' > "$dev/uevent"
	ln -sfn "$TREE/dt/soc/ethernet@1fb50000" "$dev/of_node"
	ln -sfn "$dev" "$TREE/sys/class/net/$1/device"
	[ -d "$TREE/dt/soc/ethernet@1fb50000" ] || mkdir -p "$TREE/dt/soc/ethernet@1fb50000"
	printf 'airoha,en7581-eth\n' > "$TREE/dt/soc/ethernet@1fb50000/compatible"
}

run_script() {
	PATH="$BIN:$PATH" \
	WP_SYS_NET="$TREE/sys/class/net" \
	WP_PROC_NET="$TREE/proc/net" \
	WP_DEBUGFS="$TREE/debugfs" \
	WP_DT="$TREE/dt" \
	FAKE_PROTO="${FAKE_PROTO:-}" FAKE_DEVICE="${FAKE_DEVICE:-}" \
	FAKE_IFNAME="${FAKE_IFNAME:-}" FAKE_UBUS="${FAKE_UBUS:-}" \
	FAKE_ETHTOOL="${FAKE_ETHTOOL:-}" FAKE_NFT_JSON="${FAKE_NFT_JSON:-}" \
	FAKE_NFT_TEXT="${FAKE_NFT_TEXT:-}" \
	sh "$SCRIPT" "$@"
}

tree_sum() {
	find "$TREE" -type f -exec cksum {} + | sort
}

FAILED=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAILED=1; }

expect_rc() {
	actual=$1 expected=$2 name=$3
	if [ "$actual" = "$expected" ]; then
		pass "$name: exit $actual"
	else
		fail "$name: exit $actual, expected $expected"
	fi
}

expect_grep() {
	pat=$1 file=$2 name=$3
	if grep -qF "$pat" "$file"; then
		pass "$name: contains $pat"
	else
		fail "$name: missing $pat"
		if [ "$VERBOSE" = 1 ]; then
			sed 's/^/     | /' "$file" >&2
		fi
	fi
}

expect_no_mutation() {
	name=$1
	bad=$(grep -Ev '^(uci -q get |nft (-j )?list |ethtool [A-Za-z0-9_.@-]+$|ubus call )' "$CALLS" || true)
	if [ -n "${bad:-}" ]; then
		fail "$name: non-read-only command: $bad"
	else
		pass "$name: calls.log has reads only"
	fi
}

# --- scenario 1: DHCP uplink, link up, every segment known -----------------

tree_reset
add_netdev wan 10000 full 1
add_netdev lan2 1000 full 1
FAKE_PROTO=dhcp FAKE_DEVICE=wan
FAKE_ETHTOOL='Settings for wan:
	Speed: 10000Mb/s
	Duplex: Full
	Link detected: yes'
FAKE_NFT_JSON='{"nftables":[{"metainfo":{"json_schema_version":1}},{"flowtable":{"family":"inet","name":"ft","hook":"ingress","prio":0,"devices":["lan2","wan"],"flags":["offload"]}}]}'
add_dt_node wan
printf '2\n' > "$TREE/dt/soc/ethernet@1fb50000/qdam-id"
mkdir -p "$TREE/debugfs/ppe"
printf 'entries 32768 (sram 16384, dram 16384)\nbound 11 (0%%) unbound 24\nl2b_bound 0 l2_flows_sw 0\n' \
	> "$TREE/debugfs/ppe/usage"
printf 'gdm2 wan\n' > "$TREE/debugfs/ppe/bind"
before=$(tree_sum)
if out=$(run_script --json); then rc=0; else rc=$?; fi
outfile=$TMP/out.1
printf '%s\n' "$out" > "$outfile"
expect_rc "$rc" 0 dhcp
expect_grep '"proto":"dhcp"' "$outfile" dhcp
expect_grep '"physical_device":"wan"' "$outfile" dhcp
expect_grep '"qdam_id":"2"' "$outfile" dhcp
expect_grep '"speed":10000' "$outfile" dhcp
expect_grep '"duplex":"full"' "$outfile" dhcp
expect_grep '"bound":11' "$outfile" dhcp
expect_grep '"interface_entries":1' "$outfile" dhcp
expect_grep '"member":true' "$outfile" dhcp
expect_grep '"complete":true' "$outfile" dhcp
after=$(tree_sum)
[ "$before" = "$after" ] && pass "dhcp: fake tree unchanged" || fail "dhcp: fake tree changed"
expect_no_mutation dhcp

# --- scenario 2: PPPoE uplink, session on pppoe-wan -------------------------

tree_reset
add_netdev wan 10000 full 1
add_netdev pppoe-wan 10000 full 1
printf 'Id       Address              Device\n1        10.0.0.2             pppoe-wan\n' \
	> "$TREE/proc/net/pppoe"
FAKE_PROTO=pppoe FAKE_DEVICE=wan
FAKE_ETHTOOL='Settings for wan:
	Speed: 10000Mb/s
	Duplex: Full
	Link detected: yes'
FAKE_NFT_JSON='{"nftables":[{"flowtable":{"family":"inet","name":"ft","devices":["wan"]}}]}'
add_dt_node wan
printf '2\n' > "$TREE/dt/soc/ethernet@1fb50000/gdm-id"
mkdir -p "$TREE/debugfs/ppe"
printf 'entries 32768 (sram 16384, dram 16384)\nbound 11 (0%%) unbound 24\n' \
	> "$TREE/debugfs/ppe/usage"
printf 'gdm2 wan\n' > "$TREE/debugfs/ppe/bind"
before=$(tree_sum)
if out=$(run_script --json); then rc=0; else rc=$?; fi
outfile=$TMP/out.2
printf '%s\n' "$out" > "$outfile"
expect_rc "$rc" 0 pppoe
expect_grep '"proto":"pppoe"' "$outfile" pppoe
expect_grep '"logical_device":"pppoe-wan"' "$outfile" pppoe
expect_grep '"physical_device":"wan"' "$outfile" pppoe
expect_grep '"session":true' "$outfile" pppoe
expect_grep '"qdam_id":"2"' "$outfile" pppoe
expect_grep '"complete":true' "$outfile" pppoe
after=$(tree_sum)
[ "$before" = "$after" ] && pass "pppoe: fake tree unchanged" || fail "pppoe: fake tree changed"
expect_no_mutation pppoe

# --- scenario 3: WAN down, no flowtable, no PPE, no QDMA id -----------------

tree_reset
add_netdev wan -1 unknown 0
FAKE_PROTO=dhcp FAKE_DEVICE=wan
FAKE_ETHTOOL='Settings for wan:
	Speed: Unknown!
	Duplex: Unknown! (255)
	Link detected: no'
FAKE_NFT_JSON=''
FAKE_NFT_TEXT=''
add_dt_node wan
before=$(tree_sum)
if out=$(run_script --json); then rc=0; else rc=$?; fi
outfile=$TMP/out.3
printf '%s\n' "$out" > "$outfile"
expect_rc "$rc" 1 down
expect_grep '"carrier":false' "$outfile" down
expect_grep '"speed":null' "$outfile" down
expect_grep '"qdam_id":null' "$outfile" down
expect_grep '"member":false' "$outfile" down
expect_grep '"bound":null' "$outfile" down
expect_grep '"complete":false' "$outfile" down
after=$(tree_sum)
[ "$before" = "$after" ] && pass "down: fake tree unchanged" || fail "down: fake tree changed"
expect_no_mutation down

# --- scenario 4: nft 1.1.7 pretty-printed JSON with the "dev" key ------------
#
# Captured verbatim from a live XR1710G running nft 1.1.7 "Commodore Bullmoose
# #8".  The document is pretty-printed and calls the device list "dev", not
# "devices", so a compact-only pattern finds nothing and every flowtable
# question answers "no" instead of "we could not read it".

tree_reset
add_netdev wan 10000 full 1
add_netdev lan4 1000 full 1
FAKE_PROTO=dhcp FAKE_DEVICE=wan
FAKE_ETHTOOL='Settings for wan:
	Speed: 10000Mb/s
	Duplex: Full
	Link detected: yes'
FAKE_NFT_JSON='{"nftables": [{"metainfo": {"version": "1.1.7", "release_name": "Commodore Bullmoose #8", "json_schema_version": 1}}, {"flowtable": {"family": "inet", "name": "ft", "table": "fw4", "handle": 71, "hook": "ingress", "prio": 0, "dev": ["lan2", "lan3", "lan4", "wan"]}}, {"flowtable": {"family": "bridge", "name": "fb", "table": "fw4", "handle": 2, "hook": "ingress", "prio": 0, "dev": ["lan2", "lan3", "lan4"]}}]}'
add_dt_node wan
if out=$(run_script --json); then rc=0; else rc=$?; fi
outfile=$TMP/out.4
printf '%s\n' "$out" > "$outfile"
expect_grep '"member":true' "$outfile" nft117

if [ "$FAILED" -ne 0 ]; then
	printf '\nwan-path-test: FAILED\n' >&2
	exit 1
fi
printf '\nwan-path-test: all checks passed\n'
