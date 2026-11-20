# WAN Wi-Fi 转发路径（mt7996 → GDM2）

**状态**：路径文档（doc-only，对应 #86）。每条结论带证据等级：

- **实测** — 2026-11-20 04:38–04:42 UTC（12:38–12:42 CST）在本机
  `ssh root@192.168.1.1`（`Linux OpenWrt 7.3 #0 SMP PREEMPT Fri Nov 20 04:04:01 2026 aarch64`，
  `r38047-a86ce12e27`）上直接读到的输出，命令随文给出。设备是共享机，别的 agent 同时在
  跑 `wifi reload`，**vif 集合与 flowtable 内容会随重载变化**，所以每条实测都带时刻；
  同一命令重复跑可能得到不同结果，不算矛盾。
- **代码** — 只能指到本树里的文件与行；不等于运行时真的这样走。
- **推断** — 没有运行态证据的推理，写清缺哪一步才能变成实测。

关联：#86、#51、#70、#90、#102。

## 1. 路径总图

```
Wi-Fi client
   │ 802.11 (2.4/5/6 GHz)
   ▼
mt7996 MAC/PHY  ── PCIe0 ──►  AN7581          dts:221 &pcie0, :247 mt7996@0,0
   │                           │              :253 airoha,npu=<&npu>, :254 airoha,eth=<&eth>
   │                     ┌─────┴─────┐
   │                     │ NPU (RV32)│  ← 固件 TLB7.7.0.0_v08，运行时 status=active
   │                     └─────┬─────┘
   │                           │ NPU RX ring / RRO（host DMA，不是 PSE/FE 端口）
   ▼                           ▼
mac80211 / mt76 RX  ◄──── host DMA
   │
   ▼
br-lan (bridge)  ── nf_call_iptables=1 ──►  netfilter NF_INET_FORWARD
   │
   ▼
inet fw4 flowtable "ft"（devices 由 fw4 reload 重建）
   │
   ▼
PPE (airoha_ppe)  ── 5-tuple IPV4_HNAPT / IPV6_ROUTE ──►  GDM2 (wan)
   │
   ▼
RTL8261BE PHY / USXGMII ──► WAN 口
```

## 2. 逐段证据

| # | 段 | 驱动/文件 | 证据（file:line） | 运行时状态（2026-11-20） |
|---|---|---|---|---|
| 1 | 射频 ↔ mt7996 MAC | mt7996 固件 + mt76 驱动 | `package/kernel/mt76/Makefile:709-720` 安装 `mt7996_dsp.bin`/`rom_patch`/`wa`/`wm` 到 `/lib/firmware/mediatek/mt7996/`；`an7581-xr1710g-ubi.dts:247` `mt7996@0,0` | **实测**：`apk list -I` 装的是 `kmod-mt7996e-7.3.2026.10.08~639e1287-r2`；`iw dev` 显示 `phy0.0-ap0` 2.4 GHz ch6 20 MHz、`phy0.1-ap0` 5 GHz ch149 80 MHz |
| 2 | mt7996 ↔ SoC | PCIe0，2 lanes | `an7581-xr1710g-ubi.dts:221` `&pcie0`、`:247` `mt7996@0,0`、`:253-254` phandle | 未采 `lspci -vv`；链路训练速率未验证 |
| 3 | mt7996 ↔ NPU | NPU 固件与 mailbox | `target/linux/airoha/patches-7.3/993-*`：`npu/support_map`（28 B）、`npu/counters`（584 B）只读 GET | **实测**：`/sys/kernel/debug/npu/support_map` 首行 `support_map: 28 bytes (224 bits)`；`npu/counters` 首行 `counters: 584 bytes, 112 slots`；设备固件 `strings` 为 `TLB7.7.0.0_v08` |
| 4 | NPU → host RX | mt76 NPU RX ring / RRO | `package/kernel/mt76/patches/0012-...npu-stop-never-advancing-the-RX-ring.patch`；`0016-...-npu-rro-debugfs.patch` | **实测**：`/sys/kernel/debug/ieee80211/phy0/mt76/npu_rro` → `status: npu=active hwrro=v3 hw_init=done`；`npu0` 队列 `rx_packets=54326 rx_bytes=3244804`，`npu1` 队列 `rx_packets=120442 rx_bytes=29972160`（该时刻确实有无线帧经 NPU RRO 进主机） |
| 5 | host RX → mac80211 | mt76 `mt76_rx()` → `ieee80211_rx()` | 不在本树（mt76 为 package 源码），补丁只改 debugfs/队列 | 无本树 file:line，标“上游驱动” |
| 6 | mac80211 → bridge | `br-lan`，成员含 wlan vif | `etc/hotplug.d/net/50-nf-bridge-call:21-29`：br-lan 上 `nf_call_iptables=1`、`nf_call_ip6tables=1` | **实测**：`/sys/class/net/br-lan/bridge/nf_call_iptables=1`、`nf_call_ip6tables=1`、`nf_call_arptables=0`；而全局 `/proc/sys/net/bridge/bridge-nf-call-{ip,ip6}tables` 都是 `0` —— 起作用的是 **per-bridge 属性**，不是全局 sysctl |
| 7 | bridge → netfilter forward | 桥接 IP 流量进 `NF_INET_FORWARD` | `target/linux/airoha/an7581/target.mk:31-36`（bridged traffic 经 br_netfilter 进 inet fw4 flowtable，编码成 5-tuple）；`51-bridge-hw-offload:23-27`（没有 bridge-family flowtable 的路线） | 见 §3：flowtable 成员集合**没有** wlan vif |
| 8 | netfilter → PPE | `airoha_ppe` 绑定 FOE 条目 | `patches-7.3/205-...patch:30,79,90` 建 `ppe/bind`、`ppe/usage`（含 `l2b_bound`）；`target.mk:43-52` 解释 `l2b_bound` 结构性为 0 | **实测**：`cat /sys/kernel/debug/ppe/usage` → `entries 32768`、`bound 0`、`unbound 0`、`l2b_bound 0`；`ppe/bind` 为空。该时刻无转发流量（`wan` NO-CARRIER），所以“0 绑定”只证明空闲，不证明不能绑 |
| 9 | PPE → GDM2 | `gdm2` 以太网控制器 | `an7581-xr1710g-ubi.dts:322` `&gdm2`、`:327` `phy-mode = "usxgmii"`、`:331` `openwrt,netdev-name = "wan"`；`&gdm1` `:310-315` 是 `cpu`，`&gdm4` `:338-347` 是 `lan2` | **实测**：`ip link` 里 `wan: <NO-CARRIER,...,state DOWN>`；`lan4` UP、`lan3` LOWERLAYERDOWN。WAN 口当前无链路，端到端打流的前置条件不成立 |
| 10 | GDM2 → WAN 口 | RTL8261BE / USXGMII | RTL8261BE 的 datasheet 仍未公开（`docs/wan-materials.md`） | 未采 `ethtool wan`（无载波，读数无意义） |

## 3. 真正的缺口：flowtable 的成员集合是**重载时的快照**，且当前是旧的

这一节是本文最重要的实测结论。#86 要求“标出哪些计数器已经存在”，但比计数器更早的
事实是：**AP 流量在当前这套运行时配置下根本进不了 inet flowtable 的设备集合**。

**实测**（2026-11-20 04:38:22 UTC，一条 SSH 会话内顺序执行）：

```
$ ssh root@192.168.1.1 'nft list flowtables; ls /sys/class/net/br-lan/brif/; fw4 print | sed -n "/flowtable ft {/,/}/p"'
```

1. 已加载的 flowtable：

   ```
   table inet fw4 { flowtable ft { hook ingress priority filter
       devices = { "lan2", "lan3", "lan4", "wan" } flags offload counter } }
   table bridge fw4 { flowtable fb { hook ingress priority filter
       devices = { "lan2", "lan3", "lan4" } flags offload counter } }
   ```

2. `br-lan` 的成员：`lan2`、`lan3`、`lan4`、`phy0.0-ap0`、`phy0.1-ap0`。

3. `fw4 print`（按**当前**状态重新生成、尚未加载的规则集）：

   ```
   flowtable ft { hook ingress priority 0;
       devices = { "lan2", "lan3", "lan4", "phy0.0-ap0", "phy0.1-ap0", "wan" }; }
   ```

所以缺口不是“fw4 把 wlan vif 过滤掉了”——fw4 现在就会把它们写进去；缺口是
**已加载的 ft 比当前成员集旧**：它的设备列表停在 wlan vif 加入 br-lan 之前。

**机制（代码）**：

- fw4 在 **reload 时**才从 netifd 状态重建设备列表：`51-bridge-hw-offload:16-22`
  （“fw4 builds the inet flowtable's device list at reload time … a reload that happens
  before wlan joins the bridge builds a flowtable without the wlan devices”）；设备来源是
  `zone.related_physdevs`（`54-pppoe-flowtable:5-11`；设备上的
  `/usr/share/ucode/fw4.uc:555-573` `resolve_offload_devices()`）。
- 成员变化时负责补一次 reload 的是 `etc/hotplug.d/net/50-bridge-hw-offload`：它 `flock -w 10`
  拿锁，拿不到就 `logger … "reload already in progress, giving up"` 然后退出（`:35-48`）。
- 而 `etc/hotplug.d/iface/51-bridge-hw-offload` 在**同一把锁**下跑完整个 settle 循环
  （最多 120 s，`:69-81`）、reload 一次（`:86`），再 `sleep 40` 复查成员是否变化（`:88-97`）。
  也就是说锁每次可能被持有约 15–175 s；这个窗口内到达的 vif `add` 事件全部**排队 10 s 后放弃**。
- 这不是理论：**实测** `logread | grep bridge-hw-offload` 在 04:20–04:38 之间输出了十几条
  `reload already in progress, giving up`（04:36:33×2、04:36:34、04:36:35、04:36:45、
  04:36:53、04:38:39、04:38:42 …）。`/var/lock/bridge-hw-offload.lock` 时间戳 04:38。
  04:39:11 复查：锁无人持有，但 ft 仍是旧集合 —— 放弃掉的那几次没有被补回来。

wlan vif 的个数是浮动的：本次会话里 `brif` 一度列出 `phy0.2-ap0`，几十秒后
`iw dev` 只剩 `phy0.0-ap0`/`phy0.1-ap0`（`/sys/kernel/debug/ieee80211/phy0/netdev:phy0.2-ap0`
目录时间戳 04:38）。**推断**：别的 agent 正在 `wifi reload`，phy0.2 的 vif 建了又拆；
固件里 `Radios:` 字段报 2/1，不构成三频在线证据。所以“三个 vif 都不在 ft 里”这个说法
只在“当时有三个 vif”的时刻成立；能复现的稳定结论是：**在 ft 里的 wlan vif 数量为 0，而
br-lan 实际含 1–3 个**。

**为什么即使加进去也未必有 BIND（机制，逐条标级）**：

1. fw4 只给 tcp/udp 做 offload：设备上 `/usr/share/firewall4/templates/ruleset.uc:137-138`
   `meta l4proto { tcp, udp } flow offload @ft;`（bridge 表同款在 `:507`，本树补丁
   `package/network/config/firewall4/patches/001-add-bridge-flowtable-support.patch:59`）。
   → ICMP/UDP 之外的协议、以及所有非 tcp/udp 流量都不进 flowtable 快路径。**代码**
2. 无线入向没有 PSE/FE 端口号：PPE 的端口身份来自 GDM 设备
   （`patches-7.3/920-15-...airoha_get_fe_port.patch:22-37`，入参是
   `struct airoha_gdm_dev *`，返回 `FE_PSE_PORT_GDM*`）；本板 GDM 只有 `cpu`/`wan`/`lan2`
   （dts `:310-315`、`:322-331`、`:338-347`），mt7996 在 PCIe 上，RX 走 NPU RRO 的 host DMA
   （§2 第 4 行实测）。→ 无线入向的 flow tuple 里没有对应的 FE 端口。**代码 + 推断**：
   驱动对“ingress 不是 GDM netdev”的 tuple 是拒绝还是按端口 0 编码，**未验证**；要读 7.3
   base 的 `airoha_ppe.c` 全文或做一次绑定实验才能定性。
3. 反向（有线 → 无线）**曾经**被 PPE 接管：`patches-7.3/963-...patch:15-21` 记录
   “Measured on a Gemtek XR1710G: a frame entering lan2 with TTL 5 left phy0.0-ap0 with TTL 4”
   —— 说明 PPE 能处理“FE 端口 ↔ wlan vif”的桥接流，至少出向侧可以。**代码（作者实测）**
   这条把问题收窄成：缺的是**入向**无线 → WAN 方向的证据，不是“PPE 不认识无线”。

## 4. 现有钩子清单（谁在哪一步插手）

| 钩子 | 位置 | 作用 | 现状 |
|---|---|---|---|
| `nf_call_iptables`/`nf_call_ip6tables` | `etc/hotplug.d/net/50-nf-bridge-call:21-29` | br-lan `add` 时置 1，让桥接 IP 流量进 netfilter forward | 生效（§2 第 6 行实测） |
| fw4 inet flowtable | 设备 `/usr/share/firewall4/templates/ruleset.uc:2,10-23,137-138`；本树只提供 bridge 表补丁 | 生成 `table inet fw4 ft` 与 `flow offload @ft` 规则 | 生效，但设备列表旧（§3） |
| fw4 bridge flowtable `fb` | `firewall4/patches/001-add-bridge-flowtable-support.patch:7-25,36-61` | 额外造一张 bridge-family flowtable，设备集用 `resolve_bridge_devices()` 过滤成“有 `brport` 或 `bridge` 目录的设备” | 存在（实测 `fb` = {lan2,lan3,lan4}）；板级注释 `51-bridge-hw-offload:23-27` 说它“对 PPE 绑定没有贡献、已测过” |
| 成员变化补 reload | `etc/hotplug.d/net/50-bridge-hw-offload:35-48` | vif 加入后 reload 一次 | **经常抢先放弃**（§3 实测日志） |
| 启动期 settle+reload | `etc/hotplug.d/iface/51-bridge-hw-offload:60-98` | 等成员稳定、reload、+40 s 复查 | 持有同一把锁，正是上面放弃的原因 |
| PPPoE 设备补进 ft | `etc/hotplug.d/iface/54-pppoe-flowtable` | 把 `ppp*` 加进已建好的 ft（`nft add` 走 `nft_flowtable_update()` 分支） | 未测试（本机无 PPPoE） |
| 绑定阈值 | `target.mk:59-70`；`/sys/kernel/debug/ppe/bind_rate` | 持续速率过 30 才 BIND，约 1.1–1.8 s | 实测 `bind_rate` 存在；未改值 |

## 5. 现有可观测点（实测路径）

**路径与旧文档不同**：mt76 的两个 debugfs 文件挂在 **per-phy 目录**下，不在
`/sys/kernel/debug/` 根：

```
/sys/kernel/debug/ieee80211/phy0/mt76/token_info     ← 实测存在（04:42）
/sys/kernel/debug/ieee80211/phy0/mt76/npu_rro        ← 实测存在
/sys/kernel/debug/npu/support_map                    ← 实测存在
/sys/kernel/debug/npu/counters                       ← 实测存在
/sys/kernel/debug/ppe/{bind,usage,entries,bind_rate} ← 实测存在
```

`ls /sys/kernel/debug | grep token` 为空、`test -e /sys/kernel/debug/token_info` 为假 ——
按根路径去读会得出“没编译进去”的错误结论（模块里其实有该字符串）。这是本文对 #86
原文 `token_info` 路径的一处更正。

| 可观测点 | 能看到（实测字段） | 看不到 |
|---|---|---|
| `token_info` | `status: active`；`hw_token_range 0-8191`（NPU 固件）/`sw_token_range 8192-24575`（host 驱动）；`wed_token_count: 0`；`rx_token_size: 32768`；`npu_rx0/npu_rx1` 的 `ndesc/queued/head/tail`；每 band TX 队列 `type=npu` | 每队列收包**计数**（计数在 `npu_rro` 里）、CPU 周期、PPE 是否绑定 |
| `npu_rro` | `status: npu=active hwrro=v3 hw_init=done`；RRO 锚点寄存器值；`npu0/npu1` 的 `rx_packets/rx_bytes`；`cpu_idx/dma_idx` | 端到端包数、PPE 绑定结果 |
| `npu/support_map` | 28 B 原始 hex + 位图（`raw:` 行 + 每字节 bit） | 位含义（固件 v08 无名表，全是 `?`） |
| `npu/counters` | `counters: 584 bytes, 112 slots` + 每槽 idx/value | 槽语义 |
| `ppe/bind`、`ppe/usage`、`ppe/entries` | 绑定条目；`entries 32768 (sram 16384, dram 16384)`、`bound`、`unbound`、`l2b_bound`、`ipv4_bound` | 无线侧队列深度、CPU 成本 |
| `nft list flowtables` | inet `ft` 与 bridge `fb` 的**已加载**设备集合 | PPE 是否命中（要配 `ppe/entries` 的 BND 行） |
| `fw4 print` | **按当前状态重算**的设备集合 | 未加载，只是“下次 reload 会长成什么样” |
| `logread -t bridge-hw-offload` | 每次 reload 是被执行还是被 `giving up` 放弃 | 放弃后有没有后续补跑 |

判读注意（**实测**）：`NPU Queues` 里 `queued ≈ ndesc-1`（本次 511/512）是**预填的空
buffer**，不是积压；`npu_rro` 的 `queued=1023/1536` 同理。把 `queued 贴满` 当成拥塞是
误读，旧版本判断标准已按此更正。

## 6. 明确未定项

1. **入向（Wi-Fi→WAN）PPE 是否真的接管**：当前 ft 不含 wlan vif（§3 实测），
   `ppe/usage` 全 0 且 `wan` 无载波，因此既没有正证据也没有反证据。
   要变成实测需要：(a) 一次成功的 `fw4 reload` 让 ft 含 vif；(b) WAN 载波；
   (c) 一条持续 tcp 流；(d) `ppe/entries` 的 BND 行与计数增长。
2. **WED 是否参与**：设备树无 WED 节点（`grep -i wed an7581-xr1710g-ubi.dts an7581.dtsi` 为空），
   `wed_token_count: 0` 只是线索；不能据此写“不走 WED”。
3. **NPU → bridge 的具体通道**：`npu_rro` 的 `rx_packets` 增长证明帧进了主机，
   但帧从 RRO 队列交给 mac80211 还是直接进 bridge，本树无证据。
4. **非 tcp/udp 的 AP 流量**：`ruleset.uc:138` 只挂 tcp/udp，ICMP 等不进快路径（代码），
   本机未验证其实际表现。

## 7. 最小实验（5GHz → WAN）

前置：WAN 载波 up（`ip link` 里 `wan` 不能是 NO-CARRIER），且 ft 里含至少一个 wlan vif。

```sh
# 0) 先确认前置条件（只读）
nft list flowtables | grep -A3 'flowtable ft'
fw4 print | sed -n '/flowtable ft {/,/}/p'       # 期望与上一行一致；不一致说明还没 reload
ip link show wan | head -1
ls /sys/class/net/br-lan/brif/

# 1) 采样（只读）
D=/sys/kernel/debug/ieee80211/phy0/mt76
cat $D/token_info > /tmp/tok.before
cat $D/npu_rro    > /tmp/rro.before
cat /sys/kernel/debug/npu/counters > /tmp/npu.before
nft list flowtables > /tmp/ft.before
grep ' BND ' /sys/kernel/debug/ppe/entries > /tmp/ppe.before
grep -E 'qdma|eth|mt7996' /proc/interrupts > /tmp/irq.before

# 2) 客户端：5GHz 关联，向 WAN 侧 iperf3 server 打一条**持续**流（不是短请求）
iperf3 -c <WAN_PEER> -p 5201 -t 60 -P 4

# 3) 再采一次（同上，改成 .after）
```

判定（按 `target.mk:59-70`，绑定看**速率持续**，不看包数）：

- **PPE 接管**：`ppe/entries` 出现该 5-tuple 的 `BND` 行，且 `ppe/usage` 的 `bound` 从 0 变正。
- 只出现 `UNB` 不增长 → 未绑定（低速率或 `bind_rate` 未过）。
- ft 里没有 wlan vif → 先解决 §3 的 reload 竞争，再谈绑定。
- **CPU 成本**：`mpstat -P ALL 1` 的 `%sys+%soft` 增量对应 < 0.5 核（60 s 平均）。
- **NPU 线索**：`npu_rro` 的 `rx_packets` 增量与客户端发出包数同量级；
  `token_info` 的 `wed_token_count` 只记录、不结论。

## 8. 不应写的结论

- 不写“NPU 一定不参与”：`mt7996@0,0` 有 `airoha,npu` phandle，且实测 `status: active`。
- 不写“WED 已启用/未启用”：设备树无 WED 节点，运行态未验证。
- 不写“PPE 已卸载 Wi-Fi 流”或“PPE 不处理 Wi-Fi 流”：入向未测；出向侧有 963 的作者实测记录。
- 不写“CPU 占用 0”：只能写实测 `%sys`/`%soft`。
- 不把 `l2b_bound 0` 读成“桥接没卸载”（`target.mk:45-52`：结构不可达，桥接流计入 `bound`）。

## 9. 如何验证本文

```sh
grep -n 'bridged traffic is fed through NF_INET_FORWARD\|l2b_bound 0' target/linux/airoha/an7581/target.mk
grep -n 'builds the inet flowtable' target/linux/airoha/an7581/base-files/etc/hotplug.d/iface/51-bridge-hw-offload
grep -n 'flock -w 10\|giving up' target/linux/airoha/an7581/base-files/etc/hotplug.d/net/50-bridge-hw-offload
grep -n 'meta l4proto { tcp, udp } flow offload @fb' package/network/config/firewall4/patches/001-add-bridge-flowtable-support.patch
grep -n 'airoha_get_fe_port' target/linux/airoha/patches-7.3/920-15-*.patch
ssh root@192.168.1.1 'nft list flowtables; ls /sys/class/net/br-lan/brif/; logread | grep bridge-hw-offload | tail -5'
```

预期：前五条命中真实行；设备侧能看到 ft 的 wlan vif 缺口与 `giving up` 日志；
两者不一致（ft 缺、`fw4 print` 有）就是 §3 的结论本身。
