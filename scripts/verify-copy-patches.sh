#!/usr/bin/env bash
# verify-copy-patches.sh — 拷贝类（packages）补丁的真实应用校验（F20 教训制度化，2026-08-17）
# 用法：verify-copy-patches.sh <openwrt树目录> [--oc] [--no-download]
#
# 背景（F20/F21，2026-08-17）：MANIFEST 中目标为"拷贝目录"的补丁（regdb/mt76 等）由 OpenWrt
#   构建时在解包后的包源码上以 `patch -p1` 应用；apply-patches.sh --dry-run 此前只校验目标
#   目录存在性、从不真实应用——regdb-0500 重复供给与 regdb-0555 上下文漂移（wireless-regdb
#   2026.05.30）就是这样漏掉的，三档构建首次真红才暴露（F20）。同型盲区再次放走 F21：
#   ROOT 补丁 9002 生成的 uboot 包补丁（命名 1000- 的 glob 序错误 + 内层缺 `+++ b/` 行 +
#   外层 hunk 行数未同步）在构建时应用失败——本脚本同样按构建语义真实校验派生包补丁。
#
# 做法：对每个拷贝目标，**完全复刻构建语义**——
#   1) 从树内包 Makefile 派生源码 tarball（单一事实源：PKG_VERSION / PKG_SOURCE_VERSION
#      随上游版本漂移自动跟进，不另设手工 pin，杜绝第二真相源）；
#   2) 下载（缓存于 $COPY_PATCH_CACHE，缺省 ${TMPDIR:-/tmp}/copy-patch-verify）并解包；
#   3) 组装临时补丁目录 = 树内该包已有补丁（如 regdb 的 500-world-regd-5GHz.patch / uboot 的
#      100-999 系列，构建时与本层拷贝共存）+ 本层 MANIFEST 补丁（同名拷贝）——应用顺序与
#      构建相同：shell glob 排序（实测 500-… < regdb-05xx-…；"1000-" 会排在 "100-" 与 "101-"
#      之间——F21 教训，命名必须校验 glob 序）；
#   4) 用树内自带的 scripts/patch-kernel.sh（= 构建 KPATCH）`patch -f -p1` 真实应用；
#   5) 逐包可选校验（regdb：dbparse.py db.txt 语法/语义）。
# 派生目标：ROOT 补丁生成的包补丁文件（如 9002 → package/boot/uboot-airoha/patches/9990-…）
#   在 dry-run 应用 ROOT 补丁后已存在于树内——作为额外 dest 注册（DERIVED_DESTS），与上游
#   补丁同目录 glob 应用校验（F21 制度化）。
#
# 策略：
#   - 应用/校验失败 = 退出非零（红）：sync-upstream 2h cron 尽早暴露，而不是等构建；
#   - 下载失败 = ⚠ 未校验（警告不红）：F19 教训——瞬时网络问题不应假红，构建对下载失败
#     有重试语义，拷贝补丁最终由真实构建兜底（构建应用失败即红，天然成立）。
set -euo pipefail

TREE=""; OC=0; NODL=0; EXP=0
for a in "$@"; do
  case "$a" in
    --oc) OC=1 ;;
    --experimental) EXP=1 ;;
    --no-download) NODL=1 ;;
    *) TREE="$a" ;;
  esac
done

[[ -n "$TREE" && -d "$TREE/.git" ]] || { echo "错误：需要 openwrt 树目录（含 .git），如 ../openwrt" >&2; exit 1; }
command -v patch  >/dev/null || { echo "错误：缺 patch 命令（apt install patch）" >&2; exit 1; }
command -v tar    >/dev/null || { echo "错误：缺 tar" >&2; exit 1; }
command -v curl   >/dev/null || { echo "错误：缺 curl" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/patches/MANIFEST"
[[ -f "$MANIFEST" ]] || { echo "错误：找不到 $MANIFEST" >&2; exit 1; }
KPATCH="$TREE/scripts/patch-kernel.sh"
[[ -f "$KPATCH" ]] || { echo "错误：找不到 $KPATCH（openwrt 树缺少构建补丁脚本？）" >&2; exit 1; }

CACHE="${COPY_PATCH_CACHE:-${TMPDIR:-/tmp}/copy-patch-verify}"
mkdir -p "$CACHE"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/copy-patch-verify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ── 解析 MANIFEST：收集 (dest, 补丁绝对路径) 有序列表，仅活动行（--oc 时含 #OC 行）──
entries=()
dests=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%"${line##*[![:space:]]}"}"   # rtrim
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
  dest="${line##*[[:space:]]}"; dest="${dest%/}"
  [[ "$dest" == "ROOT" ]] && continue
  entries+=("$dest|$ROOT/$src")
  case " ${dests[*]} " in *" $dest "*) ;; *) dests+=("$dest");; esac
done < "$MANIFEST"

# 派生包补丁目标（F21 制度化）：补丁文件由 ROOT 补丁生成于树内（如 9002 → uboot patches），
# dry-run 应用 ROOT 补丁后已存在——与上游补丁同目录 glob 真实应用校验（无需 MANIFEST 条目）。
# 注意：verify 必须在 dry-run 的 git reset 之前调用（apply-patches.sh 已保证），否则文件已被回滚。
DERIVED_DESTS="package/boot/uboot-airoha/patches"
for d in $DERIVED_DESTS; do
  if [[ -d "$TREE/$d" ]] && compgen -G "$TREE/$d/*" >/dev/null; then
    case " ${dests[*]} " in *" $d "*) ;; *) dests+=("$d");; esac
  fi
done

[[ ${#entries[@]} -eq 0 && ${#dests[@]} -eq 0 ]] && { echo "（无拷贝类/派生补丁条目）"; exit 0; }

fail=0; checked=0; unverified=0; src_n=0
declare -A SRCDIR PKGDIR SKIPPED

# 准备包源码（下载+解包）。结果存全局：SRCDIR[dest]=源码根 / PKGDIR[dest]=包目录；
# 跳过时置 SKIPPED[dest] 并计 unverified。返回 0=就绪，1=跳过（不经过子 shell，数组直写）。
prep_src() {
  local dest="$1"
  [[ -n "${SRCDIR[$dest]:-}" ]] && return 0
  [[ -n "${SKIPPED[$dest]:-}" ]] && return 1

  local pkgdir="" url="" url_fb="" file="" subdir="" validator=""
  case "$dest" in
    */wireless-regdb/patches)
      pkgdir="package/firmware/wireless-regdb"
      local v; v="$(awk -F':=' '/^PKG_VERSION:=/{print $2; exit}' "$TREE/$pkgdir/Makefile")"
      if [[ -z "$v" ]]; then echo "⚠ [verify] $pkgdir 缺 PKG_VERSION——跳过 $dest" >&2; SKIPPED[$dest]=1; unverified=$((unverified+1)); return 1; fi
      file="wireless-regdb-$v.tar.xz"
      url="https://cdn.kernel.org/pub/software/network/wireless-regdb/$file"   # @KERNEL 令牌 = cdn.kernel.org/pub
      subdir="wireless-regdb-$v"
      ;;
    */mt76/patches)
      pkgdir="package/kernel/mt76"
      local sv; sv="$(awk -F':=' '/^PKG_SOURCE_VERSION:=/{print $2; exit}' "$TREE/$pkgdir/Makefile")"
      if [[ -z "$sv" ]]; then echo "⚠ [verify] $pkgdir 缺 PKG_SOURCE_VERSION——跳过 $dest" >&2; SKIPPED[$dest]=1; unverified=$((unverified+1)); return 1; fi
      file="mt76-$sv.tar.gz"
      url="https://github.com/openwrt/mt76/archive/$sv.tar.gz"
      subdir="mt76-$sv"
      ;;
    */uboot-airoha/patches)
      # 派生目标（F21）：补丁文件由 ROOT 补丁 9002 生成于树内；源码取包 Makefile 版本
      pkgdir="package/boot/uboot-airoha"
      local v; v="$(awk -F':=' '/^PKG_VERSION:=/{print $2; exit}' "$TREE/$pkgdir/Makefile")"
      if [[ -z "$v" ]]; then echo "⚠ [verify] $pkgdir 缺 PKG_VERSION——跳过 $dest" >&2; SKIPPED[$dest]=1; unverified=$((unverified+1)); return 1; fi
      file="u-boot-$v.tar.bz2"
      url="https://mirror.cyberbits.eu/u-boot/$file"
      url_fb="https://ftp.denx.de/pub/u-boot/$file"   # 包 Makefile PKG_SOURCE_URL 镜像列表
      subdir="u-boot-$v"
      ;;
    *)
      echo "⚠ [verify] 未知拷贝目标 $dest——跳过（如需校验，请在本脚本登记包源映射）" >&2
      SKIPPED[$dest]=1; unverified=$((unverified+1)); return 1
      ;;
  esac

  local tarball="$CACHE/$file"
  if [[ -f "$tarball" ]]; then
    # 缓存文件可能是上次失败留下的错误页（如 429 HTML）——tar 探测不过即重下
    if ! tar -tf "$tarball" >/dev/null 2>&1; then
      echo "⚠ [verify] 缓存损坏（$file）——删除重下" >&2
      rm -f "$tarball"
    fi
  fi
  if [[ ! -f "$tarball" ]]; then
    if (( NODL )); then
      echo "⚠ [verify] --no-download 且无缓存 $file——跳过 $dest（未校验）" >&2
      SKIPPED[$dest]=1; unverified=$((unverified+1)); return 1
    fi
    echo "  ⤓ 下载 $url" >&2
    if ! curl -fsSL --retry 3 -o "$tarball" "$url"; then
      # 后备镜像（uboot 等有多镜像包）
      if [[ -n "${url_fb:-}" ]] && curl -fsSL --retry 3 -o "$tarball" "$url_fb"; then
        :
      else
        rm -f "$tarball"
        echo "⚠ [verify] 下载失败：$url${url_fb:+ / $url_fb}——跳过 $dest（未校验；构建时会真实应用，下载失败有重试语义）" >&2
        SKIPPED[$dest]=1; unverified=$((unverified+1)); return 1
      fi
    fi
    if ! tar -tf "$tarball" >/dev/null 2>&1; then
      rm -f "$tarball"
      echo "⚠ [verify] 下载内容无效：$file——跳过 $dest（未校验）" >&2
      SKIPPED[$dest]=1; unverified=$((unverified+1)); return 1
    fi
  fi

  local n="$src_n"          # 顺序计数器（跳过项不占位，目录名允许稀疏）
  src_n=$((src_n+1))
  local srcdir="$WORK/src-$n"
  mkdir -p "$srcdir"
  if ! tar -C "$srcdir" -xf "$tarball"; then
    echo "⚠ [verify] 解包失败：$tarball——跳过 $dest" >&2
    SKIPPED[$dest]=1; unverified=$((unverified+1)); return 1
  fi
  SRCDIR[$dest]="$srcdir/$subdir"
  PKGDIR[$dest]="$pkgdir"
  # 解包后必须出现期望源码目录——空包/错包（如限流中间件返回 200 空 gzip）在此拦截并弃缓存
  if [[ ! -d "${SRCDIR[$dest]}" ]]; then
    echo "⚠ [verify] 解包后未找到源码目录 $subdir（$tarball 内容异常）——删除缓存并跳过 $dest（未校验）" >&2
    rm -f "$tarball"
    SKIPPED[$dest]=1; unverified=$((unverified+1)); return 1
  fi
  return 0
}

# ── 逐 dest：准备源码 → 组装补丁目录（树内已有 + 本层）→ patch-kernel.sh 真实应用 ──
for dest in "${dests[@]}"; do
  prep_src "$dest" || continue   # 跳过项已计 unverified
  srcdir="${SRCDIR[$dest]}"

  pdir="$WORK/patch-${PKGDIR[$dest]//\//_}"
  mkdir -p "$pdir"
  # 树内该包已有补丁（真实构建时与本层拷贝共存于同一 patches/ 目录，glob 一并排序；
  # mt76 在 master 无 patches/ 目录则跳过）
  if [[ -d "$TREE/${PKGDIR[$dest]}/patches" ]]; then
    cp "$TREE/${PKGDIR[$dest]}/patches/"* "$pdir/" 2>/dev/null || true
  fi
  # 本层补丁（MANIFEST 顺序拷贝，与构建的 copy 步骤一致）
  for entry in "${entries[@]}"; do
    [[ "${entry%%|*}" == "$dest" ]] && cp -f "${entry#*|}" "$pdir/"
  done

  echo "▶ [verify] $dest（$srcdir）"
  kout="$WORK/kpatch-${dest//\//_}.out"
  if PATCH=patch "$KPATCH" "$srcdir" "$pdir" >"$kout" 2>&1; then
    checked=$((checked+1))
    echo "  ✓ [verify] 全部补丁真实应用成功（patch -f -p1，glob 顺序，$(ls "$pdir" | wc -l) 个文件）"
  else
    echo "✗ [verify] 拷贝补丁应用失败：$dest" >&2
    echo "            失败信息（构建同款 KPATCH 输出）：" >&2
    tail -n 8 "$kout" | sed 's/^/    /' >&2
    echo "            F20 教训：拷贝类补丁必须真实应用验证——按包源码当前状态重建对应补丁" >&2
    fail=1
    continue
  fi

  # 逐包校验
  case "$dest" in
    */wireless-regdb/patches)
      if (cd "$srcdir" && python3 dbparse.py db.txt >/dev/null 2>&1); then
        echo "  ✓ [verify] regdb 校验：dbparse.py db.txt 通过"
      else
        echo "✗ [verify] regdb 校验失败：dbparse.py db.txt（$srcdir）" >&2
        fail=1
      fi
      ;;
  esac
done

echo "----"
echo "拷贝补丁校验：真实应用 $checked  未校验/跳过 $unverified"
[[ "$fail" -gt 0 ]] && { echo "拷贝类补丁校验失败——见上方 ✗（修复而不是降级）" >&2; exit 1; }
exit 0
