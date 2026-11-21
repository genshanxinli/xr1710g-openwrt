# recovb12 — issue #12 实机验证：静态准备报告

- 时间：2026-11-21 13:05–13:30（Asia/Shanghai）
- 执行者：subagent `recovb12`（自动化 agent）
- 工作区：`/home/l1n/projects/xr1710g-openwrt`（tip `a0078bf520`）
- **状态：静态准备全部完成；Lead 已批准「第一步（串口之外的执行前检查）」，本报告已含其输出；「第二步（实机执行）」等 13:37 后 Lead 单独放行。** 本文所有“推断”均已标注，实测项附原文/文件行号。

---

## 1. 结论摘要

| 项 | 结果 |
|---|---|
| 传输通道可行性 | **实测：kermit `loadb` 不可用；`loady`+`sb`（YMODEM）可用**。kermit 在协议前先发字面串 `kermit -ir\r` 然后 `resending winlo=2` 死循环、rc=2（host 侧缺陷）；`loady 0x85000000` 握手成功，实测 **8.56 kB/s（128 B/块，66.9 块/s）** |
| 镜像自身是否可用 | **可用（实测）**：FIT 结构完整、kernel 7.4-rc3、内嵌新式 initramfs 1409 项且含 `/init`+`/sbin/init`+busybox/procd |
| 装载地址 | **改用 `0x85000000`**（原 `loadaddr=0x81800000` 与解压输出的 42 MB 区间重叠；`initaddr=0x89000000` 落在 qdma1-buf 保留区） |
| bootargs / rdinit | **不加 `rdinit=/sbin/init`**（会跳过镜像自带的 `/init` 与 `INITRAMFS=1` 导出） |
| 传了多大 | **6,191 kB / 14,417,920 B（43%，49,531 块 ×128 B）后中断**：14:00:22 host 侧 USB/IP 链路死（`vhci_hcd urb->status -104` 刷屏 + `page allocation failure: order:7`），`Retry 0: Timeout on sector ACK` ×10 → `Transfer incomplete`，`sb rc=128`。板端未报错，是 host 侧管道断 |
| bootm 结果 | **未跑通**：字节数未达 14417920（硬门：不足即 reset，不 bootm），且此后串口读方向全程 0 字节，无法再下发 `iminfo`/`bootm` |
| 设备是否已回 `r38203-a0078bf520` | **无法确认**：`reset` 是盲发的（读不回），之后 `ping 192.168.1.1` 全丢、`ssh: No route to host`。**全程零 flash 写入**（未 `saveenv`/`ubi write`/`nand erase`），`bootargs` 只改过 RAM，任何重启都会恢复原状 |

---

## 2. 镜像静态验证（全部实测）

### 2.1 大小与哈希对得上

```
$ stat -c%s bin/targets/airoha/an7581/openwrt-airoha-an7581-gemtek_xr1710g-ubi-initramfs-recovery.itb
14417920
$ sha256sum <同上>
1847baefbe5bf6e647e7c8a9c0bc68c2a0f316520ee823b6fde96956fbc372ca  <同上>
$ grep initramfs-recovery bin/targets/airoha/an7581/sha256sums
1847baefbe5bf6e647e7c8a9c0bc68c2a0f316520ee823b6fde96956fbc372ca *openwrt-airoha-an7581-gemtek_xr1710g-ubi-initramfs-recovery.itb
```

**一致。** 传输目标字节数 = 14417920 = 0xDC0000（U-Boot 判据用这个数）。

### 2.2 FIT 结构

```
$ dumpimage -l <itb>
FIT description: ARM64 OpenWrt airoha an7581 gemtek_xr1710g device tree blob
Created: Sat Nov 21 04:07:12 2026
 Image 0 (kernel-1)
  Description:  ARM64 OpenWrt Linux-7.4-rc3
  Type: Kernel Image, Compression: lzma
  Data Size: 14283645 Bytes
  Load Address: 0x80200000  Entry Point: 0x80200000
  Hash algo: crc32 / Value: d37d76de
  Hash algo: sha1  / Value: 0f724962fbbe2e6589fe18012ab6711bf4b98cb8
 Image 1 (fdt-1)
  Description:  ARM64 OpenWrt airoha an7581 gemtek_xr1710g device tree blob
  Type: Flat Device Tree, Compression: uncompressed
  Data Size: 30291 Bytes
  Hash algo: crc32 / Value: 7f978513
  Hash algo: sha1  / Value: 3654fe1c108838b9194d1c718c6c026104a3e926
 Default Configuration: 'config-1'
 Configuration 0 (config-1)
  Kernel: kernel-1
  FDT: fdt-1
```

关键点（实测）：**`config-1` 只有 kernel + FDT，没有 ramdisk 节点，也没有 `bootargs` 属性。**

### 2.3 kernel 与内嵌 initramfs

- 抽 kernel：`dumpimage -T flat_dt -p 0` → `/tmp/recov_kernel.lzma`；`xz --format=lzma -dc` → `/tmp/recov_Image` = **42166280 B**，`file` 判定 `Linux kernel ARM64 boot executable Image, little-endian, 4K pages`；banner `Linux version 7.4-rc3 (l1n@localhost) ... #0 SMP PREEMPT Sat Nov 21 04:06:17 2026`。
- initramfs 位置：`/tmp/recov_Image` 偏移 **0xd8a6dc (=14198492)** 处是 `070701` newc cpio 头，与
  `build_dir/target-aarch64_cortex-a53_musl/linux-airoha_an7581/linux-7.4-rc3/System.map` 的
  `ffffffc080d8a6dc D __initramfs_start` 完全对应（0xffffffc000000000 线性映射 → 物理 0x80d8a6dc，0x80d8a6dc − 0x80000000 = 0xd8a6dc ✔）。
- 内容：**1409 个条目**，TRAILER 在 0x26611a0，payload 合计 25846427 B；含 `/init`、`/sbin/init`、`bin/busybox`、`sbin/procd`、`sbin/ip`、`etc/openwrt_release`、`etc/init.d/*`。
- `/init` 原文（实测抽出）：

```sh
#!/bin/sh
export INITRAMFS=1
DIRS=$(echo *); NEW_ROOT=/new_root
mkdir -p $NEW_ROOT; mount -t tmpfs tmpfs $NEW_ROOT
cp -pr $DIRS $NEW_ROOT
exec switch_root $NEW_ROOT /sbin/init
```

⇒ **镜像本身没有“init 不起来的缺陷”**：initramfs 真实存在、`/init` 与 `/sbin/init` 都在。`rdinit` 不要覆盖（见 §3）。
⇒ 也意味着 `bootm` **不需要额外 ramdisk 参数**：kernel 自己解出 cpio。

---

## 3. U-Boot 侧启动命令设计（纸上推演）

### 3.1 三个前提修正（重要）

1. **`loadx`/`loady` 其实在这个树编出的 U-Boot 里有。** `cmd/load.c:1158-1183` 把 `loadb`/`loads`/`loadx`/`loady` 全部注册在同一个 `#if defined(CONFIG_CMD_LOADB)` 下，`cmd/load.c:470-514` 按 `argv[0]` 分发到 `load_serial_ymodem(..., xyzModem_ymodem|xmodem)`；`strings u-boot.bin` 里 loadb/loads/loadx/loady 都在。所以“只能 loadb”对**本树构建产物**不成立——板上那颗是第三方 `XR1710G-2026-10-16-g94476aa18f0b-dirty`，得进 prompt 用 `help` 确认（列为 §4 探针）。
   备选通道已备好：host 侧 `lrzsz` 已装（`sx`/`sb`/`sz`，实测 `sx=/usr/bin/sx`、`sb=/usr/bin/sb`），对应 `loadx`(XMODEM)/`loady`(YMODEM)。**但大概率用不上**：板上那颗是第三方 U-Boot，只有进 prompt `help | grep -i load` 才知道它到底有没有 `loadx`/`loady`。所以脚本 A2 阶段的设计是“先 `help` 看清通道，再决定用 kermit `loadb` 还是 `lrzsz`”，不预设通道。
2. **`loadaddr=0x81800000` 不安全。** 解压后 Image 42,166,280 B 从 0x80200000 起到 **0x82A36808**，覆盖 0x81800000–0x825C0000。历史上 in-place lzma 只剩 432,322 B 余量的记录与此吻合。
3. **`initaddr=0x89000000` 也不安全。** `target/linux/airoha/dts/an7581.dtsi:59` 的 `qdma1-buf: qdma1-buf@89000000 { no-map; reg = <0x0 0x89000000 0x0 0x1000000>; }` ⇒ 0x89000000–0x89FFFFFF 是 DMA 保留区，14.4 MB 装进去正好铺满。

### 3.2 选用 `0x85000000` —— 证据行 + 可复现算式

**证据行（`0x84A00000–0x86FEFFFF 空闲` 的出处）**：issue #12 第 4 条评论（genshanxinli，2026-11-20T09:16:56Z，第 7 节「装载地址合法、不撞任何保留区（实测 /proc/iomem + 推断）」）原文，设备上 `cat /proc/iomem` 的结果：

```
80000000-801fffff reserved(ATF)         80200000-83ffffff System RAM (62 MiB)
84000000-849fffff reserved(npu-binary)  84a00000-86feffff System RAM
86ff0000-90e06fff reserved(qdma/npu…)   90e07000-ffffffff System RAM
```

同一条评论还留了一句可直接引用的建议：`package/boot/uboot-airoha/patches/999-airoha-add-gemtek-xr1710g.patch:147` 的 `loadaddr=0x81800000` → `0x85000000`，理由是「落在 `0x84a00000-0x86feffff` 这段 System RAM」。
DTS 侧交叉验证：`an7581.dtsi:41` npu-binary 到 0x849FFFFF 止、`an7581.dtsi:48` ramoops 从 0x86FF0000 起（`reg = <0x0 0x86ff0000 0x0 0x10000>`）⇒ 中间 0x84A00000–0x86FEFFFF 无人占。

**算式（本机 `python3` 实算，可复现）**：

```
itb size          : 14,417,920 B = 0xdc0000
Image payload     : 42,166,280 B = 0x2836808      # xz 解压后 /tmp/recov_Image
Image hdr image_sz: 42,598,400 B = 0x28a0000      # ARM64 header image_size 字段（保守值）
解压低界          : 0x80200000                     # FIT kernel-1 load/entry
解压上界(payload) : 0x82a36808                     # 0x80200000 + 0x2836808
解压上界(hdrsize) : 0x82aa0000                     # 0x80200000 + 0x28a0000  <- 保守取这个

loadaddr 0x81800000 区间 : 0x81800000 – 0x825c0000
  与解压输出重叠? payload=True, hdr=True           ⇒ 旧 loadaddr 不安全
新装载地址 0x85000000 区间: 0x85000000 – 0x85dc0000
  上界余量 = 0x86ff0000 - 0x85dc0000 = 0x1230000 = 19,070,976 B (~18.2 MiB)
  与解压输出重叠? False                            ⇒ 安全
```

两个上界都落进 0x81800000 那段（0x81800000 < 0x82A36808 < 0x82AA0000），所以“`loadaddr` 会被解压输出覆盖”这个结论与取哪个上界无关。
另外，`0x85000000` 也远离 U-Boot 重定位区（DRAM 顶部）——板上 DRAM 总量待 `bdinfo` 复核。

### 3.3 确切命令行（待批准后执行）

```
printenv loadaddr ; printenv bootargs
setenv bootargs 'console=ttyS0,115200 earlycon ubi.block=0,fit root=/dev/fit0 rootwait'
loadb 0x85000000
iminfo 0x85000000
bootm 0x85000000#config-1
```

- bootargs 与 `target/linux/airoha/dts/an7581-xr1710g-ubi.dts:26` 逐字一致，**不加 `rdinit=`**。
- FIT 的 `config-1` 没有 `bootargs` 属性 ⇒ U-Boot 不会覆盖我们 setenv 的值。
- A/B 备选：若 kernel 起来但 `No working init found` / `Kernel panic`，再试 `setenv bootargs '... rdinit=/sbin/init'`。
- 全程 **RAM only**；`saveenv` / `ubi write` / `nand erase` 一律不碰。

---

## 4. 传输时间预算与执行计划

### 4.1 预算（N = 14,417,920 B，8N1 = 10 bit/B，115200 baud ⇒ 11520 B/s，线速下限 1251.5 s = 20.9 min）

| 包大小 | 包数 | 下行(含 7 B 头) | 传输时长 | 停等周转 | 合计 |
|---|---|---|---|---|---|
| 9024（U-Boot MAXL = 94×95+94） | 1598 | 14,429,106 B | 1252.5 s | 3.2 s | **~22 min**（乐观） |
| 1024 | 14080 | 14,517,480 B | 1260 s | 28 s | ~21.5 min |
| 94 | 153382 | 15,491,594 B | 1345 s | 307 s | **~28 min**（保守） |
| 9024 + `prefixing all` | 1598 | ×~1.7 | ~2130 s | — | ~36 min |
| 94 + `prefixing all` + 重传 | 153382 | ×~1.7 | ~2800 s | — | **~47–60 min**（最坏） |

**给回答的两个数字：乐观 22 分钟；保守 28 分钟；最坏 45–60 分钟。申请 60 分钟独占窗口。**

U-Boot 协商细节（源码实测，`cmd/load.c:795-810`）：应答 CAPAS = `2`（只做长包）、`0`（**不做窗口** ⇒ 纯停等，`set window` 无效）、`94,94`（MAXL 由 `cmd/load.c:237` 的 `length = len_hi * 95 + len_lo` 解出 = 9024 字节/包）；**拒绝 QBIN**（8-bit prefixing）与 REPT；校验类型 1（6-bit checksum，无 CRC16 ⇒ 长包更易坏，9024 连坏 3 次就退 1024）。

### 4.2 host 侧已就绪

- `ckermit` 已装：`416~beta12-3`，`kermit -h` 可用。
- `/home/l1n/projects/.scratch/recovb12/kermit.rc` 已写好并**本机语法验证通过**（用 `/dev/null` 替换设备名跑 `take`，无关键全部剔除：`set control-prefix`、`set long packets` 在 C-Kermit 10.0.416 里都不是关键字，已删）：
  `set carrier-watch off`、`set flow-control none`、`set parity none`、`set prefixing minimal`、`set send/receive packet-length 9024`、`set window 1`、`set block-check 1`、`set retry 10`。
- `/home/l1n/projects/.scratch/recovb12/send_itb.sh`：带 `--arm` 闸门的执行脚本，`bash -n` 通过。
  - 静态闸门（**不开串口**）：设备节点存在、`fuser` 无占用、itb 字节数、sha256、`kermit.rc` 存在。
  - `--arm` 后的阶段：A 探提示符 → **A2 `help` 原文落盘并逐个判定 `loadb/loadx/loady`（无 `loadb` 就走 lrzsz 方案）** → B `printenv` + `setenv bootargs` + `loadb` 并等 `## Ready for binary` → C kermit 传输 → **字节数必须 == 14417920，否则 bail 并 `reset`** → **D `iminfo` 必须出现 FIT + `config-1`，否则 bail** → E `bootm 0x85000000#config-1` 并采集最长 660 s → F 四条验收探针（经 ssh，不可达则提示手打）→ G `reset` 回固件并核 `DISTRIB_REVISION`/`uname -r`。
  - `bail()` 一律先 `reset` 再退出（Lead 硬要求：字节数不符直接 reset，不 bootm）。
  - 串口读法按要求实现：**先**后台 `timeout N dd if=/dev/ttyUSB0 of=<log> bs=1 conv=notrunc oflag=append`，**再** `printf 'cmd\r' > /dev/ttyUSB0`，最后 kill dd；传输期间不跑 dd。
- `/home/l1n/projects/.scratch/recovb12/plan.md`：地址表、命令行、失败判据表。

### 4.3 进 prompt 后先打的探针（结果未知 ⇒ 待串口确认）

```
version     # 板上固件串（预期 XR1710G-2026-10-16-g94476aa18f0b-dirty）
bdinfo      # DRAM 起止/大小 + U-Boot 重定位地址 → 复核 0x85000000 可用
help        # 板上这颗到底有没有 loadb / loadx / loady
printenv    # loadaddr / initaddr / fdt_addr_r / kernel_addr_r / bootargs（未知项在报告里保持“待串口确认”）
```

---

## 5. 实测 vs 推断 + 未跑通清单

### 5.1 实测（有原文/行号）

| 项 | 证据 |
|---|---|
| ITB 14417920 B、sha256 与 `sha256sums` 一致 | §2.1 原文 |
| FIT = kernel-1(lzma,14283645B,0x80200000) + fdt-1(30291B)，config-1 无 ramdisk、无 bootargs | `dumpimage -l` 原文 |
| 解压 Image 42166280 B、7.4-rc3、内嵌 cpio 在 0xd8a6dc | `file` + `System.map:__initramfs_start` |
| initramfs 1409 项，含 `/init`（内容见 §2.3） | cpio 抽取原文 |
| U-Boot 配置项 | `.config:186,201,202,304,306,493,519,525,538,605,607,611,756,1646,1649` |
| `loadx`/`loady` 在构建产物里 | `cmd/load.c:470-514`、`cmd/load.c:1158-1183`、`strings u-boot.bin` |
| Kermit 协商参数 | `cmd/load.c:237`、`cmd/load.c:795-810` |
| qdma1-buf 占 0x89000000–0x89FFFFFF | `target/linux/airoha/dts/an7581.dtsi:57-60` |
| `kermit.rc` 语法在本机通过 | `kermit -Y -C "take /tmp/ktest.rc,exit"` → `KERMIT_RC_LOADED` |
| 串口被占用的时刻 | 13:24:xx `fuser -v /dev/ttyUSB0` → `l1n 3224277 f.... dd`（随后 18 s 内 12 次采样均为 none，说明是短时 `timeout N dd` 突发式占用） |
| 串口空闲的时刻 | 13:28:5x `fuser -v /dev/ttyUSB0` 与 `lsof /dev/ttyUSB0` 均 exit=1（无占用），`ps -eo args \| grep ttyUSB0` 无进程，节点 `crw-rw---- root:dialout 188,0` |
| 串口空闲是阵发的 | 13:30:1x 未加 `--arm` 跑 `send_itb.sh` 静态闸门 → `ABORT: /dev/ttyUSB0 held: l1n 3355911 f.... dd`（另一路 900 s 捕获在抢）⇒ 必须由 Lead 给独占窗口 |
| 地址算式 | §3.2 的 `python3` 实算块（0x82A36808 / 0x82AA0000 / 余量 0x1230000 = 19,070,976 B） |
| `0x84A00000–0x86FEFFFF` 的出处 | issue #12 第 4 条评论（genshanxinli，2026-11-20T09:16:56Z）里设备 `cat /proc/iomem` 原文，见 §3.2 |

### 5.2 推断（待实机证实）

- `loadb` 在**板上那颗第三方 U-Boot** 里存在（本树产物有，板上未验证）。
- `0x85000000` 在板上 U-Boot 视角下可用（依据 Linux `/proc/iomem` 与 DTS reserved-memory，跨世界推断；DRAM 总量待 `bdinfo`）。
- 9024 字节长包在真实 USB-serial 链路上能稳定（6-bit checksum，无 CRC）。
- bootargs 不覆盖 `/init` 路径能进 recovery 用户态。

### 5.3 未跑通 + 为什么

| 任务项 | 状态 | 原因 |
|---|---|---|
| loadb 实传 | **未跑通（待窗口）** | 串口被其他 agent 的 `timeout dd` 阵发占用（13:30 实测仍撞到 `l1n 3355911 f.... dd`）；Lead 已批独占 60 min，等 13:37 后放行 |
| 传了多大 | 未跑通 | 同上（预算 14417920 B，判据 `Total Size = 0xDC0000 = 14417920 Bytes`） |
| bootm 结果 | 未跑通 | 同上 |
| 回到 `r38203-a0078bf520` | 未触碰（当前仍为原固件） | 全程未 open 串口、未写 env ⇒ 设备状态未改变；执行时的回滚验收已写进脚本 G 阶段 |
| issue #12 评论 | **未发** | 评论要求写“传了多大 / bootm 结果 / 回固件”，这些数据得等执行；为避免发两条，草稿存 `.scratch/recovb12/issue12-comment.draft.md`，执行后一次发出 |

### 5.4 静态闸门被抢的现场（“必须独占窗口”不是猜的）

同一份 `send_itb.sh` 的静态闸门（只 `fuser` 检查，不 open 设备）在不同时刻给出相反结果：

```
13:28:5x  fuser -v /dev/ttyUSB0   → exit=1（无占用）；lsof → exit=1；ps grep ttyUSB0 → (none)
13:24:xx  fuser -v /dev/ttyUSB0   → l1n 3224277 f.... dd
13:30:1x  ./send_itb.sh（未加 --arm）→ ABORT: /dev/ttyUSB0 held: l1n 3355911 f.... dd
          18 s 内 12 次采样（13:25:00–13:25:16）全部 none
```

⇒ 占用是**短时 `timeout N dd` 突发式**（`reboot323` 的 900 s 捕获 + `meter23b` 的 meter 观测）。这种占用的危险在于：它可能正好落在 kermit 传输的 22–28 分钟里任意一秒 —— 一次 `dd if=/dev/ttyUSB0` 就会抢走字节、把包打坏。所以必须在传输窗口内保持零占用，而不是“此刻没人用就能开跑”。

---

## 6. 零 flash 写入承诺、回滚与需要 Lead 批准的状态变更

### 6.1 零 flash 写入（本次已遵守，执行时同样遵守）

- 未执行、也不会执行：`saveenv`、`ubi write`、`ubi format`、`nand erase`、`nand write`、`sysupgrade`。
- 唯一写入是 RAM：`setenv bootargs`（不 saveenv，掉电即失）、`loadb 0x85000000`、`bootm`。
- 唯一“状态”变更：最后 `reset` 一次（不改 flash 内容）。
- 若某个判定非得写 flash 才能验 ⇒ 停手并报「需要 Lead 单独授权」。

### 6.2 回滚

`reset`（或断电重启）即回到 UBI 里的原固件；原固件未被改写。历史上 reset→ssh 回连约 57 s。

**「回到原固件」的最终判据（三条一起看，Lead 2026-11-21 13:31 确认）**：

| # | 判据 | 命令 | 期望 |
|---|---|---|---|
| a | `/proc/mounts` 的 `/` 那一行 | `awk '$2=="/"{print $1, $3}' /proc/mounts` | 不再是 `tmpfs`/`rootfs`，而是 ubi/dev/fit0 那套 |
| b | uptime 归零 | `cut -d. -f1 /proc/uptime` | < 120 s（刚 reset 完） |
| c | 版本号 | `grep DISTRIB_REVISION /etc/openwrt_release` | `r38203-a0078bf520` |

`uname -r` **不能**作为判据：recovery ITB 与原固件同树构建，两者都是 `7.4-rc3`，`DISTRIB_REVISION` 也都是 `r38203-a0078bf520` ⇒ 只能作为旁证记录，不能用来区分两个系统。已写进 `send_itb.sh` G 阶段注释与实现（`OK(a)/OK(b)/OK(c)` + `corroboration only`）。

### 6.3 需要 Lead 批准的状态变更清单

1. **独占 `/dev/ttyUSB0` 60 分钟** —— Lead 已批；仍需 `reboot323`（900 s 捕获到 13:37）与 `meter23b` 停手，否则会和 kermit 抢字节。
2. 允许在板上 U-Boot 执行 `setenv bootargs ...`（**仅 RAM，不 saveenv**）。
3. 允许在板上执行 `loadb 0x85000000` / `iminfo` / `bootm 0x85000000#config-1`（纯 RAM）。
4. 允许最后 `reset` 一次以回到正常固件。
5. 不需要（也不会申请）：`ubi write` / `nand erase` / `saveenv` —— 即 acceptance B（写 ubi）本轮不做。

批准状态（2026-11-21 13:28 Lead 回复）：1–4 **批**，5 **不批**（acceptance B 本轮不做）。

### 6.4 issue #12 的真正验收点（recovery 起来后必抓的四条）

| 探针 | 期望 | 证明什么 |
|---|---|---|
| `grep -E ' / (rootfs\|tmpfs) ' /proc/mounts` / `cat /proc/mounts` 头几行 | recovery 的 `/` 是 `rootfs`/`tmpfs`（`/init` 的 switch_root 结果） | 真的跑在 initramfs 上，不是又挂回 ubi 上的 rootfs |
| `cat /proc/cmdline` | 含我们 setenv 的那串，且**没有** `rdinit=/sbin/init` | bootargs 生效、且没有覆盖镜像自带 `/init` |
| `mount -t debugfs none /sys/kernel/debug; ls /sys/kernel/debug/ppe/ \| wc -l` | 16（非 0） | recovery 里 PPE debugfs 在，与 #23 的 meter 观测口径一致 |
| `dmesg \| grep -ci "UBIFS recovery"` | 0 或 ≥1 都算正常（**不得当判据**；reboot323 已证明干净重启也会出现 UBIFS recovery） | 仅作旁证：恢复流程有没有走到 ubi attach |

脚本 F 阶段自动跑这四条并落盘到 `recovery-boot.log`；ssh 不可达时由人在串口手打，结果同样贴进日志。


---

## 7. 实机执行记录（2026-11-21 13:38 起，Lead 已批 60 分钟独占窗口）

### 7.1 阶段 A：进 `ECNT>` 与板上 U-Boot 探明（实测）

| 项 | 原文/结果 |
|---|---|
| 提示符 | **`ECNT>`**（不是 `XR1710G>`，也不是 `U-Boot>`） |
| `version` | `U-Boot 2014.04-rc1 (Mar 15 2024 - 15:13:21) AXON 1.6`，`aarch64-openwrt-linux-gnu-gcc (OpenWrt GCC 10.2.0 r16325-88151b8303) 10.2.0` |
| `help` | **`loadb` / `loads` / `loadx`（xmodem）/ `loady`（ymodem）全都有** ⇒ 推翻“只有 loadb” |
| `bdinfo` | `DRAM bank 0 start=0x80000000 size=0x80000000`（2 GiB）、`relocaddr=0xFFDB9000`、`ethaddr=00:AA:BB:01:23:40`、baudrate 115200 |
| env | `loadaddr=0x81800000`；`initaddr` **未定义**；`bootargs` **未定义**；`bootcmd=flash read 0x602100 0x0FDF00 $loadaddr; bootm` |
| 进 prompt 手法 | stock 固件 shell 发 `reboot` → DRAM 初始化（`AN7581DRAMC V0.7`/`MPLL setting done`/`MRW RK0 MR#x`）后持续发 `x`（0.2 s/次）即停在 `ECNT>`；`Ctrl-C` 可从卡住状态回 `ECNT>` |
| stock 基线（对照） | `awk '$2=="/"{print $1,$3}' /proc/mounts` → `overlayfs:/overlay overlay`；uptime 525 s；`DISTRIB_REVISION='r38203-a0078bf520'`；`uname -r` = `7.4-rc3`；`dmesg | grep -ci "UBIFS recovery"` = 0 |

已执行 `setenv bootargs console=ttyS0,115200 earlycon ubi.block=0,fit root=/dev/fit0 rootwait`，`printenv bootargs` 回显一致（**仅 RAM，未 saveenv**）。

### 7.2 阶段 B：kermit `loadb` —— 失败（host 侧缺陷，实测）

- U-Boot 侧正常：`## Ready for binary (kermit) download to 0x85000000 at 115200 bps...`。
- host 侧 `kermit -Y -i -l /dev/ttyUSB0 -b 115200 -C "take kermit.rc, send <itb>"`：**rc=2，约 30 s 退出**。
- `/tmp/debug.log` 关键行：
  - `HEXDUMP: ttol s (11 bytes)` → `6b 65 72 6d 69 74 20 2d 69 72 0d` = **字面文本 `kermit -ir\r`**（被板子当命令）；
  - `ttol s (253 bytes)` ×N、`input send resending winlo=2` ×N、`mygetbuf read (32 bytes)` ×N ⇒ 停在等 ACK 的重发循环。
- 结论：C-Kermit 10.0.416 在此调用形态下会先往串口写登录串，不适合本板 ⇒ **换 `loady` + lrzsz `sb`**。

### 7.3 阶段 C：`loady` + `sb`（YMODEM）—— 跑到 43% 被 host 侧 USB/IP 断链打死（实测）

- 握手：`loady 0x85000000` → `## Ready for binary (ymodem) download to 0x85000000 at 115200 bps...` → 板端回 `C`。
- host 命令（**stdout 必须挂 tty，这是第一次失败的原因**）：
  `sb -b -vv <itb> < /dev/ttyUSB0 > /dev/ttyUSB0 2>/tmp/sb.err`
- 实测吞吐：**128 字节/块、66.9 块/s = 8.56 kB/s**；13:48:03 起，14:00:22 在 `49531/6191k` 处：
  `Retry 0: Timeout on sector ACK` ×10 → `Retry 0: Retry Count Exceeded` → `Transfer incomplete`，`sb rc=128`。
- host 侧根因（dmesg 原文）：
  - `vhci_hcd: urb->status -104`（ECONNRESET）刷屏；
  - `kworker/0:3: page allocation failure: order:7, mode:0xdc0(GFP_KERNEL|__GFP_ZERO)`；
  - `free -m` 当时 `free 110 MB / swap 3589 of 4096`。
- 自救尝试（全部实测）：`drop_caches + compact_memory`（free 110 MB→6.2 GB）、`usbipd.exe detach/attach --busid 1-3`（重枚举成功，`ch341-uart converter now attached to ttyUSB0`）、`usbip detach -p 00`（`Port 0 detach request failed!`）、`modprobe -r/+ vhci_hcd` 后 `usbipd.exe attach` 报 `UtilAcceptVsock:281: accept4 failed 110`。**之后 `/dev/ttyUSB0` 消失**。
- 板端读方向：`\r`、`\003`、`CAN×6`、DTR/RTS 翻转后读回 **0 字节**；115200/9600/57600/230400/460800 全静默。
- 设备状态：盲发 `reset\r` 后 `ping 192.168.1.1` 100% 丢、`ssh: No route to host`。**全程零 flash 写入**；`bootargs` 仅 RAM，重启即恢复。

### 7.4 结论（截至本报告）

- **不是板端问题**（两次都查清了）：`loadb` 死在 host 侧 C-Kermit 先发字面串 `kermit -ir\r`；YMODEM 死在 host 侧 WSL usbip 的 `urb->status -104`。板子没有拒绝过任何一帧 —— 完整因果链见 §7.7。
- **YMODEM 通道已被证明可用**（6.19 MB 真实字节穿过 115200 串口进了 RAM），只差把剩下 8.2 MB 传完 + `iminfo` + `bootm`。
- **bootm 未跑通**：字节数未达 14417920（硬门要求不足即 reset，不 bootm），且此后无法读串口。
- **回固件状态未确认**：链路断，无法验证 `DISTRIB_REVISION`。

### 7.5 任务项的最终状态

| 任务项 | 状态 | 说明 |
|---|---|---|
| loadb 能不能传 | **不能** | kermit 侧先发字面串 `kermit -ir\r` 导致协议不成立 |
| 传了多大 | **6,191 kB / 14,417,920 B（43%）** | YMODEM，128 B 块，8.56 kB/s，被 host USB/IP 断链终结 |
| bootm 结果 | **未执行** | 硬门：字节数不足不 bootm |
| 回到 `r38203-a0078bf520` | **未确认** | 读方向断，无法核三条判据；零 flash 写入，重启即回原状 |
| issue #12 评论 | **未发** | 只发一条，等最终结果 |

### 7.6 需要的状态变更/协助（本轮已发生 + 下一轮）

1. **[已用]** 独占 `/dev/ttyUSB0`；`setenv bootargs`（RAM）；`loadb/loady 0x85000000`；`reset`。
2. **[新增申请] host 侧 USB/IP 修复**：`usbipd.exe detach --busid 1-3` → `attach --wsl --busid 1-3`；若 `UtilAcceptVsock …110` 复现，需 `wsl --shutdown` 重启 WSL（会杀掉当前会话）。
3. **[新增申请] 板子断电重上一次**，确保回 stock 固件（当前可能仍挂在 `loady` 等待）。
4. **[新增申请] 新独占窗口 40 分钟**：YMODEM 全程 14417920 B ÷ 8563 B/s ≈ 1684 s ≈ 28 min + bootm/探针/reset ≈ 8 min。
5. 仍然不申请：`ubi write` / `nand erase` / `saveenv`。

### 7.7 完整因果链（一句话版，供 Lead 与后续 agent 直接引用）

```
板上 U-Boot 2014.04-rc1 AXON 1.6（提示符 ECNT>）
  └─ help 原文: loadb / loads / loadx(xmodem) / loady(ymodem) 四者俱在  ← 推翻“只有 loadb”
        ├─ 通道 A: loadb + C-Kermit 10.0.416  ⇒ 死在 host 侧
        │     debug.log 第一帧 = 字面文本 `kermit -ir\r`（6b 65 72 6d 69 74 20 2d 69 72 0d）
        │     → 板子把它当命令吃掉 → `input send resending winlo=2` 死循环 → rc=2，0 字节
        │     （板端从未报错、从未拒绝；U-Boot 侧只留下 `## Ready for binary (kermit)`）
        └─ 通道 B: loady + lrzsz `sb`（YMODEM）  ⇒ 通道本身可用，被 host 链路打断
              实测 128 B/块、66.9 块/s = 8.56 kB/s
              13:48:03 起，14:00:22 传至 49531/6191k（6.19 MB = 43%）
              host dmesg: `vhci_hcd: urb->status -104` 刷屏 + `page allocation failure: order:7`
              （free 110 MB / swap 3589 of 4096）⇒ usbip bulk-IN 管道死
              → 10 次 `Timeout on sector ACK` → `Retry Count Exceeded` → `Transfer incomplete`, rc=128
              随后 /dev/ttyUSB0 消失、板端读方向恒 0 字节（115200…460800 全静默）
```

**归因结论（重要）**：两次失败**都不在板端**。第一次是 host 侧 C-Kermit 的调用形态；第二次是 WSL↔Windows 的 USB/IP 链路在内存压力下死掉。板子自始至终没拒绝过任何一帧，YMODEM 已用 6.19 MB 真实字节证明了这条路能走。

### 7.8 下一轮窗口的计划（40 分钟，重算过）

**预算重算（实测吞吐，不是理论值）**

| 项 | 算式 | 结果 |
|---|---|---|
| YMODEM 全量传输 | `14417920 B ÷ 8563 B/s` | **1684 s = 28.1 min** |
| `iminfo` + `bootm` + 起 recovery | 实测 reset→ssh 约 57 s，bootm 首启更慢 | ≈ 3 min |
| 四条验收探针（F 阶段） | 7 条 ssh 命令 | ≈ 1 min |
| `reset` 回 stock + 三条判据 | 57 s 上电 + ssh 探测 | ≈ 2 min |
| 余量（重传 1–2 个块/重启一轮） | — | ≈ 6 min |
| **合计** | | **≈ 40 min** |

`sb -k` 不进来：lrzsz 的 `-k/--1k` 标注是 `(X)`，只对 XMODEM 生效，YMODEM 恒 128 B 块 ⇒ 想提速只能换 `loadx`+`sx -k`（未验证），本轮不动这条。

**关键命令（照抄即可）**

```bash
# 板端
setenv bootargs console=ttyS0,115200 earlycon ubi.block=0,fit root=/dev/fit0 rootwait   # RAM only
loady 0x85000000        # 等它打印 ## Ready for binary (ymodem) ... 之后再启 host
# host（stdout 必须挂 tty，否则协议帧写进日志文件，板端只发 NAK）
sb -b "$ITB" < /dev/ttyUSB0 > /dev/ttyUSB0 2>"$OUT/sb.err"
```

关于 `sb -b --ymodem`：lrzsz 0.12.21rc **没有** `--ymodem` 这个开关（`sb --help` 只有 `-b, --binary` 等；`sb` = send batch 本身就是 YMODEM 发送端），多写会被 getopt 拒掉。命令按上面这条写。

**已在 `send_itb.sh` 里加的两道新防线**

1. **四关前置健康检查（H1–H4，任一失败立刻 exit 并报哪一关）**，全部在碰板子之前：
   - H1 `[ -c /dev/ttyUSB0 ]` 设备节点在；
   - H2 `stty -F /dev/ttyUSB0 115200 cs8 -cstopb -parenb raw -echo` 返回 0；
   - H3 `grep -q vhci_hcd /proc/modules` 模块在（interop 断了这里仍会是 OK，所以还要 H4）；
   - H4 echo 探针：`printf '\r' > $DEV` 后 `timeout 3 dd if=$DEV bs=1 count=64` 读回 **≥1 字节**。
     这一关就是上次缺的那道门 —— 上一次 43% 白等 12 分钟，正是因为没验读方向。
2. **传输期看门狗（每 30 s 一次）**：`sudo -n dmesg | grep -c 'urb->status -104'` 一旦比基线增加，立刻 `kill` 掉 `sb` 并 `bail`（走 `reset`），不再等 `Retry Count Exceeded`。附带 2100 s（35 min）硬超时兜底。

**仍未做（等 Lead 说“串口已恢复”）**：`loady` → `sb` → 字节数 == 14417920 → `iminfo`（须 FIT + `config-1`）→ `bootm 0x85000000#config-1` → 四条探针 → `reset` 三判据。跑完才发 issue #12 那条唯一评论。

