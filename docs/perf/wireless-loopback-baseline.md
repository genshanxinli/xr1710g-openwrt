# 无线单机环回基线 — 可行性判定（结论：不可行），2026-11-20

本文件原本要给 **#13（perf baseline）** 与所有 Wi-Fi 类 issue（#43/#47/#48/#50/#53/#66/#68/#89）
提供一条**真实空口**的吞吐基线。实测结果推翻了那条路径：**在本固件 + mt7996 上，
同一 wiphy 内没有任何 VIF 能连上/加入由自己承载的 BSS**。所以本文件交付的是**判定与证据**，
不是吞吐数字。**没有编造任何测量值。**

## 结论摘要

1. **判定**：单机 AP+STA（以及 IBSS、mesh 两种替身）环回在这个硬件上**不成立**。
   根因不是「半双工吞吐减半」，而是**射频收不到自己发出去的帧**：6 GHz 段 20 s 内 AP
   `tx_packets` 按 beacon 速率稳定增长，而同一 netdev 的 `rx_mpdu_cnt` **恒为 0**，
   且该频段 `ch_time_busy / ch_time` = 12187/3168908 ≈ **0.4%**（介质几乎无第三方流量）。
   若存在自收，20 s 至少应见 ~200 个 rx MPDU。见 §4.1。
2. **实测**（决定性对照）：同一条 STA VIF、同一信道、同一个 radio，
   `iw auth` 打向**邻居真实 AP** 成功（dmesg `send auth` / `authenticated`，`sta_state=2`，
   `tx_packets=1`、`rx_packets=14`）；打向**自己的 AP** 直接
   `command failed: No such file or directory (-2)`，计数器全零。
   即：STA 的发射/接收路径本身可用，**缺的是「自己的 AP 在自己的扫描结果里」**。
   同一 VIF `scan freq 2437` 看到 7 个邻居 BSS，自己 BSSID `00:58:28:d7:44:5f` **出现 0 次**。
3. **实测**（跨 band 也被组合约束堵死）：`iw phy phy0 info` 的 per-radio 组合为
   `#{ AP, mesh point } <= 16, #{ managed } <= 19, total <= 19, #channels <= 1, STA/AP BI must match`。
   `#channels <= 1` 意味着「6 GHz AP + 5 GHz STA」这条更干净的跨 band 环回**不存在**；
   全局组合虽然写 `#channels <= 3`，但它是跨 radio 的总量约束，不能放宽单 radio 的 1 信道限制。
4. **实测**：managed VIF 无法显式锁信道 —— `iw dev <sta> set freq 5745 80 5775` 与
   `set freq 2437` 一律 `command failed: Resource busy (-16)`；即便把三个 AP 全部禁用、
   一个 VIF 不剩，仍然 `-16`。所以「先锁信道再 connect，避开扫信道冲突」这条也走不通。
5. **代码**：mac80211 不允许两个 IBSS VIF 同时 up（`package/kernel/mac80211/patches/subsys/`
   之外的 backports 源码 `net/mac80211/iface.c`：`Allow only a single IBSS interface to be up at any
   time…` → 第二个 `ip link set up` 返回 `SIOCSIFFLAGS: Resource busy`）。IBSS 自连替身因此只能
   单边存在，形成不了两个端点。
6. **方法学发现**：`iw` 侧 `connect` 返回 0 完全不等于关联发生。判据必须是
   `ethtool -S <vif>` 的 `sta_state` / `channel` / `tx_mpdu_attempts` 与**自己 AP 的
   `station dump`**。本轮的 `connect_rc=0` 全部伴随 `sta_state=0 channel=0 delta=0`，
   见 §4.2。标签、返回码都不可信。
7. **缺失**：本固件**没有 iperf3**（r38047 侧载失败，见 §2），所以即使环回成立也没有现成的
   打流工具；真 `-R` 方向断言、`aql`/`hw-queues`/`npu_rro` 的对照读数本轮**都没有取得**，
   因为没有可测量的环回链路。Wi-Fi 类 issue 的空口数据在**当前硬件条件下无法获得**。

## 设备与环境

| 项 | 值 |
|---|---|
| 固件 | OpenWrt SNAPSHOT `r38047-a86ce12e27`（`DISTRIB_TARGET='airoha/an7581'`，`DISTRIB_TAINTS='no-all'`） |
| 内核 | `Linux 7.3 #0 SMP PREEMPT Fri Nov 20 04:04:01 2026 aarch64 GNU/Linux` |
| 温度 | `thermal_zone0=42300`（42.3 °C） |
| 射频 | 单 wiphy `phy0`（`0000:01:00.0` mt7996e），三 band：2400–2500 / 5000–5900 / 5900–7200 |
| AP VIF | `phy0.0-ap0` ch6 2437 EHT20 28 dBm；`phy0.1-ap0` ch149 5745 EHT80 28 dBm；`phy0.2-ap0` ch37 6135 320 MHz 30 dBm |
| 监管 | `country US`；三个 VAP 均无 station 关联（`station dump` 三处都是 0） |
| 桥 | `br-lan` = `phy0.2-ap0` + `phy0.1-ap0` + `phy0.0-ap0` + `lan2/3/4`，`lan` = 192.168.1.1/24 |
| 工具 | `iw` 6.17、`ethtool`、`wpa_supplicant` v2.12、`hostapd`/`wpad`；**无 `iperf3`**、无 `jq`、无 `tcpdump` |
| 配置指纹 | `md5sum /etc/config/wireless` = `85043fdce72207d89b6fe1912acaecc9`；`/etc/config/network` = `cebd3f38885faf8b58567aea1db817de` |

## 为什么必须走单机环回

开发机是 WSL2，网卡 `virtio_net`（`/sys/class/net/enP59185p0s0/device -> ../../../virtio1`），
`/sys/class/ieee80211` 为空 —— **本机没有任何 Wi-Fi 射频**，不能当无线客户端。
也没有第二台设备。所以唯一能产生真实空口帧的拓扑是：让 XR1710G 自己的 STA VIF
关联到它自己的 AP VIF，然后 `iperf3` 走这条链路。

这条拓扑在**别的芯片**上是成立的（mt76 系列历史上支持 AP+STA 并发），
所以本轮的否定结论是**针对这个 mt7996 + 这版固件**的实测，不是通用断言。

## 方法（可直接照抄的探测协议）

每个组合都必须给出三组独立判据，缺一不可：

1. **VIF 侧计数器**：`ethtool -S <vif>` 的 `sta_state`、`channel`、`tx_mpdu_attempts`、
   `tx_packets`、`rx_packets`，以及 `/sys/class/net/<vif>/statistics/tx_packets` 的差分。
2. **对端侧证据**：自己 AP 的 `iw dev phy0.0-ap0 station dump`（应出现一条 station 记录）。
3. **内核侧证据**：`dmesg -c` 前后差分，找 `send auth` / `authenticate with` / `assoc` 打印。

```sh
# 建 VIF：必须显式给 addr（否则默认复用 AP 的 MAC → up 时 SIOCSIFFLAGS 失败）
iw phy phy0 interface add sta0 type managed addr 02:11:22:33:44:66 radios 0
ip link set sta0 up
n0=$(cat /sys/class/net/sta0/statistics/tx_packets)
iw dev sta0 connect OpenWrt 2437 00:58:28:d7:44:5f; echo rc=$?
sleep 6
n1=$(cat /sys/class/net/sta0/statistics/tx_packets); echo delta=$((n1-n0))
ethtool -S sta0 | grep -E 'sta_state| channel:|tx_mpdu_attempts|tx_packets|rx_packets'
iw dev phy0.0-ap0 station dump        # 应出现 station 记录，空 = 没关联
dmesg | tail
```

**自收判据**（本轮最硬的一条，与 VIF 类型无关）：

```sh
# 选一段干净的频段（6 GHz 在本环境几乎空载），看 AP 自己的 rx 计数是否随 beacon 动
for i in 1 2 3 4 5; do
  printf '%s tx=%s rx_mpdu=%s ch_time=%s busy=%s\n' "$(date +%T)" \
    "$(ethtool -S phy0.2-ap0 | awk '/tx_mpdu_attempts/{print $2}')" \
    "$(ethtool -S phy0.2-ap0 | awk '/rx_mpdu_cnt/{print $2}')" \
    "$(ethtool -S phy0.2-ap0 | awk '/ch_time:/{print $2}')" \
    "$(ethtool -S phy0.2-ap0 | awk '/ch_time_busy/{print $2}')"
  sleep 5
done
```

## 结果

### 4.1 自收判据：射频听不到自己（6 GHz，空载频段）

`phy0.2-ap0`（ch37 / 6135 / 320 MHz），20 s，无任何 station：

| 时刻 | `tx_mpdu_attempts` | `rx_mpdu_cnt` | `ch_time` | `ch_time_busy` |
|---|---|---|---|---|
| 04:57:12 | 0 | **0** | 3168908 | 12187 |
| 04:57:17 | 0 | **0** | 3173939 | 12209 |
| 04:57:22 | 0 | **0** | 3178969 | 12230 |
| 04:57:27 | 0 | **0** | 3183999 | 12249 |
| 04:57:32 | 0 | **0** | 3189029 | 12268 |

同窗口对照：`phy0.0-ap0 rx_mpdu_cnt=627699`、`phy0.1-ap0 rx_mpdu_cnt=2112077`
（这两个数是**邻居流量**，不是自收）。6 GHz 段 `ch_time_busy` 只涨 81/5000 ≈ 1.6% 的相对量，
绝对占比 0.4%，说明这段时间里介质上除了自己的 beacon 几乎没有别的帧 —— 而 `rx_mpdu_cnt`
一步没动。**结论：同一 phy 的发射不进自己的接收路径。**

> `tx_mpdu_attempts` 恒为 0 是因为 beacon 走的是另一条计数口径（`tx_packets` 在同期以
> 每 3 s +6~+7 稳定增长，见 §4.4 的基线表）。自收判据因此以 `rx_mpdu_cnt` 与
> `ch_time_busy/tx_packets` 的对照为准，而不是 `tx_mpdu_attempts`。

### 4.2 六种组合，全部不成立

判据列写法：`connect/jOIN` 返回码 → `sta_state` → `channel` → `tx_packets delta` → 对端 station 数。

| # | 组合 | 目标 | 结果 | 关键读数 |
|---|---|---|---|---|
| A | 同 radio0 managed VIF + `iw connect` | 自己的 2.4G AP | 失败 | `connect_rc=0`、`tx delta=0`、`sta_state=0`、`channel=0`、`own_ap_stations=0`、`sdata_state=0x1` |
| B | 同 radio1 managed VIF + `iw set freq 5745 80 5775` | 锁信道到 5G AP | 失败 | `command failed: Resource busy (-16)`、`channel=0` |
| C | IBSS VIF `ibss join` 自建 cell | 2.4G ch6 | 失败 | `join_rc=0`、`channel=2437`、`tx=0`、`own_cell_peers=0` |
| C' | 第二个 IBSS VIF up | 同上 | 内核禁止 | `ip: SIOCSIFFLAGS: Resource busy`；dmesg `Allow only a single IBSS interface…` |
| D | 两个 mesh point VIF（不同 MAC，同 mesh id） | 2.4G ch6 | 失败 | 两个都 `channel=2437`，`tx=0`，`peers=0`（互不发现） |
| E | managed VIF + `wpa_supplicant -D nl80211` | 自己的 2.4G AP | 失败 | 初始化后立即 `deinit`，`tx=0`、`sta_state=0` |

A 的完整原始输出（`/tmp/wl3/A-connect.txt`）：

```
connect_rc=0
tx_packets before=0 after=0 delta=0
Not connected.
     rx_packets: 0
     tx_packets: 0
     sta_state: 0
     channel: 0
     tx_mpdu_attempts: 0
     tx_mpdu_success: 0
--- mac80211 sdata state: 0x1
--- own AP station dump (expect empty)
station_count=0
--- dmesg after connect
```
（`dmesg` 段为空 = connect 连一条内核打印都没产生，更没往空口发帧。）

### 4.3 决定性对照：同一个 STA VIF，打邻居成功、打自己失败

`Z0`（`02:11:22:33:44:7d`，managed，`radios 0`，与自己的 2.4G AP 同 radio 同信道）：

| 目标 | 命令返回 | dmesg | 计数器 |
|---|---|---|---|
| 邻居 `fpl-616`（`4c:77:66:ea:5f:63`，ch6） | `auth_to_neighbor_rc=0` | `Z0: authenticate with 4c:77:66:ea:5f:63` / `send auth to … (try 1/3)` / `Z0: authenticated` | `sta_state=2`、`channel=2437`、`tx_packets=1`、`rx_packets=14` |
| 自己的 AP（`00:58:28:d7:44:5f`，ch6） | `auth_to_own_ap_rc=254`，`command failed: No such file or directory (-2)` | 无 | `sta_state=0`、`channel=0`、`tx=0`、`rx=0` |

`-2` = `ENOENT`，来自 cfg80211 在 BSS 缓存里找不到这个 BSSID —— 因为**它从来没有被收进扫描结果**：

```
外站 BSS 数=7
自己的 BSSID(00:58:28:d7:44:5f) 出现次数=0
```

同一 VIF 的 `scan freq 2437`：7 个邻居全在（`fpl-616`/`TP-LINK_B652`/`airone`/
`WIFI-AH8B0202`/`XN-UFI-416C`/`802`/`CHAOCAI`），自己的 AP **一次都没出现**。
`scan freq 5745` 同理：6 个邻居在，`00:58:28:d7:44:60` 出现 0 次。

**这就解释了为什么所有组合都停在 `sta_state=0`**：不是协商参数不对（BI、EHT、OWE 都不是原因），
而是对端 BSS 在本地扫描缓存里不存在，cfg80211 的 auth/assoc 状态机根本没东西可打。

### 4.4 baseline（未改动状态，仅记录，供对照）

三个 AP VIF 在没有任何 station 时的读数（`/tmp/wl3/F-final.txt`）：

| VIF | 信道 | txpower | `channel` | `ch_time` | `ch_time_busy` | busy 占比 |
|---|---|---|---|---|---|---|
| `phy0.0-ap0` | ch6 2437 EHT20 | 28 dBm | 2437 | 2898018 | 998601 | 34.5% |
| `phy0.1-ap0` | ch149 5745 EHT80 | 28 dBm | 5745 | 2918887 | 243463 | 8.3% |
| `phy0.2-ap0` | ch37 6135 320 MHz | 30 dBm | 6135 | 2917473 | 11183 | **0.4%** |

2.4G 与 5G 的 busy 占比高，是因为**邻居 AP 密集**（扫描稳定看到 6–7 个外站），
6G 段几乎空载 —— 这正是 §4.1 选它做自收判据的原因。

## 与 `docs/perf/ppe-wired-baseline.md` 的口径对齐

[`docs/perf/ppe-wired-baseline.md`](ppe-wired-baseline.md)（PR #207）那份是有线基线，
本轮沿用它的四条方法学约定，并明写哪里没对齐：

| 约定 | 有线基线（#207） | 本轮 |
|---|---|---|
| 方向断言 | 读 iperf3 客户端 JSON 的 `start.test_start.reverse`，不看标签 | **没有可测链路**，无 JSON；未使用 |
| CPU 时间 | `/proc/stat` 差分，`HZ=100`，`non-idle = 总 tick − idle − iowait` | 同口径可用，但无流量可测 |
| 包计数 | `ethtool -S <netdev>` 差分；并指出发送侧聚合会让「帧」不等于线上帧 | 改用 `rx_mpdu_cnt` / `ch_time*` 做**自收判据**，这是本轮新增的判据 |
| 缺失项必须列出 | 摘要第 6 条列了被转发路径 / 2.5G-10G / 无线 / stock 对照 | 本文件摘要第 7 条列出无 iperf3、无环回读数、无线数据不可得 |

两份文档的「结论摘要」都遵循同一形状：**实测 / 方法学发现 / 缺失**三段，
每条都可追到设备上的原始文件；不可追的数字不进文档。

## 局限（诚实清单）

1. **不是吞吐基线**。本文件没有任何吞吐/CPU/重传表格，因为环回链路从未建立。
   三个 band、两个方向、1 流与 4 流的格子全空。
2. **「单 radio 半双工吞吐约减半」这条经验在本硬件上没有被验证过**，
   它不是本轮的失败原因，也不应被当作已知量引用。
3. **自收判据只在一个频段（6 GHz）取得完整对照**。2.4G/5G 的 `rx_mpdu_cnt` 被邻居流量淹没，
   无法把「自收」与「收邻居」分开；因此那两段的「收不到自己」是**间接**结论
   （由 §4.3 的 scan / auth 对照支撑），不是直接计数。
4. **`wpa_supplicant` 的失败形态在不同固件上不一样**。r37994/r38034 上日志明确写
   `nl80211: Driver does not support authentication/association or connect commands`
   并 `Failed to initialize driver interface`；r38047 上它**初始化成功**（`Successfully initialized
   wpa_supplicant`）然后立即 `deinit`，没有任何扫描动作。这段差异未经逐版本复核，
   不作为结论依据（结论由 §4.3 的 `iw` 对照独立支撑）。
5. **设备和固件在测试期间被重刷过三次**（r37994-44d4267ca7 → r38034-c03e61165e →
   r38042-ff772d0946 → r38047-a86ce12e27），`/tmp` 每次清空。所有最终读数都标了
   `r38047-a86ce12e27`；早期版本上的同向观察只作为「不是单点问题」的旁证，不参与计数。
6. **`/etc/config/wireless` 的 md5 在 r38042 之后变了**（旧 `ab0a1b0e…` → 新 `85043fdce…`），
   这是**固件默认配置差异**，不是本轮改动。本轮的改动全部通过 `uci` + `cp` 回滚，
   回滚后 md5 与改动前逐字节一致（§5）。
7. **向本机 `/tmp` 侧载 iperf3 未完成**：需要 `libatomic1` / `libiperf3` / `iperf3` 三个 APK，
   但每次设备重刷都会清空 `/tmp`，最终版固件上 `command -v iperf3` 为空。
   若后续要量，必须先解决「重刷后如何保留侧载」或改用 `dl/` 里已构建的包。

## 5. 回滚证据

改动前（`/tmp/wl2/md5.before`，r38047 上重新取证的时间点）：

```
85043fdce72207d89b6fe1912acaecc9  /etc/config/wireless
cebd3f38885faf8b58567aea1db817de  /etc/config/network
```

回滚动作：删除全部实验 VIF（`iw dev <name> del`）+ `cp /tmp/wireless.bak /etc/config/wireless`
+ `cp /tmp/network.bak /etc/config/network` + `uci commit` + `wifi reload`。

回滚后：

```
85043fdce72207d89b6fe1912acaecc9  /etc/config/wireless
cebd3f38885faf8b58567aea1db817de  /etc/config/network
```

逐字节一致（两份文件的 md5 与备份记录相同）。同时 `iw dev` 只剩三个 AP VIF
（`phy0.0-ap0` ch6 / `phy0.1-ap0` ch149 / `phy0.2-ap0` ch37），三个 AP 的 `station dump`
都是 0 条（说明没有残留 STA 关联），`br-lan` 成员与改动前一致，
`dmesg` 中 `assert|WMI timeout|ring stuck|Oops|Call Trace` 匹配数为 **0**。

期间一次**环境自伤**（已修复，记录在此以免被当成固件缺陷）：手工反复 `setsid wpa_supplicant`
与 `rm -rf /var/run/wpa_supplicant` 把该目录 owner 改坏，导致 procd 的 `wpad` 循环
`bind(PF_UNIX): Permission denied`，三个 AP 一度全部消失；`/etc/init.d/wpad stop` +
`rm -rf /var/run/wpa_supplicant` + `/etc/init.d/wpad start` 后恢复。**手工起 wpa_supplicant
是这个环境里的破坏性操作**，后续不应在实机上重复。

## 6. 对 Wi-Fi 类 issue 的影响

#43/#47/#48/#50/#53/#66/#68/#89 都需要「真实空口」的证据：速率选择、AQL/队列、
NPU TX/RX 路径、recovery 行为等在空口负载下的表现。在当前硬件条件下
（**本机无射频 + 无第二台设备 + 单 phy 收不到自己**）这些证据**无法取得**。

要继续，只有三条路，且都不在本轮范围：

1. **加一台真机当客户端**（最直接，成本最低）。
2. **换芯片做环回**（mt7915/mt7921 等有 AP+STA 并发先例的型号），把结论从「不可行」
   降级为「此型号不可行」。
3. **用第三方 STA 硬件 + 现有 AP VIF** 量单向吞吐（AP 侧不参与环回，规避自收问题）——
   这条路只需要一台 STA，不需要改驱动。
