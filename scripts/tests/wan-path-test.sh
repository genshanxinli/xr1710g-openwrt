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
SCRIPT=${WAN_PATH_UNDER_TEST:-${WAN_PATH_SCRIPT:-$ROOT/target/linux/airoha/an7581/base-files/usr/sbin/wan-path}}
# Real output captured read-only from an XR1710G running r38047-a86ce12e27
# (nft 1.1.7).  The last two scenarios replay those bytes instead of
# hand-written ones, so the parsers are checked against what the device
# actually prints: tab-indented flowtable blocks and a "dev" key.
FIX=$ROOT/scripts/tests/fixtures/wan-path-xr1710g
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
expect_grep '"state":"up"' "$outfile" dhcp
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
expect_grep '"state":"up"' "$outfile" pppoe
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
expect_grep '"state":"no-carrier"' "$outfile" down
expect_grep '"complete":false' "$outfile" down
after=$(tree_sum)
[ "$before" = "$after" ] && pass "down: fake tree unchanged" || fail "down: fake tree changed"
expect_no_mutation down

# --- scenario 4: nft 1.1.7 pretty-printed JSON with the "dev" key ------------
#
# The document is pretty-printed and calls the device list "dev", not
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
FAKE_NFT_JSON=$(cat "$FIX/nft-j-list-flowtables.json")
add_dt_node wan
if out=$(run_script --json); then rc=0; else rc=$?; fi
outfile=$TMP/out.4
printf '%s\n' "$out" > "$outfile"
expect_grep '"member":true' "$outfile" nft117
expect_grep '"name":"ft"' "$outfile" nft117

# --- scenario 5: the real box, replayed from captured output ----------------
#
# Everything below is the device byte for byte: proto=dhcp, wan present but
# carrier 0, no PPPoE session (/proc/net/pppoe has only the header), the
# tab-indented flowtable listing, the pretty-printed `nft -j` document, and the
# live PPE usage dump with an empty bind table.  The path stops at the PHY, so
# the run must say so and must not exit 0 just because most counters resolved.

tree_reset
add_netdev wan -1 unknown 0
cp "$FIX/proc-net-pppoe.txt" "$TREE/proc/net/pppoe"
FAKE_PROTO=$(sed -n "s/^network\.wan\.proto='\(.*\)'$/\1/p" "$FIX/uci-network-wan.txt")
FAKE_DEVICE=$(sed -n "s/^network\.wan\.device='\(.*\)'$/\1/p" "$FIX/uci-network-wan.txt")
FAKE_ETHTOOL=$(cat "$FIX/ethtool-wan.txt")
FAKE_NFT_JSON=$(cat "$FIX/nft-j-list-flowtables.json")
FAKE_NFT_TEXT=$(cat "$FIX/nft-list-flowtables.txt")
add_dt_node wan
mkdir -p "$TREE/debugfs/ppe"
cp "$FIX/ppe-usage.txt" "$TREE/debugfs/ppe/usage"
: > "$TREE/debugfs/ppe/bind"
before=$(tree_sum)
if out=$(run_script --json); then rc=0; else rc=$?; fi
outfile=$TMP/out.5
printf '%s\n' "$out" > "$outfile"
expect_rc "$rc" 1 device
expect_grep '"state":"no-carrier"' "$outfile" device
expect_grep '"physical_device":"wan"' "$outfile" device
expect_grep '"member":true' "$outfile" device
expect_grep '"name":"ft"' "$outfile" device
expect_grep '"family":"inet"' "$outfile" device
expect_grep '"session":false' "$outfile" device
expect_grep '"carrier":false' "$outfile" device
expect_grep '"entries":32768' "$outfile" device
expect_grep '"qdam_id":null' "$outfile" device
expect_grep '"interface_entries":null' "$outfile" device
if out=$(run_script); then rc=0; else rc=$?; fi
textfile=$TMP/out.5.text
printf '%s\n' "$out" > "$textfile"
expect_rc "$rc" 1 device-text
expect_grep 'state: no-carrier' "$textfile" device-text
expect_grep 'flowtable: member=yes name=ft family=inet' "$textfile" device-text
after=$(tree_sum)
[ "$before" = "$after" ] && pass "device: fake tree unchanged" || fail "device: fake tree changed"
expect_no_mutation device

# --- scenario 6: device resolved through the netifd status fallback ---------
#
# The same capture, but with network.wan.device unset, so the physical dev has
# to come from `ubus call network.interface.wan status` - the real status
# document, not a hand-written stub.

tree_reset
add_netdev wan -1 unknown 0
cp "$FIX/proc-net-pppoe.txt" "$TREE/proc/net/pppoe"
FAKE_PROTO=dhcp FAKE_DEVICE=
FAKE_UBUS=$(cat "$FIX/ubus-wan-status.json")
FAKE_ETHTOOL=$(cat "$FIX/ethtool-wan.txt")
FAKE_NFT_JSON=
FAKE_NFT_TEXT=$(cat "$FIX/nft-list-flowtables.txt")
add_dt_node wan
if out=$(run_script --json); then rc=0; else rc=$?; fi
outfile=$TMP/out.6
printf '%s\n' "$out" > "$outfile"
expect_rc "$rc" 1 ubus-fallback
expect_grep '"physical_device":"wan"' "$outfile" ubus-fallback
expect_grep '"member":true' "$outfile" ubus-fallback
expect_grep '"name":"ft"' "$outfile" ubus-fallback
expect_no_mutation ubus-fallback

# --- scenario 7: PPPoE with physical link down -> no-carrier first ----------
#
# When carrier is 0 on a PPPoE WAN, the link died at the PHY before PPPoE can
# even dial; reporting no-pppoe-session hides the real root cause (no-carrier).

tree_reset
add_netdev wan -1 unknown 0
printf 'Id       Address              Device\n' > "$TREE/proc/net/pppoe"
FAKE_PROTO=pppoe FAKE_DEVICE=wan
FAKE_ETHTOOL='Settings for wan:
	Speed: Unknown!
	Duplex: Unknown! (255)
	Link detected: no'
FAKE_NFT_JSON=''
FAKE_NFT_TEXT=''
add_dt_node wan
if out=$(run_script --json); then rc=0; else rc=$?; fi
outfile=$TMP/out.7
printf '%s\n' "$out" > "$outfile"
expect_rc "$rc" 1 pppoe-no-carrier
expect_grep '"state":"no-carrier"' "$outfile" pppoe-no-carrier
expect_no_mutation pppoe-no-carrier

# --- scenario 8: bridge/fb listed before inet/ft in nft -j JSON -------------
#
# ft_json must select the inet/ft flowtable specifically (and read devices
# from that object) instead of taking head -1 across all flowtables.

tree_reset
add_netdev wan 10000 full 1
FAKE_PROTO=dhcp FAKE_DEVICE=wan
FAKE_ETHTOOL='Settings for wan:
	Speed: 10000Mb/s
	Duplex: Full
	Link detected: yes'
FAKE_NFT_JSON='{"nftables":[{"metainfo":{"json_schema_version":1}},{"flowtable":{"family":"bridge","name":"fb","table":"fw4","dev":["lan2","lan3"]}},{"flowtable":{"family":"inet","name":"ft","table":"fw4","dev":["lan2","wan"]}}]}'
FAKE_NFT_TEXT=''
add_dt_node wan
if out=$(run_script --json); then rc=0; else rc=$?; fi
outfile=$TMP/out.8
printf '%s\n' "$out" > "$outfile"
expect_grep '"family":"inet"' "$outfile" json-bridge-first
expect_grep '"name":"ft"' "$outfile" json-bridge-first
expect_grep '"member":true' "$outfile" json-bridge-first
expect_no_mutation json-bridge-first

# --- scenario 9: bridge/fb listed before inet/ft in nft text ----------------
#
# Same ordering reversal against the text fallback parser.

tree_reset
add_netdev wan 10000 full 1
FAKE_PROTO=dhcp FAKE_DEVICE=wan
FAKE_ETHTOOL='Settings for wan:
	Speed: 10000Mb/s
	Duplex: Full
	Link detected: yes'
FAKE_NFT_JSON=''
FAKE_NFT_TEXT='table bridge fw4 {
	flowtable fb {
		hook ingress priority filter
		devices = { "lan2", "lan3" }
		flags offload
	}
}
table inet fw4 {
	flowtable ft {
		hook ingress priority filter
		devices = { "lan2", "wan" }
		flags offload
	}
}'
add_dt_node wan
if out=$(run_script --json); then rc=0; else rc=$?; fi
outfile=$TMP/out.9
printf '%s\n' "$out" > "$outfile"
expect_grep '"family":"inet"' "$outfile" text-bridge-first
expect_grep '"name":"ft"' "$outfile" text-bridge-first
expect_grep '"member":true' "$outfile" text-bridge-first
expect_no_mutation text-bridge-first

# --- scenario 10: PPE bind lookup requires exact token match ----------------
#
# Substring/regex grep would count "wan2", "pppoe-wan", or "eth0X2" (dot as
# wildcard for "eth0.2") as entries belonging to the physical WAN netdev.

tree_reset
add_netdev wan 10000 full 1
FAKE_PROTO=dhcp FAKE_DEVICE=wan
FAKE_ETHTOOL='Settings for wan:
	Speed: 10000Mb/s
	Duplex: Full
	Link detected: yes'
FAKE_NFT_JSON='{"nftables":[{"flowtable":{"family":"inet","name":"ft","dev":["wan"]}}]}'
add_dt_node wan
printf '2\n' > "$TREE/dt/soc/ethernet@1fb50000/qdam-id"
mkdir -p "$TREE/debugfs/ppe"
printf 'entries 32768 (sram 16384, dram 16384)\nbound 2 (0%%) unbound 0\n' \
	> "$TREE/debugfs/ppe/usage"
printf 'gdm2 wan2\ngdm2 pppoe-wan\n' > "$TREE/debugfs/ppe/bind"
if out=$(run_script --json); then rc=0; else rc=$?; fi
outfile=$TMP/out.10a
printf '%s\n' "$out" > "$outfile"
expect_grep '"interface_entries":null' "$outfile" ppe-substring-no-match

tree_reset
add_netdev eth0.2 10000 full 1
FAKE_PROTO=dhcp FAKE_DEVICE=eth0.2
FAKE_ETHTOOL='Settings for eth0.2:
	Speed: 10000Mb/s
	Duplex: Full
	Link detected: yes'
FAKE_NFT_JSON='{"nftables":[{"flowtable":{"family":"inet","name":"ft","dev":["eth0.2"]}}]}'
add_dt_node eth0.2
printf '2\n' > "$TREE/dt/soc/ethernet@1fb50000/qdam-id"
mkdir -p "$TREE/debugfs/ppe"
printf 'entries 32768 (sram 16384, dram 16384)\nbound 1 (0%%) unbound 0\n' \
	> "$TREE/debugfs/ppe/usage"
printf 'gdm2 eth0X2\n' > "$TREE/debugfs/ppe/bind"
if out=$(run_script --json); then rc=0; else rc=$?; fi
outfile=$TMP/out.10b
printf '%s\n' "$out" > "$outfile"
expect_grep '"interface_entries":null' "$outfile" ppe-dot-literal

# --- scenario 11: single-device JSON string ("dev":"wan") -------------------
#
# nft -j emits a plain JSON string ("dev":"wan") instead of an array when a
# flowtable holds only one device; ft_json must parse it without matching keys.

tree_reset
add_netdev wan 10000 full 1
FAKE_PROTO=dhcp FAKE_DEVICE=wan
FAKE_ETHTOOL='Settings for wan:
	Speed: 10000Mb/s
	Duplex: Full
	Link detected: yes'
FAKE_NFT_JSON='{"nftables":[{"flowtable":{"family":"inet","name":"ft","table":"fw4","dev":"wan"}}]}'
FAKE_NFT_TEXT=''
add_dt_node wan
if out=$(run_script --json); then rc=0; else rc=$?; fi
outfile=$TMP/out.11a
printf '%s\n' "$out" > "$outfile"
expect_grep '"family":"inet"' "$outfile" json-single-dev-str
expect_grep '"name":"ft"' "$outfile" json-single-dev-str
expect_grep '"member":true' "$outfile" json-single-dev-str

FAKE_NFT_JSON='{"nftables":[{"flowtable":{"family":"inet","name":"ft","table":"fw4","dev":"lan2"}}]}'
if out=$(run_script --json); then rc=0; else rc=$?; fi
outfile=$TMP/out.11b
printf '%s\n' "$out" > "$outfile"
expect_grep '"member":false' "$outfile" json-single-dev-str-other

# --- scenario 12: multi-line devices = { ... } block in nft text ------------
#
# nft list flowtables can wrap devices across lines; ft_text must track
# in_devs until the closing brace of the device set without ending flowtable.

tree_reset
add_netdev wan 10000 full 1
FAKE_PROTO=dhcp FAKE_DEVICE=wan
FAKE_ETHTOOL='Settings for wan:
	Speed: 10000Mb/s
	Duplex: Full
	Link detected: yes'
FAKE_NFT_JSON=''
FAKE_NFT_TEXT='table inet fw4 {
	flowtable ft {
		hook ingress priority filter
		devices = {
			"lan2",
			"wan"
		}
		flags offload
	}
}'
add_dt_node wan
if out=$(run_script --json); then rc=0; else rc=$?; fi
outfile=$TMP/out.12
printf '%s\n' "$out" > "$outfile"
expect_grep '"family":"inet"' "$outfile" text-multiline-devs
expect_grep '"name":"ft"' "$outfile" text-multiline-devs
expect_grep '"member":true' "$outfile" text-multiline-devs

if [ "$FAILED" -ne 0 ]; then
	printf '\nwan-path-test: FAILED\n' >&2
	exit 1
fi
printf '\nwan-path-test: all checks passed\n'
