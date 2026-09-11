#!/bin/sh
# render.sh — 把 uci 配置渲染成可 `nft -f` 的规则集（template.nft → stdout）
#
# 单一事实源：init.d 与离线门禁都调用本脚本，避免"两处各写一份渲染逻辑"。
# 用法：
#   render.sh                 # 从 uci 读 xr1710g_proxy.global.*（设备上）
#   PROXY_HOSTS='a b' CN_... render.sh   # 覆盖（离线测试/门禁用）
#
# 输出：stdout = 渲染后的 nft 规则集；stderr = 诊断
# 退出码：0 成功；1 输入非法（不产生半成品）；2 模板缺失

set -u

TEMPLATE="${TEMPLATE:-/usr/share/xr1710g-proxy/template.nft}"
[ -r "$TEMPLATE" ] || { echo "错误：模板不可读 $TEMPLATE" >&2; exit 2; }

uci_get() { uci -q get "xr1710g_proxy.global.$1" 2>/dev/null; }
env_or_uci() { # $1=env名 $2=uci键 $3=默认
	local v
	eval "v=\${$1-}"
	[ -n "$v" ] && { printf '%s' "$v"; return; }
	v="$(uci_get "$2")"
	[ -n "$v" ] && { printf '%s' "$v"; return; }
	printf '%s' "$3"
}

FW_MARK="${FW_MARK:-$(env_or_uci FW_MARK fwmark 0x40)}"
DNS_PORT="${DNS_PORT:-$(env_or_uci DNS_PORT singbox_dns_port 5333)}"
PROXY_HOSTS="${PROXY_HOSTS-}"
if [ -z "${PROXY_HOSTS+x}" ] || [ "$PROXY_HOSTS" = "__FROM_UCI__" ]; then
	PROXY_HOSTS="$(uci_get proxy_hosts)"
fi

## ── 输入校验：IPv4/IPv6 字面量或 CIDR，且集合内不允许区间重叠 ──────────────
# nft 对 `flags interval` 集合内的重叠/包含区间直接报
#   "conflicting intervals specified"（实机 nft -c 抓出）
# 所以 192.168.123.0/24 与 192.168.123.224 不能共存 —— 这里显式检测并报错。
is_v4() {
	case "$1" in
		*:*) return 1 ;;
		*) return 0 ;;
	esac
}

v4=""; v6=""
for h in $(printf '%s' "$PROXY_HOSTS" | tr ',\t' '  '); do
	[ -n "$h" ] || continue
	if is_v4 "$h"; then
		v4="$v4$h
"
	else
		v6="$v6$h
"
	fi
done

# 去重 + 排序（确定性输出，便于 diff 与门禁）
v4="$(printf '%s' "$v4" | sed '/^$/d' | sort -u)"
v6="$(printf '%s' "$v6" | sed '/^$/d' | sort -u)"

# 区间重叠检测（仅 IPv4；IPv6 由 nft 自身报错兜底）
if [ -n "$v4" ]; then
	bad="$(printf '%s\n' "$v4" | awk '
		function n2i(s,   a,i,r) { split(s,a,"."); r=0; for(i=1;i<=4;i++) r=r*256+a[i]; return r }
		{ keys[NR]=$0; split($0,p,"/"); base=n2i(p[1]); bits=(p[2]==""?32:p[2]);
		  lo[NR]=base; hi[NR]=base+(bits==32?0:2^(32-bits)-1); cnt=NR }
		END {
		  for (i=1;i<=cnt;i++) for (j=i+1;j<=cnt;j++)
		    if (lo[i]<=hi[j] && lo[j]<=hi[i]) print "  " keys[i] " ⊂/∩ " keys[j]
		}')"
	if [ -n "$bad" ]; then
		echo "错误：proxy_hosts 存在区间重叠/包含（nft flags interval 会拒绝），请收敛为互不重叠的条目：" >&2
		echo "$bad" >&2
		exit 1
	fi
fi

# 空集合 → 不能引用的语法错误，用不可路由占位元素
[ -n "$v4" ] || v4="192.0.2.1"
[ -n "$v6" ] || v6="2001:db8::1"

elems4="$(printf '%s' "$v4" | tr '\n' ',' | sed 's/,$//')"
elems6="$(printf '%s' "$v6" | tr '\n' ',' | sed 's/,$//')"

out="$(sed -e "s|@@FW_MARK@@|$FW_MARK|g" \
    -e "s|@@DNS_PORT@@|$DNS_PORT|g" \
    -e "s|@@PROXY_HOSTS4_ELEMS@@|$elems4|g" \
    -e "s|@@PROXY_HOSTS6_ELEMS@@|$elems6|g" \
    "$TEMPLATE")"

# 渲染后残留的占位符 = 模板与渲染脚本不一致 ⇒ 红，不产出半成品
if printf '%s' "$out" | grep -q '@@'; then
	echo "错误：渲染后仍有未替换的占位符（模板与脚本不同步）：" >&2
	printf '%s\n' "$out" | grep -n '@@' >&2
	exit 1
fi

printf '%s\n' "$out"
exit 0
