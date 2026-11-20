# WAN PPE / PPPoE 已核实事实与未知项

**状态**：doc-only。除了标注为“本次实测”的只读探针，以及第 2 节一次**可回滚的 debugfs 写测试**
（`ppe/unbind_age`，已恢复原值并回读确认），本文没有产生任何新测量。
**适用**：XR1710G（`airoha/an7581`，内核 7.3）上的 PPE 流表、PPPoE 入向、桥内 L2 转发。
**关联**：#31、#30、#81、#26、#13、#90。
**配套**：[`docs/wan-measurement-protocol.md`](wan-measurement-protocol.md)（怎么测才算数）、
[`docs/perf/ppe-wired-baseline.md`](perf/ppe-wired-baseline.md)（30 窗纯有线 1G 基线）。

每条事实都带 **等级**（`实测` / `代码` / `推断`）和 **证据路径或 `file:line`**。
本仓库没有 `docs/README.md` 这类文档索引（`ls docs/` 只有各专题文件），所以本文与协议文档
互相链接，不另造一层结构。

## 0. 本机边界：没有 PPPoE，也没有 2.5G 对端

**先把这条读明白，再去看任何数字。** 下面所有 PPPoE 结论都是**代码层面**的：这台机器上
从来没有任何 PPPoE 流绑定进 PPE，所以任何“PPPoE 入向吞吐”“decap 收益”数字都不存在。

| 结论 | 等级 | 证据 |
|---|---|---|
| 板子上没有 PPPoE peer：无 `pppd` 进程、无 `ppp*` 网络设备、`/etc/config/network` 里没有 `pppoe` 段 | 实测 | `ps \| grep -i ppp` 只回显 `ash -c` 与 `grep` 自身；`ls /sys/class/net \| grep -i ppp` → `none`；`grep -in pppoe /etc/config/network` → 无输出 |
| `wan` 无 carrier，因此也没有 2.5G/10G 对端 | 实测 | `ip link show`：`3: wan: <NO-CARRIER,BROADCAST,MULTICAST,UP> ... state DOWN`；`cat /sys/class/net/wan/speed` → `-1`；`ethtool wan` → `Speed: Unknown!`、`Link detected: no` |
| 唯一 up 的以太口是 `lan4` 1 Gbit/s | 实测 | `6: lan4@cpu: <BROADCAST,MULTICAST,UP,LOWER_UP> ... state UP`；`cat /sys/class/net/lan4/speed` → `1000`；`ethtool lan4` → `Speed: 1000Mb/s`、`Duplex: Full` |
| 没有 PPPoE 的后果：PPE 里既没有绑定条目，也没有分到 L2 流 | 实测 | `usage` 打印 `bound 0 (0%) unbound 0` / `l2b_bound 0 l2_flows_sw 0`；`wc -l ppe/entries` → `0` |
| 本镜像连 `ppe/pppoe_decap` 这个节点都不存在（#81 的开关尚未实现） | 实测 | `ls /sys/kernel/debug/ppe/` 只有 `6rd bind bind_rate dslite entries entry_alias flush mcast meter ppe1_regs tb_regs tpid unbind_age usage`；`cat ppe/pppoe_decap` → `can't open ...: No such file or directory` |

本次探针的原始输出（可原样重跑）：

```
$ ssh root@192.168.1.1 'cat /sys/kernel/debug/ppe/usage; echo ---; cat /sys/kernel/debug/ppe/unbind_age; echo ---; head -3 /sys/kernel/debug/ppe/ppe1_regs; echo ---; cat /sys/module/airoha_eth/parameters/bridged_force; echo ---; command -v ss || echo NO_SS; netstat -ltnp 2>/dev/null | head -5'
entries 32768 (sram 16384, dram 16384)
bound 0 (0%) unbound 0
l2b_bound 0 l2_flows_sw 0
ipv4_capacity 32768 (sram 16384, dram 16384)
ipv4_bound 0 ipv4_bound_pct 0
---
PPE1 min_pkts=0 delta=0 raw=00000000
PPE2 min_pkts=0 delta=0 raw=00000000
---
00 0x0e00 0006070f
01 0x0e04 00000000
02 0x0e08 00000000
---
-1
---
NO_SS
Active Internet connections (only servers)
Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name    
tcp        0      0 0.0.0.0:22              0.0.0.0:*               LISTEN      1924/dropbear
tcp        0      0 0.0.0.0:80              0.0.0.0:*               LISTEN      2560/uhttpd
tcp        0      0 127.0.0.1:53            0.0.0.0:*               LISTEN      3583/dnsmasq
```

环境：`Linux OpenWrt 7.3 #0 SMP PREEMPT Fri Nov 20 04:04:01 2026 aarch64 GNU/Linux`，
`DISTRIB_RELEASE='SNAPSHOT'`、`DISTRIB_TARGET='airoha/an7581'`、`DISTRIB_TAINTS='no-all'`（实测）。
注意这份镜像**没有 `ss`、没有 `iperf3`**（`command -v ss` → `NO_SS`，`command -v iperf3` → 无输出；
`iperf3` 是侧载 APK，重启即失效），所以测量协议里那条监听断言必须走 `netstat`，
见 `docs/wan-measurement-protocol.md` 第 1.4 节。

## 1. PPE 整机表几何

| 结论 | 等级 | 证据 |
|---|---|---|
| 本机 `ppe/usage` 打印 `entries 32768 (sram 16384, dram 16384)`，`ipv4_capacity` 同样 32768 | 实测 | 上面 `usage` 原始输出；`entries` 是 hash 空间 = 驱动数组大小，不是 IPv4 可用槽数 |
| 目标配置写了 `CONFIG_NET_AIROHA_FLOW_STATS=y` | 代码 | `target/linux/airoha/an7581/config-7.3:279` |
| 当 NPU 真的收下流计数器时，每颗 PPE 的 SRAM 表只剩 4096 项，整机 = 4096×2 + 16384 = **24576** | 代码 | `target/linux/airoha/patches-7.3/209-net-airoha-size-the-SRAM-tables-the-way-the-hardware-sees-them.patch:36-38`（原文 “`airoha_ppe_get_total_num_entries()` reports 32768 where the hardware has 4096 * 2 + 16384 == 24576”） |
| 计数器没被接受时，那次 carve-out 被跳过，SRAM 保留 16384，整机就是 **32768** | 代码 | `target/linux/airoha/patches-7.3/214-net-airoha-stop-paying-for-unused-flow-counters.patch:83`（`if (num_stats > 0 && !ppe->foe_stats_enabled) return -EOPNOTSUPP;`） |
| 上面两种几何**打印同一行** `entries`，这正是 209 与 usage 输出看似矛盾的原因 | 代码 | `target/linux/airoha/patches-7.3/9999-net-airoha-report-the-derived-IPv4-capacity-in-ppe-usage.patch:7-11`（“Both cases print the same `entries` line”）；该补丁只在旁边加了 `ipv4_capacity` 行，没有改 `entries` |
| 本机 `sram` 读作 16384 ⇒ 本次启动的 carve-out **没有生效** ⇒ NPU 没有收下计数器 | 推断 | 由上两条 + `usage` 的 `sram 16384`。这条是推断：`dmesg \| grep -iE "ppe\|npu"` 在本镜像上无输出，没拿到 “NPU refused flow stats” 那行（`199-...patch:153` 的 `dev_warn`），无法直接确证 |

结论：**32768 与 24576 不是互相打脸的两个人，是同一次启动的两种分支。** 写文档/引用时
必须说明是哪一支：本机这次是 32768（SRAM 未被切走）。

`usage` 里的 `entries` 不能直接当 IPv4 容量：按
`9999-net-airoha-report-the-derived-IPv4-capacity-in-ppe-usage.patch:9-14`，它在计数器生效时
应为 24576；本机打印的 `ipv4_capacity 32768` 与 `entries` 同值，是因为这次没有 carve-out，
不是“IPv4 能用 32768 个槽”的普适结论。

**不是 49152。** 32768 = SRAM 16384 + DRAM 16384（两块共享同一个 hash 空间、不是相加的两个独立表）；
`ppe-table-32768` 在 `scripts/claims.yaml:45` 记为 `refuted`，理由是“对目标配置不成立”，
那条 refuted 针对的是 `FLOW_STATS=y` 且 NPU 接受了计数器的那一支 —— 与本机这次实测的 32768 不冲突，
两者差在 `foe_stats_enabled`。

## 2. `ppe/unbind_age`：两字段写、先校验后写

**接口形态（代码）**

| 结论 | 等级 | 证据 |
|---|---|---|
| 节点 `ppe/unbind_age` 权限 `0644`，读 “每颗 PPE 一行 `min_pkts=<u> delta=<u> raw=<hex>`”，写 `"<min_pkts> <delta>"` | 代码 | `target/linux/airoha/patches-7.3/9999-net-airoha-set-the-PPE-unbind-age-at-runtime.patch:6-8`、`:38-52`（show）、`:57-104`（write） |
| 两个字段**都必须给**：`sscanf(buf, "%u %u", ...) != 2` 就 `-EINVAL`，目的是不留下“半个寄存器被改”的状态 | 代码 | 同文件 `:75-81` |
| 范围检查在**第一次写之前**完成：`min_pkts > FIELD_MAX(...)` 或 `delta > FIELD_MAX(...)` → `-ERANGE`，两颗 PPE 都不会被改 | 代码 | 同文件 `:86-88`（注释在 `:12-14`：“an out-of-range request cannot land on one PPE and be refused on the next”） |
| 字段宽度：`MIN_PACKETS` = `GENMASK(31, 16)`（上限 65535），`DELTA` = `GENMASK(7, 0)`（上限 255） | 代码 | `drivers/net/ethernet/airoha/airoha_regs.h:324-325`（本树里的这一行来自内核树，见下注） |
| 写完后逐颗 PPE 回读，任一颗不等于请求值就 `-EIO`（硬件不实现的字段不能被当成“写成功”） | 代码 | `9999-...-unbind-age-at-runtime.patch:96-104` |

> `airoha_regs.h` 不在本仓库里：它是内核头文件，本树通过 `target/linux/airoha/patches-*`
> 补丁改它。行号取自本次构建树
> `build_dir/target-aarch64_cortex-a53_musl/linux-airoha_an7581/linux-7.3/drivers/net/ethernet/airoha/airoha_regs.h`，
> 与该镜像 `xr1710g` 基线一致（`a86ce12e27`）。

**写测试（本次实测，写完全部恢复并回读）**

在 `ssh root@192.168.1.1` 上依次执行；`N=/sys/kernel/debug/ppe/unbind_age`：

```
== original ==                                   PPE1 min_pkts=0 delta=0 raw=00000000 / PPE2 同
echo "200 5" > $N      → rc=0                    PPE1 min_pkts=200 delta=5 raw=00c80005 / PPE2 同
echo "200"   > $N      → rc=1  ash: write error: Invalid argument
                                                 值仍是 min_pkts=200 delta=5（没被动过）
echo "65536 5" > $N    → rc=1                    值仍是 min_pkts=200 delta=5，错误串未打印
echo "200 256" > $N    → rc=1  ash: write error: Result not representable（打印两次）
                                                 值仍是 min_pkts=200 delta=5
echo "0 0" > $N        → rc=0                    PPE1 min_pkts=0 delta=0 raw=00000000 / PPE2 同
```

对照代码可以确认两条错误串分属哪一支：`Invalid argument` = `-EINVAL`（字段数不对），
`Result not representable` = `-ERANGE`（超范围）。原值与恢复后的值都是 `raw=00000000`，
`tb_regs` 也回到 `PPE1 unbind_age 00000000 min_pkts 0 delta 0`（实测，恢复后复查）。

**这条实测能证明什么、不能证明什么**

- 能：两字段写生效（两颗 PPE 同时变）；单字段被拒且**旧值保留**；超范围被拒且**旧值保留**；
  `min_pkts` 上限 65535、`delta` 上限 255 与 `airoha_regs.h:324-325` 的掩码一致（65536 与 256 都被拒）。
- 不能：不能当“调大/调小 unbind_age 会改变转发行为”的证据 —— 本机 `bound 0`，没有流被老化过。
  要判老化收益必须有一条**已绑定**的流（见第 6 节未知项）。
- 写入只在本次启动有效（内核不持久化），重启回到硬复位值 `00000000`。

## 3. `ppe/ppe1_regs` 是 PPE1 寄存器窗口，不是 L2B 表

| 结论 | 等级 | 证据 |
|---|---|---|
| `FE` 基址下 `PPE1_BASE` = `0x0c00`、`PPE2_BASE` = `0x1c00` | 代码 | `airoha_regs.h:17`、`:18` |
| `REG_PPE_GLO_CFG(_n)` = `PPE1_BASE + 0x200`（n=0）→ 窗口起点 `0x0e00` | 代码 | `airoha_regs.h:263` |
| `ppe/ppe1_regs` 读的就是 `AIROHA_PPE1_REGS_BASE = PPE1_BASE + 0x200`，共 64 个 32-bit 字，`0444` 只读 | 代码 | `target/linux/airoha/patches-7.3/9999-net-airoha-rename-ppe-l2b-to-ppe1-regs.patch:5`（“That address is PPE1_BASE + 0x200”）、`:75`（`#define AIROHA_PPE1_REGS_BASE (PPE1_BASE + 0x200)`）、`:76` |
| 它**不是**一张独立的 L2B 表：窗口里的字段就是 `tb_regs` 逐个点名读的同一批寄存器（`glo_cfg` +0x00、`tb_cfg` +0x1c、`bind_rate` +0x28、`unbind_age` +0x38、`hash_seed` +0x44 …） | 代码 | 同文件 `:52`（“this window is the same one tb_regs reads a register at a time”）；旧名 `l2b` 与 “L2B ethertype table” 的解码是猜的，已被删掉 |
| 本机输出 64 行、第一行 `00 0x0e00 0006070f`（= `PPE1_BASE+0x200` 的 `glo_cfg`），文件权限 `-r--r--r--` | 实测 | `head -3 ppe1_regs` 与 `wc -l` → `64`；`ls -l ppe1_regs` |
| 窗口末尾两行读作 `deadbeef`，即 FE 对未实现字的读回哨兵，不是寄存器数据 | 实测 | `tail -2 ppe1_regs` → `62 0x0ef8 deadbeef` / `63 0x0efc deadbeef`。**推断**（同一条事实的另一半）：`deadbeef` 是“该地址无实现”的标记，不要把它当有效值写进结论 |
| 不要把这块窗口和 NPU 自己的 `0x1e900000..0x1ebfffff` 混起来：从 A53 读那个窗口会挂住 SoC | 代码 | `9999-...-rename-ppe-l2b-to-ppe1-regs.patch:62-64`；设备操作里同一条禁令 |

## 4. PPPoE 与桥内 L2：代码层面已成立的部分

| 结论 | 等级 | 证据 |
|---|---|---|
| 同一个 bridge 的两个端口之间转发的流是 L2 转发，**必须保持 IP TTL**；PPE 只在这类流上清 `IB1.BIND_TTL`，routed 流照旧递减 | 代码 | `target/linux/airoha/patches-7.3/963-net-airoha-keep-TTL-on-flows-bridged-within-one-bridge.patch:5-6`、`:20` |
| 修复前在真机上量到过 TTL 递减：`lan2` 进 TTL 5、`phy0.0-ap0` 出 TTL 4 | 实测（补丁作者记录，**非本次**） | 同文件 `:15-16`。本次未复现，也没法复现（本机没有能在两个端口间转发的 L2 路径） |
| 上述修复只覆盖**已绑定 PPE** 的硬件路径；未绑定流仍由软件 `nf_flow_offload_ipv4_forward()` 的 `ip_decrease_ttl()` 递减 | 代码 | 同文件 `:23-25` |
| 判“是否桥内转发”的正解是 nft 给出的 `is_bridging` 信号（`flow_offload_tuple.bridge_input` → `flow_cls_offload.bridge_input`），不是比较 bridge master | 代码 | `target/linux/airoha/patches-7.3/999-net-airoha-carry-the-nft-l2-bridged-signal.patch:5-14` |
| `bridged_force` 模块参数：`-1`（默认）= 用内核信号，`0` = 强制 routed（递减 TTL），`1` = 强制 L2-bridged（不减 TTL） | 代码 | 同文件 `:21-23`；`static int airoha_ppe_bridged_force = -1;` 在 `:48`，`module_param_named(bridged_force, ..., int, 0644)` 在 `:49`，使用在 `:83-84` |
| 本机 `bridged_force` 读作 `-1`，即走内核信号，没有被人为覆盖 | 实测 | `cat /sys/module/airoha_eth/parameters/bridged_force` → `-1` |
| `airoha-eth` 是 built-in（`CONFIG_NET_AIROHA=y`），所以 `bridged_force` 只在**编译期**存在：换值要重编/刷机；刷好之后运行态 A/B 不再需要刷机 | 代码 | `999-...patch:30-32`；`config-7.3:278` 的 `CONFIG_NET_AIROHA=y` |
| 该补丁自述“只做过编译与打补丁验证”，TTL 位的硬件 A/B 是后续工作 | 代码（补丁自述） | `999-...patch:33-35`。本次**未验证**，本机没有桥内转发路径 |
| 桥键被替换时，旧 L2 条目（连同它挂着的子流）以前会泄漏：`rhashtable_replace_fast()` 只重挂链、不释放被替换的对象，且 flow table params 没有 `obj_free` | 代码 | `target/linux/airoha/patches-7.3/962-net-airoha-free-the-L2-entry-a-key-replacement-displaces.patch:9-13` |
| 修复同时把“检查+插入”收回 `ppe_lock` 之内，避免两个 commit 都看到“无条目”再各自插入 | 代码 | 同文件 `:25-27` |
| 本机 `l2b_bound 0` / `l2_flows_sw 0`：软件侧从未下发过 L2 流，不是“下发了被硬件丢” | 实测（数值）/ 推断（解释） | `usage` 输出 + `entries` 为 0 行。解释部分：没有跨 bridge 的转发路径，所以没有可下发的对象；`pnf_flow_table` 只在 `FORWARD` 跳上卸载，本机 iperf3 是本地终结（见 `docs/perf/ppe-wired-baseline.md` 拓扑节） |

## 5. issue #31 正文里、本仓库没有入库证据的断言

issue #31 除上面这些，还列了几条。它们在本仓库里只有“claim”没有“measurement”，
引用时必须带等级，不要当成 `实测`：

| 断言（issue #31 原文要点） | 本仓库证据状态 | 处置 |
|---|---|---|
| PPPoE 入向最小集 = 5T/route 键 + `STATE=2` + TTL + `IB1 bit23`；`etype=8864` / bit22 / `pppoe_id` 不是必需（b12 三臂） | `scripts/claims.yaml:158-166` 记 `evidence: 推断`、`unverified`，notes 明写“b12 三臂实验原始记录未入库”；`docs/` 里没有那份记录 | 保留为 `推断`。`docs/wan-productization.md:46` 也写着 #81 的 `9904-...-psn.patch` 不在树里 → 默认 decap 语义仍未落地 |
| `decap=0` 时没有 bit23、没有硬件 decap；`decap=1` 才有 | 同上（同一条 claim） | 保留为 `推断`；**本机无 `ppe/pppoe_decap` 节点**（实测，见第 0 节），三臂根本跑不了 |
| `l2b_bound=0` 是软件从未下发 L2 流，不是 CRSN `0x0f` 丢弃；CRSN `0x0f` 落 Q0 | 只有 issue 正文；仓库里没有 `CRSN 0x0f` 的寄存器/抓包记录 | 标 `推断`，未验证 |
| NPU 不在以太网↔以太网数据面；PPE↔NPU 只在控制面（init/commit/flush mbox） | 代码可查（`npu->ops.ppe_init_stats` / `ppe_commit` 等 mbox 调用），但没有“数据面不经 NPU”的实测抓包 | `代码`（控制面调用存在）+ `推断`（数据面不走 NPU） |

## 6. 未知项：每条写成问题 + 收口所需的观察

1. **本机到底是 24576 还是 32768？** 已知 `usage` 打印 32768、`sram 16384`，但没拿到
   “NPU refused flow stats” 的 dmesg 行。收口：让 NPU 收下计数器（或打印一行
   `foe_stats_enabled`），再看 `ppe/usage` 的 `sram` 是否变 8192；另一个独立算法是把
   `ppe/tb_regs` 的 `tb_cfg`（本机 `80c0f000`）按 `REG_PPE_TB_CFG` 的 SRAM/DRAM 字段解出来，
   与 `entries` 行对照。**这条没做，别把 24576 写成本机事实。**
2. **PPPoE 入向到底需要哪些命中位？** 需要一台真有 PPPoE peer 的板子：跑一组
   `bound` 从 0 变非 0 的窗口，再逐位改 `IB1`（bit23 / bit22 / `pppoe_id`）看 `bound` 是否掉。
   本机做不了（无 peer，见第 0 节）。
3. **`ppe/pppoe_decap` 该是什么语义（decap 0/1/2/3）？** 现在节点不存在，
   `scripts/pppoe-decap-hw-bench.sh` 引用的路径在本镜像上没有创建代码。
   收口：先落 #81 的补丁，再 `ls`/`cat` 那个节点确认存在，然后才谈 A/B。
4. **`bridged_force` 的 TTL 位在真机上真的按信号生效吗？** 补丁只做过编译验证。
   收口：一条桥内 L2 转发（TTL 5 进、TTL 5 出）+ 一条 routed 转发（TTL 5 进、TTL 4 出），
   同时看 `ppe/entries` 里对应条目的 `ib1` `BIND_TTL` 位；`bridged_force` 0/1 各跑一次做 A/B。
5. **`unbind_age` 改变真的会影响老化吗？** 本机 `bound 0`，写多少都不老化任何东西。
   收口：先有一条已绑定的流，再写 `200 5` 与 `0 0` 各一段，观察 `entries` 里该条目的
   `age` 字段增长与 `unbound` 计数变化。
6. **`l2b_bound` 恒 0 的解释对吗？** 收口：造一条跨 bridge 的 L2 卸载流，看 `l2_flows_sw`
   是否从 0 变正；若仍为 0，则“软件从未下发”的解释被推翻，需要查 `foe_l2_flow_commit_entry()`
   的调用路径。
7. **PPPoE over VLAN 的 `vlan_pop` 行为**、**GDM4 10G TX 静默丢包**、**LRO 与 PPE 是否互斥**：
   仓库里都只有 issue 描述，没有落盘实验。收口方式分别是：PPPoE-over-VLAN 需要 VLAN 标签
   的 PPPoE peer 与 `ppe/entries` 里 `vlan_pop` 位观察；GDM4 需要 10G 对端 + `ethtool -S` 与
   `ppe/usage` 双侧计数；LRO/PPE 需要同一流上开/关 `rx-lro` 看 `bound` 与吞吐。
   本机 `wan` 无 carrier，三条都做不了（实测，第 0 节）。

## 7. 数字使用边界

- 本文除第 0 节的只读输出和第 2 节的写测试，**没有一个吞吐数字**。别把本文当基线。
- `bound 0` / `l2b_bound 0` / `l2_flows_sw 0` / `entries` 0 行是**本机这次**的观察，
  不能推广成“这块硬件从不卸载”——它只说明这次没有可卸载的对象。
- `5.77 Gbit/s`、`2340/2400/2450 Mbit/s`、`941 Mbit/s` 都不是本文的产物，
  出处与用法见 `docs/wan-measurement-protocol.md` 第 6 节与
  `docs/wan-productization.md:107-108`（后者把 G1/G2 明确标成 `UNVERIFIED`）。

## 8. 如何验证本文

```sh
# 文档存在
test -f docs/wan-ppe-pppoe-findings.md

# 每条事实都必须带等级 + 证据，抽查几个关键词
grep -n '实测' docs/wan-ppe-pppoe-findings.md | head -3
grep -n 'airoha_regs.h:17' docs/wan-ppe-pppoe-findings.md
grep -n 'airoha_regs.h:263' docs/wan-ppe-pppoe-findings.md
grep -n 'config-7.3:279' docs/wan-ppe-pppoe-findings.md
grep -n 'bridged_force' docs/wan-ppe-pppoe-findings.md | head -3
grep -n 'No such file or directory' docs/wan-ppe-pppoe-findings.md

# 本机边界必须在前 60 行内出现
sed -n '1,60p' docs/wan-ppe-pppoe-findings.md | grep -n '没有 PPPoE'
```

预期：全部命中；第 0 节在第一屏内，读者不会先读到数字再读边界。
