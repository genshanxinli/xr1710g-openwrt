# HANDOFF — 交接文档（2026-08-22 会话收口）

> 接任维护者请先读：`README.md`、`CONTEXT.md`、`docs/FIXES.md`（F01–F58）、`docs/adr/0001`、`docs/adr/0002`、`docs/ROADMAP.md`。

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

1. **问题 fan-out**：20 个 open issue 各派一个 subagent 做根因分析并回复 issue；要求调用 `/llm-verifier`（本环境为 `lav_select`）。**注意：验证器后端 HTTP 402 INSUFFICIENT_BALANCE，无有效 logprob 打分**，subagent 均按工程判断 fallback。
2. **统一修复并推送当前分支**：
   - `9020-npu-memory-regions-dt.patch` — #3/#8：getStatus.memory_regions 改读 `/proc/device-tree/reserved-memory/npu-*`，补第 5 区 `npu-ba`。
   - `9021-flowsense-sysfs-stats.patch` — #9：getWanHealth/getBridgeStats 弃用 `ip -s`，改读 sysfs。
   - `9022-npu-ipv6-udp-visibility.patch` — #19/#20：IPv6 地址规范化 + `ip -6 neigh` + `client_bnd.ip6` + UDP `udp_hw`（conntrack 判读）。
   - `9023-npu-rpc-graceful-tools.patch` — #2：缺 devmem 时 getFrameEngine 返回 `available:false`、pll_freq_mhz 返回 `null`；seed 补 `ethtool/ip-bridge/tcpdump/iperf3`。
   - `9024-bridge-flow-offload-deps-table.patch`（#EXP）— #1 E1/E3：DEPENDS 改 `kmod-nft-offload`，表名独立 `flow_offload`。
   - `9025-xr1710g-airoha-no-carrier-rx-stats.patch` — #15：`airoha_dev_get_stats64()` 无 carrier 只清 MIB，不虚增 rx_errors/rx_dropped（生成内核补丁 `9991`）。
   - `9026-bridge-flow-offload-init-conntrack.patch`（#EXP）— #1 E2：`nft_flow_offload_init/destroy` 对 `NFPROTO_BRIDGE` 复用 `NFPROTO_INET` conntrack（生成内核补丁 `675-04`）。
   - `9027-ledtrig-netdev-link-mode-mutex.patch` — #14：写 generic `link` 时清除具体 link-speed 位，修第二个 PHY LED `led start` EINVAL。
   - `patches/packages/mt76-0001/0003` — #4：从 fanboy14 对 pin `59676919` 重建并重新启用（`token_info` debugfs + 去 `mt7996_mac_sta_poll` 改 MCU 统计）。
   - `files/etc/config/wireless` — #11（radio0 显式 `channel auto` + 注释）、#21（新增 `K2P-5G` 5G-only SSID + 注释化 HE80 档）。
   - `scripts/device-wifi-downup-probe.sh` — #10 只读取证脚本。
   - `docs/FIXES.md` F42–F58 新增；`docs/ROADMAP.md` 增 EIP93 项。
3. **seed 修正**：`CONFIG_PACKAGE_bridge` → `CONFIG_PACKAGE_ip-bridge`；`CONFIG_BUSYBOX_DEFAULT_DEVMEM` → `CONFIG_BUSYBOX_CUSTOM=y + CONFIG_BUSYBOX_CONFIG_DEVMEM=y`。
4. **CI 新工作流**：`collect-sources.yml` 已推送到 `main` 和当前分支；用于 prepare 内核/mt76 源码并上传 artifact，生成精确内核补丁。

## 3. 构建与验证状态（截至本会话收口）

- 上一轮已验证全绿：all=`32570450652` → `ci-47`；experimental=`32570452771` → `ci-48`（包含 9020–9026 + seed 修复，不含 9027/#4 重建）。
- 最新已 dispatch（包含 9027 + mt76 0001/0003 重建 + F56 文档）：all=`32576097284`、experimental=`32576100468`。**收口时仍在进行中，下一会话先查结果**。
- 最新 sync-upstream dry-run：`32576070147` ✅ success（在 #4 重建提交之后，说明补丁层对 openwrt main 当前 HEAD 可应用）。
- 本地已通过：
  - `scripts/audit-patches.sh` ✅（30 个补丁全部一致）
  - 新内核补丁内层 `patch -p1 --dry-run` 对 collect-sources 产物 ✅
  - 新 mt76 补丁对 pin `59676919` 源码 `patch -p1 --dry-run` ✅

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
实验档另有：`vendor/02/04/05/06/07/09/17/18`、`9024`、`9026`、`mt76-0005/9990/9991/9993`、`mac80211-411`。
mt76 包补丁默认档：`mt76-0001/0003/0006/0007/0008`。

## 6. 上游状态快照（2026-08-22 查询）

- `openwrt/openwrt` master：`3d1645ee`（08-21）。sync-upstream 绿，暂不需修。
- `OpenWRT-fanboy/OpenW1700k` `ubi2-oc`：`ba58ba46`（08-21）。⚠️ **分支已 force-push/rebase**；我们的 vendor 06/07 快照（`649ef957`/`4d61493e`）和 `mt76-0005`（`496c0f5e`）已分叉（ahead 25 / behind 6–15）。**下一步需重新同步并 dry-run 验证**。
- `YYH2913/openwrt` `xr1710g-6.18-integration`：`e88fbe28`（08-19）。⚠️ 我们 08-17/18 提取的 integration 资产后又有 30+ 提交（mt76 NPU lifecycle、PCIe reset、rate-control 等）。**下一步需重新提取 9990-9993/mac80211-411/txpower/regdb 并验证**。
- `openwrt/mt76` master：`c5a3bd91`（08-22）。仍无 `token_info`，`mac.c` 仍调用 `mt7996_mac_sta_poll`；我们的 `mt76-0001/0003` 在 mt76 master 上仍必要。OpenWrt main 仍 pin mt76 `59676919`。
- 跟踪 PR：
  - 仍 open：#22397、#22029、#22473、#22532、#22533、#24034、#24619、#23990。
  - 已 merged：#21777/#23078/#23383/#21978/#22391/#24593/#22289/#23427。
  - 注意：F56 已更新——#21978 已 merged，openwrt main patches-6.18 已含 `609-04` PCIe x2 与 `913` PCIe HB reset；pcie2 x1 硬件限制仍成立，Gen3 x1 仍未验证。

## 7. 遗留/下一步

1. **查最新 build**：`32576097284`（all）和 `32576100468`（experimental）必须绿；绿后刷机验证：
   - #4：`cat /sys/kernel/debug/ieee80211/phy0/mt76/token_info`；`strings mt7996e.ko | grep mt7996_mac_sta_poll` 应消失。
   - #14：`/etc/init.d/led start` 退出码 0，无 `write error`。
   - #15：`TOGGLE_10G=1 ./scripts/device-hw-probe.sh` 复验增量归零。
   - #1 E2：实验档 `nft add rule bridge ... flow offload @br_offload` 返回 0。
2. **fanboy 再同步**：重取 `ubi2-oc` `ba58ba46`，更新 vendor 06/07/0005，过 `apply-patches.sh --dry-run --experimental`。
3. **YYH2913 再同步**：重取 `xr1710g-6.18-integration` `e88fbe28`，重点核对 9990-9993、mac80211-411、txpower/regdb 是否需要重建。
4. **#10**：当前固件 3 轮 down/up 未复现；新固件刷入后再跑 5 轮 + 串口。
5. **#5/#6/#13/#16**：维持 issue 跟踪；#6 需实机 xfrm/ESP 评估；#13 等 #24034；#16 可在新主线基础上重测 Gen3 x1。
6. **#7**：用户明确“护栏暂时不做”，保持 F34/F49 跟踪，等串口复现。
7. **注意**：`lav_select` 后端仍 402 余额不足，调用前先 `lav_ping`；不可用时按工程判断并记录。

## 8. 宿主环境备忘

- 容器缺 `make/gawk/mkhash` 等完整 OpenWrt 构建工具；本地只做 patch 生成、审计、ssh 实机验证。真正构建以 GitHub Actions 为准。
- `gh api`/`curl` 偶发 429/EOF；遇到空输出先重试，再检查 token：`export GH_TOKEN=$(cat .gh-token)`。
- 推送优先用 token URL（见第 0 节）。
- 收集源码产物：`gh run view <run_id>` 或 API 拿 artifact，`python3 -m zipfile -e` 解包；当前源码产物路径 `/tmp/kernel-led-sources`、`/tmp/mt76-59676919`、`/tmp/mt76-9f95baf9`、`/tmp/mt76-rebase`。
