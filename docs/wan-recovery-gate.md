# WAN 刷机恢复闸门（G0）

**状态**：门限文档 + 2026-11-20 事实核对。本文定义“允许开始刷机前必须满足什么”；
下面的核对结果是**现在**的满足度，不是“已经做到”。

**本轮结论（先行）**：

- 恢复镜像**已经构建出来了**（`bin/targets/airoha/an7581/`，12 845 056 字节），
  旧文“仓库里没有可用的恢复镜像产物”的前提已被取代（superseded）。
- **串口今天不可用**：主机侧 usbipd/WSL 网络模式问题未解决，`/dev/ttyUSB0` 不存在。
  所以 G0 的串口 PASS 判据**当前不可达**。
- U-Boot 环境在 UBI 的两个卷里，**两个卷都是空白的（全 0xFF）**，
  `fw_printenv` 打印的是编译进 U-Boot 的默认值（`bootdelay=2`）。
- 设备**没有** `nanddump`/`nandwrite`/`flash_erase`（只装了 `ubi-utils`），
  所以文中的 SPI-NAND 备份命令今天跑不动，要先补 `mtd-utils`（属状态变更）。
  `/dev/mtdNro` + `dd` 可以**立刻**做只读备份。
- 3 轮“刷入 → 启动 → 回滚”**没跑**。G0 仍未通过。

**关联**：#88（本文）、#12（initramfs 恢复，不是替代）、#56、#90。

证据图例：**实测** = 本轮在设备或主 checkout 上直接读到的输出；**代码** = 从树里的文件
读出、未上机；**推断** = 由代码/物理常识推出、无输出支撑；**未验证** = 没做。

## 0. 一句话规则

**没有串口、没有 SPI-NAND 全片备份、没有回滚路径，就不刷。** 三条缺一条，G0 不通过。

今天三条的状态：串口 ✗（主机侧阻塞）、备份 ✗（工具缺失，只有 `dd` 只读兜底）、
回滚路径 **未验证**（恢复镜像有了，但没在设备上跑过一次）。所以**今天不许刷**。

## 0.1 事实台账（本轮核对）

| 事实 | 值 | 来源 | 标签 |
|---|---|---|---|
| 设备固件 | `SNAPSHOT r38047-a86ce12e27`，`airoha/an7581` | `cat /etc/openwrt_release` | 实测 |
| 板名 | `gemtek,xr1710g-ubi` | `cat /tmp/sysinfo/board_name` | 实测 |
| 兼容版本 | `2.0` | `uci -q get system.@system[0].compat_version` | 实测 |
| 恢复镜像存在 | 12 845 056 B，`...-ubi-initramfs-recovery.itb` | 主 checkout `ls -l bin/targets/airoha/an7581/` | 实测 |
| 恢复镜像 SHA-256 | `e3107f22ada54d0b4d014e404b214bbe3111de40cd8366c1be64e9da59f61a31` | `sha256sum`（主 checkout） | 实测 |
| 构建版本标记 | `r38047-a86ce12e27` | `cat bin/targets/.../version.buildinfo` | 实测 |
| mtd 分区表 | 4 个分区，与 DTS 完全一致 | `cat /proc/mtd`；DTS `:139-187` | 实测 |
| UBI 卷 | `fit`/`ubootenv`/`ubootenv2`/`factory`/`rootfs_data`/`provisioning` | `ubinfo -a` | 实测 |
| 坏块 | `Count of bad physical eraseblocks: 0` | `ubinfo -a` | 实测 |
| U-Boot 环境 | `Bad CRC, using default environment` | `fw_printenv` | 实测 |
| 环境卷内容 | `/dev/ubi0_1`、`/dev/ubi0_2` 前 256 B 全 `ff` | `hexdump -C -n 256` | 实测 |
| 默认 `bootdelay` | `2`（秒） | `fw_printenv` 默认环境 | 实测 |
| mtd-utils | `nanddump`/`nandwrite`/`flash_erase` 均 MISSING，只装 `ubi-utils-2.3.1-r1` | `command -v`；`apk list -I` | 实测 |
| 只读 mtd 节点 | `/dev/mtd0ro` … `/dev/mtd3ro` 存在，`dd ... count=1` 读通 | `ls -l /dev/mtd*`；`dd if=/dev/mtd0 of=/dev/null bs=4096 count=1` | 实测 |
| 串口 | `/dev/ttyUSB0` 不存在；`usbipd attach --wsl` 报 `Networking mode 'consomme' is not supported` | `docs/serial/console-setup.md:14,19`（同日实测记录） | 实测（引自该文，未复跑） |
| U-Boot 版本（运行时） | `XR1710G-2026-10-16-g94476aa18f0b-dirty` | `docs/serial/console-setup.md:186` 的 boot 日志锚点 | 推断（来自他人抓取的 ssh dmesg，本轮未抓串口） |

`docs/garbage-router-market-2026-11.md` 曾在本节被引用（“3.3 V TTL”）：**该文件不在本树里**
（`ls docs` 无此项），那处引用已废弃（superseded）。串口电平因此回到 **推断**（TTL 3.3 V 是
这类 SoC 排针的常见电平，不是本仓库的实测）。

## 1. 串口

| 项 | 值 | 证据/状态 |
|---|---|---|
| 电平 | 3.3 V TTL | **推断**。旧文引用的 `docs/garbage-router-market-2026-11.md:115` 不在本树；上手前用万用表量 GND 与 TX 空闲电平 |
| 接线 | GND↔GND，TX↔RX，RX↔TX（交叉） | 交叉接法；不要接 VCC |
| 波特率 | 115200 8N1 | **代码**：`target/linux/airoha/dts/an7581-xr1710g-ubi.dts:27` `stdout-path = "serial0:115200n8"`；`:26` `console=ttyS0,115200` |
| 引脚定义 | **UNVERIFIED** | 仓库没有 5-pin 排针的 pinout；不要凭颜色/位置猜 |
| U-Boot 中断键 | **UNVERIFIED**（以横幅原文为准） | 仓库没有记录按键名。上电后读横幅：`Hit any key` → 任意键；`Press Ctrl-C` → `Ctrl-C` |
| 中断窗口 | **实测值 2 秒**（`bootdelay=2`，来自默认环境） | 见 §3：环境卷为空，U-Boot 用编译默认值。倒计时结束就重新上电重来 |
| 主机侧现状 | **不可用** | **实测**（`docs/serial/console-setup.md:19`）：WSL `networkingMode=Consomme` 与 usbipd-win 5.3.0 不兼容，`/dev/ttyUSB0` 不存在 |

**PASS 判据**：串口能稳定看到 U-Boot 横幅并停在 `U-Boot>` 提示符，键盘输入有回显；
横幅原文与倒计时秒数已记录。只看到内核日志不算通过——那说明已经错过中断窗口。

**当前判定：不通过**（主机侧串口拿不到；2 秒窗口会让“盲按”更容易失败，
建议先把 `bootdelay` 调大——那是写 U-Boot 环境，属状态变更，见 §6）。

## 2. SPI-NAND 备份

设备为 SPI-NAND。分区表来自设备树 `target/linux/airoha/dts/an7581-xr1710g-ubi.dts:139-187`，
本轮在设备上实测的分表与之**逐项一致**（`/proc/mtd`，erase size 全部 `0x20000`）：

| mtd | label | 偏移 | 大小 | DTS 只读 | 说明 |
|---|---|---|---|---|---|
| mtd0 | vendor | 0x00000000 | 0x00600000 (6 MiB) | `read-only` (`:142`) | 厂商区 |
| mtd1 | chainloader | 0x00600000 | 0x00100000 (1 MiB) | `read-only` (`:148`) | U-Boot 链加载 |
| mtd2 | ubi | 0x00700000 | 0x1b700000 (439 MiB) | 否 | `fit`/`ubootenv`/`ubootenv2`/`factory`/`rootfs_data`/`provisioning` |
| mtd3 | reserved_bmt | 0x1be00000 | 0x04200000 (66 MiB) | `read-only` (`:185`) | 坏块表保留区 |

整片 512 MiB（`0x20000000`）。UBI 实测：LEB 126 976 B，3512 LEB（445 939 712 B ≈ 425.2 MiB），
可用 LEB 0，坏块 0，保留 PEB 80。卷：`fit`(118 LEB) / `ubootenv`(9, 动态) / `ubootenv2`(9, 动态)
/ `factory`(9, 静态) / `rootfs_data`(3281 LEB, 397.3 MiB, 挂在 `/overlay`) / `provisioning`(2 LEB)。

编号与本文不一致时**停下**，不要按本文的编号硬写。

### 2.1 工具前提（本轮实测的阻塞点）

设备上**没有** `nanddump` / `nandwrite` / `flash_erase` / `mtd_debug`；只装了 `ubi-utils`
（`ubiformat`）。所以下面两条路径只能选一条：

- **路径 A（推荐，但属状态变更）**：装 `mtd-utils` 后再跑 2.2 的 `nanddump`。
  安装本身是状态变更，需要 Lead 批准。
- **路径 B（现在就能做，只读）**：用内核自带的只读节点 `/dev/mtdNro` + `dd`。
  拿不到坏块/ECC 统计（那部分要靠 `dmesg` 与 `ubinfo`），但镜像字节是完整的。

`/dev/mtdNro` 与 `/dev/mtdN` 是两套节点：读**只用 `ro`**，避免任何误写。

### 2.2 采集（路径 A：装好 mtd-utils 后）

```sh
mkdir -p ./nand-backup && cd ./nand-backup
# 元数据先落到设备上（很小，tmpfs 装得下），再拉回主机
ssh root@192.168.1.1 'mkdir -p /tmp/nand-backup
  cat /proc/mtd   > /tmp/nand-backup/proc-mtd.txt
  cat /proc/cmdline > /tmp/nand-backup/cmdline.txt
  cat /proc/partitions > /tmp/nand-backup/partitions.txt
  ubinfo -a      > /tmp/nand-backup/ubinfo.txt
  fw_printenv    > /tmp/nand-backup/fw-env.txt 2>&1'   # 会带 Bad CRC 警告，照录

# 镜像本体不走设备 /tmp（tmpfs 只有内存那么大），直接 ssh 管道落到主机
for i in 0 1 2 3; do
  ssh root@192.168.1.1 "nanddump -f - /dev/mtd${i} 2>/dev/null" > "./mtd${i}.bin"
done

sha256sum ./mtd*.bin > ./SHA256SUMS
ls -l ./mtd*.bin > ./ls.txt
```

`nanddump -f -` 把镜像写到 stdout，就是上面“必须走管道”的做法（设备 `/tmp` 是 tmpfs，
整片 512 MiB 写不进去）。OOB/坏块信息在 `nanddump` 的 stderr 里，要留就改成
`2> "./mtd${i}.err" 1> "./mtd${i}.bin"`（先把 stderr 落到主机侧）。

### 2.3 采集（路径 B：现在就能跑的只读兜底）

```sh
mkdir -p /tmp/nand-backup
cat /proc/mtd > /tmp/nand-backup/proc-mtd.txt
ubinfo -a     > /tmp/nand-backup/ubinfo.txt
fw_printenv   > /tmp/nand-backup/fw-env.txt 2>&1

# 设备侧 /tmp 是 tmpfs（内存），整片 512 MiB 会把它写爆；所以 dd 直接走 ssh 管道，
# 落到主机硬盘上，设备上不留镜像。split 在设备上是 MISSING（实测），不要用它。
for i in 0 1 2 3; do
  ssh root@192.168.1.1 "dd if=/dev/mtd${i}ro bs=4096 2>/dev/null" > "./mtd${i}.bin"
done
sha256sum ./mtd{0,1,2,3}.bin > ./SHA256SUMS
ls -l ./mtd*.bin ./SHA256SUMS >> ./SHA256SUMS
```

- 设备侧的 `dd ... 2>/dev/null` 只是把 `dd` 的进度统计丢掉；**ECC 报错会被一起吞掉**，
  想知道读错误就改成 `2>./mtd${i}.err` 并 `ssh ... 'cat'` 带回。
- 整条链路是 TCP 流：中途断线会**静默截断**目标文件，所以每片都要核对字节数
  （`mtd0`=6291456、`mtd1`=1048576、`mtd2`=460324864、`mtd3`=69206016）。
- `/overlay` 在 mtd2 的 `rootfs_data` 卷上，读 mtd2 时系统仍在写它：拿到的 `rootfs_data`
  可能不一致；只有停写业务（或路径 A 停机）才谈得上一致。

- 读 UBI 分区若有 ECC 错误，记录地址；不要“重试到没错误”掩盖。

### 2.4 校验与存放

```sh
cd ./nand-backup && sha256sum -c SHA256SUMS   # 主机侧，镜像已经在这
```

- 至少两份异地副本：一份在采集主机，一份在离线介质。
- **设备上没有可用的 `scp`**（实测：`scp` 二进制在，但缺 `/usr/libexec/sftp-server`，
  拉文件报 `Connection closed`）。取回只走 ssh 管道，镜像用 §2.2/§2.3 的 `dd`/`nanddump`
  直通，元数据这样搬：

```sh
for f in proc-mtd.txt cmdline.txt partitions.txt ubinfo.txt fw-env.txt; do
  ssh root@192.168.1.1 "cat /tmp/nand-backup/$f" > "./$f"
done
```

- 存放目录命名带日期与设备：`xr1710g-<serial>-<YYYYMMDD>/`；与本文同级的
  `research/lead/triage/offline/recovery/` 只放**清单与哈希**，不放镜像本体。
- 记录：序列号、固件版本、采集时间、每个 mtd 的大小与 SHA-256、`/proc/mtd` 原文、`ubinfo -a` 原文。
- 恢复前先 `sha256sum -c`；哈希不符的备份视为没有备份。

**PASS 判据**：4 个分区都有非空镜像，`SHA256SUMS` 全部 OK，且清单已离开设备保存。

**当前判定：不通过**（`nanddump` 缺失；`dd` 只读路径只验证过 `/dev/mtd0` 单块读通、全片没跑；没有异地副本）。

## 3. U-Boot 环境在 UBI，且当前是空的（本轮实测）

镜像 `target/linux/airoha/image/an7581.mk:90-91` 设 `UBOOTENV_IN_UBI := 1`、
`KERNEL_IN_UBI := 1`，设备树因此建了两个环境卷（`dts:157`、`dts:164`，
`nvmem-layout { compatible = "u-boot,env-redundant-bool" }`）。设备上的读取端配置是

```
/dev/ubi0_1 0x0 0x1f000 0x1f000 1
/dev/ubi0_2 0x0 0x1f000 0x1f000 1
```

`fw_printenv` 输出以 `Warning: Bad CRC, using default environment` 开头，随后是
`bootcmd=run distro_bootcmd`、`bootdelay=2`、`baudrate=115200`、`ipaddr=192.0.2.1` 等默认值；
两个卷的前 256 字节 `hexdump` 都是 `ff …`（擦除态）。

**后果（写进闸门里）**：

1. 板上**没有**一份可回滚的 U-Boot 环境快照——备份“当前 env”这件事现在做不了，
   只能记录 U-Boot 编译进去的默认值（`fw_printenv` 的这份输出）。
2. 中断窗口就是默认的 `bootdelay=2`。想在串口上从容操作，要先 `fw_setenv bootdelay 3`
   （或更大）并 `saveenv`——**这是写 env，属状态变更，见 §6**。
3. 反过来，环境空着也意味着 `fw_setenv` 不会覆盖任何手工配置；第一次写会创建卷内容，
   之后两份冗余副本才生效（`env-redundant-bool`）。

## 4. 刷机与回滚

### 4.1 兼容闸门（这是“能刷”的那道门，不是“该刷”）

代码链（**代码**）：

1. `target/linux/airoha/image/an7581.mk:83` `DEVICE_COMPAT_VERSION := 2.0`，
   `:84-86` 的 `DEVICE_COMPAT_MESSAGE` 说明这是 BMT/BBT 分区改动后的重刷要求。
2. 镜像元数据里的 `compat_version` 与板上 `system.@system[0].compat_version` 比对：
   `package/base-files/files/lib/upgrade/fwtool.sh:49-50` 读板上值（缺省 `1.0`），
   `:52-54` 读镜像值，`:75-80` 主版本不一致即 `return 1` 并打印消息。
3. 该返回值经 `package/base-files/files/usr/libexec/validate_firmware_image:46-48`
   落成 `notify_firmware_invalid`（`:14-16`），**只清 `VALID`，不动 `FORCEABLE`**；
   `FORCEABLE` 初值在 `:10` 为 1，只有 `notify_firmware_broken`（`:19-22`）才清零。
4. `package/base-files/files/sbin/sysupgrade:402-411`：`valid=0` 时，若 `-F` 且
   `forceable=1`，打印 `Image check failed but --force given - will update anyway!` 继续。

**所以 `-F` 能过 2.0 闸门是设计如此，不是绕过漏洞。** 实测板上 `compat_version=2.0`（§0.1），
本树镜像也是 2.0，正常升级不需要 `-F`；`-F` 只用于“确实知道自己在写什么”的降级/救援。
把 `-F` 当默认手段用，等于放弃这道门，也放弃了 `allow_backup` 的保护。

同一道闸门在 README 前页有一节三行版警告（`README.md` 的 `### Soft-brick gate`），
面向“手里只有一台机器、还没读到这里”的人：**1.x 单元上不要用 `-F`**。
布局本身的来历（为什么是 4 分区而不是参考树 2 分区）见 `docs/ubi-layout.md`。

### 4.2 允许的刷机方式

- 首次验证用 **initramfs 恢复镜像**（本树已产出，见 §5）或已知可回滚的 sysupgrade 镜像；
  不要直接整片写 UBI。
- 写入前把 `/etc/config/network`、`/etc/config/firewall`、`uci export` 存到
  `/tmp/nand-backup/` 并随备份带走。
- 刷机命令、镜像名、SHA-256、串口日志全部落盘。

### 4.3 回滚

优先级从高到低：

1. **U-Boot + TFTP**：串口停在 `U-Boot>`，用恢复镜像启动（`bootm`/`tftpboot` 按横幅给的命令），
   再从 RAM 里的 shell 恢复 UBI 或写回备份。
2. **现有系统内 sysupgrade**：`sysupgrade -n <known-good.img>`，保留串口观察。
3. **SPI-NAND 写回**：只在 1/2 都不可用时使用；写回前再次校验备份哈希，按分区
   `flash_erase` + `nandwrite`（需要 `mtd-utils`），逐分区确认，不要整片一把梭。

回滚后必须确认：串口能到 shell、`ip link` 能看到 `wan`/`lan2`/`lan3`/`lan4`
（本镜像的 busybox `ip` **实测支持 `-br`**：`ip -br link` 可用；旧文写“busybox 没有 `-br`”
已废弃（superseded））、`/proc/mtd` 分区表与备份时一致、
`uci get system.@system[0].compat_version` 仍是 `2.0`。

### 4.4 G0 通过标准

连续 **3 轮**「刷入 → 启动到 shell → 回滚成功」，每轮记录：

| 轮次 | 镜像 | 镜像 SHA-256 | 启动日志 | 回滚方式 | 回滚后 shell | 结果 |
|---|---|---|---|---|---|---|
| 1 | UNVERIFIED | — | — | — | — | 未跑 |
| 2 | UNVERIFIED | — | — | — | — | 未跑 |
| 3 | UNVERIFIED | — | — | — | — | 未跑 |

3 轮全绿才算 G0 PASS；任何一轮需要“再刷一次才好”都算失败并重新计数。

## 5. 恢复镜像的现状（本轮实测）

主 checkout（只读查看，未在那里构建；本 worktree 未构建）：

```
$ ls -l bin/targets/airoha/an7581/
-rw-r--r-- 1 l1n l1n   287532 Nov 20 12:07 openwrt-airoha-an7581-gemtek_xr1710g-ubi-chainload-uboot.itb
-rw-r--r-- 1 l1n l1n 12845056 Nov 20 12:07 openwrt-airoha-an7581-gemtek_xr1710g-ubi-initramfs-recovery.itb
-rw-r--r-- 1 l1n l1n 14861126 Nov 20 12:07 openwrt-airoha-an7581-gemtek_xr1710g-ubi-squashfs-sysupgrade.itb
-rw-r--r-- 1 l1n l1n     5122 Nov 20 12:07 openwrt-airoha-an7581-gemtek_xr1710g-ubi.manifest
$ cat bin/targets/airoha/an7581/version.buildinfo
r38047-a86ce12e27
$ sha256sum bin/targets/airoha/an7581/*.itb
68c105bffcd4c0f4b8833a9153a125d7120fbe065d2bc5ab82d666be8cabf194  ...-ubi-chainload-uboot.itb
e3107f22ada54d0b4d014e404b214bbe3111de40cd8366c1be64e9da59f61a31  ...-ubi-initramfs-recovery.itb
3fd3b368609b650206d96930ea4e3e8443e5b7768c944ccbf1f72e6da10028a2  ...-ubi-squashfs-sysupgrade.itb
```

镜像名的 `-recovery.itb` 后缀来自 `target/linux/airoha/image/an7581.mk:93-95`
（`KERNEL_INITRAMFS` 在 `:93-94`，`KERNEL_INITRAMFS_SUFFIX := -recovery.itb` 在 `:95`）。

**这条证据只证明“镜像在”、不证明“能启动”**。产物存在 ≠ 在设备上验证过；
它还没被刷过，也没有串口日志。恢复镜像要能当回滚手段，必须先过 §4.4 的第 1 轮。

## 6. 实验护栏（无人值守禁止刷机）

刷机必须在有人看着串口时进行。若要做“限时回滚”实验，先把回滚做成定时器：

```sh
cp /etc/config/network  /tmp/nand-backup/network.orig
cp /etc/config/firewall /tmp/nand-backup/firewall.orig
uci export > /tmp/nand-backup/uci.orig

( sleep 600; sysupgrade -n /tmp/nand-backup/known-good.img ) &
```

- 定时器只作为**额外**保险，不替代串口与备份。
- 实验前确认 `known-good.img` 的 SHA-256 与备份清单一致。
- 断电/重启会丢定时器；所以“无人值守 + 仅靠定时器”仍不允许。
- **实测** 设备上 `nohup`、`pkill` 都是 MISSING（有 `killall`），`sleep 0.5` 报
  `sleep: invalid number '0.5'`（只吃整数秒），所以上面的 `( … ) &` 是唯一能用的写法。
- 任何自动恢复脚本都要先干跑（`-n`/echo）。

## 7. 与 #12 的关系

#12 解决的是“刷坏了怎么用 initramfs 进去救”，本文解决的是“什么条件下才允许开始刷”。
G0 不通过时，#12 的工具再全也不开始；G0 通过也不代表 #12 的恢复镜像已经验证过——
两者是串联门，不是替代关系。本轮变化是：#12 的产物**已经有了**（§5），
但它还缺一次串口观察下的启动验证。

## 8. 未验证项清单（按本轮核对后的状态）

| 项 | 状态 |
|---|---|
| 5-pin 排针 pinout | **UNVERIFIED**（不要猜针脚） |
| U-Boot 中断键名 | **UNVERIFIED**（以横幅原文为准）；窗口长度已实测为 2 s |
| 主机侧串口 | **实测不可用**（`docs/serial/console-setup.md:19`） |
| 恢复镜像在设备上启动 | **未验证**（镜像存在，未刷） |
| 3 轮刷机/回滚 | **UNVERIFIED**（本仓库没有日志） |
| SPI-NAND 备份 | **未完成**：工具缺失；`dd` 只读路径未跑完 |
| mtd 编号与坏块分布 | **实测一致**（`/proc/mtd` 与 DTS 对得上，UBI 坏块 0）；写回路径未验证 |
| U-Boot 环境回滚快照 | **没有**（两个 env 卷为空，只有默认值可记录） |
| 在真·1.x 单元上确认闸门挡住 | **未验证**（手上只有一台 2.0 单元；且厂商固件根本不跑本树的 `sysupgrade`，闸门在那里没有执行点）。`-F` 之后具体崩在哪一步是**推断**：2.0 镜像的 `fit` 卷写进 1.x 的 `ubi` 偏移，引导器找不到自己的分区/卷 |
| 本树是否产出过 1.x 布局 | **已核实为否**（**代码**）：`git log -S'reserved_bmt'` 首个命中 `f0105e318a` 已是 4 分区 + compat 2.0；`git log --all -S'DEVICE_COMPAT_VERSION := 1' -- target/linux/airoha/image/an7581.mk` 无输出。详见 `docs/ubi-layout.md` §6 |

## 9. 如何验证本文

```sh
# 分区与串口配置（代码）
grep -n 'stdout-path\|console=ttyS0' target/linux/airoha/dts/an7581-xr1710g-ubi.dts
grep -n 'label = "vendor"\|label = "chainloader"\|label = "ubi"\|reserved_bmt' \
  target/linux/airoha/dts/an7581-xr1710g-ubi.dts
# 2.0 闸门链（代码）
sed -n '80,90p' target/linux/airoha/image/an7581.mk
sed -n '45,82p' package/base-files/files/lib/upgrade/fwtool.sh
sed -n '9,22p;44,50p' package/base-files/files/usr/libexec/validate_firmware_image
sed -n '400,412p' package/base-files/files/sbin/sysupgrade
# 设备侧（实测，只读）
ssh root@192.168.1.1 'cat /proc/mtd; uci -q get system.@system[0].compat_version; fw_printenv 2>&1 | head -3'
ssh root@192.168.1.1 'ubinfo -a | head -12; hexdump -C -n 32 /dev/ubi0_1'
ssh root@192.168.1.1 'command -v nanddump nandwrite flash_erase || echo "mtd-utils missing"'
# 构建产物（主 checkout，只读）
ls -l bin/targets/airoha/an7581/*.itb
sha256sum bin/targets/airoha/an7581/*.itb
# 本文保留未验证标记
grep -n 'UNVERIFIED\|未验证' docs/wan-recovery-gate.md
```
