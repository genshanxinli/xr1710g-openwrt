# 方案文档集 — XR1710G 代理与组网落地

> 目标分支：`feat/proxy-dns-stack`（基于 `main`，`xr1710g-openwrt` 叠加层仓库 @ `df3b12e`）
> 目标设备：Gemtek **XR1710G**（Airoha AN7581GT + MT6996/MT7996 BE19000，4×Cortex-A53 @650–1350 MHz，2 GB RAM / 512 MB SPI-NAND，kernel 6.18.44，apk-tools 3）
> 文档状态：**待评审**（评审通过后进入实现；实机刷机由用户执行，实施方不刷机）

---

## 0. 北极星

**为** 这台「内存富余、只读固件卷极紧、硬件卸载是核心资产」的 Wi-Fi 7 主路由 **在** 必须保住 PPE/NPU 硬件卸载与 2×10G 能力的处境下 **达成**：

> 代理与组网能力可按需开启；**开启 / 关闭 / 启动失败都不影响正常网络的硬件加速**；默认不开启、默认不给固件正常功能增加任何负担。

## 1. 组级成功判据（全绿才算收官）

| # | 判据 | 测量方式 |
|---|---|---|
| G1 | **offload 不变量成立** | 开/关 `xr1710g_proxy`，非名单客户端的 `cat /sys/kernel/debug/ppe/bind \| wc -l` 与 LAN↔WAN iperf3 吞吐无实质差异（≤2%）；`uci show firewall \| grep offload` 全程不变 |
| G2 | **运行期零 flash 写入** | 启用后 24h `du -sb /overlay/upper` 差值 ≤ 噪声（运行态全在 `/tmp`；CN 名单快照在只读 squashfs） |
| G3 | **内核态 WireGuard 落地** | `netbird status -d` 报 `Interface type: Kernel`；`ip rule show` 含 `not from all fwmark 0x1bd00 lookup netbird` |
| G4 | **默认关闭且失败无影响** | 全新刷机后 `enabled=0`：无 nft 表、无 ip rule、无进程、无 uci-defaults 接管；`kill -9 sing-box` 后非名单客户端全程无感 |

## 2. 三个方案一句话定位

| 方案 | 定位 | 一句话结论 |
|---|---|---|
| **方案一** | 官方 `sing-box` 核心 + 自写内核 `china_ip` 放行集合 + 自写极简 LuCI | 今天就能做：**零新 kmod 依赖**（`kmod-tun` 已内置）；offload 不变量成立 |
| **方案二** | `netbird` 内核 WireGuard + NEON 内核加解密 | 硬要求「必须显示内核态 WG」⇒ 先解供给链（自建 kmods feed / 预装 `kmod-wireguard`）；**隧道流量注定走 CPU，PPE/NPU 帮不上**，NEON 是唯一能改善的杠杆 |
| **方案三** | 「AdGuardHome + mosdns + 代理」三板斧 | **裁决为不合理**：功能重叠 × 结构性冲突 × 双倍故障域；只出 ADR + 证据，不落地 |

## 3. 已定决策（不再讨论）

| # | 决策 | 说明 |
|---|---|---|
| D1 | 分支 `feat/proxy-dns-stack`，基于 `main` | 推送 `origin`（`genshanxinli/xr1710g-openwrt`）并开 PR，用户刷机验证后再合 `main` |
| D2 | 方案一前端 = **自写极简 LuCI**（放 `packages-xr1710g/`） | **不引 homeproxy**：它硬依赖 `kmod-nft-tproxy`，且 `routing_mode=bypass_mainland_china` 把 CN 判定放用户态，与硬基准冲突 |
| D3 | 分流架构 = **架构 C**（内核层判定 + 名单客户端作用域 fake-ip） | 与架构 A 在 offload 上**逐字节等价**；代理侧性能更好（详见 §5 与 `04`） |
| D4 | 固件布局 = **扩容 `fit` 卷 + 预装封闭清单** | 机制 = HTTP U-Boot 恢复页自动 `ubi_resize_volume`；**不新增 installer、不改 DTS、不硬编码容量** |
| D5 | 供给链 = CI 把 **kmods + 自建包**发布为 GitHub Release 附件 | 设备加 `/etc/apk/repositories.d/customfeeds.list` |
| D6 | 预装封闭清单 | `kmod-wireguard` / `kmod-ipset` / `kmod-ipt-ipset` / `kmod-tun` / `kmod-nft-tproxy` / `sing-box` / `netbird`(自持提版 0.78.1) / `luci-app-xr1710g-proxy` + 一套实机排障工具 |
| D7 | **NEON** = ARM NEON SIMD 内核加密（不是独立项目/包） | 给 airoha target 开 `CONFIG_ARM64_CRYPTO` + 三项 NEON，**先入 `#EXP`**，A/B 实测后决定是否毕业 |
| D8 | issue #7 护栏 | 9036/9037 **保持 `#EXP`**，本分支不毕业；改为**硬性禁止任何代码路径写 `flow_offloading*`** |
| D9 | 验收方式 | 允许实机运行期安装/卸载 + A/B；**先备份全量 uci、留一键回滚**；绝不碰 flash、绝不刷机 |
| D10 | 方案三交付形态 | **只出 ADR + 带证据裁决文档**，不落地任何 DNS 组件 |

## 4. 事实基线（均已实机 / 源码核实）

| # | 事实 | 来源 |
|---|---|---|
| F1 | `fit` 卷 **206 LEB = 24.94 MiB**，镜像 **24.91 MiB** ⇒ **余量 32 KiB**；`rootfs_data` 3195 LEB → UBIFS **355.4 MiB**（空闲 350.6 MiB）；`available logical eraseblocks: **0**` | 实机 `ubinfo -a` / `df` / `dmesg FIT:`；`research/APP-FIT-ROUND2-2026-09-11.md` §1.1 |
| F2 | HTTP U-Boot 恢复页**自行重建/缩放 UBI 卷**：`recovery_resize_ubi_target()` → `ubi_resize_volume(DIV_ROUND_UP(image_size, usable_leb_size))`；`recovery_ensure_rootfs_data()` 以 size=0 吃掉剩余 PEB | `YYH2913/http-uboot` `net/lwip/httpd_recovery.c`（本次取证） |
| F3 | 恢复页**只保留 `ubootenv`/`ubootenv2`/`factory`**（XR1710G），**其余卷（含 `rootfs_data`）全部 `remove`** ⇒ **每次恢复页刷固件都会清空 overlay/配置** | 同上，`recovery_preserve_ubi_volume()` / `recovery_cleanup_ubi_firmware()` |
| F4 | 布局选择器 = `{ "2.0","ubi" }, { "1.5","ubi1.5" }, { "1.0","ubi1.0" }` ⇒ 本机必须选 **UBI 2.0** | 同上 `recovery_ubi_layouts[]`；`docs/FLASHING.md` A3.4 |
| F5 | 运行期装 kmod 被封：官方 kmods 目录是 `6.18.44-1-6297b246…`，本机 `228d96fa…`，`apk` 在依赖解析阶段直接 ERROR | 实机 `apk`；`research/APP-FIT-ROUND2-2026-09-11.md` §1.2 |
| F6 | 设备已有 `kmod-tun`、`kmod-nft-offload`、`nft_redir/nft_nat/nft_masq/nft_flow_offload`；**没有** `nft_tproxy` / `wireguard` / `ipset` | 实机 `/lib/modules/$(uname -r)/` |
| F7 | `dnsmasq 2.93` 编译含 `--nftset`、**无** ipset；`nftables 1.1.6` 支持 `flags interval` | 实机 `dnsmasq --help` / `nft -v` |
| F8 | 默认 `flow_offloading=1` + `flow_offloading_hw=1`；`flow_offloading_hw` 1→0→1 + `fw4 reload` 曾致整机无声重启（issue #7 / F34），护栏 9036/9037 仍是 `#EXP` | `files/etc/uci-defaults/99-xr1710g-flow-offload`；`docs/analysis-issue7-flow-offload-reboot.md`；`patches/MANIFEST` |
| F9 | `ip rule` 已被 Tailscale 占用 `0x80000/0xff0000` + table 52；sing-box TUN 默认 table 2022 / rule 9000 / mark `0x2023-0x2026` mask `0x2007` | 实机 `ip rule show`；`research/NetBird方案深度调研-2026-09-11.md` |
| F10 | 官方 feed 有 `sing-box 1.14.0`、`netbird 0.73.2`（正是 #6953 内存泄漏版本）、`adguardhome`；**无** `homeproxy`/`mosdns`/`mihomo`/`nikki` | 实机 `apk search`；`research/feeds/*.json` |
| F11 | `/proc/cpuinfo` = `fp asimd evtstrm crc32 cpuid`（无 AES/SHA 扩展）；EIP93 未注册 chacha20/poly1305 ⇒ **WireGuard 永远拿不到硬件加密** | 实机；`research/PROXY-CRYPTO-EIP93-2026-09-10.md` |
| F12 | 设备存在 09-09 事故遗留 `/etc/config/mosdns`、`/etc/config/nikki`（`enabled=0`）与 3 个 `nikki.bak.*` | 实机 `ls /etc/config` |

## 5. 架构 C 与架构 A 的取舍（性能口径）

**硬件加速上两者完全相同——不是「差不多」，是逐字节相同。** 决定 offload 的只有两件事：**判定在哪一层**、**抓哪些流进用户态**。两者都是「内核 nft：`@proxy_hosts` 且目的 ∉ `@china_ip4` → 抓；其余走原 `forward` → `flow add @ft`」。fake-ip 只是 DNS 应答，**不是路由机制**，进不了这个判定。

⇒ 两架构下 `cat /sys/kernel/debug/ppe/bind | wc -l` 必须是**同一个数**（可直接作为验收判据）。

能区分 A / C 的只有代理侧软件性能，那里 **C 全面更好**：

| 代理侧指标 | A（真实 IP） | C（名单客户端 fake-ip） | 判定 |
|---|---|---|---|
| 每连接用户态开销 | 必须 **sniff** TLS ClientHello 才知道域名 | 目的 IP 即 fake-ip，**查表即得域名，零嗅探** | C 优 |
| DNS 首答（非 CN） | 每次等真实上游 | **直接合成 198.18.x，不等上游** | C 优 |
| UDP/QUIC 分流 | 只能 sniff，ECH 场景失效 → 退 IP 规则 | 域名→fake-ip 映射，**精确** | C 优 |
| PPE/NPU 卸载 | 同一抓取集合 | 同一抓取集合 | **平手** |
| 加密吞吐 | 同 | 同 | **平手** |
| 故障域 | 无新增 | 名单客户端多一个 DNS 依赖（需 guard） | A 优 |

**结论：按性能优先 → 架构 C。**

## 6. 假设（若不成立请纠正）

1. 设备凭据沿用 `root@192.168.123.1` / `password`；实施方在实机只做运行期安装/卸载与只读探针，**不刷机、不动 `flow_offloading*`**。
2. 「极简 LuCI」= 总开关 + 名单编辑 + 更新按钮 + 只读状态；不做订阅导入/节点管理。
3. 方案一 v1 **只支持按客户端名单（`proxy_hosts`）分流**；「按目的地全量分流 + 不限定来源」明确不做（研究 §9.3 反模式 ②）。
4. 预装 netbird 只是「在固件里可用」，**默认不启用、不加入任何 zone 的默认转发**。
5. 文档集按方案拆分，评审时可再合并/拆分。

## 7. 索引

| 文件 | 内容 |
|---|---|
| `plan/00-总纲-架构与供给链.md` | 架构总图、对外接口与数据模型、**硬约束不变量**、布局扩容机制、kmods feed、边界与失败模式、风险 |
| `plan/01-方案一-内核态分流代理.md` | sing-box + 内核 CN 放行 + 极简 LuCI 的实现分解 |
| `plan/02-方案二-netbird内核WG与NEON.md` | 内核态 WireGuard + NEON 的实现分解与吞吐现实 |
| `plan/03-方案三-DNS方案裁决.md` | 「ADG + mosdns + 代理」的裁决与证据 |
| `plan/04-验收与测试矩阵.md` | T0–T5 测试步骤、判据数值、回滚与净身归还 |
| `plan/05-决策记录与取证索引.md` | 三轮质询的问答归档 + 全部证据出处（file:line / URL） |
