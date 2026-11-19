# 2.5G WAN 闸门

**状态**：门限文档 + `tools/wan-bench/2.5g.sh`；本仓库没有 2.5G USB NIC，**没有实测数字**。
**关联**：#85、#44、#70、#30、#90。
**结论先行**：2.5G 档位是否成立要靠下面两条命令的实际输出判定；未跑之前只能写
`UNVERIFIED`，不应把 10G 或 1G 的数字折算成 2.5G。

## 1. 硬件与接线

| 件 | 要求 | 说明 |
|---|---|---|
| USB NIC ×2 | RTL8156B 或同类 2.5G USB 网卡 | 同一型号、同一驱动版本，避免两端不对称 |
| 主机侧 | 一个 USB3 口给 WAN 侧 NIC | USB2 口会把上限压到 ~300 Mbit/s，测出来没有意义 |
| 对端 | 第二个 USB NIC 接 LAN 侧 | 对端可以是另一台 Linux 主机 |
| 路由器 | XR1710G，WAN 口与 lan2 口 | 2.5G NIC 插 10G 口会协商到 2.5G，这是预期 |

```
   bench host                          XR1710G                         peer
 +-------------+  2.5G link   +----------------------+  2.5G link  +-------------+
 | USB NIC ----+--------------+ WAN (gdm2)           |             | USB NIC     |
 | (--iface)   |              |   forward / PPE      |             | (--peer-if) |
 +-------------+              | LAN (lan2 / gdm4) ---+-------------+-------------+
                              +----------------------+
```

- WAN 侧网卡名写进 `--iface`，LAN 侧写进 `--peer-if`。
- 两端都要求 `cat /sys/class/net/<if>/speed` 为 `2500`；不是 2500 的臂直接判无效。
- 不要用 USB hub 串两个 2.5G 网卡；两个口共享一条 USB3 上行会互相限速。

## 2. 驱动与识别

```sh
# 两端都执行
lsusb | grep -i -E 'realtek|8156'
ethtool -i <if>            # driver: r8152
cat /sys/class/net/<if>/speed
dmesg | grep -i r8152 | tail -20
```

`r8152` 是内核驱动；如果 `ethtool -i` 显示 `cdc_ni` 或其他驱动，先换回 `r8152` 再测，
否则 2.5G 能力可能根本没启用。

## 3. 测量步骤

脚本在 bench host 上运行，通过 SSH 在 peer 上起 `iperf3 -s -1`。

```sh
# 1) 干跑：只打印命令和结果路径，不启动 iperf3/ssh
tools/wan-bench/2.5g.sh --iface enp9s0 --peer 192.0.2.10 --peer-if enp9s1 --dry-run

# 2) 实跑：TX 60s，然后 RX 60s，各自单独一次
tools/wan-bench/2.5g.sh \
  --iface enp9s0 --peer 192.0.2.10 --peer-ssh root@192.0.2.10 --peer-if enp9s1 \
  --duration 60 --parallel 4 --out research/lead/triage/offline/wan-raw/2.5g/result.json
```

脚本逐臂做这些事：

1. 在 peer 上执行 `ss -ltnp | grep :5201`；没监听则该臂无效，退出码非 0。
2. TX：`iperf3 -c PEER -p 5201 -t 60 -P 4 -J`。
3. RX：另起一次 server，`iperf3 -c PEER -p 5201 -t 60 -P 4 -R -J`。
4. 每臂记录 sender/receiver Mbit/s、`retransmits`、本机 `/proc/stat` CPU jiffies 差值、
   `ethtool`/`speed`、原始 JSON、`2.5g-<arm>.env.txt`。
5. 写 `result.json`，字段见下。

`result.json` 的最小形状：

```json
{
  "schema": "wan-bench-2.5g/v1",
  "iface": {"name": "enp9s0", "speed_mbps": 2500, "driver": "r8152"},
  "peer": {"host": "192.0.2.10", "iface": "enp9s1", "speed_mbps": 2500},
  "config": {"port": 5201, "duration_s": 60, "parallel": 4, "directions": ["tx", "rx"]},
  "arms": [
    {"name": "tx", "valid": true, "sender_mbps": null, "receiver_mbps": null,
     "retransmits": null, "cpu_jiffies_delta": null, "raw_log": "..."},
    {"name": "rx", "valid": true, "sender_mbps": null, "receiver_mbps": null,
     "retransmits": null, "cpu_jiffies_delta": null, "raw_log": "..."}
  ],
  "gate": {"basis": "min(receiver_mbps of both valid arms)",
           "min_receiver_mbps": null, "pass_mbps": 2200, "floor_mbps": 1500,
           "verdict": "invalid"}
}
```

数字只能由脚本实跑填写；上面的 `null` 是骨架，不是结果。

## 4. 判定门限

| 判定 | 条件（两个方向都有效，取较慢的 receiver 值） | 产品含义 |
|---|---|---|
| **PASS** | ≥ 2.2 Gbit/s | 2.5G 档位成立，可继续 10G 产品线 |
| **2.5G-only** | 1.5–2.2 Gbit/s | 只承诺 2.5G，不把 10G 当卖点 |
| **close 10G line** | < 1.5 Gbit/s | 关闭 10G 产品线；先查 USB/驱动/PCIe，不要先怪路由器 |

门限按 **receiver** 的 `bits_per_second` 计算，不按 sender；sender 只用于判断重传与瓶颈在
哪一端。低于 2.2 但高于 1.5 时，不允许写“接近 2.5G”这种模糊结论。

## 5. 实测记录

| 日期 | 固件/镜像 | iface / peer-if | TX receiver | RX receiver | retr TX/RX | verdict | 原始 result.json |
|---|---|---|---|---|---|---|---|
| — | — | — | UNVERIFIED | UNVERIFIED | — | 未跑 | — |

当前仓库没有 2.5G USB NIC，也没有完成的 2.5G 实测；上表保持 `UNVERIFIED`。需要的实验：
按第 1 节接线，两端 `speed=2500`，跑 `tools/wan-bench/2.5g.sh`，把 `result.json` 与两臂
原始 JSON 放进 `research/lead/triage/offline/wan-raw/2.5g/`。

## 6. 失败排查顺序

1. `speed` 不是 2500 → 换 USB3 口/线，确认 NIC 型号与 `r8152`。
2. server 没监听 → 看 peer 的 `$SERVER_LOG`（默认 `/tmp/wan-bench-2.5g-server.log`）。
3. `retransmits` 高但 receiver 低 → 先查 USB 控制器共享与 CPU 软中断，不要先改路由器。
4. TX 正常、RX 明显低 → 检查 WAN LRO 是否只在物理 WAN 上开启（见
   `docs/wan-measurement-protocol.md` 第 1 节），以及 `nft list flowtables` 是否包含 WAN。

## 7. 如何验证本文与脚本

```sh
test -x tools/wan-bench/2.5g.sh
sh -n tools/wan-bench/2.5g.sh
shellcheck -s sh -S error tools/wan-bench/2.5g.sh
tools/wan-bench/2.5g.sh --help
tools/wan-bench/2.5g.sh --iface enp9s0 --peer 192.0.2.10 --peer-if enp9s1 --dry-run

grep -n 'ss -ltnp | grep :' tools/wan-bench/2.5g.sh
grep -n -- '-R' tools/wan-bench/2.5g.sh
grep -n 'PASS_MBPS=2200\|FLOOR_MBPS=1500' tools/wan-bench/2.5g.sh
grep -n 'UNVERIFIED' docs/wan-2.5g-gate.md
```

预期：`sh -n`、`shellcheck`、`--help`、`--dry-run` 均返回 0；`--dry-run` 打印两条
`iperf3` 命令和 `result.json` 路径，且不产生任何网络流量。
