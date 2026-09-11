#!/usr/bin/env bash
# audit-upstream-watch.sh — 上游基线守护（只读、确定性）
# 用法：audit-upstream-watch.sh <openwrt树目录>
#
# 背景（2026-09-11 深度调研）：本仓多个补丁的**内层补丁基线**是上游具体文件的某一版，
# 上游改动这些文件时不会立刻让 dry-run 变红，却会让内层补丁在构建期才失败（典型：
# 上游 openwrt PR #25092 改 `generic/pending-6.18/742|743`（realtek PHY）并新增 744/745，
# 而本仓 9041 的内层 742/743/744 与 9033 的 LED hack 都基于旧版 generic 上下文 →
# 合入后本仓 9041/9033 必须重基）。
#
# 本脚本用 **git blob SHA** 精确比对"本仓补丁所基于的上游文件版本"，任何漂移都会点出
# 需要重基的补丁。比"等 dry-run 红"更早、比"人工比对"更确定。
#
# 行为：默认只报告（exit 0）；`--fail-on-drift` 时漂移即 exit 1（CI 用）。
set -euo pipefail

TREE=""; FAIL_ON_DRIFT=0
for a in "$@"; do
  case "$a" in
    --fail-on-drift) FAIL_ON_DRIFT=1 ;;
    *) TREE="$a" ;;
  esac
done
[[ -n "$TREE" && -d "$TREE/.git" ]] || { echo "用法：audit-upstream-watch.sh <openwrt树目录> [--fail-on-drift]" >&2; exit 1; }

# 基线表：<blob-sha> <上游路径> <受影响的本仓补丁>
# 生成方式：在目标上游 commit 上 `git rev-parse HEAD:<path>`
BASELINE=(
  "b7ace2329055f96346036579f329ef2f06dc19e4 target/linux/generic/pending-6.18/742-net-phy-realtek-add-5G-and-10G-PHY-support.patch    root/9041(内层742/743/744)、root/9033(LED hack)"
  "379da970e4c8b6c5329c9f0e1c8fe30ff9a784f3 target/linux/generic/pending-6.18/743-net-phy-realtek-reset-RTL8261N-USXGMII-SerDes-on-lin.patch  root/9041(内层742/743/744)"
  "b379ad09a5740990b3722cfbe6b20232db970767 package/kernel/mt76/Makefile    mt76 包补丁族（0001-0014/9990-9993）与 pin 跟踪"
)
# 基线取自 openwrt main = e59c7876（2026-09-11）。上游 bump 时**有意**更新本表。

drift=0; miss=0
echo "== 上游基线守护（compare git blob SHA）=="
for row in "${BASELINE[@]}"; do
  want=$(echo "$row" | awk '{print $1}')
  path=$(echo "$row" | awk '{print $2}')
  who=$(echo "$row" | awk '{print $3}')
  got=$( (cd "$TREE" && git rev-parse "HEAD:$path" 2>/dev/null) || echo MISSING )
  if [[ "$got" == "MISSING" ]]; then
    echo "  ✗ 缺失：$path（上游删了/改名了？受影响：$who）" >&2
    miss=$((miss+1))
  elif [[ "$got" != "$want" ]]; then
    echo "  ⚠ 漂移：$path"
    echo "      期望 $want"
    echo "      实际 $got"
    echo "      → 受影响补丁需重基：$who"
    drift=$((drift+1))
  else
    echo "  ✓ 未变：$path"
  fi
done

# 上游是否已出现 #25092 新增的 744/745（合入信号）
for p in 744-net-phy-realtek-restore-the-RTL8261CE_CG-PHY-ID-matc.patch 745-net-phy-realtek-apply-SerDes-lane-polarity-on-RTL826.patch; do
  if (cd "$TREE" && git cat-file -e "HEAD:target/linux/generic/pending-6.18/$p" 2>/dev/null); then
    echo "  ⚠ 上游已出现 generic/pending-6.18/$p（#25092 可能已合入）→ 复核 9041/9033 与 CE 适用性（本机 10G PHY 实测 = RTL8261BE / c45 0x001ccaf3）"
    drift=$((drift+1))
  fi
done

echo "----"
echo "漂移 $drift，缺失 $miss（基线取自 openwrt main e59c7876）"
if (( miss > 0 || (FAIL_ON_DRIFT && drift > 0) )); then
  echo "处理（修复而非降级）：按 docs/absorptions/2026-09-11-absorption-plan.md §5.3 重基本仓补丁并复跑" >&2
  echo "  ./scripts/apply-patches.sh . --dry-run --oc --experimental" >&2
  exit 1
fi
exit 0
