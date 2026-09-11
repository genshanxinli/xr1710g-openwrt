#!/usr/bin/env python3
"""validate-cidr.py — 校验 CIDR 列表可安全装入 nft `flags interval` 集合

nft 对 `flags interval` 集合内的**重叠/包含**区间直接报
    Error: conflicting intervals specified
（本机 2026-09-11 实机 `nft -c` 抓出）。所以装载前必须证明列表互不重叠。

输出：条目数 / 去重数 / 重叠对（最多 20 条）/ family 分布
退出码：0 = 全部合法；1 = 存在重叠或非法条目
"""
import ipaddress
import sys


def load(path, want_version):
    good, bad, dup = [], [], 0
    seen = set()
    with open(path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            s = raw.strip()
            if not s or s.startswith("#"):
                continue
            try:
                net = ipaddress.ip_network(s, strict=False)
            except ValueError as exc:
                bad.append((lineno, s, str(exc)))
                continue
            if net.version != want_version:
                bad.append((lineno, s, f"family mismatch (want v{want_version})"))
                continue
            if net in seen:
                dup += 1
                continue
            seen.add(net)
            good.append(net)
    return good, bad, dup


def overlaps(nets):
    """按区间起点排序后线性扫描：只需比较相邻项。"""
    pairs = []
    srt = sorted(nets, key=lambda n: (int(n.network_address), int(n.broadcast_address)))
    for a, b in zip(srt, srt[1:]):
        if int(b.network_address) <= int(a.broadcast_address):
            pairs.append((a, b))
    return pairs


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    total_bad = 0
    for path, ver in ((sys.argv[1], 4), (sys.argv[2], 6)):
        nets, bad, dup = load(path, ver)
        ov = overlaps(nets)
        print(f"[v{ver}] {path}")
        print(f"  entries={len(nets)} duplicates_skipped={dup} invalid={len(bad)} overlaps={len(ov)}")
        if bad:
            total_bad += 1
            for lineno, s, why in bad[:20]:
                print(f"    ✗ line {lineno}: {s!r} — {why}")
        if ov:
            total_bad += 1
            for a, b in ov[:20]:
                print(f"    ✗ overlap: {a} ⊂/∩ {b}")
        if not bad and not ov:
            print("  ✓ 可安全装入 flags interval 集合")
    return 1 if total_bad else 0


if __name__ == "__main__":
    sys.exit(main())
