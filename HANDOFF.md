# 交接提示词（给下一会话）

你是 XR1710G 自用 OpenWrt 固件仓库的接任维护者。工作区：`/home/harness/workspace/xr1710g/xr1710g-firmware2`（已 git 提交，main 分支）。先读这五个文件再动手：`README.md`、`CONTEXT.md`（词汇表）、`docs/FIXES.md`（修复台账，F01-F20）、`docs/adr/0001/0002`（两项硬决策）、`docs/ROADMAP.md`（计划）。

## 仓库是什么

Gemtek XR1710G（Airoha AN7581GT + MT7996 三频 Wi-Fi7、2×10G+2×1G）的**自用 OpenWrt 固件仓库**，形态是「openwrt master 之上的叠加层」：
- 基线 = openwrt/openwrt master（kernel 6.18）；XR1710G 板级支持（#22397 仍未合入）由本层携带
- **铁律：遇到问题修复而不是降级**——补丁冲突/失效/构建失败一律修本层，不删能力不回退版本
- 补丁层 `patches/`：`MANIFEST`（权威应用清单）+ `ORDER`（档位评审视图，须与 MANIFEST 一致）；`vendor/fanboy/` 原料桶
- 构建/CI：`scripts/build.sh <stock|oc-1.3|oc-1.4> [树]` 一键构建；`.github/workflows/build.yml`（push=stock 门禁 + workflow_dispatch 全档/matrix）+ `sync-upstream.yml`（每 2h 自动同步上游 + 补丁层 dry-run，冲突=CI 红=修补丁层）；**dispatch 构建成功后自动打 `ci-<run>` pre-release**
- 交付：双 release——stock（默认 known-good）+ oc 变体（限频 1300 可解锁，`files/etc/init.d/oc-limit`）；验收全项清单 `docs/ACCEPTANCE.md`

## 已收口的状态（2026-08-17 晚，别重复做）

- **远程仓库**：`github.com/genshanxinli/xr1710g-openwrt`（public，gh 认证账户 genshanxinli）。一切改动 push 到 main。
- **F13/F18/F19 已收口**（d87fd4e）：08 切片 root/9011-9016 + 19-core root/9017；prepare-oc.sh OPP 平移单位+花括号修复；CI 假绿修复（pipefail + no-files-found=error）。
- **F20 已修（本会话 d2506dd）**：F19 修复后三档 CI **首次真红**（32023932123/43423/47785，2026-08-17 11:13 起），根因不是 openssl（旧问题），而是 **regdb 补丁**：
  - ① `regdb-0500-world-5ghz-no-no-ir.patch` 与 OpenWrt 自带 `500-world-regd-5GHz.patch` **内容完全一致**（同作者同 diff）——重复补丁：500 先应用成功、0500 再找旧上下文必挂（Hunk #1 FAILED at 19）→ **删除 0500**（能力保留，上游已自带，非降级）；
  - ② OC 档 `regdb-0555` 的 hunk 基于原始 db.txt（6g 行 `(12), NO-OUTDOOR, NO-IR`），但 OC 档 = 默认档全量 + #OC 行，应用顺序 0510→0520 已把 6g 行改为 `(29), NO-OUTDOOR` → 0555 必挂 → **0555 按「0510/0520 应用后」状态重建**（UNII-4 扩展至 5895MHz + 6g 29→30dBm，语义不变，注释行保留）；
  - ③ 深坑：**apply-patches.sh 的 dry-run 对拷贝类（packages）补丁只检查目标目录存在性、从不真实应用**——regdb/mt76 系列补丁从未被验证过（F18 教训同类盲区）。本地从零实证通过：500→0510→0520→0555 依次 `patch -p1` 全应用 + `dbparse.py` 语法校验 exit 0 + 语义核对（world 36-48 去 NO-IR / US UNII-1 29dBm / UNII-4 5730-5895 / 6g 29→30dBm）。0510/0520 在新版 db.txt 应用 offset 42 行（上下文匹配正确）。
- **重新触发三档构建验证（本会话 14:51，正在跑）**：stock=32040461045（push 触发）、oc-1.3=32040518516、oc-1.4=32040521523（dispatch）。**成功判据 = firmware-* artifact 存在**（F19 制度化）。同步验证：push 后 sync-upstream run 32040461067 绿（新 master 上 ROOT 补丁 dry-run 无冲突）。
- 本地宿主缺陷备忘：容器缺 gawk（scan.awk asort）/mkhash → 本地 defconfig/feeds 索引不完备；定向验证（`feeds update <feed名>`、apply-patches --dry-run）可做，仓库代码以 CI（gawk 全工具）为准。

## 下一步任务（按优先级）

1. **验证三档真绿构建**（进行中）：等 stock/oc-1.3/oc-1.4 三个 run 完成，**成功判据 = firmware-* artifact 存在**（`gh api repos/genshanxinli/xr1710g-openwrt/actions/runs/<id>/artifacts`）。若再红：按 F20 教训处理——拷贝类补丁（mt76 0006/0007 等）应用失败要先本地 `patch -p1` 模拟或等构建真实应用；下载失败类（openssl 等 502/404）先重试不改仓库。绿后 oc-1.4 的 release job 会聚合发布 ci-<run>（真产物）。
2. **首个 known-good 定位**（需设备）：按 ACCEPTANCE 全项实机验收（物理口↔逻辑名、6GHz EHT320、NPU、风扇曲线、OC 档实测）→ 打 known-good tag。在此之前 stock 的 ci-<run> pre-release 已是可用候选。
3. **上游跟踪**：#22397 合入即删 9000-9002 三件套；#22029 合入即删 vendor/03；#22473 剩 uboot 侧；#24034/#24619 LED 视实机。
4. **实验档毕业候选**：#22532（DSA）/#22533（L2 offload）——experimental 构建跑通 + 实机验证后并入默认档。
5. **工程化续**：① DISABLED 的 `regdb-0530` 同样基于旧 db.txt，**启用前必须重建**（F20 备注）；② F20 教训制度化——给 apply-patches.sh 的 dry-run 增加拷贝类补丁的**真实应用校验**（或构建步骤对 packages 补丁应用失败即红，后者已天然成立）；③ 可考虑给 release job 加 artifact 存在性断言；④ 本地全量构建宿主缺 gawk 的规避文档化。

## 环境与事实速查

- 调研资产在工作区：`XR1710G-openwrt-调研报告.md`、`OC与高功率实现-调研报告.md`、`对比报告-骨架目标-vs-OpenW1700k-ubi2-oc.md`、`audit-ubi2oc/`（CI 已排除）
- 事实锚点：NCT7802 为主（动态探测）；OC 个体体质差异（stock 默认、oc 限频 1300）；realtek PHY 已进主线；NPU 内存 #24593 已合 master
- 风险自负项：US regdb 功率无 AFC/合规背书；第三方 U-Boot 后厂商恢复失效；Wi-Fi 密码占位 123456789
- 本地调试技巧：regdb 补丁验证流程（本会话沉淀）——`curl https://cdn.kernel.org/pub/software/network/wireless-regdb/wireless-regdb-2026.05.30.tar.xz` → `patch -p1` 按序应用（500 上游自带 → 0510 → 0520 → #OC 0555）→ `python3 dbparse.py db.txt` 校验语法；`/tmp/regdb/verify` 是本次会话的实证目录，可继续用
- git clone 直连 github 不稳（HTTP2 帧错误/断连），**用 `git -c http.version=HTTP/1.1 push`** 或 codeload tarball + git init 拉树
- 一切改动进 git 并留痕；vendor 包必须锁来源 commit；升级 feed/补丁后在 FIXES 登记
