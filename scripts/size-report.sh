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
	# 回退：本 target 的 .control 不存在（ci-118 实测），改从**已打包的 APK 包体**实测。
	# 说明：apk 的 .apk 是包体（含控制信息），用它给出的"包体积合计"是**上界参考**，
	# 不是 .manifest 的 Installed-Size 语义——所以这里如实标注口径。
	apk_dir=""
	for cand in "$BIN/packages" "$(dirname "$BIN")/packages"; do
		[[ -d "$cand" ]] && { apk_dir="$cand"; break; }
	done
	if [[ -n "$apk_dir" ]]; then
		# 只统计与**本次镜像同 target 的 feed 目录**，避免把全量 bin/packages 混进来
		total=0; n=0
		while IFS= read -r f; do
			sz=$(stat -c%s "$f" 2>/dev/null) || continue
			total=$((total + sz)); n=$((n + 1))
		done < <(find "$apk_dir" -name '*.apk' -type f 2>/dev/null)
		if (( n > 0 )); then
			echo "已打包组件：$n 个 APK，包体合计 $((total / 1048576)) MiB（$((total / 1024)) KiB）"
			echo "  ⚠ 口径：包体合计（APK 压缩后体积），**不是** .manifest 的 Installed-Size；"
			echo "    本 target 未产出 .control（ci-118 实测），故以此作上界参考。"
		else
			echo "已打包组件：$apk_dir 下无 .apk"
		fi
	else
		echo "已打包组件：无可用口径（$BIN/packages/*.control 不存在，且找不到 APK 目录）"
	fi
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

# ── 与基线对比（**必须在本函数写新基线之前**做，否则会拿自己跟自己比）──
# ci-118 实测教训：原实现先写基线、再读同一个文件 ⇒ 输出恒为 "Δ 0 B / 0.00%"、
# 且给出"刷机路径与上次相同"的**错误**结论。顺序即语义这里不能含糊。
cur="$(for f in $itbs; do stat -c%s "$f" 2>/dev/null; done | head -1)"
cur="${cur:-0}"

baseline_usable=0
prev=0
if [[ -n "$BASELINE" && -f "$BASELINE" ]]; then
	prev="$(awk -F= '/^sysupgrade_itb_bytes=/{print $2; exit}' "$BASELINE")"
	[[ "$prev" =~ ^[0-9]+$ ]] || prev=0
	(( prev > 0 )) && baseline_usable=1
fi

if (( baseline_usable )) && (( cur > 0 )); then
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
else
	# 没有可用基线时：**不得**给出"与上次相同"这类断言（那是无根据的结论），
	# 改为基于"本镜像是否还装得进旧 fit 卷"这个**已验证事实**给提示。
	echo
	if (( cur > 0 )) && (( cur > FIT_LEGACY )); then
		echo "== 无可用基线（本版为基线起点）=="
		echo "本镜像 ${cur} B 已 > 旧 fit 卷参考容量 $((FIT_LEGACY/1048576)) MiB。"
		echo "RELEASE_NOTE_HINT=本版镜像 $(( cur / 1048576 )) MiB，**大于旧 fit 卷容量** ⇒ 必须经 HTTP U-Boot 恢复页（192.168.255.1，布局选择器选 UBI 2.0）重刷；该路径会清空 overlay 与全部配置，刷前先备份 /etc/config。（本次无上一版基线可比，说明见 CI 日志。）"
	else
		echo "== 无可用基线（本版为基线起点，且镜像仍可装入旧 fit 卷）=="
		echo "RELEASE_NOTE_HINT=本版镜像 $(( cur / 1048576 )) MiB，仍可装入旧 fit 卷；本次无上一版基线可比。"
	fi
fi

# ── 写新基线（放在对比**之后**）──
if [[ -n "$WRITE" ]]; then
	mkdir -p "$(dirname "$WRITE")"
	{
		echo "# size-report 基线（$(date -u +%FT%TZ)）"
		echo "sysupgrade_itb_bytes=$cur"
		echo "installed_size_kib=$ctrl_kb"
	} > "$WRITE"
	echo
	echo "已写基线：$WRITE（供**下次**构建对比）"
fi

exit 0
