#!/bin/sh
# cn-list.sh — CN 放行集合的取数 / 校验 / 装载
#
# 用法：
#   cn-list.sh fetch    # 抓取到 /tmp/xr1710g-proxy/cn/ 并校验（不碰内核）
#   cn-list.sh apply    # 把已校验的运行期列表**单批原子**换入 nft 集合（失败保留旧集合）
#   cn-list.sh update   # fetch + apply（定时更新入口）
#   cn-list.sh status   # 打印快照/运行期列表条目数与时间
#
# 设计约束（plan/01 §4.4）：
#   - 快照随包装入只读 squashfs（/usr/share/xr1710g-proxy/）⇒ 零 NAND 写、零 overlay 占用（G2）
#   - 运行期更新落在 /tmp（tmpfs，掉电即失）
#   - 校验失败保留旧集合，绝不装载半成品
#   - 无 RTC / 网络不可达时只用快照，不阻塞启动

set -u

RUNDIR=/tmp/xr1710g-proxy
CN_RUN="$RUNDIR/cn"
CN_SHARE=/usr/share/xr1710g-proxy
LIBEXEC=/usr/libexec/xr1710g-proxy
TABLE=xr1710g_proxy

uci_get() { uci -q get "xr1710g_proxy.global.$1" 2>/dev/null; }

URL4="${URL4:-$(uci_get cn_list_url)}"
URL6="${URL6:-$(uci_get cn_list_url6)}"
[ -n "$URL4" ] || URL4='https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt'
[ -n "$URL6" ] || URL6='https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china6.txt'

fetch_one() { # $1=url $2=目标文件 $3=期望 family
	local tmp="$2.tmp"
	if ! curl -fsSL --connect-timeout 10 --max-time 60 -o "$tmp" "$1"; then
		echo "抓取失败：$1" >&2
		rm -f "$tmp"
		return 1
	fi
	[ -s "$tmp" ] || { echo "抓取结果为空：$1" >&2; rm -f "$tmp"; return 1; }
	mv -f "$tmp" "$2"
	return 0
}

cmd_fetch() {
	mkdir -p "$CN_RUN"
	fetch_one "$URL4" "$CN_RUN/china_ip4.txt" 4 || return 1
	fetch_one "$URL6" "$CN_RUN/china_ip6.txt" 6 || return 1

	# 校验（重叠会让 nft flags interval 直接拒绝）
	if command -v python3 >/dev/null 2>&1; then
		if ! python3 "$LIBEXEC/validate-cidr.py" "$CN_RUN/china_ip4.txt" "$CN_RUN/china_ip6.txt"; then
			echo "校验失败：列表存在重叠或非法条目，已删除运行期副本（保留旧集合）" >&2
			rm -f "$CN_RUN/china_ip4.txt" "$CN_RUN/china_ip6.txt"
			return 1
		fi
	else
		# 无 python3 时的下限校验：非空 + 只含十六进制/点/冒号/斜杠
		for f in "$CN_RUN/china_ip4.txt" "$CN_RUN/china_ip6.txt"; do
			grep -qE '^[0-9a-fA-F:./]+$' "$f" || { echo "校验失败（无 python3 降级校验）：$f" >&2; return 1; }
		done
	fi
	date +%s > "$CN_RUN/fetched_at"
	return 0
}

cmd_apply() {
	local f4="$CN_RUN/china_ip4.txt" f6="$CN_RUN/china_ip6.txt"
	local batch="$RUNDIR/cn-batch.nft"
	[ -s "$f4" ] || f4="$CN_SHARE/china_ip4.txt"
	[ -s "$f6" ] || f6="$CN_SHARE/china_ip6.txt"
	[ -s "$f4" ] || { echo "无可用 IPv4 列表（快照与运行期皆缺）" >&2; return 1; }

	nft list table inet "$TABLE" >/dev/null 2>&1 || { echo "表 inet $TABLE 不存在，先启动服务" >&2; return 1; }

	{
		echo "table inet $TABLE {"
		echo "  flush set china_ip4"
		[ -s "$f4" ] && printf '  add element china_ip4 { %s }\n' "$(tr '\n' ',' < "$f4" | sed 's/,$//')"
		echo "  flush set china_ip6"
		[ -s "$f6" ] && printf '  add element china_ip6 { %s }\n' "$(tr '\n' ',' < "$f6" | sed 's/,$//')"
		echo "}"
	} > "$batch"

	# 单批 = 原子：nft 要么全成功、要么全不改（失败时旧集合仍在）
	if ! nft -f "$batch" 2>"$RUNDIR/cn-apply.err"; then
		echo "装载失败（保留旧集合）：$(cat "$RUNDIR/cn-apply.err")" >&2
		rm -f "$batch"
		return 1
	fi
	rm -f "$batch"
	date +%s > "$CN_RUN/applied_at"
	return 0
}

cmd_update() {
	cmd_fetch || { echo "更新中止：抓取/校验未通过，旧集合保持不变" >&2; return 1; }
	cmd_apply || return 1
	echo "已更新 CN 放行集合：$(wc -l < "$CN_RUN/china_ip4.txt") 条 IPv4 / $(wc -l < "$CN_RUN/china_ip6.txt") 条 IPv6"
	return 0
}

cmd_status() {
	echo "快照（只读 squashfs）："
	for f in "$CN_SHARE/china_ip4.txt" "$CN_SHARE/china_ip6.txt"; do
		if [ -s "$f" ]; then
			echo "  $f: $(wc -l < "$f") 条, mtime=$(date -r "$f" '+%F %T' 2>/dev/null || echo '?')"
		else
			echo "  $f: 缺失"
		fi
	done
	echo "运行期（tmpfs）："
	for f in "$CN_RUN/china_ip4.txt" "$CN_RUN/china_ip6.txt"; do
		if [ -s "$f" ]; then
			echo "  $f: $(wc -l < "$f") 条"
		else
			echo "  $f: 未使用快照"
		fi
	done
	if nft list table inet "$TABLE" >/dev/null 2>&1; then
		echo "内核集合：china_ip4=$(nft list set inet "$TABLE" china_ip4 2>/dev/null | grep -o 'elements = {.*}' | tr ',' '\n' | wc -l) 条（含占位元素）"
	fi
	return 0
}

case "${1:-status}" in
	fetch)  cmd_fetch ;;
	apply)  cmd_apply ;;
	update) cmd_update ;;
	status) cmd_status ;;
	*) echo "用法：$0 {fetch|apply|update|status}" >&2; exit 2 ;;
esac
