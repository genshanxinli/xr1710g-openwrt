# WAN 测量协议

**状态**：协议文档（doc-only），没有产生任何新测量。
**适用**：XR1710G WAN 路径（1G / 2.5G / 10G、PPPoE、LRO、PPE 流表）的吞吐与 CPU 成本对比。
**关联**：#30、#26、#44、#70、#85、#86、#90、#102。

**本机边界（先读）**：这台 XR1710G 当前**没有 PPPoE peer**（无 `pppd` 进程、无 `ppp*` 网络设备、
`/etc/config/network` 无 `pppoe` 段），`wan` 是 `NO-CARRIER`（`speed` 读作 `-1`、`ethtool`
`Speed: Unknown!`），即**也没有 2.5G/10G 对端**；唯一 up 的以太口是 `lan4` 1 Gbit/s。
实测证据与逐条标注见 [`docs/wan-ppe-pppoe-findings.md`](wan-ppe-pppoe-findings.md) 第 0 节。
所以第 3 节的 B/C/D 三臂**在这台机器上无法执行**，只能写 `BLOCKED`；本节其余规则与硬件无关。

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

2. 路由器侧先确认 WAN 设备与链路速率，不接受“口插上了”作为证据。注意本机是 busybox `ip`，
   **不接受 `-br`/`-d`**（实测 `ip -br link show wan` 直接打 usage、退出码 1），写成不带 `-br`：

   ```sh
   ip link show wan                      # 看 NO-CARRIER / state
   cat /sys/class/net/wan/speed          # 无 carrier 时读作 -1，不是 0
   ethtool wan | sed -n '/Speed:/p'      # 无 carrier 时是 "Unknown!"
   ```

3. 每个 arm 开始前，在 **iperf3 服务端** 检查监听。服务端没在监听，这一臂直接判无效，
   不进入统计。命令按服务端在哪台机器选，见下面 1.4 —— **不要无条件抄 `ss`**：

   ```sh
   # 服务端是普通 Linux 主机
   ssh "$SERVER" "ss -ltn | grep -q ':5201'"

   # 服务端是这台路由器（镜像里没有 ss）
   ssh root@192.168.1.1 "netstat -ltn | grep -q ':5201'"
   ```

4. 记录本臂的完整环境，缺一项就标 `UNVERIFIED`：

   | 项 | 取值来源 |
   |---|---|
   | WAN 设备与驱动 | `ip link show wan`（busybox `ip` 不收 `-br`）、`ethtool -i wan` |
   | 链路速率/双工 | `cat /sys/class/net/wan/speed`、`ethtool wan` |
   | MTU | `cat /sys/class/net/wan/mtu`（PPPoE 同时记 `pppoe-wan`） |
   | `ppe/pppoe_decap` | `cat /sys/kernel/debug/ppe/pppoe_decap`（不存在就写 `absent`） |
   | `force_lro` / `rx-lro` | `ethtool -k wan \| grep -E 'large-receive-offload'` |
   | flowtable 设备 | `nft list flowtables` |
   | PPE 绑定条目 | `grep -c ' BND ' /sys/kernel/debug/ppe/entries`（只读） |
   | CPU/IRQ | `mpstat -P ALL 1 1`、`grep -E 'qdma\|eth' /proc/interrupts` |

### 1.4 监听断言：本机没有 `ss`

实测（本次，`ssh root@192.168.1.1 'command -v ss || echo NO_SS'`）：

```
NO_SS
```

同一台机器 `command -v iperf3` 也无输出 —— 设备侧的 `iperf3` 是侧载 APK，重启后要重装
（`docs/perf/ppe-wired-baseline.md` 的 iperf3 一行）。所以“`ss -ltnp`”这条断言只在这些场合成立：
服务端是一台有 iproute2 的 Linux 主机，或另一台带 `ss` 的盒子。**把 `ss` 当通用写法，
在被测设备上跑就是错的** —— 它会把一个正常监听的臂判无效，或者反过来，一个没监听的臂
因为断言命令本身“找不到命令”而被当成“有输出”放过。

按服务端位置选命令：

| 服务端在哪 | 断言命令 |
|---|---|
| 这台路由器（OpenWrt 镜像） | `ssh root@192.168.1.1 "netstat -ltn \| grep -q ':PORT'"` |
| 一台普通 Linux 主机 | `ssh "$SERVER" "ss -ltn \| grep -q ':PORT'"`（`-p` 需要 root，`-ltn` 够用） |
| 就在当前 shell 的机器上 | 用下面的 `listen_check` 函数，并 25 × `sleep 1` 轮询 |

本机 `netstat` 实测输出（读的是本机 22/80/53，`-ltnp` 能出 PID/Program 列，模式与看 5201 时相同）：

```
Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name    
tcp        0      0 0.0.0.0:22              0.0.0.0:*               LISTEN      1924/dropbear
tcp        0      0 0.0.0.0:80              0.0.0.0:*               LISTEN      2560/uhttpd
tcp        0      0 127.0.0.1:53            0.0.0.0:*               LISTEN      3583/dnsmasq
```

可直接复制，两个分支只用一个：

```sh
# 1) 服务端在路由器上
ssh root@192.168.1.1 "netstat -ltn | grep -q ':$PORT'" && echo LISTENING || echo NOT_LISTENING

# 2) 服务端在普通 Linux 主机上
ssh "$SERVER" "ss -ltn | grep -q ':$PORT'" && echo LISTENING || echo NOT_LISTENING

# 3) 服务端就在本机：等到监听，或 25 s 后作废
listen_check() {   # $1 = port，只有端口真的在 LISTEN 才返回 0
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -q ":$1"
  else
    netstat -ltn 2>/dev/null | grep -q ":$1"
  fi
}
```

三条纪律：

1. **必须 `grep -q ':PORT'` 看退出码。** 只跑 `netstat -ltnp` 永远有表头输出，那不是断言。
2. **把这次的退出码写进结果文件**，不要写“脚本保证 peer 在监听” —— 断言的是你这次看到的东西。
3. 设备上 `sleep` 不接受小数（`sleep 0.5` 报错），轮询用 `sleep 1`；主机上才用 `sleep 0.2`。

### 1.5 仓库脚本的现状（这是缺口，不是协议）

| 位置 | 监听断言 | 说明 |
|---|---|---|
| `scripts/bench-10g-unidirectional.sh:99-103` | **没有** | 帮助文本只写 “The peer must have "iperf3 -s" listening; it is not started by this harness.”，脚本里没有 `ss`/`netstat`/端口探测。用它跑之前，必须在本机手工执行 1.4 的断言并把退出码记进 `RESULT_DIR` |
| `tools/wan-bench/2.5g.sh:156`、`:167` | `ssh PEER 'ss -ltnp \| grep :PORT'` | peer 是普通 Linux 主机时成立；peer 若是路由器（无 `ss`），这条断言恒失败，正常臂会被判无效 —— 换 `netstat -ltn` |
| `docs/wan-2.5g-gate.md:59` | 同一句 `ss -ltnp` | 同上 |

三处都还没有改代码，本文件只记录缺口；改脚本是单独一次改动，不要在同一臂里顺手改。

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

本机实测（本次）：`ls /sys/kernel/debug/ppe/` 只有 `6rd bind bind_rate dslite entries entry_alias flush
mcast meter ppe1_regs tb_regs tpid unbind_age usage`，**没有 `pppoe_decap`**，`cat` 报
`No such file or directory`。所以在这台机器上 C/D 连开关都不存在（写 `BLOCKED`），
B 没有 PPPoE peer（见开头“本机边界”），只有 A 能在 `lan4` 1G 本地终结的意义上执行。

表内不填任何数字。数字只从当次原始 JSON 里抄，抄完在“原始日志”列写文件名。

**入向必须用 `-R`。** 只跑发送方向会把 PPPoE push 与 decap 混在一起；#30 要判的是
**decap 入向**，所以四个 arm 都用 `-R`。发送方向（无 `-R`）另开一组，不混进本表。

## 4. 每一臂的执行顺序

```sh
# 0) 服务端（LAN 侧）启动，单次
iperf3 -s -1 -p 5201

# 1) 检查服务端监听；失败则本臂无效（命令按服务端位置选，见 1.4）
ssh root@192.168.1.1 "netstat -ltn | grep -q ':5201'" \
  || { echo "arm invalid: no listener on 5201" >&2; exit 1; }
# 服务端是普通 Linux 主机时换成：
# ssh "$SERVER" "ss -ltn | grep -q ':5201'"

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

- 监听断言退出码非 0（服务端没起）。断言命令按服务端位置选：路由器上用 `netstat -ltn | grep -q ':PORT'`，普通 Linux 主机上用 `ss -ltn`，见 1.4；
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
ip addr > /root/wan-exp-*/ip.before          # 本机 busybox ip 不收 -br

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
grep -n 'NO_SS' docs/wan-measurement-protocol.md
grep -n 'netstat -ltn | grep -q' docs/wan-measurement-protocol.md
grep -n 'bench-10g-unidirectional.sh:99-103' docs/wan-measurement-protocol.md
grep -n -- '-R' docs/wan-measurement-protocol.md
grep -n '5.77' docs/wan-measurement-protocol.md
grep -n 'UNVERIFIED' docs/wan-measurement-protocol.md
# 不应再出现“无条件用 ss”的写法（1.4/1.5 提到 ss 都带条件）
grep -n '^ss -ltnp' docs/wan-measurement-protocol.md && echo "FAIL: ss 仍被当作通用写法"

# 四臂表头存在且没有填数字
sed -n '/| Arm | 路径 |/,/^$/p' docs/wan-measurement-protocol.md
```

预期：前 7 条 `grep` 均命中；最后一条**不应**命中（命中说明又出现了把 `ss` 当通用写法的段落）；四臂表只有表头与空单元格，不含 `Mbit/s` 数值。
