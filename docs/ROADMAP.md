# ROADMAP — 后续计划

按优先级排序。原则：**修复而不是降级**——所有"暂缓"都是排队，不是放弃。

## P0 首次实机（刷机后第一轮）
- [ ] **真绿门禁**（2026-08-17 F19 修复后）：重建 stock + oc-1.3 + oc-1.4，以 **firmware artifact 存在** 为成功判据（此前三次构建假绿、artifact 从未产出）
- [ ] 物理口 ↔ 逻辑名实机核对（netdev-name 已固化：lan1/lan2=双 10G、wan=1G-1（gsw_port1）、lan3=1G-2（gsw_port2），见 9001；`ip -br link` 验证后定稿 files/etc/config/network）
- [ ] 核对 6GHz EHT320 实际生效（`iw phy` / hostapd 日志），不生效则修 mt76/hostapd 至生效
- [ ] NPU 加载与卸载验证（luci-app-airoha-npu 已由 19-pack 内置）
- [ ] 风扇曲线实测（温度点/转速），按 NCT7802 实测修正曲线参数
- [ ] 跑 `docs/ACCEPTANCE.md` 全项 → 首个 known-good tag

## P1 资产评审与供给（2026-08-17：应用供给已闭环；08 切片 + 19 精简已收口）
- [x] **F13 拆分**：08 号六项切片入 default（root/9011-9016，2026-08-17 完成）；19 号精简为 root/9017 19-core（去 fastfetch/netspeedtest，2026-08-17 完成）
- [x] 评审 11/13/14/15/16 号定档位（2026-08-17：11 LRO→default；13 mt76 源 pin→否决(供应链)；14 mt76 debugfs→default；15 txpower 备选→不启用；16 wifi-scripts ucode→重建为 root/9010→default）
- [x] `luci-app-airoha-recovery` 供给（2026-08-17：packages-xr1710g/ src-link，源 naoki66@dd9ecfeef）

## P2 上游 PR 跟追（合入即删本层补丁）
- [ ] #22397（板级）——合入后删 `patches/root/9000-xr1710g-common.patch` 等三件套
- [ ] #22029（cpufreq/PM domain）——**已自持 fanboy 03（含 direct-PLL fallback）**；上游合入即删
- [ ] #24034（RTL826x LED）/ #24619（mt7530 LED）——取决于实机 LED 行为反馈
- [ ] #22473（uboot pstore）——kernel 侧已自持，剩 uboot 侧
- [ ] #22532（DSA）/ #22533（L2 offload）——实验档毕业候选（原料桶 04/05/06 已入库）：实验构建跑通 + 实机验证后并入默认档

## P3 能力增强（决策标注的后续计划）
- [ ] **漫游优化**（决策：暂不设置，固件稳定后实施）：802.11s/EHT320 回程、usteer/802.11k/v/r、（如多设备）mesh 配置
- [ ] OC 实机验证报告：oc-1.3 与 oc-1.4 在实机的稳定性/温度，归档到 FIXES F08
- [ ] 科学上网（OpenClash/PassWall）+ Docker——暂缓项，稳定后再决策 feed 与体积预算
- [ ] mt76 实验补丁（integration 树 9990-9993：EHT 广告/320M BF fallback/PS-sync/rate control）——评估后进实验档
- [ ] 530 实验室 6GHz SP 补丁——默认停用；如需高功率实验，手动启用并在验收注明非合规

## P4 工程化
- [x] 构建产出后自动打 pre-release（含 FIXES 变更摘要；2026-08-17 实现——但 F19 假绿修复前 release 是空壳，真绿后才有意义）
- [x] 构建退出码硬化（F19：pipefail + no-files-found=error，2026-08-17）
- [x] 拷贝类补丁 dry-run 真实应用校验（F20 制度化，2026-08-17：新增 `scripts/verify-copy-patches.sh` 接入 `apply-patches.sh --dry-run`——按构建语义解包包源码 + glob 排序真实 `patch -p1`，regdb 附 dbparse 校验；2h sync cron 尽早暴露而非等构建）
- [ ] 实验档毕业的自动化：experimental 构建通过 + ACCEPTANCE 子集 → PR 式合并到默认 MANIFEST
- [ ] vermagic 注入接入 CI（F14，让自建 kmod 兼容官方 opkg）
- [ ] 2h 同步工作流稳定后，把"冲突出现 → 修复 → 回归"流程沉淀为 CI 注释/文档（sync-upstream.yml 已就位）