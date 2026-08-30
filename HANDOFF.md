# HANDOFF — 交接文档（2026-08-31 更新：feat 分支已合并 main）

> 接任维护者请先读：`README.md`、`CONTEXT.md`、`docs/FIXES.md`（F01–F78）、`docs/adr/0001`、`docs/adr/0002`、`docs/ROADMAP.md`。

## 0. 工作区与远程

- 本地仓库：`/root/workspace/xr1710g-openwrt`
- 当前分支：**`main`**（`feat/antenna-eeprom-power-unlock` 已于 2026-08-30 19:44 UTC 合入 main，merge commit `3a7257c`；远程同名分支已删除，本地残留 tracking 引用已 `git fetch --prune` 清理）
- 当前 commit：以 `git log --oneline -1` 为准（合并时点 = `3a7257c`）。关键节点：`e0cbe4a` = 实验档毕业批次（ci-74 实机验证后 12 项 `#EXP` 转 default）；`46600b2` 及更早为历史构建 commit
- 远程：`https://github.com/genshanxinli/xr1710g-openwrt`（默认分支 `main`）
- 推送到 main（**push 会自动触发 build.yml——push 事件默认 stock 档**——与 sync-upstream）：
  ```bash
  export GH_TOKEN=$(cat .gh-token)
  git push "https://x-access-token:${GH_TOKEN}@github.com/genshanxinli/xr1710g-openwrt.git" main
  ```
  > 本宿主 `git push origin` 常无输出/超时，直接用 token URL 最稳；`gh api`/`curl` 偶发 EOF/429，重试 1–2 次即可。
- 进行中的平行分支（截至 2026-08-31，均未并入 main）：`feat/absorb-npu-fdk-offload-oc`（`6410bf3`，领先 main 2 commits：NPU FDK 构建脚本/补丁 + 专用 CI workflow；ci-79/ci-81 产物已出）、`feat/npu-fdk-build-workflow`（`b731d3a`）。接手前先确认这两条分支的去留。
- 上述两条分支以 **git worktree** 挂在本仓库下：`tmp/wt-absorb-npu-fdk`、`tmp/wt-npu-fdk-main`（主工作区在 `main`，勿在主工作区直接切到这两条分支）。

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

**默认档 ROOT 链**（按应用顺序）：`9000/9001/9002` 板级（66MiB reserved_bmt + rdinit） → `vendor/03` cpufreq → `vendor/10` pstore → `9017` apps-pack（fancontrol 去 init.d） → `9030` FlowSense 1.1.8-r5 → `9018` VLAN/PPPoE → `9019` CLIENTS 计数 → `9020` memory_regions DT → `9021` sysfs stats → `9022` IPv6/UDP 判读 → `9023` 优雅降级 → `9032` PPE 每流 conntrack 统计 → `9025` no-carrier rx stats → `9027` ledtrig-netdev link mode → `9031` LED interval skip → `9033` RTL826x LED（#24034 carry） → `9028` mt76 bump → `9010` txpower ucode → `vendor/11` LRO → `9011–9016` 08 切片 → **ci-74 毕业并入**：`vendor/05` bridge offload → `vendor/06` nft L2 → `9024` deps/table → `9026` init/conntrack → `vendor/07` HW_RRO teardown → `vendor/09` HW1.1/2.1 compat → `vendor/17` cmonroe 稳定 → `vendor/18` smartrg 稳定。

**实验档仅剩 4 条**：`vendor/02`（EIP93）、`vendor/04`（DSA）、`9029`（JCPLL，待 10G 对端）、`mt76-0010`（NPU RX skb->dev，待 6G 客户端）。

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

> **当前待办（2026-08-31）**：合并 `3a7257c` 已自动触发 build run #83（stock 档，main HEAD）——绿后下载产物（run 的 Artifacts `firmware-stock`；dispatch 才会有 pre-release `ci-<run_number>`），刷入设备做**毕业批次的 default 档实机回归**（ci-74 只验证了 experimental 档）。后续历史流程（7.1–7.6）保留作记录。

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
- **新增（合并后）**：run #83（stock@`3a7257c`）绿后刷机，复核毕业批次在 default 档的实机表现（bridge/nft L2 offload E1–E3、EHT320 9990/9991/9993、TXFREE 0005、HW_RRO 07、稳定性 09/17/18、fw4 flow_offload uci-defaults 生效、`compat_version 2.0`）——ci-74 结论只覆盖 experimental 档，default/stock 放行需本轮复核。
- 继续跟踪 mt76/mac80211 上游联动 bump；合入后删 `9028`/`9994`，再验（08-30 复核：mt76 master 仍 `c5a3bd91`、main 仍 pin `59676919`，暂无动作）。
- 跟进 F77（fanboy `vendor/18` 83 行版吸收）与 F78（naoki66 LAN2 SDS-mode 评估，与 `9029` 对照）。
- 跑 `docs/ACCEPTANCE.md` 全项（含 D3 72h 长稳、C2/C3/B2 物理对端项），冻结 known-good tag。

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
