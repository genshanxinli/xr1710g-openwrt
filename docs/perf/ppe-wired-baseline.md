# PPE wired baseline — lan4 ↔ host, 2026-11-20

本文件是 **#13（perf baseline）** 与 **#30（measurement protocol）** 的实测底稿：一条纯有线、1 Gbit/s、
主机↔设备本地终结的 iperf3 基线，同时记录这条路径上 PPE 是否有参与。30 个 10 s 窗口，两个方向。

## 结论摘要

1. **实测**（本次）：`lan4` 1 Gbit/s 全双工。主机→设备（`tx`）接收端 834.9–888.6 Mbit/s，
   设备 4 核非 idle 时间 17.3–22.0 CPU-s / 10 s；设备→主机（`rx`，真 `-R`）接收端 926.4–942.5 Mbit/s，
   设备只花 4.95–8.64 CPU-s / 10 s。两个方向都接近线速，但**发方向便宜得多**是本次最清楚的定量结果。
2. **实测**（本次）：30 个窗口里 `/sys/kernel/debug/ppe/usage` 的 `bound` / `unbound` / `l2b_bound`
   **全部为 0**，`/sys/kernel/debug/ppe/entries` 始终 0 行。两臂（`bind_rate` `10 10` 默认 vs `0 0` 关闭）
   行为等价，原因是这条流量**从未被尝试绑定**（本地终结、无 `FORWARD` 跳），不是“绑定了但被拒”。
3. 所以本轮**不是**卸载 A/B，**不能**用于 `target/linux/airoha/an7581/target.mk:35-36` 那句
   “3.5M-packet run / 34.3 → 0.46 CPU-seconds”。该句在 `scripts/claims.yaml` 里没有条目、没有 `实测` 证据、
   没有原始数据落盘，因此**不得**作为基线被引用。
4. **方法学发现（本轮踩坑换来的）**：第一版驱动脚本把方向参数当成了轮次参数，`-R` 从未生效，
   18 个窗口其实全是 `tx`。只有去查 iperf3 客户端 JSON 的 `start.test_start.reverse` 才发现。
   修好后补跑 12 个真 `-R` 窗口。教训已写进协议：**方向必须由客户端 JSON 断言，不能信标签**。
5. **方法学发现（第二个）**：设备→主机方向 `ethtool -S lan4` 的 `tx_packets` **不是线上的帧数**——
   14.11 GB 只记了 367 458 帧（≈38.4 KB/计数帧），说明发送侧走了大段聚合（`tx-tcp-segmentation: on`、
   `scatter-gather: on`）。反方向主机→设备是帧准的（13 533 546 帧 / 20.49 GB = 1514 B/帧，与 MTU 1500 吻合）。
   因此“CPU-s 每百万包”这类指标**只在 `tx` 方向可用**，`rx` 方向必须按字节算。
6. 缺的东西（明确列出）：被转发路径（lan↔lan 或 lan↔wifi）、2.5G/10G 口（本机 `wan` 无 carrier、`lan4` 只有
   1000 Mb/s）、无线（主机无 WiFi 网卡、设备三个 VAP 无 STA）、stock 固件对照。

## 设备与环境

| 项 | 值 |
|---|---|
| 固件 | OpenWrt SNAPSHOT `r37994-44d4267ca7`（`DISTRIB_TARGET='airoha/an7581'`，`DISTRIB_TAINTS='no-all'`） |
| 内核 | `Linux 7.3 #0 SMP PREEMPT Fri Nov 20 00:50:00 2026 aarch64`，`aarch64-openwrt-linux-musl-gcc 14.4.0` |
| CPU | 4 × Cortex-A53（`CPU part 0xd03`），`scaling_governor=performance`，`scaling_cur_freq=1200000`（定频 1.2 GHz） |
| 计时 | `CONFIG_HZ=100`（实测校准：每核约 102 tick/s、聚合 ≈ 4 × elapsed；`config-7.3` 写的 250 与实际不符） |
| 温度 | `thermal_zone0=40200`（40.2 °C） |
| 交换机 | `mt7530-mmio 1fb58000.switch: Link is Up - 10Gbps/Full`；`lan4: Link is Up - 1Gbps/Full - flow control rx/tx` |
| lan4 | `Speed: 1000Mb/s`，`Duplex: Full`，MTU 1500 |
| 卸载特性 | `tx-checksumming: on`、`tcp-segmentation-offload: on`、`scatter-gather: on`、`generic-segmentation-offload: on`、`generic-receive-offload: on` |
| PPE | `usage` 打印 `entries 32768 (sram 16384, dram 16384)`；`bind_rate` 开机 `l3 10 l2b 10` |
| fw4 | `flow_offloading=1`、`flow_offloading_hw=1`；flowtable `ft`（lan2/lan3/lan4/wan）与 `fb`（lan2/lan3/lan4）均存在 |
| iperf3 | 设备侧侧载 3.22（`libatomic1` / `libiperf3` / `iperf3` APK，`apk add --allow-untrusted`）；主机 `/usr/bin/iperf3` 3.20 |

## 拓扑：为什么这条路径上 PPE 不参与

```
[iperf3 client] container 172.19.0.1/28
        |  NAT（docker host 192.168.1.212, b0:25:aa:67:99:61）
        v
   lan4 -- 1G -- mt7530 -- cpu(10G internal) -- airoha_eth -- br-lan -- 192.168.1.1（设备自己）
```

* `lan4` 是唯一 up 的以太口；`wan` `NO-CARRIER`，`lan2` down，`lan3` `LOWERLAYERDOWN`。
* 三个 VAP（ch6 / ch149 / ch37 EHT320）都 up，但没有 STA 关联（`iw dev … station dump` 为空）；
  `/proc/net/arp` 只有 NAT 主机一条。
* iperf3 的字节进 `lan4` 后直接投给本机协议栈：**没有 `FORWARD` 跳，nf_flow_table 没有可卸载的对象**。
  这不是推断——30 个窗口 `ppe/entries` 全空、`bound` 全 0。

## 方法（可直接照抄的协议）

每个测量窗口：

1. 设备侧先起 `iperf3 -s -p 5201 -1 -J --logfile /tmp/srv-<tag>.json`，**等到 `netstat -ltn | grep :5201`
   命中**才开始打流量；25 × 0.2 s 内没监听就作废该窗（本轮 30/30 通过）。
2. 紧接 `snap <tag>.before`：`/proc/uptime`、`/proc/stat`、`/sys/kernel/debug/ppe/usage`（+ `entries`）、
   `/proc/net/snmp`、`ethtool -S lan4`、`ppe/bind_rate`。
3. 主机侧 `iperf3 -c 192.168.1.1 -p 5201 -t 10 -P <1|4> [-R] -J`，原始 JSON 落盘。
4. 客户端退出后立刻 `snap <tag>.after`，同一组文件。
5. 两臂：`default` 写回 `10 10`，`unbind` 写 `0 0`；每臂 × 1 流 / 4 流 × tx / rx × 3 轮，臂间交替。
6. 结束后写回 `10 10` 并回读确认（`l3 10 l2b 10`，`bound 0 unbound 0`）。

**方向的判定**（踩坑换来的）：解析时读 iperf3 客户端 JSON 的 `start.test_start.reverse`，
并断言“标 `rx` 的窗口 `reverse=1`、标 `tx` 的 `reverse=0`”。标签、脚本参数、文件名都不可信。

**时间与包的来源**：`CPU-s` 来自 `/proc/stat` 的时间戳差分（`cpu` 聚合行），`HZ=100`，
`non-idle = 总 tick − idle − iowait`；`elapsed` 取设备自己的 `/proc/uptime`，因此 SSH 往返也在分母里；
包数取 `ethtool -S lan4` 的 `rx_packets` / `tx_packets` 差分（`rx` 方向的坑见摘要第 5 点）。

```sh
# 设备侧 snapshot
cat /proc/uptime; echo ---STAT; cat /proc/stat; \\
echo ---PPE; cat /sys/kernel/debug/ppe/usage; echo ---ENTRIES; cat /sys/kernel/debug/ppe/entries; \\
echo ---SNMP; cat /proc/net/snmp; echo ---ETH; ethtool -S lan4; \\
echo ---BIND; cat /sys/kernel/debug/ppe/bind_rate

# 每个窗口
ssh root@192.168.1.1 'setsid iperf3 -s -p 5201 -1 -J --logfile /tmp/srv-<tag>.json &'
until ssh root@192.168.1.1 'netstat -ltn | grep -q :5201'; do sleep 0.2; done
# <snapshot before>
iperf3 -c 192.168.1.1 -p 5201 -t 10 -P <1|4> [-R] -J > <tag>.client.json
# <snapshot after>

# 两臂
ssh root@192.168.1.1 'echo 10 10 > /sys/kernel/debug/ppe/bind_rate'   # 默认
ssh root@192.168.1.1 'echo 0  0  > /sys/kernel/debug/ppe/bind_rate'   # 关闭绑定
ssh root@192.168.1.1 'echo 10 10 > /sys/kernel/debug/ppe/bind_rate; cat /sys/kernel/debug/ppe/bind_rate'
```

## 结果

### Table 1 — `tx`：主机 → 设备（18 个窗口，本次实测）

接收端取设备 iperf3 server 的 `sum_received`；`组` 是驱动脚本的分组标签（`rtx` / `rrx`），
两组实测都是 `tx`（见摘要第 4 点），所以 1 流每臂 6 轮、4 流每臂 3 轮。

| # | arm | 流 | 轮 | 组 | 接收端 Mbit/s | 发送端 Mbit/s | pps | CPU-s | softirq | sys | user | idle % | retrans | bound Δ | lan4 rx 帧 | lan4 rx 字节 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | default | 1 | 1 | rrx | 888.6 | 899.0 | 95866 | 18.04 | 5.48 | 12.29 | 0.27 | 56.2 | 0 | 0 | 766411 | 1160253820 |
| 2 | default | 1 | 2 | rrx | 885.7 | 900.6 | 95836 | 18.02 | 5.39 | 12.43 | 0.20 | 56.4 | 0 | 0 | 765162 | 1158382117 |
| 3 | default | 1 | 3 | rrx | 855.0 | 865.5 | 94061 | 21.28 | 5.13 | 15.92 | 0.23 | 48.9 | 0 | 0 | 737026 | 1115800452 |
| 4 | default | 1 | 1 | rtx | 854.7 | 868.6 | 91582 | 21.08 | 5.39 | 15.46 | 0.23 | 49.3 | 0 | 0 | 738712 | 1118341854 |
| 5 | default | 1 | 2 | rtx | 850.5 | 862.6 | 95411 | 22.03 | 6.45 | 15.24 | 0.34 | 47.0 | 0 | 0 | 729339 | 1104155695 |
| 6 | default | 1 | 3 | rtx | 851.3 | 862.6 | 92139 | 17.27 | 5.10 | 11.93 | 0.24 | 58.1 | 0 | 0 | 730518 | 1105943821 |
| 7 | default | 4 | 1 | rtx | 861.0 | 906.6 | 91685 | 18.14 | 5.10 | 12.80 | 0.24 | 58.0 | 0 | 0 | 744758 | 1127478703 |
| 8 | default | 4 | 2 | rtx | 887.6 | 932.4 | 92692 | 18.87 | 5.34 | 13.28 | 0.25 | 57.0 | 0 | 0 | 771293 | 1167602607 |
| 9 | default | 4 | 3 | rtx | 907.7 | 952.2 | 97333 | 18.52 | 5.50 | 12.76 | 0.26 | 57.3 | 0 | 0 | 785537 | 1189229767 |
| 10 | unbind | 1 | 1 | rrx | 875.0 | 885.6 | 94561 | 17.69 | 5.28 | 12.22 | 0.19 | 57.2 | 0 | 0 | 750805 | 1136658316 |
| 11 | unbind | 1 | 2 | rrx | 889.0 | 903.4 | 92395 | 21.74 | 5.88 | 15.66 | 0.20 | 47.4 | 0 | 0 | 767913 | 1162543756 |
| 12 | unbind | 1 | 3 | rrx | 869.7 | 882.2 | 94184 | 18.68 | 5.17 | 13.30 | 0.21 | 55.2 | 0 | 0 | 746632 | 1130339419 |
| 13 | unbind | 1 | 1 | rtx | 900.5 | 912.7 | 97593 | 18.29 | 5.38 | 12.63 | 0.28 | 55.5 | 1 | 0 | 773385 | 1170848161 |
| 14 | unbind | 1 | 2 | rtx | 842.1 | 852.0 | 90968 | 17.79 | 5.15 | 12.38 | 0.26 | 57.5 | 0 | 0 | 722772 | 1094216268 |
| 15 | unbind | 1 | 3 | rtx | 834.9 | 844.2 | 88258 | 18.25 | 4.90 | 13.14 | 0.21 | 56.3 | 0 | 0 | 717979 | 1086960839 |
| 16 | unbind | 4 | 1 | rtx | 900.5 | 945.8 | 96774 | 18.40 | 5.38 | 12.78 | 0.24 | 57.3 | 0 | 0 | 778684 | 1178852764 |
| 17 | unbind | 4 | 2 | rtx | 862.8 | 909.1 | 91233 | 18.38 | 5.46 | 12.66 | 0.26 | 57.2 | 0 | 0 | 745764 | 1129009742 |
| 18 | unbind | 4 | 3 | rtx | 875.8 | 922.5 | 94191 | 18.02 | 5.41 | 12.34 | 0.27 | 58.5 | 0 | 0 | 760856 | 1151848292 |

### Table 2 — `rx`：设备 → 主机（12 个窗口，真 `-R`，本次实测）

接收端取主机 iperf3 client 的 `sum_received`；`B/计数帧` = `lan4 tx_bytes / tx_packets`，≈38 KB/帧，
说明发送侧有聚合，**不能当线上帧数用**。

| # | arm | 流 | 轮 | 接收端（主机）Mbit/s | 发送端（设备）Mbit/s | CPU-s | softirq | sys | user | idle % | 计数器帧/s | 设备 tx 字节 | B/计数帧 | retrans | bound Δ |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | default | 1 | 1 | 940.4 | 943.0 | 5.10 | 1.60 | 3.34 | 0.16 | 88.4 | 16276 | 1179859214 | 60010 | 0 | 0 |
| 2 | default | 1 | 2 | 942.5 | 944.3 | 7.08 | 3.65 | 3.33 | 0.10 | 83.9 | 16531 | 1181773834 | 60710 | 0 | 0 |
| 3 | default | 1 | 3 | 927.5 | 928.6 | 5.47 | 2.39 | 3.00 | 0.08 | 87.8 | 15064 | 1162255895 | 59278 | 0 | 0 |
| 4 | default | 4 | 1 | 935.2 | 938.9 | 8.14 | 4.43 | 3.60 | 0.11 | 81.5 | 20195 | 1175577180 | 28069 | 52 | 0 |
| 5 | default | 4 | 2 | 940.0 | 943.4 | 8.29 | 4.49 | 3.66 | 0.14 | 81.1 | 19979 | 1181731998 | 28535 | 65 | 0 |
| 6 | default | 4 | 3 | 936.1 | 939.2 | 8.31 | 4.28 | 3.95 | 0.08 | 81.2 | 19286 | 1176643339 | 28118 | 51 | 0 |
| 7 | unbind | 1 | 1 | 940.4 | 942.7 | 5.95 | 2.36 | 3.42 | 0.17 | 86.1 | 16584 | 1179822961 | 59917 | 0 | 0 |
| 8 | unbind | 1 | 2 | 934.0 | 935.0 | 5.15 | 2.08 | 2.98 | 0.09 | 88.4 | 15815 | 1170295521 | 60278 | 0 | 0 |
| 9 | unbind | 1 | 3 | 939.0 | 940.3 | 4.95 | 1.67 | 3.20 | 0.08 | 88.8 | 15702 | 1176804430 | 59888 | 0 | 0 |
| 10 | unbind | 4 | 1 | 944.5 | 947.6 | 8.64 | 4.85 | 3.68 | 0.11 | 80.3 | 20647 | 1186756678 | 27408 | 70 | 0 |
| 11 | unbind | 4 | 2 | 926.4 | 930.0 | 7.42 | 4.11 | 3.21 | 0.10 | 83.1 | 18565 | 1164151661 | 28717 | 79 | 0 |
| 12 | unbind | 4 | 3 | 932.3 | 935.9 | 8.01 | 4.26 | 3.63 | 0.12 | 81.9 | 19051 | 1172016614 | 28593 | 37 | 0 |

### Table 3 — min / median / max（不是单点）

| 单元 | n | 接收端 Mbit/s min/med/max | CPU-s min/med/max | softirq s min/med/max | 计数器 pps 范围 | retrans 合计 | bound Δ 合计 |
|---|---|---|---|---|---|---|---|
| tx · default · 1 流 | 6 | 850.5 / 854.9 / 888.6 | 17.27 / 19.56 / 22.03 | 5.10 / 5.39 / 6.45 | 91582…95866 | 0 | 0 |
| tx · default · 4 流 | 3 | 861.0 / 887.6 / 907.7 | 18.14 / 18.52 / 18.87 | 5.10 / 5.34 / 5.50 | 91685…97333 | 0 | 0 |
| tx · unbind · 1 流 | 6 | 834.9 / 872.4 / 900.5 | 17.69 / 18.27 / 21.74 | 4.90 / 5.22 / 5.88 | 88258…97593 | 1 | 0 |
| tx · unbind · 4 流 | 3 | 862.8 / 875.8 / 900.5 | 18.02 / 18.38 / 18.40 | 5.38 / 5.41 / 5.46 | 91233…96774 | 0 | 0 |
| rx · default · 1 流 | 3 | 927.5 / 940.4 / 942.5 | 5.10 / 5.47 / 7.08 | 1.60 / 2.39 / 3.65 | 15064…16531 | 0 | 0 |
| rx · default · 4 流 | 3 | 935.2 / 936.1 / 940.0 | 8.14 / 8.29 / 8.31 | 4.28 / 4.43 / 4.49 | 19286…20195 | 168 | 0 |
| rx · unbind · 1 流 | 3 | 934.0 / 939.0 / 940.4 | 4.95 / 5.15 / 5.95 | 1.67 / 2.08 / 2.36 | 15702…16584 | 0 | 0 |
| rx · unbind · 4 流 | 3 | 926.4 / 932.3 / 944.5 | 7.42 / 8.01 / 8.64 | 4.11 / 4.26 / 4.85 | 18565…20647 | 186 | 0 |

噪声：`tx` 第 5 轮与 `rx` 1 流 default 第 2 轮偏高（CPU-s 上浮 10–25%），频率已锁 1.2 GHz 排除调频，
更可能是 `ssh` / `ethtool` 采样与零星工作落进这 10 s。所以结论只给 min/med/max，不拿单轮互相比。

## 校验：包确实过了这条路径，PPE 确实没参与

| 证据 | 数值 |
|---|---|
| `tx` 方向 `lan4 rx_packets` 差分 | 717 979–785 537 / 10 s（≈ 88–97 k pps），18/18 非零 |
| `tx` 方向 `lan4 rx_bytes` 差分 | 1.087–1.192 GB / 10 s，与 iperf3 传输量一致 |
| `rx` 方向 `lan4 tx_bytes` 差分 | 1.162–1.187 GB / 10 s，12/12 非零 |
| 合计 | 30 窗；`tx` 13 533 546 帧 / 20.49 GB（1514 B/帧）；`rx` 14.11 GB / 367 458 计数帧（38.4 KB/帧） |
| `/proc/net/snmp` | `RetransSegs` Δ 合计 355，全部落在 `rx 4 流` 的 6 个窗口（37–79/窗）；其余全 0 |
| `ppe/usage` | `bound 0`、`unbound 0`、`l2b_bound 0`、`l2_flows_sw 0`，30/30 不变 |
| `ppe/entries` | 独立检查为空（0 行）；这是采集前后各查一次的结果，**不是**逐窗字段（见局限） |
| 两臂 `bind_rate` | 写后回读 30/30 生效：`l3 10 l2b 10` / `l3 0 l2b 0` |

## 与 `scripts/claims.yaml` 的关系（哪些数字能沿用）

只有 `evidence: 实测` 能沿用；本仓库 perf/PPE 相关条目**没有一条**是 `实测`。

| claim id | 主题 | evidence | 本轮是否触及 |
|---|---|---|---|
| `ppe-table-24576` | 表几何 24576（FLOW_STATS=y） | 代码 | 只读观察：本机 `usage` 打印 `entries 32768 (sram 16384, dram 16384)`，与 24576 不一致，见下 |
| `ppe-table-32768` | 表几何 32768 | 代码（refuted） | 同上：本机打印反而像 32768 几何 |
| `ppe-19826-slots` | 可用槽位 19826 | 推断（unverified） | 未触及 |
| `ppe-counter-index-identity` | 计数器恒等映射 | 代码 | 未触及（本机没有 per-flow 计数器） |
| `ppe-hash-bijective` | hash 折叠覆盖全槽 | 代码 | 未触及 |
| `bridge-ttl-hardware-path` | 桥内转发保 TTL | 代码 | 未触及（没有转发路径） |
| `10g-unidirectional-baseline` | 10G 只跑单向 | 推断（unverified） | 未触及（无 10G 口） |
| `stock-bridge-gap` | stock 9.4 vs 移植 3.2 Gbit/s | 推断（unverified） | 未触及（未跑 stock） |

`target/linux/airoha/an7581/target.mk:35-36` 的 “3.5M-packet run / 34.3 → 0.46 CPU-seconds”：

* 在 `claims.yaml` 里**没有条目**，也没有任何落盘原始数据（`docs/` 之前没有 perf 记录）；
* 用本次 `tx` 数据折算：3.5 M 帧 ≈ 18.6–22.9 CPU-s/M × 3.5 ≈ 65–80 CPU-s，但口径是
  “本地终结 + 设备自带 iperf3 server + 仅上行”，与被描述的**转发流**不可比，不能互换；
* 结论：该数字目前**无实测背书**，本次既不复现也不反驳。

### 一个顺带发现的、未处理的观察

`/sys/kernel/debug/ppe/usage` 打印 `entries 32768 (sram 16384, dram 16384)`，
而 `CONFIG_NET_AIROHA_FLOW_STATS=y` + patch 209 推出的几何应是 8192 SRAM + 16384 DRAM = 24576。
运行镜像 `r37994-44d4267ca7` 正是本仓 `xr1710g` HEAD `44d4267ca7`。这条不一致本次**不处理**、
也不改 `claims.yaml`，但 `ppe-table-24576` 需要在出货镜像上重核。

## 局限

* **单臂、纯有线、1G**：`lan4` 上限 1000 Mb/s，`wan` 无 carrier，主机无 2.5G/10G 口。
* **无线缺**：主机无 WiFi 网卡；设备三个 VAP 无 STA。6 GHz EHT320 那行本次无法测。
* **没有转发路径**：PPE 只对 nf_flow_table offload 的**被转发**流生效；本地终结流不产生 entry。
  想要“卸载前/后”的 CPU 差，必须有两个端点（lan↔lan 或 lan↔wifi）。
* **客户端在 NAT 后的容器里**：设备侧看到的源是 NAT 主机。不影响设备侧 `lan4` 计数与设备 CPU 计时，
  但主机侧 CPU 不可比。
* **设备侧在跑 iperf3 server**：`tx` 方向 `user` 只有 0.2–0.3 CPU-s，几乎全在 `sys`（内核收发拷贝），
  所以“CPU-s/包”天然含 server 成本，不能与“纯转发”数字类比。
* **计数器语义**：`rx` 方向的 `tx_packets` 是聚合帧，见摘要第 5 点。
* **`ppe/entries` 没有逐窗落盘**：两版脚本的 snapshot 只采了 `ppe/usage`，`entries` 是采集前后各查一次。
  下一版协议应把它加进 snapshot（本文协议段已写上，脚本尚未照做）。
* 未跑 stock 固件；始终单向（`tx` 与 `rx` 分开跑），遵守 issue #26 的单向规则。

## 原始文件（本次采集，未入库）

`/tmp/agent-reports/meas/`

| 路径 | 内容 |
|---|---|
| `run.sh` / `run2.sh` | 第一版 18 窗（全 tx，含方向 bug）与修正后 12 窗（真 `-R`）的驱动脚本 |
| `parse_v2.py` | 从 raw 直接算表：方向取自 `test_start.reverse`，臂取自 `bind_rate` 回读并断言，带覆盖度自检 |
| `raw/<tag>.before.snap` / `.after.snap` | 设备原始 `/proc/stat`、`ppe/usage`、`/proc/net/snmp`、`ethtool -S lan4`、`bind_rate` |
| `raw/<tag>.client.json` / `.server.json` | 两端 iperf3 原始 JSON（含 `reverse`、双端 `bits_per_second`、`retransmits`） |
| `raw/results_v2.json` | 30 窗结构化结果（唯一可信的解析产物） |
| `raw/arm-log.txt` / `arm2-log.txt` | 两组的 `bind_rate` 写后回读记录 |

## 对 #13 / #30 的用法

* **#13**：本表只能填 “wired 1G / 本地终结 / OpenWrt（非 stock）” 一行，且必须同时标注“PPE 未参与”。
  stock 行、2.5G/10G 行、无线行、纯 L2 桥接行仍空。
* **#30**：本轮已覆盖该 issue 的 6 项要求——监听门、真 `-R` 双向 + 双端 `Mbits/sec` 与 `retr`、逐窗原始落盘、
  一次只改 `bind_rate` 且记录回读、无失败臂（30/30 有效）、固定表头。另建议并进本 issue 的两条协议要求：
  1. **方向必须由 `test_start.reverse` 断言**（本轮第一版就是标签与实测不符）；
  2. **`rx` 方向不要用 `tx_packets` 算 pps / 每包成本**，改用 `tx_bytes`（聚合帧会差 20 倍以上）。
  `decap` / `force_lro` / `ft devices` / MTU 四列本轮都没动（无 PPPoE、未切 LRO、flowtable 设备集固定、MTU 1500），
  如实标注“未变”。

[![](https://img.shields.io/badge/powered_by-dsh-4D6BFE?style=flat-square&logo=deepseek&logoColor=white)](https://github.com/deepseek-ai/deepseek-harness)
