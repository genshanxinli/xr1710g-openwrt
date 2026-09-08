# DNS Phase 0 静态审计记录（2026-09-08）

> 审计对象：DNS Phase 0（mosdns 主推线）新增/改动文件
> 审计类型：脚本语法核验 + mosdns config.yaml 结构与断言核验
> 审计环境：本地宿主（node v26.8.1 + yaml 包；bash）
> 关联：`feeds.custom.conf` / `seed-config.diff` / `files/etc/uci-defaults/96,97` / `files/etc/mosdns/config.yaml` 的静态面；锁源/范围/镜像哈希见同组后续小类记录。

## 1. 脚本语法核验（bash -n）

新增/改动 shell 脚本（本任务仅 2 个）：

```
## bash -n（新增/改动脚本：本任务仅 2 个）
PASS  files/etc/uci-defaults/96-xr1710g-dns-firewall
PASS  files/etc/uci-defaults/97-xr1710g-dns-mosdns
```

结果：**2/2 PASS，零错误**。

## 2. mosdns config.yaml 断言清单（节点解析 + 逐条断言）

解析器：node `yaml` 包（YAML.parse）。输出原文：

```
A1 国内组=阿里+腾讯 DoH 双上游 -> PASS
A2 国外组=DoT 8.8.8.8+1.1.1.1 -> PASS
A3 国外超时降级→国内组(threshold=1000,triggers=timeout) -> PASS
A4 geosite:cn→国内组 -> PASS
A5 lazy_cache(size=4096,ttl=86400) -> PASS
A6 fakeip 池 198.18.0.0/16 且 sequence 不引用 -> PASS
A7 监听 127.0.0.1:5353 (udp+tcp,entry=main) -> PASS
A8 无落盘/数据目录配置 -> PASS
SUMMARY: ALL PASS (8/8)
```

| # | 断言（概念→证据） | 结果 |
|---|---|---|
| A1 | 国内组 = `https://dns.alidns.com/dns-query` + `https://doh.pub/dns-query`（forward_cn，双上游且仅 2 个） | PASS |
| A2 | 国外组 = `tls://8.8.8.8` + `tls://1.1.1.1`（forward_foreign，DoT） | PASS |
| A3 | 降级链 foreign_fallback：primary=forward_foreign、secondary=forward_cn、threshold=1000ms、triggers 含 timeout | PASS |
| A4 | 主序列首条 `matches: qname $geosite:cn` → exec [cache, forward_cn]（其余 → foreign_fallback） | PASS |
| A5 | cache 插件：size=4096、lazy_cache_ttl=86400（内存缓存） | PASS |
| A6 | fakeip 插件池 `198.18.0.0/16` 已注册，且主序列 exec 不引用（空规则预置，P3 才启用） | PASS |
| A7 | udp_server + tcp_server 均 `listen: 127.0.0.1:5353`、entry=main（仅回环） | PASS |
| A8 | 全文无 persist/data_dir/cache_dir/db_/file: 等落盘或数据目录配置（NAND 零写入） | PASS |

## 3. 结论

- 全量新增/改动脚本 bash -n 零错误（2/2）。
- config.yaml 结构断言 8/8 PASS，与调研文档 §四/§五（国内 DoH×2 互备、国外 DoT 超时降级、geosite 分流、lazy_cache 内存、fakeip 空规则预置、仅回环监听、零落盘）逐条相符。
- 本记录随 DNS Phase 0 PR 一并提交。

---

# 附：diff 与锁源审查记录（2026-09-08，同组第二小类）

## 1. 范围一致性（git 全量变更枚举）

工作树 vs `main@9e1c2a5`（`git status --porcelain`）：

```
 M TASKS.md
 M config/seed-config.diff
 M docs/ACCEPTANCE.md
 M docs/FIXES.md
 M docs/ROADMAP.md
?? docs/acceptance-results/2026-09-08-dns-phase0-static-audit.md
?? files/etc/mosdns/
?? files/etc/uci-defaults/96-xr1710g-dns-firewall
?? files/etc/uci-defaults/97-xr1710g-dns-mosdns
```

共 **9 项，全部为本任务文件**，与预期清单逐一对应（seed/dhcp 归位/mosdns config/防火墙/三份文档/审计记录）：

| 期望项 | 状态 |
|---|---|
| `config/feeds.custom.conf`（feed） | ✅ 内容已在 main（并发会话 `1284dfb feat(proxy)` 同文件编辑将其一并提交；`git show HEAD:config/feeds.custom.conf` 含 `src-git-full mosdns …^df6d67b84…`×1，与本地一致，无工作树残留） |
| `config/seed-config.diff`（seed 两符号） | ✅ M（HEAD 中 0 条 mosdns 符号 → 本任务未提交部分完好） |
| uci-defaults 96/97 + mosdns config.yaml | ✅ ??×3（新增） |
| docs/ACCEPTANCE.md / FIXES.md / ROADMAP.md / TASKS.md | ✅ M×4 |
| 审计记录 | ✅ ??（本文件） |

越界检查：`docs/DDNS-EVAL.md`、`config/seed-config.experimental.diff` 均为并发会话产物（已随 `9e1c2a5`/`1284dfb` 提交），**不在本任务变更集**；本任务未触碰。

## 2. 锁 commit 远端存在性（ls-remote 证据）

2026-09-08 14:2x（本会话早段，网络正常时）取得，双源一致：

```
$ git ls-remote https://github.com/sbwml/luci-app-mosdns.git refs/tags/v5.3.4-r13
df6d67b84d32246081e259f3cb93dae63962a1fc	refs/tags/v5.3.4-r13
$ gh api repos/sbwml/luci-app-mosdns/commits/df6d67b84d32246081e259f3cb93dae63962a1fc
{"date":"2026-09-05T13:45:55Z","msg":"luci-app-mosdns: bump version to 1.7.13","sha":"df6d67b84d32246081e259f3cb93dae63962a1fc"}
release v5.3.4-r13 published 2026-09-05T13:52:31Z
```

- 锁值 = tag 指向的**轻量 tag commit**（无 `^{}` peel 行），提交时间与 release 同日。
- 复查（14:4x）因 GitHub 偶发 TLS 断流失败（HANDOFF §8 已知现象），以早段证据为准；CI 构建（后续大类）将实质复验（feed 克隆需该 commit 可达）。

## 3. hash=skip 零引入

- 本仓库变更面 grep（config/ files/ docs/）：无任何 `hash=skip` 配置残留，仅文档禁令语句（DDNS-EVAL R2 / FIXES F91 / ROADMAP L42）。
- mosdns 包 Makefile 抽查（`mosdns/Makefile @ df6d67b`）：拉取受同一网络断流影响**未完成**——按验收预案，**列入实算路径处理**（下一小类「镜像哈希实算」：网络恢复/CI 时实查 PKG_MIRROR_HASH；若缺或 skip → git archive 复现或 CI 期望值回填，禁 skip 进构建）。

## 附 2. 结论

- 范围一致性 ✅（9/9 全部为本任务文件，无越界；feed 行已随 main 提交且内容完好）。
- 锁 commit 远端存在性 ✅（早段 ls-remote+gh api 双源证据；复查受网络影响，CI 将实质复验）。
- hash=skip 零引入 ✅（本仓库变更面 grep 零残留；mosdns 包 Makefile 抽查转交「镜像哈希实算」小类闭环）。

---

# 附：镜像哈希实算（PKG_MIRROR_HASH）记录（2026-09-08，同组第三小类）

## 1. 现场判断

- 锁 commit（df6d67b）的 `mosdns/Makefile` 三通道拉取均失败（raw.githubusercontent / cdn.jsdelivr.net / gh api，2026-09-08 14:5x，GitHub TLS 断流）；本地无任何 mosdns 源码缓存（tmp/openwrt-src 无 dl 命中、.gh_cache 无）→ **包内 PKG_MIRROR_HASH 现状未证实**。
- 按本小类验收标准许可路径执行：「**已记录回填方案**」（L2 任务原文：记录 CI 首轮报期望值再回填的步骤）。

## 2. 分支预案（CI 构建大类触发判定）

- **情形 A（预期命中）**：sbwml 为成熟维护包，其 Makefile 惯例自带 `PKG_HASH`/`PKG_MIRROR_HASH` 实值（同作者同仓 mihomo-meta 已实测自带，见 F90）→ CI 首轮 download 即过，**零动作**。证据：CI stock 绿 + 网络恢复后 `curl -sL https://raw.githubusercontent.com/sbwml/luci-app-mosdns/<锁commit>/mosdns/Makefile | grep -E "^PKG_(MIRROR_HASH|HASH)"` 一行存档。
- **情形 B（缺/skip）**：CI 首轮 download 阶段报期望 sha256 → 按 §3 回填 → 重跑。

## 3. 回填方案（情形 B 时执行，可复现）

**步骤 1 — 取期望值**：CI 失败日志 download 段 `sha256sum`/`MIRROR_HASH` 报错行取期望值 `H`。

**步骤 2 — 本地复现实算（网络恢复后双源核对）**：
```
# 源码为 release tarball（PKG_SOURCE_URL=github release）时：
curl -sL https://github.com/IrineSistiana/mosdns/releases/download/<PKG_SOURCE_VERSION>/<PKG_SOURCE> -o /tmp/mosdns-src.tar.gz
sha256sum /tmp/mosdns-src.tar.gz        # 须 == H
# 源码为 git 源时（复刻 scripts/download.pl git 模式）：
git clone --depth 1 --branch <tag> https://github.com/<src-repo>.git /tmp/mosdns-src
git -C /tmp/mosdns-src archive HEAD | gzip -n | sha256sum   # 以 OpenWrt 打包命令为准
```
两值一致 → `H` 可信。

**步骤 3 — 落仓形式**：同名包覆盖——新增 `packages-xr1710g/package/mosdns/Makefile`（复制上游 Makefile + 实算 `PKG_MIRROR_HASH` 值），src-link feed（xr1710g）在 feeds.custom.conf 中位于 src-git-full mosdns 之前；以 CI 构建的 package index 实际命中为准验证（若顺序语义不符 → 退为 build.sh 在 feeds update 后应用 Makefile 补丁的一行级 hook，两者均需 CI 复验）。回填 commit 同步更新 FIXES F91。

**步骤 4 — 重跑 CI** 至 stock 绿，存档期望值、实算命令输出与本步骤记录。

## 4. 零 hash=skip 保证

- 本仓库提交面 grep 无 `hash=skip`（「diff 与锁源审查」已证：仅文档禁令文字）。
- 情形 B 回填值为实算哈希而非 skip；上游包若自带 skip 亦被覆盖名包以实值替代。
- CI 首轮即检测：download 阶段无 skip 侥幸路径（OpenWrt 对缺 hash 包直接拒绝）。

## 5. 本小类验收对照

| 验收项 | 状态 |
|---|---|
| Makefile 带实算哈希 **或** 已记录回填方案 | ✅ 以「已记录回填方案」达成（§2-§3 可执行步骤，情形 A/B 判定由 CI 大类触发） |
| 实算过程可复现（命令+产物 hash 存档） | ✅ 命令原文存档（§3 步骤 2）；情形 B 产物 hash 于回填时补记 |
| 无 hash=skip 进 CI | ✅ 本仓库零引入；情形 B 以实值覆盖 |
---

# 附：CI stock 构建验证记录（2026-09-08，CI 大类第一/二小类联动）

## 1. run 与终态

- run **#34196307154**（https://github.com/genshanxinli/xr1710g-openwrt/actions/runs/34196307154）
- 触发：`gh workflow run build.yml --ref feat/dns-phase0 -f profile=stock`；矩阵实证「build (stock)」
- 时间线（`tmp/ci/run-34196307154-watch2.log`，30s 轮询）：07:10:13 in_progress → **08:13:26 completed success**（约 1h3m；23 次 API 断流均重试存活）
- 首轮 watch 因 API EOF 中断（watch exit=1 为网络错误），换抗断流轮询器续盯，无状态丢失

## 2. firmware artifact（`tmp/ci/run34196307154/firmware-stock/`）

| 产物 | 大小(B) |
|---|---|
| openwrt-stock-…-squashfs-sysupgrade.itb | 25,596,741 |
| openwrt-stock-…-initramfs-recovery.itb | 23,592,960 |
| openwrt-stock-…-chainload-uboot.itb | 287,696 |

## 3. 镜像包清单（manifest 证据）

`openwrt-stock-airoha-an7581-stock.manifest`（218 行）：

```
L148  luci-app-mosdns - 1.7.13-r1
L162  mosdns - 5.3.4-r13
```

## 4. M6 风险点对应（Go 交叉编译链）

build log 实证：mosdns-5.3.4 经 `feeds/packages/lang/golang/golang-build.sh`（GO_PKG=IrineSistiana/mosdns，hostpkg go-1.27，toolchain aarch64_cortex-a53_gcc-14.4.0_musl）编译、`rstrip.sh: …/usr/bin/mosdns: executable`；luci-app-mosdns 与 geo2txt 同链编译 → **M6 构建链在 CI 全通，风险关闭**。

## 5. PKG_MIRROR_HASH 情形判定（镜像哈希实算小类收口）

build log L172519：`download.pl … "mosdns-5.3.4.tar.gz" "0302a685db2a6c3c09af7bf4ff0dffd24f1e583383a47f064564f5270033671b" … codeload.github.com/IrineSistiana/mosdns/…` → 上游 Makefile **自带实哈希且校验通过（情形 A 命中）**，回填方案无需启用；此前「未证实」项在此闭环。

## 6. 结论

- run 终态=completed success；firmware 三件产物在册；镜像含 mosdns 5.3.4-r13 + luci-app-mosdns 1.7.13-r1（manifest 证据）。
- M6（Go 构建链）与 PKG_MIRROR_HASH（情形 A）双风险点闭环。

---

# 附：构建问题闭环判定（2026-09-08，CI 大类第三小类）

- 首轮 run #34196307154 = **success**（08:13:26 终态），镜像含 mosdns 5.3.4-r13 / luci-app-mosdns 1.7.13-r1（manifest L148/L162）。
- 闭环状态机：**第 1 轮即达终态绿 → 零修复 commit、零重跑、零降级/删包绕行**（「修复而非降级」判据空置，无压力下改动）。
- 阻塞上报：不适用（无连续 2 轮同根因红）。
- 结论：本小类验收 = 最终状态「stock 构建绿（含 mosdns 包）」✅。

---

# 附：PR 存档（2026-09-08，PR 大类第一小类）

- PR **#27**：https://github.com/genshanxinli/xr1710g-openwrt/pull/27
- base=main / head=feat/dns-phase0 / state=OPEN / isDraft=false
- 正文四要素（动机/改动清单/验证证据/验收项引用）经 gh pr view 断言全通过
