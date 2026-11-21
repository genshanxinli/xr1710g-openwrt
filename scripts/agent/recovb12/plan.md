# recovb12 — issue #12 执行计划

> **状态（2026-11-21 14:20，实测后修订）**：纸上推演已被实机证据替换。
> - 板上 U-Boot 是 `U-Boot 2014.04-rc1 AXON 1.6`，提示符 **`ECNT>`**；`help` 原文里 `loadb`/`loads`/`loadx`/`loady` **四者俱在**。
> - `loadb`+kermit **通道作废**（host 侧 C-Kermit 先发字面串 `kermit -ir\r`，0 字节，rc=2）。
> - 改用 `loady` + lrzsz `sb`（YMODEM）：实测 **8.56 kB/s**，跑到 43% 被 host 侧 WSL usbip 断链（`vhci_hcd: urb->status -104`）打断。
> - 下一轮窗口 **40 min**；预算、四关健康检查、看门狗见 §3 与 §6。因果链见报告 §7.7。

## 1. 地址表（静态可证）

| 区间 | 来源 | 用途 |
|---|---|---|
| 0x80000000–0x801FFFFF | `target/linux/airoha/dts/an7581.dtsi:35` | ATF（no-map） |
| 0x80200000 | FIT `kernel-1` load/entry（`dumpimage -l`） | U-Boot 把压缩 kernel 拷到这里并原地解压 |
| 0x80200000–0x82A36808 | 实测：解压后 Image 42,166,280 B | 解压输出，末端与 0x81800000 区间重叠 |
| 0x81800000 | `defenvs/an7581_xr1710g_env: loadaddr` + `CONFIG_SYS_LOAD_ADDR`（`.config:202`） | 原方案装 FIT 处 —— 与解压输出重叠 ⇒ 不用 |
| 0x84000000–0x849FFFFF | `an7581.dtsi:41` npu-binary | 保留 |
| **0x84A00000–0x86FEFFFF** | issue #12 评论里 Linux `/proc/iomem` 实测的 System RAM | **空闲，可放 FIT** |
| 0x86FF0000 | `an7581.dtsi:48` ramoops | 保留 |
| 0x87000000–0x88FFFFFF | `an7581.dtsi:54` qdma0-buf | 保留 |
| 0x89000000–0x89FFFFFF | `an7581.dtsi:59` qdma1-buf ⇒ env `initaddr` 落在这里 | 不用 |
| 0x81E00000 | `CONFIG_TEXT_BASE`（`.config:186`） | U-Boot 链接基址（运行时已重定位到 DRAM 顶） |

**0x84A00000–0x86FEFFFF 这个窗口的出处**：issue #12 第 4 条评论（genshanxinli，2026-11-20T09:16:56Z）里设备 `cat /proc/iomem` 原文：

```
80000000-801fffff reserved(ATF)         80200000-83ffffff System RAM (62 MiB)
84000000-849fffff reserved(npu-binary)  84a00000-86feffff System RAM
86ff0000-90e06fff reserved(qdma/npu…)   90e07000-ffffffff System RAM
```

同评论建议把 `loadaddr=0x81800000` 改成 `0x85000000`（`package/boot/uboot-airoha/patches/999-airoha-add-gemtek-xr1710g.patch:147`）。DTS 交叉验证：npu-binary 到 0x849FFFFF 止（`an7581.dtsi:41`）、ramoops 从 0x86FF0000 起（`an7581.dtsi:48`）。

**解压上界算式**：`0x80200000 + 0x2836808 = 0x82A36808`（payload 42,166,280 B）；保守用 kernel header `image_size`：`0x80200000 + 0x28A0000 = 0x82AA0000`。旧 `loadaddr` 区间 `0x81800000-0x825C0000` 与两者都重叠 ⇒ 弃用。

**结论：装载地址用 `0x85000000`，14417920 B 结束于 0x85DC0000 < 0x86FF0000。**
Fit 拷 kernel 到 0x80200000 后解压到 0x82A36808，不碰 0x85000000；“FIT 与解压输出重叠”这个坑同时绕开。
`initaddr=0x89000000`（树里 defenv / 板上 env 的 `recovery_addr`）会踩 qdma1-buf，不适合 14.4 MB 的 ITB。

## 2. 确切命令行（纸上）

```
# A. 打断 autoboot → 提示符 ECNT>（实测；不是 XR1710G>/U-Boot>），全程只改 RAM
printenv loadaddr                      # 实测 0x81800000
printenv bootargs                      # 实测 未定义
setenv bootargs 'console=ttyS0,115200 earlycon ubi.block=0,fit root=/dev/fit0 rootwait'
#   ↑ 与 target/linux/airoha/dts/an7581-xr1710g-ubi.dts:26 逐字一致，不加 rdinit=

# B. 串口灌 RAM（YMODEM；loadb/kermit 已实测作废）
loady 0x85000000                       # 等到 '## Ready for binary (ymodem) download to 0x85000000 at 115200 bps...'
#   host: sb -b <itb> < /dev/ttyUSB0 > /dev/ttyUSB0 2>$OUT/sb.err     ← stdout 必须挂 tty！
#   （lrzsz 没有 --ymodem 开关；sb 就是 YMODEM 发送端，-b 是唯一需要的）
iminfo 0x85000000                      # 应打印 FIT: kernel-1 + fdt-1 + config-1('conf-1')
#                                       # 字节数必须 = 14417920（0xDC0000），否则不 bootm

# C. 启动
bootm 0x85000000#config-1
```

### 为什么是 `bootm <addr>#config-1` 而不是带 ramdisk
- `dumpimage -l` 显示 recovery ITB 的 `config-1 = kernel-1 + fdt-1`，**没有 ramdisk 节点**，也没有 `bootargs` 属性 ⇒ U-Boot 不会改写我们 setenv 的 bootargs。
- kernel `Image` 内部自带 cpio（`__initramfs_start = 0xffffffc080d8a6dc`，对应 Image 偏移 0xd8a6dc），1409 个条目，含 `/init`、`/sbin/init`、`bin/busybox`、`sbin/procd`。
  ⇒ kernel 自己解出 initramfs，`bootm` 不需要任何额外 ramdisk 参数。
- `#config-1` 只是锁死配置节点，避免多 config 的 ITB 选错；对单 config 镜像等价于 `bootm 0x85000000`。

### 为什么 bootargs 不加 `rdinit=/sbin/init`
实测 ITB 里的 `/init`：

```sh
#!/bin/sh
export INITRAMFS=1
DIRS=$(echo *); NEW_ROOT=/new_root
mkdir -p $NEW_ROOT; mount -t tmpfs tmpfs $NEW_ROOT
cp -pr $DIRS $NEW_ROOT
exec switch_root $NEW_ROOT /sbin/init
```

加了 `rdinit=/sbin/init` 会跳过 `/init` ⇒ `INITRAMFS=1` 不导出、根仍是 ramfs、procd 会去找 `/dev/fit0` 挂 rootfs（`ubi.block=0,fit root=/dev/fit0`） ⇒ 走不该走的分支。**默认 /init 路径才是这个 ITB 构建时的目标路径。**
`rdinit=/sbin/init` 只作为失败后的 A/B 备选。

## 3. 传输时间预算

> **实测值优先（2026-11-21 14:00）**：YMODEM 128 B 块、66.9 块/s = **8.56 kB/s** ⇒
> `14417920 ÷ 8563 = 1684 s = 28.1 min`，加 bootm/探针/reset ≈ 8 min ⇒ **40 min 窗口**。
> 下面的 kermit 理论表只作历史记录保留（该通道已作废）。

N = 14,417,920 B；8N1 = 10 bit/B；115200 baud ⇒ 11520 B/s ⇒ 线速下限 **1251.5 s = 20.9 min**。

| 包大小 | 包数 | 下行字节(含7B头) | 传输 | 停等周转(2 ms/包) | 合计 |
|---|---|---|---|---|---|
| 9024（U-Boot 报的 MAXL = 94×95+94） | 1598 | 14,429,106 | 1252.5 s | 3.2 s | **~22 min**（乐观，含 3–5% prefixing） |
| 1024 | 14080 | 14,517,480 | 1260 s | 28 s | ~21.5 min |
| 94 | 153382 | 15,491,594 | 1345 s | 307 s | **~28 min**（保守） |
| 9024 + `set prefixing all` | 1598 | ×~1.7 | ~2130 s | — | ~36 min |
| 94 + `set prefixing all` + 重传 | 153382 | ×~1.7 | ~2800 s | — | **~47–60 min**（最坏） |

窗口/包大小的影响：
- U-Boot 在 CAPAS 应答里明确 **不做窗口**（`cmd/load.c:795-810`），所以是纯停等 —— 唯一的杠杆是包大小，`set window` 无意义。
- 它只接受长包、**拒绝 QBIN**（8-bit prefixing）⇒ host 侧用 `set prefixing minimal`（8-bit 干净路，3–5% 开销），不要 `all`（binary 上 ~1.7×）。
- 校验类型只有 1（6-bit checksum），没有 CRC16 ⇒ 长包出错概率略高；9024 若连坏 3 次就退到 1024。
- 预算给 **60 min 独占窗口**（传输 22–28 min + bootm 到 login + reset 回滚 57 s + 余量）。

## 4. 需要串口确认的探针（进 prompt 后先打这几条）

```
version                # 板上到底是哪颗 U-Boot（预期 XR1710G-2026-10-16-g94476aa18f0b-dirty）
bdinfo                 # DRAM 起止/大小，确认 0x85000000 可用、U-Boot 重定位位置
help                   # 板上这颗有没有 loadb / loadx / loady（本树编的都有，见报告 §3）
printenv                # loadaddr / initaddr / fdt_addr_r / kernel_addr_r / bootargs 是否存在
```

`printenv` 结果未知 ⇒ 报告里记「待串口确认」；实测：三者都在，走 `loady`+`sb`（`loadb`+kermit 已废，见 §0）。

## 5. 失败判据 → 下一步

| 现象 | 判据 | 动作 |
|---|---|---|
| `## Ready for binary` 不出现 | 30 s 无横幅 | 停；查 `loady` 是否存在于板上 help |
| 字节数 ≠ 14417920 | `Total Size = 0x00XXXXXX` 不符 | 停，不 bootm；退 1024 包重传 |
| `Wrong Image Format for bootm command` | bootm 首行 | 地址/长度错；重灌 |
| `Bad Magic Number` | bootm | 同上 |
| `FIT ... hash/crc error` | `CONFIG_FIT_FULL_CHECK=y`（`.config:306`）会拦 | 传输损坏，重传 |
| kernel 起来但停在 `Kernel panic - not syncing: No working init found` | 串口 | 换 `rdinit=/sbin/init` 再来 |
| kernel 起来但 `uname -a` 不是 7.4-rc3 | 串口/ssh | 灌错镜像 |

## 6. 执行防线（已写进 `send_itb.sh`，上次踩过的坑）

### 6.1 四关前置健康检查（H1–H4，任一失败立即 exit 并打印关号）

全部在**碰板子之前**完成：

| 关 | 检查 | 失败含义 |
|---|---|---|
| H1 | `[ -c /dev/ttyUSB0 ]` | 设备节点不在（usbip 没 attach / ch341 没枚举） |
| H2 | `stty -F /dev/ttyUSB0 115200 cs8 -cstopb -parenb raw -echo` | tty 打不开或参数设不下 |
| H3 | `grep -q vhci_hcd /proc/modules` | usbip 宿主模块没载 |
| H4 | `printf '\r' > $DEV` 后 `timeout 3 dd if=$DEV bs=1 count=64` 读回 **≥1 字节** | 写方向可能通、**读方向死了** —— 这就是上次白等 12 分钟缺的那道门 |

### 6.2 传输期看门狗（每 30 s）

```
base=$(sudo -n dmesg | grep -c 'urb->status -104')
每 30 s: now=$(... 同上 ...) ；now > base ⇒ kill sb + bail（走 reset），不等 Retry Count Exceeded
另加 XFER_TIMEOUT=2100 s（35 min）硬超时兜底
```

### 6.3 两个必须写进脑子的调用事实

1. `sb` 的协议帧走 **stdin + stdout**。`> logfile` 会把帧写进文件、板端只发 NAK ⇒ stdout 必须是 `$DEV` 本身。
2. 不能用 `pkill -f 'dd if=/dev/ttyUSB0'` 收采集进程 —— 匹配到脚本自己的命令行会把脚本 SIGTERM 掉。用 `setsid` + `kill -- -$pid` 杀进程组。
