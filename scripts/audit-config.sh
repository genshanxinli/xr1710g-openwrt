#!/usr/bin/env bash
# audit-config.sh — seed 符号审计：核对 seed-config.diff 的活动 CONFIG_* 是否都进入 .config
# 用法：audit-config.sh <seed.diff> <.config>
# 背景（FIXES F15）：kconfig 对未知符号静默忽略 —— 拼错的符号不会报错，只是不被选中。
# 本脚本把所有活动 seed 符号逐一在 .config 中核对（=y / ="..." / 顶层 = 均算命中），
# 缺任何一个即列出并退出 1（修复而不是降级：符号写错就修，不让核心能力静默丢失）。
set -euo pipefail

SEED="${1:-config/seed-config.diff}"
CFG="${2:-.config}"
[[ -f "$SEED" ]] || { echo "错误：无 $SEED" >&2; exit 1; }
[[ -f "$CFG" ]] || { echo "错误：无 $CFG（先 make defconfig）" >&2; exit 1; }

missing=0
while IFS='=' read -r sym _; do
  case "$sym" in
    ''|\#*) continue ;;
    CONFIG_*) ;;
    *) continue ;;
  esac
  if ! grep -q "^${sym}=" "$CFG"; then
    echo "✗ seed 符号未进 .config：$sym（seed 拼写或上游包名已变？——查证后修 seed，勿跳过）" >&2
    missing=$((missing+1))
  fi
done < <(grep -E '^CONFIG_' "$SEED")

if [[ "$missing" -gt 0 ]]; then
  echo "seed 符号审计失败：$missing 个符号缺失（见上）" >&2
  exit 1
fi
echo "✓ seed 符号审计通过（$(grep -cE '^CONFIG_' "$SEED") 个活动符号全部进入 .config）"