# 03 — 方案三：裁决「AdGuardHome + mosdns + 代理」三板斧

> 上游：`plan/00-总纲-架构与供给链.md`（已定决策 D10：**只出 ADR + 证据，不落地任何 DNS 组件**）
> 依据：`research/DNS方案深度调研-2026-09-10.md` §15（行 713–788）、§2/§9、`research/DNS-architecture-factfind.md`、`research/dns/REPORT.md`

---

## 1. 被裁决的方案（来自网络社区的「三板斧」）

> mosdns 做分流中枢 → AdGuardHome 做过滤/统计面板 → 代理核心（mihomo/sing-box）做 fake-ip 与连接层分流。

## 2. 裁决

**不合理。** 在本机是「**功能重叠 + 结构性冲突 + 双倍故障域**」的组合。研究加权分：`S1 = 38.05` → 加 AGH `35.35` → 加 AGH+mosdns **`32.00`**（越加越差）。

---

## 3. 逐条证据

### 3.1 DNS 前置层看不见 fake-ip 域名（决定性）
被代理域名在代理核心的 DNS 模块里就被本地 fake-ip 化（`withFakeIP` **在上游查询之前**拦截），AGH/mosdns 这种「DNS 前置层」**根本收不到这些查询** ⇒
- 拦不住被代理域名上的广告；
- 若它们越权返回真实 IP，**破坏 fake-ip 语义**（社区原文：「SmartDNS 产生的真实 IP 会与 FakeIP 机制冲突」）。

### 3.2 mosdns 与代理核心的 DNS 模块逐项重叠（纯冗余）
分流 / DoH / 缓存 / fake-ip / geodata 逐项重叠；mosdns 唯一独有的是「DNS 层 IP 标记 / 并发测速择优」，AGH 独有的是「过滤规则生态 + WebUI 统计」。
⇒ **要过滤面板就只加 AGH；mosdns 是纯冗余。**

### 3.3 供给面与稳定性（有事故史）
- **mosdns 不在任何官方 feed**（社区封装），引擎停滞（v5.3.4，2026-01），封装层天天更新 ⇒ 数据/接线风险全在第三方层；
- 依赖 **boot 期才可能就绪的 geosite/geoip 数据文件**；
- **09-09 已在本机造成整网断解析**：数据缺失 → mosdns 起不来 → dnsmasq 指向 `127.0.0.1#5335` 死端口 ⇒ 全网解析失败；且事故中段还叠加了「dnsmasq server 列表被清空」（`warning: no upstream servers configured`，源码 `src/dnsmasq.c:998` 唯一出处 = `no-resolv` 生效且 server 列表为空）。

### 3.4 体积与「镜像可复现」
- AGH：apk 11.1 MB / Installed **28.7 MiB**；mosdns Go 15–25 MB ⇒ 合计 ≈50 MiB；
- 本轮虽已扩容 `fit` 卷，但把**可复现镜像**当硬要求时，引入**不在官方 feed** 的组件仍会带来锁源义务与单一维护点；
- 运行期装入 overlay = 写 2.26 MB/s 的 NAND（一次性约 22 s，可接受，但破坏「镜像可复现 + 锁源」铁律）。

### 3.5 双份真相与缓存冲突
- **DNS 层分流（mosdns）与连接层分流（代理 rules）是两套真相**，不一致时出现「解析走直连、连接却走代理」（或反之）的经典疑难；
- fake-ip 的 `fake-ip-ttl` 默认 **1 秒**，前置缓存**必须关闭**（OpenClash 强制 `dnsmasq cachesize=0`；Aethesailor 教程强制「禁止 Dnsmasq 缓存 DNS」；本机 `cachesize=1000` 的现状与 fake-ip 前置缓存是**无任何可信来源背书**的组合）。

### 3.6 劫持残留的故障面（若引入反代类组件）
代理类组件的 DNS 劫持表常在 `start` **无条件**打上，只有 `stop/reload` 才清理；进程崩溃且 respawn 失败 ⇒ **劫持表残留，LAN 的 DNS 与 TCP 全指向死端口 = 全网断**（比 09-09 事故面更大）。这也是方案一必须带 **guard + fail-open** 的直接原因（见 `01-方案一` §4.5）。

---

## 4. 正确替代

| 需求 | 正确工具 | 说明 |
|---|---|---|
| 拦广告（含被代理域名） | **代理核心的连接级规则**（`rule-providers` + `RULE-SET,…,REJECT` / `GEOSITE,category-ads-all,REJECT`） | 连接级，**对 fake-ip 域名同样生效**，0 新进程 |
| 过滤/统计面板 | **只加 AGH**，且必须：关 DNS 劫持、上游指 `127.0.0.1#<代理DNS端口>`、**缓存关闭** | 加权分 35.35（仍不如不加） |
| 加密上游 | `https-dns-proxy` / `stubby`（C 系，百 KB 级） | 官方 feed、体积小 |
| LAN 解析器兜底 | **dnsmasq-full** 继续做不会死的核心 | 明确失败形态 + 明文兜底 |

**四条硬约束（若将来仍要上任何前置 hub，任一不满足即不可上）**：
1. hub **不缓存**；
2. hub **不得**对 fake-ip 域名返回真实 IP；
3. 若用 mosdns，名单数据**必须先就绪**，首启闸门（数据缺失则不接管）必须写进 `uci-defaults`；
4. guard 必须把新端口纳入心跳链（否则又多一个「指向死端口」的黑洞）。

---

## 5. 本轮交付物（不写代码）

| 文件 | 内容 |
|---|---|
| `docs/adr/0005-reject-adguardhome-mosdns-proxy-stack.md` | 决策 + 背景 + 备选（P1 只加 AGH / P2 用连接级 REJECT / P3 完整三板斧）+ 后果；引用上述 §3 证据 |
| `research/三板斧-vs-本机-对照表.md` | 一页可复核对照表（能力矩阵 + 加权分 + 每条证据的来源行号） |
| `docs/FIXES.md` 条目 | 「拒绝 AGH+mosdns 叠加」结论 + 09-09 事故根因归档索引 |
| `CONTEXT.md` 词条 | 「DNS 前置层」「fake-ip 作用域」「连接级过滤 vs DNS 级过滤」 |

> 本轮**不**在固件或设备上落地 AGH / mosdns 的任何组件。
