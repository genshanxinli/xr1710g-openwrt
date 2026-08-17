#!/usr/bin/env bash
# build.sh — 本地一键构建（完整源码构建，OpenWrt 官方流程）
# 用法：build.sh <stock|oc-1.3|oc-1.4> [openwrt树目录]
#   TIER 缺省 = stock（决策：双 release，stock 为默认 known-good，oc 变体可选）
#   树目录缺省 = ./openwrt（或 $OPENWRT_DIR）
#
# 前置（首次）：
#   git clone https://github.com/openwrt/openwrt.git openwrt
#     # 或直接：本仓库就是 openwrt 的 fork（含此文件），TREE=.
#   ./scripts/feeds update -a && ./scripts/feeds install -a
#
# 本脚本在树内执行：应用补丁层 → （oc 档）prepare-oc → feeds → defconfig(+seed) → make
set -euo pipefail

TIER="${1:-stock}"
case "$TIER" in stock|oc-1.3|oc-1.4) ;; *) echo "错误：TIER ∈ stock|oc-1.3|oc-1.4" >&2; exit 1 ;; esac
TREE="${2:-${OPENWRT_DIR:-./openwrt}}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JOBS="${JOBS:-$(nproc)}"

[[ -d "$TREE/.git" && -f "$TREE/scripts/feeds" ]] || { echo "错误：$TREE 不是 openwrt 源码树（缺 scripts/feeds）" >&2; exit 1; }

echo "== [1/5] 同步补丁层（$TIER）=="
OC_FLAG=""; [[ "$TIER" != "stock" ]] && OC_FLAG="--oc"
"$ROOT/scripts/apply-patches.sh" "$TREE" $OC_FLAG

echo "== [2/5] OC 档位 =="
if [[ "$TIER" != "stock" ]]; then
  "$ROOT/scripts/prepare-oc.sh" "${TIER#oc-}" "$TREE"
else
  "$ROOT/scripts/prepare-oc.sh" stock "$TREE" || true   # 撤销可能残留的 OC 编辑
fi

echo "== [2.5/5] files/ overlay（网络/Wi-Fi/风扇/OC 限频默认配置）=="
mkdir -p "$TREE/files"
cp -rf "$ROOT/files/." "$TREE/files/"

echo "== [3/5] feeds（官方默认 + 本仓库自定义）=="
cd "$TREE"
cp -f feeds.conf.default feeds.conf
cat "$ROOT/config/feeds.custom.conf" >> feeds.conf
./scripts/feeds update -a
./scripts/feeds install -a

echo "== [4/5] 配置 =="
# 首次需先建 .config；之后每次用 seed 差量刷新（决策：可复现、显式）
if [[ ! -f .config ]]; then
  make defconfig
fi
# 应用 seed diff（见 config/seed-config.diff 内注释：依赖外部 feed 的包先 TODO）
cat "$ROOT/config/seed-config.diff" >> .config
make defconfig
grep -q "CONFIG_TARGET_airoha_an7581_gemtek_xr1710g-ubi=y" .config \
  && echo "✓ XR1710G 目标已选中" \
  || { echo "⚠ .config 中未选中 gemtek_xr1710g-ubi——检查 seed-config.diff 与 #22397 补丁" >&2; }

echo "== [5/5] 构建（-j$JOBS, 日志 build.log）=="
make -j"$JOBS" V=s 2>&1 | tee "$ROOT/build-$TIER.log"
echo "产物："
ls -la bin/targets/airoha/an7581/*.itb 2>/dev/null || find bin/targets -name '*.itb' -exec ls -la {} \;
echo "完成：$TIER"
echo "刷机：见 docs/FLASHING.md（HTTP U-Boot 主路径）"