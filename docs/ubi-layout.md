# UBI / flash layout: 4-partition chainloader vs the 2-partition reference (G-layout)

**状态**：决策文档，回答 issue #8（“4-partition chainloader 布局 vs 参考的 2-partition 工厂布局”）。
本文**不改代码、不改分区表**；结论是“保留 4-partition”，并给出为什么 2-partition 在本板
不可能存在。证据标签同全仓约定：**实测** / **代码** / **推断** / **未验证**。

**关联**：#8（本文）、#7（1.x→2.0 软砖闸门，见 `docs/wan-recovery-gate.md` §4.1 与 README）、
#12（恢复镜像）。

## 0. 结论（先行）

1. **保留 4-partition 布局**（`vendor` + `chainloader` + `ubi` + `reserved_bmt`）。它是
   本板的**引导链决定**，不是可以随手换的软件选择。
2. issue #8 里说的“参考 2-partition 布局”指的是 `bl2@0` + `ubi@0x20000`；那套布局在本树里
   只存在于 **eMMC/eVB 参考板**（`an7581-evb-multievb.dts:190-199`、`an7583-evb-multievb.dts:110`
   一带），**没有任何 Gemtek 零售板的 profile 用它**。
3. `gemtek_ubi_layout_check`（期望“正好 2 个 mtd 分区”）**不在本仓库**
   （`grep -rn gemtek_ubi_layout_check .` 无输出）；它在参考/fanboy 树里。把它移植进来
   只会**拒绝**这块板的合法升级，所以没有移植是正确的。
4. 本树的 XR1710G 从来没产出过 1.x 布局：`git log -S'reserved_bmt'` 首个命中
   `f0105e318a`（2026-10-15，`airoha: add Gemtek XR1710G (UBI) support`）里就已经是
   4-partition + `DEVICE_COMPAT_VERSION := 2.0`。所以“1.x 布局”只属于**厂商固件单元**，
   不属于本树的任何构建。

## 1. 本板实际布局（实测）

`ssh root@192.168.1.1`，`SNAPSHOT r38047-a86ce12e27`，板名 `gemtek,xr1710g-ubi`：

```
dev:    size   erasesize  name
mtd0: 00600000 00020000 "vendor"
mtd1: 00100000 00020000 "chainloader"
mtd2: 1b700000 00020000 "ubi"
mtd3: 04200000 00020000 "reserved_bmt"
```

| mtd | 段 | 偏移 | 大小 | DTS | 归宿 |
|---|---|---|---|---|---|
| mtd0 | `vendor` | `0x00000000` | 6 MiB | `dts:139-142`（`read-only` 在 `:142`） | 厂商 bootloader（AXON） |
| mtd1 | `chainloader` | `0x00600000` | 1 MiB | `dts:145-148`（`read-only` 在 `:148`） | OpenWrt 的 U-Boot FIT |
| mtd2 | `ubi` | `0x00700000` | 439 MiB | `dts:151-154`（`compatible = "linux,ubi"`） | `fit`/`ubootenv`/`ubootenv2`/`factory`/`rootfs_data`/`provisioning` |
| mtd3 | `reserved_bmt` | `0x1be00000` | 66 MiB | `dts:182-185`（`read-only` 在 `:185`） | 厂商 bootloader 的 BMT/BBT 账本 |

整片 512 MiB（`0x20000000`），erase size 全 `0x20000`。UBI：LEB 126 976 B、3512 LEB
（445 939 712 B ≈ 425.2 MiB）、`Count of bad physical eraseblocks: 0`、`reserved physical
eraseblocks: 80`；卷 `fit`(118 LEB) / `ubootenv`(9) / `ubootenv2`(9) / `factory`(9, static) /
`rootfs_data`(3281) / `provisioning`(2)。`uci -q get system.@system[0].compat_version` = `2.0`。

代码侧同一条链：`target/linux/airoha/image/an7581.mk:83`（`DEVICE_COMPAT_VERSION := 2.0`）、
`:84-86`（compat 消息，点名 “BMT/BBT partition at the end of flash”）、`:90-91`（
`UBOOTENV_IN_UBI := 1`、`KERNEL_IN_UBI := 1`，这就是为什么 `ubootenv` 与 `ubootenv2`
两个卷都要在）、`:95`（`KERNEL_INITRAMFS_SUFFIX := -recovery.itb`）、`:98`（
`ARTIFACTS := chainload-uboot.itb`）。设备侧 compat 值由
`target/linux/airoha/an7581/base-files/etc/board.d/05_compat-version:11-14` 写入
（`gemtek,w1700k-ubi` 与 `gemtek,xr1710g-ubi` → `ucidef_set_compat_version "2.0"`）。

## 2. 为什么必须有 `chainloader`（代码）

`package/boot/uboot-airoha/patches/999-airoha-add-gemtek-xr1710g.patch:5-9` 的提交说明就是
这块板的布局理由，原文：

```
Similar to the Gemtek W1700K, issues regarding BMT/BBT support
and the risk of unwanted remapping necessitate the use of a
chainloader to boot the OS from a UBI volume; separating all
writes between the BMT/BBT-aware vendor bootloader and Linux,
which manages any remapping needed in the UBI layer.
```

拆开说：

- 厂商 bootloader（AXON 1.6）是 **BMT/BBT-aware** 的：它按 NAND 的坏块表做重映射，
  所以它写过的区（`vendor` 与 `reserved_bmt` 之间的账本）不能被 Linux 侧的 UBI 重映射
  混进来。把 OS 从 UBI 卷启动、把两边写路径分开，是唯一不互相踩的办法。
- 因此 OS 的 bootloader 必须**住在一个独立的、只读的 `chainloader` 分区**里，由厂商
  bootloader 从固定偏移 `0x00600000` 链式加载（`READONLY` 在 DTS，见上）。
- 两套 U-Boot 环境卷（`ubootenv` / `ubootenv2`）也在 UBI 里（`an7581.mk:90-91`），
  这样 OpenWrt 侧改环境不会碰到厂商区。

## 3. 参考的 2-partition 布局是什么、为什么用不到这里

参考布局（issue #8 原文的 `bl2@0` + `ubi@0x20000`）在本树里的唯一实例是 **eVB/eMMC 参考板**：

```
$ sed -n '190,199p' target/linux/airoha/dts/an7581-evb-multievb.dts
		bl2@0 {
			label = "bl2";
			reg = <0x0 0x20000>;
		};

		ubi@20000 {
			label = "ubi";
			reg = <0x20000 0x0>;
		};
```

（`reg = <0x20000 0x0>` 是“从 0x20000 到片尾”的写法；`an7583-evb-multievb.dts:110` 同款。）

那套布局的前提是 **BL2/FIP 由本树自己写进 mtd0**：`target/linux/airoha/image/an7581.mk:1-5`
的 `Build/an7581-emmc-bl2-bl31-uboot` 先铺 `0x800` 字节零、把 `an7581_$1-bl2.fip` 接上、
再把 `bl31-u-boot.fip` `dd` 到 `seek=0x20000`（正好就是参考布局里 `ubi@0x20000` 的起点）；
这个 image 的 `ARTIFACTS` 是 `preloader.bin` + `bl31-uboot.fip`（`:65-67`），设备是
`an7581-evb-multievb`（eMMC）。也就是“板上没有厂商 bootloader，OpenWrt 自己就是第一级”。
XR1710G 不是这个前提：它的 `vendor` 分区里是厂商签名过的 AXON bootloader，本树**没有任何**
能把东西写进 `vendor` 的产物（`an7581.mk:98` 的 artifacts 只有 `chainload-uboot.itb`）。

顺带一个对照：同门 Gemtek W1700K 在本树里是 **3 个**分区（`vendor`/`chainloader`/`ubi`），
没有 `reserved_bmt`（`target/linux/airoha/dts/an7581-w1700k-ubi.dts` 的 partitions 节点）；
XR1710G 多出来的 66 MiB 就是它自己的 BMT/BBT 尾巴。也就是说，“同一家、同一 SoC、
不同板子的分区数都不一样”，本板的分区数由**该板的 bootloader 与 NAND 账本位置**决定，
不是由参考树的选择决定。

**一行结论**：真要做 2-partition 工厂镜像，等于要求厂商把 AXON/BL2 写进 `bl2@0`、把
BMT/BBT 账本从片尾搬到厂商自己管的地方——那需要厂商的 BL2 签名与 BMT 格式，
只能由**厂商**给出，本树做不到；在本树上“采用 2-partition”的实际后果是把 `vendor`
与 `reserved_bmt` 从分区表里删掉，随后厂商 bootloader 找不到自己的区，设备直接不启动。

## 4. 如果真移植 `gemtek_ubi_layout_check` 会怎样

那个 helper 期待“正好 2 个 mtd 分区”。本板是 4 个（实测），所以：

- `platform_check_image()` 会**拒绝**每一次合法升级（`base-files/lib/upgrade/platform.sh` 现在
  走的是 `fit_check_image` + FDT 描述比对，见该文件 `gemtek,xr1710g-ubi` 分支的注释）；
- 而拒绝的代价是“这块板的用户永远升不了级”。所以没移植它是**正确**的，不是漏做。

## 5. 只读识别布局（两条闸门共用的前置检查）

```sh
ssh root@192.168.1.1 'cat /proc/mtd'
# 期望正好 4 段：vendor 0x600000 / chainloader 0x600000+0x100000 /
#                ubi 0x700000+0x1b700000 / reserved_bmt 0x1be00000+0x4200000

ssh root@192.168.1.1 'ubinfo -a | grep -E "^Volume ID|^Name|bad physical|reserved physical"'
# 期望有 ubootenv 与 ubootenv2 两个卷（UBOOTENV_IN_UBI 的直接后果）

ssh root@192.168.1.1 'uci -q get system.@system[0].compat_version; cat /tmp/sysinfo/board_name'
# 期望 2.0 与 gemtek,xr1710g-ubi
```

- 缺 `chainloader` 或缺 `reserved_bmt`、或 UBI 里只有一个 env 卷 → **不是 2.0 布局**，
  不要刷本树的镜像（见 README 的软砖闸门与 `docs/wan-recovery-gate.md`）。
- 这些命令全是只读；`fw_printenv` 也可读（本机报 `Bad CRC, using default environment`，
  两个 env 卷前 256 B 全 `0xff`，见 `docs/wan-recovery-gate.md` §3）。

## 6. 历史核对（回答“本树是否产出过 1.x”）

```sh
git log -S'reserved_bmt' --oneline | head
#   f0105e318a airoha: add Gemtek XR1710G (UBI) support   ← 2026-10-15，首个命中
git show f0105e318a:target/linux/airoha/image/an7581.mk | grep -n COMPAT
#   107:  DEVICE_COMPAT_VERSION := 2.0
git log --all -S'DEVICE_COMPAT_VERSION := 1' -- target/linux/airoha/image/an7581.mk
#   （无输出）
grep -rn 'DEVICE_COMPAT_VERSION' target/linux/airoha/
#   只有 target/linux/airoha/image/an7581.mk:83 → 2.0
```

所以：本树**从未**产出 1.x 布局的 airoha 镜像；1.x 是厂商固件的状态，
本树的 `-ubi-*` 产物一律是 2.0（`docs/wan-recovery-gate.md` §0.1 的实测 compat 也是 2.0）。

## 7. 未验证 / 留给别人的

| 项 | 状态 |
|---|---|
| 在真·1.x 厂商单元上验证“闸门确实挡住” | **未验证**（手上没有 1.x 单元；本机是 2.0） |
| 厂商 AXON 的 BMT/BBT 格式与 BL2 签名 | **无资料**（不在本树，只能由厂商文档补） |
| 是否要做“compat 不匹配不可 `-F`”的代码改动 | **待 Lead 决定**（见 #7 评论；`validate_firmware_image` 对 compat 走 `invalid` 而非 `broken`，所以 `-F` 能过） |
