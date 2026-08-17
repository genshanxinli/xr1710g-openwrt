# 修复台账（FIXES）——"修复而不是降级"的执行记录

> 每遇问题：记一条。列：问题 → 根因 → 修复（本层补丁/上游） → 上游状态。上游合入后删除本层补丁并标「已上游」。
> 状态：`carried`（本层携带） / `upstream-open`（上游有 PR 待合） / `merged`（上游已合，删除补丁） / `n/a`（不打算上游）。

| # | 项目 | 问题/背景 | 根因 | 本层载体 | 上游状态 | 备注 |
|---|---|---|---|---|---|---|
| F01 | XR1710G 板级支持 | master 无 xr1710g 文件 | #22397 未合入 | `patches/root/9000-...-board-support.patch`（PR diff 快照） | upstream-open（#22397，2026-08-14 最后活动） | 合入即删；PR diff 会漂移，重取源后更新 |
| F02 | 6GHz 不可用 | US 默认 regdb 6GHz NO-IR 限制 | regdb 未含设备功率 | `regdb-0510/0520`（+0500 world 5GHz） | n/a（功率补丁不打算上游） | 530 实验室 SP 默认停用（#DISABLED） |
| F03 | NPU 内存/卸载 | 只在未装 Wi-Fi 板保留 NPU 内存 | 上游 #24593 | 无需携带（master 已合 2026-08-11） | merged | 跟踪：若回移分支需重拾 |
| F04 | 10G PHY 启动/link | 非 Realtek SoC 上 rtl8261 劣化、boot 失败 | #21777/#22564/#23078/#23383 系列 | 依赖：#22397 板级（含 phylink 配置）；kmod-phy-realtek + rtl826x-firmware | 部分 merged；PHY LED #24034 仍 open | 见 F06 |
| F05 | 风扇温控 | 传感器版本差异（NCT7802/NCT7511Y）；上游 airoha_fan 只覆盖 nct7802 | hwmon 动态探测缺失 | `files/etc/init.d/fan`（动态探测+曲线，覆盖 #22391 修复） | n/a（版本差异不适合上游单一脚本） | 社区实测 NCT7802 为主 |
| F06 | 10G/1G LED 行为 | XR1710G LED 由交换芯片驱动、与 W1700K 相反 | 板级差异 | 待取源：#24034（RTL826x LED）、#24619（mt7530 LED） | upstream-open | 见 specs；同步后解锁 MANIFEST |
| F07 | cpufreq / PM domain | OC 前置依赖；驱动修复 6.18 下仍不稳 | #22029 未合 | 待取源 `openwrt-22029-...`（fetch-sources.sh） | upstream-open | **OC 前必须先合**（F08 前置） |
| F08 | CPU 超频 | stock 500–1200MHz；部分机器内置 OC 启动 panic（体质差异） | OPP/PLL/governor 需整体 +200MHz（上限 1.4GHz，电压不可调） | `scripts/prepare-oc.sh`（1.3/1.4 两档，不做 1.35/1.5） | n/a（硬件体质差异 + 超频非上游议题） | 双 release：stock 默认 + oc 变体 |
| F09 | U-Boot pstore | 崩溃日志无处持久化 | #22473 未合 | 待取源 | upstream-open | 可选增强 |
| F10 | DSA 重构 | switch 端口架构迁移（实验档） | #22532 未合 | specs（不默认应用） | upstream-open | 毕业条件见 patches/README |
| F11 | L2 桥接卸载 | nft flow offload L2（实验档） | #22533 未合 | specs | upstream-open | 同上 |
| F12 | NPU/MLO/诊断应用 | 应用包无独立 feed | 散落在各家 fork 内 | feeds.custom.conf TODO + ROADMAP | n/a | luci-app-mlo（锁 911912b1）、fancontrol（锁 2c6cc7a3）已供给 |

## 未确认/待实机核实清单
- 接口名映射（10G/1G 与 eth* 对应）→ 首次实机 `ip -br link` 核对（FIXME 于 files/etc/config/network）
- U-Boot flash-slot.bin 的 SHA256 全文 → 以 YYH2913/http-uboot release 页为准（升级时校验）
- 6.18 下 PM domain PLL 公式的树内位置（prepare-oc.sh 找不到即报错并指导定位）