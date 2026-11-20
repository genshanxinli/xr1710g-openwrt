# 6.18 与 7.3 的 airoha 补丁对齐盘点

出厂内核是 6.18（`target/linux/airoha/Makefile: KERNEL_PATCHVER:=6.18`，an7583 子目标只编 6.18），
但本仓自己维护的 airoha 系列补丁只在 `patches-7.3/` 里生长。结果是：**面向 7.3 写的驱动修复，
出货镜像里一条都没有**，an7583 只能靠 675-02 这类点在 generic 面上的补丁修修补补。

本文把 `patches-7.3/` 的 108 个补丁逐个对照 `patches-6.18/`，列出缺口、判定能否直接搬、
不能直接搬的给出重生成路径，并把「直接可移」的部分在本分支落地。

## 结论速览

| 项目 | 数字 |
| --- | --- |
| `patches-7.3/` 补丁总数 | 108 |
| 其中 6.18 无对应文件（缺口） | **46** |
| 直接可移（本 PR 已落地） | **18** |
| 需重生成（本 PR 只给计划） | **25** |
| 不适用（6.18 已有等价实现） | **3** |
| 6.18 队列（落地前 → 落地后） | 659/0 → **677/0** |
| 7.3 队列（对照基线） | 333/0 |

`TOTAL applied=N bad=M` 是 `patch -p1` 全队列应用后的统计，`bad` 是 exit code 非零的补丁数。
两个基线都必须 `bad=0`，否则「apply 干净」这件事本身不成立。

## 方法

### 1. 缺口识别

`patches-6.18/*.patch` 与 `patches-7.3/*.patch` 的文件名先去掉 `-vX.Y-` 这类版本标记再比对，
文件名对不上时回退到 `Subject:` 行比对。108 个 7.3 补丁里有 46 个在 6.18 找不到对应文件。

只比 airoha 面。`generic` 的 backport-6.18 / pending-6.18 / hack-6.18（本树 489 个补丁）不在本文范围。

### 2. 位置探测（两个基线）

只做 `patch --dry-run` 会得出两个方向的错误结论，所以有两条基线：

- **基线 A「队列入口」**：干净 6.18.55 + generic 489 补丁，直接 `patch -p1 -F0 --dry-run`。
  这个基线会**低估**：很多 7.3 补丁的上下文来自 6.18 里已经存在、但排在它后面的补丁；
  还会出现 NOFILE 假象——`drivers/net/pcs/airoha/*`、`drivers/phy/airoha/phy-airoha-usb.c`
  这些文件是 airoha 补丁新建的，入口树里根本没有。
- **基线 B「队列位置」**：只把该补丁涉及的目标文件拷进临时目录，按 6.18 队列顺序把**排在它前面、
  且碰同一文件**的 6.18 补丁全部应用，然后 `-F0 --dry-run`。目标文件在入口树不存在时，
  从全量应用后的树上取。这是本文判定的主基线。

两个基线都要求 **零 fuzz**（`-F0`）。`-F2` 能过的补丁一律不算「直接可移」——fuzz 过的 hunk
意味着上下文已经对不上，只是补丁工具替人猜了位置。

### 3. 依赖检查

对每个补丁的 `+` 行抽函数调用与全大写宏/枚举名，扣掉补丁自己定义的符号，逐个在 6.18 全量树上找。
找不到的名字说明该补丁依赖的设施在 6.18 不存在——这类补丁即使 hunk 全过也不能算可移，
因为编不过。

### 4. 队列验证

落地之后必须重跑全队列：`apply-queue.sh` 按 generic → airoha 的顺序应用，任何一条 bad 都要回退。
本文所有队列数字都来自实际运行，不是推算。

## 完整盘点表

| # | 7.3 补丁 | 主题 | 触点 | 判定 |
| --- | --- | --- | --- | --- |
| 201 | `201-net-airoha-reject-a-HTB-leaf-that-cannot-shape-anything` | reject a HTB leaf that cannot shape anything | airoha_eth.c | 直接可移 ✅ |
| 202 | `202-net-airoha-report-the-frames-the-PSE-could-not-buffer` | report the frames the PSE could not buffer | airoha_eth.c/.h | 需重生成 |
| 204 | `204-net-airoha-expose-the-PSE-packet-buffer-in-debugfs` | expose the PSE packet buffer in debugfs | airoha_eth.c/.h | 直接可移 ✅ |
| 205 | `205-net-airoha-dump-bridge-entries-and-table-occupancy` | dump bridge entries and table occupancy | airoha_ppe_debugfs.c | 需重生成 |
| 206 | `206-net-airoha-say-why-GDM3-GDM4-QoS-is-refused-on-a-WAN-port` | say why GDM3/GDM4 QoS is refused on a WAN port | airoha_eth.c | 直接可移 ✅ |
| 207 | `207-net-airoha-do-not-report-absent-flow-counters-as-zero` | do not report absent flow counters as zero | airoha_ppe_debugfs.c | 直接可移 ✅ |
| 208 | `208-net-airoha-show-what-the-PSE-actually-reserved` | show what the PSE actually reserved | airoha_eth.c | 需重生成 |
| 209 | `209-net-airoha-size-the-SRAM-tables-the-way-the-hardware-sees-them` | size the SRAM tables the way the hardware sees them | airoha_ppe.c | 直接可移 ✅ |
| 210 | `210-net-airoha-do-not-alias-flow-counters-onto-unrelated-flows` | do not alias flow counters onto unrelated flows | airoha_ppe.c | 直接可移 ✅ |
| 211 | `211-net-airoha-assert-the-RX-bank-masks-do-not-overlap` | assert that the RX bank masks do not overlap | airoha_eth.c | 直接可移 ✅ |
| 212 | `212-net-airoha-address-PPE-entries-from-their-own-table` | address PPE entries from their own table, fold without udiv | airoha_ppe.c | 需重生成 |
| 213 | `213-net-airoha-report-how-the-entry-field-treats-a-large-index` | report how the entry field treats an out-of-range index | airoha_eth.h, airoha_ppe.c, _debugfs.c | 需重生成 |
| 214 | `214-net-airoha-stop-paying-for-unused-flow-counters` | stop paying for flow counters the NPU never provides | airoha_ppe.c | 需重生成 |
| 215 | `215-net-airoha-refuse-an-hfwd-ring-the-queue-cannot-hold` | refuse an HFWD ring the queue cannot hold | airoha_eth.c | 直接可移 ✅ |
| 216 | `216-net-airoha-reject-a-mismatched-channel-on-HTB-modify` | reject a mismatched channel on HTB modify too | airoha_eth.c | 直接可移 ✅ |
| 217 | `217-net-airoha-assert-the-RX-bank-mask-union` | assert the RX interrupt bank mask union | airoha_eth.c | 直接可移 ✅ |
| 600-11 | `600-11-clk-en7523-restore-AN7583-soc-data` | clk: en7523: restore AN7583 soc data | clk-en7523.c | 不适用 |
| 600-12 | `600-12-clk-en7523-pass-soc-data-to-en751221-hw-init` | clk: en7523: pass soc data to en751221 hw init | clk-en7523.c | 不适用 |
| 747 | `747-net-pcs-airoha-retrigger-the-jcpll-vco-band-search` | re-trigger the JCPLL VCO band search | pcs-airoha-common.c/.h, pcs-an7581.c | 需重生成 |
| 748 | `748-net-pcs-airoha-extend-the-manual-rx-calib-to-the-pon-pcs` | extend the manual RX calibration to the PON PCS | pcs-airoha-common.c | 直接可移 ✅ |
| 749 | `749-net-pcs-airoha-fix-USXGMII-rate-adaptation-on-speed` | fix USXGMII rate adaptation on speed changes | pcs-airoha-common.c | 直接可移 ✅ |
| 916 | `916-netfilter-nf_flow_table-keep-TTL-on-flows-bridged-within-one-bridge` | nf_flow_table: keep TTL on bridged flows | nf_flow_table_ip.c | 直接可移 ✅ |
| 920-16 | `920-16-net-airoha-Account-for-L2-overhead-in-PPE-MTU-configuration` | account for L2 overhead in PPE MTU | airoha_eth.c, airoha_ppe.c | 需重生成 |
| 926 | `926-net-airoha-allocate-UPDMEM-slots-per-ipv6-egress-mac` | allocate UPDMEM slots per IPv6 egress source MAC | airoha_eth.h, airoha_ppe.c | 需重生成 |
| 950 | `950-nvmem-layouts-include-linux-hex-h` | nvmem: layouts: include linux/hex.h | layouts.c | 直接可移 ✅ |
| 951 | `951-net-export-snmp_fold_field` | export snmp_fold_field | af_inet.c | 不适用 |
| 962 | `962-net-airoha-free-the-L2-entry-a-key-replacement-displaces` | free the L2 entry a key replacement displaces | airoha_ppe.c | 需重生成 |
| 963 | `963-net-airoha-keep-TTL-on-flows-bridged-within-one-bridge` | do not decrement TTL on flows bridged within one bridge | airoha_ppe.c | 直接可移 ✅ |
| 964 | `964-net-airoha-make-the-PPE-bind-rate-a-runtime-knob` | make the PPE bind rate a runtime knob | airoha_eth.h, airoha_ppe.c, _debugfs.c | 需重生成 |
| 965 | `965-net-airoha-dump-the-PPE-bind-and-aging-registers` | dump the PPE bind and aging registers | airoha_ppe_debugfs.c | 需重生成 |
| 966 | `966-net-airoha-add-opt-in-3-tuple-PPE-entries` | add opt-in 3-tuple PPE entries | airoha_ppe.c | 需重生成 |
| 966 | `966-net-airoha-dump-the-live-L2B-window` | dump the live L2B window | airoha_ppe_debugfs.c | 需重生成 |
| 970 | `970-net-airoha-soe-readonly-probe` | add a read-only SOE probe skeleton | Kconfig, Makefile | 直接可移 ✅ |
| 975 | `975-net-phy-airoha-usb-only-mux-the-shared-serdes` | usb: only program the SerDes mux for the shared lane | phy-airoha-usb.c | 需重生成 |
| 980 | `980-net-airoha-handle-RX_NO_CPU_DSCP-interrupt-not-just-RX_DONE` | handle RX_NO_CPU_DSCP interrupt, not just RX_DONE | airoha_eth.c, airoha_regs.h | 直接可移 ✅ |
| 986 | `986-net-airoha-refuse-to-offload-flows-behind-a-shaper` | refuse to offload flows behind a shaping qdisc | airoha_ppe.c | 需重生成 |
| 988 | `988-net-airoha-add-an-explicit-PPE-flush-node` | add a write-only debugfs node that flushes the PPE tables | airoha_ppe.c, _debugfs.c | 需重生成 |
| 989 | `989-net-airoha-add-an-opt-in-per-flow-PPE-meter` | add an opt-in per-flow PPE meter from tc police | airoha_eth.h, airoha_ppe.c, _debugfs.c | 需重生成 |
| 989 | `989-net-airoha-do-not-double-count-the-tc-ets-tx-packets` | do not double count the tc-ets tx packets | airoha_eth.c | 直接可移 ✅ |
| 990 | `990-net-airoha-let-the-NAPI-weight-be-tuned` | let the NAPI weight be tuned | airoha_eth.c/.h | 需重生成 |
| 991 | `991-net-airoha-add-an-opt-in-DS-Lite-decap-entry` | add an opt-in DS-Lite decapsulation entry path | airoha_eth.h, airoha_ppe.c, _debugfs.c | 需重生成 |
| 993 | `993-net-airoha-npu-add-read-only-support-map-and-counter-probes` | npu: add read-only support-map and counter probes | airoha_npu.c | 需重生成 |
| 993 | `993-net-airoha-npu-add-read-only-tunnel-mailbox-probe` | npu: add a read-only tunnel mailbox probe | airoha_npu.c, airoha_offload.h | 需重生成 |
| 994 | `994-net-airoha-add-minimal-PPE-6rd-tunnel-offload` | add minimal PPE 6rd tunnel offload | airoha_eth.h, airoha_ppe.c, _debugfs.c | 需重生成 |
| 999 | `999-net-airoha-add-minimal-PPE-multicast-replication` | add minimal PPE multicast replication | airoha_eth.h, airoha_ppe.c, _debugfs.c, regs.h | 需重生成 |
| 999 | `999-net-airoha-carry-the-nft-l2-bridged-signal` | carry the nft L2-bridged signal to the PPE | airoha_ppe.c, flow_offload.h, nf_flow_table*.c | 需重生成 |

## 一、直接可移（18 个，已在本 PR 落地）

判定标准三条同时满足：在队列位置上 `-F0` 零 fuzz 全过；依赖符号在 6.18 全部存在；
加进队列后全队列 `bad=0`。全部按原文件名原样复制，未改一个字节。

| 补丁 | 作用 | 风险 |
| --- | --- | --- |
| 201 | HTB leaf 的 classid 与固定 QoS channel 不匹配时拒绝建 leaf 并给 extack，避免「建上了但不整形」 | 拒绝原来静默接受的配置，脚本化 tc 配置会开始报错 |
| 204 | 新增 `/sys/kernel/debug/pse/usage`，把 PSE 池总量、各端口保留页、可共享余量与三档阈值摊开 | 纯只读；依赖 `REG_PSE_SHARE_USED_THD` 等宏，6.18 齐全 |
| 206 | GDM3/GDM4 在 WAN 口上拒绝 QoS 时说明原因，不再只返回 -EOPNOTSUPP | 只改日志与 errno 文案 |
| 207 | 硬件没有 flow counter 时打印 `n/a` 而不是 `0` | 依赖 `ppe->foe_stats_enabled`，6.18 已有；`ethtool -S` 解析脚本要能吃 n/a |
| 209 | SRAM 表尺寸改成硬件真实值（8192），此前驱动按 16384 算，两条活流会撞进同一硬件表项 | 改变 PPE 表几何，必须板测；补丁本身声明寻址问题由 212 收尾 |
| 210 | flow counter 索引改成恒等映射，越界不再记到别的流上 | 计数口径变化，监控阈值要跟着调 |
| 211 | `BUILD_BUG_ON` 断言四个 RX bank 的 pin mask 互不相交 | 编译期断言，若 6.18 的 mask 真重叠会直接编不过 |
| 215 | `num_desc` 超过 HFWD ring 上限时拒绝，而不是让 DMA 越界 | 拒绝原来能「跑起来」的配置 |
| 216 | HTB modify 路径也校验 channel，与 201 的 add 路径对齐 | 同 201，之前被静默忽略的 tc change 会开始失败 |
| 217 | 断言 RX bank mask 并集等于 `RX_DONE_INT_MASK`（去掉 ring 10/14/16-20） | 编译期断言；新增中断时必须同步改这张表 |
| 748 | PON PCS 也能走手动 RX 校准 | 改 PHY 校准流程，板测面：PON 收发光功率窗口 |
| 749 | speed 变化时重新适配 USXGMII rate | 改 PCS 速率配置，板测面：2.5G/10G 链路翻转 |
| 916 | `nf_flow_table_ip.c` 对同桥内转发的流不再递减 TTL（软件快路径） | 与 963 成对；只影响 software flow offload |
| 950 | `drivers/nvmem/layouts.c` 补 `#include <linux/hex.h>`（`mac_pton` 声明搬家） | 纯编译修复 |
| 963 | airoha 驱动侧用 `netif_is_bridge_port()` + `ingress_ifindex` 判同桥，`airoha_ppe_foe_entry_prepare()` 多一个 `bool bridged` 形参 | 改函数签名；判错会把跨桥流量的 TTL 也保住 |
| 970 | 新增只读 SOE probe（`CONFIG_NET_AIROHA_SOE`，默认 n） | 默认不编，开着才生效 |
| 980 | `RX_NO_CPU_DSCP` 中断也路由到 NAPI，此前只处理 `RX_DONE`，lan2 会静默不出包 | 中断处理面改动，板测面：lan2 打流 |
| 989（tc-ets） | 只把 delta(fwd) 当 tx_packets，消掉 2.08 倍双计数 | 计数变小是预期，历史曲线会出现台阶 |

落地后队列：**`TOTAL applied=677 bad=0`**（落地前 659/0）。

## 二、需重生成（24 个，本 PR 不动，只给路径）

每条给出「6.18 位置态上的 reject 原文 → 期望行 vs 实际行 → 重生成方案 → 风险」。
重生成的方法统一是：拿 6.18 树上的干净 pre-state（不要 fuzz 过的产物），用 `diff -up` 重做，
再放回队列位置验证 `-F0` 全过。

### 202 — PSE 无法缓冲的帧统计

```
checking file drivers/net/ethernet/airoha/airoha_eth.c
Hunk #1 succeeded at 2109 (offset -8 lines).
Hunk #2 succeeded at 2844 (offset -10 lines).
Hunk #3 FAILED at 3828.
```

期望 `static const struct ethtool_ops airoha_ethtool_ops = {`（`airoha_eth.c:3762`），
6.18 此处是 `static int airoha_metadata_dst_alloc(struct airoha_gdm_port *port)`。
**方案**：以 6.18 的 `airoha_ethtool_ops` 与 `airoha_get_eth_stats()` 为锚重做；
统计串数组长度与 `ethtool -S` 输出要一起改。
**风险**：统计错位会让所有 `ethtool -S` 字段串位。

### 205 — bridge 占用 dump，与 6.18 的 QinQ 补丁抢同一个 debugfs 锚点

位置探测 `-F0` 通过，但**加进队列就炸**：`TOTAL applied=666 bad=1`，唯一失败的是 `9999-net-airoha-add-opt-in-8021ad-QinQ-TPID-support.patch`：

```
checking file drivers/net/ethernet/airoha/airoha_ppe_debugfs.c
Hunk #2 succeeded at 233 (offset 59 lines).
Hunk #3 FAILED at 192.
1 out of 3 hunks FAILED
```

205 把 `usage` 节点插在 `bind` 注册之后，9999 的 QinQ 节点插在同一处。
**方案**：205 重编号到 9999 之后（如 `9999-01-net-airoha-dump-bridge-entries...`）并重生成。
**风险**：debugfs 节点出现顺序变化，只影响人读，不影响功能。

### 208 — PSE 实际保留了多少

位置探测 `-F0` 通过，但依赖符号在 6.18 不存在。上游 `a0b371aab6`（"parameterize the PSE reserve
instead of hardcoding GDM4"）把 7.3 的 197 与 208 一起升级了：新的 208 读 `pse_port_weight[]`、
调用 `airoha_pse_tune_port()`，并新增 `pse/weights` 节点把权重表与实际结果并排摊开。
6.18 树上 `grep -rn 'airoha_pse_tune_port\|pse_port_weight' drivers/net/ethernet/airoha/` 无任何结果，
且 6.18 的 `197-net-airoha-deepen-the-PSE-reserve-of-GDM4.patch` 仍是旧版（硬编码 GDM4）。
**方案**：先把 197 的升级版移植到 6.18（`pse_port_weight[]` + `airoha_pse_tune_port()`），再重生成 208。
**风险**：`pse/weights` 显示的是软件表，与实际生效值可能漂移；节点本身只读。

### 212 — PPE 条目按自己那张表寻址

```
checking file drivers/net/ethernet/airoha/airoha_ppe.c
Hunk #1 FAILED at 78.  Hunk #2 FAILED at 654.  Hunk #3 FAILED at 799.
Hunk #4 FAILED at 834.  Hunk #5 FAILED at 1690.
```

期望 `return PPE_SRAM_NUM_ENTRIES;`（`airoha_ppe.c:78`），6.18 此处是
`if (index >= eth->soc->num_ppe) return false;`——6.18 还没有 DRAM/PPE 表拆分。
**方案**：先落 209（已在本 PR），再按 6.18 的 `airoha_ppe_get_*` 一族重做；
`fold without udiv` 那半段可独立先做。
**风险**：PPE 表寻址错会把流表写到别的 PPE 上，症状是随机丢流。

### 213 — 大索引在 entry field 里的行为

```
checking file drivers/net/ethernet/airoha/airoha_ppe_debugfs.c
Hunk #1 succeeded at 173 (offset -69 lines).
Hunk #2 FAILED at 274.
```

期望 `&airoha_ppe_debugfs_foe_bind_fops);`（`_debugfs.c:251`），6.18 该处为空。
另需 `AIROHA_PPE_ENTRY_ALIAS_*` 枚举（6.18 无，由 964 引入）。
**方案**：先 964 或先把别名枚举单独落，再重生成。
**风险**：纯观测节点，功能风险低；依赖链风险高。

### 214 — 不再为 NPU 从不提供的计数器付费

```
checking file drivers/net/ethernet/airoha/airoha_ppe.c
Hunk #3 FAILED at 231.
```

期望 `static void airoha_ppe_hw_init(struct airoha_ppe *ppe)`（`airoha_ppe.c:209`），
6.18 此处是 `int j;`（另一函数体内）。另：`+` 行用到 `airoha_ppe_fold_hash()` /
`fold_hash`，6.18 没有——由 926 引入。
**方案**：先 926，或把 fold 逻辑内联进 214。
**风险**：少分配计数器后 `ethtool -S` 的 flow 统计会变少。

### 747 — 重触发 JCPLL VCO band search

```
checking file drivers/net/pcs/airoha/pcs-airoha.h
Hunk #1 succeeded at 1683 (offset 423 lines).
Hunk #3 FAILED at 1311.
checking file drivers/net/pcs/airoha/pcs-airoha-common.c
Hunk #1 succeeded at 703 (offset 44 lines).  Hunk #2 succeeded at 1381 (offset 112 lines).
```

期望 `{`（`pcs-airoha.h:1307`），6.18 此处是
`#define AIROHA_PCS_PMA_BIST_TX_DATA_POLLUTION_LATCH BIT(16)`。
补丁还引用 `post_config` 回调，6.18 的 pcs-airoha 没有这个钩子。
**方案**：把 `post_config` 钩子与 747 一起重做（钩子先落，再落校准）。
**风险**：AN7581 ETH lane 的 VCO 校准，配错会掉链路。

### 920-16 — PPE MTU 里把 L2 开销算进去

```
checking file drivers/net/ethernet/airoha/airoha_eth.c
Hunk #2 FAILED at 2187.
checking file drivers/net/ethernet/airoha/airoha_ppe.c
Hunk #2 FAILED at 135.  Hunk #3 FAILED at 152.
```

期望 `if (!airoha_is_lan_gdm_dev(dev))`（`airoha_eth.c:2186`），6.18 此处是
`val = airoha_fe_rr(eth, REG_FE_GDM_RX_ETH_MC_CNT(port->id));`。
**方案**：6.18 的 MTU 落在 `airoha_ppe_set_mtu()`，按该函数体重做，别照搬 7.3 的函数边界。
**风险**：改错 MTU 会同时影响 offload 与内核转发路径的尺寸判断。

### 926 — IPv6 egress MAC 的 UPDMEM 槽分配

```
checking file drivers/net/ethernet/airoha/airoha_eth.h
Hunk #1 succeeded at 650 (offset -8 lines).  Hunk #2 FAILED at 746.
checking file drivers/net/ethernet/airoha/airoha_ppe.c
Hunk #7 FAILED at 1655.（其余 8 个 hunk 成功，偏移 -75 ~ -243）
```

期望 `struct airoha_qdma qdma[AIROHA_MAX_NUM_QDMA];`（`airoha_eth.h:743`），
6.18 此处是 `airoha_rmw((qdma)->regs, (offset), (mask), (val))` 附近。
`UPDMEM` / `remove_flow` 两个符号在 6.18 也不存在。
**方案**：结构体布局按 6.18 重排后重做；`remove_flow` 回调要单独补。
**风险**：UPDMEM 槽分配错 → IPv6 大流量下 MAC 学习错乱。

### 962 — key 替换时释放被顶掉的 L2 条目

位置探测零 fuzz 通过，但依赖 `airoha_ppe_foe_remove_l2_subflows()`——6.18 没有，
它由 `999-net-airoha-carry-the-nft-l2-bridged-signal` 引入。
**方案**：先落 999（nft L2 bridged），或把子流释放内联进 962。
**风险**：不释放会泄漏 L2 条目，长时间跑满表。

### 964 — PPE bind rate 变成运行时旋钮

```
checking file drivers/net/ethernet/airoha/airoha_eth.h
Hunk #2 succeeded at 814 (offset -45 lines).  Hunk #1 FAILED at 709.
checking file drivers/net/ethernet/airoha/airoha_ppe.c
Hunk #1 FAILED at 228.  Hunk #2 FAILED at 340.
checking file drivers/net/ethernet/airoha/airoha_ppe_debugfs.c
Hunk #2 FAILED at 266.
```

期望 `*/`（`airoha_eth.h:709`），6.18 此处为空；`airoha_ppe.c:310` 期望
`"PPE%u: DRAM table did not come up, %u entries unreachable\n"`，实际是
`memcpy(dest, &act->mangle.val, sizeof(u32));`。
**方案**：绑定速率在 6.18 是编译期常量，改成 module param 需要重排 app/eth 两个结构体。
**风险**：运行中改绑定速率会打断存量流，必须带 flush。

### 965 — dump bind 与 aging 寄存器

```
checking file drivers/net/ethernet/airoha/airoha_ppe_debugfs.c
Hunk #1 FAILED at 322.  Hunk #2 FAILED at 335.
```

期望 `.release = single_release,`（`_debugfs.c:322`），6.18 该处为空——
6.18 用 `DEFINE_SHOW_ATTRIBUTE()` 宏，没有手写的 `seq_operations`。
**方案**：按 `DEFINE_SHOW_ATTRIBUTE` 风格重写输出函数与注册。
**风险**：纯观测，功能风险低。

### 966（3-tuple）— 可选 3 元组 PPE 条目

```
checking file drivers/net/ethernet/airoha/airoha_ppe.c
Hunk #1 FAILED at 6.  Hunk #5 FAILED at 1634.  Hunk #8 FAILED at 1769.  Hunk #9 FAILED at 1780.
（9 个 hunk 中 4 个失败）
```

期望 `#include <linux/platform_device.h>`（`airoha_ppe.c:10`），实际是
`#include <linux/moduleparam.h>`——6.18 的头文件顺序不同，且没有 3-tuple 需要的
`airoha_ppe_foe_entry_prepare()` 新签名。
**方案**：按 6.18 的 prepare 路径重做，3-tuple 键解析要跟着 6.18 的 dissector 走。
**风险**：键解析错 → offload 误命中，症状是随机回包到错端口。

### 966（L2B window）— dump 活的 L2B 窗口

```
checking file drivers/net/ethernet/airoha/airoha_ppe_debugfs.c
Hunk #1 FAILED at 365.  Hunk #2 FAILED at 380.
```

期望 `}`（`_debugfs.c:365`），该处为空；注册块期望
`&airoha_ppe_debugfs_bind_rate_fops);`——由 964 引入。
**方案**：先 964，再按 6.18 的注册块重做。
**风险**：纯观测。

### 975 — USB 只对共享 SerDes 编程 mux

位置探测零 fuzz 通过，但宏名漂移：补丁用 `SSTR` / `USB_PCIE_SEL`，
6.18 的 `drivers/phy/airoha/phy-airoha-usb.c:17-20` 是
`AIROHA_SCU_SSTR` / `AIROHA_SCU_SSTR_USB_PCIE_SEL`。
**方案**：换宏名重生成（纯 sed 级改动）。
**风险**：SerDes mux 配错会让 USB 与 PCIe 抢同一组 lane。

### 986 — shaper 后面的流不再 offload

```
checking file drivers/net/ethernet/airoha/airoha_ppe.c
Hunk #1 FAILED at 608.
```

期望 `hwe->ipv6.l2.src_mac_hi));`（`airoha_ppe.c:608`），实际是
`hv1 = l2->common.src_mac_hi & 0xffff;`——hash 函数是 212 之后的形态。
**方案**：先 212。否则按 6.18 的 hash 函数重写这半段。
**风险**：拒绝 offload 是对的，但误判会让整条链路的吞吐掉到 CPU 转发水平。

### 988 — 显式 flush PPE 表的写节点

```
checking file drivers/net/ethernet/airoha/airoha_ppe.c
Hunk #2 succeeded at 1553 (offset -470 lines).
checking file drivers/net/ethernet/airoha/airoha_ppe_debugfs.c
Hunk #1 FAILED at 7.  Hunk #2 FAILED at 418.  Hunk #3 FAILED at 436.
```

期望 `#include "airoha_regs.h"`（`_debugfs.c:8`），6.18 的 debugfs.c 不 include 它；
另引用 `airoha_ppe_get_sram_num_entries()`（209 引入，已落地，可复算）。
**方案**：补 include，按 6.18 的注册块重做。
**风险**：写节点误触会 flush 全部 PPE 表，症状是瞬间流量走 CPU。

### 989（per-flow meter）— tc police 映射到 PPE meter

```
checking file drivers/net/ethernet/airoha/airoha_eth.h
Hunk #4 FAILED at 724.  Hunk #5 FAILED at 759.
checking file drivers/net/ethernet/airoha/airoha_ppe.c
10 out of 11 hunks FAILED（第 1 个 FAILED at 7）
checking file drivers/net/ethernet/airoha/airoha_ppe_debugfs.c
Hunk #1 FAILED at ...
```

期望 `AIROHA_PPE_ENTRY_ALIAS_FAILED,`（`airoha_eth.h:682`），实际是
` * through the plain PPE fast path.`；`airoha_ppe.c:9` 期望
`#include <linux/module.h>`，实际是 `#include <linux/of_platform.h>`。
**方案**：依赖 964（bind rate）与 PPE meter 基础设施，按依赖顺序后置。
**风险**：meter 会改 PPE 表项格式，与 964/994 一起做才安全。

### 990 — NAPI weight 可调

```
checking file drivers/net/ethernet/airoha/airoha_eth.c
Hunk #1 FAILED at 9.  Hunk #3 FAILED at 797.  Hunk #6 FAILED at 2141.  Hunk #7 FAILED at 2156.
checking file drivers/net/ethernet/airoha/airoha_eth.h
Hunk #1 FAILED at 767.
```

期望 `#include <linux/if_vlan.h>`（`airoha_eth.c:11`），实际是
`#include <linux/pcs/pcs.h>`；`eth.h:767` 期望 `u32 updmem_seq;`，实际是 `{`。
**方案**：6.18 没有 `queues` debugfs 节点与 `updmem_seq` 字段，按 6.18 现状重做。
**风险**：NAPI weight 直接影响 RX 延迟与单核占用，调错会掉吞吐。

### 991 — 可选 DS-Lite 解封装条目

```
checking file drivers/net/ethernet/airoha/airoha_eth.h
Hunk #2 FAILED at 581.  Hunk #3 FAILED at 933.
checking file drivers/net/ethernet/airoha/airoha_ppe.c
Hunk #1 FAILED at 4.（14 个 hunk 中 6 个失败）
```

期望 `* airoha_ppe_foe_entry_prepare().`（`airoha_eth.h:572`），实际是 `};`；
依赖 994 的 tunnel 结构（`tunnel_id` / `dslite`）。
**方案**：先 994。
**风险**：DS-Lite 解封装错就是丢包。

### 993（support-map / counter probes）— NPU 只读探测

位置探测零 fuzz 通过，但 `PPE_FUNC_SET_WAIT_*` 与 `WLAN_FUNC_*` 这一组枚举在 6.18 的
`drivers/net/ethernet/airoha/airoha_npu.c` 里名字不同或不存在。
**方案**：对照 6.18 的 `airoha_npu.c` 枚举名重生成。
**风险**：只读探测，功能风险低。

### 993（tunnel mailbox probe）— 同上

`CTRL3` / `NDBG` / `RV32` / `TLB7` 等 mailbox 宏在 6.18 不存在，需随 6.18 的 NPU 寄存器表重做。
**风险**：只读。

### 994 — 最小 PPE 6rd 隧道 offload

```
checking file drivers/net/ethernet/airoha/airoha_eth.h
Hunk #2 FAILED at 616.  Hunk #3 FAILED at 967.
checking file drivers/net/ethernet/airoha/airoha_ppe.c
Hunk #2 FAILED at 64.
checking file drivers/net/ethernet/airoha/airoha_ppe_debugfs.c
Hunk #1 FAILED at 581.  Hunk #2 FAILED at 596.
```

期望 `u8 tunnel_id;`（`airoha_eth.h:602`），实际是 ` */`；`airoha_ppe.c:63` 期望
`MODULE_PARM_DESC(airoha_ppe_dslite,`，实际是 `}`——6.18 没有 tunnel/dslite 参数框架。
**方案**：先补参数与结构体框架（可与 991 合并一次做），再落 994。
**风险**：6rd offload 配错 → IPv6 大面积丢包。

### 999（multicast replication）— 最小 PPE 组播复制

```
checking file drivers/net/ethernet/airoha/airoha_eth.h
Hunk #1 FAILED at 560.  Hunk #2 FAILED at 618.
checking file drivers/net/ethernet/airoha/airoha_ppe.c
Hunk #4 FAILED at 2462.（4 个 hunk 中 1 个失败）
```

期望 `u16 tunnel_mtu;`（`airoha_eth.h:560`），实际是 `struct rhash_head node;`——
用的还是 994 引入的 tunnel 结构。
**方案**：依赖 994。
**风险**：组播复制错 → 泛洪行为异常。

### 999（nft L2 bridged signal）— 把 nft 的同桥信号传给 PPE

```
checking file drivers/net/ethernet/airoha/airoha_ppe.c
Hunk #1 FAILED at 79.  Hunk #2 FAILED at 2297.  Hunk #3 FAILED at 2510.
checking file include/net/netfilter/nf_flow_table.h
Hunk #1 FAILED at 164.  Hunk #2 FAILED at 251.
checking file net/netfilter/nf_flow_table_core.c
Hunk #1 FAILED at 154.
checking file net/netfilter/nf_flow_table_path.c
Hunk #1 FAILED at 418.
```

期望 `return airoha_ppe_6rd;`（`airoha_ppe.c:79`），实际是
`bool airoha_ppe_is_enabled(struct airoha_eth *eth, int index)`——同样缺 994 的参数。
**方案**：跨 `net/netfilter` 与驱动两侧，先落 `include/net/flow_offload.h` 的 meta 标志，
再改 6.18 的 `nf_flow_table_offload` 结构，最后接驱动。**这一条同时解锁 962**。
**风险**：跨子系统改动，错则所有 offload 流量的 TTL/桥判定全错。

## 三、不适用（3 个）

| 补丁 | 结论 | 证据 |
| --- | --- | --- |
| 600-11 | 6.18 已有等价的 AN7583 soc data | `drivers/clk/clk-en7523.c:1252` 已是 `static const struct en_clk_soc_data an7583_data = {...}`，含 `probe_child` / `base_clks` / `num_clocks + 1` / `pcie_ops` / `hw_init`；`:1268` 已有 `{ .compatible = "airoha,an7583-scu", .data = &an7583_data }`。补丁想在 `en751221_data` 之后插入同一段，自然 `Hunk #1 FAILED at 1485`。 |
| 600-12 | 6.18 的 hw_init 已经在传 soc_data | `drivers/clk/clk-en7523.c:1210` 是 `err = soc_data->hw_init(pdev, soc_data, clk_data);`，`en751221_clk_hw_init()` 的形参已含 `const struct en_clk_soc_data *soc_data`。补丁要加的正是这个形参，故 `Hunk #1 FAILED at 1340`。 |
| 951 | 6.18 已经导出这两个符号 | `net/ipv4/af_inet.c:1654` 已有 `EXPORT_SYMBOL_GPL(snmp_fold_field);`，`:1687` 已有 `EXPORT_SYMBOL_GPL(snmp_fold_field64);`。补丁重复添加，两个 hunk 必然失败。 |

这三条不需要「等价做法」——6.18 上的行为已经正确，再贴一遍会变成重复定义。

## 迁移计划（按优先级）

顺序按「先解依赖，再落功能，最后才是纯观测」排。每项一句话说风险。

### P0 — 解依赖（不做这些，后面 5 条都动不了）

1. **999（nft L2 bridged signal）**：跨 `net/netfilter` 与驱动，解锁 962。
   风险：跨子系统，错则所有 offload 流的桥判定失效。
2. **212（PPE 条目按本表寻址）**：209 已落地，212 收尾；解锁 986。
   风险：表寻址错会写坏 PPE 表，症状是随机丢流。
3. **964（bind rate 运行时旋钮）**：解锁 965 / 966-L2B / 989-meter / 213。
   风险：结构体改动面大，运行中改速率必须带 flush。

### P1 — 功能性修复（有明确线上症状）

4. **926（IPv6 egress MAC 的 UPDMEM 槽）→ 214（少分配计数器）**：一对，按序做。
   风险：槽分配错则 IPv6 大流量下 MAC 学习错乱。
5. **994（6rd）→ 991（DS-Lite）→ 999（组播复制）**：一条隧道族，按序做。
   风险：隧道 offload 配错就是 IPv6 / DS-Lite 丢包。
6. **920-16（PPE MTU 计 L2 开销）**：独立，但要按 6.18 的 `airoha_ppe_set_mtu()` 重做。
   风险：MTU 影响面覆盖 offload 与软件转发两条路径。

### P2 — 板级行为（需要硬件在环才能验收）

7. **747（JCPLL VCO band search）**：要先补 `post_config` 钩子。
   风险：校准错会掉 ETH lane。
8. **975（USB SerDes mux）**：纯宏名重生成，但影响 USB/PCIe lane 复用。
   风险：配错则 USB 与 PCIe 抢 lane。
9. **990（NAPI weight 可调）**：影响 RX 延迟排序。
   风险：调错掉吞吐。

### P3 — 观测与门禁（不影响转发正确性）

10. **202（PSE drop 统计）**、**205（bridge 占用，重编号到 9999 之后）、208（等 197 升级）**、
    **965 / 966-L2B / 213（debugfs 观测）**、**988（flush 写节点）**、**993 ×2（NPU 只读探测）**。
    风险：202 改 `ethtool -S` 字段序；988 误触会 flush 整张 PPE 表；其余只读。

### P4 — 需要配套设计，暂不做

11. **966（3-tuple）**、**989（per-flow meter）**：都要改 PPE 表项格式，
    与 964/994 强耦合，建议和它们合并成一次 PPE 表格式变更。
    风险：表格式变更没有回退路径，必须整批上线。

## 复现

```sh
# 1. 干净 6.18.55（不要解到 /tmp，那里是 tmpfs）
mkdir -p /home/l1n/projects/.scratch/mt7618/pre
tar -xf /home/l1n/projects/.scratch/linux-6.18.55.tar.xz -C /home/l1n/projects/.scratch/mt7618/pre

# 2. 全队列验证（generic backport/pending/hack + airoha/patches-6.18）
bash /home/l1n/projects/.scratch/apply-queue-618.sh \
  /home/l1n/projects/.scratch/mt7618/pre/linux-6.18.55 \
  /home/l1n/projects/xr1710g-openwrt/.agents/worktrees/mt7618
# 期望：TOTAL applied=677 bad=0
```

单项复现（位置态、零 fuzz）：

```sh
# 取 6.18 队列里排在目标补丁之前、碰同一文件的补丁依次应用，然后：
patch -p1 -F0 --dry-run -f -i target/linux/airoha/patches-7.3/<补丁>.patch
```

`-F0` 是硬要求。带 fuzz 的「能过」没有意义，它只说明补丁工具替你猜了位置。
