#!/usr/bin/env bash
# test-proxy-package.sh — 数据面离线冒烟（不需要设备，不需要 root）
#
# 覆盖三件事：
#   1) nft 模板渲染：正常/空名单/重叠名单/重复条目 四种输入
#   2) 硬约束静态断言：I1–I4 + ADR-0003（auto_route=false、CN 域名回真实 IP、可变路径在 /tmp）
#   3) sing-box 配置生成 + `sing-box check`（若提供 SINGBOX 二进制）：schema 校验
#
# 用法：
#   scripts/test-proxy-package.sh
#   SINGBOX=/path/to/sing-box scripts/test-proxy-package.sh   # 追加真实 schema 校验
#
# 注：nft **语法**校验需要 root（netlink cache init），由设备侧 `nft -c` 与 plan/04 T1-5 负责；
#     本脚本只保证渲染结果结构正确、无残留占位符、且不违反不变量。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/packages-xr1710g/package/xr1710g-proxy"
INIT="$PKG/files/etc/init.d/xr1710g-proxy"
TEMPLATE="$PKG/files/usr/share/xr1710g-proxy/template.nft"
RENDER="$PKG/files/usr/libexec/xr1710g-proxy/render.sh"
SNAP="$PKG/snapshot"
UCI_DEFAULTS="$PKG/files/etc/uci-defaults/99-xr1710g-proxy"
UCI_CONFIG="$PKG/files/etc/config/xr1710g-proxy"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { echo "  ✓ $1"; pass=$((pass+1)); }
bad() { echo "  ✗ $1"; fail=$((fail+1)); }

# 判定"代码里有没有某样东西"必须先剔除注释：模板/脚本的注释**故意**引用了禁止字样
# （如"本文件绝不出现 table inet fw4"），直接 grep 会假红（本脚本第一版即踩此坑）。
strip_comments() { sed -e 's/#.*$//' "$1"; }
check_no() { # $1=描述 $2=文件 $3=禁止模式(ERE)
	local hit
	hit="$(strip_comments "$2" | grep -nE "$3" | head -3 | tr '\n' ' ')"
	if [[ -n "$hit" ]]; then bad "$1 → 命中：$hit"; else ok "$1"; fi
}
check_yes() { # $1=描述 $2=文件 $3=必需模式(ERE)
	if strip_comments "$2" | grep -qE "$3"; then ok "$1"; else bad "$1 → 未命中 /$3/"; fi
}
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "== 1) nft 模板渲染 =="
if PROXY_HOSTS='192.168.123.224 192.168.123.50/32 fd00::/64 2001:db8::5' \
   TEMPLATE="$TEMPLATE" sh "$RENDER" > "$WORK/r1.nft" 2>"$WORK/r1.err"; then
	ok "混合名单渲染成功"
else
	bad "混合名单渲染失败：$(cat "$WORK/r1.err")"
fi
check "无残留占位符"              "! grep -q '@@' '$WORK/r1.nft'"
check "fwmark 已替换"             "grep -q 'meta mark set 0x40' '$WORK/r1.nft'"
check "DNS 端口已替换"            "grep -q 'redirect to :5333' '$WORK/r1.nft'"
check "IPv4 名单进 proxy_hosts4"  "sed -n '/set proxy_hosts4/,/}/p' '$WORK/r1.nft' | grep -q '192.168.123.224'"
check "IPv6 名单进 proxy_hosts6"  "sed -n '/set proxy_hosts6/,/}/p' '$WORK/r1.nft' | grep -q 'fd00::/64'"
check "v6 名单未混入 v4 集合"     "! sed -n '/set proxy_hosts4/,/}/p' '$WORK/r1.nft' | grep -q 'fd00::'"

if PROXY_HOSTS='' TEMPLATE="$TEMPLATE" sh "$RENDER" > "$WORK/r2.nft" 2>/dev/null; then
	ok "空名单渲染成功"
else
	bad "空名单渲染失败"
fi
check "空名单用不可路由占位 v4"   "grep -q 'elements = { 192.0.2.1 }' '$WORK/r2.nft'"
check "空名单用不可路由占位 v6"   "grep -q 'elements = { 2001:db8::1 }' '$WORK/r2.nft'"

if PROXY_HOSTS='192.168.1.0/24 192.168.1.5' TEMPLATE="$TEMPLATE" sh "$RENDER" >/dev/null 2>&1; then
	bad "重叠区间未被拒绝（nft 会直接报 conflicting intervals）"
else
	ok "重叠区间被拒绝（退出码非 0）"
fi

PROXY_HOSTS='10.0.0.1 10.0.0.1 10.0.0.2' TEMPLATE="$TEMPLATE" sh "$RENDER" > "$WORK/r4.nft" 2>/dev/null
check "重复条目已去重" "[[ \"\$(sed -n '/set proxy_hosts4/,/}/p' '$WORK/r4.nft' | grep -oE '10\\.0\\.0\\.[12]' | sort -u | wc -l)\" == 2 ]]"

echo "== 2) 硬约束静态断言（注释行已剔除）=="
# ADR-0003：绝不全局接管
check_yes "init 配置 auto_route=false"        "$INIT" '"auto_route":[[:space:]]*false'
check_yes "init 配置 auto_redirect=false"     "$INIT" '"auto_redirect":[[:space:]]*false'
# ADR-0003 硬前提：CN 域名回真实上游（dns.rules → cn）
check_yes "CN 域名指向真实上游"               "$INIT" '"rule_set":[[:space:]]*"geosite-cn",[[:space:]]*"server":[[:space:]]*"cn"'
# G2：可变路径全在 /tmp
check_yes "cache_file 在 \$RUNDIR"            "$INIT" 'cache_file.*\$RUNDIR'
check_yes "日志在 \$LOG"                      "$INIT" '"output":[[:space:]]*"\$LOG"'
# I3：nft 文件不碰 fw4 / 不动卸载点
check_no  "模板不含 table inet fw4"           "$TEMPLATE" 'table[[:space:]]+inet[[:space:]]+fw4'
check_no  "模板不含 flow add"                 "$TEMPLATE" 'flow[[:space:]]+add'
check_yes "模板只建独立表"                    "$TEMPLATE" 'table[[:space:]]+inet[[:space:]]+xr1710g_proxy'
# I1/I2：包内代码不写 flow_offloading*、不 reload fw4
check_no  "init 无 flow_offloading 写路径"    "$INIT" '(set|echo|>|printf).{0,40}flow_offloading|flow_offloading[[:space:]]*=' 
check_no  "init 无 firewall reload"           "$INIT" 'firewall reload|/etc/init\.d/firewall'
# I4：uci-defaults 不 enable 服务、不碰 firewall/network
check_no  "uci-defaults 无 enable 调用"       "$UCI_DEFAULTS" 'init\.d|(^|[[:space:]])enable([[:space:]]|$)'
check_no  "uci-defaults 不写 firewall/network" "$UCI_DEFAULTS" 'firewall|network\.'
check_yes "默认 enabled=0"                    "$UCI_CONFIG" "option enabled '0'"

echo "== 3) 快照完整性 =="
check "china_ip4 快照存在"   "[[ -s '$SNAP/china_ip4.txt' ]]"
check "china_ip6 快照存在"   "[[ -s '$SNAP/china_ip6.txt' ]]"
check "geosite-cn.srs 存在"  "[[ -s '$SNAP/geosite-cn.srs' ]]"

echo "== 4) sing-box 配置 schema 校验 =="
if [[ -n "${SINGBOX:-}" && -x "${SINGBOX:-}" ]]; then
	# 从 init 脚本抽出 gen_config（**真实单一事实源**），在受控 RUNDIR/CN_SHARE 下执行
	mkdir -p "$WORK/gc" "$WORK/run"
	{
		echo 'RUNDIR="'"$WORK"'/run"; LOG="$RUNDIR/sing-box.log"; CONF="'"$WORK"'/gc/config.json"'
		echo 'CN_SHARE="'"$PKG"'/snapshot"'
		# 抽取整个函数体：**不能**用"遇 `^}` 即停"——heredoc 里生成的 JSON
		# 自身就有顶格 `}`，会提前截断（本脚本第二版即踩此坑）。改用花括号配对计数。
		awk '/^gen_config\(\)/ { f=1 } f { print; d += gsub(/\{/,"{"); d -= gsub(/\}/,"}"); if (f && d == 0) exit }' "$INIT" \
			| sed -e 's/^\t//' 
		echo 'gen_config 5333 singtun0 /nonexistent/outbounds.json'
	} > "$WORK/gen.sh"
	if sh "$WORK/gen.sh" >/dev/null 2>&1 && [[ -s "$WORK/gc/config.json" ]]; then
		ok "gen_config 执行成功"
		if "$SINGBOX" check -c "$WORK/gc/config.json" >"$WORK/sb.err" 2>&1; then
			ok "sing-box check 通过"
		else
			bad "sing-box check 失败：$(tr '\n' ' ' < "$WORK/sb.err")"
		fi
		check "配置含 tun inbound"        "grep -q '\"type\": \"tun\"' '$WORK/gc/config.json'"
		check "配置含 fakeip server"      "grep -q '\"type\": \"fakeip\"' '$WORK/gc/config.json'"
		check "dns.rules 指定 CN 上游"    "grep -q '\"rule_set\": \"geosite-cn\", \"server\": \"cn\"' '$WORK/gc/config.json'"
		check "rule_set 用只读快照路径"   "grep -q '\"path\": \"'$SNAP'/geosite-cn.srs\"' '$WORK/gc/config.json'"
		check "route.final 指向 proxy 出站" "grep -q '\"final\": \"proxy\"' '$WORK/gc/config.json'"
		check "无节点时回落 direct"        "grep -q '{ \"type\": \"direct\", \"tag\": \"proxy\" }' '$WORK/gc/config.json'"
	else
		bad "gen_config 执行失败：$(sh "$WORK/gen.sh" 2>&1 | head -5 | tr '\n' ' ')"
	fi
else
	echo "  ⊘ 跳过（未提供 SINGBOX=/path/to/sing-box）"
fi

echo
echo "结果：$pass 通过 / $fail 失败"
[[ "$fail" == "0" ]]
