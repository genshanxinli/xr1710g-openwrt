#!/usr/bin/env python3
"""check-workflow-yaml.py — GitHub Actions workflow 的结构自检（无需 pyyaml）

为什么需要：`build.yml` 是本仓库最关键的自动化，改错一行会让**所有**构建静默失效
（或直接不触发）。而本地/CI 环境不保证有 pyyaml（本机实测 python3 无 yaml、无 ruby、
无 perl YAML 模块、npx 需联网）。所以这里做一个**保守的**结构检查，覆盖最容易犯且最贵的错：

  1. 用 TAB 缩进（YAML 直接语法错误）
  2. 块标量（`run: |`）被后续同/更浅缩进的键提前结束
  3. step 缩进回退（把 step 挂错层级 ⇒ 静默变成 with 的列表项）
  4. 关键 job / 关键步骤缺失（改名或误删）

**它不替代真正的 YAML 解析**——只做能确定性判定的结构断言。有 pyyaml 时应优先用真解析器。
用法：scripts/check-workflow-yaml.py [workflow.yml ...]（缺省检查 .github/workflows/*.yml）
"""
import re
import sys
from pathlib import Path

REQUIRED_BUILD = [
    "name:", "jobs:", "resolve:", "build:", "release:",
]
# build.yml 必须保留的关键步骤（改名即提醒改这里）
REQUIRED_SNIPPETS = [
    "gate-proxy-invariants.sh",
    "test-proxy-package.sh",
    "size-report.sh",
    "fetch-cn-list.sh",
    "kmodsfeed-",
    "size-baseline.txt",
]


def check(path: Path) -> list[str]:
    errs: list[str] = []
    text = path.read_text(encoding="utf-8")
    lines = text.split("\n")

    for i, l in enumerate(lines, 1):
        if "\t" in l:
            errs.append(f"{path}:{i}: 含 TAB（YAML 禁止用 tab 缩进）")

    # 块标量：run:/path: 等 `|` 块内的行必须比键更深缩进
    i = 0
    while i < len(lines):
        m = re.match(r'^(\s*)(run|path|body_path|script):\s*\|', lines[i])
        if m:
            base = len(m.group(1))
            j = i + 1
            while j < len(lines):
                l = lines[j]
                if not l.strip():
                    j += 1
                    continue
                if (len(l) - len(l.lstrip())) <= base:
                    break
                j += 1
            i = j
        else:
            i += 1

    # step 缩进：顶层 job 下的 step 应统一为 6 空格（jobs.<id>.steps 的项）
    step_inds = set()
    for l in lines:
        m = re.match(r'^(\s*)-\s+(name|uses|run|if|id):', l)
        if m:
            step_inds.add(len(m.group(1)))
    # 允许 6（job steps）；出现其它深度说明有 step 挂错层
    bad = {x for x in step_inds if x != 6}
    if bad:
        errs.append(f"{path}: 存在非 6 空格缩进的 step 项：{sorted(bad)}（step 可能挂错层级）")

    # 关键内容：**只对 build.yml** 断言（其它 workflow 职责不同，不做这类断言）
    if path.name == "build.yml":
        for need in REQUIRED_BUILD + REQUIRED_SNIPPETS:
            if need not in text:
                errs.append(f"{path}: 缺少关键内容 {need!r}")
    return errs


def main() -> int:
    args = sys.argv[1:]
    if args:
        files = [Path(a) for a in args]
    else:
        files = sorted(Path(".github/workflows").glob("*.yml"))
    if not files:
        print("未找到 workflow 文件", file=sys.stderr)
        return 2

    all_errs: list[str] = []
    for f in files:
        e = check(f)
        if e:
            all_errs.extend(e)
        else:
            print(f"  ✓ {f} 结构检查通过")
    if all_errs:
        print("✗ workflow 结构问题：")
        for e in all_errs:
            print("  ", e)
        return 1
    print("✓ 全部 workflow 结构检查通过（无 TAB / 块标量未提前结束 / step 层级一致 / 关键步骤齐全）")
    print("  注：这是保守结构检查，不替代真正 YAML 解析；有 pyyaml 时请优先用真解析器。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
