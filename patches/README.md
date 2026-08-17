# 补丁层规范（patches/）

本目录是本仓库的**自维护补丁层**：openwrt master 尚未合入、或不打算合入（如 OC/regdb 功率）的全部改动都从这里进树。
**政策：遇到问题修复而不是降级**——补丁与上游冲突/失效时，定位根因修复本层，而不是删掉能力。

## 目录与目标映射

| 桶 | 内容 | 落点（相对 openwrt 树根） |
|---|---|---|
| `patches/kernel/` | 内核类补丁 | `target/linux/airoha/patches-6.18/`（OpenWrt 构建时自动应用） |
| `patches/uboot/` | U-Boot 类补丁 | `package/boot/uboot-airoha/patches/` |
| `patches/packages/` | 包级补丁（regdb / mt76 / kmod…） | 按 `MANIFEST` 指定目录拷贝 |
| `patches/root/` | 跨目录补丁（如 #22397 板级支持，13 文件） | 树根 `git apply` |
| `patches/specs/` | 补丁**说明书**（来源 URL/上游状态/待取源）或暂存参考补丁 | 不自动应用 |

## MANIFEST（应用清单）

`patches/MANIFEST` 每行一条：`<补丁相对路径> <目标目录|ROOT>`。

- `#` 开头 = 注释/停用；`#EXP ` 开头 = 实验档（`apply-patches.sh --experimental` 才应用）。
- **实验档 → 默认档毕业条件**：在 known-good 周期内跑通 `docs/ACCEPTANCE.md` 全项 → 取消 `#EXP` 注释并入默认，并在 `docs/FIXES.md` 对应条目改状态。

## 补丁文件元数据头约定

每个补丁文件首段注释（`#` 行）建议包含：

```
# Source:  <URL / PR 号 / commit>
# Upstream: merged | open(PR #NN) | carried-only | n/a
# Reason: 一句话为什么在本层
```

## OC（超频）不是普通补丁

OC 依赖 master 树当前形态（`an7581.dtsi` OPP 表、`config-6.18` governor、PM domain 的 PLL 公式位置随内核版本漂移），因此不放在 MANIFEST，
由 `scripts/prepare-oc.sh <1.3|1.4>` 在**构建前**对树做确定性编辑（失败即报错，不静默降级）。原始参考补丁见
`patches/specs/original-oc-80096373b5-6.12-reference.patch`（fanboy OpenW1700k `ubi2-oc` commit 80096373b5，6.12 路径，仅作机制参考）。

## 新增补丁流程

1. 取源（PR diff / 分支 commit）放入对应桶，写元数据头 + `MANIFEST` 条目（或 `#EXP`）；
2. `scripts/apply-patches.sh <树> --dry-run` 验证可应用；
3. 首次构建验证；构建/启动问题 → 修本层补丁（修复不是降级），并记 `docs/FIXES.md`。