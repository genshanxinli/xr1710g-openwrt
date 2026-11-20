# WAN Wi-Fi 转发路径（mt7996 → GDM2）

**状态**：路径文档（doc-only）。下面的“已确认”只指**代码/设备树里能指到文件与行**；
没有一次实机抓包，因此所有“运行时是否真的这样走”的判断都标为 **未定/需实验**。
**关联**：#86、#51、#70、#90、#102。

## 1. 路径总图

```
Wi-Fi client
   │ 802.11 (2.4/5/6 GHz)
   ▼
mt7996 MAC/PHY  ── PCIe0 ──►  AN7581
   │                           │
   │                     ┌─────┴─────┐
   │                     │ NPU (RV32)│  ← airoha,npu phandle
   │                     └─────┬─────┘
   │                           │ NPU RX ring / RRO
   ▼                           ▼
mac80211 / mt76 RX  ◄──── host DMA 或 NPU 直投
   │
   ▼
br-lan (bridge)  ── nf_call_iptables=1 ──►  netfilter forward
   │
   ▼
PPE (airoha_ppe)  ── 5-tuple HNAPT / flowtable ──►  GDM2 (wan)
   │
   ▼
RTL8261BE PHY / USXGMII ──► WAN 口
```

## 2. 逐段证据

| # | 段 | 驱动/文件 | 证据（file:line） | 运行时状态 |
|---|---|---|---|---|
| 1 | 射频 ↔ mt7996 MAC | mt7996 固件 + mt76 驱动 | `package/kernel/mt76/Makefile:709-720` 安装 `mt7996_dsp.bin`/`rom_patch`/`wa`/`wm` 到 `/lib/firmware/mediatek/mt7996/`；设备树 `target/linux/airoha/dts/an7581-xr1710g-ubi.dts:247` `mt7996@0,0` | 固件加载成功与否看 `dmesg`；本仓库无本次启动日志 |
| 2 | mt7996 ↔ SoC | PCIe0，2 lanes | `an7581-xr1710g-ubi.dts:221` `&pcie0`，`:247` `mt7996@0,0`，`:253` `airoha,npu = <&npu>`，`:254` `airoha,eth = <&eth>` | 链路训练/枚举需 `lspci -vv`；未采集 |
| 3 | mt7996 ↔ NPU | NPU 固件与 mailbox | `target/linux/airoha/patches-7.3/993-...patch`：`npu/support_map`（28 B）与 `npu/counters`（584 B），只读 GET；`AIROHA_NPU_MBOX_SIZE=4416` | 读 debugfs 才能确认固件应答；未采集 |
| 4 | NPU → host RX | mt76 NPU RX ring / RRO | `package/kernel/mt76/patches/0012-wifi-mt76-npu-stop-never-advancing-the-RX-ring.patch`（`mt76_npu_dequeue()`，`NPU_RX_DMA_DESC_DONE`）；`0016-...npu-rro-debugfs.patch` 暴露 `npu_rro` 与每队列 `rx_packets/rx_bytes` | `token_info` 的 `NPU Queues` 表可看 `ndesc/queued/head/tail`；未采集 |
| 5 | host RX → mac80211 | mt76 `mt76_rx()` → `ieee80211_rx()` | 不在本树（mt76 为 package 源码）；补丁只改 debugfs/队列，不改 mac80211 入口 | 无本树 file:line，标“上游驱动” |
| 6 | mac80211 → bridge | `br-lan`，成员含 wlan vif | `target/linux/airoha/an7581/base-files/etc/hotplug.d/net/50-nf-bridge-call`：br-lan 上 `nf_call_iptables=1`、`nf_call_ip6tables=1`；`51-bridge-hw-offload` 在成员稳定后 reload fw4 | 需 `bridge link`、`ls /sys/class/net/br-lan/brif`；未采集 |
| 7 | bridge → netfilter forward | `nf_call_iptables=1` 把桥接 IP 流量送进 `NF_INET_FORWARD` | `51-bridge-hw-offload` 注释：没有 bridge-family flowtable；inet flowtable 以 5-tuple HNAPT 编码 | `nft list flowtables` 看设备集合；未采集 |
| 8 | netfilter → PPE | `airoha_ppe` 绑定 FOE 条目 | `target/linux/airoha/patches-7.3/205-...patch:102` 创建 `ppe/bind`（0444）；`:105` `ppe/usage`；`213-...patch:179` 创建 `ppe` 目录；`964` 增加 `ppe/bind_rate` | `grep ' BND ' /sys/kernel/debug/ppe/entries`、`cat ppe/bind`；未采集 |
| 9 | PPE → GDM2 | `gdm2` 以太网控制器 | `an7581-xr1710g-ubi.dts:322` `&gdm2`，`:327` `phy-mode = "usxgmii"`，`:331` `openwrt,netdev-name = "wan"`；PHY `phy8`（`:322` 的 phy-handle） | `ethtool wan`、`cat /sys/class/net/wan/speed`；未采集 |
| 10 | GDM2 → WAN 口 | RTL8261BE / USXGMII | 设备树 `phy8` 节点（`an7581-xr1710g-ubi.dts` 内 `ethernet-phy@8`，`realtek,patch-rtk-serdes`） | 链路速率/SerDes 状态需 `ethtool`；未采集 |

## 3. 现有可观测点

所有 debugfs 均只在**已启动的设备**上存在；仓库里只证明“代码会创建它”，不证明当前设备已挂载。

| 可观测点 | 能看到 | 看不到 |
|---|---|---|
| `/sys/kernel/debug/token_info`（mt76 `0001` 补丁） | SW token 使用量/池大小、`token_start`、`wed_token_count`、`rx_token_size`；NPU active 时 HW/SW token 区间；`MT_RXQ_NPU0..1` 的 `ndesc/queued/head/tail`；每 band TX 队列类型 `npu`/`dma` | 每队列收包**计数**、CPU 周期成本、WED 是否参与、PPE 是否绑定 |
| `/sys/kernel/debug/npu_rro`（mt76 `0016` 补丁） | RRO 顶层寄存器（BA bitmap/address-element/session/indirect-command/MSDU page）地址值；host DMA 与 HW/NPU 的 `cpu_idx/dma_idx`；address-element 匹配检查；NPU RX/RRO 数据队列的 `rx_packets/rx_bytes` + jiffies | 端到端包数、PPE 绑定结果、CPU 成本 |
| `/sys/kernel/debug/npu/support_map`（airoha `993`） | 28 字节 GET_WAIT_NPU_SUPPORT_MAP 原始 hex + 每字节 8 个 bit；固件 v08 没有 bit 名表，名字全是 `?` | 位含义（需另行解码） |
| `/sys/kernel/debug/npu/counters`（airoha `993`） | 584 字节 GET_WAIT_COUNTER；112 个 idx/value 槽（payload offset 8）+ 128 字节 raw tail | 每个槽的语义（固件未公开） |
| `/sys/kernel/debug/ppe/bind`、`ppe/usage`、`ppe/entries` | PPE 绑定条目、表占用、FOE 条目（state/ib1 等） | Wi-Fi 侧队列深度、CPU 成本 |
| `nft list flowtables` | inet flowtable 的设备集合与 hook | PPE 是否真的命中（要配合 `ppe/entries` 的 BND 行） |
| `ethtool -S wan` / `/proc/interrupts` | GDM/QDMA 计数与 IRQ 分布 | 单个 Wi-Fi 队列的贡献 |

## 4. 明确未定项

以下三项**不应**从现有代码推出结论，必须做实验：

1. **PPE 是否真的处理 Wi-Fi→WAN 流**：`nft list flowtables` 里能看到 `br-lan`/`wan`，不等于
   PPE 已绑定。判定要看 `ppe/entries` 是否出现对应 5-tuple 的 `BND` 行，以及该行计数器是否增长。
2. **WED 是否参与**：本板设备树没有 WED 节点（`grep -i wed an7581-xr1710g-ubi.dts an7581.dtsi`
   为空），`mt7996@0,0` 只挂了 `airoha,npu` 与 `airoha,eth`。因此“走 WED”目前是**未定**，
   不应写“一定不走 WED”，也不应写“WED 已启用”。`token_info` 的 `wed_token_count` 只能作为
   线索，不是证明。
3. **NPU → bridge 的具体通道**：NPU RX 队列把帧交给 host 后，进入 mac80211 还是直接进 bridge，
   本树没有运行态证据；只能通过 `npu_rro` 的队列计数与 `br-lan`/PPE 计数联立判断。

## 5. 最小实验（5GHz → WAN）

目的：用一次单向 TCP 流，回答“Wi-Fi 入向到 WAN 出向是否被 PPE 接管，CPU 成本多少”。

```sh
# 设备侧（串口/SSH 均可；只读采样）
cat /sys/kernel/debug/token_info            > /tmp/tok.before
cat /sys/kernel/debug/npu_rro               > /tmp/rro.before
cat /sys/kernel/debug/npu/counters          > /tmp/npu.before
nft list flowtables                         > /tmp/ft.before
grep ' BND ' /sys/kernel/debug/ppe/entries  > /tmp/ppe.before
mpstat -P ALL 1 1                           > /tmp/cpu.before
grep -E 'qdma|eth|mt7996' /proc/interrupts  > /tmp/irq.before

# 客户端：5GHz 关联，向 WAN 侧 iperf3 server 打流
iperf3 -c <WAN_PEER> -p 5201 -t 60 -P 4 -J > /tmp/wifi-wan.json

# 设备侧再采一次
cat /sys/kernel/debug/token_info            > /tmp/tok.after
cat /sys/kernel/debug/npu_rro               > /tmp/rro.after
cat /sys/kernel/debug/npu/counters          > /tmp/npu.after
nft list flowtables                         > /tmp/ft.after
grep ' BND ' /sys/kernel/debug/ppe/entries  > /tmp/ppe.after
mpstat -P ALL 1 1                           > /tmp/cpu.after
grep -E 'qdma|eth|mt7996' /proc/interrupts  > /tmp/irq.after
```

判定：

- **PPE 接管**：`ppe/entries` 前后都有同一 5-tuple 的 `BND` 行，且该行计数增长；
  `nft list flowtables` 的 devices 含 `br-lan` 与 `wan`。
- **CPU 成本**：`mpstat` 的 `%sys`/`%soft` 增量对应的核心数 < 0.5 core（60 s 平均），
  且 `token_info` 的 `NPU Queues.queued` 不持续贴满、`npu_rro` 的 `rx_packets` 增长与
  iperf3 receiver 包数量级一致。
- **WED 线索**：记录 `token_info` 的 `wed_token_count` 前后值；只作线索，不作结论。
- **失败判据**：有吞吐但 `ppe/entries` 无 `BND` 行 → 判定为“软件转发，PPE 未接管”；
  `npu` 计数器不增长 → 判定为“未走 NPU 路径”。

原始文件放 `research/lead/triage/offline/wan-raw/wifi-path/`，报告引用文件名与字段。

## 6. 不应写的结论

- 不写“NPU 一定不参与”：`mt7996@0,0` 明确有 `airoha,npu` phandle，NPU 路径存在。
- 不写“WED 已启用”：设备树没有 WED 节点，运行态未验证。
- 不写“PPE 已卸载 Wi-Fi 流”：没有 `ppe/entries` 的 BND 行与计数器增长证据。
- 不写“CPU 占用 0”：只能写实测的 `%sys`/`%soft` 与核心数。

## 7. 如何验证本文

```sh
grep -n 'mt7996@0,0\|airoha,npu\|airoha,eth' target/linux/airoha/dts/an7581-xr1710g-ubi.dts
grep -n '&gdm2\|netdev-name = "wan"' target/linux/airoha/dts/an7581-xr1710g-ubi.dts
grep -n 'debugfs_create_file("bind"' target/linux/airoha/patches-7.3/205-*.patch
grep -n 'token_info\|npu_rro\|support_map\|counters' docs/wan-wifi-path.md
grep -n '未定\|UNVERIFIED\|需实验' docs/wan-wifi-path.md
```

预期：前三条命中设备树/补丁中的真实行；文档内同时出现“未定/需实验”，没有把推断写成实测。
