# HANDOFF — 交接文档（2026-09-07 更新：上游吸收批次待办与交付物，见 §9）

> 接任维护者请先读：`README.md`、`CONTEXT.md`、`docs/FIXES.md`（F01–F78）、`docs/adr/0001`、`docs/adr/0002`、`docs/ROADMAP.md`。

## 0. 工作区与远程

- 本地仓库：`/root/workspace/xr1710g-openwrt`
- 当前分支：**`main`**（`feat/antenna-eeprom-power-unlock` 已于 2026-08-30 19:44 UTC 合入 main，merge commit `3a7257c`；`feat/absorb-npu-fdk-offload-oc` 已于 2026-08-31 合入 main，merge commit `ecb1191`）
- 当前 commit：以 `git log --oneline -1` 为准（`aba19bf` 起：9035 转 default + 04 config 上下文重建；`#94` all / `#96` experimental 均 success）。关键节点：`3a7257c` = antenna 合并点；`e0cbe4a` = 实验档毕业批次；`ecb1191` = NPU FDK 分支合并点；`602d9d0` = P1/P2 修复后主推送（build #87/#88/#89 全绿）
- 远程：`https://github.com/genshanxinli/xr1710g-openwrt`（默认分支 `main`）
- 推送到 main（**push 会自动触发 build.yml——push 事件默认 stock 档**——与 sync-upstream）：
  ```bash
  export GH_TOKEN=$(cat .gh-token)
  git push "https://x-access-token:${GH_TOKEN}@github.com/genshanxinli/xr1710g-openwrt.git" main
  ```
  > 本宿主 `git push origin` 常无输出/超时，直接用 token URL 最稳；`gh api`/`curl` 偶发 EOF/429，重试 1–2 次即可。
- `feat/absorb-npu-fdk-offload-oc`（`001f98b`）已于 2026-08-31 合入 main（merge `ecb1191`）：NPU FDK 构建脚本/补丁 + 专用 CI workflow + LED 探测 uci-defaults + 9035 #EXP 入库；ci-79/ci-81/ci-84(stock)/ci-86(experimental)/npu-fdk#5#7 均已绿。**合并后主推送 `602d9d0` 的 build #87(stock push)/#88(all)/#89(experimental) 均 success。**
- 旧分支 `feat/npu-fdk-build-workflow` 的 FDK 三文件与上述分支逐字节一致（已被吸收），可删。本地 worktree `tmp/wt-absorb-npu-fdk` 已随合并归档。

## 1. 仓库是什么

Gemtek XR1710G（Airoha AN7581 + MT7996 三频 Wi-Fi7、2×10G + 2×1G）的**自用 OpenWrt 叠加层仓库**：
- 基线 = `openwrt/openwrt` master（kernel 6.18）；板级/功率/诊断等未合入内容全部由 `patches/` 携带。
- 铁律：**修复而不是降级**；上游已吸收能力的冗余补丁应撤下（非降级）。
- `patches/MANIFEST` 是实际应用清单；`patches/ORDER` 是档位评审视图，二者必须一致。
- 构建：`scripts/build.sh <stock|oc-1.3|oc-1.4|experimental> [树]`；CI：`.github/workflows/build.yml`（workflow_dispatch：profile=all/stock/oc-1.3/oc-1.4/experimental）、`sync-upstream.yml`（2h dry-run）、`collect-sources.yml`（收集内核/mt76 prepare 后源码片段）。
- 实机：`root@192.168.123.1`，优先免密（`.ssh/id_ed25519`），否则密码 `password`。

## 2. 本会话完成的事（别重复做）

1. **执行 IP-EVAL A1–A12 吸收批次**（commit `46600b2`，已推送）：
   - A1/F64 reserved_bmt 66MiB 布局对齐：`9001/9002` ubi `0x1b700000` + reserved_bmt `@1be00000 0x04200000`；`docs/FLASHING.md` 布局表。
   - A2/F65 compat 一致性：A1 已把布局升到 2.0，`9000` 保持 `DEVICE_COMPAT_VERSION := 2.0`。
   - A3/F66 rdinit：`9001` chosen bootargs 加 `rdinit=/sbin/init`。
   - A4/F67 风扇单控制器：重写 `files/etc/init.d/fan`（动态探测 + 迟滞/最低稳定档/满速兜底）；`9017` 移除 fancontrol 的 `/etc/init.d/fan`，仅留 LuCI 前端/RPC。
   - A5/F68：新增 `patches/packages/mt76-0009-report-only-terminal-tx-failures.patch`（default）。
   - A6/F69：新增 `patches/packages/mt76-0010-set-skb-device-for-npu-rx.patch`（experimental；用 `mt76_queue_is_npu_rx(q)` 覆盖 NPU RX 队列）。
   - A7/F70：新增 `patches/root/9030-flowsense-bump-1.1.8-r5.patch`；MANIFEST 顺序 9017→9030→9018…9023；`9022` 在 9030 基线上重建。
   - A8/F71：新增 `patches/root/9029-xr1710g-airoha-pcs-jcpll-tclvar-recal.patch`（生成内核补丁 `9992-net-pcs-airoha-jcpll-tclvar-recal.patch`）。
   - A9/F72：`docs/ACCEPTANCE.md` C2 客户端国家码双侧判据；`docs/FIXES.md` F02 备注。
   - A10/F73：`docs/FLASHING.md` 坏版本清单、8/11 候选锁版、kmod-mtd-rw 救砖。
   - A11/F74：`docs/ACCEPTANCE.md` 测试方法学节 + B6 + C3 外部端点判据；OC 报告 §①D 本机 iperf3 降级为 CPU 基线。
   - A12/F75：`scripts/device-hw-probe.sh` 新增 B2.1 10G PHY VEND1 `0x103/0x104`（phytool）+ B7 EFR32 去除断言；B2.1 已修正为 C45 MMD30 路径（借道 wan/lan3）并实机验证。
2. **本地验证全绿**：
   - `scripts/audit-patches.sh` ✅（default 35 / experimental 52）
   - `scripts/apply-patches.sh tmp/openwrt-src --dry-run` ✅：regdb 4、mt76 7、uboot 41 真实应用通过
   - `scripts/apply-patches.sh tmp/openwrt-src --dry-run --experimental` ✅：regdb 4、mt76 13、uboot 41 真实应用通过
3. **推送并 dispatch 新 CI**（commit `46600b2`）：
   - all = `32621215717`（stock/oc-1.3/oc-1.4）
   - experimental = `32621217391`
   - 旧的 e0e84e0 构建 `32619703715` / `32619704962` 已取消。

## 3. 构建与验证状态（2026-08-23；08-31 增量见下）

- `46600b2` 的 CI 已绿：all = `32621215717`（success）、experimental = `32621217391`（success）。
- `sync-upstream`（push 触发）对 `46600b2` 已绿：run `32621204454`。
- 2026-08-30/31 增量（当前状态）：
  - **ci-74**（experimental，dispatch 于 main@`790f57e`，openwrt base `r0-93cf01b`）实机复核全通过 → 毕业批次 `e0cbe4a`（详见 7.6）。
  - ci-79/ci-81（`feat/absorb-npu-fdk-offload-oc`）与 ci-80/ci-82（feat 分支 `3265af0`/`56466bd`）dispatch 构建全绿（产物见对应 pre-release）。
  - **合并 `3a7257c`（push main）自动触发**：build run **#83**（stock 档，合并后首个默认档固件——绿后产物即毕业批次的 stock 验证载体，见 7.3/7.7）+ sync-upstream **#182**（已绿）。
  - **P1/P2 修复后主推送 `602d9d0`**：build **#87**（push stock）、**#88**（workflow_dispatch all：stock/oc-1.3/oc-1.4）、**#89**（workflow_dispatch experimental）均 **success**；sync-upstream **#187** 已绿。stock **#87** 已 fresh flash 复验：LED 首启探测 rc=0、bridge-flow-offload 已安装且 nft bridge flow_offload `flags offload` 通过（见 7.7）。
- 历史参考：
  - F60–F62 已解决：mt76 c5a3bd91 bump（`9028`）+ `9994` mac80211 6.18 API 兼容层；`0001/0003` 已对 c5a3bd91 重建。
  - #14 LED interval 与 #22 getStatus 算术的修复（`9031`/`9020`）已含在本批构建中。

## 4. 实机可用命令

```bash
cd /root/workspace/xr1710g-openwrt
# 登录
./.ssh/ssh-device
# 或
ssh -i .ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=.ssh/known_hosts root@192.168.123.1

# LED 失败点追踪
ssh root@192.168.123.1 'sh -x /etc/rc.common /etc/init.d/led start' > /tmp/ledx.log 2>&1

# wifi down/up 复现（见 issue #10）
DEVICE_HOST=root@192.168.123.1 ./scripts/device-wifi-downup-probe.sh

# 硬件深度探针（A12 增强后）
DEVICE_HOST=root@192.168.123.1 ./scripts/device-hw-probe.sh
```

## 5. 当前 patch 层速览（2026-08-31 毕业批次后，与 MANIFEST 逐行核对）

**默认档 ROOT 链**（按应用顺序）：`9000/9001/9002` 板级（66MiB reserved_bmt + rdinit） → `vendor/03` cpufreq → `vendor/10` pstore → `9017` apps-pack（fancontrol 去 init.d） → `9030` FlowSense 1.1.8-r5 → `9018` VLAN/PPPoE → `9019` CLIENTS 计数 → `9020` memory_regions DT → `9021` sysfs stats → `9022` IPv6/UDP 判读 → `9023` 优雅降级 → `9032` PPE 每流 conntrack 统计 → `9025` no-carrier rx stats → `9027` ledtrig-netdev link mode → `9031` LED interval skip → `9033` RTL826x LED（#24034 carry） → `9028` mt76 bump → `9010` txpower ucode → `vendor/11` LRO → `9011–9016` 08 切片 → `9035` flow-stats 共存（ci-88 后转 default） → **ci-74 毕业并入**：`vendor/05` bridge offload → `vendor/06` nft L2 → `9024` deps/table → `9026` init/conntrack → `vendor/07` HW_RRO teardown → `vendor/09` HW1.1/2.1 compat → `vendor/17` cmonroe 稳定 → `vendor/18` smartrg 稳定。

**实验档仅剩 4 条**：`vendor/02`（EIP93）、`vendor/04`（DSA）、`9029`（JCPLL，待 10G 对端）、`mt76-0010`（NPU RX skb->dev，待 6G 客户端）。`9035`（FLOW_STATS=y 与 NPU offload 共存）已于 2026-08-31 ci-88 验证后转 default（config hunk 为 stock `=y` 上下文，置于 04 前；04 config hunk 已改为 FLOW_STATS=y 上下文）。

**mt76 包补丁默认档**：`mt76-0001/0003/0005/0006/0007/0008/0009/9990/9991/9993/9994`；另 mac80211 subsys `411`（9993 编译依赖，已随毕业转 default）。

## 6. 上游状态快照（2026-08-30 会话重新查询）

- `openwrt/openwrt` master：`93cf01b0`（08-29 23:43）。相对上次快照 `eb7a45bc`（08-26）+39 commits（自 `3d1645ee` 08-21 累计 +73）；新增为 realtek DSA/ETH 重构系列（~20 commits）、qualcommax 修复、kernel 6.12 bump（6.12.104/105/107）、openssl 3.5.8、RTL8221B PHY LED backport、mediatek filogic LED 等，**无 airoha/mt76/regdb/wifi-scripts 专项**，下轮 sync dry-run 风险低。
- `openwrt/mt76` master：`c5a3bd91`（08-22），无变化；openwrt main 的 mt76 pin 仍 `59676919`，本仓库 `9028` 仍领先 main，无需再 bump。
- `OpenWRT-fanboy/OpenW1700k` `ubi2-oc`：`765535cf`（08-30 00:27，再次整枝 rebase 到 openwrt master `93cf01b0`；08-25 快照 `bc33b93e` 已被重写）。`ubi2`= `f9ecdaf`（stock 去顶）；`ubi2-oc-auto` 与 `ubi2-oc` 同为 `765535cf`；`main`=`93cf01b0`（已同步 openwrt main）。**对当前栈逐 commit 提取内层 patch 与本地 vendor 复核**：06（`7828198`：650 修改 + 675-01/02/03 三新文件）、07（`4f19f7b`：0014）、mt76-0005（`171bc4b`，仅 hunk 偏移漂移）语义完全一致；08（`2bdb0df`）仍带 `wireless-regdb/patches/555-w1700k-fix.patch`——**与本仓库 `regdb-0521`+`regdb-0555` 语义完全重合，重叠已确认、无需吸收（F76）**；18 smartrg（`d623341`）`992-21` 仍为 83 行版、无进一步变化，**吸收仍未完成（F77）**。
- `YYH2913/openwrt` `xr1710g-6.18-integration`：`e88fbe28`（08-19），无变化；mt76 0006/0007/9990/9991/9993、mac80211-411、regdb 510/520/530 已核对。
- `naoki66/ImmortalWrt-for-Gemtek-XR1710G` master：`2c99fd68f`（08-30 16:26 UTC；08-25 快照 `604bf882`）。相对 pin `dd9ecfeef` +347 commits；`package/luci-app-airoha-recovery/` 仍 0 差异，`packages-xr1710g/` 无需升锁。**新 XR1710G 专项信息（F78）**：① "Merge XR1710G USXGMII fix"——LAN2 PHY dts 增 `reset-before-id-read` + `realtek,sds-mode = <0x88c6>`，新增 108 行内核补丁 `622-net-phy-realtek-allow-board-specific-RTL826x-SDS-mode.patch`（厂商 U-Boot 写 RTL826x SDS page6 reg3=0x88c6，Linux 公共初始化缺该板级设置）；② `055e2c903` LAN2 PHY 先复位再读 ID；③ `53d5cccb0` MT7996 WED offload；④ `a8ed1a381` mt76 "set skb device for mt7996 NPU RX" 与本仓库实验档 `mt76-0010` 语义逐行一致（印证，无需改动）；⑤ 其 "drop upstreamed cpufreq PM-domain fix" 系其自家基线判断——openwrt master `patches-6.18/` 仍无 939/940（#22029 未合入），`vendor/fanboy/03` 继续携带。
- `YYH2913/luci-app-mlo` `911912b`、`rchen14b/luci-app-w1700k-fancontrol` `2c6cc7a`：均无变化。
- `YYH2913/http-uboot(-xr1710g)`：master `53b73174`；最新 release 仍 `xg2010g_260821`（08-21），tag `xg2010g_260822` 未发布为 release，本轮无新 release。锁版仍按 FLASHING A1 的 v2026.07/`59060dde`，升级前继续核对 release 页 SHA256。
- wireless-regdb 上游（cdn.kernel.org）最新仍 `2026.05.30`，与 openwrt 包版本一致，无更新。
- openwrt feeds 最新：`packages`=`d5c4e00d`、`luci`=`6e1eb21f`（均 08-30）；`video`=`644a6626`、`routing`=`4b9891b9`、`telephony`=`5d68d53c`（与 08-26 快照一致）。
- 跟踪 PR：仍 open #22397（08-30 14:02 有新活动，head 仍 `e1fe2733a1`、最后代码提交 04-11，评论仍停在 03 月——review/CI 类活动，无新代码）、#22029、#22473、#22532、#22533、#24034、#24619、#23990、#24025（08-29 有活动）；已 merged #21777/#23078/#23383/#21978/#22391/#24593/#22289/#23427/#22564/#23566/#23828；closed 未合并 #22536；issue #21177 仍 open（01-02 后无活动）。
- 失效源：`Arthur97172/Gemtek-XR1710G-wrt-builder`、`hx801217/iStoreOS-for-Gemtek-XR1710G`、`luoyizhi1987/XR1710G-YYH-OC` 均 404（`Arthur97172/Airoha-wrt-builder` 仍存在）；文档引用待标注/替换。

## 7. 下一步（重点）：合并后首个 stock 固件的实机复核

> **run #83 实机复核已完成（2026-08-31）**：详细记录见 `docs/acceptance-results/2026-08-31-stock-ci83-main.md`。fresh flash 结论：毕业批次 default 档基本通过（compat 2.0、fw4 flow_offload uci-defaults、NPU v4/v6、EHT320、F68、wifi down/up、hw-probe 全绿）；发现 P1 LED 默认 sysfs 不匹配（已实机修 UCI，代码已合入 LED 探测 uci-defaults）、P2 stock 缺 bridge-flow-offload（已移入共享 seed）。后续历史流程（7.1–7.6）保留作记录。

### 7.1 先刷 stock（all run 的 stock 产物）

**重要（历史）**：A1 已改布局；刷机必须走 HTTP U-Boot 恢复页并选 **UBI 2.0**（旧布局设备上 `sysupgrade` 会被 compat 2.0 拒；不得 -F 强刷）：
1. PC 接 10GbE 口，DHCP；开机按 reset 进 `http://192.168.255.1`；
2. 布局选择器选 **UBI 2.0**（与 `9001/9002` 新布局匹配）；
3. 上传 `*-sysupgrade.itb` 刷入 stock。
> 设备已于 2026-08-30 刷入 stock `ci-69` 并完成 7.1 复核（见 7.5）；后续同布局可用 sysupgrade。

刷入后按序验证（判据见 FIXES F64–F75 / ACCEPTANCE）：

> 方法论：experimental = 默认档 + 实验档增量（`patches/MANIFEST` 的 `#EXP` 条目），下列功能项可先在 experimental 固件上预验；标 `〔E✓ 见 7.4〕` 的项已在 CI#70 experimental 实机预验通过。最终 stock 档放行仍需刷 stock 产物复核（尤其 stock 镜像的 `sysupgrade -T`、E2 档位元数据与 stock 包集合），不能把 experimental 预验直接记为 stock 验收。
> **stock 实机结果（2026-08-30，pre-release `ci-69` = `firmware-stock.tar.gz`，commit `46600b2`）详见 7.5 与 `docs/acceptance-results/2026-08-30-stock-ci69.md`。**

- [ ] 冷启动无 `rdinit=/init failed`（F66）— **仍失败（已知良性）**：HTTP U-Boot 默认 env 覆盖 DTS chosen，dmesg 仍见 `rdinit=/init failed: -2, ignoring`。需 U-Boot 侧补 `rdinit=/sbin/init` 或换 9002 U-Boot。
- [x] `/proc/mtd` 或 `cat /proc/partitions`：`ubi` size=`0x1b700000`、`reserved_bmt` size=`0x04200000`（F64）〔E✓ 见 7.4〕
- [x] `ubinfo -a` 无坏块；多轮重启不新增坏块（F64）— ci-69 stock：bad PEBs=0，2 轮 reboot 后仍 0、max erase counter=2。〔E✓ 见 7.4〕
- [x] `/etc/init.d/fan start` 后 `pwm1` 仅一个写入者；风扇曲线随温度切换；fancontrol 页面可读可设（F67/A4）— rc=0；单 `S99fan`；`luci.fan getStatus` 可读。〔E✓ 见 7.4〕
- [x] `led start` 退出码 0；hw-offloaded PHY LED 无 EINVAL（#14/9031）— **ci-69 stock 默认 sysfs 为 `mt7530_dsa-0:*`（新内核名），本 stock 内核实为 `mt7530-0:*`，已在设备 UCI 修正 4 个 1G LED 并删除 10G LED；`led start` rc=0、offloaded=1、无 EINVAL。**〔E✓ 见 7.4〕
- [x] `getStatus` RPC 返回 5 个 NPU memory regions（#22/F63，`ubus` 侧复测）
- [x] 有损链路 `iw dev wlanX station dump`：`tx_retries>0` 时 `tx_failed≈0`（F68/A5）— 5G 站点 tx_retries=74027/12937/1693，tx_failed=56/1/2；2.4G tx_retries=397/106，tx_failed=0。〔E✓ 见 7.4〕
- [x] 三频 AP 正常；6GHz C2 双侧国家码判据（AP US + 客户端 US 可见可连；非 US 不可见属预期）（F72/A9）— **仅 AP 侧**：6G EHT320/29dBm up；无 6G 客户端，客户端侧待物理终端。
- [ ] C3 无线速率用外部对端 iperf3（禁止本机 iperf3 当吞吐判据）（F74/A11）— 未测（需外部对端 + 160/320MHz 客户端）。
- [ ] 管理面改址回连 B6（F74/A11）— **按用户要求取消**（见 7.4）。
- [x] `DEVICE_HOST=root@192.168.123.1 ./scripts/device-hw-probe.sh` 全绿（F75/A12）— 脚本已加 DSA 前缀自动探测；B2.1 VEND1 `0x103=0x8261`/`0x104=0x1141` → RTL8261BE。

### 7.2 再刷 experimental（experimental run 产物）

stock 基本项通过后，同法刷 experimental（或同布局 sysupgrade），重点验证实验档新增：
- [~] A6/F69 mt76-0010 NPU RX skb->dev：仍 `#EXP`——需 6G 客户端；按用户口径延后（2026-08-31）
- [x] A7/F70 FlowSense 1.1.8-r5：`uci show npu-monitor.settings.air_eff`=80；`getStatus` 正常；9018-9023 无回归（ci-74）
- [~] A8/F71 JCPLL TCLVAR recal：仍 `#EXP`——需 10G 对端；按用户口径延后（2026-08-31）
- [x] 实验档既有项：EHT320/9990/9991/9993、TXFREE 0005、bridge-flow-offload 9024/9026 + `config/seed-config.experimental.diff`（issue #1 E1/E2/E3）——已毕业转 default（ci-74 实机）
- [x] `wifi down/up` 5 轮不复发（issue #10）——ci-74 实机 5 轮，BSS 均 ENABLED，客户端可重连

### 7.3 通过后收口

- ~~可毕业项转 default~~ **已完成**（`e0cbe4a`，ci-74 实机后毕业 12 项；剩余 `#EXP`：`vendor/02/04`、`9029`、`mt76-0010`，分别待 EIP93 实机/DSA 实机/10G 对端/6G 客户端）。
- **run #83 已复核**（`docs/acceptance-results/2026-08-31-stock-ci83-main.md`）；**run #87 修复后 fresh flash 复验通过**（`docs/acceptance-results/2026-08-31-stock-ci87-fixes.md`）：P1 LED 首启探测 rc=0、P2 stock 档 `bridge-flow-offload` 已安装并生成 `bridge flow_offload` flowtable。**run #88 experimental 也已 fresh flash 复验**（`docs/acceptance-results/2026-08-31-experimental-ci88-9035.md`）：9035 FLOW_STATS=y 共存验证通过（dmesg `NPU flow stats unavailable (-22)`、NPU offload 存活）；LED 探测在 `mt7530_dsa-0` 路径同样 rc=0。**注意：run 编号与档位**：#88=experimental，#89=all（oc-1.3/oc-1.4/stock，均 success）。**9035 已转 default**：a820ea0 起 default 链含 9035；aba19bf 重建 04 config 上下文后，#94 all（a820ea0，stock/oc 与 aba19bf 等价）与 #96 experimental（aba19bf）均 success。**#94 stock 已 fresh flash 复验通过**（`docs/acceptance-results/2026-08-31-stock-ci94-9035-default.md`）：dmesg `NPU flow stats unavailable (-22)`、NPU offload 存活、LED rc=0、bridge-flow-offload 正常。
- 继续跟踪 mt76/mac80211 上游联动 bump；合入后删 `9028`/`9994`，再验（08-30 复核：mt76 master 仍 `c5a3bd91`、main 仍 pin `59676919`，暂无动作）。
- 跟进 F77（fanboy `vendor/18` 83 行版吸收）与 F78（naoki66 LAN2 SDS-mode 评估，与 `9029` 对照）。
- 跑 `docs/ACCEPTANCE.md` 全项（含 D3 72h 长稳、C2/C3/B2 物理对端项），冻结 known-good tag。
  - **2026-09-07 D3 时长维度达标**：experimental `r0-93cf01b`（#88/#96 批次）连续运行 **7 天零重启、零内核报错**（dmesg 全缓冲仅已知良性项、pstore 空、无泄漏迹象；NPU/PPE offload、三频含 6G EHT320、双 10G RTL8261BE、风扇/LED 全健康，F75 四路探针 rc=0）。负载为轻负载家用，`2×10G + 三频高负载` 压力条件未达，D3 整项保持 open。详见 `docs/acceptance-results/2026-09-07-d3-longrun-7d.md`。旁证：`#EXP` 四条（02/04/9029/mt76-0010）随镜像无故障运行 7 天。

### 7.4 CI#70 experimental 实机结果（2026-08-23）

> 用户已把 CI#70（run `32621217391`，experimental，commit `46600b2`）刷入设备。详细记录：`docs/acceptance-results/2026-08-23-experimental-ci70.md`。

- 已通过：F64 新布局（bad PEBs=0）、F65 `sysupgrade -T`、F67 风扇单控制器、F68 tx_failed（2.4G/5G 站点）、LED 修复后 `led start` rc=0、wifi down/up 5 轮不复发、B1 WAN、B5 NPU 活动（含 IPv6 专项：conntrack `[HW_OFFLOAD]` 与 PPE BND v6 均出现，`scripts/device-npu-ipv6-probe.sh` rc=0）、device-hw-probe B2.1 10G PHY VEND1 判据（借道 wan/lan3 + C45 MMD30 读 `IFACE/<phy>:30/0x103`；实机 `0x103=0x8261`、`0x104=0x1141`，driver=RTL8261BE 10Gbps PHY）。
- 未通过/待办：
  - F66 仍见 `rdinit=/init failed`——9001 chosen bootargs 被 HTTP U-Boot 默认 env `bootargs` 覆盖；已写 UBI env 验证 U-Boot 不读取。需 U-Boot 侧补 rdinit 或换用 9002 U-Boot 后重验。
  - F69/F71/C2/C3/C4/B2 需物理对端/客户端，未测。
  - D3 72h 长稳未测：当前仅连续运行约 18h 且 dmesg 无内核报错；72h + 2×10G + 三频负载条件仍不满足，下一轮收口前补验。
  - E2 档位元数据：当前 CI#70 固件仍无档位标识；构建层已修（见下），待下一轮构建后实机验证 `DISTRIB_DESCRIPTION` 含档位。
- 本会话已修：LED sysfs 回归 `mt7530_dsa-0` → `mt7530-0`（`files/etc/config/system`、`scripts/device-hw-probe.sh`）；设备 UCI 已同步并验证。B2.1 MDIO 访问路径修复：10G PHY 挂在 mt7530-0 总线（PHYAD 5=lan2、8=lan1），lan1/lan2 的 Airoha GDM ioctl 返回 -95，改为借道 DSA 用户口（wan/lan3）以 C45 MMD30 读 `IFACE/<phy>:30/0x103`（`scripts/device-hw-probe.sh`）。E2 构建层注入 `CONFIG_VERSION_DIST="OpenWrt <profile>"`（`scripts/build.sh`、`.github/workflows/build.yml`），下一轮构建生效。`scripts/device-npu-ipv6-probe.sh` 末尾 sampler 日志路径修正，跑通 rc=0。B6 按用户要求取消。
- issue #5 判读补强：新增 `patches/root/9032`（`luci.airoha_flowsense` 新 RPC `getPpeFlowStats`），用 conntrack 双向 tuple 补每流 `ct_packets`/`ct_bytes`/`hw_offload`；已在设备 `ubus call luci.airoha_flowsense getPpeFlowStats` 验证可用。PPE debugfs 计数本身仍待上游。

### 7.5 stock ci-69 实机复核（2026-08-30）

> 用户已把 stock 产物（pre-release `ci-69` = all run `32621215717`，commit `46600b2`）刷入设备。详细记录：`docs/acceptance-results/2026-08-30-stock-ci69.md`。

- 已通过：F64 布局（ubi=0x1b700000/reserved_bmt=0x04200000、bad PEBs=0、2 轮 reboot 不新增）、F65 `sysupgrade -T`（ci-69 `firmware-stock.tar.gz` 中 sysupgrade.itb，sha256 `79ed39c0…`）、F67 风扇单控制器、`led start` rc=0（**设备 UCI 已按旧内核实际 sysfs `mt7530-0:*` 修正；ci-69 镜像默认 `mt7530_dsa-0:*` 是适配新内核的名称**）、F68 tx_failed≈0、F75/A12 `device-hw-probe.sh` 全绿（B2.1 `0x103=0x8261`/`0x104=0x1141` → RTL8261BE；已 `apk add phytool`）、B1/B3/B4/B5（NPU loaded、offload_bound>0；IPv6 探针 rc=0 并出现 `[HW_OFFLOAD]` 与 PPE BND v6）、C1 三频 up、stock 包集合与 ci-69 manifest 一致（设备 207 包 = manifest 206 + phytool）。
- 未通过/待办：
  - F66 仍见 `rdinit=/init failed: -2, ignoring`（已知良性；HTTP U-Boot 默认 env 覆盖 DTS chosen）。
  - E2 档位元数据：ci-69 旧构建仍无 `CONFIG_VERSION_DIST` 档位标识；构建层已修，待下一轮构建实机复核。
  - C2 客户端侧 / C3 外部对端 iperf3 / B2 双 10G 对打 / A3 恢复页 / D3 72h：需物理对端或客户端，未测。
- 本会话已修：`scripts/device-hw-probe.sh` 增加 DSA 前缀自动探测（`mt7530_dsa-0`/`mt7530-0`），使探针在两代内核上均可全绿；设备 UCI LED sysfs 修正并验证；设备安装 phytool 补齐 B2.1。

### 7.6 experimental ci-74 实机复核 + 实验档毕业（2026-08-31）

> 用户已刷入 pre-release `ci-74`（`firmware-experimental.tar.gz`，`r0-93cf01b`）。详细记录：`docs/acceptance-results/2026-08-31-experimental-ci74.md`。

- 已通过（非 6G/10G 项全部通过）：E2（`OpenWrt experimental SNAPSHOT r0-93cf01b`）、F64 布局、F65 `sysupgrade -T`（本机 `compat_version` 缺失已修，仓库默认配置已补 2.0）、F67 风扇、LED（6 个 PHY LED `offloaded=1`，含 10G `:05`/`:08`）、F63 NPU 5 regions、B5 NPU IPv4（offload_bound=12/total=134；conntrack `[HW_OFFLOAD]` 31+）、B5 IPv6（`ct6_hw` 25/`bnd6` 12）、bridge-flow-offload E1/E2/E3、C1 三频、issue #10 wifi down/up 5 轮无复发、F68 tx_failed≈0、F75/A12 device-hw-probe 全绿（B2.1 RTL8261BE、C4 10G LED count=2）、B1/B4/D1/D2。
- 延后/未闭环：F66 良性 `rdinit` 假警告；D3 72h 未满；C2/C3/F69（6G 客户端）、F71/B2（10G 对端）按用户口径延后；02 EIP93、04 DSA 继续 `#EXP`。
- 毕业执行：`mt76-0005`、`mt76-9990/9991/9993`+`mac80211-411`、`vendor/05/06`+`root/9024/9026`、`vendor/07/09/17/18` 已从 `#EXP` 转默认（MANIFEST/ORDER 已同步）。
- 默认配置补强：`files/etc/config/system` 补 `compat_version '2.0'`；新增 `files/etc/uci-defaults/99-xr1710g-flow-offload` 默认开启 fw4 `flow_offloading`/`flow_offloading_hw`。

## 8. 宿主环境备忘

- 容器缺 `make/gawk/mkhash` 等完整 OpenWrt 构建工具；本地只做 patch 生成、审计、ssh 实机验证。真正构建以 GitHub Actions 为准。
- `gh api`/`curl` 偶发 429/EOF；空输出先重试；`export GH_TOKEN=$(cat .gh-token)`。
- 推送优先用 token URL（见第 0 节）。
- 本地浅克隆 openwrt master：`/root/workspace/xr1710g-openwrt/tmp/openwrt-src`（partial clone）；源码缓存：`tmp/copy-patch-verify`。
- 社区源码临时仓库：`/tmp/orangeyoo-xr1710g`、`/tmp/gilly-w1700k`、`/tmp/naoki66-xr1710g`、`/tmp/lvcdy-xr1710g`。
- mt76 bump 调试树：`tmp/mt76-bump/`；fanboy/YYH 资产若已清理则按 `fetch-sources.sh` 重取。
- **新宿主（2026-09-07 起）**：仓库在 `~/项目/xr1710g_openwrt/xr1710g-openwrt`；无 `.gh-token`（旧宿主遗留）。ssh 免密已重建：`.ssh/id_ed25519`（新钥）+ `.ssh/ssh-device` wrapper（本宿主 `/etc/ssh/ssh_config.d/20-systemd-ssh-proxy.conf` 属主损坏，wrapper 固定 `-F /dev/null` 绕过；首参含空白自动补 `DEVICE_HOST`）。沙箱每次 bash 调用 `/tmp` 隔离，probe `OUT_PREFIX` 须指向工作区 `tmp/`。


## 9. 2026-09-07 会话：上游吸收批次（待办与交付物）

> 背景：openwrt 2026-09-01 bump mt76（59676919→be5ce791，a46721f0/6c315233），导致 sync-upstream 自 08-31 20:03Z（run 33433908434）起连续失败约 7 天、build 无新产物。
> 本会话已完成 **CI 修复批次**（commit **be72915**，已推送 main）：删 9028/9994、重建 9010/9014；本地 dry-run 55/55 全绿，**sync-upstream 已恢复绿**（run 34097546620）。
> 并行五路吸收调研（mt76 / YYH2913 / fanboy / naoki66 / 社区上游）完成，结论见 §9.2 交付物。
> **aa4c8cb1**（issue #7 防御补丁族 9036/9037 #EXP + 分析文档）：调研子代理直接提交推送，dry-run 已验证通过（55/55），流程越权已记录。

### 9.1 上游吸收执行手册（工作包版，2026-09-07 编排，待下会话执行）

> **执行规则**：① 素材已全部就位（工作区 tmp/，勿重取）；② 每个工作包独立可验证；③ 补丁必须过
> `audit-patches.sh`（hunk 行数一致）与 `apply-patches.sh --dry-run --oc --experimental` 全链验证，
> 拷贝类补丁另需 verify-copy-patches 或等效手工 `patch -p1` 真实应用；④ 完成后更新 FIXES.md 对应条目
> 与 §9.1 勾选；⑤ **本会话起暂不推送（用户指示）**——吸收 commit 留在本地，待用户确认后统一推送。
> ⑥ 验证树 rsync 勿带 --delete（会误删 openwrt 树 scripts/patch-kernel.sh）。

**已完成（2026-09-07，已推送）**：P0 批次 be72915（删 9028/9994、重建 9010/9014；dry-run 55/55 绿、
sync-upstream 恢复绿）；mac80211-411 重建 b978e02（backports-7.2，ci-97 构建验证中）；
9036/9037（issue#7 防御补丁族，#EXP 已入库 aa4c8cb1，dry-run 已验证）。

**P1 工作包（按依赖顺序）**：

- **WP-9029｜9029 内层按 rdmitry PR#143 机制重写**
  现状：9029 大概率无效（①重写与首次相同的 VCOVAR/TCLVAR=硬件 no-op——rdmitry devmem 实测；
  ②bringup 时点过早，须 airoha_pcs_config() 末尾、PLL 运行 + AN enable 后）
  素材：`tmp/research_20260907/rdmitry/pr143.diff`（+pr144.diff、pcs-an7581.c、pcs-airoha-common.c、310-09.patch）
  步骤：a) 提取 post_config hook 机制（match-data，仅 an7581_pcs_eth）；b) 对照本地 9029 内层与
  master 310-09 pcs 源码重建；c) TCLVAR 0x3→0x5 脉冲 + ETH/PON 分值 0x5/0x3；d) 源码真实应用 + audit + dry-run
  实机：devmem 0x1fa7a030 一行实证（写 0x1D 后 lan2 link）→ 冷启动 5/5 → F71 收口
  落点：patches/root/9029（档位/文件名不变）；FIXES F71 更新

- **WP-0011｜mt76-0011（NTB NPU RX ownership 补丁①）**
  素材：`tmp/research_20260907/ntb_patch5.txt`（署名 Oever González，未托管仓库）
  现状：对 be5ce791 npu.c `git apply --check` RC=0；修 consume 侧越界 walk panic + refill 零地址竞态；
  本地默认 NPU offload（9035 default），同硬件风险真实（作者 W1700K 3/3 wedged→5/5 存活）
  步骤：a) 写入 `patches/packages/mt76-0011-wifi-mt76-npu-fix-rx-descriptor-ownership.patch`（default 档）；
  b) MANIFEST/ORDER 注册；c) verify 校验（下载 be5ce791 tarball + patch -p1）
  完成判据：dry-run verify 全绿；CI 构建通过；实机 NPU 长时间稳定
  注意：与 0010（skb->dev）同域不同文件

- **WP-SerDes｜SerDes/SDS bundle（622+743/744+dts 增量）**
  素材：`tmp/yyh2913-patches/b74553b.patch`；naoki66 报告 `tmp/naoki66-0907-absorb-report.md`（d3a0fa1/09feeff）
  步骤：a) 提取 622（RTL826x SDS-mode；按 09feeff 适配 6.18.44——删 export hunk）；
  b) 提取 743/744（restore-optional-RTK-SerDes / reapply-RTK-SerDes-after-aneg）；
  c) 9001 dts 增量：phy5 加 `realtek,sds-mode=0x88c6` + `reset-before-id-read` + `patch-rtk-serdes`；phy8 加 patch-rtk-serdes；
  d) 检查 rtl826x_phy_patch_sds_set 可见性（static 需回补 export hunk）；e) root 9041 号段 experimental bundle
  实机：10G/2.5G link 率 + AN_STATS_0；与 9029 互补对照

- **WP-USXGMII｜USXGMII 稳定化 625/628**
  素材：`tmp/yyh2913-patches/e61a1bb.patch`（含 625 rate adaptation / 628 SDK-crossing RX 校准 / 629 TX FIR——**629 不吸收**）
  步骤：a) 提取 625+628；b) 对 master pcs/airoha（310-09）重建；c) root 9037-9038 号段 experimental
  实机：10G 冷启动×20 + FBCK_LOCK dmesg + #22397 ifdown/up 复现；**628 疑为 LAN2 "No FBCK Lock" 真根因**

- **WP-delsta｜NPU del_sta（naoki66 2d3aa30）**
  素材：naoki66 仓库 master（pin=be5ce791 同基线；git fetch 2d3aa30）
  现状：上游未含（be5ce791 无 mt76_npu_del_sta；宏 WLAN_FUNC_SET_WAIT_DEL_STA 已在 airoha_offload.h L122）
  步骤：整文件移植为 `patches/packages/mt76-0012-...`（experimental）+ MANIFEST/ORDER
  实机：断开→同 MAC 重连 ~1Mbps 残留修复；与 0010/9019/9035 无重叠

- **WP-pinctrl｜pinctrl force-GPIO（YYH2913 436765d）**
  素材：`tmp/yyh2913-patches/436765d.patch`
  背景：9001 phy5/phy8 reset-gpios=GPIO46/31 存在"reset 写了但 pad 未 mux 成 GPIO"隐患
  步骤：按 master 203-01/203-02（已部分上游化）后状态重建；root 9040 号段 experimental
  实机：/sys/kernel/debug/gpio 46/31 方向 + PHY 复位行为

- **WP-PPE｜PPE 本地流留 CPU（YYH2913 916e91a）**
  素材：`tmp/yyh2913-patches/916e91a.patch`
  依赖：hurryman 9990 底座（hurryman2212/OpenW1700k-test offload-oc）——先评估整体 vendor 可行性
  步骤：a) blobless clone hurryman2212/OpenW1700k-test 取 9990；b) 916e91a 重建；c) root 9039 号段 experimental
  实机：路由器自发 UDP 高速流对照 GDM 计数；与 9035 同文件不同区（dry-run 确序）

- **WP-F77｜992-21 83 行版（F77 收口）**
  素材：`tmp/ow1700k-ubi2oc`（e352c48 的 992-21-net-airoha-npu-init-stability.patch 83 行版；992-20 184 行）
  步骤：a) 提取 992-21（新增 mbox 轮询 1000→500ms hunk）；b) 更新 vendor/fanboy/18 → 对 master 重建 + verify；
  c) 实验档回归后转 default
  与 9030/9032/9020 不重叠；FLOW_STATS 共存回归

- **WP-675｜新 675 系列（vendor/06 替换 + 9026 复核）**
  素材：`tmp/ow1700k-ubi2oc`（2ed1af79c7：675 系列精简 -28%，去 650/KEEP_HW，nf_ct_bridge_inner 重构）
  步骤：a) 提取 2ed1af79c7 的 675 新内容；b) 替换 vendor/06 内核件；c) 9026 对新 675-02 复核（DEPENDS 修正保持）；
  d) 650 KEEP_HW 增量去留评估；e) 实验档实机回归（bridge+FLOW_STATS 共存）后转 default

- **WP-vendor07｜vendor/07 内层 0014 按 be5ce791 重生成**
  现状：wed_rro_event 行号 1043→766；依赖 mt7996_mcu_wed_rro_reset_sessions（mcu.c:5611）/
  mt7996_has_hwrro（mt7996.h:851）在 be5ce791 均存在；与上游 bd49f06 互补不冲突；
  **fanboy 已在重建中删除同款——本地继续自持观察**
  步骤：a) 下载 be5ce791 mt76 源码（codeload）；b) 0014 按新行号重生成；c) 验证：对 be5ce791 应用 + dry-run

**P2（可选/低优先）**：OPP dts 增量（naoki66 bb84606：smcc_opp15-18，OC 档重建，保留 oc-limit 1300）；
PPE bind_rate 补丁②（`tmp/research_20260907/ntb_patch6.txt`，对 6.18 airoha_ppe.c:148 重建）；
20260721 mt7996 固件覆盖层（不跟 fork，需时自制）；e4e7c4f 仅跟踪（FIXES 记录 NPU probe deferred 语义依赖）；
#24973 PCS fwnode DRAFT 每轮 sync 跟踪；master→main 文案清理。

**不采用 / 等上游（勿重复工作）**：regdb 510/520 合并 30dBm（naoki66，合规回退——删 DFS flag 等）；
luci-app-airoha-factory（fw_env 指 stock env，本地 UBI env 布局不兼容，暂不预装）；MIB lossless
（上游 netdev 已合，等内核 bump——**届时 9025/F55 需同步重建**：清 MIB 与 delta 法冲突→改只同步 mib_prev）；
eeprom 0 值填充（Mironov aaf90b24，本机空转）；v1.5.0 前台 CAC（本地默认已前台，仅归档）；
上游 PR 全 open（#22397/#22029/#22473/#22532/33/#24034/#24619/#23990/#24025 → 9000-9002、vendor/03 继续携带）。

**执行环境（验证树，通用）**：
```bash
cd tmp && git clone --depth 1 https://github.com/openwrt/openwrt.git owrt-absorb
rsync -a --exclude='.git' --exclude='.github' --exclude='tmp' --exclude='docs/acceptance-results'   xr1710g-openwrt/ owrt-absorb/
cd owrt-absorb && ./scripts/apply-patches.sh . --dry-run --oc --experimental
# 单补丁验证：mt76 @ be5ce791（codeload tarball be5ce7910521492d4a2e4ce7ee3843680a46c047）；
# mac80211：tmp/research_20260907/bp72/backports-7.2（已解包）
```

### 9.2 交付物（报告/方案/证据）

| 文件 | 内容 |
|---|---|
| \`上游吸收方案-2026-09-07.md\`（工作区根） | 吸收方案汇总（P0-P3 表 + 实机回归清单 + 不采用清单） |
| \`评估-YYH2913-08-31八提交-吸收评估.md\`（工作区根） | YYH2913 8 提交逐项评估（9036-9041 号段落点；9025 联动重建） |
| \`fanboy-ubi2oc-09-06重建评审报告.md\`（工作区根） | fanboy 整枝评审（992-21/675 系列/HW-RRO 删除/20260721 固件） |
| \`tmp/naoki66-0907-absorb-report.md\` | naoki66 提交评估（411 重建/SerDes/SDS/factory/regdb/OPP） |
| \`tmp/research_20260907/\` | rdmitry PR#143/144 diff、NTB 补丁全文、backports-7.2 解包、论坛 JSON |
| \`tmp/research/dryrun-logs/\` | 四轮 dry-run 复现日志（9028/9010/9014 漂移证据链） |
| \`docs/analysis-issue7-flow-offload-reboot.md\` | issue #7 离线根因分析（aa4c8cb1 提交） |

### 9.3 上游状态快照（2026-09-07 重新查询）

| 源 | 快照（vs 08-30） |
|---|---|
| openwrt master/main | fe4bb132（09-06 推送；默认分支已改名 main）；+98 commits：mt76 bump a46721f0/6c315233、wifi-scripts e21a4ef9/93d975fe、airoha 9550b20/2700e9b/e4e7c4f/928f5c5、mac80211 7.2、netifd e801f59 |
| openwrt mt76 pin | **be5ce791**（09-01）；mt76 包 patches/ 目录已空（上游删 100-mac80211-support-kernel-version-7.1.patch） |
| fanboy ubi2-oc | f08c3d1e（09-06 整枝；mt76 fork 01367e60=be5ce791+1 提交 + 20260721 固件）；ubi2=00ed581b；无新 release |
| YYH2913 integration | c82129e7（08-31，+8 提交：USXGMII/SerDes/PPE/MIB/pinctrl/px5g/DHCP） |
| naoki66 | 621c27093（09-07）；09-03 新固件 release（0e959250f7）；mt76 pin=be5ce791 与本地一致 |
| YYH2913/http-uboot 锁版 | 53b73174 无变化（锁版不受影响） |
| wireless-regdb | 上游 2026.09.03 新发布；openwrt 包仍 2026.05.30（本地 regdb 补丁无漂移） |
| openwrt feeds | packages=1056fa0f、luci=7dda604a（09-07） |
