#!/usr/bin/env bash
# size-report.sh — 固件体积自检（plan/00 §4.5）
#
# 背景：`fit` 只读卷的尺寸**由 HTTP U-Boot 恢复页在上传镜像时按镜像大小自动决定**
# （ADR-0004），所以本仓库**不硬编码容量常数**。但有一个必须提前预警的后果：
#   上一次刷机把 `fit` 卷定死在当时的镜像大小；本版镜像**变大**后，
#   in-OS `sysupgrade` 会失败（`ubiupdatevol` 写不下），只能走恢复页重刷 —— **而恢复页会清空 overlay**。
#   ⇒ 镜像变大时必须让用户在下载前就知道"这版要经恢复页、请先备份 /etc/config"。
#
# 用法：
#   size-report.sh <bin/targets/airoha/an7581> [基线 .manifest 或 baseline.txt]
#   size-report.sh ... --write-baseline <文件>
#
# 输出：Installed-Size 汇总、itb 实际大小、`fit` 卷容量参考、与基线对比结论；
#       建议写进 release notes 的文案输出到 stdout 末段。
set -uo pipefail

BIN="${1:-}"
shift || true
BASELINE=""
WRITE=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--write-baseline) WRITE="$2"; shift 2 ;;
		*) BASELINE="$1"; shift ;;
	esac
done

[[ -n "$BIN" && -d "$BIN" ]] || { echo "用法：$0 <bin/targets/airoha/an7581> [基线 manifest|baseline.txt] [--write-baseline <file>]" >&2; exit 2; }

# ── fit 卷容量参考值（来自实机 ubinfo，仅作**参考**，不是构建约束）──
FIT_LEB=206           # 旧布局：206 LEB
LEB_BYTES=126976      # 124.0 KiB
FIT_LEGACY=$((FIT_LEB * LEB_BYTES))

itbs="$(ls "$BIN"/*-sysupgrade.itb 2>/dev/null)"

echo "== 固件体积自检 =="
echo "产物目录：$BIN"

# Installed-Size 汇总：优先用 .control（OpenWrt 打包会产出），否则回退到 manifest 行数
# Installed-Size 汇总：buildroot 在 bin/targets/<t>/<s>/packages/ 下产 .control；
# 不存在时如实说"未能汇总"，不假装有数（`<pkg>.manifest` 里没有尺寸）。
ctrl_count=0; ctrl_kb=0
if [[ -d "$BIN/packages" ]]; then
	while IFS= read -r c; do
		sz="$(awk -F': *' '/^Installed-Size:/{print $2; exit}' "$c" 2>/dev/null)"
		[[ "$sz" =~ ^[0-9]+$ ]] || continue
		ctrl_kb=$((ctrl_kb + sz)); ctrl_count=$((ctrl_count + 1))
	done < <(find "$BIN/packages" -name '*.control' -type f 2>/dev/null)
fi

if [[ "$ctrl_count" -gt 0 ]]; then
	echo "已打包组件：$ctrl_count 个，Installed-Size 合计 $((ctrl_kb / 1024)) MiB（$ctrl_kb KiB）"
else
	echo "已打包组件：未能汇总 Installed-Size（$BIN/packages/*.control 不存在）"
fi

for f in $itbs; do
	[[ -f "$f" ]] || continue
	sz=$(stat -c%s "$f")
	printf "sysupgrade.itb：%s = %d B = %.2f MiB\n" "$(basename "$f")" "$sz" "$(awk -v b="$sz" 'BEGIN{print b/1048576}')"
	# fit 卷参考余量
	if [[ "$sz" -gt "$FIT_LEGACY" ]]; then
		echo "  ⚠ 该镜像 > 旧 fit 卷参考容量（$FIT_LEB LEB = $((FIT_LEGACY/1048576)) MiB）"
		echo "    ⇒ 旧布局设备上的 in-OS sysupgrade 会失败；**本版必须经 HTTP U-Boot 恢复页重刷**"
		echo "    ⇒ 恢复页路径会移除 rootfs_data 卷，**overlay 与全部配置被清空**：刷前先备份 /etc/config！"
	else
		echo "  ✓ 仍可装入旧 fit 卷参考容量（$((FIT_LEGACY/1048576)) MiB）"
	fi
done

# ── 与基线对比 ──
cur="$(for f in $itbs; do stat -c%s "$f" 2>/dev/null; done | head -1)"
cur="${cur:-0}"
if [[ -n "$WRITE" ]]; then
	mkdir -p "$(dirname "$WRITE")"
	{
		echo "# size-report 基线（$(date -u +%FT%TZ)）"
		echo "sysupgrade_itb_bytes=$cur"
		echo "installed_size_kib=$ctrl_kb"
	} > "$WRITE"
	echo "已写基线：$WRITE"
fi

if [[ -n "$BASELINE" && -f "$BASELINE" ]]; then
	prev="$(awk -F= '/^sysupgrade_itb_bytes=/{print $2; exit}' "$BASELINE")"
	prev="${prev:-0}"
	if [[ "$prev" -gt 0 && "$cur" -gt 0 ]]; then
		delta=$((cur - prev))
		pct=$(awk -v a="$prev" -v b="$cur" 'BEGIN{printf "%.2f", (b-a)*100/a}')
		echo
		echo "== 与上一版对比 =="
		echo "上一版 $prev B → 本版 $cur B（Δ $delta B / $pct%）"
		if [[ "$delta" -gt 0 ]]; then
			echo "RELEASE_NOTE_HINT=本版镜像比上一版大 ${delta} B（+${pct}%）。若本机 fit 卷是上次刷机定死的，in-OS sysupgrade 可能写不下——**本版需经 HTTP U-Boot 恢复页（192.168.255.1，布局选择器选 UBI 2.0）重刷**；该路径会清空 overlay 与全部配置，请先备份 /etc/config。"
		elif [[ "$delta" -eq 0 ]]; then
			echo "RELEASE_NOTE_HINT=本版镜像与上一版等大，刷机路径与上次相同。"
		else
			echo "RELEASE_NOTE_HINT=本版镜像比上一版小 $(( -delta )) B，刷机路径无变化。"
		fi
	fi
else
	echo
	echo "（未提供基线 ⇒ 跳过对比。下次构建可用 --write-baseline 建立基线。）"
fi

exit 0
