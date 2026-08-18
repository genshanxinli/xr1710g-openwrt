#!/usr/bin/env bash
# audit-patches.sh — 补丁 hunk 行数一致性审计（F21③/9001 截断教训制度化，2026-08-17）
# 用法：audit-patches.sh [openwrt树目录]（树目录可选，仅用于解析 MANIFEST 相对路径）
#
# 背景：包裹补丁（ROOT 补丁生成包补丁，如 9002→uboot、9001→dts）的 hunk 头行数
#   （@@ -0,0 +1,N @@）与实际内容行数不一致时，git apply 会**静默按声明行数截断**
#   创建文件（F21③ 9002 丢尾部 gdm1 块；9001 丢 97 行致内核 DTS 语法错误——两例均
#   在构建期才暴露）。本审计逐 hunk 核对声明行数，不一致即红。
#
# 覆盖：MANIFEST 全部活动条目（ROOT + 拷贝 + --oc 时 #OC 行 + --experimental 时 #EXP 行）的每个 hunk。
set -euo pipefail

OC=0; EXP=0
for a in "$@"; do
  [[ "$a" == "--oc" ]] && OC=1
  [[ "$a" == "--experimental" ]] && EXP=1
done
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/patches/MANIFEST"
[[ -f "$MANIFEST" ]] || { echo "错误：找不到 $MANIFEST" >&2; exit 1; }
command -v python3 >/dev/null || { echo "错误：缺 python3" >&2; exit 1; }

# 收集活动补丁路径（与 apply-patches.sh 同一解析逻辑）
patches_list=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" ]] && continue
  if [[ "${line:0:4}" == "#OC " ]]; then
    (( OC )) || continue
    line="${line:4}"
  fi
  if [[ "${line:0:5}" == "#EXP " ]]; then
    (( EXP )) || continue
    line="${line:5}"
  fi
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  src="${line%%[[:space:]]*}"
  [[ -f "$ROOT/$src" ]] && patches_list+=("$ROOT/$src")
done < "$MANIFEST"

if [[ ${#patches_list[@]} -eq 0 ]]; then
  echo "（无活动补丁条目）"; exit 0
fi

export AUDIT_LIST="${patches_list[*]}"
python3 - "$ROOT" << 'EOF'
import os, re, sys
root = sys.argv[1]
hdr = re.compile(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@')
files = os.environ['AUDIT_LIST'].split()
bad = []
for f in files:
    cur = None
    for line in open(f, encoding='utf-8', errors='replace'):
        if hdr.match(line):
            if cur is not None and cur['got'] != cur['want']:
                bad.append((os.path.basename(f), cur['want'], cur['got']))
            m = hdr.match(line)
            cur = {'want': int(m.group(2) or 1), 'got': 0}
            continue
        if cur is not None:
            if line.startswith('+') or line.startswith(' '):
                cur['got'] += 1
            elif line.startswith('@@') or line.startswith('diff --git') or \
                 line.startswith('--- ') or line.startswith('+++ '):
                if cur['got'] != cur['want']:
                    bad.append((os.path.basename(f), cur['want'], cur['got']))
                cur = None
    if cur is not None and cur['got'] != cur['want']:
        bad.append((os.path.basename(f), cur['want'], cur['got']))
if bad:
    for name, want, got in bad:
        print(f"✗ hunk 行数不一致：{name} 声称 +{want} 实际 +{got}（git apply 会截断创建文件——修复 @@ 头行数）", file=sys.stderr)
    sys.exit(1)
print(f"✓ hunk 行数审计：{len(files)} 个补丁全部一致")
EOF
