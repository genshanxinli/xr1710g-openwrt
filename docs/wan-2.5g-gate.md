# 2.5G WAN 闸门

**状态**：`BLOCKED` —— 本机没有任何 2.5G 对端，闸门无法判定；文档 + `tools/wan-bench/2.5g.sh` 已可重复执行。
**关联**：#85、#44、#70、#30、#90。
**结论先行**：2.5G 档位是否成立，必须由下面第 5 节的两条命令在真机上跑出 `result.json` 才能判定。
在拿到 2.5G 对端之前，任何 10G 或 1G 的数字都**不能**折算成 2.5G 结论；本文件保持 `UNVERIFIED`。

## 1. 当前的阻塞点（实测）

| 端口 | 驱动 | `speed` | 链路 | 支持的 link modes | 能否承载 2.5G |
|---|---|---|---|---|---|
| `lan4` | `dsa`（内置 GbE 交换口） | `1000` | up | 10/100/**1000**baseT | **不能**，PHY 上限就是 1000 |
| `lan2` | `airoha_eth`（外置 RTL8261BE，PHYAD 5） | `-1` | no | 100/1000/**2500**/**5000**/**10000**baseT | 能，但当前无对端 |
| `wan` | `airoha_eth`（外置 RTL8261BE，PHYAD 8） | `-1` | no | 100/1000/**2500**/**5000**/**10000**baseT | 能，但当前无对端 |
| `lan3` | — | `-1` | lowerlayerdown | — | 未接线 |

判定为 `BLOCKED` 的依据：

1. `lan4` 的 `Supported link modes` 里没有 2500baseT（`ethtool lan4`，实测），把 2.5G USB
   网卡插进 `lan4` 只会协商到 **1000 Mb/s**，测出来的数是 1G 的数，不是 2.5G 的数。
2. `lan2` / `wan` 确实 advertise 2500baseT，但两者都是 `Link detected: no`、
   `/sys/class/net/<if>/speed = -1`（实测）——**没有插任何对端**。
3. 本仓库的 bench host 也没有 2.5G 网卡：唯一 up 的物理口 `enP59185p0s0` 是 10000 Mb/s
   （实测），所以 `2.5g.sh` 会在前置检查处直接 `exit 1`，`--dry-run` 会先把这条
   前置检查打印出来。

结论：**闸门今天无法给出 PASS / 2.5G-only / close-10G-line 中的任何一个**。这不是"还没测"，
而是"硬件组合不存在"——把结论写成"接近 2.5G"或按 10G 数字外推，都是伪造。

## 2. 硬件与接线

| 件 | 要求 | 说明 |
|---|---|---|
| USB NIC ×2 | RTL8156B 或同类 2.5G USB 网卡 | 同一型号、同一驱动版本，避免两端不对称 |
| 主机侧 | 一个 USB3 口给 WAN 侧 NIC | USB2 口会把上限压到 ~300 Mbit/s，测出来没有意义 |
| 对端 | 第二个 USB NIC 接 LAN 侧 | 对端可以是另一台 Linux 主机 |
| 路由器 | **`wan` 与 `lan2`**，不要用 `lan4` | 见第 1 节：`lan4` 是 1000baseT 上限的交换口 |

```
   bench host                          XR1710G                         peer
 +-------------+  2.5G link   +----------------------+  2.5G link  +-------------+
 | USB NIC ----+--------------+ wan  (RTL8261BE, PHYAD 8)         | USB NIC     |
 | (--iface)   |              |   forward / PPE      |             | (--peer-if) |
 +-------------+              | lan2 (RTL8261BE, PHYAD 5) ---------+-------------+
                              +----------------------+
```

- WAN 侧网卡名写进 `--iface`，LAN 侧写进 `--peer-if`（对端主机）或 `--router`（被测路由器）。
- 两端都要求 `cat /sys/class/net/<if>/speed` 为 `2500`；不是 2500 的臂直接判无效，
  脚本在发出任何 iperf3 流量**之前**就以 exit 1 退出。
- 不要用 USB hub 串两个 2.5G 网卡；两个口共享一条 USB3 上行会互相限速。

## 3. 驱动与识别

```sh
# 两端都执行
lsusb | grep -i -E 'realtek|8156'
ethtool -i <if>            # driver: r8152
cat /sys/class/net/<if>/speed
dmesg | grep -i r8152 | tail -20
```

`r8152` 是内核驱动；如果 `ethtool -i` 显示 `cdc_ni` / `cdc_ether`，先换回 `r8152` 再测，
否则 2500baseT 根本没启用（这两个驱动只给 1G 的 usbnet 路径）。

本镜像里连模块都没有：`ls /lib/modules/7.3/ | grep -iE '8152|usbnet|cdc'` 在 95 个模块中
无任何匹配（实测），所以"把 2.5G USB 网卡直接插在路由器上、让它当 `wan`"这条路当前不成立——
要先加 `kmod-usb-net-rtl8152` 一类的包，那是镜像改动，不在本闸门范围内。

## 4. USB 网卡特有的风险（判定前必须先排除）

| 风险 | 为什么会影响闸门 | 怎么证伪 | 证据等级 |
|---|---|---|---|
| `usbnet` 与 `virtio_net` 的统计口径不同 | `ethtool -S` 在 virtio 上只有少量计数，在 r8152 上是一整套；拿两种网卡的 `-S` 对比会得出错误结论 | 每个快照文件里 `ethtool -i` 与 `-S` 同时落盘，只比同驱动的两端 | 代码 |
| `ethtool -S` 覆盖不全 | r8152 的收发计数在部分内核版本里不含丢包/重传，`retr` 只能看 iperf3 的 `retransmits` | 以 iperf3 `-J` 的 `sum_sent.retransmits` 为准，`-S` 只作旁证 | 推断 |
| PPE / QDMA 是否对 USB netdev 生效 | 若 offload 不生效，测到的是 CPU 转发上限，不是路由器能力上限 | 见下方代码结论 + `nft list flowtables` 快照 | 代码 |
| USB3 控制器共享 / 软中断单核 | 单向 2.5G 约 2.3 Gbit/s，单核软中断很容易先撞墙 | 记录每臂 `/proc/stat` 的 CPU jiffies 差与 `retransmits` | 实测（字段已入 result.json） |
| `lan4` 误当 2.5G 口 | 会得到 1G 的数并误判为"2.5G 不成立" | 前置检查：两端都必须 2500，否则 exit 1 | 实测（第 1 节） |

PPE 是否作用于 USB netdev —— 结论是**不作用于 bench host 上的那块 USB 网卡，但它也不需要在
路由器上生效**：

- 路由器侧的网卡（`lan2`/`wan`）是 `airoha_eth` 的 GDM 口，由设备树的 `reg` 决定端口号：
  `airoha_alloc_gdm_port()`（`airoha_eth.c:4477`）里 `airoha_eth.c:4491` 取 `reg` 得 `id`、
  `airoha_eth.c:4492` 算出 `p = id - 1`，`airoha_eth.c:4494` 拒绝越界 id，
  `airoha_eth.c:4510` 才把 `port` 挂进 `eth->ports[p]`。
- 收包方向按 descriptor 里的 SPORT 反查端口：`airoha_qdma_get_gdm_dev()`
  （`airoha_eth.c:1015-1031`）查不到 port 就直接 `return ERR_PTR(-ENODEV)`。
- 所以"哪些 netdev 有 QDMA 环"完全由设备树 + GDM 索引决定；USB NIC 在 bench host 上，
  对路由器不可见，PPE 只看到 `wan` ↔ `lan2` 这一对 GDM 口，offload 该生效就生效。

这条同时说明：**如果用 USB 网卡替代路由器自己的 `wan` 口**（把 USB NIC 插在路由器上跑 PPPoE），
那才是真正"PPE 对 USB netdev 不生效"的场景——这条路本镜像连 `r8152` 模块都没加载，直接排除。

## 5. 测量步骤

脚本在 bench host 上运行，通过 SSH 在 peer 上起 `iperf3 -s -1`。

```sh
# 1) 干跑：只打印命令、快照计划和结果路径，不启动 iperf3/ssh
tools/wan-bench/2.5g.sh --iface enp9s0 --peer 192.0.2.10 --peer-if enp9s1 --dry-run

# 2) 实跑：TX 60s，然后 RX 60s，各自单独一次
tools/wan-bench/2.5g.sh \
  --iface enp9s0 --peer 192.0.2.10 --peer-ssh root@192.0.2.10 --peer-if enp9s1 \
  --router root@192.168.1.1 \
  --duration 60 --parallel 4 --out research/lead/triage/offline/wan-raw/2.5g/result.json
```

脚本逐臂做这些事：

1. `pre` 快照：本机与对端 `ethtool` / `ethtool -i` / `ethtool -S`；给了 `--router` 时
   再抓 `nft list flowtables`、`/proc/sys/net/netfilter/nf_flowtable_*` 与
   `uci show firewall | grep flow_offloading`。
2. 前置检查：任一端 `speed` 不是 2500 就 exit 1，此时 `pre` 快照已经落盘，
   错误信息里带快照路径——拒绝本身可审计。
3. 在 peer 上执行 `ss -ltnp | grep :5201`；没监听则该臂无效，退出码非 0。
4. TX：`iperf3 -c PEER -p 5201 -t 60 -P 4 -J`，跑完再抓一次 `tx` 快照。
5. RX：另起一次 server，`iperf3 -c PEER -p 5201 -t 60 -P 4 -R -J`，跑完抓 `rx` 快照。
6. 每臂记录 sender/receiver Mbit/s、`retransmits`、本机 `/proc/stat` CPU jiffies 差值、
   原始 JSON、`2.5g-<arm>.env.txt`。
7. 写 `result.json`。

一次运行的产物（`<out dir>` 下）：

```
2.5g-pre.<iface>.txt     本地第 1 次快照（ethtool 全文 + -i + -S）
2.5g-pre.<peer-if>.txt   对端第 1 次快照
2.5g-pre.router.txt      路由器快照（无 --router 时不生成）
2.5g-tx.<iface>.txt      TX 臂之后的快照（与 pre 相减即该臂的收发计数）
2.5g-rx.<iface>.txt      RX 臂之后的快照
2.5g-tx.raw.json / 2.5g-rx.raw.json   iperf3 -J 原始输出
2.5g-tx.env.txt / 2.5g-rx.env.txt     该臂的 speed/driver/mtu/iperf3 版本
result.json
```

`result.json` 的形状（`iface` 段里 `supported/advertised_link_modes`、`duplex` 来自 `pre`
快照，`snapshots` 段给出每个快照的实际路径，没跑就没有该键）：

```json
{
  "schema": "wan-bench-2.5g/v1",
  "iface": {"name": "enp9s0", "speed_mbps": 2500, "driver": "r8152",
            "duplex": "Full",
            "supported_link_modes": "2500baseT/Full",
            "advertised_link_modes": "2500baseT/Full"},
  "router": {"host": "root@192.168.1.1", "snapshot": ".../2.5g-pre.router.txt"},
  "peer": {"host": "192.0.2.10", "iface": "enp9s1", "speed_mbps": 2500},
  "config": {"port": 5201, "duration_s": 60, "parallel": 4, "directions": ["tx", "rx"]},
  "arms": [
    {"name": "tx", "valid": true, "sender_mbps": null, "receiver_mbps": null,
     "retransmits": null, "cpu_jiffies_delta": null, "raw_log": "..."},
    {"name": "rx", "valid": true, "sender_mbps": null, "receiver_mbps": null,
     "retransmits": null, "cpu_jiffies_delta": null, "raw_log": "..."}
  ],
  "snapshots": {"pre": {"local": "...", "peer": "...", "router": "..."},
                "tx":  {"local": "...", "peer": "...", "router": "..."},
                "rx":  {"local": "...", "peer": "...", "router": "..."}},
  "gate": {"basis": "min(receiver_mbps of both valid arms)",
           "min_receiver_mbps": null, "pass_mbps": 2200, "floor_mbps": 1500,
           "verdict": "invalid"}
}
```

数字只能由脚本实跑填写；上面的 `null` 是骨架，不是结果。

## 6. 判定表

前置条件（全部满足才进入判定，任一不满足 → `BLOCKED`，不得下结论）：

| # | 前置条件 | 怎么核对 | 今天 |
|---|---|---|---|
| P1 | 路由器侧端口是 `lan2` 或 `wan`（`lan4` 上限 1000baseT） | `ethtool <port> \| grep -A3 'Supported link modes'` | lan2/wan 满足；lan4 不满足 |
| P2 | 该端口 `Link detected: yes` 且 `Speed: 2500Mb/s` | `ethtool <port>` | **不满足**（both `no` / `Unknown!`） |
| P3 | bench host 的 `--iface` `speed=2500` | `result.json.iface.speed_mbps` | **不满足**（本机只有 10000 的口） |
| P4 | 对端 `--peer-if` `speed=2500` | `result.json.peer.speed_mbps` | 不满足（无对端） |
| P5 | 两臂都 `valid=true`（listener 检查通过、iperf3 解析成功） | `result.json.arms[].valid` | 未跑 |
| P6 | 路由器快照里 flowtable 含被测的两个端口 | `2.5g-pre.router.txt` | 未跑（当前 flowtable 含 `wan`，`lan2` 在 inet/bridge 两处都在） |

满足 P1–P6 后，按**较慢那个方向**的 receiver 值判定：

| 判定 | 条件（两臂都有效，取较慢的 receiver Mbit/s） | 产品含义 | 退出码 |
|---|---|---|---|
| **PASS** | ≥ 2200 | 2.5G 档位成立，可继续 10G 产品线 | 0 |
| **2.5G-only** | 1500 – 2200 | 只承诺 2.5G，不把 10G 当卖点 | 3 |
| **close 10G line** | < 1500 | 关闭 10G 产品线；先查 USB/驱动/CPU，不要先怪路由器 | 4 |
| **BLOCKED** | 任一前置条件不满足 | 不下结论（今天的状态） | 1 |

门限按 **receiver** 的 `bits_per_second` 计算，不按 sender；sender 只用于判断重传与瓶颈在
哪一端。低于 2.2 但高于 1.5 时，不允许写"接近 2.5G"这种模糊结论。

**今天（2026-11-20）的判定**：

| 判定 | 依据 |
|---|---|
| `BLOCKED` | P2/P3/P4 全不满足：路由器 `lan2`/`wan` 无链路，bench host 与对端都没有 2.5G 网卡 |

## 7. 解除 BLOCKED 的最小步骤

1. 两块 RTL8156B（或同代 2.5G USB NIC），各自插在独立的 USB3 控制器上。
2. bench host 的 NIC 接路由器 **`lan2`**，peer 的 NIC 接 bench host 的另一个口
   （或按第 2 节接线图，让被测路径是 `wan` → `lan2`）。
3. 两边 `ethtool <if>` 必须看到 `Speed: 2500Mb/s`、`Advertised link modes: 2500baseT/Full`。
4. 跑第 5 节第 2 条命令，把整个输出目录（含 `result.json` 与全部快照）放进
   `research/lead/triage/offline/wan-raw/2.5g/`。
5. 把第 8 节的表填上真实数字，`BLOCKED` 才能改成 PASS/2.5G-only/close-10G-line。

## 8. 实测记录

| 日期 | 固件/镜像 | 端口 | iface / peer-if | TX receiver | RX receiver | retr TX/RX | verdict | result.json |
|---|---|---|---|---|---|---|---|---|
| 2026-11-20 | r38047-a86ce12e27 | lan4（1000 上限） | — | UNVERIFIED | UNVERIFIED | — | **BLOCKED** | — |
| 2026-11-20 | r38047-a86ce12e27 | lan2 / wan | — | UNVERIFIED | UNVERIFIED | — | **BLOCKED**（无对端） | — |

## 9. 失败排查顺序

1. `speed` 不是 2500 → 换 USB3 口/线，确认 NIC 型号与 `r8152`；先看 `pre` 快照里的
   `Advertised link modes` 是否含 2500baseT。
2. 端口是 `lan4` → 换 `lan2`/`wan`（`lan4` 是 `dsa` 的 1000baseT 交换口，改不了）。
3. server 没监听 → 看 peer 的 `$SERVER_LOG`（默认 `/tmp/wan-bench-2.5g-server.log`）。
4. `retransmits` 高但 receiver 低 → 先查 USB 控制器共享与 CPU 软中断，不要先改路由器。
5. TX 正常、RX 明显低 → 检查 WAN LRO 是否只在物理 WAN 上开启（见
   `docs/wan-measurement-protocol.md` 第 1 节），以及 `pre`/`rx` 两次路由器快照里
   flowtable 的设备列表是否仍然包含 `wan`。

## 10. 如何验证本文与脚本

```sh
test -x tools/wan-bench/2.5g.sh
sh -n tools/wan-bench/2.5g.sh
shellcheck -s sh -S warning tools/wan-bench/2.5g.sh
tools/wan-bench/2.5g.sh --help
tools/wan-bench/2.5g.sh --iface enp9s0 --peer 192.0.2.10 --peer-if enp9s1 --dry-run

# 离线自测：假 sysfs + 假 iperf3/ssh/ethtool/nft/uci
scripts/tests/wan-2.5g-bench-test.sh

grep -n 'ss -ltnp | grep :' tools/wan-bench/2.5g.sh
grep -n -- '-R' tools/wan-bench/2.5g.sh
grep -n 'PASS_MBPS=2200\|FLOOR_MBPS=1500' tools/wan-bench/2.5g.sh
grep -n 'UNVERIFIED' docs/wan-2.5g-gate.md
```

预期：`sh -n`、`shellcheck`、`--help`、`--dry-run`、自测脚本均返回 0；`--dry-run` 打印两条
`iperf3` 命令、三次快照计划与 `result.json` 路径，且不产生任何网络流量。自测脚本覆盖两点：
1G 链路必须 exit 1 且不留 iperf3 调用、2500 链路必须 exit 0 且 `result.json` 带
`verdict=pass` 与三组快照路径。
