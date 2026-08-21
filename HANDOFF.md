# 交接提示词（给下一会话）

你是 XR1710G 自用 OpenWrt 固件仓库的接任维护者。工作区：`/home/harness/workspace/xr1710g/xr1710g-firmware2`（已 git 提交，main 分支）。先读这五个文件再动手：`README.md`、`CONTEXT.md`（词汇表）、`docs/FIXES.md`（修复台账，F01-F25）、`docs/adr/0001/0002`（两项硬决策）、`docs/ROADMAP.md`（计划）。

## 仓库是什么

Gemtek XR1710G（Airoha AN7581GT + MT7996 三频 Wi-Fi7、2×10G+2×1G）的**自用 OpenWrt 固件仓库**，形态是「openwrt master 之上的叠加层」：
- 基线 = openwrt/openwrt master（kernel 6.18）；XR1710G 板级支持（#22397 仍未合入）由本层携带
- **铁律：遇到问题修复而不是降级**——补丁冲突/失效/构建失败一律修本层，不删能力不回退版本（上游已吸收能力的情形例外：撤冗余补丁=非降级，见 F20 0500/F22 fanboy14）
- 补丁层 `patches/`：`MANIFEST`（权威应用清单）+ `ORDER`（档位评审视图，须与 MANIFEST 一致）；`vendor/fanboy/` 原料桶
- 构建/CI：`scripts/build.sh <stock|oc-1.3|oc-1.4|experimental> [树]` 一键构建；`.github/workflows/build.yml`（push=stock 门禁 + workflow_dispatch 全档/matrix）+ `sync-upstream.yml`（每 2h 自动同步上游 + 补丁层 dry-run，冲突=CI 红=修补丁层）；**dispatch 构建成功后自动打 `ci-<run>` pre-release**
- 交付：双 release——stock（默认 known-good）+ oc 变体（限频 1300 可解锁，`files/etc/init.d/oc-limit`）；验收全项清单 `docs/ACCEPTANCE.md`

## 已收口的状态（2026-08-17 晚起，本会话+8-18 F25，别重复做）

- **07 天线改善落地（2026-08-20，分支 feat/antenna-eeprom-power-unlock）**：regdb-0521 默认档（UNII-3/4 160MHz 30dBm）+ mt76-0008 默认档（eeprom 2G/5G 解锁）+ 默认无线 5G ch149/HE160、6G ch37、2.4G MU-MIMO 关；release 资产改 tar.gz 避免同名冲突（F26）；all=32407079282 / experimental=32400014053 全绿，ci-36/ci-37 产物。待实机验收后合并 main。
- **ubi2-oc 快照同步（2026-08-21，分支 feat/antenna-eeprom-power-unlock）**：vendor 06/07 更新为当前 fanboy 内容（`649ef957` L2 三补丁合并版 / `4d61493e` release HW_RRO session），并更新 MANIFEST/ORDER；新增 `patches/packages/mt76-0005-…txfree…` 入实验档（同步自 fanboy `496c0f5e`，已对 pin `59676919` 实证可应用）；对比报告已刷新至 `c052cc75`。待实验档构建/实机验证。

- **远程仓库**：`github.com/genshanxinli/xr1710g-openwrt`（public，gh 认证账户 genshanxinli）。一切改动 push 到 main。
- **F13/F18/F19 已收口**（d87fd4e）：08 切片 root/9011-9016 + 19-core root/9017；prepare-oc.sh OPP 平移单位+花括号修复；CI 假绿修复（pipefail + no-files-found=error）。
- **F20 已修**（d2506dd）：删重复 regdb-0500（上游自带 500-world-regd-5GHz.patch）+ 重建 0555（按 0510/0520 应用后状态）。**本地验证流程沉淀**：`/tmp/regdb/verify`、`/tmp/r530`（0530 实证：当前源码上带 fuzz 2 可应用，启用前须重建）。
- **F21 已修（本会话 15976d0）**：F20 后三档重建首次真红（32040461045/32040521523，2026-08-17 15:51 起，内核+kmod 全过、`uboot-airoha` an7581_gemtek_xr1710g prepare 挂）——根因三叠加：
  - ① `9002` 生成的包补丁命名 `1000-` 的 **glob 字节序**实际排在 `100-` 与 `101-` 之间（"1000"<"101"），在 defenvs/（上游 999 创建）之前应用 → 新建文件 hunk 挂；
  - ② 内层补丁 3 个新建文件 hunk 的 `+++ b/` 行在 PR 提取时全丢（首 hunk 靠 diff --git 头侥幸应用）；
  - ③ 外层 hunk 行数 `@@ -0,0 +1,295 @@` 未随修复行同步 → git apply 按 295 行截断创建文件，尾部 gdm1 块被丢。
  - **修复**：内层重命名 `9990-`（glob 序在 998/999 后、未来 1000+- 前）+ 补回 3 处 `+++ b/` 行 + 外层 hunk 行数改 298。本地实证：u-boot-2026.07 + master 全量补丁（100→…→999）+ 9990 按 glob 序 `patch -f -p1` 全应用、3 个新文件（configs/an7581_xr1710g_defconfig、defenvs/an7581_xr1710g_env、dts/upstream/src/arm64/airoha/an7581-xr1710g-ubi.dts）全部创建。
- **F22 已修（本会话 15976d0）**：verify 扩展（见下）抓出 `vendor/fanboy/14-mt76-patches-80f79586.patch` 生成的 mt76 包补丁 0001/0003 对 pin 版 mt76 **59676919（2026-07-01）完全冗余**——0001 的 token/NPU debugfs 计数器与 debugfs.c:908 逐字一致、0003 的功能性改动（MCU 采集调用 mac.c:2895-2896 + mcu.c:5552 助手）全部已上游，剩余 diff 仅删上游死代码 `mt7996_mac_sta_poll`。**#DISABLED fanboy 14**（能力上游自带=非降级，同 F03/0500 逻辑）。
- **F23 已修（本会话 83f07db）**：第四次三档重建（15976d0）uboot/mt76/regdb 全过，挂在内核 DTB 阶段——`9001` 外层 hunk 声明 `@@ -0,0 +1,330 @@` 而实际 **427 行**，**git apply 对行数不匹配静默截断创建文件**（丢尾部 97 行含 `&gdm4` 块），`an7581-xr1710g-ubi.dts:330.8-331.1 syntax error`。修复：330→427；实证 DTS 427 行完整+括号配平。**制度化**：新增 `scripts/audit-patches.sh`（逐 hunk 核对声明行数，不一致即红）接入 apply-patches.sh 应用前（dry+真实都跑）；全仓库审计仅 9001 一处。
- **F20 教训制度化（本会话 15976d0 + 83f07db，重点）**：
  - `scripts/verify-copy-patches.sh`（15976d0）接入 `apply-patches.sh --dry-run`——**按构建语义真实应用拷贝类/派生包补丁**：树内包 Makefile 派生源码 tarball（PKG_VERSION/PKG_SOURCE_VERSION 单一事实源，不手工 pin）→ 缓存下载（损坏缓存自动删除重下；下载失败=⚠ 不红，构建兜底；uboot 多镜像后备）→ 解包 → 组装「树内已有补丁+本层补丁」同目录 → 树内自带 `scripts/patch-kernel.sh`（=构建 KPATCH）glob 排序 `patch -f -p1` 真实应用 → regdb 逐包 dbparse.py 校验。应用失败=红（2h cron 尽早暴露而非等构建）。**派生目标**（ROOT 补丁生成的包补丁，如 9002→uboot、fanboy14→mt76）注册于 DERIVED_DESTS；**verify 必须在 dry-run 的 git reset 之前调用**——apply-patches.sh 已保证并正确传播退出码。CI 实证：sync-upstream 32047198944/32053502231 绿（regdb/mt76/uboot 3 目标全过）。
  - `scripts/audit-patches.sh`（83f07db，F23）接入 apply-patches.sh 应用前——**逐 hunk 核对声明行数 vs 实际**：git apply 对行数不匹配的包裹补丁静默截断创建文件不报错（F21③ 9002、F23 9001 两例），此审计补上该盲区；dry+真实模式都跑。
- **✅ P0 真绿门禁达成（2026-08-17 19:2x，第五次重建 83f07db 全绿）**：push stock=32053502298 ✓ + dispatch all=32053692044（stock/oc-1.3/oc-1.4 全 ✓）；**firmware-stock/oc-1.3/oc-1.4 artifact 各 ~33.5MB 产出**（sysupgrade+initramfs+chainload-uboot+manifest，FIT 魔数 d00dfeed 验证）；release ci-26 已建且**真产物已补传**（F24：release job 顺序 bug 致自动上传空壳，手动补传 + build.yml 已修——checkout 先于 download、去 merge-multiple 保三档同名 itb）。首个 known-good 前的可用候选 = ci-26 pre-release。
- **✅ F25 实验档工程化（2026-08-18，已合入 main `015cd2a`（squash，分支 feat/experimental-tier 已删））**：
  - **实验档可构建化**：build.sh 加 `experimental` 档；build.yml profile 校验 + OC/EXP 标志分离（'all' 仍三 release 档）；sync-upstream 2h cron dry-run 加 `--experimental`（实验档漂移检测）；audit-patches/verify-copy-patches 加 `--experimental`（#EXP 行纳入 hunk 审计与拷贝类真实应用校验）；apply-patches.sh 修 set -e 缺陷（verify 失败不再跳过 git reset）+ 透传 `--no-download`（本地离线 dry-run）。
  - **mt76 integration 9990-9993 评审（ROADMAP P3 勾掉）**：9990 EHT 广告 / 9991 160MHz BF fallback / 9993 op_mode 传递 → 重建入实验档（`patches/packages/mt76-999x-…`，对 pin 59676919 原生态可应用、master b2704cf5 无）；**9992 PS-sync 校验否决**（mt76 master 2026-08-01 已上游合入，pin 升级自然获得）。
  - **8 条 #EXP 补丁实测**：对 master 按序全应用（05-bridge-offload 依赖 02-eip93 先行——hunk 旧上下文含 02 加入的 kmod-crypto-hw-eip93 行）。
  - **CI 实证（2026-08-18 21:20）**：experimental 构建 32179841824 **成功**——firmware-experimental artifact 33.5MB（sysupgrade+initramfs+chainload-uboot+manifest）；**release job 自动上传闭环（F24 首验）**：ci-32 pre-release 4 真资产（此前 F24 修复未验证）；三次构建迭代暴露并修复两个真实问题：EXP-18 生成的 992-21 冗余超时 hunk（上游内核已 100ms）→ 29778aa；9993 的 mac80211 cap helper 编译依赖（backport 未导出）→ 携带 subsys 411 → 54fb458。**合入后 main stock 门禁 32187355106 亦绿**（firmware-stock 33.5MB，脚本改动对默认档无回归）。
- 本地宿主缺陷备忘：容器缺 gawk（scan.awk asort）/mkhash → 本地 defconfig/feeds 索引不完备；定向验证（`feeds update <feed名>`、apply-patches --dry-run）可做，仓库代码以 CI（gawk 全工具）为准。**本会话额外发现**：本宿主访问 github.com 常遇 429/500/空包（archive/codeload 下载不稳定）——verify 的缓存损坏守卫能自愈；取 mt76 源码可用 `git -c http.version=HTTP/1.1 clone` + `git fetch <sha>` 精确检出 pin commit（git 协议比 tarball 稳）。

## 下一步任务（按优先级）

1. **首个 known-good 定位**（需设备）：按 ACCEPTANCE 全项实机验收（物理口↔逻辑名、6GHz EHT320、NPU、风扇曲线、OC 档实测）→ 打 known-good tag。**在此之前的可用候选 = ci-26 pre-release（真产物，三档各含 sysupgrade/initramfs/chainload-uboot + manifest）**。
2. **~~release 自动化验证（F24 闭环）~~** ✅ **已闭环（2026-08-18）**：ci-32（experimental dispatch）release job 自动带 4 真资产。残余：下次 'all' dispatch 核对三档 + 各档子目录结构（firmware-stock/oc-1.3/oc-1.4 同名 itb 互不覆盖）。
3. **上游跟踪**：#22397 合入即删 9000-9002 三件套（uboot 补丁命名改回 PR 编号时注意 glob 序）；#22029 合入即删 vendor/03；#22473 剩 uboot 侧；#24034/#24619 LED 视实机。上游 mt76 若合入 EHT 广告/320 BF fallback/op_mode 之一，复查 9990/9991/9993 冗余性（9992 已上游，pin 升级即自然获得）。**mt76 pin 升级时：先跑 sync-upstream 验证 0006/0007/9990/9991/9993 在新 pin 上的应用**。
4. **实验档**：8 条 #EXP（02/04-09/17/18 + mt76 9990/9991/9993）已可构建验证——`build.sh experimental` 或 CI dispatch `profile=experimental`；**毕业候选**：#22532（DSA）/#22533（L2 offload）实验构建跑通 + 实机验证后并入默认档；mt76 三补丁实机 EHT320 客户端验证后毕业。
5. **工程化续**：① DISABLED 的 `regdb-0530` 已按当前状态重建（fuzz 2→0，2026-08-17），启用时过一遍 verify 即可；② 本地全量构建宿主缺 gawk 的规避文档化；③ verify-copy-patches 的未知拷贝目标会⚠跳过——新增包补丁目标时先在本脚本登记源映射（wifi-scripts/hostapd 的 EXP-17 生成补丁目录暂未登记，属已知缺口）；④ 2h 同步稳定后把「冲突→修复→回归」流程沉淀为文档；⑤ 实验档毕业自动化（ROADMAP P4：experimental 构建过 + ACCEPTANCE 子集 → PR 式并入默认 MANIFEST）；⑥ **内核补丁 verify 盲区**（F25 教训④）：ROOT 生成的 patches-6.18 补丁不在 verify 覆盖内（构建兜底）——候选扩展 verify-copy-patches 增内核 dest（2h cron 每次下载内核源码 ~150MB，评估后定）。

## 环境与事实速查

- 调研资产在工作区：`XR1710G-openwrt-调研报告.md`、`OC与高功率实现-调研报告.md`、`对比报告-骨架目标-vs-OpenW1700k-ubi2-oc.md`、`audit-ubi2oc/`（CI 已排除）
- 事实锚点：NCT7802 为主（动态探测）；OC 个体体质差异（stock 默认、oc 限频 1300）；realtek PHY 已进主线；NPU 内存 #24593 已合 master
- 风险自负项：US regdb 功率无 AFC/合规背书；第三方 U-Boot 后厂商恢复失效；Wi-Fi 密码占位 123456789
- 本地调试技巧：① 拷贝/派生补丁验证 = `scripts/apply-patches.sh <树> --dry-run [--oc]`（现含真实应用校验，需网络下载包源码，缓存于 /tmp/copy-patch-verify）；② regdb 专项：`curl https://cdn.kernel.org/pub/software/network/wireless-regdb/wireless-regdb-2026.05.30.tar.xz` → `patch -p1` 按序（500 上游自带 → 0510 → 0520 → #OC 0555）→ `python3 dbparse.py db.txt`；③ uboot 专项：mirror.cyberbits.eu 取 u-boot tarball，patch-kernel.sh glob 应用全量（/tmp/uboot-verify 实证目录）；④ scratch 验证树：`git clone --depth 1 file:///home/harness/workspace/openwrt-src /tmp/owrt-verify` + tar 叠加本仓库（镜像 CI 的 rsync）
- git clone 直连 github 不稳（HTTP2 帧错误/断连/429），**用 `git -c http.version=HTTP/1.1 push`**；取源码 tarball 不稳时用 `git clone` + `git fetch <sha>` 精确检出（git 协议更稳）
- 一切改动进 git 并留痕；vendor 包必须锁来源 commit；升级 feed/补丁后在 FIXES 登记
