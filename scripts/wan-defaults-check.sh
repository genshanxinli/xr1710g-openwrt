#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# WAN productization defaults gate (issue #90).
#
# Asserts, one row per key, the defaults this board ships with:
#
#   wan proto dhcp, wan device "wan", wan6 dhcpv6, br-lan = lan2 lan3 lan4
#   firewall defaults flow_offloading / flow_offloading_hw / fullcone on,
#   fullcone6 off, wan zone masq + mtu_fix on and covering wan + wan6
#   nft flowtable ft carries wan alongside the LAN ports
#   wan LRO off by default (the hotplug script turns it on at ifup)
#   wan MTU 1500
#   ppe/pppoe_decap defaults to 0
#
# Output is "key expected actual verdict" per row; rc 0 only when nothing
# FAILed.  A knob the running kernel does not have is reported SKIP (the
# pppoe_decap knob only exists once patches-7.4/9907 is in the image); pass
# --strict to turn SKIP into FAIL.
#
# Everything is read, never written: /etc/config/{network,firewall} are parsed
# in place, "nft list ruleset" and "ethtool -k" are read-only.
#
# Usage:
#   wan-defaults-check.sh [--strict] [--help]
#
# Environment overrides exist for the self-test (scripts/tests/
# test_wan_defaults_rollback.sh) and for reading a captured snapshot:
#   WD_NETWORK_CONF  path to a network config   (default /etc/config/network)
#   WD_FIREWALL_CONF path to a firewall config  (default /etc/config/firewall)
#   WD_NFT_OUT       file holding "nft list ruleset" output
#   WD_ETHTOOL_OUT   file holding "ethtool -k wan" output
#   WD_SYS_NET_DIR   sysfs net directory        (default /sys/class/net)
#   WD_PPE_DIR       ppe debugfs directory      (default /sys/kernel/debug/ppe)

set -u

NET_CONF=${WD_NETWORK_CONF:-/etc/config/network}
FW_CONF=${WD_FIREWALL_CONF:-/etc/config/firewall}
STRICT=0
FAILS=0
SKIPS=0

usage() {
	sed -n '/^# Usage:/,/^# test_wan_defaults_rollback/p' "$0" |
		sed 's/^# \{0,1\}//; $d'
}

while [ $# -gt 0 ]; do
	case "$1" in
	--strict) STRICT=1 ;;
	-h | --help) usage; exit 0 ;;
	*) echo "$0: unknown argument: $1" >&2; exit 2 ;;
	esac
	shift
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
FLAT="$WORK/flat"

# OpenWrt config -> dotted key=value, one line per option, "name" sections by
# name, anonymous sections as @type[index].  Lists get a numeric suffix.
flatten() {
	awk -v cfg="$1" '
	/^[[:space:]]*#/ { next }
	/^[[:space:]]*config[[:space:]]/ {
		type = $2
		ref = ""
		for (i = 3; i <= NF; i++) {
			tok = $i
			gsub(/["\047]/, "", tok)
			ref = tok
		}
		if (ref == "") {
			ref = sprintf("@%s[%d]", type, anon[type]++)
		} else {
			named[type]++
		}
		cur = cfg "." ref
		next
	}
	/^[[:space:]]*option[[:space:]]/ {
		k = $2
		v = $0
		sub(/^[[:space:]]*option[[:space:]]+[^[:space:]]+[[:space:]]+/, "", v)
		gsub(/["\047]/, "", v)
		print cur "." k "=" v
		next
	}
	/^[[:space:]]*list[[:space:]]/ {
		k = $2
		v = $0
		sub(/^[[:space:]]*list[[:space:]]+[^[:space:]]+[[:space:]]+/, "", v)
		gsub(/["\047]/, "", v)
		lc[cur "." k]++
		print cur "." k "." lc[cur "." k] "=" v
		next
	}
	' "$2"
}

for f in "network:$NET_CONF" "firewall:$FW_CONF"; do
	name=${f%%:*}
	path=${f#*:}
	[ -r "$path" ] || {
		echo "$0: cannot read $path" >&2
		exit 2
	}
	flatten "$name" "$path" >>"$FLAT"
done

get() {
	pat=$(printf '%s' "$1" | sed 's/\[/\\[/g; s/\]/\\]/g')
	line=$(grep -m1 "^$pat=" "$FLAT" 2>/dev/null) || {
		printf ''
		return
	}
	printf '%s' "${line#*=}"
}

# Ref of the section whose option name is $3 (anonymous zones come this way).
ref_by_name() {
	line=$(grep -m1 "^$1\.@$2\[[0-9]*\]\.name=$3\$" "$FLAT" 2>/dev/null) || {
		printf ''
		return
	}
	ref=${line#"$1".}
	printf '%s' "${ref%%.name=*}"
}

report() {
	# report KEY EXPECTED ACTUAL
	if [ "$2" = "$3" ]; then
		verdict=PASS
	elif [ "$3" = SKIP ]; then
		verdict=SKIP
		SKIPS=$((SKIPS + 1))
		if [ "$STRICT" = 1 ]; then
			verdict=FAIL
			FAILS=$((FAILS + 1))
		fi
	else
		verdict=FAIL
		FAILS=$((FAILS + 1))
	fi
	printf '%-32s %-30s %-30s %s\n' "$1" "$2" "$3" "$verdict"
}

printf '%-32s %-30s %-30s %s\n' key expected actual verdict

# --- config defaults --------------------------------------------------------

report network.wan.proto dhcp "$(get network.wan.proto)"
report network.wan.device wan "$(get network.wan.device)"
report network.wan6.proto dhcpv6 "$(get network.wan6.proto)"

# br-lan is described by an anonymous "config device" whose ports are the LAN
# netdevs, so the mapping assertion is on those ports, not on the interface's
# device name.
lan_dev=$(get network.lan.device)
[ -n "$lan_dev" ] || lan_dev=br-lan
bridge=$(ref_by_name network device "$lan_dev")
ports=''
for i in 1 2 3 4 5 6; do
	v=$(get "network.$bridge.ports.$i")
	[ -n "$v" ] && ports="$ports $v"
done
report "network.$lan_dev.ports" "lan2 lan3 lan4" "${ports# }"

defaults=$(ref_by_name firewall defaults defaults)
[ -n "$defaults" ] || defaults="@defaults[0]"
report firewall.flow_offloading 1 "$(get "firewall.$defaults.flow_offloading")"
report firewall.flow_offloading_hw 1 "$(get "firewall.$defaults.flow_offloading_hw")"
report firewall.fullcone 1 "$(get "firewall.$defaults.fullcone")"
report firewall.fullcone6 0 "$(get "firewall.$defaults.fullcone6")"

wan_zone=$(ref_by_name firewall zone wan)
if [ -z "$wan_zone" ]; then
	report firewall.wan_zone present missing
else
	report firewall.wan_zone.masq 1 "$(get "firewall.$wan_zone.masq")"
	report firewall.wan_zone.mtu_fix 1 "$(get "firewall.$wan_zone.mtu_fix")"
	covered=''
	for i in 1 2 3; do
		v=$(get "firewall.$wan_zone.network.$i")
		[ -n "$v" ] && covered="$covered $v"
	done
	case " $covered " in
	*' wan '*) report firewall.wan_zone.covers_wan yes yes ;;
	*) report firewall.wan_zone.covers_wan yes no ;;
	esac
	case " $covered " in
	*' wan6 '*) report firewall.wan_zone.covers_wan6 yes yes ;;
	*) report firewall.wan_zone.covers_wan6 yes no ;;
	esac
fi

# --- runtime state ----------------------------------------------------------

NFT_OUT=${WD_NFT_OUT:-}
nft_dump() {
	if [ -n "$NFT_OUT" ]; then
		cat "$NFT_OUT"
	else
		nft list ruleset 2>/dev/null
	fi
}

ft_devices=$(nft_dump | awk '/flowtable ft \{/ { f = 1; next }
	f && /devices = \{/ { line = $0; gsub(/.*devices = \{/, "", line); gsub(/\}.*/, "", line); print line; exit }')
ft_devices=$(printf '%s' "$ft_devices" | tr -d '"')
for want in wan lan2 lan3 lan4; do
	case " $(printf '%s' "$ft_devices" | tr ',' ' ') " in
	*" $want "*) report "fw4.flowtable.ft.$want" member member ;;
	*) report "fw4.flowtable.ft.$want" member absent ;;
	esac
done

ETHTOOL_OUT=${WD_ETHTOOL_OUT:-}
if [ -n "$ETHTOOL_OUT" ]; then
	lro=$(awk -F: '/large-receive-offload/ { gsub(/[ \t]/, "", $2); print $2 }' "$ETHTOOL_OUT")
else
	lro=$(ethtool -k wan 2>/dev/null |
		awk -F: '/large-receive-offload/ { gsub(/[ \t]/, "", $2); print $2 }')
fi
[ -n "$lro" ] || lro=unknown
report wan.large-receive-offload off "$lro"

SYS_NET=${WD_SYS_NET_DIR:-/sys/class/net}
mtu=$(cat "$SYS_NET/wan/mtu" 2>/dev/null || printf '')
[ -n "$mtu" ] || mtu=unknown
report wan.mtu 1500 "$mtu"

PPE=${WD_PPE_DIR:-/sys/kernel/debug/ppe}
knob="$PPE/pppoe_decap"
if [ -r "$knob" ]; then
	report ppe.pppoe_decap 0 "$(cat "$knob" | tr -d ' \n')"
else
	report ppe.pppoe_decap 0 SKIP
fi

if [ "$FAILS" -gt 0 ]; then
	printf 'WAN defaults: %d failed, %d skipped\n' "$FAILS" "$SKIPS" >&2
	exit 1
fi
printf 'WAN defaults: all rows pass (%d skipped)\n' "$SKIPS"
