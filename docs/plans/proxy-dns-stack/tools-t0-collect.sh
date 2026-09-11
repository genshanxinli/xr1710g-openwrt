#!/bin/sh
# t0-collect.sh — T0 基线取证（设备侧，只读）
# 铁律：只读、不写 flash、不碰 flow_offloading*
set -u
echo "##### META"
date -u +%Y-%m-%dT%H:%M:%SZ
uname -a
cat /etc/openwrt_release
echo "##### KERNEL_MODULES"
uname -r
ls /lib/modules/$(uname -r)/ 2>/dev/null | tr '\n' ' '
echo
echo "##### LAYOUT"
ubinfo -a 2>&1
echo "----- /proc/mtd"
cat /proc/mtd
echo "----- df"
df -h
echo "----- dmesg FIT"
dmesg 2>/dev/null | grep -i -E 'FIT:|ubi[0-9]|resize' | head -20
echo "##### CPUINFO"
cat /proc/cpuinfo | grep -E 'Features|processor|model' | head -12
echo "##### CRYPTO"
grep -E '^(name|driver|priority)' /proc/crypto | paste - - - 2>/dev/null | grep -i -E 'chacha|poly1305|curve25519|gcm\(aes\)' | head -20
echo "##### FEEDS_AND_PKGS"
cat /etc/apk/repositories.d/*.list 2>/dev/null
echo "----- installed (interesting)"
apk list --installed 2>/dev/null | grep -E 'sing-box|netbird|dnsmasq|nftables|firewall4|kmod-tun|kmod-wireguard|ipset|tproxy|ip-full|tcpdump|ethtool|conntrack|yq' | sort
echo "----- available (interesting)"
apk list 2>/dev/null | grep -E '^(sing-box|netbird|adguardhome|homeproxy|mosdns|mihomo|nikki)' | sort
echo "##### NFT"
nft list ruleset 2>&1 | head -200
echo "----- chain forward"
nft list chain inet fw4 forward 2>&1 | head -60
echo "----- flowtable"
nft list flowtables 2>&1
echo "##### IP"
echo "----- ip rule"
ip rule show
echo "----- ip route table all"
ip route show table all | head -60
echo "----- ip -6 rule"
ip -6 rule show 2>&1 | head -20
echo "##### UCI"
echo "----- firewall (offload related)"
uci show firewall 2>/dev/null | grep -i -E 'offload|flow|forwarding|zone' | head -40
echo "----- full firewall"
uci show firewall 2>/dev/null
echo "----- network"
uci show network 2>/dev/null | head -60
echo "----- dnsmasq"
uci show dhcp 2>/dev/null | head -60
echo "----- /etc/config listing"
ls -la /etc/config/
echo "##### PPE"
echo -n "ppe/bind count: "; cat /sys/kernel/debug/ppe/bind 2>/dev/null | wc -l
echo -n "ppe/entries count: "; cat /sys/kernel/debug/ppe/entries 2>/dev/null | wc -l
echo "----- ppe/bind first 10"
cat /sys/kernel/debug/ppe/bind 2>/dev/null | head -10
echo "##### OVERLAY"
du -sb /overlay/upper 2>/dev/null
echo "----- tmp usage"
df -h /tmp
echo "##### DNSMASQ_CAPS"
dnsmasq --help 2>&1 | grep -i -E 'nftset|ipset|server' | head
echo "##### PROCESSES"
ps w 2>/dev/null | head -40
echo "##### DONE"
