# XR1710G 自用 OpenWrt 固件仓库

Airoha AN7581GT + MT7996（BE19000，2×10G + 2×1G）路由器 Gemtek **XR1710G** 的自用固件仓库。

**定位**：以 openwrt master（kernel 6.18）为基座，自维护补丁层携带全部"最前沿"内容（NPU offload、HW-GRO/LRO、
in-band phylink、PCIe x2、MLO/EHT320、US regdb 功率体系、CPU 超频）。**遇到问题修复而不是降级**——冲突、
失效、失败都按根因修复，不通过删能力/回退规避（政策见 `CONTEXT.md` 与 `docs/FIXES.md`）。

## 关键决策（详见 docs/adr/）

| 决策 | 内容 |
|---|---|
| 基线 | openwrt master fork（6.18）+ 自维护补丁层（ADR-0001） |
| 刷机 | 固化 YYH2913 HTTP U-Boot，官方 chainloader 备用（ADR-0002） |
| 版本线 | 滚动 master + known-good 冻结（`docs/ACCEPTANCE.md` 全项通过才打 tag） |
| 交付 | 双 release：**stock**（默认 known-good）+ **oc 变体**（1.4G 能力 + 默认限频 1300MHz，可解锁；oc-1.3 保守档可选） |
| 预装 | 见 `config/seed-config.diff`（mlo/fancontrol/npu 等）；科学上网/Docker 暂缓（ROADMAP P3） |

## 目录结构

```
patches/            补丁层（root/packages/specs 正式桶 + vendor/fanboy 原料桶 + MANIFEST/ORDER）
scripts/            apply-patches.sh / prepare-oc.sh / build.sh / fetch-sources.sh / sync-upstream.sh
config/             feeds.custom.conf（外部 feed 锁 commit）+ seed-config.diff（预装包）
files/              根文件系统 overlay（network/wireless/system/风扇守护/OC 限频）
docs/               FIXES 台账 / ACCEPTANCE 验收 / ROADMAP / FLASHING 刷机 / adr/
.github/workflows/  build.yml（手动构建 matrix）+ sync-upstream.yml（每 2h 上游同步+补丁校验）
对比报告-骨架目标-vs-OpenW1700k-ubi2-oc.md   与 fanboy 生态的详细对比
```

## 快速开始

### 0) 准备
```bash
# 本仓库就是叠加层；需要一个 openwrt 源码树（fork 或克隆）
git clone https://github.com/openwrt/openwrt.git openwrt
# （推荐）把本仓库内容 merge/拷贝到该 fork 的根目录，随 fork 同步上游 main
```

### 1) 构建
```bash
./scripts/fetch-sources.sh          # 拉取开放 PR 补丁（依赖网络；已内置 regdb/mt76/#22397/OC）
./scripts/build.sh stock            # 默认档（或 oc-1.3 / oc-1.4）
```
产物：`bin/targets/airoha/an7581/*-sysupgrade.itb`（+ initramfs）。

> 首次构建前 `./scripts/feeds update -a` 可提前做。CI：GitHub Actions 手动 workflow_dispatch；上游同步与补丁校验由 sync-upstream.yml 每 2h 自动跑（决策：同步越勤冲突越少）。

### 2) 刷机
见 **`docs/FLASHING.md`**——主路径 HTTP U-Boot（192.168.255.1 恢复页），含锁版 SHA256 校验与严禁事项。

### 3) 验收与冻结
按 **`docs/ACCEPTANCE.md`** 全项实机验收，通过后在 FIXES/README 记录 commit 并打 known-good tag。

## 当前补丁层状态（2026-08-17）

| 项 | 状态 |
|---|---|
| #22397 XR1710G 板级支持 | 携带（对 master 重建三件套 `patches/root/9000-9002`，含 dts/uboot/envtools/02_network/mk；合入即删） |
| US regdb 功率（500/510/520） | 内置；555（UNII-4/6GHz 30dBm）= OC 档；530 实验室 SP 停用 |
| mt76 txpower（0006/0007） | 内置（YYH2913 家族；fanboy 0010/0011 备选对比） |
| cpufreq / PM domain（#22029） | 已自持（`vendor/fanboy/03`，含 direct-PLL fallback，OC 前置） |
| CPU 超频 | `scripts/prepare-oc.sh`（1.3/1.4 两档）+ OC 变体默认限频 1300（`files/etc/init.d/oc-limit`） |
| NPU（#24593） | master 已合，无需携带 |
| pstore / ramoops（#22473） | kernel 侧已自持（`vendor/fanboy/10`）；uboot 侧待上游 |
| 风扇温控 | `files/etc/init.d/fan` 动态探测（NCT7802/NCT7511Y） |
| 实验档（#22532/#22533/eip93 等） | 原料桶已入库（vendor/fanboy 02/04-09/17/18），默认不编 |
| npu/flowsense/mlo/fancontrol/filemanager 应用 | 已由 `vendor/fanboy/19` 应用包随树内置；recovery 待供给（ROADMAP P1） |

## 风险声明（自用范围）

- 6GHz/功率补丁（US regdb 520）**无 AFC/合规背书**，自用责任自负；
- 超频存在**个体体质差异**（部分机器启动 panic）——默认档 stock 无此风险；OC 档按 FIXES F08 使用；
- 第三方 U-Boot 刷入后厂商恢复通道失效——锁版 + 校验，救砖通道见 FLASHING；
- 接口名占位（network 配置）需首次实机核对（ROADMAP P0）。