# WAN 测量协议

**状态**：协议文档（doc-only），没有产生任何新测量。
**适用**：XR1710G WAN 路径（1G / 2.5G / 10G、PPPoE、LRO、PPE 流表）的吞吐与 CPU 成本对比。
**关联**：#30、#26、#44、#70、#85、#86、#90、#102。

本文只规定“怎样测才算数”。仓库里已有的 5.77 Gbit/s、2340/2400/2450 Mbit/s 等数字来自
不同链路、不同方向或不同配置，不应直接当作 1G 或 10G 的基线；详见
[`docs/MTU-POLICY.md`](MTU-POLICY.md) 与 `research/lead/triage/` 下的证据记录。

## 1. 一次性前置条件

1. 两端时钟与工具版本记录进结果文件：

   ```sh
   date -u +%Y-%m-%dT%H:%M:%SZ
   iperf3 --version | head -1
   uname -a
   ```

2. 路由器侧先确认 WAN 设备与链路速率，不接受“口插上了”作为证据：

   ```sh
   ip -br link show wan
   cat /sys/class/net/wan/speed
   ethtool wan | sed -n '/Speed:/p'
   ```

3. 每个 arm 开始前，在 **iperf3 服务端** 检查监听。服务端没在监听，这一臂直接判无效，
   不进入统计：

   ```sh
   ss -ltnp | grep :5201
   ```

4. 记录本臂的完整环境，缺一项就标 `UNVERIFIED`：

   | 项 | 取值来源 |
   |---|---|
   | WAN 设备与驱动 | `ip -br link`、`ethtool -i wan` |
   | 链路速率/双工 | `cat /sys/class/net/wan/speed`、`ethtool wan` |
   | MTU | `cat /sys/class/net/wan/mtu`（PPPoE 同时记 `pppoe-wan`） |
   | `ppe/pppoe_decap` | `cat /sys/kernel/debug/ppe/pppoe_decap`（不存在就写 `absent`） |
   | `force_lro` / `rx-lro` | `ethtool -k wan \| grep -E 'large-receive-offload'` |
   | flowtable 设备 | `nft list flowtables` |
   | PPE 绑定条目 | `grep -c ' BND ' /sys/kernel/debug/ppe/entries`（只读） |
   | CPU/IRQ | `mpstat -P ALL 1 1`、`grep -E 'qdma\|eth' /proc/interrupts` |

## 2. 单变量规则

**一个 arm 只改一个变量。** 其它变量保持不变并写进结果行；任何“顺手也改了”的 arm 作废。
允许的变量示例：

- `ppe/pppoe_decap` 取值（0/1/2，或 #81 落地后的 3）；
- `rx-lro` on/off（只对 WAN 物理设备，见
  `target/linux/airoha/an7581/base-files/etc/hotplug.d/iface/52-wan-lro`）；
- flowtable 设备集合（`nft list flowtables` 前后各存一份）；
- MTU（只允许 1500 与 9000 两档，且同一条路径内不变）。

禁止在同一 arm 内同时改 decap 与 LRO；也禁止用“重启后默认值变了”代替显式记录。

## 3. 四臂矩阵（1G PPPoE 入向）

四臂是 **PPPoE 入向** 的最小对照集。A 是控制臂，B 是当前默认，C/D 是判别臂；C 或 D 需要
对应补丁存在，不存在就写 `BLOCKED`，不要用别的配置冒充。

| Arm | 路径 | 命令（服务端在 LAN 侧） | 发送 Mbit/s | 接收 Mbit/s | Retr | 服务端监听 | decap / LRO / ft / MTU | 原始日志 | 结论 |
|---|---|---|---|---|---|---|---|---|---|
| A | 原始 IP 入向（无 PPPoE，控制） | `iperf3 -c SERVER -p PORT -t 60 -P 4 -R -J` |  |  |  |  |  |  |  |
| B | PPPoE 入向，当前默认 | `iperf3 -c SERVER -p PORT -t 60 -P 4 -R -J` |  |  |  |  |  |  |  |
| C | PPPoE 入向，`ppe/pppoe_decap=0` | 同上，先写 0 并回读 |  |  |  |  |  |  |  |
| D | PPPoE 入向，`ppe/pppoe_decap=3`（#81，实验档） | 同上，先写 3 并回读 |  |  |  |  |  |  |  |

表内不填任何数字。数字只从当次原始 JSON 里抄，抄完在“原始日志”列写文件名。

**入向必须用 `-R`。** 只跑发送方向会把 PPPoE push 与 decap 混在一起；#30 要判的是
**decap 入向**，所以四个 arm 都用 `-R`。发送方向（无 `-R`）另开一组，不混进本表。

## 4. 每一臂的执行顺序

```sh
# 0) 服务端（LAN 侧）启动，单次
iperf3 -s -1 -p 5201

# 1) 本机检查服务端监听；失败则本臂无效
ss -ltnp | grep :5201

# 2) 记录本臂环境到 env-<arm>.txt（见第 1 节）

# 3) 跑测量，原始 JSON 落盘，文件名带 arm/时间/配置
iperf3 -c "$SERVER" -p 5201 -t 60 -P 4 -R -J \
  > "raw-${ARM}-$(date -u +%Y%m%dT%H%M%SZ)-decap${DECAP}-lro${LRO}.json" \
  2> "raw-${ARM}-....err"

# 4) 从原始 JSON 抄 sender/receiver/retr，不抄 SUM 一行就完事
python3 - <<'PY'
import json, glob
p = sorted(glob.glob("raw-*.json"))[-1]
d = json.load(open(p))
for s in d["end"]["streams"]:
    print(s["sender"]["bits_per_second"]/1e6, s["receiver"]["bits_per_second"]/1e6,
          s.get("sender", {}).get("retransmits"))
print("sum_receiver_mbps", d["end"]["sum_received"]["bits_per_second"]/1e6)
PY
```

原始输出必须留在磁盘上（默认 `research/lead/triage/offline/wan-raw/` 或实验目录），
报告里引用时写“文件名 + 行号/字段”，不要只写一个四舍五入后的数字。

## 5. 失败、回滚与作废

以下任一情况，本臂作废并记录原因；不要“再跑一次取好看的”：

- `ss -ltnp | grep :PORT` 无输出（服务端没起）；
- 链路速率不是预期档位（1G 臂出现 2500/10000，或 10G 臂只有 1000）；
- 有 `retr` 但没记，或只记了 `SUM` 没记 sender/receiver；
- 实验后 `nft list flowtables` 与实验前不一致且未回滚；
- `ppe/pppoe_decap` 写入后回读不一致。

回滚（网络实验的最小集）：

```sh
# 实验前
mkdir -p /root/wan-exp-$(date -u +%Y%m%dT%H%M%SZ)
cp /etc/config/network /etc/config/firewall /root/wan-exp-*/
uci export network > /root/wan-exp-*/network.uci
nft list ruleset > /root/wan-exp-*/nft.before
ip -br addr > /root/wan-exp-*/ip.before

# 失败/结束后
cp /root/wan-exp-*/network /etc/config/network
cp /root/wan-exp-*/firewall /etc/config/firewall
/etc/init.d/network restart
/etc/init.d/firewall reload
nft list ruleset > /root/wan-exp-*/nft.after
```

`ppe/pppoe_decap` 若是脚本临时写入，必须由 `trap` 恢复原值；参考
`scripts/pppoe-decap-hw-bench.sh` 的 `KNOB_ORIG`/`trap` 处理。

## 6. 数字使用边界

- **5.77 Gbit/s 是 10G 环回/本机路径的数字，不是 1G 基线。** 1G 臂只能引用当次 1G 链路
  测得的数字；没有就当次测。
- **没有实测就不写 10G 容量结论。** 10G 臂没跑过，只能写 `UNVERIFIED` 和所需实验。
- 2340/2400/2450 Mbit/s 是 `lan10g` 上 MTU 1500 与 9000 的 A-B-A-B 记录，来自
  `docs/MTU-POLICY.md` 引用的本地非版本化研究树；它不是 WAN、不是 PPPoE、也不是 1G。
- 只报 `SUM` 会把双向/多流混成一个数；本协议要求 sender 与 receiver 同时在场，且注明方向。

## 7. 如何验证本文

```sh
# 文档存在，且包含关键约束
test -f docs/wan-measurement-protocol.md
grep -n 'ss -ltnp | grep :5201' docs/wan-measurement-protocol.md
grep -n -- '-R' docs/wan-measurement-protocol.md
grep -n '5.77' docs/wan-measurement-protocol.md
grep -n 'UNVERIFIED' docs/wan-measurement-protocol.md

# 四臂表头存在且没有填数字
sed -n '/| Arm | 路径 |/,/^$/p' docs/wan-measurement-protocol.md
```

预期：三条 `grep` 均命中；表格行只有表头与空单元格，不含 `Mbit/s` 数值。
