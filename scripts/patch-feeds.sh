#!/usr/bin/env bash
# patch-feeds.sh — 在 **feeds update/install 之后** 给 feed 克隆打"包定义"补丁
#
# 为什么需要这个独立步骤（而不是用 patches/packages/ 的拷贝机制）：
#   `patches/packages/` 的补丁会被拷到 `<pkg>/patches/`，由 OpenWrt 在**解开的包源码**上
#   以 `patch -p1` 应用。这适用于"改上游源码"（mt76/regdb/uboot）。
#   但**改 feed 包自己的 Makefile**（如 netbird 提版）不能走这条路：
#     - netbird 的 tarball 是**上游源码仓库**（含项目自己的 Makefile），没有 OpenWrt 包 Makefile；
#     - OpenWrt 的 Go 配方（golang-package.mk → golang-build.sh build）**不调用源码里的 make**。
#   ⇒ 拷贝机制必然 `Patch failed!`；且 verify-copy-patches.sh 对未登记的目标只会打印
#     "未知拷贝目标——跳过" ⇒ **静默未校验**（比失败更危险）。
#
# 本脚本把 `patches/feeds/*.patch` 以 `git apply` 打到 **feed 克隆**上（相对 feeds/<name> 根，-p1）。
# 调用点：build.sh 与 .github/workflows/build.yml 的 feeds 步骤**之后**、配置步骤之前。
#
# 用法：patch-feeds.sh <openwrt树目录> [--check]
#   --check  只检查补丁能否干净应用（不落盘）
set -euo pipefail

TREE=""
CHECK=0
for a in "$@"; do
	case "$a" in
		--check) CHECK=1 ;;
		*) TREE="$a" ;;
	esac
done
[[ -n "$TREE" && -d "$TREE" ]] || { echo "用法：$0 <openwrt树目录> [--check]" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FEEDDIR="$ROOT/patches/feeds"
[[ -d "$FEEDDIR" ]] || { echo "无 patches/feeds/ ⇒ 无需处理"; exit 0; }

# 每个 feed 补丁的落地根（相对 TREE）。新增 feed 补丁时必须在此登记 —— 未登记即红，
# 避免重犯"静默跳过"（这正是本脚本存在的理由）。
feedroot_for() { # $1 = 补丁 basename
	case "$1" in
		netbird-*) echo "feeds/packages" ;;
		*) echo "" ;;
	esac
}

applied=0; failed=0
shopt -s nullglob
for pf in "$FEEDDIR"/*.patch; do
	base="$(basename "$pf")"
	# 跳过注释行/停用行（与 MANIFEST 同款约定）
	case "$base" in \#*) continue ;; esac
	fr="$(feedroot_for "$base")"
	if [[ -z "$fr" ]]; then
		echo "✗ patches/feeds/$base 未在 feedroot_for() 登记落地根 —— 拒绝静默跳过" >&2
		failed=$((failed+1)); continue
	fi
	dest="$TREE/$fr"
	if [[ ! -d "$dest" ]]; then
		echo "⚠ feeds 目录不存在：$fr（feeds update 跑过吗？）——跳过 $base" >&2
		failed=$((failed+1)); continue
	fi

	# feed 克隆是 git 仓库 ⇒ 优先用 git apply（一次性语义，重复应用即报错，正是我们想要的）
	if [[ -d "$dest/.git" ]]; then
		if (cd "$dest" && git apply --check "$pf" 2>/tmp/pf-err); then
			if (( CHECK )); then
				echo "✓ [check] $base → $fr"
			else
				(cd "$dest" && git apply "$pf")
				echo "✓ applied $base → $fr"
			fi
			applied=$((applied+1))
		elif (cd "$dest" && git apply --check --reverse "$pf" 2>/dev/null); then
			echo "= 已应用（幂等跳过）：$base"
			applied=$((applied+1))
		else
			echo "✗ $base 无法应用到 $fr：" >&2
			sed 's/^/    /' /tmp/pf-err >&2
			failed=$((failed+1))
		fi
	else
		# 非 git feed（src-link 等）：退化为 patch -p1 --forward
		if (cd "$dest" && patch -p1 --forward --dry-run < "$pf" >/dev/null 2>&1); then
			if (( CHECK )); then
				echo "✓ [check] $base → $fr (patch)"
			else
				(cd "$dest" && patch -p1 --forward < "$pf" >/dev/null)
				echo "✓ applied $base → $fr (patch)"
			fi
			applied=$((applied+1))
		else
			echo "✗ $base 无法应用到 $fr（非 git feed，patch 也失败）" >&2
			failed=$((failed+1))
		fi
	fi
done

echo "----"
echo "feed 包定义补丁：处理 $applied  失败 $failed"
(( failed > 0 )) && { echo "✗ 存在失败项——修复而不是跳过" >&2; exit 1; }
exit 0
