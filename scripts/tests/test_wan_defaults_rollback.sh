#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Rollback matrix for scripts/wan-defaults-check.sh (issue #90).
#
# For every default that an operator may change, this does
#   baseline -> change -> check must FAIL -> roll back -> same md5 -> check PASS
# on fixture copies of /etc/config/{network,firewall} in a temp dir.  Nothing
# on the real box is touched, and each run also asserts that the check itself
# left both files byte-identical (a read-only gate that rewrites config is a
# bug, not a convenience).
#
# Usage: scripts/tests/test_wan_defaults_rollback.sh

set -u

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
CHECK="${WAN_CHECK_UNDER_TEST:-$REPO_ROOT/scripts/wan-defaults-check.sh}"

FAILED=0
fail() {
	printf 'FAIL: %s\n' "$*" >&2
	FAILED=1
}

[ -f "$CHECK" ] || fail "$CHECK is missing"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

NET="$WORK/network"
FW="$WORK/firewall"
ORIG="$WORK/orig"
mkdir -p "$ORIG" "$WORK/sysnet/wan" "$WORK/ppe"

# Fixture copies of the bench box's config (measured 2026-11-20).
cat >"$NET" <<'EOF'
config interface 'lan'
	option device 'br-lan'
	option proto 'static'

config device
	option name 'br-lan'
	option type 'bridge'
	list ports 'lan2'
	list ports 'lan3'
	list ports 'lan4'

config interface 'wan'
	option device 'wan'
	option proto 'dhcp'

config interface 'wan6'
	option device 'wan'
	option proto 'dhcpv6'
EOF

cat >"$FW" <<'EOF'
config defaults
	option syn_flood '1'
	option flow_offloading '1'
	option flow_offloading_hw '1'
	option fullcone '1'
	option fullcone6 '0'

config zone
	option name 'wan'
	list network 'wan'
	list network 'wan6'
	option masq '1'
	option mtu_fix '1'
EOF

cat >"$WORK/nft" <<'EOF'
table inet fw4 {
	flowtable ft {
		hook ingress priority filter
		devices = { "lan2", "lan3", "lan4", "phy0.0-ap0", "wan" }
		flags offload
	}
}
EOF

printf 'Features for wan:\nlarge-receive-offload: off\n' >"$WORK/ethtool"
printf '1500\n' >"$WORK/sysnet/wan/mtu"

cp "$NET" "$ORIG/network"
cp "$FW" "$ORIG/firewall"
MD5_NET=$(md5sum <"$ORIG/network")
MD5_FW=$(md5sum <"$ORIG/firewall")

OUT=''
RC=0

run_check() {
	OUT=$(WD_NETWORK_CONF="$NET" \
		WD_FIREWALL_CONF="$FW" \
		WD_NFT_OUT="$WORK/nft" \
		WD_ETHTOOL_OUT="$WORK/ethtool" \
		WD_SYS_NET_DIR="$WORK/sysnet" \
		WD_PPE_DIR="$WORK/ppe" \
		sh "$CHECK" "$@" 2>&1)
	RC=$?
}

restore() {
	cp "$ORIG/network" "$NET"
	cp "$ORIG/firewall" "$FW"
}

# assert_state CASE EXPECT_RC ROW_KEY EXPECTED_VERDICT
assert_state() {
	case=$1
	want_rc=$2
	row=$3
	verdict=$4
	[ "$RC" = "$want_rc" ] || fail "$case: rc=$RC, wanted $want_rc; output: $OUT"
	line=$(printf '%s\n' "$OUT" | awk -v k="$row" '$1 == k { print; exit }')
	[ -n "$line" ] || fail "$case: no row for $row; output: $OUT"
	case " $line " in
	*" $verdict "*) ;;
	*) fail "$case: row '$line' is not $verdict" ;;
	esac
}

# assert_unchanged CASE NET_MD5 FW_MD5 -- the check must not rewrite its input.
assert_unchanged() {
	case=$1
	[ "$(md5sum <"$NET")" = "$2" ] || fail "$case: the check rewrote $NET"
	[ "$(md5sum <"$FW")" = "$3" ] || fail "$case: the check rewrote $FW"
}

# --- baseline ---------------------------------------------------------------

run_check
assert_state baseline 0 firewall.flow_offloading PASS
assert_state baseline 0 wan.mtu PASS
assert_state baseline 0 network.wan.proto PASS
assert_state baseline 0 fw4.flowtable.ft.wan PASS
assert_state baseline 0 ppe.pppoe_decap SKIP
assert_unchanged baseline "$MD5_NET" "$MD5_FW"

# --- rollback matrix --------------------------------------------------------

# check_name key sed-expression-file config
case_rollback() {
	name=$1
	row=$2
	mutate=$3
	file=$4

	restore
	$mutate
	if [ "$(md5sum <"$file")" = "$(md5sum <"$ORIG/$(basename "$file")")" ]; then
		fail "$name: the mutation changed nothing"
	fi
	before_net=$(md5sum <"$NET")
	before_fw=$(md5sum <"$FW")
	run_check
	assert_state "$name" 1 "$row" FAIL
	assert_unchanged "$name" "$before_net" "$before_fw"

	restore
	[ "$(md5sum <"$NET")" = "$MD5_NET" ] || fail "$name: network rollback mismatch"
	[ "$(md5sum <"$FW")" = "$MD5_FW" ] || fail "$name: firewall rollback mismatch"
	run_check
	assert_state "$name" 0 "$row" PASS
}

mutate_flow_offloading() { sed -i "s/option flow_offloading '1'/option flow_offloading '0'/" "$FW"; }
mutate_flow_offloading_hw() { sed -i "s/option flow_offloading_hw '1'/option flow_offloading_hw '0'/" "$FW"; }
mutate_fullcone() { sed -i "s/option fullcone '1'/option fullcone '0'/" "$FW"; }
mutate_fullcone6() { sed -i "s/option fullcone6 '0'/option fullcone6 '1'/" "$FW"; }
mutate_masq() { sed -i "s/option masq '1'/option masq '0'/" "$FW"; }
mutate_mtu_fix() { sed -i "s/option mtu_fix '1'/option mtu_fix '0'/" "$FW"; }
mutate_wan_proto() { sed -i "s/option proto 'dhcp'/option proto 'pppoe'/" "$NET"; }
mutate_wan_device() { sed -i "s/option device 'wan'/option device 'lan2'/" "$NET"; }
mutate_wan6_proto() { sed -i "s/option proto 'dhcpv6'/option proto 'none'/" "$NET"; }
mutate_lan_ports() { sed -i "s/list ports 'lan4'/list ports 'lan5'/" "$NET"; }
case_rollback rollback.flow_offloading firewall.flow_offloading mutate_flow_offloading "$FW"
case_rollback rollback.flow_offloading_hw firewall.flow_offloading_hw mutate_flow_offloading_hw "$FW"
case_rollback rollback.fullcone firewall.fullcone mutate_fullcone "$FW"
case_rollback rollback.fullcone6 firewall.fullcone6 mutate_fullcone6 "$FW"
case_rollback rollback.masq firewall.wan_zone.masq mutate_masq "$FW"
case_rollback rollback.mtu_fix firewall.wan_zone.mtu_fix mutate_mtu_fix "$FW"
case_rollback rollback.wan_proto network.wan.proto mutate_wan_proto "$NET"
case_rollback rollback.wan_device network.wan.device mutate_wan_device "$NET"
case_rollback rollback.wan6_proto network.wan6.proto mutate_wan6_proto "$NET"
case_rollback rollback.lan_ports network.br-lan.ports mutate_lan_ports "$NET"

# --- knob-shaped rows: nft devices, LRO, MTU, pppoe_decap -------------------

restore
cat >"$WORK/nft" <<'NFTEOF'
table inet fw4 {
	flowtable ft {
		hook ingress priority filter
		devices = { "lan2", "lan3", "lan4", "phy0.0-ap0" }
		flags offload
	}
}
NFTEOF
run_check
assert_state ft-without-wan 1 fw4.flowtable.ft.wan FAIL
cat >"$WORK/nft" <<'NFTEOF'
table inet fw4 {
	flowtable ft {
		hook ingress priority filter
		devices = { "lan2", "lan3", "lan4", "phy0.0-ap0", "wan" }
		flags offload
	}
}
NFTEOF
run_check
assert_state ft-restored 0 fw4.flowtable.ft.wan PASS

printf 'Features for wan:\nlarge-receive-offload: on\n' >"$WORK/ethtool"
run_check
assert_state lro-on 1 wan.large-receive-offload FAIL
printf 'Features for wan:\nlarge-receive-offload: off\n' >"$WORK/ethtool"
run_check
assert_state lro-off 0 wan.large-receive-offload PASS

printf '1400\n' >"$WORK/sysnet/wan/mtu"
run_check
assert_state mtu-1400 1 wan.mtu FAIL
printf '1500\n' >"$WORK/sysnet/wan/mtu"
run_check
assert_state mtu-1500 0 wan.mtu PASS

# pppoe_decap: absent -> SKIP, present but != 0 -> FAIL, --strict turns the
# missing knob into a failure.
printf '0\n' >"$WORK/ppe/pppoe_decap"
run_check
assert_state ppe-default 0 ppe.pppoe_decap PASS
printf '2\n' >"$WORK/ppe/pppoe_decap"
run_check
assert_state ppe-two 1 ppe.pppoe_decap FAIL
rm -f "$WORK/ppe/pppoe_decap"
run_check
assert_state ppe-absent 0 ppe.pppoe_decap SKIP
run_check --strict
assert_state ppe-strict 1 ppe.pppoe_decap FAIL

restore
assert_unchanged final "$MD5_NET" "$MD5_FW"

[ "$FAILED" = 0 ] || {
	printf 'wan-defaults rollback cases failed\n' >&2
	exit 1
}
printf 'all wan-defaults rollback cases passed\n'
