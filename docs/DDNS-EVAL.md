# DDNS 方案调研报告（XR1710G OpenWrt）

> 范围：调研 + **方案 A 已落地**（seed-config.diff，2026-09-08）；方案 D（ddns-go）未落地，保持备选。
> 基线：本仓库 main（openwrt master 滚动基线，2026-08-31 最近活动；kernel 6.18 / airoha-an7581）。
> 文本约定：标注「（需实测）」处为**构建/实机验证前不可当定论**的事实；标注「（证据）」处附第 6 节参考资料编号。

---

## 0. 结论速览（TL;DR）

- XR1710G 硬件（AN7581GT 4×1.3GHz arm64 / 2GB RAM / 512MB SPI-NAND）**资源极其充裕**：本文全部候选都能跑，资源占用不是否决项，真正决定选型的是「与仓库政策的契合度 + IPv6 双栈 + 提供商覆盖 + 维护负担」。
- **综合最优（推荐主用）**：`ddns-scripts` + `ddns-scripts-services` + `luci-app-ddns` —— OpenWrt 官方组合，uci 原生、IPv6 支持成熟、境外提供商全覆盖（Cloudflare/No-IP/DuckDNS/HE.net 等）、aliyun.com 已入服务列表（以 feed 源码为准）；与官方 feed 零锁源负担，最贴合本仓库「官方优先 + 锁源铁律 + 滚动 master」的形态 [R2][R3]。
- **中国内地（阿里云/腾讯云 DNSPod 等）重度用户备选**：`ddns-go` —— 国内提供商覆盖最全、自带中文 Web UI、双栈最强；代价是第三方 Go 二进制、需自建 feed + 锁 commit + FIXES 登记、体积 ~15–20MB（需实测）[R4][R7]。
- **轻量/无 GUI 洁癖备选**：`inadyn` —— 官方 feed（`net/inadyn` 已确认存在 [R5]），C 守护进程 ~百 KB 级，稳定省心；但无官方 LuCI、阿里云/DNSPod 无原生插件。
- **不推荐**：`ddclient` —— Perl 重依赖、IPv6 支持弱、上游节奏放缓，纯属无谓负担。
- 若未来落地，最小动作是 seed-config.diff 加 2~3 行官方包符号（附录 §5），零 feed 改动。

---

## 1. 背景与约束

### 1.1 硬件画像（决定「适配」的物理盘面）

| 项 | 值 | 对 DDNS 选型的影响 |
|---|---|---|
| SoC | Airoha AN7581GT，4×1.3GHz arm64 + 8 核 NPU [R1] | 所有候选架构无关/有 arm64 构建；CPU 余量巨大 |
| 内存 | 2GB RAM [R1] | 常驻守护（inadyn/ddns-go）的内存开销可忽略 |
| 存储 | 512MB SPI-NAND（UBI/fitblk 布局）[R1] | 数十 KB~二十 MB 的包都放得下；ddns-go 的 ~15–20MB 也充裕 |
| 网络 | 2×10G（RTL8261BE）+ 2×1G（MT7530）[R1] | 多接口场景：PPPoE/10G WAN 的 IP 取址要灵活 |
| 系统 | openwrt master / kernel 6.18 / fw4 + odhcpd-ipv6only [R2] | IPv6 双栈是固件一等公民，DDNS 必须同步跟进制 |

### 1.2 仓库政策约束（决定「适配」的制度盘面）

1. **官方 feed 优先**：`config/feeds.custom.conf` 明示「外部包一律 src-git/src-git-full + 锁定 commit；升级显式 bump + 记 FIXES.md」[R2]。
2. **锁源铁律（F13）**：`PKG_SOURCE_URL` + 实算 `PKG_MIRROR_HASH`，禁止 fork、禁止 `hash=skip`——第三方二进制（如 ddns-go）进树需要自建 Makefile 且承担供应链审查成本 [R2]。
3. **包落地管线**：种子包必须写 `config/seed-config.diff`，由 `scripts/audit-config.sh` 审计（防 F15 式静默漏装）[R2]。
4. **滚动基线**：2h sync-upstream cron + 三档构建（stock/oc/experimental）——方案的**维护债必须 ≈ 0**，否则每次 master 漂移都付成本。
5. 调研先例：`docs/IP-EVAL-2026-08-23.md`（评估 → 转 FIXES 落地）；本文只完成前一半。

### 1.3 使用场景假设（若与你的实际不符请指出）

- 主路由形态：PPPoE/静态 IP 上联，LAN 侧双 10G + 双 1G，fw4 NAT + HW offload。
- **IPv6 双栈视为刚需**：大陆运营商公网 IPv4 常处 CGNAT，v6 公网是当下最可靠的外网入口；固件本身 v6 全链路（odhcpd-ipv6only、NPU v6 offload 已验 [R2]）。
- 域名可能在境外（Cloudflare 等）或境内（阿里云/腾讯云）注册，故按「全都要对比」处理。

---

## 2. 候选方案清单

| # | 方案 | 形态 | 官方 openwrt feed | LuCI/Web 界面 |
|---|---|---|---|---|
| A | **ddns-scripts**（+ ddns-scripts-services / -cloudflare / -nsupdate 子包 + luci-app-ddns） | BusyBox shell 脚本 + init 守护 | ✅ `net/ddns-scripts` [R3] | ✅ 官方 luci-app-ddns |
| B | **inadyn**（含 inadyn-openssl 变体） | C 守护进程 | ✅ `net/inadyn` [R5] | ❌ 无官方（第三方 luci-app-inadyn，非标准） |
| C | **ddclient**（+ luci-app-ddclient） | Perl 守护/cron | ✅ `net/ddclient` | ⚠️ 有 luci-app-ddclient（界面陈旧） |
| D | **ddns-go**（+ 社区 luci-app-ddns-go） | Go 静态二进制 + 自带 Web UI | ❌ 第三方（社区 feed/自建） | ✅ 自带 9876 Web UI（中文）[R4] |
| E | 传统自定义脚本（dnspod.sh 等）/ noip2 / cloudflared 隧道 | 手写脚本/二进制 | 混合 | 混合 |

> E 组定位说明：DNSPod 在 OpenWrt 上长期靠社区脚本（dnspod_script 系 [R6]）；cloudflared 是**内网隧道**而非 DDNS（不更新 DNS 记录，改走 Cloudflare 边缘），属于「公网可达」的另一个赛道，仅作边界提示，不进评分。

---

## 3. 多角度对比

> 评分标度 1–5；「对 XR1710G 的影响」列是本报告选型论证的主线——**硬件适配 = 物理盘面 × 制度盘面 × 功能盘面**。

### 3.1 角度一：资源占用与依赖（权重 5%）

| 方案 | 占用 | 依赖 | 对 XR1710G |
|---|---|---|---|
| ddns-scripts | KB 级脚本，更新时短命进程 | curl/wget + ca-bundle（seed 已含 `curl`、`jq` ✓） | 零压力；无常驻 |
| inadyn | 二进制约百 KB 级，常驻 RSS 约 1–3MB（需实测） | libopenssl 或 libgnutls（wpad-openssl 已带 openssl ✓） | 零压力 |
| ddclient | Perl 运行时 + 十余个 perl 模块，安装体积数 MB（需实测） | perl 全家桶，与固件其余部分零共享 | 跑得动但纯浪费 |
| ddns-go | 静态二进制 ~15–20MB、常驻 RSS ~10–30MB（需实测） | 无（Go 静态） | NAND 富余可接受；是最大的一块 |

**结论**：硬件充裕，此项只用来排除 ddclient 的「无谓负担」，不构成 ddns-go 的否决项。

### 3.2 角度二：提供商覆盖（权重 20%）

| 方案 | 境外（Cloudflare/No-IP/DuckDNS/HE.net/Freedns/DynDNS 系） | 中国内地 |
|---|---|---|
| ddns-scripts-services | ✅ 数十家内置；Cloudflare API v4 另有 `ddns-scripts-cloudflare` 子包（支持 proxy 开关）[R3][R7] | ✅ aliyun.com 服务已加入 ddns-scripts（commit e9c1321e [R8]；**以构建时 feed 源码为准**，若未带入可用 custom script 兜底）；3322.org（公云）在列；**DNSPod 无官方内置**，需社区脚本 [R6] |
| inadyn | ✅ 30+ 内置（dynv6、cloudflare、duckdns、no-ip、freedns、dnsomatic、he.net、dnsmadeeasy 等 [R5]） | ❌ 无 aliyun/dnspod 原生插件；只能 custom provider 模板硬凑 |
| ddclient | ✅ 老牌全（dyndns/no-ip/cloudflare…），云时代 API 类更新滞后 | ❌ 无原生 |
| ddns-go | ✅ Cloudflare/DuckDNS/No-IP/Google/Oracle/Vercel/Porkbun… | ✅ 最强：阿里云、腾讯云 DNSPod、华为云、百度云等 30+ [R4] |

**结论**：境外场景 A/B/C/D 都够；**境内场景 D（ddns-go）显著领先**，A 覆盖了阿里云但缺 DNSPod，B/C 基本不覆盖境内。

### 3.3 角度三：IPv4/IPv6 双栈与多接口/多域名（权重 20%）

| 方案 | IPv6 | 接口取址 | 多域名/多服务 |
|---|---|---|---|
| ddns-scripts | ✅ 原生（IPv6 开关 + ip_source：interface/network/url/script）[R3] | ✅ uci 绑定任意接口（wan/pppoe/custom） | ✅ 每 uci section 一服务，天然多域名 |
| inadyn | ✅ 2.x 支持 IPv6（checkip/接口）[R5] | ⚠️ 中等（接口取址能力弱于 A/D） | ✅ 多 provider 段 |
| ddclient | ⚠️ 弱（历史上 IPv4 为主，IPv6 依赖 provider 与版本） | ⚠️ 弱 | ✅ 多 config 段 |
| ddns-go | ✅ 原生双栈：选 v4/v6/双栈、接口正则、IPv6 前缀选项 | ✅ 接口正则（如 `eth0|pppoe`） | ✅ 多域名批量、多提供商并存 [R4][R7] |

**结论**：A 与 D 双栈最扎实；XR1710G 的双 10G + PPPoE 多接口场景，A 的 uci 接口绑定经社区多年验证（红米 AX6000 + Cloudflare 实践帖即用 ddns-scripts [R7]），D 的正则取址灵活度更高。

### 3.4 角度四：更新机制与可靠性（权重 15%）

| 方案 | 机制 | 可靠性特征 |
|---|---|---|
| ddns-scripts | uci 定时 + 事件/变更检测（2.8 系引入 monitor 机制，以当前 feed 版本为准）+ 失败重试 | 日志进 logread；TLS 校验走系统 curl/wget |
| inadyn | 常驻守护 + 定时（默认分钟级可调）+ IP 变更检测 + 自动重试 | 纯 C 单守护，崩溃重启由 procd 兜底 |
| ddclient | cron/守护定时轮询 | 依赖 perl + 外部命令，重试逻辑简单 |
| ddns-go | 定时（可调）+ **仅在 IP 变化时更新** + 失败重试 + webhook 通知 | 自带日志/通知（飞书/钉钉/Telegram 等）[R4] |

**结论**：四者的可靠性都达标；触发式（A 的事件监控、D 的变更检测）优于纯轮询。DDNS 是控制面流量（每分钟 KB 级），与 NPU offload/数据面性能**完全无关**，勿被「10G 性能」误导选型。

### 3.5 角度五：易用性与管理界面（权重 10%）

| 方案 | 界面 | 配置模型 |
|---|---|---|
| ddns-scripts + luci-app-ddns | ✅ 官方 LuCI：多 section 同页、状态/日志/测试按钮、中文翻译 | ✅ **uci**：进 `/etc/config`，sysupgrade 备份/恢复、uci-defaults 管线天然覆盖 |
| inadyn | ❌ 无官方 LuCI（第三方实现非标准） | ⚠️ `/etc/inadyn.conf` 手写（或文件管理器编辑） |
| ddclient | ⚠️ luci-app-ddclient 存在但界面陈旧 | ✅ uci |
| ddns-go | ✅ 自带 9876 Web UI（中文表单、测试、日志） | ⚠️ 自管存储（非 uci）：**sysupgrade 配置文件备份清单需手工加入**，否则刷机丢配置 |

**结论**：易用性 A ≈ D 领先；但 D 的「非 uci」与本固件的备份/回滚/ACL 体系割裂，是自用固件里一个**隐性运维成本**（需在 `/etc/sysupgrade.conf` 追认）。

### 3.6 角度六：上游维护与仓库适配成本（权重 25%——仓库政策刚性，最高权重）

| 方案 | 官方 feed | 锁源/供应链 | master 滚动适配 |
|---|---|---|---|
| ddns-scripts | ✅ [R3] | 官方包，随树 | 零成本 |
| inadyn | ✅ [R5]（troglobit 上游活跃） | 官方包 | 零成本 |
| ddclient | ✅ `net/ddclient` | 官方包 | 零成本（但上游低频） |
| ddns-go | ❌ 无官方 feed | **需自建 src-git-full feed + 锁 commit + 实算 PKG_MIRROR_HASH + FIXES 登记**；Go 二进制 vs 源码构建的供应链审查成本高 [R2] | 每次 bump 需重验，与仓库「官方优先 + 修复而非降级」理念张力最大 |

**结论**：仓库契合度 A ≈ B > C > D。若从「固件是滚动 master、每次升级都要干净」的盘面看，官方包方案是压倒性优势——这正是「最符合当前硬件/仓库」的核心判据。

### 3.7 角度七：安全与凭证管理（权重 5%）

| 方案 | TLS | 凭证 | 攻击面 |
|---|---|---|---|
| ddns-scripts | 系统 curl/wget + ca-bundle | uci 明文（root 可读） | 小（官方脚本） |
| inadyn | 编译期 TLS 库（openssl/gnutls 变体） | /etc/inadyn.conf 明文 | 小 |
| ddclient | perl + IO::Socket::SSL（历史配置坑多，近版已修） | conf 明文 | 中 |
| ddns-go | Go 自带 TLS 栈 | Web UI 明文可见 | 中：第三方二进制供应链 + 自带「在线升级」通道（需确认默认关闭） |

**结论**：官方包整体更稳；ddns-go 的便利附带供应链与凭证暴露权衡，自用可接受但应有意识。

### 3.8 角度八：扩展能力（RFC2136 自建 DNS / 通知 / 内网穿透边界）（不计权，补充）

- **RFC2136 + TSIG（自有权威 DNS）**：ddns-scripts → `ddns-scripts-nsupdate` 子包；inadyn → 内置 nsupdate 插件；ddns-go → 无。
- **通知**：ddns-go 的 webhook（飞书/钉钉/Telegram）是独有加分；ddns-scripts/inadyn 只有日志。
- **边界**：需要「公网暴露 HTTP 服务且不想开端口」→ cloudflared/DDNSTO 隧道是另一赛道，与 DDNS 不互斥、也不可互换。

### 3.9 角度九：社区实践与口碑（不计权，佐证）

- ddns-scripts + Cloudflare 在 OpenWrt 社区有稳定实践帖（红米 AX6000 长期运行）[R7]。
- ddns-go 是国内软路由社区主流方案之一（恩山 luci-app-ddns-go 帖：支持阿里/腾讯/华为/百度等 8+ 家 [R4]；知乎 IPv6+DDNS 实践 [R9]）。
- inadyn 是 OpenWrt 论坛常被推荐的轻量守护方案 [R5]。
- DNSPod 在 OpenWrt 上的官方空白由社区脚本填补（dnspod_script 系 [R6]）。

---

## 4. 综合评分与结论

权重（适配 XR1710G + 本仓库）：仓库适配 25% > 提供商覆盖 20% = IPv6 双栈 20% > 可靠性 15% > 易用性 10% > 资源 5% = 安全 5%。

| 角度（权重） | A ddns-scripts | B inadyn | C ddclient | D ddns-go |
|---|---|---|---|---|
| 资源与依赖（5%） | 5 | 5 | 2 | 3 |
| 提供商覆盖（20%） | 4（缺 DNSPod） | 3（缺国内） | 3 | 5 |
| IPv6 双栈（20%） | 5 | 3.5 | 2 | 5 |
| 更新机制与可靠性（15%） | 4.5 | 4.5 | 3.5 | 4.5 |
| 易用性（10%） | 4.5 | 2.5 | 3 | 4.5 |
| 仓库适配（25%） | 5 | 4.5 | 4 | 2 |
| 安全（5%） | 4.5 | 4.5 | 3.5 | 3.5 |
| **加权总分** | **4.65** | **3.83** | **3.10** | **3.95** |

> 打分含主观权重，但排序对权重扰动不敏感：A 在「仓库适配」这一决定性维度上遥遥领先，D 仅在纯功能维度胜出。若未来落地时**仓库政策放宽**（接受第三方 feed），D 可升为与 A 并列。

### 分场景推荐

| 场景 | 推荐 | 理由 |
|---|---|---|
| **默认/通用（推荐）** | **A：ddns-scripts + ddns-scripts-services + luci-app-ddns** | 官方全链路、uci、IPv6 成熟、境外全覆盖、阿里云可用；零维护债，与主路由固件形态一致 |
| 境内重度（阿里云/腾讯云 DNSPod 多域名、要 Web UI） | **D：ddns-go**（自建 feed + 锁源 + FIXES 登记） | 提供商与双栈覆盖最强、自备中文 UI；接受第三方二进制与 ~20MB 体积 |
| 境内但有阿里云域名即可 | A + 内置 aliyun.com 服务（不够再落 D） | 能官方就官方 |
| 极简/无 UI 洁癖/资源最抠 | **B：inadyn** | 官方包、C 守护、稳定轻量；代价是手写 conf、国内提供商弱 |
| 自建权威 DNS（RFC2136） | A + ddns-scripts-nsupdate，或 B 的 nsupdate 插件 | 唯二原生支持 TSIG 的方案 |
| **明确不选** | **C：ddclient** | Perl 重依赖、IPv6 弱、上游放缓，无任何维度的不可替代性 |

### 对「当前硬件」的最终判断

XR1710G 是一台**资源过剩、但制度约束严格（官方优先 + 锁源 + 滚动 master）的自用固件平台**。因此：

1. 选型不按「最省资源」而按「**最高适配度**」——官方 feed 方案天然胜出；
2. 硬件（arm64、2GB 内存、512MB NAND、多接口、IPv6 全链路）对 A 与 D 均无任何障碍；
3. 结论：**`ddns-scripts` 官方组合是本硬件与仓库的最优解**；`ddns-go` 作为境内重度的功能最优解保持备选；`inadyn` 是轻量审美下限；`ddclient` 出局。

---

## 5. 落地记录与剩余项

- **方案 A（已落地，2026-09-08）**：`config/seed-config.diff` 已加入 `CONFIG_PACKAGE_ddns-scripts=y`、`CONFIG_PACKAGE_ddns-scripts-services=y`、`CONFIG_PACKAGE_luci-app-ddns=y`（按需取消注释 `ddns-scripts-cloudflare` / `ddns-scripts-nsupdate`）。零 feed、零补丁改动；下次构建（audit-config.sh）后实机验证 LuCI「服务 → 动态 DNS」菜单与三包在位。
- **方案 D（未落地）**：`config/feeds.custom.conf` 增 `src-git-full ddns-go <repo>^<commit>`（或自建 Makefile 源码构建）；实算 `PKG_MIRROR_HASH`；FIXES 登记升级通道；`/etc/sysupgrade.conf` 追认 ddns-go 配置目录；评估二进制供应链（F13 同款审查）。
- **验收建议（并入 docs/ACCEPTANCE.md）**：IPv4/IPv6 双记录更新与解析生效、重启/wifi down-up 后自动恢复、IP 变化触发而非纯轮询、日志无凭证泄露。

---

## 6. 参考资料

- [R1] 本仓库 `CONTEXT.md`（硬件画像：AN7581GT / 2GB RAM / 512MB NAND / 2×10G+2×1G / MT7996 三频）
- [R2] 本仓库 `config/seed-config.diff`、`config/feeds.custom.conf`、`docs/FIXES.md`（F13 锁源铁律）、`docs/patches/README.md`（官方优先/滚动基线）
- [R3] OpenWrt 官方包仓库 `net/ddns-scripts`（含 services 定义与子包）：https://github.com/openwrt/packages/tree/master/net/ddns-scripts ；OpenWrt 官方 DDNS 文档：https://openwrt.org/docs/guide-user/services/ddns/client
- [R4] ddns-go 上游：https://github.com/jeessy2/ddns-go ；恩山 luci-app-ddns-go 帖（支持阿里/腾讯/华为/百度等 8+ 家）：https://www.right.com.cn/forum/forum.php?mod=viewthread&tid=8258107
- [R5] inadyn 上游（providers 列表 / IPv6 / nsupdate）：https://github.com/troglobit/inadyn ；官方 feed 存在性：https://git.cdn.openwrt.org/?p=feed/packages.git;a=tree;f=net/inadyn
- [R6] DNSPod 在 OpenWrt 无官方内置、靠社区脚本（dnspod_script 系）：https://blog.csdn.net/gianttj/article/details/150759455 ；恩山相关讨论：https://www.right.com.cn/forum/forum.php?mod=viewthread&tid=5247186
- [R7] 社区实践：红米 AX6000 + Cloudflare DDNS 基于 ddns-scripts 的长期稳定实现：https://www.right.com.cn/forum/thread-8488359-1-1.html
- [R8] ddns-scripts 增加 aliyun.com 服务的提交（openwrt/packages 镜像）：https://git.nju.edu.cn/nju/openwrt-packages/-/commit/e9c1321e8bc7218521663f61d842b223c7d1824d
- [R9] IPv6 公网 + ddns-go 的国内实践：https://zhuanlan.zhihu.com/p/702950333 ；https://www.toutiao.com/article/7682366519426204175/

---

*本报告为调研产物；落地（seed/feed 变更）需另行决策并按仓库政策登记。*