# eagle v4 DDR descriptor 固件：构建与静态校验清单

**状态：静态构建与静态校验完成；未上板、未刷机、未写任何设备。**

本清单对应路线图 D6：把 AN7581 + MT7996 的 eagle 固件从 SRAM
descriptor 布局推进到 stock v08 的 DDR `npu_pkt` descriptor 布局，
并只做离线构建与静态验证。所有结论来自源码、交叉编译器、ELF/反汇编
和静态地址模型，不是启动、DMA 或收发包结论。

## 1. 目标镜像

| 项 | 值 |
|---|---|
| SOC | `AN7581` |
| WiFi | `MT7996` |
| datapath | `WIFI_EAGLE`（AN7581 + MT7996 走 eagle/RRO，不使用 kite） |
| 构建标识 | `GITREV=eagle-v4-ddr` |
| 固件版本串 | `TLB7.8.0.0_v003.MT7996.eagle-v4-ddr` |

## 2. 源码与补丁

- 源码：<https://github.com/ClankerConstruction/ClankerNPU>
- 固定提交：`735529c10d5120e10f7e4a6ddf97fb384fce9903`
- v4 补丁内嵌在 `build-eagle-v4.sh`，不额外提交 patch 文件；
  补丁 sha256：`d8a2c01842364f40877e78f735be71da661f395ac13b61f8c14db7eeb1e44b4b`
- 补丁修改 11 个源文件：`npu_config.h`、`npu_globals.c`、
  `npu_hostadpt.c`、`npu_internal.h`、`npu_sram.c`、`npu_wifi.c`、
  `npu_wifi.h`、`npu_wifi_bufid.c`、`npu_wifi_eagle.c`、
  `npu_wifi_eagle_dp.c`、`npu_wifi_init.c`，共 11 个。

v4 结构性改动：

1. ring descriptor arena 移出 64 KB SRAM，落到 DDR `npu_pkt`：
   NPU 基址 `0x3E8A2000`，host 视图 `0x8A0A2000`，
   type1 = `0x4A040`，与 stock v08 的 type256/type1 一致。
2. qid10/11/12 使用 stock ring7/8/9 偏移
   `+0x18020/+0x19020/+0x1B020`，即 256/512/1024 × 16 B。
3. qid 返回保持 `base & 0x1FFFFFFF`，host 可见值在 `0x1E8...`
   窗口（例如 qid10 `0x1E8BA020`），不改回未 mask 的 `0x3E8...`。
4. 删除 SRAM 的 type1/type29/type44；type26 = `0x4000`
   （3 个 1024-id MSDU page pool + 3072 个 TDMA rx id 共用）；
   type129 = `0xE5FF`、type133 = `0x11000`，均按 stock v08 尺寸表。

## 3. 构建命令与工具链

```sh
tools/npu-firmware/build-eagle-v4.sh
# 等价的 core 命令：
# make -B SOC=AN7581 WIFI=MT7996 CLANKER=0 NPUTX=1 NPUDBG=0 PROF=0 \
#      GITREV=eagle-v4-ddr CROSS=riscv64-elf-
```

实际工具链：`riscv64-elf-gcc (Arch Linux Repositories) 16.2.0`。
换工具链版本会改变 md5；静态校验项不依赖具体工具链。

`--dry-run` 只打印步骤：无网络、无编译、无文件写入，退出 0。

## 4. 产物

| 文件 | 大小 | md5 | sha256 |
|---|---:|---|---|
| `npu_rv32.bin` | 50766 B | `8597e7cc58b72bbc1c16ed060ce44e11` | `20c71d1dacecc9b8bce8c3c0c20a92ecb4258467e7b367fb31279492d2776b5e` |
| `npu_data.bin` | 304 B | `54dbac0cefdcd39546b95b3ca3b762cf` | `705472e6e4d11a92ead6d2ff9a998bf0fa465b2ac7a6288860fd13ce9866090c` |
| `firmware.elf` | 94604 B | `a3289bbdffb831634fde71dc1d9d40a7` | `57cd06f5a96cbac02b23cf3ad45d35711a11683212604e0aabfb7e89763a8e20` |

两个 bin 是同一镜像的两半，必须成对使用；`.data` 里是 `.text` 的绝对
函数指针。构建产物不提交 git。

## 5. qid 地址

| qid | 用途 | NPU 地址 | host 可见（`& 0x1FFFFFFF`） | ring 大小 |
|---:|---|---|---|---:|
| 0 | RRO band0 | `0x3E8A2000` | `0x1E8A2000` | 0x6000 |
| 2 | RRO band2 | `0x3E8C4020` | `0x1E8C4020` | 0x6000 |
| 5 | tx ring band0 | `0x3E8A8020` | `0x1E8A8020` | 0x8000 |
| 7 | tx ring band2 | `0x3E8C8040` | `0x1E8C8040` | 0x8000 |
| 8 | RRO ind cmd | `0x3E8C1020` | `0x1E8C1020` | 0x3000 |
| 10 | MSDU page band0 | `0x3E8BA020` | `0x1E8BA020` | 0x1000 |
| 11 | MSDU page band1 | `0x3E8BB020` | `0x1E8BB020` | 0x2000 |
| 12 | MSDU page band2 | `0x3E8BD020` | `0x1E8BD020` | 0x4000 |

qid 2/7/11/12 的返回值非零；qid10/11/12 的偏移与 host
256/512/1024 × 16 B 的请求逐项对齐。

## 6. 边界

- DDR arena：`0x3E8A2000 + 0x4A040 = 0x3E8EC040`；
  host 视图 `0x8A0A2000 + 0x4A040 = 0x8A0EC040`，
  低于 `npu_pkt` 末端 `0x8CC00000`（DTS 44 MB no-map）。
- 所有 ring 末端都不越过 type1：qid12 末端 `0x3E8C1020`，
  qid7 末端 `0x3E8D0040`，均小于 `0x3E8EC040`。
- SRAM：type1/29/44 已删除；type26=`0x4000`；
  type129=`0xE5FF`、type133=`0x11000`。按 v4 分配顺序重放，
  allocator 末端 `0x3E84D240`，低于 `SRAM_END=0x3E877FFE`，
  余量 `0x2ADC0`。不存在 v2 的 `0x9D00` 超支。
- `__image_end=0x8400C64E`，远低于 2 MB rv32 上限；
  `__bss_end=0x3E905E04 < __ndbg_base=0x3E906800`。

## 7. 静态检查结果

全部 PASS（来自 `build-eagle-v4.sh` 内嵌的静态校验器）：

- 入口 `0x84000000`，前 8 个 16-bit NOP、`fence.i`/`fence`，8 路
  `mhartid` 分派。
- 版本串 `TLB7.8.0.0_v003.MT7996.eagle-v4-ddr` 在 `.rodata`。
- NDBG：`__ndbg_base=0x3E906800`（host `0x1E906800`），
  magic `0x4E444247`，块长 `0x1000`。
- DDR arena 基址 `0x3E8A2000`、type1 大小 `0x4A040` 在
  `wifi_pcie_desc_alloc` 中生成；ring 偏移表与 stock
  ring1/2/3/4/6/7/8/9 一致。
- qid 跳转表 13 项，qid2/7/11/12 走独立 handler；返回路径执行
  `slli 3; srli 3`（等价 `& 0x1FFFFFFF`）。
- qid0/2/5/7/8/10/11/12 的计算地址全部非零，且落在 DDR type1 内。
- MSDU page ring 上限 `.data` `CSWTCH.60` =
  `256/512/1024`，ring 间距 `0x1000/0x2000`。
- `get_wait_func_table` 10 项全部指向 `.text`，第 4 项即
  `eagle_mail_get_rxdesc_base`。

## 8. 与 stock v08 的差异

| 项 | stock v08 | 本 v4 |
|---|---|---|
| `npu_rv32.bin` | 125832 B `550a8b3bf967a1e83bb1aaeca030ec7b` | 50766 B `8597e7cc58b72bbc1c16ed060ce44e11` |
| `npu_data.bin` | 3092 B `210375f102c7c8a7c41f7a60c83d7652` | 304 B `54dbac0cefdcd39546b95b3ca3b762cf` |
| 版本串 | `TLB7.7.0.0_v08` | `TLB7.8.0.0_v003.MT7996.eagle-v4-ddr` |
| descriptor 区 | DDR `0x3E8A2000`，type1 `0x4A040` | **一致**：DDR `0x3E8A2000`，type1 `0x4A040` |
| MSDU page qid10/11/12 | ring7/8/9 | **一致**：`+0x18020/+0x19020/+0x1B020` |
| qid 返回 mask | `& 0x1FFFFFFF` | **一致** |
| SRAM type1/29/44 | 不占 SRAM | **一致**：已删除 |
| type26 / 129 / 133 | `0x4000` / `0xE5FF` / `0x11000` | **一致** |
| qid0/2 来源 | host `SET_WAIT_PCIE_ADDR` 基址 | 仍取 ring table 基址（本仓库既有行为），值同样落在 DDR arena |
| 数据面完整度 | 厂商完整 SDK 镜像 | Clanker 重建镜像，只覆盖本仓库既有功能面 |

## 9. 未做 / 限制

- **未上板、未刷机、未写设备**；没有串口、寄存器或收发包证据。
- 静态结论只证明镜像自洽与地址/尺寸一致，不证明可启动或可上板。
- qid0/2 仍按本仓库既有行为返回 ring table 基址；stock 使用 host 传入
  基址。若后续上板发现 host 对 qid0/2 有不同期望，需要单独对照。
- TX ring 的 `EAGLE_TX_RING_MASK=0x7FF`（2048 项）与 host 的 1024 项
  不一致是上游/上一版遗留项，本次未改；不影响本清单的静态构建结论。
- ClankerNPU 上游无 LICENSE 文件；二进制只作内部实验件，不对外分发、
  不提交 git。
- `build-eagle-v4.sh` 只新增构建/校验逻辑，不改 OpenWrt 内核、DTS、
  mt76 或其他脚本。

## 10. 复现

```sh
bash -n tools/npu-firmware/build-eagle-v4.sh   # 语法
tools/npu-firmware/build-eagle-v4.sh --dry-run # 只打印步骤，退出 0
tools/npu-firmware/build-eagle-v4.sh           # 克隆固定提交、打补丁、构建、静态校验
```

默认产物在 `build_dir/npu-firmware/eagle-v4/`（OpenWrt 已忽略
`build_dir/`），含两个 bin、ELF、map、disassembly、`manifest.txt` 与
`verify.log`。
