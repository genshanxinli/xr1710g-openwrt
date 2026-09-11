#!/usr/bin/env bash
# fetch-cn-list.sh — 抓取 + 校验 CN 放行集合与 geosite-cn 规则集，产出入**只读 squashfs** 的快照
#
# 用法：fetch-cn-list.sh [--check]
#   --check  只校验已有快照（不联网）——CI/门禁用，离线可跑
#
# 产出（包源目录，随包进只读 squashfs ⇒ 零 NAND 写、零 overlay 占用，G2）：
#   packages-xr1710g/package/xr1710g-proxy/snapshot/china_ip4.txt
#   packages-xr1710g/package/xr1710g-proxy/snapshot/china_ip6.txt
#   packages-xr1710g/package/xr1710g-proxy/snapshot/geosite-cn.srs   （sing-box binary rule-set）
#
# 数据源与许可证（plan/01 §4.4 要求"实施首步先取证"，本条即取证结论）：
#
#   china_ip4/6：
#     源：https://github.com/gaoyifan/china-operator-ip （"中国运营商 IPv4/IPv6 地址库-每日更新"）
#     许可：MIT License, Copyright (c) 2017 Yifan Gao（已核对仓库 LICENSE 全文）
#     频率：上游 master 每日多次推送（2026-09-11T07:35:03Z 抓取时最新 push）
#     分支：ip-lists（纯 CIDR 文本，一行一条，可直接 `add element`）
#     实测（2026-09-11）：china.txt = 6253 条 IPv4，china6.txt = 3459 条 IPv6，**零重叠/零非法**
#
#   geosite-cn.srs：
#     源：https://github.com/SagerNet/sing-geosite （sing-box 官方规则集仓库）
#     许可：GPL-3.0-or-later（sing-box 同源项目）
#     格式：sing-box binary rule-set（`route.rule_set` / `dns.rules.rule_set` 直接引用）
#     实测（2026-09-11）：55 614 B
#
# 快照**随仓库提交**（不依赖构建时联网）⇒ 离线/CI 可复现；升级 = 显式运行本脚本 + 提交 diff。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SNAP="$ROOT/packages-xr1710g/package/xr1710g-proxy/snapshot"
VALIDATE="$ROOT/packages-xr1710g/package/xr1710g-proxy/files/usr/libexec/xr1710g-proxy/validate-cidr.py"

BASE="https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists"
SRS_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

mkdir -p "$SNAP"

validate() {
	local v4="$SNAP/china_ip4.txt" v6="$SNAP/china_ip6.txt" srs="$SNAP/geosite-cn.srs"
	[[ -s "$v4" && -s "$v6" ]] || { echo "✗ 快照缺失：$v4 或 $v6" >&2; return 1; }
	python3 "$VALIDATE" "$v4" "$v6"
	[[ -s "$srs" ]] || { echo "✗ 规则集缺失：$srs" >&2; return 1; }
	# sing-box binary rule-set 魔数 = "SRS" + version byte
	head4="$(head -c 4 "$srs" | od -An -tx1 | tr -d ' \n')"
	case "$head4" in
		53525301|53525302) echo "  ✓ geosite-cn.srs 头合法（$head4）" ;;
		*) echo "  ✗ geosite-cn.srs 头不合法（不是 sing-box binary rule-set）：$head4" >&2; return 1 ;;
	esac
}

if [[ "$CHECK" == "1" ]]; then
	echo "== 校验已有快照（离线）=="
	validate
	echo "快照：$(wc -l < "$SNAP/china_ip4.txt") IPv4 / $(wc -l < "$SNAP/china_ip6.txt") IPv6 条 / srs $(stat -c%s "$SNAP/geosite-cn.srs") B"
	exit 0
fi

echo "== 抓取 CN 地址库（gaoyifan/china-operator-ip, MIT）=="
for f in china.txt china6.txt; do
	tmp="$SNAP/.$f.tmp"
	curl -fsSL --connect-timeout 15 --max-time 120 --retry 3 -o "$tmp" "$BASE/$f"
	[[ -s "$tmp" ]] || { echo "✗ 抓取为空：$f" >&2; rm -f "$tmp"; exit 1; }
	# 规范化：去注释/空行、去重、稳定排序（便于 diff 与可复现）
	sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]]//g' -e '/^$/d' "$tmp" | sort -u > "${tmp%.tmp}"
	rm -f "$tmp"
done
mv -f "$SNAP/.china.txt"  "$SNAP/china_ip4.txt"
mv -f "$SNAP/.china6.txt" "$SNAP/china_ip6.txt"

echo "== 抓取 geosite-cn 规则集（SagerNet/sing-geosite, GPL-3.0-or-later）=="
tmp="$SNAP/.geosite-cn.srs.tmp"
curl -fsSL --connect-timeout 15 --max-time 120 --retry 3 -o "$tmp" "$SRS_URL"
[[ -s "$tmp" ]] || { echo "✗ 抓取为空：geosite-cn.srs" >&2; rm -f "$tmp"; exit 1; }
mv -f "$tmp" "$SNAP/geosite-cn.srs"

echo "== 校验（nft flags interval 不允许任何重叠/包含；rule-set 头必须是 SRS）=="
validate

echo "== 完成 =="
echo "  china_ip4.txt:   $(wc -l < "$SNAP/china_ip4.txt") 条"
echo "  china_ip6.txt:   $(wc -l < "$SNAP/china_ip6.txt") 条"
echo "  geosite-cn.srs:  $(stat -c%s "$SNAP/geosite-cn.srs") B"
echo "请把快照 diff 一并提交（升级=显式 bump），并更新 docs/FIXES.md 对应条目。"
