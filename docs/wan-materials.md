# WAN 材料台账（AN7581 / NPU 固件 / 上游锚点）

**用途**：这是 #87 的登记册 —— 只登记**实际存在**的材料，给 URL 或本地路径、日期、大小、
SHA-256 或 commit pin、一个状态词，以及“它能证明什么、不能证明什么”。分析性调查过程留在
`.github/research/materials.md` §1–§8（那里是日志，不是台账）。

**状态词**：`已入库`（在本树里，可复现）／`仅链接`（只有外部地址，树里没有文件）／
`未公开`（按渠道找过，没有公开件，带日期）／`待索取`（有明确索取路径，尚未拿到）／
`缺失`（应当存在但本树没有）。

**证据等级**：**实测** = 2026-11-20 在 `ssh root@192.168.1.1`（`r38047-a86ce12e27`，
kernel `7.3`）上直接跑出来的输出；**代码** = 本树 file:line 或 `sha256sum`；其余标 **推断**。

## 1. 硬件与固件

| 资料名 | 类型 | URL 或本地路径 | 日期 | 大小 / sha256 或 pin | 状态 | 备注 |
|---|---|---|---|---|---|---|
| AN7581 NPU 固件（RV32 主核） | firmware | `package/firmware/linux-firmware/files/airoha/en7581_MT7996_npu_rv32.bin` | 2026-11-15 | 125,832 B；`7068a987bb95e89129a69de10d598f234a4400023eb23aacc8eb377e5f0fe0ea` | 已入库 | **代码**（`sha256sum` 复核）；**实测**设备副本与此字节一致（§2） |
| AN7581 NPU 固件（数据块） | firmware | `.../en7581_MT7996_npu_data.bin` | 2026-11-15 | 3,092 B；`6fd9506e399ebb309801ac2ecc74d3e10fa66731afc828c76fde8a67b2153f49` | 已入库 | 同上；空/极小，别当主固件 |
| AN7581 NPU 固件 CVE 判定 | 判定（工具） | `scripts/check-npu-firmware.sh` | 2026-11-20 | 见 §2.1 | 已入库 | 本树脚本；对当前 blob 判 `VULNERABLE-RANGE`（CVE-2026-89142，≤ `TLB7.8.0.0_v006`） |
| `airoha_npu.bin`（NPU 装载器） | firmware | —（预期 `package/firmware/**/airoha_npu*.bin`） | — | — | 缺失 | **代码**：`find package/firmware -name "airoha_npu*"` 无输出。上游 PR #22289 走的是本树这两个 `en7581_MT7996_npu_*`，名字不同 |
| linux-firmware 上游 v03 对 | 仅链接 | `git.kernel.org` linux-firmware `airoha/` | 2026-11-15 | 见 `.github/research/materials.md` §2 | 仅链接 | 未入库；与 v08 的差异未逐字节比对 |
| AN7581 / EN7581 datasheet 或 TRM | 文档 | — | — | — | 未公开 | 公开渠道 2026-11-15 已穷尽（FCC 只有元数据、厂商页无附件、社区无流传、采购/NDA 是剩余路径）；细节在 materials.md §1。**不要**用论坛转述当规格 |
| MT7996 厂商寄存器手册 | 文档 | MediaTek Online（需登录） | — | — | 未公开 | 未登录；`device-ref` 不能替代 |
| RTL8261BE / RTL8156B datasheet | 文档 | — | — | — | 未公开 | Realtek 站返回 301/404（materials.md §4）；代理商索取 |

## 2. NPU 固件在设备上的实测（本台账最重要的一行）

```sh
$ ssh root@192.168.1.1 'md5sum /lib/firmware/airoha/*.bin; ls -l /lib/firmware/airoha/;
                        sha256sum /lib/firmware/airoha/en7581_MT7996_npu_rv32.bin;
                        strings /lib/firmware/airoha/en7581_MT7996_npu_rv32.bin | grep -m1 TLB7'
550a8b3bf967a1e83bb1aaeca030ec7b  /lib/firmware/airoha/en7581_MT7996_npu_rv32.bin
210375f102c7c8a7c41f7a60c83d7652  /lib/firmware/airoha/en7581_MT7996_npu_data.bin
-rw-r--r--    1 root     root          3092 Nov 20 04:04 en7581_MT7996_npu_data.bin
-rw-r--r--    1 root     root        125832 Nov 20 04:04 en7581_MT7996_npu_rv32.bin
7068a987bb95e89129a69de10d598f234a4400023eb23aacc8eb377e5f0fe0ea  /lib/firmware/airoha/en7581_MT7996_npu_rv32.bin
TLB7.7.0.0_v08
```

- md5 `550a8b3bf967a1e83bb1aaeca030ec7b`、sha256 与 §1 同值、125,832 B → **实测**：设备上的
  blob 与本树入库文件字节一致（sha256 相同即一致；md5 只作旁证）。
- `strings /lib/firmware/airoha/en7581_MT7996_npu_rv32.bin | grep TLB7` → `TLB7.7.0.0_v08`
  （**实测**）。版本号来自固件字符串，不是厂商发布说明。
- 装载状态**实测**：`/sys/kernel/debug/npu/support_map` 首行
  `support_map: 28 bytes (224 bits)`，`/sys/kernel/debug/npu/counters` 首行
  `counters: 584 bytes, 112 slots`；`/sys/kernel/debug/ieee80211/phy0/mt76/npu_rro` 首行
  `status: npu=active hwrro=v3 hw_init=done` → 该固件在跑。
- 包清单**实测**：`apk list -I` 有 `airoha-en7581-mt7996-npu-firmware-20260916-r1`。

### 2.1 已知 CVE 判定（本台账必须记的一条）

本树自带只读检查脚本 `scripts/check-npu-firmware.sh`（头部注释说明它只读文件、不改固件），
它对我们的 blob 给出：

```sh
$ bash scripts/check-npu-firmware.sh --firmware-dir package/firmware/linux-firmware/files/airoha
Firmware: .../en7581_MT7996_npu_rv32.bin
  size: 125832 bytes
  md5: 550a8b3bf967a1e83bb1aaeca030ec7b
  known-hash: MATCH
  known-release: TLB7.7.0.0_v08
  verdict: VULNERABLE-RANGE
Firmware: .../en7581_MT7996_npu_data.bin
  version: none found
  verdict: UNKNOWN
Result: VULNERABLE-RANGE
```

- 判定区间来自脚本 `scripts/check-npu-firmware.sh:28` `CVE_MAX_VERSION=TLB7.8.0.0_v006`，
  即 **≤ TLB7.8.0.0_v006** 都算受影响；我们的 `TLB7.7.0.0_v08` 落在其中（**代码 + 实测**，
  脚本 `known-hash` 表在 `:82-86` 就登记了 md5 `550a8b3b…` 与版本串）。
- 数据块无版本串 → `UNKNOWN`，不是“安全”。
- 这意味着 §1 的“已入库”只描述**文件存在且可复现**，不描述**安全状态**。
  处置（换固件／加缓解／接受风险）需要厂商件或一个有决定权的判断，本台账不下结论；
  未做任何设备侧改动。

## 3. 驱动与用户态包

| 资料名 | 类型 | URL 或本地路径 | 日期 | 大小 / sha256 或 pin | 状态 | 备注 |
|---|---|---|---|---|---|---|
| mt76（含 NPU 补丁与 firmware） | 源码包 | https://github.com/OpenWRT-fanboy/mt76-firmware | 2026-10-08 | `639e128702780b398c1c36782b77899ce6bcb1fa`；mirror `9dfa305e700a7b4d83619a16517e36151a5d06e4b5a1a6d48e97ef3b48b0761e` | 已入库 | **代码** `package/kernel/mt76/Makefile:9-13`；非 MediaTek 官方发布 |
| mt76 debugfs `token_info` / `npu_rro` 来源 | patch | `package/kernel/mt76/patches/0016-*npu-rro-debugfs*`（按文件名匹配） | — | — | 已入库 | **实测**两文件挂在 per-phy 目录 `/sys/kernel/debug/ieee80211/phy0/mt76/` 下，不在 debugfs 根 |
| backports（mac80211） | SDK | https://github.com/openwrt/backports/releases/download/backports-v7.2 | 7.2 | `6ec76a4cb0988b5382b2fc5053610a56ada90b8ef6a5a4f2807cd433badb9454` | 已入库 | **代码** `package/kernel/mac80211/Makefile:13-21` |
| bridger | 包 | https://github.com/nbd168/bridger | 2026-03-23 | `de7e00a5a673fdda38d3326b624c45facc6245d2`；mirror `480047262ad886699f8abd8b25a8c292b190648d0098d207c2d1e260d0e97ab2` | 已入库 | **代码** `package/network/services/bridger/Makefile:10-15`。**更正**：旧台账写的 pin `befa61b1…` 在本树查不到（见 §6） |
| firewall4 bridge-flowtable 补丁 | patch | `package/network/config/firewall4/patches/001-add-bridge-flowtable-support.patch` | — | — | 已入库 | 本树原创；**实测**设备上跑的是打过该补丁的 fw4，`/usr/share/firewall4/templates/ruleset.uc:486-507` 有 bridge 表 |
| airoha_ppe 调试面（`ppe/bind`、`ppe/usage`、BND 行） | patch | `target/linux/airoha/patches-7.3/205-*dump-bridge-entries-and-table-occupancy.patch` | — | — | 已入库 | :30,:79,:90（**代码**）；**实测** `ppe/usage` 存在且 `entries 32768` |

## 4. 上游开源锚点

**实测**（2026-11-20，`gh api repos/openwrt/openwrt/pulls/<n>`，全部 `state=closed, merged=true`）：

| 编号 | 标题 | 合并时刻 (UTC) | 对本板的意义 |
|---|---|---|---|
| [#22289](https://github.com/openwrt/openwrt/pull/22289) | airoha: add support for AN7581+MT7996 NPU firmware | 2026-03-06T14:00:36Z | 本树 NPU 固件与包的来源 |
| [#22300](https://github.com/openwrt/openwrt/pull/22300) | airoha: an7581: disable NPU offload stats for eagle | 2026-03-06T14:01:02Z | eagle 上关闭 NPU offload 统计，解释统计面为何薄 |
| [#21978](https://github.com/openwrt/openwrt/pull/21978) | airoha: fix EN7581 PCIe initialization and add x2 link support | 2026-02-13T11:09:05Z | PCIe0 x2，即 mt7996 的链路前提 |
| [#22479](https://github.com/openwrt/openwrt/pull/22479) | airoha: Backport some missing airoha_eth upstream patches | 2026-03-20T12:21:35Z | `airoha_eth` 上游回填 |
| [#26513](https://github.com/openwrt/openwrt/pull/26513) | airoha: nvmem: fix SMC function ID for eFuse read | 2026-11-11T10:34:22Z | eFuse 读取；与 MAC/校准相关 |

| 资料名 | 类型 | URL 或本地路径 | 日期 | 大小 / sha256 或 pin | 状态 | 备注 |
|---|---|---|---|---|---|---|
| Bridge/flowtable 系列 `675-01..05` | patches | `target/linux/generic/pending-7.3/675-*` **和** `pending-6.18/675-*` | 2026-11-19 | — | 已入库 | **代码**：两套目录各 5 个文件、编号 01–05，无 06+。**更正**：旧台账只写 6.18。675-02 在 6.18 栈上留 hunk reject（#92/#160 的转述，本次未复核） |
| 9904 PPPoE decap 补丁（#81） | patch | `target/linux/airoha/patches-7.3/9904-*`（预期） | — | — | 缺失 | **代码**：`ls …/9904*` → `No such file or directory`；[#81](https://github.com/genshanxinli/xr1710g-openwrt/issues/81) 仍是 open（**实测** `gh api …/issues/81`：`state=open`，2026-11-14 建）。不要声称设备上有 `ppe/pppoe_decap` 旋钮 |
| airoha patches-7.3 目录规模 | 台账事实 | `target/linux/airoha/patches-7.3/` | 2026-11-20 | 113 个文件，其中 `9xx-` 系列 43 个 | 已入库 | **代码**；用“113”否定“只 675 那几条”的以偏概全 |

## 5. 台账规则

1. 新入册条目必须有 URL 或本地路径、日期、大小与 sha256（文件）、或 commit pin（仓库）；
   只有链接没有日期的不算登记项。
2. **推断与实测分开**。合入的上游 PR 只证明“补丁存在”，不证明本板跑它；树里有 blob 只证明
   “文件在”，不证明“固件起来了”——后者要 §2 那种运行态读数。
3. 私有文档与固件不入库；记链接、摘要与保管人。
4. 公开件找不到时，记**带日期的否定结果 + 找过的渠道**，不是“厂商没有”。
5. 引用上游时必须给编号与时刻；引用设备输出必须给命令与采样时刻（设备是共享机，vif 与
   flowtable 会随别人 `wifi reload` 变化）。

## 6. 对旧台账的更正（`materials.md` §9 的四处偏差）

| 旧写法 | 实际（本次核对） |
|---|---|
| bridger pin `befa61b1b646c53774a2285df1609776fa2f3f7f` | 本树是 `de7e00a5a673fdda38d3326b624c45facc6245d2`（`bridger/Makefile:14`）；`befa61b1` 在树里 `grep` 无命中，**未能验证**其来源 |
| 675 系列“只有 `pending-6.18`” | `pending-6.18/` 与 `pending-7.3/` 各 5 个，01–05 |
| `token_info` 在 `/sys/kernel/debug/token_info`（#86 原文） | 实际在 `/sys/kernel/debug/ieee80211/phy0/mt76/token_info`；根路径不存在，按根路径读会误判“没编进去” |
| NPU 固件“在树里”即完成 | 还需运行态：`support_map`/`counters`/`npu_rro` 的 `status`、`TLB7.7.0.0_v08`、设备 md5（§2 已补） |

## 7. 仍未解决

- AN7581/EN7581 规格书、MT7996 寄存器手册、RTL8261BE 手册均为 `未公开`：公开渠道已穷尽，
  下一步只有采购/NDA 或内部渠道；**无法用公开件验证** PPE 的端口编码细节（见
  `docs/wan-wifi-path.md` §3 第 2 条）。
- `airoha_npu.bin` 缺失，而 #87 原文假定它存在：现方案用 `en7581_MT7996_npu_rv32.bin`，
  不需要再找这个文件名；若上游后续真的引入 `airoha_npu.bin`，再补一行。
- 固件版本差异（树内 v08 vs upstream v03）未逐字节比对：需要把上游两份下载到本机再算 sha256。
