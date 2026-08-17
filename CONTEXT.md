# CONTEXT.md

> XR1710G 自用 OpenWrt 固件仓库的**领域词汇表**（glossary）。只记录术语与边界，不含实现细节。
> 维护规则：每当领域术语被澄清/解决，立即更新本条。

## 设备与硬件

- **XR1710G** — Gemtek 制造的 Wi-Fi 7 路由器（FCC ID MXF-XR1710G），本仓库的目标设备。Airoha AN7581GT SoC + MediaTek MT7996 三频 Wi-Fi 7，2×10G（RTL8261BE）+ 2×1G 网口，2GB RAM / 512MB SPI-NAND。
- **W1700K** — 与 XR1710G 同源的 Quantum Fiber 定制设备（Gemtek 17xx 家族）。差异：W1700K 带 Silabs EFR32（蓝牙/Zigbee）与 Airoha GPS、LED 由 GPIO 驱动；XR1710G 去掉两者、LED 由 MT7530 交换芯片驱动。风扇/温控传感器存在版本差异：社区实测（naoki66/skyboooox/lvcdy）以 **NCT7802** 为主，PR #22397 描述含 **NCT7511Y**——**温控方案必须动态探测 hwmon 传感器而非硬编码型号**。上游驱动/脚本常以 W1700K 为对象，移植到 XR1710G 时必须核对这些差异。
- **AN7581（EN7581 系）** — Airoha SoC：1.3GHz 4 核 CPU + 8 核 NPU。OpenWrt 目标为 `airoha/an7581`。
- **MT7996** — MediaTek Wi-Fi 7 芯片组（2.4G MT7976GN 4×4 / 5G MT7977BN 4×4 / 6G MT7977AN 4×5，BE19000），经 PCIe x2 挂载于 AN7581。
- **RTL8261BE / RTL8261N** — Realtek 5G/10G 以太网 PHY（XR1710G 用 BE，W1700K 用 N）。驱动与固件 blob 尚未进内核主线，OpenWrt 以 pending 补丁 + `rtl826x-firmware` 包携带。
- **MT7530** — MediaTek 交换芯片，承载 2×1G 口。

## 引导与刷机

- **厂商签名 U-Boot** — 2014.04-rc1（AXON），带签名校验与 BMT/BBT 坏块管理，不支持 UBI。是首刷 OpenWrt 前的必经关卡。
- **chainloader** — 由厂商 U-Boot 链加载的 OpenWrt U-Boot（`ubi-chainload-uboot.itb`），绕开签名/BMT 限制以建立 UBI 布局（OpenWrt PR #22151）。
- **chainloader 槽** — SPI-NAND 偏移 0x600000 处的 1MiB 分区，存放 chainloader（HTTP U-Boot 的 `flash-slot.bin` 即写此槽）；厂商 U-Boot 的 `bootcmd` 覆盖为 `flash read … bootm` 后从此启动。
- **fit 卷** — UBI 内承载 FIT 镜像的卷（内核 + DTB + rootfs），内核以 `root=/dev/fit0`（fitblk）挂载；相关卷还有 `ubootenv`/`ubootenv2`（redundant env）、`factory`（无线校准 EEPROM）、动态 `rootfs_data`。
- **UBI installer** — 首次安装流程：TFTP 链加载 → installer 把 OpenWrt 写入 UBI。
- **HTTP U-Boot** — YYH2913 为 XR1710G 定制的第三方 U-Boot（写入 chainloader 槽）：192.168.255.1 网页恢复、10GbE、DHCP、链加载槽位固化，免串口刷机。恢复页内置 **UBI 布局选择器**（UBI 2.0 / 1.5 / 1.0）——决定擦除/重建边界，必须与镜像内嵌 FDT 的 `ubi reg` 匹配。
- **BMT/BBT** — 厂商 U-Boot 的坏块管理机制，与标准 UBI 坏块处理不兼容，是 UBI 化的主要障碍。

## 固件形态与能力

- **sysupgrade 镜像** — 已装 OpenWrt 后的升级镜像（日常更新形态）。
- **factory / installer 镜像** — 首次刷机形态。
- **NPU offload** — AN7581 内置 8 核 NPU 承担 Wi-Fi 数据面卸载（mt76 NPU 支持 + `airoha-en7581-mt7996-npu-firmware`）。
- **EHT320 回程 / 802.11s mesh** — 6GHz 320MHz 无线回程的 mesh 组网形态。
- **MLO** — 多链路操作（Multi-Link Operation），Wi-Fi 7 核心能力，由 hostapd EHT 选项与 luci-app-mlo 管理。
- **regdb** — 无线监管域数据库，决定信道与功率；6GHz 可用性取决于所选 regdb。
- **US regdb 补丁体系** — YYH2913 wireless-regdb patches：520 = UNII-1 23→29dBm + 6GHz LPI 12→29dBm（默认携带）；555 = 6GHz 12→30dBm + UNII-3 扩展至 5895MHz（功率激进档携带）。社区无 UNII-1=30dBm 补丁（30dBm 为 FCC 授权值，固件取整 29dBm）。

## 超频与功率

- **超频（OC）** — AN7581 CPU 超频。唯一社区实现：OpenW1700k 分支 `ubi2-oc`（commit 80096373b5）三文件补丁——DTS `cpu_opp_table` 15 档整体 +200MHz（500–1200 → 700–1400）、PM domain PLL 公式 `freq_mhz = 700 + state*50` 同步、默认 governor=performance。**前置依赖**：cpufreq/PM domain 修复（openwrt #22029）。实测上限 1.4GHz（静态电压 546–650mV 不可调，1.5GHz 无一成功）；个别机器内置 OC 启动即 kernel panic（体质差异，非软件可修）→ 落地为双 release（stock 默认 + oc 变体 1.3/1.4 两档）。

## 项目政策

- **修复而非降级** — 遇到问题（构建失败/驱动缺陷/启动异常）时定位根因并修复（自持补丁或推动上游），不通过移除能力/回退版本来规避。
- **修复台账（FIXES）** — "问题 → 根因 → 修复 commit → 上游状态"的追踪表，是"修复而非降级"政策的执行机制。
