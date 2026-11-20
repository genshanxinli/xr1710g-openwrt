# pcie_single_cut 寄存器（0x1fbe3418）验证记录

**状态**：寄存器读数与 PCIe 拓扑均已**实测**；寄存器字段**语义**仍是推断，且本机**无法**验证“写 0x0 会关掉 cut”。
**关联**：#97。
**代码**：`scripts/pcie-single-cut.sh`（512 行；`ADDR=0x1fbe3418` 在 `:54`，字段上限 `0x7` 在 `:241` 与 `:317`）
**设备证据**：`scripts/tests/fixtures/pbus_csr-1fbe3400.registers`（devmem/debugfs 原始 63 行）
**测试**：`scripts/tests/test_pcie_single_cut.py`（8 个用例，把下面每个数字互相钉住）

## 1. 脚本到底假设了什么（`代码`）

| 假设 | 出处 | 内容 |
|---|---|---|
| A1 | `scripts/pcie-single-cut.sh:54` | 32 位寄存器在 `0x1fbe3418`；ADDR 必须 4 字节对齐且在 A53 禁区之外（`:198-205`） |
| A2 | `target/linux/airoha/dts/an7581.dtsi:589-592` | `pbus_csr: syscon@1fbe3400`，`reg = <0x0 0x1fbe3400 0x0 0xff>` ⇒ `0x1fbe3400 + 0x18 == 0x1fbe3418` |
| A3 | `scripts/pcie-single-cut.sh:4-10`、`:241`、`:317` | 该寄存器开机后读 `0x7`，字段只有低 3 位；写 `0x0` 等于“关掉 cut” |
| A4 | `scripts/pcie-single-cut.sh:12-14` | 不在启动路径里、不装进镜像、没人自动调用 |

## 2. 实测：寄存器读数（`实测`）

设备 `gemtek,xr1710g-ubi`，`r38047-a86ce12e27`，kernel 7.3。先确认 debugfs 里确实有这个 syscon 的 regmap：

```
$ ssh root@192.168.1.1 'ls /sys/kernel/debug/regmap/ | grep syscon'
dummy-syscon@0x000000001fa20000
dummy-syscon@0x000000001fbe3400
dummy-system-controller@0x000000001fbf0200
```

名字是 `dummy-syscon@…`：syscon 节点没有任何驱动去 bind，是 syscon/mfd 核心代建的 regmap——
**这条本身就说明 `0x18` 没有任何 DT 消费者**（见第 5 节）。

```
$ ssh root@192.168.1.1 'cat /sys/kernel/debug/regmap/dummy-syscon@0x000000001fbe3400/registers'
00: 20000000
04: fc000000
08: 21000000
0c: ff000000
10: 28000000
14: fc000000
18: 00000007        ← A3 断言的那一行，仍然成立
1c: 00000000
…  (共 63 行，offset 0x00..0xf8)
```

→ `0x1fbe3400 + 0x18 == 0x1fbe3418 == 0x00000007`。A1/A2/A3 的读值部分**与仓库假设一致**，
先前那次 regmap dump 的结论可以复用，不是“早就改了”的历史值。

脚本本体（与仓库 HEAD 逐字节相同：`sha256 0d159603ba61ce3407a8554b66278b1d6f94ff2561d427ecd22c725c18cdaa9f`）
拷到 `/tmp` 后跑 `status`，本机当下确实如头部注释所说拒绝访问：

```
$ sh /tmp/pcie-single-cut.sh status
pcie-single-cut.sh: refusing: /dev/mem does not exist (kernel CONFIG_DEVMEM is off?)
rc=1
$ sh /tmp/pcie-single-cut.sh apply
pcie-single-cut.sh: error: apply requires --confirm; no register was touched
rc=2
```

（`ls /dev/mem` → `No such file or directory`；`command -v devmem` → 无输出。`实测`）

## 3. 实测：它推理的 PCIe 拓扑（`实测`）

```
$ ssh root@192.168.1.1 'for d in /sys/bus/pci/devices/*; do
    echo "$(basename $d) vendor=$(cat $d/vendor) device=$(cat $d/device)
          width=$(cat $d/current_link_width) speed=$(cat $d/current_link_speed)
          driver=$(basename $(readlink $d/driver))"; done'
0000:00:00.0 vendor=0x14c3 device=0x6899 width=2 speed=8.0 GT/s PCIe driver=pcieport
0000:01:00.0 vendor=0x14c3 device=0x7990 width=2 speed=8.0 GT/s PCIe driver=mt7996e
0002:00:00.0 vendor=0x14c3 device=0x6899 width=1 speed=5.0 GT/s PCIe driver=pcieport
0002:01:00.0 vendor=0x14c3 device=0x7991 width=1 speed=5.0 GT/s PCIe driver=mt7996_hif
```

对得上仓库的板级 DT：

| 控制器 | 节点 base | PCI domain | 实测链路 | 板级 DT |
|---|---|---|---|---|
| pcie0 | `1fc00000`（`an7581-xr1710g-ubi.dts:221-226`，另有 `sec-pcie-mac=1fc20000`） | `0000` | x2，8.0 GT/s，`14c3:7990` | `num-lanes = <2>`（`:235`） |
| pcie1 | `1fc20000`（`an7581.dtsi:825`） | 无 | **未枚举（disabled）** | `&pcie1 { status = "disabled"; }`（`:280-282`） |
| pcie2 | `1fc40000`（`an7581.dtsi:866`） | `0002` | x1，5.0 GT/s，`14c3:7991` | `&pcie2 { status = "okay"; }`（`:284-289`） |

Uevent 也确认 5 GHz/2.4 GHz 那颗 MT7996 挂在 pcie0 上：

```
$ cat /sys/bus/pci/devices/0000:01:00.0/uevent
DRIVER=mt7996e
OF_FULLNAME=/soc/pcie@1fc00000/pcie@0,0/mt7996@0,0
PCI_ID=14C3:7990
```

`dmesg` 只剩 22 行（环形缓冲已滚掉开机段），所以**开机枚举过程没有留证**；上表的链路宽度来自 sysfs 当前值，
不是 dmesg。`实测`，但“开机时怎么训练起来的”这件事本机已无法回溯。

## 4. 由此产生的结论与未决问题

**结论（`实测`+`代码`）**：三个假设里，能被设备证实的部分全部成立——地址等于 `pbus_csr+0x18`、读值仍是 `0x7`、
拓扑是 x2(`7990`)+x1(`7991`)、`pcie1` 确实 disabled。

**以下两点本机无法证实，且不应被写成结论：**

1. **`0x7` 的语义（`推断`）**。本仓库内没有任何文件解释这个字段：`mediatek,pbus-csr` 的三个窗口分别是
   `0x0-0x4`、`0x8-0xc`、`0x10-0x14`（`an7581.dtsi:805`/`:846`/`:887`），**没有一个覆盖 `0x18`**。
   也就是说没有任何 in-tree 驱动会保存/恢复这一位，写它纯粹靠外部文档。
   `scripts/tests/test_pcie_single_cut.py:test_no_dt_consumer_claims_offset_18` 把这个事实做成了断言，
   以后若有人给 `0x18` 加了驱动窗口，那条测试会先响。
2. **“写 `0x0` = 关掉 cut”是否可观测（`未验证`）**。要验证得先让 `/dev/mem` 与 `devmem` 可用
   （这是独立的 kernel `CONFIG_DEVMEM` + busybox applet 改动，不在 #97 范围内），然后写寄存器并测 P99 延迟/
   吞吐——即一次真实的 bench，属于需要 Lead 批准的状态变更。本机今天连 `status` 都读不出值（第 2 节），
   所以这一步**没有做**。

顺带一个与“cut=3 条 lane”叙述相抵的观察（`实测`）：`0x7` 是三位全置，但两条链路此刻都在正常训练（x2 与 x1）。
若 `0x7` 字面意思是“三条 lane 全 cut”，链路不该起来。因此该字段更可能是别的编码（例如 cut 的候选/门控位），
而不是“当前已切断”的位图。这只是**推断**，但它说明“写 0x0 能提升延迟”这条 vendor 说法在本机没有独立支撑。

## 5. 交付物怎么钉住这些数字

- `scripts/tests/fixtures/pbus_csr-1fbe3400.registers`：第 2 节那份 dump 的**原文**（63 行，带来源头注释）。
- 台账条目（`scripts/claims.yaml`）：`pbus-csr-0x18-reads-7`（`实测`，supported）与 `pcie-topology-xr1710g`（`实测`，supported），`python3 scripts/check-claims.py` 通过。
- `scripts/tests/test_pcie_single_cut.py`：
  - `DeviceEvidenceTest`：fixture 必须覆盖 `0x18`、`0x18 == 0x7`、脚本 `ADDR` 必须等于 dtsi `pbus_csr` 基址 + `0x18`、
    且 dtsi 里没有窗口覆盖 `0x18`；
  - `ScriptRunTest`：用 devmem 桩把 fixture 的 `0x7` 灌进去，跑 `status`/`apply --confirm`/`restore`，
    断言 `0x1fbe3418 = 0x00000007`、`apply` 写 `0x0` 且备份写 `0x00000007`、`restore` 回到 `0x7`；
    另外断言读到 `0x9`（超出 0x7 字段）时 `apply` 拒绝且不写。

```
python3 -m unittest scripts/tests/test_pcie_single_cut.py     # 8 用例
```
