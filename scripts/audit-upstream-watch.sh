#!/usr/bin/env bash
# audit-upstream-watch.sh — 上游基线守护（只读、确定性）
# 用法：audit-upstream-watch.sh <openwrt树目录> [--fail-on-drift]
#
# 背景（2026-09-11 深度调研，2026-09-12 扩面）：
# 本仓多个补丁的**内层补丁基线**是上游的具体文件，上游改动它们时**不会**让 dry-run 变红
# （拷贝类/内层补丁不在 dry-run 覆盖内），却会让补丁在**构建期**才失败。典型两类：
#   ① 上游改 `generic/pending-6.18/742|743`（realtek PHY）→ 本仓 9041/9033 需重基
#      （PR #25092 / #24887 都在改这两个 blob）
#   ② 上游往 `generic/hack-6.18/` 加 744/745 与私有驱动目录同址/同号 → 与
#      `vendor/fanboy/09` 携带的私有 `rtl8261ce/` 驱动**功能重复**（PR #23644、25.12
#      backport #25092）。注意 #23644 实测落在 **hack**-6.18，不是 pending-6.18。
#
# 本脚本用 **git blob SHA** 精确比对"本仓补丁所基于的上游文件版本"，并用**路径存在性探测**
# 发现"上游即将/已经引入同址文件"。比"等 dry-run 红"更早、比"人工比对"更确定。
#
# 报告分三类（含义不同，不可混为"漂移"）：
#   [基线]   基线 blob SHA 不一致 → 本仓对应补丁需重基
#   [冲突]   上游已出现与本仓新增文件同址/同前缀的文件 → 需人工判"去重/改号/删除本地"
#   [缺失]   基线路径在上游消失（改名/删除）→ 需重定位
#
# 行为：默认只报告（exit 0）；`--fail-on-drift` 时 缺失/冲突/漂移 任一即 exit 1（CI 用）。
set -euo pipefail

TREE=""; FAIL_ON_DRIFT=0
for a in "$@"; do
  case "$a" in
    --fail-on-drift) FAIL_ON_DRIFT=1 ;;
    *) TREE="$a" ;;
  esac
done
[[ -n "$TREE" && -d "$TREE/.git" ]] || { echo "用法：audit-upstream-watch.sh <openwrt树目录> [--fail-on-drift]" >&2; exit 1; }

# 基线锚点：本表建立时所依据的上游 main。仅用于报告可读性（判断"是上游真改了还是基线该刷新"）。
BASELINE_UPSTREAM="f0d3e332e5f839508f77fba8c7420ceeb079ab86"   # openwrt main @ 2026-09-11 19:25Z
BASELINE_DATE="2026-09-12"
# 上游 bump 时**有意**更新上面两行 + 下表 SHA（生成方式：`git rev-parse HEAD:<path>`）。

# [基线] <blob-sha|-> <上游路径> <受影响的本仓补丁>
#   `-` = 该路径当前**不应存在**；一旦出现即视为上游已引入（等价 [冲突]）。
BASELINE=(
  "b7ace2329055f96346036579f329ef2f06dc19e4 target/linux/generic/pending-6.18/742-net-phy-realtek-add-5G-and-10G-PHY-support.patch    root/9041(内层742/743/744)、root/9033(LED hack)"
  "379da970e4c8b6c5329c9f0e1c8fe30ff9a784f3 target/linux/generic/pending-6.18/743-net-phy-realtek-reset-RTL8261N-USXGMII-SerDes-on-lin.patch  root/9041(内层742/743/744)"
  "b379ad09a5740990b3722cfbe6b20232db970767 package/kernel/mt76/Makefile    mt76 包补丁族（0001-0014/9990-9993）与 pin 跟踪"
  "a154aa9b7c8ecd6345476a0c08e11dcc44ec0b09 target/linux/airoha/an7581/config-6.18    root/9001、root/602-04 系列（airoha 目标 Kconfig/config 联动）"
  "14e28682fd40fc7ac9bb87fcbe59617fd8a9ff78  target/linux/airoha/image/an7581.mk    root/9001(DTS/image)、上游 #24926(DT overlay)"
  "5db35c03e2d08d634eeebf963d2cbdc1dcde15b4 package/boot/uboot-airoha/Makefile    root/9002(U-Boot 锁版)、上游 #24926"
)

# [冲突] 路径存在性探测（glob）：上游一旦命中，说明与"本仓自带的新文件"同址/同前缀。
# 格式：<glob 模式> <本仓对应物> <处置提示>
COLLISION_PROBES=(
  "target/linux/generic/hack-6.18/744-*|vendor/fanboy/09(hack-6.18/999-net-phy-realtek-rtl8261ce.patch)|#23644 的 744 已进上游 → 与本地 999 同号同目录，需改号或删除本地"
  "target/linux/generic/hack-6.18/745-*|vendor/fanboy/09(hack-6.18/999-net-phy-realtek-rtl8261ce.patch)|#23644 的 745 已进上游 → 主线 realtek 驱动已含 RTL8261CE，进入'私有驱动去留'二选一"
  "target/linux/generic/pending-6.18/743-0*|root/9041(内层742/743/744)、vendor/fanboy/09|#23644 的 743-01..04(c45 soft_reset/master_slave + RTL8261C-CG) 已进上游"
  "target/linux/generic/pending-6.18/744-*|root/9041(内层742/743/744)、root/9033|#25092 的 744 已进上游"
  "target/linux/generic/pending-6.18/745-*|root/9041(内层742/743/744)、root/9033|#25092 的 745 已进上游"
  "target/linux/generic/files/drivers/net/phy/rtl8261ce/*|vendor/fanboy/09(私有 rtl8261ce/ 驱动 4 文件)|上游已占用 rtl8261ce/ 目录 → 本地私有驱动与主线重复"
  "target/linux/airoha/dts/*.dtso|root/9001(DTS)|上游 #24926 引入 DT overlay 设备树 → 复核 9001 的 DTS 引用方式"
)

# 上游 realtek 主驱动内是否出现 RTL8261CE 支持（文本级探测；#23644 的实质落点）
REALTEK_MAIN_PATCH="target/linux/generic/pending-6.18/742-net-phy-realtek-add-5G-and-10G-PHY-support.patch"
REALTEK_CE_MARKERS="RTL_8261CE|8261CE_REV_C|0x001cc899"

drift=0; miss=0; collide=0
# 取上游"提交"与"工作区"两个视图：
#   · 提交视图（ls-tree）用于 CI 的干净检出 + 本仓 overlay 场景
#   · 工作区视图（ls-files --cached --others）用于本地树/被 rsync 修改过的树
# 两者取并集，避免"文件在磁盘上但未提交"被误判为未出现。
UPSTREAM_HEAD=$( (cd "$TREE" && git rev-parse HEAD 2>/dev/null) || echo UNKNOWN )
PATH_LIST=$(
  {
    (cd "$TREE" && git ls-tree -r --name-only HEAD 2>/dev/null) || true
    (cd "$TREE" && git ls-files --cached --others --exclude-standard 2>/dev/null) || true
  } | sort -u
)

echo "== 上游基线守护（blob SHA 精确比对 + 同址冲突探测）=="
echo "   上游 HEAD   : ${UPSTREAM_HEAD:0:9}"
echo "   基线锚点    : ${BASELINE_UPSTREAM:0:9}（${BASELINE_DATE} 建立）"
if [[ "$UPSTREAM_HEAD" != "$BASELINE_UPSTREAM" ]]; then
  echo "   ⓘ 上游已前进（${BASELINE_UPSTREAM:0:9} → ${UPSTREAM_HEAD:0:9}）：若下方全 ✓，说明本次前进未触碰被监视面，基线可择机刷新"
fi
echo

for row in "${BASELINE[@]}"; do
  want=$(echo "$row" | awk '{print $1}')
  path=$(echo "$row" | awk '{print $2}')
  who=$(echo "$row" | awk '{print $3}')
  # 注意：必须**先判存在性**。在已删除（但可能仍被引用）的工作区文件上，
  # `git rev-parse HEAD:<path>` 仍会返回 blob 而不报错 → 会把"文件不在树上"误判为"未变"。
  if [[ ! -e "$TREE/$path" ]]; then
    ref="MISSING"; got="MISSING"
  else
    ref=$( (cd "$TREE" && git rev-parse "HEAD:$path" 2>/dev/null) || echo MISSING )
    # 工作区优先：文件在磁盘上被改动（含本仓 overlay rsync 覆盖）时以磁盘内容为准，
    # 否则"改了文件但没 git add"会被漏报为未漂移。
    got=$( (cd "$TREE" && git hash-object -- "$path" 2>/dev/null) || echo MISSING )
  fi
  if [[ "$want" == "-" ]]; then
    if [[ "$got" != "MISSING" && "$ref" != "MISSING" ]]; then
      echo "  ⚠ [冲突] 上游已出现：$path（受影响：$who）"
      collide=$((collide+1))
    else
      echo "  ✓ [基线] 未出现（预期）：$path"
    fi
  elif [[ "$got" == "MISSING" || "$ref" == "MISSING" ]]; then
    # 区分两件事：
    #   · HEAD 里也没有 → 上游真的删了/改名了（需重定位，硬失败）
    #   · HEAD 里有、只是磁盘没有 → 本仓 overlay 未落位 / 树上缺文件（同样要处理）
    echo "  ✗ [缺失] $path（HEAD=${ref:0:9}，工作区=缺失：上游删除/改名，或本仓 overlay 未落位。受影响：$who）" >&2
    miss=$((miss+1))
  elif [[ "$got" != "$want" ]]; then
    echo "  ⚠ [基线] 漂移：$path"
    echo "      期望 $want"
    echo "      实际 $got"
    echo "      → 受影响补丁需重基：$who"
    drift=$((drift+1))
  else
    echo "  ✓ [基线] 未变：$path"
  fi
done

echo
echo "-- 同址冲突探测（上游是否已引入与本仓自带新文件重复的东西）--"
for row in "${COLLISION_PROBES[@]}"; do
  pat="${row%%|*}"; rest="${row#*|}"; who="${rest%%|*}"; hint="${rest#*|}"
  hits=$(printf '%s\n' "$PATH_LIST" | grep -E "$(printf '%s' "$pat" | sed 's/[.[\*^$]/\\&/g; s/\\\*/.*/g')" || true)
  if [[ -n "$hits" ]]; then
    echo "  ⚠ [冲突] 上游命中 $pat"
    echo "$hits" | sed 's/^/        /'
    echo "      本仓对应物：$who"
    echo "      处置：$hint"
    collide=$((collide+1))
  else
    echo "  ✓ [冲突] 上游未出现：$pat"
  fi
done

# 文本级：主线 realtek 驱动是否已含 RTL8261CE（#23644 实质）
echo
echo "-- 主线 realtek 驱动 CE 支持探测（文本级）--"
if [[ -f "$TREE/$REALTEK_MAIN_PATCH" ]]; then
  # 工作区优先（overlay/本地树内容可能已被改动）
  if grep -qE "$REALTEK_CE_MARKERS" "$TREE/$REALTEK_MAIN_PATCH" 2>/dev/null; then
    echo "  ⚠ [冲突] $REALTEK_MAIN_PATCH 已含 RTL8261CE 标记（$REALTEK_CE_MARKERS）"
    echo "      → 主线已覆盖 RTL8261CE；本仓 vendor/fanboy/09 私有 rtl8261ce/ 驱动进入去留决策"
    echo "      → 参考：本机 10G PHY 实测 c45 0x001ccaf3 = RTL_8261N，主线 742 已支持（rtl8261be/n match）"
    collide=$((collide+1))
  else
    echo "  ✓ [冲突] $REALTEK_MAIN_PATCH 尚不含 RTL8261CE 标记"
  fi
else
  echo "  ⓘ [基线] $REALTEK_MAIN_PATCH 不在上游（已被上游改写/合并？）"
fi

echo "----"
echo "汇总：基线漂移 $drift，路径缺失 $miss，同址冲突 $collide（基线锚点 ${BASELINE_UPSTREAM:0:9}）"
if (( miss > 0 || collide > 0 || (FAIL_ON_DRIFT && drift > 0) )); then
  echo "处理（修复而非降级）：" >&2
  echo "  · 基线漂移 → 按 docs/absorptions/ 最新吸收计划重基本仓补丁" >&2
  echo "  · 同址冲突 → 进入'去重/改号/删除本地'判据（RTL8261CE 见 2026-09-12 调研报告 §五）" >&2
  echo "  · 复跑验证：./scripts/apply-patches.sh . --dry-run --oc --experimental" >&2
  exit 1
fi
exit 0
