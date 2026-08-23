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

## 3. 构建与验证状态（2026-08-22 第三会话）

- F60 后 d52fdfa 构建仍全红——F61：`mt7996/mcu.c` `wlan_idx`/`res`/`i`/`wcid`/`ac` undeclared（0003 把 `UNI_ALL_STA_TXRX_AIR_TIME` case 重复插入到 `mt7996_mcu_ie_countdown`）。已修（commit `4805814`）。
- 尝试 mt76 自 bump c5a3bd91（commit `7ab2633`），四档 CI 仍全红——F62：c5a3bd91 期望新版 mac80211 API，openwrt main 当前 mac80211/kernel 头文件不匹配。
- 已解决：保留 bump，新增 `mt76-9994-mac80211-api-compat.patch` 把上述调用适配回 6.18 API（两参 tmpl、`IEEE80211_MIN_ACTION_SIZE+1`、`u.action.u.addba_req.*`）；commit `438a4f8`。
- 本地复验：`audit-patches.sh` ✅（default 32 / experimental 47）；`apply-patches.sh --dry-run --experimental` ✅（regdb 4、mt76 11、uboot 41 真实应用通过）。
- 坏 run：`32592330583`（all）❌、`32592333937`（experimental）❌；`32608174821`/`32608178233`（rollback 后 dispatch，已取消/待取消）。
- 下一步：重新 dispatch（commit `438a4f8` 之后）all + experimental，验证 mt76 c5a3bd91 + 9994 兼容层。

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

### 7.0 下一轮吸收任务（IP-EVAL 2026-08-23 可立即吸收项，全部执行）

> 评估清单：`docs/IP-EVAL-2026-08-23.md`；待吸收台账：`docs/FIXES.md` 末段 A1–A12；ROADMAP P0.5 已登记。
> 执行顺序 A1→A12，每完成一项转正为 `docs/FIXES.md` F63+ 台账行（问题→根因→载体→上游状态），并从 A 表与 ROADMAP P0.5 移除。

- **A1 reserved_bmt 66MiB 布局对齐（IP02/05/06/07/15，default）**：先实机抓 stock bootlog 核 XR1710G BMT 池（`bmt pool size: N` 与 vendor `system` 分区终点）；落地 `9001/9002`：ubi `0x1b700000`、`reserved_bmt@1be00000 0x04200000`；同步 `docs/FLASHING.md`。
- **A2 sysupgrade compat 一致性（IP15，default）**：`9000` 的 XR1710G `DEVICE_COMPAT_VERSION` 2.0→1.0（与当前布局一致）；A1 实证后恢复 2.0。
- **A3 rdinit 修复（IP17，default）**：`9001` chosen bootargs 末尾加 `rdinit=/sbin/init`。
- **A4 风扇双控制器去重（IP25，default）**：`files/etc/init.d/fan` 与 9017 内 fancontrol 的 `/etc/init.d/fan` 双入口抢 PWM——合并为单控制器 + 动态探测 + 迟滞/最低稳定档/失效满速兜底；9017 侧仅留 LuCI 前端。
- **A5 mt76 0099 tx_failed 记账修复（IP25/IP26，default）**：新增 `patches/packages/mt76-0009-report-only-terminal-tx-failures.patch`。
- **A6 mt76 0103 NPU RX skb->dev（IP25/IP26，experimental）**：新增 `patches/packages/mt76-0010-set-skb-device-for-npu-rx.patch`，按 `MT_RXQ_NPU0` qid 改写。
- **A7 flowsense 1.1.8-r5 bump（IP08，experimental）**：新增 `patches/root/9030-flowsense-bump-1.1.8-r5.patch`；9018-9023 需重放。
- **A8 JCPLL TCLVAR recal（IP10，experimental）**：新增 `patches/root/9029-xr1710g-airoha-pcs-jcpll-tclvar-recal.patch`。
- **A9 6GHz 客户端国家码判据（IP14，default 验收）**：`docs/ACCEPTANCE.md` C2 双侧判据；`docs/FIXES.md` F02 备注。
- **A10 FLASHING 坏版本/救砖（IP19，default 文档）**：`docs/FLASHING.md` 补 8/8 坏版本、8/11 `b7710e5cc851` 候选锁版、kmod-mtd-rw 救砖步骤。
- **A11 验收方法学补洞（IP20/24/28，default 验收）**：`docs/ACCEPTANCE.md` 测试方法学节 + B6 + C3 外部端点判据；`OC与高功率实现-调研报告.md` §①D 本机 iperf3 数据降级为 CPU 基线。
- **A12 device-hw-probe 增强（IP04，default 脚本）**：10G PHY 寄存器判据（VEND1 `0x103/0x104`）+ EFR32 去除断言。

1. **查 build**：`32588516036`（all）、`32588517827`（experimental）。已刷 #66（experimental，commit bde3f69）复查：
   - #4 ✅：`token_info` 存在；`strings mt7996e.ko` 无 `mt7996_mac_sta_poll`；getTokenInfo 返回正常。issue #4 已关闭。
   - #14 ⚠️：link/rx/tx 写入均 rc=0；但 `interval` 写入 4 个 PHY LED 均 EINVAL，`/etc/init.d/led start` 仍 rc=1（issue #14 保持 open）。
   - #15 ✅：lan1/lan2 down/up 各一次，rx_errors delta=0。issue #15 已关闭。
   - #1 E2 ✅：`nft add rule bridge npu_probe forward meta l4proto { tcp, udp } flow offload @ft` 返回 0；但 E1 `bridge-flow-offload` 包仍未安装（issue #1 保持 open）。
   - 9992：PS-sync 未做专项事件注入；`dmesg` 无 mt7996 MCU 异常。
   - 新增 issue #22：`getStatus` RPC 因 9020 的 `$((16#...))` 在 BusyBox ash 上不工作而整体 `Invalid argument`（F63）。
2. **#10**：#66 已复测 5 轮 `wifi down/up`，三频 AP 均恢复、logread 无 `Could not set STA`/`handle_assoc_cb`；仍未抓串口，issue 保持 open。
3. **#5/#6/#13/#16**：维持 issue 跟踪；#6 需实机 xfrm/ESP 评估；#13 等 #24034；#16 可在新主线基础上重测 Gen3 x1。
4. **#7**：用户明确“护栏暂时不做”，保持 F34/F49 跟踪，等串口复现。
5. **吸收 mt76 最新内容（下一步重点，F62 后更新）**：
   - 当前已携带 c5a3bd91 bump（9028）+ `mt76-9994` 兼容层（适配 openwrt main 6.18 mac80211 API）。待 CI all+experimental 验证编译。
   - 首选路径不变：等待/推动 OpenWrt main **联动 bump** `package/kernel/mt76` 与 `package/kernel/mac80211`；合入后删 `9028` 与 `9994`，`sync-upstream.sh` 再验。
   - 若 CI 仍暴露其它 API 不匹配：继续扩充 `9994`（先本地用 `apply-patches.sh` + `patch -f -p1` 验证，再上 CI）。
   - 升级后清理/复核：删 9992（已删）、逐条复核 mt76 补丁、audit + apply-patches 全绿、CI all+experimental 绿后实机回归（token_info、PS-sync 事件日志、三频功率、EHT320）。
6. **注意**：`lav_select` 后端仍 402 余额不足，调用前先 `lav_ping`；不可用时按工程判断并记录。

## 8. 宿主环境备忘

- 容器缺 `make/gawk/mkhash` 等完整 OpenWrt 构建工具；本地只做 patch 生成、审计、ssh 实机验证。真正构建以 GitHub Actions 为准。
- `gh api`/`curl` 偶发 429/EOF；遇到空输出先重试，再检查 token：`export GH_TOKEN=$(cat .gh-token)`。
- 推送优先用 token URL（见第 0 节）。
- 本地浅克隆 openwrt master：`/tmp/openwrt-src`（partial clone）；源码缓存：`/tmp/copy-patch-verify`（wireless-regdb/mt76/u-boot tarball）。
- fanboy 提取临时仓库：`/tmp/fanboy-extract`；mt76 pin 源码：`/tmp/mt76-59676919`；YYH 资产：`/tmp/yyh-assets`。
