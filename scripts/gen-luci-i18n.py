#!/usr/bin/env python3
"""gen-luci-i18n.py — 从 proxy.js 抽取 msgid 并生成 po/templates + po/zh_Hans

为什么不让中文直接当 msgid：LuCI 用英文 msgid 作基准，zh_Hans 靠 .po 翻译；
若 msgid 是中文，则**英文界面会显示中文**（本项目其余 LuCI 包均为英文 msgid + zh_Hans 翻译）。

用法：gen-luci-i18n.py <包目录> <i18n-scan.pl 路径>
"""
import re
import subprocess
import sys
from pathlib import Path

ZH = {
    "(none)": "（无）",
    "Absent": "不存在",
    "Capture table inet xr1710g_proxy": "抓取表 inet xr1710g_proxy",
    "China allow-list (what preserves hardware offload)": "CN 放行集合（保住硬件卸载的关键）",
    "Conflicts are detected before start. On conflict the service refuses to start instead of overwriting foreign entries.":
        "启动前会检测冲突。冲突时拒绝启动，而不是覆盖他人条目。",
    "Disabled by default. On start failure or process crash it fails open by removing the capture and redirect rules, so the proxy clients fall back to direct routing and normal networking is never affected.":
        "默认关闭。启动失败或进程崩溃时 fail-open：撤掉抓取与重定向规则，名单客户端退回直连，正常网络不受任何影响。",
    "Effective policy routes": "实际策略路由",
    "Enable scheduled update": "启用定时更新",
    "Enable split-routing proxy": "启用分流代理",
    "Fail-open is active: capture and redirect rules were removed, proxy clients fall back to direct routing.":
        "已进入 fail-open：抓取与重定向规则已撤，名单客户端退回直连。",
    "Fail-open state": "fail-open 状态",
    "Failing open is deliberate: if the proxy core dies, proxy clients fall back to direct routing instead of losing connectivity, which matches the rule that a failure must never affect normal networking. The trade-off is that during a fault those clients are not proxied, which is stated here explicitly.":
        "刻意选择 fail-open：代理核心挂掉时让名单客户端退回直连，而不是断网——与「失败不影响正常网络」一致。代价是故障期这些客户端不被代理，此处明确写出。",
    "Fake-IP scope": "fake-ip 作用域",
    "Hard constraint of this architecture: fake-IP may only be handed to proxy clients. Ordinary clients always receive real IPs. If an ordinary client received 198.18.x, the kernel allow-rule (which only matches proxy clients) would never let it out, so foreign sites would be unreachable rather than merely slow.":
        "本架构的硬约束：fake-ip 只允许投递给名单客户端。普通客户端恒得真实 IP。若普通客户端拿到 198.18.x，而内核放行规则只匹配名单客户端，它就永远出不去——国外站点会直接不通，而不是变慢。",
    "Installed": "已安装",
    "Kernel-level classification. Only clients on the proxy list are captured into userspace; all other clients stay on the original forwarding path with hardware offload fully preserved.":
        "内核层判定。只有名单客户端会被捕获进用户态；其余客户端留在原转发路径，硬件卸载完整保留。",
    "Live kernel set entries": "内核集合当前条目",
    "Loaded": "已载入",
    "Master switch. When disabled the init script exits immediately: no nft table, no policy route, no process.":
        "总开关。关闭时 init 立即退出：不建 nft 表、不加策略路由、不起进程。",
    "Must be an IPv4 address or CIDR, for example 192.168.123.224 or 192.168.123.0/24":
        "必须是 IPv4 地址或 CIDR，例如 192.168.123.224 或 192.168.123.0/24",
    "Normal (not triggered)": "正常（未触发）",
    "Not installed": "未安装",
    "Not running": "未运行",
    "Not running is the normal state while the master switch is off.":
        "总开关关闭时「未运行」是正常状态。",
    "Off by default: only the snapshot shipped in the read-only firmware volume is used, so there are zero NAND writes at runtime.":
        "默认关闭：只用随固件进只读分区的快照，因此运行期零 NAND 写入。",
    "Only these clients are captured into userspace. Every other client keeps exactly the same forwarding path as if this component did not exist, so hardware offload (PPE/NPU) is fully preserved.":
        "只有这些客户端会被捕获进用户态。其余客户端的转发路径与本组件不存在时完全一致，硬件卸载（PPE/NPU）完整保留。",
    "Note: the set must not contain overlapping or nested ranges. If you list 192.168.1.0/24, do not also list 192.168.1.5 - rendering rejects it and the service refuses to start.":
        "注意：集合不允许区间重叠或包含。写了 192.168.1.0/24 就不要再写 192.168.1.5——渲染会直接拒绝，服务拒绝启动。",
    "Policy routing": "策略路由",
    "Policy-routing entries": "策略路由条目",
    "Policy-routing mark (hex). Conflicts are detected before start; if the mark is already taken (for example Tailscale uses 0x80000/0xff0000) the service refuses to start and logs it, never touching someone else\u2019s entries.":
        "策略路由标记（十六进制）。启动前检测冲突；标记已被占用（例如 Tailscale 用 0x80000/0xff0000）时拒绝启动并落日志，绝不改他人条目。",
    "Policy-routing table number. A conflict with an existing routing table makes the service refuse to start.":
        "策略路由表号。与既有路由表冲突时拒绝启动。",
    "Proxy and networking - split-routing proxy": "代理与组网 — 分流代理",
    "Proxy clients": "名单客户端",
    "Proxy clients (source IP / CIDR, one entry per line).": "名单客户端（源 IP / CIDR，每行一条）。",
    "Recent log lines": "最近日志",
    "Routing table": "路由表号",
    "Running": "运行中",
    "Snapshot shipped in firmware": "随固件快照",
    "Split-routing settings": "分流设置",
    "Split-routing proxy": "分流代理",
    "The snapshot lives in the read-only squashfs volume, so it uses no overlay space and causes no NAND writes. China domains of proxy clients must resolve to real IPs, otherwise the kernel cannot match this set and the direct path - which is what keeps hardware offload for domestic traffic - stops working.":
        "快照位于只读 squashfs 分区：不占 overlay、不写 NAND。名单客户端的 CN 域名必须解析回真实 IP，否则内核匹配不到这个集合，「国内直连保硬件卸载」这条就直接失效。",
    "Toggling only does uci commit plus /etc/init.d/xr1710g-proxy reload; the firewall (fw4) is never reloaded, because a fw4 reload rebuilds the hardware flowtable.":
        "切换只做 uci commit + /etc/init.d/xr1710g-proxy reload；绝不 reload fw4，因为 fw4 reload 会重建硬件 flowtable。",
    "TUN interface name": "TUN 接口名",
    "Update China allow-list now": "立即更新 CN 放行集合",
    "Update failed, the previous set was kept:": "更新失败（旧集合保持不变）：",
    "Update succeeded:": "更新成功：",
    "Runtime state": "运行状态",
    "When enabled, lists are fetched to /tmp periodically and swapped into the kernel set atomically only after validation; a failed validation keeps the previous set.":
        "开启后按周期抓取到 /tmp，校验通过才原子换入内核集合；校验失败保留旧集合。",
    "auto_route and auto_redirect are always false, so traffic is never taken over globally.":
        "auto_route 与 auto_redirect 恒为 false——绝不全局接管。",
    "fwmark": "fwmark",
    "sing-box DNS port": "sing-box DNS 端口",
    "sing-box process": "sing-box 进程",
}


def parse_pot(text):
    """把 pot 文本切成 [(refs, msgid), ...]（跳过 PO 头与空 msgid）"""
    entries, refs, mid = [], [], None
    for line in text.splitlines():
        if line.startswith('#:'):
            if mid is not None:
                if mid:
                    entries.append((refs, mid))
                refs, mid = [], None
            refs.append(line)
        elif line.startswith('msgid '):
            if mid is not None:
                if mid:
                    entries.append((refs, mid))
                refs = []
            raw = line[len('msgid '):].strip()
            mid = raw[1:-1] if raw.startswith('"') else raw
        elif line.startswith('msgstr') or line.startswith('msgid_plural') or not line.strip():
            continue
    if mid:
        entries.append((refs, mid))
    return entries


def main():
    pkg = Path(sys.argv[1]).resolve()
    scanner = sys.argv[2]
    # 以包目录为 cwd、以 '.' 为扫描目标 ⇒ pot 中 ref 为相对路径（可复现 diff，不泄漏本机路径）
    pot = subprocess.run(['perl', scanner, '.'], capture_output=True, text=True, check=True, cwd=str(pkg)).stdout

    (pkg / 'po/templates').mkdir(parents=True, exist_ok=True)
    (pkg / 'po/zh_Hans').mkdir(parents=True, exist_ok=True)
    (pkg / 'po/templates/luci-app-xr1710g-proxy.pot').write_text(pot, encoding='utf-8')

    entries = parse_pot(pot)
    out = ['msgid ""', 'msgstr ""',
           '"Project-Id-Version: luci-app-xr1710g-proxy\\n"',
           '"PO-Revision-Date: 2026-09-11\\n"',
           '"Last-Translator: XR1710G Maintainer\\n"',
           '"Language-Team: \\n"',
           '"Language: zh_Hans\\n"',
           '"MIME-Version: 1.0\\n"',
           '"Content-Type: text/plain; charset=UTF-8\\n"',
           '"Content-Transfer-Encoding: 8bit\\n"',
           '']
    missing = []
    for refs, mid in entries:
        zh = ZH.get(mid)
        if zh is None:
            missing.append(mid)
            zh = ''
        out.extend(refs)
        out.append('msgid "%s"' % mid.replace('"', '\\"'))
        out.append('msgstr "%s"' % zh)
        out.append('')
    (pkg / 'po/zh_Hans/luci-app-xr1710g-proxy.po').write_text('\n'.join(out) + '\n', encoding='utf-8')

    print('entries=%d translated=%d missing=%d' % (len(entries), len(entries) - len(missing), len(missing)))
    for m in missing:
        print('  MISSING: %s' % m[:120])
    return 1 if missing else 0


if __name__ == '__main__':
    sys.exit(main())
