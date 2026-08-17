#!/usr/bin/env bash
# apply-patches.sh — 把 patches/ 补丁层应用到 openwrt 树
# 用法：apply-patches.sh <openwrt树目录> [--dry-run] [--experimental] [--oc]
# 说明：
#   - ROOT 补丁在树根 git apply（跨目录）；其余拷贝到 MANIFEST 指定目录（OpenWrt 构建时应用）。
#   - 冲突即报错退出（修复而不是降级）：人工处理冲突补丁后重跑。
#   - --dry-run：ROOT 补丁按序真实应用（--index）后 git reset --hard 回滚——累计校验，
#     正确反映补丁间依赖；要求工作区相对 HEAD 干净（CI 全新克隆满足）。
#     拷贝项（packages 等）校验目标目录存在性。
#   - --experimental：应用 #EXP 前缀条目（实验档）。
#   - --oc：应用 #OC 前缀条目（OC 档，激进资产如 regdb 555）。
set -euo pipefail

TREE=""
DRY=0
EXP=0
OC=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --experimental) EXP=1 ;;
    --oc) OC=1 ;;
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
  [[ -z "$line" ]] && continue
  if [[ "${line:0:4}" == "#OC " ]]; then
    (( OC )) || { skipped=$((skipped+1)); continue; }
    line="${line:4}"
  fi
  if [[ "${line:0:5}" == "#EXP " ]]; then
    (( EXP )) || { skipped=$((skipped+1)); continue; }
    line="${line:5}"
  fi
  [[ "$line" =~ ^[[:space:]]*# ]] && continue   # 其它注释/停用行（含前导空白）
  src="${line%%[[:space:]]*}"
  dest="${line##*[[:space:]]}"
  pf="$ROOT/$src"
  if [[ ! -f "$pf" ]]; then
    echo "⚠ 缺失补丁文件（未取源？）：$src" >&2
    missing=$((missing+1)); continue
  fi
  if [[ "$dest" == "ROOT" ]]; then
    if (( DRY )); then
      # 累计校验：按序真实应用并暂存（--index），补丁间依赖正确反映；
      # 结束后 git reset --hard 回滚（仅动 git 跟踪内容，不影响未跟踪的叠加层文件）
      if (cd "$TREE" && git apply --index "$pf" 2>/tmp/apply-err); then
        echo "✓ [dry-run] $src"
      else
        echo "✗ 冲突：$src"; sed 's/^/    /' /tmp/apply-err
        (cd "$TREE" && git reset --hard -q); exit 1
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
if (( DRY )); then
  (cd "$TREE" && git reset --hard -q)
  echo "（dry-run 完成，工作区已回滚；未跟踪文件不受影响）"
  exit 0
fi
[[ "$missing" -gt 0 ]] && { echo "存在缺失补丁——先运行 scripts/fetch-sources.sh 或按 patches/specs 取源。" >&2; exit 1; }
exit 0