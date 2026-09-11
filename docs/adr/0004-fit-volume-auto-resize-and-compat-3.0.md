# ADR 0004 — 固件容量：靠 HTTP U-Boot 恢复页自动扩容 `fit` 卷，并把 `DEVICE_COMPAT_VERSION` 升到 3.0

**Status**: accepted（2026-09-11 评审确定；plan/06 第 2 轮 Q7 用户选「扩容 fit 卷」、第 3 轮 Q14 用户指认「我到时候用 uboot-http 进行刷机」、Q12 用户选「大扩：sing-box + netbird 都预装」）
**Context**:
本机可写空间与固件空间是**两个不同的池**，容易混淆：

| 层级 | 容量 | 说明 |
|---|---|---|
| SPI-NAND 裸片 | 512 MiB | 器件标称 |
| `mtd2 ubi` | 439 MiB | `0x700000 + 0x1b700000` |
| `reserved_bmt` | 66 MiB | 坏块表保留，只读 |
| `rootfs_data`（UBIFS） | **355.4 MiB**（空闲 350.6 MiB） | **唯一可写卷 = overlay** |
| `fit`（只读固件镜像卷） | **24.94 MiB**，镜像 24.91 MiB ⇒ **余量 ≈32 KiB** | **固件本身的空间** |
| UBI 空闲 PEB | **0** | 不能在线扩容 |

⇒ 「运行期安装」不缺空间（overlay 350 MiB 空闲）；受限的只有**只读固件镜像卷 `fit`**。要把 sing-box / netbird / kmod 预装进固件，就必须先解决这 32 KiB。

**Decision**:
**不新增 installer、不改 DTS、不硬编码容量常数**。扩容机制 = **HTTP U-Boot 恢复页在上传固件时自动重建并缩放 UBI 卷**，并把 `DEVICE_COMPAT_VERSION` 由 `2.0` 升到 `3.0`。

上游源码实证（`YYH2913/http-uboot` → `net/lwip/httpd_recovery.c`）：

```c
static const struct recovery_ubi_layout recovery_ubi_layouts[] = {
    { "2.0", "ubi" }, { "1.5", "ubi1.5" }, { "1.0", "ubi1.0" },
};

// 只保留这三个卷；XR1710G 的 factory 在白名单里
static bool recovery_preserve_ubi_volume(const char *name) {
    if (!strcmp(name, "ubootenv") || !strcmp(name, "ubootenv2")) return true;
    if (of_machine_is_compatible("gemtek,xr1710g-ubi")) return !strcmp(name, "factory");
    ...
}

recovery_cleanup_ubi_firmware(&target, status_leds, image_size);   // 先移除白名单外所有卷（含旧 fit 与 rootfs_data）释放 PEB
if (!target.cur_size)                    recovery_create_ubi_target(&target, image_size);
else if (image_size > target.cur_size)   recovery_resize_ubi_target(&target, image_size);
   // → ubi_resize_volume(desc, DIV_ROUND_UP(new_size, vol->usable_leb_size))
recovery_ensure_rootfs_data(&target);    // size=0 ⇒ 吃掉剩余全部 PEB
```

**Why**:
- 上传更大的 `*-sysupgrade.itb` 即自动扩容 `fit`、自动缩 `rootfs_data` —— 零新增机制，零 DTS 改动，零容量硬编码；
- 镜像实际尺寸由构建产物的安装体积决定，因此**不需要也不应该**写死「+88 MiB」这类常数；CI 只做「比上一版大 ⇒ release notes 标注需重刷」的提醒；
- **必须升 compat 的原因**：上述 resize 只在恢复页路径生效。在旧布局（`fit` 206 LEB）的设备上跑 in-OS `sysupgrade` 一个装不下的大镜像，会走到 `ubiupdatevol` 失败。升 compat 让 `sysupgrade` **在动手前干净拒绝**，而不是写到一半失败。

**Considered Options**:
- **`append-ubi` / `ubinize` 硬编码卷尺寸 + 新 installer**：改 DTS 与镜像打包规则，引入单一维护点，且与恢复页的自动 resize 形成双源真相。否决。
- **运行期装到 overlay（不预装）**：可行（350 MiB 空闲），但用户要的是「预装进固件」（Q12）；且运行期装 kmod 被 apk 依赖解析挡住——官方 kmods 目录是 `6.18.44-1-6297b246…`，本机 hash 不同，`apk` 直接 ERROR。两条路并行：预装（本 ADR）+ 自建 kmods feed（ADR-0005 以外的供给链决策，见 `plan/00` §4.4）。
- **保持 compat 2.0 + 只在文档里要求「先扩卷」**：把风险留给用户操作，且 in-OS `sysupgrade` 会静默走到失败。否决。

**实测印证（2026-09-11 ci-118）**：本分支首个成功构建产出
`openwrt-stock-airoha-an7581-gemtek_xr1710g-ubi-squashfs-sysupgrade.itb` = **48 293 011 B = 46.06 MiB**，
**远超旧 `fit` 卷 24.94 MiB** ⇒ 「必须经恢复页重刷（会清 overlay）」不是理论推演，而是本版的确凿后果；
`DEVICE_COMPAT_VERSION := 3.0` 的作用也随之落地：旧布局设备上的 in-OS `sysupgrade` 会被**干净拒绝**。

**Consequences**:
- ✅ 扩容路径与刷机路径**同一条**（用户已选 HTTP U-Boot），无新增流程；
- ⚠️ **恢复页刷写会清空 `rootfs_data`（overlay / 全部配置）** —— 这是 `recovery_preserve_ubi_volume()` 白名单的必然结果（白名单只有 `ubootenv`/`ubootenv2`/`factory`），不是 bug。`FLASHING.md`、release notes、T0 都必须显著警告「刷前备份 `/etc/config`」；
- ⚠️ **布局选择器必须选 UBI 2.0**（`part="ubi"`，对应 `mtd2` `0x1b700000`）。选 1.5/1.0 会落到更小的分区 → `not enough PEBs`；
- ⚠️ **后续镜像再变大时 in-OS `sysupgrade` 会失败**：`fit` 卷已被上次刷机定死；失败即走恢复页重刷（会清 overlay）⇒ 由 CI 尺寸自检提前预警；
- ⚠️ 已知代价（用户已接受）：每次升级固件多写 ≈镜像大小的数据到 2.26 MB/s 的 NAND；`rootfs_data` 被相应压缩；netbird 二进制随固件版本回退。
