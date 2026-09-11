#!/usr/bin/env bash
# check-neon-crypto.sh — 离线验证「内核态 WireGuard 的 NEON 加解密是否真的会生效」
#
# 为什么有这个脚本（而不是一个 nft 式的补丁）：
#   `plan/02` §4.3 主张加 CONFIG_ARM64_CRYPTO + CONFIG_CRYPTO_CHACHA20_NEON/POLY1305_NEON/
#   CURVE25519_NEON。对 kernel 6.18.44 核对后这四个符号**都不存在** —— 若照抄，kconfig 会
#   **静默忽略未知符号**（正是 F15 的教训），留下一个"看起来做了事"的假补丁。
#   6.18 的真实机制是 lib/crypto/Kconfig 的 `CRYPTO_LIB_*_ARCH` 对 `ARM64 && KERNEL_MODE_NEON`
#   直接 `default y`，而 WireGuard 自身 select 了这些库 ⇒ 启用 kmod-wireguard 即自动带 NEON。
#
# 本脚本把上述机制变成**可执行断言**：它解析真实内核 Kconfig，检查
#   ① 三个 _NEON 符号与 ARM64_CRYPTO 确实不存在（证明旧方案的符号集是错的）
#   ② _ARCH 变体的 `default y if ARM64 && KERNEL_MODE_NEON` 规则存在（证明机制成立）
#   ③ 本 target 的 config 满足前提（KERNEL_MODE_NEON=y）
#   ④ 若提供了构建后的 .config，则断言 _ARCH 已被推出为 y
#
# 用法：
#   scripts/check-neon-crypto.sh <kernel-dir> [<built .config>]
#   scripts/check-neon-crypto.sh /path/to/openwrt/build_dir/target-*/linux-airoha_an7581/linux-6.18.44
#
# 退出码：0 全绿；1 有断言失败；2 用法/前置不满足
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KDIR="${1:-}"
BUILT_CONFIG="${2:-}"

if [[ -z "$KDIR" ]]; then
	echo "用法：$0 <kernel-dir> [<built .config>]" >&2
	echo "  <kernel-dir> = openwrt build_dir/target-*/linux-airoha_an7581/linux-<ver>/ 或任一解包后的内核源码树" >&2
	exit 2
fi
[[ -f "$KDIR/lib/crypto/Kconfig" ]] || { echo "错误：$KDIR 不像内核源码树（缺 lib/crypto/Kconfig）" >&2; exit 2; }
[[ -f "$KDIR/drivers/net/Kconfig" ]] || { echo "错误：$KDIR 缺 drivers/net/Kconfig" >&2; exit 2; }

pass=0; fail=0
ok()  { echo "  ✓ $1"; pass=$((pass+1)); }
bad() { echo "  ✗ $1"; fail=$((fail+1)); }

echo "== 内核树：$KDIR =="
echo "== 1) 旧方案（plan/02 §4.3）的符号集在本内核上不存在 =="
for sym in CONFIG_ARM64_CRYPTO CONFIG_CRYPTO_CHACHA20_NEON CONFIG_CRYPTO_POLY1305_NEON CONFIG_CRYPTO_CURVE25519_NEON; do
	plain="${sym#CONFIG_}"
	if grep -rqE "^[[:space:]]*config[[:space:]]+${plain}\$" "$KDIR/arch" "$KDIR/crypto" "$KDIR/lib" 2>/dev/null; then
		bad "$plain 竟然存在 —— 那 plan/02 的方案可能成立，请重新评估（勿盲目照抄本结论）"
	else
		ok "$plain 不存在（old plan 的符号集确认失效）"
	fi
done

echo "== 2) 真实机制：CRYPTO_LIB_*_ARCH 对 ARM64 && KERNEL_MODE_NEON 默认启用 =="
check_arch_rule() { # $1=symbol  $2=期望的 default 条件片段
	local body
	body="$(awk -v s="$1" '
		$0 ~ "^config[[:space:]]+"s"$" { f=1; print; next }
		f && /^config[[:space:]]/ { exit }
		f { print }
	' "$KDIR/lib/crypto/Kconfig")"
	if [[ -z "$body" ]]; then
		bad "$1 未在 lib/crypto/Kconfig 找到"
		return
	fi
	if grep -qE "default[[:space:]]+y[[:space:]]+if[[:space:]]+$2" <<<"$body"; then
		ok "$1 有 'default y if $2'"
	else
		bad "$1 缺少 'default y if $2'（实际内容：$(tr '\n' '|' <<<"$body")）"
	fi
}
check_arch_rule CRYPTO_LIB_CHACHA_ARCH     'ARM64 && KERNEL_MODE_NEON'
check_arch_rule CRYPTO_LIB_POLY1305_ARCH   'ARM64 && KERNEL_MODE_NEON'

echo "== 3) NEON 实现确实被编入（Makefile 层证据） =="
if grep -qE 'libchacha-\$\(CONFIG_ARM64\)[[:space:]]*\+=[[:space:]]*arm64/chacha-neon-core\.o' "$KDIR/lib/crypto/Makefile"; then
	ok "lib/crypto/Makefile: CONFIG_ARM64 ⇒ arm64/chacha-neon-core.o"
else
	bad "lib/crypto/Makefile 未找到 arm64/chacha-neon-core.o 规则"
fi
if [[ -f "$KDIR/lib/crypto/arm64/chacha-neon-core.S" ]]; then
	ok "lib/crypto/arm64/chacha-neon-core.S 存在"
else
	bad "lib/crypto/arm64/chacha-neon-core.S 缺失"
fi

echo "== 4) WireGuard 自身 select 了这些库（⇒ 启用 kmod 即触发） =="
wg="$(awk '/^config[[:space:]]+WIREGUARD$/{f=1} f&&/^config[[:space:]]/&&!/^config[[:space:]]+WIREGUARD$/{exit} f{print}' "$KDIR/drivers/net/Kconfig")"
for lib in CRYPTO_LIB_CURVE25519 CRYPTO_LIB_CHACHA20POLY1305; do
	if grep -qE "select[[:space:]]+$lib" <<<"$wg"; then
		ok "WIREGUARD select $lib"
	else
		bad "WIREGUARD 未 select $lib"
	fi
done

echo "== 5) 本 target 的前提：KERNEL_MODE_NEON =="
# 本仓库是**叠加层**模型（补丁层叠到 openwrt 树上），target/linux 不在本仓库里 ⇒
# 按 TREE 环境变量 → 本仓库 openwrt/ → 内核树同级候选，逐个找 target/linux。
TREE="${TREE:-}"
[[ -n "$TREE" && -d "$TREE/target/linux" ]] || TREE=""
if [[ -z "$TREE" && -d "$ROOT/openwrt/target/linux" ]]; then TREE="$ROOT/openwrt"; fi
if [[ -z "$TREE" ]]; then
	# 内核树路径通常是 <tree>/build_dir/target-*/linux-*/linux-<ver>
	cand="$(cd "$KDIR" 2>/dev/null && cd ../../.. 2>/dev/null && pwd)"
	[[ -n "${cand:-}" && -d "$cand/target/linux" ]] && TREE="$cand"
fi

if [[ -n "$TREE" ]]; then
	neon="$(grep -hE '^CONFIG_KERNEL_MODE_NEON=' \
		"$TREE/target/linux/airoha/an7581/config-6.18" \
		"$TREE/target/linux/generic/config-6.18" 2>/dev/null | tail -1)"
	if [[ "$neon" == "CONFIG_KERNEL_MODE_NEON=y" ]]; then
		ok "CONFIG_KERNEL_MODE_NEON=y（_ARCH 的 default 条件成立）  [tree=$TREE]"
	else
		bad "CONFIG_KERNEL_MODE_NEON 不是 =y（实际：${neon:-未找到}）—— NEON 不会生效"
	fi
else
	# 回退：从内核树自身找 config（部分 build_dir 会带 target config 副本）
	neon="$(grep -rhE '^CONFIG_KERNEL_MODE_NEON=' "$KDIR" 2>/dev/null | tail -1)"
	if [[ "$neon" == "CONFIG_KERNEL_MODE_NEON=y" ]]; then
		ok "CONFIG_KERNEL_MODE_NEON=y（来自内核树内 config 副本）"
	else
		echo "  ⊘ 跳过：找不到 openwrt 树（设 TREE=<openwrt 树>）——KERNEL_MODE_NEON 无法断言"
	fi
fi

echo "== 6) 构建后的 .config 断言（可选） =="
if [[ -n "$BUILT_CONFIG" ]]; then
	if [[ -f "$BUILT_CONFIG" ]]; then
		for sym in CRYPTO_LIB_CHACHA CRYPTO_LIB_CHACHA_ARCH CRYPTO_LIB_POLY1305 CRYPTO_LIB_POLY1305_ARCH CONFIG_WIREGUARD; do
			if grep -qE "^CONFIG_${sym}=(y|m)\$" "$BUILT_CONFIG"; then
				ok ".config: CONFIG_${sym} 已启用（$(grep -E "^CONFIG_${sym}=" "$BUILT_CONFIG")）"
			else
				bad ".config: CONFIG_${sym} 未启用 —— NEON/WG 不会生效"
			fi
		done
	else
		bad "提供的 .config 不存在：$BUILT_CONFIG"
	fi
else
	echo "  ⊘ 跳过（未提供构建后的 .config；构建一次后再传第 2 个参数即可断言）"
fi

echo
echo "结果：$pass 通过 / $fail 失败"
echo "结论：NEON 由内核 library 接口提供，**不需要任何 target config 补丁**；"
echo "      启用 kmod-wireguard 即自动生效（ADR-0006 §3）。"
[[ "$fail" == "0" ]]
