# 发布镜像特性门禁：974（BQL）与 968（napi_complete_done）

## 一句话

**补丁存在 ≠ 镜像包含。** `target/linux/airoha/patches-7.3/` 里躺着 968、974，
不代表发布出去的 `.itb` 的内核真的带着它们；本仓库用
`scripts/check-release-image-features.py` 把“源码、内核构建、镜像、运行镜像”
四层分开查，任何一层对不上就非零退出，并在日志里写清要重建还是重刷。

这个检查是**离线、只读**的：不刷机、不重启、不下载、不改镜像默认，也不写
`build_dir`。

## 为什么需要它

2026-11 的 XR1710G 镜像上出现过三种“补丁在树里、镜像里没有”的情况：

1. **构建分支不是带补丁的分支。** 补丁在开发分支的 `patches-7.3` 里，发布
   CI 却从另一个分支 clone、编译。源码里没有，镜像当然没有。
2. **补丁在树里，但内核没重编。** 驱动 `.o`/`vmlinux`/`Image` 还是旧的；镜像
   步骤只是重新打包 rootfs，于是出现“新 rootfs + 旧内核”。
3. **内核重编了，镜像没重打。** `bin/targets/.../*.itb` 里嵌的还是旧
   `Image`；`build_dir` 看起来是新的，刷进去的内核却没有对应改动。

所以门禁不能只 `grep patches-7.3/974-*.patch`；必须查**构建实际用的内核源码**、
**编出来的符号**，以及**镜像里嵌的那份内核**。

## 判据

### 974：BQL 每轮 NAPI 只报一次 TX 完成

- 源码/补丁：`airoha_qdma_tx_bql_add()`、`airoha_qdma_tx_bql_flush()` 存在，
  `netdev_tx_completed_queue()` 在驱动里只保留 **1 个调用点**（一轮 NAPI 一次），
  `airoha_gdm_dev` 里有 `bql[]`/`bql_dirty` 累加状态。
- 构建：`CONFIG_BQL=y`；`airoha_eth.o`、`vmlinux` 的符号表里有
  `airoha_qdma_tx_bql_add` 和 `airoha_qdma_tx_bql_flush`。
- 运行（在跑起来的镜像上，持续 TX 负载下）：

  ```sh
  # <conduit> 不是物理口名：lan3/lan4 这类 DSA 用户口的出向走 cpu，采 cpu（见“采集 inflight”）
  cat /sys/class/net/<conduit>/queues/tx-*/byte_queue_limits/inflight
  ```

  **判据：窗口内最大 `inflight` ≥ 65536 字节（64 KiB）。** 但 `inflight` 是**方向相关**的：
  本机 1G 路径两次采集，正向峰值只有 1680 B（队列没堆起来，BQL 本来就把 limit 收小了），
  反向（`iperf3 -R`，894 Mbit/s）峰值 192584 B（188 KiB）；门禁 PR 里还有一次 116038 B
  （≈77 帧）的旧记录，方向没写。所以采集必须写明**方向与口**，不要在“没有堆积的方向”
  上判失败——那条 64 KiB 判的是“堆起来时能不能堆够”，不是“任何方向都必须堆到 64 KiB”。
  空闲时的残值不算证据——`limit` 只在完成事件里收缩，必须在打流时采。
- `ethtool -S`：airoha 驱动没有 BQL 计数（`ethtool -S` 只报
  `rx_fc_drops`/`tx_dropped` 等），BQL 的权威接口是上面的 sysfs。脚本会读取
  `ethtool -S` 采集并在有 BQL 字样计数时提示，但**不以它作为硬判据**。

### 968：`napi_complete_done(napi, done)`

- 源码/补丁：`airoha_eth.c` 的 RX/TX 两个 poll 都是
  `napi_complete_done(napi, done)`（2 处），没有旧的
  `napi_complete(napi)`。
- 构建：该源码被编进当前内核（`.o` 不早于 `.c/.h`，`vmlinux` 不早于 `.o`），
  且 `vmlinux` 与 `$(KDIR)/Image` 的构建串一致、FIT 载荷 sha256 匹配；**不看**
  这两者的 mtime 先后（见下一节）。
- 运行：968 是“把真实 work_done 传给 NAPI core”，没有独立计数器；`ethtool -S`
  也看不到。它由“源码 + 同一份构建的符号/镜像”证明，运行时用
  `napi_defer_hard_irqs` 的行为做旁证（可选）。

### 构建/镜像一致性

判据分两类，**时间戳只在“源码 → 对象 → vmlinux”这一段有意义**：

| 判断的问题 | 判据 |
|---|---|
| 对象编自当前源码 | `airoha_eth.o` 不早于 `airoha_eth.c/.h` |
| vmlinux 含当前对象 | `vmlinux` 不早于 `airoha_eth.o` |
| **Image 与 vmlinux 同源** | 两者的 `Linux version ...` 构建串**逐字节相同** |
| **镜像嵌的是这份 Image** | `.itb` 的 FIT `kernel-1` 解压后 sha256 **等于** `$(KDIR)/Image` |
| **模块与内核同一套配置** | `profiles.json` 顶层 `linux_kernel.vermagic` 与 vmlinux 里的 vermagic 一致（脚本暂未自动比对，需人工核一条） |
| **Image 与 vmlinux 的 mtime 顺序** | **不是判据**（下面解释） |

**`Image` 比 `vmlinux` 旧是健康的，不是过期。** `include/kernel-build.mk:31-34`：

```make
define Kernel/CompileImage
	$(call Kernel/CompileImage/Default)      # 写 $(KDIR)/Image
	$(call Kernel/CompileImage/Initramfs)    # 之后才重新链接 linux-7.3/vmlinux
endef
```

所以每一个健康构建都会先产出 `Image`、再重链 `vmlinux`。实测（本仓
`build_dir/target-aarch64_cortex-a53_musl/linux-airoha_an7581`，2026-11-20，
该树后来被别的构建 `clean` 掉，所以引用时要重测）：

```
Image             14252040 B  2026-11-20 12:06:14.913
Image-initramfs   35354632 B  2026-11-20 12:06:46.174
linux-7.3/vmlinux 98724784 B  2026-11-20 12:06:46.102   ← 比 Image 晚 31 秒

$ strings -a Image              | grep -m1 'Linux version 7.3'
Linux version 7.3 (...) #0 SMP PREEMPT Fri Nov 20 04:04:01 2026
$ strings -a linux-7.3/vmlinux  | grep -m1 'Linux version 7.3'
Linux version 7.3 (...) #0 SMP PREEMPT Fri Nov 20 04:04:01 2026   ← 同一构建
```

`scripts/check-release-image-features.py` 因此把这种顺序记成 note
（`:524-534`，“the initramfs pass re-links vmlinux after the Image is written”），
只在构建串**不一致**时 fail（`:538-546`）。**不要把那条 note 改回 failure**：
改回去等于在每一个健康构建上报“镜像嵌了过期内核”（PR #218 修的就是这个假阳性）。

FIT 载荷 hash 与 `profiles.json` 的实测（同一次构建，用仓库自己的
`extract_fit_kernel()` 解析）：

```
FIT kernel-1: compression=gzip offset 0x1000 size=6076516
sha256(FIT kernel-1 payload)  = b4717c4cb30adece0491a8799234c1fa380749adf5328e20508e19b9eab301e3
sha256($(KDIR)/Image)         = b4717c4cb30adece0491a8799234c1fa380749adf5328e20508e19b9eab301e3   MATCH
```

```json
// bin/targets/airoha/an7581/profiles.json → "linux_kernel"
{"version": "7.3", "release": "1", "vermagic": "0e8e88c15987d49133565a21f8e229b3"}
```

`vermagic` 是 OpenWrt 对“内核版本 + 配置/ABI”算出的哈希：本机 vmlinux 里这个串出现 68 次
（`grep -c` 实测），文本 vermagic 是 `vermagic=7.3 SMP preempt mod_unload aarch64`，
设备上的模块目录是 `/lib/modules/7.3`。它能回答“模块和这个内核是不是同一套配置编的”；
它**不能**替代 FIT 载荷 hash（后者回答“镜像里嵌的是不是这份 `Image`”）。两条都要过。

时间戳那两条（`.o` 不早于源码、`vmlinux` 不早于 `.o`）是保守的：一个“目录里东西比镜像新”的树，
即使内容碰巧没变，也会被要求重建。发布构建本来就是从干净树一次编出来的，正常会全过；本地反复
`make` 的半成品树被拦下是预期行为。

## 用法

```sh
# 1) 只看源码/补丁：这个分支到底有没有 968/974？
scripts/check-release-image-features.py --repo .

# 2) 构建后：查内核和镜像（推荐在发布构建里跑）
scripts/check-release-image-features.py \
    --repo . \
    --build-dir build_dir \
    --image-dir bin/targets/airoha/an7581

# 3) 刷完新镜像后：离线复核运行镜像的 BQL 行为
scripts/check-release-image-features.py \
    --capture /tmp/bql-capture.txt \
    --skip-source --skip-build --skip-image

# 4) 自测（不需要板子/网络）：
python3 scripts/tests/check-release-image-features.py
```

`--build-dir` 可以给 OpenWrt 的 `build_dir` 根、`.../linux-airoha_an7581`，或
`.../linux-7.3` 本身；不给时会尝试自动找 `build_dir/target-*/linux-airoha_an7581/linux-7.3`。
`--image-dir` 不给时尝试 `bin/targets/airoha/an7581`。

### 采集 inflight（设备侧，打流时）

**采样点必须是 DSA conduit，不是物理口名。** `lan3`/`lan4` 是 DSA 用户口，出向走 `cpu`；
用户口自己没有 `byte_queue_limits` 组。

```sh
# 1) 先确认 conduit（只读）
readlink -f /sys/class/net/lan4/lower_*
# → /sys/devices/platform/soc/1fb50000.ethernet/net/cpu
```

本机实测的分布（`read-only`，镜像 `r38038` 前后那版 kernel 7.3）：

| netdev | tx 队列 | `byte_queue_limits` | lower |
|---|---|---|---|
| `cpu` | 32 | **有** | —（DSA conduit，10 Gbit/s） |
| `lan2` | 32 | 有 | — |
| `wan` | 32 | 有 | — |
| `lan3` | 1 | **没有** | `1fb50000.ethernet/net/cpu` |
| `lan4` | 1 | **没有** | `1fb50000.ethernet/net/cpu` |

物理口没有 BQL 组是**正常现象，不是镜像缺陷**。原因是内核不给“无队列”的设备建这个属性组：
`net/core/net-sysfs.c:1940`（`netdev_uses_bql()`）

```c
if (dev->lltx || (dev->priv_flags & IFF_NO_QUEUE))
	return false;
return IS_ENABLED(CONFIG_BQL);
```

而 `net/core/dev.c:12231-12234` 在驱动留 `tx_queue_len == 0` 时打 `IFF_NO_QUEUE`，
随后又把 sysfs 读到的值覆盖成 `DEFAULT_TX_QUEUE_LEN`：

```c
if (!dev->tx_queue_len) {
	dev->priv_flags |= IFF_NO_QUEUE;
	dev->tx_queue_len = DEFAULT_TX_QUEUE_LEN;
}
```

所以 `cat /sys/class/net/lan4/tx_queue_len` 读到的 `1000`（实测）**不代表驱动设过队列长度**——
拿 sysfs 的数字判“这口有没有 BQL”会误判，只能看 `queues/tx-*/byte_queue_limits/` 在不在。

采集用自动发现，不写死名字：

```sh
# 设备上，一边打流（例如 iperf3 -c <host> -t 10 -P 2），一边采：
for q in /sys/class/net/*/queues/tx-*/byte_queue_limits; do
    [ -d "$q" ] || continue
    dev=${q#/sys/class/net/}; dev=${dev%%/*}
    qid=${q#*/queues/tx-};    qid=${qid%%/*}
    printf '%s/tx-%s l=%s i=%s\n' "$dev" "$qid" "$(cat "$q/limit")" "$(cat "$q/inflight")"
done > /tmp/bql-capture.txt

# 可选：ethtool -S 只作旁证（这颗驱动没有 BQL 计数）
ethtool -S cpu > /tmp/ethtool-S.txt
```

本机 `ls -d /sys/class/net/*/queues/tx-*/byte_queue_limits` 只枚举出 `cpu`、`lan2`、`wan` 三个
（实测），所以上表里对着 `lan4` 采集会得到空文件——那不是“镜像没有 BQL”，是采错点了
（#101 里就踩过一次）。

把 `/tmp/bql-capture.txt` 拿到离线机器上跑 `--capture` 即可。脚本接受
`i=NNN`、`inflight=NNN`、`max_inflight=NNN` 和 sysfs `inflight` 文件。

**方向必须写进捕获文件名。** 本机同一队列两个方向的峰值差两个数量级（正向 1680 B / 反向
192584 B），不写方向的话，离线判据 64 KiB 会把“反向那一窗口”的结论套到“正向那一窗口”上。

### 退出码

| 码 | 含义 |
|---|---|
| 0 | 请求的检查全部通过 |
| 1 | 门禁失败：源码缺改动、对象/vmlinux 早于其输入、镜像内核与 `$(KDIR)/Image` 不是同一份（FIT 载荷 sha256 或构建串不符）、运行镜像 inflight < 64 KiB（**不看 Image/vmlinux 的 mtime 顺序**） |
| 2 | 用法或输入错误（路径不存在等） |
| 3 | 无法验证（镜像不是 FIT、缺 `vmlinux`、压缩格式不支持等） |

门禁失败（1）与无法验证（3）都会打印“重建/重刷/采集”的下一步，并且明确说明
**本检查没有刷机**；用法错误（2）只报错，不打印建议。

## 接进发布构建

发布镜像是 `xr1710g-builds` 的 `build.yml` 编的；在本仓库的脚本就位后，在
`Compile` 之后、`Collect images` 之前加一步即可（一行命令，失败即中断发布）：

```yaml
      - name: Verify 974/968 in the built image
        run: |
          cd openwrt
          python3 scripts/check-release-image-features.py \
            --build-dir build_dir \
            --image-dir bin/targets/airoha/an7581
```

本仓库的 `.github/workflows/check-release-image-features.yml` 在 PR 上跑自测，
并在 push 到 `xr1710g` 时跑一次源码审计：源码审计失败说明发布分支本身没有
968/974，任何镜像都不会有。

## 当前状态与处置

截至本次 PR（2026-11-15）验证时，`xr1710g` 分支的 `target/linux/airoha/patches-7.3/` 里**没有**
968/974（它们只在带合并的开发分支/快照里）。因此：

- 在 `xr1710g` 上跑 source 检查会**失败**：这是门禁要报的事实，不是脚本 bug；
- 在把带 968/974 的树变成发布构建的输入之前，不要发布新的 XR1710G 镜像；
- 合入后重新跑 `--build-dir`/`--image-dir`，全绿再刷机。

## 回滚

- **固件回滚**：保留上一个发布镜像；用常规 `sysupgrade` 刷回（LuCI 或 SSH）。
  设备起不来时走 U-Boot recovery console 刷 `...-ubi-initramfs-recovery.itb`，
  再刷回上一版 sysupgrade。**本门禁从不自动刷机，也不改镜像默认。**
- **门禁本身回滚**：revert 本 PR（`scripts/check-release-image-features.py`、
  测试、文档、workflow 和发布 CI 的接线步骤）即可恢复旧行为；脚本只读，
  不会留下镜像/构建副作用。
- **不要为了过门禁调低 `--min-inflight`**：发布判据是 64 KiB；调低等于绕过
  门禁本身。

## 已知限制

- 静态检查能证明“补丁被编进内核、并且这个内核被嵌进了镜像”，但不能证明
  板上正在跑的就是这个镜像；那需要 `--capture` 的实采。
- 968 没有独立计数器，靠源码 + 同一构建的符号/镜像证明；想单独做行为验证，
  用 `napi_defer_hard_irqs`/软中断时间做 A/B（本门禁不替代该实验）。
- `ethtool -S` 没有 BQL 计数是这颗驱动的现状，不是缺字段；判据看 sysfs。
- 时间戳一致性检查要求构建树和镜像来自同一次干净构建；本地脏树的告警需要
  重建消除，不能靠改时间戳绕过。
- `profiles.json` 的 `linux_kernel.vermagic` 目前**不由脚本自动比对**：脚本做的是 build 方向
  的 mtime 链、`Image`↔`vmlinux` 构建串、FIT 载荷 sha256 三条。vermagic 那条是“模块 ABI 是否
  同源”的人工判据，需要时手工核（见“构建/镜像一致性”表格最后一行）。
- `inflight` 判据 64 KiB 是**方向相关**的（本机正向峰值 1680 B、反向 192584 B）。采集时必须
  记下方向；只在“队列真的堆起来”的那个方向上下结论，不要用一个方向的阈值去判另一个方向。
