#!/usr/bin/env bash
# apply-patches.sh — 把 patches/ 补丁层应用到 openwrt 树
# 用法：apply-patches.sh <openwrt树目录> [--dry-run] [--experimental]
# 说明：
#   - ROOT 补丁在树根 git apply（跨目录）；其余拷贝到 MANIFEST 指定目录（OpenWrt 构建时应用）。
#   - 冲突即报错退出（修复而不是降级）：人工处理冲突补丁后重跑。
#   - --dry-run：ROOT 用 git apply --check 验证；拷贝项校验存在性。
set -euo pipefail

TREE=""
DRY=0
EXP=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --experimental) EXP=1 ;;
    *) TREE="$a" ;;
  esac
done

[[ -n "$TREE" && -d "$TREE/.git" ]] || { echo "错误：需要 openwrt 树目录（含 .git），如 ../openwrt" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/patches/MANIFEST"
[[ -f "$MANIFEST" ]] || { echo "错误：找不到 $MANIFEST" >&2; exit 1; }

applied=0; skipped=0; missing=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%"${line##*[![:space:]]}"}"   # rtrim
  [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
  if [[ "${line:0:5}" == "#EXP " ]]; then
    (( EXP )) || { skipped=$((skipped+1)); continue; }
    line="${line:5}"
  fi
  src="${line%%[[:space:]]*}"
  dest="${line##*[[:space:]]}"
  pf="$ROOT/$src"
  if [[ ! -f "$pf" ]]; then
    echo "⚠ 缺失补丁文件（未取源？）：$src" >&2
    missing=$((missing+1)); continue
  fi
  if [[ "$dest" == "ROOT" ]]; then
    if (( DRY )); then
      if (cd "$TREE" && git apply --check "$pf" 2>/tmp/apply-err); then
        echo "✓ [dry-run] $src"
      else
        echo "✗ 冲突：$src"; sed 's/^/    /' /tmp/apply-err; applied=$((applied+1))
      fi
    else
      (cd "$TREE" && git apply "$pf")
      echo "✓ applied  $src"
    fi
  else
    dt="$TREE/$dest"
    if (( DRY )); then
      [[ -d "$dt" ]] && echo "✓ [dry-run] $src -> $dest（目录存在）" || { echo "⚠ [dry-run] 目标目录不存在：$dest（上游树没有该目录？）" >&2; }
    else
      mkdir -p "$dt"
      cp -f "$pf" "$dt/"
      echo "✓ copied   $src -> $dest"
    fi
  fi
  applied=$((applied+1))
done < "$MANIFEST"

echo "----"
echo "处理：$applied  实验档跳过：$skipped  缺失文件：$missing"
(( DRY )) && exit 0
[[ "$missing" -gt 0 ]] && { echo "存在缺失补丁——先运行 scripts/fetch-sources.sh 或按 patches/specs 取源。" >&2; exit 1; }
exit 0