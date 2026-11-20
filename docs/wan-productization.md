# WAN 产品化默认值与回滚矩阵（G7）

**状态**：文档 + 待验收矩阵。本文**不改代码、不改默认配置**；所有“当前值”都能指到文件，
所有“实测值”都来自仓库已有证据。没有实测的格子写 `未过` 或 `UNVERIFIED`，不写“支持”。

**关联**：#90（本文）、#30、#85、#86、#88、#81、#12。

## 1. 当前 WAN 映射

`target/linux/airoha/an7581/base-files/etc/board.d/02_network:20-21`：

```
gemtek,xr1710g-ubi)
	ucidef_set_interfaces_lan_wan "lan2 lan3 lan4" "wan"
```

设备树 `target/linux/airoha/dts/an7581-xr1710g-ubi.dts`：

| 逻辑口 | 控制器 | 设备树节点 | phy-mode | PHY | 证据 | 速率结论 |
|---|---|---|---|---|---|---|
| `wan` | GDM2 | `:322` `&gdm2` | `usxgmii` (`:327`) | `phy8` (`:326`) | `:331` `openwrt,netdev-name = "wan"` | 端口标称 10G；**链路速率未实测**，写 `UNVERIFIED` |
| `lan2` | GDM4 | `:338` `&gdm4` | `usxgmii` (`:343`) | `phy5` (`:342`) | `:347` `openwrt,netdev-name = "lan2"` | **与“10G”不一致**：`phy5` 注释明确写 “The 2.5G USXGMII link to the AN7581 PCS”（`:370-373`），LED 也是 LAN2（`:381-394`） |
| `lan3` | GSW port1 | `:438` `&gsw_port1` | 内部 GbE switch | `gsw_phy1` | `:440` `label = "lan3"` | 1G switch 口（`gsw_port1`/`gsw_phy1`），实测未做 |
| `lan4` | GSW port2 | `:468` `&gsw_port2` | 内部 GbE switch | `gsw_phy2` | `:470` `label = "lan4"` | 1G switch 口（`gsw_port2`/`gsw_phy2`），实测未做 |

**差异记录（不改代码）**：

- 验收假设 `lan2 = GDM4/10G`；设备树把 `lan2` 挂在 GDM4/USXGMII，但 `phy5` 注释把它描述为
  **2.5G** USXGMII 链路。因此“lan2 是 10G”目前**没有代码/实测支持**，只能写“GDM4，PHY 侧
  注释为 2.5G，实际协商速率待测”。产品文案不应把 lan2 写成 10G，直到 `ethtool lan2` 读到
  10000 且对端也为 10G。
- `wan` 是 GDM2/USXGMII，这是确定的；`10G` 是端口标称，不是已复现实测。
- `lan3`/`lan4` 是 GSW 1G 口；没有 `gdm` 节点，也没有 2.5G/10G 证据。
- 仓库内另一份调研 `docs/garbage-router-market-2026-11.md:113` 写 “2×10GbE RJ45（WAN + lan2）”，
  与 `phy5` 注释的 “2.5G USXGMII” 冲突；两处都不是实测。以 `ethtool lan2` 的 `Speed` 为准，
  在读到 10000 之前不要对外写 lan2=10G。

## 2. 默认项

“当前值”来自代码；“是否已改”指本次文档是否改动默认配置——**全部为“否”**。

| 项 | 当前值 | 证据 | 建议值 | 是否已改 |
|---|---|---|---|---|
| WAN 设备 | `wan` | `02_network:21`；dts `:331` | 保持 `wan` | 否 |
| `ft devices` 是否含 `ppp0` | **UNVERIFIED** | fw4 在 reload 时按 zone/device 解析 flowtable devices（`51-bridge-hw-offload:17-19`）；ppp0 在 PPPoE 起来后才出现，是否被重新解析未实测 | PPPoE 拨号完成后 `nft list flowtables` 应含 `ppp0`（或至少 `wan` 的物理设备）；不含则 `fw4 reload` 后再看 | 否 |
| `pppoe_decap` 值 | **无运行时开关**：#81 要求的 `9904-...-decap-with-psn.patch` 不在树里（`ls target/linux/airoha/patches-7.3/9904*` 为空）；`scripts/pppoe-decap-hw-bench.sh` 引用的 `/sys/kernel/debug/ppe/pppoe_decap` 没有对应创建代码 → 运行态 `UNVERIFIED` | `target/linux/airoha/patches-7.3/`；#81 | 先实现 #81 的 decap=3，再谈默认；默认保持厂商语义（decap 0/1/2 不变） | 否 |
| LRO 策略 | WAN 物理设备 ifup 时 `rx-lro on`，ifdown 时 `off`；不默认改 `netdev->features` | `target/linux/airoha/an7581/base-files/etc/hotplug.d/iface/52-wan-lro` | 保持 WAN-only；LAN 不开（br-lan 没有 `NETIF_F_LRO`，且 `NETIF_F_UPPER_DISABLES`） | 否 |
| masq 策略 | 默认 `masq=1`（fw4 zone 默认），另加 `fullcone=1`、`fullcone6=0` | `target/linux/airoha/an7581/base-files/etc/uci-defaults/50_firewall-offload:24-27`；masq 本身未在该脚本中改写 | 保持 `masq=1`、`fullcone=1`、`fullcone6=0`；不要用 fullcone6 冒充 IPv6 能力 | 否 |
| 硬件 offload | `flow_offloading=1`、`flow_offloading_hw=1` | 同上 `:24-25` | 保持；若 G2/G4 未过，先查 flowtable 是否真的包含 WAN 设备 | 否 |

注意：`package/network/config/firewall4/patches/001-add-bridge-flowtable-support.patch` 会生成
`table bridge fw4` 的 `fb` flowtable，但板级 hotplug 明确说明桥接流量走 inet flowtable 的
5-tuple HNAPT，单独的 bridge flowtable 已被测过“对 PPE 绑定没有贡献”并移除
（`51-bridge-hw-offload:23-27`）。因此判断 offload 是否生效，看
`nft list flowtables` 的 **inet** 表与 `ppe/entries` 的 `BND` 行，不要只看 bridge 表。

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
ip -br link         > "$BK/ip-link.txt"
sha256sum "$BK"/*   > "$BK/SHA256SUMS"
```

备份放设备外（scp 到采集主机），并在文件名/目录名带时间；只留在 `/root` 不算备份。

### 3.2 恢复

```sh
BK=/root/wan-backup-YYYYmmdd-HHMMSS
cp "$BK/network"  /etc/config/network
cp "$BK/firewall" /etc/config/firewall
fw4 reload
/etc/init.d/network reload
```

`network reload` 不够时再 `restart`；恢复后核对 `ip -br link`、`uci show network`、
`nft list flowtables` 与备份时一致。

### 3.3 清 flowtable / 重启网络的最小步骤

```sh
nft list flowtables                 # 先看表名与设备，别凭记忆写
nft flush flowtable inet fw4 ft     # 只清条目，不删表；表名以实际输出为准
fw4 reload                          # 重新生成规则与 flowtable
/etc/init.d/network reload          # 比重启整机轻；接口重建后再看一次
```

如果 `nft list flowtables` 里没有 `inet fw4 ft`，说明表名/族不同，按实际输出改命令；
不要照抄一个不存在的表名。清表会掉现有流，生产环境要避开业务高峰。

## 4. 验收矩阵

门限来自 #90；`未过` 表示本仓库没有该项的实测证据，**不是**“不支持”的同义词，也**不是**
“已支持”。

| # | 项 | 门限 | 当前结论 | 证据/缺口 |
|---|---|---|---|---|
| G1 | 1G WAN 转发 | 941 Mbit/s（issue 给定参考） | **未过 / UNVERIFIED** | 仓库没有 1G WAN 的 iperf3 原始结果；`docs/wan-measurement-protocol.md` 只定义方法。941 是 #90 的验收参考，不是本仓库复现值 |
| G2 | PPPoE 入向 | receiver ≥ 800 Mbit/s，retransmits < 10 | **未过 / UNVERIFIED** | 需要 `docs/wan-measurement-protocol.md` 的四臂实测；`scripts/pppoe-4path.sh` 已就绪但未在硬件上跑 |
| G3 | 2.5G 单向 | ≥ 2.2 Gbit/s | **未过 / UNVERIFIED** | 无 2.5G USB NIC；`tools/wan-bench/2.5g.sh` + `docs/wan-2.5g-gate.md` 只到 dry-run |
| G4 | 10G 单向 | ≥ 6 Gbit/s | **未过 / UNVERIFIED** | 仓库没有 10G WAN 实测；5.77 Gbit/s 是 10G loopback，不是 WAN 基线 |
| G5 | 桥/Wi-Fi 转发 | 不丢包、可复现吞吐 | **未过 / UNVERIFIED** | `docs/wan-wifi-path.md` 只给路径与观测点；PPE 是否绑定 Wi-Fi→WAN 流未测 |

规则：

- 只有“原始日志 + 命令 + 配置”齐全的格子才能从 `未过` 改为 `PASS`；引用别人的数字不算。
- 2340 / 550 / 5.77 这些数字不作为已复现基线出现在本文或对外材料里。
- G3/G4 未过时，产品页不应写“支持 2.5G/10G WAN 转发”，只能写“硬件具备 2.5G/10G 端口”。

## 5. D7：不做 lan3→wan10g 迁移

本分支 WAN 已经是 `wan`（GDM2/USXGMII，`02_network:21`、dts `:322-331`），不存在把
`lan3` 改成 `wan10g` 的迁移任务。D7 只保留验证项：

1. `ip -br link` 中 `wan` 存在且 up；
2. `ethtool wan` 的 `Speed` 与对端一致（10G 标称需实测确认）；
3. `nft list flowtables` 含 WAN 侧设备；
4. G1–G5 按第 4 节逐项验收。

不新增 `wan10g` 设备名，不改 `02_network` 的 lan/wan 分配——那会改变所有已有设备的
默认行为，且与 D7 的“已经是 wan”结论冲突。

## 6. 如何验证本文

```sh
grep -n 'ucidef_set_interfaces_lan_wan' \
  target/linux/airoha/an7581/base-files/etc/board.d/02_network
grep -n '&gdm2\|&gdm4\|netdev-name = "wan"\|netdev-name = "lan2"' \
  target/linux/airoha/dts/an7581-xr1710g-ubi.dts
grep -n '2.5G USXGMII link' target/linux/airoha/dts/an7581-xr1710g-ubi.dts
grep -n 'flow_offloading\|fullcone' \
  target/linux/airoha/an7581/base-files/etc/uci-defaults/50_firewall-offload
grep -n 'rx-lro\|NETIF_F_LRO' \
  target/linux/airoha/an7581/base-files/etc/hotplug.d/iface/52-wan-lro
grep -n '未过\|UNVERIFIED' docs/wan-productization.md
```

预期：前五条命中真实行；最后一条证明未实测项没有被写成“支持”。
