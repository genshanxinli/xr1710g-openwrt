#!/usr/bin/env bash
# prepare-oc.sh — 对 openwrt 树应用/撤销 CPU 超频（确定性编辑，失败即报错）
# 用法：prepare-oc.sh <1.3|1.4|stock> <openwrt树目录>
#   - 1.3：OPP 500–1200MHz → 600–1300MHz（PLL base 600）保守档
#   - 1.4：OPP 500–1200MHz → 700–1400MHz（PLL base 700）激进档（与 fanboy ubi2-oc 一致）
#   - stock：撤销（git restore 涉及文件）
# 前置依赖：cpufreq / PM domain 修复可用（见 docs/FIXES.md 条目 #22029）——无修复时 OC 不稳定，本脚本会提示。
# 参考：OpenW1700k ubi2-oc commit 80096373b5（patches/specs/original-oc-80096373b5-6.12-reference.patch）
set -euo pipefail

TIER="${1:-stock}"
TREE="${2:-${OPENWRT_DIR:-}}"
[[ -n "$TREE" && -d "$TREE/.git" ]] || { echo "用法：prepare-oc.sh <1.3|1.4|stock> <openwrt树目录>" >&2; exit 1; }

case "$TIER" in
  1.3) BASE=600 ;;
  1.4) BASE=700 ;;
  stock) ;;
  *) echo "错误：档位必须是 1.3 / 1.4 / stock" >&2; exit 1 ;;
esac

DTS="$TREE/target/linux/airoha/dts/an7581.dtsi"
CFG="$TREE/target/linux/airoha/an7581/config-6.18"

# 记录会被修改的文件（stock 时 git restore）
TOUCHED=()
touched() { TOUCHED+=("$1"); }

revert_stock() {
  echo "撤销 OC…"
  for f in "${TOUCHED[@]:-}"; do :; done
  # 重新收集：公式出现过的文件 + dts + cfg
  mapfile -t FILES < <(grep -rl -E 'freq_mhz = [0-9]+ \+ state \* 50' "$TREE/target/linux/airoha" 2>/dev/null || true)
  FILES+=("$DTS" "$CFG")
  # shellcheck disable=SC2207
  for f in $(printf '%s\n' "${FILES[@]}" | sort -u); do
    if (cd "$TREE" && git ls-files --error-unmatch -- "$f" >/dev/null 2>&1); then
      (cd "$TREE" && git restore -- "$f" && echo "restored $f") || echo "  跳过（无改动）：$f"
    else
      # 未跟踪 = 生成文件（如 apply-patches 展开的 patches-6.18/940-*.patch）：
      # git 无法还原，删除回到 apply 前状态，下次 apply-patches 重建纯净版本（防 OC 公式残留）
      rm -f "$TREE/$f" && echo "removed 生成文件 $f（未跟踪；下次 apply-patches 重建）"
    fi
  done
}

if [[ "$TIER" == "stock" ]]; then revert_stock; exit 0; fi

echo "== OC 档位 $TIER（OPP base=$BASE MHz）=="
[[ -f "$DTS" ]] || { echo "错误：无 $DTS——#22397 板级补丁未应用？先跑 apply-patches.sh" >&2; exit 1; }
touched "$DTS"

# 1) OPP 表整体平移：hz + (BASE-500)；opp-<label> 同步改名
python3 - "$DTS" "$BASE" <<'PY'
import re, sys
path, base = sys.argv[1], int(sys.argv[2])
delta = base - 500
s = open(path, encoding="utf-8").read()
def shift_hz(m):
    hz = int(m.group(1)) + delta
    return f"opp-hz = /bits/ 64 <{hz}>;"
def shift_label(m):
    hz = int(m.group(1)) + delta
    return f"opp-{hz}"
n_hz = len(re.findall(r"opp-hz = /bits/ 64 <(\d+)>;", s))
s = re.sub(r"opp-hz = /bits/ 64 <(\d+)>;", shift_hz, s)
s = re.sub(r"\bopp-(\d+)\s*\{", shift_label, s)
open(path, "w", encoding="utf-8").write(s)
print(f"  dts OPP：平移 {n_hz} 个频率点 +{delta}MHz")
PY
touched "$DTS"

# 2) PM domain PLL 公式：freq_mhz = <old> + state * 50 → <BASE> + state * 50
#    6.18 下该公式可能在 patches-6.18/ 携带的补丁或内核源里；树内找不到就报错并要求定位（修复不是降级）。
found=0
while IFS= read -r f; do
  sed -i -E "s/freq_mhz = [0-9]+ \+ state \* 50/freq_mhz = $BASE + state * 50/" "$f"
  echo "  PLL 公式更新：$f（base=$BASE）"
  touched "$f"
  found=$((found+1))
done < <(grep -rl -E 'freq_mhz = [0-9]+ \+ state \* 50' "$TREE/target/linux/airoha" 2>/dev/null || true)
if [[ "$found" -eq 0 ]]; then
  echo "⚠ 树内未找到 'freq_mhz = <n> + state * 50'：6.18 下 PM domain 的 PLL 公式可能位于内核源码树（drivers/pmdomain/airoha）。" >&2
  echo "  处理（修复而非降级）：内核 prepare 后定位该行并同步为 $BASE + state * 50；首次构建请人工核验 (dmesg | grep -i freq)。" >&2
fi

# 3) 默认 governor → performance
if [[ -f "$CFG" ]]; then
  sed -i 's/^CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND=y$/# CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND is not set/; s/^# CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE is not set$/CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y/' "$CFG"
  echo "  governor 默认 → performance（$CFG）"
  touched "$CFG"
else
  echo "⚠ 无 $CFG——上游可能换配置文件名，请定位后补本步骤（见 FIXES.md OC 条目）。" >&2
fi

echo "---- 变更摘要："
(cd "$TREE" && git status --short -- "${TOUCHED[@]}" 2>/dev/null | sed 's/^/  /')
echo "完成。构建后请核对：cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq（应为 ${BASE}00000）"