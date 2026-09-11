# ADR 0003 — 代理分流架构：内核层判定 + 名单客户端作用域 fake-ip（架构 C）

**Status**: accepted（2026-09-11 评审确定；plan/06 第 3 轮 Q11 用户裁决「以哪个硬件加速效果更好为准，哪个性能更好」）
**Context**:
本设备的代理能力必须与已有资产共存：`chain forward` 的 `flow add @ft`、flowtable 设备表、`flow_offloading*` 三者构成硬件（PPE/NPU）卸载路径，是这台 Wi-Fi 7 主路由的核心资产（2×10G + 8 核 NPU）。研究已实机取证：**同一批流一旦被 nft 重定向进用户态，对应的 PPE BND 条目直接归零**（`research/APP-FIT-RESEARCH-2026-09-10.md` §9.7）。

因此「分流判定发生在哪一层」是决定卸载存亡的唯一开关。两种候选：

- **架构 A（真实 IP）**：内核抓取范围由「目的 IP ∈ 非 CN」决定，客户端拿真实 IP，代理侧需 sniffer 读 TLS ClientHello 才能还原域名；
- **架构 C（名单客户端作用域 fake-ip）**：只有 `@proxy_hosts` 中的客户端其 DNS 被 redirect 到代理核心的 fake-ip 解析器，非 CN 域名得 `198.18.x`，代理侧查表即得域名。

**Decision**:
采用**架构 C**。内核层（nft `inet xr1710g_proxy` + 策略路由）做唯一的分流判定，fake-ip 的作用域**严格限定为 `@proxy_hosts`**，普通客户端恒得真实 IP。

具体三条硬约束：
1. 判定在 `prerouting(mangle)`：`ip saddr @proxy_hosts ip daddr @china_ip4 accept` → 国内流量走原 `forward` 路径**保留 PPE/NPU 卸载**；其余 `meta mark 0x40` → table 100 → TUN；
2. **名单客户端的 CN 域名必须由 DNS 规则回真实 IP**——若被 fake-ip 化，内核 `ip daddr @china_ip4` 匹配不到真实 CN 目的 IP，放行失效、CN 流量被拐进用户态、卸载全丢；
3. fake-ip **不是路由机制**，只是 DNS 应答；它进不了卸载判定。

**Why**:
卸载维度上 A 与 C **逐字节等价**——两者都是「`@proxy_hosts` 且目的 ∉ `@china_ip4` → 抓；其余 → 原 forward」。真正的差异只在代理侧软件性能，那里 C 全面更优：

| 代理侧指标 | A（真实 IP） | C（名单范围 fake-ip） |
|---|---|---|
| 每连接用户态开销 | 必须 sniff TLS ClientHello | 目的 IP 即 fake-ip，**零嗅探** |
| DNS 首答（非 CN） | 每次等真实上游 | 直接合成 `198.18.x`，不等上游 |
| UDP/QUIC 分流 | 只能 sniff，ECH 场景失效退 IP 规则 | 域名→fake-ip 映射，**精确** |
| PPE/NPU 卸载 | 同一抓取集合 | 同一抓取集合（**平手**） |

**Considered Options**:
- **架构 A（真实 IP + sniffer）**：故障域更小（名单客户端不新增 DNS 依赖），但每连接多一次 TLS 嗅探、DNS 首答多一次上游往返、ECH/QUIC 分流退化。按「性能优先」否决。
- **fake-ip 全局生效（dnsmasq 把所有非 CN 查询都转给 fake-ip 解析器）**：普通客户端会解析到 `198.18.x`，而内核放行/抓取规则只对 `@proxy_hosts` 生效 ⇒ **普通客户端国外站点不是慢，是直接不通**。硬性否决。
- **TProxy 形态**：本机无 `nft_tproxy.ko`/`nf_tproxy*`（已实机取证）⇒ 今天不可用；改用已内置的 `kmod-tun` 做 TUN 入站。
- **homeproxy 作为前端**：硬依赖 `kmod-nft-tproxy`，且其 `routing_mode=bypass_mainland_china` 把 CN 判定放在用户态（`generate_client.uc`），**先天不保 CN 流量的卸载**。否决，前端自写。

**Consequences**:
- ✅ 卸载不变量可被**一个数字**验收：开/关 `xr1710g_proxy`，非名单客户端 `cat /sys/kernel/debug/ppe/bind | wc -l` 与 LAN↔WAN iperf3 无实质差异（≤2%）；
- ⚠️ 名单客户端新增一个 DNS 依赖 ⇒ **必须带 guard + fail-open**：sing-box/DNS 不健康时撤掉抓取与劫持规则，名单客户端退回直连，而不是断网；
- ⚠️ 名单客户端的 CN 域名回真实 IP 是**架构成立的前提**，必须写成配置生成的硬约束而非注释；
- ⚠️ 已卸载的旧流不会即时改道（offload 后报文绕过 netfilter）⇒ 名单变更后只做**定向** conntrack 清理，不做全表 flush；
- ⚠️ 名单客户端若同时是 Tailscale 节点，需注意 `0x80000/0xff0000` 的 mark 屏蔽；本轮只做冲突检测 + 拒绝启动。
