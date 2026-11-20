# 分支处置清单（2026-11-20）

基线：`origin/xr1710g` = `44d4267ca7`（PR #201 merge）。所有 ahead/behind 都是相对这个提交。

## 判定准则

1. **内容优先于提交**。一个分支可以删，只有同时满足：
   - 它的每个提交，内容已经以某种形式进入 `xr1710g`（同 subject 落地、同 blob、patch-id 等价、语义等价的重锚，四者之一）；或者
   - 提交本身还活着：是 `upstream/*` 的祖先（上游仍然持有），或者是受保护分支（`kernel73` / `kernel74`）的祖先；
   - 或者是维护者**明确宣布放弃**的探索（需要一条可引用的记录，不能靠"看起来没用了"推断）。
2. **`git cherry` 只是线索，不是判决**。本仓的补丁在落地时几乎都被重锚过（PR #195 重排六条碰撞补丁、#199 重锚 QinQ、#197 重编号 217），patch-id 全变，所以 `git cherry` 大概率全 `+`。判"已落地"要用 **blob 相等**（`git rev-parse <ref>:<path>`）或 **patch 文件的语义 diff**（只剩 hunk 行号偏移）。
3. **受保护分支不进入删除流程**：`kernel73`（上游镜像，必须与 `upstream/kernel73` 保持逐字节一致）、`kernel74`（PR #193/#203 的来源）。任何 `fix/*`、`docs/*` 的 agent 在用分支也不进入，即使 PR 已合并。
4. **删除是一次性动作**，先删"0 ahead（已被 PR 完整合并）"的分支，其余只写建议。合并后删 head 分支不影响已合并内容：merge commit 已经持有那些树。

## 总表

| 分支 | ahead/behind | 最后提交 | PR | 未被 PR 覆盖的独有提交 | 处置 | 理由 |
| --- | --- | --- | --- | --- | --- | --- |
| `fix/pse-reserve-param` | 0 / 1 | 2026-11-20 08:50 | #201 merged | 无 | **delete（已执行）** | 提交是 `xr1710g` 的祖先，删除不丢内容 |
| `fix/rebase-six-colliding-airoha-patches` | 0 / 12 | 2026-11-20 03:29 | #195 merged | 无 | delete（建议） | 同上 |
| `ci/xr1710g-buildable` | 0 / 14 | 2026-11-19 18:45 | #194 merged | 无 | delete（建议） | 同上 |
| `fix/build-blockers-soe-and-fakeroot` | 0 / 11 | 2026-11-20 04:06 | #196 merged | 无 | delete（建议） | 同上 |
| `fix/qdma-irq-bank-mask-217` | 0 / 7 | 2026-11-20 04:29 | #197 merged | 无 | delete（建议） | 同上 |
| `fix/qinq-tpid-9999` | 0 / 8 | 2026-11-20 04:38 | #198 merged | 无 | delete（建议） | 同上 |
| `fix/qinq-9999-reanchor` | 0 / 3 | 2026-11-20 05:45 | #199 merged | 无 | delete（建议） | 同上 |
| `agent/qdma-irq-bugon-d65bfddeab28` | 1 / 173 | 2026-11-15 23:56 | #192 closed | `a12938aabf` — 但 `git cherry` 判 `-`，等价提交 `651b26d5c2` 已在 #197 | delete（建议） | patch-id 等价，内容已落地 |
| `agent/ppe-qinq-tpid-6da6bbcea4aa` | 4 / 16 | 2026-11-16 06:53 | #124 closed，内容经 #198/#199 落地 | `e6b978a544`、`46275aadab`（TPID 补丁本体）；`8b1d45131b`（7.3/6.18 栈刷新）；`2c8be68b55`（merge） | delete（建议） | TPID 补丁与 `xr1710g` 的 `9999-...QinQ-TPID-support.patch` 语义等价（diff 只剩 hunk 行号）；栈刷新被 #195/#196 取代 |
| `agent/pse-reserve-param-aa5109af1053` | 3 / 173 | 2026-11-15 10:38 | #164 closed，内容经 #201 落地 | `d210cab015`（PSE 参数化，patch blob **SAME**）；`2d75834be6`（dump-target-info 接受两段版本号）；`8c2dce63f7`（7.3 栈刷新） | delete（建议，等 #203） | 两条 PSE 补丁 blob 与 `xr1710g` 完全相同；脚本改动被 #203 的 `(?:\.\d+)?(?:-rc\d+)?` 覆盖；栈刷新被 #195 取代 |
| `fix/wan-docs-and-harnesses` | 2 / 2 | 2026-11-20 06:22 | #200 open | `0c57a3433d`、`0013cccd4a`（PR 本体） | keep → 合并后 delete | PR 未合并前删 head 分支等于丢 PR |
| `fix/kernel-618-675-02` | 1 / 2 | 2026-11-20 09:12 | #202 open | `30bd24fca7`（PR 本体） | keep → 合并后 delete | 同上 |
| `kernel74` | 6 / 16 | 2026-11-19 18:38 | #193/#203 来源 | `ffc6be1a16`、`0d5a1eb9ce`、`a9fb6834e1`、`77efef3ab8`、`b53639392b`、`c4507aa6ce` | keep-as-mirror | #193/#203 的 head 直接从这里切出，必须保留 |
| `fix/kernel74-stage1` | 2 / 0 | 2026-11-20 09:35 | #203 open | `a1e0401391`、`55d139a62d` | keep（agent 在用，不动） | PR #203 的 head 分支，另有 agent 正在使用 |
| `kernel73` | 642 / 342 | 2026-11-14 16:16 | 无（#189 跟踪） | 642（整条上游 kernel73 线） | keep-as-mirror | 上游镜像分支，必须持续与 `upstream/kernel73` 对齐，不删 |
| `agent/upstream-sync-86d15e9d44d6` | 826 / 342 | 2026-11-19 18:40 | 无（#189 的 sync 尝试） | 见「六分支探索线」 | keep-as-mirror | 分支独有内容仍在，且是唯一持有该 rebase 结果的引用 |
| `deliver/offline-round1` | 833 / 342 | 2026-11-19 19:04 | #200（docs+harnesses） | 见「六分支探索线」 | keep-as-mirror | 同线，含 #200 尚未合入的文档与 harness |
| `impl/101-bql-inflight` | 827 / 342 | 2026-11-19 19:20 | 无 | `b5a1724cc1` 线；独有 968/974 两个补丁 | **先不要删**（另一 agent 正在搬运 968/974） | 内容不在任何 PR 里 |
| `impl/19-lan10g-diag` | 827 / 342 | 2026-11-19 19:19 | #174 只落了简化版 | diag 脚本的 `field_value` 续行修复（24 行，**没有 PR 覆盖**） | keep → 补 PR 后 delete | #174 落的是不处理续行的版本，分支版本是真修复 |
| `impl/29-wan-path` | 827 / 342 | 2026-11-19 18:58 | #200（wan-path 与测试） | 见「六分支探索线」 | keep → #200 合并后 delete | wan-path 与 `wan-path-test.sh` 只在 #200 里 |
| `xr1710g-ubus-test` | 826 / 342 | 2026-11-19 15:00 | 无 | 与 `agent/upstream-sync-86d15e9d44d6` **树完全相同** | keep-as-mirror | 同线的镜像 tips，删其一前先确认另一份仍在 |

`0 ahead` 的六个分支（#194/#195/#196/#197/#198/#199 的 head）加上已执行的 #201，都是"只在 GitHub 上留着一个指向已合并树的分支名"，删掉后如需追溯走 merge commit 或 PR 页面即可。

清单截取后远端又出现两个别的 agent 在用的分支：`fix/harness-correctness`（1 ahead / 0 behind，2026-11-20 09:50）、`fix/netwatchdog-guard`（本机尚未 fetch，未做比对）。两者按准则 3 不进入处置，只在这里登记，避免下次盘点时又被当成"新发现"。

## 六分支探索线（同 merge-base `5192094fd6`）

成员：`agent/upstream-sync-86d15e9d44d6`、`deliver/offline-round1`、`impl/101-bql-inflight`、`impl/19-lan10g-diag`、`impl/29-wan-path`、`xr1710g-ubus-test`。

### 这些分支里到底是什么

```text
5192094fd6 (merge-base)
├── xr1710g 线：342 commits，头部是一串 PR merge（#194…#201）
└── 探索线：826–833 commits，无 merge commit
    ├── 607 个提交 = upstream/main 的祖先（同一个对象，上游仍然持有）
    └── 219 个提交 = fork 自己的（deliver 为 226）
```

- `xr1710g-ubus-test` 与 `agent/upstream-sync-86d15e9d44d6` 的树**完全相同**（`git diff --stat` 空输出）。
- 这 607 个上游提交在 `xr1710g` 里没有——这就是 #189 说的"fork 落后上游"。它们不是"探索线独有的内容"，因为 `upstream/main` 持有同样的对象；删分支不会丢，但 `xr1710g` 也不会因此获得。
- 219 个 fork 提交里，**209 个在 `xr1710g` 有同 subject 的落地提交**（#141–#188 那批 agent PR 就是它们的落地点）。剩下的 10 个见下表。

### 未被任何 PR 覆盖的 10 个 fork 提交

| 提交 | 内容 | 状态 |
| --- | --- | --- |
| `4a11e7c709` | config-7.3 里点名 `# CONFIG_NET_AIROHA_SOE is not set` | **已落地**：#196 后 `config-7.3:281` 就是这一行 |
| `7a72ab8ee5` | 引入 `package/luci-app-w1700k-fancontrol/` 全套 13 个文件 | **已落地**：13/13 blob `SAME`；同提交里的 airoha 补丁 blob 差异来自后续 #195/#197 重排 |
| `1e4ce8ac5a` | performance governor + 超频 +200MHz | **在受保护分支**：`origin/kernel73` 的祖先（也是 kernel73 的 tip） |
| `76f44d46b6` | WED flow API header（7.3） | 同上，`origin/kernel73` 祖先 |
| `edc2b6f2bf` | mt7996 txfree 截断/令牌泄漏 | 同上，`origin/kernel73` 祖先 |
| `be9f844dc8` | 7.3 兼容补丁（iptables/jool/libbpf/linux-atm/mac80211） | 同上，`origin/kernel73` 祖先 |
| `6d2a544019` | kernel 7.3 pt 3：更新补丁 | 同上，`origin/kernel73` 祖先 |
| `ce8c96e21c` | mt76 补丁栈对着 **2026-10-28 pinned source** 重排（删 0013/0014，重编号到 0018–0025） | **未落地**：`xr1710g` 仍保有 0013/0014/0005，说明它钉的是更老的 mt76 源 |
| `8ba6129916` | 删掉重复的 mac80211 `424-...TXQ-scheduling-round.patch` | **未落地**：`xr1710g` 仍有该文件 |
| `86974b29bf` | firewall4 fullcone 补丁对着 `2026-11-08~3722eadc` 重刷（+20/−16） | **未落地**：`xr1710g` 的 002 补丁是旧锚 |

结论：**真正悬空的是 3 个"对新上游基线做补丁栈重排"的提交**（`ce8c96e21c`、`8ba6129916`、`86974b29bf`）。它们只在探索线上，而且只在探索线上，因为它们针对的 mt76/mac80211/firewall4 源比 `xr1710g` 钉的更新。这不是"忘了落地的功能"，是"rebase 到新上游时的副产物"——但在 #189 决定要不要吃这次 rebase 之前，不能删掉唯一持有它们的引用。

### 各分支的独有文件内容

| 分支 | 相对同线镜像多出来的东西 | 覆盖它的 PR |
| --- | --- | --- |
| `deliver/offline-round1` | `docs/wan-{productization,recovery-gate,wifi-path,2.5g-gate,measurement-protocol}.md`、`.github/research/materials.md` §9、`scripts/pppoe-4path.sh`、`tools/wan-bench/2.5g.sh` | #200（open） |
| `impl/29-wan-path` | `target/linux/airoha/an7581/base-files/usr/sbin/wan-path`、`scripts/tests/wan-path-test.sh` | #200（open） |
| `impl/101-bql-inflight` | `...968-net-airoha-budget-aware-napi-complete.patch`（35 行）、`...974-net-airoha-bql-accounting-helpers.patch`（89 行） | 无（另一 agent 正在搬运） |
| `impl/19-lan10g-diag` | `xr1710g-lan10g-diag` 的 `field_value` 续行拼接修复（24 行） | **无**（#174 落的是简化版） |
| `xr1710g-ubus-test` / `agent/upstream-sync-86d15e9d44d6` | 无（= 线基底 + 3 个未落地的栈重排） | — |

### 删除门槛（六分支共用，全部满足才可删）

1. PR #200 已 merge（docs 五份 + 四个 harness + wan-path 与测试都进 `xr1710g`）。
2. 968/974 两个补丁以 blob 相等的形式出现在 `xr1710g:target/linux/airoha/patches-7.3/`（搬运它的 PR 合并后核对 `git rev-parse`）。
3. `impl/19-lan10g-diag` 的 `field_value` 续行修复要么单独 PR 落地，要么由维护者在 #189（或后继 issue）写明放弃。
4. 三个栈重排提交（`ce8c96e21c`、`8ba6129916`、`86974b29bf`）要么在 `xr1710g` 的新基线上重做落地，要么由 #189 写明"这次 rebase 不做"。
5. #189 记录本次 sync 的结论（采用 / 放弃），保证 607 个上游提交 + 上述 3 个重排提交不再只有探索线一个引用。

过了这五条，判定可以退化成一条可执行的检查：

```sh
# 分支独有的 fork 提交（减掉上游持有的和 kernel73 持有的）必须为空
comm -23 \
  <(git log --format=%s origin/xr1710g..origin/<branch> ^upstream/main | sort -u) \
  <(git log --format=%s origin/xr1710g origin/kernel73 | sort -u)
```

输出为空 = 该分支没有 `xr1710g` 和受保护分支都没持有的内容 = 可删。

## 已执行 / 待执行

已执行（本 PR 之前，经 `gh api`，因为 `git push` 报 `Recv failure: Connection reset by peer`）：

```sh
gh api -X DELETE repos/genshanxinli/xr1710g-openwrt/git/refs/heads/fix/pse-reserve-param
```

待执行（需要人工或下一个 agent 触发，本 PR 不做）：

- 六个 `0 ahead` 的 head 分支：`fix/rebase-six-colliding-airoha-patches`、`ci/xr1710g-buildable`、`fix/build-blockers-soe-and-fakeroot`、`fix/qdma-irq-bank-mask-217`、`fix/qinq-tpid-9999`、`fix/qinq-9999-reanchor`。
- 三个 closed-PR agent 分支：`agent/qdma-irq-bugon-d65bfddeab28`、`agent/ppe-qinq-tpid-6da6bbcea4aa`、`agent/pse-reserve-param-aa5109af1053`（后者等 #203 merge，脚本改动被它覆盖）。
- 六分支探索线：等上节五条门槛。

## 证据命令

```sh
# ahead/behind
git rev-list --left-right --count origin/xr1710g...origin/<branch>

# 独有提交
git log --oneline origin/xr1710g..origin/<branch>

# patch-id 等价（重锚过的会全 +，只作线索）
git cherry -v origin/xr1710g origin/<branch>

# 内容是否真的落地：blob 相等
git rev-parse origin/<branch>:<path> origin/xr1710g:<path>

# 上游是否仍持有
git merge-base --is-ancestor <sha> upstream/main
git merge-base --is-ancestor <sha> origin/kernel73

# 探索线规模
git rev-list --count 5192094fd6..origin/xr1710g-ubus-test          # 826
git rev-list --count origin/xr1710g-ubus-test ^upstream/main       # 219
git diff --stat origin/xr1710g origin/xr1710g-ubus-test            # 1318 files, +103315/−11887
```

`kernel73` 当前与 `upstream/kernel73` 并不逐字节一致（`git diff --stat origin/kernel73 upstream/kernel73` = 599 files, +37338/−5486，上游 2026-11-19 又动过）。这是 #189 的同步工作项，也是"不能删 `kernel73`"的直接理由，不是本清单的处置对象。
