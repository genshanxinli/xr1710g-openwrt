# PPPoE 解封装：内核 ABI 缺口与 #81 的阻塞点

本文记录 `PPPoE over VLAN` 在 flowtable offload 路径上到底断在哪一环，以及
为什么 issue #81 要的「可选解封装语义（decap=3，带 IB1 回读）」不能靠改驱动做出来。

结论先说：

| 事项 | 状态 |
| --- | --- |
| 「一个 VLAN + 一个 PPPoE」能否在软件侧被识别 | 能，`9905-...-report-pppoe-over-vlan-capability.patch` 已落地 |
| 驱动能否对这条组合给出明确拒绝 + 日志 | 能，`pppoe_vlan_refuse=1` 时返回 `-EOPNOTSUPP` |
| PPE 能否一次剥掉 VLAN + PPPoE 两层 | **未知**，未实测，硬件语义没有文档 |
| 可选解封装语义（decap=3） | **阻塞在上游 netfilter**，与本驱动无关 |

## 1. 缺口：`FLOW_ACTION_PPPOE_POP` 不存在

flow action 枚举里只有 push，没有 pop：

```c
/* include/net/flow_offload.h */
	FLOW_ACTION_PPPOE_PUSH,
```

作为枚举值与代码符号 `FLOW_ACTION_PPPOE_POP` 在 7.3 prepared 树里 0 命中
（9905 之后唯一出现的地方是它自己写的注释和日志字符串）。
所以「让用户选择这条流用什么方式解封装 PPPoE」这件事，在规则层面**没有载体**：
`nft` 表达一条 ingress 剥两层头的规则时，只能发 `FLOW_ACTION_VLAN_POP`，
PPPoE 那一层没有任何 action 可以发，驱动也就收不到。

`nf_flow_table_offload.c: nf_flow_rule_route_common()` 的行为正是这个枚举形状的直接后果：
ingress 侧只为 `ETH_P_8021Q` 层发 `FLOW_ACTION_VLAN_POP`，其它封装层静默跳过。
于是 PPPoE-over-VLAN 的规则到达驱动时是 `vlan_pop = 1`、`pppoe_pop = 0`。

## 2. 缺口的下游后果：静默丢弃与错误编程

两条路都很糟，且在 9905 之前都没有任何输出：

1. **offload 层静默丢弃**。`nf_flow_offload_tuple()` 对每个 action 调
   `flow_offload_act_setup()`，失败就 `continue`；若最终有效 action 数为 0，
   `flow_offload_rule_add()` 返回 `-ENOENT`，`flow_offload_work_add()` `goto out`。
   没有日志、没有计数器、没有 `IPS_HW_OFFLOAD_BIT`，流就这么留在软件路径里，
   从外部看和「硬件不支持」无法区分。
2. **驱动侧错误编程**。`airoha_ppe_flow_offload_replace()` 里
   `case FLOW_ACTION_VLAN_POP: break;` 不记录任何状态，`data.pppoe.num` 只由
   `FLOW_ACTION_PPPOE_PUSH` 置位。PPPoE-over-VLAN 这条流编出来的 IB1 是
   `VLAN_LAYER=0`、PPPoE bind 位全 0：硬件什么都不剥，把 session 头当成 L3 载荷去匹配。

## 3. 9905 做了什么

`target/linux/airoha/patches-7.3/9905-net-airoha-report-pppoe-over-vlan-capability.patch`：

- `struct flow_cls_offload` 增加 `bool pppoe_decap`，由 `nf_flow_offload_init()`
  从 `tuple->encap[]` 里扫 `ETH_P_PPP_SES` 置位。这是在 action 列表丢信息之后，
  驱动唯一还能拿到「这条流里有 PPPoE 层」的通道。
- 驱动在 `airoha_ppe_flow_offload_cmd()` 里检查 `pppoe_decap && vlan_pop`，
  命中就打一条 ratelimited 日志，明确写出 `vlan_pop=1 pppoe_pop=0` 和缺失的 action 名。
- 新模块参数 `pppoe_vlan_refuse`（bool，0644，默认 0）。置 1 时该组合返回
  `-EOPNOTSUPP`，让流留在软件路径，而不是编一条剥不干净的表项；默认 0 时行为与补丁前逐字节相同。

这是**软件能力探测**，不是硬件能力声明：PPE 是否支持一次剥两层，仍然未知。

## 4. #81 为什么是 documented non-goal

#81 要求的 decap=3（psn+etype、不置 bit23）需要「按流选择解封装语义」。
在 action 层没有 `FLOW_ACTION_PPPOE_POP` 的前提下，任何本地的「选择」都只能是
驱动私有 ioctl / module param 之类旁路，nft 规则本身仍然无法表达，用户看到的
`nft list ruleset` 与实际生效语义会分叉。

所以 #81 的实现阻塞在上游 netfilter，需要两件事同时成立：

1. `include/net/flow_offload.h` 增加 `FLOW_ACTION_PPPOE_POP`（并进 uapi 语义）；
2. `nft` 用户态会为它发 action（今天的 nft 不会发）。

**被否决的替代方案**：在本树里私自加一个 `FLOW_ACTION_PPPOE_POP`。
它会被当成内核内部 ABI 使用（枚举值参与 `flow_action_entry` 布局与所有驱动的 switch），
等于把「上游没定义的东西」固化成本仓私有契约；而系统里没有任何组件会产出这个 action，
加完之后行为与不加完全相同，只多一份需要长期维护的分歧。
等上游落地后再写 decap=3，届时 9905 的 `pppoe_decap` 位可以由真实 action 取代。

## 5. 未实测

本机（XR1710G，PPPoE 未配置）**未能实测**这条负路径：没有 PPPoE WAN 就构造不出
PPPoE-over-VLAN 的 flowtable 流，日志与实际拒绝只能靠代码审阅与编译验证。
实测需要一条 PPPoE-over-VLAN 的 WAN 与一条能进 flowtable 的长连接。
