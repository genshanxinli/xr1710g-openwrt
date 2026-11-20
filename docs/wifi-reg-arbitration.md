# Wi-Fi 法规域仲裁（60_xr1710g-reg-arbitrate）四状态真值表

**状态**：代码 + 离线测试 + 一次实机只读空跑。CN 分支在本机（美规机）**未被实测**。
**关联**：#78、#216（`IPKG_INSTROOT` 与 `tr` 两处缺陷已合入）、#97。
**脚本**：`target/linux/airoha/an7581/base-files/etc/uci-defaults/60_xr1710g-reg-arbitrate`（181 行）
**测试**：`scripts/tests/test_reg_arbitrate.py`（14 个用例，含本文件的四状态表）

## 1. 为什么需要它

radio1（5 GHz）与 radio2（6 GHz）由**同一个** MT7996 wiphy 提供（`an7581-xr1710g-ubi.dts:247` `mt7996@0,0`），
而 cfg80211 每 wiphy 只保留一个法规域。netifd 把每个 radio 的 UCI `country` 依次 `iw reg set` 下去，
**不会失败**——最后起来的那个 radio 静默决定两个频段的域。于是 `radio1=CN` / `radio2=US` 这种配置
看起来设置成功，实际 5 GHz 的宽度/中心频点可能与 UCI 要求的不同。

脚本只仲裁这两个 `country` 值；不选信道、不选带宽、不启停/重载 wifi。

## 2. 判定顺序（`代码`，逐行指到脚本）

| 步骤 | 脚本行 | 条件 | 结果 |
|---|---|---|---|
| 0 | `:59` | `/etc/config/wireless` 不存在 | `exit 0`，静默 |
| 1 | `:61-64` | `board_name` 不是 `gemtek,xr1710g-ubi` | `exit 0`，静默 |
| 2 | `:80-83` | `wireless.radio1` 与 `wireless.radio2` **两个 section 都不存在** | 记一行 `nothing to arbitrate`，`exit 0` |
| 3 | `:94-100` `norm_country` | 值必须是 `[A-Za-z][A-Za-z]`，否则视为“没有国家” | 空串/`00`/`auto` → 空 |
| 4 | `:119-123` | `REG_PREFER` 归一化后不是 `CN`/`US` | 记 `ignoring REG_PREFER='x'`，**按未设置继续** |
| 5 | `:125` | `country1`、`country2` 都非空且不同 | 进冲突分支（6/7/8） |
| 6 | `:126-129` | 冲突 + `REG_PREFER` 未设置 | 记 `conflict … no change`，`exit 0`（默认，开机就是这样） |
| 7 | `:131-140` | 冲突 + `REG_PREFER` 等于**某一个** radio 的域 | 保留该 radio，另一个 `uci set` 成同域，`uci commit wireless`，记 `arbitrated …` |
| 8 | `:137-140` | 冲突 + `REG_PREFER` 与两个都不等 | 记 `matches neither radio`，`exit 0`，不改 |
| 9 | `:169-179` | 其余（两域相同 / 只有一个有域 / 都没有域） | 只记一行，不改 |

`--dry-run`（`:67`、`:146-149`、`:158`）把 `logger` 换成 stdout、跳过 `uci set`/`commit`，其余判定完全相同。
`/etc/init.d/boot`（START=10）不导出 `REG_PREFER`，所以**正常开机恒走“只记录、不修改”**。

## 3. 四状态真值表

`uci` 里只有两个变量决定走向：`wireless.radio1.country`(c1) 与 `wireless.radio2.country`(c2)。
下表把可达状态全列出来；“四状态”指前四行（不会触发改动的那四类），后三行是冲突三态。

| # | c1 | c2 | REG_PREFER | 分支（脚本行） | uci 是否被改 | 日志首行 |
|---|---|---|---|---|---|---|
| 1 | 空/`00` | 空/`00` | 任意（无效值先多一行告警） | `:169-170` | 否 | `reg=00 (no usable radio country), 5g=…(cfg), 6g=…(cfg)` |
| 2 | `CC` | 空/`00` | 任意 | `:171-172` | 否 | `reg=CC (radio1 only), …` |
| 3 | 空/`00` | `CC` | 任意 | `:173-174` | 否 | `reg=CC (radio2 only), …` |
| 4 | `CC` | `CC`（大小写不敏感） | 有值且 ≠ CC | `:175-176` | 否 | `reg=CC, … (REG_PREFER=DD ignored: radios already agree)` |
| 4b | `CC` | `CC` | 无 / 等于 CC / 无效 | `:177-178` 或 `:120-121`+`:177` | 否 | `reg=CC, 5g=…, 6g=…` |
| 5 | `CN` | `US` | 无 / 无效 | `:126-129`（无效时多一行 `ignoring REG_PREFER`） | 否 | `reg=CN/US conflict, …, no change (set REG_PREFER=cn\|us to arbitrate)` |
| 6a | `CN` | `US` | `us` | `:131-133`→`:143-166` | **是**：`radio1=US`，`commit wireless` | `reg=US, 5g=…, 6g=… (arbitrated CN/US, kept radio2, set radio1)` |
| 6b | `CN` | `US` | `cn` | `:134-136`→同上 | **是**：`radio2=CN`，`commit wireless` | `reg=CN, …, (arbitrated CN/US, kept radio1, set radio2)` |
| 7 | `CN` | `JP` | `us` | `:137-140` | 否 | `reg=CN/JP conflict, …, no change (REG_PREFER=US matches neither radio)` |
| 8 | 任一 section 缺失 | — | 任意 | `:80-83` | 否 | `no radio1/radio2 in the wireless config, nothing to arbitrate` |

两个“不变量”由表可见，也正是 `scripts/tests/test_reg_arbitrate.py:test_four_state_matrix_changes_nothing`
与 `test_prefer_matching_neither_radio_changes_nothing` 断言的东西：

1. 没有 `REG_PREFER` 时任何状态都**不写** uci；有 `REG_PREFER` 时只有 6a/6b 写。
2. 写入是幂等的：再跑一次同 `REG_PREFER` 时两 radio 已同域，落回第 4 行，不再 `commit`。

## 4. 实机证据（美规机，`实测`）

设备：`gemtek,xr1710g-ubi`，`r38047-a86ce12e27`，kernel 7.3。

先证明跑的是“镜像里那份”，而不是工作区里的改动：

```
# 设备 /rom 副本与仓库 HEAD 文件逐字节相同
$ sha256sum /rom/etc/uci-defaults/60_xr1710g-reg-arbitrate      # 设备
0e260919bda9418e3820c95820d638983bd736130cf65f1581353cce21834732
$ sha256sum target/linux/airoha/an7581/base-files/etc/uci-defaults/60_xr1710g-reg-arbitrate
0e260919bda9418e3820c95820d638983bd736130cf65f1581353cce21834732
```

`/etc/uci-defaults/60_xr1710g-reg-arbitrate` 在设备上**已不存在**（首次启动跑完即被删除），
所以只能跑 `/rom` 那份；它是只读镜像挂载，跑它不会 commit 任何东西。

只读空跑（无 `REG_PREFER`，即开机路径）：

```
$ uci -q get wireless.radio1.country; uci -q get wireless.radio2.country
US
US
$ md5sum /etc/config/wireless
85043fdce72207d89b6fe1912acaecc9  /etc/config/wireless
$ sh /rom/etc/uci-defaults/60_xr1710g-reg-arbitrate; echo rc=$?
rc=0
$ md5sum /etc/config/wireless
85043fdce72207d89b6fe1912acaecc9  /etc/config/wireless
$ logread -t xr1710g-reg | tail -1
Fri Nov 20 04:38:51 2026 [1795149531.726] user.notice xr1710g-reg:
  reg=US, 5g=ch149/EHT80(cfg), 6g=ch37/EHT320(cfg)
```

→ 命中真值表第 4b 行：`rc=0`，config 字节不变，只记一行。

两条同样只读、但会走别的判定入口的路径也实测了（都在“两 radio 已同域”的前提下，不会写 uci）：

```
$ REG_PREFER=cn sh /rom/etc/uci-defaults/60_xr1710g-reg-arbitrate; echo rc=$?
rc=0
$ logread -t xr1710g-reg | tail -1
  … xr1710g-reg: reg=US, 5g=ch149/EHT80(cfg), 6g=ch37/EHT320(cfg)
      (REG_PREFER=CN ignored: radios already agree)

$ REG_PREFER=jp sh /rom/etc/uci-defaults/60_xr1710g-reg-arbitrate; echo rc=$?
rc=0
$ logread -t xr1710g-reg | tail -2
  … xr1710g-reg: ignoring REG_PREFER='jp': only cn|us is supported
  … xr1710g-reg: reg=US, 5g=ch149/EHT80(cfg), 6g=ch37/EHT320(cfg)
$ md5sum /etc/config/wireless
85043fdce72207d89b6fe1912acaecc9  /etc/config/wireless
```

→ `REG_PREFER=cn` 归一化成 `CN` 并进入判定（说明 `tr 'a-z' 'A-Z'` 修法在真机 busybox 上有效），
无效值确实先告警再按“未设置”继续。顺带在同一台机上复核了 #216 的第二个缺陷本体：

```
$ echo cn | tr "[:lower:]" "[:upper:]"
cn                      # busybox 不实现字符类，原样透传 —— 缺陷可复现
$ echo cn | tr a-z A-Z
CN                      # 仓库现在的写法
```

`iw reg get` 复核域确实是 US（不是“设了没生效”）：

```
$ iw reg get | head -2
global
country US: DFS-FCC
```

## 5. 这台机器上**无法**验证的部分（`未验证`）

CN 分支（真值表 6b 行）需要 `wireless.radio1.country` 与 `wireless.radio2.country` 处于冲突状态才会进入。
本机是美规机，出厂两个 radio 都是 `US`；把它改成 `CN` 再跑脚本属于 `uci set` 状态变更，
不在本 agent 的只读权限内（已列入报告的“需要 Lead 批准的状态变更”）。

要在 CN 分支上拿到实测，需要满足任一条件：

1. 一台国行/CN 固件机，`uci show wireless` 里 `radio1.country=CN`；或
2. 本机临时 `uci set wireless.radio1.country=CN && uci commit wireless`（可回滚，`/etc/config/wireless` 先备份），
   然后 `REG_PREFER=cn sh /rom/…` 观察是否把 `radio2` 改成 `CN` 并 `commit`；或
3. 只在离机复现：`python3 -m unittest scripts/tests/test_reg_arbitrate.py`——用 `uci` 桩把 6a/6b/7 三行全走一遍
   （已做，见 `test_prefer_cn_keeps_radio1`、`test_prefer_arbitrates_and_is_idempotent`）。

**脚本自身不选信道/带宽**，所以“CN 域下 5 GHz 160 MHz 与 6 GHz 320 MHz 是否真的同时起来”不在本文件范围内；
那需要 `scripts/wifi-reg-report.sh` 的实际起网结果，本机也没有 CN 域可测。

## 6. 台账与复跑方式

`scripts/claims.yaml` 里的 `reg-arbitrate-us-agree`（`实测`，supported）只覆盖真值表第 4b 行；
6a/6b 两行仍是 `未验证`，不得当成既有事实引用。


```
python3 -m unittest scripts/tests/test_reg_arbitrate.py     # 14 用例，纯离线
python3 -m unittest scripts/tests/test_pcie_single_cut.py   # #97 的寄存器/设备证据，纯离线
```
