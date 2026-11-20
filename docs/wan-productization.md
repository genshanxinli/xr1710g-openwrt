# WAN 产品化默认值与回滚矩阵（G7）

**状态**：文档 + 验收矩阵 + 2026-11-20 设备快照。本文**不改代码、不改默认配置**；
每个“当前值”都能指到一处**实测输出**或一处**代码行**，未实测的格子写 `未过` / `UNVERIFIED`。

证据图例：**实测** = 本轮在设备（`r38047-a86ce12e27`，`ssh root@192.168.1.1`）上直接读到的输出；
**代码** = 从树里的文件读出、未上机；**推断** = 由代码或物理常识推出、无输出支撑；**未验证** = 没做。

**关联**：#90（本文）、#30、#85、#86、#88、#81、#12、#28。

## 0. 本轮新增的结论（先行）

1. **WAN 口能力是 10G，但协商速率本轮测不到**（机箱上没有接 WAN 对端）：`ethtool wan`
   **实测**把 `10000baseT/Full` 列进 Supported/Advertised，`Speed: Unknown`。
   旧文“lan2 只能写 2.5G，读到 10000 之前不要对外写 10G”一句是**读错注释**：
   `dts:370-374` 的 “The 2.5G USXGMII link to the AN7581 PCS” 描述的是 **PCS/SerDes 的
   USXGMII 2.5G 模式与重调要求**，不是铜线速率；板上 `lan2` 的 PHY 同样自报 10G（§1）。
   该结论已**取代**（superseded）旧文的推断。
2. **`ppp0` 这一行从“未实现”变成“代码已就位、运行未验证”**：树里已有
   `target/linux/airoha/an7581/base-files/etc/hotplug.d/iface/54-pppoe-flowtable`
   （为 #28 加的），它把 PPPoE 的 `l3_device` 追加进 fw4 的 `inet fw4 ft`；镜像里也已安装。
   本板没有 PPPoE 对端，所以只到**代码**层。
3. **LRO 的“当前值”与旧文不符**：脚本 `52-wan-lro` 在树里、也在镜像里，但**实测**
   `ethtool -k wan` 是 `large-receive-offload: off`，`logread` 里**没有** `wan-lro` 的任何记录。
   旧文写“WAN ifup 时 `rx-lro on`”，这一条已**取代**（superseded）为“机制存在、运行态未生效，
   原因未定位”（见 §2）。
4. **bridge flowtable 并没有被移除**：**实测** `nft list flowtables` 同时有
   `table inet fw4 → flowtable ft` 与 `table bridge fw4 → flowtable fb`；
   `fb` 来自 `package/network/config/firewall4/patches/001-add-bridge-flowtable-support.patch:36-58`，
   `51-bridge-hw-offload:23-27` 只是说明**板级 hotplug 不再自己建**它。旧文“已被测过并移除”
   已**取代**（superseded）。
5. **备份不能靠 `scp`**：**实测** 设备有 `/usr/bin/scp`，但缺 `/usr/libexec/sftp-server`，
   拉文件报 `Connection closed`；取回只能用 `ssh 'cat file' > file`。

## 1. 当前 WAN 映射

`target/linux/airoha/an7581/base-files/etc/board.d/02_network:20-21`（**代码**）：

```
gemtek,xr1710g-ubi)
	ucidef_set_interfaces_lan_wan "lan2 lan3 lan4" "wan"
```

**实测**（`uci show network`，本机 `r38047-a86ce12e27`）：

```
network.@device[0].name='br-lan'   type='bridge'   ports='lan2' 'lan3' 'lan4'
network.lan.device='br-lan'  proto='static'  ipaddr='192.168.1.1/24'
network.wan.device='wan'     proto='dhcp'
network.wan6.device='wan'    proto='dhcpv6'
```

设备树（**代码**，行号已核）：`target/linux/airoha/dts/an7581-xr1710g-ubi.dts`

| 逻辑口 | 控制器 | 节点 | phy-mode | PHY | netdev-name | 本轮实测能力 | 协商速率 |
|---|---|---|---|---|---|---|---|
| `wan` | GDM2 | `:322` `&gdm2` | `usxgmii` (`:327`) | `phy8` (`:326`) | `:331` | `ethtool wan`：`PHYAD 8`，external，Supported/Advertised 含 `10000baseT/Full`、`2500/5000`、`100/1000` | `Speed: Unknown!`，`carrier 0` → **未测** |
| `lan2` | GDM4 | `:338` `&gdm4` | `usxgmii` (`:343`) | `phy5` (`:342`) | `:347` | `ethtool lan2`：`PHYAD 5`，同样含 `10000baseT/Full` | `Speed: Unknown!` → **未测** |
| `lan3` | GSW port1 | `:438` `&gsw_port1` | 内部 GbE switch（推断 PHY `gsw_phy1`：`:438-441` 只设 `status`/`label`） | —（无 phy-handle） | `:440` `label = "lan3"` | `ethtool lan3`：最高 `1000baseT/Full` | `-1`（LOWERLAYERDOWN） |
| `lan4` | GSW port2 | `:468` `&gsw_port2` | 内部 GbE switch（推断 PHY `gsw_phy2`：`:468-471` 同上） | —（无 phy-handle） | `:470` `label = "lan4"` | `ethtool lan4`：最高 `1000baseT/Full` | **1000 Mb/s**（唯一 up 的以太口） |

`ip link`（**实测**）：`wan`、`lan2` 都是 `NO-CARRIER … state DOWN`；`lan3` 是
`LOWERLAYERDOWN`；`lan4` 是 `state UP`。`ubus call network.interface.wan status` 回
`"up": false, "proto": "dhcp", "device": "wan"`。

**差异记录（不改代码）**：

- 验收原文写“`wan` 是 GDM2/10G、`lan2` 是 GDM4/10G”。前一半**代码+实测**都成立
  （GDM2/USXGMII，PHY 自报 10G）；后一半在**代码**上成立（GDM4/USXGMII，PHY 自报 10G），
  但 `phy5` 的注释（`:370-374`）说的是 **PCS 侧 USXGMII 2.5G 模式**，两者不是一个量。
  **本轮实测只到“PHY 支持 10G”，没到“10G 链路协商成功”**：没有对端，`Speed` 是 `Unknown`。
  对外文案可以写“端口具备 10G 能力”，不能写“10G 转发已验收”（那要看 §4 的 G4）。
- `lan3`/`lan4` 是 GSW 内部 1G 口，**实测** `ethtool` 只支持到 `1000baseT/Full`，无 `gdm` 节点。
- 旧文引用的 `docs/garbage-router-market-2026-11.md:113`（“2×10GbE RJ45”）**不在本树里**
  （`ls docs` 无此文件），该引用已废弃（superseded）；能力判断改用上面的 `ethtool` 实测。

## 2. 默认项

“当前值”一栏：**实测** 指设备上的输出；**代码** 指文件行。本节不改任何默认值。

| 项 | 当前值（实测/代码） | 本轮状态 | 建议值 | 是否已改 |
|---|---|---|---|---|
| WAN 设备 | `wan`，`proto=dhcp`（`uci show network`，**实测**）；devicetree `:331`（代码） | 实测 | 保持 `wan` / DHCP | 否 |
| DEFAULT_PACKAGES | `uboot-envtools kmod-nft-bridge kmod-sched-act-police`（`target/linux/airoha/an7581/target.mk:9-10`，代码）；设备 `apk list -I` 三个包均已装（**实测**），另有 `ethtool-full-7.1-r1`。板级 `DEVICE_PACKAGES` 还带 `rtl826x-firmware`/`rtl8261c-firmware`（2.5G/10G PHY 固件）、`fitblk`、`dumpimage`（`an7581.mk:103-105`，代码）——**实测** `dumpimage` 在设备上存在，`airoha-en7581-npu-firmware`（MT7992 blob）**不是**默认（`target.mk:12-18` 的注释说明理由） | 实测 | 保持 | 否 |
| `ft devices` 是否含 `ppp0` | **当前无 PPP netdev**（**实测**：`ls /sys/class/net` 无 `ppp*`；`proto=dhcp`）。`nft list flowtables` 的 inet ft = `{ "lan2", "lan3", "lan4", "wan" }`（**实测**） | 实测（当前形态） | PPPoE 起链后应含 `pppoe-wan`：树里已加 `54-pppoe-flowtable`（**代码**，`proto=pppoe` 才动作，`nft add flowtable … devices={"$DEV"}`），镜像里已安装（**实测** `/etc/hotplug.d/iface/54-pppoe-flowtable` 存在）。**运行未验证**：无 PPPoE 对端 | 否（代码已在 HEAD） |
| `pppoe_decap` 值 | **没有运行时开关**：**实测** `/sys/kernel/debug/ppe/` 下只有 `6rd bind bind_rate dslite entries entry_alias flush mcast meter ppe1_regs tb_regs tpid unbind_age usage`，**没有 `pppoe_decap`**；**代码** `target/linux/airoha/patches-7.3/` 下无 `9904*decap*` 补丁 | 实测 + 代码 | 先实现 #81 的 decap=3 再谈默认；默认保持厂商语义（decap 0/1/2 不变） | 否 |
| LRO 策略 | 脚本 `52-wan-lro` 只碰 WAN（`hotplug.d/iface/52-wan-lro`，代码：`[ "$INTERFACE" = wan ] || exit 0`，物理设备 + 三层设备兜底 + `ethtool -K … rx-lro on/off`）。**实测运行态**：`ethtool -k wan` → `large-receive-offload: off`（无 `[fixed]`），`logread` 无 `wan-lro` 记录 | **实测≠旧文**：旧文说“ifup 时 on”，实测是 off；没定位是 hotplug 没触发还是 `-K` 在无载波时静默失败（脚本把 `-K` 的 stderr 丢了） | 保持 WAN-only；LAN 不开（`NETIF_F_UPPER_DISABLES` 与 br-lan 的 feature 集决定了桥成员不能带 LRO） | 否 |
| masq 策略 | `firewall.@zone[1].masq='1'`、`@defaults[0].fullcone='1'`、`fullcone6='0'`、`flow_offloading='1'`、`flow_offloading_hw='1'`（**实测** `uci show firewall`）；`uci-defaults/50_firewall-offload:19-27` 只写后四项，masq 是 fw4 zone 默认（代码） | 实测 | 保持 `masq=1`、`fullcone=1`、`fullcone6=0`；不要用 fullcone6 冒充 IPv6 能力 | 否 |
| 硬件 offload | `flow_offloading_hw=1`（实测）；`nft list flowtables` 两张表都存在（实测，见下）；`/sys/kernel/debug/ppe/usage` 打印 `entries 32768 (sram 16384, dram 16384)`、`bound 0 unbound 0`（当前无 WAN 流量，所以是 0） | 实测（配置）/ 未测（WAN 路径绑定） | 保持；判断是否生效看 `ppe/entries` 与 `usage` 的 `BND`，不要只看 bridge 表 | 否 |

**关于两张 flowtable（更正旧文）**：

| 表 | 设备（**实测**） | 来源 | 作用 |
|---|---|---|---|
| `table inet fw4 → flowtable ft` | `{ "lan2", "lan3", "lan4", "wan" }`，`flags offload`，`counter` | 上游 fw4 `templates/ruleset.uc` 的 `flowtable_devices`（同一变量也喂给补丁 001 的 `resolve_bridge_devices`） | WAN 路由/桥接转发的 5-tuple HNAPT 都走它（板级 `51-bridge-hw-offload` 开头 20 行解释了 br_netfilter → NF_INET_FORWARD 的路径） |
| `table bridge fw4 → flowtable fb` | `{ "lan2", "lan3", "lan4" }`，`flags offload`，`counter` | `firewall4/patches/001-add-bridge-flowtable-support.patch:36-58`（`check_bridge_flowtable`/`resolve_bridge_devices` + 模板） | 存在但**不是** PPE 绑定的判据；`51-bridge-hw-offload:23-27` 只说明板级 hotplug 不再自建 |

旧文“单独的 bridge flowtable 已被测过并移除”是**错的**（实测它就在），已标 superseded。
判定 offload 生效的方法不变：看 `inet fw4 ft` + `/sys/kernel/debug/ppe/entries` 的 `BND` 行。

`target.mk:32-40` 的注释把这条路径写清楚了（**代码**，注释里带一条历史实测）：
bridged 流量经 br_netfilter 的 `nf_call_iptables` 走 `NF_INET_FORWARD`，进普通
`table inet fw4` flowtable，由 PPE 编码成 5-tuple `IPV4_HNAPT`；注释记录“它确实 bind，
3.5M 包的跑测 0.46 CPU-秒 vs 未绑定 34.3”。这条**本轮没有复跑**，所以矩阵里仍算
`代码（历史实测记录）`，不算本轮的 `PASS` 证据。同一段还说明 bridge-family 所需的
`generic/pending-7.3/675-01..675-05` 现在**保留但不用**（fw4 没有 `flow_offloading_bridge` 开关）。

## 3. 回滚

### 3.1 备份

```sh
BK=/root/wan-backup-$(date +%Y%m%d-%H%M%S)
mkdir -p "$BK"
cp /etc/config/network  "$BK/network"
cp /etc/config/firewall "$BK/firewall"
uci export network  > "$BK/network.uci"
uci export firewall > "$BK/firewall.uci"
nft list ruleset    > "$BK/nft.ruleset"
nft list flowtables > "$BK/nft.flowtables"
ip -br link          > "$BK/ip-link.txt"     # 本镜像实测支持 -br
sha256sum "$BK"/*   > "$BK/SHA256SUMS"
```

取回（**实测**：设备上的 `scp` 缺 `sftp-server`，拉文件直接 `Connection closed`）：

```sh
for f in network firewall network.uci firewall.uci nft.ruleset nft.flowtables ip-link.txt SHA256SUMS; do
  ssh root@192.168.1.1 "cat $BK/$f" > "./wan-backup/$f"
done
```

- 备份放设备外，文件名/目录名带时间；只留在 `/root` 不算备份。
- `wan-backup-*` 与 §2 的默认值无关，改默认值之前先备份。

### 3.2 恢复

```sh
BK=/root/wan-backup-YYYYmmdd-HHMMSS
cp "$BK/network"  /etc/config/network
cp "$BK/firewall" /etc/config/firewall
fw4 reload
/etc/init.d/network reload
```

`network reload` 不够时再 `restart`；恢复后核对 `ip link`、`uci show network`、
`nft list flowtables` 与备份时一致。

### 3.3 清 flowtable / 重启网络的最小步骤

```sh
nft list flowtables                 # 先看表名与设备，别凭记忆写
nft flush flowtable inet fw4 ft     # 只清条目，不删表
fw4 reload                          # 重新生成规则与 flowtable
/etc/init.d/network reload          # 比重启整机轻；接口重建后再看一次
```

表名以实际输出为准（本机是 `inet fw4 ft` 与 `bridge fw4 fb` 两张）；
清表会掉现有流，生产环境避开业务高峰。

## 4. 验收矩阵

门限来自 #90。`未过` = 本仓库没有该项的实测证据，**不是**“不支持”，也**不是**“已支持”。
`实测` 一栏写的是本轮真跑出来的东西；其余按证据图例标注。

| # | 项 | 门限 | 当前结论 | 本轮证据 / 缺口 |
|---|---|---|---|---|
| G1 | 1G WAN 转发 | 941 Mbit/s（issue 给定参考） | **未过** | **实测**（`docs/perf/ppe-wired-baseline.md`）：`lan4` 1G 全双工、主机↔设备**本地终结**：`tx` 834.9–888.6 Mbit/s，`rx` 926.4–942.5 Mbit/s。但那是本机协议栈终结，**没有 `FORWARD` 跳**，30 个窗口 `ppe/entries` 全空、`bound` 全 0 → 不能当 WAN 转发。WAN 侧 `carrier 0` → **本板无法组 G1** |
| G2 | PPPoE 入向 | receiver ≥ 800 Mbit/s，retransmits < 10 | **未过** | **代码**：`scripts/pppoe-4path.sh`、`docs/wan-measurement-protocol.md` 的四臂就绪；`54-pppoe-flowtable` 就绪。**缺口**：无 PPPoE 对端（`wan` 无载波），四臂一次没跑 |
| G3 | 2.5G 单向 | ≥ 2.2 Gbit/s | **未过** | **代码**：`tools/wan-bench/2.5g.sh`；`docs/wan-2.5g-gate.md` 自述“没有 2.5G USB NIC，没有实测数字”。**实测** 只到“`ethtool wan` 支持 `2500baseT/Full`”，这是能力不是吞吐 |
| G4 | 10G 单向 | ≥ 6 Gbit/s | **未过** | **实测** 只到“`ethtool wan`/`lan2` 支持 `10000baseT/Full`、`Speed: Unknown`”。5.77 Gbit/s 是 10G **环回/本机路径**数字（`docs/wan-measurement-protocol.md:143`），不是 WAN 基线 |
| G5 | 桥/Wi-Fi 转发 | 不丢包、可复现吞吐 | **未过** | **代码**：`docs/wan-wifi-path.md` 给路径与观测点。**实测只到 flowtable 设备集**：`inet fw4 ft` 是 `{lan2,lan3,lan4,wan}`（物理成员），**不是** `docs/wan-wifi-path.md:104` 期望的 `br-lan`+`wan`。桥/Wi-Fi 吞吐本轮**一次没跑**（未采集 `iw`、`bridge link`、`/sys/class/net/br-lan/brif`）→ 纸面 |

规则：

- 只有“原始日志 + 命令 + 配置”齐全的格子才能从 `未过` 改为 `PASS`；引用别人的数字不算。
- 2340 / 550 / 5.77 不作为已复现基线出现在本文或对外材料里（它们的出处是
  `docs/wan-measurement-protocol.md:7,143,146` 与 `docs/MTU-POLICY.md:75`）。
- G3/G4 未过时，产品页只写“硬件具备 2.5G/10G 端口”，不写“支持 2.5G/10G WAN 转发”。

### 4.1 本板纸面行（不能在本机演示的部分，如实说明）

| 行 | 为什么是纸面 | 本机能做到的最好证据 |
|---|---|---|
| G1 | `wan` 无载波（`carrier 0`、`speed -1`），没有第二个 1G 对端可挂 WAN 侧 | `lan4` 本地终结 1G：834.9–888.6 / 926.4–942.5 Mbit/s（非转发） |
| G2 | 无 PPPoE 服务器/对端，`/sys/class/net` 无 `ppp*` | `54-pppoe-flowtable` 代码 + 设备上已安装的脚本 |
| G3 | 无 2.5G NIC | `ethtool` 的 `2500baseT/Full` 能力位 |
| G4 | 无 10G 对端 | `ethtool` 的 `10000baseT/Full` 能力位 + 5.77 环回（`docs/wan-measurement-protocol.md:143`，不作基线） |
| G5 | 无 Wi-Fi STA、无第二台主机做桥转发；本轮连 `iw`/`bridge link` 都没采集 | 只有 `nft list flowtables`（`ft`=lan2/lan3/lan4/wan，`fb`=lan2/lan3/lan4） |

也就是说：**矩阵 5 行全部是纸面/未过**，本板唯一真跑过的是 1G 本地终结与 PPE 空表。

## 5. D7：不做 lan3→wan10g 迁移

本分支 WAN 已经是 `wan`（GDM2/USXGMII，`02_network:21`、`dts:322-331`，代码），
不存在把 `lan3` 改成 `wan10g` 的迁移任务。D7 只保留验证项：

1. `ip link` 中 `wan` 存在且管理态 UP（**实测**：UP，但 `NO-CARRIER`）；
2. `ethtool wan` 的 `Speed` 与对端一致——**实测 `Speed: Unknown`**，所以这一项**未验证**；
   能确认的只有能力位含 `10000baseT/Full`；
3. `nft list flowtables` 的 `inet fw4 ft` 含 WAN 侧设备（**实测**：含 `wan`）；
4. G1–G5 按第 4 节逐项验收（全部未过）。

不新增 `wan10g` 设备名，不改 `02_network` 的 lan/wan 分配——那会改变所有已有设备的
默认行为，且与 D7 的“已经是 wan”结论冲突。

## 6. 如何验证本文

```sh
# 代码侧
grep -n 'ucidef_set_interfaces_lan_wan' \
  target/linux/airoha/an7581/base-files/etc/board.d/02_network
grep -n 'DEFAULT_PACKAGES' -A1 target/linux/airoha/an7581/target.mk
grep -n '&gdm2\|&gdm4\|netdev-name = "wan"\|netdev-name = "lan2"\|2.5G USXGMII' \
  target/linux/airoha/dts/an7581-xr1710g-ubi.dts
grep -n 'flow_offloading\|fullcone' \
  target/linux/airoha/an7581/base-files/etc/uci-defaults/50_firewall-offload
grep -n 'INTERFACE' target/linux/airoha/an7581/base-files/etc/hotplug.d/iface/52-wan-lro
grep -n 'proto\] = pppoe\|nft add flowtable' \
  target/linux/airoha/an7581/base-files/etc/hotplug.d/iface/54-pppoe-flowtable
grep -n 'table bridge fw4\|flowtable fb' \
  package/network/config/firewall4/patches/001-add-bridge-flowtable-support.patch

# 设备侧（只读）
ssh root@192.168.1.1 'uci show network; ip link; ubus call network.interface.wan status'
ssh root@192.168.1.1 'ethtool wan | head -12; ethtool lan2 | head -12; ethtool lan3 | head -8'
ssh root@192.168.1.1 'nft list flowtables; uci show firewall | grep -E "offload|masq|fullcone"'
ssh root@192.168.1.1 'ls /sys/kernel/debug/ppe/; head -5 /sys/kernel/debug/ppe/usage'
ssh root@192.168.1.1 'ethtool -k wan | grep large-receive; logread | grep -i wan-lro'

# 本文保留未过/未验证标记
grep -n '未过\|UNVERIFIED\|superseded' docs/wan-productization.md
```
