# 交接提示词（给下一会话）

你是 XR1710G 自用 OpenWrt 固件仓库的接任维护者。工作区：`/home/harness/workspace/xr1710g/xr1710g-firmware2`（已 git 提交，main 分支）。先读这五个文件再动手：`README.md`、`CONTEXT.md`（词汇表）、`docs/FIXES.md`（修复台账，F01-F19）、`docs/adr/0001/0002`（两项硬决策）、`docs/ROADMAP.md`（计划）。

## 仓库是什么

Gemtek XR1710G（Airoha AN7581GT + MT7996 三频 Wi-Fi7、2×10G+2×1G）的**自用 OpenWrt 固件仓库**，形态是「openwrt master 之上的叠加层」：
- 基线 = openwrt/openwrt master（kernel 6.18）；XR1710G 板级支持（#22397 仍未合入）由本层携带
- **铁律：遇到问题修复而不是降级**——补丁冲突/失效/构建失败一律修本层，不删能力不回退版本
- 补丁层 `patches/`：`MANIFEST`（权威应用清单）+ `ORDER`（档位评审视图，须与 MANIFEST 一致）；`vendor/fanboy/` 原料桶
- 构建/CI：`scripts/build.sh <stock|oc-1.3|oc-1.4> [树]` 一键构建；`.github/workflows/build.yml`（push=stock 门禁 + workflow_dispatch 全档/matrix）+ `sync-upstream.yml`（每 2h 自动同步上游 + 补丁层 dry-run，冲突=CI 红=修补丁层）；**dispatch 构建成功后自动打 `ci-<run>` pre-release**
- 交付：双 release——stock（默认 known-good）+ oc 变体（限频 1300 可解锁，`files/etc/init.d/oc-limit`）；验收全项清单 `docs/ACCEPTANCE.md`

## 已收口的状态（2026-08-17 晚，别重复做）

- **远程仓库**：`github.com/genshanxinli/xr1710g-openwrt`（public，gh 认证账户 genshanxinli）。一切改动 push 到 main。
- **F13 拆分已全部收口**（提交 d87fd4e）：08 号六项（SPI33MHz/banner/dropbear 静默日志/antenna-memo/snd-off/LED-silence）切为 `patches/root/9011-9016` 入 default；19 号精简为 `patches/root/9017` 19-core（去 fastfetch/netspeedtest，保留 npu/flowsense/mlo/fancontrol/wifi7）。**9014 依赖 9010 先行**（同文件 mac80211.sh，尾部上下文按 9010 后重建）；`--dry-run` 双档（default/oc）从零实证全绿，CI sync-upstream 亦过（run 32023932003）。
- **F18 已修**（d87fd4e）：prepare-oc.sh OPP 平移两个 bug——① `opp-hz` 值直接 `+delta`（Hz 级）应为 `+delta*1000000`（MHz 级），旧代码 OPP 从未真正平移（500MHz→500000200Hz）；② `opp-(\d+)\s*\{` 替换丢 `{` → **DTS 语法错误，oc 档 kernel 编译必挂**。修复后实证：1.4 档 15 点 700→1400MHz 步进 50、花括号 16/16、required-opps 完好；1.3 档 600→1300；stock 恢复 500-1200。**教训：树编辑脚本的"冒烟"必须核对数值语义与语法完整性，不能只看"能跑"**。
- **F19 已修**（d87fd4e）：**CI 假绿——此前所有"绿"构建都是假的**。build.yml 的 `make | tee` 无 pipefail（GitHub Actions 默认 bash 无 pipefail）→ make 失败码被吞 → step/job 绿；upload-artifact 无文件默认 warn 也不报错。实际：run 31999578409（"首次构建验证"）、32005186317（build#4 stock）、32005210085（oc-1.3c）三次全在 **openssl 下载失败**（3 mirror 全 502/404，瞬时网络问题）`Error 2`，但全部显示绿、`ci-8` pre-release 是 **0 assets 空壳**、**firmware artifact 从未产出**。修复：构建步骤首行 `set -euo pipefail` + 上传固件步骤 `if-no-files-found: error`。**成功判据 = firmware artifact 存在**（`gh run view <id> --json jobs` 不够，要看 artifact）。
- **F14 评估完成**（ac85f13）：vermagic 注入（01 号）暂不接入——① 需随内核版本维护 `files/etc/vermagic.txt`；② 本层 kernel 带 11/14 号配置改动，vermagic 与官方不同，注入掩盖差异；③ 自用 kmod 需求有限。维持 pending。
- 本地宿主缺陷备忘：容器缺 gawk（scan.awk asort）/mkhash → 本地 defconfig/feeds 索引不完备；定向验证（`feeds update <feed名>`、apply-patches --dry-run）可做，仓库代码以 CI（gawk 全工具）为准。

## 下一步任务（按优先级）

1. **验证真绿构建矩阵**（F18/F19 修复后已 dispatch）：stock（push 触发 32023932123）+ oc-1.3（32023943423）+ oc-1.4（32023947785），均 2026-08-17 11:13 起。**成功判据 = firmware-* artifact 存在**。openssl 下载 502/404 是 GitHub 瞬时网络问题（3 mirror 全挂），若重现先重试而非改仓库。绿后 oc-1.4 的 release job 会聚合发布 ci-<run>（这次是真产物）。
2. **首个 known-good 定位**（需设备）：按 ACCEPTANCE 全项实机验收（物理口↔逻辑名、6GHz EHT320、NPU、风扇曲线、OC 档实测）→ 打 known-good tag。在此之前 stock 的 ci-<run> pre-release 已是可用候选。
3. **上游跟踪**：#22397 合入即删 9000-9002 三件套；#22029 合入即删 vendor/03；#22473 剩 uboot 侧；#24034/#24619 LED 视实机。
4. **实验档毕业候选**：#22532（DSA）/#22533（L2 offload）——experimental 构建跑通 + 实机验证后并入默认档。
5. **工程化续**：F19 教训（CI 绿≠成功）已由 no-files-found=error 制度化；可考虑给 release job 加 artifact 存在性断言；本地全量构建宿主缺 gawk 的规避文档化。

## 环境与事实速查

- 调研资产在工作区：`XR1710G-openwrt-调研报告.md`、`OC与高功率实现-调研报告.md`、`对比报告-骨架目标-vs-OpenW1700k-ubi2-oc.md`、`audit-ubi2oc/`（CI 已排除）
- 事实锚点：NCT7802 为主（动态探测）；OC 个体体质差异（stock 默认、oc 限频 1300）；realtek PHY 已进主线；NPU 内存 #24593 已合 master
- 风险自负项：US regdb 功率无 AFC/合规背书；第三方 U-Boot 后厂商恢复失效；Wi-Fi 密码占位 123456789
- 本地调试技巧：`/tmp/owrt-08` 是本次会话建的实证树（master tarball + git init + 补丁层应用 + OC 冒烟），可继续用；git clone 直连 github 不稳（HTTP2 帧错误/断连），**用 `git -c http.version=HTTP/1.1 push`** 或 codeload tarball + git init 拉树
- 一切改动进 git 并留痕；vendor 包必须锁来源 commit；升级 feed/补丁后在 FIXES 登记
