# 本目录是自用固件的**内置包 feed**（src-link 供给，见 config/feeds.custom.conf）
# 政策：vendor 包必须锁定来源 commit 并在此登记；升级 = 显式 bump + 记 FIXES.md。

# ── luci-app-airoha-recovery ──
# LuCI 面板一键进入 U-Boot HTTP 恢复环境（配合 HTTP U-Boot 主路径，FLASHING.md）
# 来源：naoki66/ImmortalWrt-for-Gemtek-XR1710G，分支 master
#   锁定 commit：dd9ecfeefa268b764efebee0d76f3149b3c01f12（2026-08-12）
#   路径：package/luci-app-airoha-recovery/（fetched 2026-08-17，7 文件）
# 依赖：+luci-base +uboot-envtools（官方）
# 升级：对比上游新 commit 后整体替换本目录，并在 FIXES.md F12 记录。

# ── xr1710g-proxy ──
# 名单客户端分流代理的数据面（ADR-0003 架构 C）：sing-box 核心 + 独立 nft 表
#   `inet xr1710g_proxy` + 策略路由（fwmark 0x40 / table 100）+ CN 放行集合。
# 来源：本仓库自写（非 vendor）。
# 依赖：+sing-box +nftables-json +kmod-tun +ip-full +curl +python3-light
# 关键设计（改动前先读 docs/adr/0003 与 docs/plans/proxy-dns-stack/01）：
#   - 判定在 nft prerouting(mangle)：CN 目的 accept（放回原 forward 路径 ⇒ 保 PPE/NPU 卸载），
#     其余打 mark 送 TUN。名单外客户端不匹配任何规则。
#   - 硬前提：名单客户端的 CN 域名必须回真实 IP，否则内核匹配不到 @china_ip4 ⇒ 卸载全丢。
#   - 不变量 I1–I4：绝不写 flow_offloading*、绝不 reload fw4、.nft 不含 `table inet fw4`、
#     uci-defaults 不 enable 任何服务。门禁：scripts/test-proxy-package.sh
#   - CN 快照（china_ip4/6.txt + geosite-cn.srs）随包装入只读 squashfs ⇒ 运行期零 NAND 写（G2）。
#     升级快照：./scripts/fetch-cn-list.sh（抓取+校验，然后提交 diff）。
# 验证：scripts/test-proxy-package.sh（36 项离线冒烟）；实机 `nft -c` 见 plan/04 T1-5。

# ── luci-app-xr1710g-proxy ──
# 极简 LuCI 前端：总开关 / 名单编辑 / CN 快照状态与立即更新 / 只读运行状态。
# 来源：本仓库自写。依赖：+luci-base +xr1710g-proxy +jq
# 为什么不引 homeproxy（ADR-0003）：它硬依赖 +kmod-nft-tproxy，且 routing_mode=
#   bypass_mainland_china 把 CN 判定放在用户态 ⇒ 先天不保 CN 流量的硬件卸载。
# i18n：msgid 一律英文；zh_Hans 翻译由 scripts/gen-luci-i18n.py 生成（改 JS 后重跑）。