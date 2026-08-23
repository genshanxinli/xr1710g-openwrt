# HANDOFF — 交接文档（2026-08-23 会话收口）

> 接任维护者请先读：`README.md`、`CONTEXT.md`、`docs/FIXES.md`（F01–F75）、`docs/adr/0001`、`docs/adr/0002`、`docs/ROADMAP.md`。

## 0. 工作区与远程

- 本地仓库：`/root/workspace/xr1710g-openwrt`
- 当前分支：`feat/antenna-eeprom-power-unlock`
- 当前 commit：`2780c8a`（已推送；CI 构建 commit 为 `46600b2`，本 commit 仅更新 HANDOFF）
- 远程：`https://github.com/genshanxinli/xr1710g-openwrt`（默认分支 `main`）
- 推送到当前分支：
  ```bash
  export GH_TOKEN=$(cat .gh-token)
  git push "https://x-access-token:${GH_TOKEN}@github.com/genshanxinli/xr1710g-openwrt.git" feat/antenna-eeprom-power-unlock
  ```
  > 本宿主 `git push origin` 常无输出/超时，直接用 token URL 最稳；`gh api`/`curl` 偶发 EOF/429，重试 1–2 次即可。

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
   - A12/F75：`scripts/device-hw-probe.sh` 新增 B2.1 10G PHY VEND1 `0x103/0x104`（phytool）+ B7 EFR32 去除断言。
2. **本地验证全绿**：
   - `scripts/audit-patches.sh` ✅（default 35 / experimental 52）
   - `scripts/apply-patches.sh tmp/openwrt-src --dry-run` ✅：regdb 4、mt76 7、uboot 41 真实应用通过
   - `scripts/apply-patches.sh tmp/openwrt-src --dry-run --experimental` ✅：regdb 4、mt76 13、uboot 41 真实应用通过
3. **推送并 dispatch 新 CI**（commit `46600b2`）：
   - all = `32621215717`（stock/oc-1.3/oc-1.4）
   - experimental = `32621217391`
   - 旧的 e0e84e0 构建 `32619703715` / `32619704962` 已取消。

## 3. 构建与验证状态（2026-08-23）

- `46600b2` 的 CI 已绿：all = `32621215717`（success）、experimental = `32621217391`（success）。
- `sync-upstream`（push 触发）对 `46600b2` 已绿：run `32621204454`。
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

## 5. 当前 patch 层速览（默认档 ROOT）

`9000/9001/9002` 板级（66MiB reserved_bmt + rdinit） → `vendor/03` cpufreq → `vendor/10` pstore → `9017` apps-pack（fancontrol 去 init.d） → `9030` FlowSense 1.1.8-r5 → `9018` VLAN/PPPoE → `9019` CLIENTS 计数 → `9020` memory_regions DT → `9021` sysfs stats → `9022` IPv6/UDP 判读 → `9023` 优雅降级 → `9025` no-carrier rx stats → `9010` txpower ucode → `vendor/11` LRO → `9011–9016` 08 切片 → `9027` ledtrig-netdev link mode → `9031` LED interval skip → `9028` mt76 bump。
实验档另有：`vendor/02/04/05/06/07/09/17/18`、`9024`、`9026`、`9029`、`mt76-0005/0010/9990/9991/9993`、`mac80211-411`。
mt76 包补丁默认档：`mt76-0001/0003/0006/0007/0008/0009/9994`。

## 6. 上游状态快照（2026-08-23 会话未重新查询，沿用 08-22 快照）

- `openwrt/openwrt` master：`3d1645ee`（08-21）。本地 dry-run 绿。
- `OpenWRT-fanboy/OpenW1700k` `ubi2-oc`：`ba58ba46`（08-21）；06=`c0ed8295`、07=`5b917d4b`、mt76-0005=`e7a8143`。
- `YYH2913/openwrt` `xr1710g-6.18-integration`：`e88fbe28`（08-19）；mt76 0006/0007/9990/9991/9993、mac80211-411、regdb 510/520/530 已核对。
- `openwrt/mt76` master：`c5a3bd91`（08-22）。本仓库已自 bump（`9028`）+ `9994` 兼容层。
- 跟踪 PR：仍 open #22397、#22029、#22473、#22532、#22533、#24034、#24619、#23990；已 merged #21777/#23078/#23383/#21978/#22391/#24593/#22289/#23427。

## 7. 下一步（重点）：新 CI 固件刷入设备后的测试

> 等 `46600b2` 的 CI all + experimental 绿并下载产物后执行。产物在对应 run 的 Artifacts（`firmware-<profile>`）或 workflow_dispatch 成功后的 pre-release `ci-<run_number>`（`firmware-<profile>.tar.gz`）。

### 7.1 先刷 stock（all run 的 stock 产物）

**重要**：A1 已改布局，当前设备还是旧 2MiB 布局。**禁止在旧布局设备上 sysupgrade**（compat 2.0 会拒；不得 -F 强刷）。必须走 HTTP U-Boot 恢复页：
1. PC 接 10GbE 口，DHCP；开机按 reset 进 `http://192.168.255.1`；
2. 布局选择器选 **UBI 2.0**（与 `9001/9002` 新布局匹配）；
3. 上传 `*-sysupgrade.itb` 刷入 stock。

刷入后按序验证（判据见 FIXES F64–F75 / ACCEPTANCE）：
- [ ] 冷启动无 `rdinit=/init failed`（F66）
- [ ] `/proc/mtd` 或 `cat /proc/partitions`：`ubi` size=`0x1b700000`、`reserved_bmt` size=`0x04200000`（F64）
- [ ] `ubinfo -a` 无坏块；多轮重启不新增坏块（F64）
- [ ] `/etc/init.d/fan start` 后 `pwm1` 仅一个写入者；风扇曲线随温度切换；fancontrol 页面可读可设（F67/A4）
- [ ] `led start` 退出码 0；hw-offloaded PHY LED 无 EINVAL（#14/9031）
- [ ] `getStatus` RPC 返回 5 个 NPU memory regions（#22/F63，`ubus` 侧复测）
- [ ] 有损链路 `iw dev wlanX station dump`：`tx_retries>0` 时 `tx_failed≈0`（F68/A5）
- [ ] 三频 AP 正常；6GHz C2 双侧国家码判据（AP US + 客户端 US 可见可连；非 US 不可见属预期）（F72/A9）
- [ ] C3 无线速率用外部对端 iperf3（禁止本机 iperf3 当吞吐判据）（F74/A11）
- [ ] 管理面改址回连 B6（F74/A11）
- [ ] `DEVICE_HOST=root@192.168.123.1 ./scripts/device-hw-probe.sh` 全绿（F75/A12）

### 7.2 再刷 experimental（experimental run 产物）

stock 基本项通过后，同法刷 experimental（或同布局 sysupgrade），重点验证实验档新增：
- [ ] A6/F69 mt76-0010 NPU RX skb->dev：桥接 6G 客户端 `conntrack -F` 后新建流，br-lan 无丢包、CLIENTS 计数一致
- [ ] A7/F70 FlowSense 1.1.8-r5：`npu-monitor.settings.air_eff` 生效；B5/C4 下吞吐针非 0；9018-9023 功能不回归
- [ ] A8/F71 JCPLL TCLVAR recal：10G 对端直连 lan2，`ethtool` 10G link 且 rx/tx errors=0；毕业转 default
- [ ] 实验档既有项：EHT320/9990/9991/9993、TXFREE 0005、bridge-flow-offload 9024/9026（issue #1 E1/E2）
- [ ] `wifi down/up` 5 轮不复发（issue #10）

### 7.3 通过后收口

- 可毕业项转 default（尤其 F69/F71 视实机结果）；更新 FIXES/README/ROADMAP。
- 继续跟踪 mt76/mac80211 上游联动 bump；合入后删 `9028`/`9994`，再验。
- 跑 `docs/ACCEPTANCE.md` 全项，冻结 known-good tag。

## 8. 宿主环境备忘

- 容器缺 `make/gawk/mkhash` 等完整 OpenWrt 构建工具；本地只做 patch 生成、审计、ssh 实机验证。真正构建以 GitHub Actions 为准。
- `gh api`/`curl` 偶发 429/EOF；空输出先重试；`export GH_TOKEN=$(cat .gh-token)`。
- 推送优先用 token URL（见第 0 节）。
- 本地浅克隆 openwrt master：`/root/workspace/xr1710g-openwrt/tmp/openwrt-src`（partial clone）；源码缓存：`tmp/copy-patch-verify`。
- 社区源码临时仓库：`/tmp/orangeyoo-xr1710g`、`/tmp/gilly-w1700k`、`/tmp/naoki66-xr1710g`、`/tmp/lvcdy-xr1710g`。
- mt76 bump 调试树：`tmp/mt76-bump/`；fanboy/YYH 资产若已清理则按 `fetch-sources.sh` 重取。
