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
  cat /sys/class/net/<dev>/queues/tx-*/byte_queue_limits/inflight
  ```

  **判据：窗口内最大 `inflight` ≥ 65536 字节（64 KiB）。** 1G 路径实测峰值
  116038 B（≈77 帧）；10G 路径按 64 KiB 判。空闲时的残值不算证据——`limit`
  只在完成事件里收缩，必须在打流时采。
- `ethtool -S`：airoha 驱动没有 BQL 计数（`ethtool -S` 只报
  `rx_fc_drops`/`tx_dropped` 等），BQL 的权威接口是上面的 sysfs。脚本会读取
  `ethtool -S` 采集并在有 BQL 字样计数时提示，但**不以它作为硬判据**。

### 968：`napi_complete_done(napi, done)`

- 源码/补丁：`airoha_eth.c` 的 RX/TX 两个 poll 都是
  `napi_complete_done(napi, done)`（2 处），没有旧的
  `napi_complete(napi)`。
- 构建：该源码被编进当前内核（`.o` 比 `.c/.h` 新，`vmlinux` 比 `.o` 新，
  `Image` 比 `vmlinux` 新，见下一节）。
- 运行：968 是“把真实 work_done 传给 NAPI core”，没有独立计数器；`ethtool -S`
  也看不到。它由“源码 + 同一份构建的符号/镜像”证明，运行时用
  `napi_defer_hard_irqs` 的行为做旁证（可选）。

### 构建/镜像一致性

- `airoha_eth.o` 不早于 `airoha_eth.c/.h`；
- `vmlinux` 不早于驱动对象；
- `$(KDIR)/Image` 不早于 `vmlinux`；
- `.itb` 的 FIT `kernel-1` 解压后 sha256 **必须等于** `$(KDIR)/Image`；
- `Image` 和 `vmlinux` 的 `Linux version ...` 构建串一致。

时间戳检查是保守的：一个“目录里东西比镜像新”的树，即使内容碰巧没变，也会
被要求重建。发布构建本来就是从干净树一次编出来的，正常会全过；本地反复
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

```sh
# 设备上，一边打流（例如 iperf3 -c <host> -t 10 -P 2），一边采：
for q in /sys/class/net/lan10g/queues/tx-*/byte_queue_limits; do
    printf '%s l=%s i=%s\n' "$q" "$(cat "$q/limit")" "$(cat "$q/inflight")"
done > /tmp/bql-capture.txt

ethtool -S lan10g > /tmp/ethtool-S.txt   # 可选
```

`lan10g` 只是示例：按实际承载出向的 netdev 替换（`cpu`、`wan10g` 等）。
把 `/tmp/bql-capture.txt` 拿到离线机器上跑 `--capture` 即可。脚本接受
`i=NNN`、`inflight=NNN`、`max_inflight=NNN` 和 sysfs `inflight` 文件。

### 退出码

| 码 | 含义 |
|---|---|
| 0 | 请求的检查全部通过 |
| 1 | 门禁失败：源码缺改动、构建/镜像过期、运行镜像 inflight < 64 KiB |
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
