# 2026-09-11 代理数据面实机 A/B（S0→S1→S2）与净身归还

> 上游：`plan/04-验收与测试矩阵.md` §T3（A/B）与 §T4（净身归还）、`plan/README.md` G1/G4
> 性质：**运行期**探针（不刷机、不改 `flow_offloading*`、不写 NAND）。方法 = 把包文件临时部署到设备、
> 走 `init.d start/stop`，逐步采集并在结束时回收。
> ⚠️ 本文件同时是"我在设备上留下了什么"的清单（见 §6），供后续处置。

---

## 1. 目的与判据

| 判据 | 目标 |
|---|---|
| G4 · 默认关闭 | `enabled=0` 时**无 nft 表、无 ip rule、无进程**、不建运行态目录 |
| S1 · 建态正确 | 表/集合/链、`fwmark 0x40/0x40 table 100`、`default dev <tun>` 全部就位 |
| T4 · 净身归还 | `stop` 后 `nft list ruleset` 与 `ip rule show` 回到基线（**结构逐字节**） |
| 他人状态免疫 | Tailscale 的 `0x80000/0xff0000` 规则与 table 52 路由**一条不少** |
| G1 · 卸载点不动 | 基线里 fw4 的 `flow add` / `flowtable` 结构条目数全程不变 |

## 2. 方法学：为什么必须做 **counter 归一化**

第一次 diff 得到 22 行差异，逐行核对后**全部**是 `packets N bytes N` 计数器的自然增长，
发生在**本组件不拥有**的既有链上（fw4 的 `DNS-lan53`、`accept lan IPv4/IPv6 traffic`、
Tailscale 的 `ts-forward`/`ts-input`/`ts-postrouting`）：

```
<  udp dport 53 counter packets 32186 bytes 2707474 accept comment "!fw4: DNS-lan53"
>  udp dport 53 counter packets 32189 bytes 2707752 accept comment "!fw4: DNS-lan53"
```

⇒ 直接 `diff nft list ruleset` 在**活体设备上恒不可能为空**。T4 的正确判据是
**归一化后比对**（抹掉 `packets/bytes`、`expires`，只留结构）：

```sh
nft list ruleset | sed -e 's/packets [0-9]* bytes [0-9]*/packets N bytes N/g' \
                      -e 's/counter packets N bytes N/counter/g' \
                      -e 's/expires [0-9]*sec/Nsec/g'
```

这一条应回写进 `plan/04` §T4（原文写的是"逐字节一致"，在活体设备上不可达）。

## 3. 结果

设备：`Linux xr1710g 6.18.44`，`nftables v1.1.6`，busybox `ip`。

### S0（基线，`enabled=0`）

| 项 | 值 |
|---|---|
| `nft list ruleset \| norm \| md5` | `a859756c13b1e540af15196a3e68bc13` |
| `ip rule show \| md5` | `34b0c094847eaddbb6dc1c5c7c055209` |
| `table 100` | 不存在 |
| `nft list table inet xr1710g_proxy` | 不存在 |
| 运行态目录 `/tmp/xr1710g-proxy` | 不存在 |

**G4 顺带取证**：把 `enabled=0` 的配置放上去后 `init.d start` 直接 `exit 0` 并落日志
`enabled=0，不启动（I4）`——无表、无规则、无目录、无进程。

### S1（`enabled=1`，名单 = `192.168.123.224`，TUN 用已存在的 `tailscale0` 代替）

```
表存在: YES
rule100=1  route100=1
mark 规则数: 2              （ip saddr @proxy_hosts4 / ip6 saddr @proxy_hosts6 → meta mark set 0x40）
dns redirect: 2             （v4/v6 → redirect to :5333）
名单 v4 元素: 1
fw4 卸载点结构条目: 4        （与基线相同）
```

实际落地的表（`nft list table inet xr1710g_proxy` 摘录）与模板一致：

```
set proxy_hosts4 { elements = { 192.168.123.224 } }
set proxy_hosts6 { elements = { 2001:db8::1 } }        # 空名单占位（集合必须可被引用）
set china_ip4    { elements = { 192.0.2.2 } }          # 占位：本次未部署 CN 快照
chain dns_redirect { ... redirect to :5333 }
chain capture {
    ip  saddr @proxy_hosts4 ip  daddr @china_ip4 accept
    ip6 saddr @proxy_hosts6 ip6 daddr @china_ip6 accept
    ip  saddr @proxy_hosts4 meta mark set 0x00000040
    ip6 saddr @proxy_hosts6 meta mark set 0x00000040
}
```

`ip rule` / `ip route`：

```
5209:	from all fwmark 0x40/0x40 lookup 100
default dev tailscale0 scope link          (table 100)
```

### S2（`stop`）

```
表残留=0  rule100=0  route100=0  rundir=0
nft 结构: IDENTICAL   (a859756c… → a859756c…)
ip rule : IDENTICAL   (34b0c094… → 34b0c094…)
他人: tailscale mark=3  table52=7   （与基线相同）
```

⇒ **T4 通过**：结构逐字节一致，他人条目一条不少。

## 4. 本轮修掉的四个真缺陷（都由实机 A/B 抓出，非推测）

| # | 缺陷 | 症状 | 修复 |
|---|---|---|---|
| D1 | **UCI 包名不得含连字符** | 配置文件名为 `xr1710g-proxy` 时，`uci show xr1710g-proxy`（带连字符）能列出，但 `uci -q get xr1710g_proxy.global.enabled`（下划线，即 init/前端实际使用的名字）报 `Entry not found` ⇒ **服务永远起不来**，而日志只会说"enabled=0" | 配置文件重命名为 `files/etc/config/xr1710g_proxy`（下划线）。**这是最隐蔽的一个**：文件能 load、`uci show` 有输出，只有用下划线寻址才暴露 |
| D2 | **`local -x` 不被 busybox ash 支持** | `stop` 报 `local: line 68: -x: bad variable name`，`stop_service` **整条中止** ⇒ 表、rule、route 全部残留 | `route_drop()` 改 `local ... m`（不加 `-x`；该变量只需要普通作用域） |
| D3 | **TUN 就绪顺序反了** | `conflict_check` 里 probe `ip route add default dev <tun>`，而此时 TUN 尚不存在（它由 sing-box 启动时创建）⇒ **启动永远被自己的冲突检测拒绝**（日志："无法向 table 100 安装 default dev singtun0"） | 顺序改为「起 sing-box → `tun_wait` 等 TUN 就绪 → `route_install`」；probe 只装 rule（rule 不依赖 TUN），route 的安装+失败处理移到 TUN 就绪之后，并**装完立刻回读验证** |
| D4 | **后台辅助进程继承会话 stdio** | guard / 定期更新子 shell 持有调用方（SSH 会话）的 stdin ⇒ **SSH 等到子 shell 结束才返回，会话挂死**（A/B 脚本 60s 超时被杀） | 两处后台子 shell 均加 `</dev/null >>log 2>&1` |

> D1/D2/D3 都是"静态测试全绿、实机一跑就死"的类型。这正是 `plan/04` §T3 存在的意义。

## 5. 本轮**未能**完成的实机项（如实登记）

| 项 | 为什么没做 | 现状 |
|---|---|---|
| 真实 sing-box 端到端 | 设备无法访问 GitHub（`codeload` 连接超时），无法在设备上取到官方 arm64 二进制；SSH 管道传 85 MB 二进制缺少设备侧解码器（无 `base64`/`python3`） | 用**忠实替身**（长驻 + 接受 `-c`）验证了"我们自己的状态处理"；**真实配置 schema** 已由 `scripts/test-proxy-package.sh` 用 sing-box **1.14.0** 官方 amd64 二进制 `check` 通过（36 项） |
| CN 快照（6253+3459 条）装入内核集合 | 未把 snapshot 部署到设备的 `/usr/share/xr1710g-proxy/` | 已验证：空集合用占位元素后表可正常载入并 `nft -c` 通过；列表本身的"零重叠/零非法"由 `validate-cidr.py` 离线证明（见 `plan/evidence/cn-list/`） |
| G1 定量（`ppe/bind` 计数 + iperf3 ≤2%） | 需要真实流量与时间窗；本次只观测到计数器自然波动（8↔14），**不足以作为结论** | 只完成了**结构性**判据：fw4 的 `flow add`/`flowtable` 条目数全程为 4 未变；`plan/04` §3.2 的定量判据仍待刷机后执行 |
| fail-open 演练（`kill -9 sing-box`） | 依赖真实 sing-box 进程（替身被 kill 也能触发，但意义有限） | 逻辑已实现（`guard_loop` + 撤表），待刷机后按 §T3.3 演练 |
| `apk add` 路径 | 已证不可行（F92：`no such package`） | 不需要再验 |

## 6. ⚠️ 设备遗留清单（本轮在设备上留下的东西）

**网络状态已完全归还**（表/规则/进程/运行态目录全清，见 §3 S2），
但以下**文件**留在了设备上。它们都**不生效**（`enabled=0`，服务未启用、无开机自启），
但仍应在刷机前清理或知悉：

| 路径 | 内容 | 影响 |
|---|---|---|
| `/usr/bin/sing-box` | **替身脚本**（不是真二进制；只为 A/B 测试进程生命周期） | ⚠️ **必须删除**：否则以后装真 sing-box 会被它占位 |
| `/etc/config/xr1710g_proxy` | 测试配置（`enabled=0`） | 无（默认关闭）；刷机也会清 |
| `/etc/init.d/xr1710g-proxy` | 本包 init | 未 enable，不随开机启动 |
| `/usr/libexec/xr1710g-proxy/{render.sh,cn-list.sh,validate-cidr.py}` | 本包脚本 | 无 |
| `/usr/share/xr1710g-proxy/template.nft` | nft 模板 | 无 |
| `/tmp/{ab-0,ab-2}.{nft,rule}`、`/tmp/n0.md5`、`/tmp/r0.md5`、`/tmp/norm.sh`、`/tmp/probed`、`/tmp/sbchk` | 测试中间产物 | 无（tmpfs，重启即失） |
| `/etc/config/zz-*`（若还有） | UCI 命名可行性探针 | 无 |

> 清理命令（**未执行**，交由用户决定——用户已明确要求不再操作设备）：
> ```sh
> rm -f /usr/bin/sing-box /etc/config/xr1710g_proxy /etc/init.d/xr1710g-proxy \
>       /usr/libexec/xr1710g-proxy/render.sh /usr/libexec/xr1710g-proxy/cn-list.sh \
>       /usr/libexec/xr1710g-proxy/validate-cidr.py /usr/share/xr1710g-proxy/template.nft
> rmdir /usr/libexec/xr1710g-proxy /usr/share/xr1710g-proxy 2>/dev/null
> rm -rf /tmp/xr1710g-proxy /tmp/ab-* /tmp/n0.md5 /tmp/r0.md5 /tmp/norm.sh /tmp/sbchk
> ```
> 注意：`/etc/config/xr1710g_proxy`、`/etc/init.d/xr1710g-proxy`、`/usr/share/xr1710g-proxy/*`、
> `/usr/libexec/xr1710g-proxy/*` 在**正常安装本包后本来就该存在**，所以清理与否取决于
> 用户是否打算保留这次运行期安装。

## 7. 结论

- **G4（默认关闭）成立**：`enabled=0` 确实什么都不做，且负向路径（无 sing-box、fwmark/table 冲突）都拒绝启动且不留半配置；
- **T4（净身归还）成立**：`stop` 后 nft 结构与 ip rule 逐字节回到基线，Tailscale 条目零损伤；
- **G1（卸载点不动）结构层面成立**：fw4 的 `flow add`/`flowtable` 条目数全程恒定；**定量层面待刷机**；
- 本轮共修 4 个实机缺陷（§4），其中 D1（UCI 包名连字符）会导致**功能完全不可用**，静态测试无法发现。
