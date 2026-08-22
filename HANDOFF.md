# HANDOFF — 交接文档（2026-08-22 第二会话收口）

> 接任维护者请先读：`README.md`、`CONTEXT.md`、`docs/FIXES.md`（F01–F59）、`docs/adr/0001`、`docs/adr/0002`、`docs/ROADMAP.md`。

## 0. 工作区与远程

- 本地仓库：`/root/workspace/xr1710g-openwrt`
- 当前分支：`feat/antenna-eeprom-power-unlock`
- 远程：`https://github.com/genshanxinli/xr1710g-openwrt`（默认分支 `main`）
- 推送到当前分支：
  ```bash
  export GH_TOKEN=$(cat .gh-token)
  git push "https://x-access-token:${GH_TOKEN}@github.com/genshanxinli/xr1710g-openwrt.git" feat/antenna-eeprom-power-unlock
  ```
  > 注意：本宿主 `git push origin` 常无输出/超时，直接用 token URL 最稳；`gh api`/`curl` 偶发 EOF/429，重试 1–2 次即可。

## 1. 仓库是什么

Gemtek XR1710G（Airoha AN7581 + MT7996 三频 Wi-Fi7、2×10G + 2×1G）的**自用 OpenWrt 叠加层仓库**：
- 基线 = `openwrt/openwrt` master（kernel 6.18）；板级/功率/诊断等未合入内容全部由 `patches/` 携带。
- 铁律：**修复而不是降级**；上游已吸收能力的冗余补丁应撤下（非降级）。
- `patches/MANIFEST` 是实际应用清单；`patches/ORDER` 是档位评审视图，二者必须一致。
- 构建：`scripts/build.sh <stock|oc-1.3|oc-1.4|experimental> [树]`；CI：`.github/workflows/build.yml`（workflow_dispatch：profile=all/stock/oc-1.3/oc-1.4/experimental）、`sync-upstream.yml`（2h dry-run）、`collect-sources.yml`（收集内核/mt76 prepare 后源码片段）。
- 实机：`root@192.168.123.1`，优先免密（`.ssh/id_ed25519`），否则密码 `password`。

## 2. 本会话完成的事（别重复做）

1. **查 build**：上一会话收口时 dispatched 的 `32576097284`（all）与 `32576100468`（experimental）在第二会话开始时仍在进行中。
2. **fanboy 再同步**：
   - 重取 `OpenWRT-fanboy/OpenW1700k` `ubi2-oc` `ba58ba46`；`649ef957...ba58ba46` compare 为 diverged 25/6。
   - 提取当前等价 commit：06=`c0ed8295`、07=`5b917d4b`、mt76-0005=`e7a8143`。
   - 对比结果：06/07 实际 diff 与旧快照**逐字节一致**（仅 `From` commit hash 与文件名变更）；mt76-0005 对 pin mt76 59676919 的 diff 也无变化（fanboy 当前 hunk 行号 1382，pin 上仍落在 1317）。
   - 已更新文件名、`From` hash、MANIFEST/ORDER/README 注释。
3. **YYH2913 再同步**：
   - 重取 `YYH2913/openwrt` `xr1710g-6.18-integration` `e88fbe28`。
   - 对比结果：mt76 `0006/0007/9990/9991/9993` 与 `mac80211-411` 的实际 diff 与仓库内版本一致（411 仅 Signed-off/Assisted-by 顺序不同），无需重建；regdb `510/520/530` 语义一致（530 上下文差异系 0521 前置所致）。
   - 已更新上述补丁 Source 注释为 fetched 2026-08-22。
4. **9992 复核（F59）**：F25 曾以“mt76 master 2026-08-01 已合入、pin 升级自然获得”否决 9992。本次复核：openwrt main 仍 pin mt76 `59676919`（2026-07-01），**并不包含**该加固，漏洞仍存在 → 按“修复而不是降级”改为**携带 9992 入实验档**（`patches/packages/mt76-9992-…`，对 pin `git apply --check` 零失败）。pin 升级后删除。
5. **本地验证全绿**：
   - `scripts/audit-patches.sh --experimental` ✅（46 个补丁全部一致）
   - `scripts/audit-patches.sh` ✅（30 个补丁全部一致）
   - `scripts/apply-patches.sh /tmp/openwrt-src --dry-run --experimental` ✅：ROOT 全部应用；拷贝补丁真实应用 regdb（4）✅、mt76（11）✅、uboot（41）✅；mac80211 未登记映射仍跳过。
6. **修了个脚本 mode**：`scripts/verify-copy-patches.sh` 之前为 0644，`apply-patches.sh --dry-run` 调用会 Permission denied；已 `chmod +x`。
7. **推送并 dispatch 新构建**：当前分支已推送到 GitHub；新增 dispatched：
   - all = `32578257466`（commit 3c4ee17）
   - experimental = `32578259118`（commit 3c4ee17）

## 3. 构建与验证状态（截至本会话收口）

- 四档 CI 曾全部失败：`32576097284`、`32576100468`（旧）；`32578257466`、`32578259118`（resync 后）。失败点均为 `package/kernel/mt76`——`mt76_connac_mcu.h` `UNI_PER_STA_INFO_TAG` redeclaration（F60）。
- 根因：`patches/packages/mt76-0003-…` 重建时两处重复——① 第一 hunk `PER_STA_INFO_MAX_NUM`+`enum UNI_PER_STA_INFO_TAG` 块重复；② mcu.c hunk `mt7996_mcu_get_per_sta_info()` 整个函数重复。
- 已修复（commit `d52fdfa`）：① 第一 hunk 去重，行数 `+1409,20`→`+1409,13`；② mcu.c hunk 删除第二份函数，行数 `+5576,218`→`+5576,112`。
- 本地复验：`audit-patches.sh --experimental` ✅（46）；对 mt76 pin 59676919 全序应用 10 个 mt76 补丁 ✅，`UNI_PER_STA_INFO_TAG` 与 `mt7996_mcu_get_per_sta_info` 各仅 1 处，`mt7996_mac_sta_poll` 已删净。
- 已知坏 run 已取消（`32588295907`、`32588297146`）；新 dispatched（commit `d52fdfa`）：
  - all = `32588516036`
  - experimental = `32588517827`

## 4. 实机可用命令

```bash
cd /root/workspace/xr1710g-openwrt
# 登录
ssh -i .ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=.ssh/known_hosts root@192.168.123.1
# 或
./.ssh/ssh-device

# LED 失败点追踪
ssh root@192.168.123.1 'sh -x /etc/rc.common /etc/init.d/led start' > /tmp/ledx.log 2>&1

# wifi down/up 复现（已跑 3 轮未复现，见 issue #10）
DEVICE_HOST=root@192.168.123.1 ./scripts/device-wifi-downup-probe.sh
```

## 5. 当前 patch 层速览（默认档 ROOT）

`9000/9001/9002` 板级 → `vendor/03` cpufreq → `vendor/10` pstore → `9017` apps-pack → `9018` VLAN/PPPoE → `9019` CLIENTS 计数 → `9020` memory_regions DT → `9021` sysfs stats → `9022` IPv6/UDP 判读 → `9023` 优雅降级 → `9025` no-carrier rx stats → `9010` txpower ucode → `vendor/11` LRO → `9011–9016` 08 切片 → `9027` ledtrig-netdev link mode。
实验档另有：`vendor/02/04/05/06/07/09/17/18`、`9024`、`9026`、`mt76-0005/9990/9991/9992/9993`、`mac80211-411`。
mt76 包补丁默认档：`mt76-0001/0003/0006/0007/0008`。

## 6. 上游状态快照（2026-08-22 第二会话查询）

- `openwrt/openwrt` master：`3d1645ee`（08-21）。本地 dry-run 绿。
- `OpenWRT-fanboy/OpenW1700k` `ubi2-oc`：`ba58ba46`（08-21）。**已再同步**：06=`c0ed8295`、07=`5b917d4b`、mt76-0005=`e7a8143`；实际 diff 均与仓库内一致，仅 hash/文件名更新。
- `YYH2913/openwrt` `xr1710g-6.18-integration`：`e88fbe28`（08-19）。**已再核对**：mt76 0006/0007/9990/9991/9993、mac80211-411、regdb 510/520/530 均无需重建；新增携带 9992（F59）。
- `openwrt/mt76` master：`c5a3bd91`（08-22）。**本仓库 mt76 追踪对象**：每次会话 / 2h sync 后查询 `openwrt/mt76` 最新 master，并与 OpenWrt main 当前 pin 对比；有更新及时评估吸收，不得只看不跟。
- `59676919...c5a3bd91` compare（GitHub compare API / `git diff`）：**147 commits、76 files、+3038/-482**。
  关键已上游更新（MT7996 相关）：PS-sync 死循环修复（=`mt76-9992`，pin 升级后可删）；EEPROM 长度/地址边界校验；`mt7996_mcu_get_chip_config` TLV 遍历边界；RX `band_idx` 校验；mmio copy 越界修复；SER/full reset 稳定性一批；MLD/MLO 修复；EHT-MCS15/HE DCM/VHT STBC 能力修复；WED/NPU/RRO offload 修复。
  我们仍独有的补丁：`mt76-0001/0003`（token_info/NPU debugfs、MCU 站点统计替代 WTBL 轮询，master 仍无 `token_info` 且仍调用 `mt7996_mac_sta_poll`）、`0006/0007/0008`（txpower/eeprom 功率解锁）、`0005/9990/9991/9993`（TXFREE 静默/EHT 广告/320M BF fallback/op_mode 传递）。
- `openwrt/openwrt` main 仍 pin mt76 `59676919`（`package/kernel/mt76/Makefile`，2026-07-01）。**追踪原则**：OpenWrt main bump 则优先跟 bump；若 main 迟迟不 bump 且 master 含有影响 MT7996 的重要修复/安全更新，在遵守锁源铁律（`PKG_SOURCE_VERSION` + `PKG_MIRROR_HASH` 实算，禁止 fork/hash=skip）的前提下，以本仓库补丁自行 bump `package/kernel/mt76` 到指定 commit。
- 跟踪 PR：
  - 仍 open：#22397、#22029、#22473、#22532、#22533、#24034、#24619、#23990。
  - 已 merged：#21777/#23078/#23383/#21978/#22391/#24593/#22289/#23427。
  - 注意：F56 已更新——#21978 已 merged，openwrt main patches-6.18 已含 `609-04` PCIe x2 与 `913` PCIe HB reset；pcie2 x1 硬件限制仍成立，Gen3 x1 仍未验证。

## 7. 遗留/下一步

1. **查 build**：`32588516036`（all）、`32588517827`（experimental）。都绿后刷机验证：
   - #4：`cat /sys/kernel/debug/ieee80211/phy0/mt76/token_info`；`strings mt7996e.ko | grep mt7996_mac_sta_poll` 应消失。
   - #14：`/etc/init.d/led start` 退出码 0，无 `write error`。
   - #15：`TOGGLE_10G=1 ./scripts/device-hw-probe.sh` 复验增量归零。
   - #1 E2：实验档 `nft add rule bridge ... flow offload @br_offload` 返回 0。
   - 9992：实验档 mt76 PS-sync 事件解析回归（重点观察 mt7996 MCU 事件日志无异常/无死循环）。
2. **#10**：当前固件 3 轮 down/up 未复现；新固件刷入后再跑 5 轮 + 串口。
3. **#5/#6/#13/#16**：维持 issue 跟踪；#6 需实机 xfrm/ESP 评估；#13 等 #24034；#16 可在新主线基础上重测 Gen3 x1。
4. **#7**：用户明确“护栏暂时不做”，保持 F34/F49 跟踪，等串口复现。
5. **吸收 mt76 最新内容（下一步重点）**：
   - 目标：从当前 pin `59676919` 吸收 `openwrt/mt76` master `c5a3bd91` 中与 MT7996 相关的修复（清单见第 6 节）。
   - 首选路径：等待/推动 OpenWrt main bump `package/kernel/mt76`；若 main 已 bump，`sync-upstream.sh` 后重新验证本仓库 mt76 补丁。
   - 自 bump 路径（main 未 bump 时）：新增 `patches/root/9028-mt76-bump-<sha>.patch`，修改 `package/kernel/mt76/Makefile` 的 `PKG_SOURCE_DATE/PKG_SOURCE_VERSION/PKG_MIRROR_HASH`（hash 从官方 tarball 实算，禁 `skip`）；随后用 `verify-copy-patches.sh` 对 mt76 全套补丁真实应用验证。
   - 升级后清理/复核：
     1) 删除 `mt76-9992`（上游 `06b6976` 已合入同款 PS-sync 修复，携带理由消失）；
     2) 逐条复核 `0001/0003/0006/0007/0008` 与 `0005/9990/9991/9993` 是否仍可应用、是否仍必要（`git apply --check` + 源码语义比对）；
     3) `scripts/audit-patches.sh --experimental` + `scripts/apply-patches.sh <tree> --dry-run --experimental` 全绿；
     4) CI `all` + `experimental` 构建绿后实机回归：token_info、PS-sync 事件日志、三频功率、EHT320。
6. **注意**：`lav_select` 后端仍 402 余额不足，调用前先 `lav_ping`；不可用时按工程判断并记录。

## 8. 宿主环境备忘

- 容器缺 `make/gawk/mkhash` 等完整 OpenWrt 构建工具；本地只做 patch 生成、审计、ssh 实机验证。真正构建以 GitHub Actions 为准。
- `gh api`/`curl` 偶发 429/EOF；遇到空输出先重试，再检查 token：`export GH_TOKEN=$(cat .gh-token)`。
- 推送优先用 token URL（见第 0 节）。
- 本地浅克隆 openwrt master：`/tmp/openwrt-src`（partial clone）；源码缓存：`/tmp/copy-patch-verify`（wireless-regdb/mt76/u-boot tarball）。
- fanboy 提取临时仓库：`/tmp/fanboy-extract`；mt76 pin 源码：`/tmp/mt76-59676919`；YYH 资产：`/tmp/yyh-assets`。
