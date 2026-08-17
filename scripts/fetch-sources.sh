#!/usr/bin/env bash
# fetch-sources.sh — 补丁取源（把 specs 中标记"待取源"的 PR/分支内容拉成补丁文件）
# 用法：fetch-sources.sh [--all|--oc|--22397|--22029|--22473|--24034|--24619]
# 说明：优先拉**已合入/稳定**的 commit；开放 PR 用 .diff（锁定 fetch 日期记入 FIXES.md）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

want() { [[ "$1" == "--all" || "$2" == "--all" ]] || [[ "$2" == *"$1"* ]]; }

fetch() { # <name> <url> <outdir>
  local out="$3/$1"
  echo "== 取源：$1"
  curl -fsSL -o "$out" "$2" && echo "   ✓ $(wc -c < "$out") bytes" || { echo "   ✗ 失败：$2"; return 1; }
}

# 开放 PR 一律走 .diff（当前状态快照；合入后删除补丁、改 FIXES 状态）
if want 22397 "$1"; then
  fetch "openwrt-22397-xr1710g-board-support.patch" \
    "https://github.com/openwrt/openwrt/pull/22397.diff" \
    patches/root/
fi
if want 22029 "$1"; then
  fetch "openwrt-22029-cpufreq-pm-domain.patch" \
    "https://github.com/openwrt/openwrt/pull/22029.diff" \
    patches/specs/   # OC 前置依赖；拉取后移入 kernel 桶并解锁 MANIFEST
fi
if want 22473 "$1"; then
  fetch "openwrt-22473-uboot-pstore.patch" \
    "https://github.com/openwrt/openwrt/pull/22473.diff" \
    patches/specs/
fi
if want 24034 "$1"; then
  fetch "openwrt-24034-rtl826x-led.patch" \
    "https://github.com/openwrt/openwrt/pull/24034.diff" \
    patches/specs/
fi
if want 24619 "$1"; then
  fetch "openwrt-24619-mt7530-led.patch" \
    "https://github.com/openwrt/openwrt/pull/24619.diff" \
    patches/specs/
fi
if want 22532 "$1"; then
  fetch "openwrt-22532-dsa-netlink.patch" \
    "https://github.com/openwrt/openwrt/pull/22532.diff" \
    patches/specs/   # 实验档
fi
if want 22533 "$1"; then
  fetch "openwrt-22533-nft-l2-offload.patch" \
    "https://github.com/openwrt/openwrt/pull/22533.diff" \
    patches/specs/   # 实验档
fi

awk '{print}' patches/MANIFEST | grep -v '^#' | grep -q . || true
echo "----"
echo "拉取完成。步骤：移入对应桶 → 写元数据头 → 解锁 MANIFEST → apply-patches.sh --dry-run 验证。"
echo "注意：开放 PR 的 .diff 会随作者更新变化——每次取源后把 fetch 日期记入 docs/FIXES.md 对应条目。"