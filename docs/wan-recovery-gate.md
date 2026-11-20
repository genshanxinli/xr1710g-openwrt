# WAN 刷机恢复闸门（G0）

**状态**：门限文档。仓库内没有一次完整的「刷机→启动→回滚」日志，因此下表全部是
**未验证**；它定义的是“允许开始刷机前必须满足什么”，不是“已经做到”。
**关联**：#88（本文）、#12（initramfs 恢复，不是替代）、#56、#90。

## 0. 一句话规则

**没有串口、没有 SPI-NAND 全片备份、没有回滚路径，就不刷。** 三条缺一条，G0 不通过。

## 1. 串口

| 项 | 值 | 证据/状态 |
|---|---|---|
| 电平 | 3.3 V TTL | `docs/garbage-router-market-2026-11.md:115` 记录 3.3V TTL；万用表复核 |
| 接线 | GND↔GND，TX↔RX，RX↔TX（交叉） | 交叉接法；不要接 VCC |
| 波特率 | 115200 8N1 | `target/linux/airoha/dts/an7581-xr1710g-ubi.dts:27` `stdout-path = "serial0:115200n8"`；`:26` `console=ttyS0,115200` |
| 引脚定义 | **UNVERIFIED** | 仓库没有 5-pin 排针的 pinout 图；不要凭颜色/位置猜。用万用表找 GND，再按 SoC 串口常规信号确认 TX/RX，或向硬件提供方索取 pinout |
| U-Boot 中断键 | **UNVERIFIED**（按键名以横幅为准） | 仓库没有记录具体按键。上电后读横幅：若出现 “Hit any key to stop autoboot”，在倒计时内按任意键；若出现 “Press Ctrl-C”，按 `Ctrl-C`。不要预设某个键，也不要在没有横幅时盲按 |
| 中断时机 | 上电/复位后、内核启动前 | 看到 U-Boot 横幅立即在串口输入；倒计时结束就重新上电。记录横幅原文与倒计时秒数，下一轮按同一时机操作 |

**PASS 判据**：串口能稳定看到 U-Boot 横幅并停在 `U-Boot>` 提示符，键盘输入有回显；横幅原文与倒计时已记录。
只看到内核日志不算通过——那说明已经错过中断窗口。

## 2. SPI-NAND 备份

设备为 SPI-NAND，分区见 `target/linux/airoha/dts/an7581-xr1710g-ubi.dts:133-186`：

| mtd | label | 偏移 | 大小 | 说明 |
|---|---|---|---|---|
| mtd0 | vendor | 0x00000000 | 0x00600000 (6 MiB) | 只读 |
| mtd1 | chainloader | 0x00600000 | 0x00100000 (1 MiB) | 只读，U-Boot 链加载 |
| mtd2 | ubi | 0x00700000 | 0x1b700000 (439 MiB) | 根分区/环境/factory |
| mtd3 | reserved_bmt | 0x1be00000 | 0x04200000 (66 MiB) | 坏块表保留区 |

整片 512 MiB（`0x20000000`）。分区表本身来自设备树；实际 mtd 编号以设备上
`cat /proc/mtd` 为准，编号不一致时**停下**，不要按本文的编号硬写。

### 2.1 采集（在能启动的 OpenWrt 上执行）

```sh
mkdir -p /tmp/nand-backup
cat /proc/mtd > /tmp/nand-backup/proc-mtd.txt
cat /proc/cmdline > /tmp/nand-backup/cmdline.txt
cat /proc/partitions > /tmp/nand-backup/partitions.txt

for i in 0 1 2 3; do
  nanddump -f "/tmp/nand-backup/mtd${i}.bin" "/dev/mtd${i}" \
    2> "/tmp/nand-backup/mtd${i}.err"
done

sha256sum /tmp/nand-backup/mtd*.bin > /tmp/nand-backup/SHA256SUMS
ls -l /tmp/nand-backup > /tmp/nand-backup/ls.txt
```

- `nanddump` 默认只导出数据区；坏块信息单独记录在 `.err` 与 `dmesg` 里。
- 读取 UBI 分区时若有 ECC 错误，记录错误地址；不要用“重试到没错误”的方式掩盖。
- 备份期间不要挂载/写入 mtd2。

### 2.2 校验与存放

```sh
cd /tmp/nand-backup && sha256sum -c SHA256SUMS
```

- 至少两份异地副本：一份在采集主机，一份在离线介质（U 盘/另一台机器）。
- 存放目录命名带日期与设备：`xr1710g-<serial>-<YYYYMMDD>/`，与本文档同级的
  `research/lead/triage/offline/recovery/` 只放**清单与哈希**，不放镜像本体。
- 记录：设备序列号、固件版本、采集时间、每个 mtd 的大小与 SHA-256、`/proc/mtd` 原文。
- 恢复前先 `sha256sum -c`；哈希不符的备份视为没有备份。

**PASS 判据**：4 个分区都有非空镜像，`SHA256SUMS` 全部 OK，且清单已离开设备保存。

## 3. 刷机与回滚

### 3.1 允许的刷机方式

- 首次验证用 **initramfs**（#12）或已知可回滚的 sysupgrade 镜像；不要直接整片写 UBI。
- 写入前把当前 `/etc/config/network`、`/etc/config/firewall`、`uci export` 存到
  `/tmp/nand-backup/` 并随备份带走。
- 刷机命令、镜像名、SHA-256、串口日志全部落盘；不要“刷完再说”。

### 3.2 回滚

优先级从高到低：

1. **U-Boot + TFTP**：串口停在 `U-Boot>`，用已知可用的 initramfs/恢复镜像启动，
   再从 shell 恢复 UBI 或写回备份。
2. **现有系统内 sysupgrade**：`sysupgrade -n <known-good.img>`，保留串口观察。
3. **SPI-NAND 写回**：只在 1/2 都不可用时使用；写回前再次校验备份哈希，按分区
   `flash_erase` + `nandwrite`，逐分区确认，不要整片一把梭。

回滚后必须确认：串口能到 shell、`ip -br link` 能看到 `wan`/`lan2`/`lan3`/`lan4`、
`/proc/mtd` 分区表与备份时一致。

### 3.3 G0 通过标准

连续 **3 轮**「刷入 → 启动到 shell → 回滚成功」，每轮记录：

| 轮次 | 镜像 | 镜像 SHA-256 | 启动日志 | 回滚方式 | 回滚后 shell | 结果 |
|---|---|---|---|---|---|---|
| 1 | UNVERIFIED | — | — | — | — | 未跑 |
| 2 | UNVERIFIED | — | — | — | — | 未跑 |
| 3 | UNVERIFIED | — | — | — | — | 未跑 |

3 轮全绿才算 G0 PASS；任何一轮需要“再刷一次才好”都算失败并重新计数。

## 4. 实验护栏（无人值守禁止刷机）

刷机必须在有人看着串口时进行。若要做“限时回滚”实验，先把回滚做成定时器，
并确保断网/断电后仍能回到已知状态：

```sh
# 示例：保留原始配置，10 分钟后自动回滚到已知镜像
cp /etc/config/network  /tmp/nand-backup/network.orig
cp /etc/config/firewall /tmp/nand-backup/firewall.orig
uci export > /tmp/nand-backup/uci.orig

( sleep 600; sysupgrade -n /tmp/nand-backup/known-good.img ) &
```

- 定时器只作为**额外**保险，不应替代串口与备份。
- 实验前确认 `known-good.img` 的 SHA-256 与备份清单一致。
- 断电/重启会丢定时器；所以“无人值守 + 仅靠定时器”仍不允许。
- 任何自动恢复脚本都要先干跑（`-n`/echo），确认命令与路径再执行。

## 5. 与 #12 的关系

#12 解决的是“刷坏了怎么用 initramfs 进去救”，本文解决的是“什么条件下才允许开始刷”。
G0 不通过时，#12 的工具再全也不开始；G0 通过也不代表 #12 的恢复镜像已经验证过——
两者是串联门，不是替代关系。

## 6. 未验证项清单

- 5-pin 排针 pinout：**UNVERIFIED**（不要猜针脚）。
- U-Boot 中断键与倒计时长度：**UNVERIFIED**（以串口提示为准）。
- 3 轮刷机/回滚：**UNVERIFIED**（本仓库没有日志）。
- SPI-NAND 实际 mtd 编号与坏块分布：**UNVERIFIED**（以设备 `/proc/mtd` 与 `dmesg` 为准）。

## 7. 如何验证本文

```sh
grep -n 'stdout-path\|console=ttyS0' target/linux/airoha/dts/an7581-xr1710g-ubi.dts
grep -n 'label = "vendor"\|label = "chainloader"\|label = "ubi"\|reserved_bmt' \
  target/linux/airoha/dts/an7581-xr1710g-ubi.dts
grep -n 'UNVERIFIED' docs/wan-recovery-gate.md
grep -n 'nanddump\|sha256sum -c\|sysupgrade -n' docs/wan-recovery-gate.md
```

预期：前两条命中真实分区/串口配置；文档中保留 `UNVERIFIED`，且备份、校验、回滚命令齐全。
