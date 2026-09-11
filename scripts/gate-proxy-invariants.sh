#!/usr/bin/env bash
# gate-proxy-invariants.sh — 代理/组网方案的**仓库级**不变量门禁（plan/00 §3 的 I1–I4）
#
# 为什么需要它（而不只是包内自测）：
#   scripts/test-proxy-package.sh 只盯 xr1710g-proxy 一个包；但破坏不变量最容易发生在
#   **别处**——一个 uci-defaults、一个补丁、一段 files/ 脚本都可能写 flow_offloading 或
#   reload fw4。本脚本扫全仓库，把 I1–I4 变成 CI 可红可绿的一条命令。
#
# 判据（任何一条红 = 打回）：
#   I1  `flow_offloading` 只允许出现在：只读展示 / 验收脚本 / 文档 / 补丁 / 基线证据
#   I2  proxy 相关代码不得出现 `firewall reload` / `/etc/init.d/firewall`
#   I3  任何 .nft 不得含 `table inet fw4`，不得含 `flow add`
#   I4  uci-defaults 不得 enable 服务、不得写 firewall/network 的 offload 字段
#
# 设计原则：**只扫代码行（剔除注释）**。模板/脚本的注释里**故意**引用了禁止字样
#   （如"本文件绝不出现 table inet fw4"），直接 grep 会假红 —— 第一版就踩过这个坑。
#
# 用法：scripts/gate-proxy-invariants.sh [--verbose]
# 退出码：0 全绿；1 有违规
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERBOSE=0
[[ "${1:-}" == "--verbose" ]] && VERBOSE=1

pass=0; fail=0
ok()  { echo "  ✓ $1"; pass=$((pass+1)); }
bad() { echo "  ✗ $1"; fail=$((fail+1)); }
note(){ [[ "$VERBOSE" == "1" ]] && echo "      $1"; return 0; }

# 剔除行内注释（# 之后）。注意：不处理字符串里的 #（对本用途足够，且宁可少剔除不可多剔除——
# 多剔除会造成**漏报**，这是门禁里更危险的失败方向；故这里只做保守的行内注释剔除）。
strip_comments_stream() { sed -e 's/[[:space:]]*#.*$//'; }

# 列出应受 I1/I2 约束的"代码文件"。
#
# ⚠️ 用**排除法**而不是包含法：本仓库的叠加层脚本大量**没有扩展名**
#   （files/etc/init.d/fan、files/etc/uci-defaults/99-xr1710g-flow-offload、
#     packages-*/files/etc/init.d/xr1710g-proxy ...）。
#   第一版用 `-name '*.sh'` 之类包含法 ⇒ **一个都没扫到**，门禁恒绿（假绿比假红危险得多）。
#   排除法只剔掉"确定不是代码"的：文档 / 证据 / 计划 / 研究 / 补丁 / 图片 / 基线数据。
code_files() {
	find files packages-xr1710g config scripts -type f \
		! -name '*.md' ! -name '*.po' ! -name '*.pot' ! -name '*.png' ! -name '*.jpg' \
		! -name '*.txt' ! -name '*.srs' ! -name '*.tgz' ! -name '*.diff' ! -name '*.patch' \
		2>/dev/null | sort
}

echo "== I1：flow_offloading 只许出现在只读展示/验收脚本（写路径出现即红） =="
# 允许清单：脚本文件名以这些结尾的，属"只读展示/验收"用途
I1_ALLOW_RE='/(device-.*probe|device-hw-probe|device-npu[^/]*|audit-[^/]*,|audit-[^/]*)\.sh$|(^|/)(verify-copy-patches|build|prepare-oc|apply-patches|audit-patches|sync-upstream|fetch-sources|fetch-cn-list|test-proxy-package|check-neon-crypto|gate-proxy-invariants)\.sh$'
# 第二个 allowlist：**仓库既有的** issue #7 用户态缓解文件。它不是代理方案的一部分，
# 且它的存在本身就是 issue #7 的处置（默认开 offload + 60s 防抖，见
# docs/analysis-issue7-flow-offload-reboot.md）。**刻意偏离 plan/04 T1-1 的字面范围**：
# 门禁守的是"代理方案不得把 offload 字段纳入自己的写入路径"，不是"删除既有 offload 默认"。
I1_ALLOW_PATH='files/etc/uci-defaults/99-xr1710g-flow-offload'
viol=""
while IFS= read -r f; do
	[[ -n "$f" ]] || continue
	# 只读展示脚本允许出现
	if [[ "$f" =~ $I1_ALLOW_RE ]]; then note "allowed(readonly/tooling): $f"; continue; fi
	if [[ "$f" == $I1_ALLOW_PATH ]]; then note "allowed(pre-existing issue#7 mitigation, 非代理方案): $f"; continue; fi
	# 写路径特征：赋值/写入/sed -i/uci set/echo > 等
	hit="$(strip_comments_stream < "$f" | grep -nE 'flow_offloading[[:space:]]*=|(uci[[:space:]]+set|sed[[:space:]]+-i|echo|printf|tee)[^|]*flow_offloading' | head -3)"
	if [[ -n "$hit" ]]; then
		viol="$viol
  $f: $(tr '\n' ';' <<<"$hit")"
	fi
done < <(code_files)
if [[ -n "$viol" ]]; then
	bad "存在 flow_offloading 写路径：$viol"
else
	ok "无 flow_offloading 写路径（只读展示/验收脚本除外）"
fi

echo "== I2：proxy 相关代码不得 reload fw4 =="
# 只扫**会执行的东西**：shell / nft / Makefile。**不扫** .js 与 .po/.pot ——
# 那些是给用户看的**说明文字**（如"fw4 reload 会重建硬件 flowtable"），
# 把它们算作违规是假红（第一版就踩了）。判据是"有没有执行 fw4"，不是"有没有提到 fw4"。
viol=""
while IFS= read -r f; do
	[[ -n "$f" ]] || continue
	hit="$(strip_comments_stream < "$f" | grep -nE 'firewall[[:space:]]+reload|/etc/init\.d/firewall|fw4[[:space:]]+reload' | head -3)"
	if [[ -n "$hit" ]]; then
		viol="$viol
  $f: $(tr '\n' ';' <<<"$hit")"
	fi
done < <(find packages-xr1710g/package/xr1710g-proxy packages-xr1710g/package/luci-app-xr1710g-proxy \
		-type f ! -name '*.js' ! -name '*.po' ! -name '*.pot' ! -name '*.md' 2>/dev/null | sort)
if [[ -n "$viol" ]]; then
	bad "proxy 代码触发 fw4：$viol"
else
	ok "proxy 的 shell/nft/Makefile 不含 firewall reload / fw4 reload（说明文字不计）"
fi

echo "== I3：任何 .nft 不得碰 fw4 / 不得含 flow add =="
viol=""
while IFS= read -r f; do
	[[ -n "$f" ]] || continue
	h1="$(strip_comments_stream < "$f" | grep -nE 'table[[:space:]]+inet[[:space:]]+fw4')"
	h2="$(strip_comments_stream < "$f" | grep -nE 'flow[[:space:]]+add')"
	[[ -n "$h1" ]] && viol="$viol
  $f: 含 table inet fw4 → $h1"
	[[ -n "$h2" ]] && viol="$viol
  $f: 含 flow add → $h2"
done < <(find . -name '*.nft' -not -path './.git/*' 2>/dev/null | sort)
if [[ -n "$viol" ]]; then
	bad "nft 文件违反 I3：$viol"
else
	ok "所有 .nft 均为独立表、不含 flow add"
fi

echo "== I4：proxy 的 uci-defaults 不得 enable 服务 / 不得写 firewall-network offload 字段 =="
# 范围界定（重要）：本门禁守的是**代理/组网方案**不得把 offload 字段纳入自己的写入路径。
# 仓库既有的 `99-xr1710g-flow-offload` 是 issue #7 的**既有**用户态缓解（默认开 offload，
# 见 docs/analysis-issue7-flow-offload-reboot.md），与代理方案无关，**不得**被本门禁误判。
# 因此显式 allowlist；allowlist 的每一项都是一条"已知且有意"的例外，改动需同步改注释。
I4_ALLOW='files/etc/uci-defaults/99-xr1710g-flow-offload|files/etc/uci-defaults/98-xr1710g-led-sysfs-prefix'
viol=""
while IFS= read -r f; do
	[[ -n "$f" ]] || continue
	if [[ "$f" =~ ^($I4_ALLOW)$ ]]; then note "allowed(pre-existing, 非代理方案): $f"; continue; fi
	body="$(strip_comments_stream < "$f")"
	# 禁：enable 调用（允许读 enabled 配置项，但不允许 /etc/init.d 或 rpcd enable 调用）
	h1="$(grep -nE '/etc/init\.d/[A-Za-z0-9_.-]+[[:space:]]+enable|(^|[[:space:]])enable([[:space:]]|$)' <<<"$body" | grep -v 'enabled' | head -3)"
	# 禁：写 firewall/network 的 offload 字段
	h2="$(grep -nE 'uci[[:space:]]+(-q[[:space:]]+)?set[[:space:]]+(firewall|network)\.' <<<"$body" | head -3)"
	[[ -n "$h1" ]] && viol="$viol
  $f: enable 调用 → $h1"
	[[ -n "$h2" ]] && viol="$viol
  $f: 写 firewall/network → $h2"
done < <(find files packages-xr1710g -path '*uci-defaults*' -type f 2>/dev/null | sort)
if [[ -n "$viol" ]]; then
	bad "uci-defaults 违反 I4：$viol"
else
	ok "uci-defaults 只写默认值，不 enable 任何服务、不碰 firewall/network"
fi

echo "== 附加：默认关闭（G4） =="
# 代理总开关必须默认 0（预装但默认不启用）
if grep -qE "^[[:space:]]*option enabled '0'" packages-xr1710g/package/xr1710g-proxy/files/etc/config/xr1710g_proxy 2>/dev/null; then
	ok "xr1710g-proxy 默认 enabled=0"
else
	bad "xr1710g-proxy 默认不是 enabled=0 —— 违反 G4「默认关闭」"
fi
# 任何 init.d 不得被 seed 显式 enable（seed 里不应出现 rc.d 链接需求）
if grep -rnE 'xr1710g-proxy.*enable|enable.*xr1710g-proxy' config/seed-config.diff 2>/dev/null | grep -v '^.*#' | head -3 | grep -q .; then
	bad "seed-config.diff 中出现 enable xr1710g-proxy"
else
	ok "seed-config.diff 未 enable 任何代理服务"
fi

echo
echo "结果：$pass 通过 / $fail 失败"
[[ "$fail" == "0" ]]
